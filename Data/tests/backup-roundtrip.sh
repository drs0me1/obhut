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
WG="${DATA[wg-easy]}"
# In scope: the wg-easy admin account and peers.
printf 'wg account and peers fixture\n' >"$WG/wg-easy.db"
# Out of scope: rendered by wg-easy, or owned by services the installer
# provisions (DD-118). The FileBrowser/Transmission directories stand in for
# the destination's own data, which no restore may touch.
printf 'rendered from wg-easy.db\n' >"$WG/wg0.conf"
mkdir -p "$TEST_DIR/filebrowser/config" "$TEST_DIR/transmission"
printf 'destination filebrowser account\n' >"$TEST_DIR/filebrowser/filebrowser.db"
printf '{"port":80}\n' >"$TEST_DIR/filebrowser/config/settings.json"
printf '{"download-queue-size":12}\n' >"$TEST_DIR/transmission/settings.json"
chmod 600 "$WG/wg-easy.db"
jq -n '[{name:"wg-easy",image:"fixture",image_id:"sha256:fixture",user:"",
    ids:["PGID=1000","PUID=1000"],
    ports:{"51820/udp":[{HostIp:"0.0.0.0",HostPort:"61001"}],"51821/tcp":[{HostIp:"127.0.0.1",HostPort:"51821"}]}}]' \
    >"$WORK/services.json"
snapshot "$WORK/source" settings
pack "$WORK/source" "$WORK/source.tar.gz"
tar -tzf "$WORK/source.tar.gz" | grep -v '/$' | sort >"$WORK/members.txt"
printf '%s\n' manifest.json wg-easy/wg-easy.db | diff - "$WORK/members.txt"
printf 'PASS: the archive holds exactly the wg-easy database\n'
validate_bundle "$WORK/source.tar.gz" "$WORK/validated"
check_target "$WORK/validated"
cp "$WORK/services.json" "$WORK/original-services.json"
# Docker environment order is not a user/group setting; compare by value.
jq 'map(.ids |= reverse)' "$WORK/original-services.json" >"$WORK/services.json"
check_target "$WORK/validated"
mkdir "$WORK/reordered-source"
jq '.services |= map(.ids |= reverse)' \
    "$WORK/validated/manifest.json" >"$WORK/reordered-source/manifest.json"
cp "$WORK/original-services.json" "$WORK/services.json"
check_target "$WORK/reordered-source"
printf 'PASS: PUID/PGID ordering is ignored in existing backups and live targets\n'
for setting in PUID PGID; do
    jq --arg setting "$setting" 'map(.ids |= map(if startswith($setting+"=") then $setting+"=2000" else . end))' \
        "$WORK/original-services.json" >"$WORK/services.json"
    set +e
    (check_target "$WORK/validated") >"$WORK/target-reject.log" 2>&1
    rc=$?
    set -e
    (( rc != 0 )) || fail "A genuinely different $setting must be rejected."
    grep -Fq 'wg-easy ids:' "$WORK/target-reject.log"
    grep -Fq "$setting=2000" "$WORK/target-reject.log"
done
jq 'map(.ports["51820/udp"][0].HostPort="61009")' \
    "$WORK/original-services.json" >"$WORK/services.json"
set +e
(check_target "$WORK/validated") >"$WORK/target-reject.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'A changed port must still be rejected.'
grep -Fq 'wg-easy ports:' "$WORK/target-reject.log"
printf 'PASS: genuine PUID, PGID and port changes remain rejected\n'
# A fresh install can pull a newer digest under the same moving tag.
jq 'map(.image_id="sha256:different")' "$WORK/original-services.json" >"$WORK/services.json"
check_target "$WORK/validated" 2>"$WORK/image-warning.log"
grep -Fq 'UYARI:' "$WORK/image-warning.log"
cp "$WORK/original-services.json" "$WORK/services.json"
printf 'PASS: changed image digests warn but allow transfer by default\n'
jq '.[0].user="different"' "$WORK/original-services.json" >"$WORK/services.json"
set +e
(check_target "$WORK/validated") >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'A changed runtime user must still be rejected.'
cp "$WORK/original-services.json" "$WORK/services.json"
printf 'PASS: target user incompatibility rejected before writes\n'

# The destination is a fresh install: its own rendered wg0.conf and accounts,
# plus database side files SQLite must not replay.
printf 'destination wg0\n' >"$WG/wg0.conf"
printf 'destination peers\n' >"$WG/wg-easy.db"
snapshot "$WORK/rollback" rollback
printf 'stale wal\n' >"$WG/wg-easy.db-wal"
printf 'stale shm\n' >"$WG/wg-easy.db-shm"
untouched() {
    ( cd "$TEST_DIR" && find . -type f ! -path './work/*' ! -name 'wg-easy.db*' -exec sha256sum {} + | sort )
}
untouched >"$WORK/untouched-before.txt"
apply_tree "$WORK/validated"
cmp "$WORK/validated/wg-easy/wg-easy.db" "$WG/wg-easy.db"
[[ $(stat -c '%a:%u:%g' "$WG/wg-easy.db") == $(stat -c '%a:%u:%g' "$WORK/validated/wg-easy/wg-easy.db") ]]
[[ ! -e "$WG/wg-easy.db-wal" && ! -e "$WG/wg-easy.db-shm" ]]
untouched | diff "$WORK/untouched-before.txt" -
printf 'PASS: restore writes only wg-easy.db with its UID/GID/mode, clears SQLite side files, leaves everything else alone\n'

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
[[ $(cat "$WG/wg-easy.db") == 'destination peers' ]]
grep -q '^stop -t 45 fixture-container$' "$TEST_DIR/docker-calls"
grep -q '^start fixture-container$' "$TEST_DIR/docker-calls"
unset -f docker
printf 'PASS: failed restore returns previous state and restarts the original container\n'

# A wg-easy that never started has no database; rollback restores that absence.
rm -f "$WG/wg-easy.db"
snapshot "$WORK/rollback-no-db" rollback
apply_tree "$WORK/validated"
cmp "$WORK/validated/wg-easy/wg-easy.db" "$WG/wg-easy.db"
apply_tree "$WORK/rollback-no-db"
[[ ! -e "$WG/wg-easy.db" ]]
printf 'destination peers\n' >"$WG/wg-easy.db"
printf 'PASS: rollback removes a database that did not exist before\n'

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

# Older archives carry services the installer now provisions or no longer
# ships: FileBrowser and Transmission (DD-118, v2-83 era), and before
# 2026-09-13 whole directories plus Portainer (DD-116) and qBittorrent
# (DD-117). They still validate and pass the target check; restore writes
# wg-easy.db only.
legacy_archive() {
    local name=$1 services=$2
    inventory "$WORK/$name" >"$WORK/$name-files.json"
    jq --slurpfile files "$WORK/$name-files.json" --argjson extra "$(jq -nc "$services")" \
        '.files=$files[0] | .services += $extra' \
        "$WORK/source/manifest.json" >"$WORK/$name/manifest.json"
    pack "$WORK/$name" "$WORK/$name.tar.gz"
}
mkdir -p "$WORK/v83/filebrowser" "$WORK/v83/transmission"
cp -a "$WORK/source/wg-easy" "$WORK/v83/"
printf 'old filebrowser account\n' >"$WORK/v83/filebrowser/filebrowser.db"
printf '{"speed-limit-down":100}\n' >"$WORK/v83/transmission/settings.json"
legacy_archive v83 '[
  {name:"filebrowser",image:"filebrowser/filebrowser:v2",image_id:"sha256:old",user:"1000:1000",ids:[],ports:{"80/tcp":[{HostIp:"127.0.0.1",HostPort:"61007"}]}},
  {name:"transmission",image:"lscr.io/linuxserver/transmission:latest",image_id:"sha256:old",user:"",ids:["PGID=1000","PUID=1000"],ports:{"9091/tcp":[{HostIp:"127.0.0.1",HostPort:"61006"}]}}]'
mkdir -p "$WORK/wide/portainer/certs" "$WORK/wide/filebrowser/config" "$WORK/wide/qbittorrent"
cp -a "$WORK/source/wg-easy" "$WORK/wide/"
printf 'old portainer users\n' >"$WORK/wide/portainer/portainer.db"
printf 'old certificate\n' >"$WORK/wide/portainer/certs/cert.pem"
printf 'old filebrowser account\n' >"$WORK/wide/filebrowser/filebrowser.db"
printf '{}\n' >"$WORK/wide/filebrowser/config/settings.json"
printf 'old qbittorrent preferences\n' >"$WORK/wide/qbittorrent/qBittorrent.conf"
printf 'old wg0\n' >"$WORK/wide/wg-easy/wg0.conf"
legacy_archive wide '[
  {name:"filebrowser",image:"filebrowser/filebrowser:v2",image_id:"sha256:old",user:"1000:1000",ids:[],ports:{}},
  {name:"portainer",image:"portainer/portainer-ce:lts",image_id:"sha256:old",user:"",ids:[],ports:{"9443/tcp":[{HostIp:"127.0.0.1",HostPort:"9443"}]}},
  {name:"qbittorrent",image:"lscr.io/linuxserver/qbittorrent:latest",image_id:"sha256:old",user:"",ids:["PGID=1000","PUID=1000"],ports:{"61006/tcp":[{HostIp:"127.0.0.1",HostPort:"61006"}]}}]'
for name in v83 wide; do
    validate_bundle "$WORK/$name.tar.gz" "$WORK/validated-$name" 2>"$WORK/$name.log"
    grep -q 'Not: eski yedek' "$WORK/$name.log"
    grep -q 'yüklenecek 1' "$WORK/$name.log"
    check_target "$WORK/validated-$name" 2>"$WORK/$name-target.log"
    if grep -q 'UYARI' "$WORK/$name-target.log"; then fail "Legacy entries must not affect the target check: $name"; fi
    printf 'changed destination peers\n' >"$WG/wg-easy.db"
    untouched >"$WORK/untouched-before.txt"
    apply_tree "$WORK/validated-$name"
    cmp "$WORK/validated-$name/wg-easy/wg-easy.db" "$WG/wg-easy.db"
    untouched | diff "$WORK/untouched-before.txt" -
    [[ ! -e "$TEST_DIR/portainer" && ! -e "$TEST_DIR/qbittorrent" ]]
done
printf 'PASS: FileBrowser/Transmission and Portainer/qBittorrent-era archives restore wg-easy.db only\n'

# A database whose SQLite journal did not drain is incomplete on its own.
printf 'unflushed transactions\n' >"$WG/wg-easy.db-wal"
set +e
(set -e; snapshot "$WORK/unclean" settings) >"$WORK/unclean.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'A non-empty SQLite WAL must stop the backup.'
rm -f "$WG/wg-easy.db-wal"
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
jq --slurpfile files "$WORK/with-wal-files.json" '.files=$files[0]' "$WORK/source/manifest.json" >"$WORK/with-wal/manifest.json"
pack "$WORK/with-wal" "$WORK/with-wal.tar.gz"
expect_rejection "$WORK/with-wal.tar.gz" sqlite-wal
# A manifest that lists wg-easy must carry its directory.
mkdir "$WORK/no-wg-dir"
jq '.files=[]' "$WORK/source/manifest.json" >"$WORK/no-wg-dir/manifest.json"
tar -C "$WORK/no-wg-dir" -czf "$WORK/no-wg-dir.tar.gz" manifest.json
expect_rejection "$WORK/no-wg-dir.tar.gz" listed-service-missing
# An archive without wg-easy carries nothing to restore.
mkdir -p "$WORK/only-legacy/filebrowser"
printf 'old filebrowser account\n' >"$WORK/only-legacy/filebrowser/filebrowser.db"
inventory "$WORK/only-legacy" >"$WORK/only-legacy-files.json"
jq --slurpfile files "$WORK/only-legacy-files.json" \
    '.files=$files[0] | .services=[{name:"filebrowser",image:"x",image_id:"x",user:"",ids:[],ports:{}}]' \
    "$WORK/source/manifest.json" >"$WORK/only-legacy/manifest.json"
pack "$WORK/only-legacy" "$WORK/only-legacy.tar.gz"
expect_rejection "$WORK/only-legacy.tar.gz" without-wg-easy
cp -a "$WORK/source" "$WORK/tampered"
printf 'changed after checksum\n' >>"$WORK/tampered/wg-easy/wg-easy.db"
pack "$WORK/tampered" "$WORK/tampered.tar.gz"
expect_rejection "$WORK/tampered.tar.gz" tampered
mkdir -p "$WORK/v83/transmission"
printf '{}\n' >"$WORK/v83/transmission/stats.json"
pack "$WORK/v83" "$WORK/out-of-scope.tar.gz"
expect_rejection "$WORK/out-of-scope.tar.gz" out-of-scope

if [[ -n ${1:-} ]]; then
    validate_bundle "$1" "$WORK/real"
    snapshot "$WORK/before-real" rollback
    apply_tree "$WORK/real"
    for c in "${SERVICES[@]}"; do
        [[ -d "$WORK/real/$c" ]] || continue
        rel="$c/${SCOPE[$c]##*/}"
        cmp "$WORK/real/$rel" "${DATA[$c]}/${SCOPE[$c]}"
        [[ $(stat -c '%a:%u:%g' "$WORK/real/$rel") == $(stat -c '%a:%u:%g' "${DATA[$c]}/${SCOPE[$c]}") ]]
    done
    apply_tree "$WORK/before-real"
    printf 'PASS: real backup restored to isolated targets; the carried files matched with ownership and modes\n'
fi
printf 'ALL BACKUP TESTS PASSED (no production restore)\n'
