defmodule Aether.SDK.Storage.Transfer do
  @moduledoc """
  Direct provider transfers, isolated from the Aether API client.

  Upload sources are binaries or `{:file, path}`. Files are read in bounded chunks.
  `download/3` streams to a one-argument callback returning `:ok` (or `{:error, reason}`)
  or to an IO device; `download_binary/2` is the explicitly buffered convenience.
  Streaming sinks can contain partial data on failure and must be discarded by callers.

  Options: `:timeout` (15,000 ms), `:concurrency` (multipart, default 4),
  `:cancelled?` (zero-argument cancellation predicate), and `:req_options` for a
  provider-specific Req adapter/connection configuration. API client options and
  credentials are never forwarded. Redirects, decompression and retries are disabled.
  """
  alias Aether.SDK.Error
  alias Aether.SDK.Storage.Source
  @type source :: binary() | {:file, Path.t()}
  @type result(value) :: {:ok, value} | {:error, Error.t()}
  @forbidden ~w(authorization proxy-authorization x-request-id x-correlation-id cookie)
  @connection_options [:plug, :adapter, :connect_options, :finch, :pool_timeout]

  @spec upload(String.t(), source(), map(), keyword()) :: result(%{etag: String.t() | nil})
  def upload(url, source, headers \\ %{}, options \\ []) do
    with {:ok, size} <- Source.size(source),
         {:ok, response} <-
           request(:put, url, headers, Source.stream(source, 0, size), size, nil, options) do
      {:ok, %{etag: Error.header(response.headers, "etag")}}
    end
  end

  @spec download(String.t(), (binary() -> :ok | {:error, term()}) | pid() | atom(), keyword()) ::
          result(non_neg_integer())
  def download(url, destination, options \\ []) do
    into = fn {:data, data}, {request, response} ->
      if response.status in 200..299 do
        result =
          if is_function(destination, 1),
            do: destination.(data),
            else: IO.binwrite(destination, data)

        unless result == :ok, do: raise("Download destination failed")
        count = if is_integer(response.body), do: response.body, else: 0
        {:cont, {request, %{response | body: count + byte_size(data)}}}
      else
        {:cont, {request, response}}
      end
    end

    with {:ok, response} <- request(:get, url, %{}, nil, nil, into, options) do
      count = if is_integer(response.body), do: response.body, else: 0
      verify_size(response, count)
    end
  end

  @spec download_binary(String.t(), keyword()) :: result(binary())
  def download_binary(url, options \\ []) do
    with {:ok, response} <- request(:get, url, %{}, nil, nil, nil, options),
         true <- is_binary(response.body),
         {:ok, _} <- verify_size(response, byte_size(response.body)) do
      {:ok, response.body}
    else
      false -> error("invalid_response")
      result -> result
    end
  end

  @spec upload_multipart(map() | struct(), source(), keyword()) ::
          result([%{part_number: pos_integer(), etag: String.t()}])
  def upload_multipart(intent, source, options \\ []) do
    concurrency = Keyword.get(options, :concurrency, 4)

    with true <- is_integer(concurrency) and concurrency > 0,
         {:ok, size} <- Source.size(source),
         {:ok, parts} <- multipart_ranges(intent, size) do
      parts
      |> Task.async_stream(
        fn {part, start, length} ->
          with {:ok, response} <-
                 request(
                   :put,
                   field(part, :upload_url),
                   field(intent, :required_headers) || %{},
                   Source.stream(source, start, length),
                   length,
                   nil,
                   options
                 ),
               etag when is_binary(etag) and etag != "" <- Error.header(response.headers, "etag") do
            {:ok, %{part_number: field(part, :part_number), etag: etag}}
          else
            {:error, error} -> {:error, error}
            _ -> error("missing_etag")
          end
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, part}}, {:ok, parts} -> {:cont, {:ok, [part | parts]}}
        {:ok, {:error, error}}, _ -> {:halt, {:error, error}}
        _, _ -> {:halt, error("network_error")}
      end)
      |> case do
        {:ok, parts} -> {:ok, Enum.sort_by(parts, & &1.part_number)}
        result -> result
      end
    else
      false -> error("invalid_concurrency")
      result -> result
    end
  end

  @doc false
  def multipart_ranges(intent, size) do
    multipart = field(intent, :multipart)
    part_size = field(multipart, :part_size)
    parts = field(multipart, :parts)

    cond do
      field(intent, :upload_strategy) != "multipart" or not is_integer(size) or size <= 0 or
        not is_integer(part_size) or part_size <= 0 or not is_list(parts) ->
        error("invalid_upload_intent")

      length(parts) != div(size + part_size - 1, part_size) ->
        error("size_mismatch")

      true ->
        parts = Enum.sort_by(parts, &field(&1, :part_number))

        valid =
          Enum.with_index(parts, 1)
          |> Enum.all?(fn {part, number} ->
            field(part, :part_number) == number and valid_url?(field(part, :upload_url))
          end)

        if valid do
          {:ok,
           Enum.with_index(parts)
           |> Enum.map(fn {part, index} ->
             offset = index * part_size
             {part, offset, min(part_size, size - offset)}
           end)}
        else
          error("invalid_upload_intent")
        end
    end
  end

  @doc false
  def field(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      :__aether_unset__ -> nil
      value -> value
    end
  end

  def field(_, _), do: nil

  defp request(method, url, headers, body, size, into, options) do
    timeout = Keyword.get(options, :timeout, 15_000)

    cond do
      not is_integer(timeout) or timeout <= 0 ->
        error("invalid_timeout")

      not valid_url?(url) ->
        error("invalid_upload_intent")

      not valid_headers?(headers) ->
        error("invalid_provider_headers")

      cancelled?(options) ->
        error("aborted")

      true ->
        task =
          Task.async(fn ->
            try do
              provider_options =
                Keyword.take(Keyword.get(options, :req_options, []), @connection_options)

              request =
                Req.new(
                  provider_options ++
                    [
                      method: method,
                      url: url,
                      headers: headers,
                      body: body,
                      into: into,
                      raw: true,
                      retry: false,
                      redirect: false,
                      receive_timeout: timeout,
                      retry_log_level: false,
                      redirect_log_level: false,
                      http_errors: :return,
                      compressed: false,
                      compress_body: false,
                      auth: nil
                    ]
                )

              # Remove implicit headers/URL rewriting; only provider instructions are used.
              request = %{
                request
                | headers: Req.new(headers: headers).headers,
                  request_steps:
                    Keyword.drop(
                      request.request_steps,
                      [
                        :put_user_agent,
                        :compressed,
                        :auth,
                        :put_params,
                        :put_base_url,
                        :put_path_params,
                        :put_range
                      ]
                    )
              }

              request =
                if size,
                  do: Req.Request.put_header(request, "content-length", Integer.to_string(size)),
                  else: request

              Req.request(request)
            rescue
              _ -> error("network_error")
            catch
              _, _ -> error("network_error")
            end
          end)

        watch_owner(task, self())
        await(task, System.monotonic_time(:millisecond) + timeout, options)
    end
  end

  # A Task.async link does not stop a task when its caller exits normally.
  # Keep the provider request owned by the caller even in that case.
  defp watch_owner(task, owner) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      task_ref = Process.monitor(task.pid)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(task.pid, :kill)
        {:DOWN, ^task_ref, :process, _, _} -> :ok
      end
    end)
  end

  defp await(task, deadline, options) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      cancelled?(options) ->
        Task.shutdown(task, :brutal_kill)
        error("aborted")

      remaining <= 0 ->
        Task.shutdown(task, :brutal_kill)
        error("request_timeout")

      true ->
        case Task.yield(task, min(remaining, 25)) do
          nil -> await(task, deadline, options)
          {:ok, {:ok, %{status: status} = response}} when status in 200..299 -> {:ok, response}
          {:ok, {:ok, %{status: status}}} -> error("transfer_failed", status: status)
          {:ok, {:error, %Error{} = error}} -> {:error, error}
          {:ok, {:error, %Req.TransportError{reason: :timeout}}} -> error("request_timeout")
          _ -> error("network_error")
        end
    end
  end

  defp verify_size(response, count) do
    case Error.header(response.headers, "content-length") do
      nil ->
        {:ok, count}

      value ->
        if Integer.parse(value) == {count, ""}, do: {:ok, count}, else: error("size_mismatch")
    end
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}} ->
        scheme in ["http", "https"] and is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  defp valid_headers?(headers) when is_map(headers) or is_list(headers) do
    Enum.all?(headers, fn {key, value} ->
      is_binary(key) and is_binary(value) and String.downcase(String.trim(key)) not in @forbidden
    end)
  end

  defp valid_headers?(_), do: false
  defp cancelled?(options), do: Keyword.get(options, :cancelled?, fn -> false end).()

  defp error(code, attrs \\ []),
    do: {:error, Error.new(code, "Aether storage transfer failed", attrs)}
end
