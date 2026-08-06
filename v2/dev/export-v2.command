#!/usr/bin/env bash
# Çift tık: v2'yi taşınabilir tek dosya app olarak export et → dist + Masaüstü
set -Eeuo pipefail

cd -- "$(dirname -- "$0")"
./export-v2.sh --desktop

cat <<EOF

Export tamam.

  • Repo:     ../dist/Master-Stack-v2-Install.command
  • Masaüstü: ~/Desktop (veya ~/Masaüstü) / Master-Stack-v2-Install.command

Bu tek dosya tüm v2 runtime'ını içerir; başka Mac'e kopyalanıp çift tıklanır.
SSH sunucu adını sorar, yükler ve kurulumu başlatır.

EOF

read -r -p "Şimdi kurulumu başlat? [E/h]: " ans || true
ans="${ans:-E}"
if [[ "$ans" =~ ^[EeYy]$ ]]; then
    exec ../dist/Master-Stack-v2-Install.command
fi
read -r -p "Pencereyi kapatmak için Enter..."
