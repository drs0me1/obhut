#!/usr/bin/env bats
# What the Compose stack actually depends on, address-wise. See
# docs/design-decisions.md DD-56.
#
# V1-3 removed the last container binding that used the Tailscale IPv4, but
# master-compose-ipv4 went on treating that address as a precondition for
# starting the stack at all, and reconcile went on routing a change in it into
# a full five-container restart. The stack binds 127.0.0.1 and the public
# IPv4; the services that do listen on the Tailscale address (dnsmasq, Caddy,
# rclone WebDAV) are host units repaired on their own paths.
#
# master-compose-ipv4 is a whole embedded script, so it is extracted and run
# for real against stub `ip` output. Two fixture substitutions are made and
# both are asserted after the fact: STACK_DIR is redirected out of /root, and
# the wait budget is shortened so the failure case does not take two minutes.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

extract_script() {
    sed -n "/<<'${1}'\$/,/^${1}\$/p" "$INSTALL_SH" | sed '1d;$d'
}

extract_function() {
    local marker="$1" func_name="$2"
    sed -n "/<<'${marker}'\$/,/^${marker}\$/p" "$INSTALL_SH" |
        sed '1d;$d' |
        awk -v fn="$func_name" '
            $0 == fn "() {" {found=1}
            found {print}
            found && /^}/ {exit}
        '
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    mkdir -p "$FIXTURE_DIR/stub" "$FIXTURE_DIR/stack"

    HELPER="$FIXTURE_DIR/master-compose-ipv4"
    extract_script IP_REFRESH_SCRIPT |
        sed -e "s|^STACK_DIR=\"/root/docker\"$|STACK_DIR=\"$FIXTURE_DIR/stack\"|" \
            -e 's/^COMPOSE_ADDRESS_WAIT_SECONDS=120$/COMPOSE_ADDRESS_WAIT_SECONDS=2/' \
        >"$HELPER"
    grep -q "^STACK_DIR=\"$FIXTURE_DIR/stack\"$" "$HELPER"
    grep -q '^COMPOSE_ADDRESS_WAIT_SECONDS=2$' "$HELPER"
    chmod 0755 "$HELPER"

    # `ip` stub. STUB_WAN/STUB_TS select which addresses exist.
    cat >"$FIXTURE_DIR/stub/ip" <<'STUB'
#!/bin/sh
case "$*" in
    *"route get"*)
        [ "${STUB_WAN:-1}" = "1" ] || exit 0
        echo "1.1.1.1 via 10.0.2.2 dev eth0 src 10.0.2.15 uid 0"
        ;;
    *"dev tailscale0"*)
        [ "${STUB_TS:-1}" = "1" ] || exit 0
        echo "40: tailscale0    inet 100.64.0.10/32 scope global tailscale0"
        ;;
    *"dev eth0"*)
        echo "2: eth0    inet 10.0.2.15/24 brd 10.0.2.255 scope global eth0"
        ;;
esac
exit 0
STUB
    chmod 0755 "$FIXTURE_DIR/stub/ip"
    ENV_FILE="$FIXTURE_DIR/stack/.env"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

run_helper() {
    STUB_WAN="$1" STUB_TS="$2" PATH="$FIXTURE_DIR/stub:$PATH" \
        bash "$HELPER" >"$FIXTURE_DIR/out" 2>"$FIXTURE_DIR/err"
}

# --- master-compose-ipv4 ---

@test "compose addresses: both present are both recorded" {
    run_helper 1 1

    grep -Fxq 'PUBLIC_IPV4=10.0.2.15' "$ENV_FILE"
    grep -Fxq 'TAILSCALE_IPV4=100.64.0.10' "$ENV_FILE"
}

@test "compose addresses: a missing Tailscale address does not block the stack" {
    # The point of DD-56. Before it, this exited 1 and master-compose.service
    # failed with it, so no container ran without Tailscale.
    local rc=0
    run_helper 1 0 || rc=$?

    [ "$rc" -eq 0 ]
    grep -Fxq 'PUBLIC_IPV4=10.0.2.15' "$ENV_FILE"
    grep -Fxq 'TAILSCALE_IPV4=' "$ENV_FILE"
    grep -Fq 'UYARI: Tailscale IPv4' "$FIXTURE_DIR/err"
}

@test "compose addresses: a missing WAN address still fails closed" {
    # PUBLIC_IPV4 is interpolated into three container port bindings, so it
    # remains a hard precondition.
    local rc=0
    run_helper 0 1 || rc=$?

    [ "$rc" -eq 1 ]
    grep -Fq 'WAN IPv4' "$FIXTURE_DIR/err"
    [ ! -e "$ENV_FILE" ]
}

@test "compose addresses: no leftover temp file when the WAN wait fails" {
    run_helper 0 1 || true

    run bash -c "ls -A '$FIXTURE_DIR/stack'"
    [ "$output" = "" ]
}

# --- reconcile's use of the recorded addresses ---

@test "compose_env_addresses_current: true only when both lines match" {
    eval "$(extract_function RECONCILE_SCRIPT compose_env_addresses_current)"
    ENV_FILE="$FIXTURE_DIR/env"
    CURRENT_PUBLIC_IPV4=203.0.113.10
    CURRENT_TAILSCALE_IPV4=100.64.0.10

    printf 'PUBLIC_IPV4=203.0.113.10\nTAILSCALE_IPV4=100.64.0.10\n' >"$ENV_FILE"
    compose_env_addresses_current

    printf 'PUBLIC_IPV4=203.0.113.10\nTAILSCALE_IPV4=100.64.0.99\n' >"$ENV_FILE"
    rc=0
    compose_env_addresses_current || rc=$?
    [ "$rc" -ne 0 ]

    rm -f "$ENV_FILE"
    rc=0
    compose_env_addresses_current || rc=$?
    [ "$rc" -ne 0 ]
}

@test "reconcile: only a public address change forces a stack restart" {
    body="$(extract_script RECONCILE_SCRIPT)"
    gate="$(
        awk '/^STACK_RESTART_REQUIRED=0$/ {found=1} found {print}
             found && /^fi$/ {exit}' <<<"$body"
    )"

    [ -n "$gate" ]
    [ "$(grep -c 'PUBLIC_ADDRESS_CHANGED' <<<"$gate")" -eq 2 ]
    # The union flag must not be what bounces five containers any more.
    rc=0
    grep -Fq 'ADDRESS_CHANGED" -eq 1' <<<"$(grep -v PUBLIC_ADDRESS_CHANGED <<<"$gate")" || rc=$?
    [ "$rc" -ne 0 ]
}

@test "reconcile: a stale address record is refreshed without a stack restart" {
    body="$(extract_script RECONCILE_SCRIPT)"

    # The refresh exists, is driven by the same predicate the postcondition
    # uses, and calls the helper rather than restarting master-compose.
    grep -Fq 'if ! compose_env_addresses_current; then' <<<"$body"
    grep -Fq 'if "$COMPOSE_IPV4_HELPER" >/dev/null; then' <<<"$body"
    grep -Fq 'COMPOSE_IPV4_HELPER="/usr/local/sbin/master-compose-ipv4"' <<<"$body"
    # Exactly two uses of the predicate: the refresh and the postcondition.
    [ "$(grep -c 'compose_env_addresses_current' <<<"$body")" -eq 3 ]
}

@test "reconcile: the three host services still repair on a Tailscale change" {
    # Removing the stack restart must not have removed the repairs that
    # genuinely depend on the Tailscale address.
    body="$(extract_script RECONCILE_SCRIPT)"

    [ "$(grep -c '^if \[\[ "\$TAILSCALE_ADDRESS_CHANGED" -eq 1 ||$' <<<"$body")" -eq 3 ]
}
