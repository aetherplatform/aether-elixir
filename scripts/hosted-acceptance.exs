defmodule Aether.SDK.HostedAcceptance do
  alias Aether.SDK.{Client, ClientCredentials, Identity, Events, Notifications, Storage, Webhooks}
  alias Aether.SDK.Storage.{Transfer, Workflow}

  def run do
    {:ok, identity} = Identity.new(base_url: required("IDENTITY_URL"))
    checked(Identity.get_open_id_configuration(identity), "Identity discovery")
    checked(Identity.get_oauth_jwks(identity), "Identity keys")

    checked(
      Events.list_event_types(client("EVENTS", ["events:catalog/*:read"])),
      "Events catalog"
    )

    checked(
      Notifications.list_notification_templates(
        client("NOTIFICATIONS", ["notifications:templates/*:read"])
      ),
      "Notifications templates"
    )

    checked(
      Webhooks.list_webhook_subscriptions(client("WEBHOOKS", ["webhooks:subscriptions/*:read"])),
      "Webhooks subscriptions"
    )

    storage =
      client("STORAGE", [
        "storage:objects/*:create",
        "storage:objects/*:delete",
        "storage:objects/*:read",
        "storage:objects/*:share"
      ])

    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    payload = "Aether Elixir SDK hosted proof " <> id
    digest = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

    uploaded =
      checked(
        Workflow.upload_object(
          storage,
          %{
            namespace_id: required("NAMESPACE_ID"),
            logical_key: "sdk-proof/elixir-#{id}.txt",
            filename: "elixir-#{id}.txt",
            content_type: "text/plain",
            expected_size: byte_size(payload),
            client_sha256: digest
          },
          payload,
          wait_for_availability: [timeout: 120_000],
          sha256: digest
        ),
        "Storage upload and availability"
      )

    try do
      download =
        checked(
          Storage.create_object_download_intent(storage, %{path: %{object_id: uploaded.object.id}}),
          "Storage download intent"
        )

      bytes = checked(Transfer.download_binary(download.download_url), "Storage download")
      if bytes != payload, do: fail("Storage byte comparison")
    after
      checked(
        Storage.delete_object(storage, %{path: %{object_id: uploaded.object.id}},
          idempotency_key: "sdk-proof-delete-#{id}"
        ),
        "Storage deletion"
      )
    end

    IO.puts(
      "Hosted acceptance passed for all five platforms. Controlled user email acceptance is a separate required gate."
    )
  end

  defp client(platform, capabilities) do
    {:ok, provider} =
      ClientCredentials.start_link(
        token_url: required("TOKEN_URL"),
        client_id: required("CLIENT_ID"),
        client_secret: required("CLIENT_SECRET"),
        audience: required(platform <> "_AUDIENCE"),
        capabilities: capabilities
      )

    {:ok, client} =
      Client.new(
        base_url: required(platform <> "_URL"),
        token_provider: {ClientCredentials, provider}
      )

    client
  end

  defp required(name) do
    key = "AETHER_SDK_SANDBOX_" <> name

    case System.get_env(key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "Missing required hosted configuration: #{key}"
    end
  end

  defp checked({:ok, value}, _), do: value

  defp checked({:error, error}, stage),
    do: raise("#{stage} failed (HTTP #{error.status}; details suppressed)")

  defp fail(stage), do: raise("#{stage} failed")
end

Aether.SDK.HostedAcceptance.run()
