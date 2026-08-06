#!/usr/bin/env bash
# Ortak: v2 runtime ağacını SSH host'a paketle ve aç.
# Mac .command dosyaları bunu source eder; doğrudan çalıştırılmaz.
# shellcheck shell=bash

_SYNC_V2_DEV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

sync_v2_to_host() {
    local host="$1"
    local repo_root tgz remote_tgz remote_root
    repo_root="$(cd -- "$_SYNC_V2_DEV_DIR/../.." && pwd)"
    tgz="${SYNC_TGZ:-/tmp/dsi-v2.tgz}"
    remote_tgz="${SYNC_REMOTE_TGZ:-/tmp/dsi-v2.tgz}"
    remote_root="${SYNC_REMOTE_ROOT:-/root/debian-server-installer}"

    local -a ssh_base=(
        -o ClearAllForwardings=yes
        -o BatchMode=yes
        -o ConnectTimeout=20
    )

    echo "==> SSH kontrol: $host"
    ssh "${ssh_base[@]}" "$host" 'printf "OK user=%s host=%s\n" "$(id -un)" "$(hostname)"'

    echo "==> Paketleniyor: v2/ (runtime only)"
    rm -f "$tgz"
    (
        cd -- "$repo_root" || exit 1
        COPYFILE_DISABLE=1 tar -czf "$tgz" \
            --exclude='._*' \
            --exclude='.DS_Store' \
            --exclude='v2/.cursor' \
            --exclude='v2/dev' \
            --exclude='v2/tests' \
            --exclude='v2/dist' \
            v2
    )

    echo "==> Kopyalanıyor → ${host}:${remote_tgz}"
    scp "${ssh_base[@]}" "$tgz" "${host}:${remote_tgz}"

    echo "==> Sunucuda açılıyor"
    ssh "${ssh_base[@]}" "$host" bash -s <<EOF
set -Eeuo pipefail
mkdir -p '$remote_root'
rm -rf '$remote_root/v2'
tar -C '$remote_root' -xzf '$remote_tgz'
find '$remote_root/v2' -name '._*' -delete
find '$remote_root/v2' -name '.DS_Store' -delete
chmod 0755 '$remote_root/v2/install.sh'
chmod 0755 '$remote_root/v2/scripts/'*
bash -n '$remote_root/v2/install.sh'
grep -E '^V2_VERSION=' '$remote_root/v2/install.sh'
echo "SYNC_OK → $remote_root/v2"
EOF

    SYNC_LAST_HOST="$host"
    SYNC_LAST_REMOTE_ROOT="$remote_root"
}
