#!/bin/bash
# build/Workstation.app → dist/Workstation-<sürüm>.dmg + .zip + latest.json
#   scripts/make-dmg.sh <sürüm> [<build>] [<depo: sahip/ad>] [<notlar dosyası>]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?sürüm}"
BUILD_NUM="${2:-0}"
REPO="${3:-Tolgahan0/workstation}"
NOTES_FILE="${4:-}"
APP="$ROOT/build/Workstation.app"
DIST="$ROOT/dist"
[[ -d "$APP" ]] || { echo "Önce ./build.sh çalıştır." >&2; exit 1; }
rm -rf "$DIST"; mkdir -p "$DIST"
NAME="Workstation-$VERSION"

# zip (güncelleyici bunu indirir)
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# DMG: uygulama + Applications kısayolu + Kurulum.command
STAGE="$(mktemp -d -t workstation-dmg)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Workstation.app"
ln -s /Applications "$STAGE/Applications"
install -m 0755 "$ROOT/scripts/Kurulum.command" "$STAGE/Kurulum.command"
cat > "$STAGE/BENİOKU.txt" <<TXT
Workstation $VERSION

1) Kurulum.command dosyasına sağ tıkla › Aç (ilk seferde macOS onay ister).
   Uygulamayı Applications'a kopyalar, fan kontrolünü ve komutları kurar, açılışa ekler.
2) Ya da Workstation.app'i Applications'a sürükle, sonra sağ tık › Aç.

Uygulama Apple tarafından imzalanmadığı için ilk açılışta "doğrulanamadı" uyarısı çıkabilir.
Çözüm: sağ tık › Aç, ya da Terminal'de:  xattr -dr com.apple.quarantine /Applications/Workstation.app
TXT
hdiutil create -volname "Workstation $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null

ZIP_SHA=$(shasum -a 256 "$DIST/$NAME.zip" | cut -d' ' -f1)
DMG_SHA=$(shasum -a 256 "$DIST/$NAME.dmg" | cut -d' ' -f1)
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
HELPER_VERSION=""
[[ -f "$APP/Contents/Resources/helper-version" ]] && HELPER_VERSION="$(cat "$APP/Contents/Resources/helper-version")"
BASE="https://github.com/$REPO/releases/download/v$VERSION"
VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" NAME="$NAME" BASE="$BASE" ZIP_SHA="$ZIP_SHA" DMG_SHA="$DMG_SHA" \
HELPER_VERSION="$HELPER_VERSION" NOTES_FILE="$NOTES_FILE" OUT_JSON="$DIST/latest.json" /usr/bin/python3 - <<'PY'
import json, os
e = os.environ
notes = ""
if e.get("NOTES_FILE") and os.path.exists(e["NOTES_FILE"]):
    notes = open(e["NOTES_FILE"], encoding="utf-8").read()
json.dump({
    "version": e["VERSION"], "build": e["BUILD_NUM"],
    "zip_name": e["NAME"] + ".zip", "dmg_name": e["NAME"] + ".dmg",
    "zip_url": e["BASE"] + "/" + e["NAME"] + ".zip", "dmg_url": e["BASE"] + "/" + e["NAME"] + ".dmg",
    "sha256": e["ZIP_SHA"], "dmg_sha256": e["DMG_SHA"],
    "helper_version": e["HELPER_VERSION"], "notes": notes,
}, open(e["OUT_JSON"], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
ls -la "$DIST"
