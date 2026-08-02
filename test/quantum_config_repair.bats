#!/usr/bin/env bats
# shellcheck disable=SC2016
# Regression tests for FileBrowser Quantum's host-policy repair. The real
# incident is structural: Docker can create the missing bind source as a
# directory, and copying filebrowser.yaml "to" that directory succeeds while
# leaving the path a directory. A restart then keeps the stale mount spec.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

extract_function() {
    local func_name="$1"
    sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH" |
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
        extract_function remove_quantum_container_if_present
        extract_function restore_quantum_config
        extract_function restart_quantum_after_config_restore
    } >"$FUNCS_FILE"
    grep -q '^remove_quantum_container_if_present() {' "$FUNCS_FILE"
    grep -q '^restore_quantum_config() {' "$FUNCS_FILE"
    grep -q '^restart_quantum_after_config_restore() {' "$FUNCS_FILE"

    CANONICAL_DIR="$FIXTURE_DIR/canonical"
    LIVE_DIR="$FIXTURE_DIR/live"
    QUANTUM_CONFIG_FILE="$LIVE_DIR/filebrowser.yaml"
    mkdir -p "$CANONICAL_DIR" "$LIVE_DIR"
    printf 'auth:\n  signup: false\n' >"$CANONICAL_DIR/filebrowser.yaml"

    INSTALL_BIN="$FIXTURE_DIR/fake-install"
    cat >"$INSTALL_BIN" <<'FAKE_INSTALL'
#!/usr/bin/env bash
set -eu
mode=""
while [[ "$1" == -* ]]; do
    case "$1" in
        -m) mode="$2"; shift 2 ;;
        -o|-g) shift 2 ;;
        *) exit 64 ;;
    esac
done
cp "$1" "$2"
chmod "$mode" "$2"
FAKE_INSTALL
    chmod +x "$INSTALL_BIN"

    FAKE_DOCKER_DIR="$FIXTURE_DIR/docker"
    mkdir -p "$FAKE_DOCKER_DIR"
    printf '0\n' >"$FAKE_DOCKER_DIR/inspect_rc"
    printf '0\n' >"$FAKE_DOCKER_DIR/info_rc"
    printf '0\n' >"$FAKE_DOCKER_DIR/rm_rc"
    printf '0\n' >"$FAKE_DOCKER_DIR/restart_rc"
    : >"$FAKE_DOCKER_DIR/calls"
    export FAKE_DOCKER_DIR

    DOCKER_BIN="$FIXTURE_DIR/fake-docker"
    cat >"$DOCKER_BIN" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_DOCKER_DIR/calls"
case "${1:-} ${2:-}" in
    "container inspect") exit "$(cat "$FAKE_DOCKER_DIR/inspect_rc")" ;;
    "rm -f") exit "$(cat "$FAKE_DOCKER_DIR/rm_rc")" ;;
    "info ") exit "$(cat "$FAKE_DOCKER_DIR/info_rc")" ;;
    "restart filebrowser") exit "$(cat "$FAKE_DOCKER_DIR/restart_rc")" ;;
    *) exit 64 ;;
esac
FAKE_DOCKER
    chmod +x "$DOCKER_BIN"

    FAKE_SYSTEMCTL_CALLS="$FIXTURE_DIR/systemctl-calls"
    : >"$FAKE_SYSTEMCTL_CALLS"
    export FAKE_SYSTEMCTL_CALLS
    SYSTEMCTL_BIN="$FIXTURE_DIR/fake-systemctl"
    cat >"$SYSTEMCTL_BIN" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_CALLS"
FAKE_SYSTEMCTL
    chmod +x "$SYSTEMCTL_BIN"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "regular policy drift is replaced without removing the container" {
    printf 'auth:\n  signup: true\n' >"$QUANTUM_CONFIG_FILE"

    restore_quantum_config

    cmp -s "$CANONICAL_DIR/filebrowser.yaml" "$QUANTUM_CONFIG_FILE"
    [ -f "$QUANTUM_CONFIG_FILE" ]
    [ "$QUANTUM_CONTAINER_RECREATE_REQUIRED" -eq 0 ]
    [ ! -s "$FAKE_DOCKER_DIR/calls" ]
}

@test "directory bind source is replaced by a file and its container is removed" {
    mkdir -p "$QUANTUM_CONFIG_FILE/nested"
    printf 'junk\n' >"$QUANTUM_CONFIG_FILE/nested/old"

    restore_quantum_config

    [ -f "$QUANTUM_CONFIG_FILE" ]
    cmp -s "$CANONICAL_DIR/filebrowser.yaml" "$QUANTUM_CONFIG_FILE"
    [ "$QUANTUM_CONTAINER_RECREATE_REQUIRED" -eq 1 ]
    grep -Fxq 'container inspect filebrowser' "$FAKE_DOCKER_DIR/calls"
    grep -Fxq 'rm -f filebrowser' "$FAKE_DOCKER_DIR/calls"
}

@test "directory is repairable when the container is already absent" {
    mkdir -p "$QUANTUM_CONFIG_FILE"
    printf '1\n' >"$FAKE_DOCKER_DIR/inspect_rc"

    restore_quantum_config

    [ -f "$QUANTUM_CONFIG_FILE" ]
    [ "$QUANTUM_CONTAINER_RECREATE_REQUIRED" -eq 1 ]
    grep -Fxq 'info' "$FAKE_DOCKER_DIR/calls"
    run grep -Fxq 'rm -f filebrowser' "$FAKE_DOCKER_DIR/calls"
    [ "$status" -ne 0 ]
}

@test "container removal failure preserves the directory and cleans staging" {
    mkdir -p "$QUANTUM_CONFIG_FILE"
    printf '1\n' >"$FAKE_DOCKER_DIR/rm_rc"

    run restore_quantum_config

    [ "$status" -ne 0 ]
    [ -d "$QUANTUM_CONFIG_FILE" ]
    [ -z "$(find "$LIVE_DIR" -name '.filebrowser-reconcile.*' -print -quit)" ]
}

@test "daemon failure is not mistaken for an absent container" {
    mkdir -p "$QUANTUM_CONFIG_FILE"
    printf '1\n' >"$FAKE_DOCKER_DIR/inspect_rc"
    printf '1\n' >"$FAKE_DOCKER_DIR/info_rc"

    run restore_quantum_config

    [ "$status" -ne 0 ]
    [ -d "$QUANTUM_CONFIG_FILE" ]
}

@test "normal file repair restarts only filebrowser" {
    QUANTUM_CONTAINER_RECREATE_REQUIRED=0

    restart_quantum_after_config_restore

    grep -Fxq 'restart filebrowser' "$FAKE_DOCKER_DIR/calls"
    [ ! -s "$FAKE_SYSTEMCTL_CALLS" ]
}

@test "structural repair recreates filebrowser through Compose" {
    QUANTUM_CONTAINER_RECREATE_REQUIRED=1

    restart_quantum_after_config_restore

    grep -Fxq 'restart master-compose.service' "$FAKE_SYSTEMCTL_CALLS"
    [ ! -s "$FAKE_DOCKER_DIR/calls" ]
}

@test "missing container is recreated through Compose even for a regular file" {
    QUANTUM_CONTAINER_RECREATE_REQUIRED=0
    printf '1\n' >"$FAKE_DOCKER_DIR/inspect_rc"

    restart_quantum_after_config_restore

    grep -Fxq 'restart master-compose.service' "$FAKE_SYSTEMCTL_CALLS"
}

@test "repair ordering preserves drift until a restart is allowed and completed" {
    local quantum_line budget_line restore_line generic_line pending_line clear_line
    quantum_line="$(grep -n '^if \[\[ "\$QUANTUM_CONFIG_DRIFTED" -eq 1 \]\]; then$' "$INSTALL_SH" | cut -d: -f1)"
    budget_line="$(grep -n 'if ! restart_budget_available filebrowser; then' "$INSTALL_SH" | cut -d: -f1)"
    restore_line="$(grep -n 'elif ! restore_quantum_config; then' "$INSTALL_SH" | cut -d: -f1)"
    generic_line="$(grep -n '^if \[\[ "\$COMPOSE_RUNTIME_DRIFTED" -eq 1 \]\]; then$' "$INSTALL_SH" | cut -d: -f1)"
    pending_line="$(grep -n ': >"\$QUANTUM_RESTART_PENDING_FILE"' "$INSTALL_SH" | cut -d: -f1)"
    clear_line="$(grep -n 'elif ! rm -f -- "\$QUANTUM_RESTART_PENDING_FILE"; then' "$INSTALL_SH" | cut -d: -f1)"

    [ "$quantum_line" -lt "$budget_line" ]
    [ "$budget_line" -lt "$pending_line" ]
    [ "$pending_line" -lt "$restore_line" ]
    [ "$restore_line" -lt "$clear_line" ]
    [ "$clear_line" -lt "$generic_line" ]
}

@test "installer recreates filebrowser when generated policy changes" {
    grep -q '^QUANTUM_CONFIG_RECREATE_REQUIRED=0$' "$INSTALL_SH"
    grep -q '^    QUANTUM_CONFIG_RECREATE_REQUIRED=1$' "$INSTALL_SH"
    grep -q '^    if \[\[ "\$QUANTUM_CONFIG_RECREATE_REQUIRED" -eq 1 \]\]; then$' "$INSTALL_SH"
    grep -q 'QUANTUM_EXISTING_RUNNING=' "$INSTALL_SH"
    grep -q '^        docker rm -f filebrowser >/dev/null$' "$INSTALL_SH"
}

@test "generic runtime recovery recreates FileBrowser instead of restarting a stale mount" {
    local generic_block=""
    generic_block="$(
        sed -n '/^if \[\[ "\$COMPOSE_RUNTIME_DRIFTED" -eq 1 \]\]; then$/,/^if \[\[ "\$STATE_CONFIG_DRIFTED"/p' \
            "$INSTALL_SH"
    )"

    grep -q 'restart_target" == "filebrowser' <<<"$generic_block"
    grep -q 'FILEBROWSER_RUNTIME_RECREATE_REQUIRED=1' <<<"$generic_block"
    grep -q 'if remove_quantum_container_if_present; then' <<<"$generic_block"
    grep -q 'record_container_restart filebrowser' <<<"$generic_block"
}
