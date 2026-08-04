#!/usr/bin/env bats
# Coverage for A5: the OnFailure arc closes back onto reconcile, and every
# unit on that arc is restarted behind the repair cooldown (Q1-30, DD-49).
#
# Five units declare OnFailure=master-network-reconcile.service, and reconcile
# restarts all five. A synchronous failure does not spin — the OnFailure job is
# raised while reconcile is still active and systemd merges it into the running
# job. The asynchronous one does: a daemon that starts cleanly, lets reconcile
# exit, then dies seconds later trips Restart=on-failure, hits its start limit,
# fails, and fires OnFailure — which runs reconcile immediately instead of on
# the twenty-minute timer.
#
# Until Q1-30 three of those five (master-webdav, dnsmasq, caddy) were the only
# restart paths in reconcile with no restart_budget_available gate, and each
# called `systemctl reset-failed` first — which clears systemd's start-limit
# counter, the other brake. docs/testing.md already names the cooldown "the
# only thing between a repeatedly-failing repair and a restart loop", and DD-21
# defines it as "a brake on the event-driven (OnFailure) paths".
#
# The gate check below is derived from install.sh rather than restated: the
# unit set comes from install.sh's own OnFailure lines, so wiring a new unit
# into the arc and restarting it unbraked fails this suite on its own.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# Restart sites that are deliberately NOT behind their own budget call, each
# with the reason it is exempt. Anything else must be gated.
#
#   master-compose.service — COMPOSE_INACTIVE means the whole stack is down,
#     where a fifteen-minute wait costs far more than a slow retry. Each
#     attempt is already bounded by `--wait-timeout 180` and
#     TimeoutStartSec=330, so the loop is slow by construction.
#   docker-tailscale-fw.service — restarted only under STACK_RESTART_REQUIRED,
#     which is set in an earlier block that does call the budget (for
#     master-compose). The gate is real, it just is not in this block.
EXEMPT_BLOCK_MARKERS=(
    'STACK_RESTART_REQUIRED'
    'COMPOSE_INACTIVE'
)

extract_function() {
    local func_name="$1"
    sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH" |
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
        extract_function restart_budget_available
        extract_function record_container_restart
    } >"$FUNCS_FILE"
    grep -q '^restart_budget_available() {' "$FUNCS_FILE"
    grep -q '^record_container_restart() {' "$FUNCS_FILE"

    # shellcheck disable=SC1090
    source "$FUNCS_FILE"

    RESTART_STATE_DIR="$FIXTURE_DIR/run"
    RESTART_COOLDOWN_SECONDS=900
    INSTALL_BIN="$FIXTURE_DIR/fake-install"
    cat >"$INSTALL_BIN" <<'FAKE_INSTALL'
#!/usr/bin/env bash
set -eu
mkdir -p "${@: -1}"
FAKE_INSTALL
    chmod +x "$INSTALL_BIN"

    RECONCILE="$FIXTURE_DIR/reconcile.sh"
    sed -n "/<<'RECONCILE_SCRIPT'\$/,/^RECONCILE_SCRIPT\$/p" "$INSTALL_SH" |
        sed '1d;$d' >"$RECONCILE"
    grep -q '^RECOVERY_FAILED=0$' "$RECONCILE"

    RECOVERY="$FIXTURE_DIR/recovery.sh"
    awk '/^RECOVERY_FAILED=0$/ {found=1} found {print}' "$RECONCILE" \
        >"$RECOVERY"

    # Every top-level if-block of the whole script, not just the recovery
    # half: the GRO repair runs before RECOVERY_FAILED=0 and is a restart site
    # too, so a slice starting there would miss a unit added to the arc above
    # it. Blocks inside functions are indented and are not picked up.
    BLOCK_DIR="$FIXTURE_DIR/blocks"
    mkdir -p "$BLOCK_DIR"
    awk -v dir="$BLOCK_DIR" '
        /^if / { n++; f = sprintf("%s/%03d", dir, n); inblk = 1 }
        inblk { print > f }
        inblk && /^fi$/ { inblk = 0; close(f) }
    ' "$RECONCILE"
    [ "$(find "$BLOCK_DIR" -type f | wc -l)" -gt 10 ]
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# The units on the arc, read out of install.sh's own unit definitions: walk
# back from each OnFailure line to the `cat >` that opened the file it lives
# in, and take the unit name out of that path (plain unit or .service.d
# drop-in).
arc_units() {
    awk '
        /^cat >\/etc\/systemd\/system\// {
            path = $0
            sub(/^cat >/, "", path)
            sub(/ .*/, "", path)
            sub(/^\/etc\/systemd\/system\//, "", path)
            sub(/\.service\.d\/.*/, ".service", path)
            current = path
        }
        /^OnFailure=master-network-reconcile\.service$/ && current != "" {
            print current
        }
    ' "$INSTALL_SH" | sort -u
}

block_condition() {
    awk '{print} /then$/ {exit}' "$1"
}

@test "the arc is five units wide and includes reconcile's own restart targets" {
    local units=""
    units="$(arc_units)"
    [ "$(wc -l <<<"$units")" -eq 5 ]
    grep -Fxq 'docker-tailscale-fw.service' <<<"$units"
    grep -Fxq 'master-compose.service' <<<"$units"
    grep -Fxq 'master-webdav.service' <<<"$units"
    grep -Fxq 'dnsmasq.service' <<<"$units"
    grep -Fxq 'caddy.service' <<<"$units"
}

@test "reconcile does not put itself on the arc" {
    # master-network-reconcile.service must carry neither OnFailure nor
    # Restart=, or a failing repair would retrigger itself directly.
    local unit=""
    unit="$(
        sed -n "/<<'RECONCILE_SYSTEMD'\$/,/^RECONCILE_SYSTEMD\$/p" "$INSTALL_SH"
    )"
    [ -n "$unit" ]
    ! grep -q '^OnFailure=' <<<"$unit"
    ! grep -q '^Restart=' <<<"$unit"
}

@test "every restart of an arc unit is behind the repair cooldown" {
    local units block body condition unit ungated=0 checked=0
    units="$(arc_units)"

    for block in "$BLOCK_DIR"/*; do
        condition="$(block_condition "$block")"
        body="$(cat "$block")"
        while IFS= read -r unit; do
            grep -Fq "restart $unit" <<<"$body" ||
                grep -Fq "start $unit" <<<"$body" ||
                continue
            checked=$((checked + 1))
            grep -Fq 'restart_budget_available' <<<"$body" && continue
            local exempt=0 marker
            for marker in "${EXEMPT_BLOCK_MARKERS[@]}"; do
                grep -Fq "$marker" <<<"$condition" && exempt=1 && break
            done
            if [[ "$exempt" -eq 0 ]]; then
                printf 'ungated restart of %s:\n%s\n' "$unit" "$condition" >&2
                ungated=1
            fi
        done <<<"$units"
    done

    [ "$ungated" -eq 0 ]
    # Not vacuous: the arc units really are restarted from these blocks.
    [ "$checked" -ge 5 ]
}

@test "reset-failed is never reached before the budget is consulted" {
    # reset-failed clears systemd's start-limit counter, so a block that calls
    # it without a budget check has removed both brakes at once.
    local block body condition marker exempt mismatched=0
    for block in "$BLOCK_DIR"/*; do
        body="$(cat "$block")"
        grep -Fq 'reset-failed' <<<"$body" || continue
        grep -Fq 'restart_budget_available' <<<"$body" && continue
        condition="$(block_condition "$block")"
        exempt=0
        for marker in "${EXEMPT_BLOCK_MARKERS[@]}"; do
            grep -Fq "$marker" <<<"$condition" && exempt=1 && break
        done
        if [[ "$exempt" -eq 0 ]]; then
            printf 'reset-failed without a budget check:\n%s\n' "$condition" >&2
            mismatched=1
        fi
    done
    [ "$mismatched" -eq 0 ]
}

@test "an address change bypasses the cooldown on all three daemons" {
    # A Tailscale address change is not a failure signal — every one of these
    # binds that address, so the rebind must not be deferred. Same exemption
    # master-compose already had for ADDRESS_CHANGED.
    #
    # Matched against the recovery half flattened to one line: grep -F treats
    # an embedded newline as a pattern separator, so a multi-line -F pattern
    # would pass on any single line of it.
    local flat=""
    flat="$(tr -s ' \n' ' ' <"$RECOVERY")"
    grep -Fq 'if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ]] || restart_budget_available master-webdav; then' <<<"$flat"
    grep -Fq 'if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 || "$DNS_CONFIG_DRIFTED" -eq 1 ]] || restart_budget_available dnsmasq; then' <<<"$flat"
    grep -Fq 'if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 || "$CADDY_CONFIG_DRIFTED" -eq 1 ]] || restart_budget_available caddy; then' <<<"$flat"
}

@test "an inactive or misbehaving daemon does not bypass the cooldown" {
    # A daemon that is merely down or failing its runtime probe is exactly the
    # failure signal the arc amplifies, so it must reach the budget. Only the
    # address rebind and the config-restore follow-up are exempt.
    local flat=""
    flat="$(tr -s ' \n' ' ' <"$RECOVERY")"
    local flag
    for flag in WEBDAV_UNIT_INACTIVE WEBDAV_RUNTIME_DRIFTED \
                DNSMASQ_INACTIVE DNSMASQ_RUNTIME_DRIFTED \
                CADDY_INACTIVE CADDY_RUNTIME_DRIFTED; do
        if grep -Fq "\"\$$flag\" -eq 1 ]] || restart_budget_available" \
                <<<"$flat"; then
            printf '%s bypasses the cooldown\n' "$flag" >&2
            return 1
        fi
    done
}

@test "the new stamps round-trip between writer and reader" {
    # restart_budget_available and record_container_restart must agree on the
    # filename for each new target, or the gate silently never engages.
    local target
    for target in master-webdav dnsmasq caddy; do
        run restart_budget_available "$target"
        [ "$status" -eq 0 ]

        record_container_restart "$target"

        run restart_budget_available "$target"
        [ "$status" -ne 0 ]
    done
}

@test "each new stamp is scoped to its own unit" {
    record_container_restart caddy

    run restart_budget_available caddy
    [ "$status" -ne 0 ]
    run restart_budget_available dnsmasq
    [ "$status" -eq 0 ]
    run restart_budget_available master-webdav
    [ "$status" -eq 0 ]
}

@test "a deferred daemon restart still fails the run" {
    # Skipping a repair must never look like a clean cycle.
    local recovery=""
    recovery="$(cat "$RECOVERY")"
    local unit
    for unit in master-webdav dnsmasq Caddy; do
        grep -Fq "HATA: $unit yeniden başlatması" <<<"$recovery"
    done
    [ "$(grep -c 'cooldown içinde; tekrarlanmadı' <<<"$recovery")" -ge 4 ]
}
