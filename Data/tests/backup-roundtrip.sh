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
QB="${DATA[qbittorrent]}/qBittorrent"
mkdir -p "$QB/BT_backup" "${DATA[filebrowser]}/config"
# In scope: what the operator creates — accounts, passwords, peers, preferences.
printf 'filebrowser users fixture\n' >"${DATA[filebrowser]}/filebrowser.db"
printf 'preferences fixture\n' >"$QB/qBittorrent.conf"
printf 'wg account and peers fixture\n' >"${DATA[wg-easy]}/wg-easy.db"
# Out of scope: produced by the install or by the application on start.
printf '{"port":80}\n' >"${DATA[filebrowser]}/config/settings.json"
printf 'rendered from wg-easy.db\n' >"${DATA[wg-easy]}/wg0.conf"
printf 'categories\n' >"$QB/categories.json"
printf 'resume\n' >"$QB/BT_backup/torrent.fastresume"
chmod 640 "${DATA[filebrowser]}/filebrowser.db"
chown 1000:1000 "${DATA[filebrowser]}" "${DATA[filebrowser]}/filebrowser.db"
chown -R 1000:1000 "${DATA[qbittorrent]}"
jq -n '["filebrowser","qbittorrent","wg-easy"] |
    map({name:.,image:"fixture",image_id:"sha256:fixture",user:"",ids:[],ports:{}}) |
    map(if .name=="qbittorrent" then
        .ids=["PGID=1000","PUID=1000"] |
        .ports={"61006/tcp":[{HostIp:"127.0.0.1",HostPort:"61006"}]}
    else . end)' >"$WORK/services.json"
snapshot "$WORK/source" settings
pack "$WORK/source" "$WORK/source.tar.gz"
tar -tzf "$WORK/source.tar.gz" | grep -v '/$' | sort >"$WORK/members.txt"
printf '%s\n' filebrowser/filebrowser.db manifest.json qbittorrent/qBittorrent.conf wg-easy/wg-easy.db |
    sort | diff - "$WORK/members.txt"
printf 'PASS: the archive holds exactly the three operator-state files\n'
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
# A fresh install can pull a newer digest under the same moving tag.
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

# The destination is a fresh install: its own keys, rendered wg0.conf and image
# defaults, plus database side files a restore must not let SQLite replay.
printf 'destination wg0\n' >"${DATA[wg-easy]}/wg0.conf"
printf '{"port":8080}\n' >"${DATA[filebrowser]}/config/settings.json"
printf 'changed preference\n' >"$QB/qBittorrent.conf"
printf 'destination peers\n' >"${DATA[wg-easy]}/wg-easy.db"
snapshot "$WORK/rollback" rollback
printf 'stale wal\n' >"${DATA[wg-easy]}/wg-easy.db-wal"
printf 'stale shm\n' >"${DATA[wg-easy]}/wg-easy.db-shm"
( cd "$TEST_DIR" && find . -type f ! -path './work/*' ! -name filebrowser.db ! -name qBittorrent.conf \
    ! -name 'wg-easy.db*' -exec sha256sum {} + | sort ) >"$WORK/untouched-before.txt"
apply_tree "$WORK/validated"
for c in "${SERVICES[@]}"; do cmp "$WORK/validated/$c/${SCOPE[$c]##*/}" "${DATA[$c]}/${SCOPE[$c]}"; done
[[ $(stat -c '%a:%u:%g' "${DATA[filebrowser]}/filebrowser.db") == 640:1000:1000 ]]
[[ ! -e "${DATA[wg-easy]}/wg-easy.db-wal" && ! -e "${DATA[wg-easy]}/wg-easy.db-shm" ]]
( cd "$TEST_DIR" && find . -type f ! -path './work/*' ! -name filebrowser.db ! -name qBittorrent.conf \
    ! -name 'wg-easy.db*' -exec sha256sum {} + | sort ) | diff "$WORK/untouched-before.txt" -
printf 'PASS: restore writes only the three files with their UID/GID/modes, clears SQLite side files, leaves everything else alone\n'

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
cmp "$WORK/rollback/qbittorrent/qBittorrent.conf" "$QB/qBittorrent.conf"
[[ $(cat "${DATA[wg-easy]}/wg-easy.db") == 'destination peers' ]]
grep -q '^stop -t 45 fixture-container$' "$TEST_DIR/docker-calls"
grep -q '^start fixture-container$' "$TEST_DIR/docker-calls"
unset -f docker
printf 'PASS: failed restore returns previous state and restarts the original container\n'

# qBittorrent that never started has no qBittorrent/ directory yet.
rm -rf "$QB"
snapshot "$WORK/rollback-no-qbittorrent" rollback
apply_tree "$WORK/validated"
[[ $(stat -c '%a:%u:%g' "$QB") == 755:1000:1000 ]]
cmp "$WORK/validated/qbittorrent/qBittorrent.conf" "$QB/qBittorrent.conf"
apply_tree "$WORK/rollback-no-qbittorrent"
[[ ! -e "$QB/qBittorrent.conf" ]]
printf 'PASS: a missing qBittorrent directory is created for the container user; rollback removes a file that did not exist\n'

# A clean wg-easy is running but unconfigured/unhealthy; a recovery snapshot
# records that baseline, and restoring one must accept it.
jq -n '[{name:"wg-easy",health:"unhealthy"}]' >"$WORK/clean-health.json"
# shellcheck disable=SC2329 # Called inside wait_services.
docker() { printf '/wg-easy true unhealthy false\n'; }
RESTART=(fixture-wg)
wait_services "$WORK/clean-health.json"
RESTART=()
unset -f docker
printf 'PASS: unconfigured wg-easy baseline is accepted when restoring a recovery snapshot\n'

# Archives from before 2026-09-13 carry whole service directories and a
# Portainer service (DD-116). They still validate and pass the target check;
# restore takes only the three files from them.
cp -a "$WORK/source" "$WORK/legacy"
mkdir -p "$WORK/legacy/portainer/certs" "$WORK/legacy/filebrowser/config"
printf 'old portainer users\n' >"$WORK/legacy/portainer/portainer.db"
printf 'old instance key\n' >"$WORK/legacy/portainer/portainer.key"
printf 'old certificate\n' >"$WORK/legacy/portainer/certs/cert.pem"
printf '{}\n' >"$WORK/legacy/filebrowser/config/settings.json"
printf 'old wg0\n' >"$WORK/legacy/wg-easy/wg0.conf"
inventory "$WORK/legacy" >"$WORK/legacy-files.json"
jq --slurpfile files "$WORK/legacy-files.json" '.files=$files[0] |
    .services += [{name:"portainer",image:"portainer/portainer-ce:lts",image_id:"sha256:old",user:"",ids:[],ports:{"9443/tcp":[{HostIp:"127.0.0.1",HostPort:"9443"}]}}]' \
    "$WORK/source/manifest.json" >"$WORK/legacy-manifest.json"
mv "$WORK/legacy-manifest.json" "$WORK/legacy/manifest.json"
pack "$WORK/legacy" "$WORK/legacy.tar.gz"
validate_bundle "$WORK/legacy.tar.gz" "$WORK/validated-legacy" 2>"$WORK/legacy.log"
grep -q 'eski kapsamlı yedek' "$WORK/legacy.log"
check_target "$WORK/validated-legacy" 2>"$WORK/legacy-target.log"
if grep -q 'UYARI' "$WORK/legacy-target.log"; then fail 'A legacy Portainer entry must not affect the target check.'; fi
apply_tree "$WORK/validated-legacy"
[[ ! -e "$TEST_DIR/portainer" ]]
for c in "${SERVICES[@]}"; do cmp "$WORK/validated-legacy/$c/${SCOPE[$c]##*/}" "${DATA[$c]}/${SCOPE[$c]}"; done
[[ $(cat "${DATA[wg-easy]}/wg0.conf") == 'destination wg0' && $(cat "${DATA[filebrowser]}/config/settings.json") == '{"port":8080}' ]]
printf 'PASS: whole-directory archives with Portainer from before 2026-09-13 restore only the three files\n'

# A database whose SQLite journal did not drain is incomplete on its own.
printf 'unflushed transactions\n' >"${DATA[wg-easy]}/wg-easy.db-wal"
set +e
(set -e; snapshot "$WORK/unclean" settings) >"$WORK/unclean.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'A non-empty SQLite WAL must stop the backup.'
rm -f "${DATA[wg-easy]}/wg-easy.db-wal"
printf 'PASS: a backup refuses a database with a non-empty WAL\n'

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
cp -a "$WORK/source" "$WORK/with-wal"
printf 'unflushed\n' >"$WORK/with-wal/wg-easy/wg-easy.db-wal"
inventory "$WORK/with-wal" >"$WORK/with-wal-files.json"
jq --slurpfile files "$WORK/with-wal-files.json" '.files=$files[0]' "$WORK/source/manifest.json" >"$WORK/with-wal-manifest.json"
mv "$WORK/with-wal-manifest.json" "$WORK/with-wal/manifest.json"
pack "$WORK/with-wal" "$WORK/with-wal.tar.gz"
expect_rejection "$WORK/with-wal.tar.gz" sqlite-wal
printf 'changed after checksum\n' >>"$WORK/source/qbittorrent/qBittorrent.conf"
pack "$WORK/source" "$WORK/tampered.tar.gz"
expect_rejection "$WORK/tampered.tar.gz" tampered
printf '{}\n' >"$WORK/source/qbittorrent/categories.json"
pack "$WORK/source" "$WORK/out-of-scope.tar.gz"
expect_rejection "$WORK/out-of-scope.tar.gz" out-of-scope

if [[ -n ${1:-} ]]; then
    validate_bundle "$1" "$WORK/real"
    snapshot "$WORK/before-real" rollback
    apply_tree "$WORK/real"
    for c in "${SERVICES[@]}"; do
        rel="$c/${SCOPE[$c]##*/}"
        cmp "$WORK/real/$rel" "${DATA[$c]}/${SCOPE[$c]}"
        [[ $(stat -c '%a:%u:%g' "$WORK/real/$rel") == $(stat -c '%a:%u:%g' "${DATA[$c]}/${SCOPE[$c]}") ]]
    done
    apply_tree "$WORK/before-real"
    printf 'PASS: real backup restored to isolated targets; the four files matched with ownership and modes\n'
fi
printf 'ALL BACKUP TESTS PASSED (no production restore)\n'
