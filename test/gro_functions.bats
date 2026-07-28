#!/usr/bin/env bats
# Unit tests for the pure-logic helper function embedded in
# tailscale-udp-gro (itself a heredoc inside install.sh — see
# SECURITY_REVIEW.md finding H4/M7, docs/testing.md Tier 2).
#
# Like test/reconcile_functions.bats and test/firewall_functions.bats, this
# never sources or executes the full tailscale-udp-gro script: its top
# level calls real `ethtool`/`ip` against actual network interfaces, which
# is unsafe outside a real, provisioned host. Only add_default_netdev()'s
# body is extracted and sourced in isolation, then exercised against a fake
# `ip` stand-in — no root, no real routing state touched, and install.sh is
# never modified or executed.
#
# The other three embedded scripts surveyed alongside this one
# (master-compose-ipv4, master-docker-netfilter-recovery, caddy-tailnet-env)
# have no standalone functions and are almost entirely wait-loops plus real
# side effects (sleep/flock/systemctl/file writes) with no isolable pure
# logic — see docs/testing.md for why they're left to Tier 3 instead.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# See test/reconcile_functions.bats for the rationale behind this
# extraction approach (marker heredoc range, then isolate one function by
# name up to its matching top-level closing brace).
extract_function() {
    local marker="$1" func_name="$2"
    sed -n "/<<'${marker}'\$/,/^${marker}\$/p" "$INSTALL_SH" |
        sed '1d;$d' |
        awk -v fn="$func_name" '
            $0 == fn "() {" { found=1 }
            found { print }
            found && /^}/ { exit }
        '
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    extract_function GRO_SCRIPT add_default_netdev >"$FUNCS_FILE"

    # Fail loudly if install.sh's function source ever moves/renames in a
    # way this extraction can no longer find, rather than silently testing
    # an empty no-op function.
    grep -q '^add_default_netdev() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    AWK_BIN="$(command -v awk)"

    # Stand-in for `ip` (used by add_default_netdev via IP_BIN): prints
    # canned `ip <family> -o route get <probe>` output regardless of args,
    # set per test via FAKE_ROUTE_OUTPUT. Real `ip` is never invoked.
    FAKE_ROUTE_OUTPUT=""
    IP_BIN="fake_ip"
    fake_ip() {
        printf '%s' "$FAKE_ROUTE_OUTPUT"
    }

    # add_default_netdev's dedup guard reads/writes SEEN, an associative
    # array normally declared once at the top of the real script (bash 4+
    # only). This dev workstation's default /bin/bash is 3.2, which
    # pre-dates associative arrays entirely, unlike the Debian 13 target's
    # bash 5.x. Detect that gap here so affected tests can skip with a
    # clear reason instead of silently misbehaving under a plain array.
    HAS_ASSOC_ARRAYS=1
    if declare -gA SEEN=() 2>/dev/null; then
        NETDEVS=()
    else
        HAS_ASSOC_ARRAYS=0
    fi
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "add_default_netdev: adds the route's device on first sight" {
    [ "$HAS_ASSOC_ARRAYS" -eq 1 ] || skip "requires bash 4+ associative arrays (target platform is Debian 13's bash 5.x; this workstation's default /bin/bash is 3.2 without them)"
    FAKE_ROUTE_OUTPUT='8.8.8.8 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'

    add_default_netdev -4 8.8.8.8

    [ "${#NETDEVS[@]}" -eq 1 ]
    [ "${NETDEVS[0]}" = "eth0" ]
    [ "${SEEN[eth0]:-}" = "1" ]
}

@test "add_default_netdev: does not add the same device twice" {
    [ "$HAS_ASSOC_ARRAYS" -eq 1 ] || skip "requires bash 4+ associative arrays (target platform is Debian 13's bash 5.x; this workstation's default /bin/bash is 3.2 without them)"
    FAKE_ROUTE_OUTPUT='8.8.8.8 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'
    add_default_netdev -4 8.8.8.8

    FAKE_ROUTE_OUTPUT='2001:4860:4860::8888 via fe80::1 dev eth0 src 2001:db8::1'
    add_default_netdev -6 2001:4860:4860::8888

    [ "${#NETDEVS[@]}" -eq 1 ]
    [ "${NETDEVS[0]}" = "eth0" ]
}

@test "add_default_netdev: adds a second distinct device separately" {
    [ "$HAS_ASSOC_ARRAYS" -eq 1 ] || skip "requires bash 4+ associative arrays (target platform is Debian 13's bash 5.x; this workstation's default /bin/bash is 3.2 without them)"
    FAKE_ROUTE_OUTPUT='8.8.8.8 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'
    add_default_netdev -4 8.8.8.8

    FAKE_ROUTE_OUTPUT='2001:4860:4860::8888 via fe80::1 dev wg0 src 2001:db8::1'
    add_default_netdev -6 2001:4860:4860::8888

    [ "${#NETDEVS[@]}" -eq 2 ]
    [ "${NETDEVS[0]}" = "eth0" ]
    [ "${NETDEVS[1]}" = "wg0" ]
}

@test "add_default_netdev: adds nothing when there is no route (empty ip output)" {
    [ "$HAS_ASSOC_ARRAYS" -eq 1 ] || skip "requires bash 4+ associative arrays (target platform is Debian 13's bash 5.x; this workstation's default /bin/bash is 3.2 without them)"
    FAKE_ROUTE_OUTPUT=''

    add_default_netdev -4 8.8.8.8

    [ "${#NETDEVS[@]}" -eq 0 ]
}

@test "add_default_netdev: adds nothing when the route line has no dev field" {
    [ "$HAS_ASSOC_ARRAYS" -eq 1 ] || skip "requires bash 4+ associative arrays (target platform is Debian 13's bash 5.x; this workstation's default /bin/bash is 3.2 without them)"
    FAKE_ROUTE_OUTPUT='8.8.8.8 via 10.0.2.2 src 10.0.2.15 uid 0'

    add_default_netdev -4 8.8.8.8

    [ "${#NETDEVS[@]}" -eq 0 ]
}
