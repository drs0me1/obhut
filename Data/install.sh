#!/usr/bin/env bash
# Kurulum — Debian 13 / Ubuntu 24.04 / 26.04 LTS, doğrusal aşamalar,
# tekrar çalıştırılabilir.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

V2_VERSION="2026.08.06-v2-256"
# DD-260: insanların gördüğü sürüm (anlamlı sürümleme; yalnız bir yayında değişir, vX.Y.Z etiketlenir).
# V2_VERSION yapı numarasıdır: Konsol güncelleme önerirken sunucular onu karşılaştırır.
OBHUT_SURUM="1.1.0"
# DD-271: kurulumun nesli. Bu nesil yalnız temiz bir işletim sistemine kurulur (aşama 0'ın kapısı);
# Konsol yalnız aynı nesildeki yapıları güncelleme olarak önerir.
OBHUT_NESIL="2"
V2_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "$V2_ROOT/common.sh"
# shellcheck source=config/defaults.env
source "$V2_ROOT/config/defaults.env"

# STATE_DIR burada açılmaz: aşama 0'ın nesil kapısı onun varlığına bakar (DD-271).
mkdir -p "$LOG_DIR" "$RUNTIME_DIR"
V2_LOG_FILE="${V2_LOG_FILE:-$LOG_DIR/install.log}"
# retry fonksiyonları ayrı bash'te çalıştırır; apt çıktısı loga oradan da yazılsın.
export V2_LOG_FILE
FIREWALL_NEEDS_RESTART=0
# DD-233: Konsol'daki "Güncelle" düğmesi kurulumu master-guncelle birimiyle, terminalsiz yeniden
# çalıştırır (V2_GUNCELLEME=1). Bu kip ilk kurulum yapmaz: alan adı ve Tailscale oturumu önceden
# hazır olmalı; onayı operatör Konsol'da verir. Başka hiçbir yol terminalsiz kurulum yapmaz.
UPDATE_MODE=0
[[ "${V2_GUNCELLEME:-0}" != "1" ]] || UPDATE_MODE=1
# state.env'de kayıtlı OS kimliği canlı os-release ile uyuşmuyorsa 1 olur;
# OS'a bağlı adımlar dosya içeriği aynı kalsa bile yeniden uygulanır (DD-104).
OS_CHANGED=0
# Ubuntu'da unattended-upgrades varsayılan açık: apt kilidi dakikalarca
# tutulabilir. Kilitte hemen düşmek yerine bekle; retry üstte ayrıca sarar.
# Kurulumun indirdiği .deb'ler kurulduktan sonra önbellekte bırakılmaz
# (~300 MB; DD-125). Başkasının önbelleğe koyduğu dosyaya dokunulmaz.
APT_OPTS=(-o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false)

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
OBHUT_SURUM=$OBHUT_SURUM
OBHUT_NESIL=$OBHUT_NESIL
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
MEDIA_SUBDIR=$MEDIA_SUBDIR
DNS_PORT=$DNS_PORT
CADDY_HTTP_PORT=$CADDY_HTTP_PORT
DNSMASQ_CONF_FILE=$DNSMASQ_CONF_FILE
SETTINGS_FILE=$SETTINGS_FILE
SETTINGS_PENDING_FILE=$SETTINGS_PENDING_FILE
SETTINGS_DNS_FILE=$SETTINGS_DNS_FILE
SSH_PUBLIC_PORT=$SSH_PUBLIC_PORT
CHAIN_INPUT=$CHAIN_INPUT
CHAIN_FORWARD=$CHAIN_FORWARD
CHAIN_NAT=$CHAIN_NAT
CHAIN_SETTINGS=$CHAIN_SETTINGS
CHAIN_STAGING_PREFIX=$CHAIN_STAGING_PREFIX
PANEL_SOCKET=$PANEL_SOCKET
KONSOL_AUTH_DIR=$KONSOL_AUTH_DIR
CADDY_ADMIN_SOCKET=$CADDY_ADMIN_SOCKET
FILES_PANEL_PORT=$FILES_PANEL_PORT
SHARE_PORT=$SHARE_PORT
SHARE_HTTPS_PORT=$SHARE_HTTPS_PORT
SHARE_WAN_BACKEND=$SHARE_WAN_BACKEND
SHARE_STATE_FILE=$SHARE_STATE_FILE
SHARE_CADDY_SOURCE=$SHARE_CADDY_SOURCE
STATE_DIR=$STATE_DIR
SBIN_DIR=$SBIN_DIR
UNIT_DIR=$UNIT_DIR
KONTEYNER_BIRIM_DIR=$KONTEYNER_BIRIM_DIR
KONTEYNER_STATE_DIR=$KONTEYNER_STATE_DIR
KONTEYNER_LOCK=$KONTEYNER_LOCK
KONTEYNER_BAGLAMA_DIR=$KONTEYNER_BAGLAMA_DIR
KONTEYNER_NETWORK=$KONTEYNER_NETWORK
KONTEYNER_BRIDGE_PREFIX=$KONTEYNER_BRIDGE_PREFIX
KONTEYNER_NFT_TABLE=$KONTEYNER_NFT_TABLE
YAYIN_PORT_ILK=$YAYIN_PORT_ILK
YAYIN_PORT_SON=$YAYIN_PORT_SON
DOWNLOADS_UID=$DOWNLOADS_UID
DOWNLOADS_GID=$DOWNLOADS_GID
FILES_PANEL_TRASH=$FILES_PANEL_TRASH
CADDYFILE=$CADDYFILE
CADDY_MODULES_DIR=$CADDY_MODULES_DIR
VPN_BLOCK_DEST4="$VPN_BLOCK_DEST4"
VPN_BLOCK_DEST6="$VPN_BLOCK_DEST6"
WG_PORT_DEFAULT=$WG_PORT_DEFAULT
WG_ADDR_BASE4=$WG_ADDR_BASE4
WG_ADDR_BASE6=$WG_ADDR_BASE6
WG_MTU=$WG_MTU
WG_CLIENT_DNS_DEFAULT="$WG_CLIENT_DNS_DEFAULT"
WG_CLIENT_KEEPALIVE_DEFAULT=$WG_CLIENT_KEEPALIVE_DEFAULT
WG_CLIENT_ALLOWED_IPS="$WG_CLIENT_ALLOWED_IPS"
WG_CONF_DIR=$WG_CONF_DIR
WG_CLIENTS_DIR=$WG_CLIENTS_DIR
WG_NETWORKS_FILE=$WG_NETWORKS_FILE
WG_STOPPED_FILE=$WG_STOPPED_FILE
WG_NETWORKS_MAX=$WG_NETWORKS_MAX
WG_MODULES_LOAD_FILE=$WG_MODULES_LOAD_FILE
DNSMASQ_CONF_DIR=$DNSMASQ_CONF_DIR
RUNTIME_DIR=$RUNTIME_DIR
LOG_DIR=$LOG_DIR
GUNCELLEME_REPO=$GUNCELLEME_REPO
GUNCELLEME_DAL=$GUNCELLEME_DAL
GUNCELLEME_UNIT=$GUNCELLEME_UNIT
GUNCELLEME_DURUM_FILE=$GUNCELLEME_DURUM_FILE
GUNCELLEME_LOG_FILE=$GUNCELLEME_LOG_FILE
ONARIM_UNIT=$ONARIM_UNIT
ONARIM_DURUM_FILE=$ONARIM_DURUM_FILE
CONFIG_FILE=$CONFIG_FILE
SYSCTL_FORWARD_FILE=$SYSCTL_FORWARD_FILE
SYSCTL_NETBUF_FILE=$SYSCTL_NETBUF_FILE
SYSCTL_TCP_FILE=$SYSCTL_TCP_FILE
NET_BUF_FLOOR_BYTES=$NET_BUF_FLOOR_BYTES
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

# DD-124/DD-143: VPN ağlarının kaynağı sunucudaki kayıt ve wgN.conf dosyalarıdır.
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

# DD-208: Podman tabanın parçasıdır (Konsol konteynerlerinin çalışma ortamı). Daemon yok: Debian'ın
# podman.socket, podman.service ve podman-auto-update.timer birimleri kapalı gelir, kurulum açmaz.
# Aşama 1 kurar ve burada zorunlu denetler; aşama 7 yeniden denetler.
check_podman() {
    local out
    out="$(podman info --format '{{.Version.Version}} {{.Host.OCIRuntime.Name}}' 2>&1)" ||
        die "Podman çalışmıyor: ${out##*$'\n'}"
    [[ "$out" =~ ^[0-9]+\.[0-9]+ ]] || die "Podman sürümü okunamadı: $out"
    PODMAN_VERSION="${out%% *}"
}

# DD-271 (S3): bu nesil yalnız temiz bir işletim sistemine kurulur; göç kodu yoktur. STATE_DIR varsa
# bu neslin işaretini taşımalı; eski nesil bir Obhut'un bıraktığı izlerden (ESKI_NESIL_IZLERI) hiçbiri
# olmamalı. Kapı hiçbir şey yazmadan önce denetler; işaret ilk yazımla (write_generation) konur.
check_generation() {
    local nesil="" iz
    if [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        [[ ! -f "$NESIL_FILE" || -L "$NESIL_FILE" ]] || nesil="$(<"$NESIL_FILE")"
        [[ "$nesil" == "$OBHUT_NESIL" ]] ||
            die "Bu sunucuda eski nesil bir Obhut var ($STATE_DIR, nesil: ${nesil:-yok}); bu sürüm yalnız temiz bir işletim sistemine kurulur"
    fi
    for iz in $ESKI_NESIL_IZLERI; do
        [[ ! -e "$iz" && ! -L "$iz" ]] ||
            die "Bu sunucuda eski nesil bir Obhut var ($iz); bu sürüm yalnız temiz bir işletim sistemine kurulur"
    done
}

write_generation() {
    mkdir -p -- "$STATE_DIR"
    atomic_write "$NESIL_FILE" 0644 <<EOF
$OBHUT_NESIL
EOF
}

stage_0() {
    log INFO "Aşama 0/7 — kapılar ve girdi"
    require_root
    require_supported_os
    check_generation
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
    if [[ "$UPDATE_MODE" == 1 ]]; then
        log INFO "Konsol'dan güncelleme: sorular yok, onay Konsol'da verildi (DD-233)"
    else
        [[ -t 0 || -r /dev/tty ]] || die "etkileşimli TTY gerekli"
    fi
    # OS-DIVERGENCE: ufw-gate (pratikte ubuntu) — yoklama; paket yoksa no-op [DD-102]
    # Ubuntu server ufw ile gelir (varsayılan pasif). Aktifse INPUT'u ikinci
    # bir el yönetir ve MASTER-INPUT ile çelişir — fail-closed: önce kapat.
    if command -v ufw >/dev/null 2>&1 &&
        ufw status 2>/dev/null | grep -q '^Status: active'; then
        die "ufw aktif: INPUT politikası iki elden yönetilemez. Önce 'ufw disable' çalıştırın"
    fi
    acquire_lock "$RUNTIME_DIR/install.lock" "$LOCK_WAIT_SECONDS"
    [[ ! -f "$SETTINGS_PENDING_FILE" ]] ||
        die "Konsol'da bekleyen ayar işlemi var; Konsol'un üstündeki şeritte onaylayın veya geri alın (geri alma takıldıysa: Yeniden dene ya da Bırak)"

    LOCAL_DOMAIN=""
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    # DD-228: alan adının varsayılanı yoktur. Sıra: Konsol'da onaylanmış ad (DD-157), önceki
    # kurulumun adı (config.env); ikisi de yoksa (ilk kurulum) sorulur. Sonradan Konsol → Erişim →
    # Adresler'den değişir. İlk kurulumda ayar dosyası yoktur; henüz Python gerekmez.
    local saved_domain="" domain_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
    if [[ -f "$SETTINGS_FILE" ]]; then
        saved_domain="$(python3 "$V2_ROOT/panel/master_settings.py" saved-domain "$SETTINGS_FILE")" ||
            die "Konsol'daki alan adı kaydı okunamadı"
    fi
    if [[ -n "$saved_domain" ]]; then
        LOCAL_DOMAIN="$saved_domain"
        log INFO "alan adı Konsol'daki kayıttan: $LOCAL_DOMAIN"
    elif [[ -n "$LOCAL_DOMAIN" ]]; then
        log INFO "alan adı önceki kurulumdan: $LOCAL_DOMAIN (değiştirmek için Konsol → Erişim → Adresler)"
    elif [[ "$UPDATE_MODE" == 1 ]]; then
        die "Konsol'dan güncelleme ilk kurulumu yapmaz (alan adı kaydı yok); kurulumu terminalden çalıştırın"
    else
        local reply
        while :; do
            read -r -p "Yerel alan adı (ör. ev; panel.<ad> olur): " reply </dev/tty ||
                die "alan adı okunamadı"
            [[ "$reply" =~ $domain_re ]] && break
            echo "geçersiz alan adı; küçük harf, rakam ve '-' kullanın (en çok 63 karakter)" >&2
        done
        LOCAL_DOMAIN="$reply"
    fi
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

    detect_wan

    # DD-147: Tailscale'e yalnız giriş bağlantısıyla katılınır; auth key girdisi yok.
    local ts_note="aşama 2'de giriş bağlantısı gösterilir; tarayıcıda onaylayın"
    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
        [[ "$(tailscale_login_state)" == "complete" ]]; then
        ts_note="zaten online"
    elif [[ "$UPDATE_MODE" == 1 ]]; then
        die "Tailscale oturumu açık değil; giriş bağlantısı gerektiği için kurulumu terminalden çalıştırın"
    fi
    # Girdiler tek ekranda, parolasız; ilk yazımdan (config.env) önce tek onay.
    local confirm_ans="h"
    cat <<EOF

Kurulum girdileri:
  Alan adı:      $LOCAL_DOMAIN
  Kullanıcı alanı: $SERVER_ROOT (sabit; indirmeler $DOWNLOADS_PATH)
  Yerleşik:     Dosyalar, klasör WebDAV paylaşımları, WireGuard (ağları Konsol → Erişim → WireGuard kurar) ve Podman (konteyner ortamı)
  Konsol:        kullanıcı adı ve parolayla; Tailscale'den, isteğe bağlı internet HTTPS (DD-194, DD-195)
  Tailscale:     $ts_note
  full-upgrade:  evet

EOF
    if [[ "$UPDATE_MODE" == 1 ]]; then
        confirm_ans="E"
    else
        prompt confirm_ans "Bu değerlerle kurulum başlasın mı? (E/h)" "h"
    fi
    [[ "$confirm_ans" =~ ^[EeYy]$ ]] || die "kurulum iptal edildi; hiçbir ayar değiştirilmedi"

    write_generation
    write_config
}

# DD-113: dağıtımın güvenlik güncellemeleri kendiliğinden insin. Kaynak
# süzgeci paketin dağıtım varsayılanı (Debian: stable + security; Ubuntu:
# security). DD-184: Tailscale ve Caddy depoları da eklenir (dağıtımın
# listesine eklenir, yerine geçmez); güncelleme gece APT_UPGRADE_TIME'da.
# Reboot kararı operatörde; Ubuntu'da unattended-upgrades paketi imajla gelir.
apply_unattended_upgrades() {
    local timer_changed=0
    atomic_write "$APT_PERIODIC_FILE" 0644 <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    atomic_write "$APT_UNATTENDED_POLICY_FILE" 0644 <<EOF
// master-stack (DD-113): otomatik reboot yok; yeniden başlatma operatörün kararı.
Unattended-Upgrade::Automatic-Reboot "false";
// master-stack (DD-184): internete açık Tailscale ve Caddy de kendi depolarından güncellenir.
Unattended-Upgrade::Origins-Pattern {
        "$TAILSCALE_APT_ORIGIN";
        "$CADDY_APT_ORIGIN";
};
EOF
    install -d -m 0755 "${APT_UPGRADE_TIMER_DROPIN%/*}"
    atomic_write "$APT_UPGRADE_TIMER_DROPIN" 0644 <<EOF
# master-stack (DD-184): güncellemeler gece; boşta kalan zamanlama boot'ta telafi edilir.
[Timer]
OnCalendar=
OnCalendar=*-*-* $APT_UPGRADE_TIME
RandomizedDelaySec=30m
EOF
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || timer_changed=1
    systemctl daemon-reload
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 ||
        log WARN "apt-daily zamanlayıcıları etkinleştirilemedi"
    # Yeni saat, zamanlayıcı yeniden başlayınca geçerli olur.
    [[ "$timer_changed" -eq 0 ]] || systemctl restart apt-daily-upgrade.timer >/dev/null 2>&1 ||
        log WARN "apt-daily-upgrade zamanlayıcısı yeniden başlatılamadı"
}

# DD-253: Caddy's repository (Cloudsmith) answers 402 for days when the project's bandwidth limit
# is reached, and apt-get update then fails as a whole. A host that already has Caddy needs that
# list only to upgrade Caddy, so a refresh that fails on that repository alone goes on with the
# other lists and Caddy is not upgraded this run; the reason is written to the mark file. Any other
# failing repository, or a host without Caddy (stage 6 installs it from there), still fails. apt
# keeps that repository disabled: no signature check is relaxed. retry runs this in a child bash,
# so the repository, the mark file and APT_OPTS come as arguments.
apt_update_caddy_tolerant() {
    local repo="$1" mark="$2" out status errors
    shift 2
    out="$(mktemp)" || return 1
    LC_ALL=C apt-get "$@" update 2>&1 | tee "$out"
    status="${PIPESTATUS[0]}"
    if [[ "$status" -ne 0 ]] &&
        dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q 'install ok installed'; then
        errors="$(grep '^E: ' "$out" || true)"
        if [[ -n "$errors" ]] && ! grep -vF -e "$repo" -e 'E: Some index files failed to download.' <<<"$errors" >/dev/null; then
            sed -nE 's/^E: Failed to fetch [^ ]+ +([0-9]{3}) +([^[]*[^[ ]).*/\1 \2/p' <<<"$errors" | head -n1 >"$mark"
            [[ -s "$mark" ]] || echo "erişilemiyor" >"$mark"
            status=0
        fi
    fi
    rm -f "$out"
    return "$status"
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
    local caddy_mark
    caddy_mark="$(mktemp)"
    retry "apt-update" 3 "$APT_LOCK_TIMEOUT" -- apt_update_caddy_tolerant "$CADDY_APT_REPO" "$caddy_mark" "${APT_OPTS[@]}"
    if [[ -s "$caddy_mark" ]]; then
        log WARN "Caddy deposu yanıt vermiyor ($(head -c 80 "$caddy_mark")); Caddy bu kez güncellenmeden devam ediliyor (DD-253)"
    fi
    rm -f "$caddy_mark"
    # DD-228: sistem her kurulumda (yeniden kurulum dahil) önce güncellenir.
    retry "apt-upgrade" 2 "$APT_LOCK_TIMEOUT" -- \
        apt-get "${APT_OPTS[@]}" -y -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold full-upgrade
    # DD-153: yalnız temelin kullandıkları. gnupg (Caddy anahtarı artık .asc), gawk (v1'den
    # kalma; awk sistemin mawk'ı) ve apache2-utils (ortak htpasswd hesabı kaldırıldı) yok.
    retry "apt-base" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y \
        ca-certificates curl ethtool iproute2 procps kmod \
        iptables nftables coreutils util-linux diffutils jq \
        dnsutils unattended-upgrades python3
    # Artık binary kesin var: arka uç denetimi burada zorunlu (DD-108).
    check_nft_iptables required
    # DD-208: konteyner çalışma ortamı, önerileri olmadan (buildah, criu, slirp4netns gelmez).
    # Netavark köprü/NAT kurallarını, master-firewall yalnız kendi giriş korumasını yönetir.
    retry "apt-podman" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
        podman netavark aardvark-dns
    check_podman
    # DD-271: WireGuard yerleşiktir; araçları önerileri olmadan (DKMS ve derleyiciler gelmez, modül
    # çekirdeğindir). Ağ kurulmaz; aşama 4 birim ekini ve çekirdek modülünü hazırlar.
    retry "apt-wireguard" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
        wireguard-tools qrencode
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
# Caddy'nin Infuse'a WebDAV akışı, uygulamaların indirmeleri, arayüzler.
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
    # No pathname-based chown/chmod of service-writable data. Keep one selective
    # descriptor walk; links and special files stay untouched.
    python3 "$V2_ROOT/panel/master_permissions.py" "$root" "$uid" "$gid"
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
        /srv | /srv/* )
            return 0
            ;;
        *)
            die "kullanıcı alanı allowlist dışı (/srv): $p"
            ;;
    esac
}

PANEL_HELPERS_CHANGED=0
# DD-235: master-files-panel değişince Sistem görünümünün servisi de yeniden başlar.
FILES_PANEL_SCRIPT_CHANGED=0
# Paylaşım'ın araçları (master_shares.py, master_webdav.py) değişince WebDAV servisi yeniden başlar.
SHARE_HELPERS_CHANGED=0

# DD-271 (K6): WireGuard tabanın parçasıdır ve kurulumdan sonra kapalıdır: kurulum hiçbir ağ
# oluşturmaz, ilk ağı Konsol (Erişim → WireGuard) kurar. Araç SBIN_DIR'de; wg-quick@ birim eki bir ağı
# güvenlik duvarı denetimi geçmeden açmaz (DD-180); ağların klasörü yalnız root'a açıktır ve çekirdek
# modülü her açılışta yüklenir.
ensure_wireguard() {
    atomic_write "$SBIN_DIR/master-wg" 0755 <"$V2_ROOT/scripts/master-wg"
    install -d -m 0755 -o root -g root -- "$UNIT_DIR/wg-quick@.service.d"
    render_template "$V2_ROOT/systemd/wg-quick-master-stack.conf" "$UNIT_DIR/wg-quick@.service.d/master-stack.conf" 0644 \
        SBIN_DIR="$SBIN_DIR"
    modprobe wireguard >/dev/null 2>&1 || die "çekirdek WireGuard modülü yüklenemedi"
    atomic_write "$WG_MODULES_LOAD_FILE" 0644 <<'EOF'
wireguard
EOF
    install -d -m 0700 -o root -g root -- "$WG_CONF_DIR"
}

# DD-229: kurulumun yeniden çalışması kayıttaki ağları açar; durdurulmuş WireGuard (WG_STOPPED_FILE)
# kapalı kalır. Kayıt yoksa (ağ kurulmamış) yapılacak bir şey yoktur.
wireguard_networks_up() {
    local iface
    [[ ! -e "$WG_STOPPED_FILE" && -f "$WG_NETWORKS_FILE" ]] || return 0
    while IFS=$'\t' read -r iface _; do
        [[ "$iface" =~ ^wg[0-9]$ ]] || continue
        systemctl enable --now --quiet "wg-quick@$iface.service" >/dev/null 2>&1 ||
            log WARN "WireGuard: $iface açılamadı; Konsol → Erişim → WireGuard'dan bakın"
    done <"$WG_NETWORKS_FILE"
}

# Aşama 7: araç çalışıyor, modül her açılışta yüklenir, birim eki yerinde. Açık olması beklenen her
# ağ kayıttaki portu dinler ve kendi sunucu adresini taşır; Konsol'un dosya arka ucu bir VPN adresinde
# yanıt vermez (DD-177/180). Durdurulmuş WireGuard'ın ve Konsol'dan tek başına kapatılmış (birimi
# devre dışı) bir ağın arayüzü denetlenmez: kapalı olmaları beklenen durumdur (DD-229).
check_wireguard() {
    local iface port policy s4 code
    "$SBIN_DIR/master-wg" version >/dev/null 2>&1 || die "WireGuard: master-wg çalışmıyor ($SBIN_DIR/master-wg)"
    [[ -f "$WG_MODULES_LOAD_FILE" ]] || die "WireGuard: çekirdek modülü dosyası yok: $WG_MODULES_LOAD_FILE"
    [[ -f "$UNIT_DIR/wg-quick@.service.d/master-stack.conf" ]] ||
        die "WireGuard: wg-quick@ birim eki yok ($UNIT_DIR/wg-quick@.service.d/master-stack.conf)"
    [[ -f "$WG_NETWORKS_FILE" && ! -e "$WG_STOPPED_FILE" ]] || return 0
    while IFS=$'\t' read -r iface port policy s4 _; do
        [[ "$iface" =~ ^wg[0-9]$ ]] || continue
        [[ "$policy" == inet ]] || die "WireGuard: kayıtta beklenmeyen erişim sütunu: $iface ($policy)"
        systemctl is-enabled --quiet "wg-quick@$iface.service" 2>/dev/null || continue
        [[ "$(wg show "$iface" listen-port 2>/dev/null || true)" == "$port" ]] ||
            die "WireGuard: $iface dinleme portu kayıttaki $port değil"
        [[ "$(ip -4 -o addr show dev "$iface" 2>/dev/null || true)" == *" ${s4}/"* ]] ||
            die "WireGuard: $iface üzerinde $s4 yok"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${s4}:${FILES_PANEL_PORT}/" || true)"
        [[ "$code" == "000" ]] || die "WireGuard: Konsol $iface adresinde yanıt verdi (HTTP $code)"
    done <"$WG_NETWORKS_FILE"
}

stage_3() {
    log INFO "Aşama 3/7 — adresler ve dizinler"
    detect_wan
    detect_tailscale
    write_state
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && FIREWALL_NEEDS_RESTART=1

    local d
    # DD-144/171: downloads, media and trash are siblings.
    for d in \
        "$SERVER_ROOT" \
        "$DOWNLOADS_PATH" \
        "$SERVER_ROOT/$MEDIA_SUBDIR" \
        "$SERVER_ROOT/$MEDIA_SUBDIR/movies" \
        "$SERVER_ROOT/$MEDIA_SUBDIR/series" \
        "$SERVER_ROOT/$FILES_PANEL_TRASH"; do
        python3 "$V2_ROOT/panel/master_permissions.py" --mkdir "$d" "$DOWNLOADS_UID" "$DOWNLOADS_GID"
    done
    local fixed
    fixed="$(ensure_downloads_tree "$SERVER_ROOT" "$DOWNLOADS_UID" "$DOWNLOADS_GID")"
    if [[ "$fixed" -gt 0 ]]; then
        log INFO "Downloads: $fixed girdinin sahibi ya da izni düzeltildi (${DOWNLOADS_UID}:${DOWNLOADS_GID}; indirme hesabı R/W)"
    else
        log INFO "Downloads sahipliği ve izinleri yerinde (${DOWNLOADS_UID}:${DOWNLOADS_GID})"
    fi
}

stage_4() {
    log INFO "Aşama 4/7 — betikler ve şablonlar"
    atomic_write "$SBIN_DIR/master_settings.py" 0755 <"$V2_ROOT/panel/master_settings.py"
    if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]]; then
        PANEL_HELPERS_CHANGED=1
        FIREWALL_NEEDS_RESTART=1
    fi
    atomic_write "$SBIN_DIR/master_shares.py" 0755 <"$V2_ROOT/panel/master_shares.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || { PANEL_HELPERS_CHANGED=1; SHARE_HELPERS_CHANGED=1; }
    atomic_write "$SBIN_DIR/master_https.py" 0755 <"$V2_ROOT/panel/master_https.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1
    atomic_write "$SBIN_DIR/master_publications.py" 0755 <"$V2_ROOT/panel/master_publications.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1
    # DD-194: Konsol hesabı/oturumları; master-konsol root CLI'si aynı modülü çalıştırır.
    atomic_write "$SBIN_DIR/master_auth.py" 0755 <"$V2_ROOT/panel/master_auth.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1
    # DD-233: Konsol'un "Güncelle" düğmesi: sürüm denetimi (arka uç) ve işi yürüten root aracı.
    atomic_write "$SBIN_DIR/master_update.py" 0755 <"$V2_ROOT/panel/master_update.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1
    # DD-259: Konsol'un rota tablosu, Erişim okuma modeli ve canlı olaylar; DD-271: WireGuard ve denetçi
    # (YAML okuyucu, Compose ve Kubernetes okuyucuları; arka uç yükler).
    local panel_module
    for panel_module in master_api master_compose master_erisim master_inspector master_kube master_olaylar master_uygulamalar master_wireguard master_yaml master_yayin; do
        atomic_write "$SBIN_DIR/$panel_module.py" 0755 <"$V2_ROOT/panel/$panel_module.py"
        [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1
    done
    atomic_write "$SBIN_DIR/master-guncelle" 0755 <"$V2_ROOT/scripts/master-guncelle"
    # DD-239: denetle ve onar (Konsol'un Sağlık kartı ve SSH: sudo master-onar).
    atomic_write "$SBIN_DIR/master_onar.py" 0755 <"$V2_ROOT/panel/master_onar.py"
    atomic_write "$SBIN_DIR/master-onar" 0755 <"$V2_ROOT/scripts/master-onar"
    # DD-268: sunucunun durumu ve SSH'den kurtarma (sudo obhut); Konsol'un soketini ve yukarıdaki araçları kullanır.
    atomic_write "$SBIN_DIR/master_obhut.py" 0755 <"$V2_ROOT/panel/master_obhut.py"
    atomic_write "$SBIN_DIR/obhut" 0755 <"$V2_ROOT/scripts/obhut"
    # Konteyner okuma/yönetim araçları. Yazma çalışanı backend sandbox'ının dışında çalışır.
    atomic_write "$SBIN_DIR/master_containers.py" 0755 <"$V2_ROOT/panel/master_containers.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1
    local container_helper
    for container_helper in master_container_config master_container_network master_container_worker master_container_manager; do
        atomic_write "$SBIN_DIR/$container_helper.py" 0755 <"$V2_ROOT/panel/$container_helper.py"
        if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]]; then
            PANEL_HELPERS_CHANGED=1
            FIREWALL_NEEDS_RESTART=1
        fi
    done
    # DD-226: Konsol konteynerinin birimi her açılışta bağlanan klasörlerini bununla sabitler.
    atomic_write "$SBIN_DIR/master_container_binds.py" 0755 <"$V2_ROOT/panel/master_container_binds.py"
    install -d -m 0700 "$KONTEYNER_STATE_DIR"
    atomic_write "$SBIN_DIR/master-konsol" 0755 <"$V2_ROOT/scripts/master-konsol"
    atomic_write "$SBIN_DIR/master_webdav.py" 0755 <"$V2_ROOT/panel/master_webdav.py"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || SHARE_HELPERS_CHANGED=1
    render_template "$V2_ROOT/systemd/master-settings-guard.service" "$UNIT_DIR/master-settings-guard.service" 0644 \
        SBIN_DIR="$SBIN_DIR" STATE_FILE="$STATE_FILE"
    atomic_write "$UNIT_DIR/master-settings-guard.timer" 0644 <"$V2_ROOT/systemd/master-settings-guard.timer"
    render_template "$V2_ROOT/systemd/master-share-network.service" "$UNIT_DIR/master-share-network.service" 0644 \
        SBIN_DIR="$SBIN_DIR" STATE_FILE="$STATE_FILE"
    atomic_write "$UNIT_DIR/master-share-network.timer" 0644 <"$V2_ROOT/systemd/master-share-network.timer"
    ensure_wireguard
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
    render_template "$V2_ROOT/systemd/master-duvar-denetim.service" "$UNIT_DIR/master-duvar-denetim.service" 0644 \
        SBIN_DIR="$SBIN_DIR" STATE_FILE="$STATE_FILE"
    atomic_write "$UNIT_DIR/master-duvar-denetim.timer" 0644 <"$V2_ROOT/systemd/master-duvar-denetim.timer"
    systemctl daemon-reload
    systemctl enable --now master-settings-guard.timer
}

stage_5() {
    log INFO "Aşama 5/7 — firewall"

    systemctl enable master-firewall.service
    systemctl enable refresh-tailnet-config.service
    # DD-239/DD-240: after boot and nightly 03-04 (no 5-minute loop); the firewall keeps an hourly check.
    systemctl enable --now refresh-tailnet-config.timer
    systemctl enable --now master-duvar-denetim.timer

    if [[ "$FIREWALL_NEEDS_RESTART" -eq 1 ]] ||
        ! systemctl is-active --quiet master-firewall.service; then
        systemctl reset-failed master-firewall.service 2>/dev/null || true
        systemctl restart master-firewall.service
    else
        log INFO "firewall yapılandırması aynı; yeniden başlatılmadı"
    fi
    # DD-271: güvenlik duvarı WireGuard'ın portlarını ağ kaydından açar; ağ yoksa ya da WireGuard
    # durdurulmuşsa (WG_STOPPED_FILE) hiçbir VPN portu açılmaz. Ağlar aşama 7'de açılır.
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
            retry "caddy-key" 3 60 -- curl -1sLf "$CADDY_APT_REPO/gpg.key" -o "$caddy_key"
            install -m 0644 "$caddy_key" /usr/share/keyrings/caddy-stable-archive-keyring.asc
            rm -f "$caddy_key"
            atomic_write /etc/apt/sources.list.d/caddy-stable.list 0644 <<EOF
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.asc] $CADDY_APT_REPO/deb/debian any-version main
EOF
            retry "apt-update-caddy" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update
        fi
        retry "apt-caddy" 2 "$APT_LOCK_TIMEOUT" -- apt_get_install_masked_quiet "${APT_OPTS[@]}" caddy
    fi

    mkdir -p /etc/dnsmasq.d
    local dnsmasq_changed=0 caddy_changed=0 dns_tmp
    dns_tmp="$(mktemp "$RUNTIME_DIR/.dns-XXXXXX")"
    render_template "$V2_ROOT/templates/dnsmasq.conf" "$dns_tmp" 0644 \
        TAILSCALE_IF="$TAILSCALE_IF" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN"
    python3 "$SBIN_DIR/master_settings.py" filter-dns "$dns_tmp"
    atomic_write "$DNSMASQ_CONF_FILE" 0644 <"$dns_tmp"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && dnsmasq_changed=1
    # DD-158/159: Paylaşım'ın adı (paylas.<alan>); Konsol'un DNS seçimi taban adlarınki gibi uygulanır.
    render_template "$V2_ROOT/templates/paylasim-dnsmasq.conf" "$dns_tmp" 0644 \
        TAILSCALE_IF="$TAILSCALE_IF" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN"
    python3 "$SBIN_DIR/master_settings.py" filter-dns "$dns_tmp"
    atomic_write "$DNSMASQ_CONF_DIR/modul-paylasim.conf" 0644 <"$dns_tmp"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && dnsmasq_changed=1
    rm -f -- "$dns_tmp"
    # DD-156: rendered defaults consume confirmed operator choices on every re-run.
    python3 "$SBIN_DIR/master_settings.py" project-dns
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
        WAN_IPV4="$WAN_IPV4" SHARE_PORT="$SHARE_PORT" SHARE_HTTPS_PORT="$SHARE_HTTPS_PORT" \
        CADDY_HTTP_PORT="$CADDY_HTTP_PORT" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        CADDY_ADMIN_SOCKET="$CADDY_ADMIN_SOCKET" \
        PANEL_SOCKET="$PANEL_SOCKET" \
        SYSTEM_FILES_SOCKET="$SYSTEM_FILES_SOCKET" \
        FILES_PANEL_PORT="$FILES_PANEL_PORT" \
        CONSOLE_WEB_DIR="$CONSOLE_WEB_DIR" \
        CADDY_MODULES_DIR="$CADDY_MODULES_DIR"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1
    # DD-149: ek site dosyaları bu dizinden içe aktarılır.
    install -d -m 0755 -o root -g root "$CADDY_MODULES_DIR" "${SHARE_CADDY_SOURCE%/*}"
    # DD-158/191: Paylaşım'ın Tailscale sitesi. Doldurulmuş şablon SHARE_CADDY_SOURCE'ta durur; Caddy'nin
    # okuduğu kopya Konsol'un yayın seçiminden geçer (Tailscale yayını kapalıysa aynı adreslerde 403).
    local caddy_tmp
    render_template "$V2_ROOT/templates/paylasim.caddy" "$SHARE_CADDY_SOURCE" 0644 \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        SHARE_PORT="$SHARE_PORT"
    caddy_tmp="$(mktemp "$RUNTIME_DIR/.caddy-XXXXXX")"
    cp -- "$SHARE_CADDY_SOURCE" "$caddy_tmp"
    python3 "$SBIN_DIR/master_publications.py" --state "$STATE_FILE" filter-caddy paylasim "$caddy_tmp" ||
        { rm -f -- "$caddy_tmp"; die "Paylaşım'ın Caddy yayın seçimi okunamadı"; }
    atomic_write "$CADDY_MODULES_DIR/paylasim.caddy" 0644 <"$caddy_tmp"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1
    rm -f -- "$caddy_tmp"
    # DD-182: WAN paylaşım sitesi son yayındaki WAN_IPV4'e bağlanır. Sağlayıcı adresi
    # değiştirdiyse Caddy onunla açılamaz; site burada kalkar, 7. aşama yeni adresle yazar.
    local wan_site
    for wan_site in "$CADDY_MODULES_DIR"/*-wan.caddy; do
        if [[ -f "$wan_site" ]] && ! grep -qxF "$(printf '\tbind %s' "$WAN_IPV4")" "$wan_site"; then
            rm -f -- "$wan_site"
            caddy_changed=1
            log WARN "WAN IPv4 değişmiş; Caddy yayını 7. aşamada yeni adresle yazılacak"
        fi
    done
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
    # DD-180: yönetim arayüzünün soket klasörü yalnız Caddy'ye açık (0700); TCP 2019 yok.
    local caddy_runtime="${CADDY_ADMIN_SOCKET%/*}"
    atomic_write /etc/systemd/system/caddy.service.d/master-stack.conf 0644 <<EOF
[Unit]
Wants=tailscaled.service
After=tailscaled.service
OnFailure=refresh-tailnet-config.service
Wants=master-firewall.service
After=master-firewall.service
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
RuntimeDirectory=${caddy_runtime#/run/}
RuntimeDirectoryMode=0700
EnvironmentFile=$STATE_FILE
# DD-196: paket birimi --environ ile tüm ortamı (state.env) günlüğe döker; burada dökülmez.
ExecStart=
ExecStart=/usr/bin/caddy run --config $CADDYFILE --adapter caddyfile
ExecStartPre=+$SBIN_DIR/master-firewall --check
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
    ensure_panel "$OS_CHANGED"
    ensure_files_panel "$OS_CHANGED"
    ensure_system_files "$OS_CHANGED"
    ensure_share "$OS_CHANGED"
}

# DD-133, DD-140: Konsol'un root arka ucu. DD-180: TCP yok, PANEL_SOCKET
# Unix soketinde dinler (0660 root:CADDY_GROUP); Caddy tailnet'e ve isteğe bağlı genel HTTPS adına açar
# (panel.LOCAL_DOMAIN altında /api/konsol/*; DD-195). DD-194: Konsol
# girişini ve Caddy'nin her panel isteği için sorduğu oturumu da bu arka uç denetler.
# Yalnız betik ya da unit değişince servis yeniden başlar.
ensure_panel() {
    local changed="${1:-0}"
    [[ "$PANEL_HELPERS_CHANGED" -eq 0 ]] || changed=1
    # DD-194: hesap ve oturum kayıtları; arka ucun /etc altında yazabildiği kalıcı yer. Öbürü WireGuard'ın
    # klasörü (WG_CONF_DIR, aşama 4 açar): systemd yalnız o an var olan klasörü yazılabilir bağlar.
    install -d -m 0700 -o root -g root -- "$KONSOL_AUTH_DIR"
    atomic_write "$SBIN_DIR/master-panel" 0755 <"$V2_ROOT/panel/master-panel"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    render_template "$V2_ROOT/systemd/master-panel.service" "$UNIT_DIR/master-panel.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        PANEL_SOCKET="$PANEL_SOCKET" \
        PANEL_RUNTIME="$(basename -- "${PANEL_SOCKET%/*}")" \
        CADDY_GROUP="$CADDY_GROUP" \
        STATE_FILE="$STATE_FILE" \
        WG_CONF_DIR="$WG_CONF_DIR" \
        KONSOL_AUTH_DIR="$KONSOL_AUTH_DIR"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet master-panel.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet master-panel.service; then
        systemctl restart master-panel.service
    else
        log INFO "Konsol arka ucu aynı; yeniden başlatılmadı"
    fi
}

# Caddy directly serves the console's static assets.
ensure_console_pages() {
    local f rel
    local -A keep=()
    # Kökteki her dosyayı yönetir; yanlış bir değerle başka bir klasörü budamasın.
    [[ "$CONSOLE_WEB_DIR" == /usr/local/share/master-stack/* ]] || die "CONSOLE_WEB_DIR beklenmedik: $CONSOLE_WEB_DIR"
    [[ -f "$V2_ROOT/console/yeni/index.html" ]] || die "Konsol arayüzü eksik: console/yeni/index.html"
    install -d -m 0755 -o root -g root "$CONSOLE_WEB_DIR"
    # DD-267: Konsol arayüzü (tools/konsol-ui'den derlenip console/yeni'de tutulur) kökte; yanında giriş
    # sayfası, metin düzenleyici ve simgeler. Yalnız web dosyaları konur, gizli dosyalar (ör. macOS'un ._
    # eşleri) konmaz. Bu sürümde olmayan her dosya silinir.
    for f in giris.html giris.js giris.css duzenleyici.js obhut.svg obhut.png; do
        atomic_write "$CONSOLE_WEB_DIR/$f" 0644 <"$V2_ROOT/console/$f"
        keep[$f]=1
    done
    while IFS= read -r -d '' f; do
        rel="${f#"$V2_ROOT/console/yeni/"}"
        [[ -z "${keep[$rel]:-}" ]] || die "Konsol arayüzündeki $rel giriş sayfasının dosyasıyla çakışıyor"
        install -d -m 0755 -o root -g root "$(dirname -- "$CONSOLE_WEB_DIR/$rel")"
        atomic_write "$CONSOLE_WEB_DIR/$rel" 0644 <"$f"
        keep[$rel]=1
    done < <(find "$V2_ROOT/console/yeni" -type f ! -name '.*' \( -name '*.html' -o -name '*.js' -o -name '*.css' \
        -o -name '*.woff2' -o -name '*.svg' -o -name '*.png' -o -name '*.txt' -o -name 'manifest.json' \) -print0)
    while IFS= read -r -d '' f; do
        rel="${f#"$CONSOLE_WEB_DIR/"}"
        [[ -n "${keep[$rel]:-}" ]] || rm -f -- "$f"
    done < <(find "$CONSOLE_WEB_DIR" -mindepth 1 \( -type f -o -type l \) -print0)
    find "$CONSOLE_WEB_DIR" -mindepth 1 -depth -type d -empty -delete
}

# DD-139/159: yerleşik Dosyalar. master-files-panel indirme hesabıyla (DOWNLOADS_UID) yalnız loopback'te
# dinler ve yalnız SERVER_ROOT'a yazar; birimi doğrudan UNIT_DIR'e işlenir. Betik ya da birim değişince
# servis yeniden başlar; aşama 7 açıldığını ve kimin olarak çalıştığını doğrular.
ensure_files_panel() {
    local changed="${1:-0}" user group
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
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && { changed=1; FILES_PANEL_SCRIPT_CHANGED=1; }
    render_template "$V2_ROOT/systemd/master-files-panel.service" "$UNIT_DIR/master-files-panel.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        FILES_PANEL_PORT="$FILES_PANEL_PORT" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        SERVER_ROOT="$SERVER_ROOT" \
        FILES_PANEL_USER="$user" \
        FILES_PANEL_GROUP="$group" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        V2_VERSION="$V2_VERSION" \
        DOWNLOADS_SUBDIR="$DOWNLOADS_SUBDIR" \
        PRIVATE_STATE_ROOT="$PRIVATE_STATE_ROOT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet master-files-panel.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet master-files-panel.service; then
        systemctl reset-failed master-files-panel.service 2>/dev/null || true
        systemctl restart master-files-panel.service
    else
        log INFO "Dosya arka ucu aynı; yeniden başlatılmadı"
    fi
}

# DD-158/159: yerleşik klasör WebDAV (Paylaşım). Hesap kaydı (SHARE_STATE_FILE, 0600 root) servisten
# önce hazırlanır; servis onu systemd kimlik bilgisi olarak okur ve indirme hesabıyla çalışır. Birim
# doğrudan UNIT_DIR'e işlenir; birimi ya da araçları değişince servis yeniden başlar. Adları (paylas. ve
# Infuse için Tailscale IP:port) aşama 6 Caddy ve dnsmasq ile birlikte yazar; aşama 7 doğrular.
ensure_share() {
    local changed="${1:-0}"
    [[ "$SHARE_HELPERS_CHANGED" -eq 0 ]] || changed=1
    python3 "$SBIN_DIR/master_shares.py" prepare || die "klasör paylaşım kaydı hazırlanamadı"
    render_template "$V2_ROOT/systemd/master-paylasim.service" "$UNIT_DIR/master-paylasim.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        SERVER_ROOT="$SERVER_ROOT" \
        DOWNLOADS_UID="$DOWNLOADS_UID" \
        DOWNLOADS_GID="$DOWNLOADS_GID" \
        SHARE_STATE_FILE="$SHARE_STATE_FILE" \
        SHARE_PORT="$SHARE_PORT" \
        SHARE_WAN_BACKEND="$SHARE_WAN_BACKEND" \
        FILES_PANEL_TRASH="$FILES_PANEL_TRASH" \
        PRIVATE_STATE_ROOT="$PRIVATE_STATE_ROOT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet master-paylasim.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet master-paylasim.service; then
        systemctl reset-failed master-paylasim.service 2>/dev/null || true
        systemctl restart master-paylasim.service
    else
        log INFO "Paylaşım servisi aynı; yeniden başlatılmadı"
    fi
}

# DD-235: Dosyalar'ın "Sistem dosyaları" görünümü. master-files-panel'in --sistem kipi root olarak, kök /;
# yalnız SYSTEM_FILES_SOCKET Unix soketinde (0660 root:CADDY_GROUP). Caddy onu yalnız Tailscale
# sitesinde /api/sistem/* için açar. Betik ya da unit değişince servis yeniden başlar.
ensure_system_files() {
    local changed="${1:-0}"
    [[ "$FILES_PANEL_SCRIPT_CHANGED" -eq 0 ]] || changed=1
    render_template "$V2_ROOT/systemd/master-sistem-dosya.service" "$UNIT_DIR/master-sistem-dosya.service" 0644 \
        SBIN_DIR="$SBIN_DIR" \
        SYSTEM_FILES_SOCKET="$SYSTEM_FILES_SOCKET" \
        SYSTEM_FILES_RUNTIME="$(basename -- "${SYSTEM_FILES_SOCKET%/*}")" \
        CADDY_GROUP="$CADDY_GROUP" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        V2_VERSION="$V2_VERSION"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && changed=1
    systemctl daemon-reload
    systemctl enable --quiet master-sistem-dosya.service
    if [[ "$changed" -eq 1 ]] || ! systemctl is-active --quiet master-sistem-dosya.service; then
        systemctl restart master-sistem-dosya.service
    else
        log INFO "Sistem görünümü arka ucu aynı; yeniden başlatılmadı"
    fi
}

# Birim "active" olur olmaz işlem henüz root olabilir: systemd User='a exec'ten hemen önce geçer.
# uid, beklenen uid'ye dönene dek birkaç kez okunur (en çok ~5 sn); son okunan yazılır.
unit_uid() { # BİRİM
    local _ uid=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        uid="$(ps -o uid= -p "$(systemctl show -p MainPID --value "$1" 2>/dev/null || true)" 2>/dev/null | tr -d ' ' || true)"
        [[ "$uid" != "$DOWNLOADS_UID" ]] || break
        sleep 0.5
    done
    printf '%s\n' "$uid"
}

http_code() { # URL ya da curl argümanları; yanıt yoksa 000
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true
}

# Aşama 7'nin başı (DD-159): yeni başlamış olabilecek iki yerleşik servis yanıt verene dek beklenir.
# Dosyalar loopback'te Konsol başlığıyla yanıt verir; Paylaşım indirme hesabıyla çalışır ve hesapsız
# isteğe 401 verir; paylas.<alan>, Tailscale IP:port ve DNS adı açıktır (Konsol'da Tailscale yayını
# kapatılmışsa ikisi de 403).
verify_builtins() {
    local _ ok=0 uid code="" a="" b="" ans="" expected=401 rc=0
    for _ in $(seq 1 20); do
        systemctl is-active --quiet master-files-panel.service && break
        sleep 1
    done
    systemctl is-active --quiet master-files-panel.service || die "Dosyalar: servis başlamadı"
    for _ in $(seq 1 10); do
        if python3 "$SBIN_DIR/master-files-panel" check --url "http://127.0.0.1:$FILES_PANEL_PORT/api/state" \
            --host "panel.$LOCAL_DOMAIN" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    [[ "$ok" == 1 ]] || die "Dosyalar: servis yerel portunda yanıt vermedi"
    for _ in $(seq 1 20); do
        code="$(http_code "http://127.0.0.1:$SHARE_PORT/")"
        [[ "$code" != 401 ]] || break
        sleep 1
    done
    systemctl is-active --quiet master-paylasim.service || die "Paylaşım: servis başlamadı"
    uid="$(unit_uid master-paylasim.service)"
    [[ "$uid" == "$DOWNLOADS_UID" && "$code" == 401 ]] ||
        die "Paylaşım: uid/adres/giriş kapısı doğrulanamadı (uid '$uid', HTTP $code)"
    python3 "$SBIN_DIR/master_publications.py" --state "$STATE_FILE" tail-enabled paylasim || rc=$?
    [[ "$rc" -le 1 ]] || die "Paylaşım: Caddy ağ seçimi okunamadı"
    [[ "$rc" == 0 ]] || expected=403
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        a="$(http_code -H "Host: paylas.$LOCAL_DOMAIN" "http://$TAILSCALE_IPV4/")"
        b="$(http_code "http://$TAILSCALE_IPV4:$SHARE_PORT/")"
        ans="$(dig +short +time=2 +tries=1 "paylas.$LOCAL_DOMAIN" @"$TAILSCALE_IPV4" 2>/dev/null | head -n1 || true)"
        python3 "$SBIN_DIR/master_settings.py" dns-enabled "paylas.$LOCAL_DOMAIN" || ans="$TAILSCALE_IPV4"
        [[ "$a" == "$expected" && "$b" == "$expected" && "$ans" == "$TAILSCALE_IPV4" ]] && return 0
        sleep 1
    done
    die "Paylaşım: paylas.$LOCAL_DOMAIN ya da $TAILSCALE_IPV4:$SHARE_PORT açılmadı (ad $a, port $b, DNS '$ans')"
}

stage_7() {
    log INFO "Aşama 7/7 — doğrulama"
    verify_builtins
    python3 "$SBIN_DIR/master_shares.py" publish
    systemctl enable --now master-share-network.timer
    wireguard_networks_up
    "$SBIN_DIR/master-firewall" --check
    check_podman
    # DD-181: the timer sleeps while nothing is pending; it must stay enabled for boot and apply.
    systemctl is-enabled --quiet master-settings-guard.timer || die "Konsol ayar geri alma zamanlayıcısı etkin değil"
    python3 "$SBIN_DIR/master_settings.py" status >/dev/null || die "Konsol ayar durumu okunamadı"

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
    # DD-184: Tailscale ve Caddy depoları etkin kalıpta mı (başka bir dosya ezmiş olabilir)?
    local patterns
    patterns="$(apt-config dump 2>/dev/null | awk '/^Unattended-Upgrade::Origins-Pattern/' || true)"
    [[ "$patterns" == *"$TAILSCALE_APT_ORIGIN"* && "$patterns" == *"$CADDY_APT_ORIGIN"* ]] ||
        log WARN "Tailscale/Caddy otomatik güncelleme kalıpları etkin yapılandırmada yok ($APT_UNATTENDED_POLICY_FILE)"

    local name resolver ans dig_out code line
    # shellcheck disable=SC2086
    for name in $SERVICE_NAMES; do
        if ! python3 "$SBIN_DIR/master_settings.py" dns-enabled "${name}.${LOCAL_DOMAIN}"; then
            log INFO "DNS: ${name}.${LOCAL_DOMAIN} Konsol tercihiyle kapalı"
            continue
        fi
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
    if ! python3 "$SBIN_DIR/master_settings.py" dns-forward; then
        [[ "$dig_out" == *"status: REFUSED"* ]] ||
            die "DNS: alan dışı sorgu REFUSED değil (Tailscale DNS)"
    fi

    check_wireguard

    # DD-194/DD-205: Konsol girişi. Giriş sayfasının dosyaları açıktır; geri kalan her panel isteği
    # (sayfa, Dosyalar, API) Caddy'nin forward_auth'u ile root arka uca sorulur. Tailscale sitesinde
    # başka bir Tailscale cihazı oturumsuz geçer (cihazı Tailscale doğrular) ve /giris.html Konsol'a
    # yönlenir; sunucunun kendisinden gelen istek reddedilir (DD-180). Caddy'nin yönlendirme
    # başlıkları olmadan (internet sitesinde olduğu gibi) oturumsuz API 401 alır, sayfa giriş
    # sayfasına yönlenir. Ayrıca X-Konsol başlığı olmayan API isteği (başka bir sitenin tarayıcıdan
    # attığı istek) ve yabancı Host (DNS rebinding) iki arka uçta da reddedilir. Panel VPN adresinde
    # dinlenmez.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: panel.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/giris.js" || true)"
    [[ "$code" == "200" ]] || die "Konsol giriş sayfasının dosyası tailnet'ten açılmadı (HTTP $code)"
    local page_body probe tail_probe
    page_body="$(curl -s --max-time 5 -w '\n%{http_code}' -H "Host: panel.${LOCAL_DOMAIN}" \
        "http://${TAILSCALE_IPV4}/" 2>/dev/null || true)"
    [[ "${page_body##*$'\n'}" == "403" && "$page_body" == *"başka bir Tailscale cihazından"* ]] ||
        die "Konsol sayfası oturum denetiminden geçmeden açıldı (HTTP ${page_body##*$'\n'})"
    for probe in "/api/konsol/kaynaklar|401" "/|302"; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$PANEL_SOCKET" \
            -H "Host: panel.${LOCAL_DOMAIN}" -H "X-Forwarded-Uri: ${probe%%|*}" \
            "http://localhost/oturum-denetle" || true)"
        [[ "$code" == "${probe#*|}" ]] ||
            die "Konsol oturum denetimi ${probe%%|*} için HTTP $code döndü (beklenen ${probe#*|})"
    done
    # DD-205: başka bir Tailscale cihazı (Caddy'nin yazdığı X-Forwarded-For) oturumsuz geçer; giriş
    # sayfası ona Konsol'u gösterir. Deneme adresi sunucunun kendi tailnet adresinden türetilir
    # (son bölüm farklı, aynı 100.64.0.0/10 aralığında); sabit bir adres yazılmaz.
    tail_probe="${TAILSCALE_IPV4%.*}.$(( (${TAILSCALE_IPV4##*.} + 1) % 254 + 1 ))"
    for probe in "/api/konsol/kaynaklar|204" "/giris.html|302"; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$PANEL_SOCKET" \
            -H "Host: panel.${LOCAL_DOMAIN}" -H "X-Forwarded-For: $tail_probe" -H "X-Forwarded-Uri: ${probe%%|*}" \
            "http://localhost/oturum-denetle" || true)"
        [[ "$code" == "${probe#*|}" ]] ||
            die "Konsol Tailscale kapısı ${probe%%|*} için HTTP $code döndü (beklenen ${probe#*|})"
    done
    # DD-180: root arka ucu TCP'de değil, yalnız Unix soketinde; dosya arka ucu loopback'te.
    local gate gate_path gate_url gate_via=()
    for gate in "http://127.0.0.1:${FILES_PANEL_PORT}|/api/state" "unix:${PANEL_SOCKET}|/api/konsol/kaynaklar"; do
        gate_path="${gate#*|}"
        gate_url="${gate%%|*}"
        gate_via=()
        if [[ "$gate_url" == unix:* ]]; then
            gate_via=(--unix-socket "${gate_url#unix:}")
            gate_url="http://localhost"
        fi
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${gate_via[@]}" \
            -H "Host: panel.${LOCAL_DOMAIN}" "${gate_url}${gate_path}" || true)"
        [[ "$code" == "403" ]] || die "Konsol ${gate_path}: X-Konsol başlığı olmadan HTTP $code (beklenen 403)"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${gate_via[@]}" -H 'X-Konsol: 1' \
            -H "Host: baska.ornek" "${gate_url}${gate_path}" || true)"
        [[ "$code" == "403" ]] || die "Konsol ${gate_path}: yabancı Host ile HTTP $code (beklenen 403)"
    done
    # DD-180: indirme hesabıyla çalışan bir program (ör. bir paketin servisi) root arka uca ve
    # Caddy'nin yönetim arayüzüne ulaşamamalı. Soketin izni ve gerçek bir deneme sınanır.
    [[ "$(stat -c '%U:%G:%a' "$PANEL_SOCKET" 2>/dev/null)" == "root:${CADDY_GROUP}:660" ]] ||
        die "Konsol arka ucu soketi root:${CADDY_GROUP} 0660 değil: $PANEL_SOCKET"
    [[ "$(stat -c '%U:%a' "${CADDY_ADMIN_SOCKET%/*}" 2>/dev/null)" == "caddy:700" ]] ||
        die "Caddy yönetim soketinin klasörü yalnız Caddy'ye açık değil: ${CADDY_ADMIN_SOCKET%/*}"
    [[ -S "$CADDY_ADMIN_SOCKET" ]] || die "Caddy yönetim soketi yok: $CADDY_ADMIN_SOCKET"
    # DD-235: Sistem görünümü (root) da yalnız root ve Caddy'nin grubuna açık bir sokette; yalnız
    # Tailscale kanalından ve başka bir Tailscale cihazından gelen isteği kabul eder.
    [[ "$(stat -c '%U:%G:%a' "$SYSTEM_FILES_SOCKET" 2>/dev/null)" == "root:${CADDY_GROUP}:660" ]] ||
        die "Sistem görünümü soketi root:${CADDY_GROUP} 0660 değil: $SYSTEM_FILES_SOCKET"
    local kanal adres beklenen
    for probe in "tailscale|${tail_probe}|200" "internet|${tail_probe}|403" "tailscale|${TAILSCALE_IPV4}|403"; do
        IFS='|' read -r kanal adres beklenen <<<"$probe"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$SYSTEM_FILES_SOCKET" \
            -H "Host: panel.${LOCAL_DOMAIN}" -H 'X-Konsol: 1' -H "X-Konsol-Kanal: $kanal" \
            -H "X-Forwarded-For: $adres" "http://localhost/api/sistem/state" || true)"
        [[ "$code" == "$beklenen" ]] ||
            die "Sistem görünümü $kanal kanalı ve $adres için HTTP $code döndü (beklenen $beklenen)"
    done
    local sock
    for sock in "$PANEL_SOCKET" "$SYSTEM_FILES_SOCKET" "$CADDY_ADMIN_SOCKET"; do
        code="$(setpriv --reuid="$DOWNLOADS_UID" --regid="$DOWNLOADS_GID" --clear-groups \
            curl -s -o /dev/null -w '%{http_code}' --max-time 3 --unix-socket "$sock" \
            -H "Host: panel.${LOCAL_DOMAIN}" -H 'X-Konsol: 1' "http://localhost/" 2>/dev/null || true)"
        [[ "$code" == "000" ]] || die "İndirme hesabı $sock soketine bağlanabildi (HTTP $code)"
    done
    # Caddy'nin varsayılan TCP yönetim portu (2019) kapalı; yeniden yükleme soketten çalışır.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:2019/config/" || true)"
    [[ "$code" == "000" ]] || die "Caddy yönetim arayüzü TCP'de açık (HTTP $code)"
    systemctl reload caddy || die "Caddy yönetim soketi üzerinden yeniden yüklenemedi"
    # DD-180: Caddy'nin tailnet adresi sunucunun içinden de açıktır; oradan gelen istek (ör.
    # indirme hesabıyla çalışan bir program) root arka uçtan 403 almalı. Arka ucun kendi
    # denetimi soketten yapılır; 403'ün gövdesi isteğin Caddy'den arka uca ulaştığını da gösterir.
    local self_body
    self_body="$(setpriv --reuid="$DOWNLOADS_UID" --regid="$DOWNLOADS_GID" --clear-groups \
        curl -s --max-time 5 -w '\n%{http_code}' -H "Host: panel.${LOCAL_DOMAIN}" -H 'X-Konsol: 1' \
        "http://${TAILSCALE_IPV4}/api/konsol/kaynaklar" 2>/dev/null || true)"
    [[ "${self_body##*$'\n'}" == "403" && "$self_body" == *"başka bir Tailscale cihazından"* ]] ||
        die "Sunucunun içinden Caddy üzerinden root arka uca ulaşıldı (HTTP ${self_body##*$'\n'})"
    self_body="$(setpriv --reuid="$DOWNLOADS_UID" --regid="$DOWNLOADS_GID" --clear-groups \
        curl -s --max-time 5 -w '\n%{http_code}' -H "Host: panel.${LOCAL_DOMAIN}" -H 'X-Konsol: 1' \
        "http://${TAILSCALE_IPV4}/api/sistem/state" 2>/dev/null || true)"
    [[ "${self_body##*$'\n'}" == "403" && "$self_body" == *"başka bir Tailscale cihazından"* ]] ||
        die "Sunucunun içinden Caddy üzerinden Sistem görünümüne ulaşıldı (HTTP ${self_body##*$'\n'})"
    local panel_out
    panel_out="$(python3 "$SBIN_DIR/master-panel" check --socket "$PANEL_SOCKET" \
        --url "http://panel.${LOCAL_DOMAIN}/api/konsol/kaynaklar" --host "panel.${LOCAL_DOMAIN}" 2>&1)" ||
        die "Konsol arka ucu yanıt vermedi: $panel_out"
    log INFO "Konsol arka ucu açıldı: http://panel.${LOCAL_DOMAIN} ($panel_out)"
    # DD-159: built-in Files is required, writable and unprivileged.
    local files_out files_uid
    # DD-194: Caddy'den geçen yol oturum ister; arka ucun kendisi loopback'ten sınanır.
    files_out="$(python3 "$SBIN_DIR/master-files-panel" check \
        --url "http://127.0.0.1:${FILES_PANEL_PORT}/api/state" --host "panel.${LOCAL_DOMAIN}" 2>&1)" ||
        die "Konsol dosya arka ucu yanıt vermedi: $files_out"
    log INFO "Konsol dosya arka ucu açıldı: $files_out"
    files_uid="$(ps -o uid= -p "$(systemctl show -p MainPID --value master-files-panel.service)" 2>/dev/null | tr -d ' ')"
    [[ "$files_uid" == "$DOWNLOADS_UID" ]] ||
        die "Dosya paneli uid '${files_uid}' ile çalışıyor (beklenen $DOWNLOADS_UID; root olmamalı)"
    # DD-143: a WireGuard network's server address must not reach Konsol (check_wireguard).
    # WebDAV registry, unprivileged listener and addresses were verified by verify_builtins.

    log INFO "Temel doğrulamalar geçti"
}

# Özet: WireGuard'ın durumu tek satırda (kayıttaki ağlar ve arayüzlerdeki peer'lar).
summary_wireguard() {
    local iface nets=0 peers=0
    if [[ -f "$WG_NETWORKS_FILE" ]]; then
        while IFS=$'\t' read -r iface _; do
            [[ "$iface" =~ ^wg[0-9]$ ]] || continue
            nets=$((nets + 1))
            peers=$((peers + $(wg show "$iface" peers 2>/dev/null | grep -c . || true)))
        done <"$WG_NETWORKS_FILE"
    fi
    if [[ -e "$WG_STOPPED_FILE" ]]; then
        printf 'durduruldu (%s ağ)' "$nets"
    elif [[ "$nets" -eq 0 ]]; then
        printf 'ağ yok; ilk ağ Konsol → Erişim → WireGuard'
    else
        printf '%s ağ, %s peer' "$nets" "$peers"
    fi
}

print_summary() {
    log INFO "Kurulum tamam — Obhut $OBHUT_SURUM (yapı $V2_VERSION)"
    cat <<EOF

WAN:          $WAN_INTERFACE $WAN_IPV4 ${WAN_IPV6:-"(IPv6 yok)"}
Tailscale:    $TAILSCALE_IPV4 ${TAILSCALE_IPV6:-"(IPv6 yok)"}
Domain:       $LOCAL_DOMAIN
Kullanıcı alanı: $SERVER_ROOT (indirmeler $DOWNLOADS_PATH, kütüphane $SERVER_ROOT/$MEDIA_SUBDIR)
State:        $STATE_FILE
Log:          $V2_LOG_FILE

Manuel Tailscale Admin:
  1) DNS → Nameservers → Custom: $TAILSCALE_IPV4
  2) Restrict to domain: $LOCAL_DOMAIN
  3) Exit node olarak bu makineyi onayla

Konsol: http://panel.${LOCAL_DOMAIN} (Genel Bakış, Uygulamalar, Erişim, Dosyalar, Sistem; Tailscale'den parolasız)
  İnternetten HTTPS isteğe bağlı: önce Sistem → Hesap (kullanıcı adı + parola),
  sonra Erişim → Adresler → Konsol (DNS A kaydı gerekir).
  Sağlık, güncelleme ve günlük Sistem'de; uygulamalar Uygulamalar'da.
Podman:       ${PODMAN_VERSION:-?} (konteyner ortamı; Konsol → Gelişmiş → Podman)
Yerleşikler:
  Dosyalar: $SERVER_ROOT
  Paylaşım: Dosyalar → Paylaşımlar: klasör başına adres, kullanıcı ve erişim izni
  WireGuard: $(summary_wireguard)
  WireGuard cihazları yalnız internete çıkar; sunucu servisleri ve diğer ağlara erişemez.
  Peer ve QR: Konsol ya da Mac'te wireguard.command.
Tailscale IP: refresh-tailnet-config → Caddy
EOF
}

main() {
    log INFO "Obhut $OBHUT_SURUM başlıyor (yapı $V2_VERSION)"
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
        --why="Obhut kurulum işlemi" \
        --mode=block \
        env V2_INHIBITED=1 bash "$self" "$@"
fi

main "$@"
