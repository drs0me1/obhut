// Podman's reads (DD-211, DD-289): the containers, images, volumes and networks with what each kind takes on disk
// (GET /api/konsol/konteynerler/liste), and the section's only write, the cleanup of what nothing uses (its read
// model and the job, K8). Paths and shapes come from sema.ts (generated from panel/master_api.py); every reply is
// checked before a page shows it, a list item without its expected fields is left out, and a collection that
// could not be read is never shown as an empty one.
import { YOLLAR, type KonteynerListesi, type Temizlik, type TemizlikIsi, type TemizlikIstegi } from "./sema";
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
    folders with their sizes) and the containers Obhut does not manage; `fresh` measures the folders again. */
export async function readCleanup(fresh = false): Promise<Temizlik> {
  const v = shaped<Temizlik>(await getJson(YOLLAR.temizlik + (fresh ? "?yenile=1" : "")), (d) =>
    ["imajlar", "aglar", "birimler", "klasorler", "konteynerler"].every((k) => isList(d[k])));
  return {
    read_at: isNumber(v.read_at) ? v.read_at : 0,
    imajlar: v.imajlar.filter((i) => isObject(i) && isText(i.id)).map((i) => ({ id: i.id, etiketler: texts(i.etiketler), boyut: nullableNumber(i.boyut), olusturuldu: nullableNumber(i.olusturuldu) })),
    aglar: v.aglar.filter((n) => isObject(n) && isText(n.ad)).map((n) => ({ ad: n.ad, surucu: isText(n.surucu) ? n.surucu : "", arayuz: isText(n.arayuz) ? n.arayuz : "" })),
    birimler: v.birimler.filter((b) => isObject(b) && isText(b.ad)).map((b) => ({ ad: b.ad, surucu: isText(b.surucu) ? b.surucu : "", olusturuldu: nullableNumber(b.olusturuldu) })),
    klasorler: v.klasorler.filter((k) => isObject(k) && isText(k.ad) && isText(k.yol)).map((k) => ({ ad: k.ad, yol: k.yol, boyut: nullableNumber(k.boyut), neden: isText(k.neden) ? k.neden : "" })),
    konteynerler: v.konteynerler
      .filter((c) => isObject(c) && isText(c.ad))
      .map((c) => ({ ad: c.ad, imaj: isText(c.imaj) ? c.imaj : "", durum: isText(c.durum) ? c.durum : "", yonetici: c.yonetici === "kayitsiz" || c.yonetici === "baska" ? c.yonetici : "podman" })),
    hatalar: texts(v.hatalar),
  };
}

/** The selected items as one job (202), followed in İşlemler; each is checked again right before it goes. */
export async function startCleanup(request: TemizlikIstegi): Promise<TemizlikIsi> {
  return shaped(await postJson(YOLLAR.temizle, request), (v) => isText(v.is) && v.is !== "");
}
