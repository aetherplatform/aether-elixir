defmodule Aether.SDK.Webhooks.Signature do
  @moduledoc """
  Verify the Aether signature header against the exact raw request body before JSON decoding.
  Accepts one signing secret or a list of current/previous secrets for rotation.
  `:tolerance` defaults to 300 seconds; `:now` is an injectable Unix time in seconds.
  Successful verification returns `{:ok, %{timestamp: unix_seconds}}`.
  """
  alias Aether.SDK.Error

  @spec verify(binary(), String.t() | nil, binary() | [binary()], keyword()) ::
          {:ok, %{timestamp: non_neg_integer()}} | {:error, Error.t()}
  def verify(payload, header, secrets, options \\ []) do
    secrets = List.wrap(secrets)
    tolerance = Keyword.get(options, :tolerance, 300)
    now = Keyword.get(options, :now, System.system_time(:second))

    cond do
      not is_binary(payload) or secrets == [] or
          not Enum.all?(secrets, &(is_binary(&1) and &1 != "")) ->
        error("invalid_signature_options")

      not is_integer(tolerance) or tolerance < 0 or not is_integer(now) ->
        error("invalid_signature_options")

      true ->
        with {:ok, timestamp, signatures} <- parse(header),
             :ok <- recent(timestamp, now, tolerance) do
          expected =
            Enum.map(
              secrets,
              &:crypto.mac(:hmac, :sha256, &1, [Integer.to_string(timestamp), ".", payload])
            )

          # Evaluate every candidate, including during secret rotation.
          matches =
            for digest <- expected,
                signature <- signatures,
                do: :crypto.hash_equals(digest, signature)

          if Enum.any?(matches),
            do: {:ok, %{timestamp: timestamp}},
            else: error("invalid_signature")
        end
    end
  end

  defp recent(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance, do: :ok, else: error("timestamp_expired")
  end

  defp parse(header) when header in [nil, ""], do: error("missing_signature")

  defp parse(header) when is_binary(header) do
    parts = header |> String.split(",") |> Enum.map(&(String.trim(&1) |> String.split("=")))

    cond do
      not Enum.all?(parts, &valid_component?/1) ->
        error("invalid_signature_format")

      true ->
        times = for ["t", value] <- parts, do: value
        signatures = for ["v1", value] <- parts, do: Base.decode16!(value, case: :lower)

        cond do
          times == [] -> error("missing_timestamp")
          length(times) != 1 -> error("invalid_signature_format")
          signatures == [] -> error("missing_signature")
          true -> {:ok, String.to_integer(hd(times)), signatures}
        end
    end
  end

  defp parse(_), do: error("invalid_signature_format")

  defp valid_component?(["t", value]) do
    Regex.match?(~r/^(0|[1-9][0-9]{0,18})$/, value) and
      String.to_integer(value) <= 9_223_372_036_854_775_807
  end

  defp valid_component?(["v1", value]), do: Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp valid_component?(_), do: false
  defp error(code), do: {:error, Error.new(code, "Aether webhook signature verification failed")}
end
