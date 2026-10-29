// İşlem geçmişi's words (GET /api/konsol/islemler, DD-276, A7): every line the backends write, in the interface's
// words. The root backend's own actions (the account, the update, the reboot, repair, the folder shares), the
// settings transaction's ("ayar-<step>", its detail naming an access row, a WireGuard action or "ayarlar"; the same
// names the pending banner uses), the applications' ("uygulama-<verb>"), Podman's cleanup ("temizlik") and one
// container's actions ("konteyner-<verb>", DD-294),
// WireGuard's device actions ("wireguard-<verb>") and the file backends' (source "dosya").
import { SCOPE_TEXT } from "../../access";
import type { KayitSatiri, WireGuardEylemi } from "../../api/sema";

/** The applications' jobs ("uygulama-<verb>"); the detail names the application. */
const APP: Record<string, string> = {
  kur: "Uygulama kurulumu", baslat: "Uygulama başlatma", durdur: "Uygulama durdurma", "yeniden-baslat": "Uygulama yeniden başlatma",
  guncelle: "Uygulama imaj güncellemesi", tanim: "Uygulama tanım değişikliği", kaldir: "Uygulama kaldırma", taslak: "Taslak dosya",
};

/** One container's actions ("konteyner-<verb>", DD-294); the detail names the container. */
const CONTAINER: Record<string, string> = {
  baslat: "Konteyner başlatma", durdur: "Konteyner durdurma", "yeniden-baslat": "Konteyner yeniden başlatma", kaldir: "Konteyner kaldırma",
};

/** WireGuard's device lines (master_wireguard's audit verbs; {detail} is the whole detail, {0}, {1} … its words). */
const WIREGUARD: Record<string, string> = {
  ekle: "{detail} cihazı eklendi",
  cikar: "{detail} cihazı silindi",
  dns: "{detail} cihazının DNS'i değişti",
  keepalive: "{0} cihazının canlı tutma süresi: {1} sn",
  "ag-ayarlar": "{detail} ağının adı ve varsayılan DNS'i güncellendi",
  "peer-durum": "{0} cihazı {1}",
  qr: "{detail} QR kodu görüntülendi",
  profil: "{detail} profili indirildi",
};

/** A settings action's WireGuard subject (DD-275), as the pending banner names it. */
const WIREGUARD_ACTION: Record<WireGuardEylemi, (iface: string) => string> = {
  baslat: () => "WireGuard'ı aç",
  durdur: () => "WireGuard'ı kapat",
  "ag-ekle": () => "WireGuard ağı ekle",
  "ag-kaldir": (iface) => `${iface} ağını kaldır`,
  "ag-ac": (iface) => `${iface} ağını aç`,
  "ag-kapat": (iface) => `${iface} ağını kapat`,
  "yeniden-uret": (iface) => `${iface} anahtarını yeniden üret`,
};

/** The settings transaction's steps. */
const STEP: Record<string, string> = { apply: "uygulandı", confirm: "onaylandı", rollback: "geri alındı", discard: "bırakıldı" };

/** An access row's id (uygulama:<app>:<service>:<port>/<proto>) in words: "notlar · web 8080/TCP". */
function rowWords(id: string): string {
  const match = /^uygulama:([^:]+):(.+):(\d+)\/(tcp|udp)$/.exec(id);
  return match ? `${match[1]} · ${match[2]} ${match[3]}/${(match[4] as string).toUpperCase()}` : id;
}

/** What a settings action changed, from its detail (master_settings.audit_detail). */
function settingsSubject(detail: string): string {
  const words = detail.split(" ");
  if (words[0] === "wireguard" && words[1]) {
    const name = WIREGUARD_ACTION[words[1] as WireGuardEylemi];
    const port = /UDP \d+$/.exec(detail)?.[0];
    const iface = words[2] && /^wg\d$/.test(words[2]) ? words[2] : "ağ";
    return name ? name(iface) + (port && words[1] === "ag-ekle" ? ` (${port})` : "") : "WireGuard değişikliği";
  }
  if (words[0] === "erisim") {
    if (!words[1]) return "Erişim değişikliği";
    const row = rowWords(words[1]);
    if (words[2] === "ham") {
      const scope = SCOPE_TEXT[words[3] as keyof typeof SCOPE_TEXT] ?? words[3] ?? "";
      return `Erişim değişikliği · ${row} (doğrudan port, ${scope.toLocaleLowerCase("tr")}, sunucu portu ${words[4] ?? "?"})`;
    }
    if (words[2] === "adres") {
      // erisim <id> adres <ad> tailscale-portu <port|kapali> internet <name|kapali>
      const tsPort = words[5] === "kapali" ? "kapalı" : words[5];
      const internet = words[7] === "kapali" ? "kapalı" : words[7];
      return `Erişim değişikliği · ${row} (Tailscale adı ${words[3]}, Tailscale portu ${tsPort}, internet adı ${internet})`;
    }
    return `Erişim değişikliği · ${row}`;
  }
  return "Güvenlik duvarı, yerel adlar ya da alan adı değişikliği";
}

type Text = (e: KayitSatiri) => string;

const ACTION_TEXT: Record<string, Text> = {
  // the file backends
  klasor: (e) => `Yeni klasör: ${e.detail}`,
  ad: (e) => `Yeniden adlandırıldı: ${e.detail}`,
  tasi: (e) => `Taşındı: ${e.detail}`,
  cope: (e) => `Çöpe taşındı: ${e.detail}`,
  "geri-yukle": (e) => `Çöpten geri yüklendi: ${e.detail}`,
  "kalici-sil": (e) => `Çöpten kalıcı silindi: ${e.detail}`,
  "cop-bosalt": (e) => `Çöp boşaltıldı (${e.detail} öge)`,
  sil: (e) => `Kalıcı silindi (Sistem dosyaları): ${e.detail}`,
  "yükle": (e) => `Yüklendi: ${e.detail}`,
  indir: (e) => `İndirildi: ${e.detail}`,
  duzenle: (e) => `Düzenlendi: ${e.detail}`,
  // the Konsol account
  "hesap-kur": () => "Konsol hesabı oluşturuldu",
  giris: () => "Konsol girişi",
  cikis: () => "Konsol çıkışı",
  "parola-degis": () => "Konsol parolası değiştirildi",
  // folder shares
  "paylasim-save": () => "Klasör paylaşımı kaydedildi",
  "paylasim-remove": () => "Klasör paylaşımı kaldırıldı",
  // Sistem
  guncelleme: (e) => `Obhut güncellemesi başlatıldı: ${e.detail}`,
  onarim: (e) => (e.detail === "denetle" ? "Denetim başlatıldı" : "Denetim ve onarım başlatıldı"),
  "yeniden-baslat": (e) => `Sunucunun yeniden başlatılması istendi (${e.detail})`,
  // Podman
  temizlik: (e) => `Podman temizliği istendi (${e.detail})`,
};

export type Kind = "konsol" | "erisim" | "wireguard" | "paylasim" | "dosya" | "uygulama" | "podman";

const LABELS: Record<Kind, string> = {
  konsol: "Konsol", erisim: "Erişim", wireguard: "WireGuard", paylasim: "Paylaşımlar", dosya: "Dosyalar", uygulama: "Uygulamalar",
  podman: "Podman",
};
/** The kinds in the order of the filter chips. */
export const KIND_ORDER: readonly Kind[] = ["konsol", "uygulama", "podman", "erisim", "wireguard", "paylasim", "dosya"];

export function kindOf(e: KayitSatiri): Kind {
  if (e.source !== "panel") return "dosya";
  if (e.action.startsWith("uygulama-")) return "uygulama";
  if (e.action.startsWith("wireguard-")) return "wireguard";
  if (e.action.startsWith("ayar-")) return e.detail.startsWith("wireguard ") ? "wireguard" : "erisim";
  if (e.action.startsWith("paylasim-")) return "paylasim";
  if (e.action === "temizlik" || e.action.startsWith("konteyner-")) return "podman";
  return "konsol";
}

export const kindLabel = (kind: Kind): string => LABELS[kind];

/** The line in words; a failed action ends in "— başarısız". */
export function lineOf(e: KayitSatiri): string {
  let text: string;
  const known = ACTION_TEXT[e.action];
  const wireguard = e.action.startsWith("wireguard-") ? WIREGUARD[e.action.slice("wireguard-".length)] : undefined;
  if (known) text = known(e);
  else if (e.action.startsWith("ayar-")) {
    const step = STEP[e.action.slice("ayar-".length)] ?? e.action.slice("ayar-".length);
    text = `${settingsSubject(e.detail)} · ${step}`;
  } else if (wireguard !== undefined) {
    const words = e.detail.split(" ");
    text = wireguard.replace(/\{(detail|\d)\}/g, (_, key: string) => (key === "detail" ? e.detail : words[Number(key)] ?? ""));
  } else if (e.action.startsWith("uygulama-")) {
    const verb = e.action.slice("uygulama-".length);
    // A removal's detail says whether the data stays: "<app> (veri: sakla|sil)".
    const detail = e.detail.replace(/ \(veri: sakla\)$/, " (veriler saklanır)").replace(/ \(veri: sil\)$/, " (veriler silinir)");
    text = `${APP[verb] ?? verb} istendi: ${detail}`;
  } else if (e.action.startsWith("konteyner-")) {
    const verb = e.action.slice("konteyner-".length);
    text = `${CONTAINER[verb] ?? verb} istendi: ${e.detail}`;
  } else text = `${e.action} ${e.detail}`;
  return e.ok ? text : `${text} — başarısız`;
}
