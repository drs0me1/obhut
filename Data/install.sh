#!/usr/bin/env bash
# Kurulum — Debian 13 / Ubuntu 24.04 / 26.04 LTS, doğrusal aşamalar,
# tekrar çalıştırılabilir.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

V2_VERSION="2026.08.06-v2-113"
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
COMPOSE_NEEDS_UP=1
FIREWALL_NEEDS_RESTART=0
PULL_IMAGES=0
# state.env'de kayıtlı OS kimliği canlı os-release ile uyuşmuyorsa 1 olur;
# OS'a bağlı adımlar dosya içeriği aynı kalsa bile yeniden uygulanır (DD-104).
OS_CHANGED=0
# Ubuntu'da unattended-upgrades varsayılan açık: apt kilidi dakikalarca
# tutulabilir. Kilitte hemen düşmek yerine bekle; retry üstte ayrıca sarar.
# Kurulumun indirdiği .deb'ler kurulduktan sonra önbellekte bırakılmaz
# (~300 MB; DD-125). Başkasının önbelleğe koyduğu dosyaya dokunulmaz.
APT_OPTS=(-o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false)
# DD-119: kurulum girdi dosyasının alanları (şablon: config/kurulum.env.example).
# Hepsi dosyada yazılı olmalı; INPUT_NONEMPTY_KEYS boş da olamaz. Boş alan adı
# defaults.env varsayılanını alır; boş TS_AUTH_KEY tarayıcıdan giriş demektir.
# SSH_HOST'u yalnız launcher okur. Kullanıcı alanı sorulmaz: SERVER_ROOT sabittir (DD-144).
INPUT_KEYS="SSH_HOST LOCAL_DOMAIN DOZZLE_USER DOZZLE_PASS FILEBROWSER_USER FILEBROWSER_PASS TORRENT_USER TORRENT_PASS WG_PANEL_USER WG_PANEL_PASS SHARE_USER SHARE_PASS TS_AUTH_KEY"
INPUT_NONEMPTY_KEYS="DOZZLE_USER DOZZLE_PASS FILEBROWSER_USER FILEBROWSER_PASS TORRENT_USER TORRENT_PASS WG_PANEL_USER WG_PANEL_PASS SHARE_USER SHARE_PASS"

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
TORRENT_PUBLIC_PORT=$TORRENT_PUBLIC_PORT
SSH_PUBLIC_PORT=$SSH_PUBLIC_PORT
CHAIN_INPUT=$CHAIN_INPUT
CHAIN_DOCKER=$CHAIN_DOCKER
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
FILES_PANEL_PORT=$FILES_PANEL_PORT
SHARE_PORT=$SHARE_PORT
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

# DD-124/DD-143: WireGuard'ın kaynağı sunucudaki kayıt ve wgN.conf dosyalarıdır.
# Kurulum hiçbirini yaratmaz, silmez ya da içeriğine dokunmaz; ağları master-wg
# (Konsol ya da wireguard.command) kurar. NAT ve FORWARD master-firewall'dadır
# (DD-16/DD-17): PostUp yok. Firewall'dan sonra çağrılır.
# DD-143: kurulum WireGuard ağı yaratmaz. Yalnız katmanı hazırlar: araçlar, çekirdek
# modülü ve /etc/wireguard. İlk ağı da sonrakileri de Konsol (master-wg net-add) kurar;
# böylece tek bir yaratma yolu vardır ve kurulum hiçbir anahtara dokunmaz.
ensure_wireguard_ready() {
    # Kernel modülü çekirdekte; öneriler wireguard-dkms çekebilirdi.
    retry "apt-wireguard" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        --no-install-recommends wireguard-tools qrencode
    modprobe wireguard 2>/dev/null ||
        log WARN "modprobe wireguard başarısız; çekirdek desteği yoksa ağ açılmaz"
    atomic_write "$WG_MODULES_LOAD_FILE" 0644 <<<"wireguard"
    install -d -m 0700 -o root -g root "$WG_CONF_DIR"
}

# Kayıttaki ağlar açılışta ve her çalıştırmada ayakta olmalı; kurulum yalnız onları
# uygular, hiçbirini yaratmaz ya da silmez.
ensure_wg_networks_running() {
    local iface scope rest count=0
    [[ -n "${WG_NETWORKS_FILE:-}" && -f "$WG_NETWORKS_FILE" ]] || {
        log INFO "WireGuard ağı yok; Konsol'da WireGuard sayfasından Yapılandır ile oluşturun"
        return 0
    }
    while IFS=$'\t' read -r iface _ scope rest; do
        [[ "$iface" =~ ^wg[0-9]$ ]] || continue
        count=$((count + 1))
        systemctl enable --quiet "wg-quick@${iface}.service"
        systemctl is-active --quiet "wg-quick@${iface}.service" ||
            systemctl restart "wg-quick@${iface}.service" ||
            log WARN "${iface} başlatılamadı"
        if [[ "$scope" == ui ]]; then
            systemctl enable --quiet "caddy-wg@${iface}.service"
            systemctl is-active --quiet "caddy-wg@${iface}.service" ||
                systemctl restart "caddy-wg@${iface}.service" ||
                log WARN "caddy-wg@${iface} başlatılamadı"
        fi
    done <"$WG_NETWORKS_FILE"
    if [[ "$count" -eq 0 ]]; then
        log INFO "WireGuard ağı yok; Konsol'da WireGuard sayfasından Yapılandır ile oluşturun"
    else
        log INFO "WireGuard: kayıttaki $count ağ uygulandı"
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

    # DD-119: dosya tek doğru kaynak. Hesaplar her çalıştırmada kayıtlı olanla
    # karşılaştırılır; farklıysa aşama 1 (WebDAV) ve 4 (Dozzle, FileBrowser,
    # qBittorrent) günceller. Parolalar yalnız bellekte durur.
    # DD-116: Dozzle parolası aşama 4'te imajın kendi aracına stdin'den gider.
    DOZZLE_NEW_USER="$INPUT_DOZZLE_USER"
    DOZZLE_NEW_PASS="$INPUT_DOZZLE_PASS"
    validate_account Dozzle "$DOZZLE_NEW_USER" "$DOZZLE_NEW_PASS" \
        '^[a-z][a-z0-9_-]{0,31}$' "$DOZZLE_MIN_PASSWORD_LENGTH"
    # DD-129: qBittorrent hesabı; parola sunucuya yalnız qBittorrent'in PBKDF2
    # özeti olarak gider.
    TORRENT_NEW_USER="$INPUT_TORRENT_USER"
    TORRENT_NEW_PASS="$INPUT_TORRENT_PASS"
    validate_account qBittorrent "$TORRENT_NEW_USER" "$TORRENT_NEW_PASS" \
        '^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$' "$TORRENT_MIN_PASSWORD_LENGTH"
    # DD-118: FileBrowser hesabı; arayüzden değiştirilen parola dosyadakine döner.
    FILEBROWSER_NEW_USER="$INPUT_FILEBROWSER_USER"
    FILEBROWSER_NEW_PASS="$INPUT_FILEBROWSER_PASS"
    validate_account FileBrowser "$FILEBROWSER_NEW_USER" "$FILEBROWSER_NEW_PASS" \
        '^[a-z][a-z0-9_-]{0,31}$' "$FILEBROWSER_MIN_PASSWORD_LENGTH"
    # DD-133: WireGuard paneli hesabı; parola sunucuya yalnız PBKDF2 özeti olarak gider.
    WG_PANEL_NEW_USER="$INPUT_WG_PANEL_USER"
    WG_PANEL_NEW_PASS="$INPUT_WG_PANEL_PASS"
    validate_account "WireGuard paneli" "$WG_PANEL_NEW_USER" "$WG_PANEL_NEW_PASS" \
        '^[a-z][a-z0-9_-]{0,31}$' "$WG_PANEL_MIN_PASSWORD_LENGTH"
    # DD-141: paylaşım WebDAV'ı; bütün paylaşımlar bu tek hesapla açılır.
    SHARE_NEW_USER="$INPUT_SHARE_USER"
    SHARE_NEW_PASS="$INPUT_SHARE_PASS"
    validate_account "Paylaşım" "$SHARE_NEW_USER" "$SHARE_NEW_PASS" \
        '^[a-z][a-z0-9._-]{0,31}$' "$SHARE_MIN_PASSWORD_LENGTH"

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
  Kullanıcı alanı: $SERVER_ROOT (sabit; indirmeler $DOWNLOADS_PATH)
  WireGuard:     ağı Konsol kurar (kurulum ağ yaratmaz; DD-143)
  Hesaplar:      Dozzle $DOZZLE_NEW_USER, FileBrowser $FILEBROWSER_NEW_USER, qBittorrent $TORRENT_NEW_USER,
                 Konsol $WG_PANEL_NEW_USER, paylaşım $SHARE_NEW_USER
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
        apache2-utils dnsutils unattended-upgrades python3
    # Artık binary kesin var: arka uç denetimi burada zorunlu (DD-108).
    check_nft_iptables required
    timedatectl set-timezone "$TIMEZONE" || log WARN "saat dilimi ayarlanamadı"
    apply_unattended_upgrades

    ensure_share_account
}

# DD-119: htpasswd tek satırda dosyadaki hesabı taşıyorsa dokunulmaz; değilse
# yeniden yazılır ve çalışan konteyner yeniden başlatılır (secret bir bind mount:
# `mv` sonrası konteyner eski dosyayı görür). Parola stdin'den gider.
# DD-141: paylaşım hesabı iki dosyaya yazılır: rclone'un okuduğu htpasswd (bcrypt) ve
# Konsol'un gösterip kopyalattığı düz metin kopya (root'a özel, dosya arka ucuna yalnız
# systemd kimlik bilgisi olarak açılır). İkisi de aynı girdiden gelir, ayrışamazlar.
ensure_share_account() {
    local tmp
    [[ -n "${SHARE_NEW_PASS:-}" ]] || return 0
    if [[ -f "$SHARE_HTPASSWD_FILE" && "$(wc -l <"$SHARE_HTPASSWD_FILE")" -eq 1 ]] &&
        printf '%s' "$SHARE_NEW_PASS" |
        htpasswd -vi "$SHARE_HTPASSWD_FILE" "$SHARE_NEW_USER" >/dev/null 2>&1 &&
        [[ -f "$SHARE_CRED_FILE" && "$(cat "$SHARE_CRED_FILE")" == "${SHARE_NEW_USER}:${SHARE_NEW_PASS}" ]]; then
        log INFO "Paylaşım hesabı girdi dosyasıyla aynı; dokunulmadı"
    else
        tmp="$(mktemp "$STATE_DIR/.paylasim-XXXXXX")"
        printf '%s' "$SHARE_NEW_PASS" | htpasswd -i -B "$tmp" "$SHARE_NEW_USER"
        chmod 0600 "$tmp"
        chown root:root "$tmp"
        mv -f "$tmp" "$SHARE_HTPASSWD_FILE"
        tmp="$(mktemp "$STATE_DIR/.paylasim-XXXXXX")"
        printf '%s:%s\n' "$SHARE_NEW_USER" "$SHARE_NEW_PASS" >"$tmp"
        chmod 0600 "$tmp"
        chown root:root "$tmp"
        mv -f "$tmp" "$SHARE_CRED_FILE"
        log INFO "Paylaşım hesabı yazıldı: $SHARE_HTPASSWD_FILE ($SHARE_NEW_USER)"
        SHARE_ACCOUNT_CHANGED=1
        if docker inspect paylasim >/dev/null 2>&1; then
            docker restart paylasim >/dev/null || log WARN "paylasim yeniden başlatılamadı; yeni hesap bir sonraki açılışta geçerli"
        fi
    fi
    unset SHARE_NEW_PASS
    SHARE_NEW_USER=""
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

# DD-129: /config bind. qBittorrent.conf, templates/qBittorrent.conf'taki
# anahtarlar ve kurulum.env hesabıyla eşitlenir; qBittorrent'in kendi eklediği
# anahtarlar olduğu gibi kalır. Portları imaj her açılışta komut satırından verir.
ensure_qbittorrent_dir() {
    install -d -m 0750 -o "$DOWNLOADS_UID" -g "$DOWNLOADS_GID" "$QBITTORRENT_DATA_DIR"
}

# qBittorrent'in WebUI parola özeti: PBKDF2-HMAC-SHA512, 100000 tur, 16 bayt
# tuz, 64 bayt özet, "@ByteArray(tuz:özet)" (base64, tırnaklı). Parola stdin'den
# okunur. Argüman verilirse o özeti doğrular (0 eşleşir, 1 eşleşmez, 2 biçim
# bozuk); özet python'a ortamdan gider, argv'de görünmez. Argümansız yeni özet
# yazar.
qbit_pbkdf2() {
    QB_EXISTING="${1:-}" python3 -c '
import base64, binascii, hashlib, hmac, os, sys
pw = sys.stdin.buffer.read()
cur = os.environ.get("QB_EXISTING", "")
if cur:
    inner = cur[1:-1] if len(cur) > 1 and cur[0] == cur[-1] == "\"" else cur
    if not (inner.startswith("@ByteArray(") and inner.endswith(")")):
        sys.exit(2)
    salt, sep, want = inner[len("@ByteArray("):-1].partition(":")
    try:
        salt = base64.b64decode(salt, validate=True)
        want = base64.b64decode(want, validate=True)
    except (binascii.Error, ValueError):
        sys.exit(2)
    if not sep or not salt or not want:
        sys.exit(2)
    got = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, len(want))
    sys.exit(0 if hmac.compare_digest(got, want) else 1)
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
sys.stdout.write("\"@ByteArray(%s:%s)\"\n" % (base64.b64encode(salt).decode(), base64.b64encode(key).decode()))
'
}

# INI → "[bölüm]<TAB>anahtar=değer". qBittorrent anahtarları ters eğik çizgi
# içerir, değerler '=' içerebilir: yalnız ilk '=' ayırır. Yorum ve boş satır atlanır.
qbit_conf_flatten() {
    awk '/^\[[^]]*\]$/ {s = $0; next} /^[^#;]/ && index($0, "=") > 1 {print s "\t" $0}' "$@"
}

# stdin: istenen düz liste; $1: canlı dosya. Değeri farklı ya da eksik olan
# anahtarları "[bölüm] anahtar" olarak yazar (değer yazmaz).
qbit_conf_diff() {
    awk -F'\t' '
        FNR == NR { k = $1 "\t" substr($2, 1, index($2, "=") - 1); want[k] = $2; order[++n] = k; next }
        /^\[[^]]*\]$/ { s = $0; next }
        index($0, "=") > 1 {
            k = s "\t" substr($0, 1, index($0, "=") - 1)
            if ((k in want) && !(k in have)) have[k] = $0
        }
        END {
            for (i = 1; i <= n; i++)
                if (have[order[i]] != want[order[i]]) { split(order[i], p, "\t"); print p[1] " " p[2] }
        }
    ' - "$1"
}

# stdin: istenen düz liste; $1: canlı dosya (yoksa /dev/null). Çıktı: istenen
# anahtarları kendi bölümünde yerinde değiştirilmiş, eksikleri bölüm sonuna,
# eksik bölümleri dosya sonuna eklenmiş dosya. Diğer satırlar aynen kalır;
# yönetilen bir anahtarın ikinci kopyası atılır.
qbit_conf_merge() {
    awk -F'\t' '
        function flush(sec,   list, m, i) {
            m = split(keys[sec], list, SUBSEP)
            for (i = 2; i <= m; i++)
                if (!(list[i] in done)) { print substr(want[list[i]], 1); done[list[i]] = 1 }
        }
        FNR == NR {
            k = $1 "\t" substr($2, 1, index($2, "=") - 1)
            if (!(k in want)) {
                want[k] = $2
                keys[$1] = keys[$1] SUBSEP k
                if (!($1 in known)) { known[$1] = 1; secs[++ns] = $1 }
            }
            next
        }
        /^[[:space:]]*$/ { blanks++; next }
        /^\[[^]]*\]$/ {
            if (s != "") flush(s)
            for (; blanks > 0; blanks--) print ""
            s = $0; present[s] = 1; print; next
        }
        {
            for (; blanks > 0; blanks--) print ""
            if (index($0, "=") > 1) {
                k = s "\t" substr($0, 1, index($0, "=") - 1)
                if (k in want) {
                    if (!(k in done)) { print want[k]; done[k] = 1 }
                    next
                }
            }
            print
        }
        END {
            if (s != "") flush(s)
            for (i = 1; i <= ns; i++) {
                if (secs[i] in present) continue
                if (printed++ || s != "") print ""
                print secs[i]
                flush(secs[i])
            }
        }
    ' - "$1"
}

# DD-129: qBittorrent.conf'u şablon + kurulum.env hesabıyla eşitler. Değişiklik
# yoksa dosyaya ve konteynere dokunulmaz. Parola özeti, mevcut özet aynı parolayı
# doğruluyorsa korunur (her çalıştırmada yeni tuz = sahte değişiklik olurdu).
# qBittorrent kapanırken dosyasını yazdığından değişiklik konteyner durunca yapılır.
sync_qbittorrent_config() {
    local conf="$QBITTORRENT_CONF_FILE" cur="" hash desired diff running merged rc=0
    install -d -m 0750 -o "$DOWNLOADS_UID" -g "$DOWNLOADS_GID" "$QBITTORRENT_DATA_DIR" "${conf%/*}"
    if [[ -f "$conf" ]]; then
        cur="$(awk 'index($0, "WebUI\\Password_PBKDF2=") == 1 {print substr($0, 23); exit}' "$conf")"
    fi
    if [[ -n "$cur" ]]; then
        printf '%s' "$TORRENT_NEW_PASS" | qbit_pbkdf2 "$cur" || rc=$?
    else
        rc=1
    fi
    if [[ "$rc" -eq 0 ]]; then
        hash="$cur"
    else
        hash="$(printf '%s' "$TORRENT_NEW_PASS" | qbit_pbkdf2)" ||
            die "qBittorrent parola özeti hesaplanamadı (python3)"
    fi
    desired="$(
        qbit_conf_flatten "$V2_ROOT/templates/qBittorrent.conf"
        printf '[Preferences]\tWebUI\\Username=%s\n' "$TORRENT_NEW_USER"
        printf '[Preferences]\tWebUI\\Password_PBKDF2=%s\n' "$hash"
    )"
    if [[ -f "$conf" ]]; then
        diff="$(qbit_conf_diff "$conf" <<<"$desired")"
        if [[ -z "$diff" ]]; then
            log INFO "qBittorrent ayarları ve hesabı şablonla aynı; dokunulmadı"
            hash="" desired="" cur=""
            return 0
        fi
    else
        diff="(yeni dosya)"
    fi
    running="$(docker inspect -f '{{.State.Running}}' qbittorrent 2>/dev/null || true)"
    [[ "$running" != "true" ]] || docker stop qbittorrent >/dev/null
    # Durunca qBittorrent dosyasını yeniden yazmış olabilir: birleştirme sonra.
    if [[ -f "$conf" ]]; then
        merged="$(qbit_conf_merge "$conf" <<<"$desired")"
    else
        merged="$(qbit_conf_merge /dev/null <<<"$desired")"
    fi
    atomic_write "$conf" 0600 <<<"$merged"
    chown "$DOWNLOADS_UID:$DOWNLOADS_GID" "$conf"
    log INFO "qBittorrent ayarları eşitlendi: $(paste -sd, - <<<"$diff" | sed 's/,/, /g')"
    [[ "$running" != "true" ]] || docker start qbittorrent >/dev/null
    hash="" desired="" cur="" merged=""
}

# DD-129: kurulum.env hesabıyla gerçekten giriş yapılabildiğini ve girişin
# atlanamadığını doğrular. Parola urlencode için python3'e, oradan curl'e
# stdin'den gider (argv'de görünmez). qBittorrent başarısız girişte istemci
# IP'sini yasakladığından yalnız "hazır değil" (000/5xx) beklenir; 401'de durulur.
qbit_login_check() {
    local jar code n=0 prefs
    jar="$(mktemp "$RUNTIME_DIR/qbit-cookie.XXXXXX")"
    while :; do
        code="$(printf '%s\n%s' "$TORRENT_NEW_USER" "$TORRENT_NEW_PASS" |
            python3 -c 'import sys, urllib.parse; u, p = sys.stdin.read().split("\n", 1); sys.stdout.write(urllib.parse.urlencode({"username": u, "password": p}))' |
            curl -s -o /dev/null -w '%{http_code}' --max-time 5 -c "$jar" --data @- \
                -H "Referer: http://127.0.0.1:${TORRENT_UI_PORT}" \
                "http://127.0.0.1:${TORRENT_UI_PORT}/api/v2/auth/login" || true)"
        case "$code" in 000 | 5??) ;; *) break ;; esac
        n=$((n + 1))
        [[ "$n" -lt 30 ]] || break
        sleep 1
    done
    # qBittorrent 5.2 başarılı girişte 204 döner (eskiler 200 "Ok."); asıl kanıt
    # oturum çerezidir.
    if [[ "$code" != "200" && "$code" != "204" ]] || ! grep -q 'SID' "$jar"; then
        rm -f -- "$jar"
        die "qBittorrent girişi kurulum.env hesabıyla başarısız (HTTP ${code})"
    fi
    prefs="$(curl -s --max-time 5 -b "$jar" "http://127.0.0.1:${TORRENT_UI_PORT}/api/v2/app/preferences" || true)"
    rm -f -- "$jar"
    jq -e --arg u "$TORRENT_NEW_USER" \
        '.web_ui_username == $u and .bypass_local_auth == false and .bypass_auth_subnet_whitelist_enabled == false' \
        >/dev/null <<<"$prefs" ||
        die "qBittorrent tercihleri beklenen gibi değil (kullanıcı adı ya da giriş atlama)"
    log INFO "qBittorrent girişi kurulum.env hesabıyla doğrulandı"
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
    # DD-144: kök kullanıcı alanı; indirme klasörü, kütüphane, çöp ve paylaşım kökü
    # kardeştir. Torrent istemcisi yalnız indirme klasörünü görür.
    for d in \
        "$SERVER_ROOT" \
        "$DOWNLOADS_PATH" \
        "$DOWNLOADS_PATH/.unpackerr" \
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
        log INFO "Downloads: $fixed girdinin sahibi ya da izni düzeltildi (${DOWNLOADS_UID}:${DOWNLOADS_GID}; qBittorrent/FileBrowser/Unpackerr R/W)"
    else
        log INFO "Downloads sahipliği ve izinleri yerinde (${DOWNLOADS_UID}:${DOWNLOADS_GID})"
    fi
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
    # Önerilen paketler olmadan (DD-125): stack imaj derlemez ve rootless
    # çalışmaz; buildx, git (+perl) ve rootless-extras ~200 MB yer tutuyordu.
    # docker-ce'nin önerilerinden çalışma zamanının kullandığı ikisi açıkça
    # yazılır: apparmor (çekirdekte AppArmor açıkken docker-default profili
    # için gerekir) ve pigz (katman açma).
    retry "apt-docker" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin apparmor pigz
    systemctl enable --now docker
    ensure_dozzle_users
    ensure_qbittorrent_dir
    sync_qbittorrent_config

    mkdir -p "$COMPOSE_DIR"
    COMPOSE_NEEDS_UP=0
    render_template "$V2_ROOT/templates/compose.yaml" "$COMPOSE_DIR/compose.yaml" 0600 \
        DOZZLE_IMAGE="$DOZZLE_IMAGE" \
        FILEBROWSER_IMAGE="$FILEBROWSER_IMAGE" \
        QBITTORRENT_IMAGE="$QBITTORRENT_IMAGE" \
        UNPACKERR_IMAGE="$UNPACKERR_IMAGE" \
        RCLONE_IMAGE="$RCLONE_IMAGE" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        SHARE_DIR="$SHARE_DIR" \
        SHARE_PORT="$SHARE_PORT" \
        SHARE_HTPASSWD_FILE="$SHARE_HTPASSWD_FILE" \
        DOZZLE_UI_PORT="$DOZZLE_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT" \
        TORRENT_PUBLIC_PORT="$TORRENT_PUBLIC_PORT" \
        SERVER_ROOT="$SERVER_ROOT" \
        DOWNLOADS_PATH="$DOWNLOADS_PATH" \
        DOWNLOADS_UID="$DOWNLOADS_UID" \
        DOWNLOADS_GID="$DOWNLOADS_GID" \
        FILEBROWSER_DATA_DIR="$FILEBROWSER_DATA_DIR" \
        DOZZLE_DATA_DIR="$DOZZLE_DATA_DIR" \
        QBITTORRENT_DATA_DIR="$QBITTORRENT_DATA_DIR" \
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
    log INFO "Aşama 5/7 — firewall (paylaşım WebDAV'ı Compose'ta)"
    [[ -f "$SHARE_HTPASSWD_FILE" ]] || die "Paylaşım htpasswd yok: $SHARE_HTPASSWD_FILE"
    chown root:root "$SHARE_HTPASSWD_FILE" "$SHARE_CRED_FILE"
    chmod 0600 "$SHARE_HTPASSWD_FILE" "$SHARE_CRED_FILE"

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
    ensure_wireguard_ready
    ensure_wg_networks_running
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
        DOZZLE_UI_PORT="$DOZZLE_UI_PORT" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT" \
        WG_PANEL_PORT="$WG_PANEL_PORT" \
        FILES_PANEL_PORT="$FILES_PANEL_PORT" \
        SHARE_PORT="$SHARE_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1
    # Caddy env yer tutucularını çalışma anında çözer; boş ortamla doğrulamak
    # `http://:` gibi anlamsız bir siteyi geçerli sayardı — gerçek değerlerle
    # doğrula (DD-106). Çıktı normalde JSON log satırları; hata satırını süz,
    # bulunamazsa son satırı göster.
    if ! validate_out="$(
        TAILSCALE_IPV4="$TAILSCALE_IPV4" SHARE_PORT="$SHARE_PORT" \
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
        DOZZLE_UI_PORT="$DOZZLE_UI_PORT" \
        TORRENT_UI_PORT="$TORRENT_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT"
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

# DD-133: WireGuard web paneli. 127.0.0.1:WG_PANEL_PORT dinler; tailnet'e Caddy
# açar (wg.LOCAL_DOMAIN). Hesap kurulum.env'den: özet root'a özel dosyada, panel
# dosya değişince kendisi yeniden okur. Sayfa dosyaları her istekte diskten okunur;
# yalnız betik ya da unit değişince servis yeniden başlar.
ensure_wg_panel() {
    local changed="${1:-0}" f out
    atomic_write "$SBIN_DIR/master-wg-panel" 0755 <"$V2_ROOT/panel/master-wg-panel"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    if [[ -n "${WG_PANEL_NEW_PASS:-}" ]]; then
        out="$(printf '%s' "$WG_PANEL_NEW_PASS" |
            python3 "$SBIN_DIR/master-wg-panel" account --auth "$WG_PANEL_AUTH_FILE" --user "$WG_PANEL_NEW_USER")" ||
            die "WireGuard paneli hesabı yazılamadı ($WG_PANEL_AUTH_FILE)"
        if [[ "$out" == "aynı" ]]; then
            log INFO "WireGuard paneli hesabı girdi dosyasıyla aynı; dokunulmadı"
        else
            log INFO "WireGuard paneli hesabı yazıldı: $WG_PANEL_AUTH_FILE ($WG_PANEL_NEW_USER)"
            # DD-139: dosya paneli hesabın kopyasını başlarken alır; yeniden başlaması gerekir.
            WG_PANEL_ACCOUNT_CHANGED=1
        fi
    fi
    [[ -f "$WG_PANEL_AUTH_FILE" ]] || die "WireGuard paneli hesabı yok: $WG_PANEL_AUTH_FILE"
    chown root:root "$WG_PANEL_AUTH_FILE"
    chmod 0600 "$WG_PANEL_AUTH_FILE"
    render_template "$V2_ROOT/systemd/master-wg-panel.service" "$UNIT_DIR/master-wg-panel.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        WG_PANEL_PORT="$WG_PANEL_PORT" \
        STATE_FILE="$STATE_FILE" \
        WG_PANEL_AUTH_FILE="$WG_PANEL_AUTH_FILE" \
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
# DOWNLOADS_UID olarak çalışır ve yalnız SERVER_ROOT'a yazar. Hesap WireGuard paneliyle
# aynıdır: root'a özel özet dosyası LoadCredential ile servisin kendi kopyasına gelir, bu
# yüzden hesap değişince panel yeniden başlar. qBittorrent'in yarım indirme klasörü
# şablondan okunur; panel orada taşıma/silme için uyarır.
ensure_files_panel() {
    local changed="${1:-0}" f temp_dir user group
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
    install -d -m 0755 "$CONSOLE_WEB_DIR"
    for f in index.html konsol.css konsol.js; do
        atomic_write "$CONSOLE_WEB_DIR/$f" 0644 <"$V2_ROOT/console/$f"
    done
    # qBittorrent'in geçici klasörü konteyner yoluyla yazılıdır; panel onu kullanıcı
    # alanının köküne göre bilir (DD-144): <indirme klasörü>/<geçici>.
    temp_dir="$(awk -F= '$1 == "Session\\TempPath" {print $2; exit}' "$V2_ROOT/templates/qBittorrent.conf")"
    temp_dir="${temp_dir#/downloads/}"
    temp_dir="${temp_dir%/}"
    if [[ "$temp_dir" =~ ^[A-Za-z0-9._-]+$ ]]; then
        temp_dir="$DOWNLOADS_SUBDIR/$temp_dir"
    else
        temp_dir=""
    fi
    render_template "$V2_ROOT/systemd/master-files-panel.service" "$UNIT_DIR/master-files-panel.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        FILES_PANEL_PORT="$FILES_PANEL_PORT" \
        CONSOLE_WEB_DIR="$CONSOLE_WEB_DIR" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        SHARE_DIR="$SHARE_DIR" \
        SHARE_CRED_FILE="$SHARE_CRED_FILE" \
        WG_PANEL_AUTH_FILE="$WG_PANEL_AUTH_FILE" \
        SERVER_ROOT="$SERVER_ROOT" \
        FILES_PANEL_USER="$user" \
        FILES_PANEL_GROUP="$group" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        V2_VERSION="$V2_VERSION" \
        QBITTORRENT_TEMP_DIR="$temp_dir"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    [[ "${WG_PANEL_ACCOUNT_CHANGED:-0}" -eq 1 ]] && changed=1
    [[ "${SHARE_ACCOUNT_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet master-files-panel.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet master-files-panel.service; then
        # Önceki bir çalıştırmada başlama sınırına takıldıysa yeniden denemeyi engellemesin.
        systemctl reset-failed master-files-panel.service 2>/dev/null || true
        systemctl restart master-files-panel.service
    else
        log INFO "Dosya paneli aynı; yeniden başlatılmadı"
    fi
}

# DD-142: sunucudaki tek WebDAV paylaşımdır; salt okunur ve kökü yalnız .pay/w.
assert_share_readonly_runtime() {
    local label="Paylaşım WebDAV'ı" cmd rootfs mounts
    cmd="$(docker inspect paylasim --format '{{json .Config.Cmd}}' 2>/dev/null || true)"
    [[ "$cmd" == *"--read-only"* ]] ||
        die "$label komutunda --read-only yok"

    rootfs="$(
        docker inspect paylasim --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || true
    )"
    [[ "$rootfs" == "true" ]] ||
        die "$label root filesystem read-only değil (ReadonlyRootfs=$rootfs)"

    mounts="$(
        docker inspect paylasim --format \
            '{{range .Mounts}}{{println .Destination .RW}}{{end}}' 2>/dev/null || true
    )"
    grep -qx "${SERVER_ROOT} false" <<<"$mounts" ||
        die "$label ${SERVER_ROOT} mount RW=false değil"
    # Paylaşım yalnız paylaşım kökünü sunar: kullanıcı alanının tamamı hiçbir yerde yayımlanmaz.
    [[ "$cmd" == *"${SERVER_ROOT}/${SHARE_DIR}/w"* ]] ||
        die "Paylaşım WebDAV'ının kökü ${SERVER_ROOT}/${SHARE_DIR}/w değil"
    [[ "$cmd" == *"--copy-links"* ]] ||
        die "Paylaşım WebDAV'ında --copy-links yok (paylaşılan ögeler görünmez)"
}

assert_share_network() {
    local nets count
    nets="$(
        docker inspect paylasim --format \
            '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
            2>/dev/null || true
    )"
    grep -qx 'paylasim' <<<"$nets" || die "paylasim konteyneri paylasim ağına bağlı değil"
    count="$(grep -c . <<<"$nets" || true)"
    [[ "$count" -eq 1 ]] || die "paylasim beklenmeyen ağlar: $(tr '\n' ' ' <<<"$nets")"
}

wait_share_healthy() {
    local attempt status
    for attempt in $(seq 1 36); do
        status="$(
            docker inspect paylasim --format \
                '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                2>/dev/null || echo missing
        )"
        [[ "$status" == "healthy" ]] && return 0
        sleep 2
    done
    die "paylasim healthcheck hazır değil (son durum: ${status:-unknown}; deneme=${attempt:-0})"
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
        # --remove-orphans: compose dosyası tek doğruluk kaynağıdır; dosyadan çıkarılan
        # bir servisin konteyneri ayakta kalmaz (DD-142'de kaldırılan webdav gibi).
        (cd "$COMPOSE_DIR" && docker compose up -d --remove-orphans)
    else
        log INFO "Compose dosyası aynı ve konteynerler ayakta; up atlandı"
    fi
    if [[ "$PULL_IMAGES" -eq 1 ]]; then
        log INFO "docker image prune (eski imaj katmanları temizleniyor)"
        docker image prune -f >/dev/null || log WARN "docker image prune başarısız (yok sayıldı)"
    fi
    wait_share_healthy
    assert_share_network
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
    # DD-127: qBittorrent API'si girişsiz 403 vermeli. Arayüzde "yerel istemcide
    # girişi atla" ya da bir alt ağ beyaz listesi açılırsa Caddy'den gelen herkes
    # parolasız girerdi (istekler konteynere Docker ağ geçidinden ulaşır).
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: torrent.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/api/v2/app/version" || true)"
    [[ "$code" == "403" ]] ||
        die "qBittorrent API girişsiz yanıt $code verdi (beklenen 403; arayüzde giriş atlama/beyaz liste açık olabilir)"
    qbit_login_check
    unset TORRENT_NEW_PASS

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:${SHARE_PORT}/" || true)"
    [[ "$code" == "401" ]] || die "Paylaşım loopback kimlik doğrulamasız yanıt $code (beklenen 401)"

    assert_share_readonly_runtime

    (cd "$COMPOSE_DIR" && docker port qbittorrent) 2>/dev/null |
        grep -q "${TORRENT_PUBLIC_PORT}/tcp" ||
        die "qbittorrent public TCP ${TORRENT_PUBLIC_PORT} publish yok"
    (cd "$COMPOSE_DIR" && docker port qbittorrent) 2>/dev/null |
        grep -q "${TORRENT_PUBLIC_PORT}/udp" ||
        die "qbittorrent public UDP ${TORRENT_PUBLIC_PORT} publish yok"

    for svc in dozzle filebrowser paylasim; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            [[ "$line" == *127.0.0.1:* ]] ||
                die "UI publish yalnız loopback olmalı: $svc ($line)"
        done < <((cd "$COMPOSE_DIR" && docker port "$svc") 2>/dev/null || true)
    done
    (cd "$COMPOSE_DIR" && docker port paylasim) 2>/dev/null |
        grep -q "127.0.0.1:${SHARE_PORT}" ||
        die "paylasim loopback publish ${SHARE_PORT} yok"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *"${TORRENT_PUBLIC_PORT}/"* ]] && continue
        [[ "$line" == *127.0.0.1:* ]] ||
            die "qBittorrent UI publish yalnız loopback olmalı ($line)"
    done < <((cd "$COMPOSE_DIR" && docker port qbittorrent) 2>/dev/null || true)

    # DD-120/DD-143: WireGuard katmanı hazır; kayıtta ağ varsa her biri ayakta, portu
    # kaydındaki port ve erişimi "ui" olanın arayüzleri caddy-wg'den non-5xx.
    local wg_iface wg_scope wg_s4 wg_port wg_ui_port
    "$SBIN_DIR/master-wg" version >/dev/null ||
        die "master-wg çalışmıyor ($SBIN_DIR/master-wg)"
    [[ -f "$WG_MODULES_LOAD_FILE" ]] || die "WireGuard modül dosyası yok: $WG_MODULES_LOAD_FILE"
    WG_PEER_COUNT=0
    WG_NET_COUNT=0
    if [[ -n "${WG_NETWORKS_FILE:-}" && -f "$WG_NETWORKS_FILE" ]]; then
        while IFS=$'\t' read -r wg_iface wg_port wg_scope wg_s4 _; do
            [[ "$wg_iface" =~ ^wg[0-9]$ ]] || continue
            WG_NET_COUNT=$((WG_NET_COUNT + 1))
            [[ "$(wg show "$wg_iface" listen-port 2>/dev/null || true)" == "$wg_port" ]] ||
                die "WireGuard $wg_iface dinleme portu kayıttaki $wg_port değil"
            ip -4 -o addr show dev "$wg_iface" 2>/dev/null | grep -q " ${wg_s4}/" ||
                die "WireGuard $wg_iface üzerinde $wg_s4 yok"
            WG_PEER_COUNT=$((WG_PEER_COUNT + $(wg show "$wg_iface" peers 2>/dev/null | grep -c . || true)))
            [[ "$wg_scope" == ui ]] || continue
            for wg_ui_port in "$DOZZLE_UI_PORT" "$TORRENT_UI_PORT" "$FILEBROWSER_UI_PORT"; do
                ui_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${wg_s4}:${wg_ui_port}/" || true)"
                [[ "$ui_code" =~ ^[1-4][0-9][0-9]$ ]] ||
                    die "caddy-wg ${wg_s4}:${wg_ui_port}: HTTP '${ui_code}' (non-5xx beklenir)"
            done
        done <"$WG_NETWORKS_FILE"
    fi

    # DD-140: Konsol tailnet'ten girişsiz 401 verir, kurulum.env hesabıyla iki arka uca da
    # ulaşır; eski adresler panele yönlenir ve panel WireGuard adresinde dinlenmez.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: panel.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
    [[ "$code" == "401" ]] || die "Konsol girişsiz yanıt $code verdi (beklenen 401)"
    local redir
    for redir in wg dosya; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Host: ${redir}.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
        [[ "$code" == "302" ]] || die "${redir}.${LOCAL_DOMAIN} panele yönlenmedi (HTTP $code)"
    done
    local panel_out
    panel_out="$(printf '%s' "$WG_PANEL_NEW_PASS" | python3 "$SBIN_DIR/master-wg-panel" check \
        --url "http://${TAILSCALE_IPV4}/api/wg/state" --host "panel.${LOCAL_DOMAIN}" \
        --user "$WG_PANEL_NEW_USER" 2>&1)" ||
        die "WireGuard paneli kurulum.env hesabıyla açılmadı: $panel_out"
    log INFO "Konsol WireGuard arka ucu açıldı: http://panel.${LOCAL_DOMAIN} ($panel_out)"
    # DD-139: dosya arka ucu aynı hesapla açılır, kök yazılabilir, root değil.
    local files_out files_uid svc
    files_out="$(printf '%s' "$WG_PANEL_NEW_PASS" | python3 "$SBIN_DIR/master-files-panel" check \
        --url "http://${TAILSCALE_IPV4}/api/state" --host "panel.${LOCAL_DOMAIN}" \
        --user "$WG_PANEL_NEW_USER" 2>&1)" ||
        die "Dosya paneli WireGuard paneli hesabıyla açılmadı: $files_out"
    unset WG_PANEL_NEW_PASS
    log INFO "Konsol dosya arka ucu açıldı: $files_out"
    files_uid="$(ps -o uid= -p "$(systemctl show -p MainPID --value master-files-panel.service)" 2>/dev/null | tr -d ' ')"
    [[ "$files_uid" == "$DOWNLOADS_UID" ]] ||
        die "Dosya paneli uid '${files_uid}' ile çalışıyor (beklenen $DOWNLOADS_UID; root olmamalı)"
    # DD-143: ağ varsa Konsol o ağın sunucu adresinde dinlememeli (ağ yoksa denetim atlanır).
    local wg_first_addr=""
    [[ ! -f "${WG_NETWORKS_FILE:-}" ]] ||
        wg_first_addr="$(awk -F'\t' '$1 ~ /^wg[0-9]$/ {print $4; exit}' "$WG_NETWORKS_FILE")"
    if [[ -n "$wg_first_addr" ]]; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://${wg_first_addr}:${FILES_PANEL_PORT}/" || true)"
        [[ "$code" == "000" ]] || die "Konsol WireGuard adresinde yanıt verdi (HTTP $code)"
    fi
    # Çöp unpackerr'a ve WebDAV'a boş görünmeli: içindeki arşivler yeniden açılmaz, Infuse listelemez.
    # DD-141: paylaşım salt okunur ve girişsiz açılmaz; kök klasör indirme sahibinde.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: paylas.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
    [[ "$code" == "401" ]] || die "Paylaşım WebDAV'ı girişsiz yanıt $code verdi (beklenen 401)"
    # DD-141: Infuse adı çözemeyen istemciler için IP:port adresi de açık olmalı.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${TAILSCALE_IPV4}:${SHARE_PORT}/" || true)"
    [[ "$code" == "401" ]] || die "Paylaşım ${TAILSCALE_IPV4}:${SHARE_PORT} adresinde yanıt $code verdi (beklenen 401)"
    local share_owner
    share_owner="$(stat -c '%u:%g' "$SERVER_ROOT/$SHARE_DIR/w" 2>/dev/null || true)"
    [[ "$share_owner" == "${DOWNLOADS_UID}:${DOWNLOADS_GID}" ]] ||
        die "Paylaşım kökü ${SERVER_ROOT}/${SHARE_DIR}/w sahibi '${share_owner}' (beklenen ${DOWNLOADS_UID}:${DOWNLOADS_GID})"

    # DD-144: çöp ve paylaşım kökü indirme klasörünün dışında; unpackerr ve qBittorrent
    # yalnız indirme klasörünü bağlar, o yüzden ikisini de göremez (tmpfs perdesi gerekmez).
    docker exec unpackerr sh -c \
        "test ! -e /downloads/${FILES_PANEL_TRASH} && test ! -e /downloads/${SHARE_DIR}" ||
        die "unpackerr konteyneri çöp ya da paylaşım klasörünü görüyor; indirme klasörünün dışında olmalılar"
    docker exec qbittorrent sh -c \
        "test ! -e /downloads/${FILES_PANEL_TRASH} && test ! -e /downloads/${SHARE_DIR}" ||
        die "qBittorrent konteyneri çöp ya da paylaşım klasörünü görüyor"
    if [[ -n "$wg_first_addr" ]]; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://${wg_first_addr}:${WG_PANEL_PORT}/" || true)"
        [[ "$code" == "000" ]] || die "Konsol arka ucu WireGuard adresinde yanıt verdi (HTTP $code)"
    fi

    log INFO "Temel doğrulamalar geçti"
}

print_summary() {
    local qb_note="kurulum.env hesabı; ayarlar templates/qBittorrent.conf"
    log INFO "Kurulum tamam — v$V2_VERSION"
    cat <<EOF

WAN:          $WAN_INTERFACE $WAN_IPV4 ${WAN_IPV6:-"(IPv6 yok)"}
Tailscale:    $TAILSCALE_IPV4 ${TAILSCALE_IPV6:-"(IPv6 yok)"}
Domain:       $LOCAL_DOMAIN
Kullanıcı alanı: $SERVER_ROOT (indirmeler $DOWNLOADS_PATH, kütüphane $SERVER_ROOT/$MEDIA_SUBDIR)
WireGuard:    ${WG_NET_COUNT:-0} ağ, ${WG_PEER_COUNT:-0} peer (endpoint: $WG_ENDPOINT_HOST; ağları Konsol kurar)
Torrent peer: ${TORRENT_PUBLIC_PORT}/tcp+udp
Compose:      $COMPOSE_DIR/compose.yaml
State:        $STATE_FILE
Log:          $V2_LOG_FILE

Manuel Tailscale Admin:
  1) DNS → Nameservers → Custom: $TAILSCALE_IPV4
  2) Restrict to domain: $LOCAL_DOMAIN
  3) Exit node olarak bu makineyi onayla

Konsol: http://panel.${LOCAL_DOMAIN} (WireGuard peer/ağ yönetimi, ${SERVER_ROOT} dosya yöneticisi,
  sunucu durumu ve günlük; yalnız Tailscale, kurulum.env hesabı. wg.${LOCAL_DOMAIN} ve dosya.${LOCAL_DOMAIN} buraya yönlenir)
Paylaşım: http://paylas.${LOCAL_DOMAIN} (Konsol'dan paylaşılanlar; salt okunur, tek hesap, yalnız Tailscale)
  Infuse: http://${TAILSCALE_IPV4}:${SHARE_PORT}/ (ad çözemeyen istemciler için aynı paylaşım)
Dozzle: http://dozzle.${LOCAL_DOMAIN} (durum, loglar, başlat/durdur/sil)
qBittorrent: http://torrent.${LOCAL_DOMAIN} ($qb_note)
WireGuard: ${WG_NET_COUNT:-0} ağ. Yoksa Konsol → WireGuard → Yapılandır ile ilk ağı kurun;
  "Local erişim" açık ağlarda Dozzle/qBittorrent/FileBrowser o ağın sunucu adresinde açılır.
  Peer eklemek/çıkarmak ve QR: Konsol ya da Mac'te wireguard.command (anahtarlar sunucuda üretilir).
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
