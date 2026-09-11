#!/usr/bin/env bash
# Linux/root only. All restore targets are isolated mktemp directories.
# Optional argument: a real archive to validate and restore in isolation.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../dev/container-backup-remote.sh
source "$TEST_ROOT/dev/container-backup-remote.sh"
(( EUID == 0 )) || fail 'Run this isolated test as root on Linux.'
TEST_DIR=$(mktemp -d /tmp/master-stack-backup-test.XXXXXXXX)
test_cleanup() { rm -rf -- "$TEST_DIR"; }
trap test_cleanup EXIT
WORK="$TEST_DIR/work"
mkdir "$WORK"
for c in "${SERVICES[@]}"; do DATA[$c]="$TEST_DIR/$c"; mkdir "${DATA[$c]}"; done
mkdir -p "${DATA[qbittorrent]}/qBittorrent/BT_backup" "${DATA[filebrowser]}/config" "${DATA[portainer]}/bin" "${DATA[portainer]}/backups"
printf 'portainer fixture\n' >"${DATA[portainer]}/portainer.db"
printf 'filebrowser fixture\n' >"${DATA[filebrowser]}/filebrowser.db"
printf '{}\n' >"${DATA[filebrowser]}/config/settings.json"
printf 'preferences fixture\n' >"${DATA[qbittorrent]}/qBittorrent/qBittorrent.conf"
printf 'categories must survive\n' >"${DATA[qbittorrent]}/qBittorrent/categories.json"
printf 'torrent must survive\n' >"${DATA[qbittorrent]}/qBittorrent/BT_backup/torrent.fastresume"
printf 'cache must survive\n' >"${DATA[portainer]}/bin/cache"
printf 'old backup must survive\n' >"${DATA[portainer]}/backups/prior.db"
printf 'wg database fixture\n' >"${DATA[wg-easy]}/wg-easy.db"
printf 'wg config fixture\n' >"${DATA[wg-easy]}/wg0.conf"
chmod 640 "${DATA[filebrowser]}/filebrowser.db"
chown 1000:1000 "${DATA[filebrowser]}" "${DATA[filebrowser]}/filebrowser.db"
jq -n '["filebrowser","portainer","qbittorrent","wg-easy"] |
    map({name:.,image:"fixture",image_id:"sha256:fixture",user:"",ids:[],ports:{}}) |
    map(if .name=="qbittorrent" then
        .ids=["PGID=1000","PUID=1000"] |
        .ports={"61006/tcp":[{HostIp:"127.0.0.1",HostPort:"61006"}]}
    else . end)' >"$WORK/services.json"
snapshot "$WORK/source" settings
pack "$WORK/source" "$WORK/source.tar.gz"
validate_bundle "$WORK/source.tar.gz" "$WORK/validated"
check_target "$WORK/validated"
cp "$WORK/services.json" "$WORK/original-services.json"
# Docker environment order is not a user/group setting. Existing schema-1
# archives can contain either order; both sides must be compared by value.
jq 'map(if .name=="qbittorrent" then .ids |= reverse else . end)' \
    "$WORK/original-services.json" >"$WORK/services.json"
check_target "$WORK/validated"
mkdir "$WORK/reordered-source"
jq '.services |= map(if .name=="qbittorrent" then .ids |= reverse else . end)' \
    "$WORK/validated/manifest.json" >"$WORK/reordered-source/manifest.json"
cp "$WORK/original-services.json" "$WORK/services.json"
check_target "$WORK/reordered-source"
printf 'PASS: PUID/PGID ordering is ignored in existing backups and live targets\n'
for setting in PUID PGID; do
    jq --arg setting "$setting" 'map(if .name=="qbittorrent" then
        .ids |= map(if startswith($setting+"=") then $setting+"=2000" else . end)
    else . end)' "$WORK/original-services.json" >"$WORK/services.json"
    set +e
    (check_target "$WORK/validated") >"$WORK/target-reject.log" 2>&1
    rc=$?
    set -e
    (( rc != 0 )) || fail "A genuinely different $setting must be rejected."
    grep -Fq 'qbittorrent ids:' "$WORK/target-reject.log"
    grep -Fq "$setting=2000" "$WORK/target-reject.log"
done
jq 'map(if .name=="qbittorrent" then .ports["61006/tcp"][0].HostPort="61008" else . end)' \
    "$WORK/original-services.json" >"$WORK/services.json"
set +e
(check_target "$WORK/validated") >"$WORK/target-reject.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'A changed port must still be rejected.'
grep -Fq 'qbittorrent ports:' "$WORK/target-reject.log"
printf 'PASS: genuine PUID, PGID and port changes remain rejected\n'
# A fresh v73 install can pull a newer digest under the same moving tag.
# Version changes are warnings, without any explicit override argument.
for c in "${SERVICES[@]}"; do
    jq --arg c "$c" 'map(if .name==$c then .image_id="sha256:different" else . end)' \
        "$WORK/original-services.json" >"$WORK/services.json"
    check_target "$WORK/validated" 2>"$WORK/image-warning.log"
    grep -Fq 'UYARI:' "$WORK/image-warning.log"
done
jq 'map(.image="fixture:new-version" | .image_id="sha256:new-version")' \
    "$WORK/original-services.json" >"$WORK/services.json"
check_target "$WORK/validated" 2>"$WORK/image-warning.log"
grep -Fq 'UYARI:' "$WORK/image-warning.log"
printf 'PASS: changed image digests/tags warn but allow transfer by default\n'
jq '.[0].user="different"' "$WORK/original-services.json" >"$WORK/services.json"
set +e
(check_target "$WORK/validated") >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'A changed runtime user must still be rejected.'
cp "$WORK/original-services.json" "$WORK/services.json"
printf 'PASS: target user incompatibility rejected before writes\n'
[[ ! -e "$WORK/validated/qbittorrent/categories.json" && ! -e "$WORK/validated/portainer/bin" ]]
printf 'changed preference\n' >"${DATA[qbittorrent]}/qBittorrent/qBittorrent.conf"
printf 'extra stale file\n' >"${DATA[wg-easy]}/obsolete"
snapshot "$WORK/rollback" rollback
apply_tree "$WORK/validated"
[[ ! -e "${DATA[wg-easy]}/obsolete" ]]
cmp "$WORK/validated/qbittorrent/qBittorrent.conf" "${DATA[qbittorrent]}/qBittorrent/qBittorrent.conf"
[[ $(stat -c '%a:%u:%g' "${DATA[filebrowser]}/filebrowser.db") == 640:1000:1000 ]]
[[ $(cat "${DATA[qbittorrent]}/qBittorrent/categories.json") == 'categories must survive' ]]
[[ -f "${DATA[qbittorrent]}/qBittorrent/BT_backup/torrent.fastresume" && -f "${DATA[portainer]}/bin/cache" && -f "${DATA[portainer]}/backups/prior.db" ]]
printf 'PASS: archive roundtrip, UID/GID/modes, excluded files preserved\n'

# Exercise the actual EXIT recovery handler without touching any real container.
# shellcheck disable=SC2329 # Called by the sourced EXIT recovery handler.
docker() { printf '%s\n' "$*" >>"$TEST_DIR/docker-calls"; }
set +e
(
    RESTORING=1
    RESTART=(fixture-container)
    trap finish EXIT
    exit 17
)
rc=$?
set -e
[[ "$rc" == 17 ]]
[[ -f "${DATA[wg-easy]}/obsolete" ]]
cmp "$WORK/rollback/qbittorrent/qBittorrent.conf" "${DATA[qbittorrent]}/qBittorrent/qBittorrent.conf"
grep -q '^stop -t 45 fixture-container$' "$TEST_DIR/docker-calls"
grep -q '^start fixture-container$' "$TEST_DIR/docker-calls"
unset -f docker
printf 'PASS: failed restore returns previous state and restarts the original container\n'

# A clean wg-easy is running but unconfigured/unhealthy; safety backups must
# preserve that baseline so the subsequent restore can configure it.
jq -n '[{name:"wg-easy",health:"unhealthy"}]' >"$WORK/clean-health.json"
# shellcheck disable=SC2329 # Called inside wait_services.
docker() { printf '/wg-easy true unhealthy false\n'; }
RESTART=(fixture-wg)
wait_services "$WORK/clean-health.json"
RESTART=()
unset -f docker
printf 'PASS: unconfigured wg-easy does not block the pre-restore safety backup\n'

expect_rejection() {
    local archive=$1 label=$2 rc
    set +e
    (set -e; validate_bundle "$archive" "$WORK/rejected-$label") >"$WORK/reject.log" 2>&1
    rc=$?
    set -e
    (( rc != 0 )) || fail "Archive should have been rejected: $label"
    printf 'PASS: rejected %s archive\n' "$label"
}
mkdir "$WORK/evil"
printf 'not a config\n' >"$WORK/evil/file"
tar -C "$WORK/evil" -czf "$WORK/traversal.tar.gz" --transform='s#file#../escape#' file
expect_rejection "$WORK/traversal.tar.gz" traversal
[[ ! -e "$WORK/escape" ]]
tar -C "$WORK/evil" -czf "$WORK/absolute.tar.gz" --transform='s#file#/tmp/escape#' file
expect_rejection "$WORK/absolute.tar.gz" absolute
ln -s /etc "$WORK/evil/link"
tar -C "$WORK/evil" -czf "$WORK/symlink.tar.gz" link
expect_rejection "$WORK/symlink.tar.gz" symlink
ln "$WORK/evil/file" "$WORK/evil/hardlink"
tar -C "$WORK/evil" -czf "$WORK/hardlink.tar.gz" file hardlink
expect_rejection "$WORK/hardlink.tar.gz" hardlink
printf 'changed after checksum\n' >>"$WORK/source/qbittorrent/qBittorrent.conf"
pack "$WORK/source" "$WORK/tampered.tar.gz"
expect_rejection "$WORK/tampered.tar.gz" tampered
printf '{}\n' >"$WORK/source/qbittorrent/categories.json"
pack "$WORK/source" "$WORK/out-of-scope.tar.gz"
expect_rejection "$WORK/out-of-scope.tar.gz" out-of-scope

if [[ -n ${1:-} ]]; then
    validate_bundle "$1" "$WORK/real"
    apply_tree "$WORK/real"
    snapshot "$WORK/real-roundtrip" settings
    jq -e --slurpfile actual "$WORK/real-roundtrip/manifest.json" '.files==$actual[0].files' "$WORK/real/manifest.json" >/dev/null
    apply_tree "$WORK/rollback"
    printf 'PASS: real backup restored to isolated targets; all hashes/ownership/modes matched\n'
fi
printf 'ALL BACKUP TESTS PASSED (no production restore)\n'
