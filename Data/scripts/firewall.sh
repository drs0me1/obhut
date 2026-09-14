#!/usr/bin/env bash
# Host INPUT + DOCKER-USER + WireGuard FORWARD/NAT politikası. Staging zincir,
# atomik swap.
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

# WAN_INTERFACE state'te yalnız ipucu; belirleyici olan canlı default-route
# (resolve_wan_interface). Diğer değerler state'ten zorunlu (DD-66).
: "${TAILSCALE_IF:?}"
: "${CHAIN_INPUT:?}"
: "${CHAIN_DOCKER:?}"
: "${CHAIN_STAGING_PREFIX:?}"
: "${WG_PUBLIC_PORT:?}"
: "${TORRENT_PUBLIC_PORT:?}"
: "${SSH_PUBLIC_PORT:?}"
: "${TAILSCALE_UDP_PORT:?}"
: "${CHAIN_FORWARD:?}"
: "${CHAIN_NAT:?}"
: "${WG_INTERFACE:?}"
: "${WG_SERVER_IPV4:?}"
: "${WG_SUBNET4:?}"
: "${WG_SUBNET6:?}"
: "${DOZZLE_UI_PORT:?}"
: "${TORRENT_UI_PORT:?}"
: "${FILEBROWSER_UI_PORT:?}"

# nat tablosu aynı yardımcılarla yönetilir: "$bin" tek kelime olduğu için tablo
# seçimi bu sarmalayıcılardadır.
iptables_nat() { iptables -t nat "$@"; }
ip6tables_nat() { ip6tables -t nat "$@"; }

# DD-120: WireGuard istemcilerinin host'ta ulaşabildiği tek yer: caddy-wg'nin
# WireGuard adresindeki arayüz portları.
wg_ui_ports() {
    printf '%s,%s,%s\n' "$DOZZLE_UI_PORT" "$TORRENT_UI_PORT" "$FILEBROWSER_UI_PORT"
}

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

# Yarıda kalan bir apply iki tür artık bırakır: hiç bağlanmamış bir staging
# zinciri, ya da activate_named'in -I ile bağlayıp rename'e yetişemediği
# REFERANSLI bir zincir. İkincisini apply başında silmek yürürlükteki tek
# politikayı yok edebilirdi; bu yüzden temizlik apply'ın SONUNDA yapılır —
# o noktada final zincir parent'a bağlıdır ve kalan her staging artığı ölüdür.
# Referanslıyı atlamak politikayı korurdu ama check_no_staging_artifacts'i
# kalıcı fail bırakır, unit failed kalır ve watchdog sonuçsuz döner (DD-95).
purge_staging_leftovers() {
    local bin="$1" chain parent rules
    rules="$("$bin" -w 5 -S 2>/dev/null)" || return 0
    while read -r chain; do
        [[ -n "$chain" ]] || continue
        while read -r parent; do
            [[ -n "$parent" ]] || continue
            while "$bin" -w 5 -C "$parent" -j "$chain" 2>/dev/null; do
                "$bin" -w 5 -D "$parent" -j "$chain"
            done
        done < <(awk -v c="$chain" \
            '$1 == "-A" && $NF == c && $(NF - 1) == "-j" { print $2 }' <<<"$rules")
        "$bin" -w 5 -F "$chain" 2>/dev/null || true
        "$bin" -w 5 -X "$chain" 2>/dev/null || true
        printf 'firewall: staging artığı silindi (%s %s)\n' "$bin" "$chain"
    done < <(awk -v p="$CHAIN_STAGING_PREFIX" \
        '$1 == "-N" && index($2, p) == 1 { print $2 }' <<<"$rules")
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
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p tcp --dport "$TORRENT_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp --dport "$TORRENT_PUBLIC_PORT" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -j DROP
    # DD-120: WireGuard istemcisi host'ta yalnız arayüz portlarına ve ping'e
    # ulaşır; SSH, DNS ve TS IP (dolayısıyla WebDAV) kapalı.
    "$bin" -w 5 -A "$staging" -i "$WG_INTERFACE" -d "$WG_SERVER_IPV4" -p tcp \
        -m multiport --dports "$(wg_ui_ports)" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WG_INTERFACE" -d "$WG_SERVER_IPV4" -p icmp \
        --icmp-type echo-request -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WG_INTERFACE" -j DROP
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
        -m conntrack --ctstate NEW --ctorigdstport "$TORRENT_PUBLIC_PORT" -j RETURN
    "$bin" -w 5 -A "$staging" -i "$WAN_INTERFACE" -p udp \
        -m conntrack --ctstate NEW --ctorigdstport "$TORRENT_PUBLIC_PORT" -j RETURN
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
    # DD-120: arayüzlere WireGuard erişimi yalnız IPv4 adresinden.
    "$bin" -w 5 -A "$staging" -i "$WG_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" INPUT "$staging" "$CHAIN_INPUT"
}

# DD-120: WireGuard istemcileri yalnız internete çıkar ve dönüşünü alır;
# tailnet, Docker ağları ve istemciler arası trafik kapalı. Zincir FORWARD'ın
# başına bağlanır; Docker ya da tailscaled yeniden başlayınca drop-in ve PartOf
# politikayı yeniden uygular. Arada altta kalsa bile ts-forward tailnet'e yeni
# bağlantıyı zaten düşürür.
apply_forward() {
    local bin="$1" prefix="$2" staging
    staging="$(create_staging "$bin" "$prefix")"
    "$bin" -w 5 -A "$staging" -i "$WG_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
    "$bin" -w 5 -A "$staging" -i "$WG_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -o "$WG_INTERFACE" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$bin" -w 5 -A "$staging" -o "$WG_INTERFACE" -j DROP
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" FORWARD "$staging" "$CHAIN_FORWARD"
}

# DD-120: WireGuard alt ağı WAN'a çıkarken maskelenir (wg-quick PostUp'ı yok;
# kural sahibi bu betik, DD-16/DD-17).
apply_nat() {
    local bin="$1" prefix="$2" subnet="$3" staging
    staging="$(create_staging "$bin" "$prefix")"
    "$bin" -w 5 -A "$staging" -s "$subnet" -o "$WAN_INTERFACE" -j MASQUERADE
    "$bin" -w 5 -A "$staging" -j RETURN
    activate_named "$bin" POSTROUTING "$staging" "$CHAIN_NAT"
}

apply_docker6() {
    # IPv4 ile aynı şekil: yalnız WAN'dan GELEN düşer, köprü çıkışı RETURN ile
    # DOCKER-FORWARD'a devam eder. Koşulsuz DROP köprü IPv6 çıkışını da keserdi
    # (DD-71). Public IPv6 publish yok; bu yüzden WAN öncesi ACCEPT de yok.
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

# NIC yeniden adlandırılırsa state ipucu bayatlar. Eskiden bu ölümcüldü ve host
# hiç INPUT politikası almıyordu; artık canlı arayüz belirleyici (DD-94).
# state.env yazılmaz: WAN_INTERFACE'i çalışma zamanında yalnız bu betik tüketir.
resolve_wan_interface() {
    local live
    live="$(current_wan_interface)"
    [[ -n "$live" ]] || die "güncel WAN arayüzü okunamadı"
    if [[ -n "${WAN_INTERFACE:-}" && "$live" != "$WAN_INTERFACE" ]]; then
        printf 'firewall: UYARI WAN arayüzü drift: state=%s live=%s (canlı kullanılıyor)\n' \
            "$WAN_INTERFACE" "$live" >&2
    fi
    WAN_INTERFACE="$live"
}

# Zincir şekli: tek WAN DROP, WAN izinlerinden sonra ve öncesinde koşulsuz
# (arayüz/port/proto/conntrack kısıtı olmayan) ACCEPT/RETURN bulunmamalı.
# Sıra `iptables -S` üzerinden okunur; -L -v sütun düzeni sürüme göre değişir.
check_chain_shape() {
    local bin="$1" chain="$2" allow_target="$3"
    local drop_pos=0 drop_count=0 allow_max=0 bypass="" n=0 line body
    while IFS= read -r line; do
        [[ "$line" == "-A $chain "* ]] || continue
        n=$((n + 1))
        body="${line#-A "$chain" }"
        # Koşulsuz kural: yalnız -j <target>, hiçbir match seçeneği yok.
        if [[ "$body" == "-j ACCEPT" || "$body" == "-j RETURN" ]]; then
            [[ -n "$bypass" ]] || bypass="$n:$body"
        fi
        case "$line" in
            *"-i ${WAN_INTERFACE} "*)
                case "$line" in
                    *"-j DROP") drop_pos=$n; drop_count=$((drop_count + 1)) ;;
                    *"-j ${allow_target}") allow_max=$n ;;
                esac
                ;;
        esac
    done < <("$bin" -w 5 -S "$chain")
    [[ "$drop_pos" -gt 0 ]] ||
        die "$bin: $chain içinde WAN DROP satırı yok"
    [[ "$drop_count" -eq 1 ]] ||
        die "$bin: $chain WAN DROP sayısı $drop_count (beklenen 1)"
    [[ "$drop_pos" -gt "$allow_max" ]] ||
        die "$bin: $chain WAN DROP ($drop_pos) allow ($allow_target max=$allow_max) önünde veya eşit"
    if [[ -n "$bypass" ]]; then
        local pos="${bypass%%:*}" rule="${bypass#*:}"
        [[ "$pos" -gt "$drop_pos" ]] ||
            die "$bin: $chain WAN DROP öncesi koşulsuz kural ($pos: $rule) — bypass"
    fi
}

# WAN'dan izinli (proto, port) çiftleri — tek liste. check_rule çağrıları da
# beklenen sayı da buradan üretilir; ikinci bir yerde tekrarlanmaz.
wan_allow_pairs() {
    printf '%s\n' "udp $TAILSCALE_UDP_PORT" "tcp $SSH_PUBLIC_PORT"
    [[ "$1" == v4 ]] || return 0
    printf '%s\n' "udp $WG_PUBLIC_PORT" "tcp $TORRENT_PUBLIC_PORT" \
        "udp $TORRENT_PUBLIC_PORT"
}

# MASTER-DOCKER'da WAN'dan RETURN alan publish'ler (IPv6 publish yok).
# WireGuard Docker'da değil (DD-120): portu yalnız INPUT'ta.
docker_return_pairs() {
    [[ "$1" == v4 ]] || return 0
    printf '%s\n' "tcp $TORRENT_PUBLIC_PORT" "udp $TORRENT_PUBLIC_PORT"
}

# Tek tek desen kontrolü "eksik kural" bulur, "fazladan kural" bulamaz:
# '-i WAN -j ACCEPT' gibi port nitelemesi olmayan bir geçiş, beklenen
# kuralların hepsi yerinde olduğu için denetimden sağ çıkardı. Sayı birebir
# tutmak zorunda: her fazladan WAN geçişi — blanket ya da portlu — düşer.
check_wan_allow_count() {
    local bin="$1" chain="$2" target="$3" expected="$4" actual
    actual="$("$bin" -w 5 -S "$chain" 2>/dev/null |
        grep -cE -- "^-A $chain .*-i $WAN_INTERFACE .*-j $target\$" || true)"
    [[ "$actual" -eq "$expected" ]] ||
        die "$bin: $chain WAN $target sayısı $actual (beklenen $expected) — fazladan geçiş"
}

check_input_chain() {
    local bin="$1" family="$2" n=0 proto port
    check_jump_exactly_one "$bin" INPUT "$CHAIN_INPUT"
    check_no_staging_artifacts "$bin"
    check_ts_input_precedence "$bin"
    check_rule "$bin" "$CHAIN_INPUT" -i "$WAN_INTERFACE" -j DROP
    while read -r proto port; do
        [[ -n "$proto" ]] || continue
        check_rule "$bin" "$CHAIN_INPUT" -i "$WAN_INTERFACE" \
            -p "$proto" --dport "$port" -j ACCEPT
        n=$((n + 1))
    done < <(wan_allow_pairs "$family")
    check_wan_allow_count "$bin" "$CHAIN_INPUT" ACCEPT "$n"
    check_chain_shape "$bin" "$CHAIN_INPUT" ACCEPT
    check_rule "$bin" "$CHAIN_INPUT" -i "$WG_INTERFACE" -j DROP
    if [[ "$family" == v4 ]]; then
        check_rule "$bin" "$CHAIN_INPUT" -i "$WG_INTERFACE" -d "$WG_SERVER_IPV4" \
            -p tcp -m multiport --dports "$(wg_ui_ports)" -j ACCEPT
        check_rule "$bin" "$CHAIN_INPUT" -i "$WG_INTERFACE" -d "$WG_SERVER_IPV4" \
            -p icmp --icmp-type echo-request -j ACCEPT
        # `-S` önce -d, sonra -i yazar (ölçüldü, iptables 1.8 nft).
        check_before "$bin" "$CHAIN_INPUT" "-i $WG_INTERFACE -j DROP" \
            "-d $WG_SERVER_IPV4/32 -i $WG_INTERFACE "
    fi
}

# check_before BIN CHAIN SON_KURAL ÖNCEKİ_DESEN — ÖNCEKİ_DESEN'le başlayan her
# kural (-A CHAIN sonrası) SON_KURAL'dan önce gelmeli. -C sırayı görmez.
check_before() {
    local bin="$1" chain="$2" last="$3" earlier="$4" n=0 last_pos=0 max_earlier=0 line body
    while IFS= read -r line; do
        [[ "$line" == "-A $chain "* ]] || continue
        n=$((n + 1))
        body="${line#-A "$chain" }"
        [[ "$body" == "$last" ]] && last_pos=$n
        [[ "$body" == "$earlier"* ]] && max_earlier=$n
    done < <("$bin" -w 5 -S "$chain")
    [[ "$last_pos" -gt 0 ]] || die "$bin: $chain içinde '$last' yok"
    [[ "$last_pos" -gt "$max_earlier" ]] ||
        die "$bin: $chain sırası hatalı: '$earlier…' ($max_earlier) '$last' ($last_pos) önünde değil"
}

check_forward_chain() {
    local bin="$1" count
    check_jump_exactly_one "$bin" FORWARD "$CHAIN_FORWARD"
    check_rule "$bin" "$CHAIN_FORWARD" -i "$WG_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
    check_rule "$bin" "$CHAIN_FORWARD" -i "$WG_INTERFACE" -j DROP
    check_rule "$bin" "$CHAIN_FORWARD" -o "$WG_INTERFACE" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    check_rule "$bin" "$CHAIN_FORWARD" -o "$WG_INTERFACE" -j DROP
    check_before "$bin" "$CHAIN_FORWARD" "-i $WG_INTERFACE -j DROP" \
        "-i $WG_INTERFACE -o $WAN_INTERFACE "
    check_before "$bin" "$CHAIN_FORWARD" "-o $WG_INTERFACE -j DROP" \
        "-o $WG_INTERFACE -m conntrack --ctstate RELATED,ESTABLISHED "
    # Fazladan kural (ör. -i wg0 -j ACCEPT) -C ile görünmez; sayı birebir tutmalı.
    count="$("$bin" -w 5 -S "$CHAIN_FORWARD" | grep -c "^-A $CHAIN_FORWARD " || true)"
    [[ "$count" -eq 5 ]] || die "$bin: $CHAIN_FORWARD kural sayısı $count (beklenen 5)"
}

check_nat_chain() {
    local bin="$1" subnet="$2"
    check_jump_exactly_one "$bin" POSTROUTING "$CHAIN_NAT"
    check_rule "$bin" "$CHAIN_NAT" -s "$subnet" -o "$WAN_INTERFACE" -j MASQUERADE
    check_no_staging_artifacts "$bin"
}

check_docker_chain() {
    local bin="$1" family="$2" n=0 proto port
    check_jump_exactly_one "$bin" DOCKER-USER "$CHAIN_DOCKER"
    check_rule "$bin" "$CHAIN_DOCKER" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    check_rule "$bin" "$CHAIN_DOCKER" -i "$TAILSCALE_IF" -j RETURN
    while read -r proto port; do
        [[ -n "$proto" ]] || continue
        check_rule "$bin" "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -p "$proto" \
            -m conntrack --ctstate NEW --ctorigdstport "$port" -j RETURN
        n=$((n + 1))
    done < <(docker_return_pairs "$family")
    check_rule "$bin" "$CHAIN_DOCKER" -i "$WAN_INTERFACE" -j DROP
    check_rule "$bin" "$CHAIN_DOCKER" -j RETURN
    check_wan_allow_count "$bin" "$CHAIN_DOCKER" RETURN "$n"
    check_chain_shape "$bin" "$CHAIN_DOCKER" RETURN
}

if [[ "$MODE" == check ]]; then
    resolve_wan_interface
    check_input_chain iptables v4
    check_input_chain ip6tables v6
    check_rule ip6tables "$CHAIN_INPUT" \
        -p ipv6-icmp --icmpv6-type neighbour-solicitation -j ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" \
        -p ipv6-icmp --icmpv6-type neighbour-advertisement -j ACCEPT
    check_rule ip6tables "$CHAIN_INPUT" \
        -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT

    if docker_user_present iptables; then
        check_docker_chain iptables v4
    elif docker_service_active; then
        die "iptables: Docker aktif ama DOCKER-USER yok"
    else
        printf 'firewall: Docker yok; IPv4 MASTER-DOCKER denetimi atlandı\n'
    fi
    if docker_user_present ip6tables; then
        check_docker_chain ip6tables v6
    elif docker_service_active; then
        die "ip6tables: Docker aktif ama DOCKER-USER yok"
    else
        printf 'firewall: Docker yok; IPv6 MASTER-DOCKER denetimi atlandı\n'
    fi
    check_forward_chain iptables
    check_forward_chain ip6tables
    check_nat_chain iptables_nat "$WG_SUBNET4"
    check_nat_chain ip6tables_nat "$WG_SUBNET6"
    printf 'firewall: kritik politikalar yerinde\n'
    exit 0
fi

resolve_wan_interface
apply_input4
ensure_ts_input_precedence iptables
apply_input6
ensure_ts_input_precedence ip6tables
apply_forward iptables "${CHAIN_STAGING_PREFIX}FW-"
apply_forward ip6tables "${CHAIN_STAGING_PREFIX}FW6-"
apply_nat iptables_nat "${CHAIN_STAGING_PREFIX}NAT-" "$WG_SUBNET4"
apply_nat ip6tables_nat "${CHAIN_STAGING_PREFIX}NAT6-" "$WG_SUBNET6"
apply_docker4
apply_docker6
purge_staging_leftovers iptables
purge_staging_leftovers ip6tables
purge_staging_leftovers iptables_nat
purge_staging_leftovers ip6tables_nat
check_no_staging_artifacts iptables
check_no_staging_artifacts ip6tables
check_no_staging_artifacts iptables_nat
check_no_staging_artifacts ip6tables_nat
printf 'firewall: politika uygulandı (WAN if=%s)\n' "$WAN_INTERFACE"
