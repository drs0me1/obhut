#!/usr/bin/env bats
# Unit tests for check_ipv4_policy() and check_ipv6_policy(), the two
# composite verifiers embedded in docker-tailscale-fw (a heredoc inside
# install.sh — see SECURITY_REVIEW.md H4/M7, docs/testing.md Tier 2).
#
# These two functions are where the project's entire expected firewall
# rule set is written down: the exact contents and ordering of
# MASTER-TS-FORWARD and MASTER-DOCKER, the required FORWARD prefix, the
# absence of legacy wide rules and stale staging chains. They are also
# what `docker-tailscale-fw --check` returns, which reconcile trusts
# wholesale when deciding whether the firewall has drifted.
#
# docs/testing.md previously assumed these were too integration-shaped to
# unit-test and left them to Tier 3. That turned out to be too
# pessimistic: like the five predicates in test/firewall_functions.bats,
# they only ever read state — `-S` to list a chain, `-C` to test whether
# one exact rule exists — and everything else they depend on
# (TS_GUARD_CHAIN, POLICY_CHAIN, WAN4_IF, WAN6_IF, PUBLIC_IPV4,
# TAILSCALE_IPV4) is a plain global a test can assign. So a fake stand-in
# is enough; no root, no real firewall, no host.
#
# WHAT THESE TESTS DO PROVE: that the verifier accepts a correct firewall
# and rejects each specific way it can be wrong — a missing terminal
# DROP, a jump that isn't first, a duplicated jump, an extra rule
# appended to DOCKER-USER, a leftover staging chain, a resurrected legacy
# wide rule, a resurrected narrow WebDAV allow (removed in V1-3).
#
# WHAT THEY DO NOT PROVE: that the *apply* path (apply_ipv4 /
# apply_tailnet_guard) actually produces the rules these verifiers
# expect. The healthy fixture below restates the expected rule set, so if
# someone changes check_ipv4_policy's expectations the healthy case fails
# — a deliberate signal to re-confirm the fixture still describes real
# policy, not a proof that apply and check agree. Verifying that coupling
# would mean driving apply_ipv4 through a recording fake, which its
# staging-chain activation loops make impractical; that remains Tier 3's
# job, and the live install does exercise it end to end.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# See test/reconcile_functions.bats for the rationale behind this
# extraction approach.
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

# Shared stand-in for iptables/ip6tables. Dispatches on the family prefix
# (4 or 6) plus the -t table and the -S chain, so v4 and v6 state can be
# set independently in one test. Deliberately avoids bash associative
# arrays: this workstation's /bin/bash is 3.2, and test/gro_functions.bats
# already self-skips entirely for that reason — these tests should not.
_fake_dispatch() {
    local family="$1"
    shift
    local table="filter" chain="" mode="" n=$# i=0
    local -a argv=("$@")

    for (( i = 0; i < n; i++ )); do
        case "${argv[i]}" in
            -t) table="${argv[i + 1]}" ;;
            -S) mode="S"; (( i + 1 < n )) && chain="${argv[i + 1]}" ;;
            -C) mode="C" ;;
            -L) mode="L" ;;
        esac
    done

    case "$mode" in
        C)
            # Only ever used to probe for the legacy wide DOCKER-USER
            # rules; a non-zero exit means "rule absent", which is the
            # healthy state.
            local c_var="FAKE${family}_C_EXIT"
            return "${!c_var:-1}"
            ;;
        L)
            return 0
            ;;
    esac

    local var="FAKE${family}_${table}_${chain:-ALL}"
    var="${var//-/_}"
    printf '%s' "${!var:-}"
}

fake4_bin() { _fake_dispatch 4 "$@"; }
fake6_bin() { _fake_dispatch 6 "$@"; }

# Loads the healthy IPv4 firewall picture: what a correctly applied
# policy looks like on a host whose WAN interface is eth0, public address
# 203.0.113.5 and Tailscale address 100.64.0.5.
load_healthy_ipv4() {
    WAN4_IF="eth0"
    PUBLIC_IPV4="203.0.113.5"
    TAILSCALE_IPV4="100.64.0.5"

    FAKE4_mangle_FORWARD=$'-P FORWARD ACCEPT\n-A FORWARD -j MASTER-TS-FORWARD'
    FAKE4_filter_FORWARD=$'-P FORWARD DROP\n-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j ts-forward'
    FAKE4_filter_DOCKER_FORWARD=$'-N DOCKER-FORWARD\n-A DOCKER-FORWARD -j DOCKER-CT'
    FAKE4_filter_DOCKER_USER=$'-N DOCKER-USER\n-A DOCKER-USER -j MASTER-DOCKER'
    FAKE4_mangle_MASTER_TS_FORWARD=$'-N MASTER-TS-FORWARD\n-A MASTER-TS-FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A MASTER-TS-FORWARD -i tailscale0 -o eth0 -j MARK --set-xmark 0x40000/0xff0000\n-A MASTER-TS-FORWARD -i tailscale0 -o eth0 -j ACCEPT\n-A MASTER-TS-FORWARD -i tailscale0 -j DROP\n-A MASTER-TS-FORWARD -o tailscale0 -j DROP\n-A MASTER-TS-FORWARD -j RETURN'
    FAKE4_filter_MASTER_DOCKER=$'-N MASTER-DOCKER\n-A MASTER-DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n-A MASTER-DOCKER -i tailscale0 -o eth0 -j ACCEPT\n-A MASTER-DOCKER -o tailscale0 -j DROP\n-A MASTER-DOCKER -i eth0 -p tcp -m conntrack --ctstate NEW --ctorigdst 203.0.113.5 --ctorigdstport 65173 -j RETURN\n-A MASTER-DOCKER -i eth0 -p udp -m conntrack --ctstate NEW --ctorigdst 203.0.113.5 --ctorigdstport 65173 -j RETURN\n-A MASTER-DOCKER -i eth0 -p udp -m conntrack --ctstate NEW --ctorigdst 203.0.113.5 --ctorigdstport 65171 -j RETURN\n-A MASTER-DOCKER -i eth0 -j DROP\n-A MASTER-DOCKER -j RETURN'
    # Whole-table dumps, used only by no_stale_staging_chains.
    FAKE4_mangle_ALL=$'-P FORWARD ACCEPT\n-N MASTER-TS-FORWARD'
    FAKE4_filter_ALL=$'-P FORWARD DROP\n-N DOCKER-USER\n-N MASTER-DOCKER'
    FAKE4_C_EXIT=1
}

load_healthy_ipv6() {
    WAN6_IF="eth0"
    FAKE6_mangle_FORWARD=$'-P FORWARD ACCEPT\n-A FORWARD -j MASTER-TS-FORWARD'
    FAKE6_filter_FORWARD=$'-P FORWARD DROP\n-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j ts-forward'
    FAKE6_filter_DOCKER_FORWARD=$'-N DOCKER-FORWARD\n-A DOCKER-FORWARD -j DOCKER-CT'
    FAKE6_filter_DOCKER_USER=$'-N DOCKER-USER\n-A DOCKER-USER -j MASTER-DOCKER'
    FAKE6_mangle_MASTER_TS_FORWARD=$'-N MASTER-TS-FORWARD\n-A MASTER-TS-FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A MASTER-TS-FORWARD -i tailscale0 -o eth0 -j MARK --set-xmark 0x40000/0xff0000\n-A MASTER-TS-FORWARD -i tailscale0 -o eth0 -j ACCEPT\n-A MASTER-TS-FORWARD -i tailscale0 -j DROP\n-A MASTER-TS-FORWARD -o tailscale0 -j DROP\n-A MASTER-TS-FORWARD -j RETURN'
    FAKE6_filter_MASTER_DOCKER=$'-N MASTER-DOCKER\n-A MASTER-DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n-A MASTER-DOCKER -i tailscale0 -o eth0 -j ACCEPT\n-A MASTER-DOCKER -o tailscale0 -j DROP\n-A MASTER-DOCKER -i eth0 -j DROP\n-A MASTER-DOCKER -j RETURN'
    FAKE6_mangle_ALL=$'-P FORWARD ACCEPT\n-N MASTER-TS-FORWARD'
    FAKE6_filter_ALL=$'-P FORWARD DROP\n-N DOCKER-USER\n-N MASTER-DOCKER'
    FAKE6_C_EXIT=1
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    {
        extract_function FW_SCRIPT chain_rules_exact
        extract_function FW_SCRIPT jump_is_first_and_single
        extract_function FW_SCRIPT forward_prefix_is_exact
        extract_function FW_SCRIPT docker_forward_has_no_terminal_drop
        extract_function FW_SCRIPT no_stale_staging_chains
        extract_function FW_SCRIPT check_ipv4_policy
        extract_function FW_SCRIPT check_ipv6_policy
    } >"$FUNCS_FILE"

    # Fail loudly if extraction stops finding these, rather than silently
    # testing empty no-ops.
    grep -q '^check_ipv4_policy() {' "$FUNCS_FILE"
    grep -q '^check_ipv6_policy() {' "$FUNCS_FILE"
    grep -q '^no_stale_staging_chains() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    AWK_BIN="$(command -v awk)"
    IPTABLES_BIN="fake4_bin"
    IP6TABLES_BIN="fake6_bin"
    POLICY_CHAIN="MASTER-DOCKER"
    TS_GUARD_CHAIN="MASTER-TS-FORWARD"
    TS_IF="tailscale0"

    load_healthy_ipv4
    load_healthy_ipv6
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# --- check_ipv4_policy ---

@test "check_ipv4_policy: accepts a fully correct policy" {
    run check_ipv4_policy
    [ "$status" -eq 0 ]
}

@test "check_ipv4_policy: rejects a missing terminal WAN DROP" {
    # The fail-closed backbone: without this rule any WAN forward traffic
    # not matching an explicit allow would pass instead of being dropped.
    FAKE4_filter_MASTER_DOCKER="${FAKE4_filter_MASTER_DOCKER/$'\n-A MASTER-DOCKER -i eth0 -j DROP'/}"

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a missing Tailnet-to-Docker DROP" {
    FAKE4_mangle_MASTER_TS_FORWARD="${FAKE4_mangle_MASTER_TS_FORWARD/$'\n-A MASTER-TS-FORWARD -i tailscale0 -j DROP'/}"

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a mangle jump that is not first" {
    FAKE4_mangle_FORWARD=$'-P FORWARD ACCEPT\n-A FORWARD -j SOMETHING-ELSE\n-A FORWARD -j MASTER-TS-FORWARD'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a duplicated DOCKER-USER jump" {
    FAKE4_filter_DOCKER_USER=$'-N DOCKER-USER\n-A DOCKER-USER -j MASTER-DOCKER\n-A DOCKER-USER -j MASTER-DOCKER'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects an extra rule appended to DOCKER-USER" {
    # DOCKER-USER belongs wholly to this policy; anything added after the
    # jump could short-circuit the allowed flows.
    FAKE4_filter_DOCKER_USER=$'-N DOCKER-USER\n-A DOCKER-USER -j MASTER-DOCKER\n-A DOCKER-USER -j DROP'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a resurrected legacy wide RETURN rule" {
    # -C succeeding means the rule exists, which is what the legacy
    # cleanup path is there to prevent.
    FAKE4_C_EXIT=0

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a leftover staging chain in mangle" {
    FAKE4_mangle_ALL=$'-P FORWARD ACCEPT\n-N MASTER-TS-FORWARD\n-N MASTER-TS-NEXT-12345'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a leftover staging chain in filter" {
    FAKE4_filter_ALL=$'-P FORWARD DROP\n-N DOCKER-USER\n-N MASTER-DOCKER\n-N MASTER-NEXT-4242'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a terminal DROP inside DOCKER-FORWARD" {
    FAKE4_filter_DOCKER_FORWARD=$'-N DOCKER-FORWARD\n-A DOCKER-FORWARD -j DROP'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a resurrected narrow WebDAV allow" {
    # V1-3 moved WebDAV to a host service, so the Tailnet guard chain has
    # no exceptions left at all. An old-style --ctorigdst allow reappearing
    # (a stale helper, a partial upgrade) must read as drift, not be
    # tolerated as harmless.
    FAKE4_mangle_MASTER_TS_FORWARD="${FAKE4_mangle_MASTER_TS_FORWARD/$'-A MASTER-TS-FORWARD -i tailscale0 -j DROP'/$'-A MASTER-TS-FORWARD -i tailscale0 -p tcp -m conntrack --ctstate NEW --ctorigdst 100.64.0.5 --ctorigdstport 65113 -j ACCEPT\n-A MASTER-TS-FORWARD -i tailscale0 -j DROP'}"

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv4_policy: rejects a wrong FORWARD prefix order" {
    FAKE4_filter_FORWARD=$'-P FORWARD DROP\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j DOCKER-USER\n-A FORWARD -j ts-forward'

    run check_ipv4_policy
    [ "$status" -ne 0 ]
}

# --- check_ipv6_policy ---

@test "check_ipv6_policy: accepts a fully correct policy with an IPv6 WAN" {
    run check_ipv6_policy
    [ "$status" -eq 0 ]
}

@test "check_ipv6_policy: accepts the reduced rule set when there is no IPv6 WAN" {
    # With no IPv6 default route the exit-node and WAN-DROP rules are
    # deliberately absent, and the expected set shrinks to match.
    WAN6_IF=""
    FAKE6_mangle_MASTER_TS_FORWARD=$'-N MASTER-TS-FORWARD\n-A MASTER-TS-FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A MASTER-TS-FORWARD -i tailscale0 -j DROP\n-A MASTER-TS-FORWARD -o tailscale0 -j DROP\n-A MASTER-TS-FORWARD -j RETURN'
    FAKE6_filter_MASTER_DOCKER=$'-N MASTER-DOCKER\n-A MASTER-DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n-A MASTER-DOCKER -o tailscale0 -j DROP\n-A MASTER-DOCKER -j RETURN'

    run check_ipv6_policy
    [ "$status" -eq 0 ]
}

@test "check_ipv6_policy: reports a specific diagnostic when ip6tables is missing" {
    # M5: this must not be masked behind the generic policy-drift error.
    IP6TABLES_BIN=""

    run check_ipv6_policy
    [ "$status" -ne 0 ]
    [[ "$output" == *"ip6tables bulunamadı"* ]]
}

@test "check_ipv6_policy: rejects a missing Tailnet egress DROP" {
    FAKE6_filter_MASTER_DOCKER="${FAKE6_filter_MASTER_DOCKER/$'\n-A MASTER-DOCKER -o tailscale0 -j DROP'/}"

    run check_ipv6_policy
    [ "$status" -ne 0 ]
}

@test "check_ipv6_policy: rejects an IPv4-shaped rule set when an IPv6 WAN exists" {
    # Guards against the two families' expected sets being conflated. This
    # swaps the *policy* chain, not the guard chain: since V1-3 removed the
    # v4-only WebDAV allow, both families' guard chains are legitimately
    # identical, and the remaining real difference is that only v4 carries
    # the public qBittorrent/wg-easy port RETURNs and the WAN DROP.
    FAKE6_filter_MASTER_DOCKER="$FAKE4_filter_MASTER_DOCKER"

    run check_ipv6_policy
    [ "$status" -ne 0 ]
}
