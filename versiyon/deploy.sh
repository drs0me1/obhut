#!/usr/bin/env bash
# install.sh'in bu dizindeki export'unu bir hedef host'a kopyalar, aktarımı
# SHA256 ile doğrular ve isteğe bağlı olarak kurulumu tmux içinde başlatır.
#
# Hash BİLEREK sabit kodlanmadı: yerel dosyadan hesaplanıp uzaktakiyle
# karşılaştırılıyor. Sabit bir değer, export her takas edildiğinde elle
# güncellenmesi gereken ikinci bir kopya olurdu — bu depoda tam olarak o
# sınıftan (cooldown sabiti, mimari tablosu, "sabit image" ibaresi) birden
# fazla sapma yaşandı. Burada hesaplanan hash sapamaz.
#
# tmux kullanılmıyor (operatör kararı, 2026-07-31): kurulum sağlayıcı
# konsolundan da çalıştırılabildiği için SSH kopmasına karşı sarmalayıcıya
# gerek görülmedi. Bilinen bedeli: SSH üzerinden çalıştırılırken bağlantı
# Aşama 1'den sonra koparsa kurulum yarıda kalır. Çareyi betiğin kendisi
# sağlıyor — yeniden çalıştırmak idempotenttir.
#
# Kullanım:
#   ./deploy.sh [host]           kopyala + doğrula
#   ./deploy.sh [host] --run     kopyala + doğrula + kurulumu başlat
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-nrm}"
MODE="${2:-}"
SSH_OPTS=(-o ClearAllForwardings=yes)

# ClearAllForwardings: ~/.ssh/config'teki nrm girdisi beş LocalForward ve
# ExitOnForwardFailure yes taşıyor; portlar doluysa bağlantı hiç kurulmaz.

shopt -s nullglob
EXPORTS=("$SCRIPT_DIR"/install-V1-*.sh)
shopt -u nullglob

if [[ "${#EXPORTS[@]}" -ne 1 ]]; then
    echo "HATA: ${SCRIPT_DIR} içinde tam olarak bir export bekleniyordu, ${#EXPORTS[@]} bulundu." >&2
    printf '  %s\n' "${EXPORTS[@]}" >&2
    exit 1
fi

LOCAL_FILE="${EXPORTS[0]}"
VERSION="$(awk -F'"' '/^MASTER_SETUP_VERSION=/ {print $2; exit}' "$LOCAL_FILE")"
LOCAL_SHA="$(sha256sum "$LOCAL_FILE" | awk '{print $1}')"

echo "Sürüm  : ${VERSION:-bilinmiyor}"
echo "Dosya  : $(basename "$LOCAL_FILE")"
echo "SHA256 : $LOCAL_SHA"
echo "Hedef  : ${HOST}:/root/master.sh"
echo

scp "${SSH_OPTS[@]}" "$LOCAL_FILE" "${HOST}:/root/master.sh"

REMOTE_SHA="$(
    ssh "${SSH_OPTS[@]}" "$HOST" 'sha256sum /root/master.sh' | awk '{print $1}'
)"

if [[ "$REMOTE_SHA" != "$LOCAL_SHA" ]]; then
    echo "HATA: Aktarım doğrulanamadı." >&2
    echo "  yerel  : $LOCAL_SHA" >&2
    echo "  uzak   : $REMOTE_SHA" >&2
    exit 1
fi
echo "Aktarım doğrulandı: uzak SHA256 yerelle aynı."

ssh "${SSH_OPTS[@]}" "$HOST" 'chmod +x /root/master.sh'

if [[ "$MODE" != "--run" ]]; then
    echo
    echo "Kurulumu başlatmak için:"
    echo "  $0 $HOST --run"
    echo "Sağlayıcı konsolundan:"
    echo "  bash /root/master.sh"
    exit 0
fi

# Tailscale girişi hakkında: bekleyen bir kayıt isteği, kurulum yeniden
# başlatılırsa ölür. Yeniden başlatma yeni bir nodekey üretir ve önceki auth
# yolunu geçersiz kılar; sonuç "410 auth path not found" olur. 2026-07-31'de
# üç deneme tam olarak buna gitti. Yavaş bir giriş için çare beklemektir.
echo
echo "Kurulum başlatılıyor. Tailscale giriş linki geldiğinde TARAYICIDA"
echo "HEMEN açın ve oturuma dokunmayın; yeniden başlatmak bekleyen kayıt"
echo "isteğini '410 auth path not found' ile öldürür."
echo
exec ssh -t "${SSH_OPTS[@]}" "$HOST" 'bash /root/master.sh'
