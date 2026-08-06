#!/usr/bin/env bash
# Çift tıkla çalıştır (macOS .command). Repo'daki v2 runtime'ı SSH ile yükler.
# Kurulum için taşınabilir dosya: ../dist/Master-Stack-v2-Install.command
# (üretmek: build-portable-installer.command)
set -Eeuo pipefail

cd -- "$(dirname -- "$0")"
# shellcheck source=sync-v2.sh
source ./sync-v2.sh

DEFAULT_HOST="${DEPLOY_HOST:-nrm}"
printf '\n=== master-stack v2 yükleme ===\n'
read -r -p "SSH sunucu adı [${DEFAULT_HOST}]: " HOST || true
HOST="${HOST:-$DEFAULT_HOST}"
[[ -n "$HOST" ]] || { echo "HATA: sunucu adı boş" >&2; read -r -p "Çıkmak için Enter..."; exit 1; }

sync_v2_to_host "$HOST"

cat <<EOF

Yükleme tamam ($HOST).

Konsolda kurulum:
  ssh -t $HOST 'bash ${SYNC_LAST_REMOTE_ROOT}/v2/install.sh'

veya çift tık: install-v2.command

Prompt sırası:
  1) Yerel alan adı          [ayc]
  2) Downloads dizini        [/downloads]
  3) wg-easy public UDP port [65171]
  4) WebDAV portu            [65113]
  5) (htpasswd yoksa) WebDAV kullanıcı / parola×2
  6) Tailscale login URL → tarayıcıda onayla

EOF

read -r -p "Pencereyi kapatmak için Enter..."
