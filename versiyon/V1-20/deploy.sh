#!/usr/bin/env bash
# Bu dizindeki install.sh export'unu bir hedef host'a kopyalar, aktarımı
# SHA256 ile doğrular ve isteğe bağlı olarak kurulumu başlatır.
#
# Hash BİLEREK sabit kodlanmadı: yerel dosyadan hesaplanıp uzaktakiyle
# karşılaştırılıyor. Sabit bir değer, export her takas edildiğinde elle
# güncellenmesi gereken ikinci bir kopya olurdu — bu depoda tam olarak o
# sınıftan (cooldown sabiti, STACK_SCHEMA, mimari tablosu, "sabit image"
# ibaresi) dört ayrı sapma yaşandı. Burada hesaplanan hash sapamaz.
#
# tmux kullanılmıyor (operatör kararı, 2026-07-31): kurulum sağlayıcı
# konsolundan da çalıştırılabildiği için SSH kopmasına karşı sarmalayıcıya
# gerek görülmedi. Bilinen bedeli: SSH üzerinden çalıştırılırken bağlantı
# Aşama 1'den sonra koparsa kurulum yarıda kalır. Çareyi betiğin kendisi
# sağlıyor — yeniden çalıştırmak idempotenttir.
#
# BU DOSYA versiyon/V1-20/deploy.sh İLE BİREBİR AYNIDIR ve öyle kalmalı.
# Her sürüm klasörü kendi kendine yeterli olsun diye kopyalandı (klasörü
# tek başına başka bir makineye taşımak çalışır olmalı). Sapmayı tek
# komutla yakala:
#   diff versiyon/V1-20/deploy.sh versiyon/V2-2/deploy.sh
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

# Guard, sürüm klasörlerine geçtikten sonra da korundu (2026-08-01). Artık
# her klasörde doğal olarak tek export var, ama guard'ın asıl işi kalabalık
# bir dizini reddetmek değil: yanlışlıkla ikinci bir dosya bırakılırsa
# hangisinin kurulacağı sessizce belirsizleşir. Sessiz belirsizlik, bu
# depoda tekrar tekrar sorun çıkaran sınıfın ta kendisi.
shopt -s nullglob
# Desen sürümden bağımsız: dizin-başına-sürüm şeması zaten tek dosyayı
# garanti ediyor, o yüzden ada V/Q/R öneki dayatmaya gerek yok. Önceki hâli
# install-V*-*.sh idi ve quantum dalındaki install-Q1-1.sh ile hiç
# eşleşmiyordu — guard doğru davranıp "0 bulundu" ile reddetti (2026-08-01).
EXPORTS=("$SCRIPT_DIR"/install-*.sh)
shopt -u nullglob

if [[ "${#EXPORTS[@]}" -ne 1 ]]; then
    echo "HATA: ${SCRIPT_DIR} içinde tam olarak bir export bekleniyordu, ${#EXPORTS[@]} bulundu." >&2
    # Sayı kontrolü şart: bash 3.2'de (bu iş istasyonunun /bin/bash'i) boş bir
    # dizinin "${arr[@]}" açılımı `set -u` altında "unbound variable" ile
    # patlar, yani sıfır-export dalı amaçlanan exit 1 yerine farklı bir hatayla
    # çıkardı. Guard'ı iki yönde de test ederken yakalandı (2026-08-01).
    if [[ "${#EXPORTS[@]}" -gt 0 ]]; then
        printf '  %s\n' "${EXPORTS[@]}" >&2
    fi
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
