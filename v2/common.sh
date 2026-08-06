#!/usr/bin/env bash
# v2 ortak yardımcılar — kısa ve tekrar kullanılanlar.
# Docker / Tailscale / firewall bilmez. Production: Bash 5.x (Debian 13).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf 'HATA: %s source edilmek içindir.\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

V2_LOG_FILE="${V2_LOG_FILE:-}"
V2_LAST_ATOMIC_CHANGED="${V2_LAST_ATOMIC_CHANGED:-0}"

log() {
    local level="$1"
    shift
    local line
    line="[$(date '+%H:%M:%S')] $*"
    case "$level" in
        WARN | HATA) printf '%s\n' "$line" >&2 ;;
        *) printf '%s\n' "$line" ;;
    esac
    if [[ -n "$V2_LOG_FILE" ]]; then
        printf '%s\n' "$line" >>"$V2_LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    log HATA "${1:-bilinmeyen hata}"
    exit "${2:-1}"
}

require_root() {
    [[ "$(id -u)" == "0" ]] || die "bu betik root olarak çalıştırılmalıdır"
}

require_debian_trixie() {
    local f="${V2_OS_RELEASE_PATH:-/etc/os-release}"
    [[ -r "$f" ]] || die "işletim sistemi okunamıyor: $f"
    local id="" codename="" version_id=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ID=*) id="${line#ID=}"; id="${id%\"}"; id="${id#\"}" ;;
            VERSION_CODENAME=*)
                codename="${line#VERSION_CODENAME=}"
                codename="${codename%\"}"
                codename="${codename#\"}"
                ;;
            VERSION_ID=*)
                version_id="${line#VERSION_ID=}"
                version_id="${version_id%\"}"
                version_id="${version_id#\"}"
                ;;
        esac
    done <"$f"
    [[ "$id" == "debian" ]] || die "yalnız Debian desteklenir (ID=${id:-yok})"
    [[ "$codename" == "trixie" ]] || die "yalnız Debian 13 trixie (codename=${codename:-yok})"
    [[ "${version_id%%.*}" == "13" ]] || die "yalnız Debian 13 (VERSION_ID=${version_id:-yok})"
}

acquire_lock() {
    local lock_file="${1:?}" wait_seconds="${2:-5}"
    [[ "$lock_file" == /* && "$lock_file" != / && "$lock_file" != */ ]] ||
        die "kilit yolu mutlak bir dosya olmalıdır"
    command -v flock >/dev/null || die "flock gerekli (util-linux)"
    mkdir -p -- "${lock_file%/*}"
    exec {V2_LOCK_FD}>"$lock_file"
    flock -w "$wait_seconds" "$V2_LOCK_FD" ||
        die "kilit alınamadı (${wait_seconds}s): $lock_file"
}

# retry LABEL ATTEMPTS TIMEOUT -- cmd args...
retry() {
    local label="$1" attempts="$2" budget="$3"
    shift 3
    [[ "${1:-}" == "--" ]] || die "retry: '--' ayırıcısı gerekli"
    shift
    local n=1 status=0
    while [[ "$n" -le "$attempts" ]]; do
        status=0
        # --foreground: tmux/non-TTY altında apt'in SIGTSTP ile T durumunda
        # kalmasını önler (aksi halde paket kurulumu donar).
        timeout --foreground "$budget" "$@" || status=$?
        [[ "$status" -eq 0 ]] && return 0
        log WARN "$label: deneme $n/$attempts başarısız (kod $status)"
        n=$((n + 1))
        [[ "$n" -le "$attempts" ]] && sleep 2
    done
    die "$label: $attempts deneme başarısız (son kod $status)"
}

# atomic_write DEST MODE < stdin
# Sets V2_LAST_ATOMIC_CHANGED to 1 if the file was replaced, 0 if content matched.
atomic_write() {
    local dest="${1:?}" mode="${2:-0644}"
    [[ "$dest" == /* && "$dest" != / ]] || die "atomic_write: mutlak hedef gerekli"
    [[ ! -L "$dest" ]] || die "atomic_write: symlink hedef reddedildi: $dest"
    local dir="${dest%/*}"
    [[ -d "$dir" ]] || die "atomic_write: dizin yok: $dir"
    local tmp
    tmp="$(mktemp "$dir/.v2-XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f -- '$tmp'" RETURN
    cat >"$tmp"
    chmod "$mode" "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        chmod "$mode" "$dest" 2>/dev/null || true
        V2_LAST_ATOMIC_CHANGED=0
        return 0
    fi
    mv -f "$tmp" "$dest"
    V2_LAST_ATOMIC_CHANGED=1
}

# render_template SRC DEST MODE KEY=VALUE...
# Yer tutucu: __KEY__
render_template() {
    local src="${1:?}" dest="${2:?}" mode="${3:?}"
    shift 3
    [[ -f "$src" ]] || die "şablon yok: $src"
    local content key value
    content="$(cat -- "$src")"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "geçersiz şablon anahtarı: $key"
        content="${content//__${key}__/$value}"
    done
    if [[ "$content" =~ __[A-Z][A-Z0-9_]*__ ]]; then
        die "şablonda doldurulmamış yer tutucu kaldı: $src"
    fi
    local awtmp
    awtmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f -- '$awtmp'" RETURN
    printf '%s' "$content" >"$awtmp"
    atomic_write "$dest" "$mode" <"$awtmp"
}
