// How an application (GET /api/konsol/uygulamalar, DD-261) is shown everywhere: its state, how it is
// reached, whether it needs attention, where "Aç" leads, its resources and version, its icon. One place,
// so Genel Bakış, Uygulamalar, the application page and the palette say the same thing.
import type { IconName } from "./components/icons";
import type { Tone } from "./components/ui/types";
import type { ErisimDurumu, Uygulama, UygulamaHucresi } from "./api/sema";
import { UNKNOWN, bytes, percent } from "./format";

export type AppState = Uygulama["durum"];
export type AppAction = Uygulama["eylemler"][number];

const STATES: Record<Exclude<AppState, "islemde">, { text: string; tone: Tone }> = {
  calisiyor: { text: "Çalışıyor", tone: "ok" },
  durduruldu: { text: "Durdurulmuş", tone: "neutral" },
  hata: { text: "Sorun var", tone: "danger" },
  bilinmiyor: { text: UNKNOWN, tone: "neutral" },
};

// An operation's verb while its own progress line is empty (engine verbs and the action names).
const DOING: Record<string, string> = {
  kur: "Kuruluyor…",
  baslat: "Başlatılıyor…",
  durdur: "Durduruluyor…",
  "yeniden-baslat": "Yeniden başlatılıyor…",
  guncelle: "Güncelleniyor…",
  kaldir: "Kaldırılıyor…",
};

/** The state pill: "Çalışıyor", "Durdurulmuş", the running operation's text, "Sorun var" or "—". */
export function appState(app: Pick<Uygulama, "durum" | "islem">): { text: string; tone: Tone } {
  if (app.durum === "islemde") {
    const op = app.islem;
    return { text: op?.metin || (op ? DOING[op.eylem] : "") || "İşlemde…", tone: "accent" };
  }
  return STATES[app.durum] ?? { text: UNKNOWN, tone: "neutral" };
}

/** Dikkat: a failed state, a warning on how it is reached, or a newer image waiting for the operator. */
export function needsAttention(app: Uygulama): boolean {
  return app.durum === "hata" || Boolean(app.tailscale.uyari) || Boolean(app.internet.uyari) || app.guncelleme === "yeni";
}

// "bilinmiyor": the image can move but Konsol has not checked it yet (the backend starts that check and it
// becomes guncel/yeni within about a minute); like "sabit" it shows nothing and is never an error.
const UPDATE_TEXTS: Record<Uygulama["guncelleme"], string> = {
  guncel: "Güncel",
  yeni: "Yeni sürüm",
  denetlenemedi: "Denetlenemedi",
  bilinmiyor: UNKNOWN,
  sabit: UNKNOWN,
};

/** The version column: "Güncel", "Yeni sürüm", "Denetlenemedi", or "—" (not checked yet, or a fixed image). */
export const updateText = (state: Uygulama["guncelleme"]): string => UPDATE_TEXTS[state] ?? UNKNOWN;

/** Whether there is a version state worth a line of its own. */
export const hasUpdateState = (state: Uygulama["guncelleme"]): boolean => state === "guncel" || state === "yeni" || state === "denetlenemedi";

export interface AccessChip {
  scope: "tailscale" | "internet";
  text: string;
  tone: Tone;
  /** The cell's note, read out after the chip's text. */
  detail: string;
}

const SCOPES = [
  ["tailscale", "Tailscale"],
  ["internet", "İnternet"],
] as const;

/** One chip per cell that applies: open, partly open, closed or failing; a warning ("Şifresiz HTTP") wins. */
export function accessChips(app: Pick<Uygulama, "tailscale" | "internet">): AccessChip[] {
  const out: AccessChip[] = [];
  for (const [scope, label] of SCOPES) {
    const c: UygulamaHucresi = app[scope];
    if (c.uyari) out.push({ scope, text: `${label} · ${c.uyari}`, tone: "warning", detail: c.not });
    else if (c.durum === "acik") out.push({ scope, text: label, tone: "ok", detail: c.not });
    else if (c.durum === "kismen") out.push({ scope, text: `${label} · kısmen`, tone: "accent", detail: c.not });
    else if (c.durum === "hata") out.push({ scope, text: `${label} · sorun`, tone: "danger", detail: c.not });
    else if (c.durum === "kapali") out.push({ scope, text: `${label} kapalı`, tone: "neutral", detail: c.not });
  }
  return out;
}

export const CELL_TEXT: Record<ErisimDurumu, string> = { acik: "Açık", kismen: "Kısmen", kapali: "Kapalı", yok: UNKNOWN, hata: "Sorun var" };
export const CELL_TONE: Record<ErisimDurumu, Tone> = { acik: "ok", kismen: "accent", kapali: "neutral", yok: "neutral", hata: "danger" };

function host(url: string | null): string | null {
  if (!url) return null;
  try {
    return new URL(url).host || null;
  } catch {
    return null;
  }
}

/** The overview card's line: the address and how far it reaches ("torrent.ev · internette kısmen açık"). */
export function accessLine(app: Uygulama): string {
  const parts: string[] = [];
  const name = host(app.adres.tailscale) ?? host(app.adres.internet) ?? app.tailscale.adresler.find((a) => /^[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+$/.test(a));
  if (name) parts.push(name);
  const net = app.internet;
  if (net.durum === "acik") parts.push(net.uyari ? `internette açık · ${net.uyari}` : "internette açık");
  else if (net.durum === "kismen") parts.push("internette kısmen açık");
  else if (net.durum === "hata") parts.push("internet yayınında sorun");
  else if (app.tailscale.durum === "acik") parts.push("yalnız Tailscale");
  return parts.join(" · ") || app.aciklama || UNKNOWN;
}

const WEB = /^https?:\/\/[^\s]+$/i;

/** Where "Aç" goes: the application's own address in a new tab (the internet name when this page itself
    came over HTTPS, else the tailnet name; the other one when only that exists), or for a built-in its
    page in the current interface. None when the application has neither. */
export function openTarget(app: Pick<Uygulama, "adres" | "tur" | "sayfa">, https = location.protocol === "https:"): { href: string; external: boolean } | null {
  const [first, second] = https ? [app.adres.internet, app.adres.tailscale] : [app.adres.tailscale, app.adres.internet];
  const url = [first, second].find((u): u is string => typeof u === "string" && WEB.test(u));
  if (url) return { href: url, external: true };
  if (app.tur === "yerlesik" && app.sayfa?.startsWith("#/")) return { href: "/" + app.sayfa, external: false };
  return null;
}

/** The application's page in the current interface ("/#/torrent"), for what is not built here yet. */
export function legacyPage(app: Pick<Uygulama, "sayfa">): string | null {
  return app.sayfa?.startsWith("#/") ? "/" + app.sayfa : null;
}

/** "%1 · 84 MB"; "—" when neither is known. */
export function resourceText(app: Pick<Uygulama, "kaynak">): string {
  const parts = [app.kaynak.cpu, app.kaynak.bellek].map((v, i) => (v === null ? null : i === 0 ? percent(v) : bytes(v))).filter((v): v is string => v !== null);
  return parts.length ? parts.join(" · ") : UNKNOWN;
}

const ICONS: Record<string, IconName> = { download: "download", shield: "shield", folder: "folder", share: "share", box: "box", globe: "globe" };

export function appIcon(app: Pick<Uygulama, "id" | "simge" | "tur">): IconName {
  if (app.simge && ICONS[app.simge]) return ICONS[app.simge] as IconName;
  if (app.id === "yerlesik:dosya") return "folder";
  if (app.id === "yerlesik:paylasim") return "share";
  return "box";
}

// The prototype's colours for the known icons; any other application gets one by its id.
const TILES: Partial<Record<IconName, number>> = { folder: 1, download: 2, shield: 3, share: 4 };

/** One of four tile colours, always the same for the same application. */
export function appTile(app: Pick<Uygulama, "id" | "simge" | "tur">): number {
  const known = TILES[appIcon(app)];
  if (known) return known;
  let sum = 0;
  for (const ch of app.id) sum = (sum + (ch.codePointAt(0) ?? 0)) % 9973;
  return (sum % 4) + 1;
}

/** An image reference with its digest shortened ("…/qbittorrent@sha256:0123456789ab…"). */
export function shortImage(image: string): string {
  const at = image.indexOf("@sha256:");
  if (at < 0) return image;
  const digest = image.slice(at + 8);
  return digest.length > 12 ? `${image.slice(0, at)}@sha256:${digest.slice(0, 12)}…` : image;
}

export const KIND_TEXT: Record<Uygulama["tur"], string> = { paket: "App Store paketi", konteyner: "Konteyner", yerlesik: "Yerleşik" };
