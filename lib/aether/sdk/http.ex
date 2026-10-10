defmodule Aether.SDK.HTTP do
  @moduledoc false
  alias Aether.SDK.Error

  # The linked task bounds the whole response, including a slowly streaming body.
  # Exceptions from adapters must never become task-crash logs containing secrets.
  def run(options, timeout, cancelled? \\ fn -> false end)
      when is_integer(timeout) and timeout > 0 do
    run_fun(
      fn ->
        Req.request(
          Keyword.merge(options,
            retry: false,
            redirect: false,
            decode_body: false,
            http_errors: :return,
            receive_timeout: timeout,
            retry_log_level: false,
            redirect_log_level: false
          )
        )
      end,
      timeout,
      cancelled?
    )
  end

  def run_fun(fun, timeout, cancelled?) when is_function(fun, 0) do
    owner = self()

    task =
      Task.async(fn ->
        worker = self()

        guard =
          spawn(fn ->
            ref = Process.monitor(owner)
            worker_ref = Process.monitor(worker)

            receive do
              {:DOWN, ^ref, :process, _, _} -> Process.exit(worker, :kill)
              {:DOWN, ^worker_ref, :process, _, _} -> :ok
            end
          end)

        try do
          fun.()
        rescue
          _ -> {:error, Error.new("network_error", "Aether request failed")}
        catch
          _, _ -> {:error, Error.new("network_error", "Aether request failed")}
        after
          Process.exit(guard, :kill)
        end
      end)

    await(task, System.monotonic_time(:millisecond) + timeout, cancelled?)
  end

  defp await(task, deadline, cancelled?) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      cancelled?.() ->
        Task.shutdown(task, :brutal_kill)
        {:error, Error.new("request_aborted", "Aether request was cancelled")}

      remaining <= 0 ->
        Task.shutdown(task, :brutal_kill)
        {:error, Error.new("request_timeout", "Aether request timed out")}

      true ->
        result(Task.yield(task, min(remaining, 25)), task, deadline, cancelled?)
    end
  end

  defp result(result, task, deadline, cancelled?) do
    case result do
      {:ok, {:ok, response}} ->
        {:ok, response}

      {:ok, {:error, %Req.TransportError{reason: :timeout}}} ->
        {:error, Error.new("request_timeout", "Aether request timed out")}

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:ok, {:error, _}} ->
        {:error, Error.new("network_error", "Aether request failed")}

      nil ->
        await(task, deadline, cancelled?)

      _ ->
        {:error, Error.new("network_error", "Aether request failed")}
    end
  end
end
