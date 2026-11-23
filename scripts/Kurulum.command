#!/bin/bash
# Workstation — DMG'den kurulum. Çift tıkla (ilk seferde: sağ tık › Aç).
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)/Workstation.app"
DEST="/Applications/Workstation.app"
echo "Workstation kuruluyor…"
if [[ -d "$SRC" ]]; then
  pkill -x Workstation 2>/dev/null || true
  sleep 1
  if [[ -w /Applications ]]; then rm -rf "$DEST"; ditto "$SRC" "$DEST"
  else sudo rm -rf "$DEST"; sudo ditto "$SRC" "$DEST"; sudo chown -R "$(id -un)":staff "$DEST"; fi
fi
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
"$DEST/Contents/Resources/postinstall.sh" --app "$DEST"
echo
echo "Tamam! Menü çubuğundaki Mac mini simgesine tıkla. Bu pencereyi kapatabilirsin."
