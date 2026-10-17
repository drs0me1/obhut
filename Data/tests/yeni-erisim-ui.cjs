/* Konsol's new interface, phase 3 (DD-258): Erişim (Genel, Adresler, Tailscale, Güvenlik duvarı), the Yayınla
   flow and the pending settings change in the committed build under Data/console/yeni, with the production
   CSP and fixture replies for every endpoint they read or post to (yeni-harness.cjs). The WireGuard tab has
   its own suite (yeni-wireguard-ui.cjs). Fails on any console error, CSP violation or page error. Never
   contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-erisim-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737/6598 addresses, example names); shapes as in api/sema.ts
const NOW = 1791845000;
const DAY = 86400;
const VPN_NOTE = "WireGuard cihazları yalnız internete çıkar; bu sunucudaki hizmetlere ulaşamaz.";
const cell = (durum, adresler = [], not = "", uyari = "") => ({ durum, adresler, not, uyari });
const { uygulama, uygulamalar, ayrinti } = require("./yeni-harness.cjs").fixtures;
const row = (id, ad, tur, cells, ayrinti = [], aciklama = "") => ({ id, ad, tur, aciklama, uygulama: null, calisiyor: true, yerel: cell("yok"),
  tailscale: cell("yok"), wireguard: cell("kapali", [], VPN_NOTE), internet: cell("yok"), yayinlar: [], ayrinti, ...cells });

const WARNINGS = [
  { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda okunabilir.",
    duzelt: { bolum: "yayinlar", hedef: "paylasim" } },
  { seviye: "warn", hizmet: "konteyner:medya_web", metin: "medya_web: 203.0.113.10:8096/tcp doğrudan internete açık; şifreleme ve giriş uygulamanın kendisinde.",
    duzelt: { bolum: "uygulama", hedef: "medya" } },
  { seviye: "warn", hizmet: "konteyner:notlar", metin: "notlar.example.org sertifikası 10 gün sonra doluyor; Caddy kendiliğinden yeniler, yenilemezse internetten erişim kesilir.",
    duzelt: { bolum: "yayinlar", hedef: "konteyner:notlar" } },
];
const ROWS = [
  row("panel", "Konsol", "konsol", { tailscale: cell("acik", ["panel.ev"], "Giriş istemez; cihazı Tailscale doğrular."), internet: cell("kapali") }, [], "Yönetim paneli"),
  row("konteyner:notlar", "notlar", "konteyner", { yerel: cell("acik", ["127.0.0.1:8090 → 80/tcp"]), tailscale: cell("acik", ["notlar.ev"]),
    internet: cell("acik", ["notlar.example.org"]) }, [{ baslik: "Konteyner portu", deger: "127.0.0.1:8090 → 80/tcp" },
    { baslik: "DNS", deger: "notlar.ev → 100.64.0.2" }, { baslik: "Caddy", deger: "notlar.example.org → 127.0.0.1:8090" }], "Konteyner"),
  row("konteyner:medya_web", "medya_web", "konteyner", { uygulama: "medya", yerel: cell("kapali"), tailscale: cell("acik", ["100.64.0.2:8096/tcp"]),
    internet: cell("acik", ["203.0.113.10:8096/tcp"], "", "Doğrudan WAN") }, [{ baslik: "Port", deger: "0.0.0.0:8096 → 8096/tcp" }], "Uygulama · medya"),
  row("paylasim", "Paylaşımlar", "paylasim", { tailscale: cell("acik", ["paylas.ev", "100.64.0.2:61010"], "2 klasör"), internet: cell("acik", ["http://203.0.113.10:61010"], "1 klasör", "Şifresiz HTTP") },
    [{ baslik: "Klasör · Filmler", deger: "Tailscale açık · İnternet açık" }], "WebDAV · 2 klasör"),
  row("sistem:ssh", "SSH", "sistem", { tailscale: cell("acik", ["22/tcp"]), internet: cell("acik", ["203.0.113.10:22/tcp"]) }, [], "Uzak kabuk"),
  row("vpn:wg0", "WireGuard wg0", "vpn", { wireguard: cell("yok"), tailscale: cell("acik", ["61001/udp"]), internet: cell("acik", ["203.0.113.10:61001/udp"]) }, [], "Ana ağ"),
];
function erisim(o = {}) {
  return {
    read_at: NOW, alan: "ev", hatalar: [], uyarilar: WARNINGS, hizmetler: ROWS,
    ozet: {
      tailscale: { ipv4: "100.64.0.2", ipv6: "fd7a:115c:a1e0::2", durum: "bagli", anahtar_bitis: NOW + 10 * DAY, ad: "sunucu.example-tailnet.ts.net", surum: "1.88.3",
        adresler: ["100.64.0.2", "fd7a:115c:a1e0::2"], cikis_dugumu: true },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [
        { ad: "SSH", port: 22, proto: "tcp", aileler: [4, 6], kaynak: "temel" },
        { ad: "WireGuard wg0", port: 61001, proto: "udp", aileler: [4], kaynak: "temel" },
        { ad: "Oyun", port: 27015, proto: "udp", aileler: [4], kaynak: "kural" }] },
      wireguard: { kurulu: true, durduruldu: false, not: VPN_NOTE, aglar: [{ arayuz: "wg0", ad: "Ana ağ", etkin: true, port: 61001 }] },
      sertifikalar: [{ ad: "notlar.example.org", hizmet: "konteyner:notlar", durum: "gecerli", bitis: NOW + 10 * DAY }],
    },
    ...o,
  };
}

const GUARD_APP = "Yalnız uygulamanın kendi girişi korur; Konsol bu adreste giriş denetlemez.";
const cand = (o) => ({ servis: null, yerel_ad: null, tailscale: false, internet: false, alan_adi: "", durum: "disabled", mesaj: "İnternet yayını kapalı.", bitis: null,
  hedef: null, giris: GUARD_APP, onay_kelimesi: false, internet_engel: "", kullanilabilir: true, neden: "", konteyner: null, ...o });
const NO_LOOPBACK = "Bu konteynerin yalnız bu sunucuda (127.0.0.1) dinleyen bir portu yok; yayımlanamaz.";
const box = (o) => ({ kaynak: "dis", uygulama: null, calisiyor: true, yerel_portlar: [], diger_portlar: [], ...o });
function candidates() {
  return [
    cand({ id: "panel", tur: "konsol", ad: "Konsol", servis: "panel", yerel_ad: "panel.ev", tailscale: true, giris: "İnternetten Konsol hesabıyla giriş istenir.", onay_kelimesi: true }),
    cand({ id: "konteyner:notlar", tur: "konteyner", ad: "notlar", servis: "elle-notlar", yerel_ad: "notlar.ev", tailscale: true, internet: true,
      alan_adi: "notlar.example.org", durum: "ready", mesaj: "Sertifika doğrulandı.", bitis: NOW + 10 * DAY, hedef: "127.0.0.1:8090",
      konteyner: box({ ad: "notlar", yerel_portlar: [{ host_port: 8090, container_port: 80 }] }) }),
    // An application's container published straight on the internet (no loopback port): nothing to name.
    cand({ id: "konteyner:medya_web", tur: "konteyner", ad: "medya_web", kullanilabilir: false, neden: NO_LOOPBACK,
      konteyner: box({ ad: "medya_web", kaynak: "uygulama", uygulama: "medya", diger_portlar: [{ kapsam: "public", host_port: 8096, container_port: 8096 }] }) }),
    // An application's address port: the container listens on its pool port at 127.0.0.1 (DD-271 phase 3).
    cand({ id: "konteyner:kutu_web", tur: "konteyner", ad: "kutu_web",
      konteyner: box({ ad: "kutu_web", kaynak: "uygulama", uygulama: "kutu", yerel_portlar: [{ host_port: 62001, container_port: 80 }] }) }),
    cand({ id: "konteyner:dis", tur: "konteyner", ad: "dis", kullanilabilir: false, neden: NO_LOOPBACK, konteyner: box({ ad: "dis" }) }),
    cand({ id: "elle:yazici", tur: "elle", ad: "Yazıcı", servis: "elle-yazici", yerel_ad: "yazici.ev", tailscale: true, hedef: "127.0.0.1:631", mesaj: "Hedef yanıt vermiyor." }),
    cand({ id: "paylasim", tur: "paylasim", ad: "WebDAV paylaşımları", servis: "paylasim", yerel_ad: "paylas.ev", tailscale: true, durum: "http", mesaj: "HTTPS alan adı tanımlanmadı.",
      giris: "Klasör hesapları korur; her klasörün internet erişimi Paylaşımlar'dan açılır." }),
  ];
}

const PORTS = [
  { ad: "SSH", aile: 4, proto: "tcp", port: 22, kapsam: "wan", sabit: false },
  { ad: "SSH", aile: 6, proto: "tcp", port: 22, kapsam: "wan", sabit: false },
  { ad: "WireGuard wg0", aile: 4, proto: "udp", port: 61001, kapsam: "wan", sabit: false },
  { ad: "medya · konteyner portu", aile: 4, proto: "tcp", port: 8096, kapsam: "wan", sabit: true },
  { ad: "Caddy", aile: 4, proto: "tcp", port: 80, kapsam: "tail", sabit: false },
  { ad: "dnsmasq", aile: 4, proto: "udp", port: 53, kapsam: "tail", sabit: false },
  { ad: "Konsol · dosya", aile: 4, proto: "tcp", port: 62001, kapsam: "lo", sabit: false },
];
const RULES = [{ id: "u_medya", name: "Medya", family: 4, scope: "tail", proto: "tcp", port: 8096, source: "", allow: true }];
function firewall(o = {}) {
  return {
    revizyon: "rev-1", denetim: { ok: true, metin: "Güvenlik duvarı kuralları beklendiği gibi." }, kurallar: JSON.parse(JSON.stringify(RULES)), portlar: PORTS,
    dinleyiciler: [
      { proto: "tcp", aile: 4, port: 22, adres: "0.0.0.0", kapsam: "any" },
      { proto: "tcp", aile: 4, port: 80, adres: "100.64.0.2", kapsam: "tail" },
      { proto: "udp", aile: 4, port: 53, adres: "100.64.0.2", kapsam: "tail" },
      { proto: "tcp", aile: 4, port: 62001, adres: "127.0.0.1", kapsam: "lo" }],
    teknik: [
      { aile: 4, tablo: "filter", zincir: "INPUT", sira: "1", paket: 12345, bayt: 6789012, kural: "-A INPUT -i lo -j ACCEPT", sahip: "Konsol" },
      { aile: 4, tablo: "filter", zincir: "ts-input", sira: "1", paket: 10, bayt: 900, kural: "-A ts-input -j RETURN", sahip: "Tailscale" },
      { aile: 6, tablo: "filter", zincir: "INPUT", sira: "1", paket: 7, bayt: 560, kural: "-A INPUT -i lo -j ACCEPT", sahip: "Konsol" }],
    aglar: [{ arayuz: "wg0", ad: "Ana ağ", etkin: true }], hatalar: [], ...o,
  };
}
function names() {
  return {
    revizyon: "rev-1", alan: "ev", hatalar: [],
    adlar: [
      { ad: "panel.ev", aile: 4, hedef: "tailscale", kaynak: "base", kapali: false, kilitli: true },
      { ad: "panel.ev", aile: 6, hedef: "fd7a:115c:a1e0::2", kaynak: "base", kapali: false, kilitli: true },
      { ad: "paylas.ev", aile: 4, hedef: "tailscale", kaynak: "base", kapali: false, kilitli: false },
      { ad: "yedek.ev", aile: 4, hedef: "tailscale", kaynak: "yedek", kapali: true, kilitli: false },
      { ad: "notlar.ev", aile: 4, hedef: "tailscale", kaynak: "elle", kapali: false, kilitli: false }],
    kayitlar: [{ name: "yazici.ev", target: "192.0.2.40", enabled: true }], yonlendirme: true, sunucular: ["1.1.1.1", "1.0.0.1"],
  };
}

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-248", surum: "1.1.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: NOW, sampled_at: NOW, cpu: 2.0, mem: { total: 8375186227, used: 696254464 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "ok", read_at: NOW - 60, checks: [{ id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  guncelleme: { kurulu: "2026.08.06-v2-248", kurulu_surum: "1.1.0", son: "2026.08.06-v2-248", son_surum: "1.1.0", commit: "0".repeat(40), yeni: false,
    denetlendi: NOW, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: erisim(),
  uygulamalar: uygulamalar([uygulama("kutu"), uygulama("medya")]),
  yayinlar: { revizyon: "rev-1", alan: "ev", wan_ipv4: "203.0.113.10", adaylar: candidates(), hatalar: [] },
  adlar: names(),
  "guvenlik-duvari": firewall(),
  ag: { read_at: NOW, sampled_at: NOW, rx: 1024, tx: 2048 },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-erisim-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8771", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, count, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies
const plan = (o = {}) => ({ revizyon: "rev-1", onay_sn: 0, degisiklikler: [], etkiler: [], uyarilar: [], uygulanabilir: true, ...o });
const item = (alan, islem, nesne, once, sonra) => ({ alan, islem, nesne, once, sonra });
function settingsPlan(body) {
  if (body.firewall) {
    return plan({ onay_sn: 60, degisiklikler: [item("guvenlik-duvari", "degistir", "SSH", "TCP 22 · İnternet · IPv4 · izin", "TCP 22 · İnternet · IPv4 · engel"),
      item("guvenlik-duvari", "ekle", "Oyun", null, "UDP 27015 · İnternet · IPv4 · izin")], etkiler: ["Güvenlik duvarı kuralları yeniden kurulur."],
    uyarilar: [{ seviye: "info", metin: "Uygulandıktan sonra 60 saniye içinde onaylamazsanız kendiliğinden geri alınır." }] });
  }
  if (body.domain) {
    return plan({ onay_sn: 300, degisiklikler: [item("alan-adi", "degistir", "Yerel alan adı", "ev", body.domain)],
      etkiler: ["dnsmasq yeniden başlar; yerel adlar birkaç saniye yanıt vermeyebilir.", "Caddy ve dosya servisleri yeni adla yeniden başlar."],
      uyarilar: [{ seviye: "warn", metin: `Değişikliği 5 dakika içinde yeni adresten onaylayın: http://panel.${body.domain}. Tailscale yönetim panelindeki split DNS kaydını da yeni ada çevirin.` }] });
  }
  if (body.dns) {
    return plan({ degisiklikler: [item("dns", "kapat", "paylas.ev", "açık", "kapalı"), item("dns", "ekle", "nas.ev", null, "192.0.2.50"),
      item("dns", "degistir", "Dış adlar", "Üst DNS: 1.1.1.1, 1.0.0.1", "Üst DNS: 9.9.9.9, 149.112.112.112")],
    etkiler: ["dnsmasq yeniden başlar; yerel adlar birkaç saniye yanıt vermeyebilir."] });
  }
  if (body.web?.sil) return plan({ degisiklikler: [item("yayin", "kaldir", "Yazıcı", "yazici.ev açık · internet: kapalı · hedef 127.0.0.1:631", null)], etkiler: ["Caddy yapılandırması yeniden yüklenir."] });
  if (body.web) return plan({ degisiklikler: [item("yayin", "ekle", body.web.elle?.name ?? body.web.service, null, `${body.web.elle?.local}.ev açık · internet: kapalı · hedef ${body.web.elle?.upstream}`)],
    etkiler: ["Caddy yapılandırması yeniden yüklenir."] });
  return null;
}
const planReplies = [];   // replies for the next ayarlar/plan POSTs, before settingsPlan()
const applyReplies = [];  // replies for the next ayarlar/uygula POSTs
h.handlers["/api/konsol/ayarlar/plan"] = ({ method, body }) => (method === "POST" ? planReplies.shift() ?? { body: settingsPlan(body) } : undefined);
h.handlers["/api/konsol/ayarlar/uygula"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const forced = applyReplies.shift();
  if (forced) return forced;
  if (body.firewall) return { body: { pending: { id: "p-fw", phase: "awaiting", seconds: 60 } } };
  if (body.domain) return { body: { pending: { id: "p-alan", phase: "awaiting", seconds: 300, domain: { old: "ev", new: body.domain } } } };
  return { body: { pending: null, committed: true } };
};
for (const action of ["onayla", "geri-al", "birak"]) {
  h.handlers["/api/konsol/ayarlar/" + action] = ({ method }) => (method === "POST" ? { body: { ok: true } } : undefined);
}
const yayinReplies = [];
function publicationPlan(req) {
  const c = data.yayinlar.adaylar.find((x) => x.id === req.hedef);
  const local = req.yerel ?? (c.yerel_ad ? c.yerel_ad.split(".")[0] : c.ad);
  const steps = [];
  let web = { service: c.servis, tail: req.tailscale, enabled: req.internet, domain: req.alan_adi };
  if (c.tur === "konsol" && req.onay) web.confirm = req.onay;
  if (!c.servis) {
    web = { service: "elle-" + local, tail: req.tailscale, enabled: req.internet, domain: req.alan_adi,
      elle: { name: req.ad ?? c.ad, local, upstream: "127.0.0.1:" + c.konteyner.yerel_portlar[0].host_port } };
  }
  const istek = { revision: req.revizyon, web };
  steps.push({ tur: "ayar", baslik: "Ad ve erişim", aciklama: `Tailscale adı ${local}.ev ${req.tailscale ? "açık" : "kapalı"}; internet adı ${req.internet ? req.alan_adi : "kapalı"}.`, istek });
  const engel = c.tur === "konsol" && req.internet && !req.onay ? "Panel'i internete açmak için onayla yazın." : "";
  return { hedef: c, adimlar: steps, engel, dns: req.internet && req.alan_adi ? { ad: req.alan_adi, tur: "A", deger: "203.0.113.10" } : null,
    plan: engel ? null : plan({ degisiklikler: [item("yayin", req.internet ? "ac" : "degistir", `${c.ad} · internet adı`, c.internet ? c.alan_adi : "kapalı", req.internet ? req.alan_adi : "kapalı")],
      etkiler: ["Caddy yapılandırması yeniden yüklenir.", ...(req.internet ? ["İnternet adı için HTTPS sertifikası alınır (en çok 1 dakika)."] : [])] }),
    uyarilar: [] };
}
h.handlers["/api/konsol/yayinlar/plan"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const forced = yayinReplies.shift();
  if (forced) return typeof forced === "function" ? forced(body) : forced;
  return { body: publicationPlan(body) };
};
// An application's page (a warning's Düzelt leads there).
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)$/, (req, m) => {
  const item = data.uygulamalar.items.find((a) => a.ad === m[1]);
  return item ? { body: ayrinti(item) } : { status: 404, body: { error: "Uygulama bulunamadı." } };
}]);

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const hashOf = (page) => page.evaluate(() => location.hash);
const lastPost = (key) => posts(key).at(-1);
/** Whether closing or reloading the tab now would ask first (the leave guard, DD-266). */
const guarded = (page) => page.evaluate(() => {
  const event = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
});
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
const flowSheet = (page) => page.getByRole("dialog").filter({ has: page.locator(".stepper") });
const clone = (v) => JSON.parse(JSON.stringify(v));
const dateText = (seconds) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", year: "numeric" }).format(new Date(seconds * 1000));
const KEY_DATE = dateText(NOW + 10 * DAY);

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= Erişim → Genel: warnings first with their fix, the summaries, the matrix
    let page = await newPage();
    await page.goto(url("#/erisim"));
    assert.equal(await page.locator("main h1").innerText(), "Erişim");
    const tabs = page.getByRole("tablist", { name: "Erişim bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Genel", "Adresler", "Tailscale", "WireGuard", "Güvenlik duvarı"]);
    await page.getByTestId("access-warnings").waitFor();
    const fixes = page.getByTestId("access-warnings").locator(".problem");
    assert.deepEqual(await fixes.locator("strong").allInnerTexts(), WARNINGS.map((w) => w.metin));
    assert.deepEqual(await fixes.getByRole("link", { name: "Düzelt" }).evaluateAll((as) => as.map((a) => a.getAttribute("href"))),
      ["#/erisim?sekme=adresler&yayinla=paylasim", "#/uygulamalar/medya", "#/erisim?sekme=adresler&yayinla=konteyner%3Anotlar"]);
    await page.getByTestId("page-desc").filter({ hasText: "6 hizmet Tailscale'de · 5 hizmet internette · 3 uyarı" }).waitFor();
    // Summaries.
    const ts = page.getByTestId("sum-tailscale");
    assert.equal(await ts.locator(".pill").innerText(), "Bağlı");
    assert.deepEqual(await ts.locator("dd").allInnerTexts(), ["sunucu.example-tailnet.ts.net", "100.64.0.2 · fd7a:115c:a1e0::2", `${KEY_DATE} tarihine kadar`]);
    assert.match(await ts.locator("dd").nth(2).getAttribute("class"), /warn-text/, "a key within 14 days is a warning");
    assert.deepEqual(await page.getByTestId("sum-internet").locator(".fact-list li").allInnerTexts(),
      ["SSH · 22/tcp", "WireGuard wg0 · 61001/udp · yalnız IPv4", "Oyun · 27015/udp · yalnız IPv4 · sizin kuralınız"]);
    assert.deepEqual(await page.getByTestId("sum-wireguard").locator(".fact-list li").allInnerTexts(), ["wg0 · Ana ağ · UDP 61001 · açık"]);
    assert.equal(await page.getByTestId("sum-certs").locator(".fact-list li").innerText(), `notlar.example.org · ${KEY_DATE} tarihine kadar`);
    // The matrix in plain words.
    const matrix = page.getByTestId("matrix");
    assert.deepEqual(await matrix.locator("thead th").allInnerTexts(), ["Hizmet", "Bu sunucu", "Tailscale", "WireGuard", "İnternet"]);
    assert.deepEqual(await matrix.locator("tbody tr[data-hizmet]").evaluateAll((trs) => trs.map((t) => t.dataset.hizmet)), ROWS.map((r) => r.id));
    const notlar = matrix.locator('tr[data-hizmet="konteyner:notlar"]');
    assert.deepEqual(await notlar.locator(".matrix-cell .pill").allInnerTexts(), ["Açık", "Açık", "Kapalı", "Açık"]);
    assert.equal(await notlar.locator('[data-hucre="wireguard"] .cell-note').count(), 0, "the VPN note is said once, under the table");
    assert.equal(await notlar.locator(".cell-addr").count(), 0, "addresses only with Teknik ayrıntı");
    const shares = matrix.locator('tr[data-hizmet="paylasim"] [data-hucre="internet"]');
    assert.match(await shares.locator(".pill").getAttribute("class"), /pill-warning/);
    assert.equal(await shares.locator(".warn-text").innerText(), "Şifresiz HTTP");
    await noStyles(page, "erisim genel");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-erisim-genel.png", true);
    // Teknik ayrıntı: addresses and the technical lines, kept in the address.
    await matrix.getByRole("switch", { name: "Teknik ayrıntı" }).click();
    await page.waitForURL((u) => u.hash === "#/erisim?teknik=1");
    assert.equal(await notlar.locator('[data-hucre="internet"] .cell-addr').innerText(), "notlar.example.org");
    assert.equal(await matrix.locator('tr[data-hizmet="paylasim"] [data-hucre="tailscale"] .cell-addr').innerText(), "paylas.ev · 100.64.0.2:61010");
    assert.deepEqual(await matrix.locator('[data-ayrinti="konteyner:notlar"] dd').allInnerTexts(),
      ["127.0.0.1:8090 → 80/tcp", "notlar.ev → 100.64.0.2", "notlar.example.org → 127.0.0.1:8090"]);
    await page.reload();
    await matrix.locator('[data-ayrinti="paylasim"]').waitFor();
    assert.equal(await matrix.getByRole("switch", { name: "Teknik ayrıntı" }).getAttribute("aria-checked"), "true", "from the address");
    await shot(page, "1440-light-erisim-teknik.png", true);
    assert.equal(await page.getByTestId("vpn-note").innerText(), "WireGuard: " + VPN_NOTE, "the VPN note once, not in every row");

    // Düzelt: a publication opens the Yayınla flow on Adresler, preset to the row (Kim).
    await page.getByTestId("access-warnings").getByRole("link", { name: "Düzelt" }).first().click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adresler&yayinla=paylasim");
    let flow = flowSheet(page);
    await flow.waitFor();
    assert.equal(await flow.locator("h2").innerText(), "WebDAV paylaşımları · Yayınla");
    const currentStep = (f) => f.locator('.stepper [aria-current="step"]').evaluate((e) => e.textContent.trim());
    assert.equal(await currentStep(flow), "2Kim");
    assert.equal(await flow.getByTestId("flow-guard").innerText(), "Klasör hesapları korur; her klasörün internet erişimi Paylaşımlar'dan açılır.");
    assert.equal(await page.evaluate(() => document.querySelector(".app").inert), true, "the page behind the flow is inert");
    await page.keyboard.press("Escape");
    await flow.waitFor({ state: "detached" });
    assert.equal(await hashOf(page), "#/erisim?sekme=adresler", "closing removes the flow from the address");
    await page.goto(url("#/erisim"));
    await page.getByTestId("access-warnings").getByRole("link", { name: "Düzelt" }).nth(1).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/medya");
    await page.locator("main h1").filter({ hasText: "medya" }).waitFor();
    await page.getByTestId("service").first().waitFor();
    await page.context().close();

    // ================= Tailscale: the device, its key, the exit node and the admin console
    page = await newPage();
    await page.goto(url("#/erisim?sekme=tailscale"));
    await page.getByTestId("ts-tab").waitFor();
    assert.equal(await page.getByTestId("ts-name").innerText(), "sunucu.example-tailnet.ts.net");
    assert.equal(await page.getByTestId("ts-addresses").innerText(), "100.64.0.2 · fd7a:115c:a1e0::2");
    assert.equal(await page.getByTestId("ts-version").innerText(), "1.88.3");
    assert.match(await page.getByTestId("ts-key").innerText(), /gün kaldı$/);
    await page.getByTestId("ts-key-warning").waitFor();
    assert.match(await page.getByTestId("ts-exit").innerText(), /^Sunuluyor/);
    const admin = page.getByTestId("ts-admin-link");
    assert.deepEqual([await admin.getAttribute("href"), await admin.getAttribute("target"), await admin.getAttribute("rel")],
      ["https://login.tailscale.com/admin/machines", "_blank", "noopener noreferrer"]);
    assert.equal(await page.locator('[data-testid="ts-tab"] button').count(), 0, "nothing changes Tailscale from Konsol");
    await shot(page, "1440-light-erisim-tailscale.png", true);
    await page.context().close();
    // Disconnected: a "bad" warning whose fix is the Tailscale tab.
    data.erisim = erisim({ uyarilar: [{ seviye: "bad", hizmet: "", metin: "Tailscale bağlı değil; Konsol'a ve tailnet adlarına öbür cihazlardan ulaşılamaz.",
      duzelt: { bolum: "tailscale", hedef: "" } }] });
    data.erisim.ozet.tailscale = { ...data.erisim.ozet.tailscale, durum: "bagli-degil", anahtar_bitis: null, cikis_dugumu: false };
    data.erisim.ozet.wireguard = { kurulu: false, durduruldu: true, not: "", aglar: [] };
    page = await newPage();
    await page.goto(url("#/genel"));
    const overviewFix = page.locator('.problem[data-kind="erisim"]').getByRole("link", { name: "Düzelt" });
    assert.equal(await overviewFix.getAttribute("href"), "#/erisim?sekme=tailscale", "Genel Bakış's Düzelt follows duzelt");
    await overviewFix.click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=tailscale");
    assert.equal(await page.getByTestId("ts-device").locator(".pill").innerText(), "Bağlı değil");
    assert.equal(await page.getByTestId("ts-key").innerText(), "Süresiz ya da bilinmiyor");
    assert.equal(await page.getByTestId("ts-exit").innerText(), "Sunulmuyor.");
    // A stopped WireGuard has no networks to list; the summary says so.
    await page.goto(url("#/erisim"));
    assert.equal(await page.getByTestId("sum-wireguard-none").innerText(), "WireGuard durduruldu; ağlar kapalı.");
    await page.context().close();
    data.erisim = erisim();
    // Erişim that cannot be read (any failure, a 404 too) says so and waits for the server.
    h.status["/api/konsol/erisim"] = 404;
    expectedFailures = ["/api/konsol/erisim"];
    page = await newPage();
    await page.goto(url("#/erisim"));
    const unread = page.locator('section[aria-label="Erişim"]');
    await unread.getByText("Erişim henüz okunamadı").waitFor();
    assert.match(await unread.innerText(), /Sunucu yanıt verince burada görünür\./);
    await page.context().close();
    delete h.status["/api/konsol/erisim"];
    expectedFailures = [];

    // ================= Adresler: publications, local names (draft → plan → apply), the local domain
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    const pubs = page.getByTestId("publications");
    await pubs.locator('tr[data-yayin="konteyner:notlar"]').waitFor();
    assert.deepEqual(await pubs.locator("tbody tr").evaluateAll((trs) => trs.map((t) => t.dataset.yayin)), candidates().map((c) => c.id));
    const notlarRow = pubs.locator('tr[data-yayin="konteyner:notlar"]');
    assert.equal(await notlarRow.locator('[data-hucre="tailscale"]').innerText(), "notlar.ev\naçık");
    assert.equal(await notlarRow.locator('[data-hucre="internet"]').innerText(), "notlar.example.org\n" + GUARD_APP);
    assert.match(await notlarRow.locator('[data-hucre="durum"]').innerText(), new RegExp(`Sertifika hazır[\\s\\S]*Sertifika: ${KEY_DATE}`));
    assert.equal(await pubs.locator('tr[data-yayin="konteyner:kutu_web"] [data-eylem="duzenle"]').innerText(), "Yayınla", "not published yet");
    assert(await pubs.locator('tr[data-yayin="konteyner:dis"] [data-eylem="duzenle"]').isDisabled(), "unavailable");
    assert(await pubs.locator('tr[data-yayin="konteyner:medya_web"] [data-eylem="duzenle"]').isDisabled(), "no loopback port: nothing to name");
    assert.match(await pubs.locator('tr[data-yayin="konteyner:dis"]').innerText(), /dinleyen bir portu yok/);
    assert.equal(await pubs.locator('[data-eylem="kaldir"]').count(), 2, "manual addresses (one joined to its container) can be removed");
    assert.equal(await page.getByTestId("dns-hint").locator(".mono").innerText(), "203.0.113.10");
    // Local names: one row per name, the locked one disabled, the operator's record, forwarding.
    const namesCard = page.getByTestId("names");
    assert.deepEqual(await namesCard.locator("tbody tr").evaluateAll((trs) => trs.map((t) => t.dataset.ad || "k:" + t.dataset.kayit)),
      ["panel.ev", "paylas.ev", "yedek.ev", "notlar.ev", "k:yazici.ev"]);
    assert.equal(await namesCard.locator('tr[data-ad="panel.ev"] td').first().innerText(), "Tailscale adresi · 100.64.0.2 · fd7a:115c:a1e0::2");
    assert(await namesCard.getByRole("switch", { name: "panel.ev açık" }).isDisabled(), "Konsol's own name is locked");
    assert.equal(await namesCard.getByRole("switch", { name: "yedek.ev açık" }).getAttribute("aria-checked"), "false");
    assert.equal(await namesCard.locator('tr[data-ad="paylas.ev"] td').nth(1).innerText(), "Temel");
    assert.equal(await namesCard.locator('tr[data-ad="yedek.ev"] td').nth(1).innerText(), "yedek", "any other source as it is");
    assert.equal(await namesCard.locator('tr[data-ad="notlar.ev"] td').nth(1).innerText(), "Elle adres");
    await noStyles(page, "erisim adresler");
    await shot(page, "1440-light-erisim-adresler.png", true);
    // The draft: a name off, a record added, forwarding to Quad9.
    assert.equal(await page.getByTestId("dns-draft").count(), 0);
    assert.equal(await guarded(page), false, "no draft, no question");
    await namesCard.getByRole("switch", { name: "paylas.ev açık" }).click();
    await page.getByTestId("dns-draft").filter({ hasText: "1 değişiklik taslakta" }).waitFor();
    assert.equal(await guarded(page), true, "a DNS draft asks before the tab closes");
    await page.getByTestId("add-record").click();
    let sheet = page.getByRole("dialog", { name: "Yerel ad ekle" });
    await sheet.waitFor();
    await sheet.getByRole("button", { name: "Taslağa ekle" }).click();
    await sheet.getByText("Adı yazın (ör. yazici).").waitFor();
    await sheet.getByLabel("Ad", { exact: true }).fill("yazici");
    await sheet.getByRole("button", { name: "Taslağa ekle" }).click();
    await sheet.getByText("Bu ad zaten kullanılıyor.").waitFor();
    await sheet.getByLabel("Ad", { exact: true }).fill("nas");
    await sheet.getByLabel("Sabit bir IP adresi").check();
    await sheet.getByRole("textbox", { name: "IP adresi" }).fill("192.0.2.50");
    await sheet.getByRole("button", { name: "Taslağa ekle" }).click();
    await sheet.waitFor({ state: "detached" });
    await namesCard.locator('tr[data-kayit="nas.ev"]').waitFor();
    await page.getByTestId("forward").getByText("Quad9").click();
    await page.getByTestId("dns-draft").filter({ hasText: "3 değişiklik taslakta" }).waitFor();
    assert(await page.getByTestId("review-domain").isDisabled(), "no domain change over a draft");
    await shot(page, "1440-light-erisim-dns-taslak.png", true);
    await page.getByTestId("review-dns").click();
    sheet = page.getByRole("dialog", { name: "Yerel ad değişiklikleri" });
    await sheet.getByTestId("plan").waitFor();
    const DNS_BODY = { revision: "rev-1", dns: { disabled: ["yedek.ev", "paylas.ev"], records: [{ name: "yazici.ev", target: "192.0.2.40", enabled: true },
      { name: "nas.ev", target: "192.0.2.50", enabled: true }], forward: true, servers: ["9.9.9.9", "149.112.112.112"] } };
    assert.deepEqual(lastPost("ayarlar/plan"), DNS_BODY, "the plan asks for exactly the draft");
    assert.equal(await sheet.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.");
    assert.deepEqual(await sheet.locator(".plan-item .pill").allInnerTexts(), ["Kapanır", "Eklenir", "Değişir"]);
    assert.deepEqual(await sheet.locator(".plan-group[data-alan] .plan-title").allInnerTexts(), ["Yerel adlar (DNS)"]);
    const off = sheet.locator('.plan-item[data-islem="kapat"]');
    assert.deepEqual([await off.locator(".plan-object").innerText(), await off.locator(".plan-before").innerText(), await off.locator(".plan-after").innerText()],
      ["paylas.ev", "açık", "kapalı"], "before → after");
    await shot(page, "1440-light-erisim-dns-plan.png");
    data.adlar = { ...names(), adlar: names().adlar.map((a) => (a.ad === "paylas.ev" ? { ...a, kapali: true } : a)), kayitlar: DNS_BODY.dns.records,
      sunucular: DNS_BODY.dns.servers };
    const namesReads = count("adlar");
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), DNS_BODY, "apply sends the planned body unchanged");
    await page.getByTestId("addresses-note").filter({ hasText: "Yerel adlar kaydedildi." }).waitFor();
    await waitFor(() => count("adlar") > namesReads, "names read again");
    await page.getByTestId("dns-draft").waitFor({ state: "detached" });
    assert.equal(await namesCard.getByRole("switch", { name: "paylas.ev açık" }).getAttribute("aria-checked"), "false");
    data.adlar = names();
    // A refused plan shows the backend's words and can be asked again.
    await namesCard.getByRole("switch", { name: "notlar.ev açık" }).click();
    expectedFailures = ["/api/konsol/ayarlar/plan"];
    planReplies.push({ status: 400, body: { error: "Ayarlar değişmiş. Yenileyip yeniden inceleyin." } });
    await page.getByTestId("review-dns").click();
    sheet = page.getByRole("dialog", { name: "Yerel ad değişiklikleri" });
    await sheet.getByTestId("plan-error").filter({ hasText: "Ayarlar değişmiş. Yenileyip yeniden inceleyin." }).waitFor();
    assert(await sheet.getByTestId("apply").isDisabled());
    await sheet.getByRole("button", { name: "Yeniden denetle" }).click();
    await sheet.getByTestId("plan").waitFor();
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    await page.getByTestId("dns-draft").getByRole("button", { name: "Vazgeç" }).click();
    await page.getByTestId("dns-draft").waitFor({ state: "detached" });
    assert.equal(await guarded(page), false, "the dropped draft no longer asks");
    expectedFailures = [];

    // The local domain: plan (300 s), apply, then confirmation only from the new address.
    await page.getByTestId("review-domain").click();
    await page.getByTestId("domain").getByText("Yeni alan adını yazın (ör. ev).").waitFor();
    await page.getByTestId("domain-input").fill("Ev");
    assert.equal(await guarded(page), true, "a typed domain asks before the tab closes");
    await page.getByTestId("review-domain").click();
    await page.getByTestId("domain").getByText("Alan adı zaten bu değerde.").waitFor();
    await page.getByTestId("domain-input").fill("ofis");
    await page.getByTestId("review-domain").click();
    sheet = page.getByRole("dialog", { name: "Yerel alan adı değişsin mi?" });
    await sheet.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("ayarlar/plan"), { revision: "rev-1", domain: "ofis" });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /5:00 içinde onaylamazsanız/);
    assert.match(await sheet.locator(".modal-list").innerText(), /Restrict to domain” ile ofis alanını ekleyin/);
    assert.equal(await sheet.locator(".plan-address").innerText(), "http://panel.ofis/");
    await shot(page, "1440-light-erisim-alan-plan.png");
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), { revision: "rev-1", domain: "ofis" });
    assert.equal(await guarded(page), false, "the applied domain is no draft");
    const banner = page.locator(".pending");
    await banner.waitFor();
    await page.getByTestId("countdown").filter({ hasText: /^(5:00|4:59)$/ }).waitFor();
    const domainNote = banner.getByTestId("pending-domain");
    assert.match(await domainNote.innerText(), /ev → ofis değişiyor; yeni adresten onaylayın/);
    assert.equal(await domainNote.getByRole("link", { name: "panel.ofis" }).getAttribute("href"), "http://panel.ofis/#/erisim?sekme=adresler");
    assert.equal(await domainNote.getByRole("link", { name: "panel.ev" }).getAttribute("href"), "http://panel.ev/#/erisim?sekme=adresler");
    assert(await banner.getByTestId("pending-confirm").isDisabled(), "a domain change is confirmed only from the new address");
    assert.equal(await page.getByTestId("domain-pending").getByRole("link").getAttribute("href"), "http://panel.ofis/#/erisim?sekme=adresler");
    assert(await page.getByTestId("review-domain").isDisabled(), "no new change while one is pending");
    await shot(page, "1440-light-erisim-alan-bekliyor.png");
    await banner.getByTestId("pending-rollback").click();
    await banner.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/geri-al"), { id: "p-alan" });
    await page.getByTestId("pending-result").filter({ hasText: "Önceki ayarlar geri yüklendi." }).waitFor();
    await page.getByTestId("domain-pending").waitFor({ state: "detached" });

    // Removing a manual address: plan → apply with {web: {service, sil: true}}.
    await pubs.locator('tr[data-yayin="elle:yazici"] [data-eylem="kaldir"]').click();
    sheet = page.getByRole("dialog", { name: "Yazıcı kaldırılsın mı?" });
    await sheet.getByTestId("plan").waitFor();
    assert.equal(await sheet.locator(".modal-desc").innerText(), "yazici.ev kapanır. 127.0.0.1:631 üzerindeki uygulama çalışmaya devam eder.");
    assert.deepEqual(lastPost("ayarlar/plan"), { revision: "rev-1", web: { service: "elle-yazici", sil: true } });
    assert.deepEqual(await sheet.locator(".plan-item .pill").allInnerTexts(), ["Kaldırılır"]);
    await sheet.getByRole("button", { name: "Kaldır" }).click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), { revision: "rev-1", web: { service: "elle-yazici", sil: true } });
    await page.getByTestId("addresses-note").filter({ hasText: "Adres kaldırıldı." }).waitFor();
    await page.context().close();

    // ================= Yayınla: a published container's internet name (Kim → Ad with the DNS record → Plan → Uygula)
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    await page.getByTestId("publications").locator('tr[data-yayin="konteyner:notlar"] [data-eylem="duzenle"]').click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("yayinla") === "konteyner:notlar");
    flow = flowSheet(page);
    await flow.getByRole("switch", { name: "Tailscale adı" }).waitFor();
    assert.equal(await currentStep(flow), "2Kim");
    assert.equal(await flow.getByRole("switch", { name: "Tailscale adı" }).getAttribute("aria-checked"), "true");
    assert.equal(await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).getAttribute("aria-checked"), "true");
    assert.equal(await flow.getByTestId("flow-guard").innerText(), GUARD_APP);
    const go = flow.getByTestId("flow-go");
    await go.click();
    assert.equal(await currentStep(flow), "3Ad");
    assert.equal(await flow.getByTestId("flow-domain").inputValue(), "notlar.example.org");
    assert.equal(await flow.getByTestId("flow-local").count(), 0, "a published container keeps its tailnet name");
    await flow.getByTestId("flow-domain").fill("indir.example.org/");
    await go.click();
    await flow.getByText("Tam alan adını girin; URL, IP, port veya yol eklemeyin.").waitFor();
    assert.equal(await currentStep(flow), "3Ad", "an invalid name keeps the step");
    await flow.getByTestId("flow-domain").fill("Indir.Example.org.");
    assert.equal((await flow.getByTestId("flow-dns").locator("dd").allInnerTexts()).join(" | "), "indir.example.org | A | 203.0.113.10");
    await go.click();
    assert.equal(await currentStep(flow), "4Plan");
    await flow.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("yayinlar/plan"), { hedef: "konteyner:notlar", revizyon: "rev-1", tailscale: true, internet: true, alan_adi: "indir.example.org" });
    assert.deepEqual(await flow.getByTestId("flow-steps").locator(".flow-run strong").allInnerTexts(), ["1. Ad ve erişim"]);
    assert.equal(await flow.getByTestId("plan-dns").locator(".mono").innerText(), "indir.example.org · A · 203.0.113.10");
    assert.deepEqual(await flow.locator(".plan-item .plan-object").allInnerTexts(), ["notlar · internet adı"]);
    await shot(page, "1440-light-yayinla-plan.png");
    // Applying waits for the certificate (held back here) and says so.
    let release;
    const held = new Promise((resolve) => (release = resolve));
    await page.route("**/api/konsol/ayarlar/uygula", async (route) => {
      await held;
      return h.answer(route);
    });
    await go.click();
    await flow.getByTestId("run-state").filter({ hasText: "Sürüyor…" }).waitFor();
    assert.match(await flow.locator(".flow-run .cell-note").innerText(), /sertifika bekleniyor \(en çok 1 dakika\)/);
    assert(await go.isDisabled(), "no second apply while it runs");
    assert(await flow.getByTestId("flow-back").isDisabled());
    release();
    await flow.getByTestId("flow-done").waitFor();
    await page.unroute("**/api/konsol/ayarlar/uygula");
    assert.deepEqual(lastPost("ayarlar/uygula"), { revision: "rev-1", web: { service: "elle-notlar", tail: true, enabled: true, domain: "indir.example.org" } },
      "the plan's settings step, unchanged");
    assert.equal(await flow.getByTestId("run-state").innerText(), "Tamam");
    assert.deepEqual(await flow.getByTestId("flow-done").getByRole("link").evaluateAll((as) => as.map((a) => a.getAttribute("href"))),
      ["http://notlar.ev/", "https://indir.example.org/"]);
    assert.equal(await go.innerText(), "Kapat");
    await shot(page, "1440-light-yayinla-tamam.png");
    await go.click();
    await flow.waitFor({ state: "detached" });
    assert.equal(await hashOf(page), "#/erisim?sekme=adresler");
    await page.context().close();

    // ================= the Konsol row: its internet name needs the typed word, sent as `onay`
    page = await newPage();
    await page.goto(url("#/erisim"));
    await page.getByTestId("publish").click();
    await page.waitForURL((u) => u.hash === "#/erisim?yayinla=sec");
    flow = flowSheet(page);
    await flow.waitFor();
    assert.equal(await currentStep(flow), "1Ne");
    const options = flow.locator(".choice-item");
    await options.first().waitFor();
    assert.deepEqual(await options.evaluateAll((ls) => ls.map((l) => l.dataset.aday)), [...candidates().map((c) => c.id), "yeni"]);
    assert(await flow.locator('[data-aday="konteyner:dis"] input').isDisabled(), "an unavailable candidate cannot be chosen");
    assert.match(await flow.locator('[data-aday="konteyner:dis"]').innerText(), /dinleyen bir portu yok/);
    await flow.getByTestId("flow-go").click();
    await flow.getByText("Yayımlanacak olanı seçin.").waitFor();
    await flow.locator('[data-aday="panel"]').click();
    await flow.getByTestId("flow-go").click();
    assert(await flow.getByRole("switch", { name: "Tailscale adı" }).isDisabled(), "Konsol's tailnet name stays on");
    await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).click();
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-domain").fill("konsol.example.org");
    const plansBefore = posts("yayinlar/plan").length;
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("konsol-word").waitFor();
    assert.match(await flow.getByTestId("konsol-word").innerText(), /https:\/\/konsol\.example\.org adresinde Konsol'un giriş sayfası internete açılır/);
    await page.waitForTimeout(150);
    assert.equal(posts("yayinlar/plan").length, plansBefore, "no plan before the typed word");
    assert(await flow.getByTestId("flow-go").isDisabled());
    await shot(page, "1440-light-yayinla-konsol.png");
    await flow.getByLabel("Onaylamak için onayla yazın").fill("onay");
    await page.waitForTimeout(100);
    assert.equal(posts("yayinlar/plan").length, plansBefore);
    await flow.getByLabel("Onaylamak için onayla yazın").fill("ONAYLA");
    await flow.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("yayinlar/plan"), { hedef: "panel", revizyon: "rev-1", tailscale: true, internet: true, alan_adi: "konsol.example.org", onay: "onayla" });
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-done").waitFor();
    assert.deepEqual(lastPost("ayarlar/uygula"), { revision: "rev-1", web: { service: "panel", tail: true, enabled: true, domain: "konsol.example.org", confirm: "onayla" } });
    await flow.getByTestId("flow-go").click();
    await flow.waitFor({ state: "detached" });
    await page.context().close();

    // ================= an application's address port (127.0.0.1, DD-271 phase 3): its names, then the settings step
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler&yayinla=konteyner:kutu_web"));
    flow = flowSheet(page);
    await flow.waitFor();
    await flow.getByRole("switch", { name: "Tailscale adı" }).waitFor();
    assert.equal(await currentStep(flow), "2Kim");
    assert.equal(await flow.getByRole("switch", { name: "Tailscale adı" }).getAttribute("aria-checked"), "true", "a new publication starts on the tailnet");
    assert.equal(await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).getAttribute("aria-checked"), "false");
    await flow.getByTestId("flow-go").click();
    assert.equal(await flow.getByTestId("flow-name").inputValue(), "kutu_web");
    assert.equal(await flow.getByTestId("flow-local").inputValue(), "kutu-web", "the server's own choice of name");
    await flow.getByTestId("flow-local").fill("film_1");
    await flow.getByTestId("flow-go").click();
    await flow.getByText("Küçük harfle başlamalı; yalnız küçük harf, rakam ve tire (en çok 31).").waitFor();
    await flow.getByTestId("flow-local").fill("notlar");
    await flow.getByText("notlar.ev adı zaten kullanılıyor.").waitFor();
    await flow.getByTestId("flow-local").fill("kutu");
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("yayinlar/plan"), { hedef: "konteyner:kutu_web", revizyon: "rev-1", tailscale: true, internet: false, alan_adi: "", yerel: "kutu" });
    assert.deepEqual(await flow.getByTestId("flow-steps").locator(".flow-run").evaluateAll((ls) => ls.map((l) => l.dataset.tur)), ["ayar"]);
    const kutuPlan = publicationPlan(lastPost("yayinlar/plan"));
    assert.equal(kutuPlan.adimlar[0].istek.web.elle.upstream, "127.0.0.1:62001", "the application's own pool port");
    await shot(page, "1440-light-yayinla-konteyner.png");
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-done").waitFor();
    assert.deepEqual(lastPost("ayarlar/uygula"), kutuPlan.adimlar[0].istek, "the settings request, unchanged");
    assert.deepEqual(await flow.getByTestId("run-state").allInnerTexts(), ["Tamam"]);
    assert.equal(posts("konteynerler/islem").length, 0, "no container job");
    await flow.getByTestId("flow-go").click();
    await flow.waitFor({ state: "detached" });

    // The settings step fails: the name did not open, and the plan can be checked again.
    await page.goto(url("#/erisim?yayinla=konteyner:kutu_web"));
    flow = flowSheet(page);
    await flow.getByRole("switch", { name: "Tailscale adı" }).waitFor();
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("yayinlar/plan"), { hedef: "konteyner:kutu_web", revizyon: "rev-1", tailscale: true, internet: false, alan_adi: "" });
    expectedFailures = ["/api/konsol/ayarlar/uygula"];
    applyReplies.push({ status: 400, body: { error: "Caddy yapılandırması doğrulanamadı." } });
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-error").waitFor();
    assert.equal(await flow.getByTestId("flow-error").innerText(), "Caddy yapılandırması doğrulanamadı.");
    assert.deepEqual(await flow.getByTestId("run-state").allInnerTexts(), ["Başarısız"]);
    assert.equal(await flow.getByTestId("flow-go").innerText(), "Yeniden denetle");
    await shot(page, "1440-light-yayinla-hata.png");
    expectedFailures = [];
    await flow.getByTestId("flow-back").click();
    await flow.getByTestId("flow-back").click();
    await flow.getByTestId("flow-back").click();
    assert.equal(await currentStep(flow), "1Ne");
    await flow.getByTestId("flow-back").click();
    await flow.waitFor({ state: "detached" });
    await page.context().close();

    // ================= another port on this server: a new manual address, planned through ayarlar/plan
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    await page.getByTestId("add-manual").click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adresler&yayinla=yeni");
    flow = flowSheet(page);
    await flow.getByTestId("manual-port").waitFor();
    await flow.getByTestId("flow-go").click();
    await flow.getByText("Bu sunucuda dinleyen portu yazın (1–65535).").waitFor();
    await flow.getByTestId("manual-port").fill("8123");
    await flow.getByTestId("flow-go").click();
    await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).click();
    assert.equal(await flow.getByTestId("flow-guard").innerText(), GUARD_APP);
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-name").fill("Yazdırma");
    await flow.getByTestId("flow-local").fill("baski");
    await flow.getByTestId("flow-domain").fill("baski.example.org");
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("plan").waitFor();
    const MANUAL = { revision: "rev-1", web: { service: "elle-baski", tail: true, enabled: true, domain: "baski.example.org",
      elle: { name: "Yazdırma", local: "baski", upstream: "127.0.0.1:8123" } } };
    assert.deepEqual(lastPost("ayarlar/plan"), MANUAL);
    assert.equal(await flow.getByTestId("plan-dns").locator(".mono").innerText(), "baski.example.org · A · 203.0.113.10");
    assert.equal(await flow.locator('.plan-warning[data-seviye="warn"]').innerText(), GUARD_APP);
    assert.match(await flow.getByTestId("flow-steps").innerText(), /baski\.ev → 127\.0\.0\.1:8123/);
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-done").waitFor();
    assert.deepEqual(lastPost("ayarlar/uygula"), MANUAL);
    await flow.getByTestId("flow-go").click();
    await flow.waitFor({ state: "detached" });

    // What blocks a plan ("engel") is shown, and "Yeniden denetle" asks again.
    yayinReplies.push((body) => ({ body: { ...publicationPlan(body), engel: "indir.example.org adı 203.0.113.10 adresine çözülmüyor; DNS kaydını denetleyin." } }));
    await page.goto(url("#/erisim?sekme=adresler&yayinla=konteyner:notlar"));
    flow = flowSheet(page);
    await flow.getByRole("switch", { name: "Tailscale adı" }).waitFor();
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-domain").fill("indir.example.org");
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-engel").filter({ hasText: "çözülmüyor" }).waitFor();
    assert(await flow.getByTestId("flow-go").isDisabled(), "a blocked plan cannot be applied");
    await shot(page, "1440-light-yayinla-engel.png");
    const asked = posts("yayinlar/plan").length;
    await flow.getByTestId("recheck").click();
    await flow.getByTestId("flow-engel").waitFor({ state: "detached" });
    await page.waitForFunction(() => !document.querySelector('[data-testid="flow-go"]').disabled);
    assert.equal(posts("yayinlar/plan").length, asked + 1);
    // Both names off unpublishes.
    await flow.getByTestId("flow-back").click();
    await flow.getByTestId("flow-back").click();
    await flow.getByRole("switch", { name: "Tailscale adı" }).click();
    await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).click();
    await flow.getByTestId("unpublish").waitFor();
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("yayinlar/plan"), { hedef: "konteyner:notlar", revizyon: "rev-1", tailscale: false, internet: false, alan_adi: "notlar.example.org" },
      "the remembered internet name is kept while off");
    await flow.getByTestId("flow-go").click();
    await flow.getByTestId("flow-done").filter({ hasText: "Yayın kaldırıldı." }).waitFor();
    await page.context().close();

    // Konsol without an account cannot open its internet name; the reason is shown.
    const NO_ACCOUNT = "Önce Konsol hesabı oluşturun (Tailscale adresinden, Sistem → Hesap).";
    data.yayinlar = { ...data.yayinlar, adaylar: candidates().map((c) => (c.id === "panel" ? { ...c, internet_engel: NO_ACCOUNT } : c)) };
    page = await newPage();
    await page.goto(url("#/erisim?yayinla=panel"));
    flow = flowSheet(page);
    await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).waitFor();
    assert(await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).isDisabled());
    assert.equal(await flow.getByTestId("internet-block").innerText(), NO_ACCOUNT);
    assert.equal(await flow.getByRole("switch", { name: "İnternet adı (HTTPS)" }).getAttribute("aria-describedby"), "yayin-engel");
    data.yayinlar = { ...data.yayinlar, adaylar: candidates() };
    // An unknown target falls back to the choice.
    await page.goto(url("#/erisim?yayinla=konteyner:yok"));
    await flowSheet(page).getByTestId("flow-notice").filter({ hasText: "yayımlanabilecekler arasında yok" }).waitFor();
    assert.equal(await currentStep(flowSheet(page)), "1Ne");
    await page.context().close();

    // ================= Güvenlik duvarı: the base's ports with the rules, a draft → plan → apply → 60 s → Onayla
    page = await newPage();
    await page.goto(url("#/erisim?sekme=guvenlik-duvari"));
    const fwView = page.getByTestId("firewall");
    await fwView.getByTestId("fw-check").filter({ hasText: "Güvenlik duvarı kuralları beklendiği gibi." }).waitFor();
    const nets = fwView.getByRole("tablist", { name: "Gelen ağlar" }).getByRole("tab");
    assert.deepEqual(await nets.allInnerTexts(), ["İnternet", "Tailscale", "WireGuard", "Sunucu içi"]);
    const fwRows = () => fwView.locator(".fw-table tbody tr");
    assert.deepEqual(await fwRows().evaluateAll((trs) => trs.map((t) => t.dataset.port)), ["tcp/22", "udp/61001", "tcp/8096"], "İnternet · IPv4");
    const ssh = fwView.locator('tr[data-port="tcp/22"]');
    assert.equal(await ssh.locator('td[data-label="Dinleme"]').innerText(), "Bu ağda dinliyor\n0.0.0.0");
    assert.equal(await ssh.getByTestId("rule-state").innerText(), "Temel");
    assert.equal(await ssh.getByRole("switch").getAttribute("aria-checked"), "true");
    const fixed = fwView.locator('tr[data-port="tcp/8096"]');
    assert(await fixed.getByRole("switch").isDisabled(), "a container publication is locked");
    assert.match(await fixed.innerText(), /Konteyner yayını · uygulamayla açılır, kapanır/);
    assert.equal(await fwView.locator('tr[data-port="udp/61001"] td[data-label="Dinleme"]').innerText(), "Dinleyici yok");
    await noStyles(page, "erisim guvenlik-duvari");
    await shot(page, "1440-light-erisim-guvenlik.png", true);
    // A baseline port turned off: the switch writes the operator's rule for it.
    await ssh.getByRole("switch").click();
    assert.equal(await ssh.getByRole("switch").getAttribute("aria-checked"), "false");
    assert.equal(await ssh.getByTestId("rule-state").innerText(), "Taslak · Yeni kural");
    await page.getByTestId("fw-draft").filter({ hasText: "1 değişiklik taslakta" }).waitFor();
    assert.equal(await guarded(page), true, "a firewall draft asks before the tab closes");
    // "+ Port kuralı": checked before it joins the draft.
    await fwView.getByTestId("add-rule").click();
    sheet = page.getByRole("dialog", { name: "Port kuralı ekle" });
    await sheet.waitFor();
    assert.equal(await sheet.getByLabel("Ağ", { exact: true }).inputValue(), "wan", "the open tab's network");
    await sheet.getByTestId("save-rule").click();
    await sheet.getByText("1–64 karakterlik bir ad yazın.").waitFor();
    await sheet.getByText("1 ile 65535 arasında bir port yazın.").waitFor();
    await sheet.getByLabel("Ad", { exact: true }).fill("Oyun");
    await sheet.getByLabel("Protokol").selectOption("udp");
    await sheet.getByLabel("Port", { exact: true }).fill("27015");
    await sheet.getByRole("textbox", { name: /^Kaynak IP/ }).fill("2001:db8::/32");
    await sheet.getByTestId("save-rule").click();
    await sheet.getByText("Kaynak adresinin IP ailesi seçilen aileyle uyuşmuyor.").waitFor();
    await sheet.getByRole("textbox", { name: /^Kaynak IP/ }).fill("");
    await sheet.getByTestId("save-rule").click();
    await sheet.waitFor({ state: "detached" });
    const game = fwView.locator('tr[data-port="udp/27015"]');
    await game.waitFor();
    assert.equal(await game.getByTestId("rule-state").innerText(), "Taslak · Yeni kural");
    assert.equal(await game.getByRole("button", { name: "Oyun kuralını düzenle" }).count(), 1);
    await page.getByTestId("fw-draft").filter({ hasText: "2 değişiklik taslakta" }).waitFor();
    // The same port and source twice is refused.
    await fwView.getByTestId("add-rule").click();
    sheet = page.getByRole("dialog", { name: "Port kuralı ekle" });
    await sheet.getByLabel("Ad", { exact: true }).fill("Oyun 2");
    await sheet.getByLabel("Protokol").selectOption("udp");
    await sheet.getByLabel("Port", { exact: true }).fill("27015");
    await sheet.getByTestId("save-rule").click();
    await sheet.getByText("Bu port ve kaynak için zaten bir kural var; o satırı düzenleyin.").waitFor();
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    // Other networks and the address family are in the address.
    await fwView.locator('[data-aile="6"]').click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("aile") === "6");
    assert.deepEqual(await fwRows().evaluateAll((trs) => trs.map((t) => t.dataset.port)), ["tcp/22"]);
    await fwView.locator('[data-aile="4"]').click();
    await nets.filter({ hasText: "Tailscale" }).click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("kapsam") === "tailscale");
    assert.deepEqual(await fwRows().evaluateAll((trs) => trs.map((t) => t.dataset.port)), ["tcp/80", "udp/53", "tcp/8096"]);
    assert.equal(await fwView.locator('tr[data-kural="u_medya"]').getByTestId("rule-state").innerText(), "Kural");
    await nets.filter({ hasText: "WireGuard" }).click();
    const wgPanel = fwView.locator('.fw-panel[data-kapsam="wireguard"]');
    assert.equal(await wgPanel.locator(".card-text").innerText(), "WireGuard cihazları yalnız internete çıkar. Sunucu servisleri, özel ağlar ve diğer " +
      "cihazlar engellenir; bu politika değiştirilemez. WireGuard'ın UDP bağlantı portu İnternet sekmesindedir; yönlendirme ve NAT kuralları Teknik kurallar'dadır.");
    assert.deepEqual(await wgPanel.getByRole("list", { name: "WireGuard ağları" }).locator("li").allInnerTexts(), ["wg0 · Ana ağ · açık"]);
    await nets.filter({ hasText: "Sunucu içi" }).click();
    const lo = fwView.locator('tr[data-port="tcp/62001"]');
    assert(await lo.getByRole("switch").isDisabled());
    assert.match(await lo.innerText(), /Sunucu içi · korunur/);
    // Teknik kurallar: the live rows with counters and owners, and the listeners (open state in the address).
    await fwView.getByTestId("fw-technical").locator("summary").click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("kurallar") === "1");
    const tech = fwView.locator(".tech-table tbody tr");
    assert.equal(await tech.count(), 2, "IPv4 rows only");
    assert.equal(await tech.first().locator('td[data-label="Sayaç"]').innerText(), "12.345 paket · 6.789.012 bayt");
    assert.deepEqual(await tech.locator('td[data-label="Sahibi"]').allInnerTexts(), ["Konsol", "Tailscale"]);
    assert.equal(await fwView.locator(".listen-table tbody tr").count(), 4);
    await shot(page, "1440-light-erisim-teknik-kurallar.png", true);
    // İncele → the plan → Uygula → the pending change counts down; Onayla confirms it.
    await page.getByTestId("review-fw").click();
    sheet = page.getByRole("dialog", { name: "Güvenlik duvarı değişiklikleri" });
    await sheet.getByTestId("plan").waitFor();
    const fwBody = lastPost("ayarlar/plan");
    const added = fwBody.firewall.at(-1);
    assert.match(added.id, /^u_[a-z0-9]+$/);
    assert.deepEqual(fwBody, { revision: "rev-1", firewall: [RULES[0],
      { id: "p_4_wan_tcp_22", name: "SSH", family: 4, scope: "wan", proto: "tcp", port: 22, source: "", allow: false },
      { id: added.id, name: "Oyun", family: 4, scope: "wan", proto: "udp", port: 27015, source: "", allow: true }] });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /Süreli onay: uygulandıktan sonra 1:00 içinde onaylamazsanız/);
    assert.deepEqual(await sheet.locator(".plan-item .plan-object").allInnerTexts(), ["SSH", "Oyun"]);
    assert.equal(await sheet.locator(".plan-effects").innerText(), "Güvenlik duvarı kuralları yeniden kurulur.");
    await shot(page, "1440-light-erisim-guvenlik-plan.png");
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), fwBody, "apply sends the planned body unchanged");
    const pending = page.locator(".pending");
    await pending.waitFor();
    await page.getByTestId("countdown").filter({ hasText: /^(1:00|0:59)$/ }).waitFor();
    await fwView.getByTestId("fw-locked").waitFor();
    assert(await fwView.locator('tr[data-port="tcp/62001"]').count() >= 0);
    assert.equal(await page.getByTestId("fw-draft").count(), 0, "the draft went to the server");
    assert.equal(await guarded(page), false, "nothing left to lose");
    assert(await pending.getByTestId("pending-confirm").isEnabled());
    await shot(page, "1440-light-erisim-bekliyor.png");
    data["guvenlik-duvari"] = firewall({ kurallar: fwBody.firewall });
    await pending.getByTestId("pending-confirm").click();
    await pending.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/onayla"), { id: "p-fw" });
    await page.getByTestId("pending-result").filter({ hasText: "Ayarlar kalıcı olarak kaydedildi." }).waitFor();
    await waitFor(() => h.requests.some((r) => r.path === "/api/konsol/guvenlik-duvari" && r.query === "?yenile=1"), "the rules read again, uncached");
    await fwView.getByTestId("fw-locked").waitFor({ state: "detached" });
    // Another change, rolled back from the banner.
    await nets.filter({ hasText: "İnternet" }).click();
    await fwView.locator('tr[data-port="udp/61001"]').getByRole("switch").click();
    await page.getByTestId("review-fw").click();
    sheet = page.getByRole("dialog", { name: "Güvenlik duvarı değişiklikleri" });
    await sheet.getByTestId("plan").waitFor();
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    await pending.waitFor();
    await pending.getByTestId("pending-rollback").click();
    await pending.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/geri-al"), { id: "p-fw" });
    // Rules that the plan says cannot be confirmed from here: "Uygula" stays off, with the reason.
    await fwView.locator('tr[data-port="udp/61001"]').getByRole("switch").click();
    planReplies.push({ body: plan({ onay_sn: 60, uygulanabilir: false, degisiklikler: [item("guvenlik-duvari", "ekle", "WireGuard wg0", null, "UDP 61001 · İnternet · IPv4 · engel")],
      uyarilar: [{ seviye: "bad", metin: "Bu kurallar şu anki Konsol bağlantınızı keser; onay verilemez ve değişiklik geri alınır." }] }) });
    await page.getByTestId("review-fw").click();
    sheet = page.getByRole("dialog", { name: "Güvenlik duvarı değişiklikleri" });
    await sheet.getByTestId("plan-blocked").waitFor();
    assert(await sheet.getByTestId("apply").isDisabled(), "not applicable");
    assert.match(await sheet.locator('.plan-warning[data-seviye="bad"]').innerText(), /şu anki Konsol bağlantınızı keser/);
    await shot(page, "1440-light-erisim-uygulanamaz.png");
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    await page.context().close();
    // Without a WireGuard network the tab stays and says where networks are set up.
    data["guvenlik-duvari"] = firewall({ aglar: [] });
    page = await newPage();
    await page.goto(url("#/erisim?sekme=guvenlik-duvari&kapsam=wireguard"));
    const noNets = page.getByTestId("firewall").locator('.fw-panel[data-kapsam="wireguard"]');
    await noNets.waitFor();
    assert.deepEqual(await page.getByTestId("firewall").getByRole("tablist", { name: "Gelen ağlar" }).getByRole("tab").allInnerTexts(),
      ["İnternet", "Tailscale", "WireGuard", "Sunucu içi"]);
    assert.equal(await noNets.locator(".meter-note").innerText(), "Henüz WireGuard ağı yok; ağlar Erişim → WireGuard'da kurulur.");
    await shot(page, "1440-light-erisim-guvenlik-wg-yok.png");
    await page.context().close();
    data["guvenlik-duvari"] = firewall();

    // ================= a rollback that failed five times: retry, or discard with the typed word
    page = await newPage();
    await page.goto(url("#/erisim"));
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("bekleyen", { bekleyen: { id: "p-takili", phase: "stuck", seconds: 0, attempts: 5, error: "dnsmasq başlamadı" } });
    const stuck = page.locator('.pending[data-phase="stuck"]');
    await stuck.waitFor();
    assert.match(await stuck.locator(".pending-detail").innerText(), /Geri alma tamamlanamadı \(5 deneme\)\. Son hata: dnsmasq başlamadı/);
    await stuck.getByTestId("pending-retry").click();
    await waitFor(() => posts("ayarlar/geri-al").length && lastPost("ayarlar/geri-al").id === "p-takili", "retry");
    await page.getByTestId("pending-result").filter({ hasText: "Önceki ayarlar geri yüklendi." }).waitFor();
    push("bekleyen", { bekleyen: { id: "p-takili", phase: "stuck", seconds: 0, attempts: 5, error: "dnsmasq başlamadı" } });
    await stuck.getByTestId("pending-discard").click();
    sheet = page.getByRole("dialog", { name: "Takılan geri alma bırakılsın mı?" });
    await sheet.waitFor();
    assert(await sheet.getByTestId("discard-go").isDisabled());
    await sheet.getByLabel("Onaylamak için onayla yazın").fill("onayla");
    await sheet.getByTestId("discard-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/birak"), { id: "p-takili", confirm: "onayla" });
    await page.getByTestId("pending-result").filter({ hasText: "Takılan işlem bırakıldı" }).waitFor();
    // A refused confirmation keeps the banner with the backend's words.
    push("bekleyen", { bekleyen: { id: "p-fw2", phase: "awaiting", seconds: 40 } });
    expectedFailures = ["/api/konsol/ayarlar/onayla"];
    h.handlers["/api/konsol/ayarlar/onayla"] = ({ method }) => (method === "POST" ? { status: 400, body: { error: "Onay süresi dolmuş veya işlem artık geçerli değil." } } : undefined);
    await page.locator(".pending").getByTestId("pending-confirm").click();
    await page.getByTestId("pending-error").filter({ hasText: "Onay süresi dolmuş veya işlem artık geçerli değil." }).waitFor();
    h.handlers["/api/konsol/ayarlar/onayla"] = ({ method }) => (method === "POST" ? { body: { ok: true } } : undefined);
    expectedFailures = [];
    push("bekleyen", { bekleyen: null });
    await page.locator(".pending").waitFor({ state: "detached" });
    await page.context().close();

    // ================= the internet channel: confirmation needs a Tailscale device
    expectedFailures = ["/api/konsol/olaylar"];
    data.bekleyen = { bekleyen: { id: "p-fw", phase: "awaiting", seconds: 50 } };
    page = await h.newHttpsPage("konsol.example.org");
    await page.goto("https://konsol.example.org/#/erisim?sekme=guvenlik-duvari");
    const remote = page.locator(".pending");
    await remote.getByTestId("pending-internet").waitFor();
    assert.match(await remote.getByTestId("pending-internet").innerText(), /^Onay yalnız Tailscale'e bağlı bir cihazdan verilir/);
    assert.equal(await remote.getByTestId("pending-internet").getByRole("link").getAttribute("href"), "http://panel.ev/");
    assert(await remote.getByTestId("pending-confirm").isDisabled(), "not from the internet name");
    assert(await remote.getByTestId("pending-rollback").isEnabled(), "rolling back stays possible");
    await shot(page, "1440-light-internet-bekleyen.png");
    await page.context().close();
    data.bekleyen = { bekleyen: null };
    expectedFailures = [];

    // ================= the palette: Erişim's tabs and the Yayınla action
    page = await newPage();
    await page.goto(url("#/erisim"));
    await page.getByTestId("matrix").waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    const input = palette.getByRole("combobox");
    await input.fill("yayınla");
    assert.equal(await palette.locator('[data-key="yayinla"] .palette-hint').innerText(), "Erişim", "an action of Erişim");
    await palette.locator('[data-key="yayinla"]').click();
    await page.waitForURL((u) => u.hash === "#/erisim?yayinla=sec");
    await flowSheet(page).locator(".choice-item").first().waitFor();
    await page.keyboard.press("Escape");
    await page.keyboard.press("Control+K");
    await input.fill("dnsmasq");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Erişim → Adresler", "Gelişmiş → DNS"], "names are changed in Erişim, read in Gelişmiş");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adresler");
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes: no style attribute, no horizontal scroll
    const VIEWS = [["genel", "#/erisim", "[data-testid=matrix]"], ["adresler", "#/erisim?sekme=adresler", "[data-testid=names] tbody tr"],
      ["tailscale", "#/erisim?sekme=tailscale", "[data-testid=ts-device]"], ["guvenlik", "#/erisim?sekme=guvenlik-duvari&kurallar=1", ".fw-table"]];
    for (const colorScheme of ["light", "dark"]) {
      page = await newPage({ colorScheme });
      for (const [name, hash, ready] of VIEWS) {
        await page.goto(url(hash));
        await page.locator(ready).first().waitFor();
        await noStyles(page, `1440 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `1440 ${colorScheme} ${name}`);
        await shot(page, `1440-${colorScheme}-${name}.png`, true);
      }
      await page.goto(url("#/erisim?sekme=adresler&yayinla=konteyner:kutu_web"));
      await flowSheet(page).getByRole("switch", { name: "Tailscale adı" }).waitFor();
      await shot(page, `1440-${colorScheme}-yayinla.png`);
      await page.context().close();

      page = await newPage({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
      for (const [name, hash, ready] of VIEWS) {
        await page.goto(url(hash));
        await page.locator(ready).first().waitFor();
        await noStyles(page, `390 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `390 ${colorScheme} ${name}`);
        await shot(page, `390-${colorScheme}-${name}.png`, true);
      }
      assert.equal(await page.locator(".fw-table tbody tr").first().evaluate((el) => getComputedStyle(el).display), "grid", "cards on a phone");
      await page.goto(url("#/erisim?sekme=adresler&yayinla=konteyner:notlar"));
      flow = flowSheet(page);
      await flow.getByRole("switch", { name: "Tailscale adı" }).waitFor();
      const sheetBox = await flow.boundingBox();
      assert(Math.abs(sheetBox.y + sheetBox.height - 844) <= 1 && sheetBox.width === 390, "a bottom sheet on a phone");
      await flow.getByTestId("flow-go").tap();
      await flow.getByTestId("flow-go").tap();
      await flow.getByTestId("plan").waitFor();
      await noStyles(page, `390 ${colorScheme} yayinla`);
      await shot(page, `390-${colorScheme}-yayinla-plan.png`);
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      await shot(page, `320-${colorScheme}-yayinla-plan.png`);
      for (const [name, hash, ready] of VIEWS) {
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
    console.log("PASS: Konsol phase 3 Erişim under the production CSP — Genel (warnings first with Düzelt by duzelt: Yayınla, the application, " +
      "Tailscale; summaries, a stopped WireGuard; the matrix in plain words with Teknik ayrıntı in the address; an unreadable Erişim), Tailscale (device, addresses, version, key expiry " +
      "warning, exit node, admin console link, disconnected), Adresler (publications with state, certificate and guard; local names with the " +
      "locked one and raw sources; DNS draft → plan → apply with exact bodies; a refused plan and re-check; the local domain: plan, 300 s, " +
      "confirmation only from the new address, rollback; removing a manual address), the Yayınla flow (a published container's internet name with the DNS record and the " +
      "certificate wait, the Konsol row with the typed word as onay, an application's address port named through the exact settings request, " +
      "a failing settings step and Yeniden denetle, no container step, another port as a manual address, engel and " +
      "Yeniden denetle, both names off, Konsol without an account, an unknown target), Güvenlik duvarı (the base's ports with rules, listeners, locked rows, " +
      "draft with a baseline switch and a new rule, checks, IPv6, tabs, technical rules with counters, plan → apply → 60 s → Onayla and Geri al, " +
      "a plan that cannot be applied, the WireGuard tab without networks), the leave guard on the DNS, domain and firewall drafts, the stuck rollback (retry, typed discard), a refused confirmation, the internet channel's confirmation " +
      "message, a warning's Düzelt to an application's page, the palette, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
