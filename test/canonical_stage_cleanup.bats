#!/usr/bin/env bats
# Coverage for A3: cleanup_master_setup decides whether the staged canonical
# generation was published by calling canonical_stage_is_current, not by
# re-deriving the answer inline (Q1-28, DD-47).
#
# Until Q1-28 the same question was asked twice inside the same cleanup, two
# different ways. restore_dns_stack_on_failure called the predicate, which
# normalises BOTH sides with readlink -f; a hundred lines later the staged-dir
# block resolved only the `current` symlink and compared it against the raw
# mktemp string. If any path component above the canonical root were ever a
# symlink the two would answer differently within one cleanup run: the DNS
# rollback snapshot would be discarded as "already published" and the staged
# directory `current` points at would then be rm -rf'd as "not published",
# leaving a dangling pointer that makes canonical_bundle_ok fail on every
# subsequent reconcile.
#
# The equality branch is NOT dead and is not what this change removes: a
# signal landing between the `mv -Tf` swap and the CANONICAL_STAGE_DIR reset
# reaches it, which test/dns_stack_rollback.bats pins deliberately. What A3
# removes is the second, divergent implementation of one predicate.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

extract_outer_function() {
    local func_name="$1"
    awk -v fn="$func_name" '
        $0 == fn "() {" { found=1 }
        found { print }
        found && /^}/ { exit }
    ' "$INSTALL_SH"
}

# The staged-generation block lives inside cleanup_master_setup, which cannot
# be sourced (it resets traps and exits). Lifting the block into a function
# keeps it executable rather than only greppable. The anchor deliberately
# matches on the variable rather than on the whole condition, so an inverted
# or rewritten condition still extracts and is caught by a behavioural test
# instead of by extraction failure.
extract_stage_cleanup_block() {
    awk '
        /^    if \[\[ -n "\$CANONICAL_STAGE_DIR"/ { found = 1 }
        found { print }
        found && $0 == "    fi" { exit }
    ' "$INSTALL_SH"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    BLOCK="$(extract_stage_cleanup_block)"
    [ -n "$BLOCK" ]

    {
        extract_outer_function canonical_stage_is_current
        # Verbatim, for the tests that assert on the real allowlist.
        printf 'cleanup_staged_generation() {\n%s\n}\n' "$BLOCK"
        # Same block with the allowlist re-rooted at the fixture, so the
        # deleting branch is observable at all. Without this the hardcoded
        # /usr/local prefix would make every fixture path survive and the
        # behavioural tests would pass vacuously.
        printf 'cleanup_staged_generation_here() {\n%s\n}\n' \
            "$(sed 's|/usr/local/share/master-stack/|"$CANONICAL_ROOT"/|' \
                <<<"$BLOCK")"
    } >"$FUNCS_FILE"

    grep -q '^canonical_stage_is_current() {' "$FUNCS_FILE"
    grep -q 'rm -rf -- "\$CANONICAL_STAGE_DIR"' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    CANONICAL_ROOT="$FIXTURE_DIR/canonical"
    mkdir -p "$CANONICAL_ROOT"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

publish() {
    CANONICAL_STAGE_DIR="$1"
    mkdir -p "$CANONICAL_STAGE_DIR"
    ln -sfn "$(basename "$CANONICAL_STAGE_DIR")" "$CANONICAL_ROOT/current"
}

@test "a published generation is recognised as current" {
    publish "$CANONICAL_ROOT/.generation.new"
    run canonical_stage_is_current
    [ "$status" -eq 0 ]
}

@test "an unpublished generation is not current" {
    CANONICAL_STAGE_DIR="$CANONICAL_ROOT/.generation.new"
    mkdir -p "$CANONICAL_STAGE_DIR"
    run canonical_stage_is_current
    [ "$status" -ne 0 ]
}

@test "a superseded generation is not current" {
    publish "$CANONICAL_ROOT/.generation.old"
    local superseded="$CANONICAL_STAGE_DIR"
    publish "$CANONICAL_ROOT/.generation.new"
    CANONICAL_STAGE_DIR="$superseded"
    run canonical_stage_is_current
    [ "$status" -ne 0 ]
}

@test "no staged generation is not current" {
    CANONICAL_STAGE_DIR=""
    run canonical_stage_is_current
    [ "$status" -ne 0 ]
}

@test "a symlinked path above the canonical root does not flip the verdict" {
    # This is the case the inline comparison got wrong. The staged directory
    # is named through a symlinked prefix — exactly what mktemp -d would hand
    # back — while `current` resolves to the real path underneath it.
    local real="$FIXTURE_DIR/real-share"
    mkdir -p "$real"
    ln -sfn real-share "$FIXTURE_DIR/share"
    CANONICAL_ROOT="$FIXTURE_DIR/share"
    publish "$CANONICAL_ROOT/.generation.new"

    # The predicate normalises both sides and gets it right.
    run canonical_stage_is_current
    [ "$status" -eq 0 ]

    # A raw string comparison against a resolved `current` does not, which is
    # what made the removed inline block delete the live generation.
    local resolved
    resolved="$(readlink -f -- "$CANONICAL_ROOT/current")"
    [ "$resolved" != "$CANONICAL_STAGE_DIR" ]
}

@test "cleanup keeps a generation that reached the current pointer" {
    # The signal window between `mv -Tf` and the CANONICAL_STAGE_DIR reset.
    publish "$CANONICAL_ROOT/.generation.new"
    cleanup_staged_generation_here
    [ -d "$CANONICAL_STAGE_DIR" ]
    # Resolved on both sides: on macOS the fixture path itself sits under a
    # symlinked /tmp, so the raw string would not match its own resolution.
    [ "$(readlink -f -- "$CANONICAL_ROOT/current")" \
      = "$(readlink -f -- "$CANONICAL_STAGE_DIR")" ]
}

@test "cleanup removes a generation that never reached the current pointer" {
    CANONICAL_STAGE_DIR="$CANONICAL_ROOT/.generation.new"
    mkdir -p "$CANONICAL_STAGE_DIR"
    cleanup_staged_generation_here
    [ ! -e "$CANONICAL_STAGE_DIR" ]
}

@test "cleanup keeps the generation the current pointer was moved to" {
    # A superseded stage dir is deleted; the live one is not. Pins that the
    # predicate is read against `current`, not against staging order.
    publish "$CANONICAL_ROOT/.generation.old"
    local superseded="$CANONICAL_STAGE_DIR"
    publish "$CANONICAL_ROOT/.generation.new"
    local live="$CANONICAL_STAGE_DIR"

    CANONICAL_STAGE_DIR="$superseded"
    cleanup_staged_generation_here

    [ ! -e "$superseded" ]
    [ -d "$live" ]
}

@test "cleanup refuses to delete outside the generation namespace" {
    # The case allowlist is the only thing standing between an aborted install
    # and `rm -rf` on an arbitrary path, so it is tested rather than assumed:
    # this fixture is unpublished, which is the branch that deletes.
    CANONICAL_STAGE_DIR="$FIXTURE_DIR/not-a-generation"
    mkdir -p "$CANONICAL_STAGE_DIR"
    ! canonical_stage_is_current
    cleanup_staged_generation
    [ -d "$CANONICAL_STAGE_DIR" ]
}

@test "cleanup asks the shared predicate instead of re-deriving the answer" {
    local body=""
    body="$(extract_outer_function cleanup_master_setup)"
    [ -n "$body" ]
    grep -Fq '! canonical_stage_is_current' <<<"$body"
    # One predicate, one implementation: cleanup must not resolve the current
    # pointer itself, or the two halves of this function can disagree.
    ! grep -Fq 'master-stack/current' <<<"$body"
    ! grep -Fq 'canonical_active_target' <<<"$body"
}

@test "the deleting branch keeps its generation-namespace allowlist" {
    grep -Fq '/usr/local/share/master-stack/.generation.*)' <<<"$BLOCK"
}
