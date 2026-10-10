defmodule Aether.SDK.Error do
  @moduledoc "A safe, structured API or transport failure. Retry timing is in seconds."
  @derive {Inspect, only: [:status, :code, :attempts]}
  defexception status: 0,
               code: "request_failed",
               message: "Aether request failed",
               request_id: nil,
               details: nil,
               retry: %{},
               attempts: 1,
               cause: nil

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          code: String.t(),
          message: String.t(),
          request_id: String.t() | nil,
          details: term(),
          retry: map(),
          attempts: pos_integer(),
          cause: term()
        }

  def new(code, message, attrs \\ []),
    do: struct!(__MODULE__, Keyword.merge([code: to_string(code), message: message], attrs))

  def from_response(status, headers, body, attempts \\ 1) do
    envelope = if is_map(body), do: body["error"], else: nil
    attrs = if is_map(envelope), do: envelope, else: %{}

    code =
      cond do
        is_binary(envelope) and envelope != "" -> envelope
        is_binary(attrs["code"]) and attrs["code"] != "" -> attrs["code"]
        true -> "request_failed"
      end

    message = text(attrs["message"]) || "Aether request failed with HTTP #{status}"
    request_id = text(header(headers, "x-request-id")) || text(attrs["request_id"])

    new(code, message,
      status: status,
      request_id: request_id,
      details: attrs["details"],
      attempts: attempts,
      retry: retry_metadata(headers)
    )
  end

  @safe_auth_codes ~w(invalid_request invalid_passwordless_request invalid_client invalid_grant invalid_scope unauthorized_client unsupported_grant_type access_denied invalid_target token_issuance_unavailable invalid_code code_already_used code_expired invalid_redirect_uri invalid_code_verifier invalid_token origin_not_allowed custom_completion_not_allowed rate_limited temporarily_unavailable identity_role_unavailable revocation_backend_unavailable request_failed request_timeout network_error request_aborted invalid_response invalid_token_response)
  def sanitize(%__MODULE__{} = error) do
    code =
      if String.downcase(error.code) in @safe_auth_codes, do: error.code, else: "request_failed"

    %{
      error
      | code: code,
        message: "Aether authentication request failed",
        request_id: nil,
        details: nil,
        cause: nil,
        retry:
          Map.take(error.retry, [
            :retry_after_seconds,
            :rate_limit_limit,
            :rate_limit_remaining,
            :rate_limit_reset
          ])
    }
  end

  def header(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def header(headers, key) when is_list(headers),
    do: headers |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end) |> header(key)

  defp retry_metadata(headers) do
    Enum.reduce(
      [
        {"retry-after", :retry_after_seconds},
        {"ratelimit-limit", :rate_limit_limit},
        {"ratelimit-remaining", :rate_limit_remaining},
        {"ratelimit-reset", :rate_limit_reset}
      ],
      %{},
      fn {key, field}, acc ->
        case Integer.parse(header(headers, key) || "") do
          {value, ""} when value >= 0 -> Map.put(acc, field, value)
          _ -> acc
        end
      end
    )
    |> then(fn retry ->
      if value = header(headers, "quota-reset"),
        do: Map.put(retry, :quota_reset, value),
        else: retry
    end)
  end

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(_), do: nil
end
