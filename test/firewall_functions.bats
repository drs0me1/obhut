#!/usr/bin/env bats
# Unit tests for pure-logic firewall-state functions embedded in
# docker-tailscale-fw (itself a heredoc inside install.sh — see
# SECURITY_REVIEW.md finding H4/M7, docs/testing.md Tier 2).
#
# Like test/reconcile_functions.bats, this never sources or executes the
# full docker-tailscale-fw script: its top level takes a `flock` and can
# call `exit`, which is unsafe outside a real, provisioned host. Only the
# named function *bodies* below are extracted and sourced in isolation:
# route_value (route parsing) and five predicate functions that each take
# an iptables/ip6tables binary path as their first argument and only ever
# call it with `-S`/`-C` to read state — never to mutate firewall rules.
# Fake stand-in functions replace real `ip`/iptables/ip6tables throughout:
# no root, no real firewall or routing state touched, and install.sh is
# never modified or executed.

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
    {
        extract_function FW_SCRIPT route_value
        extract_function FW_SCRIPT resolve_wan_ipv4
        extract_function FW_SCRIPT wait_for_wan_ipv4
        extract_function FW_SCRIPT chain_rules_exact
        extract_function FW_SCRIPT jump_is_first_and_single
        extract_function FW_SCRIPT forward_prefix_is_exact
        extract_function FW_SCRIPT docker_forward_has_no_terminal_drop
        extract_function FW_SCRIPT no_stale_staging_chains
    } >"$FUNCS_FILE"

    # Fail loudly if install.sh's function source ever moves/renames in a
    # way this extraction can no longer find, rather than silently testing
    # empty no-op functions.
    grep -q '^route_value() {' "$FUNCS_FILE"
    grep -q '^resolve_wan_ipv4() {' "$FUNCS_FILE"
    grep -q '^wait_for_wan_ipv4() {' "$FUNCS_FILE"
    grep -q '^chain_rules_exact() {' "$FUNCS_FILE"
    grep -q '^jump_is_first_and_single() {' "$FUNCS_FILE"
    grep -q '^forward_prefix_is_exact() {' "$FUNCS_FILE"
    grep -q '^docker_forward_has_no_terminal_drop() {' "$FUNCS_FILE"
    grep -q '^no_stale_staging_chains() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    AWK_BIN="$(command -v awk)"

    # Stand-in for iptables/ip6tables: the functions under test only ever
    # call "$bin" with `-w 5 [-t table] -S [chain]` (read a chain's rules)
    # or `-w 5 -C ...` (test whether an exact rule exists). Real iptables
    # is never invoked, so tests never touch actual firewall state and
    # never need root. FAKE_S_OUTPUT/FAKE_C_EXIT are set per test.
    FAKE_S_OUTPUT=""
    FAKE_C_EXIT=1
    fake_bin() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == "-S" ]]; then
                printf '%s' "$FAKE_S_OUTPUT"
                return 0
            fi
            if [[ "$arg" == "-C" ]]; then
                return "$FAKE_C_EXIT"
            fi
        done
        return 0
    }

    # Stand-in for `ip` (used by route_value): prints canned `ip route get`
    # output regardless of args, set per test via FAKE_ROUTE_OUTPUT.
    # FAKE_IP_DELAY makes each simulated `ip` call cost real wall-clock
    # time, which is what lets the wait_for_wan_ipv4 deadline tests tell a
    # time-bounded loop apart from an iteration-bounded one.
    FAKE_ROUTE_OUTPUT=""
    FAKE_IP_DELAY=0
    IP_BIN="fake_ip"
    fake_ip() {
        [ "$FAKE_IP_DELAY" = "0" ] || sleep "$FAKE_IP_DELAY"
        printf '%s' "$FAKE_ROUTE_OUTPUT"
    }
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# --- route_value ---
# The reusable parsing helper behind detect_ipv4_route's WAN4_IF/PUBLIC_IPV4
# detection and the script's own WAN6_IF detection (install.sh, Stage 2 /
# docker-tailscale-fw). detect_ipv4_route itself lives in install.sh's
# outer script (not a heredoc) and calls `exit` on failure, so it's already
# covered directly by `bash -n install.sh`/`shellcheck install.sh` and isn't
# a good fit for this extraction technique; this tests the shared parsing
# logic it (and WAN6_IF detection) is built on instead.

@test "route_value: extracts the outgoing interface (dev)" {
    FAKE_ROUTE_OUTPUT='1.1.1.1 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'

    run route_value -4 1.1.1.1 dev
    [ "$status" -eq 0 ]
    [ "$output" = "eth0" ]
}

@test "route_value: extracts the source address (src)" {
    FAKE_ROUTE_OUTPUT='1.1.1.1 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'

    run route_value -4 1.1.1.1 src
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.2.15" ]
}

@test "route_value: prints nothing when the keyword is absent" {
    FAKE_ROUTE_OUTPUT='1.1.1.1 via 10.0.2.2 dev eth0 uid 0'

    run route_value -4 1.1.1.1 src
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "route_value: prints nothing when there is no route (empty ip output)" {
    FAKE_ROUTE_OUTPUT=''

    run route_value -6 2001:4860:4860::8888 dev
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# --- resolve_wan_ipv4 / wait_for_wan_ipv4 ---
# The helper's WAN IPv4 readiness gate. `apply` waits for the addresses
# because PUBLIC_IPV4 is interpolated into three MASTER-DOCKER rules;
# `--check` resolves them once and reports drift immediately rather than
# sleeping (see docs/design-decisions.md DD-52). resolve_wan_ipv4 is called
# directly rather than through `run`, because `run`'s subshell would discard
# the WAN4_IF/PUBLIC_IPV4 assignments the function exists to make.

@test "resolve_wan_ipv4: true, and sets both values, from a complete route" {
    FAKE_ROUTE_OUTPUT='1.1.1.1 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'
    WAN4_IF=""
    PUBLIC_IPV4=""

    resolve_wan_ipv4
    [ "$WAN4_IF" = "eth0" ]
    [ "$PUBLIC_IPV4" = "10.0.2.15" ]
}

@test "resolve_wan_ipv4: false when there is no route at all" {
    FAKE_ROUTE_OUTPUT=''
    WAN4_IF=""
    PUBLIC_IPV4=""

    # Not `! resolve_wan_ipv4`: bash exempts an `!`-inverted command from
    # `set -e`, so that form only fails a test when it is the last line.
    # Capturing the status keeps the assertion live and keeps the function's
    # WAN4_IF/PUBLIC_IPV4 side effects, which `run`'s subshell would discard.
    rc=0
    resolve_wan_ipv4 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$WAN4_IF" = "" ]
    [ "$PUBLIC_IPV4" = "" ]
}

@test "resolve_wan_ipv4: false when the route has an interface but no source" {
    FAKE_ROUTE_OUTPUT='1.1.1.1 via 10.0.2.2 dev eth0 uid 0'
    WAN4_IF=""
    PUBLIC_IPV4=""

    rc=0
    resolve_wan_ipv4 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$WAN4_IF" = "eth0" ]
    [ "$PUBLIC_IPV4" = "" ]
}

@test "wait_for_wan_ipv4: returns at once when the addresses are present" {
    FAKE_ROUTE_OUTPUT='1.1.1.1 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0'
    WAN_ADDRESS_WAIT_SECONDS=30
    SECONDS=0

    wait_for_wan_ipv4
    [ "$SECONDS" -lt 2 ]
}

@test "wait_for_wan_ipv4: gives up on wall-clock time, not on iteration count" {
    # Each simulated `ip` call costs a second and resolve_wan_ipv4 makes two
    # of them, so an iteration-bounded loop would run far past the deadline
    # it prints. The lower bound is asserted too: without it the case would
    # also pass against a loop that never waited at all.
    FAKE_ROUTE_OUTPUT=''
    FAKE_IP_DELAY=1
    WAN_ADDRESS_WAIT_SECONDS=3
    SECONDS=0

    rc=0
    wait_for_wan_ipv4 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$SECONDS" -ge 3 ]
    [ "$SECONDS" -le 8 ]
}

# --- the removed Tailscale IPv4 gate (DD-52) ---
# Structural, because the gate is top-level code in the heredoc rather than
# a function the extraction technique above can reach.

@test "docker-tailscale-fw: no longer resolves a Tailscale IPv4 it never uses" {
    run bash -c "sed -n \"/<<'FW_SCRIPT'\\\$/,/^FW_SCRIPT\\\$/p\" '$INSTALL_SH' |
        grep -c 'TAILSCALE_IPV4' || true"
    [ "$output" = "0" ]
}

@test "docker-tailscale-fw: --check never reaches the waiting path" {
    body="$(sed -n "/<<'FW_SCRIPT'\$/,/^FW_SCRIPT\$/p" "$INSTALL_SH")"

    # Exactly two mentions: the definition and the single non---check call.
    [ "$(grep -c 'wait_for_wan_ipv4' <<<"$body")" -eq 2 ]
    [ "$(grep -c '^elif ! wait_for_wan_ipv4; then$' <<<"$body")" -eq 1 ]
    [ "$(grep -c '^if \[\[ "\$MODE" == "--check" \]\]; then$' <<<"$body")" -eq 2 ]
}

# --- chain_rules_exact ---

@test "chain_rules_exact: true when the chain's rules exactly match" {
    FAKE_S_OUTPUT=$'-N MASTER-DOCKER\n-A DOCKER-USER -j MASTER-DOCKER\n'

    run chain_rules_exact fake_bin filter DOCKER-USER \
        "-A DOCKER-USER -j MASTER-DOCKER"
    [ "$status" -eq 0 ]
}

@test "chain_rules_exact: false when a rule is missing" {
    FAKE_S_OUTPUT=$'-N MASTER-DOCKER\n'

    run chain_rules_exact fake_bin filter DOCKER-USER \
        "-A DOCKER-USER -j MASTER-DOCKER"
    [ "$status" -ne 0 ]
}

@test "chain_rules_exact: false when there is an unexpected extra rule" {
    FAKE_S_OUTPUT=$'-A DOCKER-USER -j MASTER-DOCKER\n-A DOCKER-USER -j SOME-OTHER-CHAIN\n'

    run chain_rules_exact fake_bin filter DOCKER-USER \
        "-A DOCKER-USER -j MASTER-DOCKER"
    [ "$status" -ne 0 ]
}

# --- jump_is_first_and_single ---

@test "jump_is_first_and_single: true when the jump is first and appears once" {
    FAKE_S_OUTPUT=$'-N MASTER-TS-FORWARD\n-A FORWARD -j MASTER-TS-FORWARD\n-A FORWARD -j DOCKER-USER\n'

    run jump_is_first_and_single fake_bin mangle FORWARD MASTER-TS-FORWARD
    [ "$status" -eq 0 ]
}

@test "jump_is_first_and_single: false when another jump precedes it" {
    FAKE_S_OUTPUT=$'-A FORWARD -j DOCKER-USER\n-A FORWARD -j MASTER-TS-FORWARD\n'

    run jump_is_first_and_single fake_bin mangle FORWARD MASTER-TS-FORWARD
    [ "$status" -ne 0 ]
}

@test "jump_is_first_and_single: false when the jump is duplicated" {
    FAKE_S_OUTPUT=$'-A FORWARD -j MASTER-TS-FORWARD\n-A FORWARD -j MASTER-TS-FORWARD\n'

    run jump_is_first_and_single fake_bin mangle FORWARD MASTER-TS-FORWARD
    [ "$status" -ne 0 ]
}

@test "jump_is_first_and_single: false when the jump is absent" {
    FAKE_S_OUTPUT=$'-A FORWARD -j DOCKER-USER\n'

    run jump_is_first_and_single fake_bin mangle FORWARD MASTER-TS-FORWARD
    [ "$status" -ne 0 ]
}

# --- forward_prefix_is_exact ---

@test "forward_prefix_is_exact: true for the exact expected 3-rule prefix" {
    FAKE_S_OUTPUT=$'-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j ts-forward\n'

    run forward_prefix_is_exact fake_bin
    [ "$status" -eq 0 ]
}

@test "forward_prefix_is_exact: false when the prefix order is wrong" {
    FAKE_S_OUTPUT=$'-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j DOCKER-USER\n-A FORWARD -j ts-forward\n'

    run forward_prefix_is_exact fake_bin
    [ "$status" -ne 0 ]
}

@test "forward_prefix_is_exact: false when a jump target is duplicated" {
    FAKE_S_OUTPUT=$'-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j ts-forward\n-A FORWARD -j DOCKER-USER\n'

    run forward_prefix_is_exact fake_bin
    [ "$status" -ne 0 ]
}

# --- docker_forward_has_no_terminal_drop ---

@test "docker_forward_has_no_terminal_drop: true when rules exist with no DROP/REJECT" {
    FAKE_S_OUTPUT=$'-N DOCKER-FORWARD\n-A DOCKER-FORWARD -j DOCKER-BRIDGE\n'

    run docker_forward_has_no_terminal_drop fake_bin
    [ "$status" -eq 0 ]
}

@test "docker_forward_has_no_terminal_drop: false when a DROP rule is present" {
    FAKE_S_OUTPUT=$'-A DOCKER-FORWARD -j DOCKER-BRIDGE\n-A DOCKER-FORWARD -j DROP\n'

    run docker_forward_has_no_terminal_drop fake_bin
    [ "$status" -ne 0 ]
}

@test "docker_forward_has_no_terminal_drop: false when the chain has no rules" {
    FAKE_S_OUTPUT=""

    run docker_forward_has_no_terminal_drop fake_bin
    [ "$status" -ne 0 ]
}

# --- no_stale_staging_chains ---

@test "no_stale_staging_chains: true when no stale staging chain exists" {
    FAKE_S_OUTPUT=$'-N MASTER-DOCKER\n-N MASTER-TS-FORWARD\n-A DOCKER-USER -j MASTER-DOCKER\n'

    run no_stale_staging_chains fake_bin filter
    [ "$status" -eq 0 ]
}

@test "no_stale_staging_chains: false when a stale MASTER-NEXT- chain exists" {
    FAKE_S_OUTPUT=$'-N MASTER-DOCKER\n-N MASTER-NEXT-abc123\n'

    run no_stale_staging_chains fake_bin filter
    [ "$status" -ne 0 ]
}

@test "no_stale_staging_chains: false when a stale MASTER-TS-NEXT- chain exists" {
    FAKE_S_OUTPUT=$'-N MASTER-TS-FORWARD\n-N MASTER-TS-NEXT-abc123\n'

    run no_stale_staging_chains fake_bin mangle
    [ "$status" -ne 0 ]
}
