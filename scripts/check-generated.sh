#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AETHER_ROOT="$(cd "${SDK_ROOT}/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/aether-elixir-contracts.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

for platform in identity events notifications storage webhooks; do
  bundled="${SDK_ROOT}/contracts/openapi/${platform}.json"
  test -f "${bundled}"
  if [[ -f "${AETHER_ROOT}/scripts/openapi_contracts.rb" ]]; then
    ruby "${AETHER_ROOT}/scripts/openapi_contracts.rb" bundle "${platform}" \
      "${work_dir}/${platform}.json" >/dev/null
    cmp "${bundled}" "${work_dir}/${platform}.json"
  fi
done

(cd "${SDK_ROOT}" && mix aether.generate --check)
