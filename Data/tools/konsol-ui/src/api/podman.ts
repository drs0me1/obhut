// The container manager's reads and writes for Uygulamalar' add flows and an application's page (DD-211,
// DD-258 phase 4a; Data/docs/design/container-manager-api.md): the inventory, one container's detail,
// the image update check, an operation's record, the write actions and the folder list of the picker.
// Paths come from sema.ts (generated from panel/master_api.py); every reply is checked before a page shows
// it, and a list item without its expected fields is left out. The browser never decides what a container
// may do: it shows `actions` and `restricted_reason` as the server sends them.
import {
  YOLLAR,
  type Klasorler,
  type KonteynerAyrintisi,
  type KonteynerPortu,
} from "./sema";
import { getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isList = Array.isArray;
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isBool = (v: unknown): v is boolean => typeof v === "boolean";
const query = (path: string, params: Record<string, string>) => `${path}?${new URLSearchParams(params).toString()}`;

// ---- a generic definition and an App Store adapter's fields, as the detail's `config` carries them
export type Scope = "local" | "tailscale" | "public";
export type Restart = "no" | "on-failure" | "always";
export type Account = "downloads" | "image";

export interface ConfigPort {
  scope: Scope;
  host_port: number;
  container_port: number;
  protocol: "tcp" | "udp";
  public_ack?: boolean;
}

export interface ConfigMount {
  type: "bind" | "volume";
  source: string;
  destination: string;
  read_only: boolean;
}

/** A secret row comes without its value (`present` says one is stored); a blank value keeps it. */
export interface ConfigEnv {
  name: string;
  value?: string;
  secret: boolean;
  present?: boolean;
}

export interface ContainerConfig {
  name: string;
  image: string;
  image_ref?: string;
  network: string;
  ports: ConfigPort[];
  mounts: ConfigMount[];
  environment: ConfigEnv[];
  command: string[];
  autostart: boolean;
  manual_stop?: boolean;
  restart: Restart;
  cpus: string;
  memory: string;
  user?: Account;
  /** pids_limit, ulimits, stop_signal, schema, revision: kept as read; an editor that omits them keeps them. */
  [key: string]: unknown;
}

/** An App Store package's container settings (DD-219, DD-221): the peer port only when the adapter has one. */
export interface AdapterConfig {
  listener_port: number;
  peer_port?: number;
  save?: string;
}

export interface ProtectedMount {
  destination: string;
  source: string;
  reason: string;
}

export interface Listening {
  address: string;
  port: number;
  protocol: string;
  scope: string;
}

export interface Update {
  state: string;
  channel: string;
  error: string;
  checked_at?: number;
}

/** A container row of the inventory with the fields the pages read, each checked (unknown → empty). */
export interface Container {
  id: string;
  name: string;
  image: string;
  state: string;
  unit: string;
  network: string;
  ports: KonteynerPortu[];
  started: number | null;
  restarts: number;
  health: string;
  /** False for a managed definition without a live Podman container (its service is stopped). */
  live: boolean;
  source: "appstore" | "konsol" | "external";
  module_id: string | null;
  revision: string | null;
  actions: string[];
  restricted_reason: string;
  cpu_percent: number | null;
  memory_bytes: number | null;
  busy: string | null;
  listening: Listening[] | null;
  update: Update | null;
}

/** One container's detail (GET …/ayrinti): the row's fields, its mounts and, for a managed one, its definition. */
export interface ContainerDetail extends Container {
  mounts_detail: { type: string; source: string; destination: string; rw: boolean; name: string }[];
  generic: ContainerConfig | null;
  adapter: AdapterConfig | null;
  editable: string[];
  protected: ProtectedMount[];
  effective_autostart: boolean | null;
  user: string;
  command: string;
}

export interface Inventory {
  runtime: { version: string; ok: boolean; error: string };
  containers: Container[];
  images: { id: string; name: string; used_by: string[]; pinned: boolean; size: number | null }[];
  volumes: { name: string; driver: string; used_by: string[]; managed: boolean; size: number | null }[];
  networks: { name: string; driver: string; managed: boolean; internal: boolean; used_by: string[] }[];
  storage: { images: number; containers: number; size: number | null };
  resource_errors: Record<string, string>;
}

const SOURCES = new Set(["appstore", "konsol", "external"]);

export function isGenericConfig(v: unknown): v is ContainerConfig {
  return isObject(v) && isText(v.name) && isText(v.image) && isList(v.ports) && isList(v.mounts) && isList(v.environment);
}

export function isAdapterConfig(v: unknown): v is AdapterConfig {
  return isObject(v) && isNumber(v.listener_port) && !("image" in v);
}

function update(v: unknown): Update | null {
  if (!isObject(v) || !isText(v.state)) return null;
  const out: Update = { state: v.state, channel: isText(v.channel) ? v.channel : "", error: isText(v.error) ? v.error : "" };
  if (isNumber(v.checked_at)) out.checked_at = v.checked_at;
  return out;
}

function listening(v: unknown): Listening[] | null {
  if (!isList(v)) return null;
  return v.filter((s): s is Listening => isObject(s) && isText(s.address) && isNumber(s.port) && isText(s.protocol) && isText(s.scope));
}

const textOf = (v: unknown) => (isText(v) ? v : "");
const numberOr = (v: unknown) => (isNumber(v) ? v : null);

function row(v: Record<string, unknown>): Container {
  return {
    id: textOf(v.id),
    name: v.name as string,
    image: textOf(v.image),
    state: isText(v.state) ? v.state : "unknown",
    unit: textOf(v.unit),
    network: textOf(v.network),
    ports: isList(v.ports) ? v.ports.filter((p): p is KonteynerPortu => isObject(p) && isNumber(p.host_port) && isNumber(p.container_port)) : [],
    started: numberOr(v.started),
    restarts: isNumber(v.restarts) ? v.restarts : 0,
    health: textOf(v.health),
    live: v.live !== false,
    source: isText(v.source) && SOURCES.has(v.source) ? (v.source as Container["source"]) : "external",
    module_id: isText(v.module_id) ? v.module_id : null,
    revision: isText(v.revision) ? v.revision : null,
    actions: isList(v.actions) ? v.actions.filter(isText) : [],
    restricted_reason: textOf(v.restricted_reason),
    cpu_percent: numberOr(v.cpu_percent),
    memory_bytes: numberOr(v.memory_bytes),
    busy: isText(v.busy) ? v.busy : null,
    listening: listening(v.listening),
    update: update(v.update),
  };
}

function protectedMounts(v: unknown): ProtectedMount[] {
  if (!isList(v)) return [];
  return v
    .map((m) => (isText(m) ? { destination: m, source: "", reason: "" } : isObject(m) && isText(m.destination) ? { destination: m.destination, source: isText(m.source) ? m.source : "", reason: isText(m.reason) ? m.reason : "" } : null))
    .filter((m): m is ProtectedMount => m !== null);
}

export async function readInventory(): Promise<Inventory> {
  const v = shaped<Record<string, unknown>>(await getJson(YOLLAR.konteyner_listesi), (d) => isObject(d.runtime) && isList(d.containers));
  const runtime = v.runtime as Record<string, unknown>;
  const storage = isObject(v.storage) ? v.storage : {};
  const errors = isObject(v.resource_errors) ? v.resource_errors : {};
  const objects = (list: unknown) => (isList(list) ? list.filter((x): x is Record<string, unknown> => isObject(x) && isText(x.name)) : []);
  const names = (list: unknown) => (isList(list) ? list.filter(isText) : []);
  return {
    runtime: { version: textOf(runtime.version), ok: runtime.ok === true, error: textOf(runtime.error) },
    containers: objects(v.containers).map(row),
    images: objects(v.images).map((o) => ({ id: textOf(o.id), name: o.name as string, used_by: names(o.used_by), pinned: o.pinned === true, size: numberOr(o.size) })),
    volumes: objects(v.volumes).map((o) => ({ name: o.name as string, driver: textOf(o.driver), used_by: names(o.used_by), managed: o.managed === true, size: numberOr(o.size) })),
    networks: objects(v.networks).map((o) => ({ name: o.name as string, driver: textOf(o.driver), managed: o.managed === true, internal: o.internal === true, used_by: names(o.used_by) })),
    storage: { images: isNumber(storage.images) ? storage.images : 0, containers: isNumber(storage.containers) ? storage.containers : 0, size: numberOr(storage.size) },
    resource_errors: Object.fromEntries(Object.entries(errors).filter((e): e is [string, string] => isText(e[1]))),
  };
}

export async function readContainer(name: string): Promise<ContainerDetail> {
  const v = shaped<Record<string, unknown>>(await getJson(query(YOLLAR.konteyner_ayrintisi, { ad: name })), (d) => isText(d.name));
  const base = row(v);
  const config = (v as KonteynerAyrintisi).config;
  return {
    ...base,
    mounts_detail: isList(v.mounts)
      ? v.mounts.filter((m) => isObject(m)).map((m) => {
          const o = m as Record<string, unknown>;
          return { type: isText(o.type) ? o.type : "", source: isText(o.source) ? o.source : "", destination: isText(o.destination) ? o.destination : "", rw: o.rw !== false, name: isText(o.name) ? o.name : "" };
        })
      : [],
    generic: isGenericConfig(config) ? config : null,
    adapter: isAdapterConfig(config) ? config : null,
    editable: isList(v.editable) ? v.editable.filter(isText) : [],
    protected: protectedMounts(v.protected_mounts),
    effective_autostart: isBool(v.effective_autostart) ? v.effective_autostart : null,
    user: textOf(v.user),
    command: textOf(v.command),
  };
}

/** DD-214: the cached update check of every managed container; `force` asks the registries again (at most
    once a minute on the server). */
export async function readUpdates(force = false): Promise<{ checked_at: number; items: Record<string, Update> }> {
  const v = shaped<Record<string, unknown>>(await getJson(YOLLAR.konteyner_guncellemeleri + (force ? "?yenile=1" : "")), (d) => isNumber(d.checked_at) && isObject(d.items));
  const items: Record<string, Update> = {};
  for (const [name, value] of Object.entries(v.items as Record<string, unknown>)) {
    const u = update(value);
    if (u) items[name] = { ...u, checked_at: u.checked_at ?? (v.checked_at as number) };
  }
  return { checked_at: v.checked_at as number, items };
}

export interface Operation {
  id: string;
  action: string;
  name: string;
  state: "running" | "done" | "failed" | string;
  step: string;
  error: string;
  result: Record<string, unknown> | null;
}

/** An operation's record (GET …/islem?id=): its result once it is done (an adoption preview, an image update). */
export async function readOperation(id: string): Promise<Operation> {
  const v = shaped<Record<string, unknown>>(await getJson(query(YOLLAR.konteyner_isi, { id })), (d) => isText(d.id) && isText(d.state));
  return {
    id: v.id as string,
    action: isText(v.action) ? v.action : "",
    name: isText(v.name) ? v.name : "",
    state: v.state as string,
    step: isText(v.step) ? v.step : "",
    error: isText(v.error) ? v.error : "",
    result: isObject(v.result) ? v.result : null,
  };
}

/** A write (create, save, adopt, a lifecycle action): 202 with the operation's id, followed as a live job. */
export async function startContainerAction(request: Record<string, unknown>): Promise<{ id: string }> {
  return shaped<{ id: string }>(await postJson(YOLLAR.konteyner_islemi, request), (v) => isText(v.id) && v.id !== "");
}

/** The folders the picker offers: the safe roots, or the folders under one of them, with their free space. */
export async function readFolders(path = ""): Promise<Klasorler["items"]> {
  const v = shaped<Klasorler>(await getJson(YOLLAR.klasorler + (path ? "?" + new URLSearchParams({ path }).toString() : "")), (d) => isList(d.items));
  return v.items.filter((i) => isObject(i) && isText(i.path)).map((i) => ({ path: i.path, free: isNumber(i.free) ? i.free : 0 }));
}
