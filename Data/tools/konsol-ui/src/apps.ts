// How an application (GET /api/konsol/uygulamalar, DD-271 phase 3) is shown everywhere: its state, whether
// it needs attention, its services, resources and version, where its file came from, its tile colour. One
// place, so Genel Bakış, Uygulamalar, the application page and the palette say the same thing. Erişim's
// cell words live here too (CELL_TEXT, CELL_TONE).
import type { Tone } from "./components/ui/types";
import type { ErisimDurumu, Uygulama, UygulamaServisAyrintisi } from "./api/sema";
import { UNKNOWN, bytes, percent } from "./format";

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
  yeni: "Yeni sürüm",
  denetlenemedi: "Denetlenemedi",
  bilinmiyor: UNKNOWN,
  sabit: UNKNOWN,
};

/** The version column: "Güncel", "Yeni sürüm", "Denetlenemedi", or "—" (not checked yet, or a fixed image). */
export const updateText = (state: Uygulama["guncelleme"]): string => UPDATE_TEXTS[state] ?? UNKNOWN;

/** Whether there is a version state worth a line of its own. */
export const hasUpdateState = (state: Uygulama["guncelleme"]): boolean => state === "guncel" || state === "yeni" || state === "denetlenemedi";

export const FORMAT_TEXT: Record<Uygulama["bicim"], string> = { compose: "Compose", kubernetes: "Kubernetes" };

/** Where the application's file came from (K2). */
export const SOURCE_TEXT: Record<Uygulama["koken"], string> = {
  dosya: "Dosyadan",
  adres: "Bir adresten",
  imaj: "Bir imajdan",
  konteyner: "Bir konteynerden",
};

/** How a service starts (A4). */
export const START_TEXT: Record<UygulamaServisAyrintisi["baslangic"], string> = {
  direct: "Doğrudan kendi kullanıcısıyla",
  root: "Root olarak; kendi kullanıcısına geçebilir",
};

export const servicesText = (n: number): string => `${n} servis`;

/** The application's line under its name: "Compose · 2 servis". */
export const appLine = (app: Pick<Uygulama, "bicim" | "servisler">): string => `${FORMAT_TEXT[app.bicim] ?? app.bicim} · ${servicesText(app.servisler.length)}`;

/** "1 uyarı". */
export const warningText = (n: number): string => `${n} uyarı`;

export const CELL_TEXT: Record<ErisimDurumu, string> = { acik: "Açık", kismen: "Kısmen", kapali: "Kapalı", yok: UNKNOWN, hata: "Sorun var" };
export const CELL_TONE: Record<ErisimDurumu, Tone> = { acik: "ok", kismen: "accent", kapali: "neutral", yok: "neutral", hata: "danger" };

/** "%1 · 84 MB"; "—" when neither is known. */
export function resourceText(app: Pick<Uygulama, "kaynak">): string {
  const parts = [app.kaynak.cpu, app.kaynak.bellek].map((v, i) => (v === null ? null : i === 0 ? percent(v) : bytes(v))).filter((v): v is string => v !== null);
  return parts.length ? parts.join(" · ") : UNKNOWN;
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

/** Podman's images, volumes and networks: Gelişmiş's Podman view (phase 4a), one of its lists. */
export function podmanRoute(kaynak: "imajlar" | "birimler" | "aglar" | "" = ""): string {
  return "/gelismis?sekme=podman" + (kaynak ? "&kaynak=" + kaynak : "");
}
