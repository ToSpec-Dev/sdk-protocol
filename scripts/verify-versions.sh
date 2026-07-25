#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
parent="$(dirname "$root")"

redact_node="$(node -p "require('$parent/redact-node/package.json').version")"
sdk_node="$(node -p "require('$parent/sdk-node/package.json').version")"
sdk_node_dep="$(node -p "require('$parent/sdk-node/package.json').dependencies['@tospec/redact']")"
vendor="$parent/sdk-node/${sdk_node_dep#file:}"
vendor_version="$(tar -xOf "$vendor" package/package.json | node -e 'let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).version))')"

redact_dotnet="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$parent/redact-dotnet/src/ToSpec.Redact/ToSpec.Redact.csproj")"
sdk_dotnet="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$parent/sdk-dotnet/src/ToSpec.Sdk/ToSpec.Sdk.csproj")"
sdk_dotnet_dep="$(sed -n 's:.*PackageVersion Include="ToSpec.Redact" Version="\([^"]*\)".*:\1:p' "$parent/sdk-dotnet/Directory.Packages.props")"

test "$redact_node" = "$vendor_version" || { echo "Node vendored redactor is $vendor_version, source is $redact_node" >&2; exit 1; }
test "$sdk_node_dep" = "file:vendor/tospec-redact-$redact_node.tgz" || { echo "Node SDK dependency does not name current redactor" >&2; exit 1; }
test "$redact_dotnet" = "$sdk_dotnet_dep" || { echo ".NET SDK redactor dependency is $sdk_dotnet_dep, source is $redact_dotnet" >&2; exit 1; }
test -f "$parent/sdk-dotnet/local-packages/ToSpec.Redact.$redact_dotnet.nupkg" || { echo "missing .NET vendored redactor $redact_dotnet" >&2; exit 1; }
test "$sdk_node" = "$sdk_dotnet" || { echo "SDK release versions diverge: Node $sdk_node, .NET $sdk_dotnet" >&2; exit 1; }

echo "versions coherent: SDK $sdk_node; redactors Node $redact_node / .NET $redact_dotnet"
