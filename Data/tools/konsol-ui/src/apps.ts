// How an application (GET /api/konsol/uygulamalar, DD-271) is shown everywhere: its state, whether it needs
// attention, its services, resources, live rate and version, where its file came from, how each service starts,
// how its container ports are reached (from Erişim's rows), its first address and its tile colour. One place, so Genel Bakış,
// Uygulamalar, the application page and the palette say the same thing. Erişim's cell words live here too
// (CELL_TEXT, CELL_TONE).
import type { Tone } from "./components/ui/types";
import type { ErisimDurumu, ErisimHucresi, Hizmet, KaynakTuru, SurecKullanicisi, Uygulama, UygulamaServisAyrintisi } from "./api/sema";
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

/** How a service starts (A4): its definition, before anything runs. */
export function startText(mode: UygulamaServisAyrintisi["baslangic"], user: string | null): string {
  return mode === "direct" ? `Doğrudan${user ? ` ${user}` : ""} · bütün yetkiler kapalı` : "Root olarak başlar · imaj isterse kendi kullanıcısına geçer";
}

/** A process user as people read it: "abc (uid 1000)", "uid 911", "root". */
export const userText = (u: SurecKullanicisi): string => (u.uid === 0 ? "root" : u.ad ? `${u.ad} (uid ${u.uid})` : `uid ${u.uid}`);

/** What a service runs as now (its processes' users), or how it starts while that is not known. */
export function runState(s: UygulamaServisAyrintisi): { text: string; tone: Tone } {
  if (s.baslangic === "direct") return { text: startText("direct", s.kullanici), tone: "ok" };
  if (!s.surecler) return { text: "Root olarak başlar", tone: "neutral" };
  const own = s.surecler.filter((u) => u.uid !== 0);
  // The name alone here (its uid is in the service's process lines), so the pill stays short on a phone.
  return own.length
    ? { text: `Root başladı · ${own.map((u) => u.ad || `uid ${u.uid}`).join(", ")} olarak çalışıyor`, tone: "ok" }
    : { text: "Root olarak çalışıyor", tone: "warning" };
}

export const servicesText = (n: number): string => `${n} servis`;

/** The application's line under its name: "Compose · dosyadan · 2 servis". */
export const appLine = (app: Pick<Uygulama, "bicim" | "servisler" | "koken">): string =>
  `${FORMAT_TEXT[app.bicim] ?? app.bicim} · ${SOURCE_SHORT[app.koken] ?? app.koken} · ${servicesText(app.servisler.length)}`;

/** "1 uyarı". */
export const warningText = (n: number): string => `${n} uyarı`;

/** An address in pieces a narrow cell may break between: after its scheme, before its port and its protocol, never
    inside a number. */
export const addressPieces = (line: string): string[] => line.replace("://", "://\n").split(/\n|(?=:\d|\/(?:tcp|udp))/);

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

/** A cell's colour in Erişim's tables: a warning (a raw port open on the internet, unencrypted WebDAV) over its
    state. */
export const cellTone = (c: ErisimHucresi): Tone => (c.uyari ? "warning" : (CELL_TONE[c.durum] ?? "neutral"));

export interface AccessLine {
  text: string;
  tone: Tone;
}

/** One access row of an application as the list maps it: the addresses and ports it is reached on from Tailscale
    and the internet (each in its cell's colour; "Kapalı" when the row opens nothing) beside its container port
    ("8080/tcp"; with its service when the application has more than one). */
export interface AccessMapping {
  id: string;
  server: AccessLine[];
  container: string;
}

/** How an application's container ports are reached, from Erişim's rows, in the rows' order. */
export function accessMap(rows: readonly Hizmet[], app: string, services: number): AccessMapping[] {
  return rows
    .filter((h) => h.tur === "uygulama" && h.uygulama === app && h.satir)
    .map((h) => {
      const server = (["tailscale", "internet"] as const).flatMap((k) => (h[k].durum === "yok" ? [] : h[k].adresler.map((text) => ({ text, tone: cellTone(h[k]) }))));
      const key = h.anahtar ?? "";
      const port = key.slice(key.indexOf(":") + 1);
      return { id: h.id, server: server.length ? server : [{ text: "Kapalı", tone: "neutral" }], container: services > 1 && h.servis ? `${h.servis} · ${port}` : port };
    });
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
