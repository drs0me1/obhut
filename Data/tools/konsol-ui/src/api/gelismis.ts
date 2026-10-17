// Gelişmiş's reads (DD-266; read-only since the rebuild's phase 5, K8): the effective Caddy and dnsmasq
// configuration, Podman's images, volumes and networks (docs/design/container-manager-api.md), and its only write:
// the cleanup of what nothing uses (its read model and the job). Paths and shapes come from sema.ts (generated
// from panel/master_api.py); every reply is checked before a page shows it, a list item without its expected
// fields is left out, and a collection that could not be read is never shown as an empty one.
import { YOLLAR, type Gelismis, type KonteynerListesi, type Temizlik, type TemizlikIsi, type TemizlikIstegi, type YapilandirmaDosyasi } from "./sema";
import { getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isList = Array.isArray;
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const texts = (v: unknown): string[] => (isList(v) ? v.filter(isText) : []);
const files = (v: unknown): YapilandirmaDosyasi[] => (isList(v) ? v.filter((f): f is YapilandirmaDosyasi => isObject(f) && isText(f.file) && isText(f.text)) : []);

export interface CaddyRoute {
  path: string;
  kind: string;
  to: string;
}

export interface DnsName {
  name: string;
  iface: string;
  family: number | null;
  address: string;
  source: string;
}

export interface Advanced {
  read_at: number;
  caddy: { entries: { address: string; routes: CaddyRoute[]; source: string; access: "tailscale" | "wan"; scheme: string }[]; raw: YapilandirmaDosyasi[] };
  dnsmasq: { listen: string[]; domains: string[]; dhcp: boolean; names: DnsName[]; raw: YapilandirmaDosyasi[] };
}

export async function readAdvanced(fresh = false): Promise<Advanced> {
  const value = shaped<Gelismis>(await getJson(YOLLAR.gelismis + (fresh ? "?yenile=1" : "")), (v) => isObject(v.caddy) && isObject(v.dnsmasq));
  const caddy = value.caddy as unknown as Record<string, unknown>;
  const dns = value.dnsmasq as unknown as Record<string, unknown>;
  return {
    read_at: isNumber(value.read_at) ? value.read_at : 0,
    caddy: {
      entries: (isList(caddy.entries) ? caddy.entries : [])
        .filter((e): e is Record<string, unknown> => isObject(e) && isText(e.address) && isText(e.source))
        .map((e) => ({
          address: e.address as string,
          source: e.source as string,
          access: e.access === "wan" ? "wan" : "tailscale",
          scheme: isText(e.scheme) ? e.scheme : "",
          routes: (isList(e.routes) ? e.routes : [])
            .filter((r): r is Record<string, unknown> => isObject(r) && isText(r.kind))
            .map((r) => ({ path: isText(r.path) ? r.path : "", kind: r.kind as string, to: isText(r.to) ? r.to : "" })),
        })),
      raw: files(caddy.raw),
    },
    dnsmasq: {
      listen: texts(dns.listen),
      domains: texts(dns.domains),
      dhcp: dns.dhcp === true,
      names: (isList(dns.names) ? dns.names : [])
        .filter((n): n is Record<string, unknown> => isObject(n) && isText(n.name))
        .map((n) => ({
          name: n.name as string,
          iface: isText(n.iface) ? n.iface : "",
          family: n.family === 4 || n.family === 6 ? n.family : null,
          address: isText(n.address) ? n.address : "",
          source: isText(n.source) ? n.source : "",
        })),
      raw: files(dns.raw),
    },
  };
}

// ---- Podman's resources
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

export interface Resources {
  read_at: number;
  runtime: { version: string; ok: boolean; error: string };
  /** null: the collection could not be read (its reason is in `errors`). */
  images: Image[] | null;
  volumes: Volume[] | null;
  networks: Network[] | null;
  storage: { size: number | null };
  errors: Partial<Record<"images" | "volumes" | "networks" | "stats" | "containers", string>> & Record<string, string>;
}

const used = (v: unknown) => texts(v);
// Podman's subnet rows may be {subnet, gateway} objects; plain text is read too.
const subnets = (v: unknown) => (isList(v) ? v.map((x) => (isText(x) ? x : isObject(x) && isText(x.subnet) ? x.subnet : "")).filter(Boolean) : []);

export async function readResources(): Promise<Resources> {
  const value = shaped<KonteynerListesi>(await getJson(YOLLAR.konteyner_listesi), (v) => isObject(v.runtime) || "images" in v);
  const rt: Record<string, unknown> = isObject(value.runtime) ? value.runtime : {};
  const errors: Record<string, string> = {};
  if (isObject(value.resource_errors)) for (const [k, v] of Object.entries(value.resource_errors)) if (isText(v) && v) errors[k] = v;
  const storage: Record<string, unknown> = isObject(value.storage) ? value.storage : {};
  return {
    read_at: isNumber(value.read_at) ? value.read_at : 0,
    runtime: { version: isText(rt.version) ? rt.version : "", ok: rt.ok === true, error: isText(rt.error) ? rt.error : "" },
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
    storage: { size: isNumber(storage.size) ? storage.size : null },
    errors,
  };
}

// ---- the cleanup (K8)
const nullableNumber = (v: unknown): number | null => (isNumber(v) ? v : null);

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
