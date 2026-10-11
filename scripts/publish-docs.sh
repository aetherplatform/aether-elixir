#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HEX_API_KEY:?Set the package-only Hex credential in the protected environment}"
version=$(mix run --no-start -e 'IO.write(Mix.Project.config()[:version])' | tail -1)
tag="v${version}"
git rev-parse --verify "refs/tags/${tag}" >/dev/null
# A README/release-note correction must not ship API changes under an old version.
git diff --exit-code "$tag" -- lib mix.exs mix.lock guides
curl --fail --silent --show-error --output /dev/null \
  "https://repo.hex.pm/tarballs/aether_sdk-${version}.tar"
mix docs --warnings-as-errors
mix hex.publish docs --yes
