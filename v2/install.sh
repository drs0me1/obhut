#!/usr/bin/env bash
# v2 kurulum — Debian 13, doğrusal aşamalar, tekrar çalıştırılabilir.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

V2_VERSION="2026.08.06-v2-1"
V2_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "$V2_ROOT/common.sh"
# shellcheck source=config/defaults.env
source "$V2_ROOT/config/defaults.env"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
V2_LOG_FILE="${V2_LOG_FILE:-$LOG_DIR/install.log}"

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
WEBDAV_PORT=$WEBDAV_PORT
CHAIN_INPUT=$CHAIN_INPUT
CHAIN_DOCKER=$CHAIN_DOCKER
EOF
}

write_config() {
    atomic_write "$CONFIG_FILE" 0600 <<EOF
LOCAL_DOMAIN=$LOCAL_DOMAIN
DOWNLOADS_PATH=$DOWNLOADS_PATH
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST
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

apply_udp_gro() {
    local netdev
    netdev="$(
        ip -4 -o route get 8.8.8.8 2>/dev/null |
            awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
    )" || true
    [[ -n "$netdev" ]] || { log WARN "UDP GRO: varsayılan arayüz yok"; return 0; }
    if ethtool -K "$netdev" rx-udp-gro-forwarding on rx-gro-list off; then
        log INFO "UDP GRO uygulandı: $netdev"
    else
        log WARN "UDP GRO uygulanamadı: $netdev"
    fi
}

install_tailscale_repo() {
    retry "tailscale-gpg" 3 60 -- \
        curl -fsSL "https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
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

    local prev_domain="$DEFAULT_LOCAL_DOMAIN" prev_dl="$DOWNLOADS_PATH_DEFAULT" prev_wg=""
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        prev_domain="${LOCAL_DOMAIN:-$prev_domain}"
        prev_dl="${DOWNLOADS_PATH:-$prev_dl}"
        prev_wg="${WG_ENDPOINT_HOST:-}"
    fi

    prompt LOCAL_DOMAIN "Yerel alan adı" "$prev_domain"
    [[ "$LOCAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die "geçersiz alan adı: $LOCAL_DOMAIN"
    prompt DOWNLOADS_PATH "Downloads dizini" "$prev_dl"
    [[ "$DOWNLOADS_PATH" == /* ]] || die "downloads yolu mutlak olmalı"

    detect_wan
    if [[ -n "$prev_wg" ]]; then
        prompt WG_ENDPOINT_HOST "wg-easy endpoint (IP veya DNS)" "$prev_wg"
    else
        prompt WG_ENDPOINT_HOST "wg-easy endpoint (IP veya DNS)" "$WAN_IPV4"
    fi

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
}

stage_1() {
    log INFO "Aşama 1/7 — sistem ve paketler"
    export DEBIAN_FRONTEND=noninteractive
    retry "apt-update" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
    retry "apt-upgrade" 2 "$APT_LOCK_TIMEOUT" -- \
        apt-get -y -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold full-upgrade
    retry "apt-base" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y \
        ca-certificates curl gnupg ethtool iproute2 gawk procps kmod \
        iptables ip6tables coreutils util-linux diffutils jq rclone \
        apache2-utils dnsutils
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

stage_2() {
    log INFO "Aşama 2/7 — Tailscale"
    install_tailscale_repo
    retry "apt-update-ts" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
    retry "apt-tailscale" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y tailscale
    systemctl enable --now tailscaled

    cat >/etc/sysctl.d/99-master-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
    sysctl --system >/dev/null || true
    apply_udp_gro

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
        "$DOWNLOADS_PATH/media/series"; do
        if [[ ! -e "$d" ]]; then
            mkdir -p "$d"
            chmod 0755 "$d"
        fi
    done
    log INFO "Mevcut medya ağacında recursive chown YOK"
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

    mkdir -p "$COMPOSE_DIR"
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
        DOWNLOADS_PATH="$DOWNLOADS_PATH" \
        QUANTUM_CONFIG_FILE="$QUANTUM_CONFIG_FILE" \
        TIMEZONE="$TIMEZONE"

    atomic_write "$COMPOSE_DIR/.env" 0600 <<EOF
WAN_IPV4=$WAN_IPV4
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST
EOF

    # Minimal FileBrowser Quantum config (operatör ilk girişte hesabı kurar)
    if [[ ! -f "$QUANTUM_CONFIG_FILE" ]]; then
        atomic_write "$QUANTUM_CONFIG_FILE" 0644 <<EOF
server:
  port: 80
  sources:
    - path: /data
EOF
    fi

    install -m 0755 "$V2_ROOT/scripts/firewall.sh" "$SBIN_DIR/master-firewall"
    install -m 0755 "$V2_ROOT/scripts/webdav.sh" "$SBIN_DIR/master-webdav"
    # Unit içindeki /downloads yolunu operatör seçimine göre yaz
    sed -e "s|/downloads|${DOWNLOADS_PATH}|g" \
        "$V2_ROOT/systemd/master-webdav.service" |
        atomic_write "$UNIT_DIR/master-webdav.service" 0644

    atomic_write /etc/systemd/system/master-firewall.service 0644 <<EOF
[Unit]
Description=Master stack firewall
After=network-online.target docker.service
Wants=network-online.target
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=STATE_FILE=$STATE_FILE
ExecStart=$SBIN_DIR/master-firewall apply
ExecStartPost=$SBIN_DIR/master-firewall --check

[Install]
WantedBy=multi-user.target
EOF
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
    # servis kullanıcısı downloads'u okuyabilsin
    # Yalnız kurulumun oluşturduğu erişim: recursive chown yok.
    setfacl -m u:master-webdav:rx "$DOWNLOADS_PATH" 2>/dev/null ||
        chmod o+x "$DOWNLOADS_PATH" 2>/dev/null || true

    systemctl enable master-firewall.service
    "$SBIN_DIR/master-firewall" apply
    systemctl enable --now master-webdav.service
}

stage_6() {
    log INFO "Aşama 6/7 — dnsmasq ve Caddy"
    systemctl mask --now dnsmasq 2>/dev/null || true
    systemctl mask --now caddy 2>/dev/null || true

    retry "apt-dns-caddy" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y dnsmasq debian-keyring
    # Caddy resmi depo
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
        retry "caddy-gpg" 3 60 -- curl -1sLf \
            'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
            gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        atomic_write /etc/apt/sources.list.d/caddy-stable.list 0644 <<'EOF'
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
        retry "apt-update-caddy" 3 "$APT_LOCK_TIMEOUT" -- apt-get update
    fi
    retry "apt-caddy" 2 "$APT_LOCK_TIMEOUT" -- apt-get install -y caddy

    mkdir -p /etc/dnsmasq.d
    render_template "$V2_ROOT/templates/dnsmasq.conf" "$DNSMASQ_CONF_FILE" 0644 \
        TAILSCALE_IF="$TAILSCALE_IF" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN"

    # systemd-resolved 53 çakışmasını azalt
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        atomic_write /etc/systemd/resolved.conf.d/master-stack.conf 0644 <<'EOF'
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved || true
    fi

    render_template "$V2_ROOT/templates/Caddyfile" "$CADDYFILE" 0644 \
        CADDY_HTTP_PORT="$CADDY_HTTP_PORT" \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" \
        PORTAINER_UI_PORT="$PORTAINER_UI_PORT" \
        WG_UI_PORT="$WG_UI_PORT" \
        QBIT_UI_PORT="$QBIT_UI_PORT" \
        FILEBROWSER_UI_PORT="$FILEBROWSER_UI_PORT" \
        WEBDAV_PORT="$WEBDAV_PORT"

    mkdir -p /etc/systemd/system/caddy.service.d
    atomic_write /etc/systemd/system/caddy.service.d/master-stack.conf 0644 <<EOF
[Service]
EnvironmentFile=$STATE_FILE
EOF

    systemctl unmask dnsmasq caddy
    systemctl enable dnsmasq caddy
    systemctl restart dnsmasq
    systemctl restart caddy
}

stage_7() {
    log INFO "Aşama 7/7 — doğrulama"
    (cd "$COMPOSE_DIR" && docker compose up -d)
    "$SBIN_DIR/master-firewall" --check

    local name
    for name in portainer wg qbit file webdav health; do
        local ans
        ans="$(dig +short "${name}.${LOCAL_DOMAIN}" @127.0.0.1 | head -n1 || true)"
        [[ "$ans" == "$TAILSCALE_IPV4" ]] ||
            die "DNS: ${name}.${LOCAL_DOMAIN} -> '${ans}' (beklenen $TAILSCALE_IPV4)"
    done

    local health
    health="$(curl -fsS --max-time 5 "http://${TAILSCALE_IPV4}/" -H "Host: health.${LOCAL_DOMAIN}" || true)"
    [[ "$health" == "ok" ]] || die "Caddy health yanıtı beklenen gibi değil"

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/" || true)"
    [[ "$code" == "401" ]] || die "WebDAV kimlik doğrulamasız yanıt $code (beklenen 401)"

    log INFO "Temel doğrulamalar geçti"
}

print_summary() {
    log INFO "Kurulum tamam — v$V2_VERSION"
    cat <<EOF

WAN:          $WAN_INTERFACE $WAN_IPV4
Tailscale:    $TAILSCALE_IPV4 ${TAILSCALE_IPV6:-"(IPv6 yok)"}
Domain:       $LOCAL_DOMAIN
Downloads:    $DOWNLOADS_PATH
wg endpoint:  $WG_ENDPOINT_HOST
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

main "$@"
