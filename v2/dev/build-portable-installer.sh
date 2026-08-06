#!/usr/bin/env bash
# v2 runtime'ını gömülü tek bir macOS .command dosyasına paketler.
# Çıktı: repo'dan bağımsız; Masaüstü'ne kopyalanıp çift tıkla çalışır.
set -Eeuo pipefail

DEV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$DEV_DIR/../.." && pwd)"
V2_ROOT="$REPO_ROOT/v2"
DIST_DIR="$V2_ROOT/dist"
OUT_NAME="Master-Stack-v2-Install.command"
MARKER="__MASTER_STACK_V2_ARCHIVE__"

V2_VERSION="$(awk -F= '/^V2_VERSION=/{gsub(/"/,"",$2); print $2; exit}' "$V2_ROOT/install.sh")"
[[ -n "$V2_VERSION" ]] || { echo "HATA: V2_VERSION okunamadı" >&2; exit 1; }

COPY_DESKTOP=0
OUT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop) COPY_DESKTOP=1; shift ;;
        -o|--output) OUT_PATH="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Kullanım: $(basename "$0") [--desktop] [-o PATH]

  --desktop   ~/Desktop/$OUT_NAME olarak da yaz
  -o PATH     çıktı yolu (varsayılan: v2/dist/$OUT_NAME)
EOF
            exit 0
            ;;
        *) echo "HATA: bilinmeyen argüman: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$OUT_PATH" ]] || OUT_PATH="$DIST_DIR/$OUT_NAME"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/dsi-v2-portable.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

tgz="$tmpdir/v2.tgz"
echo "==> Paketleniyor: v2/ runtime (v$V2_VERSION)"
(
    cd -- "$REPO_ROOT" || exit 1
    COPYFILE_DISABLE=1 tar -czf "$tgz" \
        --exclude='._*' \
        --exclude='.DS_Store' \
        --exclude='v2/.cursor' \
        --exclude='v2/dev' \
        --exclude='v2/tests' \
        --exclude='v2/dist' \
        v2
)

b64="$tmpdir/v2.b64"
base64 <"$tgz" | tr -d '\n' >"$b64"
# satır kır: taşınabilirlik / diff için 76 kolon
fold -w 76 "$b64" >"$b64.folded"
mv "$b64.folded" "$b64"

mkdir -p "$(dirname -- "$OUT_PATH")"
built_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

{
    cat <<'HEADER_END'
#!/usr/bin/env bash
# Master Stack v2 — taşınabilir tek dosya kurulum (macOS .command)
# Repo'ya ihtiyaç duymaz. Masaüstü'ne kopyalayıp çift tıklayın.
# Yeniden üretmek: v2/dev/build-portable-installer.sh
set -Eeuo pipefail

HEADER_END
    cat <<EOF
PORTABLE_V2_VERSION="$V2_VERSION"
PORTABLE_BUILT_AT="$built_at"
ARCHIVE_MARKER="$MARKER"
EOF
    cat <<'BODY_END'

DEFAULT_HOST="${DEPLOY_HOST:-nrm}"
REMOTE_TGZ="/tmp/dsi-v2.tgz"
REMOTE_ROOT="/root/debian-server-installer"

pause_exit() {
    local rc="${1:-0}"
    echo
    read -r -p "Pencereyi kapatmak için Enter..." || true
    exit "$rc"
}

here="$(cd -- "$(dirname -- "$0")" && pwd)"
self="$here/$(basename -- "$0")"
[[ -f "$self" ]] || { echo "HATA: betik yolu bulunamadı: $self" >&2; pause_exit 1; }

tgz="$(mktemp "${TMPDIR:-/tmp}/dsi-v2-embed.XXXXXX.tgz")"
cleanup_local() { rm -f "$tgz"; }
trap cleanup_local EXIT

printf '\n=== Master Stack v2 — taşınabilir kurulum ===\n'
printf 'Sürüm:  %s\n' "$PORTABLE_V2_VERSION"
printf 'Üretim: %s\n\n' "$PORTABLE_BUILT_AT"

read -r -p "SSH sunucu adı [${DEFAULT_HOST}]: " HOST || true
HOST="${HOST:-$DEFAULT_HOST}"
[[ -n "$HOST" ]] || { echo "HATA: sunucu adı boş" >&2; pause_exit 1; }

echo "==> Gömülü arşiv açılıyor"
marker_line="$(grep -n "^${ARCHIVE_MARKER}$" "$self" | head -n1 | cut -d: -f1 || true)"
[[ -n "$marker_line" ]] || { echo "HATA: gömülü arşiv işareti yok" >&2; pause_exit 1; }
if ! tail -n +"$((marker_line + 1))" "$self" | base64 -D -o "$tgz" 2>/dev/null; then
    tail -n +"$((marker_line + 1))" "$self" | base64 --decode >"$tgz"
fi
[[ -s "$tgz" ]] || { echo "HATA: arşiv boş veya bozuk" >&2; pause_exit 1; }

ssh_base=(-o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=20)

echo "==> SSH kontrol: $HOST"
ssh "${ssh_base[@]}" "$HOST" 'printf "OK user=%s host=%s\n" "$(id -un)" "$(hostname)"'

echo "==> Kopyalanıyor → ${HOST}:${REMOTE_TGZ}"
scp "${ssh_base[@]}" "$tgz" "${HOST}:${REMOTE_TGZ}"

echo "==> Sunucuda açılıyor"
ssh "${ssh_base[@]}" "$HOST" bash -s <<EOF
set -Eeuo pipefail
mkdir -p '$REMOTE_ROOT'
rm -rf '$REMOTE_ROOT/v2'
tar -C '$REMOTE_ROOT' -xzf '$REMOTE_TGZ'
find '$REMOTE_ROOT/v2' -name '._*' -delete
find '$REMOTE_ROOT/v2' -name '.DS_Store' -delete
chmod 0755 '$REMOTE_ROOT/v2/install.sh'
chmod 0755 '$REMOTE_ROOT/v2/scripts/'*
bash -n '$REMOTE_ROOT/v2/install.sh'
grep -E '^V2_VERSION=' '$REMOTE_ROOT/v2/install.sh'
echo "SYNC_OK → $REMOTE_ROOT/v2"
EOF

printf '\n==> Kurulum başlıyor: %s\n' "$HOST"
printf '    Promptlarda Enter = varsayılan. Tailscale URL gelince tarayıcıda onayla.\n\n'

set +e
ssh \
    -o ClearAllForwardings=yes \
    -o ConnectTimeout=20 \
    -t \
    "$HOST" \
    "bash '$REMOTE_ROOT/v2/install.sh'"
rc=$?
set -e

echo
if [[ "$rc" -eq 0 ]]; then
    echo "Kurulum oturumu bitti (exit 0)."
else
    echo "Kurulum oturumu bitti (exit $rc)." >&2
fi
pause_exit "$rc"

BODY_END
    printf '%s\n' "$MARKER"
    cat "$b64"
    printf '\n'
} >"$OUT_PATH"

chmod 0755 "$OUT_PATH"
# macOS: çift tık için execute bit; quarantine varsa kullanıcı ilk seferde açmalı
xattr -d com.apple.quarantine "$OUT_PATH" 2>/dev/null || true

bytes="$(wc -c <"$OUT_PATH" | tr -d ' ')"
echo "==> Yazıldı: $OUT_PATH ($bytes bayt, v$V2_VERSION)"

if [[ "$COPY_DESKTOP" -eq 1 ]]; then
    desk="${HOME}/Desktop"
    [[ -d "$desk" ]] || desk="${HOME}/Masaüstü"
    if [[ -d "$desk" ]]; then
        cp -f "$OUT_PATH" "$desk/$OUT_NAME"
        chmod 0755 "$desk/$OUT_NAME"
        xattr -d com.apple.quarantine "$desk/$OUT_NAME" 2>/dev/null || true
        echo "==> Masaüstü kopyası: $desk/$OUT_NAME"
    else
        echo "UYARI: Masaüstü klasörü bulunamadı; yalnız $OUT_PATH yazıldı" >&2
    fi
fi
