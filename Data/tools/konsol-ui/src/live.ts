// The shell's live data (DD-258). Every value starts unknown (null) and is shown as "—" until the server
// answers; a failed read keeps the last known value. The event stream (api/olaylar.ts) pushes resources,
// health, running jobs and the pending settings change. When the stream is unavailable (404, 503, no
// ReadableStream) or keeps failing, the same data is polled: resources every 10 s, health every 60 s, jobs
// and the pending change every 5 s. Applications, the update check and Erişim's warnings are read every
// 60 s in both modes, and again whenever a job starts or ends. Hidden pages do not poll.
import { computed, reactive } from "vue";
import {
  YOLLAR,
  type Bekleyen,
  type BekleyenDegisiklik,
  type Erisim,
  type Guncelleme,
  type Islem,
  type Islemler,
  type Kaynaklar,
  type Saglik,
  type SaglikDurumu,
  type Uygulamalar,
  type Uyari,
} from "./api/sema";
import { ApiError, getJson } from "./api/http";
import { isApp } from "./api/konsol";
import { openEvents } from "./api/olaylar";

export type Connection = "baslangic" | "canli" | "yeniden" | "yoklama";
export type Level = "ok" | "warning" | "danger";

export const live = reactive({
  kaynaklar: null as Kaynaklar | null,
  /** The server's clock minus this browser's, in seconds (from kaynaklar.read_at). */
  offset: 0,
  saglik: null as Saglik | null,
  islemler: null as Islem[] | null,
  /** undefined: not read yet; null: no pending change. */
  bekleyen: undefined as BekleyenDegisiklik | null | undefined,
  /** Date.now() when bekleyen.seconds was read; the banner counts down from there. */
  bekleyenAt: 0,
  /** Applications (DD-261): packages, Konsol's containers and the built-ins in one list. */
  uygulamalar: null as Uygulamalar | null,
  guncelleme: null as Guncelleme | null,
  /** Erişim's warnings; null while unknown. */
  uyarilar: null as Uyari[] | null,
  /** GET /api/konsol/erisim answered 404: an older backend without the read model. */
  erisimYok: false,
  connection: "baslangic" as Connection,
});

type Key = "kaynaklar" | "saglik" | "islemler" | "bekleyen" | "uygulamalar" | "guncelleme" | "erisim";

const PATHS: Record<Key, string> = {
  kaynaklar: YOLLAR.kaynaklar,
  saglik: YOLLAR.saglik,
  islemler: YOLLAR.etkinlik,
  bekleyen: YOLLAR.bekleyen,
  uygulamalar: YOLLAR.uygulamalar,
  guncelleme: YOLLAR.guncelleme,
  erisim: YOLLAR.erisim,
};

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isText = (v: unknown): v is string => typeof v === "string";

function isJob(v: unknown): v is Islem {
  return isObject(v) && isText(v.id) && isText(v.ad) && isText(v.tur) && isText(v.durum);
}

/** Health levels: "ok", "warn" and everything else ("bad", or a status this shell does not know). */
export function checkLevel(status: SaglikDurumu | string): Level {
  return status === "ok" ? "ok" : status === "warn" ? "warning" : "danger";
}

let jobSignature: string | null = null;

const apply: Record<Key, (data: unknown) => void> = {
  kaynaklar(data) {
    if (!isObject(data)) return;
    live.kaynaklar = data as unknown as Kaynaklar;
    if (typeof data.read_at === "number" && Number.isFinite(data.read_at)) live.offset = data.read_at - Date.now() / 1000;
  },
  saglik(data) {
    if (isObject(data) && Array.isArray(data.checks)) {
      const checks = data.checks.filter((c): c is Saglik["checks"][number] => isObject(c) && isText(c.status));
      live.saglik = { ...(data as unknown as Saglik), checks };
    }
  },
  islemler(data) {
    if (!isObject(data) || !Array.isArray(data.items)) return;
    const items = (data as unknown as Islemler).items.filter(isJob);
    live.islemler = items;
    // A job that started, ended or failed may change the application list, the version or health.
    const signature = items.map((j) => `${j.tur}:${j.id}:${j.durum}`).sort().join("|");
    if (jobSignature !== null && signature !== jobSignature) {
      void refresh("uygulamalar", true);
      if (/(^|\|)guncelleme:/.test(signature + "|" + jobSignature)) void refresh("guncelleme", true);
      if (/(^|\|)onarim:/.test(signature + "|" + jobSignature)) void refresh("saglik", true);
    }
    jobSignature = signature;
  },
  bekleyen(data) {
    if (!isObject(data) || !("bekleyen" in data)) return;
    const value = (data as unknown as Bekleyen).bekleyen;
    live.bekleyen = isObject(value) && isText(value.phase) ? value : null;
    live.bekleyenAt = Date.now();
  },
  uygulamalar(data) {
    if (!isObject(data) || !Array.isArray(data.items)) return;
    const value = data as unknown as Uygulamalar;
    live.uygulamalar = {
      ...value,
      items: value.items.filter(isApp),
      katalog: Array.isArray(value.katalog) ? value.katalog.filter((k) => isObject(k) && isText(k.id) && isText(k.ad)) : [],
      altyapi: isObject(value.altyapi) ? value.altyapi : { podman: "", calisiyor: false, imaj: 0, kullanilmayan_imaj: 0, birim: 0, ag: 0 },
      hatalar: Array.isArray(value.hatalar) ? value.hatalar.filter(isText) : [],
    };
  },
  guncelleme(data) {
    if (isObject(data)) live.guncelleme = data as unknown as Guncelleme;
  },
  erisim(data) {
    if (isObject(data) && Array.isArray(data.uyarilar)) {
      live.uyarilar = (data as unknown as Erisim).uyarilar.filter((u): u is Uyari => isObject(u) && isText(u.metin));
      live.erisimYok = false;
    }
  },
};

// A read that started before a newer stream event arrived must not overwrite it.
const generation: Record<Key, number> = { kaynaklar: 0, saglik: 0, islemler: 0, bekleyen: 0, uygulamalar: 0, guncelleme: 0, erisim: 0 };
const inflight = new Set<Key>();
// A read asked for because something changed (a job started or ended) while the same read is under way
// runs once more when it ends, so it cannot miss the change; a timer's read is simply skipped.
const again = new Set<Key>();

async function refresh(key: Key, changed = false): Promise<void> {
  if (key === "erisim" && live.erisimYok) return;
  if (inflight.has(key)) {
    if (changed) again.add(key);
    return;
  }
  inflight.add(key);
  const before = generation[key];
  try {
    const data = await getJson(PATHS[key]);
    if (generation[key] === before) apply[key](data);
  } catch (err) {
    if (key === "erisim" && err instanceof ApiError && err.status === 404) {
      live.erisimYok = true;
      live.uyarilar = null;
    }
  } finally {
    inflight.delete(key);
    if (again.delete(key)) void refresh(key, true);
  }
}

/** Reads the application list now (a page opened, or an operation was started from it). */
export function refreshApps(): Promise<void> {
  return refresh("uygulamalar", true);
}

// Timers: the slow reads run always; the fast ones only while the stream is not delivering.
const ALWAYS: [Key, number][] = [["uygulamalar", 60000], ["guncelleme", 60000], ["erisim", 60000]];
const FALLBACK: [Key, number][] = [["kaynaklar", 10000], ["saglik", 60000], ["islemler", 5000], ["bekleyen", 5000]];
const timers = new Map<Key, number>();
let polling: "" | "yok" | "kopuk" = "";

function every(key: Key, ms: number): void {
  const old = timers.get(key);
  if (old !== undefined) clearInterval(old);
  timers.set(key, window.setInterval(() => {
    if (!document.hidden) void refresh(key);
  }, ms));
}

function startPolling(reason: "yok" | "kopuk"): void {
  live.connection = "yoklama";
  if (polling) {
    if (reason === "yok") polling = "yok";
    return;
  }
  polling = reason;
  for (const [key, ms] of FALLBACK) {
    every(key, ms);
    void refresh(key);
  }
}

function stopPolling(): void {
  if (polling !== "kopuk") return;
  polling = "";
  for (const [key] of FALLBACK) {
    const timer = timers.get(key);
    if (timer !== undefined) clearInterval(timer);
    timers.delete(key);
  }
}

const STREAM_KEYS = new Set<string>(["kaynaklar", "saglik", "islemler", "bekleyen"]);
// Consecutive stream failures after which the page polls while the stream keeps retrying.
const FAILURES_BEFORE_POLLING = 3;

let started = false;

export function startLive(): void {
  if (started) return;
  started = true;
  for (const key of Object.keys(PATHS) as Key[]) void refresh(key);
  for (const [key, ms] of ALWAYS) every(key, ms);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    for (const [key] of ALWAYS) void refresh(key);
    if (polling) for (const [key] of FALLBACK) void refresh(key);
  });
  openEvents({
    open() {
      stopPolling();
      if (!polling) live.connection = "canli";
    },
    event(name, data) {
      if (!STREAM_KEYS.has(name)) return;
      const key = name as Key;
      generation[key] += 1;
      apply[key](data);
    },
    lost(failures) {
      if (failures >= FAILURES_BEFORE_POLLING) startPolling("kopuk");
      else if (!polling) live.connection = "yeniden";
    },
    unavailable() {
      startPolling("yok");
    },
  });
}

// ---- derived values

/** The server's clock now, in Unix seconds. */
export const serverNow = (): number => Date.now() / 1000 + live.offset;

export const health = computed(() => {
  const s = live.saglik;
  if (!s) return null;
  let danger = 0;
  let warning = 0;
  for (const check of s.checks) {
    const level = checkLevel(check.status);
    if (level === "danger") danger += 1;
    else if (level === "warning") warning += 1;
  }
  return { danger, warning };
});

/** Health problems plus Erişim's warnings (the top bar's chip); null while health is unknown. */
export const problems = computed(() => {
  const h = health.value;
  if (!h) return null;
  const warnings = live.uyarilar ?? [];
  const bad = warnings.filter((u) => u.seviye === "bad").length;
  const count = h.danger + h.warning + warnings.length;
  const level: Level = h.danger + bad > 0 ? "danger" : count > 0 ? "warning" : "ok";
  return { count, level };
});

/** The applications the operator manages: every item but Files, which has its own section (Dosyalar). */
export const apps = computed(() => (live.uygulamalar ? live.uygulamalar.items.filter((a) => a.id !== "yerlesik:dosya") : null));

export const runningJobs = computed(() => (live.islemler ?? []).filter((j) => j.durum === "calisiyor"));
export const finishedJobs = computed(() => (live.islemler ?? []).filter((j) => j.durum !== "calisiyor"));
