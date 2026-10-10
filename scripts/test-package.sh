#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hosted=false
case $# in
  0) ;;
  1)
    if [[ "$1" == "--hosted" ]]; then
      hosted=true
    else
      echo "usage: $0 [--hosted]" >&2
      exit 64
    fi
    ;;
  *)
    echo "usage: $0 [--hosted]" >&2
    exit 64
    ;;
esac
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/aether-elixir-package.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

bash "${SDK_ROOT}/scripts/export-public-repository.sh" "${work_dir}/export"
(cd "${work_dir}/export" && export MIX_BUILD_PATH="${work_dir}/export-build" &&
  mix deps.get && bash scripts/check-generated.sh &&
  mix compile --warnings-as-errors && mix hex.build --output "${work_dir}/aether_sdk.tar")

mkdir -p "${work_dir}/outer" "${work_dir}/package" "${work_dir}/consumer"
tar -xf "${work_dir}/aether_sdk.tar" -C "${work_dir}/outer"
test -f "${work_dir}/outer/contents.tar.gz"
if tar -tzf "${work_dir}/outer/contents.tar.gz" |
  grep -Eq '(^|/)(deps|_build|\.git|\.env|\.secrets)(/|$)'; then
  echo "Hex package contains private or build files" >&2
  exit 1
fi
tar -xzf "${work_dir}/outer/contents.tar.gz" -C "${work_dir}/package"
test -f "${work_dir}/package/lib/aether/sdk/identity.ex"
test -f "${work_dir}/package/lib/aether/sdk/generated/storage.ex"
test -f "${work_dir}/package/lib/aether/sdk/types/webhooks.ex"

cat > "${work_dir}/consumer/mix.exs" <<'ELIXIR'
defmodule AetherConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :aether_consumer, version: "0.1.0", elixir: "~> 1.17",
     deps: [{:aether_sdk, path: "../package"}]]
  end

  def application, do: [extra_applications: [:logger]]
end
ELIXIR

cat > "${work_dir}/consumer/smoke.exs" <<'ELIXIR'
alias Aether.SDK.{Client, Events, Identity, Notifications, Storage, Webhooks}
alias Aether.SDK.Types

{:ok, client} = Client.new(base_url: "https://api.example.test", token: "package-smoke")
{:ok, _identity} = Identity.new(base_url: "https://auth.example.test", client_id: "smoke")
true = is_struct(client, Client)

for {module, function, arity} <- [
      {Identity, :generate_pkce, 0},
      {Events, :list_event_types, 3},
      {Notifications, :list_notification_templates, 3},
      {Storage, :get_object, 3},
      {Webhooks, :list_webhook_subscriptions, 3}
    ] do
  true = Code.ensure_loaded?(module)
  true = function_exported?(module, function, arity)
end

for module <- [
      Types.Identity.PasswordlessStartRequest,
      Types.Events.EventType,
      Types.Notifications.QueuedNotification,
      Types.Storage.Asset,
      Types.Webhooks.Delivery
    ] do
  true = Code.ensure_loaded?(module)
  true = function_exported?(module, :__schema__, 0)
end

for {catalog, expected} <- [
      {Aether.SDK.Generated.Identity, 11},
      {Aether.SDK.Generated.Events, 3},
      {Aether.SDK.Generated.Notifications, 29},
      {Aether.SDK.Generated.Storage, 18},
      {Aether.SDK.Generated.Webhooks, 19}
    ] do
  true = Code.ensure_loaded?(catalog)
  ^expected = map_size(catalog.operations())
end
ELIXIR

(cd "${work_dir}/consumer" && export MIX_BUILD_PATH="${work_dir}/consumer-build" &&
  mix deps.get && mix run smoke.exs)
echo "Unpacked Hex package passed independent consumer smoke."

if [[ "${hosted}" == true ]]; then
  cp "${SDK_ROOT}/scripts/hosted-acceptance.exs" "${work_dir}/consumer/hosted-acceptance.exs"
  (cd "${work_dir}/consumer" && export MIX_BUILD_PATH="${work_dir}/consumer-build" &&
    mix run hosted-acceptance.exs)
fi
