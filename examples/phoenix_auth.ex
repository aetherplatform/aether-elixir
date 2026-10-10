# Framework-neutral boundary illustration for a Phoenix controller.
# This example is not compiled with the SDK. Phoenix and Ecto are not SDK dependencies.
defmodule MyAppWeb.AetherAuthController do
  use MyAppWeb, :controller
  alias Aether.SDK.Identity

  def start(conn, _params) do
    client = MyApp.Aether.identity_client()
    proof = Identity.generate_pkce()
    state = Identity.generate_state()
    callback = MyApp.Aether.callback_url()

    {:ok, url} =
      Identity.authorize(client, %{
        redirect_uri: callback,
        scope: "openid profile email",
        code_challenge: proof.code_challenge,
        state: state
      })

    # Application-owned server-side storage: short expiry, single consumption.
    # Do not store the verifier in an unencrypted client-readable cookie.
    handle = MyApp.AuthTransactions.store(%{proof: proof, state: state, callback: callback})
    conn |> put_session(:aether_transaction, handle) |> redirect(external: url)
  end

  def callback(conn, _params) do
    handle = get_session(conn, :aether_transaction)
    conn = delete_session(conn, :aether_transaction)
    client = MyApp.Aether.identity_client()

    # consume/1 is an application-defined atomic, single-use lookup.
    with {:ok, tx} <- MyApp.AuthTransactions.consume(handle),
         {:ok, %Identity.CallbackAuthorized{code: code}} <-
           Identity.validate_callback(current_url(conn), tx.callback, tx.state),
         {:ok, tokens} <-
           Identity.exchange_oauth_token(client, %{
             grant_type: "authorization_code",
             code: code,
             redirect_uri: tx.callback,
             code_verifier: tx.proof.code_verifier
           }),
         {:ok, claims} <- Identity.get_user_info(client, %{access_token: tokens.access_token}),
         {:ok, account} <- MyApp.Accounts.resolve_aether_subject(claims.sub) do
      # Product account mapping, authorization and session creation belong to MyApp.
      MyAppWeb.UserAuth.log_in_user(conn, account)
    else
      _ -> conn |> put_flash(:error, "Sign-in could not be completed") |> redirect(to: "/login")
    end
  end
end
