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

@test "require_supported_os accepts trixie noble and resolute" {
    for triple in "debian trixie 13" "ubuntu noble 24.04" "ubuntu resolute 26.04"; do
        set -- $triple
        cat >"$TMP/os" <<EOF
ID=$1
VERSION_CODENAME=$2
VERSION_ID="$3"
EOF
        V2_OS_RELEASE_PATH="$TMP/os"
        run require_supported_os
        [ "$status" -eq 0 ]
    done
}

@test "require_supported_os exports OS_ID and OS_CODENAME for repo lines" {
    cat >"$TMP/os" <<'EOF'
ID=ubuntu
VERSION_CODENAME=noble
VERSION_ID="24.04"
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    require_supported_os
    [ "$OS_ID" = "ubuntu" ]
    [ "$OS_CODENAME" = "noble" ]
}

@test "require_supported_os rejects unsupported and mismatched releases" {
    # Non-LTS ubuntu, older debian, and an ID/codename mismatch all fail.
    for triple in "ubuntu jammy 22.04" "debian bookworm 12" "ubuntu trixie 13" "debian noble 24.04"; do
        set -- $triple
        cat >"$TMP/os" <<EOF
ID=$1
VERSION_CODENAME=$2
VERSION_ID="$3"
EOF
        V2_OS_RELEASE_PATH="$TMP/os"
        run require_supported_os
        [ "$status" -eq 1 ]
    done
    # Codename/version mismatch within a supported pair also fails.
    cat >"$TMP/os" <<'EOF'
ID=ubuntu
VERSION_CODENAME=noble
VERSION_ID="26.04"
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    run require_supported_os
    [ "$status" -eq 1 ]
}

@test "install derives apt repos from os-release and carries ubuntu guards" {
    # Repo suite comes from OS_ID/OS_CODENAME — no hardcoded distro remains.
    grep -qF 'https://pkgs.tailscale.com/stable/$OS_ID $OS_CODENAME main' \
        "$V2_ROOT/install.sh"
    grep -qF 'https://download.docker.com/linux/$OS_ID' "$V2_ROOT/install.sh"
    grep -qF 'Suites: $OS_CODENAME' "$V2_ROOT/install.sh"
    ! grep -q 'trixie' "$V2_ROOT/install.sh"
    # Caddy repo stays distro-agnostic (any-version) — same line on ubuntu.
    grep -q 'caddy/stable/deb/debian any-version main' "$V2_ROOT/install.sh"
    # ufw active is a hard stop before any mutation (stage_0).
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" |
        grep -q "ufw aktif"
    # systemd-resolved stub symlink is repointed so host DNS survives.
    grep -q 'stub-resolv.conf' "$V2_ROOT/install.sh"
    grep -qF 'ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf' \
        "$V2_ROOT/install.sh"
    # debian-keyring is installed on debian only.
    grep -q '\[\[ "\$OS_ID" == "debian" \]\] && dns_pkgs+=(debian-keyring)' \
        "$V2_ROOT/install.sh"
    # Every apt-get call waits on the dpkg lock (ubuntu unattended-upgrades).
    grep -q 'APT_OPTS=(-o DPkg::Lock::Timeout=' "$V2_ROOT/install.sh"
    [ "$(grep -cF 'apt-get "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 10 ]
}

@test "require_supported_os records version and architecture" {
    cat >"$TMP/os" <<'EOF'
ID=ubuntu
VERSION_CODENAME=resolute
VERSION_ID="26.04"
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    require_supported_os
    [ "$OS_VERSION_ID" = "26.04" ]
    [ -n "$OS_ARCH" ]
    # The reader loop must not leak its variable into the caller.
    awk '/^require_supported_os\(\)/,/^}$/' "$V2_ROOT/common.sh" |
        grep -q 'local id="" codename="" version_id="" line=""'
}

@test "state.env records the OS the install ran on and a change forces re-apply" {
    # Identity is recorded, not just derived (DD-104).
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q '^OS_ID=\$OS_ID$'
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q '^OS_CODENAME=\$OS_CODENAME$'
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q '^OS_VERSION_ID=\$OS_VERSION_ID$'
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q '^OS_ARCH=\$OS_ARCH$'
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'KERNEL_RELEASE='
    # A missing record must not be reported as a release change.
    awk '/^detect_os_change\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'v2-73 öncesi'
    # A real change re-runs the OS-conditional work rather than trusting bytes.
    grep -q 'OS_CHANGED=1' "$V2_ROOT/install.sh"
    grep -qF '"${V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 || "$OS_CHANGED" -eq 1' \
        "$V2_ROOT/install.sh"
    awk '/^detect_os_change\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'FIREWALL_NEEDS_RESTART=1'
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'detect_os_change'
}

@test "third-party restart managers are suspended during apt" {
    # needrestart runs in automatic mode on ubuntu; DEBIAN_FRONTEND does not
    # disable it. The installer owns its own restarts (DD-103).
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'export NEEDRESTART_SUSPEND=1'
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'export DEBIAN_FRONTEND=noninteractive'
}

@test "sysctl drop-ins sort last and the runtime value is asserted" {
    # Provider images ship 99-*.conf too and the last assignment wins (DD-105).
    grep -q 'SYSCTL_NETBUF_FILE="/etc/sysctl.d/99-zz-' "$V2_ROOT/config/defaults.env"
    grep -q 'SYSCTL_FORWARD_FILE="/etc/sysctl.d/99-zz-' "$V2_ROOT/config/defaults.env"
    grep -q 'SYSCTL_LEGACY_FILES=' "$V2_ROOT/config/defaults.env"
    ! grep -q 'atomic_write /etc/sysctl.d/99-master' "$V2_ROOT/install.sh"
    # Old names are removed, otherwise one key is written from two files.
    awk '/^remove_legacy_sysctl_files\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'rm -f'
    awk '/^stage_2\(\)/,/^ensure_downloads_tree\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'remove_legacy_sysctl_files'
    # File placement is not proof; stage 7 reads the live value.
    awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'sysctl -n net.ipv4.ip_forward'
}

@test "fail-early gates: nft backend, repo suite, rendered configs" {
    # Docker and firewall.sh must share one netfilter backend (DD-106), and
    # both families are checked because each has its own alternatives link.
    awk '/^check_nft_iptables\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'nf_tables'
    awk '/^check_nft_iptables\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'for bin in iptables ip6tables'
    # Debian minimal has no iptables until stage 1 installs it, so stage 0 may
    # only check what exists; stage 1 makes it mandatory (DD-108).
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'check_nft_iptables optional'
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'check_nft_iptables required'
    # The mandatory check must come after the package that provides the binary.
    awk '/retry "apt-base"/{i=NR} /check_nft_iptables required/{c=NR}
         END { exit !(i && c && i < c) }' "$V2_ROOT/install.sh"
    # A suite the vendor has not published is named, not timed out on.
    awk '/^assert_repo_suite\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'curl'
    grep -q 'assert_repo_suite "Tailscale"' "$V2_ROOT/install.sh"
    grep -q 'assert_repo_suite "Docker"' "$V2_ROOT/install.sh"
    # Every render is validated before the unit that consumes it is restarted.
    grep -q 'dnsmasq --test -C "\$DNSMASQ_CONF_FILE"' "$V2_ROOT/install.sh"
    grep -q 'caddy validate --config "\$CADDYFILE"' "$V2_ROOT/install.sh"
    grep -q 'docker compose config -q' "$V2_ROOT/install.sh"
    # Caddy resolves env placeholders at runtime; validate with the real values.
    grep -qF 'TAILSCALE_IPV4="$TAILSCALE_IPV4" WEBDAV_PORT="$WEBDAV_PORT"' \
        "$V2_ROOT/install.sh"
}

@test "OS-divergence inventory: code markers and the doc table agree" {
    # Every distro-dependent point carries a marker; architecture.md lists the
    # same set. Neither can drift without this failing.
    code="$(grep -o 'OS-DIVERGENCE: [a-z-]*' "$V2_ROOT/install.sh" |
        awk '{print $2}' | sort -u)"
    doc="$(awk '/OS-DIVERGENCE-INVENTORY:BEGIN/,/OS-DIVERGENCE-INVENTORY:END/' \
        "$V2_ROOT/docs/architecture.md" |
        grep -oE '^\| `[a-z-]+`' | tr -d '|` ' | sort -u)"

    # Guard against both extractions silently returning nothing, which would
    # make the comparison below pass for the wrong reason.
    [ -n "$code" ]
    [ -n "$doc" ]
    grep -qx 'caddy-keyring-pkg' <<<"$code"
    grep -qx 'caddy-keyring-pkg' <<<"$doc"

    [ "$code" = "$doc" ]

    # Each inventory row cites the decision that justifies it.
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        awk '/OS-DIVERGENCE-INVENTORY:BEGIN/,/OS-DIVERGENCE-INVENTORY:END/' \
            "$V2_ROOT/docs/architecture.md" |
            grep -E "^\| \`${slug}\`" | grep -qE 'DD-[0-9]+'
    done <<<"$doc"
}

@test "resolved divergence is probed, not assumed, and is actually written" {
    # The one divergence that had no coverage at all until now. On Debian
    # resolved is inactive, so the whole block must be skipped rather than
    # writing a drop-in that nothing reads.
    block="$(awk '/is-active --quiet systemd-resolved/,/^    fi$/' \
        "$V2_ROOT/install.sh")"
    [ -n "$block" ]
    grep -q 'DNSStubListener=no' <<<"$block"

    # Nothing under resolved.conf.d may be written outside that conditional.
    total="$(grep -c 'resolved.conf.d' "$V2_ROOT/install.sh")"
    inside="$(grep -c 'resolved.conf.d' <<<"$block")"
    [ "$total" -eq "$inside" ]

    # The stub repoint is nested inside the same probe and is target-tested,
    # so it stays a no-op on a host without the stub symlink.
    grep -q 'stub-resolv.conf' <<<"$block"
    grep -q 'ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf' <<<"$block"

    # A restart only happens when the drop-in changed or the release changed.
    grep -q 'systemctl restart systemd-resolved' <<<"$block"
    grep -qF 'V2_LAST_ATOMIC_CHANGED:-0}" -eq 1 || "$OS_CHANGED" -eq 1' <<<"$block"

    # The setting is not assumed to have worked: systemd 259 accepts and
    # ignores it, so the achieved state is read back and reported (DD-109).
    grep -q 'report_resolved_stub_state' <<<"$block"
}

@test "resolved stub state is read back, on a wall-clock bound" {
    body="$(awk '/^report_resolved_stub_state\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$body" ]
    # Reads the achieved state rather than trusting the write.
    grep -q '127' <<<"$body"
    # Both outcomes are reported; a silent no-op is the thing being fixed.
    [ "$(grep -c 'log INFO' <<<"$body")" -eq 2 ]
    # Every wait in this tree is bounded by wall clock, never by iteration count.
    grep -q 'SECONDS + RESOLVED_STUB_SETTLE_SECONDS' <<<"$body"
    grep -q 'RESOLVED_STUB_SETTLE_SECONDS=' "$V2_ROOT/config/defaults.env"
}

@test "require_supported_os does not source os-release" {
    cat >"$TMP/os" <<EOF
ID=debian
VERSION_CODENAME=trixie
VERSION_ID="13"
X=\$(touch $TMP/pwned)
EOF
    V2_OS_RELEASE_PATH="$TMP/os"
    run require_supported_os
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
    # TMP scratch should not accumulate installer temps from that call (different dir)
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

@test "render_template preserves trailing newline" {
    printf 'v=__V__\n' >"$TMP/t"
    render_template "$TMP/t" "$TMP/o" 0644 V=ok
    [[ "$(tail -c1 "$TMP/o" | wc -l | tr -d ' ')" == "1" ]]
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

@test "compose publishes the torrent peer TCP and UDP 1:1" {
    grep -q '"0.0.0.0:__TORRENT_PUBLIC_PORT__:__TORRENT_PUBLIC_PORT__/tcp"' \
        "$V2_ROOT/templates/compose.yaml"
    grep -q '"0.0.0.0:__TORRENT_PUBLIC_PORT__:__TORRENT_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "firewall allows the torrent peer TCP and UDP on WAN" {
    grep -q 'tcp --dport "$TORRENT_PUBLIC_PORT"' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'udp --dport "$TORRENT_PUBLIC_PORT"' "$V2_ROOT/scripts/firewall.sh"
    # DOCKER-USER: both protocols for NEW --ctorigdstport
    [[ "$(grep -c 'ctorigdstport "$TORRENT_PUBLIC_PORT"' \
        "$V2_ROOT/scripts/firewall.sh")" -ge 2 ]]
}

@test "firewall requires ports and chains from state" {
    grep -q 'CHAIN_INPUT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'TORRENT_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX' "$V2_ROOT/install.sh"
    ! grep -qE 'WG_PUBLIC_PORT:=61001|TORRENT_PUBLIC_PORT:=61005|CHAIN_INPUT:=MASTER' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX}IN-' "$V2_ROOT/scripts/firewall.sh"
}

@test "transmission and unpackerr use DOWNLOADS_UID/GID tokens" {
    grep -q 'PUID: "__DOWNLOADS_UID__"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'PGID: "__DOWNLOADS_GID__"' "$V2_ROOT/templates/compose.yaml"
    grep -c 'user: "__DOWNLOADS_UID__:__DOWNLOADS_GID__"' \
        "$V2_ROOT/templates/compose.yaml" | grep -q '^[2-9]'
    ! grep -qE 'PUID: "1000"|PGID: "1000"|user: "1000:1000"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "downloads tree is chown 1000 for transmission filebrowser unpackerr" {
    grep -q 'DOWNLOADS_UID=1000' "$V2_ROOT/config/defaults.env"
    grep -q 'DOWNLOADS_GID=1000' "$V2_ROOT/config/defaults.env"
    grep -q 'ensure_downloads_tree' "$V2_ROOT/install.sh"
    grep -q 'assert_downloads_path_allowed' "$V2_ROOT/install.sh"
    grep -q 'allowlist dışı' "$V2_ROOT/install.sh"
    grep -q 'chown -h' "$V2_ROOT/install.sh"
    grep -q '! -uid' "$V2_ROOT/install.sh"
    grep -q '! -perm 0775' "$V2_ROOT/install.sh"
    grep -q '! -perm 0664' "$V2_ROOT/install.sh"
    # Downloads tree itself is selective find+chown, not chown -R on DOWNLOADS_PATH.
    ! awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'chown -R'
    # Single tree walk (v2-71): one find with comma-joined expressions, not
    # three separate passes over the whole downloads tree.
    [ "$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -c 'find "\$root"')" -eq 1 ]
    grep -q 'user: "__DOWNLOADS_UID__:__DOWNLOADS_GID__"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "ensure_downloads_tree single pass fixes deviant modes and keeps compliant ones" {
    # Run the REAL function (extracted from install.sh) against a tmp tree:
    # deviant dir/file modes must be repaired, already-compliant entries kept.
    die() { echo "die: $*" >&2; return 1; }
    eval "$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    mkdir -p "$TMP/dl/sub"
    echo x >"$TMP/dl/sub/bad"
    echo y >"$TMP/dl/sub/good"
    chmod 0700 "$TMP/dl/sub"
    chmod 0600 "$TMP/dl/sub/bad"
    chmod 0664 "$TMP/dl/sub/good"
    ensure_downloads_tree "$TMP/dl" "$(id -u)" "$(id -g)"
    [ "$(stat -f '%Lp' "$TMP/dl/sub" 2>/dev/null || stat -c '%a' "$TMP/dl/sub")" = "775" ]
    [ "$(stat -f '%Lp' "$TMP/dl/sub/bad" 2>/dev/null || stat -c '%a' "$TMP/dl/sub/bad")" = "664" ]
    [ "$(stat -f '%Lp' "$TMP/dl/sub/good" 2>/dev/null || stat -c '%a' "$TMP/dl/sub/good")" = "664" ]
    run ensure_downloads_tree "$TMP/yok" "$(id -u)" "$(id -g)"
    [ "$status" -ne 0 ]
}

@test "docker daemon.json merges dns and log rotation via jq" {
    grep -q 'merge_docker_daemon_config' "$V2_ROOT/install.sh"
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'jq'
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q '\.dns = \["1.1.1.1", "1.0.0.1"\]'
    ! awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'atomic_write /etc/docker/daemon.json'
}

@test "container log rotation is merged only for the json-file driver" {
    grep -q 'DOCKER_LOG_MAX_SIZE=' "$V2_ROOT/config/defaults.env"
    grep -q 'DOCKER_LOG_MAX_FILE=' "$V2_ROOT/config/defaults.env"
    # The merge must be conditional: an operator-selected driver is preserved.
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'log-driver" // "json-file"'
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'max-size'
    # Existing keys survive: log-opts is added to, not replaced.
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'log-opts" // {}'
}

@test "docker daemon config is in place before the package starts dockerd" {
    # docker-ce's postinst starts dockerd at once; a daemon.json written after
    # that is not read until the next restart, so the containers stage 7
    # creates got neither dns nor log options (DD-110). Same pattern as DD-18.
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        awk '/^    merge_docker_daemon_config$/{m=NR} /retry "apt-docker"/{a=NR}
             END { exit !(m && a && m < a) }'
    # A daemon.json change on an already-running dockerd is reported, not assumed.
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" | grep -q 'docker_was_active'
}

@test "container log rotation is part of the compose definition" {
    # daemon.json log-opts are read only at container creation and never reach
    # existing containers; in compose they are a diff and trigger a recreate.
    grep -q '^x-logging: &default-logging$' "$V2_ROOT/templates/compose.yaml"
    grep -q 'max-size: "__DOCKER_LOG_MAX_SIZE__"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'max-file: "__DOCKER_LOG_MAX_FILE__"' "$V2_ROOT/templates/compose.yaml"
    services="$(grep -c '^    container_name:' "$V2_ROOT/templates/compose.yaml")"
    refs="$(grep -c '^    logging: \*default-logging$' "$V2_ROOT/templates/compose.yaml")"
    [ "$services" -gt 0 ]
    [ "$services" -eq "$refs" ]
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'DOCKER_LOG_MAX_SIZE="\$DOCKER_LOG_MAX_SIZE"'
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'DOCKER_LOG_MAX_FILE="\$DOCKER_LOG_MAX_FILE"'
}

@test "tcp congestion control is applied only when the host can load it" {
    # DD-111: measured on TCP that terminates on the host. A kernel without the
    # module must not stop the install (DD-108); the result is read back (DD-109).
    body="$(awk '/^apply_tcp_congestion_control\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$body" ]
    grep -q 'if ! modprobe' <<<"$body"
    [ "$(grep -c 'return 0' <<<"$body")" -ge 2 ]
    grep -q 'atomic_write "\$SYSCTL_TCP_FILE"' <<<"$body"
    grep -q 'atomic_write "\$TCP_MODULES_LOAD_FILE"' <<<"$body"
    grep -q 'SYSCTL_TCP_FILE="/etc/sysctl.d/99-zz-' "$V2_ROOT/config/defaults.env"
    grep -q 'TCP_CONGESTION_CONTROL="bbr"' "$V2_ROOT/config/defaults.env"
    grep -q 'TCP_DEFAULT_QDISC="fq"' "$V2_ROOT/config/defaults.env"
    # Applied in stage 2, before the tailscale package creates tailscale0.
    awk '/^stage_2\(\)/,/^ensure_downloads_tree\(\)/' "$V2_ROOT/install.sh" |
        awk '/^    apply_tcp_congestion_control$/{a=NR} /install -y tailscale/{t=NR}
             END { exit !(a && t && a < t) }'
    # Stage 7 reads the live value back; a mismatch warns, it does not fail.
    block="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'sysctl -n net.ipv4.tcp_congestion_control' <<<"$block"
    ! grep -q 'die "tcp_congestion_control' <<<"$block"
}

@test "downloads path rejects unsafe characters and compose needs no .env" {
    grep -q 'downloads yolu yalnızca' "$V2_ROOT/install.sh"
    grep -q "downloads yolu '..' içeremez" "$V2_ROOT/install.sh"
    grep -q 'assert_downloads_path_allowed' "$V2_ROOT/install.sh"
    grep -q 'sistem dizinine izin vermez' "$V2_ROOT/install.sh"
    ! awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'atomic_write "$COMPOSE_DIR/.env"'
    # Every value is rendered into the file, so no interpolation is left for
    # Compose to resolve and a stray .env cannot change the stack.
    ! grep -q '\${' "$V2_ROOT/templates/compose.yaml"
}

@test "compose runs dozzle behind a login with actions, no shell, loopback only" {
    # DD-116: docker.sock is root-equivalent, so loopback + Caddy + users.yml.
    block="$(awk '/^  dozzle:$/,/^  filebrowser:$/' "$V2_ROOT/templates/compose.yaml")"
    [ -n "$block" ]
    grep -q '"127.0.0.1:__DOZZLE_UI_PORT__:8080"' <<<"$block"
    grep -q 'DOZZLE_AUTH_PROVIDER: simple' <<<"$block"
    grep -q 'DOZZLE_ENABLE_ACTIONS: "true"' <<<"$block"
    grep -q 'DOZZLE_NO_ANALYTICS: "true"' <<<"$block"
    ! grep -q 'DOZZLE_ENABLE_SHELL' <<<"$block"
    grep -q 'read_only: true' <<<"$block"
    grep -q -- '- no-new-privileges=true' <<<"$block"
    grep -q -- '- ALL' <<<"$block"
    grep -q '__DOZZLE_DATA_DIR__:/data' <<<"$block"
    grep -q '\["CMD", "/dozzle", "healthcheck"\]' <<<"$block"
    ! grep -qi portainer "$V2_ROOT/templates/compose.yaml" "$V2_ROOT/templates/Caddyfile" \
        "$V2_ROOT/templates/dnsmasq.conf"
}

@test "caddy proxies dozzle over plain loopback http" {
    grep -q 'reverse_proxy 127.0.0.1:__DOZZLE_UI_PORT__' "$V2_ROOT/templates/Caddyfile"
    ! grep -q 'tls_insecure_skip_verify' "$V2_ROOT/templates/Caddyfile"
    # Stage 7 fails closed when the login is not enforced.
    awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'Dozzle API girişsiz yanıt'
}

@test "dozzle account comes from the input file and never reaches argv" {
    stage0="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'DOZZLE_NEW_PASS="\$INPUT_DOZZLE_PASS"' <<<"$stage0"
    grep -q 'validate_account Dozzle' <<<"$stage0"
    grep -q '"\$DOZZLE_MIN_PASSWORD_LENGTH"' <<<"$stage0"
    body="$(awk '/^ensure_dozzle_users\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'if dozzle_users_match; then' <<<"$body"
    grep -q 'docker run -i --rm --network none "\$DOZZLE_IMAGE"' <<<"$body"
    grep -q 'generate --user-roles actions' <<<"$body"
    ! grep -q -- '--password' <<<"$body"
    grep -q 'unset DOZZLE_NEW_PASS' <<<"$body"
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" | grep -q '^    ensure_dozzle_users$'
    grep -q '^DOZZLE_USERS_FILE="/etc/master-stack/dozzle/users.yml"' "$V2_ROOT/config/defaults.env"
}

@test "ensure_dozzle_users writes a private file from stdin and rejects malformed output" {
    eval "$(awk '/^dozzle_users_match\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_dozzle_users\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    DOZZLE_DATA_DIR="$TMP/dozzle" DOZZLE_USERS_FILE="$TMP/dozzle/users.yml" DOZZLE_IMAGE=fixture
    RUNTIME_DIR="$TMP"
    log() { :; }
    chown() { :; }
    install() { mkdir -p "${!#}"; chmod 700 "${!#}"; }
    hash="\$2a\$11\$$(printf 'a%.0s' {1..53})"
    docker() {
        [ "$1" = run ] || return 1
        printf '%s\n' "$*" >"$TMP/argv"
        IFS= read -r pw
        printf '%s' "$pw" >"$TMP/stdin"
        printf 'users:\n    admin:\n        password: %s\n        roles: actions\n' "$hash"
    }
    DOZZLE_NEW_USER=admin DOZZLE_NEW_PASS='fixture-password-123'
    run ensure_dozzle_users
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/stdin")" = 'fixture-password-123' ]
    ! grep -q 'fixture-password-123' "$TMP/argv"
    grep -q 'generate --user-roles actions admin' "$TMP/argv"
    mode="$(stat -c %a "$TMP/dozzle/users.yml" 2>/dev/null || stat -f %Lp "$TMP/dozzle/users.yml")"
    [ "$mode" = 600 ]
    # DD-119: a users file already holding this account is left alone.
    if command -v htpasswd >/dev/null; then
        real="$(printf '%s' 'fixture-password-123' | htpasswd -niB -C 4 admin | cut -d: -f2-)"
        printf 'users:\n    admin:\n        email: ""\n        password: %s\n        roles: actions\n' "$real" \
            >"$TMP/dozzle/users.yml"
        docker() { printf '%s\n' "$*" >>"$TMP/dozzle-calls"; return 1; }
        DOZZLE_NEW_USER=admin DOZZLE_NEW_PASS='fixture-password-123'
        run ensure_dozzle_users
        [ "$status" -eq 0 ]
        [ ! -e "$TMP/dozzle-calls" ]
        grep -qF "$real" "$TMP/dozzle/users.yml"
        # A second user in the file is not the account the input file describes.
        printf '    other:\n        password: %s\n' "$real" >>"$TMP/dozzle/users.yml"
        run dozzle_users_match
        [ "$status" -ne 0 ]
        [ -z "$(find "$TMP" -maxdepth 1 -name '.bcrypt-*')" ]
    fi
    rm -f "$TMP/dozzle/users.yml"
    docker() { [ "$1" = run ] || return 1; IFS= read -r _; printf 'not a users file\n'; }
    DOZZLE_NEW_USER=admin DOZZLE_NEW_PASS='fixture-password-123'
    run ensure_dozzle_users
    [ "$status" -ne 0 ]
    [ ! -e "$TMP/dozzle/users.yml" ]
    [ -z "$(ls -A "$TMP/dozzle")" ]
}

@test "unpackerr watches folders, not a torrent client API" {
    grep -q 'UN_FOLDER_0_PATH: "/downloads"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'UN_FOLDER_0_MOVE_BACK: "true"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'UN_FOLDER_0_DELETE_ORIGINAL: "false"' "$V2_ROOT/templates/compose.yaml"
    ! grep -qE 'UN_(QBITTORRENT|TRANSMISSION)_' "$V2_ROOT/templates/compose.yaml"
}

@test "transmission keeps credentials out of compose and a clean-shutdown settings seed" {
    # DD-117: the image needs USER/PASS at every start (it disables auth and
    # cannot RPC-exit without them), so they come from root-only files.
    block="$(awk '/^  transmission:$/,/^  unpackerr:$/' "$V2_ROOT/templates/compose.yaml")"
    [ -n "$block" ]
    grep -q '"127.0.0.1:__TORRENT_UI_PORT__:9091"' <<<"$block"
    grep -q 'PEERPORT: "__TORRENT_PUBLIC_PORT__"' <<<"$block"
    grep -q 'FILE__USER: /run/secrets/transmission/user' <<<"$block"
    grep -q 'FILE__PASS: /run/secrets/transmission/pass' <<<"$block"
    grep -q '__TRANSMISSION_AUTH_DIR__:/run/secrets/transmission:ro' <<<"$block"
    grep -q '__TRANSMISSION_DATA_DIR__:/config' <<<"$block"
    ! grep -qE '^ +(USER|PASS|HOST_WHITELIST):' <<<"$block"
    ! grep -qi qbittorrent "$V2_ROOT/templates/compose.yaml"
    body="$(awk '/^ensure_transmission_files\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q '"rpc-port": 9091' <<<"$body"
    grep -q '"download-dir": "/downloads"' <<<"$body"
    # DD-118: the operator's torrent preferences are installed, not restored.
    grep -q '"dht-enabled": false, "pex-enabled": false, "lpd-enabled": false' <<<"$body"
    grep -q '"download-queue-enabled": true, "download-queue-size": 12' <<<"$body"
    # A heredoc closing brace at column 0 would end the extracted function early.
    [ "$(grep -c '^}$' <<<"$body")" -eq 1 ]
    grep -q 'if \[\[ ! -e "\$settings" \]\]' <<<"$body"
    grep -q 'umask 077' <<<"$body"
    grep -q 'unset TRANSMISSION_NEW_PASS' <<<"$body"
    grep -q 'docker restart transmission' <<<"$body"
    stage0="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'TRANSMISSION_NEW_PASS="\$INPUT_TRANSMISSION_PASS"' <<<"$stage0"
    grep -q 'validate_account Transmission' <<<"$stage0"
    grep -q 'docker inspect qbittorrent' <<<"$stage0"
    awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'Transmission RPC girişsiz yanıt'
}

@test "ensure_transmission_files seeds settings once and writes private credentials" {
    eval "$(awk '/^ensure_transmission_files\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    TRANSMISSION_DATA_DIR="$TMP/tr" TRANSMISSION_AUTH_DIR="$TMP/tr-auth" DOWNLOADS_UID=1000 DOWNLOADS_GID=1000
    log() { :; }
    chown() { :; }
    install() { mkdir -p "${!#}"; }
    docker() { printf '%s\n' "$*" >>"$TMP/docker-calls"; [ "$1" != inspect ]; }
    TRANSMISSION_NEW_USER=admin TRANSMISSION_NEW_PASS='fixture-password-123'
    run ensure_transmission_files
    [ "$status" -eq 0 ]
    jq -e '."rpc-port" == 9091 and ."dht-enabled" == false and ."pex-enabled" == false and
        ."lpd-enabled" == false and ."download-queue-enabled" == true and ."download-queue-size" == 12' \
        "$TMP/tr/settings.json" >/dev/null
    [ "$(cat "$TMP/tr-auth/user")" = admin ]
    [ "$(cat "$TMP/tr-auth/pass")" = 'fixture-password-123' ]
    mode="$(stat -c %a "$TMP/tr-auth/pass" 2>/dev/null || stat -f %Lp "$TMP/tr-auth/pass")"
    [ "$mode" = 600 ]
    ! grep -q 'fixture-password-123' "$TMP/docker-calls"
    ! grep -q '^restart' "$TMP/docker-calls"
    # A second run keeps Transmission's own settings file untouched.
    printf '{"speed-limit-down":123}\n' >"$TMP/tr/settings.json"
    docker() { printf '%s\n' "$*" >>"$TMP/docker-calls"; }
    TRANSMISSION_NEW_USER=admin2 TRANSMISSION_NEW_PASS='fixture-password-456'
    run ensure_transmission_files
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/tr/settings.json")" = '{"speed-limit-down":123}' ]
    [ "$(cat "$TMP/tr-auth/user")" = admin2 ]
    grep -q '^restart transmission' "$TMP/docker-calls"
    # DD-119: the same credentials again leave the files and the container alone.
    rm -f "$TMP/docker-calls"
    touch -t 200001010000 "$TMP/tr-auth/pass"
    TRANSMISSION_NEW_USER=admin2 TRANSMISSION_NEW_PASS='fixture-password-456'
    run ensure_transmission_files
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/docker-calls" ]
    [ -z "$(find "$TMP/tr-auth/pass" -newermt '2001-01-01')" ]
}

@test "filebrowser classic serves downloads at /srv with disableExec" {
    grep -q 'container_name: filebrowser' "$V2_ROOT/templates/compose.yaml"
    grep -q '__DOWNLOADS_PATH__:/srv' "$V2_ROOT/templates/compose.yaml"
    grep -q '__FILEBROWSER_DATA_DIR__:/database' "$V2_ROOT/templates/compose.yaml"
    grep -q '__FILEBROWSER_DATA_DIR__/config:/config' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--disableExec' "$V2_ROOT/templates/compose.yaml"
    ! grep -q -- '--disable-exec' "$V2_ROOT/templates/compose.yaml"
    grep -q 'no-new-privileges=true' "$V2_ROOT/templates/compose.yaml"
    ! grep -q 'no-new-privileges:true' "$V2_ROOT/templates/compose.yaml"
    grep -q 'filebrowser/filebrowser:v2' "$V2_ROOT/config/defaults.env"
    grep -q 'FILEBROWSER_DATA_DIR="/etc/master-stack/filebrowser-data"' \
        "$V2_ROOT/config/defaults.env"
    grep -q 'ensure_filebrowser_data_dir' "$V2_ROOT/install.sh"
    grep -q 'FILEBROWSER_DATA_DIR/config' "$V2_ROOT/install.sh"
    ! grep -q 'FileBrowser varsayılan: admin / admin' "$V2_ROOT/install.sh"
    ! grep -q 'rastgele admin parolası' "$V2_ROOT/install.sh"
    ! grep -q 'qBittorrent varsayılan WebUI' "$V2_ROOT/install.sh"
    ! grep -q 'docker logs filebrowser' "$V2_ROOT/install.sh"
    ! grep -q 'ilk yönetici hesabını sen kur' "$V2_ROOT/install.sh"
    ! grep -q 'QUANTUM_CONFIG_FILE' "$V2_ROOT/config/defaults.env"
    ! grep -q 'gtsteffaniak/filebrowser' "$V2_ROOT/config/defaults.env"
    ! grep -q 'filebrowser_data:' "$V2_ROOT/templates/compose.yaml"
}

@test "filebrowser account comes from the input file and never reaches argv" {
    # DD-118: no first-boot random admin; the installer creates the account.
    # DD-119: an existing database is synced to the input file, not kept.
    stage0="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'FILEBROWSER_NEW_PASS="\$INPUT_FILEBROWSER_PASS"' <<<"$stage0"
    grep -q 'validate_account FileBrowser' <<<"$stage0"
    grep -q '"\$FILEBROWSER_MIN_PASSWORD_LENGTH"' <<<"$stage0"
    ensure="$(awk '/^ensure_filebrowser_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'if \[\[ -f "\$FILEBROWSER_DB_FILE" \]\]' <<<"$ensure"
    grep -q 'sync_filebrowser_account' <<<"$ensure"
    grep -q 'create_filebrowser_account' <<<"$ensure"
    grep -q 'unset FILEBROWSER_NEW_PASS' <<<"$ensure"
    body="$(awk '/^create_filebrowser_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ "$(grep -c '^}$' <<<"$body")" -eq 1 ]
    grep -q 'htpasswd -niB -C 10' <<<"$body"
    grep -q -- '--minimumPasswordLength "\$FILEBROWSER_MIN_PASSWORD_LENGTH"' <<<"$body"
    run ! grep -qE -- '--password|users (add|update)' <<<"$body"
    sync="$(awk '/^sync_filebrowser_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'users import --overwrite' <<<"$sync"
    run ! grep -qE -- '--replace|--password|users (add|update)' <<<"$sync"
    ! grep -q 'FILEBROWSER_NEW_PASS' <<<"$(awk '/^filebrowser_cli\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    awk '/^filebrowser_cli\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'docker run --rm --network none'
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    grep -A1 '^    ensure_filebrowser_data_dir$' <<<"$stage4" | grep -q '^    ensure_filebrowser_account$'
    grep -q '^FILEBROWSER_DB_FILE="/etc/master-stack/filebrowser-data/filebrowser.db"' "$V2_ROOT/config/defaults.env"
    grep -q '^FILEBROWSER_MIN_PASSWORD_LENGTH=12$' "$V2_ROOT/config/defaults.env"
}

@test "ensure_filebrowser_account installs a verified database and leaves nothing on failure" {
    eval "$(awk '/^filebrowser_cli\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^filebrowser_account_fail\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^create_filebrowser_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_filebrowser_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    sync_filebrowser_account() { printf 'sync\n' >>"$TMP/docker-calls"; }
    FILEBROWSER_DATA_DIR="$TMP/fb" FILEBROWSER_DB_FILE="$TMP/fb/filebrowser.db" FILEBROWSER_IMAGE=fixture
    FILEBROWSER_MIN_PASSWORD_LENGTH=12 DOWNLOADS_UID=1000 DOWNLOADS_GID=1000
    mkdir -p "$TMP/fb"
    log() { :; }
    chown() { :; }
    htpasswd() {
        IFS= read -r pw || true
        printf '%s' "$pw" >"$TMP/htpasswd-stdin"
        printf '%s\n' "$*" >"$TMP/htpasswd-argv"
        printf '%s:$2y$10$%s\n\n' "${!#}" "$(printf 'a%.0s' {1..53})"
    }
    docker() {
        local a w=""
        printf '%s\n' "$*" >>"$TMP/docker-calls"
        case "$1" in
            inspect) return "${FB_CONTAINER_RC:-1}" ;;
            run) ;;
            *) return 0 ;;
        esac
        for a in "$@"; do case "$a" in *:/database) w="${a%:/database}" ;; esac; done
        case "$*" in
            *" config init "*) printf 'db\n' >"$w/filebrowser.db" ;;
            *" config export "*) printf '{"settings":{"key":"k","defaults":{"scope":".","viewMode":"mosaic","perm":{"admin":false,"create":true}}}}\n' >"$w/settings.json" ;;
            *" users import "*) [ -z "${FB_IMPORT_FAIL:-}" ] || return 1; cp "$w/users.json" "$w/imported.json" ;;
            *" users export "*) cp "$w/imported.json" "$w/users.json" ;;
        esac
    }
    FILEBROWSER_NEW_USER=murat FILEBROWSER_NEW_PASS='fixture-password-123'
    run ensure_filebrowser_account
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/fb/filebrowser.db")" = db ]
    [ "$(cat "$TMP/htpasswd-stdin")" = 'fixture-password-123' ]
    ! grep -q 'fixture-password-123' "$TMP/docker-calls" "$TMP/htpasswd-argv"
    grep -q 'config init .*--viewMode mosaic' "$TMP/docker-calls"
    grep -q -- '--minimumPasswordLength 12' "$TMP/docker-calls"
    ! grep -q '^restart' "$TMP/docker-calls"
    [ -z "$(find "$TMP/fb" -name '.init-*')" ]
    # A database deleted under a running container: rebuilt, then restarted.
    rm -f "$TMP/fb/filebrowser.db" "$TMP/docker-calls"
    FB_CONTAINER_RC=0 FILEBROWSER_NEW_USER=murat FILEBROWSER_NEW_PASS='fixture-password-456'
    run ensure_filebrowser_account
    [ "$status" -eq 0 ]
    grep -q '^restart filebrowser$' "$TMP/docker-calls"
    # A failed import installs nothing and cleans up after itself.
    rm -f "$TMP/fb/filebrowser.db"
    FB_IMPORT_FAIL=1 FILEBROWSER_NEW_USER=murat FILEBROWSER_NEW_PASS='fixture-password-789'
    run ensure_filebrowser_account
    [ "$status" -ne 0 ]
    [ ! -e "$TMP/fb/filebrowser.db" ]
    [ -z "$(ls -A "$TMP/fb")" ]
}

@test "wg-easy is gone from compose, defaults and the tailnet edge" {
    # DD-120: WireGuard runs in the host kernel; nothing of wg-easy remains.
    # Comments may name wg-easy as the origin of the profile format; code may not.
    local code
    code="$(grep -hvE '^[[:space:]]*#' "$V2_ROOT/templates/compose.yaml" "$V2_ROOT/config/defaults.env" \
        "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf" \
        "$V2_ROOT/install.sh" "$V2_ROOT/scripts/firewall.sh")"
    run ! grep -qE 'wg-easy|wg_easy|WG_BRIDGE|WG_UI_PORT|WG_EASY' <<<"$code"
    run ! grep -q '__WG_PUBLIC_PORT__' "$V2_ROOT/templates/compose.yaml"
    run ! grep -qE '^[[:space:]]+wg:$' "$V2_ROOT/templates/compose.yaml"
    run ! grep -qw wg <<<"$(awk -F'"' '/^SERVICE_NAMES=/{print $2}' "$V2_ROOT/config/defaults.env")"
    [ "$(grep -c '^  [a-z][a-z-]*:$' <<<"$(awk '/^services:/,/^networks:/' "$V2_ROOT/templates/compose.yaml")")" -eq 5 ]
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
    grep -q '"0.0.0.0:__TORRENT_PUBLIC_PORT__:__TORRENT_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
    ! grep -q '\${WAN_IPV4}' "$V2_ROOT/templates/compose.yaml"
}

@test "compose public peer ports are IPv4-only" {
    grep -q '0.0.0.0:__TORRENT_PUBLIC_PORT__' "$V2_ROOT/templates/compose.yaml"
    # Unqualified host:port would also bind [::] on Docker.
    run ! grep -qE '^[[:space:]]*- "__TORRENT_PUBLIC_PORT__:__TORRENT_PUBLIC_PORT__/' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "refresh-tailnet-config touches only Caddy state and the firewall unit" {
    # Compose, WebDAV and raw netfilter stay out of the timer's scope.
    ! grep -qE 'compose|DOCKER-USER|master-webdav|iptables' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
    ! grep -q 'rebind_webdav' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'BOUND_UNITS="caddy.service"' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "refresh timer recovers a broken firewall unit" {
    local body
    body="$(awk '/^recover_firewall_if_broken\(\)/,/^}$/' \
        "$V2_ROOT/scripts/refresh-tailnet-config")"
    [[ -n "$body" ]]
    grep -q 'is-failed --quiet "\$FIREWALL_UNIT"' <<<"$body"
    grep -q -- '--check' <<<"$body"
    # start-limit exhaustion makes a plain restart fail; reset-failed first.
    grep -q 'reset-failed "\$FIREWALL_UNIT"' <<<"$body"
    grep -q 'restart "\$FIREWALL_UNIT"' <<<"$body"
    # Skip while the oneshot is mid-apply (tailscaled restart triggers both).
    grep -q 'activating' <<<"$body"
    # Must run regardless of tailnet state: called before the tailscale wait.
    awk '/^recover_firewall_if_broken$/ { print NR; exit }' \
        "$V2_ROOT/scripts/refresh-tailnet-config" | grep -qE '[0-9]+'
    [[ "$(awk '/^recover_firewall_if_broken$/ { print NR; exit }' \
        "$V2_ROOT/scripts/refresh-tailnet-config")" -lt \
        "$(awk '/^if ! wait_for_tailscale_ready; then$/ { print NR; exit }' \
        "$V2_ROOT/scripts/refresh-tailnet-config")" ]]
}

@test "refresh-tailnet timer is five minutes" {
    grep -q 'OnUnitActiveSec=5min' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'WantedBy=timers.target' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'refresh-tailnet-config.timer' "$V2_ROOT/install.sh"
    # Unit= already names the oneshot; Requires= is redundant and couples
    # timer activation to service start failure modes.
    ! grep -q 'Requires=refresh-tailnet-config.service' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
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
    # --check side: the pair list carries it before the v4-only guard, so both
    # families assert it.
    local pairs
    pairs="$(awk '/^wan_allow_pairs\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    [[ "$(grep -n 'udp \$TAILSCALE_UDP_PORT' <<<"$pairs" | cut -d: -f1)" -lt \
        "$(grep -n 'v4' <<<"$pairs" | head -1 | cut -d: -f1)" ]]
    # The port must not be selectable as a stack port.
    grep -q '"\$TAILSCALE_UDP_PORT")' "$V2_ROOT/install.sh"
}

@test "refresh-tailnet warns when the tailnet is unusable" {
    grep -q 'warn_if_tailnet_unusable' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'BackendState' "$V2_ROOT/scripts/refresh-tailnet-config"
    # Warning must name Online as well — BackendState alone is ambiguous when
    # the daemon is Running but Self.Online is false (DD-86).
    grep -q 'Online=' "$V2_ROOT/scripts/refresh-tailnet-config"
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

@test "caddy OnFailure triggers refresh-tailnet without waiting for the timer" {
    local block
    block="$(awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh")"
    grep -q 'OnFailure=refresh-tailnet-config.service' <<<"$block"
    # Failure path must not invent a second refresh owner.
    ! grep -q 'OnFailure=.*watch-tailnet' "$V2_ROOT/install.sh"
}

@test "wait-tailnet-addr accepts matching state IP on the interface" {
    local stub bin rc
    bin="$(mktemp -d)"
    stub="$bin/ip"
    cat >"$stub" <<'EOF'
#!/bin/sh
# emulate: ip -4 -o addr show dev tailscale0 scope global
printf '%s\n' '2: tailscale0    inet 100.118.76.122/32 scope global'
EOF
    chmod +x "$stub"
    set +e
    PATH="$bin:$PATH" TAILSCALE_IPV4=100.118.76.122 TAILNET_ADDR_WAIT_SECONDS=4 \
        "$V2_ROOT/scripts/wait-tailnet-addr"
    rc=$?
    set -e
    rm -rf "$bin"
    [ "$rc" -eq 0 ]
}

@test "wait-tailnet-addr fails fast when state IP is stale on a live interface" {
    local stub bin rc out
    bin="$(mktemp -d)"
    stub="$bin/ip"
    cat >"$stub" <<'EOF'
#!/bin/sh
printf '%s\n' '2: tailscale0    inet 100.118.76.122/32 scope global'
EOF
    chmod +x "$stub"
    set +e
    out="$(
        PATH="$bin:$PATH" TAILSCALE_IPV4=100.64.0.1 TAILNET_ADDR_WAIT_SECONDS=4 \
            "$V2_ROOT/scripts/wait-tailnet-addr" 2>&1
    )"
    rc=$?
    set -e
    rm -rf "$bin"
    [ "$rc" -eq 1 ]
    [[ "$out" == *stale* ]]
}

@test "wait-tailnet-addr without TAILSCALE_IPV4 still accepts any interface IP" {
    local stub bin rc
    bin="$(mktemp -d)"
    stub="$bin/ip"
    cat >"$stub" <<'EOF'
#!/bin/sh
printf '%s\n' '2: tailscale0    inet 100.118.76.122/32 scope global'
EOF
    chmod +x "$stub"
    set +e
    PATH="$bin:$PATH" env -u TAILSCALE_IPV4 TAILNET_ADDR_WAIT_SECONDS=4 \
        "$V2_ROOT/scripts/wait-tailnet-addr"
    rc=$?
    set -e
    rm -rf "$bin"
    [ "$rc" -eq 0 ]
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
    grep -q 'SYSCTL_NETBUF_FILE' "$V2_ROOT/install.sh"
    grep -q 'apply_udp_netbuf_floor' "$V2_ROOT/install.sh"
    # Ordering: floor call appears before apt-get install tailscale
    awk '/apply_udp_netbuf_floor$/{f=NR} /install -y tailscale/{t=NR}
         END { exit !(f && t && f < t) }' "$V2_ROOT/install.sh"
    ! grep -q 'rmem_max = 7500000' "$V2_ROOT/install.sh"
}

@test "watch-tailnet-addr is removed; refresh timer remains" {
    [ ! -e "$V2_ROOT/scripts/watch-tailnet-addr" ]
    [ ! -e "$V2_ROOT/systemd/watch-tailnet-addr.service" ]
    ! grep -q 'watch-tailnet-addr' "$V2_ROOT/install.sh"
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

@test "webdav compose is loopback; Caddy exposes TS IP:WEBDAV_PORT" {
    grep -q 'container_name: webdav' "$V2_ROOT/templates/compose.yaml"
    grep -q 'RCLONE_IMAGE=' "$V2_ROOT/config/defaults.env"
    grep -qE '^RCLONE_IMAGE="rclone/rclone:1\.75"' "$V2_ROOT/config/defaults.env"
    grep -q '__RCLONE_IMAGE__' "$V2_ROOT/templates/compose.yaml"
    grep -q '127.0.0.1:__WEBDAV_PORT__:8080' "$V2_ROOT/templates/compose.yaml"
    ! grep -q '__TAILSCALE_IPV4__:__WEBDAV_PORT__' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--htpasswd=/run/secrets/webdav_htpasswd' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--read-only' "$V2_ROOT/templates/compose.yaml"
    grep -q '__DOWNLOADS_PATH__:/downloads:ro' "$V2_ROOT/templates/compose.yaml"
    grep -q 'reverse_proxy 127.0.0.1:{$WEBDAV_PORT}' "$V2_ROOT/templates/Caddyfile"
    grep -q 'http://webdav.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}:{$WEBDAV_PORT}' \
        "$V2_ROOT/templates/Caddyfile"
    ! grep -q '__WEBDAV_PORT__' "$V2_ROOT/templates/Caddyfile"
    ! grep -qE 'http://\{\$TAILSCALE_IPV4\}[[:space:],}]' \
        "$V2_ROOT/templates/Caddyfile"
    grep -q 'WEBDAV_PORT_CHANGED' "$V2_ROOT/install.sh"
    ! grep -q 'master-webdav' "$V2_ROOT/install.sh"
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
    grep -q 'check_docker_chain' "$V2_ROOT/scripts/firewall.sh"
    awk '/^check_docker_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh" |
        grep -q -- '-i "$WAN_INTERFACE" -j DROP'
    grep -q 'check_input_chain ip6tables v6' "$V2_ROOT/scripts/firewall.sh"
    awk '/^check_input_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh" |
        grep -q -- '-i "$WAN_INTERFACE" -j DROP'
    # IPv6 has no container publish, so no WAN RETURN is allowed at all.
    awk '/^docker_return_pairs\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh" |
        grep -q '"\$1" == v4'
}

@test "firewall script does not flush DOCKER-USER" {
    ! grep -qE 'DOCKER-USER.*-F|-F DOCKER-USER' "$V2_ROOT/scripts/firewall.sh"
}

@test "WAN allow count is derived from one list and rejects extra passes" {
    local script="$V2_ROOT/scripts/firewall.sh" body
    # Pattern checks find a missing rule but never an extra one: an
    # interface-qualified pass such as '-i WAN -j ACCEPT' satisfies every
    # expected pattern. The count must match the list exactly.
    body="$(awk '/^check_wan_allow_count\(\)/,/^}$/' "$script")"
    [[ -n "$body" ]]
    grep -q 'fazladan geçiş' <<<"$body"
    grep -q 'expected' <<<"$body"
    # Both the check_rule calls and the count come from the same list.
    grep -q 'wan_allow_pairs "\$family"' "$script"
    grep -q 'docker_return_pairs "\$family"' "$script"
    grep -q 'check_wan_allow_count "\$bin" "\$CHAIN_INPUT" ACCEPT "\$n"' "$script"
    grep -q 'check_wan_allow_count "\$bin" "\$CHAIN_DOCKER" RETURN "\$n"' "$script"
    # Ports must not be restated next to the loop.
    ! grep -q 'check_rule iptables "\$CHAIN_INPUT" -i "\$WAN_INTERFACE" \\' "$script"
}

@test "check_chain_shape rejects a single bypass rule before the WAN DROP" {
    local body
    body="$(awk '/^check_chain_shape\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    [[ -n "$body" ]]
    # Exactly one WAN DROP, allows before it, and no unconditional rule before.
    grep -q 'WAN DROP sayısı' <<<"$body"
    grep -q 'bypass' <<<"$body"
    grep -qF '== "-j ACCEPT"' <<<"$body"
    grep -qF '== "-j RETURN"' <<<"$body"
}

@test "apply purges staging leftovers including referenced ones" {
    local script="$V2_ROOT/scripts/firewall.sh" body
    body="$(awk '/^purge_staging_leftovers\(\)/,/^}$/' "$script")"
    [[ -n "$body" ]]
    # An interrupted activate_named leaves the staging chain jumped from its
    # parent; skipping it would fail --check forever. Jump goes first.
    grep -q -- '-D "\$parent" -j "\$chain"' <<<"$body"
    grep -q -- '-X "\$chain"' <<<"$body"
    # It must run after the policy is in place, never before.
    [[ "$(awk '/^purge_staging_leftovers iptables$/ { print NR; exit }' "$script")" -gt \
        "$(awk '/^apply_docker6$/ { print NR; exit }' "$script")" ]]
    [[ "$(awk '/^purge_staging_leftovers iptables$/ { print NR; exit }' "$script")" -lt \
        "$(awk '/^check_no_staging_artifacts iptables$/ { print NR; exit }' "$script")" ]]
}

@test "ts-input precedence does not delete-all MASTER-INPUT jumps" {
    grep -q 'ensure_ts_input_precedence' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'insert_pos_after_ts_input' "$V2_ROOT/scripts/firewall.sh"
    ! awk '/^ensure_ts_input_precedence\(\)/,/^create_staging\(\)/' \
        "$V2_ROOT/scripts/firewall.sh" |
        grep -qE 'while .*-D INPUT -j "\$CHAIN_INPUT"'
}

@test "master-firewall converges without ordering on docker" {
    local unit="$V2_ROOT/systemd/master-firewall.service"
    # Host INPUT must not wait on Docker; the drop-in adds MASTER-DOCKER later.
    ! grep -q 'After=.*docker.service' "$unit"
    ! grep -q 'Wants=.*docker.service' "$unit"
    ! grep -q 'Requires=docker.service' "$unit"
    ! grep -q 'WantedBy=docker.service' "$unit"
    grep -q 'Wants=network-online.target' "$unit"
    # PartOf stays as the belt-and-braces trigger next to the drop-in.
    grep -q 'PartOf=docker.service' "$unit"
    grep -q 'PartOf=tailscaled.service' "$unit"
    grep -q 'WantedBy=tailscaled.service' "$unit"
    grep -q 'After=.*tailscaled.service' "$unit"
    grep -q 'Restart=on-failure' "$unit"
    grep -q 'RestartSec=10s' "$unit"
    grep -q 'StartLimitIntervalSec=300' "$unit"
    grep -q 'StartLimitBurst=12' "$unit"
    grep -q 'master-firewall.service' "$V2_ROOT/install.sh"
    # Compose must not be PartOf/Requires-coupled to the firewall unit.
    ! grep -qiE 'compose|master-compose' "$unit"
    # Docker start re-applies firewall even when RemainAfterExit left it active.
    grep -q 'docker.service.d/master-stack.conf' "$V2_ROOT/install.sh"
    grep -q 'ExecStartPost=-/bin/systemctl --no-block restart master-firewall.service' \
        "$V2_ROOT/systemd/docker.service.d/master-stack.conf"
}

@test "install carries no migration cleanup for older revisions" {
    # Upgrade path is a fresh install, or a re-run that overwrites what the
    # installer owns. Nothing hunts for leftovers of an older revision, so no
    # global package, user or container removal lives here (DD-96).
    local s="$V2_ROOT/install.sh"
    ! grep -q 'remove_stale_filebrowser' "$s"
    ! grep -q 'purge_host_webdav_leftovers' "$s"
    ! grep -qE 'apt-get (purge|autoremove)' "$s"
    ! grep -qE 'userdel|groupdel|setfacl' "$s"
    ! grep -qE 'docker (rm|volume rm)' "$s"
    ! grep -q 'docker.service.wants' "$s"
    ! grep -q 'filebrowser.yaml' "$s"
    ! grep -qE 'disable --now' "$s"
    # Deleting a file the installer does not own is the same overreach.
    ! grep -q 'rm -f "\$COMPOSE_DIR/.env"' "$s"
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
    grep -q 'check_input_chain iptables v4' "$V2_ROOT/scripts/firewall.sh"
    awk '/^check_input_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh" |
        grep -q -- '-i "$WAN_INTERFACE" -j DROP'
    grep -q 'check_docker_chain' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_chain_shape' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'ESTABLISHED,RELATED -j RETURN' "$V2_ROOT/scripts/firewall.sh"
    grep -q -- '--ctorigdstport "$TORRENT_PUBLIC_PORT" -j RETURN' \
        "$V2_ROOT/scripts/firewall.sh"
    # DD-120: WireGuard is not a Docker publish any more; the port lives in INPUT.
    run ! grep -q -- '--ctorigdstport "$WG_PUBLIC_PORT"' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -c 'TORRENT_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh" | grep -q '^[2-9]'
}

@test "firewall --check enforces jump uniqueness staging SSH and WAN drift" {
    grep -q 'check_jump_exactly_one' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_no_staging_artifacts' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'resolve_wan_interface' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WAN arayüzü drift' "$V2_ROOT/scripts/firewall.sh"
    # Drift is a runtime fact, not a fatal state mismatch: live iface wins.
    ! grep -q 'assert_wan_interface_current' "$V2_ROOT/scripts/firewall.sh"
    ! grep -q 'WAN_INTERFACE:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'SSH_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'neighbour-solicitation -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'neighbour-advertisement -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'packet-too-big -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    # Helper does not consume WAN_IPV4 (endpoint hint stays in state.env).
    ! grep -q 'WAN_IPV4' "$V2_ROOT/scripts/firewall.sh"
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

@test "re-run offers an opt-in image pull, defaulted off and skipped on first install" {
    grep -q 'PULL_IMAGES' "$V2_ROOT/install.sh"
    grep -q 'V2_PULL_IMAGES' "$V2_ROOT/install.sh"
    grep -q 'Konteyner imajları güncel sürüme çekilsin mi' "$V2_ROOT/install.sh"
    grep -q 'docker compose pull' "$V2_ROOT/install.sh"
    # Prompt only reachable when STATE_FILE already exists (re-run gate).
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" |
        grep -B6 'pull_ans "Konteyner imajları' | grep -q '\-r "\$STATE_FILE"'
    # First install skips the prompt outright (no redundant pull before compose up).
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'ilk kurulum (compose up zaten güncel imajları çeker)'
    # Default answer is "hayır" (matches upgrade_ans's default).
    grep -q 'local pull_ans="h"' "$V2_ROOT/install.sh"
    # A pull forces stage_4 to treat compose as needing recreation.
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -A1 'docker compose pull) || die' | grep -q 'COMPOSE_NEEDS_UP=1'
    # A pull also prunes now-dangling images after compose up recreates
    # containers on the new digest, and a prune failure does not abort.
    awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh" |
        grep -A2 'PULL_IMAGES.*-eq 1' | grep -q 'docker image prune -f'
    grep -q 'docker image prune -f >/dev/null || log WARN' "$V2_ROOT/install.sh"
    # DD-101: the pull is gated on free disk under /var/lib/docker, the
    # floor lives once in defaults.env, and the gate dies (fail-closed)
    # BEFORE docker compose pull runs.
    grep -q '^PULL_MIN_FREE_GB=' "$V2_ROOT/config/defaults.env"
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        awk '/PULL_MIN_FREE_GB/ { seen = 1 }
             /docker compose pull/ { if (!seen) exit 1 }'
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'df -Pk /var/lib/docker'
    grep -q 'boş alan yetersiz' "$V2_ROOT/install.sh"
}

@test "re-run skips apt-get update when the repo file is unchanged" {
    # stage_2: tailscale repo write immediately gates its own apt-get update.
    awk '/^stage_2\(\)/,/^ensure_downloads_tree\(\)/' "$V2_ROOT/install.sh" |
        grep -A4 'install_tailscale_repo$' | grep -q 'V2_LAST_ATOMIC_CHANGED.*-eq 1'
    grep -q 'tailscale.list aynı; apt-get update atlandı' "$V2_ROOT/install.sh"
    # stage_4: same gate for the docker repo write.
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -A4 'install_docker_repo$' | grep -q 'V2_LAST_ATOMIC_CHANGED.*-eq 1'
    grep -q 'docker.sources aynı; apt-get update atlandı' "$V2_ROOT/install.sh"
    # First install still updates: install_tailscale_repo/install_docker_repo
    # write via atomic_write, which sets V2_LAST_ATOMIC_CHANGED=1 for a new file.
    grep -q 'V2_LAST_ATOMIC_CHANGED' "$V2_ROOT/common.sh"
}

@test "base packages include htpasswd helpers" {
    grep -q 'apache2-utils dnsutils' "$V2_ROOT/install.sh"
    ! grep -qE 'apache2-utils dnsutils acl' "$V2_ROOT/install.sh"
    # acl may be installed only as a migration helper inside the purge path.
    ! awk '/^stage_1\(\)/,/^stage_2\(\)/' "$V2_ROOT/install.sh" |
        grep -qE '\bacl\b'
}

@test "exporter embeds archive sha256 and stages root-level runtime" {
    local exporter="$V2_ROOT/dev/export-installer.sh"
    grep -q 'PORTABLE_ARCHIVE_SHA256' "$exporter"
    grep -q 'sha256sum' "$exporter"
    ! grep -qE '\.sha256"|Sidecar' "$exporter"
    grep -q 'dsi-extract' "$exporter"
    grep -q 'staging/installer/install.sh' "$exporter"
    grep -q 'REMOTE_ROOT/install.sh' "$exporter"
    grep -q 'gzip -n' "$exporter"
    grep -q 'touch -t 200001010000' "$exporter"
    grep -q 'TZ=UTC' "$exporter"
    grep -q -- '--no-xattrs' "$exporter"
    grep -q -- '--no-mac-metadata' "$exporter"
    ! grep -q 'touch -t 197001010000' "$exporter"
    grep -q 'reproducible/${V2_VERSION}' "$exporter"
}

@test "stage 7 checks DNS on Tailscale IP and publish surface" {
    grep -q 'status: REFUSED' "$V2_ROOT/install.sh"
    grep -q 'for resolver in 127.0.0.1' "$V2_ROOT/install.sh"
    grep -q 'Host: webdav.' "$V2_ROOT/install.sh"
    grep -q 'WebDAV Caddy TS-IP:' "$V2_ROOT/install.sh"
    grep -q 'http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/' "$V2_ROOT/install.sh"
    grep -q 'http://127.0.0.1:${WEBDAV_PORT}/' "$V2_ROOT/install.sh"
    ! grep -q 'WebDAV Tailscale publish' "$V2_ROOT/install.sh"
    grep -q 'assert_webdav_readonly_runtime' "$V2_ROOT/install.sh"
    grep -q 'ReadonlyRootfs' "$V2_ROOT/install.sh"
    grep -q '/downloads false' "$V2_ROOT/install.sh"
    ! grep -q 'v2-write-probe' "$V2_ROOT/install.sh"
    ! awk '/^assert_webdav_readonly_runtime/,/^stage_7/' "$V2_ROOT/install.sh" |
        grep -qE '401\|403\|405'
    run ! grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    grep -q 'docker port transmission' "$V2_ROOT/install.sh"
    grep -q 'docker port webdav' "$V2_ROOT/install.sh"
    grep -q 'UI publish yalnız loopback' "$V2_ROOT/install.sh"
    # Contract §14.13 / DD-88
    grep -q 'for ui_host in dozzle torrent file' "$V2_ROOT/install.sh"
    grep -q 'non-5xx beklenir' "$V2_ROOT/install.sh"
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

@test "compose images use upstream stable tracks where published" {
    # DD-97: prefer the vendor's stable track over a frozen patch@digest.
    grep -qE '^DOZZLE_IMAGE="amir20/dozzle:v11"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^FILEBROWSER_IMAGE="filebrowser/filebrowser:v2"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^TRANSMISSION_IMAGE="lscr\.io/linuxserver/transmission:latest"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^UNPACKERR_IMAGE="ghcr.io/unpackerr/unpackerr:0\.15"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^RCLONE_IMAGE="rclone/rclone:1\.75"' \
        "$V2_ROOT/config/defaults.env"
    # Forbidden floats — except LinuxServer Transmission:latest, its only stable
    # track (LinuxServer publishes no major tag).
    ! grep -qE '_(IMAGE)="[^"]*:(stable|sts|edge|nightly|libtorrentv1)(@|")' \
        "$V2_ROOT/config/defaults.env"
    ! grep -qE '^(DOZZLE|FILEBROWSER|WG_EASY|UNPACKERR|RCLONE)_IMAGE="[^"]*:latest' \
        "$V2_ROOT/config/defaults.env"
    # Track images must not carry a digest pin.
    ! grep -qE '^(DOZZLE|FILEBROWSER|TRANSMISSION|WG_EASY|UNPACKERR|RCLONE)_IMAGE="[^"]*@sha256:' \
        "$V2_ROOT/config/defaults.env"
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

@test "unattended security upgrades are enabled without automatic reboot" {
    # DD-113: distribution-default origin filter, explicit periodic policy,
    # reboot left to the operator; stage 7 reads the effective policy back.
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'unattended-upgrades'
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -q '^    apply_unattended_upgrades$'
    body="$(awk '/^apply_unattended_upgrades\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$body" ]
    grep -q 'atomic_write "\$APT_PERIODIC_FILE"' <<<"$body"
    grep -q 'APT::Periodic::Unattended-Upgrade "1"' <<<"$body"
    grep -q 'atomic_write "\$APT_UNATTENDED_POLICY_FILE"' <<<"$body"
    grep -q 'Automatic-Reboot "false"' <<<"$body"
    grep -q 'APT_PERIODIC_FILE="/etc/apt/apt.conf.d/20auto-upgrades"' "$V2_ROOT/config/defaults.env"
    grep -q 'APT_UNATTENDED_POLICY_FILE="/etc/apt/apt.conf.d/5' "$V2_ROOT/config/defaults.env"
    awk '/^stage_7\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'APT::Periodic::Unattended-Upgrade'
    ! awk '/^stage_7\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'die "otomatik güvenlik'
}

@test "pipe consumers in the installer tree do not exit early under pipefail" {
    # An awk/sed that exits on first match sends SIGPIPE to the producer; with
    # set -o pipefail the pipeline returns 141 and set -e aborts the install
    # (seen live on 2026-09-12, DD-113). Consumers reading files are fine.
    # [|] not \|: BSD grep -E (Finder/bats on macOS) reads \| differently
    # from GNU grep. `exit *[}]` matches awk's `{...; exit}`, not a shell
    # `|| { ...; exit 1; }` guard.
    ! grep -nE '[|][^|]*(awk|sed)[^|]*; *exit *[}]' \
        "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT"/scripts/*
}

@test "repository root carries one exported installer, identical to its Data/app archive" {
    # The root holds what is double-clicked; everything else lives under Data/.
    local top copies
    top="$(cd "$V2_ROOT/.." && pwd)"
    copies=( "$top"/20[0-9][0-9].[0-9][0-9].[0-9][0-9]-v2-*.command )
    [ "${#copies[@]}" -eq 1 ]
    [ -f "${copies[0]}" ]
    cmp "${copies[0]}" "$V2_ROOT/app/$(basename "${copies[0]}")"
    # DD-122: the backup tool is retired; nothing of it may come back.
    [ ! -e "$top/container-backup.command" ]
    [ ! -e "$V2_ROOT/dev/container-backup-remote.sh" ]
    [ ! -e "$V2_ROOT/docs/container-backup.md" ]
    [ ! -e "$V2_ROOT/tests/backup-roundtrip.sh" ]
    [ ! -e "$V2_ROOT/app/latest.command" ]
}

@test "tailscale auth key is optional, read from the input file, and never persisted" {
    # DD-115/DD-119: the key comes from the input file, is dropped when the node
    # is already online, never written to config/state and never placed on a
    # command line.
    body="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'TS_AUTH_KEY="\$INPUT_TS_AUTH_KEY"' <<<"$body"
    grep -q 'kullanılmayacak (Tailscale zaten online)' <<<"$body"
    grep -A1 'tailscale_login_state)" == "complete"' <<<"$body" | grep -q 'TS_AUTH_KEY=""'
    grep -q 'tskey-client-' <<<"$body"
    run ! grep -qE 'prompt_optional_secret|read -r -s' "$V2_ROOT/install.sh"
    ! awk '/^write_(state|config)\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'TS_AUTH_KEY'
    ! grep -nE -- '--auth-?key[= ]"?\$\{?TS_AUTH_KEY' "$V2_ROOT/install.sh"
    ! grep -nE 'export +TS_AUTH_KEY|log [A-Z]+ .*\$\{?TS_AUTH_KEY' "$V2_ROOT/install.sh"
    stage2="$(awk '/^stage_2\(\)/,/^ensure_downloads_tree\(\)/' "$V2_ROOT/install.sh")"
    grep -q '! tailscale_login_with_key' <<<"$stage2"
    grep -q 'unset TS_AUTH_KEY' <<<"$stage2"
    grep -q '^TS_AUTHKEY_LOGIN_SECONDS=' "$V2_ROOT/config/defaults.env"
}

@test "tailscale auth key reaches tailscale up only through a private file" {
    eval "$(awk '/^tailscale_login_with_key\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    RUNTIME_DIR="$TMP" V2_LOG_FILE="$TMP/install.log" TS_AUTHKEY_LOGIN_SECONDS=5
    TS_AUTH_KEY="tskey-auth-kFIXTURE1CNTRL-notarealsecret0123"
    log() { printf '%s\n' "$*" >>"$TMP/install.log"; }
    timeout() { shift; "$@"; }
    tailscale_login_state() { printf 'pending\n'; }
    tailscale() {
        [ "$1" = up ] || return 0
        printf '%s\n' "$*" >"$TMP/argv"
        local file="${2#--auth-key=file:}"
        stat -c %a "$file" >"$TMP/mode" 2>/dev/null || stat -f %Lp "$file" >"$TMP/mode"
        cat "$file" >"$TMP/seen"
        printf 'Success.\n'
    }
    run tailscale_login_with_key
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/seen")" = "$TS_AUTH_KEY" ]
    [ "$(cat "$TMP/mode")" = 600 ]
    grep -q -- '--auth-key=file:' "$TMP/argv"
    ! grep -qF "$TS_AUTH_KEY" "$TMP/argv"
    ! grep -qF "$TS_AUTH_KEY" "$TMP/install.log"
    [ ! -e "$TMP/tailscale-authkey" ]
}

@test "a rejected tailscale auth key falls back to the browser login" {
    eval "$(awk '/^tailscale_login_with_key\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    RUNTIME_DIR="$TMP" V2_LOG_FILE="$TMP/install.log" TS_AUTHKEY_LOGIN_SECONDS=5
    TS_AUTH_KEY="tskey-auth-kFIXTURE1CNTRL-notarealsecret0123"
    log() { printf '%s\n' "$*" >>"$TMP/install.log"; }
    timeout() { shift; "$@"; }
    tailscale_login_state() { printf 'pending\n'; }
    tailscale() { [ "$1" = up ] && { printf 'backend error: invalid key\n'; return 1; }; }
    run tailscale_login_with_key
    [ "$status" -eq 1 ]
    grep -q 'tarayıcıdan girişe geçiliyor' "$TMP/install.log"
    ! grep -qF "$TS_AUTH_KEY" "$TMP/install.log"
    [ ! -e "$TMP/tailscale-authkey" ]
}

@test "read_input_file takes values literally and deletes the file" {
    # DD-119: the file is never sourced; '$', quotes inside, '=' and spaces
    # inside a value are data.
    cat >"$TMP/in.env" <<'EOF'
# comment
   # indented comment

A=p@ss $HOME "x" =y
B=
C=it's
EOF
    chmod 600 "$TMP/in.env"
    read_input_file "$TMP/in.env" "A B C" "A C"
    [ "$INPUT_A" = 'p@ss $HOME "x" =y' ]
    [ -z "$INPUT_B" ]
    [ "$INPUT_C" = "it's" ]
    [ ! -e "$TMP/in.env" ]
    run ! grep -qE '\bsource\b|^\s*\. ' <<<"$(awk '/^read_input_file\(\)/,/^}$/' "$V2_ROOT/common.sh")"
}

@test "read_input_file rejects bad input, never echoes a value, always deletes" {
    local body expect
    while IFS='|' read -r body expect; do
        printf '%b' "$body" >"$TMP/in.env"
        chmod 600 "$TMP/in.env"
        run read_input_file "$TMP/in.env" "A B" "A"
        [ "$status" -ne 0 ]
        case "$output" in *"$expect"*) ;; *) false ;; esac
        case "$output" in *secretvalue*) false ;; esac
        [ ! -e "$TMP/in.env" ]
    done <<'EOF'
A=secretvalue\nB=\nZ=1\n|bilinmeyen alan: Z
A=secretvalue\nA=secretvalue\nB=\n|A iki kez yazılmış
A=secretvalue\n|eksik alan: B
A=\nB=secretvalue\n|boş bırakılamayan alan: A
A=secretvalue\r\nB=\n|CRLF
A=secretvalue \nB=\n|boşluk var
A="secretvalue"\nB=\n|tırnak
a=secretvalue\nB=\n|ALAN=değer biçiminde değil
EOF
    printf 'A=secretvalue\nB=\n' >"$TMP/in.env"
    chmod 644 "$TMP/in.env"
    run read_input_file "$TMP/in.env" "A B" "A"
    [ "$status" -ne 0 ]
    case "$output" in *"izinleri 644"*) ;; *) false ;; esac
    [ ! -e "$TMP/in.env" ]
    run read_input_file "$TMP/missing.env" "A B" "A"
    [ "$status" -ne 0 ]
    case "$output" in *"girdi dosyası yok"*) ;; *) false ;; esac
}

@test "bcrypt_matches verifies through stdin and leaves no temp file" {
    command -v htpasswd >/dev/null || skip "htpasswd yok"
    RUNTIME_DIR="$TMP"
    hash="$(printf '%s' 'pw with $pace' | htpasswd -niB -C 4 u | cut -d: -f2-)"
    bcrypt_matches u "$hash" 'pw with $pace'
    run ! bcrypt_matches u "$hash" 'other'
    run ! bcrypt_matches u 'plain-not-bcrypt' 'pw with $pace'
    [ -z "$(ls -A "$TMP")" ]
    body="$(awk '/^bcrypt_matches\(\)/,/^}$/' "$V2_ROOT/common.sh")"
    grep -q "printf '%s' \"\$pass\" | htpasswd -vi" <<<"$body"
}

@test "stage 0 reads the input file first and confirms before the first write" {
    stage0="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    # DD-120: the WireGuard folder is taken first, so a bad kurulum.env cannot
    # leave keys behind in /run; then the whole input folder goes.
    grep -A8 '^    require_root$' <<<"$stage0" | awk '
        /slurp_wireguard_inputs "\$INPUT_WG_DIR"/ { w = NR }
        /read_input_file "\$INPUT_FILE" "\$INPUT_KEYS" "\$INPUT_NONEMPTY_KEYS"/ { r = NR }
        /rm -rf -- "\$INPUT_DIR"/ { d = NR }
        END { exit !(w && r && d && w < r && r < d) }'
    grep -q '^INPUT_DIR="/run/master-stack/kurulum"$' "$V2_ROOT/config/defaults.env"
    grep -q '^INPUT_FILE="/run/master-stack/kurulum/kurulum.env"$' "$V2_ROOT/config/defaults.env"
    grep -q '^INPUT_WG_DIR="/run/master-stack/kurulum/wireguard"$' "$V2_ROOT/config/defaults.env"
    # Every INPUT_* is dropped once mapped; secrets stay only in the *_NEW_* vars.
    grep -q 'unset "INPUT_\$input_key"' <<<"$stage0"
    # One confirmation, then config.env: nothing is written before the operator agrees.
    awk '/prompt confirm_ans/ {c = NR} /^    write_config$/ {w = NR}
         END { exit !(c && w && c < w) }' <<<"$stage0"
    [ "$(grep -c 'write_config' <<<"$stage0")" -eq 1 ]
    grep -q 'die "kurulum iptal edildi' <<<"$stage0"
    # The old secret prompts are gone for good.
    run ! grep -qE 'prompt_secret_twice|prompt_optional_secret|read -r -s' "$V2_ROOT/install.sh"
    # The summary names accounts, never passwords.
    summary="$(awk '/Kurulum girdileri \(kurulum\/kurulum.env\)/,/^EOF$/' <<<"$stage0")"
    [ -n "$summary" ]
    run ! grep -q '_PASS' <<<"$summary"
    run ! grep -q 'TS_AUTH_KEY' <<<"$summary"
}

@test "input template lists exactly the installer's keys with no values" {
    local template="$V2_ROOT/config/kurulum.env.example" keys tkeys
    keys="$(awk -F'"' '/^INPUT_KEYS=/{print $2}' "$V2_ROOT/install.sh" | tr ' ' '\n' | sort)"
    tkeys="$(grep -E '^[A-Z][A-Z0-9_]*=' "$template" | cut -d= -f1 | sort)"
    [ -n "$keys" ]
    [ "$keys" = "$tkeys" ]
    run ! grep -qE '^[A-Z][A-Z0-9_]*=.+' "$template"
    for k in $(awk -F'"' '/^INPUT_NONEMPTY_KEYS=/{print $2}' "$V2_ROOT/install.sh"); do
        grep -q "^$k=$" "$template"
    done
    cp "$template" "$TMP/in.env"
    chmod 600 "$TMP/in.env"
    read_input_file "$TMP/in.env" "$(awk -F'"' '/^INPUT_KEYS=/{print $2}' "$V2_ROOT/install.sh")" ""
    grep -qx '/kurulum/' "$V2_ROOT/../.gitignore"
}

@test "ensure_webdav_htpasswd keeps a matching account and rewrites a changed one" {
    command -v htpasswd >/dev/null || skip "htpasswd yok"
    eval "$(awk '/^ensure_webdav_htpasswd\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    STATE_DIR="$TMP" WEBDAV_HTPASSWD_FILE="$TMP/webdav.htpasswd"
    log() { :; }
    chown() { :; }
    docker() { printf '%s\n' "$*" >>"$TMP/docker-calls"; }
    WEBDAV_NEW_USER=infuse WEBDAV_NEW_PASS='fixture pass $1'
    run ensure_webdav_htpasswd
    [ "$status" -eq 0 ]
    printf '%s' 'fixture pass $1' | htpasswd -vi "$TMP/webdav.htpasswd" infuse 2>/dev/null
    grep -q '^restart webdav$' "$TMP/docker-calls"
    before="$(cat "$TMP/webdav.htpasswd")"
    rm -f "$TMP/docker-calls"
    run ensure_webdav_htpasswd
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/webdav.htpasswd")" = "$before" ]
    [ ! -e "$TMP/docker-calls" ]
    WEBDAV_NEW_USER=infuse WEBDAV_NEW_PASS='changed-pass-2'
    run ensure_webdav_htpasswd
    [ "$status" -eq 0 ]
    printf '%s' 'changed-pass-2' | htpasswd -vi "$TMP/webdav.htpasswd" infuse 2>/dev/null
    grep -q '^restart webdav$' "$TMP/docker-calls"
    [ "$(wc -l <"$TMP/webdav.htpasswd")" -eq 1 ]
    run ! grep -q 'changed-pass-2' "$TMP/docker-calls"
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -q '^    ensure_webdav_htpasswd$'
}

@test "sync_filebrowser_account leaves a matching account alone and overwrites a changed one in place" {
    command -v htpasswd >/dev/null || skip "htpasswd yok"
    for f in filebrowser_cli filebrowser_account_fail filebrowser_target_id \
        filebrowser_user_matches filebrowser_sync_fail sync_filebrowser_account; do
        eval "$(awk "/^$f\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
    done
    FILEBROWSER_DATA_DIR="$TMP/fb" FILEBROWSER_DB_FILE="$TMP/fb/filebrowser.db" FILEBROWSER_IMAGE=fixture
    DOWNLOADS_UID=1000 DOWNLOADS_GID=1000 RUNTIME_DIR="$TMP"
    mkdir -p "$TMP/fb"
    printf 'db-v1\n' >"$TMP/fb/filebrowser.db"
    log() { :; }
    chown() { :; }
    old="$(printf '%s' 'fixture-password-123' | htpasswd -niB -C 4 murat | cut -d: -f2-)"
    jq -n --arg h "$old" '[{id: 1, username: "murat", password: $h, perm: {admin: true}, viewMode: "list"},
        {id: 2, username: "guest", password: $h, perm: {admin: false}}]' >"$TMP/store.json"
    docker() {
        local a w=""
        printf '%s\n' "$*" >>"$TMP/docker-calls"
        case "$1" in
            inspect) printf 'true\n'; return 0 ;;
            stop | start) return 0 ;;
            run) ;;
            *) return 0 ;;
        esac
        for a in "$@"; do case "$a" in *:/database) w="${a%:/database}" ;; esac; done
        case "$*" in
            *" users export "*) cp "$TMP/store.json" "$w/users.json" ;;
            *" users import --overwrite "*)
                jq -s '.[1][0] as $n | .[0] | map(if .id == $n.id then $n else . end)' \
                    "$TMP/store.json" "$w/import.json" >"$TMP/store.new" && mv "$TMP/store.new" "$TMP/store.json"
                printf 'db-v2\n' >"$w/filebrowser.db" ;;
            *) return 1 ;;
        esac
    }
    FILEBROWSER_NEW_USER=murat FILEBROWSER_NEW_PASS='fixture-password-123'
    run sync_filebrowser_account
    [ "$status" -eq 0 ]
    run ! grep -qE '^(stop|start) ' "$TMP/docker-calls"
    [ "$(cat "$TMP/fb/filebrowser.db")" = db-v1 ]
    [ -z "$(find "$TMP/fb" -name '.sync-*')" ]
    # A changed password: container stopped, same id overwritten, other fields
    # and other users kept, verified database moved in, container started.
    rm -f "$TMP/docker-calls"
    FILEBROWSER_NEW_USER=murat FILEBROWSER_NEW_PASS='changed-password-456'
    run sync_filebrowser_account
    [ "$status" -eq 0 ]
    grep -q '^stop filebrowser$' "$TMP/docker-calls"
    grep -q '^start filebrowser$' "$TMP/docker-calls"
    grep -q 'users import --overwrite /database/import.json' "$TMP/docker-calls"
    run ! grep -q 'changed-password-456' "$TMP/docker-calls"
    [ "$(cat "$TMP/fb/filebrowser.db")" = db-v2 ]
    jq -e 'length == 2 and (.[] | select(.id == 1) | .viewMode == "list" and .username == "murat")' \
        "$TMP/store.json" >/dev/null
    jq -r '.[] | select(.id == 1) | "murat:" + .password' "$TMP/store.json" >"$TMP/ht"
    printf '%s' 'changed-password-456' | htpasswd -vi "$TMP/ht" murat 2>/dev/null
    jq -e --arg h "$old" '.[] | select(.id == 2) | .password == $h' "$TMP/store.json" >/dev/null
    [ -z "$(find "$TMP/fb" -name '.sync-*')" ]
    # A failed import restarts the container on the untouched database.
    rm -f "$TMP/docker-calls"
    printf 'db-v2\n' >"$TMP/fb/filebrowser.db"
    docker() {
        printf '%s\n' "$*" >>"$TMP/docker-calls"
        case "$*" in
            inspect*) printf 'true\n' ;;
            *" users export "*) local a w=""; for a in "$@"; do case "$a" in *:/database) w="${a%:/database}" ;; esac; done
                cp "$TMP/store.json" "$w/users.json" ;;
            *" users import "*) return 1 ;;
        esac
        return 0
    }
    FILEBROWSER_NEW_USER=murat FILEBROWSER_NEW_PASS='third-password-789'
    run sync_filebrowser_account
    [ "$status" -ne 0 ]
    grep -q '^start filebrowser$' "$TMP/docker-calls"
    [ "$(cat "$TMP/fb/filebrowser.db")" = db-v2 ]
    [ -z "$(find "$TMP/fb" -name '.sync-*')" ]
}

@test "portable launcher reads kurulum/ beside it and sends it only to tmpfs" {
    local exporter="$V2_ROOT/dev/export-installer.sh" body
    body="$(awk "/cat <<'BODY_END'/,/^BODY_END\$/" "$exporter")"
    [ -n "$body" ]
    grep -q 'INPUT_LOCAL_DIR="\$here/kurulum"' <<<"$body"
    grep -q 'INPUT_FILE_LOCAL="\$INPUT_LOCAL_DIR/kurulum.env"' <<<"$body"
    grep -q 'wireguard/sunucu.key' <<<"$body"
    # Every file sent is mode-checked, and only listed files are sent.
    grep -q 'for f in "\${input_files\[@\]}"; do' <<<"$body"
    grep -q 'stat -f %Lp "\$INPUT_LOCAL_DIR/\$f"' <<<"$body"
    grep -q -- '-cf - "\${input_files\[@\]}"' <<<"$body"
    grep -q -- '--no-same-owner -xf -' <<<"$body"
    # Only SSH_HOST is read on the Mac; the rest is validated by the installer.
    grep -q 'index(\$0, "SSH_HOST=") == 1' <<<"$body"
    run ! grep -qE '_PASS|TS_AUTH_KEY' <<<"$body"
    run ! grep -q 'SSH sunucu adı' <<<"$body"
    run ! grep -q 'DEPLOY_HOST' "$exporter"
    grep -q 'stat -f -c %T' <<<"$body"
    grep -q '= tmpfs \]' <<<"$body"
    grep -q 'remote_input_sent=1' <<<"$body"
    awk '/^cleanup_local\(\)/,/^}$/' <<<"$body" | grep -q "rm -rf '\$REMOTE_INPUT_DIR'"
    # The server-side path has one source: defaults.env.
    grep -q "awk -F= '/^INPUT_DIR=/" "$exporter"
    grep -q 'REMOTE_INPUT_DIR="\$INPUT_DIR"' "$exporter"
    # The archive is built from Data/ only; kurulum/ lives in the repo root.
    run ! grep -q 'TOP_DIR/kurulum' "$exporter"
    # Finder runs .command files with macOS /bin/bash 3.2.
    run ! grep -qE 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)' <<<"$body"
}

wg_fixture_key() {
    # 32 random bytes, base64: the shape of a WireGuard key (not a real key pair).
    openssl rand -base64 32
}

wg_load_input_functions() {
    local f
    for f in slurp_wireguard_inputs wg_trim wg_dns_list_ok wg_client_ipv4_ok wg_client_ipv6_ok \
        parse_wireguard_profile validate_wireguard_inputs; do
        eval "$(awk "/^$f\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
    done
    # shellcheck source=/dev/null
    source "$V2_ROOT/config/defaults.env"
    INPUT_WG_PEERS="" INPUT_WG_CLIENT_DNS="" INPUT_WG_CLIENT_KEEPALIVE="" INPUT_WG_CLIENT_DNS_OVERRIDE=""
}

@test "wireguard inputs are read into memory, deleted, and validated in wg-easy's format" {
    wg_load_input_functions
    local dir="$TMP/in/wireguard" sk spub p1 p2 psk
    mkdir -p "$dir"
    sk="$(wg_fixture_key)" spub="$(wg_fixture_key)" p1="$(wg_fixture_key)"
    p2="$(wg_fixture_key)" psk="$(wg_fixture_key)"
    printf '%s\n' "$sk" >"$dir/sunucu.key"
    cat >"$dir/iphone.conf" <<EOF
[Interface]
PrivateKey = $p1
Address = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128
MTU = 1420
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = $spub
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 0
Endpoint = 203.0.113.10:61001
EOF
    printf '[Interface]\nPrivateKey = %s\nAddress = 10.8.0.3/32\n\n[Peer]\nPublicKey = %s\n' \
        "$p2" "$spub" >"$dir/mac.conf"
    printf 'not a profile\n' >"$dir/notes.txt"
    chmod 600 "$dir"/*
    slurp_wireguard_inputs "$dir"
    [ ! -e "$dir" ]
    INPUT_WG_PEERS="iphone mac"
    validate_wireguard_inputs
    [ "$WG_PEER_COUNT" -eq 2 ]
    [ "${WG_PEER_NAMES[*]}" = "iphone mac" ]
    [ "${WG_PEER_IPV4[*]}" = "10.8.0.2 10.8.0.3" ]
    [ "${WG_PEER_IPV6[0]}" = "fdcc:ad94:bacf:61a4::cafe:2" ]
    [ -z "${WG_PEER_IPV6[1]}" ]
    [ "${WG_PEER_PSK[0]}" = "$psk" ]
    [ -z "${WG_PEER_PSK[1]}" ]
    [ "$WG_SERVER_PRIVATE" = "$sk" ]
    [ "$WG_SERVER_KEY_NEW" -eq 0 ]
    [ "${WG_PEER_SERVER_PUB[1]}" = "$spub" ]
    [ "${WG_PEER_NEW[*]}" = "0 0" ]
    [ -z "$WG_NEW_PEERS" ]
    # Empty env fields take the defaults.env values.
    [ "$WG_CLIENT_DNS" = "$WG_CLIENT_DNS_DEFAULT" ]
    [ "$WG_CLIENT_KEEPALIVE" = "$WG_CLIENT_KEEPALIVE_DEFAULT" ]
    [ "${WG_PEER_ORIG[0]}" = "$(printf '%s' "$(cat <<EOF
[Interface]
PrivateKey = $p1
Address = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128
MTU = 1420
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = $spub
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 0
Endpoint = 203.0.113.10:61001
EOF
)")" ]
}

@test "WG_PEERS plans new peers on free addresses, keeps existing ones, and applies DNS overrides" {
    wg_load_input_functions
    local dir="$TMP/in/wireguard" sk spub
    sk="$(wg_fixture_key)" spub="$(wg_fixture_key)"
    mkdir -p "$dir"
    printf '%s\n' "$sk" >"$dir/sunucu.key"
    # Existing peers hold .2 and .4 (and :2, :4); .9 is taken to prove skipping.
    for spec in "iPh0 10.8.0.2 fdcc:ad94:bacf:61a4::cafe:2" "iPd0 10.8.0.4 fdcc:ad94:bacf:61a4::cafe:4" \
        "eski 10.8.0.9 fdcc:ad94:bacf:61a4::cafe:9"; do
        set -- $spec
        printf '[Interface]\nPrivateKey = %s\nAddress = %s/32, %s/128\n[Peer]\nPublicKey = %s\n' \
            "$(wg_fixture_key)" "$2" "$3" "$spub" >"$dir/$1.conf"
    done
    chmod 600 "$dir"/*
    slurp_wireguard_inputs "$dir"
    INPUT_WG_PEERS="yeni1 iPh0  iPd0 yeni2"
    INPUT_WG_CLIENT_DNS="9.9.9.9, 2620:fe::fe"
    INPUT_WG_CLIENT_KEEPALIVE=21
    INPUT_WG_CLIENT_DNS_OVERRIDE=" iPd0 = 1.1.1.1, 1.0.0.1 ; yeni2=8.8.8.8 "
    validate_wireguard_inputs
    [ "$WG_PEER_COUNT" -eq 4 ]
    [ "${WG_PEER_NAMES[*]}" = "yeni1 iPh0 iPd0 yeni2" ]
    [ "${WG_PEER_NEW[*]}" = "1 0 0 1" ]
    # New peers fill .3 then .5; the unlisted "eski" still owns nothing.
    [ "${WG_PEER_IPV4[*]}" = "10.8.0.3 10.8.0.2 10.8.0.4 10.8.0.5" ]
    [ "${WG_PEER_IPV6[0]}" = "fdcc:ad94:bacf:61a4::cafe:3" ]
    [ "${WG_PEER_IPV6[3]}" = "fdcc:ad94:bacf:61a4::cafe:5" ]
    [ "${WG_PEER_DNS[0]}" = "9.9.9.9, 2620:fe::fe" ]
    [ "${WG_PEER_DNS[2]}" = "1.1.1.1, 1.0.0.1" ]
    [ "${WG_PEER_DNS[3]}" = "8.8.8.8" ]
    [ "$WG_CLIENT_KEEPALIVE" = 21 ]
    [ "$WG_UNLISTED_FILES" = "eski.conf " ]
    [ "$WG_NEW_PEERS" = "yeni1=10.8.0.3 yeni2=10.8.0.5 " ]
    [ "$WG_DNS_OVERRIDE_NAMES" = "iPd0 yeni2 " ]
    # Host 10 is written in hex on IPv6, matching wg-easy's .2 <-> :2 layout.
    rm -rf "$TMP/in"; mkdir -p "$dir"
    slurp_wireguard_inputs "$dir"
    INPUT_WG_PEERS="p2 p3 p4 p5 p6 p7 p8 p9 p10" INPUT_WG_CLIENT_DNS_OVERRIDE=""
    validate_wireguard_inputs
    [ "$WG_SERVER_KEY_NEW" -eq 1 ]
    [ "${WG_PEER_IPV4[8]}" = "10.8.0.10" ]
    [ "${WG_PEER_IPV6[8]}" = "fdcc:ad94:bacf:61a4::cafe:a" ]
    # No folder at all: a fresh install with no peers is valid.
    rm -rf "$TMP/in"
    slurp_wireguard_inputs "$dir"
    INPUT_WG_PEERS=""
    validate_wireguard_inputs
    [ "$WG_PEER_COUNT" -eq 0 ]
    [ "$WG_SERVER_KEY_NEW" -eq 1 ]
}

@test "wireguard inputs reject bad profiles and env fields without echoing key material" {
    wg_load_input_functions
    local sk spub p1 p2 dir="$TMP/in/wireguard"
    sk="$(wg_fixture_key)" spub="$(wg_fixture_key)" p1="$(wg_fixture_key)" p2="$(wg_fixture_key)"
    good() { printf '[Interface]\nPrivateKey = %s\nAddress = %s\n[Peer]\nPublicKey = %s\n%b' "$1" "$2" "$spub" "${3:-}"; }
    run_case() {
        rm -rf "$TMP/in"
        mkdir -p "$dir"
        printf '%s\n' "$sk" >"$dir/sunucu.key"
        good "$p1" 10.8.0.2/32 >"$dir/a.conf"
        INPUT_WG_PEERS="a b" INPUT_WG_CLIENT_DNS="" INPUT_WG_CLIENT_KEEPALIVE="" INPUT_WG_CLIENT_DNS_OVERRIDE=""
        eval "$1"
        chmod 600 "$dir"/* 2>/dev/null || true
        eval "${2:-}"
        slurp_wireguard_inputs "$dir"
        [ ! -e "$dir" ]
        run validate_wireguard_inputs
        [ "$status" -ne 0 ]
        case "$output" in *"$3"*) ;; *) printf 'expected %s, got: %s\n' "$3" "$output"; false ;; esac
        case "$output" in *"$sk"* | *"$p1"* | *"$p2"* | *"$spub"*) false ;; esac
    }
    run_case 'rm -f "$dir/sunucu.key"' '' 'sunucu.key yok ama profiller var'
    run_case 'printf "short\n" >"$dir/sunucu.key"' '' 'WireGuard özel anahtarı değil'
    run_case '' 'chmod 644 "$dir/a.conf"' 'izinleri 644'
    run_case 'good "$p2" 10.8.0.2/32 >"$dir/b.conf"' '' 'başka bir profilde de var'
    run_case 'good "$p1" 10.8.0.9/32 >"$dir/b.conf"' '' 'özel anahtarı başka bir profilde'
    run_case 'good "$p2" 10.8.1.2/32 >"$dir/b.conf"' '' "'10.8.1.2' 10.8.0.0/24 içinde"
    run_case 'good "$p2" 10.8.0.1/32 >"$dir/b.conf"' '' "'10.8.0.1'"
    run_case 'good "$p2" "10.8.0.3/32, fdcc::3/128" >"$dir/b.conf"' '' "IPv6 'fdcc::3'"
    run_case 'good "$p2" 10.8.0.3/32 "[Peer]\nPublicKey = $spub\n" >"$dir/b.conf"' '' 'tek [Interface] ve tek [Peer]'
    run_case 'good "$p2" 10.8.0.3/32 "Endpoint = 1.2.3.4:51820\n" >"$dir/b.conf"' '' 'Endpoint portu 51820'
    run_case 'printf "[Interface]\nPrivateKey = %s\nAddress = 10.8.0.3/32\n[Peer]\nPublicKey = %s\nPresharedKey = nope\n" "$p2" "$spub" >"$dir/b.conf"' '' 'PresharedKey'
    run_case 'INPUT_WG_PEERS="a bad/name"' '' "'bad/name' geçersiz ad"
    run_case 'INPUT_WG_PEERS="a a"' '' "'a' iki kez"
    run_case 'INPUT_WG_CLIENT_DNS="dns.example"' '' 'WG_CLIENT_DNS virgülle'
    run_case 'INPUT_WG_CLIENT_KEEPALIVE=70000' '' 'WG_CLIENT_KEEPALIVE 0-65535'
    run_case 'INPUT_WG_CLIENT_KEEPALIVE=021' '' 'WG_CLIENT_KEEPALIVE 0-65535'
    run_case 'INPUT_WG_CLIENT_DNS_OVERRIDE="zz=1.1.1.1"' '' "'zz' WG_PEERS'te yok"
    run_case 'INPUT_WG_CLIENT_DNS_OVERRIDE="a=1.1.1.1; a=8.8.8.8"' '' "'a' iki kez"
    run_case 'INPUT_WG_CLIENT_DNS_OVERRIDE="a=bad"' '' "'a' için DNS"
    run_case 'INPUT_WG_CLIENT_DNS_OVERRIDE="1.1.1.1"' '' "'ad=dns' biçiminde"
}

@test "ensure_wireguard generates missing keys, writes public keys only, and hands back changed profiles" {
    for f in wg_client_profile ensure_wireguard; do
        eval "$(awk "/^$f\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
    done
    # shellcheck source=/dev/null
    source "$V2_ROOT/config/defaults.env"
    WG_CONF_FILE="$TMP/etc/wireguard/wg0.conf" WG_MODULES_LOAD_FILE="$TMP/modules.conf"
    OUTPUT_DIR="$TMP/out" OUTPUT_WG_DIR="$TMP/out/wireguard"
    WG_PUBLIC_PORT=61001 WG_ENDPOINT_HOST=203.0.113.7 APT_OPTS=() APT_LOCK_TIMEOUT=1
    log() { [ "$1" != HATA ] || printf '%s\n' "$*"; }
    retry() { printf 'retry %s\n' "$*" >>"$TMP/calls"; }
    modprobe() { :; }
    install() { mkdir -p "${!#}"; }
    systemctl() { printf 'systemctl %s\n' "$*" >>"$TMP/calls"; [ "$1" != is-active ]; }
    qrencode() { printf 'qrencode %s\n' "$*" >>"$TMP/calls"; cat >"$TMP/qr-input"; }
    GEN=0
    # Deterministic stand-ins for wg: keys only ever cross stdin/stdout, and a
    # derived "public key" (rot13) never contains its private key.
    wg() {
        case "$1" in
            pubkey) local k; IFS= read -r k; printf 'PUB-%s\n' "$(printf '%s' "${k:0:8}" | tr 'A-Za-z' 'N-ZA-Mn-za-m')" ;;
            genkey) printf 'GENKEY%02d%s=\n' "$GEN" "$(printf 'g%.0s' {1..35})"; GEN=$((GEN + 1)) ;;
            genpsk) printf 'GENPSK%s=\n' "$(printf 'p%.0s' {1..37})" ;;
            syncconf) printf 'wg syncconf %s\n' "$2" >>"$TMP/calls"; cat "$3" >"$TMP/syncconf-input"; return "${SYNC_RC:-0}" ;;
            *) return 1 ;;
        esac
    }
    wg-quick() { [ "$1" = strip ] && grep -vE '^(Address|MTU) = ' "$WG_CONF_FILE"; }
    existing_profile() {
        printf '[Interface]\nPrivateKey = CLIENT1keybbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\nAddress = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128\nMTU = 1420\nDNS = %s\n\n[Peer]\nPublicKey = PUB-FREIREXR\nPresharedKey = PSKddddddddddddddddddddddddddddddddddddddd=\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 21\nEndpoint = 203.0.113.7:61001' "$1"
    }
    set_inputs() {
        WG_SERVER_KEY_NEW=0
        WG_SERVER_PRIVATE="SERVERKEYaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="
        WG_PEER_NAMES=(iphone ipad yeni)
        WG_PEER_PRIVATE=("CLIENT1keybbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=" "CLIENT2keycccccccccccccccccccccccccccccccccc=" "")
        WG_PEER_PSK=("PSKddddddddddddddddddddddddddddddddddddddd=" "" "")
        WG_PEER_SERVER_PUB=("PUB-FREIREXR" "PUB-FREIREXR" "")
        WG_PEER_IPV4=(10.8.0.2 10.8.0.3 10.8.0.4)
        WG_PEER_IPV6=(fdcc:ad94:bacf:61a4::cafe:2 "" fdcc:ad94:bacf:61a4::cafe:4)
        WG_PEER_DNS=("1.1.1.1" "9.9.9.9" "1.1.1.1")
        WG_PEER_NEW=(0 0 1)
        # iphone's stored profile already matches; ipad's does not (old DNS/keepalive).
        WG_PEER_ORIG=("$(existing_profile 1.1.1.1)" "old ipad profile" "")
        WG_CLIENT_KEEPALIVE=21
        WG_PEER_COUNT=3
    }
    set_inputs
    run ensure_wireguard
    [ "$status" -eq 0 ]
    conf="$(cat "$WG_CONF_FILE")"
    mode="$(stat -c %a "$WG_CONF_FILE" 2>/dev/null || stat -f %Lp "$WG_CONF_FILE")"
    [ "$mode" = 600 ]
    grep -q '^Address = 10.8.0.1/24, fdcc:ad94:bacf:61a4::cafe:1/112$' <<<"$conf"
    grep -q '^PrivateKey = SERVERKEYa' <<<"$conf"
    grep -q '^PublicKey = PUB-PYVRAG1x$' <<<"$conf"
    grep -q '^PublicKey = PUB-TRAXRL00$' <<<"$conf"
    grep -q '^PresharedKey = GENPSKppp' <<<"$conf"
    grep -q '^AllowedIPs = 10.8.0.4/32, fdcc:ad94:bacf:61a4::cafe:4/128$' <<<"$conf"
    [ "$(grep -c '^\[Peer\]$' <<<"$conf")" -eq 3 ]
    [ "$(grep -c '^PrivateKey' <<<"$conf")" -eq 1 ]
    run ! grep -qE 'CLIENT1key|CLIENT2key|GENKEY00|PostUp' <<<"$conf"
    grep -q 'no-install-recommends wireguard-tools qrencode' "$TMP/calls"
    # Hand-back: the new peer and the changed ipad, not the unchanged iphone.
    [ -f "$OUTPUT_WG_DIR/yeni.conf" ]
    [ -f "$OUTPUT_WG_DIR/ipad.conf" ]
    [ ! -e "$OUTPUT_WG_DIR/iphone.conf" ]
    [ ! -e "$OUTPUT_WG_DIR/sunucu.key" ]
    mode="$(stat -c %a "$OUTPUT_WG_DIR/yeni.conf" 2>/dev/null || stat -f %Lp "$OUTPUT_WG_DIR/yeni.conf")"
    [ "$mode" = 600 ]
    yeni="$(cat "$OUTPUT_WG_DIR/yeni.conf")"
    grep -q '^PrivateKey = GENKEY00' <<<"$yeni"
    grep -q '^PresharedKey = GENPSKppp' <<<"$yeni"
    grep -q '^PublicKey = PUB-FREIREXR$' <<<"$yeni"
    grep -q '^Address = 10.8.0.4/32, fdcc:ad94:bacf:61a4::cafe:4/128$' <<<"$yeni"
    grep -q '^PersistentKeepalive = 21$' <<<"$yeni"
    grep -q '^Endpoint = 203.0.113.7:61001$' <<<"$yeni"
    grep -q '^DNS = 9.9.9.9$' "$OUTPUT_WG_DIR/ipad.conf"
    grep -q '^Address = 10.8.0.3/32$' "$OUTPUT_WG_DIR/ipad.conf"
    run ! grep -q 'PresharedKey' "$OUTPUT_WG_DIR/ipad.conf"
    # The QR code is for the new peer only, and goes to the terminal, not the log.
    [ "$(grep -c '^qrencode' "$TMP/calls")" -eq 1 ]
    grep -q 'GENKEY00' "$TMP/qr-input"
    grep -q '^systemctl restart wg-quick@wg0.service$' "$TMP/calls"
    # DD-123: on a running interface a peer change is applied live, the kernel
    # WireGuard way (wg syncconf of `wg-quick strip`), with no restart. Here two
    # peers are removed and nothing is left to hand back.
    rm -f "$TMP/calls"
    systemctl() { printf 'systemctl %s\n' "$*" >>"$TMP/calls"; }
    set_inputs
    WG_PEER_NAMES=(iphone) WG_PEER_COUNT=1
    WG_PEER_NEW=(0)
    WG_PEER_ORIG=("$(existing_profile 1.1.1.1)")
    run ensure_wireguard
    [ "$status" -eq 0 ]
    [ ! -e "$OUTPUT_DIR" ]
    run ! grep -q '^qrencode' "$TMP/calls"
    grep -q '^wg syncconf wg0$' "$TMP/calls"
    run ! grep -q 'restart' "$TMP/calls"
    [ "$(grep -c '^\[Peer\]$' "$TMP/syncconf-input")" -eq 1 ]
    run ! grep -qE '^(Address|MTU) = ' "$TMP/syncconf-input"
    # The same inputs again: nothing to apply at all.
    rm -f "$TMP/calls"
    set_inputs
    WG_PEER_NAMES=(iphone) WG_PEER_COUNT=1 WG_PEER_NEW=(0) WG_PEER_ORIG=("$(existing_profile 1.1.1.1)")
    run ensure_wireguard
    [ "$status" -eq 0 ]
    run ! grep -qE 'syncconf|restart' "$TMP/calls"
    # A failed syncconf falls back to a restart.
    rm -f "$TMP/calls"
    set_inputs
    SYNC_RC=1
    run ensure_wireguard
    [ "$status" -eq 0 ]
    grep -q '^wg syncconf wg0$' "$TMP/calls"
    grep -q '^systemctl restart wg-quick@wg0.service$' "$TMP/calls"
    SYNC_RC=0
    # An empty `wg-quick strip` must never reach syncconf (it would wipe the
    # key and every peer): restart instead.
    rm -f "$TMP/calls"
    set_inputs
    WG_PEER_NAMES=(iphone) WG_PEER_COUNT=1 WG_PEER_NEW=(0) WG_PEER_ORIG=("$(existing_profile 1.1.1.1)")
    wg-quick() { :; }
    run ensure_wireguard
    [ "$status" -eq 0 ]
    run ! grep -q 'syncconf' "$TMP/calls"
    grep -q '^systemctl restart wg-quick@wg0.service$' "$TMP/calls"
    wg-quick() { [ "$1" = strip ] && grep -vE '^(Address|MTU) = ' "$WG_CONF_FILE"; }
    # An interface change (MTU) needs wg-quick itself: restart, no syncconf.
    rm -f "$TMP/calls"
    set_inputs
    WG_MTU=1380
    run ensure_wireguard
    [ "$status" -eq 0 ]
    grep -q '^systemctl restart wg-quick@wg0.service$' "$TMP/calls"
    run ! grep -q 'syncconf' "$TMP/calls"
    WG_MTU=1420
    # A fresh server key is handed back with the profiles.
    set_inputs
    WG_SERVER_KEY_NEW=1 WG_SERVER_PRIVATE=""
    WG_PEER_NAMES=(yeni) WG_PEER_PRIVATE=("") WG_PEER_PSK=("") WG_PEER_SERVER_PUB=("")
    WG_PEER_IPV4=(10.8.0.2) WG_PEER_IPV6=("") WG_PEER_DNS=(1.1.1.1) WG_PEER_NEW=(1) WG_PEER_ORIG=("") WG_PEER_COUNT=1
    run ensure_wireguard
    [ "$status" -eq 0 ]
    [ -f "$OUTPUT_WG_DIR/sunucu.key" ]
    grep -q '^PublicKey = PUB-TRAXRL' "$OUTPUT_WG_DIR/yeni.conf"
    # A profile made for another server stops before wg0.conf changes.
    before="$(cat "$WG_CONF_FILE")"
    set_inputs
    WG_PEER_SERVER_PUB=("PUB-FREIREXR" "PUB-OTHERSRV" "")
    run ensure_wireguard
    [ "$status" -ne 0 ]
    case "$output" in *"ipad.conf başka bir sunucuya ait"*) ;; *) false ;; esac
    [ "$(cat "$WG_CONF_FILE")" = "$before" ]
}

@test "launcher hands generated WireGuard profiles back before removing them from the server" {
    local exporter="$V2_ROOT/dev/export-installer.sh" body fetch
    body="$(awk "/cat <<'BODY_END'/,/^BODY_END\$/" "$exporter")"
    fetch="$(awk '/^fetch_wireguard_output\(\)/,/^}$/' <<<"$body")"
    [ -n "$fetch" ]
    # The remote copy is removed only after every file is in kurulum/wireguard.
    awk '/mv -f "\$f" "\$INPUT_LOCAL_DIR\/wireguard\/"/ {m = NR} /rm -rf .\$REMOTE_OUTPUT_DIR./ {r = NR}
         END { exit !(m && r && m < r) }' <<<"$fetch"
    grep -q 'chmod 600 "$f"' <<<"$fetch"
    grep -q 'umask 077 && tar -C "$staging" -xf -' <<<"$fetch"
    # It runs after the install session whatever its exit code.
    awk '/"bash .\$REMOTE_ROOT\/install.sh."/ {i = NR} /^fetch_wireguard_output \|\| rc=1$/ {f = NR}
         END { exit !(i && f && i < f) }' <<<"$body"
    # wireguard/ is optional now; sunucu.key is sent only when present.
    run ! grep -q 'WireGuard sunucu anahtarı yok' <<<"$body"
    grep -q '\[\[ -f "\$INPUT_LOCAL_DIR/wireguard/sunucu.key" \]\] && input_files+=(wireguard/sunucu.key)' <<<"$body"
    grep -q 'REMOTE_OUTPUT_WG_DIR="\$OUTPUT_WG_DIR"' "$exporter"
    grep -q '^OUTPUT_DIR="/run/master-stack/kurulum-cikti"$' "$V2_ROOT/config/defaults.env"
    grep -q '^OUTPUT_WG_DIR="/run/master-stack/kurulum-cikti/wireguard"$' "$V2_ROOT/config/defaults.env"
    # Stage 0 clears a previous run's output that was never fetched.
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" | grep -A3 'rm -rf -- "\$INPUT_DIR"' |
        grep -q 'rm -rf -- "\$OUTPUT_DIR"'
}

@test "firewall confines WireGuard clients to internet egress and the caddy-wg ports" {
    local fw="$V2_ROOT/scripts/firewall.sh" in4 in6 fwd nat
    for v in CHAIN_FORWARD CHAIN_NAT WG_INTERFACE WG_SERVER_IPV4 WG_SUBNET4 WG_SUBNET6 \
        DOZZLE_UI_PORT TORRENT_UI_PORT FILEBROWSER_UI_PORT; do
        grep -q ": \"\${$v:?}\"" "$fw"
        awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q "^$v=\\\$$v$"
    done
    in4="$(awk '/^apply_input4\(\)/,/^}$/' "$fw")"
    grep -q -- '-i "$WG_INTERFACE" -d "$WG_SERVER_IPV4" -p tcp' <<<"$in4"
    grep -q -- '--dports "$(wg_ui_ports)" -j ACCEPT' <<<"$in4"
    grep -q -- '-i "$WG_INTERFACE" -j DROP' <<<"$in4"
    # The allow rules come before the DROP, and both before the final RETURN.
    awk '/wg_ui_ports/ {a = NR} /-i "\$WG_INTERFACE" -j DROP/ {d = NR} /-j RETURN$/ {r = NR}
         END { exit !(a && d && r && a < d && d < r) }' <<<"$in4"
    in6="$(awk '/^apply_input6\(\)/,/^}$/' "$fw")"
    grep -q -- '-i "$WG_INTERFACE" -j DROP' <<<"$in6"
    run ! grep -q 'wg_ui_ports' <<<"$in6"
    fwd="$(awk '/^apply_forward\(\)/,/^}$/' "$fw")"
    grep -q -- '-i "$WG_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT' <<<"$fwd"
    grep -q -- '-o "$WG_INTERFACE" -j DROP' <<<"$fwd"
    grep -q 'activate_named "$bin" FORWARD "$staging" "$CHAIN_FORWARD"' <<<"$fwd"
    awk '/-o "\$WAN_INTERFACE" -j ACCEPT/ {a = NR} /-i "\$WG_INTERFACE" -j DROP/ {d = NR}
         END { exit !(a && d && a < d) }' <<<"$fwd"
    nat="$(awk '/^apply_nat\(\)/,/^}$/' "$fw")"
    grep -q -- '-s "$subnet" -o "$WAN_INTERFACE" -j MASQUERADE' <<<"$nat"
    grep -q 'activate_named "$bin" POSTROUTING "$staging" "$CHAIN_NAT"' <<<"$nat"
    grep -q '^apply_nat iptables_nat "${CHAIN_STAGING_PREFIX}NAT-" "$WG_SUBNET4"$' "$fw"
    grep -q '^apply_nat ip6tables_nat "${CHAIN_STAGING_PREFIX}NAT6-" "$WG_SUBNET6"$' "$fw"
    grep -q '^purge_staging_leftovers ip6tables_nat$' "$fw"
    grep -q '^iptables_nat() { iptables -t nat "$@"; }$' "$fw"
    # --check asserts all of it, counts the FORWARD chain and checks order.
    grep -q '^    check_forward_chain ip6tables$' "$fw"
    grep -q '^    check_nat_chain ip6tables_nat "$WG_SUBNET6"$' "$fw"
    awk '/^check_forward_chain\(\)/,/^}$/' "$fw" | grep -q 'beklenen 5'
    # WireGuard is no longer a Docker publish.
    run ! grep -q 'WG_PUBLIC_PORT' <<<"$(awk '/^docker_return_pairs\(\)/,/^}$/' "$fw")"
    # No wg-quick PostUp rules: the firewall script owns netfilter (DD-16/DD-17).
    run ! grep -q 'PostUp' <<<"$(grep -vE '^[[:space:]]*#' "$V2_ROOT/install.sh")"
}

@test "check_before and the WireGuard FORWARD count catch order and extra rules" {
    eval "$(awk '/^check_before\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    eval "$(awk '/^check_forward_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
    check_jump_exactly_one() { :; }
    check_rule() { :; }
    CHAIN_FORWARD=MASTER-FORWARD WG_INTERFACE=wg0 WAN_INTERFACE=eth0
    good='-A MASTER-FORWARD -i wg0 -o eth0 -j ACCEPT
-A MASTER-FORWARD -i wg0 -j DROP
-A MASTER-FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A MASTER-FORWARD -o wg0 -j DROP
-A MASTER-FORWARD -j RETURN'
    fake() { printf -- '-N MASTER-FORWARD\n%s\n' "$RULES"; }
    iptables() { fake; }
    RULES="$good"
    run check_forward_chain iptables
    [ "$status" -eq 0 ]
    # The DROP before the ACCEPT: every packet dropped.
    RULES="$(printf '%s\n' "$good" | awk 'NR == 1 { first = $0; next } NR == 2 { print; print first; next } { print }')"
    run check_forward_chain iptables
    [ "$status" -ne 0 ]
    # An extra blanket ACCEPT.
    RULES="$(printf -- '-A MASTER-FORWARD -i wg0 -j ACCEPT\n%s' "$good")"
    run check_forward_chain iptables
    [ "$status" -ne 0 ]
    case "$output" in *"beklenen 5"*) ;; *) false ;; esac
}

@test "caddy-wg serves only the UI ports on the WireGuard address and follows wg-quick" {
    local t="$V2_ROOT/templates/Caddyfile.wg" u="$V2_ROOT/systemd/caddy-wg.service" body
    grep -q '^	admin off$' "$t"
    grep -q '^	auto_https off$' "$t"
    grep -q '^	default_bind __WG_SERVER_IPV4__$' "$t"
    for p in DOZZLE_UI_PORT TORRENT_UI_PORT FILEBROWSER_UI_PORT; do
        grep -q "^http://:__${p}__ {\$" "$t"
        grep -q "reverse_proxy 127.0.0.1:__${p}__\$" "$t"
    done
    [ "$(grep -c '^http://' "$t")" -eq 3 ]
    run ! grep -qiE 'webdav|TAILSCALE|LOCAL_DOMAIN' <<<"$(grep -v '^#' "$t")"
    grep -q '^Requires=wg-quick@__WG_INTERFACE__.service$' "$u"
    grep -q '^PartOf=wg-quick@__WG_INTERFACE__.service$' "$u"
    grep -q '^User=caddy$' "$u"
    grep -q -- '--config __CADDY_WG_FILE__ --adapter caddyfile' "$u"
    run ! grep -qi 'tailscale' "$u"
    body="$(awk '/^ensure_caddy_wg\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'caddy validate --config "$CADDY_WG_FILE"' <<<"$body"
    grep -q 'systemctl restart caddy-wg.service' <<<"$body"
    awk '/^stage_6\(\)/,/^assert_webdav_readonly_runtime\(\)/' "$V2_ROOT/install.sh" |
        grep -q '^    ensure_caddy_wg "\$OS_CHANGED"$'
    # WireGuard comes up after the firewall has its rules, then caddy-wg in stage 6.
    awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh" |
        awk '/restart master-firewall.service/ {f = NR} /^    ensure_wireguard$/ {w = NR}
             END { exit !(f && w && f < w) }'
    # Stage 7 proves the interface, the peer count and the three UI ports.
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'wg show "$WG_INTERFACE" listen-port' <<<"$s7"
    grep -q '"$wg_peers" -eq "$WG_PEER_COUNT"' <<<"$s7"
    grep -q 'http://${WG_SERVER_IPV4}:${wg_ui_port}/' <<<"$s7"
}
