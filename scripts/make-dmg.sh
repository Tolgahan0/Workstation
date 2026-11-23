#!/bin/bash
# build/Workstation.app → dist/Workstation-<sürüm>.dmg + .zip + latest.json + Workstation.dmg (sürümsüz kopya)
#   scripts/make-dmg.sh <sürüm> [<build>] [<depo: sahip/ad>] [<notlar dosyası>]
# DMG penceresi: açık arka plan, solda Workstation, ok, sağda Applications (sürükle-bırak kurulum).
# Kurulum.command ve BENİOKU.txt pencerenin görünen alanının altında (aşağı kaydırınca) durur.
# Yerleşim Finder AppleScript ile yazılır (birkaç deneme); Finder yanıt vermezse
# scripts/dmg/DS_Store şablonu kullanılır (birim adı sabit "Workstation" olduğu için şablon her sürümde geçerli).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?sürüm}"
BUILD_NUM="${2:-0}"
REPO="${3:-Tolgahan0/workstation}"
NOTES_FILE="${4:-}"
APP="$ROOT/build/Workstation.app"
DIST="$ROOT/dist"
ASSETS="$ROOT/scripts/dmg"
VOLNAME="Workstation"
[[ -d "$APP" ]] || { echo "Önce ./build.sh çalıştır." >&2; exit 1; }
rm -rf "$DIST"; mkdir -p "$DIST"
NAME="Workstation-$VERSION"

# Pencere yerleşimi (Tools/DMGBackground ile aynı ölçüler)
WIN_W=660; WIN_H=440; ICON=128
APP_POS="170, 220"; APPS_POS="490, 220"
SETUP_POS="220, 610"; README_POS="440, 610"

# zip (güncelleyici bunu indirir)
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

WORK="$(mktemp -d -t workstation-dmg)"
MNT=""
cleanup() {
  [[ -n "$MNT" && -d "$MNT" ]] && hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Workstation.app"
ln -s /Applications "$STAGE/Applications"
install -m 0755 "$ROOT/scripts/Kurulum.command" "$STAGE/Kurulum.command"
cat > "$STAGE/BENİOKU.txt" <<TXT
Workstation $VERSION

KURULUM
1) Workstation'ı Applications klasörüne sürükle.
2) Applications'ta Workstation'a sağ tıkla › Aç (ilk seferde macOS onay ister).
   Mac mini simgesi menü çubuğunda belirir; modlar (Masaüstü / Uyku / Remote) hemen çalışır.

İSTEĞE BAĞLI (önerilir): Kurulum.command
Sürükleyerek kurduğunda şunlar henüz kurulu değildir:
  • fan kontrolü (wm-fanhelper yardımcısı)
  • parolasız mod geçişi (pmset için sudoers kuralı; yoksa Uyku/Remote güç ayarları uygulanamaz)
  • terminal komutları: workstation, workstation-connect  (ssh studio workstation remote)
  • açılışta otomatik başlatma
Bunlar için bu penceredeki Kurulum.command dosyasına sağ tıkla › Aç. Mac parolan bir kez sorulur.
Kurulum.command uygulamayı Applications'a da kopyalar; yani sürüklemeden doğrudan onu da kullanabilirsin.
Sonradan çalıştırmak için Terminal'de:
  /Applications/Workstation.app/Contents/Resources/postinstall.sh

"Doğrulanamadı" uyarısı
Uygulama Apple tarafından noter onaylı değil. Sağ tık › Aç yeterli; olmazsa Terminal'de:
  xattr -dr com.apple.quarantine /Applications/Workstation.app

----
English: drag Workstation to Applications, then right-click › Open. For fan control, password-less
mode switching, the "workstation" command and launch-at-login, right-click Kurulum.command › Open (once).
TXT

# Arka plan: 1x + 2x → tek HiDPI TIFF
if [[ -f "$ASSETS/background.png" && -f "$ASSETS/background@2x.png" ]]; then
  tiffutil -cathidpicheck "$ASSETS/background.png" "$ASSETS/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
    || cp "$ASSETS/background.png" "$STAGE/.background/background.tiff"
fi
# Birim simgesi = uygulama simgesi
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

# Aynı adla bağlı eski bir birim varsa ayır (Finder adla adresler)
for v in "/Volumes/$VOLNAME" "/Volumes/$VOLNAME "[0-9]*; do
  [[ -d "$v" ]] && hdiutil detach "$v" -force >/dev/null 2>&1 || true
done

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
RW="$WORK/rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[[ -d "$MNT" ]] || { echo "DMG bağlanamadı." >&2; exit 1; }
DISK_NAME="$(basename "$MNT")"
[[ -f "$MNT/.VolumeIcon.icns" ]] && command -v SetFile >/dev/null && SetFile -a C "$MNT" 2>/dev/null || true

layout_finder() {
  /usr/bin/osascript <<OSA
with timeout of 60 seconds
  tell application "Finder"
    tell disk "$DISK_NAME"
      open
      delay 1
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + 28))}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to $ICON
      set text size of opts to 13
      set label position of opts to bottom
      set shows item info of opts to false
      set shows icon preview of opts to true
      set background picture of opts to file ".background:background.tiff"
      set position of item "Workstation.app" of container window to {$APP_POS}
      set position of item "Applications" of container window to {$APPS_POS}
      set position of item "Kurulum.command" of container window to {$SETUP_POS}
      set position of item "BENİOKU.txt" of container window to {$README_POS}
      close
      open
      delay 1
      update without registering applications
      delay 2
      close
    end tell
  end tell
end timeout
OSA
}

LAID_OUT=0
ATTEMPTS=3; [[ "${WS_DMG_NO_FINDER:-0}" == 1 ]] && ATTEMPTS=0
attempt=0
while (( attempt < ATTEMPTS )); do
  attempt=$((attempt + 1))
  if layout_finder 2>"$WORK/osa.log"; then
    for _ in $(seq 1 20); do [[ -f "$MNT/.DS_Store" ]] && break; sleep 0.5; done
    if [[ -f "$MNT/.DS_Store" ]]; then LAID_OUT=1; break; fi
  fi
  echo "Finder yerleşimi denemesi $attempt başarısız: $(tail -n 2 "$WORK/osa.log" 2>/dev/null)" >&2
  sleep 3
done
if [[ $LAID_OUT == 1 ]]; then
  echo "Finder yerleşimi yazıldı."
  mkdir -p "$ROOT/build" && cp "$MNT/.DS_Store" "$ROOT/build/DS_Store.generated" 2>/dev/null || true   # şablonu yenilemek için
elif [[ -f "$ASSETS/DS_Store" ]]; then
  echo "Finder yanıt vermedi; hazır .DS_Store şablonu kullanılıyor." >&2
  cp "$ASSETS/DS_Store" "$MNT/.DS_Store"
else
  echo "Uyarı: DMG yerleşimi uygulanamadı (düz pencere)." >&2
fi
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$MNT" >/dev/null 2>&1 || { sleep 2; hdiutil detach "$MNT" -force >/dev/null; }
MNT=""
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DIST/$NAME.dmg" >/dev/null

ZIP_SHA=$(shasum -a 256 "$DIST/$NAME.zip" | cut -d' ' -f1)
DMG_SHA=$(shasum -a 256 "$DIST/$NAME.dmg" | cut -d' ' -f1)
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
# Sürümsüz kopya: site ve README doğrudan releases/latest/download/Workstation.dmg adresine bağlanır.
cp "$DIST/$NAME.dmg" "$DIST/Workstation.dmg"
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
