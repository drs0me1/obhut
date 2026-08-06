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
    printf 'same\n' | atomic_write "$TMP/f" 0644
    local before
    before="$(stat -f '%i' "$TMP/f" 2>/dev/null || stat -c '%i' "$TMP/f")"
    printf 'same\n' | atomic_write "$TMP/f" 0644
    local after
    after="$(stat -f '%i' "$TMP/f" 2>/dev/null || stat -c '%i' "$TMP/f")"
    [ "$before" = "$after" ]
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

@test "compose template has no public TCP for qbit" {
    ! grep -E 'QBIT_PUBLIC_PORT.*tcp|65173/tcp' "$V2_ROOT/templates/compose.yaml"
    grep -q 'QBIT_PUBLIC_PORT.*/udp' "$V2_ROOT/templates/compose.yaml"
}

@test "qbittorrent runs as uid 1000" {
    grep -q 'PUID: "1000"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'PGID: "1000"' "$V2_ROOT/templates/compose.yaml"
}

@test "compose enables portainer http on 9000" {
    grep -q -- '--http-enabled' "$V2_ROOT/templates/compose.yaml"
    grep -q '127.0.0.1:__PORTAINER_UI_PORT__:9000' "$V2_ROOT/templates/compose.yaml"
}

@test "unpackerr watches folders, not the qBittorrent API" {
    grep -q 'UN_FOLDER_0_PATH: "/downloads"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'UN_FOLDER_0_MOVE_BACK: "true"' "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'UN_QBITTORRENT_' "$V2_ROOT/templates/compose.yaml"
}

@test "filebrowser serves full downloads at /data" {
    grep -q '__DOWNLOADS_PATH__:/data' "$V2_ROOT/templates/compose.yaml"
    grep -q 'FILEBROWSER_CONFIG: /config.yaml' "$V2_ROOT/templates/compose.yaml"
    grep -q '__QUANTUM_CONFIG_FILE__:/config.yaml:ro' "$V2_ROOT/templates/compose.yaml"
    grep -q 'filebrowser_data:/home/filebrowser/data' "$V2_ROOT/templates/compose.yaml"
}

@test "wg-easy publishes WireGuard UDP 1:1 without remap" {
    grep -q '"__WG_PUBLIC_PORT__:__WG_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'WAN_IPV4' "$V2_ROOT/templates/compose.yaml"
    ! grep -q ':51820/udp' "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'WG_PORT:' "$V2_ROOT/templates/compose.yaml"
}

@test "compose public UDP ports are not bound to WAN_IPV4" {
    grep -q '"__QBIT_PUBLIC_PORT__:__QBIT_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
    ! grep -q '\${WAN_IPV4}' "$V2_ROOT/templates/compose.yaml"
}

@test "refresh-tailnet-config does not touch compose or firewall" {
    ! grep -qE 'compose|master-firewall|DOCKER-USER' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'try-restart caddy' "$V2_ROOT/scripts/refresh-tailnet-config" ||
        grep -q 'restart caddy' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'master-webdav' "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "dnsmasq binds lo and tailscale only" {
    grep -q 'interface=lo' "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'interface=__TAILSCALE_IF__' "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'bind-dynamic' "$V2_ROOT/templates/dnsmasq.conf"
}

@test "Caddyfile uses plain HTTP portainer upstream" {
    grep -q 'reverse_proxy 127.0.0.1:__PORTAINER_UI_PORT__' "$V2_ROOT/templates/Caddyfile"
    ! grep -qi 'tls_insecure' "$V2_ROOT/templates/Caddyfile"
}

@test "webdav script uses htpasswd file not password flags" {
    grep -q -- '--htpasswd' "$V2_ROOT/scripts/webdav.sh"
    ! grep -qE -- '--pass |--user ' "$V2_ROOT/scripts/webdav.sh"
}

@test "firewall script does not flush DOCKER-USER" {
    ! grep -qE 'DOCKER-USER.*-F|-F DOCKER-USER' "$V2_ROOT/scripts/firewall.sh"
}

@test "defaults.env has no webdav password assignments" {
    ! grep -qE '^[[:space:]]*(WEBDAV_PASSWORD|WEBDAV_USER_PASSWORD|WEBDAV_PASSWORD_HASH)=' \
        "$V2_ROOT/config/defaults.env"
}
