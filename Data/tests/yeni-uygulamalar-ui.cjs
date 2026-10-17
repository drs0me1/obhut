/* Konsol's Genel Bakış, Uygulamalar and an application's page (DD-258; DD-271 phase 3) in the committed build
   under Data/console/yeni, with the production CSP and fixture replies for every endpoint they read or post
   to (yeni-harness.cjs). The applications come from their records (GET /api/konsol/uygulamalar and
   …/uygulamalar/{app}); every action is a job followed in İşlemler. Fails on any console error, CSP violation
   or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulamalar-ui.cjs */
const assert = require("node:assert/strict");
const { uygulama, servis, uygulamalar, ayrinti } = require("./yeni-harness.cjs").fixtures;

// ---- fixtures: documentation values only (RFC 5737 addresses, registry.example images); shapes as in api/sema.ts
const VPN_NOTE = "WireGuard cihazları yalnız internete çıkar; bu sunucudaki hizmetlere ulaşamaz.";
const OK_CHECKS = [
  { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" },
  { id: "caddy", name: "Caddy", status: "ok", detail: "çalışıyor" },
  { id: "dns", name: "DNS", status: "ok", detail: "yanıt veriyor" }];
const BAD_CHECK = { id: "units", name: "2 eski birim başarısız", status: "bad", detail: "konsol-deneme ve konsol-eski her açılışta hata veriyor." };
const WARNING = { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda okunabilir.",
  duzelt: { bolum: "adresler", hedef: "paylasim" } };
// An application port's access row as Erişim lists it (rebuild phase 4): its sheet in Adresler is the row's one home.
const NOTLAR_WEB = "uygulama:notlar:web:8080/tcp";
const NOTLAR_ROW = { tur: "adres", ad: "notlar", tailscale_portu: 8443, internet: "notlar.example.org" };
const accessCell = (durum, adresler = []) => ({ durum, adresler, not: "", uyari: "" });
const ACCESS_ROW = { id: NOTLAR_WEB, ad: "notlar · web", tur: "uygulama", aciklama: "8080/tcp · Adres", uygulama: "notlar", servis: "web", anahtar: "web:8080/tcp",
  calisiyor: true, yerel: accessCell("acik", ["127.0.0.1:62001"]), tailscale: accessCell("acik", ["notlar.ev", "100.64.0.2:8443"]),
  wireguard: accessCell("kapali"), internet: accessCell("acik", ["notlar.example.org"]), satir: NOTLAR_ROW, web: null, ayrinti: [] };
const ROOT_WARNING = "Bu konteyner root olarak başlıyor; kendi kullanıcısına geçmezse /srv'ye Dosyalar hesabının açamayacağı dosyalar yazabilir.";
const D = (c) => c.repeat(64);
const JOB = (n) => String(n).padStart(32, "0");

function apps() {
  return [
    // A job runs on it: the server holds every action back.
    uygulama("arsiv", { durum: "islemde", servisler: [servis("web", { durum: "islemde", imaj: "registry.example/arsiv:2" })], eylemler: [], is: JOB(99) }),
    // One service runs, the other is stopped.
    uygulama("galeri", { durum: "kismen", servisler: [servis("web", { imaj: "registry.example/galeri/web:3", guncelleme: "guncel" }),
      servis("isci", { durum: "durduruldu", imaj: "registry.example/galeri/isci:3", guncelleme: "guncel" })],
    kaynak: { cpu: 1.2, bellek: 52428800 }, guncelleme: "guncel", eylemler: ["baslat", "durdur", "guncelle"] }),
    // A root-started service with a /srv folder (a warning), a newer image of one of its tags.
    uygulama("notlar", { servisler: [servis("web", { imaj: "registry.example/notlar/web:2.4", guncelleme: "yeni" }),
      servis("db", { imaj: "registry.example/notlar/db:16", guncelleme: "guncel" })],
    kaynak: { cpu: 3.2, bellek: 220200960 }, guncelleme: "yeni", eylemler: ["durdur", "yeniden-baslat", "guncelle"], revizyon: "rev-notlar-7", uyari: 1 }),
    // Its file came from an address; its images have not been checked yet.
    uygulama("pano", { servisler: [servis("web", { imaj: "registry.example/pano:1", guncelleme: "bilinmiyor" })], guncelleme: "bilinmiyor",
      eylemler: ["durdur", "yeniden-baslat", "guncelle"], koken: "adres" }),
    // A Kubernetes Pod from an image name, stopped, its image pinned by digest.
    uygulama("yedek", { durum: "durduruldu", bicim: "kubernetes", servisler: [servis("yedekle", { durum: "durduruldu", imaj: "registry.example/yedek@sha256:" + D("c") })],
      eylemler: ["baslat"], koken: "imaj", durduruldu: true }),
  ];
}
const ALTYAPI = { podman: "5.4.2", calisiyor: true, imaj: 3, kullanilmayan_imaj: 1, birim: 2, ag: 3 };
const NOTLAR_FILE = [
  "services:",
  "  web:",
  "    image: registry.example/notlar/web:2.4",
  "    ports: [\"8080:8080\", \"9000:9000/udp\"]",
  "    volumes: [\"veri:/data\", \"/srv/Belgeler:/belgeler:ro\"]",
  "    tmpfs: [/tmp]",
  "    environment: { TZ: Europe/Istanbul, DB_PASSWORD: \"${DB_PASSWORD}\" }",
  "  db:",
  "    image: registry.example/notlar/db:16",
  "    user: \"999:999\"",
  "    volumes: [\"db-veri:/var/lib/db\"]",
  "    environment: { POSTGRES_PASSWORD: \"${DB_PASSWORD}\" }",
  "volumes: { veri: {}, db-veri: {} }",
  ""].join("\n");

function details() {
  const items = Object.fromEntries(data.uygulamalar.items.map((a) => [a.ad, a]));
  const out = {};
  const VERI = "/var/lib/master-stack/uygulamalar/";
  if (items.notlar) {
    out.notlar = ayrinti(items.notlar, {
      gizliler: [{ ad: "notlar-db-password", servisler: ["web", "db"] }],
      uyarilar: [{ servis: "web", metin: ROOT_WARNING }],
      koken: { tur: "dosya", adres: null, imaj: null, konteyner: null, alindi: 1791700000, sha256: D("e") },
      metin: NOTLAR_FILE,
      yanitlar: { name: "notlar", answers: {
        "port:web:8080/tcp": { use: "caddy", tailscale_name: "notlar" }, "port:web:9000/udp": { use: "raw" },
        "mount:web:/data": { to: "app" }, "mount:web:/belgeler": { to: "srv", path: "/srv/Belgeler", read_only: true },
        "mount:db:/var/lib/postgresql/data/uzun-bir-alt-klasor": { to: "app" }, "var:DB_PASSWORD": { set: true }, "var:TZ": { value: "Europe/Istanbul" },
        "start:web": { mode: "root" }, "start:db": { mode: "direct" } } },
    }, {
      web: { baslangic: "root", ozet: "registry.example/notlar/web@sha256:" + D("a"), calisma: 1791800000, saglik: "healthy", yeniden_baslama: 2,
        portlar: [{ port: 8080, protokol: "tcp", id: NOTLAR_WEB, erisim: NOTLAR_ROW, kullanim: "caddy", tailscale_adi: "notlar", yerel_port: 62001 },
          { port: 9000, protokol: "udp", id: "uygulama:notlar:web:9000/udp", erisim: { tur: "ham", kapsam: "tailscale", port: 9001 }, kullanim: "raw",
            tailscale_adi: null, yerel_port: null }],
        baglamalar: [{ hedef: "/data", tur: "app", yol: VERI + "notlar/veri", salt_okunur: false },
          { hedef: "/belgeler", tur: "srv", yol: "/srv/Belgeler", salt_okunur: true }, { hedef: "/tmp", tur: "tmpfs", yol: null, salt_okunur: false }],
        gizliler: ["notlar-db-password"] },
      db: { kullanici: "999:999", ozet: "registry.example/notlar/db@sha256:" + D("b"), calisma: 1791800100,
        baglamalar: [{ hedef: "/var/lib/db", tur: "app", yol: VERI + "notlar/db-veri", salt_okunur: false }], gizliler: ["notlar-db-password"] },
    });
  }
  if (items.galeri) {
    out.galeri = ayrinti(items.galeri, {}, {
      web: { kullanici: "1000:1000", calisma: 1791750000, saglik: "unhealthy", yeniden_baslama: 5,
        portlar: [{ port: 80, protokol: "tcp", id: "uygulama:galeri:web:80/tcp", erisim: { tur: "adres", ad: "galeri", tailscale_portu: null, internet: "" },
          kullanim: "caddy", tailscale_adi: "galeri", yerel_port: 62003 }] },
    });
  }
  if (items.pano) {
    out.pano = ayrinti(items.pano, { koken: { tur: "adres", adres: "https://files.example.org/pano/compose.yaml", imaj: null, konteyner: null, alindi: 1791710000, sha256: D("f") } },
      { web: { calisma: 1791760000, portlar: [{ port: 3000, protokol: "tcp", id: "uygulama:pano:web:3000/tcp", erisim: { tur: "adres", ad: "pano", tailscale_portu: null, internet: "" },
        kullanim: "caddy", tailscale_adi: "pano", yerel_port: 62002 }] } });
  }
  if (items.yedek) {
    out.yedek = ayrinti(items.yedek, { koken: { tur: "imaj", adres: null, imaj: "registry.example/yedek:1.0", konteyner: null, alindi: 1791720000, sha256: D("d") },
      metin: "apiVersion: v1\nkind: Pod\nmetadata:\n  name: yedek\nspec:\n  containers:\n    - name: yedekle\n      image: registry.example/yedek:1.0\n" },
    { yedekle: { kanal: "", ozet: "registry.example/yedek@sha256:" + D("c") } });
  }
  if (items.arsiv) out.arsiv = ayrinti(items.arsiv);
  return out;
}

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-244", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: 1791845000, sampled_at: 1791845000, cpu: 2.0, mem: { total: 8375186227, used: 696254464 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "bad", read_at: 1791844900, checks: [BAD_CHECK, ...OK_CHECKS] },
  guncelleme: { kurulu: "2026.08.06-v2-244", kurulu_surum: "1.0.0", son: "2026.08.06-v2-244", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false,
    denetlendi: 1791845000, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: 1791845000, alan: "ev", revizyon: "rev-1", hizmetler: [ACCESS_ROW], hatalar: [], uyarilar: [WARNING],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "sunucu", surum: "1.80.0", adresler: ["100.64.0.2"], cikis_dugumu: true },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, durduruldu: false, not: VPN_NOTE, aglar: [] }, sertifikalar: [] } },
  uygulamalar: uygulamalar(apps(), { altyapi: ALTYAPI }),
  // Erişim → Adresler (a port's link leads there): the local names, read with the rows.
  adlar: { revizyon: "rev-1", alan: "ev", hatalar: [], adlar: [{ ad: "notlar.ev", aile: 4, hedef: "tailscale", kaynak: "uygulama", kapali: false, kilitli: true,
    satir: NOTLAR_WEB }], kayitlar: [], yonlendirme: false, sunucular: [] },
  ag: { read_at: 1791845000, sampled_at: 1791845000, rx: 10240, tx: 38912 },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
};

const LOG = Array.from({ length: 30 }, (_, i) => `2026-10-13T01:${String(10 + i).padStart(2, "0")}:00+03:00 notlar_web[812]: satır ${i + 1}`);
const DB_LOG = ["2026-10-13T01:00:00+03:00 notlar_db[640]: hazır"];
const BUSY = "Bu hedefte bir işlem sürüyor.";
const LOG_ERROR = "Uygulama günlüğü okunamadı.";
const FAILED_STEP = "web başlamadı: sağlık denetimi 300 sn içinde geçmedi";

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-uygulamalar-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8769", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, count, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies: one application's detail, a service's log, its actions and its removal
const replies = [];  // replies for the next POSTs, before the default 202
let jobSeq = 0;
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)$/, ({ method }, m) => {
  if (method !== "GET") return undefined;
  const d = details()[m[1]];
  return d ? { body: d } : { status: 404, body: { error: "Uygulama bulunamadı." } };
}]);
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)\/gunluk$/, ({ query }, m) => {
  if (m[1] === "pano") return { status: 502, body: { error: LOG_ERROR } };
  return { body: query.get("servis") === "db" ? { satirlar: DB_LOG, kesik: false } : { satirlar: LOG, kesik: true } };
}]);
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)\/(islem|kaldir)$/, ({ method, body }, m) => {
  if (method !== "POST") return undefined;
  return replies.shift() ?? { status: 202, body: { is: JOB(++jobSeq), eylem: m[2] === "kaldir" ? "kaldir" : body.eylem, ad: m[1] } };
}]);
// A finished job's own record: an image update that found nothing new.
h.handlers["/api/konsol/konteynerler/islem"] = ({ method, query }) => (method === "GET"
  ? { body: { id: query.get("id"), action: "uygulama-guncelle", name: "notlar", state: "done", step: "", result: { ok: true, ad: "notlar", revizyon: "rev-notlar-7", changed: false } } }
  : undefined);
const onarimReplies = [];
h.handlers["/api/konsol/onarim"] = ({ method }) => (method === "POST" ? onarimReplies.shift() ?? { status: 202, body: { kip: "onar" } } : undefined);

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const active = (page) => page.evaluate(() => {
  const e = document.activeElement;
  return e ? (e.getAttribute("aria-label") || e.textContent || "").trim().replace(/\s+/g, " ") : "";
});
const rowNames = (page) => page.locator(".app-table tbody .app-name").allInnerTexts();
const postsTo = (path) => h.requests.filter((r) => r.method === "POST" && r.path === path).map((r) => r.body);
const lastPost = (path) => postsTo(path).at(-1);
const reads = (path) => h.requests.filter((r) => r.method === "GET" && r.path === path);
const job = (o) => ({ tur: "uygulama", id: JOB(0), ad: "notlar · İşlem", durum: "calisiyor", adim: "", bitis: null, ...o });
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
    assert.equal(await warn.getByRole("link", { name: "Düzelt" }).getAttribute("href"), "#/erisim?sekme=adresler&satir=paylasim", "its fix: the row's sheet");
    assert.equal(await page.getByRole("link", { name: "Tüm denetimler" }).getAttribute("href"), "#/sistem?sekme=saglik", "Sistem → Sağlık (phase 4a)");
    // Applications: every application in the list, in its order, each leading to its page.
    await page.locator(".app-card").first().waitFor();
    assert.deepEqual(await page.locator(".app-card").evaluateAll((els) => els.map((e) => e.dataset.uygulama)), ["arsiv", "galeri", "notlar", "pano", "yedek"]);
    assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (5)");
    assert.equal(await page.getByTestId("all-apps").getAttribute("href"), "#/uygulamalar");
    const card = (ad) => page.locator(`.app-card[data-uygulama="${ad}"]`);
    assert.deepEqual(await page.locator(".app-card .pill").allInnerTexts(), ["İşlemde…", "Kısmen çalışıyor", "Çalışıyor", "Çalışıyor", "Durdurulmuş"]);
    assert.equal(await card("notlar").locator(".app-line").innerText(), "Compose · 2 servis · 1 uyarı · yeni sürüm var");
    assert.equal(await card("yedek").locator(".app-line").innerText(), "Kubernetes · 1 servis");
    assert.equal(await card("notlar").getByRole("link", { name: "notlar ayrıntıları" }).getAttribute("href"), "#/uygulamalar/notlar");
    assert.equal(await page.locator('.app-card [data-eylem="ac"]').count(), 0, "no address to open yet (phase 4)");
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
    assert.deepEqual(postsTo("/api/konsol/onarim"), [{ kip: "onar" }, { kip: "onar" }], "the repair POST body");
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

    // ================= a clean server: no applications yet; adding one comes with the new screens
    const EMPTY_TEXT = "Compose ya da Kubernetes dosyasından uygulama eklemek Konsol'un yeni ekranlarıyla gelecek.";
    data.uygulamalar = uygulamalar([], { altyapi: { ...ALTYAPI, imaj: 0, kullanilmayan_imaj: 0, birim: 0, ag: 1 } });
    page = await newPage();
    await page.goto(url("#/genel"));
    const overviewApps = page.locator(".overview-apps");
    await overviewApps.locator(".empty-title").filter({ hasText: "Henüz uygulama yok." }).waitFor();
    assert.equal(await overviewApps.locator(".empty-text").innerText(), EMPTY_TEXT);
    assert.equal(await overviewApps.locator(".empty-state a, .empty-state button").count(), 0, "it points nowhere else");
    assert.equal(await page.locator(".app-card").count(), 0);
    assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (0)");
    assert.equal(await page.locator('.sidebar [data-badge="uygulamalar"]').count(), 0, "no count beside an empty section");
    await noStyles(page, "genel, no applications");
    await shot(page, "1440-light-genel-bos.png", true);
    await page.getByTestId("all-apps").click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.getByTestId("page-desc").filter({ hasText: "Henüz uygulama yok" }).waitFor();
    const appsEmpty = page.getByTestId("apps-empty");
    await appsEmpty.waitFor();
    assert.equal(await appsEmpty.locator(".empty-title").innerText(), "Henüz uygulama yok.");
    assert.equal(await appsEmpty.locator(".empty-text").innerText(), EMPTY_TEXT);
    assert.equal(await appsEmpty.locator("a, button").count(), 0, "it points nowhere else");
    assert.equal(await page.locator(".app-table").count(), 0);
    assert.equal(await page.getByRole("button", { name: "Uygulama ekle" }).count(), 0, "no add flow before the new screens");
    const emptyChips = page.getByRole("group", { name: "Süzgeç" }).getByRole("button");
    assert.deepEqual((await emptyChips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")), ["Tümü 0", "Çalışan 0", "Durdurulmuş 0", "Dikkat 0"]);
    assert.equal(await page.getByTestId("infra-line").innerText(), "Podman 5.4.2 · 0 imaj · 0 birim · 1 ağ · kullanılmayan imaj yok");
    await noStyles(page, "uygulamalar, no applications");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-uygulamalar-bos.png", true);
    await page.context().close();
    data.uygulamalar = uygulamalar(apps(), { altyapi: ALTYAPI });

    // ================= the palette lists the applications and opens their pages
    page = await newPage();
    await page.goto(url("#/genel"));
    await page.locator(".app-card").first().waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.waitFor();
    const appOptions = () => palette.locator(".palette-group").filter({ has: page.locator(".palette-group-name", { hasText: "Uygulamalar" }) }).locator(".palette-label").allInnerTexts();
    assert.deepEqual(await appOptions(), ["arsiv", "galeri", "notlar", "pano", "yedek"]);
    assert.equal(await palette.locator(".palette-label").filter({ hasText: /yönetime|konteyner oluştur/i }).count(), 0, "no add flow in the palette");
    await palette.getByRole("combobox").fill("yedekle");
    assert.deepEqual(await appOptions(), ["yedek"], "found by its service's name");
    await palette.getByRole("combobox").fill("notl");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar");
    await page.locator("main h1").filter({ hasText: "notlar" }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the application's heading has focus");
    await page.context().close();

    // ================= Uygulamalar: summary, filters, search, all in the address
    page = await newPage();
    await page.goto(url("#/uygulamalar"));
    await page.getByTestId("page-desc").filter({ hasText: "5 uygulama · 2 çalışıyor · 1 durdurulmuş · 2 dikkat" }).waitFor();
    assert.equal(await page.locator('.sidebar [data-badge="uygulamalar"]').innerText(), "5", "the sidebar counts the same applications");
    const chips = page.getByRole("group", { name: "Süzgeç" }).getByRole("button");
    assert.deepEqual((await chips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")), ["Tümü 5", "Çalışan 2", "Durdurulmuş 1", "Dikkat 2"]);
    assert.equal(await chips.filter({ hasText: "Tümü" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await rowNames(page), ["arsiv", "galeri", "notlar", "pano", "yedek"]);
    assert(await page.locator(".app-table thead").isVisible(), "a table on a wide screen");
    assert.deepEqual((await page.locator(".app-table thead th").allInnerTexts()).slice(0, 5), ["Uygulama", "Durum", "Servisler", "Kaynak", "Sürüm"]);
    const tr = (ad) => page.locator(`tr[data-uygulama="${ad}"]`);
    assert.equal(await tr("notlar").locator(".app-desc").innerText(), "Compose · 2 servis");
    assert.deepEqual(await tr("notlar").locator(".col-state .pill").allInnerTexts(), ["Çalışıyor", "1 uyarı"], "a warning shows beside the state");
    assert.equal(await tr("notlar").locator(".col-svc").innerText(), "2 servis · web, db");
    assert.equal(await tr("notlar").locator(".col-res").innerText(), "%3 · 210 MB");
    assert.equal(await tr("notlar").locator(".col-ver").innerText(), "Yeni sürüm");
    assert.equal(await tr("galeri").locator(".col-state").innerText(), "Kısmen çalışıyor");
    assert.equal(await tr("galeri").locator(".col-res").innerText(), "%1 · 50 MB");
    assert.equal(await tr("galeri").locator(".col-ver").innerText(), "Güncel");
    assert.equal(await tr("arsiv").locator(".col-state").innerText(), "İşlemde…");
    assert.equal(await tr("yedek").locator(".col-state").innerText(), "Durdurulmuş");
    assert.equal(await tr("yedek").locator(".app-desc").innerText(), "Kubernetes · 1 servis");
    assert.equal(await tr("pano").locator(".col-ver").innerText(), "—", "not checked yet: nothing shown, not an error");
    assert.equal(await tr("pano").locator(".col-res").innerText(), "—", "unknown resources");
    assert.equal(await tr("yedek").getByRole("link", { name: "yedek ayrıntıları" }).getAttribute("href"), "#/uygulamalar/yedek");
    assert.equal(await page.locator('.app-table [data-eylem="ac"]').count(), 0, "no address to open yet (phase 4)");
    assert.equal(await page.getByTestId("apps-empty").count(), 0);
    await noStyles(page, "uygulamalar");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-uygulamalar.png", true);

    await chips.filter({ hasText: "Dikkat" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=dikkat");
    assert.deepEqual(await rowNames(page), ["galeri", "notlar"], "partly running, or a warning and a newer image");
    assert.equal(await chips.filter({ hasText: "Dikkat" }).getAttribute("aria-pressed"), "true");
    await chips.filter({ hasText: "Durdurulmuş" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=durmus");
    assert.deepEqual(await rowNames(page), ["yedek"]);
    await chips.filter({ hasText: "Çalışan" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=calisan");
    assert.deepEqual(await rowNames(page), ["notlar", "pano"]);
    await chips.filter({ hasText: "Tümü" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    // By name, service or image, with Turkish case rules: "GALERİ" is "galeri", "GALERI" is "galerı".
    const search = page.getByRole("searchbox", { name: "Uygulama ara" });
    await search.fill("GALERİ");
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ara=GALER%C4%B0");
    assert.deepEqual(await rowNames(page), ["galeri"]);
    await search.fill("GALERI");
    await page.getByText("Aramayla eşleşen uygulama yok.").waitFor();
    await search.fill("db");
    assert.deepEqual(await rowNames(page), ["notlar"], "found by a service");
    await search.fill("registry.example/pano");
    assert.deepEqual(await rowNames(page), ["pano"], "found by an image");
    await page.getByRole("status").filter({ hasText: "1 uygulama gösteriliyor" }).waitFor();
    // The view comes back from the address.
    await page.goto(url("#/uygulamalar?suzgec=dikkat&ara=web"));
    await page.reload();
    await page.locator(".app-table").waitFor();
    assert.equal(await search.inputValue(), "web");
    assert.equal(await chips.filter({ hasText: "Dikkat" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await rowNames(page), ["galeri", "notlar"]);
    await page.goto(url("#/uygulamalar?suzgec=durmus&ara=notlar"));
    await page.getByText("Aramayla eşleşen uygulama yok.").waitFor();
    await page.getByRole("button", { name: "Tüm uygulamaları göster" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    assert.equal(await search.inputValue(), "");
    assert.equal((await rowNames(page)).length, 5, "the filter and the search both cleared");
    // An empty filter says so.
    data.uygulamalar = { ...data.uygulamalar, items: apps().map((a) => (a.ad === "yedek" ? { ...a, durum: "calisiyor" } : a)) };
    await page.goto(url("#/uygulamalar?suzgec=durmus"));
    await page.reload();
    await page.getByText("Durdurulmuş uygulama yok.").waitFor();
    assert.equal(await page.getByTestId("apps-empty").count(), 0, "a filter that matches nothing is not an empty server");
    data.uygulamalar = uygulamalar(apps(), { altyapi: ALTYAPI });
    // The infrastructure, and errors from the read model.
    await page.goto(url("#/uygulamalar"));
    await page.reload();
    assert.equal(await page.getByTestId("infra-line").innerText(), "Podman 5.4.2 · 3 imaj · 2 birim · 3 ağ · 1 kullanılmayan imaj");
    assert.equal(await page.getByTestId("infra").getByRole("link", { name: "İmajlar" }).getAttribute("href"), "#/gelismis?sekme=podman&kaynak=imajlar");
    assert.equal(await page.getByTestId("add-app").count(), 0, "no add card");
    // Keyboard order through the toolbar and the first row; the focus is visible.
    await search.focus();
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "arsiv");
    assert.equal(await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle), "solid", "a visible focus ring");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "arsiv ayrıntıları");
    data.uygulamalar = { ...data.uygulamalar, hatalar: ["Podman kullanılamıyor."] };
    await page.reload();
    await page.getByTestId("app-errors").getByText("Podman kullanılamıyor.").waitFor();
    assert.equal(await page.getByTestId("app-errors").getByRole("heading").innerText(), "Bazı bilgiler okunamadı");
    await shot(page, "1440-light-uygulamalar-hatalar.png", true);
    data.uygulamalar = { ...data.uygulamalar, hatalar: [] };

    // ================= an application's page
    await page.reload();
    await page.locator(".app-table").waitFor();
    await tr("notlar").getByRole("link", { name: "notlar", exact: true }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar");
    await page.locator("main h1").filter({ hasText: "notlar" }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the new page's heading has focus");
    assert.equal(await page.title(), "notlar · Konsol");
    const trail = page.getByRole("navigation", { name: "Konum" });
    assert.equal(await trail.getByRole("link", { name: "Uygulamalar" }).getAttribute("href"), "#/uygulamalar");
    assert.equal(await trail.locator('[aria-current="page"]').innerText(), "notlar");
    assert.equal(await page.locator('.sidebar [data-nav="uygulamalar"]').getAttribute("aria-current"), "true", "the section of the page");
    assert.equal(await page.getByTestId("app-state").innerText(), "Çalışıyor");
    await page.getByTestId("app-desc").filter({ hasText: "Compose · 2 servis · yeni sürüm var" }).waitFor();
    const actions = () => page.getByTestId("app-actions").locator("[data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem));
    assert.deepEqual(await actions(), ["yeniden-baslat", "durdur", "guncelle", "kaldir"], "the backend's eylemler, and Kaldır");
    // The warning, prominent above the tabs.
    const warnings = page.getByTestId("app-warnings");
    await warnings.waitFor();
    assert.equal(await warnings.getByRole("heading").innerText(), "Bir uyarı");
    assert.equal(await warnings.locator('li[data-servis="web"]').innerText(), "web: " + ROOT_WARNING);
    // Özet.
    const tabs = page.getByRole("tablist", { name: "notlar bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Özet", "Portlar", "Depolama", "Tanım", "Günlük"]);
    assert.deepEqual(await tabs.evaluateAll((els) => els.map((e) => [e.getAttribute("aria-selected"), e.tabIndex])),
      [["true", 0], ["false", -1], ["false", -1], ["false", -1], ["false", -1]], "one tab stop");
    const web = page.locator('[data-testid="service"][data-servis="web"]');
    const db = page.locator('[data-testid="service"][data-servis="db"]');
    await web.waitFor();
    assert.equal(await page.getByTestId("app-format").innerText(), "Compose · 2 servis");
    assert.equal(await page.getByTestId("app-version").innerText(), "Yeni sürüm");
    assert.equal(await page.getByTestId("app-network").innerText(), "ksl-notlar");
    assert.equal(await page.getByTestId("app-pod").count(), 0, "a Compose application has no pod");
    assert.equal(await page.getByTestId("app-cpu").innerText(), "%3");
    assert.equal(await page.getByTestId("app-memory").innerText(), "210 MB");
    assert.equal(await web.getByTestId("service-state").innerText(), "Çalışıyor");
    assert.equal(await web.getByTestId("service-start").innerText(), "Root olarak; kendi kullanıcısına geçebilir");
    assert.equal(await web.getByTestId("service-user").innerText(), "İmajın varsayılanı");
    assert.equal(await web.getByTestId("service-image").innerText(), "registry.example/notlar/web:2.4");
    assert.equal(await web.getByTestId("service-digest").innerText(), "registry.example/notlar/web@sha256:aaaaaaaaaaaa…");
    assert.equal(await web.getByTestId("service-version").innerText(), "Yeni sürüm · registry.example/notlar/web:2.4");
    assert.equal(await web.getByTestId("service-health").innerText(), "Sağlıklı");
    assert.equal(await web.getByTestId("service-restarts").innerText(), "2");
    assert.equal(await web.getByTestId("service-started").innerText(), dateTime(1791800000));
    assert.equal(await db.getByTestId("service-start").innerText(), "Doğrudan kendi kullanıcısıyla");
    assert.equal(await db.getByTestId("service-user").innerText(), "999:999");
    assert.equal(await db.getByTestId("service-health").innerText(), "Denetim tanımlı değil");
    assert.match(await db.innerText(), /notlar_db/);
    assert.match(await db.innerText(), /konsol-notlar_db\.service/);
    assert.equal(await page.getByTestId("note-unhealthy").count(), 0);
    await noStyles(page, "uygulama");
    await shot(page, "1440-light-uygulama-ozet.png", true);
    // Arrow keys move and choose; the address follows.
    await tabs.first().focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=portlar");
    assert.equal(await active(page), "Portlar");
    await page.keyboard.press("End");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk");
    assert.equal(await active(page), "Günlük");
    await page.keyboard.press("Home");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar");
    assert.equal(await active(page), "Özet");
    await page.keyboard.press("ArrowLeft");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk");
    assert.equal(await tabs.filter({ hasText: "Günlük" }).getAttribute("aria-selected"), "true");
    // Portlar: each container port with its access row (an address: its names and ports; a raw port: its scope and
    // host port), read-only, each linking to its row in Erişim → Adresler.
    await tabs.filter({ hasText: "Portlar" }).click();
    const ports = page.getByTestId("port-table");
    await ports.waitFor();
    assert.deepEqual(await ports.locator("tbody tr").evaluateAll((els) => els.map((e) => e.dataset.port)), [NOTLAR_WEB, "uygulama:notlar:web:9000/udp"]);
    assert.deepEqual(await ports.locator("tbody tr").evaluateAll((els) => els.map((e) => [e.children[0].innerText.trim(), e.children[1].innerText.trim()])),
      [["8080/tcp", "web"], ["9000/udp", "web"]]);
    const addressPort = ports.locator(`tr[data-port="${NOTLAR_WEB}"]`);
    assert.deepEqual(await addressPort.getByTestId("port-address").locator("dt").allInnerTexts(), ["Adres", "Tailscale adı", "Tailscale portu", "İnternet adı"]);
    assert.deepEqual(await addressPort.getByTestId("port-address").locator("dd").allInnerTexts(),
      ["Yalnız bu sunucu · 127.0.0.1:62001", "notlar.ev", "TCP 8443", "notlar.example.org"]);
    assert.deepEqual((await ports.locator('tr[data-port="uygulama:notlar:web:9000/udp"]').getByTestId("port-raw").innerText()).split("\n"), ["Ham port", "Tailscale", "UDP 9001"]);
    assert.deepEqual(await ports.getByTestId("port-row-link").evaluateAll((as) => as.map((a) => a.getAttribute("href"))),
      ["#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A8080%2Ftcp", "#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A9000%2Fudp"]);
    assert.equal(await ports.locator("button, input").count(), 0, "read-only: the row changes in Erişim");
    await shot(page, "1440-light-uygulama-portlar.png", true);
    // The link opens the row's sheet in Adresler.
    await addressPort.getByTestId("port-row-link").click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A8080%2Ftcp");
    const rowSheet = page.getByRole("dialog", { name: "notlar · web" });
    await rowSheet.getByTestId("row-form").waitFor();
    assert.equal(await rowSheet.getByTestId("row-name").inputValue(), "notlar");
    await rowSheet.getByRole("button", { name: "Vazgeç" }).click();
    await rowSheet.waitFor({ state: "detached" });
    await page.goBack();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=portlar");
    await ports.waitFor();
    // Depolama: every mount with its path on this server; the application's data folder.
    await tabs.filter({ hasText: "Depolama" }).click();
    await page.getByTestId("mounts").waitFor();
    assert.deepEqual(await page.getByTestId("mounts").locator(".mount").allInnerTexts(), [
      "/data · web\nUygulamanın klasörü · /var/lib/master-stack/uygulamalar/notlar/veri · Okuma-yazma",
      "/belgeler · web\nSunucu klasörü · /srv/Belgeler · Salt okunur",
      "/tmp · web\nGeçici (bellekte)",
      "/var/lib/db · db\nUygulamanın klasörü · /var/lib/master-stack/uygulamalar/notlar/db-veri · Okuma-yazma"]);
    assert.equal(await page.getByTestId("data-folder").locator(".mono").innerText(), "/var/lib/master-stack/uygulamalar/notlar");
    // Tanım: the source, the file as given, the answers (a secret only as set) and the secrets by name.
    await tabs.filter({ hasText: "Tanım" }).click();
    await page.getByTestId("source").waitFor();
    assert.equal(await page.getByTestId("source-kind").innerText(), "Dosyadan");
    assert.equal(await page.getByTestId("source-sha").innerText(), D("e"));
    assert.equal(await page.getByTestId("file").locator("pre").evaluate((e) => e.textContent), NOTLAR_FILE, "the file exactly as given");
    assert.deepEqual(await page.getByTestId("secrets").locator(".mount").allInnerTexts(), ["notlar-db-password\nweb, db"]);
    const answer = (id) => page.getByTestId("answers").locator(`[data-yanit="${id}"]`).innerText();
    assert.equal(await answer("var:DB_PASSWORD"), "gizli · gösterilmez", "a secret answer never shows a value");
    assert.equal(await answer("var:TZ"), "Europe/Istanbul");
    assert.equal(await answer("port:web:8080/tcp"), "Adres · Tailscale adı notlar");
    assert.equal(await answer("port:web:9000/udp"), "Ham port");
    assert.equal(await answer("mount:web:/belgeler"), "/srv/Belgeler · salt okunur");
    assert.equal(await answer("mount:web:/data"), "Uygulamanın klasörü");
    assert.equal(await answer("start:web"), "Root olarak; kendi kullanıcısına geçebilir");
    assert.deepEqual(await page.getByTestId("units").locator("li").allInnerTexts(), ["konsol-notlar.network", "konsol-notlar_db.container", "konsol-notlar_web.container"]);
    assert.equal(await page.locator("textarea, [contenteditable]").count(), 0, "read-only: no editor");
    await shot(page, "1440-light-uygulama-tanim.png", true);
    // Günlük: one service at a time.
    const logPath = "/api/konsol/uygulamalar/notlar/gunluk";
    const logReads = reads(logPath).length;
    await tabs.filter({ hasText: "Günlük" }).click();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByTestId("log-lines").locator("li").count(), 30);
    assert.equal(await page.getByTestId("log-lines").locator("li").first().innerText(), LOG[0]);
    await page.getByText("Yalnız son 200 satır gösteriliyor.").waitFor();
    assert.equal(reads(logPath).length, logReads + 1);
    assert.equal(reads(logPath).at(-1).query, "?servis=web&satir=200");
    const serviceChips = page.getByRole("radiogroup", { name: "Servis" });
    assert.deepEqual(await serviceChips.locator(".choice-chip").allInnerTexts(), ["web", "db"]);
    await serviceChips.getByText("db").click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk&servis=db");
    await page.getByTestId("log-lines").locator("li").filter({ hasText: "hazır" }).waitFor();
    assert.equal(reads(logPath).at(-1).query, "?servis=db&satir=200");
    await page.getByRole("button", { name: "Yenile" }).click();
    await waitFor(() => reads(logPath).length === logReads + 3, "Yenile reads the log again");
    assert.equal(await page.getByTestId("live-switch").getAttribute("aria-checked"), "false");
    await shot(page, "1440-light-uygulama-gunluk.png", true);

    // Actions: each POST body exactly; the job of a 202 shows in the activity drawer and its end reads the
    // page again.
    await tabs.filter({ hasText: "Özet" }).click();
    const detailReads = () => reads("/api/konsol/uygulamalar/notlar").length;
    const islem = "/api/konsol/uygulamalar/notlar/islem";
    const button = (eylem) => page.getByTestId("app-actions").locator(`[data-eylem="${eylem}"]`);
    await button("yeniden-baslat").click();
    await waitFor(() => postsTo(islem).length === 1, "restart posted");
    assert.deepEqual(lastPost(islem), { eylem: "yeniden-baslat", revizyon: "rev-notlar-7" });
    await page.getByTestId("action-note").filter({ hasText: "Yeniden başlatılıyor; ilerlemesi İşlemler'de görünür." }).waitFor();
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    const restartJob = JOB(jobSeq);
    push("islemler", { items: [job({ id: restartJob, ad: "notlar · Yeniden başlatma", adim: "web durduruluyor" })] });
    await page.getByRole("button", { name: "İşlemler, 1 çalışıyor" }).click();
    const drawer = page.getByRole("dialog", { name: "İşlemler" });
    assert.equal(await drawer.locator(".job-name").innerText(), "notlar · Yeniden başlatma");
    assert.equal(await drawer.locator(".job-meta").innerText(), "Uygulama · web durduruluyor");
    await page.keyboard.press("Escape");
    await drawer.waitFor({ state: "detached" });
    await page.waitForTimeout(200);
    const before = detailReads();
    push("islemler", { items: [job({ id: restartJob, ad: "notlar · Yeniden başlatma", durum: "tamam", bitis: 1791845300 })] });
    await waitFor(() => detailReads() > before, "the application is read again when its job ends");
    await page.waitForFunction(() => document.querySelector('[data-testid="action-note"]').textContent === "", null, { timeout: 5000 });

    // A failed job says why, in the job's own words.
    await button("yeniden-baslat").click();
    await waitFor(() => postsTo(islem).length === 2, "restart posted again");
    const failedJob = JOB(jobSeq);
    push("islemler", { items: [job({ id: failedJob, ad: "notlar · Yeniden başlatma", adim: "web başlatılıyor" })] });
    await page.waitForTimeout(200);
    push("islemler", { items: [job({ id: failedJob, ad: "notlar · Yeniden başlatma", durum: "hata", adim: FAILED_STEP, bitis: 1791845310 })] });
    await page.getByTestId("action-error").filter({ hasText: "İşlem başarısız: " + FAILED_STEP }).waitFor();
    assert.equal(await page.getByTestId("action-error").getAttribute("role"), "alert");
    await shot(page, "1440-light-uygulama-hata.png");

    // Durdur asks first; Esc keeps it running and gives the focus back.
    await button("durdur").click();
    const stopDialog = page.getByRole("dialog", { name: "notlar durdurulsun mu?" });
    await stopDialog.waitFor();
    assert.equal(await active(page), "Vazgeç");
    assert.equal(await stopDialog.locator(".modal-desc").innerText(), "Kurulu kalır; istediğinizde başlatırsınız.");
    assert.deepEqual(await stopDialog.locator(".modal-list li").allInnerTexts(), ["Servisler durur; sunucu yeniden başlasa da kapalı kalır."]);
    for (let n = 0; n < 3; n++) await page.keyboard.press("Tab");
    assert(await stopDialog.evaluate((d) => d.contains(document.activeElement)), "Tab stays in the dialog");
    await shot(page, "1440-light-uygulama-durdur.png");
    await page.keyboard.press("Escape");
    await stopDialog.waitFor({ state: "detached" });
    assert.equal(await active(page), "Durdur", "focus back on Durdur");
    assert.equal(postsTo(islem).length, 2, "nothing sent");
    // An error reply stays in the dialog, in the backend's words.
    expectedFailures = ["/api/konsol/uygulamalar/notlar/islem"];
    replies.push({ status: 409, body: { error: BUSY } });
    await button("durdur").click();
    await stopDialog.locator('[data-onay="evet"]').click();
    await stopDialog.getByTestId("dialog-error").filter({ hasText: BUSY }).waitFor();
    assert.equal(await stopDialog.getByTestId("dialog-error").getAttribute("role"), "alert");
    await stopDialog.getByRole("button", { name: "Durdur" }).click();
    await stopDialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost(islem), { eylem: "durdur", revizyon: "rev-notlar-7" });
    // A direct action's error shows on the page.
    replies.push({ status: 409, body: { error: BUSY } });
    await button("yeniden-baslat").click();
    await page.getByTestId("action-error").filter({ hasText: BUSY }).waitFor();
    // Güncelle: what an image update does; its job's end reads the page again and says how it went.
    await button("guncelle").click();
    const updateDialog = page.getByRole("dialog", { name: "notlar güncellensin mi?" });
    await updateDialog.waitFor();
    assert.equal(await updateDialog.locator(".modal-desc").innerText(), "Yeni sürüm yayınlanmış.");
    assert.deepEqual(await updateDialog.locator(".modal-list li").allInnerTexts(), ["Her servisin imaj etiketi yeniden çekilir ve özeti karşılaştırılır.",
      "Özet değişen servisler yeni imajla yeniden başlar; kısa bir kesinti olabilir.", "Bir servis başlamazsa eski imajlara geri dönülür.",
      "Veriler uygulamanın klasörlerinde kalır."]);
    await updateDialog.getByRole("button", { name: "Güncelle" }).click();
    await updateDialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost(islem), { eylem: "guncelle", revizyon: "rev-notlar-7" });
    const updateJob = JOB(jobSeq);
    push("islemler", { items: [job({ id: updateJob, ad: "notlar · İmaj güncelleme", adim: "İmaj indiriliyor" })] });
    await page.waitForTimeout(200);
    const beforeUpdate = detailReads();
    push("islemler", { items: [job({ id: updateJob, ad: "notlar · İmaj güncelleme", durum: "tamam", bitis: 1791845400 })] });
    await waitFor(() => detailReads() > beforeUpdate, "read again when the image update ends");
    await page.getByTestId("action-note").filter({ hasText: "notlar: imajlar zaten güncel." }).waitFor();
    assert.equal(reads("/api/konsol/konteynerler/islem").at(-1).query, `?id=${updateJob}`, "the job's own record");
    // Kaldır keeps the data by default: a sheet with the choice, the body names only the data choice and the revision.
    const kaldir = "/api/konsol/uygulamalar/notlar/kaldir";
    await button("kaldir").click();
    const removeSheet = page.getByRole("dialog", { name: "notlar kaldırılsın mı?" });
    await removeSheet.waitFor();
    assert.match(await removeSheet.getAttribute("class"), /modal-sheet/);
    assert.equal(await removeSheet.locator(".modal-desc").innerText(), "Uygulama kaldırılır; verileri siz seçmedikçe kalır.");
    assert.deepEqual(await removeSheet.locator(".modal-list li").allInnerTexts(), [
      "Servisler durur; konteynerleri, birimleri, ağı ve gizli değerleri kaldırılır.", "İmajlar kalır; Gelişmiş → Podman'dan silinir.",
      "Sunucu klasörlerine (/srv) dokunulmaz."]);
    const keep = removeSheet.getByRole("radio", { name: /Verileri sakla/ });
    const wipe = removeSheet.getByRole("radio", { name: /Verileri sil/ });
    assert(await keep.isChecked(), "keeping the data is the default");
    assert(await keep.evaluate((el) => el === document.activeElement), "the default has focus");
    assert.equal(await removeSheet.locator('[data-veri="sakla"] .choice-sub').innerText(), "Uygulamanın klasörü /var/lib/master-stack/uygulamalar/notlar olduğu gibi kalır.");
    assert.equal(await removeSheet.getByRole("textbox").count(), 0, "no word to type while the data stays");
    const removeButton = removeSheet.locator('[data-onay="kaldir"]');
    assert.equal(await removeButton.innerText(), "Kaldır");
    assert(await removeButton.isEnabled());
    await shot(page, "1440-light-uygulama-kaldir.png");
    // Choosing to delete asks for the application's name; going back to keep needs none again.
    await wipe.check();
    const word = removeSheet.getByRole("textbox", { name: "Onaylamak için notlar yazın" });
    await word.waitFor();
    assert(await removeButton.isDisabled(), "not before the name");
    assert.equal(await removeButton.innerText(), "Kaldır ve verileri sil");
    await keep.check();
    assert(await removeButton.isEnabled());
    await removeButton.click();
    await removeSheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost(kaldir), { veri: "sakla", revizyon: "rev-notlar-7" });
    await page.getByTestId("action-note").filter({ hasText: "Kaldırılıyor; ilerlemesi İşlemler'de görünür." }).waitFor();
    // A finished removal leads back to the list; the application's page is not read again.
    const removeJob = JOB(jobSeq);
    data.uygulamalar = { ...data.uygulamalar, items: data.uygulamalar.items.filter((a) => a.ad !== "notlar") };
    push("islemler", { items: [job({ id: removeJob, ad: "notlar · Kaldırma" })] });
    await page.waitForTimeout(200);
    const beforeRemove = detailReads();
    push("islemler", { items: [job({ id: removeJob, ad: "notlar · Kaldırma", durum: "tamam", bitis: 1791845500 })] });
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.locator(".app-table").waitFor();
    assert.deepEqual(await rowNames(page), ["arsiv", "galeri", "pano", "yedek"]);
    assert.equal(detailReads(), beforeRemove, "the removed application is not read again");
    await page.context().close();
    expectedFailures = [];
    data.uygulamalar = uygulamalar(apps(), { altyapi: ALTYAPI });

    // ================= deleting the data: the typed name (Turkish case rules); a Kubernetes application from an image
    page = await newPage();
    await page.goto(url("#/uygulamalar/yedek"));
    await page.locator("main h1").filter({ hasText: "yedek" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "Durdurulmuş" }).waitFor();
    assert.deepEqual(await actions(), ["baslat", "kaldir"], "no update for a pinned image");
    assert.equal(await page.getByTestId("app-warnings").count(), 0);
    await page.getByTestId("app-format").filter({ hasText: "Kubernetes · 1 servis" }).waitFor();
    assert.equal(await page.locator('[data-servis="yedekle"]').getByTestId("service-health").innerText(), "—", "a stopped service shows no health");
    assert.equal(await page.locator('[data-servis="yedekle"]').getByTestId("service-version").count(), 0, "a pinned image has no version line");
    await page.getByRole("tab", { name: "Portlar" }).click();
    await page.getByTestId("ports").getByText("Bu uygulamanın portu yok").waitFor();
    await page.getByRole("tab", { name: "Depolama" }).click();
    await page.getByTestId("mounts").getByText("Bu uygulamaya bağlı klasör yok").waitFor();
    await page.getByRole("tab", { name: "Tanım" }).click();
    assert.equal(await page.getByTestId("source-kind").innerText(), "Bir imajdan");
    assert.match(await page.getByTestId("source").innerText(), /registry\.example\/yedek:1\.0/);
    assert.equal(await page.getByTestId("secrets").locator(".meter-note").first().innerText(), "Gizli değer yok.");
    await page.getByRole("tab", { name: "Günlük" }).click();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByRole("radiogroup", { name: "Servis" }).count(), 0, "one service: no choice");
    assert.equal(reads("/api/konsol/uygulamalar/yedek/gunluk").at(-1).query, "?servis=yedekle&satir=200");
    await page.getByTestId("app-actions").locator('[data-eylem="kaldir"]').click();
    const wipeSheet = page.getByRole("dialog", { name: "yedek kaldırılsın mı?" });
    await wipeSheet.waitFor();
    await wipeSheet.getByRole("radio", { name: /Verileri sil/ }).check();
    const name = wipeSheet.getByRole("textbox", { name: "Onaylamak için yedek yazın" });
    await name.fill("yede");
    assert(await wipeSheet.locator('[data-onay="kaldir"]').isDisabled());
    await name.fill("YEDEK");
    assert(await wipeSheet.locator('[data-onay="kaldir"]').isEnabled(), "Turkish case rules for the name");
    await shot(page, "1440-light-uygulama-veri-sil.png");
    await wipeSheet.locator('[data-onay="kaldir"]').click();
    await wipeSheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/konsol/uygulamalar/yedek/kaldir"), { veri: "sil", onay: "yedek", revizyon: "rev-yedek" }, "the name itself, not what was typed");
    await page.context().close();

    // ================= partly running with a failing health check; a job running; a log that cannot be read; an unknown name
    page = await newPage();
    await page.goto(url("#/uygulamalar/galeri"));
    await page.locator("main h1").filter({ hasText: "galeri" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "Kısmen çalışıyor" }).waitFor();
    assert.deepEqual(await actions(), ["durdur", "baslat", "guncelle", "kaldir"]);
    const unhealthy = page.getByTestId("note-unhealthy");
    await unhealthy.waitFor();
    assert.equal(await unhealthy.innerText(), "Sağlık denetimi başarısız: web. Nedeni için Günlük bölümüne bakın.");
    assert.equal(await unhealthy.getByRole("link", { name: "Günlük" }).getAttribute("href"), "#/uygulamalar/galeri?sekme=gunluk&servis=web");
    assert.equal(await page.locator('[data-servis="isci"]').getByTestId("service-state").innerText(), "Durdurulmuş");
    await page.getByTestId("app-actions").locator('[data-eylem="baslat"]').click();
    await waitFor(() => lastPost("/api/konsol/uygulamalar/galeri/islem")?.eylem === "baslat", "start posted");
    assert.deepEqual(lastPost("/api/konsol/uygulamalar/galeri/islem"), { eylem: "baslat", revizyon: "rev-galeri" });

    await page.goto(url("#/uygulamalar/arsiv"));
    await page.locator("main h1").filter({ hasText: "arsiv" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "İşlemde…" }).waitFor();
    assert.deepEqual(await actions(), [], "a job runs on it: no action, no removal");

    expectedFailures = ["/api/konsol/uygulamalar/pano/gunluk"];
    await page.goto(url("#/uygulamalar/pano?sekme=gunluk"));
    await page.locator("main h1").filter({ hasText: "pano" }).waitFor();
    await page.getByTestId("log-error").filter({ hasText: LOG_ERROR }).waitFor();
    assert.equal(await page.getByTestId("log-error").getAttribute("role"), "alert");
    await page.getByRole("tab", { name: "Tanım" }).click();
    assert.equal(await page.getByTestId("source-kind").innerText(), "Bir adresten");
    assert.match(await page.getByTestId("source").innerText(), /https:\/\/files\.example\.org\/pano\/compose\.yaml/);
    expectedFailures = ["/api/konsol/uygulamalar/yok"];
    await page.goto(url("#/uygulamalar/yok"));
    await page.getByText("Bu uygulama yok").waitFor();
    assert.equal(await page.getByText("Uygulama bulunamadı.").count(), 1);
    await page.context().close();
    expectedFailures = [];

    // ================= the live log switch: every 5 s while on, from the address too
    page = await newPage({}, { clock: true });
    await page.goto(url("#/uygulamalar/notlar?sekme=gunluk"));
    await page.getByTestId("log-lines").waitFor();
    await page.waitForTimeout(100);
    const l0 = reads(logPath).length;
    await page.clock.runFor(10000);
    await page.waitForTimeout(150);
    assert.equal(reads(logPath).length, l0, "no reads while Canlı is off");
    const liveSwitch = page.getByRole("switch", { name: "Canlı" });
    await liveSwitch.click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk&canli=1");
    assert.equal(await liveSwitch.getAttribute("aria-checked"), "true");
    await page.clock.runFor(5000);
    await waitFor(() => reads(logPath).length === l0 + 1, "read after 5 s");
    await page.clock.runFor(5000);
    await waitFor(() => reads(logPath).length === l0 + 2, "and after 10 s");
    await liveSwitch.click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk");
    await page.clock.runFor(15000);
    await page.waitForTimeout(150);
    assert.equal(reads(logPath).length, l0 + 2, "off again: no more reads");
    await page.goto(url("#/uygulamalar/notlar?sekme=gunluk&canli=1"));
    await page.reload();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByRole("switch", { name: "Canlı" }).getAttribute("aria-checked"), "true", "on from the address");
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes
    for (const colorScheme of ["light", "dark"]) {
      page = await newPage({ colorScheme });
      for (const [name, hash] of [["genel", "#/genel"], ["uygulamalar", "#/uygulamalar"], ["uygulama", "#/uygulamalar/notlar"]]) {
        await page.goto(url(hash));
        await page.locator(name === "uygulamalar" ? ".app-table" : name === "genel" ? ".app-card" : "[data-testid=service]").first().waitFor();
        await noStyles(page, `1440 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `1440 ${colorScheme} ${name}`);
        await shot(page, `1440-${colorScheme}-${name}.png`, true);
      }
      await page.context().close();

      page = await newPage({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
      await page.goto(url("#/genel"));
      await page.locator(".app-card").first().waitFor();
      const tiles = await page.locator(".app-card").evaluateAll((els) => els.slice(0, 2).map((e) => Math.round(e.getBoundingClientRect().top)));
      assert.equal(tiles[0], tiles[1], "two tiles per row");
      await noStyles(page, `390 ${colorScheme} genel`);
      assert(await noHorizontalScroll(page), "390 genel");
      await shot(page, `390-${colorScheme}-genel.png`, true);
      // A tap anywhere on the tile (here its top right corner, away from the name) opens the page.
      const tile = page.locator('.app-card[data-uygulama="notlar"]');
      const tileBox = await tile.boundingBox();
      await tile.tap({ position: { x: tileBox.width - 14, y: 14 } });
      await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar");
      await page.getByTestId("service").first().waitFor();
      assert.equal(await page.getByRole("navigation", { name: "Alt menü" }).getByRole("link", { name: "Uygulamalar" }).getAttribute("aria-current"), "true");
      assert(await noHorizontalScroll(page), "390 uygulama");
      await shot(page, `390-${colorScheme}-uygulama.png`, true);
      await page.getByTestId("app-actions").locator('[data-eylem="kaldir"]').tap();
      const sheet = page.getByRole("dialog", { name: "notlar kaldırılsın mı?" });
      await sheet.waitFor();
      const sheetBox = await sheet.boundingBox();
      assert(Math.abs(sheetBox.y + sheetBox.height - 844) <= 1 && sheetBox.width === 390, "a bottom sheet on a phone");
      await sheet.getByRole("radio", { name: /Verileri sil/ }).check();
      await sheet.getByRole("textbox").waitFor();
      await shot(page, `390-${colorScheme}-kaldir.png`);
      await sheet.getByRole("button", { name: "Kapat" }).tap();
      await sheet.waitFor({ state: "detached" });
      await page.goto(url("#/uygulamalar"));
      await page.locator(".app-table").waitFor();
      assert.equal(await page.locator('tr[data-uygulama="notlar"]').evaluate((el) => getComputedStyle(el).display), "grid", "cards on a phone");
      assert.equal(await page.locator(".app-table thead").evaluate((el) => getComputedStyle(el).position), "absolute", "column heads only for screen readers");
      assert.equal(await page.locator('tr[data-uygulama="notlar"] .col-state').evaluate((el) => getComputedStyle(el, "::before").content), '"Durum"');
      await noStyles(page, `390 ${colorScheme} uygulamalar`);
      assert(await noHorizontalScroll(page), "390 uygulamalar");
      await shot(page, `390-${colorScheme}-uygulamalar.png`, true);
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      for (const [name, hash, ready] of [["uygulamalar", "#/uygulamalar", ".app-table"], ["genel", "#/genel", ".app-card"],
        ["uygulama", "#/uygulamalar/notlar", "[data-testid=service]"], ["portlar", "#/uygulamalar/notlar?sekme=portlar", "[data-testid=port-table]"],
        ["depolama", "#/uygulamalar/notlar?sekme=depolama", "[data-testid=mounts]"], ["tanim", "#/uygulamalar/notlar?sekme=tanim", "[data-testid=file]"],
        ["gunluk", "#/uygulamalar/notlar?sekme=gunluk", "[data-testid=log-lines]"]]) {
        await page.goto(url(hash));
        await page.locator(ready).first().waitFor();
        await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        await noStyles(page, `320 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `320 ${colorScheme} ${name}`);
        await shot(page, `320-${colorScheme}-${name}.png`, true);
      }
      await page.context().close();
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol's Genel Bakış, Uygulamalar and an application's page (DD-271 phase 3) under the production CSP — Genel Bakış " +
      "(problems with their fix, repair confirmation, POST {kip:onar}, error, running and ended repair, calm state, locked repair with its reason, " +
      "the applications with their state and line, resources, network rates and a failed read, server), network reads every 5 s only while " +
      "shown and visible, a clean server's empty states (no add flow, pointing nowhere else), palette opens application pages (by name or " +
      "service), Uygulamalar (summary, state and warning pills, services, resources, version, filter chips with counts, Turkish-aware search by " +
      "name, service and image, URL state and reload, empty filters, infrastructure, errors, keyboard order and focus ring), application page " +
      "(trail, heading focus, the warning, tabs with arrow keys and URL, Özet's services, Portlar with each port's access row and its link to the row in Adresler, " +
      "Depolama's mounts and data folder, Tanım's source, file, answers without secret values and secrets by name, Günlük per service with " +
      "Yenile, an error and the Canlı switch), exact POST bodies (yeniden-baslat, durdur, guncelle, baslat, kaldir keeping and deleting the data " +
      "with the typed name), dialog focus trap, Esc and focus return, error replies, jobs in the drawer and their end reading the page again, a " +
      "failed job's reason, the image update's result, a removed application, a busy one, an unknown one, 1440/390/320 in light and dark. " +
      "Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
