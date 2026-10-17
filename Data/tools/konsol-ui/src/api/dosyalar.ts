// Dosyalar' file backends (phase 4b, DD-267): the user area (/srv) as its owner account at /api/* (DD-139 …
// DD-145, DD-249) and, on the tailnet only, the whole server as root at /api/sistem/* (DD-235). These routes
// are not in the root backend's route table (sema.ts); the shapes follow files-panel/master-files-panel. A
// reply without its expected shape is an error, and a list item without its expected fields is left out.
// Also the root backend's two reads Dosyalar joins with them: who uses which folder (depolama) and the
// folder shares, for the marks in the folder list (paylasim).
import { YOLLAR, type Depolama, type Paylasim } from "./sema";
import { ApiError, getJson, goToSignIn, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

/** Which tree: the user area or, on the tailnet, the whole server as root. */
export type Tree = "srv" | "sistem";

const PREFIX: Record<Tree, string> = { srv: "/api", sistem: "/api/sistem" };

function at(tree: Tree, route: string, params?: Record<string, string>): string {
  return PREFIX[tree] + route + (params ? "?" + new URLSearchParams(params).toString() : "");
}

const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const numberOrNull = (v: unknown): number | null => (isNumber(v) ? v : null);

export interface FilesState {
  root: string;
  writable: boolean;
  textLimit: number;
  disk: { total: number | null; free: number | null; used: number | null; mount: boolean };
  /** The trash's count and size; null in the root view (it has none). */
  trash: { count: number; size: number } | null;
}

export type EntryType = "dir" | "file" | "link" | "other";

export interface Entry {
  name: string;
  type: EntryType;
  /** A file's size, a folder's total (DD-247) when the backend could walk it, else null. */
  size: number | null;
  mtime: number;
  /** A folder's item count; null when it could not be read. */
  count: number | null;
}

export interface Listing {
  /** Relative to the root, "" for the root itself. */
  path: string;
  entries: Entry[];
  /** Items left out because their names are not valid (not UTF-8, too long). */
  skipped: number;
}

export type Encoding = "utf-8" | "cp1254" | "cp437";

export interface TextFile {
  path: string;
  size: number;
  mtime: number;
  truncated: boolean;
  encoding: Encoding;
  bom: boolean;
  eol: "lf" | "crlf";
  editable: boolean;
  /** Why it may not be saved ("" when it may). */
  reason: string;
  /** The SHA-256 of the bytes read; a save sends it back (DD-249). Null when not editable. */
  version: string | null;
  text: string;
}

export interface SavedText {
  path: string;
  version: string;
  size: number;
  mtime: number;
}

export interface TrashItem {
  id: string;
  name: string;
  type: EntryType;
  size: number | null;
  /** The folder it was deleted from, relative to the root; null when unknown. */
  from: string | null;
  deleted: number;
  /** A record whose content is not one item: it can only be deleted for good. */
  broken: boolean;
  count: number | null;
}

const ENTRY_TYPES: readonly string[] = ["dir", "file", "link", "other"];

function entryOf(v: unknown): Entry | null {
  if (!isObject(v) || !isText(v.name) || !isText(v.type) || !ENTRY_TYPES.includes(v.type)) return null;
  return { name: v.name, type: v.type as EntryType, size: numberOrNull(v.size), mtime: isNumber(v.mtime) ? v.mtime : 0, count: numberOrNull(v.count) };
}

export async function readState(tree: Tree): Promise<FilesState> {
  const v = shaped<Record<string, unknown>>(await getJson(at(tree, "/state")), (s) => isText(s.root) && isObject(s.disk));
  const disk = v.disk as Record<string, unknown>;
  const trash = isObject(v.trash) && isNumber(v.trash.count) ? { count: v.trash.count, size: isNumber(v.trash.size) ? v.trash.size : 0 } : null;
  return {
    root: v.root as string,
    writable: v.writable !== false,
    textLimit: isNumber(v.textLimit) ? v.textLimit : 0,
    disk: { total: numberOrNull(disk.total), free: numberOrNull(disk.free), used: numberOrNull(disk.used), mount: disk.mount === true },
    trash: tree === "srv" ? trash : null,
  };
}

/** A folder's contents; `dirsOnly` lists only its folders and skips the sizes (the move dialog). */
export async function readListing(tree: Tree, path: string, dirsOnly = false): Promise<Listing> {
  const params: Record<string, string> = { path };
  if (dirsOnly) params.dirs = "1";
  const v = shaped<Record<string, unknown>>(await getJson(at(tree, "/list", params)), (l) => Array.isArray(l.entries));
  const entries = (v.entries as unknown[]).map(entryOf).filter((e): e is Entry => e !== null);
  return { path: isText(v.path) ? v.path : path, entries, skipped: isNumber(v.skipped) ? v.skipped : 0 };
}

export async function readText(tree: Tree, path: string, encoding: Encoding | "auto"): Promise<TextFile> {
  const v = shaped<Record<string, unknown>>(await getJson(at(tree, "/text", { path, enc: encoding })), (t) => isText(t.text) && isText(t.encoding));
  return {
    path: isText(v.path) ? v.path : path,
    size: isNumber(v.size) ? v.size : 0,
    mtime: isNumber(v.mtime) ? v.mtime : 0,
    truncated: v.truncated === true,
    encoding: v.encoding as Encoding,
    bom: v.bom === true,
    eol: v.eol === "crlf" ? "crlf" : "lf",
    editable: v.editable === true && isText(v.version),
    reason: isText(v.reason) ? v.reason : "",
    version: isText(v.version) ? v.version : null,
    text: v.text as string,
  };
}

export async function saveText(tree: Tree, body: { path: string; text: string; encoding: Encoding; version: string }): Promise<SavedText> {
  return shaped(await postJson(at(tree, "/text/save"), body), (v) => isText(v.version) && isNumber(v.size));
}

export async function makeFolder(tree: Tree, path: string, name: string): Promise<void> {
  await postJson(at(tree, "/mkdir"), { path, name });
}

export async function renameItem(tree: Tree, path: string, name: string, to: string): Promise<void> {
  await postJson(at(tree, "/rename"), { path, name, to });
}

export async function moveItems(tree: Tree, path: string, names: string[], to: string): Promise<string[]> {
  const v = shaped<{ moved: unknown }>(await postJson(at(tree, "/move"), { path, names, to }), (r) => Array.isArray(r.moved));
  return (v.moved as unknown[]).filter(isText);
}

/** /srv only: into the trash (DD-139); it can be restored from Çöp kutusu. */
export async function trashItems(path: string, names: string[]): Promise<void> {
  await postJson(at("srv", "/trash"), { path, names });
}

/** The root view only (DD-235): permanent; one item is confirmed by its own name, several by "onayla". */
export async function deleteItems(path: string, names: string[], confirm: string): Promise<string[]> {
  const v = shaped<{ deleted: unknown }>(await postJson(at("sistem", "/delete"), { path, names, confirm }), (r) => Array.isArray(r.deleted));
  return (v.deleted as unknown[]).filter(isText);
}

export async function readTrash(): Promise<TrashItem[]> {
  const v = shaped<{ items: unknown }>(await getJson(at("srv", "/trash")), (r) => Array.isArray(r.items));
  const out: TrashItem[] = [];
  for (const raw of v.items as unknown[]) {
    const e = entryOf(raw);
    if (!e || !isObject(raw) || !isText(raw.id)) continue;
    out.push({ ...e, id: raw.id, from: isText(raw.from) ? raw.from : null, deleted: isNumber(raw.deleted) ? raw.deleted : e.mtime, broken: raw.broken === true });
  }
  return out;
}

export interface Restored {
  id: string;
  /** Where it went back to, relative to the root. */
  path: string;
  /** Its name there (numbered when the old name was taken: "rapor (2).pdf"). */
  name: string;
}

export async function restoreTrash(ids: string[]): Promise<Restored[]> {
  const v = shaped<{ restored: unknown }>(await postJson(at("srv", "/trash/restore"), { ids }), (r) => Array.isArray(r.restored));
  return (v.restored as unknown[]).filter((r): r is Restored => isObject(r) && isText(r.id) && isText(r.path) && isText(r.name));
}

export async function purgeTrash(ids: string[]): Promise<void> {
  await postJson(at("srv", "/trash/purge"), { ids });
}

export async function emptyTrash(): Promise<number> {
  const v = shaped<{ purged: unknown }>(await postJson(at("srv", "/trash/empty"), { confirm: "onayla" }), (r) => isNumber(r.purged));
  return v.purged as number;
}

/** A file's download address: a plain link (the backend lets a download through without X-Konsol). */
export function downloadUrl(tree: Tree, path: string): string {
  return at(tree, "/download", { path });
}

/** An upload the operator cancelled. */
export class UploadCancelled extends Error {}

export interface Sending {
  done: Promise<void>;
  abort(): void;
}

/** POST …/upload?path=&name= with the file itself as the body (DD-145), through XMLHttpRequest for its
    progress and cancel. The server writes to a temporary name and refuses an existing one (409). */
export function sendFile(tree: Tree, folder: string, file: File, progress: (sent: number) => void): Sending {
  const xhr = new XMLHttpRequest();
  const done = new Promise<void>((resolve, reject) => {
    xhr.open("POST", at(tree, "/upload", { path: folder, name: file.name }));
    xhr.setRequestHeader("X-Konsol", "1");
    xhr.upload.addEventListener("progress", (e) => progress(e.loaded));
    xhr.addEventListener("load", () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve();
        return;
      }
      let body: unknown = null;
      try {
        body = JSON.parse(xhr.responseText);
      } catch {
        body = null;
      }
      if (xhr.status === 401 && (!isObject(body) || body.giris === true)) {
        goToSignIn();
        reject(new ApiError(401, "Oturum gerekli; yeniden giriş yapın."));
        return;
      }
      reject(new ApiError(xhr.status, isObject(body) && isText(body.error) ? body.error : `Sunucu yanıtı: HTTP ${xhr.status}`));
    });
    xhr.addEventListener("error", () => reject(new ApiError(0, "bağlantı koptu")));
    xhr.addEventListener("abort", () => reject(new UploadCancelled("iptal edildi")));
    xhr.send(file);
  });
  return { done, abort: () => xhr.abort() };
}

/** Who uses which folder of the user area (applications' bind mounts and the folder shares, DD-267) and each
    application's data folders with their sizes (K7; `fresh` measures them again instead of the server's cache). */
export async function readStorage(fresh = false): Promise<Depolama> {
  const v = shaped<Depolama>(await getJson(YOLLAR.depolama + (fresh ? "?yenile=1" : "")), (d) => isText(d.kok) && Array.isArray(d.kullananlar));
  const size = (n: unknown) => (isNumber(n) && n >= 0 ? n : null);
  return {
    ...v,
    kullananlar: v.kullananlar.filter((u) => isObject(u) && isText(u.yol) && isText(u.id) && isText(u.ad) && isText(u.tur)),
    uygulamalar: (Array.isArray(v.uygulamalar) ? v.uygulamalar : [])
      .filter((a) => isObject(a) && isText(a.ad) && isText(a.yol))
      .map((a) => ({
        ...a,
        boyut: size(a.boyut),
        neden: isText(a.neden) ? a.neden : "",
        olculdu: isNumber(a.olculdu) ? a.olculdu : null,
        klasorler: (Array.isArray(a.klasorler) ? a.klasorler : [])
          .filter((k) => isObject(k) && isText(k.ad))
          .map((k) => ({ ...k, yol: isText(k.yol) ? k.yol : "", boyut: size(k.boyut), neden: isText(k.neden) ? k.neden : "", hedefler: Array.isArray(k.hedefler) ? k.hedefler.filter(isText) : [] })),
      })),
    hatalar: Array.isArray(v.hatalar) ? v.hatalar.filter(isText) : [],
  };
}

/** The folder shares (DD-192), for the marks in the folder list; their page is Paylaşımlar. */
export async function readShares(): Promise<Paylasim[]> {
  const v = shaped<{ items: unknown }>(await getJson(YOLLAR.paylasimlar), (s) => Array.isArray(s.items));
  return (v.items as unknown[]).filter((s): s is Paylasim => isObject(s) && isText(s.id) && isText(s.path) && isObject(s.connections));
}
