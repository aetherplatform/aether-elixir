#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${SDK_ROOT}"

mix deps.get
bash scripts/check-release-boundary.sh
bash scripts/check-generated.sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix dialyzer
mix docs --warnings-as-errors
bash scripts/test-package.sh
