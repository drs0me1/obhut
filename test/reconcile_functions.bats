#!/usr/bin/env bats
# Unit tests for pure-logic helper functions embedded in
# master-network-reconcile (itself a heredoc inside install.sh — see
# SECURITY_REVIEW.md finding H4/M7, docs/testing.md Tier 2).
#
# This never sources or executes the full reconcile script: that script
# runs real flock/systemctl/docker calls at its top level the moment it's
# loaded, which is unsafe outside a real, provisioned host. Instead, only
# the two named function *bodies* below are extracted and sourced in
# isolation, then exercised against throwaway fixture files — no root,
# no systemd, no Docker, and install.sh is never modified or executed.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# Extracts the master-network-reconcile heredoc body from install.sh,
# then pulls just one named function's source out of it (from
# "name() {" to the matching top-level "}"), assuming — as this codebase
# does throughout — that the closing brace is at column 0 with no nested
# top-level braces. Safer than sourcing the whole script, which would run
# real flock/systemctl/docker calls at its top level.
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
        extract_function RECONCILE_SCRIPT state_value
        extract_function RECONCILE_SCRIPT owned_file_ok
    } >"$FUNCS_FILE"

    # Fail loudly if install.sh's function source ever moves/renames in a
    # way this extraction can no longer find, rather than silently testing
    # an empty no-op function.
    grep -q '^state_value() {' "$FUNCS_FILE"
    grep -q '^owned_file_ok() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    AWK_BIN="$(command -v awk)"
    STAT_BIN="$(command -v stat)"

    # owned_file_ok() shells out to GNU coreutils' `stat -c '%u:%g:%a'`
    # syntax, which matches install.sh's Debian target but not macOS's BSD
    # `stat` (no -c support). Detect that mismatch here so the affected
    # tests can skip on a dev workstation instead of failing on an
    # environment gap that has nothing to do with the function's logic.
    HAS_GNU_STAT=1
    "$STAT_BIN" -c '%u:%g:%a' "$FUNCS_FILE" >/dev/null 2>&1 || HAS_GNU_STAT=0
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# --- state_value ---

@test "state_value: returns the value of an existing key" {
    STATE_FILE="$FIXTURE_DIR/state.env"
    CANONICAL_DIR="$FIXTURE_DIR/no-such-canonical-dir"
    printf 'STACK_SCHEMA=9\nWEBDAV_PORT=65113\n' >"$STATE_FILE"

    run state_value WEBDAV_PORT 0
    [ "$status" -eq 0 ]
    [ "$output" = "65113" ]
}

@test "state_value: falls back to the default for a missing key" {
    STATE_FILE="$FIXTURE_DIR/state.env"
    CANONICAL_DIR="$FIXTURE_DIR/no-such-canonical-dir"
    printf 'STACK_SCHEMA=8\n' >"$STATE_FILE"

    run state_value LOCAL_DOMAIN "example"
    [ "$status" -eq 0 ]
    [ "$output" = "example" ]
}

@test "state_value: prefers the canonical copy over STATE_FILE when present" {
    STATE_FILE="$FIXTURE_DIR/state.env"
    CANONICAL_DIR="$FIXTURE_DIR/canonical"
    mkdir -p "$CANONICAL_DIR"
    printf 'QBIT_PUBLIC_PORT=65173\n' >"$STATE_FILE"
    printf 'QBIT_PUBLIC_PORT=99999\n' >"$CANONICAL_DIR/state.env"

    run state_value QBIT_PUBLIC_PORT 0
    [ "$status" -eq 0 ]
    [ "$output" = "99999" ]
}

@test "state_value: falls back to the default when no state file is readable" {
    STATE_FILE="$FIXTURE_DIR/does-not-exist.env"
    CANONICAL_DIR="$FIXTURE_DIR/no-such-canonical-dir"

    run state_value WG_PUBLIC_PORT 65171
    [ "$status" -eq 0 ]
    [ "$output" = "65171" ]
}

# --- owned_file_ok ---

@test "owned_file_ok: returns true on an exact uid:gid:mode match" {
    [ "$HAS_GNU_STAT" -eq 1 ] || skip "requires GNU coreutils stat -c (target platform is Debian; this host's stat is not GNU stat)"
    local f="$FIXTURE_DIR/owned.txt"
    : >"$f"
    chmod 0644 "$f"
    local uid gid
    uid="$(id -u)"
    gid="$(id -g)"

    run owned_file_ok "$f" "$uid" "$gid" 644
    [ "$status" -eq 0 ]
}

@test "owned_file_ok: returns false on a mode mismatch" {
    [ "$HAS_GNU_STAT" -eq 1 ] || skip "requires GNU coreutils stat -c (target platform is Debian; this host's stat is not GNU stat)"
    local f="$FIXTURE_DIR/owned.txt"
    : >"$f"
    chmod 0600 "$f"
    local uid gid
    uid="$(id -u)"
    gid="$(id -g)"

    run owned_file_ok "$f" "$uid" "$gid" 644
    [ "$status" -ne 0 ]
}

@test "owned_file_ok: returns false when the file does not exist" {
    run owned_file_ok "$FIXTURE_DIR/no-such-file.txt" 0 0 600
    [ "$status" -ne 0 ]
}
