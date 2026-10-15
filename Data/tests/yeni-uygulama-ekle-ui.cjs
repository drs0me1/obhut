/* Konsol's new interface, phase 4a (DD-258): Uygulamalar' add flows (the catalogue with a package's install
   form, a container from an image, adopting a container made outside Konsol) and the application page's
   container views and settings (Özet, Erişim's ports, Depolama, Ayarlar: a Konsol definition, an App Store
   adapter, a package's settings form and first-login account; Günlük's tail and search; the image update) in
   the committed build under Data/console/yeni, with the production CSP and fixture replies for every endpoint
   they read or post to (yeni-harness.cjs). Fails on any console error, CSP violation or page error. Never
   contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulama-ekle-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737 addresses, example names); shapes as in api/sema.ts
const NOW = 1791845000;
const cell = (durum, adresler = [], uyari = "", not = "") => ({ durum, adresler, uyari, not });
const app = (o) => ({ modul: null, konteyner: null, simge: null, durum: "calisiyor", islem: null, tailscale: cell("yok"), internet: cell("yok"),
  kaynak: { cpu: null, bellek: null }, guncelleme: "sabit", adres: { tailscale: null, internet: null }, sayfa: null, eylemler: [], revizyon: null,
  metinler: null, ...o });
const SHA = (c) => c.repeat(64);

const TORRENT_FORM = {
  kur_baslik: "qBittorrent'i kur", kur_alt: "Web arayüzü hesabı ve indirme klasörü", kur_not: "Kurulum bu bilgilerle başlar. Parola sunucuda yalnız özet olarak saklanır.",
  ayar_baslik: "qBittorrent ayarları", ayar_alt: "Web arayüzü hesabı ve indirme klasörü",
  ayar_not: "Doğrudan kaydedilir; çalışıyorsa qBittorrent kısa süre yeniden başlar. Mevcut indirmeler taşınmaz.", oku: "/durum", yaz: "/ayar",
  alanlar: [
    { ad: "username", tur: "metin", etiket: "Kullanıcı adı", varsayilan: "admin", desen: "[A-Za-z0-9._@\\-]{1,64}", en_cok: 64, ipucu: "Harf, rakam ve . _ @ - kullanılabilir." },
    { ad: "password", tur: "parola", etiket: "Parola", en_az: 8, en_cok: 256, ipucu: "En az 8 karakter.", ayar_ipucu: "Boş bırakılırsa kayıtlı parola korunur." },
    // An unrendered default (the installer fills it in) counts as none: the folder must be chosen.
    { ad: "save", tur: "klasor", etiket: "İndirme klasörü", varsayilan: "__DOWNLOADS_PATH__", ipucu: "İndirmeler ya da kütüphane altında." },
  ] };
const TORRENT_KONSOL = { ad: "qBittorrent", alt: "Torrent indirmelerini yönetin.", simge: "download",
  aciklama: "Sunucudaki Podman'da konteyner olarak çalışır. Kurulumda seçtiğiniz hesap ve indirme klasörüyle başlar.",
  neler: [["box", "linuxserver/qbittorrent imajı 5.1.2, özetiyle sabit"], ["globe", "torrent.ev adı eklenir (arayüz yalnız sunucuda dinler)"], ["nope", "Eş portu yalnız WAN IPv4 adresinde açılır"]],
  notlar: ["Podman konteyneri · qbittorrent", "arayüz yalnız sunucu"], form: TORRENT_FORM };
const WG_KONSOL = { ad: "WireGuard", alt: "Cihazlarınız için VPN bağlantısı.", simge: "shield", aciklama: "Çekirdek WireGuard katmanını kurar.",
  neler: [["box", "Paketler: wireguard-tools, qrencode"]], notlar: ["Debian paketleri + Konsol sayfası"] };
const GEZGIN_KONSOL = { ad: "Gezgin", alt: "Sunucudaki dosyalarınızı tarayıcıdan yönetin.", simge: "folder",
  form: { kur_baslik: "Gezgin'i kur", alanlar: [{ ad: "username", tur: "metin", etiket: "Kullanıcı adı", varsayilan: "yonetici" }] } };
const pkg = (id, installed, konsol, o = {}) => ({ id, runtime: "konteyner", installed, state: installed ? "calisiyor" : "", live: installed ? "running" : "", busy: false,
  progress: null, durdurulabilir: true, konsol, ...o });

const APPS = {
  gezgin: app({ id: "paket:gezgin", ad: "Gezgin", tur: "paket", aciklama: "Sunucudaki dosyalarınızı tarayıcıdan yönetin.", modul: "gezgin", konteyner: "gezgin", simge: "folder",
    eylemler: ["durdur", "yeniden-baslat", "kaldir"], revizyon: "rev-gezgin-1" }),
  torrent: app({ id: "paket:torrent", ad: "qBittorrent", tur: "paket", aciklama: "Torrent indirmelerini yönetin.", modul: "torrent", konteyner: "torrent", simge: "download",
    tailscale: cell("acik", ["torrent.ev"]), adres: { tailscale: "http://torrent.ev", internet: null }, eylemler: ["durdur", "yeniden-baslat", "kaldir"], revizyon: "rev-torrent-7" }),
  web: app({ id: "konteyner:web", ad: "web", tur: "konteyner", aciklama: "Konteyner · docker.io/library/nginx", konteyner: "web", kaynak: { cpu: 4.2, bellek: 41943040 },
    tailscale: cell("acik", ["web.ev"]), internet: cell("acik", ["203.0.113.10:8443/tcp"]), guncelleme: "yeni", eylemler: ["durdur", "yeniden-baslat", "guncelle", "kaldir"], revizyon: "rev-web-1" }),
  notlar: app({ id: "konteyner:notlar", ad: "notlar", tur: "konteyner", aciklama: "Konteyner · docker.io/library/nginx", konteyner: "notlar", durum: "durduruldu",
    guncelleme: "guncel", eylemler: ["baslat", "kaldir"], revizyon: "rev-notlar-1" }),
  medya: app({ id: "konteyner:medya", ad: "medya", tur: "konteyner", aciklama: "Konsol dışında yönetilen konteyner · docker.io/example/medya", konteyner: "medya",
    eylemler: ["durdur", "yeniden-baslat", "kaldir"] }),
  paylasim: app({ id: "yerlesik:paylasim", ad: "Paylaşımlar", tur: "yerlesik", aciklama: "WebDAV · yerleşik", sayfa: "#/dosyalar/paylasim" }),
};

const crow = (o) => ({ id: "", image: "", state: "running", unit: "", network: "", ports: [], started: null, restarts: 0, health: "", live: true, source: "konsol",
  module_id: null, revision: null, actions: [], restricted_reason: "", cpu_percent: null, memory_bytes: null, busy: null, listening: null, update: null, mounts: 0, ...o });
const WEB_CONFIG = { schema: 1, name: "web", image: "docker.io/library/nginx@sha256:" + SHA("c"), image_ref: "docker.io/library/nginx:1.27-alpine", network: "bridge",
  ports: [{ scope: "local", host_port: 8088, container_port: 80, protocol: "tcp", public_ack: false }, { scope: "public", host_port: 8443, container_port: 443, protocol: "tcp", public_ack: true }],
  mounts: [{ type: "volume", source: "web-veri", destination: "/usr/share/nginx/html", read_only: false }],
  environment: [{ name: "TZ", value: "Europe/Istanbul", secret: false }, { name: "API_TOKEN", secret: true, present: true }, { name: "ESKI", value: "1", secret: false }],
  command: ["nginx", "-g", "daemon off;"], autostart: true, manual_stop: false, restart: "on-failure", cpus: "1.5", memory: "512m", pids_limit: "", user: "downloads", revision: "rev-web-1" };
const EDITABLE = ["ports", "mounts", "environment", "command", "autostart", "restart", "cpus", "memory", "image", "network", "user"];
function containers() {
  return {
    web: crow({ name: "web", id: "0a1b2c3d4e5f", image: WEB_CONFIG.image, unit: "konsol-web.service", network: "konsol", revision: "rev-web-1", health: "unhealthy", restarts: 3,
      started: NOW - 7200, cpu_percent: 4.2, memory_bytes: 41943040, actions: ["stop", "restart", "save", "remove", "image-update"],
      ports: [{ host_ip: "127.0.0.1", host_port: 8088, container_port: 80, protocol: "tcp", scope: "local" }, { host_ip: "0.0.0.0", host_port: 8443, container_port: 443, protocol: "tcp", scope: "public" }],
      update: { state: "var", channel: "docker.io/library/nginx:1.27-alpine", error: "", checked_at: NOW - 600 },
      config: WEB_CONFIG, editable: EDITABLE, protected_mounts: [], effective_autostart: true, user: "1000:1000", command: "nginx -g daemon off;",
      mounts: [{ type: "volume", source: "/var/lib/containers/storage/volumes/web-veri/_data", destination: "/usr/share/nginx/html", rw: true, name: "web-veri" }] }),
    notlar: crow({ name: "notlar", image: "docker.io/library/nginx@sha256:" + SHA("d"), state: "stopped", live: false, unit: "konsol-notlar.service", network: "bridge",
      revision: "rev-notlar-1", actions: ["start", "save", "remove", "image-update"], update: { state: "guncel", channel: "docker.io/library/nginx:1.27", error: "", checked_at: NOW - 600 },
      config: { schema: 1, name: "notlar", image: "docker.io/library/nginx@sha256:" + SHA("d"), image_ref: "docker.io/library/nginx:1.27", network: "bridge", ports: [], mounts: [],
        environment: [], command: [], autostart: true, manual_stop: true, restart: "always", cpus: "", memory: "", user: "image", revision: "rev-notlar-1" },
      editable: EDITABLE, protected_mounts: [], effective_autostart: false, user: "", command: "", mounts: [] }),
    medya: crow({ name: "medya", id: "9f8e7d6c5b4a", image: "docker.io/example/medya:10.9", network: "host", source: "external", actions: ["stop", "restart", "remove", "adopt"],
      listening: [{ address: "0.0.0.0", port: 8096, protocol: "tcp", scope: "all" }, { address: "100.64.0.2", port: 1900, protocol: "udp", scope: "tailscale" }],
      user: "", command: "/jellyfin/jellyfin", mounts: [{ type: "bind", source: "/srv/medya", destination: "/media", rw: true, name: "" }] }),
    eski: crow({ name: "eski", image: "docker.io/example/eski:1", state: "exited", source: "external", actions: [],
      restricted_reason: "Konteyner başka bir yöneticiye ait veya desteklenmeyen seçenekler kullanıyor." }),
    garip: crow({ name: "garip", image: "docker.io/example/garip:2", source: "external", actions: ["stop", "restart", "remove", "adopt"] }),
    torrent: crow({ name: "torrent", id: "a1b2c3d4e5f6", image: "lscr.io/linuxserver/qbittorrent@sha256:" + SHA("a"), unit: "torrent.service", network: "torrent",
      source: "appstore", module_id: "torrent", revision: "rev-torrent-7", actions: ["stop", "restart", "remove", "image-update", "save"],
      ports: [{ host_ip: "127.0.0.1", host_port: 62947, container_port: 62947, protocol: "tcp", scope: "local" }, { host_ip: "203.0.113.10", host_port: 63851, container_port: 63851, protocol: "tcp", scope: "public" }],
      config: { listener_port: 62947, peer_port: 63851, save: "/srv/indirilenler" }, editable: ["listener_port", "peer_port", "save"],
      protected_mounts: [{ source: "/var/lib/qbittorrent", target: "/config", destination: "/config", reason: "Uygulama profili; taşıma ayrı bir işlemdir." },
        { source: "/srv/indirilenler", target: "/srv/indirilenler", destination: "/srv/indirilenler", reason: "Uygulamanın indirme kökü." }],
      effective_autostart: true, user: "1000:1000", command: "",
      mounts: [{ type: "bind", source: "/var/lib/qbittorrent", destination: "/config", rw: true, name: "" }, { type: "bind", source: "/srv/indirilenler", destination: "/srv/indirilenler", rw: true, name: "" }] }),
    gezgin: crow({ name: "gezgin", image: "ghcr.io/example/gezgin@sha256:" + SHA("b"), unit: "gezgin.service", network: "gezgin", source: "appstore", module_id: "gezgin",
      revision: "rev-gezgin-1", actions: ["stop", "restart", "remove", "image-update"], config: { listener_port: 62983 }, editable: [], protected_mounts: [], effective_autostart: true }),
  };
}
let CONTAINERS = containers();
const box = (name) => {
  const c = CONTAINERS[name];
  if (!c) return null;
  return { imaj: c.image, ag: c.network, kullanici: c.user, baslangic: c.started, saglik: c.health, yeniden_baslama: c.restarts,
    portlar: c.ports, baglamalar: (Array.isArray(c.mounts) ? c.mounts : []).map((m) => ({ tur: m.type, kaynak: m.source, hedef: m.destination, yazilabilir: m.rw, ad: m.name })) };
};
const listRow = (c) => ({ ...c, mounts: Array.isArray(c.mounts) ? c.mounts.length : 0, config: undefined, editable: undefined, protected_mounts: undefined });
const inventory = () => ({ read_at: NOW, runtime: { version: "5.4.2", ok: true, error: "" }, containers: Object.values(CONTAINERS).map(listRow),
  images: [{ id: "sha256:" + SHA("c"), name: "docker.io/library/nginx:1.27-alpine", size: 52428800, created: NOW - 86400, used_by: ["web"], managed: true, pinned: false }],
  volumes: [{ name: "web-veri", driver: "local", size: null, used_by: ["web"], managed: true }, { name: "bos-veri", driver: "local", size: null, used_by: [], managed: true }],
  networks: [{ name: "konsol", id: "n1", driver: "bridge", subnets: ["10.89.0.0/24"], used_by: ["web"], managed: true, internal: false },
    { name: "arka", id: "n2", driver: "bridge", subnets: ["10.89.1.0/24"], used_by: [], managed: true, internal: true },
    { name: "podman", id: "n0", driver: "bridge", subnets: ["10.88.0.0/16"], used_by: [], managed: false, internal: false }],
  storage: { images: 1, containers: 6, size: 1610612736 }, resource_errors: {} });

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-250", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, interval: 10, read_at: NOW, sampled_at: NOW, cpu: [1.0], mem: { total: 8375186227, used: 696254464, graph: [8.0] },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "ok", read_at: NOW, checks: [{ id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  guncelleme: { kurulu: "2026.08.06-v2-250", kurulu_surum: "1.0.0", son: "2026.08.06-v2-250", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false,
    denetlendi: NOW, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: NOW, alan: "ev", hizmetler: [], hatalar: [], uyarilar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null }, internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] },
      wireguard: { kurulu: false, not: "", aglar: [] }, sertifikalar: [] } },
  uygulamalar: null,
  // Genel Bakış (the palette starts there).
  ag: { read_at: NOW, iface: "eth0", window: 600, sampled_at: NOW, rx: 1024, tx: 2048, points: [], apps: [] },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
};
function setApps(ids, katalog) {
  data.uygulamalar = { read_at: NOW, hatalar: [], katalog, altyapi: { podman: "5.4.2", calisiyor: true, imaj: 1, kullanilmayan_imaj: 0, birim: 2, ag: 3 },
    items: ids.map((id) => APPS[id]).filter(Boolean) };
}
const CATALOGUE = [{ id: "torrent", ad: "qBittorrent", aciklama: "Torrent indirmelerini yönetin.", simge: "download" }, { id: "wireguard", ad: "WireGuard", aciklama: "Cihazlarınız için VPN bağlantısı.", simge: "shield" }];
setApps(["gezgin", "web", "notlar", "medya", "paylasim"], CATALOGUE);
let PACKAGES = [pkg("torrent", false, TORRENT_KONSOL), pkg("wireguard", false, WG_KONSOL), pkg("gezgin", true, GEZGIN_KONSOL)];

const FOLDERS = {
  "": [{ path: "/srv/indirilenler", free: 255550000000 }, { path: "/srv/kitaplik", free: 255550000000 }],
  "/srv/indirilenler": [{ path: "/srv/indirilenler/filmler", free: 255550000000 }, { path: "/srv/indirilenler/diziler", free: 255550000000 }],
  "/srv/kitaplik": [],
};
const LOG = ["2026-10-13T01:10:00+03:00 web[812]: başladı", "2026-10-13T01:11:00+03:00 web[812]: HATA: yukarı akış yanıt vermedi", "2026-10-13T01:12:00+03:00 web[812]: istek tamam",
  "2026-10-13T01:13:00+03:00 web[812]: İkinci hata: İstanbul saat dilimi"];

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-uygulama-ekle-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8774", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies
const replies = { islem: [], konteyner: [], ayar: [] };   // forced replies for the next POSTs, before the defaults
const ops = {};                                           // GET …/konteynerler/islem?id= records
let jobSeq = 0;
h.handlers["/api/konsol/moduller"] = () => ({ body: { items: PACKAGES } });
h.handlers["/api/konsol/ayarlar/klasorler"] = ({ query }) => ({ body: { items: FOLDERS[query.get("path") ?? ""] ?? [] } });
h.handlers["/api/konsol/konteynerler/liste"] = () => ({ body: inventory() });
h.handlers["/api/konsol/konteynerler/ayrinti"] = ({ query }) => (CONTAINERS[query.get("ad")] ? { body: CONTAINERS[query.get("ad")] } : { status: 404, body: { error: "Konteyner bulunamadı" } });
h.handlers["/api/konsol/konteynerler/gunluk"] = () => ({ body: { name: "web", lines: LOG, truncated: false } });
h.handlers["/api/konsol/konteynerler/guncellemeler"] = ({ query }) => {
  if (query.get("yenile") === "1") CONTAINERS.web.update = { state: "var", channel: "docker.io/library/nginx:1.27-alpine", error: "", checked_at: NOW + 60 };
  return { body: { checked_at: NOW + 60, items: { web: CONTAINERS.web.update, notlar: CONTAINERS.notlar.update }, cached: query.get("yenile") !== "1" } };
};
h.handlers["/api/konsol/konteynerler/islem"] = ({ method, body, query }) => {
  if (method === "GET") return ops[query.get("id")] ? { body: ops[query.get("id")] } : { status: 404, body: { error: "İşlem bulunamadı; konteyner durumunu yenileyin." } };
  const forced = replies.konteyner.shift();
  if (forced) return forced;
  const id = `is${String(++jobSeq).padStart(30, "0")}`;
  return { status: 202, body: { id, action: body.action, name: body.name ?? body.config?.name, state: "running", step: "Başlatılıyor" } };
};
h.handlers["/api/konsol/uygulamalar/ayrinti"] = ({ query }) => {
  const item = data.uygulamalar.items.find((a) => a.id === query.get("id"));
  if (!item) return { status: 404, body: { error: "Uygulama bulunamadı." } };
  return { body: { uygulama: item, konteyner: item.konteyner ? box(item.konteyner) : null, erisim: null } };
};
h.handlers["/api/konsol/uygulamalar/gunluk"] = ({ query }) => ({ body: { satirlar: LOG, kesik: query.get("satir") === "100" } });
h.handlers["/api/konsol/uygulamalar/islem"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const forced = replies.islem.shift();
  if (forced) return forced;
  const broker = body.id.startsWith("konteyner:") || body.eylem === "guncelle";
  return { status: 202, body: { id: body.id, eylem: body.eylem, is: broker ? `is${String(++jobSeq).padStart(30, "0")}` : null } };
};
let account = { user: "admin", temp: true, host: "torrent.ev" };
h.handlers["/api/konsol/uygulamalar/hesap"] = ({ query }) => {
  if (query.get("id") !== "paket:torrent") return { status: 404, body: { error: "bu modülde hesap yok" } };
  return { body: query.get("parola") === "1" && account.temp ? { ...account, pass: "Gecici-Parola-42" } : account };
};
let torrentSettings = { username: "admin", save: "/srv/indirilenler", profile: "/var/lib/qbittorrent" };
h.dynamic.push([/^\/api\/uygulama\/torrent\/(durum|ayar)$/, (req, m) => {
  if (m[1] === "durum") return { body: torrentSettings };
  const forced = replies.ayar.shift();
  if (forced) return forced;
  if (req.body.username) torrentSettings = { ...torrentSettings, username: req.body.username };
  return { body: { ok: true, username: torrentSettings.username, save: torrentSettings.save } };
}]);

// ---- helpers
const url = (hash) => new URL("/yeni/" + hash, base).href;
const hashOf = (page) => page.evaluate(() => location.hash);
const lastPost = (key) => posts(key).at(-1);
const job = (o) => ({ tur: "konteyner", id: "", ad: "", durum: "calisiyor", adim: "", bitis: null, ...o });
const lastJob = () => `is${String(jobSeq).padStart(30, "0")}`;
const field = (scope, name) => scope.locator(`[data-alan="${name}"]`);
/** A table's rows as their cells' text, "|" between cells (the same on wide screens and as cards). */
const cells = (table) => table.locator("tbody tr").evaluateAll((trs) => trs.map((tr) => [...tr.children].map((c) => c.textContent.trim()).join("|")));
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
const settle = (page) => page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
async function stream() {
  await waitFor(() => h.stream.clients.size >= 1, "event stream");
}
/** Whether the page asks before a reload (useLeaveGuard's beforeunload listener). */
const guarded = (page) => page.evaluate(() => {
  const e = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(e);
  return e.defaultPrevented;
});

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= Uygulamalar: the add card and Podman's counts
    let page = await newPage();
    await page.goto(url("#/uygulamalar"));
    const add = page.getByTestId("add-app");
    await add.getByText("2 uygulama kurulabilir.").waitFor();
    assert.deepEqual(await add.locator(".catalog a").evaluateAll((as) => as.map((a) => [a.textContent, a.getAttribute("href")])),
      [["qBittorrent", "#/uygulamalar?ekle=katalog&paket=torrent"], ["WireGuard", "#/uygulamalar?ekle=katalog&paket=wireguard"]]);
    await add.getByText("Podman'da Konsol dışında kurulmuş 2 konteyner yönetime alınabilir.").waitFor();
    const infra = page.getByTestId("infra");
    assert.equal(await infra.getByTestId("infra-unhealthy").innerText(), "1");
    assert.equal(await infra.getByTestId("infra-updates").innerText(), "1");
    assert.equal(await infra.getByTestId("infra-size").innerText(), "1,5 GB");
    assert.deepEqual(await infra.locator(".infra-links a").evaluateAll((as) => as.map((a) => a.getAttribute("href"))),
      ["#/gelismis?sekme=podman&kaynak=imajlar", "#/gelismis?sekme=podman&kaynak=birimler", "#/gelismis?sekme=podman&kaynak=aglar"]);
    assert.equal(await page.locator('a[href^="/#/moduller"], a[href^="/#/konteynerler"]').count(), 0, "no links to App Store or Podman of the current interface");

    // ================= the catalogue: list, a package's words, its form and its checks
    await add.getByRole("link", { name: "Kataloğu aç" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ekle=katalog");
    let sheet = page.getByRole("dialog", { name: "Katalogdan kur" });
    await sheet.getByTestId("catalog-list").waitFor();
    assert.deepEqual(await sheet.locator(".catalog-item strong").allInnerTexts(), ["qBittorrent", "WireGuard"], "only packages not installed");
    await shot(page, "1440-light-katalog.png");
    await sheet.getByRole("button", { name: "qBittorrent: ayrıntı ve kurulum" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ekle=katalog&paket=torrent");
    sheet = page.getByRole("dialog", { name: "qBittorrent'i kur" });
    await sheet.getByTestId("catalog-desc").waitFor();
    assert.equal(await sheet.locator(".modal-desc").innerText(), "Web arayüzü hesabı ve indirme klasörü");
    assert.deepEqual(await sheet.getByTestId("catalog-will").locator("li").allInnerTexts(), TORRENT_KONSOL.neler.map((p) => p[1]));
    assert.equal(await sheet.getByTestId("catalog-will").locator("svg").count(), 3, "an unknown icon falls back");
    assert.deepEqual(await sheet.getByTestId("catalog-facts").locator(".fact-chip").allInnerTexts(), TORRENT_KONSOL.notlar);
    assert.equal(await sheet.getByTestId("install-note").innerText(), TORRENT_FORM.kur_not);
    const form = sheet.getByTestId("package-form");
    assert.equal(await field(form, "username").inputValue(), "admin", "the declared default");
    assert.equal(await form.getByTestId("folder-value").inputValue(), "", "an unrendered default is no default");
    // Checks on the first submit, the first invalid field focused.
    await sheet.getByTestId("install-go").click();
    await form.getByText("Parolayı yazın.").waitFor();
    await form.getByText("Bir klasör seçin.").waitFor();
    assert(await field(form, "password").evaluate((el) => el === document.activeElement), "the first invalid field has focus");
    assert.equal(posts("uygulamalar/islem").length, 0, "nothing sent");
    await field(form, "username").fill("ad soyad");
    await field(form, "password").fill("kisa");
    await form.getByText("Geçersiz değer. Harf, rakam ve . _ @ - kullanılabilir.").waitFor();
    await form.getByText("En az 8 karakter olmalı.").waitFor();
    await field(form, "password").fill("uzun-parola-1");
    await field(form, "password-tekrar").fill("uzun-parola-2");
    await form.getByText("Parolalar aynı değil.").waitFor();
    await field(form, "password-tekrar").fill("uzun-parola-1");
    await field(form, "username").fill("yonetici");
    // The folder picker: the roots with their free space, into a folder, Esc closes only the picker.
    const toggle = form.getByTestId("folder-toggle");
    await toggle.click();
    const panel = form.getByTestId("folder-panel");
    await panel.locator(".folder-row").first().waitFor();
    assert.equal(await toggle.getAttribute("aria-expanded"), "true");
    assert.deepEqual(await panel.locator(".folder-row").allInnerTexts(), ["/srv/indirilenler\n238,0 GB boş\nİçine gir\nSeç", "/srv/kitaplik\n238,0 GB boş\nİçine gir\nSeç"]);
    await panel.getByRole("button", { name: "/srv/kitaplik içine gir" }).click();
    await panel.getByText("Bu klasörün altında seçilebilir klasör yok.").waitFor();
    assert(await panel.locator(".folder-where").evaluate((el) => el === document.activeElement), "the location has focus after entering");
    await panel.getByTestId("folder-up").click();
    await panel.getByRole("button", { name: "/srv/indirilenler içine gir" }).click();
    await panel.getByRole("button", { name: "/srv/indirilenler/filmler seç" }).waitFor();
    await page.keyboard.press("Escape");
    await panel.waitFor({ state: "detached" });
    assert(await sheet.isVisible(), "Esc closed the picker, not the sheet");
    assert(await toggle.evaluate((el) => el === document.activeElement), "focus back on Klasör seç");
    await toggle.press("Enter");
    await panel.getByRole("button", { name: "/srv/indirilenler içine gir" }).click();
    await panel.getByRole("button", { name: "/srv/indirilenler/filmler seç" }).click();
    assert.equal(await form.getByTestId("folder-value").inputValue(), "/srv/indirilenler/filmler");
    assert.deepEqual(h.requests.filter((r) => r.path === "/api/konsol/ayarlar/klasorler").map((r) => r.query),
      ["", "?path=%2Fsrv%2Fkitaplik", "", "?path=%2Fsrv%2Findirilenler", "", "?path=%2Fsrv%2Findirilenler"]);
    assert(await guarded(page), "a typed draft asks before a reload");
    await noStyles(page, "katalog formu");
    await shot(page, "1440-light-katalog-form.png");
    // A refusal stays in the sheet, in the server's words; the draft stays.
    expectedFailures = ["/api/konsol/uygulamalar/islem"];
    replies.islem.push({ status: 400, body: { error: "Kurulum bilgileri doğrulanamadı: parola çok yaygın." } });
    await sheet.getByTestId("install-go").click();
    await sheet.getByTestId("install-error").filter({ hasText: "Kurulum bilgileri doğrulanamadı: parola çok yaygın." }).waitFor();
    assert.equal(await field(form, "password").inputValue(), "uzun-parola-1", "the draft stays after a refusal");
    expectedFailures = [];
    // An earlier failed install of the same package is still listed: it is not this one's end.
    await stream();
    push("islemler", { items: [job({ tur: "modul", id: "torrent", ad: "qBittorrent · Kur", durum: "hata", adim: "eski hata", bitis: NOW - 30 })] });
    await sheet.getByTestId("install-go").click();
    await sheet.getByTestId("install-progress").waitFor();
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "paket:torrent", eylem: "kur", form: { username: "yonetici", password: "uzun-parola-1", save: "/srv/indirilenler/filmler" } });
    await page.waitForTimeout(150);
    assert.equal(await sheet.getByTestId("install-error").count(), 0, "the old failure is not this install's end");
    push("islemler", { items: [job({ tur: "modul", id: "torrent", ad: "qBittorrent · Kur", adim: "Adım 2/4 · İmaj indiriliyor" })] });
    await sheet.getByTestId("install-step").filter({ hasText: "Adım 2/4 · İmaj indiriliyor" }).waitFor();
    await shot(page, "1440-light-katalog-kuruluyor.png");
    // Installed: the application's page opens.
    PACKAGES = [pkg("torrent", true, TORRENT_KONSOL), pkg("wireguard", false, WG_KONSOL), pkg("gezgin", true, GEZGIN_KONSOL)];
    setApps(["gezgin", "torrent", "web", "notlar", "medya", "paylasim"], [CATALOGUE[1]]);
    push("islemler", { items: [job({ tur: "modul", id: "torrent", ad: "qBittorrent · Kur", durum: "tamam", bitis: NOW + 60 })] });
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent");
    await page.locator("main h1").filter({ hasText: "qBittorrent" }).waitFor();
    assert.equal(await guarded(page), false, "nothing left to ask about");

    // A package without a form: Kur at once; a failed job says why and offers to try again.
    await page.goto(url("#/uygulamalar?ekle=katalog&paket=wireguard"));
    sheet = page.getByRole("dialog", { name: "WireGuard kurulsun mu?" });
    await sheet.getByText("Kurulum bilgi istemez; Kur ile hemen başlar.").waitFor();
    await sheet.getByTestId("install-go").click();
    await sheet.getByTestId("install-progress").waitFor();
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "paket:wireguard", eylem: "kur" }, "no form without a declaration");
    push("islemler", { items: [job({ tur: "modul", id: "wireguard", ad: "WireGuard · Kur", adim: "Adım 1/3 · Paketler" })] });
    await sheet.getByTestId("install-step").filter({ hasText: "Adım 1/3 · Paketler" }).waitFor();
    push("islemler", { items: [job({ tur: "modul", id: "wireguard", ad: "WireGuard · Kur", durum: "hata", adim: "apt-get başarısız", bitis: NOW + 90 })] });
    await sheet.getByTestId("install-error").filter({ hasText: "Kurulum başarısız: apt-get başarısız" }).waitFor();
    assert.equal(await sheet.getByTestId("install-go").innerText(), "Yeniden dene");
    assert.equal(await hashOf(page), "#/uygulamalar?ekle=katalog&paket=wireguard", "a failed install stays");
    await shot(page, "1440-light-katalog-hata.png");
    await sheet.getByTestId("catalog-back").click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ekle=katalog");
    await page.keyboard.press("Escape");
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.context().close();

    // ================= Bir imajdan: the definition, its checks, the review, a refusal, a failed and a done job
    page = await newPage();
    await page.goto(url("#/uygulamalar?ekle=imaj"));
    sheet = page.getByRole("dialog", { name: "Bir imajdan konteyner" });
    const flow = sheet.getByTestId("create-flow");
    await field(flow, "image").waitFor();
    assert.deepEqual(await field(flow, "network").locator("option").allInnerTexts(), ["Varsayılan Konsol ağı", "konsol", "arka (iç ağ)"], "the default and Konsol's managed bridges");
    assert.equal(await field(flow, "user").inputValue(), "downloads", "least privilege by default");
    await sheet.getByTestId("create-go").click();
    await flow.getByText("İmajın tam adını yazın: kayıt adresi, depo ve etiket (ör. docker.io/library/nginx:1.27-alpine).").waitFor();
    await flow.getByText("Ad küçük harfle başlar; küçük harf, rakam ve - içerir (2–31 karakter).").waitFor();
    assert(await field(flow, "image").evaluate((el) => el === document.activeElement), "the first invalid field has focus");
    await field(flow, "image").fill("nginx:latest");
    await field(flow, "name").fill("notlar");
    await flow.getByText("Bu ad kullanılıyor.").waitFor();
    await field(flow, "image").fill("docker.io/library/caddy:2.8");
    await field(flow, "name").fill("site");
    // Ports: an internet port needs the acknowledgement; the same server port twice; a port out of range.
    await flow.getByRole("button", { name: "Port ekle" }).click();
    let ports = flow.locator(".port-row");
    assert(await field(ports.nth(0), "scope").evaluate((el) => el === document.activeElement), "the new row's first field has focus");
    assert.equal(await field(ports.nth(0), "scope").inputValue(), "local", "a new port starts on this server only");
    await field(ports.nth(0), "host").fill("8080");
    await field(ports.nth(0), "inner").fill("80");
    await field(ports.nth(0), "scope").selectOption("public");
    await ports.nth(0).getByText("İnternete açık port için onay kutusunu işaretleyin.").waitFor();
    await field(ports.nth(0), "ack").locator("input").check();
    await flow.getByRole("button", { name: "Port ekle" }).click();
    await field(ports.nth(1), "host").fill("8080");
    await field(ports.nth(1), "inner").fill("70000");
    await ports.nth(1).getByText("Portlar 1–65535 arasında bir sayı olmalı.").waitFor();
    await field(ports.nth(1), "inner").fill("443");
    await ports.nth(1).getByText("Bu sunucu portu bu protokolle iki kez var.").waitFor();
    await field(ports.nth(1), "protocol").selectOption("udp");
    await ports.nth(1).getByText("Bu sunucu portu bu protokolle iki kez var.").waitFor({ state: "detached" });
    await field(ports.nth(1), "scope").selectOption("tailscale");
    // Mounts: a volume from the list or a new name, a server folder through the picker, the account rule.
    await flow.getByRole("button", { name: "Bağlama ekle" }).click();
    let mounts = flow.locator(".mount-row");
    assert.deepEqual(await flow.locator("datalist option").evaluateAll((os) => os.map((o) => o.value)), ["web-veri", "bos-veri"]);
    await field(mounts.nth(0), "source").fill("Site Verisi");
    await field(mounts.nth(0), "destination").fill("/data");
    await mounts.nth(0).getByText("Birim adı küçük harf ya da rakamla başlar; küçük harf, rakam ve - _ . içerir.").waitFor();
    await field(mounts.nth(0), "source").fill("site-veri");
    await flow.getByRole("button", { name: "Bağlama ekle" }).click();
    await field(mounts.nth(1), "type").selectOption("bind");
    await mounts.nth(1).getByText("Sunucu klasörünü seçin.").waitFor();
    await mounts.nth(1).getByTestId("folder-toggle").click();
    await mounts.nth(1).getByRole("button", { name: "/srv/kitaplik seç" }).click();
    await field(mounts.nth(1), "destination").fill("/data");
    await mounts.nth(1).getByText("Bu konteyner yolu iki kez var.").waitFor();
    await field(mounts.nth(1), "destination").fill("/kitaplik");
    await field(flow, "user").selectOption("image");
    await flow.getByText("Sunucu klasörüne yalnız Dosyalar hesabıyla yazılabilir: hesabı değiştirin ya da klasörü salt okunur yapın.").waitFor();
    await field(mounts.nth(1), "readonly").locator("input").check();
    await flow.getByText("Sunucu klasörüne yalnız Dosyalar hesabıyla yazılabilir", { exact: false }).waitFor({ state: "detached" });
    // Environment: names checked, a secret row; command; limits.
    await flow.getByRole("button", { name: "Değişken ekle" }).click();
    let envs = flow.locator(".env-row");
    await field(envs.nth(0), "env-name").fill("1TZ");
    await envs.nth(0).getByText("Değişken adı harf ya da _ ile başlar; harf, rakam ve _ içerir.").waitFor();
    await field(envs.nth(0), "env-name").fill("TZ");
    await field(envs.nth(0), "env-value").fill("Europe/Istanbul");
    await flow.getByRole("button", { name: "Değişken ekle" }).click();
    await field(envs.nth(1), "env-name").fill("SIFRE");
    await field(envs.nth(1), "secret").locator("input").check();
    assert.equal(await field(envs.nth(1), "env-value").getAttribute("type"), "password");
    await field(envs.nth(1), "env-value").fill("cok-gizli");
    await flow.getByRole("button", { name: "Değişken ekle" }).click();
    await flow.getByRole("button", { name: "3. değişkenini kaldır" }).click();
    assert.equal(await envs.count(), 2);
    assert(await flow.getByRole("button", { name: "Değişken ekle" }).evaluate((el) => el === document.activeElement), "focus goes to Değişken ekle after a removal");
    await field(flow, "command").fill("caddy\nrun\n--config\n/etc/caddy/Caddyfile");
    await field(flow, "cpus").fill("iki");
    await field(flow, "memory").fill("512mb");
    await flow.getByText("İşlemci sınırı bir sayı olmalı (ör. 1.5; en çok 256).").waitFor();
    await flow.getByText("Bellek sınırı sayı ve birim olmalı (ör. 512m, 2g).").waitFor();
    await field(flow, "cpus").fill("0.5");
    await field(flow, "memory").fill("256m");
    await field(flow, "restart").selectOption("always");
    assert.equal(await flow.locator(".field-error").count(), 0, "no problem left");
    await noStyles(page, "imajdan");
    assert(await guarded(page), "the draft asks before a reload");
    await shot(page, "1440-light-imajdan.png", true);
    await sheet.getByTestId("create-go").click();
    await sheet.getByTestId("review").waitFor();
    assert(await sheet.getByTestId("review-title").evaluate((el) => el === document.activeElement), "the review's heading has focus");
    assert.deepEqual(await sheet.locator(".review-facts dt").allInnerTexts(), ["Ad", "İmaj", "Ağ", "Port", "Port", "Bağlama", "Bağlama", "Ortam", "Ortam", "Komut", "Başlatma", "İşlemci sınırı", "Bellek sınırı", "Hesap"]);
    assert.deepEqual(await sheet.locator(".review-facts dd").allInnerTexts(), ["site", "docker.io/library/caddy:2.8", "Varsayılan Konsol ağı",
      "İnternet (herkese açık) · 8080 → 80/tcp", "Tailscale · 8080 → 443/udp", "birim site-veri → /data", "klasör /srv/kitaplik → /kitaplik (salt okunur)",
      "TZ=Europe/Istanbul", "SIFRE (gizli, yeni değer)", "caddy run --config /etc/caddy/Caddyfile", "açılışta başlar · yeniden başlatma: Her zaman", "0.5 çekirdek", "256m",
      "İmajın kendi hesabı (çoğunlukla root)"]);
    assert.equal(await sheet.getByTestId("public-ports").locator(".notice-title").innerText(), "İnternete açık port: 8080/tcp");
    assert.equal(await sheet.locator('[data-testid="consequences"] [data-ton="bad"]').count(), 1, "the internet port is called out");
    assert.equal(await sheet.getByTestId("create-go").innerText(), "Oluştur ve başlat");
    await sheet.getByTestId("start-after").locator("input").uncheck();
    assert.equal(await sheet.getByTestId("create-go").innerText(), "Oluştur");
    await shot(page, "1440-light-imajdan-gozden.png", true);
    // A refusal: the server's words on the review, nothing else changes.
    expectedFailures = ["/api/konsol/konteynerler/islem"];
    replies.konteyner.push({ status: 409, body: { error: "Bu ad bir uygulamaya veya sistem hizmetine ait." } });
    await sheet.getByTestId("create-go").click();
    await sheet.getByTestId("create-error").filter({ hasText: "Bu ad bir uygulamaya veya sistem hizmetine ait." }).waitFor();
    expectedFailures = [];
    const created = { name: "site", image: "docker.io/library/caddy:2.8", image_ref: "docker.io/library/caddy:2.8", network: "bridge",
      ports: [{ scope: "public", host_port: 8080, container_port: 80, protocol: "tcp", public_ack: true }, { scope: "tailscale", host_port: 8080, container_port: 443, protocol: "udp", public_ack: false }],
      mounts: [{ type: "volume", source: "site-veri", destination: "/data", read_only: false }, { type: "bind", source: "/srv/kitaplik", destination: "/kitaplik", read_only: true }],
      environment: [{ name: "TZ", value: "Europe/Istanbul", secret: false }, { name: "SIFRE", value: "cok-gizli", secret: true }],
      command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile"], autostart: true, restart: "always", cpus: "0.5", memory: "256m", user: "image" };
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "create", config: created, start: false }, "the exact create request");
    // A failed job: back to the definition, which kept the draft.
    await stream();
    await sheet.getByTestId("create-go").click();
    await sheet.getByTestId("create-run").waitFor();
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "create", config: created, start: false });
    push("islemler", { items: [job({ id: lastJob(), ad: "site · Oluştur", adim: "İmaj çekiliyor" })] });
    await sheet.getByTestId("create-step").filter({ hasText: "İmaj çekiliyor" }).waitFor();
    push("islemler", { items: [job({ id: lastJob(), ad: "site · Oluştur", durum: "hata", adim: "İmaj çekilemedi: manifest unknown", bitis: NOW + 5 })] });
    await sheet.getByTestId("create-error").filter({ hasText: "Oluşturulamadı: İmaj çekilemedi: manifest unknown" }).waitFor();
    await shot(page, "1440-light-imajdan-hata.png");
    await sheet.getByTestId("create-go").click();
    await field(flow, "image").waitFor();
    assert.equal(await field(flow, "name").inputValue(), "site", "the draft is kept");
    assert.equal(await flow.locator(".port-row").count(), 2);
    // Done: the new application's page opens.
    await sheet.getByTestId("create-go").click();
    await sheet.getByTestId("start-after").locator("input").check();
    await sheet.getByTestId("create-go").click();
    await sheet.getByTestId("create-run").waitFor();
    assert.equal(lastPost("konteynerler/islem").start, true);
    APPS.site = app({ id: "konteyner:site", ad: "site", tur: "konteyner", aciklama: "Konteyner · docker.io/library/caddy", konteyner: "site", eylemler: ["durdur", "yeniden-baslat", "kaldir"] });
    CONTAINERS.site = crow({ name: "site", image: "docker.io/library/caddy@sha256:" + SHA("e"), unit: "konsol-site.service", network: "konsol", actions: ["stop", "restart", "save", "remove", "image-update"],
      config: { ...created, image: "docker.io/library/caddy@sha256:" + SHA("e"), manual_stop: false }, editable: EDITABLE, revision: "rev-site-1" });
    setApps(["gezgin", "torrent", "web", "notlar", "medya", "site", "paylasim"], [CATALOGUE[1]]);
    push("islemler", { items: [job({ id: lastJob(), ad: "site · Oluştur", durum: "tamam", bitis: NOW + 9 })] });
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:site");
    await page.locator("main h1").filter({ hasText: "site" }).waitFor();
    await page.context().close();
    delete CONTAINERS.site;
    setApps(["gezgin", "torrent", "web", "notlar", "medya", "paylasim"], [CATALOGUE[1]]);

    // ================= Var olanı yönetime al: the list, a preview, the choices, the typed word
    page = await newPage();
    await page.goto(url("#/uygulamalar?ekle=sahiplen"));
    sheet = page.getByRole("dialog", { name: "Var olanı yönetime al" });
    await sheet.locator('[data-konteyner="medya"]').waitFor();
    assert.deepEqual(await sheet.locator(".choice-item strong").allInnerTexts(), ["medya", "eski", "garip"], "only containers made outside Konsol");
    assert.equal(await sheet.locator('[data-konteyner="eski"] .warn-text').innerText(), "Konteyner başka bir yöneticiye ait veya desteklenmeyen seçenekler kullanıyor.");
    assert.equal(await sheet.locator('[data-konteyner="eski"] button').count(), 0, "not adoptable: no button");
    await stream();
    const adoptPosts = posts("konteynerler/islem").length;
    await sheet.getByRole("button", { name: "medya: önizle" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ekle=sahiplen&ad=medya");
    sheet = page.getByRole("dialog", { name: "medya · yönetime al" });
    await sheet.getByTestId("adopt-waiting").waitFor();
    await waitFor(() => posts("konteynerler/islem").length && lastPost("konteynerler/islem").preview === true, "the preview request");
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "adopt", name: "medya", preview: true });
    const previewJob = lastJob();
    const PREVIEW_CONFIG = { name: "medya", image: "docker.io/example/medya@sha256:" + SHA("f"), image_ref: "docker.io/example/medya:10.9", network: "host",
      ports: [{ scope: "public", host_port: 8096, container_port: 8096, protocol: "tcp", public_ack: false }, { scope: "tailscale", host_port: 1900, container_port: 1900, protocol: "udp", public_ack: false }],
      mounts: [{ type: "bind", source: "/srv/medya", destination: "/media", read_only: false }], environment: [{ name: "TZ", value: "Europe/Istanbul", secret: false }, { name: "ANAHTAR", secret: true, present: true }],
      command: [], autostart: true, restart: "always", cpus: "", memory: "", user: "image", pids_limit: "2048", stop_signal: "SIGTERM" };
    ops[previewJob] = { id: previewJob, action: "adopt", name: "medya", state: "done", step: "", result: { preview: { config: PREVIEW_CONFIG, unsupported: [], fingerprint: "fp-medya-1", requires_scope_review: true } } };
    push("islemler", { items: [job({ id: previewJob, ad: "medya · Sahiplen", durum: "tamam", bitis: NOW + 20 })] });
    await sheet.getByTestId("adopt-read").waitFor();
    assert.deepEqual(await sheet.getByTestId("adopt-read").locator("dd").allInnerTexts(),
      ["docker.io/example/medya:10.9", "host", "/srv/medya → /media", "TZ, ANAHTAR (gizli)", "Her zaman"]);
    assert.equal(await field(sheet, "network").inputValue(), "bridge", "the host network is not offered: the default bridge");
    const adoptPorts = sheet.locator(".adopt-row");
    assert.deepEqual(await adoptPorts.locator(".field-help").allInnerTexts(), ["Şu an: İnternet (herkese açık)", "Şu an: Tailscale"]);
    assert.deepEqual([await field(adoptPorts.nth(0), "scope").inputValue(), await field(adoptPorts.nth(1), "scope").inputValue()], ["", ""], "every scope chosen again");
    await sheet.getByTestId("adopt-go").click();
    await sheet.getByTestId("adopt-why").filter({ hasText: "Her portun erişimini seçin." }).waitFor();
    await sheet.getByText("Erişimi seçin.").first().waitFor();
    await field(adoptPorts.nth(0), "scope").selectOption("public");
    await field(adoptPorts.nth(1), "scope").selectOption("local");
    await sheet.getByTestId("adopt-why").filter({ hasText: "Her portun erişimini seçin." }).waitFor();
    await field(adoptPorts.nth(0), "ack").locator("input").check();
    await sheet.getByTestId("adopt-why").filter({ hasText: "Hesabı ya da klasörü düzeltin." }).waitFor();
    await sheet.getByText("Sunucu klasörüne yalnız Dosyalar hesabıyla yazılabilir: hesabı değiştirin ya da klasörü salt okunur yapın.").waitFor();
    await field(sheet, "user").selectOption("downloads");
    await sheet.getByTestId("adopt-why").filter({ hasText: "Onay sözcüğünü yazın." }).waitFor();
    await sheet.getByRole("textbox", { name: "Onaylamak için onayla yazın" }).fill("onayla");
    await noStyles(page, "yönetime al");
    await shot(page, "1440-light-yonetime-al.png", true);
    assert.equal(posts("konteynerler/islem").length, adoptPosts + 1, "nothing changed before the confirmation");
    await sheet.getByTestId("adopt-go").click();
    await sheet.getByTestId("adopt-run").waitFor();
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "adopt", name: "medya", preview_fingerprint: "fp-medya-1", start: true, confirm: true,
      config: { ...PREVIEW_CONFIG, network: "bridge", user: "downloads", ports: [{ scope: "public", host_port: 8096, container_port: 8096, protocol: "tcp", public_ack: true },
        { scope: "local", host_port: 1900, container_port: 1900, protocol: "udp", public_ack: false }] } }, "the preview's settings with the choices");
    push("islemler", { items: [job({ id: lastJob(), ad: "medya · Sahiplen", durum: "tamam", bitis: NOW + 40 })] });
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya");
    // Options the server cannot carry over block it.
    await page.goto(url("#/uygulamalar?ekle=sahiplen&ad=garip"));
    sheet = page.getByRole("dialog", { name: "garip · yönetime al" });
    await sheet.getByTestId("adopt-waiting").waitFor();
    await waitFor(() => lastPost("konteynerler/islem").name === "garip", "the preview request");
    const garipJob = lastJob();
    ops[garipJob] = { id: garipJob, action: "adopt", name: "garip", state: "done", result: { preview: { config: { ...PREVIEW_CONFIG, name: "garip", ports: [], mounts: [] },
      unsupported: ["--privileged", "--device /dev/dri"], fingerprint: "fp-garip" } } };
    push("islemler", { items: [job({ id: garipJob, ad: "garip · Sahiplen", durum: "tamam", bitis: NOW + 50 })] });
    await sheet.getByTestId("adopt-unsupported").waitFor();
    assert.deepEqual(await sheet.getByTestId("adopt-unsupported").locator("li").allInnerTexts(), ["--privileged", "--device /dev/dri"]);
    assert(await sheet.getByTestId("adopt-go").isDisabled(), "cannot be adopted");
    assert.equal(await sheet.getByRole("textbox", { name: "Onaylamak için onayla yazın" }).count(), 0);
    // A failed preview job says why and can be asked again.
    await page.goto(url("#/uygulamalar?ekle=sahiplen&ad=medya"));
    sheet = page.getByRole("dialog", { name: "medya · yönetime al" });
    await sheet.getByTestId("adopt-waiting").waitFor();
    await waitFor(() => lastPost("konteynerler/islem").name === "medya" && lastJob() !== garipJob, "another preview");
    push("islemler", { items: [job({ id: lastJob(), ad: "medya · Sahiplen", durum: "hata", adim: "Konteyner incelenemedi.", bitis: NOW + 60 })] });
    await sheet.getByTestId("adopt-error").filter({ hasText: "Konteyner incelenemedi." }).waitFor();
    await sheet.getByRole("button", { name: "Yeniden dene" }).waitFor();
    await page.context().close();

    // ================= a Konsol container's page: Özet, Erişim's ports, Depolama, the update check
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:web"));
    await page.getByTestId("source").waitFor();
    assert.equal(await page.getByTestId("source").locator(".pill").innerText(), "Konsol");
    assert.equal(await page.getByTestId("unit").innerText(), "konsol-web.service");
    assert.equal(await page.getByTestId("container-id").innerText(), "0a1b2c3d4e5f");
    assert.equal(await page.getByTestId("image-tag").innerText(), " · etiket docker.io/library/nginx:1.27-alpine");
    assert.equal(await page.getByTestId("command").innerText(), "nginx -g daemon off;");
    assert.equal(await page.getByTestId("note-unhealthy").getByRole("link", { name: "Günlük" }).getAttribute("href"), "#/uygulamalar/konteyner:web?sekme=gunluk");
    assert.equal(await page.getByTestId("update-state").innerText(), "Yeni sürüm var");
    const clock = (s) => new Intl.DateTimeFormat("tr-TR", { hour: "2-digit", minute: "2-digit" }).format(new Date(s * 1000));
    assert.equal(await page.getByTestId("update-note").innerText(), `kanal: docker.io/library/nginx:1.27-alpine · ${clock(NOW - 600)}'de denetlendi`);
    assert.equal(await page.getByTestId("cpu-limit").innerText(), "Sınır 1.5 çekirdek");
    assert.equal(await page.getByTestId("memory-limit").innerText(), "Sınır 512m");
    assert.equal(await page.getByTestId("autostart").innerText(), "Açılışta başlar");
    assert.equal(await page.getByTestId("restart-policy").innerText(), "Hata olursa");
    const env = page.getByTestId("summary-env");
    assert.deepEqual(await cells(env), ["TZ|Europe/Istanbul", "API_TOKEN|gizli · gösterilmez", "ESKI|1"]);
    await noStyles(page, "web özet");
    await shot(page, "1440-light-konteyner-ozet.png", true);
    const ayrintiReads = () => h.requests.filter((r) => r.path === "/api/konsol/konteynerler/ayrinti").length;
    const before = ayrintiReads();
    await page.getByTestId("update-check").click();
    await waitFor(() => h.requests.some((r) => r.path === "/api/konsol/konteynerler/guncellemeler" && r.query === "?yenile=1"), "the registries asked again");
    await waitFor(() => ayrintiReads() > before, "the container read again");
    await page.getByTestId("update-note").filter({ hasText: `${clock(NOW + 60)}'de denetlendi` }).waitFor();
    // Erişim: the published ports with their scope, the internet one marked.
    await page.getByRole("tab", { name: "Erişim" }).click();
    const portTable = page.getByTestId("port-table");
    await portTable.waitFor();
    assert.deepEqual(await cells(portTable), ["Yalnız bu sunucu|8088|80|TCP", "İnternet (herkese açık)|8443|443|TCP"]);
    assert.equal(await portTable.locator('tr[data-kapsam="public"] .pill-danger').count(), 1);
    await page.getByTestId("public-warning").waitFor();
    assert.equal(await page.getByTestId("network").innerText(), "Varsayılan Konsol ağı");
    await page.getByRole("tab", { name: "Depolama" }).click();
    assert.deepEqual(await page.getByTestId("volumes").locator(".mount").allInnerTexts(), ["web-veri\nOkuma-yazma · konteynerde /usr/share/nginx/html"]);
    assert.equal(await page.getByTestId("volumes").getByRole("link", { name: "Gelişmiş → Podman → Birimler" }).getAttribute("href"), "#/gelismis?sekme=podman&kaynak=birimler");

    // Günlük: the number of lines and the search are in the address; matches are marked.
    await page.getByRole("tab", { name: "Günlük" }).click();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(h.requests.filter((r) => r.path === "/api/konsol/uygulamalar/gunluk").at(-1).query, "?id=konteyner%3Aweb&satir=200");
    await page.getByTestId("log-tail").getByText("500").click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:web?sekme=gunluk&satir=500");
    await waitFor(() => h.requests.filter((r) => r.path === "/api/konsol/uygulamalar/gunluk").at(-1).query === "?id=konteyner%3Aweb&satir=500", "500 lines asked");
    await page.getByTestId("log-search").fill("HATA");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:web?sekme=gunluk&satir=500&ara=HATA");
    assert.deepEqual(await page.getByTestId("log-lines").locator("li").allInnerTexts(), [LOG[1], LOG[3]], "only the matching lines (Turkish case rules)");
    assert.deepEqual(await page.getByTestId("log-lines").locator("mark").allInnerTexts(), ["HATA", "hata"]);
    assert.equal(await page.getByTestId("log-matches").innerText(), "2 satır eşleşiyor");
    await page.getByTestId("log-search").fill("İSTANBUL");
    assert.deepEqual(await page.getByTestId("log-lines").locator("mark").allInnerTexts(), ["İstanbul"]);
    await shot(page, "1440-light-gunluk-arama.png");
    await page.reload();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByTestId("log-search").inputValue(), "İSTANBUL", "the search comes back from the address");
    assert.equal(await page.getByTestId("log-tail").locator("input:checked").inputValue(), "500");
    await page.getByTestId("log-search").fill("yok-böyle-bir-şey");
    await page.getByText("Eşleşen satır yok").waitFor();

    // Güncelle (a newer image is known): the result says the new version.
    await page.getByRole("tab", { name: "Özet" }).click();
    const action = (eylem) => page.getByTestId("app-actions").locator(`[data-eylem="${eylem}"]`);
    assert.deepEqual(await page.getByTestId("app-actions").locator("[data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem)),
      ["yeniden-baslat", "durdur", "guncelle", "kaldir"]);
    await action("guncelle").click();
    let dialog = page.getByRole("dialog", { name: "web güncellensin mi?" });
    await dialog.waitFor();
    assert.equal(await dialog.locator(".modal-desc").innerText(), "Yeni sürüm yayınlanmış · docker.io/library/nginx:1.27-alpine");
    assert.deepEqual(await dialog.locator(".modal-list li").allInnerTexts(), ["İmajın etiketi yeniden çekilir ve yeni özetle karşılaştırılır.",
      "Özet değiştiyse konteyner yeni imajla yeniden oluşturulur; kısa bir kesinti olabilir.", "Kalıcı veriler bağlamalarda kalır; konteynerin yazılabilir katmanı silinir."]);
    await dialog.getByRole("button", { name: "Güncelle" }).click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:web", eylem: "guncelle", revizyon: "rev-web-1" });
    const updateJob = lastJob();
    ops[updateJob] = { id: updateJob, action: "image-update", name: "web", state: "done", result: { changed: true, version: "1.27.3" } };
    await stream();
    push("islemler", { items: [job({ id: updateJob, ad: "web · İmaj güncelleme", adim: "İmaj indiriliyor" })] });
    await page.waitForTimeout(150);
    push("islemler", { items: [job({ id: updateJob, ad: "web · İmaj güncelleme", durum: "tamam", bitis: NOW + 70 })] });
    await page.getByTestId("action-note").filter({ hasText: "web: imaj güncellendi (1.27.3)." }).waitFor();
    await page.context().close();

    // ================= Ayarlar of a running Konsol container: the definition, the diff, a stale revision, the save
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:web?sekme=ayarlar"));
    const def = page.getByTestId("definition");
    await field(def, "image").waitFor();
    assert.equal(await field(def, "image").inputValue(), "docker.io/library/nginx:1.27-alpine", "the tag, not the pinned digest");
    assert.equal(await page.getByTestId("definition-status").innerText(), "Değişiklik yok.");
    assert(await page.getByTestId("definition-review").isDisabled());
    assert.equal(await guarded(page), false);
    const secret = def.locator(".env-row").nth(1);
    assert.equal(await field(secret, "env-value").getAttribute("placeholder"), "kayıtlı · boş bırakılırsa korunur");
    assert.equal(await field(secret, "env-value").inputValue(), "", "a stored secret never comes to the browser");
    assert(await field(secret, "secret").locator("input").isDisabled());
    await field(def, "memory").fill("1g");
    await field(def, "restart").selectOption("always");
    await def.getByRole("button", { name: "ESKI değişkenini kaldır" }).click();
    await def.getByRole("button", { name: "Port ekle" }).click();
    const newPort = def.locator(".port-row").nth(2);
    await field(newPort, "host").fill("9000");
    await field(newPort, "inner").fill("9000");
    await page.getByTestId("definition-status").filter({ hasText: "4 değişiklik; henüz kaydedilmedi." }).waitFor();
    assert(await guarded(page), "a draft asks before a reload");
    // Live updates (a read of the same definition) do not touch the draft.
    await page.getByRole("tab", { name: "Özet" }).click();
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    await field(def, "image").waitFor();
    await page.getByTestId("definition-review").click();
    let review = page.getByRole("dialog", { name: "web · değişiklikler" });
    await review.getByTestId("diff").waitFor();
    const diff = await review.getByTestId("diff").locator(".plan-item").evaluateAll((items) => items.map((i) => `${i.dataset.tur} ${i.querySelector(".plan-object").textContent}: ${i.querySelector(".plan-change").innerText.replace(/\s+/g, " ").trim()}`));
    assert.deepEqual(diff, ["add Port: Sonra: Yalnız bu sunucu · 9000 → 9000/tcp", "del Ortam: Önce: ESKI=1", "chg Yeniden başlatma: Önce: Hata olursa → Sonra: Her zaman",
      "chg Bellek sınırı: Önce: 512m → Sonra: 1g"], "each field before → after, named for screen readers");
    assert.deepEqual(await review.getByTestId("consequences").locator("li").evaluateAll((ls) => ls.map((l) => l.dataset.ton)), ["warn", "bad"], "a running container is re-created");
    assert.equal(await review.getByTestId("start-after").count(), 0, "a running container needs no start");
    assert.equal(await review.getByTestId("definition-apply").innerText(), "Uygula ve yeniden oluştur");
    await shot(page, "1440-light-tanim-gozden.png");
    // A stale revision: the current definition is offered instead of sending again.
    expectedFailures = ["/api/konsol/konteynerler/islem"];
    replies.konteyner.push({ status: 409, body: { error: "Ayarlar değişmiş; sayfayı yenileyip değişiklikleri yeniden inceleyin." } });
    await review.getByTestId("definition-apply").click();
    await review.getByTestId("definition-error").filter({ hasText: "Ayarlar değişmiş; sayfayı yenileyip değişiklikleri yeniden inceleyin." }).waitFor();
    assert(await review.getByTestId("definition-apply").isDisabled(), "not sent again as it is");
    expectedFailures = [];
    const expectedConfig = { name: "web", image: WEB_CONFIG.image, image_ref: WEB_CONFIG.image_ref, network: "bridge",
      ports: [...WEB_CONFIG.ports, { scope: "local", host_port: 9000, container_port: 9000, protocol: "tcp", public_ack: false }],
      mounts: WEB_CONFIG.mounts, environment: [{ name: "TZ", value: "Europe/Istanbul", secret: false }, { name: "API_TOKEN", secret: true }],
      command: WEB_CONFIG.command, autostart: true, restart: "always", cpus: "1.5", memory: "1g", user: "downloads" };
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "save", name: "web", revision: "rev-web-1", config: expectedConfig, start: false },
      "the exact save request; the stored secret goes without a value");
    await shot(page, "1440-light-tanim-eski.png");
    CONTAINERS.web = { ...CONTAINERS.web, revision: "rev-web-2", config: { ...WEB_CONFIG, cpus: "2", revision: "rev-web-2" } };
    await review.getByTestId("definition-reload").click();
    await review.waitFor({ state: "detached" });
    await page.getByTestId("definition-status").filter({ hasText: "Değişiklik yok." }).waitFor();
    assert.equal(await field(def, "cpus").inputValue(), "2", "the current definition replaced the draft");
    // Edit again and save: the job's end reads the page again.
    await field(def, "memory").fill("768m");
    await page.getByTestId("definition-review").click();
    review = page.getByRole("dialog", { name: "web · değişiklikler" });
    await review.getByTestId("definition-apply").click();
    await review.getByTestId("definition-run").waitFor();
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "save", name: "web", revision: "rev-web-2", start: false,
      config: { ...expectedConfig, ports: WEB_CONFIG.ports, environment: [...expectedConfig.environment, { name: "ESKI", value: "1", secret: false }], restart: "on-failure", cpus: "2", memory: "768m" } });
    await stream();
    push("islemler", { items: [job({ id: lastJob(), ad: "web · Kaydet", adim: "Konteyner yeniden oluşturuluyor" })] });
    await review.getByTestId("definition-run").getByText("Konteyner yeniden oluşturuluyor").waitFor();
    CONTAINERS.web = { ...CONTAINERS.web, revision: "rev-web-3", config: { ...WEB_CONFIG, cpus: "2", memory: "768m", revision: "rev-web-3" } };
    push("islemler", { items: [job({ id: lastJob(), ad: "web · Kaydet", durum: "tamam", bitis: NOW + 80 })] });
    await review.waitFor({ state: "detached" });
    await page.getByTestId("definition-done").filter({ hasText: "Değişiklikler uygulandı." }).waitFor();
    await page.getByTestId("definition-status").filter({ hasText: "Değişiklik yok." }).waitFor();
    assert.equal(await field(def, "memory").inputValue(), "768m");
    // A failed save job keeps the draft and says why.
    await field(def, "memory").fill("2g");
    await page.getByTestId("definition-review").click();
    review = page.getByRole("dialog", { name: "web · değişiklikler" });
    await review.getByTestId("definition-apply").click();
    await review.getByTestId("definition-run").waitFor();
    push("islemler", { items: [job({ id: lastJob(), ad: "web · Kaydet", durum: "hata", adim: "Konteyner başlatılamadı.", bitis: NOW + 90 })] });
    await review.getByTestId("definition-error").filter({ hasText: "Uygulanamadı: Konteyner başlatılamadı." }).waitFor();
    await review.getByTestId("definition-back").click();
    await review.waitFor({ state: "detached" });
    assert.equal(await field(def, "memory").inputValue(), "2g", "the draft is kept");
    await page.context().close();
    CONTAINERS = containers();

    // ================= a stopped definition: no live container, start after saving, İmajı güncelle "zaten güncel"
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:notlar"));
    await page.getByTestId("note-definition").waitFor();
    assert.equal(await page.getByTestId("container-id").innerText(), "— · çalışan konteyner yok");
    assert.equal(await page.getByTestId("autostart").innerText(), "Kapalı · siz durdurdunuz\nBaşlat bu durumu kaldırır; açılış tercihi yeniden geçerli olur.");
    assert.deepEqual(await page.getByTestId("app-actions").locator("[data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem)), ["baslat", "imaj-guncelle", "kaldir"]);
    await page.getByTestId("app-actions").locator('[data-eylem="imaj-guncelle"]').click();
    dialog = page.getByRole("dialog", { name: "notlar güncellensin mi?" });
    await dialog.waitFor();
    assert.equal(await dialog.locator(".modal-desc").innerText(), "Kendiliğinden güncelleme yoktur; yalnız siz onaylayınca.");
    await dialog.getByRole("button", { name: "Güncelle" }).click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:notlar", eylem: "guncelle", revizyon: "rev-notlar-1" });
    const sameJob = lastJob();
    ops[sameJob] = { id: sameJob, action: "image-update", name: "notlar", state: "done", result: { changed: false } };
    await stream();
    push("islemler", { items: [job({ id: sameJob, ad: "notlar · İmaj güncelleme" })] });
    await page.waitForTimeout(150);
    push("islemler", { items: [job({ id: sameJob, ad: "notlar · İmaj güncelleme", durum: "tamam", bitis: NOW + 100 })] });
    await page.getByTestId("action-note").filter({ hasText: "notlar: imaj zaten güncel." }).waitFor();
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    await field(page.getByTestId("definition"), "cpus").fill("1");
    await page.getByTestId("definition-review").click();
    review = page.getByRole("dialog", { name: "notlar · değişiklikler" });
    await review.getByTestId("start-after").waitFor();
    assert.deepEqual(await review.getByTestId("consequences").locator("li").evaluateAll((ls) => ls.map((l) => l.dataset.ton)), ["ok"], "a stopped one is not interrupted");
    assert.equal(await review.getByTestId("definition-apply").innerText(), "Kaydet");
    await review.getByTestId("start-after").locator("input").check();
    assert.equal(await review.getByTestId("definition-apply").innerText(), "Kaydet ve başlat");
    await review.getByTestId("definition-apply").click();
    await review.getByTestId("definition-run").waitFor();
    const body = lastPost("konteynerler/islem");
    assert.deepEqual([body.action, body.name, body.revision, body.start, body.config.cpus, body.config.user], ["save", "notlar", "rev-notlar-1", true, "1", "image"]);
    await page.context().close();

    // ================= a container made outside Konsol: its listening sockets, adopt from its page
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:medya?sekme=erisim"));
    const listen = page.getByTestId("listening");
    await listen.waitFor();
    assert.deepEqual(await cells(listen), ["Tüm adresler|0.0.0.0|8096|TCP", "Tailscale|100.64.0.2|1900|UDP"]);
    assert.equal(await page.getByTestId("network").innerText(), "Sunucu ağı (host)");
    const adoptLink = page.getByTestId("app-actions").locator('[data-eylem="yonetime-al"]');
    assert.equal(await adoptLink.getAttribute("href"), "#/uygulamalar?ekle=sahiplen&ad=medya");
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    await page.getByTestId("settings-external").waitFor();
    assert.equal(await page.getByTestId("settings-adopt").getAttribute("href"), "#/uygulamalar?ekle=sahiplen&ad=medya");
    await page.getByRole("tab", { name: "Özet" }).click();
    assert.equal(await page.getByTestId("summary-update").count(), 0, "no update state for a foreign container");
    assert.equal(await page.getByTestId("autostart").innerText(), "Konsol söz veremez\nBu konteyneri başka bir araç yönetir; açılışta ne olacağını o belirler.");
    await page.context().close();

    // ================= an App Store package's Ayarlar: the adapter, the settings form, the first-login account
    page = await newPage({ permissions: ["clipboard-read", "clipboard-write"] }, { clock: true });
    await page.goto(url("#/uygulamalar/paket:torrent?sekme=ayarlar"));
    const adapter = page.getByTestId("adapter");
    await field(adapter, "listener").waitFor();
    assert.equal(await field(adapter, "peer").inputValue(), "63851");
    assert.equal(await adapter.getByTestId("folder-value").inputValue(), "/srv/indirilenler");
    assert.deepEqual(await adapter.getByTestId("protected").locator(".mount").allInnerTexts(),
      ["/var/lib/qbittorrent → /config\nkorunur · Uygulama profili; taşıma ayrı bir işlemdir · burada değiştirilemez",
        "/srv/indirilenler → /srv/indirilenler\nkorunur · Uygulamanın indirme kökü · burada değiştirilemez"]);
    await field(adapter, "peer").fill("62947");
    await page.getByTestId("adapter-review").click();
    await adapter.getByText("Eş portu arayüz portundan farklı olmalı.").waitFor();
    await field(adapter, "peer").fill("80");
    await adapter.getByText("Eş portu 1024–65535 arasında bir sayı olmalı.").waitFor();
    await field(adapter, "peer").fill("64000");
    await adapter.getByTestId("folder-toggle").click();
    await adapter.getByRole("button", { name: "/srv/indirilenler içine gir" }).click();
    await adapter.getByRole("button", { name: "/srv/indirilenler/filmler seç" }).click();
    await page.getByTestId("adapter-status").filter({ hasText: "2 değişiklik; henüz kaydedilmedi." }).waitFor();
    await page.getByTestId("adapter-review").click();
    review = page.getByRole("dialog", { name: "Konteyner ayarları · değişiklikler" });
    await review.getByTestId("diff").waitFor();
    assert.deepEqual(await review.getByTestId("diff").locator(".plan-item").evaluateAll((items) => items.map((i) => `${i.querySelector(".plan-object").textContent}: ${i.querySelector(".plan-change").innerText.replace(/\s+/g, " ").trim()}`)),
      ["Eş portu: Önce: 63851 → Sonra: 64000", "Kayıt klasörü: Önce: /srv/indirilenler → Sonra: /srv/indirilenler/filmler"]);
    assert.deepEqual(await review.getByTestId("consequences").locator("li").evaluateAll((ls) => ls.map((l) => l.dataset.ton)), ["warn", "warn", "warn", "info"]);
    await review.getByTestId("adapter-apply").click();
    await review.getByTestId("adapter-run").waitFor();
    assert.deepEqual(lastPost("konteynerler/islem"), { action: "save", name: "torrent", revision: "rev-torrent-7",
      config: { listener_port: 62947, peer_port: 64000, save: "/srv/indirilenler/filmler" }, start: false });
    await stream();
    CONTAINERS.torrent = { ...CONTAINERS.torrent, revision: "rev-torrent-8", config: { listener_port: 62947, peer_port: 64000, save: "/srv/indirilenler/filmler" } };
    push("islemler", { items: [job({ id: lastJob(), ad: "torrent · Kaydet", durum: "tamam", bitis: NOW + 110 })] });
    await page.getByTestId("adapter-done").waitFor();
    await page.getByTestId("adapter-status").filter({ hasText: "Değişiklik yok." }).waitFor();
    // The settings form: the save folder is the adapter card's; only changed fields go out.
    const settings = page.getByTestId("package-settings");
    await field(settings, "username").waitFor();
    assert.equal(await settings.getByRole("heading").innerText(), "qBittorrent ayarları");
    assert.equal(await settings.locator('[data-alan="save"]').count(), 0, "one place per setting");
    await settings.getByText("İndirme klasörü: yukarıdaki Konteyner ayarları kartında değişir.").waitFor();
    assert.equal(await field(settings, "username").inputValue(), "admin", "the package's current value");
    assert.equal(await field(settings, "password").inputValue(), "", "never a password");
    await settings.getByTestId("settings-save").click();
    await settings.getByTestId("form-note").filter({ hasText: "Değişiklik yok." }).waitFor();
    await field(settings, "password").fill("yeni-parola-9");
    await settings.getByTestId("settings-save").click();
    await settings.getByText("Parolalar aynı değil.").waitFor();
    await field(settings, "password-tekrar").fill("yeni-parola-9");
    expectedFailures = ["/api/uygulama/torrent/ayar"];
    replies.ayar.push({ status: 400, body: { error: "qBittorrent ayarı uygulanamadı: profil kilitli." } });
    await settings.getByTestId("settings-save").click();
    await settings.getByTestId("settings-error").filter({ hasText: "qBittorrent ayarı uygulanamadı: profil kilitli." }).waitFor();
    expectedFailures = [];
    assert.deepEqual(h.requests.filter((r) => r.path === "/api/uygulama/torrent/ayar").at(-1).body, { password: "yeni-parola-9" }, "a password alone");
    await field(settings, "username").fill("yonetici");
    await field(settings, "password").fill("");
    await field(settings, "password-tekrar").fill("");
    await settings.getByTestId("settings-save").click();
    await settings.getByTestId("settings-done").waitFor();
    assert.deepEqual(h.requests.filter((r) => r.path === "/api/uygulama/torrent/ayar").at(-1).body, { username: "yonetici" }, "a blank password keeps the stored one");
    assert.equal(await field(settings, "username").inputValue(), "yonetici", "read again after the save");
    assert.equal(await settings.getByTestId("settings-note").innerText(), TORRENT_FORM.ayar_not);
    // The first-login account: the temporary password only on request, for 30 s, hidden with the tab.
    const acct = page.getByTestId("account-card");
    await acct.getByTestId("account-user").waitFor();
    assert.equal(await acct.getByTestId("account-address").innerText(), "torrent.ev");
    assert.equal(await acct.getByTestId("account-pass").innerText(), "•••••••••");
    const reveals = () => h.requests.filter((r) => r.path === "/api/konsol/uygulamalar/hesap" && r.query.includes("parola=1")).length;
    assert.equal(reveals(), 0, "never read without asking");
    await acct.getByTestId("account-reveal").click();
    await acct.getByTestId("account-pass").filter({ hasText: "Gecici-Parola-42" }).waitFor();
    assert.equal(await acct.getByTestId("account-left").innerText(), "30 sn sonra gizlenir");
    assert.equal(h.requests.filter((r) => r.path === "/api/konsol/uygulamalar/hesap").at(-1).query, "?id=paket%3Atorrent&parola=1");
    await noStyles(page, "torrent ayarlar");
    await shot(page, "1440-light-paket-ayarlar.png", true);
    await page.clock.runFor(10000);
    await acct.getByTestId("account-left").filter({ hasText: "20 sn sonra gizlenir" }).waitFor();
    await page.clock.runFor(20000);
    await acct.getByTestId("account-pass").filter({ hasText: "•••••••••" }).waitFor();
    assert.equal(await acct.getByTestId("account-left").count(), 0, "hidden after 30 s");
    await acct.getByTestId("account-reveal").click();
    await acct.getByTestId("account-pass").filter({ hasText: "Gecici-Parola-42" }).waitFor();
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await acct.getByTestId("account-pass").filter({ hasText: "•••••••••" }).waitFor();
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    // Copying fetches it on request too, without showing it.
    const n = reveals();
    await acct.getByTestId("account-copy").click();
    await waitFor(() => reveals() === n + 1, "the password fetched for the copy");
    await acct.locator('[role="status"]').filter({ hasText: "Geçici parola kopyalandı." }).waitFor();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "Gecici-Parola-42");
    assert.equal(await acct.getByTestId("account-pass").innerText(), "•••••••••", "copied, not shown");
    await page.context().close();

    // A package without settings or an account (404): the plain empty state.
    expectedFailures = ["/api/konsol/uygulamalar/hesap"];
    page = await newPage();
    await page.goto(url("#/uygulamalar/paket:gezgin?sekme=ayarlar"));
    await page.getByTestId("settings-empty").waitFor();
    await page.context().close();
    expectedFailures = [];

    // ================= the palette opens the add flows
    page = await newPage();
    await page.goto(url("#/genel"));
    await page.locator(".app-card").first().waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.getByRole("combobox").fill("konteyner oluştur");
    assert.equal(await palette.locator('[aria-selected="true"] .palette-label').innerText(), "İmajdan konteyner oluştur");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ekle=imaj");
    await page.getByRole("dialog", { name: "Bir imajdan konteyner" }).waitFor();
    await page.keyboard.press("Escape");
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes
    PACKAGES = [pkg("torrent", false, TORRENT_KONSOL), pkg("wireguard", false, WG_KONSOL), pkg("gezgin", true, GEZGIN_KONSOL)];
    CONTAINERS = containers();
    const views = [
      ["katalog", "#/uygulamalar?ekle=katalog&paket=torrent", '[data-testid="package-form"]'],
      ["imajdan", "#/uygulamalar?ekle=imaj", '[data-alan="image"]'],
      ["yonetime-al", "#/uygulamalar?ekle=sahiplen", '[data-konteyner="medya"]'],
      ["konteyner-ayarlar", "#/uygulamalar/konteyner:web?sekme=ayarlar", '[data-testid="definition"] [data-alan="image"]'],
      ["konteyner-ozet", "#/uygulamalar/konteyner:web", '[data-testid="summary-env"]'],
      ["konteyner-erisim", "#/uygulamalar/konteyner:medya?sekme=erisim", '[data-testid="listening"]'],
      ["paket-ayarlar", "#/uygulamalar/paket:torrent?sekme=ayarlar", '[data-testid="account-user"]'],
      ["gunluk", "#/uygulamalar/konteyner:web?sekme=gunluk&ara=hata", '[data-testid="log-lines"]'],
      ["uygulamalar", "#/uygulamalar", '[data-testid="infra-counts"]'],
    ];
    for (const colorScheme of ["light", "dark"]) {
      for (const [width, height] of [[1440, 900], [390, 844], [320, 640]]) {
        const phone = width < 768;
        page = await newPage({ colorScheme, viewport: { width, height }, ...(phone ? { isMobile: true, hasTouch: true } : {}), reducedMotion: "reduce" });
        for (const [name, hash, ready] of views) {
          await page.goto(url(hash));
          await page.locator(ready).first().waitFor();
          if (name === "imajdan") {
            await page.getByRole("button", { name: "Port ekle" }).click();
            await page.getByRole("button", { name: "Bağlama ekle" }).click();
            await page.locator('.mount-row [data-alan="type"]').selectOption("bind");
            await page.locator(".mount-row").getByTestId("folder-toggle").click();
            await page.locator(".mount-row .folder-row").first().waitFor();
            await page.getByRole("button", { name: "Değişken ekle" }).click();
          }
          await settle(page);
          await noStyles(page, `${width} ${colorScheme} ${name}`);
          assert(await noHorizontalScroll(page), `no horizontal scroll: ${width} ${colorScheme} ${name}`);
          const overflow = await page.evaluate(() => [...document.querySelectorAll(".modal, .card")].filter((el) => el.scrollWidth > el.clientWidth + 1).map((el) => el.className));
          assert.deepEqual(overflow, [], `nothing wider than its card or sheet: ${width} ${colorScheme} ${name}`);
          await shot(page, `${width}-${colorScheme}-${name}.png`, !hash.includes("ekle="));
        }
        await page.context().close();
      }
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: /yeni/ phase 4a Uygulama ekle and the application's settings under the production CSP — Uygulamalar' add card (catalogue " +
      "links, adoptable count, no links to the current interface) and Altyapı (unhealthy, updates, storage, Gelişmiş's Podman lists), the " +
      "catalogue (only packages not installed, the package's words, its form: the declared default, an unrendered default, required, " +
      "pattern, length, the repeated password, the folder picker with free space, entering, back, Esc only closing the picker, a refusal " +
      "keeping the draft, an older finished job not ending this one, progress, the application's page on success, a package without a " +
      "form, a failed job and Yeniden dene), Bir imajdan (checks of image, name, ports with scope and acknowledgement, duplicates, mounts " +
      "with volumes and the folder picker, the writable-bind account rule, environment with secrets, limits; the review with internet ports " +
      "called out and start after; a refusal; a failed job keeping the draft; the exact create request; the new page on success), adoption " +
      "(only foreign containers with reasons, the preview job and its record, every scope chosen again, acknowledgement, account rule, the " +
      "typed word, the exact request, unsupported options blocking, a failed preview), a Konsol container's Özet (source, unit, ID, tag, " +
      "update state with channel and time and ?yenile=1, limits, command, environment without secrets, start state), Erişim's ports and a " +
      "host container's sockets, Depolama, Günlük (?satir=, ?ara= with marks, Turkish case, reload), Güncelle and İmajı güncelle with their " +
      "results, the definition editor (draft kept across reads, field diff, consequences, stale revision with Güncel tanımı yükle, the exact " +
      "save with a kept secret, the job, a failed job keeping the draft, start after saving a stopped one), the leave guard, adopting from " +
      "the page, an App Store adapter (checks, picker, diff, exact save), the settings form (no password read, only changed fields, blank " +
      "password kept, refusal), the account (password on request only, 30 s, hidden with the tab, copied without showing), a package " +
      "without settings, the palette, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
