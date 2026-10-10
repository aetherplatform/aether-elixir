#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AETHER_ROOT="$(cd "${SDK_ROOT}/../.." && pwd)"

if [[ -f "${AETHER_ROOT}/scripts/openapi_contracts.rb" ]]; then
  for platform in identity events notifications storage webhooks; do
    ruby "${AETHER_ROOT}/scripts/openapi_contracts.rb" bundle "${platform}" \
      "${SDK_ROOT}/contracts/openapi/${platform}.json" >/dev/null
  done
fi

for platform in identity events notifications storage webhooks; do
  test -f "${SDK_ROOT}/contracts/openapi/${platform}.json"
done

(cd "${SDK_ROOT}" && mix aether.generate)
