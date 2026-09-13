#!/usr/bin/env bash
# Kurulum çalışma dosyalarını gömülü tek bir macOS .command dosyasına paketler.
# Her export: Data/app/<V2_VERSION>.command (sürüm arşivi) + repo kökünde
# güncel sürümün kopyası (çift tıklanan dosya).
set -Eeuo pipefail

DEV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Kurulum ağacı Data/ altında; çift tıklanan dosyalar repo kökünde.
REPO_ROOT="$(cd -- "$DEV_DIR/.." && pwd)"
TOP_DIR="$(cd -- "$REPO_ROOT/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
MARKER="__MASTER_STACK_ARCHIVE__"

V2_VERSION="$(awk -F= '/^V2_VERSION=/{gsub(/"/,"",$2); print $2; exit}' "$REPO_ROOT/install.sh")"
[[ -n "$V2_VERSION" ]] || { echo "HATA: V2_VERSION okunamadı" >&2; exit 1; }

OUT_NAME="${V2_VERSION}.command"
COPY_DESKTOP=0
OUT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop) COPY_DESKTOP=1; shift ;;
        -o|--output) OUT_PATH="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Kullanım: $(basename "$0") [--desktop] [-o PATH]

  (varsayılan) Data/app/${V2_VERSION}.command — sürüm adıyla kaydet,
                repo köküne güncel kopya (kökteki önceki sürüm kaldırılır)
  --desktop     aynı dosyayı ~/Desktop (veya ~/Masaüstü) altına da kopyala
  -o PATH       çıktı yolunu elle seç
EOF
            exit 0
            ;;
        *) echo "HATA: bilinmeyen argüman: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$OUT_PATH" ]] || OUT_PATH="$APP_DIR/$OUT_NAME"

file_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    else
        shasum -a 256 "$f" | awk '{print $1}'
    fi
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/dsi-portable.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

tgz="$tmpdir/installer.tgz"
stage="$tmpdir/src"
mkdir -p "$stage/installer"
echo "==> Paketleniyor: kurulum çalışma dosyaları ($V2_VERSION) [deterministik]"
# Sabit mtime + gzip -n → aynı kaynak = aynı ARCHIVE_SHA256.
# TZ=UTC + 2000-01-01: doğu TZ'de 1970-01-01 local Unix epoch öncesi olur
# (mtime 0 → Debian tar "implausibly old"). --no-xattrs/--no-mac-metadata:
# Apple provenance pax başlıkları Debian'da LIBARCHIVE uyarısı üretmesin.
rsync -a \
    --exclude='._*' \
    --exclude='.DS_Store' \
    "$REPO_ROOT/install.sh" \
    "$REPO_ROOT/common.sh" \
    "$REPO_ROOT/config" \
    "$REPO_ROOT/templates" \
    "$REPO_ROOT/scripts" \
    "$REPO_ROOT/systemd" \
    "$stage/installer/"
xattr -cr "$stage" 2>/dev/null || true
TZ=UTC find "$stage" -exec touch -t 200001010000 {} +
(
    cd -- "$stage" || exit 1
    COPYFILE_DISABLE=1 tar \
        --format=ustar \
        --no-xattrs \
        --no-mac-metadata \
        --uid 0 --gid 0 \
        --uname root --gname root \
        -cf - installer | gzip -n >"$tgz"
)

ARCHIVE_SHA256="$(file_sha256 "$tgz")"
[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "HATA: arşiv sha256 üretilemedi" >&2
    exit 1
}

b64="$tmpdir/installer.b64"
base64 <"$tgz" | tr -d '\n' >"$b64"
fold -w 76 "$b64" >"$b64.folded"
mv "$b64.folded" "$b64"

mkdir -p "$(dirname -- "$OUT_PATH")"
# Duvar saati .command hash'ini kirletmesin; sürüm kimliği yeterli.
built_at="reproducible/${V2_VERSION}"

{
    cat <<'HEADER_END'
#!/usr/bin/env bash
# Master Stack — taşınabilir tek dosya kurulum (macOS .command)
# Repo'ya ihtiyaç duymaz. Masaüstü'ne kopyalayıp çift tıklayın.
# Yeniden üretmek: dev/export-installer.sh
set -Eeuo pipefail

HEADER_END
    cat <<EOF
PORTABLE_INSTALLER_VERSION="$V2_VERSION"
PORTABLE_BUILT_AT="$built_at"
PORTABLE_ARCHIVE_SHA256="$ARCHIVE_SHA256"
ARCHIVE_MARKER="$MARKER"
EOF
    cat <<'BODY_END'

DEFAULT_HOST="${DEPLOY_HOST:-nrm}"
REMOTE_TGZ="/tmp/debian-server-installer.tgz"
REMOTE_ROOT="/root/debian-server-installer"

pause_exit() {
    local rc="${1:-0}"
    echo
    read -r -p "Pencereyi kapatmak için Enter..." || true
    exit "$rc"
}

file_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    else
        shasum -a 256 "$f" | awk '{print $1}'
    fi
}

here="$(cd -- "$(dirname -- "$0")" && pwd)"
self="$here/$(basename -- "$0")"
[[ -f "$self" ]] || { echo "HATA: betik yolu bulunamadı: $self" >&2; pause_exit 1; }

tgz="$(mktemp "${TMPDIR:-/tmp}/dsi-embed.XXXXXX.tgz")"
cleanup_local() { rm -f "$tgz"; }
trap cleanup_local EXIT

printf '\n=== Master Stack — taşınabilir kurulum ===\n'
printf 'Sürüm:  %s\n' "$PORTABLE_INSTALLER_VERSION"
printf 'Üretim: %s\n' "$PORTABLE_BUILT_AT"
printf 'SHA256: %s\n\n' "$PORTABLE_ARCHIVE_SHA256"

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

got_sha="$(file_sha256 "$tgz")"
[[ "$got_sha" == "$PORTABLE_ARCHIVE_SHA256" ]] || {
    echo "HATA: arşiv sha256 uyuşmuyor" >&2
    echo "  beklenen: $PORTABLE_ARCHIVE_SHA256" >&2
    echo "  bulunan:  $got_sha" >&2
    pause_exit 1
}
echo "==> SHA256 doğrulandı"

ssh_base=(-o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=20)

echo "==> SSH kontrol: $HOST"
ssh "${ssh_base[@]}" "$HOST" 'printf "OK user=%s host=%s\n" "$(id -un)" "$(hostname)"'

echo "==> Kopyalanıyor → ${HOST}:${REMOTE_TGZ}"
scp "${ssh_base[@]}" "$tgz" "${HOST}:${REMOTE_TGZ}"

echo "==> Sunucuda açılıyor (atomik + sha256)"
ssh "${ssh_base[@]}" "$HOST" bash -s <<EOF
set -Eeuo pipefail
expect='$PORTABLE_ARCHIVE_SHA256'
remote_tgz='$REMOTE_TGZ'
remote_root='$REMOTE_ROOT'
got="\$(sha256sum "\$remote_tgz" | awk '{print \$1}')"
[[ "\$got" == "\$expect" ]] || {
    echo "HATA: uzak arşiv sha256 uyuşmuyor (\$got)" >&2
    exit 1
}
staging="\$(mktemp -d /tmp/dsi-extract.XXXXXX)"
incoming="\${remote_root}.incoming.\$\$"
previous="\${remote_root}.previous.\$\$"
cleanup_staging() {
    rm -rf "\$staging" "\$incoming"
    if [[ ! -e "\$remote_root" && -e "\$previous" ]]; then
        mv "\$previous" "\$remote_root"
    fi
}
trap cleanup_staging EXIT
tar -C "\$staging" -xzf "\$remote_tgz"
[[ -f "\$staging/installer/install.sh" ]] || {
    echo "HATA: arşivde install.sh yok" >&2
    exit 1
}
rm -rf "\$incoming" "\$previous"
mv "\$staging/installer" "\$incoming"
if [[ -e "\$remote_root" ]]; then
    mv "\$remote_root" "\$previous"
fi
if ! mv "\$incoming" "\$remote_root"; then
    [[ ! -e "\$previous" ]] || mv "\$previous" "\$remote_root"
    exit 1
fi
rm -rf "\$previous"
trap - EXIT
rmdir "\$staging" 2>/dev/null || rm -rf "\$staging"
find "\$remote_root" -name '._*' -delete
find "\$remote_root" -name '.DS_Store' -delete
chmod 0755 "\$remote_root/install.sh"
chmod 0755 "\$remote_root/scripts/"*
bash -n "\$remote_root/install.sh"
grep -E '^V2_VERSION=' "\$remote_root/install.sh"
echo "SYNC_OK → \$remote_root"
EOF

printf '\n==> Kurulum başlıyor: %s\n' "$HOST"
printf '    Promptlarda Enter = varsayılan. Tailscale URL gelince tarayıcıda onayla.\n\n'

set +e
ssh \
    -o ClearAllForwardings=yes \
    -o ConnectTimeout=20 \
    -t \
    "$HOST" \
    "bash '$REMOTE_ROOT/install.sh'"
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
xattr -d com.apple.quarantine "$OUT_PATH" 2>/dev/null || true

bytes="$(wc -c <"$OUT_PATH" | tr -d ' ')"
echo "==> Yazıldı: $OUT_PATH ($bytes bayt)"
echo "==> SHA256 (gömülü arşiv): $ARCHIVE_SHA256"

# Repo kökünde yalnız güncel sürüm durur; önceki sürümlerin kopyası kalkar,
# arşivleri Data/app/ altında kalır.
if [[ "$(cd -- "$(dirname -- "$OUT_PATH")" && pwd)" == "$(cd -- "$APP_DIR" && pwd)" ]]; then
    for old in "$TOP_DIR"/20[0-9][0-9].[0-9][0-9].[0-9][0-9]-v2-*.command; do
        if [[ -f "$old" && "$old" != "$TOP_DIR/$OUT_NAME" ]]; then rm -f -- "$old"; fi
    done
    cp -f "$OUT_PATH" "$TOP_DIR/$OUT_NAME"
    chmod 0755 "$TOP_DIR/$OUT_NAME"
    xattr -d com.apple.quarantine "$TOP_DIR/$OUT_NAME" 2>/dev/null || true
    echo "==> kök: $TOP_DIR/$OUT_NAME"
fi

if [[ "$COPY_DESKTOP" -eq 1 ]]; then
    desk="${HOME}/Desktop"
    [[ -d "$desk" ]] || desk="${HOME}/Masaüstü"
    if [[ -d "$desk" ]]; then
        cp -f "$OUT_PATH" "$desk/$OUT_NAME"
        chmod 0755 "$desk/$OUT_NAME"
        xattr -d com.apple.quarantine "$desk/$OUT_NAME" 2>/dev/null || true
        echo "==> Masaüstü: $desk/$OUT_NAME"
    else
        echo "UYARI: Masaüstü klasörü bulunamadı; yalnız $OUT_PATH yazıldı" >&2
    fi
fi
