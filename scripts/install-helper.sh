#!/bin/bash
# Root olarak çalışır: fan yardımcısını ve parolasız izin kuralını kurar.
#   sudo install-helper.sh <Workstation.app yolu> <kullanıcı>
set -euo pipefail
APP="${1:?uygulama yolu}"
USER_NAME="${2:?kullanıcı}"
[[ $EUID -eq 0 ]] || { echo "root olarak çalıştırılmalı" >&2; exit 1; }
SRC="$APP/Contents/Resources/wm-fanhelper"
DST="/usr/local/libexec/wm-fanhelper"
SUDOERS_FILE="/etc/sudoers.d/workstation_toggle"
HAVE_HELPER=0
if [[ -f "$SRC" ]]; then
  install -d -m 0755 -o root -g wheel /usr/local/libexec
  install -m 0755 -o root -g wheel "$SRC" "$DST"
  [[ -f "$APP/Contents/Resources/helper-version" ]] && install -m 0644 -o root -g wheel "$APP/Contents/Resources/helper-version" "$DST.version"
  "$DST" reset >/dev/null 2>&1 || true
  HAVE_HELPER=1
fi
TMP="$(mktemp -t workstation_toggle)"
{
  echo "# Workstation: mod geçişlerinde pmset'in ve fan yardımcısının parola sormadan çalışması için."
  echo "# wm-fanhelper yalnızca: status | set <fan|all> auto|half|max | reset kabul eder."
  if [[ $HAVE_HELPER == 1 ]]; then echo "$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset, $DST"
  else echo "$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset"; fi
} > "$TMP"
if /usr/sbin/visudo -cf "$TMP" >/dev/null; then
  install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"
  /usr/sbin/visudo -cf "$SUDOERS_FILE" >/dev/null || { rm -f "$SUDOERS_FILE"; echo "sudoers doğrulanamadı, kaldırıldı" >&2; exit 1; }
fi
rm -f "$TMP"
# Komut satırı yardımcıları
install -d -m 0755 /usr/local/bin
install -m 0755 "$APP/Contents/Resources/bin/workstation" /usr/local/bin/workstation
install -m 0755 "$APP/Contents/Resources/bin/workstation-connect" /usr/local/bin/workstation-connect
echo "ok"
