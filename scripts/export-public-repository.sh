#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AETHER_ROOT="$(cd "${SDK_ROOT}/../.." && pwd)"
output="${1:-}"

if [[ -z "${output}" ]]; then
  echo "usage: $0 EMPTY_OUTPUT_DIRECTORY" >&2
  exit 64
fi

mkdir -p "${output}"
if [[ -n "$(find "${output}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "output directory must be empty: ${output}" >&2
  exit 65
fi

# A whitelist keeps build output, dependencies, credentials and unrelated
# monorepo files out of the standalone public repository.
for entry in lib test scripts guides mix.exs mix.lock .formatter.exs .gitignore \
  examples README.md CHANGELOG.md RELEASING.md LICENSE NOTICE VERSIONING.md; do
  if [[ -e "${SDK_ROOT}/${entry}" ]]; then
    rsync -a "${SDK_ROOT}/${entry}" "${output}/"
  fi
done

mkdir -p "${output}/.github/workflows"
for workflow in ci.yml release.yml docs.yml; do
  if [[ -f "${SDK_ROOT}/.github/workflows/${workflow}" ]]; then
    cp "${SDK_ROOT}/.github/workflows/${workflow}" "${output}/.github/workflows/${workflow}"
  fi
done

mkdir -p "${output}/contracts/openapi" "${output}/contracts/sdk/v1" \
  "${output}/contracts/webhooks/signatures/v1"

for platform in identity events notifications storage webhooks; do
  if [[ -f "${AETHER_ROOT}/scripts/openapi_contracts.rb" ]]; then
    ruby "${AETHER_ROOT}/scripts/openapi_contracts.rb" bundle "${platform}" \
      "${output}/contracts/openapi/${platform}.json" >/dev/null
  else
    cp "${SDK_ROOT}/contracts/openapi/${platform}.json" \
      "${output}/contracts/openapi/${platform}.json"
  fi
done

cp "${SDK_ROOT}"/contracts/sdk/v1/*.json "${output}/contracts/sdk/v1/"
cp "${SDK_ROOT}/contracts/webhooks/signatures/v1/vectors.json" \
  "${output}/contracts/webhooks/signatures/v1/vectors.json"

unsafe_file="$(find "${output}" \( -type l -o -type f \( \
  -name '.env*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o \
  -name '*.p8' -o -name '*.log' -o -name '*.dump' -o -name '*.sqlite' -o \
  -name '.DS_Store' \) \) -print -quit)"
if [[ -n "${unsafe_file}" ]]; then
  echo "unsafe file in public SDK export: ${unsafe_file}" >&2
  exit 66
fi

if grep -R -n -E \
  --exclude='check-release-boundary.sh' --exclude='export-public-repository.sh' \
  '/Users/|-----BEGIN [A-Z ]*PRIVATE KEY-----|SERVICE_JWT_PRIVATE_KEY|NATS_URL|DATABASE_URL|AWS_SECRET_ACCESS_KEY|UPSTASH_REDIS_REST_TOKEN|SUPABASE_SERVICE_ROLE_KEY|HEX_API_KEY=' \
  "${output}"; then
  echo "private path or operational credential material in public SDK export" >&2
  exit 66
fi

bash "${output}/scripts/check-release-boundary.sh"
echo "Public Elixir SDK repository exported to ${output}"
