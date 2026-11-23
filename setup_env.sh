#!/bin/bash
# Workstation — ortam hazırlığı
#  1) Homebrew (/opt/homebrew/bin/brew) yoksa kurar ve ~/.zprofile'a shellenv satırını ekler
#  2) BetterDisplay (/Applications/BetterDisplay.app) yoksa `brew install --cask betterdisplay` ile kurar
#  3) BetterDisplay CLI erişimini doğrular; kapalıysa uyarır
set -euo pipefail

BREW="/opt/homebrew/bin/brew"
BD_APP="/Applications/BetterDisplay.app"
BD_CLI="$BD_APP/Contents/MacOS/BetterDisplay"
SHELLENV_LINE='eval "$(/opt/homebrew/bin/brew shellenv)"'

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m✖\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Bu betik yalnızca macOS'ta çalışır."
[[ "$(uname -m)" == "arm64" ]] || warn "Apple Silicon (arm64) bekleniyordu, bulunan: $(uname -m)"
[[ $EUID -ne 0 ]] || fail "Lütfen sudo OLMADAN normal kullanıcı olarak çalıştırın (gerektiğinde parola sorulur)."

# --- 1) Homebrew -------------------------------------------------------------
if [[ ! -x "$BREW" ]]; then
  info "Homebrew bulunamadı, kuruluyor (yönetici parolası istenebilir)…"
  /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  [[ -x "$BREW" ]] || fail "Homebrew kurulumu başarısız: $BREW bulunamadı."
  ok "Homebrew kuruldu."
else
  ok "Homebrew mevcut: $BREW"
fi

touch "$HOME/.zprofile"
if ! grep -qxF "$SHELLENV_LINE" "$HOME/.zprofile"; then
  printf '\n%s\n' "$SHELLENV_LINE" >> "$HOME/.zprofile"
  ok "~/.zprofile dosyasına Homebrew shellenv satırı eklendi."
else
  ok "~/.zprofile zaten Homebrew shellenv satırını içeriyor."
fi
eval "$("$BREW" shellenv)"

# --- 2) BetterDisplay --------------------------------------------------------
if [[ ! -d "$BD_APP" ]]; then
  info "BetterDisplay bulunamadı, kuruluyor: brew install --cask betterdisplay"
  "$BREW" install --cask betterdisplay
  [[ -d "$BD_APP" ]] || fail "BetterDisplay kurulumu başarısız: $BD_APP bulunamadı."
  ok "BetterDisplay kuruldu."
else
  ok "BetterDisplay mevcut: $BD_APP"
fi

# --- 3) CLI doğrulaması ------------------------------------------------------
# CLI istekleri çalışan BetterDisplay uygulaması tarafından işlenir; çalışmıyorsa başlat.
if ! /usr/bin/pgrep -x BetterDisplay >/dev/null 2>&1; then
  info "BetterDisplay başlatılıyor…"
  /usr/bin/open -g -a "$BD_APP" || true
  for _ in {1..20}; do
    /usr/bin/pgrep -x BetterDisplay >/dev/null 2>&1 && break
    sleep 0.5
  done
  sleep 3
fi

# macOS'ta `timeout` yok: komutu arka planda çalıştırıp süre aşımında sonlandır.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return $rc
}

CLI_OUT="$(mktemp -t bdcli)"
cli_ok=0
for attempt in 1 2 3; do
  if run_with_timeout 15 "$BD_CLI" get -identifiers >"$CLI_OUT" 2>&1 && grep -q '{' "$CLI_OUT"; then
    cli_ok=1; break
  fi
  sleep 2
done

if [[ $cli_ok -eq 1 ]]; then
  ok "BetterDisplay CLI çalışıyor. Algılanan ekranlar:"
  grep -E '"(name|deviceType|tagID)"' "$CLI_OUT" | sed 's/^/    /' || true
else
  warn "BetterDisplay CLI yanıt vermedi."
  warn "Lütfen BetterDisplay > Settings > Application > Integration bölümünde"
  warn "'Enable CLI / URL scheme' (CLI erişimi) seçeneğini AÇIN, sonra bu betiği tekrar çalıştırın."
  [[ -s "$CLI_OUT" ]] && { warn "CLI çıktısı:"; sed 's/^/    /' "$CLI_OUT" >&2; }
  /usr/bin/osascript -e 'display dialog "BetterDisplay CLI erişimi kapalı görünüyor.\n\nBetterDisplay > Settings > Application (Integration) bölümünde \"Enable CLI / URL scheme\" kutucuğunu açın ve kurulumu tekrar çalıştırın." with title "Workstation" buttons {"Tamam"} default button 1 with icon caution' >/dev/null 2>&1 || true
  /usr/bin/open -a "$BD_APP" || true
fi
rm -f "$CLI_OUT"

# install.sh'nin bu sonucu okuyabilmesi için: 0 = CLI hazır, 2 = CLI kapalı (kurulum devam edebilir)
[[ $cli_ok -eq 1 ]] && exit 0 || exit 2
