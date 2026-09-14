#!/bin/bash
# WireGuard peer menüsü (DD-124). Repo kökünde çift tıklanır; sunucudaki
# master-wg'yi SSH ile çağırır. Sunucuya hiçbir anahtar ya da profil gönderilmez:
# peer sunucuda üretilir, QR kodu terminale basılır, profil
# kurulum/wireguard/<ad>.conf olarak alınır. Finder bu dosyayı macOS /bin/bash
# 3.2 ile çalıştırır.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
INPUT_FILE="$ROOT/kurulum/kurulum.env"
DEFAULTS_FILE="$ROOT/Data/config/defaults.env"
INSTALLER="$ROOT/Data/install.sh"
WG_DIR="$ROOT/kurulum/wireguard"

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

[[ -f "$DEFAULTS_FILE" && -f "$INSTALLER" ]] || fail "Data/ bulunamadı; betiği repo kökünden çalıştırın."
[[ -f "$INPUT_FILE" ]] || fail "girdi dosyası yok: $INPUT_FILE"
# kurulum.env'den yalnız SSH_HOST okunur.
HOST="$(awk 'index($0, "SSH_HOST=") == 1 {print substr($0, 10); exit}' "$INPUT_FILE")"
[[ "$HOST" =~ ^[A-Za-z0-9._@-]+$ ]] || fail "kurulum.env içinde SSH_HOST boş ya da geçersiz"
LOCAL_VERSION="$(awk -F= '/^V2_VERSION=/{gsub(/"/, "", $2); print $2; exit}' "$INSTALLER")"
MASTER_WG="$(default_of SBIN_DIR)/master-wg"
DEFAULT_DNS="$(default_of WG_CLIENT_DNS_DEFAULT)"
DEFAULT_KEEPALIVE="$(default_of WG_CLIENT_KEEPALIVE_DEFAULT)"
DEFAULT_MTU="$(default_of WG_MTU)"

ctl_dir="$(mktemp -d "${TMPDIR:-/tmp}/wg-menu.XXXXXX")"
# ServerAlive: sunucu kaybolursa açık bağlantı dakikalarca asılı kalmasın.
ssh_base=(-o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=20
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o ControlMaster=auto -o "ControlPath=$ctl_dir/c" -o ControlPersist=120)
cleanup() {
    ssh "${ssh_base[@]}" -O exit "$HOST" >/dev/null 2>&1 || true
    rm -rf "$ctl_dir"
}
trap cleanup EXIT

# Uzak komut: argümanlar %q ile tırnaklanır, sunucu kabuğu tek tek ayırır.
remote() {
    local cmd
    cmd="$(printf '%q ' "$MASTER_WG" "$@")"
    ssh "${ssh_base[@]}" "$HOST" "$cmd"
}

ask() {
    local var="$1" msg="$2" def="${3:-}" reply=""
    if [[ -n "$def" ]]; then
        read -r -p "$msg [$def]: " reply || true
        reply="${reply:-$def}"
    else
        read -r -p "$msg: " reply || true
    fi
    printf -v "$var" '%s' "$reply"
}

human_bytes() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

list_peers() {
    local out name ip hs rx tx profile now ago
    out="$(remote list)" || return 1
    if [[ -z "$out" ]]; then
        echo "  (peer yok)"
        return 0
    fi
    now="$(date +%s)"
    # printf bayt sayar: çok baytlı başlıklar (Ş, İ) satırlarla aynı hizaya çekilir.
    printf '  %-16s %-12s %-18s %-12s %-13s %s\n' AD IP "SON EL SIKIŞMA" GELEN GİDEN PROFİL
    while IFS=$'\t' read -r name ip hs rx tx profile; do
        if [[ "$hs" == 0 ]]; then
            ago="hiç"
        elif (( now - hs < 120 )); then
            ago="$(( now - hs )) sn önce"
        elif (( now - hs < 7200 )); then
            ago="$(( (now - hs) / 60 )) dk önce"
        else
            ago="$(( (now - hs) / 3600 )) sa önce"
        fi
        printf '  %-16s %-12s %-18s %-12s %-12s %s\n' "$name" "$ip" "$ago" \
            "$(human_bytes "$rx")" "$(human_bytes "$tx")" "$profile"
    done <<<"$out"
}

fetch_profile() {
    local name="$1" tmp
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    tmp="$WG_DIR/.$name.conf.gelen"
    (umask 077 && remote profile "$name" >"$tmp") || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$WG_DIR/$name.conf"
    echo "Profil alındı: kurulum/wireguard/$name.conf"
}

add_peer() {
    local name dns keepalive mtu result
    ask name "Peer adı (harf, rakam, . _ -)"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || { echo "Geçersiz ad."; return 1; }
    ask dns "DNS" "$DEFAULT_DNS"
    ask keepalive "PersistentKeepalive (sn, 0 = kapalı)" "$DEFAULT_KEEPALIVE"
    ask mtu "MTU" "$DEFAULT_MTU"
    result="$(remote add "$name" "$dns" "$keepalive" "$mtu")" || return 1
    printf '\nEklendi: %s (%s) — sunucuda üretildi ve bağlantılar kopmadan uygulandı.\n' \
        "$name" "${result##*$'\t'}"
    fetch_profile "$name" || echo "UYARI: profil alınamadı; menüden '4) QR göster' ile yeniden alabilirsiniz." >&2
    printf '\n%s — WireGuard uygulamasıyla okutun:\n' "$name"
    remote qr "$name" || true
}

remove_peer() {
    local name confirm=""
    list_peers || return 1
    echo
    ask name "Çıkarılacak peer adı"
    [[ -n "$name" ]] || return 0
    ask confirm "'$name' sunucudan kaldırılsın, profili silinsin mi? (E/h)" "h"
    [[ "$confirm" =~ ^[EeYy]$ ]] || { echo "Vazgeçildi."; return 0; }
    remote remove "$name" >/dev/null || return 1
    rm -f "$WG_DIR/$name.conf"
    echo "Kaldırıldı: $name"
}

show_qr() {
    local name refresh=""
    list_peers || return 1
    echo
    ask name "QR'ı gösterilecek peer adı"
    [[ -n "$name" ]] || return 0
    remote qr "$name" || return 1
    ask refresh "Profil kurulum/wireguard'a da alınsın mı? (E/h)" "h"
    [[ ! "$refresh" =~ ^[EeYy]$ ]] || fetch_profile "$name" || true
}

printf '\n=== WireGuard peer yönetimi ===\n'
echo "==> Sunucu: $HOST"
remote_version="$(remote version 2>/dev/null)" ||
    fail "sunucuda master-wg yok ya da çalışmıyor; önce güncel kurulumu (<sürüm>.command) çalıştırın."
[[ "$remote_version" == "$LOCAL_VERSION" ]] ||
    fail "sunucudaki kurulum $remote_version, bu repo $LOCAL_VERSION; önce güncel kurulumu çalıştırın."

while true; do
    printf '\n--- %s (%s) ---\n' "$HOST" "$LOCAL_VERSION"
    printf '  1) Peer listesi\n  2) Peer ekle\n  3) Peer çıkar\n  4) QR göster\n  5) Çıkış\n'
    choice=""
    read -r -p "Seçim: " choice || break
    case "$choice" in
        1) list_peers || true ;;
        2) add_peer || true ;;
        3) remove_peer || true ;;
        4) show_qr || true ;;
        5 | q | Q) break ;;
        "") ;;
        *) echo "1-5 arası seçin." ;;
    esac
done
pause_exit 0
