// The upload queue (DD-145, phase 4b): one file at a time, whichever folder or tree it goes to, so a long
// upload keeps going while the operator opens other folders or tabs. A name the folder already holds (or
// one already queued for it) is skipped before anything is sent: the server never writes over a file.
// Each item shows its progress; a waiting or running one can be cancelled. Finished uploads leave the
// queue and tell the folder views (onUploaded); failed and skipped ones stay with their reason until
// removed.
import { reactive } from "vue";
import { sendFile, UploadCancelled, type Tree } from "../../api/dosyalar";
import { errorText } from "./files";

export type UploadState = "sirada" | "yukleniyor" | "atlandi" | "hata";

export interface UploadItem {
  id: number;
  tree: Tree;
  /** The target folder, relative to the tree's root. */
  folder: string;
  name: string;
  size: number;
  sent: number;
  state: UploadState;
  /** Why it was skipped or failed. */
  reason: string;
}

export const uploads = reactive<{ items: UploadItem[] }>({ items: [] });

const files = new Map<number, File>();
const aborts = new Map<number, () => void>();
const listeners = new Set<(item: UploadItem) => void>();
let seq = 0;
let running = false;

/** Queues files for `folder`; `taken` are the names it holds now. Returns how many were skipped. */
export function queueFiles(tree: Tree, folder: string, list: readonly File[], taken: Iterable<string>, skipped: readonly { name: string; reason: string }[] = []): number {
  const names = new Set(taken);
  for (const u of uploads.items) {
    if (u.tree === tree && u.folder === folder && (u.state === "sirada" || u.state === "yukleniyor")) names.add(u.name);
  }
  let skips = 0;
  for (const s of skipped) {
    uploads.items.push({ id: ++seq, tree, folder, name: s.name, size: 0, sent: 0, state: "atlandi", reason: s.reason });
    skips += 1;
  }
  for (const file of list) {
    const clash = names.has(file.name);
    names.add(file.name);
    const id = ++seq;
    uploads.items.push({ id, tree, folder, name: file.name, size: file.size, sent: 0, state: clash ? "atlandi" : "sirada", reason: clash ? "aynı adla bir öge var; üzerine yazılmaz" : "" });
    if (clash) skips += 1;
    else files.set(id, file);
  }
  pump();
  return skips;
}

function find(id: number): UploadItem | undefined {
  return uploads.items.find((u) => u.id === id);
}

function drop(id: number): void {
  const i = uploads.items.findIndex((u) => u.id === id);
  if (i >= 0) uploads.items.splice(i, 1);
  files.delete(id);
  aborts.delete(id);
}

function pump(): void {
  if (running) return;
  const next = uploads.items.find((u) => u.state === "sirada");
  if (!next) return;
  const file = files.get(next.id);
  if (!file) {
    drop(next.id);
    pump();
    return;
  }
  running = true;
  next.state = "yukleniyor";
  const id = next.id;
  const sending = sendFile(next.tree, next.folder, file, (sent) => {
    const item = find(id);
    if (item) item.sent = Math.min(sent, item.size);
  });
  aborts.set(id, sending.abort);
  sending.done
    .then(() => {
      const item = find(id);
      if (item) {
        const done = { ...item, sent: item.size };
        drop(id);
        for (const fn of listeners) fn(done);
      }
    })
    .catch((err: unknown) => {
      const item = find(id);
      if (err instanceof UploadCancelled || !item) {
        drop(id);
        return;
      }
      item.state = "hata";
      item.reason = errorText(err);
      files.delete(id);
      aborts.delete(id);
    })
    .finally(() => {
      running = false;
      pump();
    });
}

/** Cancels a waiting or running upload, or removes a finished one's line. */
export function cancelUpload(id: number): void {
  const item = find(id);
  if (!item) return;
  const abort = aborts.get(id);
  if (item.state === "yukleniyor" && abort) {
    abort();
    return;
  }
  drop(id);
}

/** Calls `fn` with each upload that finished; returns the unsubscribe. */
export function onUploaded(fn: (item: UploadItem) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
