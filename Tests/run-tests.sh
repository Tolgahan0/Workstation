#!/bin/bash
# Temizleyici çekirdeği testleri (Foundation yalnızca; Linux veya macOS).
#   Tests/run-tests.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SWIFTC=(swiftc)
[[ "$(uname -s)" == "Darwin" ]] && SWIFTC=(xcrun swiftc)
# AppKit/SwiftUI içermeyen tüm kaynaklar (Linux'ta da derlenir).
export WORKSTATION_LANG=tr
CORE=()
for f in L10n Shell Models SMC KeepAwake URLRoute Schedule Notifier SystemStats Profiles PowerManager NetworkInfo \
         AutoSwitch AudioControl BetterDisplayInstaller BrightnessCoalescer FanControl \
         CleanerCore CleanerScanner CleanerExecutor CleanerCLI UpdateCore Updater; do
  CORE+=("$ROOT/Sources/$f.swift")
done
"${SWIFTC[@]}" -swift-version 5 "${CORE[@]}" "$ROOT/Tests/CleanerTests/main.swift" -o "$OUT/cleaner-tests"
"$OUT/cleaner-tests"
