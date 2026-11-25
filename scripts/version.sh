#!/bin/bash
# Tek sürüm kaynağı: depo kökündeki VERSION dosyası.
#   scripts/version.sh            → sürümü yazdırır
#   scripts/version.sh sync       → Info.plist, site ve README'yi VERSION'a eşitler
#   scripts/version.sh check [v]  → hepsi VERSION ile aynı mı (+ verilirse etiket/sürüm v); farklıysa çıkış 1
#   scripts/version.sh check-app <Workstation.app> → derlenen uygulama, workstation komutu ve fan yardımcısı
# macOS ve Linux'ta çalışır (CI denetimi); yalnızca bash + python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$(tr -d ' \n\r' < "$ROOT/VERSION")"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "VERSION geçersiz: '$V'" >&2; exit 1; }

plist_version() {
  python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$1"
}

case "${1:-}" in
  "") echo "$V" ;;
  sync)
    python3 - "$ROOT" "$V" <<'PY'
import plistlib, re, sys, pathlib
root, v = pathlib.Path(sys.argv[1]), sys.argv[2]
p = root / "Info.plist"
d = plistlib.load(open(p, "rb")); d["CFBundleShortVersionString"] = v
plistlib.dump(d, open(p, "wb"))
for f, pat, rep in [
    ("site/index.html", r'data-version>[^<]*<', f'data-version>v{v}<'),
    ("README.md", r'git tag v[0-9][^ ]* && git push origin v[0-9][^ \n]*', f'git tag v{v} && git push origin v{v}'),
]:
    fp = root / f
    s = fp.read_text()
    s2 = re.sub(pat, rep, s)
    fp.write_text(s2)
print("eşitlendi:", v)
PY
    ;;
  check)
    fail=0
    want="${2:-}"; want="${want#v}"
    if [[ -n "$want" && "$want" != "$V" ]]; then echo "✗ etiket/sürüm $want ≠ VERSION $V" >&2; fail=1; fi
    pv="$(plist_version "$ROOT/Info.plist")"
    [[ "$pv" == "$V" ]] || { echo "✗ Info.plist $pv ≠ $V (scripts/version.sh sync)" >&2; fail=1; }
    grep -q "data-version>v$V<" "$ROOT/site/index.html" || { echo "✗ site/index.html sürümü $V değil (scripts/version.sh sync)" >&2; fail=1; }
    if grep -qE 'git tag v[0-9]' "$ROOT/README.md"; then
      grep -q "git tag v$V && git push origin v$V" "$ROOT/README.md" || { echo "✗ README sürüm örneği $V değil (scripts/version.sh sync)" >&2; fail=1; }
    fi
    grep -q '^WS_VERSION="@VERSION@"' "$ROOT/workstation" || { echo "✗ workstation: WS_VERSION yer tutucusu yok" >&2; fail=1; }
    grep -q '^WS_VERSION="@VERSION@"' "$ROOT/workstation-connect" || { echo "✗ workstation-connect: WS_VERSION yer tutucusu yok" >&2; fail=1; }
    (( fail == 0 )) && echo "✔ sürümler tutarlı: $V"
    exit $fail
    ;;
  check-app)
    APP="${2:?Workstation.app yolu}"
    fail=0
    av="$(plist_version "$APP/Contents/Info.plist")"
    [[ "$av" == "$V" ]] || { echo "✗ uygulama $av ≠ $V" >&2; fail=1; }
    for c in workstation workstation-connect; do
      cv="$(sed -n 's/^WS_VERSION="\(.*\)"$/\1/p' "$APP/Contents/Resources/bin/$c")"
      [[ "$cv" == "$V" ]] || { echo "✗ $c $cv ≠ $V" >&2; fail=1; }
    done
    if [[ -x "$APP/Contents/Resources/wm-fanhelper" ]]; then
      hv="$("$APP/Contents/Resources/wm-fanhelper" version 2>/dev/null || true)"
      [[ "$hv" == "$V" ]] || { echo "✗ wm-fanhelper '$hv' ≠ $V" >&2; fail=1; }
    fi
    if [[ -x "$APP/Contents/MacOS/Workstation" ]]; then
      xv="$("$APP/Contents/MacOS/Workstation" --version 2>/dev/null || true)"
      [[ "$xv" == "$V" ]] || { echo "✗ Workstation --version '$xv' ≠ $V" >&2; fail=1; }
    fi
    (( fail == 0 )) && echo "✔ derleme sürümleri tutarlı: $V (uygulama, workstation, workstation-connect, wm-fanhelper)"
    exit $fail
    ;;
  *) echo "Kullanım: scripts/version.sh [sync | check [sürüm] | check-app <app>]" >&2; exit 2 ;;
esac
