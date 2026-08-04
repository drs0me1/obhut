#!/usr/bin/env bats
# Coverage for B2: Stage 2 bounces the tailscaled daemon without dragging the
# service stack along with it (Q1-33, DD-51).
#
# Two drop-ins written later in the run make tailscaled the runtime anchor of
# the stack: tailscaled.service.d/98-master-stack.conf and 99-caddy-tailnet.conf
# declare `Wants=` on docker-tailscale-fw, master-compose, master-webdav and
# caddy, and those four units declare `PartOf=tailscaled.service` back. On a
# *reinstall* both halves already exist on disk while Stage 2 runs, so every job
# Stage 2 enqueues against tailscaled reaches the whole stack:
#
#   - a start job pulls the `Wants=` set (measured: an already-active tailscaled
#     given `enable --now` started caddy and master-webdav from inactive), and
#   - a restart job propagates through `PartOf=` to all four.
#
# Neither is blocking — `systemctl start` returned in 0s with master-compose
# still activating — which is the actual hazard: master-compose's ExecStart
# (`docker compose up`) and its ExecStartPre (`master-compose-ipv4`, which
# rewrites /root/docker/.env) take no lock, so they run the *previous* version's
# config concurrently with Stages 3-6 rewriting exactly those files.
#
# The invariants below are derived from install.sh's own text: the coupling is
# read out of the unit definitions rather than restated, so removing a drop-in
# or adding a sixth PartOf unit does not silently make these tests vacuous.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

setup() {
    FIXTURE_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

stage2() {
    awk '/^progress_stage_begin 2 /{f=1} f{print} f&&/^progress_stage_begin 3 /{exit}' \
        "$INSTALL_SH"
}

# Executable systemctl statements only: a line whose first word is `systemctl`.
# The operator-recovery hints print the same command inside an echo, and those
# are advice for a human running it with the installer stopped, where pulling
# the stack back up is the whole point.
systemctl_statements() {
    grep -nE '^[[:space:]]*systemctl[[:space:]]' "$INSTALL_SH"
}

# Every unit named by a Wants= line inside a tailscaled.service.d drop-in.
tailscaled_wants_units() {
    awk '
        /tailscaled\.service\.d\// { indropin = 1; next }
        indropin && /^Wants=/ {
            sub(/^Wants=/, "")
            n = split($0, parts, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
        }
        indropin && /^[A-Z_]+DROPIN$/ { indropin = 0 }
    ' "$INSTALL_SH" | sort -u
}

# Every unit definition in install.sh that declares PartOf=...tailscaled.service.
partof_tailscaled_count() {
    grep -cE '^PartOf=.*tailscaled\.service' "$INSTALL_SH"
}

@test "the coupling that makes job isolation necessary is still declared" {
    # If this ever fails, the guards below may have become redundant rather than
    # wrong — check the drop-ins before relaxing anything.
    local wants
    wants="$(tailscaled_wants_units)"
    [ -n "$wants" ]
    grep -q '^master-compose.service$' <<<"$wants"
    grep -q '^docker-tailscale-fw.service$' <<<"$wants"
    grep -q '^master-webdav.service$' <<<"$wants"
    grep -q '^caddy.service$' <<<"$wants"
    [ "$(partof_tailscaled_count)" -ge 4 ]
}

@test "Stage 2 never starts tailscaled with enable --now" {
    local s2
    s2="$(stage2)"
    [ -n "$s2" ]
    ! grep -qE '^[[:space:]]*systemctl[[:space:]]+enable[[:space:]]+--now[[:space:]]+tailscaled' \
        <<<"$s2"
    # ...and not via the reordered spelling either.
    ! grep -qE '^[[:space:]]*systemctl[[:space:]]+enable[[:space:]]+tailscaled[[:space:]]+--now' \
        <<<"$s2"
    grep -qE '^systemctl enable tailscaled$' <<<"$s2"
}

@test "Stage 2 starts tailscaled only when it is not already running" {
    local s2
    s2="$(stage2)"
    grep -qE '^systemctl is-active --quiet tailscaled \|\| systemctl start tailscaled$' \
        <<<"$s2"
}

@test "every executable tailscaled restart is dependency-isolated" {
    local line found=0
    while IFS= read -r line; do
        [[ "$line" == *tailscaled* ]] || continue
        [[ "$line" == *" restart "* ]] || continue
        found=$((found + 1))
        [[ "$line" == *"--job-mode=ignore-dependencies"* ]] || {
            echo "unguarded restart: $line" >&2
            return 1
        }
    done < <(systemctl_statements)
    # The login retry loop's daemon reset. If this drops to zero the rule above
    # is passing vacuously.
    [ "$found" -ge 1 ]
}

@test "the operator recovery hint still tells a human the plain command" {
    # Deliberate exception: with the installer stopped, a human wants the
    # dependencies pulled. The rule above must keep distinguishing the two.
    grep -q 'echo "  systemctl restart tailscaled && tailscale up" >&2' "$INSTALL_SH"
}

@test "no start job is enqueued when tailscaled is already active" {
    local block
    block="$(stage2 | grep -A1 -E '^systemctl enable tailscaled$')"
    [ -n "$block" ]

    cat >"$FIXTURE_DIR/run.sh" <<EOF
set -Eeuo pipefail
systemctl() {
    printf '%s\n' "systemctl \$*" >>"$FIXTURE_DIR/calls"
    [[ "\$1" != "is-active" ]] || return 0
    return 0
}
$block
EOF

    run bash "$FIXTURE_DIR/run.sh"
    [ "$status" -eq 0 ]
    grep -q '^systemctl enable tailscaled$' "$FIXTURE_DIR/calls"
    ! grep -q 'systemctl start tailscaled' "$FIXTURE_DIR/calls"
}

@test "a start job is enqueued when tailscaled is not running" {
    local block
    block="$(stage2 | grep -A1 -E '^systemctl enable tailscaled$')"

    cat >"$FIXTURE_DIR/run.sh" <<EOF
set -Eeuo pipefail
systemctl() {
    printf '%s\n' "systemctl \$*" >>"$FIXTURE_DIR/calls"
    [[ "\$1" != "is-active" ]] || return 1
    return 0
}
$block
EOF

    run bash "$FIXTURE_DIR/run.sh"
    [ "$status" -eq 0 ]
    grep -q 'systemctl start tailscaled' "$FIXTURE_DIR/calls"
}

@test "the daemon reset hands the isolation flag to systemctl in one invocation" {
    # The failure this rules out is the flag drifting onto a neighbouring
    # command, or the restart splitting into a stop/start pair that loses it.
    # Argument *order* is not pinned: systemctl permutes options and unit names,
    # and `restart tailscaled --job-mode=ignore-dependencies` was measured to
    # isolate the job just as well.
    local line
    line="$(grep -E '^[[:space:]]*systemctl[[:space:]]+restart[[:space:]].*tailscaled' \
        "$INSTALL_SH")"
    [ -n "$line" ]

    cat >"$FIXTURE_DIR/run.sh" <<EOF
set -Eeuo pipefail
systemctl() {
    printf '%s\n' "\$#" >"$FIXTURE_DIR/argc"
    printf '%s\n' "\$@" >"$FIXTURE_DIR/args"
}
$line
EOF

    run bash "$FIXTURE_DIR/run.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$FIXTURE_DIR/argc")" -eq 3 ]
    grep -qx -e 'restart' "$FIXTURE_DIR/args"
    grep -qx -e '--job-mode=ignore-dependencies' "$FIXTURE_DIR/args"
    grep -qx -e 'tailscaled' "$FIXTURE_DIR/args"
}
