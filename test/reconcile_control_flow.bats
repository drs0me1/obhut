#!/usr/bin/env bats
# Regression coverage for reconcile's control-plane boundaries: transient
# deferral versus persistent failure, read-only mode side effects, recoverable
# compose-file loss, and storage ordering for the host WebDAV service.

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
        extract_function defer_transient
        extract_function fail_unhealthy
        extract_function current_addresses_ready
        extract_function compose_file_structurally_ok
        extract_function compose_file_ok
        extract_function restore_missing_compose_file
        extract_function filebrowser_audit_due
        extract_function record_filebrowser_audit
    } >"$FUNCS_FILE"
    for function_name in \
        defer_transient fail_unhealthy current_addresses_ready \
        compose_file_structurally_ok compose_file_ok \
        restore_missing_compose_file \
        filebrowser_audit_due record_filebrowser_audit; do
        grep -q "^${function_name}() {" "$FUNCS_FILE"
    done

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    CANONICAL_DIR="$FIXTURE_DIR/canonical"
    COMPOSE_FILE="$FIXTURE_DIR/live/compose.yaml"
    FILEBROWSER_AUDIT_STAMP="$FIXTURE_DIR/run/filebrowser-password-audit.last"
    RESTART_STATE_DIR="$FIXTURE_DIR/run"
    FILEBROWSER_AUDIT_INTERVAL_SECONDS=86400
    CMP_BIN="$(command -v cmp)"
    mkdir -p "$CANONICAL_DIR" "$(dirname "$COMPOSE_FILE")"
    printf 'services:\n  app: {}\n' >"$CANONICAL_DIR/compose.yaml"

    # Ownership parsing is covered separately with GNU stat. These tests need
    # to isolate path shape/content, so metadata is a controllable predicate.
    OWNED_FILE_OK=1
    owned_file_ok() {
        [[ "$OWNED_FILE_OK" -eq 1 ]]
    }

    INSTALL_BIN="$FIXTURE_DIR/fake-install"
    cat >"$INSTALL_BIN" <<'FAKE_INSTALL'
#!/usr/bin/env bash
set -eu
while [[ "$1" == -* ]]; do
    case "$1" in
        -d) shift; mkdir -p "${@: -1}"; exit 0 ;;
        -m|-o|-g) shift 2 ;;
        *) exit 64 ;;
    esac
done
cp "$1" "$2"
FAKE_INSTALL
    chmod +x "$INSTALL_BIN"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "transient deferral succeeds only in reconcile mode" {
    MODE=reconcile
    run defer_transient 75 "transaction active"
    [ "$status" -eq 0 ]
    [[ "$output" == *"transaction active"* ]]

    MODE=--check
    run defer_transient 75 "transaction active"
    [ "$status" -eq 75 ]
    [[ "$output" == *"HATA: transaction active"* ]]
}

@test "persistent unhealthy state fails in every mode" {
    MODE=reconcile
    run fail_unhealthy "tailscaled inactive"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HATA: tailscaled inactive"* ]]

    MODE=--check
    run fail_unhealthy "tailscaled inactive"
    [ "$status" -eq 1 ]
}

@test "address readiness requires WAN source and Tailscale IPv4" {
    local address_block=""
    CURRENT_WAN4_IF=eth0
    CURRENT_PUBLIC_IPV4=203.0.113.10
    CURRENT_TAILSCALE_IPV4=100.64.0.10
    current_addresses_ready

    CURRENT_TAILSCALE_IPV4=""
    run current_addresses_ready
    [ "$status" -ne 0 ]

    address_block="$(
        sed -n '/^read_current_addresses$/,/^ENV_PUBLIC_IPV4=/p' "$INSTALL_SH"
    )"
    grep -Fq 'ADDRESS_READY_WAIT_SECONDS / 2' <<<"$address_block"
    grep -Fq 'report_tailscale_diagnostics' <<<"$address_block"
    grep -Fq 'fail_unhealthy' <<<"$address_block"
}

@test "modified regular compose remains structurally usable but not canonical" {
    printf 'services:\n  changed: {}\n' >"$COMPOSE_FILE"

    compose_file_structurally_ok
    run compose_file_ok
    [ "$status" -ne 0 ]
}

@test "missing directory and symlink compose targets are structurally rejected" {
    run compose_file_structurally_ok
    [ "$status" -ne 0 ]

    mkdir -p "$COMPOSE_FILE"
    run compose_file_structurally_ok
    [ "$status" -ne 0 ]

    rm -rf "$COMPOSE_FILE"
    ln -s "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE"
    run compose_file_structurally_ok
    [ "$status" -ne 0 ]
}

@test "exact regular compose with expected metadata is canonical" {
    cp "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE"

    compose_file_structurally_ok
    compose_file_ok
}

@test "compose metadata failure is independent of content" {
    cp "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE"
    OWNED_FILE_OK=0

    run compose_file_structurally_ok
    [ "$status" -ne 0 ]
}

@test "missing compose is restored byte-identically without applying it" {
    restore_missing_compose_file

    cmp -s "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE"
    compose_file_ok
    [ -z "$(find "$(dirname "$COMPOSE_FILE")" -name '.compose-reconcile.*' -print -quit)" ]
}

@test "compose restore refuses directory and symlink targets" {
    mkdir -p "$COMPOSE_FILE"
    run restore_missing_compose_file
    [ "$status" -ne 0 ]
    [ -d "$COMPOSE_FILE" ]

    rm -rf "$COMPOSE_FILE"
    ln -s "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE"
    run restore_missing_compose_file
    [ "$status" -ne 0 ]
    [ -L "$COMPOSE_FILE" ]
}

@test "filebrowser audit is due with no old or corrupt stamp" {
    filebrowser_audit_due

    mkdir -p "$RESTART_STATE_DIR"
    printf '%s\n' "$(( $(date +%s) - 86401 ))" >"$FILEBROWSER_AUDIT_STAMP"
    filebrowser_audit_due

    printf 'corrupt\n' >"$FILEBROWSER_AUDIT_STAMP"
    filebrowser_audit_due
}

@test "recent filebrowser audit suppresses another login attempt" {
    mkdir -p "$RESTART_STATE_DIR"
    printf '%s\n' "$(date +%s)" >"$FILEBROWSER_AUDIT_STAMP"

    run filebrowser_audit_due
    [ "$status" -ne 0 ]
}

@test "record_filebrowser_audit atomically publishes a numeric stamp" {
    record_filebrowser_audit

    [ -f "$FILEBROWSER_AUDIT_STAMP" ]
    run grep -Eq '^[0-9]+$' "$FILEBROWSER_AUDIT_STAMP"
    [ "$status" -eq 0 ]
    [ -z "$(find "$RESTART_STATE_DIR" -name '.filebrowser-audit.*' -print -quit)" ]
}

@test "password POST is gated to due normal reconcile runs" {
    local call_line="" guard_block=""
    call_line="$(grep -n '^[[:space:]]*report_default_filebrowser_password$' "$INSTALL_SH" | cut -d: -f1)"
    [ -n "$call_line" ]
    guard_block="$(sed -n "$((call_line - 7)),$((call_line + 1))p" "$INSTALL_SH")"

    grep -Fq 'if [[ "$MODE" == "reconcile" ]] &&' <<<"$guard_block"
    grep -Fq 'filebrowser_audit_due &&' <<<"$guard_block"
    grep -Fq 'if record_filebrowser_audit; then' <<<"$guard_block"
    grep -Fq "inspect -f '{{.State.Running}}' filebrowser" <<<"$guard_block"
}

@test "reconcile service cannot skip checks when compose is missing" {
    local unit_block="" stage7_block=""
    unit_block="$(
        sed -n "/<<'RECONCILE_SYSTEMD'\$/,/^RECONCILE_SYSTEMD\$/p" \
            "$INSTALL_SH"
    )"
    stage7_block="$(sed -n '/progress_stage_begin 7 /,$p' "$INSTALL_SH")"

    ! grep -q '^ConditionPathExists=' <<<"$unit_block"
    grep -Fq "grep -q '^ConditionPathExists='" <<<"$stage7_block"
}

@test "host WebDAV waits for the configured media mount" {
    local unit_block="" stage7_block=""
    unit_block="$(
        sed -n '/<<WEBDAV_SYSTEMD$/,/^WEBDAV_SYSTEMD$/p' "$INSTALL_SH"
    )"
    stage7_block="$(sed -n '/progress_stage_begin 7 /,$p' "$INSTALL_SH")"

    grep -Fq 'RequiresMountsFor=${DOWNLOADS_PATH}/media' <<<"$unit_block"
    grep -Fq 'grep -Fxq "RequiresMountsFor=$DOWNLOADS_PATH/media"' \
        <<<"$stage7_block"
}
