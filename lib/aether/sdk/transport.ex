defmodule Aether.SDK.Transport do
  @moduledoc false
  alias Aether.SDK.{AccessToken, Client, Error, HTTP, Schema}

  @settings [
    :timeout,
    :max_retries,
    :request_id,
    :correlation_id,
    :idempotency_key,
    :cancelled?,
    :auth,
    :sensitive,
    :retry
  ]

  def request(client, operation, request, options \\ []) do
    with :ok <- settings(options),
         {:ok, _} <- Client.validate_url(client.base_url),
         {:ok, envelope} <- envelope(request),
         {:ok, path} <- parameters(operation, "path", envelope["path"] || %{}),
         {:ok, query} <- parameters(operation, "query", envelope["query"] || %{}),
         {:ok, headers} <- request_headers(operation, envelope["headers"] || %{}, options),
         {:ok, body} <- body(operation, envelope),
         {:ok, url} <- build_url(client.base_url, operation.path, path, query),
         {:ok, serialized} <- serialize(body, operation.content_type) do
      timeout = Keyword.get(options, :timeout, client.timeout)
      retries = Keyword.get(options, :max_retries, client.max_retries)
      safe = Keyword.get(options, :retry, true) and retry_safe?(operation, headers, body)
      run(client, operation, url, serialized, headers, options, timeout, retries, safe, 1, false)
    end
    |> sanitize(options)
  end

  defp settings(options) do
    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in @settings)) and
         (not Keyword.has_key?(options, :timeout) or
            (is_integer(options[:timeout]) and options[:timeout] > 0)) and
         (not Keyword.has_key?(options, :max_retries) or
            (is_integer(options[:max_retries]) and options[:max_retries] >= 0)) and
         (not Keyword.has_key?(options, :cancelled?) or is_function(options[:cancelled?], 0)) and
         (not Keyword.has_key?(options, :retry) or is_boolean(options[:retry])) and
         (not Keyword.has_key?(options, :sensitive) or is_boolean(options[:sensitive])),
       do: :ok,
       else: invalid("invalid_request_options")
  end

  defp envelope(request) when is_map(request) do
    with {:ok, normalized} <- Schema.encode(%{"type" => "object"}, request) do
      if Enum.all?(Map.keys(normalized), &(&1 in ~w(path query body headers))),
        do: {:ok, normalized},
        else: invalid("invalid_request")
    end
  end

  defp envelope(_), do: invalid("invalid_request")

  defp parameters(operation, location, values) when is_map(values) do
    params = Enum.filter(operation.parameters, &(&1["in"] == location))
    allowed = Map.new(params, &{&1["name"], &1["schema"] || %{}})
    required = for param <- params, param["required"], do: param["name"]

    Schema.encode(
      %{
        "type" => "object",
        "properties" => allowed,
        "required" => required,
        "additionalProperties" => false
      },
      values
    )
  end

  defp parameters(_, _, _), do: invalid("invalid_request")

  defp request_headers(operation, values, options) when is_map(values) do
    values = Map.new(values, fn {key, value} -> {String.downcase(to_string(key)), value} end)

    values =
      Enum.reduce(
        [
          request_id: "x-request-id",
          correlation_id: "x-correlation-id",
          idempotency_key: "idempotency-key"
        ],
        values,
        fn {option, header}, acc ->
          if options[option], do: Map.put(acc, header, options[option]), else: acc
        end
      )

    allowed =
      Enum.filter(operation.parameters, &(&1["in"] == "header"))
      |> Map.new(&{String.downcase(&1["name"]), &1["schema"] || %{"type" => "string"}})
      |> Map.merge(%{"x-request-id" => header_schema(), "x-correlation-id" => header_schema()})

    required =
      for param <- operation.parameters,
          param["in"] == "header" and param["required"],
          do: String.downcase(param["name"])

    with {:ok, headers} <-
           Schema.encode(
             %{
               "type" => "object",
               "properties" => allowed,
               "required" => required,
               "additionalProperties" => false
             },
             values
           ) do
      {:ok,
       Map.put_new(
         headers,
         "x-request-id",
         "req_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
       )}
    end
  end

  defp request_headers(_, _, _), do: invalid("invalid_request")

  defp header_schema,
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 128,
      "pattern" => "^[A-Za-z0-9._-]+$"
    }

  defp body(operation, envelope) do
    cond do
      not Map.has_key?(envelope, "body") and Map.get(operation, :request_required, false) ->
        invalid("invalid_request")

      not Map.has_key?(envelope, "body") ->
        {:ok, nil}

      is_nil(operation.request_schema) ->
        invalid("invalid_request")

      true ->
        Schema.encode(operation.request_schema, envelope["body"])
    end
  end

  defp serialize(nil, _), do: {:ok, nil}

  defp serialize(body, "application/x-www-form-urlencoded") do
    {:ok, URI.encode_query(body)}
  end

  defp serialize(body, _) do
    case Jason.encode(body) do
      {:ok, encoded} -> {:ok, encoded}
      _ -> invalid("invalid_request")
    end
  end

  def build_url(base, path, values, query) do
    names = Regex.scan(~r/\{([^}]+)\}/, path) |> Enum.map(&List.last/1)

    if Enum.all?(names, &Map.has_key?(values, &1)) do
      path =
        Enum.reduce(names, path, fn key, url ->
          String.replace(
            url,
            "{" <> key <> "}",
            URI.encode(to_string(values[key]), &URI.char_unreserved?/1)
          )
        end)

      query =
        query
        |> Enum.sort()
        |> Enum.map_join("&", fn {key, value} ->
          URI.encode(to_string(key), &URI.char_unreserved?/1) <>
            "=" <>
            URI.encode(to_string(value), &URI.char_unreserved?/1)
        end)

      {:ok,
       String.trim_trailing(base, "/") <> path <> if(query == "", do: "", else: "?" <> query)}
    else
      invalid("missing_path_parameter")
    end
  end

  def retry_safe?(operation, headers, body) do
    cond do
      operation.method in [:get, :head, :options] ->
        true

      operation.idempotency in ["required", "optional"] ->
        nonempty?(headers["idempotency-key"])

      operation.idempotency == "request_field" ->
        is_map(body) and nonempty?(body["idempotency_key"])

      true ->
        false
    end
  end

  def retryable?(%Error{status: 0, code: code}),
    do: code in ~w(network_error request_timeout token_request_failed)

  def retryable?(%Error{status: status}) when status in [502, 503, 504], do: true
  def retryable?(%Error{status: 429, code: code}), do: String.downcase(code) == "rate_limited"
  def retryable?(_), do: false

  defp run(
         client,
         operation,
         url,
         body,
         headers,
         options,
         timeout,
         retries,
         safe,
         attempt,
         refreshed
       ) do
    cancelled? = Keyword.get(options, :cancelled?, fn -> false end)
    start = System.monotonic_time()

    result =
      if cancelled?.() do
        invalid("request_aborted")
      else
        with {:ok, auth} <-
               HTTP.run_fun(fn -> authenticate(client, options) end, timeout, cancelled?) do
          headers =
            Map.merge(headers, %{
              "accept" => "application/json",
              "user-agent" => client.user_agent
            })

          headers = if auth, do: Map.put(headers, "authorization", auth), else: headers

          headers =
            if body,
              do: Map.put(headers, "content-type", operation.content_type || "application/json"),
              else: headers

          req =
            Keyword.merge(client.req_options,
              method: operation.method,
              url: url,
              headers: headers
            )

          req = if body, do: Keyword.put(req, :body, body), else: req

          remaining =
            timeout -
              System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

          if remaining > 0,
            do: HTTP.run(req, remaining, cancelled?) |> response(operation, attempt),
            else: invalid("request_timeout")
        end
      end

    result =
      case result do
        {:error, error} -> {:error, %{error | attempts: attempt}}
        other -> other
      end

    status =
      case result do
        {:ok, _} -> :ok
        {:error, error} -> error.status
      end

    :telemetry.execute(
      [:aether, :sdk, :request, :stop],
      %{duration: System.monotonic_time() - start},
      %{operation: operation.name, platform: operation.platform, attempt: attempt, status: status}
    )

    refresh =
      case result do
        {:error, %Error{status: 401}} when not refreshed -> invalidate(client, options)
        _ -> false
      end

    case result do
      {:error, %Error{} = error} when safe and attempt <= retries ->
        if refresh or retryable?(error) do
          delay = if refresh, do: 0, else: retry_delay(error, attempt)

          :telemetry.execute([:aether, :sdk, :request, :retry], %{delay: delay}, %{
            operation: operation.name,
            platform: operation.platform,
            attempt: attempt,
            status: error.status
          })

          case wait(delay, cancelled?) do
            :ok ->
              run(
                client,
                operation,
                url,
                body,
                headers,
                options,
                timeout,
                retries,
                safe,
                attempt + 1,
                refreshed or refresh
              )

            {:error, error} ->
              {:error, %{error | attempts: attempt}}
          end
        else
          result
        end

      _ ->
        result
    end
  end

  defp response({:error, _} = error, _, _), do: error

  defp response({:ok, response}, operation, attempt) do
    decoded = if response.body in ["", nil], do: {:ok, nil}, else: Jason.decode(response.body)

    if response.status in operation.success_statuses do
      with {:ok, value} <- decoded,
           {:ok, result} <- Schema.decode(operation.response_schemas[response.status], value) do
        {:ok, result}
      else
        _ ->
          {:error,
           Error.new("invalid_response", "Aether returned an invalid response",
             status: response.status,
             attempts: attempt
           )}
      end
    else
      body =
        case decoded do
          {:ok, body} -> body
          _ -> nil
        end

      {:error, Error.from_response(response.status, response.headers, body, attempt)}
    end
  end

  defp authenticate(client, options) do
    case Keyword.get(options, :auth, :client) do
      :none ->
        {:ok, nil}

      {:basic, id, secret} when is_binary(id) and is_binary(secret) ->
        {:ok,
         "Basic " <> Base.encode64(URI.encode_www_form(id) <> ":" <> URI.encode_www_form(secret))}

      {:bearer, token} when is_binary(token) ->
        {:ok, "Bearer " <> token}

      :client ->
        client_token(client)

      _ ->
        invalid("invalid_configuration")
    end
  end

  defp client_token(%{token: token}) when is_binary(token), do: {:ok, "Bearer " <> token}

  defp client_token(%{token_provider: {module, state}}) do
    try do
      case module.get_token(state) do
        {:ok, %AccessToken{value: value}} when is_binary(value) and value != "" ->
          {:ok, "Bearer " <> value}

        {:error, %Error{} = error} ->
          {:error, Error.sanitize(error)}

        _ ->
          invalid("invalid_token_response")
      end
    rescue
      _ -> invalid("token_request_failed")
    catch
      _, _ -> invalid("token_request_failed")
    end
  end

  defp client_token(_), do: invalid("invalid_configuration")

  defp invalidate(client, options) do
    try do
      case {Keyword.get(options, :auth, :client), Map.get(client, :token_provider)} do
        {:client, {module, state}} ->
          if function_exported?(module, :invalidate, 1),
            do: module.invalidate(state) == :ok,
            else: false

        _ ->
          false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp retry_delay(error, attempt) do
    case Map.fetch(error.retry, :retry_after_seconds) do
      {:ok, seconds} when is_integer(seconds) and seconds >= 0 -> seconds * 1000
      _ -> min(100 * Integer.pow(2, min(attempt - 1, 4)), 1000)
    end
  end

  defp wait(0, cancelled?), do: if(cancelled?.(), do: invalid("request_aborted"), else: :ok)

  defp wait(remaining, cancelled?) do
    if cancelled?.(),
      do: invalid("request_aborted"),
      else:
        (
          Process.sleep(min(remaining, 25))
          wait(max(remaining - 25, 0), cancelled?)
        )
  end

  defp sanitize({:error, error}, options),
    do: {:error, if(options[:sensitive] == true, do: Error.sanitize(error), else: error)}

  defp sanitize(result, _), do: result
  defp invalid(code), do: {:error, Error.new(code, "Invalid Aether request or configuration")}
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
