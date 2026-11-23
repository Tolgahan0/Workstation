#!/bin/bash
# WorkstationMode — tek adımlık kurulum
#   ./install.sh
# Yapılanlar:
#   1) setup_env.sh: Homebrew + BetterDisplay kontrolü/kurulumu, CLI doğrulaması
#   2) Xcode Command Line Tools kontrolü
#   3) Swift kaynaklarını derleyip /Applications/WorkstationMode.app paketini oluşturma + ad-hoc imza
#   4) /usr/local/libexec/wm-fanhelper (fan yardımcısı, root:wheel 755) +
#      /etc/sudoers.d/workstation_toggle  →  <kullanıcı> ALL=(root) NOPASSWD: /usr/bin/pmset, /usr/local/libexec/wm-fanhelper
#   5) workstation:// URL scheme kaydı (lsregister)
#   6) /usr/local/bin/workstation + workstation-connect yardımcı komutları
#   7) Login Items'a ekleme ve uygulamayı başlatma
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="WorkstationMode"
APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.tolgahanayaz.workstationmode"
SUDOERS_FILE="/etc/sudoers.d/workstation_toggle"
HELPER_DST="/usr/local/bin/workstation"
FANHELPER_DST="/usr/local/libexec/wm-fanhelper"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m✖\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Bu betik yalnızca macOS'ta çalışır."
[[ $EUID -ne 0 ]] || fail "Lütfen sudo OLMADAN çalıştırın: ./install.sh (parola gerektiğinde bir kez sorulur)."
TARGET_USER="$(id -un)"

info "Yönetici yetkisi gerekiyor (sudoers, /usr/local/bin). Parolanız bir kez istenecek."
sudo -v
# Kurulum süresince sudo zaman damgasını canlı tut.
# disown: bash iş tablosundan çıkarılır → çıkışta öldürülünce "Terminated: 15" mesajı basılmaz.
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 30; done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE=$!
disown "$SUDO_KEEPALIVE" 2>/dev/null || true
BUILD_DIR="$(mktemp -d -t workstationmode-build)"
cleanup() {
  if [[ -n "${SUDO_KEEPALIVE:-}" ]]; then
    pkill -P "$SUDO_KEEPALIVE" 2>/dev/null || true   # alt süreç (sleep)
    kill "$SUDO_KEEPALIVE" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE" 2>/dev/null || true
  fi
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# --- 1) Ortam ----------------------------------------------------------------
info "Ortam hazırlanıyor (setup_env.sh)…"
set +e
/bin/bash "$SCRIPT_DIR/setup_env.sh"
ENV_RC=$?
set -e
if [[ $ENV_RC -eq 2 ]]; then
  warn "BetterDisplay CLI henüz kapalı. Kurulum devam ediyor; CLI'ı açtıktan sonra uygulama otomatik çalışır."
elif [[ $ENV_RC -ne 0 ]]; then
  warn "setup_env.sh tamamlanamadı (kod $ENV_RC). Devam ediliyor; BetterDisplay yoksa uygulama Remote'u ilk başlattığınızda kendisi kurar."
fi
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

# --- 2) Xcode Command Line Tools ---------------------------------------------
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  warn "Xcode Command Line Tools bulunamadı. Kurulum penceresi açılıyor…"
  xcode-select --install 2>/dev/null || true
  fail "Command Line Tools kurulumunu tamamladıktan sonra ./install.sh komutunu tekrar çalıştırın."
fi
ok "Xcode Command Line Tools: $(xcode-select -p)"

# --- 3) Derleme ve paketleme --------------------------------------------------
info "Swift kaynakları derleniyor…"
ARCH="$(uname -m)"   # arm64 (Apple Silicon) veya x86_64
xcrun swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  -framework Cocoa -framework SwiftUI -framework IOKit -framework CoreGraphics \
  "$SCRIPT_DIR"/Sources/*.swift \
  -o "$BUILD_DIR/$APP_NAME"
ok "Derleme tamam."

info "Fan yardımcısı (wm-fanhelper) derleniyor…"
FANHELPER_OK=0
if xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" -framework IOKit \
     "$SCRIPT_DIR/Tools/FanHelper/main.swift" "$SCRIPT_DIR/Sources/SMC.swift" \
     -o "$BUILD_DIR/wm-fanhelper" 2>"$BUILD_DIR/fanhelper.log"; then
  FANHELPER_OK=1
  ok "wm-fanhelper derlendi."
else
  warn "wm-fanhelper derlenemedi (fan kontrolü yalnızca okuma yapar). Ayrıntı: $(tail -n 3 "$BUILD_DIR/fanhelper.log" 2>/dev/null)"
fi

STAGE="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Uygulama simgesi (mor zemin üzerinde gümüş Mac Studio) → AppIcon.icns
info "Uygulama simgesi oluşturuluyor…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
if xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" -framework Cocoa \
     "$SCRIPT_DIR/Tools/MakeIcon/main.swift" "$SCRIPT_DIR/Sources/IconRenderer.swift" "$SCRIPT_DIR/Sources/Models.swift" \
     -o "$BUILD_DIR/MakeIcon" 2>"$BUILD_DIR/makeicon.log" \
   && "$BUILD_DIR/MakeIcon" "$ICONSET" >/dev/null \
   && iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"; then
  ok "AppIcon.icns oluşturuldu."
else
  warn "Simge oluşturulamadı (uygulama varsayılan simgeyle çalışır). Ayrıntı: $(tail -n 3 "$BUILD_DIR/makeicon.log" 2>/dev/null)"
fi
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null || fail "Info.plist geçersiz."

info "Ad-hoc imzalanıyor…"
codesign --force --deep -s - "$STAGE"
codesign --verify --verbose=1 "$STAGE" >/dev/null 2>&1 && ok "İmza doğrulandı."

# Çalışan eski sürümü kapat ve yenisini /Applications'a kopyala.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  info "Çalışan $APP_NAME kapatılıyor…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
fi
if [[ -w /Applications ]]; then
  rm -rf "$APP_PATH"
  ditto "$STAGE" "$APP_PATH"
else
  sudo rm -rf "$APP_PATH"
  sudo ditto "$STAGE" "$APP_PATH"
  sudo chown -R "$TARGET_USER":staff "$APP_PATH"
fi
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
touch "$APP_PATH"   # Finder/Dock simge önbelleğini tazele
ok "Uygulama kuruldu: $APP_PATH"

# --- 4) fan yardımcısı + sudoers ---------------------------------------------
if [[ "$FANHELPER_OK" == 1 ]]; then
  info "Fan yardımcısı kuruluyor: $FANHELPER_DST (root:wheel 755)"
  sudo install -d -m 0755 -o root -g wheel /usr/local/libexec
  sudo install -m 0755 -o root -g wheel "$BUILD_DIR/wm-fanhelper" "$FANHELPER_DST"
  # Önceki oturumdan manuel kalmış fan varsa sisteme bırak (zararsız; fansız Mac'te hiçbir şey yapmaz).
  sudo "$FANHELPER_DST" reset >/dev/null 2>&1 || true
  ok "wm-fanhelper kuruldu."
fi

info "Parolasız pmset / fan yardımcısı izni ayarlanıyor: $SUDOERS_FILE"
TMP_SUDOERS="$(mktemp -t workstation_toggle)"
if [[ "$FANHELPER_OK" == 1 ]]; then
  cat > "$TMP_SUDOERS" <<SUDOERS
# WorkstationMode: mod geçişlerinde pmset'in ve fan yardımcısının parola sormadan çalışması için.
# wm-fanhelper yalnızca: status | set <fan|all> auto|half|max | reset kabul eder.
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset, $FANHELPER_DST
SUDOERS
else
  cat > "$TMP_SUDOERS" <<SUDOERS
# WorkstationMode: mod geçişlerinde pmset'in parola sormadan çalışması için
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset
SUDOERS
fi
if sudo /usr/sbin/visudo -cf "$TMP_SUDOERS" >/dev/null; then
  sudo install -m 0440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS_FILE"
  rm -f "$TMP_SUDOERS"
  sudo /usr/sbin/visudo -cf "$SUDOERS_FILE" >/dev/null || { sudo rm -f "$SUDOERS_FILE"; fail "sudoers doğrulaması başarısız, dosya kaldırıldı."; }
  # Önbellekteki sudo yetkisini YOK SAYARAK (-k komutla birlikte) parolasız çalıştığını doğrula.
  if sudo -k -n /usr/bin/pmset -g >/dev/null 2>&1; then
    ok "sudo -n pmset parolasız çalışıyor."
    if [[ "$FANHELPER_OK" == 1 ]]; then
      if sudo -k -n "$FANHELPER_DST" status >/dev/null 2>&1; then
        ok "sudo -n wm-fanhelper parolasız çalışıyor."
      else
        warn "wm-fanhelper status başarısız (fansız Mac olabilir); günlüğe bakın."
      fi
    fi
  else
    warn "sudo -n pmset hâlâ parola istiyor; /etc/sudoers içinde '#includedir /private/etc/sudoers.d' satırını kontrol edin."
  fi
else
  rm -f "$TMP_SUDOERS"
  fail "sudoers kuralı visudo doğrulamasından geçmedi."
fi

# --- 5) URL scheme kaydı -----------------------------------------------------
info "workstation:// URL scheme kaydediliyor…"
"$LSREGISTER" -f "$APP_PATH" && ok "URL scheme kaydedildi."

# --- 6) workstation yardımcı komutu ------------------------------------------
info "Yardımcı komut kuruluyor: $HELPER_DST"
sudo mkdir -p /usr/local/bin
sudo install -m 0755 "$SCRIPT_DIR/workstation" "$HELPER_DST"
sudo install -m 0755 "$SCRIPT_DIR/workstation-connect" "/usr/local/bin/workstation-connect"
# SSH ile komut çalıştırılırken (ssh studio workstation remote) zsh yalnızca ~/.zshenv'i okur;
# /usr/local/bin PATH'te olsun.
ZSHENV_LINE='export PATH="/usr/local/bin:$PATH"'
touch "$HOME/.zshenv"
grep -qxF "$ZSHENV_LINE" "$HOME/.zshenv" || printf '\n%s\n' "$ZSHENV_LINE" >> "$HOME/.zshenv"
ok "Yardımcı komutlar hazır: workstation remote [WxH|ön ayar] | sleep | desktop | status | log · workstation-connect <host>"

# --- 7) Login Items + başlatma -----------------------------------------------
info "Login Items'a ekleniyor (System Events için izin istenebilir)…"
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "$APP_NAME"; then
  ok "Zaten Login Items'ta."
else
  if osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_PATH\", hidden:true}" >/dev/null; then
    ok "Login Items'a eklendi."
  else
    warn "Login Items'a eklenemedi. System Settings > General > Login Items bölümünden elle ekleyin."
  fi
fi

info "Uygulama başlatılıyor…"
open "$APP_PATH"
sleep 2
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  ok "$APP_NAME menü çubuğunda çalışıyor."
else
  warn "$APP_NAME başlatılamadı; günlük: ~/Library/Logs/WorkstationMode.log"
fi

cat <<DONE

Kurulum tamamlandı.
  Menü çubuğu simgesi:  mor zemin üzerinde gümüş Mac Studio (rozet: mavi=Uyku · yeşil=Remote · sarı=geçiş)
  Uzaktan:             ssh <host> workstation remote [WxH|mbp14…] | sleep | desktop | status
  Bağlanan Mac'ten:    workstation-connect <host>   (ekran boyutunu algılar, Remote'u açar, Ekran Paylaşımı'nı başlatır)
  URL:                 open -g workstation://remote
  Günlük:              ~/Library/Logs/WorkstationMode.log
DONE
