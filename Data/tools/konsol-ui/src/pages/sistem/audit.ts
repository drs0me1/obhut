// The audit log's words (GET /api/konsol/islemler, DD-196/200), as the current Konsol writes them
// (console/konsol.js ACTION_TEXT, evKind, evText): the root backend's own actions, the file backend's
// ("dosya") and a package API's, which arrive as "<id>:<verb>" and take their words from the package's
// konsol.json `gunluk` templates ({detail} is the whole detail, {0}, {1} … its words).
import type { KayitSatiri, Modul } from "../../api/sema";

export interface Packages {
  name(id: string): string;
  template(id: string, verb: string): string | null;
}

export function packagesOf(modules: readonly Modul[]): Packages {
  const konsol = (id: string) => {
    const k = modules.find((m) => m.id === id)?.konsol;
    return k && typeof k === "object" ? k : null;
  };
  return {
    name(id) {
      const ad = konsol(id)?.ad;
      return typeof ad === "string" && ad ? ad : id;
    },
    template(id, verb) {
      const list = konsol(id)?.gunluk;
      const text = list && typeof list === "object" && !Array.isArray(list) ? (list as Record<string, unknown>)[verb] : null;
      return typeof text === "string" ? text : null;
    },
  };
}

/** The root backend's container operations (JOB_CONTAINER_ACTIONS in master-panel). */
const CONTAINER: Record<string, string> = {
  create: "Konteyner oluşturma", save: "Konteyner ayar kaydı", start: "Konteyner başlatma", stop: "Konteyner durdurma",
  restart: "Konteyner yeniden başlatma", remove: "Konteyner kaldırma", adopt: "Konteyner sahiplenme", "image-pull": "İmaj indirme",
  "image-remove": "İmaj silme", "image-update": "İmaj güncelleme", "volume-create": "Birim oluşturma", "volume-remove": "Birim silme",
  "network-create": "Ağ oluşturma", "network-remove": "Ağ silme",
};

type Text = (e: KayitSatiri, p: Packages) => string;
const pkg = (detail: string, p: Packages) => p.name(String(detail || "").split(" ")[0] ?? "");

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
  favori: (e) => `${e.detail.startsWith("+") ? "Favorilere eklendi" : "Favorilerden çıkarıldı"}: ${e.detail.slice(2)}`,
  "modul-kur": (e, p) => `${pkg(e.detail, p)} kurulumu başlatıldı`,
  "modul-baslat": (e, p) => `${pkg(e.detail, p)} başlatıldı`,
  "modul-durdur": (e, p) => `${pkg(e.detail, p)} durduruldu`,
  "modul-yeniden-baslat": (e, p) => `${pkg(e.detail, p)} yeniden başlatıldı`,
  "modul-kaldir": (e, p) => `${pkg(e.detail, p)} kaldırıldı${e.detail.endsWith("+veri") ? " · verisiyle" : ""}`,
  "modul-hesap": (e, p) => `${pkg(e.detail, p)} parolası görüntülendi`,
  "arsiv-olustur": (e) => `ZIP oluşturma başladı: ${e.detail}`,
  "arsiv-ac": (e) => `Arşiv açma başladı: ${e.detail}`,
  "arsiv-iptal": (e) => `Arşiv işlemi için iptal istendi: ${e.detail}`,
  "arsiv-sonuc": (e) => `Arşiv işlemi bitti: ${e.detail}`,
  "hesap-kur": () => "Konsol hesabı oluşturuldu",
  giris: () => "Konsol girişi",
  cikis: () => "Konsol çıkışı",
  "parola-degis": () => "Konsol parolası değiştirildi",
  duzen: (e) => (e.detail === "sifirla" ? "Ana Menü varsayılan düzene döndü" : "Ana Menü düzeni kaydedildi"),
  "ayar-apply": () => "Ayarlar uygulandı",
  "ayar-confirm": () => "Ayar değişikliği onaylandı",
  "ayar-rollback": () => "Ayarlar geri alındı",
  "ayar-discard": () => "Takılan ayar işlemi bırakıldı",
  "paylasim-save": () => "Klasör paylaşımı kaydedildi",
  "paylasim-pause": () => "Klasör paylaşımının durumu değişti",
  "paylasim-remove": () => "Klasör paylaşımı kaldırıldı",
  guncelleme: (e) => `Sunucu güncellemesi başlatıldı: ${e.detail}`,
  onarim: (e) => (e.detail === "denetle" ? "Denetim başlatıldı" : "Denetim ve onarım başlatıldı"),
  "yeniden-baslat": (e) => `Sunucunun yeniden başlatılması istendi (${e.detail})`,
};

export type Kind = "konsol" | "ayar" | "paylasim" | "dosya" | "uygulama" | string;

const LABELS: Record<string, string> = { konsol: "Konsol", ayar: "Ayarlar", paylasim: "Paylaşımlar", dosya: "Dosyalar", uygulama: "Uygulamalar" };
/** The fixed kinds in the order of the filter chips; packages follow in the order they appear. */
export const KIND_ORDER = ["konsol", "ayar", "paylasim", "dosya", "uygulama"];

export function kindOf(e: KayitSatiri): Kind {
  if (e.action.startsWith("modul-") || e.action.startsWith("konteyner-")) return "uygulama";
  if (e.source !== "panel") return "dosya";
  if (e.action.includes(":")) return e.action.split(":")[0] ?? "konsol";
  if (e.action.startsWith("ayar-")) return "ayar";
  if (e.action.startsWith("paylasim-")) return "paylasim";
  return "konsol";
}

export function kindLabel(kind: Kind, p: Packages): string {
  return LABELS[kind] ?? p.name(kind);
}

/** The line in words; a failed action ends in "— başarısız". */
export function lineOf(e: KayitSatiri, p: Packages): string {
  let text: string;
  const known = ACTION_TEXT[e.action];
  if (known) text = known(e, p);
  else if (e.action.startsWith("konteyner-")) {
    const action = e.action.slice("konteyner-".length);
    text = `${CONTAINER[action] ?? action} istendi: ${e.detail}`;
  } else if (e.action.includes(":")) {
    const [id = "", verb = ""] = e.action.split(":");
    const template = p.template(id, verb);
    const words = e.detail.split(" ");
    text = template !== null
      ? template.replace(/\{(detail|\d)\}/g, (_, key: string) => (key === "detail" ? e.detail : words[Number(key)] ?? ""))
      : `${p.name(id)}: ${verb} ${e.detail}`;
  } else text = `${e.action} ${e.detail}`;
  return e.ok ? text : `${text} — başarısız`;
}
