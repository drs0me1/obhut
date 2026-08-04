#!/usr/bin/env bats
# Coverage for B1: one definition of "online" in the installer, and waits that
# honour the duration they print (Q1-32, DD-50).
#
# Stage 2 used to decide "is this node online?" by parsing the first line of
# `tailscale status --self` and looking for the substring "offline" — the only
# one of the script's three online predicates that read human-readable output,
# and the only one with no tests. It also returned true for BackendState=
# Starting, since that prints a self line with no "offline" in it, so Stage 2's
# final gate could pass on a node that was not Running yet.
#
# Its three call sites now use tailscale_login_complete, which is JSON-backed
# and covered in test/tailscale_login.bats. That function wraps
# `tailscale status --json` in `timeout $TAILSCALE_LOGIN_STATUS_TIMEOUT`, so a
# wedged daemon makes each probe cost seconds instead of milliseconds — which
# is why both waits had to stop counting iterations and start counting time.
# An iteration-bounded loop of 90 rounds with a 3-second probe and a 2-second
# sleep runs for 450 seconds while printing "180 saniye içinde".

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

setup() {
    FIXTURE_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# Lift a top-level wait out of Stage 2 and shrink its deadline so the bound can
# be measured in seconds rather than minutes. Only the deadline constant is
# rewritten; the loop's shape is whatever install.sh actually has.
extract_wait() {
    local start_pattern="$1" end_pattern="$2" deadline="$3"
    awk -v start="$start_pattern" -v end="$end_pattern" '
        index($0, start) { found = 1 }
        found { print }
        found && index($0, end) { exit }
    ' "$INSTALL_SH" | sed "s/+ 60))/+ $deadline))/; s/+ 180))/+ $deadline))/"
}

@test "the text-parsing online predicate is gone" {
    ! grep -q '^tailscale_is_online() {' "$INSTALL_SH"
    ! grep -q 'tailscale_is_online' "$INSTALL_SH"
}

@test "no decision is made from tailscale status text output" {
    # `tailscale status --self` may still be printed for the operator, but no
    # predicate may key on its wording. One use survives, the informational
    # echo that tells the operator which node it found.
    [ "$(grep -c 'tailscale status --self' "$INSTALL_SH")" -eq 1 ]
    grep -q 'echo "Sunucu zaten bir Tailscale ağına bağlı."' "$INSTALL_SH"
    # The substring match that used to decide it.
    ! grep -qE '[!=]=[[:space:]]*\*offline\*' "$INSTALL_SH"
}

@test "Stage 2 gates on the JSON-backed predicate" {
    local stage2=""
    stage2="$(
        awk '/^progress_stage_begin 2 /{f=1} f{print} f&&/^progress_stage_begin 3 /{exit}' \
            "$INSTALL_SH"
    )"
    [ -n "$stage2" ]
    # Both waits and the post-wait re-check.
    [ "$(grep -c 'tailscale_login_complete' <<<"$stage2")" -ge 4 ]
}

@test "both Stage 2 waits are bounded by wall clock, not by iteration count" {
    local stage2=""
    stage2="$(
        awk '/^progress_stage_begin 2 /{f=1} f{print} f&&/^progress_stage_begin 3 /{exit}' \
            "$INSTALL_SH"
    )"
    grep -Fq 'TAILSCALE_ONLINE_DEADLINE=$((SECONDS + 60))' <<<"$stage2"
    grep -Fq 'TAILSCALE_CONNECT_DEADLINE=$((SECONDS + 180))' <<<"$stage2"
    grep -Fq '(( SECONDS < TAILSCALE_ONLINE_DEADLINE )) || break' <<<"$stage2"
    grep -Fq '(( SECONDS < TAILSCALE_CONNECT_DEADLINE )) || break' <<<"$stage2"
    # The shapes these replaced.
    ! grep -q 'for _ in \$(seq 1 60); do' <<<"$stage2"
    ! grep -q 'for _ in \$(seq 1 90); do' <<<"$stage2"
}

@test "the connect gate stops at its deadline even when every probe is slow" {
    # The regression the deadline exists to prevent: with a wedged daemon each
    # probe costs TAILSCALE_LOGIN_STATUS_TIMEOUT seconds, and an
    # iteration-bounded loop would run for iterations x (probe + sleep).
    local block start elapsed
    # From the flag initialisation, so the extracted block is self-contained
    # under `set -u`.
    block="$(extract_wait 'TAILSCALE_CONNECTED=0' 'done' 3)"
    [ -n "$block" ]
    grep -Fq 'SECONDS + 3' <<<"$block"

    cat >"$FIXTURE_DIR/run.sh" <<EOF
set -Eeuo pipefail
tailscale() { return 0; }
tailscale_login_complete() { sleep 1; return 1; }
$block
printf 'connected=%s\n' "\$TAILSCALE_CONNECTED"
EOF

    start=$SECONDS
    run bash "$FIXTURE_DIR/run.sh"
    elapsed=$((SECONDS - start))

    [ "$status" -eq 0 ]
    [[ "$output" == *"connected=0"* ]]
    # Deadline 3s + at most one in-flight probe (1s) + one sleep (2s).
    [ "$elapsed" -le 8 ]
}

@test "the connect gate returns as soon as the node is up" {
    local block start elapsed
    block="$(extract_wait 'TAILSCALE_CONNECTED=0' 'done' 30)"

    cat >"$FIXTURE_DIR/run.sh" <<EOF
set -Eeuo pipefail
tailscale() { return 0; }
tailscale_login_complete() { return 0; }
$block
printf 'connected=%s\n' "\$TAILSCALE_CONNECTED"
EOF

    start=$SECONDS
    run bash "$FIXTURE_DIR/run.sh"
    elapsed=$((SECONDS - start))

    [ "$status" -eq 0 ]
    [[ "$output" == *"connected=1"* ]]
    # No sleep on the success path: it must not wait out the deadline.
    [ "$elapsed" -le 3 ]
}

@test "the registration wait stops at its deadline when the node never comes up" {
    local block start elapsed
    block="$(extract_wait 'TAILSCALE_ONLINE_DEADLINE=' 'done' 3)"
    [ -n "$block" ]

    cat >"$FIXTURE_DIR/run.sh" <<EOF
set -Eeuo pipefail
tailscale_login_complete() { sleep 1; return 1; }
$block
printf 'exited\n'
EOF

    start=$SECONDS
    run bash "$FIXTURE_DIR/run.sh"
    elapsed=$((SECONDS - start))

    [ "$status" -eq 0 ]
    [[ "$output" == *"exited"* ]]
    [ "$elapsed" -le 8 ]
}
