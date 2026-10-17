// The six sections of Konsol (DD-258, docs/archive/redesign.md): Genel Bakış and Uygulamalar (phase 2), Erişim
// (phase 3), Sistem and Gelişmiş (phase 4a), Dosyalar (phase 4b); each section's tabs and add flows.
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
    description: "Sağlık, uygulamalar, erişim ve sunucu bir bakışta.",
    icon: "home",
    keywords: "ana menü özet durum sağlık dikkat kaynaklar ağ erişim özeti",
  },
  {
    id: "uygulamalar",
    title: "Uygulamalar",
    short: "Uygulamalar",
    description: "Uygulamalar ve servisleri tek listede.",
    icon: "apps",
    keywords: "uygulama servis konteyner podman imaj compose kubernetes başlat durdur kaldır",
  },
  {
    id: "erisim",
    title: "Erişim",
    short: "Erişim",
    description: "Kim, neye, nereden erişir.",
    icon: "globe",
    keywords: "adres ham port alan adı tailscale wireguard internet https sertifika caddy dns güvenlik duvarı",
  },
  {
    id: "dosyalar",
    title: "Dosyalar",
    short: "Dosyalar",
    description: "Sunucunun klasörleri ve paylaşımları.",
    icon: "folder",
    keywords: "klasör dosya depolama disk paylaşım çöp kutusu uygulama verileri",
  },
  {
    id: "sistem",
    title: "Sistem",
    short: "Sistem",
    description: "Obhut'un kendisi: sağlık, sürüm, hesap ve sunucu.",
    icon: "server",
    keywords: "sağlık onarım kaydı güncelleme sürüm hesap oturum sunucu işlem geçmişi",
  },
  {
    id: "gelismis",
    title: "Gelişmiş",
    short: "Gelişmiş",
    description: "Salt okunur teknik görünümler; tek işlem temizlik.",
    icon: "sliders",
    keywords: "teknik caddy dns kayıt güvenlik duvarı kural port podman imaj ağ temizlik",
  },
];

export const sectionById = (id: unknown): Section =>
  SECTIONS.find((s) => s.id === id) ?? (SECTIONS[0] as Section);

/** Erişim's tabs (rebuild phase 5, A7), in the address as ?sekme=; the palette lists each one. */
export const ACCESS_TABS = [
  { id: "genel", label: "Genel", keywords: "erişim matris kim nereden sertifika özet" },
  { id: "adresler", label: "Adresler", keywords: "adres aç ham port tailscale adı tailscale portu internet adı caddy https sertifika" },
  { id: "adlar", label: "Yerel adlar", keywords: "yerel ad dns dnsmasq kayıt yönlendirme üst dns yerel alan adı" },
  { id: "tailscale", label: "Tailscale", keywords: "tailnet cihaz anahtar çıkış düğümü exit node" },
  { id: "wireguard", label: "WireGuard", keywords: "vpn ağ cihaz peer qr profil" },
  { id: "guvenlik-duvari", label: "Güvenlik duvarı", keywords: "firewall port kural izin" },
] as const;

export type AccessTab = (typeof ACCESS_TABS)[number]["id"];

/** The address of an Erişim tab; on Adresler `satir` opens an access row's sheet (its id: panel, paylasim or
    uygulama:<app>:<service>:<port>/<proto>, rebuild phase 4) and `kip` "adres-ac" opens it as "Adres aç". */
export function accessRoute(tab: AccessTab = "genel", satir = "", kip: "" | "adres-ac" = ""): string {
  const query = new URLSearchParams();
  if (tab !== "genel") query.set("sekme", tab);
  if (satir) query.set("satir", satir);
  if (kip) query.set("kip", kip);
  const text = query.toString();
  return "/erisim" + (text ? "?" + text : "");
}

/** Sistem's tabs (A7), in the address as ?sekme=; the palette lists each one. The theme is the top bar's and the
    palette's, not a tab's. */
export const SYSTEM_TABS = [
  { id: "saglik", label: "Sağlık", keywords: "sağlık denetim onarım denetle onar master-onar onarım kaydı" },
  { id: "guncellemeler", label: "Güncellemeler", keywords: "güncelleme sürüm yeni sürüm github yükselt imaj uygulama güncellemesi" },
  { id: "hesap", label: "Hesap", keywords: "hesap oturum parola giriş çıkış kullanıcı" },
  { id: "sunucu", label: "Sunucu", keywords: "sunucu çekirdek işletim sistemi yeniden başlat reboot açık kalma" },
  { id: "gecmis", label: "İşlem geçmişi", keywords: "işlem geçmişi kayıt log denetim kaydı kim ne yaptı" },
] as const;

export type SystemTab = (typeof SYSTEM_TABS)[number]["id"];

/** Gelişmiş's tabs (K8), in the address as ?sekme=: read-only views; Podman's cleanup is the only write. */
export const ADVANCED_TABS = [
  { id: "caddy", label: "Caddy", keywords: "caddy site yapılandırma caddyfile ham yönlendirme proxy" },
  { id: "dns", label: "DNS", keywords: "dns dnsmasq kayıt ad dinleme dhcp" },
  { id: "guvenlik-duvari", label: "Güvenlik duvarı", keywords: "güvenlik duvarı iptables nftables teknik kural zincir dinleyici" },
  { id: "podman", label: "Podman", keywords: "podman imaj birim volume ağ network temizlik temizle kullanılmayan sahipsiz konteyner" },
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
