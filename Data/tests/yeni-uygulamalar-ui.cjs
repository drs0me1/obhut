/* Konsol's new interface, phase 2 (DD-258): Genel Bakış, Uygulamalar and an application's page in the
   committed build under Data/console/yeni, with the production CSP and fixture replies for every endpoint
   they read or post to (yeni-harness.cjs). The applications are the server's containers (DD-271). Fails on
   any console error, CSP violation or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulamalar-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737 addresses, example names); shapes as in api/sema.ts
const cell = (durum, adresler = [], uyari = "", not = "") => ({ durum, adresler, uyari, not });
const hcell = (durum, adresler = [], not = "", uyari = "") => ({ durum, adresler, not, uyari });
const app = (name, o) => ({ id: "konteyner:" + name, ad: name, tur: "konteyner", aciklama: "", konteyner: name, durum: "calisiyor", tailscale: cell("yok"),
  internet: cell("yok"), kaynak: { cpu: null, bellek: null }, guncelleme: "sabit", adres: { tailscale: null, internet: null }, eylemler: [], revizyon: null, ...o });
const VPN_NOTE = "WireGuard cihazları yalnız internete çıkar; bu sunucudaki hizmetlere ulaşamaz.";
const OK_CHECKS = [
  { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" },
  { id: "caddy", name: "Caddy", status: "ok", detail: "çalışıyor" },
  { id: "dns", name: "DNS", status: "ok", detail: "yanıt veriyor" }];
const BAD_CHECK = { id: "units", name: "2 eski konteyner birimi başarısız", status: "bad", detail: "konsol-filebrowser ve konsol-deneme her açılışta hata veriyor." };
const WARNING = { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda okunabilir.",
  duzelt: { bolum: "yayinlar", hedef: "paylasim" } };
const LOCKED = "Bu adın çalışan konteyneri kayıtlı yöneticiyle eşleşmiyor; işlem yapılmadı.";

function apps() {
  return [
    // Made outside Konsol: it can be adopted; nothing in its image has been checked yet.
    app("wiki", { aciklama: "Ekibinizin notlarını ve belgelerini tarayıcıdan düzenleyin.", tailscale: cell("acik", ["wiki.ev"]), internet: cell("acik", ["wiki.example.com"]),
      guncelleme: "bilinmiyor", adres: { tailscale: "http://wiki.ev", internet: "https://wiki.example.com" }, eylemler: ["durdur", "yeniden-baslat", "kaldir"] }),
    app("medya", { aciklama: "Film ve dizi arşivinizi yayınlayın.", tailscale: cell("acik", ["medya.ev"]), internet: cell("kismen", ["203.0.113.10:8920/tcp"], "", "Yalnız akış portu"),
      kaynak: { cpu: 3.2, bellek: 220200960 }, guncelleme: "yeni", adres: { tailscale: "http://medya.ev", internet: null },
      eylemler: ["durdur", "yeniden-baslat", "guncelle", "kaldir"], revizyon: "rev-medya-7" }),
    // Not reached from anywhere, and its detail carries no container facts (sema allows null).
    app("yedek", { aciklama: "Konteyner · docker.io/example/yedek", eylemler: ["durdur", "yeniden-baslat", "kaldir"], revizyon: "rev-yedek-2" }),
    app("notlar", { aciklama: "Konteyner · docker.io/library/nginx", durum: "durduruldu", tailscale: cell("kapali"), internet: cell("kapali"), guncelleme: "guncel",
      eylemler: ["baslat", "kaldir"] }),
    // Its definition cannot be changed now (the server holds every action back).
    app("galeri", { aciklama: "Konteyner · docker.io/example/galeri", tailscale: cell("acik", ["galeri.ev"]), internet: cell("acik", ["http://203.0.113.10:8080"], "Şifresiz HTTP"),
      adres: { tailscale: "http://galeri.ev", internet: null }, revizyon: "rev-galeri-3" }),
  ];
}
const ALTYAPI = { podman: "5.4.2", calisiyor: true, imaj: 3, kullanilmayan_imaj: 1, birim: 2, ag: 3 };

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-244", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: 1791845000, sampled_at: 1791845000, cpu: 2.0, mem: { total: 8375186227, used: 696254464 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "bad", read_at: 1791844900, checks: [BAD_CHECK, ...OK_CHECKS] },
  guncelleme: { kurulu: "2026.08.06-v2-244", kurulu_surum: "1.0.0", son: "2026.08.06-v2-244", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false,
    denetlendi: 1791845000, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: 1791845000, alan: "ev", hizmetler: [], hatalar: [], uyarilar: [WARNING],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "sunucu", surum: "1.80.0", adresler: ["100.64.0.2"], cikis_dugumu: true },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, durduruldu: false, not: VPN_NOTE, aglar: [] }, sertifikalar: [] } },
  uygulamalar: { read_at: 1791845000, hatalar: [], altyapi: ALTYAPI, items: apps() },
  ag: { read_at: 1791845000, sampled_at: 1791845000, rx: 10240, tx: 38912 },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
};

const row = (id, ad, cells, ayrinti = []) => ({ id, ad, tur: "konteyner", aciklama: "Konteyner", uygulama: id, calisiyor: true, yerel: hcell("yok"), tailscale: hcell("yok"),
  wireguard: hcell("kapali", [], VPN_NOTE), internet: hcell("yok"), yayinlar: [], ayrinti, ...cells });
const box = (o) => ({ imaj: "", ag: "", kullanici: "", baslangic: null, saglik: "", yeniden_baslama: 0, portlar: [], baglamalar: [], ...o });
const IMAGES = { medya: "docker.io/example/medya@sha256:" + "a".repeat(64), wiki: "ghcr.io/example/wiki@sha256:" + "b".repeat(64),
  notlar: "docker.io/library/nginx@sha256:" + "c".repeat(64), galeri: "docker.io/example/galeri@sha256:" + "d".repeat(64) };
const ACCESS = {
  "konteyner:medya": row("konteyner:medya", "medya", { yerel: hcell("acik", ["127.0.0.1:18096 → 8096/tcp"]), tailscale: hcell("acik", ["medya.ev"]),
    internet: hcell("kismen", ["203.0.113.10:8920/tcp"], "Yalnız akış portu") },
  [{ baslik: "Konteyner portu", deger: "127.0.0.1:18096 → 8096/tcp" }, { baslik: "DNS", deger: "medya.ev → 100.64.0.2" }]),
  "konteyner:wiki": row("konteyner:wiki", "wiki", { yerel: hcell("acik", ["127.0.0.1:8093"]), tailscale: hcell("acik", ["wiki.ev"]), internet: hcell("acik", ["wiki.example.com"]) },
    [{ baslik: "Caddy", deger: "wiki.example.com → 127.0.0.1:8093" }]),
  "konteyner:notlar": row("konteyner:notlar", "notlar", { yerel: hcell("kapali"), tailscale: hcell("kapali"), internet: hcell("kapali") }),
  "konteyner:galeri": row("konteyner:galeri", "galeri", { yerel: hcell("acik", ["203.0.113.10:8080 → 80/tcp"]), tailscale: hcell("acik", ["galeri.ev"]),
    internet: hcell("acik", ["http://203.0.113.10:8080"], "", "Şifresiz HTTP") }, [{ baslik: "Konteyner portu", deger: "203.0.113.10:8080 → 80/tcp" }]),
};
const BOXES = {
  "konteyner:medya": box({ imaj: IMAGES.medya, ag: "konsol", kullanici: "1000:1000", baslangic: 1791800000, saglik: "healthy", yeniden_baslama: 2,
    portlar: [{ host_ip: "127.0.0.1", host_port: 18096, container_port: 8096, protocol: "tcp", scope: "local" },
      { host_ip: "203.0.113.10", host_port: 8920, container_port: 8920, protocol: "tcp", scope: "public" }],
    baglamalar: [{ tur: "bind", kaynak: "/srv/filmler", hedef: "/data/filmler", yazilabilir: true, ad: "" },
      { tur: "bind", kaynak: "/srv/kitaplik", hedef: "/library", yazilabilir: false, ad: "" },
      { tur: "volume", kaynak: "/var/lib/containers/storage/volumes/medya-config/_data", hedef: "/config", yazilabilir: true, ad: "medya-config" }] }),
  "konteyner:wiki": box({ imaj: IMAGES.wiki, ag: "wiki", kullanici: "1000:1000", baslangic: 1791700000,
    baglamalar: [{ tur: "bind", kaynak: "/srv/belgeler", hedef: "/data", yazilabilir: true, ad: "" }, { tur: "volume", kaynak: "/v/wiki-db", hedef: "/db", yazilabilir: true, ad: "wiki-db" }] }),
  "konteyner:notlar": box({ imaj: IMAGES.notlar, ag: "konsol" }),
  "konteyner:galeri": box({ imaj: IMAGES.galeri, ag: "konsol", baslangic: 1791750000,
    portlar: [{ host_ip: "203.0.113.10", host_port: 8080, container_port: 80, protocol: "tcp", scope: "public" }] }),
};
// Phase 4a: the application page reads its container's own detail (konteynerler/ayrinti), Uygulamalar reads
// Podman's counts (konteynerler/liste); yeni-uygulama-ekle-ui.cjs covers them, here they only have to answer.
const crow = (o) => ({ id: "", image: "", state: "running", unit: "", network: "", ports: [], started: null, restarts: 0, health: "", live: true, source: "konsol",
  revision: null, actions: [], restricted_reason: "", cpu_percent: null, memory_bytes: null, busy: null, listening: null, update: null, ...o });
const EDITABLE = ["ports", "mounts", "environment", "command", "autostart", "restart", "cpus", "memory", "image", "network", "user"];
const generic = (name, o) => ({ name, image: IMAGES[name], network: "bridge", ports: [], mounts: [], environment: [], command: [], autostart: true, manual_stop: false,
  restart: "on-failure", cpus: "", memory: "", user: "downloads", ...o });
const CONTAINERS = {
  medya: crow({ name: "medya", id: "a1b2c3d4e5f6", image: IMAGES.medya, unit: "konsol-medya.service", network: "konsol", management_id: "konsol:medya",
    revision: "rev-medya-7", health: "healthy", actions: ["stop", "restart", "save", "remove", "image-update"],
    ports: [{ host_ip: "127.0.0.1", host_port: 18096, container_port: 8096, protocol: "tcp", scope: "local" },
      { host_ip: "203.0.113.10", host_port: 8920, container_port: 8920, protocol: "tcp", scope: "public" }],
    update: { state: "var", channel: "docker.io/example/medya:latest", error: "", checked_at: 1791844000 },
    config: generic("medya", { ports: [{ scope: "local", host_port: 18096, container_port: 8096, protocol: "tcp" },
      { scope: "public", host_port: 8920, container_port: 8920, protocol: "tcp", public_ack: true }],
    mounts: [{ type: "bind", source: "/srv/filmler", destination: "/data/filmler", read_only: false }, { type: "bind", source: "/srv/kitaplik", destination: "/library", read_only: true },
      { type: "volume", source: "medya-config", destination: "/config", read_only: false }],
    environment: [{ name: "TZ", value: "Europe/Istanbul", secret: false }] }),
    editable: EDITABLE, effective_autostart: true, user: "1000:1000", command: "" }),
  wiki: crow({ name: "wiki", id: "b2c3d4e5f6a1", image: IMAGES.wiki, network: "wiki", source: "external", actions: ["stop", "restart", "remove", "adopt"],
    ports: [{ host_ip: "127.0.0.1", host_port: 8093, container_port: 3000, protocol: "tcp", scope: "local" }], user: "1000:1000", command: "" }),
  notlar: crow({ name: "notlar", image: IMAGES.notlar, state: "stopped", live: false, unit: "konsol-notlar.service", network: "konsol", management_id: "konsol:notlar",
    actions: ["start", "save", "remove", "image-update"], revision: "rev-notlar-1",
    update: { state: "guncel", channel: "docker.io/library/nginx:1.27-alpine", error: "", checked_at: 1791844000 },
    config: generic("notlar", { image_ref: "docker.io/library/nginx:1.27-alpine" }), editable: EDITABLE, effective_autostart: true, user: "", command: "" }),
  galeri: crow({ name: "galeri", id: "c3d4e5f6a1b2", image: IMAGES.galeri, unit: "konsol-galeri.service", network: "konsol", management_id: "konsol:galeri",
    revision: "rev-galeri-3", restricted_reason: LOCKED, ports: [{ host_ip: "203.0.113.10", host_port: 8080, container_port: 80, protocol: "tcp", scope: "public" }],
    config: generic("galeri", { ports: [{ scope: "public", host_port: 8080, container_port: 80, protocol: "tcp", public_ack: true }] }),
    editable: EDITABLE, effective_autostart: true, user: "", command: "" }),
};
const LOG = Array.from({ length: 30 }, (_, i) => `2026-10-13T01:${String(10 + i).padStart(2, "0")}:00+03:00 medya[812]: satır ${i + 1}`);
const BUSY = "Bir uygulama işlemi sürüyor; bitince yeniden deneyin.";
const LOG_ERROR = "Konteynerin günlüğü okunamadı.";

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-uygulamalar-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8769", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, count, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies
h.handlers["/api/konsol/konteynerler/ayrinti"] = ({ query }) => (CONTAINERS[query.get("ad")] ? { body: CONTAINERS[query.get("ad")] } : { status: 404, body: { error: "Konteyner bulunamadı" } });
// Podman holds the containers the list shows (none on a clean server).
h.handlers["/api/konsol/konteynerler/liste"] = () => ({ body: { read_at: 1791845000, runtime: { version: "5.4.2", ok: true, error: "" },
  containers: Object.values(CONTAINERS).filter((c) => data.uygulamalar.items.some((a) => a.konteyner === c.name)),
  images: [], volumes: [], networks: [], storage: { images: 3, containers: 3, size: 1610612736 }, resource_errors: {} } });
h.handlers["/api/konsol/konteynerler/islem"] = ({ method, query }) => (method === "GET"
  ? { body: { id: query.get("id"), action: "image-update", name: "medya", state: "done", step: "", result: { changed: true, version: "10.9.1" } } } : undefined);
h.handlers["/api/konsol/uygulamalar/ayrinti"] = ({ query }) => {
  const id = query.get("id");
  const item = data.uygulamalar.items.find((a) => a.id === id);
  if (!item) return { status: 404, body: { error: "Uygulama bulunamadı." } };
  return { body: { uygulama: item, konteyner: BOXES[id] ?? null, erisim: ACCESS[id] ?? null } };
};
h.handlers["/api/konsol/uygulamalar/gunluk"] = ({ query }) => (query.get("id") === "konteyner:yedek"
  ? { status: 503, body: { error: LOG_ERROR } }
  : { body: { satirlar: LOG, kesik: true } });
const islemReplies = [];  // replies for the next POSTs, before the default 202
let jobSeq = 0;
h.handlers["/api/konsol/uygulamalar/islem"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  // Every application is a container: the container broker names its job.
  return islemReplies.shift() ?? { status: 202, body: { id: body.id, eylem: body.eylem, is: `is-${++jobSeq}` } };
};
const onarimReplies = [];
h.handlers["/api/konsol/onarim"] = ({ method }) => (method === "POST" ? onarimReplies.shift() ?? { status: 202, body: { kip: "onar" } } : undefined);

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const active = (page) => page.evaluate(() => {
  const e = document.activeElement;
  return e ? (e.getAttribute("aria-label") || e.textContent || "").trim().replace(/\s+/g, " ") : "";
});
const rowNames = (page) => page.locator(".app-table tbody .app-name").allInnerTexts();
const lastPost = (key) => posts(key).at(-1);
const job = (o) => ({ tur: "konteyner", id: "is-0", ad: "medya · İşlem", durum: "calisiyor", adim: "", bitis: null, ...o });
const dateTime = (s) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }).format(new Date(s * 1000));
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= Genel Bakış: problems first, each with its one fix
    let page = await newPage();
    await page.goto(url("#/genel"));
    const h1 = page.locator("main h1");
    assert.equal(await h1.innerText(), "Genel Bakış");
    await page.locator("#saglik-baslik").filter({ hasText: "2 konu dikkat istiyor" }).waitFor();
    await page.getByTestId("health-sub").filter({ hasText: "Diğer 3 denetim sorunsuz · son denetim 1 dakika önce" }).waitFor();
    const problems = page.locator(".problem");
    assert.equal(await problems.count(), 2);
    const bad = page.locator('.problem-danger[data-kind="saglik"]');
    assert.equal(await bad.locator("strong").innerText(), BAD_CHECK.name);
    assert.equal(await bad.locator(".problem-text span").innerText(), BAD_CHECK.detail);
    const repair = bad.getByRole("button", { name: "Denetle ve onar" });
    await page.waitForFunction(() => !document.querySelector('.problem-danger button[disabled]'));
    const warn = page.locator('.problem-warning[data-kind="erisim"]');
    assert.equal(await warn.locator("strong").innerText(), WARNING.metin);
    assert.equal(await warn.locator(".problem-text span").innerText(), "Erişim · Paylaşımlar");
    assert.equal(await warn.getByRole("link", { name: "Düzelt" }).getAttribute("href"), "#/erisim?sekme=adresler&yayinla=paylasim", "its fix (phase 3)");
    assert.equal(await page.getByRole("link", { name: "Tüm denetimler" }).getAttribute("href"), "#/sistem?sekme=saglik", "Sistem → Sağlık (phase 4a)");
    // Applications: every container in the list, in its order.
    await page.locator(".app-card").first().waitFor();
    assert.deepEqual(await page.locator(".app-card").evaluateAll((els) => els.map((e) => e.dataset.uygulama)),
      ["konteyner:wiki", "konteyner:medya", "konteyner:yedek", "konteyner:notlar", "konteyner:galeri"]);
    assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (5)");
    assert.equal(await page.getByTestId("all-apps").getAttribute("href"), "#/uygulamalar");
    const card = (id) => page.locator(`.app-card[data-uygulama="${id}"]`);
    // "Aç" is only ever the application's own address, in a new tab.
    assert.deepEqual(await page.locator('.app-card [data-eylem="ac"]').evaluateAll((els) => els.map((e) => [e.getAttribute("href"), e.getAttribute("target"), e.getAttribute("rel"),
      e.getAttribute("aria-label")])), [["http://wiki.ev", "_blank", "noopener noreferrer", "wiki uygulamasını yeni sekmede aç"],
      ["http://medya.ev", "_blank", "noopener noreferrer", "medya uygulamasını yeni sekmede aç"], ["http://galeri.ev", "_blank", "noopener noreferrer", "galeri uygulamasını yeni sekmede aç"]]);
    assert.equal(await card("konteyner:wiki").locator(".pill").innerText(), "Çalışıyor");
    assert.equal(await card("konteyner:wiki").getByRole("link", { name: "wiki ayrıntıları" }).getAttribute("href"), "#/uygulamalar/konteyner:wiki");
    assert.equal(await card("konteyner:medya").locator(".app-line").innerText(), "medya.ev · internette kısmen açık · yeni sürüm var");
    assert.equal(await card("konteyner:yedek").locator('[data-eylem="ac"]').count(), 0, "nothing to open");
    assert.equal(await card("konteyner:yedek").locator(".app-line").innerText(), "Konteyner · docker.io/example/yedek");
    assert.equal(await card("konteyner:notlar").locator(".pill").innerText(), "Durdurulmuş");
    assert.equal(await card("konteyner:notlar").locator('[data-eylem="ac"]').count(), 0, "a closed one has no address");
    assert.equal(await card("konteyner:galeri").locator(".app-line").innerText(), "galeri.ev · internette açık · Şifresiz HTTP");
    // Resources, network and the server.
    assert.equal(await page.getByTestId("cpu").innerText(), "%2");
    assert.equal(await page.getByTestId("memory").innerText(), "664 MB / 7,8 GB");
    assert.equal(await page.getByTestId("disk").innerText(), "12,7 GB / 250,7 GB");
    await page.getByTestId("rx").filter({ hasText: "10 KB/s" }).waitFor();
    assert.equal(await page.getByTestId("tx").innerText(), "38 KB/s");
    assert.equal(await page.getByTestId("network").locator(".pill").innerText(), "Canlı");
    assert.equal(await page.getByTestId("net-error").count(), 0);
    assert.deepEqual(await page.getByTestId("server").locator("dd").allInnerTexts(), ["Debian GNU/Linux 13 (trixie)", "5 gün", "100.64.0.2", "203.0.113.10", "1.0.0 · güncel"]);
    await noStyles(page, "genel");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-genel-sorunlar.png", true);

    // Repair: a confirmation first (the page may not answer while Caddy or Konsol restarts).
    await repair.click();
    const repairDialog = page.getByRole("dialog", { name: "Denetim ve onarım başlasın mı?" });
    await repairDialog.waitFor();
    assert.equal(await page.evaluate(() => document.querySelector(".app").inert), true, "the page behind the dialog is inert");
    assert.equal(await active(page), "Vazgeç", "the safe answer has focus");
    await page.keyboard.press("Control+K");
    assert.equal(await page.getByRole("dialog", { name: "Komut paleti" }).count(), 0, "the palette waits for the answer");
    for (let n = 0; n < 4; n++) await page.keyboard.press("Tab");
    assert(await repairDialog.evaluate((d) => d.contains(document.activeElement)), "Tab stays in the dialog");
    await page.keyboard.press("Escape");
    await repairDialog.waitFor({ state: "detached" });
    assert.equal(await active(page), "Denetle ve onar", "focus returns to the fix");
    // A refused start shows the backend's words in the dialog.
    expectedFailures = ["/api/konsol/onarim"];
    onarimReplies.push({ status: 409, body: { error: "Bir denetim zaten sürüyor." } });
    await repair.click();
    await repairDialog.getByRole("button", { name: "Onar" }).click();
    await repairDialog.getByRole("alert").filter({ hasText: "Bir denetim zaten sürüyor." }).waitFor();
    await repairDialog.getByRole("button", { name: "Vazgeç" }).click();
    await repairDialog.waitFor({ state: "detached" });
    data.onarim = { ...data.onarim, calisiyor: true };
    await repair.click();
    await repairDialog.getByRole("button", { name: "Onar" }).click();
    await repairDialog.waitFor({ state: "detached" });
    assert.deepEqual(posts("onarim"), [{ kip: "onar" }, { kip: "onar" }], "the repair POST body");
    await bad.getByRole("button", { name: "Onarım sürüyor…" }).waitFor();
    assert(await bad.getByRole("button", { name: "Onarım sürüyor…" }).isDisabled());
    await page.locator(".health-note").filter({ hasText: "Denetim ve onarım başladı; ilerlemesi İşlemler'de görünür." }).waitFor();
    // The repair job runs and ends: health and the repair state are read again.
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("islemler", { items: [job({ tur: "onarim", id: "onarim", ad: "Denetle ve onar", adim: "Güvenlik duvarı" })] });
    await page.getByRole("button", { name: "İşlemler, 1 çalışıyor" }).waitFor();
    const healthReads = count("saglik"), repairReads = count("onarim");
    data.onarim = { ...data.onarim, calisiyor: false };
    data.saglik = { status: "ok", read_at: 1791845000, checks: [...OK_CHECKS, { ...BAD_CHECK, status: "ok", name: "Birimler" }] };
    push("islemler", { items: [job({ tur: "onarim", id: "onarim", ad: "Denetle ve onar", durum: "tamam", bitis: 1791845100 })] });
    await waitFor(() => count("saglik") > healthReads && count("onarim") > repairReads, "health and repair read again after the repair");
    await page.locator("#saglik-baslik").filter({ hasText: "1 konu dikkat istiyor" }).waitFor();
    assert.equal(await page.locator('.problem[data-kind="saglik"]').count(), 0);
    assert.equal(await page.locator(".health-note").count(), 0, "the started note goes when the repair ends");
    await page.context().close();
    expectedFailures = [];

    // ================= the calm state
    data.saglik = { status: "ok", read_at: 1791844900, checks: [...OK_CHECKS, { ...BAD_CHECK, status: "ok", name: "Birimler" }] };
    data.erisim = { ...data.erisim, uyarilar: [] };
    page = await newPage();
    await page.goto(url("#/genel"));
    await page.locator("#saglik-baslik").filter({ hasText: "Her şey yolunda" }).waitFor();
    await page.getByTestId("health-sub").filter({ hasText: "4 denetim sorunsuz · son denetim 1 dakika önce" }).waitFor();
    assert.equal(await page.locator(".problems").count(), 0);
    assert.match(await page.getByTestId("health").getAttribute("class"), /health-ok/);
    assert.equal(await page.locator(".desktop-tools .chip").innerText(), "Her şey yolunda");
    await shot(page, "1440-light-genel-sakin.png");
    await page.context().close();

    // ================= repair locked (internet channel): the fix is shown, disabled, with the reason
    data.saglik = { status: "bad", read_at: 1791844900, checks: [BAD_CHECK, ...OK_CHECKS] };
    data.erisim = { ...data.erisim, uyarilar: [WARNING] };
    data.onarim = { calisiyor: false, kurulu: true, baslatilabilir: false, rapor: null };
    page = await newPage();
    await page.goto(url("#/genel"));
    const lock = page.getByTestId("repair-lock");
    await lock.filter({ hasText: "Onarım yalnız Tailscale adresinden başlatılır." }).waitFor();
    const locked = page.getByRole("button", { name: "Denetle ve onar" });
    assert(await locked.isDisabled(), "repair cannot start here");
    assert.equal(await locked.getAttribute("aria-describedby"), await lock.getAttribute("id"));
    assert.equal(await page.locator(".problem-warning").getByRole("link", { name: "Düzelt" }).count(), 1, "Erişim's fix stays");
    await shot(page, "1440-light-genel-kilitli.png");
    await page.context().close();
    data.onarim = { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null };

    // ================= the network card reads every 5 s only while Genel Bakış is shown and visible
    page = await newPage({}, { clock: true });
    await page.goto(url("#/genel"));
    await page.getByTestId("rx").filter({ hasText: "10 KB/s" }).waitFor();
    await page.waitForTimeout(100);
    const n0 = count("ag");
    await page.clock.runFor(5000);
    await waitFor(() => count("ag") === n0 + 1, "a read after 5 s");
    await page.clock.runFor(5000);
    await waitFor(() => count("ag") === n0 + 2, "another after 10 s");
    const visibility = (hidden) => page.evaluate((value) => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => value });
      document.dispatchEvent(new Event("visibilitychange"));
    }, hidden);
    await visibility(true);
    await page.clock.runFor(15000);
    await page.waitForTimeout(150);
    assert.equal(count("ag"), n0 + 2, "no reads while the tab is hidden");
    await visibility(false);
    await waitFor(() => count("ag") === n0 + 3, "a read as soon as the tab is visible again");
    // A failed read says so and is no longer live; the next one that answers clears it.
    expectedFailures = ["/api/konsol/ag"];
    h.status["/api/konsol/ag"] = 503;
    await page.clock.runFor(5000);
    await page.getByTestId("net-error").filter({ hasText: "Ağ bilgisi okunamadı." }).waitFor();
    assert.equal(await page.getByTestId("network").locator(".pill").count(), 0, "not live while the reads fail");
    delete h.status["/api/konsol/ag"];
    await page.clock.runFor(5000);
    await page.getByTestId("net-error").waitFor({ state: "detached" });
    await page.getByTestId("network").locator(".pill").filter({ hasText: "Canlı" }).waitFor();
    expectedFailures = [];
    const n1 = count("ag");
    await page.locator('.sidebar [data-nav="uygulamalar"]').click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.clock.runFor(15000);
    await page.waitForTimeout(150);
    assert.equal(count("ag"), n1, "no reads on another page");
    await page.context().close();

    // ================= a clean server: no applications yet, and each page leads to adding one
    data.uygulamalar = { ...data.uygulamalar, items: [], altyapi: { ...ALTYAPI, imaj: 0, kullanilmayan_imaj: 0, birim: 0, ag: 1 } };
    page = await newPage();
    await page.goto(url("#/genel"));
    const overviewApps = page.locator(".overview-apps");
    await overviewApps.locator(".empty-title").filter({ hasText: "Henüz uygulama yok" }).waitFor();
    assert.equal(await overviewApps.locator(".empty-text").innerText(),
      "Bir imajdan konteyner çalıştırabilir ya da Podman'da var olan bir konteyneri yönetime alabilirsiniz.");
    assert.equal(await page.locator(".app-card").count(), 0);
    assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (0)");
    assert.equal(await page.locator('.sidebar [data-badge="uygulamalar"]').count(), 0, "no count beside an empty section");
    await noStyles(page, "genel, no applications");
    await shot(page, "1440-light-genel-bos.png", true);
    await overviewApps.getByRole("link", { name: "Uygulama ekle" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.getByTestId("page-desc").filter({ hasText: "Henüz uygulama yok" }).waitFor();
    const appsEmpty = page.getByTestId("apps-empty");
    await appsEmpty.waitFor();
    assert.equal(await appsEmpty.locator(".empty-title").innerText(), "Henüz uygulama yok");
    assert.equal(await appsEmpty.locator(".empty-text").innerText(),
      "Bir imajdan konteyner çalıştırabilir ya da Podman'da var olan bir konteyneri yönetime alabilirsiniz.");
    assert.equal(await page.locator(".app-table").count(), 0);
    const emptyChips = page.getByRole("group", { name: "Süzgeç" }).getByRole("button");
    assert.deepEqual((await emptyChips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")), ["Tümü 0", "Çalışan 0", "Durdurulmuş 0", "Dikkat 0"]);
    await page.getByTestId("add-app").getByText("Konsol dışında kurulmuş, yönetime alınabilecek konteyner yok.").waitFor();
    assert.deepEqual(await page.getByTestId("add-app").locator("[data-secenek]").evaluateAll((els) => els.map((e) => e.dataset.secenek)), ["imaj", "benimse"]);
    assert.equal(await page.getByTestId("infra-line").innerText(), "Podman 5.4.2 · 0 imaj · 0 birim · 1 ağ · kullanılmayan imaj yok");
    assert.equal(await page.getByTestId("empty-add").innerText(), "Uygulama ekle");
    await noStyles(page, "uygulamalar, no applications");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-uygulamalar-bos.png", true);
    await page.getByTestId("empty-add").click();
    assert.equal(await active(page), "Uygulama ekle", "the empty state's button leads to the add card");
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H2");
    assert(await page.getByTestId("add-app").evaluate((el) => el.contains(document.activeElement)));
    await page.context().close();
    data.uygulamalar = { ...data.uygulamalar, items: apps(), altyapi: ALTYAPI };

    // ================= the palette lists the applications and opens their pages
    page = await newPage();
    await page.goto(url("#/genel"));
    await page.locator(".app-card").first().waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.waitFor();
    assert.deepEqual(await palette.locator('[aria-labelledby="palet-grup-1"] .palette-label').allInnerTexts(), ["wiki", "medya", "yedek", "notlar", "galeri"]);
    await palette.getByRole("combobox").fill("medy");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya");
    await page.locator("main h1").filter({ hasText: "medya" }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the application's heading has focus");
    await page.context().close();

    // ================= Uygulamalar: summary, filters, search, all in the address
    page = await newPage();
    await page.goto(url("#/uygulamalar"));
    await page.getByTestId("page-desc").filter({ hasText: "5 uygulama · 4 çalışıyor · 1 durdurulmuş · 2 dikkat" }).waitFor();
    assert.equal(await page.locator('.sidebar [data-badge="uygulamalar"]').innerText(), "5", "the sidebar counts the same applications");
    const chips = page.getByRole("group", { name: "Süzgeç" }).getByRole("button");
    assert.deepEqual((await chips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")), ["Tümü 5", "Çalışan 4", "Durdurulmuş 1", "Dikkat 2"]);
    assert.equal(await chips.filter({ hasText: "Tümü" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await rowNames(page), ["wiki", "medya", "yedek", "notlar", "galeri"]);
    assert(await page.locator(".app-table thead").isVisible(), "a table on a wide screen");
    const tr = (id) => page.locator(`tr[data-uygulama="${id}"]`);
    const chipsOf = (id) => tr(id).locator(".access-chip").evaluateAll((els) => els.map((e) => [e.querySelector(".access-text").textContent, e.className.replace("access-chip ", "")]));
    assert.equal(await tr("konteyner:medya").locator(".app-desc").innerText(), "Film ve dizi arşivinizi yayınlayın", "the item's own description");
    assert.equal(await tr("konteyner:medya").locator(".col-state").innerText(), "Çalışıyor");
    assert.deepEqual(await chipsOf("konteyner:medya"), [["Tailscale", "chip-tone-ok"], ["İnternet · kısmen", "chip-tone-accent"]]);
    assert.equal(await tr("konteyner:medya").locator(".col-res").innerText(), "%3 · 210 MB");
    assert.equal(await tr("konteyner:medya").locator(".col-ver").innerText(), "Yeni sürüm");
    const rowOpen = tr("konteyner:medya").locator('[data-eylem="ac"]');
    assert.deepEqual([await rowOpen.getAttribute("href"), await rowOpen.getAttribute("target"), await rowOpen.getAttribute("rel"), await rowOpen.getAttribute("aria-label")],
      ["http://medya.ev", "_blank", "noopener noreferrer", "medya uygulamasını yeni sekmede aç"]);
    assert.deepEqual(await chipsOf("konteyner:galeri"), [["Tailscale", "chip-tone-ok"], ["İnternet · Şifresiz HTTP", "chip-tone-warning"]]);
    assert.equal(await tr("konteyner:galeri").locator('[data-eylem="ac"]').getAttribute("href"), "http://galeri.ev");
    assert.equal(await tr("konteyner:notlar").locator(".col-state").innerText(), "Durdurulmuş");
    assert.deepEqual(await chipsOf("konteyner:notlar"), [["Tailscale kapalı", "chip-tone-neutral"], ["İnternet kapalı", "chip-tone-neutral"]]);
    assert.equal(await tr("konteyner:notlar").locator(".col-ver").innerText(), "Güncel");
    assert.equal(await tr("konteyner:notlar").locator('[data-eylem="ac"]').count(), 0);
    assert.equal(await tr("konteyner:wiki").locator(".col-ver").innerText(), "—", "not checked yet: nothing shown, not an error");
    assert.equal(await tr("konteyner:wiki").locator(".col-res").innerText(), "—", "unknown resources");
    assert.equal(await tr("konteyner:yedek").locator(".col-access").innerText(), "—", "no cell applies");
    assert.equal(await tr("konteyner:yedek").getByRole("link", { name: "yedek ayrıntıları" }).getAttribute("href"), "#/uygulamalar/konteyner:yedek");
    assert.equal(await page.getByTestId("apps-empty").count(), 0);
    await noStyles(page, "uygulamalar");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-uygulamalar.png", true);

    await chips.filter({ hasText: "Dikkat" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=dikkat");
    assert.deepEqual(await rowNames(page), ["medya", "galeri"], "a newer image or a warning on how it is reached");
    assert.equal(await chips.filter({ hasText: "Dikkat" }).getAttribute("aria-pressed"), "true");
    await chips.filter({ hasText: "Durdurulmuş" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=durmus");
    assert.deepEqual(await rowNames(page), ["notlar"]);
    await chips.filter({ hasText: "Çalışan" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=calisan");
    assert.deepEqual(await rowNames(page), ["wiki", "medya", "yedek", "galeri"]);
    await chips.filter({ hasText: "Tümü" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    // Turkish case rules: "NOTLARINI" is "notlarını" (a plain toLowerCase would give "notlarini"), "ARŞİVİNİZİ"
    // is "arşivinizi" (a plain toLowerCase keeps a combining dot on each i).
    const search = page.getByRole("searchbox", { name: "Uygulama ara" });
    await search.fill("NOTLARINI");
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ara=NOTLARINI");
    assert.deepEqual(await rowNames(page), ["wiki"]);
    await search.fill("ARŞİVİNİZİ");
    assert.deepEqual(await rowNames(page), ["medya"]);
    await page.getByRole("status").filter({ hasText: "1 uygulama gösteriliyor" }).waitFor();
    // The view comes back from the address.
    await page.goto(url("#/uygulamalar?suzgec=dikkat&ara=ar%C5%9Fiv"));
    await page.reload();
    await page.locator(".app-table").waitFor();
    assert.equal(await search.inputValue(), "arşiv");
    assert.equal(await chips.filter({ hasText: "Dikkat" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await rowNames(page), ["medya"]);
    await page.goto(url("#/uygulamalar?suzgec=durmus&ara=wiki"));
    await page.getByText("Aramayla eşleşen uygulama yok.").waitFor();
    await page.getByRole("button", { name: "Tüm uygulamaları göster" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    assert.equal(await search.inputValue(), "");
    assert.equal((await rowNames(page)).length, 5, "the filter and the search both cleared");
    // An empty filter says so.
    data.uygulamalar = { ...data.uygulamalar, items: data.uygulamalar.items.map((a) => (a.id === "konteyner:notlar" ? { ...a, durum: "calisiyor" } : a)) };
    await page.goto(url("#/uygulamalar?suzgec=durmus"));
    await page.reload();
    await page.getByText("Durdurulmuş uygulama yok.").waitFor();
    assert.equal(await page.getByTestId("apps-empty").count(), 0, "a filter that matches nothing is not an empty server");
    data.uygulamalar = { ...data.uygulamalar, items: apps() };
    // Adding an application, the infrastructure, and errors from the read model.
    await page.goto(url("#/uygulamalar"));
    await page.reload();
    const add = page.getByTestId("add-app");
    // Since phase 4a the add flows open over this page (yeni-uygulama-ekle-ui.cjs drives them).
    assert.deepEqual(await add.locator("[data-secenek]").evaluateAll((els) => els.map((e) => e.dataset.secenek)), ["imaj", "benimse"]);
    assert.equal(await add.getByTestId("open-create").getAttribute("href"), "#/uygulamalar?ekle=imaj");
    assert.equal(await add.getByTestId("open-adopt").getAttribute("href"), "#/uygulamalar?ekle=sahiplen");
    await add.getByText("Podman'da Konsol dışında kurulmuş 1 konteyner yönetime alınabilir.").waitFor();
    assert.equal(await page.getByTestId("infra-line").innerText(), "Podman 5.4.2 · 3 imaj · 2 birim · 3 ağ · 1 kullanılmayan imaj");
    assert.equal(await page.getByTestId("infra").getByRole("link", { name: "İmajlar" }).getAttribute("href"), "#/gelismis?sekme=podman&kaynak=imajlar");
    await page.getByRole("button", { name: "Uygulama ekle" }).click();
    assert.equal(await active(page), "Uygulama ekle", "the button leads to the panel");
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H2");
    // Keyboard order through the toolbar and the first row; the focus is visible.
    await search.focus();
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "Uygulama ekle");
    assert.equal(await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle), "solid", "a visible focus ring");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "wiki");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "wiki uygulamasını yeni sekmede aç");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "wiki ayrıntıları");
    data.uygulamalar = { ...data.uygulamalar, hatalar: ["Podman kullanılamıyor."] };
    await page.reload();
    await page.getByTestId("app-errors").getByText("Podman kullanılamıyor.").waitFor();
    assert.equal(await page.getByTestId("app-errors").getByRole("heading").innerText(), "Bazı bilgiler okunamadı");
    await shot(page, "1440-light-uygulamalar-hatalar.png", true);
    data.uygulamalar = { ...data.uygulamalar, hatalar: [] };

    // ================= an application's page
    await page.reload();
    await page.locator(".app-table").waitFor();
    await tr("konteyner:medya").getByRole("link", { name: "medya", exact: true }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya");
    await page.locator("main h1").filter({ hasText: "medya" }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the new page's heading has focus");
    assert.equal(await page.title(), "medya · Konsol");
    const trail = page.getByRole("navigation", { name: "Konum" });
    assert.equal(await trail.getByRole("link", { name: "Uygulamalar" }).getAttribute("href"), "#/uygulamalar");
    assert.equal(await trail.locator('[aria-current="page"]').innerText(), "medya");
    assert.equal(await page.locator('.sidebar [data-nav="uygulamalar"]').getAttribute("aria-current"), "true", "the section of the page");
    assert.equal(await page.getByTestId("app-state").innerText(), "Çalışıyor");
    await page.getByTestId("app-desc").filter({ hasText: "Film ve dizi arşivinizi yayınlayın · yeni sürüm var" }).waitFor();
    const actions = () => page.getByTestId("app-actions").locator("[data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem));
    assert.deepEqual(await actions(), ["ac", "yeniden-baslat", "durdur", "guncelle", "kaldir"]);
    const appOpen = page.getByTestId("app-actions").locator('[data-eylem="ac"]');
    assert.deepEqual([await appOpen.getAttribute("href"), await appOpen.getAttribute("target"), await appOpen.getAttribute("rel"), await appOpen.getAttribute("aria-label")],
      ["http://medya.ev", "_blank", "noopener noreferrer", "medya uygulamasını yeni sekmede aç"]);
    // Özet.
    const tabs = page.getByRole("tablist", { name: "medya bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Özet", "Erişim", "Depolama", "Ayarlar", "Günlük"]);
    assert.deepEqual(await tabs.evaluateAll((els) => els.map((e) => [e.getAttribute("aria-selected"), e.tabIndex])),
      [["true", 0], ["false", -1], ["false", -1], ["false", -1], ["false", -1]], "one tab stop");
    await page.getByTestId("started").filter({ hasText: dateTime(1791800000) }).waitFor();
    await page.getByTestId("source").waitFor();
    assert.equal(await page.getByTestId("source").locator(".pill").innerText(), "Konsol", "managed by Konsol");
    assert.equal(await page.getByTestId("app-health").innerText(), "Sağlıklı");
    assert.equal(await page.getByTestId("restarts").innerText(), "2");
    assert.equal(await page.getByTestId("account").innerText(), "1000:1000 · Dosyalar hesabı (yetkisiz)");
    assert.equal(await page.getByTestId("app-version").innerText(), "Yeni sürüm");
    assert.equal(await page.getByTestId("summary-state").getByText(/^docker\.io\/example\/medya/).innerText(), "docker.io/example/medya@sha256:aaaaaaaaaaaa…");
    assert.equal(await page.locator('[data-erisim="internet"] .cell-value').innerText(), "203.0.113.10:8920/tcp · Yalnız akış portu");
    assert.equal(await page.getByTestId("app-cpu").innerText(), "%3");
    assert.equal(await page.getByTestId("app-memory").innerText(), "210 MB");
    assert.equal(await page.getByTestId("update-state").innerText(), "Yeni sürüm var");
    await noStyles(page, "uygulama");
    await shot(page, "1440-light-uygulama-ozet.png", true);
    // Arrow keys move and choose; the address follows.
    await tabs.first().focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=erisim");
    assert.equal(await active(page), "Erişim");
    await page.keyboard.press("End");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=gunluk");
    assert.equal(await active(page), "Günlük");
    await page.keyboard.press("Home");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya");
    assert.equal(await active(page), "Özet");
    await page.keyboard.press("ArrowLeft");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=gunluk");
    assert.equal(await tabs.filter({ hasText: "Günlük" }).getAttribute("aria-selected"), "true");
    await tabs.filter({ hasText: "Özet" }).click();
    await page.getByTestId("summary-access").getByRole("button", { name: "Erişim ayrıntısı" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=erisim");
    // Erişim.
    const access = page.getByTestId("access");
    assert.deepEqual(await access.locator(".access-row strong").allInnerTexts(), ["Bu sunucu", "Tailscale", "WireGuard", "İnternet"]);
    assert.deepEqual(await access.locator(".access-row .pill").allInnerTexts(), ["Açık", "Açık", "Kapalı", "Kısmen"]);
    assert.equal(await access.locator('[data-hucre="wireguard"] .access-note').innerText(), VPN_NOTE);
    assert.equal(await access.locator('[data-hucre="internet"] .access-note').innerText(), "Yalnız akış portu");
    const technical = access.locator("details.technical");
    assert.equal(await technical.evaluate((d) => d.open), false);
    await technical.locator("summary").click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=erisim&teknik=1");
    assert.deepEqual(await technical.locator("dd").allInnerTexts(), ["127.0.0.1:18096 → 8096/tcp", "medya.ev → 100.64.0.2"]);
    // Since phase 3 it opens the Yayınla flow over this page (yeni-erisim-ui.cjs drives the flow).
    assert.equal(await access.getByRole("button", { name: "Erişimi düzenle" }).count(), 1);
    // The container's ports from its definition, an internet port marked.
    assert.deepEqual(await page.getByTestId("port-table").locator("tbody tr").evaluateAll((els) => els.map((e) => e.dataset.kapsam)), ["local", "public"]);
    await page.getByTestId("public-warning").waitFor();
    await shot(page, "1440-light-uygulama-erisim.png", true);
    await page.reload();
    await access.locator(".access-row").first().waitFor();
    assert.equal(await tabs.filter({ hasText: "Erişim" }).getAttribute("aria-selected"), "true", "the tab comes back from the address");
    assert.equal(await technical.evaluate((d) => d.open), true, "and the open details too");
    // Depolama, Ayarlar.
    await tabs.filter({ hasText: "Depolama" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=depolama&teknik=1");
    assert.deepEqual(await page.getByTestId("folders").locator(".mount").allInnerTexts(),
      ["/srv/filmler\nOkuma-yazma · konteynerde /data/filmler", "/srv/kitaplik\nSalt okunur · konteynerde /library"]);
    assert.deepEqual(await page.getByTestId("volumes").locator(".mount").allInnerTexts(), ["medya-config\nOkuma-yazma · konteynerde /config"]);
    // Since phase 4a the settings are here (yeni-uygulama-ekle-ui.cjs drives the definition editor).
    await tabs.filter({ hasText: "Ayarlar" }).click();
    await page.getByTestId("definition").waitFor();
    await page.getByTestId("definition-status").filter({ hasText: "Değişiklik yok." }).waitFor();
    // Günlük.
    const logReads = count("uygulamalar/gunluk");
    await tabs.filter({ hasText: "Günlük" }).click();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByTestId("log-lines").locator("li").count(), 30);
    assert.equal(await page.getByTestId("log-lines").locator("li").first().innerText(), LOG[0]);
    await page.getByText("Yalnız son 200 satır gösteriliyor.").waitFor();
    assert.equal(count("uygulamalar/gunluk"), logReads + 1);
    assert.equal(h.requests.filter((r) => r.path === "/api/konsol/uygulamalar/gunluk").at(-1).query, "?id=konteyner%3Amedya&satir=200");
    await page.getByRole("button", { name: "Yenile" }).click();
    await waitFor(() => count("uygulamalar/gunluk") === logReads + 2, "Yenile reads the log again");
    assert.equal(await page.getByTestId("live-switch").getAttribute("aria-checked"), "false");
    await shot(page, "1440-light-uygulama-gunluk.png", true);

    // Actions: each POST body exactly; the container job of a 202 shows in the activity drawer and its end
    // reads the page again.
    await tabs.filter({ hasText: "Özet" }).click();
    const detailReads = () => count("uygulamalar/ayrinti");
    const button = (eylem) => page.getByTestId("app-actions").locator(`[data-eylem="${eylem}"]`);
    await button("yeniden-baslat").click();
    await waitFor(() => posts("uygulamalar/islem").length === 1, "restart posted");
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:medya", eylem: "yeniden-baslat", revizyon: "rev-medya-7" });
    await page.getByTestId("action-note").filter({ hasText: "Yeniden başlatılıyor; ilerlemesi İşlemler'de görünür." }).waitFor();
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    const restartJob = `is-${jobSeq}`;
    push("islemler", { items: [job({ id: restartJob, ad: "medya · Yeniden başlat", adim: "Adım 1/2 · Durduruluyor" })] });
    await page.getByRole("button", { name: "İşlemler, 1 çalışıyor" }).click();
    const drawer = page.getByRole("dialog", { name: "İşlemler" });
    assert.equal(await drawer.locator(".job-name").innerText(), "medya · Yeniden başlat");
    assert.equal(await drawer.locator(".job-meta").innerText(), "Konteyner · Adım 1/2 · Durduruluyor");
    await page.keyboard.press("Escape");
    await drawer.waitFor({ state: "detached" });
    await page.waitForTimeout(200);
    const before = detailReads();
    push("islemler", { items: [job({ id: restartJob, ad: "medya · Yeniden başlat", durum: "tamam", bitis: 1791845300 })] });
    await waitFor(() => detailReads() > before, "the application is read again when its job ends");
    await page.waitForFunction(() => document.querySelector('[data-testid="action-note"]').textContent === "", null, { timeout: 5000 });

    // Durdur asks first; Esc keeps it running and gives the focus back.
    await button("durdur").click();
    const stopDialog = page.getByRole("dialog", { name: "medya durdurulsun mu?" });
    await stopDialog.waitFor();
    assert.equal(await active(page), "Vazgeç");
    assert.equal(await stopDialog.locator(".modal-desc").innerText(), "Kurulu kalır; istediğinizde başlatırsınız.");
    assert.deepEqual(await stopDialog.locator(".modal-list li").allInnerTexts(),
      ["Konteyner durur. Konsol'un yönettiği bir konteyner sunucu yeniden başlasa da kapalı kalır."]);
    for (let n = 0; n < 3; n++) await page.keyboard.press("Tab");
    assert(await stopDialog.evaluate((d) => d.contains(document.activeElement)), "Tab stays in the dialog");
    await shot(page, "1440-light-uygulama-durdur.png");
    await page.keyboard.press("Escape");
    await stopDialog.waitFor({ state: "detached" });
    assert.equal(await active(page), "Durdur", "focus back on Durdur");
    assert.equal(posts("uygulamalar/islem").length, 1, "nothing sent");
    // An error reply stays in the dialog, in the backend's words.
    expectedFailures = ["/api/konsol/uygulamalar/islem"];
    islemReplies.push({ status: 409, body: { error: BUSY } });
    await button("durdur").click();
    await stopDialog.locator('[data-onay="evet"]').click();
    await stopDialog.getByTestId("dialog-error").filter({ hasText: BUSY }).waitFor();
    assert.equal(await stopDialog.getByTestId("dialog-error").getAttribute("role"), "alert");
    await stopDialog.getByRole("button", { name: "Durdur" }).click();
    await stopDialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:medya", eylem: "durdur", revizyon: "rev-medya-7" });
    // A direct action's error shows on the page.
    islemReplies.push({ status: 409, body: { error: BUSY } });
    await button("yeniden-baslat").click();
    await page.getByTestId("action-error").filter({ hasText: BUSY }).waitFor();
    assert.equal(await page.getByTestId("action-error").getAttribute("role"), "alert");
    // Güncelle: what an image update does; its job's end reads the page again and says how it went.
    await button("guncelle").click();
    const updateDialog = page.getByRole("dialog", { name: "medya güncellensin mi?" });
    await updateDialog.waitFor();
    assert.equal(await updateDialog.locator(".modal-desc").innerText(), "Yeni sürüm yayınlanmış · docker.io/example/medya:latest");
    assert.deepEqual(await updateDialog.locator(".modal-list li").allInnerTexts(), ["İmajın etiketi yeniden çekilir ve yeni özetle karşılaştırılır.",
      "Özet değiştiyse konteyner yeni imajla yeniden oluşturulur; kısa bir kesinti olabilir.", "Kalıcı veriler bağlamalarda kalır; konteynerin yazılabilir katmanı silinir."]);
    await updateDialog.getByRole("button", { name: "Güncelle" }).click();
    await updateDialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:medya", eylem: "guncelle", revizyon: "rev-medya-7" });
    const updateJob = `is-${jobSeq}`;
    push("islemler", { items: [job({ id: updateJob, ad: "medya · İmaj güncelleme", adim: "İmaj indiriliyor" })] });
    await page.waitForTimeout(200);
    const beforeUpdate = detailReads();
    push("islemler", { items: [job({ id: updateJob, ad: "medya · İmaj güncelleme", durum: "tamam", bitis: 1791845400 })] });
    await waitFor(() => detailReads() > beforeUpdate, "read again when the image update ends");
    await page.getByTestId("action-note").filter({ hasText: "medya: imaj güncellendi (10.9.1)." }).waitFor();
    assert.equal(h.requests.filter((r) => r.path === "/api/konsol/konteynerler/islem").at(-1).query, `?id=${updateJob}`, "the operation's own record");
    // Kaldır: a sheet and the typed word; the body names only the container and its revision.
    await button("kaldir").click();
    const removeSheet = page.getByRole("dialog", { name: "medya kaldırılsın mı?" });
    await removeSheet.waitFor();
    assert.match(await removeSheet.getAttribute("class"), /modal-sheet/);
    const removeButton = removeSheet.locator('[data-onay="kaldir"]');
    assert(await removeButton.isDisabled(), "not before the word");
    const word = removeSheet.getByRole("textbox", { name: "Onaylamak için onayla yazın" });
    assert(await word.evaluate((el) => el === document.activeElement), "the word field has focus");
    await word.fill("onay");
    assert(await removeButton.isDisabled());
    await word.fill("ONAYLA");
    assert(await removeButton.isEnabled(), "Turkish case rules for the word");
    assert.equal(await removeSheet.locator(".modal-desc").innerText(), "Konteyner kaldırılır.");
    assert.deepEqual(await removeSheet.locator(".modal-list li").allInnerTexts(),
      ["Konteyner durdurulur ve kaldırılır; Konsol'da bir tanımı varsa o da silinir.",
        "Adlı birimler ve imaj kalır; Gelişmiş → Podman'dan silinir. Sunucu klasörlerine dokunulmaz."]);
    assert.equal(await removeSheet.locator(".modal-list li svg").count(), 2);
    assert.equal(await removeSheet.getByRole("checkbox").count(), 0, "nothing to choose: the container goes, its volumes and image stay");
    await shot(page, "1440-light-uygulama-kaldir.png");
    await removeButton.click();
    await removeSheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:medya", eylem: "kaldir", revizyon: "rev-medya-7" });
    await page.context().close();
    expectedFailures = [];

    // ================= a stopped container: no revision; its image can be pulled again; gone after its removal
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:notlar"));
    await page.locator("main h1").filter({ hasText: "notlar" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "Durdurulmuş" }).waitFor();
    await page.getByTestId("note-definition").waitFor();
    assert.deepEqual(await actions(), ["baslat", "imaj-guncelle", "kaldir"], "its image can be pulled again (phase 4a)");
    await page.getByRole("tab", { name: "Erişim" }).click();
    await page.getByTestId("ports").getByText("Port yayımlanmıyor; konteynere yalnız aynı ağdaki konteynerler ulaşır.").waitFor();
    await button("baslat").click();
    await waitFor(() => lastPost("uygulamalar/islem")?.eylem === "baslat", "start posted");
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:notlar", eylem: "baslat" }, "no revizyon when it is null");
    await button("kaldir").click();
    const removeBox = page.getByRole("dialog", { name: "notlar kaldırılsın mı?" });
    await removeBox.waitFor();
    await removeBox.getByRole("textbox").fill("onayla");
    await removeBox.locator('[data-onay="kaldir"]').click();
    await removeBox.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:notlar", eylem: "kaldir" });
    expectedFailures = ["/api/konsol/uygulamalar/ayrinti"];
    data.uygulamalar = { ...data.uygulamalar, items: data.uygulamalar.items.filter((a) => a.id !== "konteyner:notlar") };
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("islemler", { items: [job({ id: `is-${jobSeq}`, ad: "notlar · Kaldır" })] });
    await page.waitForTimeout(200);
    push("islemler", { items: [job({ id: `is-${jobSeq}`, ad: "notlar · Kaldır", durum: "tamam", bitis: 1791845500 })] });
    // A finished removal leads back to the list; the application's page is not read again.
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.context().close();
    data.uygulamalar = { ...data.uygulamalar, items: apps() };

    // ================= a container made outside Konsol, one whose definition is locked, one without
    // container facts, and an unknown id
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:wiki"));
    await page.locator("main h1").filter({ hasText: "wiki" }).waitFor();
    await page.getByTestId("app-actions").locator('[data-eylem="yonetime-al"]').waitFor();
    assert.deepEqual(await actions(), ["ac", "yeniden-baslat", "durdur", "yonetime-al", "kaldir"], "it is adopted before it is changed");
    assert.deepEqual([await button("ac").getAttribute("href"), await button("ac").getAttribute("target")], ["http://wiki.ev", "_blank"]);
    assert.equal(await button("yonetime-al").getAttribute("href"), "#/uygulamalar?ekle=sahiplen&ad=wiki");
    await page.getByTestId("started").waitFor();
    assert.equal(await page.getByTestId("source").locator(".pill").innerText(), "Dışarıda");
    assert.equal(await page.getByTestId("autostart").innerText(), "Konsol söz veremez\nBu konteyneri başka bir araç yönetir; açılışta ne olacağını o belirler.");
    assert.equal(await page.getByTestId("summary-update").count(), 0, "Konsol does not follow its image");
    assert.equal(await page.getByTestId("app-version").count(), 0, "an image not checked yet shows no version line");
    assert.equal(await page.getByTestId("app-health").innerText(), "Denetim tanımlı değil");
    assert.deepEqual([await page.getByTestId("app-cpu").innerText(), await page.getByTestId("app-memory").innerText()], ["—", "—"], "unknown resources");
    await page.getByText("Kaynak kullanımı şu an okunamıyor.").waitFor();
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    const external = page.getByTestId("settings-external");
    await external.waitFor();
    assert.equal(await external.locator(".empty-title").innerText(), "Bu konteyner Konsol dışında yönetiliyor");
    assert.equal(await external.getByTestId("settings-adopt").getAttribute("href"), "#/uygulamalar?ekle=sahiplen&ad=wiki");

    await page.goto(url("#/uygulamalar/konteyner:galeri?sekme=erisim"));
    await page.locator("main h1").filter({ hasText: "galeri" }).waitFor();
    const galeriInternet = page.locator('[data-hucre="internet"]');
    await galeriInternet.waitFor();
    assert.match(await galeriInternet.locator(".pill").getAttribute("class"), /pill-warning/);
    assert.equal(await galeriInternet.locator(".warn-text").innerText(), "Şifresiz HTTP");
    await page.getByTestId("public-warning").waitFor();
    assert.deepEqual(await actions(), ["ac"], "the server holds every action back");
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    const lockedSettings = page.getByTestId("settings-locked");
    await lockedSettings.waitFor();
    assert.equal(await lockedSettings.locator(".empty-title").innerText(), "Bu konteynerin tanımı şu an düzenlenemiyor");
    assert.equal(await lockedSettings.locator(".empty-text").innerText(), LOCKED);
    await page.getByRole("tab", { name: "Özet" }).click();
    assert.equal(await page.getByTestId("note-restricted").innerText(), LOCKED);

    await page.goto(url("#/uygulamalar/konteyner:yedek?sekme=erisim"));
    await page.locator("main h1").filter({ hasText: "yedek" }).waitFor();
    await page.getByText("Bu uygulamanın yayınladığı bir adres yok").waitFor();
    assert.equal(await page.getByTestId("access-publish").innerText(), "Yayınla");
    await page.getByRole("tab", { name: "Depolama" }).click();
    await page.getByTestId("storage-empty").getByText("Bu uygulama bir konteynerde çalışmıyor").waitFor();
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    await page.getByTestId("settings-empty").getByText("Bu uygulamanın ayrı bir ayar sayfası yok").waitFor();
    expectedFailures = ["/api/konsol/uygulamalar/gunluk"];
    await page.getByRole("tab", { name: "Günlük" }).click();
    await page.getByTestId("log-error").filter({ hasText: LOG_ERROR }).waitFor();
    assert.equal(await page.getByTestId("log-error").getAttribute("role"), "alert");
    expectedFailures = ["/api/konsol/uygulamalar/ayrinti"];
    await page.goto(url("#/uygulamalar/konteyner:yok"));
    await page.getByText("Bu uygulama yok").waitFor();
    assert.equal(await page.getByText("Uygulama bulunamadı.").count(), 1);
    await page.context().close();
    expectedFailures = [];

    // ================= the live log switch: every 5 s while on, from the address too
    page = await newPage({}, { clock: true });
    await page.goto(url("#/uygulamalar/konteyner:medya?sekme=gunluk"));
    await page.getByTestId("log-lines").waitFor();
    await page.waitForTimeout(100);
    const l0 = count("uygulamalar/gunluk");
    await page.clock.runFor(10000);
    await page.waitForTimeout(150);
    assert.equal(count("uygulamalar/gunluk"), l0, "no reads while Canlı is off");
    const liveSwitch = page.getByRole("switch", { name: "Canlı" });
    await liveSwitch.click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=gunluk&canli=1");
    assert.equal(await liveSwitch.getAttribute("aria-checked"), "true");
    await page.clock.runFor(5000);
    await waitFor(() => count("uygulamalar/gunluk") === l0 + 1, "read after 5 s");
    await page.clock.runFor(5000);
    await waitFor(() => count("uygulamalar/gunluk") === l0 + 2, "and after 10 s");
    await liveSwitch.click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya?sekme=gunluk");
    await page.clock.runFor(15000);
    await page.waitForTimeout(150);
    assert.equal(count("uygulamalar/gunluk"), l0 + 2, "off again: no more reads");
    await page.goto(url("#/uygulamalar/konteyner:medya?sekme=gunluk&canli=1"));
    await page.reload();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByRole("switch", { name: "Canlı" }).getAttribute("aria-checked"), "true", "on from the address");
    await page.context().close();

    // ================= over HTTPS (the public name) "Aç" leads to the internet address
    expectedFailures = ["/api/konsol/olaylar"];
    page = await h.newHttpsPage("konsol.example.test");
    await page.goto("https://konsol.example.test/#/genel");
    await page.locator(".app-card").first().waitFor();
    assert.equal(await page.locator('.app-card[data-uygulama="konteyner:wiki"] [data-eylem="ac"]').getAttribute("href"), "https://wiki.example.com");
    assert.equal(await page.locator('.app-card[data-uygulama="konteyner:medya"] [data-eylem="ac"]').getAttribute("href"), "http://medya.ev",
      "without an internet name the tailnet one is offered");
    await page.context().close();
    expectedFailures = [];

    // ================= 1440, 390 and 320 in both themes
    for (const colorScheme of ["light", "dark"]) {
      page = await newPage({ colorScheme });
      for (const [name, hash] of [["genel", "#/genel"], ["uygulamalar", "#/uygulamalar"], ["uygulama", "#/uygulamalar/konteyner:medya"]]) {
        await page.goto(url(hash));
        await page.locator(name === "uygulamalar" ? ".app-table" : name === "genel" ? ".app-card" : "[data-testid=summary-state]").first().waitFor();
        await noStyles(page, `1440 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `1440 ${colorScheme} ${name}`);
        await shot(page, `1440-${colorScheme}-${name}.png`, true);
      }
      await page.context().close();

      page = await newPage({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
      await page.goto(url("#/genel"));
      await page.locator(".app-card").first().waitFor();
      assert.equal(await page.locator('.app-card [data-eylem="ac"]').first().isVisible(), false, "phone tiles open the application's page");
      const tiles = await page.locator(".app-card").evaluateAll((els) => els.slice(0, 2).map((e) => Math.round(e.getBoundingClientRect().top)));
      assert.equal(tiles[0], tiles[1], "two tiles per row");
      await noStyles(page, `390 ${colorScheme} genel`);
      assert(await noHorizontalScroll(page), "390 genel");
      await shot(page, `390-${colorScheme}-genel.png`, true);
      // A tap anywhere on the tile (here its top right corner, away from the name) opens the page.
      const tile = page.locator('.app-card[data-uygulama="konteyner:medya"]');
      const tileBox = await tile.boundingBox();
      await tile.tap({ position: { x: tileBox.width - 14, y: 14 } });
      await page.waitForURL((u) => u.hash === "#/uygulamalar/konteyner:medya");
      await page.getByTestId("summary-state").waitFor();
      assert.equal(await page.getByRole("navigation", { name: "Alt menü" }).getByRole("link", { name: "Uygulamalar" }).getAttribute("aria-current"), "true");
      assert(await noHorizontalScroll(page), "390 uygulama");
      await shot(page, `390-${colorScheme}-uygulama.png`, true);
      await page.getByTestId("app-actions").locator('[data-eylem="kaldir"]').tap();
      const sheet = page.getByRole("dialog", { name: "medya kaldırılsın mı?" });
      await sheet.waitFor();
      const sheetBox = await sheet.boundingBox();
      assert(Math.abs(sheetBox.y + sheetBox.height - 844) <= 1 && sheetBox.width === 390, "a bottom sheet on a phone");
      await shot(page, `390-${colorScheme}-kaldir.png`);
      await sheet.getByRole("button", { name: "Kapat" }).tap();
      await sheet.waitFor({ state: "detached" });
      await page.goto(url("#/uygulamalar"));
      await page.locator(".app-table").waitFor();
      assert.equal(await page.locator('tr[data-uygulama="konteyner:medya"]').evaluate((el) => getComputedStyle(el).display), "grid", "cards on a phone");
      assert.equal(await page.locator(".app-table thead").evaluate((el) => getComputedStyle(el).position), "absolute", "column heads only for screen readers");
      assert.equal(await page.locator('tr[data-uygulama="konteyner:medya"] .col-state').evaluate((el) => getComputedStyle(el, "::before").content), '"Durum"');
      await noStyles(page, `390 ${colorScheme} uygulamalar`);
      assert(await noHorizontalScroll(page), "390 uygulamalar");
      await shot(page, `390-${colorScheme}-uygulamalar.png`, true);
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      for (const [name, hash] of [["uygulamalar", "#/uygulamalar"], ["genel", "#/genel"], ["uygulama", "#/uygulamalar/konteyner:medya?sekme=erisim"]]) {
        await page.goto(url(hash));
        await page.locator(name === "uygulamalar" ? ".app-table" : name === "genel" ? ".app-card" : "[data-testid=access]").first().waitFor();
        await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        await noStyles(page, `320 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `320 ${colorScheme} ${name}`);
        await shot(page, `320-${colorScheme}-${name}.png`, true);
      }
      await page.context().close();
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol phase 2 under the production CSP — Genel Bakış (problems with their fix, repair confirmation, POST {kip:onar}, error, " +
      "running and ended repair, calm state, locked repair with its reason, the containers as applications, Aç only to their own address over HTTP " +
      "and HTTPS, resources, network rates and a failed read, server), network reads every 5 s only while shown and visible, a clean server's " +
      "empty states leading to Uygulama ekle, palette opens application pages, Uygulamalar (summary, filter chips with counts, Turkish-aware " +
      "search, URL state and reload, empty filters, add panel, infrastructure, errors, keyboard order and focus ring), application page (trail, " +
      "heading focus, tabs with arrow keys and URL, Özet's management, Erişim with technical details in the URL and ports, Depolama, Ayarlar " +
      "(definition, outside Konsol, locked, none), Günlük with Yenile, an error and the Canlı switch), exact POST bodies (yeniden-baslat, durdur, " +
      "guncelle, kaldir, baslat without revizyon), dialog focus trap, Esc and focus return, typed confirmation, error replies, container jobs in " +
      "the drawer and their end reading the page again, the image update's result, a removed application, an unknown one, 1440/390/320 in light " +
      "and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
