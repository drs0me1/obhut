/* Konsol's new interface, phase 4b (DD-258, DD-267): Dosyalar → Paylaşımlar (folder shares over WebDAV, DD-158,
   DD-179, DD-190, DD-192), in the committed build under Data/console/yeni with the production CSP and fixture
   replies for every endpoint the page reads or posts to (yeni-harness.cjs): the boundary notice, n/max, the
   transports, one card per share with its two connections (switch, permission, duration and renewal,
   reasons, address with copy and the Infuse fields), the acknowledgements (read/write, the internet over
   plain HTTP) with the exact request bodies, refusals in the server's words, one change at a time, the
   create and edit sheets (folder chooser over the user area, user name rules, password rules, show/hide,
   generator, copy), removal with the typed word, the deep links (?yeni=, ?paylasim=), Erişim's ways here,
   the palette without the old interface, 1440/390/320 in light and dark. Fails on any console error, CSP
   violation, page error or layout-audit finding (DD-270). Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-paylasim-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737/6598 addresses, example names); shapes as in api/sema.ts
const NOW = 1791845000;
const DAY = 86400;
const A = "a".repeat(24), B = "b".repeat(24), C = "c".repeat(24), D = "d".repeat(24);
const TS = "http://100.64.0.2:61010", WAN = "http://203.0.113.10:61010";
const clone = (v) => JSON.parse(JSON.stringify(v));
const conn = (o) => ({ enabled: true, permission: "ro", expires: NOW + 7 * DAY, expired: false, available: true, active: true, reason: "", url: "", ...o });
const share = (id, path, username, connections, o = {}) => {
  const urls = Object.fromEntries(Object.entries(connections).filter(([, c]) => c.active).map(([k, c]) => [k, c.url]));
  return { id, path, name: path.split("/").pop(), username, created: NOW - 10 * DAY, changed: NOW - DAY, type: "dir", available: true,
    connections, urls, url: Object.values(urls)[0] ?? "", ...o };
};
const SHARES = [
  share(A, "Filmler", "aile-medya", {
    tailscale: conn({ url: `${TS}/s/${A}/` }),
    wan: conn({ enabled: false, active: false, reason: "Bağlantı kapalı.", url: `${WAN}/s/${A}/` }),
  }),
  share(B, "Belgeler/Ortak", "ofis", {
    tailscale: conn({ expires: NOW - DAY, expired: true, active: false, reason: "Süresi doldu; yeniden süre seçin.", url: `${TS}/s/${B}/` }),
    wan: conn({ permission: "rw", expires: null, url: `${WAN}/s/${B}/` }),
  }),
  share(C, "Eski", "eski-arsiv", {
    tailscale: conn({ active: false, reason: "Klasör bulunamadı veya değiştirildi.", url: `${TS}/s/${C}/` }),
    wan: conn({ enabled: false, active: false, reason: "Klasör bulunamadı veya değiştirildi.", url: `${WAN}/s/${C}/` }),
  }, { available: false }),
];
const LIMITS = { wan_connections: 8, wan_connections_per_ip: 4, tail_connections: 64, wan_auth_parallel: 4, tail_auth_parallel: 2, auth_failures: 5,
  auth_window_seconds: 60, auth_block_seconds: 300, auth_entries: 4096, share_failures: 100, share_window_seconds: 3600, share_block_seconds: 3600, wan_timeout_seconds: 30 };
const WAN_HTTP = { available: true, address: "203.0.113.10", domain: "", mode: "http", scheme: "http", port: 61010, reason: "" };
const view = (o = {}) => ({ host: TS, items: clone(SHARES), max: 32, wan: { ...WAN_HTTP }, tail_enabled: true, limits: LIMITS, ...o });

/** A copy of `v` with one share's connection changed. */
function withConn(v, id, scope, patch) {
  const next = clone(v);
  Object.assign(next.items.find((s) => s.id === id).connections[scope], patch);
  return next;
}

const { uygulama, uygulamalar } = require("./yeni-harness.cjs").fixtures;
const cell = (durum, adresler = [], not = "", uyari = "") => ({ durum, adresler, not, uyari });
const row = (id, ad, tur, cells, aciklama = "") => ({ id, ad, tur, aciklama, uygulama: null, servis: null, anahtar: null, calisiyor: true, yerel: cell("yok"),
  tailscale: cell("yok"), wireguard: cell("kapali"), internet: cell("yok"), satir: null, web: { tail: true, enabled: false, domain: "" }, ayrinti: [], ...cells });

const ROWS = [
  row("panel", "Konsol", "konsol", { tailscale: cell("acik", ["panel.ev"]), internet: cell("kapali") }, "Yönetim paneli"),
  row("paylasim", "Paylaşımlar", "paylasim", { tailscale: cell("acik", ["paylas.ev"], "2 klasör"), internet: cell("acik", [WAN], "1 klasör", "Şifresiz HTTP") }, "WebDAV · 3 klasör"),
];
// One application, so the palette has its Uygulamalar group.
const APPS = [uygulama("notlar")];

const data = {
  kaynaklar: { host: "sunucu", version: "2026.10.16-v2-250", surum: "1.1.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: NOW, sampled_at: NOW, cpu: 2.0, mem: { total: 8375186227, used: 696254464 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "ok", read_at: NOW - 60, checks: [{ id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  guncelleme: { kurulu: "2026.10.16-v2-250", kurulu_surum: "1.1.0", son: "2026.10.16-v2-250", son_surum: "1.1.0", commit: "0".repeat(40), yeni: false,
    denetlendi: NOW, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: NOW, alan: "ev", revizyon: "rev-1", hatalar: [], uyarilar: [], hizmetler: ROWS,
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "", surum: "", adresler: [], cikis_dugumu: null },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, durduruldu: false, not: "", aglar: [] }, sertifikalar: [] } },
  uygulamalar: uygulamalar(APPS),
  adlar: { revizyon: "rev-1", alan: "ev", hatalar: [], adlar: [{ ad: "panel.ev", aile: 4, hedef: "tailscale", kaynak: "base", satir: "panel" }],
    kayitlar: [], yonlendirme: false, sunucular: [] },
  ag: { read_at: NOW, sampled_at: NOW, rx: 1024, tx: 2048 },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
  depolama: { read_at: NOW, kok: "/srv", kullananlar: [], hatalar: [] },
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-paylasim-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8776", data,
  expected: () => expectedFailures });
const { base, waitFor, newPage, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies
let shares = view();
const saveReplies = [];    // replies for the next paylasim/kaydet POSTs (else the current view)
const removeReplies = [];  // replies for the next paylasim/kaldir POSTs
h.handlers["/api/konsol/paylasim"] = ({ method }) => (method === "GET" ? { body: shares } : undefined);
h.handlers["/api/konsol/paylasim/kaydet"] = ({ method }) => (method === "POST" ? saveReplies.shift() ?? { body: shares } : undefined);
h.handlers["/api/konsol/paylasim/kaldir"] = ({ method }) => (method === "POST" ? removeReplies.shift() ?? { body: shares } : undefined);
/** The next save answers with `v`, which is also what the page reads from then on. */
const nextSave = (v) => {
  shares = v;
  saveReplies.push({ body: v });
};
// The files backend's folders (GET /api/list?path=&dirs=1), relative to the user area.
const FOLDERS = { "": ["Filmler", ".gizli", "Belgeler", "Müzik", "indirilenler"], Belgeler: ["Ortak", "Faturalar"], "Belgeler/Faturalar": [], "Belgeler/Ortak": [], Müzik: [], Filmler: [] };
h.handlers["/api/list"] = ({ query }) => {
  const at = query.get("path") ?? "";
  if (query.get("dirs") !== "1") return { status: 400, body: { error: "dirs=1 expected" } };
  if (!(at in FOLDERS)) return { status: 404, body: { error: "Klasör bulunamadı." } };
  return { body: { path: at, skipped: 0, entries: FOLDERS[at].map((name) => ({ name, type: "dir", size: null, mtime: NOW - DAY })) } };
};

// ---- helpers
const UI = "/";
const url = (hash) => new URL(UI + hash, base).href;
const SHARES_URL = "#/dosyalar?sekme=paylasimlar";
const hashOf = (page) => page.evaluate(() => location.hash);
const queryOf = async (page) => new URLSearchParams((await hashOf(page)).split("?")[1] ?? "");
const lastPost = (key) => posts(key).at(-1);
const dateTime = (s) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }).format(new Date(s * 1000));
/** Whether closing or reloading the tab now would ask first (the leave guard, DD-266). */
const guarded = (page) => page.evaluate(() => {
  const event = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
});
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
const card = (page, id) => page.locator(`[data-paylasim="${id}"]`);
const connOf = (page, id, scope) => card(page, id).locator(`[data-baglanti="${scope}"]`);
const sheetOf = (page) => page.locator(".modal").filter({ has: page.getByTestId("share-form") });
const noteIs = (page, text) => page.getByTestId("share-note").filter({ hasText: text }).waitFor();
/** Waits until the focused element is the one `test` names: a data-testid, "H1", or a button's text. */
const focusOn = (page, what) => page.waitForFunction((w) => {
  const e = document.activeElement;
  return Boolean(e) && (e.getAttribute("data-testid") === w || e.tagName === w || e.textContent.trim() === w);
}, what, { timeout: 3000 });

async function openShares(page, extra = "") {
  await page.goto(url(SHARES_URL + extra));
  await page.getByTestId("share-head").waitFor();
}

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= the page: boundary, head, transports, the cards and their connections
    let page = await newPage({ permissions: ["clipboard-read", "clipboard-write"] });
    await openShares(page);
    assert.equal(await page.locator("main h1").innerText(), "Dosyalar");
    assert.equal(await page.getByRole("tab", { name: "Paylaşımlar" }).getAttribute("aria-selected"), "true");
    await card(page, C).waitFor();
    assert.deepEqual(await page.locator(".share-card .card-title").allInnerTexts(), ["Filmler", "Ortak", "Eski"]);
    assert.deepEqual(await page.getByTestId("share-path").allInnerTexts(), ["/srv/Filmler", "/srv/Belgeler/Ortak", "/srv/Eski"], "the folder's place under the user area");
    assert.deepEqual(await page.getByTestId("share-state").allInnerTexts(), ["Açık", "Açık", "Klasör bulunamadı"]);
    assert.match(await card(page, C).getByTestId("share-state").getAttribute("class"), /pill-danger/);
    assert.equal(await page.getByTestId("share-count").innerText(), "3/32 klasör");
    assert.deepEqual(await page.getByTestId("share-routes").locator("dd").allInnerTexts(), ["Şifreli tünel", "Şifresiz HTTP · 203.0.113.10:61010"]);
    assert.equal(await page.getByTestId("share-publication").getAttribute("href"), "#/erisim?sekme=adresler&satir=paylasim", "the address and the internet name stay in Erişim, on their row");
    // The boundary notice: the short form always, the detail in the address.
    const boundary = page.getByTestId("share-boundary");
    assert.match(await boundary.innerText(), /Paylaşmadan önce erişim sınırını kontrol edin/);
    assert.equal(await page.getByTestId("share-boundary-more").count(), 0);
    await page.getByTestId("share-boundary-toggle").click();
    await page.waitForURL((u) => u.hash === SHARES_URL + "&sinir=1");
    assert.match(await page.getByTestId("share-boundary-more").innerText(), /İnternet üzerinden HTTP, parola ve dosyaları şifrelemeden gönderir/, "plain HTTP is named while WAN is HTTP");
    assert.equal(await page.getByTestId("share-boundary-toggle").getAttribute("aria-expanded"), "true");
    await page.reload();
    await page.getByTestId("share-boundary-more").waitFor();
    await page.getByTestId("share-boundary-toggle").click();
    await page.waitForURL((u) => u.hash === SHARES_URL);
    // Filmler: Tailscale open, the internet off but available.
    let ts = connOf(page, A, "tailscale");
    assert.equal(await ts.getByTestId("conn-state").innerText(), "Erişim açık");
    assert.equal(await ts.getByRole("switch", { name: "Filmler · Tailscale bağlantısı" }).getAttribute("aria-checked"), "true");
    assert.equal(await ts.locator('[data-alan="izin"]').inputValue(), "ro");
    assert.equal(await ts.locator('[data-alan="sure"]').inputValue(), "keep");
    assert.equal(await ts.locator('[data-alan="sure"] option:checked').textContent(), "Bitiş · " + dateTime(NOW + 7 * DAY));
    assert.deepEqual(await ts.locator('[data-alan="sure"] option').allTextContents(),
      ["Bitiş · " + dateTime(NOW + 7 * DAY), "1 gün (bugünden)", "7 gün (bugünden)", "30 gün (bugünden)", "Süresiz"]);
    assert.equal(await ts.getByTestId("conn-url").innerText(), `${TS}/s/${A}/`);
    assert.deepEqual(await ts.getByTestId("conn-infuse").locator("dd").allInnerTexts(), ["WebDAV (HTTP)", "100.64.0.2", "61010", `/s/${A}/`]);
    assert.equal(await ts.getByTestId("conn-reason").count(), 0);
    let wan = connOf(page, A, "wan");
    assert.equal(await wan.getByTestId("conn-state").innerText(), "Kapalı");
    assert.equal(await wan.getByTestId("conn-reason").innerText(), "Bağlantı kapalı.");
    assert.equal(await wan.getByTestId("conn-transport").innerText(), "Şifresiz HTTP · 203.0.113.10:61010");
    assert.equal(await wan.getByRole("switch").isDisabled(), false, "an available transport can be turned on");
    assert.match(await wan.innerText(), /Bağlantı kullanılabilir olunca bu adresten erişilir\./);
    // Ortak: Tailscale expired, the internet read/write without an end.
    ts = connOf(page, B, "tailscale");
    assert.equal(await ts.getByTestId("conn-state").innerText(), "Süresi doldu");
    assert.match(await ts.getByTestId("conn-state").getAttribute("class"), /pill-warning/);
    assert.equal(await ts.getByTestId("conn-reason").innerText(), "Süresi doldu; yeniden süre seçin.");
    assert.equal(await ts.locator('[data-alan="sure"] option:checked').textContent(), "Süresi doldu · " + dateTime(NOW - DAY));
    wan = connOf(page, B, "wan");
    assert.equal(await wan.locator('[data-alan="izin"]').inputValue(), "rw");
    assert.equal(await wan.locator('[data-alan="sure"]').inputValue(), "0");
    assert.equal(await wan.locator('[data-alan="sure"] option:checked').textContent(), "Süresiz");
    // Eski: the folder is gone; the reasons say so.
    assert.deepEqual(await card(page, C).getByTestId("conn-reason").allInnerTexts(), ["Klasör bulunamadı veya değiştirildi.", "Klasör bulunamadı veya değiştirildi."]);
    // The account and the address copy.
    assert.equal(await card(page, A).getByTestId("share-user").innerText(), "aile-medya");
    await card(page, A).getByRole("button", { name: "Filmler kullanıcı adı kopyala" }).click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "aile-medya");
    await connOf(page, A, "tailscale").getByRole("button", { name: "Filmler · Tailscale adresi kopyala" }).click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), `${TS}/s/${A}/`);
    await page.getByRole("status").filter({ hasText: "Filmler · Tailscale adresi kopyalandı." }).waitFor();
    await noStyles(page, "list");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-paylasimlar.png", true);

    // ================= instant changes: the exact bodies, the questions, refusals
    // Turning a connection off.
    nextSave(withConn(shares, A, "tailscale", { enabled: false, active: false, reason: "Bağlantı kapalı." }));
    await connOf(page, A, "tailscale").getByRole("switch").click();
    await noteIs(page, "Filmler · Tailscale bağlantısı kapatıldı; hesap ve dosyalar korundu.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { tailscale: { enabled: false } } });
    assert.equal(await connOf(page, A, "tailscale").getByRole("switch").getAttribute("aria-checked"), "false");
    assert.equal(await connOf(page, A, "tailscale").getByTestId("conn-state").innerText(), "Kapalı");
    // Turning it on again.
    nextSave(withConn(shares, A, "tailscale", { enabled: true, active: true, reason: "" }));
    await connOf(page, A, "tailscale").getByRole("switch").click();
    await noteIs(page, "Filmler · Tailscale bağlantısı açıldı.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { tailscale: { enabled: true } } });
    // The internet over plain HTTP asks first; declining sends nothing.
    let saves = posts("paylasim/kaydet").length;
    await connOf(page, A, "wan").getByRole("switch").click();
    let ask = page.getByRole("dialog", { name: "İnternet erişimi şifresiz HTTP ile açılsın mı?" });
    await ask.waitFor();
    assert.match(await ask.getByTestId("ask-http").innerText(), /parola ve dosyaları şifrelemeden gönderir/);
    assert.match(await ask.locator(".modal-desc").innerText(), /^Filmler · Şifresiz HTTP · 203\.0\.113\.10:61010$/);
    await focusOn(page, "Vazgeç");  // the safe answer has the focus
    await page.keyboard.press("Escape");
    await ask.waitFor({ state: "detached" });
    assert.equal(posts("paylasim/kaydet").length, saves, "declined: nothing sent");
    assert.equal(await connOf(page, A, "wan").getByRole("switch").getAttribute("aria-checked"), "false", "the switch shows the saved state");
    await connOf(page, A, "wan").getByRole("switch").click();
    await ask.waitFor();
    nextSave(withConn(shares, A, "wan", { enabled: true, active: true, reason: "" }));
    await ask.getByRole("button", { name: "Onayla ve aç" }).click();
    await ask.waitFor({ state: "detached" });
    await noteIs(page, "Filmler · İnternet bağlantısı açıldı.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { wan: { enabled: true } }, ack_wan_http: true });
    // Read/write asks first; the select keeps the saved value meanwhile.
    saves = posts("paylasim/kaydet").length;
    await connOf(page, A, "tailscale").locator('[data-alan="izin"]').selectOption("rw");
    ask = page.getByRole("dialog", { name: "Yazma izni açılsın mı?" });
    await ask.waitFor();
    assert.equal(await ask.locator(".modal-desc").innerText(), "Filmler · Tailscale");
    assert.match(await ask.getByTestId("ask-write").innerText(), /WebDAV ile silinenler Çöp'e gitmez\./);
    assert.equal(await connOf(page, A, "tailscale").locator('[data-alan="izin"]').inputValue(), "ro");
    await ask.getByRole("button", { name: "Vazgeç" }).click();
    await ask.waitFor({ state: "detached" });
    assert.equal(posts("paylasim/kaydet").length, saves);
    await connOf(page, A, "tailscale").locator('[data-alan="izin"]').selectOption("rw");
    await ask.waitFor();
    nextSave(withConn(shares, A, "tailscale", { permission: "rw" }));
    await ask.getByRole("button", { name: "Yazma izni ver" }).click();
    await ask.waitFor({ state: "detached" });
    await noteIs(page, "Filmler · Tailscale erişimi okuma ve yazma.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { tailscale: { permission: "rw", ack_write: true } } });
    assert.equal(await connOf(page, A, "tailscale").locator('[data-alan="izin"]').inputValue(), "rw");
    // Back to read-only: no question.
    nextSave(withConn(shares, B, "wan", { permission: "ro" }));
    await connOf(page, B, "wan").locator('[data-alan="izin"]').selectOption("ro");
    await noteIs(page, "Ortak · İnternet erişimi salt okunur.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: B, connections: { wan: { permission: "ro" } } });
    // A duration renews from today; choosing the current "Süresiz" again sends nothing.
    nextSave(withConn(shares, B, "tailscale", { expires: NOW + 7 * DAY, expired: false, active: true, reason: "" }));
    await connOf(page, B, "tailscale").locator('[data-alan="sure"]').selectOption("7");
    await noteIs(page, "Ortak · Tailscale süresi kaydedildi: 7 gün, bugünden.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: B, connections: { tailscale: { days: 7 } } });
    assert.equal(await connOf(page, B, "tailscale").getByTestId("conn-state").innerText(), "Erişim açık");
    assert.equal(await connOf(page, B, "tailscale").locator('[data-alan="sure"]').inputValue(), "keep");
    saves = posts("paylasim/kaydet").length;
    await connOf(page, B, "wan").locator('[data-alan="sure"]').selectOption("0");
    await connOf(page, B, "wan").locator('[data-alan="sure"]').selectOption("0");
    assert.equal(posts("paylasim/kaydet").length, saves, "the same unlimited duration is no change");
    nextSave(withConn(shares, A, "wan", { expires: null }));
    await connOf(page, A, "wan").locator('[data-alan="sure"]').selectOption("0");
    await noteIs(page, "Filmler · İnternet süresi kaydedildi: süresiz.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { wan: { days: 0 } } });
    nextSave(withConn(shares, A, "wan", { expires: NOW + DAY }));
    await connOf(page, A, "wan").locator('[data-alan="sure"]').selectOption("1");
    await noteIs(page, "Filmler · İnternet süresi kaydedildi: 1 gün, bugünden.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { wan: { days: 1 } } });
    // A refusal: the server's words on the card, the switch back at the saved state, the view read again.
    expectedFailures = ["/api/konsol/paylasim/kaydet"];
    saveReplies.push({ status: 409, body: { error: "Başka bir kurulum/ayar işlemi sürüyor; yeniden deneyin." } });
    let reads = h.calls["/api/konsol/paylasim"];
    await connOf(page, A, "wan").getByRole("switch").click();
    await card(page, A).getByTestId("share-error").filter({ hasText: "Başka bir kurulum/ayar işlemi sürüyor; yeniden deneyin." }).waitFor();
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { wan: { enabled: false } } });
    assert.equal(await connOf(page, A, "wan").getByRole("switch").getAttribute("aria-checked"), "true");
    await waitFor(() => h.calls["/api/konsol/paylasim"] > reads, "the view read again after a refusal");
    assert.equal(await card(page, B).getByTestId("share-error").count(), 0, "only the card it concerned");
    expectedFailures = [];
    // One change at a time: every control waits while a change is under way.
    let release;
    const gate = new Promise((r) => (release = r));
    await page.route("**/api/konsol/paylasim/kaydet", async (route) => {
      await gate;
      return h.answer(route);
    });
    nextSave(withConn(shares, C, "tailscale", { enabled: false, reason: "Klasör bulunamadı veya değiştirildi." }));
    await connOf(page, C, "tailscale").getByRole("switch").click();
    await page.locator('[data-testid="share-list"][aria-busy="true"]').waitFor();
    assert.equal(await page.locator('.share-list :is([role="switch"], select, button[data-eylem="duzenle"], button[data-eylem="kaldir"]):not([disabled])').count(), 0,
      "every control is off meanwhile");
    assert(await page.getByTestId("share-add").isDisabled());
    await page.getByRole("status").filter({ hasText: "Kaydediliyor…" }).waitFor();
    release();
    await noteIs(page, "Eski · Tailscale bağlantısı kapatıldı; hesap ve dosyalar korundu.");
    await page.unroute("**/api/konsol/paylasim/kaydet");
    assert.equal(await page.locator('[data-testid="share-list"][aria-busy="false"]').count(), 1);
    await noStyles(page, "after changes");

    // ================= removal: the typed word, a refusal, the card gone
    await card(page, C).getByRole("button", { name: "Eski paylaşımını kaldır" }).click();
    ask = page.getByRole("dialog", { name: "“Eski” paylaşımı kaldırılsın mı?" });
    await ask.waitFor();
    assert.equal(await ask.locator(".modal-desc").innerText(), "/srv/Eski");
    assert.deepEqual(await ask.getByTestId("ask-remove").locator("li").allInnerTexts(), [
      "Bu klasörün iki bağlantısı ve ortak hesabı iptal edilir.",
      "Klasör ve içindeki dosyalar silinmez.",
      "WebDAV hizmeti yenilenir; diğer paylaşımların sürmekte olan aktarımları da kesilir, yeniden bağlanabilirler."]);
    const go = ask.getByTestId("ask-go");
    assert(await go.isDisabled(), "not before the word");
    const word = ask.getByRole("textbox");
    await page.waitForFunction(() => document.activeElement?.closest(".confirm-word") !== null);  // the word's field has the focus
    await word.fill("onay");
    assert(await go.isDisabled());
    await word.fill(" ONAYLA ");
    assert.equal(await go.isDisabled(), false, "Turkish case rules, spaces trimmed");
    await shot(page, "1440-light-kaldir.png");
    expectedFailures = ["/api/konsol/paylasim/kaldir"];
    removeReplies.push({ status: 409, body: { error: "Önce bekleyen ayar değişikliğini onaylayın veya geri alın." } });
    await go.click();
    await ask.getByTestId("ask-error").filter({ hasText: "Önce bekleyen ayar değişikliğini onaylayın veya geri alın." }).waitFor();
    assert.deepEqual(lastPost("paylasim/kaldir"), { id: C });
    expectedFailures = [];
    shares = clone(shares);
    shares.items = shares.items.filter((s) => s.id !== C);
    removeReplies.push({ body: shares });
    await go.click();
    await ask.waitFor({ state: "detached" });
    await noteIs(page, "Eski paylaşımı kaldırıldı; klasör ve dosyalar korundu.");
    assert.equal(await card(page, C).count(), 0);
    assert.equal(await page.getByTestId("share-count").innerText(), "2/32 klasör");
    await focusOn(page, "H1");  // the button is gone: the heading has the focus
    await page.context().close();

    // ================= a new share: rules, the folder chooser, the password, both connections, the body
    shares = view();
    page = await newPage({ permissions: ["clipboard-read", "clipboard-write"] });
    await openShares(page);
    await card(page, A).waitFor();
    await page.getByTestId("share-add").click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).has("yeni"));
    let sheet = sheetOf(page);
    await sheet.waitFor();
    assert.equal(await sheet.locator("h2").innerText(), "Klasör paylaş");
    assert.equal(await sheet.getByTestId("draft-switch-tailscale").getAttribute("aria-checked"), "true", "Tailscale starts on while it is published");
    assert.equal(await sheet.getByTestId("draft-switch-wan").getAttribute("aria-checked"), "false", "the internet starts off");
    assert.deepEqual(await sheet.locator('fieldset [data-alan="izin"]').evaluateAll((els) => els.map((e) => e.value)), ["ro", "ro"]);
    assert.deepEqual(await sheet.locator('fieldset [data-alan="sure"]').evaluateAll((els) => els.map((e) => e.value)), ["7", "7"]);
    assert.match(await sheet.innerText(), /İnternet sınırları: 60 saniyede 5 hatalı giriş → 5 dakika engel; IP başına 4, toplam 8 eşzamanlı istek\./);
    assert.equal(await guarded(page), false, "an empty form is no draft");
    // Nothing typed: the rules, no request, the first field focused.
    saves = posts("paylasim/kaydet").length;
    await sheet.getByTestId("share-form-go").click();
    assert.deepEqual(await sheet.locator(".field-error").allInnerTexts(), ["Paylaşılacak klasörü seçin.", "Kullanıcı adını yazın.", "Parola yazın ya da üretin (en az 8 karakter)."]);
    await focusOn(page, "share-folder-value");  // the first field with a problem
    assert.equal(posts("paylasim/kaydet").length, saves);
    // The folder chooser over the user area.
    const listReads = () => h.requests.filter((r) => r.path === "/api/list").map((r) => r.query);
    await sheet.getByTestId("share-folder-toggle").click();
    const panel = sheet.getByTestId("share-folder-panel");
    await panel.locator(".folder-row").first().waitFor();
    assert.deepEqual(await panel.locator(".folder-row").evaluateAll((els) => els.map((e) => e.dataset.klasor)), ["Belgeler", "Filmler", "indirilenler", "Müzik"],
      "by name, hidden folders left out");
    assert.equal(await panel.locator('[data-klasor="Filmler"]').innerText().then((t) => t.includes("Paylaşılıyor")), true, "a shared folder is marked");
    assert.equal(listReads().at(-1), "?path=&dirs=1");
    await panel.getByRole("button", { name: "Belgeler içine gir" }).click();
    await panel.locator('[data-klasor="Belgeler/Faturalar"]').waitFor();
    assert.equal(listReads().at(-1), "?path=Belgeler&dirs=1");
    assert.match(await panel.locator('[data-klasor="Belgeler/Ortak"]').innerText(), /Paylaşılıyor/);
    assert.equal(await panel.locator(".folder-where").textContent(), "Şu an: /srv/Belgeler");
    await panel.getByRole("button", { name: "Faturalar seç" }).click();
    await panel.waitFor({ state: "detached" });
    assert.equal(await sheet.getByTestId("share-folder-value").inputValue(), "/srv/Belgeler/Faturalar");
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("yeni") === "Belgeler/Faturalar", "the chosen folder is in the address");
    assert.equal(await sheet.locator("h2").innerText(), "Faturalar · WebDAV ile paylaş");
    await focusOn(page, "share-folder-toggle");
    // Esc closes the panel only.
    await sheet.getByTestId("share-folder-toggle").click();
    await panel.waitFor();
    await page.keyboard.press("Escape");
    await panel.waitFor({ state: "detached" });
    await sheet.waitFor();
    assert.equal(await guarded(page), true, "a chosen folder is a draft");
    // The user name rules.
    const user = sheet.locator('[data-alan="kullanici"]');
    const userError = () => sheet.locator(".field").filter({ has: page.locator('[data-alan="kullanici"]') }).locator(".field-error").innerText();
    await user.fill("OFIS");
    assert.equal(await userError(), "Bu kullanıcı adı başka bir paylaşımda kullanılıyor.", "case does not make another name");
    await user.fill("-x");
    assert.equal(await userError(), "Kullanıcı adı 3–32 harf/rakam veya . _ - içermeli; harf ya da rakamla başlamalı.");
    await user.fill("muhasebe");
    assert.equal(await sheet.locator(".field").filter({ has: page.locator('[data-alan="kullanici"]') }).locator(".field-error").count(), 0);
    // The password: rules, show/hide, the generator, copy.
    const pass = sheet.locator('[data-alan="parola"]');
    const passError = () => sheet.locator(".field").filter({ has: page.locator('[data-alan="parola"]') }).locator(".field-error").innerText();
    await pass.fill("kisa");
    assert.equal(await passError(), "Parola en az 8 karakter olmalı.");
    await pass.fill("iki:nokta12");
    assert.equal(await passError(), "Parolada : ve kontrol karakteri olamaz.");
    assert.equal(await pass.getAttribute("type"), "password");
    assert.equal(await pass.getAttribute("autocomplete"), "new-password");
    await sheet.getByTestId("share-pass-show").click();
    assert.equal(await pass.getAttribute("type"), "text");
    assert.equal(await sheet.getByTestId("share-pass-show").getAttribute("aria-pressed"), "true");
    await sheet.getByTestId("share-pass-show").click();
    assert.equal(await pass.getAttribute("type"), "password");
    await sheet.getByTestId("share-pass-generate").click();
    const generated = await pass.inputValue();
    assert.match(generated, /^[0-9a-f]{40}$/, "20 random bytes as hex");
    assert.equal(await pass.getAttribute("type"), "text", "a generated password is shown");
    await sheet.getByTestId("share-pass-generate").click();
    assert.notEqual(await pass.inputValue(), generated, "a new one each time");
    const password = await pass.inputValue();
    await sheet.getByRole("button", { name: "Parola kopyala" }).click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), password);
    // Read/write needs its acknowledgement; so does the internet over plain HTTP.
    const wanDraft = sheet.locator('fieldset[data-baglanti="wan"]');
    await wanDraft.locator('[data-alan="izin"]').selectOption("rw");
    await wanDraft.locator('[data-onay="yazma-wan"]').waitFor();
    await sheet.getByTestId("draft-switch-wan").click();
    await wanDraft.locator('[data-onay="http"]').waitFor();
    await sheet.locator('fieldset[data-baglanti="tailscale"] [data-alan="sure"]').selectOption("30");
    await sheet.getByTestId("share-form-go").click();
    assert.deepEqual(await wanDraft.locator(".field-error").allInnerTexts(), ["Yazma iznini bu bağlantı için onaylayın.", "Şifresiz HTTP'yi onaylayın."]);
    assert.equal(posts("paylasim/kaydet").length, saves);
    await wanDraft.locator('[data-onay="yazma-wan"] input').check();
    await wanDraft.locator('[data-onay="http"] input').check();
    await shot(page, "1440-light-yeni.png");
    // A refusal stays in the sheet with what was typed.
    expectedFailures = ["/api/konsol/paylasim/kaydet"];
    saveReplies.push({ status: 400, body: { error: "Bu klasör iç/geçici alan “indirilenler” ile çakışıyor. Bu alanı içermeyen bir klasör seçin." } });
    await sheet.getByTestId("share-form-go").click();
    await sheet.getByTestId("share-form-error").filter({ hasText: "“indirilenler” ile çakışıyor" }).waitFor();
    const body = { path: "Belgeler/Faturalar", username: "muhasebe", password,
      connections: { tailscale: { enabled: true, permission: "ro", days: 30 }, wan: { enabled: true, permission: "rw", days: 7, ack_write: true } }, ack_wan_http: true };
    assert.deepEqual(lastPost("paylasim/kaydet"), body, "the whole new share in one request");
    assert.equal(await user.inputValue(), "muhasebe");
    assert.equal(await pass.inputValue(), password);
    expectedFailures = [];
    const created = view();
    created.items.push(share(D, "Belgeler/Faturalar", "muhasebe", {
      tailscale: conn({ expires: NOW + 30 * DAY, url: `${TS}/s/${D}/` }),
      wan: conn({ permission: "rw", url: `${WAN}/s/${D}/` }),
    }));
    nextSave(created);
    await sheet.getByTestId("share-form-go").click();
    await sheet.waitFor({ state: "detached" });
    await noteIs(page, "Faturalar paylaşımı hazır.");
    assert.deepEqual(lastPost("paylasim/kaydet"), body);
    assert.equal(await hashOf(page), SHARES_URL, "closing removes the sheet from the address");
    await card(page, D).waitFor();
    assert.equal(await page.getByTestId("share-count").innerText(), "4/32 klasör");
    assert.equal(await guarded(page), false, "no draft once saved");
    await focusOn(page, "share-add");
    // Opening again starts empty; the password is gone.
    await page.getByTestId("share-add").click();
    await sheet.waitFor();
    assert.deepEqual([await sheet.locator('[data-alan="kullanici"]').inputValue(), await sheet.locator('[data-alan="parola"]').inputValue()], ["", ""]);
    await page.keyboard.press("Escape");
    await sheet.waitFor({ state: "detached" });
    assert.equal(await hashOf(page), SHARES_URL);
    // A folder that is already shared: the sheet says so and offers its share.
    await page.getByTestId("share-add").click();
    await sheet.waitFor();
    await sheet.getByTestId("share-folder-toggle").click();
    await sheet.getByRole("button", { name: "Filmler seç" }).click();
    await sheet.getByTestId("share-exists").waitFor();
    await sheet.getByTestId("share-form-go").click();
    assert.equal(posts("paylasim/kaydet").length, saves + 2, "no request for a shared folder");
    await sheet.getByTestId("share-exists-edit").click();
    await page.waitForURL((u) => u.hash === `${SHARES_URL}&paylasim=${A}`);
    await sheet.locator("h2").filter({ hasText: "Filmler · paylaşımı düzenle" }).waitFor();
    await page.context().close();

    // ================= editing: only what changed is sent; the folder can move; removal from the sheet
    shares = view();
    page = await newPage();
    await openShares(page);
    await card(page, A).getByRole("button", { name: "Filmler paylaşımını düzenle" }).click();
    await page.waitForURL((u) => u.hash === `${SHARES_URL}&paylasim=${A}`);
    sheet = sheetOf(page);
    await sheet.waitFor();
    assert.equal(await sheet.locator("h2").innerText(), "Filmler · paylaşımı düzenle");
    assert.equal(await sheet.locator(".modal-desc").innerText(), "/srv/Filmler · ortak klasör ve hesap");
    assert.equal(await sheet.getByTestId("share-folder-value").inputValue(), "/srv/Filmler");
    assert.equal(await sheet.locator('[data-alan="kullanici"]').inputValue(), "aile-medya");
    assert.equal(await sheet.locator('[data-alan="parola"]').inputValue(), "");
    assert.equal(await sheet.locator('[data-alan="parola"]').getAttribute("placeholder"), "Boş bırakın: mevcut parola korunur");
    assert.equal(await sheet.locator("fieldset[data-baglanti]").count(), 0, "the connections stay on the card");
    assert(await sheet.getByTestId("share-form-go").isDisabled(), "nothing changed yet");
    assert.equal(await guarded(page), false);
    await sheet.locator('[data-alan="kullanici"]').fill("aile");
    assert.equal(await guarded(page), true);
    nextSave(view({ items: view().items.map((s) => (s.id === A ? { ...s, username: "aile" } : s)) }));
    await sheet.getByTestId("share-form-go").click();
    await sheet.waitFor({ state: "detached" });
    await noteIs(page, "Filmler paylaşımı güncellendi.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, username: "aile" });
    assert.equal(await card(page, A).getByTestId("share-user").innerText(), "aile");
    // A new password and another folder; the same name and an empty password are left out.
    await card(page, A).getByRole("button", { name: "Filmler paylaşımını düzenle" }).click();
    await sheet.waitFor();
    await sheet.locator('[data-alan="parola"]').fill("kisa");
    await sheet.getByTestId("share-form-go").click();
    assert.equal(await sheet.locator(".field-error").innerText(), "Parola en az 8 karakter olmalı.");
    await sheet.locator('[data-alan="parola"]').fill("yeni-parola-2026");
    await sheet.getByTestId("share-folder-toggle").click();
    await sheet.getByRole("button", { name: "Müzik seç" }).click();
    nextSave(view({ items: view().items.map((s) => (s.id === A ? { ...s, username: "aile", path: "Müzik", name: "Müzik" } : s)) }));
    await sheet.getByTestId("share-form-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, path: "Müzik", password: "yeni-parola-2026" });
    await noteIs(page, "Filmler paylaşımı güncellendi.");
    assert.equal(await card(page, A).getByTestId("share-path").innerText(), "/srv/Müzik");
    // Removal from the sheet: the sheet closes, the typed confirmation opens.
    await card(page, B).getByRole("button", { name: "Ortak paylaşımını düzenle" }).click();
    await sheet.waitFor();
    await sheet.getByTestId("share-form-remove").click();
    ask = page.getByRole("dialog", { name: "“Ortak” paylaşımı kaldırılsın mı?" });
    await ask.waitFor();
    assert.equal(await hashOf(page), SHARES_URL);
    await ask.getByRole("textbox").fill("onayla");
    shares = clone(shares);
    shares.items = shares.items.filter((s) => s.id !== B);
    removeReplies.push({ body: shares });
    await ask.getByTestId("ask-go").click();
    await ask.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("paylasim/kaldir"), { id: B });
    assert.equal(await card(page, B).count(), 0);
    await page.context().close();

    // ================= deep links: ?yeni=<folder>, ?paylasim=<id>
    shares = view();
    page = await newPage();
    await openShares(page, "&yeni=" + encodeURIComponent("Müzik"));
    sheet = sheetOf(page);
    await sheet.locator("h2").filter({ hasText: "Müzik · WebDAV ile paylaş" }).waitFor();
    assert.equal(await sheet.getByTestId("share-folder-value").inputValue(), "/srv/Müzik");
    await page.keyboard.press("Escape");
    await sheet.waitFor({ state: "detached" });
    // A folder that is already shared opens its share.
    await openShares(page, "&yeni=Belgeler%2FOrtak");
    await page.waitForURL((u) => u.hash === `${SHARES_URL}&paylasim=${B}`);
    await sheet.locator("h2").filter({ hasText: "Ortak · paylaşımı düzenle" }).waitFor();
    // A share's sheet; one that is gone says so.
    await openShares(page, "&paylasim=" + A);
    await sheet.locator("h2").filter({ hasText: "Filmler · paylaşımı düzenle" }).waitFor();
    await page.goto("about:blank");
    await openShares(page, "&paylasim=" + "e".repeat(24));
    await noteIs(page, "Bu paylaşım bulunamadı; kaldırılmış olabilir.");
    assert.equal(await hashOf(page), SHARES_URL);
    assert.equal(await sheet.count(), 0);
    // A hidden folder is refused before anything is sent.
    saves = posts("paylasim/kaydet").length;
    await openShares(page, "&yeni=.gizli");
    await sheet.waitFor();
    await sheet.locator('[data-alan="kullanici"]').fill("gizli");
    await sheet.locator('[data-alan="parola"]').fill("yeterince-uzun");
    await sheet.getByTestId("share-form-go").click();
    assert.equal(await sheet.locator(".field-error").first().innerText(), "Kök, gizli/iç klasörler ve geçersiz yollar paylaşılamaz.");
    assert.equal(posts("paylasim/kaydet").length, saves);
    await page.keyboard.press("Escape");
    await page.context().close();

    // ================= other states: empty, full, unreadable, HTTPS, no internet
    page = await newPage();
    shares = view({ items: [] });
    await openShares(page);
    const empty = page.getByTestId("share-empty");
    await empty.waitFor();
    assert.match(await empty.innerText(), /Henüz paylaşım yok/);
    assert.equal(await page.getByTestId("share-count").innerText(), "0/32 klasör");
    await empty.getByRole("button", { name: "Paylaşım ekle" }).click();
    await sheetOf(page).waitFor();
    await page.keyboard.press("Escape");
    await shot(page, "1440-light-bos.png");
    shares = view({ max: 3 });
    await page.reload();
    await card(page, C).waitFor();
    assert(await page.getByTestId("share-add").isDisabled(), "the limit is reached");
    assert.match(await page.locator("#paylasim-sinir-dolu").innerText(), /En çok 3 paylaşım oluşturulabilir\./);
    expectedFailures = ["/api/konsol/paylasim"];
    h.status["/api/konsol/paylasim"] = 503;
    await page.reload();
    await page.getByTestId("share-load-error").filter({ hasText: "Paylaşımlar okunamadı: fixture" }).waitFor();
    delete h.status["/api/konsol/paylasim"];
    expectedFailures = [];
    // The internet over HTTPS: no question, the Infuse fields with 443.
    const httpsWan = { available: true, address: "203.0.113.10", domain: "paylas.example.org", mode: "https", scheme: "https", port: 443, reason: "" };
    shares = view({ wan: httpsWan, items: view().items.map((s) => (s.id === A ? { ...s, connections: { ...s.connections, wan: { ...s.connections.wan, url: `https://paylas.example.org/s/${A}/` } } } : s)) });
    await page.reload();
    await card(page, A).waitFor();
    assert.deepEqual(await page.getByTestId("share-routes").locator("dd").allInnerTexts(), ["Şifreli tünel", "HTTPS · paylas.example.org"]);
    assert.deepEqual(await connOf(page, A, "wan").getByTestId("conn-infuse").locator("dd").allInnerTexts(), ["WebDAV (HTTPS)", "paylas.example.org", "443", `/s/${A}/`]);
    nextSave(withConn(shares, A, "wan", { enabled: true, active: true, reason: "" }));
    await connOf(page, A, "wan").getByRole("switch").click();
    await noteIs(page, "Filmler · İnternet bağlantısı açıldı.");
    assert.deepEqual(lastPost("paylasim/kaydet"), { id: A, connections: { wan: { enabled: true } } }, "no acknowledgement over HTTPS");
    await page.getByTestId("share-boundary-toggle").click();
    assert.doesNotMatch(await page.getByTestId("share-boundary-more").innerText(), /şifrelemeden/);
    // The transports not published: the switches of closed connections wait; the way to Erişim.
    const closedWan = { available: false, address: "", domain: "", mode: "off", scheme: "", port: 443, reason: "İnternet paylaşımı kapalı. Erişim → Adresler bölümünde HTTPS alan adı kaydedin." };
    shares = view({ wan: closedWan, tail_enabled: false, items: view().items.map((s) => (s.id === A ? { ...s, connections: {
      tailscale: conn({ enabled: false, active: false, available: false, reason: "Erişim → Adresler bölümünde Tailscale erişimi kapalı.", url: "" }),
      wan: conn({ enabled: false, active: false, available: false, reason: closedWan.reason, url: "" }) } } : s)) });
    await page.reload();
    await card(page, A).waitFor();
    assert.deepEqual(await page.getByTestId("share-routes").locator("dd").allInnerTexts(), ["Tailscale yayını kapalı", closedWan.reason]);
    for (const scope of ["tailscale", "wan"]) {
      const c = connOf(page, A, scope);
      assert(await c.getByRole("switch").isDisabled(), scope + ": a closed transport cannot be turned on here");
      assert.equal(await c.getByTestId("conn-publish").getAttribute("href"), "#/erisim?sekme=adresler&satir=paylasim");
      assert.equal(await c.getByTestId("conn-no-url").innerText(), "Bağlantı adresi kullanılamıyor.");
    }
    assert.equal(await connOf(page, A, "wan").getByTestId("conn-reason").innerText(), closedWan.reason);
    await page.getByTestId("share-add").click();
    sheet = sheetOf(page);
    await sheet.waitFor();
    assert.equal(await sheet.getByTestId("draft-switch-tailscale").getAttribute("aria-checked"), "false", "not on while Tailscale is not published");
    assert(await sheet.getByTestId("draft-switch-tailscale").isDisabled());
    assert(await sheet.getByTestId("draft-switch-wan").isDisabled());
    assert.equal(await sheet.getByTestId("draft-wan-reason").innerText(), closedWan.reason);
    await shot(page, "1440-light-yeni-kapali.png");
    await page.keyboard.press("Escape");
    await page.context().close();

    // ================= the ways here: Erişim's WebDAV rows, the palette
    shares = view();
    page = await newPage();
    await page.goto(url("#/erisim"));
    const matrixLink = page.getByTestId("matrix").locator('tr[data-hizmet="paylasim"]').getByTestId("share-folders");
    await matrixLink.waitFor();
    assert.equal(await matrixLink.getAttribute("href"), "#/dosyalar?sekme=paylasimlar");
    await page.goto(url("#/erisim?sekme=adresler"));
    const pubLink = page.getByTestId("access-rows").locator('tr[data-satir="paylasim"]').getByTestId("share-folders");
    await pubLink.waitFor();
    assert.equal(await pubLink.innerText(), "Klasör izinleri ve süreler: Dosyalar → Paylaşımlar");
    assert.equal(await page.getByTestId("access-rows").locator('tr[data-satir="panel"]').getByTestId("share-folders").count(), 0, "only WebDAV's row");
    // Dosyalar' way to the address opens WebDAV's row sheet, which leads back to the folders.
    await page.goto(url("#/dosyalar?sekme=paylasimlar"));
    await page.getByTestId("share-publication").click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adresler&satir=paylasim");
    const rowSheet = page.getByRole("dialog", { name: "Paylaşımlar" });
    await rowSheet.getByTestId("row-form").waitFor();
    assert.equal(await rowSheet.getByRole("switch", { name: "Tailscale adı" }).getAttribute("aria-checked"), "true");
    assert.equal(await rowSheet.getByTestId("row-shares").getAttribute("href"), "#/dosyalar?sekme=paylasimlar");
    await rowSheet.getByRole("button", { name: "Vazgeç" }).click();
    await rowSheet.waitFor({ state: "detached" });
    await pubLink.click();
    await page.waitForURL((u) => u.hash === SHARES_URL);
    await card(page, A).waitFor();
    await page.goto(url("#/uygulamalar"));
    await page.locator('tr[data-uygulama="notlar"]').waitFor();
    // The palette: no "Eski arayüz"; Paylaşımlar is a Dosyalar tab.
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.waitFor();
    assert.deepEqual(await palette.locator(".palette-group-name").allInnerTexts(), ["Sayfalar", "Uygulamalar", "Adresler", "Eylemler"]);
    await palette.getByRole("combobox").fill("paylaşım");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Dosyalar", "Dosyalar → Paylaşımlar", "paylas.ev"],
      "the folders' tab, and Paylaşımlar' access row in Adresler");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === SHARES_URL);
    await palette.waitFor({ state: "detached" });
    await card(page, A).waitFor();
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes: no style attribute, no horizontal scroll
    shares = view();
    const VIEWS = [
      ["liste", SHARES_URL, "[data-paylasim]", true],
      ["sinir", SHARES_URL + "&sinir=1", "[data-testid=share-boundary-more]", true],
      ["yeni", SHARES_URL + "&yeni=" + encodeURIComponent("Belgeler/Faturalar"), "[data-testid=share-form]", false],
      ["duzenle", SHARES_URL + "&paylasim=" + A, "[data-testid=share-form]", false],
    ];
    for (const colorScheme of ["light", "dark"]) {
      for (const [width, height, mobile] of [[1440, 900, false], [390, 844, true], [320, 640, true]]) {
        page = await newPage({ colorScheme, viewport: { width, height }, ...(mobile ? { isMobile: true, hasTouch: true, reducedMotion: "reduce" } : {}) });
        for (const [name, hash, ready, full] of VIEWS) {
          await page.goto(url(hash));
          await page.locator(ready).first().waitFor();
          await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
          await noStyles(page, `${width} ${colorScheme} ${name}`);
          assert(await noHorizontalScroll(page), `${width} ${colorScheme} ${name}`);
          await shot(page, `${width}-${colorScheme}-${name}.png`, full);
        }
        // The folder chooser open in the sheet, and the removal question.
        await page.goto(url(SHARES_URL + "&yeni="));
        await sheetOf(page).getByTestId("share-folder-toggle").click();
        await sheetOf(page).getByTestId("share-folder-panel").locator(".folder-row").first().waitFor();
        await noStyles(page, `${width} ${colorScheme} klasor`);
        assert(await noHorizontalScroll(page));
        await shot(page, `${width}-${colorScheme}-klasor.png`);
        await page.goto(url(SHARES_URL));
        await card(page, B).getByRole("button", { name: "Ortak paylaşımını kaldır" }).click();
        await page.getByRole("dialog", { name: "“Ortak” paylaşımı kaldırılsın mı?" }).waitFor();
        await noStyles(page, `${width} ${colorScheme} kaldir`);
        await shot(page, `${width}-${colorScheme}-kaldir.png`);
        await page.keyboard.press("Escape");
        const columns = await card(page, A).locator(".share-conns").evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(" ").length);
        assert.equal(columns, width === 1440 ? 2 : 1, `${width}: the connections ${width === 1440 ? "side by side" : "stacked"}`);
        if (width === 390) {
          await page.goto(url(SHARES_URL + "&paylasim=" + A));
          const box = await page.getByRole("dialog", { name: "Filmler · paylaşımı düzenle" }).boundingBox();
          assert(Math.abs(box.y + box.height - height) <= 1 && box.width === width, "a bottom sheet on a phone");
        }
        await page.context().close();
      }
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol phase 4b Paylaşımlar under the production CSP — the boundary notice (detail in the address), n/max, the transports " +
      "(Tailscale, plain HTTP, HTTPS, closed), one card per share (state, folder, account copy) with its two connections (switch, permission, " +
      "duration and renewal from today, expiry, reasons, address copy, Infuse fields, the way to Erişim when not published), the exact bodies " +
      "(enabled, permission with ack_write, days, ack_wan_http only over HTTP), the questions and declining them, refusals in the server's " +
      "words with a fresh read, one change at a time, removal with the typed word and a refusal, the create sheet (folder chooser over the " +
      "user area with /api/list, hidden folders left out, shared ones marked, the user name and password rules, show/hide, the generator, " +
      "copy, the acknowledgements, the whole body, a refusal keeping the form, the password gone after closing, an already shared folder), " +
      "the edit sheet (only changed fields, moving the folder, removal from it), deep links (?yeni=, ?paylasim=, an unknown share, a hidden " +
      "folder), empty / full / unreadable, Erişim's WebDAV rows leading here, the palette without the old interface, " +
      "1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
