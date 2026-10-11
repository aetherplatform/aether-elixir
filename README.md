# Aether Elixir SDK

Official Elixir client for Aether's public Identity, Events, Notifications,
Storage and Webhooks APIs. The SDK covers 80 contract-approved operations.

**Release status:** [`0.1.0-beta.1`](https://hex.pm/packages/aether_sdk/0.1.0-beta.1)
is published on Hex. The exact published package passed the five-platform
Mac staging journey; controlled email OAuth and passwordless completion also
passed with that package. SMS delivery remains unverified. SDK installation
does not provision an Aether application or hosted environment.

Requires Elixir 1.17 or later within 1.x. CI covers Elixir/OTP 1.17/27, 1.18/27
and 1.19/28. Runtime dependencies are Req, Jason and Telemetry.

## Install

Add the exact beta version to your Mix dependencies, then run `mix deps.get`:

```elixir
# mix.exs
{:aether_sdk, "== 0.1.0-beta.1"}
```

The package name is `aether_sdk`; modules live under `Aether.SDK`.
Read the [API documentation and guides](https://hexdocs.pm/aether_sdk/0.1.0-beta.1/).
Pin the beta version and review changes before upgrading.

## Make a request

Use the base URL and credentials assigned to your registered application.
Tokens and configuration are explicit; no global application configuration
is required.

```elixir
alias Aether.SDK.{Client, Events}

{:ok, client} = Client.new(
  base_url: System.fetch_env!("AETHER_EVENTS_URL"),
  token: System.fetch_env!("AETHER_ACCESS_TOKEN")
)

case Events.list_event_types(client) do
  {:ok, response} -> response.data
  {:error, error} -> {error.status, error.code, error.retry}
end
```

Use `ClientCredentials` for supervised workload token acquisition; see
[Authentication](guides/authentication.md). Use `Identity.new/1` for a public
OAuth client and `Identity.confidential/1` for a backend client.

```elixir
alias Aether.SDK.Identity

{:ok, identity} = Identity.new(
  base_url: System.fetch_env!("AETHER_IDENTITY_URL"),
  client_id: System.fetch_env!("AETHER_CLIENT_ID")
)

proof = Identity.generate_pkce()
state = Identity.generate_state()
# Keep proof.code_verifier and state in application-controlled storage.
{:ok, url} = Identity.authorize(identity, %{
  redirect_uri: "https://app.example/auth/callback",
  scope: "openid profile email",
  code_challenge: proof.code_challenge,
  state: state
})
```

Read [Identity and passwordless](guides/identity.md) for callback exchange,
completion outcomes, refresh and logout. Tokens remain opaque credentials;
`get_user_info/3` supplies authenticated identity claims.

## Public interface

| Module | Operations |
| --- | ---: |
| `Aether.SDK.Identity` | 11 |
| `Aether.SDK.Events` | 3 |
| `Aether.SDK.Notifications` | 29 |
| `Aether.SDK.Storage` | 18 |
| `Aether.SDK.Webhooks` | 19 |

Function names follow contract operation IDs converted to snake_case. For
example, `createUploadIntent` becomes `Storage.create_upload_intent/3`.
Generated endpoints accept a client, a request envelope, and optional settings:

```elixir
Aether.SDK.Storage.get_object(client,
  %{path: %{object_id: "obj_00000000000000000000000000000001"}},
  timeout: 10_000, max_retries: 0
)
```

The request envelope has `:path`, `:query`, `:body` and `:headers` maps, when the
operation declares them. Identity functions accept the request body directly.
Both atom and string keys are accepted on input. Declared responses become
structs under `Aether.SDK.Types`; free-form JSON retains string keys. Optional
struct fields use `:__aether_unset__` to distinguish omission from JSON null.

Functions return `{:ok, result}` or `{:error, %Aether.SDK.Error{}}`. See
[Errors and retries](guides/errors.md), [Storage](guides/storage.md) and
[Webhooks and pagination](guides/webhooks-pagination.md).

## Application boundary

The SDK handles the public HTTP protocol. Your application owns sessions,
account mapping, authorization decisions, transaction storage and token storage.
It does not bring Phoenix, Ecto or Aether's internal libraries into the runtime.
The Phoenix example in `examples/phoenix_auth.ex` illustrates this boundary.

## Development

```sh
mix deps.get
bash scripts/certify.sh
```

Bundled JSON contracts and shared test vectors let the standalone repository
regenerate independently. `mix aether.generate --check` verifies deterministic
output. See [Release process](RELEASING.md) for package inspection, hosted
acceptance, maintainer authentication and immutable publication.

Apache-2.0. Copyright Aether contributors.
