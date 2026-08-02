#!/usr/bin/env bash
# macOS'ta ÇİFT TIKLANABİLİR giriş noktası. Finder bir .command dosyasını
# Terminal.app içinde çalıştırır (.sh'i çalıştırmaz, editörde açar) — tek
# fark bu; iş yine yanındaki deploy.sh'te.
#
# Neden ayrı bir dosya: deploy.sh terminalden ve belgelerden çağrılan
# kanonik arayüz olarak kalmalı. Onu .command'e çevirmek çift tıklamayı
# kazandırıp `./deploy.sh nrm --run` alışkanlığını ve README'lerdeki her
# referansı bozardı. Bu sarmalayıcı mantık taşımaz, yalnız çift tıklamanın
# eksik bıraktığı üç şeyi tamamlar:
#
#   1. Çalışma dizini. Terminal .command'i $HOME'dan başlatır, dosyanın
#      bulunduğu dizinden değil.
#   2. Argümanlar. Çift tıklamayla argüman geçirilemez, o yüzden host ve
#      --run seçimi burada sorulur.
#   3. Pencerenin açık kalması. İş bitince Terminal pencereyi kapatabilir
#      ve hata mesajı okunmadan kaybolur; sonda tuş bekleniyor.
#
# BU DOSYA versiyon/V1-20/deploy.command İLE BİREBİR AYNIDIR ve öyle
# kalmalı (bkz. deploy.sh'teki aynı not):
#   diff versiyon/V1-20/deploy.command versiyon/R2.4/deploy.command
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# Hata hâlinde de pencere açık kalsın: aksi hâlde çift tıklayan kişi
# mesajı hiç göremez.
pause_and_exit() {
    local code="${1:-0}"
    echo
    printf 'Kapatmak için bir tuşa basın... '
    read -rsn1 || true
    echo
    exit "$code"
}
trap 'pause_and_exit $?' ERR

# deploy.sh ile aynı glob: hangi export'un yanında durduğumuzu o belirler.
# Burada yalnız başlıkta göstermek için okunuyor; sayı kontrolünü ve asıl
# reddi deploy.sh yapıyor, iki yerde tekrar etmeye gerek yok.
shopt -s nullglob
EXPORTS=(install-*.sh)
shopt -u nullglob

EXPORT_NAME=""
VERSION=""
if [[ "${#EXPORTS[@]}" -eq 1 ]]; then
    EXPORT_NAME="${EXPORTS[0]}"
    VERSION="$(
        awk -F'"' '/^MASTER_SETUP_VERSION=/ {print $2; exit}' "$EXPORT_NAME"
    )"
elif [[ "${#EXPORTS[@]}" -gt 1 ]]; then
    EXPORT_NAME="${#EXPORTS[@]} adet — deploy.sh reddedecek"
fi

echo "=================================================="
echo "  Kurulum betiği dağıtımı"
echo "  Sürüm : ${VERSION:-bilinmiyor}"
echo "  Dosya : ${EXPORT_NAME:-bulunamadı}"
echo "=================================================="
echo

read -rp "Hedef host [nrm]: " HOST_INPUT
HOST="${HOST_INPUT:-nrm}"
echo

echo "Ne yapılsın?"
echo "  1) Yalnız kopyala ve SHA256 ile doğrula"
echo "  2) Kopyala, doğrula ve KURULUMU BAŞLAT"
echo "  3) İptal"
echo
read -rp "Seçim [1]: " CHOICE
CHOICE="${CHOICE:-1}"
echo

case "$CHOICE" in
    1) ./deploy.sh "$HOST" ;;
    2)
        echo "Kurulum başlatılacak: ${HOST}"
        echo "Tailscale giriş linki geldiğinde TARAYICIDA HEMEN açın ve"
        echo "oturuma dokunmayın — yeniden başlatmak bekleyen kayıt isteğini"
        echo "'410 auth path not found' ile öldürür."
        echo
        read -rp "Onaylıyor musunuz? [e/H]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[eE]$ ]]; then
            echo
            ./deploy.sh "$HOST" --run
        else
            echo "İptal edildi."
        fi
        ;;
    *) echo "İptal edildi." ;;
esac

pause_and_exit 0
