// Shared helpers of Dosyalar' views (phase 4b): paths relative to a tree's root, the order of a folder
// (folders first, Turkish collation with numbers in order), what may open in the editor, dates and a
// folder share's mark (DD-192).
import type { Entry } from "../../api/dosyalar";
import type { Paylasim } from "../../api/sema";
import { UNKNOWN, bytes } from "../../format";

const collator = new Intl.Collator("tr-TR", { numeric: true, sensitivity: "base" });

/** Folders first, then by name the Turkish way ("Çizgi" after "Cep", "Bölüm 2" before "Bölüm 10"). */
export function sortEntries<T extends Pick<Entry, "name" | "type">>(list: readonly T[]): T[] {
  return [...list].sort((a, b) => {
    const dirs = Number(b.type === "dir") - Number(a.type === "dir");
    return dirs || collator.compare(a.name, b.name) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  });
}

/** A folder's name order for lists of names (the move dialog). */
export const compareNames = (a: string, b: string): number => collator.compare(a, b);

export const joinPath = (folder: string, name: string): string => (folder ? folder + "/" + name : name);

/** The parts of a relative path from the address, or null when it is not one ("..", empty parts). */
export function splitPath(raw: string): string[] | null {
  const text = raw.replace(/^\/+|\/+$/g, "");
  if (!text) return [];
  const parts = text.split("/");
  return parts.every((p) => p !== "" && p !== "." && p !== ".." && !p.includes("\0")) ? parts : null;
}

/** The absolute place of a relative path under `root` ("/srv" + "Filmler" → "/srv/Filmler"; "/" + "etc"). */
export function fullPath(root: string, rel: string): string {
  if (!rel) return root;
  return (root.endsWith("/") ? root : root + "/") + rel;
}

const TEXT_EXT = /\.(txt|log|nfo|srt|sub|md|json|conf|ini|csv|ya?ml|toml|cfg|cnf|env|sh|bash|py|js|mjs|cjs|ts|css|html?|xml|service|timer|socket|mount|path|target|container|network|volume|rules|caddy|properties|list)$/i;

/** Whether a click on the file opens it in the editor: a text type, or a name without an extension
    (hosts, fstab, sshd_config). Any other file opens there through "Düzenle" when it is small enough. */
export function isTextName(name: string): boolean {
  return TEXT_EXT.test(name) || name.lastIndexOf(".") <= 0;
}

export function canEdit(e: Pick<Entry, "name" | "type" | "size">, textLimit: number): boolean {
  return e.type === "file" && (isTextName(e.name) || (e.size !== null && e.size <= textLimit));
}

const thisYear = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
const otherYear = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short", year: "numeric" });

/** "8 Eki 14:02" this year, "8 Eki 2024" before it. */
export function when(unixSeconds: number): string {
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return UNKNOWN;
  const d = new Date(unixSeconds * 1000);
  return (d.getFullYear() === new Date().getFullYear() ? thisYear : otherYear).format(d);
}

export const isoTime = (unixSeconds: number): string => new Date(unixSeconds * 1000).toISOString();

/** A folder's size column: its total when walked and not empty, else "—" (its count is beside it). */
export function sizeText(e: Pick<Entry, "type" | "size" | "count">): string {
  if (e.type === "dir") return e.count && e.size !== null ? bytes(e.size) : UNKNOWN;
  return e.type === "file" ? bytes(e.size) : UNKNOWN;
}

export const countText = (count: number | null): string => `${count === null ? "?" : count} öge`;

export const TYPE_TEXT: Record<Entry["type"], string> = { dir: "Klasör", file: "Dosya", link: "Sembolik bağlantı", other: "Özel dosya" };

const SCOPES = [
  ["tailscale", "Tailscale"],
  ["wan", "İnternet"],
] as const;

/** A shared folder's mark: its open connections, or that it is shared but closed. */
export function shareMark(s: Paylasim): { on: boolean; text: string } {
  const open = SCOPES.filter(([k]) => s.connections[k]?.active).map(([, label]) => label);
  return open.length ? { on: true, text: "Paylaşılıyor · " + open.join(", ") } : { on: false, text: "Paylaşım kapalı" };
}

/** Whether a folder may be offered for sharing: no part of its path is hidden. */
export function shareable(rel: string): boolean {
  return !rel.split("/").some((p) => p.startsWith("."));
}

export function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
