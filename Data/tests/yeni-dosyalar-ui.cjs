/* Konsol's new interface, phase 4b (DD-258, DD-267): Dosyalar — Depolama (the disk, the trash in short, Gezgin,
   the user area's folders with who uses them), Sunucu klasörleri (the folder browser over the files backend:
   breadcrumbs, Turkish order, sizes and times, the filter, ticks, uploads from the picker and a drop with the
   queue, progress and cancel, downloads, new folder, rename, move, trash, the packages' folders, the share
   marks and the links to Paylaşımlar, the text editor with CodeMirror under the CSP), Çöp kutusu (restore,
   permanent delete, empty) and Sistem dosyaları (the same browser as root over /api/sistem/*, the typed
   name, the root-save warning, the tailnet-only refusal) in the committed build under Data/console/yeni,
   with the production CSP and an in-memory files backend answering every request (yeni-harness.cjs). The
   real editor bundle (Data/console/duzenleyici.js) is served at /duzenleyici.js. Fails on any console
   error, CSP violation or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-dosyalar-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737/6598 addresses, example names)
const NOW = 1791845000;
const DAY = 86400;
const KB = 1024, MB = 1024 * KB, GB = 1024 * MB;
const TZ = "Europe/Istanbul";
const SHA = (c) => c.repeat(64);
const ucell = (durum, adresler = []) => ({ durum, adresler, uyari: "", not: "" });
const app = (o) => ({ modul: null, konteyner: null, simge: null, durum: "calisiyor", islem: null, tailscale: ucell("yok"), internet: ucell("yok"),
  kaynak: { cpu: null, bellek: null }, guncelleme: "sabit", adres: { tailscale: null, internet: null }, sayfa: null, eylemler: [], revizyon: null,
  metinler: null, hesap: false, aciklama: "", ...o });
const GEZGIN = app({ id: "paket:gezgin", ad: "Gezgin", tur: "paket", modul: "gezgin", konteyner: "gezgin", simge: "folder", aciklama: "Sunucudaki dosyalarınızı tarayıcıdan yönetin.",
  tailscale: ucell("acik", ["gezgin.ev"]), adres: { tailscale: "http://gezgin.ev", internet: null } });
const APPS = [
  GEZGIN,
  app({ id: "paket:torrent", ad: "qBittorrent", tur: "paket", modul: "torrent", konteyner: "torrent", simge: "download" }),
  app({ id: "konteyner:notlar", ad: "notlar", tur: "konteyner", konteyner: "notlar" }),
  app({ id: "yerlesik:dosya", ad: "Dosyalar", tur: "yerlesik", sayfa: "#/dosyalar" }),
];
const conn = (active, o = {}) => ({ enabled: active, permission: "ro", expires: null, expired: false, available: true, active, reason: "", url: "", ...o });
const SHARES = { enabled: true, running: true, host: "paylas.ev", max: 32, tail_enabled: true, limits: {},
  wan: { available: false, address: "", reason: "kapalı", mode: "off", domain: "", port: 443 },
  items: [{ id: "f1lm", path: "Filmler", name: "Filmler", username: "aile", created: NOW - 9 * DAY, changed: NOW - DAY, type: "dir", available: true,
    connections: { tailscale: conn(true), wan: conn(false) }, urls: { tailscale: "" }, url: "" }] };
const STORAGE = { read_at: NOW, kok: "/srv", hatalar: ["notlar2: konteyner okunamadı (podman inspect 125)"], kullananlar: [
  { yol: "/srv", id: "paket:gezgin", ad: "Gezgin", tur: "paket", hedef: "/srv", yazilabilir: true },
  { yol: "/srv/Belgeler/arsiv", id: "konteyner:notlar", ad: "notlar", tur: "konteyner", hedef: "/data", yazilabilir: false },
  { yol: "/srv/Filmler", id: "yerlesik:paylasim", ad: "Filmler", tur: "paylasim", hedef: "/s/f1lm/", yazilabilir: false },
  { yol: "/srv/eski", id: "konteyner:eski", ad: "eski", tur: "konteyner", hedef: "/old", yazilabilir: true },
  { yol: "/srv/indirilenler", id: "paket:torrent", ad: "qBittorrent", tur: "paket", hedef: "/downloads", yazilabilir: true },
] };

const data = {
  kaynaklar: { host: "sunucu", version: "2026.10.16-v2-250", surum: "1.2.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 5 * DAY,
    cores: 4, interval: 10, read_at: NOW, sampled_at: NOW, cpu: [2.0], mem: { total: 8 * GB, used: 700 * MB, graph: [8.0] },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 500 * GB, free: 320 * GB } },
  saglik: { status: "ok", read_at: NOW - 60, checks: [{ id: "firewall", name: "Güvenlik duvarı", status: "ok", detail: "Kurallar yerinde" }] },
  guncelleme: { kurulu: "2026.10.16-v2-250", kurulu_surum: "1.2.0", son: "2026.10.16-v2-250", son_surum: "1.2.0", commit: "0".repeat(40), yeni: false,
    denetlendi: NOW, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: NOW, alan: "ev", hizmetler: [], uyarilar: [], hatalar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null }, internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] },
      wireguard: { kurulu: false, not: "", aglar: [] }, sertifikalar: [] } },
  uygulamalar: { read_at: NOW, hatalar: [], katalog: [], altyapi: { podman: "5.4.2", calisiyor: true, imaj: 2, kullanilmayan_imaj: 0, birim: 1, ag: 2 }, items: APPS },
  paylasim: SHARES,
  depolama: STORAGE,
};

// ---- an in-memory files backend with the real one's shapes and words (files-panel/master-files-panel)
const OLD = Date.UTC(2024, 9, 8, 9, 0) / 1000;
let versions = 0;
const nextVersion = () => SHA("bcdefghijk"[versions++ % 10]);
const dir = (children = {}, mtime = NOW - 2 * DAY, o = {}) => ({ type: "dir", mtime, children, ...o });
const file = (size, o = {}) => ({ type: "file", size, mtime: NOW - 3600, ...o });
const text = (content, o = {}) => ({ type: "file", size: Buffer.byteLength(content), mtime: NOW - 7200, text: content, version: SHA("0"), editable: true, reason: "",
  truncated: false, encoding: "utf-8", eol: "lf", ...o });
const AYAR = "sunucu:\n  ad: ev\n";

function makeSrv() {
  return dir({
    ".gizli": dir({ anahtar: file(64) }),
    Belgeler: dir({ "rapor.pdf": file(1.2 * MB), "notlar.txt": text("alışveriş listesi\n"), arsiv: dir({}),
      "baskasi.conf": text("x=1\n", { editable: false, reason: "dosyanın sahibi başka bir hesap; düzenlenemez" }) }),
    Cep: dir({ "a.txt": text("a\n") }, OLD, { skipped: 1 }),
    Çizgi: dir({}),
    Filmler: dir({ 2024: dir({ "a.mkv": file(700 * MB) }), "Bölüm 10.mkv": file(400 * MB), "Bölüm 2.mkv": file(350 * MB) }),
    ılık: dir({}),
    indirilenler: dir({ ".gecici": dir({ "parca.!qB": file(20 * MB) }), "tamam.iso": file(2 * GB) }),
    "ayar.yml": text(AYAR, { version: SHA("a") }),
    "büyük.log": text("satır\n".repeat(20), { size: 3 * MB, truncated: true, editable: false, version: null, reason: "dosya 1 MiB'tan büyük; yalnız ilk bölümü okunur" }),
    "zeytin.bin": file(2 * KB, { binary: true }),
  });
}
function makeSys() {
  return dir({
    boot: dir({ vmlinuz: file(9 * MB) }, NOW - 30 * DAY, { mount: true }),
    etc: dir({ ssh: dir({ sshd_config: text("Port 22\nPermitRootLogin no\n", { version: SHA("d") }) }), hosts: text("127.0.0.1 localhost\n") }),
    srv: dir({}),
    tmp: dir({}),
    vmlinuz: { type: "link", mtime: NOW - 30 * DAY },
  }, NOW - 40 * DAY);
}
let srv = makeSrv();
let sys = makeSys();
let trash = [];
let trashSeq = 0;
function makeTrash() {
  trash = [
    { id: "1791844000000-0000aaaa", name: "ayar.yml", type: "file", size: 120, mtime: NOW - 5 * DAY, from: "", deleted: NOW - 3 * DAY, node: text("eski: 1\n") },
    { id: "1791843000000-0000bbbb", name: "Tatil", type: "dir", size: 3 * MB, mtime: NOW - 9 * DAY, from: "Belgeler", deleted: NOW - 4 * DAY, node: dir({ "a.jpg": file(3 * MB) }), count: 1 },
    { id: "1791842000000-0000cccc", name: "(bozuk kayıt)", type: "other", size: null, mtime: NOW - 6 * DAY, from: null, deleted: NOW - 6 * DAY, broken: true, node: null },
  ];
}
makeTrash();

const nodeAt = (root, rel) => {
  let n = root;
  for (const p of rel ? rel.split("/") : []) {
    if (!n || n.type !== "dir") return null;
    n = n.children[p];
  }
  return n ?? null;
};
const sizeOf = (n) => (n.type === "dir" ? Object.values(n.children).reduce((s, c) => s + sizeOf(c), 0) : n.type === "file" ? n.size : 0);
const entryOf = (name, n, dirsOnly) => (n.type === "dir"
  ? { name, type: "dir", mtime: n.mtime, size: dirsOnly ? null : sizeOf(n), count: Object.keys(n.children).length }
  : { name, type: n.type, mtime: n.mtime, size: n.type === "file" ? n.size : null });
const fail = (status, error) => ({ status, body: { error } });
const ENOENT = fail(404, "bulunamadı (taşınmış ya da silinmiş olabilir)");
const EEXIST = fail(409, "aynı adla bir öge var; üzerine yazılmaz");
const numbered = (name, i) => {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? `${name.slice(0, dot)} (${i})${name.slice(dot)}` : `${name} (${i})`;
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-dosyalar-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8775", data,
  expected: () => expectedFailures });
const { base, newPage, noHorizontalScroll, styleAttributes, shot } = h;
h.raw = (p) => /^\/api\/(sistem\/)?upload$/.test(p);
h.unsigned = (p) => /^\/api\/(sistem\/)?download$/.test(p);

/** Replies forced for the next requests of a path (a refusal), before the model answers. */
const forced = {};
const force = (path, ...replies) => (forced[path] = [...(forced[path] ?? []), ...replies]);
/** Uploads held back until the suite releases them (each: { name, release(create = true) }). */
const held = [];
let holding = false;

function backend(prefix, tree) {
  const route = (path, fn) => {
    h.handlers[prefix + path] = (req) => {
      const queue = forced[prefix + path];
      if (queue && queue.length) {
        const r = queue.shift();
        return typeof r === "function" ? r(req) : r;
      }
      return fn(req);
    };
  };
  const system = prefix === "/api/sistem";
  route("/state", () => ({ body: system
    ? { host: "sunucu", version: "v2-250", root: "/", sistem: true, writable: true, disk: { total: 60 * GB, free: 41 * GB, used: null, mount: true }, textLimit: MB }
    : { host: "sunucu", version: "v2-250", root: "/srv", downloads: "indirilenler", domain: "ev", writable: true,
      protected: [{ path: "indirilenler/.gecici", owner: "qBittorrent" }],
      disk: { total: 500 * GB, free: 320 * GB, used: sizeOf(tree()), mount: true },
      trash: { count: trash.length, size: trash.reduce((s, t) => s + (t.size ?? 0), 0) }, textLimit: MB } }));
  route("/list", ({ query }) => {
    const path = query.get("path") ?? "", dirsOnly = query.get("dirs") === "1";
    const n = nodeAt(tree(), path);
    if (!n || n.type !== "dir") return ENOENT;
    const entries = Object.entries(n.children).map(([name, c]) => entryOf(name, c, dirsOnly)).filter((e) => !dirsOnly || e.type === "dir");
    return { body: { path, entries, skipped: n.skipped ?? 0 } };
  });
  route("/text", ({ query }) => {
    const path = query.get("path"), enc = query.get("enc");
    const n = nodeAt(tree(), path);
    if (!n || n.type !== "file") return n ? fail(400, "dosya değil") : ENOENT;
    if (n.binary || n.text === undefined) return fail(415, "metin dosyası değil");
    const encoding = ["utf-8", "cp1254", "cp437"].includes(enc) ? enc : n.encoding;
    return { body: { path, size: n.size, mtime: n.mtime, truncated: n.truncated, detected: n.encoding, encoding, bom: false, eol: n.eol,
      editable: n.editable && !n.truncated, reason: n.truncated ? n.reason : n.editable ? "" : n.reason, version: n.editable && !n.truncated ? n.version : null, text: n.text } };
  });
  route("/text/save", ({ body }) => {
    const n = nodeAt(tree(), body.path);
    if (!n || n.type !== "file") return ENOENT;
    if (body.version !== n.version) return fail(409, "dosya siz açtıktan sonra değişti; kaydedilmedi (yeniden açın)");
    n.text = body.text;
    n.size = Buffer.byteLength(body.text);
    n.version = nextVersion();
    n.mtime = NOW;
    return { body: { path: body.path, version: n.version, size: n.size, mtime: NOW } };
  });
  route("/download", ({ query }) => {
    const path = query.get("path"), n = nodeAt(tree(), path);
    if (!n || n.type !== "file") return ENOENT;
    const name = path.split("/").at(-1);
    return { contentType: "application/octet-stream", headers: { "Content-Disposition": `attachment; filename="dosya"; filename*=UTF-8''${encodeURIComponent(name)}` },
      body: n.text ?? "ikili" };
  });
  route("/upload", ({ query, body }) => {
    const path = query.get("path"), name = query.get("name"), n = nodeAt(tree(), path);
    if (!n || n.type !== "dir") return ENOENT;
    if (n.children[name]) return fail(409, `“${name}” zaten var; üzerine yazılmaz`);
    const create = () => {
      n.children[name] = text(body.text, { mtime: NOW });
      return { status: 201, body: { name, size: body.size } };
    };
    if (!holding) return create();
    return new Promise((resolve) => held.push({ name, release: (make = true) => resolve(make ? create() : { status: 400, body: { error: "yükleme yarıda kesildi" } }) }));
  });
  route("/mkdir", ({ body }) => {
    const n = nodeAt(tree(), body.path);
    if (!n || n.type !== "dir") return ENOENT;
    if (!body.name || body.name.includes("/")) return fail(400, "geçersiz ad (boş olamaz, / içeremez, en çok 255 bayt)");
    if (n.children[body.name]) return EEXIST;
    n.children[body.name] = dir({}, NOW);
    return { status: 201, body: { name: body.name } };
  });
  route("/rename", ({ body }) => {
    const n = nodeAt(tree(), body.path);
    if (!n || !n.children[body.name]) return ENOENT;
    if (n.children[body.to]) return EEXIST;
    n.children[body.to] = n.children[body.name];
    delete n.children[body.name];
    return { body: { name: body.to } };
  });
  route("/move", ({ body }) => {
    const from = nodeAt(tree(), body.path), to = nodeAt(tree(), body.to);
    if (!from || !to || to.type !== "dir") return ENOENT;
    const clash = body.names.find((name) => to.children[name]);
    if (clash) return fail(409, `“${clash}” hedefte zaten var; üzerine yazılmaz`);
    for (const name of body.names) {
      to.children[name] = from.children[name];
      delete from.children[name];
    }
    return { body: { moved: body.names } };
  });
  if (system) {
    route("/delete", ({ body }) => {
      const want = body.names.length === 1 ? body.names[0] : "onayla";
      if (body.confirm !== want) return fail(400, `onay için ${body.names.length === 1 ? "ögenin adını" : "onayla"} yazın`);
      const n = nodeAt(tree(), body.path);
      const mounted = body.names.find((name) => n.children[name]?.mount);
      if (mounted) return fail(409, `“${mounted}” bir bağlama noktası ya da içinde bağlı bir disk var; silinmez`);
      for (const name of body.names) delete n.children[name];
      return { body: { deleted: body.names } };
    });
    return;
  }
  route("/trash", ({ method, body }) => {
    if (method === "GET") return { body: { items: trash.map(({ node, ...t }) => t) } };
    const n = nodeAt(tree(), body.path);
    const ids = [];
    for (const name of body.names) {
      const c = n.children[name];
      const id = `${String(NOW * 1000 + ++trashSeq).padStart(13, "0")}-0000000${trashSeq}`;
      trash.unshift({ id, name, type: c.type, size: c.type === "dir" ? sizeOf(c) : c.size ?? null, mtime: c.mtime, from: body.path, deleted: NOW, node: c,
        ...(c.type === "dir" ? { count: Object.keys(c.children).length } : {}) });
      delete n.children[name];
      ids.push(id);
    }
    return { body: { ids } };
  });
  route("/trash/restore", ({ body }) => {
    const restored = [];
    for (const id of body.ids) {
      const t = trash.find((x) => x.id === id);
      if (!t || t.broken) return fail(400, "çöp kaydı bozuk; kalıcı silin");
      const dest = nodeAt(tree(), t.from ?? "") ?? tree();
      let name = t.name;
      for (let i = 2; dest.children[name]; i++) name = numbered(t.name, i);
      dest.children[name] = t.node;
      trash = trash.filter((x) => x !== t);
      restored.push({ id, path: t.from ?? "", name });
    }
    return { body: { restored } };
  });
  route("/trash/purge", ({ body }) => {
    trash = trash.filter((t) => !body.ids.includes(t.id));
    return { body: { purged: body.ids.length } };
  });
  route("/trash/empty", ({ body }) => {
    if (body.confirm !== "onayla") return fail(400, "onay için onayla yazın");
    const n = trash.length;
    trash = [];
    return { body: { purged: n } };
  });
}
backend("/api", () => srv);
backend("/api/sistem", () => sys);

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const hashOf = (page) => page.evaluate(() => location.hash);
const queryOf = async (page) => new URLSearchParams((await hashOf(page)).split("?")[1] ?? "");
const posts = (path) => h.requests.filter((r) => r.method === "POST" && r.path === path).map((r) => r.body);
const lastPost = (path) => posts(path).at(-1);
const gets = (path) => h.requests.filter((r) => r.method === "GET" && r.path === path);
const open = (options = {}) => newPage({ timezoneId: TZ, ...options });
const decimal = (v, d) => v.toFixed(d).replace(".", ",");
function bytes(v) {
  if (v == null || v < 0) return "—";
  if (v === 0) return "0 B";
  if (v >= 1024 ** 4) return decimal(v / 1024 ** 4, 2) + " TB";
  if (v >= 1024 ** 3) return decimal(v / 1024 ** 3, 1) + " GB";
  if (v >= 1024 ** 2) return Math.round(v / 1024 ** 2) + " MB";
  return Math.max(1, Math.round(v / 1024)) + " KB";
}
const thisYear = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: TZ });
const otherYear = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short", year: "numeric", timeZone: TZ });
const when = (s) => (new Date(s * 1000).getFullYear() === new Date().getFullYear() ? thisYear : otherYear).format(new Date(s * 1000));
const activeText = (page) => page.evaluate(() => {
  const e = document.activeElement;
  return e ? (e.getAttribute("aria-label") || e.textContent || "").trim().replace(/\s+/g, " ") : "";
});
/** Whether leaving the page now would ask first (the leave guard's beforeunload handler). */
const guarded = (page) => page.evaluate(() => {
  const event = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
});
/** Style attributes outside CodeMirror's own tree (it positions its gutters and cursor through the CSSOM). */
const styled = async (page) => (await page.locator("body *").evaluateAll((els) =>
  els.filter((e) => (e.getAttribute("style") ?? "").trim() !== "" && !e.closest(".cm-editor"))
    .map((e) => `${e.tagName}.${e.className}: ${e.getAttribute("style")}`)));
async function noStyles(page, where) {
  assert.deepEqual(await styled(page), [], "no style attributes: " + where);
}
const browser = (page) => page.getByTestId("browser");
const row = (page, name) => page.getByTestId("list").locator(`tr[data-oge=${JSON.stringify(name)}]`);
const names = (page) => page.getByTestId("list").locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.oge));
const crumbs = (page) => page.getByTestId("crumbs").locator("li").allInnerTexts().then((l) => l.map((t) => t.replace(/^›\s*/, "").trim()));
const settle = (page) => page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
async function folder(page, rel) {
  await page.waitForFunction((want) => new URLSearchParams(location.hash.split("?")[1] ?? "").get("yol") === (want || null), rel);
  await page.locator(`[data-testid=list]:not([aria-busy])`).waitFor();
}
async function drop(page, files, type = "drop") {
  await page.evaluate(({ files, type }) => {
    const target = document.querySelector('[data-testid="browser"] [data-testid="list"]');
    const dt = new DataTransfer();
    for (const f of files) dt.items.add(new File([f.text], f.name, { type: "text/plain" }));
    for (const t of type === "drop" ? ["dragenter", "dragover", "drop"] : ["dragenter", "dragover"]) target.dispatchEvent(new DragEvent(t, { dataTransfer: dt, bubbles: true, cancelable: true }));
  }, { files, type });
}

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= Depolama: the disk, the trash, Gezgin and who uses which folder
    let page = await open();
    await page.goto(url("#/dosyalar"));
    assert.equal(await page.locator("main h1").innerText(), "Dosyalar");
    const tabs = page.getByRole("tablist", { name: "Dosyalar bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Depolama", "Sunucu klasörleri", "Çöp kutusu", "Paylaşımlar", "Sistem dosyaları"]);
    assert.deepEqual(await page.locator('.sidebar .nav-item[aria-current="page"] .nav-label').allInnerTexts(), ["Dosyalar"]);
    const disk = page.getByTestId("disk");
    await disk.getByTestId("disk-used").waitFor();
    assert.equal(await disk.getByTestId("disk-used").innerText(), `${bytes(180 * GB)} / ${bytes(500 * GB)}`);
    assert.equal(await disk.getByTestId("disk-free").innerText(), `${bytes(320 * GB)} boş · %36 dolu`);
    assert.equal(await disk.getByTestId("area").innerText(), `/srv · ${bytes(sizeOf(srv))} (çöp hariç)`);
    assert.equal(await disk.getByTestId("mount").innerText(), "Kendi diskinde (ayrı bir bağlama noktası)");
    assert.equal(await page.getByTestId("trash-count").innerText(), `3 öge · ${bytes(120 + 3 * MB)}`);
    assert.equal(await page.getByTestId("trash-link").getAttribute("href"), "#/dosyalar?sekme=cop");
    const gezginOpen = page.getByTestId("gezgin").getByTestId("gezgin-open");
    assert.deepEqual([await gezginOpen.getAttribute("href"), await gezginOpen.getAttribute("target"), await gezginOpen.getAttribute("rel")],
      ["http://gezgin.ev", "_blank", "noopener noreferrer"]);
    assert.equal(await page.getByTestId("gezgin").getByTestId("gezgin-page").getAttribute("href"), "#/uygulamalar/paket:gezgin");
    const folders = page.getByTestId("folders");
    await folders.locator("tbody tr").first().waitFor();
    assert.deepEqual(await folders.locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.klasor)), [".gizli", "Belgeler", "Cep", "Çizgi", "Filmler", "ılık", "indirilenler"],
      "folders first in Turkish order: Ç after C, ı before i");
    assert.equal(await page.getByTestId("whole").innerText(), "Bütün kullanıcı alanını kullanan: Gezgin (okuma-yazma · konteynerde /srv).");
    const uses = async (name) => folders.locator(`tr[data-klasor="${name}"] .files-uses li`).evaluateAll((lis) => lis.map((li) => ({
      kind: li.dataset.kullanan, text: li.innerText.replace(/\s+/g, " ").trim(), href: li.querySelector("a")?.getAttribute("href") ?? null })));
    assert.deepEqual(await uses("Filmler"), [
      { kind: "paylasim", text: "Filmler klasör paylaşımı · Filmler · salt okunur", href: "#/dosyalar?sekme=paylasimlar&paylasim=f1lm" },
      { kind: "paket", text: "Gezgin tüm kullanıcı alanı", href: "#/uygulamalar/paket:gezgin" }]);
    assert.deepEqual(await uses("indirilenler"), [
      { kind: "paket", text: "qBittorrent indirilenler · okuma-yazma · konteynerde /downloads", href: "#/uygulamalar/paket:torrent" },
      { kind: "koruma", text: "qBittorrent yazıyor · indirilenler/.gecici · Konsol burada değişiklik yapmaz", href: "#/uygulamalar/paket:torrent" },
      { kind: "paket", text: "Gezgin tüm kullanıcı alanı", href: "#/uygulamalar/paket:gezgin" }]);
    assert.deepEqual((await uses("Belgeler"))[0], { kind: "konteyner", text: "notlar Belgeler/arsiv · salt okunur · konteynerde /data", href: "#/uygulamalar/konteyner:notlar" });
    const filmler = folders.locator('tr[data-klasor="Filmler"]');
    assert.deepEqual(await filmler.locator("td").allInnerTexts().then((c) => c.slice(0, 2)), [bytes(1450 * MB), "3 öge"]);
    assert.equal(await folders.locator('tr[data-klasor="Çizgi"] td').first().innerText(), "—", "an empty folder has no size");
    assert.equal(await page.getByTestId("storage-warning").innerText(), "notlar2: konteyner okunamadı (podman inspect 125)");
    assert.equal((await page.getByTestId("elsewhere").locator("li").innerText()).replace(/\s+/g, " "), "eski eski · okuma-yazma · konteynerde /old");
    assert.match(await page.getByTestId("root-files").innerText(), /^Kökte ayrıca 3 dosya var/);
    await shot(page, "1440-light-depolama.png", true);
    // A folder opens in Sunucu klasörleri.
    await filmler.locator(".files-folder-link").click();
    await page.waitForURL((u) => u.hash === "#/dosyalar?sekme=srv&yol=Filmler");
    await row(page, "2024").waitFor();
    assert.deepEqual(await crumbs(page), ["/srv", "Filmler"]);
    await page.context().close();

    // Without Gezgin a note leads to the catalogue; a failed read of who uses what says so, the folders stay.
    data.uygulamalar = { ...data.uygulamalar, items: APPS.filter((a) => a.id !== "paket:gezgin") };
    h.status["/api/konsol/depolama"] = 503;
    expectedFailures = ["/api/konsol/depolama"];
    page = await open();
    await page.goto(url("#/dosyalar"));
    await page.getByTestId("storage-error").filter({ hasText: "Kullananlar okunamadı: fixture" }).waitFor();
    assert.equal(await page.getByTestId("gezgin").getByTestId("gezgin-install").getAttribute("href"), "#/uygulamalar?ekle=katalog&paket=gezgin");
    assert.match(await page.getByTestId("gezgin").innerText(), /Tam dosya yöneticisi Gezgin'dir/);
    assert.equal(await page.getByTestId("folders").locator('tr[data-klasor="Filmler"] td[data-label="Kullanan"]').innerText(), "okunamadı");
    await page.goto(url("#/dosyalar?sekme=srv"));
    assert.equal(await page.getByTestId("gezgin").getByRole("link", { name: "Gezgin'i kurun" }).getAttribute("href"), "#/uygulamalar?ekle=katalog&paket=gezgin");
    await page.context().close();
    delete h.status["/api/konsol/depolama"];
    expectedFailures = [];
    data.uygulamalar = { ...data.uygulamalar, items: APPS };

    // ================= Sunucu klasörleri: order, sizes, marks, the filter, ticks and the address
    page = await open();
    await page.goto(url("#/dosyalar?sekme=srv"));
    await row(page, "ayar.yml").waitFor();
    assert.deepEqual(await names(page), [".gizli", "Belgeler", "Cep", "Çizgi", "Filmler", "ılık", "indirilenler", "ayar.yml", "büyük.log", "zeytin.bin"]);
    assert.equal(await page.getByTestId("crumbs").count(), 0, "the root needs no trail: its title names it");
    assert.equal(await page.getByTestId("folder-title").innerText(), "/srv");
    assert.equal(await page.getByTestId("folder-summary").innerText(), `10 öge · ${bytes(sizeOf(srv))}`);
    assert.deepEqual(await row(page, "Filmler").locator("td").allInnerTexts().then((c) => c.slice(1, 3)), [bytes(1450 * MB), when(NOW - 2 * DAY)]);
    assert.equal(await row(page, "Cep").locator(".files-date").innerText(), when(OLD), "another year shows the year");
    assert.match(when(OLD), /2024$/);
    assert.equal(await row(page, "Çizgi").locator(".files-name .cell-note").innerText(), "0 öge");
    assert.equal(await row(page, "Çizgi").locator(".files-size").innerText(), "—");
    assert.equal(await row(page, "ayar.yml").locator(".files-size").innerText(), bytes(Buffer.byteLength(AYAR)));
    // Share marks and the links to Paylaşımlar (the other tab reads yeni= and paylasim=).
    assert.equal(await row(page, "Filmler").locator('[data-isaret="paylasim"]').innerText(), "Paylaşılıyor · Tailscale");
    assert.equal(await row(page, "Filmler").getByRole("link", { name: "Paylaşımı yönet: Filmler" }).getAttribute("href"), "#/dosyalar?sekme=paylasimlar&paylasim=f1lm");
    assert.equal(await row(page, "Filmler").getByRole("link", { name: "Paylaş: Filmler" }).count(), 0);
    assert.equal(await row(page, "Belgeler").getByRole("link", { name: "Paylaş: Belgeler" }).getAttribute("href"), "#/dosyalar?sekme=paylasimlar&yeni=Belgeler");
    assert.equal(await row(page, ".gizli").locator('[data-eylem="paylas"]').count(), 0, "a hidden folder is not offered");
    // A folder that holds a package's folder: marked, not ticked, not changed, not shared.
    const held1 = row(page, "indirilenler");
    assert.equal(await held1.locator('[data-isaret="koruma"]').innerText(), "İçinde qBittorrent klasörü var");
    assert.equal(await held1.locator('input[type="checkbox"]').count(), 0);
    assert.equal(await held1.locator('[data-eylem="adlandir"], [data-eylem="tasi"], [data-eylem="cop"], [data-eylem="paylas"]').count(), 0);
    // Row actions by kind: a text file opens in the editor, any small file has Düzenle, a big binary only İndir.
    assert.deepEqual(await row(page, "ayar.yml").locator(".files-row-actions [data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem)),
      ["indir", "duzenle", "adlandir", "tasi", "cop"]);
    assert.deepEqual(await row(page, "Belgeler").locator(".files-row-actions [data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem)),
      ["paylas", "adlandir", "tasi", "cop"]);
    assert.equal(await row(page, "ayar.yml").getByRole("link", { name: "İndir: ayar.yml" }).getAttribute("href"), "/api/download?path=ayar.yml");
    assert.equal(await row(page, "zeytin.bin").locator(".files-open").evaluate((a) => a.tagName + " " + a.getAttribute("href")), "A /api/download?path=zeytin.bin");
    // The filter: Turkish case rules, in the address, Esc clears it.
    const filter = page.getByTestId("filter");
    await filter.fill("İNDİR");
    await page.waitForFunction(() => new URLSearchParams(location.hash.split("?")[1]).get("ara") === "İNDİR");
    assert.deepEqual(await names(page), ["indirilenler"]);
    assert.equal(await page.getByTestId("folder-summary").innerText().then((t) => t.split(" · ")[0]), "1 / 10 öge gösteriliyor");
    await filter.fill("yok-böyle");
    await page.getByText("Eşleşen öge yok").waitFor();
    await filter.press("Escape");
    await row(page, "ayar.yml").waitFor();
    assert.equal((await queryOf(page)).get("ara"), null);
    // Ticks: "Tümünü seç" skips what may not be changed; the bar sums the size.
    await page.getByTestId("select-all").check();
    const selection = page.getByTestId("selection");
    assert.equal(await selection.locator(".files-selection-text").innerText(), `9 öge seçili · ${bytes(sizeOf(srv) - sizeOf(srv.children.indirilenler))}`);
    await page.getByTestId("sel-clear").click();
    assert.equal(await selection.count(), 0);
    await row(page, "ayar.yml").getByLabel("Seç: ayar.yml").check();
    await row(page, "zeytin.bin").getByLabel("Seç: zeytin.bin").check();
    assert.equal(await selection.locator(".files-selection-text").innerText(), `2 öge seçili · ${bytes(Buffer.byteLength(AYAR) + 2 * KB)}`);
    assert(await page.getByTestId("select-all").evaluate((i) => i.indeterminate), "some ticked: the box shows it");
    await shot(page, "1440-light-srv-secim.png", true);
    // Opening a folder is a history entry; the heading takes the focus; Back returns.
    await row(page, "Filmler").getByRole("button", { name: "Filmler", exact: true }).click();
    await folder(page, "Filmler");
    assert.deepEqual(await names(page), ["2024", "Bölüm 2.mkv", "Bölüm 10.mkv"], "numbers in order");
    assert.equal(await activeText(page), "Filmler");
    assert.equal(await selection.count(), 0, "a new folder starts without ticks");
    await page.goBack();
    await folder(page, "");
    await row(page, "Filmler").waitFor();
    await page.goForward();
    await folder(page, "Filmler");
    await page.getByTestId("crumbs").getByRole("button", { name: "/srv", exact: true }).click();
    await folder(page, "");
    // Paylaş leads to Paylaşımlar with the folder (that tab is built beside this one).
    await row(page, "Belgeler").getByRole("link", { name: "Paylaş: Belgeler" }).click();
    await page.waitForURL((u) => u.hash === "#/dosyalar?sekme=paylasimlar&yeni=Belgeler");
    await page.goBack();
    await row(page, "Belgeler").waitFor();

    // A folder that cannot be opened leaves the browser where it was.
    expectedFailures = ["/api/list"];
    force("/api/list", fail(403, "izin yok"));
    await row(page, "Cep").getByRole("button", { name: "Cep", exact: true }).click();
    await page.getByTestId("failure").filter({ hasText: "“/srv/Cep” açılamadı: izin yok" }).waitFor();
    await folder(page, "");
    assert.equal(await page.getByTestId("crumbs").count(), 0);
    await row(page, "Cep").getByRole("button", { name: "Cep", exact: true }).click();
    await folder(page, "Cep");
    assert.equal(await page.getByTestId("failure").count(), 0, "the next folder clears the old reason");
    assert.equal(await page.getByTestId("list").locator(".meter-note").innerText(), "1 öge gösterilmedi (adı geçersiz).");
    await page.context().close();
    // An address naming a folder that is not there: one up at a time until one opens.
    page = await open();
    await page.goto(url("#/dosyalar?sekme=srv&yol=Yok/Burada"));
    await page.getByTestId("failure").filter({ hasText: "“/srv/Yok” açılamadı: bulunamadı (taşınmış ya da silinmiş olabilir)" }).waitFor();
    await folder(page, "");
    await row(page, "ayar.yml").waitFor();
    assert.deepEqual(gets("/api/list").slice(-3).map((r) => r.query), ["?path=Yok%2FBurada", "?path=Yok", "?path="]);
    expectedFailures = [];
    await page.context().close();

    // ================= a package's folder: marked with its owner, nothing changes there
    page = await open();
    await page.goto(url("#/dosyalar?sekme=srv&yol=indirilenler"));
    await row(page, ".gecici").waitFor();
    assert.equal(await row(page, ".gecici").locator('[data-isaret="koruma"]').innerText(), "Yazan: qBittorrent");
    assert.equal(await row(page, ".gecici").locator('input[type="checkbox"]').count(), 0);
    assert.equal(await row(page, "tamam.iso").locator('input[type="checkbox"]').count(), 1);
    assert.equal(await page.getByTestId("guard-here").count(), 0);
    await row(page, ".gecici").getByRole("button", { name: ".gecici", exact: true }).click();
    await folder(page, "indirilenler/.gecici");
    assert.equal(await page.getByTestId("guard-here").innerText(),
      "qBittorrent bu klasöre yazıyor. Buradaki dosyaları taşımak ya da silmek onun işini bozar; Konsol burada değişiklik yapmaz.");
    assert(await page.getByTestId("upload").isDisabled());
    assert(await page.getByTestId("new-folder").isDisabled());
    assert.equal(await page.getByTestId("upload").getAttribute("title"), "qBittorrent bu klasöre yazıyor; burada değişiklik yapılmaz.");
    assert.deepEqual(await row(page, "parca.!qB").locator(".files-row-actions [data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem)), ["indir"]);
    assert.equal(await page.getByTestId("select-all").count(), 0);
    await drop(page, [{ name: "olmaz.txt", text: "x" }], "hover");
    assert.equal(await page.getByTestId("drop").innerText(), "qBittorrent bu klasöre yazıyor; burada değişiklik yapılmaz.");
    await drop(page, [{ name: "olmaz.txt", text: "x" }]);
    await page.getByTestId("failure").filter({ hasText: "qBittorrent bu klasöre yazıyor; burada değişiklik yapılmaz." }).waitFor();
    assert.equal(posts("/api/upload").length, 0, "nothing is sent into a package's folder");
    await shot(page, "1440-light-paket-klasoru.png", true);
    await page.context().close();

    // ================= uploads: picker, skipped names, the queue one at a time, cancel, a refusal, a drop
    page = await open();
    await page.goto(url("#/dosyalar?sekme=srv&yol=Belgeler"));
    await row(page, "notlar.txt").waitFor();
    holding = true;
    await page.getByTestId("upload-input").setInputFiles([
      { name: "notlar.txt", mimeType: "text/plain", buffer: Buffer.from("aynı ad") },
      { name: "yeni.txt", mimeType: "text/plain", buffer: Buffer.from("merhaba") },
      { name: "ikinci.txt", mimeType: "text/plain", buffer: Buffer.from("iki") },
    ]);
    const queue = page.getByTestId("uploads");
    const upload = (name) => queue.locator(`li[data-yukleme=${JSON.stringify(name)}]`);
    await h.waitFor(() => held.length === 1, "the first upload reaches the server");
    assert.equal(await page.getByTestId("note").innerText(), "2 dosya yükleme sırasına alındı. 1 öge atlandı; nedeni Yüklemeler'de.");
    assert.equal(await upload("notlar.txt").getByTestId("upload-state").innerText(), "atlandı: aynı adla bir öge var; üzerine yazılmaz");
    await page.waitForFunction(() => document.querySelector('[data-yukleme="yeni.txt"]')?.dataset.durum === "yukleniyor");
    assert.match(await upload("yeni.txt").getByTestId("upload-state").innerText(), /^%\d+$/);
    assert.equal(await upload("yeni.txt").locator("svg.usage").count(), 1, "a progress bar while it runs");
    assert.equal(await upload("ikinci.txt").getByTestId("upload-state").innerText(), "sırada");
    assert.equal(await upload("yeni.txt").locator(".cell-note").innerText(), "/srv/Belgeler · 1 KB");
    assert(await guarded(page), "closing the tab asks while uploads run");
    await shot(page, "1440-light-yuklemeler.png");
    // A waiting one is cancelled without being sent; the running one ends and the folder shows it.
    await upload("ikinci.txt").getByRole("button", { name: "Yüklemeyi iptal et: ikinci.txt" }).click();
    await upload("ikinci.txt").waitFor({ state: "detached" });
    held.shift().release();
    await row(page, "yeni.txt").waitFor();
    await page.getByTestId("note").filter({ hasText: "“yeni.txt” yüklendi." }).waitFor();
    await upload("yeni.txt").waitFor({ state: "detached" });
    const sent = h.requests.filter((r) => r.path === "/api/upload");
    assert.deepEqual(sent.map((r) => [r.query, r.body]), [["?path=Belgeler&name=yeni.txt", { size: 7, text: "merhaba" }]], "skipped and cancelled files are never sent");
    assert.equal(await guarded(page), false);
    // A running upload is cancelled: the request is given up and nothing appears.
    await page.getByTestId("upload-input").setInputFiles([{ name: "uzun.bin", mimeType: "application/octet-stream", buffer: Buffer.alloc(4096, 1) }]);
    await h.waitFor(() => held.length === 1, "the long upload reaches the server");
    await upload("uzun.bin").getByRole("button", { name: "Yüklemeyi iptal et: uzun.bin" }).click();
    await upload("uzun.bin").waitFor({ state: "detached" });
    held.shift().release(false);
    holding = false;
    assert.equal(await row(page, "uzun.bin").count(), 0);
    // The server refuses one (disk reserve): the line keeps the reason until removed.
    expectedFailures = ["/api/upload"];
    force("/api/upload", fail(507, "sunucuda yeterli boş alan yok (en az 5.0 GB boş kalmalı)"));
    await page.getByTestId("upload-input").setInputFiles([{ name: "buyuk.iso", mimeType: "application/octet-stream", buffer: Buffer.alloc(2048, 2) }]);
    await upload("buyuk.iso").getByTestId("upload-state").filter({ hasText: "yüklenemedi: sunucuda yeterli boş alan yok (en az 5.0 GB boş kalmalı)" }).waitFor();
    await upload("buyuk.iso").getByRole("button", { name: "Satırı kaldır: buyuk.iso" }).click();
    await upload("notlar.txt").getByRole("button", { name: "Satırı kaldır: notlar.txt" }).click();
    await queue.waitFor({ state: "detached" });
    expectedFailures = [];
    // A drop on the browser: the target is named, a folder is skipped, the file goes up.
    await drop(page, [{ name: "surukle.txt", text: "sürüklendi" }], "hover");
    assert.equal(await page.getByTestId("drop").innerText(), "Bırakın — /srv/Belgeler içine yüklenir");
    await shot(page, "1440-light-birak.png");
    await drop(page, [{ name: "surukle.txt", text: "sürüklendi" }]);
    await row(page, "surukle.txt").waitFor();
    assert.equal(await page.getByTestId("drop").count(), 0);
    assert.deepEqual(lastPost("/api/upload"), { size: Buffer.byteLength("sürüklendi"), text: "sürüklendi" });

    // ================= download, new folder, rename, move, trash
    const [download] = await Promise.all([page.waitForEvent("download"), row(page, "rapor.pdf").getByRole("link", { name: "İndir: rapor.pdf" }).click()]);
    assert.equal(download.suggestedFilename(), "rapor.pdf");
    assert.deepEqual(gets("/api/download").map((r) => r.query), ["?path=Belgeler%2Frapor.pdf"]);
    // Yeni klasör: the name's rules, a refusal in the server's words, the request.
    await page.getByTestId("new-folder").click();
    let dialog = page.getByRole("dialog", { name: "Yeni klasör" });
    assert.equal(await dialog.locator(".modal-desc").innerText(), "/srv/Belgeler");
    assert(await dialog.getByTestId("name-input").evaluate((i) => i === document.activeElement));
    await dialog.getByTestId("name-go").click();
    await dialog.locator(".field-error").filter({ hasText: "Bir ad yazın." }).waitFor();
    await dialog.getByTestId("name-input").fill("a/b");
    await dialog.getByTestId("name-go").click();
    await dialog.locator(".field-error").filter({ hasText: "Ad / içeremez." }).waitFor();
    expectedFailures = ["/api/mkdir"];
    await dialog.getByTestId("name-input").fill("arsiv");
    await dialog.getByTestId("name-input").press("Enter");
    await dialog.getByTestId("name-error").filter({ hasText: "aynı adla bir öge var; üzerine yazılmaz" }).waitFor();
    expectedFailures = [];
    await dialog.getByTestId("name-input").fill("Faturalar");
    await shot(page, "1440-light-yeni-klasor.png");
    await dialog.getByTestId("name-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/mkdir"), { path: "Belgeler", name: "Faturalar" });
    await row(page, "Faturalar").waitFor();
    assert.equal(await page.getByTestId("note").innerText(), "“Faturalar” klasörü oluşturuldu.");
    assert.equal(await activeText(page), "Yeni klasör", "the focus returns to the button");
    // Yeniden adlandır: the name is selected up to its extension; a taken name is refused.
    await row(page, "notlar.txt").getByRole("button", { name: "Yeniden adlandır: notlar.txt" }).click();
    dialog = page.getByRole("dialog", { name: "Yeniden adlandır" });
    const nameInput = dialog.getByTestId("name-input");
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "name-input");
    assert.deepEqual(await nameInput.evaluate((i) => [i.value, i.selectionStart, i.selectionEnd]), ["notlar.txt", 0, 6]);
    expectedFailures = ["/api/rename"];
    await nameInput.fill("rapor.pdf");
    await dialog.getByTestId("name-go").click();
    await dialog.getByTestId("name-error").filter({ hasText: "aynı adla bir öge var; üzerine yazılmaz" }).waitFor();
    expectedFailures = [];
    await nameInput.fill("notlar-eski.txt");
    await dialog.getByTestId("name-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/rename"), { path: "Belgeler", name: "notlar.txt", to: "notlar-eski.txt" });
    await row(page, "notlar-eski.txt").waitFor();
    assert.equal(await page.getByTestId("note").innerText(), "“notlar.txt” → “notlar-eski.txt”");
    // Taşı: the dialog browses folders only (dirs=1), never into the moved folder or a package's folder.
    await row(page, "Faturalar").getByLabel("Seç: Faturalar").check();
    await row(page, "rapor.pdf").getByLabel("Seç: rapor.pdf").check();
    await page.getByTestId("sel-move").click();
    dialog = page.getByRole("dialog", { name: "2 öge taşı" });
    const moveList = dialog.locator(".files-move-list li");
    await moveList.first().waitFor();
    assert.equal(await dialog.locator(".modal-desc").innerText(), `/srv/Belgeler · ${bytes(1.2 * MB)}`);
    assert.equal(await dialog.getByTestId("move-block").innerText(), "Seçilenler zaten bu klasörde; hedef klasörün içine girin.");
    assert(await dialog.getByTestId("move-go").isDisabled());
    assert.deepEqual(await moveList.evaluateAll((lis) => lis.map((li) => li.dataset.klasor)), ["arsiv", "Faturalar"]);
    assert(await dialog.getByRole("button", { name: "Faturalar içine gir" }).isDisabled(), "not into itself");
    assert.equal(await dialog.locator('li[data-klasor="Faturalar"] .files-move-note').innerText(), "taşınan klasör");
    assert(gets("/api/list").at(-1).query.includes("dirs=1"));
    await dialog.getByTestId("move-up").click();
    await dialog.locator('li[data-klasor="indirilenler"]').waitFor();
    assert.equal(await activeText(page), "/srv", "the place the dialog moved to takes the focus");
    await dialog.getByRole("button", { name: "indirilenler içine gir" }).click();
    await dialog.getByRole("button", { name: ".gecici içine gir" }).click();
    await dialog.getByTestId("move-block").filter({ hasText: "qBittorrent bu klasöre yazıyor; buraya taşınmaz." }).waitFor();
    assert(await dialog.getByTestId("move-go").isDisabled());
    await dialog.locator(".files-crumbs").getByRole("button", { name: "/srv" }).click();
    await dialog.getByRole("button", { name: "Filmler içine gir" }).click();
    await dialog.locator('li[data-klasor="2024"]').waitFor();
    assert(await dialog.getByTestId("move-go").isEnabled());
    await shot(page, "1440-light-tasi.png");
    expectedFailures = ["/api/move"];
    force("/api/move", fail(409, "“rapor.pdf” hedefte zaten var; üzerine yazılmaz"));
    await dialog.getByTestId("move-go").click();
    await dialog.getByTestId("move-error").filter({ hasText: "“rapor.pdf” hedefte zaten var; üzerine yazılmaz" }).waitFor();
    expectedFailures = [];
    await dialog.getByTestId("move-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/move"), { path: "Belgeler", names: ["Faturalar", "rapor.pdf"], to: "Filmler" });
    assert.equal(await page.getByTestId("note").innerText(), "2 öge taşındı → /srv/Filmler");
    await row(page, "rapor.pdf").waitFor({ state: "detached" });
    assert.equal(await page.getByTestId("selection").count(), 0);
    // Çöpe at: a plain confirmation (it comes back from Çöp kutusu).
    await row(page, "notlar-eski.txt").getByRole("button", { name: "Çöpe at: notlar-eski.txt" }).click();
    dialog = page.getByRole("dialog", { name: "“notlar-eski.txt” çöpe taşınsın mı?" });
    assert.equal(await dialog.locator(".modal-desc").innerText(), "/srv/Belgeler/notlar-eski.txt");
    assert.equal(await dialog.locator(".modal-list li").first().innerText(), "Çöp kutusundan geri yüklenebilir; disk alanı çöp boşaltılınca açılır.");
    assert.equal(await activeText(page), "Vazgeç", "the safe button has the focus");
    await dialog.getByTestId("remove-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/trash"), { path: "Belgeler", names: ["notlar-eski.txt"] });
    await row(page, "notlar-eski.txt").waitFor({ state: "detached" });
    assert.equal(await page.getByTestId("note").innerText(), "“notlar-eski.txt” çöpe taşındı.");
    await noStyles(page, "after the changes");
    await page.context().close();

    // ================= the text editor: CodeMirror under the CSP, save with the version, the leave guard
    page = await open();
    await page.goto(url("#/dosyalar?sekme=srv"));
    await row(page, "ayar.yml").getByRole("button", { name: "ayar.yml", exact: true }).click();
    let sheet = page.getByRole("dialog", { name: "ayar.yml" });
    await sheet.locator("[data-testid=editor-box] .cm-content").waitFor();
    assert.equal((await queryOf(page)).get("dosya"), "ayar.yml", "the open file is in the address");
    assert.equal(await sheet.locator(".modal-desc").innerText(), `/srv · ${bytes(Buffer.byteLength(AYAR))} · UTF-8 · LF`);
    assert.equal(await sheet.getByTestId("language").innerText(), "YAML");
    assert.equal(await sheet.getByTestId("root-save").count(), 0, "no root warning in the user area");
    assert.equal(await sheet.getByTestId("read-only").count(), 0);
    const save = sheet.getByTestId("save");
    assert(await save.isDisabled());
    assert(await page.locator(".cm-content").evaluate((c) => c.contains(document.activeElement) || c === document.activeElement), "the text has the focus");
    assert.equal(await guarded(page), false);
    await page.locator(".cm-content").click();
    await page.keyboard.press("Control+End");
    await page.keyboard.type("debug: true");
    assert(await save.isEnabled());
    await sheet.getByTestId("dirty").waitFor();
    assert.equal(await sheet.getByTestId("position").innerText(), "Satır 3, Sütun 12");
    assert(await guarded(page), "unsaved text: closing the tab asks");
    await shot(page, "1440-light-duzenleyici.png");
    await page.keyboard.press("ControlOrMeta+s");
    await sheet.getByTestId("saved").filter({ hasText: "Kaydedildi." }).waitFor();
    assert.deepEqual(lastPost("/api/text/save"), { path: "ayar.yml", text: AYAR + "debug: true", encoding: "utf-8", version: SHA("a") });
    assert(await save.isDisabled());
    assert.equal(await guarded(page), false);
    await page.keyboard.type("\n# iki");
    await save.click();
    await sheet.getByTestId("saved").waitFor();
    assert(await save.isDisabled());
    assert.equal(lastPost("/api/text/save").version, SHA("b"), "the next save sends the version the last one returned");
    await page.waitForFunction(() => document.querySelector(".cm-content")?.contains(document.activeElement));
    // A file changed since it was opened is refused; "Yeniden aç" asks, then reads it again.
    expectedFailures = ["/api/text/save"];
    srv.children["ayar.yml"].version = SHA("z");
    await page.keyboard.type("\nx: 1");
    await save.click();
    await sheet.getByTestId("save-error").filter({ hasText: "dosya siz açtıktan sonra değişti; kaydedilmedi (yeniden açın)" }).waitFor();
    expectedFailures = [];
    await sheet.getByTestId("reopen").click();
    await sheet.getByTestId("discard-ask").waitFor();
    assert.equal(await activeText(page), "Düzenlemeye dön");
    const reads = gets("/api/text").length;
    await sheet.getByTestId("discard").click();
    await h.waitFor(() => gets("/api/text").length === reads + 1, "the file is read again");
    await sheet.locator(".cm-content").filter({ hasText: "# iki" }).waitFor();
    assert.equal(await sheet.getByTestId("dirty").count(), 0);
    // Another encoding reads it again in that encoding.
    await sheet.getByTestId("encoding").selectOption("cp1254");
    await sheet.locator(".modal-desc").filter({ hasText: "Türkçe (Windows-1254)" }).waitFor();
    assert.equal(new URLSearchParams(gets("/api/text").at(-1).query).get("enc"), "cp1254");
    // Kapat and Esc with unsaved changes ask inside the sheet; "Değişiklikleri at" closes without saving.
    await page.locator(".cm-content").click();
    await page.keyboard.type("z");
    const saves = posts("/api/text/save").length;
    await sheet.getByTestId("editor-close").click();
    await sheet.getByTestId("discard-ask").filter({ hasText: "Kaydedilmemiş değişiklikler atılsın mı?" }).waitFor();
    await shot(page, "1440-light-duzenleyici-sor.png");
    await sheet.getByTestId("keep-editing").click();
    assert.equal(await sheet.getByTestId("discard-ask").count(), 0);
    assert(await page.locator(".cm-content").evaluate((c) => c.contains(document.activeElement)), "back in the text");
    await page.keyboard.press("Escape");
    await sheet.getByTestId("discard-ask").waitFor();
    await sheet.getByTestId("discard").click();
    await sheet.waitFor({ state: "detached" });
    assert.equal((await queryOf(page)).get("dosya"), null);
    assert.equal(posts("/api/text/save").length, saves, "discarding saves nothing");
    assert.equal(await activeText(page), "ayar.yml", "the focus returns to the file's name");
    // Back with unsaved changes asks too, inside the sheet, then goes back.
    await row(page, "Cep").getByRole("button", { name: "Cep", exact: true }).click();
    await folder(page, "Cep");
    await row(page, "a.txt").getByRole("button", { name: "a.txt", exact: true }).click();
    sheet = page.getByRole("dialog", { name: "a.txt" });
    await sheet.locator(".cm-content").waitFor();
    await page.locator(".cm-content").click();
    await page.keyboard.type("b");
    await page.goBack();
    await sheet.getByTestId("discard-ask").waitFor();
    await page.waitForFunction(() => new URLSearchParams(location.hash.split("?")[1]).get("dosya") === "a.txt");
    assert.equal((await queryOf(page)).get("yol"), "Cep", "the sheet held the address");
    await sheet.getByTestId("discard").click();
    await page.waitForFunction(() => location.hash === "#/dosyalar?sekme=srv");
    await sheet.waitFor({ state: "detached" });
    await row(page, "Belgeler").getByRole("button", { name: "Belgeler", exact: true }).click();
    await folder(page, "Belgeler");
    // Read-only files: too big (first part), another account's, a binary refused by the server.
    await row(page, "baskasi.conf").getByRole("button", { name: "baskasi.conf", exact: true }).click();
    sheet = page.getByRole("dialog", { name: "baskasi.conf" });
    await sheet.getByTestId("read-only").filter({ hasText: "Salt okunur: dosyanın sahibi başka bir hesap; düzenlenemez." }).waitFor();
    assert.match(await sheet.getByTestId("text-view").innerText(), /^x=1\n?$/);
    assert.equal(await sheet.getByTestId("save").count(), 0);
    assert.equal(await sheet.getByTestId("editor-download").getAttribute("href"), "/api/download?path=Belgeler%2Fbaskasi.conf");
    await sheet.getByTestId("editor-close").click();
    await sheet.waitFor({ state: "detached" });
    await page.goto(url("#/dosyalar?sekme=srv&dosya=b%C3%BCy%C3%BCk.log"));
    sheet = page.getByRole("dialog", { name: "büyük.log" });
    await sheet.getByTestId("read-only").filter({ hasText: "Dosya büyük: yalnız ilk bölümü salt okunur gösteriliyor." }).waitFor();
    await shot(page, "1440-light-salt-okunur.png");
    await sheet.getByRole("button", { name: "Kapat" }).first().click();
    await sheet.waitFor({ state: "detached" });
    expectedFailures = ["/api/text"];
    await row(page, "zeytin.bin").getByRole("button", { name: "Düzenle: zeytin.bin" }).click();
    sheet = page.getByRole("dialog", { name: "zeytin.bin" });
    await sheet.getByTestId("editor-error").filter({ hasText: "metin dosyası değil" }).waitFor();
    expectedFailures = [];
    await page.keyboard.press("Escape");
    await sheet.waitFor({ state: "detached" });
    await page.context().close();

    // The bundle cannot load: the file is shown read-only and nothing is saved.
    expectedFailures = ["duzenleyici.js"];
    page = await open();
    await page.route("**/duzenleyici.js", (r) => r.fulfill({ status: 404, body: "yok" }));
    await page.goto(url("#/dosyalar?sekme=srv&dosya=ayar.yml"));
    sheet = page.getByRole("dialog", { name: "ayar.yml" });
    await sheet.getByTestId("read-only").filter({ hasText: "Düzenleyici yüklenemedi; dosya salt okunur gösteriliyor." }).waitFor();
    assert.equal(await sheet.getByTestId("save").count(), 0);
    assert.match(await sheet.getByTestId("text-view").innerText(), /^sunucu:/);
    await page.context().close();
    expectedFailures = [];

    // ================= Çöp kutusu: restore (a taken name gets a number), permanent delete, empty
    page = await open();
    await page.goto(url("#/dosyalar?sekme=cop"));
    const trashCard = page.getByTestId("trash");
    const trow = (name) => trashCard.locator(`tr[data-oge=${JSON.stringify(name)}]`);
    await trow("notlar-eski.txt").waitFor();
    assert.deepEqual(await trashCard.locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.oge)), ["notlar-eski.txt", "ayar.yml", "Tatil", "(bozuk kayıt)"]);
    assert.equal(await page.getByTestId("trash-summary").innerText(), `4 öge · ${bytes(trash.reduce((s, t) => s + (t.size ?? 0), 0))}`);
    assert.equal((await trow("Tatil").locator(".files-marks").innerText()).replace(/\s+/g, " "), "Nereden: /srv/Belgeler 1 öge");
    assert.equal(await trow("Tatil").getByRole("link", { name: "/srv/Belgeler" }).getAttribute("href"), "#/dosyalar?sekme=srv&yol=Belgeler");
    assert.equal(await trow("ayar.yml").getByRole("link", { name: "/srv" }).getAttribute("href"), "#/dosyalar?sekme=srv");
    assert.equal(await trow("Tatil").locator(".files-date").innerText(), when(NOW - 4 * DAY));
    assert.equal(await trow("(bozuk kayıt)").locator(".files-marks").innerText().then((t) => t.replace(/\s+/g, " ")), "Nereden: bilinmiyor Bozuk kayıt; yalnız kalıcı silinir");
    assert.equal(await trow("(bozuk kayıt)").getByRole("button", { name: /^Geri yükle/ }).count(), 0);
    await shot(page, "1440-light-cop.png", true);
    // Two restored at once (the broken one ticked too is left out of the restore).
    await trow("ayar.yml").getByLabel("Seç: ayar.yml").check();
    await trow("Tatil").getByLabel("Seç: Tatil").check();
    await trow("(bozuk kayıt)").getByLabel("Seç: (bozuk kayıt)").check();
    assert.equal(await page.getByTestId("trash-selection").locator(".files-selection-text").innerText(), `3 öge seçili · ${bytes(120 + 3 * MB)}`);
    await page.getByTestId("sel-restore").click();
    await page.getByTestId("trash-note").filter({ hasText: "2 öge geri yüklendi." }).waitFor();
    assert.deepEqual(lastPost("/api/trash/restore"), { ids: ["1791844000000-0000aaaa", "1791843000000-0000bbbb"] });
    assert.equal(await page.getByTestId("trash-note").innerText(), "2 öge geri yüklendi. “ayar.yml” adı doluydu; “ayar (2).yml” olarak geri yüklendi.");
    assert(srv.children["ayar (2).yml"] && srv.children.Belgeler.children.Tatil, "back where they were");
    await trow("Tatil").waitFor({ state: "detached" });
    // A refusal is shown in the server's words.
    expectedFailures = ["/api/trash/restore"];
    force("/api/trash/restore", fail(400, "çöp kaydı bozuk; kalıcı silin"));
    await trow("notlar-eski.txt").getByRole("button", { name: "Geri yükle: notlar-eski.txt" }).click();
    await page.getByTestId("trash-failure").filter({ hasText: "çöp kaydı bozuk; kalıcı silin" }).waitFor();
    expectedFailures = [];
    // Kalıcı sil needs the typed word.
    await trow("(bozuk kayıt)").getByRole("button", { name: "Kalıcı sil: (bozuk kayıt)" }).click();
    dialog = page.getByRole("dialog", { name: "“(bozuk kayıt)” kalıcı silinsin mi?" });
    assert(await dialog.getByTestId("purge-go").isDisabled());
    await dialog.getByLabel("Onaylamak için onayla yazın").fill("onay");
    assert(await dialog.getByTestId("purge-go").isDisabled());
    await dialog.getByLabel("Onaylamak için onayla yazın").fill("ONAYLA");
    await dialog.getByTestId("purge-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/trash/purge"), { ids: ["1791842000000-0000cccc"] });
    await page.getByTestId("trash-note").filter({ hasText: "“(bozuk kayıt)” kalıcı silindi." }).waitFor();
    // Çöpü boşalt: the whole trash after the typed word.
    await page.getByTestId("trash-empty").click();
    dialog = page.getByRole("dialog", { name: "Çöp boşaltılsın mı?" });
    assert.deepEqual(await dialog.locator(".modal-list li").allInnerTexts(), ["1 öge kalıcı silinir.", `${bytes(Buffer.byteLength("alışveriş listesi\n"))} disk alanı boşalır.`, "Geri alınamaz."]);
    await dialog.getByLabel("Onaylamak için onayla yazın").fill("onayla");
    await shot(page, "1440-light-cop-bosalt.png");
    await dialog.getByTestId("purge-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/trash/empty"), { confirm: "onayla" });
    await page.getByText("Çöp boş", { exact: true }).waitFor();
    assert.equal(await page.getByTestId("trash-note").innerText(), "Çöp boşaltıldı: 1 öge kalıcı silindi.");
    assert(await page.getByTestId("trash-empty").isDisabled());
    await page.context().close();
    makeTrash();

    // ================= Sistem dosyaları: the same browser as root, the typed name, the root-save warning
    page = await open();
    await page.goto(url("#/dosyalar?sekme=srv&yol=Filmler"));
    await row(page, "2024").waitFor();
    await page.getByRole("tablist", { name: "Dosyalar bölümleri" }).getByRole("tab", { name: "Sistem dosyaları" }).click();
    await page.getByTestId("root-warning").waitFor();
    assert.equal((await queryOf(page)).get("yol"), null, "the other tab's folder stays behind");
    await row(page, "etc").waitFor();
    assert.equal(gets("/api/sistem/list").filter((r) => r.query.includes("Filmler")).length, 0, "Sistem dosyaları never opened /Filmler");
    assert.equal(await page.getByTestId("root-warning").innerText(),
      "Root olarak çalışır. Sunucunun bütün dosyaları burada değiştirilebilir ve silinebilir; çöp kutusu yoktur, silinen geri gelmez.");
    assert.deepEqual(await names(page), ["boot", "etc", "srv", "tmp", "vmlinuz"]);
    assert.equal(await page.getByTestId("folder-title").innerText(), "/");
    assert.equal(await row(page, "vmlinuz").locator(".files-name .cell-note").innerText(), "Sembolik bağlantı");
    assert.deepEqual(await row(page, "vmlinuz").locator(".files-row-actions [data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem)), ["adlandir", "tasi", "sil"]);
    assert.equal(await page.getByTestId("list").locator('[data-eylem="paylas"], [data-eylem="paylasim-yonet"], [data-eylem="cop"]').count(), 0, "no shares and no trash");
    assert.equal(await page.getByTestId("gezgin").count(), 0);
    await shot(page, "1440-light-sistem.png", true);
    // Several items: "onayla"; the server refuses a mount point.
    await row(page, "boot").getByLabel("Seç: boot").check();
    await row(page, "tmp").getByLabel("Seç: tmp").check();
    await page.getByTestId("sel-remove").click();
    dialog = page.getByRole("dialog", { name: "2 öge kalıcı silinsin mi?" });
    assert.deepEqual(await dialog.locator(".modal-list li").allInnerTexts().then((l) => l.slice(0, 2)),
      ["Geri alınamaz; Sistem dosyalarında çöp kutusu yoktur.", "Root olarak silinir; sistemin kendi dosyaları da silinebilir."]);
    await dialog.getByLabel("Onaylamak için onayla yazın").fill("onayla");
    expectedFailures = ["/api/sistem/delete"];
    await dialog.getByTestId("remove-go").click();
    await dialog.getByTestId("remove-error").filter({ hasText: "“boot” bir bağlama noktası ya da içinde bağlı bir disk var; silinmez" }).waitFor();
    expectedFailures = [];
    assert.deepEqual(lastPost("/api/sistem/delete"), { path: "", names: ["boot", "tmp"], confirm: "onayla" });
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "detached" });
    await page.getByTestId("sel-clear").click();
    // One item: its own name is the word, exactly what the request carries.
    await row(page, "etc").getByRole("button", { name: "etc", exact: true }).click();
    await folder(page, "etc");
    await row(page, "hosts").getByRole("button", { name: "Kalıcı sil: hosts" }).click();
    dialog = page.getByRole("dialog", { name: "“hosts” kalıcı silinsin mi?" });
    assert.equal(await dialog.locator(".modal-desc").innerText(), "/etc/hosts");
    const word = dialog.getByLabel("Onaylamak için hosts yazın");
    await word.fill("onayla");
    assert(await dialog.getByTestId("remove-go").isDisabled());
    await word.fill("hosts");
    await shot(page, "1440-light-sistem-sil.png");
    await dialog.getByTestId("remove-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/sistem/delete"), { path: "etc", names: ["hosts"], confirm: "hosts" });
    await row(page, "hosts").waitFor({ state: "detached" });
    assert.equal(await page.getByTestId("note").innerText(), "“hosts” kalıcı silindi.");
    // The editor saves as root and says so.
    await row(page, "ssh").getByRole("button", { name: "ssh", exact: true }).click();
    await folder(page, "etc/ssh");
    assert.deepEqual(await crumbs(page), ["/", "etc", "ssh"]);
    await row(page, "sshd_config").getByRole("button", { name: "sshd_config", exact: true }).click();
    sheet = page.getByRole("dialog", { name: "sshd_config" });
    await sheet.locator(".cm-content").waitFor();
    assert.equal(await sheet.getByTestId("root-save").innerText(), "Root olarak kaydedilir. Dosyanın sahibi ve izinleri korunur; önceki içerik geri alınamaz.");
    assert.equal(await sheet.getByTestId("language").innerText(), "Yapılandırma");
    await page.locator(".cm-content").click();
    await page.keyboard.press("Control+End");
    await page.keyboard.type("X11Forwarding no\n");
    await sheet.getByTestId("save").click();
    await sheet.getByTestId("saved").waitFor();
    assert.deepEqual(lastPost("/api/sistem/text/save"), { path: "etc/ssh/sshd_config", text: "Port 22\nPermitRootLogin no\nX11Forwarding no\n", encoding: "utf-8", version: SHA("d") });
    await shot(page, "1440-light-sistem-duzenleyici.png");
    await sheet.getByTestId("editor-close").click();
    await sheet.waitFor({ state: "detached" });
    // Upload, new folder and move go to the root backend's paths.
    await page.getByTestId("crumbs").getByRole("button", { name: "/", exact: true }).click();
    await folder(page, "");
    await row(page, "tmp").getByRole("button", { name: "tmp", exact: true }).click();
    await folder(page, "tmp");
    await page.getByTestId("upload-input").setInputFiles([{ name: "not.txt", mimeType: "text/plain", buffer: Buffer.from("kök") }]);
    await row(page, "not.txt").waitFor();
    assert.deepEqual(h.requests.filter((r) => r.path === "/api/sistem/upload").map((r) => [r.query, r.body]), [["?path=tmp&name=not.txt", { size: 4, text: "kök" }]]);
    await row(page, "not.txt").getByRole("button", { name: "Taşı: not.txt" }).click();
    dialog = page.getByRole("dialog", { name: "“not.txt” taşı" });
    await dialog.getByTestId("move-up").click();
    await dialog.getByRole("button", { name: "srv içine gir" }).click();
    await dialog.getByTestId("move-where").filter({ hasText: /^srv$/ }).waitFor();
    await dialog.getByTestId("move-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/sistem/move"), { path: "tmp", names: ["not.txt"], to: "srv" });
    assert(gets("/api/sistem/list").some((r) => r.query === "?path=&dirs=1"));
    assert(posts("/api/move").every((b) => b.path !== "tmp"), "nothing went to the user area's backend");
    await page.context().close();

    // The root backend refuses (not another Tailscale device, the internet name): the tab says why.
    expectedFailures = ["/api/sistem/state"];
    force("/api/sistem/state", fail(403, "Sistem görünümü yalnız başka bir Tailscale cihazından kullanılır"));
    page = await open();
    const listsBefore = gets("/api/sistem/list").length;
    await page.goto(url("#/dosyalar?sekme=sistem"));
    const refused = page.getByTestId("system-refused");
    await refused.waitFor();
    assert.equal(await refused.locator(".empty-title").innerText(), "Sistem dosyaları yalnız Tailscale'den açılır");
    assert.equal(await refused.locator(".empty-text").innerText(),
      "Sistem görünümü yalnız başka bir Tailscale cihazından kullanılır. Bu görünüm sunucunun bütün dosyalarını root olarak açar; yalnız başka bir Tailscale cihazından, Konsol'un tailnet adresiyle kullanılır.");
    assert.equal(gets("/api/sistem/list").length, listsBefore, "nothing is listed after a refusal");
    await shot(page, "1440-light-sistem-red.png");
    force("/api/sistem/state", fail(404, "bulunamadı"));
    await page.reload();
    await refused.waitFor();
    await page.context().close();
    expectedFailures = [];
    // On the internet name (HTTPS) the tab is not offered at all (the page polls there: no event stream).
    expectedFailures = ["/api/konsol/olaylar"];
    page = await h.newHttpsPage("panel.example.org", { timezoneId: TZ });
    await page.goto("https://panel.example.org/#/dosyalar?sekme=sistem");
    await page.getByTestId("depolama").waitFor();
    assert.deepEqual(await page.getByRole("tablist", { name: "Dosyalar bölümleri" }).getByRole("tab").allInnerTexts(),
      ["Depolama", "Sunucu klasörleri", "Çöp kutusu", "Paylaşımlar"]);
    await page.context().close();
    expectedFailures = [];

    // ================= 1440, 390 and 320 in both themes: no style attribute, no horizontal scroll
    srv = makeSrv();
    sys = makeSys();
    const VIEWS = [
      ["depolama", "#/dosyalar", "[data-testid=folders] tbody tr"],
      ["srv", "#/dosyalar?sekme=srv", "[data-testid=list] tbody tr"],
      ["srv-belgeler", "#/dosyalar?sekme=srv&yol=Belgeler", "[data-testid=list] tbody tr"],
      ["paket-klasoru", "#/dosyalar?sekme=srv&yol=indirilenler%2F.gecici", "[data-testid=guard-here]"],
      ["cop", "#/dosyalar?sekme=cop", "[data-testid=trash] tbody tr"],
      ["sistem", "#/dosyalar?sekme=sistem&yol=etc", "[data-testid=list] tbody tr"],
      ["duzenleyici", "#/dosyalar?sekme=srv&dosya=ayar.yml", ".cm-content"],
      ["salt-okunur", "#/dosyalar?sekme=srv&dosya=b%C3%BCy%C3%BCk.log", "[data-testid=text-view]"],
    ];
    for (const colorScheme of ["light", "dark"]) {
      for (const [width, height, mobile] of [[1440, 900, false], [390, 844, true], [320, 640, true]]) {
        page = await open({ colorScheme, viewport: { width, height }, ...(mobile ? { isMobile: true, hasTouch: true, reducedMotion: "reduce" } : {}) });
        for (const [name, hash, ready] of VIEWS) {
          await page.goto(url(hash));
          await page.locator(ready).first().waitFor();
          await settle(page);
          await noStyles(page, `${width} ${colorScheme} ${name}`);
          assert(await noHorizontalScroll(page), `no horizontal scroll: ${width} ${colorScheme} ${name}`);
          await shot(page, `${width}-${colorScheme}-${name}.png`, !["duzenleyici", "salt-okunur"].includes(name));
        }
        // The move dialog and a selection on this width.
        await page.goto(url("#/dosyalar?sekme=srv"));
        await row(page, "Belgeler").waitFor();
        await row(page, "ayar.yml").getByLabel("Seç: ayar.yml").check();
        await settle(page);
        assert(await noHorizontalScroll(page), `selection: ${width} ${colorScheme}`);
        await shot(page, `${width}-${colorScheme}-secim.png`);
        await row(page, "Belgeler").getByRole("button", { name: "Taşı: Belgeler" }).click();
        await page.getByRole("dialog", { name: "“Belgeler” taşı" }).locator(".files-move-list li").first().waitFor();
        await settle(page);
        await noStyles(page, `${width} ${colorScheme} move`);
        await shot(page, `${width}-${colorScheme}-tasi.png`);
        if (width === 390) {
          assert.equal(await row(page, "ayar.yml").evaluate((el) => getComputedStyle(el).display), "grid", "rows are cards on a phone");
          const box = await page.getByRole("dialog", { name: "“Belgeler” taşı" }).boundingBox();
          assert(Math.abs(box.y + box.height - height) <= 1 && box.width === width, "a bottom sheet on a phone");
        }
        await page.keyboard.press("Escape");
        await page.context().close();
      }
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol phase 4b Dosyalar under the production CSP — Depolama (the disk with what the user area holds and its mount, " +
      "the trash in short with its link, Gezgin's address or the way to install it, the top folders in Turkish order with size, count and who " +
      "uses them: applications' binds with their access and container path, a bind of the whole user area for every folder, folder shares, " +
      "a package's own folder with its owner, binds outside the listed folders, a failed read), Sunucu klasörleri (order with numbers, sizes " +
      "and times, share marks, Paylaş / Paylaşımı yönet links with yeni= and paylasim=, the filter with Turkish case rules in ara=, ticks and " +
      "Tümünü seç, folders as history entries, a folder that cannot be opened, a package's folder and one that holds it, uploads from the " +
      "picker with a skipped name, the queue one at a time with progress, cancel waiting and running uploads, a refusal, a drop, the leave " +
      "guard, download, new folder, rename, move with dirs=1 and its blocks, trash), the editor (the real CodeMirror bundle, YAML, the " +
      "position, Ctrl+S and Kaydet with the returned version, a 409 with Yeniden aç, another encoding, Kapat / Esc / Back with unsaved " +
      "changes, read-only files, a binary refused, the bundle failing to load), Çöp kutusu (restore with a numbered name, a broken record, " +
      "a refusal, permanent delete and empty with the typed word), Sistem dosyaları (root warning, no trash or shares, the typed name, a " +
      "mount point refused, the root-save warning, upload and move on /api/sistem/*, the tab's own folder, the tailnet-only refusal, no tab " +
      "over HTTPS), 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
