#!/usr/bin/env bash
# v2 runtime'ını gömülü tek bir macOS .command dosyasına paketler.
# Her export: v2/app/<V2_VERSION>.command (sürüm adıyla arşivlenir).
set -Eeuo pipefail

DEV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$DEV_DIR/../.." && pwd)"
V2_ROOT="$REPO_ROOT/v2"
APP_DIR="$V2_ROOT/app"
MARKER="__MASTER_STACK_V2_ARCHIVE__"

V2_VERSION="$(awk -F= '/^V2_VERSION=/{gsub(/"/,"",$2); print $2; exit}' "$V2_ROOT/install.sh")"
[[ -n "$V2_VERSION" ]] || { echo "HATA: V2_VERSION okunamadı" >&2; exit 1; }

OUT_NAME="${V2_VERSION}.command"
COPY_DESKTOP=0
OUT_PATH=""
SETTINGS_BUNDLE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop) COPY_DESKTOP=1; shift ;;
        --settings-bundle) SETTINGS_BUNDLE="$2"; shift 2 ;;
        -o|--output) OUT_PATH="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Kullanım: $(basename "$0") [--desktop] [--settings-bundle FILE] [-o PATH]

  (varsayılan) v2/app/${V2_VERSION}.command — sürüm adıyla kaydet
  --desktop     aynı dosyayı ~/Desktop (veya ~/Masaüstü) altına da kopyala
  --settings-bundle FILE
                özel dört-servis ayar paketini runtime'a 0600 olarak ekle
  -o PATH       çıktı yolunu elle seç
EOF
            exit 0
            ;;
        *) echo "HATA: bilinmeyen argüman: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$OUT_PATH" ]] || OUT_PATH="$APP_DIR/$OUT_NAME"
if [[ -n "$SETTINGS_BUNDLE" ]]; then
    [[ -f "$SETTINGS_BUNDLE" && ! -L "$SETTINGS_BUNDLE" && -r "$SETTINGS_BUNDLE" ]] || {
        echo "HATA: ayar paketi normal/okunabilir dosya değil: $SETTINGS_BUNDLE" >&2
        exit 1
    }
fi

file_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    else
        shasum -a 256 "$f" | awk '{print $1}'
    fi
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/dsi-v2-portable.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

tgz="$tmpdir/v2.tgz"
stage="$tmpdir/src"
mkdir -p "$stage"
echo "==> Paketleniyor: v2/ runtime (v$V2_VERSION) [deterministik]"
# Sabit mtime + gzip -n → aynı kaynak = aynı ARCHIVE_SHA256.
# TZ=UTC + 2000-01-01: doğu TZ'de 1970-01-01 local Unix epoch öncesi olur
# (mtime 0 → Debian tar "implausibly old"). --no-xattrs/--no-mac-metadata:
# Apple provenance pax başlıkları Debian'da LIBARCHIVE uyarısı üretmesin.
rsync -a \
    --exclude='.cursor/' \
    --exclude='dev/' \
    --exclude='tests/' \
    --exclude='dist/' \
    --exclude='app/' \
    --exclude='private/' \
    --exclude='settings/' \
    --exclude='._*' \
    --exclude='.DS_Store' \
    "$V2_ROOT/" "$stage/v2/"
if [[ -n "$SETTINGS_BUNDLE" ]]; then
    mkdir -p "$stage/v2/settings"
    install -m 0600 "$SETTINGS_BUNDLE" \
        "$stage/v2/settings/master-stack-settings-v3.tar.gz"
    echo "==> Ayar paketi eklendi: $(file_sha256 "$SETTINGS_BUNDLE")"
fi
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
        -cf - v2 | gzip -n >"$tgz"
)

ARCHIVE_SHA256="$(file_sha256 "$tgz")"
[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "HATA: arşiv sha256 üretilemedi" >&2
    exit 1
}

b64="$tmpdir/v2.b64"
base64 <"$tgz" | tr -d '\n' >"$b64"
fold -w 76 "$b64" >"$b64.folded"
mv "$b64.folded" "$b64"

mkdir -p "$(dirname -- "$OUT_PATH")"
# Duvar saati .command hash'ini kirletmesin; sürüm kimliği yeterli.
built_at="reproducible/${V2_VERSION}"
portable_settings_seed="YOK"
output_mode=0755
if [[ -n "$SETTINGS_BUNDLE" ]]; then
    portable_settings_seed="ŞİFRESİZ-4-SERVİS"
    output_mode=0700
fi

{
    cat <<'HEADER_END'
#!/usr/bin/env bash
# Master Stack v2 — taşınabilir tek dosya kurulum (macOS .command)
# Repo'ya ihtiyaç duymaz. Masaüstü'ne kopyalayıp çift tıklayın.
# Yeniden üretmek: v2/dev/export-v2.sh
set -Eeuo pipefail

HEADER_END
    cat <<EOF
PORTABLE_V2_VERSION="$V2_VERSION"
PORTABLE_BUILT_AT="$built_at"
PORTABLE_ARCHIVE_SHA256="$ARCHIVE_SHA256"
PORTABLE_SETTINGS_SEED="$portable_settings_seed"
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

tgz="$(mktemp "${TMPDIR:-/tmp}/dsi-v2-embed.XXXXXX.tgz")"
cleanup_local() { rm -f "$tgz"; }
trap cleanup_local EXIT

printf '\n=== Master Stack v2 — taşınabilir kurulum ===\n'
printf 'Sürüm:  %s\n' "$PORTABLE_V2_VERSION"
printf 'Üretim: %s\n' "$PORTABLE_BUILT_AT"
printf 'SHA256: %s\n' "$PORTABLE_ARCHIVE_SHA256"
if [[ "$PORTABLE_SETTINGS_SEED" == "ŞİFRESİZ-4-SERVİS" ]]; then
    printf 'AYAR PAKETİ: VAR — Portainer/FileBrowser/qBittorrent/wg-easy (parola yok)\n\n'
else
    printf 'AYAR PAKETİ: YOK — dört servis boş/yeni ayarla başlayacak\n\n'
fi

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
staging="\$(mktemp -d /tmp/dsi-v2-extract.XXXXXX)"
cleanup_staging() { rm -rf "\$staging"; }
trap cleanup_staging EXIT
tar -C "\$staging" -xzf "\$remote_tgz"
[[ -f "\$staging/v2/install.sh" ]] || {
    echo "HATA: arşivde v2/install.sh yok" >&2
    exit 1
}
mkdir -p "\$remote_root"
rm -rf "\$remote_root/v2"
mv "\$staging/v2" "\$remote_root/v2"
trap - EXIT
rmdir "\$staging" 2>/dev/null || rm -rf "\$staging"
find "\$remote_root/v2" -name '._*' -delete
find "\$remote_root/v2" -name '.DS_Store' -delete
chmod 0755 "\$remote_root/v2/install.sh"
chmod 0755 "\$remote_root/v2/scripts/"*
bash -n "\$remote_root/v2/install.sh"
grep -E '^V2_VERSION=' "\$remote_root/v2/install.sh"
echo "SYNC_OK → \$remote_root/v2"
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

chmod "$output_mode" "$OUT_PATH"
xattr -d com.apple.quarantine "$OUT_PATH" 2>/dev/null || true

bytes="$(wc -c <"$OUT_PATH" | tr -d ' ')"
echo "==> Yazıldı: $OUT_PATH ($bytes bayt)"
echo "==> SHA256 (gömülü arşiv): $ARCHIVE_SHA256"

latest_link="$APP_DIR/latest.command"
if [[ -z "$SETTINGS_BUNDLE" &&
      "$(cd -- "$(dirname -- "$OUT_PATH")" && pwd)" == "$(cd -- "$APP_DIR" && pwd)" ]]; then
    cp -f "$OUT_PATH" "$latest_link"
    chmod 0755 "$latest_link"
    xattr -d com.apple.quarantine "$latest_link" 2>/dev/null || true
    echo "==> latest: $latest_link"
fi

if [[ "$COPY_DESKTOP" -eq 1 ]]; then
    desk="${HOME}/Desktop"
    [[ -d "$desk" ]] || desk="${HOME}/Masaüstü"
    if [[ -d "$desk" ]]; then
        cp -f "$OUT_PATH" "$desk/$OUT_NAME"
        chmod "$output_mode" "$desk/$OUT_NAME"
        xattr -d com.apple.quarantine "$desk/$OUT_NAME" 2>/dev/null || true
        echo "==> Masaüstü: $desk/$OUT_NAME"
    else
        echo "UYARI: Masaüstü klasörü bulunamadı; yalnız $OUT_PATH yazıldı" >&2
    fi
fi
