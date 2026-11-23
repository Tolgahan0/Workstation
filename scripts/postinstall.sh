#!/bin/bash
# Workstation — kurulum sonrası adımlar (install.sh, DMG'deki Kurulum.command ve güncelleyici kullanır).
#   postinstall.sh [--app /Applications/Workstation.app] [--no-launch]
#  1) eski WorkstationMode.app'i ve Login Items kaydını kaldırır
#  2) fan yardımcısı + parolasız izin + komut satırı yardımcıları (yönetici parolası bir kez sorulur)
#  3) workstation:// adresini kaydeder, Login Items'a ekler, uygulamayı açar
set -euo pipefail
APP="/Applications/Workstation.app"
LAUNCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) shift; APP="$1" ;;
    --no-launch) LAUNCH=0 ;;
  esac
  shift
done
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
[[ $EUID -ne 0 ]] || { echo "Lütfen sudo olmadan çalıştır." >&2; exit 1; }
[[ -d "$APP" ]] || { echo "Uygulama bulunamadı: $APP" >&2; exit 1; }
USER_NAME="$(id -un)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 1) Eski ad
if [[ -d /Applications/WorkstationMode.app ]] || pgrep -x WorkstationMode >/dev/null 2>&1; then
  info "Eski WorkstationMode kaldırılıyor (ayarların korunur)…"
  pkill -x WorkstationMode 2>/dev/null || true
  osascript -e 'tell application "System Events" to delete (every login item whose name is "WorkstationMode")' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/WorkstationMode.app 2>/dev/null || sudo rm -rf /Applications/WorkstationMode.app
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# 2) Yönetici adımları
info "Fan kontrolü ve komut satırı yardımcıları kuruluyor (Mac parolan istenebilir)…"
if sudo "$APP/Contents/Resources/install-helper.sh" "$APP" "$USER_NAME" >/dev/null; then
  ok "Yardımcılar kuruldu."
else
  warn "Yardımcılar kurulamadı; fan ayarı ve parolasız mod geçişi çalışmayabilir."
fi
ZSHENV_LINE='export PATH="/usr/local/bin:$PATH"'
touch "$HOME/.zshenv"
grep -qxF "$ZSHENV_LINE" "$HOME/.zshenv" || printf '\n%s\n' "$ZSHENV_LINE" >> "$HOME/.zshenv"

# 3) URL, Login Items, başlat
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
     | tr ',' '\n' | sed 's/^ *//' | grep -qx "Workstation"; then
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP\", hidden:true}" >/dev/null 2>&1 \
    && ok "Açılışta otomatik başlayacak." || warn "Login Items'a eklenemedi; Sistem Ayarları › Genel › Giriş Öğeleri'nden ekleyebilirsin."
fi
if [[ $LAUNCH == 1 ]]; then
  open "$APP"
  ok "Workstation menü çubuğunda."
fi
