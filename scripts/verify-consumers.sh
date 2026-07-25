#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
parent="$(dirname "$root")"

for repo in redact-node sdk-node sdk-dotnet platform; do
  test -d "$parent/$repo" || { echo "missing sibling consumer: $repo" >&2; exit 1; }
done

compare_json_tree() {
  local target="$1"
  while IFS= read -r source; do
    rel="${source#"$root/fixtures/"}"
    test -f "$target/$rel" || { echo "missing fixture copy: $target/$rel" >&2; exit 1; }
    cmp "$source" "$target/$rel" || { echo "fixture drift: $rel" >&2; exit 1; }
  done < <(find "$root/fixtures" -type f -name '*.json' | sort)
}

compare_json_tree "$parent/redact-node/test/protocol-fixtures"
compare_json_tree "$parent/sdk-node/test/protocol-fixtures"
compare_json_tree "$parent/sdk-dotnet/tests/ToSpec.Sdk.Tests/Fixtures"
compare_json_tree "$parent/platform/tests/ToSpec.Integration.Tests/Fixtures/SdkProtocol"

echo "all protocol fixture copies are byte-identical"
