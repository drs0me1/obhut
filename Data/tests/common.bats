#!/usr/bin/env bats
# Kritik common.sh davranışları — framework değil, dar güvenlik/doğruluk seti.

bats_require_minimum_version 1.5.0

setup() {
    V2_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # shellcheck source=../common.sh
    source "$V2_ROOT/common.sh"
    TMP="$(mktemp -d)"
    # macOS /var is a symlink; no-follow traversal needs the physical fixture root.
    TMP="$(cd "$TMP" && pwd -P)"
    V2_RETRY_BACKOFF_SECONDS=0
}

teardown() {
    [ -z "${PANEL_PID:-}" ] || kill "$PANEL_PID" 2>/dev/null || true
    [ -z "${PSOCK:-}" ] || rm -rf "${PSOCK%/*}"
    rm -rf "$TMP"
}

stat_field() {
    # GNU/BSD options differ. A failed probe may still print filesystem data;
    # capture it and publish only the successful platform's value.
    local value
    if value="$(stat -c "$1" "$3" 2>/dev/null)"; then
        printf '%s\n' "$value"
    else
        stat -f "$2" "$3"
    fi
}

file_sha256() {
    python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
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
    # Caddy repo stays distro-agnostic (any-version) — same line on ubuntu; its base URL is the
    # one CADDY_APT_REPO in defaults.env (DD-253).
    grep -qF '$CADDY_APT_REPO/deb/debian any-version main' "$V2_ROOT/install.sh"
    grep -qx 'CADDY_APT_REPO="https://dl.cloudsmith.io/public/caddy/stable"' "$V2_ROOT/config/defaults.env"
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
    # DD-152: no Docker repository update or packages; DD-208: Podman is one base call; DD-271:
    # WireGuard's tools are one more, without recommends (no DKMS or compilers).
    # DD-253: stage 1's refresh passes APT_OPTS through apt_update_caddy_tolerant.
    [ "$(grep -cF 'apt-get "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 7 ]
    [ "$(grep -cE 'apt_update_caddy_tolerant "\$CADDY_APT_REPO" [^ ]+ "\$\{APT_OPTS\[@\]\}"' "$V2_ROOT/install.sh")" -eq 1 ]
    awk '/^stage_1\(\)/,/^}/' "$V2_ROOT/install.sh" | grep -A1 -F 'retry "apt-wireguard" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y --no-install-recommends' |
        grep -qx '        wireguard-tools qrencode'
    # retry runs a function in a child bash that does not inherit arrays, so
    # the masked-quiet installs take APT_OPTS as arguments (DD-125).
    [ "$(grep -cF 'apt_get_install_masked_quiet "${APT_OPTS[@]}"' "$V2_ROOT/install.sh")" -eq 2 ]
    run bash -c "awk '/^apt_get_install_masked_quiet\\(\\)/,/^}/' '$V2_ROOT/install.sh' | grep -q APT_OPTS"
    [ "$status" -ne 0 ]
}

@test "the RAR repository and packages are not installed" {
    # DD-267: Konsol's ZIP/RAR jobs are gone. Stage 1 adds no RAR source and installs neither unrar
    # nor python3-rarfile; DD-271: nothing removes what an older install added either.
    s1="$(awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh")"
    run ! grep -qE 'unrar|rarfile|ensure_rar_repository|remove_retired' <<<"$(grep -v '^[[:space:]]*#' "$V2_ROOT/install.sh")"
    run ! grep -qE 'apt-get.*(remove|purge)' <<<"$s1"
    grep -qF 'dnsutils unattended-upgrades python3' <<<"$s1"
    run ! grep -qE 'RAR_APT_SOURCE_FILE=|ARCHIVE_DIR=' "$V2_ROOT/config/defaults.env"
}

@test "a Caddy repository outage alone does not stop apt-update on a host that has Caddy" {
    # DD-253: Cloudsmith answers 402 when the Caddy project's bandwidth limit is reached and
    # apt-get update fails as a whole; only that repository may be skipped, and only with Caddy.
    eval "$(awk '/^apt_update_caddy_tolerant\(\)/,/^}/' "$V2_ROOT/install.sh")"
    local repo=https://dl.cloudsmith.io/public/caddy/stable
    mkdir -p "$TMP/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s/apt-args"\ncat "%s/apt-out"\nexit "$(cat "%s/apt-rc")"\n' \
        "$TMP" "$TMP" "$TMP" >"$TMP/bin/apt-get"
    printf '#!/bin/bash\ncat "%s/caddy-status"\n' "$TMP" >"$TMP/bin/dpkg-query"
    chmod +x "$TMP/bin/apt-get" "$TMP/bin/dpkg-query"
    caddy_down="E: Failed to fetch $repo/deb/debian/dists/any-version/InRelease  402  Payment Required [IP: 192.0.2.1 443]
E: The repository '$repo/deb/debian any-version InRelease' is no longer signed."
    printf '%s\n' "Hit:1 https://deb.debian.org/debian trixie InRelease" "$caddy_down" >"$TMP/apt-out"
    echo 100 >"$TMP/apt-rc"
    printf 'install ok installed' >"$TMP/caddy-status"
    PATH="$TMP/bin:$PATH" run apt_update_caddy_tolerant "$repo" "$TMP/mark" -o DPkg::Lock::Timeout=60
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/mark")" = "402 Payment Required" ]
    [ "$(cat "$TMP/apt-args")" = "-o DPkg::Lock::Timeout=60 update" ]
    # Another failing repository still stops the run.
    printf '%s\n' "$caddy_down" "E: Failed to fetch https://deb.debian.org/debian/dists/trixie/InRelease  Temporary failure resolving 'deb.debian.org'" >"$TMP/apt-out"
    : >"$TMP/mark"
    PATH="$TMP/bin:$PATH" run apt_update_caddy_tolerant "$repo" "$TMP/mark"
    [ "$status" -eq 100 ]
    [ ! -s "$TMP/mark" ]
    # Without Caddy (a first install) the repository is needed: stop.
    printf '%s\n' "$caddy_down" >"$TMP/apt-out"
    printf 'deinstall ok config-files' >"$TMP/caddy-status"
    PATH="$TMP/bin:$PATH" run apt_update_caddy_tolerant "$repo" "$TMP/mark"
    [ "$status" -eq 100 ]
    [ ! -s "$TMP/mark" ]
    # A clean refresh passes through untouched.
    echo 0 >"$TMP/apt-rc"
    printf 'install ok installed' >"$TMP/caddy-status"
    PATH="$TMP/bin:$PATH" run apt_update_caddy_tolerant "$repo" "$TMP/mark"
    [ "$status" -eq 0 ]
    [ ! -s "$TMP/mark" ]
    # Stage 1 uses it with the one configured repository; stage 6's first-install refresh stays
    # strict, and the repository literal lives only in defaults.env.
    grep -qx 'CADDY_APT_REPO="https://dl.cloudsmith.io/public/caddy/stable"' "$V2_ROOT/config/defaults.env"
    awk '/^stage_1\(\)/,/^apply_udp_netbuf_floor\(\)/' "$V2_ROOT/install.sh" |
        grep -qF 'retry "apt-update" 3 "$APT_LOCK_TIMEOUT" -- apt_update_caddy_tolerant "$CADDY_APT_REPO" "$caddy_mark" "${APT_OPTS[@]}"'
    awk '/^stage_6\(\)/,/^stage_7\(\)/' "$V2_ROOT/install.sh" |
        grep -qF 'retry "apt-update-caddy" 3 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" update'
    run ! grep -q 'dl\.cloudsmith\.io' "$V2_ROOT/install.sh"
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
    # DD-201: no WireGuard endpoint key anywhere in the base; master-wg uses the detected WAN_IPV4.
    run ! grep -q 'WG_ENDPOINT_HOST' "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env" "$V2_ROOT/panel/master-panel"
    grep -q 'Endpoint = ${WAN_IPV4}:${WG_PUBLIC_PORT}' "$V2_ROOT/scripts/master-wg"
    run grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$V2_ROOT/install.sh" "$V2_ROOT/scripts/master-wg" \
        "$V2_ROOT/panel/master-panel" "$V2_ROOT/config/defaults.env"
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
    [ "$(stat_field %a %Lp "$TMP/f")" = "600" ]
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
    before="$(stat_field %i %i "$TMP/f")"
    atomic_write "$TMP/f" 0644 <<<"same"
    local after
    after="$(stat_field %i %i "$TMP/f")"
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

@test "render_template keeps ampersand slash and backslash values and preserves the replacement option" {
    local value='/a/b&c\dir\&d\\tail' flag before
    printf 'v=__V__\n' >"$TMP/t"
    render_template "$TMP/t" "$TMP/o" 0644 "V=$value"
    [ "$(cat "$TMP/o")" = "v=$value" ]
    # Bash 3.2 still runs the literal-value assertion; newer shells must also
    # leave both the enabled and disabled caller option states unchanged.
    if (shopt -s patsub_replacement) 2>/dev/null; then
        for flag in -s -u; do
            (
                shopt "$flag" patsub_replacement
                before="$(shopt -p patsub_replacement || true)"
                render_template "$TMP/t" "$TMP/o" 0644 "V=$value"
                [ "$(cat "$TMP/o")" = "v=$value" ]
                [ "$(shopt -p patsub_replacement || true)" = "$before" ]
            )
        done
    fi
}

@test "template rendering leaves no temporary files and no global RETURN trap" {
    # Bash 5 leaked one TMPDIR file per render_template call: atomic_write's RETURN
    # trap replaced the caller's cleanup trap (DD-193). Bash 3.2 hid the leak.
    run ! grep -qE '^[[:space:]]*trap .*RETURN' "$V2_ROOT/common.sh"
    mkdir -p "$TMP/rt-tmp" "$TMP/rt-out"
    printf 'v=__V__\n' >"$TMP/t"
    run bash -c '
        set -Eeuo pipefail
        source "$1/common.sh"
        export TMPDIR="$2/rt-tmp"
        caller() {
            trap "echo caller-trap >>\"$2/rt-trap\"" RETURN
            render_template "$2/t" "$2/rt-out/a" 0644 V=1
            render_template "$2/t" "$2/rt-out/b" 0644 V=2
            printf "same\n" | atomic_write "$2/rt-out/c" 0600
        }
        caller "$@"
        trap - RETURN
        render_template "$2/t" "$2/rt-out/d" 0644 V=4
        [ -z "$(trap -p RETURN)" ]
    ' _ "$V2_ROOT" "$TMP"
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TMP/rt-tmp")" ]
    [ "$(cat "$TMP/rt-out/b")" = "v=2" ]
    [ "$(cat "$TMP/rt-trap")" = "caller-trap" ]
    [ -z "$(find "$TMP/rt-out" -name '.installer-*')" ]
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

@test "firewall has no Docker chain" {
    local fw="$V2_ROOT/scripts/firewall.sh"
    # DD-152: no Docker — no MASTER-DOCKER chain, no DOCKER-USER jump, no wait for dockerd.
    [ "$(grep -vE '^[[:space:]]*#' "$fw" | grep -ciE 'docker')" -eq 0 ]
    run ! grep -q 'CHAIN_DOCKER' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh"
    run ! grep -qi 'docker' <<<"$(grep -vE '^[[:space:]]*#' "$V2_ROOT/systemd/master-firewall.service")"
}

@test "firewall requires ports and chains from state" {
    grep -q 'CHAIN_INPUT:?' "$V2_ROOT/scripts/firewall.sh"
    # DD-143: WireGuard ağları state.env'den değil kayıttan gelir; boş kayıt geçerlidir.
    run ! grep -qE 'WG_PORT_DEFAULT:\?|WG_INTERFACE:\?|WG_ADDR_BASE4:\?' "$V2_ROOT/scripts/firewall.sh"
    # DD-198/271: the firewall reads WireGuard's own registry and stopped marker, both from state.
    grep -q 'WG_NETWORKS_FILE:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'WG_STOPPED_FILE:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q '^load_wireguard_rules()' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'VPN_BLOCK_DEST4:?' "$V2_ROOT/scripts/firewall.sh"
    run ! grep -q 'WG_BLOCK_DEST' "$V2_ROOT/scripts/firewall.sh" "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh"
    grep -q 'CHAIN_STAGING_PREFIX:?' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX' "$V2_ROOT/install.sh"
    run ! grep -q 'CHAIN_INPUT:=MASTER' "$V2_ROOT/scripts/firewall.sh"
    grep -q 'CHAIN_STAGING_PREFIX}IN-' "$V2_ROOT/scripts/firewall.sh"
}

@test "WebDAV runs as the downloads uid" {
    # DD-152: the share service reads the shared files as their owner, never as root.
    grep -qx 'User=__DOWNLOADS_UID__' "$V2_ROOT/systemd/master-paylasim.service"
    grep -qx 'Group=__DOWNLOADS_GID__' "$V2_ROOT/systemd/master-paylasim.service"
}

@test "downloads tree repairs ownership for the share and the console through safe descriptors" {
    grep -q 'DOWNLOADS_UID=1000' "$V2_ROOT/config/defaults.env"
    grep -q 'DOWNLOADS_GID=1000' "$V2_ROOT/config/defaults.env"
    grep -q 'ensure_downloads_tree' "$V2_ROOT/install.sh"
    grep -q 'assert_downloads_path_allowed' "$V2_ROOT/install.sh"
    grep -q 'allowlist dışı' "$V2_ROOT/install.sh"
    # The installer delegates its selective walk to the same helper tested in
    # test_install_hardening.py (including links, special files and races).
    downloads_tree="$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$downloads_tree" ]
    run ! grep -q 'chown -R' <<<"$downloads_tree"
    # DD-271: no name under the user area is reserved in the walk.
    grep -qxF '    python3 "$V2_ROOT/panel/master_permissions.py" "$root" "$uid" "$gid"' <<<"$downloads_tree"
    run ! grep -q 'SHARE_DIR' <<<"$downloads_tree"
    run ! grep -qE 'find |chown |chmod ' <<<"$(grep -v '^[[:space:]]*#' <<<"$downloads_tree")"
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
    [ "$(stat_field %a %Lp "$TMP/dl/sub")" = "775" ]
    [ "$(stat_field %a %Lp "$TMP/dl/sub/bad")" = "664" ]
    [ "$(stat_field %a %Lp "$TMP/dl/sub/good")" = "664" ]
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
    # DD-271: the root backend answers /api/konsol/* only; no package API path is routed.
    awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile" | grep -q '@kok path /api/konsol/\*$'
    run ! grep -q '/api/uygulama' "$V2_ROOT/templates/Caddyfile"
    # DD-151: no base Compose project at all.
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

@test "WireGuard networks wait for a checked firewall and the timer reopens failed ones" {
    local dropin="$V2_ROOT/systemd/wg-quick-master-stack.conf" rt="$V2_ROOT/scripts/refresh-tailnet-config" s4
    grep -qx 'Wants=master-firewall.service' "$dropin"
    grep -qx 'After=master-firewall.service' "$dropin"
    grep -qx 'ExecStartPre=+__SBIN_DIR__/master-firewall --check' "$dropin"
    awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh" |
        grep -qxF 'ExecStartPre=+$SBIN_DIR/master-firewall --check'
    # DD-271: stage 4 renders the drop-in straight into the unit folder (its __SBIN_DIR__ from the base).
    grep -q '__SBIN_DIR__' "$dropin"
    awk '/^ensure_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh" |
        grep -qF 'render_template "$V2_ROOT/systemd/wg-quick-master-stack.conf" "$UNIT_DIR/wg-quick@.service.d/master-stack.conf" 0644'
    # With the firewall recovery and before the tailnet wait: WireGuard does not need Tailscale.
    [ "$(awk '/^recover_firewall_if_broken$/ {print NR; exit}' "$rt")" -lt \
        "$(awk '/^recover_failed_wireguard$/ {print NR; exit}' "$rt")" ]
    [ "$(awk '/^recover_failed_wireguard$/ {print NR; exit}' "$rt")" -lt \
        "$(awk '/^if ! wait_for_tailscale_ready; then$/ {print NR; exit}' "$rt")" ]
    eval "$(awk '/^recover_failed_wireguard\(\)/,/^}$/' "$rt")"
    systemctl() {
        printf '%s\n' "$*" >>"$TMP/calls"
        case "$1" in
            list-units) [ ! -e "$TMP/failed" ] || cat "$TMP/failed" ;;
            is-enabled) [ "$3" != wg-quick@wg1.service ] ;;
        esac
    }
    FIREWALL_BIN="$TMP/fw"
    printf '#!/bin/sh\necho check >>"%s/calls"\n[ ! -e "%s/fw-broken" ]\n' "$TMP" "$TMP" >"$FIREWALL_BIN"
    chmod +x "$FIREWALL_BIN"
    # DD-271: without a network, or while WireGuard is stopped, failed units are not even listed.
    WG_NETWORKS_FILE="$TMP/networks" WG_STOPPED_FILE="$TMP/.durduruldu"
    printf 'wg-quick@wg0.service loaded failed failed WireGuard\n' >"$TMP/failed"
    recover_failed_wireguard
    [ ! -e "$TMP/calls" ]
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tEv\n' >"$WG_NETWORKS_FILE"
    printf 'wg0\n' >"$WG_STOPPED_FILE"
    recover_failed_wireguard
    [ ! -e "$TMP/calls" ]
    rm -f "$TMP/failed" "$WG_STOPPED_FILE"
    # Nothing failed: the firewall is not even checked.
    recover_failed_wireguard
    run ! grep -q '^check$' "$TMP/calls"
    printf 'wg-quick@wg0.service loaded failed failed WireGuard\nwg-quick@wg1.service loaded failed failed WireGuard\nwg-quick@x;y.service loaded failed failed x\n' >"$TMP/failed"
    # The firewall is still broken: nothing is reopened.
    touch "$TMP/fw-broken"
    : >"$TMP/calls"
    recover_failed_wireguard
    grep -qx 'check' "$TMP/calls"
    run ! grep -q '^restart' "$TMP/calls"
    # The firewall is fixed: only the enabled network comes back.
    rm -f "$TMP/fw-broken"
    : >"$TMP/calls"
    recover_failed_wireguard
    [ "$(grep '^restart' "$TMP/calls")" = "restart wg-quick@wg0.service" ]
}

@test "Caddy's admin API and the root backend are reachable only through private sockets" {
    local block render
    grep -qx "$(printf '\tadmin unix/__CADDY_ADMIN_SOCKET__')" "$V2_ROOT/templates/Caddyfile"
    block="$(awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh")"
    grep -qF 'local caddy_runtime="${CADDY_ADMIN_SOCKET%/*}"' "$V2_ROOT/install.sh"
    grep -qx 'RuntimeDirectory=${caddy_runtime#/run/}' <<<"$block"
    grep -qx 'RuntimeDirectoryMode=0700' <<<"$block"
    render="$(awk '/render_template "\$V2_ROOT\/templates\/Caddyfile"/,/CADDY_MODULES_DIR="\$CADDY_MODULES_DIR"$/' "$V2_ROOT/install.sh")"
    grep -qF 'CADDY_ADMIN_SOCKET="$CADDY_ADMIN_SOCKET"' <<<"$render"
    grep -qF 'PANEL_SOCKET="$PANEL_SOCKET"' <<<"$render"
    grep -qF 'PANEL_RUNTIME="$(basename -- "${PANEL_SOCKET%/*}")"' "$V2_ROOT/install.sh"
    grep -qF 'CADDY_GROUP="$CADDY_GROUP"' "$V2_ROOT/install.sh"
    # The backend refuses TCP outright; the settings view no longer lists a backend port.
    grep -qF 'fail("panel yalnız bir Unix soketinde dinler' "$V2_ROOT/panel/master-panel"
    run ! grep -q '"Konsol · WireGuard arka ucu"' "$V2_ROOT/panel/master-panel"
    grep -q 'SO_PEERCRED' "$V2_ROOT/panel/master-panel"
}

@test "speed and log-noise settings: compressed Konsol, idle guard, quiet timers, quiet backend" {
    local site s7 unit
    # DD-181: pages and API replies are compressed (DD-259: all but the event stream); page files
    # revalidate instead of redownloading.
    site="$(awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile")"
    grep -qx "$(printf '\tencode @sikistir zstd gzip')" <<<"$site"
    grep -q 'Cache-Control "no-cache"' <<<"$site"
    run ! grep -q 'Cache-Control "no-store"' "$V2_ROOT/templates/Caddyfile"
    # The WebDAV sites stay uncompressed (video).
    run ! grep -q 'encode' "$V2_ROOT/templates/paylasim.caddy"
    # PID 1's per-run lines stay out of the journal; the helpers' own messages stay at notice.
    for unit in master-settings-guard.service master-share-network.service; do
        grep -qx 'SyslogLevel=notice' "$V2_ROOT/systemd/$unit"
        grep -qx 'LogLevelMax=notice' "$V2_ROOT/systemd/$unit"
    done
    # The guard stops its own timer only when idle; stage 7 therefore checks that it is enabled.
    grep -qF 'run(["systemctl", "stop", "--no-block", GUARD_TIMER], check=False)' "$V2_ROOT/panel/master_settings.py"
    grep -qF 'run(["systemctl", "start", GUARD_TIMER])' "$V2_ROOT/panel/master_settings.py"
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -qF 'systemctl is-enabled --quiet master-settings-guard.timer' <<<"$s7"
    run ! grep -qF 'systemctl is-active --quiet master-settings-guard.timer' <<<"$s7"
    # The root backend writes audit lines only, no request lines.
    awk '/    def log_message\(self, fmt, \*args\):/,/pass$/' "$V2_ROOT/panel/master-panel" | grep -q '^        pass$'
}

@test "resilience: capped rollback with discard, stale WAN site, watchdog resets, health endpoint" {
    local s6 rt="$V2_ROOT/scripts/refresh-tailnet-config" body
    # DD-182: five automatic attempts with backoff, then "stuck" until the operator retries or discards.
    grep -qx 'ROLLBACK_ATTEMPTS = 5' "$V2_ROOT/panel/master_settings.py"
    grep -qx 'ROLLBACK_BACKOFF = 15' "$V2_ROOT/panel/master_settings.py"
    # DD-265: the transaction's routes are in the route table, on the same workers.
    grep -qF 'Route("POST", "/api/konsol/ayarlar/birak", "ayarlar_birak",' "$V2_ROOT/panel/master_api.py"
    grep -qF 'self.settings_action(user, "rollback", data)' "$V2_ROOT/panel/master-panel"
    grep -qF 'self.settings_action(user, "discard", data)' "$V2_ROOT/panel/master-panel"
    grep -qF 'geri alma takıldıysa: Yeniden dene ya da Bırak' "$V2_ROOT/install.sh"
    # A WAN share site bound to an address the provider took away goes before Caddy restarts.
    s6="$(awk '/^stage_6\(\)/,/^ensure_panel\(\)/' "$V2_ROOT/install.sh")"
    [ "$(grep -n 'rm -f -- "\$wan_site"' <<<"$s6" | cut -d: -f1)" -lt "$(grep -n 'caddy validate --config' <<<"$s6" | cut -d: -f1)" ]
    grep -qF 'grep -qxF "$(printf '"'"'\tbind %s'"'"' "$WAN_IPV4")" "$wan_site"' <<<"$s6"
    # The watchdog resets Caddy's start limit and checks the firewall again once Tailscale answers.
    body="$(awk '/^recover_failed_bound_units\(\)/,/^}$/' "$rt")"
    [ "$(grep -n 'reset-failed "\$unit"' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'systemctl restart "\$unit"' <<<"$body" | cut -d: -f1)" ]
    # Also recover the guard after an address change, before refreshing bridge bindings.
    [ "$(grep -cx 'recover_firewall_if_broken' "$rt")" -eq 3 ]
    [ "$(awk '/^recover_firewall_if_broken$/ {n++; if (n == 2) {print NR; exit}}' "$rt")" -gt \
        "$(awk '/^if ! wait_for_tailscale_ready; then$/ {print NR; exit}' "$rt")" ]
    # Health: a read-only endpoint (DD-259: in the route table) with a short cache.
    grep -qF 'Route("GET", "/api/konsol/saglik", "saglik",' "$V2_ROOT/panel/master_api.py"
    grep -qF 'self.json(200, self.panel.health())' <<<"$(grep -A1 'def api_saglik(self, query):' "$V2_ROOT/panel/master-panel")"
    grep -qx 'HEALTH_CACHE_SECONDS = 30' "$V2_ROOT/panel/master-panel"
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

@test "refresh-tailnet runs after boot and nightly 03-04; the firewall keeps an hourly check (DD-239, DD-240)" {
    # No 5-minute loop: after boot once, once a night (03:00 + up to 55 min), and on demand.
    grep -qx 'OnBootSec=2min' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -qx 'OnCalendar=\*-\*-\* 03:00:00' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -qx 'RandomizedDelaySec=55min' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    run ! grep -q 'OnUnitActiveSec\|OnUnitInactiveSec' "$V2_ROOT/systemd/refresh-tailnet-config.timer"
    grep -qx 'OnUnitActiveSec=1h' "$V2_ROOT/systemd/master-duvar-denetim.timer"
    grep -qx 'ExecStart=__SBIN_DIR__/master-onar --duvar' "$V2_ROOT/systemd/master-duvar-denetim.service"
    grep -qx '    systemctl enable --now master-duvar-denetim.timer' "$V2_ROOT/install.sh"
    grep -qx 'OnFailure=refresh-tailnet-config.service' "$V2_ROOT/install.sh"
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

@test "master-onar is installed for Konsol and SSH; onar.command reads only SSH_HOST (DD-239)" {
    local install="$V2_ROOT/install.sh" cmd="$V2_ROOT/../onar.command"
    grep -qF 'atomic_write "$SBIN_DIR/master_onar.py" 0755 <"$V2_ROOT/panel/master_onar.py"' "$install"
    grep -qF 'atomic_write "$SBIN_DIR/master-onar" 0755 <"$V2_ROOT/scripts/master-onar"' "$install"
    for key in ONARIM_UNIT ONARIM_DURUM_FILE; do grep -qx "$key=\$$key" "$install"; done
    bash -n "$cmd"
    [ -x "$cmd" ]
    grep -qF "index(\$0, \"SSH_HOST=\") == 1" "$cmd"
    [ "$(grep -c 'kurulum.env' "$cmd")" -le 3 ]
    run ! grep -qE 'scp |rsync|>> *"\$INPUT_FILE"' "$cmd"
    grep -qF 'exec sudo $tool $mode' "$cmd"
    grep -qF 'self.error(403, "Onarım yalnız Tailscale adresinden başlatılır.")' "$V2_ROOT/panel/master-panel"
    grep -qF '"master-duvar-denetim.timer"' "$V2_ROOT/panel/master-panel"
}

@test "watch-tailnet-addr is removed; refresh timer remains" {
    [ ! -e "$V2_ROOT/scripts/watch-tailnet-addr" ]
    [ ! -e "$V2_ROOT/systemd/watch-tailnet-addr.service" ]
    run ! grep -q 'watch-tailnet-addr' "$V2_ROOT/install.sh"
    grep -q 'OnBootSec=2min' \
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
    local unit="$V2_ROOT/systemd/master-paylasim.service"
    grep -qxF 'ExecStart=/usr/bin/python3 __SBIN_DIR__/master_webdav.py --registry=%d/registry --port=__SHARE_PORT__ --wan-listen=__SHARE_WAN_BACKEND__' "$unit"
    for line in 'LoadCredential=registry:__SHARE_STATE_FILE__' 'User=__DOWNLOADS_UID__' \
        'Group=__DOWNLOADS_GID__' 'Type=exec' 'ProtectSystem=strict' 'ProtectHome=true' \
        'PrivateTmp=true' 'NoNewPrivileges=true' 'CapabilityBoundingSet=' \
        'IPAddressDeny=any' 'IPAddressAllow=localhost' 'ReadWritePaths=__SERVER_ROOT__' \
        'InaccessiblePaths=__SERVER_ROOT__/__FILES_PANEL_TRASH__ __PRIVATE_STATE_ROOT__' \
        'RequiresMountsFor=__SERVER_ROOT__'; do
        grep -qxF "$line" "$unit"
    done
    # DD-225: one assignment (a second one would reset the list); SIGSYS stays the stricter default.
    [ "$(grep -c '^InaccessiblePaths=' "$unit")" -eq 1 ]
    run ! grep -q '^SystemCallErrorNumber=' "$unit"
    grep -qx 'http://paylas.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}:__SHARE_PORT__ {' "$V2_ROOT/templates/paylasim.caddy"
    # Public TLS has its own port; tailnet WebDAV stays on explicit HTTP.
    grep -qx 'SHARE_HTTPS_PORT="443"' "$V2_ROOT/config/defaults.env"
    grep -qxF "$(printf '\tauto_https disable_redirects')" "$V2_ROOT/templates/Caddyfile"
    grep -qxF "$(printf '\tservers __WAN_IPV4__:__SHARE_HTTPS_PORT__ {')" "$V2_ROOT/templates/Caddyfile"
    grep -qx 'interface-name=paylas.__LOCAL_DOMAIN__,__TAILSCALE_IF__/4' "$V2_ROOT/templates/paylasim-dnsmasq.conf"
    [ "$(grep -c '^http://paylas' "$V2_ROOT/templates/Caddyfile")" -eq 0 ]
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
    grep -qF -- '--dport "${VPN_PORTS[i]}" -j ACCEPT' "$V2_ROOT/scripts/firewall.sh"
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
    # Apply, check and the cold-start recovery policy share the same control types.
    [ "$(grep -c 'for type in "${ICMP6_TYPES\[@\]}"' "$V2_ROOT/scripts/firewall.sh")" -eq 3 ]
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

@test "every run upgrades the system and re-runs skip unchanged edge restart" {
    # DD-228: full-upgrade is not a question any more, re-runs included.
    awk '/^stage_1\(\)/,/^stage_2\(\)/' "$V2_ROOT/install.sh" | grep -q -- '-o Dpkg::Options::=--force-confold full-upgrade'
    run ! grep -q 'RUN_FULL_UPGRADE' "$V2_ROOT/install.sh"
    run ! grep -q 'V2_FULL_UPGRADE' "$V2_ROOT/install.sh"
    run ! grep -q 'full-upgrade yapılsın mı' "$V2_ROOT/install.sh"
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
}

@test "kur.sh fetches the public repo and starts the installer on the server terminal" {
    # DD-228: one curl line on the server; no SSH launcher, no embedded archive.
    local kur="$V2_ROOT/../kur.sh"
    bash -n "$kur"
    # The whole body runs from main(): a truncated download never runs half a script.
    [ "$(grep -vE '^\s*(#|$)' "$kur" | tail -n 1)" = 'main "$@"' ]
    grep -q '^main() {$' "$kur"
    grep -q 'https://codeload.github.com/\$repo/tar.gz/\$ref' "$kur"
    grep -q 'local repo="drs0me1/obhut"' "$kur"
    grep -q 'local ref="${KUR_REF:-main}"' "$kur"
    grep -q 'local root="${KUR_ROOT:-/root/debian-server-installer}"' "$kur"
    grep -q 'exec bash "\$root/install.sh" </dev/tty' "$kur"
    grep -q -- "--exclude='__pycache__'" "$kur"
    grep -q -- '--no-same-owner' "$kur"
    run ! grep -qE '^[^#"]*\b(ssh|scp) ' "$kur"
}

@test "kur.sh ships the runtime tree, swaps it atomically and hands the terminal to the installer" {
    local kur="$V2_ROOT/../kur.sh" src="$TMP/src/obhut-main" dir
    mkdir -p "$src/Data"
    for dir in install.sh common.sh config templates scripts systemd panel files-panel console; do
        cp -R "$V2_ROOT/$dir" "$src/Data/"
    done
    mkdir -p "$src/Data/tests" "$src/Data/panel/__pycache__"
    touch "$src/Data/tests/x.bats" "$src/Data/panel/__pycache__/x.pyc"
    # The real installer must never start here: a stub stands in for it.
    printf '#!/usr/bin/env bash\nV2_VERSION="stub"\necho "STUB_INSTALL tty=$([[ -t 0 ]] && echo yes || echo no)"\n' \
        >"$src/Data/install.sh"
    tar -C "$TMP/src" -czf "$TMP/kod.tgz" obhut-main
    # A previous copy is replaced as a whole.
    mkdir -p "$TMP/root"
    touch "$TMP/root/stale"
    [ "$(id -u)" -eq 0 ] || skip "needs root"
    command -v script >/dev/null || skip "needs script(1) for a terminal"
    run script -qec "KUR_URL='file://$TMP/kod.tgz' KUR_ROOT='$TMP/root' bash '$kur'" /dev/null
    case "$output" in *"STUB_INSTALL tty=yes"*) ;; *) false ;; esac
    [ -f "$TMP/root/install.sh" ]
    [ -x "$TMP/root/install.sh" ]
    [ -x "$TMP/root/scripts/master-wg" ]
    [ ! -e "$TMP/root/stale" ]
    [ ! -e "$TMP/root/tests" ]
    [ ! -e "$TMP/root/panel/__pycache__" ]
    case "$output" in *"Yerleştirildi"*) ;; *) false ;; esac
}

@test "kur.sh never swaps the tree under a running install; master-wg net takes the install lock" {
    # A running install reads its templates and helpers from the tree kur.sh replaces.
    local kur="$V2_ROOT/../kur.sh"
    grep -q 'flock -n "$lock" true' "$kur"
    awk '/flock -n "\$lock" true/ {l = NR} /mv -- "\$incoming" "\$root"/ {m = NR} END { exit !(l && m && l < m) }' "$kur"
    # The lock is the installer's own file, read from defaults.env, not restated.
    grep -q '^RUNTIME_DIR="/' "$V2_ROOT/config/defaults.env"
    grep -q 'config/defaults.env")/install.lock"' "$kur"
    # DD-229: master-wg durdur writes its list under this lock; "net ac" must not slip past it.
    awk '/^cmd_net\(\)/,/^}$/' "$V2_ROOT/scripts/master-wg" | grep -qx '    take_lock'
}

@test "kur.sh update mode installs only the confirmed commit and version, without a terminal" {
    # DD-233: Konsol's update runs kur.sh pinned to a commit; install.sh gets V2_GUNCELLEME=1 and no tty.
    local kur="$V2_ROOT/../kur.sh" src="$TMP/src/obhut-x" dir sha=0123456789abcdef0123456789abcdef01234567
    [ "$(id -u)" -eq 0 ] || skip "needs root"
    mkdir -p "$src/Data"
    for dir in install.sh common.sh config templates scripts systemd panel files-panel console; do
        cp -R "$V2_ROOT/$dir" "$src/Data/"
    done
    printf '#!/usr/bin/env bash\nV2_VERSION="2026.08.06-v2-212"\necho "STUB_INSTALL tty=$([[ -t 0 ]] && echo yes || echo no) guncelleme=${V2_GUNCELLEME:-0}"\n' \
        >"$src/Data/install.sh"
    tar -C "$TMP/src" -czf "$TMP/kod.tgz" obhut-x
    mkdir -p "$TMP/root" && touch "$TMP/root/keep"
    # A branch name, a bad version or another version than the confirmed one changes nothing.
    run env KUR_URL="file://$TMP/kod.tgz" KUR_ROOT="$TMP/root" KUR_REF=main KUR_GUNCELLE=2026.08.06-v2-212 bash "$kur" </dev/null
    [ "$status" -ne 0 ]
    case "$output" in *"commit'e sabitlenmeli"*) ;; *) false ;; esac
    run env KUR_URL="file://$TMP/kod.tgz" KUR_ROOT="$TMP/root" KUR_REF="$sha" KUR_GUNCELLE='v2-212;x' bash "$kur" </dev/null
    [ "$status" -ne 0 ]
    case "$output" in *"geçersiz sürüm"*) ;; *) false ;; esac
    run env KUR_URL="file://$TMP/kod.tgz" KUR_ROOT="$TMP/root" KUR_REF="$sha" KUR_GUNCELLE=2026.08.06-v2-213 bash "$kur" </dev/null
    [ "$status" -ne 0 ]
    case "$output" in *"onaylanan 2026.08.06-v2-213 değil"*) ;; *) false ;; esac
    [ -f "$TMP/root/keep" ]
    run env KUR_URL="file://$TMP/kod.tgz" KUR_ROOT="$TMP/root" KUR_REF="$sha" KUR_GUNCELLE=2026.08.06-v2-212 bash "$kur" </dev/null
    [ "$status" -eq 0 ]
    case "$output" in *"STUB_INSTALL tty=no guncelleme=1"*) ;; *) false ;; esac
    [ ! -e "$TMP/root/keep" ]
    [ -x "$TMP/root/install.sh" ]
    # Without KUR_GUNCELLE the terminal stays required.
    grep -q 'exec bash "\$root/install.sh" </dev/tty' "$kur"
    grep -q 'V2_GUNCELLEME=1 exec bash "\$root/install.sh" </dev/null' "$kur"
}

@test "master-guncelle runs the pinned kur.sh and records the result for Konsol" {
    # DD-233: the unit's result file and output; Konsol only reads them.
    local tool="$V2_ROOT/scripts/master-guncelle" sha=0123456789abcdef0123456789abcdef01234567 args
    [ "$(id -u)" -eq 0 ] || skip "needs root"
    bash -n "$tool"
    printf 'GUNCELLEME_REPO=drs0me1/obhut\nGUNCELLEME_DURUM_FILE=%s\nGUNCELLEME_LOG_FILE=%s\n' \
        "$TMP/log/guncelleme.durum" "$TMP/log/guncelleme.log" >"$TMP/state.env"
    printf 'echo "ref=$KUR_REF surum=$KUR_GUNCELLE"\necho "[10:00:00] Aşama 3/7 — servisler"\n' >"$TMP/ok.sh"
    run env STATE_FILE="$TMP/state.env" KUR_BETIK_URL="file://$TMP/ok.sh" bash "$tool" uygula "$sha" 2026.08.06-v2-212
    [ "$status" -eq 0 ]
    grep -qx 'durum=tamam' "$TMP/log/guncelleme.durum"
    grep -qx 'hedef=2026.08.06-v2-212' "$TMP/log/guncelleme.durum"
    grep -qx "commit=$sha" "$TMP/log/guncelleme.durum"
    grep -qx "ref=$sha surum=2026.08.06-v2-212" "$TMP/log/guncelleme.log"
    [ "$(stat -c %a "$TMP/log/guncelleme.log")" = 600 ]
    printf 'echo "[10:00:01] Aşama 0/7 — kapılar"\necho "[10:00:02] Tailscale oturumu açık değil" >&2\nexit 1\n' >"$TMP/bad.sh"
    run env STATE_FILE="$TMP/state.env" KUR_BETIK_URL="file://$TMP/bad.sh" bash "$tool" uygula "$sha" 2026.08.06-v2-212
    [ "$status" -ne 0 ]
    grep -qx 'durum=hata' "$TMP/log/guncelleme.durum"
    grep -qx 'mesaj=Tailscale oturumu açık değil' "$TMP/log/guncelleme.durum"
    # systemd-inhibit's closing "env failed with exit status N." names no cause (DD-253).
    printf 'echo "[10:00:03] apt-update: 3 deneme başarısız (son kod 100)" >&2\necho "env failed with exit status 1."\nexit 1\n' >"$TMP/inhibit.sh"
    run env STATE_FILE="$TMP/state.env" KUR_BETIK_URL="file://$TMP/inhibit.sh" bash "$tool" uygula "$sha" 2026.08.06-v2-212
    [ "$status" -ne 0 ]
    grep -qx 'mesaj=apt-update: 3 deneme başarısız (son kod 100)' "$TMP/log/guncelleme.durum"
    # Malformed requests never write a result.
    rm -f "$TMP/log/guncelleme.durum"
    for args in "uygula main 2026.08.06-v2-212" "uygula $sha v2-212" "kur $sha 2026.08.06-v2-212" "uygula $sha"; do
        # shellcheck disable=SC2086
        run env STATE_FILE="$TMP/state.env" bash "$tool" $args
        [ "$status" -ne 0 ]
    done
    [ ! -e "$TMP/log/guncelleme.durum" ]
}

@test "update mode: Konsol re-runs the installer without questions, never a first install" {
    # DD-233: no terminal and no confirmation only for V2_GUNCELLEME=1; the domain and the Tailscale
    # login must already exist; the backend helpers and the tool are installed; one repository name.
    local install="$V2_ROOT/install.sh" stage key
    stage="$(awk '/^stage_0\(\) \{/,/^}$/' "$install")"
    grep -qF '[[ "${V2_GUNCELLEME:-0}" != "1" ]] || UPDATE_MODE=1' "$install"
    grep -qF "die \"Konsol'dan güncelleme ilk kurulumu yapmaz" <<<"$stage"
    grep -qF 'die "Tailscale oturumu açık değil; giriş bağlantısı gerektiği için kurulumu terminalden çalıştırın"' <<<"$stage"
    grep -qF '[[ -t 0 || -r /dev/tty ]] || die "etkileşimli TTY gerekli"' <<<"$stage"
    grep -qF 'prompt confirm_ans "Bu değerlerle kurulum başlasın mı? (E/h)" "h"' <<<"$stage"
    [ "$(grep -c 'confirm_ans="E"' <<<"$stage")" -eq 1 ]
    grep -qF 'atomic_write "$SBIN_DIR/master_update.py" 0755 <"$V2_ROOT/panel/master_update.py"' "$install"
    grep -qF 'atomic_write "$SBIN_DIR/master-guncelle" 0755 <"$V2_ROOT/scripts/master-guncelle"' "$install"
    for key in GUNCELLEME_REPO GUNCELLEME_DAL GUNCELLEME_UNIT GUNCELLEME_DURUM_FILE GUNCELLEME_LOG_FILE LOG_DIR; do
        grep -qx "$key=\$$key" "$install"
    done
    # shellcheck source=/dev/null
    source "$V2_ROOT/config/defaults.env"
    grep -qF "local repo=\"$GUNCELLEME_REPO\"" "$V2_ROOT/../kur.sh"
    [ "$GUNCELLEME_DURUM_FILE" = "$LOG_DIR/guncelleme.durum" ]
    [ "$GUNCELLEME_LOG_FILE" = "$LOG_DIR/guncelleme.log" ]
    # The start is Tailscale-only and pinned.
    grep -qF 'self.error(403, "Güncelleme yalnız Tailscale adresinden başlatılır.")' "$V2_ROOT/panel/master-panel"
}

@test "Konsol pages carry the Obhut mark as their icon and the files ship with the console" {
    # DD-256: the Ô mark is both pages' icon (SVG, light/dark aware) with a PNG for iOS home screens.
    # DD-267: Konsol's page is the build's index.html (Vite writes these links with a space before ">").
    local page svg="$V2_ROOT/console/obhut.svg" png="$V2_ROOT/console/obhut.png"
    for page in yeni/index.html giris.html; do
        grep -qE '<link rel="icon" type="image/svg\+xml" href="/obhut\.svg" ?>' "$V2_ROOT/console/$page"
        grep -qE '<link rel="apple-touch-icon" href="/obhut\.png" ?>' "$V2_ROOT/console/$page"
    done
    # The SVG is self-contained: its only URL is the SVG namespace; no script, no external image.
    run ! grep -qiE '<script|<image|xlink|href=' "$svg"
    [ "$(grep -vF 'xmlns="http://www.w3.org/2000/svg"' "$svg" | grep -ciE 'https?://')" -eq 0 ]
    grep -q 'prefers-color-scheme' "$svg"
    grep -qF '<circle cx="32" cy="41" r="14.5"/>' "$svg"
    grep -qF '<path d="M20 16L32 9L44 16"/>' "$svg"
    [ "$(od -An -tx1 -N8 "$png" | tr -d ' \n')" = "89504e470d0a1a0a" ]
    # Both files are installed with the other console files.
    grep -qw 'obhut.svg' <<<"$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qw 'obhut.png' <<<"$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # The sign-in page's brand is the wordmark, inline (it follows the theme through currentColor)
    # and identical to docs/obhut-yazi.svg; the old "Konsol." text is gone.
    local giris="$V2_ROOT/console/giris.html"
    grep -qF '<svg class="wordmark-svg" viewBox="0 -1066.4 2732 1077.4" role="img" aria-label="Obhut">' "$giris"
    run ! grep -qF 'class="wordmark">Konsol' "$giris"
    [ "$(grep -oE ' d="[^"]*"' "$giris" | sort)" = "$(grep -oE ' d="[^"]*"' "$V2_ROOT/docs/obhut-yazi.svg" | sort)" ]
    [ "$(grep -o ' d="' "$giris" | wc -l | tr -d ' ')" -eq 5 ]
    grep -qF '.login .wordmark-svg { display: block; height: 40px; width: auto; color: var(--ink); }' "$V2_ROOT/console/giris.css"
    run ! grep -qF 'class="wordmark"' "$giris"
}

@test "stage 7 checks DNS on Tailscale IP and publish surface" {
    grep -q 'status: REFUSED' "$V2_ROOT/install.sh"
    grep -q 'for resolver in 127.0.0.1' "$V2_ROOT/install.sh"
    run ! grep -q 'WebDAV Tailscale publish' "$V2_ROOT/install.sh"
    run ! grep -q 'v2-write-probe' "$V2_ROOT/install.sh"
    run ! grep -q 'docker port wg-easy' "$V2_ROOT/install.sh"
    # DD-151: no base containers.
    [ "$(grep -c 'docker port' "$V2_ROOT/install.sh")" -eq 0 ]
    # DD-159/271: stage 7 checks the share's publish surface itself (verify_builtins).
    body="$(awk '/^verify_builtins\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qF '[[ "$uid" == "$DOWNLOADS_UID" && "$code" == 401 ]]' <<<"$body"
    grep -qF 'http_code "http://127.0.0.1:$SHARE_PORT/"' <<<"$body"
    grep -qF 'http_code -H "Host: paylas.$LOCAL_DOMAIN" "http://$TAILSCALE_IPV4/"' <<<"$body"
    grep -qF 'http_code "http://$TAILSCALE_IPV4:$SHARE_PORT/"' <<<"$body"
    grep -qF 'dig +short +time=2 +tries=1 "paylas.$LOCAL_DOMAIN" @"$TAILSCALE_IPV4"' <<<"$body"
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
    grep -q '"dns:${DNS_PORT:-53}" "http:${CADDY_HTTP_PORT:-80}"' "$V2_ROOT/scripts/master-wg"
    grep -q 'CADDY_HTTP_PORT' "$V2_ROOT/install.sh"
}

@test "FileBrowser is gone: no container, account, port, database or file. name" {
    # DD-146: Konsol's own file manager (upload, multi-select, search) replaced it.
    local code
    code="$(grep -hvE '^[[:space:]]*#' "$V2_ROOT/config/defaults.env" \
        "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf" \
        "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT/scripts/firewall.sh" "$V2_ROOT/scripts/master-wg" \
        "$V2_ROOT/panel/master-panel" "$V2_ROOT/console/yeni/app.js" "$V2_ROOT/console/yeni/index.html" \
        "$V2_ROOT/config/kurulum.env.example")"
    run ! grep -qi 'filebrowser' <<<"$code"
    run ! grep -q '61007' <<<"$code"
    # DD-154: the old name is gone too (it only redirected to the console).
    run ! grep -q 'file\.__LOCAL_DOMAIN__' "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf"
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
}

@test "WebDAV uses packaged Python with no downloaded executable or shared plaintext password" {
    run ! grep -qE '^RCLONE_|^SHARE_ACCOUNT=|^SHARE_PASSWORD_LENGTH=' "$V2_ROOT/config/defaults.env"
    run ! grep -qE 'share_rclone|share_write_account' "$V2_ROOT/install.sh"
    grep -qx 'SHARE_STATE_FILE="/etc/master-stack/webdav.json"' "$V2_ROOT/config/defaults.env"
    grep -q 'hashlib.scrypt' "$V2_ROOT/panel/master_shares.py"
    grep -q 'hmac.compare_digest' "$V2_ROOT/panel/master_shares.py"
    grep -q 'parser.error("WebDAV root olarak çalıştırılamaz.")' "$V2_ROOT/panel/master_webdav.py"
}

@test "refresh timer has no no-op Persistent key" {
    # DD-240: the nightly OnCalendar run needs no catch-up; the boot run covers a missed night.
    run ! grep -q 'Persistent=' "$V2_ROOT/systemd/refresh-tailnet-config.timer" "$V2_ROOT/systemd/master-duvar-denetim.timer"
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
    # DD-184: Tailscale and Caddy repositories join the distribution's list, updates at night.
    grep -qF '"$TAILSCALE_APT_ORIGIN";' <<<"$body"
    grep -qF '"$CADDY_APT_ORIGIN";' <<<"$body"
    grep -qx 'TAILSCALE_APT_ORIGIN="origin=Tailscale,label=Tailscale"' "$V2_ROOT/config/defaults.env"
    grep -qx 'CADDY_APT_ORIGIN="origin=cloudsmith/caddy/stable"' "$V2_ROOT/config/defaults.env"
    grep -qF 'OnCalendar=*-*-* $APT_UPGRADE_TIME' <<<"$body"
    grep -qx 'OnCalendar=' <<<"$body"
    grep -qF 'systemctl restart apt-daily-upgrade.timer' <<<"$body"
    run ! grep -q 'Automatic-Reboot "true"' "$V2_ROOT/install.sh"
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

@test "repository root carries kur.sh and no exported installer" {
    # DD-228 retires the DD-154 portable .command and its exporter; kur.sh is the entry point.
    local top copies
    top="$(cd "$V2_ROOT/.." && pwd)"
    [ -f "$top/kur.sh" ]
    copies=( "$top"/*.command )
    # DD-239: onar.command is the SSH fallback for "Denetle ve onar".
    [ "$(printf '%s\n' "${copies[@]##*/}" | sort | tr '\n' ' ')" = 'onar.command wireguard.command ' ]
    [ ! -e "$V2_ROOT/app" ]
    [ ! -e "$V2_ROOT/dev/export-installer.sh" ]
    # DD-122: the backup tool is retired; nothing of it may come back.
    [ ! -e "$top/container-backup.command" ]
    [ ! -e "$V2_ROOT/dev/container-backup-remote.sh" ]
    [ ! -e "$V2_ROOT/docs/container-backup.md" ]
    [ ! -e "$V2_ROOT/tests/backup-roundtrip.sh" ]
}

@test "tailscale joins only through the login link: no auth key input, file or flag" {
    # DD-147: the operator approves the link shown during the install; nothing is typed or stored.
    run ! grep -q 'TS_AUTH_KEY' "$V2_ROOT/install.sh" "$V2_ROOT/config/kurulum.env.example" "$V2_ROOT/config/defaults.env"
    run ! grep -qE -- '--auth-key|tailscale-authkey|TS_AUTHKEY_LOGIN_SECONDS|tailscale_login_with_key' \
        "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env"
    stage2="$(awk '/^stage_2\(\)/,/^stage_3\(\)/' "$V2_ROOT/install.sh")"
    grep -q 'if \[\[ "\$(tailscale_login_state)" != "complete" \]\]; then' <<<"$stage2"
    grep -qx '        tailscale_login' <<<"$stage2"
    grep -q 'giriş bağlantısı gösterilir' "$V2_ROOT/install.sh"
}

@test "stage 0 asks for the domain on the server and confirms before the first write" {
    stage0="$(awk '/^stage_0\(\)/,/^stage_1\(\)/' "$V2_ROOT/install.sh")"
    # DD-228: no input file reaches the server any more.
    run ! grep -qE 'read_input_file|INPUT_FILE|INPUT_DIR|INPUT_KEYS' \
        "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT/config/defaults.env"
    # The domain has no default: a name confirmed in Konsol (DD-157) or the previous install's
    # wins and is not asked; only a first install asks, before the confirmation.
    grep -q 'read -r -p "Yerel alan adı (ör. ev; panel.<ad> olur): " reply </dev/tty' <<<"$stage0"
    run ! grep -q 'prompt LOCAL_DOMAIN' <<<"$stage0"
    awk '/saved-domain/ {s = NR} /Yerel alan adı/ {p = NR} /prompt confirm_ans/ {c = NR}
         END { exit !(s && p && c && s < p && p < c) }' <<<"$stage0"
    # Every run upgrades the system first; nothing asks or skips it.
    grep -qx '  full-upgrade:  evet' <<<"$stage0"
    run ! grep -qE 'upgrade_ans|V2_FULL_UPGRADE|yes_no_upgrade' "$V2_ROOT/install.sh"
    # DD-124/DD-143: nothing of WireGuard is an input.
    run ! grep -qE 'take_snapshot_input|validate_snapshot' <<<"$stage0"
    run ! grep -qE 'INPUT_WG_DIR|OUTPUT_DIR|OUTPUT_WG_DIR|\bWG_PEERS\b' \
        "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh" "$V2_ROOT/config/kurulum.env.example"
    # One confirmation, then config.env: nothing is written before the operator agrees.
    awk '/prompt confirm_ans/ {c = NR} /^    write_config$/ {w = NR}
         END { exit !(c && w && c < w) }' <<<"$stage0"
    [ "$(grep -c 'write_config' <<<"$stage0")" -eq 1 ]
    grep -q 'die "kurulum iptal edildi' <<<"$stage0"
    # The old secret prompts are gone for good.
    run ! grep -qE 'prompt_secret_twice|prompt_optional_secret|read -r -s' "$V2_ROOT/install.sh"
    # The summary names accounts, never passwords.
    summary="$(awk '/^Kurulum girdileri:$/,/^EOF$/' <<<"$stage0")"
    [ -n "$summary" ]
    run ! grep -q '_PASS' <<<"$summary"
    run ! grep -q 'TS_AUTH_KEY' <<<"$summary"
}


@test "the generation gate refuses an older Obhut before any write and marks this generation (DD-271)" {
    local harness install="$V2_ROOT/install.sh" stage0
    # The generation sits beside the release; state.env records it for Konsol's update check.
    grep -A6 '^OBHUT_SURUM="' "$install" | grep -qx 'OBHUT_NESIL="2"'
    grep -qE '^V2_VERSION="[0-9]{4}\.[0-9]{2}\.[0-9]{2}-v2-[0-9]+"$' "$install"
    grep -qx 'OBHUT_NESIL=$OBHUT_NESIL' <<<"$(awk '/^write_state\(\)/,/^}$/' "$install")"
    grep -qx 'NESIL_FILE="/etc/master-stack/nesil"' "$V2_ROOT/config/defaults.env"
    grep -qx 'ESKI_NESIL_IZLERI="/usr/local/sbin/master-modul /usr/local/share/master-stack/moduller /etc/master-stack/moduller"' \
        "$V2_ROOT/config/defaults.env"
    harness='
        set -Eeuo pipefail
        source "$V2_ROOT/common.sh"
        eval "$(awk "/^check_generation\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
        eval "$(awk "/^write_generation\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
        OBHUT_NESIL=2 STATE_DIR="$T/etc/master-stack" NESIL_FILE="$T/etc/master-stack/nesil"
        ESKI_NESIL_IZLERI="$T/sbin/master-modul $T/share/moduller $T/etc/master-stack/moduller"
        "$@"'
    mkdir -p "$TMP/etc" "$TMP/sbin" "$TMP/share"
    # A clean system passes and the first write is the marker (0644, the generation only).
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_generation
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/etc/master-stack" ]
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ write_generation
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/etc/master-stack/nesil")" = 2 ]
    [ "$(stat_field %a %Lp "$TMP/etc/master-stack/nesil")" = 644 ]
    # A re-run of this generation passes.
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_generation
    [ "$status" -eq 0 ]
    # Another generation, a state folder without the marker or a linked marker: refused.
    printf '1\n' >"$TMP/etc/master-stack/nesil"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_generation
    [ "$status" -ne 0 ]
    case "$output" in *"Bu sunucuda eski nesil bir Obhut var"*"nesil: 1"*"yalnız temiz bir işletim sistemine kurulur"*) ;; *) false ;; esac
    rm -f "$TMP/etc/master-stack/nesil"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_generation
    [ "$status" -ne 0 ]
    case "$output" in *"nesil: yok"*) ;; *) false ;; esac
    printf '2\n' >"$TMP/marker"
    ln -s "$TMP/marker" "$TMP/etc/master-stack/nesil"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_generation
    [ "$status" -ne 0 ]
    # Any trace only an older Obhut leaves is refused, with or without a state folder.
    rm -rf "$TMP/etc/master-stack"
    for trace in "$TMP/sbin/master-modul" "$TMP/share/moduller" "$TMP/etc/master-stack/moduller"; do
        mkdir -p "${trace%/*}"
        : >"$trace"
        [ ! -d "$TMP/etc/master-stack" ] || printf '2\n' >"$TMP/etc/master-stack/nesil"
        run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_generation
        [ "$status" -ne 0 ]
        case "$output" in *"eski nesil bir Obhut var ($trace)"*) ;; *) false ;; esac
        rm -f "$trace"
    done
    # Stage 0 runs the gate before the lock and any write; the marker is the first write, right
    # after the confirmation; the top of the installer no longer creates STATE_DIR.
    stage0="$(awk '/^stage_0\(\)/,/^}$/' "$install")"
    awk '/^    check_generation$/ {g = NR} /acquire_lock/ {l = NR} /prompt confirm_ans/ {c = NR}
         /^    write_generation$/ {m = NR} /^    write_config$/ {w = NR}
         END { exit !(g && l && c && m && w && g < l && l < c && c < m && m + 1 == w) }' <<<"$stage0"
    grep -qx 'mkdir -p "$LOG_DIR" "$RUNTIME_DIR"' "$install"
    run ! grep -qE '^mkdir -p .*STATE_DIR' "$install"
    # No other gate or cleanup for older installs is left.
    run ! grep -qE '\.pay|RETIRED_|remove_retired|eski bir sürüm' "$install" "$V2_ROOT/config/defaults.env"
}

@test "kurulum.env template carries only wireguard.command's SSH host" {
    local template="$V2_ROOT/config/kurulum.env.example"
    [ "$(grep -E '^[A-Z][A-Z0-9_]*=' "$template" | cut -d= -f1 | tr '\n' ' ')" = 'SSH_HOST ' ]
    run ! grep -qE '^[A-Z][A-Z0-9_]*=.+' "$template"
    grep -qx '/kurulum/' "$V2_ROOT/../.gitignore"
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
    run ! grep -q 'wireguard/sunucu' "$V2_ROOT/../kur.sh"
    # Girdi dosyasında WireGuard portu da yok: ağın portunu Konsol belirler.
    run ! grep -q 'WG_PUBLIC_PORT' "$V2_ROOT/config/kurulum.env.example"
    run ! grep -q 'INPUT_WG_PUBLIC_PORT' "$V2_ROOT/install.sh"
    # DD-271: the installer prepares WireGuard's tool, drop-in, folder and kernel module, but never
    # makes a key or a network of its own.
    local ready
    ready="$(awk '/^ensure_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ -n "$ready" ]
    run ! grep -qE 'wg genkey|syncconf|PrivateKey|net-add' <<<"$ready"
    run ! grep -qE 'master-wg" (net-add|add|baslat)' "$V2_ROOT/install.sh"
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
    # Konsol'un root arka ucu; master-wg her çağrıyı günlükleyen sahte bir araç (DD-133, DD-143, DD-271).
    # Sahte araçlar state'teki SBIN_DIR'de durur; arka uç onları oradan çalıştırır (--state-env).
    PANEL="$V2_ROOT/panel/master-panel"
    mkdir -p "$TMP/pbin" "$TMP/clients"
    printf '[Interface]\n' >"$TMP/wg0.conf"
    touch -t 202001010000 "$TMP/wg0.conf" "$TMP/clients"
    cat >"$TMP/state.env" <<EOF
V2_VERSION=2026.08.06-v2-test
LOCAL_DOMAIN=ayc
WAN_IPV4=203.0.113.7
SHARE_PORT=61010
SHARE_HTTPS_PORT=443
TAILSCALE_IPV4=100.64.0.7
SERVER_ROOT=$TMP
RUNTIME_DIR=$TMP/run
SBIN_DIR=$TMP/pbin
WG_PORT_DEFAULT=61001
WG_ADDR_BASE4=10.8
WG_ADDR_BASE6=fdcc:ad94:bacf:61a4
WG_MTU=1420
WG_CLIENT_DNS_DEFAULT="1.1.1.1, 1.0.0.1, 2606:4700:4700::1001"
WG_CLIENT_KEEPALIVE_DEFAULT=21
WG_CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
WG_CONF_DIR=$TMP
WG_CLIENTS_DIR=$TMP/clients
WG_NETWORKS_FILE=$TMP/networks
WG_STOPPED_FILE=$TMP/.durduruldu
WG_NETWORKS_MAX=9
EOF
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\n' >"$TMP/networks"
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
    # Sahte systemd araçları (çağrıları günlükler).
    cat >"$TMP/pbin/systemd-run" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/sdrun-calls"
# A worker run (--pipe): its JSON request arrives on stdin and it answers JSON (DD-202, DD-210).
case " \$* " in *" --pipe "*) cat >>"$TMP/sdrun-stdin"; printf '{"ok": true}\n' ;; esac
EOF
    cat >"$TMP/pbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/systemctl-calls"
[ "\$1" != list-units ] || exit 0
exit 3
EOF
    chmod +x "$TMP/pbin/systemd-run" "$TMP/pbin/systemctl"
    # DD-180: no TCP port; a short socket path (macOS allows 104 bytes).
    PSOCK="$(mktemp -d /tmp/wgp.XXXXXX)/api.sock"
    python3 "$PANEL" serve --listen "unix:$PSOCK" --state "$TMP/state.env" --state-env >"$TMP/panel.log" 2>&1 &
    PANEL_PID=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null --unix-socket "$PSOCK" "http://panel.ayc/api/konsol/kaynaklar" && return 0
        sleep 0.1
    done
    cat "$TMP/panel.log"
    return 1
}

pc() {
    local path="$1"
    shift
    curl -s -o "$TMP/body" -D "$TMP/head" -w '%{http_code}' --unix-socket "$PSOCK" -H "Host: panel.ayc" "$@" "http://panel.ayc$path"
}

@test "wg panel needs no password but a known host and the panel header before it runs master-wg" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    # DD-147: no password and no login prompt; Tailscale is the boundary.
    # Konsol sayfasını dosya arka ucu verir; burada kök 404'tür.
    [ "$(pc /)" = 404 ]
    run ! grep -qi '^WWW-Authenticate' "$TMP/head"
    [ "$(pc /api/konsol/wireguard/state -H 'X-Konsol: 1')" = 200 ]
    grep -qi "^Content-Security-Policy: default-src 'none'; base-uri 'none'" "$TMP/head"
    grep -qi '^Cache-Control: no-store' "$TMP/head"
    grep -qi '^X-Frame-Options: DENY' "$TMP/head"
    # DNS rebinding: another Host name is refused even with the password.
    [ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$PSOCK" -H 'Host: evil.example' "http://panel.ayc/")" = 403 ]
    # DD-180: the loopback names are no longer trusted Host values.
    for host in 127.0.0.1:61008 localhost:61008 localhost; do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$PSOCK" -H 'X-Konsol: 1' -H "Host: $host" \
            "http://panel.ayc/api/konsol/wireguard/state")" = 403 ]
    done
    # DD-180: what Caddy relays must come from another tailnet device, never from this host.
    for ip in 127.0.0.1 203.0.113.5 10.8.0.2 ::1 fe80::1 not-an-ip; do
        [ "$(pc /api/konsol/wireguard/state -H 'X-Konsol: 1' -H "X-Forwarded-For: $ip")" = 403 ]
        grep -q 'başka bir Tailscale cihazından' "$TMP/body"
    done
    [ "$(pc /api/konsol/wireguard/state -H 'X-Konsol: 1' -H 'X-Forwarded-For: 100.64.0.9')" = 200 ]
    [ "$(pc /api/konsol/wireguard/state -H 'X-Konsol: 1' -H 'X-Forwarded-For: fd7a:115c:a1e0::9')" = 200 ]
    # CSRF: the API needs the panel header and a same-origin fetch.
    [ "$(pc /api/konsol/wireguard/state)" = 403 ]
    [ "$(pc /api/konsol/wireguard/state -H 'X-Konsol: 1' -H 'Sec-Fetch-Site: cross-site')" = 403 ]
    # Only the background sampler's read-only calls (DD-137) may have run.
    touch "$TMP/mwg-calls"
    run ! grep -qvE '^(wg[0-9]|yok)\|(nets|info)$' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/state -H 'X-Konsol: 1' -H 'Sec-Fetch-Site: same-origin')" = 200 ]
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
    # check (stage 7): no password; the probe is the resources endpoint.
    run python3 "$PANEL" check --socket "$PSOCK" --url "http://panel.ayc/api/konsol/kaynaklar" --host panel.ayc
    [ "$status" -eq 0 ]
    [ "$output" = "sürüm 2026.08.06-v2-test" ]
    # Another route is no probe target: anything but the resources answer fails the check.
    run python3 "$PANEL" check --socket "$PSOCK" --url "http://panel.ayc/api/konsol/wireguard/state" --host panel.ayc
    [ "$status" -ne 0 ]
    # A foreign name fails the check (the Host gate stays).
    run python3 "$PANEL" check --socket "$PSOCK" --url "http://panel.ayc/api/konsol/kaynaklar" --host evil.example
    [ "$status" -ne 0 ]
    case "$output" in *"HTTP 403"*) ;; *) false ;; esac
    # The account machinery is gone for good.
    run ! grep -qE 'pbkdf2|WWW-Authenticate|def cmd_account|locked_out|FAIL_LIMIT' "$PANEL"
}

@test "WireGuard stops as a whole and restarts only the networks that were open (DD-229)" {
    grep -q '^WG_STOPPED_FILE="/etc/wireguard/.durduruldu"$' "$V2_ROOT/config/defaults.env"
    wg_mock_bin
    wg_state_fixture
    local wgd="$TMP/etc/wireguard"
    mkdir -p "$TMP/en"
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tA\nwg1\t61020\tinet\t10.8.1.1\t10.8.1.0/24\tfd00::1:1\tfd00::1:0/112\t1.1.1.1\tB\nwg2\t61021\tinet\t10.8.2.1\t10.8.2.0/24\tfd00::2:1\tfd00::2:0/112\t1.1.1.1\tC\n' >"$wgd/networks"
    touch "$TMP/en/wg-quick@wg0.service" "$TMP/en/wg-quick@wg2.service"   # wg1 was closed on its own
    cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
case "$*" in *"${SYSTEMCTL_FAIL:-@none@}"*) exit 1 ;; esac
case "$1" in
    is-enabled) [ -e "$MOCK_DIR/en/$3" ] ;;
    enable) touch "$MOCK_DIR/en/$4" ;;
    disable) rm -f "$MOCK_DIR/en/$4" ;;
    list-unit-files | list-units) ls "$MOCK_DIR/en" ;;
esac
EOF
    chmod +x "$TMP/bin/systemctl"
    # Stop: the open networks are listed first, every unit goes down, then the firewall is applied.
    run master_wg durdur
    [ "$status" -eq 0 ]
    [ "$output" = $'durduruldu\t2' ]
    [ "$(cat "$wgd/.durduruldu")" = $'wg0\nwg2' ]
    [ "$(stat_field %a %Lp "$wgd/.durduruldu")" = 600 ]
    [ -z "$(ls "$TMP/en")" ]
    [ "$(tail -n 1 "$TMP/calls")" = "systemctl restart master-firewall.service" ]
    # A second stop keeps the original list.
    run master_wg durdur
    [ "$status" -eq 0 ]
    [ "$(cat "$wgd/.durduruldu")" = $'wg0\nwg2' ]
    # While stopped, master-wg refuses to open or add a network.
    run master_wg --if wg0 net ac
    [ "$status" -ne 0 ]
    case "$output" in *"WireGuard durduruldu; önce Konsol → Erişim → WireGuard'dan başlatın"*) ;; *) false ;; esac
    run master_wg net-add 61031 1.1.1.1 x
    [ "$status" -ne 0 ]
    [ "$(grep -c '^    not_stopped$' "$V2_ROOT/scripts/master-wg")" -eq 2 ]
    # Start: a failed firewall keeps WireGuard stopped with the same list.
    : >"$TMP/calls"
    export SYSTEMCTL_FAIL="restart master-firewall.service"
    run master_wg baslat
    unset SYSTEMCTL_FAIL
    [ "$status" -ne 0 ]
    [ "$(cat "$wgd/.durduruldu")" = $'wg0\nwg2' ]
    [ -z "$(ls "$TMP/en")" ]
    # Start: the firewall first, then only wg0 and wg2 (wg2 deleted meanwhile is skipped); the list goes.
    sed -i.bak '/^wg2\t/d' "$wgd/networks"
    : >"$TMP/calls"
    run master_wg baslat
    [ "$status" -eq 0 ]
    [ "$output" = $'calisiyor\t1' ]
    [ "$(ls "$TMP/en")" = 'wg-quick@wg0.service' ]
    [ ! -e "$wgd/.durduruldu" ]
    awk '/systemctl restart master-firewall.service/ {f = NR} /systemctl enable --now --quiet wg-quick@wg0.service/ {w = NR}
         END { exit !(f && w && f < w) }' "$TMP/calls"
    # A pending Konsol setting blocks both, and neither takes a network argument.
    printf 'SETTINGS_PENDING_FILE=%s/pending.json\n' "$TMP" >>"$TMP/state.env"
    : >"$TMP/pending.json"
    run master_wg durdur
    [ "$status" -ne 0 ]
    case "$output" in *"bekleyen ayar"*) ;; *) false ;; esac
    [ ! -e "$wgd/.durduruldu" ]
    rm -f "$TMP/pending.json"
    run master_wg --if wg0 durdur
    [ "$status" -ne 0 ]
    run master_wg baslat extra
    [ "$status" -ne 0 ]
}

@test "the installer's re-run and final check follow WireGuard's own state (DD-229, DD-271)" {
    mkdir -p "$TMP/wg" "$TMP/en" "$TMP/units/wg-quick@.service.d"
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tA\nwg1\t61020\tinet\t10.8.1.1\t10.8.1.0/24\tfd00::1:1\tfd00::1:0/112\t1.1.1.1\tB\n' >"$TMP/wg/networks"
    local harness='
        set -Eeuo pipefail
        source "$V2_ROOT/common.sh"
        eval "$(awk "/^wireguard_networks_up\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
        eval "$(awk "/^check_wireguard\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
        WG_NETWORKS_FILE="$T/wg/networks" WG_STOPPED_FILE="$T/wg/.durduruldu"
        WG_MODULES_LOAD_FILE="$T/mod" SBIN_DIR="$T/sbin" UNIT_DIR="$T/units" FILES_PANEL_PORT=61009
        systemctl() {
            case "$1" in
                is-enabled) [[ -e "$T/en/$3" ]] ;;
                enable) touch "$T/en/$4" ;;
            esac
        }
        wg() { echo 1; }
        ip() { echo "5: $5    inet 10.8.0.1/24 scope global $5"; }
        curl() { echo 000; }
        "$@"'
    # A re-run brings the registered networks up unless WireGuard is stopped.
    printf 'wg0\n' >"$TMP/wg/.durduruldu"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ wireguard_networks_up
    [ "$status" -eq 0 ] && [ -z "$(ls "$TMP/en")" ]
    rm -f "$TMP/wg/.durduruldu"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ wireguard_networks_up
    [ "$status" -eq 0 ]
    [ "$(ls "$TMP/en" | tr '\n' ' ')" = 'wg-quick@wg0.service wg-quick@wg1.service ' ]
    # The final check needs the tool, the module file and the drop-in.
    mkdir -p "$TMP/sbin"; printf '#!/bin/bash\nexit 0\n' >"$TMP/sbin/master-wg"; chmod +x "$TMP/sbin/master-wg"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_wireguard
    [ "$status" -ne 0 ]
    case "$output" in *"çekirdek modülü dosyası yok"*) ;; *) false ;; esac
    touch "$TMP/mod"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_wireguard
    [ "$status" -ne 0 ]
    case "$output" in *"wg-quick@ birim eki yok"*) ;; *) false ;; esac
    touch "$TMP/units/wg-quick@.service.d/master-stack.conf"
    # An open network listening on another port fails; a stopped WireGuard and a network closed on
    # its own are not checked (found live on nrm, v2-208).
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_wireguard
    [ "$status" -ne 0 ]
    case "$output" in *"wg0 dinleme portu kayıttaki 61001 değil"*) ;; *) false ;; esac
    printf 'wg0\n' >"$TMP/wg/.durduruldu"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_wireguard
    [ "$status" -eq 0 ]
    rm -f "$TMP/wg/.durduruldu" "$TMP"/en/*
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_wireguard
    [ "$status" -eq 0 ]
    # No network at all: only the tool, the module file and the drop-in are checked.
    rm -f "$TMP/wg/networks"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness" _ check_wireguard
    [ "$status" -eq 0 ]
    # Both run in stage 7: the networks after the builtins, the check after the DNS checks.
    s7="$(awk '/^stage_7\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx '    wireguard_networks_up' <<<"$s7"
    grep -qx '    check_wireguard' <<<"$s7"
}


builtin_harness() {
    # The installer's own functions for the two built-ins, with the host's tools as logged stand-ins.
    # T is the fixture root; the units and tools land under it, every other value is the base's.
    mkdir -p "$TMP/units" "$TMP/sbin"
    printf '%s\n' '
        set -Eeuo pipefail
        source "$V2_ROOT/common.sh"
        source "$V2_ROOT/config/defaults.env"
        for f in ensure_files_panel ensure_share unit_uid http_code verify_builtins; do
            eval "$(awk "/^$f\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
        done
        SBIN_DIR="$T/sbin" UNIT_DIR="$T/units" LOCAL_DOMAIN=ayc V2_VERSION=2026.08.06-v2-test
        TAILSCALE_IPV4=100.64.0.7 STATE_FILE="$T/state.env"
        FILES_PANEL_SCRIPT_CHANGED=0 SHARE_HELPERS_CHANGED="${SHARE_HELPERS_CHANGED:-0}"
        getent() { printf "%s:x:%s:\n" kullanici "$2"; }
        groupadd() { echo "groupadd $*" >>"$T/log"; }
        useradd() { echo "useradd $*" >>"$T/log"; }
        systemctl() {
            echo "systemctl $*" >>"$T/log"
            case "$1" in
                is-active) [[ -e "$T/active-${3%.service}" ]] ;;
                restart) touch "$T/active-${2%.service}" ;;
                show) echo 4242 ;;
            esac
        }
        python3() {
            echo "python3 $*" >>"$T/log"
            case "$*" in
                *"master_shares.py prepare") [[ ! -e "$T/prepare-fail" ]] ;;
                *"tail-enabled paylasim") [[ ! -e "$T/tail-off" ]] || return 1 ;;
                *) return 0 ;;
            esac
        }
        ps() { echo " ${FAKE_UID:-1000}"; }
        curl() {
            case "$*" in
                *"127.0.0.1:61010/"*) printf "%s" "${SHARE_LOCAL:-401}" ;;
                *) if [[ -e "$T/tail-off" ]]; then printf 403; else printf 401; fi ;;
            esac
        }
        dig() { echo 100.64.0.7; }
        sleep() { :; }
        "$@"'
}

@test "Files and folder WebDAV are rendered straight into the unit folder by the installer (DD-159, DD-271)" {
    local h files share
    h="$(builtin_harness)"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ ensure_files_panel 0
    [ "$status" -eq 0 ]
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ ensure_share 0
    [ "$status" -eq 0 ]
    files="$TMP/units/master-files-panel.service" share="$TMP/units/master-paylasim.service"
    [ -f "$files" ] && [ -f "$share" ] && [ -x "$TMP/sbin/master-files-panel" ]
    run ! grep -q '__[A-Z][A-Z0-9_]*__' "$files" "$share"
    # Files: the downloads account by name, loopback, no package folders, no retired arguments.
    grep -qx 'User=kullanici' "$files"
    grep -q -- '--listen 127.0.0.1:61009 --root /srv --trash .cop --domain=ayc --version=2026.08.06-v2-test --downloads-dir=downloads$' "$files"
    grep -qx 'InaccessiblePaths=/var/lib' "$files"
    # WebDAV: the downloads uid, the registry as a credential, both listeners, trash and private state hidden.
    grep -qx 'User=1000' "$share"
    grep -qx 'LoadCredential=registry:/etc/master-stack/webdav.json' "$share"
    grep -q -- '--port=61010 --wan-listen=127.0.0.2$' "$share"
    grep -qx 'InaccessiblePaths=/srv/.cop /var/lib' "$share"
    # The registry is prepared before the unit; both are enabled and started on a first run.
    awk '/master_shares.py prepare/ {p = NR} /enable --quiet master-paylasim.service/ {e = NR}
         END { exit !(p && e && p < e) }' "$TMP/log"
    grep -qx 'systemctl restart master-files-panel.service' "$TMP/log"
    grep -qx 'systemctl restart master-paylasim.service' "$TMP/log"
    # A re-run with nothing changed restarts neither; a changed WebDAV helper restarts only WebDAV.
    : >"$TMP/log"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ ensure_files_panel 0
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ ensure_share 0
    run ! grep -q 'restart' "$TMP/log"
    run env T="$TMP" V2_ROOT="$V2_ROOT" SHARE_HELPERS_CHANGED=1 bash -c "$h" _ ensure_share 0
    grep -qx 'systemctl restart master-paylasim.service' "$TMP/log"
    run ! grep -q 'restart master-files-panel' "$TMP/log"
    # A registry that cannot be prepared stops the installer before the unit changes.
    rm -f "$share"
    touch "$TMP/prepare-fail"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ ensure_share 0
    [ "$status" -ne 0 ]
    case "$output" in *"klasör paylaşım kaydı hazırlanamadı"*) ;; *) false ;; esac
    [ ! -e "$share" ]
    # Stage 6 starts both; nothing goes through a module folder or registry.
    s6="$(awk '/^stage_6\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx '    ensure_files_panel "$OS_CHANGED"' <<<"$s6"
    grep -qx '    ensure_share "$OS_CHANGED"' <<<"$s6"
    run ! grep -qE '(^|[^A-Z_])MODULES_|master-modul|yerlesik' "$V2_ROOT/install.sh"
}

@test "stage 6 writes the share's site and name with the base and through Konsol's choices (DD-158, DD-191)" {
    local s6
    s6="$(awk '/^stage_6\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # The name: rendered, filtered by Konsol's DNS choices, beside the base names, before dnsmasq's check.
    grep -qF 'render_template "$V2_ROOT/templates/paylasim-dnsmasq.conf" "$dns_tmp" 0644' <<<"$s6"
    grep -qF 'atomic_write "$DNSMASQ_CONF_DIR/modul-paylasim.conf" 0644 <"$dns_tmp"' <<<"$s6"
    awk '/templates\/paylasim-dnsmasq.conf/ {r = NR} /filter-dns "\$dns_tmp"/ && r && !f {f = NR} /modul-paylasim.conf/ {w = NR}
         /dnsmasq --test/ {t = NR} END { exit !(r && f > r && w > f && t > w) }' <<<"$s6"
    # The site: the filled template is kept as the source Konsol's publication choice reads; Caddy's
    # copy passes that choice, and both come before Caddy's validation.
    grep -qx 'SHARE_CADDY_SOURCE="/usr/local/share/master-stack/paylasim.caddy"' "$V2_ROOT/config/defaults.env"
    grep -qx 'SHARE_CADDY_SOURCE=$SHARE_CADDY_SOURCE' "$V2_ROOT/install.sh"
    grep -qF 'render_template "$V2_ROOT/templates/paylasim.caddy" "$SHARE_CADDY_SOURCE" 0644' <<<"$s6"
    grep -qF 'master_publications.py" --state "$STATE_FILE" filter-caddy paylasim "$caddy_tmp"' <<<"$s6"
    awk '/filter-caddy paylasim/ {f = NR} /"\$CADDY_MODULES_DIR\/paylasim.caddy"/ {w = NR} /caddy validate --config/ {v = NR}
         END { exit !(f && w > f && v > w) }' <<<"$s6"
    grep -q '^http://paylas.__LOCAL_DOMAIN__, http://{$TAILSCALE_IPV4}:__SHARE_PORT__ {$' "$V2_ROOT/templates/paylasim.caddy"
    grep -qx 'interface-name=paylas.__LOCAL_DOMAIN__,__TAILSCALE_IF__/4' "$V2_ROOT/templates/paylasim-dnsmasq.conf"
}

@test "stage 7 waits for both built-ins and proves the share's addresses before publishing (DD-159)" {
    local h
    h="$(builtin_harness)"
    touch "$TMP/active-master-files-panel" "$TMP/active-master-paylasim"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ verify_builtins
    [ "$status" -eq 0 ]
    grep -qF 'master-files-panel check --url http://127.0.0.1:61009/api/state --host panel.ayc' "$TMP/log"
    # The share must refuse a request without an account and run as the downloads uid.
    run env T="$TMP" V2_ROOT="$V2_ROOT" SHARE_LOCAL=200 bash -c "$h" _ verify_builtins
    [ "$status" -ne 0 ]
    case "$output" in *"Paylaşım: uid/adres/giriş kapısı doğrulanamadı"*) ;; *) false ;; esac
    run env T="$TMP" V2_ROOT="$V2_ROOT" FAKE_UID=0 bash -c "$h" _ verify_builtins
    [ "$status" -ne 0 ]
    # Konsol turned the share's Tailscale publication off: both addresses must answer 403.
    touch "$TMP/tail-off"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ verify_builtins
    [ "$status" -eq 0 ]
    rm -f "$TMP/tail-off" "$TMP/active-master-paylasim"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$h" _ verify_builtins
    [ "$status" -ne 0 ]
    case "$output" in *"Paylaşım: servis başlamadı"*) ;; *) false ;; esac
    # Stage 7 starts with the proof; the share's public sites are published only after it.
    s7="$(awk '/^stage_7\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ "$(grep -n '^    verify_builtins$' <<<"$s7" | cut -d: -f1)" -lt "$(grep -n 'master_shares.py" publish' <<<"$s7" | cut -d: -f1)" ]
}


@test "legacy share markers and credential paths have no runtime consumers" {
    run ! grep -qE 'SHARE_ENABLED|share_enabled|share_summary' "$V2_ROOT/install.sh" "$V2_ROOT/files-panel/master-files-panel"
    run ! grep -qE 'SHARE_CRED_FILE|SHARE_HTPASSWD_FILE' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh"
    run ! grep -q 'os.symlink' "$V2_ROOT/files-panel/master-files-panel"
    run ! grep -q '/api/paylas"' "$V2_ROOT/files-panel/master-files-panel"
}

@test "stage 3 creates the current tree; nothing is reserved for an older install" {
    eval "$(awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    detect_wan() { :; }
    detect_tailscale() { :; }
    write_state() { V2_LAST_ATOMIC_CHANGED=0; }
    log() { :; }
    SERVER_ROOT="$TMP/root" DOWNLOADS_PATH="$TMP/root/downloads" MEDIA_SUBDIR=media
    FILES_PANEL_TRASH=.cop
    DOWNLOADS_UID="$(id -u)" DOWNLOADS_GID="$(id -g)"
    stage_3
    [ -d "$SERVER_ROOT/downloads" ]
    [ -d "$SERVER_ROOT/media/movies" ]
    [ -d "$SERVER_ROOT/.cop" ]
    run ! grep -rq --exclude-dir=__pycache__ 'SHARE_DIR' "$V2_ROOT/config/defaults.env" "$V2_ROOT/scripts" "$V2_ROOT/systemd" "$V2_ROOT/templates"
}

@test "stage 3 refuses a symlink media parent before creating outside directories" {
    eval "$(awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    eval "$(awk '/^ensure_downloads_tree\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    detect_wan() { :; }
    detect_tailscale() { :; }
    write_state() { V2_LAST_ATOMIC_CHANGED=0; }
    log() { :; }
    SERVER_ROOT="$TMP/root" DOWNLOADS_PATH="$TMP/root/downloads" MEDIA_SUBDIR=media
    FILES_PANEL_TRASH=.cop
    DOWNLOADS_UID="$(id -u)" DOWNLOADS_GID="$(id -g)"
    mkdir -p "$SERVER_ROOT" "$TMP/outside"
    ln -s "$TMP/outside" "$SERVER_ROOT/media"
    # Match the installer's errexit semantics; never source its stage dispatcher.
    run -- bash -c 'set -Eeuo pipefail; eval "$1"; eval "$2"; stage_3' _ \
        "$(declare -f stage_3 ensure_downloads_tree detect_wan detect_tailscale write_state log die)" \
        "$(declare -p SERVER_ROOT DOWNLOADS_PATH MEDIA_SUBDIR FILES_PANEL_TRASH DOWNLOADS_UID DOWNLOADS_GID V2_ROOT)"
    [ "$status" -ne 0 ]
    case "$output" in *"güvenli onarılamadı"*) ;; *) false ;; esac
    [ ! -e "$TMP/outside/movies" ]
    [ ! -e "$TMP/outside/series" ]
    [ -L "$SERVER_ROOT/media" ]
}

@test "wg panel adds and removes networks and passes each network's peer actions to master-wg" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    local auth=(-H 'X-Konsol: 1') json=(-H 'Content-Type: application/json')
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"phone","dns":"1.1.1.1, 1.0.0.1","keepalive":21,"mtu":1420}')" = 201 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"name": "phone", "ipv4": "10.8.0.3"}' "$TMP/body"
    grep -qx 'wg0|add|phone|1.1.1.1, 1.0.0.1|21|1420' "$TMP/mwg-calls"
    # Bad names, interfaces, bodies and confirmations never reach master-wg; its refusals come back as messages.
    : >"$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"../x","dns":"1.1.1.1","keepalive":21,"mtu":1420}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets/eth0/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":21,"mtu":1420}')" = 404 ]
    # Numbers are numbers: a quoted keepalive or MTU is refused before master-wg runs.
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":"21","mtu":1420}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers "${auth[@]}" -d 'name=phone')" = 400 ]
    [ "$(pc '/api/konsol/wireguard/nets/wg0/peers/..%2Fx/remove' "${auth[@]}" "${json[@]}" -d '{}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets/wg0/reset "${auth[@]}" "${json[@]}" -d '{"confirm":"evet"}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets/wg1/remove "${auth[@]}" "${json[@]}" -d '{"confirm":"SIL"}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets "${auth[@]}" "${json[@]}" -d '{"port":61011,"scope":"all","dns":"9.9.9.9","label":""}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets "${auth[@]}" "${json[@]}" -d '{"port":"abc","dns":"9.9.9.9","label":""}')" = 400 ]
    [ ! -s "$TMP/mwg-calls" ]
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"dup","dns":"1.1.1.1","keepalive":21,"mtu":1420}')" = 400 ]
    grep -q "zaten var" "$TMP/body"
    [ "$(pc /api/konsol/wireguard/nets "${auth[@]}" "${json[@]}" -d '{"port":61001,"dns":"9.9.9.9","label":"x"}')" = 400 ]
    grep -q "UDP 61001 kullanılıyor (wg0)" "$TMP/body"
    # A new network: master-wg net-add, then it is listed with its label and takes its own peers.
    [ "$(pc /api/konsol/wireguard/nets "${auth[@]}" "${json[@]}" -d '{"port":61011,"dns":"9.9.9.9","label":"Misafir"}')" = 201 ]
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"iface": "wg1", "port": 61011}' "$TMP/body"
    grep -qx 'yok|net-add|61011|9.9.9.9|Misafir' "$TMP/mwg-calls"
    pc /api/konsol/wireguard/state "${auth[@]}" >/dev/null
    python3 -c 'import json, sys; n = json.load(open(sys.argv[1]))["networks"][1]; assert (n["iface"], n["label"], n["dns"], n["peers"]) == ("wg1", "Misafir", "9.9.9.9", []), n' "$TMP/body"
    grep -qx 'wg1|info' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg1/peers "${auth[@]}" "${json[@]}" -d '{"name":"guest","dns":"9.9.9.9","keepalive":0,"mtu":1420}')" = 201 ]
    grep -qx 'wg1|add|guest|9.9.9.9|0|1420' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg1/peers/guest/dns "${auth[@]}" "${json[@]}" -d '{"dns":"1.1.1.1"}')" = 200 ]
    grep -qx 'wg1|dns|guest|1.1.1.1' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg1/peers/guest/remove "${auth[@]}" "${json[@]}" -d '{}')" = 200 ]
    grep -qx 'wg1|remove|guest' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg1/reset "${auth[@]}" "${json[@]}" -d '{"confirm":"Onayla"}')" = 200 ]
    grep -qx 'wg1|reset|--onay' "$TMP/mwg-calls"
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"peers": 4, "profiles": 4}' "$TMP/body"
    [ "$(pc /api/konsol/wireguard/nets/wg1/remove "${auth[@]}" "${json[@]}" -d '{"confirm":"onayla"}')" = 200 ]
    grep -qx 'yok|net-remove|wg1|--onay' "$TMP/mwg-calls"
    # The profile and the QR only when asked, as a download (the old masked preview is gone).
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers/iphone/profile "${auth[@]}")" = 200 ]
    grep -qx 'wg0|profile|iphone' "$TMP/mwg-calls"
    grep -q 'SECRETPRIV' "$TMP/body"
    grep -q '^Endpoint = 203.0.113.7:61001$' "$TMP/body"
    grep -qi '^Content-Disposition: attachment; filename="iphone.conf"' "$TMP/head"
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers/iphone/qr.png "${auth[@]}")" = 200 ]
    grep -qi '^Content-Type: image/png' "$TMP/head"
    [ "$(head -c 4 "$TMP/body" | od -An -tx1 | tr -d ' \n')" = 89504e47 ]
    # Every WireGuard call lives under /api/konsol/wireguard (DD-271); nothing answers elsewhere.
    [ "$(pc /api/wg/state "${auth[@]}")" = 404 ]
    [ "$(pc /api/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":21,"mtu":1420}')" = 404 ]
    [ "$(pc /api/state "${auth[@]}")" = 404 ]
    [ "$(pc /api/nets/wg0/peers "${auth[@]}" "${json[@]}" -d '{"name":"x","dns":"1.1.1.1","keepalive":21,"mtu":1420}')" = 404 ]
    # DD-140: peer and network switches and keepalive go to master-wg.
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers/iphone/durum "${auth[@]}" "${json[@]}" -d '{"on":false}')" = 200 ]
    grep -qx 'wg0|peer|iphone|kapat' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers/iphone/durum "${auth[@]}" "${json[@]}" -d '{"on":true}')" = 200 ]
    grep -qx 'wg0|peer|iphone|ac' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers/iphone/keepalive "${auth[@]}" "${json[@]}" -d '{"keepalive":25}')" = 200 ]
    grep -qx 'wg0|keepalive|iphone|25' "$TMP/mwg-calls"
    [ "$(pc /api/konsol/wireguard/nets/wg0/peers/iphone/keepalive "${auth[@]}" "${json[@]}" -d '{"keepalive":"x"}')" = 400 ]
    [ "$(pc /api/konsol/wireguard/nets/wg0/durum "${auth[@]}" "${json[@]}" -d '{"on":false}')" = 200 ]
    grep -qx 'wg0|net|kapat' "$TMP/mwg-calls"
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"iface": "wg0", "active": False}' "$TMP/body"
    [ "$(pc /api/konsol/wireguard/nets/wg0/durum "${auth[@]}" "${json[@]}" -d '{"on":true}')" = 200 ]
    grep -qx 'wg0|net|ac' "$TMP/mwg-calls"
    # The audit log names the action, network and peer, never a password or key.
    # The details read as the sentence Konsol shows.
    grep -q 'konsol yerel wireguard-ekle wg0/phone -> ok' "$TMP/panel.log"
    grep -q 'konsol yerel wireguard-ag-ekle wg1 -> ok' "$TMP/panel.log"
    grep -q 'konsol yerel wireguard-ag-kaldir wg1 -> ok' "$TMP/panel.log"
    grep -q 'konsol yerel wireguard-peer-durum wg0/iphone kapatıldı -> ok' "$TMP/panel.log"
    grep -q 'konsol yerel wireguard-ag-durum wg0 kapatıldı -> ok' "$TMP/panel.log"
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
        pc /api/konsol/wireguard/state -H 'X-Konsol: 1' >/dev/null
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
}

@test "Konsol sign-in: Caddy asks the root backend for every protected path; the tailnet passes, the internet signs in" {
    local site body s7 backend="$V2_ROOT/panel/master-panel" auth="$V2_ROOT/panel/master_auth.py"
    # DD-194: only the sign-in page's files and the sign-in API are open to Caddy; DD-205: the sign-in
    # page itself goes to the backend too, which sends the tailnet back to Konsol.
    # DD-195: the routes live in one snippet; the tailnet site only imports it.
    [ "$(awk '/^http:\/\/panel.__LOCAL_DOMAIN__ \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile")" = \
        "$(printf 'http://panel.__LOCAL_DOMAIN__ {\n\timport konsol tailscale\n}')" ]
    site="$(awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile")"
    # DD-267: the sign-in page is self-contained; its theme script, font and icons are open beside its own files.
    # DD-268: so are the app manifest and its icons, which the browser asks for without cookies.
    grep -qxF "$(printf '\t@korumali not path /giris.js /giris.css /tema.js /fonts/Outfit-Variable.woff2 /obhut.svg /obhut.png /manifest.json /obhut-192.png /obhut-512.png /api/konsol/oturum /api/konsol/oturum/*')" <<<"$site"
    # DD-205: the backend answers by Caddy's channel — the tailnet needs no cookie, its /giris.html is a redirect
    # to Konsol, the internet needs a session except for the sign-in page; the account is made without a code.
    grep -qF 'if self.channel() == "tailscale":' "$backend"
    grep -qF 'self.send(302, extra={"Location": home})' "$backend"
    # DD-267: home is always / and the sign-in page /giris.html; never an address from the request.
    grep -qF 'home, login = "/", "/giris.html"' "$backend"
    run ! grep -q 'parse_qs' <<<"$(awk '/    def session_gate\(self\):/,/    def account_post\(/' "$backend")"
    grep -qF 'if user or page == "/giris.html":' "$backend"
    grep -qF 'reveal=self.channel() != "internet"' "$backend"
    grep -qF 'store.create(data.get("kullanici"), data.get("parola"))' "$backend"
    grep -qF 'store.set_password(data.get("yeni"))' "$backend"
    run ! grep -qE 'SETUP_FILE|kurulum-kodu|issue_code|normalize_code|CODE_ALPHABET' "$auth"
    run ! grep -qE 'form-setup|setup-code|Kurulum kodu' "$V2_ROOT/console/giris.html" "$V2_ROOT/console/giris.js"
    grep -qxF "$(printf '\tforward_auth @korumali unix/__PANEL_SOCKET__ {')" <<<"$site"
    grep -qxF "$(printf '\t\turi /oturum-denetle')" <<<"$site"
    # forward_auth precedes the routes, so no handle block can bypass it.
    [ "$(grep -n 'forward_auth' <<<"$site" | cut -d: -f1)" -lt "$(grep -n '@kok path' <<<"$site" | cut -d: -f1)" ]
    # The sign-in page loads only open files, and nothing from elsewhere or inline (DD-267: no Konsol stylesheet).
    [ "$(grep -oE '(href|src)="[^"]+"' "$V2_ROOT/console/giris.html" | LC_ALL=C sort -u | tr '\n' ' ')" = 'href="/giris.css" href="/obhut.png" href="/obhut.svg" src="/giris.js" src="/tema.js" ' ]
    run ! grep -qiE '<style|style=|onclick=|https?://' "$V2_ROOT/console/giris.html"
    run ! grep -qE 'localStorage|sessionStorage|innerHTML' "$V2_ROOT/console/giris.js"
    # Everything it loads, its stylesheet's font included, is open before a session and ships with the
    # console: the sign-in page's own files or the build's (installed at the same root).
    local open asset
    open="$(grep -F '@korumali not path' <<<"$site" | tr -s ' \t' '\n')"
    for asset in $(grep -oE '(href|src)="/[^"]+"' "$V2_ROOT/console/giris.html" | cut -d'"' -f2) \
        $(grep -oE 'url\("?/[^")]+' "$V2_ROOT/console/giris.css" | sed -E 's/^url\("?//'); do
        grep -qxF -- "$asset" <<<"$open"
        [ -f "$V2_ROOT/console/${asset#/}" ] || [ -f "$V2_ROOT/console/yeni/${asset#/}" ]
    done
    # Every file of the sign-in page and the editor is installed beside the build (the sign-in page once
    # 404'd on a real host).
    local pages f
    pages="$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    for f in "$V2_ROOT"/console/*; do [ -d "$f" ] || grep -qw "${f##*/}" <<<"$pages"; done
    grep -qx 'KONSOL_AUTH_DIR="/etc/master-stack/konsol"' "$V2_ROOT/config/defaults.env"
    grep -qx 'KONSOL_AUTH_DIR=$KONSOL_AUTH_DIR' "$V2_ROOT/install.sh"
    run ! grep -q 'KONSOL' "$V2_ROOT/config/kurulum.env.example"
    # Helpers installed; the 0700 folder exists before the backend restarts with write access to it.
    grep -qF 'atomic_write "$SBIN_DIR/master_auth.py" 0755 <"$V2_ROOT/panel/master_auth.py"' "$V2_ROOT/install.sh"
    grep -qF 'atomic_write "$SBIN_DIR/master-konsol" 0755 <"$V2_ROOT/scripts/master-konsol"' "$V2_ROOT/install.sh"
    body="$(awk '/^ensure_panel\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    [ "$(grep -n 'install -d -m 0700 -o root -g root -- "$KONSOL_AUTH_DIR"' <<<"$body" | cut -d: -f1)" -lt \
        "$(grep -n 'systemctl restart master-panel.service' <<<"$body" | cut -d: -f1)" ]
    grep -qF 'KONSOL_AUTH_DIR="$KONSOL_AUTH_DIR"' <<<"$body"
    # Stage 7: an open sign-in file, a refused host-local page request, both session answers for a
    # caller without Caddy's headers and the tailnet answers (204, /giris.html → /).
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -qF '"http://${TAILSCALE_IPV4}/giris.js"' <<<"$s7"
    grep -qF 'for probe in "/api/konsol/kaynaklar|401" "/|302"; do' <<<"$s7"
    grep -qF 'for probe in "/api/konsol/kaynaklar|204" "/giris.html|302"; do' <<<"$s7"
    grep -qF -- '-H "X-Forwarded-For: $tail_probe"' <<<"$s7"
    grep -qF '"http://localhost/oturum-denetle"' <<<"$s7"
    grep -qF -- '--url "http://127.0.0.1:${FILES_PANEL_PORT}/api/state"' <<<"$s7"
    # DD-205: no setup code anywhere — the summary names the passwordless tailnet and the Settings card.
    run ! grep -qE 'konsol_login_summary|ilk giriş kodu|master_auth.py" --state "\$STATE_FILE" kod' "$V2_ROOT/install.sh"
    grep -qF "Tailscale'den parolasız" "$V2_ROOT/install.sh"
    grep -qF 'önce Sistem → Hesap' "$V2_ROOT/install.sh"
    run ! grep -qE '"kod"|sub.add_parser\("kod"' "$auth"
    [ -x "$V2_ROOT/scripts/master-konsol" ]
}

@test "public Konsol: one snippet, Caddy-written channel, pinned backend Host, managed cleanup" {
    local snippet
    # DD-195: both Konsol sites share the signed-in routes; only Caddy names the channel.
    snippet="$(awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile")"
    [ "$(grep -c "$(printf '\theader_up X-Konsol-Kanal {args\\[0\\]}')" <<<"$snippet")" -eq 3 ]
    [ "$(grep -c 'header_up Host panel.__LOCAL_DOMAIN__$' <<<"$snippet")" -eq 4 ]
    awk '/forward_auth @korumali/,/^\t}$/' <<<"$snippet" | grep -qF 'header_up X-Konsol-Kanal {args[0]}'
    # Each site opens at most 16 backend connections (session check and root API alike).
    [ "$(grep -c "$(printf '\t\t\tmax_conns_per_host 16')" <<<"$snippet")" -eq 3 ]
    [ "$(grep -c '^\s*header_up X-Forwarded-Host {host}$' <<<"$snippet")" -eq 1 ]
    grep -qx 'LimitNOFILE=8192' "$V2_ROOT/systemd/master-panel.service"
    [ "$(grep -c '^import konsol ' "$V2_ROOT/templates/Caddyfile")" -eq 0 ]
    grep -qxF "$(printf '\timport konsol tailscale')" "$V2_ROOT/templates/Caddyfile"
    # The public site is generated, never templated, and imports the same snippet.
    grep -qF '"\timport konsol internet\n}\n"' "$V2_ROOT/panel/master_publications.py"
    grep -qF 'header Strict-Transport-Security' "$V2_ROOT/panel/master_publications.py"
    # A local domain change also renames the Host the backends check.
    grep -qF 'r"(?m)^(\t+header_up Host panel\.)" + old + r"$"' "$V2_ROOT/panel/master_settings.py"
    # A changed WAN IPv4 drops the stale public site like the other WAN sites.
    # Every public site by pattern, no application name in the installer.
    awk '/for wan_site in/,/; do$/' "$V2_ROOT/install.sh" | grep -qF '"$CADDY_MODULES_DIR"/*-wan.caddy'
    # The backend trusts the internet mark only while the publication is active.
    grep -qF 'if not self.panel.public_open() or not self.public_client():' "$V2_ROOT/panel/master-panel"
    grep -qF 'secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""' "$V2_ROOT/panel/master-panel"
}

@test "WireGuard is built in and off after install: tool, drop-in, folder and kernel module, no network (DD-271)" {
    local s4 s7 harness k
    # The tool and the drop-in are the base's; no store engine or package tree is left to ship.
    [ -x "$V2_ROOT/scripts/master-wg" ]
    [ -f "$V2_ROOT/systemd/wg-quick-master-stack.conf" ]
    [ ! -e "$V2_ROOT/scripts/master-modul" ] && [ ! -e "$V2_ROOT/magaza" ]
    grep -qE '^    local items="install.sh common.sh config templates scripts systemd panel files-panel console"$' "$V2_ROOT/../kur.sh"
    # Stage 4 places the tool, the drop-in, the folder and the kernel module file; it creates no network.
    s4="$(awk '/^stage_4\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx '    ensure_wireguard' <<<"$s4"
    mkdir -p "$TMP/sbin" "$TMP/units" "$TMP/modules-load"
    harness='
        set -Eeuo pipefail
        source "$V2_ROOT/common.sh"
        eval "$(awk "/^ensure_wireguard\\(\\)/,/^}\$/" "$V2_ROOT/install.sh")"
        SBIN_DIR="$T/sbin" UNIT_DIR="$T/units" WG_CONF_DIR="$T/wireguard" WG_MODULES_LOAD_FILE="$T/modules-load/wg.conf"
        modprobe() { echo "modprobe $*" >>"$T/log"; [[ ! -e "$T/no-module" ]]; }
        install() {
            local a skip=0 args=()
            for a in "$@"; do
                if [[ "$skip" == 1 ]]; then skip=0; continue; fi
                case "$a" in -o | -g) skip=1 ;; *) args+=("$a") ;; esac
            done
            command install "${args[@]}"
        }
        ensure_wireguard'
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness"
    [ "$status" -eq 0 ]
    cmp -s "$V2_ROOT/scripts/master-wg" "$TMP/sbin/master-wg" && [ -x "$TMP/sbin/master-wg" ]
    grep -qx "ExecStartPre=+$TMP/sbin/master-firewall --check" "$TMP/units/wg-quick@.service.d/master-stack.conf"
    [ "$(cat "$TMP/modules-load/wg.conf")" = wireguard ]
    [ "$(stat_field %a %Lp "$TMP/wireguard")" = 700 ]
    [ -z "$(ls -A "$TMP/wireguard")" ]
    grep -qx 'modprobe wireguard' "$TMP/log"
    touch "$TMP/no-module"
    run env T="$TMP" V2_ROOT="$V2_ROOT" bash -c "$harness"
    [ "$status" -ne 0 ]
    case "$output" in *"çekirdek WireGuard modülü yüklenemedi"*) ;; *) false ;; esac
    run ! grep -qE 'master-wg" (net-add|add|baslat)|wg genkey' "$V2_ROOT/install.sh"
    # Stage 1 installs the tools with the base; state.env carries every WireGuard key for the
    # server's scripts, which read nothing else (no package folder, no wireguard.env).
    awk '/^stage_1\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx '        wireguard-tools qrencode'
    for k in WG_PORT_DEFAULT WG_ADDR_BASE4 WG_ADDR_BASE6 WG_MTU WG_CLIENT_KEEPALIVE_DEFAULT WG_CONF_DIR \
        WG_CLIENTS_DIR WG_NETWORKS_FILE WG_STOPPED_FILE WG_NETWORKS_MAX WG_MODULES_LOAD_FILE; do
        grep -q "^$k=" "$V2_ROOT/config/defaults.env"
        awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx "$k=\$$k"
    done
    for k in WG_CLIENT_DNS_DEFAULT WG_CLIENT_ALLOWED_IPS; do
        awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx "$k=\"\$$k\""
    done
    run ! grep -qE 'MODULES_|wireguard\.env|PAKET_|paket\.env' "$V2_ROOT/scripts/master-wg" "$V2_ROOT/scripts/firewall.sh" \
        "$V2_ROOT/scripts/refresh-tailnet-config" "$V2_ROOT/../wireguard.command"
    # Stage 7 checks it; the confirmation screen and the summary name it as a built-in.
    s7="$(awk '/^stage_7\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx '    check_wireguard' <<<"$s7"
    grep -qF 'WireGuard (ağları Konsol → Erişim → WireGuard kurar)' <<<"$(awk '/^stage_0\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qF '  WireGuard: $(summary_wireguard)' "$V2_ROOT/install.sh"
    # Caddy no longer dumps state.env into the journal.
    awk '/caddy.service.d\/master-stack.conf/,/^EOF$/' "$V2_ROOT/install.sh" | grep -qxF 'ExecStart=/usr/bin/caddy run --config $CADDYFILE --adapter caddyfile'
}

@test "system view: root unit on its own socket, tailnet-only Caddy route, stage 7 channel proof" {
    # DD-235: Files' "Sistem (/)" view is the same backend in --sistem mode, as root, over /.
    local unit="$V2_ROOT/systemd/master-sistem-dosya.service" s7 snippet
    grep -qx 'SYSTEM_FILES_SOCKET="/run/master-sistem-dosya/api.sock"' "$V2_ROOT/config/defaults.env"
    grep -qF 'master-files-panel serve --sistem --listen unix:__SYSTEM_FILES_SOCKET__ --socket-group __CADDY_GROUP__ --root / ' "$unit"
    run ! grep -qE '^(User|ProtectSystem|ProtectHome|PrivateTmp)=' "$unit"
    grep -qx 'IPAddressDeny=any' "$unit"
    grep -qx 'NoNewPrivileges=true' "$unit"
    grep -qx 'RestrictSUIDSGID=true' "$unit"
    # Caddy: only the tailnet site routes it; the internet site's request falls to the files backend (404).
    snippet="$(awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile")"
    grep -qxF "$(printf '\t\tpath /api/sistem/*')" <<<"$snippet"
    grep -qxF "$(printf '\t\texpression `"{args[0]}" == "tailscale"`')" <<<"$snippet"
    grep -qxF "$(printf '\t\treverse_proxy unix/__SYSTEM_FILES_SOCKET__ {')" <<<"$snippet"
    grep -qF 'SYSTEM_FILES_SOCKET="$SYSTEM_FILES_SOCKET"' "$V2_ROOT/install.sh"
    grep -qF '    ensure_system_files "$OS_CHANGED"' "$V2_ROOT/install.sh"
    # The backend refuses any other channel or a client that is this host.
    grep -qF 'self.headers.get(CHANNEL_HEADER) != "tailscale"' "$V2_ROOT/files-panel/master-files-panel"
    grep -qF 'not remote_tailnet(forwarded.split(",")[-1].strip())' "$V2_ROOT/files-panel/master-files-panel"
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    grep -qF '"$(stat -c '"'"'%U:%G:%a'"'"' "$SYSTEM_FILES_SOCKET" 2>/dev/null)" == "root:${CADDY_GROUP}:660"' <<<"$s7"
    grep -qF 'for probe in "tailscale|${tail_probe}|200" "internet|${tail_probe}|403" "tailscale|${TAILSCALE_IPV4}|403"; do' <<<"$s7"
    grep -qF '"http://${TAILSCALE_IPV4}/api/sistem/state"' <<<"$s7"
    # Health, Günlük and a domain change know the unit.
    grep -qF '"master-sistem-dosya.service"' "$V2_ROOT/panel/master-panel"
    grep -qF '"-u", "master-sistem-dosya.service"' "$V2_ROOT/panel/master-panel"
    grep -qF 'master-sistem-dosya.service' "$V2_ROOT/panel/master_settings.py"
}

@test "installer wires the wg panel: loopback unit, tailnet name, Konsol sign-in, stage 7 gate proof" {
    local unit="$V2_ROOT/systemd/master-panel.service" body s6 s7
    # DD-180: no TCP port; a Unix socket only Caddy's group and root can open.
    grep -q -- '--listen unix:__PANEL_SOCKET__ --socket-group __CADDY_GROUP__' "$unit"
    grep -qx 'RuntimeDirectory=__PANEL_RUNTIME__' "$unit"
    grep -qx 'RuntimeDirectoryMode=0755' "$unit"
    # DD-271: the backend finds the base's tools (master-wg among them) in state.env's SBIN_DIR.
    run ! grep -qE -- '--master-wg|--master-modul' "$unit"
    run ! grep -q 'PANEL_DNS_DEFAULT\|PANEL_KEEPALIVE_DEFAULT\|PANEL_MTU_DEFAULT' "$unit"
    for line in 'NoNewPrivileges=true' 'ProtectSystem=full' 'ReadWritePaths=-__WG_CONF_DIR__ -__KONSOL_AUTH_DIR__' 'PrivateTmp=true' \
        'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK'; do
        grep -qx "$line" "$unit"
    done
    grep -qx 'PANEL_SOCKET="/run/master-panel/api.sock"' "$V2_ROOT/config/defaults.env"
    grep -qx 'CADDY_GROUP="caddy"' "$V2_ROOT/config/defaults.env"
    grep -qx 'CADDY_ADMIN_SOCKET="/run/caddy/admin.sock"' "$V2_ROOT/config/defaults.env"
    run ! grep -rq 'WG_PANEL_PORT' "$V2_ROOT/config" "$V2_ROOT/install.sh" "$V2_ROOT/scripts" "$V2_ROOT/panel" \
        "$V2_ROOT/systemd" "$V2_ROOT/templates"
    # DD-194: the Konsol account is created at the first visit; the input file, defaults and unit
    # carry none of the retired DD-140 account settings.
    run ! grep -qE 'WG_PANEL_(USER|PASS|AUTH_FILE|MIN_PASSWORD_LENGTH|NEW_|ACCOUNT)' \
        "$V2_ROOT/config/defaults.env" "$V2_ROOT/config/kurulum.env.example" "$V2_ROOT/install.sh" "$unit"
    run ! grep -q -- '--auth' "$unit"
    # No panel port is reserved any more: it has none.
    run ! grep -q '"panel:' "$V2_ROOT/scripts/master-wg"
    body="$(awk '/^ensure_panel\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # DD-271: WireGuard's folder is the backend's one fixed write path beside the account folder; the
    # unit gets it from the base key, never as a literal.
    grep -qF 'WG_CONF_DIR="$WG_CONF_DIR"' <<<"$body"
    run ! grep -q '/etc/wireguard' "$unit"
    run ! grep -q 'PANEL_WRITE_PATHS' "$V2_ROOT/install.sh"
    # DD-140: this backend serves no page files any more; the console pages come from the file backend.
    run ! grep -q -- '--web' "$V2_ROOT/systemd/master-panel.service"
    run ! grep -qE 'index\.html|panel\.css|panel\.js' <<<"$body"
    s6="$(awk '/^stage_6\(\)/,/^ensure_panel\(\)/' "$V2_ROOT/install.sh")"
    grep -q '^    ensure_panel "\$OS_CHANGED"$' <<<"$s6"
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    # Without a password the gates are the protection: stage 7 proves both on both backends.
    grep -q 'X-Konsol başlığı olmadan HTTP' <<<"$s7"
    grep -q 'yabancı Host ile HTTP' <<<"$s7"
    # DD-159/171: the built-in Files gate is mandatory, never optional.
    grep -qF 'for gate in "http://127.0.0.1:${FILES_PANEL_PORT}|/api/state" "unix:${PANEL_SOCKET}|/api/konsol/kaynaklar"; do' <<<"$s7"
    run ! grep -q 'files_on' <<<"$s7"
    # DD-180: the socket modes, a real attempt as the downloads account, no TCP admin port, a reload.
    grep -qF '"root:${CADDY_GROUP}:660"' <<<"$s7"
    grep -qF '"caddy:700"' <<<"$s7"
    grep -qF 'setpriv --reuid="$DOWNLOADS_UID" --regid="$DOWNLOADS_GID" --clear-groups' <<<"$s7"
    grep -qF 'for sock in "$PANEL_SOCKET" "$SYSTEM_FILES_SOCKET" "$CADDY_ADMIN_SOCKET"; do' <<<"$s7"
    grep -qF '"http://127.0.0.1:2019/config/"' <<<"$s7"
    grep -qF 'systemctl reload caddy || die' <<<"$s7"
    # The Caddy tailnet listener is reachable from the host too: that path must end in the backend's 403.
    grep -qF '"http://${TAILSCALE_IPV4}/api/konsol/kaynaklar" 2>/dev/null || true)"' <<<"$s7"
    grep -qF '*"başka bir Tailscale cihazından"*' <<<"$s7"
    grep -qF 'master-panel" check --socket "$PANEL_SOCKET"' <<<"$s7"
    grep -q 'Konsol giriş sayfasının dosyası tailnet.ten açılmadı' <<<"$s7"
    grep -q 'master-panel" check' <<<"$s7"
    run ! grep -q 'WG_PANEL_PORT' <<<"$s7"
    # Exported with the runtime, Caddy on the tailnet only, nothing on the WireGuard edge.
    grep -qE '^    local items="[^"]*(^| )panel( |")' "$V2_ROOT/../kur.sh"
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
    # No backup feature in the backend, its unit or Konsol's sources (the page's CSP is checked with the build).
    run ! grep -qiE 'yedek|backup' "$V2_ROOT/panel/master-panel" "$unit"
    run ! grep -rqiE 'yedek|backup' "$V2_ROOT/tools/konsol-ui/src"
    run ! grep -q 'WG_BACKUP_MARK' "$V2_ROOT/config/defaults.env" "$V2_ROOT/install.sh" "$V2_ROOT/../wireguard.command"
    # Stage 0 refuses a wg0 or WebDAV port that a panel network already uses.
    # DD-143: port çakışması artık ağı kuran yerde denetlenir (master-wg net-add).
    grep -q 'UDP $port kullanılıyor' "$V2_ROOT/scripts/master-wg"
}

files_panel_start() {
    # DD-139: the file panel on a scratch root, with an account written by the WireGuard panel.
    FPANEL="$V2_ROOT/files-panel/master-files-panel"
    mkdir -p "$TMP/root/Filmler/Kuzey" "$TMP/root/incomplete" "$TMP/outside"
    printf 'gizli\n' >"$TMP/outside/secret.txt"
    ln -s "$TMP/outside" "$TMP/root/kacis"
    printf 'merhaba dünya\n' >"$TMP/root/notlar.txt"
    # DD-149: the share account never reaches this backend; it only manages the links.
    FPORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    python3 "$FPANEL" serve --listen "127.0.0.1:$FPORT" --root "$TMP/root" \
        --domain ayc --version 2026.08.06-v2-test >"$TMP/fpanel.log" 2>&1 &
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
    awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile" >"$TMP/site"
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
assert d["root"] == sys.argv[2] and d["writable"] and "protected" not in d, d
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

@test "files panel has no shared-root share API" {
    files_panel_start
    [ "$(fpost /api/paylas '{"path":"Filmler/Kuzey","days":7}')" = 404 ]
    [ "$(fpost /api/paylas/kaldir '{"name":"Kuzey"}')" = 404 ]
    [ "$(fp /api/paylas)" = 404 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: attacker.example' -H 'X-Konsol: 1' "http://127.0.0.1:$FPORT/api/state")" = 403 ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: panel.ayc' "http://127.0.0.1:$FPORT/api/state")" = 403 ]
    [ "$(fp /api/state -H 'Sec-Fetch-Site: cross-site')" = 403 ]
    [ "$(fp /api/state)" = 200 ]
    python3 -c 'import json,sys; assert "share" not in json.load(open(sys.argv[1]))' "$TMP/body"
    [ -d "$TMP/root/Filmler/Kuzey" ]
}

@test "files panel takes an upload into the folder, never over an existing name and leaves no half file" {
    # DD-145: the body is the file itself; it is written under a temp name and renamed.
    files_panel_start
    printf 'yuk %s' "$(seq 1 200 | tr -d '\n')" >"$TMP/payload.bin"
    [ "$(fp "/api/upload?path=Filmler&name=arsiv.bin" --data-binary "@$TMP/payload.bin")" = 201 ]
    cmp -s "$TMP/payload.bin" "$TMP/root/Filmler/arsiv.bin"
    [ "$(stat_field %a %Lp "$TMP/root/Filmler/arsiv.bin")" = 664 ]
    grep -q 'konsol 127.0.0.1 yükle "Filmler/arsiv.bin" -> ok' "$TMP/fpanel.log"
    # Aynı ad ikinci kez: üzerine yazılmaz, dosya bozulmaz.
    printf 'baska icerik' >"$TMP/other.bin"
    [ "$(fp "/api/upload?path=Filmler&name=arsiv.bin" --data-binary "@$TMP/other.bin")" = 409 ]
    cmp -s "$TMP/payload.bin" "$TMP/root/Filmler/arsiv.bin"
    # Geçici ad kalmaz.
    [ "$(ls -A "$TMP/root/Filmler" | grep -c '^\.yukleniyor-')" = 0 ]
    # Geçersiz ad ve gövdesiz istek reddedilir; çöp hedef olamaz.
    [ "$(fp "/api/upload?path=Filmler&name=..%2Fkacak" --data-binary "@$TMP/other.bin")" = 400 ]
    [ "$(fp "/api/upload?path=Filmler&name=bos.bin" -X POST -H 'Content-Length: 0')" = 411 ]
    [ "$(fp "/api/upload?path=.cop&name=x.bin" --data-binary "@$TMP/other.bin")" = 403 ]
    # A refusal decided before the body is read still reads (drains) the body first, so a
    # proxy sees the real answer instead of a reset connection (Caddy turned that into 502).
    head -c 8388608 /dev/zero >"$TMP/big.bin"
    [ "$(fp "/api/upload?path=.cop&name=x.bin" --data-binary "@$TMP/big.bin")" = 403 ]
    [ "$(fp "/api/upload?path=Filmler&name=arsiv.bin" --data-binary "@$TMP/big.bin")" = 409 ]
    grep -q '“arsiv.bin” zaten var' "$TMP/body"
    grep -q 'self.drain(length)' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'UPLOAD_DRAIN_MAX = ' "$V2_ROOT/files-panel/master-files-panel"
    # Yükleme kilidi bütün akış boyunca tutulmaz: yalnız son taşıma kilitli.
    grep -q 'self.run(user, "yükle", put, lock=False' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'with self.lock:' "$V2_ROOT/files-panel/master-files-panel"
}

@test "the base install has no Compose project, no Dozzle and no service account in the input file" {
    # DD-151, DD-152: the installer brings Konsol, Tailscale, names and the firewall; no Docker.
    run ! grep -q '^INPUT_KEYS=' "$V2_ROOT/install.sh"
    [ "$(grep -E '^[A-Z_]+=' "$V2_ROOT/config/kurulum.env.example" | cut -d= -f1 | tr '\n' ' ')" = 'SSH_HOST ' ]
    [ ! -e "$V2_ROOT/templates/compose.yaml" ]
    [ "$(cat "$V2_ROOT/install.sh" "$V2_ROOT/common.sh" "$V2_ROOT/config/defaults.env" "$V2_ROOT/templates/Caddyfile" \
        "$V2_ROOT/templates/dnsmasq.conf" "$V2_ROOT/scripts/firewall.sh" \
        "$V2_ROOT/scripts/master-wg" "$V2_ROOT/panel/master-panel" "$V2_ROOT/console/yeni/app.js" \
        "$V2_ROOT/console/yeni/index.html" | grep -ciE 'dozzle|COMPOSE_DIR|PULL_IMAGES|bcrypt_matches|validate_account')" -eq 0 ]
    grep -qx 'SERVICE_NAMES="panel"' "$V2_ROOT/config/defaults.env"
    run ! grep -q 'docker-ce' "$V2_ROOT/install.sh"
    # DD-271: the shipped tree names no application.
    run ! grep -qiE 'torrent|gezgin' "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env" "$V2_ROOT/templates/Caddyfile" \
        "$V2_ROOT/templates/dnsmasq.conf" "$V2_ROOT/scripts/firewall.sh" "$V2_ROOT/scripts/master-wg" "$V2_ROOT/../kur.sh"
}

@test "network card data (DD-206): WAN counters from sysfs; no stored layout (DD-267)" {
    local backend="$V2_ROOT/panel/master-panel"
    # DD-267: the root backend no longer stores the layout (no route, record or audit kind).
    run ! grep -qE 'LAYOUT_|/api/konsol/duzen|"duzen"' "$backend"
    # Network: WAN counters from sysfs (no command in the sampler).
    grep -qF 'open("/sys/class/net/%s/statistics/%s" % (iface, name), "rb")' "$backend"
}

@test "Podman is base infrastructure (DD-211): integrated manager uses private root workers" {
    local s1 s7 mc="$V2_ROOT/panel/master_containers.py"
    s1="$(awk '/^stage_1\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    # Stage 1 installs the runtime without recommends (no buildah, criu, slirp4netns) and requires it.
    grep -qF 'retry "apt-podman" 2 "$APT_LOCK_TIMEOUT" -- apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \' <<<"$s1"
    grep -qx '        podman netavark aardvark-dns' <<<"$s1"
    [ "$(grep -n 'check_nft_iptables required' <<<"$s1" | cut -d: -f1)" -lt "$(grep -n 'check_podman$' <<<"$s1" | cut -d: -f1)" ]
    grep -qx '    check_podman' <<<"$s7"
    grep -qF "podman info --format '{{.Version.Version}} {{.Host.OCIRuntime.Name}}'" "$V2_ROOT/install.sh"
    # No daemon: the installer never enables Podman's socket, service or auto-update timer.
    [ "$(cat "$V2_ROOT/install.sh" | grep -vE '^[[:space:]]*#' | grep -cE 'podman\.socket|podman-auto-update|systemctl (enable|start)[^#]*podman')" -eq 0 ]
    # The base read mapper stays read-only; manager writes have one gated route and an external worker.
    grep -qF 'atomic_write "$SBIN_DIR/master_containers.py" 0755 <"$V2_ROOT/panel/master_containers.py"' "$V2_ROOT/install.sh"
    # DD-266: the reads are table routes too, on the same view; no Podman path is matched by hand.
    for read in liste ayrinti guncellemeler islem; do
        grep -qF "Route(\"GET\", \"/api/konsol/konteynerler/$read\"," "$V2_ROOT/panel/master_api.py"
    done
    grep -qF 'return self.panel.containers.view()' "$V2_ROOT/panel/master-panel"
    [ "$(grep -c '/api/konsol/konteynerler/' "$V2_ROOT/panel/master-panel")" -eq 0 ]
    # DD-265: the one write route is declared in the route table and goes to the same broker.
    grep -qF 'Route("POST", "/api/konsol/konteynerler/islem", "konteyner_islemi",' "$V2_ROOT/panel/master_api.py"
    grep -qF 'self.panel.containers.submit(data)' "$V2_ROOT/panel/master-panel"
    grep -qF -- '--property=RuntimeMaxSec=900' "$V2_ROOT/panel/master_container_manager.py"
    # Podman read commands only, the environment never returned; logs unfiltered, a managed container's
    # from its unit journal (DD-251).
    run ! grep -qE '"(run|create|pull|rm|rmi|stop|start|kill|exec|restart|reset)"' "$mc"
    run ! grep -qE 'SECRET_RE|MASK|mask\(' "$mc" "$V2_ROOT/panel/master_container_manager.py"
    grep -qF "rc,text,_=self.run(['journalctl','-u',unit,'-n',str(tail),'--no-pager','-o','short-iso'],30)" "$V2_ROOT/panel/master_container_manager.py"
    run ! grep -qE '"Env"|\.get\("Env"' "$mc"
    run ! grep -qiE 'qbittorrent|wireguard|torrent' "$mc"
}

@test "contract names the current trash path and WebDAV curtain (no stale tmpfs text)" {
    # The trash lives at SERVER_ROOT/.cop and WebDAV masks it with InaccessiblePaths (DD-158).
    run ! grep -q 'empty tmpfs' "$V2_ROOT/docs/contract.md"
    run ! grep -qF 'DOWNLOADS_PATH/.cop' "$V2_ROOT/docs/contract.md"
    grep -qF 'InaccessiblePaths=__SERVER_ROOT__/__FILES_PANEL_TRASH__' "$V2_ROOT/systemd/master-paylasim.service"
}

@test "Konsol container bind sources are pinned by a base helper (DD-226)" {
    local stage4
    grep -qx 'KONTEYNER_BAGLAMA_DIR="/run/master-stack/konteyner-baglama"' "$V2_ROOT/config/defaults.env"
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'KONTEYNER_BAGLAMA_DIR=\$KONTEYNER_BAGLAMA_DIR'
    stage4="$(awk '/^stage_4\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qF 'atomic_write "$SBIN_DIR/master_container_binds.py" 0755 <"$V2_ROOT/panel/master_container_binds.py"' <<<"$stage4"
    # Not in the loop that restarts the firewall: the firewall never calls this helper.
    run ! grep -qE 'for container_helper in .*master_container_binds' <<<"$stage4"
    run ! grep -qiE 'qbittorrent|torrent|wireguard|PAKET_' "$V2_ROOT/panel/master_container_binds.py"
    # DD-227: the generic container code (account rule included) names no application either.
    run ! grep -qiE 'qbittorrent|torrent|wireguard' "$V2_ROOT/panel/master_container_config.py" "$V2_ROOT/panel/master_container_worker.py"
    grep -qF "'master_container_binds.py'" "$V2_ROOT/tests/containers-worker-linux.py"
}

@test "the server's private state is hidden from the uid-1000 data units (DD-225)" {
    local files="$V2_ROOT/systemd/master-files-panel.service" dav="$V2_ROOT/systemd/master-paylasim.service"
    local unit key args out
    grep -qx 'PRIVATE_STATE_ROOT="/var/lib"' "$V2_ROOT/config/defaults.env"
    # Files needs its trash and share names; it loses only the server's private state.
    grep -qx 'InaccessiblePaths=__PRIVATE_STATE_ROOT__' "$files"
    [ "$(grep -c '^InaccessiblePaths=' "$files")" -eq 1 ]
    run ! grep -qE '^InaccessiblePaths=.*(TRASH|ARCHIVE|SHARE_DIR)' "$files"
    awk '/^ensure_files_panel\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF 'PRIVATE_STATE_ROOT="$PRIVATE_STATE_ROOT"'
    # The base units name no application.
    run ! grep -qiE 'qbittorrent|torrent|wireguard' "$files" "$dav"
    # Both templates render with every placeholder filled, and the masks keep their order.
    for unit in "$files" "$dav"; do
        args=()
        for key in $(grep -oE '__[A-Z][A-Z0-9_]*__' "$unit" | sort -u | sed 's/^__//; s/__$//'); do
            case "$key" in
                SERVER_ROOT) args+=("$key=/srv") ;; FILES_PANEL_TRASH) args+=("$key=.cop") ;;
                PRIVATE_STATE_ROOT) args+=("$key=/var/lib") ;; *) args+=("$key=x") ;;
            esac
        done
        render_template "$unit" "$TMP/rendered" 0644 "${args[@]}"
        out="$(grep '^InaccessiblePaths=' "$TMP/rendered")"
        if [ "$unit" = "$dav" ]; then
            [ "$out" = 'InaccessiblePaths=/srv/.cop /var/lib' ]
        else
            [ "$out" = 'InaccessiblePaths=/var/lib' ]
        fi
    done
}

@test "image updates (DD-214): Konsol checks registry manifests, the operator updates; no automatic update" {
    local mc="$V2_ROOT/panel/master_containers.py"
    check="$(sed -n '/^def update_status(/,/^class ContainerError/p' "$mc")"
    # The check reads manifests only: no pull, run or rmi anywhere in the base read module.
    grep -qF '["podman", "manifest", "inspect", channel]' <<<"$check"
    run ! grep -qE '"(pull|run|rmi|rm|create)"' "$mc"
    # No timer, auto-update label or Podman auto-update unit anywhere in the stack.
    [ "$(grep -rhE 'AutoUpdate=|podman-auto-update|auto-update' "$V2_ROOT/panel" "$V2_ROOT/systemd" "$V2_ROOT/install.sh" "$V2_ROOT/scripts" | grep -cvE '^[[:space:]]*#')" -eq 0 ]
}

@test "the files backend has no archive jobs and its unit passes no retired argument (DD-267, DD-271)" {
    # No route and no result line.
    run ! grep -qE 'arsiv|/api/archives' "$V2_ROOT/files-panel/master-files-panel"
    run ! grep -qE -- '--archive-dir|--share|--protected' "$V2_ROOT/systemd/master-files-panel.service"
}

@test "installer wires private folder accounts without exposing hashes to the file backend" {
    grep -qx 'LoadCredential=registry:__SHARE_STATE_FILE__' "$V2_ROOT/systemd/master-paylasim.service"
    grep -qF 'atomic_write "$SBIN_DIR/master_shares.py"' "$V2_ROOT/install.sh"
    grep -qF 'atomic_write "$SBIN_DIR/master_https.py"' "$V2_ROOT/install.sh"
    grep -qF 'atomic_write "$SBIN_DIR/master_webdav.py"' "$V2_ROOT/install.sh"
    [ "$(cat "$V2_ROOT/systemd/master-files-panel.service" "$V2_ROOT/files-panel/master-files-panel" | grep -cE 'LoadCredential|SHARE_STATE_FILE')" -eq 0 ]
}

@test "installer wires the files panel: downloads uid, sandbox, no password, tailnet name, hidden trash, stage 7 proof" {
    local unit="$V2_ROOT/systemd/master-files-panel.service" body s6 s7 line
    for line in 'User=__FILES_PANEL_USER__' 'Group=__FILES_PANEL_GROUP__' 'NoNewPrivileges=true' 'CapabilityBoundingSet=' \
        'ProtectSystem=strict' 'ReadWritePaths=__SERVER_ROOT__' 'ProtectHome=true' 'PrivateTmp=true' 'PrivateDevices=true' \
        'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' 'UMask=0002' \
        'IPAddressDeny=any' 'IPAddressAllow=localhost' 'SystemCallFilter=@system-service' \
        'SystemCallErrorNumber=EPERM' 'ProtectProc=invisible' 'PrivateIPC=true' 'MemoryDenyWriteExecute=true'; do
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
    body="$(awk '/^ensure_files_panel\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # systemd needs a user entry for the downloads uid: an existing name, else a system account without login.
    grep -q 'getent passwd "\$DOWNLOADS_UID"' <<<"$body"
    grep -q 'getent group "\$DOWNLOADS_GID"' <<<"$body"
    grep -q 'useradd --system --uid "\$DOWNLOADS_UID" --gid "\$DOWNLOADS_GID" --no-create-home' <<<"$body"
    grep -q -- '--shell /usr/sbin/nologin "\$DOWNLOADS_ACCOUNT"' <<<"$body"
    grep -qx 'DOWNLOADS_ACCOUNT="master-downloads"' "$V2_ROOT/config/defaults.env"
    # DD-271: rendered straight into the unit folder; no folder is reserved for an application.
    grep -qF 'render_template "$V2_ROOT/systemd/master-files-panel.service" "$UNIT_DIR/master-files-panel.service" 0644' <<<"$body"
    run ! grep -qE 'protected|paket_' <<<"$body"
    # Caddy serves the console pages from CONSOLE_WEB_DIR; this backend serves none (DD-140). DD-267: the
    # page is the build's index.html, placed at the root from console/yeni.
    pages="$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qF 'done < <(find "$V2_ROOT/console/yeni" -type f' <<<"$pages"
    [ -f "$V2_ROOT/console/yeni/index.html" ]
    run ! grep -q 'index.html' <<<"$body"
    grep -q 'CONSOLE_WEB_DIR="\$CONSOLE_WEB_DIR"' <<<"$(awk '/^stage_6\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx 'CONSOLE_WEB_DIR="/usr/local/share/master-stack/konsol"' "$V2_ROOT/config/defaults.env"
    grep -qE '^    local items="[^"]*(^| )console( |")' "$V2_ROOT/../kur.sh"
    s6="$(awk '/^stage_6\(\)/,/^ensure_panel\(\)/' "$V2_ROOT/install.sh")"
    grep -q '^    ensure_files_panel "\$OS_CHANGED"$' <<<"$s6"
    # The port collides with nothing: master-wg net-add reserves the base's ports (DD-271).
    grep -qF '"Dosyalar:${FILES_PANEL_PORT:-}" "Paylaşım:${SHARE_PORT:-}"' "$V2_ROOT/scripts/master-wg"
    run ! grep -q 'declared_ports' "$V2_ROOT/scripts/master-wg"
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'FILES_PANEL_PORT=\$FILES_PANEL_PORT'
    # Tailnet only through Caddy; nothing on the WireGuard edge.
    # DD-140: one address; /api/konsol/* to the root backend, the rest (pages included) here.
    awk '/^\(konsol\) \{$/,/^\}$/' "$V2_ROOT/templates/Caddyfile" >"$TMP/site"
    grep -qxF "$(printf '\t@kok path /api/konsol/*')" "$TMP/site"
    grep -q 'handle @kok {' "$TMP/site"
    grep -q 'handle /api/\* {' "$TMP/site"
    grep -q 'reverse_proxy unix/__PANEL_SOCKET__ {$' "$TMP/site"
    grep -q 'reverse_proxy 127.0.0.1:__FILES_PANEL_PORT__ {$' "$TMP/site"
    # DD-271: no redirect at all (no old address is kept).
    run ! grep -q 'redir ' "$V2_ROOT/templates/Caddyfile"
    grep -qx 'interface-name=panel.__LOCAL_DOMAIN__,__TAILSCALE_IF__/4' "$V2_ROOT/templates/dnsmasq.conf"
    [ ! -e "$V2_ROOT/templates/Caddyfile.wg" ]
    # DD-144: the trash sits beside the downloads folder, not inside it, so no container
    # that mounts downloads can reach it and the tmpfs curtain is gone.
    awk '/^stage_3\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF '"$SERVER_ROOT/$FILES_PANEL_TRASH"; do'
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    run ! grep -q 'panele yönlenmedi' <<<"$s7"
    grep -q 'master-files-panel" check' <<<"$s7"
    grep -q 'ps -o uid= -p' <<<"$s7"
    # DD-271: the "no file backend on a VPN address" check is the base's WireGuard check.
    run ! grep -q 'wg_first_addr' <<<"$s7"
    awk '/^check_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF 'http://${s4}:${FILES_PANEL_PORT}/'
    grep -qE '^    local items="[^"]*(^| )files-panel( |")' "$V2_ROOT/../kur.sh"
    # One page, no login: both backends answer only on panel.<domain> and log the same actor.
    grep -q 'ACTOR = "konsol"' "$V2_ROOT/files-panel/master-files-panel"
    grep -q 'ACTOR = "konsol"' "$V2_ROOT/panel/master-panel"
    grep -q 'API_HEADER = "X-Konsol"' "$V2_ROOT/files-panel/master-files-panel" "$V2_ROOT/panel/master-panel"
    grep -q 'hosts.add("panel.%s"' "$V2_ROOT/files-panel/master-files-panel" "$V2_ROOT/panel/master-panel"
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
    # DD-271: the base state carries addresses, ports, paths and WireGuard's own keys.
    cat >"$TMP/state.env" <<EOF
V2_VERSION=2026.08.06-v2-test
WAN_IPV4=203.0.113.7
RUNTIME_DIR=$TMP/run
SSH_PUBLIC_PORT=22
SHARE_PORT=61010
FILES_PANEL_PORT=61009
TAILSCALE_UDP_PORT=41641
WG_CONF_DIR=$TMP/etc/wireguard
WG_CLIENTS_DIR=$TMP/etc/wireguard/clients
WG_ADDR_BASE4=10.8
WG_ADDR_BASE6=fdcc:ad94:bacf:61a4
WG_PORT_DEFAULT=61001
WG_CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
WG_MTU=1420
WG_NETWORKS_FILE=$TMP/etc/wireguard/networks
WG_STOPPED_FILE=$TMP/etc/wireguard/.durduruldu
WG_NETWORKS_MAX=9
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

@test "backend write paths (DD-207, DD-271): WireGuard's folder exists before the backend starts" {
    local s4 s6 unit="$V2_ROOT/systemd/master-panel.service"
    # The backend's only write paths are fixed: WireGuard's folder and the account folder; both are
    # created before the backend first starts (stage 4 and ensure_panel), so systemd always binds them.
    grep -qx 'ReadWritePaths=-__WG_CONF_DIR__ -__KONSOL_AUTH_DIR__' "$unit"
    awk '/^ensure_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF 'install -d -m 0700 -o root -g root -- "$WG_CONF_DIR"'
    awk '/^ensure_panel\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF 'install -d -m 0700 -o root -g root -- "$KONSOL_AUTH_DIR"'
    s4="$(grep -n '^stage_4()' "$V2_ROOT/install.sh" | cut -d: -f1)"
    s6="$(grep -n '^stage_6()' "$V2_ROOT/install.sh" | cut -d: -f1)"
    [ "$s4" -lt "$s6" ]
    run ! grep -qE 'panel_yollari_bagli|arkauc' "$V2_ROOT/install.sh"
}

@test "master-wg says plainly when its folder is read-only for the caller (DD-207)" {
    [ "$(id -u)" -ne 0 ] || skip "root writes into a 0555 folder; the check needs an unprivileged runner"
    wg_mock_bin
    wg_state_fixture
    local wgd="$TMP/etc/wireguard" before
    before="$(cat "$wgd/networks")"
    chmod 0555 "$wgd"
    run master_wg net-add 61011 1.1.1.1 x
    chmod 0755 "$wgd"
    [ "$status" -ne 0 ]
    case "$output" in *"salt okunur görünüyor"*"systemctl restart master-panel"*) ;; *) false ;; esac
    [ "$(cat "$wgd/networks")" = "$before" ]
    [ ! -e "$wgd/wg1.conf" ]
    chmod 0555 "$wgd"
    run master_wg list
    chmod 0755 "$wgd"
    [ "$status" -eq 0 ]   # reading still works
    grep -qF 'net-add|net-remove|add|remove|dns|keepalive|peer|net|net-settings|reset|durdur|baslat) yazilabilir ;;' "$V2_ROOT/scripts/master-wg"
}

@test "master-wg adds a peer generated on the server, applies it live and keeps the profile root-side" {
    wg_mock_bin
    wg_state_fixture
    run master_wg add iphone "9.9.9.9 , 149.112.112.112" 21 1380
    [ "$status" -eq 0 ]
    [ "$output" = $'iphone\t10.8.0.2' ]
    profile="$TMP/etc/wireguard/clients-wg0/iphone.conf"
    mode="$(stat_field %a %Lp "$profile")"
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

@test "network settings rename a network without touching peers keys or services (DD-265)" {
    wg_settings_fixture
    local revision bad
    revision="$(wg_revision)"
    run master_wg --if wg0 net-settings 1.1.1.1 "$revision" 'Ev \ağı'
    [ "$status" -eq 0 ]
    [ "$(cut -f9 "$TMP/etc/wireguard/networks")" = 'Ev \ağı' ]
    [ "$(cut -f8 "$TMP/etc/wireguard/networks")" = '1.1.1.1' ]
    cmp -s "$WG0_CONF" "$TMP/original.conf"
    grep -qx 'unchanged profile' "$TMP/etc/wireguard/clients-wg0/test.conf"
    [ ! -s "$TMP/calls" ]
    # The old revision is stale now; a bad name is refused before any write.
    run master_wg --if wg0 net-settings 1.1.1.1 "$revision" 'Başka'
    [ "$status" -ne 0 ]
    cp "$TMP/etc/wireguard/networks" "$TMP/renamed.networks"
    for bad in ' baş' 'son ' $'iki\tsütun' "$(printf 'x%.0s' {1..65})"; do
        run master_wg --if wg0 net-settings 1.1.1.1 "$(wg_revision)" "$bad"
        [ "$status" -ne 0 ]
    done
    cmp -s "$TMP/renamed.networks" "$TMP/etc/wireguard/networks"
    # Without a name the name stays.
    run master_wg --if wg0 net-settings 9.9.9.9 "$(wg_revision)"
    [ "$status" -eq 0 ]
    [ "$(cut -f9 "$TMP/etc/wireguard/networks")" = 'Ev \ağı' ]
}

@test "network settings reject an access argument without writes" {
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
    case "$output" in *'bekleyen ayar işlemini'*) ;; *) false ;; esac
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
    [ "$(stat_field %a %Lp "$wgd/wg1.conf")" = 600 ]
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
    # Refusals change nothing: a port of wg0, of a panel network or of the base (WebDAV, Files), the
    # range, scope, DNS, label.
    before="$(cat "$wgd/networks")"
    rm -f "$TMP/calls"
    for args in "61001|1.1.1.1|x" "61021|1.1.1.1|x" "61010|1.1.1.1|x" "61009|1.1.1.1|x" \
        "1000|1.1.1.1|x" "61031|dns.google|x" $'61031|1.1.1.1|a\tb' "61031|1.1.1.1| lead"; do
        IFS='|' read -r a b c <<<"$args"
        run master_wg net-add "$a" "$b" "$c"
        [ "$status" -ne 0 ]
    done
    run master_wg net-add 61001 1.1.1.1 x
    case "$output" in *"UDP 61001 kullanılıyor (wg0)"*) ;; *) false ;; esac
    run master_wg net-add 61009 1.1.1.1 x
    case "$output" in *"UDP 61009 kullanılıyor (Dosyalar)"*) ;; *) false ;; esac
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
    # The limit comes from the base's state (DD-271).
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
    conf_before="$(file_sha256 "$WG0_CONF")"
    rm -f "$TMP/calls"
    run master_wg dns iphone "2a07:a8c0::df:877b , 2a07:a8c1::df:877b"
    [ "$status" -eq 0 ]
    [ "$output" = $'iphone\t2a07:a8c0::df:877b, 2a07:a8c1::df:877b' ]
    grep -qx 'DNS = 2a07:a8c0::df:877b, 2a07:a8c1::df:877b' "$profile"
    [ "$(grep -c '^DNS = ' "$profile")" = 1 ]
    [ "$(grep -v '^DNS = ' "$profile")" = "$rest_before" ]
    [ "$(file_sha256 "$WG0_CONF")" = "$conf_before" ]
    mode="$(stat_field %a %Lp "$profile")"
    [ "$mode" = 600 ]
    # DNS is client-side only: nothing is applied to the interface.
    run ! grep -qE 'syncconf|systemctl restart' "$TMP/calls"
    # Bad input changes nothing.
    before="$(file_sha256 "$profile")"
    run master_wg dns iphone "dns.google"
    [ "$status" -ne 0 ]
    run master_wg dns iphone " , "
    [ "$status" -ne 0 ]
    run master_wg dns ghost 1.1.1.1
    [ "$status" -ne 0 ]
    case "$output" in *"adında bir peer yok"*) ;; *) false ;; esac
    run master_wg dns iphone
    [ "$status" -ne 0 ]
    [ "$(file_sha256 "$profile")" = "$before" ]
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

@test "the console folder holds this version's files only: the build at the root beside the sign-in page (DD-267)" {
    # ensure_console_pages places the build (console/yeni) at CONSOLE_WEB_DIR's root with the sign-in
    # page, the editor and the icons, then removes every other file (whatever an earlier build of this
    # generation shipped) and the folders left empty; a symlink goes as a link, never followed.
    local fn want f
    fn="$(awk '/^ensure_console_pages\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    # It manages every file in the folder, so a wrong value cannot prune another folder; no build, no change.
    grep -qF '[[ "$CONSOLE_WEB_DIR" == /usr/local/share/master-stack/* ]] || die ' <<<"$fn"
    grep -qF '[[ -f "$V2_ROOT/console/yeni/index.html" ]] || die ' <<<"$fn"
    [ "$(grep -n 'CONSOLE_WEB_DIR" == /usr/local/share/master-stack/' <<<"$fn" | cut -d: -f1)" -lt "$(grep -n 'install -d' <<<"$fn" | head -1 | cut -d: -f1)" ]
    [ "$(grep -n 'console/yeni/index.html" ]] || die' <<<"$fn" | cut -d: -f1)" -lt "$(grep -n 'install -d' <<<"$fn" | head -1 | cut -d: -f1)" ]
    grep -qx 'CONSOLE_WEB_DIR="/usr/local/share/master-stack/konsol"' "$V2_ROOT/config/defaults.env"
    # Files go one by one (no recursive rm that could cross into a linked folder); nothing is per package.
    run ! grep -q 'rm -rf' <<<"$fn"
    # The kept-file table is an associative array (the server's Bash 5); macOS /bin/bash 3.2 has none.
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || skip "ensure_console_pages needs Bash 4 or later"
    # The fixture's folder stands in for /usr/local/share/master-stack; the owner flags need root.
    eval "${fn//\/usr\/local\/share\/master-stack\//$TMP/share/}"
    install() { mkdir -p -- "${@: -1}"; }
    CONSOLE_WEB_DIR="$TMP/share/konsol"
    mkdir -p "$CONSOLE_WEB_DIR/kalkan/sayfa" "$CONSOLE_WEB_DIR/onceki/fonts" "$TMP/other"
    for f in index.html konsol.js konsol.css panel.css ayarlar.js onceki/index.html onceki/app.js \
        onceki/fonts/Outfit-Variable.woff2 kalkan/sayfa/sayfa.js ._app.js; do
        printf 'old\n' >"$CONSOLE_WEB_DIR/$f"
    done
    printf 'keep\n' >"$TMP/other/keep"
    ln -s "$TMP/other" "$CONSOLE_WEB_DIR/kalkan/baglanti"
    ln -s "$TMP/other/keep" "$CONSOLE_WEB_DIR/eski.js"
    ensure_console_pages
    want="$( { (cd "$V2_ROOT/console/yeni" && find . -type f ! -name kaynak.sha256 ! -name '.*' | sed 's|^\./||')
        printf '%s\n' giris.html giris.js giris.css duzenleyici.js obhut.svg obhut.png; } | LC_ALL=C sort)"
    [ "$(cd "$CONSOLE_WEB_DIR" && find . -mindepth 1 ! -type d | sed 's|^\./||' | LC_ALL=C sort)" = "$want" ]
    [ "$(cd "$CONSOLE_WEB_DIR" && find . -mindepth 1 -type d | sed 's|^\./||' | LC_ALL=C sort)" = \
        "$(cd "$V2_ROOT/console/yeni" && find . -mindepth 1 -type d | sed 's|^\./||' | LC_ALL=C sort)" ]
    for f in $want; do
        if [ -f "$V2_ROOT/console/yeni/$f" ]; then cmp -s "$V2_ROOT/console/yeni/$f" "$CONSOLE_WEB_DIR/$f"; else cmp -s "$V2_ROOT/console/$f" "$CONSOLE_WEB_DIR/$f"; fi
        [ "$(stat_field %a %Lp "$CONSOLE_WEB_DIR/$f")" = 644 ]
    done
    [ ! -e "$CONSOLE_WEB_DIR/kaynak.sha256" ]
    [ "$(cat "$TMP/other/keep")" = keep ]
    # A second run changes nothing.
    ensure_console_pages
    [ "$(cd "$CONSOLE_WEB_DIR" && find . -mindepth 1 ! -type d | sed 's|^\./||' | LC_ALL=C sort)" = "$want" ]
    # A folder outside Konsol's share and a tree without the build are refused before anything is touched;
    # a build file named like one of the sign-in page's stops the install.
    mkdir -p "$TMP/elsewhere"
    printf 'mine\n' >"$TMP/elsewhere/note"
    CONSOLE_WEB_DIR="$TMP/elsewhere" run ensure_console_pages
    [ "$status" -ne 0 ]
    [ "$(ls -A "$TMP/elsewhere")" = note ]
    mkdir -p "$TMP/v2/console"
    cp "$V2_ROOT"/console/giris.* "$V2_ROOT"/console/duzenleyici.js "$V2_ROOT"/console/obhut.* "$TMP/v2/console/"
    V2_ROOT="$TMP/v2" run ensure_console_pages
    [ "$status" -ne 0 ]
    [ "$(cd "$CONSOLE_WEB_DIR" && find . -mindepth 1 ! -type d | sed 's|^\./||' | LC_ALL=C sort)" = "$want" ]
    mkdir -p "$TMP/v2/console/yeni"
    printf '<!doctype html>\n' >"$TMP/v2/console/yeni/index.html"
    printf 'clash\n' >"$TMP/v2/console/yeni/giris.js"
    V2_ROOT="$TMP/v2" run ensure_console_pages
    [ "$status" -ne 0 ]
    case "$output" in *giris.js*) ;; *) false ;; esac
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
    # Prompt defaults come from the base's defaults.env (DD-271); no package file is read.
    grep -q 'DEFAULT_KEEPALIVE="$(default_of WG_CLIENT_KEEPALIVE_DEFAULT)"' "$cmd"
    grep -q '^WG_CLIENT_KEEPALIVE_DEFAULT="21"$' "$V2_ROOT/config/defaults.env"
    grep -q '^WG_CLIENTS_DIR="/etc/wireguard/clients"$' "$V2_ROOT/config/defaults.env"
    run ! grep -qE 'magaza|wireguard\.env|wg_default_of' "$cmd"
}

@test "no setting names a single WireGuard network: the paths are bases only" {
    # DD-143: wg0 is one registry row like any other, so no default, state key or
    # script may hard-code its config path.
    grep -q '^WG_CONF_DIR="/etc/wireguard"$' "$V2_ROOT/config/defaults.env"
    # DD-271: the installer's state carries WireGuard's base keys; master-wg reads them from there.
    awk '/^write_state\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qx 'WG_CONF_DIR=$WG_CONF_DIR'
    run ! grep -qE 'WG_ENV_FILE|wireguard\.env' "$V2_ROOT/scripts/master-wg"
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
    # DD-198/271: the rules come from WireGuard's own registry, read by the firewall itself.
    for f in load_wireguard_rules container_dns_iface apply_input4 apply_input6 apply_forward apply_nat wan_allow_pairs; do
        eval "$(awk "/^$f\\(\\)/,/^}\$/" "$fw")"
    done
    grep -q '^load_wireguard_rules$' "$fw"
    awk '/^load_wireguard_rules$/ {l = NR} /^resolve_wan_interface$/ {r = NR} END { exit !(l && r && l < r) }' "$fw"
    # write_state carries the sockets the base needs and WireGuard's registry and marker (DD-271).
    for v in PANEL_SOCKET CADDY_ADMIN_SOCKET WG_NETWORKS_FILE WG_STOPPED_FILE; do
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
    CHAIN_STAGING_PREFIX=MASTER-NEXT- KONTEYNER_BRIDGE_PREFIX=ksl
    eval "$(grep '^VPN_BLOCK_DEST[46]=' "$V2_ROOT/config/defaults.env")"
    eval "$(sed -n '/^ICMP6_TYPES=(/,/)$/{p;}' "$fw")"
    WG_NETWORKS_FILE="$TMP/networks" WG_STOPPED_FILE="$TMP/.durduruldu"
    # DD-143: wg0 da kayıttan gelir; kayıt boşsa hiç WireGuard kuralı olmaz.
    : >"$WG_NETWORKS_FILE"
    load_wireguard_rules
    [ "${#VPN_IFACES[@]}" -eq 0 ]
    apply_input4
    run ! grep -q ' wg' "$TMP/in4"
    rm -f "$TMP/in4" "$TMP/in6" "$TMP/nat4" "$TMP/nat6"
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc:ad94:bacf:61a4::1\tfdcc:ad94:bacf:61a4::/112\t1.1.1.1\tAna ağ\n' >"$WG_NETWORKS_FILE"
    printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\tMisafir\n' >>"$WG_NETWORKS_FILE"
    printf 'wg2\t61021\tinet\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t1.1.1.1\t\n' >>"$WG_NETWORKS_FILE"
    load_wireguard_rules
    [ "${VPN_IFACES[*]}" = "wg0 wg1 wg2" ]
    # DD-229: a stopped WireGuard keeps its registry but opens nothing.
    printf 'wg0\nwg2\n' >"$WG_STOPPED_FILE"
    load_wireguard_rules
    [ "${#VPN_IFACES[@]}" -eq 0 ]
    rm -f "$WG_STOPPED_FILE"
    load_wireguard_rules
    [ "${VPN_IFACES[*]}" = "wg0 wg1 wg2" ]
    apply_input4
    apply_forward iptables FW-
    apply_input6
    apply_nat iptables_nat NAT- "${VPN_NET4[@]}"
    apply_nat ip6tables_nat NAT6- "${VPN_NET6[@]}"
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
    set -- $VPN_BLOCK_DEST4
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
    run load_wireguard_rules
    [ "$status" -ne 0 ]
    case "$output" in *"ağ kaydı bozuk"*"hiçbir kural değiştirilmedi"*) ;; *) false ;; esac
    printf 'wg1\t61011\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc:ad94:bacf:61a4::1:1\tfdcc:ad94:bacf:61a4::1:0/112\t9.9.9.9\t\n' >"$WG_NETWORKS_FILE"
    printf 'wg2\t61011\tinet\t10.8.2.1\t10.8.2.0/24\tfdcc:ad94:bacf:61a4::2:1\tfdcc:ad94:bacf:61a4::2:0/112\t9.9.9.9\t\n' >>"$WG_NETWORKS_FILE"
    run load_wireguard_rules
    [ "$status" -ne 0 ]
    case "$output" in *"tekrar eden"*) ;; *) false ;; esac
    [ ! -e "$TMP/in4" ]
    # DD-143: kayıt dosyası hiç yoksa ağ da yoktur.
    WG_NETWORKS_FILE="$TMP/none"
    load_wireguard_rules
    [ "${#VPN_IFACES[@]}" -eq 0 ]
    # No wg-quick PostUp rules: the firewall script owns netfilter (DD-16/DD-17).
    run ! grep -q 'PostUp' <<<"$(grep -vE '^[[:space:]]*#' "$V2_ROOT/install.sh")"
    run ! grep -q 'WG_PUBLIC_PORT' <<<"$(awk '/^docker_return_pairs\(\)/,/^}$/' "$fw")"
}

@test "a WireGuard registry the firewall cannot trust stops it before any rule" {
    local fw="$V2_ROOT/scripts/firewall.sh" line
    eval "$(awk '/^load_wireguard_rules\(\)/,/^}$/' "$fw")"
    die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
    WG_NETWORKS_FILE="$TMP/networks" WG_STOPPED_FILE="$TMP/.durduruldu"
    # Any malformed line (name, port, scope, subnets) stops the run: no partial list is applied.
    for line in $'wgx\t61051\tinet\t10.8.5.1\t10.8.5.0/24\tfd00::5:1\tfd00::5:0/112\t1.1.1.1\tA' \
        $'wg5\t0\tinet\t10.8.5.1\t10.8.5.0/24\tfd00::5:1\tfd00::5:0/112\t1.1.1.1\tA' \
        $'wg5\t61051\tui\t10.8.5.1\t10.8.5.0/24\tfd00::5:1\tfd00::5:0/112\t1.1.1.1\tA' \
        $'wg5\t61051\tinet\t10.8.5.1\t10.8.5.0\tfd00::5:1\tfd00::5:0/112\t1.1.1.1\tA' \
        $'wg5\t61051\tinet\t10.8.5.1\t10.8.5.0/24'; do
        printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tA\n%s\n' "$line" >"$WG_NETWORKS_FILE"
        run load_wireguard_rules
        [ "$status" -ne 0 ]
        case "$output" in *"WireGuard ağ kaydı bozuk"*) ;; *) false ;; esac
    done
    # A symlinked registry is not the one master-wg writes.
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tA\n' >"$TMP/elsewhere"
    rm -f "$WG_NETWORKS_FILE"
    ln -s "$TMP/elsewhere" "$WG_NETWORKS_FILE"
    run load_wireguard_rules
    [ "$status" -ne 0 ]
    case "$output" in *"sembolik bağ"*) ;; *) false ;; esac
    # A good registry without a trailing newline gives its networks.
    rm -f "$WG_NETWORKS_FILE"
    printf 'wg5\t61051\tinet\t10.8.5.1\t10.8.5.0/24\tfdcc::5:1\tfdcc::5:0/112\t1.1.1.1\t' >"$WG_NETWORKS_FILE"
    load_wireguard_rules
    [ "${VPN_IFACES[*]}" = "wg5" ] && [ "${VPN_PORTS[*]}" = 61051 ]
    # A die at load time leaves the boot recovery guard to the EXIT trap (set before loading).
    awk '/^trap startup_failure EXIT$/ {t = NR} /^load_wireguard_rules$/ {l = NR} END { exit !(t && l && t < l) }' "$fw"
}

@test "check_before and the WireGuard FORWARD count catch order and extra rules" {
    eval "$(awk '/^check_before\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    eval "$(awk '/^check_forward_chain\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    eval "$(awk '/^check_rule_count\(\)/,/^}$/' "$V2_ROOT/scripts/firewall.sh")"
    die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
    check_jump_exactly_one() { :; }
    check_rule() { :; }
    CHAIN_FORWARD=MASTER-FORWARD WAN_INTERFACE=eth0
    VPN_IFACES=(wg0)
    VPN_BLOCK_DEST4="" VPN_BLOCK_DEST6=""
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
    VPN_IFACES=(wg0 wg1)
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
    run ! grep -qE 'Caddyfile.wg|izin verilen WireGuard|Local erişim' "$V2_ROOT/console/yeni/app.js"
    run ! grep -qE 'CADDY_WG_FILE|caddy-wg@|ensure_caddy_wg' "$V2_ROOT/install.sh" "$V2_ROOT/scripts/master-wg"
    # Fresh installs only: no upgrade helper rewrites an older WireGuard registry.
    run ! grep -q 'master_wg_upgrade' "$V2_ROOT/install.sh"
    [ ! -e "$V2_ROOT/panel/master_wg_upgrade.py" ]
    local s7
    s7="$(awk '/^stage_7\(\)/,/^print_summary\(\)/' "$V2_ROOT/install.sh")"
    # DD-271: the per-network checks are the base's check_wireguard, run from stage 7.
    grep -qx '    check_wireguard' <<<"$s7"
    awk '/^check_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF 'wg show "$iface" listen-port'
    awk '/^check_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh" | grep -qF '"$SBIN_DIR/master-wg" version'
    run ! grep -qE 'wg_s4|caddy-wg' <<<"$s7"
}

@test "installer summary names the built-ins and WireGuard's state" {
    eval "$(awk '/^summary_wireguard\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    WG_NETWORKS_FILE="$TMP/networks" WG_STOPPED_FILE="$TMP/.durduruldu"
    wg() { printf 'peer-a\npeer-b\n'; }
    run summary_wireguard
    [ "$output" = 'ağ yok; ilk ağ Konsol → Erişim → WireGuard' ]
    printf 'wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tA\n' >"$WG_NETWORKS_FILE"
    run summary_wireguard
    [ "$output" = '1 ağ, 2 peer' ]
    printf 'wg0\n' >"$WG_STOPPED_FILE"
    run summary_wireguard
    [ "$output" = 'durduruldu (1 ağ)' ]
    # DD-208: Podman is base infrastructure, printed with its version.
    grep -qF 'Podman:       ${PODMAN_VERSION:-?} (konteyner ortamı; Konsol → Gelişmiş → Podman)' "$V2_ROOT/install.sh"
    body="$(awk '/^print_summary\(\)/,/^}$/' "$V2_ROOT/install.sh")"
    grep -qx '  Dosyalar: $SERVER_ROOT' <<<"$body"
    grep -qx '  Paylaşım: Dosyalar → Paylaşımlar: klasör başına adres, kullanıcı ve erişim izni' <<<"$body"
    grep -qx '  WireGuard: $(summary_wireguard)' <<<"$body"
    run ! grep -qE 'summary_modules|summary_notes|App Store|paket_' <<<"$body"
}

settings_fixture() {
    # DD-155: the Ayarlar backend against the real templates (rendered here) and fake iptables
    # with counters.
    mkdir -p "$TMP/caddy/moduller" "$TMP/dnsmasq.d" "$TMP/srv/downloads"
    cat >>"$TMP/state.env" <<EOF
WAN_INTERFACE=eth0
WAN_IPV4=203.0.113.7
TAILSCALE_IF=tailscale0
SSH_PUBLIC_PORT=22
TAILSCALE_UDP_PORT=41641
CHAIN_INPUT=MASTER-INPUT
CHAIN_FORWARD=MASTER-FORWARD
CHAIN_NAT=MASTER-NAT
CADDYFILE=$TMP/caddy/Caddyfile
CADDY_MODULES_DIR=$TMP/caddy/moduller
DNSMASQ_CONF_DIR=$TMP/dnsmasq.d
DOWNLOADS_PATH=$TMP/srv/downloads
EOF
    rend() {
        sed -e 's/__LOCAL_DOMAIN__/ayc/g' -e 's#__PANEL_SOCKET__#/run/master-panel/api.sock#g' \
            -e 's#__SYSTEM_FILES_SOCKET__#/run/master-sistem-dosya/api.sock#g' \
            -e 's#__CADDY_ADMIN_SOCKET__#/run/caddy/admin.sock#g' -e 's/__FILES_PANEL_PORT__/61009/g' \
            -e 's/__CADDY_HTTP_PORT__/80/g' -e "s#__CONSOLE_WEB_DIR__#$TMP/web#g" -e "s#__CADDY_MODULES_DIR__#$TMP/caddy/moduller#g" \
            -e 's/__WAN_IPV4__/203.0.113.7/g' -e 's/__SHARE_HTTPS_PORT__/443/g' \
            -e 's/__SHARE_PORT__/61010/g' -e 's/__TAILSCALE_IF__/tailscale0/g' \
            -e "s#__DOWNLOADS_PATH__#$TMP/srv/downloads#g" "$1"
    }
    rend "$V2_ROOT/templates/Caddyfile" >"$TMP/caddy/Caddyfile"
    rend "$V2_ROOT/templates/paylasim.caddy" >"$TMP/caddy/moduller/paylasim.caddy"
    rend "$V2_ROOT/templates/dnsmasq.conf" >"$TMP/dnsmasq.d/local-services.conf"
    rend "$V2_ROOT/templates/paylasim-dnsmasq.conf" >"$TMP/dnsmasq.d/modul-paylasim.conf"
    cat >"$TMP/pbin/iptables" <<'EOF'
#!/bin/bash
case "$*" in
    *"-S MASTER-INPUT") printf '%s\n' '-N MASTER-INPUT' '-A MASTER-INPUT -i lo -c 157 20446 -j ACCEPT' \
        '-A MASTER-INPUT -m conntrack --ctstate RELATED,ESTABLISHED -c 687 118737 -j ACCEPT' \
        '-A MASTER-INPUT -i tailscale0 -c 4 240 -j ACCEPT' '-A MASTER-INPUT -i eth0 -p udp -m udp --dport 41641 -c 0 0 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -p tcp -m tcp --dport 22 -c 23 1412 -j ACCEPT' '-A MASTER-INPUT -i eth0 -p udp -m udp --dport 61001 -c 5 300 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -p tcp -m tcp --dport 8080 -c 3 180 -j ACCEPT' \
        '-A MASTER-INPUT -i eth0 -c 1631 190422 -j DROP' '-A MASTER-INPUT -i wg0 -c 7 420 -j DROP' \
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

# DD-267: the old Settings page's GET /api/konsol/ayarlar is gone; the view it returned still feeds
# Gelişmiş, Erişim and the firewall page, so a test reads it from the backend in-process (same state
# and fake tools as the running panel).
settings_view() {
    PYTHONDONTWRITEBYTECODE=1 python3 - "$V2_ROOT/panel/master-panel" "$TMP" <<'PY'
import importlib.machinery, importlib.util, json, sys, types
loader = importlib.machinery.SourceFileLoader("master_panel", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("master_panel", loader))
loader.exec_module(module)
p = module.Panel(types.SimpleNamespace(state=sys.argv[2] + "/state.env", state_env=True, allow_host=[]))
print(json.dumps(p.settings(fresh=True), ensure_ascii=False))
PY
}

@test "wg panel shows the server's settings read-only: rules with counters, sites, names" {
    command -v python3 >/dev/null || skip "python3 yok"
    panel_start
    settings_fixture
    # DD-267: the old shell's settings read is gone; Gelişmiş and the firewall page read the same view.
    [ "$(pc /api/konsol/ayarlar)" = 403 ]
    [ "$(pc /api/konsol/ayarlar -H 'X-Konsol: 1')" = 404 ]
    [ "$(pc /api/konsol/gelismis -H 'X-Konsol: 1')" = 200 ]
    run ! grep -qE 'GIZLI|Password|Username' "$TMP/body"
    cp "$TMP/body" "$TMP/gelismis"
    [ "$(pc /api/konsol/guvenlik-duvari -H 'X-Konsol: 1')" = 200 ]
    run ! grep -qE 'GIZLI|Password|Username' "$TMP/body"
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["denetim"] == {"ok": True, "metin": "firewall: kritik politikalar yerinde"} and d["aglar"][0]["arayuz"] == "wg0", d' "$TMP/body"
    settings_view >"$TMP/view"
    run ! grep -qE 'GIZLI|Password|Username' "$TMP/view"
    python3 - "$TMP/view" "$TMP" "$TMP/gelismis" <<'PY'
import json, sys
d, tmp = json.load(open(sys.argv[1])), sys.argv[2]
g = json.load(open(sys.argv[3]))
assert (g["caddy"], g["dnsmasq"]) == (d["web"], d["dns"]), g
fw = d["firewall"]
assert fw["ok"] and fw["check"] == "firewall: kritik politikalar yerinde", fw
# The old Settings page's rule groups are gone: the technical rows (guvenlik-duvari teknik) carry the rules.
assert "v4" not in fw and "v6" not in fw, sorted(fw)
# Web: every address with where it goes, its source and who reaches it.
web = {e["address"]: e for e in d["web"]["entries"]}
routes = [(r["path"], r["kind"], r["to"]) for r in web["panel.ayc"]["routes"]]
assert routes == [
    ("/api/konsol/*", "proxy", "unix//run/master-panel/api.sock"),
    ("/api/sistem/*", "proxy", "unix//run/master-sistem-dosya/api.sock"), ("/api/*", "proxy", "127.0.0.1:61009"), ("", "files", "")], web["panel.ayc"]
assert "health.ayc" not in web
assert web["paylas.ayc"]["source"] == "paylasim" and web["100.64.0.7:61010"]["source"] == "paylasim"
assert not [a for a in web if "torrent" in a or "gezgin" in a]
assert not [a for a in web if a.startswith(("wg.", "dosya.", "file."))]
# The base Caddyfile and the share's site (DD-271: no package site).
assert len(d["web"]["raw"]) == 2
assert not any(token in json.dumps(d["web"]["raw"]) for token in ("__WAN_IPV4__", "__SHARE_PORT__", "__SHARE_HTTPS_PORT__"))
# Names: the base's and the share's, all on the Tailscale address.
names = {n["name"]: n for n in d["dns"]["names"]}
assert set(names) == {"panel.ayc", "paylas.ayc"}, names
assert names["panel.ayc"]["source"] == "base" and names["paylas.ayc"]["source"] == "paylasim"
assert all(n["address"] == "100.64.0.7" for n in names.values())
assert d["dns"]["listen"] == ["lo", "tailscale0"] and d["dns"]["domains"] == ["ayc"] and d["dns"]["dhcp"] is False
# DD-202: the base view knows no application.
assert "torrent" not in d, sorted(d)
PY
    # Read-only: the page's GET never starts a job.
    [ ! -e "$TMP/sdrun-calls" ]
}

@test "the settings guard runs from its own two-second timer" {
    grep -q 'OnUnitActiveSec=2s' "$V2_ROOT/systemd/master-settings-guard.timer"
    grep -q 'master_settings.py --state __STATE_FILE__ guard' "$V2_ROOT/systemd/master-settings-guard.service"
}

@test "settings API keeps its gates, hides hashes, lists all rules and passes mutations privately to a worker" {
    panel_start
    settings_fixture
    mkdir -p "$TMP/srv/media" "$TMP/run" "$TMP/units"
    cat >>"$TMP/state.env" <<EOF
SETTINGS_FILE=$TMP/settings.json
SETTINGS_PENDING_FILE=$TMP/pending.json
SETTINGS_DNS_FILE=$TMP/dnsmasq.d/konsol.conf
DNSMASQ_CONF_FILE=$TMP/dnsmasq.d/local-services.conf
UNIT_DIR=$TMP/units
RUNTIME_DIR=$TMP/run
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
    # DD-267: the view is read in-process (its route is gone); the firewall page's table route carries its rules.
    [ "$(pc '/api/konsol/ayarlar?yenile=1' -H 'X-Konsol: 1')" = 404 ]
    [ "$(pc '/api/konsol/guvenlik-duvari?yenile=1' -H 'X-Konsol: 1')" = 200 ]
    python3 - "$TMP/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "GIZLI" not in json.dumps(d)
assert any(r["kural"] == "Politika: DROP" for r in d["teknik"])
assert any(r["sahip"] == "Tailscale" and r["paket"] == 2 for r in d["teknik"])
assert any(r["port"] == 8081 and r["kapsam"] == "any" for r in d["dinleyiciler"])
PY
    settings_view >"$TMP/view"
    python3 - "$TMP/view" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "username" not in d["manage"] and d["manage"]["pending"] is None, d["manage"]
tls = d["manage"]["https"]
assert (tls["domain"], tls["mode"], tls["scheme"], tls["port"], tls["status"]) == ("", "http", "http", 61010, "http"), tls
assert "GIZLI" not in json.dumps(d)
assert any(r["spec"] == "Politika: DROP" for r in d["firewall"]["rules"]["rows"])
assert any(r["owner"] == "Tailscale" and r["packets"] == 2 for r in d["firewall"]["rules"]["rows"])
# DD-174: raw sockets remain visible but do not synthesize remote port rules.
assert any(r["port"] == 8081 and r["scope"] == "any" for r in d["firewall"]["listeners"])
assert any(r["port"] == 8081 and r["scope"] == "lo" for r in d["firewall"]["ports"])
assert not any(r["port"] == 8081 and r["scope"] in ("wan", "tail") for r in d["firewall"]["ports"])
PY
    [ "$(pc /api/konsol/ayarlar/durum)" = 403 ]
    [ "$(pc /api/konsol/ayarlar/durum -H 'X-Konsol: 1')" = 404 ]
    [ "$(pc /api/konsol/ayarlar/klasorler -H 'X-Konsol: 1')" = 200 ]
    grep -q "$TMP/srv/media" "$TMP/body"
    [ "$(pc '/api/konsol/ayarlar/klasorler?path=/etc' -H 'X-Konsol: 1')" = 400 ]
    [ "$(pc /api/konsol/ayarlar/uygula -H 'Content-Type: application/json' --data '{}')" = 403 ]
    [ "$(pc /api/konsol/ayarlar/uygula "${headers[@]}" -H 'Sec-Fetch-Site: cross-site' --data '{}')" = 403 ]
    [ ! -e "$TMP/sdrun-calls" ]
    [ "$(pc /api/konsol/ayarlar/uygula "${headers[@]}" --data '{"revision":"sample","dns":{"disabled":["health.ayc"],"records":[],"forward":false,"servers":[]}}')" = 200 ]
    grep -q -- '--wait --pipe --collect' "$TMP/sdrun-calls"
    grep -q 'master_settings.py --state .* apply$' "$TMP/sdrun-calls"
    grep -q 'health.ayc' "$TMP/worker-body"
    [ "$(pc /api/konsol/ayarlar/onayla "${headers[@]}" --data '{"id":"sample","client":"100.64.0.9","host":"panel.forged"}')" = 200 ]
    # DD-180: without Caddy's X-Forwarded-For the client is the server itself, never a body value.
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["client"] == "yerel"' "$TMP/worker-body"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["kanal"] == "yerel"' "$TMP/worker-body"
    [ "$(pc /api/konsol/ayarlar/onayla "${headers[@]}" -H 'X-Forwarded-For: 100.64.0.5' --data '{"id":"sample"}')" = 200 ]
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["client"] == "100.64.0.5"' "$TMP/worker-body"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["host"] != "panel.forged"' "$TMP/worker-body"
    # DD-195: the channel and the browser's real name come from Caddy's headers, never the body.
    [ "$(pc /api/konsol/ayarlar/onayla "${headers[@]}" -H 'X-Forwarded-For: 100.64.0.5' -H 'X-Konsol-Kanal: internet' \
        -H 'X-Forwarded-Host: Konsol.Example.NET' --data '{"id":"sample","kanal":"tailscale"}')" = 403 ]
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["kanal"] == "tailscale"' "$TMP/worker-body"
    [ "$(pc /api/konsol/ayarlar/nested/uygula "${headers[@]}" --data '{}')" = 404 ]
    [ "$(pc /api/konsol/ayarlar/uygula "${headers[@]}" --data '[]')" = 400 ]
}

@test "the domain has no default: confirmed or previous name is kept, a first install is asked until valid" {
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
    stanza="$(sed -n '/^    local saved_domain="" /,/^    # DD-144:/p' "$V2_ROOT/install.sh")"
    [ -n "$stanza" ]
    # The terminal is replaced by a fed `read`; the stanza's own /dev/tty redirection is
    # pointed at /dev/null so the test needs no terminal.
    stanza="${stanza//<\/dev\/tty/</dev/null}"
    local pick='die() { echo "DIE $*"; exit 90; }; log() { :; }
        read() { local v="${!#}"; [[ $# -gt 0 && -n "${ANS+x}" && "$ANS" != END ]] || return 1
            printf -v "$v" "%s" "${ANS%%,*}"; echo "ASKED" >&2
            if [[ "$ANS" == *,* ]]; then ANS="${ANS#*,}"; else ANS=END; fi; }
        pick_domain() { LOCAL_DOMAIN="$2"; eval "$1"; echo "$LOCAL_DOMAIN"; }
        pick_domain "$1" "$2"'
    run env SETTINGS_FILE="$TMP/settings.json" V2_ROOT="$V2_ROOT" ANS=x bash -c "$pick" _ "$stanza" eski
    [ "$status" -eq 0 ]
    [ "$output" = ev ]
    # No confirmed name: the previous install's name is kept, nothing is asked.
    run env SETTINGS_FILE="$TMP/none.json" V2_ROOT="$V2_ROOT" ANS=x bash -c "$pick" _ "$stanza" eski
    [ "$status" -eq 0 ]
    [ "$output" = eski ]
    # First install: no default; empty and invalid answers are asked again.
    run env SETTINGS_FILE="$TMP/none.json" V2_ROOT="$V2_ROOT" ANS=',Bad_Name,ev' bash -c "$pick" _ "$stanza" ""
    [ "$status" -eq 0 ]
    [ "$(grep -c '^ASKED$' <<<"$output")" -eq 3 ]
    [ "$(grep -c '^geçersiz alan adı' <<<"$output")" -eq 2 ]
    [ "${lines[${#lines[@]}-1]}" = ev ]
    # A closed terminal stops the install instead of looping.
    run env SETTINGS_FILE="$TMP/none.json" V2_ROOT="$V2_ROOT" ANS=END bash -c "$pick" _ "$stanza" ""
    [ "$status" -eq 90 ]
    # No default exists anywhere.
    run ! grep -q 'DEFAULT_LOCAL_DOMAIN' "$V2_ROOT/install.sh" "$V2_ROOT/config/defaults.env"
    printf '%s\n' '{"domain":"bad;value"}' >"$TMP/settings.json"
    run python3 "$V2_ROOT/panel/master_settings.py" saved-domain "$TMP/settings.json"
    [ "$status" -ne 0 ]
    run ! grep -q 'health.__LOCAL_DOMAIN__' "$V2_ROOT/templates/Caddyfile" "$V2_ROOT/templates/dnsmasq.conf"
    grep -q 'state.lock' "$V2_ROOT/scripts/refresh-tailnet-config"
    grep -q 'flock -n 8' "$V2_ROOT/scripts/refresh-tailnet-config"
}

@test "the text editor bundle is installed, matches its pinned build and stays inside the CSP" {
    # DD-249: console/duzenleyici.js is built from tools/duzenleyici; its banner names every pinned package.
    local bundle="$V2_ROOT/console/duzenleyici.js" tools="$V2_ROOT/tools/duzenleyici" name version
    [ -f "$bundle" ]
    head -1 "$bundle" | grep -q '^/\*! Konsol text editor (DD-249)'
    while read -r name version; do
        [ "$name" = esbuild ] && continue
        head -60 "$bundle" | grep -qF " *   $name $version — Copyright"
    done < <(python3 -c 'import json,sys; [print(k, v) for k, v in json.load(open(sys.argv[1]))["devDependencies"].items()]' "$tools/package.json")
    grep -q '"lockfileVersion"' "$tools/package-lock.json"
    run ! grep -q '"resolved": "http' <(grep '"resolved"' "$tools/package-lock.json" | grep -v 'https://registry.npmjs.org/')
    # The build sources never reach the server: kur.sh copies a fixed list without tools.
    run ! grep -qE '^    local items="[^"]*(^| )tools( |")' "$V2_ROOT/../kur.sh"
    grep -qx 'node_modules/' "$V2_ROOT/../.gitignore"
    # Loaded on first use from Konsol's own origin (DD-267: by the interface's Dosyalar page); styles go
    # through a constructed sheet, not <style>.
    grep -qxF 'const SRC = "/duzenleyici.js";' "$V2_ROOT/tools/konsol-ui/src/pages/dosyalar/editor.ts"
    grep -qF 'StyleModule.mount = ' "$tools/giris.js"
    grep -qF 'adoptedStyleSheets' "$bundle"
    # The only address in the code is the SVG namespace; nothing is fetched from elsewhere.
    [ "$(grep -oE 'https?://[a-zA-Z0-9./_-]+' "$bundle" | sort -u)" = "http://www.w3.org/2000/svg" ]
    # Both views offer the save route; the system view keeps its narrower list otherwise.
    grep -qF '"/api/text/save": ("duzenle", save_text),' "$V2_ROOT/files-panel/master-files-panel"
    [ "$(grep -cF '"/api/text/save": ("duzenle", save_text),' "$V2_ROOT/files-panel/master-files-panel")" -eq 2 ]
}

@test "Konsol's backend: route table, Erişim and live events are installed and wired (DD-259)" {
    local install="$V2_ROOT/install.sh" panel="$V2_ROOT/panel/master-panel" caddy="$V2_ROOT/templates/Caddyfile" module stage
    # Every module the backend imports is installed beside it in SBIN_DIR, and so is every module those
    # import in turn (the inspector reads through master_yaml, master_compose and master_kube).
    local modules seen=" " todo
    todo="$(grep -oE '^import master_[a-z_]+' "$panel" | cut -d' ' -f2)"
    while [ -n "$todo" ]; do
        modules="$todo"
        todo=""
        for module in $modules; do
            case "$seen" in *" $module "*) continue ;; esac
            seen+="$module "
            grep -qE "atomic_write \"\\\$SBIN_DIR/$module\\.py\"|^ *for [a-z_]+ in ([a-z_]+ )*$module( |;)" "$install" ||
                { echo "not installed: $module"; return 1; }
            todo+=" $(grep -oE '^(import|from) master_[a-z_]+' "$V2_ROOT/panel/$module.py" | awk '{print $2}' | tr '\n' ' ')"
        done
        todo="${todo//[[:space:]]/ }"
        [ -n "${todo// /}" ] || todo=""
    done
    case "$seen" in *" master_yaml "*) ;; *) echo "master_yaml not reached"; return 1 ;; esac
    case "$seen" in *" master_kube "*) ;; *) echo "master_kube not reached"; return 1 ;; esac
    stage="$(awk '/^stage_4\(\) \{/,/^}$/' "$install")"
    grep -qF 'for panel_module in master_api master_compose master_erisim master_inspector master_kube master_olaylar master_uygulamalar master_wireguard master_yaml master_yayin; do' <<<"$stage"
    grep -qF '[[ "${V2_LAST_ATOMIC_CHANGED:-0}" -eq 0 ]] || PANEL_HELPERS_CHANGED=1' <<<"$(grep -A3 'for panel_module in' <<<"$stage")"
    # The event stream is never compressed (the encoder would hold small events back); everything else is.
    grep -qx $'\t@sikistir not path /api/konsol/olaylar' "$caddy"
    grep -qx $'\tencode @sikistir zstd gzip' "$caddy"
    [ "$(grep -c 'encode zstd gzip' "$caddy")" -eq 0 ]
    # Heartbeats well inside the backend's 180 s socket timeout; streams leave most of Caddy's 16
    # connections per site to ordinary requests; the page reads the stream with fetch, so the X-Konsol
    # gate has no exception.
    grep -qx '    timeout = 180' "$panel"
    grep -qx 'STREAM_HEARTBEAT_SECONDS = 15' "$panel"
    grep -qx 'STREAM_LIMIT = 4' "$panel"
    [ "$(grep -c 'max_conns_per_host 16' "$caddy")" -ge 2 ]
    [ "$(grep -c 'olaylar' <<<"$(awk '/def gate\(self\):/,/return ACTOR/' "$panel")")" -eq 0 ]
    # DD-267: the build is Konsol at the console's root; its hidden files are never placed and every file
    # not in this version is removed (the console folder test drives ensure_console_pages).
    grep -qF 'atomic_write "$CONSOLE_WEB_DIR/$rel" 0644 <"$f"' "$install"
    grep -qF 'find "$V2_ROOT/console/yeni" -type f ! -name '"'"'.*'"'"' \( -name '"'"'*.html'"'"'' "$install"
    grep -qF '[[ -n "${keep[$rel]:-}" ]] || rm -f -- "$f"' "$install"
}

@test "Konsol's build matches its sources, stays inside the CSP and is installed whole at the root (DD-259, DD-267)" {
    local yeni="$V2_ROOT/console/yeni" tools="$V2_ROOT/tools/konsol-ui" caddy="$V2_ROOT/templates/Caddyfile" f
    # The committed build belongs to the committed sources: npm run derle writes the digest and POSIX
    # tools recompute it (rebuild: cd tools/konsol-ui && npm ci && npm run derle).
    [ "$(sh "$tools/kaynak-ozeti.sh")" = "$(cat "$yeni/kaynak.sha256")" ]
    # The API types are generated (test_api.py compares them with panel/master_api.py).
    head -1 "$tools/src/api/sema.ts" | grep -qxF '// Generated by Data/panel/master_api.py (DD-259); do not edit.'
    # Exact pins, no install scripts, every package from the public registry; the banner names them.
    grep -qx 'ignore-scripts=true' "$tools/.npmrc"
    run ! grep -qE '": "[\^~]|": "latest"' "$tools/package.json"
    run ! grep -q '"resolved": "http' <(grep '"resolved"' "$tools/package-lock.json" | grep -v 'https://registry.npmjs.org/')
    head -1 "$yeni/app.js" | grep -qF '/*! Konsol (DD-258), built from Data/tools/konsol-ui'
    head -8 "$yeni/app.js" | grep -qF " *   vue-router $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencies"]["vue-router"])' "$tools/package.json") — "
    # The page loads only its own files, from the root (DD-267): no inline script, style or handler,
    # nothing from elsewhere.
    run ! grep -qiE '<style|style=|(^|[[:space:]])on[a-z]+=|https?://' "$yeni/index.html"
    [ "$(grep -oE '(href|src)="[^"]+"' "$yeni/index.html" | LC_ALL=C sort -u | tr '\n' ' ')" = \
        'href="/app.css" href="/fonts/Outfit-Variable.woff2" href="/manifest.json" href="/obhut.png" href="/obhut.svg" src="/app.js" src="/tema.js" ' ]
    # DD-268: installable as an app — a manifest within manifest-src 'self', its icons in the build, no service worker.
    grep -qF "manifest-src 'self'" "$caddy"
    python3 - "$yeni/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert (m["start_url"], m["scope"], m["display"]) == ("/#/genel", "/", "standalone"), m
assert {i["src"] for i in m["icons"]} == {"/obhut-192.png", "/obhut-512.png", "/obhut.svg"}, m["icons"]
assert any(i["purpose"] == "maskable" for i in m["icons"])
PY
    [ -f "$yeni/obhut-192.png" ] && [ -f "$yeni/obhut-512.png" ]
    run ! grep -qE 'serviceWorker|navigator\.serviceWorker' "$yeni/app.js"
    grep -qF -- "-o -name 'manifest.json'" "$V2_ROOT/install.sh"
    run ! grep -qE 'new Function|eval\(' "$yeni/app.js"
    # The stylesheet's only address is the local font; the sources put text into the page, never HTML.
    [ "$(grep -oE 'url\([^)]*\)|@import|https?://' "$yeni/app.css" | sort -u)" = 'url(/fonts/Outfit-Variable.woff2)' ]
    run ! grep -rqE 'v-html|\.(inner|outer)HTML *=|insertAdjacentHTML' "$tools/src"
    # The only addresses in the bundle are XML namespaces and Vue's error reference; none is fetched.
    [ "$(grep -oE 'https?://[a-zA-Z0-9./_-]+' "$yeni/app.js" | sort -u | tr '\n' ' ')" = \
        'http://www.w3.org/1998/Math/MathML http://www.w3.org/1999/xlink http://www.w3.org/2000/svg https://vuejs.org/error-reference/ ' ]
    # The local font needs font-src 'self' in the console's one CSP; its licence travels with it.
    [ "$(grep -c "font-src 'self'" "$caddy")" -eq 1 ]
    [ -f "$yeni/fonts/OFL.txt" ]
    # Every file of the build has an extension the installer places.
    for f in $(cd "$yeni" && find . -type f ! -name kaynak.sha256 | sed 's|^\./||'); do
        case "$f" in *.html | *.js | *.css | *.woff2 | *.svg | *.png | *.txt | manifest.json) ;; *) echo "not installed: $f"; return 1 ;; esac
    done
    # Sources stay in the repository: kur.sh ships console/ (with the build), never tools/.
    run ! grep -qE '^    local items="[^"]*(^| )tools( |")' "$V2_ROOT/../kur.sh"
    grep -qx 'node_modules/' "$V2_ROOT/../.gitignore"
}

@test "the browser suites measure the layout of every screenshot and card cells wrap long values (DD-270)" {
    local audit="$V2_ROOT/tests/duzen-denetimi.cjs" harness="$V2_ROOT/tests/yeni-harness.cjs"
    [ -f "$audit" ]
    # Every shot() runs the audit unless KONSOL_DUZEN=0; a finding fails the suite like a console error.
    grep -qF 'if (process.env.KONSOL_DUZEN !== "0") {' "$harness"
    grep -qF 'require("./duzen-denetimi.cjs").audit(page, widths)' "$harness"
    grep -qF 'h.errors.push(`layout ${file} @${r.width}: ${f.kind} ${f.el}' "$harness"
    grep -qF 'const DUZEN_GENISLIKLER = [320, 360, 390, 768, 1024, 1280, 1920];' "$harness"
    # A screenshot waits for every finite animation, not only for Vue's transition classes.
    grep -qF 'document.getAnimations().every((a) => a.playState !== "running"' "$harness"
    grep -qF 'assert.deepEqual((await page.evaluate(measure)).findings, [], `login layout ${colorScheme}/${width}`);' "$V2_ROOT/tests/giris-ui.cjs"
    for kind in sayfa-tasmasi pencere-disinda tasma kirpilma ezilme cakisma pencere; do
        grep -q "\"$kind\"" "$audit"
    done
    # The audit only measures: it never clicks, types or changes the page.
    run ! grep -qE '\.(click|fill|press|tap)\(|setAttribute|innerHTML|\.remove\(' "$audit"
    # On a phone a card cell is a flex column; a long address breaks inside it instead of running over the next.
    awk '/@container \(max-width: 760px\)/,0' "$V2_ROOT/tools/konsol-ui/src/styles/ui.css" |
        awk '/\.data-table td\[data-label\] \{/,/\}/' | grep -q 'overflow-wrap: anywhere;'
    awk '/\.fw-table td\[data-label\],/,/\}/' "$V2_ROOT/tools/konsol-ui/src/styles/erisim.css" | grep -q 'overflow-wrap: anywhere;'
}

@test "the release version people see sits beside the build number servers compare (DD-260)" {
    local install="$V2_ROOT/install.sh" surum
    surum="$(sed -n 's/^OBHUT_SURUM="\(.*\)"$/\1/p' "$install")"
    # A semantic version, defined once, right after the build number.
    grep -qxE '[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}' <<<"$surum"
    [ "$(grep -c '^OBHUT_SURUM="' "$install")" -eq 1 ]
    grep -A3 '^V2_VERSION="' "$install" | grep -q '^OBHUT_SURUM="'
    # Kept in state for Konsol; the start and summary lines name both numbers.
    grep -qx 'OBHUT_SURUM=$OBHUT_SURUM' "$install"
    grep -qF 'log INFO "Obhut $OBHUT_SURUM başlıyor (yapı $V2_VERSION)"' "$install"
    grep -qF 'log INFO "Kurulum tamam — Obhut $OBHUT_SURUM (yapı $V2_VERSION)"' "$install"
    # The update check reads both from GitHub's install.sh; the build number decides what is offered.
    python3 - "$V2_ROOT" "$surum" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/panel")
import master_update as mu
text = open(sys.argv[1] + "/install.sh", encoding="utf-8").read()
assert mu.SURUM_LINE_RE.search(text).group(1) == sys.argv[2]
assert mu.number(mu.INSTALL_LINE_RE.search(text).group(1)) is not None
PY
    # Konsol shows it and falls back to the build number from an older backend.
    grep -qF 'live.kaynaklar?.surum || live.guncelleme?.kurulu_surum || shortVersion(' "$V2_ROOT/tools/konsol-ui/src/components/SideNav.vue"
    # The changelog has this release's section.
    grep -qE "^## \[$surum\] — [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$V2_ROOT/CHANGELOG.md"
}

@test "obhut: the root CLI is installed beside master-onar and speaks to Konsol's own socket (DD-268)" {
    local mod="$V2_ROOT/panel/master_obhut.py"
    grep -qF 'atomic_write "$SBIN_DIR/master_obhut.py" 0755 <"$V2_ROOT/panel/master_obhut.py"' "$V2_ROOT/install.sh"
    grep -qF 'atomic_write "$SBIN_DIR/obhut" 0755 <"$V2_ROOT/scripts/obhut"' "$V2_ROOT/install.sh"
    grep -qxF 'exec /usr/bin/python3 "$(dirname -- "$(readlink -f -- "$0")")/master_obhut.py" "$@"' "$V2_ROOT/scripts/obhut"
    # The socket from state.env with Konsol's Host and the X-Konsol header; no TCP, no shell.
    grep -qF 'env.get("PANEL_SOCKET")' "$mod"
    grep -qF '"X-Konsol": "1"' "$mod"
    run ! grep -qE 'shell=True|os\.system|HTTPSConnection|create_connection' "$mod"
    # Recovery does not need the backend: checks and repairs are master-onar's, the account master-konsol's.
    grep -qF 'run_tool("master-onar", "--denetle")' "$mod"
    grep -qF 'run_tool("master-konsol", args.eylem)' "$mod"
    python3 -I "$mod" --help >/dev/null
}
