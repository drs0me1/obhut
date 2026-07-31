#!/usr/bin/env bats
# Unit tests for canonical_bundle_ok(), embedded in
# master-network-reconcile (itself a heredoc inside install.sh — see
# SECURITY_REVIEW.md findings H4/M7/M8/M10, docs/testing.md Tier 2).
#
# Why this function specifically: it is reconcile's first gate. If it
# returns non-zero the script exits before reaching any detection or
# repair logic, so the entire self-healing loop goes silent. And its
# correctness depends on agreement between two places that are ~2000
# lines apart in install.sh:
#
#   * Stage 6 decides which files go into the SHA256SUMS manifest;
#   * canonical_bundle_ok compares the manifest's entry list against a
#     hardcoded expected list, with an exact string equality.
#
# Nothing enforces that those two stay in sync, and neither `bash -n` nor
# `shellcheck` can see the mismatch. These tests therefore derive the
# expected file list from install.sh's own Stage 6 source rather than
# restating it, so the two sides are compared against each other rather
# than against this file's assumptions.
#
# Revised for V1-8: local DNS is no longer optional, so the manifest has
# exactly one shape and the function has one branch. The former
# DNS-disabled cases are gone; what replaces them is a regression guard
# that the old two-entry shape is now *rejected* (see the truncated-list
# test below), because a host still carrying a pre-V1-8 bundle must be
# caught rather than silently accepted.
#
# Scope: the manifest entry-list logic only. Hash verification is
# sha256sum's job and is stubbed out; ownership/mode checking is
# owned_file_ok's job and is covered by reconcile_functions.bats. Both
# are overridden here so these tests run on any POSIX host, with no GNU
# coreutils, no root, no systemd and no Docker.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# Same extraction technique as reconcile_functions.bats: pull the
# reconcile heredoc body out of install.sh, then isolate one function
# (from "name() {" to the matching top-level "}"). The full script is
# never sourced — it runs real flock/systemctl/docker calls at its top
# level.
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

# The file list Stage 6 feeds to sha256sum, read straight out of
# install.sh: a multi-line continuation ending at the first line without a
# trailing backslash.
stage6_manifest_files() {
    awk '
        /sha256sum -- \\$/ { collecting=1; next }
        collecting {
            sub(/^[[:space:]]+/, "")
            if (sub(/[[:space:]]*\\$/, "")) { print; next }
            print
            exit
        }
    ' "$INSTALL_SH"
}

# Builds a SHA256SUMS fixture in the canonical dir. Only the second field
# matters — canonical_bundle_ok reads entries with `awk 'NF == 2 {print $2}'`
# — so the digest column is filler.
write_manifest() {
    : >"$CANONICAL_DIR/SHA256SUMS"
    local entry
    for entry in "$@"; do
        printf '%s  %s\n' \
            "0000000000000000000000000000000000000000000000000000000000000000" \
            "$entry" >>"$CANONICAL_DIR/SHA256SUMS"
    done
}

write_stage6_manifest() {
    local files=()
    while IFS= read -r line; do files+=("$line"); done \
        < <(stage6_manifest_files)
    write_manifest "${files[@]}"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    FUNCS_FILE="$FIXTURE_DIR/funcs.sh"
    extract_function RECONCILE_SCRIPT canonical_bundle_ok >"$FUNCS_FILE"

    # Fail loudly if the function is renamed or its source moves in a way
    # this extraction can no longer find, rather than silently testing an
    # empty no-op.
    grep -q '^canonical_bundle_ok() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    # Out of scope for these tests, and both would otherwise drag in a
    # GNU-coreutils dependency this workstation doesn't have.
    owned_file_ok() { return 0; }

    AWK_BIN="$(command -v awk)"
    CANONICAL_DIR="$FIXTURE_DIR/canonical"
    mkdir -p "$CANONICAL_DIR"
    printf 'STACK_SCHEMA=10\n' >"$CANONICAL_DIR/state.env"

    # Stub sha256sum: these tests assert on the manifest's entry list, not
    # on digest verification.
    SHA256SUM_BIN="$FIXTURE_DIR/sha256sum-stub"
    printf '#!/bin/sh\nexit 0\n' >"$SHA256SUM_BIN"
    chmod 0755 "$SHA256SUM_BIN"

    # Sanity-check the extractor before any test relies on it; an empty
    # list would make every assertion below vacuously pass.
    [ -n "$(stage6_manifest_files)" ]
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "canonical_bundle_ok: accepts Stage 6's own manifest list" {
    write_stage6_manifest

    run canonical_bundle_ok
    [ "$status" -eq 0 ]
}

@test "canonical_bundle_ok: Stage 6 publishes exactly the eight expected entries" {
    # Pins the manifest's shape as well as its content. If someone adds a
    # ninth managed file to Stage 6 without extending canonical_bundle_ok's
    # expected list (or vice versa), the acceptance test above would still
    # pass on the derived list while the real function drifted; this one
    # catches the count changing at all.
    local files=()
    while IFS= read -r line; do files+=("$line"); done \
        < <(stage6_manifest_files)

    [ "${#files[@]}" -eq 8 ]
    [ "${files[0]}" = "state.env" ]
    [ "${files[1]}" = "compose.yaml" ]
}

@test "canonical_bundle_ok: rejects the pre-M10 list that omits compose.yaml" {
    write_manifest \
        state.env \
        dnsmasq-local-services.conf \
        dnsmasq-99-tailscale-order.conf \
        Caddyfile \
        caddy-99-tailnet-bind.conf \
        caddy-tailnet-env \
        tailscaled-99-caddy-tailnet.conf

    run canonical_bundle_ok
    [ "$status" -ne 0 ]
}

@test "canonical_bundle_ok: rejects the pre-V1-8 two-entry bundle" {
    # Before V1-8 a DNS-disabled install published a manifest of just
    # state.env and compose.yaml, and canonical_bundle_ok accepted it. Now
    # that DNS/Caddy are a fixed part of the stack, that shape means a host
    # is carrying a stale bundle and must be caught, not tolerated.
    write_manifest state.env compose.yaml

    run canonical_bundle_ok
    [ "$status" -ne 0 ]
}

@test "canonical_bundle_ok: rejects an extra entry appended to a correct list" {
    local files=()
    while IFS= read -r line; do files+=("$line"); done \
        < <(stage6_manifest_files)
    write_manifest "${files[@]}" unexpected-extra.conf

    run canonical_bundle_ok
    [ "$status" -ne 0 ]
}

@test "canonical_bundle_ok: rejects a correct set of entries in the wrong order" {
    # Documents that the comparison is order-sensitive: it is a single
    # string equality, not a set comparison. Anyone reordering Stage 6's
    # sha256sum arguments must reorder the expected list to match.
    local files=()
    while IFS= read -r line; do files+=("$line"); done \
        < <(stage6_manifest_files)
    [ "${#files[@]}" -ge 2 ]
    write_manifest "${files[1]}" "${files[0]}" "${files[@]:2}"

    run canonical_bundle_ok
    [ "$status" -ne 0 ]
}

@test "canonical_bundle_ok: rejects an unreadable manifest" {
    write_stage6_manifest
    rm -f "$CANONICAL_DIR/SHA256SUMS"

    run canonical_bundle_ok
    [ "$status" -ne 0 ]
}
