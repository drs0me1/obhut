#!/usr/bin/env bash
# Kurulum — Debian 13 / Ubuntu 24.04 / 26.04 LTS, doğrusal aşamalar,
# tekrar çalıştırılabilir.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

V2_VERSION="2026.08.06-v2-89"
V2_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "$V2_ROOT/common.sh"
# shellcheck source=config/defaults.env
source "$V2_ROOT/config/defaults.env"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
V2_LOG_FILE="${V2_LOG_FILE:-$LOG_DIR/install.log}"
RUN_FULL_UPGRADE=0
COMPOSE_NEEDS_UP=1
FIREWALL_NEEDS_RESTART=0
PULL_IMAGES=0
# state.env'de kayıtlı OS kimliği canlı os-release ile uyuşmuyorsa 1 olur;
# OS'a bağlı adımlar dosya içeriği aynı kalsa bile yeniden uygulanır (DD-104).
OS_CHANGED=0
# Ubuntu'da unattended-upgrades varsayılan açık: apt kilidi dakikalarca
# tutulabilir. Kilitte hemen düşmek yerine bekle; retry üstte ayrıca sarar.
APT_OPTS=(-o DPkg::Lock::Timeout=60)
# DD-119: kurulum girdi dosyasının alanları (şablon: config/kurulum.env.example).
# Hepsi dosyada yazılı olmalı; INPUT_NONEMPTY_KEYS boş da olamaz. Boş alan adı,
# downloads yolu ya da port defaults.env varsayılanını alır; boş TS_AUTH_KEY
# tarayıcıdan giriş demektir. SSH_HOST'u yalnız launcher okur.
INPUT_KEYS="SSH_HOST LOCAL_DOMAIN DOWNLOADS_PATH WG_PUBLIC_PORT WEBDAV_PORT WEBDAV_USER WEBDAV_PASS DOZZLE_USER DOZZLE_PASS TRANSMISSION_USER TRANSMISSION_PASS FILEBROWSER_USER FILEBROWSER_PASS TS_AUTH_KEY"
INPUT_NONEMPTY_KEYS="WEBDAV_USER WEBDAV_PASS DOZZLE_USER DOZZLE_PASS TRANSMISSION_USER TRANSMISSION_PASS FILEBROWSER_USER FILEBROWSER_PASS"

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

# DD-119: girdi dosyasındaki bir hesabı eski soruların kurallarıyla doğrular.
# Mesaj değeri yazmaz.
validate_account() {
    local label="$1" user="$2" pass="$3" user_re="$4" min="$5"
    [[ "$user" =~ $user_re ]] || die "girdi dosyası: geçersiz $label kullanıcı adı"
    [[ "${#pass}" -ge "$min" ]] || die "girdi dosyası: $label parolası en az $min karakter olmalı"
}

write_state() {
    atomic_write "$STATE_FILE" 0600 <<EOF
V2_VERSION=$V2_VERSION
WAN_INTERFACE=$WAN_INTERFACE
WAN_IPV4=$WAN_IPV4
TAILSCALE_IF=$TAILSCALE_IF
TAILSCALE_UDP_PORT=$TAILSCALE_UDP_PORT
TAILSCALE_IPV4=$TAILSCALE_IPV4
TAILSCALE_IPV6=$TAILSCALE_IPV6
LOCAL_DOMAIN=$LOCAL_DOMAIN
DOWNLOADS_PATH=$DOWNLOADS_PATH
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST
WG_PUBLIC_PORT=$WG_PUBLIC_PORT
TORRENT_PUBLIC_PORT=$TORRENT_PUBLIC_PORT
SSH_PUBLIC_PORT=$SSH_PUBLIC_PORT
WEBDAV_PORT=$WEBDAV_PORT
CHAIN_INPUT=$CHAIN_INPUT
CHAIN_DOCKER=$CHAIN_DOCKER
CHAIN_FORWARD=$CHAIN_FORWARD
CHAIN_NAT=$CHAIN_NAT
CHAIN_STAGING_PREFIX=$CHAIN_STAGING_PREFIX
WG_INTERFACE=$WG_INTERFACE
WG_SERVER_IPV4=$WG_SERVER_IPV4
WG_SERVER_IPV6=$WG_SERVER_IPV6
WG_SUBNET4=$WG_SUBNET4
WG_SUBNET6=$WG_SUBNET6
WG_CONF_FILE=$WG_CONF_FILE
WG_CLIENTS_DIR=$WG_CLIENTS_DIR
WG_CLIENT_ALLOWED_IPS="$WG_CLIENT_ALLOWED_IPS"
RUNTIME_DIR=$RUNTIME_DIR
DOZZLE_UI_PORT=$DOZZLE_UI_PORT
TORRENT_UI_PORT=$TORRENT_UI_PORT
FILEBROWSER_UI_PORT=$FILEBROWSER_UI_PORT
OS_ID=$OS_ID
OS_CODENAME=$OS_CODENAME
OS_VERSION_ID=$OS_VERSION_ID
OS_ARCH=$OS_ARCH
KERNEL_RELEASE=$(uname -r)
EOF
}

# Kurulumun hangi OS üzerinde yapıldığını state.env'den okur. Kayıt yoksa
# (v2-73 ve öncesi) sürüm değişimi iddia edilmez — yalnız yeni alanlar yazılır.
detect_os_change() {
    [[ -r "$STATE_FILE" ]] || return 0
    local prev_id prev_codename prev_version
    prev_id="$(awk -F= '/^OS_ID=/{print $2; exit}' "$STATE_FILE" || true)"
    prev_codename="$(awk -F= '/^OS_CODENAME=/{print $2; exit}' "$STATE_FILE" || true)"
    prev_version="$(awk -F= '/^OS_VERSION_ID=/{print $2; exit}' "$STATE_FILE" || true)"
    [[ -n "$prev_id" && -n "$prev_codename" ]] || {
        log INFO "state.env'de OS kaydı yok (v2-73 öncesi); bu çalıştırmada eklenecek"
        return 0
    }
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
DOWNLOADS_PATH=$DOWNLOADS_PATH
WG_PUBLIC_PORT=$WG_PUBLIC_PORT
WEBDAV_PORT=$WEBDAV_PORT
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

# DD-115: auth key ile giriş. Anahtar argv'ye (ps), loga ve kalıcı diske girmez:
# root'a özel tmpfs'teki dosyadan `--auth-key=file:` ile okunur, komut döner
# dönmez (ya da betik yarıda kalırsa çıkışta) silinir. Anahtar reddedilir veya
# süre dolarsa 1 döner; çağıran tarayıcı akışına geçer.
tailscale_login_with_key() {
    local keyfile="$RUNTIME_DIR/tailscale-authkey" rc=0
    log INFO "Tailscale: auth key ile giriş"
    trap 'rm -f -- "$RUNTIME_DIR/tailscale-authkey"' EXIT
    (umask 077 && printf '%s' "$TS_AUTH_KEY" >"$keyfile")
    # Çıkış kodu tee'nin değil tailscale'in: pipefail ayarından bağımsız okunur.
    set +e
    timeout "$TS_AUTHKEY_LOGIN_SECONDS" \
        tailscale up --auth-key="file:$keyfile" --advertise-exit-node --ssh 2>&1 |
        tee -a "$V2_LOG_FILE"
    rc=${PIPESTATUS[0]}
    set -e
    rm -f -- "$keyfile"
    trap - EXIT
    # rc 0: aşama 2'nin çevrimiçi bekleme döngüsü sonrasını bekler (cihaz onayı dahil).
    [[ "$rc" -ne 0 ]] || return 0
    [[ "$(tailscale_login_state)" != "complete" ]] || return 0
    log WARN "Tailscale auth key ile giriş olmadı (çıkış $rc: anahtar geçersiz, süresi dolmuş ya da tek kullanımlık ve kullanılmış olabilir); tarayıcıdan girişe geçiliyor"
    return 1
}

# wg_peer_section DOSYA — ilk "# peer: " ya da [Peer] satırından sona kadar.
wg_peer_section() {
    awk '/^# peer: / || /^\[Peer\]$/ {p = 1} p {print}' "$1"
}

# DD-124: WireGuard'ın kaynağı sunucudaki wg0.conf. Kurulum yalnız [Interface]
# bölümünü yönetir: dosya yoksa sunucu anahtarını `wg genkey` ile üretir, varsa
# anahtarı ve bütün [Peer] bloklarını olduğu gibi korur. Peer'ları master-wg
# (Mac'te wireguard.command) ekler ve çıkarır. NAT ve FORWARD master-firewall'dadır
# (DD-16/DD-17): PostUp yok. Firewall'dan sonra çağrılır.
# DD-123: değişiklik `wg syncconf` ile canlı gider; arayüz yalnız adresi/MTU'su
# değişince ya da ayakta değilken yeniden başlar.
ensure_wireguard() {
    local private="" peers="" content changed old_iface="" new_iface stripped
    # Kernel modülü çekirdekte; öneriler wireguard-dkms çekebilirdi.
    retry "apt-wireguard" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        --no-install-recommends wireguard-tools qrencode
    modprobe wireguard 2>/dev/null || log WARN "modprobe wireguard başarısız; çekirdek desteği yoksa wg-quick başlamaz"
    atomic_write "$WG_MODULES_LOAD_FILE" 0644 <<<"wireguard"
    install -d -m 0700 -o root -g root "${WG_CONF_FILE%/*}" "$WG_CLIENTS_DIR"
    if [[ -f "$WG_CONF_FILE" ]]; then
        private="$(awk -F' = ' '/^\[Peer\]$/ {exit} $1 == "PrivateKey" {print $2; exit}' "$WG_CONF_FILE")"
        [[ "$private" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
            die "$WG_CONF_FILE içinde sunucu anahtarı yok ya da bozuk; düzeltin ya da silin (silinirse yeni anahtar üretilir, bütün cihazlar yeniden eklenmeli)"
        peers="$(wg_peer_section "$WG_CONF_FILE")"
        old_iface="$(awk '/^# peer: / || /^\[Peer\]$/ {exit} /^(Address|MTU) = /' "$WG_CONF_FILE")"
    else
        private="$(wg genkey)" || die "WireGuard sunucu anahtarı üretilemedi"
        log INFO "WireGuard sunucu anahtarı üretildi; peer eklemek için Mac'te wireguard.command"
    fi
    content="# master-stack — [Interface] kurulumundur; peer'ları master-wg (wireguard.command) yönetir (DD-124).
[Interface]
Address = ${WG_SERVER_IPV4}/${WG_SUBNET4#*/}, ${WG_SERVER_IPV6}/${WG_SUBNET6#*/}
ListenPort = ${WG_PUBLIC_PORT}
MTU = ${WG_MTU}
PrivateKey = ${private}"
    [[ -z "$peers" ]] || content+="

${peers}"
    new_iface="$(awk '/^# peer: / || /^\[Peer\]$/ {exit} /^(Address|MTU) = /' <<<"$content")"
    atomic_write "$WG_CONF_FILE" 0600 <<<"$content"
    changed="$V2_LAST_ATOMIC_CHANGED"
    content=""
    private=""
    systemctl enable --quiet "wg-quick@${WG_INTERFACE}.service"
    if ! systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service" ||
        [[ "$changed" -eq 1 && "$old_iface" != "$new_iface" ]]; then
        systemctl restart "wg-quick@${WG_INTERFACE}.service"
        log INFO "WireGuard ${WG_INTERFACE}: UDP ${WG_PUBLIC_PORT}"
    elif [[ "$changed" -eq 1 ]]; then
        # `wg-quick strip` boş dönerse syncconf anahtarı ve bütün peer'ları
        # silerdi: çıktı önce denetlenir. Anahtar printf ile (builtin) gider.
        stripped="$(wg-quick strip "$WG_INTERFACE" 2>/dev/null || true)"
        if [[ "$stripped" == *"PrivateKey = "* ]] &&
            wg syncconf "$WG_INTERFACE" <(printf '%s\n' "$stripped"); then
            log INFO "WireGuard ${WG_INTERFACE}: değişiklik canlı uygulandı (yeniden başlatılmadı)"
        else
            log WARN "wg syncconf başarısız; ${WG_INTERFACE} yeniden başlatılıyor"
            systemctl restart "wg-quick@${WG_INTERFACE}.service"
        fi
        stripped=""
    else
        log INFO "WireGuard yapılandırması aynı; yeniden başlatılmadı"
    fi
}

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
# hem Tailscale hem Docker debian/ubuntu için aynı URL kalıbını yayınlar.
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

install_docker_repo() {
    # OS-DIVERGENCE: docker-repo-suite (debian+ubuntu) — URIs/Suites os-release'ten
    # türer; linux/debian ve linux/ubuntu aynı URL kalıbını yayınlar [DD-102]
    assert_repo_suite "Docker" \
        "https://download.docker.com/linux/${OS_ID}/dists/${OS_CODENAME}/Release"
    install -m 0755 -d /etc/apt/keyrings
    retry "docker-gpg" 3 60 -- \
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    atomic_write /etc/apt/sources.list.d/docker.sources 0644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/$OS_ID
Suites: $OS_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

# firewall.sh ve Docker aynı netfilter arka ucunu kullanmak zorunda. Alternatif
# legacy'ye alınmışsa Docker nft tablosuna yazar, betik legacy'yi okur ve
# DOCKER-USER "yok" görünür — semptomu bildiren, sebebi gizleyen bir ölüm.
# Kapıyı koyup gerçek çareyi söylüyoruz (DD-106).
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
            die "$bin arka ucu nft değil ($ver); Docker nft kullanır. Çare: update-alternatives --set $bin /usr/sbin/${bin}-nft"
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
    # DD-117: qBittorrent'ten kalan konteyner peer portunu tutar, Transmission
    # başlayamaz. Kurulum onu silmez (DD-96); hiçbir şey değişmeden durur.
    if command -v docker >/dev/null 2>&1 && docker inspect qbittorrent >/dev/null 2>&1; then
        die "qBittorrent konteyneri hâlâ var ve peer portunu tutuyor; Transmission başlayamaz (DD-117). Kaldırın: docker rm -f qbittorrent (ayarları docker_qbit_config volume'ünde kalır), sonra kurulumu yeniden çalıştırın"
    fi

    # defaults.env değerleri config.env source edilmeden önce alınır.
    local def_domain="$DEFAULT_LOCAL_DOMAIN" def_dl="$DOWNLOADS_PATH_DEFAULT"
    local def_webdav_port="$WEBDAV_PORT" def_wg_port="$WG_PUBLIC_PORT"
    local prev_webdav_port="$WEBDAV_PORT" prev_wg_port="$WG_PUBLIC_PORT"
    if [[ -r "$STATE_FILE" ]]; then
        local state_wg
        state_wg="$(awk -F= '/^WG_PUBLIC_PORT=/{print $2; exit}' "$STATE_FILE" || true)"
        [[ "$state_wg" =~ ^[0-9]+$ ]] && prev_wg_port="$state_wg"
    fi
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        prev_webdav_port="${WEBDAV_PORT:-$prev_webdav_port}"
        if grep -q '^WG_PUBLIC_PORT=' "$CONFIG_FILE"; then
            prev_wg_port="${WG_PUBLIC_PORT:-$prev_wg_port}"
        fi
    fi

    # DD-119: değerler girdi dosyasından; boş alan defaults.env varsayılanı.
    LOCAL_DOMAIN="${INPUT_LOCAL_DOMAIN:-$def_domain}"
    [[ "$LOCAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die "geçersiz alan adı: $LOCAL_DOMAIN"
    DOWNLOADS_PATH="${INPUT_DOWNLOADS_PATH:-$def_dl}"
    [[ "$DOWNLOADS_PATH" == /* ]] || die "downloads yolu mutlak olmalı"
    [[ "$DOWNLOADS_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
        die "downloads yolu yalnızca [A-Za-z0-9._/-] içerebilir"
    [[ "$DOWNLOADS_PATH" != *//* ]] || die "downloads yolu '//' içeremez"
    [[ "$DOWNLOADS_PATH" =~ (^|/)\.\.(/|$) ]] &&
        die "downloads yolu '..' içeremez"
    assert_downloads_path_allowed "$DOWNLOADS_PATH"

    WG_PUBLIC_PORT="${INPUT_WG_PUBLIC_PORT:-$def_wg_port}"
    [[ "$WG_PUBLIC_PORT" =~ ^[0-9]+$ ]] || die "WireGuard UDP portu sayı olmalı"
    [[ "$WG_PUBLIC_PORT" -ge 1 && "$WG_PUBLIC_PORT" -le 65535 ]] ||
        die "WireGuard UDP portu 1-65535 arasında olmalı"
    case "$WG_PUBLIC_PORT" in
        "$DNS_PORT" | "$CADDY_HTTP_PORT" | "$SSH_PUBLIC_PORT" | "$TORRENT_PUBLIC_PORT" | "$DOZZLE_UI_PORT" | \
        "$FILEBROWSER_UI_PORT" | "$TORRENT_UI_PORT" | "$prev_webdav_port" | \
        "$TAILSCALE_UDP_PORT")
            die "WireGuard UDP portu başka bir stack portuyla çakışıyor: $WG_PUBLIC_PORT"
            ;;
    esac
    if [[ "$WG_PUBLIC_PORT" != "$prev_wg_port" ]]; then
        log INFO "WireGuard UDP portu değişti: $prev_wg_port → $WG_PUBLIC_PORT (wg0.conf ve firewall yeniden yazılacak)"
    fi

    WEBDAV_PORT="${INPUT_WEBDAV_PORT:-$def_webdav_port}"
    [[ "$WEBDAV_PORT" =~ ^[0-9]+$ ]] || die "WebDAV portu sayı olmalı"
    [[ "$WEBDAV_PORT" -ge 1 && "$WEBDAV_PORT" -le 65535 ]] ||
        die "WebDAV portu 1-65535 arasında olmalı"
    case "$WEBDAV_PORT" in
        "$DNS_PORT" | "$CADDY_HTTP_PORT" | "$SSH_PUBLIC_PORT" | "$WG_PUBLIC_PORT" | "$TORRENT_PUBLIC_PORT" | \
        "$DOZZLE_UI_PORT" | "$FILEBROWSER_UI_PORT" | "$TORRENT_UI_PORT" | \
        "$TAILSCALE_UDP_PORT")
            die "WebDAV portu başka bir stack portuyla çakışıyor: $WEBDAV_PORT"
            ;;
    esac
    WEBDAV_PORT_CHANGED=0
    if [[ "$WEBDAV_PORT" != "$prev_webdav_port" ]]; then
        WEBDAV_PORT_CHANGED=1
        log INFO "WebDAV portu değişti: $prev_webdav_port → $WEBDAV_PORT (compose + Caddy)"
    fi

    detect_wan
    WG_ENDPOINT_HOST="$WAN_IPV4"

    # DD-119: dosya tek doğru kaynak. Hesaplar her çalıştırmada kayıtlı olanla
    # karşılaştırılır; farklıysa aşama 1 (WebDAV) ve 4 (Dozzle, Transmission,
    # FileBrowser) günceller. Parolalar yalnız bellekte durur.
    WEBDAV_NEW_USER="$INPUT_WEBDAV_USER"
    WEBDAV_NEW_PASS="$INPUT_WEBDAV_PASS"
    validate_account WebDAV "$WEBDAV_NEW_USER" "$WEBDAV_NEW_PASS" \
        '^[a-z][a-z0-9._-]{0,31}$' "$WEBDAV_MIN_PASSWORD_LENGTH"
    # DD-116: Dozzle parolası aşama 4'te imajın kendi aracına stdin'den gider.
    DOZZLE_NEW_USER="$INPUT_DOZZLE_USER"
    DOZZLE_NEW_PASS="$INPUT_DOZZLE_PASS"
    validate_account Dozzle "$DOZZLE_NEW_USER" "$DOZZLE_NEW_PASS" \
        '^[a-z][a-z0-9_-]{0,31}$' "$DOZZLE_MIN_PASSWORD_LENGTH"
    # DD-117: Transmission imajı düz parolayı her açılışta ister; root'a özel
    # dosyada durur, Compose'a ve docker inspect'e girmez.
    TRANSMISSION_NEW_USER="$INPUT_TRANSMISSION_USER"
    TRANSMISSION_NEW_PASS="$INPUT_TRANSMISSION_PASS"
    validate_account Transmission "$TRANSMISSION_NEW_USER" "$TRANSMISSION_NEW_PASS" \
        '^[a-z][a-z0-9_-]{0,31}$' "$TRANSMISSION_MIN_PASSWORD_LENGTH"
    # DD-118: FileBrowser hesabı; arayüzden değiştirilen parola dosyadakine döner.
    FILEBROWSER_NEW_USER="$INPUT_FILEBROWSER_USER"
    FILEBROWSER_NEW_PASS="$INPUT_FILEBROWSER_PASS"
    validate_account FileBrowser "$FILEBROWSER_NEW_USER" "$FILEBROWSER_NEW_PASS" \
        '^[a-z][a-z0-9_-]{0,31}$' "$FILEBROWSER_MIN_PASSWORD_LENGTH"

    # DD-115: auth key verilirse aşama 2'de tarayıcı adımı atlanır; boş = login
    # URL. Anahtar yalnız bellekte durur: config/state'e yazılmaz, dışa aktarılmaz.
    TS_AUTH_KEY="$INPUT_TS_AUTH_KEY"
    if [[ -n "$TS_AUTH_KEY" ]]; then
        [[ "$TS_AUTH_KEY" != tskey-client-* ]] ||
            die "girdi dosyası: TS_AUTH_KEY bir OAuth istemci sırrı; admin panelinden bir auth key (tskey-auth-…) oluşturun ya da boş bırakın"
        [[ "$TS_AUTH_KEY" =~ ^tskey-[A-Za-z0-9-]+$ ]] ||
            die "girdi dosyası: TS_AUTH_KEY 'tskey-' ile başlamalı ve yalnız harf, rakam, '-' içermeli; tarayıcıdan giriş için boş bırakın"
    fi
    local ts_key_note="yok (tarayıcıdan giriş)"
    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
        [[ "$(tailscale_login_state)" == "complete" ]]; then
        TS_AUTH_KEY=""
        ts_key_note="kullanılmayacak (Tailscale zaten online)"
    elif [[ -n "$TS_AUTH_KEY" ]]; then
        ts_key_note="var (aşama 2'de tarayıcı adımı atlanacak)"
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

    PULL_IMAGES=0
    if [[ "${V2_PULL_IMAGES:-}" == "1" ]]; then
        PULL_IMAGES=1
        log INFO "image pull: V2_PULL_IMAGES=1"
    elif [[ ! -r "$STATE_FILE" ]]; then
        log INFO "image pull: ilk kurulum (compose up zaten güncel imajları çeker)"
    else
        local pull_ans="h"
        prompt pull_ans "Konteyner imajları güncel sürüme çekilsin mi? (pull + eski imajlar silinir)" "h"
        if [[ "$pull_ans" =~ ^[EeYy]$ ]]; then
            PULL_IMAGES=1
        else
            log INFO "image pull atlandı"
        fi
    fi

    # DD-119: dosyadan gelen her şey tek ekranda, parolasız; ilk yazımdan
    # (config.env) önce tek onay.
    local yes_no_upgrade="hayır" yes_no_pull="hayır" confirm_ans="h"
    [[ "$RUN_FULL_UPGRADE" -eq 1 ]] && yes_no_upgrade="evet"
    [[ "$PULL_IMAGES" -eq 1 ]] && yes_no_pull="evet"
    cat <<EOF

Kurulum girdileri (kurulum/kurulum.env):
  Alan adı:      $LOCAL_DOMAIN
  Downloads:     $DOWNLOADS_PATH
  WireGuard:     UDP $WG_PUBLIC_PORT (peer'lar sunucuda; eklemek/çıkarmak: wireguard.command)
  WebDAV portu:  $WEBDAV_PORT
  Hesaplar:      WebDAV $WEBDAV_NEW_USER, Dozzle $DOZZLE_NEW_USER, Transmission $TRANSMISSION_NEW_USER, FileBrowser $FILEBROWSER_NEW_USER
                 (dosyadakinden farklı olan hesap güncellenir)
  Tailscale key: $ts_key_note
  full-upgrade:  $yes_no_upgrade
  image pull:    $yes_no_pull

EOF
    prompt confirm_ans "Bu değerlerle kurulum başlasın mı? (E/h)" "h"
    [[ "$confirm_ans" =~ ^[EeYy]$ ]] || die "kurulum iptal edildi; hiçbir ayar değiştirilmedi"

    write_config
}

# DD-113: dağıtımın güvenlik güncellemeleri kendiliğinden insin. Kaynak
# süzgeci paketin dağıtım varsayılanı (Debian: stable + security; Ubuntu:
# security); Docker/Tailscale/Caddy depoları eşleşmez, onları yalnız yeniden
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
    # kapatmaz. Kütüphane güncellemesinden sonra sshd/docker/containerd/
    # tailscaled/caddy/dnsmasq'ı aşamaların ortasında yeniden başlatır —
    # ufw kapısının reddettiği "tek şeyin iki sahibi" sınıfının aynısı.
    # SUSPEND apt kancasınca okunur; Debian'da needrestart kurulu değil, no-op.
    export NEEDRESTART_SUSPEND=1
    retry "apt-update" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
    if [[ "$RUN_FULL_UPGRADE" -eq 1 ]]; then
        retry "apt-upgrade" 2 "$APT_LOCK_TIMEOUT" -- \
            apt-get "${APT_OPTS[@]}" -y -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold full-upgrade
    fi
    retry "apt-base" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        ca-certificates curl gnupg ethtool iproute2 gawk procps kmod \
        iptables coreutils util-linux diffutils jq \
        apache2-utils dnsutils unattended-upgrades
    # Artık binary kesin var: arka uç denetimi burada zorunlu (DD-108).
    check_nft_iptables required
    timedatectl set-timezone "$TIMEZONE" || log WARN "saat dilimi ayarlanamadı"
    apply_unattended_upgrades

    ensure_webdav_htpasswd
}

# DD-119: htpasswd tek satırda dosyadaki hesabı taşıyorsa dokunulmaz; değilse
# yeniden yazılır ve çalışan webdav yeniden başlatılır (secret bir bind mount:
# `mv` sonrası konteyner eski dosyayı görür). Parola stdin'den gider.
ensure_webdav_htpasswd() {
    local tmp
    [[ -n "${WEBDAV_NEW_PASS:-}" ]] || return 0
    if [[ -f "$WEBDAV_HTPASSWD_FILE" && "$(wc -l <"$WEBDAV_HTPASSWD_FILE")" -eq 1 ]] &&
        printf '%s' "$WEBDAV_NEW_PASS" |
        htpasswd -vi "$WEBDAV_HTPASSWD_FILE" "$WEBDAV_NEW_USER" >/dev/null 2>&1; then
        log INFO "WebDAV hesabı girdi dosyasıyla aynı; dokunulmadı"
    else
        tmp="$(mktemp "$STATE_DIR/.htpasswd-XXXXXX")"
        printf '%s' "$WEBDAV_NEW_PASS" | htpasswd -i -B "$tmp" "$WEBDAV_NEW_USER"
        chmod 0600 "$tmp"
        chown root:root "$tmp"
        mv -f "$tmp" "$WEBDAV_HTPASSWD_FILE"
        log INFO "WebDAV hesabı yazıldı: $WEBDAV_HTPASSWD_FILE ($WEBDAV_NEW_USER)"
        if docker inspect webdav >/dev/null 2>&1; then
            docker restart webdav >/dev/null || log WARN "webdav yeniden başlatılamadı; yeni hesap bir sonraki açılışta geçerli"
        fi
    fi
    unset WEBDAV_NEW_PASS
    WEBDAV_NEW_USER=""
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

# v2-73'e kadar dosyalar 99-master-*.conf idi ve sağlayıcı imajının
# 99-nc-kernel.conf'u onlardan SONRA sıralanıyordu; son atama kazandığı için
# ip_forward boot'ta sessizce geri alınabilirdi. Yeni adlar 99-zz-* (DD-105);
# eskiler silinmezse aynı anahtar iki dosyadan yazılır.
remove_legacy_sysctl_files() {
    local f
    # shellcheck disable=SC2086 # boşlukla ayrılmış liste bilinçli
    for f in $SYSCTL_LEGACY_FILES; do
        [[ -f "$f" ]] || continue
        rm -f "$f"
        log INFO "eski sysctl drop-in silindi: $f"
    done
}

# TCP tıkanıklık denetimi (DD-111). Yalnız bu host'ta SONLANAN TCP'yi etkiler:
# Caddy'nin Infuse'a WebDAV akışı, Transmission yüklemeleri, arayüzler.
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
    remove_legacy_sysctl_files
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
        if [[ -z "${TS_AUTH_KEY:-}" ]] || ! tailscale_login_with_key; then
            tailscale_login
        fi
    else
        log INFO "Tailscale zaten online"
    fi
    unset TS_AUTH_KEY
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
    find "$root" \
        \( \( ! -uid "$uid" -o ! -gid "$gid" \) \
        -exec chown -h "${uid}:${gid}" {} + -false \) -o \
        \( -type d ! -perm 0775 -exec chmod 0775 {} + -false \) -o \
        \( -type f ! -perm 0664 -exec chmod 0664 {} + \)
}

# Recursive chown/chmod only under an allowlisted data root (DD-93).
assert_downloads_path_allowed() {
    local p="$1"
    case "$p" in
        / | /etc | /etc/* | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | \
        /boot | /boot/* | /dev | /dev/* | /proc | /proc/* | /sys | /sys/* | \
        /run | /run/* | /root | /root/* | /var | /var/* | /tmp | /tmp/* | \
        /home | /home/* | /lib | /lib/* | /lib64 | /lib64/* | /opt | /opt/* | \
        /srv | /media | /media/* | /mnt | /mnt/* )
            die "downloads yolu sistem dizinine izin vermez: $p"
            ;;
    esac
    case "$p" in
        /downloads | /downloads/* | /data | /data/* | \
        /srv/downloads | /srv/downloads/* )
            return 0
            ;;
        *)
            die "downloads yolu allowlist dışı (/downloads, /data, /srv/downloads): $p"
            ;;
    esac
}

# Klasik FileBrowser Bolt DB + image VOLUME /config — anonim volume oluşmasın.
ensure_filebrowser_data_dir() {
    mkdir -p "$FILEBROWSER_DATA_DIR/config"
    chown -R "${DOWNLOADS_UID}:${DOWNLOADS_GID}" "$FILEBROWSER_DATA_DIR"
    chmod 0750 "$FILEBROWSER_DATA_DIR" "$FILEBROWSER_DATA_DIR/config"
}

# DD-118: FileBrowser CLI'ı ağsız, tek seferlik konteynerde, yalnız geçici
# dizin bağlı çalışır. stdout (`config init` ayar dökümü, anahtar dahil)
# atılır; stderr hata ayıklama için geçici dizine yazılır.
filebrowser_cli() {
    local work="$1"
    shift
    docker run --rm --network none --user "$DOWNLOADS_UID:$DOWNLOADS_GID" \
        -w /database -v "$work:/database" --entrypoint filebrowser "$FILEBROWSER_IMAGE" \
        "$@" --database /database/filebrowser.db >/dev/null 2>>"$work/cli.log"
}

filebrowser_account_fail() {
    local work="$1" msg="$2"
    [[ -s "$work/cli.log" ]] && tail -n 5 -- "$work/cli.log" >&2
    rm -rf -- "$work"
    die "$msg"
}

# DD-118/DD-119: hesap girdi dosyasından gelir. Veritabanı yoksa kurulur,
# varsa dosyadakiyle eşitlenir. Parola argv'ye, loga, diske düz metin girmez.
ensure_filebrowser_account() {
    [[ -n "${FILEBROWSER_NEW_PASS:-}" ]] || return 0
    if [[ -f "$FILEBROWSER_DB_FILE" ]]; then
        sync_filebrowser_account
    else
        create_filebrowser_account
    fi
    unset FILEBROWSER_NEW_PASS
    FILEBROWSER_NEW_USER=""
}

# DD-118: ilk açılışın log'a yazdığı rastgele admin parolası hiç oluşmaz.
# Veritabanı geçici dizinde kurulur: `config init` bayrakları upstream'in ilk
# açılış ayarlarıyla aynıdır (ölçüldü, key hariç fark yok). Kullanıcı, bcrypt
# özeti htpasswd'e stdin'den giden bir JSON dosyasından içe aktarılır.
# Doğrulanan veritabanı tek `mv` ile yerine konur.
create_filebrowser_account() {
    local work hash
    work="$(mktemp -d "$FILEBROWSER_DATA_DIR/.init-XXXXXX")"
    chown "$DOWNLOADS_UID:$DOWNLOADS_GID" "$work"
    if ! filebrowser_cli "$work" config init --address 0.0.0.0 --port 80 --root /srv \
        --viewMode mosaic --sorting.by '' --redirectAfterCopyMove --hideLoginButton \
        --minimumPasswordLength "$FILEBROWSER_MIN_PASSWORD_LENGTH" ||
        ! filebrowser_cli "$work" config export /database/settings.json; then
        filebrowser_account_fail "$work" "FileBrowser veritabanı başlatılamadı"
    fi
    hash="$(printf '%s' "$FILEBROWSER_NEW_PASS" | htpasswd -niB -C 10 "$FILEBROWSER_NEW_USER" | cut -d: -f2-)"
    if [[ ! "$hash" =~ ^\$2[aby]\$10\$ ]] ||
        ! jq --arg u "$FILEBROWSER_NEW_USER" --arg h "$hash" \
            '[.settings.defaults + {id: 1, username: $u, password: $h, lockPassword: false, rules: []} |
              .perm.admin = true]' "$work/settings.json" >"$work/users.json"; then
        filebrowser_account_fail "$work" "FileBrowser kullanıcı kaydı hazırlanamadı"
    fi
    rm -f -- "$work/settings.json"
    chown "$DOWNLOADS_UID:$DOWNLOADS_GID" "$work/users.json"
    if ! filebrowser_cli "$work" users import /database/users.json ||
        ! filebrowser_cli "$work" users export /database/users.json ||
        ! jq -e --arg u "$FILEBROWSER_NEW_USER" \
            'length == 1 and .[0].username == $u and .[0].perm.admin == true and
             (.[0].password | test("^\\$2[aby]\\$"))' "$work/users.json" >/dev/null; then
        filebrowser_account_fail "$work" "FileBrowser hesabı oluşturulamadı"
    fi
    mv -f -- "$work/filebrowser.db" "$FILEBROWSER_DB_FILE"
    rm -rf -- "$work"
    log INFO "FileBrowser hesabı oluşturuldu: $FILEBROWSER_DB_FILE"
    # Veritabanı silinip yeniden oluşturulduysa çalışan konteyner eskisini tutar.
    if docker inspect filebrowser >/dev/null 2>&1; then
        docker restart filebrowser >/dev/null || log WARN "filebrowser yeniden başlatılamadı; yeni hesap bir sonraki açılışta geçerli"
    fi
}

# Hedef kayıt: dosyadaki adı taşıyan kullanıcı, yoksa en küçük id'li yönetici.
filebrowser_target_id() {
    jq -r --arg u "$FILEBROWSER_NEW_USER" \
        '(map(select(.username == $u)) + (map(select(.perm.admin == true)) | sort_by(.id))) | .[0].id // empty' \
        "$1"
}

# USERS_JSON ID: o id dosyadaki adı ve parolayı taşıyorsa 0.
filebrowser_user_matches() {
    local hash
    hash="$(jq -r --argjson id "$2" --arg u "$FILEBROWSER_NEW_USER" \
        '.[] | select(.id == $id and .username == $u) | .password' "$1")" || return 1
    bcrypt_matches "$FILEBROWSER_NEW_USER" "$hash" "$FILEBROWSER_NEW_PASS"
}

filebrowser_sync_fail() {
    local work="$1" was_running="$2" msg="$3"
    if [[ "$was_running" -eq 1 ]]; then
        docker start filebrowser >/dev/null || true
    fi
    filebrowser_account_fail "$work" "$msg"
}

# DD-119: çalışan FileBrowser Bolt dosyasını kilitler (CLI zaman aşımına düşer
# — ölçüldü), bu yüzden karşılaştırma bir kopyada yapılır ve hesap aynıysa
# konteynere dokunulmaz. Fark varsa konteyner durdurulur, taze kopyada
# `users import --overwrite` aynı id'ye adı ve özeti yazar (diğer alanlar ve
# ayarlar korunur; `--replace` "sole admin" hatası verir — ölçüldü), sonuç
# doğrulanır ve tek `mv` ile yerine konur. Başka kullanıcılara dokunulmaz.
sync_filebrowser_account() {
    local work id hash was_running=0
    work="$(mktemp -d "$FILEBROWSER_DATA_DIR/.sync-XXXXXX")"
    chown "$DOWNLOADS_UID:$DOWNLOADS_GID" "$work"
    cp -p -- "$FILEBROWSER_DB_FILE" "$work/filebrowser.db"
    filebrowser_cli "$work" users export /database/users.json ||
        filebrowser_account_fail "$work" "FileBrowser kullanıcıları okunamadı"
    id="$(filebrowser_target_id "$work/users.json" || true)"
    [[ "$id" =~ ^[0-9]+$ ]] ||
        filebrowser_account_fail "$work" "FileBrowser veritabanında yönetici hesabı yok"
    if filebrowser_user_matches "$work/users.json" "$id"; then
        rm -rf -- "$work"
        log INFO "FileBrowser hesabı girdi dosyasıyla aynı; dokunulmadı"
        return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' filebrowser 2>/dev/null)" == true ]]; then
        docker stop filebrowser >/dev/null ||
            filebrowser_account_fail "$work" "filebrowser durdurulamadı; hesap güncellenmedi"
        was_running=1
    fi
    # Durdurmadan önceki son yazımlar da gelsin: kopya yeniden alınır.
    cp -p -- "$FILEBROWSER_DB_FILE" "$work/filebrowser.db"
    rm -f -- "$work/users.json"
    hash="$(printf '%s' "$FILEBROWSER_NEW_PASS" | htpasswd -niB -C 10 "$FILEBROWSER_NEW_USER" | cut -d: -f2-)"
    if ! filebrowser_cli "$work" users export /database/users.json ||
        [[ ! "$hash" =~ ^\$2[aby]\$10\$ ]] ||
        ! jq --argjson id "$id" --arg u "$FILEBROWSER_NEW_USER" --arg h "$hash" \
            'map(select(.id == $id) | .username = $u | .password = $h)' \
            "$work/users.json" >"$work/import.json" ||
        ! jq -e 'length == 1' "$work/import.json" >/dev/null; then
        filebrowser_sync_fail "$work" "$was_running" "FileBrowser kullanıcı kaydı hazırlanamadı"
    fi
    chown "$DOWNLOADS_UID:$DOWNLOADS_GID" "$work/import.json"
    rm -f -- "$work/users.json"
    if ! filebrowser_cli "$work" users import --overwrite /database/import.json ||
        ! filebrowser_cli "$work" users export /database/users.json ||
        ! filebrowser_user_matches "$work/users.json" "$id"; then
        filebrowser_sync_fail "$work" "$was_running" "FileBrowser hesabı güncellenemedi"
    fi
    mv -f -- "$work/filebrowser.db" "$FILEBROWSER_DB_FILE"
    rm -rf -- "$work"
    log INFO "FileBrowser hesabı girdi dosyasıyla eşitlendi: $FILEBROWSER_NEW_USER"
    if [[ "$was_running" -eq 1 ]]; then
        docker start filebrowser >/dev/null || log WARN "filebrowser başlatılamadı"
    fi
}

# DD-119: users.yml tek kullanıcı taşıyor, adı dosyadaki ve özeti parolayla
# eşleşiyorsa 0. Kullanıcılar 4, alanları 8 boşluk girintili (generate çıktısı).
dozzle_users_match() {
    local hash
    [[ -f "$DOZZLE_USERS_FILE" ]] || return 1
    [[ "$(awk '/^    [^ #][^:]*:[[:space:]]*$/ {n++} END {print n+0}' "$DOZZLE_USERS_FILE")" -eq 1 ]] ||
        return 1
    hash="$(awk -v u="$DOZZLE_NEW_USER" '/^    [^ ]/ {in_user = ($1 == u ":")}
        in_user && $1 == "password:" {print $2}' "$DOZZLE_USERS_FILE")"
    bcrypt_matches "$DOZZLE_NEW_USER" "$hash" "$DOZZLE_NEW_PASS"
}

# DD-116: users.yml imajın kendi `generate` aracıyla üretilir (bcrypt; biçim
# upstream'in). Parola stdin'den gider — argv'ye, loga, diske düz metin girmez;
# konteyner ağsız. Rol `actions`: başlat/durdur/sil, shell yok.
ensure_dozzle_users() {
    local tmp
    install -d -m 0700 -o root -g root "$DOZZLE_DATA_DIR"
    [[ -n "${DOZZLE_NEW_PASS:-}" ]] || return 0
    if dozzle_users_match; then
        log INFO "Dozzle hesabı girdi dosyasıyla aynı; dokunulmadı"
        unset DOZZLE_NEW_PASS
        DOZZLE_NEW_USER=""
        return 0
    fi
    tmp="$(mktemp "$DOZZLE_DATA_DIR/.users-XXXXXX")"
    if ! printf '%s\n' "$DOZZLE_NEW_PASS" |
        docker run -i --rm --network none "$DOZZLE_IMAGE" \
            generate --user-roles actions "$DOZZLE_NEW_USER" >"$tmp"; then
        rm -f -- "$tmp"
        die "Dozzle kullanıcı dosyası üretilemedi"
    fi
    if ! awk -v u="$DOZZLE_NEW_USER" '$1 == u ":" {user=1} $1 == "password:" && $2 ~ /^\$2[aby]\$/ {hash=1}
        END {exit !(user && hash)}' "$tmp"; then
        rm -f -- "$tmp"
        die "Dozzle kullanıcı dosyası beklenen biçimde değil"
    fi
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f -- "$tmp" "$DOZZLE_USERS_FILE"
    unset DOZZLE_NEW_PASS
    DOZZLE_NEW_USER=""
    log INFO "Dozzle kullanıcı dosyası yazıldı: $DOZZLE_USERS_FILE"
    # Çalışan bir Dozzle yeni hesabı ancak yeniden açılışta okur.
    if docker inspect dozzle >/dev/null 2>&1; then
        docker restart dozzle >/dev/null || log WARN "dozzle yeniden başlatılamadı; yeni hesap bir sonraki açılışta geçerli"
    fi
}

# DD-117: /config bind — settings.json'u yalnız ilk kurulumda başlatır, sonrası
# Transmission'ındır. `rpc-port` şarttır: imajın kapanış betiği portu buradan
# okur; eksikse temiz kapanış olmaz ve ayarlar kaydedilmez (ölçüldü).
# Kimlik dosyaları root'a özel; konteynere salt okunur bağlanır.
ensure_transmission_files() {
    local settings="$TRANSMISSION_DATA_DIR/settings.json"
    install -d -m 0750 -o "$DOWNLOADS_UID" -g "$DOWNLOADS_GID" "$TRANSMISSION_DATA_DIR"
    if [[ ! -e "$settings" ]]; then
        jq -n '{"download-dir": "/downloads", "incomplete-dir": "/downloads/incomplete",
            "incomplete-dir-enabled": true, "port-forwarding-enabled": false, "rpc-port": 9091,
            "dht-enabled": false, "pex-enabled": false, "lpd-enabled": false,
            "download-queue-enabled": true, "download-queue-size": 12}' |
            atomic_write "$settings" 0600
        chown "$DOWNLOADS_UID:$DOWNLOADS_GID" "$settings"
        log INFO "Transmission başlangıç ayarları yazıldı: $settings"
    fi
    install -d -m 0700 -o root -g root "$TRANSMISSION_AUTH_DIR"
    [[ -n "${TRANSMISSION_NEW_PASS:-}" ]] || return 0
    # DD-119: kimlik dosyaları dosyadakiyle aynıysa dokunulmaz.
    if [[ -f "$TRANSMISSION_AUTH_DIR/user" && -f "$TRANSMISSION_AUTH_DIR/pass" &&
        "$(<"$TRANSMISSION_AUTH_DIR/user")" == "$TRANSMISSION_NEW_USER" &&
        "$(<"$TRANSMISSION_AUTH_DIR/pass")" == "$TRANSMISSION_NEW_PASS" ]]; then
        log INFO "Transmission hesabı girdi dosyasıyla aynı; dokunulmadı"
        unset TRANSMISSION_NEW_PASS
        TRANSMISSION_NEW_USER=""
        return 0
    fi
    (
        umask 077
        printf '%s' "$TRANSMISSION_NEW_USER" >"$TRANSMISSION_AUTH_DIR/.user.tmp"
        printf '%s' "$TRANSMISSION_NEW_PASS" >"$TRANSMISSION_AUTH_DIR/.pass.tmp"
    )
    chown root:root "$TRANSMISSION_AUTH_DIR/.user.tmp" "$TRANSMISSION_AUTH_DIR/.pass.tmp"
    mv -f -- "$TRANSMISSION_AUTH_DIR/.user.tmp" "$TRANSMISSION_AUTH_DIR/user"
    mv -f -- "$TRANSMISSION_AUTH_DIR/.pass.tmp" "$TRANSMISSION_AUTH_DIR/pass"
    unset TRANSMISSION_NEW_PASS
    TRANSMISSION_NEW_USER=""
    log INFO "Transmission kimlik dosyaları yazıldı: $TRANSMISSION_AUTH_DIR"
    if docker inspect transmission >/dev/null 2>&1; then
        docker restart transmission >/dev/null || log WARN "transmission yeniden başlatılamadı; yeni hesap bir sonraki açılışta geçerli"
    fi
}

# DD-8: yalnız bilinen anahtarları yaz; diğer daemon.json ayarlarını koru.
# log-opts yalnız sürücü json-file iken (varsayılan) dokunulur — operatör
# başka bir sürücü seçtiyse onun ayarı ezilmez (DD-107). Yürürlüğe girmesi
# docker restart + konteynerlerin yeniden yaratılmasını bekler; bu yüzden
# burada disruptif bir restart yapılmaz.
merge_docker_daemon_config() {
    local existing='{}' merged
    command -v jq >/dev/null 2>&1 || die "jq gerekli (daemon.json merge)"
    if [[ -f /etc/docker/daemon.json ]]; then
        existing="$(cat /etc/docker/daemon.json)"
        [[ -n "${existing//[[:space:]]/}" ]] || existing='{}'
    fi
    merged="$(
        jq --arg sz "$DOCKER_LOG_MAX_SIZE" --arg n "$DOCKER_LOG_MAX_FILE" '
            .dns = ["1.1.1.1", "1.0.0.1"]
            | if ((."log-driver" // "json-file") == "json-file")
              then ."log-opts" = ((."log-opts" // {}) +
                                  {"max-size": $sz, "max-file": $n})
              else . end
        ' <<<"$existing"
    )" || die "daemon.json jq merge başarısız (geçersiz JSON?)"
    atomic_write /etc/docker/daemon.json 0644 <<<"$merged"
}

stage_3() {
    log INFO "Aşama 3/7 — adresler ve dizinler"
    detect_wan
    detect_tailscale
    write_state
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1

    local d
    for d in \
        "$DOWNLOADS_PATH" \
        "$DOWNLOADS_PATH/media" \
        "$DOWNLOADS_PATH/media/movies" \
        "$DOWNLOADS_PATH/media/series" \
        "$DOWNLOADS_PATH/.unpackerr"; do
        mkdir -p "$d"
    done
    ensure_downloads_tree "$DOWNLOADS_PATH" "$DOWNLOADS_UID" "$DOWNLOADS_GID"
    log INFO "Downloads sahibi ${DOWNLOADS_UID}:${DOWNLOADS_GID} (sapma düzeltildi; Transmission/FileBrowser/Unpackerr R/W)"
}

stage_4() {
    log INFO "Aşama 4/7 — Docker ve şablonlar"
    install_docker_repo
    if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 || "$OS_CHANGED" -eq 1 ]]; then
        retry "apt-update-docker" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
    else
        log INFO "docker.sources aynı; apt-get update atlandı (stage_1 zaten günceldi)"
    fi
    # daemon.json paket kurulumundan ÖNCE (DD-110): docker-ce'nin postinst'i
    # dockerd'yi hemen başlatır. Sonra yazılan ayar bir sonraki restart'a kadar
    # okunmaz — sıfırdan kurulumda aşama 7'nin konteynerleri dns/log ayarını
    # hiç almıyordu (ölçüldü: dockerd 23:09:43, daemon.json 23:09:45). DD-18'deki
    # Tailscale netbuf tabanıyla aynı kalıp; hiçbir docker paketi bu dosyayı
    # sahiplenmez, dolayısıyla kurulum onu ezmez.
    local docker_was_active=0
    systemctl is-active --quiet docker 2>/dev/null && docker_was_active=1
    mkdir -p /etc/docker
    merge_docker_daemon_config
    if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 && "$docker_was_active" -eq 1 ]]; then
        log INFO "daemon.json değişti ama dockerd zaten çalışıyor; daemon düzeyindeki ayarlar bir sonraki docker yeniden başlatmasında okunur (proje konteynerlerinin log ayarı compose'ta — DD-110)"
    fi
    retry "apt-docker" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ensure_dozzle_users
    ensure_transmission_files

    mkdir -p "$COMPOSE_DIR"
    COMPOSE_NEEDS_UP=0
    render_template "$V2_ROOT/templates/compose.yaml" "$COMPOSE_DIR/compose.yaml" 0600 \
        DOZZLE_IMAGE="$DOZZLE_IMAGE" \
        FILEBROWSER_IMAGE="$FILEBROWSER_IMAGE" \
        TRANSMISSION_IMAGE="$TRANSMISSION_IMAGE" \
        UNPACKERR_IMAGE="$UNPACKERR_IMAGE" \
        RCLONE_IMAGE="$RCLONE_IMAGE" \
        DOZZLE_UI_PORT="$DOZZLE_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT" \
        TORRENT_PUBLIC_PORT="$TORRENT_PUBLIC_PORT" \
        WEBDAV_PORT="$WEBDAV_PORT" \
        WEBDAV_HTPASSWD_FILE="$WEBDAV_HTPASSWD_FILE" \
        DOWNLOADS_PATH="$DOWNLOADS_PATH" \
        DOWNLOADS_UID="$DOWNLOADS_UID" \
        DOWNLOADS_GID="$DOWNLOADS_GID" \
        FILEBROWSER_DATA_DIR="$FILEBROWSER_DATA_DIR" \
        DOZZLE_DATA_DIR="$DOZZLE_DATA_DIR" \
        TRANSMISSION_DATA_DIR="$TRANSMISSION_DATA_DIR" \
        TRANSMISSION_AUTH_DIR="$TRANSMISSION_AUTH_DIR" \
        DOCKER_LOG_MAX_SIZE="$DOCKER_LOG_MAX_SIZE" \
        DOCKER_LOG_MAX_FILE="$DOCKER_LOG_MAX_FILE" \
        TIMEZONE="$TIMEZONE"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && COMPOSE_NEEDS_UP=1
    # Render'ı aktifleştirmeden önce doğrula (DD-106): şema hatası pull/up
    # yerine burada, kendi mesajıyla düşsün. Aşama 7'deki `config --services`
    # zaten örtük doğrulardı ama iki aşama sonra ve pull'dan sonraydı.
    (cd "$COMPOSE_DIR" && docker compose config -q) ||
        die "compose.yaml doğrulanamadı: $COMPOSE_DIR/compose.yaml"

    if [[ "$PULL_IMAGES" -eq 1 ]]; then
        # Fail-closed disk kapısı (DD-101): yarıda kalan bir pull disk-dolu
        # durumunda çalışan konteynerleri de etkileyebilir; eşik altındaysa
        # hiç başlama. Ölçüm imajların yaşadığı dosya sisteminden alınır.
        local pull_free_kb pull_min_kb
        pull_free_kb="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}')"
        [[ "$pull_free_kb" =~ ^[0-9]+$ ]] ||
            die "disk boş alanı okunamadı (/var/lib/docker)"
        pull_min_kb=$((PULL_MIN_FREE_GB * 1024 * 1024))
        [[ "$pull_free_kb" -ge "$pull_min_kb" ]] ||
            die "imaj pull için boş alan yetersiz: $((pull_free_kb / 1024 / 1024)) GiB < ${PULL_MIN_FREE_GB} GiB (/var/lib/docker)"
        log INFO "docker compose pull (imajlar güncelleniyor; boş alan $((pull_free_kb / 1024 / 1024)) GiB)"
        (cd "$COMPOSE_DIR" && docker compose pull) || die "docker compose pull başarısız"
        COMPOSE_NEEDS_UP=1
    fi

    ensure_filebrowser_data_dir
    ensure_filebrowser_account

    atomic_write "$SBIN_DIR/master-wg" 0755 <"$V2_ROOT/scripts/master-wg"
    atomic_write "$SBIN_DIR/master-firewall" 0755 <"$V2_ROOT/scripts/firewall.sh"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1
    atomic_write "$SBIN_DIR/refresh-tailnet-config" 0755 \
        <"$V2_ROOT/scripts/refresh-tailnet-config"
    atomic_write "$SBIN_DIR/wait-tailnet-addr" 0755 \
        <"$V2_ROOT/scripts/wait-tailnet-addr"

    atomic_write "$UNIT_DIR/master-firewall.service" 0644 \
        <"$V2_ROOT/systemd/master-firewall.service"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1
    mkdir -p "$UNIT_DIR/docker.service.d"
    atomic_write "$UNIT_DIR/docker.service.d/master-stack.conf" 0644 \
        <"$V2_ROOT/systemd/docker.service.d/master-stack.conf"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1
    atomic_write "$UNIT_DIR/refresh-tailnet-config.service" 0644 \
        <"$V2_ROOT/systemd/refresh-tailnet-config.service"
    atomic_write "$UNIT_DIR/refresh-tailnet-config.timer" 0644 \
        <"$V2_ROOT/systemd/refresh-tailnet-config.timer"
    systemctl daemon-reload
}

stage_5() {
    log INFO "Aşama 5/7 — firewall (WebDAV Compose'ta)"
    [[ -f "$WEBDAV_HTPASSWD_FILE" ]] || die "WebDAV htpasswd yok: $WEBDAV_HTPASSWD_FILE"
    chown root:root "$WEBDAV_HTPASSWD_FILE"
    chmod 0600 "$WEBDAV_HTPASSWD_FILE"

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
    ensure_wireguard
}

apt_get_install_masked_quiet() {
    local tmp rc=0 line
    tmp="$(mktemp)"
    set +e
    apt-get "${APT_OPTS[@]}" install -y "$@" >"$tmp" 2>&1
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

stage_6() {
    log INFO "Aşama 6/7 — dnsmasq ve Caddy"
    local need_pkg=0
    dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed' || need_pkg=1
    dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q 'install ok installed' || need_pkg=1

    if [[ "$need_pkg" -eq 1 ]]; then
        systemctl stop dnsmasq caddy 2>/dev/null || true
        systemctl mask dnsmasq.service caddy.service >/dev/null 2>&1 || true
        # OS-DIVERGENCE: caddy-keyring-pkg (debian) — ağaçtaki TEK gerçek
        # "if OS = debian" dallanması [DD-102]
        # debian-keyring yalnız Debian'da: Caddy'nin resmi kurulum setinden;
        # Ubuntu'da işlevi yok (imza doğrulaması cloudsmith keyring'iyle).
        local -a dns_pkgs=(dnsmasq)
        [[ "$OS_ID" == "debian" ]] && dns_pkgs+=(debian-keyring)
        retry "apt-dns-caddy" 2 "$APT_LOCK_TIMEOUT" -- \
            apt_get_install_masked_quiet "${dns_pkgs[@]}"
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            retry "caddy-gpg" 3 60 -- curl -1sLf \
                'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
                gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            atomic_write /etc/apt/sources.list.d/caddy-stable.list 0644 <<'EOF'
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
            retry "apt-update-caddy" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
        fi
        retry "apt-caddy" 2 "$APT_LOCK_TIMEOUT" -- apt_get_install_masked_quiet caddy
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
        DOZZLE_UI_PORT="$DOZZLE_UI_PORT" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1
    # {$WEBDAV_PORT} Caddyfile'da sabit değil; state.env değişince yeniden başlat.
    [[ "${WEBDAV_PORT_CHANGED:-0}" -eq 1 ]] && caddy_changed=1
    # Caddy env yer tutucularını çalışma anında çözer; boş ortamla doğrulamak
    # `http://:` gibi anlamsız bir siteyi geçerli sayardı — gerçek değerlerle
    # doğrula (DD-106). Çıktı normalde JSON log satırları; hata satırını süz,
    # bulunamazsa son satırı göster.
    if ! validate_out="$(
        TAILSCALE_IPV4="$TAILSCALE_IPV4" WEBDAV_PORT="$WEBDAV_PORT" \
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
    if [[ "$dnsmasq_changed" -eq 1 ]] || ! systemctl is-active --quiet dnsmasq; then
        systemctl restart dnsmasq
    else
        log INFO "dnsmasq yapılandırması aynı; yeniden başlatılmadı"
    fi
    # Infuse: Caddy ${TS_IPV4}:${WEBDAV_PORT}. Eski Compose TS publish (v2-65)
    # hâlâ o soketi tutuyorsa Caddy bind edemez — önce webdav'ı yeni
    # (loopback-only) compose ile yeniden yarat.
    if docker port webdav 2>/dev/null |
        grep -q "${TAILSCALE_IPV4}:${WEBDAV_PORT}"; then
        log INFO "WebDAV Tailscale publish bırakılıyor (Infuse portu Caddy'ye)"
        (cd "$COMPOSE_DIR" && docker compose up -d webdav)
    fi
    if [[ "$caddy_changed" -eq 1 ]] || ! systemctl is-active --quiet caddy; then
        systemctl restart caddy
    else
        log INFO "Caddy yapılandırması aynı; yeniden başlatılmadı"
    fi
    ensure_caddy_wg "$OS_CHANGED"
}

# DD-120: WireGuard istemcilerinin arayüzlere eriştiği ikinci Caddy. Yalnız
# WireGuard adresinde IP:port dinler; Tailscale'e bağlı değildir, wg-quick
# ile birlikte kalkar ve iner. Tailnet Caddy'sine ve refresh'e dokunmaz.
ensure_caddy_wg() {
    local changed="${1:-0}" validate_out
    render_template "$V2_ROOT/templates/Caddyfile.wg" "$CADDY_WG_FILE" 0644 \
        WG_SERVER_IPV4="$WG_SERVER_IPV4" \
        DOZZLE_UI_PORT="$DOZZLE_UI_PORT" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    if ! validate_out="$(caddy validate --config "$CADDY_WG_FILE" --adapter caddyfile 2>&1)"; then
        die "Caddyfile.wg geçersiz ($CADDY_WG_FILE): $(
            grep -i -m1 'error' <<<"$validate_out" || tail -n1 <<<"$validate_out"
        )"
    fi
    render_template "$V2_ROOT/systemd/caddy-wg.service" "$UNIT_DIR/caddy-wg.service" 0644 \
        WG_INTERFACE="$WG_INTERFACE" \
        CADDY_WG_FILE="$CADDY_WG_FILE"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet caddy-wg.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet caddy-wg.service; then
        systemctl restart caddy-wg.service
    else
        log INFO "caddy-wg yapılandırması aynı; yeniden başlatılmadı"
    fi
}

assert_webdav_readonly_runtime() {
    local cmd rootfs mounts
    cmd="$(docker inspect webdav --format '{{json .Config.Cmd}}' 2>/dev/null || true)"
    [[ "$cmd" == *"--read-only"* ]] ||
        die "WebDAV komutunda --read-only yok"

    rootfs="$(
        docker inspect webdav --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || true
    )"
    [[ "$rootfs" == "true" ]] ||
        die "WebDAV root filesystem read-only değil (ReadonlyRootfs=$rootfs)"

    mounts="$(
        docker inspect webdav --format \
            '{{range .Mounts}}{{println .Destination .RW}}{{end}}' 2>/dev/null || true
    )"
    grep -qx '/downloads false' <<<"$mounts" ||
        die "WebDAV /downloads mount RW=false değil"
}

assert_webdav_network() {
    local nets count
    nets="$(
        docker inspect webdav --format \
            '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
            2>/dev/null || true
    )"
    grep -qx 'webdav' <<<"$nets" || die "webdav konteyneri webdav ağına bağlı değil"
    count="$(grep -c . <<<"$nets" || true)"
    [[ "$count" -eq 1 ]] || die "webdav beklenmeyen ağlar: $(tr '\n' ' ' <<<"$nets")"
}

wait_webdav_healthy() {
    local attempt status
    for attempt in $(seq 1 36); do
        status="$(
            docker inspect webdav --format \
                '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                2>/dev/null || echo missing
        )"
        [[ "$status" == "healthy" ]] && return 0
        sleep 2
    done
    die "webdav healthcheck hazır değil (son durum: ${status:-unknown}; deneme=${attempt:-0})"
}

stage_7() {
    log INFO "Aşama 7/7 — doğrulama"
    local need_up="$COMPOSE_NEEDS_UP" running=0 expected
    expected="$(
        (cd "$COMPOSE_DIR" && docker compose config --services) | grep -c .
    )" || die "compose servis sayısı okunamadı"
    if [[ "$need_up" -eq 0 ]]; then
        running="$(
            (cd "$COMPOSE_DIR" && docker compose ps --status running -q 2>/dev/null || true) |
                wc -l | tr -d ' '
        )"
        [[ "$running" =~ ^[0-9]+$ ]] || running=0
        if [[ "$running" -lt "$expected" ]]; then
            need_up=1
        fi
    fi
    if [[ "$need_up" -eq 1 ]]; then
        (cd "$COMPOSE_DIR" && docker compose up -d)
    else
        log INFO "Compose dosyası aynı ve konteynerler ayakta; up atlandı"
    fi
    if [[ "$PULL_IMAGES" -eq 1 ]]; then
        log INFO "docker image prune (eski imaj katmanları temizleniyor)"
        docker image prune -f >/dev/null || log WARN "docker image prune başarısız (yok sayıldı)"
    fi
    wait_webdav_healthy
    assert_webdav_network
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

    local name resolver ans dig_out code health line svc
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

    # Contract §14.13 — dört UI sitesi Caddy üzerinden non-5xx (DD-88).
    local ui_host ui_code
    for ui_host in dozzle torrent file; do
        ui_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Host: ${ui_host}.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
        [[ "$ui_code" =~ ^[1-4][0-9][0-9]$ ]] ||
            die "Caddy ${ui_host}.${LOCAL_DOMAIN}: HTTP '${ui_code}' (non-5xx beklenir)"
    done

    # DD-116: Dozzle docker.sock'a erişir; giriş zorunlu olmalı (fail-closed).
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: dozzle.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/api/events/stream" || true)"
    [[ "$code" == "401" ]] ||
        die "Dozzle API girişsiz yanıt $code verdi (beklenen 401)"
    # DD-117: Transmission girişi zorunlu olmalı (imaj kimlik yoksa girişi kapatır).
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: torrent.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/transmission/rpc" || true)"
    [[ "$code" == "401" ]] ||
        die "Transmission RPC girişsiz yanıt $code verdi (beklenen 401)"
    # DD-96: kurulum eski Portainer'ı silmez; hâlâ çalışıyorsa söyler.
    if docker inspect -f '{{.State.Running}}' portainer 2>/dev/null | grep -qx true; then
        log WARN "Portainer artık kurulumun parçası değil (DD-116) ama çalışıyor ve docker.sock'a erişiyor; kaldırmak için: docker rm -f portainer (verisi: docker volume rm docker_portainer_data)"
    fi

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:${WEBDAV_PORT}/" || true)"
    [[ "$code" == "401" ]] || die "WebDAV loopback kimlik doğrulamasız yanıt $code (beklenen 401)"

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: webdav.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
    [[ "$code" == "401" ]] ||
        die "WebDAV Caddy üzerinden kimlik doğrulamasız yanıt $code (beklenen 401)"

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/" || true)"
    [[ "$code" == "401" ]] ||
        die "WebDAV Caddy TS-IP:${WEBDAV_PORT} kimlik doğrulamasız yanıt $code (beklenen 401)"

    assert_webdav_readonly_runtime

    (cd "$COMPOSE_DIR" && docker port transmission) 2>/dev/null |
        grep -q "${TORRENT_PUBLIC_PORT}/tcp" ||
        die "transmission public TCP ${TORRENT_PUBLIC_PORT} publish yok"
    (cd "$COMPOSE_DIR" && docker port transmission) 2>/dev/null |
        grep -q "${TORRENT_PUBLIC_PORT}/udp" ||
        die "transmission public UDP ${TORRENT_PUBLIC_PORT} publish yok"

    for svc in dozzle filebrowser webdav; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            [[ "$line" == *127.0.0.1:* ]] ||
                die "UI publish yalnız loopback olmalı: $svc ($line)"
        done < <((cd "$COMPOSE_DIR" && docker port "$svc") 2>/dev/null || true)
    done
    (cd "$COMPOSE_DIR" && docker port webdav) 2>/dev/null |
        grep -q "127.0.0.1:${WEBDAV_PORT}" ||
        die "webdav loopback publish ${WEBDAV_PORT} yok"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *"${TORRENT_PUBLIC_PORT}/"* ]] && continue
        [[ "$line" == *127.0.0.1:* ]] ||
            die "Transmission UI publish yalnız loopback olmalı ($line)"
    done < <((cd "$COMPOSE_DIR" && docker port transmission) 2>/dev/null || true)

    # DD-120: WireGuard ayakta, girdi profilleri kadar peer, arayüzler WireGuard
    # adresinde caddy-wg'den non-5xx.
    local wg_port wg_ui_port
    wg_port="$(wg show "$WG_INTERFACE" listen-port 2>/dev/null || true)"
    [[ "$wg_port" == "$WG_PUBLIC_PORT" ]] ||
        die "WireGuard $WG_INTERFACE dinleme portu '${wg_port}' (beklenen $WG_PUBLIC_PORT)"
    WG_PEER_COUNT="$(wg show "$WG_INTERFACE" peers 2>/dev/null | grep -c . || true)"
    "$SBIN_DIR/master-wg" version >/dev/null ||
        die "master-wg çalışmıyor ($SBIN_DIR/master-wg)"
    ip -4 -o addr show dev "$WG_INTERFACE" 2>/dev/null | grep -q " ${WG_SERVER_IPV4}/" ||
        die "WireGuard $WG_INTERFACE üzerinde $WG_SERVER_IPV4 yok"
    for wg_ui_port in "$DOZZLE_UI_PORT" "$TORRENT_UI_PORT" "$FILEBROWSER_UI_PORT"; do
        ui_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://${WG_SERVER_IPV4}:${wg_ui_port}/" || true)"
        [[ "$ui_code" =~ ^[1-4][0-9][0-9]$ ]] ||
            die "caddy-wg ${WG_SERVER_IPV4}:${wg_ui_port}: HTTP '${ui_code}' (non-5xx beklenir)"
    done

    log INFO "Temel doğrulamalar geçti"
}

print_summary() {
    log INFO "Kurulum tamam — v$V2_VERSION"
    cat <<EOF

WAN:          $WAN_INTERFACE $WAN_IPV4
Tailscale:    $TAILSCALE_IPV4 ${TAILSCALE_IPV6:-"(IPv6 yok)"}
Domain:       $LOCAL_DOMAIN
Downloads:    $DOWNLOADS_PATH
WireGuard:    ${WG_INTERFACE} UDP ${WG_PUBLIC_PORT}, ${WG_PEER_COUNT:-0} peer (endpoint: $WG_ENDPOINT_HOST)
Torrent peer: ${TORRENT_PUBLIC_PORT}/tcp+udp
Compose:      $COMPOSE_DIR/compose.yaml
State:        $STATE_FILE
Log:          $V2_LOG_FILE

Manuel Tailscale Admin:
  1) DNS → Nameservers → Custom: $TAILSCALE_IPV4
  2) Restrict to domain: $LOCAL_DOMAIN
  3) Exit node olarak bu makineyi onayla

Dozzle: http://dozzle.${LOCAL_DOMAIN} (durum, loglar, başlat/durdur/sil)
Transmission: http://torrent.${LOCAL_DOMAIN} (kurulumda verilen kullanıcı/parola)
WebDAV: http://webdav.${LOCAL_DOMAIN} (MagicDNS)
  Infuse: http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/ (Caddy → loopback; Compose'a IP yok)
WireGuard üzerinden arayüzler (yalnız IP:port; tailnet ve WebDAV kapalı):
  Dozzle http://${WG_SERVER_IPV4}:${DOZZLE_UI_PORT}  Transmission http://${WG_SERVER_IPV4}:${TORRENT_UI_PORT}  FileBrowser http://${WG_SERVER_IPV4}:${FILEBROWSER_UI_PORT}
  Peer eklemek/çıkarmak, QR: Mac'te wireguard.command (peer sunucuda üretilir, profil kurulum/wireguard'a alınır)
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
