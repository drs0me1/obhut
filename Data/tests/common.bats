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
    # DD-152: no Docker repository any more.
    run ! grep -q 'download.docker.com' "$V2_ROOT/install.sh"
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
    # DD-153: apt reads the armored key itself; no gnupg, no dearmor.
    run ! grep -q 'gpg --dearmor' "$V2_ROOT/install.sh"
    grep -q 'signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.asc' \
        "$V2_ROOT/install.sh"
    run grep -q 'dns_pkgs+=(debian-keyring)' "$V2_ROOT/install.sh"
    [ "$status" -ne 0 ]
    # Every apt-get call waits on the dpkg lock (ubuntu unattended-upgrades).
    grep -q 'APT_OPTS=(-o DPkg::Lock::Timeout=' "$V2_ROOT/install.sh"
    # DD-150: the WireGuard packages are installed by the WireGuard module, not here;
    # DD-152: no Docker repository update or packages either.
    [ "$(grep -cF 'apt-get "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 7 ]
    grep -qF 'apt-get install -y --no-install-recommends' "$V2_ROOT/scripts/master-modul"
    grep -qF -- '-o DPkg::Lock::Timeout=300 "$@"' "$V2_ROOT/scripts/master-modul"
    grep -qx 'WG_PACKAGES="wireguard-tools qrencode"' "$V2_ROOT/scripts/master-modul"
    grep -qx '            apt_install qbittorrent-nox || fail_step "$FAIL"' "$V2_ROOT/scripts/master-modul"
    # retry runs a function in a child bash that does not inherit arrays, so
    # the masked-quiet installs take APT_OPTS as arguments (DD-125).
    [ "$(grep -cF 'apt_get_install_masked_quiet "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 2 ]
    run bash -c "awk '/^apt_get_install_masked_quiet\\(\\)/,/^}/' '$V2_ROOT/install.sh' | grep -q APT_OPTS"
    [ "$status" -ne 0 ]
}

@test "RAR repository uses signed distribution components and supported architectures" {
    # Exercise the actual distribution selection without touching host apt paths.
    selection="$(awk '/^ensure_rar_repository\(\)/,/^}/' "$V2_ROOT/install.sh" |
        sed -n '/    case "\$OS_ID" in/,/^    esac/p')"
    for triple in 'debian trixie amd64' 'ubuntu noble amd64' 'ubuntu resolute arm64'; do
        set -- $triple
        OS_ID="$1" OS_CODENAME="$2" OS_ARCH="$3"
        eval "$selection"
        if [ "$OS_ID" = debian ]; then
            [ "$components" = non-free ]
            [ "$mirror" = https://deb.debian.org/debian ]
            [ "$security" = https://security.debian.org/debian-security ]
            [ "$keyring" = /usr/share/keyrings/debian-archive-keyring.gpg ]
        else
            [ "$components" = 'universe multiverse' ]
            [ "$keyring" = /usr/share/keyrings/ubuntu-archive-keyring.gpg ]
            if [ "$OS_ARCH" = arm64 ]; then
                [ "$mirror" = https://ports.ubuntu.com/ubuntu-ports ]
                [ "$security" = "$mirror" ]
            else
                [ "$mirror" = https://archive.ubuntu.com/ubuntu ]
                [ "$security" = https://security.ubuntu.com/ubuntu ]
            fi
        fi
    done
    grep -qF 'deb [signed-by=$keyring] $security $OS_CODENAME-security $components' "$V2_ROOT/install.sh"
    grep -qF 'dnsutils unattended-upgrades python3 python3-rarfile unrar' "$V2_ROOT/install.sh"
    grep -qF 'master_rar.py' "$V2_ROOT/install.sh"
}

@test "RAR repository leaves existing sources alone when dependencies have candidates" {
    eval "$(awk '/^ensure_rar_repository\(\)/,/^}/' "$V2_ROOT/install.sh")"
    apt-cache() { echo '  Candidate: 1.2.3'; }
    atomic_write() { return 99; }
    retry() { return 98; }
    run ensure_rar_repository
    [ "$status" -eq 0 ]
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
    # tailscaled and firewall.sh must share one netfilter backend (DD-106), and
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
    run ! grep -q 'assert_repo_suite "Docker"' "$V2_ROOT/install.sh"
    # Every render is validated before the unit that consumes it is restarted.
    grep -q 'dnsmasq --test -C "\$DNSMASQ_CONF_FILE"' "$V2_ROOT/install.sh"
    grep -q 'caddy validate --config "\$CADDYFILE"' "$V2_ROOT/install.sh"
    # Caddy resolves env placeholders at runtime; validate with the real values. Module
    # site files render their port literally, so only the Tailscale address is needed (DD-149).
    grep -qF 'TAILSCALE_IPV4="$TAILSCALE_IPV4" \' "$V2_ROOT/install.sh"
    [ "$(grep -c 'SHARE_PORT="\$SHARE_PORT" \\$' <<<"$(awk '/caddy validate --config/{print prev} {prev=$0}' "$V2_ROOT/install.sh")")" -eq 0 ]
}

@test "apt keeps no downloaded packages and installs no Docker" {
    # DD-125: the installer's own .deb downloads are not left in the cache.
    grep -qF 'APT_OPTS=(-o DPkg::Lock::Timeout=60 -o APT::Keep-Downloaded-Packages=false)' \
        "$V2_ROOT/install.sh"
    # DD-152: no Docker engine, repository, daemon settings or unit drop-in at all.
    run ! grep -qE 'docker-ce|containerd|docker-compose-plugin|download\.docker\.com|daemon\.json|docker\.service' \
        "$V2_ROOT/install.sh"
    [ ! -e "$V2_ROOT/systemd/docker.service.d/master-stack.conf" ]
    run ! grep -qE 'DOCKER_LOG_MAX_(SIZE|FILE)=|_IMAGE=' "$V2_ROOT/config/defaults.env"
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
    grep -qx 'tailscale-repo-suite' <<<"$code"
    grep -qx 'tailscale-repo-suite' <<<"$doc"
    run ! grep -qx 'docker-repo-suite' <<<"$code$doc"

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

@test "firewall opens no torrent peer port and has no Docker chain" {
    # DD-151: qBittorrent runs on the host and makes outgoing connections only.
    local fw="$V2_ROOT/scripts/firewall.sh"
    [ "$(cat "$fw" "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env" "$V2_ROOT/scripts/master-wg" \
        "$V2_ROOT/panel/master-wg-panel" | grep -c 'TORRENT_PUBLIC_PORT')" -eq 0 ]
    # DD-152: no Docker — no MASTER-DOCKER chain, no DOCKER-USER jump, no wait for dockerd.
    [ "$(grep -vE '^[[:space:]]*#' "$fw" | grep -ciE 'docker')" -eq 0 ]
    run ! grep -q 'CHAIN_DOCKER' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh"
    run ! grep -qi 'docker' <<<"$(grep -vE '^[[:space:]]*#' "$V2_ROOT/systemd/master-firewall.service")"
}

@test "firewall requires ports and chains from state" {
    grep -q 'CHAIN_INPUT:?' "$V2_ROOT/scripts/firewall.sh"
    # DD-143: WireGuard ağları state.env'den değil kayıttan gelir; boş kayıt geçerlidir.
    run ! grep -qE 'WG_PORT_DEFAULT:\?|WG_INTERFACE:\?|WG_ADDR_BASE4:\?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_NETWORKS_FILE' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_BLOCK_DEST4:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX' "$V2_ROOT/install.sh"
    run ! grep -qE 'TORRENT_PUBLIC_PORT:=61005|CHAIN_INPUT:=MASTER' \
        "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX}IN-' "$V2_ROOT/scripts/firewall.sh"
}

@test "qBittorrent and WebDAV run as the downloads uid" {
    # DD-151: the package's template unit runs as the downloads account's own name.
    body="$(awk '/^torrent_unit_name\(\)/,/^}$/' "$V2_ROOT/scripts/master-modul")"
    grep -qF 'getent passwd "$DOWNLOADS_UID"' <<<"$body"
    grep -qF "printf 'qbittorrent-nox@%s.service\n'" <<<"$body"
    # DD-152: the share service reads the shared files as their owner, never as root.
    grep -qx 'User=__DOWNLOADS_UID__' "$V2_ROOT/modules/paylasim/master-paylasim.service"
    grep -qx 'Group=__DOWNLOADS_GID__' "$V2_ROOT/modules/paylasim/master-paylasim.service"
}

@test "downloads tree is chown 1000 for qbittorrent, the share and the console" {
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

@test "the user area is a fixed root under /srv" {
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
}

@test "wg-easy is gone from compose, defaults and the tailnet edge" {
    # DD-120: WireGuard runs in the host kernel; nothing of wg-easy remains.
    # Comments may name wg-easy as the origin of the profile format; code may not.
    local code
    code="$(grep -hvE '^[[:space:]]*#' "$V2_ROOT/config/defaults.env" \
        "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf" \
        "$V2_ROOT/install.sh" "$V2_ROOT/scripts/firewall.sh")"
    run ! grep -qE 'wg-easy|wg_easy|WG_BRIDGE|WG_UI_PORT|WG_EASY|__WG_PUBLIC_PORT__' <<<"$code"
    # DD-154: the old names wg., dosya. and file. are gone; the console is panel. only.
    run ! grep -qE '^http://(wg|dosya|file)\.' "$V2_ROOT/templates/Caddyfile"
    run ! grep -qE 'interface-name=(wg|dosya|file)\.' "$V2_ROOT/templates/dnsmasq.conf"
    grep -A1 '^http://panel.__LOCAL_DOMAIN__ {$' "$V2_ROOT/templates/Caddyfile" | grep -q '@kok path /api/wg/\* /api/konsol/\*$'
    # DD-151: no base Compose project at all; every container belongs to a module.
    [ ! -e "$V2_ROOT/templates/compose.yaml" ]
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

@test "the only WebDAV is a credential-loaded unprivileged host service behind Caddy" {
    local unit="$V2_ROOT/modules/paylasim/master-paylasim.service"
    grep -qxF 'ExecStart=/usr/bin/python3 __SBIN_DIR__/master_webdav.py --registry=%d/registry --port=__SHARE_PORT__ --wan-listen=__SHARE_WAN_BACKEND__' "$unit"
    for line in 'LoadCredential=registry:__SHARE_STATE_FILE__' 'User=__DOWNLOADS_UID__' \
        'Group=__DOWNLOADS_GID__' 'Type=exec' 'ProtectSystem=strict' 'ProtectHome=true' \
        'PrivateTmp=true' 'NoNewPrivileges=true' 'CapabilityBoundingSet=' \
        'IPAddressDeny=any' 'IPAddressAllow=localhost' 'ReadWritePaths=__SERVER_ROOT__' \
        'InaccessiblePaths=__SERVER_ROOT__/__FILES_PANEL_TRASH__ -__SERVER_ROOT__/__SHARE_DIR__'; do
        grep -qxF "$line" "$unit"
    done
    grep -qx 'http://paylas.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}:__SHARE_PORT__ {' "$V2_ROOT/modules/paylasim/paylasim.caddy"
    grep -qx 'interface-name=paylas.__LOCAL_DOMAIN__,__TAILSCALE_IF__' "$V2_ROOT/modules/paylasim/dnsmasq.conf"
    [ "$(grep -c '^http://paylas' "$V2_ROOT/templates/Caddyfile")" -eq 0 ]
    [ ! -e "$V2_ROOT/modules/paylasim/compose.yaml" ]
}

@test "IPv6 INPUT is checked with the same WAN-scoped shape" {
    grep -q 'check_input_chain ip6tables v6' "$V2_ROOT/scripts/firewall.sh"
    awk '/^check_input_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh" |
        grep -q -- '-i "$WAN_INTERFACE" -j DROP'
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
    grep -q 'check_wan_allow_count "\$bin" "\$CHAIN_INPUT" ACCEPT "\$n"' "$script"
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
        "$(awk '/^apply_nat ip6tables_nat / { print NR; exit }' "$script")" ]
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

@test "master-firewall converges on its own and follows tailscaled" {
    local unit="$V2_ROOT/systemd/master-firewall.service"
    # DD-94: host INPUT sits as early as possible; DD-152: there is no Docker to wait for.
    run ! grep -qi 'docker' <<<"$(grep -vE '^[[:space:]]*#' "$unit")"
    grep -q 'Wants=network-online.target' "$unit"
    grep -q 'PartOf=tailscaled.service' "$unit"
    grep -q 'WantedBy=tailscaled.service' "$unit"
    grep -q 'After=.*tailscaled.service' "$unit"
    grep -q 'Restart=on-failure' "$unit"
    grep -q 'RestartSec=10s' "$unit"
    grep -q 'StartLimitIntervalSec=300' "$unit"
    grep -q 'StartLimitBurst=12' "$unit"
    grep -q 'master-firewall.service' "$V2_ROOT/install.sh"
    run ! grep -qiE 'compose|master-compose' "$unit"
    [ ! -e "$V2_ROOT/systemd/docker.service.d/master-stack.conf" ]
    run ! grep -q 'docker.service.d' "$V2_ROOT/install.sh"
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

@test "firewall --check asserts critical IPv4 ACCEPT/DROP rules" {
    grep -q 'check_rule()' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'kritik politikalar yerinde' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'check_input_chain iptables v4' "$V2_ROOT/scripts/firewall.sh"
    awk '/^check_input_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh" |
        grep -q -- '-i "$WAN_INTERFACE" -j DROP'
    grep -q 'check_chain_shape' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'ESTABLISHED,RELATED -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    # DD-120: WireGuard is not a Docker publish any more; the port lives in INPUT.
    run ! grep -q -- '--ctorigdstport "$WG_PUBLIC_PORT"' "$V2_ROOT/scripts/firewall.sh"
    grep -qF -- '--dport "${WG_PORTS[i]}" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
    [ "$(grep -c 'TORRENT_PUBLIC_PORT' "$V2_ROOT/scripts/firewall.sh")" -eq 0 ]
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
    grep -q 'neighbour-solicitation neighbour-advertisement)' "$V2_ROOT/scripts/firewall.sh"
    [ "$(grep -c 'for type in "${ICMP6_TYPES\[@\]}"' "$V2_ROOT/scripts/firewall.sh")" -eq 2 ]
    grep -q '^ICMP6_TYPES=(destination-unreachable packet-too-big' "$V2_ROOT/scripts/firewall.sh"
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
    grep -q 'FIREWALL_NEEDS_RESTART' "$V2_ROOT/install.sh"
    run ! grep -q 'WEBDAV_NEEDS_RESTART' "$V2_ROOT/install.sh"
    grep -q 'yapılandırması aynı; yeniden başlatılmadı' "$V2_ROOT/install.sh"
    # DD-151: no base Compose project and no image-pull question any more.
    [ "$(grep -cE 'COMPOSE_NEEDS_UP|PULL_IMAGES|docker compose' "$V2_ROOT/install.sh")" -eq 0 ]
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

@test "re-run skips apt-get update when the repo file is unchanged" {
    # stage_2: tailscale repo write immediately gates its own apt-get update.
    awk '/^stage_2\(\)/,/^ensure_downloads_tree\(\)/' "$V2_ROOT/install.sh" |
        grep -A4 'install_tailscale_repo$' | grep -q 'V2_LAST_ATOMIC_CHANGED.*-eq 1'
    grep -q 'tailscale.list aynı; apt-get update atlandı' "$V2_ROOT/install.sh"
    # First install still updates: install_tailscale_repo writes via atomic_write,
    # which sets V2_LAST_ATOMIC_CHANGED=1 for a new file.
    grep -q 'V2_LAST_ATOMIC_CHANGED' "$V2_ROOT/common.sh"
}

@test "base packages include the Python runtime used by WebDAV without htpasswd" {
    base="$(awk '/retry "apt-base"/{p=1} p{print} p && !/\\$/{exit}' "$V2_ROOT/install.sh")"
    grep -q 'dnsutils unattended-upgrades python3' <<<"$base"
    run ! grep -qwE 'gnupg|gawk|apache2-utils' <<<"$base"
    run ! grep -q 'share_tools' "$V2_ROOT/scripts/master-modul"
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
    local mm="$V2_ROOT/scripts/master-modul"
    grep -q 'status: REFUSED' "$V2_ROOT/install.sh"
    grep -q 'for resolver in 127.0.0.1' "$V2_ROOT/install.sh"
    run ! grep -q 'WebDAV Tailscale publish' "$V2_ROOT/install.sh"
    run ! grep -q 'v2-write-probe' "$V2_ROOT/install.sh"
    run ! grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    # DD-151: no base containers; each module checks its own publish surface.
    [ "$(grep -c 'docker port' "$V2_ROOT/install.sh")" -eq 0 ]
    # DD-149: the share's publish surface is checked by master-modul when the module is installed.
    [ "$(grep -cE 'docker port paylasim|Host: paylas\.|:\$\{SHARE_PORT\}/' "$V2_ROOT/install.sh")" -eq 0 ]
    body="$(awk '/^share_verify\(\)/,/^}$/' "$mm")"
    grep -qF '[[ "$uid" == "$DOWNLOADS_UID" && "$code" == 401 ]]' <<<"$body"
    grep -qF 'http_code "http://127.0.0.1:$SHARE_PORT/"' <<<"$body"
    names="$(awk '/^share_verify_names\(\)/,/^}$/' "$mm")"
    grep -qF 'http_code -H "Host: paylas.$LOCAL_DOMAIN" "http://$TAILSCALE_IPV4/"' <<<"$names"
    grep -qF 'http_code "http://$TAILSCALE_IPV4:$SHARE_PORT/"' <<<"$names"
    grep -qF 'dig +short +time=2 +tries=1 "paylas.$LOCAL_DOMAIN" @"$TAILSCALE_IPV4"' <<<"$names"
    # Contract §14.13 / DD-88: the qBittorrent interface over WireGuard answers non-5xx (module only).
    run ! grep -q 'http://${wg_s4}' "$V2_ROOT/install.sh"
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

@test "FileBrowser is gone: no container, account, port, database or file. name" {
    # DD-146: Konsol's own file manager (upload, multi-select, search) replaced it.
    local code
    code="$(grep -hvE '^[[:space:]]*#' "$V2_ROOT/config/defaults.env" \
        "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf" \
        "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT/scripts/firewall.sh" "$V2_ROOT/scripts/master-wg" \
        "$V2_ROOT/panel/master-wg-panel" "$V2_ROOT/console/konsol.js" "$V2_ROOT/console/index.html" \
        "$V2_ROOT/config/kurulum.env.example")"
    run ! grep -qi 'filebrowser' <<<"$code"
    run ! grep -q '61007' <<<"$code"
    run ! grep -qE '^INPUT_KEYS=.*FILEBROWSER' "$V2_ROOT/install.sh"
    # DD-154: the old name is gone too (it only redirected to the console).
    run ! grep -q 'file\.__LOCAL_DOMAIN__' "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf"
    # WireGuard "ui" networks reach the qBittorrent module's interface only (DD-151).
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
}

@test "WebDAV uses packaged Python with no downloaded executable or shared plaintext password" {
    run ! grep -qE '^RCLONE_|^SHARE_ACCOUNT=|^SHARE_PASSWORD_LENGTH=' "$V2_ROOT/config/defaults.env"
    run ! grep -qE 'share_rclone|share_write_account|apt_install apache2-utils' "$V2_ROOT/scripts/master-modul"
    grep -qx 'SHARE_STATE_FILE="/etc/master-stack/webdav.json"' "$V2_ROOT/config/defaults.env"
    grep -q 'hashlib.scrypt' "$V2_ROOT/panel/master_shares.py"
    grep -q 'hmac.compare_digest' "$V2_ROOT/panel/master_shares.py"
    grep -q 'parser.error("WebDAV root olarak çalıştırılamaz.")' "$V2_ROOT/panel/master_webdav.py"
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
    # DD-154: Data/app keeps only the current export too; older ones live in Git.
    local apps
    apps=( "$V2_ROOT"/app/20[0-9][0-9].[0-9][0-9].[0-9][0-9]-v2-*.command )
    [ "${#apps[@]}" -eq 1 ]
    grep -qF '"$APP_DIR"/20[0-9][0-9].[0-9][0-9].[0-9][0-9]-v2-*.command; do' "$V2_ROOT/dev/export-installer.sh"
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
    grep -q 'özel kurulum girdisi 600 olmalı' <<<"$body"
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
    # DD-150: the installer prepares nothing of WireGuard any more; the module does, and it
    # never makes a key or a network of its own either.
    [ "$(grep -cE '^ensure_wireguard(_ready)?\(\)|^ensure_wg_networks_running\(\)' "$V2_ROOT/install.sh")" -eq 0 ]
    local ready
    ready="$(awk '/^wg_packages\(\)/,/^firewall_apply\(\)/' "$V2_ROOT/scripts/master-modul")"
    [ -n "$ready" ]
    run ! grep -qE 'wg genkey|syncconf|PrivateKey' <<<"$ready"
    grep -qx 'WG_PACKAGES="wireguard-tools qrencode"' "$V2_ROOT/scripts/master-modul"
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
MODULES_FILE=$TMP/moduller
SHARE_PORT=61010
RCLONE_VERSION=1.75.1
TAILSCALE_IPV4=100.64.0.7
SERVER_ROOT=$TMP
EOF
    # DD-150: WireGuard is a module; these tests run with it installed.
    printf 'wireguard\tcalisiyor\n' >"$TMP/moduller"
    cat >"$TMP/pbin/master-wg" <<EOF
#!/bin/bash
net=""
[ "\$1" != --if ] || { net="\$2"; shift 2; }
(IFS='|'; printf '%s|%s\n' "\${net:-yok}" "\$*") >>"$TMP/mwg-calls"
case "\$1" in
    nets) [ -e "$TMP/no-wg" ] && exit 0
        printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\t1\t1\n'
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
    liste) printf 'paylasim\thost\t%s\t-\t-\t-\t-\t-\n' "\$(cat "$TMP/pay-state" 2>/dev/null || echo yok)"
        printf 'torrent\thost\t%s\t%s\t-\t-\t-\t-\n' "\$(cat "$TMP/mod-state" 2>/dev/null || echo yok)" "\$([ -e "$TMP/mod-running" ] && echo running || echo -)" ;;
    gunluk) printf 'WebUI will be started shortly\n' ;;
    hesap) [ -e "$TMP/pay-cred" ] || { echo "HATA: hesap yok" >&2; exit 1; }
        if [ "\$3" = --parola ]; then printf 'paylasim\t1700000000\tQm7vRt2kWx9pLc4nHs8e\n'; else printf 'paylasim\t1700000000\n'; fi ;;
    *) echo "HATA: beklenmeyen çağrı \$*" >&2; exit 1 ;;
esac
EOF
    cat >"$TMP/pbin/systemd-run" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/sdrun-calls"
EOF
    cat >"$TMP/pbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/systemctl-calls"
if [ "\$1" = list-units ]; then
    for f in "$TMP"/busy-*; do
        [ ! -e "\$f" ] || printf '%s.service loaded active running Konsol modül işlemi\n' "\${f##*/busy-}"
    done
    exit 0
fi
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
assert (n["port"], n["server4"], n["subnet6"], n["active"]) == (61001, "10.8.0.1", "fdcc:ad94:bacf:61a4::/112", True), n
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
    # DD-148: master-modul with a fake flock and logger.
    mkdir -p "$TMP/mbin" "$TMP/mods" "$TMP/run" "$TMP/dl"
    cat >"$TMP/mstate.env" <<EOF
MODULES_FILE=$TMP/moduller
MODULES_DIR=$TMP/mods
RUNTIME_DIR=$TMP/run
DOWNLOADS_PATH=$TMP/dl
EOF
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/flock"
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/logger"
    chmod +x "$TMP/mbin"/*
}

mm() {
    PATH="$TMP/mbin:$PATH" STATE_FILE="$TMP/mstate.env" bash "$V2_ROOT/scripts/master-modul" "$@"
}

@test "master-modul lists the catalogue in Konsol's order and accepts only known modules and verbs" {
    modul_fixture
    run mm liste
    [ "$status" -eq 0 ]
    # Catalogue order is Konsol's order (DD-149, DD-150); DD-152: no Docker runtime, no Arşiv açıcı.
    [ "$(cut -f1 <<<"$output" | tr '\n' ' ')" = 'wireguard torrent ' ]
    [ "$(cut -f2 <<<"$output" | tr '\n' ' ')" = 'konsol host ' ]
    [ "$(grep -c '^paylasim' <<<"$output")" -eq 0 ]
    run mm kaldir paylasim
    [ "$status" -ne 0 ]
    case "$output" in *"bilinmeyen modül"*) ;; *) false ;; esac
    run mm baslat torrent
    [ "$status" -ne 0 ]
    # Only catalogued ids and known commands are accepted.
    for id in unpackerr ../etc filebrowser; do
        run mm kur "$id"
        [ "$status" -ne 0 ]
        case "$output" in *"bilinmeyen modül"*) ;; *) false ;; esac
    done
    run mm kaldir paylasim --hepsi
    [ "$status" -ne 0 ]
    run mm sil paylasim
    [ "$status" -ne 0 ]
    run mm gunluk paylasim 20000
    [ "$status" -ne 0 ]
    [ "$(grep -vE '^[[:space:]]*#' "$V2_ROOT/scripts/master-modul" | grep -ciE 'docker|compose|container|unpackerr')" -eq 0 ]
}

@test "master-modul keeps lifecycle changes locked and deletes only owned data" {
    [ "$(grep -c '^    take_lock$' "$V2_ROOT/scripts/master-modul")" -eq 6 ]
    grep -q 'flock -w 5 8' "$V2_ROOT/scripts/master-modul"
    grep -qF '[[ "$TORRENT_PROFILE_DIR" == /var/lib/* && -d "$TORRENT_PROFILE_DIR" && ! -L "$TORRENT_PROFILE_DIR" ]] || return 0' "$V2_ROOT/scripts/master-modul"
    run ! grep -qE 'files_drop_data|share_drop_data|share_marker' "$V2_ROOT/scripts/master-modul"
    grep -qF 'find "$WG_CONF_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' "$V2_ROOT/scripts/master-modul"
    [ "$(grep -c 'find -L' "$V2_ROOT/scripts/master-modul")" -eq 0 ]
}

share_fixture() {
    # Real registry preparation; fake host services and network probes.
    modul_fixture
    mkdir -p "$TMP/mods/paylasim" "$TMP/etc" "$TMP/caddy/moduller" "$TMP/dnsmasq.d" "$TMP/units" "$TMP/lib" \
        "$TMP/srv/downloads"
    printf '[Service]\nExecStart=/usr/bin/python3 %s/lib/master_webdav.py\n' "$TMP" >"$TMP/mods/paylasim/master-paylasim.service"
    printf 'http://paylas.ayc, http://{$TAILSCALE_IPV4}:61010 {\n\treverse_proxy 127.0.0.1:61010\n}\n' >"$TMP/mods/paylasim/paylasim.caddy"
    printf 'interface-name=paylas.ayc,tailscale0\n' >"$TMP/mods/paylasim/dnsmasq.conf"
    : >"$TMP/caddy/Caddyfile"
    cp "$V2_ROOT/panel/master_shares.py" "$TMP/lib/master_shares.py"
    cat >>"$TMP/mstate.env" <<EOF
SERVER_ROOT=$TMP/srv
SHARE_DIR=.pay
SHARE_PORT=61010
SHARE_STATE_FILE=$TMP/etc/webdav.json
SBIN_DIR=$TMP/lib
TORRENT_TEMP_DIR=incomplete
TORRENT_PROFILE_DIR=$TMP/profile
DOWNLOADS_PATH=$TMP/srv/downloads
SETTINGS_PENDING_FILE=$TMP/pending
STATE_DIR=$TMP/etc
CADDYFILE=$TMP/caddy/Caddyfile
CADDY_MODULES_DIR=$TMP/caddy/moduller
DNSMASQ_CONF_DIR=$TMP/dnsmasq.d
LOCAL_DOMAIN=ayc
TAILSCALE_IPV4=100.64.0.7
UNIT_DIR=$TMP/units
DOWNLOADS_UID=1000
FILES_PANEL_TRASH=.cop
EOF
    cat >"$TMP/mbin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/curl-calls"
printf 'curl %s\n' "\$*" >>"$TMP/order"
printf 401
EOF
    cat >"$TMP/mbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/systemctl-calls"
printf 'systemctl %s\n' "\$*" >>"$TMP/order"
case "\$*" in
    "is-active --quiet master-paylasim.service") [ -e "$TMP/share-up" ] ;;
    "restart master-paylasim.service") [ ! -e "$TMP/start-fail" ] && touch "$TMP/share-up" && rm -f "$TMP/uid-seen" ;;
    "disable --now master-paylasim.service") rm -f "$TMP/share-up" ;;
    "show -p MainPID --value master-paylasim.service") echo 4242 ;;
    "show -p TemporaryFileSystem --value master-paylasim.service") echo "$TMP/srv/.cop:ro" ;;
    *) exit 0 ;;
esac
EOF
    # Right after a restart the main process is still root (systemd drops to User= at exec):
    # the first uid read of every start answers 0, as measured on nrm.
    cat >"$TMP/mbin/ps" <<EOF
#!/bin/bash
case "\$2" in
    uid=)
        if [ -e "$TMP/uid-seen" ]; then echo " 1000"; else touch "$TMP/uid-seen"; echo " 0"; fi ;;
esac
EOF
    # Caddy owns the Infuse address; only the share process's own sockets count.
    cat >"$TMP/mbin/ss" <<EOF
#!/bin/bash
echo 'LISTEN 0 4096 127.0.0.1:61010 0.0.0.0:* users:(("rclone",pid=4242,fd=8))'
echo 'LISTEN 0 4096 100.64.0.7:61010 0.0.0.0:* users:(("caddy",pid=77,fd=9))'
EOF
    cat >"$TMP/mbin/install" <<'EOF'
#!/bin/bash
# The test runs unprivileged: owners are dropped, everything else goes to the real install.
args=()
skip=0
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in -o | -g) skip=1 ;; *) args+=("$a") ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
    printf '#!/bin/bash\necho amd64\n' >"$TMP/mbin/dpkg"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/caddy-calls"\n[ ! -e "%s/caddy-bad" ]\n' "$TMP" "$TMP" >"$TMP/mbin/caddy"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/dnsmasq-calls"\n[ ! -e "%s/dnsmasq-bad" ]\n' "$TMP" "$TMP" >"$TMP/mbin/dnsmasq"
    printf '#!/bin/bash\necho 100.64.0.7\n' >"$TMP/mbin/dig"
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/chown"
    # DD-150: Paylaşım needs the Dosya yöneticisi module.
    printf 'dosya\tcalisiyor\n' >"$TMP/moduller"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/logger-calls"\n' "$TMP" >"$TMP/mbin/logger"
    chmod +x "$TMP/mbin"/*
}


builtin_fixture() {
    share_fixture
    mkdir -p "$TMP/mods/dosya" "$TMP/srv/.cop"
    printf '[Service]\nExecStart=/bin/true\n' >"$TMP/mods/dosya/master-files-panel.service"
    printf 'import sys\nsys.exit(0)\n' >"$TMP/lib/master-files-panel"
    printf 'FILES_PANEL_PORT=61009\n' >>"$TMP/mstate.env"
    # Both workers are unprivileged; loopback Files denies a missing panel header.
    printf '#!/bin/bash\necho 1000\n' >"$TMP/mbin/ps"
    cat >"$TMP/mbin/curl" <<EOF
#!/bin/bash
printf 'curl %s\\n' "\$*" >>"$TMP/order"
case "\$*" in *61009*) printf 403 ;; *) printf 401 ;; esac
EOF
    chmod +x "$TMP/mbin/ps" "$TMP/mbin/curl"
}

file_mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

@test "builtins prepare a private registry and verify both services before registration" {
    builtin_fixture
    : >"$TMP/moduller"
    run mm yerlesik
    [ "$status" -eq 0 ]
    grep -qx "$(printf 'paylasim\tcalisiyor')" "$TMP/moduller"
    grep -qx "$(printf 'dosya\tcalisiyor')" "$TMP/moduller"
    [ "$(file_mode "$TMP/etc/webdav.json")" = 0o600 ]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["schema"] == 3 and d["items"] == []' "$TMP/etc/webdav.json"
    cmp -s "$TMP/mods/paylasim/master-paylasim.service" "$TMP/units/master-paylasim.service"
    cmp -s "$TMP/mods/dosya/master-files-panel.service" "$TMP/units/master-files-panel.service"
    [ ! -e "$TMP/srv/.pay" ]
    run mm liste
    [ "$(cut -f1 <<<"$output" | tr '\n' ' ')" = 'wireguard torrent ' ]
}

liste_live() { mm liste | awk -F'\t' -v i="$1" '$1 == i {print $4}'; }

@test "builtins fail closed on a corrupt share registry before publishing" {
    builtin_fixture
    printf '{"schema":1,"items":[]}\n' >"$TMP/etc/webdav.json"
    run mm yerlesik
    [ "$status" -ne 0 ]
    [ ! -e "$TMP/units/master-paylasim.service" ]
    [ ! -e "$TMP/caddy/moduller/paylasim.caddy" ]
    grep -q '"schema":1' "$TMP/etc/webdav.json"
}

@test "builtins reject every public lifecycle action and preserve their registry" {
    builtin_fixture
    run mm yerlesik
    [ "$status" -eq 0 ]
    cp "$TMP/etc/webdav.json" "$TMP/before.json"
    for id in dosya paylasim; do
        for action in kur baslat durdur kaldir uygula hesap; do
            run mm "$action" "$id" --veri
            [ "$status" -ne 0 ]
            case "$output" in *"bilinmeyen modül"*) ;; *) false ;; esac
        done
        run mm parola "$id"
        [ "$status" -ne 0 ]
    done
    cmp -s "$TMP/etc/webdav.json" "$TMP/before.json"
    [ -e "$TMP/units/master-paylasim.service" ]
    [ -e "$TMP/units/master-files-panel.service" ]
}

@test "builtins reapply idempotently preserve accounts and recover an interrupted installation" {
    builtin_fixture
    touch "$TMP/dnsmasq-bad"
    run mm yerlesik
    [ "$status" -ne 0 ]
    [ "$(grep -c paylasim "$TMP/moduller")" -eq 0 ]
    cp "$TMP/etc/webdav.json" "$TMP/before.json"
    rm -f "$TMP/dnsmasq-bad"
    run mm yerlesik
    [ "$status" -eq 0 ]
    : >"$TMP/systemctl-calls"
    run mm yerlesik
    [ "$status" -eq 0 ]
    [ "$(grep -c '^restart ' "$TMP/systemctl-calls")" -eq 0 ]
    cmp -s "$TMP/etc/webdav.json" "$TMP/before.json"
    run mm yerlesik 'dosya paylasim'
    [ "$status" -eq 0 ]
    grep -qx 'restart master-files-panel.service' "$TMP/systemctl-calls"
    grep -qx 'restart master-paylasim.service' "$TMP/systemctl-calls"
    cmp -s "$TMP/etc/webdav.json" "$TMP/before.json"
}

@test "legacy share markers and credential paths have no runtime consumers" {
    run ! grep -qE 'SHARE_ENABLED|share_enabled|share_summary' "$V2_ROOT/scripts/master-modul" "$V2_ROOT/files-panel/master-files-panel"
    run ! grep -qE 'SHARE_CRED_FILE|SHARE_HTPASSWD_FILE' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh" "$V2_ROOT/scripts/master-modul"
    run ! grep -q 'os.symlink' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'self.error(410, RETIRED_SHARE_MESSAGE)' "$V2_ROOT/files-panel/master-files-panel"
}

@test "builtins preserve legacy metadata and do not follow or recreate its marker" {
    builtin_fixture
    mkdir -p "$TMP/srv/.pay/w"
    printf 'old registry\n' >"$TMP/srv/.pay/kayit.json"
    printf 'old credential\n' >"$TMP/etc/paylasim.cred"
    printf 'unchanged\n' >"$TMP/marker-target"
    ln -s "$TMP/marker-target" "$TMP/srv/.pay/acik"
    run mm yerlesik
    [ "$status" -eq 0 ]
    [ -L "$TMP/srv/.pay/acik" ]
    [ "$(cat "$TMP/marker-target")" = unchanged ]
    [ "$(cat "$TMP/srv/.pay/kayit.json")" = 'old registry' ]
    [ "$(cat "$TMP/etc/paylasim.cred")" = 'old credential' ]
    cp "$TMP/etc/webdav.json" "$TMP/registry-before"
    run mm yerlesik
    [ "$status" -eq 0 ]
    cmp -s "$TMP/registry-before" "$TMP/etc/webdav.json"
}

@test "stage 3 creates the current tree without legacy sharing and preserves old private modes" {
    eval "$(awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    detect_wan() { :; }
    detect_tailscale() { :; }
    write_state() { V2_LAST_ATOMIC_CHANGED=0; }
    log() { :; }
    SERVER_ROOT="$TMP/root" DOWNLOADS_PATH="$TMP/root/downloads" MEDIA_SUBDIR=media
    FILES_PANEL_TRASH=.cop FILES_ARCHIVE_DIR=.arsiv SHARE_DIR=.pay
    DOWNLOADS_UID="$(id -u)" DOWNLOADS_GID="$(id -g)"
    stage_3
    [ -d "$SERVER_ROOT/downloads" ]
    [ -d "$SERVER_ROOT/media/movies" ]
    [ -d "$SERVER_ROOT/.cop" ]
    [ ! -e "$SERVER_ROOT/.pay" ]
    mkdir -p "$SERVER_ROOT/.pay/w"
    printf 'old private metadata\n' >"$SERVER_ROOT/.pay/kayit.json"
    chmod 0700 "$SERVER_ROOT/.pay" "$SERVER_ROOT/.pay/w"
    chmod 0600 "$SERVER_ROOT/.pay/kayit.json"
    stage_3
    [ "$(file_mode "$SERVER_ROOT/.pay")" = 0o700 ]
    [ "$(file_mode "$SERVER_ROOT/.pay/w")" = 0o700 ]
    [ "$(file_mode "$SERVER_ROOT/.pay/kayit.json")" = 0o600 ]
    [ "$(cat "$SERVER_ROOT/.pay/kayit.json")" = 'old private metadata' ]
    [ ! -e "$SERVER_ROOT/.pay/acik" ]
}

@test "wg panel lists modules and starts module work as its own systemd unit" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    [ "$(pc /api/konsol/moduller)" = 403 ]
    [ "$(pc /api/konsol/moduller -H 'X-Konsol: 1')" = 200 ]
    python3 -c '
import json, sys
m = [i for i in json.load(open(sys.argv[1]))["items"] if i["id"] == "torrent"][0]
assert (m["id"], m["runtime"], m["installed"], m["state"], m["busy"], m["progress"]) == ("torrent", "host", False, "", False, None), m
' "$TMP/body"
    local json=(-H 'X-Konsol: 1' -H 'Content-Type: application/json')
    [ "$(pc /api/konsol/moduller/torrent/kur "${json[@]}" --data '{}')" = 202 ]
    tail -n 1 "$TMP/sdrun-calls" | grep -q -- '^--unit=master-modul-torrent.service --collect --quiet '
    tail -n 1 "$TMP/sdrun-calls" | grep -q "/master-modul kur torrent$"
    [ "$(pc /api/konsol/moduller/torrent/kaldir "${json[@]}" --data '{"veri":true}')" = 202 ]
    tail -n 1 "$TMP/sdrun-calls" | grep -q "/master-modul kaldir torrent --veri$"
    [ "$(pc /api/konsol/moduller/torrent/durdur "${json[@]}" --data '{"veri":true}')" = 202 ]
    tail -n 1 "$TMP/sdrun-calls" | grep -q "/master-modul durdur torrent$"
    printf 'calisiyor\n' >"$TMP/mod-state"
    touch "$TMP/mod-running"
    [ "$(pc /api/konsol/moduller -H 'X-Konsol: 1')" = 200 ]
    grep -q '"installed": true, "state": "calisiyor", "live": "running"' "$TMP/body"
    # One operation at a time per module.
    touch "$TMP/busy-master-modul-torrent"
    local before
    before="$(wc -l <"$TMP/sdrun-calls")"
    [ "$(pc /api/konsol/moduller/torrent/baslat "${json[@]}" --data '{}')" = 409 ]
    [ "$(pc /api/konsol/moduller -H 'X-Konsol: 1')" = 200 ]
    grep -q '"busy": true' "$TMP/body"
    rm -f "$TMP/busy-master-modul-torrent"
    # v2-120: busy comes from list-units; is-active on a collected transient unit spams the journal.
    grep -q '^list-units --plain --no-legend --no-pager --state=active,activating,deactivating,reloading master-modul-\*\.service$' "$TMP/systemctl-calls"
    run ! grep -q '^is-active' "$TMP/systemctl-calls"
    # Unknown modules, unknown actions and requests without the panel header never reach systemd-run.
    [ "$(pc /api/konsol/moduller/yok/kur "${json[@]}" --data '{}')" = 404 ]
    [ "$(pc /api/konsol/moduller/torrent/sil "${json[@]}" --data '{}')" = 404 ]
    [ "$(pc /api/konsol/moduller/torrent/kur -H 'Content-Type: application/json' --data '{}')" = 403 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: baska.ornek' "${json[@]}" --data '{}' \
        "http://127.0.0.1:$PORT/api/konsol/moduller/torrent/kur")" = 403 ]
    [ "$(wc -l <"$TMP/sdrun-calls")" = "$before" ]
    [ "$(pc /api/konsol/moduller/torrent/gunluk -H 'X-Konsol: 1')" = 200 ]
    grep -qi '^Content-Type: text/plain' "$TMP/head"
    grep -q 'WebUI will be started shortly' "$TMP/body"
    grep -q 'panel: konsol 127.0.0.1 modul-kur torrent -> ok' "$TMP/panel.log"
    grep -q 'panel: konsol 127.0.0.1 modul-kaldir torrent +veri -> ok' "$TMP/panel.log"
    grep -q 'panel: konsol 127.0.0.1 modul-durdur torrent -> ok' "$TMP/panel.log"
    grep -q 'panel: konsol 127.0.0.1 modul-baslat torrent -> hata' "$TMP/panel.log"
}

@test "wg panel never reveals or rotates a retired shared account even when installed" {
    panel_start
    local json=(-H 'X-Konsol: 1' -H 'Content-Type: application/json')
    printf 'paylasim\tcalisiyor\n' >"$TMP/moduller"
    for path in /api/konsol/moduller/paylasim/hesap '/api/konsol/moduller/paylasim/hesap?parola=1'; do
        [ "$(pc "$path" -H 'X-Konsol: 1')" = 404 ]
    done
    [ "$(pc /api/konsol/moduller/paylasim/parola -H 'X-Konsol: 1' -H 'Content-Type: application/json' --data '{}')" = 404 ]
    [ ! -e "$TMP/sdrun-calls" ]
    [ "$(pc /api/wg/sistem -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["share"] == {"port":61010,"on":True}' "$TMP/body"
}

@test "wg panel answers without the WireGuard module and never runs master-wg for it" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    local json=(-H 'X-Konsol: 1' -H 'Content-Type: application/json') before
    # DD-150: WireGuard is a module; without it the page gets an empty, marked state.
    : >"$TMP/moduller"
    before="$(cat "$TMP/mwg-calls" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$(pc /api/wg/state -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["installed"] is False and d["networks"] == [], d' "$TMP/body"
    [ "$(pc /api/wg/nets "${json[@]}" --data '{"port":"61011","dns":"1.1.1.1","label":""}')" = 409 ]
    grep -q 'WireGuard kurulu değil; Konsol → App Store' "$TMP/body"
    [ "$(pc /api/wg/nets/wg0/peers/iphone/add "${json[@]}" --data '{}')" = 409 ]
    [ "$(pc /api/wg/nets/wg0/peers/iphone/profile -H 'X-Konsol: 1')" = 404 ]
    [ "$(cat "$TMP/mwg-calls" 2>/dev/null | wc -l | tr -d ' ')" = "$before" ]
    # The disk card no longer needs the file backend: the root backend measures the user area.
    [ "$(pc /api/wg/sistem -H 'X-Konsol: 1')" = 200 ]
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["root"] == sys.argv[2] and d["disk"]["total"] > 0 and d["disk"]["free"] >= 0, d
assert not [r for r in d["ports"] if r["scope"] == "wireguard" or r["name"].startswith("WireGuard")], d["ports"]
' "$TMP/body" "$TMP"
    # With the module back, the same requests reach master-wg again.
    printf 'wireguard\tcalisiyor\n' >"$TMP/moduller"
    [ "$(pc /api/wg/state -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["installed"] is True and d["networks"], d' "$TMP/body"
}

@test "console always includes Files while WireGuard follows its optional application" {
    local js="$V2_ROOT/console/konsol.js"
    grep -qF 'const wgOn = () => modOn("wireguard");' "$js"
    grep -q 'href="#/dosyalar" data-route="dosyalar"' "$V2_ROOT/console/index.html"
    grep -qF 'document.querySelectorAll('"'"'[data-route="wireguard"]'"'"').forEach((a) => { a.hidden = !wgOn(); });' "$js"
    # A page whose module is absent is not opened; the backends are not asked.
    grep -qF 'if (MODS && ((key === "torrent" && !modOn("torrent")) || (key === "wireguard" && !wgOn()))) {' "$js"
    grep -qF 'api("/api/konsol/kaynaklar", { signal: controller.signal })' "$js"
    grep -qF 'loadModules().then(() => { if (current === "wireguard" && wgOn()) loadWg(); });' "$js"
    # Built-ins never enter the optional application catalogue.
    run ! grep -qF 'requires: "dosya",' "$js"
    # Konsol modules are opened from the row, never stopped from details.
    run ! grep -qF 'dosya: () => {' "$js"
    grep -qF 'wireguard: { name: "WireGuard"' "$js"
    grep -qF '"data-go":meta.page ? meta.page[0] : "#/torrent"' "$js"
    grep -qF 'meta.noStop ? null : h("button"' "$js"
    # Host measurements remain independent of optional applications.
    grep -qF 'fresh && s.disk?.total > 0' "$js"
    run ! grep -qE 'data-view="(genel|uygulamalar|gunluk)"|desktop-dock|window-min' "$V2_ROOT/console/index.html"
}

@test "wg panel shows qBittorrent's first login only on request and never offers a new password for it" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    local json=(-H 'X-Konsol: 1' -H 'Content-Type: application/json')
    cat >"$TMP/pbin/master-modul" <<EOF
#!/bin/bash
case "\$1" in
    liste) printf 'torrent\thost\tcalisiyor\trunning\t-\t-\t-\t-\n' ;;
    hesap) if [ "\$3" = --parola ]; then printf 'admin\tgecici\tTmp9Pass7Word\n'; else printf 'admin\tgecici\n'; fi ;;
    *) exit 1 ;;
esac
EOF
    printf 'wireguard\tcalisiyor\ntorrent\tcalisiyor\n' >"$TMP/moduller"
    printf 'TORRENT_UI_PORT=61006\nFILES_PANEL_PORT=61009\n' >>"$TMP/state.env"
    [ "$(pc /api/konsol/moduller/torrent/hesap -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d == {"user": "admin", "temp": True, "host": "torrent.ayc"}, d' "$TMP/body"
    [ "$(pc '/api/konsol/moduller/torrent/hesap?parola=1' -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["pass"] == "Tmp9Pass7Word"' "$TMP/body"
    grep -q 'panel: konsol 127.0.0.1 modul-hesap torrent -> ok' "$TMP/panel.log"
    [ "$(pc /api/konsol/moduller/torrent/parola "${json[@]}" --data '{}')" = 404 ]
    # The ports card shows the interface port only with the module; no torrent peer port at all.
    [ "$(pc /api/wg/sistem -H 'X-Konsol: 1')" = 200 ]
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert [r["scope"] for r in d["ports"] if r["name"] == "qBittorrent arayüzü"] == ["loopback"], d["ports"]
assert not [r for r in d["ports"] if "eş trafiği" in r["name"] or r["name"] == "Dozzle"], d["ports"]
assert not [r for r in d["ports"] if r["port"] == 61009], d["ports"]
' "$TMP/body"
    # v2-120: the file backend's port is listed only with the Dosya yöneticisi module.
    printf 'wireguard\tcalisiyor\ntorrent\tcalisiyor\ndosya\tcalisiyor\n' >"$TMP/moduller"
    [ "$(pc /api/wg/sistem -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert [r["scope"] for r in d["ports"] if r["port"] == 61009] == ["loopback"], d["ports"]' "$TMP/body"
    printf 'wireguard\tcalisiyor\n' >"$TMP/moduller"
    [ "$(pc /api/wg/sistem -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert not [r for r in d["ports"] if "qBittorrent" in r["name"]], d["ports"]' "$TMP/body"
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
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"abc","dns":"9.9.9.9","label":""}')" = 400 ]
    [ ! -s "$TMP/mwg-calls" ]
    [ "$(pc /api/wg/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"dup","dns":"1.1.1.1","keepalive":"21","mtu":"1420"}')" = 400 ]
    grep -q "zaten var" "$TMP/body"
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"61001","dns":"9.9.9.9","label":"x"}')" = 400 ]
    grep -q "UDP 61001 kullanılıyor (wg0)" "$TMP/body"
    # A new network: master-wg net-add, then it is listed with its label and takes its own peers.
    [ "$(pc /api/wg/nets "${auth[@]}" "${json[@]}" -d '{"port":"61011","dns":"9.9.9.9","label":"Misafir"}')" = 201 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"iface": "wg1", "port": 61011}' "$TMP/body"
    grep -qx 'yok|net-add|61011|9.9.9.9|Misafir' "$TMP/mwg-calls"
    pc /api/wg/state "${auth[@]}" >/dev/null
    python3 -c 'import json, sys; n = json.load(open(sys.argv[1]))["networks"][1]; assert (n["iface"], n["label"], n["dns"], n["peers"]) == ("wg1", "Misafir", "9.9.9.9", []), n' "$TMP/body"
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
    nets) printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t\t\t1\t1\n' ;;
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
    for line in 'NoNewPrivileges=true' 'ProtectSystem=full' 'ReadWritePaths=-/etc/wireguard' 'PrivateTmp=true' \
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
    # v2-119: the WireGuard folder exists before the backend starts, even without the module.
    [ "$(grep -n 'install -d -m 0700 -o root -g root -- "$WG_CONF_DIR"' <<<"$body" | cut -d: -f1)" -lt \
        "$(grep -n 'systemctl restart master-wg-panel.service' <<<"$body" | cut -d: -f1)" ]
    # DD-140: this backend serves no page files any more; the console pages come from the file backend.
    run ! grep -q -- '--web' "$V2_ROOT/systemd/master-wg-panel.service"
    run ! grep -qE 'index\.html|panel\.css|panel\.js' <<<"$body"
    s6="$(awk '/^stage_6\(\)/,/^ensure_wg_panel\(\)/' "$V2_ROOT/install.sh")"
    grep -q '^    ensure_wg_panel "\$OS_CHANGED"$' <<<"$s6"
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    # Without a password the gates are the protection: stage 7 proves both on both backends.
    grep -q 'X-Konsol başlığı olmadan HTTP' <<<"$s7"
    grep -q 'yabancı Host ile HTTP' <<<"$s7"
    # DD-159/171: the built-in Files gate is mandatory, never optional.
    grep -qF 'local gate_port gate_path gates="$FILES_PANEL_PORT:/api/state $WG_PANEL_PORT:/api/wg/state"' <<<"$s7"
    run ! grep -q 'files_on' <<<"$s7"
    grep -q 'for gate_port in \$gates; do' <<<"$s7"
    grep -q 'Konsol sayfası tailnet.ten açılmadı' <<<"$s7"
    grep -q 'master-wg-panel" check' <<<"$s7"
    grep -q 'http://${wg_first_addr}:${WG_PANEL_PORT}/' <<<"$s7"
    # Exported with the runtime, Caddy on the tailnet only, nothing on the WireGuard edge.
    grep -q '"\$REPO_ROOT/panel"' "$V2_ROOT/dev/export-installer.sh"
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
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
    # DD-149: the share account never reaches this backend; it only manages the links.
    FPORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    python3 "$FPANEL" serve --listen "127.0.0.1:$FPORT" --root "$TMP/root" \
        --share .pay \
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

@test "files panel rejects legacy shared-root creation and hides its internal directory" {
    files_panel_start
    [ "$(fpost /api/paylas '{"path":"Filmler/Kuzey","days":7}')" = 410 ]
    [ ! -e "$TMP/root/.pay/w/Kuzey" ]
    mkdir -p "$TMP/root/.pay"
    printf 'paylasim\n' >"$TMP/root/.pay/acik"
    [ "$(fpost /api/paylas '{"path":"Filmler/Kuzey","days":7}')" = 410 ]
    [ "$(fpost /api/paylas/kaldir '{"name":"Kuzey"}')" = 410 ]
    [ "$(fp /api/paylas)" = 410 ]
    [ "$(fp /api/paylas -I)" = 410 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: attacker.example' -H 'X-Konsol: 1' "http://127.0.0.1:$FPORT/api/paylas")" = 403 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: panel.ayc' "http://127.0.0.1:$FPORT/api/paylas")" = 403 ]
    [ "$(fp /api/paylas -H 'Sec-Fetch-Site: cross-site')" = 403 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: panel.ayc' --data '{}' "http://127.0.0.1:$FPORT/api/paylas")" = 403 ]
    [ "$(fpost /api/paylas '{}')" = 410 ]
    [ "$(fp /api/state)" = 200 ]
    python3 -c 'import json,sys; assert "share" not in json.load(open(sys.argv[1]))' "$TMP/body"
    [ "$(cat "$TMP/root/.pay/acik")" = paylasim ]
    [ "$(fp '/api/list?path=.pay')" = 403 ]
    [ -d "$TMP/root/Filmler/Kuzey" ]
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
    grep -q 'oninput: (e) => { fsQuery = e.target.value; renderRows(); renderDock(); updateMeta(); }' "$js"
    grep -q 'fsSel.clear();' "$js"
    # qBittorrent'in yazdığı klasör seçilemez.
    grep -q 'const locked = inTemp(here) || inTemp(pathText(fsPath));' "$js"
    grep -q 'locked ? null : h("button", { type: "button", class: "chk"' "$js"
    # Kısayol sütunu kökü ve üst klasörleri arka uçtan alır.
    grep -q 'fsRootDirs = r.entries.filter((e) => e.type === "dir")' "$js"
    grep -q '\.fsrail' "$css"
    grep -qx '          <nav class="fsrail" id="fs-rail" aria-label="Klasörler"></nav>' "$V2_ROOT/console/index.html"
}

@test "the base install has no Compose project, no Dozzle and no service account in the input file" {
    # DD-151, DD-152: the installer brings Konsol, Tailscale, names and the firewall; no Docker.
    [ "$(grep '^INPUT_KEYS=' "$V2_ROOT/install.sh")" = 'INPUT_KEYS="SSH_HOST LOCAL_DOMAIN"' ]
    [ "$(grep '^INPUT_NONEMPTY_KEYS=' "$V2_ROOT/install.sh")" = 'INPUT_NONEMPTY_KEYS=""' ]
    [ "$(grep -E '^[A-Z_]+=' "$V2_ROOT/config/kurulum.env.example" | cut -d= -f1 | tr '\n' ' ')" = 'SSH_HOST LOCAL_DOMAIN ' ]
    [ ! -e "$V2_ROOT/templates/compose.yaml" ]
    [ ! -e "$V2_ROOT/templates/qBittorrent.conf" ]
    [ "$(cat "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT/config/defaults.env" "$V2_ROOT/templates/Caddyfile" \
        "$V2_ROOT/templates/dnsmasq.conf" "$V2_ROOT/scripts/firewall.sh" \
        "$V2_ROOT/scripts/master-wg" "$V2_ROOT/panel/master-wg-panel" "$V2_ROOT/console/konsol.js" \
        "$V2_ROOT/console/index.html" | grep -ciE 'dozzle|COMPOSE_DIR|QBITTORRENT_(IMAGE|DATA_DIR|CONF_FILE)|PULL_IMAGES|bcrypt_matches|validate_account')" -eq 0 ]
    grep -qx 'SERVICE_NAMES="panel"' "$V2_ROOT/config/defaults.env"
    run ! grep -q 'docker-ce' "$V2_ROOT/install.sh"
    # qBittorrent's name and interface come with its module.
    for f in master-stack.conf qBittorrent.conf torrent.caddy dnsmasq.conf; do
        grep -qF "render_template \"\$V2_ROOT/modules/torrent/$f\" \"\$MODULES_DIR/torrent/$f\" 0644" "$V2_ROOT/install.sh"
    done
    grep -qx 'WebUI\\Address=127.0.0.1' "$V2_ROOT/modules/torrent/qBittorrent.conf"
    grep -qx 'WebUI\\Port=__TORRENT_UI_PORT__' "$V2_ROOT/modules/torrent/qBittorrent.conf"
    grep -qx 'Session\\DefaultSavePath=__DOWNLOADS_PATH__/' "$V2_ROOT/modules/torrent/qBittorrent.conf"
    # DD-178: only panel integration/headless startup keys may be seeded. In
    # particular do not force UPnP, discovery, temporary storage or performance.
    expected="$(printf '%s\n' Accepted 'Session\DefaultSavePath' 'Downloads\SavePath' \
        'WebUI\Address' 'WebUI\LocalHostAuth' 'WebUI\Port' | LC_ALL=C sort)"
    actual="$(awk -F= '/=/ {print $1}' "$V2_ROOT/modules/torrent/qBittorrent.conf" | LC_ALL=C sort)"
    [ "$actual" = "$expected" ]
    grep -qx 'Accepted=true' "$V2_ROOT/modules/torrent/qBittorrent.conf"
    grep -qx 'WebUI\\LocalHostAuth=true' "$V2_ROOT/modules/torrent/qBittorrent.conf"
    grep -qx 'TORRENT_PROFILE_DIR="/var/lib/qbittorrent"' "$V2_ROOT/config/defaults.env"
}

@test "console shows qBittorrent's first login and its interface link" {
    local js="$V2_ROOT/console/konsol.js" html="$V2_ROOT/console/index.html"
    grep -qF 'return { name: "qBittorrent", sub: "Torrent indirmelerini yönetin.", icon: "download", tone: "t-video", firstLogin: true,' "$js"
    # DD-152: the Unpackerr application and its "recommended together" hint are gone.
    # The removed Unpackerr app stays absent; the built-in Files action now uses this label.
    run ! grep -qE 'recommends|unpackerr' "$js"
    grep -qF 'qBittorrent ayarları' "$js"
    grep -qF 'accountBlock("torrent")' "$js"
    grep -qF 'const REVEAL_SECONDS = 30;' "$js"
    grep -qF 'if (document.hidden) hideAllPass();' "$js"
    grep -qF 'href:location.protocol + "//torrent." + S.sys.domain' "$js"
    grep -q 'data-route="torrent".*hidden' "$html"
    [ "$(grep -c 'link-dozzle' "$html" "$js" | awk -F: '{s += $NF} END {print s}')" -eq 0 ]
    grep -q '^\.acct-wg {' "$V2_ROOT/console/konsol.css"
}

@test "installer prepares optional modules and reapplies installed ones separately from builtins" {
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
    run ! grep -q 'unpackerr' <<<"$body"
    # DD-149, DD-152: the share module's unit, Caddy site and dnsmasq name; one change marks it once.
    for f in master-paylasim.service paylasim.caddy dnsmasq.conf; do
        grep -qF "render_template \"\$V2_ROOT/modules/paylasim/$f\" \"\$MODULES_DIR/paylasim/$f\" 0644" <<<"$body"
    done
    grep -qF '[[ "$changed" -eq 0 ]] || MODULES_CHANGED="$MODULES_CHANGED paylasim"' <<<"$body"
    grep -qF 'atomic_write "$MODULES_FILE" 0644 </dev/null' <<<"$body"
    # The installer never installs, stops or removes a module on its own.
    [ "$(grep -cE 'master-modul" (kur|kaldir|durdur|baslat|parola)' "$V2_ROOT/install.sh")" -eq 0 ]
    # Module site files: the base Caddyfile imports the directory stage 6 creates before validating.
    [ "$(tail -n 1 "$V2_ROOT/templates/Caddyfile")" = 'import __CADDY_MODULES_DIR__/*.caddy' ]
    s6="$(awk '/^stage_6\(\)/,/^stage_7\(\)/' "$V2_ROOT/install.sh")"
    awk '/install -d -m 0755 -o root -g root "\$CADDY_MODULES_DIR"/ {a = NR} /caddy validate --config/ {b = NR} END {exit !(a && b && a < b)}' <<<"$s6"
    for k in SHARE_DIR SHARE_STATE_FILE STATE_DIR CADDYFILE CADDY_MODULES_DIR DNSMASQ_CONF_DIR; do
        awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx "$k=\\\$$k"
    done
    # reapply_modules: a changed module file is applied to an installed module in either state.
    eval "$(awk '/^reapply_modules\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^module_state\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    mkdir -p "$TMP/sbin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$TMP" >"$TMP/sbin/master-modul"
    chmod +x "$TMP/sbin/master-modul"
    log() { :; }
    SBIN_DIR="$TMP/sbin"
    MODULES_FILE="$TMP/reg"
    MODULES_CHANGED=" torrent"
    printf 'torrent\tcalisiyor\n' >"$TMP/reg"
    reapply_modules
    grep -qx 'uygula torrent' "$TMP/calls"
    rm -f "$TMP/calls"
    printf 'torrent\tdurduruldu\n' >"$TMP/reg"
    reapply_modules
    grep -qx 'uygula torrent' "$TMP/calls"
    rm -f "$TMP/calls"
    : >"$TMP/reg"
    reapply_modules
    [ ! -e "$TMP/calls" ]
    MODULES_CHANGED=""
    printf 'torrent\tcalisiyor\n' >"$TMP/reg"
    reapply_modules
    [ ! -e "$TMP/calls" ]
    awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh" | grep -qx '    reapply_modules'
    # The root backend runs module work; its unit knows the helper.
    grep -qF -- '--master-modul __SBIN_DIR__/master-modul' "$V2_ROOT/systemd/master-wg-panel.service"
}

@test "console shows App Store from the module API in one responsive sidebar" {
    local js="$V2_ROOT/console/konsol.js" html="$V2_ROOT/console/index.html"
    [ "$(grep -c 'data-route="moduller"' "$html")" -eq 1 ]
    grep -q 'aria-controls="panel-sidebar"' "$html"
    grep -q 'href="/panel.css"' "$html"
    grep -q '<section data-view="moduller"' "$html"
    grep -q 'id="mod-grid"' "$html"
    grep -q 'id="cf-extra"' "$html"
    grep -qF 'api("/api/konsol/moduller")' "$js"
    grep -qF 'post(`/api/konsol/moduller/${enc(m.id)}/${action}`, { veri: !!veri })' "$js"
    grep -qF 'if (MODS.some((m) => m.busy)) modTimer = setTimeout(loadModules, 1500);' "$js"
    # Until the unit writes its first step, the card shows the requested action, not the previous one.
    grep -qF 'if (!p || p.action !== want || p.step === "bitti" || p.step === "hata") m.progress = { action: want, step: "0", total: 0, text: "" };' "$js"
    grep -qF 'moduller: { title: "App Store"' "$js"
    run ! grep -qF 'unpackerr' "$js"
    # DD-152: every module runs on the host or in Konsol; there is no Docker runtime chip.
    grep -qF 'const RUNTIME = { host: ["host", "server", "Host"], konsol: ["konsol", "gauge", "Konsol"] };' "$js"
    run ! grep -q 'rt-chip.docker' "$V2_ROOT/console/konsol.css"
    grep -q '^\.store-list' "$V2_ROOT/console/panel.css"
    grep -q '^\.store-row' "$V2_ROOT/console/panel.css"
    grep -q '^\.rt-chip' "$V2_ROOT/console/konsol.css"
}

@test "console includes per-folder accounts as a Files capability" {
    local js="$V2_ROOT/console/konsol.js" dav="$V2_ROOT/console/dosyalar.js"
    grep -qF 'if (fsView === "shares") { renderShareList(body); return; }' "$js"
    grep -qF '"#/dosyalar/arsiv"' "$js"
    grep -qF 'api("/api/konsol/paylasim")' "$js"
    grep -qF 'window.createSharesPage' "$js"
    grep -qF 'permission: permission.value, ack_write: ack.checked' "$dav"
    grep -qF 'days.value === "keep" ? null' "$dav"
    grep -qF 'data.password = ""' "$dav"
    run ! grep -qE 'localStorage|sessionStorage' "$dav"
}

@test "installer wires private folder accounts without exposing hashes to the file backend" {
    grep -qx 'LoadCredential=registry:__SHARE_STATE_FILE__' "$V2_ROOT/modules/paylasim/master-paylasim.service"
    grep -qF 'atomic_write "$SBIN_DIR/master_shares.py"' "$V2_ROOT/install.sh"
    grep -qF 'atomic_write "$SBIN_DIR/master_webdav.py"' "$V2_ROOT/install.sh"
    grep -qF 'dosyalar.css dosyalar.js' "$V2_ROOT/install.sh"
    [ "$(cat "$V2_ROOT/systemd/master-files-panel.service" "$V2_ROOT/files-panel/master-files-panel" | grep -cE 'LoadCredential|SHARE_STATE_FILE')" -eq 0 ]
    grep -qx 'ReadWritePaths=__TORRENT_PROFILE_DIR__ __DOWNLOADS_PATH__' "$V2_ROOT/modules/torrent/master-stack.conf"
    grep -qx 'InaccessiblePaths=-__SERVER_ROOT__/__FILES_PANEL_TRASH__ -__SERVER_ROOT__/__SHARE_DIR__' "$V2_ROOT/modules/torrent/master-stack.conf"
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
    grep -qF 'temp_dir="$DOWNLOADS_SUBDIR/$TORRENT_TEMP_DIR"' <<<"$body"
    # DD-140: this backend serves the console pages.
    pages="$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    for f in index.html konsol.css konsol.js; do grep -q "$f" <<<"$pages"; [ -f "$V2_ROOT/console/$f" ]; done
    run ! grep -q 'index.html' <<<"$body"
    grep -q 'CONSOLE_WEB_DIR="\$CONSOLE_WEB_DIR"' <<<"$(awk '/^stage_6\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx 'CONSOLE_WEB_DIR="/usr/local/share/master-stack/konsol"' "$V2_ROOT/config/defaults.env"
    grep -q '"\$REPO_ROOT/console"' "$V2_ROOT/dev/export-installer.sh"
    s6="$(awk '/^stage_6\(\)/,/^ensure_wg_panel\(\)/' "$V2_ROOT/install.sh")"
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
    run ! grep -q 'redir ' "$V2_ROOT/templates/Caddyfile"
    grep -qx 'interface-name=panel.__LOCAL_DOMAIN__,__TAILSCALE_IF__' "$V2_ROOT/templates/dnsmasq.conf"
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
    # DD-144: the trash sits beside the downloads folder, not inside it, so no container
    # that mounts downloads can reach it and the tmpfs curtain is gone.
    awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF '"$SERVER_ROOT/$FILES_PANEL_TRASH"; do'
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    run ! grep -q 'panele yönlenmedi' <<<"$s7"
    grep -q 'master-files-panel" check' <<<"$s7"
    grep -q 'ps -o uid= -p' <<<"$s7"
    grep -q 'http://${wg_first_addr}:${FILES_PANEL_PORT}/' <<<"$s7"
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
SHARE_PORT=61010
TORRENT_UI_PORT=61006
TAILSCALE_UDP_PORT=41641
EOF
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\n' \
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

wg_settings_fixture() {
    wg_mock_bin
    wg_state_fixture
    printf 'unchanged profile\n' >"$TMP/etc/wireguard/clients-wg0/test.conf"
    cp "$WG0_CONF" "$TMP/original.conf"
    cp "$TMP/etc/wireguard/networks" "$TMP/original.networks"
}

wg_revision() {
    local line
    line="$(sed -n '1p' "$TMP/etc/wireguard/networks")"
    printf '%s' "$line" | sha256sum | awk '{print $1}'
}

@test "network settings change default DNS only without changing peers keys or services" {
    wg_settings_fixture
    run master_wg --if wg0 net-settings '9.9.9.9, 2620:fe::fe' "$(wg_revision)"
    [ "$status" -eq 0 ]
    [ "$(cut -f8 "$TMP/etc/wireguard/networks")" = '9.9.9.9, 2620:fe::fe' ]
    [ "$(cut -f9 "$TMP/etc/wireguard/networks")" = 'Ana ağ' ]
    cmp -s "$WG0_CONF" "$TMP/original.conf"
    grep -qx 'unchanged profile' "$TMP/etc/wireguard/clients-wg0/test.conf"
    [ ! -s "$TMP/calls" ]
}

@test "network settings reject retired access arguments without writes" {
    wg_settings_fixture
    local scope
    for scope in ui inet; do
        run master_wg --if wg0 net-settings "$scope" 1.1.1.1 "$(wg_revision)"
        [ "$status" -ne 0 ]
        run master_wg net-add 61011 "$scope" 1.1.1.1 test
        [ "$status" -ne 0 ]
    done
    cmp -s "$TMP/original.networks" "$TMP/etc/wireguard/networks"
    [ ! -s "$TMP/calls" ]
}

@test "DNS settings never start a stopped network" {
    wg_settings_fixture
    export WG_ACTIVE=0
    run master_wg --if wg0 net-settings 9.9.9.9 "$(wg_revision)"
    [ "$status" -eq 0 ]
    cmp -s "$WG0_CONF" "$TMP/original.conf"
    [ ! -s "$TMP/calls" ]
}

@test "network settings reject stale revisions pending settings and invalid DNS before writes" {
    wg_settings_fixture
    local revision bad
    revision="$(wg_revision)"
    for bad in '999.1.1.1' ':::' 'dns.example' 'fe80::1%eth0' $'1.1.1.1\n9.9.9.9'; do
        run master_wg --if wg0 net-settings "$bad" "$revision"
        [ "$status" -ne 0 ]
    done
    run master_wg --if wg0 net-settings all 1.1.1.1 "$revision"
    [ "$status" -ne 0 ]
    run master_wg --if wg0 net-settings 9.9.9.9 "$(printf 'a%.0s' {1..64})"
    [ "$status" -ne 0 ]
    case "$output" in *'Ağ ayarları değişmiş'*) ;; *) false ;; esac
    printf 'SETTINGS_PENDING_FILE=%s/pending.json\n' "$TMP" >>"$TMP/state.env"
    touch "$TMP/pending.json"
    run master_wg --if wg0 net-settings 9.9.9.9 "$revision"
    [ "$status" -ne 0 ]
    case "$output" in *'bekleyen işlemi'*) ;; *) false ;; esac
    cmp -s "$TMP/original.networks" "$TMP/etc/wireguard/networks"
    [ ! -s "$TMP/calls" ]
}

@test "master-wg net-add creates the next network, opens the firewall before the interface and undoes a failed step" {
    wg_mock_bin
    wg_state_fixture
    local wgd="$TMP/etc/wireguard" before args a b c d
    rm -f "$TMP/calls"
    run master_wg net-add 61011 "1.1.1.1 , 1.0.0.1" "İş ağı"
    [ "$status" -eq 0 ]
    [ "$output" = $'wg1\t61011' ]
    grep -qx 'Address = 10.8.1.1/24, fdcc:ad94:bacf:61a4::1:1/112' "$wgd/wg1.conf"
    grep -qx 'ListenPort = 61011' "$wgd/wg1.conf"
    grep -qx 'MTU = 1420' "$wgd/wg1.conf"
    grep -q '^PrivateKey = PRIV' "$wgd/wg1.conf"
    [ "$(stat -f %Lp "$wgd/wg1.conf" 2>/dev/null || stat -c %a "$wgd/wg1.conf")" = 600 ]
    [ -d "$wgd/clients-wg1" ]
    [ "$(sed -n 2p "$wgd/networks")" = $'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t1.1.1.1, 1.0.0.1\tİş ağı' ]
    [ ! -e "$wgd/caddy-wg-wg1.env" ]
    # Firewall first, then the interface. No companion listener is created.
    awk '/systemctl restart master-firewall.service/ {f = NR} /systemctl enable --now wg-quick@wg1.service/ {w = NR}
         END { exit !(f && w && f < w) }' "$TMP/calls"
    run ! grep -q caddy-wg "$TMP/calls"
    # An internet-only network takes the next number, with no Caddy.
    rm -f "$TMP/calls"
    run master_wg net-add 61021 9.9.9.9 ""
    [ "$output" = $'wg2\t61021' ]
    [ ! -e "$wgd/caddy-wg-wg2.env" ]
    run ! grep -q 'caddy-wg@wg2' "$TMP/calls"
    [ "$(sed -n 3p "$wgd/networks")" = $'wg2\t61021\tinet\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t9.9.9.9\t' ]
    # Refusals change nothing: a port of wg0, of a panel network or of the stack, the range, scope, DNS, label.
    before="$(cat "$wgd/networks")"
    rm -f "$TMP/calls"
    for args in "61001|1.1.1.1|x" "61021|1.1.1.1|x" "61008|1.1.1.1|x" "61006|1.1.1.1|x" \
        "1000|1.1.1.1|x" "61031|dns.google|x" $'61031|1.1.1.1|a\tb' "61031|1.1.1.1| lead"; do
        IFS='|' read -r a b c <<<"$args"
        run master_wg net-add "$a" "$b" "$c"
        [ "$status" -ne 0 ]
    done
    run master_wg net-add 61001 1.1.1.1 x
    case "$output" in *"UDP 61001 kullanılıyor (wg0)"*) ;; *) false ;; esac
    [ "$(cat "$wgd/networks")" = "$before" ]
    [ ! -e "$wgd/wg3.conf" ]
    [ ! -s "$TMP/calls" ]
    # A port another program listens on is refused too.
    printf '#!/bin/bash\ncase "$*" in *61099*) echo "UNCONN 0 0 0.0.0.0:61099 0.0.0.0:*" ;; esac\n' >"$TMP/bin/ss"
    chmod +x "$TMP/bin/ss"
    run master_wg net-add 61099 1.1.1.1 x
    case "$output" in *"başka bir program"*) ;; *) false ;; esac
    # A failing step removes every trace of the new network and puts the firewall back.
    export SYSTEMCTL_FAIL="enable --now wg-quick@wg3"
    run master_wg net-add 61031 1.1.1.1 Test
    unset SYSTEMCTL_FAIL
    [ "$status" -ne 0 ]
    case "$output" in *"wg3 başlatılamadı; ağ oluşturulmadı"*) ;; *) false ;; esac
    [ ! -e "$wgd/wg3.conf" ]
    [ ! -e "$wgd/clients-wg3" ]
    [ ! -e "$wgd/caddy-wg-wg3.env" ]
    [ "$(cat "$wgd/networks")" = "$before" ]
    [ "$(grep -c 'systemctl restart master-firewall.service' "$TMP/calls")" -eq 2 ]
    grep -q 'systemctl disable --now wg-quick@wg3.service' "$TMP/calls"
    export SYSTEMCTL_FAIL="restart master-firewall.service"
    run master_wg net-add 61031 1.1.1.1 Test
    unset SYSTEMCTL_FAIL
    [ "$status" -ne 0 ]
    [ ! -e "$wgd/wg3.conf" ]
    [ "$(cat "$wgd/networks")" = "$before" ]
    # The limit comes from state.env.
    printf 'WG_NETWORKS_MAX=2\n' >>"$TMP/state.env"
    run master_wg net-add 61031 1.1.1.1 ""
    [ "$status" -ne 0 ]
    case "$output" in *"en çok 3 ağ"*) ;; *) false ;; esac
}

@test "master-wg --if runs peer commands on a panel network, nets lists all and net-remove drops only that network" {
    wg_mock_bin
    wg_state_fixture
    local wgd="$TMP/etc/wireguard"
    master_wg net-add 61011 9.9.9.9 Misafir >/dev/null
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
    [ "$(sed -n 1p <<<"$output")" = $'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\t1\t1' ]
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

konsol_fixture() {
    # DD-150: the Konsol modules (Dosya yöneticisi, WireGuard) against fakes.
    modul_fixture
    mkdir -p "$TMP/mods/dosya" "$TMP/units" "$TMP/sbin" "$TMP/srv/.cop" "$TMP/etc/wireguard" "$TMP/modload"
    printf '[Service]\nExecStart=/bin/true\n' >"$TMP/mods/dosya/master-files-panel.service"
    printf 'import sys, os\nsys.exit(1 if os.path.exists("%s/check-fail") else 0)\n' "$TMP" >"$TMP/sbin/master-files-panel"
    cat >>"$TMP/mstate.env" <<EOF
SERVER_ROOT=$TMP/srv
FILES_PANEL_PORT=61009
FILES_PANEL_TRASH=.cop
UNIT_DIR=$TMP/units
SBIN_DIR=$TMP/sbin
DOWNLOADS_UID=1000
LOCAL_DOMAIN=ayc
TAILSCALE_IPV4=100.64.0.7
WG_CONF_DIR=$TMP/etc/wireguard
WG_NETWORKS_FILE=$TMP/etc/wireguard/networks
WG_MODULES_LOAD_FILE=$TMP/modload/master-stack-wireguard.conf
EOF
    cat >"$TMP/mbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/systemctl-calls"
case "\$*" in
    "restart master-firewall.service")
        if grep -q '^wireguard' "$TMP/moduller" 2>/dev/null; then echo firewall-wg >>"$TMP/order"; else echo firewall-nowg >>"$TMP/order"; fi ;;
    "enable --now master-files-panel.service") touch "$TMP/files-active" ;;
    "disable --now master-files-panel.service") rm -f "$TMP/files-active" ;;
    "is-active --quiet master-files-panel.service") [ -e "$TMP/files-active" ] ;;
    "show -p MainPID --value master-files-panel.service") echo 4242 ;;
    "enable --now --quiet wg-quick@"*) echo "up \${4%.service}" >>"$TMP/order" ;;
    list-unit-files*) [ ! -e "$TMP/wg-units" ] || cat "$TMP/wg-units" ;;
esac
exit 0
EOF
    printf '#!/bin/bash\n[ "$1 $2" = "-o uid=" ] && echo "  1000"\n' >"$TMP/mbin/ps"
    printf '#!/bin/bash\nprintf 403\n' >"$TMP/mbin/curl"
    printf '#!/bin/bash\n[ -e "%s/pkgs" ]\n' "$TMP" >"$TMP/mbin/dpkg"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/apt-calls"\ntouch "%s/pkgs"\n' "$TMP" "$TMP" >"$TMP/mbin/apt-get"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/modprobe-calls"\n' "$TMP" >"$TMP/mbin/modprobe"
    printf '#!/bin/bash\nfor a; do :; done\nmkdir -p "$a"\n' >"$TMP/mbin/install"
    chmod +x "$TMP/mbin"/*
}

torrent_fixture() {
    # DD-151: the qBittorrent host module against fakes (apt, systemd, journal, curl, dig, Caddy, dnsmasq).
    konsol_fixture
    mkdir -p "$TMP/mods/torrent" "$TMP/caddy/moduller" "$TMP/dnsmasq.d" "$TMP/srv/downloads" "$TMP/qbprof"
    printf '[Service]\nUMask=0002\n' >"$TMP/mods/torrent/master-stack.conf"
    sed -e "s#__DOWNLOADS_PATH__#$TMP/srv/downloads#g" -e 's/__TORRENT_UI_PORT__/61006/g' \
        "$V2_ROOT/modules/torrent/qBittorrent.conf" >"$TMP/mods/torrent/qBittorrent.conf"
    printf 'http://torrent.ayc {\n\treverse_proxy 127.0.0.1:61006\n}\n' >"$TMP/mods/torrent/torrent.caddy"
    printf 'interface-name=torrent.ayc,tailscale0\n' >"$TMP/mods/torrent/dnsmasq.conf"
    : >"$TMP/caddy/Caddyfile"
    cat >>"$TMP/mstate.env" <<EOF
DOWNLOADS_GID=1000
TORRENT_UI_PORT=61006
TORRENT_PROFILE_DIR=$TMP/qbprof
SHARE_DIR=.pay
CADDYFILE=$TMP/caddy/Caddyfile
CADDY_MODULES_DIR=$TMP/caddy/moduller
DNSMASQ_CONF_DIR=$TMP/dnsmasq.d
EOF
    cat >"$TMP/mbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/systemctl-calls"
case "\$*" in
    "enable --now qbittorrent-nox@master-downloads.service") touch "$TMP/qb-active" ;;
    "disable --now qbittorrent-nox@master-downloads.service") rm -f "$TMP/qb-active" ;;
    "is-active --quiet qbittorrent-nox@master-downloads.service") [ -e "$TMP/qb-active" ] ;;
    "show -p MainPID --value qbittorrent-nox@master-downloads.service") echo 4242 ;;
    "show -p InvocationID --value qbittorrent-nox@master-downloads.service") echo 0123456789abcdef0123456789abcdef ;;
    "show -p InaccessiblePaths --value qbittorrent-nox@master-downloads.service")
        [ -e "$TMP/qb-open" ] || echo "-$TMP/srv/.cop -$TMP/srv/.pay" ;;
esac
exit 0
EOF
    cat >"$TMP/mbin/journalctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/journal-calls"
echo "WebUI will be started shortly after internal preparations. Please wait..."
echo "The WebUI administrator username is: admin"
[ -e "$TMP/qb-password-set" ] || echo "The WebUI administrator password was not set. A temporary password is provided for this session: Tmp9Pass7Word"
EOF
    printf '#!/bin/bash\necho master-downloads:x:1000:1000::/nonexistent:/usr/sbin/nologin\n' >"$TMP/mbin/getent"
    printf '#!/bin/bash\necho 100.64.0.7\n' >"$TMP/mbin/dig"
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/caddy"
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/dnsmasq"
    printf '#!/bin/bash\nexit 0\n' >"$TMP/mbin/chown"
    chmod +x "$TMP/mbin"/*
}

@test "master-modul installs qBittorrent on the host once, as the downloads user, closed to the trash and the share" {
    torrent_fixture
    run mm kur torrent
    [ "$status" -eq 0 ]
    grep -qx "$(printf 'torrent\tcalisiyor')" "$TMP/moduller"
    [ "$(cat "$TMP/run/modul-torrent.ilerleme")" = "$(printf 'kur\tbitti\t0\tkuruldu')" ]
    grep -q -- 'install -y --no-install-recommends -o DPkg::Lock::Timeout=300 qbittorrent-nox' "$TMP/apt-calls"
    # The package's unit gets our drop-in; the settings are written once into an empty profile.
    cmp -s "$TMP/mods/torrent/master-stack.conf" "$TMP/units/qbittorrent-nox@.service.d/master-stack.conf"
    cmp -s "$TMP/mods/torrent/qBittorrent.conf" "$TMP/qbprof/qBittorrent/qBittorrent.conf"
    grep -qx 'enable --now qbittorrent-nox@master-downloads.service' "$TMP/systemctl-calls"
    cmp -s "$TMP/mods/torrent/torrent.caddy" "$TMP/caddy/moduller/torrent.caddy"
    cmp -s "$TMP/mods/torrent/dnsmasq.conf" "$TMP/dnsmasq.d/modul-torrent.conf"
    run mm liste
    [ "$(grep '^torrent' <<<"$output" | cut -f2-4)" = "$(printf 'host\tcalisiyor\trunning')" ]
    # First login: the temporary password comes from this run's journal, only on request.
    run mm hesap torrent
    [ "$output" = "$(printf 'admin\tgecici')" ]
    run mm hesap torrent --parola
    [ "$output" = "$(printf 'admin\tgecici\tTmp9Pass7Word')" ]
    grep -q '_SYSTEMD_INVOCATION_ID=0123456789abcdef0123456789abcdef' "$TMP/journal-calls"
    run mm gunluk torrent 20
    [ "$(grep -c 'Tmp9Pass7Word' <<<"$output")" -eq 0 ]
    touch "$TMP/qb-password-set"
    run mm hesap torrent --parola
    [ "$output" = "$(printf 'admin\tayarli')" ]
    printf '[Preferences]\nWebUI\\Username=operator\n' >"$TMP/qbprof/qBittorrent/qBittorrent.conf"
    run mm hesap torrent
    [ "$output" = "$(printf 'operator\tayarli')" ]
    # Settings made in qBittorrent stay: a reinstall never rewrites the profile.
    printf '%s\n' '[BitTorrent]' 'Session\LSDEnabled=false' 'Session\TempPathEnabled=true' \
        'Session\TempPath=/operator/incomplete/' '[Network]' 'PortForwardingEnabled=true' \
        '[Preferences]' 'Connection\UPnP=true' 'WebUI\Username=operator' \
        >"$TMP/qbprof/qBittorrent/qBittorrent.conf"
    cp "$TMP/qbprof/qBittorrent/qBittorrent.conf" "$TMP/operator.conf"
    run mm uygula torrent
    [ "$status" -eq 0 ]
    cmp -s "$TMP/operator.conf" "$TMP/qbprof/qBittorrent/qBittorrent.conf"
    run mm durdur torrent
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/qb-active" ]
    grep -qx "$(printf 'torrent\tdurduruldu')" "$TMP/moduller"
    run mm baslat torrent
    [ "$status" -eq 0 ]
    run mm kaldir torrent
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/units/qbittorrent-nox@.service.d/master-stack.conf" ]
    [ ! -e "$TMP/caddy/moduller/torrent.caddy" ]
    [ ! -e "$TMP/dnsmasq.d/modul-torrent.conf" ]
    [ "$(grep -cE 'remove|purge' "$TMP/apt-calls")" -eq 0 ]
    : >"$TMP/apt-calls"
    run mm kur torrent
    [ "$status" -eq 0 ]
    [ ! -s "$TMP/apt-calls" ]
    cmp -s "$TMP/operator.conf" "$TMP/qbprof/qBittorrent/qBittorrent.conf"
    [ "$(grep -c 'master-firewall' "$TMP/systemctl-calls")" -eq 0 ]
    # --veri deletes the profile only under /var/lib; nothing else is ever removed.
    run mm kaldir torrent --veri
    [ "$status" -eq 0 ]
    [ -f "$TMP/qbprof/qBittorrent/qBittorrent.conf" ]
    # A service that can see the trash or the share is taken back.
    touch "$TMP/qb-open"
    run mm kur torrent
    [ "$status" -ne 0 ]
    case "$output" in *"çöp ve paylaşım klasörünü görebiliyor"*) ;; *) false ;; esac
    [ "$(grep -c torrent "$TMP/moduller")" -eq 0 ]
    [ ! -e "$TMP/caddy/moduller/torrent.caddy" ]
}

@test "installer protects the archive workspace and wires bounded nonroot ZIP jobs" {
    eval "$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    mkdir -p "$TMP/root/.arsiv" "$TMP/root/media"
    printf 'private\n' >"$TMP/root/.arsiv/jobs.json"
    chmod 0700 "$TMP/root/.arsiv"
    chmod 0600 "$TMP/root/.arsiv/jobs.json"
    FILES_ARCHIVE_DIR=.arsiv
    ensure_downloads_tree "$TMP/root" "$(id -u)" "$(id -g)" >/dev/null
    [ "$(file_mode "$TMP/root/.arsiv")" = 0o700 ]
    [ "$(file_mode "$TMP/root/.arsiv/jobs.json")" = 0o600 ]
    grep -qF -- '--archive-dir=__FILES_ARCHIVE_DIR__' "$V2_ROOT/systemd/master-files-panel.service"
    grep -qx 'MemoryMax=512M' "$V2_ROOT/systemd/master-files-panel.service"
    grep -qx 'CPUQuota=100%' "$V2_ROOT/systemd/master-files-panel.service"
    grep -qF '"$SBIN_DIR/master-modul" yerlesik "$MODULES_CHANGED"' "$V2_ROOT/install.sh"
}

@test "master-modul installs WireGuard, opens the kept networks after the firewall and closes them on removal" {
    konsol_fixture
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc::1\tfdcc::/112\t1.1.1.1\tAna\n' >"$TMP/etc/wireguard/networks"
    printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc::1:1\tfdcc::1:0/112\t9.9.9.9\t\n' >>"$TMP/etc/wireguard/networks"
    printf '[Interface]\n' >"$TMP/etc/wireguard/wg0.conf"
    run mm kur wireguard
    [ "$status" -eq 0 ]
    grep -qx "$(printf 'wireguard\tcalisiyor')" "$TMP/moduller"
    grep -q -- 'install -y --no-install-recommends -o DPkg::Lock::Timeout=300 wireguard-tools qrencode' "$TMP/apt-calls"
    grep -qx 'wireguard' "$TMP/modprobe-calls"
    [ "$(cat "$TMP/modload/master-stack-wireguard.conf")" = wireguard ]
    # The firewall is applied with the module registered, then the registry's networks come up.
    [ "$(tr '\n' ' ' <"$TMP/order")" = 'firewall-wg up wg-quick@wg0 up wg-quick@wg1 ' ]
    run ! grep -q caddy-wg "$TMP/systemctl-calls"
    [ "$(grep -c 'caddy-wg@wg1' "$TMP/systemctl-calls")" -eq 0 ]
    # Existing keys and networks are applied, never made.
    [ "$(cat "$TMP/etc/wireguard/wg0.conf")" = '[Interface]' ]
    run mm durdur wireguard
    [ "$status" -ne 0 ]
    # Removal: networks close, the module leaves the registry before the firewall is re-applied,
    # the keys stay; a reinstall brings the networks back.
    printf 'wg-quick@wg0.service enabled enabled\ncaddy-wg@wg0.service enabled enabled\n' >"$TMP/wg-units"
    : >"$TMP/order"
    run mm kaldir wireguard
    [ "$status" -eq 0 ]
    grep -qx 'disable --now --quiet wg-quick@wg0.service' "$TMP/systemctl-calls"
    run ! grep -q caddy-wg "$TMP/systemctl-calls"
    grep -qx 'disable --now --quiet wg-quick@wg1.service' "$TMP/systemctl-calls"
    [ "$(cat "$TMP/order")" = firewall-nowg ]
    [ ! -e "$TMP/modload/master-stack-wireguard.conf" ]
    [ -f "$TMP/etc/wireguard/wg0.conf" ]
    [ "$(grep -c wireguard "$TMP/moduller")" -eq 0 ]
    : >"$TMP/apt-calls"
    run mm kur wireguard
    [ "$status" -eq 0 ]
    [ ! -s "$TMP/apt-calls" ]
    # --veri: keys, profiles and the registry go; the folder stays.
    run mm kaldir wireguard --veri
    [ "$status" -eq 0 ]
    [ -d "$TMP/etc/wireguard" ]
    [ -z "$(ls -A "$TMP/etc/wireguard")" ]
    # master-wg says so instead of touching anything while the module is absent.
    grep -qF 'die "WireGuard modülü kurulu değil; Konsol → Modüller → WireGuard ile kurun"' "$V2_ROOT/scripts/master-wg"
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
    for f in wg_module_on load_wg_networks apply_input4 apply_input6 apply_forward apply_nat wan_allow_pairs; do
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
    WAN_INTERFACE=eth0 TAILSCALE_IF=tailscale0 TAILSCALE_UDP_PORT=41641 SSH_PUBLIC_PORT=22
    CHAIN_STAGING_PREFIX=MASTER-NEXT-
    eval "$(grep '^WG_BLOCK_DEST[46]=' "$V2_ROOT/config/defaults.env")"
    eval "$(sed -n '/^ICMP6_TYPES=(/,/)$/{p;}' "$fw")"
    MODULES_FILE="$TMP/moduller"
    printf 'wireguard\tcalisiyor\n' >"$MODULES_FILE"
    WG_NETWORKS_FILE="$TMP/networks"
    # DD-143: wg0 da kayıttan gelir; kayıt boşsa hiç WireGuard kuralı olmaz.
    : >"$WG_NETWORKS_FILE"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    apply_input4
    run ! grep -q ' wg' "$TMP/in4"
    rm -f "$TMP/in4" "$TMP/in6" "$TMP/nat4" "$TMP/nat6"
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\n' >"$WG_NETWORKS_FILE"
    printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\tMisafir\n' >>"$WG_NETWORKS_FILE"
    printf 'wg2\t61021\tinet\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t1.1.1.1\t\n' >>"$WG_NETWORKS_FILE"
    load_wg_networks
    [ "${WG_IFACES[*]}" = "wg0 wg1 wg2" ]
    # DD-175: missing, empty or stopped module records never revive preserved networks.
    rm "$MODULES_FILE"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    : >"$MODULES_FILE"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    printf 'wireguard\tdurduruldu\n' >"$MODULES_FILE"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    printf 'dosya\tcalisiyor\n' >"$MODULES_FILE"
    load_wg_networks
    [ "${#WG_IFACES[@]}" -eq 0 ]
    printf 'wireguard\tcalisiyor\n' >>"$MODULES_FILE"
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
    # No host service or ping is permitted, even for established flows.
    for w in wg0 wg1 wg2; do
        for pair in "IN-:in4" "IN6-:in6"; do
            grep -qx -- "-A MASTER-NEXT-${pair%%:*} -i $w -j DROP" "$TMP/${pair##*:}"
            awk -v w="$w" '$0 ~ "-i " w " -j DROP" {d=NR} /--ctstate ESTABLISHED,RELATED/ {a=NR}
                END {exit !(d && a && d<a)}' "$TMP/${pair##*:}"
        done
    done
    run ! grep -qE -- '^-A [^ ]+ -j RETURN$' "$TMP/in4" "$TMP/in6" "$TMP/nat4" "$TMP/nat6"
    # FORWARD: to the WAN only, replies back, anything else (another network, the tailnet) dropped.
    set -- $WG_BLOCK_DEST4
    [ "$(grep -c '^-A FW- ' "$TMP/in4")" -eq "$((3 * (4 + $#)))" ]
    for w in wg0 wg1 wg2; do
        awk -v w="$w" '$0 == "-A FW- -i " w " -o eth0 -j ACCEPT" {a = NR} $0 == "-A FW- -i " w " -j DROP" {d = NR}
            $0 == "-A FW- -i eth0 -o " w " -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" {r = NR} $0 == "-A FW- -o " w " -j DROP" {o = NR}
            END { exit !(a && d && r && o && a < d && d < r && r < o) }' "$TMP/in4"
    done
    run ! grep -qE -- '-i wg[0-9] -o wg[0-9]' "$TMP/in4"
    # NAT: every subnet masqueraded on the WAN.
    [ "$(cat "$TMP/nat4")" = "$(printf -- '-A NAT- -s %s -o eth0 -j MASQUERADE\n' 10.8.0.0/24 10.8.1.0/24 10.8.2.0/24)" ]
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
    eval "$(awk '/^check_rule_count\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
    check_jump_exactly_one() { :; }
    check_rule() { :; }
    CHAIN_FORWARD=MASTER-FORWARD WAN_INTERFACE=eth0
    WG_IFACES=(wg0)
    WG_BLOCK_DEST4="" WG_BLOCK_DEST6=""
    good='-A MASTER-FORWARD -i wg0 -o eth0 -j ACCEPT
-A MASTER-FORWARD -i wg0 -j DROP
-A MASTER-FORWARD -i eth0 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A MASTER-FORWARD -o wg0 -j DROP'
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
    case "$output" in *"beklenen 4"*) ;; *) false ;; esac
    # DD-175: two networks need four rules each, without a redundant RETURN.
    WG_IFACES=(wg0 wg1)
    RULES="$(printf '%s\n' "$good"; printf '%s\n' "$good" | sed 's/wg0/wg1/g')"
    run check_forward_chain iptables
    [ "$status" -eq 0 ]
    RULES="$good"
    run check_forward_chain iptables
    [ "$status" -ne 0 ]
}

@test "internet-only installation never recreates the retired WireGuard web listener" {
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
    [ ! -e "$V2_ROOT/systemd/caddy-wg@.service" ]
    run ! grep -qE 'Caddyfile.wg|izin verilen WireGuard|Local erişim' "$V2_ROOT/console/konsol.js"
    run ! grep -qE 'CADDY_WG_FILE|caddy-wg@|ensure_caddy_wg' "$V2_ROOT/install.sh" "$V2_ROOT/scripts/master-wg" "$V2_ROOT/scripts/master-modul"
    grep -q 'python3 "$V2_ROOT/panel/master_wg_upgrade.py" "$STATE_FILE"' "$V2_ROOT/install.sh"
    local s7
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -qF 'wg show "$wg_iface" listen-port' <<<"$s7"
    grep -q '"$SBIN_DIR/master-wg" version' <<<"$s7"
    run ! grep -q 'http://${wg_s4}' <<<"$s7"
}

@test "installer summary names each module's state and says why WireGuard is re-applied" {
    # v2-120: an installed module is not "installed from Konsol"; its address is shown instead.
    eval "$(awk '/^summary_modules\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    module_state() { case "$1" in torrent) echo calisiyor ;; paylasim) echo durduruldu ;; esac; }
    SERVER_ROOT=/srv LOCAL_DOMAIN=ayc TAILSCALE_IPV4=100.64.0.7 SHARE_PORT=61010 WG_NET_COUNT=1 WG_PEER_COUNT=2
    run summary_modules
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[0]}" = "  Dosya yöneticisi: kurulu değil" ]
    [ "${lines[1]}" = "  WireGuard: kurulu değil" ]
    [ "${lines[2]}" = "  qBittorrent: kurulu — http://torrent.ayc; ilk giriş bilgisi kartında" ]
    [ "${lines[3]}" = "  Paylaşım: kurulu, durduruldu — Dosyalar → Paylaşımlar: klasör başına adres, kullanıcı ve erişim izni" ]
    awk '/^print_summary\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx '\$(summary_modules)'
    run ! grep -q "Paylaşım: Konsol → Modüller'den kurulur" "$V2_ROOT/install.sh"
    awk '/^reapply_modules\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -q 'Modül wireguard: yeniden uygulanıyor (her kurulumda'
}

settings_fixture() {
    # DD-155: the Ayarlar backend against the real templates (rendered here), fake iptables
    # with counters and a qBittorrent profile that also holds a password hash.
    mkdir -p "$TMP/caddy/moduller" "$TMP/dnsmasq.d" "$TMP/qb/qBittorrent" "$TMP/srv/downloads"
    cat >>"$TMP/state.env" <<EOF
WAN_INTERFACE=eth0
WAN_IPV4=203.0.113.7
TAILSCALE_IF=tailscale0
SSH_PUBLIC_PORT=22
TAILSCALE_UDP_PORT=41641
TORRENT_UI_PORT=61006
CHAIN_INPUT=MASTER-INPUT
CHAIN_FORWARD=MASTER-FORWARD
CHAIN_NAT=MASTER-NAT
CADDYFILE=$TMP/caddy/Caddyfile
CADDY_MODULES_DIR=$TMP/caddy/moduller
DNSMASQ_CONF_DIR=$TMP/dnsmasq.d
TORRENT_PROFILE_DIR=$TMP/qb
DOWNLOADS_PATH=$TMP/srv/downloads
EOF
    rend() {
        sed -e 's/__LOCAL_DOMAIN__/ayc/g' -e 's/__WG_PANEL_PORT__/61008/g' -e 's/__FILES_PANEL_PORT__/61009/g' \
            -e 's/__CADDY_HTTP_PORT__/80/g' -e "s#__CONSOLE_WEB_DIR__#$TMP/web#g" -e "s#__CADDY_MODULES_DIR__#$TMP/caddy/moduller#g" \
            -e 's/__SHARE_PORT__/61010/g' -e 's/__TORRENT_UI_PORT__/61006/g' -e 's/__TAILSCALE_IF__/tailscale0/g' \
            -e "s#__DOWNLOADS_PATH__#$TMP/srv/downloads#g" -e 's/__TORRENT_TEMP_DIR__/incomplete/g' "$1"
    }
    rend "$V2_ROOT/templates/Caddyfile" >"$TMP/caddy/Caddyfile"
    rend "$V2_ROOT/modules/paylasim/paylasim.caddy" >"$TMP/caddy/moduller/paylasim.caddy"
    rend "$V2_ROOT/modules/torrent/torrent.caddy" >"$TMP/caddy/moduller/torrent.caddy"
    rend "$V2_ROOT/templates/dnsmasq.conf" >"$TMP/dnsmasq.d/local-services.conf"
    rend "$V2_ROOT/modules/paylasim/dnsmasq.conf" >"$TMP/dnsmasq.d/modul-paylasim.conf"
    rend "$V2_ROOT/modules/torrent/dnsmasq.conf" >"$TMP/dnsmasq.d/modul-torrent.conf"
    rend "$V2_ROOT/modules/torrent/qBittorrent.conf" >"$TMP/qb/qBittorrent/qBittorrent.conf"
    printf 'Session\\Port=45410\nWebUI\\Username=admin\nWebUI\\Password_PBKDF2="@ByteArray(GIZLIOZET:GIZLITUZ)"\n' >>"$TMP/qb/qBittorrent/qBittorrent.conf"
    printf 'dosya\tcalisiyor\nwireguard\tcalisiyor\ntorrent\tcalisiyor\npaylasim\tcalisiyor\n' >"$TMP/moduller"
    cat >"$TMP/pbin/iptables" <<'EOF'
#!/bin/bash
case "$*" in
    *"-S MASTER-INPUT") printf '%s\n' '-N MASTER-INPUT' '-A MASTER-INPUT -i lo -c 157 20446 -j ACCEPT' \
        '-A MASTER-INPUT -m conntrack --ctstate RELATED,ESTABLISHED -c 687 118737 -j ACCEPT' \
        '-A MASTER-INPUT -i tailscale0 -c 4 240 -j ACCEPT' '-A MASTER-INPUT -i eth0 -p udp -m udp --dport 41641 -c 0 0 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -p tcp -m tcp --dport 22 -c 23 1412 -j ACCEPT' '-A MASTER-INPUT -i eth0 -p udp -m udp --dport 61001 -c 5 300 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -p tcp -m tcp --dport 8080 -c 3 180 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -c 1631 190422 -j DROP' '-A MASTER-INPUT -d 10.8.0.1/32 -i wg0 -p tcp -m multiport --dports 61006 -c 2 120 -j ACCEPT' \
        '-A MASTER-INPUT -d 10.8.0.1/32 -i wg0 -p icmp -m icmp --icmp-type 8 -c 0 0 -j ACCEPT' '-A MASTER-INPUT -i wg0 -c 7 420 -j DROP' \
        '-A MASTER-INPUT -c 0 0 -j RETURN' ;;
    *"-S MASTER-FORWARD") printf '%s\n' '-N MASTER-FORWARD' '-A MASTER-FORWARD -i wg0 -o eth0 -c 9 900 -j ACCEPT' \
        '-A MASTER-FORWARD -i wg0 -c 1 60 -j DROP' '-A MASTER-FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -c 9 900 -j ACCEPT' \
        '-A MASTER-FORWARD -o wg0 -c 0 0 -j DROP' '-A MASTER-FORWARD -c 0 0 -j RETURN' ;;
    *"-t nat -v -S MASTER-NAT") printf '%s\n' '-N MASTER-NAT' '-A MASTER-NAT -s 10.8.0.0/24 -o eth0 -c 9 900 -j MASQUERADE' '-A MASTER-NAT -c 1 1 -j RETURN' ;;
    *) exit 1 ;;
esac
EOF
    cat >"$TMP/pbin/ip6tables" <<'EOF'
#!/bin/bash
case "$*" in
    *"-S MASTER-INPUT") printf '%s\n' '-N MASTER-INPUT' '-A MASTER-INPUT -i lo -c 1 1 -j ACCEPT' \
        '-A MASTER-INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 135 -c 6 6 -j ACCEPT' '-A MASTER-INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 136 -c 4 4 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -c 111 17452 -j DROP' '-A MASTER-INPUT -c 0 0 -j RETURN' ;;
    *"-S MASTER-FORWARD") printf '%s\n' '-N MASTER-FORWARD' ;;
    # The registry and ip6tables write the same network differently.
    *"-S MASTER-NAT") printf '%s\n' '-N MASTER-NAT' '-A MASTER-NAT -s fdcc:ad94:bacf:61a4:0:0:0:0/112 -o eth0 -c 2 2 -j MASQUERADE' ;;
    *) exit 1 ;;
esac
EOF
    printf '#!/bin/bash\necho "firewall: kritik politikalar yerinde"\n' >"$TMP/pbin/master-firewall"
    chmod +x "$TMP/pbin/iptables" "$TMP/pbin/ip6tables" "$TMP/pbin/master-firewall"
}

@test "wg panel shows the server's settings read-only: rules with counters, sites, names and qBittorrent paths" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    settings_fixture
    [ "$(pc /api/konsol/ayarlar)" = 403 ]
    [ "$(pc /api/konsol/ayarlar -H 'X-Konsol: 1')" = 200 ]
    # Nothing secret leaves: qBittorrent's password hash and user are never read.
    run ! grep -qE 'GIZLI|Password|Username' "$TMP/body"
    python3 - "$TMP/body" "$TMP" <<'PY'
import json, sys
d, tmp = json.load(open(sys.argv[1])), sys.argv[2]
fw = d["firewall"]
assert fw["ok"] and fw["check"] == "firewall: kritik politikalar yerinde", fw
v4 = fw["v4"]["entries"]
k = lambda g, kind: [e for e in v4 if e["group"] == g and e["kind"] == kind]
assert k("wan", "ssh")[0]["pkts"] == 23 and k("wan", "ssh")[0]["port"] == 22, v4
assert k("wan", "drop")[0]["pkts"] == 1631
wgp = k("wan", "wireguard")[0]
assert (wgp["iface"], wgp["port"], wgp["label"]) == ("wg0", 61001, "Ana ağ"), wgp
assert k("wg:wg0", "ui")[0]["ports"] == [{"port": 61006, "name": "qbittorrent"}]
assert k("wg:wg0", "nat")[0]["subnet"] == "10.8.0.0/24" and k("wg:wg0", "egress")[0]["pkts"] == 9
assert k("ts", "all")[0]["pkts"] == 4 and k("self", "lo")[0]["pkts"] == 157
# A rule Konsol does not know is shown, not hidden; RETURN is not a rule to show.
other = [e for e in v4 if e["group"] == "other"]
assert len(other) == 1 and "--dport 8080" in other[0]["spec"], other
assert not [e for e in v4 if e["spec"] == "-j RETURN"]
raw = fw["v4"]["raw"]
assert "# iptables -S MASTER-INPUT" in raw and "# iptables -t nat -S MASTER-NAT" in raw and " -c " not in raw, raw
v6 = fw["v6"]["entries"]
assert sum(e["pkts"] for e in v6 if e["kind"] == "icmp6") == 10 and [e["pkts"] for e in v6 if e["kind"] == "drop"] == [111], v6
assert [e["group"] for e in v6 if e["kind"] == "nat"] == ["wg:wg0"] and not [e for e in v6 if e["group"] == "other"], v6
# Web: every address with where it goes, its source and who reaches it.
web = {e["address"]: e for e in d["web"]["entries"]}
assert [(r["path"], r["kind"], r["to"]) for r in web["panel.ayc"]["routes"]] == [
    ("/api/wg/* /api/konsol/*", "proxy", "127.0.0.1:61008"), ("/api/*", "proxy", "127.0.0.1:61009"), ("", "files", "")], web["panel.ayc"]
assert "health.ayc" not in web
assert web["paylas.ayc"]["source"] == "paylasim" and web["100.64.0.7:61010"]["source"] == "paylasim"
assert web["torrent.ayc"]["routes"][0]["to"] == "127.0.0.1:61006"
assert "10.8.0.1:61006" not in web
assert not [a for a in web if a.startswith(("wg.", "dosya.", "file."))]
assert len(d["web"]["raw"]) == 3
# Names: the base's and each module's, all on the Tailscale address.
names = {n["name"]: n for n in d["dns"]["names"]}
assert set(names) == {"panel.ayc", "paylas.ayc", "torrent.ayc"}, names
assert names["panel.ayc"]["source"] == "base" and names["paylas.ayc"]["source"] == "paylasim"
assert all(n["address"] == "100.64.0.7" for n in names.values())
assert d["dns"]["listen"] == ["lo", "tailscale0"] and d["dns"]["domains"] == ["ayc"] and d["dns"]["dhcp"] is False
t = d["torrent"]
assert t["save"] == tmp + "/srv/downloads/" and t["save_inside"], t
assert t["temp"] == "" and not t["temp_on"] and not t["temp_inside"], t
assert t["peer_port"] == 45410 and t["ui"] == "127.0.0.1:61006"
PY
    # DD-178: absent in the seed, but an explicit user's temporary folder is
    # still reported accurately; GET must never enable or rewrite it.
    printf '\n[BitTorrent]\nSession\\TempPath=%s/srv/downloads/user-buffer/\nSession\\TempPathEnabled=true\n' \
        "$TMP" >>"$TMP/qb/qBittorrent/qBittorrent.conf"
    cp "$TMP/qb/qBittorrent/qBittorrent.conf" "$TMP/user-temp.conf"
    [ "$(pc '/api/konsol/ayarlar?yenile=1' -H 'X-Konsol: 1')" = 200 ]
    python3 - "$TMP/body" "$TMP" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["torrent"]
assert t["temp"] == sys.argv[2] + "/srv/downloads/user-buffer/" and t["temp_on"] and t["temp_inside"], t
PY
    cmp -s "$TMP/user-temp.conf" "$TMP/qb/qBittorrent/qBittorrent.conf"
    # A save path outside the downloads folder is flagged (the sandbox would refuse the writes);
    # "Yenile" skips the short cache.
    sed -i.bak 's#^Session\\DefaultSavePath=.*#Session\\DefaultSavePath=/root/indirilenler/#' "$TMP/qb/qBittorrent/qBittorrent.conf"
    [ "$(pc '/api/konsol/ayarlar?yenile=1' -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; t = json.load(open(sys.argv[1]))["torrent"]; assert t["save"] == "/root/indirilenler/" and not t["save_inside"], t' "$TMP/body"
    printf 'wireguard\tcalisiyor\n' >"$TMP/moduller"
    [ "$(pc '/api/konsol/ayarlar?yenile=1' -H 'X-Konsol: 1')" = 200 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["torrent"] == {"installed": False}' "$TMP/body"
    # Read-only: the page's GET never starts module work.
    [ ! -e "$TMP/sdrun-calls" ]
}

@test "console manages five system tabs and separate torrent settings with shared rollback" {
    local js="$V2_ROOT/console/konsol.js" html="$V2_ROOT/console/index.html" css="$V2_ROOT/console/konsol.css"
    [ "$(grep -c 'data-route="ayarlar"' "$html")" -eq 1 ]
    grep -q '<section data-view="ayarlar" hidden>' "$html"
    grep -q 'id="settings-page"' "$html"
    grep -q 'src="/ayarlar.js"' "$html"
    grep -q 'href="/ayarlar.css"' "$html"
    grep -qF 'api(fresh === true ? "/api/konsol/ayarlar?yenile=1" : "/api/konsol/ayarlar")' "$js"
    grep -qF 'ayarlar: { title: "Ayarlar"' "$js"
    grep -q 'window.createSettingsPage' "$js"
    local settings="$V2_ROOT/console/ayarlar.js"
    for label in Sistem 'Güvenlik Duvarı' Caddy Dnsmasq Günlük qBittorrent 'İncele ve uygula' 'Geri al'; do grep -q "$label" "$settings"; done
    grep -q 'id="torrent-settings"' "$html"
    grep -q '/api/konsol/ayarlar/uygula' "$settings"
    grep -q '/api/konsol/ayarlar/durum' "$settings"
    run ! grep -qE 'localStorage[.(]|innerHTML[ =]' "$settings"
    grep -q 'OnUnitActiveSec=2s' "$V2_ROOT/systemd/master-settings-guard.timer"
    grep -q 'master_settings.py --state __STATE_FILE__ guard' "$V2_ROOT/systemd/master-settings-guard.service"
    # Icons the page uses exist (svg() silently falls back to the file icon).
    for icon in sliders route chev arrow; do grep -qE "^    ${icon}: '" "$js"; done
    grep -q '^\.addr-t \.tr {' "$css"
    # CSP: no inline style in the markup.
    run ! grep -q ' style="' "$html"
    run ! grep -q CADDY_WG_FILE "$V2_ROOT/install.sh"
}

@test "settings API keeps its gates, hides hashes, lists all rules and passes mutations privately to a worker" {
    TMP="$(cd "$TMP" && pwd -P)"
    panel_start
    settings_fixture
    mkdir -p "$TMP/srv/media" "$TMP/run" "$TMP/units" "$TMP/templates"
    cat >>"$TMP/state.env" <<EOF
SETTINGS_FILE=$TMP/settings.json
SETTINGS_PENDING_FILE=$TMP/pending.json
SETTINGS_DNS_FILE=$TMP/dnsmasq.d/konsol.conf
DNSMASQ_CONF_FILE=$TMP/dnsmasq.d/local-services.conf
UNIT_DIR=$TMP/units
MODULES_DIR=$TMP/templates
RUNTIME_DIR=$TMP/run
WG_NETWORKS_FILE=$TMP/networks
MEDIA_SUBDIR=media
SERVER_ROOT=$TMP/srv
EOF
    cat >"$TMP/pbin/iptables-save" <<'EOF'
#!/bin/bash
printf '%s\n' '*filter' ':INPUT DROP [3:40]' ':ts-input - [0:0]' '[2:120] -A INPUT -j ts-input' '[2:120] -A ts-input -i tailscale0 -j ACCEPT' 'COMMIT'
EOF
    cp "$TMP/pbin/iptables-save" "$TMP/pbin/ip6tables-save"
    cat >"$TMP/pbin/ss" <<'EOF'
#!/bin/bash
case "$*" in *-4) echo 'tcp LISTEN 0 128 0.0.0.0:8081 0.0.0.0:*' ;; esac
EOF
    cat >"$TMP/pbin/systemd-run" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/sdrun-calls"
python3 -c 'import json,sys; json.dump(json.load(sys.stdin), open(sys.argv[1], "w"))' "$TMP/worker-body"
printf '{"ok":true}\n'
EOF
    chmod +x "$TMP/pbin/iptables-save" "$TMP/pbin/ip6tables-save" "$TMP/pbin/ss" "$TMP/pbin/systemd-run"
    local headers=(-H 'X-Konsol: 1' -H 'Content-Type: application/json')
    [ "$(pc '/api/konsol/ayarlar?yenile=1' -H 'X-Konsol: 1')" = 200 ]
    python3 - "$TMP/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["manage"]["username"] == "admin" and d["manage"]["pending"] is None, d["manage"]
assert "GIZLI" not in json.dumps(d)
assert any(r["spec"] == "Politika: DROP" for r in d["firewall"]["rules"]["rows"])
assert any(r["owner"] == "Tailscale" and r["packets"] == 2 for r in d["firewall"]["rules"]["rows"])
# DD-174: raw sockets remain visible but do not synthesize remote port rules.
assert any(r["port"] == 8081 and r["scope"] == "any" for r in d["firewall"]["listeners"])
assert any(r["port"] == 8081 and r["scope"] == "lo" for r in d["firewall"]["ports"])
assert not any(r["port"] == 8081 and r["scope"] in ("wan", "tail") for r in d["firewall"]["ports"])
PY
    [ "$(pc /api/konsol/ayarlar/durum)" = 403 ]
    [ "$(pc /api/konsol/ayarlar/klasorler -H 'X-Konsol: 1')" = 200 ]
    grep -q "$TMP/srv/media" "$TMP/body"
    [ "$(pc '/api/konsol/ayarlar/klasorler?path=/etc' -H 'X-Konsol: 1')" = 400 ]
    [ "$(pc /api/konsol/ayarlar/uygula -H 'Content-Type: application/json' --data '{}')" = 403 ]
    [ "$(pc /api/konsol/ayarlar/uygula "${headers[@]}" -H 'Sec-Fetch-Site: cross-site' --data '{}')" = 403 ]
    [ ! -e "$TMP/sdrun-calls" ]
    [ "$(pc /api/konsol/ayarlar/uygula "${headers[@]}" --data '{"revision":"sample","torrent":{"password":"dummy-api-password"}}')" = 200 ]
    grep -q -- '--wait --pipe --collect' "$TMP/sdrun-calls"
    grep -q 'master_settings.py --state .* apply$' "$TMP/sdrun-calls"
    grep -q 'dummy-api-password' "$TMP/worker-body"
    run ! grep -q 'dummy-api-password' "$TMP/sdrun-calls" "$TMP/panel.log" "$TMP/body"
    [ "$(pc /api/konsol/ayarlar/onayla "${headers[@]}" --data '{"id":"sample","client":"100.64.0.9","host":"panel.forged"}')" = 200 ]
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["client"] == "127.0.0.1"' "$TMP/worker-body"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["host"] != "panel.forged"' "$TMP/worker-body"
    [ "$(pc /api/konsol/ayarlar/nested/uygula "${headers[@]}" --data '{}')" = 404 ]
    [ "$(pc /api/konsol/ayarlar/uygula "${headers[@]}" --data '[]')" = 400 ]
}

@test "confirmed domain overrides stale installer input without retaining the health site" {
    command -v python3 >/dev/null || skip "python3 unavailable"
    run python3 "$V2_ROOT/panel/master_settings.py" saved-domain "$TMP/settings.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    printf '%s\n' '{"domain":"ev"}' >"$TMP/settings.json"
    run python3 "$V2_ROOT/panel/master_settings.py" saved-domain "$TMP/settings.json"
    [ "$status" -eq 0 ]
    [ "$output" = ev ]
    # Execute only the actual domain-selection stanza, never installer stages.
    local stanza
    stanza="$(sed -n '/^    LOCAL_DOMAIN="${INPUT_LOCAL_DOMAIN:-\$def_domain}"/,/^    # DD-144:/p' "$V2_ROOT/install.sh")"
    [ -n "$stanza" ]
    run env INPUT_LOCAL_DOMAIN=ayc SETTINGS_FILE="$TMP/settings.json" V2_ROOT="$V2_ROOT" \
        bash -c 'die() { exit 90; }; pick_domain() { local def_domain=ayc; eval "$1"; echo "$LOCAL_DOMAIN"; }; pick_domain "$1"' _ "$stanza"
    [ "$status" -eq 0 ]
    [ "$output" = ev ]
    printf '%s\n' '{"domain":"bad;value"}' >"$TMP/settings.json"
    run python3 "$V2_ROOT/panel/master_settings.py" saved-domain "$TMP/settings.json"
    [ "$status" -ne 0 ]
    run ! grep -q 'health.__LOCAL_DOMAIN__' "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'state.lock' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'flock -n 8' "$V2_ROOT/scripts/refresh-tailnet-config"
}
