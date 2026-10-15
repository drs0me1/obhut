// Dosyalar → Paylaşımlar (phase 4b, DD-267): the folder shares (WebDAV, DD-158/179/190/192) and the user
// area's folders for choosing one. GET /api/konsol/paylasim is the whole view; both writes answer with it.
// A write names only what changes: a new share sends its folder, account and both connections; an edit its
// id and the changed fields; a list control one connection's patch ({enabled}, {permission, ack_write} or
// {days}). The share manager (panel/master_shares.py `change`) checks every rule again: read/write needs
// `ack_write` in the same connection's patch, turning the internet connection on over plain HTTP needs
// `ack_wan_http`, and a duration is 1, 7 or 30 days or 0 (no end), counted from now. The folders come from
// the files backend (GET /api/list?path=&dirs=1), relative to the user area like a share's `path`.
import { YOLLAR, type Paylasim, type PaylasimBaglantisi, type Paylasimlar } from "./sema";
import { getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

export type ShareScope = "tailscale" | "wan";
export type ShareDays = 0 | 1 | 7 | 30;

/** One connection's change; a field left out keeps its saved value. */
export interface ConnectionPatch {
  enabled?: boolean;
  permission?: "ro" | "rw";
  days?: ShareDays;
  /** Required with permission "rw": writing covers upload, overwrite, move and permanent delete. */
  ack_write?: true;
}

export interface ShareSave {
  id?: string;
  path?: string;
  username?: string;
  password?: string;
  connections?: Partial<Record<ShareScope, ConnectionPatch>>;
  /** Required when the internet connection is turned on while it is carried over plain HTTP. */
  ack_wan_http?: true;
}

const isBool = (v: unknown): v is boolean => typeof v === "boolean";
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

function isConnection(v: unknown): v is PaylasimBaglantisi {
  return (
    isObject(v) && isBool(v.enabled) && (v.permission === "ro" || v.permission === "rw") && (v.expires === null || isNumber(v.expires)) &&
    isBool(v.expired) && isBool(v.available) && isBool(v.active) && isText(v.reason) && isText(v.url)
  );
}

function cleanShare(v: unknown): Paylasim | null {
  if (!isObject(v) || !isText(v.id) || !isText(v.path) || !isText(v.name) || !isText(v.username) || !isObject(v.connections)) return null;
  const connections: Paylasim["connections"] = {};
  for (const scope of ["tailscale", "wan"] as const) {
    const c = v.connections[scope];
    if (isConnection(c)) connections[scope] = c;
  }
  return {
    ...(v as unknown as Paylasim),
    available: v.available === true,
    connections,
    urls: isObject(v.urls) ? (v.urls as Paylasim["urls"]) : {},
    url: isText(v.url) ? v.url : "",
  };
}

function cleanView(data: unknown): Paylasimlar {
  const v = shaped<Paylasimlar>(data, (d) => Array.isArray(d.items) && isBool(d.running));
  return {
    ...v,
    enabled: v.enabled === true,
    host: isText(v.host) ? v.host : "",
    items: v.items.map(cleanShare).filter((s): s is Paylasim => s !== null),
    max: isNumber(v.max) ? v.max : 32,
    wan: isObject(v.wan) ? v.wan : {},
    tail_enabled: v.tail_enabled === true,
    limits: isObject(v.limits) ? v.limits : {},
  };
}

export async function readShares(): Promise<Paylasimlar> {
  return cleanView(await getJson(YOLLAR.paylasimlar));
}

/** Creates (no id) or changes a share; WebDAV restarts and running transfers are cut. */
export async function saveShare(body: ShareSave): Promise<Paylasimlar> {
  return cleanView(await postJson(YOLLAR.paylasim_kaydet, body));
}

/** Removes a share's two connections and its account; the folder and its files stay. */
export async function removeShare(id: string): Promise<Paylasimlar> {
  return cleanView(await postJson(YOLLAR.paylasim_kaldir, { id }));
}

export interface UserFolder {
  name: string;
  /** Relative to the user area ("Filmler/Diziler"). */
  path: string;
}

// The files backend's own route (not in the root backend's table, sema.ts).
const FILES_LIST = "/api/list";

/** The folders directly under `path` in the user area ("" for its top), by name; hidden folders (a name
    that starts with ".") are left out, since a share can never name one. */
export async function readUserFolders(path = ""): Promise<UserFolder[]> {
  const value = shaped<{ entries: unknown[] }>(
    await getJson(FILES_LIST + "?" + new URLSearchParams({ path, dirs: "1" }).toString()),
    (d) => Array.isArray(d.entries),
  );
  return value.entries
    .filter((e): e is { name: string; type: string } => isObject(e) && isText(e.name) && e.type === "dir" && e.name !== "" && !e.name.startsWith("."))
    .map((e) => ({ name: e.name, path: path ? `${path}/${e.name}` : e.name }))
    .sort((a, b) => a.name.localeCompare(b.name, "tr"));
}
