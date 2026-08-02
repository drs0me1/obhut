#!/usr/bin/env bats
# Unit tests for the second tier of reconcile helpers — the ones the M7
# inventory listed as "stub-able but with milder failure modes, worth
# doing, not urgent" and which had no coverage at all until now:
# port_binding_exists, docker_network_tuple, record_container_restart,
# forwarding_config_ok and gro_flags_ok.
#
# Same method as reconcile_functions.bats: the full reconcile script is
# never sourced (it runs real flock/systemctl/docker at its top level);
# only the named function bodies are extracted and exercised against
# fixtures and stub binaries. No root, no systemd, no Docker.
#
# What makes these worth testing despite the mild failure modes: four of
# the five reach the outside world through a *parsing* step, and parsing
# is where silent wrong answers live. `grep -Fx` versus `grep -F` decides
# whether a port check can be satisfied by a substring; `head -n 1`
# decides which network a multi-homed container reports; an awk program
# decides whether a commented-out sysctl line counts as configuration.
# None of those are visible in a live smoke test, because the healthy path
# looks identical either way.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

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

# Stub binaries that print a canned payload and exit with a chosen code,
# so each test states the outside world it is testing against inline
# rather than through shared fixture state.
#
# The two differ by stream, and the distinction is load-bearing: docker
# and ethtool write diagnostics to stderr, and each call site under test
# discards stderr with 2>/dev/null. A stub that put an error message on
# stdout would be feeding the parser text the real program never sends,
# and the failure-path tests would be testing the stub.
make_stub() {
    local path="$1" exit_code="$2" payload="$3"
    {
        printf '#!/bin/sh\n'
        printf 'cat <<%s\n' "STUB_PAYLOAD"
        printf '%s\n' "$payload"
        printf '%s\n' "STUB_PAYLOAD"
        printf 'exit %s\n' "$exit_code"
    } >"$path"
    chmod 0755 "$path"
}

make_err_stub() {
    local path="$1" exit_code="$2" payload="$3"
    {
        printf '#!/bin/sh\n'
        printf 'cat >&2 <<%s\n' "STUB_PAYLOAD"
        printf '%s\n' "$payload"
        printf '%s\n' "STUB_PAYLOAD"
        printf 'exit %s\n' "$exit_code"
    } >"$path"
    chmod 0755 "$path"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    {
        extract_function RECONCILE_SCRIPT port_binding_exists
        extract_function RECONCILE_SCRIPT docker_network_tuple
        extract_function RECONCILE_SCRIPT record_container_restart
        extract_function RECONCILE_SCRIPT restart_budget_available
        extract_function RECONCILE_SCRIPT forwarding_config_ok
        extract_function RECONCILE_SCRIPT gro_flags_ok
    } >"$FUNCS_FILE"

    # Fail loudly rather than silently testing an empty no-op if any of
    # these is renamed or its source moves out of extraction range.
    grep -q '^port_binding_exists() {' "$FUNCS_FILE"
    grep -q '^docker_network_tuple() {' "$FUNCS_FILE"
    grep -q '^record_container_restart() {' "$FUNCS_FILE"
    grep -q '^restart_budget_available() {' "$FUNCS_FILE"
    grep -q '^forwarding_config_ok() {' "$FUNCS_FILE"
    grep -q '^gro_flags_ok() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    DOCKER_BIN="$FIXTURE_DIR/docker"
    ETHTOOL_BIN="$FIXTURE_DIR/ethtool"
    REAL_AWK="$(command -v awk)"
    AWK_BIN="$REAL_AWK"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# --- port_binding_exists ---
#
# Reads `docker port <container> <port>` and requires one output line to
# equal the expected publish address exactly.

@test "port_binding_exists: accepts an exact published binding" {
    make_stub "$DOCKER_BIN" 0 '127.0.0.1:7113'

    run port_binding_exists filebrowser 80/tcp '127.0.0.1:7113'
    [ "$status" -eq 0 ]
}

@test "port_binding_exists: a longer address containing the expected one is not a match" {
    # The reason the call uses `grep -Fx` and not `grep -F`. With a
    # substring match, a binding on 10.0.0.1:71130 would satisfy a check
    # for 127.0.0.1:7113 — wrong host, wrong port, reported healthy.
    make_stub "$DOCKER_BIN" 0 '10.0.0.1:71130'

    run port_binding_exists filebrowser 80/tcp '0.0.0.1:7113'
    [ "$status" -ne 0 ]
}

@test "port_binding_exists: a bare port does not satisfy an address-qualified expectation" {
    # 0.0.0.0:7113 means published on every interface; 127.0.0.1:7113
    # means loopback only. Every web UI in this stack depends on the
    # difference, so the check must not treat them as interchangeable.
    make_stub "$DOCKER_BIN" 0 '0.0.0.0:7113'

    run port_binding_exists filebrowser 80/tcp '127.0.0.1:7113'
    [ "$status" -ne 0 ]
}

@test "port_binding_exists: matches when one of several bindings is the expected one" {
    # Dual-stack publishes list one line per family.
    make_stub "$DOCKER_BIN" 0 '[::1]:7113
127.0.0.1:7113'

    run port_binding_exists filebrowser 80/tcp '127.0.0.1:7113'
    [ "$status" -eq 0 ]
}

@test "port_binding_exists: reports missing when the port is not published" {
    make_stub "$DOCKER_BIN" 1 ''

    run port_binding_exists filebrowser 80/tcp '127.0.0.1:7113'
    [ "$status" -ne 0 ]
}

@test "port_binding_exists: reports missing when docker itself fails" {
    # A dead daemon must read as "binding absent", not as an error that
    # propagates: the caller's repair path is the right response either
    # way, and 2>/dev/null in the function is what makes it so.
    make_err_stub "$DOCKER_BIN" 125 'Cannot connect to the Docker daemon'

    run port_binding_exists filebrowser 80/tcp '127.0.0.1:7113'
    [ "$status" -ne 0 ]
}

# --- docker_network_tuple ---
#
# Emits "<network>|<ip>" for the container's first network. Feeds
# docker_dnat_rule_exists, which splits on the pipe.

@test "docker_network_tuple: emits network and address for a single-network container" {
    make_stub "$DOCKER_BIN" 0 'wg|10.42.42.42'

    run docker_network_tuple wg-easy
    [ "$status" -eq 0 ]
    [ "$output" = "wg|10.42.42.42" ]
}

@test "docker_network_tuple: returns only the first network of a multi-homed container" {
    # Documents the `head -n 1`: the caller derives one bridge interface
    # and one DNAT rule from this, so a second line would be silently
    # ignored downstream. Pinning it here makes the limitation a stated
    # contract rather than an accident of implementation.
    make_stub "$DOCKER_BIN" 0 'wg|10.42.42.42
bridge|172.17.0.2'

    run docker_network_tuple wg-easy
    [ "$output" = "wg|10.42.42.42" ]
}

@test "docker_network_tuple: emits nothing for a container with no networks" {
    make_stub "$DOCKER_BIN" 0 ''

    run docker_network_tuple wg-easy
    [ -z "$output" ]
}

@test "docker_network_tuple: emits nothing when the container is absent" {
    # docker writes "No such object" to stderr, which the function
    # discards. Nothing reaches the pipeline, so the caller's pipe guard
    # rejects the result rather than parsing an error string as a
    # network name.
    make_err_stub "$DOCKER_BIN" 1 'Error: No such object: wg-easy'

    run docker_network_tuple wg-easy
    [ -z "$output" ]
}

@test "docker_network_tuple: output without a pipe is rejected by the caller's guard" {
    # docker_dnat_rule_exists gates on [[ "$tuple" == *"|"* ]]. This pins
    # that a container on a network with no address assigned yet — which
    # the template renders as "name|" — still carries the separator, while
    # genuinely malformed output does not.
    make_stub "$DOCKER_BIN" 0 'wg|'
    run docker_network_tuple wg-easy
    [[ "$output" == *"|"* ]]

    make_stub "$DOCKER_BIN" 0 'unexpected'
    run docker_network_tuple wg-easy
    [[ "$output" != *"|"* ]]
}

# --- record_container_restart / restart_budget_available ---
#
# Tested as a pair. Nothing else pins that the writer and the reader agree
# on the stamp's filename and format, and DD-21 turns on that agreement:
# the cooldown is the only thing standing between a repeatedly-failing
# repair and a restart loop.

setup_restart_state() {
    RESTART_STATE_DIR="$FIXTURE_DIR/restart-state"
    RESTART_COOLDOWN_SECONDS=900
    # install(1)'s -o/-g need root. The stub keeps the directory creation
    # and its mode, drops the ownership arguments, and leaves everything
    # else about the function under test.
    INSTALL_BIN="$FIXTURE_DIR/install-stub"
    {
        printf '#!/bin/sh\n'
        printf 'args=""\n'
        printf 'while [ $# -gt 0 ]; do\n'
        printf '  case "$1" in\n'
        printf '    -o|-g) shift 2 ;;\n'
        printf '    *) args="$args $1"; shift ;;\n'
        printf '  esac\n'
        printf 'done\n'
        printf 'exec install $args\n'
    } >"$INSTALL_BIN"
    chmod 0755 "$INSTALL_BIN"
}

@test "record_container_restart: writes a stamp the budget check then reads" {
    setup_restart_state

    record_container_restart filebrowser
    [ -f "$RESTART_STATE_DIR/filebrowser.last-restart" ]

    # The coupling: having just recorded a restart, the budget must be
    # spent. A filename or format disagreement between the two functions
    # shows up here and nowhere else.
    run restart_budget_available filebrowser
    [ "$status" -ne 0 ]
}

@test "record_container_restart: the stamp holds a current epoch timestamp" {
    setup_restart_state

    record_container_restart qbittorrent
    local written now
    written="$(cat "$RESTART_STATE_DIR/qbittorrent.last-restart")"
    now="$(date +%s)"

    [[ "$written" =~ ^[0-9]+$ ]]
    [ "$((now - written))" -lt 60 ]
    [ "$((now - written))" -ge 0 ]
}

@test "record_container_restart: stamps are per-container" {
    setup_restart_state

    record_container_restart filebrowser

    # Recording one container's restart must not spend another's budget —
    # the cooldown is a per-container gate, not a global one.
    run restart_budget_available caddy
    [ "$status" -eq 0 ]
}

@test "record_container_restart: leaves no temporary files behind" {
    # The write is mktemp + chmod + mv. A failure to rename would leave a
    # dotfile in a directory that is otherwise only ever read by
    # restart_budget_available, which would not notice.
    setup_restart_state

    record_container_restart filebrowser
    record_container_restart filebrowser

    local leftovers
    leftovers="$(find "$RESTART_STATE_DIR" -name '.*' -type f | wc -l | tr -d ' ')"
    [ "$leftovers" -eq 0 ]
}

@test "record_container_restart: creates the state directory when absent" {
    # /run is a tmpfs: the directory is gone after every reboot, and the
    # first repair of the boot has to create it rather than fail.
    setup_restart_state
    [ ! -d "$RESTART_STATE_DIR" ]

    record_container_restart filebrowser
    [ -d "$RESTART_STATE_DIR" ]
}

@test "record_container_restart: overwrites an earlier stamp rather than appending" {
    setup_restart_state

    record_container_restart filebrowser
    record_container_restart filebrowser

    local lines
    lines="$(wc -l <"$RESTART_STATE_DIR/filebrowser.last-restart" | tr -d ' ')"
    [ "$lines" -eq 1 ]
}

# --- forwarding_config_ok ---
#
# Asserts that /etc/sysctl.d/99-tailscale.conf declares both forwarding
# sysctls as 1. The path is hardcoded in the function, so AWK_BIN is
# replaced with a wrapper that redirects the file argument to a fixture
# while running the real awk program — the awk program is the logic under
# test and is not stubbed.

use_sysctl_fixture() {
    printf '%s' "$1" >"$FIXTURE_DIR/sysctl.conf"
    AWK_BIN="$FIXTURE_DIR/awk-redirect"
    {
        printf '#!/bin/sh\n'
        printf '# Replaces the trailing file operand with the fixture.\n'
        printf 'prog="$1"; shift\n'
        printf 'exec %s "$prog" %s\n' \
            "$REAL_AWK" "$FIXTURE_DIR/sysctl.conf"
    } >"$AWK_BIN"
    chmod 0755 "$AWK_BIN"
    # Ownership/mode is owned_file_ok's job and has its own coverage in
    # reconcile_functions.bats; here it is held true so the assertions
    # isolate the content check.
    owned_file_ok() { return 0; }
}

@test "forwarding_config_ok: accepts both forwarding sysctls set to 1" {
    use_sysctl_fixture 'net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
'
    run forwarding_config_ok
    [ "$status" -eq 0 ]
}

@test "forwarding_config_ok: tolerates whitespace around the keys and values" {
    # The awk program strips all whitespace before comparing, so a
    # hand-edited file with spaces is still correct configuration. Pinning
    # this stops a future "tidy-up" of the gsub from silently turning a
    # healthy host into a permanent warning.
    use_sysctl_fixture '  net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding	=	1
'
    run forwarding_config_ok
    [ "$status" -eq 0 ]
}

@test "forwarding_config_ok: ignores unrelated lines and comments" {
    use_sysctl_fixture '# managed by install.sh
net.ipv4.conf.all.rp_filter=2
net.ipv4.ip_forward=1
net.core.rmem_max=7500000
net.ipv6.conf.all.forwarding=1
'
    run forwarding_config_ok
    [ "$status" -eq 0 ]
}

@test "forwarding_config_ok: a commented-out setting does not count as set" {
    # Pins the behaviour, and a mutation showed the mechanism is not the
    # one the code's shape suggests. Removing the regex's start-of-line
    # anchor changes no outcome at all: the unanchored pattern does match
    # '#net.ipv4.ip_forward=1', but gsub strips whitespace and not the
    # '#', so the line reaches the comparison with its prefix intact and
    # the string equality rejects it. The anchor is redundant with the
    # equality check rather than load-bearing. Recorded because the
    # opposite is the natural assumption, and someone tightening or
    # loosening that regex should know it is not what enforces this.
    use_sysctl_fixture '#net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
'
    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

@test "forwarding_config_ok: rejects a value other than 1" {
    use_sysctl_fixture 'net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=1
'
    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

@test "forwarding_config_ok: rejects IPv4 forwarding declared without IPv6" {
    use_sysctl_fixture 'net.ipv4.ip_forward=1
'
    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

@test "forwarding_config_ok: the comparison is order-sensitive" {
    # Documents a real constraint rather than endorsing it: the check is a
    # single string equality against a two-line literal, so a file that
    # declares both sysctls correctly but in the other order is reported
    # as drifted and rewritten from the canonical copy. Harmless because
    # install.sh generates this file, but anyone hand-editing it should
    # know, and anyone loosening it should do so deliberately.
    use_sysctl_fixture 'net.ipv6.conf.all.forwarding=1
net.ipv4.ip_forward=1
'
    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

@test "forwarding_config_ok: rejects a duplicated declaration" {
    # Two matching lines for one key produce three output lines and fail
    # the equality. Correct: sysctl applies the last one, so a duplicate
    # is a file whose effect cannot be read off its first occurrence.
    use_sysctl_fixture 'net.ipv4.ip_forward=1
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
'
    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

@test "forwarding_config_ok: rejects an empty or missing file" {
    use_sysctl_fixture ''
    run forwarding_config_ok
    [ "$status" -ne 0 ]

    rm -f "$FIXTURE_DIR/sysctl.conf"
    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

@test "forwarding_config_ok: fails when ownership or mode is wrong" {
    use_sysctl_fixture 'net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
'
    owned_file_ok() { return 1; }

    run forwarding_config_ok
    [ "$status" -ne 0 ]
}

# --- gro_flags_ok ---
#
# Deliberately tolerant: it returns success for every state it cannot
# judge, matching what the tailscale-udp-gro helper itself does. The
# tests below are mostly about pinning that tolerance, because the easy
# mistake is to "tighten" it into a permanent warning on hardware that
# simply does not expose the knobs.

@test "gro_flags_ok: healthy when forwarding is on and gro-list is off" {
    CURRENT_WAN4_IF=eth0
    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: on
rx-gro-list: off'

    run gro_flags_ok
    [ "$status" -eq 0 ]
}

@test "gro_flags_ok: drifted when both flags are on" {
    CURRENT_WAN4_IF=eth0
    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: on
rx-gro-list: on'

    run gro_flags_ok
    [ "$status" -ne 0 ]
}

@test "gro_flags_ok: drifted when forwarding is off" {
    CURRENT_WAN4_IF=eth0
    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: off
rx-gro-list: off'

    run gro_flags_ok
    [ "$status" -ne 0 ]
}

@test "gro_flags_ok: healthy when ethtool is not installed" {
    CURRENT_WAN4_IF=eth0
    ETHTOOL_BIN=""

    run gro_flags_ok
    [ "$status" -eq 0 ]
}

@test "gro_flags_ok: healthy when the WAN interface has not been detected" {
    CURRENT_WAN4_IF=""
    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: on
rx-gro-list: on'

    run gro_flags_ok
    [ "$status" -eq 0 ]
}

@test "gro_flags_ok: healthy when the driver reports neither feature" {
    # Not every NIC exposes these. Absence is not drift.
    CURRENT_WAN4_IF=eth0
    make_stub "$ETHTOOL_BIN" 0 'tx-checksumming: on
scatter-gather: on'

    run gro_flags_ok
    [ "$status" -eq 0 ]
}

@test "gro_flags_ok: healthy when the driver reports only one of the two" {
    CURRENT_WAN4_IF=eth0
    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: off'

    run gro_flags_ok
    [ "$status" -eq 0 ]
}

@test "gro_flags_ok: healthy when either flag is pinned [fixed]" {
    # A [fixed] flag cannot be changed, so reporting it as drift would
    # produce a warning every twenty minutes that no action can clear —
    # the same failure shape the inode check's '-' branch avoids (DD-31).
    CURRENT_WAN4_IF=eth0
    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: off [fixed]
rx-gro-list: on'

    run gro_flags_ok
    [ "$status" -eq 0 ]

    make_stub "$ETHTOOL_BIN" 0 'rx-udp-gro-forwarding: on
rx-gro-list: on [fixed]'

    run gro_flags_ok
    [ "$status" -eq 0 ]
}

@test "gro_flags_ok: healthy when ethtool fails on the interface" {
    CURRENT_WAN4_IF=eth0
    make_err_stub "$ETHTOOL_BIN" 1 'netlink error: no device matches name'

    run gro_flags_ok
    [ "$status" -eq 0 ]
}
