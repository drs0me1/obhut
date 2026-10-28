// How Erişim (DD-258; access rows since rebuild phase 4) names things everywhere: where a warning's fix leads,
// which rows are access rows and how many of them are open where (Erişim's head), an access row in words, and the name rules the row sheet checks before it asks
// the server (the server checks them again).
import { accessRoute } from "./sections";
import type { ErisimSatiri, Hizmet, Uyari } from "./api/sema";

/** Where a warning is fixed: its access row's sheet in Adresler (the target is the row id) or the application's
    page (the target is the application's name); without a place (Tailscale itself), Erişim → Genel. */
export function fixRoute(fix: Uyari["duzelt"]): string {
  if (!fix) return accessRoute();
  if (fix.bolum === "uygulama" && fix.hedef) return "/uygulamalar/" + encodeURIComponent(fix.hedef);
  return accessRoute("adresler", fix.hedef);
}

/** A raw port's scope in words. */
export const SCOPE_TEXT: Record<Extract<ErisimSatiri, { tur: "ham" }>["kapsam"], string> = {
  kapali: "Kapalı",
  tailscale: "Tailscale",
  internet: "İnternet",
};

/** A raw port's scope as Erişim offers the choice (its segmented control and the row's sheet). */
export const SCOPE_CHOICES: readonly { id: Extract<ErisimSatiri, { tur: "ham" }>["kapsam"]; text: string }[] = [
  { id: "kapali", text: "Kapalı" },
  { id: "tailscale", text: "Yalnız Tailscale" },
  { id: "internet", text: "İnternet" },
];

/** A row whose home is Erişim → Adresler: Konsol, Paylaşımlar and each application port with its stored row. */
export function isAccessRow(h: Hizmet): boolean {
  if (h.tur === "konsol" || h.tur === "paylasim") return true;
  return h.tur === "uygulama" && h.satir !== null && Boolean(h.uygulama) && portKey(h.anahtar ?? "") !== null;
}

/** How many Tailscale names and internet names the access rows have, and how many raw ports are open where. */
export function accessCounts(rows: readonly Hizmet[]): { tailscale: number; internet: number; rawInternet: number; rawTailscale: number } {
  const out = { tailscale: 0, internet: 0, rawInternet: 0, rawTailscale: 0 };
  for (const h of rows) {
    if (!isAccessRow(h)) continue;
    if (h.tur === "konsol" || h.tur === "paylasim") {
      if (h.tur === "konsol" || h.web?.tail) out.tailscale += 1;
      // An internet name is one with a name: WebDAV's switch can be on with no name configured.
      if (h.web?.enabled && h.web.domain) out.internet += 1;
    } else if (h.satir?.tur === "adres") {
      out.tailscale += 1;
      if (h.satir.internet) out.internet += 1;
    } else if (h.satir?.kapsam === "internet") out.rawInternet += 1;
    else if (h.satir?.kapsam === "tailscale") out.rawTailscale += 1;
  }
  return out;
}

/** The ports "Adres aç" can give a Tailscale name: an application's raw TCP ports. */
export function addressCandidates(rows: readonly Hizmet[]): Hizmet[] {
  return rows.filter((h) => isAccessRow(h) && h.satir?.tur === "ham" && portKey(h.anahtar ?? "")?.protokol === "tcp");
}

/** Whose row it is: Konsol, Paylaşımlar or the application. */
export const rowOwner = (h: Hizmet): string => (h.tur === "uygulama" ? h.uygulama ?? h.ad : h.ad);

/** An access row by its name (the palette, the pending banner): an address by its Tailscale name (<ad>.<alan>;
    Konsol's panel, Paylaşımlar' paylas), a raw port by its application and port. */
export function rowName(h: Hizmet, domain: string): string {
  const key = portKey(h.anahtar ?? "");
  if (h.satir?.tur === "ham" && key) return `${rowOwner(h)} · ${key.port}/${key.protokol.toUpperCase()}`;
  const label = h.tur === "konsol" ? "panel" : h.tur === "paylasim" ? "paylas" : h.satir?.tur === "adres" ? h.satir.ad : "";
  return label && domain ? `${label}.${domain}` : rowOwner(h);
}

/** An application port's row key ("<service>:<port>/<proto>") as its parts; null when it is not one. */
export function portKey(key: string): { servis: string; port: number; protokol: "tcp" | "udp" } | null {
  const match = /^(.+):([1-9][0-9]{0,4})\/(tcp|udp)$/.exec(key);
  if (!match) return null;
  return { servis: match[1] as string, port: Number(match[2]), protokol: match[3] as "tcp" | "udp" };
}

/** A Tailscale name's label (<ad>.<alan>): the inspector's TAILSCALE_NAME_RE. */
export const TAILSCALE_NAME_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
/** Labels Obhut keeps for itself (Konsol's panel, WebDAV's paylas). */
export const RESERVED_NAMES: readonly string[] = ["panel", "paylas"];
/** A full public host name: no URL, IP, port or path. */
export const HOST_RE = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]+)$/;
/** A local domain (Konsol answers at panel.<alan>). */
export const DOMAIN_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/** Why a Tailscale name's label cannot be used, or "" when it can (taken: the labels other rows hold). */
export function nameProblem(label: string, taken: readonly string[] = []): string {
  if (!label) return "Tailscale adını yazın (ör. notlar).";
  if (!TAILSCALE_NAME_RE.test(label)) return "Küçük harf, rakam ve tire; tireyle başlamaz ya da bitmez (en çok 63).";
  if (RESERVED_NAMES.includes(label)) return `${label} adı Obhut'undur; başka bir ad seçin.`;
  return taken.includes(label) ? `${label} adı başka bir satırda kullanılıyor.` : "";
}

/** A name as the operator typed it: trimmed, lower case, without a final dot. */
export const cleanHost = (text: string): string => text.trim().toLowerCase().replace(/\.$/, "");

/** Why a public name cannot be used, or "" when it can. */
export function hostProblem(text: string): string {
  const host = cleanHost(text);
  if (!host) return "İnternet adını yazın (ör. uygulama.example.org).";
  return HOST_RE.test(host) ? "" : "Tam alan adını girin; URL, IP, port veya yol eklemeyin.";
}

/** Why a port number cannot be used, or "" when it can. */
export function portProblem(text: string): string {
  const value = /^\d+$/.test(text.trim()) ? Number(text.trim()) : NaN;
  return value >= 1 && value <= 65535 ? "" : "1 ile 65535 arasında bir port yazın.";
}
