defmodule Aether.SDK.Storage.Workflow.Result do
  @moduledoc "Upload intent and final object metadata. The signed intent is omitted from inspection."
  @derive {Inspect, only: [:object]}
  defstruct [:intent, :object]
  @type t :: %__MODULE__{intent: struct() | map(), object: struct() | map()}
end

defmodule Aether.SDK.Storage.Workflow do
  @moduledoc """
  Create, transfer, and complete uploads with best-effort cleanup on failure.

  `upload_object(client, request, source, options)` accepts a create-intent body
  and a binary or `{:file, path}` source. Options include `:concurrency`,
  `:provider_options` (passed only to the provider transfer), `:request_options`
  (passed only to the API), `:idempotency_keys` (`:create`, `:complete`, `:abort`),
  `:sha256`, `:cancelled?`, and `:wait_for_availability` (`true` or polling keyword options).

  The original failure is returned when abort cleanup fails; `error.details`
  contains the stage and whether cleanup succeeded. Availability failures after
  completion never abort a completed upload. Polling defaults to 120 seconds
  with one second between requests, and accepts `:cancelled?` for cancellation.
  """
  alias Aether.SDK.{Error, Storage}
  alias Aether.SDK.Storage.{Source, Transfer}
  alias Aether.SDK.Storage.Workflow.Result
  import Aether.SDK.Storage.Transfer, only: [field: 2]

  @spec upload_object(Aether.SDK.Client.t(), map() | struct(), Transfer.source(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def upload_object(client, request, source, options \\ []) do
    with {:ok, size} <- Source.size(source),
         :ok <- check_size(size, field(request, :expected_size)) do
      request = default_metadata(request)
      keys = Keyword.get(options, :idempotency_keys, %{})

      keys =
        Map.new([:create, :complete, :abort], fn name ->
          {name,
           field(keys, name) ||
             "upload_#{name}_#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"}
        end)

      api_options = api_options(options)

      case Storage.create_upload_intent(
             client,
             %{body: request, headers: idempotency(keys.create)},
             api_options
           ) do
        {:ok, intent} -> finish(client, request, intent, source, keys, options)
        {:error, error} -> {:error, stage(error, :create_intent)}
      end
    end
  end

  @spec wait_for_object_available(Aether.SDK.Client.t(), String.t(), keyword()) ::
          {:ok, map() | struct()} | {:error, Error.t()}
  def wait_for_object_available(client, object_id, options \\ []) do
    timeout = Keyword.get(options, :timeout, 120_000)
    interval = Keyword.get(options, :poll_interval, 1_000)

    if is_integer(timeout) and timeout >= 0 and is_integer(interval) and interval >= 0 do
      deadline = System.monotonic_time(:millisecond) + timeout
      poll(client, object_id, deadline, interval, options)
    else
      {:error,
       Error.new(
         "invalid_timeout",
         "Availability timeout and poll interval must be non-negative milliseconds"
       )}
    end
  end

  defp finish(client, request, intent, source, keys, options) do
    provider = forward_cancellation(Keyword.get(options, :provider_options, []), options)
    provider = Keyword.put(provider, :concurrency, Keyword.get(options, :concurrency, 4))

    transfer =
      case field(intent, :upload_strategy) do
        "single" ->
          if field(intent, :multipart) == nil do
            case Transfer.upload(
                   field(intent, :upload_url),
                   source,
                   field(intent, :required_headers) || %{},
                   provider
                 ) do
              {:ok, _} -> {:ok, %{}}
              result -> result
            end
          else
            {:error,
             Error.new("invalid_upload_intent", "Storage returned an invalid upload intent")}
          end

        "multipart" ->
          case Transfer.upload_multipart(intent, source, provider) do
            {:ok, parts} -> {:ok, %{parts: parts}}
            result -> result
          end

        _ ->
          {:error,
           Error.new("invalid_upload_intent", "Storage returned an invalid upload intent")}
      end

    result =
      with {:ok, body} <- tag(transfer, :transfer) do
        sha256 = Keyword.get(options, :sha256, field(request, :client_sha256))
        body = if sha256, do: Map.put(body, :sha256, sha256), else: body

        Storage.complete_upload(
          client,
          %{
            path: %{upload_id: field(intent, :upload_id)},
            body: body,
            headers: idempotency(keys.complete)
          },
          api_options(options)
        )
        |> tag(:complete)
      end

    case result do
      {:ok, object} ->
        available(client, intent, object, options)

      {:error, error} ->
        cleanup =
          Storage.abort_upload(
            client,
            %{path: %{upload_id: field(intent, :upload_id)}, headers: idempotency(keys.abort)},
            api_options(options) |> Keyword.delete(:cancelled?)
          )

        {:error,
         %{
           error
           | details: Map.put(error.details, :cleanup_succeeded, match?({:ok, _}, cleanup))
         }}
    end
  end

  defp available(client, intent, object, options) do
    case Keyword.get(options, :wait_for_availability, false) do
      false ->
        {:ok, %Result{intent: intent, object: object}}

      wait ->
        wait_options = forward_cancellation(if(wait == true, do: [], else: wait), options)

        wait_options =
          Keyword.put_new(
            wait_options,
            :request_options,
            api_options(options)
          )

        case wait_for_object_available(client, field(intent, :object_id), wait_options) do
          {:ok, available} -> {:ok, %Result{intent: intent, object: available}}
          result -> result
        end
    end
  end

  defp poll(client, object_id, deadline, interval, options) do
    remaining = deadline - System.monotonic_time(:millisecond)
    api = api_options(options)

    cond do
      cancelled?(options) ->
        {:error, Error.new("aborted", "Object availability polling was cancelled")}

      remaining <= 0 ->
        availability_timeout()

      true ->
        # Even response-body reads are bounded by the remaining polling budget.
        timeout = min(Keyword.get(api, :timeout, client.timeout), remaining)

        case Storage.get_object(
               client,
               %{path: %{object_id: object_id}},
               Keyword.put(api, :timeout, timeout)
             ) do
          {:ok, object} ->
            cond do
              field(object, :status) == "available" ->
                {:ok, object}

              field(object, :status) == "deleted" ->
                {:error,
                 Error.new("object_deleted", "Object was deleted before becoming available")}

              deadline <= System.monotonic_time(:millisecond) ->
                availability_timeout()

              true ->
                pause(
                  min(interval, max(deadline - System.monotonic_time(:millisecond), 0)),
                  options
                )

                poll(client, object_id, deadline, interval, options)
            end

          {:error, %Error{code: "request_timeout"}} ->
            if deadline <= System.monotonic_time(:millisecond),
              do: availability_timeout(),
              else:
                {:error, Error.new("request_timeout", "Object availability request timed out")}

          error ->
            error
        end
    end
  end

  defp pause(0, _), do: :ok

  defp pause(time, options) do
    unless cancelled?(options) do
      step = min(time, 25)
      Process.sleep(step)
      pause(time - step, options)
    end
  end

  defp api_options(options),
    do: forward_cancellation(Keyword.get(options, :request_options, []), options)

  defp forward_cancellation(target, options) do
    case Keyword.fetch(options, :cancelled?) do
      {:ok, cancel} -> Keyword.put_new(target, :cancelled?, cancel)
      :error -> target
    end
  end

  defp cancelled?(options), do: Keyword.get(options, :cancelled?, fn -> false end).()

  defp availability_timeout,
    do: {:error, Error.new("availability_timeout", "Timed out waiting for object availability")}

  defp check_size(size, size), do: :ok

  defp check_size(_, _),
    do: {:error, Error.new("size_mismatch", "Upload source size does not match expected_size")}

  # Older Storage deployments persist omitted metadata as null, although the
  # public object contract requires a map. Explicit null still fails validation.
  defp default_metadata(request) do
    case Map.get(request, :metadata, Map.get(request, "metadata", :__aether_unset__)) do
      :__aether_unset__ -> Map.put(request, :metadata, %{})
      _ -> request
    end
  end

  defp idempotency(key), do: %{"idempotency-key" => key}
  defp tag({:error, error}, name), do: {:error, stage(error, name)}
  defp tag(result, _), do: result
  defp stage(error, name), do: %{error | details: %{stage: name}}
end
