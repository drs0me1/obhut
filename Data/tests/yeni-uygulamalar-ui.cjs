/* Konsol's Uygulamalar and an application's page (DD-258; rebuild phase 5, the prototype) in the committed build
   under Data/console/yeni, with the production CSP and fixture replies for every endpoint they read or post to
   (yeni-harness.cjs). The applications come from their records (GET /api/konsol/uygulamalar and
   …/uygulamalar/{app}); how each is reached from Erişim's rows; every action is a job followed in İşlemler.
   Uygulama ekle and Tanım's edit have their own suite (yeni-uygulama-ekle-ui.cjs). Fails on any console error,
   CSP violation, page error or layout finding. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulamalar-ui.cjs */
const assert = require("node:assert/strict");
const { uygulama, servis, uygulamalar, ayrinti, soru, inceleme } = require("./yeni-harness.cjs").fixtures;

// ---- fixtures: documentation values only (RFC 5737 addresses, registry.example images); shapes as in api/sema.ts
const OK_CHECKS = [
  { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" },
  { id: "caddy", name: "Caddy", status: "ok", detail: "çalışıyor" },
  { id: "dns", name: "DNS", status: "ok", detail: "yanıt veriyor" }];
const BAD_CHECK = { id: "units", name: "2 eski birim başarısız", status: "bad", detail: "konsol-deneme ve konsol-eski her açılışta hata veriyor." };
const WARNING = { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda okunabilir.",
  duzelt: { bolum: "adresler", hedef: "paylasim" } };
// Each application port's access row as Erişim lists it (rebuild phase 4): its sheet in Adresler is the row's one home.
const NOTLAR_WEB = "uygulama:notlar:web:8080/tcp";
const NOTLAR_UDP = "uygulama:notlar:web:9000/udp";
const NOTLAR_ROW = { tur: "adres", ad: "notlar", tailscale_portu: 8443, internet: "notlar.example.org" };
const accessCell = (durum, adresler = []) => ({ durum, adresler, not: "", uyari: "" });
const row = (app, service, key, satir, o = {}) => ({ id: `uygulama:${app}:${service}:${key}`, ad: `${app} · ${service}`, tur: "uygulama",
  aciklama: key, uygulama: app, servis: service, anahtar: `${service}:${key}`, calisiyor: true, yerel: accessCell("kapali"),
  tailscale: accessCell("kapali"), wireguard: accessCell("kapali"), internet: accessCell("kapali"), satir, web: null, ...o });
const ACCESS_ROWS = [
  row("notlar", "web", "8080/tcp", NOTLAR_ROW, { yerel: accessCell("acik", ["127.0.0.1:62001"]), tailscale: accessCell("acik", ["notlar.ev", "100.64.0.2:8443"]),
    internet: accessCell("acik", ["notlar.example.org"]) }),
  row("notlar", "web", "9000/udp", { tur: "ham", kapsam: "tailscale", port: 9001 }, { tailscale: accessCell("acik", ["100.64.0.2:9001"]) }),
  row("galeri", "web", "80/tcp", { tur: "adres", ad: "galeri", tailscale_portu: null, internet: "" }, { tailscale: accessCell("acik", ["galeri.ev"]) }),
  row("pano", "web", "3000/tcp", { tur: "adres", ad: "pano", tailscale_portu: null, internet: "" }, { tailscale: accessCell("acik", ["pano.ev"]) }),
];
const ROOT_WARNING = "Bu konteyner root olarak başlıyor; kendi kullanıcısına geçmezse /srv'ye Dosyalar hesabının açamayacağı dosyalar yazabilir.";
// What notlar's web runs as now: switched to the Files account (settled), or still root.
const SWITCHED = [{ uid: 1000, ad: "abc", surec: 1, komutlar: ["web-server"] }, { uid: 0, ad: "root", surec: 3, komutlar: ["s6-svscan", "s6-supervise"] }];
const NOW_SWITCHED = "Şu an uygulama abc (uid 1000) olarak çalışıyor: Dosyalar hesabıyla aynı kullanıcı, /srv'ye yazdıkları Dosyalar'dan açılır. " +
  "Başlatıcının 3 süreci root olarak kalıyor.";
const NOW_ROOT = "Şu an bütün süreçleri root olarak çalışıyor: /srv'ye yazdıkları root'a ait olur ve Dosyalar hesabı açamaz.";
let notlarRoot = false;
const D = (c) => c.repeat(64);
const JOB = (n) => String(n).padStart(32, "0");

function apps() {
  return [
    // A job runs on it: the server holds every action back.
    uygulama("arsiv", { durum: "islemde", servisler: [servis("web", { durum: "islemde", imaj: "registry.example/arsiv:2" })], eylemler: [], is: JOB(99) }),
    // One service runs, the other is stopped.
    uygulama("galeri", { durum: "kismen", servisler: [servis("web", { imaj: "registry.example/galeri/web:3", guncelleme: "guncel" }),
      servis("isci", { durum: "durduruldu", imaj: "registry.example/galeri/isci:3", guncelleme: "guncel" })],
    kaynak: { cpu: 1.2, bellek: 52428800 }, guncelleme: "guncel", eylemler: ["baslat", "durdur", "guncelle"], adres: "http://galeri.ev" }),
    // A root-started service with a /srv folder (a warning), a newer image of one of its tags, its live rate and address.
    uygulama("notlar", { servisler: [servis("web", { imaj: "registry.example/notlar/web:2.4", guncelleme: "yeni" }),
      servis("db", { imaj: "registry.example/notlar/db:16", guncelleme: "guncel" })],
    kaynak: { cpu: 3.2, bellek: 220200960 }, guncelleme: "yeni", eylemler: ["durdur", "yeniden-baslat", "guncelle"], revizyon: "rev-notlar-7", uyari: 1,
    ag: { indirme: 1258291, yukleme: 38912, toplam: { indirme: 1288490189, yukleme: 314572800 } }, adres: "http://notlar.ev" }),
    // Its file came from an address; its images have not been checked yet.
    uygulama("pano", { servisler: [servis("web", { imaj: "registry.example/pano:1", guncelleme: "bilinmiyor" })], guncelleme: "bilinmiyor",
      eylemler: ["durdur", "yeniden-baslat", "guncelle"], koken: "adres", ag: { indirme: 0, yukleme: 512, toplam: { indirme: 0, yukleme: 4096 } }, adres: "http://pano.ev" }),
    // A Kubernetes Pod from an image name, stopped, its image pinned by digest.
    uygulama("yedek", { durum: "durduruldu", bicim: "kubernetes", servisler: [servis("yedekle", { durum: "durduruldu", imaj: "registry.example/yedek@sha256:" + D("c") })],
      eylemler: ["baslat"], koken: "imaj", durduruldu: true }),
  ];
}
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
// The inspector's reading of notlar's file (Tanım marks its lines with it).
const NOTLAR_INSPECTION = inceleme({ name: "notlar", questions: [
  soru.ad("notlar"), soru.degisken("TZ", { line: 7 }), soru.degisken("DB_PASSWORD", { line: 7, secret: true, generate: true, services: ["web", "db"] }),
  soru.port("web", 8080, { line: 4, suggest: "notlar" }), soru.port("web", 9000, { line: 4, protocol: "udp" }),
  soru.klasor("web", "/data", { line: 5 }), soru.klasor("web", "/belgeler", { line: 5, source: "/srv/Belgeler", source_kind: "absolute", read_only: true, suggest: "srv",
    folder: "belgeler", srv_path: "/srv/Belgeler" }), soru.baslangic("web"),
  soru.klasor("db", "/var/lib/db", { line: 11, source: "db-veri", folder: "db-veri" }), soru.baslangic("db", { line: 8, suggest: "direct", user: "999:999", direct_user: "999:999" })],
notes: [{ line: 4, key: "ports", text: "Dosyadaki sunucu tarafı (8080) kullanılmaz; port Erişim'den açılır." }] });

function details() {
  const items = Object.fromEntries(data.uygulamalar.items.map((a) => [a.ad, a]));
  const out = {};
  const VERI = "/var/lib/master-stack/uygulamalar/";
  if (items.notlar) {
    out.notlar = ayrinti(items.notlar, {
      guncelleme_denetlendi: 1791844400,
      gizliler: [{ ad: "notlar-db-password", servisler: ["web", "db"] }],
      uyarilar: [{ servis: "web", metin: ROOT_WARNING, simdi: notlarRoot ? NOW_ROOT : NOW_SWITCHED, cozuldu: !notlarRoot }],
      koken: { tur: "dosya", adres: null, imaj: null, konteyner: null, alindi: 1791700000, sha256: D("e") },
      metin: NOTLAR_FILE,
      yanitlar: { name: "notlar", answers: {
        "mount:web:/data": { to: "app" }, "mount:web:/belgeler": { to: "srv", path: "/srv/Belgeler", read_only: true },
        "mount:db:/var/lib/db": { to: "app" }, "var:DB_PASSWORD": { set: true }, "var:TZ": { value: "Europe/Istanbul" },
        "start:web": { mode: "root" }, "start:db": { mode: "direct" } } },
    }, {
      web: { baslangic: "root", ozet: "registry.example/notlar/web@sha256:" + D("a"), calisma: 1791800000, saglik: "healthy", yeniden_baslama: 2,
        surecler: notlarRoot ? [SWITCHED[1]] : SWITCHED,
        portlar: [{ port: 8080, protokol: "tcp", id: NOTLAR_WEB, erisim: NOTLAR_ROW, kullanim: "caddy", tailscale_adi: "notlar", yerel_port: 62001 },
          { port: 9000, protokol: "udp", id: NOTLAR_UDP, erisim: { tur: "ham", kapsam: "tailscale", port: 9001 }, kullanim: "raw", tailscale_adi: null, yerel_port: null }],
        baglamalar: [{ hedef: "/data", tur: "app", yol: VERI + "notlar/veri", salt_okunur: false, boyut: 52428800 },
          { hedef: "/belgeler", tur: "srv", yol: "/srv/Belgeler", salt_okunur: true, boyut: null }, { hedef: "/tmp", tur: "tmpfs", yol: null, salt_okunur: false, boyut: null }],
        gizliler: ["notlar-db-password"] },
      db: { kullanici: "999:999", ozet: "registry.example/notlar/db@sha256:" + D("b"), calisma: 1791800100,
        surecler: [{ uid: 999, ad: "postgres", surec: 2, komutlar: ["postgres"] }],
        baglamalar: [{ hedef: "/var/lib/db", tur: "app", yol: VERI + "notlar/db-veri", salt_okunur: false, boyut: null }], gizliler: ["notlar-db-password"] },
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
  erisim: { read_at: 1791845000, alan: "ev", revizyon: "rev-1", hizmetler: ACCESS_ROWS, hatalar: [], uyarilar: [WARNING],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "sunucu", surum: "1.80.0", adresler: ["100.64.0.2"], cikis_dugumu: true },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, durduruldu: false, aglar: [] }, sertifikalar: [] } },
  uygulamalar: uygulamalar(apps()),
  // Erişim → Adresler (a port's link leads there): the local names, read with the rows.
  adlar: { revizyon: "rev-1", alan: "ev", hatalar: [], adlar: [{ ad: "notlar.ev", aile: 4, hedef: "tailscale", kaynak: "uygulama", satir: NOTLAR_WEB }], kayitlar: [], yonlendirme: false, sunucular: [] },
};

const LOG = Array.from({ length: 30 }, (_, i) => `2026-10-13T01:${String(10 + i).padStart(2, "0")}:00+03:00 notlar_web[812]: satır ${i + 1}`);
const DB_LOG = ["2026-10-13T01:00:00+03:00 notlar_db[640]: hazır"];
const BUSY = "Bu hedefte bir işlem sürüyor.";
const LOG_ERROR = "Uygulama günlüğü okunamadı.";
const FAILED_STEP = "web başlamadı: sağlık denetimi 300 sn içinde geçmedi";

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-uygulamalar-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8769", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies: one application's detail, a service's log, its actions and its removal; the inspector
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
// Tanım marks the stored file's lines with the inspector's dry run of it.
h.handlers["/api/konsol/uygulamalar/denetle"] = ({ method, body }) => (method === "POST"
  ? { body: { inceleme: body.metin === NOTLAR_FILE ? NOTLAR_INSPECTION : inceleme({ name: "yedek", format: "kubernetes" }) } } : undefined);
// A finished job's own record: an image update that found nothing new.
h.handlers["/api/konsol/konteynerler/islem"] = ({ method, query }) => (method === "GET"
  ? { body: { id: query.get("id"), action: "uygulama-guncelle", name: "notlar", state: "done", step: "", result: { ok: true, ad: "notlar", revizyon: "rev-notlar-7", changed: false } } }
  : undefined);

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
const texts = (loc) => loc.evaluateAll((els) => els.map((e) => e.innerText.trim().replace(/\s+/g, " ")));
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}

(async () => {
  h.checkBuild();
  await h.start();
  try {
    let page;
    // ================= a clean server: no applications yet; the empty state offers "Uygulama ekle"
    data.uygulamalar = uygulamalar([]);
    page = await newPage();
    await page.goto(url("#/uygulamalar"));
    await page.getByTestId("page-desc").filter({ hasText: "Henüz uygulama yok" }).waitFor();
    const appsEmpty = page.getByTestId("apps-empty");
    await appsEmpty.waitFor();
    assert.equal(await appsEmpty.locator(".empty-title").innerText(), "Henüz uygulama yok.");
    assert.equal(await appsEmpty.locator(".empty-text").innerText(),
      "Bir Compose ya da Kubernetes dosyasından, bir adresten, bir imaj adından ya da var olan bir konteynerden eklenir.");
    assert.equal(await page.locator(".app-table").count(), 0);
    assert.equal(await page.getByRole("link", { name: "Uygulama ekle" }).count(), 2, "in the toolbar and in the empty state");
    assert.equal(await page.getByTestId("infra").count(), 0, "the infrastructure card is Gelişmiş's (K8)");
    const emptyChips = page.getByRole("group", { name: "Süzgeç" }).getByRole("button");
    assert.deepEqual((await emptyChips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")), ["Tümü 0", "Çalışan 0", "Durdurulmuş 0", "Dikkat 0"]);
    await noStyles(page, "uygulamalar, no applications");
    assert(await noHorizontalScroll(page));
    assert.equal(await page.locator('.sidebar [data-badge="uygulamalar"]').count(), 0, "no count beside an empty section");
    await shot(page, "1440-light-uygulamalar-bos.png", true);
    // The empty state's link opens Uygulama ekle, a page of its own; closing it with nothing entered goes back at once.
    await appsEmpty.getByRole("link", { name: "Uygulama ekle" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulama-ekle");
    const addPage = page.getByTestId("add-flow");
    await addPage.waitFor();
    assert.deepEqual(await addPage.locator(".flow-steps li").evaluateAll((els) => els.map((e) => [e.textContent, e.getAttribute("aria-current")])),
      [["1Kaynak", "step"], ["2Denetçi", null], ["3Plan", null], ["4Kurulum", null]]);
    assert.equal(await active(page), "Uygulama ekle", "the page's heading has the focus");
    await addPage.getByRole("button", { name: "Kapat" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await addPage.waitFor({ state: "detached" });
    assert.equal(await active(page), "Uygulamalar", "back on the list, its heading focused");
    await page.context().close();
    data.uygulamalar = uygulamalar(apps());

    // ================= the palette lists the applications and opens their pages
    page = await newPage();
    await page.goto(url("#/uygulamalar"));
    await page.locator(".app-table").first().waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.waitFor();
    const appOptions = () => palette.locator(".palette-group").filter({ has: page.locator(".palette-group-name", { hasText: "Uygulamalar" }) }).locator(".palette-label").allInnerTexts();
    assert.deepEqual(await appOptions(), ["arsiv", "galeri", "notlar", "pano", "yedek"]);
    await palette.getByRole("combobox").fill("yedekle");
    assert.deepEqual(await appOptions(), ["yedek"], "found by its service's name");
    await palette.getByRole("combobox").fill("notl");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar");
    await page.locator("main h1").filter({ hasText: "notlar" }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the application's heading has focus");
    assert.equal(await page.getByTestId("page-back").isEnabled(), true, "Geri before the trail too: the head's buttons are on every page");
    assert.equal(await page.getByTestId("page-home").getAttribute("href"), "#/genel");
    await page.context().close();

    // ================= Uygulamalar: summary, columns, the access mapping, rate, filters, search, all in the address
    page = await newPage();
    await page.goto(url("#/uygulamalar"));
    await page.getByTestId("page-desc").filter({ hasText: "5 uygulama · 2 çalışıyor · 1 durdurulmuş · 2 dikkat" }).waitFor();
    assert.equal(await page.locator('.sidebar [data-badge="uygulamalar"]').innerText(), "5", "the sidebar counts the same applications");
    const chips = page.getByRole("group", { name: "Süzgeç" }).getByRole("button");
    assert.deepEqual((await chips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")), ["Tümü 5", "Çalışan 2", "Durdurulmuş 1", "Dikkat 2"]);
    assert.equal(await chips.filter({ hasText: "Tümü" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await rowNames(page), ["arsiv", "galeri", "notlar", "pano", "yedek"]);
    assert(await page.locator(".app-table thead").isVisible(), "a table on a wide screen");
    assert.deepEqual(await page.locator(".app-table thead th").evaluateAll((ths) => ths.map((x) => x.innerText.replace(/\s+/g, " ").trim())),
      ["Uygulama", "Durum", "Sunucu Konteyner", "Kaynak", "Ağ", "Eylemler"], "the access column in two halves; no update column");
    const tr = (ad) => page.locator(`tr[data-uygulama="${ad}"]`);
    assert.equal(await tr("notlar").locator(".app-desc").innerText(), "Compose · dosyadan · 2 servis");
    assert.deepEqual(await tr("notlar").locator(".col-state .pill").allInnerTexts(), ["Çalışıyor", "1 uyarı"], "a warning shows beside the state");
    // Each access row as a mapping: the addresses on this server (each in its cell's colour) → the container port.
    const mapOf = (ad) => tr(ad).getByTestId("app-access").locator(".map").evaluateAll((ms) => ms.map((m) => [m.dataset.satir,
      [...m.querySelectorAll(".reach")].map((r) => [r.className.match(/reach-(ok|warning|danger|accent|neutral)/)[1], r.textContent.trim()]),
      m.querySelector(".map-container").textContent.replace(/\s+/g, " ").trim()]));
    assert.deepEqual(await mapOf("notlar"), [
      [NOTLAR_WEB, [["ok", "notlar.ev"], ["ok", "100.64.0.2:8443"], ["ok", "notlar.example.org"]], "→web · 8080/tcp"],
      [NOTLAR_UDP, [["ok", "100.64.0.2:9001"]], "→web · 9000/udp"]], "server → container, the service named when the application has more than one");
    assert.equal(await tr("notlar").getByTestId("app-access").locator(".pill").count(), 0, "no chips, no 'Ham'");
    assert.equal(await tr("notlar").locator(".col-res").innerText(), "%3 · 210 MB");
    assert.equal(await tr("notlar").getByTestId("app-rate").innerText(), "↓ 1 MB/s · ↑ 38 KB/s", "its own bridge's live rate");
    assert.equal(await tr("notlar").getByTestId("app-total").innerText(), "toplam ↓ 1,2 GB · ↑ 300 MB", "what passed through the bridge, under the rate");
    assert.equal(await tr("notlar").locator(".col-ver").count(), 0, "a newer image is the page's Özet and the Dikkat filter's");
    assert.equal(await page.locator(".app-table").innerText().then((s) => s.includes("Yeni imaj")), false);
    assert.equal(await tr("notlar").locator('[data-eylem="ac"]').getAttribute("href"), "http://notlar.ev", "Aç: its first address");
    assert.equal(await tr("notlar").locator('[data-eylem="ac"]').getAttribute("target"), "_blank");
    assert.equal(await tr("galeri").locator(".col-state").innerText(), "Kısmen çalışıyor");
    assert.deepEqual(await mapOf("galeri"), [["uygulama:galeri:web:80/tcp", [["ok", "galeri.ev"]], "→web · 80/tcp"]]);
    assert.deepEqual(await mapOf("pano"), [["uygulama:pano:web:3000/tcp", [["ok", "pano.ev"]], "→3000/tcp"]], "one service: the port alone");
    assert.equal(await tr("galeri").locator(".col-res").innerText(), "%1 · 50 MB");
    assert.equal(await tr("galeri").getByTestId("app-rate").innerText(), "—", "no rate while it has none");
    assert.equal(await tr("galeri").getByTestId("app-total").count(), 0, "and no total");
    assert.equal(await tr("arsiv").locator(".col-state").innerText(), "İşlemde…");
    assert.equal(await tr("arsiv").getByTestId("app-access").innerText(), "Port yok", "no access row: no port");
    assert.equal(await tr("arsiv").locator('[data-eylem="ac"]').count(), 0, "no address, no Aç");
    assert.equal(await tr("yedek").locator(".col-state").innerText(), "Durdurulmuş");
    assert.equal(await tr("yedek").locator(".app-desc").innerText(), "Kubernetes · imajdan · 1 servis");
    assert.equal(await tr("pano").locator(".app-desc").innerText(), "Compose · adresten · 1 servis");
    assert.equal(await tr("pano").locator(".col-res").innerText(), "—", "unknown resources");
    assert.equal(await tr("pano").getByTestId("app-rate").innerText(), "↓ 0 B/s · ↑ 1 KB/s");
    assert.equal(await tr("yedek").getByRole("link", { name: "yedek ayrıntıları" }).getAttribute("href"), "#/uygulamalar/yedek");
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
    data.uygulamalar = uygulamalar(apps());
    // Keyboard order through the toolbar and the first row; the focus is visible.
    await page.goto(url("#/uygulamalar"));
    await page.reload();
    await page.locator(".app-table").waitFor();
    await search.focus();
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "Uygulama ekle");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "arsiv");
    assert.equal(await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle), "solid", "a visible focus ring");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "arsiv ayrıntıları");
    // Errors from the read model.
    data.uygulamalar = { ...data.uygulamalar, hatalar: ["Podman kullanılamıyor."] };
    await page.reload();
    await page.getByTestId("app-errors").getByText("Podman kullanılamıyor.").waitFor();
    assert.equal(await page.getByTestId("app-errors").getByRole("heading").innerText(), "Bazı bilgiler okunamadı");
    await shot(page, "1440-light-uygulamalar-hatalar.png", true);
    data.uygulamalar = { ...data.uygulamalar, hatalar: [] };
    // "Uygulama ekle" in the toolbar opens its page (its own suite drives it).
    await page.reload();
    await page.locator('.apps-toolbar [data-eylem="ekle"]').click();
    await page.waitForURL((u) => u.hash === "#/uygulama-ekle");
    await page.getByTestId("add-flow").getByRole("button", { name: "Vazgeç" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");

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
    await page.getByTestId("app-desc").filter({ hasText: "Compose · dosyadan · 2 servis · yeni imaj var" }).waitFor();
    const actions = () => page.getByTestId("app-actions").locator("[data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem));
    assert.deepEqual(await actions(), ["ac", "yeniden-baslat", "durdur", "kaldir"], "Aç, the backend's eylemler, and Kaldır; Güncelle lives on Özet's update card");
    assert.equal(await page.getByTestId("app-actions").locator('[data-eylem="ac"]').getAttribute("href"), "http://notlar.ev");
    // The warning, prominent above the tabs, with what web runs as now: switched to the Files account, so settled.
    const warnings = page.getByTestId("app-warnings");
    await warnings.waitFor();
    assert.equal(await warnings.getByRole("heading").innerText(), "Bir uyarı, şu an sorun değil");
    assert.equal(await warnings.getAttribute("data-durum"), "cozuldu");
    assert.match(await warnings.getAttribute("class"), /notice-ok/);
    assert.equal(await warnings.locator('li[data-servis="web"]').innerText(), "web: " + ROOT_WARNING + "\n" + NOW_SWITCHED);
    // Özet.
    const tabs = page.getByRole("tablist", { name: "notlar bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Özet", "Erişim", "Depolama", "Tanım", "Günlük"]);
    assert.deepEqual(await tabs.evaluateAll((els) => els.map((e) => [e.getAttribute("aria-selected"), e.tabIndex])),
      [["true", 0], ["false", -1], ["false", -1], ["false", -1], ["false", -1]], "one tab stop");
    const web = page.locator('[data-testid="service"][data-servis="web"]');
    const db = page.locator('[data-testid="service"][data-servis="db"]');
    await web.waitFor();
    assert.equal(await page.getByTestId("app-source").innerText(), "Compose · Dosya");
    assert.equal(await page.getByTestId("app-format").innerText(), "2 servis");
    assert.equal(await page.getByTestId("app-network").innerText(), "ksl-notlar");
    assert.equal(await page.getByTestId("app-data").innerText(), "/var/lib/master-stack/uygulamalar/notlar");
    assert.equal(await page.getByTestId("app-pod").count(), 0, "a Compose application has no pod");
    assert.equal(await page.getByTestId("app-cpu").innerText(), "%3");
    assert.equal(await page.getByTestId("app-memory").innerText(), "210 MB");
    assert.equal(await page.getByTestId("summary-resources").getByTestId("app-rate").innerText(), "↓ 1 MB/s · ↑ 38 KB/s");
    assert.equal(await page.getByTestId("app-version").innerText(), "Yeni imaj");
    assert.deepEqual(await page.getByTestId("update-digest").allInnerTexts(), ["registry.example/notlar/web@sha256:aaaaaaaaaaaa…",
      "registry.example/notlar/db@sha256:bbbbbbbbbbbb…"]);
    const checkedAt = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }).format(new Date(1791844400 * 1000));
    assert.equal(await page.getByTestId("update-checked").innerText(), `${checkedAt} (10 dakika önce)`, "when the registries were last asked");
    assert.equal(await web.getByTestId("service-state").innerText(), "Çalışıyor");
    assert.equal(await web.getByTestId("service-start").innerText(), "Root başladı · abc olarak çalışıyor");
    assert.equal(await web.getByTestId("service-user").innerText(), "İmajın varsayılanı");
    assert.deepEqual(await web.getByTestId("service-processes").locator(".process-line").allInnerTexts(),
      ["abc (uid 1000) · 1 süreç\nweb-server", "root · 3 süreç\ns6-svscan, s6-supervise"]);
    assert.equal(await web.getByTestId("service-image").innerText(), "registry.example/notlar/web:2.4");
    assert.equal(await web.getByTestId("service-digest").innerText(), "registry.example/notlar/web@sha256:aaaaaaaaaaaa…");
    assert.equal(await web.getByTestId("service-health").innerText(), "Sağlıklı");
    assert.equal(await web.getByTestId("service-restarts").innerText(), "2");
    assert.equal(await web.getByTestId("service-started").innerText(), dateTime(1791800000));
    assert.equal(await db.getByTestId("service-start").innerText(), "Doğrudan 999:999 · bütün yetkiler kapalı");
    assert.equal(await db.getByTestId("service-user").innerText(), "999:999");
    assert.equal(await db.getByTestId("service-processes").innerText(), "postgres (uid 999) · 2 süreç\npostgres");
    assert.equal(await db.getByTestId("service-health").innerText(), "Denetim tanımlı değil");
    assert.match(await db.innerText(), /notlar_db/);
    assert.match(await db.innerText(), /konsol-notlar_db\.service/);
    assert.equal(await page.getByTestId("note-unhealthy").count(), 0);
    await noStyles(page, "uygulama");
    await shot(page, "1440-light-uygulama-ozet.png", true);
    // Still root: the warning stays a warning and says so; the service says what it runs as.
    notlarRoot = true;
    await page.reload();
    await warnings.filter({ hasText: NOW_ROOT }).waitFor();
    assert.equal(await warnings.getByRole("heading").innerText(), "Bir uyarı");
    assert.equal(await warnings.getAttribute("data-durum"), "uyari");
    assert.match(await warnings.getByTestId("warning-now").getAttribute("class"), /warn-text/);
    assert.equal(await web.getByTestId("service-start").innerText(), "Root olarak çalışıyor");
    await shot(page, "1440-light-uygulama-root.png");
    notlarRoot = false;
    await page.reload();
    await warnings.filter({ hasText: NOW_SWITCHED }).waitFor();
    // Arrow keys move and choose; the address follows.
    await tabs.first().focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=erisim");
    assert.equal(await active(page), "Erişim");
    await page.keyboard.press("End");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk");
    assert.equal(await active(page), "Günlük");
    await page.keyboard.press("Home");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar");
    assert.equal(await active(page), "Özet");
    await page.keyboard.press("ArrowLeft");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=gunluk");
    assert.equal(await tabs.filter({ hasText: "Günlük" }).getAttribute("aria-selected"), "true");
    // Erişim: each container port with its access row, read-only, each linking to its row in Erişim → Adresler.
    await tabs.filter({ hasText: "Erişim" }).click();
    const access = page.getByTestId("access-table");
    await access.waitFor();
    assert.deepEqual(await access.locator("tbody tr").evaluateAll((els) => els.map((e) => e.dataset.satir)), [NOTLAR_WEB, NOTLAR_UDP]);
    assert.deepEqual((await access.locator("thead th").allInnerTexts()).slice(0, 5), ["Port", "Tür", "Tailscale adı", "Tailscale portu", "İnternet adı"]);
    const addressRow = access.locator(`tr[data-satir="${NOTLAR_WEB}"]`);
    assert.deepEqual(await texts(addressRow.locator("th, td")), ["web · 8080/TCP Yalnız bu sunucu · 127.0.0.1:62001 → 8080", "Adres", "notlar.ev",
      "100.64.0.2:8443", "notlar.example.org", "Adresler'de aç"]);
    assert.deepEqual(await texts(access.locator(`tr[data-satir="${NOTLAR_UDP}"] th, tr[data-satir="${NOTLAR_UDP}"] td`)),
      ["web · 9000/UDP", "Doğrudan port", "Yalnız Tailscale 100.64.0.2:9001", "Adresler'de aç"]);
    assert.deepEqual(await access.getByTestId("access-link").evaluateAll((as) => as.map((a) => a.getAttribute("href"))),
      ["#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A8080%2Ftcp", "#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A9000%2Fudp"]);
    assert.equal(await page.getByTestId("access-edit").getAttribute("href"), "#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A8080%2Ftcp");
    assert.equal(await page.getByTestId("access").locator("button, input, [role=switch]").count(), 0, "read-only: the row changes in Erişim");
    await shot(page, "1440-light-uygulama-erisim.png", true);
    // The link opens the row's panel in Adresler, under the row.
    await addressRow.getByTestId("access-link").click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A8080%2Ftcp");
    const rowSheet = page.locator('tr[data-satir="uygulama:notlar:web:8080/tcp"] + tr.row-detail').getByRole("region", { name: "notlar · web" });
    await rowSheet.getByTestId("row-form").waitFor();
    assert.equal(await rowSheet.getByTestId("row-name").inputValue(), "notlar");
    await rowSheet.getByRole("button", { name: "Vazgeç" }).click();
    await rowSheet.waitFor({ state: "detached" });
    await page.goBack();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/notlar?sekme=erisim");
    await access.waitFor();
    // Depolama: every mount with its path on this server and the way to it in Dosyalar; the data folder.
    await tabs.filter({ hasText: "Depolama" }).click();
    const mounts = page.getByTestId("mount-table");
    await mounts.waitFor();
    assert.deepEqual(await mounts.locator("tbody tr").evaluateAll((els) => els.map((e) => e.dataset.hedef)), ["web:/data", "web:/belgeler", "web:/tmp", "db:/var/lib/db"]);
    assert.deepEqual(await texts(mounts.locator('tr[data-hedef="web:/data"] > *')), ["/data web",
      "/var/lib/master-stack/uygulamalar/notlar/veri Uygulamanın klasörü", "Okuma-yazma", "50 MB", "Sistem dosyaları'nda aç"]);
    assert.deepEqual(await texts(mounts.locator('tr[data-hedef="web:/belgeler"] > *')), ["/belgeler web", "/srv/Belgeler Sunucu klasörü · Dosyalar hesabı",
      "Salt okunur", "—", "Dosyalar'da aç"]);
    assert.deepEqual(await texts(mounts.locator('tr[data-hedef="web:/tmp"] > *')), ["/tmp web", "Geçici (bellekte)", "—", "—", ""]);
    assert.equal(await mounts.locator('tr[data-hedef="db:/var/lib/db"] [data-testid=mount-size]').innerText(), "—", "a folder not measured yet");
    assert.deepEqual(await mounts.locator("tbody a").evaluateAll((as) => as.map((a) => a.getAttribute("href"))), [
      "#/dosyalar?sekme=sistem&yol=var%2Flib%2Fmaster-stack%2Fuygulamalar%2Fnotlar%2Fveri", "#/dosyalar?sekme=srv&yol=Belgeler",
      "#/dosyalar?sekme=sistem&yol=var%2Flib%2Fmaster-stack%2Fuygulamalar%2Fnotlar%2Fdb-veri"]);
    assert.equal(await page.getByTestId("data-path").innerText(), "/var/lib/master-stack/uygulamalar/notlar");
    await shot(page, "1440-light-uygulama-depolama.png", true);
    // Tanım: the source and when it was read, the answers (a secret only "Kayıtlı", a port's use from its row), the
    // secrets by name, the units, the file with the inspector's marks beside its lines.
    const denetle = "/api/konsol/uygulamalar/denetle";
    await tabs.filter({ hasText: "Tanım" }).click();
    await page.getByTestId("source").waitFor();
    await waitFor(() => postsTo(denetle).length === 1, "the stored file is inspected for its marks");
    assert.deepEqual(lastPost(denetle), { metin: NOTLAR_FILE }, "its text only: nothing else is sent");
    assert.equal(await page.getByTestId("source-kind").innerText(), "Dosya");
    assert.equal(await page.getByTestId("source-sha").innerText(), D("e"));
    assert.match(await page.getByTestId("source-read").innerText(), new RegExp("^" + dateTime(1791700000) + " · "));
    assert.equal(await page.getByTestId("source").locator('[data-eylem="kaynaktan-yenile"]').count(), 0, "a pasted file has no source to refresh from");
    const answer = (id) => page.getByTestId("answers").locator(`[data-yanit="${id}"]`).innerText();
    assert.equal(await answer("port:web:8080/tcp"), "Adres · notlar.ev");
    assert.equal(await answer("port:web:9000/udp"), "Doğrudan port · Tailscale");
    assert.equal(await answer("var:DB_PASSWORD"), "Kayıtlı", "a secret answer never shows a value");
    assert.equal(await answer("var:TZ"), "Europe/Istanbul");
    assert.equal(await answer("mount:web:/belgeler"), "/srv/Belgeler · salt okunur");
    assert.equal(await answer("mount:web:/data"), "Uygulamanın klasörü");
    assert.equal(await answer("start:web"), "Root olarak başlar · imaj isterse kendi kullanıcısına geçer");
    assert.equal(await answer("start:db"), "Doğrudan 999:999 · bütün yetkiler kapalı");
    assert.deepEqual(await page.getByTestId("answers").locator("dt").allInnerTexts(), ["8080/TCP · web", "9000/UDP · web", "Klasör /var/lib/db · db",
      "Klasör /belgeler · web", "Klasör /data · web", "db · nasıl başlasın?", "web · nasıl başlasın?", "Gizli değer ${DB_PASSWORD}", "Değişken ${TZ}"]);
    assert.deepEqual(await page.getByTestId("secrets").locator(".mount").allInnerTexts(), ["notlar-db-password\nweb, db"]);
    assert.deepEqual(await page.getByTestId("units").locator("li").allInnerTexts(), ["konsol-notlar.network", "konsol-notlar_db.container", "konsol-notlar_web.container"]);
    const file = page.getByTestId("file").getByRole("textbox", { name: "Kurulum dosyası" });
    assert.equal(await file.inputValue(), NOTLAR_FILE, "the file exactly as given");
    assert.equal(await file.getAttribute("readonly"), "", "read here; Tanımı düzenle edits it");
    await page.getByTestId("file").locator('.code-line[data-satir="4"]').waitFor();
    assert.deepEqual(await page.getByTestId("file").locator(".code-line[data-satir]").evaluateAll((els) => els.map((e) => [e.dataset.satir, e.querySelector(".code-mark").textContent])),
      [["2", "ad · başlatma"], ["4", "port · not"], ["5", "klasör"], ["7", "değişken · gizli değer"], ["8", "başlatma"], ["11", "klasör"]], "the marks beside the lines");
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
    assert.equal(postsTo(denetle).length, 1, "Tanım stays mounted: its file is not inspected again");
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
    // Güncelle (here from Özet's update card): what an image update does; its job's end reads the page again and
    // says how it went.
    await page.locator('[data-eylem="guncelle-ozet"]').click();
    const updateDialog = page.getByRole("dialog", { name: "notlar güncellensin mi?" });
    await updateDialog.waitFor();
    assert.equal(await updateDialog.locator(".modal-desc").innerText(), "Yeni imaj yayımlanmış.");
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
    // Kaldır deletes the data by default (DD-281), after the application's name; "Verileri sakla" keeps it.
    const kaldir = "/api/konsol/uygulamalar/notlar/kaldir";
    await button("kaldir").click();
    const removeDialog = page.getByRole("dialog", { name: "notlar kaldırılsın mı?" });
    await removeDialog.waitFor();
    assert.match(await removeDialog.getAttribute("class"), /modal-dialog/);
    assert.equal((await removeDialog.getByTestId("remove-text").innerText()).replace(/\s+/g, " "),
      "notlar durdurulur; birimleri, ağı, gizli değerleri, adresleri, yerel adları, doğrudan portları, verileri ve iş kayıtları kaldırılır. " +
      "İmajlarını başka bir uygulama ya da konteyner kullanmıyorsa onlar da silinir.");
    const keep = removeDialog.getByRole("checkbox", { name: /Verileri sakla/ });
    assert(!(await keep.isChecked()), "deleting the data is the default");
    const word = removeDialog.getByRole("textbox", { name: "Onaylamak için notlar yazın" });
    assert(await word.evaluate((el) => el === document.activeElement), "the name to type has focus");
    assert.equal(await removeDialog.getByTestId("remove-keep").innerText(), "Verileri sakla\n/var/lib/master-stack/uygulamalar/notlar");
    assert.match(await removeDialog.innerText(), /Sunucu klasörlerine \(\/srv\) hiçbir durumda dokunulmaz\./);
    assert.match(await removeDialog.innerText(), /Veriler geri alınamaz biçimde silinir; onaylamak için uygulamanın adını yazın\./);
    const removeButton = removeDialog.locator('[data-onay="kaldir"]');
    assert(await removeButton.isDisabled(), "not before the name");
    assert.equal(await removeButton.innerText(), "Kaldır ve verileri sil");
    await shot(page, "1440-light-uygulama-kaldir.png");
    // Keeping the data needs no name.
    await keep.check();
    await word.waitFor({ state: "detached" });
    assert.match(await removeDialog.innerText(), /Klasör kalır; aynı adla yeniden eklenince geri bağlanır\./);
    assert.equal(await removeButton.innerText(), "Kaldır");
    assert(await removeButton.isEnabled());
    await removeButton.click();
    await removeDialog.waitFor({ state: "detached" });
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
    data.uygulamalar = uygulamalar(apps());

    // ================= deleting the data: the typed name (Turkish case rules); a Kubernetes application from an image
    page = await newPage();
    await page.goto(url("#/uygulamalar/yedek"));
    await page.locator("main h1").filter({ hasText: "yedek" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "Durdurulmuş" }).waitFor();
    assert.deepEqual(await actions(), ["baslat", "kaldir"], "no update for a pinned image; Başlat, no Aç");
    assert.match(await page.locator('[data-eylem="baslat"]').getAttribute("class"), /btn-primary/, "a stopped application's first action");
    assert.equal(await page.getByTestId("app-warnings").count(), 0);
    await page.getByTestId("app-source").filter({ hasText: "Kubernetes · İmaj adından taslak · registry.example/yedek:1.0" }).waitFor();
    assert.equal(await page.getByTestId("app-version").innerText(), "Denetlenmedi");
    assert.equal(await page.locator('[data-servis="yedekle"]').getByTestId("service-health").innerText(), "—", "a stopped service shows no health");
    assert.equal(await page.locator('[data-eylem="guncelle-ozet"]').count(), 0);
    await page.getByRole("tab", { name: "Erişim" }).click();
    await page.getByTestId("access").getByText("Bu uygulamanın portu yok").waitFor();
    await page.getByRole("tab", { name: "Depolama" }).click();
    await page.getByTestId("mounts").getByText("Bu uygulamaya bağlı klasör yok").waitFor();
    await page.getByRole("tab", { name: "Tanım" }).click();
    assert.equal(await page.getByTestId("source-kind").innerText(), "İmaj adından taslak");
    assert.equal(await page.getByTestId("source-where").innerText(), "registry.example/yedek:1.0");
    assert.equal(await page.getByTestId("secrets").innerText(), "Gizli değer yok.");
    await page.getByRole("tab", { name: "Günlük" }).click();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByRole("radiogroup", { name: "Servis" }).count(), 0, "one service: no choice");
    assert.equal(reads("/api/konsol/uygulamalar/yedek/gunluk").at(-1).query, "?servis=yedekle&satir=200");
    await page.getByTestId("app-actions").locator('[data-eylem="kaldir"]').click();
    const wipeDialog = page.getByRole("dialog", { name: "yedek kaldırılsın mı?" });
    await wipeDialog.waitFor();
    assert(!(await wipeDialog.getByRole("checkbox", { name: /Verileri sakla/ }).isChecked()), "deleting is the default");
    const name = wipeDialog.getByRole("textbox", { name: "Onaylamak için yedek yazın" });
    await name.fill("yede");
    assert(await wipeDialog.locator('[data-onay="kaldir"]').isDisabled());
    await name.fill("YEDEK");
    assert(await wipeDialog.locator('[data-onay="kaldir"]').isEnabled(), "Turkish case rules for the name");
    await shot(page, "1440-light-uygulama-veri-sil.png");
    await wipeDialog.locator('[data-onay="kaldir"]').click();
    await wipeDialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("/api/konsol/uygulamalar/yedek/kaldir"), { veri: "sil", onay: "yedek", revizyon: "rev-yedek" }, "the name itself, not what was typed");
    await page.context().close();

    // ================= partly running with a failing health check; a job running; a log that cannot be read; an
    // address source; an unknown name
    page = await newPage();
    await page.goto(url("#/uygulamalar/galeri"));
    await page.locator("main h1").filter({ hasText: "galeri" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "Kısmen çalışıyor" }).waitFor();
    assert.deepEqual(await actions(), ["ac", "durdur", "baslat", "kaldir"], "a partly running application opens too");
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
    assert.equal(await page.getByTestId("source-kind").innerText(), "Adres");
    assert.equal(await page.getByTestId("source-where").innerText(), "https://files.example.org/pano/compose.yaml");
    assert.equal(await page.getByTestId("source").locator('[data-eylem="kaynaktan-yenile"]').count(), 1, "an address source can be fetched again");
    expectedFailures = ["/api/konsol/uygulamalar/yok"];
    await page.goto(url("#/uygulamalar/yok"));
    await page.getByText("Bu uygulama yok").waitFor();
    assert.equal(await page.getByText("Uygulama bulunamadı.").count(), 1);
    await page.context().close();
    expectedFailures = [];

    // ================= the live rate: the list again every 10 s while it is shown; the live log switch
    page = await newPage({}, { clock: true });
    await page.goto(url("#/uygulamalar"));
    await page.locator('tr[data-uygulama="notlar"] [data-testid="app-rate"]').filter({ hasText: "↓ 1 MB/s · ↑ 38 KB/s" }).waitFor();
    const listReads = reads("/api/konsol/uygulamalar").length;
    data.uygulamalar = uygulamalar(apps().map((a) => (a.ad === "notlar" ? { ...a, ag: { indirme: 3145728, yukleme: 2048, toplam: { indirme: 1291635917, yukleme: 314574848 } } } : a)));
    await page.clock.runFor(10000);
    await page.locator('tr[data-uygulama="notlar"] [data-testid="app-rate"]').filter({ hasText: "↓ 3 MB/s · ↑ 2 KB/s" }).waitFor();
    assert(reads("/api/konsol/uygulamalar").length > listReads, "read again after 10 s");
    data.uygulamalar = uygulamalar(apps());
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
      for (const [name, hash, ready] of [["uygulamalar", "#/uygulamalar", ".app-table"], ["uygulama", "#/uygulamalar/notlar", "[data-testid=service]"],
        ["tanim", "#/uygulamalar/notlar?sekme=tanim", ".code-line[data-satir]"]]) {
        await page.goto(url(hash));
        await page.locator(ready).first().waitFor();
        await noStyles(page, `1440 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `1440 ${colorScheme} ${name}`);
        await shot(page, `1440-${colorScheme}-${name}.png`, true);
      }
      await page.context().close();

      page = await newPage({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
      await page.goto(url("#/uygulamalar/notlar"));
      await page.getByTestId("service").first().waitFor();
      assert.equal(await page.getByRole("navigation", { name: "Alt menü" }).getByRole("link", { name: "Uygulamalar" }).getAttribute("aria-current"), "true");
      assert(await noHorizontalScroll(page), "390 uygulama");
      await shot(page, `390-${colorScheme}-uygulama.png`, true);
      await page.getByTestId("app-actions").locator('[data-eylem="kaldir"]').tap();
      const dialog = page.getByRole("dialog", { name: "notlar kaldırılsın mı?" });
      await dialog.waitFor();
      const box = await dialog.boundingBox();
      assert(Math.abs(box.y + box.height - 844) <= 1 && box.width === 390, "at the bottom on a phone");
      await dialog.getByRole("textbox").waitFor();
      await shot(page, `390-${colorScheme}-kaldir.png`);
      await dialog.getByRole("button", { name: "Kapat" }).tap();
      await dialog.waitFor({ state: "detached" });
      await page.goto(url("#/uygulamalar"));
      await page.locator(".app-table").waitFor();
      assert.equal(await page.locator('tr[data-uygulama="notlar"]').evaluate((el) => getComputedStyle(el).display), "grid", "cards on a phone");
      assert.equal(await page.locator(".app-table thead").evaluate((el) => getComputedStyle(el).position), "absolute", "column heads only for screen readers");
      assert.equal(await page.locator('tr[data-uygulama="notlar"] .col-access').evaluate((el) => getComputedStyle(el, "::before").content), '"Erişim"');
      await noStyles(page, `390 ${colorScheme} uygulamalar`);
      assert(await noHorizontalScroll(page), "390 uygulamalar");
      await shot(page, `390-${colorScheme}-uygulamalar.png`, true);
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      for (const [name, hash, ready] of [["uygulamalar", "#/uygulamalar", ".app-table"],
        ["uygulama", "#/uygulamalar/notlar", "[data-testid=service]"], ["erisim", "#/uygulamalar/notlar?sekme=erisim", "[data-testid=access-table]"],
        ["depolama", "#/uygulamalar/notlar?sekme=depolama", "[data-testid=mount-table]"], ["tanim", "#/uygulamalar/notlar?sekme=tanim", ".code-line[data-satir]"],
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
    console.log("PASS: Konsol's Uygulamalar and an application's page (rebuild phase 5) under the production CSP — a clean server's empty " +
      "state with Uygulama ekle (its own page #/uygulama-ekle, closed at once with nothing entered), the palette opening application pages (by name or service), Uygulamalar " +
      "(summary, state and warning pills, access chips from Erişim's rows, resources, the live rate read again every 10 s, update state, Aç, " +
      "filter chips with counts, Turkish-aware search by name, service and image, URL state and reload, empty filters, errors, keyboard order " +
      "and focus ring), the application page (trail, heading focus, Aç, the warning, tabs with arrow keys and URL; Özet's state, resources " +
      "with the rate, update digests and services; Erişim's read-only rows with links to Adresler and the sheet they open; Depolama's mounts " +
      "with their ways into Dosyalar and the data folder; Tanım's source, answers without secret values, ports from their rows, secrets " +
      "by name, units and the file with the inspector's marks; Günlük per service with Yenile, an error and the Canlı switch), exact POST " +
      "bodies (yeniden-baslat, durdur, guncelle, baslat, kaldir deleting the data by default with the typed name, or keeping it), dialog focus trap, Esc and " +
      "focus return, error replies, jobs in the drawer and their end reading the page again, a failed job's reason, the image update's " +
      "result, a removed application, a busy one, an unknown one, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
