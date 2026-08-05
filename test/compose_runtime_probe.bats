#!/usr/bin/env bats
# Coverage for A4: probe_compose_runtime's contract (Q1-29, DD-48).
#
# The function was called check_compose_runtime and had no tests at all — its
# component probes (port_binding_exists, docker_network_tuple, ...) are
# covered in test/reconcile_probes.bats, the 110-line composite that resets
# four globals from five call sites was not. It is also a predicate that
# printed: two stderr lines rode along with every one of those five calls, so
# a drifted cycle emitted the same wg-easy error four times and `--status`
# showed it as prose interleaved into the key=value report (it captures
# `--check` with 2>&1). That is the same shape DD-33 already fixed once for
# the filebrowser password probe on this very function.
#
# What is pinned here: the four globals are recomputed on every call, the
# function is silent, and DD-12/H6's rule survives — a pending wg-easy setup
# must NOT make the probe fail, or every fresh install breaks at Stage 7
# again. The component probes are stubbed; this file is about the composite.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

extract_function() {
    local func_name="$1"
    sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH" |
        awk -v fn="$func_name" '
            $0 == fn "() {" { found=1 }
            found { print }
            found && /^}/ { exit }
        '
}

reconcile_script() {
    sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    {
        extract_function add_compose_restart_target
        extract_function probe_compose_runtime
        extract_function compose_runtime_still_ok
    } >"$FUNCS_FILE"

    grep -q '^probe_compose_runtime() {' "$FUNCS_FILE"
    grep -q '^add_compose_restart_target() {' "$FUNCS_FILE"
    grep -q '^compose_runtime_still_ok() {' "$FUNCS_FILE"

    declare -a COMPOSE_RESTART_TARGETS=()
    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    QBIT_PUBLIC_PORT=65173
    WG_PUBLIC_PORT=65171
    CURRENT_PUBLIC_IPV4=203.0.113.10

    # Container state, controllable per name. Default: everything up.
    STATE_DIR="$FIXTURE_DIR/state"
    mkdir -p "$STATE_DIR/running" "$STATE_DIR/health"
    local name
    for name in filebrowser portainer qbittorrent unpackerr wg-easy; do
        printf 'true\n' >"$STATE_DIR/running/$name"
        printf 'healthy\n' >"$STATE_DIR/health/$name"
    done
    printf '%s\n' "$WG_PUBLIC_PORT" >"$STATE_DIR/wgport"

    DOCKER_BIN="$FIXTURE_DIR/fake-docker"
    cat >"$DOCKER_BIN" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -u
case "$1" in
    inspect)
        format="$3"; container="$4"
        case "$format" in
            *State.Running*) cat "$STATE_DIR/running/$container" ;;
            *State.Health*)  cat "$STATE_DIR/health/$container" ;;
        esac
        ;;
    exec)
        # `docker exec wg-easy wg show wg0 listen-port`
        cat "$STATE_DIR/wgport"
        ;;
esac
FAKE_DOCKER
    chmod +x "$DOCKER_BIN"
    export STATE_DIR

    # The setup-redirect probe: a Location header read through real awk.
    AWK_BIN="$(command -v awk)"
    SETUP_LOCATION=""
    CURL_BIN="$FIXTURE_DIR/fake-curl"
    cat >"$CURL_BIN" <<'FAKE_CURL'
#!/usr/bin/env bash
set -u
[[ -n "${SETUP_LOCATION:-}" ]] || exit 0
printf 'HTTP/1.1 302 Found\r\nLocation: %s\r\n\r\n' "$SETUP_LOCATION"
FAKE_CURL
    chmod +x "$CURL_BIN"
    export SETUP_LOCATION

    # Component probes, covered on their own in reconcile_probes.bats.
    PORT_BINDINGS_OK=1
    ENDPOINTS_OK=1
    QBIT_LISTENER_OK=1
    WG_NETFILTER_OK=1
    port_binding_exists() { [[ "$PORT_BINDINGS_OK" -eq 1 ]]; }
    http_endpoint_responds() { [[ "$ENDPOINTS_OK" -eq 1 ]]; }
    qbittorrent_peer_listener_ok() { [[ "$QBIT_LISTENER_OK" -eq 1 ]]; }
    wg_container_netfilter_ok() { [[ "$WG_NETFILTER_OK" -eq 1 ]]; }
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

set_setup_location() {
    SETUP_LOCATION="$1"
    export SETUP_LOCATION
}

@test "a fully healthy stack passes with no restart targets" {
    run probe_compose_runtime
    [ "$status" -eq 0 ]

    probe_compose_runtime
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 0 ]
    [ "$WG_SETUP_PENDING" -eq 0 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 0 ]
    [ -z "$WG_OBSERVED_PORT" ]
}

@test "the probe prints nothing" {
    # It is called up to five times a cycle and three of those are pure
    # predicate positions. Diagnostics belong to the caller (DD-33's rule,
    # applied to the two lines it left behind).
    printf 'false\n' >"$STATE_DIR/running/qbittorrent"
    set_setup_location /setup/
    printf '1234\n' >"$STATE_DIR/wgport"
    ENDPOINTS_OK=0

    run probe_compose_runtime
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "a stopped container fails the probe and becomes a restart target" {
    printf 'false\n' >"$STATE_DIR/running/portainer"

    run probe_compose_runtime
    [ "$status" -ne 0 ]

    probe_compose_runtime || true
    printf '%s\n' "${COMPOSE_RESTART_TARGETS[@]}" | grep -Fxq portainer
}

@test "an unhealthy container fails the probe; 'none' does not" {
    printf 'unhealthy\n' >"$STATE_DIR/health/unpackerr"
    run probe_compose_runtime
    [ "$status" -ne 0 ]

    printf 'none\n' >"$STATE_DIR/health/unpackerr"
    run probe_compose_runtime
    [ "$status" -eq 0 ]
}

@test "a starting container is drift, not a pass" {
    printf 'starting\n' >"$STATE_DIR/health/filebrowser"
    run probe_compose_runtime
    [ "$status" -ne 0 ]
}

@test "restart targets are deduplicated across signals" {
    # qbittorrent fails four separate checks in one pass: health, two port
    # bindings, the HTTP probe and the peer listener.
    printf 'unhealthy\n' >"$STATE_DIR/health/qbittorrent"
    QBIT_LISTENER_OK=0

    probe_compose_runtime || true
    [ "$(printf '%s\n' "${COMPOSE_RESTART_TARGETS[@]}" |
         grep -Fxc qbittorrent)" -eq 1 ]
}

@test "a pending wg-easy setup does not fail the probe (DD-12/H6)" {
    # The regression that broke every fresh install before DD-12: a wg-easy
    # that has not had its admin account created is the EXPECTED state, and
    # must not count toward compose_runtime drift or Stage 7's postcondition.
    set_setup_location /setup/
    printf '1234\n' >"$STATE_DIR/wgport"

    run probe_compose_runtime
    [ "$status" -eq 0 ]

    probe_compose_runtime
    [ "$WG_SETUP_PENDING" -eq 1 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 0 ]
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 0 ]
}

@test "a wg-easy port mismatch after setup is real drift" {
    printf '1234\n' >"$STATE_DIR/wgport"

    run probe_compose_runtime
    [ "$status" -ne 0 ]

    probe_compose_runtime || true
    [ "$WG_CONFIGURATION_INVALID" -eq 1 ]
    [ "$WG_SETUP_PENDING" -eq 0 ]
    # The value the caller now prints, since the probe no longer does.
    [ "$WG_OBSERVED_PORT" = "1234" ]
    # A configuration error is not something a restart fixes, so wg-easy is
    # deliberately NOT queued for one.
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 0 ]
}

@test "wg-easy netfilter drift is a restart target, not a config error" {
    WG_NETFILTER_OK=0

    run probe_compose_runtime
    [ "$status" -ne 0 ]

    probe_compose_runtime || true
    [ "$WG_CONFIGURATION_INVALID" -eq 0 ]
    printf '%s\n' "${COMPOSE_RESTART_TARGETS[@]}" | grep -Fxq wg-easy
}

@test "a stopped wg-easy is not inspected for port or setup state" {
    printf 'false\n' >"$STATE_DIR/running/wg-easy"
    printf '1234\n' >"$STATE_DIR/wgport"
    set_setup_location /setup/

    probe_compose_runtime || true

    [ "$WG_CONFIGURATION_INVALID" -eq 0 ]
    [ "$WG_SETUP_PENDING" -eq 0 ]
    printf '%s\n' "${COMPOSE_RESTART_TARGETS[@]}" | grep -Fxq wg-easy
}

@test "every global is recomputed, not accumulated, across calls" {
    # The reason this matters: three of the five call sites are pure
    # predicate positions that silently reset these. If a stale value could
    # survive a call, a later reader would act on a measurement that no
    # longer holds.
    printf 'false\n' >"$STATE_DIR/running/portainer"
    printf '1234\n' >"$STATE_DIR/wgport"
    probe_compose_runtime || true
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -gt 0 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 1 ]
    [ -n "$WG_OBSERVED_PORT" ]

    printf 'true\n' >"$STATE_DIR/running/portainer"
    printf '%s\n' "$WG_PUBLIC_PORT" >"$STATE_DIR/wgport"
    run probe_compose_runtime
    [ "$status" -eq 0 ]

    probe_compose_runtime
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 0 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 0 ]
    [ "$WG_SETUP_PENDING" -eq 0 ]
    [ -z "$WG_OBSERVED_PORT" ]
}

@test "the caller reports what the probe stopped printing" {
    local script=""
    script="$(
        sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH"
    )"
    # Reported once at the detection site, which runs in every mode and
    # before all_critical_state_healthy's early exit — otherwise a host whose
    # only issue is a pending wg-easy setup would go silent.
    grep -Fq 'echo "UYARI: wg-easy ilk kurulumu tamamlanmamış' <<<"$script"
    grep -Fq '${WG_OBSERVED_PORT:-yok}' <<<"$script"
    # And as data, so --status shows it in the key=value report rather than
    # as prose captured through 2>&1.
    grep -Fq 'wg_setup=$WG_SETUP_PENDING wg_config=$WG_CONFIGURATION_INVALID' \
        <<<"$script"
}

# --- D5: the postcondition wrapper (Q1-39, DD-57) ------------------------
#
# The probe publishes four globals as a side effect of answering yes/no. That
# is right where the cycle measures, and wrong where it merely checks: the two
# postcondition positions used to overwrite the very measurements the report
# and the repair loop had already acted on. compose_runtime_still_ok asks the
# same question and puts everything back.

@test "the wrapper restores every global the probe resets" {
    # A measured, drifted state, published the way the detection site does.
    printf 'false\n' >"$STATE_DIR/running/portainer"
    printf '1234\n' >"$STATE_DIR/wgport"
    probe_compose_runtime || true
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 1 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 1 ]
    [ "$WG_OBSERVED_PORT" = "1234" ]

    # The repair lands, and the postcondition re-asks against a healthy stack.
    printf 'true\n' >"$STATE_DIR/running/portainer"
    printf '%s\n' "$WG_PUBLIC_PORT" >"$STATE_DIR/wgport"

    compose_runtime_still_ok

    printf '%s\n' "${COMPOSE_RESTART_TARGETS[@]}" | grep -Fxq portainer
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 1 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 1 ]
    [ "$WG_OBSERVED_PORT" = "1234" ]
    [ "$WG_SETUP_PENDING" -eq 0 ]
}

@test "the wrapper does not leak the probe's findings into a clean state" {
    # The other direction, and the one the (( saved_count > 0 )) guard exists
    # for: nothing was queued before the call, so nothing may be queued after
    # it either — including what this call itself found.
    probe_compose_runtime
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 0 ]

    printf 'false\n' >"$STATE_DIR/running/qbittorrent"
    printf '1234\n' >"$STATE_DIR/wgport"

    run compose_runtime_still_ok
    [ "$status" -ne 0 ]

    compose_runtime_still_ok || true
    [ "${#COMPOSE_RESTART_TARGETS[@]}" -eq 0 ]
    [ "$WG_CONFIGURATION_INVALID" -eq 0 ]
    [ "$WG_SETUP_PENDING" -eq 0 ]
    [ -z "$WG_OBSERVED_PORT" ]
}

@test "the wrapper returns the probe's verdict, not the restore's" {
    probe_compose_runtime

    run compose_runtime_still_ok
    [ "$status" -eq 0 ]

    printf 'false\n' >"$STATE_DIR/running/filebrowser"
    run compose_runtime_still_ok
    [ "$status" -ne 0 ]
}

@test "a pending wg-easy setup survives the postcondition unchanged" {
    # DD-12/H6 again, one layer out. On a fresh install WG_SETUP_PENDING=1 is
    # the expected state and the caller warns about it; a postcondition that
    # silently cleared the flag would take that warning away on exactly the
    # run that needs it.
    set_setup_location /setup/
    printf '1234\n' >"$STATE_DIR/wgport"
    probe_compose_runtime
    [ "$WG_SETUP_PENDING" -eq 1 ]

    # The admin finishes the wizard during the repair window, so the
    # postcondition's own measurement disagrees with the reported one. The
    # reported one is what the cycle already acted on, and it must win.
    set_setup_location ""
    printf '%s\n' "$WG_PUBLIC_PORT" >"$STATE_DIR/wgport"

    run compose_runtime_still_ok
    [ "$status" -eq 0 ]

    compose_runtime_still_ok
    [ "$WG_SETUP_PENDING" -eq 1 ]
}

@test "only measurement positions call the probe directly" {
    # Derived from the script rather than restated: any new call in a pure
    # predicate position fails here instead of quietly clearing four globals.
    # The three permitted shapes are the detection, its one retry, and the
    # re-measure after a Quantum config repair — each consumes what it moved.
    local script offenders
    script="$(reconcile_script)"
    offenders="$(
        grep -n 'probe_compose_runtime' <<<"$script" |
            grep -Fv 'probe_compose_runtime() {' |
            grep -Fv '|| COMPOSE_RUNTIME_DRIFTED=1' |
            grep -Fv 'if ! probe_compose_runtime; then' |
            grep -Fv 'probe_compose_runtime || rc=$?' || true
    )"
    [ -z "$offenders" ]

    # And the exemptions are not vacuous: the wrapper's own call is there, and
    # both postcondition positions go through it.
    grep -Fq 'probe_compose_runtime || rc=$?' <<<"$script"
    [ "$(grep -Fc 'compose_runtime_still_ok' <<<"$script")" -eq 3 ]
}

@test "the globals the wrapper reads are initialized before it can run" {
    # The wrapper reads four globals that nothing declares at top level — the
    # probe is their only writer. Under the script's `set -u` an early caller
    # would abort the cycle instead of measuring, so what makes the reads safe
    # is that the unconditional detection call precedes both call sites.
    local script first_probe first_wrapper
    script="$(reconcile_script)"

    # Top level, so it cannot be skipped by a mode or a branch.
    first_probe="$(
        grep -n '^if ! probe_compose_runtime; then' <<<"$script" |
            head -1 | cut -d: -f1
    )"
    first_wrapper="$(
        grep -n 'compose_runtime_still_ok' <<<"$script" |
            grep -Fv 'compose_runtime_still_ok() {' |
            head -1 | cut -d: -f1
    )"

    [ -n "$first_probe" ]
    [ -n "$first_wrapper" ]
    [ "$first_probe" -lt "$first_wrapper" ]
}
