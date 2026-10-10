# Authentication

Aether distinguishes workload access from user sign-in. A workload token
represents a registered application with approved platform capabilities;
it does not identify a human user.

## Supervised workload provider

Add one provider per audience/capability set to your application's supervisor:

```elixir
children = [
  {Aether.SDK.ClientCredentials,
   name: MyApp.AetherEventsTokens,
   token_url: System.fetch_env!("AETHER_TOKEN_URL"),
   client_id: System.fetch_env!("AETHER_CLIENT_ID"),
   client_secret: System.fetch_env!("AETHER_CLIENT_SECRET"),
   audience: System.fetch_env!("AETHER_EVENTS_AUDIENCE"),
   capabilities: ["events:catalog/*:read"]}
]

{:ok, client} = Aether.SDK.Client.new(
  base_url: System.fetch_env!("AETHER_EVENTS_URL"),
  token_provider: {Aether.SDK.ClientCredentials, MyApp.AetherEventsTokens}
)
```

Each provider caches until 30 seconds before expiry and shares one acquisition
among concurrent callers. `ClientCredentials.invalidate/1` clears the cache;
an older acquisition cannot repopulate an invalidated cache. A failed
acquisition is shared with its waiting callers and is not cached.

Provider settings include `:timeout` (10 seconds), `:max_retries` (one retry)
and `:expiry_skew` (30,000 milliseconds). This machine grant has a separate
retry policy from single-attempt user authorization-code exchange and refresh.

A custom provider implements `c:Aether.SDK.TokenProvider.get_token/1`, returning
`{:ok, %Aether.SDK.AccessToken{value: token, expires_at: unix_milliseconds}}` or
`{:error, %Aether.SDK.Error{}}`. Optional `invalidate/1` supports refreshing a
credential after an authorized retry of a safe request.

## User clients

`Identity.new/1` configures a public browser/mobile client with an optional
client ID. It can fetch discovery without a registration. Public clients
cannot request machine client-credentials tokens or introspect tokens.

`Identity.confidential/1` requires a client ID and client secret. Keep secrets
on the server. Both constructors use the configured Identity origin, not
an arbitrary endpoint received from a callback or request parameter.

Store credentials in your deployment secret manager. Client, authentication,
PKCE and generated response structs redact their values when inspected; this
is a guardrail, not a reason to log response bodies or inspect application maps.
