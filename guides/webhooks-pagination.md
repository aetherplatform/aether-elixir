# Webhook signatures and pagination

Verify webhook signatures against the exact raw request body before decoding
JSON. `Aether.SDK.Webhooks.Signature.verify/4` accepts one secret or a list of
current and previous secrets during rotation. It checks every candidate using
constant-time digest comparisons and enforces a 300 second timestamp tolerance
by default.

```elixir
alias Aether.SDK.Webhooks.Signature

case Signature.verify(raw_body, signature_header, [current_secret, previous_secret]) do
  {:ok, %{timestamp: timestamp}} ->
    {:ok, Jason.decode!(raw_body), timestamp}

  {:error, error} ->
    {:error, error}
end
```

`Aether.SDK.Pagination.stream/2` adapts a cursor fetch function into a lazy
stream. The fetch function receives `nil` initially, unless `:initial_cursor`
is supplied, and returns `{:ok, %{items: items, next_cursor: cursor}}` or
`{:error, error}`. Adapt a generated list operation's response to this shape
when its field names differ.

```elixir
alias Aether.SDK.Pagination

stream =
  Pagination.stream(fn cursor ->
    case fetch_page.(cursor) do
      {:ok, page} -> {:ok, %{items: page.items, next_cursor: page.next_cursor}}
      {:error, error} -> {:error, error}
    end
  end)

Enum.each(stream, fn
  {:ok, item} -> IO.inspect(item)
  {:error, error} -> IO.warn(Exception.message(error))
end)
```

The stream yields `{:ok, item}` for each item. It yields one `{:error, error}`
and stops on a fetch failure, malformed page, repeated cursor, or page limit.
The default maximum is 1,000 fetched pages; change it with `:max_pages`.
