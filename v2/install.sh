#!/usr/bin/env bash
# v2 kurulum — Debian 13, doğrusal aşamalar, tekrar çalıştırılabilir.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

V2_VERSION="2026.08.06-v2-28"
V2_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "$V2_ROOT/common.sh"
# shellcheck source=config/defaults.env
source "$V2_ROOT/config/defaults.env"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
V2_LOG_FILE="${V2_LOG_FILE:-$LOG_DIR/install.log}"
RUN_FULL_UPGRADE=0
COMPOSE_NEEDS_UP=1

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

prompt_secret_twice() {
    local var="$1" msg="$2" a="" b=""
    read -r -s -p "$msg: " a </dev/tty || true
    printf '\n' >/dev/tty
    read -r -s -p "$msg (tekrar): " b </dev/tty || true
    printf '\n' >/dev/tty
    [[ -n "$a" ]] || die "parola boş olamaz"
    [[ "$a" == "$b" ]] || die "parolalar eşleşmiyor"
    [[ "${#a}" -ge "$WEBDAV_MIN_PASSWORD_LENGTH" ]] ||
        die "parola en az $WEBDAV_MIN_PASSWORD_LENGTH karakter olmalı"
    printf -v "$var" '%s' "$a"
}

write_state() {
    atomic_write "$STATE_FILE" 0600 <<EOF
V2_VERSION=$V2_VERSION
WAN_INTERFACE=$WAN_INTERFACE
WAN_IPV4=$WAN_IPV4
TAILSCALE_IF=$TAILSCALE_IF
TAILSCALE_IPV4=$TAILSCALE_IPV4
TAILSCALE_IPV6=$TAILSCALE_IPV6
LOCAL_DOMAIN=$LOCAL_DOMAIN
DOWNLOADS_PATH=$DOWNLOADS_PATH
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST
WG_PUBLIC_PORT=$WG_PUBLIC_PORT
QBIT_PUBLIC_PORT=$QBIT_PUBLIC_PORT
SSH_PUBLIC_PORT=$SSH_PUBLIC_PORT
WEBDAV_PORT=$WEBDAV_PORT
CHAIN_INPUT=$CHAIN_INPUT
CHAIN_DOCKER=$CHAIN_DOCKER
CHAIN_STAGING_PREFIX=$CHAIN_STAGING_PREFIX
EOF
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
        wait "$up_pid" 2>/dev/null || true
        if [[ "$(tailscale_login_state)" == "complete" ]]; then
            rm -f "$out"
            return 0
        fi
        log WARN "Tailscale giriş başarısız/410; daemon sıfırlanıyor"
        kill "$up_pid" 2>/dev/null || true
        systemctl restart --job-mode=ignore-dependencies tailscaled
        sleep 2
        attempt=$((attempt + 1))
    done
    rm -f "$out"
    die "Tailscale girişi tamamlanamadı"
}

ensure_wg_kernel_modules() {
    local wg_module
    for wg_module in wireguard ip6_tables ip6table_nat; do
        if ! modprobe "$wg_module" 2>/tmp/modprobe-wg.err; then
            log WARN "modprobe $wg_module başarısız"
            cat /tmp/modprobe-wg.err >&2 || true
        fi
        rm -f /tmp/modprobe-wg.err
    done
    atomic_write /etc/modules-load.d/wg-easy.conf 0644 <<'EOF'
wireguard
ip6_tables
ip6table_nat
EOF
    if ip link add wg-easy-probe0 type wireguard 2>/dev/null; then
        ip link del wg-easy-probe0
        log INFO "WireGuard host çekirdek desteği doğrulandı"
    else
        log WARN "Host WireGuard arayüzü oluşturamıyor; wg-easy başlatılamayabilir"
    fi
}

install_tailscale_repo() {
    local keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
    local tmp
    tmp="$(mktemp)"
    retry "tailscale-gpg" 3 60 -- \
        curl -fsSL "https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg" -o "$tmp"
    # apt/sqv keyring'i _apt kullanıcısı olarak okur; 0600 Permission denied verir.
    install -m 0644 "$tmp" "$keyring"
    rm -f "$tmp"
    atomic_write /etc/apt/sources.list.d/tailscale.list 0644 <<'EOF'
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main
EOF
}

install_docker_repo() {
    install -m 0755 -d /etc/apt/keyrings
    retry "docker-gpg" 3 60 -- \
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    atomic_write /etc/apt/sources.list.d/docker.sources 0644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

ensure_webdav_user() {
    if ! id -u master-webdav >/dev/null 2>&1; then
        useradd --system --home /nonexistent --shell /usr/sbin/nologin master-webdav
    fi
}

stage_0() {
    log INFO "Aşama 0/7 — kapılar ve girdi"
    require_root
    require_debian_trixie
    [[ -t 0 || -r /dev/tty ]] || die "etkileşimli TTY gerekli"
    acquire_lock "$RUNTIME_DIR/install.lock" "$LOCK_WAIT_SECONDS"

    local prev_domain="$DEFAULT_LOCAL_DOMAIN" prev_dl="$DOWNLOADS_PATH_DEFAULT"
    local prev_webdav_port="$WEBDAV_PORT" prev_wg_port="$WG_PUBLIC_PORT"
    if [[ -r "$STATE_FILE" ]]; then
        local state_wg
        state_wg="$(awk -F= '/^WG_PUBLIC_PORT=/{print $2; exit}' "$STATE_FILE" || true)"
        [[ "$state_wg" =~ ^[0-9]+$ ]] && prev_wg_port="$state_wg"
    fi
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        prev_domain="${LOCAL_DOMAIN:-$prev_domain}"
        prev_dl="${DOWNLOADS_PATH:-$prev_dl}"
        prev_webdav_port="${WEBDAV_PORT:-$prev_webdav_port}"
        if grep -q '^WG_PUBLIC_PORT=' "$CONFIG_FILE"; then
            prev_wg_port="${WG_PUBLIC_PORT:-$prev_wg_port}"
        fi
    fi

    prompt LOCAL_DOMAIN "Yerel alan adı" "$prev_domain"
    [[ "$LOCAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die "geçersiz alan adı: $LOCAL_DOMAIN"
    prompt DOWNLOADS_PATH "Downloads dizini" "$prev_dl"
    [[ "$DOWNLOADS_PATH" == /* ]] || die "downloads yolu mutlak olmalı"

    prompt WG_PUBLIC_PORT "wg-easy public UDP port" "$prev_wg_port"
    [[ "$WG_PUBLIC_PORT" =~ ^[0-9]+$ ]] || die "wg-easy UDP portu sayı olmalı"
    [[ "$WG_PUBLIC_PORT" -ge 1 && "$WG_PUBLIC_PORT" -le 65535 ]] ||
        die "wg-easy UDP portu 1-65535 arasında olmalı"
    case "$WG_PUBLIC_PORT" in
        53 | 80 | "$SSH_PUBLIC_PORT" | "$QBIT_PUBLIC_PORT" | "$PORTAINER_UI_PORT" | \
        "$FILEBROWSER_UI_PORT" | "$QBIT_UI_PORT" | "$WG_UI_PORT" | "$prev_webdav_port")
            die "wg-easy UDP portu başka bir stack portuyla çakışıyor: $WG_PUBLIC_PORT"
            ;;
    esac
    if [[ "$WG_PUBLIC_PORT" != "$prev_wg_port" ]]; then
        log INFO "wg-easy UDP portu değişti: $prev_wg_port → $WG_PUBLIC_PORT (compose yeniden yazılacak)"
    fi

    prompt WEBDAV_PORT "WebDAV portu (yalnız Tailnet)" "$prev_webdav_port"
    [[ "$WEBDAV_PORT" =~ ^[0-9]+$ ]] || die "WebDAV portu sayı olmalı"
    [[ "$WEBDAV_PORT" -ge 1 && "$WEBDAV_PORT" -le 65535 ]] ||
        die "WebDAV portu 1-65535 arasında olmalı"
    case "$WEBDAV_PORT" in
        53 | 80 | "$SSH_PUBLIC_PORT" | "$WG_PUBLIC_PORT" | "$QBIT_PUBLIC_PORT" | \
        "$PORTAINER_UI_PORT" | "$FILEBROWSER_UI_PORT" | "$QBIT_UI_PORT" | "$WG_UI_PORT")
            die "WebDAV portu başka bir stack portuyla çakışıyor: $WEBDAV_PORT"
            ;;
    esac

    detect_wan
    WG_ENDPOINT_HOST="$WAN_IPV4"

    write_config

    WEBDAV_NEW_USER=""
    WEBDAV_NEW_PASS=""
    if [[ -f "$WEBDAV_HTPASSWD_FILE" ]]; then
        log INFO "Mevcut WebDAV kimlik dosyası korunuyor: $WEBDAV_HTPASSWD_FILE"
    else
        prompt WEBDAV_NEW_USER "WebDAV kullanıcı adı"
        [[ "$WEBDAV_NEW_USER" =~ ^[a-z][a-z0-9._-]{0,31}$ ]] ||
            die "geçersiz WebDAV kullanıcı adı"
        prompt_secret_twice WEBDAV_NEW_PASS "WebDAV parolası"
    fi

    RUN_FULL_UPGRADE=0
    if [[ "${V2_FULL_UPGRADE:-}" == "1" ]]; then
        RUN_FULL_UPGRADE=1
        log INFO "full-upgrade: V2_FULL_UPGRADE=1"
    elif [[ ! -r "$STATE_FILE" ]]; then
        RUN_FULL_UPGRADE=1
        log INFO "full-upgrade: ilk kurulum"
    else
        local upgrade_ans="h"
        prompt upgrade_ans "Debian full-upgrade yapılsın mı? (uzun sürebilir)" "h"
        if [[ "$upgrade_ans" =~ ^[EeYy]$ ]]; then
            RUN_FULL_UPGRADE=1
        else
            log INFO "full-upgrade atlandı (yeniden kurulum)"
        fi
    fi
}

stage_1() {
    log INFO "Aşama 1/7 — sistem ve paketler"
    export DEBIAN_FRONTEND=noninteractive
    retry "apt-update" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
    if [[ "$RUN_FULL_UPGRADE" -eq 1 ]]; then
        retry "apt-upgrade" 2 "$APT_LOCK_TIMEOUT" -- \
            apt-get -y -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold full-upgrade
    fi
    retry "apt-base" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y \
        ca-certificates curl gnupg ethtool iproute2 gawk procps kmod \
        iptables coreutils util-linux diffutils jq rclone \
        apache2-utils dnsutils acl
    timedatectl set-timezone "$TIMEZONE" || log WARN "saat dilimi ayarlanamadı"

    if [[ -n "${WEBDAV_NEW_PASS:-}" ]]; then
        local tmp
        tmp="$(mktemp "$STATE_DIR/.htpasswd-XXXXXX")"
        printf '%s' "$WEBDAV_NEW_PASS" | htpasswd -i -B "$tmp" "$WEBDAV_NEW_USER"
        chmod 0600 "$tmp"
        chown root:root "$tmp"
        mv -f "$tmp" "$WEBDAV_HTPASSWD_FILE"
        unset WEBDAV_NEW_PASS
        WEBDAV_NEW_USER=""
    fi
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
    atomic_write /etc/sysctl.d/99-master-stack-netbuf.conf 0644 <<EOF
net.core.rmem_max = $target_rmem
net.core.wmem_max = $target_wmem
EOF
    sysctl -p /etc/sysctl.d/99-master-stack-netbuf.conf >/dev/null
    log INFO "UDP netbuf floor: rmem_max=$target_rmem wmem_max=$target_wmem"
}

stage_2() {
    log INFO "Aşama 2/7 — Tailscale"
    install_tailscale_repo
    retry "apt-update-ts" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
    # M11/DD-18: buffer tabanı paket kurulumundan önce
    apply_udp_netbuf_floor
    retry "apt-tailscale" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y tailscale
    systemctl enable --now tailscaled

    # Forwarding ayrı dosyada; rmem/wmem yalnız netbuf conf'ta (DD-18).
    atomic_write /etc/sysctl.d/99-master-tailscale.conf 0644 <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-master-tailscale.conf >/dev/null || true
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

stage_3() {
    log INFO "Aşama 3/7 — adresler ve dizinler"
    detect_wan
    detect_tailscale
    write_state

    local d
    for d in \
        "$DOWNLOADS_PATH" \
        "$DOWNLOADS_PATH/media" \
        "$DOWNLOADS_PATH/media/movies" \
        "$DOWNLOADS_PATH/media/series" \
        "$DOWNLOADS_PATH/.unpackerr"; do
        mkdir -p "$d"
    done
    chown -R "${DOWNLOADS_UID}:${DOWNLOADS_GID}" "$DOWNLOADS_PATH"
    find "$DOWNLOADS_PATH" -type d -exec chmod 0775 {} +
    find "$DOWNLOADS_PATH" -type f -exec chmod 0664 {} +
    log INFO "Downloads sahibi ${DOWNLOADS_UID}:${DOWNLOADS_GID} (qBit/FileBrowser/Unpackerr R/W)"
}

stage_4() {
    log INFO "Aşama 4/7 — Docker ve şablonlar"
    install_docker_repo
    retry "apt-update-docker" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
    retry "apt-docker" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    mkdir -p /etc/docker
    atomic_write /etc/docker/daemon.json 0644 <<'EOF'
{
  "dns": ["1.1.1.1", "1.0.0.1"]
}
EOF
    systemctl enable --now docker
    ensure_wg_kernel_modules

    mkdir -p "$COMPOSE_DIR"
    COMPOSE_NEEDS_UP=0
    render_template "$V2_ROOT/templates/compose.yaml" "$COMPOSE_DIR/compose.yaml" 0600 \
        PORTAINER_IMAGE="$PORTAINER_IMAGE" \
        FILEBROWSER_IMAGE="$FILEBROWSER_IMAGE" \
        QBITTORRENT_IMAGE="$QBITTORRENT_IMAGE" \
        UNPACKERR_IMAGE="$UNPACKERR_IMAGE" \
        WG_EASY_IMAGE="$WG_EASY_IMAGE" \
        PORTAINER_UI_PORT="$PORTAINER_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT" \
        QBIT_UI_PORT="$QBIT_UI_PORT" \
        QBIT_PUBLIC_PORT="$QBIT_PUBLIC_PORT" \
        WG_UI_PORT="$WG_UI_PORT" \
        WG_PUBLIC_PORT="$WG_PUBLIC_PORT" \
        WG_BRIDGE_SUBNET="$WG_BRIDGE_SUBNET" \
        WG_BRIDGE_IPV4="$WG_BRIDGE_IPV4" \
        WG_BRIDGE_SUBNET6="$WG_BRIDGE_SUBNET6" \
        WG_BRIDGE_IPV6="$WG_BRIDGE_IPV6" \
        DOWNLOADS_PATH="$DOWNLOADS_PATH" \
        DOWNLOADS_UID="$DOWNLOADS_UID" \
        DOWNLOADS_GID="$DOWNLOADS_GID" \
        QUANTUM_CONFIG_FILE="$QUANTUM_CONFIG_FILE" \
        TIMEZONE="$TIMEZONE"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && COMPOSE_NEEDS_UP=1

    atomic_write "$COMPOSE_DIR/.env" 0600 <<EOF
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST
EOF
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && COMPOSE_NEEDS_UP=1

    # FileBrowser Quantum: panel kökü container /data = host DOWNLOADS_PATH
    if [[ ! -f "$QUANTUM_CONFIG_FILE" ]]; then
        atomic_write "$QUANTUM_CONFIG_FILE" 0644 <<'EOF'
server:
  port: 80
  baseURL: "/"
  cacheDir: "/home/filebrowser/data/cache"
  sources:
    - path: "/data"
auth:
  methods:
    password:
      enabled: true
      minLength: 5
      signup: false
    passkey:
      enabled: false
EOF
    fi

    install -m 0755 "$V2_ROOT/scripts/firewall.sh" "$SBIN_DIR/master-firewall"
    install -m 0755 "$V2_ROOT/scripts/webdav.sh" "$SBIN_DIR/master-webdav"
    install -m 0755 "$V2_ROOT/scripts/refresh-tailnet-config" \
        "$SBIN_DIR/refresh-tailnet-config"
    # Unit içindeki /downloads yolunu operatör seçimine göre yaz
    sed -e "s|/downloads|${DOWNLOADS_PATH}|g" \
        "$V2_ROOT/systemd/master-webdav.service" |
        atomic_write "$UNIT_DIR/master-webdav.service" 0644

    install -m 0644 "$V2_ROOT/systemd/master-firewall.service" \
        "$UNIT_DIR/master-firewall.service"
    install -m 0644 "$V2_ROOT/systemd/refresh-tailnet-config.service" \
        "$UNIT_DIR/refresh-tailnet-config.service"
    install -m 0644 "$V2_ROOT/systemd/refresh-tailnet-config.timer" \
        "$UNIT_DIR/refresh-tailnet-config.timer"
    systemctl disable --now watch-tailnet-addr.service 2>/dev/null || true
    rm -f "$UNIT_DIR/watch-tailnet-addr.service" "$SBIN_DIR/watch-tailnet-addr"
    systemctl daemon-reload
}

stage_5() {
    log INFO "Aşama 5/7 — firewall ve WebDAV"
    ensure_webdav_user
    atomic_write "$WEBDAV_ENV_FILE" 0644 <<EOF
DOWNLOADS_PATH=$DOWNLOADS_PATH
WEBDAV_PORT=$WEBDAV_PORT
TAILSCALE_IF=$TAILSCALE_IF
EOF
    chown root:root "$WEBDAV_HTPASSWD_FILE"
    chmod 0600 "$WEBDAV_HTPASSWD_FILE"
    setfacl -m u:master-webdav:rx "$DOWNLOADS_PATH" 2>/dev/null ||
        chmod o+x "$DOWNLOADS_PATH" 2>/dev/null || true

    systemctl enable --now master-firewall.service
    systemctl enable refresh-tailnet-config.service
    systemctl enable --now refresh-tailnet-config.timer
    systemctl enable --now master-webdav.service
}

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

stage_6() {
    log INFO "Aşama 6/7 — dnsmasq ve Caddy"
    local need_pkg=0
    dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed' || need_pkg=1
    dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q 'install ok installed' || need_pkg=1

    if [[ "$need_pkg" -eq 1 ]]; then
        systemctl stop dnsmasq caddy 2>/dev/null || true
        systemctl mask dnsmasq.service caddy.service >/dev/null 2>&1 || true
        retry "apt-dns-caddy" 2 "$APT_LOCK_TIMEOUT" -- \
            apt_get_install_masked_quiet dnsmasq debian-keyring
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            retry "caddy-gpg" 3 60 -- curl -1sLf \
                'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
                gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            atomic_write /etc/apt/sources.list.d/caddy-stable.list 0644 <<'EOF'
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
            retry "apt-update-caddy" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
        fi
        retry "apt-caddy" 2 "$APT_LOCK_TIMEOUT" -- apt_get_install_masked_quiet caddy
    fi

    mkdir -p /etc/dnsmasq.d
    local dnsmasq_changed=0 caddy_changed=0
    render_template "$V2_ROOT/templates/dnsmasq.conf" "$DNSMASQ_CONF_FILE" 0644 \
        TAILSCALE_IF="$TAILSCALE_IF" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && dnsmasq_changed=1

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        atomic_write /etc/systemd/resolved.conf.d/master-stack.conf 0644 <<'EOF'
[Resolve]
DNSStubListener=no
EOF
        if [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]]; then
            systemctl restart systemd-resolved || true
        fi
    fi

    render_template "$V2_ROOT/templates/Caddyfile" "$CADDYFILE" 0644 \
        CADDY_HTTP_PORT="$CADDY_HTTP_PORT" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        PORTAINER_UI_PORT="$PORTAINER_UI_PORT" \
        WG_UI_PORT="$WG_UI_PORT" \
        QBIT_UI_PORT="$QBIT_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT" \
        WEBDAV_PORT="$WEBDAV_PORT"
    [[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 ]] && caddy_changed=1

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
    atomic_write /etc/systemd/system/caddy.service.d/master-stack.conf 0644 <<EOF
[Unit]
Wants=tailscaled.service
After=tailscaled.service
PartOf=tailscaled.service

[Service]
EnvironmentFile=$STATE_FILE
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
    if [[ "$caddy_changed" -eq 1 ]] || ! systemctl is-active --quiet caddy; then
        systemctl restart caddy
    else
        log INFO "Caddy yapılandırması aynı; yeniden başlatılmadı"
    fi
}

stage_7() {
    log INFO "Aşama 7/7 — doğrulama"
    local need_up="$COMPOSE_NEEDS_UP" running=0
    local expected=5
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
    "$SBIN_DIR/master-firewall" --check

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

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/" || true)"
    [[ "$code" == "401" ]] || die "WebDAV kimlik doğrulamasız yanıt $code (beklenen 401)"

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: webdav.${LOCAL_DOMAIN}" "http://${TAILSCALE_IPV4}/" || true)"
    [[ "$code" == "401" ]] ||
        die "WebDAV Caddy üzerinden kimlik doğrulamasız yanıt $code (beklenen 401)"

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -X PUT --data 'v2-probe' \
        "http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/.v2-write-probe" || true)"
    [[ "$code" =~ ^(401|403|405)$ ]] ||
        die "WebDAV yazma denemesi reddedilmedi (HTTP $code)"

    (cd "$COMPOSE_DIR" && docker port wg-easy) 2>/dev/null |
        grep -q "${WG_PUBLIC_PORT}/udp" ||
        die "wg-easy public UDP ${WG_PUBLIC_PORT} publish yok"
    (cd "$COMPOSE_DIR" && docker port qbittorrent) 2>/dev/null |
        grep -q "${QBIT_PUBLIC_PORT}/tcp" ||
        die "qbittorrent public TCP ${QBIT_PUBLIC_PORT} publish yok"
    (cd "$COMPOSE_DIR" && docker port qbittorrent) 2>/dev/null |
        grep -q "${QBIT_PUBLIC_PORT}/udp" ||
        die "qbittorrent public UDP ${QBIT_PUBLIC_PORT} publish yok"

    for svc in portainer filebrowser; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            [[ "$line" == *127.0.0.1:* ]] ||
                die "UI publish yalnız loopback olmalı: $svc ($line)"
        done < <((cd "$COMPOSE_DIR" && docker port "$svc") 2>/dev/null || true)
    done
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *"${QBIT_PUBLIC_PORT}/"* ]] && continue
        [[ "$line" == *127.0.0.1:* ]] ||
            die "qBit UI publish yalnız loopback olmalı ($line)"
    done < <((cd "$COMPOSE_DIR" && docker port qbittorrent) 2>/dev/null || true)
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *"${WG_PUBLIC_PORT}/"* ]] && continue
        [[ "$line" == *127.0.0.1:* ]] ||
            die "wg-easy UI publish yalnız loopback olmalı ($line)"
    done < <((cd "$COMPOSE_DIR" && docker port wg-easy) 2>/dev/null || true)

    log INFO "Temel doğrulamalar geçti"
}

print_summary() {
    log INFO "Kurulum tamam — v$V2_VERSION"
    cat <<EOF

WAN:          $WAN_INTERFACE $WAN_IPV4
Tailscale:    $TAILSCALE_IPV4 ${TAILSCALE_IPV6:-"(IPv6 yok)"}
Domain:       $LOCAL_DOMAIN
Downloads:    $DOWNLOADS_PATH
wg UDP:       ${WG_PUBLIC_PORT} (endpoint ipucu: $WG_ENDPOINT_HOST)
qBit peer:    ${QBIT_PUBLIC_PORT}/tcp+udp
Compose:      $COMPOSE_DIR/compose.yaml
State:        $STATE_FILE
Log:          $V2_LOG_FILE

Manuel Tailscale Admin:
  1) DNS → Nameservers → Custom: $TAILSCALE_IPV4
  2) Restrict to domain: $LOCAL_DOMAIN
  3) Exit node olarak bu makineyi onayla

Uyarı: Portainer / wg-easy / FileBrowser ilk yönetici hesabını sen kur.
qBittorrent varsayılan WebUI parolasını değiştir.
WebDAV: http://webdav.${LOCAL_DOMAIN} (Infuse)
wg-easy ilk kurulum: Host=${WG_ENDPOINT_HOST}, Port=${WG_PUBLIC_PORT}
  (UDP ${WG_PUBLIC_PORT}:${WG_PUBLIC_PORT} — WAN IP compose'a gömülmez; port değişince yeniden kur)
Tailscale IP: refresh-tailnet-config (WantedBy=tailscaled + 5dk timer) → Caddy/WebDAV

EOF
}

main() {
    log INFO "master-stack v2 $V2_VERSION başlıyor"
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
        --who=master-stack-v2 \
        --why="master-stack v2 kurulum işlemi" \
        --mode=block \
        env V2_INHIBITED=1 bash "$self" "$@"
fi

main "$@"
