#!/bin/bash
# Sunucudaki hazır ayarları kurulum/ klasörüne çeker (DD-128). Repo kökünde çift
# tıklanır; Finder bu dosyayı macOS /bin/bash 3.2 ile çalıştırır.
#   kurulum/wireguard/sunucu/wg0.conf  sunucu anahtarı + peer listesi
#   kurulum/wireguard/<ad>.conf        cihaz profilleri (sunucudakilerin aynası)
#   kurulum/qbittorrent/qBittorrent.conf  qBittorrent ayarları, hesap dahil
# Sunucu sıfırdan kurulduğunda <sürüm>.command bunları gönderir ve kurulum,
# sunucuda karşılıkları yoksa yerine koyar. Dosya içerikleri ekrana yazılmaz.
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
INPUT_FILE="$ROOT/kurulum/kurulum.env"
DEFAULTS_FILE="$ROOT/Data/config/defaults.env"
WG_DIR="$ROOT/kurulum/wireguard"
QB_DIR="$ROOT/kurulum/qbittorrent"
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'

pause_exit() {
    echo
    read -r -p "Pencereyi kapatmak için Enter..." || true
    exit "${1:-0}"
}

fail() {
    printf 'HATA: %s\n' "$*" >&2
    pause_exit 1
}

# defaults.env'den tek bir değer (source edilmez).
default_of() {
    awk -F= -v k="$1" '$1 == k {v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit}' "$DEFAULTS_FILE"
}

[[ -f "$DEFAULTS_FILE" ]] || fail "Data/ bulunamadı; betiği repo kökünden çalıştırın."
[[ -f "$INPUT_FILE" ]] || fail "girdi dosyası yok: $INPUT_FILE"
# kurulum.env'den yalnız SSH_HOST okunur.
HOST="$(awk 'index($0, "SSH_HOST=") == 1 {print substr($0, 10); exit}' "$INPUT_FILE")"
[[ "$HOST" =~ ^[A-Za-z0-9._@-]+$ ]] || fail "kurulum.env içinde SSH_HOST boş ya da geçersiz"
REMOTE_WG_CONF="$(default_of WG_CONF_FILE)"
REMOTE_WG_CLIENTS="$(default_of WG_CLIENTS_DIR)"
REMOTE_QB_DIR="$(default_of QBITTORRENT_DATA_DIR)/qBittorrent"
REMOTE_STATE="$(default_of STATE_FILE)"
for p in "$REMOTE_WG_CONF" "$REMOTE_WG_CLIENTS" "$REMOTE_QB_DIR" "$REMOTE_STATE"; do
    [[ "$p" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "defaults.env yolu beklenmeyen biçimde: $p"
done

work="$(mktemp -d "$ROOT/kurulum/.ayarlar.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

printf '\n=== Hazır ayarları çek ===\n'
echo "==> Sunucu: $HOST"
# Sunucu yalnız var olan dosyaları tar ile gönderir; içerik bu Mac'te diske
# iner, ekrana değil. Göreli yollar, sunucunun kök dizinine göredir.
if ! ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=20 "$HOST" bash -s -- \
    "$REMOTE_STATE" "$REMOTE_WG_CONF" "$REMOTE_WG_CLIENTS" "$REMOTE_QB_DIR" >"$work/ayarlar.tar" <<'REMOTE'
set -euo pipefail
state="$1" wg_conf="$2" wg_clients="$3" qb_dir="$4"
[[ -f "$state" ]] || { echo "sunucuda kurulum yok ($state)" >&2; exit 3; }
list=()
[[ ! -f "$wg_conf" ]] || list+=("${wg_conf#/}")
for f in "$wg_clients"/*.conf; do
    [[ ! -f "$f" ]] || list+=("${f#/}")
done
[[ ! -f "$qb_dir/qBittorrent.conf" ]] || list+=("${qb_dir#/}/qBittorrent.conf")
[[ "${#list[@]}" -gt 0 ]] || { echo "sunucuda çekilecek ayar yok" >&2; exit 4; }
tar -C / -cf - -- "${list[@]}"
REMOTE
then
    fail "sunucudan ayarlar alınamadı (bağlantı ya da sunucu hatası; ayrıntı yukarıda)"
fi
mkdir "$work/x"
tar -C "$work/x" -xf "$work/ayarlar.tar"
rm -f "$work/ayarlar.tar"

src_wg="$work/x${REMOTE_WG_CONF}"
src_clients="$work/x${REMOTE_WG_CLIENTS}"
src_qb="$work/x${REMOTE_QB_DIR}"

# Değişti mi? Yalnız özetler karşılaştırılır.
changed() {
    [[ ! -f "$2" ]] && return 0
    [[ "$(shasum -a 256 <"$1")" != "$(shasum -a 256 <"$2")" ]]
}

put() { # kaynak hedef etiket
    local dir
    dir="$(dirname -- "$2")"
    mkdir -p "$dir"
    chmod 700 "$dir"
    if changed "$1" "$2"; then
        cp -f "$1" "$2.gelen"
        chmod 600 "$2.gelen"
        mv -f "$2.gelen" "$2"
        printf '  %-40s değişti\n' "$3"
    else
        chmod 600 "$2"
        printf '  %-40s aynı\n' "$3"
    fi
}

mkdir -p "$ROOT/kurulum"
chmod 700 "$ROOT/kurulum"

if [[ -f "$src_wg" ]]; then
    grep -q '^PrivateKey = ' "$src_wg" || fail "sunucudaki wg0.conf'ta anahtar yok; çekilmedi"
    peers="$(grep -c '^\[Peer\]$' "$src_wg" || true)"
    put "$src_wg" "$WG_DIR/sunucu/wg0.conf" "WireGuard sunucu (anahtar + $peers peer)"
    # Cihaz profilleri sunucunun aynası: sunucuda olmayan yerel kopya kalkar.
    kept=" "
    for f in "$src_clients"/*.conf; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        name="${name%.conf}"
        [[ "$name" =~ $NAME_RE ]] || { echo "  UYARI: geçersiz profil adı atlandı: $name" >&2; continue; }
        put "$f" "$WG_DIR/$name.conf" "profil $name"
        kept="$kept$name "
    done
    for f in "$WG_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        name="${name%.conf}"
        case "$kept" in
            *" $name "*) ;;
            *) rm -f "$f" && printf '  %-40s silindi (sunucuda yok)\n' "profil $name" ;;
        esac
    done
else
    echo "  WireGuard: sunucuda yapılandırma yok; atlandı"
fi

if [[ -f "$src_qb/qBittorrent.conf" ]]; then
    grep -q 'Password_PBKDF2' "$src_qb/qBittorrent.conf" ||
        echo "  UYARI: qBittorrent hesabı henüz ayarlanmamış (parola yok); arayüzden ayarlayıp yeniden çekin" >&2
    put "$src_qb/qBittorrent.conf" "$QB_DIR/qBittorrent.conf" "qBittorrent qBittorrent.conf"
else
    echo "  qBittorrent: sunucuda ayar dosyası yok; atlandı"
fi

cat <<'EOF'

Tamam. Dosyalar kurulum/ altında (izin 600). Sunucu sıfırdan kurulduğunda
<sürüm>.command bunları gönderir; kurulum yalnız sunucuda karşılığı yoksa
yerine koyar. Ayar değiştirdikten sonra bu dosyayı yeniden çalıştırın.
EOF
pause_exit 0
