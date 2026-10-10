#!/usr/bin/env bash
set -euo pipefail
SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo 'usage: test-published.sh EXACT_VERSION' >&2
  exit 64
fi
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/aether-elixir-published.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
cat > "$work_dir/mix.exs" <<ELIXIR
defmodule PublishedConsumer.MixProject do
  use Mix.Project
  def project, do: [app: :published_consumer, version: "0.1.0", deps: [{:aether_sdk, "== ${version}"}]]
  def application, do: [extra_applications: [:logger]]
end
ELIXIR
cp "$SDK_ROOT/scripts/hosted-acceptance.exs" "$work_dir/hosted-acceptance.exs"
cd "$work_dir"
export MIX_BUILD_PATH="$work_dir/_build"
mix deps.get
mix compile --warnings-as-errors
mix run hosted-acceptance.exs
printf 'Published Hex %s passed independent hosted consumer verification.\n' "$version"
