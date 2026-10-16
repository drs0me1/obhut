// Gelişmiş's reads and actions (DD-266, phase 4a): the effective Caddy and dnsmasq configuration, and
// Podman's images, volumes and networks with their jobs (docs/design/container-manager-api.md). Paths and
// shapes come from sema.ts (generated from panel/master_api.py); every reply is checked before a page shows
// it, a list item without its expected fields is left out, and a collection that could not be read is
// never shown as an empty one.
import { YOLLAR, type Gelismis, type KonteynerIsi, type KonteynerListesi, type YapilandirmaDosyasi } from "./sema";
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
  managed: boolean;
}

export interface Volume {
  name: string;
  driver: string;
  size: number | null;
  used_by: string[];
  managed: boolean;
}

export interface Network {
  name: string;
  id: string;
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
  storage: { images: number | null; containers: number | null; size: number | null };
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
          used_by: used(i.used_by), managed: i.managed === true,
        }))
      : null,
    volumes: isList(value.volumes)
      ? value.volumes.filter((x) => isObject(x) && isText(x.name)).map((x) => ({
          name: x.name as string, driver: isText(x.driver) ? x.driver : "", size: isNumber(x.size) ? x.size : null, used_by: used(x.used_by), managed: x.managed === true,
        }))
      : null,
    networks: isList(value.networks)
      ? value.networks.filter((n) => isObject(n) && isText(n.name)).map((n) => ({
          name: n.name as string, id: isText(n.id) ? n.id : "", driver: isText(n.driver) ? n.driver : "", subnets: subnets(n.subnets),
          used_by: used(n.used_by), managed: n.managed === true, internal: n.internal === true,
        }))
      : null,
    storage: {
      images: isNumber(storage.images) ? storage.images : null,
      containers: isNumber(storage.containers) ? storage.containers : null,
      size: isNumber(storage.size) ? storage.size : null,
    },
    errors,
  };
}

export type ResourceJob =
  | { action: "image-pull"; image: string }
  | { action: "image-remove"; image: string }
  | { action: "volume-create"; name: string }
  | { action: "volume-remove"; name: string }
  | { action: "network-create"; name: string; subnet: string; internal: boolean }
  | { action: "network-remove"; name: string };

/** Starts a resource job (202 {id, action, name, state}); its end arrives in the activity list. */
export async function startResourceJob(request: ResourceJob): Promise<KonteynerIsi & { id: string }> {
  return shaped<KonteynerIsi & { id: string }>(await postJson(YOLLAR.konteyner_islemi, request), (v) => isText(v.id) && v.id !== "");
}

// The worker checks these again.
/** A fully qualified image: a registry (with a dot or a port, or localhost), a repository and a tag or digest. */
export const IMAGE_RE =
  /^(localhost|[a-z0-9-]+(\.[a-z0-9-]+)+)(:[0-9]{1,5})?\/[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[0-9a-f]{64})$/;
export const RESOURCE_NAME_RE = /^[a-z0-9][a-z0-9_.-]{0,62}$/;
export const CIDR_RE = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;
