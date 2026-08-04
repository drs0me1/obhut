#!/usr/bin/env bats
# Coverage for A2: a failed canonical bundle verification degrades reconcile
# instead of aborting it (Q1-27, DD-46).
#
# Before Q1-27 the first thing reconcile did after taking the stack lock was
# `canonical_bundle_ok || exit 1`. One wrong mode bit on one of the nine
# canonical entries therefore disabled address re-binding, firewall renewal,
# Tailscale repair, container restarts and disk reporting — none of which read
# the bundle at all — and the timer went on failing every 20 minutes with a
# single line of output. The script already had the right answer for an
# untrustworthy reference in CANONICAL_CONFIG_INVALID: set a flag, report it,
# skip only the dependent blocks, exit non-zero at the end. Q1-27 applies that
# same pattern to the bundle gate.
#
# These are structural tests over the reconcile heredoc. The gating is
# top-level control flow, not a function, so it cannot be sourced and called
# the way test/reconcile_functions.bats calls its predicates — the same
# constraint that makes test/reconcile_control_flow.bats's unit-file cases
# structural. What is checked here is the invariant rather than a transcript
# of the current lines: every top-level block that copies from $CANONICAL_DIR
# or calls a canonical restore helper must be gated, so a *new* ungated
# restore site added later fails these tests without anyone remembering to
# extend them.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# Tokens that mean "this block consumes the canonical bundle as its source of
# truth". The two helper names are here because their call sites do not
# mention $CANONICAL_DIR themselves.
CANONICAL_CONSUMERS=(
    '$CANONICAL_DIR/'
    'restore_missing_compose_file'
    'restore_quantum_config'
)

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    RECONCILE="$FIXTURE_DIR/reconcile.sh"
    sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH" |
        sed '1d;$d' >"$RECONCILE"

    # Fail loudly rather than passing over an empty extraction.
    grep -q '^canonical_bundle_ok() {' "$RECONCILE"
    grep -q '^RECOVERY_FAILED=0$' "$RECONCILE"

    BLOCK_DIR="$FIXTURE_DIR/blocks"
    mkdir -p "$BLOCK_DIR"

    # The recovery half only: everything from the first RECOVERY_FAILED=0
    # onwards. Function definitions above it also reference $CANONICAL_DIR,
    # and those are gated by their callers, not by themselves.
    awk '/^RECOVERY_FAILED=0$/ {found=1} found {print}' "$RECONCILE" \
        >"$FIXTURE_DIR/recovery.sh"

    # Split the recovery half into top-level if-blocks. The reconcile script
    # indents consistently, so a top-level block is `^if ` through `^fi$`.
    awk -v dir="$BLOCK_DIR" '
        /^if / { n++; f = sprintf("%s/%03d", dir, n); inblk = 1 }
        inblk { print > f }
        inblk && /^fi$/ { inblk = 0; close(f) }
    ' "$FIXTURE_DIR/recovery.sh"

    [ "$(find "$BLOCK_DIR" -type f | wc -l)" -gt 10 ]
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

block_condition() {
    awk '{print} /then$/ {exit}' "$1"
}

block_body() {
    awk 'body {print} /then$/ {body = 1}' "$1"
}

@test "the bundle gate sets a flag instead of exiting" {
    local gate=""
    gate="$(
        awk '/^CANONICAL_BUNDLE_INVALID=0$/ {found=1} found {print}
             found && /^fi$/ {exit}' "$RECONCILE"
    )"

    [ -n "$gate" ]
    grep -Fq 'if ! canonical_bundle_ok; then' <<<"$gate"
    grep -Fq 'CANONICAL_BUNDLE_INVALID=1' <<<"$gate"
    # The whole point of A2: no unconditional abort here any more.
    ! grep -Eq '^ *exit ' <<<"$gate"
    # And the operator still learns why repairs were withheld.
    grep -Fq 'HATA:' <<<"$gate"
}

@test "every canonical-restore block is gated on the bundle flag" {
    local block condition body token ungated=0
    for block in "$BLOCK_DIR"/*; do
        condition="$(block_condition "$block")"
        body="$(block_body "$block")"
        for token in "${CANONICAL_CONSUMERS[@]}"; do
            grep -Fq -- "$token" <<<"$body" || continue
            if ! grep -Fq 'CANONICAL_BUNDLE_INVALID' <<<"$condition"; then
                printf 'ungated canonical consumer (%s):\n%s\n' \
                    "$token" "$condition" >&2
                ungated=1
            fi
            break
        done
    done
    [ "$ungated" -eq 0 ]
}

@test "the gated set is not empty" {
    # Guards the test above from passing vacuously if the block splitter or
    # the recovery-half slice stops matching anything.
    local gated=0 block
    for block in "$BLOCK_DIR"/*; do
        block_condition "$block" | grep -Fq 'CANONICAL_BUNDLE_INVALID' &&
            gated=$((gated + 1))
    done
    [ "$gated" -ge 7 ]
}

@test "an invalid bundle is treated as at least as serious as invalid configs" {
    # CANONICAL_CONFIG_INVALID already withholds the dnsmasq/Caddy restore and
    # restart blocks. A bundle that fails verification subsumes that case: the
    # canonical files are not trustworthy at all, so wherever the narrower
    # flag gates, the broader one must gate too.
    local block condition mismatched=0
    for block in "$BLOCK_DIR"/*; do
        condition="$(block_condition "$block")"
        grep -Fq 'CANONICAL_CONFIG_INVALID" -eq 0' <<<"$condition" || continue
        if ! grep -Fq 'CANONICAL_BUNDLE_INVALID" -eq 0' <<<"$condition"; then
            printf 'config-gated but not bundle-gated:\n%s\n' "$condition" >&2
            mismatched=1
        fi
    done
    [ "$mismatched" -eq 0 ]
}

@test "an invalid bundle fails the run" {
    # Degrading must not turn into passing. The flag has to reach both the
    # health gate and RECOVERY_FAILED, or reconcile would exit 0 on a host
    # whose canonical copy is unverifiable.
    local healthy=""
    healthy="$(
        awk '/^all_critical_state_healthy\(\) \{$/ {found=1} found {print}
             found && /^}$/ {exit}' "$RECONCILE"
    )"
    grep -Fq 'CANONICAL_BUNDLE_INVALID' <<<"$healthy"

    grep -Fq '"$CANONICAL_BUNDLE_INVALID" -eq 1 ||' "$FIXTURE_DIR/recovery.sh"

    # The end-of-run postcondition sweep re-runs the check itself, so a bundle
    # broken *during* the run is caught even if the flag was clear at start.
    grep -Fq '! canonical_bundle_ok ||' "$RECONCILE"
}

@test "--check reports the bundle flag" {
    grep -Fq 'canonical_bundle=$CANONICAL_BUNDLE_INVALID' "$RECONCILE"
}

@test "bundle-independent repairs stay outside the gate" {
    # The regression A2 fixes is over-gating, not under-gating. These blocks
    # read nothing from the canonical bundle and must keep running when it is
    # unverifiable, otherwise the flag has merely moved the abort downwards.
    local block condition
    for block in "$BLOCK_DIR"/*; do
        condition="$(block_condition "$block")"
        case "$condition" in
            *FORWARDING_DRIFTED*|*TAILSCALE_PREFS_DRIFTED*|*DOCKER_NETFILTER_DRIFTED*)
                if grep -Fq 'CANONICAL_BUNDLE_INVALID' <<<"$condition"; then
                    printf 'over-gated block:\n%s\n' "$condition" >&2
                    return 1
                fi
                ;;
        esac
    done
}
