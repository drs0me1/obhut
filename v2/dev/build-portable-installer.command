#!/usr/bin/env bash
# Çift tık: tek dosyalı kurulum üreticisi → v2/dist + Masaüstü
set -Eeuo pipefail

cd -- "$(dirname -- "$0")"
./build-portable-installer.sh --desktop

cat <<EOF

Taşınabilir kurulum hazır.

  • Repo:     ../dist/Master-Stack-v2-Install.command
  • Masaüstü: ~/Desktop (veya ~/Masaüstü) / Master-Stack-v2-Install.command

Bu tek dosyayı istediğin yere kopyalayabilirsin; repo gerekmez.
Çift tıklayınca SSH sunucu adını sorar, yükler ve kurulumu başlatır.

EOF

read -r -p "Şimdi kurulumu başlat? [E/h]: " ans || true
ans="${ans:-E}"
if [[ "$ans" =~ ^[EeYy]$ ]]; then
    exec ../dist/Master-Stack-v2-Install.command
fi
read -r -p "Pencereyi kapatmak için Enter..."
