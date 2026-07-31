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
# Kullanım:
#   ./deploy.sh [host]           kopyala + doğrula
#   ./deploy.sh [host] --run     kopyala + doğrula + tmux'ta kurulumu başlat
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
    echo "veya elle:"
    echo "  ssh -t ${SSH_OPTS[*]} $HOST 'bash /root/master.sh'"
    exit 0
fi

# tmux: kurulum ortasında SSH kopması Aşama 1 sonrası bir firewall penceresi
# bırakabilir. tmux ile bağlantı düşse de kurulum sürer, `tmux attach -t
# master-setup` ile geri dönülür.
ssh "${SSH_OPTS[@]}" "$HOST" \
    'command -v tmux >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq tmux; }'

echo
echo "Kurulum tmux oturumu 'master-setup' içinde başlatılıyor."
echo "Tailscale giriş linki geldiğinde TARAYICIDA HEMEN açın: bekleyen bir"
echo "kayıt isteği, oturuma müdahale edilirse veya süresi dolarsa"
echo "'410 auth path not found' ile ölür ve yeniden başlatmak gerekir."
echo
exec ssh -t "${SSH_OPTS[@]}" "$HOST" \
    'tmux new-session -A -s master-setup "bash /root/master.sh"'
