#!/usr/bin/env bash
# Çift tıkla çalıştır (macOS .command). v2/ ağacını seçilen SSH sunucusuna yükler.
# Kurulumu başlatmaz — konsoldan elle: bash /root/debian-server-installer/v2/install.sh
set -Eeuo pipefail

cd -- "$(dirname -- "$0")/../.."
REPO_ROOT="$(pwd)"
TGZ="/tmp/dsi-v2.tgz"
REMOTE_TGZ="/tmp/dsi-v2.tgz"
REMOTE_ROOT="/root/debian-server-installer"

DEFAULT_HOST="${DEPLOY_HOST:-nrm}"
printf '\n=== master-stack v2 yükleme ===\n'
printf 'Repo: %s\n\n' "$REPO_ROOT"
read -r -p "SSH sunucu adı [${DEFAULT_HOST}]: " HOST || true
HOST="${HOST:-$DEFAULT_HOST}"
[[ -n "$HOST" ]] || { echo "HATA: sunucu adı boş" >&2; read -r -p "Çıkmak için Enter..."; exit 1; }

SSH_BASE=(
    -o ClearAllForwardings=yes
    -o BatchMode=yes
    -o ConnectTimeout=20
)
ssh_cmd() { ssh "${SSH_BASE[@]}" "$@"; }
scp_cmd() { scp "${SSH_BASE[@]}" "$@"; }

echo "==> SSH kontrol: $HOST"
ssh_cmd "$HOST" 'printf "OK user=%s host=%s\n" "$(id -un)" "$(hostname)"'

echo "==> Paketleniyor: v2/"
rm -f "$TGZ"
COPYFILE_DISABLE=1 tar -czf "$TGZ" \
    --exclude='._*' \
    --exclude='.DS_Store' \
    v2

echo "==> Kopyalanıyor → ${HOST}:${REMOTE_TGZ}"
scp_cmd "$TGZ" "${HOST}:${REMOTE_TGZ}"

echo "==> Sunucuda açılıyor"
ssh_cmd "$HOST" bash -s <<EOF
set -Eeuo pipefail
mkdir -p '$REMOTE_ROOT'
rm -rf '$REMOTE_ROOT/v2'
tar -C '$REMOTE_ROOT' -xzf '$REMOTE_TGZ'
find '$REMOTE_ROOT/v2' -name '._*' -delete
find '$REMOTE_ROOT/v2' -name '.DS_Store' -delete
chmod 0755 '$REMOTE_ROOT/v2/install.sh'
chmod 0755 '$REMOTE_ROOT/v2/scripts/'* 2>/dev/null || true
bash -n '$REMOTE_ROOT/v2/install.sh'
grep -E '^V2_VERSION=' '$REMOTE_ROOT/v2/install.sh'
echo "SYNC_OK → $REMOTE_ROOT/v2"
EOF

cat <<EOF

Yükleme tamam ($HOST).

Konsolda kurulum:
  bash $REMOTE_ROOT/v2/install.sh

Prompt sırası (v2-4):
  1) Yerel alan adı          [ayc]
  2) Downloads dizini        [/downloads]
  3) wg-easy public UDP port [65171]
  4) WebDAV portu            [65113]
  5) (htpasswd yoksa) WebDAV kullanıcı / parola×2
  6) Tailscale login URL → tarayıcıda onayla

EOF

read -r -p "Pencereyi kapatmak için Enter..."
