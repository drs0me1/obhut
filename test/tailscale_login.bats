#!/usr/bin/env bats
# Regression coverage for the interactive Tailscale login state classifier.
# A browser authorization can leave the daemon permanently retrying an auth
# path that the control plane has already retired. The production retry loop
# may recover early only from the structured, persistent LocalAPI signature;
# a transient 410 during a successful login must remain successful.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

extract_outer_function() {
    local func_name="$1"
    awk -v fn="$func_name" '
        $0 == fn "() {" { found=1 }
        found { print }
        found && /^}/ { exit }
    ' "$INSTALL_SH"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    extract_outer_function tailscale_login_state >"$FUNCS_FILE"
    extract_outer_function tailscale_login_complete >>"$FUNCS_FILE"
    grep -q '^tailscale_login_state() {' "$FUNCS_FILE"
    grep -q '^tailscale_login_complete() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    OPERATOR_LOG="$FIXTURE_DIR/operator.log"
    exec 5>"$OPERATOR_LOG"

    STATUS_RC=0
    STATUS_JSON='{}'
    TAILSCALE_LOGIN_STATUS_TIMEOUT=3
    TIMEOUT_ARGS_FILE="$FIXTURE_DIR/timeout-args"
    timeout() {
        printf '%s\n' "$*" >"$TIMEOUT_ARGS_FILE"
        [ "$1" -eq "$TAILSCALE_LOGIN_STATUS_TIMEOUT" ]
        shift
        "$@"
    }
    tailscale() {
        [ "$1" = status ]
        [ "$2" = --json ]
        if [ "$STATUS_RC" -ne 0 ]; then
            return "$STATUS_RC"
        fi
        printf '%s\n' "$STATUS_JSON"
    }
}

teardown() {
    exec 5>&-
    rm -rf "$FIXTURE_DIR"
}

source_interactive_login_fixture() {
    extract_outer_function tailscale_interactive_login >"$FIXTURE_DIR/interactive.sh"
    # shellcheck disable=SC1090
    source "$FIXTURE_DIR/interactive.sh"

    MASTER_LOG_FILE="$FIXTURE_DIR/master.log"
    UP_ATTEMPTS_FILE="$FIXTURE_DIR/up-attempts"
    STATE_CALLS_FILE="$FIXTURE_DIR/state-calls"
    RESTARTS_FILE="$FIXTURE_DIR/restarts"
    TAILSCALE_LOGIN_ATTEMPTS=3
    TAILSCALE_AUTH_PATH_DEAD_SAMPLES=3
    TAILSCALE_LOGIN_STATUS_TIMEOUT=3
    TAILSCALE_LOGIN_POST_SUCCESS_GRACE=3
    TAILSCALE_LOGIN_TIMEOUT=20

    tailscale() {
        local attempts=0 state_calls=0
        [ "$1" = up ]
        if [ -f "$UP_ATTEMPTS_FILE" ]; then
            read -r attempts <"$UP_ATTEMPTS_FILE"
        fi
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" >"$UP_ATTEMPTS_FILE"
        printf 'To authenticate, visit: https://login.tailscale.com/a/test-%s\n' "$attempts"

        case "$LOGIN_SCENARIO:$attempts" in
            persistent:1)
                while :; do command sleep 1; done
                ;;
            transient:1)
                while :; do
                    if [ -f "$STATE_CALLS_FILE" ]; then
                        read -r state_calls <"$STATE_CALLS_FILE"
                    fi
                    [ "$state_calls" -ge 3 ] && return 0
                    command sleep 0.01
                done
                ;;
            *) return 0 ;;
        esac
    }

    tailscale_login_state() {
        local attempts=0 state_calls=0
        if [ -f "$UP_ATTEMPTS_FILE" ]; then
            read -r attempts <"$UP_ATTEMPTS_FILE"
        fi

        if [ "$LOGIN_SCENARIO" = persistent ]; then
            if [ "$attempts" -le 1 ]; then
                printf 'auth_path_dead\n'
            else
                printf 'complete\n'
            fi
            return 0
        fi

        if [ -f "$STATE_CALLS_FILE" ]; then
            read -r state_calls <"$STATE_CALLS_FILE"
        fi
        state_calls=$((state_calls + 1))
        printf '%s\n' "$state_calls" >"$STATE_CALLS_FILE"
        case "$state_calls" in
            1) printf 'auth_path_dead\n' ;;
            2) printf 'pending\n' ;;
            *) printf 'complete\n' ;;
        esac
    }

    tailscale_login_complete() {
        [ "$(tailscale_login_state)" = complete ]
    }

    tailscale_daemon_ready() {
        return 0
    }

    systemctl() {
        local restarts=0
        [ "$1" = restart ]
        [ "$2" = tailscaled ]
        if [ -f "$RESTARTS_FILE" ]; then
            read -r restarts <"$RESTARTS_FILE"
        fi
        printf '%s\n' "$((restarts + 1))" >"$RESTARTS_FILE"
    }

    # The production loop sleeps for two seconds. These fixtures use external
    # sleep explicitly inside the background `tailscale up` stub, so removing
    # only the foreground waits keeps the tests deterministic and fast.
    sleep() {
        return 0
    }
}

@test "complete requires Running, online, node ID and an IP" {
    STATUS_JSON='{
      "BackendState":"Running",
      "Self":{"Online":true,"ID":"node-1","TailscaleIPs":["100.64.0.1"]},
      "Health":[]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = complete ]
}

@test "Running without a node ID remains pending" {
    STATUS_JSON='{
      "BackendState":"Running",
      "Self":{"Online":true,"ID":"","TailscaleIPs":["100.64.0.1"]},
      "Health":[]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = pending ]
}

@test "Running without a Tailscale IP remains pending" {
    STATUS_JSON='{
      "BackendState":"Running",
      "Self":{"Online":true,"ID":"node-1","TailscaleIPs":[]},
      "Health":[]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = pending ]
}

@test "the observed NeedsLogin offline empty-ID 410 signature is dead" {
    STATUS_JSON='{
      "BackendState":"NeedsLogin",
      "Self":{"Online":false,"ID":"","TailscaleIPs":null},
      "Health":["You are logged out. The last login error was: register request: http 410: auth path not found"]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = auth_path_dead ]
}

@test "a successful node wins over a transient 410 health line" {
    STATUS_JSON='{
      "BackendState":"Running",
      "Self":{"Online":true,"ID":"node-1","TailscaleIPs":["100.64.0.1"]},
      "Health":["register request: http 410: auth path not found"]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = complete ]
}

@test "a 410 with an assigned node ID is not classified as dead" {
    STATUS_JSON='{
      "BackendState":"NeedsLogin",
      "Self":{"Online":false,"ID":"node-1","TailscaleIPs":null},
      "Health":["register request: http 410: auth path not found"]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = pending ]
}

@test "NeedsLogin with an unrelated health warning remains pending" {
    STATUS_JSON='{
      "BackendState":"NeedsLogin",
      "Self":{"Online":false,"ID":"","TailscaleIPs":null},
      "Health":["control plane is temporarily unavailable"]
    }'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = pending ]
}

@test "missing optional Health and Self fields remain pending" {
    STATUS_JSON='{"BackendState":"NeedsLogin"}'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = pending ]
}

@test "malformed LocalAPI JSON is unknown, never dead" {
    STATUS_JSON='{not-json'

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = unknown ]
    [ "$(<"$TIMEOUT_ARGS_FILE")" = "3 tailscale status --json" ]
}

@test "a LocalAPI command failure is unknown, never dead" {
    STATUS_RC=1

    run tailscale_login_state

    [ "$status" -eq 0 ]
    [ "$output" = unknown ]
}

@test "login_complete accepts only the fully verified state" {
    STATUS_JSON='{
      "BackendState":"Running",
      "Self":{"Online":true,"ID":"node-1","TailscaleIPs":["100.64.0.1"]},
      "Health":[]
    }'
    run tailscale_login_complete
    [ "$status" -eq 0 ]

    STATUS_JSON='{
      "BackendState":"NeedsLogin",
      "Self":{"Online":false,"ID":"","TailscaleIPs":null},
      "Health":["register request: http 410: auth path not found"]
    }'
    run tailscale_login_complete
    [ "$status" -ne 0 ]
}

@test "three consecutive dead samples restart early and the next link succeeds" {
    source_interactive_login_fixture
    LOGIN_SCENARIO=persistent

    run tailscale_interactive_login

    [ "$status" -eq 0 ]
    [ "$(<"$UP_ATTEMPTS_FILE")" -eq 2 ]
    [ "$(<"$RESTARTS_FILE")" -eq 1 ]
    [[ "$output" == *"kalıcı 410"* ]]
    [[ "$output" != *"20 saniyede tamamlanmadı"* ]]
}

@test "one transient dead sample is reset and never restarts a successful login" {
    source_interactive_login_fixture
    LOGIN_SCENARIO=transient

    run tailscale_interactive_login

    [ "$status" -eq 0 ]
    [ "$(<"$UP_ATTEMPTS_FILE")" -eq 1 ]
    [ ! -e "$RESTARTS_FILE" ]
    [ "$(<"$STATE_CALLS_FILE")" -ge 3 ]
    [[ "$output" != *"kalıcı 410"* ]]
}

@test "a successful login survives a node that is slow to come online" {
    # Q1-22. `tailscale up` exits 0 -- the operator completed the browser
    # step -- but the node has not reached the fully verified state before
    # the post-success grace expires. Q1-21 treated that as "incomplete",
    # restarted the daemon and demanded a second browser authorization,
    # discarding a login that had in fact succeeded. The wait for the node
    # to come online belongs to the 180s check further down Stage 2, not
    # here, so the grace window may only return early -- never restart.
    source_interactive_login_fixture
    LOGIN_SCENARIO=slow
    TAILSCALE_LOGIN_POST_SUCCESS_GRACE=1

    tailscale() {
        local attempts=0
        [ "$1" = up ]
        if [ -f "$UP_ATTEMPTS_FILE" ]; then
            read -r attempts <"$UP_ATTEMPTS_FILE"
        fi
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" >"$UP_ATTEMPTS_FILE"
        printf 'To authenticate, visit: https://login.tailscale.com/a/slow-%s\n' \
            "$attempts"
        return 0
    }
    # Never reaches the verified state within the window.
    tailscale_login_state() { printf 'pending\n'; }
    tailscale_login_complete() { return 1; }

    run tailscale_interactive_login

    [ "$status" -eq 0 ]
    # No daemon restart, and no second authorization demanded.
    [ ! -f "$RESTARTS_FILE" ]
    read -r attempts <"$UP_ATTEMPTS_FILE"
    [ "$attempts" -eq 1 ]
    # The hand-off to the downstream wait is announced, not silent.
    [[ "$output" == *"NOT:"* ]]
}
