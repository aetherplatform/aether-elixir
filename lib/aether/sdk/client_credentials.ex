defmodule Aether.SDK.ClientCredentials do
  @moduledoc """
  Supervised, expiry-aware workload credentials with one acquisition in flight.

  Add `{Aether.SDK.ClientCredentials, options}` to a supervisor, then configure
  a platform client with `token_provider: {Aether.SDK.ClientCredentials, name}`.
  Required options are `:token_url`, `:client_id`, `:client_secret`, `:audience`
  and a nonempty list of `:capabilities`. Cache expiry includes a 30-second skew.
  `invalidate/1` clears the cache and replaces any in-flight acquisition for
  current waiters.
  """
  use GenServer
  @behaviour Aether.SDK.TokenProvider
  alias Aether.SDK.{AccessToken, Client, Error, HTTP}

  def child_spec(options) do
    %{
      id: Keyword.get(options, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [options]}
    }
  end

  def start_link(options) do
    with :ok <- validate(options) do
      GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
    end
  end

  @impl Aether.SDK.TokenProvider
  def get_token(provider), do: GenServer.call(provider, :get_token, :infinity)
  @impl Aether.SDK.TokenProvider
  def invalidate(provider), do: GenServer.call(provider, :invalidate)

  @impl GenServer
  def init(options),
    do:
      {:ok,
       %{
         options: options,
         token: nil,
         task: nil,
         waiters: %{},
         generation: 0,
         flight_generation: nil
       }}

  @impl GenServer
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl GenServer
  def handle_call(:get_token, from, state) do
    skew = Keyword.get(state.options, :expiry_skew, 30_000)

    case state.token do
      %AccessToken{expires_at: expiry} = token when expiry > 0 ->
        if expiry > System.system_time(:millisecond) + skew,
          do: {:reply, {:ok, token}, state},
          else: enqueue(from, %{state | token: nil})

      _ ->
        enqueue(from, state)
    end
  end

  def handle_call(:invalidate, _from, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)

    state = %{
      state
      | token: nil,
        task: nil,
        generation: state.generation + 1,
        flight_generation: nil
    }

    state = if map_size(state.waiters) > 0, do: start_flight(state), else: state
    {:reply, :ok, state}
  end

  defp enqueue({pid, _} = from, state) do
    ref = Process.monitor(pid)
    state = %{state | waiters: Map.put(state.waiters, ref, from)}

    state = if state.task, do: state, else: start_flight(state)

    {:noreply, state}
  end

  defp start_flight(state) do
    owner = self()
    options = state.options

    task =
      Task.async(fn ->
        worker = self()

        guard =
          spawn(fn ->
            owner_ref = Process.monitor(owner)
            worker_ref = Process.monitor(worker)

            receive do
              {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(worker, :kill)
              {:DOWN, ^worker_ref, :process, _, _} -> :ok
            end
          end)

        try do
          acquire(options)
        after
          Process.exit(guard, :kill)
        end
      end)

    %{state | task: task, flight_generation: state.generation}
  end

  @impl GenServer
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    Enum.each(state.waiters, fn {monitor, from} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, result)
    end)

    token =
      case result do
        {:ok, token} when state.generation == state.flight_generation -> token
        _ -> nil
      end

    {:noreply, %{state | task: nil, token: token, waiters: %{}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    waiters = Map.delete(state.waiters, ref)

    if map_size(waiters) == 0 and state.task do
      Task.shutdown(state.task, :brutal_kill)
      {:noreply, %{state | waiters: waiters, task: nil}}
    else
      {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp acquire(options) do
    try do
      headers = %{
        "accept" => "application/json",
        "content-type" => "application/x-www-form-urlencoded",
        "authorization" =>
          "Basic " <>
            Base.encode64(
              URI.encode_www_form(options[:client_id]) <>
                ":" <> URI.encode_www_form(options[:client_secret])
            )
      }

      body =
        URI.encode_query(%{
          "grant_type" => "client_credentials",
          "audience" => options[:audience],
          "scope" => Enum.join(options[:capabilities], " ")
        })

      req =
        Keyword.merge(Keyword.get(options, :req_options, []),
          url: options[:token_url],
          method: :post,
          headers: headers,
          body: body
        )

      fetch(req, Keyword.get(options, :timeout, 10_000), Keyword.get(options, :max_retries, 1), 1)
    rescue
      _ -> failure("token_request_failed")
    catch
      _, _ -> failure("token_request_failed")
    end
  end

  defp fetch(req, timeout, retries, attempt) do
    result =
      with {:ok, response} <- HTTP.run(req, timeout) do
        body =
          case Jason.decode(response.body) do
            {:ok, value} -> value
            _ -> nil
          end

        if response.status in 200..299 do
          case body do
            %{"access_token" => token, "token_type" => "Bearer", "expires_in" => expiry}
            when is_binary(token) and token != "" and is_integer(expiry) and expiry > 0 ->
              {:ok,
               %AccessToken{
                 value: token,
                 expires_at: System.system_time(:millisecond) + expiry * 1000
               }}

            _ ->
              failure("invalid_token_response")
          end
        else
          {:error,
           Error.from_response(response.status, response.headers, body, attempt)
           |> Error.sanitize()}
        end
      end

    case result do
      {:error, error} ->
        if attempt <= retries and Aether.SDK.Transport.retryable?(error) do
          delay =
            case Map.fetch(error.retry, :retry_after_seconds) do
              {:ok, seconds} when is_integer(seconds) and seconds >= 0 -> seconds * 1000
              _ -> min(100 * attempt, 1000)
            end

          Process.sleep(delay)
          fetch(req, timeout, retries, attempt + 1)
        else
          {:error, %{Error.sanitize(error) | attempts: attempt}}
        end

      other ->
        other
    end
  end

  defp validate(options) do
    allowed =
      ~w(name token_url client_id client_secret audience capabilities timeout max_retries expiry_skew req_options)a

    valid =
      Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
        Enum.all?(
          [:client_id, :client_secret, :audience],
          &(is_binary(options[&1]) and String.trim(options[&1]) != "")
        ) and
        is_list(options[:capabilities]) and options[:capabilities] != [] and
        Enum.all?(options[:capabilities], &(is_binary(&1) and String.trim(&1) != "")) and
        is_integer(Keyword.get(options, :expiry_skew, 30_000)) and
        Keyword.get(options, :expiry_skew, 30_000) >= 0

    if valid do
      with {:ok, _} <- Client.validate_url(options[:token_url]),
           :ok <-
             Client.validate_options(
               Keyword.take(options, [:timeout, :max_retries, :req_options])
             ) do
        :ok
      end
    else
      failure("invalid_configuration")
    end
  end

  defp failure(code), do: {:error, Error.new(code, "Aether workload authentication failed")}
end
