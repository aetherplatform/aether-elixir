#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HEX_API_KEY:?Set the scoped Hex publication credential in the protected environment}"
version=$(mix run --no-start -e 'IO.write(Mix.Project.config()[:version])' | tail -1)
package="aether_sdk-${version}.tar"
test -f "reviewed/${package}"
mix hex.build
cmp "$package" "reviewed/$package"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=$(curl --silent --show-error --output "$tmp/existing.tar" --write-out '%{http_code}' "https://repo.hex.pm/tarballs/${package}")
case "$status" in
  200)
    # Recovery can complete missing steps only when the immutable tar is exact.
    cmp "$package" "$tmp/existing.tar"
    ;;
  404)
    mix hex.publish package --yes
    ;;
  *)
    echo "Could not establish existing immutable Hex version (HTTP $status)" >&2
    exit 1
    ;;
esac
mix docs --warnings-as-errors
# HexDocs is recoverable separately from package publication.
mix hex.publish docs --yes
