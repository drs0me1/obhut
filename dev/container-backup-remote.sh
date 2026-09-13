#!/usr/bin/env bash
# SSH üzerinden çağrılan Linux yardımcısı; kurulum paketine dahil edilmez.
set -Eeuo pipefail
umask 077
export LC_ALL=C

SERVICES=(portainer filebrowser qbittorrent wg-easy)
# Her servisten yalnız operatörün oluşturduğu durumu tutan dosya: hesaplar,
# parolalar, qBittorrent tercihleri, wg-easy peer'ları. Anahtarlar, sertifikalar,
# wg0.conf ve imaj varsayılan ayarları kurulum/uygulama yeniden üretir (DD-114).
declare -A SCOPE=([portainer]=portainer.db [filebrowser]=filebrowser.db
    [qbittorrent]=qBittorrent/qBittorrent.conf [wg-easy]=wg-easy.db)
declare -A DATA=() IDS=()
RESTART=()
RESTORING=0
WORK=""

say() { printf '%s\n' "$*" >&2; }
fail() { say "HATA: $*"; exit 1; }

discover() {
    local c dest src kind volume config_src
    docker inspect "${SERVICES[@]}" >"$WORK/inspect.json"
    for c in "${SERVICES[@]}"; do
        case "$c" in
            portainer) dest=/data; kind=volume ;;
            filebrowser) dest=/database; kind=bind ;;
            qbittorrent) dest=/config; kind=volume ;;
            wg-easy) dest=/etc/wireguard; kind=volume ;;
        esac
        jq -e --arg c "$c" '
            .[] | select(.Name == "/"+$c) |
            .Config.Labels["com.docker.compose.service"] == $c and
            .State.Paused == false and .State.Restarting == false
        ' "$WORK/inspect.json" >/dev/null || fail "$c: beklenen Compose konteyneri bulunamadı."
        src=$(jq -er --arg c "$c" --arg dest "$dest" --arg kind "$kind" '
            [.[] | select(.Name == "/"+$c) | .Mounts[] |
             select(.Destination == $dest and .Type == $kind and .RW == true)] |
            if length == 1 then .[0].Source else error("mount") end
        ' "$WORK/inspect.json")
        [[ "$src" =~ ^/[a-zA-Z0-9_./-]+$ && "$src" != *'/../'* ]] || fail "Geçersiz veri yolu: $c"
        [[ -d "$src" && "$(realpath -e "$src")" == "$src" ]] || fail "$c: veri yolu symlink veya eksik."
        if [[ "$kind" == volume ]]; then
            volume=$(jq -er --arg c "$c" --arg dest "$dest" '
                .[] | select(.Name == "/"+$c) | .Mounts[] | select(.Destination==$dest) | .Name
            ' "$WORK/inspect.json")
            docker volume inspect "$volume" | jq -e --arg src "$src" '
                .[0] | .Mountpoint==$src and .Driver=="local" and ((.Options // {}) | length)==0
            ' >/dev/null || fail "$c: yalnız yerel Docker volume desteklenir."
            [[ "$src" == */volumes/"$volume"/_data ]] || fail "$c: beklenmeyen volume yolu."
        else
            [[ "$src" == /etc/master-stack/filebrowser-data ]] || fail "FileBrowser veri yolu desteklenen kurulumla eşleşmiyor."
            config_src=$(jq -er '.[] | select(.Name=="/filebrowser") | .Mounts[] |
                select(.Destination=="/config" and .Type=="bind") | .Source' "$WORK/inspect.json")
            [[ "$config_src" == "$src/config" && ! -L "$config_src" ]] || fail "FileBrowser /config bağlantısı eşleşmiyor."
        fi
        DATA[$c]=$src
        IDS[$c]=$(jq -r --arg c "$c" '.[] | select(.Name=="/"+$c) | .Id' "$WORK/inspect.json")
        say "$c: $dest → $src"
    done
    jq '[.[] | {name:(.Name | ltrimstr("/")), image:.Config.Image, image_id:.Image,
        running:.State.Running, health:(.State.Health.Status // "none"),
        user:.Config.User, ids:([.Config.Env[]? | select(startswith("PUID=") or startswith("PGID="))] | sort),
        ports:.HostConfig.PortBindings}] | sort_by(.name)' "$WORK/inspect.json" >"$WORK/services.json"
}

stop_services() {
    local c running
    for c in "${SERVICES[@]}"; do
        running=$(docker inspect -f '{{.State.Running}}' "${IDS[$c]}")
        if [[ "$running" == true ]]; then
            RESTART+=("${IDS[$c]}")
            say "$c durduruluyor (tutarlı veritabanı kopyası)..."
            docker stop -t 45 "${IDS[$c]}" >/dev/null
            [[ $(docker inspect -f '{{.State.ExitCode}}' "${IDS[$c]}") != 137 ]] || fail "$c zorla kapandı; yedek kullanılmayacak."
        fi
        [[ $(docker inspect -f '{{.State.Running}}' "${IDS[$c]}") == false ]] || fail "$c durmadı."
    done
}

start_services() {
    local id failed=0
    for id in "${RESTART[@]}"; do
        docker start "$id" >/dev/null || failed=1
    done
    return "$failed"
}

wait_services() {
    local baseline=${1:-} id state name running health restarting ready deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        ready=1
        for id in "${RESTART[@]}"; do
            state=$(docker inspect -f '{{.Name}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.Restarting}}' "$id")
            read -r name running health restarting <<<"$state"
            if [[ "$running" != true || "$restarting" != false ]]; then ready=0; continue; fi
            if [[ "$health" != healthy && "$health" != none ]]; then
                if [[ -z "$baseline" ]] || [[ $(jq -r --arg c "${name#/}" '.[]|select(.name==$c)|.health' "$baseline") == healthy ]]; then
                    ready=0
                fi
            fi
        done
        (( ready )) && return 0
        sleep 2
    done
    say "Konteynerler 120 saniyede hazır olmadı."
    return 1
}

inventory() {
    local root=$1 rel digest
    (
        cd "$root"
        find portainer filebrowser qbittorrent wg-easy -type f -print | sort |
        while IFS= read -r rel; do
            digest=$(sha256sum "$rel"); digest=${digest%% *}
            jq -cn --arg path "$rel" --arg sha "$digest" \
                --arg stat "$(stat -c '%a:%u:%g' "$rel")" '{path:$path,sha256:$sha,stat:$stat}'
        done
    ) | jq -s .
}

snapshot() {
    local out=$1 kind=$2 c entry side
    mkdir -m 700 "$out"
    for c in "${SERVICES[@]}"; do
        mkdir -m 700 "$out/$c"
        entry="${DATA[$c]}/${SCOPE[$c]}"
        [[ ! -e "$entry" || "$(realpath -e "$entry")" == "$entry" ]] || fail "$c: ${SCOPE[$c]} yolunda symlink olamaz."
        # Temiz kapanışta SQLite yan dosyalarını boşaltır; dolu kalmışsa tek
        # veritabanı dosyası eksik olur.
        for side in -wal -journal; do
            [[ ! -s "$entry$side" ]] || fail "$c: ${SCOPE[$c]}$side dolu; uygulama temiz kapanmadı, yedek alınmadı."
        done
        if [[ -f "$entry" ]]; then cp -a "$entry" "$out/$c/"; fi
    done
    # Only regular files and directories with portable names enter the format.
    find "$out" -mindepth 1 -printf '%y %P\n' >"$WORK/tree.txt"
    awk '$1 !~ /^[fd]$/ || $2 !~ /^[a-zA-Z0-9_.\/-]+$/ || NF!=2 {exit 1}' "$WORK/tree.txt" ||
        fail "Desteklenmeyen dosya adı/symlink/özel dosya; yedek oluşturulmadı."
    if [[ "$kind" == settings ]]; then
        for c in "${SERVICES[@]}"; do
            entry="$c/${SCOPE[$c]##*/}"
            [[ -s "$out/$entry" ]] || fail "Ayarlanmış kaynak dosyası eksik: $entry"
        done
    fi
    inventory "$out" >"$WORK/files.json"
    jq -n --arg kind "$kind" --arg date "$(date -u +%FT%TZ)" --arg host "$(hostname)" \
        --slurpfile services "$WORK/services.json" --slurpfile files "$WORK/files.json" \
        '{format:"master-stack-settings",schema:1,kind:$kind,created_utc:$date,source_host:$host,
          services:$services[0],files:$files[0]}' >"$out/manifest.json"
}

pack() {
    tar --format=ustar --hard-dereference --numeric-owner -C "$1" -czf "$2" \
        manifest.json portainer filebrowser qbittorrent wg-easy
    chmod 600 "$2"
}

validate_bundle() {
    local archive=$1 out=$2 rel
    [[ -f "$archive" && ! -L "$archive" ]] || fail "Yedek dosyası bulunamadı."
    (( $(stat -c %s "$archive") <= 536870912 )) || fail "Yedek 512 MiB sınırını aşıyor."
    timeout 60 tar -tzf "$archive" >"$WORK/names.txt"
    timeout 60 tar --numeric-owner -tvzf "$archive" >"$WORK/types.txt"
    awk '
        substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}
        {bytes+=$3; if (bytes>1073741824 || NR>20000) exit 1}
    ' "$WORK/types.txt" || fail "Arşivde bağlantı/özel dosya var veya boyut sınırı aşıldı."
    while IFS= read -r rel; do
        rel=${rel%/}
        [[ "$rel" =~ ^[a-zA-Z0-9_./-]+$ && "/$rel/" != *'/../'* && "/$rel/" != *'/./'* && "$rel" != *'//'* ]] || fail "Geçersiz arşiv yolu."
        case "$rel" in
            manifest.json|portainer|filebrowser|qbittorrent|wg-easy|portainer/*|filebrowser/*|wg-easy/*|qbittorrent/qBittorrent.conf) ;;
            *) fail "Yedek kapsamı dışında dosya: $rel" ;;
        esac
        case "$rel" in portainer/bin|portainer/bin/*|portainer/backups|portainer/backups/*) fail "Portainer önbelleği/eski yedek kapsam dışında." ;; esac
    done <"$WORK/names.txt"
    [[ -z $(sed 's:/$::' "$WORK/names.txt" | sort | uniq -d) ]] || fail "Arşivde tekrarlanan yol."
    mkdir -m 700 "$out"
    tar --extract --gzip --file "$archive" --directory "$out" --numeric-owner --same-owner --same-permissions --delay-directory-restore
    jq -e '.format=="master-stack-settings" and .schema==1 and
        (.kind=="settings" or .kind=="rollback") and
        ([.services[].name] | sort)==["filebrowser","portainer","qbittorrent","wg-easy"]' \
        "$out/manifest.json" >/dev/null || fail "Yedek biçimi desteklenmiyor."
    for rel in "${SERVICES[@]}"; do [[ -d "$out/$rel" ]] || fail "Yedekte servis eksik: $rel"; done
    inventory "$out" >"$WORK/actual.json"
    jq -e --slurpfile actual "$WORK/actual.json" '.files==$actual[0]' "$out/manifest.json" >/dev/null || fail "Dosya SHA256/sahiplik/izin doğrulaması başarısız."
    local c scoped=0 side
    for c in "${SERVICES[@]}"; do
        rel="$c/${SCOPE[$c]##*/}"
        for side in -wal -journal; do
            [[ ! -s "$out/$rel$side" ]] || fail "Yedekte dolu SQLite yan dosyası var: $rel$side"
        done
        if [[ -f "$out/$rel" ]]; then scoped=$((scoped + 1)); fi
        if [[ $(jq -r .kind "$out/manifest.json") == settings ]]; then
            [[ -s "$out/$rel" ]] || fail "Yedekte gerekli dosya eksik: $rel"
        fi
    done
    # 2026-09-13 öncesi yedekler servis dizinlerinin tamamını taşır.
    if (( $(jq '.files|length' "$out/manifest.json") > scoped )); then
        say "Not: eski kapsamlı yedek; anahtar/sertifika/türetilmiş dosyalar yüklenmez, her servisten yalnız ayar dosyası yüklenir."
    fi
    say "Yedek doğrulandı: $(jq '.files|length' "$out/manifest.json") dosya, yüklenecek $scoped."
}

check_target() {
    local source=$1
    # Older schema-1 backups also need normalization: Docker environment order
    # is not significant, but actual PUID/PGID values must still match exactly.
    if ! jq -e --slurpfile target "$WORK/services.json" '
        [.services[] | {name,user,ids:(.ids | sort),ports}] ==
        [$target[0][] | {name,user,ids:(.ids | sort),ports}]
    ' "$source/manifest.json" >/dev/null; then
        jq -r --slurpfile target "$WORK/services.json" '
            .services[] as $saved | $target[0][] | select(.name==$saved.name) as $live |
            ["user","ids","ports"][] as $field |
            ($saved[$field] | if $field=="ids" then sort else . end) as $a |
            ($live[$field] | if $field=="ids" then sort else . end) as $b |
            select($a!=$b) |
            "\($saved.name) \($field): yedek=\($a | tojson), hedef=\($b | tojson)"
        ' "$source/manifest.json" >&2
        fail "Hedef portları veya kullanıcı UID/GID (PUID/PGID) değerleri kaynakla eşleşmiyor; ayarlar yüklenmedi."
    fi
    if ! jq -e --slurpfile target "$WORK/services.json" '
        [.services[] | {name,image_id}] == [$target[0][] | {name,image_id}]
    ' "$source/manifest.json" >/dev/null; then
        say "UYARI: konteyner imajları farklı; sürüm farkı aktarımı engellemez. Uygulama/veritabanı uyumluluğu garanti edilmez."
    fi
}

# Yalnız dört dosya yazılır; hedefteki diğer her şey (anahtarlar, sertifikalar,
# wg0.conf, önbellekler) kurulumun/uygulamanın bıraktığı gibi kalır. Arşivde
# olmayan kapsam dosyası hedeften kaldırılır: kurtarma anlık kopyası o dosyanın
# işlem öncesi yokluğunu da geri getirir.
apply_tree() {
    local source=$1 c dest dir src tmp side
    for c in "${SERVICES[@]}"; do
        [[ -d "${DATA[$c]}" && "$(realpath -e "${DATA[$c]}")" == "${DATA[$c]}" ]] || return 1
        dest="${DATA[$c]}/${SCOPE[$c]}"
        dir=${dest%/*}
        src="$source/$c/${SCOPE[$c]##*/}"
        if [[ ! -e "$dir" && ! -L "$dir" ]]; then
            # Yalnız qBittorrent/ hiç açılmamış bir uygulamada eksik olabilir.
            mkdir -m 755 "$dir" || return 1
            if [[ -f "$src" ]]; then chown --reference="$src" "$dir" || return 1; fi
        fi
        [[ -d "$dir" && "$(realpath -e "$dir")" == "$dir" && ! -L "$dest" ]] || return 1
        # Hedefte kalan SQLite yan dosyaları geri yüklenen veritabanına işlenmesin.
        for side in -wal -shm -journal; do rm -f -- "$dest$side" || return 1; done
        if [[ -f "$src" ]]; then
            tmp=$(mktemp "$dir/.restore.XXXXXXXX") || return 1
            cp -a "$src" "$tmp" || return 1
            mv -fT "$tmp" "$dest" || return 1
        else
            rm -f -- "$dest" || return 1
        fi
    done
}

finish() {
    local rc=$? id rollback_safe=1
    trap - EXIT HUP INT TERM
    if (( RESTORING )); then
        say "Geri yükleme tamamlanamadı; işlem öncesi ayarlara dönülüyor."
        for id in "${RESTART[@]}"; do docker stop -t 45 "$id" >/dev/null || rollback_safe=0; done
        if (( rollback_safe )); then apply_tree "$WORK/rollback" || rollback_safe=0; fi
        if (( ! rollback_safe )); then
            say "HATA: otomatik geri dönüş başarısız; veri alanları kontrol edilmeden servisler başlatılmayacak. Kurtarma: $WORK/rollback.tar.gz"
            exit 1
        fi
    fi
    if (( ${#RESTART[@]} )); then
        start_services || { say "HATA: bazı konteynerler başlatılamadı."; rc=1; }
    fi
    exit "$rc"
}

main() {
    local action=${1:-inspect} owner_uid owner_gid
    WORK=$(cd -- "$(dirname -- "$0")" && pwd)
    [[ "$WORK" =~ ^/tmp/master-stack-backup\.[a-zA-Z0-9]+$ ]] || fail "Yardımcı yalnız SSH geçici dizininde çalıştırılır."
    if (( EUID != 0 )); then exec sudo -n bash "$0" "$@"; fi
    for cmd in docker jq tar flock sha256sum realpath timeout; do command -v "$cmd" >/dev/null || fail "$cmd gerekli."; done
    owner_uid=$(stat -c %u "$WORK"); owner_gid=$(stat -c %g "$WORK")
    mkdir -p /run/master-stack
    exec 9>/run/master-stack/install.lock
    flock -n 9 || fail "Başka bir kurulum/yedekleme çalışıyor."
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    discover
    # A restore uploads once and runs check and restore in the same directory,
    # so each step replaces what an earlier step left behind.
    case "$action" in
        inspect) cat "$WORK/services.json" ;;
        backup)
            rm -rf -- "$WORK/snapshot"
            stop_services
            snapshot "$WORK/snapshot" settings
            pack "$WORK/snapshot" "$WORK/settings.tar.gz"
            start_services
            wait_services || fail "Yedek alındı ancak servis kontrolü başarısız."
            RESTART=()
            chown "$owner_uid:$owner_gid" "$WORK/settings.tar.gz"
            sha256sum "$WORK/settings.tar.gz" | cut -d ' ' -f1 >"$WORK/settings.sha256"
            chown "$owner_uid:$owner_gid" "$WORK/settings.sha256"
            say "Yedek hazır; önceden çalışan konteynerler yeniden çalışıyor."
            ;;
        check|restore)
            rm -rf -- "$WORK/validated"
            validate_bundle "$WORK/input.tar.gz" "$WORK/validated"
            check_target "$WORK/validated"
            if [[ "$action" == restore ]]; then
                stop_services
                snapshot "$WORK/rollback" rollback
                pack "$WORK/rollback" "$WORK/rollback.tar.gz"
                chown "$owner_uid:$owner_gid" "$WORK/rollback.tar.gz"
                RESTORING=1
                apply_tree "$WORK/validated"
                start_services
                if [[ $(jq -r .kind "$WORK/validated/manifest.json") == rollback ]]; then
                    jq .services "$WORK/validated/manifest.json" >"$WORK/expected-health.json"
                    wait_services "$WORK/expected-health.json" || fail "Kurtarma sonrası servis kontrolü başarısız."
                else
                    wait_services || fail "Servis kontrolü başarısız."
                fi
                RESTORING=0
                RESTART=()
                say "Geri yükleme tamamlandı; konteyner kontrolleri geçti."
            fi
            ;;
        *) fail "Bilinmeyen işlem: $action" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
