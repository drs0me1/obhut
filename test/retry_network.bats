#!/usr/bin/env bats
# Unit tests for retry_network(), the bounded retry + mandatory timeout
# wrapper around install.sh's network-dependent steps (SECURITY_REVIEW
# finding L8, DD-24, docs/testing.md Tier 2).
#
# Unlike the other suites in this directory, the function under test lives
# in install.sh's own body rather than inside an embedded heredoc, so it is
# extracted directly. install.sh is never sourced whole: it execs itself
# under systemd-inhibit at the top level and would refuse to run here
# anyway.
#
# The point of these cases is that all four paths are deterministic. The
# design note originally claimed the recovery path -- transient failure
# followed by success -- could not be tested without a real flaky network.
# That was wrong: a stub that fails once and then succeeds reproduces it
# exactly, which is what "case 4" does.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

setup() {
    if ! command -v timeout >/dev/null 2>&1; then
        skip "requires GNU coreutils timeout (target platform is Debian; this host has none)"
    fi

    FIXTURE_DIR="$(mktemp -d)"

    # Extract the constants block plus the function body, from the first
    # NET_RETRY_ constant through the function's closing brace at column 0.
    awk '/^NET_RETRY_ATTEMPTS=/,/^}$/' "$INSTALL_SH" >"$FIXTURE_DIR/retry.sh"

    # retry_network only calls out to progress_stage_note, which needs the
    # whole progress subsystem. Stub it: this suite is about control flow,
    # exit codes and timing, not rendering.
    MASTER_CURRENT_PERCENT=50
    MASTER_CURRENT_STAGE_LABEL="test"
    progress_stage_note() { :; }

    # shellcheck disable=SC1090
    source "$FIXTURE_DIR/retry.sh"
}

teardown() {
    # Must not return non-zero: setup() skips before FIXTURE_DIR exists on
    # hosts without GNU timeout, and a failing teardown turns a legitimate
    # skip into a reported failure.
    if [ -n "${FIXTURE_DIR:-}" ]; then
        rm -rf "$FIXTURE_DIR"
    fi
    return 0
}

@test "retry_network: returns immediately when the command succeeds" {
    run retry_network "ok" 5 5 -- true
    [ "$status" -eq 0 ]
    # No warning should be emitted on a first-attempt success.
    [ -z "$output" ]
}

@test "retry_network: exhausts its attempts on a persistent failure" {
    run retry_network "persistent" 5 5 -- false
    [ "$status" -eq 1 ]
    [[ "$output" == *"1. deneme başarısız"* ]]
    [[ "$output" == *"2. deneme başarısız"* ]]
    [[ "$output" == *"3 denemenin tamamı başarısız"* ]]
}

@test "retry_network: reports a timeout distinctly from a command failure" {
    # A hang is the failure this wrapper exists for: the script holds a
    # systemd shutdown inhibitor and the flock reconcile shares, so an
    # unbounded download blocks both. 124 is timeout(1)'s own exit code.
    NET_RETRY_ATTEMPTS=2
    run retry_network "hanging" 1 1 -- sleep 30
    [ "$status" -eq 124 ]
    [[ "$output" == *"zaman aşımı"* ]]
    [[ "$output" != *"denemenin tamamı başarısız"* ]]
}

@test "retry_network: recovers when a later attempt succeeds" {
    cat >"$FIXTURE_DIR/flaky.sh" <<EOF
#!/usr/bin/env bash
# Fails once, then succeeds -- a deterministic stand-in for the transient
# registry error (Docker Hub 502) that motivated L8.
if [ -f "$FIXTURE_DIR/flag" ]; then exit 0; fi
touch "$FIXTURE_DIR/flag"
exit 1
EOF
    chmod +x "$FIXTURE_DIR/flaky.sh"

    run retry_network "flaky" 5 5 -- "$FIXTURE_DIR/flaky.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1. deneme başarısız"* ]]
    [[ "$output" != *"2. deneme başarısız"* ]]
}

@test "retry_network: passes arguments through untouched" {
    run retry_network "args" 5 5 -- printf '%s|%s' "bir iki" "üç"
    [ "$status" -eq 0 ]
    [ "$output" = "bir iki|üç" ]
}
