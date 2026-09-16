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
    [ -z "${PANEL_PID:-}" ] || kill "$PANEL_PID" 2>/dev/null || true
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

@test "detect_wan finds the server's own IPv4 and IPv6 and stores them" {
    # DD-138: nothing is typed by hand; the addresses come from the host's routing table.
    eval "$(awk '/^detect_wan\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    ip() {
        case "$*" in
        "-4 -o route get 1.1.1.1") echo "1.1.1.1 via 203.0.113.1 dev eth0 src 203.0.113.7 uid 0" ;;
        "-4 -o addr show dev eth0") echo "2: eth0    inet 203.0.113.7/24 brd 203.0.113.255 scope global eth0" ;;
        "-6 -o route get 2606:4700:4700::1111")
            [ "${FAKE_V6:-}" = none ] && return 2
            echo "2606:4700:4700::1111 from :: via fe80::1 dev eth0 proto ra src 2001:db8::7 metric 1024 pref medium" ;;
        "-6 -o addr show dev eth0 scope global")
            [ "${FAKE_V6:-}" = other ] || echo "2: eth0    inet6 2001:db8::7/64 scope global dynamic mngtmpaddr" ;;
        *) return 1 ;;
        esac
    }
    detect_wan
    [ "$WAN_INTERFACE" = eth0 ]
    [ "$WAN_IPV4" = 203.0.113.7 ]
    [ "$WAN_IPV6" = 2001:db8::7 ]
    FAKE_V6=none detect_wan
    [ -z "$WAN_IPV6" ]
    FAKE_V6=other detect_wan
    [ -z "$WAN_IPV6" ]
    # Both are written to state.env; the endpoint is the detected IPv4; no literal address remains.
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'WAN_IPV6=\$WAN_IPV6'
    awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh" | grep -qx '    WG_ENDPOINT_HOST="\$WAN_IPV4"'
    run grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$V2_ROOT/install.sh" "$V2_ROOT/scripts/master-wg" \
        "$V2_ROOT/panel/master-wg-panel" "$V2_ROOT/config/defaults.env"
    # DNS provider prefixes (DD-140 presets) are data, not addresses of this server.
    printf '%s\n' "$output" | grep -vE '10\.8\.|127\.0\.0\.|0\.0\.0\.0|1\.1\.1\.|1\.0\.0\.|9\.9\.9\.|149\.112\.112\.|94\.140\.1[45]\.|8\.8\.[84]\.|45\.90\.[23]0\.|100\.100\.100\.100|100\.64\.0\.0|255\.' >"$TMP/literals" || true
    [ ! -s "$TMP/literals" ]
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
    grep -qF 'TAILSCALE_IPV4="$TAILSCALE_IPV4" SHARE_PORT="$SHARE_PORT"' \
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
    # DD-143: WireGuard ağları state.env'den değil kayıttan gelir; boş kayıt geçerlidir.
    run ! grep -qE 'WG_PORT_DEFAULT:\?|WG_INTERFACE:\?|WG_ADDR_BASE4:\?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_NETWORKS_FILE' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'TORRENT_PUBLIC_PORT:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX' "$V2_ROOT/install.sh"
    run ! grep -qE 'TORRENT_PUBLIC_PORT:=61005|CHAIN_INPUT:=MASTER' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX}IN-' "$V2_ROOT/scripts/firewall.sh"
}

@test "qbittorrent and unpackerr use DOWNLOADS_UID/GID tokens" {
    grep -q 'PUID: "__DOWNLOADS_UID__"' "$V2_ROOT/templates/compose.yaml"
    grep -q 'PGID: "__DOWNLOADS_GID__"' "$V2_ROOT/templates/compose.yaml"
    # DD-148: unpackerr is a module with its own compose file.
    [ "$(grep -c 'user: "__DOWNLOADS_UID__:__DOWNLOADS_GID__"' "$V2_ROOT/modules/unpackerr/compose.yaml")" -eq 1 ]
    run ! grep -qE 'PUID: "1000"|PGID: "1000"|user: "1000:1000"' \
        "$V2_ROOT/templates/compose.yaml" "$V2_ROOT/modules/unpackerr/compose.yaml"
}

@test "downloads tree is chown 1000 for qbittorrent, unpackerr and the console" {
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
        "$V2_ROOT/modules/unpackerr/compose.yaml"
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

@test "the user area is a fixed root under /srv and compose needs no .env" {
    # DD-144: the operator is not asked for a path; the constant is still checked.
    grep -qx 'SERVER_ROOT="/srv"' "$V2_ROOT/config/defaults.env"
    grep -qx 'DOWNLOADS_SUBDIR="downloads"' "$V2_ROOT/config/defaults.env"
    run ! grep -qE '^INPUT_KEYS=.*DOWNLOADS_PATH' "$V2_ROOT/install.sh"
    run ! grep -q 'DOWNLOADS_PATH' "$V2_ROOT/config/kurulum.env.example"
    grep -q 'DOWNLOADS_PATH="\$SERVER_ROOT/\$DOWNLOADS_SUBDIR"' "$V2_ROOT/install.sh"
    grep -q 'assert_downloads_path_allowed "\$SERVER_ROOT"' "$V2_ROOT/install.sh"
    grep -q 'kullanıcı alanı sistem dizininde olamaz' "$V2_ROOT/install.sh"
    grep -q 'kullanıcı alanı allowlist dışı' "$V2_ROOT/install.sh"
    # config.env no longer carries a path the operator could have chosen.
    run ! grep -q 'DOWNLOADS_PATH=\$DOWNLOADS_PATH' <<<"$(awk '/^write_config\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    [ -n "$stage4" ]
    run ! grep -q 'atomic_write "$COMPOSE_DIR/.env"' <<<"$stage4"
    # Every value is rendered into the file, so no interpolation is left for
    # Compose to resolve and a stray .env cannot change the stack.
    run ! grep -q '\${' "$V2_ROOT/templates/compose.yaml"
}

@test "compose runs dozzle behind a login with actions, no shell, loopback only" {
    # DD-116: docker.sock is root-equivalent, so loopback + Caddy + users.yml.
    block="$(awk '/^  dozzle:$/,/^  qbittorrent:$/' "$V2_ROOT/templates/compose.yaml")"
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
    grep -q 'UN_FOLDER_0_PATH: "/downloads"' "$V2_ROOT/modules/unpackerr/compose.yaml"
    grep -q 'UN_FOLDER_0_MOVE_BACK: "true"' "$V2_ROOT/modules/unpackerr/compose.yaml"
    grep -q 'UN_FOLDER_0_DELETE_ORIGINAL: "false"' "$V2_ROOT/modules/unpackerr/compose.yaml"
    run ! grep -qE 'UN_(QBITTORRENT|TRANSMISSION)_' "$V2_ROOT/modules/unpackerr/compose.yaml"
    # DD-148: no network at all, and never part of the base compose file.
    grep -qx '    network_mode: none' "$V2_ROOT/modules/unpackerr/compose.yaml"
    run ! grep -q 'unpackerr' "$V2_ROOT/templates/compose.yaml"
}

@test "qbittorrent is synced from its template and the input account, ports stay on the command line" {
    # DD-129: managed keys live in templates/qBittorrent.conf; the account comes
    # from TORRENT_USER/TORRENT_PASS; the image passes --webui-port and
    # --torrenting-port on every start, so ports are not template keys.
    block="$(awk '/^  qbittorrent:$/,/^  paylasim:$/' "$V2_ROOT/templates/compose.yaml" | sed '/^  # DD-141/,$d')"
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
    grep -q 'TORRENT_USER TORRENT_PASS SHARE_USER SHARE_PASS"$' <<<"$(grep '^INPUT_KEYS=' "$V2_ROOT/install.sh")"
    grep -q 'INPUT_NONEMPTY_KEYS=.*TORRENT_USER TORRENT_PASS SHARE_USER SHARE_PASS"' "$V2_ROOT/install.sh"
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
    awk '/"\$code" == "403"/ && !a {a = NR} /^    qbit_login_check$/ {b = NR} /^    unset TORRENT_NEW_PASS$/ {c = NR}
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
    # The name wg. now redirects to the console (DD-140); the backend stays on loopback.
    grep -q '^http://wg.__LOCAL_DOMAIN__, http://dosya.__LOCAL_DOMAIN__, http://file.__LOCAL_DOMAIN__ {$' "$V2_ROOT/templates/Caddyfile"
    grep -A1 '^http://panel.__LOCAL_DOMAIN__ {$' "$V2_ROOT/templates/Caddyfile" | grep -q '@kok path /api/wg/\* /api/konsol/\*$'
    # DD-142, DD-146, DD-148: üç temel servis; unpackerr modül oldu, FileBrowser yok.
    [ "$(grep -c '^  [a-z][a-z-]*:$' <<<"$(awk '/^services:/,/^networks:/' "$V2_ROOT/templates/compose.yaml")")" -eq 3 ]
}

@test "every template placeholder is filled by its render_template call" {
    command -v python3 >/dev/null || skip "python3 yok"
    run python3 -c '
import re, sys
root = sys.argv[1]
lines = open(root + "/install.sh", encoding="utf-8").read().split("\n")
calls, i = {}, 0
while i < len(lines):
    m = re.search(r"render_template \"\$V2_ROOT/([^\"]+)\"", lines[i])
    if m:
        block = [lines[i]]
        while block[-1].rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            block.append(lines[i])
        keys = set(re.findall(r"([A-Z][A-Z0-9_]*)=", " ".join(block)))
        calls.setdefault(m.group(1), set()).update(keys)
    i += 1
assert calls, "render_template çağrısı bulunamadı"
missing = []
for name, keys in calls.items():
    text = open(root + "/" + name, encoding="utf-8").read()
    for ph in sorted(set(re.findall(r"__([A-Z][A-Z0-9_]*)__", text))):
        if ph not in keys:
            missing.append("%s: __%s__" % (name, ph))
assert not missing, missing
' "$V2_ROOT"
    [ "$status" -eq 0 ]
}

@test "a config newer than its unit forces a restart even when the file did not change" {
    # Bir önceki çalıştırma render ile restart arasında düşerse dosya "aynı" görünür
    # ama servis eski ayarla çalışır (canlı görüldü: yeni dnsmasq adı çözülmedi).
    grep -q 'config_newer_than_unit "\$DNSMASQ_CONF_FILE" dnsmasq.service' "$V2_ROOT/install.sh"
    grep -q 'config_newer_than_unit "\$CADDYFILE" caddy.service' "$V2_ROOT/install.sh"
    local body
    body="$(awk '/^config_newer_than_unit\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'ActiveEnterTimestamp' <<<"$body"
    grep -q 'stat -c %Y' <<<"$body"
    # Birim hiç çalışmamışsa (zaman damgası boş) yeniden başlatılır.
    grep -q '\[\[ -n "\$started" \]\] || return 0' <<<"$body"
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
    # DD-143: port çakışması denetimi artık master-wg net-add'de (ağları o kurar).
    grep -q '"tailscale:\${TAILSCALE_UDP_PORT:-}"' "$V2_ROOT/scripts/master-wg"
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

@test "the only WebDAV is the share: loopback compose, share root, Caddy name and TS IP:SHARE_PORT" {
    # DD-142: indirme klasörünün tamamını yayımlayan servis kaldırıldı; tek rclone kaldı.
    run ! grep -q 'container_name: webdav' "$V2_ROOT/templates/compose.yaml"
    run ! grep -qE 'WEBDAV_(PORT|USER|PASS|HTPASSWD_FILE|MIN_PASSWORD_LENGTH)' \
        "$V2_ROOT/config/defaults.env" "$V2_ROOT/config/kurulum.env.example" "$V2_ROOT/install.sh" \
        "$V2_ROOT/templates/compose.yaml" "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf"
    run ! grep -q 'webdav' "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'container_name: paylasim' "$V2_ROOT/templates/compose.yaml"
    grep -q 'RCLONE_IMAGE=' "$V2_ROOT/config/defaults.env"
    grep -qE '^RCLONE_IMAGE="rclone/rclone:1\.75"' "$V2_ROOT/config/defaults.env"
    grep -q '__RCLONE_IMAGE__' "$V2_ROOT/templates/compose.yaml"
    [ "$(grep -c '__RCLONE_IMAGE__' "$V2_ROOT/templates/compose.yaml")" -eq 1 ]
    grep -q '127.0.0.1:__SHARE_PORT__:8080' "$V2_ROOT/templates/compose.yaml"
    run ! grep -q '__TAILSCALE_IPV4__:__SHARE_PORT__' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--htpasswd=/run/secrets/paylasim_htpasswd' "$V2_ROOT/templates/compose.yaml"
    grep -q -- '--read-only' "$V2_ROOT/templates/compose.yaml"
    grep -q '__SERVER_ROOT__:__SERVER_ROOT__:ro' "$V2_ROOT/templates/compose.yaml"
    grep -q 'reverse_proxy 127.0.0.1:__SHARE_PORT__' "$V2_ROOT/templates/Caddyfile"
    grep -q 'http://paylas.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}:{$SHARE_PORT}' \
        "$V2_ROOT/templates/Caddyfile"
    run ! grep -qE 'http://\{\$TAILSCALE_IPV4\}[[:space:],}]' \
        "$V2_ROOT/templates/Caddyfile"
    run ! grep -q 'master-webdav' "$V2_ROOT/install.sh"
    run ! grep -qE 'apt-get install -y[^\n]*\brclone\b' "$V2_ROOT/install.sh"
    grep -q "wget -q -S -O /dev/null http://127.0.0.1:8080/" \
        "$V2_ROOT/templates/compose.yaml"
    grep -q "grep -q '401'" "$V2_ROOT/templates/compose.yaml"
    awk '
      /^  paylasim:/ {in_svc=1; next}
      in_svc && /^  [a-z]/ {in_svc=0}
      in_svc && /healthcheck:/ {found=1}
      END {exit found ? 0 : 1}
    ' "$V2_ROOT/templates/compose.yaml"
    awk '
      /^  paylasim:/ {in_svc=1; next}
      in_svc && /^  [a-z]/ {in_svc=0}
      in_svc && /mem_limit:|memory:|pids_limit:/ {bad=1}
      END {exit bad ? 1 : 0}
    ' "$V2_ROOT/templates/compose.yaml"
    grep -qE '^[[:space:]]*- paylasim$' "$V2_ROOT/templates/compose.yaml"
    awk '
      /^networks:/ {in_nets=1; next}
      in_nets && /^[a-z]/ {in_nets=0}
      in_nets && /^  paylasim:/ {found=1}
      in_nets && found && /name: paylasim/ {named=1}
      in_nets && found && /internal: true/ {bad=1}
      END {exit (named && !bad) ? 0 : 1}
    ' "$V2_ROOT/templates/compose.yaml"
    grep -q 'wait_share_healthy' "$V2_ROOT/install.sh"
    # Dosyadan çıkarılan servisin konteyneri ayakta kalmaz.
    grep -q 'docker compose up -d --remove-orphans' "$V2_ROOT/install.sh"
    grep -q 'assert_share_network' "$V2_ROOT/install.sh"
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
    grep -qF -- '--dport "${WG_PORTS[i]}" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
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
    grep -q 'Host: paylas.' "$V2_ROOT/install.sh"
    grep -q 'http://${TAILSCALE_IPV4}:${SHARE_PORT}/' "$V2_ROOT/install.sh"
    grep -q 'http://127.0.0.1:${SHARE_PORT}/' "$V2_ROOT/install.sh"
    run ! grep -q 'WebDAV Tailscale publish' "$V2_ROOT/install.sh"
    grep -q 'assert_share_readonly_runtime' "$V2_ROOT/install.sh"
    grep -q 'ReadonlyRootfs' "$V2_ROOT/install.sh"
    grep -q '"\${SERVER_ROOT} false"' "$V2_ROOT/install.sh"
    run ! grep -q 'v2-write-probe' "$V2_ROOT/install.sh"
    share_runtime="$(awk '/^assert_share_readonly_runtime/,/^stage_7/' "$V2_ROOT/install.sh")"
    [ -n "$share_runtime" ]
    run ! grep -qE '401\|403\|405' <<<"$share_runtime"
    run ! grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    grep -q 'docker port qbittorrent' "$V2_ROOT/install.sh"
    grep -q 'docker port paylasim' "$V2_ROOT/install.sh"
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
    # DNS_PORT and CADDY_HTTP_PORT exist and are read where ports are checked (DD-143: master-wg).
    grep -q '"dns:53" "http:80"' "$V2_ROOT/scripts/master-wg"
    grep -q 'CADDY_HTTP_PORT' "$V2_ROOT/install.sh"
}

@test "FileBrowser is gone: no container, account, port or database; file. redirects to the console" {
    # DD-146: Konsol's own file manager (upload, multi-select, search) replaced it.
    local code
    code="$(grep -hvE '^[[:space:]]*#' "$V2_ROOT/templates/compose.yaml" "$V2_ROOT/config/defaults.env" \
        "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/Caddyfile.wg" "$V2_ROOT/templates/dnsmasq.conf" \
        "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT/scripts/firewall.sh" "$V2_ROOT/scripts/master-wg" \
        "$V2_ROOT/panel/master-wg-panel" "$V2_ROOT/console/konsol.js" "$V2_ROOT/console/index.html" \
        "$V2_ROOT/config/kurulum.env.example")"
    run ! grep -qi 'filebrowser' <<<"$code"
    run ! grep -q '61007' <<<"$code"
    run ! grep -qE '^INPUT_KEYS=.*FILEBROWSER' "$V2_ROOT/install.sh"
    # The old name keeps working as a bookmark: it lands on the console.
    grep -q '^http://wg.__LOCAL_DOMAIN__, http://dosya.__LOCAL_DOMAIN__, http://file.__LOCAL_DOMAIN__ {$' "$V2_ROOT/templates/Caddyfile"
    grep -qx 'interface-name=file.__LOCAL_DOMAIN__,__TAILSCALE_IF__' "$V2_ROOT/templates/dnsmasq.conf"
    # WireGuard "ui" networks reach Dozzle and qBittorrent only.
    [ "$(grep -c '^http://' "$V2_ROOT/templates/Caddyfile.wg")" -eq 2 ]
}

@test "compose images use upstream stable tracks where published" {
    # DD-97: prefer the vendor's stable track over a frozen patch@digest.
    grep -qE '^DOZZLE_IMAGE="amir20/dozzle:v11"' \
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

@test "tailscale joins only through the login link: no auth key input, file or flag" {
    # DD-147: the operator approves the link shown during the install; nothing is typed or stored.
    run ! grep -q 'TS_AUTH_KEY' "$V2_ROOT/install.sh" "$V2_ROOT/config/kurulum.env.example" "$V2_ROOT/config/defaults.env"
    run ! grep -qE -- '--auth-key|tailscale-authkey|TS_AUTHKEY_LOGIN_SECONDS|tailscale_login_with_key' \
        "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env"
    run ! grep -qE '^INPUT_KEYS=.*TS_' "$V2_ROOT/install.sh"
    stage2="$(awk '/^stage_2\(\)/,/^stage_3\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'if \[\[ "\$(tailscale_login_state)" != "complete" \]\]; then' <<<"$stage2"
    grep -qx '        tailscale_login' <<<"$stage2"
    grep -q 'giriş bağlantısı gösterilir' "$V2_ROOT/install.sh"
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
    # DD-124/DD-143: girdi yalnız kurulum.env; WireGuard için hiçbir girdi yok.
    run ! grep -qE 'take_snapshot_input|validate_snapshot' <<<"$stage0"
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

@test "ensure_share_account keeps a matching account, rewrites a changed one and stores both files" {
    command -v htpasswd >/dev/null || skip "htpasswd yok"
    eval "$(awk '/^ensure_share_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    STATE_DIR="$TMP" SHARE_HTPASSWD_FILE="$TMP/paylasim.htpasswd" SHARE_CRED_FILE="$TMP/paylasim.cred"
    log() { :; }
    chown() { :; }
    docker() { printf '%s\n' "$*" >>"$TMP/docker-calls"; }
    SHARE_NEW_USER=paylasim SHARE_NEW_PASS='fixture pass $1'
    run ensure_share_account
    [ "$status" -eq 0 ]
    printf '%s' 'fixture pass $1' | htpasswd -vi "$TMP/paylasim.htpasswd" paylasim 2>/dev/null
    # Konsol'un gösterdiği düz kopya da yazılır; ikisi aynı girdiden gelir.
    [ "$(cat "$TMP/paylasim.cred")" = 'paylasim:fixture pass $1' ]
    grep -q '^inspect paylasim$' "$TMP/docker-calls"
    before="$(cat "$TMP/paylasim.htpasswd")"
    rm -f "$TMP/docker-calls"
    SHARE_NEW_USER=paylasim SHARE_NEW_PASS='fixture pass $1'
    run ensure_share_account
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/paylasim.htpasswd")" = "$before" ]
    [ ! -e "$TMP/docker-calls" ]
    SHARE_NEW_USER=paylasim SHARE_NEW_PASS='changed-pass-2'
    run ensure_share_account
    [ "$status" -eq 0 ]
    printf '%s' 'changed-pass-2' | htpasswd -vi "$TMP/paylasim.htpasswd" paylasim 2>/dev/null
    [ "$(wc -l <"$TMP/paylasim.htpasswd")" -eq 1 ]
    run ! grep -q 'changed-pass-2' "$TMP/docker-calls"
    awk '/^stage_1\(\)/,/^ensure_share_account\(\)/' "$V2_ROOT/install.sh" |
        grep -q '^    ensure_share_account$'
}
@test "portable launcher reads kurulum/ beside it and sends it only to tmpfs" {
    local exporter="$V2_ROOT/dev/export-installer.sh" body
    body="$(awk "/cat <<'BODY_END'/,/^BODY_END\$/" "$exporter")"
    [ -n "$body" ]
    grep -q 'INPUT_LOCAL_DIR="\$here/kurulum"' <<<"$body"
    grep -q 'INPUT_FILE_LOCAL="\$INPUT_LOCAL_DIR/kurulum.env"' <<<"$body"
    grep -q 'stat -f %Lp "\$INPUT_FILE_LOCAL"' <<<"$body"
    # DD-143: sunucuya yalnız kurulum.env gider, geri hiçbir şey alınmaz.
    grep -q 'send_files="kurulum.env"' <<<"$body"
    grep -q -- '--no-mac-metadata -cf - \$send_files |' <<<"$body"
    run ! grep -qE 'wireguard/sunucu|wireguard/\*' <<<"$body"
    run ! grep -qiE 'qbittorrent' <<<"$body"
    grep -q 'anahtar/parola içerdiği için 600 olmalı' <<<"$body"
    grep -q -- '--no-same-owner -xf -' <<<"$body"
    run ! grep -qE 'input_files|fetch_wireguard_output|OUTPUT_' <<<"$body"
    run ! grep -q 'REMOTE_RESTORE_DIR' <<<"$body"
    run ! grep -q 'REMOTE_RESTORE_DIR' "$exporter"
    # Only SSH_HOST is read on the Mac; the rest is validated by the installer.
    grep -q 'index(\$0, "SSH_HOST=") == 1' <<<"$body"
    run ! grep -qE '_PASS|TS_AUTH_KEY' <<<"$body"
    run ! grep -q 'SSH sunucu adı' <<<"$body"
    run ! grep -q 'DEPLOY_HOST' "$exporter"
    grep -q 'stat -f -c %T' <<<"$body"
    grep -q '= tmpfs \]' <<<"$body"
    grep -q 'remote_input_sent=1' <<<"$body"
    awk '/^cleanup_local\(\)/,/^}$/' <<<"$body" | grep -q "rm -rf '\$REMOTE_INPUT_DIR'"
    # A literal temp name would survive an interrupted run and break every later one
    # (BSD mktemp only replaces trailing X's): the archive lives in a fresh private dir.
    grep -q 'tgz_dir="$(mktemp -d "${TMPDIR:-/tmp}/dsi-embed.XXXXXX")"' <<<"$body"
    run ! grep -qE '^[^#]*mktemp [^#]*X{6}\.[a-z]' "$V2_ROOT/dev/export-installer.sh"
    awk '/^cleanup_local\(\)/,/^}$/' <<<"$body" | grep -q 'rm -rf -- "\$tgz_dir"'
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
Address = 10.8.0.1/24, fdcc:ad94:bacf:61a4::1/112
ListenPort = 61001
MTU = 1420
PrivateKey = $K1

# peer: iph0
[Peer]
PublicKey = $K2
PresharedKey = $K3
AllowedIPs = 10.8.0.2/32, fdcc:ad94:bacf:61a4::2/128

# peer: mac.book_1
[Peer]
PublicKey = $K4
PresharedKey = $K3
AllowedIPs = 10.8.0.3/32, fdcc:ad94:bacf:61a4::3/128
EOF
}

snapshot_profile() {
    snapshot_keys
    cat <<EOF
[Interface]
PrivateKey = $K2
Address = 10.8.0.2/32, fdcc:ad94:bacf:61a4::2/128
MTU = 1420
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = $K1
PresharedKey = $K3
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 21
Endpoint = ${1:-203.0.113.7}:61001
EOF
}

@test "the installer carries nothing from the Mac: no snapshot, no restore, no WireGuard upload" {
    # DD-143: kurulum WireGuard ağı yaratmaz ve Mac'ten hiçbir dosya okumaz.
    local key
    for key in restore_wireguard_snapshot wg_snapshot_check validate_snapshot take_snapshot_input \
        snapshot_note RESTORE_DIR SNAPSHOT_MAX_BYTES WG_RESTORED; do
        run ! grep -q "$key" "$V2_ROOT/install.sh"
    done
    run ! grep -qE 'RESTORE_DIR|SNAPSHOT_MAX_BYTES' "$V2_ROOT/config/defaults.env"
    run ! grep -q 'wireguard/sunucu' "$V2_ROOT/dev/export-installer.sh"
    grep -q 'send_files="kurulum.env"' "$V2_ROOT/dev/export-installer.sh"
    [ "$(grep -c 'send_files=' "$V2_ROOT/dev/export-installer.sh")" -eq 1 ]
    # Girdi dosyasında WireGuard portu da yok: ağın portunu Konsol belirler.
    run ! grep -q 'WG_PUBLIC_PORT' "$V2_ROOT/config/kurulum.env.example"
    run ! grep -q 'INPUT_WG_PUBLIC_PORT' "$V2_ROOT/install.sh"
    # Kurulum yalnız katmanı hazırlar ve kayıttaki ağları uygular.
    grep -q '^ensure_wireguard_ready()' "$V2_ROOT/install.sh"
    grep -q '^ensure_wg_networks_running()' "$V2_ROOT/install.sh"
    run ! grep -q '^ensure_wireguard()' "$V2_ROOT/install.sh"
    local ready
    ready="$(awk '/^ensure_wireguard_ready\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    run ! grep -qE 'wg genkey|wg-quick|syncconf|PrivateKey' <<<"$ready"
    grep -q 'wireguard-tools qrencode' <<<"$ready"
    awk '/^stage_5\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'ensure_wg_networks_running'
}

@test "wireguard.command talks to the server only: picks a network, no backup, no upload" {
    local cmd="$V2_ROOT/../wireguard.command"
    # DD-143: Mac'te yedek yok; menüde "Ağ seç" var, "Yedek al" yok.
    run ! grep -qE 'backup_settings|auto_backup|Yedek al' "$cmd"
    grep -q 'select_net()' "$cmd"
    grep -q 'Ağ seç' "$cmd"
    grep -q 'Ağı yeniden üret' "$cmd"
    grep -q 'master-wg ile --if' <<<"$(grep -A2 'NET=""' "$cmd" | head -5)" || grep -q '"$MASTER_WG" --if "$NET"' "$cmd"
    # Ağ yoksa kullanıcı Konsol'a yönlendirilir.
    grep -q 'Konsol' "$cmd"
    grep -q 'Yapılandır' "$cmd"
    # Sunucuya hiçbir dosya gönderilmez.
    run ! grep -qE '\bscp\b|tar -x|put \$' "$cmd"
    bash -n "$cmd"
}

panel_start() {
    # Konsol'un WireGuard arka ucu, her çağrıyı günlükleyen sahte master-wg ile (DD-133, DD-143).
    PANEL="$V2_ROOT/panel/master-wg-panel"
    mkdir -p "$TMP/pbin" "$TMP/clients"
    printf '[Interface]\n' >"$TMP/wg0.conf"
    touch -t 202001010000 "$TMP/wg0.conf" "$TMP/clients"
    cat >"$TMP/state.env" <<EOF
V2_VERSION=2026.08.06-v2-test
LOCAL_DOMAIN=ayc
WG_ENDPOINT_HOST=203.0.113.7
WG_PORT_DEFAULT=61001
WG_ADDR_BASE4=10.8
WG_ADDR_BASE6=fdcc:ad94:bacf:61a4
WG_CONF_DIR=$TMP
WG_CLIENTS_DIR=$TMP/clients
WG_CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
EOF
    cat >"$TMP/pbin/master-wg" <<EOF
#!/bin/bash
net=""
[ "\$1" != --if ] || { net="\$2"; shift 2; }
(IFS='|'; printf '%s|%s\n' "\${net:-yok}" "\$*") >>"$TMP/mwg-calls"
case "\$1" in
    nets) [ -e "$TMP/no-wg" ] && exit 0
        printf 'wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\t1\t1\n'
        [ ! -e "$TMP/has-wg1" ] || printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\tMisafir\t1\t0\n' ;;
    info) [ "\$net" != wg0 ] || printf 'iphone\t10.8.0.2\tfdcc:ad94:bacf:61a4::2\t1700000000\t2048\t1024\tvar\t1.1.1.1, 1.0.0.1\t21\t1420\t1\n' ;;
    net-add) [ "\$2" != 61001 ] || { echo "HATA: UDP 61001 kullanılıyor (wg0); başka bir port seçin" >&2; exit 1; }
        touch "$TMP/has-wg1"; printf 'wg1\t%s\n' "\$2" ;;
    net-remove) rm -f "$TMP/has-wg1"; printf '%s\t0\n' "\$2" ;;
    add) [ "\$2" != dup ] || { echo "HATA: 'dup' adında bir peer zaten var" >&2; exit 1; }; printf '%s\t10.8.0.3\n' "\$2" ;;
    remove | dns | keepalive) exit 0 ;;
    peer) printf '%s\t%s\n' "\$2" "\$3" ;;
    net) [ "\$2" != kapat ] || { printf '%s\t0\n' "\$net"; exit 0; }; printf '%s\t1\n' "\$net" ;;
    reset) printf '4\t4\n' ;;
    profile) printf '[Interface]\nPrivateKey = SECRETPRIV\nAddress = 10.8.0.2/32\n\n[Peer]\nPresharedKey = SECRETPSK\nEndpoint = 203.0.113.7:61001\n' ;;
    png) printf '\211PNG\r\n\032\nQRDATA' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TMP/pbin/master-wg"
    # DD-148: sahte modül yardımcısı ve systemd araçları (çağrıları günlükler).
    cat >"$TMP/pbin/master-modul" <<EOF
#!/bin/bash
case "\$1" in
    liste) printf 'unpackerr\tdocker\t%s\t%s\t-\t-\t-\t-\n' "\$(cat "$TMP/mod-state" 2>/dev/null || echo yok)" "\$([ -e "$TMP/mod-running" ] && echo running || echo yok)" ;;
    gunluk) printf '[INFO] Klasör izleniyor: /downloads\n' ;;
    *) echo "HATA: beklenmeyen çağrı \$*" >&2; exit 1 ;;
esac
EOF
    cat >"$TMP/pbin/systemd-run" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/sdrun-calls"
EOF
    cat >"$TMP/pbin/systemctl" <<EOF
#!/bin/bash
[ "\$1" = is-active ] && [ -e "$TMP/busy-\${3%.service}" ] && exit 0
exit 3
EOF
    chmod +x "$TMP/pbin/master-modul" "$TMP/pbin/systemd-run" "$TMP/pbin/systemctl"
    PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    python3 "$PANEL" serve --listen "127.0.0.1:$PORT" --state "$TMP/state.env" --state-env \
        --master-wg "$TMP/pbin/master-wg" --master-modul "$TMP/pbin/master-modul" >"$TMP/panel.log" 2>&1 &
    PANEL_PID=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null "http://127.0.0.1:$PORT/api/wg/state" && return 0
        sleep 0.1
    done
    cat "$TMP/panel.log"
    return 1
}

# pc PATH [curl args...] → HTTP code; body in $TMP/body, headers in $TMP/head.
pc() {
    local path="$1"
    shift
    curl -s -o "$TMP/body" -D "$TMP/head" -w '%{http_code}' -H "Host: panel.ayc" "$@" "http://127.0.0.1:$PORT$path"
}

@test "wg panel needs no password but a known host and the panel header before it runs master-wg" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    # DD-147: no password and no login prompt; Tailscale is the boundary.
    # Konsol sayfasını dosya arka ucu verir; burada kök 404'tür.
    [ "$(pc /)" = 404 ]
    run ! grep -qi '^WWW-Authenticate' "$TMP/head"
    [ "$(pc /api/wg/state -H 'X-Konsol: 1')" = 200 ]
    grep -qi "^Content-Security-Policy: default-src 'none'; base-uri 'none'" "$TMP/head"
    grep -qi '^Cache-Control: no-store' "$TMP/head"
    grep -qi '^X-Frame-Options: DENY' "$TMP/head"
    # DNS rebinding: another Host name is refused even with the password.
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$PORT/")" = 403 ]
    # CSRF: the API needs the panel header and a same-origin fetch.
    [ "$(pc /api/wg/state)" = 403 ]
    [ "$(pc /api/wg/state -H 'X-Konsol: 1' -H 'Sec-Fetch-Site: cross-site')" = 403 ]
    # Only the background sampler's read-only calls (DD-137) may have run.
    touch "$TMP/mwg-calls"
    run ! grep -qvE '^(wg[0-9]|yok)\|(nets|info)$' "$TMP/mwg-calls"
    [ "$(pc /api/wg/state -H 'X-Konsol: 1' -H 'Sec-Fetch-Site: same-origin')" = 200 ]
    python3 - "$TMP/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert [n["iface"] for n in d["networks"]] == ["wg0"], d
n = d["networks"][0]
assert (n["port"], n["scope"], n["server4"], n["subnet6"], n["active"]) == (61001, "ui", "10.8.0.1", "fdcc:ad94:bacf:61a4::/112", True), n
p = n["peers"][0]
assert (p["name"], p["ipv4"], p["provider"], p["keepalive"], p["mtu"], p["profile"]) == ("iphone", "10.8.0.2", "Cloudflare", 21, 1420, True), p
assert d["endpoint"] == "203.0.113.7" and d["max"] == 10 and 53 in d["reserved"], d
assert d["defaults"]["dns"] and d["defaults"]["keepalive"] == 21
# DD-136: the panel does not track the Mac backup.
assert "backup" not in d
PY
    # check (stage 7): no password.
    run python3 "$PANEL" check --url "http://127.0.0.1:$PORT/api/wg/state" --host panel.ayc
    [ "$status" -eq 0 ]
    [ "$output" = "1 ağ, 1 peer" ]
    # DD-143: temiz kurulumda ağ yoktur; check yine geçer.
    touch "$TMP/no-wg"
    run python3 "$PANEL" check --url "http://127.0.0.1:$PORT/api/wg/state" --host panel.ayc
    [ "$status" -eq 0 ]
    [ "$output" = "0 ağ, 0 peer" ]
    rm -f "$TMP/no-wg"
    # A foreign name fails the check (the Host gate stays).
    run python3 "$PANEL" check --url "http://127.0.0.1:$PORT/api/wg/state" --host evil.example
    [ "$status" -ne 0 ]
    case "$output" in *"HTTP 403"*) ;; *) false ;; esac
    # The account machinery is gone for good.
    run ! grep -qE 'pbkdf2|WWW-Authenticate|def cmd_account|locked_out|FAIL_LIMIT' "$PANEL"
}

modul_fixture() {
    # DD-148: master-modul with a fake docker, flock and logger.
    mkdir -p "$TMP/mbin" "$TMP/mods/unpackerr" "$TMP/run" "$TMP/dl/.unpackerr"
    printf 'services: {}\n' >"$TMP/mods/unpackerr/compose.yaml"
    cat >"$TMP/mstate.env" <<EOF
MODULES_FILE=$TMP/moduller
MODULES_DIR=$TMP/mods
RUNTIME_DIR=$TMP/run
DOWNLOADS_PATH=$TMP/dl
EOF
    cat >"$TMP/mbin/docker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/docker-calls"
case "\$1" in
    info | exec | rm) exit 0 ;;
    compose)
        case "\$6" in
            pull) [ ! -e "$TMP/pull-fail" ] || exit 1 ;;
            up) touch "$TMP/running"; rm -f "$TMP/stopped" ;;
            stop) rm -f "$TMP/running"; touch "$TMP/stopped" ;;
            down) rm -f "$TMP/running" "$TMP/stopped" ;;
        esac ;;
    inspect)
        if [ -e "$TMP/running" ]; then echo running
        elif [ -e "$TMP/stopped" ]; then echo exited
        else echo; echo "Error: No such object: \$3" >&2; exit 1
        fi ;;
    logs) echo "[INFO] Klasör izleniyor: /downloads" ;;
esac
EOF
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/flock"
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/logger"
    chmod +x "$TMP/mbin"/*
}

mm() {
    PATH="$TMP/mbin:$PATH" STATE_FILE="$TMP/mstate.env" bash "$V2_ROOT/scripts/master-modul" "$@"
}

@test "master-modul installs, stops, starts and removes a docker module and records every step" {
    modul_fixture
    run mm liste
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'unpackerr\tdocker\tyok\tyok\t-\t-\t-\t-')" ]
    run mm kur unpackerr
    [ "$status" -eq 0 ]
    grep -qx "$(printf 'unpackerr\tcalisiyor')" "$TMP/moduller"
    [ "$(cat "$TMP/run/modul-unpackerr.ilerleme")" = "$(printf 'kur\tbitti\t0\tkuruldu')" ]
    grep -qx "compose -p unpackerr -f $TMP/mods/unpackerr/compose.yaml pull --quiet" "$TMP/docker-calls"
    grep -qx "compose -p unpackerr -f $TMP/mods/unpackerr/compose.yaml up -d --remove-orphans" "$TMP/docker-calls"
    run mm liste
    [ "$output" = "$(printf 'unpackerr\tdocker\tcalisiyor\trunning\tkur\tbitti\t0\tkuruldu')" ]
    # Already installed: refused.
    run mm kur unpackerr
    [ "$status" -ne 0 ]
    case "$output" in *"zaten kurulu"*) ;; *) false ;; esac
    run mm durdur unpackerr
    [ "$status" -eq 0 ]
    grep -qx "$(printf 'unpackerr\tdurduruldu')" "$TMP/moduller"
    run mm liste
    [ "$output" = "$(printf 'unpackerr\tdocker\tdurduruldu\texited\tdurdur\tbitti\t0\tdurduruldu')" ]
    run mm baslat unpackerr
    [ "$status" -eq 0 ]
    grep -qx "$(printf 'unpackerr\tcalisiyor')" "$TMP/moduller"
    run mm gunluk unpackerr 20
    [ "$output" = "[INFO] Klasör izleniyor: /downloads" ]
    run mm gunluk unpackerr 20000
    [ "$status" -ne 0 ]
    # Removing with --veri drops only the module's own log folder, never the downloads.
    touch "$TMP/dl/film.mkv"
    touch "$TMP/dl/.unpackerr/unpackerr.log"
    run mm kaldir unpackerr --veri
    [ "$status" -eq 0 ]
    [ "$(grep -c unpackerr "$TMP/moduller")" -eq 0 ]
    [ -d "$TMP/dl/.unpackerr" ]
    [ -z "$(ls -A "$TMP/dl/.unpackerr")" ]
    [ -f "$TMP/dl/film.mkv" ]
    grep -qx "compose -p unpackerr -f $TMP/mods/unpackerr/compose.yaml down --rmi all --remove-orphans" "$TMP/docker-calls"
    run mm liste
    [ "$output" = "$(printf 'unpackerr\tdocker\tyok\tyok\tkaldir\tbitti\t0\tkaldırıldı')" ]
    run mm kaldir unpackerr
    [ "$status" -ne 0 ]
    case "$output" in *"kurulu değil"*) ;; *) false ;; esac
    # Only catalogued ids and known commands are accepted.
    run mm kur ../etc
    [ "$status" -ne 0 ]
    case "$output" in *"bilinmeyen modül"*) ;; *) false ;; esac
    run mm kur filebrowser
    [ "$status" -ne 0 ]
    run mm kaldir unpackerr --hepsi
    [ "$status" -ne 0 ]
    run mm sil unpackerr
    [ "$status" -ne 0 ]
}

@test "master-modul reports a failed install in its progress file and registers nothing" {
    modul_fixture
    touch "$TMP/pull-fail"
    run mm kur unpackerr
    [ "$status" -ne 0 ]
    [ "$(cat "$TMP/run/modul-unpackerr.ilerleme")" = "$(printf 'kur\thata\t0\timaj indirilemedi')" ]
    [ ! -s "$TMP/moduller" ]
    [ "$(grep -c ' up -d' "$TMP/docker-calls")" -eq 0 ]
    # Every change runs under the one module lock; the only deletion is the module's own log folder.
    [ "$(grep -c '^    take_lock$' "$V2_ROOT/scripts/master-modul")" -eq 4 ]
    grep -q 'flock -w 5 8' "$V2_ROOT/scripts/master-modul"
    [ "$(grep -cE 'rm -r|-delete' "$V2_ROOT/scripts/master-modul")" -eq 1 ]
    grep -qF 'find "$DOWNLOADS_PATH/.unpackerr" -mindepth 1 -delete' "$V2_ROOT/scripts/master-modul"
}

@test "wg panel lists modules and starts module work as its own systemd unit" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    [ "$(pc /api/konsol/moduller)" = 403 ]
    [ "$(pc /api/konsol/moduller -H 'X-Konsol: 1')" = 200 ]
    python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))["items"][0]
assert (m["id"], m["runtime"], m["installed"], m["state"], m["busy"], m["progress"]) == ("unpackerr", "docker", False, "", False, None), m
' "$TMP/body"
    local json=(-H 'X-Konsol: 1' -H 'Content-Type: application/json')
    [ "$(pc /api/konsol/moduller/unpackerr/kur "${json[@]}" --data '{}')" = 202 ]
    tail -n 1 "$TMP/sdrun-calls" | grep -q -- '^--unit=master-modul-unpackerr.service --collect --quiet '
    tail -n 1 "$TMP/sdrun-calls" | grep -q "/master-modul kur unpackerr$"
    [ "$(pc /api/konsol/moduller/unpackerr/kaldir "${json[@]}" --data '{"veri":true}')" = 202 ]
    tail -n 1 "$TMP/sdrun-calls" | grep -q "/master-modul kaldir unpackerr --veri$"
    [ "$(pc /api/konsol/moduller/unpackerr/durdur "${json[@]}" --data '{"veri":true}')" = 202 ]
    tail -n 1 "$TMP/sdrun-calls" | grep -q "/master-modul durdur unpackerr$"
    printf 'calisiyor\n' >"$TMP/mod-state"
    touch "$TMP/mod-running"
    [ "$(pc /api/konsol/moduller -H 'X-Konsol: 1')" = 200 ]
    grep -q '"installed": true, "state": "calisiyor", "live": "running"' "$TMP/body"
    # One operation at a time per module.
    touch "$TMP/busy-master-modul-unpackerr"
    local before
    before="$(wc -l <"$TMP/sdrun-calls")"
    [ "$(pc /api/konsol/moduller/unpackerr/baslat "${json[@]}" --data '{}')" = 409 ]
    [ "$(pc /api/konsol/moduller -H 'X-Konsol: 1')" = 200 ]
    grep -q '"busy": true' "$TMP/body"
    rm -f "$TMP/busy-master-modul-unpackerr"
    # Unknown modules, unknown actions and requests without the panel header never reach systemd-run.
    [ "$(pc /api/konsol/moduller/yok/kur "${json[@]}" --data '{}')" = 404 ]
    [ "$(pc /api/konsol/moduller/unpackerr/sil "${json[@]}" --data '{}')" = 404 ]
    [ "$(pc /api/konsol/moduller/unpackerr/kur -H 'Content-Type: application/json' --data '{}')" = 403 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: baska.ornek' "${json[@]}" --data '{}' \
        "http://127.0.0.1:$PORT/api/konsol/moduller/unpackerr/kur")" = 403 ]
    [ "$(wc -l <"$TMP/sdrun-calls")" = "$before" ]
    [ "$(pc /api/konsol/moduller/unpackerr/gunluk -H 'X-Konsol: 1')" = 200 ]
    grep -qi '^Content-Type: text/plain' "$TMP/head"
    grep -q 'Klasör izleniyor' "$TMP/body"
    grep -q 'panel: konsol 127.0.0.1 modul-kur unpackerr -> ok' "$TMP/panel.log"
    grep -q 'panel: konsol 127.0.0.1 modul-kaldir unpackerr +veri -> ok' "$TMP/panel.log"
    grep -q 'panel: konsol 127.0.0.1 modul-durdur unpackerr -> ok' "$TMP/panel.log"
    grep -q 'panel: konsol 127.0.0.1 modul-baslat unpackerr -> hata' "$TMP/panel.log"
}

@test "wg panel adds and removes networks and passes each network's peer actions to master-wg" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    local auth=(-H 'X-Konsol: 1') json=(-H 'Content-Type: application/json')
    [ "$(pc /api/wg/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"phone","dns":"1.1.1.1, 1.0.0.1","keepalive":"21","mtu":"1420"}')" = 201 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"name": "phone", "ipv4": "10.8.0.3"}' "$TMP/body"
    grep -qx 'wg0|add|phone|1.1.1.1, 1.0.0.1|21|1420' "$TMP/mwg-calls"
    # Bad names, interfaces, bodies and confirmations never reach master-wg; its refusals come back as messages.
    : >"$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"../x","dns":"1.1.1.1","keepalive":"21","mtu":"1420"}')" = 400 ]
    [ "$(pc /api/wg/nets/eth0/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":"21","mtu":"1420"}')" = 400 ]
    [ "$(pc /api/wg/nets/wg0/peers "${auth[@]}" -d 'name=phone')" = 400 ]
    [ "$(pc '/api/wg/nets/wg0/peers/..%2Fx/remove' "${auth[@]}" "${json[@]}" -d '{}')" = 400 ]
    [ "$(pc /api/wg/nets/wg0/reset "${auth[@]}" "${json[@]}" -d '{"confirm":"evet"}')" = 400 ]
    [ "$(pc /api/wg/nets/wg1/remove "${auth[@]}" "${json[@]}" -d '{"confirm":"SIL"}')" = 400 ]
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"61011","scope":"all","dns":"9.9.9.9","label":""}')" = 400 ]
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"abc","scope":"inet","dns":"9.9.9.9","label":""}')" = 400 ]
    [ ! -s "$TMP/mwg-calls" ]
    [ "$(pc /api/wg/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"dup","dns":"1.1.1.1","keepalive":"21","mtu":"1420"}')" = 400 ]
    grep -q "zaten var" "$TMP/body"
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"61001","scope":"inet","dns":"9.9.9.9","label":"x"}')" = 400 ]
    grep -q "UDP 61001 kullanılıyor (wg0)" "$TMP/body"
    # A new network: master-wg net-add, then it is listed with its label and takes its own peers.
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"61011","scope":"inet","dns":"9.9.9.9","label":"Misafir"}')" = 201 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"iface": "wg1", "port": 61011}' "$TMP/body"
    grep -qx 'yok|net-add|61011|inet|9.9.9.9|Misafir' "$TMP/mwg-calls"
    pc /api/wg/state "${auth[@]}" >/dev/null
    python3 -c 'import json, sys; n = json.load(open(sys.argv[1]))["networks"][1]; assert (n["iface"], n["label"], n["scope"], n["dns"], n["peers"]) == ("wg1", "Misafir", "inet", "9.9.9.9", []), n' "$TMP/body"
    grep -qx 'wg1|info' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg1/peers "${auth[@]}" "${json[@]}" -d '{"name":"guest","dns":"9.9.9.9","keepalive":"0","mtu":"1420"}')" = 201 ]
    grep -qx 'wg1|add|guest|9.9.9.9|0|1420' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg1/peers/guest/dns "${auth[@]}" "${json[@]}" -d '{"dns":"1.1.1.1"}')" = 200 ]
    grep -qx 'wg1|dns|guest|1.1.1.1' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg1/peers/guest/remove "${auth[@]}" "${json[@]}" -d '{}')" = 200 ]
    grep -qx 'wg1|remove|guest' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg1/reset "${auth[@]}" "${json[@]}" -d '{"confirm":"Onayla"}')" = 200 ]
    grep -qx 'wg1|reset|--onay' "$TMP/mwg-calls"
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"peers": 4, "profiles": 4}' "$TMP/body"
    [ "$(pc /api/wg/nets/wg1/remove "${auth[@]}" "${json[@]}" -d '{"confirm":"onayla"}')" = 200 ]
    grep -qx 'yok|net-remove|wg1|--onay' "$TMP/mwg-calls"
    # The masked preview carries no secret; the download and the QR only when asked.
    [ "$(pc '/api/wg/nets/wg0/peers/iphone/profile?masked=1' "${auth[@]}")" = 200 ]
    grep -q '^PrivateKey = •' "$TMP/body"
    grep -q '^Endpoint = 203.0.113.7:61001$' "$TMP/body"
    run ! grep -qE 'SECRETPRIV|SECRETPSK' "$TMP/body"
    grep -qx 'wg0|profile|iphone' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg0/peers/iphone/profile "${auth[@]}")" = 200 ]
    grep -q 'SECRETPRIV' "$TMP/body"
    grep -qi '^Content-Disposition: attachment; filename="iphone.conf"' "$TMP/head"
    [ "$(pc /api/wg/nets/wg0/peers/iphone/qr.png "${auth[@]}")" = 200 ]
    grep -qi '^Content-Type: image/png' "$TMP/head"
    [ "$(head -c 4 "$TMP/body" | od -An -tx1 | tr -d ' \n')" = 89504e47 ]
    # The old routes are gone: every WireGuard call now lives under /api/wg.
    [ "$(pc /api/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":"21","mtu":"1420"}')" = 404 ]
    [ "$(pc /api/state "${auth[@]}")" = 404 ]
    [ "$(pc /api/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":"21","mtu":"1420"}')" = 404 ]
    # DD-140: peer and network switches and keepalive go to master-wg.
    [ "$(pc /api/wg/nets/wg0/peers/iphone/durum "${auth[@]}" "${json[@]}" -d '{"on":false}')" = 200 ]
    grep -qx 'wg0|peer|iphone|kapat' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg0/peers/iphone/durum "${auth[@]}" "${json[@]}" -d '{"on":true}')" = 200 ]
    grep -qx 'wg0|peer|iphone|ac' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg0/peers/iphone/keepalive "${auth[@]}" "${json[@]}" -d '{"keepalive":"25"}')" = 200 ]
    grep -qx 'wg0|keepalive|iphone|25' "$TMP/mwg-calls"
    [ "$(pc /api/wg/nets/wg0/peers/iphone/keepalive "${auth[@]}" "${json[@]}" -d '{"keepalive":"x"}')" = 400 ]
    [ "$(pc /api/wg/nets/wg0/durum "${auth[@]}" "${json[@]}" -d '{"on":false}')" = 200 ]
    grep -qx 'wg0|net|kapat' "$TMP/mwg-calls"
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"iface": "wg0", "active": False}' "$TMP/body"
    [ "$(pc /api/wg/nets/wg0/durum "${auth[@]}" "${json[@]}" -d '{"on":true}')" = 200 ]
    grep -qx 'wg0|net|ac' "$TMP/mwg-calls"
    # The audit log names the action, network and peer, never a password or key.
    grep -q 'konsol 127.0.0.1 ekle wg0/phone -> ok' "$TMP/panel.log"
    grep -q 'konsol 127.0.0.1 ag-ekle wg1 -> ok' "$TMP/panel.log"
    grep -q 'konsol 127.0.0.1 ag-kaldir wg1 -> ok' "$TMP/panel.log"
    grep -q 'konsol 127.0.0.1 peer-durum wg0/iphone kapat -> ok' "$TMP/panel.log"
    grep -q 'konsol 127.0.0.1 ag-durum wg0 kapat -> ok' "$TMP/panel.log"
    run ! grep -qE 'panel pass|SECRETPRIV|SECRETPSK|QRDATA' "$TMP/panel.log"
}

@test "wg panel marks a peer connected only while data keeps arriving from it" {
    command -v python3 >/dev/null || skip "python3 yok"
    # DD-137: a 2 s window and a 0.3 s sampler instead of 45 s and 10 s.
    export PANEL_ACTIVE_WINDOW=2 PANEL_SAMPLE_SECONDS=0.3
    panel_start
    unset PANEL_ACTIVE_WINDOW PANEL_SAMPLE_SECONDS
    echo 1000 >"$TMP/rx"
    echo 5 >"$TMP/hs-age"
    cat >"$TMP/pbin/master-wg.new" <<EOF
#!/bin/bash
[ "\$1" != --if ] || shift 2
case "\$1" in
    nets) printf 'wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t\t\t1\t1\n' ;;
    info) printf 'phone\t10.8.0.2\tfdcc:ad94:bacf:61a4::2\t%s\t%s\t500\tvar\t1.1.1.1\t21\t1420\t1\n' "\$(( \$(date +%s) - \$(cat "$TMP/hs-age") ))" "\$(cat "$TMP/rx")" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TMP/pbin/master-wg.new"
    mv -f "$TMP/pbin/master-wg.new" "$TMP/pbin/master-wg"
    online() {
        pc /api/wg/state -H 'X-Konsol: 1' >/dev/null
        python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); p = d["networks"][0]["peers"][0]; print(p["online"], p["active_at"] is not None, d["active_window"])' "$TMP/body"
    }
    # Just seen, fresh handshake: connected until it has been watched for a whole window.
    [ "$(online)" = "True False 2" ]
    # No data for longer than the window: idle, although the handshake is 5 s old.
    sleep 2.6
    [ "$(online)" = "False False 2" ]
    # Data arrives: connected, and idle again one window later.
    echo 2000 >"$TMP/rx"
    sleep 0.8
    [ "$(online)" = "True True 2" ]
    sleep 2.6
    [ "$(online)" = "False True 2" ]
    # The sampler watches without any page: data seen early, then silence, reads as idle.
    echo 3000 >"$TMP/rx"
    sleep 2.8
    [ "$(online)" = "False True 2" ]
    # Data with a handshake older than 3 minutes is never "connected".
    echo 4000 >"$TMP/rx"
    echo 300 >"$TMP/hs-age"
    sleep 0.8
    [ "$(online)" = "False True 2" ]
    # A counter that went down (interface restarted) starts over.
    echo 10 >"$TMP/rx"
    echo 5 >"$TMP/hs-age"
    sleep 0.8
    [ "$(online)" = "True False 2" ]
    # The page shows the server's verdict; the handshake only separates idle from never seen.
    grep -q 'if (p.online) return "ok";' "$V2_ROOT/console/konsol.js"
    run ! grep -q 'a < 180' "$V2_ROOT/console/konsol.js"
}

@test "installer wires the wg panel: loopback unit, tailnet name, no password, stage 7 gate proof" {
    local unit="$V2_ROOT/systemd/master-wg-panel.service" body s6 s7
    grep -q -- '--listen 127.0.0.1:__WG_PANEL_PORT__' "$unit"
    grep -q -- '--master-wg __SBIN_DIR__/master-wg' "$unit"
    for line in 'NoNewPrivileges=true' 'ProtectSystem=full' 'ReadWritePaths=/etc/wireguard' 'PrivateTmp=true' \
        'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK'; do
        grep -qx "$line" "$unit"
    done
    grep -qx 'WG_PANEL_PORT="61008"' "$V2_ROOT/config/defaults.env"
    # DD-147: no account anywhere — not in the input, the defaults, the unit or the installer.
    run ! grep -qE 'WG_PANEL_(USER|PASS|AUTH_FILE|MIN_PASSWORD_LENGTH|NEW_|ACCOUNT)' \
        "$V2_ROOT/config/defaults.env" "$V2_ROOT/config/kurulum.env.example" "$V2_ROOT/install.sh" "$unit"
    run ! grep -q -- '--auth' "$unit"
    # The panel port collides with nothing the stage 0 port checks know.
    grep -q '"panel:\${WG_PANEL_PORT:-}"' "$V2_ROOT/scripts/master-wg"
    body="$(awk '/^ensure_wg_panel\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # DD-140: this backend serves no page files any more; the console pages come from the file backend.
    run ! grep -q -- '--web' "$V2_ROOT/systemd/master-wg-panel.service"
    run ! grep -qE 'index\.html|panel\.css|panel\.js' <<<"$body"
    s6="$(awk '/^stage_6\(\)/,/^ensure_caddy_wg\(\)/' "$V2_ROOT/install.sh")"
    grep -q '^    ensure_wg_panel "\$OS_CHANGED"$' <<<"$s6"
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    # Without a password the gates are the protection: stage 7 proves both on both backends.
    grep -q 'X-Konsol başlığı olmadan HTTP' <<<"$s7"
    grep -q 'yabancı Host ile HTTP' <<<"$s7"
    grep -q 'for gate_port in "\$FILES_PANEL_PORT:/api/state" "\$WG_PANEL_PORT:/api/wg/state"; do' <<<"$s7"
    grep -q 'Konsol sayfası tailnet.ten açılmadı' <<<"$s7"
    grep -q 'master-wg-panel" check' <<<"$s7"
    grep -q 'http://${wg_first_addr}:${WG_PANEL_PORT}/' <<<"$s7"
    # Exported with the runtime, Caddy on the tailnet only, nothing on the WireGuard edge.
    grep -q '"\$REPO_ROOT/panel"' "$V2_ROOT/dev/export-installer.sh"
    run ! grep -q 'WG_PANEL' "$V2_ROOT/templates/Caddyfile.wg"
    # The console page loads nothing from elsewhere and runs no inline code.
    run ! grep -qiE '<style|style=|onclick=|https?://' "$V2_ROOT/console/index.html"
    run ! grep -qE 'https?://' "$V2_ROOT/console/konsol.js" "$V2_ROOT/console/konsol.css"
    grep -q '"X-Konsol": "1"' "$V2_ROOT/console/konsol.js"
    # DD-136/DD-140: network cards and "Arayüz ekle" as its own page.
    grep -q 'id="wg-tabs"' "$V2_ROOT/console/index.html"
    grep -q 'data-view="wgadd"' "$V2_ROOT/console/index.html"
    grep -q 'id="na-create"' "$V2_ROOT/console/index.html"
    # DD-143: her ağ kartında kaldırma var; wg0 ayrıcalıklı değil.
    run ! grep -q 'base ? null' "$V2_ROOT/console/konsol.js"
    grep -q 'arayüzünü kaldır' "$V2_ROOT/console/konsol.js"
    grep -q 'Bu son ağ' "$V2_ROOT/console/konsol.js"
    run ! grep -qiE 'yedek|backup' "$V2_ROOT/console/index.html" "$V2_ROOT/console/konsol.js" "$V2_ROOT/panel/master-wg-panel" "$unit"
    run ! grep -q 'WG_BACKUP_MARK' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh" "$V2_ROOT/../wireguard.command"
    # Stage 0 refuses a wg0 or WebDAV port that a panel network already uses.
    # DD-143: port çakışması artık ağı kuran yerde denetlenir (master-wg net-add).
    grep -q 'UDP $port kullanılıyor' "$V2_ROOT/scripts/master-wg"
    # The console polls every ten seconds and skips the work while the tab is hidden.
    grep -q 'if (document.hidden) return;' "$V2_ROOT/console/konsol.js"
}

files_panel_start() {
    # DD-139: the file panel on a scratch root, with an account written by the WireGuard panel.
    FPANEL="$V2_ROOT/files-panel/master-files-panel"
    mkdir -p "$TMP/fweb" "$TMP/root/Filmler/Kuzey" "$TMP/root/incomplete" "$TMP/outside"
    printf '<!doctype html><title>konsol</title>\n' >"$TMP/fweb/index.html"
    printf 'body{}\n' >"$TMP/fweb/konsol.css"
    printf '/* js */\n' >"$TMP/fweb/konsol.js"
    printf 'gizli\n' >"$TMP/outside/secret.txt"
    ln -s "$TMP/outside" "$TMP/root/kacis"
    printf 'merhaba dünya\n' >"$TMP/root/notlar.txt"
    # DD-141: paylaşım hesabı systemd kimlik bilgisi gibi verilir.
    mkdir -p "$TMP/creds"
    printf 'paylasim:paylas pass\n' >"$TMP/creds/paylasim-auth"
    FPORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    CREDENTIALS_DIRECTORY="$TMP/creds" python3 "$FPANEL" serve --listen "127.0.0.1:$FPORT" --root "$TMP/root" \
        --share .pay --share-credential paylasim-auth \
        --domain ayc --version 2026.08.06-v2-test --temp-dir incomplete >"$TMP/fpanel.log" 2>&1 &
    PANEL_PID=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null "http://127.0.0.1:$FPORT/" && return 0
        sleep 0.1
    done
    cat "$TMP/fpanel.log"
    return 1
}

# fp PATH [curl args...] → HTTP code; body in $TMP/body, headers in $TMP/head (panel header; no password, DD-147).
fp() {
    local path="$1"
    shift
    curl -s -o "$TMP/body" -D "$TMP/head" -w '%{http_code}' -H "Host: panel.ayc" \
        -H 'X-Konsol: 1' "$@" "http://127.0.0.1:$FPORT$path"
}
fpost() {
    fp "$1" -H 'Content-Type: application/json' --data "$2"
}

@test "files panel opens without a password on its own name and refuses everything else" {
    command -v python3 >/dev/null || skip "python3 yok"
    files_panel_start
    local bare=(-s -o /dev/null -w '%{http_code}')
    # DD-147: no password or login prompt. DD-148: the pages are Caddy's, not this backend's.
    [ "$(fp /)" = 404 ]
    run ! grep -qi '^WWW-Authenticate' "$TMP/head"
    [ "$(fp /api/state)" = 200 ]
    grep -qi "^Content-Security-Policy: default-src 'none'" "$TMP/head"
    grep -qi '^Cache-Control: no-store' "$TMP/head"
    grep -qi '^X-Frame-Options: DENY' "$TMP/head"
    awk '/^http:\/\/panel.__LOCAL_DOMAIN__ \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile" >"$TMP/site"
    grep -q 'root \* __CONSOLE_WEB_DIR__' "$TMP/site"
    grep -qx '		file_server' "$TMP/site"
    grep -q "Content-Security-Policy \"default-src 'none'; script-src 'self'" "$TMP/site"
    grep -q 'X-Frame-Options "DENY"' "$TMP/site"
    run ! grep -q 'STATIC = ' "$FPANEL"
    # DNS rebinding and the WireGuard panel's own name are refused.
    [ "$(curl "${bare[@]}" -H 'Host: evil.example' -H 'X-Konsol: 1' "http://127.0.0.1:$FPORT/api/state")" = 403 ]
    [ "$(curl "${bare[@]}" -H 'Host: wg.ayc' -H 'X-Konsol: 1' "http://127.0.0.1:$FPORT/api/state")" = 403 ]
    # CSRF: the API needs the panel header and a same-origin fetch; nothing changes without them.
    [ "$(curl "${bare[@]}" -H 'Host: panel.ayc' "http://127.0.0.1:$FPORT/api/state")" = 403 ]
    [ "$(fp /api/state -H 'Sec-Fetch-Site: cross-site')" = 403 ]
    [ "$(curl "${bare[@]}" -H 'Host: panel.ayc' -H 'Content-Type: application/json' \
        --data '{"path":"","name":"x"}' "http://127.0.0.1:$FPORT/api/mkdir")" = 403 ]
    [ ! -e "$TMP/root/x" ]
    [ "$(fp /api/state -H 'Sec-Fetch-Site: same-origin')" = 200 ]
    python3 - "$TMP/body" "$TMP/root" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["root"] == sys.argv[2] and d["writable"] and d["temp"] == "incomplete", d
assert d["trash"] == {"count": 0, "size": 0} and d["disk"]["total"] >= d["disk"]["free"] > 0, d
PY
    # The stage 7 check: no password.
    run python3 "$FPANEL" check --url "http://127.0.0.1:$FPORT/api/state" --host panel.ayc
    [ "$status" -eq 0 ]
    [ "$output" = "kök $TMP/root, çöpte 0 öge" ]
    run python3 "$FPANEL" check --url "http://127.0.0.1:$FPORT/api/state" --host evil.example
    [ "$status" -ne 0 ]
    case "$output" in *"HTTP 403"*) ;; *) false ;; esac
    run ! grep -qE 'pbkdf2|WWW-Authenticate|auth-credential|locked_out|FAIL_LIMIT' "$FPANEL"
}

@test "files panel stays inside its root and never overwrites or moves a folder into itself" {
    command -v python3 >/dev/null || skip "python3 yok"
    files_panel_start
    [ "$(fp '/api/list?path=')" = 200 ]
    python3 - "$TMP/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
kinds = {e["name"]: e["type"] for e in d["entries"]}
assert kinds == {"Filmler": "dir", "incomplete": "dir", "kacis": "link", "notlar.txt": "file"}, kinds
PY
    # A symlink is listed but never followed; .. and the trash are not reachable by path.
    [ "$(fp '/api/list?path=kacis')" = 400 ]
    [ "$(fp '/api/text?path=kacis%2Fsecret.txt')" = 400 ]
    [ "$(fp '/api/download?path=kacis%2Fsecret.txt')" = 400 ]
    [ "$(fp '/api/list?path=..%2Foutside')" = 400 ]
    [ "$(fp '/api/list?path=Filmler%2F..%2F..')" = 400 ]
    [ "$(fpost /api/move '{"path":"","names":["notlar.txt"],"to":"kacis"}')" = 400 ]
    [ -f "$TMP/root/notlar.txt" ]
    [ ! -e "$TMP/outside/notlar.txt" ]
    mkdir -p "$TMP/root/.cop"
    [ "$(fp '/api/list?path=.cop')" = 403 ]
    [ "$(fpost /api/mkdir '{"path":"","name":".cop2"}')" = 201 ]
    [ "$(fpost /api/mkdir '{"path":"","name":".cop"}')" = 400 ]
    [ "$(fpost /api/rename '{"path":"","name":".cop2","to":".cop"}')" = 400 ]
    [ "$(fpost /api/mkdir '{"path":"","name":"a/b"}')" = 400 ]
    [ "$(fpost /api/mkdir '{"path":"","name":".."}')" = 400 ]
    # No operation overwrites: the existing target keeps its content.
    printf 'eski\n' >"$TMP/root/Filmler/notlar.txt"
    [ "$(fpost /api/rename '{"path":"","name":".cop2","to":"notlar.txt"}')" = 409 ]
    [ "$(fpost /api/move '{"path":"","names":["notlar.txt"],"to":"Filmler"}')" = 409 ]
    grep -qx 'eski' "$TMP/root/Filmler/notlar.txt"
    grep -qx 'merhaba dünya' "$TMP/root/notlar.txt"
    [ "$(fpost /api/move '{"path":"","names":["Filmler"],"to":"Filmler/Kuzey"}')" = 400 ]
    [ "$(fpost /api/move '{"path":"","names":["Filmler"],"to":""}')" = 400 ]
    [ "$(fpost /api/rename '{"path":"Filmler","name":"notlar.txt","to":"eski.txt"}')" = 200 ]
    [ "$(fpost /api/move '{"path":"","names":["notlar.txt",".cop2"],"to":"Filmler/Kuzey"}')" = 200 ]
    [ -f "$TMP/root/Filmler/Kuzey/notlar.txt" ]
    [ -d "$TMP/root/Filmler/Kuzey/.cop2" ]
    [ -f "$TMP/root/Filmler/eski.txt" ]
    grep -q 'dosya: konsol 127.0.0.1 tasi ' "$TMP/fpanel.log"
    grep -q 'hedefte zaten var; üzerine yazılmaz" -> hata' "$TMP/fpanel.log"
}

@test "files panel moves deleted items to the trash, restores them to where they were and empties only on onayla" {
    command -v python3 >/dev/null || skip "python3 yok"
    files_panel_start
    printf 'film\n' >"$TMP/root/Filmler/Kuzey/film.mkv"
    [ "$(fpost /api/trash '{"path":"Filmler","names":["Kuzey"]}')" = 200 ]
    [ "$(fpost /api/trash '{"path":"","names":["notlar.txt","kacis"]}')" = 200 ]
    [ ! -e "$TMP/root/Filmler/Kuzey" ]
    # Trashing (and later purging) a symlink never touches its target.
    [ -f "$TMP/outside/secret.txt" ]
    [ "$(fp '/api/list?path=')" = 200 ]
    run ! grep -q '"\.cop"' "$TMP/body"
    [ "$(fp /api/trash)" = 200 ]
    python3 - "$TMP/body" >"$TMP/ids" <<'PY'
import json, sys
items = {i["name"]: i for i in json.load(open(sys.argv[1]))["items"]}
assert set(items) == {"Kuzey", "notlar.txt", "kacis"}, items
assert items["Kuzey"]["from"] == "Filmler" and items["Kuzey"]["size"] == 5, items["Kuzey"]
assert items["notlar.txt"]["from"] == "" and items["notlar.txt"]["type"] == "file"
print(items["Kuzey"]["id"], items["notlar.txt"]["id"], items["kacis"]["id"])
PY
    local kuzey notlar kacis
    read -r kuzey notlar kacis <"$TMP/ids"
    [ "$(fp /api/state)" = 200 ]
    grep -q '"trash": {"count": 3' "$TMP/body"
    # Back to its folder; a name that is taken meanwhile gets a number, nothing is overwritten.
    printf 'yeni\n' >"$TMP/root/notlar.txt"
    local req="{\"ids\":[\"$kuzey\",\"$notlar\"]}"
    [ "$(fpost /api/trash/restore "$req")" = 200 ]
    [ -f "$TMP/root/Filmler/Kuzey/film.mkv" ]
    grep -qx 'yeni' "$TMP/root/notlar.txt"
    grep -qx 'merhaba dünya' "$TMP/root/notlar (2).txt"
    # When the original folder is gone, the item comes back to the root.
    [ "$(fpost /api/trash '{"path":"Filmler/Kuzey","names":["film.mkv"]}')" = 200 ]
    rm -rf "$TMP/root/Filmler"
    [ "$(fp /api/trash)" = 200 ]
    local film
    film="$(python3 -c 'import json,sys; print([i["id"] for i in json.load(open(sys.argv[1]))["items"] if i["name"] == "film.mkv"][0])' "$TMP/body")"
    req="{\"ids\":[\"$film\"]}"
    [ "$(fpost /api/trash/restore "$req")" = 200 ]
    [ -f "$TMP/root/film.mkv" ]
    req="{\"ids\":[\"$kacis\"]}"
    [ "$(fpost /api/trash/purge "$req")" = 200 ]
    [ -f "$TMP/outside/secret.txt" ]
    [ "$(fpost /api/trash '{"path":"","names":["film.mkv"]}')" = 200 ]
    [ "$(fpost /api/trash/restore '{"ids":["../../etc"]}')" = 400 ]
    [ "$(fpost /api/trash/empty '{"confirm":"evet"}')" = 400 ]
    [ -n "$(ls -A "$TMP/root/.cop")" ]
    [ "$(fpost /api/trash/empty '{"confirm":" ONAYLA "}')" = 200 ]
    [ -z "$(ls -A "$TMP/root/.cop")" ]
    grep -q 'dosya: konsol 127.0.0.1 cop-bosalt 1 -> ok' "$TMP/fpanel.log"
}

@test "files panel shows text in its encoding, only the first megabyte and never a binary; downloads stay same-origin" {
    command -v python3 >/dev/null || skip "python3 yok"
    files_panel_start
    printf 'Işıklar çıktığında\n' | iconv -f UTF-8 -t CP1254 >"$TMP/root/alt.tr.srt"
    printf 'caf\xe9 \xdb\xdb\n' >"$TMP/root/film.nfo"
    printf 'bin\000ary' >"$TMP/root/film.mkv"
    python3 -c 'import sys; open(sys.argv[1], "wb").write(("ş" * 600000).encode())' "$TMP/root/buyuk.log"
    [ "$(fp '/api/text?path=alt.tr.srt')" = 200 ]
    python3 - "$TMP/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["detected"] == "cp1254" and d["text"] == "Işıklar çıktığında\n" and not d["truncated"], d
PY
    [ "$(fp '/api/text?path=alt.tr.srt&enc=utf-8')" = 200 ]
    grep -q '\\ufffd\|�' "$TMP/body"
    [ "$(fp '/api/text?path=film.nfo')" = 200 ]
    grep -q '"detected": "cp437"' "$TMP/body"
    grep -q '█' "$TMP/body"
    [ "$(fp '/api/text?path=notlar.txt')" = 200 ]
    grep -q '"detected": "utf-8"' "$TMP/body"
    [ "$(fp '/api/text?path=buyuk.log')" = 200 ]
    python3 - "$TMP/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# 1 MiB cut in the middle of a two-byte letter is still UTF-8.
assert d["truncated"] and d["size"] == 1200000 and d["detected"] == "utf-8" and len(d["text"]) == 524288, (d["size"], len(d["text"]))
PY
    [ "$(fp '/api/text?path=film.mkv')" = 415 ]
    [ "$(fp '/api/text?path=Filmler')" = 400 ]
    [ "$(fp '/api/text?path=notlar.txt&enc=latin9')" = 400 ]
    # A download is an attachment, needs no panel header, and a cross-site request is refused.
    [ "$(curl -s -o "$TMP/body" -D "$TMP/head" -w '%{http_code}' -H 'Host: panel.ayc' \
        "http://127.0.0.1:$FPORT/api/download?path=notlar.txt")" = 200 ]
    grep -qx 'merhaba dünya' "$TMP/body"
    grep -qi "^Content-Disposition: attachment; filename=\"notlar.txt\"; filename\*=UTF-8''notlar.txt" "$TMP/head"
    grep -qi '^Content-Type: application/octet-stream' "$TMP/head"
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: panel.ayc' -H 'Sec-Fetch-Site: cross-site' \
        "http://127.0.0.1:$FPORT/api/download?path=notlar.txt")" = 403 ]
    grep -q 'dosya: konsol 127.0.0.1 indir "notlar.txt" -> ok' "$TMP/fpanel.log"
}

@test "files panel shares a folder as a link in the share root, sweeps expired ones and keeps the rest of the root out" {
    command -v python3 >/dev/null || skip "python3 yok"
    files_panel_start
    # Paylaşımlar kendi köküne göreli bir bağlantı olarak girer; dosya kopyalanmaz.
    [ "$(fpost /api/paylas '{"path":"Filmler/Kuzey","days":7}')" = 201 ]
    run python3 -c 'import json, sys
item = json.load(open(sys.argv[1]))["item"]
assert item["name"] == "Kuzey" and item["path"] == "Filmler/Kuzey" and item["type"] == "dir", item
assert item["expires"] - item["created"] == 7 * 86400, item' "$TMP/body"
    [ "$status" -eq 0 ]
    [ "$(readlink "$TMP/root/.pay/w/Kuzey")" = "../../Filmler/Kuzey" ]
    [ -d "$TMP/root/.pay/w/Kuzey" ]
    [ "$(fp /api/paylas)" = 200 ]
    run python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
assert d["host"] == "http://paylas.ayc" and d["user"] == "paylasim" and d["pass"] == "paylas pass", d
assert [i["name"] for i in d["items"]] == ["Kuzey"], d' "$TMP/body"
    [ "$status" -eq 0 ]
    # Aynı öge iki kez paylaşılmaz; ad çakışması numaralanır.
    [ "$(fpost /api/paylas '{"path":"Filmler/Kuzey","days":0}')" = 409 ]
    mkdir -p "$TMP/root/Diziler/Kuzey"
    [ "$(fpost /api/paylas '{"path":"Diziler/Kuzey","days":0}')" = 201 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["item"]["name"] == "Kuzey-2"' "$TMP/body"
    # Kök, çöp ve paylaşım klasörünün kendisi paylaşılamaz; kökten çıkılamaz.
    [ "$(fpost /api/paylas '{"path":"","days":0}')" = 400 ]
    [ "$(fpost /api/paylas '{"path":".cop","days":0}')" = 403 ]
    [ "$(fpost /api/paylas '{"path":".pay","days":0}')" = 403 ]
    [ "$(fpost /api/paylas '{"path":"../etc","days":0}')" = 400 ]
    [ "$(fpost /api/paylas '{"path":"yok-boyle","days":0}')" = 404 ]
    [ "$(fpost /api/paylas '{"path":"Filmler","days":-3}')" = 400 ]
    # Paylaşım klasörü dosya listesinde ve gezinmede görünmez.
    [ "$(fp '/api/list?path=')" = 200 ]
    run ! grep -q '"\.pay"' "$TMP/body"
    [ "$(fp '/api/list?path=.pay')" = 403 ]
    # Süresi dolan paylaşım listelemede düşer ve bağlantısı silinir.
    python3 -c 'import json, sys, time
path = sys.argv[1]
data = json.load(open(path))
data["items"][0]["expires"] = int(time.time()) - 10
json.dump(data, open(path, "w"), ensure_ascii=False)' "$TMP/root/.pay/kayit.json"
    [ "$(fp /api/paylas)" = 200 ]
    python3 -c 'import json, sys; assert [i["name"] for i in json.load(open(sys.argv[1]))["items"]] == ["Kuzey-2"]' "$TMP/body"
    [ ! -e "$TMP/root/.pay/w/Kuzey" ]
    [ -d "$TMP/root/Filmler/Kuzey" ]
    # Çıkarmak yalnız bağlantıyı siler.
    [ "$(fpost /api/paylas/kaldir '{"name":"Kuzey-2"}')" = 200 ]
    [ ! -e "$TMP/root/.pay/w/Kuzey-2" ]
    [ -d "$TMP/root/Diziler/Kuzey" ]
    [ "$(fpost /api/paylas/kaldir '{"name":"Kuzey-2"}')" = 404 ]
    [ "$(fpost /api/paylas/kaldir '{"name":"../x"}')" = 400 ]
    # Kayıtta olmayan bir bağlantı elle konsa da temizlenir.
    ln -s ../../Filmler "$TMP/root/.pay/w/elle"
    [ "$(fp /api/paylas)" = 200 ]
    [ ! -e "$TMP/root/.pay/w/elle" ]
    grep -q 'konsol 127.0.0.1 paylas "Filmler/Kuzey -> Kuzey (7 gün)" -> ok' "$TMP/fpanel.log"
    grep -q 'konsol 127.0.0.1 paylas-kaldir "Kuzey-2" -> ok' "$TMP/fpanel.log"
    run ! grep -q 'paylas pass' "$TMP/fpanel.log"
}

@test "files panel takes an upload into the folder, never over an existing name and leaves no half file" {
    # DD-145: the body is the file itself; it is written under a temp name and renamed.
    files_panel_start
    printf 'yuk %s' "$(seq 1 200 | tr -d '\n')" >"$TMP/payload.bin"
    [ "$(fp "/api/upload?path=Filmler&name=arsiv.bin" --data-binary "@$TMP/payload.bin")" = 201 ]
    cmp -s "$TMP/payload.bin" "$TMP/root/Filmler/arsiv.bin"
    [ "$(stat -f '%Lp' "$TMP/root/Filmler/arsiv.bin" 2>/dev/null || stat -c '%a' "$TMP/root/Filmler/arsiv.bin")" = 664 ]
    grep -q 'konsol 127.0.0.1 yükle "Filmler/arsiv.bin" -> ok' "$TMP/fpanel.log"
    # Aynı ad ikinci kez: üzerine yazılmaz, dosya bozulmaz.
    printf 'baska icerik' >"$TMP/other.bin"
    [ "$(fp "/api/upload?path=Filmler&name=arsiv.bin" --data-binary "@$TMP/other.bin")" = 409 ]
    cmp -s "$TMP/payload.bin" "$TMP/root/Filmler/arsiv.bin"
    # Geçici ad kalmaz.
    [ "$(ls -A "$TMP/root/Filmler" | grep -c '^\.yukleniyor-')" = 0 ]
    # Geçersiz ad ve gövdesiz istek reddedilir; çöp ve paylaşım klasörü hedef olamaz.
    [ "$(fp "/api/upload?path=Filmler&name=..%2Fkacak" --data-binary "@$TMP/other.bin")" = 400 ]
    [ "$(fp "/api/upload?path=Filmler&name=bos.bin" -X POST -H 'Content-Length: 0')" = 411 ]
    [ "$(fp "/api/upload?path=.cop&name=x.bin" --data-binary "@$TMP/other.bin")" = 403 ]
    [ "$(fp "/api/upload?path=.pay&name=x.bin" --data-binary "@$TMP/other.bin")" = 403 ]
    # A refusal decided before the body is read still reads (drains) the body first, so a
    # proxy sees the real answer instead of a reset connection (Caddy turned that into 502).
    head -c 8388608 /dev/zero >"$TMP/big.bin"
    [ "$(fp "/api/upload?path=.cop&name=x.bin" --data-binary "@$TMP/big.bin")" = 403 ]
    [ "$(fp "/api/upload?path=Filmler&name=arsiv.bin" --data-binary "@$TMP/big.bin")" = 409 ]
    grep -q '“arsiv.bin” zaten var' "$TMP/body"
    grep -q 'self.drain(length)' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'UPLOAD_DRAIN_MAX = ' "$V2_ROOT/files-panel/master-files-panel"
    # The console does not even send a file whose name is already in the folder.
    grep -q 'state: clash ? "err" : "wait", error: clash ? "zaten var; üzerine yazılmaz" : ""' "$V2_ROOT/console/konsol.js"
    # Yükleme kilidi bütün akış boyunca tutulmaz: yalnız son taşıma kilitli.
    grep -q 'self.run(user, "yükle", put, lock=False' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'with self.lock:' "$V2_ROOT/files-panel/master-files-panel"
}

@test "console uploads into the list itself, selects many rows and searches the folder" {
    # DD-145: ayrı yükleme alanı yok; hedef liste, ilerleme satırın içinde.
    local js="$V2_ROOT/console/konsol.js" css="$V2_ROOT/console/konsol.css"
    grep -q 'xhr.open("POST", `/api/upload?path=${enc(u.path)}&name=${enc(u.name)}`)' "$js"
    grep -q 'xhr.setRequestHeader("X-Konsol", "1")' "$js"
    grep -q 'xhr.upload.addEventListener("progress"' "$js"
    # Bırakma hedefi liste; perde ya da ayrı kuyruk kartı yok.
    grep -q 'panel.addEventListener("drop"' "$js"
    grep -q '"tr up"' "$js" || grep -q 'class: "tr up' "$js"
    grep -q '\.fs-t\.dragging' "$css"
    grep -q '\.droptip' "$css"
    run ! grep -qi 'dropveil\|queue-card' "$js" "$css"
    # Çoklu seçim tek istekte çöpe/taşımaya gider.
    grep -q 'names: items.map((i) => i.name)' "$js"
    [ "$(grep -c 'names: items.map((i) => i.name)' "$js")" -ge 2 ]
    # Arama yalnız satırları yeniler; klasör değişince seçim ve arama sıfırlanır.
    grep -q 'oninput: (e) => { fsQuery = e.target.value; renderRows(); updateMeta(); }' "$js"
    grep -q 'fsSel.clear();' "$js"
    # qBittorrent'in yazdığı klasör seçilemez.
    grep -q 'const locked = inTemp(here) || inTemp(pathText(fsPath));' "$js"
    grep -q 'locked ? null : h("button", { type: "button", class: "chk"' "$js"
    # Kısayol sütunu kökü ve üst klasörleri arka uçtan alır.
    grep -q 'fsRootDirs = r.entries.filter((e) => e.type === "dir")' "$js"
    grep -q '\.fsrail' "$css"
    grep -qx '          <nav class="fsrail" id="fs-rail" aria-label="Klasörler"></nav>' "$V2_ROOT/console/index.html"
}

@test "installer lays out modules without installing any, and reapplies only running ones" {
    # DD-148: the installer writes module files and an empty registry; Konsol installs.
    grep -qx 'MODULES_FILE="/etc/master-stack/moduller"' "$V2_ROOT/config/defaults.env"
    grep -qx 'MODULES_DIR="/usr/local/share/master-stack/moduller"' "$V2_ROOT/config/defaults.env"
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'MODULES_FILE=\$MODULES_FILE'
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'MODULES_DIR=\$MODULES_DIR'
    grep -qF '"$REPO_ROOT/modules"' "$V2_ROOT/dev/export-installer.sh"
    stage4="$(awk '/^stage_4\(\)/,/^stage_5\(\)/' "$V2_ROOT/install.sh")"
    grep -qF 'atomic_write "$SBIN_DIR/master-modul" 0755' <<<"$stage4"
    grep -qx '    ensure_module_files' <<<"$stage4"
    body="$(awk '/^ensure_module_files\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qF 'render_template "$V2_ROOT/modules/unpackerr/compose.yaml" "$MODULES_DIR/unpackerr/compose.yaml" 0644' <<<"$body"
    grep -qF 'atomic_write "$MODULES_FILE" 0644 </dev/null' <<<"$body"
    # The installer never installs, stops or removes a module on its own.
    [ "$(grep -cE 'master-modul" (kur|kaldir|durdur)' "$V2_ROOT/install.sh")" -eq 0 ]
    # reapply_modules: a changed module file restarts a running module only.
    eval "$(awk '/^reapply_modules\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    mkdir -p "$TMP/sbin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$TMP" >"$TMP/sbin/master-modul"
    chmod +x "$TMP/sbin/master-modul"
    log() { :; }
    SBIN_DIR="$TMP/sbin"
    MODULES_FILE="$TMP/reg"
    MODULES_CHANGED=" unpackerr"
    printf 'unpackerr\tcalisiyor\n' >"$TMP/reg"
    reapply_modules
    grep -qx 'baslat unpackerr' "$TMP/calls"
    rm -f "$TMP/calls"
    printf 'unpackerr\tdurduruldu\n' >"$TMP/reg"
    reapply_modules
    [ ! -e "$TMP/calls" ]
    : >"$TMP/reg"
    reapply_modules
    [ ! -e "$TMP/calls" ]
    MODULES_CHANGED=""
    printf 'unpackerr\tcalisiyor\n' >"$TMP/reg"
    reapply_modules
    [ ! -e "$TMP/calls" ]
    awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh" |
        awk '/docker compose up -d --remove-orphans/ {a = NR} /^    reapply_modules$/ {b = NR} END {exit !(a && b && a < b)}'
    # The root backend runs module work; its unit knows the helper.
    grep -qF -- '--master-modul __SBIN_DIR__/master-modul' "$V2_ROOT/systemd/master-wg-panel.service"
}

@test "console shows the Modüller page from the module API" {
    local js="$V2_ROOT/console/konsol.js" html="$V2_ROOT/console/index.html"
    # Side navigation and the phone's bottom bar both link the page.
    [ "$(grep -c 'data-route="moduller"' "$html")" -eq 2 ]
    grep -q 'grid-template-columns: repeat(5, minmax(0, 1fr)); position: fixed;' "$V2_ROOT/console/konsol.css"
    grep -q '<section data-view="moduller"' "$html"
    grep -q 'id="mod-grid"' "$html"
    grep -q 'id="cf-extra"' "$html"
    grep -qF 'api("/api/konsol/moduller")' "$js"
    grep -qF 'post(`/api/konsol/moduller/${enc(m.id)}/${action}`, { veri: !!veri })' "$js"
    grep -qF 'if (MODS.some((m) => m.busy)) modTimer = setTimeout(loadModules, 1500);' "$js"
    # Until the unit writes its first step, the card shows the requested action, not the previous one.
    grep -qF 'if (!p || p.action !== want || p.step === "bitti" || p.step === "hata") m.progress = { action: want, step: "0", total: 0, text: "" };' "$js"
    grep -qF 'moduller: { title: "Modüller"' "$js"
    grep -qF 'unpackerr: { name: "Arşiv açıcı"' "$js"
    grep -q '^\.base-list' "$V2_ROOT/console/konsol.css"
    grep -q '^\.rt-chip' "$V2_ROOT/console/konsol.css"
}

@test "installer wires the share WebDAV: read-only rclone on the share root, one account, tailnet name, hidden from Infuse" {
    local compose="$V2_ROOT/templates/compose.yaml" unit="$V2_ROOT/systemd/master-files-panel.service" body s7 line
    awk '/^  paylasim:$/,/^networks:$/' "$compose" >"$TMP/svc"
    for line in '      - __SERVER_ROOT__/__SHARE_DIR__/w' '      - --htpasswd=/run/secrets/paylasim_htpasswd' \
        '      - --copy-links' '      - --read-only' '    read_only: true' \
        '      - "127.0.0.1:__SHARE_PORT__:8080"' '      - __SERVER_ROOT__:__SERVER_ROOT__:ro'; do
        grep -qx "$line" "$TMP/svc"
    done
    grep -q 'image: __RCLONE_IMAGE__' "$TMP/svc"
    run ! grep -q 'cap_add' "$TMP/svc"
    # DD-144: the trash and the share root sit outside the downloads folder, so the
    # containers that mount only downloads cannot see them; no tmpfs curtain is left.
    run ! grep -q 'size=16k' "$compose"
    grep -qx '      - __DOWNLOADS_PATH__:/downloads' "$V2_ROOT/modules/unpackerr/compose.yaml"
    awk '/^  qbittorrent:$/,/^  paylasim:$/' "$compose" | grep -qx '      - __DOWNLOADS_PATH__:/downloads'
    grep -q 'test ! -e /downloads/\${FILES_PANEL_TRASH} && test ! -e /downloads/\${SHARE_DIR}' "$V2_ROOT/install.sh"
    grep -q "test ! -e /downloads/.cop && test ! -e /downloads/.pay" "$V2_ROOT/scripts/master-modul"
    # Tek hesap: htpasswd rclone için, düz kopya yalnız Konsol'un göstermesi için.
    grep -qx 'SHARE_PORT="61010"' "$V2_ROOT/config/defaults.env"
    grep -qx 'SHARE_DIR=".pay"' "$V2_ROOT/config/defaults.env"
    grep -qx 'SHARE_USER=' "$V2_ROOT/config/kurulum.env.example"
    grep -qx 'SHARE_PASS=' "$V2_ROOT/config/kurulum.env.example"
    grep -q 'SHARE_USER SHARE_PASS' "$V2_ROOT/install.sh"
    grep -q 'validate_account "Paylaşım"' "$V2_ROOT/install.sh"
    body="$(awk '/^ensure_share_account\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'htpasswd -i -B "\$tmp" "\$SHARE_NEW_USER"' <<<"$body"
    grep -q 'unset SHARE_NEW_PASS' <<<"$body"
    grep -q 'docker restart paylasim' <<<"$body"
    # Dosya arka ucu paylaşımı yönetir ve hesabı yalnız kimlik bilgisi olarak görür.
    grep -q -- '--share __SHARE_DIR__ --share-credential paylasim-auth' "$unit"
    grep -qx 'LoadCredential=paylasim-auth:__SHARE_CRED_FILE__' "$unit"
    # Tailnet adı ve portu; WireGuard kenarında yok.
    # DD-141: ada ek olarak IP:port adresi (Infuse adı çözemez; DD-98'deki WebDAV ile aynı neden).
    grep -q '^http://paylas.__LOCAL_DOMAIN__, http://{\$TAILSCALE_IPV4}:{\$SHARE_PORT} {$' "$V2_ROOT/templates/Caddyfile"
    grep -A1 '^http://paylas.__LOCAL_DOMAIN__, http://{\$TAILSCALE_IPV4}:{\$SHARE_PORT} {$' "$V2_ROOT/templates/Caddyfile" | grep -q 'reverse_proxy 127.0.0.1:__SHARE_PORT__$'
    grep -q 'TAILSCALE_IPV4="\$TAILSCALE_IPV4" SHARE_PORT="\$SHARE_PORT"' "$V2_ROOT/install.sh"
    grep -q '"share": {"port": num_or(env.get("SHARE_PORT"), 0)}' "$V2_ROOT/panel/master-wg-panel"
    grep -q 'function shareIpUrl' "$V2_ROOT/console/konsol.js"
    grep -q 'Paylaşım ${TAILSCALE_IPV4}:${SHARE_PORT} adresinde yanıt' "$V2_ROOT/install.sh"
    grep -qx 'interface-name=paylas.__LOCAL_DOMAIN__,__TAILSCALE_IF__' "$V2_ROOT/templates/dnsmasq.conf"
    run ! grep -q 'SHARE_' "$V2_ROOT/templates/Caddyfile.wg"
    grep -q '"paylasim:${SHARE_PORT:-}"' "$V2_ROOT/scripts/master-wg"
    grep -q '"SHARE_PORT")}' "$V2_ROOT/panel/master-wg-panel"
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'SHARE_PORT=\$SHARE_PORT'
    # Aşama 7: girişsiz 401, kök sahibi, salt okunurluk ve gizli klasör.
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -q "Paylaşım WebDAV'ı girişsiz yanıt" <<<"$s7"
    grep -q 'Paylaşım kökü' <<<"$s7"
    grep -q 'test ! -e /downloads/\${SHARE_DIR}' <<<"$s7"
    awk '/^assert_share_readonly_runtime\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'docker inspect paylasim'
    awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q '"\$SERVER_ROOT/\$SHARE_DIR/w"'
    # Konsol sayfası paylaşımı tek hesapla anlatır ve parolayı yalnız istenince gösterir.
    grep -q '/api/paylas' "$V2_ROOT/console/konsol.js"
    grep -q 'showPass' "$V2_ROOT/console/konsol.js"
}

@test "installer wires the files panel: downloads uid, sandbox, no password, tailnet name, hidden trash, stage 7 proof" {
    local unit="$V2_ROOT/systemd/master-files-panel.service" body s6 s7 line
    for line in 'User=__FILES_PANEL_USER__' 'Group=__FILES_PANEL_GROUP__' 'NoNewPrivileges=true' 'CapabilityBoundingSet=' \
        'ProtectSystem=strict' 'ReadWritePaths=__SERVER_ROOT__' 'ProtectHome=true' 'PrivateTmp=true' 'PrivateDevices=true' \
        'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' 'UMask=0002'; do
        grep -qx "$line" "$unit"
    done
    grep -q -- '--listen 127.0.0.1:__FILES_PANEL_PORT__ --root __SERVER_ROOT__' "$unit"
    grep -q -- '--root __SERVER_ROOT__ --trash __FILES_PANEL_TRASH__' "$unit"
    run ! grep -q -- '--web' "$unit"
    run ! grep -qE 'panel-auth|--auth' "$unit"
    [ "$(grep -c '^ReadWritePaths=' "$unit")" -eq 1 ]
    run ! grep -qE '^User=(root|0)$|AF_NETLINK|/etc/wireguard' "$unit"
    grep -qx 'FILES_PANEL_PORT="61009"' "$V2_ROOT/config/defaults.env"
    grep -qx 'FILES_PANEL_TRASH=".cop"' "$V2_ROOT/config/defaults.env"
    # No account at all (DD-147).
    run ! grep -q 'FILES_PANEL\|DOSYA' "$V2_ROOT/config/kurulum.env.example"
    run ! grep -qE '^INPUT_KEYS=.*(FILES|DOSYA)' "$V2_ROOT/install.sh"
    body="$(awk '/^ensure_files_panel\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # systemd needs a user entry for the downloads uid: an existing name, else a system account without login.
    grep -q 'getent passwd "\$DOWNLOADS_UID"' <<<"$body"
    grep -q 'getent group "\$DOWNLOADS_GID"' <<<"$body"
    grep -q 'useradd --system --uid "\$DOWNLOADS_UID" --gid "\$DOWNLOADS_GID" --no-create-home' <<<"$body"
    grep -q -- '--shell /usr/sbin/nologin "\$DOWNLOADS_ACCOUNT"' <<<"$body"
    grep -qx 'DOWNLOADS_ACCOUNT="master-downloads"' "$V2_ROOT/config/defaults.env"
    grep -q 'Session\\\\TempPath' <<<"$body"
    # DD-140: this backend serves the console pages.
    pages="$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    for f in index.html konsol.css konsol.js; do grep -q "$f" <<<"$pages"; [ -f "$V2_ROOT/console/$f" ]; done
    run ! grep -q 'index.html' <<<"$body"
    grep -q 'CONSOLE_WEB_DIR="\$CONSOLE_WEB_DIR"' <<<"$(awk '/^stage_6\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx 'CONSOLE_WEB_DIR="/usr/local/share/master-stack/konsol"' "$V2_ROOT/config/defaults.env"
    grep -q '"\$REPO_ROOT/console"' "$V2_ROOT/dev/export-installer.sh"
    s6="$(awk '/^stage_6\(\)/,/^ensure_caddy_wg\(\)/' "$V2_ROOT/install.sh")"
    grep -q '^    ensure_files_panel "\$OS_CHANGED"$' <<<"$s6"
    # The port collides with nothing: stage 0, master-wg net-add and the wg panel know it.
    grep -q '"dosya-paneli:\${FILES_PANEL_PORT:-}"' "$V2_ROOT/scripts/master-wg"
    grep -q '"dosya-paneli:${FILES_PANEL_PORT:-}"' "$V2_ROOT/scripts/master-wg"
    grep -q '"FILES_PANEL_PORT", "SHARE_PORT")}' "$V2_ROOT/panel/master-wg-panel"
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'FILES_PANEL_PORT=\$FILES_PANEL_PORT'
    # Tailnet only through Caddy; nothing on the WireGuard edge.
    # DD-140: one address; /api/wg/* to the WireGuard backend, the rest (pages included) here.
    awk '/^http:\/\/panel.__LOCAL_DOMAIN__ \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile" >"$TMP/site"
    grep -q '@kok path /api/wg/\* /api/konsol/\*' "$TMP/site"
    grep -q 'handle @kok {' "$TMP/site"
    grep -q 'handle /api/\* {' "$TMP/site"
    grep -q 'reverse_proxy 127.0.0.1:__WG_PANEL_PORT__$' "$TMP/site"
    grep -q 'reverse_proxy 127.0.0.1:__FILES_PANEL_PORT__$' "$TMP/site"
    grep -q '^http://wg.__LOCAL_DOMAIN__, http://dosya.__LOCAL_DOMAIN__, http://file.__LOCAL_DOMAIN__ {$' "$V2_ROOT/templates/Caddyfile"
    grep -q 'redir http://panel.__LOCAL_DOMAIN__{uri} 302' "$V2_ROOT/templates/Caddyfile"
    grep -qx 'interface-name=panel.__LOCAL_DOMAIN__,__TAILSCALE_IF__' "$V2_ROOT/templates/dnsmasq.conf"
    run ! grep -q 'FILES_PANEL' "$V2_ROOT/templates/Caddyfile.wg"
    # DD-144: the trash sits beside the downloads folder, not inside it, so no container
    # that mounts downloads can reach it and the tmpfs curtain is gone.
    run ! grep -q '__FILES_PANEL_TRASH__:ro,size=16k' "$V2_ROOT/templates/compose.yaml"
    grep -q 'test ! -e /downloads/\${FILES_PANEL_TRASH}' "$V2_ROOT/install.sh"
    awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q '"\$SERVER_ROOT/\$FILES_PANEL_TRASH" \\'
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'panele yönlenmedi' <<<"$s7"
    grep -q 'master-files-panel" check' <<<"$s7"
    grep -q 'ps -o uid= -p' <<<"$s7"
    grep -q 'http://${wg_first_addr}:${FILES_PANEL_PORT}/' <<<"$s7"
    grep -q 'test ! -e /downloads/\${FILES_PANEL_TRASH}' <<<"$s7"
    grep -q '"\$REPO_ROOT/files-panel"' "$V2_ROOT/dev/export-installer.sh"
    # The console page inserts names only as text; the one innerHTML builds icons from a fixed table.
    [ "$(grep -c 'innerHTML' "$V2_ROOT/console/konsol.js")" -eq 1 ]
    grep -q 't.innerHTML = .<svg' "$V2_ROOT/console/konsol.js"
    # One page, no login: both backends answer only on panel.<domain> and log the same actor.
    grep -q 'ACTOR = "konsol"' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'ACTOR = "konsol"' "$V2_ROOT/panel/master-wg-panel"
    grep -q 'API_HEADER = "X-Konsol"' "$V2_ROOT/files-panel/master-files-panel" "$V2_ROOT/panel/master-wg-panel"
    grep -q 'hosts.add("panel.%s"' "$V2_ROOT/files-panel/master-files-panel" "$V2_ROOT/panel/master-wg-panel"
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
[ "$1" = strip ] && grep -vE '^(Address|MTU) = |^#' "${WG0_CONF%/*}/$2.conf"
EOF
    cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
case "$*" in *"${SYSTEMCTL_FAIL:-@none@}"*) exit 1 ;; esac
[ "$1" != is-active ] || [ "${WG_ACTIVE:-1}" = 1 ]
EOF
    printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/flock"
    printf '#!/bin/bash\nprintf "QR:"; cat\n' >"$TMP/bin/qrencode"
    chmod +x "$TMP/bin"/*
    export MOCK_LOG="$TMP/calls" MOCK_DIR="$TMP"
}

# DD-143: ağlar kayıtta yaşar; fikstür wg0'ı kayda yazar (kurulum değil, master-wg kurar).
wg_state_fixture() {
    mkdir -p "$TMP/etc/wireguard/clients-wg0" "$TMP/run"
    cat >"$TMP/state.env" <<EOF
V2_VERSION=2026.08.06-v2-test
WG_CONF_DIR=$TMP/etc/wireguard
WG_CLIENTS_DIR=$TMP/etc/wireguard/clients
WG_ADDR_BASE4=10.8
WG_ADDR_BASE6=fdcc:ad94:bacf:61a4
WG_PORT_DEFAULT=61001
WG_ENDPOINT_HOST=203.0.113.7
WG_CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
RUNTIME_DIR=$TMP/run
WG_MTU=1420
WG_NETWORKS_FILE=$TMP/etc/wireguard/networks
WG_NETWORKS_MAX=9
WG_PANEL_PORT=61008
SSH_PUBLIC_PORT=22
TORRENT_PUBLIC_PORT=61005
SHARE_PORT=61010
DOZZLE_UI_PORT=61002
TORRENT_UI_PORT=61006
TAILSCALE_UDP_PORT=41641
EOF
    printf 'wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\n' \
        >"$TMP/etc/wireguard/networks"
    export WG0_CONF="$TMP/etc/wireguard/wg0.conf"
    printf '# header\n[Interface]\nAddress = 10.8.0.1/24, fdcc:ad94:bacf:61a4::1/112\nListenPort = 61001\nMTU = 1420\nPrivateKey = SRVKEY%s=\n' \
        "$(printf 's%.0s' {1..37})" >"$WG0_CONF"
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
    profile="$TMP/etc/wireguard/clients-wg0/iphone.conf"
    mode="$(stat -c %a "$profile" 2>/dev/null || stat -f %Lp "$profile")"
    [ "$mode" = 600 ]
    grep -qx 'PrivateKey = PRIV01kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk=' "$profile"
    grep -qx 'Address = 10.8.0.2/32, fdcc:ad94:bacf:61a4::2/128' "$profile"
    grep -qx 'MTU = 1380' "$profile"
    grep -qx 'DNS = 9.9.9.9, 149.112.112.112' "$profile"
    grep -qx 'PersistentKeepalive = 21' "$profile"
    grep -qx 'Endpoint = 203.0.113.7:61001' "$profile"
    grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0' "$profile"
    # The server key's public half is in the profile; the client key is not in wg0.conf.
    grep -q '^PublicKey = PUBFEIXRL' "$profile"
    conf="$(cat "$WG0_CONF")"
    grep -qx '# peer: iphone' <<<"$conf"
    grep -qx 'AllowedIPs = 10.8.0.2/32, fdcc:ad94:bacf:61a4::2/128' <<<"$conf"
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
    grep -qx 'Address = 10.8.0.3/32, fdcc:ad94:bacf:61a4::3/128' <<<"$output"
    run master_wg qr ipad
    case "$output" in "QR:[Interface]"*) ;; *) false ;; esac
    # list: name, address, handshake, rx, tx, stored profile.
    pub="$(awk -F' = ' '/^# peer: ipad$/ {f = 1} f && $1 == "PublicKey" {print $2; exit}' "$WG0_CONF")"
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
    before="$(cat "$WG0_CONF")"
    for args in "iphone 1.1.1.1 21 1420|zaten var" "bad/name 1.1.1.1 21 1420|geçersiz peer adı" \
        "x not-an-ip 21 1420|DNS virgülle" "x 1.1.1.1 70000 1420|keepalive" "x 1.1.1.1 abc 1420|keepalive" \
        "x 1.1.1.1 21 1600|MTU" "x 1.1.1.1 21 900|MTU" "x , 21 1420|en az bir DNS"; do
        set -- ${args%%|*}
        run master_wg add "$@"
        [ "$status" -ne 0 ]
        case "$output" in *"${args#*|}"*) ;; *) printf 'expected %s: %s\n' "${args#*|}" "$output"; false ;; esac
    done
    [ "$(cat "$WG0_CONF")" = "$before" ]
    [ "$(ls "$TMP/etc/wireguard/clients-wg0")" = iphone.conf ]
    run master_wg remove nosuch
    [ "$status" -ne 0 ]
    run master_wg profile nosuch
    [ "$status" -ne 0 ]
}

@test "master-wg png writes the stored profile's QR code as PNG to a pipe and never to a terminal" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    cat >"$TMP/bin/qrencode" <<'EOF'
#!/bin/bash
printf 'qrencode %s\n' "$*" >>"$MOCK_LOG"
printf '\211PNG\r\n\032\n'
cat
EOF
    chmod +x "$TMP/bin/qrencode"
    rm -f "$TMP/calls"
    master_wg png iphone >"$TMP/out.png"
    grep -qx 'qrencode -t PNG -s 8 -o -' "$TMP/calls"
    [ "$(head -c 8 "$TMP/out.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
    tail -c +9 "$TMP/out.png" | cmp - "$TMP/etc/wireguard/clients-wg0/iphone.conf"
    # Nothing is applied or changed.
    run ! grep -qE '^(wg|systemctl) ' "$TMP/calls"
    run master_wg png ghost
    [ "$status" -ne 0 ]
    case "$output" in *"'ghost' için sunucuda profil yok"*) ;; *) false ;; esac
    run master_wg png "../iphone"
    [ "$status" -ne 0 ]
    run master_wg png
    [ "$status" -ne 0 ]
    # Binary output is refused on a terminal.
    body="$(awk '/^cmd_png\(\)/,/^}$/' "$V2_ROOT/scripts/master-wg")"
    grep -q '\[\[ ! -t 1 \]\] || die' <<<"$body"
}

@test "master-wg info adds IPv6, DNS, keepalive and MTU to the list and never a key" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone "1.1.1.1, 1.0.0.1, 2606:4700:4700::1001" 21 1420 >/dev/null
    master_wg add laptop 9.9.9.9 0 1380 >/dev/null
    master_wg add tablet 8.8.8.8 25 1400 >/dev/null
    rm -f "$TMP/etc/wireguard/clients-wg0/tablet.conf"
    # A profile without a keepalive line (hand-made or older) reads as 0.
    grep -v '^PersistentKeepalive' "$TMP/etc/wireguard/clients-wg0/laptop.conf" >"$TMP/laptop.conf"
    cat "$TMP/laptop.conf" >"$TMP/etc/wireguard/clients-wg0/laptop.conf"
    pub="$(awk -F' = ' '/^# peer: iphone$/ {f = 1} f && $1 == "PublicKey" {print $2; exit}' "$WG0_CONF")"
    printf 'SERVERPRIV\tSERVERPUB\t61001\toff\n%s\t(none)\t198.51.100.4:5555\t10.8.0.2/32\t1700000000\t2048\t1024\t21\n' "$pub" >"$TMP/dump"
    run master_wg info
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p <<<"$output")" = $'iphone\t10.8.0.2\tfdcc:ad94:bacf:61a4::2\t1700000000\t2048\t1024\tvar\t1.1.1.1, 1.0.0.1, 2606:4700:4700::1001\t21\t1420\t1' ]
    [ "$(sed -n 2p <<<"$output")" = $'laptop\t10.8.0.3\tfdcc:ad94:bacf:61a4::3\t0\t0\t0\tvar\t9.9.9.9\t0\t1380\t1' ]
    # A peer without a stored profile keeps eleven fields with the profile ones empty.
    [ "$(sed -n 3p <<<"$output")" = $'tablet\t10.8.0.4\tfdcc:ad94:bacf:61a4::4\t0\t0\t0\tyok\t\t\t\t1' ]
    run ! grep -qE 'PRIV|PSK|PUB' <<<"$output"
    # list keeps its six fields for wireguard.command.
    run master_wg list
    [ "$(sed -n 1p <<<"$output")" = $'iphone\t10.8.0.2\t1700000000\t2048\t1024\tvar' ]
}

@test "master-wg net-add creates the next network, opens the firewall before the interface and undoes a failed step" {
    wg_mock_bin
    wg_state_fixture
    local wgd="$TMP/etc/wireguard" before args a b c d
    rm -f "$TMP/calls"
    run master_wg net-add 61011 ui "1.1.1.1 , 1.0.0.1" "İş ağı"
    [ "$status" -eq 0 ]
    [ "$output" = $'wg1\t61011' ]
    grep -qx 'Address = 10.8.1.1/24, fdcc:ad94:bacf:61a4::1:1/112' "$wgd/wg1.conf"
    grep -qx 'ListenPort = 61011' "$wgd/wg1.conf"
    grep -qx 'MTU = 1420' "$wgd/wg1.conf"
    grep -q '^PrivateKey = PRIV' "$wgd/wg1.conf"
    [ "$(stat -f %Lp "$wgd/wg1.conf" 2>/dev/null || stat -c %a "$wgd/wg1.conf")" = 600 ]
    [ -d "$wgd/clients-wg1" ]
    [ "$(sed -n 2p "$wgd/networks")" = $'wg1\t61011\tui\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t1.1.1.1, 1.0.0.1\tİş ağı' ]
    grep -qx 'WG_BIND=10.8.1.1' "$wgd/caddy-wg-wg1.env"
    # Firewall first (the port opens, forwarding and NAT exist), then the interface, then its Caddy.
    awk '/systemctl restart master-firewall.service/ {f = NR} /systemctl enable --now wg-quick@wg1.service/ {w = NR}
         /systemctl enable --now caddy-wg@wg1.service/ {c = NR} END { exit !(f && w && c && f < w && w < c) }' "$TMP/calls"
    # An internet-only network takes the next number, with no Caddy.
    rm -f "$TMP/calls"
    run master_wg net-add 61021 inet 9.9.9.9 ""
    [ "$output" = $'wg2\t61021' ]
    [ ! -e "$wgd/caddy-wg-wg2.env" ]
    run ! grep -q 'caddy-wg@wg2' "$TMP/calls"
    [ "$(sed -n 3p "$wgd/networks")" = $'wg2\t61021\tinet\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t9.9.9.9\t' ]
    # Refusals change nothing: a port of wg0, of a panel network or of the stack, the range, scope, DNS, label.
    before="$(cat "$wgd/networks")"
    rm -f "$TMP/calls"
    for args in "61001|ui|1.1.1.1|x" "61021|ui|1.1.1.1|x" "61008|ui|1.1.1.1|x" "61005|inet|1.1.1.1|x" \
        "1000|ui|1.1.1.1|x" "61031|all|1.1.1.1|x" "61031|ui|dns.google|x" $'61031|ui|1.1.1.1|a\tb' "61031|ui|1.1.1.1| lead"; do
        IFS='|' read -r a b c d <<<"$args"
        run master_wg net-add "$a" "$b" "$c" "$d"
        [ "$status" -ne 0 ]
    done
    run master_wg net-add 61001 ui 1.1.1.1 x
    case "$output" in *"UDP 61001 kullanılıyor (wg0)"*) ;; *) false ;; esac
    [ "$(cat "$wgd/networks")" = "$before" ]
    [ ! -e "$wgd/wg3.conf" ]
    [ ! -s "$TMP/calls" ]
    # A port another program listens on is refused too.
    printf '#!/bin/bash\ncase "$*" in *61099*) echo "UNCONN 0 0 0.0.0.0:61099 0.0.0.0:*" ;; esac\n' >"$TMP/bin/ss"
    chmod +x "$TMP/bin/ss"
    run master_wg net-add 61099 inet 1.1.1.1 x
    case "$output" in *"başka bir program"*) ;; *) false ;; esac
    # A failing step removes every trace of the new network and puts the firewall back.
    export SYSTEMCTL_FAIL="enable --now wg-quick@wg3"
    run master_wg net-add 61031 ui 1.1.1.1 Test
    unset SYSTEMCTL_FAIL
    [ "$status" -ne 0 ]
    case "$output" in *"wg3 başlatılamadı; ağ oluşturulmadı"*) ;; *) false ;; esac
    [ ! -e "$wgd/wg3.conf" ]
    [ ! -e "$wgd/clients-wg3" ]
    [ ! -e "$wgd/caddy-wg-wg3.env" ]
    [ "$(cat "$wgd/networks")" = "$before" ]
    [ "$(grep -c 'systemctl restart master-firewall.service' "$TMP/calls")" -eq 2 ]
    grep -q 'systemctl disable --now wg-quick@wg3.service' "$TMP/calls"
    export SYSTEMCTL_FAIL="enable --now caddy-wg@wg3"
    run master_wg net-add 61031 ui 1.1.1.1 Test
    unset SYSTEMCTL_FAIL
    [ "$status" -ne 0 ]
    [ ! -e "$wgd/wg3.conf" ]
    [ "$(cat "$wgd/networks")" = "$before" ]
    # The limit comes from state.env.
    printf 'WG_NETWORKS_MAX=2\n' >>"$TMP/state.env"
    run master_wg net-add 61031 inet 1.1.1.1 ""
    [ "$status" -ne 0 ]
    case "$output" in *"en çok 3 ağ"*) ;; *) false ;; esac
}

@test "master-wg --if runs peer commands on a panel network, nets lists all and net-remove drops only that network" {
    wg_mock_bin
    wg_state_fixture
    local wgd="$TMP/etc/wireguard"
    master_wg net-add 61011 inet 9.9.9.9 Misafir >/dev/null
    rm -f "$TMP/calls"
    run master_wg --if wg1 add tel 9.9.9.9 21 1420
    [ "$status" -eq 0 ]
    [ "$output" = $'tel\t10.8.1.2' ]
    grep -qx 'Address = 10.8.1.2/32, fdcc:ad94:bacf:61a4::1:2/128' "$wgd/clients-wg1/tel.conf"
    grep -qx 'Endpoint = 203.0.113.7:61011' "$wgd/clients-wg1/tel.conf"
    grep -qx 'AllowedIPs = 10.8.1.2/32, fdcc:ad94:bacf:61a4::1:2/128' "$wgd/wg1.conf"
    grep -q '^wg syncconf wg1 ' "$TMP/calls"
    run ! grep -q 'tel' "$wgd/wg0.conf"
    [ ! -e "$wgd/clients/tel.conf" ]
    run master_wg --if wg1 info
    [ "$(cut -f1-3 <<<"$output")" = $'tel\t10.8.1.2\tfdcc:ad94:bacf:61a4::1:2' ]
    # DD-143: birden çok ağ varken peer komutu ağ ister.
    run master_wg add phone 1.1.1.1 21 1420
    [ "$status" -ne 0 ]
    case "$output" in *"birden çok ağ var"*) ;; *) false ;; esac
    master_wg --if wg0 add phone 1.1.1.1 21 1420 >/dev/null
    run master_wg nets
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p <<<"$output")" = $'wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\t1\t1' ]
    [ "$(sed -n 2p <<<"$output")" = $'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\tMisafir\t1\t1' ]
    run master_wg --if wg7 list
    [ "$status" -ne 0 ]
    case "$output" in *"'wg7' diye bir WireGuard ağı yok"*) ;; *) false ;; esac
    run master_wg --if eth0 list
    [ "$status" -ne 0 ]
    run master_wg --if wg1 nets
    [ "$status" -ne 0 ]
    # net-remove needs --onay, never touches wg0, and removes only the network asked for.
    run master_wg net-remove wg1
    [ "$status" -ne 0 ]
    # DD-143: wg0 da sıradan bir ağ; kaldırılabilir ama onay ister.
    run master_wg net-remove wg0
    [ "$status" -ne 0 ]
    [ -f "$wgd/wg1.conf" ]
    export WG_ACTIVE=0
    rm -f "$TMP/calls"
    run master_wg net-remove wg1 --onay
    [ "$status" -eq 0 ]
    [ "$output" = $'wg1\t1' ]
    [ ! -e "$wgd/wg1.conf" ]
    [ ! -e "$wgd/clients-wg1" ]
    [ "$(wc -l <"$wgd/networks" | tr -d " ")" = 1 ]
    grep -q 'systemctl disable --now wg-quick@wg1.service' "$TMP/calls"
    grep -q 'systemctl restart master-firewall.service' "$TMP/calls"
    grep -qx '# peer: phone' "$wgd/wg0.conf"
    [ -f "$wgd/clients-wg0/phone.conf" ]
    # Tek ağ kalınca peer komutu --if istemez.
    run master_wg list
    [ "$status" -eq 0 ]
    run master_wg net-remove wg1 --onay
    [ "$status" -ne 0 ]
}

@test "master-wg dns rewrites only the profile's DNS line and leaves keys and wg0.conf alone" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    profile="$TMP/etc/wireguard/clients-wg0/iphone.conf"
    rest_before="$(grep -v '^DNS = ' "$profile")"
    conf_before="$(shasum <"$WG0_CONF")"
    rm -f "$TMP/calls"
    run master_wg dns iphone "2a07:a8c0::df:877b , 2a07:a8c1::df:877b"
    [ "$status" -eq 0 ]
    [ "$output" = $'iphone\t2a07:a8c0::df:877b, 2a07:a8c1::df:877b' ]
    grep -qx 'DNS = 2a07:a8c0::df:877b, 2a07:a8c1::df:877b' "$profile"
    [ "$(grep -c '^DNS = ' "$profile")" = 1 ]
    [ "$(grep -v '^DNS = ' "$profile")" = "$rest_before" ]
    [ "$(shasum <"$WG0_CONF")" = "$conf_before" ]
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
    [ -z "$(find "$TMP/etc/wireguard/clients-wg0" -name '.peer-*')" ]
    # The menu default (DD-131) is valid and written back exactly as defaults.env has it.
    default_dns="$(awk -F'"' '/^WG_CLIENT_DNS_DEFAULT=/{print $2; exit}' "$V2_ROOT/config/defaults.env")"
    run master_wg dns iphone "$default_dns"
    [ "$status" -eq 0 ]
    grep -qxF "DNS = $default_dns" "$profile"
}

@test "master-wg reset needs --onay, issues a new server key and drops every peer and profile" {
    wg_mock_bin
    wg_state_fixture
    master_wg add iphone 1.1.1.1 21 1420 >/dev/null
    master_wg add ipad 1.1.1.1 21 1420 >/dev/null
    conf_before="$(cat "$WG0_CONF")"
    run master_wg reset
    [ "$status" -ne 0 ]
    [ "$(cat "$WG0_CONF")" = "$conf_before" ]
    [ -f "$TMP/etc/wireguard/clients-wg0/iphone.conf" ]
    rm -f "$TMP/calls"
    run master_wg reset --onay
    [ "$status" -eq 0 ]
    [ "$output" = $'2\t2' ]
    # [Interface] lines and the header stay, the key is new, no peer is left.
    grep -qx '# header' "$WG0_CONF"
    grep -qx 'Address = 10.8.0.1/24, fdcc:ad94:bacf:61a4::1/112' "$WG0_CONF"
    grep -qx 'ListenPort = 61001' "$WG0_CONF"
    grep -qx 'MTU = 1420' "$WG0_CONF"
    [ "$(grep -c '^PrivateKey = ' "$WG0_CONF")" = 1 ]
    run ! grep -q 'SRVKEY' "$WG0_CONF"
    [ "$(tail -n 1 "$WG0_CONF" | cut -c1-13)" = "PrivateKey = " ]
    run ! grep -qE '^\[Peer\]$|^# peer: ' "$WG0_CONF"
    [ -z "$(ls -A "$TMP/etc/wireguard/clients-wg0")" ]
    # Applied live, with the new key and no peers.
    grep -q '^PrivateKey = PRIV' "$TMP/syncconf"
    run ! grep -q '^\[Peer\]' "$TMP/syncconf"
    # A failed apply restores wg0.conf and keeps the profiles.
    master_wg add mac 1.1.1.1 21 1420 >/dev/null
    conf_before="$(cat "$WG0_CONF")"
    export SYNC_RC=1
    run master_wg reset --onay
    unset SYNC_RC
    [ "$status" -ne 0 ]
    [ "$(cat "$WG0_CONF")" = "$conf_before" ]
    [ -f "$TMP/etc/wireguard/clients-wg0/mac.conf" ]
    # Nothing but the interface section is ever written back: wg0.conf with no
    # [Interface] is refused.
    printf '[Peer]\nPublicKey = x\n' >"$WG0_CONF"
    run master_wg reset --onay
    [ "$status" -ne 0 ]
}

@test "master-wg remove drops exactly one block, rolls back a failed apply and never feeds an empty strip" {
    wg_mock_bin
    wg_state_fixture
    for n in a b c; do master_wg add "$n" 1.1.1.1 21 1420 >/dev/null; done
    run master_wg remove b
    [ "$status" -eq 0 ]
    conf="$(cat "$WG0_CONF")"
    [ "$(grep -c '^\[Peer\]$' <<<"$conf")" -eq 2 ]
    run ! grep -q '# peer: b' <<<"$conf"
    grep -qx '# peer: a' <<<"$conf"
    grep -qx '# peer: c' <<<"$conf"
    run ! grep -q '10.8.0.3/32' <<<"$conf"
    [ ! -e "$TMP/etc/wireguard/clients-wg0/b.conf" ]
    # No run of blank lines is left where the block was.
    awk 'NR > 1 && prev == "" && $0 == "" {bad = 1} {prev = $0} END {exit bad}' <<<"$conf"
    # The freed address is reused.
    run master_wg add d 1.1.1.1 21 1420
    [ "$output" = $'d\t10.8.0.3' ]
    # A failed syncconf restores wg0.conf and removes the new profile.
    before="$(cat "$WG0_CONF")"
    SYNC_RC=1 run master_wg add e 1.1.1.1 21 1420
    [ "$status" -ne 0 ]
    [ "$(cat "$WG0_CONF")" = "$before" ]
    [ ! -e "$TMP/etc/wireguard/clients-wg0/e.conf" ]
    # An empty `wg-quick strip` never reaches syncconf.
    printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/wg-quick"
    rm -f "$TMP/calls"
    run master_wg remove a
    [ "$status" -ne 0 ]
    run ! grep -q 'syncconf' "$TMP/calls"
    grep -qx '# peer: a' "$WG0_CONF"
}

@test "the installer prepares the WireGuard layer and applies the registry, never a network of its own" {
    # DD-143: kurulum anahtar üretmez, conf yazmaz, arayüz açmaz.
    eval "$(awk '/^ensure_wireguard_ready\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_wg_networks_running\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    wg_mock_bin
    wg_state_fixture
    PATH="$TMP/bin:$PATH"
    WG_CONF_DIR="$TMP/etc/wireguard" WG_MODULES_LOAD_FILE="$TMP/modules.conf"
    WG_NETWORKS_FILE="$TMP/etc/wireguard/networks" APT_OPTS=() APT_LOCK_TIMEOUT=1
    log() { printf '%s %s\n' "$1" "${*:2}" >>"$TMP/log"; }
    retry() { printf 'retry %s\n' "$*" >>"$TMP/calls"; }
    modprobe() { :; }
    atomic_write() { cat >"$1"; }
    install() { local a; for a in "$@"; do case "$a" in /*) mkdir -p "$a" ;; esac; done; }
    before="$(cat "$WG0_CONF")"
    run ensure_wireguard_ready
    [ "$status" -eq 0 ]
    grep -q 'no-install-recommends wireguard-tools qrencode' "$TMP/calls"
    [ "$(cat "$TMP/modules.conf")" = wireguard ]
    # Var olan yapılandırmaya dokunulmaz, yenisi yazılmaz.
    [ "$(cat "$WG0_CONF")" = "$before" ]
    run ! grep -q 'wg genkey' "$TMP/calls"

    # Kayıttaki ağ uygulanır: birim etkinleştirilir, gerekiyorsa başlatılır.
    rm -f "$TMP/calls"
    WG_ACTIVE=0 run ensure_wg_networks_running
    [ "$status" -eq 0 ]
    grep -q 'systemctl enable --quiet wg-quick@wg0.service' "$TMP/calls"
    grep -q 'systemctl restart wg-quick@wg0.service' "$TMP/calls"
    grep -q 'systemctl enable --quiet caddy-wg@wg0.service' "$TMP/calls"

    # Kayıt yoksa hiçbir şey açılmaz; kullanıcı Konsol'a yönlendirilir.
    rm -f "$TMP/calls" "$TMP/log" "$TMP/etc/wireguard/networks"
    run ensure_wg_networks_running
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/calls" ]
    grep -q 'Yapılandır' "$TMP/log"
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
    # Option 8 needs the typed word (DD-130); DD-143: Mac'te yedek yok.
    body="$(awk '/^regenerate_net\(\)/,/^}$/' "$cmd")"
    grep -q "tr '\[:upper:\]' '\[:lower:\]')\" in" <<<"$body"
    grep -q '^        onayla) ;;$' <<<"$body"
    grep -q 'remote reset --onay' <<<"$body"
    for fn in add_peer:add remove_peer:remove change_dns:dns; do
        body="$(awk -v f="^${fn%%:*}\\(\\)" '$0 ~ f, /^}$/' "$cmd")"
        awk -v c="remote ${fn#*:} " 'index($0, c) {r = NR} END {exit !r}' <<<"$body"
    done
    grep -q '6) select_net --ask || true ;;' "$cmd"
    grep -q '7) change_dns || true ;;' "$cmd"
    grep -q '8) regenerate_net || true ;;' "$cmd"
    # Reading the profile for the current DNS never exits the pipe early.
    grep -qF "awk -F' = ' '\$1 == \"DNS\" {v = \$2} END {print v}'" "$cmd"
    # Nothing local is sent to the server: no scp, no local tar archive, no
    # file redirected into ssh. The only stdin is the backup script heredoc,
    # whose body runs on the server.
    # DD-143: sunucuda çalışan gömülü betik de kalktı; dosya baştan sona yerel.
    outside="$(cat "$cmd")"
    [ "$(grep -c "<<'REMOTE'" "$cmd")" -eq 0 ]
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

@test "no setting names a single WireGuard network: the paths are bases only" {
    # DD-143: wg0 is one registry row like any other, so no default, state key or
    # script may hard-code its config path.
    grep -q '^WG_CONF_DIR="/etc/wireguard"$' "$V2_ROOT/config/defaults.env"
    # The state file the installer writes carries the base directory, not a network.
    grep -q '^WG_CONF_DIR=\$WG_CONF_DIR$' "$V2_ROOT/install.sh"
    run ! grep -rn 'WG_CONF_FILE' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh" \
        "$V2_ROOT/panel" "$V2_ROOT/files-panel" "$V2_ROOT/../wireguard.command"
    run ! grep -qE '^[^#]*wg0\.conf' "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env"
    # master-wg keeps WG_CONF_FILE as the selected network's path, derived from the
    # base; it must not inherit one from the environment.
    grep -q ': "${WG_CONF_DIR:?}"' "$V2_ROOT/scripts/master-wg"
    grep -q '^BASE_CONF_DIR="\$WG_CONF_DIR"$' "$V2_ROOT/scripts/master-wg"
    grep -q '^WG_CONF_FILE=""$' "$V2_ROOT/scripts/master-wg"
}

@test "firewall builds rules for every WireGuard network and keeps the networks apart" {
    local fw="$V2_ROOT/scripts/firewall.sh" f
    for f in wg_ui_ports load_wg_networks apply_input4 apply_input6 apply_forward apply_nat wan_allow_pairs; do
        eval "$(awk "/^$f\\(\\)/,/^}\$/" "$fw")"
    done
    grep -q '^load_wg_networks$' "$fw"
    awk '/^load_wg_networks$/ {l = NR} /^resolve_wan_interface$/ {r = NR} END { exit !(l && r && l < r) }' "$fw"
    # write_state carries what the firewall and master-wg need (DD-136).
    for v in WG_NETWORKS_FILE WG_NETWORKS_MAX WG_MTU WG_PANEL_PORT WG_ADDR_BASE4 WG_ADDR_BASE6; do
        awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q "^$v=\\\$$v$"
    done
    die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
    create_staging() { printf '%s' "$2"; }
    activate_named() { :; }
    iptables() { shift 2; printf '%s\n' "$*" >>"$TMP/in4"; }
    ip6tables() { shift 2; printf '%s\n' "$*" >>"$TMP/in6"; }
    iptables_nat() { shift 2; printf '%s\n' "$*" >>"$TMP/nat4"; }
    ip6tables_nat() { shift 2; printf '%s\n' "$*" >>"$TMP/nat6"; }
    WAN_INTERFACE=eth0 TAILSCALE_IF=tailscale0 TAILSCALE_UDP_PORT=41641 SSH_PUBLIC_PORT=22 TORRENT_PUBLIC_PORT=61005
    CHAIN_STAGING_PREFIX=MASTER-NEXT- DOZZLE_UI_PORT=61002 TORRENT_UI_PORT=61006
    WG_NETWORKS_FILE="$TMP/networks"
    # DD-143: wg0 da kayıttan gelir; kayıt boşsa hiç WireGuard kuralı olmaz.
    : >"$WG_NETWORKS_FILE"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    apply_input4
    run ! grep -q ' wg' "$TMP/in4"
    rm -f "$TMP/in4" "$TMP/in6" "$TMP/nat4" "$TMP/nat6"
    printf 'wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\n' >"$WG_NETWORKS_FILE"
    printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\tMisafir\n' >>"$WG_NETWORKS_FILE"
    printf 'wg2\t61021\tui\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t1.1.1.1\t\n' >>"$WG_NETWORKS_FILE"
    load_wg_networks
    [ "${WG_IFACES[*]}" = "wg0 wg1 wg2" ]
    apply_input4
    apply_forward iptables FW-
    apply_input6
    apply_nat iptables_nat NAT- "${WG_NET4[@]}"
    apply_nat ip6tables_nat NAT6- "${WG_NET6[@]}"
    # WAN: one UDP port per network, before the single WAN DROP.
    for port in 61001 61011 61021; do
        grep -qx -- "-A MASTER-NEXT-IN- -i eth0 -p udp --dport $port -j ACCEPT" "$TMP/in4"
    done
    [ "$(wan_allow_pairs v4 | grep -c '^udp 610[0-2]1$')" -eq 3 ]
    awk '/--dport 61021 -j ACCEPT/ {a = NR} /-i eth0 -j DROP/ {d = NR} END { exit !(a && d && a < d) }' "$TMP/in4"
    # UI ports only on the "ui" networks' own addresses; ping and a DROP for each network.
    grep -qx -- '-A MASTER-NEXT-IN- -i wg0 -d 10.8.0.1 -p tcp -m multiport --dports 61002,61006 -j ACCEPT' "$TMP/in4"
    grep -qx -- '-A MASTER-NEXT-IN- -i wg2 -d 10.8.2.1 -p tcp -m multiport --dports 61002,61006 -j ACCEPT' "$TMP/in4"
    run ! grep -q -- '-i wg1 -d 10.8.1.1 -p tcp' "$TMP/in4"
    for w in wg0 wg1 wg2; do
        grep -qx -- "-A MASTER-NEXT-IN- -i $w -j DROP" "$TMP/in4"
        grep -qx -- "-A MASTER-NEXT-IN6- -i $w -j DROP" "$TMP/in6"
        grep -q -- "-A MASTER-NEXT-IN- -i $w -d 10.8.[0-2].1 -p icmp --icmp-type echo-request -j ACCEPT" "$TMP/in4"
    done
    [ "$(grep '^-A MASTER-NEXT-IN- ' "$TMP/in4" | tail -n 1)" = '-A MASTER-NEXT-IN- -j RETURN' ]
    # FORWARD: to the WAN only, replies back, anything else (another network, the tailnet) dropped.
    [ "$(grep -c '^-A FW- ' "$TMP/in4")" -eq 13 ]
    for w in wg0 wg1 wg2; do
        awk -v w="$w" '$0 == "-A FW- -i " w " -o eth0 -j ACCEPT" {a = NR} $0 == "-A FW- -i " w " -j DROP" {d = NR}
            $0 == "-A FW- -o " w " -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" {r = NR} $0 == "-A FW- -o " w " -j DROP" {o = NR}
            END { exit !(a && d && r && o && a < d && d < r && r < o) }' "$TMP/in4"
    done
    run ! grep -qE -- '-i wg[0-9] -o wg[0-9]' "$TMP/in4"
    # NAT: every subnet masqueraded on the WAN.
    [ "$(cat "$TMP/nat4")" = "$(printf -- '-A NAT- -s %s -o eth0 -j MASQUERADE\n' 10.8.0.0/24 10.8.1.0/24 10.8.2.0/24; printf -- '-A NAT- -j RETURN')" ]
    grep -qx -- '-A NAT6- -s fdcc:ad94:bacf:61a4::2:0/112 -o eth0 -j MASQUERADE' "$TMP/nat6"
    # A broken or clashing registry stops before any chain is touched.
    rm -f "$TMP/in4"
    printf 'wg3\t61031\tall\t10.8.3.1\t10.8.3.0/24\tfdcc::3:1\tfdcc::3:0/112\t1.1.1.1\t\n' >>"$WG_NETWORKS_FILE"
    run load_wg_networks
    [ "$status" -ne 0 ]
    case "$output" in *"ağ kaydı bozuk"*"hiçbir kural değiştirilmedi"*) ;; *) false ;; esac
    printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\t\n' >"$WG_NETWORKS_FILE"
    printf 'wg2\t61011\tinet\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t9.9.9.9\t\n' >>"$WG_NETWORKS_FILE"
    run load_wg_networks
    [ "$status" -ne 0 ]
    case "$output" in *"tekrar eden"*) ;; *) false ;; esac
    [ ! -e "$TMP/in4" ]
    # DD-143: kayıt dosyası hiç yoksa ağ da yoktur.
    WG_NETWORKS_FILE="$TMP/none"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    # No wg-quick PostUp rules: the firewall script owns netfilter (DD-16/DD-17).
    run ! grep -q 'PostUp' <<<"$(grep -vE '^[[:space:]]*#' "$V2_ROOT/install.sh")"
    run ! grep -q 'WG_PUBLIC_PORT' <<<"$(awk '/^docker_return_pairs\(\)/,/^}$/' "$fw")"
}

@test "check_before and the WireGuard FORWARD count catch order and extra rules" {
    eval "$(awk '/^check_before\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    eval "$(awk '/^check_forward_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
    check_jump_exactly_one() { :; }
    check_rule() { :; }
    CHAIN_FORWARD=MASTER-FORWARD WAN_INTERFACE=eth0
    WG_IFACES=(wg0)
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
    # DD-136: two networks need four rules each plus the RETURN.
    WG_IFACES=(wg0 wg1)
    RULES="$(printf '%s\n' "$good" | sed '$d'; printf '%s\n' "$good" | sed 's/wg0/wg1/g')"
    run check_forward_chain iptables
    [ "$status" -eq 0 ]
    RULES="$good"
    run check_forward_chain iptables
    [ "$status" -ne 0 ]
}

@test "caddy-wg serves only the UI ports on each WireGuard address and follows its wg-quick" {
    local t="$V2_ROOT/templates/Caddyfile.wg" u="$V2_ROOT/systemd/caddy-wg@.service" body
    grep -q '^	admin off$' "$t"
    grep -q '^	auto_https off$' "$t"
    # DD-136: one Caddyfile, one instance per interface; the address comes from the instance's env file.
    grep -q '^	default_bind {$WG_BIND}$' "$t"
    for p in DOZZLE_UI_PORT TORRENT_UI_PORT; do
        grep -q "^http://:__${p}__ {\$" "$t"
        grep -q "reverse_proxy 127.0.0.1:__${p}__\$" "$t"
    done
    [ "$(grep -c '^http://' "$t")" -eq 2 ]
    run ! grep -qiE 'webdav|TAILSCALE|LOCAL_DOMAIN' <<<"$(grep -v '^#' "$t")"
    [ ! -e "$V2_ROOT/systemd/caddy-wg.service" ]
    grep -q '^Requires=wg-quick@%i.service$' "$u"
    grep -q '^PartOf=wg-quick@%i.service$' "$u"
    grep -q '^EnvironmentFile=__WG_CONF_DIR__/caddy-wg-%i.env$' "$u"
    grep -q '^User=caddy$' "$u"
    grep -q -- '--config __CADDY_WG_FILE__ --adapter caddyfile' "$u"
    run ! grep -qi 'tailscale' "$u"
    body="$(awk '/^ensure_caddy_wg\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -q 'WG_BIND="127.0.0.1" caddy validate --config "$CADDY_WG_FILE"' <<<"$body"
    # DD-143: örnek birimleri ağlarla birlikte master-wg açar; kurulum yalnız şablonu tutar.
    run ! grep -qE 'caddy-wg-\$\{WG_INTERFACE\}|caddy-wg@\$\{WG_INTERFACE\}' <<<"$body"
    grep -q 'WG_BIND=%s' "$V2_ROOT/scripts/master-wg"
    # A changed shared file restarts the networks' instances.
    grep -q 'systemctl try-restart "caddy-wg@${iface}.service"' <<<"$body"
    awk '/^stage_6\(\)/,/^assert_webdav_readonly_runtime\(\)/' "$V2_ROOT/install.sh" |
        grep -q '^    ensure_caddy_wg "\$OS_CHANGED"$'
    # Kayıttaki ağlar firewall kurallarından sonra uygulanır (DD-143).
    awk '/^stage_5\(\)/,/^apt_get_install_masked_quiet\(\)/' "$V2_ROOT/install.sh" |
        awk '/restart master-firewall.service/ {f = NR} /^    ensure_wg_networks_running$/ {w = NR}
             END { exit !(f && w && f < w) }'
    # Stage 7 proves each registry network's port, address and UI ports.
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'wg show "$wg_iface" listen-port' <<<"$s7"
    grep -q '"$SBIN_DIR/master-wg" version' <<<"$s7"
    grep -q 'http://${wg_s4}:${wg_ui_port}/' <<<"$s7"
}
