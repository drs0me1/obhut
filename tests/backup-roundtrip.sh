#!/usr/bin/env bash
# Linux/root only. All restore targets are isolated mktemp directories.
# Optional argument: a real archive to validate, restore and seed in isolation.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # bcrypt/config fixtures are literal $-strings.
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
# Installer inputs, exactly as install.sh writes them (umask 077 → 0600 root).
HOST_STATE="$TEST_DIR/host-source"
mkdir -m 700 "$HOST_STATE"
printf 'LOCAL_DOMAIN=ayc\nDOWNLOADS_PATH=/srv/downloads\nWG_PUBLIC_PORT=51820\nWEBDAV_PORT=61003\nTIMEZONE=Europe/Berlin\n' >"$HOST_STATE/config.env"
BCRYPT_FIXTURE='webdav:$2y$05$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0'
printf '%s\n' "$BCRYPT_FIXTURE" >"$HOST_STATE/webdav.htpasswd"
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
[[ $(jq -r .schema "$WORK/validated/manifest.json") == 2 ]]
[[ $(jq -r '.files[] | select(.path=="host/config.env") | .stat' "$WORK/validated/manifest.json") == 600:0:0 ]]
[[ $(jq -r '.files[] | select(.path=="host/webdav.htpasswd") | .stat' "$WORK/validated/manifest.json") == 600:0:0 ]]
cmp "$WORK/validated/host/config.env" "$HOST_STATE/config.env"
tar -tzf "$WORK/source.tar.gz" | grep -qx 'host/webdav.htpasswd'
printf 'PASS: schema-2 backup carries the installer inputs with root-only modes\n'
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

# Schema 1 (2026-09-05 … 2026-09-11) has no host/ directory and stays restorable.
cp -a "$WORK/source" "$WORK/legacy"
rm -rf "$WORK/legacy/host"
jq '.schema=1 | .files |= map(select(.path | startswith("host/") | not))' \
    "$WORK/source/manifest.json" >"$WORK/legacy/manifest.json"
pack "$WORK/legacy" "$WORK/legacy.tar.gz"
if tar -tzf "$WORK/legacy.tar.gz" | grep -q '^host'; then fail 'legacy archive must not contain host/'; fi
validate_bundle "$WORK/legacy.tar.gz" "$WORK/validated-legacy"
check_target "$WORK/validated-legacy"
[[ ! -e "$WORK/validated-legacy/host" ]]
apply_tree "$WORK/validated-legacy"
printf 'PASS: schema-1 archive without host/ still validates and restores\n'

expect_rejection() {
    local archive=$1 label=$2 rc
    set +e
    (set -e; validate_bundle "$archive" "$WORK/rejected-$label") >"$WORK/reject.log" 2>&1
    rc=$?
    set -e
    (( rc != 0 )) || fail "Archive should have been rejected: $label"
    printf 'PASS: rejected %s archive\n' "$label"
}
# A schema-1 manifest cannot claim host files, and a schema-2 settings backup
# must carry both installer inputs.
cp -a "$WORK/source" "$WORK/legacy-with-host"
jq '.schema=1' "$WORK/source/manifest.json" >"$WORK/legacy-with-host/manifest.json"
pack "$WORK/legacy-with-host" "$WORK/legacy-with-host.tar.gz"
expect_rejection "$WORK/legacy-with-host.tar.gz" schema-1-with-host
cp -a "$WORK/source" "$WORK/missing-htpasswd"
rm "$WORK/missing-htpasswd/host/webdav.htpasswd"
jq '.files |= map(select(.path != "host/webdav.htpasswd"))' \
    "$WORK/source/manifest.json" >"$WORK/missing-htpasswd/manifest.json"
pack "$WORK/missing-htpasswd" "$WORK/missing-htpasswd.tar.gz"
expect_rejection "$WORK/missing-htpasswd.tar.gz" schema-2-without-htpasswd
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
tar -C "$WORK/evil" -czf "$WORK/host-extra.tar.gz" --transform='s#file#host/state.env#' file
expect_rejection "$WORK/host-extra.tar.gz" host-out-of-scope
printf 'changed after checksum\n' >>"$WORK/source/qbittorrent/qBittorrent.conf"
pack "$WORK/source" "$WORK/tampered.tar.gz"
expect_rejection "$WORK/tampered.tar.gz" tampered
printf '{}\n' >"$WORK/source/qbittorrent/categories.json"
pack "$WORK/source" "$WORK/out-of-scope.tar.gz"
expect_rejection "$WORK/out-of-scope.tar.gz" out-of-scope

# seed: the installer inputs land on a host that has no /etc/master-stack yet,
# re-running is a no-op, and a differing existing file stops the whole step.
HOST_STATE="$TEST_DIR/host-target"
seed_host "$WORK/source.tar.gz" 2>"$WORK/seed.log"
[[ $(stat -c '%a:%u:%g' "$HOST_STATE") == 700:0:0 ]]
for name in "${HOST_FILES[@]}"; do
    [[ $(stat -c '%a:%u:%g' "$HOST_STATE/$name") == 600:0:0 ]]
    cmp "$HOST_STATE/$name" "$TEST_DIR/host-source/$name"
done
seed_host "$WORK/source.tar.gz" 2>"$WORK/seed.log"
grep -q 'zaten aynı' "$WORK/seed.log"
printf 'PASS: seed places both installer inputs as 0600 root and re-runs as a no-op\n'
rm "$HOST_STATE/config.env"
printf 'other:$2y$05$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0\n' >"$HOST_STATE/webdav.htpasswd"
set +e
(set -e; seed_host "$WORK/source.tar.gz") >"$WORK/seed.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'seed must refuse to overwrite a differing existing file.'
[[ ! -e "$HOST_STATE/config.env" ]]
grep -q 'zaten var ve yedektekinden farklı' "$WORK/seed.log"
printf 'PASS: seed refuses a differing existing file and writes nothing\n'
set +e
(set -e; seed_host "$WORK/legacy.tar.gz") >"$WORK/seed.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail 'seed must refuse an archive without host files.'
grep -q 'şema 2' "$WORK/seed.log"
printf 'PASS: seed refuses a schema-1 archive\n'
# The seeded config.env is sourced by install.sh as root: only its own keys,
# with values that carry no shell syntax, pass.
expect_bad_config() {
    local label=$1 rc
    set +e
    (set -e; check_config_env "$WORK/bad-config.env") >/dev/null 2>&1
    rc=$?
    set -e
    (( rc != 0 )) || fail "config.env should have been rejected: $label"
}
for bad in 'LOCAL_DOMAIN=$(id)' 'LOCAL_DOMAIN=ayc;id' 'PATH=/tmp' 'DOWNLOADS_PATH=/srv/../etc' 'WEBDAV_PORT=70000' 'TIMEZONE=Europe/Berlin;x' 'LOCAL_DOMAIN=ayc'$'\n''LOCAL_DOMAIN=b'; do
    printf '%s\n' "$bad" >"$WORK/bad-config.env"
    expect_bad_config "$bad"
done
check_config_env "$TEST_DIR/host-source/config.env"
printf '%s\n' "$BCRYPT_FIXTURE" "$BCRYPT_FIXTURE" >"$WORK/bad.htpasswd"
set +e
(set -e; check_htpasswd "$WORK/bad.htpasswd") >/dev/null 2>&1; rc=$?
set -e
(( rc != 0 )) || fail 'two htpasswd lines must be rejected.'
printf 'webdav:$apr1$saltsalt$abcdefghijklmnopqrstuv\n' >"$WORK/bad.htpasswd"
set +e
(set -e; check_htpasswd "$WORK/bad.htpasswd") >/dev/null 2>&1; rc=$?
set -e
(( rc != 0 )) || fail 'a non-bcrypt htpasswd must be rejected.'
check_htpasswd "$TEST_DIR/host-source/webdav.htpasswd"
printf 'PASS: seed accepts only write_config keys and a single bcrypt account\n'

if [[ -n ${1:-} ]]; then
    validate_bundle "$1" "$WORK/real"
    apply_tree "$WORK/real"
    HOST_STATE="$TEST_DIR/host-source"
    snapshot "$WORK/real-roundtrip" settings
    jq -e --slurpfile actual "$WORK/real-roundtrip/manifest.json" '
        [.files[] | select(.path | startswith("host/") | not)] ==
        [$actual[0].files[] | select(.path | startswith("host/") | not)]' "$WORK/real/manifest.json" >/dev/null
    apply_tree "$WORK/rollback"
    printf 'PASS: real backup restored to isolated targets; all hashes/ownership/modes matched\n'
    if [[ -d "$WORK/real/host" ]]; then
        HOST_STATE="$TEST_DIR/host-real"
        seed_host "$1" 2>/dev/null
        cmp "$HOST_STATE/config.env" "$WORK/real/host/config.env"
        cmp "$HOST_STATE/webdav.htpasswd" "$WORK/real/host/webdav.htpasswd"
        printf 'PASS: real backup seeded an isolated host directory\n'
    fi
fi
printf 'ALL BACKUP TESTS PASSED (no production restore)\n'
