# Identity and passwordless

The same public protocol works from application backends, browsers and mobile
apps. The Elixir SDK leaves browser navigation, application sessions, PKCE
storage and token storage to the consumer. Do not decode an opaque access
token to infer identity; call authenticated userinfo.

## Hosted OAuth journey

Create a public or confidential Identity client. Fetch discovery with
`Identity.get_open_id_configuration(client)`; the SDK checks its issuer and
endpoint locations against the configured Identity origin. Generate fresh
PKCE and state for every authorization transaction.

```elixir
alias Aether.SDK.Identity

proof = Identity.generate_pkce()
state = Identity.generate_state()
redirect_uri = "https://app.example/auth/callback"
{:ok, authorization_url} = Identity.authorize(client, %{
  redirect_uri: redirect_uri,
  scope: "openid profile email",
  state: state,
  code_challenge: proof.code_challenge
})
```

Store the verifier, state and exact redirect URI in server-controlled,
transaction-specific storage. Redirect the browser to `authorization_url`.
On return, pass the complete callback URL to the helper:

```elixir
with {:ok, %Identity.CallbackAuthorized{code: code}} <-
       Identity.validate_callback(callback_url, redirect_uri, state),
     {:ok, tokens} <- Identity.exchange_oauth_token(client, %{
       grant_type: "authorization_code", code: code,
       redirect_uri: redirect_uri, code_verifier: proof.code_verifier
     }),
     {:ok, user} <- Identity.get_user_info(client, %{access_token: tokens.access_token}) do
  # Map user.sub into your local account model and establish your own session.
  {:ok, user}
end
```

A denial is `%Identity.CallbackDenied{error: "access_denied", state: state}`.
Callbacks with different redirects or states, duplicate parameters, fragments,
conflicting code/error results or malformed encoding are rejected. Consume
stored transaction data once, including after denial. Use registered HTTPS
callbacks, or explicitly registered development loopback callbacks.

## Send and verify a code

Passwordless must be enabled for the registered client and channel. Sending
again is an explicit user action using `start_passwordless/3`; wait for the
server-returned `resend_after` interval. Resending supersedes the pending code.

```elixir
{:ok, challenge} = Identity.start_passwordless(client, %{
  identifier: "person@example.test", channel: "email",
  redirect_uri: redirect_uri, scope: "openid profile email", state: state,
  code_challenge: proof.code_challenge, code_challenge_method: "S256"
})

{:ok, outcome} = Identity.verify_passwordless(client, %{
  transaction: challenge.transaction, challenge_id: challenge.challenge_id,
  identifier: "person@example.test", channel: "email", code: submitted_code,
  code_verifier: proof.code_verifier
})
```

The same contract supports `channel: "sms"`. Contract tests do not establish
that an SMS provider is configured. The transaction lasts ten minutes and a
code lasts five minutes; the current server supplies a configurable resend
interval. Respect `429` retry timing and require a new user action after expiry
or failure. The SDK never resends, verifies, completes, exchanges a code or
rotates a refresh token automatically.

## Handle completion explicitly

```elixir
alias Aether.SDK.Types.Identity, as: Results

case outcome do
  %Results.PasswordlessAuthorized{code: code, state: returned_state} ->
    # Check returned_state against stored state, then exchange code with the
    # original redirect URI and verifier through Identity.exchange_oauth_token.
    {:authorized, code, returned_state}

  %Results.PasswordlessHostedCompletionRequired{} = pending ->
    {:ok, url} = Identity.continuation_url(client, pending)
    {:navigate, url}

  %Results.PasswordlessCustomCompletionRequired{} = pending ->
    # Display only the registration/consent requirements supplied by Aether.
    {:custom_completion, pending}
end
```

Hosted completion is the default. Its short-lived continuation URL opens an
Aether page, which returns to the registered OAuth callback. Use the same
callback validation and code exchange shown above. A handoff is scoped to this
transaction; do not treat it as an application login session.

Custom completion requires operator approval on the registered client.
`Identity.complete_passwordless/3` accepts the opaque continuation, verifier,
and `decision: "approve"` or `"deny"`, plus contract-declared registration and
consent data when required. It returns `PasswordlessAuthorized` or
`PasswordlessDenied`. A request field cannot enable custom completion for a
hosted-only client. Never log continuation handles, OTPs, codes or tokens.

After the user explicitly approves the displayed requirements, a custom
registration completion can be submitted as follows:

```elixir
request = %{
  continuation: pending.continuation,
  code_verifier: proof.code_verifier,
  decision: "approve"
}

request = if pending.requirements.registration do
  Map.merge(request, %{
    identifier: verified_identifier,
    profile: %{display_name: submitted_display_name},
    consent: %{
      aether_terms_version: pending.requirements.aether_terms_version,
      aether_privacy_version: pending.requirements.aether_privacy_version
    }
  })
else
  request
end

case Identity.complete_passwordless(client, request) do
  {:ok, %Results.PasswordlessAuthorized{} = authorized} -> {:exchange_code, authorized}
  {:ok, %Results.PasswordlessDenied{} = denied} -> {:denied, denied}
  {:error, error} -> {:failed, error}
end
```

For denial, send only the continuation, verifier and `decision: "deny"`.
Never infer acceptance from the absence of an answer or automatically approve
registration/consent to finish a sign-in.

## Refresh and logout

Refresh using `exchange_oauth_token` with `grant_type: "refresh_token"` and the
stored refresh token. Serialize refresh for each application session and
replace stored credentials atomically after success. The SDK makes one
attempt, because repeating a rotated token can revoke the token family.

For logout, call `Identity.revoke_oauth_token(client, %{token: refresh_token,
token_type_hint: "refresh_token"})`, then clear your application session and
stored credentials. Choose and document your application behavior if the
revocation endpoint is unavailable. Public clients can revoke their presented
tokens; introspection remains available only to confidential clients.
