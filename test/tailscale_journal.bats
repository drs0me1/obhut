#!/usr/bin/env bats
# Regression coverage for the node-not-found journal classifier. Under
# pipefail, `journalctl | grep -q` can report a found early match as failure
# when journalctl receives SIGPIPE. The production helper must consume the
# complete stream without hiding a genuine journalctl error.

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
    extract_outer_function tailscale_journal_has_node_not_found >"$FUNCS_FILE"
    grep -q '^tailscale_journal_has_node_not_found() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"
    set -o pipefail
    MASTER_SETUP_STARTED_AT="2026-08-02T00:00:00+03:00"
    PRODUCER_MARKER="$FIXTURE_DIR/producer-finished"
    JOURNAL_MATCH=0
    JOURNAL_FAIL=0

    journalctl() {
        local index=0
        trap 'exit 141' PIPE
        if [[ "$JOURNAL_MATCH" -eq 1 ]]; then
            printf 'control: 404 node not found\n'
        fi
        # Larger than a typical pipe buffer. An early-closing grep -q makes
        # this producer take SIGPIPE before it can write the marker.
        while [[ "$index" -lt 6000 ]]; do
            printf 'tailscaled ordinary journal tail line %s\n' "$index"
            index=$((index + 1))
        done
        printf 'finished\n' >"$PRODUCER_MARKER"
        [[ "$JOURNAL_FAIL" -eq 0 ]]
    }
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "an early match remains true after a journal larger than the pipe buffer" {
    JOURNAL_MATCH=1

    run tailscale_journal_has_node_not_found

    [ "$status" -eq 0 ]
    [ -e "$PRODUCER_MARKER" ]
}

@test "a complete journal without the message returns false" {
    run tailscale_journal_has_node_not_found

    [ "$status" -ne 0 ]
    [ -e "$PRODUCER_MARKER" ]
}

@test "a real journalctl failure is not hidden by a matching line" {
    JOURNAL_MATCH=1
    JOURNAL_FAIL=1

    run tailscale_journal_has_node_not_found

    [ "$status" -ne 0 ]
    [ -e "$PRODUCER_MARKER" ]
}
