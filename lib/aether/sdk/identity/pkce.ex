defmodule Aether.SDK.Identity.PKCE do
  @moduledoc "An S256 proof. Store the verifier privately until code exchange."
  @derive {Inspect, only: [:code_challenge_method]}
  @enforce_keys [:code_verifier, :code_challenge]
  defstruct [:code_verifier, :code_challenge, code_challenge_method: "S256"]

  @type t :: %__MODULE__{
          code_verifier: String.t(),
          code_challenge: String.t(),
          code_challenge_method: String.t()
        }

  @spec generate() :: t()
  def generate do
    verifier = generate_state()

    %__MODULE__{
      code_verifier: verifier,
      code_challenge: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    }
  end

  @spec generate_state() :: String.t()
  def generate_state, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end

defmodule Aether.SDK.Identity.CallbackAuthorized do
  @moduledoc "A validated OAuth callback. Exchange the code using the saved PKCE verifier."
  @derive {Inspect, only: [:status]}
  defstruct [:code, :state, status: "authorized"]
  @type t :: %__MODULE__{code: String.t(), state: String.t(), status: String.t()}
end

defmodule Aether.SDK.Identity.CallbackDenied do
  @moduledoc "A validated OAuth error callback. Remote descriptions are discarded."
  @derive {Inspect, only: [:status, :error]}
  defstruct [:error, :state, status: "denied"]
  @type t :: %__MODULE__{error: String.t(), state: String.t(), status: String.t()}
end
