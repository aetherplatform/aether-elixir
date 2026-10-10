defmodule Aether.SDK.AccessToken do
  @moduledoc "An opaque bearer token and its expiry as Unix milliseconds."
  @derive {Inspect, only: [:expires_at]}
  @enforce_keys [:value, :expires_at]
  defstruct [:value, :expires_at]
  @type t :: %__MODULE__{value: String.t(), expires_at: integer()}
end

defmodule Aether.SDK.TokenProvider do
  @moduledoc "Application-provided bearer credentials. Pass {module, state} as the client's token_provider."
  @callback get_token(term()) ::
              {:ok, Aether.SDK.AccessToken.t()} | {:error, Aether.SDK.Error.t()}
  @callback invalidate(term()) :: :ok
  @optional_callbacks invalidate: 1
end
