// How an application (GET /api/konsol/uygulamalar, DD-271) is shown everywhere: its state, whether it needs
// attention, its services, resources, live rate and version, where its file came from, how each service starts,
// how it is reached (from Erişim's rows), its first address and its tile colour. One place, so Genel Bakış,
// Uygulamalar, the application page and the palette say the same thing. Erişim's cell words live here too
// (CELL_TEXT, CELL_TONE).
import type { Tone } from "./components/ui/types";
import type { ErisimDurumu, Hizmet, KaynakTuru, Uygulama, UygulamaServisAyrintisi } from "./api/sema";
import { UNKNOWN, bytes, percent, rate } from "./format";

export type AppState = Uygulama["durum"];
export type AppAction = Uygulama["eylemler"][number];

const STATES: Record<AppState, { text: string; tone: Tone }> = {
  calisiyor: { text: "Çalışıyor", tone: "ok" },
  durduruldu: { text: "Durdurulmuş", tone: "neutral" },
  kismen: { text: "Kısmen çalışıyor", tone: "warning" },
  hata: { text: "Sorun var", tone: "danger" },
  islemde: { text: "İşlemde…", tone: "accent" },
};

/** The state pill of an application or of one of its services. */
export function appState(app: Pick<Uygulama, "durum">): { text: string; tone: Tone } {
  return STATES[app.durum] ?? { text: UNKNOWN, tone: "neutral" };
}

/** Dikkat: a failed or partly running application, a warning in its definition, or a newer image waiting for
    the operator. */
export function needsAttention(app: Uygulama): boolean {
  return app.durum === "hata" || app.durum === "kismen" || app.uyari > 0 || app.guncelleme === "yeni";
}

// "bilinmiyor": the image can move but Konsol has not checked it yet (the backend starts that check and it
// becomes "guncel" or "yeni" within about a minute); like "sabit" it shows nothing and is never an error.
const UPDATE_TEXTS: Record<Uygulama["guncelleme"], string> = {
  guncel: "Güncel",
  yeni: "Yeni imaj",
  denetlenemedi: "Denetlenemedi",
  bilinmiyor: UNKNOWN,
  sabit: UNKNOWN,
};

/** The update column: "Güncel", "Yeni imaj", "Denetlenemedi", or "—" (not checked yet, or a fixed image). */
export const updateText = (state: Uygulama["guncelleme"]): string => UPDATE_TEXTS[state] ?? UNKNOWN;

export const FORMAT_TEXT: Record<Uygulama["bicim"], string> = { compose: "Compose", kubernetes: "Kubernetes" };

/** Where the application's file came from (K2), in a line ("Compose · adresten · 2 servis"). */
export const SOURCE_SHORT: Record<KaynakTuru, string> = {
  dosya: "dosyadan",
  adres: "adresten",
  imaj: "imajdan",
  konteyner: "konteynerden",
};

/** Where the application's file came from (K2), as a fact. */
export const SOURCE_TEXT: Record<KaynakTuru, string> = {
  dosya: "Dosya",
  adres: "Adres",
  imaj: "İmaj adından taslak",
  konteyner: "Var olan konteynerden taslak",
};

/** How a service starts (A4). */
export function startText(mode: UygulamaServisAyrintisi["baslangic"], user: string | null): string {
  return mode === "direct" ? `Doğrudan${user ? ` ${user}` : ""} · bütün yetkiler kapalı` : "Root olarak · kendi kullanıcısına geçebilir";
}

export const servicesText = (n: number): string => `${n} servis`;

/** The application's line under its name: "Compose · dosyadan · 2 servis". */
export const appLine = (app: Pick<Uygulama, "bicim" | "servisler" | "koken">): string =>
  `${FORMAT_TEXT[app.bicim] ?? app.bicim} · ${SOURCE_SHORT[app.koken] ?? app.koken} · ${servicesText(app.servisler.length)}`;

/** "1 uyarı". */
export const warningText = (n: number): string => `${n} uyarı`;

export const CELL_TEXT: Record<ErisimDurumu, string> = { acik: "Açık", kismen: "Kısmen", kapali: "Kapalı", yok: UNKNOWN, hata: "Sorun var" };
export const CELL_TONE: Record<ErisimDurumu, Tone> = { acik: "ok", kismen: "accent", kapali: "neutral", yok: "neutral", hata: "danger" };

/** "%1 · 84 MB"; "—" when neither is known. */
export function resourceText(app: Pick<Uygulama, "kaynak">): string {
  const parts = [app.kaynak.cpu, app.kaynak.bellek].map((v, i) => (v === null ? null : i === 0 ? percent(v) : bytes(v))).filter((v): v is string => v !== null);
  return parts.length ? parts.join(" · ") : UNKNOWN;
}

/** The live rate of the application's own bridge: "↓ 1,2 MB/s · ↑ 38 KB/s"; "—" while it has none. */
export function rateText(app: Pick<Uygulama, "ag">): string {
  return app.ag ? `↓ ${rate(app.ag.indirme)} · ↑ ${rate(app.ag.yukleme)}` : UNKNOWN;
}

const ADDRESS_RE = /^https?:\/\/[^/\s]+/;

/** The application's first address when it can be opened now (it runs, fully or in part); "" otherwise. */
export function openAddress(app: Pick<Uygulama, "adres" | "durum">): string {
  const address = typeof app.adres === "string" && ADDRESS_RE.test(app.adres) ? app.adres : "";
  return address && (app.durum === "calisiyor" || app.durum === "kismen") ? address : "";
}

/** How an application is reached, from Erişim's rows: a Tailscale name, an internet name, each open raw port;
    "Kapalı" when nothing is open. */
export function accessChips(rows: readonly Hizmet[], app: string): { text: string; tone: Tone }[] {
  const mine = rows.filter((h) => h.tur === "uygulama" && h.uygulama === app && h.satir);
  const out: { text: string; tone: Tone }[] = [];
  if (mine.some((h) => h.satir?.tur === "adres")) out.push({ text: "Tailscale", tone: "ok" });
  const internet = mine.filter((h) => h.satir?.tur === "adres" && h.satir.internet);
  if (internet.length) out.push({ text: "İnternet", tone: internet.some((h) => h.internet.durum === "hata" || h.internet.uyari) ? "warning" : "accent" });
  for (const h of mine) {
    if (h.satir?.tur === "ham" && h.satir.kapsam !== "kapali") out.push({ text: `Ham ${h.satir.port} · ${h.satir.kapsam === "internet" ? "internet" : "Tailscale"}`, tone: "warning" });
  }
  if (!out.length) out.push({ text: "Kapalı", tone: "neutral" });
  return out;
}

/** One of four tile colours, always the same for the same application (by its name). */
export function appTile(app: Pick<Uygulama, "ad">): number {
  let sum = 0;
  for (const ch of app.ad) sum = (sum + (ch.codePointAt(0) ?? 0)) % 9973;
  return (sum % 4) + 1;
}

/** An image reference with its digest shortened ("…/web@sha256:0123456789ab…"). */
export function shortImage(image: string): string {
  const at = image.indexOf("@sha256:");
  if (at < 0) return image;
  const digest = image.slice(at + 8);
  return digest.length > 12 ? `${image.slice(0, at)}@sha256:${digest.slice(0, 12)}…` : image;
}
