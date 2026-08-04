#!/usr/bin/env bats
# Every bounded wait in install.sh must bound itself by wall-clock time, not
# by an iteration count, so the duration its error message promises is the
# duration it actually waits. See docs/design-decisions.md DD-50 (Stage 2),
# DD-52 (the firewall helper) and DD-55 (the three remaining sites).
#
# Two of the three are whole embedded scripts, so they are extracted and run
# for real against a stub `ip` that never produces an address and costs a
# measurable amount of time per probe. That cost is what separates a deadline
# from a counter: with a probe as expensive as the whole budget, an
# iteration-bounded loop overruns by a multiple, while a deadline stops at the
# budget. The third lives inside master-network-reconcile's top level and is
# asserted structurally.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

extract_script() {
    sed -n "/<<'${1}'\$/,/^${1}\$/p" "$INSTALL_SH" | sed '1d;$d'
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    mkdir -p "$FIXTURE_DIR/stub"

    # `ip` that always succeeds, prints nothing (so no address is ever
    # parsed) and costs three seconds per call.
    cat >"$FIXTURE_DIR/stub/ip" <<'STUB'
#!/bin/sh
sleep 3
exit 0
STUB
    chmod 0755 "$FIXTURE_DIR/stub/ip"
    # Never reached; present so `command -v` succeeds at script start.
    for stub_bin in rclone; do
        printf '#!/bin/sh\nexit 0\n' >"$FIXTURE_DIR/stub/$stub_bin"
        chmod 0755 "$FIXTURE_DIR/stub/$stub_bin"
    done
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

# --- master-compose-ipv4 (master-compose.service's ExecStartPre) ---

@test "master-compose-ipv4: its wait ends on the clock, not on a count" {
    local script="$FIXTURE_DIR/master-compose-ipv4"
    extract_script IP_REFRESH_SCRIPT |
        sed 's/^COMPOSE_ADDRESS_WAIT_SECONDS=120$/COMPOSE_ADDRESS_WAIT_SECONDS=3/' \
            >"$script"
    grep -q '^COMPOSE_ADDRESS_WAIT_SECONDS=3$' "$script"
    chmod 0755 "$script"

    local start=$SECONDS rc=0
    PATH="$FIXTURE_DIR/stub:$PATH" bash "$script" >/dev/null 2>"$FIXTURE_DIR/err" || rc=$?
    local elapsed=$((SECONDS - start))

    [ "$rc" -eq 1 ]
    # Lower bound too: without it the case would also pass against a loop
    # that never waited at all.
    [ "$elapsed" -ge 3 ]
    [ "$elapsed" -le 7 ]
    # The message must name the bound it actually honoured.
    grep -Fq "3 saniyede" "$FIXTURE_DIR/err"
}

# --- master-webdav-serve (master-webdav.service's ExecStart) ---

@test "master-webdav-serve: its wait ends on the clock, not on a count" {
    local script="$FIXTURE_DIR/master-webdav-serve"
    extract_script WEBDAV_SERVE_SCRIPT |
        sed 's/^WAIT_SECONDS=300$/WAIT_SECONDS=3/' >"$script"
    grep -q '^WAIT_SECONDS=3$' "$script"
    chmod 0755 "$script"

    local start=$SECONDS rc=0
    MEDIA_DIR="$FIXTURE_DIR" \
    WEBDAV_PORT=65113 \
    CREDENTIALS_DIRECTORY="$FIXTURE_DIR" \
    PATH="$FIXTURE_DIR/stub:$PATH" \
        bash "$script" >/dev/null 2>"$FIXTURE_DIR/err" || rc=$?
    local elapsed=$((SECONDS - start))

    [ "$rc" -eq 1 ]
    [ "$elapsed" -ge 3 ]
    [ "$elapsed" -le 7 ]
    grep -Fq "3 saniyede" "$FIXTURE_DIR/err"
}

# --- master-network-reconcile's address-ready wait (structural) ---

@test "reconcile: the address-ready wait is bounded by a deadline" {
    body="$(extract_script RECONCILE_SCRIPT)"

    grep -Fq 'ADDRESS_READY_DEADLINE=$((SECONDS + ADDRESS_READY_WAIT_SECONDS))' <<<"$body"
    grep -Fq 'while [[ "$SECONDS" -lt "$ADDRESS_READY_DEADLINE" ]]; do' <<<"$body"
    # The iteration-bounded form this replaced must not come back.
    rc=0
    grep -Fq 'seq 1 "$((ADDRESS_READY_WAIT_SECONDS / 2))"' <<<"$body" || rc=$?
    [ "$rc" -ne 0 ]
}

@test "Stage 2's tailscaled socket wait is bounded by a deadline" {
    grep -Fq 'TAILSCALED_SOCKET_DEADLINE=$((SECONDS + TAILSCALED_SOCKET_WAIT_SECONDS))' \
        "$INSTALL_SH"
    grep -Fq 'while [[ "$SECONDS" -lt "$TAILSCALED_SOCKET_DEADLINE" ]]' \
        "$INSTALL_SH" ||
        grep -Fq '[[ "$SECONDS" -lt "$TAILSCALED_SOCKET_DEADLINE" ]] || break' \
            "$INSTALL_SH"
    # The message must quote the variable rather than a literal, so the two
    # can never drift apart again.
    grep -Fq 'soketi ${TAILSCALED_SOCKET_WAIT_SECONDS} saniyede oluşmadı' \
        "$INSTALL_SH"
}

@test "no iteration-counted loop promises a duration" {
    # The invariant, stated as the rule rather than as a ban on seq: several
    # `for _ in $(seq 1 N)` loops in this file are legitimately
    # iteration-bounded -- the staging-chain name retries take no sleep at
    # all, and the postcondition retries claim no duration. What must never
    # recur is a loop that counts turns while its message promises seconds.
    awk '
        /for _ in \$\(seq 1 / {start = NR; window = 1; next}
        window && NR - start > 18 {window = 0}
        window && /saniyede|saniye içinde/ {
            printf "%d: loop at %d promises a duration: %s\n", NR, start, $0
            found = 1
            window = 0
        }
        END {exit found ? 1 : 0}
    ' "$INSTALL_SH" >"$FIXTURE_DIR/hits"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$FIXTURE_DIR/hits" >&2
        return 1
    fi
}
