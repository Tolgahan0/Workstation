#!/bin/bash
# Temizleyici çekirdeği testleri (Foundation yalnızca; Linux veya macOS).
#   Tests/run-tests.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SWIFTC=(swiftc)
[[ "$(uname -s)" == "Darwin" ]] && SWIFTC=(xcrun swiftc)
"${SWIFTC[@]}" -swift-version 5 \
  "$ROOT/Sources/Shell.swift" "$ROOT/Sources/CleanerCore.swift" "$ROOT/Sources/CleanerScanner.swift" \
  "$ROOT/Sources/CleanerExecutor.swift" "$ROOT/Sources/CleanerCLI.swift" \
  "$ROOT/Tests/CleanerTests/main.swift" -o "$OUT/cleaner-tests"
"$OUT/cleaner-tests"
