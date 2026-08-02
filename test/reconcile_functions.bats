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
        extract_function RECONCILE_SCRIPT restart_budget_available
        extract_function RECONCILE_SCRIPT disk_space_ok
        extract_function RECONCILE_SCRIPT inode_space_ok
        extract_function RECONCILE_SCRIPT all_critical_state_healthy
    } >"$FUNCS_FILE"

    # Fail loudly if install.sh's function source ever moves/renames in a
    # way this extraction can no longer find, rather than silently testing
    # an empty no-op function.
    grep -q '^state_value() {' "$FUNCS_FILE"
    grep -q '^owned_file_ok() {' "$FUNCS_FILE"
    grep -q '^restart_budget_available() {' "$FUNCS_FILE"
    grep -q '^disk_space_ok() {' "$FUNCS_FILE"
    grep -q '^inode_space_ok() {' "$FUNCS_FILE"
    grep -q '^all_critical_state_healthy() {' "$FUNCS_FILE"

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
    printf 'STACK_SCHEMA=10\nWEBDAV_PORT=65113\n' >"$STATE_FILE"

    run state_value WEBDAV_PORT 0
    [ "$status" -eq 0 ]
    [ "$output" = "65113" ]
}

@test "state_value: reads an IMAGE_DIGEST_ key written by Stage 5" {
    # Schema 10 appends IMAGE_DIGEST_* after the heredoc-written block, so the
    # keys land at the end of the file and carry a colon in their value. Both
    # properties are things state_value's awk parse could plausibly get wrong.
    STATE_FILE="$FIXTURE_DIR/state.env"
    CANONICAL_DIR="$FIXTURE_DIR/no-such-canonical-dir"
    printf 'STACK_SCHEMA=10\nWEBDAV_PORT=65113\n' >"$STATE_FILE"
    printf 'IMAGE_DIGEST_WG_EASY=sha256:%064d\n' 0 >>"$STATE_FILE"

    run state_value IMAGE_DIGEST_WG_EASY bilinmiyor
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:0000000000000000000000000000000000000000000000000000000000000000" ]
}

@test "state_value: falls back to the default for a missing key" {
    STATE_FILE="$FIXTURE_DIR/state.env"
    CANONICAL_DIR="$FIXTURE_DIR/no-such-canonical-dir"
    printf 'STACK_SCHEMA=10\n' >"$STATE_FILE"

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

# --- restart_budget_available ---
#
# The 15-minute per-container restart cooldown. Worth covering on its own:
# it is the gate that decides whether a detected drift actually gets
# repaired, and the mismatch between it and the old 5-minute timer is what
# motivated moving the timer to 20 minutes (DD-21) — the constant driving
# that decision had no test behind it.

@test "restart_budget_available: allows a restart when no stamp exists" {
    RESTART_STATE_DIR="$FIXTURE_DIR/stamps"
    RESTART_COOLDOWN_SECONDS=900
    mkdir -p "$RESTART_STATE_DIR"

    run restart_budget_available portainer
    [ "$status" -eq 0 ]
}

@test "restart_budget_available: allows a restart once the cooldown has elapsed" {
    RESTART_STATE_DIR="$FIXTURE_DIR/stamps"
    RESTART_COOLDOWN_SECONDS=900
    mkdir -p "$RESTART_STATE_DIR"
    printf '%s\n' "$(( $(date +%s) - 901 ))" \
        >"$RESTART_STATE_DIR/portainer.last-restart"

    run restart_budget_available portainer
    [ "$status" -eq 0 ]
}

@test "restart_budget_available: refuses a restart inside the cooldown" {
    RESTART_STATE_DIR="$FIXTURE_DIR/stamps"
    RESTART_COOLDOWN_SECONDS=900
    mkdir -p "$RESTART_STATE_DIR"
    printf '%s\n' "$(( $(date +%s) - 60 ))" \
        >"$RESTART_STATE_DIR/portainer.last-restart"

    run restart_budget_available portainer
    [ "$status" -ne 0 ]
}

@test "restart_budget_available: treats a corrupt stamp as no stamp" {
    # A truncated or garbage stamp must not wedge repairs shut forever;
    # the function floors it to 0, which reads as "cooldown long expired".
    RESTART_STATE_DIR="$FIXTURE_DIR/stamps"
    RESTART_COOLDOWN_SECONDS=900
    mkdir -p "$RESTART_STATE_DIR"
    printf 'not-a-timestamp\n' >"$RESTART_STATE_DIR/portainer.last-restart"

    run restart_budget_available portainer
    [ "$status" -eq 0 ]
}

@test "restart_budget_available: scopes the stamp to one container" {
    RESTART_STATE_DIR="$FIXTURE_DIR/stamps"
    RESTART_COOLDOWN_SECONDS=900
    mkdir -p "$RESTART_STATE_DIR"
    printf '%s\n' "$(date +%s)" >"$RESTART_STATE_DIR/portainer.last-restart"

    run restart_budget_available qbittorrent
    [ "$status" -eq 0 ]
}

# --- disk_space_ok ---
#
# Uses a stub `df` on PATH, the same technique test/firewall_functions.bats
# uses for iptables. Reported but never auto-repaired: deleting user data is
# not a safe automated action, so this function's only job is to classify.

# Emits the two-line shape `df --output=pcent` produces: a "Use%" header
# followed by the percentage. disk_space_ok reads the last line and strips
# everything that is not a digit, so the header must be present for the
# test to exercise the real parse rather than a simplified one.
# Built with echo rather than printf: the percentage being stubbed contains
# a literal '%', which printf would read as a format specifier. The first
# draft did exactly that and emitted `printf: invalid format character` on
# stderr while still passing, because disk_space_ok's `tr -dc '0-9'` strips
# the mangled output back into something usable — a test helper quietly
# testing the wrong string.
stub_df() {
    mkdir -p "$FIXTURE_DIR/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'echo "Use%"'
        echo "echo '$1'"
    } >"$FIXTURE_DIR/bin/df"
    chmod +x "$FIXTURE_DIR/bin/df"
    DF_BIN="$FIXTURE_DIR/bin/df"
}

@test "disk_space_ok: accepts usage below the threshold" {
    stub_df "2%"
    DISK_USAGE_THRESHOLD_PCT=90

    run disk_space_ok /downloads
    [ "$status" -eq 0 ]
}

@test "disk_space_ok: rejects usage above the threshold" {
    stub_df "95%"
    DISK_USAGE_THRESHOLD_PCT=90

    run disk_space_ok /downloads
    [ "$status" -ne 0 ]
}

@test "disk_space_ok: treats the threshold itself as not ok" {
    # The comparison is strict (<), so 90 with a threshold of 90 is already
    # a warning. Pinning the boundary here so it cannot drift silently.
    stub_df "90%"
    DISK_USAGE_THRESHOLD_PCT=90

    run disk_space_ok /downloads
    [ "$status" -ne 0 ]
}

@test "disk_space_ok: fails closed when df output is unparseable" {
    mkdir -p "$FIXTURE_DIR/bin"
    printf '#!/usr/bin/env bash\nprintf "no percentage here\\n"\n' \
        >"$FIXTURE_DIR/bin/df"
    chmod +x "$FIXTURE_DIR/bin/df"
    DF_BIN="$FIXTURE_DIR/bin/df"
    DISK_USAGE_THRESHOLD_PCT=90

    run disk_space_ok /downloads
    [ "$status" -ne 0 ]
}

# --- inode_space_ok ---
#
# A filesystem can be empty in bytes and full in inodes: ext4 fixes its
# inode table at mkfs time, so a tree of many small files can exhaust it
# while df -h still reports free space. Same stub technique as above, with
# `df --output=ipcent`.

@test "inode_space_ok: accepts usage below the threshold" {
    stub_df "3%"
    DISK_USAGE_THRESHOLD_PCT=90

    run inode_space_ok /downloads
    [ "$status" -eq 0 ]
}

@test "inode_space_ok: rejects usage above the threshold" {
    stub_df "97%"
    DISK_USAGE_THRESHOLD_PCT=90

    run inode_space_ok /downloads
    [ "$status" -ne 0 ]
}

@test "inode_space_ok: treats the threshold itself as not ok" {
    # Mirrors disk_space_ok: the comparison is strict (<).
    stub_df "90%"
    DISK_USAGE_THRESHOLD_PCT=90

    run inode_space_ok /downloads
    [ "$status" -ne 0 ]
}

@test "inode_space_ok: treats a dash as healthy, not as unreadable" {
    # Filesystems that allocate inodes dynamically report "-" in this
    # column. Measured on the Debian target 2026-08-01 against a btrfs loop
    # device: IUse% is "-", and the digit filter leaves an empty string —
    # which under the byte side's fail-closed rule would raise a permanent
    # false alarm on every cycle. "-" means "no table to exhaust", so it
    # must pass. This is the case the function exists to get right.
    stub_df "-"
    DISK_USAGE_THRESHOLD_PCT=90

    run inode_space_ok /downloads
    [ "$status" -eq 0 ]
}

@test "inode_space_ok: fails closed when df output is unparseable" {
    # Genuinely unreadable output is different from "-" and keeps the byte
    # side's behaviour: report rather than assume healthy.
    mkdir -p "$FIXTURE_DIR/bin"
    printf '#!/usr/bin/env bash\nprintf "no percentage here\\n"\n' \
        >"$FIXTURE_DIR/bin/df"
    chmod +x "$FIXTURE_DIR/bin/df"
    DF_BIN="$FIXTURE_DIR/bin/df"
    DISK_USAGE_THRESHOLD_PCT=90

    run inode_space_ok /downloads
    [ "$status" -ne 0 ]
}

# --- all_critical_state_healthy ---
#
# Pure: twenty flag variables, one test expression, no external calls. The
# contract worth protecting is that ANY single flag set is enough to make it
# false — a new drift signal added to the reconcile pass but forgotten here
# would silently stop failing the run, which is the failure shape V1-11 had
# (a condition that influenced the exit code without being part of this
# gate). These cases do not reproduce that bug; they pin the invariant that
# would make a repeat visible.

CRITICAL_FLAGS=(
    ADDRESS_CHANGED WG_ENDPOINT_DRIFTED FORWARDING_DRIFTED DISK_SPACE_LOW
    INODE_SPACE_LOW
    TAILSCALE_OFFLINE TAILSCALE_PREFS_DRIFTED TAILSCALE_NETFILTER_DRIFTED
    FIREWALL_DRIFTED DOCKER_NETFILTER_DRIFTED FW_INACTIVE COMPOSE_INACTIVE
    COMPOSE_RUNTIME_DRIFTED COMPOSE_FILE_MISSING COMPOSE_FILE_UNSAFE
    COMPOSE_FILE_METADATA_DRIFTED CONFIG_DRIFTED CANONICAL_CONFIG_INVALID
    WEBDAV_UNIT_INACTIVE WEBDAV_RUNTIME_DRIFTED CADDY_INACTIVE
    CADDY_RUNTIME_DRIFTED DNSMASQ_INACTIVE DNSMASQ_RUNTIME_DRIFTED
)

clear_critical_flags() {
    local flag
    for flag in "${CRITICAL_FLAGS[@]}"; do
        printf -v "$flag" '%s' 0
    done
}

@test "all_critical_state_healthy: true when every flag is clear" {
    clear_critical_flags
    run all_critical_state_healthy
    [ "$status" -eq 0 ]
}

@test "all_critical_state_healthy: false when any single flag is set" {
    local flag
    for flag in "${CRITICAL_FLAGS[@]}"; do
        clear_critical_flags
        printf -v "$flag" '%s' 1
        if all_critical_state_healthy; then
            printf 'flag %s did not make the gate fail\n' "$flag" >&2
            return 1
        fi
    done
}

@test "all_critical_state_healthy: covers exactly the flags the function reads" {
    # Guards against the list above drifting from install.sh. If a flag is
    # added to the function without being added here, the loop above would
    # keep passing while covering less than it claims.
    local body extracted
    body="$(extract_function RECONCILE_SCRIPT all_critical_state_healthy)"
    extracted="$(
        printf '%s\n' "$body" |
            grep -oE '\$[A-Z_]+' | tr -d '$' | sort -u
    )"
    [ "$extracted" = "$(printf '%s\n' "${CRITICAL_FLAGS[@]}" | sort -u)" ]
}
