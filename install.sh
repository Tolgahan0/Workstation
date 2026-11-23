#!/bin/bash
# Workstation — kaynaktan tek adımlık kurulum
#   ./install.sh
# Yapılanlar:
#   1) setup_env.sh: Homebrew + BetterDisplay kontrolü/kurulumu
#   2) Xcode Command Line Tools kontrolü
#   3) ./build.sh → build/Workstation.app (ad-hoc imzalı)
#   4) /Applications/Workstation.app'e kopyalama (eski WorkstationMode.app kaldırılır, ayarlar korunur)
#   5) scripts/postinstall.sh: fan yardımcısı, parolasız izin, workstation komutları, URL kaydı, Login Items, başlatma
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Workstation"
APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.tolgahanayaz.workstationmode"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m✖\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Bu betik yalnızca macOS'ta çalışır."
[[ $EUID -ne 0 ]] || fail "Lütfen sudo OLMADAN çalıştırın: ./install.sh (parola gerektiğinde bir kez sorulur)."
TARGET_USER="$(id -un)"

info "Yönetici yetkisi gerekiyor (fan yardımcısı, /usr/local/bin). Parolanız bir kez istenecek."
sudo -v
# Kurulum süresince sudo zaman damgasını canlı tut (disown: çıkışta "Terminated: 15" basılmaz).
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 30; done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE=$!
disown "$SUDO_KEEPALIVE" 2>/dev/null || true
cleanup() {
  if [[ -n "${SUDO_KEEPALIVE:-}" ]]; then
    pkill -P "$SUDO_KEEPALIVE" 2>/dev/null || true
    kill "$SUDO_KEEPALIVE" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE" 2>/dev/null || true
  fi
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

# --- 3) Derleme --------------------------------------------------------------
"$SCRIPT_DIR/build.sh"
STAGE="$SCRIPT_DIR/build/$APP_NAME.app"

# --- 4) /Applications --------------------------------------------------------
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
touch "$APP_PATH"
ok "Uygulama kuruldu: $APP_PATH"

# --- 5) Kurulum sonrası ------------------------------------------------------
"$APP_PATH/Contents/Resources/postinstall.sh" --app "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
cat <<DONE

Kurulum tamamlandı (Workstation $VERSION).
  Menü çubuğu simgesi:  tek renk Mac mini (rozet: mavi=Uyku · yeşil=Remote · sarı=geçiş)
  Uzaktan:             ssh <host> workstation remote | sleep | desktop | status | clean --dry-run
  Bağlanan Mac'ten:    workstation-connect --setup <host>   (bir kez), sonra: workstation-connect
  Kestirmeler / URL:   workstation://remote · workstation://fan/max · workstation://clean/scan
  Günlük:              ~/Library/Logs/Workstation.log
DONE
