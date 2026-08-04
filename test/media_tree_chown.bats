#!/usr/bin/env bats
# The Stage 4 media-tree ownership repair (install.sh, "find
# "$DOWNLOADS_PATH/media" ... -exec chown"). See SECURITY_REVIEW.md finding
# D3 and docs/design-decisions.md DD-53.
#
# `find` defaults to -P, so it does not follow symlinks -- it reports them.
# A `chown` without -h then dereferences the path it is handed, which turns
# a symlink planted inside the media tree into a redirect onto an arbitrary
# host file. That was measured on the test host before the fix.
#
# These cases run the real command extracted from install.sh against a
# fixture tree, with a stub `chown` on PATH that only records how it was
# invoked. Nothing is actually chowned, so no root is needed and no real
# ownership anywhere is touched.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# The command is top-level code rather than a function, so it is extracted
# by its first line through the line carrying -exec, not by the
# function-body technique the other suites use.
extract_media_chown() {
    awk '
        /^find "\$DOWNLOADS_PATH\/media" \\$/ {found=1}
        found {print}
        found && /-exec chown/ {exit}
    ' "$INSTALL_SH"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    SNIPPET="$FIXTURE_DIR/snippet.sh"
    CHOWN_LOG="$FIXTURE_DIR/chown.log"
    export CHOWN_LOG

    extract_media_chown >"$SNIPPET"

    # Fail loudly if the command ever moves or is reworded, rather than
    # silently testing an empty snippet.
    grep -q '^find "\$DOWNLOADS_PATH/media" \\$' "$SNIPPET"
    grep -q -- '-exec chown' "$SNIPPET"

    mkdir -p "$FIXTURE_DIR/stub" "$FIXTURE_DIR/media"
    cat >"$FIXTURE_DIR/stub/chown" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CHOWN_LOG"
STUB
    chmod 0755 "$FIXTURE_DIR/stub/chown"

    printf 'payload\n' >"$FIXTURE_DIR/sentinel"
    printf 'payload\n' >"$FIXTURE_DIR/media/regular.mkv"
    ln -s "$FIXTURE_DIR/sentinel" "$FIXTURE_DIR/media/planted.mkv"

    DOWNLOADS_PATH="$FIXTURE_DIR"
    export DOWNLOADS_PATH
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

run_snippet() {
    # The predicate selects entries that are not 1000:1000. A runner that
    # happens to be exactly 1000:1000 cannot produce a matching fixture
    # without root, so the case would pass vacuously.
    if [ "$(id -u):$(id -g)" = "1000:1000" ]; then
        skip "test runner is 1000:1000; the predicate cannot select the fixture"
    fi
    PATH="$FIXTURE_DIR/stub:$PATH" bash "$SNIPPET"
}

@test "media chown: find selects the planted symlink (the hazard is real)" {
    run_snippet

    [ -s "$CHOWN_LOG" ]
    grep -Fq "$FIXTURE_DIR/media/planted.mkv" "$CHOWN_LOG"
}

@test "media chown: every invocation is non-dereferencing (-h)" {
    run_snippet

    [ -s "$CHOWN_LOG" ]
    # Every recorded invocation must carry -h before the owner spec, or a
    # selected symlink would have its target chowned instead of itself.
    while IFS= read -r invocation; do
        case "$invocation" in
            "-h 1000:1000 "*) ;;
            *) printf 'dereferencing invocation: %s\n' "$invocation" >&2
               return 1 ;;
        esac
    done <"$CHOWN_LOG"
}

@test "media chown: the regular file is still repaired" {
    run_snippet

    grep -Fq "$FIXTURE_DIR/media/regular.mkv" "$CHOWN_LOG"
}
