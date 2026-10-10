#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "${SDK_ROOT}/mix.exs"
test -f "${SDK_ROOT}/LICENSE"
test -f "${SDK_ROOT}/NOTICE"

if grep -Eq '(^|[[:space:]])(path:|git:)' "${SDK_ROOT}/mix.exs"; then
  echo "Elixir SDK package has a source-only dependency" >&2
  exit 1
fi

ruby - "${SDK_ROOT}" <<'RUBY'
require "json"
root = ARGV.fetch(0)
counts = {"identity" => 11, "events" => 3, "notifications" => 29,
          "storage" => 18, "webhooks" => 19}
prefixes = {
  "identity" => ["/oauth/", "/.well-known/", "/v1/passwordless/"],
  "events" => ["/v1/events/"],
  "notifications" => ["/v1/notifications/"],
  "storage" => ["/v1/storage/"],
  "webhooks" => ["/v1/webhooks/"]
}
counts.each do |platform, expected|
  path = File.join(root, "contracts/openapi", "#{platform}.json")
  document = JSON.parse(File.read(path))
  operations = document.fetch("paths").flat_map do |route, item|
    item.each_with_object([]) do |(method, value), ids|
      next unless %w[get post put patch delete head options].include?(method)
      next unless value.is_a?(Hash) && value["operationId"]
      abort "private #{platform} route: #{route}" unless prefixes.fetch(platform).any? { |prefix| route.start_with?(prefix) }
      abort "internal #{platform} route: #{route}" if route.include?("/internal/") ||
        route.include?("provider-migrations") || route.include?("consumer-groups")
      ids << value.fetch("operationId")
    end
  end
  abort "#{platform}: expected #{expected} operations, found #{operations.length}" unless operations.length == expected
  abort "#{platform}: duplicate operation ID" unless operations.uniq.length == expected
end
RUBY
