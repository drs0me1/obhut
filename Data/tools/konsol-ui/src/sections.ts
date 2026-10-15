// The six sections of the new Konsol (DD-258, redesign.md): Genel Bakış and Uygulamalar (phase 2), Erişim
// (phase 3), Sistem and Gelişmiş (phase 4a), Dosyalar (phase 4b); each section's tabs and add flows, and
// where the addresses of the Konsol before phase 4b lead (oldHome).
import type { IconName } from "./components/icons";

export type SectionId = "genel" | "uygulamalar" | "erisim" | "dosyalar" | "sistem" | "gelismis";

export interface Section {
  id: SectionId;
  title: string;
  /** The label under the icon in the phone's bottom bar. */
  short: string;
  description: string;
  icon: IconName;
  /** Extra words the command palette matches. */
  keywords: string;
}

export const SECTIONS: readonly Section[] = [
  {
    id: "genel",
    title: "Genel Bakış",
    short: "Genel",
    description: "Sağlık, uygulamalar, kaynaklar ve sunucu bir bakışta.",
    icon: "home",
    keywords: "ana menü özet durum sağlık kaynaklar",
  },
  {
    id: "uygulamalar",
    title: "Uygulamalar",
    short: "Uygulamalar",
    description: "App Store paketleri, konteynerler ve yerleşik hizmetler tek listede.",
    icon: "apps",
    keywords: "app store mağaza paket konteyner podman kur kaldır",
  },
  {
    id: "erisim",
    title: "Erişim",
    short: "Erişim",
    description: "Kim, neye, nereden erişebilir.",
    icon: "globe",
    keywords: "yayın yayınla adres alan adı tailscale wireguard internet https sertifika caddy dns güvenlik duvarı",
  },
  {
    id: "dosyalar",
    title: "Dosyalar",
    short: "Dosyalar",
    description: "Dosyalar, depolama ve sistem dosyaları.",
    icon: "folder",
    keywords: "klasör dosya depolama disk paylaşım çöp kutusu",
  },
  {
    id: "sistem",
    title: "Sistem",
    short: "Sistem",
    description: "Sağlık, güncellemeler, hesap, sunucu, görünüm ve günlük.",
    icon: "server",
    keywords: "sağlık onarım güncelleme sürüm hesap oturum görünüm tema günlük",
  },
  {
    id: "gelismis",
    title: "Gelişmiş",
    short: "Gelişmiş",
    description: "Teknik görünümler: Caddy, DNS, güvenlik duvarı ve Podman.",
    icon: "sliders",
    keywords: "teknik caddy dns kayıt güvenlik duvarı kural port podman imaj ağ",
  },
];

export const sectionById = (id: unknown): Section =>
  SECTIONS.find((s) => s.id === id) ?? (SECTIONS[0] as Section);

/** Erişim's tabs (phase 3), in the address as ?sekme=; the palette lists each one. */
export const ACCESS_TABS = [
  { id: "genel", label: "Genel", keywords: "erişim matris kim nereden uyarı sertifika özet" },
  { id: "adresler", label: "Adresler", keywords: "adres yayın alan adı caddy https sertifika dns dnsmasq yerel ad kayıt yönlendirme elle" },
  { id: "tailscale", label: "Tailscale", keywords: "tailnet cihaz anahtar çıkış düğümü exit node" },
  { id: "wireguard", label: "WireGuard", keywords: "vpn ağ cihaz peer qr profil" },
  { id: "guvenlik-duvari", label: "Güvenlik duvarı", keywords: "firewall port kural iptables dinleyici" },
] as const;

export type AccessTab = (typeof ACCESS_TABS)[number]["id"];

/** The address of an Erişim tab; `yayinla` opens the Yayınla flow over it (a candidate's id, "sec" to choose
    first, "yeni" for another port on this server). */
export function accessRoute(tab: AccessTab = "genel", yayinla = ""): string {
  const query = new URLSearchParams();
  if (tab !== "genel") query.set("sekme", tab);
  if (yayinla) query.set("yayinla", yayinla);
  const text = query.toString();
  return "/erisim" + (text ? "?" + text : "");
}

/** Sistem's tabs (phase 4a), in the address as ?sekme=; the palette lists each one. */
export const SYSTEM_TABS = [
  { id: "saglik", label: "Sağlık", keywords: "sağlık denetim onarım denetle onar master-onar günlük" },
  { id: "guncellemeler", label: "Güncellemeler", keywords: "güncelleme sürüm yeni sürüm github yükselt" },
  { id: "hesap", label: "Hesap", keywords: "hesap oturum parola giriş çıkış kullanıcı" },
  { id: "sunucu", label: "Sunucu", keywords: "sunucu çekirdek işletim sistemi yeniden başlat reboot açık kalma" },
  { id: "gorunum", label: "Görünüm", keywords: "görünüm tema renk" },
  { id: "gunluk", label: "Günlük", keywords: "günlük kayıt işlem geçmişi log denetim kaydı" },
] as const;

export type SystemTab = (typeof SYSTEM_TABS)[number]["id"];

/** Gelişmiş's tabs (phase 4a), in the address as ?sekme=. */
export const ADVANCED_TABS = [
  { id: "caddy", label: "Caddy", keywords: "caddy site yapılandırma caddyfile ham yönlendirme proxy" },
  { id: "dns", label: "DNS", keywords: "dns dnsmasq kayıt ad dinleme dhcp" },
  { id: "guvenlik-duvari", label: "Güvenlik duvarı", keywords: "güvenlik duvarı iptables teknik kural zincir" },
  { id: "podman", label: "Podman", keywords: "podman imaj birim volume ağ network çek" },
] as const;

export type AdvancedTab = (typeof ADVANCED_TABS)[number]["id"];

/** The address of a Sistem tab. */
export function systemRoute(tab: SystemTab = "saglik"): string {
  return tab === "saglik" ? "/sistem" : "/sistem?sekme=" + tab;
}

/** The address of a Gelişmiş tab. */
export function advancedRoute(tab: AdvancedTab = "caddy"): string {
  return tab === "caddy" ? "/gelismis" : "/gelismis?sekme=" + tab;
}

/** Dosyalar's tabs (phase 4b), in the address as ?sekme=. Sistem dosyaları shows only on the tailnet. */
export const FILES_TABS = [
  { id: "depolama", label: "Depolama", keywords: "depolama disk alan klasör kullanan uygulama" },
  { id: "srv", label: "Sunucu klasörleri", keywords: "dosya klasör yükle indir yeni klasör ad taşı srv kullanıcı alanı düzenle" },
  { id: "cop", label: "Çöp kutusu", keywords: "çöp geri yükle kalıcı sil boşalt" },
  { id: "paylasimlar", label: "Paylaşımlar", keywords: "paylaşım webdav klasör paylaş infuse finder bağlantı süre" },
  { id: "sistem", label: "Sistem dosyaları", keywords: "kök root sistem dosya etc yapılandırma düzenle" },
] as const;

export type FilesTab = (typeof FILES_TABS)[number]["id"];

/** The address of a Dosyalar tab, with extra query values (a folder: yol=). */
export function filesRoute(tab: FilesTab = "depolama", extra: Record<string, string> = {}): string {
  const query = new URLSearchParams(tab === "depolama" ? extra : { sekme: tab, ...extra }).toString();
  return "/dosyalar" + (query ? "?" + query : "");
}

/** Each section's tabs for the command palette (its first tab is the section itself). */
export const SECTION_TABS: Partial<Record<SectionId, readonly { id: string; label: string; keywords: string; to: string }[]>> = {
  erisim: ACCESS_TABS.map((t) => ({ ...t, to: accessRoute(t.id) })),
  sistem: SYSTEM_TABS.map((t) => ({ ...t, to: systemRoute(t.id) })),
  gelismis: ADVANCED_TABS.map((t) => ({ ...t, to: advancedRoute(t.id) })),
  dosyalar: FILES_TABS.map((t) => ({ ...t, to: filesRoute(t.id) })),
};

/** Uygulamalar' add flows (phase 4a), opened over the list with ?ekle= (a package's install with &paket=,
    one container's adoption with &ad=); the palette lists each one. */
export const ADD_FLOWS = [
  { id: "katalog", label: "Katalogdan uygulama kur", keywords: "app store mağaza paket kur katalog ekle" },
  { id: "imaj", label: "İmajdan konteyner oluştur", keywords: "konteyner podman imaj yeni oluştur docker ekle" },
  { id: "sahiplen", label: "Var olan konteyneri yönetime al", keywords: "benimse sahiplen konteyner podman dışarıda yönet" },
] as const;

export type AddFlow = (typeof ADD_FLOWS)[number]["id"];

/** The address of an add flow over Uygulamalar. */
export function addRoute(flow: AddFlow, extra: Record<string, string> = {}): string {
  return "/uygulamalar?" + new URLSearchParams({ ekle: flow, ...extra }).toString();
}

/** A folder path from an old address's parts, each URI-encoded ("Filmler%20Yeni", "Diziler"); "" when a part
    cannot be decoded or would leave the folder (".", ".."), so the view opens at its top. */
function oldFolder(parts: readonly string[]): string {
  try {
    const decoded = parts.map((p) => decodeURIComponent(p));
    return decoded.some((p) => !p || p === "." || p === ".." || p.includes("/") || p.includes("\0")) ? "" : decoded.join("/");
  } catch {
    return "";
  }
}

const OLD_SETTINGS = new Map<string, string>([
  ["fw", accessRoute("guvenlik-duvari")],
  ["web", accessRoute("adresler")],
  ["dns", accessRoute("adresler")],
  ["log", systemRoute("gunluk")],
  ["konteynerler", advancedRoute("podman")],
]);

/** Where an address of the Konsol before phase 4b leads (its hash route, "/ayarlar/fw"): App Store and the
    Podman page to Uygulamalar, Settings' tabs to Erişim, Sistem and Gelişmiş, Files' views to Dosyalar' tabs,
    WireGuard's page to Erişim. Null when the new home depends on what is installed (a package's own page
    "/torrent", "/moduller/<id>", a container "/konteynerler/<ad>") or the address is not an old one. */
export function oldHome(path: string): string | null {
  const [head, sub, ...rest] = path.split("/").filter(Boolean);
  switch (head) {
    case "moduller":
      return sub ? null : addRoute("katalog");
    case "konteynerler":
      return sub ? null : "/uygulamalar";
    case "ayarlar":
      if (sub === "konteynerler" && rest.length) return null;
      return OLD_SETTINGS.get(sub ?? "") ?? systemRoute();
    case "dosyalar": {
      if (sub === "klasor" || sub === "sistem") {
        const yol = oldFolder(rest);
        return filesRoute(sub === "klasor" ? "srv" : "sistem", yol ? { yol } : {});
      }
      if (sub === "cop") return filesRoute("cop");
      if (sub === "paylasim") return filesRoute("paylasimlar");
      return "/dosyalar";
    }
    case "wireguard":
      return sub ? null : accessRoute("wireguard");
  }
  return null;
}
