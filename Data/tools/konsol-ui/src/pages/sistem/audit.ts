// The audit log's words (GET /api/konsol/islemler, DD-196): the root backend's own actions, the
// applications' ("uygulama-<verb>"), WireGuard's ("wireguard-<verb>", DD-271) and the file backend's ("dosya"). WireGuard's lines are templates over the
// detail ({detail} is the whole detail, {0}, {1} … its words).
import type { KayitSatiri } from "../../api/sema";

/** Gelişmiş's Podman resource jobs ("konteyner-<action>", JOB_CONTAINER_ACTIONS in master-panel). */
const CONTAINER: Record<string, string> = {
  "image-pull": "İmaj indirme", "image-remove": "İmaj silme", "volume-create": "Birim oluşturma", "volume-remove": "Birim silme",
  "network-create": "Ağ oluşturma", "network-remove": "Ağ silme",
};

/** The applications' jobs ("uygulama-<verb>", DD-271 phase 3); the detail names the application. */
const APP: Record<string, string> = {
  kur: "Uygulama kurulumu", baslat: "Uygulama başlatma", durdur: "Uygulama durdurma", "yeniden-baslat": "Uygulama yeniden başlatma",
  guncelle: "Uygulama imaj güncellemesi", tanim: "Uygulama tanım değişikliği", kaldir: "Uygulama kaldırma", taslak: "Uygulama taslağı",
};

/** WireGuard's lines (master_wireguard's audit verbs), as its page has always worded them. */
const WIREGUARD: Record<string, string> = {
  ekle: "{detail} eklendi",
  cikar: "{detail} silindi",
  dns: "{detail} için DNS değişti",
  keepalive: "{0} için keepalive {1} sn",
  "ag-ayarlar": "{detail} varsayılan DNS ayarı güncellendi",
  "peer-durum": "{0} {1}",
  "ag-durum": "{0} ağı {1}",
  "ag-ekle": "{detail} ağı oluşturuldu",
  "ag-kaldir": "{detail} ağı kaldırıldı",
  "yeniden-uret": "{detail} yeniden üretildi",
  qr: "{detail} QR kodu görüntülendi",
  profil: "{detail} profili indirildi",
  durdur: "WireGuard durduruldu",
  baslat: "WireGuard başlatıldı",
};

type Text = (e: KayitSatiri) => string;

const ACTION_TEXT: Record<string, Text> = {
  klasor: (e) => `Yeni klasör: ${e.detail}`,
  ad: (e) => `Yeniden adlandırıldı: ${e.detail}`,
  tasi: (e) => `Taşındı: ${e.detail}`,
  cope: (e) => `Çöpe taşındı: ${e.detail}`,
  "geri-yukle": (e) => `Çöpten geri yüklendi: ${e.detail}`,
  "kalici-sil": (e) => `Kalıcı silindi: ${e.detail}`,
  "cop-bosalt": (e) => `Çöp boşaltıldı (${e.detail} öge)`,
  indir: (e) => `İndirildi: ${e.detail}`,
  duzenle: (e) => `Düzenlendi: ${e.detail}`,
  "hesap-kur": () => "Konsol hesabı oluşturuldu",
  giris: () => "Konsol girişi",
  cikis: () => "Konsol çıkışı",
  "parola-degis": () => "Konsol parolası değiştirildi",
  "ayar-apply": () => "Ayarlar uygulandı",
  "ayar-confirm": () => "Ayar değişikliği onaylandı",
  "ayar-rollback": () => "Ayarlar geri alındı",
  "ayar-discard": () => "Takılan ayar işlemi bırakıldı",
  "paylasim-save": () => "Klasör paylaşımı kaydedildi",
  "paylasim-remove": () => "Klasör paylaşımı kaldırıldı",
  guncelleme: (e) => `Sunucu güncellemesi başlatıldı: ${e.detail}`,
  onarim: (e) => (e.detail === "denetle" ? "Denetim başlatıldı" : "Denetim ve onarım başlatıldı"),
  "yeniden-baslat": (e) => `Sunucunun yeniden başlatılması istendi (${e.detail})`,
};

export type Kind = "konsol" | "ayar" | "paylasim" | "wireguard" | "dosya" | "uygulama";

const LABELS: Record<Kind, string> = {
  konsol: "Konsol", ayar: "Ayarlar", paylasim: "Paylaşımlar", wireguard: "WireGuard", dosya: "Dosyalar", uygulama: "Uygulamalar",
};
/** The kinds in the order of the filter chips. */
export const KIND_ORDER: readonly Kind[] = ["konsol", "ayar", "paylasim", "wireguard", "dosya", "uygulama"];

export function kindOf(e: KayitSatiri): Kind {
  if (e.action.startsWith("konteyner-") || e.action.startsWith("uygulama-")) return "uygulama";
  if (e.source !== "panel") return "dosya";
  if (e.action.startsWith("ayar-")) return "ayar";
  if (e.action.startsWith("paylasim-")) return "paylasim";
  if (e.action.startsWith("wireguard-")) return "wireguard";
  return "konsol";
}

export const kindLabel = (kind: Kind): string => LABELS[kind];

/** The line in words; a failed action ends in "— başarısız". */
export function lineOf(e: KayitSatiri): string {
  let text: string;
  const known = ACTION_TEXT[e.action];
  const wireguard = e.action.startsWith("wireguard-") ? WIREGUARD[e.action.slice("wireguard-".length)] : undefined;
  if (known) text = known(e);
  else if (wireguard !== undefined) {
    const words = e.detail.split(" ");
    text = wireguard.replace(/\{(detail|\d)\}/g, (_, key: string) => (key === "detail" ? e.detail : words[Number(key)] ?? ""));
  } else if (e.action.startsWith("konteyner-")) {
    const action = e.action.slice("konteyner-".length);
    text = `${CONTAINER[action] ?? action} istendi: ${e.detail}`;
  } else if (e.action.startsWith("uygulama-")) {
    const verb = e.action.slice("uygulama-".length);
    text = `${APP[verb] ?? verb} istendi: ${e.detail}`;
  } else text = `${e.action} ${e.detail}`;
  return e.ok ? text : `${text} — başarısız`;
}
