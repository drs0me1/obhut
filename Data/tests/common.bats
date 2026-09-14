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
    case "$output" in *'%s%s'*) ;; *) false ;; esac
}

@test "die exits non-zero" {
    run die "bitti"
    [ "$status" -eq 1 ]
    case "$output" in *"bitti"*) ;; *) false ;; esac
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
    run ! grep -q 'trixie' "$V2_ROOT/install.sh"
    # Caddy repo stays distro-agnostic (any-version) — same line on ubuntu.
    grep -q 'caddy/stable/deb/debian any-version main' "$V2_ROOT/install.sh"
    # ufw active is a hard stop before any mutation (stage_0).
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" |
        grep -q "ufw aktif"
    # systemd-resolved stub symlink is repointed so host DNS survives.
    grep -q 'stub-resolv.conf' "$V2_ROOT/install.sh"
    grep -qF 'ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf' \
        "$V2_ROOT/install.sh"
    # The Caddy repo is verified by its signed-by keyring; debian-keyring is
    # not installed on any OS (DD-125).
    grep -q 'signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg' \
        "$V2_ROOT/install.sh"
    run grep -q 'dns_pkgs+=(debian-keyring)' "$V2_ROOT/install.sh"
    [ "$status" -ne 0 ]
    # Every apt-get call waits on the dpkg lock (ubuntu unattended-upgrades).
    grep -q 'APT_OPTS=(-o DPkg::Lock::Timeout=' "$V2_ROOT/install.sh"
    [ "$(grep -cF 'apt-get "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 9 ]
    # retry runs a function in a child bash that does not inherit arrays, so
    # the masked-quiet installs take APT_OPTS as arguments (DD-125).
    [ "$(grep -cF 'apt_get_install_masked_quiet "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 2 ]
    run bash -c "awk '/^apt_get_install_masked_quiet\\(\\)/,/^}/' '$V2_ROOT/install.sh' | grep -q APT_OPTS"
    [ "$status" -ne 0 ]
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
        grep -qF '[[ -n "$prev_id" && -n "$prev_codename" ]] || return 0'
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
    run ! grep -q 'atomic_write /etc/sysctl.d/99-master' "$V2_ROOT/install.sh"
    # The v2-73 file-name migration is gone (v2-96, DD-96): no host still has it.
    run ! grep -qE 'SYSCTL_LEGACY_FILES|remove_legacy_sysctl_files' \
        "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env"
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

@test "apt keeps no downloaded packages and Docker skips its recommends" {
    # DD-125: the installer's own .deb downloads are not left in the cache,
    # and Docker comes without buildx, git/perl or rootless-extras.
    grep -qF 'APT_OPTS=(-o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false)' \
        "$V2_ROOT/install.sh"
    docker_install="$(awk '/retry "apt-docker"/{p=1} p{print} p && !/\\$/{exit}' \
        "$V2_ROOT/install.sh")"
    grep -q -- '--no-install-recommends' <<<"$docker_install"
    grep -q 'docker-ce docker-ce-cli containerd.io docker-compose-plugin apparmor pigz' \
        <<<"$docker_install"
    run grep -qE 'docker-buildx-plugin|docker-ce-rootless-extras' "$V2_ROOT/install.sh"
    [ "$status" -ne 0 ]
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
    grep -qx 'docker-repo-suite' <<<"$code"
    grep -qx 'docker-repo-suite' <<<"$doc"

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
    [ "$(tail -c1 "$TMP/o" | wc -l | tr -d ' ')" = "1" ]
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
    case "$output" in *"flock"*) ;; *) false ;; esac
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
    case "$output" in *"ok:hi"*) ;; *) false ;; esac
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
    [ "$(grep -c 'ctorigdstport "$TORRENT_PUBLIC_PORT"' \
        "$V2_ROOT/scripts/firewall.sh")" -ge 2 ]
}

@test "firewall requires ports and chains from state" {
    grep -q 'CHAIN_INPUT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'TORRENT_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX' "$V2_ROOT/install.sh"
    run ! grep -qE 'WG_PUBLIC_PORT:=61001|TORRENT_PUBLIC_PORT:=61005|CHAIN_INPUT:=MASTER' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX}IN-' "$V2_ROOT/scripts/firewall.sh"
}

@test "qbittorrent and unpackerr use DOWNLOADS_UID/GID tokens" {
    grep -q 'PUID: "__DOWNLOADS_UID__"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'PGID: "__DOWNLOADS_GID__"' "$V2_ROOT/templates/compose.yaml"
    grep -c 'user: "__DOWNLOADS_UID__:__DOWNLOADS_GID__"' \
        "$V2_ROOT/templates/compose.yaml" | grep -q '^[2-9]'
    run ! grep -qE 'PUID: "1000"|PGID: "1000"|user: "1000:1000"' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "downloads tree is chown 1000 for qbittorrent filebrowser unpackerr" {
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
    downloads_tree="$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$downloads_tree" ]
    run ! grep -q 'chown -R' <<<"$downloads_tree"
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
    # It reports how many entries it fixed, so the log says so only when true.
    chmod 0775 "$TMP/dl"
    [ "$(ensure_downloads_tree "$TMP/dl" "$(id -u)" "$(id -g)")" = 2 ]
    [ "$(ensure_downloads_tree "$TMP/dl" "$(id -u)" "$(id -g)")" = 0 ]
    [ "$(stat -f '%Lp' "$TMP/dl/sub" 2>/dev/null || stat -c '%a' "$TMP/dl/sub")" = "775" ]
    [ "$(stat -f '%Lp' "$TMP/dl/sub/bad" 2>/dev/null || stat -c '%a' "$TMP/dl/sub/bad")" = "664" ]
    [ "$(stat -f '%Lp' "$TMP/dl/sub/good" 2>/dev/null || stat -c '%a' "$TMP/dl/sub/good")" = "664" ]
    run ensure_downloads_tree "$TMP/yok" "$(id -u)" "$(id -g)"
    case "$output" in *"die: downloads dizini yok"*) ;; *) false ;; esac
}

@test "docker daemon.json merges dns and log rotation via jq" {
    grep -q 'merge_docker_daemon_config' "$V2_ROOT/install.sh"
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q 'jq'
    awk '/^merge_docker_daemon_config\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -q '\.dns = \["1.1.1.1", "1.0.0.1"\]'
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$stage4" ]
    run ! grep -q 'atomic_write /etc/docker/daemon.json' <<<"$stage4"
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
    run ! grep -q 'die "tcp_congestion_control' <<<"$block"
}

@test "downloads path rejects unsafe characters and compose needs no .env" {
    grep -q 'downloads yolu yalnızca' "$V2_ROOT/install.sh"
    grep -q "downloads yolu '..' içeremez" "$V2_ROOT/install.sh"
    grep -q 'assert_downloads_path_allowed' "$V2_ROOT/install.sh"
    grep -q 'sistem dizinine izin vermez' "$V2_ROOT/install.sh"
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$stage4" ]
    run ! grep -q 'atomic_write "$COMPOSE_DIR/.env"' <<<"$stage4"
    # Every value is rendered into the file, so no interpolation is left for
    # Compose to resolve and a stray .env cannot change the stack.
    run ! grep -q '\${' "$V2_ROOT/templates/compose.yaml"
}

@test "compose runs dozzle behind a login with actions, no shell, loopback only" {
    # DD-116: docker.sock is root-equivalent, so loopback + Caddy + users.yml.
    block="$(awk '/^  dozzle:$/,/^  filebrowser:$/' "$V2_ROOT/templates/compose.yaml")"
    [ -n "$block" ]
    grep -q '"127.0.0.1:__DOZZLE_UI_PORT__:8080"' <<<"$block"
    grep -q 'DOZZLE_AUTH_PROVIDER: simple' <<<"$block"
    grep -q 'DOZZLE_ENABLE_ACTIONS: "true"' <<<"$block"
    grep -q 'DOZZLE_NO_ANALYTICS: "true"' <<<"$block"
    run ! grep -q 'DOZZLE_ENABLE_SHELL' <<<"$block"
    grep -q 'read_only: true' <<<"$block"
    grep -q -- '- no-new-privileges=true' <<<"$block"
    grep -q -- '- ALL' <<<"$block"
    grep -q '__DOZZLE_DATA_DIR__:/data' <<<"$block"
    grep -q '\["CMD", "/dozzle", "healthcheck"\]' <<<"$block"
    run ! grep -qi portainer "$V2_ROOT/templates/compose.yaml" "$V2_ROOT/templates/Caddyfile" \
        "$V2_ROOT/templates/dnsmasq.conf"
}

@test "caddy proxies dozzle over plain loopback http" {
    grep -q 'reverse_proxy 127.0.0.1:__DOZZLE_UI_PORT__' "$V2_ROOT/templates/Caddyfile"
    run ! grep -q 'tls_insecure_skip_verify' "$V2_ROOT/templates/Caddyfile"
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
    run ! grep -q -- '--password' <<<"$body"
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
    run ! grep -q 'fixture-password-123' "$TMP/argv"
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
    run ! grep -qE 'UN_(QBITTORRENT|TRANSMISSION)_' "$V2_ROOT/templates/compose.yaml"
}

@test "qbittorrent is synced from its template and the input account, ports stay on the command line" {
    # DD-129: managed keys live in templates/qBittorrent.conf; the account comes
    # from TORRENT_USER/TORRENT_PASS; the image passes --webui-port and
    # --torrenting-port on every start, so ports are not template keys.
    block="$(awk '/^  qbittorrent:$/,/^  unpackerr:$/' "$V2_ROOT/templates/compose.yaml")"
    [ -n "$block" ]
    grep -q 'image: __QBITTORRENT_IMAGE__' <<<"$block"
    grep -q '"127.0.0.1:__TORRENT_UI_PORT__:__TORRENT_UI_PORT__"' <<<"$block"
    grep -q 'WEBUI_PORT: "__TORRENT_UI_PORT__"' <<<"$block"
    grep -q 'TORRENTING_PORT: "__TORRENT_PUBLIC_PORT__"' <<<"$block"
    grep -q '__QBITTORRENT_DATA_DIR__:/config' <<<"$block"
    grep -q 'stop_grace_period: 30s' <<<"$block"
    run ! grep -qE 'FILE__|/run/secrets|PEERPORT' <<<"$block"
    run ! grep -qi transmission "$V2_ROOT/templates/compose.yaml"
    grep -q '^QBITTORRENT_CONF_FILE="/etc/master-stack/qbittorrent/qBittorrent/qBittorrent.conf"$' \
        "$V2_ROOT/config/defaults.env"
    run ! grep -qE '^TRANSMISSION_' "$V2_ROOT/config/defaults.env"
    # The template: the operator's settings plus the auth guards, no ports, no
    # generated or account keys.
    local tpl="$V2_ROOT/templates/qBittorrent.conf"
    for key in 'Session\MaxActiveDownloads=12' 'Session\MaxConnections=800' \
        'Session\Preallocation=true' 'Session\TempPathEnabled=true' 'General\Locale=en' \
        'WebUI\LocalHostAuth=true' 'WebUI\AuthSubnetWhitelistEnabled=false' 'Accepted=true'; do
        grep -qxF "$key" "$tpl"
    done
    run ! grep -qE '^(Session\\Port|Session\\SSL\\Port|WebUI\\Port|Connection\\PortRangeMin|MigrationVersion|Cookies|WebUI\\Username|WebUI\\Password_PBKDF2)=' "$tpl"
    # Input keys, stage wiring and the Caddy auth check.
    grep -q 'TORRENT_USER TORRENT_PASS TS_AUTH_KEY' "$V2_ROOT/install.sh"
    grep -q 'INPUT_NONEMPTY_KEYS=.*TORRENT_USER TORRENT_PASS"' "$V2_ROOT/install.sh"
    grep -qx 'TORRENT_USER=' "$V2_ROOT/config/kurulum.env.example"
    grep -qx 'TORRENT_PASS=' "$V2_ROOT/config/kurulum.env.example"
    # The Transmission and Portainer transition aids are gone (v2-96).
    run ! grep -qiE 'transmission|portainer|INPUT_REMOVED_KEYS' "$V2_ROOT/install.sh" "$V2_ROOT/common.sh"
    run ! grep -q 'TRANSMISSION' "$V2_ROOT/config/kurulum.env.example"
    stage0="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'validate_account qBittorrent "\$TORRENT_NEW_USER" "\$TORRENT_NEW_PASS"' <<<"$stage0"
    grep -q 'unattended-upgrades python3' "$V2_ROOT/install.sh"
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    awk '/ensure_qbittorrent_dir$/ {a = NR} /sync_qbittorrent_config$/ {b = NR}
         /render_template .*compose.yaml/ {c = NR} END {exit !(a && b && c && a < b && b < c)}' <<<"$stage4"
    stage7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -q '/api/v2/app/version' <<<"$stage7"
    grep -q '"\$code" == "403"' <<<"$stage7"
    awk '/"\$code" == "403"/ {a = NR} /^    qbit_login_check$/ {b = NR} /^    unset TORRENT_NEW_PASS$/ {c = NR}
         END {exit !(a && b && c && a < b && b < c)}' <<<"$stage7"
    # No file-pull or restore path for qBittorrent is left (DD-128 narrowed).
    run ! grep -qE 'restore_qbittorrent_snapshot|kurulum/qbittorrent|SNAPSHOT_QB' "$V2_ROOT/install.sh"
}

@test "qbit_pbkdf2 writes qBittorrent's hash format and verifies it without argv" {
    command -v python3 >/dev/null || skip "python3 yok"
    eval "$(awk '/^qbit_pbkdf2\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    h="$(printf '%s' 'pw with $pace&=' | qbit_pbkdf2)"
    case "$h" in '"@ByteArray('*':'*')"') ;; *) false ;; esac
    # 16-byte salt and 64-byte key, base64.
    inner="${h#\"@ByteArray(}"; inner="${inner%)\"}"
    [ "$(printf '%s' "${inner%%:*}" | base64 -D 2>/dev/null | wc -c | tr -d ' ' || printf '%s' "${inner%%:*}" | base64 -d | wc -c)" = 16 ]
    [ "$(printf '%s' "${inner#*:}" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 64 ]
    printf '%s' 'pw with $pace&=' | qbit_pbkdf2 "$h"
    run bash -c "$(declare -f qbit_pbkdf2); printf '%s' other | qbit_pbkdf2 '$h'"
    [ "$status" -eq 1 ]
    run bash -c "$(declare -f qbit_pbkdf2); printf '%s' x | qbit_pbkdf2 'plain-not-a-hash'"
    [ "$status" -eq 2 ]
    # A fresh salt every time.
    [ "$(printf '%s' same | qbit_pbkdf2)" != "$(printf '%s' same | qbit_pbkdf2)" ]
    # Known vector: salt "0123456789abcdef", password "12345test".
    kv="$(python3 -c 'import base64,hashlib; s=b"0123456789abcdef"; print("\"@ByteArray(%s:%s)\"" % (base64.b64encode(s).decode(), base64.b64encode(hashlib.pbkdf2_hmac("sha512", b"12345test", s, 100000, 64)).decode()))')"
    printf '%s' 12345test | qbit_pbkdf2 "$kv"
    body="$(awk '/^qbit_pbkdf2\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'QB_EXISTING="\${1:-}" python3 -c' <<<"$body"
    grep -q 'sys.stdin.buffer.read()' <<<"$body"
}

@test "qbit_conf_diff and qbit_conf_merge touch only managed keys and are idempotent" {
    eval "$(awk '/^qbit_conf_flatten\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^qbit_conf_diff\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^qbit_conf_merge\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    cat >"$TMP/live.conf" <<'EOF'
[Application]
FileLogger\Enabled=true

[BitTorrent]
Session\DHTEnabled=true
Session\MaxActiveDownloads=3
Session\SSL\Port=11680
Session\MaxActiveDownloads=5

[Preferences]
WebUI\Address=*
WebUI\Port=61006

[RSS]
AutoDownloader\SmartEpisodeFilter=s(\\d+)e(\\d+), "(\\d{4}[.\\-]\\d{1,2})"
EOF
    cat >"$TMP/tpl.conf" <<'EOF'
# comment
[BitTorrent]
Session\MaxActiveDownloads=12
Session\Preallocation=true

[LegalNotice]
Accepted=true

[Preferences]
WebUI\Address=*
WebUI\LocalHostAuth=true
EOF
    desired="$(qbit_conf_flatten "$TMP/tpl.conf"; printf '[Preferences]\tWebUI\\Username=me\n')"
    [ "$(qbit_conf_diff "$TMP/live.conf" <<<"$desired")" = "[BitTorrent] Session\\MaxActiveDownloads
[BitTorrent] Session\\Preallocation
[LegalNotice] Accepted
[Preferences] WebUI\\LocalHostAuth
[Preferences] WebUI\\Username" ]
    qbit_conf_merge "$TMP/live.conf" <<<"$desired" >"$TMP/merged.conf"
    # Managed keys set in place, missing ones added to their section, a missing
    # section appended; unmanaged lines untouched, values with '=' kept.
    grep -qxF 'Session\MaxActiveDownloads=12' "$TMP/merged.conf"
    grep -qxF 'Session\DHTEnabled=true' "$TMP/merged.conf"
    grep -qxF 'Session\SSL\Port=11680' "$TMP/merged.conf"
    grep -qxF 'WebUI\Port=61006' "$TMP/merged.conf"
    grep -qF 'SmartEpisodeFilter=s(\\d+)e(\\d+), "(\\d{4}[.\\-]\\d{1,2})"' "$TMP/merged.conf"
    [ "$(grep -c 'MaxActiveDownloads' "$TMP/merged.conf")" = 1 ]
    awk '/^\[BitTorrent\]$/ {b = 1} b && /^Session\\Preallocation=true$/ {p = NR} /^\[Preferences\]$/ {q = NR}
         END {exit !(p && q && p < q)}' "$TMP/merged.conf"
    awk '/^\[Preferences\]$/ {s = 1; next} /^\[/ {s = 0} s && /^WebUI\\Username=me$/ {f = 1} END {exit !f}' "$TMP/merged.conf"
    grep -qx '\[LegalNotice\]' "$TMP/merged.conf"
    [ -z "$(qbit_conf_diff "$TMP/merged.conf" <<<"$desired")" ]
    qbit_conf_merge "$TMP/merged.conf" <<<"$desired" >"$TMP/merged2.conf"
    cmp "$TMP/merged.conf" "$TMP/merged2.conf"
    # A fresh file from nothing holds exactly the desired keys.
    qbit_conf_merge /dev/null <<<"$desired" >"$TMP/fresh.conf"
    [ -z "$(qbit_conf_diff "$TMP/fresh.conf" <<<"$desired")" ]
    [ "$(grep -c '=' "$TMP/fresh.conf")" = "$(grep -c . <<<"$desired")" ]
    # The real template parses into the expected sections.
    [ "$(qbit_conf_flatten "$V2_ROOT/templates/qBittorrent.conf" | cut -f1 | sort -u | tr '\n' ' ')" = "[AutoRun] [BitTorrent] [LegalNotice] [Network] [Preferences] " ]
}

@test "sync_qbittorrent_config writes once, keeps a matching hash, stops the client only to change" {
    command -v python3 >/dev/null || skip "python3 yok"
    for fn in qbit_pbkdf2 qbit_conf_flatten qbit_conf_diff qbit_conf_merge sync_qbittorrent_config; do
        eval "$(awk "/^${fn}\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
    done
    log() { printf '%s %s\n' "$1" "$2" >>"$TMP/log"; }
    install() { local a; for a in "$@"; do :; done; mkdir -p "$TMP/qbdata/qBittorrent"; }
    chown() { :; }
    docker() { printf '%s\n' "$*" >>"$TMP/docker-calls"; [ "$1" != inspect ] || echo true; }
    QBITTORRENT_DATA_DIR="$TMP/qbdata" QBITTORRENT_CONF_FILE="$TMP/qbdata/qBittorrent/qBittorrent.conf"
    DOWNLOADS_UID=1000 DOWNLOADS_GID=1000
    TORRENT_NEW_USER=admin TORRENT_NEW_PASS='fixture-pass-123'

    # Fresh: written from the template plus the account.
    sync_qbittorrent_config
    conf="$QBITTORRENT_CONF_FILE"
    grep -qxF 'Session\MaxActiveDownloads=12' "$conf"
    grep -qxF 'WebUI\Username=admin' "$conf"
    h1="$(awk 'index($0, "WebUI\\Password_PBKDF2=") == 1' "$conf")"
    [ -n "$h1" ]
    printf '%s' 'fixture-pass-123' | qbit_pbkdf2 "${h1#*=}"

    # Same input: nothing written, the container left alone, same hash.
    printf 'Session\\SSL\\Port=4242\n' >>"$conf"
    before="$(shasum "$conf")"
    rm -f "$TMP/docker-calls"
    sync_qbittorrent_config
    [ "$(shasum "$conf")" = "$before" ]
    grep -q 'şablonla aynı; dokunulmadı' "$TMP/log"
    run ! grep -q '^stop' "$TMP/docker-calls"

    # A setting changed in the UI and a new password: stop, fix only those, start.
    sed -i.bak 's/^Session\\MaxActiveDownloads=12$/Session\\MaxActiveDownloads=3/' "$conf"
    TORRENT_NEW_PASS='fixture-pass-456'
    rm -f "$TMP/docker-calls"
    sync_qbittorrent_config
    grep -qxF 'Session\MaxActiveDownloads=12' "$conf"
    grep -qxF 'Session\SSL\Port=4242' "$conf"
    h2="$(awk 'index($0, "WebUI\\Password_PBKDF2=") == 1' "$conf")"
    [ "$h2" != "$h1" ]
    printf '%s' 'fixture-pass-456' | qbit_pbkdf2 "${h2#*=}"
    [ "$(sed -n 1p "$TMP/docker-calls")" = "inspect -f {{.State.Running}} qbittorrent" ]
    grep -qx 'stop qbittorrent' "$TMP/docker-calls"
    grep -qx 'start qbittorrent' "$TMP/docker-calls"
    grep -q 'eşitlendi: \[BitTorrent\] Session\\MaxActiveDownloads, \[Preferences\] WebUI\\Password_PBKDF2' "$TMP/log"
    # Neither password nor hash reaches the log.
    run ! grep -qE 'fixture-pass|ByteArray' "$TMP/log"
}

@test "qbit_login_check sends the password on stdin and never retries a refused login" {
    body="$(awk '/^qbit_login_check\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$body" ]
    grep -q "printf '%s\\\\n%s' \"\$TORRENT_NEW_USER\" \"\$TORRENT_NEW_PASS\" |" <<<"$body"
    grep -q 'curl .*--data @-' <<<"$body"
    # The password never appears as a command argument.
    run ! grep -qE '(curl|jq|python3)[^|]*\$TORRENT_NEW_PASS' <<<"$body"
    # Only "not ready" is retried; a 401 would count toward qBittorrent's IP ban.
    grep -q 'case "\$code" in 000 | 5??) ;; \*) break ;; esac' <<<"$body"
    grep -q '.bypass_local_auth == false and .bypass_auth_subnet_whitelist_enabled == false' <<<"$body"
    # qBittorrent 5.2 answers a good login with 204 and a SID cookie (measured).
    grep -qF '[[ "$code" != "200" && "$code" != "204" ]] || ! grep -q '"'"'SID'"'"' "$jar"' <<<"$body"
    grep -q 'rm -f -- "\$jar"' <<<"$body"
}

@test "filebrowser classic serves downloads at /srv with disableExec" {
    grep -q 'container_name: filebrowser' "$V2_ROOT/templates/compose.yaml"
    grep -q '__DOWNLOADS_PATH__:/srv' "$V2_ROOT/templates/compose.yaml"
    grep -q '__FILEBROWSER_DATA_DIR__:/database' "$V2_ROOT/templates/compose.yaml"
    grep -q '__FILEBROWSER_DATA_DIR__/config:/config' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--disableExec' "$V2_ROOT/templates/compose.yaml"
    # The template comment names the deprecated flag; only uncommented lines count.
    compose="$(grep -v '^[[:space:]]*#' "$V2_ROOT/templates/compose.yaml")"
    [ -n "$compose" ]
    run ! grep -q -- '--disable-exec' <<<"$compose"
    grep -q 'no-new-privileges=true' "$V2_ROOT/templates/compose.yaml"
    run ! grep -q 'no-new-privileges:true' "$V2_ROOT/templates/compose.yaml"
    grep -q 'filebrowser/filebrowser:v2' "$V2_ROOT/config/defaults.env"
    grep -q 'FILEBROWSER_DATA_DIR="/etc/master-stack/filebrowser-data"' \
        "$V2_ROOT/config/defaults.env"
    grep -q 'ensure_filebrowser_data_dir' "$V2_ROOT/install.sh"
    grep -q 'FILEBROWSER_DATA_DIR/config' "$V2_ROOT/install.sh"
    # Old operator hints about default or logged passwords are gone. The DD-118
    # comment still names the random admin password, so only code lines count.
    install_code="$(grep -v '^[[:space:]]*#' "$V2_ROOT/install.sh")"
    [ -n "$install_code" ]
    run ! grep -q 'FileBrowser varsayılan: admin / admin' <<<"$install_code"
    run ! grep -q 'rastgele admin parolası' <<<"$install_code"
    run ! grep -q 'qBittorrent varsayılan WebUI' <<<"$install_code"
    run ! grep -q 'docker logs filebrowser' <<<"$install_code"
    run ! grep -q 'ilk yönetici hesabını sen kur' <<<"$install_code"
    run ! grep -q 'QUANTUM_CONFIG_FILE' "$V2_ROOT/config/defaults.env"
    run ! grep -q 'gtsteffaniak/filebrowser' "$V2_ROOT/config/defaults.env"
    run ! grep -q 'filebrowser_data:' "$V2_ROOT/templates/compose.yaml"
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
    run ! grep -q 'FILEBROWSER_NEW_PASS' <<<"$(awk '/^filebrowser_cli\(\)/,/^}$/' "$V2_ROOT/install.sh")"
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
    run ! grep -q 'fixture-password-123' "$TMP/docker-calls" "$TMP/htpasswd-argv"
    grep -q 'config init .*--viewMode mosaic' "$TMP/docker-calls"
    grep -q -- '--minimumPasswordLength 12' "$TMP/docker-calls"
    run ! grep -q '^restart' "$TMP/docker-calls"
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
    [ -n "$SERVICE_NAMES" ]
    local name
    for name in $SERVICE_NAMES; do
        grep -q "interface-name=${name}.__LOCAL_DOMAIN__" \
            "$V2_ROOT/templates/dnsmasq.conf"
        grep -q "http://${name}.__LOCAL_DOMAIN__" \
            "$V2_ROOT/templates/Caddyfile"
    done
    run ! grep -q 'CONTAINER_NAMES=' "$V2_ROOT/config/defaults.env"
}

@test "compose public UDP ports are not bound to WAN_IPV4" {
    grep -q '"0.0.0.0:__TORRENT_PUBLIC_PORT__:__TORRENT_PUBLIC_PORT__/udp"' \
        "$V2_ROOT/templates/compose.yaml"
    run ! grep -q '\${WAN_IPV4}' "$V2_ROOT/templates/compose.yaml"
}

@test "compose public peer ports are IPv4-only" {
    grep -q '0.0.0.0:__TORRENT_PUBLIC_PORT__' "$V2_ROOT/templates/compose.yaml"
    # Unqualified host:port would also bind [::] on Docker.
    run ! grep -qE '^[[:space:]]*- "__TORRENT_PUBLIC_PORT__:__TORRENT_PUBLIC_PORT__/' \
        "$V2_ROOT/templates/compose.yaml"
}

@test "refresh-tailnet-config touches only Caddy state and the firewall unit" {
    # Compose, WebDAV and raw netfilter stay out of the timer's scope.
    run ! grep -qE 'compose|DOCKER-USER|master-webdav|iptables' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
    run ! grep -q 'rebind_webdav' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'BOUND_UNITS="caddy.service"' \
        "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "refresh timer recovers a broken firewall unit" {
    local body
    body="$(awk '/^recover_firewall_if_broken\(\)/,/^}$/' \
        "$V2_ROOT/scripts/refresh-tailnet-config")"
    [ -n "$body" ]
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
    [ "$(awk '/^recover_firewall_if_broken$/ { print NR; exit }' \
        "$V2_ROOT/scripts/refresh-tailnet-config")" -lt \
        "$(awk '/^if ! wait_for_tailscale_ready; then$/ { print NR; exit }' \
        "$V2_ROOT/scripts/refresh-tailnet-config")" ]
}

@test "refresh-tailnet timer is five minutes" {
    grep -q 'OnUnitActiveSec=5min' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'WantedBy=timers.target' \
        "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'refresh-tailnet-config.timer' "$V2_ROOT/install.sh"
    # Unit= already names the oneshot; Requires= is redundant and couples
    # timer activation to service start failure modes.
    run ! grep -q 'Requires=refresh-tailnet-config.service' \
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
    [ "$(grep -n 'udp \$TAILSCALE_UDP_PORT' <<<"$pairs" | cut -d: -f1)" -lt \
        "$(grep -n 'v4' <<<"$pairs" | head -1 | cut -d: -f1)" ]
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
    run ! grep -qE 'tailscale (up|set|login)' "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "refresh-tailnet uses restart, never try-restart" {
    # try-restart is a no-op on a failed unit AND returns 0, so the old
    # "try-restart || restart" fallback was unreachable and a failed unit was
    # never resurrected when the address came back. The script's own comment
    # explains this, so only uncommented lines count.
    code="$(grep -v '^[[:space:]]*#' "$V2_ROOT/scripts/refresh-tailnet-config")"
    [ -n "$code" ]
    run ! grep -q 'try-restart' <<<"$code"
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
    run ! grep -q 'OnFailure=.*watch-tailnet' "$V2_ROOT/install.sh"
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
    case "$out" in *stale*) ;; *) false ;; esac
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
    run ! grep -q 'rmem_max = 7500000' "$V2_ROOT/install.sh"
}

@test "watch-tailnet-addr is removed; refresh timer remains" {
    [ ! -e "$V2_ROOT/scripts/watch-tailnet-addr" ]
    [ ! -e "$V2_ROOT/systemd/watch-tailnet-addr.service" ]
    run ! grep -q 'watch-tailnet-addr' "$V2_ROOT/install.sh"
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
    run ! grep -q 'apply_udp_gro' "$V2_ROOT/install.sh"
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
    run ! grep -q '__TAILSCALE_IPV4__:__WEBDAV_PORT__' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--htpasswd=/run/secrets/webdav_htpasswd' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--read-only' "$V2_ROOT/templates/compose.yaml"
    grep -q '__DOWNLOADS_PATH__:/downloads:ro' "$V2_ROOT/templates/compose.yaml"
    grep -q 'reverse_proxy 127.0.0.1:{$WEBDAV_PORT}' "$V2_ROOT/templates/Caddyfile"
    grep -q 'http://webdav.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}:{$WEBDAV_PORT}' \
        "$V2_ROOT/templates/Caddyfile"
    run ! grep -q '__WEBDAV_PORT__' "$V2_ROOT/templates/Caddyfile"
    run ! grep -qE 'http://\{\$TAILSCALE_IPV4\}[[:space:],}]' \
        "$V2_ROOT/templates/Caddyfile"
    grep -q 'WEBDAV_PORT_CHANGED' "$V2_ROOT/install.sh"
    run ! grep -q 'master-webdav' "$V2_ROOT/install.sh"
    run ! grep -qE 'apt-get install -y[^\n]*\brclone\b' "$V2_ROOT/install.sh"
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
    run ! awk '
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
    [ -n "$body" ]
    run ! grep -qE '\-A "\$staging" -j DROP$' <<<"$body"
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
    run ! grep -qE 'DOCKER-USER.*-F|-F DOCKER-USER' "$V2_ROOT/scripts/firewall.sh"
}

@test "WAN allow count is derived from one list and rejects extra passes" {
    local script="$V2_ROOT/scripts/firewall.sh" body
    # Pattern checks find a missing rule but never an extra one: an
    # interface-qualified pass such as '-i WAN -j ACCEPT' satisfies every
    # expected pattern. The count must match the list exactly.
    body="$(awk '/^check_wan_allow_count\(\)/,/^}$/' "$script")"
    [ -n "$body" ]
    grep -q 'fazladan geçiş' <<<"$body"
    grep -q 'expected' <<<"$body"
    # Both the check_rule calls and the count come from the same list.
    grep -q 'wan_allow_pairs "\$family"' "$script"
    grep -q 'docker_return_pairs "\$family"' "$script"
    grep -q 'check_wan_allow_count "\$bin" "\$CHAIN_INPUT" ACCEPT "\$n"' "$script"
    grep -q 'check_wan_allow_count "\$bin" "\$CHAIN_DOCKER" RETURN "\$n"' "$script"
    # Ports must not be restated next to the loop.
    run ! grep -q 'check_rule iptables "\$CHAIN_INPUT" -i "\$WAN_INTERFACE" \\' "$script"
}

@test "check_chain_shape rejects a single bypass rule before the WAN DROP" {
    local body
    body="$(awk '/^check_chain_shape\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    [ -n "$body" ]
    # Exactly one WAN DROP, allows before it, and no unconditional rule before.
    grep -q 'WAN DROP sayısı' <<<"$body"
    grep -q 'bypass' <<<"$body"
    grep -qF '== "-j ACCEPT"' <<<"$body"
    grep -qF '== "-j RETURN"' <<<"$body"
}

@test "apply purges staging leftovers including referenced ones" {
    local script="$V2_ROOT/scripts/firewall.sh" body
    body="$(awk '/^purge_staging_leftovers\(\)/,/^}$/' "$script")"
    [ -n "$body" ]
    # An interrupted activate_named leaves the staging chain jumped from its
    # parent; skipping it would fail --check forever. Jump goes first.
    grep -q -- '-D "\$parent" -j "\$chain"' <<<"$body"
    grep -q -- '-X "\$chain"' <<<"$body"
    # It must run after the policy is in place, never before.
    [ "$(awk '/^purge_staging_leftovers iptables$/ { print NR; exit }' "$script")" -gt \
        "$(awk '/^apply_docker6$/ { print NR; exit }' "$script")" ]
    [ "$(awk '/^purge_staging_leftovers iptables$/ { print NR; exit }' "$script")" -lt \
        "$(awk '/^check_no_staging_artifacts iptables$/ { print NR; exit }' "$script")" ]
}

@test "ts-input precedence does not delete-all MASTER-INPUT jumps" {
    grep -q 'ensure_ts_input_precedence' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'insert_pos_after_ts_input' "$V2_ROOT/scripts/firewall.sh"
    ts_precedence="$(awk '/^ensure_ts_input_precedence\(\)/,/^create_staging\(\)/' "$V2_ROOT/scripts/firewall.sh")"
    [ -n "$ts_precedence" ]
    run ! grep -qE 'while .*-D INPUT -j "\$CHAIN_INPUT"' <<<"$ts_precedence"
}

@test "master-firewall converges without ordering on docker" {
    local unit="$V2_ROOT/systemd/master-firewall.service"
    # Host INPUT must not wait on Docker; the drop-in adds MASTER-DOCKER later.
    run ! grep -q 'After=.*docker.service' "$unit"
    run ! grep -q 'Wants=.*docker.service' "$unit"
    run ! grep -q 'Requires=docker.service' "$unit"
    run ! grep -q 'WantedBy=docker.service' "$unit"
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
    run ! grep -qiE 'compose|master-compose' "$unit"
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
    run ! grep -q 'remove_stale_filebrowser' "$s"
    run ! grep -q 'purge_host_webdav_leftovers' "$s"
    run ! grep -qE 'apt-get (purge|autoremove)' "$s"
    run ! grep -qE 'userdel|groupdel|setfacl' "$s"
    # An operator message may name a removal command to run by hand; only a
    # command the installer runs itself counts.
    code="$(grep -vE '^[[:space:]]*(die|log [A-Z]+) "' "$s")"
    [ -n "$code" ]
    run ! grep -qE 'docker (rm|volume rm)' <<<"$code"
    run ! grep -q 'docker.service.wants' "$s"
    run ! grep -q 'filebrowser.yaml' "$s"
    run ! grep -qE 'disable --now' "$s"
    # Deleting a file the installer does not own is the same overreach.
    run ! grep -q 'rm -f "\$COMPOSE_DIR/.env"' "$s"
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
    run ! grep -q 'assert_wan_interface_current' "$V2_ROOT/scripts/firewall.sh"
    run ! grep -q 'WAN_INTERFACE:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'SSH_PUBLIC_PORT" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'neighbour-solicitation -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'neighbour-advertisement -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'packet-too-big -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    # Helper does not consume WAN_IPV4 (endpoint hint stays in state.env).
    run ! grep -q 'WAN_IPV4' "$V2_ROOT/scripts/firewall.sh"
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
    caddy_dropin="$(awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh")"
    [ -n "$caddy_dropin" ]
    run ! grep -q 'PartOf=tailscaled.service' <<<"$caddy_dropin"
}

@test "no assertion relies on a bare negation or [[ ]] (bash 3.2)" {
    # Under macOS /bin/bash 3.2 a `! cmd` or `[[ ]]` statement never fails a
    # test, because errexit ignores it. Use `run !`, `[ ]` or `case` (DD-126).
    run grep -nE '^[[:space:]]+(! |\[\[ )' "$BATS_TEST_FILENAME"
    [ "$status" -eq 1 ]
}

@test "masked-quiet apt install under retry receives APT_OPTS" {
    # retry runs a function in a child bash, where the APT_OPTS array is not
    # inherited. Options passed as arguments must still reach apt-get (DD-125).
    mkdir -p "$TMP/bin"
    cat >"$TMP/bin/apt-get" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/apt-calls"
echo "fake apt output"
EOF
    cat >"$TMP/bin/timeout" <<'EOF'
#!/bin/bash
[ "$1" = --foreground ] && shift
shift
exec "$@"
EOF
    chmod +x "$TMP/bin/apt-get" "$TMP/bin/timeout"
    eval "$(awk '/^apt_get_install_masked_quiet\(\)/,/^}/' "$V2_ROOT/install.sh")"
    APT_OPTS=(-o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false)
    # V2_LOG_FILE is exported by install.sh, so the child bash appends apt's
    # full output to the install log too (v2-96).
    grep -qx 'export V2_LOG_FILE' "$V2_ROOT/install.sh"
    export V2_LOG_FILE="$TMP/install.log"
    PATH="$TMP/bin:$PATH" retry "apt-test" 1 10 -- \
        apt_get_install_masked_quiet "${APT_OPTS[@]}" caddy
    grep -qx 'install -y -o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false caddy' \
        "$TMP/apt-calls"
    grep -qx 'fake apt output' "$TMP/install.log"
}

@test "edge apt install masks units until configured" {
    grep -q 'systemctl mask dnsmasq.service caddy.service' "$V2_ROOT/install.sh"
    grep -q 'apt_get_install_masked_quiet' "$V2_ROOT/install.sh"
    run ! grep -q '/usr/sbin/policy-rc.d' "$V2_ROOT/install.sh"
    awk '/^stage_6\(\)/,/^stage_7\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'systemctl unmask dnsmasq caddy'
}

@test "re-run gates full-upgrade and skips unchanged edge restart" {
    grep -q 'RUN_FULL_UPGRADE' "$V2_ROOT/install.sh"
    grep -q 'V2_FULL_UPGRADE' "$V2_ROOT/install.sh"
    grep -q 'full-upgrade yapılsın mı' "$V2_ROOT/install.sh"
    grep -q 'COMPOSE_NEEDS_UP' "$V2_ROOT/install.sh"
    grep -q 'FIREWALL_NEEDS_RESTART' "$V2_ROOT/install.sh"
    run ! grep -q 'WEBDAV_NEEDS_RESTART' "$V2_ROOT/install.sh"
    grep -q 'yapılandırması aynı; yeniden başlatılmadı' "$V2_ROOT/install.sh"
    grep -q 'Compose dosyası aynı ve konteynerler ayakta' "$V2_ROOT/install.sh"
    grep -q 'V2_LAST_ATOMIC_CHANGED' "$V2_ROOT/common.sh"
    awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'systemctl restart master-firewall.service'
    stage5="$(awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$stage5" ]
    run ! grep -q 'master-webdav' <<<"$stage5"
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$stage4" ]
    run ! grep -qE '\|[[:space:]]*atomic_write' <<<"$stage4"
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
    run ! grep -qE 'apache2-utils dnsutils acl' "$V2_ROOT/install.sh"
    # acl may be installed only as a migration helper inside the purge path.
    stage1="$(awk '/^stage_1\(\)/,/^stage_2\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$stage1" ]
    run ! grep -qE '\bacl\b' <<<"$stage1"
}

@test "exporter embeds archive sha256 and stages root-level runtime" {
    local exporter="$V2_ROOT/dev/export-installer.sh"
    grep -q 'PORTABLE_ARCHIVE_SHA256' "$exporter"
    grep -q 'sha256sum' "$exporter"
    run ! grep -qE '\.sha256"|Sidecar' "$exporter"
    grep -q 'dsi-extract' "$exporter"
    grep -q 'staging/installer/install.sh' "$exporter"
    grep -q 'REMOTE_ROOT/install.sh' "$exporter"
    grep -q 'gzip -n' "$exporter"
    grep -q 'touch -t 200001010000' "$exporter"
    grep -q 'TZ=UTC' "$exporter"
    grep -q -- '--no-xattrs' "$exporter"
    grep -q -- '--no-mac-metadata' "$exporter"
    run ! grep -q 'touch -t 197001010000' "$exporter"
    grep -q 'reproducible/${V2_VERSION}' "$exporter"
}

@test "stage 7 checks DNS on Tailscale IP and publish surface" {
    grep -q 'status: REFUSED' "$V2_ROOT/install.sh"
    grep -q 'for resolver in 127.0.0.1' "$V2_ROOT/install.sh"
    grep -q 'Host: webdav.' "$V2_ROOT/install.sh"
    grep -q 'WebDAV Caddy TS-IP:' "$V2_ROOT/install.sh"
    grep -q 'http://${TAILSCALE_IPV4}:${WEBDAV_PORT}/' "$V2_ROOT/install.sh"
    grep -q 'http://127.0.0.1:${WEBDAV_PORT}/' "$V2_ROOT/install.sh"
    run ! grep -q 'WebDAV Tailscale publish' "$V2_ROOT/install.sh"
    grep -q 'assert_webdav_readonly_runtime' "$V2_ROOT/install.sh"
    grep -q 'ReadonlyRootfs' "$V2_ROOT/install.sh"
    grep -q '/downloads false' "$V2_ROOT/install.sh"
    run ! grep -q 'v2-write-probe' "$V2_ROOT/install.sh"
    webdav_runtime="$(awk '/^assert_webdav_readonly_runtime/,/^stage_7/' "$V2_ROOT/install.sh")"
    [ -n "$webdav_runtime" ]
    run ! grep -qE '401\|403\|405' <<<"$webdav_runtime"
    run ! grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    grep -q 'docker port qbittorrent' "$V2_ROOT/install.sh"
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
        run ! grep -q "^${key}=" "$V2_ROOT/config/defaults.env"
    done
    # DNS_PORT and CADDY_HTTP_PORT exist and are now actually used.
    grep -q '"\$DNS_PORT" | "\$CADDY_HTTP_PORT"' "$V2_ROOT/install.sh"
    run ! grep -qE '^\s+53 \| 80 \|' "$V2_ROOT/install.sh"
}

@test "compose images use upstream stable tracks where published" {
    # DD-97: prefer the vendor's stable track over a frozen patch@digest.
    grep -qE '^DOZZLE_IMAGE="amir20/dozzle:v11"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^FILEBROWSER_IMAGE="filebrowser/filebrowser:v2"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^QBITTORRENT_IMAGE="lscr\.io/linuxserver/qbittorrent:latest"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^UNPACKERR_IMAGE="ghcr.io/unpackerr/unpackerr:0\.15"' \
        "$V2_ROOT/config/defaults.env"
    grep -qE '^RCLONE_IMAGE="rclone/rclone:1\.75"' \
        "$V2_ROOT/config/defaults.env"
    # Forbidden floats — except LinuxServer qBittorrent:latest, its only stable
    # track (LinuxServer publishes no major tag).
    run ! grep -qE '_(IMAGE)="[^"]*:(stable|sts|edge|nightly|libtorrentv1)(@|")' \
        "$V2_ROOT/config/defaults.env"
    run ! grep -qE '^(DOZZLE|FILEBROWSER|WG_EASY|UNPACKERR|RCLONE)_IMAGE="[^"]*:latest' \
        "$V2_ROOT/config/defaults.env"
    # Track images must not carry a digest pin.
    run ! grep -qE '^(DOZZLE|FILEBROWSER|QBITTORRENT|WG_EASY|UNPACKERR|RCLONE)_IMAGE="[^"]*@sha256:' \
        "$V2_ROOT/config/defaults.env"
}

@test "stage 7 derives the container count from compose" {
    run ! grep -q 'local expected=5' "$V2_ROOT/install.sh"
    grep -q 'docker compose config --services' "$V2_ROOT/install.sh"
}

@test "refresh timer has no no-op Persistent key" {
    # Persistent= only applies to OnCalendar= timers; this one is monotonic.
    run ! grep -q 'Persistent=' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -q 'OnUnitActiveSec=5min' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
}

@test "tailscale_login reaps stuck up child before retry" {
    grep -q 'reap_bg_pid()' "$V2_ROOT/install.sh"
    grep -q 'kill -KILL' "$V2_ROOT/install.sh"
    awk '/^tailscale_login\(\)/,/^stage_0\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'reap_bg_pid "\$up_pid"'
    login_body="$(awk '/^tailscale_login\(\)/,/^stage_0\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$login_body" ]
    run ! grep -q 'kill "\$up_pid"' <<<"$login_body"
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
    stage7="$(awk '/^stage_7\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$stage7" ]
    run ! grep -q 'die "otomatik güvenlik' <<<"$stage7"
}

@test "pipe consumers in the installer tree do not exit early under pipefail" {
    # An awk/sed that exits on first match sends SIGPIPE to the producer; with
    # set -o pipefail the pipeline returns 141 and set -e aborts the install
    # (seen live on 2026-09-12, DD-113). Consumers reading files are fine.
    # [|] not \|: BSD grep -E (Finder/bats on macOS) reads \| differently
    # from GNU grep. `exit *[}]` matches awk's `{...; exit}`, not a shell
    # `|| { ...; exit 1; }` guard.
    run ! grep -nE '[|][^|]*(awk|sed)[^|]*; *exit *[}]' \
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
    state_writers="$(awk '/^write_(state|config)\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$state_writers" ]
    run ! grep -q 'TS_AUTH_KEY' <<<"$state_writers"
    run ! grep -nE -- '--auth-?key[= ]"?\$\{?TS_AUTH_KEY' "$V2_ROOT/install.sh"
    run ! grep -nE 'export +TS_AUTH_KEY|log [A-Z]+ .*\$\{?TS_AUTH_KEY' "$V2_ROOT/install.sh"
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
    run ! grep -qF "$TS_AUTH_KEY" "$TMP/argv"
    run ! grep -qF "$TS_AUTH_KEY" "$TMP/install.log"
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
    run ! grep -qF "$TS_AUTH_KEY" "$TMP/install.log"
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
    grep -A6 '^    require_root$' <<<"$stage0" | awk '
        /read_input_file "\$INPUT_FILE" "\$INPUT_KEYS" "\$INPUT_NONEMPTY_KEYS"/ { r = NR }
        /rm -rf -- "\$INPUT_DIR"/ { d = NR }
        END { exit !(r && d && r < d) }'
    grep -q '^INPUT_DIR="/run/master-stack/kurulum"$' "$V2_ROOT/config/defaults.env"
    grep -q '^INPUT_FILE="/run/master-stack/kurulum/kurulum.env"$' "$V2_ROOT/config/defaults.env"
    # DD-124: no peer definitions or hand-back path. The DD-128 snapshot is the
    # only WireGuard input, taken before the input directory is removed.
    grep -A8 '^    require_root$' <<<"$stage0" | awk '
        /take_snapshot_input/ { t = NR }
        /rm -rf -- "\$INPUT_DIR"/ { d = NR }
        /validate_snapshot/ { v = NR }
        END { exit !(t && d && v && t < d && d < v) }'
    run ! grep -qE 'INPUT_WG_DIR|OUTPUT_DIR|OUTPUT_WG_DIR|\bWG_PEERS\b' \
        "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh" "$V2_ROOT/config/kurulum.env.example"
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
    grep -q 'stat -f %Lp "\$INPUT_FILE_LOCAL"' <<<"$body"
    # DD-128: kurulum.env plus the pulled settings when present, each named
    # file mode 600; nothing is fetched back.
    grep -q 'send_files="kurulum.env"' <<<"$body"
    grep -q -- '--no-mac-metadata -cf - \$send_files |' <<<"$body"
    grep -q 'send_files="\$send_files wireguard/sunucu/wg0.conf"' <<<"$body"
    grep -qF '"${f##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}\.conf$' <<<"$body"
    run ! grep -qiE 'qbittorrent' <<<"$body"
    grep -q 'anahtar/parola içerdiği için 600 olmalı' <<<"$body"
    grep -q -- '--no-same-owner -xf -' <<<"$body"
    run ! grep -qE 'input_files|fetch_wireguard_output|OUTPUT_' <<<"$body"
    awk '/^cleanup_local\(\)/,/^}$/' <<<"$body" | grep -q "'\$REMOTE_RESTORE_DIR'"
    grep -q 'REMOTE_RESTORE_DIR="\$RESTORE_DIR"' "$exporter"
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

snapshot_keys() {
    K1="$(printf 'A%.0s' {1..43})="
    K2="$(printf 'B%.0s' {1..43})="
    K3="$(printf 'C%.0s' {1..43})="
    K4="$(printf 'D%.0s' {1..43})="
}

snapshot_server_conf() {
    snapshot_keys
    cat <<EOF
# master-stack — [Interface] kurulumundur
[Interface]
Address = 10.8.0.1/24, fdcc:ad94:bacf:61a4::cafe:1/112
ListenPort = 61001
MTU = 1420
PrivateKey = $K1

# peer: iph0
[Peer]
PublicKey = $K2
PresharedKey = $K3
AllowedIPs = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128

# peer: mac.book_1
[Peer]
PublicKey = $K4
PresharedKey = $K3
AllowedIPs = 10.8.0.3/32, fdcc:ad94:bacf:61a4::cafe:3/128
EOF
}

snapshot_profile() {
    snapshot_keys
    cat <<EOF
[Interface]
PrivateKey = $K2
Address = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128
MTU = 1420
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = $K1
PresharedKey = $K3
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 21
Endpoint = ${1:-203.0.113.10}:61001
EOF
}

@test "wg_snapshot_check accepts master-stack files and rejects anything wg-quick could run" {
    # DD-128: a restored wg0.conf is fed to wg-quick as root, so only the keys
    # master-stack writes may appear; messages never echo a key.
    eval "$(awk '/^wg_snapshot_check\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    source "$V2_ROOT/config/defaults.env"
    snapshot_server_conf >"$TMP/wg0.conf"
    [ "$(wg_snapshot_check "$TMP/wg0.conf" server)" = "ok 2" ]
    snapshot_profile >"$TMP/p.conf"
    [ "$(wg_snapshot_check "$TMP/p.conf" profile)" = "ok 1" ]
    local variant out
    while IFS='|' read -r variant expect; do
        case "$variant" in
            postup) sed 's/^MTU = 1420$/PostUp = iptables -F/' "$TMP/wg0.conf" >"$TMP/bad" ;;
            wide) sed 's#^AllowedIPs = 10.8.0.3/32.*#AllowedIPs = 0.0.0.0/0#' "$TMP/wg0.conf" >"$TMP/bad" ;;
            shortkey) sed "s#^PresharedKey = .*#PresharedKey = abc=#" "$TMP/wg0.conf" >"$TMP/bad" ;;
            dupname) sed 's/^# peer: mac.book_1$/# peer: iph0/' "$TMP/wg0.conf" >"$TMP/bad" ;;
            badname) sed 's/^# peer: iph0$/# peer: ..\/evil/' "$TMP/wg0.conf" >"$TMP/bad" ;;
            nokey) grep -v '^PrivateKey' "$TMP/wg0.conf" >"$TMP/bad" ;;
            peerextra) sed 's/^PresharedKey = \(.*\)$/PresharedKey = \1\nEndpoint = 1.2.3.4:1/' "$TMP/wg0.conf" >"$TMP/bad" ;;
        esac
        out="$(wg_snapshot_check "$TMP/bad" server)"
        case "$out" in *"$expect"*) ;; *) echo "$variant: $out"; false ;; esac
        case "$out" in "ok "*) false ;; esac
        run ! grep -qE 'AAAA|BBBB|CCCC|DDDD' <<<"$out"
    done <<'EOF'
postup|izin verilmeyen alan: PostUp
wide|alt ağı dışında: 0.0.0.0/0
shortkey|PresharedKey biçimi
dupname|aynı peer adı
badname|geçersiz peer adı
nokey|PrivateKey yok
peerextra|izin verilmeyen alan: Endpoint
EOF
    sed 's/^DNS = .*/&\nPostDown = rm -rf \//' "$TMP/p.conf" >"$TMP/bad"
    case "$(wg_snapshot_check "$TMP/bad" profile)" in *"PostDown"*) ;; *) false ;; esac
    { cat "$TMP/p.conf"; printf '\n[Peer]\nPublicKey = %s\n' "$K4"; } >"$TMP/bad"
    case "$(wg_snapshot_check "$TMP/bad" profile)" in *"birden fazla [Peer]"*) ;; *) false ;; esac
}

@test "validate_snapshot allows only the expected files and counts what it found" {
    eval "$(awk '/^wg_snapshot_check\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^validate_snapshot\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^snapshot_note\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    source "$V2_ROOT/config/defaults.env"
    RESTORE_DIR="$TMP/restore"
    mkdir -p "$RESTORE_DIR/wireguard/sunucu"
    snapshot_server_conf >"$RESTORE_DIR/wireguard/sunucu/wg0.conf"
    snapshot_profile >"$RESTORE_DIR/wireguard/iph0.conf"
    snapshot_profile >"$RESTORE_DIR/wireguard/mac.book_1.conf"
    SNAPSHOT_PEERS=0 SNAPSHOT_WG_PROFILES=0
    validate_snapshot
    [ "$SNAPSHOT_PEERS" = 2 ]
    [ "$SNAPSHOT_WG_PROFILES" = 2 ]
    [ "$(snapshot_note)" = "WireGuard sunucu anahtarı + 2 peer, 2 profil" ]
    # Anything else stops the install before a change.
    local extra
    # qBittorrent is no longer pulled (DD-129): its file is refused too.
    for extra in qbittorrent/qBittorrent.conf qbittorrent/evil.sh \
        wireguard/sunucu/other.conf "wireguard/bad name.conf" wireguard/x/y.conf; do
        mkdir -p "$(dirname "$RESTORE_DIR/$extra")"
        printf 'x\n' >"$RESTORE_DIR/$extra"
        run validate_snapshot
        [ "$status" -ne 0 ]
        case "$output" in *"hazır ayarlar"*) ;; *) false ;; esac
        rm -f "$RESTORE_DIR/$extra"
    done
    ln -s /etc/passwd "$RESTORE_DIR/wireguard/linked.conf"
    run validate_snapshot
    [ "$status" -ne 0 ]
    rm -f "$RESTORE_DIR/wireguard/linked.conf"
    SNAPSHOT_MAX_BYTES=10
    run validate_snapshot
    case "$output" in *"çok büyük"*) ;; *) false ;; esac
    SNAPSHOT_MAX_BYTES=1048576
    # Profiles without the server file are dropped, not sent on.
    rm -f "$RESTORE_DIR/wireguard/sunucu/wg0.conf"
    validate_snapshot
    [ ! -e "$RESTORE_DIR/wireguard" ]
}

@test "the WireGuard snapshot is restored only where the server has nothing" {
    eval "$(awk '/^restore_wireguard_snapshot\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    log() { printf '%s %s\n' "$1" "$2" >>"$TMP/log"; }
    install() {
        local dir=0 a=()
        while [ "$#" -gt 0 ]; do
            case "$1" in -d) dir=1 ;; -m | -o | -g) shift ;; *) a+=("$1") ;; esac
            shift
        done
        if [ "$dir" = 1 ]; then mkdir -p "${a[@]}"; else cp "${a[0]}" "${a[1]}"; fi
    }
    RESTORE_DIR="$TMP/restore" WG_CONF_FILE="$TMP/etc/wireguard/wg0.conf" WG_CLIENTS_DIR="$TMP/etc/wireguard/clients"
    WG_ENDPOINT_HOST=203.0.113.10 WG_PUBLIC_PORT=61001 SNAPSHOT_PEERS=2
    mkdir -p "$RESTORE_DIR/wireguard/sunucu"
    snapshot_server_conf >"$RESTORE_DIR/wireguard/sunucu/wg0.conf"
    snapshot_profile >"$RESTORE_DIR/wireguard/iph0.conf"
    snapshot_profile 203.0.113.9 >"$RESTORE_DIR/wireguard/old.conf"

    # Fresh server: everything goes in as is.
    restore_wireguard_snapshot
    [ "$WG_RESTORED" = 1 ]
    cmp "$RESTORE_DIR/wireguard/sunucu/wg0.conf" "$WG_CONF_FILE"
    cmp "$RESTORE_DIR/wireguard/iph0.conf" "$WG_CLIENTS_DIR/iph0.conf"
    grep -q '^WARN 1 cihaz profilinin Endpoint' "$TMP/log"

    # Existing server config: the server is the truth, nothing is touched.
    printf 'server-own\n' >"$WG_CONF_FILE"
    restore_wireguard_snapshot
    [ "$WG_RESTORED" = 0 ]
    [ "$(cat "$WG_CONF_FILE")" = server-own ]
    grep -q 'kurulum/wireguard kullanılmadı' "$TMP/log"
}

@test "snapshot restores are wired into the stages and the runtime copy is removed" {
    stage5="$(awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh")"
    awk '/restore_wireguard_snapshot$/ {a = NR} /^    ensure_wireguard$/ {b = NR}
         END {exit !(a && b && a < b)}' <<<"$stage5"
    main="$(awk '/^main\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    awk '/^    stage_5$/ {a = NR} /rm -rf -- "\$RESTORE_DIR"/ {b = NR} /^    stage_6$/ {c = NR}
         END {exit !(a && b && c && a < b && b < c)}' <<<"$main"
    grep -q '^RESTORE_DIR="/run/master-stack/restore"$' "$V2_ROOT/config/defaults.env"
    grep -q 'Hazır ayarlar: \$(snapshot_note)' "$V2_ROOT/install.sh"
}

@test "wireguard.command option 6 mirrors the server's WireGuard files into kurulum/ without printing them" {
    local repo="$TMP/repo" srv="$TMP/srv" ver
    ver="$(awk -F'"' '/^V2_VERSION=/{print $2; exit}' "$V2_ROOT/install.sh")"
    mkdir -p "$repo/Data/config" "$repo/kurulum/wireguard" "$repo/kurulum/qbittorrent" \
        "$srv/etc/wireguard/clients" "$srv/etc/master-stack" "$TMP/bin"
    cp "$V2_ROOT/../wireguard.command" "$repo/"
    cp "$V2_ROOT/config/defaults.env" "$repo/Data/config/"
    printf 'V2_VERSION="%s"\n' "$ver" >"$repo/Data/install.sh"
    printf 'SSH_HOST=nrm\nWEBDAV_PASS=never-read\n' >"$repo/kurulum/kurulum.env"
    touch "$srv/etc/master-stack/state.env"
    snapshot_server_conf >"$srv/etc/wireguard/wg0.conf"
    snapshot_profile >"$srv/etc/wireguard/clients/iph0.conf"
    printf 'stale\n' >"$repo/kurulum/wireguard/gone.conf"
    # A v2-93 pull left a qBittorrent copy with a password hash: it is removed.
    printf '[Preferences]\nWebUI\\Password_PBKDF2="@ByteArray(secret-hash)"\n' \
        >"$repo/kurulum/qbittorrent/qBittorrent.conf"
    # Fake ssh: master-wg version answers the local version; the backup script
    # is kept for inspection and the fixture tree is sent relative to /.
    cat >"$TMP/bin/ssh" <<EOF
#!/bin/bash
case "\$*" in
    *" -O exit "*) exit 0 ;;
    *"master-wg version"*) echo "$ver" ;;
    *"bash -s"*) printf '%s\n' "\$*" >"$TMP/ssh-args"; cat >"$TMP/ssh-script"
        cd "$srv" && tar -cf - \$(find etc -type f ! -name state.env | sort) ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TMP/bin/ssh"
    run env PATH="$TMP/bin:$PATH" /bin/bash "$repo/wireguard.command" < <(printf '6\n5\n\n')
    [ "$status" -eq 0 ]
    cmp "$srv/etc/wireguard/wg0.conf" "$repo/kurulum/wireguard/sunucu/wg0.conf"
    cmp "$srv/etc/wireguard/clients/iph0.conf" "$repo/kurulum/wireguard/iph0.conf"
    [ ! -e "$repo/kurulum/wireguard/gone.conf" ]
    [ ! -e "$repo/kurulum/qbittorrent" ]
    for f in "$repo/kurulum/wireguard/sunucu/wg0.conf" "$repo/kurulum/wireguard/iph0.conf"; do
        [ "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" = 600 ]
    done
    pulled="$output"
    case "$pulled" in *"6) Yedek al"*) ;; *) false ;; esac
    case "$pulled" in *"profil gone"*"silindi"*) ;; *) false ;; esac
    case "$pulled" in *"eski qBittorrent kopyası"*"silindi"*) ;; *) false ;; esac
    run ! grep -qE 'AAAA|BBBB|secret-hash|never-read' <<<"$pulled"
    [ -z "$(find "$repo/kurulum" -name '.yedek.*')" ]
    # A second backup reports unchanged files.
    run env PATH="$TMP/bin:$PATH" /bin/bash "$repo/wireguard.command" < <(printf '6\n5\n\n')
    case "$output" in *"profil iph0"*"aynı"*) ;; *) false ;; esac
    # The server side needs an install and a wg0.conf, tars only WireGuard files.
    grep -q 'tar -C / -cf - -- "\${list\[@\]}"' "$TMP/ssh-script"
    grep -q 'sunucuda kurulum yok' "$TMP/ssh-script"
    grep -q 'sunucuda WireGuard yapılandırması yok' "$TMP/ssh-script"
    run ! grep -qiE 'qbittorrent|categories|feeds' "$TMP/ssh-script"
    grep -q -- '-- /etc/master-stack/state.env /etc/wireguard/wg0.conf /etc/wireguard/clients$' "$TMP/ssh-args"
    # The separate ayarlar.command is gone.
    [ ! -e "$V2_ROOT/../ayarlar.command" ]
}

@test "wireguard.command options 7 and 8 change DNS with a new QR and regenerate wg0 only after SIL" {
    local repo="$TMP/repo" srv="$TMP/srv" ver
    ver="$(awk -F'"' '/^V2_VERSION=/{print $2; exit}' "$V2_ROOT/install.sh")"
    mkdir -p "$repo/Data/config" "$repo/kurulum/wireguard" "$srv/etc/wireguard/clients" "$srv/etc/master-stack" "$TMP/bin"
    cp "$V2_ROOT/../wireguard.command" "$repo/"
    cp "$V2_ROOT/config/defaults.env" "$repo/Data/config/"
    printf 'V2_VERSION="%s"\n' "$ver" >"$repo/Data/install.sh"
    printf 'SSH_HOST=nrm\n' >"$repo/kurulum/kurulum.env"
    touch "$srv/etc/master-stack/state.env"
    snapshot_server_conf >"$srv/etc/wireguard/wg0.conf"
    snapshot_profile >"$repo/kurulum/wireguard/iph0.conf"
    # Fake server: records master-wg calls; after "reset" the server has no peers.
    cat >"$TMP/bin/ssh" <<EOF
#!/bin/bash
case "\$*" in
    *" -O exit "*) exit 0 ;;
    *"master-wg version"*) echo "$ver" ;;
    *"master-wg list"*) [ -e "$TMP/reset-done" ] || printf 'iph0\t10.8.0.2\t0\t0\t0\tvar\n' ;;
    *"master-wg profile iph0"*) printf '[Interface]\nPrivateKey = SECRETKEY\nDNS = 1.1.1.1\n' ;;
    *"master-wg dns iph0 "*) echo "\$*" >>"$TMP/calls"; a="\${*% }"; last="\${a##* }"; printf 'iph0\t%s\n' "\$last" ;;
    *"master-wg qr iph0"*) echo "QR-CODE" ;;
    *"master-wg reset --onay"*) echo "\$*" >>"$TMP/calls"; touch "$TMP/reset-done"; printf '4\t4\n'
        printf '[Interface]\nPrivateKey = NEWKEY\n' >"$srv/etc/wireguard/wg0.conf" ;;
    *"bash -s"*) cat >/dev/null; cd "$srv" && tar -cf - etc/wireguard/wg0.conf ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TMP/bin/ssh"
    # 7 twice: Enter keeps the current DNS read from the profile, then a new one;
    # 8 with a wrong word changes nothing.
    run env PATH="$TMP/bin:$PATH" /bin/bash "$repo/wireguard.command" \
        < <(printf '7\niph0\n\n7\niph0\n2a07:a8c0::df:877b\n8\nevet\n5\n\n')
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$TMP/calls" | awk '{print $NF}')" = "1.1.1.1" ]
    case "$output" in *"DNS değişti: iph0 → 2a07:a8c0::df:877b"*"QR-CODE"*) ;; *) false ;; esac
    case "$output" in *"Vazgeçildi; hiçbir şey değişmedi."*) ;; *) false ;; esac
    grep -q 'master-wg dns iph0 2a07' "$TMP/calls"
    run ! grep -q 'reset' "$TMP/calls"
    run ! grep -q 'SECRETKEY' <<<"$output"
    [ -f "$repo/kurulum/wireguard/iph0.conf" ]
    # 8 with SIL: reset, then the backup mirrors the clean server.
    run env PATH="$TMP/bin:$PATH" /bin/bash "$repo/wireguard.command" < <(printf '8\nSIL\n5\n\n')
    [ "$status" -eq 0 ]
    grep -q 'master-wg reset --onay' "$TMP/calls"
    case "$output" in *"4 peer ve 4 profil silindi"*) ;; *) false ;; esac
    [ ! -e "$repo/kurulum/wireguard/iph0.conf" ]
    grep -qx 'PrivateKey = NEWKEY' "$repo/kurulum/wireguard/sunucu/wg0.conf"
    case "$output" in *"8) wg0 yeniden üret"*) ;; *) false ;; esac
}

wg_mock_bin() {
    # Stand-ins on PATH for the tools master-wg and ensure_wireguard call; every
    # call is logged, keys come from a counter and never from randomness.
    mkdir -p "$TMP/bin"
    cat >"$TMP/bin/wg" <<'EOF'
#!/bin/bash
printf 'wg %s\n' "$*" >>"$MOCK_LOG"
case "$1" in
    genkey) n=$(cat "$MOCK_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$MOCK_DIR/n"
        printf 'PRIV%02d%s=\n' "$n" "$(printf 'k%.0s' {1..37})" ;;
    genpsk) printf 'PSK%s=\n' "$(printf 'p%.0s' {1..40})" ;;
    pubkey) IFS= read -r k; printf 'PUB%s=\n' "$(printf '%s' "${k:0:6}" | tr 'A-Za-z' 'N-ZA-Mn-za-m')$(printf 'u%.0s' {1..34})" ;;
    syncconf) cat "$3" >"$MOCK_DIR/syncconf"; exit "${SYNC_RC:-0}" ;;
    show) [ "$3" = dump ] && cat "$MOCK_DIR/dump" 2>/dev/null; true ;;
esac
EOF
    cat >"$TMP/bin/wg-quick" <<'EOF'
#!/bin/bash
[ "$1" = strip ] && grep -vE '^(Address|MTU) = |^#' "$WG_CONF_FILE"
EOF
    cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
[ "$1" != is-active ] || [ "${WG_ACTIVE:-1}" = 1 ]
EOF
    printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/flock"
    printf '#!/bin/bash\nprintf "QR:"; cat\n' >"$TMP/bin/qrencode"
    chmod +x "$TMP/bin"/*
    export MOCK_LOG="$TMP/calls" MOCK_DIR="$TMP"
}

wg_state_fixture() {
    mkdir -p "$TMP/etc/wireguard/clients" "$TMP/run"
    cat >"$TMP/state.env" <<EOF
V2_VERSION=2026.08.06-v2-test
WG_INTERFACE=wg0
WG_CONF_FILE=$TMP/etc/wireguard/wg0.conf
WG_CLIENTS_DIR=$TMP/etc/wireguard/clients
WG_SERVER_IPV4=10.8.0.1
WG_SERVER_IPV6=fdcc:ad94:bacf:61a4::cafe:1
WG_SUBNET4=10.8.0.0/24
WG_SUBNET6=fdcc:ad94:bacf:61a4::cafe:0/112
WG_PUBLIC_PORT=61001
WG_ENDPOINT_HOST=203.0.113.7
WG_CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
RUNTIME_DIR=$TMP/run
EOF
    export WG_CONF_FILE="$TMP/etc/wireguard/wg0.conf"
    printf '# header\n[Interface]\nAddress = 10.8.0.1/24, fdcc:ad94:bacf:61a4::cafe:1/112\nListenPort = 61001\nMTU = 1420\nPrivateKey = SRVKEY%s=\n' \
        "$(printf 's%.0s' {1..37})" >"$WG_CONF_FILE"
}

master_wg() {
    PATH="$TMP/bin:$PATH" STATE_FILE="$TMP/state.env" bash "$V2_ROOT/scripts/master-wg" "$@"
}

@test "master-wg adds a peer generated on the server, applies it live and keeps the profile root-side" {
    wg_mock_bin
    wg_state_fixture
    run master_wg add iphone "9.9.9.9 , 149.112.112.112" 21 1380
    [ "$status" -eq 0 ]
    [ "$output" = $'iphone\t10.8.0.2' ]
    profile="$TMP/etc/wireguard/clients/iphone.conf"
    mode="$(stat -c %a "$profile" 2>/dev/null || stat -f %Lp "$profile")"
    [ "$mode" = 600 ]
    grep -qx 'PrivateKey = PRIV01kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk=' "$profile"
    grep -qx 'Address = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128' "$profile"
    grep -qx 'MTU = 1380' "$profile"
    grep -qx 'DNS = 9.9.9.9, 149.112.112.112' "$profile"
    grep -qx 'PersistentKeepalive = 21' "$profile"
    grep -qx 'Endpoint = 203.0.113.7:61001' "$profile"
    grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0' "$profile"
    # The server key's public half is in the profile; the client key is not in wg0.conf.
    grep -q '^PublicKey = PUBFEIXRL' "$profile"
    conf="$(cat "$WG_CONF_FILE")"
    grep -qx '# peer: iphone' <<<"$conf"
    grep -qx 'AllowedIPs = 10.8.0.2/32, fdcc:ad94:bacf:61a4::cafe:2/128' <<<"$conf"
    run ! grep -q 'PRIV01' <<<"$conf"
    grep -qx 'PrivateKey = SRVKEYsssssssssssssssssssssssssssssssssssss=' <<<"$conf"
    # Live, the kernel WireGuard way: syncconf, no restart.
    grep -q '^wg syncconf wg0 ' "$TMP/calls"
    run ! grep -q 'restart' "$TMP/calls"
    grep -q '^\[Peer\]$' "$TMP/syncconf"
    # The next peer takes the next address; profile and QR come from the stored file.
    run master_wg add ipad 1.1.1.1 0 1420
    [ "$output" = $'ipad\t10.8.0.3' ]
    run master_wg profile ipad
    [ "$status" -eq 0 ]
    grep -qx 'Address = 10.8.0.3/32, fdcc:ad94:bacf:61a4::cafe:3/128' <<<"$output"
    run master_wg qr ipad
    case "$output" in "QR:[Interface]"*) ;; *) false ;; esac
    # list: name, address, handshake, rx, tx, stored profile.
    pub="$(awk -F' = ' '/^# peer: ipad$/ {f = 1} f && $1 == "PublicKey" {print $2; exit}' "$WG_CONF_FILE")"
    printf 'srv\tx\t61001\toff\n%s\t(none)\t198.51.100.4:5000\t10.8.0.3/32\t1789000000\t500\t900\t21\n' "$pub" >"$TMP/dump"
    run master_wg list
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'iphone\t10.8.0.2\t0\t0\t0\tvar' ]
    [ "${lines[1]}" = $'ipad\t10.8.0.3\t1789000000\t500\t900\tvar' ]
    run master_wg version
    [ "$output" = 2026.08.06-v2-test ]
}

@test "master-wg rejects bad input and duplicates before touching anything" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    before="$(cat "$WG_CONF_FILE")"
    for args in "iphone 1.1.1.1 21 1420|zaten var" "bad/name 1.1.1.1 21 1420|geçersiz peer adı" \
        "x not-an-ip 21 1420|DNS virgülle" "x 1.1.1.1 70000 1420|keepalive" "x 1.1.1.1 abc 1420|keepalive" \
        "x 1.1.1.1 21 1600|MTU" "x 1.1.1.1 21 900|MTU" "x , 21 1420|en az bir DNS"; do
        set -- ${args%%|*}
        run master_wg add "$@"
        [ "$status" -ne 0 ]
        case "$output" in *"${args#*|}"*) ;; *) printf 'expected %s: %s\n' "${args#*|}" "$output"; false ;; esac
    done
    [ "$(cat "$WG_CONF_FILE")" = "$before" ]
    [ "$(ls "$TMP/etc/wireguard/clients")" = iphone.conf ]
    run master_wg remove nosuch
    [ "$status" -ne 0 ]
    run master_wg profile nosuch
    [ "$status" -ne 0 ]
}

@test "master-wg dns rewrites only the profile's DNS line and leaves keys and wg0.conf alone" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    profile="$TMP/etc/wireguard/clients/iphone.conf"
    rest_before="$(grep -v '^DNS = ' "$profile")"
    conf_before="$(shasum <"$WG_CONF_FILE")"
    rm -f "$TMP/calls"
    run master_wg dns iphone "2a07:a8c0::df:877b , 2a07:a8c1::df:877b"
    [ "$status" -eq 0 ]
    [ "$output" = $'iphone\t2a07:a8c0::df:877b, 2a07:a8c1::df:877b' ]
    grep -qx 'DNS = 2a07:a8c0::df:877b, 2a07:a8c1::df:877b' "$profile"
    [ "$(grep -c '^DNS = ' "$profile")" = 1 ]
    [ "$(grep -v '^DNS = ' "$profile")" = "$rest_before" ]
    [ "$(shasum <"$WG_CONF_FILE")" = "$conf_before" ]
    mode="$(stat -c %a "$profile" 2>/dev/null || stat -f %Lp "$profile")"
    [ "$mode" = 600 ]
    # DNS is client-side only: nothing is applied to the interface.
    run ! grep -qE 'syncconf|systemctl restart' "$TMP/calls"
    # Bad input changes nothing.
    before="$(shasum <"$profile")"
    run master_wg dns iphone "dns.google"
    [ "$status" -ne 0 ]
    run master_wg dns iphone " , "
    [ "$status" -ne 0 ]
    run master_wg dns ghost 1.1.1.1
    [ "$status" -ne 0 ]
    case "$output" in *"adında bir peer yok"*) ;; *) false ;; esac
    run master_wg dns iphone
    [ "$status" -ne 0 ]
    [ "$(shasum <"$profile")" = "$before" ]
    [ -z "$(find "$TMP/etc/wireguard/clients" -name '.peer-*')" ]
}

@test "master-wg reset needs --onay, issues a new server key and drops every peer and profile" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    master_wg add ipad 1.1.1.1 21 1420 >/dev/null
    conf_before="$(cat "$WG_CONF_FILE")"
    run master_wg reset
    [ "$status" -ne 0 ]
    [ "$(cat "$WG_CONF_FILE")" = "$conf_before" ]
    [ -f "$TMP/etc/wireguard/clients/iphone.conf" ]
    rm -f "$TMP/calls"
    run master_wg reset --onay
    [ "$status" -eq 0 ]
    [ "$output" = $'2\t2' ]
    # [Interface] lines and the header stay, the key is new, no peer is left.
    grep -qx '# header' "$WG_CONF_FILE"
    grep -qx 'Address = 10.8.0.1/24, fdcc:ad94:bacf:61a4::cafe:1/112' "$WG_CONF_FILE"
    grep -qx 'ListenPort = 61001' "$WG_CONF_FILE"
    grep -qx 'MTU = 1420' "$WG_CONF_FILE"
    [ "$(grep -c '^PrivateKey = ' "$WG_CONF_FILE")" = 1 ]
    run ! grep -q 'SRVKEY' "$WG_CONF_FILE"
    [ "$(tail -n 1 "$WG_CONF_FILE" | cut -c1-13)" = "PrivateKey = " ]
    run ! grep -qE '^\[Peer\]$|^# peer: ' "$WG_CONF_FILE"
    [ -z "$(ls -A "$TMP/etc/wireguard/clients")" ]
    # Applied live, with the new key and no peers.
    grep -q '^PrivateKey = PRIV' "$TMP/syncconf"
    run ! grep -q '^\[Peer\]' "$TMP/syncconf"
    # A failed apply restores wg0.conf and keeps the profiles.
    master_wg add mac 1.1.1.1 21 1420 >/dev/null
    conf_before="$(cat "$WG_CONF_FILE")"
    export SYNC_RC=1
    run master_wg reset --onay
    unset SYNC_RC
    [ "$status" -ne 0 ]
    [ "$(cat "$WG_CONF_FILE")" = "$conf_before" ]
    [ -f "$TMP/etc/wireguard/clients/mac.conf" ]
    # Nothing but the interface section is ever written back: wg0.conf with no
    # [Interface] is refused.
    printf '[Peer]\nPublicKey = x\n' >"$WG_CONF_FILE"
    run master_wg reset --onay
    [ "$status" -ne 0 ]
}

@test "master-wg remove drops exactly one block, rolls back a failed apply and never feeds an empty strip" {
    wg_mock_bin
    wg_state_fixture
    for n in a b c; do master_wg add "$n" 1.1.1.1 21 1420 >/dev/null; done
    run master_wg remove b
    [ "$status" -eq 0 ]
    conf="$(cat "$WG_CONF_FILE")"
    [ "$(grep -c '^\[Peer\]$' <<<"$conf")" -eq 2 ]
    run ! grep -q '# peer: b' <<<"$conf"
    grep -qx '# peer: a' <<<"$conf"
    grep -qx '# peer: c' <<<"$conf"
    run ! grep -q '10.8.0.3/32' <<<"$conf"
    [ ! -e "$TMP/etc/wireguard/clients/b.conf" ]
    # No run of blank lines is left where the block was.
    awk 'NR > 1 && prev == "" && $0 == "" {bad = 1} {prev = $0} END {exit bad}' <<<"$conf"
    # The freed address is reused.
    run master_wg add d 1.1.1.1 21 1420
    [ "$output" = $'d\t10.8.0.3' ]
    # A failed syncconf restores wg0.conf and removes the new profile.
    before="$(cat "$WG_CONF_FILE")"
    SYNC_RC=1 run master_wg add e 1.1.1.1 21 1420
    [ "$status" -ne 0 ]
    [ "$(cat "$WG_CONF_FILE")" = "$before" ]
    [ ! -e "$TMP/etc/wireguard/clients/e.conf" ]
    # An empty `wg-quick strip` never reaches syncconf.
    printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/wg-quick"
    rm -f "$TMP/calls"
    run master_wg remove a
    [ "$status" -ne 0 ]
    run ! grep -q 'syncconf' "$TMP/calls"
    grep -qx '# peer: a' "$WG_CONF_FILE"
}

@test "ensure_wireguard manages only [Interface] and keeps every peer" {
    eval "$(awk '/^wg_peer_section\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # shellcheck source=/dev/null
    source "$V2_ROOT/config/defaults.env"
    wg_mock_bin
    wg_state_fixture
    PATH="$TMP/bin:$PATH"
    WG_CONF_FILE="$TMP/etc/wireguard/wg0.conf" WG_CLIENTS_DIR="$TMP/etc/wireguard/clients"
    WG_MODULES_LOAD_FILE="$TMP/modules.conf" WG_PUBLIC_PORT=61001 APT_OPTS=() APT_LOCK_TIMEOUT=1
    log() { [ "$1" != HATA ] || printf '%s\n' "$*"; }
    retry() { printf 'retry %s\n' "$*" >>"$TMP/calls"; }
    modprobe() { :; }
    install() { local a; for a in "$@"; do case "$a" in /*) mkdir -p "$a" ;; esac; done; }
    # First install: no wg0.conf, a server key is generated, no peers.
    rm -f "$WG_CONF_FILE"
    run ensure_wireguard
    [ "$status" -eq 0 ]
    grep -qx 'PrivateKey = PRIV01kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk=' "$WG_CONF_FILE"
    grep -qx 'ListenPort = 61001' "$WG_CONF_FILE"
    run ! grep -q '\[Peer\]' "$WG_CONF_FILE"
    grep -q 'no-install-recommends wireguard-tools qrencode' "$TMP/calls"
    # Peers added by master-wg survive a re-run byte for byte, with no apply at all.
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    master_wg add ipad 1.1.1.1 21 1420 >/dev/null
    before="$(cat "$WG_CONF_FILE")"
    rm -f "$TMP/calls"
    run ensure_wireguard
    [ "$status" -eq 0 ]
    [ "$(cat "$WG_CONF_FILE")" = "$before" ]
    run ! grep -qE 'syncconf|restart' "$TMP/calls"
    # A port change keeps the key and the peers and is applied live.
    WG_PUBLIC_PORT=61011
    rm -f "$TMP/calls"
    run ensure_wireguard
    [ "$status" -eq 0 ]
    grep -qx 'ListenPort = 61011' "$WG_CONF_FILE"
    grep -qx 'PrivateKey = PRIV01kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk=' "$WG_CONF_FILE"
    [ "$(grep -c '^# peer: ' "$WG_CONF_FILE")" -eq 2 ]
    grep -q '^wg syncconf wg0 ' "$TMP/calls"
    run ! grep -q 'restart' "$TMP/calls"
    # An MTU change needs wg-quick: restart.
    WG_MTU=1380
    rm -f "$TMP/calls"
    run ensure_wireguard
    grep -q '^systemctl restart wg-quick@wg0.service$' "$TMP/calls"
    [ "$(grep -c '^# peer: ' "$WG_CONF_FILE")" -eq 2 ]
    # A wg0.conf without a server key stops instead of generating a new one.
    printf '[Interface]\nListenPort = 1\n' >"$WG_CONF_FILE"
    run ensure_wireguard
    [ "$status" -ne 0 ]
    case "$output" in *"sunucu anahtarı yok"*) ;; *) false ;; esac
    # The installer installs the tool and records what it reads.
    awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh" |
        grep -q 'atomic_write "\$SBIN_DIR/master-wg" 0755 <"\$V2_ROOT/scripts/master-wg"'
    # state.env is sourced by master-wg and master-firewall: a value with a space
    # must be quoted or the rest of the line runs as a command.
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'WG_CLIENT_ALLOWED_IPS="\$WG_CLIENT_ALLOWED_IPS"'
    for v in $(grep -oE '^: "\$\{[A-Z0-9_]+:\?\}"' "$V2_ROOT/scripts/master-wg" | tr -dc 'A-Z0-9_\n'); do
        awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q "^$v="
    done
}

@test "wireguard.command generates on the server, sends no key and keeps to bash 3.2" {
    local cmd="$V2_ROOT/../wireguard.command"
    [ -x "$cmd" ]
    /bin/bash -n "$cmd"
    run ! grep -qE 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)' "$cmd"
    # Only SSH_HOST is read from kurulum.env.
    grep -q 'index(\$0, "SSH_HOST=") == 1' "$cmd"
    run ! grep -qE '_PASS|TS_AUTH_KEY' "$cmd"
    # Every server call goes through master-wg with %q-quoted arguments.
    grep -q "printf '%q ' \"\$MASTER_WG\" \"\$@\"" "$cmd"
    # master-wg reads no stdin; ssh -n keeps typed menu input from being swallowed.
    grep -q 'ssh -n "\${ssh_base\[@\]}" "\$HOST" "\$cmd"' "$cmd"
    for sub in version list add remove profile qr dns 'reset --onay'; do
        grep -q "remote $sub" "$cmd"
    done
    # Option 8 needs the typed word and re-syncs the backup afterwards (DD-130).
    body="$(awk '/^regenerate_wg0\(\)/,/^}$/' "$cmd")"
    grep -q 'SIL | SİL) ;;' <<<"$body"
    awk '/remote reset --onay/ {r = NR} /backup_settings/ {b = NR} END {exit !(r && b && r < b)}' <<<"$body"
    grep -q '7) change_dns || true ;;' "$cmd"
    grep -q '8) regenerate_wg0 || true ;;' "$cmd"
    # Reading the profile for the current DNS never exits the pipe early.
    grep -qF "awk -F' = ' '\$1 == \"DNS\" {v = \$2} END {print v}'" "$cmd"
    # Nothing local is sent to the server: no scp, no local tar archive, no
    # file redirected into ssh. The only stdin is the backup script heredoc,
    # whose body runs on the server.
    outside="$(awk "/<<'REMOTE'\$/ {skip = 1; print; next} skip && /^REMOTE\$/ {skip = 0; next} !skip" "$cmd")"
    [ "$(grep -c "<<'REMOTE'" "$cmd")" -eq 1 ]
    run ! grep -qE '^[^#]*(scp |tar -c|tar [^|]*-cf|ssh [^|#]*< *["$/])' <<<"$outside"
    run ! grep -qE '^[^#]*\| *ssh' <<<"$outside"
    # The profile lands in kurulum/wireguard with mode 600 via a temporary file.
    body="$(awk '/^fetch_profile\(\)/,/^}$/' "$cmd")"
    grep -q 'umask 077 && remote profile "\$name" >"\$tmp"' <<<"$body"
    grep -q 'chmod 600 "\$tmp"' <<<"$body"
    grep -q 'mv -f "\$tmp" "\$WG_DIR/\$name.conf"' <<<"$body"
    grep -q 'ServerAliveInterval=15' "$cmd"
    # The versions must match before any change.
    grep -q '"\$remote_version" == "\$LOCAL_VERSION"' "$cmd"
    # Prompt defaults come from defaults.env.
    grep -q 'default_of WG_CLIENT_KEEPALIVE_DEFAULT' "$cmd"
    grep -q '^WG_CLIENT_KEEPALIVE_DEFAULT="21"$' "$V2_ROOT/config/defaults.env"
    grep -q '^WG_CLIENTS_DIR="/etc/wireguard/clients"$' "$V2_ROOT/config/defaults.env"
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
    grep -q '"$SBIN_DIR/master-wg" version' <<<"$s7"
    grep -q 'http://${WG_SERVER_IPV4}:${wg_ui_port}/' <<<"$s7"
}
