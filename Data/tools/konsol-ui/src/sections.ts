// The six sections of the new Konsol (DD-258, redesign.md). In phase 1 each is a placeholder that links
// to the current interface ("/#/…"), where the work is still done.
import type { IconName } from "./components/icons";

export type SectionId = "genel" | "uygulamalar" | "erisim" | "dosyalar" | "sistem" | "gelismis";

export interface LegacyLink {
  href: string;
  label: string;
}

export interface Section {
  id: SectionId;
  title: string;
  /** The label under the icon in the phone's bottom bar. */
  short: string;
  description: string;
  icon: IconName;
  /** Extra words the command palette matches. */
  keywords: string;
  legacy: LegacyLink[];
}

export const SECTIONS: readonly Section[] = [
  {
    id: "genel",
    title: "Genel Bakış",
    short: "Genel",
    description: "Sağlık, uygulamalar, kaynaklar ve sunucu bir bakışta.",
    icon: "home",
    keywords: "ana menü özet durum sağlık kaynaklar",
    legacy: [{ href: "/#/genel", label: "Ana Menü" }],
  },
  {
    id: "uygulamalar",
    title: "Uygulamalar",
    short: "Uygulamalar",
    description: "App Store paketleri, konteynerler ve yerleşik hizmetler tek listede.",
    icon: "apps",
    keywords: "app store mağaza paket konteyner podman kur kaldır",
    legacy: [
      { href: "/#/moduller", label: "App Store" },
      { href: "/#/konteynerler", label: "Podman" },
    ],
  },
  {
    id: "erisim",
    title: "Erişim",
    short: "Erişim",
    description: "Kim, neye, nereden erişebilir.",
    icon: "globe",
    keywords: "yayın yayınla adres alan adı tailscale wireguard internet https sertifika caddy dns güvenlik duvarı",
    legacy: [
      { href: "/#/ayarlar/web", label: "Ayarlar → Caddy" },
      { href: "/#/ayarlar/dns", label: "Ayarlar → Dnsmasq" },
      { href: "/#/ayarlar/fw", label: "Ayarlar → Güvenlik Duvarı" },
      { href: "/#/wireguard", label: "WireGuard" },
    ],
  },
  {
    id: "dosyalar",
    title: "Dosyalar",
    short: "Dosyalar",
    description: "Dosyalar, depolama ve sistem dosyaları.",
    icon: "folder",
    keywords: "klasör dosya depolama disk paylaşım çöp kutusu",
    legacy: [{ href: "/#/dosyalar", label: "Dosyalar" }],
  },
  {
    id: "sistem",
    title: "Sistem",
    short: "Sistem",
    description: "Sağlık ve onarım, güncellemeler, hesap, görünüm ve günlük.",
    icon: "server",
    keywords: "sağlık onarım güncelleme sürüm hesap oturum görünüm tema günlük",
    legacy: [
      { href: "/#/ayarlar", label: "Ayarlar → Sistem" },
      { href: "/#/ayarlar/log", label: "Ayarlar → Günlük" },
    ],
  },
  {
    id: "gelismis",
    title: "Gelişmiş",
    short: "Gelişmiş",
    description: "Teknik görünümler: Caddy yapılandırması, DNS kayıtları, güvenlik duvarı kuralları ve Podman.",
    icon: "sliders",
    keywords: "teknik caddy dns kayıt güvenlik duvarı kural port podman imaj ağ",
    legacy: [{ href: "/#/ayarlar/fw", label: "Ayarlar → Güvenlik Duvarı" }],
  },
];

export const sectionById = (id: unknown): Section =>
  SECTIONS.find((s) => s.id === id) ?? (SECTIONS[0] as Section);

/** The current interface's views, for the palette's "Eski arayüz" group. */
export const LEGACY_VIEWS: readonly (LegacyLink & { keywords: string })[] = [
  { href: "/#/genel", label: "Ana Menü", keywords: "genel bakış ana sayfa" },
  { href: "/#/dosyalar", label: "Dosyalar", keywords: "klasör dosya paylaşım çöp" },
  { href: "/#/moduller", label: "App Store", keywords: "uygulama mağaza paket modül" },
  { href: "/#/konteynerler", label: "Podman", keywords: "konteyner imaj container" },
  { href: "/#/ayarlar", label: "Ayarlar → Sistem", keywords: "ayarlar sağlık onarım hesap güncelleme" },
  { href: "/#/ayarlar/web", label: "Ayarlar → Caddy", keywords: "ayarlar web yayın https alan adı" },
  { href: "/#/ayarlar/dns", label: "Ayarlar → Dnsmasq", keywords: "ayarlar dns kayıt ad" },
  { href: "/#/ayarlar/fw", label: "Ayarlar → Güvenlik Duvarı", keywords: "ayarlar firewall port kural" },
  { href: "/#/ayarlar/log", label: "Ayarlar → Günlük", keywords: "ayarlar log kayıt işlem geçmişi" },
];
