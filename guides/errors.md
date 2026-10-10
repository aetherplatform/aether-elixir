# Errors, retries and cancellation

Requests return an `Aether.SDK.Error` with `status`, exact `code`, safe `message`,
`request_id`, `retry` metadata and `attempts`. A transport error has status zero.
Handle unknown server codes using status and your application's context.
Authentication errors suppress untrusted server messages, details and request
IDs that could contain credentials. Never log whole request or response maps.

```elixir
case Aether.SDK.Events.list_event_types(client, %{}, max_retries: 0) do
  {:ok, response} -> {:ok, response.data}
  {:error, %{status: 429, code: "rate_limited", retry: timing}} ->
    {:try_later, timing[:retry_after_seconds]}
  {:error, error} -> {:failed, error.code, error.request_id}
end
```

Normal API requests default to a 15-second timeout and at most two retries.
The timeout bounds credential acquisition and response-body reading for each
attempt. `max_retries: 0` disables automatic retries. Req's independent retries
and redirects are disabled, so redirects cannot forward Aether credentials.

Reads are eligible for retry on network failure, timeout, HTTP 502/503/504 and
rate limiting. Mutations require the operation's declared idempotency policy
and the actual serialized idempotency key. A key does not make an operation
retryable when its contract says retries are unsupported. Quota exhaustion
is not rate limiting and does not trigger a retry. Numeric `Retry-After` is
honored; otherwise bounded exponential backoff is used.

Use a stable idempotency key for one logical mutation; never reuse it for a
different payload. Depending on the operation, pass `idempotency_key: key`, a
contract-declared `"idempotency-key"` header, or the declared body field.

Pass a zero-argument `cancelled?` predicate to stop acquisition, a request,
response reading or retry delay. Cancelling the caller process also tears down
its owned request. Cancellation returns `request_aborted`; it is not retried.
Cancellation cannot undo a mutation already accepted by the server.

```elixir
Aether.SDK.Events.list_event_types(client, %{},
  timeout: 5_000,
  cancelled?: fn -> cancellation_flag_set?() end
)
```

Telemetry events are `[:aether, :sdk, :request, :stop]` (native-unit duration)
and `[:aether, :sdk, :request, :retry]` (delay in milliseconds). Metadata contains
operation, platform, attempt and status. It excludes URLs, bodies, secrets,
OTP values, tokens and remote error details. A successful status is `:ok`.
