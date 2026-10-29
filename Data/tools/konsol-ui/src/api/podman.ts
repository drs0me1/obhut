// Podman's reads (DD-211, DD-289): the containers, images, volumes and networks with what each kind takes on disk
// (GET /api/konsol/konteynerler/liste) and the cleanup of what nothing uses (its read model and the job, K8);
// DD-294: one container's page, its log and its actions (start, stop, restart, remove; a job each), whoever
// installed it. Paths and shapes come from sema.ts (generated from panel/master_api.py); every reply is
// checked before a page shows it, a list item without its expected fields is left out, and a collection that
// could not be read is never shown as an empty one.
import {
  YOLLAR,
  type KonteynerAyrintisi,
  type KonteynerEylemIsi,
  type KonteynerEylemi,
  type KonteynerGunlugu,
  type KonteynerListesi,
  type KonteynerYonetimi,
  type Temizlik,
  type TemizlikIsi,
  type TemizlikIstegi,
} from "./sema";
import { getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isList = Array.isArray;
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const texts = (v: unknown): string[] => (isList(v) ? v.filter(isText) : []);
const nullableNumber = (v: unknown): number | null => (isNumber(v) ? v : null);

// ---- the inventory
export interface Container {
  name: string;
  image: string;
  /** Podman's state: running, exited, created, paused … */
  state: string;
  /** healthy, unhealthy, starting or "" (no health check). */
  health: string;
  exitCode: number;
  restarts: number;
  started: number | null;
  /** The application it belongs to (its labels and record), or null: a container Obhut does not manage. */
  app: string | null;
  /** Who runs it and what Konsol may do to it (DD-294); null when the server did not say. */
  manager: KonteynerYonetimi | null;
  /** The pod it is in ("" for none). */
  pod: string;
  /** A job working on it now. */
  busy: string | null;
  cpu: number | null;
  memory: number | null;
  ports: { hostIp: string; hostPort: number; containerPort: number; protocol: string }[];
}

export interface Image {
  id: string;
  name: string;
  size: number | null;
  created: number | null;
  used_by: string[];
}

export interface Volume {
  name: string;
  driver: string;
  used_by: string[];
  managed: boolean;
}

export interface Network {
  name: string;
  driver: string;
  subnets: string[];
  used_by: string[];
  managed: boolean;
  internal: boolean;
}

/** What one kind takes on disk as `podman system df` counts it. */
export interface StorageKind {
  type: "images" | "containers" | "volumes";
  count: number;
  active: number;
  size: number;
  reclaimable: number | null;
}

export interface Resources {
  read_at: number;
  runtime: { version: string; ok: boolean; error: string };
  /** null: the collection could not be read (its reason is in `errors`). */
  containers: Container[] | null;
  images: Image[] | null;
  volumes: Volume[] | null;
  networks: Network[] | null;
  storage: { size: number | null; types: StorageKind[] };
  errors: Partial<Record<"images" | "volumes" | "networks" | "stats" | "containers", string>> & Record<string, string>;
}

const used = (v: unknown) => texts(v);
const ACTIONS: readonly KonteynerYonetimi["eylemler"][number][] = ["baslat", "durdur", "yeniden-baslat", "kaldir"];
const MANAGERS: readonly KonteynerYonetimi["tur"][] = ["uygulama", "birim", "compose", "pod", "podman"];
/** Who runs a container, in words. */
export function managerText(m: KonteynerYonetimi | null | undefined): string {
  if (!m) return "—";
  return {
    uygulama: `Obhut uygulaması · ${m.ad}`,
    birim: `systemd birimi · ${m.ad}`,
    compose: `Compose projesi · ${m.ad}`,
    pod: `Pod · ${m.ad}`,
    podman: "Yalnız Podman",
  }[m.tur];
}

/** A manager as the server sent it, or null; an action the shell does not know is left out. */
export function manager(v: unknown): KonteynerYonetimi | null {
  if (!isObject(v) || !MANAGERS.includes(v.tur as KonteynerYonetimi["tur"])) return null;
  return {
    tur: v.tur as KonteynerYonetimi["tur"], ad: isText(v.ad) ? v.ad : "",
    eylemler: (isList(v.eylemler) ? v.eylemler : []).filter((a): a is KonteynerYonetimi["eylemler"][number] => ACTIONS.includes(a as never)),
    dosya: isText(v.dosya) ? v.dosya : "",
  };
}
// Podman's subnet rows may be {subnet, gateway} objects; plain text is read too.
const subnets = (v: unknown) => (isList(v) ? v.map((x) => (isText(x) ? x : isObject(x) && isText(x.subnet) ? x.subnet : "")).filter(Boolean) : []);
const KINDS: readonly StorageKind["type"][] = ["images", "containers", "volumes"];

export async function readResources(): Promise<Resources> {
  const value = shaped<KonteynerListesi>(await getJson(YOLLAR.konteyner_listesi), (v) => isObject(v.runtime) || "images" in v);
  const rt: Record<string, unknown> = isObject(value.runtime) ? value.runtime : {};
  const errors: Record<string, string> = {};
  if (isObject(value.resource_errors)) for (const [k, v] of Object.entries(value.resource_errors)) if (isText(v) && v) errors[k] = v;
  const storage: Record<string, unknown> = isObject(value.storage) ? value.storage : {};
  return {
    read_at: isNumber(value.read_at) ? value.read_at : 0,
    runtime: { version: isText(rt.version) ? rt.version : "", ok: rt.ok === true, error: isText(rt.error) ? rt.error : "" },
    containers: isList(value.containers)
      ? value.containers.filter((c) => isObject(c) && isText(c.name)).map((c) => ({
          name: c.name as string, image: isText(c.image) ? c.image : "", state: isText(c.state) ? c.state : "", health: isText(c.health) ? c.health : "",
          exitCode: isNumber(c.exit_code) ? c.exit_code : 0, restarts: isNumber(c.restarts) ? c.restarts : 0, started: nullableNumber(c.started),
          app: c.source === "uygulama" && isText(c.uygulama) && c.uygulama ? c.uygulama : null,
          manager: manager(c.yonetim), pod: isText(c.pod) ? c.pod : "", busy: isText(c.busy) && c.busy ? c.busy : null,
          cpu: nullableNumber(c.cpu_percent), memory: nullableNumber(c.memory_bytes),
          ports: (isList(c.ports) ? c.ports : [])
            .filter((p) => isObject(p) && isNumber(p.host_port) && isNumber(p.container_port))
            .map((p) => ({ hostIp: isText(p.host_ip) ? p.host_ip : "", hostPort: p.host_port as number, containerPort: p.container_port as number,
              protocol: isText(p.protocol) ? p.protocol : "tcp" })),
        }))
      : null,
    images: isList(value.images)
      ? value.images.filter((i) => isObject(i) && isText(i.name)).map((i) => ({
          id: isText(i.id) ? i.id : "", name: i.name as string, size: isNumber(i.size) ? i.size : null, created: isNumber(i.created) ? i.created : null,
          used_by: used(i.used_by),
        }))
      : null,
    volumes: isList(value.volumes)
      ? value.volumes.filter((x) => isObject(x) && isText(x.name)).map((x) => ({
          name: x.name as string, driver: isText(x.driver) ? x.driver : "", used_by: used(x.used_by), managed: x.managed === true,
        }))
      : null,
    networks: isList(value.networks)
      ? value.networks.filter((n) => isObject(n) && isText(n.name)).map((n) => ({
          name: n.name as string, driver: isText(n.driver) ? n.driver : "", subnets: subnets(n.subnets),
          used_by: used(n.used_by), managed: n.managed === true, internal: n.internal === true,
        }))
      : null,
    storage: {
      size: isNumber(storage.size) ? storage.size : null,
      types: (isList(storage.types) ? storage.types : [])
        .filter((k): k is Record<string, unknown> => isObject(k) && KINDS.includes(k.type as StorageKind["type"]) && isNumber(k.size))
        .map((k) => ({ type: k.type as StorageKind["type"], count: isNumber(k.count) ? k.count : 0, active: isNumber(k.active) ? k.active : 0,
          size: k.size as number, reclaimable: nullableNumber(k.reclaimable) })),
    },
    errors,
  };
}

// ---- the cleanup (K8)
/** What nothing uses (images by ID with their tags, networks and volumes by name, removed applications' data
    folders with their sizes); `fresh` measures the folders again. */
export async function readCleanup(fresh = false): Promise<Temizlik> {
  const v = shaped<Temizlik>(await getJson(YOLLAR.temizlik + (fresh ? "?yenile=1" : "")), (d) =>
    ["imajlar", "aglar", "birimler", "klasorler"].every((k) => isList(d[k])));
  return {
    read_at: isNumber(v.read_at) ? v.read_at : 0,
    imajlar: v.imajlar.filter((i) => isObject(i) && isText(i.id)).map((i) => ({ id: i.id, etiketler: texts(i.etiketler), boyut: nullableNumber(i.boyut), olusturuldu: nullableNumber(i.olusturuldu) })),
    aglar: v.aglar.filter((n) => isObject(n) && isText(n.ad)).map((n) => ({ ad: n.ad, surucu: isText(n.surucu) ? n.surucu : "", arayuz: isText(n.arayuz) ? n.arayuz : "" })),
    birimler: v.birimler.filter((b) => isObject(b) && isText(b.ad)).map((b) => ({ ad: b.ad, surucu: isText(b.surucu) ? b.surucu : "", olusturuldu: nullableNumber(b.olusturuldu) })),
    klasorler: v.klasorler.filter((k) => isObject(k) && isText(k.ad) && isText(k.yol)).map((k) => ({ ad: k.ad, yol: k.yol, boyut: nullableNumber(k.boyut), neden: isText(k.neden) ? k.neden : "" })),
    hatalar: texts(v.hatalar),
  };
}

/** The selected items as one job (202), followed in İşlemler; each is checked again right before it goes. */
export async function startCleanup(request: TemizlikIstegi): Promise<TemizlikIsi> {
  return shaped(await postJson(YOLLAR.temizle, request), (v) => isText(v.is) && v.is !== "");
}

// ---- one container (DD-294)
/** One container's page: its facts (never its environment or command line), who runs it, its resources. */
export async function readContainer(name: string): Promise<KonteynerAyrintisi> {
  const v = shaped<KonteynerAyrintisi>(await getJson(`${YOLLAR.konteyner_ayrintisi}?${new URLSearchParams({ ad: name })}`), (d) =>
    isText(d.ad) && isObject(d.yonetim) && isList(d.portlar) && isList(d.baglamalar) && isList(d.aglar) && isList(d.etiketler));
  const m = manager(v.yonetim);
  if (!m) throw new Error("Konteynerin yöneticisi okunamadı.");
  return {
    ...v, yonetim: m,
    portlar: v.portlar.filter((p) => isObject(p) && isNumber(p.host_port) && isNumber(p.container_port)),
    baglamalar: v.baglamalar.filter((b) => isObject(b) && isText(b.hedef)),
    aglar: v.aglar.filter((a) => isObject(a) && isText(a.ad)),
    etiketler: v.etiketler.filter((e) => isObject(e) && isText(e.ad) && isText(e.deger)),
  };
}

/** A container's last lines, from where its log driver writes them. */
export async function readContainerLog(name: string, lines: number): Promise<KonteynerGunlugu> {
  const v = shaped<KonteynerGunlugu>(await getJson(`${YOLLAR.konteyner_gunlugu}?${new URLSearchParams({ ad: name, satir: String(lines) })}`), (d) =>
    isList(d.satirlar));
  return { satirlar: texts(v.satirlar), kesik: v.kesik === true, kaynak: v.kaynak };
}

/** Starts one container's action as a job (202), followed in İşlemler. */
export async function startContainerAction(request: KonteynerEylemi): Promise<KonteynerEylemIsi> {
  return shaped(await postJson(YOLLAR.konteyner_eylemi, request), (v) => isText(v.is) && v.is !== "");
}
