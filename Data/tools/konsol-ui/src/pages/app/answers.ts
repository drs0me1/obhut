// The inspector's questions as a form (K2, K3; rebuild.md 4.2): one draft per question, how a draft becomes the
// answers the backend takes (Yanitlar for an install, TanimYanitlari for an edit), which questions still wait for
// an answer, the checks the form makes before the server makes them again, the short words beside a file's lines
// and a random secret. Shared by Uygulama ekle's Denetçi and an application's Tanım. A secret value lives only in
// a draft while the form is open: never in the address, the browser's storage or a log.
import { nameProblem } from "../../access";
import type {
  Inceleme,
  KayitliYanitlar,
  Soru,
  SoruBaslangic,
  SoruKlasor,
  SoruPort,
  TanimYanitlari,
  UygulamaAyrinti,
  UygulamaPortu,
  Yanit,
  YanitSakla,
  Yanitlar,
} from "../../api/sema";

export type PortDraft = { kind: "port"; use: "" | "caddy" | "raw"; name: string };
/** A variable or a secret; `keep` (an edit only) keeps the value the application already has. */
export type ValueDraft = { kind: "value"; value: string; keep: boolean };
/** `path` is relative to the server root (the Files account's area). */
export type MountDraft = { kind: "mount"; to: "app" | "srv"; path: string; readOnly: boolean };
export type StartDraft = { kind: "start"; mode: "direct" | "root" };
export type Draft = PortDraft | ValueDraft | MountDraft | StartDraft;

export interface AnswerState {
  name: string;
  drafts: Record<string, Draft>;
}

/** What an edit knows that an install does not: the ports that stay (answered from their access rows, whose home is
    Erişim → Adresler) and the secrets the application already has. */
export interface EditContext {
  app: string;
  staying: ReadonlyMap<string, UygulamaPortu>;
  stored: ReadonlySet<string>;
}

export const isSecret = (q: Soru): boolean => q.kind === "secret" || (q.kind === "var" && q.secret);
export const canGenerate = (q: Soru): boolean => (q.kind === "secret" || q.kind === "var") && q.generate;

/** The questions the form asks (the name has its own field). */
export const formQuestions = (inspection: Inceleme | null): Soru[] => (inspection?.questions ?? []).filter((q) => q.kind !== "name");

/** A port question's id for a port of the application ("port:<service>:<port>/<proto>"). */
export const portQuestion = (service: string, p: Pick<UygulamaPortu, "port" | "protokol">): string => `port:${service}:${p.port}/${p.protokol}`;

/** The ports an application has now, by their question's id. */
export function stayingPorts(detail: UygulamaAyrinti): Map<string, UygulamaPortu> {
  const out = new Map<string, UygulamaPortu>();
  for (const s of detail.servisler) for (const p of s.portlar) out.set(portQuestion(s.ad, p), p);
  return out;
}

/** A server-root path as the form keeps it (relative, no leading or trailing slashes): "/srv/Belgeler" → "Belgeler". */
export function relativePath(path: string | null | undefined, root: string): string {
  if (!path || !root) return "";
  const base = root.replace(/\/+$/, "");
  return path === base ? "" : path.startsWith(base + "/") ? path.slice(base.length + 1).replace(/\/+$/, "") : "";
}

/** A new draft for a question, from a stored answer when there is one (an edit). */
function seed(q: Soru, stored: Yanit | { set: boolean } | undefined, root: string): Draft | null {
  switch (q.kind) {
    case "port":
      // A1: nothing is chosen for a TCP port; a UDP port can only be a raw port (closed, A2).
      return { kind: "port", use: q.choices.length === 1 && q.choices[0] === "raw" ? "raw" : "", name: q.suggest ?? "" };
    case "var":
    case "secret": {
      if (stored && "set" in stored) return { kind: "value", value: "", keep: isSecret(q) };
      const value = stored && "value" in stored ? stored.value : q.kind === "var" && !q.secret ? (q.default ?? "") : "";
      return { kind: "value", value, keep: false };
    }
    case "mount": {
      if (stored && "to" in stored) {
        return stored.to === "srv"
          ? { kind: "mount", to: "srv", path: relativePath(stored.path, root), readOnly: stored.read_only }
          : { kind: "mount", to: "app", path: "", readOnly: q.read_only };
      }
      return { kind: "mount", to: q.suggest, path: relativePath(q.srv_path, root), readOnly: q.read_only };
    }
    case "start":
      return { kind: "start", mode: stored && "mode" in stored ? stored.mode : q.suggest };
    default:
      return null;
  }
}

/** Gives every question of an inspection a draft (one it already has stays: a changed file keeps its answers). */
export function syncDrafts(state: AnswerState, inspection: Inceleme, stored: KayitliYanitlar["answers"] | null, root: string): void {
  for (const q of formQuestions(inspection)) {
    const old = state.drafts[q.id];
    if (old && old.kind === draftKind(q)) continue;
    const fresh = seed(q, stored?.[q.id], root);
    if (fresh) state.drafts[q.id] = fresh;
  }
}

const draftKind = (q: Soru): Draft["kind"] | null => (q.kind === "port" ? "port" : q.kind === "var" || q.kind === "secret" ? "value" : q.kind === "mount" ? "mount" : q.kind === "start" ? "start" : null);

/** Whether a question still waits for its answer. */
export function waiting(q: Soru, d: Draft | undefined, edit: EditContext | null): boolean {
  if (q.kind === "port" && edit?.staying.has(q.id)) return false;
  if (!d) return true;
  if (d.kind === "port") return d.use === "" || (d.use === "caddy" && d.name.trim() === "");
  if (d.kind === "value") return !d.keep && d.value === "" && (isSecret(q) || (q.kind === "var" && q.required));
  if (d.kind === "mount") return d.to === "srv" && d.path === "";
  return false;
}

/** How many questions wait for their answer. */
export function waitingCount(inspection: Inceleme | null, state: AnswerState, edit: EditContext | null): number {
  return formQuestions(inspection).filter((q) => waiting(q, state.drafts[q.id], edit)).length;
}

/** One draft as the backend's answer; null while it has none (an unchosen port). */
function answerOf(q: Soru, d: Draft | undefined, root: string, edit: EditContext | null): Yanit | YanitSakla | null {
  if (!d) return null;
  if (d.kind === "port") {
    if (d.use === "raw") return { use: "raw" };
    return d.use === "caddy" ? { use: "caddy", tailscale_name: d.name.trim() } : null;
  }
  if (d.kind === "value") return d.keep && edit && isSecret(q) ? { keep: true } : { value: d.value };
  if (d.kind === "mount") return d.to === "app" ? { to: "app" } : { to: "srv", path: d.path ? `${root.replace(/\/+$/, "")}/${d.path}` : "", read_only: d.readOnly };
  return { mode: d.mode };
}

/** The answers of an install: every question answered so far (one still waiting is left out, so the server's check
    speaks only of what was given; the plan needs them all). */
export function installAnswers(inspection: Inceleme | null, state: AnswerState, root: string): Yanitlar {
  const answers: Record<string, Yanit> = {};
  for (const q of formQuestions(inspection)) {
    if (waiting(q, state.drafts[q.id], null)) continue;
    const a = answerOf(q, state.drafts[q.id], root, null);
    if (a && !("keep" in a)) answers[q.id] = a;
  }
  return { name: state.name.trim(), answers };
}

/** The answers of an edit: a staying port's are left out (its row answers it), a kept secret is {"keep": true}. */
export function editAnswers(inspection: Inceleme | null, state: AnswerState, root: string, edit: EditContext): TanimYanitlari {
  const answers: Record<string, Yanit | YanitSakla> = {};
  for (const q of formQuestions(inspection)) {
    if ((q.kind === "port" && edit.staying.has(q.id)) || waiting(q, state.drafts[q.id], edit)) continue;
    const a = answerOf(q, state.drafts[q.id], root, edit);
    if (a) answers[q.id] = a;
  }
  return { name: edit.app, answers };
}

// ---- the checks the form makes first (panel/master_inspector.py makes them again)
const APP_NAME_RE = /^[a-z][a-z0-9-]{0,29}$/;
const SRV_PATH_RE = /^[A-Za-z0-9_./ -]+$/;

export function appNameProblem(name: string): string {
  if (!name) return "Uygulamanın adını yazın.";
  if (!APP_NAME_RE.test(name)) return "Küçük harfle başlamalı; küçük harf, rakam ve '-' içermeli, en çok 30 karakter.";
  return name.startsWith("konsol") || name.startsWith("master") ? "konsol ve master ile başlayan adlar Obhut'undur." : "";
}

/** A folder under the server root as DD-226's anchors take it: not the root itself, nothing hidden, plain characters. */
export function folderProblem(path: string): string {
  if (!path) return "Bir klasör seçin.";
  const parts = path.split("/");
  if (parts.some((p) => p === "" || p === "." || p === ".." || p.startsWith("."))) return "Gizli olmayan bir alt klasör olmalı.";
  return SRV_PATH_RE.test(path) ? "" : "Klasör yolu yalnız İngilizce harf, rakam, boşluk, '.', '_' ve '-' içerebilir.";
}

/** Why an answer cannot be used yet, before the server is asked; "" when nothing is known against it. `taken`: the
    Tailscale names other rows hold. */
export function localProblem(q: Soru, d: Draft | undefined, drafts: AnswerState["drafts"], taken: readonly string[]): string {
  if (!d) return "";
  if (d.kind === "port" && d.use === "caddy" && d.name.trim()) {
    const name = d.name.trim();
    const twice = Object.entries(drafts).some(([id, o]) => id !== q.id && o.kind === "port" && o.use === "caddy" && o.name.trim() === name);
    return twice ? "Bu Tailscale adı bu uygulamada başka bir portta da kullanılıyor." : nameProblem(name, taken);
  }
  if (d.kind === "mount" && d.to === "srv" && d.path) return folderProblem(d.path);
  return "";
}

// ---- words
/** A question's heading: "8080/TCP · web", "Gizli değer ${DB_PASSWORD}", "Klasör /data", "web · nasıl başlasın?". */
export function questionTitle(q: Soru): string {
  switch (q.kind) {
    case "port":
      return `${q.port}/${q.protocol.toUpperCase()} · ${q.service}`;
    case "var":
      return q.secret ? `Gizli değer \${${q.name}}` : `Değişken \${${q.name}}`;
    case "secret":
      return `Gizli değer ${q.env} · ${q.service}`;
    case "mount":
      return `Klasör ${q.target} · ${q.service}`;
    case "start":
      return `${q.service} · nasıl başlasın?`;
    default:
      return q.title;
  }
}

/** The inspector's guess for a port, in words (A1: shown beside the choice, never applied). */
export const guessText = (q: SoruPort): string => (q.guess === "web" ? "web arayüzü" : "web değil (bilinen bir servis portu)");

/** How a mount question's file names its source. */
export const mountSource = (q: SoruKlasor): string => q.source || "adsız birim";

/** The capabilities a root start keeps (A4), in words. */
export const rootText = (q: SoruBaslangic): string => `${q.open_caps.length} yetki açık · gerekirse kendi kullanıcısına geçer`;

// ---- the marks beside a file's lines
export interface LineMark {
  tone: "refuse" | "question" | "note";
  labels: string[];
}

const QUESTION_WORD: Record<Soru["kind"], string> = { name: "ad", port: "port", var: "değişken", secret: "gizli değer", mount: "klasör", start: "başlatma" };

/** Each marked line of an inspected file with its short words ("port", "gizli değer", "durduruyor") and its most
    serious kind; the full texts are the refusals, notes and questions listed beside the file. */
export function lineMarks(inspection: Inceleme | null): Map<number, LineMark> {
  const out = new Map<number, LineMark>();
  if (!inspection) return out;
  const rank = { refuse: 0, question: 1, note: 2 } as const;
  for (const m of inspection.marks) {
    let word = m.kind === "refuse" ? "durduruyor" : m.kind === "note" ? "not" : "";
    if (m.kind === "question") {
      const q = inspection.questions.find((x) => x.line === m.line && x.title === m.text);
      word = q ? (isSecret(q) ? "gizli değer" : QUESTION_WORD[q.kind]) : "soru";
    }
    const mark = out.get(m.line) ?? { tone: m.kind, labels: [] };
    if (rank[m.kind] < rank[mark.tone]) mark.tone = m.kind;
    if (!mark.labels.includes(word)) mark.labels.push(word);
    out.set(m.line, mark);
  }
  return out;
}

// ---- a random secret (the browser's generator; it never leaves the form but in the request)
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

export function randomSecret(length = 32): string {
  const out: string[] = [];
  const bytes = new Uint8Array(64);
  while (out.length < length) {
    crypto.getRandomValues(bytes);
    for (const b of bytes) {
      // 248 = 4 × 62: a byte above it would make some characters likelier.
      if (b < 248 && out.length < length) out.push(ALPHABET[b % 62] as string);
    }
  }
  return out.join("");
}

/** The UTF-8 size of a text (the server takes a file of at most 256 KiB). */
export const textBytes = (text: string): number => new TextEncoder().encode(text).length;
export const FILE_LIMIT = 256 * 1024;
