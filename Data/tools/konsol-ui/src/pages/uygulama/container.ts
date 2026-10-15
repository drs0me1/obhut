// The container definition editor's model (DD-211, DD-227; the current Konsol's Podman editor,
// konteynerler.js draftFrom/configOut/problems/changes): a draft of strings the fields edit, the definition
// it becomes, the checks the server makes too (master_container_config.validate, so a refusal is rare), the
// field-by-field changes against the saved definition and what saving them does. Shared by "Bir imajdan"
// (create), the application page's Ayarlar (save) and "Var olanı yönetime al" (adopt).
import type { Account, ConfigEnv, ConfigMount, ConfigPort, ContainerConfig, Inventory, Restart, Scope } from "../../api/podman";

export const SCOPE_TEXT: Record<string, string> = { local: "Yalnız bu sunucu", tailscale: "Tailscale", public: "İnternet (herkese açık)", other: "Belirli adres" };
export const RESTART_TEXT: Record<Restart, string> = { no: "Hayır", "on-failure": "Hata olursa", always: "Her zaman" };
export const USER_TEXT: Record<Account, string> = { downloads: "Dosyalar hesabı (yetkisiz)", image: "İmajın kendi hesabı (çoğunlukla root)" };
export const ACCOUNT_RULE = "Sunucu klasörüne yalnız Dosyalar hesabıyla yazılabilir: hesabı değiştirin ya da klasörü salt okunur yapın.";
export const PUBLIC_RISK = "İnternete açık port Konsol oturumunu ve Caddy'nin HTTPS'ini atlar; erişimi yalnız uygulamanın kendi girişi korur.";
/** The logical managed bridge: the server creates the configured Konsol network on first use. */
export const DEFAULT_NETWORK = "bridge";

export const NAME_RE = /^[a-z][a-z0-9-]{1,30}$/;
// A full reference: registry (a dot, a port or localhost), repository and a tag or a digest.
export const IMAGE_RE = /^(localhost|[a-z0-9-]+(\.[a-z0-9-]+)+)(:[0-9]{1,5})?\/[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[0-9a-f]{64})$/;
const VOLUME_RE = /^[a-z0-9][a-z0-9_.-]{0,62}$/;
const ENV_RE = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/;
const PATH_RE = /^\/[A-Za-z0-9_./ -]+$/;
const CPUS_RE = /^[0-9]{1,3}(\.[0-9]{1,3})?$/;
const MEMORY_RE = /^[1-9][0-9]{0,8}[kKmMgG]?$/;

export type DraftScope = Scope | "";

export interface PortDraft {
  key: number;
  scope: DraftScope;
  host: string;
  inner: string;
  protocol: "tcp" | "udp";
  ack: boolean;
  /** Already public in the saved definition: no new acknowledgement. */
  wasPublic: boolean;
  /** Adoption: the scope the container has now ("" otherwise). */
  current: string;
}

export interface MountDraft {
  key: number;
  type: "volume" | "bind";
  source: string;
  destination: string;
  readOnly: boolean;
}

export interface EnvDraft {
  key: number;
  name: string;
  value: string;
  secret: boolean;
  /** A secret whose value is stored on the server (never sent here): blank keeps it. */
  stored: boolean;
}

export interface Draft {
  name: string;
  /** The pinned reference of the saved definition, sent back unchanged while the tag is. */
  image: string;
  imageRef: string;
  network: string;
  ports: PortDraft[];
  mounts: MountDraft[];
  env: EnvDraft[];
  command: string;
  autostart: boolean;
  restart: Restart;
  cpus: string;
  memory: string;
  user: Account;
}

let next = 1;
export const rowKey = () => next++;

export function newPort(): PortDraft {
  return { key: rowKey(), scope: "local", host: "", inner: "", protocol: "tcp", ack: false, wasPublic: false, current: "" };
}

export function newMount(): MountDraft {
  return { key: rowKey(), type: "volume", source: "", destination: "", readOnly: false };
}

export function newEnv(): EnvDraft {
  return { key: rowKey(), name: "", value: "", secret: false, stored: false };
}

const RESTARTS = new Set<Restart>(["no", "on-failure", "always"]);

export function draftFrom(cfg: Partial<ContainerConfig>): Draft {
  return {
    name: cfg.name ?? "",
    image: cfg.image ?? "",
    imageRef: cfg.image_ref || cfg.image || "",
    network: cfg.network ?? DEFAULT_NETWORK,
    ports: (cfg.ports ?? []).map((p) => ({
      key: rowKey(),
      scope: p.scope,
      host: p.host_port != null ? String(p.host_port) : "",
      inner: p.container_port != null ? String(p.container_port) : "",
      protocol: p.protocol === "udp" ? "udp" : "tcp",
      ack: Boolean(p.public_ack),
      wasPublic: p.scope === "public",
      current: "",
    })),
    mounts: (cfg.mounts ?? []).map((m) => ({ key: rowKey(), type: m.type === "bind" ? "bind" : "volume", source: m.source ?? "", destination: m.destination ?? "", readOnly: Boolean(m.read_only) })),
    env: (cfg.environment ?? []).map((e) =>
      e.secret ? { key: rowKey(), name: e.name ?? "", value: "", secret: true, stored: Boolean(e.present) } : { key: rowKey(), name: e.name ?? "", value: e.value ?? "", secret: false, stored: false },
    ),
    command: Array.isArray(cfg.command) ? cfg.command.join("\n") : "",
    autostart: cfg.autostart !== false,
    restart: cfg.restart && RESTARTS.has(cfg.restart) ? cfg.restart : "on-failure",
    cpus: cfg.cpus ?? "",
    memory: cfg.memory ?? "",
    user: cfg.user === "downloads" ? "downloads" : "image",
  };
}

/** A new definition: least privilege (the Files account), the managed bridge, started at boot. */
export function emptyDraft(): Draft {
  return { ...draftFrom({}), network: DEFAULT_NETWORK, autostart: true, restart: "on-failure", user: "downloads" };
}

const commandOf = (text: string) => text.split("\n").map((s) => s.trim()).filter(Boolean);

export function portsOut(ports: PortDraft[]): ConfigPort[] {
  return ports.map((p) => ({
    scope: (p.scope || "local") as Scope,
    host_port: Number(p.host.trim()),
    container_port: Number(p.inner.trim()),
    protocol: p.protocol,
    public_ack: p.scope === "public" && (p.ack || p.wasPublic),
  }));
}

/** The definition the draft stands for. An unchanged tag sends the saved pinned reference back; an unchanged
    secret goes without a value, so the server keeps it. */
export function configOut(d: Draft, orig: ContainerConfig | null): ContainerConfig {
  const ref = d.imageRef.trim();
  const imageChanged = !orig || ref !== (orig.image_ref || orig.image || "");
  return {
    name: d.name.trim(),
    image: imageChanged ? ref : d.image,
    image_ref: ref,
    network: d.network,
    ports: portsOut(d.ports),
    mounts: d.mounts.map((m): ConfigMount => ({ type: m.type, source: m.source.trim(), destination: m.destination.trim(), read_only: m.readOnly })),
    environment: d.env.map((e): ConfigEnv =>
      e.secret ? (e.value !== "" ? { name: e.name.trim(), value: e.value, secret: true } : { name: e.name.trim(), secret: true }) : { name: e.name.trim(), value: e.value, secret: false },
    ),
    command: commandOf(d.command),
    autostart: d.autostart,
    restart: d.restart,
    cpus: d.cpus.trim(),
    memory: d.memory.trim(),
    user: d.user,
  };
}

export interface NetworkChoice {
  value: string;
  label: string;
}

export const networkLabel = (v: string) => (v === DEFAULT_NETWORK ? "Varsayılan Konsol ağı" : v === "none" ? "Ağ yok" : v || "—");

/** The logical default and Konsol's managed bridges; the saved network stays offered when it is not listed,
    so an unrelated edit never changes it silently. Podman's own "podman" network is not offered. */
export function networkChoices(inventory: Pick<Inventory, "networks"> | null, keep = ""): NetworkChoice[] {
  const out: NetworkChoice[] = [{ value: DEFAULT_NETWORK, label: networkLabel(DEFAULT_NETWORK) }];
  for (const n of inventory?.networks ?? []) {
    if (n.driver === "bridge" && n.managed && n.name !== DEFAULT_NETWORK) out.push({ value: n.name, label: n.name + (n.internal ? " (iç ağ)" : "") });
  }
  if (keep && !out.some((c) => c.value === keep)) out.push({ value: keep, label: `${networkLabel(keep)} (şu anki)` });
  return out;
}

export const writesFolder = (d: Pick<Draft, "mounts">) => d.mounts.some((m) => m.type === "bind" && !m.readOnly);

const validPort = (text: string) => /^\d{1,5}$/.test(text.trim()) && Number(text) >= 1 && Number(text) <= 65535;
const validPath = (text: string) => PATH_RE.test(text) && !text.split("/").includes("..") && text !== "/";

export type Problems = Record<string, string>;

export interface CheckContext {
  create: boolean;
  /** Whether a field may change (create: all). */
  editable: (field: string) => boolean;
  /** Names already used by containers on this server. */
  taken: ReadonlySet<string>;
  networks: readonly NetworkChoice[];
  /** Named volumes on this server; null while the list is unread. The worker mounts only an existing
      volume (it creates none), so another name is refused here. */
  volumes: ReadonlySet<string> | null;
}

/** Each field's first problem, by key: name, image, network, user, cpus, memory, command, p<key>, m<key>, e<key>. */
export function problems(d: Draft, ctx: CheckContext): Problems {
  const out: Problems = {};
  const add = (key: string, text: string) => {
    if (!out[key]) out[key] = text;
  };
  if (ctx.create) {
    const name = d.name.trim();
    if (!NAME_RE.test(name)) add("name", "Ad küçük harfle başlar; küçük harf, rakam ve - içerir (2–31 karakter).");
    else if (ctx.taken.has(name)) add("name", "Bu ad kullanılıyor.");
  }
  if ((ctx.create || ctx.editable("image")) && !IMAGE_RE.test(d.imageRef.trim())) {
    add("image", "İmajın tam adını yazın: kayıt adresi, depo ve etiket (ör. docker.io/library/nginx:1.27-alpine).");
  }
  if (ctx.editable("network") && !ctx.networks.some((c) => c.value === d.network)) add("network", "Bir ağ seçin.");
  if (d.network === "none" && d.ports.length) add("network", "Ağsız konteyner port yayımlayamaz.");
  if (d.user !== "downloads" && writesFolder(d)) add("user", ACCOUNT_RULE);
  const seen = new Set<string>();
  for (const p of d.ports) {
    const key = "p" + p.key;
    if (!p.scope) add(key, "Erişimi seçin.");
    if (!validPort(p.host) || !validPort(p.inner)) add(key, "Portlar 1–65535 arasında bir sayı olmalı.");
    const id = `${Number(p.host)}/${p.protocol}`;
    if (validPort(p.host) && seen.has(id)) add(key, "Bu sunucu portu bu protokolle iki kez var.");
    seen.add(id);
    if (p.scope === "public" && !p.ack && !p.wasPublic) add(key, "İnternete açık port için onay kutusunu işaretleyin.");
  }
  const targets = new Set<string>();
  for (const m of d.mounts) {
    const key = "m" + m.key;
    const source = m.source.trim();
    const target = m.destination.trim();
    if (m.type === "volume" && !VOLUME_RE.test(source)) add(key, "Birim adı küçük harf ya da rakamla başlar; küçük harf, rakam ve - _ . içerir.");
    else if (m.type === "volume" && ctx.volumes && !ctx.volumes.has(source)) add(key, "Bu birim yok; önce Gelişmiş → Podman → Birimler'de oluşturun.");
    if (m.type === "bind" && !validPath(source)) add(key, "Sunucu klasörünü seçin.");
    if (!validPath(target)) add(key, "Konteynerdeki yol / ile başlar; harf, rakam, boşluk ve . _ - / içerir.");
    else if (targets.has(target)) add(key, "Bu konteyner yolu iki kez var.");
    targets.add(target);
  }
  const names = new Set<string>();
  for (const e of d.env) {
    const key = "e" + e.key;
    const name = e.name.trim();
    if (!ENV_RE.test(name)) add(key, "Değişken adı harf ya da _ ile başlar; harf, rakam ve _ içerir.");
    else if (names.has(name)) add(key, "Bu ad iki kez var.");
    names.add(name);
  }
  if (commandOf(d.command).length > 128) add("command", "Komut en çok 128 argüman olabilir.");
  const cpus = d.cpus.trim();
  if (cpus && (!CPUS_RE.test(cpus) || Number(cpus) <= 0 || Number(cpus) > 256)) add("cpus", "İşlemci sınırı bir sayı olmalı (ör. 1.5; en çok 256).");
  if (d.memory.trim() && !MEMORY_RE.test(d.memory.trim())) add("memory", "Bellek sınırı sayı ve birim olmalı (ör. 512m, 2g).");
  return out;
}

// ---- the review: what changes and what saving does
export interface Change {
  kind: "add" | "del" | "chg";
  field: string;
  before: string;
  after: string;
}

const portText = (p: ConfigPort) => `${SCOPE_TEXT[p.scope] ?? p.scope} · ${p.host_port} → ${p.container_port}/${p.protocol}`;
const mountText = (m: ConfigMount) => `${m.type === "volume" ? "birim" : "klasör"} ${m.source} → ${m.destination}${m.read_only ? " (salt okunur)" : ""}`;
const envText = (e: ConfigEnv) => (e.secret ? `${e.name} (gizli${"value" in e && e.value !== undefined ? ", yeni değer" : ""})` : `${e.name}=${e.value ?? ""}`);
const limit = (v: string | undefined, unit = "") => (v ? v + unit : "sınırsız");

/** The new definition, one row per field; against a saved one, what is added, removed or changed. */
export function changes(orig: ContainerConfig | null, next: ContainerConfig): Change[] {
  const out: Change[] = [];
  const add = (field: string, after: string) => out.push({ kind: "add", field, before: "", after });
  if (!orig) {
    add("Ad", next.name);
    add("İmaj", next.image_ref ?? next.image);
    add("Ağ", networkLabel(next.network));
    next.ports.forEach((p) => add("Port", portText(p)));
    next.mounts.forEach((m) => add("Bağlama", mountText(m)));
    next.environment.forEach((e) => add("Ortam", envText(e)));
    if (next.command.length) add("Komut", next.command.join(" "));
    add("Başlatma", `${next.autostart ? "açılışta başlar" : "açılışta başlamaz"} · yeniden başlatma: ${RESTART_TEXT[next.restart]}`);
    if (next.cpus) add("İşlemci sınırı", next.cpus + " çekirdek");
    if (next.memory) add("Bellek sınırı", next.memory);
    add("Hesap", USER_TEXT[next.user ?? "downloads"]);
    return out;
  }
  const list = <T>(a: T[], b: T[], text: (x: T) => string, field: string) => {
    const before = new Set(a.map(text));
    const after = new Set(b.map(text));
    for (const t of before) if (!after.has(t)) out.push({ kind: "del", field, before: t, after: "" });
    for (const t of after) if (!before.has(t)) add(field, t);
  };
  const chg = (field: string, before: string, after: string) => {
    if (before !== after) out.push({ kind: "chg", field, before, after });
  };
  chg("İmaj", orig.image_ref || orig.image, next.image_ref ?? next.image);
  chg("Ağ", networkLabel(orig.network), networkLabel(next.network));
  list(orig.ports ?? [], next.ports, portText, "Port");
  list(orig.mounts ?? [], next.mounts, mountText, "Bağlama");
  const saved = (orig.environment ?? []).map((e): ConfigEnv => (e.secret ? { name: e.name, secret: true } : { name: e.name, value: e.value ?? "", secret: false }));
  list(saved, next.environment, envText, "Ortam");
  chg("Komut", (orig.command ?? []).join(" ") || "imajın komutu", next.command.join(" ") || "imajın komutu");
  chg("Açılışta", orig.autostart !== false ? "başlar" : "başlamaz", next.autostart ? "başlar" : "başlamaz");
  chg("Yeniden başlatma", RESTART_TEXT[orig.restart] ?? orig.restart, RESTART_TEXT[next.restart]);
  chg("İşlemci sınırı", limit(orig.cpus, " çekirdek"), limit(next.cpus, " çekirdek"));
  chg("Bellek sınırı", limit(orig.memory), limit(next.memory));
  chg("Hesap", USER_TEXT[orig.user ?? "image"], USER_TEXT[next.user ?? "image"]);
  return out;
}

export interface Consequence {
  tone: "info" | "ok" | "warn" | "bad";
  text: string;
}

/** What saving does (DD-211: every generic save re-creates a running container). */
export function consequences(mode: "create" | "save", running: boolean, list: Change[], next: Pick<ContainerConfig, "user">): Consequence[] {
  const out: Consequence[] = [];
  if (mode === "create") out.push({ tone: "info", text: "İmaj çekilir ve özete sabitlenir; tanım Konsol'a kaydedilir ve systemd hizmeti yazılır." });
  else if (!running) out.push({ tone: "ok", text: "Konteyner durmuş olduğu için kesinti olmaz: tanım kaydedilir, başlattığınızda yeni ayarlarla yeniden oluşturulur." });
  else {
    out.push({ tone: "warn", text: "Çalışan konteyner durdurulup yeni ayarlarla yeniden oluşturulur; bu sırada hizmet kısa süre kesilir." });
    out.push({ tone: "bad", text: "Konteynerin yazılabilir katmanı silinir; kalıcı veriler yalnız bağlamalarda durur." });
  }
  if (mode === "save" && list.some((c) => c.field === "Bağlama")) out.push({ tone: "warn", text: "Bağlama değişikliği dosya taşımaz; eski klasör ya da birim olduğu gibi kalır." });
  if (list.some((c) => c.kind === "add" && c.field === "Port" && c.after.startsWith(SCOPE_TEXT.public ?? ""))) out.push({ tone: "bad", text: PUBLIC_RISK });
  if (next.user === "downloads" && list.some((c) => c.field === "Hesap" && c.kind === "chg")) {
    out.push({ tone: "warn", text: "Önceden kullanılmış bir birim sahibini korur; Dosyalar hesabı ona yazamayabilir. Root gerektiren ya da 1024 altında port açan imajlar başlamayabilir." });
  }
  return out;
}
