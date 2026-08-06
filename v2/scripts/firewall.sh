#!/usr/bin/env bash
# Host INPUT + DOCKER-USER politikası. Staging zincir, atomik swap.
# Üçüncü taraf DOCKER-USER kuralları silinmez. Docker zincirleri silinmez.
set -Eeuo pipefail

STATE_FILE="${STATE_FILE:-/etc/master-stack/state.env}"
DEFAULTS_FILE="${DEFAULTS_FILE:-}"
MODE="${1:-apply}"

die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Kullanım: firewall.sh [apply|--check]
EOF
}

case "$MODE" in
    apply | "") MODE=apply ;;
    --check) MODE=check ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

# shellcheck disable=SC1090
[[ -r "$STATE_FILE" ]] || die "state.env yok: $STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

: "${WAN_INTERFACE:?}"
: "${WAN_IPV4:=}"
: "${TAILSCALE_IF:=tailscale0}"
: "${CHAIN_INPUT:=MASTER-INPUT}"
: "${CHAIN_DOCKER:=MASTER-DOCKER}"
: "${WG_PUBLIC_PORT:=65171}"
: "${QBIT_PUBLIC_PORT:=65173}"

if [[ -n "$DEFAULTS_FILE" && -r "$DEFAULTS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$DEFAULTS_FILE"
fi

ensure_jump() {
    local bin="$1" parent="$2" chain="$3"
    if ! "$bin" -w 5 -C "$parent" -j "$chain" 2>/dev/null; then
        "$bin" -w 5 -I "$parent" 1 -j "$chain"
    fi
}

# Tailscale'in ts-input jump'ı MASTER-INPUT'tan önce olmalı; aksi halde
# WAN DROP, UDP 41641 / NDP sonrası TS kurallarını gölgeler.
ensure_ts_input_precedence() {
    local bin="$1" pos=""
    if ! "$bin" -w 5 -L ts-input -n >/dev/null 2>&1; then
        return 0
    fi
    if ! "$bin" -w 5 -C INPUT -j ts-input 2>/dev/null; then
        "$bin" -w 5 -I INPUT 1 -j ts-input
    fi
    while "$bin" -w 5 -C INPUT -j "$CHAIN_INPUT" 2>/dev/null; do
        "$bin" -w 5 -D INPUT -j "$CHAIN_INPUT"
    done
    pos="$("$bin" -w 5 -L INPUT -n --line-numbers |
        awk '$2 == "ts-input" { print $1; exit }')"
    if [[ -n "$pos" ]]; then
        "$bin" -w 5 -I INPUT "$((pos + 1))" -j "$CHAIN_INPUT"
    else
        "$bin" -w 5 -I INPUT 1 -j "$CHAIN_INPUT"
    fi
}

create_staging() {
    local bin="$1" prefix="$2" name="" _
    for _ in $(seq 1 20); do
        name="${prefix}$RANDOM"
        if "$bin" -w 5 -N "$name" 2>/dev/null; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    die "staging zinciri oluşturulamadı ($bin)"
}

activate_named() {
    # Staging önce parent'a bağlanır; sonra eski final kaldırılır ve rename yapılır.
    # DOCKER-USER / INPUT içindeki diğer (üçüncü taraf) kurallar silinmez.
    local bin="$1" parent="$2" staging="$3" final="$4"
    "$bin" -w 5 -I "$parent" 1 -j "$staging"
    while "$bin" -w 5 -C "$parent" -j "$final" 2>/dev/null; do
        "$bin" -w 5 -D "$parent" -j "$final"
    done
    if "$bin" -w 5 -L "$final" -n >/dev/null 2>&1; then
        "$bin" -w 5 -F "$final"
        "$bin" -w 5 -X "$final"
    fi
    "$bin" -w 5 -E "$staging" "$final"
    ensure_jump "$bin" "$parent" "$final"
    # rename sonrası staging adına kalan jump'ı temizle (olmamalı, yine de)
    while "$bin" -w 5 -C "$parent" -j "$staging" 2>/dev/null; do
        "$bin" -w 5 -D "$parent" -j "$staging"
    done
}

apply_input4() {
    local bin=iptables staging
    staging="$(create_staging "$bin" MASTER-NEXT-IN-)"
    "$bin" -w 5 -A "$staging" -i lo -j ACCEPT
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp --dport "$WG_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp --dport "$QBIT_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" INPUT "$staging" "$CHAIN_INPUT"
}

apply_docker4() {
    local bin=iptables staging
    "$bin" -w 5 -L DOCKER-USER -n >/dev/null 2>&1 ||
        die "DOCKER-USER yok; Docker çalışıyor mu?"
    staging="$(create_staging "$bin" MASTER-NEXT-DK-)"
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j RETURN
    # WAN IP adresi gömülmez; arayüz + orijinal hedef port yeterli.
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp \
        -m conntrack --ctstate NEW --ctorigdstport "$QBIT_PUBLIC_PORT" -j RETURN
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp \
        -m conntrack --ctstate NEW --ctorigdstport "$WG_PUBLIC_PORT" -j RETURN
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" DOCKER-USER "$staging" "$CHAIN_DOCKER"
}

apply_input6() {
    local bin=ip6tables staging
    command -v "$bin" >/dev/null || die "ip6tables gerekli"
    staging="$(create_staging "$bin" MASTER-NEXT-IN6-)"
    "$bin" -w 5 -A "$staging" -i lo -j ACCEPT
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j ACCEPT
    # NDP/RA ve PMTU: WAN IPv6 default (fe80::…) komşu çözümü buna bağlı.
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type parameter-problem -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type echo-reply -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type router-solicitation -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type neighbour-solicitation -j ACCEPT
    "$bin" -w 5 -A "$staging" -p ipv6-icmp --icmpv6-type neighbour-advertisement -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" INPUT "$staging" "$CHAIN_INPUT"
}

apply_docker6() {
    local bin=ip6tables staging
    "$bin" -w 5 -L DOCKER-USER -n >/dev/null 2>&1 ||
        die "ip6tables DOCKER-USER yok"
    staging="$(create_staging "$bin" MASTER-NEXT-DK6-)"
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j RETURN
    "$bin" -w 5 -A "$staging" -j DROP
    activate_named "$bin" DOCKER-USER "$staging" "$CHAIN_DOCKER"
}

check_jump() {
    local bin="$1" parent="$2" chain="$3"
    "$bin" -w 5 -C "$parent" -j "$chain" 2>/dev/null ||
        die "$bin: $parent -> $chain jump yok"
}

check_ts_input_precedence() {
    local bin="$1" ts_pos="" master_pos=""
    if ! "$bin" -w 5 -L ts-input -n >/dev/null 2>&1; then
        return 0
    fi
    if ! "$bin" -w 5 -C INPUT -j ts-input 2>/dev/null; then
        return 0
    fi
    ts_pos="$("$bin" -w 5 -L INPUT -n --line-numbers |
        awk '$2 == "ts-input" { print $1; exit }')"
    master_pos="$("$bin" -w 5 -L INPUT -n --line-numbers |
        awk -v c="$CHAIN_INPUT" '$2 == c { print $1; exit }')"
    [[ -n "$ts_pos" && -n "$master_pos" ]] ||
        die "$bin: ts-input / $CHAIN_INPUT satır numarası okunamadı"
    [[ "$ts_pos" -lt "$master_pos" ]] ||
        die "$bin: INPUT sırası hatalı (ts-input=$ts_pos, $CHAIN_INPUT=$master_pos)"
}

if [[ "$MODE" == check ]]; then
    check_jump iptables INPUT "$CHAIN_INPUT"
    check_jump iptables DOCKER-USER "$CHAIN_DOCKER"
    check_jump ip6tables INPUT "$CHAIN_INPUT"
    check_jump ip6tables DOCKER-USER "$CHAIN_DOCKER"
    check_ts_input_precedence iptables
    check_ts_input_precedence ip6tables
    printf 'firewall: politika jumplari yerinde\n'
    exit 0
fi

apply_input4
ensure_ts_input_precedence iptables
apply_docker4
apply_input6
ensure_ts_input_precedence ip6tables
apply_docker6
printf 'firewall: politika uygulandı (WAN if=%s)\n' "$WAN_INTERFACE"
