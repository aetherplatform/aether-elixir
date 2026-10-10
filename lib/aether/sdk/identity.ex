defmodule Aether.SDK.Identity do
  @moduledoc """
  Public passwordless, OAuth and OIDC operations.

  Configuration is explicit. Use `new/1` for discovery or a registered public
  client and `confidential/1` for a server with registered credentials. The
  consumer owns verifier, transaction, token and application-session storage.
  OAuth tokens are opaque; use authenticated `get_user_info/3` for user claims.

  Request maps use contract field names, as strings or atoms. Generated request
  structs are accepted. Functions return `{:ok, result}` or `{:error, error}`.
  `authorize/3` returns the browser authorization URL without making a request.
  No OTP, completion, token exchange, refresh or revocation is retried.
  """

  alias Aether.SDK.{Client, Error, Schema, Transport}
  alias Aether.SDK.Generated.Identity, as: Catalog
  alias Aether.SDK.Identity.{CallbackAuthorized, CallbackDenied, PKCE}

  @derive {Inspect, only: [:client_id, :mode, :timeout, :max_retries]}
  defstruct [
    :base_url,
    :client_id,
    :client_secret,
    mode: :public,
    timeout: 15_000,
    max_retries: 2,
    req_options: [],
    user_agent: "aether-elixir/0.1.0-beta.1"
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          mode: :public | :confidential,
          timeout: pos_integer(),
          max_retries: non_neg_integer(),
          req_options: keyword(),
          user_agent: String.t()
        }
  @type result :: {:ok, term()} | {:error, Error.t()}
  @verifier ~r/\A[A-Za-z0-9._~-]{43,128}\z/
  @challenge ~r/\A[A-Za-z0-9_-]{43}\z/
  @otp ~r/\A[0-9]{6}\z/
  @oauth_errors ~w(access_denied invalid_request unauthorized_client unsupported_response_type invalid_scope server_error temporarily_unavailable)
  @endpoints %{
    "authorization_endpoint" => "/oauth/authorize",
    "token_endpoint" => "/oauth/token",
    "userinfo_endpoint" => "/oauth/userinfo",
    "revocation_endpoint" => "/oauth/revoke",
    "introspection_endpoint" => "/oauth/introspect",
    "jwks_uri" => "/.well-known/jwks.json"
  }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    allowed = [:base_url, :client_id, :timeout, :max_retries, :req_options, :user_agent]

    with true <- Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)),
         :ok <- Client.validate_options(options),
         {:ok, uri} <- Client.validate_url(options[:base_url]),
         true <- is_nil(options[:client_id]) or nonempty?(options[:client_id]) do
      {:ok, struct!(__MODULE__, Keyword.put(options, :base_url, origin(uri)))}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_config()
    end
  end

  def new(_), do: invalid_config()

  @spec confidential(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def confidential(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- nonempty?(options[:client_id]) and nonempty?(options[:client_secret]),
         {:ok, client} <- new(Keyword.delete(options, :client_secret)) do
      {:ok, %{client | mode: :confidential, client_secret: options[:client_secret]}}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_config()
    end
  end

  def confidential(_), do: invalid_config()

  @doc "Create a cryptographically random callback state, stored by the application."
  @spec generate_state() :: String.t()
  defdelegate generate_state(), to: PKCE

  @doc "Create a fresh S256 verifier/challenge pair. Never send the verifier to start."
  @spec generate_pkce() :: PKCE.t()
  def generate_pkce, do: PKCE.generate()

  @doc "Build the hosted OAuth authorization URL. This operation runs in a browser."
  @spec authorize(t(), map(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def authorize(client, request, options \\ []), do: authorization_url(client, request, options)

  @spec authorization_url(t(), map(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def authorization_url(%__MODULE__{} = client, request, _options \\ []) do
    with {:ok, body} <- normalize(request),
         :ok <-
           only_keys(
             body,
             ~w(client_id redirect_uri scope state nonce code_challenge code_challenge_method response_type)
           ),
         {:ok, id} <- client_id(client, body),
         {:ok, _} <- redirect_uri(body["redirect_uri"]),
         true <- nonempty?(body["scope"]) and bounded?(body["state"]),
         true <- is_nil(body["nonce"]) or bounded?(body["nonce"]),
         true <- pattern?(@challenge, body["code_challenge"]),
         true <- Map.get(body, "code_challenge_method", "S256") == "S256",
         true <- Map.get(body, "response_type", "code") == "code" do
      query =
        body
        |> Map.put("client_id", id)
        |> Map.put("response_type", "code")
        |> Map.put("code_challenge_method", "S256")
        |> URI.encode_query()

      {:ok, client.base_url <> "/oauth/authorize?" <> query}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_request()
    end
  end

  @doc "Validate exact callback URL, original state and one success/error result."
  @spec validate_callback(String.t(), String.t(), String.t()) :: result()
  def validate_callback(callback_url, registered_redirect, expected_state) do
    with true <- nonempty?(expected_state),
         {:ok, _} <- redirect_uri(registered_redirect),
         {:ok, callback} <- parse_uri(callback_url),
         true <- is_nil(callback.userinfo) and is_nil(callback.fragment),
         true <- hd(String.split(callback_url, "?", parts: 2)) == registered_redirect,
         {:ok, query} <- unique_query(callback.query),
         :ok <- only_keys(query, ~w(code state error error_description error_uri)),
         true <- secure_equal?(query["state"], expected_state) do
      callback_result(query)
    else
      _ -> {:error, Error.new("invalid_callback", "OAuth callback or state does not match")}
    end
  end

  @doc "Fetch and validate metadata against the configured Identity origin."
  @spec get_open_id_configuration(t(), map(), keyword()) :: result()
  def get_open_id_configuration(client, request \\ %{}, options \\ []) do
    with {:ok, result} <- read(client, :get_open_id_configuration, request, options),
         true <- valid_discovery?(client, result) do
      {:ok, result}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_response()
    end
  end

  @spec get_oauth_jwks(t(), map(), keyword()) :: result()
  def get_oauth_jwks(client, request \\ %{}, options \\ []) do
    with {:ok, result} <- read(client, :get_oauth_jwks, request, options),
         true <- is_list(field(result, :keys)) and field(result, :keys) != [] do
      {:ok, result}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_response()
    end
  end

  @spec list_oauth_scopes(t(), map(), keyword()) :: result()
  def list_oauth_scopes(client, request \\ %{}, options \\ []),
    do: read(client, :list_oauth_scopes, request, options)

  @doc "Fetch claims using a user access token. Machine tokens do not identify users."
  @spec get_user_info(t(), map(), keyword()) :: result()
  def get_user_info(%__MODULE__{} = client, request, options \\ []) do
    with {:ok, body} <- normalize(request),
         :ok <- only_keys(body, ~w(access_token)),
         true <- nonempty?(body["access_token"]),
         {:ok, result} <-
           call(client, :get_user_info, %{query: hint(client.client_id)}, options,
             auth: {:bearer, body["access_token"]},
             sensitive: true
           ),
         true <- nonempty?(field(result, :sub)) do
      {:ok, result}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_request()
    end
  end

  @doc "Exchange a code, rotate a refresh token, or request a confidential machine grant."
  @spec exchange_oauth_token(t(), map(), keyword()) :: result()
  def exchange_oauth_token(%__MODULE__{} = client, request, options \\ []) do
    with {:ok, body} <- normalize(request),
         :ok <-
           only_keys(
             body,
             ~w(client_id grant_type code redirect_uri code_verifier refresh_token audience scope)
           ),
         {:ok, id} <- client_id(client, body),
         :ok <- validate_grant(client, body),
         {:ok, body} <- encode(:exchange_oauth_token, Map.put(body, "client_id", id)),
         {:ok, result} <- mutation(client, :exchange_oauth_token, body, options),
         true <-
           nonempty?(field(result, :access_token)) and field(result, :token_type) == "Bearer",
         true <- is_integer(field(result, :expires_in)) and field(result, :expires_in) > 0 do
      {:ok, result}
    else
      {:error, error} ->
        {:error, error}

      _ ->
        {:error,
         Error.new("invalid_token_response", "Identity returned an invalid token response")}
    end
  end

  @spec revoke_oauth_token(t(), map(), keyword()) :: result()
  def revoke_oauth_token(client, request, options \\ []),
    do: token_handle(client, :revoke_oauth_token, request, options)

  @spec introspect_oauth_token(t(), map(), keyword()) :: result()
  def introspect_oauth_token(client, request, options \\ [])

  def introspect_oauth_token(%__MODULE__{mode: :confidential} = client, request, options),
    do: token_handle(client, :introspect_oauth_token, request, options)

  def introspect_oauth_token(_, _, _),
    do:
      {:error,
       Error.new("unauthorized_client", "Token introspection requires a confidential client")}

  @doc "Send or explicitly resend an OTP. Respect the returned resend_after seconds."
  @spec start_passwordless(t(), map(), keyword()) :: result()
  def start_passwordless(client, request, options \\ []),
    do: passwordless(client, :start_passwordless, request, options)

  @spec verify_passwordless(t(), map(), keyword()) :: result()
  def verify_passwordless(client, request, options \\ []),
    do: passwordless(client, :verify_passwordless, request, options)

  @doc "Submit approved custom completion. Availability is decided by the registered client policy."
  @spec complete_passwordless(t(), map(), keyword()) :: result()
  def complete_passwordless(client, request, options \\ []),
    do: passwordless(client, :complete_passwordless, request, options)

  @doc "Return a validated hosted completion URL for the application's browser handoff."
  @spec continuation_url(t(), map()) :: result()
  def continuation_url(%__MODULE__{} = client, result) do
    if field(result, :status) == "hosted_completion_required" and valid_outcome?(client, result),
      do: {:ok, field(result, :continuation_url)},
      else: invalid_response()
  end

  defp read(client, operation, request, options) do
    with {:ok, body} <- normalize(request),
         true <- map_size(body) == 0 do
      call(client, operation, %{}, options, auth: :none)
    else
      _ -> invalid_request()
    end
  end

  defp token_handle(client, operation, request, options) do
    with {:ok, body} <- normalize(request),
         :ok <- only_keys(body, ~w(client_id token token_type_hint)),
         {:ok, id} <- client_id(client, body),
         true <- nonempty?(body["token"]),
         {:ok, body} <- encode(operation, Map.put(body, "client_id", id)) do
      mutation(client, operation, body, options)
    else
      {:error, error} -> {:error, error}
      _ -> invalid_request()
    end
  end

  defp passwordless(client, operation, request, options) do
    with {:ok, body} <- normalize(request),
         {:ok, id} <- client_id(client, body),
         {:ok, body} <- encode(operation, Map.put(body, "client_id", id)),
         :ok <- validate_passwordless(operation, body),
         {:ok, result} <- mutation(client, operation, body, options),
         true <- valid_passwordless_response?(client, operation, result) do
      {:ok, result}
    else
      {:error, error} -> {:error, error}
      _ -> invalid_response()
    end
  end

  defp encode(operation, body),
    do: Schema.encode(Catalog.operation(operation).request_schema, body)

  defp mutation(client, operation, body, options) do
    query = if operation == :introspect_oauth_token, do: %{}, else: hint(body["client_id"])

    call(client, operation, %{body: body, query: query}, options,
      auth: auth(client),
      retry: false,
      sensitive: true
    )
  end

  defp call(client, operation, request, options, security) do
    # Caller options cannot override Identity's authentication or single-attempt policy.
    Transport.request(
      client,
      Catalog.operation(operation),
      request,
      Keyword.merge(options, security)
    )
  end

  defp auth(%{mode: :confidential, client_id: id, client_secret: secret}),
    do: {:basic, id, secret}

  defp auth(_), do: :none
  defp hint(nil), do: %{}
  defp hint(id), do: %{"client_id" => id}

  defp client_id(client, body) do
    provided = body["client_id"]
    id = client.client_id || provided

    if nonempty?(id) and (is_nil(provided) or provided == id),
      do: {:ok, id},
      else: invalid_request()
  end

  defp validate_grant(client, body) do
    valid =
      case body["grant_type"] do
        "authorization_code" ->
          nonempty?(body["code"]) and pattern?(@verifier, body["code_verifier"]) and
            match?({:ok, _}, redirect_uri(body["redirect_uri"])) and
            Enum.all?(~w(refresh_token audience scope), &(not Map.has_key?(body, &1)))

        "refresh_token" ->
          nonempty?(body["refresh_token"]) and
            Enum.all?(
              ~w(code redirect_uri code_verifier audience scope),
              &(not Map.has_key?(body, &1))
            )

        "client_credentials" ->
          client.mode == :confidential and nonempty?(body["audience"]) and
            nonempty?(body["scope"]) and
            Enum.all?(
              ~w(code redirect_uri code_verifier refresh_token),
              &(not Map.has_key?(body, &1))
            )

        _ ->
          false
      end

    if valid, do: :ok, else: invalid_request()
  end

  defp validate_passwordless(:start_passwordless, body) do
    valid =
      nonempty?(body["identifier"]) and body["channel"] in ["email", "sms"] and
        pattern?(@challenge, body["code_challenge"]) and body["code_challenge_method"] == "S256" and
        match?({:ok, _}, redirect_uri(body["redirect_uri"])) and
        (not Map.has_key?(body, "state") or bounded?(body["state"])) and
        (not Map.has_key?(body, "nonce") or bounded?(body["nonce"]))

    if valid, do: :ok, else: invalid_request()
  end

  defp validate_passwordless(:verify_passwordless, body) do
    valid =
      Enum.all?(~w(transaction challenge_id identifier), &nonempty?(body[&1])) and
        body["channel"] in ["email", "sms"] and pattern?(@otp, body["code"]) and
        pattern?(@verifier, body["code_verifier"])

    if valid, do: :ok, else: invalid_request()
  end

  defp validate_passwordless(:complete_passwordless, body) do
    valid =
      nonempty?(body["continuation"]) and pattern?(@verifier, body["code_verifier"]) and
        body["decision"] in ["approve", "deny"]

    if valid, do: :ok, else: invalid_request()
  end

  defp valid_passwordless_response?(_, :start_passwordless, result) do
    nonempty?(field(result, :transaction)) and nonempty?(field(result, :challenge_id)) and
      field(result, :expires_in) == 300 and field(result, :transaction_expires_in) == 600 and
      field(result, :resend_after) in 1..300
  end

  defp valid_passwordless_response?(client, operation, result) do
    statuses =
      if operation == :verify_passwordless,
        do: ~w(authorized hosted_completion_required custom_completion_required),
        else: ~w(authorized denied)

    field(result, :status) in statuses and valid_outcome?(client, result)
  end

  defp valid_outcome?(client, result) do
    case field(result, :status) do
      "authorized" ->
        nonempty?(field(result, :code)) and nullable_string?(field(result, :state))

      "denied" ->
        field(result, :error) == "access_denied" and nullable_string?(field(result, :state))

      "hosted_completion_required" ->
        field(result, :expires_in) in 1..300 and
          valid_handoff?(client, field(result, :continuation_url))

      "custom_completion_required" ->
        required = field(result, :requirements)

        nonempty?(field(result, :continuation)) and field(result, :expires_in) in 1..300 and
          is_boolean(field(required, :registration)) and is_boolean(field(required, :consent)) and
          is_list(field(required, :scopes)) and Enum.all?(field(required, :scopes), &nonempty?/1) and
          if field(required, :registration),
            do:
              nonempty?(field(required, :aether_terms_version)) and
                nonempty?(field(required, :aether_privacy_version)),
            else:
              nullable_string?(field(required, :aether_terms_version)) and
                nullable_string?(field(required, :aether_privacy_version))

      _ ->
        false
    end
  end

  defp valid_handoff?(client, value) do
    with {:ok, uri} <- parse_uri(value),
         true <- origin(uri) == client.base_url and is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- uri.path == "/oauth/passwordless/continue",
         {:ok, %{"handoff" => handoff} = query} <- unique_query(uri.query) do
      map_size(query) == 1 and nonempty?(handoff)
    else
      _ -> false
    end
  end

  defp valid_discovery?(client, result) do
    with issuer when is_binary(issuer) <- field(result, :issuer),
         true <- String.trim_trailing(issuer, "/") == client.base_url do
      Enum.all?(@endpoints, fn {name, path} ->
        value = field(result, name)
        value == nil or value == :__aether_unset__ or value == client.base_url <> path
      end) and
        Enum.all?(
          [:response_types_supported, :grant_types_supported, :code_challenge_methods_supported],
          fn name ->
            values = field(result, name)
            is_list(values) and values != [] and Enum.all?(values, &nonempty?/1)
          end
        )
    else
      _ -> false
    end
  end

  defp callback_result(query) do
    cond do
      Map.has_key?(query, "code") and Map.has_key?(query, "error") ->
        invalid_callback()

      nonempty?(query["code"]) and
          not Enum.any?(~w(error error_description error_uri), &Map.has_key?(query, &1)) ->
        {:ok, %CallbackAuthorized{code: query["code"], state: query["state"]}}

      query["error"] in @oauth_errors and not Map.has_key?(query, "code") ->
        {:ok, %CallbackDenied{error: query["error"], state: query["state"]}}

      true ->
        invalid_callback()
    end
  end

  defp unique_query(value) when is_binary(value) do
    if Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value) do
      invalid_callback()
    else
      pairs = URI.query_decoder(value) |> Enum.to_list()
      map = Map.new(pairs)
      if map_size(map) == length(pairs), do: {:ok, map}, else: invalid_callback()
    end
  rescue
    ArgumentError -> invalid_callback()
  end

  defp unique_query(_), do: invalid_callback()

  defp redirect_uri(value) do
    with {:ok, uri} <- parse_uri(value),
         true <-
           nonempty?(uri.host) and is_nil(uri.userinfo) and is_nil(uri.query) and
             is_nil(uri.fragment),
         true <-
           uri.scheme == "https" or
             (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"]) do
      {:ok, uri}
    else
      _ -> invalid_request()
    end
  end

  defp parse_uri(value) when is_binary(value), do: URI.new(value)
  defp parse_uri(_), do: {:error, :invalid_uri}

  defp origin(uri),
    do: URI.to_string(%{uri | path: nil, query: nil, fragment: nil, userinfo: nil})

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal?(_, _), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp bounded?(value), do: nonempty?(value) and byte_size(value) <= 1024
  defp pattern?(pattern, value), do: is_binary(value) and Regex.match?(pattern, value)
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)

  defp field(value, key) when is_map(value) and is_atom(key),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp field(value, key) when is_map(value) and is_binary(key) do
    Enum.find_value(Map.to_list(value), fn {k, v} -> if to_string(k) == key, do: {:found, v} end)
    |> case do
      {:found, v} -> v
      nil -> nil
    end
  end

  defp field(_, _), do: nil

  defp normalize(%_{} = value), do: Schema.encode(%{}, value)

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {_, :__aether_unset__}, acc ->
        {:cont, acc}

      {key, value}, {:ok, acc} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(acc, key),
          do: {:halt, invalid_request()},
          else: {:cont, {:ok, Map.put(acc, key, value)}}

      _, _ ->
        {:halt, invalid_request()}
    end)
  end

  defp normalize(_), do: invalid_request()

  defp only_keys(body, keys),
    do: if(Enum.all?(Map.keys(body), &(&1 in keys)), do: :ok, else: invalid_request())

  defp invalid_request, do: {:error, Error.new("invalid_request", "Invalid Identity request")}

  defp invalid_response,
    do: {:error, Error.new("invalid_response", "Identity returned an invalid response")}

  defp invalid_callback, do: {:error, Error.new("invalid_callback", "Invalid OAuth callback")}

  defp invalid_config,
    do: {:error, Error.new("invalid_configuration", "Invalid Identity client configuration")}
end
