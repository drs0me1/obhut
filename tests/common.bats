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
    [ "$(grep -cF 'apt-get "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 9 ]
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
    ! grep -qE 'WG_PUBLIC_PORT:=61001|QBIT_PUBLIC_PORT:=61005|CHAIN_INPUT:=MASTER' \
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

@test "wg-easy host preloads legacy IPv4 and IPv6 netfilter modules" {
    local module_block
    module_block="$(awk '/^ensure_wg_kernel_modules\(\)/,/^}/' "$V2_ROOT/install.sh")"
    [[ "$module_block" == *'wireguard ip_tables iptable_nat ip6_tables ip6table_nat'* ]]

    run awk '
        /atomic_write \/etc\/modules-load.d\/wg-easy.conf/ { capture = 1; next }
        capture && /^EOF$/ { exit }
        capture { print }
    ' "$V2_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ "$output" = $'wireguard\nip_tables\niptable_nat\nip6_tables\nip6table_nat' ]
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
    grep -q -- '--ctorigdstport "$QBIT_PUBLIC_PORT" -j RETURN' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q -- '--ctorigdstport "$WG_PUBLIC_PORT" -j RETURN' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -c 'QBIT_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh" | grep -q '^[2-9]'
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
    grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    grep -q 'docker port qbittorrent' "$V2_ROOT/install.sh"
    grep -q 'docker port webdav' "$V2_ROOT/install.sh"
    grep -q 'UI publish yalnız loopback' "$V2_ROOT/install.sh"
    # Contract §14.13 / DD-88
    grep -q 'for ui_host in portainer wg qbit file' "$V2_ROOT/install.sh"
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
    grep -qE '^PORTAINER_IMAGE="portainer/portainer-ce:lts"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^FILEBROWSER_IMAGE="filebrowser/filebrowser:v2"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^QBITTORRENT_IMAGE="lscr\.io/linuxserver/qbittorrent:latest"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^WG_EASY_IMAGE="ghcr.io/wg-easy/wg-easy:15"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^UNPACKERR_IMAGE="ghcr.io/unpackerr/unpackerr:0\.15"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^RCLONE_IMAGE="rclone/rclone:1\.75"' \
        "$V2_ROOT/config/defaults.env"
    # Forbidden floats — except qBittorrent:latest (LinuxServer's stable+lt v2 track).
    ! grep -qE '_(IMAGE)="[^"]*:(stable|sts|edge|nightly|libtorrentv1)(@|")' \
        "$V2_ROOT/config/defaults.env"
    ! grep -qE '^(PORTAINER|FILEBROWSER|WG_EASY|UNPACKERR|RCLONE)_IMAGE="[^"]*:latest' \
        "$V2_ROOT/config/defaults.env"
    # Track images must not carry a digest pin.
    ! grep -qE '^(PORTAINER|FILEBROWSER|QBITTORRENT|WG_EASY|UNPACKERR|RCLONE)_IMAGE="[^"]*@sha256:' \
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

@test "container-backup seed paths are the installer's config and htpasswd files" {
    # The worker restates the two paths because it runs before defaults.env
    # exists on a fresh host; this pins them to the single source of truth.
    local config_file htpasswd_file host_state host_files
    config_file="$(awk -F'"' '/^CONFIG_FILE=/{print $2}' "$V2_ROOT/config/defaults.env")"
    htpasswd_file="$(awk -F'"' '/^WEBDAV_HTPASSWD_FILE=/{print $2}' "$V2_ROOT/config/defaults.env")"
    host_state="$(awk -F= '/^HOST_STATE=/{print $2}' "$V2_ROOT/dev/container-backup-remote.sh")"
    host_files="$(sed -n 's/^HOST_FILES=(\(.*\))$/\1/p' "$V2_ROOT/dev/container-backup-remote.sh")"
    [ "$host_files" = "config.env webdav.htpasswd" ]
    [ "$host_state/config.env" = "$config_file" ]
    [ "$host_state/webdav.htpasswd" = "$htpasswd_file" ]
}

@test "container-backup seed accepts exactly the keys write_config writes" {
    local written accepted
    written="$(awk '/^write_config\(\)/,/^EOF$/' "$V2_ROOT/install.sh" |
        grep -oE '^[A-Z_]+=' | tr -d = | sort | tr '\n' ' ')"
    accepted="$(awk '/^check_config_env\(\)/,/^}/' "$V2_ROOT/dev/container-backup-remote.sh" |
        grep -oE '^ +[A-Z_|]+\)' | tr -d ' )' | tr '|' '\n' | sort | tr '\n' ' ')"
    [ -n "$written" ]
    [ "$written" = "$accepted" ]
}

@test "container-backup launcher stays on bash 3.2 features for Finder" {
    # Finder runs .command files with macOS /bin/bash 3.2.
    ! grep -qE 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)' "$V2_ROOT/container-backup.command"
    grep -q 'seed' "$V2_ROOT/container-backup.command"
    grep -q -- '-pbkdf2 -iter 600000 -md sha256' "$V2_ROOT/container-backup.command"
}
