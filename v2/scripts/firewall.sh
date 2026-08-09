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
if [[ -n "${DEFAULTS_FILE:-}" && -r "$DEFAULTS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$DEFAULTS_FILE"
fi

: "${WAN_INTERFACE:?}"
: "${TAILSCALE_IF:?}"
: "${CHAIN_INPUT:?}"
: "${CHAIN_DOCKER:?}"
: "${CHAIN_STAGING_PREFIX:?}"
: "${WG_PUBLIC_PORT:?}"
: "${QBIT_PUBLIC_PORT:?}"
: "${SSH_PUBLIC_PORT:?}"
: "${TAILSCALE_UDP_PORT:?}"

input_line() {
    local bin="$1" target="$2"
    "$bin" -w 5 -L INPUT -n --line-numbers |
        awk -v t="$target" '$2 == t { print $1; exit }'
}

insert_pos_after_ts_input() {
    local bin="$1" ts_pos=""
    if "$bin" -w 5 -C INPUT -j ts-input 2>/dev/null; then
        ts_pos="$(input_line "$bin" ts-input)"
        if [[ -n "$ts_pos" ]]; then
            printf '%s\n' "$((ts_pos + 1))"
            return 0
        fi
    fi
    printf '1\n'
}

ensure_jump() {
    local bin="$1" parent="$2" chain="$3" pos=1
    if "$bin" -w 5 -C "$parent" -j "$chain" 2>/dev/null; then
        return 0
    fi
    if [[ "$parent" == "INPUT" ]]; then
        pos="$(insert_pos_after_ts_input "$bin")"
    fi
    "$bin" -w 5 -I "$parent" "$pos" -j "$chain"
}

ensure_ts_input_precedence() {
    local bin="$1" ts_pos="" master_before="" master_after="" _
    if ! "$bin" -w 5 -L ts-input -n >/dev/null 2>&1; then
        return 0
    fi
    if ! "$bin" -w 5 -C INPUT -j ts-input 2>/dev/null; then
        "$bin" -w 5 -I INPUT 1 -j ts-input
    fi

    for _ in $(seq 1 20); do
        ts_pos="$(input_line "$bin" ts-input)"
        [[ -n "$ts_pos" ]] || return 0

        master_before="$("$bin" -w 5 -L INPUT -n --line-numbers |
            awk -v c="$CHAIN_INPUT" -v ts="$ts_pos" \
                '$2 == c && $1+0 < ts+0 { print $1; exit }')"
        master_after="$("$bin" -w 5 -L INPUT -n --line-numbers |
            awk -v c="$CHAIN_INPUT" -v ts="$ts_pos" \
                '$2 == c && $1+0 > ts+0 { print $1; exit }')"

        if [[ -z "$master_before" ]]; then
            if [[ -z "$master_after" ]] &&
                ! "$bin" -w 5 -C INPUT -j "$CHAIN_INPUT" 2>/dev/null; then
                "$bin" -w 5 -I INPUT "$((ts_pos + 1))" -j "$CHAIN_INPUT"
            fi
            while true; do
                ts_pos="$(input_line "$bin" ts-input)"
                master_after="$("$bin" -w 5 -L INPUT -n --line-numbers |
                    awk -v c="$CHAIN_INPUT" -v ts="$ts_pos" \
                        '$2 == c && $1+0 > ts+0 { n++; if (n==2) { print $1; exit } }')"
                [[ -n "$master_after" ]] || break
                "$bin" -w 5 -D INPUT "$master_after"
            done
            return 0
        fi

        if [[ -z "$master_after" ]]; then
            "$bin" -w 5 -I INPUT "$((ts_pos + 1))" -j "$CHAIN_INPUT"
        fi
        master_before="$("$bin" -w 5 -L INPUT -n --line-numbers |
            awk -v c="$CHAIN_INPUT" -v ts="$ts_pos" \
                '$2 == c && $1+0 < ts+0 { print $1; exit }')"
        [[ -n "$master_before" ]] || continue
        "$bin" -w 5 -D INPUT "$master_before"
    done
    die "$bin: ts-input / $CHAIN_INPUT sırası düzeltilemedi"
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
    # INPUT'ta staging, varsa ts-input'un hemen arkasına girer (gölgelememek için).
    local bin="$1" parent="$2" staging="$3" final="$4" pos=1
    if [[ "$parent" == "INPUT" ]]; then
        pos="$(insert_pos_after_ts_input "$bin")"
    fi
    "$bin" -w 5 -I "$parent" "$pos" -j "$staging"
    while "$bin" -w 5 -C "$parent" -j "$final" 2>/dev/null; do
        "$bin" -w 5 -D "$parent" -j "$final"
    done
    if "$bin" -w 5 -L "$final" -n >/dev/null 2>&1; then
        "$bin" -w 5 -F "$final"
        "$bin" -w 5 -X "$final"
    fi
    "$bin" -w 5 -E "$staging" "$final"
    ensure_jump "$bin" "$parent" "$final"
    while "$bin" -w 5 -C "$parent" -j "$staging" 2>/dev/null; do
        "$bin" -w 5 -D "$parent" -j "$staging"
    done
}

apply_input4() {
    local bin=iptables staging
    staging="$(create_staging "$bin" "${CHAIN_STAGING_PREFIX}IN-")"
    "$bin" -w 5 -A "$staging" -i lo -j ACCEPT
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j ACCEPT
    # Tailscale'in kendi UDP portu: ts-input da kabul eder ama o zincirin
    # varlığına/sırasına bağlı kalmamak için burada da açık (DD-73).
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp \
        --dport "$TAILSCALE_UDP_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p tcp --dport "$SSH_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp --dport "$WG_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p tcp --dport "$QBIT_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp --dport "$QBIT_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" INPUT "$staging" "$CHAIN_INPUT"
}

docker_service_active() {
    systemctl is-active --quiet docker.service 2>/dev/null
}

docker_user_present() {
    local bin="$1"
    "$bin" -w 5 -L DOCKER-USER -n >/dev/null 2>&1
}

wait_for_docker_user() {
    local bin="$1"
    local wait_s=0 deadline
    if docker_user_present "$bin"; then
        return 0
    fi
    if ! docker_service_active; then
        return 1
    fi
    wait_s="${DOCKER_USER_WAIT_SECONDS:-10}"
    deadline=$((SECONDS + wait_s))
    while true; do
        if docker_user_present "$bin"; then
            return 0
        fi
        if [[ "$SECONDS" -ge "$deadline" ]]; then
            die "$bin: DOCKER-USER yok; Docker çalışıyor ama zincir yok (${wait_s}s)"
        fi
        sleep 1
    done
}

apply_docker4() {
    local bin=iptables staging
    if ! wait_for_docker_user "$bin"; then
        printf 'firewall: UYARI: Docker yok/hazır değil; IPv4 MASTER-DOCKER atlandı (docker start → drop-in restart)\n'
        return 0
    fi
    staging="$(create_staging "$bin" "${CHAIN_STAGING_PREFIX}DK-")"
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j RETURN
    # WAN IP adresi gömülmez; arayüz + orijinal hedef port yeterli.
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p tcp \
        -m conntrack --ctstate NEW --ctorigdstport "$QBIT_PUBLIC_PORT" -j RETURN
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
    staging="$(create_staging "$bin" "${CHAIN_STAGING_PREFIX}IN6-")"
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
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp \
        --dport "$TAILSCALE_UDP_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p tcp --dport "$SSH_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" INPUT "$staging" "$CHAIN_INPUT"
}

apply_docker6() {
    # IPv4 ile aynı şekil: yalnız WAN'dan GELEN düşer, köprü çıkışı RETURN ile
    # DOCKER-FORWARD'a devam eder. Koşulsuz DROP wg-easy peer IPv6 çıkışını da
    # keserdi. Public IPv6 publish yok; bu yüzden WAN öncesi ACCEPT de yok.
    local bin=ip6tables staging
    if ! wait_for_docker_user "$bin"; then
        printf 'firewall: UYARI: Docker yok/hazır değil; IPv6 MASTER-DOCKER atlandı (docker start → drop-in restart)\n'
        return 0
    fi
    staging="$(create_staging "$bin" "${CHAIN_STAGING_PREFIX}DK6-")"
    "$bin" -w 5 -A "$staging" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    "$bin" -w 5 -A "$staging" -i "$TAILSCALE_IF" -j RETURN
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" DOCKER-USER "$staging" "$CHAIN_DOCKER"
}

check_jump_exactly_one() {
    local bin="$1" parent="$2" chain="$3" n
    n="$("$bin" -w 5 -L "$parent" -n --line-numbers 2>/dev/null |
        awk -v c="$chain" '$2 == c { n++ } END { print n+0 }')"
    [[ "$n" -eq 1 ]] ||
        die "$bin: $parent -> $chain jump sayısı $n (beklenen 1)"
}

check_rule() {
    local bin="$1"
    shift
    "$bin" -w 5 -C "$@" 2>/dev/null ||
        die "$bin: eksik kural: $*"
}

check_no_staging_artifacts() {
    local bin="$1" hit
    hit="$("$bin" -w 5 -S 2>/dev/null | awk -v p="$CHAIN_STAGING_PREFIX" '
        $1 == "-N" && index($2, p) == 1 { print $2; exit }
        $1 == "-A" {
            for (i = 1; i < NF; i++)
                if ($i == "-j" && index($(i + 1), p) == 1) {
                    print $(i + 1)
                    exit
                }
        }
    ')"
    [[ -z "$hit" ]] || die "$bin: staging artığı: $hit"
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

current_wan_interface() {
    local route
    route="$(ip -4 -o route get 1.1.1.1)" || die "WAN rotası okunamadı"
    awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$route"
}

assert_wan_interface_current() {
    local live
    live="$(current_wan_interface)"
    [[ -n "$live" ]] || die "güncel WAN arayüzü okunamadı"
    [[ "$live" == "$WAN_INTERFACE" ]] ||
        die "WAN arayüzü drift: state=$WAN_INTERFACE live=$live (yeniden kur / state güncelle)"
}

# WAN DROP must sit after every WAN ACCEPT/RETURN in the chain (not merely exist).
# Order is taken from `iptables -S` (stable); -L -v column layout varies.
check_wan_drop_after_allows() {
    local bin="$1" chain="$2" allow_target="$3"
    local drop_pos=0 allow_max=0 n=0 line
    while IFS= read -r line; do
        [[ "$line" == -A* ]] || continue
        n=$((n + 1))
        case "$line" in
            *"-i ${WAN_INTERFACE} "* | *"-i ${WAN_INTERFACE}"$'\t'*)
                ;;
            *)
                continue
                ;;
        esac
        case "$line" in
            *"-j DROP"*)
                drop_pos=$n
                ;;
            *"-j ${allow_target}"*)
                allow_max=$n
                ;;
        esac
    done < <("$bin" -w 5 -S "$chain")
    [[ "$drop_pos" -gt 0 ]] ||
        die "$bin: $chain içinde WAN DROP satırı yok"
    [[ "$drop_pos" -gt "$allow_max" ]] ||
        die "$bin: $chain WAN DROP ($drop_pos) allow ($allow_target max=$allow_max) önünde veya eşit"
}

check_docker_chain() {
    local bin="$1"
    check_jump_exactly_one "$bin" DOCKER-USER "$CHAIN_DOCKER"
    check_rule "$bin" "$CHAIN_DOCKER" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    check_rule "$bin" "$CHAIN_DOCKER" -i "$TAILSCALE_IF" -j RETURN
    if [[ "$bin" == iptables ]]; then
        check_rule "$bin" "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -p tcp \
            -m conntrack --ctstate NEW --ctorigdstport "$QBIT_PUBLIC_PORT" -j RETURN
        check_rule "$bin" "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -p udp \
            -m conntrack --ctstate NEW --ctorigdstport "$QBIT_PUBLIC_PORT" -j RETURN
        check_rule "$bin" "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -p udp \
            -m conntrack --ctstate NEW --ctorigdstport "$WG_PUBLIC_PORT" -j RETURN
    fi
    check_rule "$bin" "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -j DROP
    check_rule "$bin" "$CHAIN_DOCKER" -j RETURN
    check_wan_drop_after_allows "$bin" "$CHAIN_DOCKER" RETURN
}

if [[ "$MODE" == check ]]; then
    assert_wan_interface_current
    check_jump_exactly_one iptables INPUT "$CHAIN_INPUT"
    check_jump_exactly_one ip6tables INPUT "$CHAIN_INPUT"
    check_no_staging_artifacts iptables
    check_no_staging_artifacts ip6tables
    check_ts_input_precedence iptables
    check_ts_input_precedence ip6tables
    check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" -j DROP
    check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p tcp --dport "$SSH_PUBLIC_PORT" -j ACCEPT
    check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p udp --dport "$WG_PUBLIC_PORT" -j ACCEPT
    check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p tcp --dport "$QBIT_PUBLIC_PORT" -j ACCEPT
    check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p udp --dport "$QBIT_PUBLIC_PORT" -j ACCEPT
    check_rule iptables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p udp --dport "$TAILSCALE_UDP_PORT" -j ACCEPT
    check_wan_drop_after_allows iptables "$CHAIN_INPUT" ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" -i "$WAN_INTERFACE" -j DROP
    check_rule ip6tables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p tcp --dport "$SSH_PUBLIC_PORT" -j ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
        -p udp --dport "$TAILSCALE_UDP_PORT" -j ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" \
        -p ipv6-icmp --icmpv6-type neighbour-solicitation -j ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" \
        -p ipv6-icmp --icmpv6-type neighbour-advertisement -j ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" \
        -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
    check_wan_drop_after_allows ip6tables "$CHAIN_INPUT" ACCEPT

    if docker_user_present iptables; then
        check_docker_chain iptables
    elif docker_service_active; then
        die "iptables: Docker aktif ama DOCKER-USER yok"
    else
        printf 'firewall: Docker yok; IPv4 MASTER-DOCKER denetimi atlandı\n'
    fi
    if docker_user_present ip6tables; then
        check_docker_chain ip6tables
    elif docker_service_active; then
        die "ip6tables: Docker aktif ama DOCKER-USER yok"
    else
        printf 'firewall: Docker yok; IPv6 MASTER-DOCKER denetimi atlandı\n'
    fi
    printf 'firewall: kritik politikalar yerinde\n'
    exit 0
fi

assert_wan_interface_current
apply_input4
ensure_ts_input_precedence iptables
apply_input6
ensure_ts_input_precedence ip6tables
apply_docker4
apply_docker6
check_no_staging_artifacts iptables
check_no_staging_artifacts ip6tables
printf 'firewall: politika uygulandı (WAN if=%s)\n' "$WAN_INTERFACE"
