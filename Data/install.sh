#!/usr/bin/env bash
# Kurulum — Debian 13 / Ubuntu 24.04 / 26.04 LTS, doğrusal aşamalar,
# tekrar çalıştırılabilir.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

V2_VERSION="2026.08.06-v2-125"
V2_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "$V2_ROOT/common.sh"
# shellcheck source=config/defaults.env
source "$V2_ROOT/config/defaults.env"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
V2_LOG_FILE="${V2_LOG_FILE:-$LOG_DIR/install.log}"
# retry fonksiyonları ayrı bash'te çalıştırır; apt çıktısı loga oradan da yazılsın.
export V2_LOG_FILE
RUN_FULL_UPGRADE=0
FIREWALL_NEEDS_RESTART=0
# state.env'de kayıtlı OS kimliği canlı os-release ile uyuşmuyorsa 1 olur;
# OS'a bağlı adımlar dosya içeriği aynı kalsa bile yeniden uygulanır (DD-104).
OS_CHANGED=0
# Ubuntu'da unattended-upgrades varsayılan açık: apt kilidi dakikalarca
# tutulabilir. Kilitte hemen düşmek yerine bekle; retry üstte ayrıca sarar.
# Kurulumun indirdiği .deb'ler kurulduktan sonra önbellekte bırakılmaz
# (~300 MB; DD-125). Başkasının önbelleğe koyduğu dosyaya dokunulmaz.
APT_OPTS=(-o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false)
# DD-119: kurulum girdi dosyasının alanları (şablon: config/kurulum.env.example).
# Hepsi dosyada yazılı olmalı. Boş alan adı defaults.env varsayılanını alır. Tailscale'e
# her zaman giriş bağlantısıyla katılınır (DD-147). SSH_HOST'u yalnız launcher okur.
# Kullanıcı alanı sorulmaz: SERVER_ROOT sabittir (DD-144). Servis hesabı girdisi yok: her
# modül kendi hesabını Konsol'da gösterir (DD-148, DD-149, DD-151).
INPUT_KEYS="SSH_HOST LOCAL_DOMAIN"
INPUT_NONEMPTY_KEYS=""

prompt() {
    local var="$1" msg="$2" default="${3:-}"
    local reply=""
    if [[ -n "$default" ]]; then
        read -r -p "$msg [$default]: " reply </dev/tty || true
        reply="${reply:-$default}"
    else
        read -r -p "$msg: " reply </dev/tty || true
    fi
    [[ -n "$reply" ]] || die "değer boş olamaz: $msg"
    printf -v "$var" '%s' "$reply"
}

write_state() {
    atomic_write "$STATE_FILE" 0600 <<EOF
V2_VERSION=$V2_VERSION
WAN_INTERFACE=$WAN_INTERFACE
WAN_IPV4=$WAN_IPV4
WAN_IPV6=$WAN_IPV6
TAILSCALE_IF=$TAILSCALE_IF
TAILSCALE_UDP_PORT=$TAILSCALE_UDP_PORT
TAILSCALE_IPV4=$TAILSCALE_IPV4
TAILSCALE_IPV6=$TAILSCALE_IPV6
LOCAL_DOMAIN=$LOCAL_DOMAIN
SERVER_ROOT=$SERVER_ROOT
DOWNLOADS_PATH=$DOWNLOADS_PATH
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST
WG_PORT_DEFAULT=$WG_PORT_DEFAULT
SSH_PUBLIC_PORT=$SSH_PUBLIC_PORT
CHAIN_INPUT=$CHAIN_INPUT
CHAIN_FORWARD=$CHAIN_FORWARD
CHAIN_NAT=$CHAIN_NAT
CHAIN_STAGING_PREFIX=$CHAIN_STAGING_PREFIX
WG_ADDR_BASE4=$WG_ADDR_BASE4
WG_ADDR_BASE6=$WG_ADDR_BASE6
WG_CONF_DIR=$WG_CONF_DIR
WG_CLIENTS_DIR=$WG_CLIENTS_DIR
WG_MTU=$WG_MTU
WG_NETWORKS_FILE=$WG_NETWORKS_FILE
WG_NETWORKS_MAX=$WG_NETWORKS_MAX
WG_PANEL_PORT=$WG_PANEL_PORT
MODULES_FILE=$MODULES_FILE
MODULES_DIR=$MODULES_DIR
FILES_PANEL_PORT=$FILES_PANEL_PORT
SHARE_PORT=$SHARE_PORT
SHARE_DIR=$SHARE_DIR
SHARE_HTPASSWD_FILE=$SHARE_HTPASSWD_FILE
SHARE_CRED_FILE=$SHARE_CRED_FILE
SHARE_ACCOUNT=$SHARE_ACCOUNT
SHARE_PASSWORD_LENGTH=$SHARE_PASSWORD_LENGTH
STATE_DIR=$STATE_DIR
SBIN_DIR=$SBIN_DIR
UNIT_DIR=$UNIT_DIR
DOWNLOADS_UID=$DOWNLOADS_UID
DOWNLOADS_GID=$DOWNLOADS_GID
FILES_PANEL_TRASH=$FILES_PANEL_TRASH
WG_MODULES_LOAD_FILE=$WG_MODULES_LOAD_FILE
CADDYFILE=$CADDYFILE
CADDY_MODULES_DIR=$CADDY_MODULES_DIR
CADDY_WG_FILE=$CADDY_WG_FILE
DNSMASQ_CONF_DIR=$DNSMASQ_CONF_DIR
WG_CLIENT_ALLOWED_IPS="$WG_CLIENT_ALLOWED_IPS"
RUNTIME_DIR=$RUNTIME_DIR
TORRENT_UI_PORT=$TORRENT_UI_PORT
TORRENT_PROFILE_DIR=$TORRENT_PROFILE_DIR
RCLONE_VERSION=$RCLONE_VERSION
RCLONE_SHA256_AMD64=$RCLONE_SHA256_AMD64
RCLONE_SHA256_ARM64=$RCLONE_SHA256_ARM64
RCLONE_DOWNLOAD_URL=$RCLONE_DOWNLOAD_URL
RCLONE_BIN=$RCLONE_BIN
OS_ID=$OS_ID
OS_CODENAME=$OS_CODENAME
OS_VERSION_ID=$OS_VERSION_ID
OS_ARCH=$OS_ARCH
KERNEL_RELEASE=$(uname -r)
EOF
}

# Kurulumun hangi OS üzerinde yapıldığını state.env'den okur. Kayıt eksikse
# sürüm değişimi iddia edilmez.
detect_os_change() {
    [[ -r "$STATE_FILE" ]] || return 0
    local prev_id prev_codename prev_version
    prev_id="$(awk -F= '/^OS_ID=/{print $2; exit}' "$STATE_FILE" || true)"
    prev_codename="$(awk -F= '/^OS_CODENAME=/{print $2; exit}' "$STATE_FILE" || true)"
    prev_version="$(awk -F= '/^OS_VERSION_ID=/{print $2; exit}' "$STATE_FILE" || true)"
    [[ -n "$prev_id" && -n "$prev_codename" ]] || return 0
    if [[ "$prev_id" == "$OS_ID" && "$prev_codename" == "$OS_CODENAME" &&
        "$prev_version" == "$OS_VERSION_ID" ]]; then
        return 0
    fi
    OS_CHANGED=1
    log WARN "işletim sistemi değişmiş: ${prev_id}/${prev_codename}/${prev_version:-yok} → ${OS_ID}/${OS_CODENAME}/${OS_VERSION_ID}"
    log WARN "OS'a bağlı adımlar (apt depoları, çekirdek modülleri, resolved, dnsmasq/Caddy, firewall) yeniden uygulanacak"
    FIREWALL_NEEDS_RESTART=1
}

write_config() {
    atomic_write "$CONFIG_FILE" 0600 <<EOF
LOCAL_DOMAIN=$LOCAL_DOMAIN
TIMEZONE=$TIMEZONE
EOF
}

detect_wan() {
    local route
    route="$(ip -4 -o route get 1.1.1.1)" || die "WAN rotası okunamadı"
    WAN_INTERFACE="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$route")"
    WAN_IPV4="$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"$route")"
    [[ -n "$WAN_INTERFACE" && -n "$WAN_IPV4" ]] || die "WAN arayüzü/IPv4 tespit edilemedi"
    ip -4 -o addr show dev "$WAN_INTERFACE" | grep -q " $WAN_IPV4/" ||
        die "WAN_IPV4 ($WAN_IPV4) $WAN_INTERFACE üzerinde değil"
    # DD-138: IPv6 da sunucunun kendi yönlendirme tablosundan (paket gönderilmez, dış
    # site sorulmaz). Yoksa ya da WAN arayüzünde global adres değilse boş kalır.
    WAN_IPV6="$(ip -6 -o route get 2606:4700:4700::1111 2>/dev/null |
        awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || WAN_IPV6=""
    if [[ -n "$WAN_IPV6" ]] &&
        ! ip -6 -o addr show dev "$WAN_INTERFACE" scope global | grep -q " $WAN_IPV6/"; then
        WAN_IPV6=""
    fi
}

detect_tailscale() {
    TAILSCALE_IPV4="$(
        ip -4 -o addr show dev "$TAILSCALE_IF" scope global |
            awk 'NR==1 {sub(/\/.*/,"",$4); print $4}'
    )"
    [[ "$TAILSCALE_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        die "Tailscale IPv4 yok ($TAILSCALE_IF)"
    TAILSCALE_IPV6="$(
        ip -6 -o addr show dev "$TAILSCALE_IF" scope global |
            awk 'NR==1 {sub(/\/.*/,"",$4); print $4}'
    )" || TAILSCALE_IPV6=""
    if [[ -z "$TAILSCALE_IPV6" ]]; then
        log WARN "Tailscale IPv6 yok; devam (IPv4 zorunlu)"
    fi
}

tailscale_login_state() {
    local json state
    json="$(tailscale status --json 2>/dev/null)" || { printf 'unknown\n'; return 0; }
    state="$(
        jq -r '
            if (.BackendState == "Running" and .Self.Online == true and
                ((.Self.ID // "") | length) > 0 and
                ((.Self.TailscaleIPs // []) | length) > 0)
            then "complete"
            elif (.BackendState == "NeedsLogin" and .Self.Online != true and
                  (.Self.ID // "") == "" and
                  any(.Health[]?; contains("http 410: auth path not found")))
            then "auth_path_dead"
            else "pending" end
        ' <<<"$json" 2>/dev/null
    )" || state="unknown"
    printf '%s\n' "$state"
}

reap_bg_pid() {
    local pid="${1:?}" grace="${2:-10}" waited=0
    kill -0 "$pid" 2>/dev/null || {
        wait "$pid" 2>/dev/null || true
        return 0
    }
    kill "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt "$grace" ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

tailscale_login() {
    local attempt=1 max=3 out up_pid streamed total elapsed state dead_samples=0
    out="$(mktemp)"
    while [[ "$attempt" -le "$max" ]]; do
        : >"$out"
        streamed=0
        dead_samples=0
        log INFO "Tailscale giriş denemesi $attempt/$max"
        tailscale up --advertise-exit-node --ssh >"$out" 2>&1 &
        up_pid=$!
        elapsed=0
        while kill -0 "$up_pid" 2>/dev/null; do
            total="$(wc -l <"$out")"
            if [[ "$total" -gt "$streamed" ]]; then
                sed -n "$((streamed + 1)),${total}p" "$out" | tee -a "$V2_LOG_FILE"
                streamed="$total"
            fi
            state="$(tailscale_login_state)"
            if [[ "$state" == "complete" ]]; then
                wait "$up_pid" 2>/dev/null || true
                rm -f "$out"
                return 0
            fi
            if [[ "$state" == "auth_path_dead" ]]; then
                dead_samples=$((dead_samples + 1))
                [[ "$dead_samples" -ge 3 ]] && break
            else
                dead_samples=0
            fi
            elapsed=$((elapsed + 2))
            [[ "$elapsed" -ge 300 ]] && break
            sleep 2
        done
        reap_bg_pid "$up_pid" 10
        if [[ "$(tailscale_login_state)" == "complete" ]]; then
            rm -f "$out"
            return 0
        fi
        log WARN "Tailscale giriş başarısız/410; daemon sıfırlanıyor"
        systemctl restart --job-mode=ignore-dependencies tailscaled
        sleep 2
        attempt=$((attempt + 1))
    done
    rm -f "$out"
    die "Tailscale girişi tamamlanamadı"
}

# DD-124/DD-143: WireGuard'ın kaynağı sunucudaki kayıt ve wgN.conf dosyalarıdır.
# Yayıncı bu ID/codename için gerçekten bir suite yayınlamış mı? Yayınlamadıysa
# hata `apt-get update`in içinde, 3 deneme x APT_LOCK_TIMEOUT sonra ve sebebi
# gizleyen bir mesajla çıkardı. Ağ dalgalanmasında yanlış ölmemek için 3 deneme
# yapılır; hepsi başarısızsa sebep adıyla söylenir (DD-106).
assert_repo_suite() {
    local label="$1" url="$2" n=1
    while [[ "$n" -le 3 ]]; do
        curl -fs -I --max-time 15 "$url" >/dev/null 2>&1 && return 0
        n=$((n + 1))
        [[ "$n" -le 3 ]] && sleep 2
    done
    die "$label deposunda $OS_ID/$OS_CODENAME suite'i yok ($url) — yayıncı bu sürümü henüz yayınlamamış olabilir"
}

# Depo suite'i os-release'ten (require_supported_os → OS_ID/OS_CODENAME);
# Tailscale debian/ubuntu için aynı URL kalıbını yayınlar.
install_tailscale_repo() {
    # OS-DIVERGENCE: tailscale-repo-suite (debian+ubuntu) — depo suite'i ve
    # keyring URL'i os-release'ten türer; iki yayıncı da aynı kalıbı kullanır [DD-102]
    local keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
    assert_repo_suite "Tailscale" \
        "https://pkgs.tailscale.com/stable/${OS_ID}/dists/${OS_CODENAME}/Release"
    local tmp
    tmp="$(mktemp)"
    retry "tailscale-gpg" 3 60 -- \
        curl -fsSL "https://pkgs.tailscale.com/stable/${OS_ID}/${OS_CODENAME}.noarmor.gpg" -o "$tmp"
    # apt/sqv keyring'i _apt kullanıcısı olarak okur; 0600 Permission denied verir.
    install -m 0644 "$tmp" "$keyring"
    rm -f "$tmp"
    atomic_write /etc/apt/sources.list.d/tailscale.list 0644 <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/$OS_ID $OS_CODENAME main
EOF
}

# firewall.sh ve tailscaled aynı netfilter arka ucunu kullanmak zorunda: betik kendi
# zincirini INPUT'ta ts-input'un arkasına sıralar. Alternatif legacy'ye alınmışsa betik
# başka bir tabloyu okur ve ts-input "yok" görünür — semptomu bildiren, sebebi gizleyen
# bir ölüm. Kapıyı koyup gerçek çareyi söylüyoruz (DD-106; Docker DD-152 ile gitti).
#
# İki çağrı yeri (DD-108): Ubuntu iptables'ı önyüklü getirir, Debian minimal
# getirmez — paketi aşama 1 kurar. Aşama 0'da binary yoksa denetlenecek bir
# yanlış yapılandırma da yoktur; kapı ertelenir. Aşama 1'den sonra zorunludur.
check_nft_iptables() {
    local required="${1:-optional}" bin ver missing=0
    for bin in iptables ip6tables; do
        ver="$("$bin" --version 2>/dev/null || true)"
        if [[ -z "$ver" ]]; then
            missing=1
            continue
        fi
        [[ "$ver" == *"nf_tables"* ]] ||
            die "$bin arka ucu nft değil ($ver); Tailscale ve güvenlik duvarı nft kullanır. Çare: update-alternatives --set $bin /usr/sbin/${bin}-nft"
    done
    [[ "$missing" -eq 1 ]] || return 0
    [[ "$required" != "required" ]] ||
        die "iptables/ip6tables bulunamadı (aşama 1 kurmuş olmalıydı)"
    log INFO "iptables henüz kurulu değil (Debian minimal); nft arka uç denetimi aşama 1'e ertelendi"
}

stage_0() {
    log INFO "Aşama 0/7 — kapılar ve girdi"
    require_root
    # DD-119: girdi ilk iş okunur ve silinir; kapılardan biri düşse bile
    # parolalar /run'da kalmaz.
    read_input_file "$INPUT_FILE" "$INPUT_KEYS" "$INPUT_NONEMPTY_KEYS"
    rm -rf -- "$INPUT_DIR"
    require_supported_os
    log INFO "İşletim sistemi: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME}) ${OS_ARCH}, çekirdek $(uname -r)"
    case "$OS_ARCH" in
        amd64) ;;
        arm64) log WARN "arm64: apt depoları ve imajlar bu mimariyi yayınlıyor ama canlı doğrulanmadı" ;;
        *) log WARN "beklenmeyen mimari ($OS_ARCH); yalnız amd64 canlı doğrulandı" ;;
    esac
    detect_os_change
    # OS-DIVERGENCE: netfilter-binaries (debian) — minimal Debian iptables'ı
    # getirmez; aşama 0 yalnız var olanı denetler, aşama 1 zorunlu kılar [DD-108]
    check_nft_iptables optional
    [[ -t 0 || -r /dev/tty ]] || die "etkileşimli TTY gerekli"
    # OS-DIVERGENCE: ufw-gate (pratikte ubuntu) — yoklama; paket yoksa no-op [DD-102]
    # Ubuntu server ufw ile gelir (varsayılan pasif). Aktifse INPUT'u ikinci
    # bir el yönetir ve MASTER-INPUT ile çelişir — fail-closed: önce kapat.
    if command -v ufw >/dev/null 2>&1 &&
        ufw status 2>/dev/null | grep -q '^Status: active'; then
        die "ufw aktif: INPUT politikası iki elden yönetilemez. Önce 'ufw disable' çalıştırın"
    fi
    acquire_lock "$RUNTIME_DIR/install.lock" "$LOCK_WAIT_SECONDS"

    # defaults.env değerleri config.env source edilmeden önce alınır.
    local def_domain="$DEFAULT_LOCAL_DOMAIN"
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    # DD-119: değerler girdi dosyasından; boş alan defaults.env varsayılanı.
    LOCAL_DOMAIN="${INPUT_LOCAL_DOMAIN:-$def_domain}"
    [[ "$LOCAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die "geçersiz alan adı: $LOCAL_DOMAIN"
    # DD-144: kullanıcı alanı sorulmaz. Kök defaults.env'de sabittir; indirme klasörü
    # ve kütüphane onun altındadır. Sabit yanlış düzenlenirse allowlist durdurur.
    [[ "$SERVER_ROOT" == /* && "$SERVER_ROOT" != */ ]] ||
        die "SERVER_ROOT mutlak ve sonu '/' olmayan bir yol olmalı: $SERVER_ROOT"
    [[ "$DOWNLOADS_SUBDIR" =~ ^[A-Za-z0-9._-]+$ && "$MEDIA_SUBDIR" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "DOWNLOADS_SUBDIR ve MEDIA_SUBDIR tek bir klasör adı olmalı"
    assert_downloads_path_allowed "$SERVER_ROOT"
    DOWNLOADS_PATH="$SERVER_ROOT/$DOWNLOADS_SUBDIR"

    # DD-143: WireGuard portu artık girdi değil. state.env'deki değer yalnız Konsol'un
    # ilk ağa önerdiği porttur; ağı ve portunu master-wg net-add doğrular.

    detect_wan
    WG_ENDPOINT_HOST="$WAN_IPV4"

    # DD-147: Tailscale'e yalnız giriş bağlantısıyla katılınır; auth key girdisi yok.
    local ts_note="aşama 2'de giriş bağlantısı gösterilir; tarayıcıda onaylayın"
    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
        [[ "$(tailscale_login_state)" == "complete" ]]; then
        ts_note="zaten online"
    fi
    local input_key
    for input_key in $INPUT_KEYS; do
        unset "INPUT_$input_key"
    done

    RUN_FULL_UPGRADE=0
    if [[ "${V2_FULL_UPGRADE:-}" == "1" ]]; then
        RUN_FULL_UPGRADE=1
        log INFO "full-upgrade: V2_FULL_UPGRADE=1"
    elif [[ ! -r "$STATE_FILE" ]]; then
        RUN_FULL_UPGRADE=1
        log INFO "full-upgrade: ilk kurulum"
    else
        local upgrade_ans="h"
        prompt upgrade_ans "Sistem full-upgrade yapılsın mı? (uzun sürebilir)" "h"
        if [[ "$upgrade_ans" =~ ^[EeYy]$ ]]; then
            RUN_FULL_UPGRADE=1
        else
            log INFO "full-upgrade atlandı (yeniden kurulum)"
        fi
    fi

    # DD-119: dosyadan gelen her şey tek ekranda, parolasız; ilk yazımdan
    # (config.env) önce tek onay.
    local yes_no_upgrade="hayır" confirm_ans="h"
    [[ "$RUN_FULL_UPGRADE" -eq 1 ]] && yes_no_upgrade="evet"
    cat <<EOF

Kurulum girdileri (kurulum/kurulum.env):
  Alan adı:      $LOCAL_DOMAIN
  Kullanıcı alanı: $SERVER_ROOT (sabit; indirmeler $DOWNLOADS_PATH)
  WireGuard:     ağı Konsol kurar (kurulum ağ yaratmaz; DD-143)
  Modüller:      Dosya yöneticisi, WireGuard, qBittorrent, Paylaşım
                 Konsol → Modüller'den kurulur; hesaplarını Konsol gösterir (DD-148)
  Konsol:        parolasız; yalnız Tailscale'den açılır (DD-147)
  Tailscale:     $ts_note
  full-upgrade:  $yes_no_upgrade

EOF
    prompt confirm_ans "Bu değerlerle kurulum başlasın mı? (E/h)" "h"
    [[ "$confirm_ans" =~ ^[EeYy]$ ]] || die "kurulum iptal edildi; hiçbir ayar değiştirilmedi"

    write_config
}

# DD-113: dağıtımın güvenlik güncellemeleri kendiliğinden insin. Kaynak
# süzgeci paketin dağıtım varsayılanı (Debian: stable + security; Ubuntu:
# security); Tailscale/Caddy depoları eşleşmez, onları yalnız yeniden
# çalıştırma günceller. Reboot kararı operatörde; Ubuntu'da unattended-upgrades
# paketi imajla gelir, dosyalar oradakiyle aynı içeriğe yazılır (no-op).
apply_unattended_upgrades() {
    atomic_write "$APT_PERIODIC_FILE" 0644 <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    atomic_write "$APT_UNATTENDED_POLICY_FILE" 0644 <<EOF
// master-stack (DD-113): otomatik reboot yok; yeniden başlatma operatörün kararı.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 ||
        log WARN "apt-daily zamanlayıcıları etkinleştirilemedi"
}

stage_1() {
    log INFO "Aşama 1/7 — sistem ve paketler"
    export DEBIAN_FRONTEND=noninteractive
    # OS-DIVERGENCE: needrestart-suspend (ubuntu) — env değişkeni; Debian'da
    # paket kurulu olmadığı için no-op [DD-103]
    # Ubuntu'da needrestart apt kancasıyla gelir ve "Ubuntu modunda" restart
    # kipini OTOMATİK'e ayarlar ($nrconf{restart}='a'); DEBIAN_FRONTEND bunu
    # kapatmaz. Kütüphane güncellemesinden sonra sshd/tailscaled/caddy/
    # dnsmasq'ı aşamaların ortasında yeniden başlatır —
    # ufw kapısının reddettiği "tek şeyin iki sahibi" sınıfının aynısı.
    # SUSPEND apt kancasınca okunur; Debian'da needrestart kurulu değil, no-op.
    export NEEDRESTART_SUSPEND=1
    retry "apt-update" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
    if [[ "$RUN_FULL_UPGRADE" -eq 1 ]]; then
        retry "apt-upgrade" 2 "$APT_LOCK_TIMEOUT" -- \
            apt-get "${APT_OPTS[@]}" -y -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold full-upgrade
    fi
    # DD-153: yalnız temelin kullandıkları. gnupg (Caddy anahtarı artık .asc), gawk (v1'den
    # kalma; awk sistemin mawk'ı) ve apache2-utils (htpasswd yalnız Paylaşım'ın) temelde yok.
    retry "apt-base" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        ca-certificates curl ethtool iproute2 procps kmod \
        iptables coreutils util-linux diffutils jq \
        dnsutils unattended-upgrades python3
    # Artık binary kesin var: arka uç denetimi burada zorunlu (DD-108).
    check_nft_iptables required
    timedatectl set-timezone "$TIMEZONE" || log WARN "saat dilimi ayarlanamadı"
    apply_unattended_upgrades
}

apply_udp_netbuf_floor() {
    # Legacy / DD-18: max(current, 16 MiB); asla düşürme. tailscaled socket
    # açılmadan önce yazılmalı (paket postinst daemon'ı başlatır).
    local current_rmem=0 current_wmem=0 target_rmem target_wmem
    current_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
    current_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
    [[ "$current_rmem" =~ ^[0-9]+$ ]] || current_rmem=0
    [[ "$current_wmem" =~ ^[0-9]+$ ]] || current_wmem=0
    target_rmem="$NET_BUF_FLOOR_BYTES"
    target_wmem="$NET_BUF_FLOOR_BYTES"
    if (( current_rmem > target_rmem )); then
        target_rmem="$current_rmem"
    fi
    if (( current_wmem > target_wmem )); then
        target_wmem="$current_wmem"
    fi
    atomic_write "$SYSCTL_NETBUF_FILE" 0644 <<EOF
net.core.rmem_max = $target_rmem
net.core.wmem_max = $target_wmem
EOF
    sysctl -p "$SYSCTL_NETBUF_FILE" >/dev/null
    log INFO "UDP netbuf floor: rmem_max=$target_rmem wmem_max=$target_wmem"
}

# TCP tıkanıklık denetimi (DD-111). Yalnız bu host'ta SONLANAN TCP'yi etkiler:
# Caddy'nin Infuse'a WebDAV akışı, qBittorrent yüklemeleri, arayüzler.
# Exit-node üzerinden yönlendirilen akışların denetimi uç noktalardadır;
# router'ın ayarı onlara dokunmaz. tcp_bbr Ubuntu 26.04 çekirdeğinde modül
# olarak doğrulandı; Debian 13 için beklenir ama doğrulanmadı. Yüklenemezse
# kurulum durmaz, varsayılanda kalır — bir kapı yalnız host'un sahip olduğunu
# doğrulayabilir (DD-108).
apply_tcp_congestion_control() {
    if ! modprobe "tcp_${TCP_CONGESTION_CONTROL}" 2>/dev/null; then
        log INFO "tcp_${TCP_CONGESTION_CONTROL} yüklenemedi; varsayılan tıkanıklık denetimi korunuyor ($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
        return 0
    fi
    atomic_write "$TCP_MODULES_LOAD_FILE" 0644 <<EOF
tcp_${TCP_CONGESTION_CONTROL}
EOF
    atomic_write "$SYSCTL_TCP_FILE" 0644 <<EOF
net.core.default_qdisc = $TCP_DEFAULT_QDISC
net.ipv4.tcp_congestion_control = $TCP_CONGESTION_CONTROL
EOF
    if ! sysctl -p "$SYSCTL_TCP_FILE" >/dev/null 2>&1; then
        log WARN "TCP ayarları uygulanamadı ($SYSCTL_TCP_FILE); varsayılan korunuyor"
        return 0
    fi
    log INFO "TCP: congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control) default_qdisc=$(sysctl -n net.core.default_qdisc)"
}

stage_2() {
    log INFO "Aşama 2/7 — Tailscale"
    install_tailscale_repo
    if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 || "$OS_CHANGED" -eq 1 ]]; then
        retry "apt-update-ts" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
    else
        log INFO "tailscale.list aynı; apt-get update atlandı (stage_1 zaten günceldi)"
    fi
    # M11/DD-18: buffer tabanı paket kurulumundan önce
    apply_udp_netbuf_floor
    # DD-111: default_qdisc tailscale0 oluşmadan önce yazılsın (taze kurulumda)
    apply_tcp_congestion_control
    retry "apt-tailscale" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y tailscale
    systemctl enable --now tailscaled

    # Forwarding ayrı dosyada; rmem/wmem yalnız netbuf conf'ta (DD-18).
    atomic_write "$SYSCTL_FORWARD_FILE" 0644 <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$SYSCTL_FORWARD_FILE" >/dev/null || true
    install -m 0755 "$V2_ROOT/scripts/tailscale-udp-gro" "$SBIN_DIR/tailscale-udp-gro"
    install -m 0644 "$V2_ROOT/systemd/tailscale-udp-gro.service" \
        "$UNIT_DIR/tailscale-udp-gro.service"
    systemctl daemon-reload
    systemctl enable --now tailscale-udp-gro.service ||
        log WARN "tailscale-udp-gro başlatılamadı"

    if [[ "$(tailscale_login_state)" != "complete" ]]; then
        tailscale_login
    else
        log INFO "Tailscale zaten online"
    fi
    tailscale set --advertise-exit-node --ssh=true \
        --stateful-filtering=true --netfilter-mode=on --snat-subnet-routes=true

    local deadline=$((SECONDS + TS_ONLINE_DEADLINE_SECONDS))
    while [[ "$(tailscale_login_state)" != "complete" ]]; do
        [[ "$SECONDS" -lt "$deadline" ]] || die "Tailscale online olmadı"
        sleep 2
    done
}

ensure_downloads_tree() {
    local root="$1" uid="$2" gid="$3"
    [[ -d "$root" ]] || die "downloads dizini yok: $root"
    # Tek geçiş, üç ayrı find değil: büyük kütüphanede ağaç I/O'su üçte bire
    # iner. "-exec … + -false" grubu her girdide sonraki gruba da bakılmasını
    # sağlar (GNU virgül operatörü BSD find'da yok; testler iş istasyonunda
    # koşar). Onarım DD-84 gereği seçici kalır (yalnız sapmış girdiler);
    # hedef modlarda suid/sgid olmadığından exec sırası sonucu değiştirmez.
    # -print düzeltilen girdiyi yazar; aynı girdi hem sahip hem mod için
    # görünebilir, sayı tekilleştirilir. Çıktı: düzeltilen girdi sayısı.
    find "$root" \
        \( \( ! -uid "$uid" -o ! -gid "$gid" \) \
        -print -exec chown -h "${uid}:${gid}" {} + -false \) -o \
        \( -type d ! -perm 0775 -print -exec chmod 0775 {} + -false \) -o \
        \( -type f ! -perm 0664 -print -exec chmod 0664 {} + \) |
        sort -u | wc -l | tr -d ' '
}

# Recursive chown/chmod only under an allowlisted data root (DD-93).
assert_downloads_path_allowed() {
    local p="$1"
    case "$p" in
        / | /etc | /etc/* | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | \
        /boot | /boot/* | /dev | /dev/* | /proc | /proc/* | /sys | /sys/* | \
        /run | /run/* | /root | /root/* | /var | /var/* | /tmp | /tmp/* | \
        /home | /home/* | /lib | /lib/* | /lib64 | /lib64/* | /opt | /opt/* | \
        /media | /media/* | /mnt | /mnt/* )
            die "kullanıcı alanı sistem dizininde olamaz: $p"
            ;;
    esac
    # DD-144: /srv FHS'te zaten "bu sistemin sunduğu veri" dizini ve Debian paketleri
    # oraya dosya koyamaz; kullanıcı alanının yeri orası.
    case "$p" in
        /srv | /srv/* | /data | /data/* )
            return 0
            ;;
        *)
            die "kullanıcı alanı allowlist dışı (/srv, /data): $p"
            ;;
    esac
}

# DD-148: modüllerin dosyaları. Kurulum her modülün şablonunu yer tutucuları doldurarak
# MODULES_DIR/<id>/ altına yazar ve kayıt dosyasını (yoksa boş) oluşturur; hiçbir modülü
# kendiliğinden kurmaz, başlatmaz ya da kaldırmaz. Dosyası değişen kurulu modülü aşama 7
# yeniden uygular. Sıra master-modul'deki katalogla aynıdır.
MODULES_CHANGED=""
module_state() { # ID → calisiyor | durduruldu | (boş: kurulu değil)
    awk -F'\t' -v i="$1" '$1 == i {print $2; exit}' "$MODULES_FILE" 2>/dev/null || true
}
ensure_module_files() {
    local changed=0
    install -d -m 0755 -o root -g root "$MODULES_DIR"
    # DD-149, DD-152: Paylaşım — servis birimi (rclone sunucuda), Caddy sitesi ve dnsmasq adı.
    # Canlı kopyaları master-modul koyar. Birim rclone sürümünü taşır: sürüm yükselince kurulu
    # Paylaşım yeniden uygulanır ve yeni sürüme geçer.
    install -d -m 0755 -o root -g root "$MODULES_DIR/paylasim"
    render_template "$V2_ROOT/modules/paylasim/master-paylasim.service" "$MODULES_DIR/paylasim/master-paylasim.service" 0644 \
        RCLONE_VERSION="$RCLONE_VERSION" \
        RCLONE_BIN="$RCLONE_BIN" \
        SERVER_ROOT="$SERVER_ROOT" \
        SHARE_DIR="$SHARE_DIR" \
        SHARE_PORT="$SHARE_PORT" \
        SHARE_HTPASSWD_FILE="$SHARE_HTPASSWD_FILE" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        DOWNLOADS_UID="$DOWNLOADS_UID" \
        DOWNLOADS_GID="$DOWNLOADS_GID"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    render_template "$V2_ROOT/modules/paylasim/paylasim.caddy" "$MODULES_DIR/paylasim/paylasim.caddy" 0644 \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        SHARE_PORT="$SHARE_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    render_template "$V2_ROOT/modules/paylasim/dnsmasq.conf" "$MODULES_DIR/paylasim/dnsmasq.conf" 0644 \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        TAILSCALE_IF="$TAILSCALE_IF"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    [[ "$changed" -eq 0 ]] || MODULES_CHANGED="$MODULES_CHANGED paylasim"
    # DD-151: qBittorrent — ilk ayar (profil boşken bir kez), servis eki, Caddy sitesi, dnsmasq adı.
    changed=0
    install -d -m 0755 -o root -g root "$MODULES_DIR/torrent"
    render_template "$V2_ROOT/modules/torrent/qBittorrent.conf" "$MODULES_DIR/torrent/qBittorrent.conf" 0644 \
        DOWNLOADS_PATH="$DOWNLOADS_PATH" \
        TORRENT_TEMP_DIR="$TORRENT_TEMP_DIR" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT"
    render_template "$V2_ROOT/modules/torrent/master-stack.conf" "$MODULES_DIR/torrent/master-stack.conf" 0644 \
        TORRENT_PROFILE_DIR="$TORRENT_PROFILE_DIR" \
        DOWNLOADS_PATH="$DOWNLOADS_PATH" \
        SERVER_ROOT="$SERVER_ROOT" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        SHARE_DIR="$SHARE_DIR"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    render_template "$V2_ROOT/modules/torrent/torrent.caddy" "$MODULES_DIR/torrent/torrent.caddy" 0644 \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    render_template "$V2_ROOT/modules/torrent/dnsmasq.conf" "$MODULES_DIR/torrent/dnsmasq.conf" 0644 \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        TAILSCALE_IF="$TAILSCALE_IF"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    [[ "$changed" -eq 0 ]] || MODULES_CHANGED="$MODULES_CHANGED torrent"
    # DD-150: WireGuard'ın işlenen dosyası yok; kuruluysa her çalıştırmada uygulanır (paketler
    # bir sürüm yükseltmesinden sonra, kayıttaki ağlar açık).
    MODULES_CHANGED="$MODULES_CHANGED wireguard"
    if [[ ! -f "$MODULES_FILE" ]]; then
        atomic_write "$MODULES_FILE" 0644 </dev/null
    fi
    chown root:root "$MODULES_FILE"
    chmod 0644 "$MODULES_FILE"
}

# DD-148/DD-149: dosyası değişen kurulu modül yeniden uygulanır (adları, hesabı; çalışıyorsa
# servisi). Durdurulmuş modül durur, kurulmamış modüle dokunulmaz, hiçbiri kaldırılmaz.
reapply_modules() {
    local id state
    for id in $MODULES_CHANGED; do
        state="$(module_state "$id")"
        [[ "$state" == calisiyor || "$state" == durduruldu ]] || continue
        if [[ "$id" == wireguard ]]; then
            log INFO "Modül wireguard: yeniden uygulanıyor (her kurulumda: paketler, çekirdek modülü, ağlar)"
        else
            log INFO "Modül $id: dosyası değişti, yeniden uygulanıyor"
        fi
        "$SBIN_DIR/master-modul" uygula "$id" >/dev/null ||
            log WARN "Modül $id yeniden uygulanamadı; Konsol → Modüller'den bakın"
    done
}

stage_3() {
    log INFO "Aşama 3/7 — adresler ve dizinler"
    detect_wan
    detect_tailscale
    write_state
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1

    local d
    # DD-144: kök kullanıcı alanı; indirme klasörü, kütüphane, çöp ve paylaşım kökü
    # kardeştir. Torrent istemcisi yalnız indirme klasörünü görür.
    for d in \
        "$SERVER_ROOT" \
        "$DOWNLOADS_PATH" \
        "$SERVER_ROOT/$MEDIA_SUBDIR" \
        "$SERVER_ROOT/$MEDIA_SUBDIR/movies" \
        "$SERVER_ROOT/$MEDIA_SUBDIR/series" \
        "$SERVER_ROOT/$FILES_PANEL_TRASH" \
        "$SERVER_ROOT/$SHARE_DIR" \
        "$SERVER_ROOT/$SHARE_DIR/w"; do
        mkdir -p "$d"
    done
    local fixed
    fixed="$(ensure_downloads_tree "$SERVER_ROOT" "$DOWNLOADS_UID" "$DOWNLOADS_GID")"
    if [[ "$fixed" -gt 0 ]]; then
        log INFO "Downloads: $fixed girdinin sahibi ya da izni düzeltildi (${DOWNLOADS_UID}:${DOWNLOADS_GID}; qBittorrent/Konsol R/W)"
    else
        log INFO "Downloads sahipliği ve izinleri yerinde (${DOWNLOADS_UID}:${DOWNLOADS_GID})"
    fi
}

stage_4() {
    log INFO "Aşama 4/7 — betikler ve şablonlar"
    # DD-152: Docker yok; modüller sunucuda systemd servisi olarak çalışır.
    atomic_write "$SBIN_DIR/master-wg" 0755 <"$V2_ROOT/scripts/master-wg"
    atomic_write "$SBIN_DIR/master-modul" 0755 <"$V2_ROOT/scripts/master-modul"
    ensure_module_files
    atomic_write "$SBIN_DIR/master-firewall" 0755 <"$V2_ROOT/scripts/firewall.sh"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1
    atomic_write "$SBIN_DIR/refresh-tailnet-config" 0755 \
        <"$V2_ROOT/scripts/refresh-tailnet-config"
    atomic_write "$SBIN_DIR/wait-tailnet-addr" 0755 \
        <"$V2_ROOT/scripts/wait-tailnet-addr"

    atomic_write "$UNIT_DIR/master-firewall.service" 0644 \
        <"$V2_ROOT/systemd/master-firewall.service"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1
    atomic_write "$UNIT_DIR/refresh-tailnet-config.service" 0644 \
        <"$V2_ROOT/systemd/refresh-tailnet-config.service"
    atomic_write "$UNIT_DIR/refresh-tailnet-config.timer" 0644 \
        <"$V2_ROOT/systemd/refresh-tailnet-config.timer"
    systemctl daemon-reload
}

stage_5() {
    log INFO "Aşama 5/7 — firewall"

    systemctl enable master-firewall.service
    systemctl enable refresh-tailnet-config.service
    systemctl enable --now refresh-tailnet-config.timer

    if [[ "$FIREWALL_NEEDS_RESTART" -eq 1 ]] ||
        ! systemctl is-active --quiet master-firewall.service; then
        systemctl reset-failed master-firewall.service 2>/dev/null || true
        systemctl restart master-firewall.service
    else
        log INFO "firewall yapılandırması aynı; yeniden başlatılmadı"
    fi
    # DD-150: WireGuard katmanı (paketler, çekirdek modülü, ağların açılması) WireGuard
    # modülündedir; kurulu değilse güvenlik duvarı hiçbir WireGuard portu açmaz.
}

# retry fonksiyonu export -f + bash -c ile ayrı süreçte çalıştırır; diziler
# oraya geçmez. APT_OPTS bu yüzden çağırandan argüman olarak gelir (DD-125).
apt_get_install_masked_quiet() {
    local tmp rc=0 line
    tmp="$(mktemp)"
    set +e
    apt-get install -y "$@" >"$tmp" 2>&1
    rc=$?
    set -e
    if [[ -n "${V2_LOG_FILE:-}" ]]; then
        cat "$tmp" >>"$V2_LOG_FILE" 2>/dev/null || true
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"Failed to preset unit: Unit "* && "$line" == *" is masked" ]] ||
            [[ "$line" == *"deb-systemd-helper: error: systemctl preset failed"* ]] ||
            [[ "$line" == *".service is a disabled or a static unit"* ]]; then
            continue
        fi
        printf '%s\n' "$line"
    done <"$tmp"
    rm -f "$tmp"
    return "$rc"
}

# DNSStubListener=no yazıldı; yürürlüğe girdi mi? systemd 259 (Ubuntu 26.04)
# anahtarı kabul edip yok sayıyor. Bu yerleşimde zararsızdır ve ÖLÇÜLDÜ:
# dnsmasq yalnız arayüze ATANMIŞ adresleri bağlar (127.0.0.1, ::1, tailscale0);
# 127.0.0.53 atanmış bir adres değil, yalnız 127/8 rotasıyla erişilebilir, bu
# yüzden iki çözümleyici aynı sokete hiç talip olmaz. Yine de uygulanan bir
# ayarın sonucunu okumak, sessizce başarılı saymaktan iyidir (DD-109).
report_resolved_stub_state() {
    local deadline=$((SECONDS + RESOLVED_STUB_SETTLE_SECONDS))
    while [[ "$SECONDS" -lt "$deadline" ]]; do
        if ss -lnu 2>/dev/null | grep -q '127\.0\.0\.53'; then
            log INFO "resolved stub'ı 127.0.0.53'te ayakta — DNSStubListener=no bu sürümde yok sayılıyor; bu yerleşimde zararsız (DD-109)"
            return 0
        fi
        sleep 1
    done
    log INFO "resolved stub'ı kapalı — DNSStubListener=no yürürlükte"
}

# Yapılandırma dosyası servisin başlangıcından yeniyse servis onu okumamıştır:
# önceki çalıştırma render ile restart arasında düşmüş olabilir. O zaman "dosya
# aynı" demek yetmez; birim yine de yeniden başlatılır.
config_newer_than_unit() {
    local file="$1" unit="$2" started file_ts unit_ts
    started="$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null || true)"
    [[ -n "$started" ]] || return 0
    unit_ts="$(date -d "$started" +%s 2>/dev/null || echo 0)"
    file_ts="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
    [[ "$unit_ts" -eq 0 || "$file_ts" -gt "$unit_ts" ]]
}

stage_6() {
    log INFO "Aşama 6/7 — dnsmasq ve Caddy"
    local need_pkg=0
    dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed' || need_pkg=1
    dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q 'install ok installed' || need_pkg=1

    if [[ "$need_pkg" -eq 1 ]]; then
        systemctl stop dnsmasq caddy 2>/dev/null || true
        systemctl mask dnsmasq.service caddy.service >/dev/null 2>&1 || true
        # debian-keyring kurulmaz (DD-125): Caddy deposunun imzası indirilen
        # cloudsmith keyring'iyle (signed-by) doğrulanır.
        retry "apt-dns-caddy" 2 "$APT_LOCK_TIMEOUT" -- \
            apt_get_install_masked_quiet "${APT_OPTS[@]}" dnsmasq
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.asc ]]; then
            # DD-153: apt zırhlı anahtarı kendisi okur (signed-by *.asc); gnupg gerekmez.
            local caddy_key
            caddy_key="$(mktemp)"
            retry "caddy-key" 3 60 -- curl -1sLf \
                'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$caddy_key"
            install -m 0644 "$caddy_key" /usr/share/keyrings/caddy-stable-archive-keyring.asc
            rm -f "$caddy_key"
            atomic_write /etc/apt/sources.list.d/caddy-stable.list 0644 <<'EOF'
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.asc] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
            retry "apt-update-caddy" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
        fi
        retry "apt-caddy" 2 "$APT_LOCK_TIMEOUT" -- apt_get_install_masked_quiet "${APT_OPTS[@]}" caddy
    fi

    mkdir -p /etc/dnsmasq.d
    local dnsmasq_changed=0 caddy_changed=0
    render_template "$V2_ROOT/templates/dnsmasq.conf" "$DNSMASQ_CONF_FILE" 0644 \
        TAILSCALE_IF="$TAILSCALE_IF" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && dnsmasq_changed=1
    # OS/paket sürümü değişince kaybolan bir direktif, aksi hâlde ilk belirtisini
    # "systemctl restart dnsmasq başarısız" olarak verirdi. --test satır numarası
    # ve direktif adı söyler (DD-106).
    local validate_out=""
    if ! validate_out="$(dnsmasq --test -C "$DNSMASQ_CONF_FILE" 2>&1)"; then
        die "dnsmasq yapılandırması geçersiz ($DNSMASQ_CONF_FILE): ${validate_out:-sebep bildirilmedi}"
    fi

    # OS-DIVERGENCE: resolved-stub (pratikte ubuntu) — yoklama: resolved pasifse
    # (Debian varsayılanı) blok tamamen atlanır ve drop-in hiç oluşturulmaz.
    # Ubuntu 26.04 / systemd 259 anahtarı kabul edip yok sayıyor; sonuç
    # okunup bildirilir, sessizce başarılı sayılmaz [DD-102, DD-109]
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        atomic_write /etc/systemd/resolved.conf.d/master-stack.conf 0644 <<'EOF'
[Resolve]
DNSStubListener=no
EOF
        if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 || "$OS_CHANGED" -eq 1 ]]; then
            systemctl restart systemd-resolved || true
        fi
        report_resolved_stub_state
        # OS-DIVERGENCE: resolvconf-symlink (ubuntu) — hedef testi; stub symlink
        # yoksa (Debian) no-op. Tailscale sonradan dosyayı devralır [DD-102]
        # Ubuntu: /etc/resolv.conf stub'a (127.0.0.53) symlink gelir; stub
        # kapanınca host DNS kırılır. resolved'in gerçek uplink dosyasına çevir.
        if [[ "$(readlink /etc/resolv.conf 2>/dev/null)" == *stub-resolv.conf ]]; then
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            log INFO "resolv.conf stub yerine resolved uplink dosyasına bağlandı"
        fi
    fi

    render_template "$V2_ROOT/templates/Caddyfile" "$CADDYFILE" 0644 \
        CADDY_HTTP_PORT="$CADDY_HTTP_PORT" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        WG_PANEL_PORT="$WG_PANEL_PORT" \
        FILES_PANEL_PORT="$FILES_PANEL_PORT" \
        CONSOLE_WEB_DIR="$CONSOLE_WEB_DIR" \
        CADDY_MODULES_DIR="$CADDY_MODULES_DIR"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1
    # DD-149: modüllerin site dosyaları bu dizinden içe aktarılır; boş dizin geçerlidir.
    install -d -m 0755 -o root -g root "$CADDY_MODULES_DIR"
    ensure_console_pages
    # Caddy env yer tutucularını çalışma anında çözer; boş ortamla doğrulamak
    # `http://:` gibi anlamsız bir siteyi geçerli sayardı — gerçek değerlerle
    # doğrula (DD-106). Çıktı normalde JSON log satırları; hata satırını süz,
    # bulunamazsa son satırı göster.
    if ! validate_out="$(
        TAILSCALE_IPV4="$TAILSCALE_IPV4" \
            caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1
    )"; then
        die "Caddyfile geçersiz ($CADDYFILE): $(
            grep -i -m1 'error' <<<"$validate_out" || tail -n1 <<<"$validate_out"
        )"
    fi
    # Sürüm yükseltmesinden sonra dosyalar bayt olarak aynı kalsa bile paketler
    # değişti; iki kenar servisi bir kez yeniden başlasın (DD-104).
    if [[ "$OS_CHANGED" -eq 1 ]]; then
        dnsmasq_changed=1
        caddy_changed=1
    fi

    mkdir -p /etc/systemd/system/dnsmasq.service.d
    atomic_write /etc/systemd/system/dnsmasq.service.d/master-stack.conf 0644 <<'EOF'
[Unit]
Wants=tailscaled.service
After=tailscaled.service

[Service]
Restart=on-failure
RestartSec=5s
EOF
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && dnsmasq_changed=1

    mkdir -p /etc/systemd/system/caddy.service.d
    # ExecStartPre: state.env TAILSCALE_IPV4 arayüzde olmalı (DD-72/DD-85).
    # StartLimit, adres hiç gelmezse veya stale kalırsa unit'i failed yapar.
    # OnFailure: stale/fail sonrası refresh'i timer beklemeden çalıştırır (DD-87).
    atomic_write /etc/systemd/system/caddy.service.d/master-stack.conf 0644 <<EOF
[Unit]
Wants=tailscaled.service
After=tailscaled.service
OnFailure=refresh-tailnet-config.service
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
EnvironmentFile=$STATE_FILE
ExecStartPre=$SBIN_DIR/wait-tailnet-addr
TimeoutStartSec=150s
Restart=on-failure
RestartSec=5s
EOF
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1

    systemctl daemon-reload
    systemctl unmask dnsmasq caddy 2>/dev/null || true
    systemctl enable dnsmasq caddy
    if [[ "$dnsmasq_changed" -eq 1 ]] || ! systemctl is-active --quiet dnsmasq ||
        config_newer_than_unit "$DNSMASQ_CONF_FILE" dnsmasq.service; then
        systemctl restart dnsmasq
    else
        log INFO "dnsmasq yapılandırması aynı; yeniden başlatılmadı"
    fi
    if [[ "$caddy_changed" -eq 1 ]] || ! systemctl is-active --quiet caddy ||
        config_newer_than_unit "$CADDYFILE" caddy.service; then
        systemctl restart caddy
    else
        log INFO "Caddy yapılandırması aynı; yeniden başlatılmadı"
    fi
    ensure_caddy_wg "$OS_CHANGED"
    ensure_wg_panel "$OS_CHANGED"
    ensure_files_panel "$OS_CHANGED"
}

# DD-120: WireGuard istemcilerinin arayüzlere eriştiği ikinci Caddy. Yalnız
# WireGuard adresinde IP:port dinler; Tailscale'e bağlı değildir, wg-quick
# ile birlikte kalkar ve iner. Tailnet Caddy'sine ve refresh'e dokunmaz.
# DD-136: tek Caddyfile.wg, arayüz başına bir örnek (caddy-wg@wgN). Dinlenen adres
# /etc/wireguard/caddy-wg-<arayüz>.env'deki WG_BIND; wg0'ınkini kurulum, panel ağlarınınkini
# master-wg yazar. Ortak dosya ya da şablon değişince panel ağlarının örnekleri de
# yeniden başlar.
ensure_caddy_wg() {
    local changed="${1:-0}" validate_out iface
    render_template "$V2_ROOT/templates/Caddyfile.wg" "$CADDY_WG_FILE" 0644 \
        TORRENT_UI_PORT="$TORRENT_UI_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    # Ağ yokken sunucu adresi de yok; doğrulama yalnız sözdizimi için yer tutucu bağlar.
    if ! validate_out="$(WG_BIND="127.0.0.1" caddy validate --config "$CADDY_WG_FILE" --adapter caddyfile 2>&1)"; then
        die "Caddyfile.wg geçersiz ($CADDY_WG_FILE): $(
            grep -i -m1 'error' <<<"$validate_out" || tail -n1 <<<"$validate_out"
        )"
    fi
    render_template "$V2_ROOT/systemd/caddy-wg@.service" "$UNIT_DIR/caddy-wg@.service" 0644 \
        WG_CONF_DIR="$WG_CONF_DIR" \
        CADDY_WG_FILE="$CADDY_WG_FILE"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    # DD-143: örnek birimleri ağlarla birlikte master-wg açar; kurulum yalnız şablonu
    # günceller ve şablon değiştiyse ayakta olanları yeniler.
    if [[ "$changed" -eq 1 && -n "${WG_NETWORKS_FILE:-}" && -f "$WG_NETWORKS_FILE" ]]; then
        while IFS=$'\t' read -r iface _; do
            [[ "$iface" =~ ^wg[0-9]$ ]] || continue
            systemctl try-restart "caddy-wg@${iface}.service" ||
                log WARN "caddy-wg@${iface} yeniden başlatılamadı"
        done <"$WG_NETWORKS_FILE"
    else
        log INFO "caddy-wg yapılandırması aynı; yeniden başlatılmadı"
    fi
}

# DD-133, DD-140: Konsol'un WireGuard ve sistem arka ucu. 127.0.0.1:WG_PANEL_PORT dinler;
# tailnet'e Caddy açar (panel.LOCAL_DOMAIN altında /api/wg/*). DD-147: parola yok, erişim
# sınırı Tailscale. Yalnız betik ya da unit değişince servis yeniden başlar.
ensure_wg_panel() {
    local changed="${1:-0}" f out
    # Arka ucun yazabildiği tek kalıcı yer. DD-150'den beri WireGuard modülü (paketiyle
    # birlikte) sonradan kurulur; klasör burada açılmazsa arka uç başlamaz (v2-119).
    install -d -m 0700 -o root -g root -- "$WG_CONF_DIR"
    atomic_write "$SBIN_DIR/master-wg-panel" 0755 <"$V2_ROOT/panel/master-wg-panel"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    render_template "$V2_ROOT/systemd/master-wg-panel.service" "$UNIT_DIR/master-wg-panel.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        WG_PANEL_PORT="$WG_PANEL_PORT" \
        STATE_FILE="$STATE_FILE" \
        WG_CLIENT_DNS_DEFAULT="$WG_CLIENT_DNS_DEFAULT" \
        WG_CLIENT_KEEPALIVE_DEFAULT="$WG_CLIENT_KEEPALIVE_DEFAULT" \
        WG_MTU="$WG_MTU"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet master-wg-panel.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet master-wg-panel.service; then
        systemctl restart master-wg-panel.service
    else
        log INFO "WireGuard paneli aynı; yeniden başlatılmadı"
    fi
}

# DD-139: dosya paneli. 127.0.0.1:FILES_PANEL_PORT dinler; tailnet'e Caddy açar. Servis
# DOWNLOADS_UID olarak çalışır ve yalnız SERVER_ROOT'a yazar. qBittorrent'in yarım indirme
# klasörü şablondan okunur; panel orada taşıma/silme için uyarır. DD-150: Dosya yöneticisi bir
# Konsol modülüdür: kurulum betiği ve servis birimini (MODULES_DIR/dosya/) hazırlar, servisi
# modül açar. Betik ya da birim değişirse kurulu modül aşama 7'de yeniden uygulanır.
# DD-148: Konsol sayfaları temeldir; Caddy doğrudan sunar (dosya yöneticisi modüldür).
ensure_console_pages() {
    local f
    install -d -m 0755 -o root -g root "$CONSOLE_WEB_DIR"
    for f in index.html konsol.css konsol.js; do
        atomic_write "$CONSOLE_WEB_DIR/$f" 0644 <"$V2_ROOT/console/$f"
    done
}

ensure_files_panel() {
    local changed="${1:-0}" temp_dir user group
    # systemd User= sayısal uid için de kullanıcı kaydı ister. Varsa mevcut ad (ör. ubuntu),
    # yoksa girişsiz, ev dizinsiz bir sistem hesabı; dosya sahipliği sayısal kaldığı için değişmez.
    # getent bulamayınca 2 döner; pipefail altında kurulumu düşürmesin.
    group="$(getent group "$DOWNLOADS_GID" | cut -d: -f1 || true)"
    if [[ -z "$group" ]]; then
        groupadd --system --gid "$DOWNLOADS_GID" "$DOWNLOADS_ACCOUNT" ||
            die "gid $DOWNLOADS_GID için grup açılamadı ($DOWNLOADS_ACCOUNT)"
        group="$DOWNLOADS_ACCOUNT"
        log INFO "gid $DOWNLOADS_GID için sistem grubu açıldı: $group (dosya paneli)"
    fi
    user="$(getent passwd "$DOWNLOADS_UID" | cut -d: -f1 || true)"
    if [[ -z "$user" ]]; then
        useradd --system --uid "$DOWNLOADS_UID" --gid "$DOWNLOADS_GID" --no-create-home \
            --home-dir /nonexistent --shell /usr/sbin/nologin "$DOWNLOADS_ACCOUNT" ||
            die "uid $DOWNLOADS_UID için sistem hesabı açılamadı ($DOWNLOADS_ACCOUNT)"
        user="$DOWNLOADS_ACCOUNT"
        log INFO "uid $DOWNLOADS_UID için girişsiz sistem hesabı açıldı: $user (dosya paneli)"
    fi
    atomic_write "$SBIN_DIR/master-files-panel" 0755 <"$V2_ROOT/files-panel/master-files-panel"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    # DD-144, DD-151: qBittorrent modülünün ilk ayarındaki yarım indirme klasörü; panel onu
    # kullanıcı alanının köküne göre bilir (<indirme klasörü>/<geçici>) ve orada uyarır.
    temp_dir="$DOWNLOADS_SUBDIR/$TORRENT_TEMP_DIR"
    install -d -m 0755 -o root -g root "$MODULES_DIR/dosya"
    render_template "$V2_ROOT/systemd/master-files-panel.service" "$MODULES_DIR/dosya/master-files-panel.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        FILES_PANEL_PORT="$FILES_PANEL_PORT" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        SHARE_DIR="$SHARE_DIR" \
        SERVER_ROOT="$SERVER_ROOT" \
        FILES_PANEL_USER="$user" \
        FILES_PANEL_GROUP="$group" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        V2_VERSION="$V2_VERSION" \
        QBITTORRENT_TEMP_DIR="$temp_dir"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    [[ "$changed" -eq 0 ]] || MODULES_CHANGED="$MODULES_CHANGED dosya"
}

stage_7() {
    log INFO "Aşama 7/7 — doğrulama"
    # DD-152: Docker yok; kurulu modüller dosyaları değiştiyse master-modul ile yeniden uygulanır.
    reapply_modules
    "$SBIN_DIR/master-firewall" --check

    # Drop-in doğru yazılmış olsa bile /etc/sysctl.d'de sonradan sıralanan bir
    # dosya onu ezebilir; belirleyici olan ÇALIŞMA ANINDAKİ değer (DD-105).
    # ip_forward exit node'un varlık şartı: fail-closed.
    local fwd rmem
    fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    [[ "$fwd" == "1" ]] ||
        die "net.ipv4.ip_forward=$fwd (exit node için 1 olmalı; $SYSCTL_FORWARD_FILE başka bir /etc/sysctl.d dosyasınca eziliyor olabilir)"
    rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
    [[ "$rmem" =~ ^[0-9]+$ ]] || rmem=0
    if (( rmem < NET_BUF_FLOOR_BYTES )); then
        log WARN "net.core.rmem_max=$rmem taban değerin ($NET_BUF_FLOOR_BYTES) altında; $SYSCTL_NETBUF_FILE eziliyor olabilir"
    fi
    # DD-111: sonuç geri okunur. Bir optimizasyon, sözleşme maddesi değil —
    # uyumsuzluk uyarı üretir, kurulumu düşürmez.
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo bilinmiyor)"
    if [[ -f "$SYSCTL_TCP_FILE" && "$cc" != "$TCP_CONGESTION_CONTROL" ]]; then
        log WARN "tcp_congestion_control=$cc ($TCP_CONGESTION_CONTROL bekleniyordu; $SYSCTL_TCP_FILE eziliyor olabilir)"
    fi
    # DD-113: güncelleme politikası geri okunur (etkin apt-config + zamanlayıcı).
    # Bakım konusu, sözleşme maddesi değil — uyumsuzluk uyarı üretir.
    local periodic
    # awk boruyu sonuna kadar okur: erken `exit` apt-config'e SIGPIPE verir ve
    # pipefail altında 141 ile kurulumu düşürür (canlı testte görüldü).
    periodic="$(apt-config dump 2>/dev/null | awk -F'"' '/^APT::Periodic::Unattended-Upgrade /{v=$2} END{print v}')"
    if [[ "$periodic" != "1" ]] || ! command -v unattended-upgrade >/dev/null 2>&1 ||
        ! systemctl is-active --quiet apt-daily-upgrade.timer; then
        log WARN "otomatik güvenlik güncellemeleri etkin değil (APT::Periodic::Unattended-Upgrade=${periodic:-yok}; $APT_PERIODIC_FILE eziliyor olabilir)"
    fi

    local name resolver ans dig_out code health line
    # shellcheck disable=SC2086
    for name in $SERVICE_NAMES; do
        for resolver in 127.0.0.1 "$TAILSCALE_IPV4"; do
            ans="$(
                dig +short +time=2 +tries=1 "${name}.${LOCAL_DOMAIN}" @"$resolver" |
                    head -n1 || true
            )"
            [[ "$ans" == "$TAILSCALE_IPV4" ]] ||
                die "DNS: ${name}.${LOCAL_DOMAIN} @$resolver -> '${ans}' (beklenen $TAILSCALE_IPV4)"
        done
    done

    dig_out="$(
        dig +time=2 +tries=1 +noall +comments "not-in-${LOCAL_DOMAIN}.example" \
            @"$TAILSCALE_IPV4" 2>/dev/null || true
    )"
    [[ "$dig_out" == *"status: REFUSED"* ]] ||
        die "DNS: alan dışı sorgu REFUSED değil (Tailscale DNS)"

    health="$(curl -fsS --max-time 5 "http://${TAILSCALE_IPV4}/" -H "Host: health.${LOCAL_DOMAIN}" || true)"
    [[ "$health" == "ok" ]] || die "Caddy health yanıtı beklenen gibi değil"

    # DD-120/DD-143: WireGuard katmanı hazır; kayıtta ağ varsa her biri ayakta, portu
    # kaydındaki port ve erişimi "ui" olanın arayüzleri caddy-wg'den non-5xx.
    local wg_iface wg_scope wg_s4 wg_port wg_ui_port ui_code
    "$SBIN_DIR/master-wg" version >/dev/null ||
        die "master-wg çalışmıyor ($SBIN_DIR/master-wg)"
    WG_PEER_COUNT=0
    WG_NET_COUNT=0
    # DD-150: ağlar ve çekirdek modülü yalnız WireGuard modülü kuruluyken denetlenir.
    local wg_on=0 files_on=0
    [[ -z "$(module_state wireguard)" ]] || wg_on=1
    [[ -z "$(module_state dosya)" ]] || files_on=1
    if [[ "$wg_on" -eq 1 ]]; then
        [[ -f "$WG_MODULES_LOAD_FILE" ]] || die "WireGuard modül dosyası yok: $WG_MODULES_LOAD_FILE"
    fi
    if [[ "$wg_on" -eq 1 && -n "${WG_NETWORKS_FILE:-}" && -f "$WG_NETWORKS_FILE" ]]; then
        while IFS=$'\t' read -r wg_iface wg_port wg_scope wg_s4 _; do
            [[ "$wg_iface" =~ ^wg[0-9]$ ]] || continue
            WG_NET_COUNT=$((WG_NET_COUNT + 1))
            [[ "$(wg show "$wg_iface" listen-port 2>/dev/null || true)" == "$wg_port" ]] ||
                die "WireGuard $wg_iface dinleme portu kayıttaki $wg_port değil"
            ip -4 -o addr show dev "$wg_iface" 2>/dev/null | grep -q " ${wg_s4}/" ||
                die "WireGuard $wg_iface üzerinde $wg_s4 yok"
            WG_PEER_COUNT=$((WG_PEER_COUNT + $(wg show "$wg_iface" peers 2>/dev/null | grep -c . || true)))
            # DD-151: WireGuard'dan açılan arayüz qBittorrent'inkidir; modül kuruluysa sınanır.
            [[ "$wg_scope" == ui && -n "$(module_state torrent)" ]] || continue
            wg_ui_port="$TORRENT_UI_PORT"
            ui_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://${wg_s4}:${wg_ui_port}/" || true)"
            [[ "$ui_code" =~ ^[1-4][0-9][0-9]$ ]] ||
                die "caddy-wg ${wg_s4}:${wg_ui_port}: HTTP '${ui_code}' (non-5xx beklenir)"
        done <"$WG_NETWORKS_FILE"
    fi

    # DD-140, DD-147: Konsol tailnet'ten parolasız açılır. Parola olmadığı için asıl korumalar
    # sınanır: X-Konsol başlığı olmayan API isteği (başka bir sitenin tarayıcıdan attığı
    # istek) ve yabancı Host (DNS rebinding) iki arka uçta da reddedilir. Panel WireGuard
    # adresinde dinlenmez. DD-154: eski adresler (wg., dosya., file.) yoktur.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: panel.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
    [[ "$code" == "200" ]] || die "Konsol sayfası tailnet'ten açılmadı (HTTP $code)"
    local gate_port gate_path gates="$WG_PANEL_PORT:/api/wg/state"
    [[ "$files_on" -eq 0 ]] || gates="$FILES_PANEL_PORT:/api/state $gates"
    for gate_port in $gates; do
        gate_path="${gate_port#*:}"
        gate_port="${gate_port%%:*}"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Host: panel.${LOCAL_DOMAIN}" "http://127.0.0.1:${gate_port}${gate_path}" || true)"
        [[ "$code" == "403" ]] || die "Konsol ${gate_path}: X-Konsol başlığı olmadan HTTP $code (beklenen 403)"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'X-Konsol: 1' \
            -H "Host: baska.ornek" "http://127.0.0.1:${gate_port}${gate_path}" || true)"
        [[ "$code" == "403" ]] || die "Konsol ${gate_path}: yabancı Host ile HTTP $code (beklenen 403)"
    done
    local panel_out
    panel_out="$(python3 "$SBIN_DIR/master-wg-panel" check \
        --url "http://${TAILSCALE_IPV4}/api/wg/state" --host "panel.${LOCAL_DOMAIN}" 2>&1)" ||
        die "Konsol WireGuard arka ucu yanıt vermedi: $panel_out"
    log INFO "Konsol WireGuard arka ucu açıldı: http://panel.${LOCAL_DOMAIN} ($panel_out)"
    # DD-139: dosya arka ucu açılır, kök yazılabilir, root değil (DD-150: modül kuruluysa).
    local files_out files_uid
    if [[ "$files_on" -eq 1 ]]; then
        files_out="$(python3 "$SBIN_DIR/master-files-panel" check \
            --url "http://${TAILSCALE_IPV4}/api/state" --host "panel.${LOCAL_DOMAIN}" 2>&1)" ||
            die "Konsol dosya arka ucu yanıt vermedi: $files_out"
        log INFO "Konsol dosya arka ucu açıldı: $files_out"
        files_uid="$(ps -o uid= -p "$(systemctl show -p MainPID --value master-files-panel.service)" 2>/dev/null | tr -d ' ')"
        [[ "$files_uid" == "$DOWNLOADS_UID" ]] ||
            die "Dosya paneli uid '${files_uid}' ile çalışıyor (beklenen $DOWNLOADS_UID; root olmamalı)"
    else
        log INFO "Dosya yöneticisi kurulu değil; Konsol → Modüller'den kurulur"
    fi
    # DD-143: ağ varsa Konsol o ağın sunucu adresinde dinlememeli (ağ yoksa denetim atlanır).
    local wg_first_addr=""
    [[ "$wg_on" -eq 0 || ! -f "${WG_NETWORKS_FILE:-}" ]] ||
        wg_first_addr="$(awk -F'\t' '$1 ~ /^wg[0-9]$/ {print $4; exit}' "$WG_NETWORKS_FILE")"
    if [[ -n "$wg_first_addr" ]]; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://${wg_first_addr}:${FILES_PANEL_PORT}/" || true)"
        [[ "$code" == "000" ]] || die "Konsol WireGuard adresinde yanıt verdi (HTTP $code)"
    fi
    # DD-141: paylaşım kökü indirme sahibinde (dosya servisi bağlantıları oraya yazar). WebDAV'ı
    # (401, ad ve Infuse adresi) Paylaşım modülü kurulurken master-modul sınar (DD-149).
    local share_owner
    share_owner="$(stat -c '%u:%g' "$SERVER_ROOT/$SHARE_DIR/w" 2>/dev/null || true)"
    [[ "$share_owner" == "${DOWNLOADS_UID}:${DOWNLOADS_GID}" ]] ||
        die "Paylaşım kökü ${SERVER_ROOT}/${SHARE_DIR}/w sahibi '${share_owner}' (beklenen ${DOWNLOADS_UID}:${DOWNLOADS_GID})"

    # DD-144: çöp ve paylaşım kökü indirme klasörünün dışında; qBittorrent onları göremez,
    # Paylaşım çöpü göremez — kurulurken master-modul sınar (DD-151, DD-152).
    if [[ -n "$wg_first_addr" ]]; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://${wg_first_addr}:${WG_PANEL_PORT}/" || true)"
        [[ "$code" == "000" ]] || die "Konsol arka ucu WireGuard adresinde yanıt verdi (HTTP $code)"
    fi

    log INFO "Temel doğrulamalar geçti"
}

# Özet: her modülün durumu; kurulu olanın adresi (DD-148). v2-120'ye dek kurulu modül için de
# "Konsol → Modüller'den kurulur" yazılıyordu.
summary_modules() {
    local id name info st
    for id in dosya wireguard torrent paylasim; do
        case "$id" in
            dosya) name="Dosya yöneticisi"; info="$SERVER_ROOT" ;;
            wireguard) name="WireGuard"; info="${WG_NET_COUNT:-0} ağ, ${WG_PEER_COUNT:-0} peer" ;;
            torrent) name="qBittorrent"; info="http://torrent.${LOCAL_DOMAIN}; ilk giriş bilgisi kartında" ;;
            paylasim) name="Paylaşım"; info="http://paylas.${LOCAL_DOMAIN}, Infuse için ${TAILSCALE_IPV4}:${SHARE_PORT}; hesabı kartında" ;;
        esac
        case "$(module_state "$id")" in
            calisiyor) st="kurulu" ;;
            durduruldu) st="kurulu, durduruldu" ;;
            *) st="kurulu değil"; info="" ;;
        esac
        printf '  %s: %s%s\n' "$name" "$st" "${info:+ — $info}"
    done
}

print_summary() {
    log INFO "Kurulum tamam — v$V2_VERSION"
    cat <<EOF

WAN:          $WAN_INTERFACE $WAN_IPV4 ${WAN_IPV6:-"(IPv6 yok)"}
Tailscale:    $TAILSCALE_IPV4 ${TAILSCALE_IPV6:-"(IPv6 yok)"}
Domain:       $LOCAL_DOMAIN
Kullanıcı alanı: $SERVER_ROOT (indirmeler $DOWNLOADS_PATH, kütüphane $SERVER_ROOT/$MEDIA_SUBDIR)
WireGuard:    ${WG_NET_COUNT:-0} ağ, ${WG_PEER_COUNT:-0} peer (endpoint: $WG_ENDPOINT_HOST; modül ve ağlar Konsol'dan)
State:        $STATE_FILE
Log:          $V2_LOG_FILE

Manuel Tailscale Admin:
  1) DNS → Nameservers → Custom: $TAILSCALE_IPV4
  2) Restrict to domain: $LOCAL_DOMAIN
  3) Exit node olarak bu makineyi onayla

Konsol: http://panel.${LOCAL_DOMAIN} (sunucu durumu, modüller ve günlük; parolasız, yalnız Tailscale)
Modüller (Konsol → Modüller'den kurulur, durdurulur, kaldırılır; DD-148, DD-150, DD-151):
$(summary_modules)
  WireGuard ağları WireGuard → Yapılandır'dan; "Local erişim" açık ağlarda qBittorrent arayüzü
  o ağın sunucu adresinde açılır. Peer ve QR: Konsol ya da Mac'te wireguard.command.
Tailscale IP: refresh-tailnet-config → Caddy

EOF
}

main() {
    log INFO "master-stack $V2_VERSION başlıyor"
    stage_0
    stage_1
    stage_2
    stage_3
    stage_4
    stage_5
    # DD-128: hazır ayarların işi bitti; anahtarlar /run'da kalmaz.
    stage_6
    stage_7
    print_summary
}

if [[ "${V2_INHIBITED:-0}" != "1" ]]; then
    if ! command -v systemd-inhibit >/dev/null 2>&1 ||
       [[ ! -d /run/systemd/system ]]; then
        die "systemd-inhibit kullanılamıyor; kurulum başlatılmadı"
    fi
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    [[ -n "$self" && -f "$self" ]] || die "kurulum betiğinin yolu çözülemedi"
    exec systemd-inhibit \
        --what=shutdown:sleep \
        --who=master-stack-installer \
        --why="master-stack kurulum işlemi" \
        --mode=block \
        env V2_INHIBITED=1 bash "$self" "$@"
fi

main "$@"
