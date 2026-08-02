#!/usr/bin/env bats
# Regression coverage for Stage 6's DNS/Caddy file transaction. Service
# state alone is not a rollback: a previously-active daemon must restart
# with its previous files, and a fresh install must remove files that did
# not exist before the failed attempt.

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
    extract_outer_function dns_stack_managed_path_ok >"$FUNCS_FILE"
    extract_outer_function dns_stack_rollback_dir_ok >>"$FUNCS_FILE"
    extract_outer_function capture_dns_stack_files >>"$FUNCS_FILE"
    extract_outer_function restore_dns_stack_files >>"$FUNCS_FILE"
    extract_outer_function canonical_stage_is_current >>"$FUNCS_FILE"
    extract_outer_function restore_dns_stack_on_failure >>"$FUNCS_FILE"

    grep -q '^capture_dns_stack_files() {' "$FUNCS_FILE"
    grep -q '^restore_dns_stack_files() {' "$FUNCS_FILE"
    grep -q '^restore_dns_stack_on_failure() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    DNS_STACK_ROLLBACK_BASE="$FIXTURE_DIR/run"
    mkdir -p "$DNS_STACK_ROLLBACK_BASE"
    EXISTING_FILE="$FIXTURE_DIR/live/etc/caddy/Caddyfile"
    ABSENT_FILE="$FIXTURE_DIR/live/etc/dnsmasq.d/local-services.conf"
    DNS_STACK_MANAGED_FILES=("$EXISTING_FILE" "$ABSENT_FILE")
    mkdir -p "$(dirname "$EXISTING_FILE")" "$(dirname "$ABSENT_FILE")"
    printf 'old config\n' >"$EXISTING_FILE"
    chmod 0640 "$EXISTING_FILE"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "file rollback restores previous content and removes a newly-created file" {
    capture_dns_stack_files
    local rollback_dir="$DNS_STACK_ROLLBACK_DIR"

    printf 'new config\n' >"$EXISTING_FILE"
    chmod 0600 "$EXISTING_FILE"
    printf 'created by failed install\n' >"$ABSENT_FILE"

    restore_dns_stack_files

    [ "$(cat "$EXISTING_FILE")" = "old config" ]
    [ ! -e "$ABSENT_FILE" ]
    [ -z "$DNS_STACK_ROLLBACK_DIR" ]
    [ ! -e "$rollback_dir" ]
}

@test "file rollback preserves an original symbolic link" {
    local target="$FIXTURE_DIR/original-target"
    printf 'target\n' >"$target"
    rm -f "$EXISTING_FILE"
    ln -s "$target" "$EXISTING_FILE"

    capture_dns_stack_files
    rm -f "$EXISTING_FILE"
    printf 'replacement\n' >"$EXISTING_FILE"
    restore_dns_stack_files

    [ -L "$EXISTING_FILE" ]
    [ "$(readlink "$EXISTING_FILE")" = "$target" ]
}

@test "capture rejects a relative or root managed path" {
    DNS_STACK_MANAGED_FILES=("relative.conf" "/")

    run capture_dns_stack_files

    [ "$status" -ne 0 ]
    [ -z "$DNS_STACK_ROLLBACK_DIR" ]
}

@test "service rollback restores files before reloading and restarting daemons" {
    capture_dns_stack_files
    printf 'new config\n' >"$EXISTING_FILE"
    printf 'new file\n' >"$ABSENT_FILE"

    SYSTEMCTL_LOG="$FIXTURE_DIR/systemctl.log"
    systemctl() {
        printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
        return 0
    }
    DNS_STACK_STATE_CAPTURED=1
    DNSMASQ_WAS_ACTIVE=1
    DNSMASQ_INITIAL_LOAD_STATE=loaded
    DNSMASQ_INITIAL_UNIT_FILE_STATE=enabled
    CADDY_WAS_ACTIVE=1
    CADDY_INITIAL_LOAD_STATE=loaded
    CADDY_INITIAL_UNIT_FILE_STATE=enabled

    restore_dns_stack_on_failure 1

    [ "$(cat "$EXISTING_FILE")" = "old config" ]
    [ ! -e "$ABSENT_FILE" ]
    [ "$DNS_STACK_STATE_CAPTURED" -eq 0 ]
    [ "$(grep -c '^daemon-reload$' "$SYSTEMCTL_LOG")" -eq 1 ]
    [ "$(grep -c '^restart dnsmasq.service$' "$SYSTEMCTL_LOG")" -eq 1 ]
    [ "$(grep -c '^restart caddy.service$' "$SYSTEMCTL_LOG")" -eq 1 ]
    [ "$(grep -c '^start ' "$SYSTEMCTL_LOG" || true)" -eq 0 ]
}

@test "Stage 6 commits rollback only after canonical current is swapped" {
    local capture_line="" first_write_line="" swap_line="" commit_line=""
    local stage_clear_line=""

    capture_line="$(grep -n '^capture_dns_stack_files$' "$INSTALL_SH" |
        cut -d: -f1)"
    first_write_line="$(
        grep -n -m1 '^cat >/etc/systemd/system/dnsmasq.service.d/' \
            "$INSTALL_SH" | cut -d: -f1
    )"
    swap_line="$(
        grep -n -m1 '^mv -Tf "\$CANONICAL_LINK_TMP"' "$INSTALL_SH" |
            cut -d: -f1
    )"
    commit_line="$(
        awk -v swap="$swap_line" \
            'NR > swap && $0 == "DNS_STACK_STATE_CAPTURED=0" {print NR; exit}' \
            "$INSTALL_SH"
    )"
    stage_clear_line="$(
        awk -v swap="$swap_line" \
            'NR > swap && $0 == "CANONICAL_STAGE_DIR=\"\"" {print NR; exit}' \
            "$INSTALL_SH"
    )"

    [ -n "$capture_line" ]
    [ -n "$first_write_line" ]
    [ -n "$swap_line" ]
    [ -n "$commit_line" ]
    [ -n "$stage_clear_line" ]
    [ "$capture_line" -lt "$first_write_line" ]
    [ "$first_write_line" -lt "$swap_line" ]
    [ "$swap_line" -lt "$commit_line" ]
    [ "$commit_line" -lt "$stage_clear_line" ]
}

@test "a committed current pointer closes the signal window before the flag update" {
    capture_dns_stack_files
    printf 'committed new config\n' >"$EXISTING_FILE"

    CANONICAL_ROOT="$FIXTURE_DIR/canonical"
    CANONICAL_STAGE_DIR="$CANONICAL_ROOT/.generation.new"
    mkdir -p "$CANONICAL_STAGE_DIR"
    ln -s .generation.new "$CANONICAL_ROOT/current"
    DNS_STACK_STATE_CAPTURED=1
    SYSTEMCTL_LOG="$FIXTURE_DIR/systemctl.log"
    systemctl() {
        printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
        return 0
    }

    restore_dns_stack_on_failure 143

    [ "$(cat "$EXISTING_FILE")" = "committed new config" ]
    [ "$DNS_STACK_STATE_CAPTURED" -eq 0 ]
    [ -z "$DNS_STACK_ROLLBACK_DIR" ]
    [ ! -e "$SYSTEMCTL_LOG" ]
}

@test "a failed file restore retains the recovery snapshot" {
    capture_dns_stack_files
    local rollback_dir="$DNS_STACK_ROLLBACK_DIR"
    local backup_file="$rollback_dir/files$EXISTING_FILE"
    printf 'new config\n' >"$EXISTING_FILE"
    cp() { return 1; }

    run restore_dns_stack_files

    [ "$status" -ne 0 ]
    [ -d "$rollback_dir" ]
    [ "$(command cat "$backup_file")" = "old config" ]
}
