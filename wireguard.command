#!/bin/bash
# WireGuard peer menüsü (DD-124). Repo kökünde çift tıklanır; sunucudaki
# master-wg'yi SSH ile çağırır. Sunucuya hiçbir anahtar ya da profil gönderilmez:
# peer sunucuda üretilir, QR kodu terminale basılır, profil
# kurulum/wireguard/<ad>.conf, QR resmi <ad>.png olarak alınır (DD-132). "Yedek al" sunucu yapılandırmasını
# (wg0.conf) ve bütün profilleri kurulum/wireguard'a çeker; yeniden kurulumda
# kurulum bunları, sunucuda karşılığı yoksa geri koyar (DD-128). "DNS değiştir"
# yalnız profildeki DNS satırını, "wg0'ı yeniden üret" sunucu anahtarını ve
# bütün peer'ları sıfırlar (DD-130). Ekle, çıkar, DNS değiştir ve wg0'ı yeniden
# üret başarılı olunca yedek kendiliğinden alınır. Finder bu dosyayı macOS
# /bin/bash 3.2 ile çalıştırır.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
INPUT_FILE="$ROOT/kurulum/kurulum.env"
DEFAULTS_FILE="$ROOT/Data/config/defaults.env"
INSTALLER="$ROOT/Data/install.sh"
WG_DIR="$ROOT/kurulum/wireguard"
OLD_QB_DIR="$ROOT/kurulum/qbittorrent"
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
REMOTE_WG_CONF="$(default_of WG_CONF_FILE)"
REMOTE_WG_CLIENTS="$(default_of WG_CLIENTS_DIR)"
REMOTE_STATE="$(default_of STATE_FILE)"
for p in "$REMOTE_WG_CONF" "$REMOTE_WG_CLIENTS" "$REMOTE_STATE"; do
    [[ "$p" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "defaults.env yolu beklenmeyen biçimde: $p"
done

ctl_dir="$(mktemp -d "${TMPDIR:-/tmp}/wg-menu.XXXXXX")"
# ServerAlive: sunucu kaybolursa açık bağlantı dakikalarca asılı kalmasın.
ssh_base=(-o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=20
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o ControlMaster=auto -o "ControlPath=$ctl_dir/c" -o ControlPersist=120)
backup_work=""
cleanup() {
    ssh "${ssh_base[@]}" -O exit "$HOST" >/dev/null 2>&1 || true
    rm -rf "$ctl_dir"
    [[ -z "$backup_work" ]] || rm -rf "$backup_work"
}
trap cleanup EXIT

# Uzak komut: argümanlar %q ile tırnaklanır, sunucu kabuğu tek tek ayırır.
remote() {
    local cmd
    cmd="$(printf '%q ' "$MASTER_WG" "$@")"
    # -n: master-wg stdin okumaz; ssh menü girdisini yutmasın.
    ssh -n "${ssh_base[@]}" "$HOST" "$cmd"
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
    # DD-132: QR resmini sunucu üretir; profille aynı anahtarı taşır (izin 600).
    tmp="$WG_DIR/.$name.png.gelen"
    if (umask 077 && remote png "$name" >"$tmp") && is_png "$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$WG_DIR/$name.png"
        echo "QR resmi alındı: kurulum/wireguard/$name.png"
    else
        rm -f "$tmp"
        echo "UYARI: QR resmi alınamadı; '6) Yedek al' ile yeniden deneyin." >&2
    fi
}

is_png() {
    [[ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]]
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
    auto_backup
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
    rm -f "$WG_DIR/$name.conf" "$WG_DIR/$name.png"
    echo "Kaldırıldı: $name"
    auto_backup
}

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

# DD-130: profildeki DNS satırını değiştirir; anahtarlar ve wg0.conf aynı kalır.
# Cihaz yeni QR'ı (ya da kurulum/wireguard'daki dosyayı) içe aktarınca geçerli olur.
change_dns() {
    local name current dns result
    list_peers || return 1
    echo
    ask name "DNS'i değiştirilecek peer adı"
    [[ -n "$name" ]] || return 0
    [[ "$name" =~ $NAME_RE ]] || { echo "Geçersiz ad."; return 1; }
    # awk boruyu sonuna kadar okur: erken çıkış ssh'e SIGPIPE verirdi.
    current="$(remote profile "$name" | awk -F' = ' '$1 == "DNS" {v = $2} END {print v}')" || return 1
    ask dns "Yeni DNS" "${current:-$DEFAULT_DNS}"
    result="$(remote dns "$name" "$dns")" || return 1
    printf '\nDNS değişti: %s → %s (anahtarlar aynı).\n' "$name" "${result#*$'\t'}"
    fetch_profile "$name" || echo "UYARI: profil alınamadı; menüden '4) QR göster' ile yeniden alabilirsiniz." >&2
    printf '\n%s — yeni profil; cihazda WireGuard uygulamasıyla okutun (eski tüneli silin):\n' "$name"
    remote qr "$name" || true
    auto_backup
}

# DD-130: sunucuda yeni anahtar üretir, bütün peer kayıtlarını ve profilleri
# siler; ardından kurulum/wireguard yedeğini bu temiz hale eşitler. Yazılı onay ister.
regenerate_wg0() {
    local out confirm=""
    echo
    echo "UYARI: sunucuda yeni bir WireGuard anahtarı üretilir; bütün peer kayıtları ve profilleri silinir."
    echo "       Kayıtlı cihazların hiçbiri bağlanamaz; hepsinin '2) Peer ekle' ile yeniden eklenmesi gerekir."
    echo "       Ardından kurulum/wireguard yedeği de bu temiz hale eşitlenir (eski profiller silinir)."
    echo
    list_peers || return 1
    echo
    ask confirm "Devam etmek için SIL yazın"
    case "$confirm" in
        SIL | SİL) ;;
        *) echo "Vazgeçildi; hiçbir şey değişmedi."; return 0 ;;
    esac
    out="$(remote reset --onay)" || return 1
    printf '\nwg0 yeniden üretildi: %s peer ve %s profil silindi; yeni sunucu anahtarı etkin.\n' \
        "${out%%$'\t'*}" "${out##*$'\t'}"
    auto_backup
}

# DD-130: sunucuda değişiklik başarılı olunca kurulum/wireguard eşitlenir; yeniden
# kurulum silinmiş bir peer'ı ya da eski anahtarı geri getirmez.
auto_backup() {
    echo
    echo "Yedek güncelleniyor (kurulum/wireguard):"
    backup_settings || echo "UYARI: yedek eşitlenemedi; '6) Yedek al' ile yeniden deneyin." >&2
}

# DD-128: sunucu yapılandırmasını (anahtar + peer listesi) ve bütün profilleri
# kurulum/wireguard'a çeker; içerik ekrana yazılmaz. Profiller sunucunun aynası
# olur. Yeniden kurulumda <sürüm>.command bunları gönderir ve kurulum, sunucuda
# wg0.conf yoksa yerine koyar.
backup_settings() {
    local src_wg src_clients f name ext peers kept=" "
    mkdir -p "$ROOT/kurulum"
    chmod 700 "$ROOT/kurulum"
    backup_work="$(mktemp -d "$ROOT/kurulum/.yedek.XXXXXX")"
    # Sunucu yalnız var olan dosyaları, köke göre göreli yollarla tar olarak
    # gönderir; bu Mac'te diske iner, ekrana değil.
    if ! ssh "${ssh_base[@]}" "$HOST" bash -s -- \
        "$REMOTE_STATE" "$REMOTE_WG_CONF" "$REMOTE_WG_CLIENTS" "$MASTER_WG" >"$backup_work/yedek.tar" <<'REMOTE'
set -euo pipefail
state="$1" wg_conf="$2" wg_clients="$3" master_wg="$4"
[[ -f "$state" ]] || { echo "sunucuda kurulum yok ($state)" >&2; exit 3; }
[[ -f "$wg_conf" ]] || { echo "sunucuda WireGuard yapılandırması yok" >&2; exit 4; }
# QR resimleri (DD-132) root'a özel geçici dizinde, profille aynı göreli yolda üretilir.
work="$(mktemp -d "${TMPDIR:-/run}/wg-yedek.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/${wg_clients#/}"
list=("${wg_conf#/}") pngs=()
for f in "$wg_clients"/*.conf; do
    [[ -f "$f" ]] || continue
    list+=("${f#/}")
    name="${f##*/}"
    name="${name%.conf}"
    if "$master_wg" png "$name" >"$work/${wg_clients#/}/$name.png"; then
        pngs+=("${wg_clients#/}/$name.png")
    else
        echo "UYARI: $name için QR resmi üretilemedi" >&2
    fi
done
# Yollar köke göreli ("etc/..."), tire ile başlamaz.
tar -cf - -C / "${list[@]}" -C "$work" ${pngs[@]+"${pngs[@]}"}
REMOTE
    then
        echo "HATA: yedek alınamadı (bağlantı ya da sunucu hatası; ayrıntı yukarıda)" >&2
        rm -rf "$backup_work"
        backup_work=""
        return 1
    fi
    mkdir "$backup_work/x"
    tar -C "$backup_work/x" -xf "$backup_work/yedek.tar"
    src_wg="$backup_work/x${REMOTE_WG_CONF}"
    src_clients="$backup_work/x${REMOTE_WG_CLIENTS}"
    if ! grep -q '^PrivateKey = ' "$src_wg"; then
        echo "HATA: sunucudaki wg0.conf'ta anahtar yok; yedek alınmadı" >&2
        rm -rf "$backup_work"
        backup_work=""
        return 1
    fi
    peers="$(grep -c '^\[Peer\]$' "$src_wg" || true)"
    echo
    put "$src_wg" "$WG_DIR/sunucu/wg0.conf" "sunucu (anahtar + $peers peer)"
    for f in "$src_clients"/*.conf; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        name="${name%.conf}"
        [[ "$name" =~ $NAME_RE ]] || { echo "  UYARI: geçersiz profil adı atlandı: $name" >&2; continue; }
        put "$f" "$WG_DIR/$name.conf" "profil $name"
        [[ ! -f "$src_clients/$name.png" ]] || put "$src_clients/$name.png" "$WG_DIR/$name.png" "QR resmi $name"
        kept="$kept$name "
    done
    for f in "$WG_DIR"/*.conf "$WG_DIR"/*.png; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        ext="${name##*.}"
        name="${name%.*}"
        case "$kept" in
            *" $name "*) ;;
            *) rm -f "$f" && printf '  %-40s silindi (sunucuda yok)\n' "$([[ "$ext" == png ]] && echo "QR resmi" || echo profil) $name" ;;
        esac
    done
    # v2-93'ün çektiği qBittorrent kopyası artık kullanılmıyor (DD-129); parola
    # özeti taşıdığı için kaldırılır.
    if [[ -f "$OLD_QB_DIR/qBittorrent.conf" ]]; then
        rm -f "$OLD_QB_DIR/qBittorrent.conf"
        rmdir "$OLD_QB_DIR" 2>/dev/null || true
        printf '  %-40s silindi (artık kurulum.env + şablon)\n' "eski qBittorrent kopyası"
    fi
    rm -rf "$backup_work"
    backup_work=""
    echo "Yedek kurulum/wireguard altında (izin 600). Yeniden kurulumda <sürüm>.command bunları gönderir."
}

show_qr() {
    local name refresh=""
    list_peers || return 1
    echo
    ask name "QR'ı gösterilecek peer adı"
    [[ -n "$name" ]] || return 0
    remote qr "$name" || return 1
    ask refresh "Profil ve QR resmi kurulum/wireguard'a da alınsın mı? (E/h)" "h"
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
    printf '  6) Yedek al (sunucu anahtarı + peer listesi + profiller → kurulum/wireguard)\n'
    printf '  7) DNS değiştir (anahtarlar aynı, yeni QR)\n'
    printf '  8) wg0 yeniden üret (yeni anahtar, bütün peer%s silinir)\n' "'lar"
    choice=""
    read -r -p "Seçim: " choice || break
    case "$choice" in
        1) list_peers || true ;;
        2) add_peer || true ;;
        3) remove_peer || true ;;
        4) show_qr || true ;;
        5 | q | Q) break ;;
        6) backup_settings || true ;;
        7) change_dns || true ;;
        8) regenerate_wg0 || true ;;
        "") ;;
        *) echo "1-8 arası seçin." ;;
    esac
done
pause_exit 0
