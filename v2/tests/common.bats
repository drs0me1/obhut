#!/usr/bin/env bats
# Kritik common.sh davranışları — framework değil, dar güvenlik/doğruluk seti.

bats_require_minimum_version 1.5.0

setup() {
    V2_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # shellcheck source=../common.sh
    source "$V2_ROOT/common.sh"
    TMP="$(mktemp -d)"
    V2_RETRY_BACKOFF_SECONDS=0
}

teardown() {
    rm -rf "$TMP"
}

@test "log does not treat message as format string" {
    run log INFO '%s%s'
    [ "$status" -eq 0 ]
    [[ "$output" == *'%s%s'* ]]
}

@test "die exits non-zero" {
    run die "bitti"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bitti"* ]]
}

@test "require_debian_trixie accepts trixie 13" {
    cat >"$TMP/os" <<'EOF'
ID=debian
VERSION_CODENAME=trixie
VERSION_ID="13"
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    run require_debian_trixie
    [ "$status" -eq 0 ]
}

@test "require_debian_trixie rejects ubuntu" {
    cat >"$TMP/os" <<'EOF'
ID=ubuntu
VERSION_CODENAME=trixie
VERSION_ID="13"
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    run require_debian_trixie
    [ "$status" -eq 1 ]
}

@test "require_debian_trixie does not source os-release" {
    cat >"$TMP/os" <<EOF
ID=debian
VERSION_CODENAME=trixie
VERSION_ID="13"
X=\$(touch $TMP/pwned)
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    run require_debian_trixie
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/pwned" ]
}

@test "atomic_write creates file with mode" {
    printf 'x\n' | atomic_write "$TMP/f" 0600
    [ "$(cat "$TMP/f")" = "x" ]
    [ "$(stat -f '%Lp' "$TMP/f" 2>/dev/null || stat -c '%a' "$TMP/f")" = "600" ]
}

@test "atomic_write refuses symlink target" {
    printf 'a\n' >"$TMP/real"
    ln -s "$TMP/real" "$TMP/link"
    run bash -c "source '$V2_ROOT/common.sh'; printf y | atomic_write '$TMP/link' 0644"
    [ "$status" -ne 0 ]
    [ "$(cat "$TMP/real")" = "a" ]
}

@test "atomic_write leaves no temp on failure" {
    run bash -c "source '$V2_ROOT/common.sh'; printf y | atomic_write '/' 0644"
    [ "$status" -ne 0 ]
    # TMP scratch should not accumulate .v2- temps from that call (different dir)
    true
}

@test "atomic_write skips replace when content identical" {
    atomic_write "$TMP/f" 0644 <<<"same"
    local before
    before="$(stat -f '%i' "$TMP/f" 2>/dev/null || stat -c '%i' "$TMP/f")"
    atomic_write "$TMP/f" 0644 <<<"same"
    local after
    after="$(stat -f '%i' "$TMP/f" 2>/dev/null || stat -c '%i' "$TMP/f")"
    [ "$before" = "$after" ]
    [ "$V2_LAST_ATOMIC_CHANGED" -eq 0 ]
}

@test "atomic_write sets changed flag on replace" {
    atomic_write "$TMP/f" 0644 <<<"a"
    [ "$V2_LAST_ATOMIC_CHANGED" -eq 1 ]
    atomic_write "$TMP/f" 0644 <<<"b"
    [ "$V2_LAST_ATOMIC_CHANGED" -eq 1 ]
}

@test "render_template replaces tokens" {
    printf 'a=__A__ b=__B__\n' >"$TMP/t"
    render_template "$TMP/t" "$TMP/o" 0644 A=1 B=two
    [ "$(cat "$TMP/o")" = "a=1 b=two" ]
}

@test "render_template rejects leftover token" {
    printf 'a=__A__ b=__B__\n' >"$TMP/t"
    run render_template "$TMP/t" "$TMP/o" 0644 A=1
    [ "$status" -ne 0 ]
}

@test "render_template keeps ampersand and slash in values" {
    printf 'v=__V__\n' >"$TMP/t"
    render_template "$TMP/t" "$TMP/o" 0644 'V=/a/b&c'
    [ "$(cat "$TMP/o")" = 'v=/a/b&c' ]
}

@test "acquire_lock rejects relative path" {
    run acquire_lock "rel/lock" 1
    [ "$status" -ne 0 ]
}

@test "acquire_lock fails closed without flock" {
    command -v flock >/dev/null 2>&1 && skip "flock var; negatif yol Debian'da ayrı"
    run acquire_lock "$TMP/k" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"flock"* ]]
}

@test "retry preserves argument boundaries" {
    command -v timeout >/dev/null 2>&1 || skip "timeout yok"
    run retry etiket 1 5 -- printf '%s\n' 'a b' c
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "a b" ]
    [ "${lines[1]}" = "c" ]
}

@test "retry fails after attempts" {
    command -v timeout >/dev/null 2>&1 || skip "timeout yok"
    run retry etiket 2 2 -- false
    [ "$status" -ne 0 ]
}

@test "retry runs bash functions via timeout" {
    command -v timeout >/dev/null 2>&1 || skip "timeout yok"
    _v2_retry_fn() { printf '%s\n' "ok:$1"; }
    run retry etiket 1 5 -- _v2_retry_fn hi
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:hi"* ]]
}

@test "compose publishes qbit peer TCP and UDP 1:1" {
    grep -q '"0.0.0.0:__QBIT_PUBLIC_PORT__:__QBIT_PUBLIC_PORT__/tcp"' \
        "$V2_ROOT/templates/compose.yaml"
    grep -q '"0.0.0.0:__QBIT_PUBLIC_PORT__:__QBIT_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "firewall allows qbit peer TCP and UDP on WAN" {
    grep -q 'tcp --dport "$QBIT_PUBLIC_PORT"' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'udp --dport "$QBIT_PUBLIC_PORT"' "$V2_ROOT/scripts/firewall.sh"
    # DOCKER-USER: both protocols for NEW --ctorigdstport
    [[ "$(grep -c 'ctorigdstport "$QBIT_PUBLIC_PORT"' \
        "$V2_ROOT/scripts/firewall.sh")" -ge 2 ]]
}

@test "firewall requires ports and chains from state" {
    grep -q 'CHAIN_INPUT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'QBIT_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX' "$V2_ROOT/install.sh"
    ! grep -qE 'WG_PUBLIC_PORT:=65171|QBIT_PUBLIC_PORT:=65173|CHAIN_INPUT:=MASTER' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX}IN-' "$V2_ROOT/scripts/firewall.sh"
}

@test "qbittorrent and unpackerr use DOWNLOADS_UID/GID tokens" {
    grep -q 'PUID: "__DOWNLOADS_UID__"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'PGID: "__DOWNLOADS_GID__"' "$V2_ROOT/templates/compose.yaml"
    grep -c 'user: "__DOWNLOADS_UID__:__DOWNLOADS_GID__"' \
        "$V2_ROOT/templates/compose.yaml" | grep -q '^[2-9]'
    ! grep -qE 'PUID: "1000"|PGID: "1000"|user: "1000:1000"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "downloads tree is chown 1000 for qbit filebrowser unpackerr" {
    grep -q 'DOWNLOADS_UID=1000' "$V2_ROOT/config/defaults.env"
    grep -q 'DOWNLOADS_GID=1000' "$V2_ROOT/config/defaults.env"
    grep -q 'chown -R "${DOWNLOADS_UID}:${DOWNLOADS_GID}"' "$V2_ROOT/install.sh"
    grep -q 'user: "__DOWNLOADS_UID__:__DOWNLOADS_GID__"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "downloads path rejects unsafe characters and compose has no .env" {
    grep -q 'downloads yolu yalnızca' "$V2_ROOT/install.sh"
    grep -q "downloads yolu '..' içeremez" "$V2_ROOT/install.sh"
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'rm -f "$COMPOSE_DIR/.env"'
    ! awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'atomic_write "$COMPOSE_DIR/.env"'
}

@test "compose publishes portainer https on 9443" {
    ! grep -q -- '--http-enabled' "$V2_ROOT/templates/compose.yaml"
    grep -q '127.0.0.1:__PORTAINER_UI_PORT__:9443' "$V2_ROOT/templates/compose.yaml"
}

@test "caddy proxies portainer over https with skip-verify" {
    grep -q 'reverse_proxy https://127.0.0.1:__PORTAINER_UI_PORT__' \
        "$V2_ROOT/templates/Caddyfile"
    grep -q 'tls_insecure_skip_verify' "$V2_ROOT/templates/Caddyfile"
}

@test "unpackerr watches folders, not the qBittorrent API" {
    grep -q 'UN_FOLDER_0_PATH: "/downloads"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'UN_FOLDER_0_MOVE_BACK: "true"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'UN_FOLDER_0_DELETE_ORIGINAL: "false"' "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'UN_QBITTORRENT_' "$V2_ROOT/templates/compose.yaml"
}

@test "filebrowser serves full downloads at /data" {
    grep -q '__DOWNLOADS_PATH__:/data' "$V2_ROOT/templates/compose.yaml"
    grep -q 'FILEBROWSER_CONFIG: /config.yaml' "$V2_ROOT/templates/compose.yaml"
    grep -q '__QUANTUM_CONFIG_FILE__:/config.yaml:ro' "$V2_ROOT/templates/compose.yaml"
    grep -q 'filebrowser_data:/home/filebrowser/data' "$V2_ROOT/templates/compose.yaml"
}

@test "wg-easy publishes WireGuard UDP 1:1 without remap" {
    grep -q '"0.0.0.0:__WG_PUBLIC_PORT__:__WG_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'WAN_IPV4' "$V2_ROOT/templates/compose.yaml"
    ! grep -q ':51820/udp' "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'WG_PORT:' "$V2_ROOT/templates/compose.yaml"
}

@test "wg-easy healthcheck matches legacy H5 timing" {
    grep -q 'start_interval: 5s' "$V2_ROOT/templates/compose.yaml"
    grep -q 'start_period: 60s' "$V2_ROOT/templates/compose.yaml"
    grep -q 'wg show | /bin/grep -q interface' "$V2_ROOT/templates/compose.yaml"
}

@test "wg-easy bridge addresses come from defaults.env tokens" {
    grep -q 'WG_BRIDGE_IPV4=' "$V2_ROOT/config/defaults.env"
    grep -q 'WG_BRIDGE_SUBNET=' "$V2_ROOT/config/defaults.env"
    grep -q 'ipv4_address: __WG_BRIDGE_IPV4__' "$V2_ROOT/templates/compose.yaml"
    grep -q 'ipv6_address: __WG_BRIDGE_IPV6__' "$V2_ROOT/templates/compose.yaml"
    grep -q 'subnet: __WG_BRIDGE_SUBNET__' "$V2_ROOT/templates/compose.yaml"
    grep -q 'subnet: __WG_BRIDGE_SUBNET6__' "$V2_ROOT/templates/compose.yaml"
    grep -q 'WG_BRIDGE_IPV4=' "$V2_ROOT/install.sh"
    grep -q 'name: wg' "$V2_ROOT/templates/compose.yaml"
    grep -q 'enable_ipv6: true' "$V2_ROOT/templates/compose.yaml"
}

@test "SERVICE_NAMES drives DNS check and matches edge templates" {
    grep -q 'for name in \$SERVICE_NAMES' "$V2_ROOT/install.sh"
    # shellcheck source=/dev/null
    source "$V2_ROOT/config/defaults.env"
    [[ -n "$SERVICE_NAMES" ]]
    local name
    for name in $SERVICE_NAMES; do
        grep -q "interface-name=${name}.__LOCAL_DOMAIN__" \
            "$V2_ROOT/templates/dnsmasq.conf"
        grep -q "http://${name}.__LOCAL_DOMAIN__" \
            "$V2_ROOT/templates/Caddyfile"
    done
    ! grep -q 'CONTAINER_NAMES=' "$V2_ROOT/config/defaults.env"
}

@test "compose public UDP ports are not bound to WAN_IPV4" {
    grep -q '"0.0.0.0:__QBIT_PUBLIC_PORT__:__QBIT_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
    ! grep -q '\${WAN_IPV4}' "$V2_ROOT/templates/compose.yaml"
}

@test "compose public peer ports are IPv4-only" {
    grep -q '0.0.0.0:__QBIT_PUBLIC_PORT__' "$V2_ROOT/templates/compose.yaml"
    grep -q '0.0.0.0:__WG_PUBLIC_PORT__' "$V2_ROOT/templates/compose.yaml"
    # Unqualified host:port would also bind [::] on Docker.
    ! grep -qE '^[[:space:]]*- "__QBIT_PUBLIC_PORT__:__QBIT_PUBLIC_PORT__/' \
        "$V2_ROOT/templates/compose.yaml"
    ! grep -qE '^[[:space:]]*- "__WG_PUBLIC_PORT__:__WG_PUBLIC_PORT__/' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "refresh-tailnet-config does not touch compose or firewall" {
    ! grep -qE 'compose|master-firewall|DOCKER-USER|master-webdav' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'BOUND_UNITS="caddy.service"' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "refresh-tailnet timer is five minutes" {
    grep -q 'OnUnitActiveSec=5min' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'WantedBy=timers.target' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'refresh-tailnet-config.timer' "$V2_ROOT/install.sh"
}

@test "MASTER-INPUT accepts the Tailscale UDP port on its own" {
    # Otherwise direct peer connectivity depends entirely on ts-input being
    # present and ordered first; with ts-input gone the WAN DROP swallows it.
    grep -q 'TAILSCALE_UDP_PORT="41641"' "$V2_ROOT/config/defaults.env"
    grep -q 'TAILSCALE_UDP_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'TAILSCALE_UDP_PORT=\$TAILSCALE_UDP_PORT' "$V2_ROOT/install.sh"
    local v4 v6
    v4="$(awk '/^apply_input4\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    v6="$(awk '/^apply_input6\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    grep -q 'TAILSCALE_UDP_PORT" -j ACCEPT' <<<"$v4"
    grep -q 'TAILSCALE_UDP_PORT" -j ACCEPT' <<<"$v6"
    grep -q 'check_rule iptables "$CHAIN_INPUT"' "$V2_ROOT/scripts/firewall.sh"
    # The port must not be selectable as a stack port.
    grep -q '"\$TAILSCALE_UDP_PORT")' "$V2_ROOT/install.sh"
}

@test "refresh-tailnet warns when the tailnet is unusable" {
    grep -q 'warn_if_tailnet_unusable' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'BackendState' "$V2_ROOT/scripts/refresh-tailnet-config"
    # A warning only; the helper must not try to repair Tailscale itself.
    ! grep -qE 'tailscale (up|set|login)' "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "refresh-tailnet uses restart, never try-restart" {
    # try-restart is a no-op on a failed unit AND returns 0, so the old
    # "try-restart || restart" fallback was unreachable and a failed unit was
    # never resurrected when the address came back.
    ! grep -q 'try-restart' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'systemctl restart "$unit"' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'recover_failed_bound_units' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'is-failed' "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "caddy waits for the tailnet address and fails visibly" {
    [ -x "$V2_ROOT/scripts/wait-tailnet-addr" ]
    grep -q 'wait-tailnet-addr' "$V2_ROOT/install.sh"
    local block
    block="$(awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh")"
    grep -q 'ExecStartPre=.*wait-tailnet-addr' <<<"$block"
    grep -q 'StartLimitBurst=' <<<"$block"
    grep -q 'StartLimitIntervalSec=' <<<"$block"
    grep -q 'TimeoutStartSec=' <<<"$block"
}

@test "refresh-tailnet soft-skips missing Tailscale IPv4" {
    grep -q 'atlanıyor' "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "refresh-tailnet waits for tailscale IP before reading state" {
    grep -q 'tailscale wait --timeout=' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'wait_for_tailscale_ready' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'REFRESH_TAILNET_WAIT_TIMEOUT=120s' \
        "$V2_ROOT/systemd/refresh-tailnet-config.service"
    grep -q 'TimeoutStartSec=150s' \
        "$V2_ROOT/systemd/refresh-tailnet-config.service"
    # Soft-skip after wait failure must not fail the oneshot hard.
    awk '/^wait_for_tailscale_ready/,/^warn_if_tailnet_unusable/' \
        "$V2_ROOT/scripts/refresh-tailnet-config" |
        grep -q 'return 1'
    grep -q 'if ! wait_for_tailscale_ready; then' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "udp netbuf floor is 16MiB and applied before tailscale install" {
    grep -q 'NET_BUF_FLOOR_BYTES=16777216' "$V2_ROOT/config/defaults.env"
    grep -q '99-master-stack-netbuf.conf' "$V2_ROOT/install.sh"
    grep -q 'apply_udp_netbuf_floor' "$V2_ROOT/install.sh"
    # Ordering: floor call appears before apt-get install tailscale
    awk '/apply_udp_netbuf_floor$/{f=NR} /apt-get install -y tailscale/{t=NR}
         END { exit !(f && t && f < t) }' "$V2_ROOT/install.sh"
    ! grep -q 'rmem_max = 7500000' "$V2_ROOT/install.sh"
}

@test "watch-tailnet-addr is removed; refresh timer remains" {
    [ ! -e "$V2_ROOT/scripts/watch-tailnet-addr" ]
    [ ! -e "$V2_ROOT/systemd/watch-tailnet-addr.service" ]
    ! grep -q 'enable --now watch-tailnet-addr' "$V2_ROOT/install.sh"
    grep -q 'disable --now watch-tailnet-addr.service' "$V2_ROOT/install.sh"
    grep -q 'OnUnitActiveSec=5min' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'WantedBy=tailscaled.service' \
        "$V2_ROOT/systemd/refresh-tailnet-config.service"
}

@test "tailscale-udp-gro unit is WantedBy multi-user" {
    grep -q 'WantedBy=multi-user.target' \
        "$V2_ROOT/systemd/tailscale-udp-gro.service"
    grep -q 'rx-udp-gro-forwarding on' "$V2_ROOT/scripts/tailscale-udp-gro"
    grep -q 'tailscale-udp-gro.service' "$V2_ROOT/install.sh"
    ! grep -q 'apply_udp_gro' "$V2_ROOT/install.sh"
}

@test "dnsmasq binds lo and tailscale only" {
    grep -q 'interface=lo' "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'interface=__TAILSCALE_IF__' "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'bind-dynamic' "$V2_ROOT/templates/dnsmasq.conf"
}

@test "webdav compose service is loopback rclone with htpasswd" {
    grep -q 'container_name: webdav' "$V2_ROOT/templates/compose.yaml"
    grep -q 'RCLONE_IMAGE=' "$V2_ROOT/config/defaults.env"
    grep -qE '^RCLONE_IMAGE="rclone/rclone:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}"' \
        "$V2_ROOT/config/defaults.env"
    grep -q 'rclone/rclone:1.74.4@sha256:' "$V2_ROOT/config/defaults.env"
    grep -q '__RCLONE_IMAGE__' "$V2_ROOT/templates/compose.yaml"
    grep -q '127.0.0.1:__WEBDAV_PORT__:8080' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--htpasswd=/run/secrets/webdav_htpasswd' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--read-only' "$V2_ROOT/templates/compose.yaml"
    grep -q '__DOWNLOADS_PATH__:/downloads:ro' "$V2_ROOT/templates/compose.yaml"
    grep -q 'reverse_proxy 127.0.0.1:__WEBDAV_PORT__' "$V2_ROOT/templates/Caddyfile"
    grep -q 'http://webdav.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}' \
        "$V2_ROOT/templates/Caddyfile"
    ! grep -q 'reverse_proxy {$TAILSCALE_IPV4}:__WEBDAV_PORT__' \
        "$V2_ROOT/templates/Caddyfile"
    grep -q 'purge_host_webdav_leftovers' "$V2_ROOT/install.sh"
    grep -q 'disable --now master-webdav.service' "$V2_ROOT/install.sh"
    grep -q 'apt-get purge -y rclone' "$V2_ROOT/install.sh"
    grep -q 'userdel "$user"' "$V2_ROOT/install.sh"
    grep -q 'setfacl -R -x' "$V2_ROOT/install.sh"
    ! grep -qE 'apt-get install -y[^\n]*\brclone\b' "$V2_ROOT/install.sh"
    grep -q "wget -q -S -O /dev/null http://127.0.0.1:8080/" \
        "$V2_ROOT/templates/compose.yaml"
    grep -q "grep -q '401'" "$V2_ROOT/templates/compose.yaml"
    awk '
      /^  webdav:/ {in_webdav=1; next}
      in_webdav && /^  [a-z]/ {in_webdav=0}
      in_webdav && /healthcheck:/ {found=1}
      END {exit found ? 0 : 1}
    ' "$V2_ROOT/templates/compose.yaml"
    awk '
      /^  webdav:/ {in_webdav=1; next}
      in_webdav && /^  [a-z]/ {in_webdav=0}
      in_webdav && /mem_limit:|memory:|pids_limit:/ {bad=1}
      END {exit bad ? 1 : 0}
    ' "$V2_ROOT/templates/compose.yaml"
    grep -qE '^[[:space:]]*- webdav$' "$V2_ROOT/templates/compose.yaml"
    awk '
      /^networks:/ {in_nets=1; next}
      in_nets && /^[a-z]/ {in_nets=0}
      in_nets && /^  webdav:/ {found=1}
      in_nets && found && /name: webdav/ {named=1}
      in_nets && found && /internal: true/ {bad=1}
      END {exit (named && !bad) ? 0 : 1}
    ' "$V2_ROOT/templates/compose.yaml"
    ! awk '
      /^  webdav:/ {in_webdav=1; next}
      in_webdav && /^  [a-z]/ {in_webdav=0}
      in_webdav && /networks:/ {in_nets=1; next}
      in_webdav && in_nets && /^[[:space:]]+- wg$/ {bad=1}
      END {exit bad ? 0 : 1}
    ' "$V2_ROOT/templates/compose.yaml"
    grep -q 'wait_webdav_healthy' "$V2_ROOT/install.sh"
    grep -q 'assert_webdav_network' "$V2_ROOT/install.sh"
}

@test "IPv6 MASTER-DOCKER drops WAN only, not bridge egress" {
    # An unconditional DROP here also kills wg-easy peer IPv6 egress.
    local body
    body="$(awk '/^apply_docker6\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    [[ -n "$body" ]]
    ! grep -qE '\-A "\$staging" -j DROP$' <<<"$body"
    grep -q -- '-i "$WAN_INTERFACE" -j DROP' <<<"$body"
    grep -qE '\-A "\$staging" -j RETURN$' <<<"$body"
    # --check must assert the WAN-scoped shape so the regression cannot return.
    grep -q 'check_rule ip6tables "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -j DROP' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_rule ip6tables "$CHAIN_INPUT" -i "$WAN_INTERFACE" -j DROP' \
        "$V2_ROOT/scripts/firewall.sh"
}

@test "firewall script does not flush DOCKER-USER" {
    ! grep -qE 'DOCKER-USER.*-F|-F DOCKER-USER' "$V2_ROOT/scripts/firewall.sh"
}

@test "ts-input precedence does not delete-all MASTER-INPUT jumps" {
    grep -q 'ensure_ts_input_precedence' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'insert_pos_after_ts_input' "$V2_ROOT/scripts/firewall.sh"
    ! awk '/^ensure_ts_input_precedence\(\)/,/^create_staging\(\)/' \
        "$V2_ROOT/scripts/firewall.sh" |
        grep -qE 'while .*-D INPUT -j "\$CHAIN_INPUT"'
}

@test "master-firewall unit is WantedBy docker.service" {
    grep -q 'WantedBy=docker.service' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'WantedBy=tailscaled.service' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'Wants=network-online.target docker.service' \
        "$V2_ROOT/systemd/master-firewall.service"
    ! grep -q 'Requires=docker.service' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'PartOf=docker.service' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'PartOf=tailscaled.service' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'After=.*tailscaled.service' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'Restart=on-failure' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'RestartSec=2s' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'StartLimitBurst=5' "$V2_ROOT/systemd/master-firewall.service"
    grep -q 'master-firewall.service' "$V2_ROOT/install.sh"
    # Compose must not be PartOf/Requires-coupled to the firewall unit.
    ! grep -qiE 'compose|master-compose' "$V2_ROOT/systemd/master-firewall.service"
}

@test "firewall waits for DOCKER-USER only when Docker is active" {
    grep -q 'wait_for_docker_user' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'DOCKER_USER_WAIT_SECONDS' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'docker_service_active' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'MASTER-DOCKER atlandı' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'MASTER-DOCKER denetimi atlandı' "$V2_ROOT/scripts/firewall.sh"
    # Host INPUT must be applied before Docker stages.
    awk '
        /^apply_input4$/ { i4=NR }
        /^apply_input6$/ { i6=NR }
        /^apply_docker4$/ { d4=NR }
        /^apply_docker6$/ { d6=NR }
        END {
            exit !(i4 && i6 && d4 && d6 && i4 < i6 && i6 < d4 && d4 < d6)
        }
    ' "$V2_ROOT/scripts/firewall.sh"
}

@test "firewall --check asserts critical IPv4 ACCEPT/DROP rules" {
    grep -q 'check_rule()' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'kritik politikalar yerinde' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" -j DROP' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_rule iptables "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -j DROP' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -c 'QBIT_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh" | grep -q '^[2-9]'
}

@test "firewall --check enforces jump uniqueness staging SSH and WAN drift" {
    grep -q 'check_jump_exactly_one' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_no_staging_artifacts' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'assert_wan_interface_current' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WAN arayüzü drift' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'SSH_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'neighbour-solicitation -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'neighbour-advertisement -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    # IPv6 Tailscale UDP must be checked, not only IPv4.
    grep -c 'TAILSCALE_UDP_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh" |
        grep -q '^[2-9]'
}

@test "edge drop-ins order after tailscaled without PartOf" {
    grep -q 'dnsmasq.service.d/master-stack.conf' "$V2_ROOT/install.sh"
    grep -q 'caddy.service.d/master-stack.conf' "$V2_ROOT/install.sh"
    awk '/dnsmasq.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh" |
        grep -q 'After=tailscaled.service'
    awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh" |
        grep -q 'After=tailscaled.service'
    ! awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh" |
        grep -q 'PartOf=tailscaled.service'
}

@test "edge apt install masks units until configured" {
    grep -q 'systemctl mask dnsmasq.service caddy.service' "$V2_ROOT/install.sh"
    grep -q 'apt_get_install_masked_quiet' "$V2_ROOT/install.sh"
    ! grep -q '/usr/sbin/policy-rc.d' "$V2_ROOT/install.sh"
    awk '/^stage_6\(\)/,/^stage_7\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'systemctl unmask dnsmasq caddy'
}

@test "re-run gates full-upgrade and skips unchanged edge restart" {
    grep -q 'RUN_FULL_UPGRADE' "$V2_ROOT/install.sh"
    grep -q 'V2_FULL_UPGRADE' "$V2_ROOT/install.sh"
    grep -q 'full-upgrade yapılsın mı' "$V2_ROOT/install.sh"
    grep -q 'COMPOSE_NEEDS_UP' "$V2_ROOT/install.sh"
    grep -q 'FIREWALL_NEEDS_RESTART' "$V2_ROOT/install.sh"
    ! grep -q 'WEBDAV_NEEDS_RESTART' "$V2_ROOT/install.sh"
    grep -q 'yapılandırması aynı; yeniden başlatılmadı' "$V2_ROOT/install.sh"
    grep -q 'Compose dosyası aynı ve konteynerler ayakta' "$V2_ROOT/install.sh"
    grep -q 'V2_LAST_ATOMIC_CHANGED' "$V2_ROOT/common.sh"
    awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'systemctl restart master-firewall.service'
    ! awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'master-webdav'
    ! awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -qE '\|[[:space:]]*atomic_write'
}

@test "base packages include htpasswd helpers" {
    grep -q 'apache2-utils dnsutils' "$V2_ROOT/install.sh"
    ! grep -qE 'apache2-utils dnsutils acl' "$V2_ROOT/install.sh"
    # acl may be installed only as a migration helper inside the purge path.
    ! awk '/^stage_1\(\)/,/^stage_2\(\)/' "$V2_ROOT/install.sh" |
        grep -qE '\bacl\b'
}

@test "export-v2 embeds archive sha256 and stages remote extract" {
    grep -q 'PORTABLE_ARCHIVE_SHA256' "$V2_ROOT/dev/export-v2.sh"
    grep -q 'sha256sum' "$V2_ROOT/dev/export-v2.sh"
    ! grep -qE '\.sha256"|Sidecar' "$V2_ROOT/dev/export-v2.sh"
    grep -q 'dsi-v2-extract' "$V2_ROOT/dev/export-v2.sh"
    grep -q 'staging/v2' "$V2_ROOT/dev/export-v2.sh"
}

@test "stage 7 checks DNS on Tailscale IP and publish surface" {
    grep -q 'status: REFUSED' "$V2_ROOT/install.sh"
    grep -q 'for resolver in 127.0.0.1' "$V2_ROOT/install.sh"
    grep -q 'Host: webdav.' "$V2_ROOT/install.sh"
    grep -q 'WebDAV TS-IP alias' "$V2_ROOT/install.sh"
    grep -q 'http://127.0.0.1:${WEBDAV_PORT}/' "$V2_ROOT/install.sh"
    grep -q 'assert_webdav_readonly_runtime' "$V2_ROOT/install.sh"
    grep -q 'ReadonlyRootfs' "$V2_ROOT/install.sh"
    grep -q '/downloads false' "$V2_ROOT/install.sh"
    ! grep -q 'v2-write-probe' "$V2_ROOT/install.sh"
    ! awk '/^assert_webdav_readonly_runtime/,/^stage_7/' "$V2_ROOT/install.sh" |
        grep -qE '401\|403\|405'
    grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    grep -q 'docker port qbittorrent' "$V2_ROOT/install.sh"
    grep -q 'docker port webdav' "$V2_ROOT/install.sh"
    grep -q 'UI publish yalnız loopback' "$V2_ROOT/install.sh"
}

@test "install holds systemd-inhibit" {
    grep -q 'systemd-inhibit' "$V2_ROOT/install.sh"
    grep -q 'V2_INHIBITED' "$V2_ROOT/install.sh"
}

@test "defaults.env carries no unread keys" {
    # Every key here must be read by something. A key nothing reads is a
    # second source of truth waiting to drift.
    local key
    for key in V2_CONFIG_SCHEMA NET_RETRY_ATTEMPTS ADDRESS_WAIT_DEADLINE_SECONDS \
        WEBDAV_READ_ONLY; do
        ! grep -q "^${key}=" "$V2_ROOT/config/defaults.env"
    done
    # DNS_PORT and CADDY_HTTP_PORT exist and are now actually used.
    grep -q '"\$DNS_PORT" | "\$CADDY_HTTP_PORT"' "$V2_ROOT/install.sh"
    ! grep -qE '^\s+53 \| 80 \|' "$V2_ROOT/install.sh"
}

@test "stage 7 derives the container count from compose" {
    ! grep -q 'local expected=5' "$V2_ROOT/install.sh"
    grep -q 'docker compose config --services' "$V2_ROOT/install.sh"
}

@test "refresh timer has no no-op Persistent key" {
    # Persistent= only applies to OnCalendar= timers; this one is monotonic.
    ! grep -q 'Persistent=' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'OnUnitActiveSec=5min' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
}

@test "tailscale_login reaps stuck up child before retry" {
    grep -q 'reap_bg_pid()' "$V2_ROOT/install.sh"
    grep -q 'kill -KILL' "$V2_ROOT/install.sh"
    awk '/^tailscale_login\(\)/,/^stage_0\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'reap_bg_pid "\$up_pid"'
    ! awk '/^tailscale_login\(\)/,/^stage_0\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'kill "\$up_pid"'
}

