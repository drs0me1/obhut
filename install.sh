#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MASTER_SETUP_VERSION="2026.08.04-Q1-32"
MASTER_SETUP_SHA256="$(
    sha256sum -- "${BASH_SOURCE[0]}" 2>/dev/null | awk '{print $1}' || true
)"
[[ "$MASTER_SETUP_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    MASTER_SETUP_SHA256="bilinmiyor"
MASTER_LOCK_FILE="/run/lock/master-stack.lock"
MASTER_LOCK_WAIT_SECONDS=5
APT_LOCK_TIMEOUT=300

MASTER_LOG_DIR="/var/log/master-setup"
MASTER_LOG_FILE=""
MASTER_LOGGING_ACTIVE=0
MASTER_CONSOLE_STREAM_FDS_OPEN=0
MASTER_PROGRESS_TTY_FD_OPEN=0
MASTER_PROGRESS_ACTIVE=0
MASTER_PROGRESS_ANSI=0
MASTER_CURRENT_STAGE=0
MASTER_CURRENT_STAGE_LABEL=""
MASTER_CURRENT_PERCENT=0
MASTER_STAGE_LOG_START_LINE=0
MASTER_ERROR_LINE=""
MASTER_SIGNAL=""
MASTER_SERVICE_JOURNAL_APPENDED=0

TIMER_WINDOW_PREPARED=0
RECONCILE_TIMER_WAS_ACTIVE=0
RECONCILE_TIMER_WAS_ENABLED=0
APT_DAILY_TIMER_WAS_ACTIVE=0
APT_DAILY_UPGRADE_TIMER_WAS_ACTIVE=0
RECONCILE_TIMER_REENABLED=0
APT_DAILY_TIMER_REENABLED=0
APT_DAILY_UPGRADE_TIMER_REENABLED=0
DNS_STACK_STATE_CAPTURED=0
DNSMASQ_WAS_ACTIVE=0
DNSMASQ_INITIAL_LOAD_STATE="not-found"
DNSMASQ_INITIAL_UNIT_FILE_STATE="not-found"
CADDY_WAS_ACTIVE=0
CADDY_INITIAL_LOAD_STATE="not-found"
CADDY_INITIAL_UNIT_FILE_STATE="not-found"
DNS_STACK_ROLLBACK_BASE="/run"
DNS_STACK_ROLLBACK_DIR=""
DNS_STACK_MANAGED_FILES=(
    /etc/dnsmasq.d/local-services.conf
    /etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf
    /etc/caddy/Caddyfile
    /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf
    /usr/local/sbin/caddy-tailnet-env
    /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf
)
CANONICAL_STAGE_DIR=""
CANONICAL_LINK_TMP=""

progress_render() {
    local percent="$1" label="$2" state="${3:-RUN}" suffix="${4:-}"
    local width=16 filled=0 index=0 bar="" color="" reset=""

    [[ -n "$MASTER_LOG_FILE" &&
       "$MASTER_PROGRESS_TTY_FD_OPEN" -eq 1 ]] || return 0
    (( percent < 0 )) && percent=0
    (( percent > 100 )) && percent=100
    filled=$((percent * width / 100))

    for ((index = 0; index < width; index++)); do
        if [[ "$state" == "OK" ]]; then
            bar+="#"
        elif (( index < filled )); then
            bar+="#"
        elif (( index == filled && filled < width )); then
            if [[ "$state" == "FAIL" ]]; then
                bar+="!"
            else
                bar+=">"
            fi
        else
            bar+="-"
        fi
    done

    if [[ "$MASTER_PROGRESS_ANSI" -eq 1 ]]; then
        case "$state" in
            OK) color=$'\033[32m' ;;
            FAIL) color=$'\033[31m' ;;
            *) color=$'\033[36m' ;;
        esac
        reset=$'\033[0m'
        printf '\r\033[2K%s[%d/7] [%s] %3d%% · %s%s%s' \
            "$color" "$MASTER_CURRENT_STAGE" "$bar" "$percent" \
            "$label" "$suffix" "$reset" >&5 || true
    else
        printf '[%d/7] [%s] %3d%% · %s%s\n' \
            "$MASTER_CURRENT_STAGE" "$bar" "$percent" "$label" "$suffix" \
            >&5 || true
    fi
}

progress_clear_line() {
    [[ -n "$MASTER_LOG_FILE" &&
       "$MASTER_PROGRESS_TTY_FD_OPEN" -eq 1 ]] || return 0
    if [[ "$MASTER_PROGRESS_ANSI" -eq 1 ]]; then
        printf '\r\033[2K' >&5 || true
    else
        printf '\n' >&5 || true
    fi
}

progress_setup_logging() {
    local timestamp=""

    install -d -m 0700 -o root -g root "$MASTER_LOG_DIR"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    MASTER_LOG_FILE="${MASTER_LOG_DIR}/master-setup-${timestamp}-$$.log"
    install -m 0600 -o root -g root /dev/null "$MASTER_LOG_FILE"

    exec 3>&1 4>&2 5>/dev/tty
    MASTER_CONSOLE_STREAM_FDS_OPEN=1
    MASTER_PROGRESS_TTY_FD_OPEN=1
    if [[ -t 5 && "${TERM:-dumb}" != "dumb" ]]; then
        MASTER_PROGRESS_ANSI=1
    fi

    {
        printf 'Master Setup %s\n' "$MASTER_SETUP_VERSION"
        printf 'Başlangıç: %s\n' "$MASTER_SETUP_STARTED_AT"
        printf 'Log: %s\n\n' "$MASTER_LOG_FILE"
    } >>"$MASTER_LOG_FILE"

    printf '\nAyrıntılı kurulum logu: %s\n\n' "$MASTER_LOG_FILE" >&5 ||
        true
    exec >>"$MASTER_LOG_FILE" 2>&1
    MASTER_LOGGING_ACTIVE=1
}

progress_stage_begin() {
    local stage="$1" label="$2"

    MASTER_CURRENT_STAGE="$stage"
    MASTER_CURRENT_STAGE_LABEL="$label"
    MASTER_CURRENT_PERCENT=0
    MASTER_PROGRESS_ACTIVE=1
    MASTER_STAGE_LOG_START_LINE="$(wc -l <"$MASTER_LOG_FILE" 2>/dev/null || echo 0)"
    printf '\n[%s] AŞAMA %s/7 BAŞLADI: %s\n' \
        "$(date --iso-8601=seconds)" "$stage" "$label" >>"$MASTER_LOG_FILE"
    progress_render 0 "$label"
}

progress_stage_note() {
    local percent="$1" label="$2"

    [[ "$MASTER_PROGRESS_ACTIVE" -eq 1 ]] || return 0
    (( percent < MASTER_CURRENT_PERCENT )) && percent="$MASTER_CURRENT_PERCENT"
    (( percent > 99 )) && percent=99
    MASTER_CURRENT_PERCENT="$percent"
    MASTER_CURRENT_STAGE_LABEL="$label"
    printf '[%s] Aşama %s: %s%% - %s\n' \
        "$(date --iso-8601=seconds)" "$MASTER_CURRENT_STAGE" \
        "$percent" "$label" >>"$MASTER_LOG_FILE"
    progress_render "$percent" "$label"
}

progress_stage_resume() {
    [[ "$MASTER_PROGRESS_ACTIVE" -eq 1 ]] || return 0
    progress_render "$MASTER_CURRENT_PERCENT" "$MASTER_CURRENT_STAGE_LABEL"
}

progress_stage_done() {
    local warnings=0 suffix=" · tamamlandı"

    [[ "$MASTER_PROGRESS_ACTIVE" -eq 1 ]] || return 0
    warnings="$(
        tail -n "+$((MASTER_STAGE_LOG_START_LINE + 1))" "$MASTER_LOG_FILE" |
            grep -c 'UYARI:' || true
    )"
    if [[ "$warnings" =~ ^[0-9]+$ && "$warnings" -gt 0 ]]; then
        suffix+=" · ${warnings} uyarı loglandı"
    fi

    MASTER_CURRENT_PERCENT=100
    progress_render 100 "$MASTER_CURRENT_STAGE_LABEL" OK "$suffix"
    if [[ "$MASTER_PROGRESS_ANSI" -eq 1 ]]; then
        printf '\n' >&5 || true
    fi
    printf '[%s] AŞAMA %s/7 TAMAMLANDI%s\n' \
        "$(date --iso-8601=seconds)" "$MASTER_CURRENT_STAGE" "$suffix" \
        >>"$MASTER_LOG_FILE"
    MASTER_PROGRESS_ACTIVE=0
}

progress_restore_output() {
    if [[ "$MASTER_LOGGING_ACTIVE" -eq 1 ]]; then
        exec 1>&3 2>&4
        MASTER_LOGGING_ACTIVE=0
    fi
    if [[ "$MASTER_CONSOLE_STREAM_FDS_OPEN" -eq 1 ]]; then
        exec 3>&- 4>&-
        MASTER_CONSOLE_STREAM_FDS_OPEN=0
    fi
}

progress_close_tty() {
    if [[ "$MASTER_PROGRESS_TTY_FD_OPEN" -eq 1 ]]; then
        exec 5>&-
        MASTER_PROGRESS_TTY_FD_OPEN=0
    fi
}

NET_RETRY_ATTEMPTS=3
NET_RETRY_BULK_FIRST=300
NET_RETRY_BULK_NEXT=180
NET_RETRY_SMALL_FIRST=60
NET_RETRY_SMALL_NEXT=30

retry_network() {
    local label="$1" first_timeout="$2" retry_timeout="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift

    local attempt=1 rc=0 limit="$first_timeout" backoff=5
    while :; do
        rc=0
        timeout --signal=TERM --kill-after=30s "$limit" "$@" || rc=$?
        [[ "$rc" -eq 0 ]] && return 0

        if [[ "$attempt" -ge "$NET_RETRY_ATTEMPTS" ]]; then
            if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
                echo "HATA: ${label}: son deneme ${limit} saniyede tamamlanmadı (zaman aşımı)." >&2
            else
                echo "HATA: ${label}: ${NET_RETRY_ATTEMPTS} denemenin tamamı başarısız (son çıkış kodu ${rc})." >&2
            fi
            return "$rc"
        fi

        echo "UYARI: ${label}: ${attempt}. deneme başarısız (çıkış kodu ${rc}); ${backoff}s sonra yeniden denenecek." >&2
        progress_stage_note "$MASTER_CURRENT_PERCENT" \
            "${MASTER_CURRENT_STAGE_LABEL} (yeniden deneniyor: $((attempt + 1))/${NET_RETRY_ATTEMPTS})"
        sleep "$backoff"

        attempt=$((attempt + 1))
        limit="$retry_timeout"
        backoff=15
    done
}

append_master_service_journal() {
    [[ "$MASTER_LOGGING_ACTIVE" -eq 1 ]] || return 0
    [[ "$MASTER_SERVICE_JOURNAL_APPENDED" -eq 0 ]] || return 0
    MASTER_SERVICE_JOURNAL_APPENDED=1

    {
        echo
        echo "--- Kurulum sırasında yönetilen servislerin journald kayıtları ---"
        journalctl --since "${MASTER_SETUP_STARTED_AT:-today}" \
            --no-pager -o short-iso \
            -u tailscale-udp-gro.service \
            -u docker-tailscale-fw.service \
            -u master-compose.service \
            -u master-docker-netfilter-recovery.service \
            -u master-network-reconcile.service \
            -u caddy.service \
            -u dnsmasq.service 2>&1 || true
    } >>"$MASTER_LOG_FILE"
}

restore_one_timer() {
    local unit="$1" was_active="$2" restored="$3"
    [[ "$restored" -eq 0 ]] || return 0
    if [[ "$was_active" -eq 1 ]]; then
        if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
            echo "Önceki aktif timer geri başlatılıyor: $unit" >&2
            systemctl start "$unit"
        fi
    elif systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "Kurulum sırasında açılan timer önceki inactive durumuna döndürülüyor: $unit" >&2
        systemctl stop "$unit"
    fi
}

restore_stopped_timers_on_exit() {
    local exit_rc="${1:-0}" restore_rc=0
    [[ "${TIMER_WINDOW_PREPARED:-0}" -eq 1 ]] || return 0

    restore_one_timer apt-daily.timer \
        "${APT_DAILY_TIMER_WAS_ACTIVE:-0}" \
        "${APT_DAILY_TIMER_REENABLED:-0}" || restore_rc=1
    restore_one_timer apt-daily-upgrade.timer \
        "${APT_DAILY_UPGRADE_TIMER_WAS_ACTIVE:-0}" \
        "${APT_DAILY_UPGRADE_TIMER_REENABLED:-0}" || restore_rc=1
    if [[ "$exit_rc" -ne 0 ]]; then
        if [[ "${RECONCILE_TIMER_WAS_ACTIVE:-0}" -eq 1 ]]; then
            systemctl start master-network-reconcile.timer || restore_rc=1
        else
            systemctl stop master-network-reconcile.timer \
                >/dev/null 2>&1 || restore_rc=1
        fi
        if [[ "${RECONCILE_TIMER_WAS_ENABLED:-0}" -eq 1 ]]; then
            systemctl enable master-network-reconcile.timer \
                >/dev/null 2>&1 || restore_rc=1
        else
            systemctl disable master-network-reconcile.timer \
                >/dev/null 2>&1 || restore_rc=1
        fi
    else
        restore_one_timer master-network-reconcile.timer \
            "${RECONCILE_TIMER_WAS_ACTIVE:-0}" \
            "${RECONCILE_TIMER_REENABLED:-0}" || restore_rc=1
    fi
    TIMER_WINDOW_PREPARED=0
    return "$restore_rc"
}

dns_stack_managed_path_ok() {
    local path="$1"
    [[ "$path" == /* && "$path" != "/" ]]
}

dns_stack_rollback_dir_ok() {
    local path="$1"
    [[ -n "$path" &&
       "$path" == "$DNS_STACK_ROLLBACK_BASE"/master-dns-stack-rollback.* ]]
}

capture_dns_stack_files() {
    local managed_path="" backup_path=""

    DNS_STACK_ROLLBACK_DIR="$(
        mktemp -d \
            "$DNS_STACK_ROLLBACK_BASE/master-dns-stack-rollback.XXXXXX"
    )"
    chmod 0700 "$DNS_STACK_ROLLBACK_DIR"

    for managed_path in "${DNS_STACK_MANAGED_FILES[@]}"; do
        if ! dns_stack_managed_path_ok "$managed_path"; then
            rm -rf -- "$DNS_STACK_ROLLBACK_DIR"
            DNS_STACK_ROLLBACK_DIR=""
            return 1
        fi
        backup_path="$DNS_STACK_ROLLBACK_DIR/files$managed_path"
        if ! install -d -m 0700 "$(dirname "$backup_path")"; then
            rm -rf -- "$DNS_STACK_ROLLBACK_DIR"
            DNS_STACK_ROLLBACK_DIR=""
            return 1
        fi
        if [[ -e "$managed_path" || -L "$managed_path" ]]; then
            if ! cp -a -- "$managed_path" "$backup_path"; then
                rm -rf -- "$DNS_STACK_ROLLBACK_DIR"
                DNS_STACK_ROLLBACK_DIR=""
                return 1
            fi
        fi
    done
}

restore_dns_stack_files() {
    local managed_path="" backup_path="" restore_rc=0

    dns_stack_rollback_dir_ok "$DNS_STACK_ROLLBACK_DIR" &&
        [[ -d "$DNS_STACK_ROLLBACK_DIR" ]] || return 1

    for managed_path in "${DNS_STACK_MANAGED_FILES[@]}"; do
        if ! dns_stack_managed_path_ok "$managed_path"; then
            restore_rc=1
            continue
        fi
        backup_path="$DNS_STACK_ROLLBACK_DIR/files$managed_path"
        if [[ -e "$backup_path" || -L "$backup_path" ]]; then
            rm -rf -- "$managed_path" || restore_rc=1
            install -d -m 0755 "$(dirname "$managed_path")" || {
                restore_rc=1
                continue
            }
            cp -a -- "$backup_path" "$managed_path" || restore_rc=1
        else
            rm -rf -- "$managed_path" || restore_rc=1
        fi
    done

    if [[ "$restore_rc" -eq 0 ]]; then
        rm -rf -- "$DNS_STACK_ROLLBACK_DIR" || restore_rc=1
        [[ "$restore_rc" -ne 0 ]] || DNS_STACK_ROLLBACK_DIR=""
    fi
    return "$restore_rc"
}

canonical_stage_is_current() {
    local canonical_root="${CANONICAL_ROOT:-/usr/local/share/master-stack}"
    local active_target="" stage_target=""
    [[ -n "${CANONICAL_STAGE_DIR:-}" ]] || return 1
    active_target="$(
        readlink -f -- "$canonical_root/current" 2>/dev/null || true
    )"
    stage_target="$(
        readlink -f -- "$CANONICAL_STAGE_DIR" 2>/dev/null || true
    )"
    [[ -n "$stage_target" && "$active_target" == "$stage_target" ]]
}

restore_dns_stack_on_failure() {
    local exit_rc="${1:-0}" restore_rc=0 daemon="" was_active=0
    local load_state="" unit_file_state="" current_load_state=""
    [[ "$exit_rc" -ne 0 &&
       "${DNS_STACK_STATE_CAPTURED:-0}" -eq 1 ]] || return 0

    if canonical_stage_is_current; then
        if dns_stack_rollback_dir_ok "$DNS_STACK_ROLLBACK_DIR"; then
            rm -rf -- "$DNS_STACK_ROLLBACK_DIR" || restore_rc=1
        fi
        DNS_STACK_ROLLBACK_DIR=""
        DNS_STACK_STATE_CAPTURED=0
        return "$restore_rc"
    fi

    for daemon in dnsmasq caddy; do
        current_load_state="$(
            systemctl show "$daemon.service" -p LoadState --value \
                2>/dev/null || true
        )"
        if [[ "$current_load_state" != "not-found" ]]; then
            systemctl stop "$daemon.service" \
                >/dev/null 2>&1 || restore_rc=1
        fi
    done
    if ! restore_dns_stack_files; then
        echo "HATA: DNS/Caddy dosya rollback'i tamamlanamadı; kurtarma" >&2
        echo "kopyası korundu: $DNS_STACK_ROLLBACK_DIR" >&2
        restore_rc=1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || restore_rc=1

    for daemon in dnsmasq caddy; do
        case "$daemon" in
            dnsmasq)
                was_active="${DNSMASQ_WAS_ACTIVE:-0}"
                load_state="${DNSMASQ_INITIAL_LOAD_STATE:-not-found}"
                unit_file_state="${DNSMASQ_INITIAL_UNIT_FILE_STATE:-not-found}"
                ;;
            caddy)
                was_active="${CADDY_WAS_ACTIVE:-0}"
                load_state="${CADDY_INITIAL_LOAD_STATE:-not-found}"
                unit_file_state="${CADDY_INITIAL_UNIT_FILE_STATE:-not-found}"
                ;;
        esac

        if [[ "$load_state" == "not-found" ]]; then
            systemctl disable --now "$daemon.service" \
                >/dev/null 2>&1 || true
            systemctl mask "$daemon.service" >/dev/null 2>&1 || restore_rc=1
            continue
        fi

        if [[ "$unit_file_state" == "masked" ||
              "$unit_file_state" == "masked-runtime" ]]; then
            systemctl mask "$daemon.service" >/dev/null 2>&1 || restore_rc=1
        else
            systemctl unmask "$daemon.service" >/dev/null 2>&1 || restore_rc=1
            case "$unit_file_state" in
                enabled|enabled-runtime|linked|linked-runtime|alias)
                    systemctl enable "$daemon.service" \
                        >/dev/null 2>&1 || restore_rc=1
                    ;;
                *)
                    systemctl disable "$daemon.service" \
                        >/dev/null 2>&1 || restore_rc=1
                    ;;
            esac
        fi
        if [[ "$was_active" -eq 1 ]]; then
            systemctl reset-failed "$daemon.service" >/dev/null 2>&1 || true
            systemctl restart "$daemon.service" \
                >/dev/null 2>&1 || restore_rc=1
        else
            systemctl stop "$daemon.service" >/dev/null 2>&1 || true
        fi
    done
    DNS_STACK_STATE_CAPTURED=0
    return "$restore_rc"
}

cleanup_master_setup() {
    local rc=$? restore_rc=0 dns_restore_rc=0 error_tail=""
    trap - ERR EXIT INT TERM
    set +e

    restore_dns_stack_on_failure "$rc" || dns_restore_rc=$?
    if [[ "$dns_restore_rc" -ne 0 && "$rc" -eq 0 ]]; then
        rc="$dns_restore_rc"
    fi

    restore_stopped_timers_on_exit "$rc" || restore_rc=$?
    if [[ "$restore_rc" -ne 0 && "$rc" -eq 0 ]]; then
        rc="$restore_rc"
    fi

    if [[ -n "$CANONICAL_LINK_TMP" ]]; then
        case "$CANONICAL_LINK_TMP" in
            /usr/local/share/master-stack/.generation.*.link)
                rm -f -- "$CANONICAL_LINK_TMP"
                ;;
        esac
    fi
    if [[ -n "$CANONICAL_STAGE_DIR" ]] && ! canonical_stage_is_current; then
        case "$CANONICAL_STAGE_DIR" in
            /usr/local/share/master-stack/.generation.*)
                rm -rf -- "$CANONICAL_STAGE_DIR"
                ;;
        esac
    fi

    if [[ "$MASTER_LOGGING_ACTIVE" -eq 1 ]]; then
        if [[ "$rc" -ne 0 ]]; then
            error_tail="$(tail -c 8192 "$MASTER_LOG_FILE" 2>/dev/null || true)"
            append_master_service_journal
            printf '\nHATA: Kurulum başarısız; rc=%s, aşama=%s, satır=%s\n' \
                "$rc" "${MASTER_CURRENT_STAGE:-0}" \
                "${MASTER_ERROR_LINE:-bilinmiyor}" >>"$MASTER_LOG_FILE"
        fi
        progress_restore_output

        if [[ "$rc" -ne 0 ]]; then
            MASTER_PROGRESS_ACTIVE=1
            progress_render "${MASTER_CURRENT_PERCENT:-0}" \
                "${MASTER_CURRENT_STAGE_LABEL:-Kurulum} başarısız" FAIL
            if [[ "$MASTER_PROGRESS_ANSI" -eq 1 ]]; then
                printf '\n' >&5
            fi
            printf '\nHATA: Kurulum aşama %s/7 sırasında durdu (çıkış kodu: %s' \
                "${MASTER_CURRENT_STAGE:-0}" "$rc" >&5
            if [[ -n "${MASTER_ERROR_LINE:-}" ]]; then
                printf ', satır: %s' "$MASTER_ERROR_LINE" >&5
            fi
            if [[ -n "${MASTER_SIGNAL:-}" ]]; then
                printf ', sinyal: %s' "$MASTER_SIGNAL" >&5
            fi
            printf ').\nLog: %s\n' "$MASTER_LOG_FILE" >&5
            printf '%s\n' '--- Logun son satırları ---' >&5
            printf '%s\n' "$error_tail" |
                tr '\r' '\n' |
                tail -n 20 >&5 || true
            printf '%s\n' '---------------------------' >&5
        fi
    fi

    progress_close_tty
    exit "$rc"
}

on_error() {
    local rc=$? line="${BASH_LINENO[0]:-${LINENO}}"
    trap - ERR
    set +e
    MASTER_ERROR_LINE="$line"
    if [[ "$MASTER_LOGGING_ACTIVE" -eq 1 ]]; then
        echo
        echo "HATA: Kurulum ${line}. satırda durdu (çıkış kodu: ${rc})." >&2
    else
        echo
        echo "HATA: Kurulum ${line}. satırda durdu (çıkış kodu: ${rc})." >&2
    fi
    exit "$rc"
}

on_signal() {
    MASTER_SIGNAL="$1"
    MASTER_ERROR_LINE="${3:-}"
    exit "$2"
}

trap on_error ERR
trap cleanup_master_setup EXIT
trap 'on_signal INT 130 "$LINENO"' INT
trap 'on_signal TERM 143 "$LINENO"' TERM

WG_UI_HTTP_CODE=""
WG_UI_LOCATION=""
wg_ui_probe() {
    local headers="" curl_rc=0
    WG_UI_HTTP_CODE=""
    WG_UI_LOCATION=""
    command -v curl >/dev/null 2>&1 || return 1

    headers="$(mktemp /run/master-wg-ui.XXXXXX)"
    WG_UI_HTTP_CODE="$(
        curl --noproxy "*" -sS -I \
            --connect-timeout 3 --max-time 5 \
            -o "$headers" -w '%{http_code}' \
            http://127.0.0.1:51821/ 2>/dev/null
    )" || curl_rc=$?
    WG_UI_LOCATION="$(
        awk -F': ' 'tolower($1) == "location" {
            gsub("\r", "", $2); print $2; exit
        }' "$headers" 2>/dev/null || true
    )"
    rm -f -- "$headers"
    [[ "$curl_rc" -eq 0 && "$WG_UI_HTTP_CODE" =~ ^[23][0-9][0-9]$ ]]
}

set_unit_file_mode() {
    local unit_path=""
    for unit_path in "$@"; do
        chown root:root "$unit_path"
        chmod 0644 "$unit_path"
    done
}

if [[ "$(id -u)" -ne 0 ]]; then
    echo "HATA: Bu betik root kullanıcısı olarak çalıştırılmalıdır." >&2
    exit 1
fi

if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    echo "HATA: Bu kurulum okunabilir/yazılabilir etkileşimli bir terminal (/dev/tty) gerektirir." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "HATA: /etc/os-release bulunamadı." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    echo "HATA: Bu betik yalnızca Debian için tasarlanmıştır (tespit edilen: ${ID:-bilinmiyor})." >&2
    exit 1
fi

if [[ "${VERSION_CODENAME:-}" != "trixie" || "${VERSION_ID:-}" != 13* ]]; then
    echo "HATA: Bu betik Debian 13 (trixie) için hazırlanmıştır." >&2
    echo "Tespit edilen: ${PRETTY_NAME:-bilinmiyor}, kod adı: ${VERSION_CODENAME:-bilinmiyor}" >&2
    exit 1
fi

if [[ "${MASTER_SETUP_INHIBITED:-0}" != "1" ]]; then
    if ! command -v systemd-inhibit >/dev/null 2>&1 ||
       [[ ! -d /run/systemd/system ]]; then
        echo "HATA: systemd shutdown inhibitörü kullanılamıyor; kurulum başlatılmadı." >&2
        exit 1
    fi

    MASTER_SETUP_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -z "$MASTER_SETUP_SELF" || ! -f "$MASTER_SETUP_SELF" ]]; then
        echo "HATA: Kurulum betiğinin gerçek dosya yolu çözülemedi." >&2
        exit 1
    fi

    exec systemd-inhibit \
        --what=shutdown:sleep \
        --who=master-setup \
        --why='Debian, Docker and Tailnet installation transaction' \
        --mode=block \
        env MASTER_SETUP_INHIBITED=1 bash "$MASTER_SETUP_SELF" "$@"
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "HATA: flock bulunamadı (util-linux kurulmalıdır)." >&2
    exit 1
fi
install -d -m 0755 /run/lock
exec 9>"$MASTER_LOCK_FILE"
if ! flock -w "$MASTER_LOCK_WAIT_SECONDS" 9; then
    echo "HATA: Ortak stack kilidi ${MASTER_LOCK_WAIT_SECONDS} saniyede alınamadı." >&2
    echo "Aktif master-maintenance/master.sh işlemini kontrol edin: $MASTER_LOCK_FILE" >&2
    exit 1
fi

MASTER_SETUP_STARTED_AT="$(date --iso-8601=seconds)"
export DEBIAN_FRONTEND=noninteractive

TIMEZONE="Europe/Berlin"
WG_PUBLIC_PORT="65171"
QBIT_PUBLIC_PORT="65173"
WEBDAV_PORT="65113"

MASTER_RESTART_COOLDOWN_SECONDS=900

PORTAINER_IMAGE="portainer/portainer-ce:lts"
FILEBROWSER_IMAGE="ghcr.io/gtsteffaniak/filebrowser:stable"
QBITTORRENT_IMAGE="lscr.io/linuxserver/qbittorrent:latest"
WG_EASY_IMAGE="ghcr.io/wg-easy/wg-easy:15.3"
UNPACKERR_IMAGE="ghcr.io/unpackerr/unpackerr:0.15"

echo "=================================================="
echo "  OTOMATİK SUNUCU KURULUMU"
echo "  Sürüm: $MASTER_SETUP_VERSION"
echo "  Debian 13 -> Tailscale Exit Node -> Docker"
echo "  -> Compose -> (Opsiyonel) Tailnet DNS + Caddy"
echo "=================================================="
echo

echo "==> 0/7 Kurulum bilgileri soruluyor..."
echo

read -rp "İndirme/medya dizini için host yolu [/downloads]: " DOWNLOADS_PATH_INPUT </dev/tty
DOWNLOADS_PATH="${DOWNLOADS_PATH_INPUT:-/downloads}"

if [[ ! "$DOWNLOADS_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "HATA: İndirme yolu mutlak olmalı ve yalnız güvenli yol karakterleri içermelidir." >&2
    exit 1
fi

DOWNLOADS_PATH="$(realpath -m -- "$DOWNLOADS_PATH")"
case "$DOWNLOADS_PATH" in
    /downloads|/downloads/*|/srv/*|/mnt/*|/media/*)
        ;;
    *)
        echo "HATA: İndirme yolu /downloads, /srv, /mnt veya /media altında olmalıdır." >&2
        echo "Tespit edilen: $DOWNLOADS_PATH" >&2
        exit 1
        ;;
esac
echo

EXISTING_MANAGED_DNS=0
if [[ -e /etc/dnsmasq.d/local-services.conf ||
      -e /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf ||
      -e /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf ]]; then
    EXISTING_MANAGED_DNS=1
fi

EXISTING_LOCAL_DOMAIN=""
if [[ "$EXISTING_MANAGED_DNS" -eq 1 && -r /etc/master-stack/state.env ]]; then
    EXISTING_LOCAL_DOMAIN="$(
        awk -F= '$1=="LOCAL_DOMAIN"{print $2; exit}' \
            /etc/master-stack/state.env 2>/dev/null
    )"
fi
DEFAULT_LOCAL_DOMAIN="${EXISTING_LOCAL_DOMAIN:-ayc}"

if [[ "$EXISTING_MANAGED_DNS" -eq 1 && -n "$EXISTING_LOCAL_DOMAIN" ]]; then
    echo "Mevcut yönetilen DNS/Caddy kurulumu tespit edildi (.$EXISTING_LOCAL_DOMAIN)."
    echo "Enter mevcut alan adını korur; farklı bir ad yazarsanız eski adlar"
    echo "silinip yenileri kurulur."
else
    echo "Servisler için Tailnet'e özel DNS adları (dnsmasq + Caddy) kurulacak."
    echo "Örnek: portainer.$DEFAULT_LOCAL_DOMAIN, file.$DEFAULT_LOCAL_DOMAIN, qbit.$DEFAULT_LOCAL_DOMAIN"
fi
read -rp "Yerel alan adı uzantısı [$DEFAULT_LOCAL_DOMAIN]: " LOCAL_DOMAIN_INPUT </dev/tty
LOCAL_DOMAIN="${LOCAL_DOMAIN_INPUT:-$DEFAULT_LOCAL_DOMAIN}"

LOCAL_DOMAIN="$(printf '%s' "$LOCAL_DOMAIN" | tr '[:upper:]' '[:lower:]')"

if [[ ${#LOCAL_DOMAIN} -gt 253 ||
      ! "$LOCAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ||
      "$LOCAL_DOMAIN" == *..* ]]; then
    echo "HATA: Geçersiz yerel alan adı: $LOCAL_DOMAIN" >&2
    exit 1
fi

IFS='.' read -r -a DOMAIN_LABELS <<<"$LOCAL_DOMAIN"
for label in "${DOMAIN_LABELS[@]}"; do
    if [[ -z "$label" || ${#label} -gt 63 || "$label" == -* || "$label" == *- ]]; then
        echo "HATA: Geçersiz DNS etiketi: $label" >&2
        exit 1
    fi
done
echo

WEBDAV_HTPASSWD_FILE="/etc/master-stack/webdav.htpasswd"

QUANTUM_CONFIG_FILE="/etc/master-stack/filebrowser.yaml"
WEBDAV_SETUP_CREDENTIALS=0
WEBDAV_USER=""
WEBDAV_PASSWORD=""
if [[ -s "$WEBDAV_HTPASSWD_FILE" ]]; then
    echo "Mevcut WebDAV kimlik bilgisi korunuyor: $WEBDAV_HTPASSWD_FILE"
    echo "Sıfırlamak için bu dosyayı silip betiği yeniden çalıştırın."
else
    WEBDAV_SETUP_CREDENTIALS=1
    echo "WebDAV (Apple TV/Infuse) erişimi için kimlik bilgisi belirleyin."
    read -rp "WebDAV kullanıcı adı [infuse]: " WEBDAV_USER_INPUT </dev/tty
    WEBDAV_USER="${WEBDAV_USER_INPUT:-infuse}"
    if [[ ! "$WEBDAV_USER" =~ ^[a-z][a-z0-9._-]{0,31}$ ]]; then
        echo "HATA: Kullanıcı adı küçük harfle başlamalı ve yalnız" >&2
        echo "a-z, 0-9, nokta, alt çizgi, tire içermelidir (en çok 32)." >&2
        exit 1
    fi
    while :; do
        read -rsp "WebDAV parolası (en az 8 karakter): " WEBDAV_PASSWORD </dev/tty
        echo
        if (( ${#WEBDAV_PASSWORD} < 8 )); then
            echo "Parola en az 8 karakter olmalı; yeniden deneyin."
            continue
        fi
        read -rsp "Parola (tekrar): " WEBDAV_PASSWORD_CONFIRM </dev/tty
        echo
        if [[ "$WEBDAV_PASSWORD" == "$WEBDAV_PASSWORD_CONFIRM" ]]; then
            break
        fi
        echo "Parolalar eşleşmedi; yeniden deneyin."
    done
    unset WEBDAV_PASSWORD_CONFIRM
fi
echo

echo "--- Özet ---"
echo "İndirme dizini     : $DOWNLOADS_PATH"
echo "Zaman dilimi       : $TIMEZONE"
if [[ "$WEBDAV_SETUP_CREDENTIALS" -eq 1 ]]; then
    echo "WebDAV kullanıcısı : $WEBDAV_USER (yeni; host rclone servisi, salt okunur)"
else
    echo "WebDAV kullanıcısı : mevcut htpasswd korunuyor"
fi
echo "Tailnet DNS        : .$LOCAL_DOMAIN (dnsmasq + Caddy)"
echo

read -rp "Devam edilsin mi? [E/h]: " CONFIRM </dev/tty
CONFIRM="${CONFIRM:-E}"
if [[ ! "$CONFIRM" =~ ^[EeYy]$ ]]; then
    echo "Kurulum iptal edildi."
    exit 0
fi

progress_setup_logging

progress_stage_begin 1 "Temel Debian sistemi hazırlanıyor"

if systemctl list-jobs --no-legend 2>/dev/null |
    awk '$2 ~ /^(reboot|shutdown|poweroff|halt)\.target$/ {found=1}
         END {exit(found ? 0 : 1)}'; then
    echo "HATA: Aktif shutdown/reboot transaction'ı var; kurulum başlatılmadı." >&2
    exit 1
fi

RECONCILE_TIMER_WAS_ACTIVE=0
RECONCILE_TIMER_WAS_ENABLED=0
APT_DAILY_TIMER_WAS_ACTIVE=0
APT_DAILY_UPGRADE_TIMER_WAS_ACTIVE=0
systemctl is-active --quiet master-network-reconcile.timer 2>/dev/null &&
    RECONCILE_TIMER_WAS_ACTIVE=1
systemctl is-enabled --quiet master-network-reconcile.timer 2>/dev/null &&
    RECONCILE_TIMER_WAS_ENABLED=1
systemctl is-active --quiet apt-daily.timer 2>/dev/null &&
    APT_DAILY_TIMER_WAS_ACTIVE=1
systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null &&
    APT_DAILY_UPGRADE_TIMER_WAS_ACTIVE=1

RECONCILE_TIMER_REENABLED=0
APT_DAILY_TIMER_REENABLED=0
APT_DAILY_UPGRADE_TIMER_REENABLED=0
TIMER_WINDOW_PREPARED=1

stop_timer_if_loaded() {
    local unit="$1" load_state=""
    load_state="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
    if [[ -z "$load_state" || "$load_state" == "not-found" ]]; then
        return 0
    fi
    systemctl stop "$unit"
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "HATA: Timer durdurulamadı: $unit" >&2
        return 1
    fi
}

stop_timer_if_loaded master-network-reconcile.timer
stop_timer_if_loaded apt-daily.timer
stop_timer_if_loaded apt-daily-upgrade.timer

if [[ "$(systemctl show master-network-reconcile.service \
        -p LoadState --value 2>/dev/null || true)" != "not-found" ]]; then
    systemctl stop master-network-reconcile.service
    if systemctl is-active --quiet master-network-reconcile.service 2>/dev/null; then
        echo "HATA: master-network-reconcile.service durdurulamadı." >&2
        exit 1
    fi
fi

APT_BACKGROUND_WAIT_SECONDS=300
APT_BACKGROUND_WAITED=0
while systemctl is-active --quiet apt-daily.service 2>/dev/null ||
      systemctl is-active --quiet apt-daily-upgrade.service 2>/dev/null; do
    if (( APT_BACKGROUND_WAITED >= APT_BACKGROUND_WAIT_SECONDS )); then
        echo "HATA: Arka plan apt işlemi ${APT_BACKGROUND_WAIT_SECONDS} saniyede bitmedi." >&2
        exit 1
    fi
    sleep 2
    APT_BACKGROUND_WAITED=$((APT_BACKGROUND_WAITED + 2))
done

if systemctl list-jobs --no-legend 2>/dev/null |
    awk '$2 ~ /^(reboot|shutdown|poweroff|halt)\.target$/ {found=1}
         END {exit(found ? 0 : 1)}'; then
    echo "HATA: Kurulum penceresi hazırlanırken reboot transaction'ı oluştu." >&2
    exit 1
fi

progress_stage_note 20 "Paket yöneticisi ve timer penceresi hazırlanıyor"

timedatectl set-timezone "$TIMEZONE"

progress_stage_note 30 "Debian paket listeleri indiriliyor"
retry_network "apt-get update" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" update
progress_stage_note 45 "Debian sistem güncellemeleri uygulanıyor"
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    full-upgrade -y
progress_stage_note 80 "Temel ağ ve sistem araçları kuruluyor"
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" install -y \
    ca-certificates curl gnupg ethtool iproute2 gawk procps kmod \
    iptables coreutils util-linux diffutils jq rclone apache2-utils

echo "İşletim sistemi: ${PRETTY_NAME}, zaman dilimi: $TIMEZONE"
progress_stage_note 95 "Temel sistem doğrulanıyor"

progress_stage_done
progress_stage_begin 2 "Tailscale ve exit-node hazırlanıyor"

if ! modprobe tun 2>/tmp/modprobe-tun.err; then
    echo "UYARI: 'modprobe tun' başarısız oldu:" >&2
    cat /tmp/modprobe-tun.err >&2 || true
fi
rm -f /tmp/modprobe-tun.err

if [[ ! -c /dev/net/tun ]]; then
    echo "HATA: /dev/net/tun bulunamadı. Sağlayıcıda TUN/TAP desteğini açın." >&2
    exit 1
fi

progress_stage_note 10 "Tailscale paket deposu hazırlanıyor"
install -d -m 0755 /usr/share/keyrings
retry_network "Tailscale keyring indirme" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg" \
    -o /tmp/tailscale-archive-keyring.gpg
install -m 0644 /tmp/tailscale-archive-keyring.gpg \
    /usr/share/keyrings/tailscale-archive-keyring.gpg
rm -f /tmp/tailscale-archive-keyring.gpg

retry_network "Tailscale depo listesi indirme" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list

retry_network "apt-get update" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" update
progress_stage_note 22 "UDP soket buffer tabanı ayarlanıyor"

NET_BUF_FLOOR_BYTES=16777216
CURRENT_RMEM_MAX="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
CURRENT_WMEM_MAX="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
[[ "$CURRENT_RMEM_MAX" =~ ^[0-9]+$ ]] || CURRENT_RMEM_MAX=0
[[ "$CURRENT_WMEM_MAX" =~ ^[0-9]+$ ]] || CURRENT_WMEM_MAX=0

TARGET_RMEM_MAX="$NET_BUF_FLOOR_BYTES"
TARGET_WMEM_MAX="$NET_BUF_FLOOR_BYTES"
if (( CURRENT_RMEM_MAX > TARGET_RMEM_MAX )); then
    TARGET_RMEM_MAX="$CURRENT_RMEM_MAX"
fi
if (( CURRENT_WMEM_MAX > TARGET_WMEM_MAX )); then
    TARGET_WMEM_MAX="$CURRENT_WMEM_MAX"
fi

cat >/etc/sysctl.d/99-master-stack-netbuf.conf <<SYSCTL_NETBUF
net.core.rmem_max = $TARGET_RMEM_MAX
net.core.wmem_max = $TARGET_WMEM_MAX
SYSCTL_NETBUF
chown root:root /etc/sysctl.d/99-master-stack-netbuf.conf
chmod 0644 /etc/sysctl.d/99-master-stack-netbuf.conf
sysctl -p /etc/sysctl.d/99-master-stack-netbuf.conf

progress_stage_note 25 "Tailscale paketi kuruluyor"
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" install -y tailscale
systemctl enable --now tailscaled
progress_stage_note 40 "IP forwarding ve UDP GRO hazırlanıyor"

cat >/etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
chown root:root /etc/sysctl.d/99-tailscale.conf
chmod 0644 /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

cat >/usr/local/sbin/tailscale-udp-gro <<'GRO_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

IP_BIN="$(command -v ip)"
AWK_BIN="$(command -v awk)"
ETHTOOL_BIN="$(command -v ethtool)"

declare -A SEEN=()
NETDEVS=()
APPLY_FAILED=0

add_default_netdev() {
    local family="$1" probe="$2" dev=""
    dev="$(
        "$IP_BIN" "$family" -o route get "$probe" 2>/dev/null |
            "$AWK_BIN" '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
    )" || true

    if [[ -n "$dev" && -z "${SEEN[$dev]:-}" ]]; then
        SEEN["$dev"]=1
        NETDEVS+=("$dev")
    fi
}

add_default_netdev -4 8.8.8.8
add_default_netdev -6 2001:4860:4860::8888

if [[ "${#NETDEVS[@]}" -eq 0 ]]; then
    echo "HATA: Varsayılan internet arayüzü henüz tespit edilemedi." >&2
    exit 1
fi

for netdev in "${NETDEVS[@]}"; do
    echo "UDP GRO kontrol edilen arayüz: $netdev"

    features="$($ETHTOOL_BIN -k "$netdev" 2>/dev/null || true)"
    if grep -q '^rx-udp-gro-forwarding: on' <<<"$features" &&
       grep -q '^rx-gro-list: off' <<<"$features"; then
        echo "$netdev üzerinde UDP GRO ayarları zaten önerilen değerlerde."
        continue
    fi

    if ! grep -q '^rx-udp-gro-forwarding:' <<<"$features" ||
       ! grep -q '^rx-gro-list:' <<<"$features"; then
        echo "UYARI: $netdev sürücüsü gereken iki UDP GRO özelliğini bildirmiyor." >&2
        continue
    fi

    if grep -E '^rx-udp-gro-forwarding:.*\[fixed\]|^rx-gro-list:.*\[fixed\]' \
        <<<"$features" >/dev/null; then
        echo "UYARI: $netdev üzerindeki UDP GRO özellikleri sürücü tarafından sabitlenmiş." >&2
        continue
    fi

    "$ETHTOOL_BIN" -K "$netdev" rx-udp-gro-forwarding on rx-gro-list off || {
        echo "UYARI: $netdev üzerinde UDP GRO ayarları uygulanamadı." >&2
        APPLY_FAILED=1
        continue
    }

    updated_features="$($ETHTOOL_BIN -k "$netdev" 2>/dev/null || true)"
    grep -E '^rx-udp-gro-forwarding:|^rx-gro-list:' <<<"$updated_features" || true

    if ! grep -q '^rx-udp-gro-forwarding: on' <<<"$updated_features" ||
       ! grep -q '^rx-gro-list: off' <<<"$updated_features"; then
        echo "UYARI: $netdev UDP GRO değerleri doğrulanamadı; yeniden denenecek." >&2
        APPLY_FAILED=1
    fi
done

exit "$APPLY_FAILED"
GRO_SCRIPT
chmod 0755 /usr/local/sbin/tailscale-udp-gro

cat >/etc/systemd/system/tailscale-udp-gro.service <<'SYSTEMD'
[Unit]
Description=Tailscale UDP GRO forwarding optimization
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-udp-gro
RemainAfterExit=yes
Restart=no
TimeoutStartSec=30s

[Install]
WantedBy=multi-user.target
SYSTEMD
set_unit_file_mode /etc/systemd/system/tailscale-udp-gro.service

systemctl daemon-reload
systemctl enable tailscale-udp-gro.service
if ! systemctl start tailscale-udp-gro.service; then
    echo "UYARI: UDP GRO optimizasyonu ilk denemede uygulanamadı; reconcile yeniden deneyecek." >&2
    echo "Tailscale kurulumu bu performans optimizasyonu nedeniyle durdurulmadı." >&2
    systemctl reset-failed tailscale-udp-gro.service >/dev/null 2>&1 || true
fi

progress_stage_note 55 "tailscaled ve Tailnet bağlantısı bekleniyor"
SOCKET_PATH="/run/tailscale/tailscaled.sock"
echo "tailscaled soketi bekleniyor..."
TAILSCALED_READY=0
for _ in $(seq 1 30); do
    if [[ -S "$SOCKET_PATH" ]]; then
        TAILSCALED_READY=1
        break
    fi
    sleep 1
done

if [[ "$TAILSCALED_READY" -ne 1 ]]; then
    echo "HATA: tailscaled soketi 30 saniyede oluşmadı: $SOCKET_PATH" >&2
    exit 1
fi

tailscale_daemon_ready() {
    local _
    for _ in $(seq 1 30); do
        if tailscale status --json >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

TAILSCALE_LOGIN_ATTEMPTS=3
TAILSCALE_AUTH_PATH_DEAD_SAMPLES=3
TAILSCALE_LOGIN_STATUS_TIMEOUT=3
TAILSCALE_LOGIN_POST_SUCCESS_GRACE=15
TAILSCALE_LOGIN_TIMEOUT=300

tailscale_login_state() {
    local status_json="" state=""

    if ! status_json="$(
        timeout "$TAILSCALE_LOGIN_STATUS_TIMEOUT" \
            tailscale status --json 2>/dev/null
    )"; then
        printf 'unknown\n'
        return 0
    fi

    state="$(
        jq -r '
            if (
                .BackendState == "Running" and
                .Self.Online == true and
                ((.Self.ID // "") | length) > 0 and
                ((.Self.TailscaleIPs // []) | length) > 0
            ) then
                "complete"
            elif (
                .BackendState == "NeedsLogin" and
                .Self.Online != true and
                (.Self.ID // "") == "" and
                any(.Health[]?; contains("http 410: auth path not found"))
            ) then
                "auth_path_dead"
            else
                "pending"
            end
        ' <<<"$status_json" 2>/dev/null
    )" || state="unknown"

    case "$state" in
        complete | auth_path_dead | pending) printf '%s\n' "$state" ;;
        *) printf 'unknown\n' ;;
    esac
}

tailscale_login_complete() {
    [[ "$(tailscale_login_state)" == "complete" ]]
}

tailscale_interactive_login() {
    local attempt out_file up_pid streamed total elapsed outcome
    local login_state auth_path_dead_samples attempt_started
    local post_success_started

    out_file="$(mktemp)"

    for ((attempt = 1; attempt <= TAILSCALE_LOGIN_ATTEMPTS; attempt++)); do
        : >"$out_file"
        streamed=0
        auth_path_dead_samples=0
        attempt_started=$SECONDS

        if [[ "$attempt" -gt 1 ]]; then
            printf '\n' >&5
            printf 'ÖNCEKİ BAĞLANTI ARTIK GEÇERSİZ — onu açmayın.\n' >&5
            printf 'Tarayıcıdaki eski Tailscale sekmelerini kapatın; birini\n' >&5
            printf 'açmak yeni bağlantıyı da geçersiz kılar.\n' >&5
            printf 'Yeni bağlantı (%s/%s):\n' \
                "$attempt" "$TAILSCALE_LOGIN_ATTEMPTS" >&5
        fi

        tailscale up --advertise-exit-node --ssh >"$out_file" 2>&1 &
        up_pid=$!

        elapsed=0
        outcome=""
        while :; do
            total="$(wc -l <"$out_file")"
            if [[ "$total" -gt "$streamed" ]]; then
                sed -n "$((streamed + 1)),${total}p" "$out_file" |
                    tee -a "$MASTER_LOG_FILE" >&5
                streamed="$total"
            fi

            if ! kill -0 "$up_pid" 2>/dev/null; then
                outcome=0
                wait "$up_pid" || outcome=$?
                break
            fi

            login_state="$(tailscale_login_state)"
            if [[ "$login_state" == "auth_path_dead" ]]; then
                auth_path_dead_samples=$((auth_path_dead_samples + 1))
                if [[ "$auth_path_dead_samples" -ge "$TAILSCALE_AUTH_PATH_DEAD_SAMPLES" ]]; then
                    outcome="auth_path_dead"
                    break
                fi
            else
                auth_path_dead_samples=0
            fi

            elapsed=$((SECONDS - attempt_started))
            if [[ "$elapsed" -ge "$TAILSCALE_LOGIN_TIMEOUT" ]]; then
                outcome="timeout"
                break
            fi

            sleep 2
        done

        total="$(wc -l <"$out_file")"
        if [[ "$total" -gt "$streamed" ]]; then
            sed -n "$((streamed + 1)),${total}p" "$out_file" |
                tee -a "$MASTER_LOG_FILE" >&5
        fi

        if [[ "$outcome" == "0" ]]; then
            post_success_started=$SECONDS
            while [[ "$((SECONDS - post_success_started))" -lt "$TAILSCALE_LOGIN_POST_SUCCESS_GRACE" ]]; do
                if tailscale_login_complete; then
                    rm -f "$out_file"
                    return 0
                fi
                sleep 1
            done
            echo "NOT: Giriş başarılı; düğüm ${TAILSCALE_LOGIN_POST_SUCCESS_GRACE} saniyede online kimlik/IP" >&2
            echo "doğrulamasını geçmedi. Yeniden giriş İSTENMİYOR; online olma beklemesi" >&2
            echo "aşağıdaki 180 saniyelik kontrole bırakıldı." >&2
            rm -f "$out_file"
            return 0
        fi

        kill "$up_pid" 2>/dev/null || true
        wait "$up_pid" 2>/dev/null || true

        case "$outcome" in
            auth_path_dead)
                echo "Tailscale auth yolu kalıcı 410 durumunda; 300 saniye beklenmeyecek." >&2
                echo "Daemon sıfırlanıp yeni kayıt bağlantısı açılıyor." >&2
                ;;
            timeout)
                echo "Tailscale girişi ${TAILSCALE_LOGIN_TIMEOUT} saniyede tamamlanmadı." >&2
                echo "Bağlantı kilitlenmiş olabilir; daemon sıfırlanıp yenisi açılıyor." >&2
                ;;
            *)
                echo "tailscale up rc=${outcome} ile döndü; daemon sıfırlanıyor." >&2
                ;;
        esac

        systemctl restart tailscaled
        if ! tailscale_daemon_ready; then
            echo "HATA: tailscaled yeniden başlatıldıktan sonra yanıt vermedi." >&2
            rm -f "$out_file"
            return 1
        fi
    done

    rm -f "$out_file"
    echo "HATA: Tailscale girişi ${TAILSCALE_LOGIN_ATTEMPTS} denemede tamamlanamadı." >&2
    echo "Elle kurtarma — logout YETMEZ, daemon ölü bağlantıyı bellekte tutar:" >&2
    echo "  systemctl restart tailscaled && tailscale up" >&2
    echo "Bağlantı geldiğinde HEMEN açın ve eski sekmeleri kapatın." >&2
    echo "Ayrıntı: journalctl -u tailscaled -n 50" >&2
    return 1
}

tailscale_journal_has_node_not_found() {
    journalctl -u tailscaled \
        --since "${MASTER_SETUP_STARTED_AT:--5min}" \
        --no-pager 2>/dev/null |
        grep -F "node not found" >/dev/null
}

TAILSCALE_NEEDS_LOGIN=0

if ! tailscale ip -4 >/dev/null 2>&1; then
    TAILSCALE_NEEDS_LOGIN=1
else
    echo "Kayıtlı Tailscale bağlantısının online olması bekleniyor..."
    TAILSCALE_ONLINE_DEADLINE=$((SECONDS + 60))
    while ! tailscale_login_complete; do
        (( SECONDS < TAILSCALE_ONLINE_DEADLINE )) || break
        sleep 1
    done
    if ! tailscale_login_complete; then
        if tailscale_journal_has_node_not_found; then
            echo "UYARI: Kayıtlı Tailscale profili 60 saniyede online olmadı." >&2
            echo "NEDEN: Kontrol düzlemi bu düğümü tanımıyor (404 node not found)." >&2
            echo "Düğüm Tailscale panelinden silinmiş; yerel profil geçerli görünse de" >&2
            echo "sunucu tarafında karşılığı yok." >&2
            echo "Yerel profil temizlenip yeni kayıt açılıyor..." >&2
            if ! timeout 60 tailscale logout; then
                echo "HATA: Yerel Tailscale profili temizlenemedi." >&2
                echo "Elle deneyin: tailscale logout && bash $0" >&2
                exit 1
            fi
            TAILSCALE_NEEDS_LOGIN=1
        else
            echo "HATA: Kayıtlı Tailscale profili 60 saniyede online olmadı." >&2
            echo "Ağ/control-plane erişimini veya mevcut profili kontrol edip yeniden çalıştırın." >&2
            echo "Ayrıntı için: journalctl -u tailscaled -n 50" >&2
            exit 1
        fi
    else
        echo "Sunucu zaten bir Tailscale ağına bağlı."
        tailscale status --self 2>/dev/null | head -n 1 || true
    fi
fi

if [[ "$TAILSCALE_NEEDS_LOGIN" -eq 1 ]]; then
    progress_clear_line
    printf 'Tailscale girişi gerekiyor; aşağıdaki bağlantıyı tarayıcıda açın:\n' >&5
    printf '[%s] Etkileşimli Tailscale girişi başladı.\n' \
        "$(date --iso-8601=seconds)" >>"$MASTER_LOG_FILE"
    printf 'Bağlantı geldiği anda açın. Kurulumu YENİDEN BAŞLATMAYIN:\n' >&5
    printf 'yeniden başlatmak yeni bir kayıt açar ve bekleyen bağlantıyı\n' >&5
    printf 'öldürür (410). Takılırsa betik kendisi kurtarıp yenisini basar.\n' >&5
    if ! tailscale_interactive_login; then
        exit 1
    fi
    progress_stage_resume
fi

progress_stage_note 70 "Tailscale IPv4 ve online durumu doğrulanıyor"
TAILSCALE_CONNECTED=0
TAILSCALE_CONNECT_DEADLINE=$((SECONDS + 180))
while true; do
    if tailscale ip -4 >/dev/null 2>&1 && tailscale_login_complete; then
        TAILSCALE_CONNECTED=1
        break
    fi
    (( SECONDS < TAILSCALE_CONNECT_DEADLINE )) || break
    sleep 2
done

if [[ "$TAILSCALE_CONNECTED" -ne 1 ]]; then
    echo "HATA: Tailscale 180 saniye içinde IPv4 adresi alamadı." >&2
    exit 1
fi

tailscale set \
    --advertise-exit-node \
    --ssh=true \
    --stateful-filtering=true \
    --netfilter-mode=on \
    --snat-subnet-routes=true
progress_stage_note 90 "Exit-node, Tailscale SSH ve stateful filtering doğrulanıyor"

TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
if [[ ! "$TS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "HATA: Tailscale bağlantısı hazır görünüyor ancak geçerli IPv4 alınamadı." >&2
    exit 1
fi
echo "Tailscale IPv4: $TS_IP"

progress_stage_done
progress_stage_begin 3 "Docker ve dar firewall politikası hazırlanıyor"

install -m 0755 -d /etc/apt/keyrings
retry_network "Docker GPG anahtarı indirme" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

progress_stage_note 15 "Docker daemon yapılandırması hazırlanıyor"

DOCKER_WAS_ACTIVE=0
if systemctl is-active --quiet docker.service 2>/dev/null; then
    DOCKER_WAS_ACTIVE=1
fi

install -d -m 0755 /etc/docker
DOCKER_DAEMON_JSON_CHANGED=0
DOCKER_DAEMON_JSON_TMP="$(mktemp /etc/docker/daemon.json.XXXXXX)"

if [[ -f /etc/docker/daemon.json ]]; then
    if ! jq empty /etc/docker/daemon.json 2>/dev/null; then
        rm -f "$DOCKER_DAEMON_JSON_TMP"
        echo "HATA: Mevcut /etc/docker/daemon.json geçerli JSON değil." >&2
        echo "Dosya elle düzeltilmeden üzerine yazılmayacak." >&2
        exit 1
    fi
    jq '.dns = ["1.1.1.1", "1.0.0.1"]' /etc/docker/daemon.json >"$DOCKER_DAEMON_JSON_TMP"
else
    jq -n '{dns: ["1.1.1.1", "1.0.0.1"]}' >"$DOCKER_DAEMON_JSON_TMP"
fi
chmod 0644 "$DOCKER_DAEMON_JSON_TMP"

if cmp -s "$DOCKER_DAEMON_JSON_TMP" /etc/docker/daemon.json 2>/dev/null; then
    rm -f "$DOCKER_DAEMON_JSON_TMP"
else
    mv -f "$DOCKER_DAEMON_JSON_TMP" /etc/docker/daemon.json
    DOCKER_DAEMON_JSON_CHANGED=1
fi

if [[ "$DOCKER_WAS_ACTIVE" -eq 1 && "$DOCKER_DAEMON_JSON_CHANGED" -eq 0 ]]; then
    DAEMON_JSON_MTIME_EPOCH="$(stat -c %Y /etc/docker/daemon.json 2>/dev/null || echo 0)"
    DOCKER_ACTIVE_SINCE_EPOCH="$(
        date -d "$(systemctl show docker.service --property=ActiveEnterTimestamp --value)" \
            +%s 2>/dev/null || echo 0
    )"
    if [[ "$DAEMON_JSON_MTIME_EPOCH" -gt "$DOCKER_ACTIVE_SINCE_EPOCH" ]]; then
        DOCKER_DAEMON_JSON_CHANGED=1
    fi
fi

progress_stage_note 30 "Docker paket listeleri ve bileşenleri kuruluyor"
retry_network "apt-get update" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" update
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

progress_stage_note 65 "Docker daemon doğrulanıp başlatılıyor"
dockerd --validate --config-file /etc/docker/daemon.json
systemctl enable --now docker

detect_ipv4_route() {
    local route_line=""
    route_line="$(ip -4 -o route get 1.1.1.1 2>/dev/null || true)"
    WAN4_IF="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$route_line")"
    PUBLIC_IPV4="$(awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<<"$route_line")"

    if [[ -z "$WAN4_IF" || -z "$PUBLIC_IPV4" ]]; then
        echo "HATA: Varsayılan rota arayüzü veya IPv4 adresi tespit edilemedi." >&2
        exit 1
    fi

    if ! ip -4 -o addr show dev "$WAN4_IF" | awk '{print $4}' | cut -d/ -f1 |
        grep -Fx "$PUBLIC_IPV4" >/dev/null; then
        echo "HATA: Tespit edilen IPv4, $WAN4_IF üzerinde bulunamadı: $PUBLIC_IPV4" >&2
        exit 1
    fi
}

detect_ipv4_route
progress_stage_note 75 "WAN IPv4 ve Docker ağ yolu belirleniyor"
echo "WAN IPv4 arayüzü : $WAN4_IF"
echo "Bağlanılacak IPv4: $PUBLIC_IPV4"

cat >/usr/local/sbin/docker-tailscale-fw <<'FW_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

IP_BIN="$(command -v ip)"
AWK_BIN="$(command -v awk)"
IPTABLES_BIN="$(command -v iptables)"
IP6TABLES_BIN="$(command -v ip6tables || true)"
FLOCK_BIN="$(command -v flock)"
POLICY_CHAIN="MASTER-DOCKER"
TS_GUARD_CHAIN="MASTER-TS-FORWARD"
TS_IF="tailscale0"
MODE="${1:-apply}"

case "$MODE" in
    apply|--check)
        ;;
    *)
        echo "HATA: Kullanım: docker-tailscale-fw [--check]" >&2
        exit 2
        ;;
esac

if [[ -z "$IP6TABLES_BIN" ]]; then
    echo "HATA: ip6tables bulunamadı; IPv6 Tailnet izolasyon politikası uygulanamaz." >&2
    echo "IPv6 forwarding açık olduğu için politikasız devam etmek güvenli değil." >&2
    exit 1
fi

exec 9>/run/lock/docker-tailscale-fw.lock
if ! "$FLOCK_BIN" -w 30 9; then
    echo "HATA: Firewall uygulama kilidi 30 saniyede alınamadı." >&2
    exit 1
fi

route_value() {
    local family="$1" probe="$2" keyword="$3"
    "$IP_BIN" "$family" -o route get "$probe" 2>/dev/null |
        "$AWK_BIN" -v key="$keyword" \
        '{for (i=1; i<=NF; i++) if ($i==key) {print $(i+1); exit}}'
}

WAN4_IF=""
PUBLIC_IPV4=""
TAILSCALE_IPV4=""
for _ in $(seq 1 300); do
    WAN4_IF="$(route_value -4 1.1.1.1 dev || true)"
    PUBLIC_IPV4="$(route_value -4 1.1.1.1 src || true)"
    TAILSCALE_IPV4="$(
        "$IP_BIN" -4 -o addr show dev "$TS_IF" scope global 2>/dev/null |
            "$AWK_BIN" 'NR == 1 {sub(/\/.*/, "", $4); print $4}' || true
    )"

    if [[ -n "$WAN4_IF" && -n "$PUBLIC_IPV4" &&
          "$TAILSCALE_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    fi
    sleep 1
done

if [[ -z "$WAN4_IF" || -z "$PUBLIC_IPV4" ]]; then
    echo "HATA: IPv4 default route veya kaynak adres 300 saniyede hazır olmadı." >&2
    exit 1
fi

if [[ ! "$TAILSCALE_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "HATA: Firewall için Tailscale IPv4 300 saniyede hazır olmadı." >&2
    exit 1
fi

WAN6_IF="$(route_value -6 2001:4860:4860::8888 dev || true)"

wait_for_chain() {
    local bin="$1" chain="$2"
    for _ in $(seq 1 30); do
        if "$bin" -w 5 -L "$chain" -n >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_docker_user() {
    wait_for_chain "$1" DOCKER-USER
}

remove_legacy_wide_rules() {
    local bin="$1"
    while "$bin" -w 5 -C DOCKER-USER -i "$TS_IF" -j RETURN 2>/dev/null; do
        "$bin" -w 5 -D DOCKER-USER -i "$TS_IF" -j RETURN
    done
    while "$bin" -w 5 -C DOCKER-USER -o "$TS_IF" -j RETURN 2>/dev/null; do
        "$bin" -w 5 -D DOCKER-USER -o "$TS_IF" -j RETURN
    done
}

create_staging_chain() {
    local bin="$1"
    local staging_chain=""

    for _ in $(seq 1 20); do
        staging_chain="MASTER-NEXT-$RANDOM"
        if "$bin" -w 5 -N "$staging_chain" 2>/dev/null; then
            printf '%s\n' "$staging_chain"
            return 0
        fi
    done

    echo "HATA: Geçici firewall zinciri oluşturulamadı." >&2
    return 1
}

activate_staging_chain() {
    local bin="$1" staging_chain="$2" stale_chain=""

    "$bin" -w 5 -I DOCKER-USER 1 -j "$staging_chain"
    remove_legacy_wide_rules "$bin"

    while [[ "$(
        "$bin" -w 5 -S DOCKER-USER 2>/dev/null |
            "$AWK_BIN" '$1 == "-A" {count++} END {print count+0}'
    )" -gt 1 ]]; do
        "$bin" -w 5 -D DOCKER-USER 2
    done

    while read -r stale_chain; do
        [[ -n "$stale_chain" && "$stale_chain" != "$staging_chain" ]] || continue
        while "$bin" -w 5 -C DOCKER-USER -j "$stale_chain" 2>/dev/null; do
            "$bin" -w 5 -D DOCKER-USER -j "$stale_chain"
        done
        "$bin" -w 5 -F "$stale_chain"
        "$bin" -w 5 -X "$stale_chain"
    done < <(
        "$bin" -w 5 -S |
            "$AWK_BIN" '$1=="-N" && $2 ~ /^MASTER-NEXT-/ {print $2}'
    )

    if "$bin" -w 5 -L "$POLICY_CHAIN" -n >/dev/null 2>&1; then
        "$bin" -w 5 -F "$POLICY_CHAIN"
        "$bin" -w 5 -X "$POLICY_CHAIN"
    fi

    "$bin" -w 5 -E "$staging_chain" "$POLICY_CHAIN"
}

ensure_forward_prefix() {
    local bin="$1" target="" last_rule=""

    for target in DOCKER-USER DOCKER-FORWARD ts-forward; do
        if ! wait_for_chain "$bin" "$target"; then
            echo "HATA: Beklenen firewall zinciri bulunamadı: $target ($bin)." >&2
            echo "Docker veya Tailscale sürümü bu betiğin varsaydığı zincir düzenini değiştirmiş olabilir." >&2
            return 1
        fi
    done

    "$bin" -w 5 -I FORWARD 1 -j ts-forward
    "$bin" -w 5 -I FORWARD 1 -j DOCKER-FORWARD
    "$bin" -w 5 -I FORWARD 1 -j DOCKER-USER
    for target in DOCKER-USER DOCKER-FORWARD ts-forward; do
        while :; do
            last_rule="$(
                "$bin" -w 5 -L FORWARD -n --line-numbers 2>/dev/null |
                    "$AWK_BIN" -v target="$target" \
                        '$2 == target {count++; last=$1}
                         END {if (count > 1) print last}'
            )"
            [[ "$last_rule" =~ ^[0-9]+$ ]] || break
            "$bin" -w 5 -D FORWARD "$last_rule"
        done
    done
}

create_ts_guard_staging_chain() {
    local bin="$1"
    local staging_chain=""

    for _ in $(seq 1 20); do
        staging_chain="MASTER-TS-NEXT-$RANDOM"
        if "$bin" -w 5 -t mangle -N "$staging_chain" 2>/dev/null; then
            printf '%s\n' "$staging_chain"
            return 0
        fi
    done

    echo "HATA: Geçici Tailnet pre-forward zinciri oluşturulamadı." >&2
    return 1
}

activate_ts_guard_staging_chain() {
    local bin="$1" staging_chain="$2" stale_chain=""

    "$bin" -w 5 -t mangle -I FORWARD 1 -j "$staging_chain"

    while "$bin" -w 5 -t mangle -C FORWARD -j "$TS_GUARD_CHAIN" 2>/dev/null; do
        "$bin" -w 5 -t mangle -D FORWARD -j "$TS_GUARD_CHAIN"
    done

    while read -r stale_chain; do
        [[ -n "$stale_chain" && "$stale_chain" != "$staging_chain" ]] || continue
        while "$bin" -w 5 -t mangle -C FORWARD -j "$stale_chain" 2>/dev/null; do
            "$bin" -w 5 -t mangle -D FORWARD -j "$stale_chain"
        done
        "$bin" -w 5 -t mangle -F "$stale_chain"
        "$bin" -w 5 -t mangle -X "$stale_chain"
    done < <(
        "$bin" -w 5 -t mangle -S |
            "$AWK_BIN" '$1=="-N" && $2 ~ /^MASTER-TS-NEXT-/ {print $2}'
    )

    if "$bin" -w 5 -t mangle -L "$TS_GUARD_CHAIN" -n >/dev/null 2>&1; then
        "$bin" -w 5 -t mangle -F "$TS_GUARD_CHAIN"
        "$bin" -w 5 -t mangle -X "$TS_GUARD_CHAIN"
    fi

    "$bin" -w 5 -t mangle -E "$staging_chain" "$TS_GUARD_CHAIN"
}

apply_tailnet_guard() {
    local bin="$1" wan_if="$2" family="$3" staging_chain=""

    staging_chain="$(create_ts_guard_staging_chain "$bin")"
    "$bin" -w 5 -t mangle -A "$staging_chain" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    if [[ -n "$wan_if" ]]; then
        "$bin" -w 5 -t mangle -A "$staging_chain" \
            -i "$TS_IF" -o "$wan_if" \
            -j MARK --set-xmark 0x40000/0xff0000
        "$bin" -w 5 -t mangle -A "$staging_chain" \
            -i "$TS_IF" -o "$wan_if" -j ACCEPT
    fi

    "$bin" -w 5 -t mangle -A "$staging_chain" -i "$TS_IF" -j DROP
    "$bin" -w 5 -t mangle -A "$staging_chain" -o "$TS_IF" -j DROP
    "$bin" -w 5 -t mangle -A "$staging_chain" -j RETURN

    activate_ts_guard_staging_chain "$bin" "$staging_chain"
}

apply_ipv4() {
    local bin="$1" staging_chain=""
    wait_for_docker_user "$bin" || {
        echo "HATA: IPv4 DOCKER-USER zinciri bulunamadı." >&2
        return 1
    }

    staging_chain="$(create_staging_chain "$bin")"

    "$bin" -w 5 -A "$staging_chain" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    "$bin" -w 5 -A "$staging_chain" \
        -i "$TS_IF" -o "$WAN4_IF" -j ACCEPT

    "$bin" -w 5 -A "$staging_chain" -o "$TS_IF" -j DROP

    "$bin" -w 5 -A "$staging_chain" \
        -i "$WAN4_IF" -p tcp \
        -m conntrack --ctstate NEW \
        --ctorigdst "$PUBLIC_IPV4" --ctorigdstport 65173 \
        -j RETURN

    "$bin" -w 5 -A "$staging_chain" \
        -i "$WAN4_IF" -p udp \
        -m conntrack --ctstate NEW \
        --ctorigdst "$PUBLIC_IPV4" --ctorigdstport 65173 \
        -j RETURN

    "$bin" -w 5 -A "$staging_chain" \
        -i "$WAN4_IF" -p udp \
        -m conntrack --ctstate NEW \
        --ctorigdst "$PUBLIC_IPV4" --ctorigdstport 65171 \
        -j RETURN

    "$bin" -w 5 -A "$staging_chain" -i "$WAN4_IF" -j DROP

    "$bin" -w 5 -A "$staging_chain" -j RETURN
    activate_staging_chain "$bin" "$staging_chain"
}

apply_ipv6() {
    local bin="$1" staging_chain=""
    wait_for_docker_user "$bin" || {
        echo "HATA: IPv6 DOCKER-USER zinciri bulunamadı." >&2
        return 1
    }

    staging_chain="$(create_staging_chain "$bin")"
    "$bin" -w 5 -A "$staging_chain" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    if [[ -n "$WAN6_IF" ]]; then
        "$bin" -w 5 -A "$staging_chain" \
            -i "$TS_IF" -o "$WAN6_IF" -j ACCEPT
    fi

    "$bin" -w 5 -A "$staging_chain" -o "$TS_IF" -j DROP

    if [[ -n "$WAN6_IF" ]]; then
        "$bin" -w 5 -A "$staging_chain" -i "$WAN6_IF" -j DROP
    fi

    "$bin" -w 5 -A "$staging_chain" -j RETURN
    activate_staging_chain "$bin" "$staging_chain"
}

chain_rules_exact() {
    local bin="$1" table="$2" chain="$3" actual="" expected=""
    local -a table_args=()
    shift 3

    [[ "$table" == "filter" ]] || table_args=(-t "$table")
    actual="$(
        "$bin" -w 5 "${table_args[@]}" -S "$chain" 2>/dev/null |
            "$AWK_BIN" '$1 == "-A" {print}' || true
    )"
    expected="$(printf '%s\n' "$@")"
    [[ "$actual" == "$expected" ]]
}

jump_is_first_and_single() {
    local bin="$1" table="$2" parent="$3" target="$4"
    local rules="" first="" count=0 expected=""
    local -a table_args=()

    [[ "$table" == "filter" ]] || table_args=(-t "$table")
    rules="$("$bin" -w 5 "${table_args[@]}" -S "$parent" 2>/dev/null || true)"
    expected="-A $parent -j $target"
    first="$("$AWK_BIN" '$1 == "-A" {print; exit}' <<<"$rules")"
    count="$("$AWK_BIN" -v expected="$expected" \
        '$0 == expected {count++} END {print count+0}' <<<"$rules")"
    [[ "$first" == "$expected" && "$count" -eq 1 ]]
}

forward_prefix_is_exact() {
    local bin="$1" rules="" leading=""
    rules="$("$bin" -w 5 -S FORWARD 2>/dev/null || true)"
    leading="$(
        "$AWK_BIN" '$1 == "-A" {print; count++; if (count == 3) exit}' \
            <<<"$rules"
    )"
    [[ "$leading" == $'-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j ts-forward' ]] ||
        return 1
    for target in DOCKER-USER DOCKER-FORWARD ts-forward; do
        [[ "$(grep -Fxc -- "-A FORWARD -j $target" <<<"$rules")" == "1" ]] ||
            return 1
    done
}

docker_forward_has_no_terminal_drop() {
    local bin="$1" rules=""
    rules="$("$bin" -w 5 -S DOCKER-FORWARD 2>/dev/null || true)"
    [[ -n "$rules" ]] &&
        ! "$AWK_BIN" '$1 == "-A" && / -j (DROP|REJECT)( |$)/ {
            found=1
        } END {exit found ? 0 : 1}' <<<"$rules"
}

no_stale_staging_chains() {
    local bin="$1" table="$2" rules=""
    local -a table_args=()

    [[ "$table" == "filter" ]] || table_args=(-t "$table")
    rules="$("$bin" -w 5 "${table_args[@]}" -S 2>/dev/null || true)"
    ! "$AWK_BIN" '$1 == "-N" &&
        ($2 ~ /^MASTER-NEXT-/ || $2 ~ /^MASTER-TS-NEXT-/) {found=1}
        END {exit(found ? 0 : 1)}' <<<"$rules"
}

check_ipv4_policy() {
    local -a ts_rules=(
        "-A $TS_GUARD_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        "-A $TS_GUARD_CHAIN -i $TS_IF -o $WAN4_IF -j MARK --set-xmark 0x40000/0xff0000"
        "-A $TS_GUARD_CHAIN -i $TS_IF -o $WAN4_IF -j ACCEPT"
        "-A $TS_GUARD_CHAIN -i $TS_IF -j DROP"
        "-A $TS_GUARD_CHAIN -o $TS_IF -j DROP"
        "-A $TS_GUARD_CHAIN -j RETURN"
    )
    local -a docker_rules=(
        "-A $POLICY_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
        "-A $POLICY_CHAIN -i $TS_IF -o $WAN4_IF -j ACCEPT"
        "-A $POLICY_CHAIN -o $TS_IF -j DROP"
        "-A $POLICY_CHAIN -i $WAN4_IF -p tcp -m conntrack --ctstate NEW --ctorigdst $PUBLIC_IPV4 --ctorigdstport 65173 -j RETURN"
        "-A $POLICY_CHAIN -i $WAN4_IF -p udp -m conntrack --ctstate NEW --ctorigdst $PUBLIC_IPV4 --ctorigdstport 65173 -j RETURN"
        "-A $POLICY_CHAIN -i $WAN4_IF -p udp -m conntrack --ctstate NEW --ctorigdst $PUBLIC_IPV4 --ctorigdstport 65171 -j RETURN"
        "-A $POLICY_CHAIN -i $WAN4_IF -j DROP"
        "-A $POLICY_CHAIN -j RETURN"
    )

    jump_is_first_and_single \
        "$IPTABLES_BIN" mangle FORWARD "$TS_GUARD_CHAIN" &&
        forward_prefix_is_exact "$IPTABLES_BIN" &&
        docker_forward_has_no_terminal_drop "$IPTABLES_BIN" &&
        jump_is_first_and_single \
            "$IPTABLES_BIN" filter DOCKER-USER "$POLICY_CHAIN" &&
        chain_rules_exact \
            "$IPTABLES_BIN" filter DOCKER-USER \
            "-A DOCKER-USER -j $POLICY_CHAIN" &&
        chain_rules_exact \
            "$IPTABLES_BIN" mangle "$TS_GUARD_CHAIN" "${ts_rules[@]}" &&
        chain_rules_exact \
            "$IPTABLES_BIN" filter "$POLICY_CHAIN" "${docker_rules[@]}" &&
        ! "$IPTABLES_BIN" -w 5 -C DOCKER-USER \
            -i "$TS_IF" -j RETURN 2>/dev/null &&
        ! "$IPTABLES_BIN" -w 5 -C DOCKER-USER \
            -o "$TS_IF" -j RETURN 2>/dev/null &&
        no_stale_staging_chains "$IPTABLES_BIN" mangle &&
        no_stale_staging_chains "$IPTABLES_BIN" filter
}

check_ipv6_policy() {
    local -a ts_rules=(
        "-A $TS_GUARD_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    )
    local -a docker_rules=(
        "-A $POLICY_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    )

    if [[ -z "$IP6TABLES_BIN" ]]; then
        echo "HATA: ip6tables bulunamadı; IPv6 firewall politikası doğrulanamıyor." >&2
        return 1
    fi
    if [[ -n "$WAN6_IF" ]]; then
        ts_rules+=(
            "-A $TS_GUARD_CHAIN -i $TS_IF -o $WAN6_IF -j MARK --set-xmark 0x40000/0xff0000"
            "-A $TS_GUARD_CHAIN -i $TS_IF -o $WAN6_IF -j ACCEPT"
        )
        docker_rules+=("-A $POLICY_CHAIN -i $TS_IF -o $WAN6_IF -j ACCEPT")
    fi
    ts_rules+=(
        "-A $TS_GUARD_CHAIN -i $TS_IF -j DROP"
        "-A $TS_GUARD_CHAIN -o $TS_IF -j DROP"
        "-A $TS_GUARD_CHAIN -j RETURN"
    )
    docker_rules+=("-A $POLICY_CHAIN -o $TS_IF -j DROP")
    if [[ -n "$WAN6_IF" ]]; then
        docker_rules+=("-A $POLICY_CHAIN -i $WAN6_IF -j DROP")
    fi
    docker_rules+=("-A $POLICY_CHAIN -j RETURN")

    jump_is_first_and_single \
        "$IP6TABLES_BIN" mangle FORWARD "$TS_GUARD_CHAIN" &&
        forward_prefix_is_exact "$IP6TABLES_BIN" &&
        docker_forward_has_no_terminal_drop "$IP6TABLES_BIN" &&
        jump_is_first_and_single \
            "$IP6TABLES_BIN" filter DOCKER-USER "$POLICY_CHAIN" &&
        chain_rules_exact \
            "$IP6TABLES_BIN" filter DOCKER-USER \
            "-A DOCKER-USER -j $POLICY_CHAIN" &&
        chain_rules_exact \
            "$IP6TABLES_BIN" mangle "$TS_GUARD_CHAIN" "${ts_rules[@]}" &&
        chain_rules_exact \
            "$IP6TABLES_BIN" filter "$POLICY_CHAIN" "${docker_rules[@]}" &&
        ! "$IP6TABLES_BIN" -w 5 -C DOCKER-USER \
            -i "$TS_IF" -j RETURN 2>/dev/null &&
        ! "$IP6TABLES_BIN" -w 5 -C DOCKER-USER \
            -o "$TS_IF" -j RETURN 2>/dev/null &&
        no_stale_staging_chains "$IP6TABLES_BIN" mangle &&
        no_stale_staging_chains "$IP6TABLES_BIN" filter
}

check_policy() {
    check_ipv4_policy && check_ipv6_policy
}

if [[ "$MODE" == "--check" ]]; then
    if check_policy; then
        echo "Docker-Tailscale firewall politikası tam ve sıralı."
        exit 0
    fi
    echo "HATA: Docker-Tailscale firewall politikası sapmış." >&2
    exit 1
fi

ensure_forward_prefix "$IPTABLES_BIN"
ensure_forward_prefix "$IP6TABLES_BIN"
apply_tailnet_guard "$IPTABLES_BIN" "$WAN4_IF" 4
apply_tailnet_guard "$IP6TABLES_BIN" "$WAN6_IF" 6
apply_ipv4 "$IPTABLES_BIN"
apply_ipv6 "$IP6TABLES_BIN"

if ! check_policy; then
    echo "HATA: Firewall politikası uygulama sonrası doğrulanamadı." >&2
    exit 1
fi

echo "Docker-Tailscale firewall politikası uygulandı."
echo "IPv4 WAN: $WAN4_IF ($PUBLIC_IPV4), IPv6 WAN: ${WAN6_IF:-yok}"
FW_SCRIPT
chmod 0755 /usr/local/sbin/docker-tailscale-fw

cat >/etc/systemd/system/docker-tailscale-fw.service <<'FW_SYSTEMD'
[Unit]
Description=Restrict Docker forwarding while preserving Tailscale exit-node traffic
Requires=docker.service tailscaled.service
Wants=network-online.target
After=network-online.target tailscaled.service docker.service
PartOf=docker.service tailscaled.service
OnFailure=master-network-reconcile.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-tailscale-fw
RemainAfterExit=yes
Restart=no
TimeoutStartSec=600s

[Install]
WantedBy=multi-user.target
FW_SYSTEMD
set_unit_file_mode /etc/systemd/system/docker-tailscale-fw.service

install -d -m 0755 /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/99-tailscale-forward.conf <<DROPIN
[Unit]
Wants=network-online.target docker-tailscale-fw.service master-compose.service
After=network-online.target
RequiresMountsFor=$DOWNLOADS_PATH
DROPIN
set_unit_file_mode /etc/systemd/system/docker.service.d/99-tailscale-forward.conf

install -d -m 0755 /etc/systemd/system/tailscaled.service.d
cat >/etc/systemd/system/tailscaled.service.d/98-master-stack.conf <<'TS_STACK_DROPIN'
[Unit]
Wants=docker-tailscale-fw.service master-compose.service master-webdav.service
Before=docker-tailscale-fw.service master-compose.service master-webdav.service
TS_STACK_DROPIN
set_unit_file_mode /etc/systemd/system/tailscaled.service.d/98-master-stack.conf

systemctl daemon-reload
systemctl enable docker-tailscale-fw.service

progress_stage_note 95 "Docker ve firewall unit tanımları doğrulanıyor"
echo "Docker: $(docker version --format '{{.Server.Version}}')"

progress_stage_done
progress_stage_begin 4 "Dizinler, Compose ve reconcile tanımları yazılıyor"

install -d -m 0700 -o root -g root /data/portainer/data
install -d -m 0750 -o 1000 -g 1000 /data/qbittorrent/appdata
install -d -m 0700 -o root -g root /data/wg-easy/config

for wg_module in wireguard ip6_tables ip6table_nat; do
    if ! modprobe "$wg_module" 2>/tmp/modprobe-wg.err; then
        echo "UYARI: 'modprobe $wg_module' başarısız oldu:" >&2
        cat /tmp/modprobe-wg.err >&2 || true
    fi
    rm -f /tmp/modprobe-wg.err
done

cat >/etc/modules-load.d/wg-easy.conf <<'MODULES_EOF'
wireguard
ip6_tables
ip6table_nat
MODULES_EOF
chown root:root /etc/modules-load.d/wg-easy.conf
chmod 0644 /etc/modules-load.d/wg-easy.conf

if ip link add wg-easy-probe0 type wireguard 2>/dev/null; then
    ip link del wg-easy-probe0
else
    echo "UYARI: Host çekirdeği WireGuard arayüzü oluşturamıyor; wg-easy başlatılamayabilir." >&2
fi
install -d -m 0750 -o 1000 -g 1000 \
    "$DOWNLOADS_PATH/media" \
    "$DOWNLOADS_PATH/media/movies" \
    "$DOWNLOADS_PATH/media/series" \
    "$DOWNLOADS_PATH/media/.unpackerr"
install -d -m 0700 -o root -g root /root/docker
install -d -m 0700 -o root -g root /etc/master-stack
install -d -m 0755 -o root -g root /usr/local/share/master-stack

MEDIA_GROUP="$(getent group 1000 | cut -d: -f1 || true)"
if [[ -z "$MEDIA_GROUP" ]]; then
    groupadd -g 1000 mediadata
    MEDIA_GROUP="mediadata"
fi
if ! id -u master-webdav >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --no-create-home \
        --shell /usr/sbin/nologin master-webdav
fi
usermod -aG "$MEDIA_GROUP" master-webdav

WG_ENDPOINT_HOST_FOR_STATE="$PUBLIC_IPV4"

cat >/etc/master-stack/state.env <<EOF
STACK_SCHEMA=10
STACK_VERSION=$MASTER_SETUP_VERSION
STACK_SHA256=$MASTER_SETUP_SHA256
LOCAL_DOMAIN=$LOCAL_DOMAIN
QBIT_PUBLIC_PORT=$QBIT_PUBLIC_PORT
WG_PUBLIC_PORT=$WG_PUBLIC_PORT
WEBDAV_PORT=$WEBDAV_PORT
WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST_FOR_STATE
DOWNLOADS_PATH=$DOWNLOADS_PATH
EOF
chown root:root /etc/master-stack/state.env
chmod 0600 /etc/master-stack/state.env

if [[ "$WEBDAV_SETUP_CREDENTIALS" -eq 1 ]]; then
    WEBDAV_HTPASSWD_TMP="$(mktemp /etc/master-stack/.webdav.htpasswd.XXXXXX)"
    printf '%s' "$WEBDAV_PASSWORD" |
        htpasswd -i -B "$WEBDAV_HTPASSWD_TMP" "$WEBDAV_USER"
    unset WEBDAV_PASSWORD
    chown root:root "$WEBDAV_HTPASSWD_TMP"
    chmod 0600 "$WEBDAV_HTPASSWD_TMP"
    mv -f "$WEBDAV_HTPASSWD_TMP" "$WEBDAV_HTPASSWD_FILE"
fi

QUANTUM_CONFIG_TMP="$(mktemp /etc/master-stack/.filebrowser.yaml.XXXXXX)"
cat >"$QUANTUM_CONFIG_TMP" <<'QUANTUM_YAML'
server:
  port: 80
  baseURL: "/"
  cacheDir: "/home/filebrowser/data/cache"
  sources:
    - path: "/srv"
auth:
  methods:
    password:
      enabled: true
      minLength: 5
      signup: false
    passkey:
      enabled: false
QUANTUM_YAML
chown root:root "$QUANTUM_CONFIG_TMP"
chmod 0644 "$QUANTUM_CONFIG_TMP"
QUANTUM_CONFIG_RECREATE_REQUIRED=0
if [[ -f "$QUANTUM_CONFIG_FILE" &&
      ! -L "$QUANTUM_CONFIG_FILE" ]] &&
   cmp -s "$QUANTUM_CONFIG_TMP" "$QUANTUM_CONFIG_FILE" &&
   [[ "$(stat -c '%u:%g:%a' "$QUANTUM_CONFIG_FILE" 2>/dev/null || true)" == "0:0:644" ]]; then
    rm -f "$QUANTUM_CONFIG_TMP"
else
    QUANTUM_CONFIG_RECREATE_REQUIRED=1
    if [[ -L "$QUANTUM_CONFIG_FILE" ||
          ( -e "$QUANTUM_CONFIG_FILE" &&
            ! -f "$QUANTUM_CONFIG_FILE" ) ]]; then
        echo "NOT: ${QUANTUM_CONFIG_FILE} normal dosya değil; temizlenip" >&2
        echo "dosya olarak yeniden yazılacak." >&2
        rm -rf -- "$QUANTUM_CONFIG_FILE"
    fi
    mv -f "$QUANTUM_CONFIG_TMP" "$QUANTUM_CONFIG_FILE"
fi

find "$DOWNLOADS_PATH/media" \
    \( ! -uid 1000 -o ! -gid 1000 \) \
    -exec chown 1000:1000 {} +
progress_stage_note 15 "Veri ve medya dizinleri hazırlandı"

PORTAINER_TRUSTED_ORIGINS="portainer.${LOCAL_DOMAIN}"

cat >/root/docker/compose.yaml <<YAML_EOF
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  portainer:
    image: ${PORTAINER_IMAGE}
    container_name: portainer
    restart: unless-stopped
    logging: *default-logging
    environment:
      TRUSTED_ORIGINS: "${PORTAINER_TRUSTED_ORIGINS}"
    ports:
      - "127.0.0.1:9443:9443/tcp"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /data/portainer/data:/data

  filebrowser:
    image: ${FILEBROWSER_IMAGE}
    container_name: filebrowser
    restart: unless-stopped
    logging: *default-logging
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    environment:
      FILEBROWSER_CONFIG: /config.yaml
      FILEBROWSER_DATABASE: /home/filebrowser/data/database.db
    ports:
      - "127.0.0.1:7113:80/tcp"
    volumes:
      - ${DOWNLOADS_PATH}/media:/srv
      - ${QUANTUM_CONFIG_FILE}:/config.yaml:ro
      - filebrowser_data:/home/filebrowser/data

  qbittorrent:
    image: ${QBITTORRENT_IMAGE}
    container_name: qbittorrent
    restart: unless-stopped
    logging: *default-logging
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - FOWNER
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "${TIMEZONE}"
      WEBUI_PORT: "13087"
      TORRENTING_PORT: "${QBIT_PUBLIC_PORT}"
    ports:
      - "127.0.0.1:13087:13087/tcp"
      - "\${PUBLIC_IPV4}:${QBIT_PUBLIC_PORT}:${QBIT_PUBLIC_PORT}/tcp"
      - "\${PUBLIC_IPV4}:${QBIT_PUBLIC_PORT}:${QBIT_PUBLIC_PORT}/udp"
    volumes:
      - /data/qbittorrent/appdata:/config
      - ${DOWNLOADS_PATH}/media:/downloads
    stop_grace_period: 10s

  unpackerr:
    image: ${UNPACKERR_IMAGE}
    container_name: unpackerr
    user: "1000:1000"
    restart: unless-stopped
    logging: *default-logging
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    mem_limit: 512m
    cpus: 1.0
    environment:
      TZ: "${TIMEZONE}"
      UN_LOG_FILE: "/downloads/.unpackerr/unpackerr.log"
      UN_LOG_FILE_MB: "10"
      UN_LOG_FILES: "3"
      UN_LOG_QUEUES: "30m"
      UN_FOLDERS_INTERVAL: "10s"
      UN_FOLDER_0_PATH: "/downloads"
      UN_FOLDER_0_EXTRACT_PATH: ""
      UN_FOLDER_0_DELETE_AFTER: "0"
      UN_FOLDER_0_DISABLE_RECURSION: "false"
      UN_FOLDER_0_DELETE_FILES: "false"
      UN_FOLDER_0_DELETE_ORIGINAL: "false"
      UN_FOLDER_0_DISABLE_LOG: "false"
      UN_FOLDER_0_MOVE_BACK: "true"
      UN_FOLDER_0_EXTRACT_ISOS: "false"
    volumes:
      - ${DOWNLOADS_PATH}/media:/downloads
    stop_grace_period: 30s

  wg-easy:
    image: ${WG_EASY_IMAGE}
    container_name: wg-easy
    restart: unless-stopped
    logging: *default-logging
    healthcheck:
      test:
        - CMD-SHELL
        - '/usr/bin/timeout 5s /bin/sh -c "/usr/bin/wg show | /bin/grep -q interface"'
      interval: 60s
      timeout: 5s
      retries: 3
      start_period: 60s
      start_interval: 5s
    environment:
      INSECURE: "true"
    ports:
      - "\${PUBLIC_IPV4}:${WG_PUBLIC_PORT}:${WG_PUBLIC_PORT}/udp"
      - "127.0.0.1:51821:51821/tcp"
    volumes:
      - /data/wg-easy/config:/etc/wireguard
    cap_add:
      - NET_ADMIN
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.src_valid_mark: "1"
      net.ipv6.conf.all.disable_ipv6: "0"
      net.ipv6.conf.all.forwarding: "1"
      net.ipv6.conf.default.forwarding: "1"
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a

networks:
  wg:
    name: wg
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64

volumes:
  filebrowser_data:
    name: filebrowser_data
YAML_EOF

chown root:root /root/docker/compose.yaml
chmod 0600 /root/docker/compose.yaml
progress_stage_note 45 "Beş container için Compose tanımı yazıldı"

cat >/root/docker/.env <<EOF
PUBLIC_IPV4=$PUBLIC_IPV4
TAILSCALE_IPV4=$TS_IP
EOF
chown root:root /root/docker/.env
chmod 0600 /root/docker/.env

cat >/usr/local/sbin/master-compose-ipv4 <<'IP_REFRESH_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

IP_BIN="$(command -v ip)"
AWK_BIN="$(command -v awk)"
STACK_DIR="/root/docker"
ENV_FILE="$STACK_DIR/.env"

for _ in $(seq 1 120); do
    ROUTE_LINE="$($IP_BIN -4 -o route get 1.1.1.1 2>/dev/null || true)"
    WAN4_IF="$($AWK_BIN '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$ROUTE_LINE")"
    PUBLIC_IPV4="$($AWK_BIN '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<<"$ROUTE_LINE")"
    TAILSCALE_IPV4="$(
        "$IP_BIN" -4 -o addr show dev tailscale0 scope global 2>/dev/null |
            "$AWK_BIN" 'NR == 1 {sub(/\/.*/, "", $4); print $4}' || true
    )"

    if [[ -n "$WAN4_IF" &&
          "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
          "$TAILSCALE_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
       "$IP_BIN" -4 -o addr show dev "$WAN4_IF" |
           "$AWK_BIN" '{print $4}' | cut -d/ -f1 | grep -Fx "$PUBLIC_IPV4" >/dev/null; then
        TMP_FILE="$(mktemp "$STACK_DIR/.env.XXXXXX")"
        {
            printf 'PUBLIC_IPV4=%s\n' "$PUBLIC_IPV4"
            printf 'TAILSCALE_IPV4=%s\n' "$TAILSCALE_IPV4"
        } >"$TMP_FILE"
        chmod 0600 "$TMP_FILE"
        mv -f "$TMP_FILE" "$ENV_FILE"
        echo "Compose public IPv4 güncellendi: $WAN4_IF ($PUBLIC_IPV4)"
        echo "Compose Tailscale IPv4 güncellendi: $TAILSCALE_IPV4"
        exit 0
    fi

    sleep 1
done

echo "HATA: Compose için WAN ve Tailscale IPv4 120 saniyede hazır olmadı." >&2
exit 1
IP_REFRESH_SCRIPT
chmod 0755 /usr/local/sbin/master-compose-ipv4
progress_stage_note 60 "Dinamik IPv4 ve Tailscale binding helper'ı yazıldı"

cat >/etc/systemd/system/master-compose.service <<COMPOSE_SYSTEMD
[Unit]
Description=Start and reconcile the master Docker Compose stack after WAN and Tailscale IPv4 are ready
Requires=docker.service docker-tailscale-fw.service tailscaled.service
Wants=network-online.target
After=network-online.target tailscaled.service docker.service docker-tailscale-fw.service
PartOf=docker.service tailscaled.service
OnFailure=master-network-reconcile.service
StartLimitIntervalSec=60
StartLimitBurst=10
RequiresMountsFor=$DOWNLOADS_PATH

[Service]
Type=oneshot
WorkingDirectory=/root/docker
ExecStartPre=/usr/local/sbin/master-compose-ipv4
ExecStart=/usr/bin/docker compose --env-file /root/docker/.env -f /root/docker/compose.yaml up -d --remove-orphans --wait --wait-timeout 180
RemainAfterExit=yes
Restart=no
TimeoutStartSec=330

[Install]
WantedBy=multi-user.target
COMPOSE_SYSTEMD
set_unit_file_mode /etc/systemd/system/master-compose.service

cat >/usr/local/sbin/master-network-reconcile <<'RECONCILE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

IP_BIN="$(command -v ip)"
AWK_BIN="$(command -v awk)"
SYSTEMCTL_BIN="$(command -v systemctl)"
SYSCTL_BIN="$(command -v sysctl)"
IPTABLES_BIN="$(command -v iptables)"
IP6TABLES_BIN="$(command -v ip6tables || true)"
FLOCK_BIN="$(command -v flock)"
DOCKER_BIN="$(command -v docker)"
TAILSCALE_BIN="$(command -v tailscale)"
JQ_BIN="$(command -v jq)"
CURL_BIN="$(command -v curl)"
INSTALL_BIN="$(command -v install)"
CMP_BIN="$(command -v cmp)"
SHA256SUM_BIN="$(command -v sha256sum)"
READLINK_BIN="$(command -v readlink)"
SS_BIN="$(command -v ss)"
STAT_BIN="$(command -v stat)"
DF_BIN="$(command -v df)"
ETHTOOL_BIN="$(command -v ethtool || true)"
ENV_FILE="/root/docker/.env"
COMPOSE_FILE="/root/docker/compose.yaml"
STATE_FILE="/etc/master-stack/state.env"
QUANTUM_CONFIG_FILE="/etc/master-stack/filebrowser.yaml"
CANONICAL_ROOT="/usr/local/share/master-stack"
select_canonical_dir() {
    CANONICAL_DIR="$CANONICAL_ROOT/current"
    if [[ ! -L "$CANONICAL_DIR" &&
          -r "$CANONICAL_ROOT/SHA256SUMS" ]]; then
        CANONICAL_DIR="$CANONICAL_ROOT"
    fi
}
select_canonical_dir
FW_HELPER="/usr/local/sbin/docker-tailscale-fw"
CORE_RECOVERY_UNIT="master-docker-netfilter-recovery.service"
RESTART_STATE_DIR="/run/master-network-reconcile"
QUANTUM_RESTART_PENDING_FILE="$RESTART_STATE_DIR/filebrowser-config.pending"
FILEBROWSER_AUDIT_STAMP="$RESTART_STATE_DIR/filebrowser-password-audit.last"
DISK_USAGE_THRESHOLD_PCT=90
RESTART_COOLDOWN_SECONDS=900
FILEBROWSER_AUDIT_INTERVAL_SECONDS=86400
ADDRESS_READY_WAIT_SECONDS=30
MODE="${1:-reconcile}"

case "$MODE" in
    reconcile|--check|--status)
        ;;
    *)
        echo "HATA: Kullanım: master-network-reconcile [--check|--status]" >&2
        exit 2
        ;;
esac

state_value() {
    local key="$1" default_value="$2" value=""
    local state_source="$STATE_FILE"
    if [[ -r "$CANONICAL_DIR/state.env" ]]; then
        state_source="$CANONICAL_DIR/state.env"
    fi
    if [[ -r "$state_source" ]]; then
        value="$(
            "$AWK_BIN" -F= -v key="$key" \
                '$1 == key {print substr($0, index($0, "=") + 1); exit}' \
                "$state_source"
        )"
    fi
    printf '%s\n' "${value:-$default_value}"
}

defer_transient() {
    local check_rc="$1"
    shift
    if [[ "$MODE" == "--check" ]]; then
        echo "HATA: $*" >&2
        exit "$check_rc"
    fi
    echo "$*"
    exit 0
}

fail_unhealthy() {
    echo "HATA: $*" >&2
    exit 1
}

report_tailscale_diagnostics() {
    local status_json="" backend="bilinmiyor" online="bilinmiyor"
    local health="okunamadı" key_expiry="bilinmiyor"

    status_json="$("$TAILSCALE_BIN" status --json 2>/dev/null || true)"
    if "$JQ_BIN" -e 'type == "object"' >/dev/null 2>&1 <<<"$status_json"; then
        backend="$(
            "$JQ_BIN" -r '.BackendState // "bilinmiyor"' \
                <<<"$status_json" || printf 'bilinmiyor\n'
        )"
        online="$(
            "$JQ_BIN" -r \
                'if .Self.Online == true then "true" elif .Self.Online == false then "false" else "bilinmiyor" end' \
                <<<"$status_json" || printf 'bilinmiyor\n'
        )"
        health="$(
            "$JQ_BIN" -r \
                '(.Health // []) | if type != "array" then tostring elif length == 0 then "yok" else map(tostring) | join(" | ") end' \
                <<<"$status_json" || printf 'okunamadı\n'
        )"
        key_expiry="$(
            "$JQ_BIN" -r '.Self.KeyExpiry // "bilinmiyor"' \
                <<<"$status_json" || printf 'bilinmiyor\n'
        )"
    fi

    echo "Tailscale teşhisi: BackendState=$backend Self.Online=$online KeyExpiry=$key_expiry" >&2
    echo "Tailscale health: $health" >&2
}

owned_file_ok() {
    local path="$1" expected_uid="$2" expected_gid="$3" expected_mode="$4"
    local actual=""
    actual="$("$STAT_BIN" -c '%u:%g:%a' "$path" 2>/dev/null || true)"
    [[ -e "$path" &&
       "$actual" == "$expected_uid:$expected_gid:$expected_mode" ]]
}

canonical_bundle_ok() {
    local manifest_entries="" expected_entries=""
    local canonical_target="$CANONICAL_DIR" canonical_root_target=""

    if [[ "$CANONICAL_DIR" != "$CANONICAL_ROOT" ]]; then
        [[ -L "$CANONICAL_DIR" ]] || return 1
        canonical_root_target="$(
            "$READLINK_BIN" -f -- "$CANONICAL_ROOT" 2>/dev/null || true
        )"
        canonical_target="$(
            "$READLINK_BIN" -f -- "$CANONICAL_DIR" 2>/dev/null || true
        )"
        [[ -n "$canonical_root_target" &&
           "$canonical_target" == "$canonical_root_target"/.generation.* &&
           -d "$canonical_target" ]] || return 1
    fi

    [[ -r "$CANONICAL_DIR/SHA256SUMS" ]] &&
        (cd "$CANONICAL_DIR" &&
            "$SHA256SUM_BIN" -c --status SHA256SUMS) ||
        return 1
    owned_file_ok "$canonical_target" 0 0 755 &&
        owned_file_ok "$CANONICAL_DIR/SHA256SUMS" 0 0 644 &&
        owned_file_ok "$CANONICAL_DIR/state.env" 0 0 600 &&
        owned_file_ok "$CANONICAL_DIR/compose.yaml" 0 0 600 &&
        owned_file_ok "$CANONICAL_DIR/filebrowser.yaml" 0 0 644 ||
        return 1

    manifest_entries="$(
        "$AWK_BIN" 'NF == 2 {print $2}' "$CANONICAL_DIR/SHA256SUMS"
    )"
    expected_entries=$'state.env\ncompose.yaml\nfilebrowser.yaml\ndnsmasq-local-services.conf\ndnsmasq-99-tailscale-order.conf\nCaddyfile\ncaddy-99-tailnet-bind.conf\ncaddy-tailnet-env\ntailscaled-99-caddy-tailnet.conf'
    [[ "$manifest_entries" == "$expected_entries" ]] || return 1

    owned_file_ok "$CANONICAL_DIR/dnsmasq-local-services.conf" 0 0 644 &&
        owned_file_ok "$CANONICAL_DIR/dnsmasq-99-tailscale-order.conf" 0 0 644 &&
        owned_file_ok "$CANONICAL_DIR/Caddyfile" 0 0 644 &&
        owned_file_ok "$CANONICAL_DIR/caddy-99-tailnet-bind.conf" 0 0 644 &&
        owned_file_ok "$CANONICAL_DIR/caddy-tailnet-env" 0 0 755 &&
        owned_file_ok "$CANONICAL_DIR/tailscaled-99-caddy-tailnet.conf" 0 0 644
}

if [[ "$MODE" == "--status" ]]; then
    status_check_rc=0
    status_check_output="$("$0" --check 2>&1)" || status_check_rc=$?
    status_downloads_path="$(state_value DOWNLOADS_PATH /downloads)"

    echo "=== Master Stack durum özeti ==="
    echo "Kurulum sürümü : $(state_value STACK_VERSION bilinmiyor)"
    echo "Betik SHA256   : $(state_value STACK_SHA256 bilinmiyor)"
    echo "Durum şeması   : $(state_value STACK_SCHEMA bilinmiyor)"
    echo
    echo "Container durumları:"
    for status_container in \
        filebrowser portainer qbittorrent unpackerr wg-easy; do
        status_container_state="$(
            "$DOCKER_BIN" inspect -f \
                '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' \
                "$status_container" 2>/dev/null || echo "yok"
        )"
        status_image_id="$(
            "$DOCKER_BIN" inspect -f '{{.Image}}' \
                "$status_container" 2>/dev/null || true
        )"
        status_running_digest=""
        if [[ -n "$status_image_id" ]]; then
            status_running_digest="$(
                "$DOCKER_BIN" image inspect -f \
                    '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
                    "$status_image_id" 2>/dev/null || true
            )"
            status_running_digest="${status_running_digest#*@}"
        fi
        status_recorded_digest="$(
            state_value \
                "IMAGE_DIGEST_$(
                    printf '%s' "$status_container" | tr 'a-z-' 'A-Z_'
                )" ""
        )"
        status_digest_note=""
        if [[ -n "$status_running_digest" ]]; then
            status_digest_note="  ${status_running_digest:7:12}"
            [[ "$status_running_digest" == "$status_recorded_digest" ]] ||
                status_digest_note+=" (kayıtla ayrışmış)"
        fi
        printf '  %-12s %s%s\n' \
            "$status_container" "$status_container_state" "$status_digest_note"
    done
    printf '  %-12s %s (host servisi)\n' "webdav" "$(
        "$SYSTEMCTL_BIN" is-active master-webdav.service 2>/dev/null || true
    )"
    echo
    status_failed_units="$(
        "$SYSTEMCTL_BIN" --failed --no-legend --plain 2>/dev/null |
            "$AWK_BIN" '{print "  " $1}' || true
    )"
    if [[ -n "$status_failed_units" ]]; then
        echo "Başarısız systemd unit'leri:"
        printf '%s\n' "$status_failed_units"
    else
        echo "Başarısız systemd unit yok."
    fi
    echo
    status_disk_line="$(
        "$DF_BIN" -h --output=pcent,avail,ipcent,target \
            "$status_downloads_path" 2>/dev/null |
            "$AWK_BIN" 'NR == 2 {
                print "kullanım " $1 ", boş " $2 ", inode " $3 " (" $4 ")"
            }' || true
    )"
    echo "İndirme diski  : ${status_disk_line:-okunamadı}"
    echo
    status_stamps_found=0
    for status_stamp_file in "$RESTART_STATE_DIR"/*.last-restart; do
        [[ -r "$status_stamp_file" ]] || continue
        status_stamp_epoch=""
        read -r status_stamp_epoch <"$status_stamp_file" ||
            status_stamp_epoch=""
        [[ "$status_stamp_epoch" =~ ^[0-9]+$ ]] || continue
        if [[ "$status_stamps_found" -eq 0 ]]; then
            echo "Son onarım damgaları (yeniden başlatmada sıfırlanır):"
            status_stamps_found=1
        fi
        status_stamp_name="${status_stamp_file##*/}"
        printf '  %-12s %s\n' "${status_stamp_name%.last-restart}" \
            "$(date -d "@$status_stamp_epoch" '+%Y-%m-%d %H:%M:%S')"
    done
    if [[ "$status_stamps_found" -eq 0 ]]; then
        echo "Son yeniden başlatmadan beri onarım damgası yok."
    fi
    echo
    echo "Reconcile --check sonucu (rc=$status_check_rc):"
    printf '%s\n' "$status_check_output" | "$AWK_BIN" '{print "  " $0}'
    exit "$status_check_rc"
fi

if [[ "${MASTER_STACK_LOCK_HELD:-0}" != "1" ]]; then
    exec 8>/run/lock/master-stack.lock
    if ! "$FLOCK_BIN" -n 8; then
        defer_transient 75 \
            "Başka bir stack transaction'ı aktif; reconcile kontrolü ertelendi."
    fi
fi

CANONICAL_BUNDLE_INVALID=0
if ! canonical_bundle_ok; then
    CANONICAL_BUNDLE_INVALID=1
    echo "HATA: Canonical master-stack bundle doğrulaması başarısız; canonical kopyadan geri yükleme yapılmayacak, çalışan servisler korunacak." >&2
fi

STACK_SCHEMA="$(state_value STACK_SCHEMA 0)"
LOCAL_DOMAIN="$(state_value LOCAL_DOMAIN "")"
QBIT_PUBLIC_PORT="$(state_value QBIT_PUBLIC_PORT 65173)"
WG_PUBLIC_PORT="$(state_value WG_PUBLIC_PORT 65171)"
WEBDAV_PORT="$(state_value WEBDAV_PORT 65113)"
WG_ENDPOINT_HOST="$(state_value WG_ENDPOINT_HOST "")"
DOWNLOADS_PATH="$(state_value DOWNLOADS_PATH "/downloads")"
if [[ "$STACK_SCHEMA" != "10" ||
      ! "$QBIT_PUBLIC_PORT" =~ ^[0-9]+$ ||
      ! "$WG_PUBLIC_PORT" =~ ^[0-9]+$ ||
      ! "$WEBDAV_PORT" =~ ^[0-9]+$ ||
      -z "$WG_ENDPOINT_HOST" ]]; then
    echo "HATA: Canonical master-stack state içeriği geçersiz." >&2
    exit 1
fi

for managed_unit in \
    docker.service \
    tailscaled.service \
    docker-tailscale-fw.service \
    master-compose.service \
    master-webdav.service \
    tailscale-udp-gro.service \
    caddy.service \
    dnsmasq.service; do
    MANAGED_LOAD_STATE="$(
        "$SYSTEMCTL_BIN" show "$managed_unit" \
            --property=LoadState --value 2>/dev/null || true
    )"
    [[ -n "$MANAGED_LOAD_STATE" && "$MANAGED_LOAD_STATE" != "not-found" ]] ||
        continue

    MANAGED_ACTIVE_STATE="$(
        "$SYSTEMCTL_BIN" show "$managed_unit" \
            --property=ActiveState --value 2>/dev/null || true
    )"
    MANAGED_JOB="$(
        "$SYSTEMCTL_BIN" show "$managed_unit" \
            --property=Job --value 2>/dev/null || true
    )"
    if [[ -n "$MANAGED_JOB" ||
          "$MANAGED_ACTIVE_STATE" == "activating" ||
          "$MANAGED_ACTIVE_STATE" == "deactivating" ||
          "$MANAGED_ACTIVE_STATE" == "reloading" ||
          "$MANAGED_ACTIVE_STATE" == "refreshing" ]]; then
        defer_transient 75 \
            "$managed_unit geçiş/job durumunda; reconcile sonraki periyoda ertelendi."
    fi
done

if ! "$SYSTEMCTL_BIN" is-active --quiet docker.service ||
   ! "$SYSTEMCTL_BIN" is-active --quiet tailscaled.service; then
    echo "Docker durumu: $("$SYSTEMCTL_BIN" is-active docker.service 2>/dev/null || true)" >&2
    echo "tailscaled durumu: $("$SYSTEMCTL_BIN" is-active tailscaled.service 2>/dev/null || true)" >&2
    report_tailscale_diagnostics
    fail_unhealthy \
        "Docker veya tailscaled aktif değil; sonraki timer'a kadar sağlıksız durum gizlenmeyecek."
fi

read_current_addresses() {
    ROUTE_LINE="$("$IP_BIN" -4 -o route get 1.1.1.1 2>/dev/null || true)"
    CURRENT_WAN4_IF="$(
        "$AWK_BIN" \
            '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' \
            <<<"$ROUTE_LINE"
    )"
    CURRENT_PUBLIC_IPV4="$(
        "$AWK_BIN" \
            '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' \
            <<<"$ROUTE_LINE"
    )"
    CURRENT_TAILSCALE_IPV4="$(
        "$IP_BIN" -4 -o addr show dev tailscale0 scope global 2>/dev/null |
            "$AWK_BIN" 'NR == 1 {sub(/\/.*/, "", $4); print $4}' || true
    )"
    CURRENT_TAILSCALE_IPV6="$(
        "$IP_BIN" -6 -o addr show dev tailscale0 scope global 2>/dev/null |
            "$AWK_BIN" 'NR == 1 {sub(/\/.*/, "", $4); print $4}' || true
    )"
}

current_addresses_ready() {
    [[ -n "$CURRENT_WAN4_IF" &&
       "$CURRENT_PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
       "$CURRENT_TAILSCALE_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

read_current_addresses

if ! current_addresses_ready; then
    for _ in $(seq 1 "$((ADDRESS_READY_WAIT_SECONDS / 2))"); do
        sleep 2
        read_current_addresses
        current_addresses_ready && break
    done
fi
if ! current_addresses_ready; then
    report_tailscale_diagnostics
    fail_unhealthy \
        "WAN veya Tailscale adresi ${ADDRESS_READY_WAIT_SECONDS} saniyede hazır olmadı; çalışan servisler değiştirilmedi."
fi

ENV_PUBLIC_IPV4=""
ENV_TAILSCALE_IPV4=""
if [[ -r "$ENV_FILE" ]]; then
    ENV_PUBLIC_IPV4="$(
        "$AWK_BIN" -F= '$1=="PUBLIC_IPV4" {
            print substr($0, index($0, "=") + 1); exit
        }' "$ENV_FILE"
    )"
    ENV_TAILSCALE_IPV4="$(
        "$AWK_BIN" -F= '$1=="TAILSCALE_IPV4" {
            print substr($0, index($0, "=") + 1); exit
        }' "$ENV_FILE"
    )"
fi

PUBLIC_ADDRESS_CHANGED=0
TAILSCALE_ADDRESS_CHANGED=0
ADDRESS_CHANGED=0
WG_ENDPOINT_DRIFTED=0
[[ "$CURRENT_PUBLIC_IPV4" == "$ENV_PUBLIC_IPV4" ]] ||
    PUBLIC_ADDRESS_CHANGED=1
[[ "$CURRENT_TAILSCALE_IPV4" == "$ENV_TAILSCALE_IPV4" ]] ||
    TAILSCALE_ADDRESS_CHANGED=1
if [[ "$PUBLIC_ADDRESS_CHANGED" -eq 1 ||
      "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ]]; then
    ADDRESS_CHANGED=1
fi
if [[ "$WG_ENDPOINT_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ &&
      "$WG_ENDPOINT_HOST" != "$CURRENT_PUBLIC_IPV4" ]]; then
    WG_ENDPOINT_DRIFTED=1
fi

disk_space_ok() {
    local path="$1" threshold="${2:-$DISK_USAGE_THRESHOLD_PCT}" usage_pct=""
    usage_pct="$(
        "$DF_BIN" --output=pcent "$path" 2>/dev/null |
            tail -n 1 | tr -dc '0-9'
    )"
    [[ -n "$usage_pct" ]] || return 1
    (( usage_pct < threshold ))
}

inode_space_ok() {
    local path="$1" threshold="${2:-$DISK_USAGE_THRESHOLD_PCT}" raw="" usage_pct=""
    raw="$(
        "$DF_BIN" --output=ipcent "$path" 2>/dev/null |
            tail -n 1 | tr -d '[:space:]'
    )"
    if [[ "$raw" == "-" ]]; then
        return 0
    fi
    usage_pct="${raw//[^0-9]/}"
    [[ -n "$usage_pct" ]] || return 1
    (( usage_pct < threshold ))
}

forwarding_ok() {
    [[ "$("$SYSCTL_BIN" -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" &&
       "$("$SYSCTL_BIN" -n net.ipv6.conf.all.forwarding 2>/dev/null || true)" == "1" ]]
}

forwarding_config_ok() {
    local managed_lines=""
    managed_lines="$(
        "$AWK_BIN" '
            /^[[:space:]]*(net\.ipv4\.ip_forward|net\.ipv6\.conf\.all\.forwarding)[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $0); print
            }
        ' /etc/sysctl.d/99-tailscale.conf 2>/dev/null || true
    )"
    [[ "$managed_lines" == $'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1' ]] &&
        owned_file_ok /etc/sysctl.d/99-tailscale.conf 0 0 644
}

tailscale_online() {
    local status_json=""
    status_json="$("$TAILSCALE_BIN" status --json 2>/dev/null || true)"
    "$JQ_BIN" -e \
        '.BackendState == "Running" and .Self.Online == true' \
        >/dev/null 2>&1 <<<"$status_json"
}

tailscale_prefs_ok() {
    local prefs_json=""
    prefs_json="$("$TAILSCALE_BIN" debug prefs 2>/dev/null || true)"
    "$JQ_BIN" -e '
        .WantRunning == true and
        .RunSSH == true and
        .NoSNAT == false and
        .NoStatefulFiltering == false and
        .NetfilterMode == 2 and
        ((.AdvertiseRoutes // []) | index("0.0.0.0/0") != null) and
        ((.AdvertiseRoutes // []) | index("::/0") != null)
    ' >/dev/null 2>&1 <<<"$prefs_json"
}

tailscale_netfilter_family_ok() {
    local bin="$1" forward_rules="" ts_rules="" nat_rules=""
    local jump_rule="-A FORWARD -j ts-forward"
    local mark_rule="-A ts-forward -i tailscale0 -j MARK --set-xmark 0x40000/0xff0000"
    local accept_rule="-A ts-forward -m mark --mark 0x40000/0xff0000 -j ACCEPT"
    local jump_pos="" first_ts_rule="" second_ts_rule=""

    forward_rules="$("$bin" -w 5 -S FORWARD 2>/dev/null || true)"
    ts_rules="$("$bin" -w 5 -S ts-forward 2>/dev/null || true)"
    nat_rules="$("$bin" -w 5 -t nat -S POSTROUTING 2>/dev/null || true)"
    [[ "$(grep -Fxc -- "$jump_rule" <<<"$forward_rules")" == "1" ]] ||
        return 1
    jump_pos="$("$AWK_BIN" -v rule="$jump_rule" '$0 == rule {print NR; exit}' \
        <<<"$forward_rules")"
    if "$AWK_BIN" -v limit="$jump_pos" \
            'NR < limit && / -j (DROP|REJECT)$/ {found=1} END {exit found ? 0 : 1}' \
            <<<"$forward_rules"; then
        return 1
    fi

    [[ "$(grep -Fxc -- "$mark_rule" <<<"$ts_rules")" == "1" &&
       "$(grep -Fxc -- "$accept_rule" <<<"$ts_rules")" == "1" ]] ||
        return 1
    first_ts_rule="$("$AWK_BIN" '$1 == "-A" {print; exit}' <<<"$ts_rules")"
    second_ts_rule="$(
        "$AWK_BIN" '$1 == "-A" {count++; if (count == 2) {print; exit}}' \
            <<<"$ts_rules"
    )"
    [[ "$first_ts_rule" == "$mark_rule" &&
       "$second_ts_rule" == "$accept_rule" ]] || return 1

    [[ "$(grep -Fxc -- '-A POSTROUTING -j ts-postrouting' \
            <<<"$nat_rules")" == "1" ]] &&
        "$bin" -w 5 -t nat -C ts-postrouting \
            -m mark --mark 0x40000/0xff0000 \
            -j MASQUERADE 2>/dev/null
}

tailscale_netfilter_ok() {
    tailscale_netfilter_family_ok "$IPTABLES_BIN" &&
        { [[ -z "$IP6TABLES_BIN" ]] ||
          tailscale_netfilter_family_ok "$IP6TABLES_BIN"; }
}

port_binding_exists() {
    local container="$1" container_port="$2" expected="$3"
    "$DOCKER_BIN" port "$container" "$container_port" 2>/dev/null |
        grep -Fx "$expected" >/dev/null
}

docker_network_tuple() {
    local container="$1"
    "$DOCKER_BIN" inspect -f \
        '{{range $name, $cfg := .NetworkSettings.Networks}}{{printf "%s|%s\n" $name $cfg.IPAddress}}{{end}}' \
        "$container" 2>/dev/null | head -n 1
}

docker_dnat_rule_exists() {
    local container="$1" protocol="$2" port="$3" destination_ip="$4"
    local tuple="" network_name="" container_ip="" network_id="" bridge_if=""

    tuple="$(docker_network_tuple "$container")"
    [[ "$tuple" == *"|"* ]] || return 1
    network_name="${tuple%%|*}"
    container_ip="${tuple#*|}"
    [[ -n "$network_name" && -n "$container_ip" ]] || return 1
    network_id="$(
        "$DOCKER_BIN" network inspect -f '{{.Id}}' \
            "$network_name" 2>/dev/null || true
    )"
    bridge_if="$(
        "$DOCKER_BIN" network inspect -f \
            '{{index .Options "com.docker.network.bridge.name"}}' \
            "$network_name" 2>/dev/null || true
    )"
    if [[ -z "$bridge_if" || "$bridge_if" == "<no value>" ]]; then
        if [[ "$network_name" == "bridge" ]]; then
            bridge_if="docker0"
        elif [[ -n "$network_id" ]]; then
            bridge_if="br-${network_id:0:12}"
        fi
    fi
    [[ -n "$bridge_if" ]] || return 1

    "$IPTABLES_BIN" -w 5 -t nat -C DOCKER \
        -d "$destination_ip/32" ! -i "$bridge_if" \
        -p "$protocol" -m "$protocol" --dport "$port" \
        -j DNAT --to-destination "$container_ip:$port" 2>/dev/null
}

host_forward_prefix_ok() {
    local bin="$1" forward_rules="" leading_rules="" docker_rules=""
    local required_jump=""
    forward_rules="$("$bin" -w 5 -S FORWARD 2>/dev/null || true)"
    leading_rules="$(
        "$AWK_BIN" '$1 == "-A" {print; count++; if (count == 3) exit}' \
            <<<"$forward_rules"
    )"
    [[ "$leading_rules" == $'-A FORWARD -j DOCKER-USER\n-A FORWARD -j DOCKER-FORWARD\n-A FORWARD -j ts-forward' ]] ||
        return 1
    for required_jump in DOCKER-USER DOCKER-FORWARD ts-forward; do
        [[ "$(grep -Fxc -- "-A FORWARD -j $required_jump" \
                <<<"$forward_rules")" == "1" ]] || return 1
    done
    docker_rules="$("$bin" -w 5 -S DOCKER-FORWARD 2>/dev/null || true)"
    [[ -n "$docker_rules" ]] &&
        ! "$AWK_BIN" '$1 == "-A" && / -j (DROP|REJECT)( |$)/ {
            found=1
        } END {exit found ? 0 : 1}' <<<"$docker_rules"
}

docker_host_netfilter_ok() {
    host_forward_prefix_ok "$IPTABLES_BIN" &&
        { [[ -z "$IP6TABLES_BIN" ]] ||
          host_forward_prefix_ok "$IP6TABLES_BIN"; } &&
        "$IPTABLES_BIN" -w 5 -t nat -C PREROUTING \
        -m addrtype --dst-type LOCAL -j DOCKER 2>/dev/null &&
        "$IPTABLES_BIN" -w 5 -t nat -C OUTPUT \
            ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL \
            -j DOCKER 2>/dev/null &&
        docker_dnat_rule_exists qbittorrent tcp "$QBIT_PUBLIC_PORT" \
            "$CURRENT_PUBLIC_IPV4" &&
        docker_dnat_rule_exists qbittorrent udp "$QBIT_PUBLIC_PORT" \
            "$CURRENT_PUBLIC_IPV4" &&
        docker_dnat_rule_exists wg-easy udp "$WG_PUBLIC_PORT" \
            "$CURRENT_PUBLIC_IPV4"
}

wg_container_netfilter_ok() {
    local wg_cidr="" input_rules="" forward_rules="" nat_rules=""
    local sysctl_values="" default_route=""
    wg_cidr="$(
        "$DOCKER_BIN" exec wg-easy \
            ip -4 -o route show dev wg0 scope link 2>/dev/null |
            "$AWK_BIN" 'NR == 1 {print $1}' || true
    )"
    [[ "$wg_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]] ||
        return 1
    input_rules="$(
        "$DOCKER_BIN" exec wg-easy iptables -w 5 -S INPUT 2>/dev/null || true
    )"
    forward_rules="$(
        "$DOCKER_BIN" exec wg-easy iptables -w 5 -S FORWARD 2>/dev/null || true
    )"
    nat_rules="$(
        "$DOCKER_BIN" exec wg-easy iptables -w 5 -t nat -S POSTROUTING \
            2>/dev/null || true
    )"
    [[ "$input_rules" == $'-P INPUT ACCEPT\n-A INPUT -p udp -m udp --dport '"$WG_PUBLIC_PORT"$' -j ACCEPT' &&
       "$forward_rules" == $'-P FORWARD ACCEPT\n-A FORWARD -i wg0 -j ACCEPT\n-A FORWARD -o wg0 -j ACCEPT' &&
       "$nat_rules" == $'-P POSTROUTING ACCEPT\n-A POSTROUTING -s '"$wg_cidr"$' -o eth0 -j MASQUERADE' ]] ||
        return 1

    sysctl_values="$(
        "$DOCKER_BIN" exec wg-easy sh -c \
            'cat /proc/sys/net/ipv4/ip_forward /proc/sys/net/ipv4/conf/all/src_valid_mark /proc/sys/net/ipv6/conf/all/forwarding' \
            2>/dev/null || true
    )"
    [[ "$sysctl_values" == $'1\n1\n1' ]] || return 1
    default_route="$(
        "$DOCKER_BIN" exec wg-easy ip -4 route show default 2>/dev/null || true
    )"
    grep -Eq '^default .* dev eth0([[:space:]]|$)' <<<"$default_route"
}

qbittorrent_peer_listener_ok() {
    local listeners="" tuple="" container_ip=""
    tuple="$(docker_network_tuple qbittorrent)"
    [[ "$tuple" == *"|"* ]] || return 1
    container_ip="${tuple#*|}"
    [[ "$container_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    listeners="$(
        "$DOCKER_BIN" exec qbittorrent netstat -lntu 2>/dev/null || true
    )"
    "$AWK_BIN" -v expected="$container_ip:$QBIT_PUBLIC_PORT" \
        -v wildcard="0.0.0.0:$QBIT_PUBLIC_PORT" '
        $1 ~ /^tcp/ && ($4 == expected || $4 == wildcard) {
            tcp=1
        }
        $1 ~ /^udp/ && ($4 == expected || $4 == wildcard) {
            udp=1
        }
        END {exit (tcp && udp) ? 0 : 1}
    ' <<<"$listeners"
}

http_endpoint_responds() {
    local url="$1" insecure="${2:-0}" code="" curl_rc=0
    local -a tls_args=()
    [[ "$insecure" == "1" ]] && tls_args=(-k)
    code="$(
        "$CURL_BIN" --noproxy "*" -sS "${tls_args[@]}" \
            --connect-timeout 2 --max-time 4 \
            -o /dev/null -w '%{http_code}' "$url" 2>/dev/null
    )" || curl_rc=$?
    [[ "$curl_rc" -eq 0 &&
       "$code" =~ ^[1-4][0-9][0-9]$ ]]
}

webdav_direct_ok() {
    local host="$1" code=""
    code="$(
        "$CURL_BIN" --noproxy "*" -sS \
            --connect-timeout 2 --max-time 4 \
            -X PROPFIND -H "Depth: 0" \
            -o /dev/null -w '%{http_code}' \
            "http://$host:$WEBDAV_PORT/" 2>/dev/null || true
    )"
    [[ "$code" == "401" ]]
}

report_default_filebrowser_password() {
    local code=""
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' filebrowser \
          2>/dev/null || true)" == "true" ]] || return 0
    code="$(
        "$CURL_BIN" --noproxy '*' -sS --connect-timeout 2 --max-time 6 \
            -o /dev/null -w '%{http_code}' \
            -X POST -H 'X-Password: admin' \
            'http://127.0.0.1:7113/api/auth/login?username=admin' \
            2>/dev/null || true
    )"
    case "$code" in
        200)
            echo "UYARI: filebrowser admin parolası hâlâ varsayılan (admin/admin)." >&2
            echo "http://file.${LOCAL_DOMAIN} adresinden değiştirin." >&2
            ;;
        429)
            echo "UYARI: filebrowser varsayılan parola kontrolü yapılamadı; giriş uç noktası hız sınırında (429)." >&2
            echo "Bu 'parola varsayılan değil' anlamına GELMEZ; sonraki günlük denetimde yeniden bakılacak." >&2
            ;;
    esac
}

filebrowser_audit_due() {
    local now="" last=0
    now="$(date +%s)"
    if [[ -r "$FILEBROWSER_AUDIT_STAMP" ]]; then
        read -r last <"$FILEBROWSER_AUDIT_STAMP" || last=0
    fi
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= FILEBROWSER_AUDIT_INTERVAL_SECONDS ))
}

record_filebrowser_audit() {
    local stamp_tmp=""
    "$INSTALL_BIN" -d -m 0700 -o root -g root "$RESTART_STATE_DIR" ||
        return 1
    stamp_tmp="$(mktemp "$RESTART_STATE_DIR/.filebrowser-audit.XXXXXX")" ||
        return 1
    if ! printf '%s\n' "$(date +%s)" >"$stamp_tmp" ||
       ! chmod 0600 "$stamp_tmp" ||
       ! mv -f "$stamp_tmp" "$FILEBROWSER_AUDIT_STAMP"; then
        rm -f -- "$stamp_tmp"
        return 1
    fi
}

declare -a COMPOSE_RESTART_TARGETS=()
add_compose_restart_target() {
    local target="$1" existing=""
    for existing in "${COMPOSE_RESTART_TARGETS[@]:-}"; do
        [[ "$existing" == "$target" ]] && return 0
    done
    COMPOSE_RESTART_TARGETS+=("$target")
}

restart_budget_available() {
    local target="$1" stamp=""
    local now="" last=0
    stamp="$RESTART_STATE_DIR/$target.last-restart"
    now="$(date +%s)"
    if [[ -r "$stamp" ]]; then
        read -r last <"$stamp" || last=0
    fi
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= RESTART_COOLDOWN_SECONDS ))
}

record_container_restart() {
    local target="$1" tmp=""
    "$INSTALL_BIN" -d -m 0700 -o root -g root "$RESTART_STATE_DIR"
    tmp="$(mktemp "$RESTART_STATE_DIR/.${target}.XXXXXX")"
    printf '%s\n' "$(date +%s)" >"$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$RESTART_STATE_DIR/$target.last-restart"
}

probe_compose_runtime() {
    local container="" running="" health="" wg_running=""
    local wg_port="" setup_location=""
    local runtime_ok=0
    local -a expected_containers=(
        filebrowser portainer qbittorrent unpackerr wg-easy
    )

    COMPOSE_RESTART_TARGETS=()
    WG_CONFIGURATION_INVALID=0
    WG_SETUP_PENDING=0
    WG_OBSERVED_PORT=""
    for container in "${expected_containers[@]}"; do
        running="$(
            "$DOCKER_BIN" inspect -f '{{.State.Running}}' \
                "$container" 2>/dev/null || true
        )"
        if [[ "$running" != "true" ]]; then
            add_compose_restart_target "$container"
            runtime_ok=1
            continue
        fi
        health="$(
            "$DOCKER_BIN" inspect -f \
                '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$container" 2>/dev/null || true
        )"
        if [[ "$health" != "none" && "$health" != "healthy" ]]; then
            add_compose_restart_target "$container"
            runtime_ok=1
        fi
    done

    port_binding_exists portainer 9443/tcp "127.0.0.1:9443" ||
        { add_compose_restart_target portainer; runtime_ok=1; }
    port_binding_exists filebrowser 80/tcp "127.0.0.1:7113" ||
        { add_compose_restart_target filebrowser; runtime_ok=1; }
    port_binding_exists qbittorrent 13087/tcp "127.0.0.1:13087" ||
        { add_compose_restart_target qbittorrent; runtime_ok=1; }
    port_binding_exists qbittorrent "$QBIT_PUBLIC_PORT/tcp" \
        "$CURRENT_PUBLIC_IPV4:$QBIT_PUBLIC_PORT" ||
        { add_compose_restart_target qbittorrent; runtime_ok=1; }
    port_binding_exists qbittorrent "$QBIT_PUBLIC_PORT/udp" \
        "$CURRENT_PUBLIC_IPV4:$QBIT_PUBLIC_PORT" ||
        { add_compose_restart_target qbittorrent; runtime_ok=1; }
    port_binding_exists wg-easy 51821/tcp "127.0.0.1:51821" ||
        { add_compose_restart_target wg-easy; runtime_ok=1; }
    port_binding_exists wg-easy "$WG_PUBLIC_PORT/udp" \
        "$CURRENT_PUBLIC_IPV4:$WG_PUBLIC_PORT" ||
        { add_compose_restart_target wg-easy; runtime_ok=1; }

    if ! http_endpoint_responds https://127.0.0.1:9443/ 1; then
        add_compose_restart_target portainer
        runtime_ok=1
    fi
    if ! http_endpoint_responds http://127.0.0.1:7113/; then
        add_compose_restart_target filebrowser
        runtime_ok=1
    fi

    if ! http_endpoint_responds http://127.0.0.1:13087/; then
        add_compose_restart_target qbittorrent
        runtime_ok=1
    fi
    if ! qbittorrent_peer_listener_ok; then
        add_compose_restart_target qbittorrent
        runtime_ok=1
    fi
    if ! http_endpoint_responds http://127.0.0.1:51821/; then
        add_compose_restart_target wg-easy
        runtime_ok=1
    fi

    wg_running="$(
        "$DOCKER_BIN" inspect -f '{{.State.Running}}' \
            wg-easy 2>/dev/null || true
    )"
    if [[ "$wg_running" == "true" ]]; then
        wg_port="$(
            "$DOCKER_BIN" exec wg-easy \
                wg show wg0 listen-port 2>/dev/null || true
        )"
        setup_location="$(
            "$CURL_BIN" -fsSI --connect-timeout 2 \
                http://127.0.0.1:51821 2>/dev/null |
                "$AWK_BIN" -F': ' 'tolower($1) == "location" {
                    gsub("\r", "", $2); print $2; exit
                }' || true
        )"
        if [[ "$setup_location" == /setup/* ]]; then
            WG_SETUP_PENDING=1
        elif [[ "$wg_port" != "$WG_PUBLIC_PORT" ]]; then
            WG_OBSERVED_PORT="$wg_port"
            WG_CONFIGURATION_INVALID=1
            runtime_ok=1
        elif ! wg_container_netfilter_ok; then
            add_compose_restart_target wg-easy
            runtime_ok=1
        fi
    fi

    [[ "$runtime_ok" -eq 0 ]]
}

state_file_ok() {
    "$CMP_BIN" -s "$CANONICAL_DIR/state.env" "$STATE_FILE" &&
        owned_file_ok "$STATE_FILE" 0 0 600
}

compose_file_structurally_ok() {
    [[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] &&
        owned_file_ok "$COMPOSE_FILE" 0 0 600
}

compose_file_ok() {
    compose_file_structurally_ok &&
        "$CMP_BIN" -s "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE"
}

restore_missing_compose_file() {
    local target_parent="" tmp=""
    [[ ! -e "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || return 1
    target_parent="${COMPOSE_FILE%/*}"
    "$INSTALL_BIN" -d -m 0700 -o root -g root "$target_parent" ||
        return 1
    tmp="$(mktemp "$target_parent/.compose-reconcile.XXXXXX")" ||
        return 1
    if ! "$INSTALL_BIN" -m 0600 -o root -g root \
            "$CANONICAL_DIR/compose.yaml" "$tmp" ||
       [[ -e "$COMPOSE_FILE" || -L "$COMPOSE_FILE" ]] ||
       ! mv -f -- "$tmp" "$COMPOSE_FILE" ||
       ! compose_file_ok; then
        rm -f -- "$tmp"
        return 1
    fi
}

quantum_config_ok() {
    "$CMP_BIN" -s \
        "$CANONICAL_DIR/filebrowser.yaml" "$QUANTUM_CONFIG_FILE" &&
        owned_file_ok "$QUANTUM_CONFIG_FILE" 0 0 644 &&
        [[ ! -e "$QUANTUM_RESTART_PENDING_FILE" ]]
}

remove_quantum_container_if_present() {
    if "$DOCKER_BIN" container inspect filebrowser >/dev/null 2>&1; then
        "$DOCKER_BIN" rm -f filebrowser >/dev/null 2>&1
    else
        "$DOCKER_BIN" info >/dev/null 2>&1
    fi
}

restore_quantum_config() {
    local target_parent="" tmp=""
    QUANTUM_CONTAINER_RECREATE_REQUIRED=0
    target_parent="${QUANTUM_CONFIG_FILE%/*}"
    tmp="$(mktemp "$target_parent/.filebrowser-reconcile.XXXXXX")" ||
        return 1

    if ! "$INSTALL_BIN" -m 0644 -o root -g root \
            "$CANONICAL_DIR/filebrowser.yaml" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi

    if [[ -L "$QUANTUM_CONFIG_FILE" ||
          ( -e "$QUANTUM_CONFIG_FILE" &&
            ! -f "$QUANTUM_CONFIG_FILE" ) ]]; then
        if ! remove_quantum_container_if_present; then
            rm -f -- "$tmp"
            return 1
        fi
        if ! rm -rf -- "$QUANTUM_CONFIG_FILE"; then
            rm -f -- "$tmp"
            return 1
        fi
        QUANTUM_CONTAINER_RECREATE_REQUIRED=1
    fi

    if ! mv -f -- "$tmp" "$QUANTUM_CONFIG_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

restart_quantum_after_config_restore() {
    if [[ "$QUANTUM_CONTAINER_RECREATE_REQUIRED" -eq 1 ]] ||
       ! "$DOCKER_BIN" container inspect filebrowser >/dev/null 2>&1; then
        "$SYSTEMCTL_BIN" restart master-compose.service
    else
        "$DOCKER_BIN" restart filebrowser >/dev/null 2>&1
    fi
}

dns_config_files_ok() {
    "$CMP_BIN" -s \
        "$CANONICAL_DIR/dnsmasq-local-services.conf" \
        /etc/dnsmasq.d/local-services.conf &&
        owned_file_ok /etc/dnsmasq.d/local-services.conf 0 0 644 &&
        "$CMP_BIN" -s \
            "$CANONICAL_DIR/dnsmasq-99-tailscale-order.conf" \
            /etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf &&
        owned_file_ok \
            /etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf \
            0 0 644
}

caddy_config_files_ok() {
    "$CMP_BIN" -s \
            "$CANONICAL_DIR/Caddyfile" \
            /etc/caddy/Caddyfile &&
        owned_file_ok /etc/caddy/Caddyfile 0 0 644 &&
        "$CMP_BIN" -s \
            "$CANONICAL_DIR/caddy-99-tailnet-bind.conf" \
            /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf &&
        owned_file_ok \
            /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf \
            0 0 644 &&
        "$CMP_BIN" -s \
            "$CANONICAL_DIR/caddy-tailnet-env" \
            /usr/local/sbin/caddy-tailnet-env &&
        owned_file_ok /usr/local/sbin/caddy-tailnet-env 0 0 755 &&
        "$CMP_BIN" -s \
            "$CANONICAL_DIR/tailscaled-99-caddy-tailnet.conf" \
            /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf &&
        owned_file_ok \
            /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf \
            0 0 644
}

config_files_ok() {
    state_file_ok && quantum_config_ok &&
        dns_config_files_ok && caddy_config_files_ok
}

canonical_runtime_configs_valid() {
    dnsmasq --test \
        --conf-file="$CANONICAL_DIR/dnsmasq-local-services.conf" \
        >/dev/null 2>&1 &&
        TS_IPV4="$CURRENT_TAILSCALE_IPV4" \
            caddy validate --config "$CANONICAL_DIR/Caddyfile" \
            >/dev/null 2>&1
}

dns_listeners_ok() {
    local line="" local_address="" found_v4=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local_address="$("$AWK_BIN" '{print $5}' <<<"$line")"
        case "$local_address" in
            "$CURRENT_TAILSCALE_IPV4:53")
                found_v4=1
                ;;
            "[$CURRENT_TAILSCALE_IPV6]:53")
                [[ -n "$CURRENT_TAILSCALE_IPV6" ]] || return 1
                ;;
            *"%tailscale0:53")
                ;;
            *)
                return 1
                ;;
        esac
    done < <("$SS_BIN" -H -lntu 'sport = :53' 2>/dev/null || true)
    [[ "$found_v4" -eq 1 ]]
}

caddy_listener_ok() {
    local line="" local_address="" found=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local_address="$("$AWK_BIN" '{print $4}' <<<"$line")"
        [[ "$local_address" == "$CURRENT_TAILSCALE_IPV4:80" ]] ||
            return 1
        found=1
    done < <("$SS_BIN" -H -lnt 'sport = :80' 2>/dev/null || true)
    [[ "$found" -eq 1 ]]
}

dns_runtime_ok() {
    local answer="" external_status=""
    command -v dig >/dev/null 2>&1 || return 1
    dnsmasq --test >/dev/null 2>&1 || return 1
    answer="$(
        dig +time=2 +tries=1 +short \
            "@$CURRENT_TAILSCALE_IPV4" \
            "health.$LOCAL_DOMAIN" A 2>/dev/null |
            head -n 1 || true
    )"
    [[ "$answer" == "$CURRENT_TAILSCALE_IPV4" ]] || return 1
    external_status="$(
        dig +time=2 +tries=1 \
            "@$CURRENT_TAILSCALE_IPV4" example.com A 2>/dev/null |
            "$AWK_BIN" '/status:/ {
                sub(/.*, status: /, ""); sub(/,.*/, ""); print; exit
            }' || true
    )"
    [[ "$external_status" == "REFUSED" ]] && dns_listeners_ok
}

caddy_runtime_ok() {
    local env_ip="" body="" webdav_code=""
    env_ip="$(
        "$AWK_BIN" -F= '$1 == "TS_IPV4" {print $2; exit}' \
            /run/caddy-tailnet/tailscale.env 2>/dev/null || true
    )"
    [[ "$env_ip" == "$CURRENT_TAILSCALE_IPV4" ]] || return 1
    TS_IPV4="$CURRENT_TAILSCALE_IPV4" \
        caddy validate --config /etc/caddy/Caddyfile \
        >/dev/null 2>&1 || return 1
    body="$(
        "$CURL_BIN" --noproxy "*" -fsS \
            --connect-timeout 2 --max-time 4 \
            -H "Host: health.$LOCAL_DOMAIN" \
            "http://$CURRENT_TAILSCALE_IPV4/" 2>/dev/null || true
    )"
    [[ "$body" == "ok" ]] || return 1
    webdav_code="$(
        "$CURL_BIN" --noproxy "*" -sS \
            --connect-timeout 2 --max-time 4 \
            -X PROPFIND -H "Depth: 0" \
            -H "Host: webdav.$LOCAL_DOMAIN" \
            -o /dev/null -w '%{http_code}' \
            "http://$CURRENT_TAILSCALE_IPV4/" 2>/dev/null || true
    )"
    [[ "$webdav_code" == "401" ]] && caddy_listener_ok
}

FW_STATE="$("$SYSTEMCTL_BIN" is-active docker-tailscale-fw.service 2>/dev/null || true)"
FW_INACTIVE=0
[[ "$FW_STATE" == "active" ]] || FW_INACTIVE=1

COMPOSE_STATE="$("$SYSTEMCTL_BIN" is-active master-compose.service 2>/dev/null || true)"
COMPOSE_INACTIVE=0
[[ "$COMPOSE_STATE" == "active" ]] || COMPOSE_INACTIVE=1

FORWARDING_DRIFTED=0
if ! forwarding_ok || ! forwarding_config_ok; then
    FORWARDING_DRIFTED=1
fi

DISK_SPACE_LOW=0
disk_space_ok "$DOWNLOADS_PATH" || DISK_SPACE_LOW=1

INODE_SPACE_LOW=0
inode_space_ok "$DOWNLOADS_PATH" || INODE_SPACE_LOW=1

TAILSCALE_OFFLINE=0
TAILSCALE_PREFS_DRIFTED=0
TAILSCALE_NETFILTER_DRIFTED=0
tailscale_online || TAILSCALE_OFFLINE=1
tailscale_prefs_ok || TAILSCALE_PREFS_DRIFTED=1
tailscale_netfilter_ok || TAILSCALE_NETFILTER_DRIFTED=1

FIREWALL_DRIFTED=0
if [[ ! -x "$FW_HELPER" ]] || ! "$FW_HELPER" --check >/dev/null 2>&1; then
    FIREWALL_DRIFTED=1
fi

DOCKER_NETFILTER_DRIFTED=0
docker_host_netfilter_ok || DOCKER_NETFILTER_DRIFTED=1

COMPOSE_RUNTIME_DRIFTED=0
if ! probe_compose_runtime; then
    sleep 1
    probe_compose_runtime || COMPOSE_RUNTIME_DRIFTED=1
fi
[[ "$WG_SETUP_PENDING" -eq 0 ]] ||
    echo "UYARI: wg-easy ilk kurulumu tamamlanmamış; yönetici hesabı web arayüzünden oluşturulana kadar VPN kullanılamaz." >&2
[[ "$WG_CONFIGURATION_INVALID" -eq 0 ]] ||
    echo "HATA: wg-easy iç portu ${WG_OBSERVED_PORT:-yok}; beklenen $WG_PUBLIC_PORT." >&2

if [[ "$MODE" == "reconcile" ]] &&
   filebrowser_audit_due &&
   [[ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' filebrowser \
          2>/dev/null || true)" == "true" ]]; then
    if record_filebrowser_audit; then
        report_default_filebrowser_password
    else
        echo "UYARI: filebrowser parola audit damgası yazılamadı; rate-limit'i korumak için giriş denemesi yapılmadı." >&2
    fi
fi

STATE_CONFIG_DRIFTED=0
QUANTUM_CONFIG_DRIFTED=0
DNS_CONFIG_DRIFTED=0
CADDY_CONFIG_DRIFTED=0
CONFIG_DRIFTED=0
state_file_ok || STATE_CONFIG_DRIFTED=1
quantum_config_ok || QUANTUM_CONFIG_DRIFTED=1
dns_config_files_ok || DNS_CONFIG_DRIFTED=1
caddy_config_files_ok || CADDY_CONFIG_DRIFTED=1
if [[ "$STATE_CONFIG_DRIFTED" -eq 1 ||
      "$QUANTUM_CONFIG_DRIFTED" -eq 1 ||
      "$DNS_CONFIG_DRIFTED" -eq 1 ||
      "$CADDY_CONFIG_DRIFTED" -eq 1 ]]; then
    CONFIG_DRIFTED=1
fi
CANONICAL_CONFIG_INVALID=0
canonical_runtime_configs_valid || CANONICAL_CONFIG_INVALID=1

COMPOSE_FILE_DRIFTED=0
COMPOSE_FILE_MISSING=0
COMPOSE_FILE_UNSAFE=0
COMPOSE_FILE_METADATA_DRIFTED=0
if [[ ! -e "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]]; then
    COMPOSE_FILE_MISSING=1
    echo "UYARI: /root/docker/compose.yaml eksik; canonical kopya geri yüklenecek." >&2
elif [[ ! -f "$COMPOSE_FILE" || -L "$COMPOSE_FILE" ]]; then
    COMPOSE_FILE_UNSAFE=1
    echo "HATA: /root/docker/compose.yaml normal dosya değil; otomatik üzerine yazılmayacak." >&2
else
    "$CMP_BIN" -s "$CANONICAL_DIR/compose.yaml" "$COMPOSE_FILE" ||
        COMPOSE_FILE_DRIFTED=1
    owned_file_ok "$COMPOSE_FILE" 0 0 600 ||
        COMPOSE_FILE_METADATA_DRIFTED=1
fi
if [[ "$COMPOSE_FILE_DRIFTED" -eq 1 ]]; then
    echo "UYARI: /root/docker/compose.yaml kurulumun canonical kopyasından farklı." >&2
    echo "Otomatik geri yükleme yapılmaz. Kalıcı olması gereken bir değişiklikse install.sh'e işleyin." >&2
fi
if [[ "$COMPOSE_FILE_METADATA_DRIFTED" -eq 1 ]]; then
    echo "UYARI: /root/docker/compose.yaml sahiplik/modu sapmış; içerik değiştirilmeden düzeltilecek." >&2
fi

WEBDAV_UNIT_INACTIVE=0
WEBDAV_RUNTIME_DRIFTED=0
"$SYSTEMCTL_BIN" is-active --quiet master-webdav.service ||
    WEBDAV_UNIT_INACTIVE=1
if ! webdav_direct_ok "$CURRENT_TAILSCALE_IPV4"; then
    sleep 1
    webdav_direct_ok "$CURRENT_TAILSCALE_IPV4" || WEBDAV_RUNTIME_DRIFTED=1
fi

CADDY_INACTIVE=0
DNSMASQ_INACTIVE=0
CADDY_RUNTIME_DRIFTED=0
DNSMASQ_RUNTIME_DRIFTED=0
"$SYSTEMCTL_BIN" is-active --quiet caddy.service ||
    CADDY_INACTIVE=1
"$SYSTEMCTL_BIN" is-active --quiet dnsmasq.service ||
    DNSMASQ_INACTIVE=1
if ! dns_runtime_ok; then
    sleep 1
    dns_runtime_ok || DNSMASQ_RUNTIME_DRIFTED=1
fi
if ! caddy_runtime_ok; then
    sleep 1
    caddy_runtime_ok || CADDY_RUNTIME_DRIFTED=1
fi

gro_flags_ok() {
    local features=""
    [[ -n "$ETHTOOL_BIN" && -n "$CURRENT_WAN4_IF" ]] || return 0
    features="$("$ETHTOOL_BIN" -k "$CURRENT_WAN4_IF" 2>/dev/null || true)"
    grep -q '^rx-udp-gro-forwarding:' <<<"$features" || return 0
    grep -q '^rx-gro-list:' <<<"$features" || return 0
    grep -qE '^rx-udp-gro-forwarding:.*\[fixed\]|^rx-gro-list:.*\[fixed\]' \
        <<<"$features" && return 0
    grep -q '^rx-udp-gro-forwarding: on' <<<"$features" &&
        grep -q '^rx-gro-list: off' <<<"$features"
}

GRO_SERVICE_INACTIVE=0
GRO_FLAGS_DRIFTED=0
GRO_LOAD_STATE="$(
    "$SYSTEMCTL_BIN" show tailscale-udp-gro.service \
        --property=LoadState --value 2>/dev/null || true
)"
if [[ -n "$GRO_LOAD_STATE" && "$GRO_LOAD_STATE" != "not-found" ]]; then
    "$SYSTEMCTL_BIN" is-active --quiet tailscale-udp-gro.service ||
        GRO_SERVICE_INACTIVE=1
    gro_flags_ok || GRO_FLAGS_DRIFTED=1
fi

all_critical_state_healthy() {
    [[ "$ADDRESS_CHANGED" -eq 0 &&
       "$WG_ENDPOINT_DRIFTED" -eq 0 &&
       "$FORWARDING_DRIFTED" -eq 0 &&
       "$DISK_SPACE_LOW" -eq 0 &&
       "$INODE_SPACE_LOW" -eq 0 &&
       "$TAILSCALE_OFFLINE" -eq 0 &&
       "$TAILSCALE_PREFS_DRIFTED" -eq 0 &&
       "$TAILSCALE_NETFILTER_DRIFTED" -eq 0 &&
       "$FIREWALL_DRIFTED" -eq 0 &&
       "$DOCKER_NETFILTER_DRIFTED" -eq 0 &&
       "$FW_INACTIVE" -eq 0 &&
       "$COMPOSE_INACTIVE" -eq 0 &&
       "$COMPOSE_RUNTIME_DRIFTED" -eq 0 &&
       "$COMPOSE_FILE_MISSING" -eq 0 &&
       "$COMPOSE_FILE_UNSAFE" -eq 0 &&
       "$COMPOSE_FILE_METADATA_DRIFTED" -eq 0 &&
       "$CONFIG_DRIFTED" -eq 0 &&
       "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
       "$CANONICAL_CONFIG_INVALID" -eq 0 &&
       "$WEBDAV_UNIT_INACTIVE" -eq 0 &&
       "$WEBDAV_RUNTIME_DRIFTED" -eq 0 &&
       "$CADDY_INACTIVE" -eq 0 &&
       "$CADDY_RUNTIME_DRIFTED" -eq 0 &&
       "$DNSMASQ_INACTIVE" -eq 0 &&
       "$DNSMASQ_RUNTIME_DRIFTED" -eq 0 ]]
}

if [[ "$MODE" == "--check" ]]; then
    printf '%s\n' \
        "address=$ADDRESS_CHANGED forwarding=$FORWARDING_DRIFTED disk_space_low=$DISK_SPACE_LOW inode_space_low=$INODE_SPACE_LOW" \
        "wg_endpoint=$WG_ENDPOINT_DRIFTED" \
        "tailscale_offline=$TAILSCALE_OFFLINE tailscale_prefs=$TAILSCALE_PREFS_DRIFTED tailscale_netfilter=$TAILSCALE_NETFILTER_DRIFTED" \
        "firewall=$FIREWALL_DRIFTED docker_netfilter=$DOCKER_NETFILTER_DRIFTED firewall_unit=$FW_INACTIVE" \
        "compose_unit=$COMPOSE_INACTIVE compose_runtime=$COMPOSE_RUNTIME_DRIFTED wg_setup=$WG_SETUP_PENDING wg_config=$WG_CONFIGURATION_INVALID" \
        "config=$CONFIG_DRIFTED state_config=$STATE_CONFIG_DRIFTED quantum_config=$QUANTUM_CONFIG_DRIFTED dns_config=$DNS_CONFIG_DRIFTED caddy_config=$CADDY_CONFIG_DRIFTED canonical_bundle=$CANONICAL_BUNDLE_INVALID canonical_invalid=$CANONICAL_CONFIG_INVALID compose_file=$COMPOSE_FILE_DRIFTED compose_missing=$COMPOSE_FILE_MISSING compose_unsafe=$COMPOSE_FILE_UNSAFE compose_metadata=$COMPOSE_FILE_METADATA_DRIFTED" \
        "webdav_unit=$WEBDAV_UNIT_INACTIVE webdav_runtime=$WEBDAV_RUNTIME_DRIFTED" \
        "caddy_unit=$CADDY_INACTIVE caddy_runtime=$CADDY_RUNTIME_DRIFTED" \
        "dnsmasq_unit=$DNSMASQ_INACTIVE dnsmasq_runtime=$DNSMASQ_RUNTIME_DRIFTED" \
        "gro_unit=$GRO_SERVICE_INACTIVE gro_flags=$GRO_FLAGS_DRIFTED"
    if all_critical_state_healthy; then
        exit 0
    fi
    exit 1
fi

if [[ "$GRO_SERVICE_INACTIVE" -eq 1 || "$GRO_FLAGS_DRIFTED" -eq 1 ]]; then
    if [[ "$GRO_SERVICE_INACTIVE" -eq 1 ]]; then
        GRO_REASON="unit aktif değil"
    else
        GRO_REASON="ethtool bayrakları sapmış (unit aktif)"
    fi
    if restart_budget_available tailscale-udp-gro; then
        echo "tailscale-udp-gro: $GRO_REASON; yeniden uygulanıyor."
        record_container_restart tailscale-udp-gro
        "$SYSTEMCTL_BIN" reset-failed tailscale-udp-gro.service >/dev/null 2>&1 || true
        if "$SYSTEMCTL_BIN" restart tailscale-udp-gro.service; then
            GRO_SERVICE_INACTIVE=0
            gro_flags_ok && GRO_FLAGS_DRIFTED=0
        else
            echo "UYARI: UDP GRO optimizasyonu uygulanamadı; yalnız throughput etkilenir, bağlantı değil." >&2
        fi
    else
        echo "UYARI: tailscale-udp-gro $GRO_REASON; restart cooldown nedeniyle bu periyot atlandı." >&2
    fi
fi

if all_critical_state_healthy; then
    exit 0
fi

[[ "$ADDRESS_CHANGED" -eq 0 ]] ||
    echo "Ağ adresi drift'i: ${ENV_PUBLIC_IPV4:-yok}/${ENV_TAILSCALE_IPV4:-yok} -> $CURRENT_PUBLIC_IPV4/$CURRENT_TAILSCALE_IPV4"
[[ "$WG_ENDPOINT_DRIFTED" -eq 0 ]] ||
    echo "HATA: WG istemci endpoint'i $WG_ENDPOINT_HOST, güncel public IPv4 $CURRENT_PUBLIC_IPV4; DDNS veya istemci config güncellemesi gerekli." >&2
[[ "$FORWARDING_DRIFTED" -eq 0 ]] ||
    echo "IP forwarding çalışma değeri sapmış; yönetilen sysctl yeniden uygulanacak."
[[ "$DISK_SPACE_LOW" -eq 0 ]] ||
    echo "HATA: $DOWNLOADS_PATH bulunduğu dosya sistemi %${DISK_USAGE_THRESHOLD_PCT} üzerinde dolu; yeni indirme/çıkarma işlemleri başarısız olabilir. Otomatik onarım yok, elle yer açılması gerekiyor." >&2
[[ "$INODE_SPACE_LOW" -eq 0 ]] ||
    echo "HATA: $DOWNLOADS_PATH bulunduğu dosya sisteminin inode'larının %${DISK_USAGE_THRESHOLD_PCT}'ından fazlası kullanılmış; bayt olarak yer kalsa bile yeni dosya oluşturma ENOSPC verebilir. Çare çok sayıda küçük dosya silmektir, büyük dosya silmek inode açmaz. Otomatik onarım yok." >&2
[[ "$TAILSCALE_OFFLINE" -eq 0 ]] ||
    echo "HATA: Tailscale daemon aktif fakat Tailnet online değil." >&2
if [[ "$TAILSCALE_OFFLINE" -eq 1 ]]; then
    report_tailscale_diagnostics
fi
[[ "$TAILSCALE_PREFS_DRIFTED" -eq 0 ]] ||
    echo "Tailscale exit-node tercihleri sapmış; yeniden uygulanacak."
[[ "$TAILSCALE_NETFILTER_DRIFTED" -eq 0 ]] ||
    echo "Tailscale netfilter/NAT omurgası sapmış; tercihler yeniden uygulanacak."
[[ "$FIREWALL_DRIFTED" -eq 0 ]] ||
    echo "MASTER firewall zincirlerinin tam içerik/sırası sapmış; yenilenecek."
[[ "$DOCKER_NETFILTER_DRIFTED" -eq 0 ]] ||
    echo "Docker DNAT/FORWARD omurgası sapmış; ayrı core recovery planlanacak."
[[ "$FW_INACTIVE" -eq 0 ]] ||
    echo "docker-tailscale-fw.service aktif değil; yeniden uygulanacak."
[[ "$COMPOSE_INACTIVE" -eq 0 ]] ||
    echo "master-compose.service aktif değil; stack başlatılacak."
[[ "$COMPOSE_RUNTIME_DRIFTED" -eq 0 ]] ||
    echo "Container sağlık veya port binding sapması tespit edildi."
if [[ "$STATE_CONFIG_DRIFTED" -eq 1 ||
      "$DNS_CONFIG_DRIFTED" -eq 1 ||
      "$CADDY_CONFIG_DRIFTED" -eq 1 ]]; then
    if [[ "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
          "$CANONICAL_CONFIG_INVALID" -eq 0 ]]; then
        echo "Yönetilen state/Caddy/dnsmasq dosyası sapmış; canonical kopya geri yüklenecek."
    else
        echo "HATA: Yönetilen state/Caddy/dnsmasq dosyası sapmış; canonical kopya doğrulanamadığı için geri yükleme yapılmayacak." >&2
    fi
fi
if [[ "$QUANTUM_CONFIG_DRIFTED" -eq 1 ]]; then
    if [[ "$CANONICAL_BUNDLE_INVALID" -eq 0 ]]; then
        echo "filebrowser politika dosyası ($QUANTUM_CONFIG_FILE) sapmış; canonical kopya geri yüklenip container yenilenecek."
    else
        echo "HATA: filebrowser politika dosyası ($QUANTUM_CONFIG_FILE) sapmış; canonical kopya doğrulanamadığı için geri yükleme yapılmayacak." >&2
    fi
fi
[[ "$CANONICAL_CONFIG_INVALID" -eq 0 ]] ||
    echo "HATA: Canonical DNS/Caddy yapılandırması geçersiz; çalışan daemon'lar korunacak." >&2
[[ "$WEBDAV_UNIT_INACTIVE" -eq 0 && "$WEBDAV_RUNTIME_DRIFTED" -eq 0 ]] ||
    echo "Host WebDAV (master-webdav) active/işlev durumu sapmış; yeniden başlatılacak."
[[ "$CADDY_INACTIVE" -eq 0 && "$CADDY_RUNTIME_DRIFTED" -eq 0 ]] ||
    echo "Caddy active/işlev durumu sapmış; yeniden başlatılacak."
[[ "$DNSMASQ_INACTIVE" -eq 0 && "$DNSMASQ_RUNTIME_DRIFTED" -eq 0 ]] ||
    echo "dnsmasq active/işlev durumu sapmış; yeniden başlatılacak."

RECOVERY_FAILED=0
CORE_RECOVERY_SCHEDULED=0
FILEBROWSER_RUNTIME_RECREATE_REQUIRED=0
declare -a ELIGIBLE_RESTART_TARGETS=()

if [[ "$COMPOSE_FILE_MISSING" -eq 1 &&
      "$CANONICAL_BUNDLE_INVALID" -eq 0 ]]; then
    if restore_missing_compose_file; then
        COMPOSE_FILE_MISSING=0
        echo "Eksik compose.yaml canonical kopyadan geri yüklendi; çalışan container'lar değiştirilmedi."
    else
        echo "HATA: Eksik compose.yaml canonical kopyadan geri yüklenemedi." >&2
        RECOVERY_FAILED=1
    fi
fi
if [[ "$COMPOSE_FILE_METADATA_DRIFTED" -eq 1 ]]; then
    if chown root:root "$COMPOSE_FILE" &&
       chmod 0600 "$COMPOSE_FILE" &&
       compose_file_structurally_ok; then
        COMPOSE_FILE_METADATA_DRIFTED=0
    else
        echo "HATA: compose.yaml sahiplik/modu düzeltilemedi." >&2
        RECOVERY_FAILED=1
    fi
fi
if [[ "$COMPOSE_FILE_UNSAFE" -eq 1 ]]; then
    RECOVERY_FAILED=1
fi

if [[ "$TAILSCALE_OFFLINE" -eq 1 ]]; then
    RECOVERY_FAILED=1
fi
if [[ "$WG_ENDPOINT_DRIFTED" -eq 1 ||
      "$CANONICAL_BUNDLE_INVALID" -eq 1 ||
      "$CANONICAL_CONFIG_INVALID" -eq 1 ]]; then
    RECOVERY_FAILED=1
fi
if [[ "$WG_CONFIGURATION_INVALID" -eq 1 ]]; then
    echo "HATA: wg-easy kalıcı setup/port yapılandırma hatası otomatik restart ile değiştirilmeyecek." >&2
    RECOVERY_FAILED=1
fi

if [[ "$FORWARDING_DRIFTED" -eq 1 ]]; then
    SYSCTL_TMP="$(mktemp /etc/sysctl.d/.99-tailscale.conf.XXXXXX)"
    {
        printf 'net.ipv4.ip_forward = 1\n'
        printf 'net.ipv6.conf.all.forwarding = 1\n'
    } >"$SYSCTL_TMP"
    chmod 0644 "$SYSCTL_TMP"
    chown root:root "$SYSCTL_TMP"
    mv -f "$SYSCTL_TMP" /etc/sysctl.d/99-tailscale.conf
    if ! "$SYSCTL_BIN" -p /etc/sysctl.d/99-tailscale.conf >/dev/null ||
       ! forwarding_ok ||
       ! forwarding_config_ok; then
        echo "HATA: IP forwarding değerleri geri yüklenemedi." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$TAILSCALE_PREFS_DRIFTED" -eq 1 ||
      "$TAILSCALE_NETFILTER_DRIFTED" -eq 1 ]]; then
    if ! "$TAILSCALE_BIN" set \
            --advertise-exit-node \
            --ssh=true \
            --stateful-filtering=true \
            --netfilter-mode=on \
            --snat-subnet-routes=true; then
        echo "HATA: Tailscale exit-node/netfilter durumu onarılamadı." >&2
        RECOVERY_FAILED=1
    else
        TAILSCALE_REPAIRED=0
        for _ in $(seq 1 10); do
            if tailscale_prefs_ok && tailscale_netfilter_ok; then
                TAILSCALE_REPAIRED=1
                break
            fi
            sleep 1
        done
        if [[ "$TAILSCALE_REPAIRED" -ne 1 ]]; then
            echo "HATA: Tailscale exit-node/netfilter postcondition başarısız." >&2
            RECOVERY_FAILED=1
        fi
    fi
fi

STACK_RESTART_REQUIRED=0
if [[ "$ADDRESS_CHANGED" -eq 1 ||
      "$TAILSCALE_PREFS_DRIFTED" -eq 1 ||
      "$TAILSCALE_NETFILTER_DRIFTED" -eq 1 ||
      "$FIREWALL_DRIFTED" -eq 1 ||
      "$FW_INACTIVE" -eq 1 ]]; then
    if [[ "$ADDRESS_CHANGED" -eq 1 ]] ||
       restart_budget_available master-compose; then
        STACK_RESTART_REQUIRED=1
        record_container_restart master-compose
    else
        echo "HATA: master-compose stack yenilemesi $((RESTART_COOLDOWN_SECONDS / 60)) dakikalık cooldown içinde; tekrarlanmadı." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$STACK_RESTART_REQUIRED" -eq 1 ]]; then
    if ! "$SYSTEMCTL_BIN" stop master-compose.service; then
        echo "HATA: master-compose.service kontrollü durdurulamadı." >&2
        RECOVERY_FAILED=1
    elif ! "$SYSTEMCTL_BIN" restart docker-tailscale-fw.service; then
        echo "HATA: MASTER firewall politikası yenilenemedi." >&2
        RECOVERY_FAILED=1
    elif ! "$FW_HELPER" --check >/dev/null 2>&1; then
        echo "HATA: MASTER firewall postcondition başarısız." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$QUANTUM_CONFIG_DRIFTED" -eq 1 &&
      "$CANONICAL_BUNDLE_INVALID" -eq 0 ]]; then
    if ! restart_budget_available filebrowser; then
        echo "HATA: filebrowser politika onarımı $((RESTART_COOLDOWN_SECONDS / 60)) dakikalık cooldown içinde; dosya ve yürürlükteki politika birlikte korunup sonraki tura bırakıldı." >&2
        RECOVERY_FAILED=1
    elif ! "$INSTALL_BIN" -d -m 0700 -o root -g root \
            "$RESTART_STATE_DIR" ||
         ! (umask 077; : >"$QUANTUM_RESTART_PENDING_FILE"); then
        echo "HATA: filebrowser politika onarımı pending işareti yazılamadı." >&2
        RECOVERY_FAILED=1
    elif ! restore_quantum_config; then
        echo "HATA: Canonical filebrowser politika dosyası güvenli biçimde geri yüklenemedi." >&2
        RECOVERY_FAILED=1
    else
        record_container_restart filebrowser
        if restart_quantum_after_config_restore; then
            QUANTUM_CONFIG_REPAIRED=0
            for _ in $(seq 1 60); do
                quantum_health="$(
                    "$DOCKER_BIN" inspect -f \
                        '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                        filebrowser 2>/dev/null || true
                )"
                if [[ "$quantum_health" == "healthy" ||
                      "$quantum_health" == "none" ]] &&
                   http_endpoint_responds http://127.0.0.1:7113/; then
                    QUANTUM_CONFIG_REPAIRED=1
                    break
                fi
                sleep 1
            done
            if [[ "$QUANTUM_CONFIG_REPAIRED" -ne 1 ]]; then
                echo "HATA: filebrowser politika yenilemesinden sonra yanıt vermedi." >&2
                RECOVERY_FAILED=1
            elif ! rm -f -- "$QUANTUM_RESTART_PENDING_FILE"; then
                echo "HATA: filebrowser politika onarımı pending işareti temizlenemedi." >&2
                RECOVERY_FAILED=1
            else
                QUANTUM_CONFIG_DRIFTED=0
                COMPOSE_RUNTIME_DRIFTED=0
                probe_compose_runtime || COMPOSE_RUNTIME_DRIFTED=1
                COMPOSE_STATE="$(
                    "$SYSTEMCTL_BIN" is-active master-compose.service \
                        2>/dev/null || true
                )"
                COMPOSE_INACTIVE=0
                [[ "$COMPOSE_STATE" == "active" ]] || COMPOSE_INACTIVE=1
            fi
        else
            echo "HATA: filebrowser politika değişikliği için yeniden başlatılamadı/yaratılamadı." >&2
            RECOVERY_FAILED=1
        fi
    fi
fi

if [[ "$COMPOSE_RUNTIME_DRIFTED" -eq 1 ]]; then
    for restart_target in "${COMPOSE_RESTART_TARGETS[@]:-}"; do
        if [[ "$restart_target" == "wg-easy" &&
              ( "$WG_CONFIGURATION_INVALID" -eq 1 ||
                "$WG_SETUP_PENDING" -eq 1 ) ]]; then
            continue
        fi
        if restart_budget_available "$restart_target"; then
            if [[ "$restart_target" == "filebrowser" ]]; then
                FILEBROWSER_RUNTIME_RECREATE_REQUIRED=1
            else
                ELIGIBLE_RESTART_TARGETS+=("$restart_target")
            fi
        else
            echo "HATA: $restart_target otomatik restart bütçesinde; $((RESTART_COOLDOWN_SECONDS / 60)) dakikalık cooldown dolmadan yeniden başlatılmadı." >&2
            RECOVERY_FAILED=1
        fi
    done
fi

if [[ "$COMPOSE_INACTIVE" -eq 1 ||
      "$COMPOSE_RUNTIME_DRIFTED" -eq 1 ||
      "$STACK_RESTART_REQUIRED" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" stop master-compose.service >/dev/null 2>&1 || true
    if ((${#ELIGIBLE_RESTART_TARGETS[@]} > 0)); then
        if "$DOCKER_BIN" restart "${ELIGIBLE_RESTART_TARGETS[@]}" \
                >/dev/null 2>&1; then
            for restart_target in "${ELIGIBLE_RESTART_TARGETS[@]}"; do
                record_container_restart "$restart_target"
            done
        else
            echo "HATA: Hedef container restart işlemi başarısız." >&2
            RECOVERY_FAILED=1
        fi
    fi
    if [[ "$FILEBROWSER_RUNTIME_RECREATE_REQUIRED" -eq 1 ]]; then
        if remove_quantum_container_if_present; then
            record_container_restart filebrowser
        else
            echo "HATA: Sağlıksız filebrowser container'ı yeniden yaratılmak üzere kaldırılamadı." >&2
            RECOVERY_FAILED=1
        fi
    fi
    if ! "$SYSTEMCTL_BIN" start master-compose.service; then
        echo "HATA: Compose stack uzlaştırılamadı." >&2
        RECOVERY_FAILED=1
    elif ! probe_compose_runtime; then
        echo "HATA: Container/port postcondition başarısız." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$STATE_CONFIG_DRIFTED" -eq 1 &&
      "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
      "$CANONICAL_CONFIG_INVALID" -eq 0 ]]; then
    if ! "$INSTALL_BIN" -d -m 0700 -o root -g root /etc/master-stack ||
       ! "$INSTALL_BIN" -m 0600 -o root -g root \
            "$CANONICAL_DIR/state.env" "$STATE_FILE"; then
        echo "HATA: Canonical master state dosyası geri yüklenemedi." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$DNS_CONFIG_DRIFTED" -eq 1 &&
      "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
      "$CANONICAL_CONFIG_INVALID" -eq 0 ]]; then
    if ! "$INSTALL_BIN" -m 0644 -o root -g root \
            "$CANONICAL_DIR/dnsmasq-local-services.conf" \
            /etc/dnsmasq.d/local-services.conf ||
       ! "$INSTALL_BIN" -m 0644 -o root -g root \
            "$CANONICAL_DIR/dnsmasq-99-tailscale-order.conf" \
            /etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf; then
        echo "HATA: Canonical dnsmasq dosyaları geri yüklenemedi." >&2
        RECOVERY_FAILED=1
    else
        "$SYSTEMCTL_BIN" daemon-reload
    fi
fi

if [[ "$CADDY_CONFIG_DRIFTED" -eq 1 &&
      "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
      "$CANONICAL_CONFIG_INVALID" -eq 0 ]]; then
    if ! "$INSTALL_BIN" -m 0644 -o root -g root \
            "$CANONICAL_DIR/Caddyfile" /etc/caddy/Caddyfile ||
       ! "$INSTALL_BIN" -m 0644 -o root -g root \
            "$CANONICAL_DIR/caddy-99-tailnet-bind.conf" \
            /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf ||
       ! "$INSTALL_BIN" -m 0755 -o root -g root \
            "$CANONICAL_DIR/caddy-tailnet-env" \
            /usr/local/sbin/caddy-tailnet-env ||
       ! "$INSTALL_BIN" -m 0644 -o root -g root \
            "$CANONICAL_DIR/tailscaled-99-caddy-tailnet.conf" \
            /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf; then
        echo "HATA: Canonical Caddy dosyaları geri yüklenemedi." >&2
        RECOVERY_FAILED=1
    else
        "$SYSTEMCTL_BIN" daemon-reload
    fi
fi

if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ||
      "$WEBDAV_UNIT_INACTIVE" -eq 1 ||
      "$WEBDAV_RUNTIME_DRIFTED" -eq 1 ]]; then
    WEBDAV_RESTART_EXEMPT=0
    if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ]]; then
        WEBDAV_RESTART_EXEMPT=1
    fi
    if [[ "$WEBDAV_RESTART_EXEMPT" -eq 1 ]] ||
       restart_budget_available master-webdav; then
        if [[ "$WEBDAV_RESTART_EXEMPT" -eq 0 ]]; then
            record_container_restart master-webdav
        fi
        "$SYSTEMCTL_BIN" reset-failed master-webdav.service >/dev/null 2>&1 || true
        if ! "$SYSTEMCTL_BIN" restart master-webdav.service; then
            echo "HATA: master-webdav.service yeniden başlatılamadı." >&2
            RECOVERY_FAILED=1
        else
            WEBDAV_REPAIRED=0
            for _ in $(seq 1 10); do
                if webdav_direct_ok "$CURRENT_TAILSCALE_IPV4"; then
                    WEBDAV_REPAIRED=1
                    break
                fi
                sleep 1
            done
            if [[ "$WEBDAV_REPAIRED" -ne 1 ]]; then
                echo "HATA: Host WebDAV işlevsel postcondition başarısız." >&2
                RECOVERY_FAILED=1
            fi
        fi
    else
        echo "HATA: master-webdav yeniden başlatması $((RESTART_COOLDOWN_SECONDS / 60)) dakikalık cooldown içinde; tekrarlanmadı." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ||
      "$DNS_CONFIG_DRIFTED" -eq 1 ||
      "$DNSMASQ_INACTIVE" -eq 1 ||
      "$DNSMASQ_RUNTIME_DRIFTED" -eq 1 ]] &&
   [[ "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
      "$CANONICAL_CONFIG_INVALID" -eq 0 ]]; then
    DNSMASQ_RESTART_EXEMPT=0
    if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ||
          "$DNS_CONFIG_DRIFTED" -eq 1 ]]; then
        DNSMASQ_RESTART_EXEMPT=1
    fi
    if [[ "$DNSMASQ_RESTART_EXEMPT" -eq 1 ]] ||
       restart_budget_available dnsmasq; then
        if [[ "$DNSMASQ_RESTART_EXEMPT" -eq 0 ]]; then
            record_container_restart dnsmasq
        fi
        "$SYSTEMCTL_BIN" reset-failed dnsmasq.service >/dev/null 2>&1 || true
        if ! "$SYSTEMCTL_BIN" restart dnsmasq.service ||
           ! dns_runtime_ok; then
            echo "HATA: dnsmasq işlevsel postcondition başarısız." >&2
            RECOVERY_FAILED=1
        fi
    else
        echo "HATA: dnsmasq yeniden başlatması $((RESTART_COOLDOWN_SECONDS / 60)) dakikalık cooldown içinde; tekrarlanmadı." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ||
      "$CADDY_CONFIG_DRIFTED" -eq 1 ||
      "$CADDY_INACTIVE" -eq 1 ||
      "$CADDY_RUNTIME_DRIFTED" -eq 1 ]] &&
   [[ "$CANONICAL_BUNDLE_INVALID" -eq 0 &&
      "$CANONICAL_CONFIG_INVALID" -eq 0 ]]; then
    CADDY_RESTART_EXEMPT=0
    if [[ "$TAILSCALE_ADDRESS_CHANGED" -eq 1 ||
          "$CADDY_CONFIG_DRIFTED" -eq 1 ]]; then
        CADDY_RESTART_EXEMPT=1
    fi
    if [[ "$CADDY_RESTART_EXEMPT" -eq 1 ]] ||
       restart_budget_available caddy; then
        if [[ "$CADDY_RESTART_EXEMPT" -eq 0 ]]; then
            record_container_restart caddy
        fi
        "$SYSTEMCTL_BIN" reset-failed caddy.service >/dev/null 2>&1 || true
        if ! "$SYSTEMCTL_BIN" restart caddy.service ||
           ! caddy_runtime_ok; then
            echo "HATA: Caddy işlevsel postcondition başarısız." >&2
            RECOVERY_FAILED=1
        fi
    else
        echo "HATA: Caddy yeniden başlatması $((RESTART_COOLDOWN_SECONDS / 60)) dakikalık cooldown içinde; tekrarlanmadı." >&2
        RECOVERY_FAILED=1
    fi
fi

if [[ "$DOCKER_NETFILTER_DRIFTED" -eq 1 ]] &&
   docker_host_netfilter_ok; then
    DOCKER_NETFILTER_DRIFTED=0
fi

if [[ "$DOCKER_NETFILTER_DRIFTED" -eq 1 ]]; then
    if "$SYSTEMCTL_BIN" start --no-block "$CORE_RECOVERY_UNIT"; then
        CORE_RECOVERY_SCHEDULED=1
    else
        echo "HATA: Docker netfilter core recovery planlanamadı." >&2
        RECOVERY_FAILED=1
    fi
fi

if ! forwarding_ok ||
   ! forwarding_config_ok ||
   ! disk_space_ok "$DOWNLOADS_PATH" ||
   ! inode_space_ok "$DOWNLOADS_PATH" ||
   ! tailscale_online ||
   ! tailscale_prefs_ok ||
   ! tailscale_netfilter_ok ||
   [[ ! -x "$FW_HELPER" ]] ||
   ! "$FW_HELPER" --check >/dev/null 2>&1 ||
   { [[ "$CORE_RECOVERY_SCHEDULED" -eq 0 ]] &&
     ! docker_host_netfilter_ok; } ||
   [[ ! -r "$ENV_FILE" ]] ||
   ! grep -Fxq "PUBLIC_IPV4=$CURRENT_PUBLIC_IPV4" "$ENV_FILE" ||
   ! grep -Fxq "TAILSCALE_IPV4=$CURRENT_TAILSCALE_IPV4" "$ENV_FILE" ||
   ! probe_compose_runtime ||
   ! webdav_direct_ok "$CURRENT_TAILSCALE_IPV4" ||
   ! canonical_bundle_ok ||
   ! canonical_runtime_configs_valid ||
   ! compose_file_structurally_ok ||
   ! config_files_ok ||
   ! dns_runtime_ok ||
   ! caddy_runtime_ok; then
    echo "HATA: Bir veya daha fazla kritik postcondition doğrulanamadı." >&2
    RECOVERY_FAILED=1
fi

if [[ "$RECOVERY_FAILED" -ne 0 ]]; then
    echo "HATA: Bir veya daha fazla kritik ağ servisi uzlaştırılamadı." >&2
    exit 1
fi

if [[ "$CORE_RECOVERY_SCHEDULED" -eq 1 ]]; then
    echo "Yerel onarımlar tamamlandı; Docker core netfilter recovery sıraya alındı."
else
    echo "Ağ, firewall, container, DNS ve Caddy durumu uzlaştırıldı."
fi
RECONCILE_SCRIPT
chmod 0755 /usr/local/sbin/master-network-reconcile
progress_stage_note 85 "Ağ ve firewall reconcile helper'ı yazıldı"

cat >/usr/local/sbin/master-docker-netfilter-recovery <<'CORE_RECOVERY_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

LOCK_FILE="/run/lock/master-stack.lock"
STATE_DIR="/run/master-network-reconcile"
STAMP_FILE="$STATE_DIR/docker-core.last-restart"
COOLDOWN_SECONDS=900

exec 8>"$LOCK_FILE"
if ! flock -w 30 8; then
    echo "HATA: Docker core recovery master-stack kilidini alamadı." >&2
    exit 1
fi

if ! systemctl is-active --quiet docker.service ||
   ! systemctl is-active --quiet tailscaled.service; then
    echo "HATA: Docker core recovery için ana daemon'lar aktif değil." >&2
    exit 1
fi

install -d -m 0700 -o root -g root "$STATE_DIR"
NOW="$(date +%s)"
LAST=0
if [[ -r "$STAMP_FILE" ]]; then
    read -r LAST <"$STAMP_FILE" || LAST=0
fi
[[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
if (( NOW - LAST < COOLDOWN_SECONDS )); then
    echo "HATA: Docker core recovery $((COOLDOWN_SECONDS / 60)) dakikalık cooldown içinde; restart yinelenmedi." >&2
    exit 1
fi

STAMP_TMP="$(mktemp "$STATE_DIR/.docker-core.XXXXXX")"
printf '%s\n' "$NOW" >"$STAMP_TMP"
chmod 0600 "$STAMP_TMP"
mv -f "$STAMP_TMP" "$STAMP_FILE"

systemctl restart docker.service
systemctl start docker-tailscale-fw.service
systemctl start master-compose.service

MASTER_STACK_LOCK_HELD=1 \
    /usr/local/sbin/master-network-reconcile --check
echo "Docker DNAT/FORWARD omurgası restart sonrası doğrulandı."
CORE_RECOVERY_SCRIPT
chmod 0755 /usr/local/sbin/master-docker-netfilter-recovery

cat >/etc/systemd/system/master-docker-netfilter-recovery.service <<'CORE_RECOVERY_SYSTEMD'
[Unit]
Description=Recover Docker-owned DNAT and forwarding rules after reconcile exits
Wants=network-online.target tailscaled.service
After=network-online.target tailscaled.service master-network-reconcile.service
StartLimitIntervalSec=900
StartLimitBurst=2

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/master-docker-netfilter-recovery
Restart=no
TimeoutStartSec=1800
CORE_RECOVERY_SYSTEMD
set_unit_file_mode /etc/systemd/system/master-docker-netfilter-recovery.service

cat >/etc/systemd/system/master-network-reconcile.service <<'RECONCILE_SYSTEMD'
[Unit]
Description=Reconcile Docker, Tailnet bindings and managed firewall policy
After=network-online.target docker.service tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/master-network-reconcile
TimeoutStartSec=1800s
RECONCILE_SYSTEMD
set_unit_file_mode /etc/systemd/system/master-network-reconcile.service

cat >/etc/systemd/system/master-network-reconcile.timer <<'RECONCILE_TIMER'
[Unit]
Description=Periodically check WAN, Tailnet bindings and managed services

[Timer]
OnCalendar=*-*-* *:00/20:00
AccuracySec=10s
RandomizedDelaySec=0
Persistent=false
Unit=master-network-reconcile.service

[Install]
WantedBy=timers.target
RECONCILE_TIMER
set_unit_file_mode /etc/systemd/system/master-network-reconcile.timer

cat >/usr/local/sbin/master-webdav-serve <<'WEBDAV_SERVE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

IP_BIN="$(command -v ip)"
AWK_BIN="$(command -v awk)"
RCLONE_BIN="$(command -v rclone)"
WAIT_SECONDS=300

: "${MEDIA_DIR:?MEDIA_DIR tanımlı değil}"
: "${WEBDAV_PORT:?WEBDAV_PORT tanımlı değil}"
: "${CREDENTIALS_DIRECTORY:?systemd LoadCredential dizini yok}"

TS_IPV4=""
IP_PROBE_REPORTED=0
for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
    IP_RC=0
    IP_OUTPUT="$(
        "$IP_BIN" -4 -o addr show dev tailscale0 scope global 2>&1
    )" || IP_RC=$?

    if [[ "$IP_RC" -ne 0 ]]; then
        if [[ "$IP_PROBE_REPORTED" -eq 0 ]]; then
            echo "HATA: tailscale0 adresi sorgulanamıyor: ${IP_OUTPUT}" >&2
            IP_PROBE_REPORTED=1
        fi
    else
        TS_IPV4="$(
            "$AWK_BIN" 'NR == 1 {sub(/\/.*/, "", $4); print $4}' \
                <<<"$IP_OUTPUT"
        )"
        [[ "$TS_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        TS_IPV4=""
    fi
    sleep 1
done

if [[ -z "$TS_IPV4" ]]; then
    if [[ "$IP_PROBE_REPORTED" -eq 1 ]]; then
        echo "HATA: 'ip' komutu çalışamadığı için adres hiç okunamadı." >&2
    else
        echo "HATA: tailscale0 IPv4 adresi ${WAIT_SECONDS} saniyede oluşmadı." >&2
    fi
    exit 1
fi

echo "WebDAV dinleniyor: ${TS_IPV4}:${WEBDAV_PORT} -> ${MEDIA_DIR} (salt okunur)"
exec "$RCLONE_BIN" serve webdav "$MEDIA_DIR" \
    --config /dev/null \
    --addr "${TS_IPV4}:${WEBDAV_PORT}" \
    --htpasswd "$CREDENTIALS_DIRECTORY/htpasswd" \
    --dir-cache-time 1m \
    --read-only
WEBDAV_SERVE_SCRIPT
chmod 0755 /usr/local/sbin/master-webdav-serve

cat >/etc/systemd/system/master-webdav.service <<WEBDAV_SYSTEMD
[Unit]
Description=Salt okunur Tailnet WebDAV servisi (rclone, medya ağacı)
Wants=tailscaled.service
After=network-online.target tailscaled.service
PartOf=tailscaled.service
OnFailure=master-network-reconcile.service
RequiresMountsFor=${DOWNLOADS_PATH}/media
StartLimitIntervalSec=900
StartLimitBurst=2

[Service]
User=master-webdav
Environment=MEDIA_DIR=${DOWNLOADS_PATH}/media
Environment=WEBDAV_PORT=${WEBDAV_PORT}
LoadCredential=htpasswd:/etc/master-stack/webdav.htpasswd
ExecStart=/usr/local/sbin/master-webdav-serve
Restart=on-failure
RestartSec=5s
TimeoutStartSec=330s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
WEBDAV_SYSTEMD
set_unit_file_mode /etc/systemd/system/master-webdav.service

progress_stage_note 95 "Compose ve systemd tanımları son kontrolden geçiriliyor"
echo "Compose dosyası: /root/docker/compose.yaml"
echo "Image etiketleri (yama seviyesinde hareketli — bkz. DD-23):"
grep -E '^    image:' /root/docker/compose.yaml | sed 's/^/  /'

progress_stage_done
progress_stage_begin 5 "Container image'ları ve servisleri başlatılıyor"

cd /root/docker
progress_stage_note 10 "Compose yapılandırması doğrulanıyor"
docker compose --env-file /root/docker/.env config --quiet
progress_stage_note 20 "Container image'ları indiriliyor"
retry_network "Container image indirme" \
    "$NET_RETRY_BULK_FIRST" "$NET_RETRY_BULK_NEXT" -- \
    docker compose --env-file /root/docker/.env pull
progress_stage_note 60 "Systemd bağımlılık grafiği doğrulanıyor"
systemctl daemon-reload
systemd-analyze verify \
    docker.service \
    tailscaled.service \
    tailscale-udp-gro.service \
    docker-tailscale-fw.service \
    master-compose.service \
    master-webdav.service \
    master-docker-netfilter-recovery.service \
    master-network-reconcile.service \
    master-network-reconcile.timer
systemctl enable master-compose.service
systemctl enable master-webdav.service

progress_stage_note 75 "Firewall uygulanıp Compose stack başlatılıyor"
if docker container inspect filebrowser >/dev/null 2>&1; then
    QUANTUM_EXISTING_RUNNING="$(
        docker inspect -f '{{.State.Running}}' filebrowser 2>/dev/null || true
    )"
    QUANTUM_EXISTING_HEALTH="$(
        docker inspect -f \
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            filebrowser 2>/dev/null || true
    )"
    if [[ "$QUANTUM_EXISTING_RUNNING" != "true" ||
          ( "$QUANTUM_EXISTING_HEALTH" != "healthy" &&
            "$QUANTUM_EXISTING_HEALTH" != "none" ) ]]; then
        QUANTUM_CONFIG_RECREATE_REQUIRED=1
    fi
    if [[ "$QUANTUM_CONFIG_RECREATE_REQUIRED" -eq 1 ]]; then
        systemctl stop master-compose.service
        docker rm -f filebrowser >/dev/null
    fi
fi
if [[ "$DOCKER_WAS_ACTIVE" -eq 1 && "$DOCKER_DAEMON_JSON_CHANGED" -eq 1 ]]; then
    systemctl restart docker
    systemctl start docker-tailscale-fw.service
    systemctl start master-compose.service
else
    systemctl stop master-compose.service
    systemctl restart docker-tailscale-fw.service
    systemctl start master-compose.service
fi
echo "Container'lar başlatıldı."

progress_stage_note 90 "Host WebDAV servisi başlatılıyor"
systemctl reset-failed master-webdav.service >/dev/null 2>&1 || true
systemctl restart master-webdav.service

resolved_image_digest() {
    local container="$1" image_id="" digest=""
    image_id="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
    [[ -n "$image_id" ]] || return 0
    digest="$(
        docker image inspect -f \
            '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
            "$image_id" 2>/dev/null || true
    )"
    printf '%s' "${digest#*@}"
}

progress_stage_note 93 "Çalışan image digest'leri kaydediliyor"
for digest_service in portainer filebrowser qbittorrent unpackerr wg-easy; do
    service_digest="$(resolved_image_digest "$digest_service")"
    [[ "$service_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        service_digest="bilinmiyor"
    printf 'IMAGE_DIGEST_%s=%s\n' \
        "$(printf '%s' "$digest_service" | tr 'a-z-' 'A-Z_')" \
        "$service_digest"
done >>/etc/master-stack/state.env
unset digest_service service_digest

progress_stage_note 95 "Container sağlık beklemeleri tamamlandı"

progress_stage_done
progress_stage_begin 6 "Opsiyonel Tailnet DNS ve Caddy hazırlanıyor"
progress_stage_note 10 ".$LOCAL_DOMAIN için dnsmasq kuruluyor"

capture_dns_stack_files
DNSMASQ_INITIAL_LOAD_STATE="$(
    systemctl show dnsmasq.service -p LoadState --value 2>/dev/null || true
)"
DNSMASQ_INITIAL_UNIT_FILE_STATE="$(
    systemctl is-enabled dnsmasq.service 2>/dev/null || true
)"
DNSMASQ_INITIAL_LOAD_STATE="${DNSMASQ_INITIAL_LOAD_STATE:-not-found}"
DNSMASQ_INITIAL_UNIT_FILE_STATE="${DNSMASQ_INITIAL_UNIT_FILE_STATE:-not-found}"
systemctl is-active --quiet dnsmasq.service 2>/dev/null &&
    DNSMASQ_WAS_ACTIVE=1
CADDY_INITIAL_LOAD_STATE="$(
    systemctl show caddy.service -p LoadState --value 2>/dev/null || true
)"
CADDY_INITIAL_UNIT_FILE_STATE="$(
    systemctl is-enabled caddy.service 2>/dev/null || true
)"
CADDY_INITIAL_LOAD_STATE="${CADDY_INITIAL_LOAD_STATE:-not-found}"
CADDY_INITIAL_UNIT_FILE_STATE="${CADDY_INITIAL_UNIT_FILE_STATE:-not-found}"
systemctl is-active --quiet caddy.service 2>/dev/null &&
    CADDY_WAS_ACTIVE=1
DNS_STACK_STATE_CAPTURED=1

systemctl stop dnsmasq.service 2>/dev/null || true
systemctl mask dnsmasq.service >/dev/null
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" install -y dnsmasq dnsutils

install -d -m 0755 /etc/systemd/system/dnsmasq.service.d
cat >/etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf <<'DNSMASQ_DROPIN'
[Unit]
Wants=tailscaled.service
After=tailscaled.service
OnFailure=master-network-reconcile.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=10s
DNSMASQ_DROPIN
set_unit_file_mode \
    /etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf

cat >/etc/dnsmasq.d/local-services.conf <<EOF
interface=tailscale0
except-interface=lo
bind-dynamic
port=53

no-resolv
no-hosts
local=/$LOCAL_DOMAIN/
local-ttl=30

interface-name=portainer.$LOCAL_DOMAIN,tailscale0/4
interface-name=file.$LOCAL_DOMAIN,tailscale0/4
interface-name=qbit.$LOCAL_DOMAIN,tailscale0/4
interface-name=wg.$LOCAL_DOMAIN,tailscale0/4
interface-name=webdav.$LOCAL_DOMAIN,tailscale0/4
interface-name=health.$LOCAL_DOMAIN,tailscale0/4
EOF

chown root:root /etc/dnsmasq.d/local-services.conf
chmod 0644 /etc/dnsmasq.d/local-services.conf
dnsmasq --test
systemctl daemon-reload
systemctl unmask dnsmasq.service
systemctl enable dnsmasq
systemctl restart dnsmasq
progress_stage_note 35 "dnsmasq yalnız tailscale0 üzerinde hazır"

progress_stage_note 45 "Caddy paket deposu hazırlanıyor"
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" install -y \
    debian-keyring debian-archive-keyring apt-transport-https

CADDY_GPG_TMP="$(mktemp)"
retry_network "Caddy GPG anahtarı indirme" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    -o "$CADDY_GPG_TMP"
gpg --batch --yes --dearmor \
    -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    <"$CADDY_GPG_TMP"
rm -f "$CADDY_GPG_TMP"

retry_network "Caddy depo listesi indirme" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list

chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod 0644 /etc/apt/sources.list.d/caddy-stable.list

systemctl stop caddy.service 2>/dev/null || true
systemctl mask caddy.service >/dev/null
retry_network "apt-get update" \
    "$NET_RETRY_SMALL_FIRST" "$NET_RETRY_SMALL_NEXT" -- \
    apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" update
progress_stage_note 60 "Caddy paketi kuruluyor"
apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" install -y caddy

cat >/usr/local/sbin/caddy-tailnet-env <<'CADDY_ENV_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

IP_BIN="$(command -v ip)"
AWK_BIN="$(command -v awk)"
RUNTIME_DIR="/run/caddy-tailnet"
ENV_FILE="$RUNTIME_DIR/tailscale.env"
WAIT_SECONDS=300

mkdir -p "$RUNTIME_DIR"

for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
TS_IPV4="$(
    "$IP_BIN" -4 -o addr show dev tailscale0 scope global 2>/dev/null |
        "$AWK_BIN" 'NR == 1 {sub(/\/.*/, "", $4); print $4}' || true
)"

if [[ "$TS_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    TMP_FILE="$(mktemp "$RUNTIME_DIR/tailscale.env.XXXXXX")"
    printf 'TS_IPV4=%s\n' "$TS_IPV4" >"$TMP_FILE"
    mv -f "$TMP_FILE" "$ENV_FILE"
    echo "Caddy Tailscale IPv4: $TS_IPV4"
    exit 0
fi

sleep 1
done

echo "HATA: tailscale0 IPv4 adresi ${WAIT_SECONDS} saniyede oluşmadı." >&2
exit 1
CADDY_ENV_SCRIPT
chmod 0755 /usr/local/sbin/caddy-tailnet-env

install -d -m 0755 /etc/systemd/system/caddy.service.d
cat >/etc/systemd/system/caddy.service.d/99-tailnet-bind.conf <<'CADDY_DROPIN'
[Unit]
Wants=tailscaled.service docker.service
After=tailscaled.service docker.service
PartOf=tailscaled.service
OnFailure=master-network-reconcile.service
StartLimitIntervalSec=900
StartLimitBurst=2

[Service]
RuntimeDirectory=caddy-tailnet
RuntimeDirectoryMode=0750

ExecStartPre=/usr/local/sbin/caddy-tailnet-env

ExecStart=
ExecStart=/usr/bin/caddy run --environ --envfile /run/caddy-tailnet/tailscale.env --config /etc/caddy/Caddyfile

ExecReload=
ExecReload=/bin/sh -c '/usr/local/sbin/caddy-tailnet-env && exec /usr/bin/caddy reload --envfile /run/caddy-tailnet/tailscale.env --config /etc/caddy/Caddyfile --force'

Restart=on-failure
RestartSec=5s
TimeoutStartSec=330s
CADDY_DROPIN
set_unit_file_mode \
    /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf

install -d -m 0755 /etc/systemd/system/tailscaled.service.d
cat >/etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf <<'TS_CADDY_DROPIN'
[Unit]
Wants=caddy.service
Before=caddy.service
TS_CADDY_DROPIN
set_unit_file_mode \
    /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf

cat >/etc/caddy/Caddyfile <<EOF
{
	default_bind {\$TS_IPV4}
}

http://portainer.${LOCAL_DOMAIN} {
	reverse_proxy https://127.0.0.1:9443 {
		transport http {
			tls_insecure_skip_verify
		}
	}
}

http://file.${LOCAL_DOMAIN} {
	reverse_proxy 127.0.0.1:7113
}

http://qbit.${LOCAL_DOMAIN} {
	reverse_proxy 127.0.0.1:13087
}

http://wg.${LOCAL_DOMAIN} {
	reverse_proxy 127.0.0.1:51821
}

http://webdav.${LOCAL_DOMAIN} {
	reverse_proxy {\$TS_IPV4}:${WEBDAV_PORT}
}

http://health.${LOCAL_DOMAIN} {
	respond "ok" 200
}
EOF

chown root:root /etc/caddy/Caddyfile
chmod 0644 /etc/caddy/Caddyfile

TS_IPV4="$TS_IP" caddy validate --config /etc/caddy/Caddyfile

progress_stage_note 85 "Caddy Tailnet binding'i başlatılıp doğrulanıyor"
systemctl daemon-reload
systemctl unmask caddy.service
systemd-analyze verify caddy.service
systemctl enable caddy
systemctl restart caddy

caddy validate \
    --envfile /run/caddy-tailnet/tailscale.env \
    --config /etc/caddy/Caddyfile

echo "Tailnet DNS ve Caddy kurulumu tamamlandı."

CANONICAL_ROOT="/usr/local/share/master-stack"
CANONICAL_CURRENT_TARGET="$(
    readlink -f -- "$CANONICAL_ROOT/current" 2>/dev/null || true
)"
for canonical_old_generation in "$CANONICAL_ROOT"/.generation.*; do
    [[ -d "$canonical_old_generation" ]] || continue
    [[ "$canonical_old_generation" == "$CANONICAL_CURRENT_TARGET" ]] ||
        rm -rf -- "$canonical_old_generation"
done
CANONICAL_STAGE_DIR="$(
    mktemp -d "$CANONICAL_ROOT/.generation.XXXXXX"
)"
chown root:root "$CANONICAL_STAGE_DIR"
chmod 0755 "$CANONICAL_STAGE_DIR"

install -m 0600 -o root -g root \
    /etc/master-stack/state.env \
    "$CANONICAL_STAGE_DIR/state.env"
install -m 0600 -o root -g root \
    /root/docker/compose.yaml \
    "$CANONICAL_STAGE_DIR/compose.yaml"
install -m 0644 -o root -g root \
    "$QUANTUM_CONFIG_FILE" \
    "$CANONICAL_STAGE_DIR/filebrowser.yaml"
install -m 0644 -o root -g root \
    /etc/dnsmasq.d/local-services.conf \
    "$CANONICAL_STAGE_DIR/dnsmasq-local-services.conf"
install -m 0644 -o root -g root \
    /etc/systemd/system/dnsmasq.service.d/99-tailscale-order.conf \
    "$CANONICAL_STAGE_DIR/dnsmasq-99-tailscale-order.conf"
install -m 0644 -o root -g root \
    /etc/caddy/Caddyfile \
    "$CANONICAL_STAGE_DIR/Caddyfile"
install -m 0644 -o root -g root \
    /etc/systemd/system/caddy.service.d/99-tailnet-bind.conf \
    "$CANONICAL_STAGE_DIR/caddy-99-tailnet-bind.conf"
install -m 0755 -o root -g root \
    /usr/local/sbin/caddy-tailnet-env \
    "$CANONICAL_STAGE_DIR/caddy-tailnet-env"
install -m 0644 -o root -g root \
    /etc/systemd/system/tailscaled.service.d/99-caddy-tailnet.conf \
    "$CANONICAL_STAGE_DIR/tailscaled-99-caddy-tailnet.conf"

CANONICAL_MANIFEST_TMP="$CANONICAL_STAGE_DIR/.SHA256SUMS.tmp"
(
    cd "$CANONICAL_STAGE_DIR"
    sha256sum -- \
        state.env \
        compose.yaml \
        filebrowser.yaml \
        dnsmasq-local-services.conf \
        dnsmasq-99-tailscale-order.conf \
        Caddyfile \
        caddy-99-tailnet-bind.conf \
        caddy-tailnet-env \
        tailscaled-99-caddy-tailnet.conf
) >"$CANONICAL_MANIFEST_TMP"
chown root:root "$CANONICAL_MANIFEST_TMP"
chmod 0644 "$CANONICAL_MANIFEST_TMP"
mv -f "$CANONICAL_MANIFEST_TMP" "$CANONICAL_STAGE_DIR/SHA256SUMS"
(
    cd "$CANONICAL_STAGE_DIR"
    sha256sum -c --status SHA256SUMS
)

CANONICAL_LINK_TMP="${CANONICAL_STAGE_DIR}.link"
ln -s "$(basename "$CANONICAL_STAGE_DIR")" "$CANONICAL_LINK_TMP"
mv -Tf "$CANONICAL_LINK_TMP" "$CANONICAL_ROOT/current"

DNS_STACK_STATE_CAPTURED=0
CANONICAL_LINK_TMP=""
CANONICAL_STAGE_DIR=""
rm -rf -- "$DNS_STACK_ROLLBACK_DIR"
DNS_STACK_ROLLBACK_DIR=""

rm -f -- \
    "$CANONICAL_ROOT/SHA256SUMS" \
    "$CANONICAL_ROOT/state.env" \
    "$CANONICAL_ROOT/compose.yaml" \
    "$CANONICAL_ROOT/filebrowser.yaml" \
    "$CANONICAL_ROOT/dnsmasq-local-services.conf" \
    "$CANONICAL_ROOT/dnsmasq-99-tailscale-order.conf" \
    "$CANONICAL_ROOT/Caddyfile" \
    "$CANONICAL_ROOT/caddy-99-tailnet-bind.conf" \
    "$CANONICAL_ROOT/caddy-tailnet-env" \
    "$CANONICAL_ROOT/tailscaled-99-caddy-tailnet.conf"

progress_stage_note 95 "Yirmi dakikalık reconcile timer etkinleştiriliyor"
systemctl enable --now master-network-reconcile.timer
if ! systemctl is-active --quiet master-network-reconcile.timer; then
    echo "HATA: master-network-reconcile.timer başlatılamadı." >&2
    exit 1
fi
RECONCILE_TIMER_REENABLED=1

progress_stage_done
progress_stage_begin 7 "Çalışan sistem ve bağlantılar doğrulanıyor"

cd /root/docker

detect_ipv4_route
TS_IP="$(
    ip -4 -o addr show dev tailscale0 scope global 2>/dev/null |
        awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}' || true
)"
if [[ ! "$TS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "HATA: Doğrulama için güncel Tailscale IPv4 tespit edilemedi." >&2
    exit 1
fi

ENV_PUBLIC_IPV4="$(awk -F= '$1=="PUBLIC_IPV4" {print substr($0, index($0, "=") + 1); exit}' /root/docker/.env)"
ENV_TAILSCALE_IPV4="$(awk -F= '$1=="TAILSCALE_IPV4" {print substr($0, index($0, "=") + 1); exit}' /root/docker/.env)"
if [[ "$ENV_PUBLIC_IPV4" != "$PUBLIC_IPV4" || "$ENV_TAILSCALE_IPV4" != "$TS_IP" ]]; then
    echo "HATA: Compose adresleri çalışan arayüzlerle eşleşmiyor." >&2
    echo "  Public : ${ENV_PUBLIC_IPV4:-yok} (env), $PUBLIC_IPV4 (arayüz)" >&2
    echo "  Tailnet: ${ENV_TAILSCALE_IPV4:-yok} (env), $TS_IP (arayüz)" >&2
    exit 1
fi

for unit in tailscaled.service docker.service docker-tailscale-fw.service master-compose.service master-webdav.service master-network-reconcile.timer; do
    if ! systemctl is-active --quiet "$unit"; then
        echo "HATA: Zorunlu servis aktif değil: $unit" >&2
        systemctl --no-pager --full status "$unit" || true
        exit 1
    fi
done

assert_unit_property_contains() {
    local unit_name="$1" property_name="$2" actual_value="" required_unit=""
    shift 2
    actual_value="$(
        systemctl show "$unit_name" \
            --property="$property_name" --value 2>/dev/null || true
    )"
    for required_unit in "$@"; do
        if [[ " $actual_value " != *" $required_unit "* ]]; then
            echo "HATA: systemd bağımlılığı eksik: ${unit_name}.${property_name} -> ${required_unit}" >&2
            echo "Tespit edilen: ${actual_value:-<boş>}" >&2
            exit 1
        fi
    done
}

assert_unit_property_equals() {
    local unit_name="$1" property_name="$2" expected_value="$3" actual_value=""
    actual_value="$(
        systemctl show "$unit_name" \
            --property="$property_name" --value 2>/dev/null || true
    )"
    if [[ "$actual_value" != "$expected_value" ]]; then
        echo "HATA: systemd özelliği beklenen değerde değil: ${unit_name}.${property_name}" >&2
        echo "Beklenen: $expected_value; tespit edilen: ${actual_value:-<boş>}" >&2
        exit 1
    fi
}

assert_unit_property_excludes() {
    local unit_name="$1" property_name="$2" actual_value="" forbidden_unit=""
    shift 2
    actual_value="$(
        systemctl show "$unit_name" \
            --property="$property_name" --value 2>/dev/null || true
    )"
    for forbidden_unit in "$@"; do
        if [[ " $actual_value " == *" $forbidden_unit "* ]]; then
            echo "HATA: systemd bağımlılığı beklenmedik unit çekiyor: ${unit_name}.${property_name} -> ${forbidden_unit}" >&2
            echo "Tespit edilen: ${actual_value:-<boş>}" >&2
            exit 1
        fi
    done
}

assert_unit_property_contains tailscaled.service Wants \
    docker-tailscale-fw.service master-compose.service master-webdav.service
assert_unit_property_contains docker.service Wants \
    docker-tailscale-fw.service master-compose.service

assert_unit_property_contains master-webdav.service PartOf \
    tailscaled.service
assert_unit_property_contains master-webdav.service After \
    tailscaled.service
assert_unit_property_contains master-webdav.service OnFailure \
    master-network-reconcile.service
if ! grep -Fxq "RequiresMountsFor=$DOWNLOADS_PATH/media" \
        /etc/systemd/system/master-webdav.service; then
    echo "HATA: master-webdav medya mount bağımlılığı eksik." >&2
    exit 1
fi

assert_unit_property_contains docker-tailscale-fw.service Requires \
    docker.service tailscaled.service
assert_unit_property_contains docker-tailscale-fw.service After \
    docker.service tailscaled.service
assert_unit_property_contains docker-tailscale-fw.service PartOf \
    docker.service tailscaled.service
assert_unit_property_contains docker-tailscale-fw.service OnFailure \
    master-network-reconcile.service

assert_unit_property_contains master-compose.service Requires \
    docker.service docker-tailscale-fw.service tailscaled.service
assert_unit_property_contains master-compose.service After \
    docker.service docker-tailscale-fw.service tailscaled.service
assert_unit_property_contains master-compose.service PartOf \
    docker.service tailscaled.service
assert_unit_property_contains master-compose.service OnFailure \
    master-network-reconcile.service

assert_unit_property_contains master-network-reconcile.service After \
    docker.service tailscaled.service
assert_unit_property_excludes master-network-reconcile.service After \
    docker-tailscale-fw.service master-compose.service
assert_unit_property_excludes master-network-reconcile.service Requires \
    docker.service tailscaled.service
assert_unit_property_excludes master-network-reconcile.service Requisite \
    docker.service tailscaled.service
if grep -q '^ConditionPathExists=' \
        /etc/systemd/system/master-network-reconcile.service; then
    echo "HATA: Reconcile eksik compose.yaml durumunda koşulsuz çalışabilmeli." >&2
    exit 1
fi
assert_unit_property_contains master-docker-netfilter-recovery.service After \
    tailscaled.service master-network-reconcile.service
assert_unit_property_excludes master-docker-netfilter-recovery.service Requires \
    docker.service master-network-reconcile.service
assert_unit_property_equals master-docker-netfilter-recovery.service Restart no
assert_unit_property_equals \
    master-docker-netfilter-recovery.service TimeoutStartUSec 30min

for reconciled_oneshot in \
    tailscale-udp-gro.service \
    docker-tailscale-fw.service \
    master-compose.service; do
    assert_unit_property_equals "$reconciled_oneshot" Restart no
    assert_unit_property_equals "$reconciled_oneshot" StartLimitIntervalUSec 1min
    assert_unit_property_equals "$reconciled_oneshot" StartLimitBurst 10
done

assert_unit_property_contains tailscaled.service Wants caddy.service
assert_unit_property_contains caddy.service Wants \
    docker.service tailscaled.service
assert_unit_property_contains caddy.service After \
    docker.service tailscaled.service
assert_unit_property_contains caddy.service PartOf tailscaled.service
assert_unit_property_contains dnsmasq.service Wants tailscaled.service
assert_unit_property_contains dnsmasq.service After tailscaled.service
for guarded_daemon in caddy.service dnsmasq.service; do
    assert_unit_property_contains "$guarded_daemon" OnFailure \
        master-network-reconcile.service
    assert_unit_property_equals "$guarded_daemon" Restart on-failure
done
assert_unit_property_equals dnsmasq.service StartLimitIntervalUSec 1min
assert_unit_property_equals dnsmasq.service StartLimitBurst 5
assert_unit_property_equals caddy.service StartLimitIntervalUSec 15min
assert_unit_property_equals caddy.service StartLimitBurst 2
echo "Systemd bağımlılık ve kurtarma modeli etkin manager özelliklerinden doğrulandı."
progress_stage_note 30 "Systemd servis ve kurtarma modeli doğrulandı"

CURRENT_TIMEZONE="$(timedatectl show --property=Timezone --value)"
if [[ "$CURRENT_TIMEZONE" != "$TIMEZONE" ]]; then
    echo "HATA: Sistem zaman dilimi beklenen değerle eşleşmiyor." >&2
    echo "Beklenen: $TIMEZONE" >&2
    echo "Tespit edilen: ${CURRENT_TIMEZONE:-yok}" >&2
    exit 1
fi

if ! grep -Fxq "OnCalendar=*-*-* *:00/20:00" \
        /etc/systemd/system/master-network-reconcile.timer ||
   ! grep -Fxq "RandomizedDelaySec=0" \
        /etc/systemd/system/master-network-reconcile.timer ||
   ! grep -Fxq "Persistent=false" \
        /etc/systemd/system/master-network-reconcile.timer ||
   ! systemd-analyze calendar "*-*-* *:00/20:00" >/dev/null; then
    echo "HATA: Reconcile timer beklenen deterministik zamanlamayla eşleşmiyor." >&2
    exit 1
fi

if ! systemctl is-active --quiet tailscale-udp-gro.service; then
    echo "UYARI: Opsiyonel UDP GRO optimizasyon servisi henüz aktif değil." >&2
fi

progress_stage_note 40 "Tailscale, forwarding ve container durumları okunuyor"
echo
echo "--- Tailscale ---"
tailscale status
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding

echo
echo "--- Container'lar ---"
docker compose ps

UNPACKERR_DOWNLOADS_SOURCE="$(
    docker inspect unpackerr \
        --format '{{range .Mounts}}{{if eq .Destination "/downloads"}}{{.Source}}{{end}}{{end}}'
)"
if [[ "$UNPACKERR_DOWNLOADS_SOURCE" != "$DOWNLOADS_PATH/media" ]]; then
    echo "HATA: Unpackerr /downloads bağlantısı beklenen host dizinine bağlı değil." >&2
    echo "Beklenen: $DOWNLOADS_PATH/media" >&2
    echo "Tespit edilen: ${UNPACKERR_DOWNLOADS_SOURCE:-yok}" >&2
    exit 1
fi

UNPACKERR_ENV="$(docker inspect unpackerr --format '{{range .Config.Env}}{{println .}}{{end}}')"
for expected_env in \
    "UN_FOLDERS_INTERVAL=10s" \
    "UN_FOLDER_0_PATH=/downloads" \
    "UN_FOLDER_0_DELETE_AFTER=0" \
    "UN_FOLDER_0_DISABLE_RECURSION=false" \
    "UN_FOLDER_0_DELETE_ORIGINAL=false" \
    "UN_FOLDER_0_MOVE_BACK=true" \
    "UN_LOG_FILE_MB=10"; do
    if ! grep -Fxq "$expected_env" <<<"$UNPACKERR_ENV"; then
        echo "HATA: Unpackerr ayarı uygulanmamış: $expected_env" >&2
        exit 1
    fi
done
echo "Unpackerr doğrulandı: tüm media ağacı, alt klasörler ve iç içe arşivler izleniyor."
progress_stage_note 55 "Container mount, arşiv ve port yayınları doğrulanıyor"

echo
echo "--- IPv4 DOCKER-USER / MASTER-DOCKER ---"
iptables -L DOCKER-USER -n -v --line-numbers
iptables -L MASTER-DOCKER -n -v --line-numbers

FIRST_MANGLE_FORWARD_RULE="$(
    iptables -w 5 -t mangle -S FORWARD 2>/dev/null |
        awk '$1=="-A" {print; exit}' || true
)"
FIRST_DOCKER_USER_RULE="$(
    iptables -w 5 -S DOCKER-USER 2>/dev/null |
        awk '$1=="-A" {print; exit}' || true
)"
if [[ "$FIRST_MANGLE_FORWARD_RULE" != "-A FORWARD -j MASTER-TS-FORWARD" ||
      "$FIRST_DOCKER_USER_RULE" != "-A DOCKER-USER -j MASTER-DOCKER" ]]; then
    echo "HATA: Yönetilen firewall jump kuralları zincirlerin ilk sırasında değil." >&2
    exit 1
fi

echo
echo "--- IPv4 mangle/FORWARD / MASTER-TS-FORWARD ---"
iptables -t mangle -L FORWARD -n -v --line-numbers
iptables -t mangle -L MASTER-TS-FORWARD -n -v --line-numbers

if command -v ip6tables >/dev/null 2>&1 && \
   ip6tables -L MASTER-DOCKER -n >/dev/null 2>&1; then
    echo
    echo "--- IPv6 MASTER-DOCKER ---"
    ip6tables -L MASTER-DOCKER -n -v --line-numbers
fi

echo
echo "--- Dinlenen portlar ---"
ss -lntup | grep -E \
    ":(53|80|9443|7113|13087|${QBIT_PUBLIC_PORT}|${WG_PUBLIC_PORT}|51821|${WEBDAV_PORT})([[:space:]]|$)" || true

assert_docker_binding() {
    local container="$1" container_port="$2" expected_binding="$3" bindings=""
    bindings="$(docker port "$container" "$container_port" 2>/dev/null || true)"
    if ! grep -Fx "$expected_binding" <<<"$bindings" >/dev/null; then
        echo "HATA: $container için beklenen Docker port yayını bulunamadı:" >&2
        echo "  $container_port -> $expected_binding" >&2
        printf '%s\n' "${bindings:-<yayın yok>}" >&2
        exit 1
    fi
}

assert_docker_binding qbittorrent "${QBIT_PUBLIC_PORT}/tcp" "${PUBLIC_IPV4}:${QBIT_PUBLIC_PORT}"
assert_docker_binding qbittorrent "${QBIT_PUBLIC_PORT}/udp" "${PUBLIC_IPV4}:${QBIT_PUBLIC_PORT}"
assert_docker_binding wg-easy "${WG_PUBLIC_PORT}/udp" "${PUBLIC_IPV4}:${WG_PUBLIC_PORT}"

for digest_service in portainer filebrowser qbittorrent unpackerr wg-easy; do
    DIGEST_KEY="IMAGE_DIGEST_$(printf '%s' "$digest_service" | tr 'a-z-' 'A-Z_')"
    RECORDED_DIGEST="$(
        awk -F= -v k="$DIGEST_KEY" \
            '$1==k {print substr($0, index($0, "=") + 1); exit}' \
            /etc/master-stack/state.env
    )"
    RUNNING_DIGEST="$(resolved_image_digest "$digest_service")"
    if [[ ! "$RECORDED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "HATA: $DIGEST_KEY state.env'e yazılamamış (${RECORDED_DIGEST:-boş})." >&2
        exit 1
    fi
    if [[ "$RECORDED_DIGEST" != "$RUNNING_DIGEST" ]]; then
        echo "HATA: $digest_service çalışan digest'i kayıtla uyuşmuyor." >&2
        echo "  kayıt   : $RECORDED_DIGEST" >&2
        echo "  çalışan : ${RUNNING_DIGEST:-tespit edilemedi}" >&2
        exit 1
    fi
done
unset digest_service DIGEST_KEY RECORDED_DIGEST RUNNING_DIGEST

RECONCILE_COOLDOWN="$(
    awk -F= '$1 == "RESTART_COOLDOWN_SECONDS" {print $2; exit}' \
        /usr/local/sbin/master-network-reconcile
)"
RECOVERY_COOLDOWN="$(
    awk -F= '$1 == "COOLDOWN_SECONDS" {print $2; exit}' \
        /usr/local/sbin/master-docker-netfilter-recovery
)"
if [[ ! "$RECONCILE_COOLDOWN" =~ ^[0-9]+$ ||
      ! "$RECOVERY_COOLDOWN" =~ ^[0-9]+$ ]]; then
    echo "HATA: Onarım cooldown sabiti üretilen script'lerden okunamadı." >&2
    echo "  reconcile: ${RECONCILE_COOLDOWN:-yok}" >&2
    echo "  recovery : ${RECOVERY_COOLDOWN:-yok}" >&2
    exit 1
fi
if [[ "$RECONCILE_COOLDOWN" != "$MASTER_RESTART_COOLDOWN_SECONDS" ||
      "$RECOVERY_COOLDOWN" != "$MASTER_RESTART_COOLDOWN_SECONDS" ]]; then
    echo "HATA: Onarım cooldown sabitleri birbirinden ayrışmış." >&2
    echo "  install.sh : $MASTER_RESTART_COOLDOWN_SECONDS" >&2
    echo "  reconcile  : $RECONCILE_COOLDOWN" >&2
    echo "  recovery   : $RECOVERY_COOLDOWN" >&2
    exit 1
fi
unset RECONCILE_COOLDOWN RECOVERY_COOLDOWN

if ! ss -lnt "( sport = :${WEBDAV_PORT} )" | grep -q "${TS_IP}:${WEBDAV_PORT}"; then
    echo "HATA: Host WebDAV dinleyicisi ${TS_IP}:${WEBDAV_PORT} adresinde bulunamadı." >&2
    exit 1
fi
if ss -lnt "( sport = :${WEBDAV_PORT} )" |
    grep -qE "(${PUBLIC_IPV4}|0\.0\.0\.0|\*):${WEBDAV_PORT}"; then
    echo "HATA: Host WebDAV dinleyicisi public/wildcard adrese açılmış." >&2
    exit 1
fi

for port_spec in "tcp:${QBIT_PUBLIC_PORT}" "udp:${QBIT_PUBLIC_PORT}" "udp:${WG_PUBLIC_PORT}"; do
    protocol="${port_spec%%:*}"
    port="${port_spec##*:}"
    if ! iptables -w 5 -C MASTER-DOCKER \
            -i "$WAN4_IF" -p "$protocol" \
            -m conntrack --ctstate NEW \
            --ctorigdst "$PUBLIC_IPV4" --ctorigdstport "$port" \
            -j RETURN; then
        echo "HATA: Public $protocol/$port firewall izni bulunamadı." >&2
        exit 1
    fi
done

V4_DOCKER_JUMP_COUNT="$(
    iptables -w 5 -S DOCKER-USER |
        awk '$0=="-A DOCKER-USER -j MASTER-DOCKER" {count++}
             END {print count+0}'
)"
V4_MANGLE_JUMP_COUNT="$(
    iptables -w 5 -t mangle -S FORWARD |
        awk '$0=="-A FORWARD -j MASTER-TS-FORWARD" {count++}
             END {print count+0}'
)"
if [[ "$V4_DOCKER_JUMP_COUNT" != "1" || "$V4_MANGLE_JUMP_COUNT" != "1" ]] ||
   ! iptables -w 5 -C MASTER-DOCKER \
        -i tailscale0 -o "$WAN4_IF" -j ACCEPT ||
   ! iptables -w 5 -C MASTER-DOCKER -o tailscale0 -j DROP ||
   ! iptables -w 5 -C MASTER-DOCKER -i "$WAN4_IF" -j DROP ||
   ! iptables -w 5 -t mangle -C MASTER-TS-FORWARD \
        -i tailscale0 -o "$WAN4_IF" \
        -j MARK --set-xmark 0x40000/0xff0000 ||
   ! iptables -w 5 -t mangle -C MASTER-TS-FORWARD \
        -i tailscale0 -o "$WAN4_IF" -j ACCEPT ||
   ! iptables -w 5 -t mangle -C MASTER-TS-FORWARD -i tailscale0 -j DROP ||
   ! iptables -w 5 -t mangle -C MASTER-TS-FORWARD -o tailscale0 -j DROP; then
    echo "HATA: IPv4 firewall DROP/exit-node omurgası eksik veya yinelenmiş." >&2
    exit 1
fi

if command -v ip6tables >/dev/null 2>&1 &&
   ip6tables -w 5 -L DOCKER-USER -n >/dev/null 2>&1; then
    V6_DOCKER_JUMP_COUNT="$(
        ip6tables -w 5 -S DOCKER-USER |
            awk '$0=="-A DOCKER-USER -j MASTER-DOCKER" {count++}
                 END {print count+0}'
    )"
    V6_MANGLE_JUMP_COUNT="$(
        ip6tables -w 5 -t mangle -S FORWARD |
            awk '$0=="-A FORWARD -j MASTER-TS-FORWARD" {count++}
                 END {print count+0}'
    )"
    if [[ "$V6_DOCKER_JUMP_COUNT" != "1" || "$V6_MANGLE_JUMP_COUNT" != "1" ]] ||
       ! ip6tables -w 5 -C MASTER-DOCKER -o tailscale0 -j DROP ||
       ! ip6tables -w 5 -t mangle -C MASTER-TS-FORWARD \
            -i tailscale0 -j DROP ||
       ! ip6tables -w 5 -t mangle -C MASTER-TS-FORWARD \
            -o tailscale0 -j DROP; then
        echo "HATA: IPv6 firewall Tailnet izolasyon omurgası eksik veya yinelenmiş." >&2
        exit 1
    fi

    WAN6_IF_FINAL="$(
        ip -6 -o route get 2001:4860:4860::8888 2>/dev/null |
            awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' ||
            true
    )"
    if [[ -n "$WAN6_IF_FINAL" ]] &&
       { ! ip6tables -w 5 -C MASTER-DOCKER \
                -i tailscale0 -o "$WAN6_IF_FINAL" -j ACCEPT ||
         ! ip6tables -w 5 -C MASTER-DOCKER -i "$WAN6_IF_FINAL" -j DROP ||
         ! ip6tables -w 5 -t mangle -C MASTER-TS-FORWARD \
                -i tailscale0 -o "$WAN6_IF_FINAL" \
                -j MARK --set-xmark 0x40000/0xff0000 ||
         ! ip6tables -w 5 -t mangle -C MASTER-TS-FORWARD \
                -i tailscale0 -o "$WAN6_IF_FINAL" -j ACCEPT; }; then
        echo "HATA: IPv6 exit-node/WAN DROP kuralları eksik." >&2
        exit 1
    fi
fi

/usr/local/sbin/docker-tailscale-fw --check
progress_stage_note 75 "IPv4/IPv6 firewall omurgası doğrulandı"

direct_webdav_code=""
for _ in $(seq 1 20); do
    direct_webdav_code="$(
        curl -sS -o /dev/null -w '%{http_code}' \
            --noproxy '*' \
            --connect-timeout 2 --max-time 5 \
            -X PROPFIND -H "Depth: 0" \
            "http://${TS_IP}:${WEBDAV_PORT}/" || true
    )"
    [[ "$direct_webdav_code" == "401" ]] && break
    sleep 1
done
if [[ "$direct_webdav_code" != "401" ]]; then
    echo "HATA: Doğrudan Tailnet WebDAV beklenen 401 yerine ${direct_webdav_code} döndürdü." >&2
    exit 1
fi
echo "Doğrudan Tailnet WebDAV doğrulandı: ${TS_IP}:${WEBDAV_PORT} -> HTTP ${direct_webdav_code}"
progress_stage_note 85 "Doğrudan Tailnet WebDAV erişimi doğrulandı"

echo
echo "--- dnsmasq ve Caddy ---"
for unit in dnsmasq.service caddy.service; do
    if ! systemctl is-active --quiet "$unit"; then
        echo "HATA: Tailnet DNS/Caddy servisi aktif değil: $unit" >&2
        systemctl --no-pager --full status "$unit" || true
        exit 1
    fi
done
systemctl --no-pager --full status dnsmasq caddy

for name in portainer file qbit wg webdav health; do
    answer="$(dig +short A "${name}.${LOCAL_DOMAIN}" @"${TS_IP}" 2>/dev/null | head -n 1 || true)"
    if [[ "$answer" != "$TS_IP" ]]; then
        echo "HATA: ${name}.${LOCAL_DOMAIN} beklenen A kaydını döndürmedi." >&2
        exit 1
    fi
done
echo "DNS A kayıtları doğrulandı: $TS_IP"

HEALTH_BODY="$(
    curl --noproxy '*' -fsS \
        --connect-timeout 2 --max-time 4 \
        -H "Host: health.${LOCAL_DOMAIN}" \
        "http://${TS_IP}/" 2>/dev/null || true
)"
if [[ "$HEALTH_BODY" != "ok" ]]; then
    echo "HATA: Caddy health uç noktası beklenen 'ok' yanıtını vermedi." >&2
    exit 1
fi

MASTER_STACK_LOCK_HELD=1 \
    /usr/local/sbin/master-network-reconcile --check
progress_stage_note 90 "DNS, Caddy ve kalan systemd durumları denetleniyor"

FAILED_UNITS="$(systemctl --failed --no-legend 2>/dev/null || true)"
if [[ -n "$FAILED_UNITS" ]]; then
    echo
    echo "UYARI: Başarısız systemd unit'leri var:" >&2
    printf '%s\n' "$FAILED_UNITS" >&2
fi

WG_INTERNAL_PORT="$(docker exec wg-easy wg show wg0 listen-port 2>/dev/null || true)"
wg_ui_probe || true
WG_SETUP_LOCATION="$WG_UI_LOCATION"

progress_stage_note 95 "Timer'lar geri yüklenip systemd kayıtları denetleniyor"
systemctl stop apt-daily.timer apt-daily-upgrade.timer \
    >/dev/null 2>&1 || true
if [[ "$APT_DAILY_TIMER_WAS_ACTIVE" -eq 1 ]]; then
    systemctl start apt-daily.timer
fi
APT_DAILY_TIMER_REENABLED=1
if [[ "$APT_DAILY_UPGRADE_TIMER_WAS_ACTIVE" -eq 1 ]]; then
    systemctl start apt-daily-upgrade.timer
fi
APT_DAILY_UPGRADE_TIMER_REENABLED=1

CUSTOM_GRAPH_ERRORS="$(
    journalctl --since "$MASTER_SETUP_STARTED_AT" --no-pager -o cat \
        -u docker.service \
        -u tailscaled.service \
        -u docker-tailscale-fw.service \
        -u master-compose.service \
        -u master-docker-netfilter-recovery.service \
        -u master-network-reconcile.service \
        -u caddy.service \
        -u dnsmasq.service 2>/dev/null |
        grep -Ei 'ordering cycle|deleted to break ordering cycle|dependency failed|start-limit-hit' ||
        true
)"
if [[ -n "$CUSTOM_GRAPH_ERRORS" ]]; then
    echo "HATA: Kurulum sırasında custom servis grafiği hatası tespit edildi:" >&2
    printf '%s\n' "$CUSTOM_GRAPH_ERRORS" >&2
    exit 1
fi

echo "Custom systemd grafiği doğrulandı; ordering/dependency çakışması yok."
append_master_service_journal
progress_stage_note 99 "Tüm çalışma ve bağlantı testleri tamamlandı"

{
    echo
    echo "--- Başarılı kurulum özeti ---"
    printf 'Sürüm: %s\n' "$MASTER_SETUP_VERSION"
    printf 'WAN arayüzü: %s\n' "$WAN4_IF"
    printf 'Bağlanan IPv4: %s\n' "$PUBLIC_IPV4"
    printf 'Tailscale IPv4: %s\n' "$TS_IP"
    printf 'İndirme dizini: %s\n' "$DOWNLOADS_PATH"
    printf 'Zaman dilimi: %s\n' "$TIMEZONE"
    printf 'qBittorrent public: %s:%s/tcp+udp\n' \
        "$PUBLIC_IPV4" "$QBIT_PUBLIC_PORT"
    printf 'wg-easy public: %s:%s/udp\n' \
        "$PUBLIC_IPV4" "$WG_PUBLIC_PORT"
    printf 'WebDAV Tailnet: http://%s:%s\n' "$TS_IP" "$WEBDAV_PORT"
    printf 'Tailnet yerel DNS: *.%s -> %s\n' "$LOCAL_DOMAIN" "$TS_IP"
    printf 'Bitiş: %s\n' "$(date --iso-8601=seconds)"
} >>"$MASTER_LOG_FILE"

progress_stage_done
progress_restore_output
progress_close_tty

echo
echo "=================================================="
echo "  KURULUM TAMAMLANDI"
echo "=================================================="
echo "WAN arayüzü       : $WAN4_IF"
echo "Bağlanan IPv4     : $PUBLIC_IPV4"
echo "Tailscale IPv4    : $TS_IP"
echo "İndirme dizini    : $DOWNLOADS_PATH"
echo "Zaman dilimi      : $TIMEZONE"
echo "Otomatik reboot   : Kapalı (manuel: systemctl reboot)"
echo "Ağ uzlaştırma     : 20 dakikada bir düşük maliyetli güvenlik kontrolü"
echo "                    (çökmeler OnFailure ile anında kurtarılır)"
echo "Oneshot kurtarma  : İç restart yok; Docker/Tailscale olayı + reconcile"
echo "Kurulum logu      : $MASTER_LOG_FILE"
echo "Durum özeti       : master-network-reconcile --status"
echo "                    (kurulu sürüm/hash, container'lar ve çalışan"
echo "                    image digest'leri, --check sonucu)"
echo
echo "UYARI: Aşağıdaki yönetilen dosyalar 20 dakikada bir bu kurulumun ürettiği"
echo "canonical kopyayla karşılaştırılır; kaynağı ne olursa olsun (elle yapılan"
echo "bir değişiklik dahil) sapma tespit edilirse sessizce eski haline"
echo "döndürülür. Kalıcı bir değişiklik için install.sh'i düzenleyip yeniden"
echo "çalıştırın:"
echo "  /etc/master-stack/state.env"
echo "  /etc/dnsmasq.d/local-services.conf, /etc/caddy/Caddyfile"
echo "  ve ilgili systemd drop-in'leri"
echo
echo "UYARI: docker-tailscale-fw.service, master-compose.service ve"
echo "caddy.service systemd"
echo "PartOf ile docker.service ve/veya tailscaled.service'e bağlıdır."
echo "'systemctl restart tailscaled' veya 'systemctl restart docker' gibi"
echo "rutin bir komut, firewall'u, tüm Compose stack'ini ve Caddy'yi de birlikte"
echo "durdurup yeniden başlatır. Bu, sistemin sıralamayı ve tutarlılığı"
echo "korumasını sağlayan kasıtlı bir tasarımdır."
echo
echo "Public IPv4 portları:"
echo "  qBittorrent peer: ${PUBLIC_IPV4}:${QBIT_PUBLIC_PORT}/tcp+udp"
echo "  wg-easy Docker  : ${PUBLIC_IPV4}:${WG_PUBLIC_PORT}/udp"
echo
echo "UYARI: Portainer ve wg-easy yönetici hesaplarını script oluşturmaz;"
echo "her birinin ilk web erişiminde admin hesabını hemen siz oluşturun."
echo "Bu servisler yalnız 127.0.0.1/tailnet üzerinden erişilebilir olsa da,"
echo "oluşturulmamış bir admin hesabı tailnet'teki başka bir cihazın önce"
echo "erişip kurulumu tamamlamasına açık kalır."
echo "  Portainer: https://127.0.0.1:9443 veya http://portainer.${LOCAL_DOMAIN}"
echo "  wg-easy  : http://127.0.0.1:51821 veya http://wg.${LOCAL_DOMAIN}"
echo
echo "!! EN ÖNCELİKLİ ADIM: filebrowser (Quantum) admin parolası."
echo "Portainer ve wg-easy hesapsız gelir; Quantum ondan FARKLI:"
echo "ÇALIŞAN bir varsayılan kimlikle açılır."
echo "  Kullanıcı: admin   Parola: admin"
echo "İlk iş olarak http://file.${LOCAL_DOMAIN} adresine girip parolayı"
echo "değiştirin. Değiştirene kadar tailnet'teki her cihaz medya ağacına"
echo "tam yetkiyle erişebilir. Quantum ilk girişte uyarı gösterir ama"
echo "değişikliği zorlamaz — bu adım tamamen sizde."
echo "Hesabı betik değil container yaratır (bilinçli; bkz. DD-27), yani"
echo "parolayı yalnız arayüzden değiştirebilirsiniz."
echo
echo "ELLE AYAR: qBittorrent soket alma buffer'ı."
echo "Bu betik qBittorrent'in yapılandırmasını yönetmez, dolayısıyla taze bir"
echo "kurulumda bu ayar sistem varsayılanına (208 KB) döner. 2026-07-29'da"
echo "yaklaşık 278 MB/s'lik gerçek bir indirmede ölçüldü: 208 KB ile uTP/DHT"
echo "soketi doyup paket düşürüyor, ayarlandığında aynı yükte drop sıfırlanıyor."
echo "  Tools > Options > Advanced > Socket receive buffer size"
echo "  Önerilen: 16777216 (16 MiB). Çekirdek isteği net.core.rmem_max ile"
echo "  kırpar; bu kurulum o tavanı en az 16 MiB olacak şekilde garanti eder."
echo
WEBDAV_SUMMARY_USER="$(
    awk -F: 'NF >= 2 {print $1; exit}' "$WEBDAV_HTPASSWD_FILE" 2>/dev/null || true
)"
echo "WebDAV (host rclone servisi, salt okunur):"
echo "  Sunulan dizin : ${DOWNLOADS_PATH}/media"
echo "  Kullanıcı adı : ${WEBDAV_SUMMARY_USER:-<htpasswd okunamadı>}"
echo "  Parola        : Aşama 0'da belirlediğiniz parola"
echo "  Adres         : ${TS_IP} veya webdav.${LOCAL_DOMAIN}"
echo "  Port          : ${WEBDAV_PORT}"
echo "  Protokol      : WebDAV (HTTP, HTTPS değil)"
echo "  Tam URL       : http://${TS_IP}:${WEBDAV_PORT}"
echo "  Kimlik dosyası: /etc/master-stack/webdav.htpasswd (bcrypt)"
echo "  Sıfırlama     : dosyayı silip install.sh'i yeniden çalıştırın"
echo
echo "filebrowser (Quantum) yalnız şu dizini görür:"
echo "  ${DOWNLOADS_PATH}/media -> /srv"
echo "  Politika dosyası: ${QUANTUM_CONFIG_FILE} (sır içermez)"
echo "  Durum/veritabanı : filebrowser_data volume'u"
echo
echo "Unpackerr:"
echo "  İzlenen medya ağacı : ${DOWNLOADS_PATH}/media (tüm alt klasörler)"
echo "  Container yolu      : /downloads"
echo "  Tarama aralığı      : 10 saniye"
echo "  İç içe arşivler     : Açılır"
echo "  Çıkarma konumu      : Arşivin bulunduğu klasör"
echo "  RAR dosyaları       : Silinmez; seeding korunur"
echo "  qBittorrent kayıt yolu /downloads altında herhangi bir klasör olabilir."

if [[ "$WG_INTERNAL_PORT" == "$WG_PUBLIC_PORT" ]]; then
    echo
    echo "wg-easy WireGuard: hazır (container wg0 = ${WG_INTERNAL_PORT}/udp)"
elif [[ "$WG_SETUP_LOCATION" == /setup/* ]]; then
    echo
    echo "UYARI: wg-easy ilk web kurulumu henüz tamamlanmadı."
    echo "  Docker public yayını hazır; fakat wg0 şu anda ${WG_INTERNAL_PORT:-bilinmiyor}/udp dinliyor."
    echo "  wg-easy kurulum ekranında Host=${PUBLIC_IPV4}, Port=${WG_PUBLIC_PORT} seçin."
    echo "  Bu işlem yapılana kadar ${PUBLIC_IPV4}:${WG_PUBLIC_PORT}/udp VPN hizmeti vermez."
else
    echo
    echo "UYARI: wg-easy container iç portu ${WG_INTERNAL_PORT:-tespit edilemedi}; beklenen ${WG_PUBLIC_PORT}."
    echo "  wg-easy ayarındaki WireGuard portunu ${WG_PUBLIC_PORT} olarak düzeltin."
fi

echo
echo "Tailnet servis adresleri:"
echo "  http://portainer.${LOCAL_DOMAIN}"
echo "  http://file.${LOCAL_DOMAIN}"
echo "  http://qbit.${LOCAL_DOMAIN}"
echo "  http://wg.${LOCAL_DOMAIN}"
echo "  http://webdav.${LOCAL_DOMAIN}"
echo
echo "Tailscale Admin -> DNS -> Nameservers -> Custom:"
echo "  Nameserver IP      : $TS_IP"
echo "  Restrict to domain : $LOCAL_DOMAIN"
echo
echo "NOT: dnsmasq ve Caddy güncel tailscale0 IPv4'ünü dinamik kullanır."
echo "Tailscale cihazı silinip yeniden kaydedilirse yalnız Admin DNS nameserver"
echo "adresinin yeni Tailscale IPv4 ile güncellenmesi gerekir."

echo
echo "Tailscale Admin -> Machines bölümünde:"
echo "  1. Exit node route'unu onaylayın."
echo "  2. Güvenilir sunucu için key expiry politikasını kontrol edin."

if [[ -f /run/reboot-required ]]; then
    echo
    echo "=================================================="
    echo "  SİSTEM YENİDEN BAŞLATMA GEREKTİRİYOR"
    echo "=================================================="
    if [[ -r /run/reboot-required.pkgs ]]; then
        echo "İlgili paketler:"
        sed 's/^/  - /' /run/reboot-required.pkgs
    fi
    echo
    echo "Otomatik reboot yapılmayacak."
    echo "Hazır olduğunuzda konsoldan çalıştırın: systemctl reboot"
else
    echo
    echo "Sistem şu anda zorunlu reboot bildirmiyor."
    echo "İhtiyaç halinde manuel reboot: systemctl reboot"
fi
