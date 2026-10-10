defmodule Aether.SDK.Client do
  @moduledoc "Explicit HTTP configuration for a public Aether platform. Tokens remain application-controlled."
  alias Aether.SDK.Error
  @derive {Inspect, only: [:timeout, :max_retries]}
  defstruct [
    :base_url,
    :token,
    :token_provider,
    timeout: 15_000,
    max_retries: 2,
    req_options: [],
    user_agent: "aether-elixir/0.1.0-beta.1"
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t() | nil,
          token_provider: term(),
          timeout: pos_integer(),
          max_retries: non_neg_integer(),
          req_options: keyword(),
          user_agent: String.t()
        }

  def new(options) when is_list(options) do
    with :ok <- validate_options(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 not in [:client_id, :client_secret])),
         {:ok, _} <- validate_url(options[:base_url]) do
      if (is_binary(options[:token]) and String.trim(options[:token]) != "") or
           options[:token_provider] != nil do
        {:ok, struct!(__MODULE__, options)}
      else
        {:error, Error.new("invalid_configuration", "A token or token provider is required")}
      end
    else
      false -> invalid_config()
      error -> error
    end
  end

  def new(_),
    do: {:error, Error.new("invalid_configuration", "Client options must be a keyword list")}

  @doc false
  def validate_options(options) do
    if Keyword.keyword?(options), do: valid_options(options), else: invalid_config()
  end

  defp valid_options(options) do
    timeout = Keyword.get(options, :timeout, 15_000)
    retries = Keyword.get(options, :max_retries, 2)

    allowed = [
      :base_url,
      :token,
      :token_provider,
      :timeout,
      :max_retries,
      :req_options,
      :user_agent,
      :client_id,
      :client_secret
    ]

    cond do
      not Keyword.keyword?(options) or Enum.any?(Keyword.keys(options), &(&1 not in allowed)) ->
        invalid_config()

      not is_integer(timeout) or timeout <= 0 ->
        invalid_config()

      not is_integer(retries) or retries < 0 ->
        invalid_config()

      not Keyword.keyword?(Keyword.get(options, :req_options, [])) ->
        invalid_config()

      Enum.any?(
        Keyword.keys(Keyword.get(options, :req_options, [])),
        &(&1 not in [:plug, :finch, :connect_options, :pool_timeout])
      ) ->
        invalid_config()

      not is_binary(Keyword.get(options, :user_agent, "aether-elixir")) ->
        invalid_config()

      options[:token] != nil and options[:token_provider] != nil ->
        invalid_config()

      options[:token_provider] != nil and not valid_provider?(options[:token_provider]) ->
        invalid_config()

      true ->
        :ok
    end
  end

  defp valid_provider?({module, _state}) when is_atom(module), do: true
  defp valid_provider?(_), do: false

  @doc false
  def validate_url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error,
         Error.new(
           "invalid_configuration",
           "An absolute HTTP base URL without credentials, query or fragment is required"
         )}
    end
  end

  def validate_url(_), do: invalid_config()

  defp invalid_config,
    do: {:error, Error.new("invalid_configuration", "Invalid client configuration")}
end
