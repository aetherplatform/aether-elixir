# Storage transfers

`Aether.SDK.Storage.Workflow.upload_object/4` creates an upload intent through
Aether, transfers the source to the signed provider URL, and completes the
upload. The source may be a binary or `{:file, path}`. File sources are read in
bounded chunks, and multipart uploads use at most four concurrent parts by
default.

```elixir
alias Aether.SDK.{Client, Storage.Workflow}

{:ok, client} = Client.new(base_url: aether_url, token: access_token)
path = "/path/to/photo.jpg"

request = %{
  namespace_id: namespace_id,
  logical_key: "photos/photo.jpg",
  filename: "photo.jpg",
  content_type: "image/jpeg",
  expected_size: File.stat!(path).size
}

{:ok, %Workflow.Result{object: object}} =
  Workflow.upload_object(client, request, {:file, path},
    wait_for_availability: [timeout: 120_000, poll_interval: 1_000]
  )
```

The workflow checks the source size before creating an intent. It generates
separate idempotency keys for create, complete, and abort unless supplied in
`:idempotency_keys`. A transfer or completion failure triggers a best-effort
abort; the returned error remains the original failure, and
`error.details.cleanup_succeeded` reports the abort result. Once completion
succeeds, an availability polling failure does not abort the upload. Pass a
zero-argument `:cancelled?` function to stop transfers and polling.

For direct provider operations, use `Aether.SDK.Storage.Transfer.upload/4`,
`upload_multipart/3`, or `download/3`. These functions take signed URLs and
provider headers, not an Aether client. They never forward the client's token
or tracing headers. Multipart results preserve each provider ETag exactly and
are sorted by part number for completion.

```elixir
alias Aether.SDK.Storage.Transfer

{:ok, byte_count} =
  Transfer.download(signed_url, fn chunk ->
    IO.binwrite(device, chunk)
  end)
```

`download/3` streams chunks to a callback or IO device. A destination may
contain partial bytes if the transfer fails, so discard it on error. Use
`download_binary/2` only when buffering the entire response is appropriate.
Provider calls do not follow redirects or retry; obtain a fresh signed URL
from Aether if one expires.
