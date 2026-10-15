// How Paylaşımlar (phase 4b, DD-267) says things: a share's and a connection's state, the internet
// connection's transport, the address split for Infuse, the expiry, the rules the form checks before the
// server checks them again (panel/master_shares.py: USER_RE, parts(), the password rules) and the
// password generator. `shareBrief` is the one line a folder list shows for a shared folder.
import type { Paylasim, PaylasimBaglantisi, Paylasimlar } from "../../../api/sema";
import type { ShareDays, ShareScope } from "../../../api/paylasim";
import type { IconName } from "../../../components/icons";
import type { Tone } from "../../../components/ui/types";
import { dateTime } from "../../../format";

export const SCOPES: readonly ShareScope[] = ["tailscale", "wan"];

export const DURATIONS: readonly { days: ShareDays; text: string }[] = [
  { days: 1, text: "1 gün" },
  { days: 7, text: "7 gün" },
  { days: 30, text: "30 gün" },
  { days: 0, text: "Süresiz" },
];

export const PERMISSIONS: readonly { id: "ro" | "rw"; text: string }[] = [
  { id: "ro", text: "Salt okunur" },
  { id: "rw", text: "Okuma ve yazma" },
];

export const scopeName = (scope: ShareScope): string => (scope === "tailscale" ? "Tailscale" : "İnternet");

/** How the internet connection is carried: a public HTTPS name, plain HTTP on the address and port, or
    closed ("") when no HTTPS name is saved any more. */
export function wanMode(view: Pick<Paylasimlar, "wan"> | null): "https" | "http" | "" {
  const mode = view?.wan.mode;
  return mode === "https" ? "https" : mode === "http" ? "http" : "";
}

export function scopeIcon(scope: ShareScope, view: Pick<Paylasimlar, "wan"> | null): IconName {
  if (scope === "tailscale") return "tailnet";
  return wanMode(view) === "https" ? "lock" : "globe";
}

/** The transport in plain words: "Şifreli tünel", "HTTPS · paylas.example.org", "Şifresiz HTTP · 203.0.113.10:61010". */
export function transportText(scope: ShareScope, view: Paylasimlar | null): string {
  if (scope === "tailscale") return view?.tail_enabled === false ? "Tailscale yayını kapalı" : "Şifreli tünel";
  const wan = view?.wan;
  const mode = wanMode(view);
  if (mode === "https") return wan?.domain ? `HTTPS · ${wan.domain}` : "HTTPS";
  if (mode === "http") return wan?.address ? `Şifresiz HTTP · ${wan.address}${wan.port ? ":" + wan.port : ""}` : "Şifresiz HTTP";
  return "Kapalı";
}

/** A share's state over both connections (the current Konsol's words). */
export function shareState(s: Pick<Paylasim, "connections" | "available">): { text: string; tone: Tone } {
  const list = SCOPES.map((scope) => s.connections[scope]).filter((c): c is PaylasimBaglantisi => Boolean(c));
  if (!list.length) return { text: "Bağlantı bilgisi yok", tone: "neutral" };
  if (list.every((c) => !c.enabled)) return { text: "Duraklatıldı", tone: "neutral" };
  if (!s.available) return { text: "Klasör bulunamadı", tone: "danger" };
  if (list.some((c) => c.active)) return { text: "Açık", tone: "ok" };
  if (list.some((c) => c.enabled && c.expired)) return { text: "Süresi doldu", tone: "warning" };
  return { text: "Erişim kullanılamıyor", tone: "warning" };
}

/** One connection's state. */
export function connectionState(c: PaylasimBaglantisi): { text: string; tone: Tone } {
  if (c.active) return { text: "Erişim açık", tone: "ok" };
  if (c.expired) return { text: "Süresi doldu", tone: "warning" };
  if (!c.enabled) return { text: "Kapalı", tone: "neutral" };
  return { text: "Erişim kullanılamıyor", tone: "warning" };
}

export function expiryText(c: Pick<PaylasimBaglantisi, "expires" | "expired">): string {
  if (c.expires === null) return "Süresiz";
  return `${c.expired ? "Süresi doldu" : "Bitiş"} · ${dateTime(c.expires)}`;
}

export interface Endpoint {
  url: string;
  secure: boolean;
  host: string;
  port: string;
  path: string;
}

/** The address as Infuse asks for it (WebDAV, host, port, path); null for no or a broken address. */
export function endpointOf(url: string): Endpoint | null {
  if (!url) return null;
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  const secure = u.protocol === "https:";
  return { url, secure, host: u.hostname, port: u.port || (secure ? "443" : "80"), path: u.pathname };
}

/** The folder's place on the server ("/srv/Filmler"); just the share's path while the root is unknown. */
export function fullPath(root: string, path: string): string {
  const base = root.replace(/\/+$/, "");
  return base ? `${base}/${path}` : path;
}

/** A folder path as the share manager keeps it: no leading, trailing or doubled slashes. */
export const cleanPath = (path: string): string => path.split("/").filter(Boolean).join("/");

/** Why a folder cannot be shared, by the share manager's own rule (parts()); "" when it can. */
export function pathProblem(path: string): string {
  const parts = path.split("/").filter(Boolean);
  if (!parts.length) return "Paylaşılacak klasörü seçin.";
  // The code points below 32 and 127 (control characters), spelt out: the rule is the server's.
  const control = (p: string) => [...p].some((ch) => (ch.codePointAt(0) ?? 0) < 32 || ch.codePointAt(0) === 127);
  if (parts.length > 64 || parts.some((p) => p.startsWith(".") || p.includes("\\") || control(p) || new TextEncoder().encode(p).length > 255)) {
    return "Kök, gizli/iç klasörler ve geçersiz yollar paylaşılamaz.";
  }
  return "";
}

export const USER_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$/;

export function usernameProblem(name: string, items: readonly Paylasim[], own = ""): string {
  if (!name) return "Kullanıcı adını yazın.";
  if (!USER_RE.test(name)) return "Kullanıcı adı 3–32 harf/rakam veya . _ - içermeli; harf ya da rakamla başlamalı.";
  if (items.some((s) => s.id !== own && s.username.toLowerCase() === name.toLowerCase())) return "Bu kullanıcı adı başka bir paylaşımda kullanılıyor.";
  return "";
}

/** The share manager's password rules; on an edit an empty password keeps the saved one. */
export function passwordProblem(password: string, required: boolean): string {
  if (!password) return required ? "Parola yazın ya da üretin (en az 8 karakter)." : "";
  if (password.length < 8) return "Parola en az 8 karakter olmalı.";
  if (password.length > 256) return "Parola en çok 256 karakter olabilir.";
  if (password.includes(":") || [...password].some((ch) => (ch.codePointAt(0) ?? 0) < 32)) return "Parolada : ve kontrol karakteri olamaz.";
  return "";
}

/** 20 random bytes as 40 hexadecimal digits (getRandomValues works over plain HTTP too). */
export function generatePassword(): string {
  const values = new Uint8Array(20);
  crypto.getRandomValues(values);
  return Array.from(values, (v) => v.toString(16).padStart(2, "0")).join("");
}

const limit = (limits: Paylasimlar["limits"], key: string, fallback: number): number => {
  const v = limits[key];
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
};

/** The internet listener's budgets in words (DD-180), from the share manager's limits. */
export function limitsText(limits: Paylasimlar["limits"]): string {
  const failures = limit(limits, "auth_failures", 5);
  const window = limit(limits, "auth_window_seconds", 60);
  const block = Math.round(limit(limits, "auth_block_seconds", 300) / 60);
  return `İnternet sınırları: ${window} saniyede ${failures} hatalı giriş → ${block} dakika engel; IP başına ${limit(limits, "wan_connections_per_ip", 4)}, toplam ${limit(limits, "wan_connections", 8)} eşzamanlı istek.`;
}

/** One line for a shared folder in a folder list: the open connections with the days left, else the state
    ("Paylaşılıyor: Tailscale (7 gün)", "Paylaşım: duraklatıldı"). `now` in Unix seconds. */
export function shareBrief(s: Pick<Paylasim, "connections" | "available">, now: number): { on: boolean; text: string } {
  const open = SCOPES.flatMap((scope) => {
    const c = s.connections[scope];
    if (!c?.active) return [];
    return [`${scopeName(scope)} (${c.expires === null ? "süresiz" : `${Math.max(0, Math.ceil((c.expires - now) / 86400))} gün`})`];
  });
  if (open.length) return { on: true, text: "Paylaşılıyor: " + open.join(", ") };
  return { on: false, text: "Paylaşım: " + shareState(s).text.toLocaleLowerCase("tr-TR") };
}
