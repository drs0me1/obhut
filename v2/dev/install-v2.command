#!/usr/bin/env bash
# Repo içinden: güncel taşınabilir kurulum dosyasını üretip çalıştırır.
# Masaüstü kopyası için: build-portable-installer.command (veya --desktop)
set -Eeuo pipefail

cd -- "$(dirname -- "$0")"
./build-portable-installer.sh
exec ../dist/Master-Stack-v2-Install.command
