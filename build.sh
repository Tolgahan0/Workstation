#!/bin/bash
# Workstation — derleme ve paketleme (install.sh ve GitHub Actions bunu kullanır).
#   ./build.sh                         → build/Workstation.app (bu Mac'in mimarisi)
#   ./build.sh --universal             → arm64 + x86_64 (yayın için)
#   ./build.sh --build 42              → sürüm her zaman VERSION dosyasından (tek kaynak)
#   ./build.sh --version X             → yalnızca VERSION ile aynıysa kabul edilir (CI etiket denetimi)
# Çıktı: build/Workstation.app
#   Contents/MacOS/Workstation                 menü çubuğu uygulaması
#   Contents/Resources/wm-fanhelper            fan yardımcısı (kurulumda /usr/local/libexec'e kopyalanır)
#   Contents/Resources/helper-version          yardımcının sürüm özeti (güncellemede yeniden kurulum gerekip gerekmediği)
#   Contents/Resources/bin/workstation(-connect)  komut satırı yardımcıları
#   Contents/Resources/postinstall.sh + install-helper.sh   kurulum sonrası adımlar
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Workstation"
OUT="$ROOT/build"
UNIVERSAL=0
VERSION=""
BUILD_NUM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --version) shift; VERSION="${1:-}" ;;
    --build) shift; BUILD_NUM="${1:-}" ;;
    --out) shift; OUT="${1:-}" ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "build.sh yalnızca macOS'ta çalışır." >&2; exit 1; }

# Tek sürüm kaynağı: VERSION. Uygulama, fan yardımcısı, workstation(-connect) komutları ve latest.json bunu kullanır.
FILE_VERSION="$(tr -d ' \n\r' < "$ROOT/VERSION")"
if [[ -n "$VERSION" && "$VERSION" != "$FILE_VERSION" ]]; then
  echo "Sürüm uyuşmuyor: --version $VERSION ≠ VERSION dosyası $FILE_VERSION (önce VERSION'ı güncelleyip scripts/version.sh sync)" >&2
  exit 1
fi
VERSION="$FILE_VERSION"
"$ROOT/scripts/version.sh" check >/dev/null || { "$ROOT/scripts/version.sh" check; exit 1; }

if [[ $UNIVERSAL == 1 ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
TMP="$(mktemp -d -t workstation-build)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

FRAMEWORKS=(-framework Cocoa -framework SwiftUI -framework IOKit -framework CoreGraphics -framework CoreAudio
            -framework UserNotifications -framework Security)

info "Swift kaynakları derleniyor (${ARCHS[*]})…"
BINS=()
for a in "${ARCHS[@]}"; do
  xcrun swiftc -O -swift-version 5 -target "$a-apple-macos13.0" "${FRAMEWORKS[@]}" \
    "$ROOT"/Sources/*.swift -o "$TMP/$APP_NAME-$a"
  BINS+=("$TMP/$APP_NAME-$a")
done
lipo -create "${BINS[@]}" -output "$TMP/$APP_NAME"
ok "Uygulama derlendi."

info "Fan yardımcısı (wm-fanhelper) derleniyor…"
FAN_OK=1
FBINS=()
printf 'let workstationVersion = "%s"\n' "$VERSION" > "$TMP/BuildVersion.swift"
for a in "${ARCHS[@]}"; do
  if xcrun swiftc -O -swift-version 5 -target "$a-apple-macos13.0" -framework IOKit \
       "$ROOT/Tools/FanHelper/main.swift" "$ROOT/Sources/SMC.swift" "$ROOT/Sources/L10n.swift" "$TMP/BuildVersion.swift" -o "$TMP/wm-fanhelper-$a" 2>"$TMP/fan-$a.log"; then
    FBINS+=("$TMP/wm-fanhelper-$a")
  else
    FAN_OK=0; warn "wm-fanhelper ($a) derlenemedi: $(tail -n 3 "$TMP/fan-$a.log")"
  fi
done
[[ $FAN_OK == 1 ]] && lipo -create "${FBINS[@]}" -output "$TMP/wm-fanhelper"

STAGE="$OUT/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/bin"
cp "$TMP/$APP_NAME" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
PB=/usr/libexec/PlistBuddy
[[ -n "$VERSION" ]] && "$PB" -c "Set :CFBundleShortVersionString $VERSION" "$STAGE/Contents/Info.plist"
[[ -n "$BUILD_NUM" ]] && "$PB" -c "Set :CFBundleVersion $BUILD_NUM" "$STAGE/Contents/Info.plist"
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

if [[ $FAN_OK == 1 ]]; then
  cp "$TMP/wm-fanhelper" "$STAGE/Contents/Resources/wm-fanhelper"
  # Yalnızca yardımcının mantığı: L10n.swift'teki her metin değişikliği "yardımcılar güncel değil" uyarısı çıkarmasın.
  { cat "$ROOT/Tools/FanHelper/main.swift" "$ROOT/Sources/SMC.swift"; echo "$VERSION"; } | shasum -a 256 | cut -c1-16 > "$STAGE/Contents/Resources/helper-version"
fi
for c in workstation workstation-connect; do
  sed "s/^WS_VERSION=\"@VERSION@\".*/WS_VERSION=\"$VERSION\"/" "$ROOT/$c" > "$STAGE/Contents/Resources/bin/$c"
  chmod 0755 "$STAGE/Contents/Resources/bin/$c"
done
install -m 0755 "$ROOT/scripts/postinstall.sh" "$STAGE/Contents/Resources/postinstall.sh"
install -m 0755 "$ROOT/scripts/install-helper.sh" "$STAGE/Contents/Resources/install-helper.sh"

info "Uygulama simgesi oluşturuluyor…"
NATIVE="$(uname -m)"
if xcrun swiftc -O -swift-version 5 -target "$NATIVE-apple-macos13.0" -framework Cocoa \
     "$ROOT/Tools/MakeIcon/main.swift" "$ROOT/Sources/IconRenderer.swift" "$ROOT/Sources/Models.swift" "$ROOT/Sources/L10n.swift" \
     -o "$TMP/MakeIcon" 2>"$TMP/makeicon.log" \
   && "$TMP/MakeIcon" "$TMP/AppIcon.iconset" >/dev/null \
   && iconutil -c icns "$TMP/AppIcon.iconset" -o "$STAGE/Contents/Resources/AppIcon.icns"; then
  ok "Simge hazır."
else
  warn "Simge oluşturulamadı (varsayılan simge kullanılır): $(tail -n 3 "$TMP/makeicon.log" 2>/dev/null)"
fi

info "Ad-hoc imzalanıyor…"
[[ -f "$STAGE/Contents/Resources/wm-fanhelper" ]] && codesign --force -s - "$STAGE/Contents/Resources/wm-fanhelper"
codesign --force --deep -s - "$STAGE"
codesign --verify --deep --strict "$STAGE"
ok "Hazır: $STAGE ($("$PB" -c 'Print :CFBundleShortVersionString' "$STAGE/Contents/Info.plist"))"
