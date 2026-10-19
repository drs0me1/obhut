/* Konsol's interface, Erişim (DD-258; access rows since rebuild phase 4, the phase 5 prototype's screens): Genel,
   Adresler, Yerel adlar, Güvenlik duvarı and the pending settings change in the committed build under
   Data/console/yeni, with the production CSP and fixture replies for every endpoint they read or post to
   (yeni-harness.cjs). Genel: the summaries (Tailscale's leads to its admin console: no Tailscale tab, DD-288) and the
   matrix, each access row linking to its panel. Adresler: the
   addresses (Konsol, Paylaşımlar, each application port with a Caddy row) with their Tailscale name, Tailscale port,
   internet name and state, and the raw ports with their scope; a row's panel opens under the row itself, one at a time
   (no sheet beside the page); a switch or a scope opens it with that change made (a closing straight to the plan,
   an opening with its field first); "Ayrıntı" opens it as it is and closes it again, Esc closes it too:
   an address row's Tailscale name, Tailscale port, internet name and "Adresi kaldır"; a raw row's scope and host port
   with the internet consent; "Adres aç" (from the tab bar, a row or a raw row's panel, another port chosen in the panel);
   Konsol's internet name with the typed word; Paylaşımlar' Tailscale name. Every change goes through the settings
   plan with its exact body: an opening waits for the 60 s confirmation, a closing commits at once, a long apply
   stays busy and says so. The panel is in the address (?satir=<row id>, ?kip=adres-ac): Genel Bakış, the matrix,
   the firewall's locked rows and locked local names open it. Yerel adlar: names, records, forwarding (a draft →
   plan → apply) and the local domain. Güvenlik duvarı: the operator's rules beside the locked rows; the technical
   rules are Gelişmiş's. The WireGuard tab has its own suite (yeni-wireguard-ui.cjs). Fails on any console error,
   CSP violation or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-erisim-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737/6598 addresses, example names); shapes as in api/sema.ts
const NOW = 1791845000;
const DAY = 86400;
const cell = (durum, adresler = [], not = "", uyari = "") => ({ durum, adresler, not, uyari });
const { uygulama, uygulamalar, ayrinti } = require("./yeni-harness.cjs").fixtures;
const row = (id, ad, tur, cells, aciklama = "") => ({ id, ad, tur, aciklama, uygulama: null, servis: null, anahtar: null, calisiyor: true,
  yerel: cell("yok"), tailscale: cell("yok"), wireguard: cell("kapali"), internet: cell("yok"), satir: null, web: null, ...cells });
// An application port's row: id uygulama:<app>:<service>:<port>/<proto>, its stored row (satir) and its key.
function appRow(id, satir, cells) {
  const [, app, service, port] = id.split(":");
  return row(id, `${app} · ${service}`, "uygulama", { uygulama: app, servis: service, anahtar: `${service}:${port}`, satir, ...cells },
    `${port} · ${satir.tur === "adres" ? "Adres" : "Doğrudan port"}`);
}
const NOTLAR = "uygulama:notlar:web:8080/tcp";
const MEDYA = "uygulama:medya:web:8096/tcp";
const MEDYA_UDP = "uygulama:medya:web:1900/udp";
const KUTU = "uygulama:kutu:app:9000/tcp";
/** A row id in an address, as URLSearchParams writes it. */
const enc = (id) => new URLSearchParams({ satir: id }).toString().slice("satir=".length);

const WARNINGS = [
  { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda okunabilir.",
    duzelt: { bolum: "adresler", hedef: "paylasim" } },
  { seviye: "warn", hizmet: MEDYA, metin: "medya · web: 8096/tcp doğrudan internete açık; şifreleme ve giriş uygulamanın kendisinde.",
    duzelt: { bolum: "adresler", hedef: MEDYA } },
  { seviye: "warn", hizmet: MEDYA, metin: "medya uygulamasının bir servisi yeniden başlıyor.", duzelt: { bolum: "uygulama", hedef: "medya" } },
  { seviye: "warn", hizmet: NOTLAR, metin: "notlar.example.org sertifikası 10 gün sonra doluyor; Caddy kendiliğinden yeniler, yenilemezse internetten erişim kesilir.",
    duzelt: { bolum: "adresler", hedef: NOTLAR } },
];
const NOTLAR_ROW = { tur: "adres", ad: "notlar", tailscale_portu: 8443, internet: "notlar.example.org" };
function rows(o = {}) {
  return [
    row("panel", "Konsol", "konsol", { tailscale: cell("acik", ["panel.ev"]), internet: cell("kapali"),
      web: { tail: true, enabled: false, domain: "" } }, "Yönetim paneli"),
    appRow(NOTLAR, o.notlar ?? NOTLAR_ROW, { yerel: cell("acik", ["127.0.0.1:62001"]), tailscale: cell("acik", [`${(o.notlar ?? NOTLAR_ROW).ad}.ev`, "100.64.0.2:8443"]),
      internet: cell("acik", ["notlar.example.org"]) }),
    appRow(MEDYA, { tur: "ham", kapsam: "internet", port: 8096 }, { yerel: cell("kapali"), tailscale: cell("kapali"),
      internet: cell("acik", ["203.0.113.10:8096/tcp"], "", "Şifreleme ve giriş uygulamanın kendisinde.") }),
    appRow(MEDYA_UDP, { tur: "ham", kapsam: "kapali", port: 1900 }, { yerel: cell("kapali"), tailscale: cell("kapali"), internet: cell("kapali") }),
    appRow(KUTU, { tur: "ham", kapsam: "kapali", port: 9000 }, { yerel: cell("kapali"), tailscale: cell("kapali"), internet: cell("kapali") }),
    row("konteyner:dis", "dis", "konteyner", { yerel: cell("acik", ["127.0.0.1:5000/tcp"]), tailscale: cell("kapali"), internet: cell("kapali") },
      "Konteyner · Konsol dışında yönetiliyor"),
    row("paylasim", "Paylaşımlar", "paylasim", { tailscale: cell("acik", ["paylas.ev", "100.64.0.2:61010"]),
      internet: cell("acik", ["http://203.0.113.10:61010"], "", "Şifresiz HTTP"), web: { tail: true, enabled: false, domain: "" } }, "WebDAV · 2 klasör"),
    row("sistem:ssh", "SSH", "sistem", { tailscale: cell("acik", ["22/tcp"]), internet: cell("acik", ["203.0.113.10:22/tcp"]) }, "Uzak kabuk"),
    row("vpn:wg0", "WireGuard wg0", "vpn", { wireguard: cell("yok"), tailscale: cell("acik", ["61001/udp"]), internet: cell("acik", ["203.0.113.10:61001/udp"]) }, "Ana ağ"),
    row("kural:u_yazici", "Yazıcı", "kural", { tailscale: cell("kapali", ["631/tcp · yalnız 100.64.0.9"]), wireguard: cell("yok"), internet: cell("yok") }, "Engelleme kuralı · IPv4"),
  ];
}
const ROWS = rows();
function erisim(o = {}) {
  return {
    read_at: NOW, alan: "ev", revizyon: "rev-1", hatalar: [], uyarilar: WARNINGS, hizmetler: rows(),
    ozet: {
      tailscale: { ipv4: "100.64.0.2", ipv6: "fd7a:115c:a1e0::2", durum: "bagli", anahtar_bitis: NOW + 10 * DAY, ad: "sunucu.example-tailnet.ts.net", surum: "1.88.3",
        cikis_dugumu: true },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [
        { ad: "SSH", port: 22, proto: "tcp", aileler: [4, 6], kaynak: "temel" },
        { ad: "WireGuard wg0", port: 61001, proto: "udp", aileler: [4], kaynak: "temel" },
        { ad: "Oyun", port: 27015, proto: "udp", aileler: [4], kaynak: "kural" }] },
      wireguard: { kurulu: true, durduruldu: false, aglar: [{ arayuz: "wg0", ad: "Ana ağ", etkin: true, port: 61001 }] },
      sertifikalar: [{ ad: "notlar.example.org", hizmet: NOTLAR, durum: "gecerli", bitis: NOW + 10 * DAY }],
    },
    ...o,
  };
}

const PORTS = [
  { ad: "SSH", aile: 4, proto: "tcp", port: 22, kapsam: "wan", sabit: false, satir: null },
  { ad: "SSH", aile: 6, proto: "tcp", port: 22, kapsam: "wan", sabit: false, satir: null },
  { ad: "WireGuard wg0", aile: 4, proto: "udp", port: 61001, kapsam: "wan", sabit: false, satir: null },
  { ad: "medya · web 8096/tcp · doğrudan port", aile: 4, proto: "tcp", port: 8096, kapsam: "wan", sabit: true, satir: MEDYA },
  { ad: "Caddy", aile: 4, proto: "tcp", port: 80, kapsam: "tail", sabit: false, satir: null },
  { ad: "dnsmasq", aile: 4, proto: "udp", port: 53, kapsam: "tail", sabit: false, satir: null },
  { ad: "notlar · web 8080/tcp · Tailscale portu", aile: 4, proto: "tcp", port: 8443, kapsam: "tail", sabit: true, satir: NOTLAR },
  { ad: "Konsol · dosya", aile: 4, proto: "tcp", port: 62001, kapsam: "lo", sabit: false, satir: null },
];
const RULES = [{ id: "u_medya", name: "Medya", family: 4, scope: "tail", proto: "tcp", port: 8097, source: "", allow: true }];
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
      { ad: "panel.ev", aile: 4, hedef: "tailscale", kaynak: "base", satir: "panel" },
      { ad: "panel.ev", aile: 6, hedef: "fd7a:115c:a1e0::2", kaynak: "base", satir: "panel" },
      { ad: "paylas.ev", aile: 4, hedef: "tailscale", kaynak: "paylasim", satir: "paylasim" },
      { ad: "notlar.ev", aile: 4, hedef: "tailscale", kaynak: "uygulama", satir: NOTLAR },
      // A name no row owns (the projection not yet rewritten): read-only too.
      { ad: "eski.ev", aile: 4, hedef: "tailscale", kaynak: "uygulama", satir: null }],
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
  uygulamalar: uygulamalar([uygulama("notlar"), uygulama("medya"), uygulama("kutu", { servisler: [{ ad: "app", durum: "calisiyor", imaj: "registry.example/app:1", guncelleme: "sabit" }] })]),
  adlar: names(),
  "guvenlik-duvari": firewall(),
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-erisim-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8771", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, count, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies: the settings plan and apply as master_settings words them (decision 1: an opening waits
// for the 60 s confirmation, a closing commits at once)
const plan = (o = {}) => ({ revizyon: "rev-1", onay_sn: 0, degisiklikler: [], etkiler: [], uyarilar: [], uygulanabilir: true, ...o });
const item = (alan, islem, nesne, once, sonra) => ({ alan, islem, nesne, once, sonra });
const CONSENT_TEXT = "Port internete doğrudan açılır: arada Caddy, HTTPS ve Konsol girişi olmaz; şifreleme ve giriş uygulamanın kendisindedir.";
const CONSENT_MISSING = "Portu internete açmak için bu uyarıyı onaylayın (internet onayı).";
const TIMED = { seviye: "info", metin: "Uygulandıktan sonra 60 saniye içinde onaylamazsanız kendiliğinden geri alınır." };
/** master_publications.opening: whether an application row's change opens or widens access. */
function rowOpens(old, now) {
  if (now.tur === "adres") {
    if (old.tur !== "adres" || old.ad !== now.ad) return true;
    if (now.tailscale_portu !== null && now.tailscale_portu !== old.tailscale_portu) return true;
    return Boolean(now.internet) && now.internet !== old.internet;
  }
  if (now.kapsam === "kapali") return false;
  if (old.tur !== "ham" || old.kapsam === "kapali" || old.port !== now.port) return true;
  return now.kapsam === "internet" && old.kapsam !== "internet";
}
/** master_publications.web_opening for a fixed row. */
const webOpens = (before, after) => (after.tail && !before.tail) || (after.enabled && !before.enabled) || (after.enabled && before.enabled && after.domain !== before.domain);
const rowText = (r) => (r.tur === "ham" ? `Doğrudan port · ${r.kapsam} ${r.port}` : `Adres · ${r.ad}.ev · ${r.tailscale_portu ?? "kapalı"} · internet: ${r.internet || "kapalı"}`);
const appRows = () => data.erisim.hizmetler.filter((x) => x.tur === "uygulama");
const rowOf = (req) => appRows().find((x) => x.uygulama === req.uygulama && x.anahtar === req.anahtar);
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
    return plan({ degisiklikler: [item("dns", "degistir", "yazici.ev", "192.0.2.40", "192.0.2.40 · kapalı"), item("dns", "ekle", "nas.ev", null, "192.0.2.50"),
      item("dns", "degistir", "Dış adlar", "Üst DNS: 1.1.1.1, 1.0.0.1", "Üst DNS: 9.9.9.9, 149.112.112.112")],
    etkiler: ["dnsmasq yeniden başlar; yerel adlar birkaç saniye yanıt vermeyebilir."] });
  }
  if (body.erisim) {
    const r = rowOf(body.erisim), old = r.satir, now = body.erisim.satir;
    const timed = rowOpens(old, now);
    const internet = now.tur === "ham" && now.kapsam === "internet" && !(old.tur === "ham" && old.kapsam === "internet" && old.port === now.port);
    const uyarilar = internet ? [{ seviye: "warn", metin: CONSENT_TEXT }] : [];
    if (internet && !body.erisim.internet_onayi) uyarilar.push({ seviye: "bad", metin: CONSENT_MISSING });
    if (timed) uyarilar.push(TIMED);
    return plan({ onay_sn: timed ? 60 : 0, uygulanabilir: !(internet && !body.erisim.internet_onayi),
      degisiklikler: [item("erisim", old.tur !== now.tur ? (now.tur === "adres" ? "ekle" : "kaldir") : timed ? "ac" : "kapat", `${r.ad} ${body.erisim.anahtar.split(":")[1]}`, rowText(old), rowText(now))],
      etkiler: [`${r.servis} servisi (ve ona bağlı servisler) yeniden başlar; birkaç saniye yanıt vermez.`, "Güvenlik duvarı ve konteyner koruması yeniden kurulur."], uyarilar });
  }
  if (body.web) {
    const before = data.erisim.hizmetler.find((x) => x.id === body.web.service).web;
    const timed = webOpens(before, body.web);
    return plan({ onay_sn: timed ? 60 : 0, degisiklikler: [item("erisim", timed ? "ac" : "kapat", `${body.web.service === "panel" ? "Konsol" : "WebDAV"} · internet adı`,
      before.enabled ? before.domain : "kapalı", body.web.enabled ? body.web.domain : "kapalı")], etkiler: ["Caddy yapılandırması yeniden yüklenir."],
    uyarilar: timed ? [TIMED] : [] });
  }
  return null;
}
const planReplies = [];   // replies for the next ayarlar/plan POSTs, before settingsPlan()
const applyReplies = [];  // replies for the next ayarlar/uygula POSTs
const afterApply = [];    // what the server holds after the next apply (run once its reply is decided)
function applyReply(body) {
  if (body.firewall) return { body: { pending: { id: "p-fw", phase: "awaiting", seconds: 60 } } };
  if (body.domain) return { body: { pending: { id: "p-alan", phase: "awaiting", seconds: 300, domain: { old: "ev", new: body.domain } } } };
  if (body.erisim && settingsPlan(body).onay_sn) return { body: { pending: { id: "p-erisim", phase: "awaiting", seconds: 60, erisim: rowOf(body.erisim).id } } };
  if (body.web && settingsPlan(body).onay_sn) return { body: { pending: { id: "p-web", phase: "awaiting", seconds: 60, web: true } } };
  return { body: { pending: null, committed: true } };
}
h.handlers["/api/konsol/ayarlar/plan"] = ({ method, body }) => (method === "POST" ? planReplies.shift() ?? { body: settingsPlan(body) } : undefined);
h.handlers["/api/konsol/ayarlar/uygula"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const reply = applyReplies.shift() ?? applyReply(body);
  for (const change of afterApply.splice(0)) change();
  return reply;
};
for (const action of ["onayla", "geri-al", "birak"]) {
  h.handlers["/api/konsol/ayarlar/" + action] = ({ method }) => (method === "POST" ? { body: { ok: true } } : undefined);
}
// An application's page (Genel Bakış' link of a warning leads there).
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)$/, (req, m) => {
  const item = data.uygulamalar.items.find((a) => a.ad === m[1]);
  return item ? { body: ayrinti(item) } : { status: 404, body: { error: "Uygulama bulunamadı." } };
}]);

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const hashOf = (page) => page.evaluate(() => location.hash);
const lastPost = (key) => posts(key).at(-1);
const satirOf = (page) => page.evaluate(() => new URLSearchParams(location.hash.split("?")[1] ?? "").get("satir"));
/** Whether closing or reloading the tab now would ask first (the leave guard, DD-266). */
const guarded = (page) => page.evaluate(() => {
  const event = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
});
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
const dateText = (seconds) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", year: "numeric" }).format(new Date(seconds * 1000));
const KEY_DATE = dateText(NOW + 10 * DAY);
const KEY_DAY = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long" }).format(new Date((NOW + 10 * DAY) * 1000));
/** The open access row panel (under its own row in Adresler; one at a time). */
const rowSheet = (page) => page.locator("tr.row-detail .inline-panel");
/** Opens a row's panel from Adresler' tables ("Ayrıntı" or "Adres aç") and waits for its form. */
async function openRow(page, id, eylem = "ayrinti") {
  await page.getByTestId("addresses").locator(`tr[data-satir="${id}"] [data-eylem="${eylem}"]`).click();
  await page.waitForFunction((want) => new URLSearchParams(location.hash.split("?")[1] ?? "").get("satir") === want, id);
  const sheet = rowSheet(page);
  await sheet.getByTestId("row-form").waitFor();
  return sheet;
}
/** Asks for the plan from the panel's form and returns the planned body. */
async function review(sheet) {
  const before = posts("ayarlar/plan").length;
  await sheet.getByTestId("review").click();
  await sheet.getByTestId("plan").waitFor();
  await waitFor(() => posts("ayarlar/plan").length > before, "the plan was asked for");
  return lastPost("ayarlar/plan");
}

/** A table control's change opens the row's panel straight on its plan; returns the planned body. */
async function planFrom(page, control) {
  const before = posts("ayarlar/plan").length;
  await control.click();
  const sheet = rowSheet(page);
  await sheet.getByTestId("plan").waitFor();
  await waitFor(() => posts("ayarlar/plan").length > before, "the plan was asked for");
  return [sheet, lastPost("ayarlar/plan")];
}
const rowsOf = (card) => card.locator("tbody tr").evaluateAll((trs) => trs.map((t) => t.dataset.satir));

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= Erişim → Genel: the summaries and the matrix
    let page = await newPage();
    await page.goto(url("#/erisim"));
    assert.equal(await page.locator("main h1").innerText(), "Erişim");
    const tabs = page.getByRole("tablist", { name: "Erişim bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Genel", "Adresler", "Yerel adlar", "WireGuard", "Güvenlik duvarı"]);
    await page.getByTestId("matrix").waitFor();
    // Yayınla is gone: no button, no query parameter, no request to the old routes. Warnings are Genel Bakış'.
    assert.equal(await page.getByTestId("publish").count(), 0, "no Yayınla button");
    assert.equal(await page.getByRole("button", { name: "Yayınla" }).count(), 0);
    assert.equal(await page.locator(".problem").count(), 0, "no warnings card in Erişim");
    // Konsol, Paylaşımlar and notlar have a Tailscale name; notlar an internet name.
    await page.getByTestId("page-desc").filter({ hasText: "3 adres Tailscale'de · 1 internet adı · 4 uyarı" }).waitFor();
    // Summaries: one template (SummaryCard): the state, one-line rows, the tab with the details at the foot.
    const summaryRows = (card) => card.locator(".summary-rows").evaluate((dl) => [...dl.children].reduce((out, el, i, all) =>
      (el.tagName === "DT" ? [...out, [el.textContent, all[i + 1].textContent]] : out), []));
    const summary = async (id) => {
      const card = page.getByTestId(id);
      return [await card.locator(".pill").innerText(), await summaryRows(card), await card.locator(".summary-link").innerText(), await card.locator(".summary-link").getAttribute("href")];
    };
    assert.deepEqual(await summary("sum-tailscale"), ["Bağlı", [["IPv4", "100.64.0.2"], ["IPv6", "fd7a:115c:a1e0::2"], ["Anahtar", KEY_DATE]],
      "Yönetim paneli", "https://login.tailscale.com/admin/machines"], "DD-288: devices, ACLs and the key change in the admin console");
    assert.deepEqual(await page.getByTestId("sum-tailscale").locator(".summary-link").evaluate((a) => [a.target, a.rel]), ["_blank", "noopener noreferrer"]);
    assert.match(await page.getByTestId("sum-tailscale").locator("dd").nth(2).getAttribute("class"), /warn-text/, "a key within 14 days is a warning");
    // The internet card holds its addresses only; how many ports are open is its state, which ones Güvenlik duvarı's.
    assert.deepEqual(await summary("sum-internet"), ["3 port açık", [["IPv4", "203.0.113.10"], ["IPv6", "yok"]], "Güvenlik duvarı", "#/erisim?sekme=guvenlik-duvari"]);
    assert.deepEqual(await summary("sum-wireguard"), ["Açık", [["wg0", "Ana ağ · UDP 61001"]], "WireGuard", "#/erisim?sekme=wireguard"]);
    assert.deepEqual(await summary("sum-certs"), ["Yakında doluyor", [[KEY_DAY, "notlar.example.org"]], "Adresler", "#/erisim?sekme=adresler"]);
    assert.equal(await page.getByTestId("sum-certs").locator("dd").getAttribute("title"), `notlar.example.org: ${KEY_DATE} tarihine kadar`);
    // The cards of a row are as tall as each other and their links share one line.
    const feet = await page.locator(".summary-card").evaluateAll((cards) => cards.map((c) => [Math.round(c.getBoundingClientRect().height),
      Math.round(c.querySelector(".summary-link").getBoundingClientRect().bottom)]));
    assert.equal(new Set(feet.map((f) => f[0])).size, 1, "equal heights");
    assert.equal(new Set(feet.map((f) => f[1])).size, 1, "the links on one line");
    // The matrix: each cell the addresses and ports it is reached on, or its state in one word; no sentence in the
    // table. A warning or a fault is the cell's colour. An access row's name links to its sheet.
    const matrix = page.getByTestId("matrix");
    assert.deepEqual(await matrix.locator("thead th").allInnerTexts(), ["Hizmet", "Bu sunucu", "Tailscale", "WireGuard", "İnternet"]);
    assert.deepEqual(await matrix.locator("tbody tr[data-hizmet]").evaluateAll((trs) => trs.map((t) => t.dataset.hizmet)),
      ROWS.map((r) => r.id).filter((id) => id !== MEDYA_UDP), "an application is one row whatever its ports");
    assert.deepEqual(await matrix.locator("tbody tr[data-uygulama]").evaluateAll((trs) => trs.map((t) => [t.dataset.uygulama, t.querySelector(".matrix-name").textContent])),
      [["notlar", "notlar"], ["medya", "medya"], ["kutu", "kutu"]]);
    const cellsOf = (id) => matrix.locator(`tr[data-hizmet="${id}"] .matrix-cell`).evaluateAll((tds) => tds.map((td) =>
      [td.querySelector(".reach").className.match(/reach-(ok|warning|danger|accent|neutral)/)[1],
        ...[...td.querySelectorAll(".reach-lines > span:not(.sr-only)")].map((s) => s.textContent)]));
    assert.deepEqual(await cellsOf(NOTLAR), [["ok", "127.0.0.1:62001"], ["ok", "notlar.ev", "100.64.0.2:8443"], ["neutral", "Kapalı"], ["ok", "notlar.example.org"]]);
    assert.deepEqual(await cellsOf("panel"), [["neutral", "—"], ["ok", "panel.ev"], ["neutral", "Kapalı"], ["neutral", "Kapalı"]]);
    assert.deepEqual(await cellsOf(MEDYA), [["neutral", "Kapalı"], ["neutral", "Kapalı"], ["neutral", "Kapalı"], ["warning", "203.0.113.10:8096/tcp"]],
      "a raw port on the internet is a warning's colour; its closed UDP port adds nothing to the row");
    assert.deepEqual(await cellsOf("paylasim"), [["neutral", "—"], ["ok", "paylas.ev", "100.64.0.2:61010"], ["neutral", "Kapalı"], ["warning", "http://203.0.113.10:61010"]]);
    assert.deepEqual(await cellsOf("kural:u_yazici"), [["neutral", "—"], ["neutral", "631/tcp · yalnız 100.64.0.9"], ["neutral", "—"], ["neutral", "—"]],
      "a blocking rule keeps its port");
    const heard = (id) => matrix.locator(`tr[data-hizmet="${id}"] [data-hucre="internet"]`).evaluate((td) => td.textContent.replace(/\s+/g, " ").trim());
    assert.equal(await heard(NOTLAR), "Açık: notlar.example.org", "a screen reader hears the state before the address");
    assert.equal(await heard(MEDYA), "Açık, uyarı: 203.0.113.10:8096/tcp", "and a warning, which the eye sees as a colour");
    const text = await matrix.innerText();
    for (const words of ["Giriş istemez", "uygulamanın kendisinde", "Şifresiz HTTP", "yalnız internete çıkar", "klasör ·", "Adresler'de değiştir"])
      assert(!text.includes(words), `no sentence in the table: ${words}`);
    assert.equal(await matrix.locator(".matrix-cell [title], .pill, .cell-note").count(), 0, "a cell holds its addresses only");
    assert.equal(await page.getByRole("switch", { name: "Teknik ayrıntı" }).count(), 0, "no technical switch: the addresses are always there");
    assert.equal(await page.getByTestId("vpn-note").count(), 0);
    const notlar = matrix.locator(`tr[data-hizmet="${NOTLAR}"]`);
    assert.equal(await notlar.locator(".cell-sub").innerText(), "8080/tcp", "its ports under the name");
    assert.equal(await matrix.locator(`tr[data-hizmet="${MEDYA}"] .cell-sub`).innerText(), "8096/tcp · 1900/udp");
    assert.deepEqual(await matrix.getByTestId("row-link").evaluateAll((as) => as.map((a) => a.getAttribute("href"))),
      ["#/erisim?sekme=adresler&satir=panel", `#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`, "#/uygulamalar/medya?sekme=erisim",
        `#/erisim?sekme=adresler&satir=${enc(KUTU)}`, "#/erisim?sekme=adresler&satir=paylasim"],
      "Konsol, an application with one port and Paylaşımlar link to their row, one with more to its own Erişim; a container of no application has none");
    await noStyles(page, "erisim genel");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-erisim-genel.png", true);

    // A row's link opens its panel on Adresler, under the row; closing it removes the row from the address.
    await matrix.locator(`tr[data-hizmet="${KUTU}"]`).getByTestId("row-link").click();
    await page.waitForURL((u) => u.hash === `#/erisim?sekme=adresler&satir=${enc(KUTU)}`);
    let sheet = rowSheet(page);
    await sheet.getByTestId("row-form").waitFor();
    assert.equal(await sheet.locator("h3").innerText(), "kutu · app");
    assert.equal(await sheet.locator(".inline-panel-desc").innerText(), "9000/tcp · Doğrudan port");
    assert.equal(await sheet.locator('[data-kapsam="kapali"] input').isChecked(), true, "the row as the server holds it");
    assert.equal(await page.locator(`tr[data-satir="${KUTU}"] + tr.row-detail .inline-panel`).count(), 1, "the panel opens under its own row");
    assert.equal(await page.getByRole("dialog").count(), 0, "no sheet beside the page");
    await page.keyboard.press("Escape");
    await sheet.waitFor({ state: "detached" });
    assert.equal(await hashOf(page), "#/erisim?sekme=adresler", "closing removes the row from the address");
    // Yayınla's old address opens nothing.
    await page.goto(url("#/erisim?yayinla=sec"));
    await page.getByTestId("matrix").waitFor();
    await page.waitForTimeout(150);
    assert.equal(await page.getByRole("dialog").count(), 0, "?yayinla= opens nothing");
    await page.context().close();

    // ================= Tailscale has no tab of its own (DD-288): its old address opens Genel, its warnings lead there
    page = await newPage();
    await page.goto(url("#/erisim?sekme=tailscale"));
    await page.getByTestId("matrix").waitFor();
    const accessTabs = page.getByRole("tablist", { name: "Erişim bölümleri" });
    assert.equal(await accessTabs.getByRole("tab", { name: "Tailscale" }).count(), 0, "no Tailscale tab");
    assert.equal(await accessTabs.getByRole("tab", { selected: true }).innerText(), "Genel");
    await page.context().close();
    // Disconnected: a "bad" warning with no place; Uyarılar leads to Erişim → Genel, whose card says so.
    data.erisim = erisim({ uyarilar: [{ seviye: "bad", hizmet: "", metin: "Tailscale bağlı değil; Konsol'a ve tailnet adlarına öbür cihazlardan ulaşılamaz.",
      duzelt: null }] });
    data.erisim.ozet.tailscale = { ...data.erisim.ozet.tailscale, durum: "bagli-degil", anahtar_bitis: null, cikis_dugumu: false };
    data.erisim.ozet.wireguard = { kurulu: false, durduruldu: true, aglar: [] };
    page = await newPage();
    await page.goto(url("#/uyarilar"));
    const overviewFix = page.locator('.problem[data-kind="erisim"]').getByRole("link", { name: "Erişim'de incele" });
    assert.equal(await overviewFix.getAttribute("href"), "#/erisim", "a warning with no place leads to Erişim → Genel");
    await overviewFix.click();
    await page.waitForURL((u) => u.hash === "#/erisim");
    const tsCard = page.getByTestId("sum-tailscale");
    assert.equal(await tsCard.locator(".pill").innerText(), "Bağlı değil");
    assert.deepEqual(await tsCard.locator("dt").allInnerTexts(), ["IPv4", "IPv6", "Cihaz"], "no key end: the device's name instead");
    assert.equal(await tsCard.locator("dd").nth(2).innerText(), "sunucu.example-tailnet.ts.net");
    // WireGuard with no network: the summary says it is off.
    await page.goto(url("#/erisim"));
    assert.equal(await page.getByTestId("sum-wireguard").locator(".summary-empty").innerText(), "Ağ yok; açınca ilk ağ kurulur.");
    assert.equal(await page.getByTestId("sum-wireguard").locator(".pill").innerText(), "Kapalı");
    await page.context().close();
    data.erisim = erisim();
    // Uyarılar: an access row's warning leads to its panel; an application's to its page.
    page = await newPage();
    await page.goto(url("#/uyarilar"));
    const rowFix = page.locator('.problem[data-kind="erisim"] [data-eylem="duzelt"]');
    await rowFix.first().waitFor();
    assert.deepEqual(await rowFix.evaluateAll((as) => as.map((a) => [a.textContent.trim(), a.getAttribute("href")])), [
      ["Erişim'de incele", "#/erisim?sekme=adresler&satir=paylasim"], ["Erişim'de incele", `#/erisim?sekme=adresler&satir=${enc(MEDYA)}`],
      ["Uygulamaya git", "#/uygulamalar/medya"], ["Erişim'de incele", `#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`]]);
    assert.match(await page.locator('.problem[data-kind="erisim"]').nth(1).innerText(), /Erişim · medya/, "a warning is named after its application");
    await rowFix.nth(1).click();
    await page.waitForURL((u) => u.hash === `#/erisim?sekme=adresler&satir=${enc(MEDYA)}`);
    await rowSheet(page).getByTestId("row-form").waitFor();
    await page.goto(url("#/uyarilar"));
    await rowFix.nth(2).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/medya");
    await page.locator("main h1").filter({ hasText: "medya" }).waitFor();
    // The top bar's chip opens Uyarılar.
    assert.equal(await page.locator(".desktop-tools .chip").getAttribute("href"), "#/uyarilar");
    await page.context().close();
    // Erişim that cannot be read (any failure, a 404 too) says so and waits for the server.
    h.status["/api/konsol/erisim"] = 404;
    expectedFailures = ["/api/konsol/erisim"];
    page = await newPage();
    await page.goto(url("#/erisim"));
    const unread = page.locator('section[aria-label="Erişim"]');
    await unread.getByText("Erişim henüz okunamadı").waitFor();
    assert.match(await unread.innerText(), /Sunucu yanıt verince burada görünür\./);
    assert(await page.getByTestId("adres-ac").isDisabled(), "nothing to open an address for while Erişim is unknown");
    await page.context().close();
    delete h.status["/api/konsol/erisim"];
    expectedFailures = [];

    // ================= Adresler: the addresses and the raw ports
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    const list = page.getByTestId("access-rows");
    const raws = page.getByTestId("raw-rows");
    await list.locator(`tr[data-satir="${NOTLAR}"]`).waitFor();
    assert.deepEqual(await rowsOf(list), ["panel", "paylasim", NOTLAR], "Konsol, Paylaşımlar, then each application port with an address");
    assert.deepEqual(await rowsOf(raws), [MEDYA, MEDYA_UDP, KUTU], "each raw port; a container of no application has no row");
    assert.deepEqual(await list.locator("thead th").allInnerTexts(), ["Hizmet", "Tailscale adı", "Tailscale portu", "İnternet adı", "Durum", "Eylemler"]);
    assert.deepEqual(await raws.locator("thead th").allInnerTexts(), ["Hizmet", "Port", "Kapsam", "Adres", "Eylemler"]);
    const notlarRow = list.locator(`tr[data-satir="${NOTLAR}"]`);
    assert.equal(await notlarRow.locator(".col-main").innerText(), "notlar\nweb · 8080/TCP");
    assert.equal(await notlarRow.locator('[data-hucre="tailscale"] .cell-addr').innerText(), "notlar.ev");
    assert.equal(await notlarRow.getByRole("switch", { name: "notlar · Tailscale adı" }).getAttribute("aria-checked"), "true");
    assert.equal(await notlarRow.locator('[data-hucre="ts-port"] .cell-addr').innerText(), "100.64.0.2:8443");
    assert.equal(await notlarRow.locator('[data-hucre="internet"] .cell-addr').innerText(), "notlar.example.org");
    assert.match(await notlarRow.locator('[data-hucre="durum"]').innerText(), /^Sertifika · (9|10) gün$/, "days left on its certificate");
    const panelRow = list.locator('tr[data-satir="panel"]');
    assert.equal(await panelRow.locator(".col-main").innerText(), "Konsol\nYönetim paneli");
    assert.equal(await panelRow.locator('[data-hucre="tailscale"]').innerText(), "Hep açık\npanel.ev");
    assert.equal(await panelRow.locator('[data-hucre="ts-port"]').innerText(), "—");
    assert.equal(await panelRow.getByRole("switch", { name: "Konsol · İnternet adı" }).getAttribute("aria-checked"), "false");
    assert.equal(await panelRow.locator('[data-hucre="durum"]').innerText(), "Tailscale'de");
    const shareRow = list.locator('tr[data-satir="paylasim"]');
    assert.equal(await shareRow.locator('[data-hucre="ts-port"]').innerText(), "Sabit\n100.64.0.2:61010");
    assert.equal(await shareRow.locator('[data-hucre="durum"] .pill').innerText(), "Şifresiz HTTP");
    assert.equal(await shareRow.getByTestId("share-folders").getAttribute("href"), "#/dosyalar?sekme=paylasimlar");
    const medyaRaw = raws.locator(`tr[data-satir="${MEDYA}"]`);
    assert.equal(await medyaRaw.locator('td[data-label="Port"]').innerText(), "8096/TCP");
    assert.deepEqual(await medyaRaw.getByRole("radio").allInnerTexts(), ["Kapalı", "Yalnız Tailscale", "İnternet"]);
    assert.equal(await medyaRaw.getByRole("radio", { name: "İnternet" }).getAttribute("aria-checked"), "true");
    assert.equal(await medyaRaw.locator('td[data-label="Adres"]').innerText(), "203.0.113.10:8096/tcp");
    assert.equal(await raws.locator(`tr[data-satir="${KUTU}"] td[data-label="Adres"]`).innerText(), "—");
    assert.deepEqual(await raws.locator('[data-eylem="adres-ac"]').evaluateAll((bs) => bs.map((b) => b.closest("tr").dataset.satir)), [MEDYA, KUTU],
      "Adres aç only for a raw TCP port");
    assert.equal(await page.getByTestId("dns-hint").locator(".mono").innerText(), "203.0.113.10");
    await noStyles(page, "erisim adresler");
    await shot(page, "1440-light-erisim-adresler.png", true);
    // "Adres aç" beside the tabs opens the first raw TCP port as "Adres aç"; another port is chosen in the sheet.
    await page.getByTestId("adres-ac").click();
    await page.waitForURL((u) => u.hash === `#/erisim?sekme=adresler&satir=${enc(MEDYA)}&kip=adres-ac`);
    sheet = rowSheet(page);
    await sheet.locator("h3").filter({ hasText: "medya · web · Adres aç" }).waitFor();
    assert.deepEqual(await sheet.getByTestId("row-pick").locator("option").allInnerTexts(), ["medya · web · 8096/TCP", "kutu · app · 9000/TCP"]);
    await sheet.getByTestId("row-pick").selectOption(KUTU);
    await page.waitForFunction((want) => new URLSearchParams(location.hash.split("?")[1] ?? "").get("satir") === want, KUTU);
    assert.equal(new URLSearchParams((await hashOf(page)).split("?")[1]).get("kip"), "adres-ac", "still Adres aç");
    await sheet.locator("h3").filter({ hasText: "kutu · app · Adres aç" }).waitFor();
    assert.equal(await sheet.getByTestId("row-name").inputValue(), "kutu", "the chosen port's name suggestion");
    await shot(page, "1440-light-erisim-adres-ac-sec.png");
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    assert.equal(await hashOf(page), "#/erisim?sekme=adresler");
    // A row's panel opens under the row itself, one at a time: "Ayrıntı" opens and closes it, another row's moves it.
    const detailOf = (id) => page.locator(`tr[data-satir="${id}"] + tr.row-detail .inline-panel`);
    const toggleOf = (card, id) => card.locator(`tr[data-satir="${id}"] [data-eylem="ayrinti"]`);
    assert.equal(await toggleOf(list, NOTLAR).getAttribute("aria-expanded"), "false");
    await toggleOf(list, NOTLAR).click();
    await detailOf(NOTLAR).getByTestId("row-form").waitFor();
    assert.equal(await toggleOf(list, NOTLAR).getAttribute("aria-expanded"), "true");
    assert.equal(await toggleOf(list, NOTLAR).getAttribute("aria-controls"), await detailOf(NOTLAR).evaluate((el) => el.closest("td").id));
    assert.equal(await detailOf(NOTLAR).getByRole("heading").innerText(), "notlar · web");
    assert.equal(await page.evaluate(() => document.querySelector(".app").inert), false, "the page stays usable around the panel");
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "row-name");
    await shot(page, "1440-light-erisim-satir-panel.png");
    await toggleOf(raws, KUTU).click();
    await detailOf(KUTU).getByTestId("row-form").waitFor();
    assert.equal(await page.locator(".inline-panel").count(), 1, "only the chosen row's panel is open");
    assert.equal(await toggleOf(list, NOTLAR).getAttribute("aria-expanded"), "false");
    await toggleOf(raws, KUTU).click();
    await detailOf(KUTU).waitFor({ state: "detached" });
    assert.equal(await hashOf(page), "#/erisim?sekme=adresler", "closing removes the row from the address");
    // Esc in the panel closes it; the focus goes back to its row's "Ayrıntı".
    await toggleOf(list, NOTLAR).click();
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "row-name");
    await page.keyboard.press("Escape");
    await detailOf(NOTLAR).waitFor({ state: "detached" });
    assert(await toggleOf(list, NOTLAR).evaluate((el) => el === document.activeElement), "the focus is back on its Ayrıntı");
    await page.context().close();

    // ================= Yerel adlar: the managed names read-only, the records (draft → plan → apply) and the local domain
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adlar"));
    const namesCard = page.getByTestId("names");
    await namesCard.locator('tr[data-ad="panel.ev"]').waitFor();
    assert.deepEqual(await namesCard.locator("tbody tr").evaluateAll((trs) => trs.map((t) => t.dataset.ad || "k:" + t.dataset.kayit)),
      ["panel.ev", "paylas.ev", "notlar.ev", "eski.ev", "k:yazici.ev"]);
    assert.equal(await namesCard.locator('tr[data-ad="panel.ev"] td').first().innerText(), "Tailscale adresi · 100.64.0.2 · fd7a:115c:a1e0::2");
    assert.deepEqual(await namesCard.locator('td[data-label="Sahibi"]').allInnerTexts(), ["Konsol", "Paylaşımlar", "notlar", "Uygulama", "Elle"]);
    assert.equal(await namesCard.locator('tr[data-ad="panel.ev"]').getByTestId("name-locked").innerText(), "Konsol'un adı");
    // No managed name has a switch (rebuild phase 6): each changes in its own row; only the operator's records switch.
    assert.equal(await namesCard.locator("tr[data-ad]").getByRole("switch").count(), 0, "no managed name is switched here");
    assert.equal(await namesCard.locator('tr[data-ad="eski.ev"]').getByTestId("name-locked").innerText(), "Salt okunur");
    assert.equal(await namesCard.locator('tr[data-ad="notlar.ev"]').getByTestId("name-row").getAttribute("href"), `#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`);
    // WebDAV's name has one home: Paylaşımlar' Tailscale switch in Adresler.
    assert.equal(await namesCard.locator('tr[data-ad="paylas.ev"]').getByTestId("name-row").getAttribute("href"), "#/erisim?sekme=adresler&satir=paylasim");
    assert.equal(await namesCard.getByRole("switch", { name: "yazici.ev açık" }).getAttribute("aria-checked"), "true");
    assert.equal(await namesCard.locator('tr[data-kayit="yazici.ev"] td').first().innerText(), "Sabit adres · 192.0.2.40");
    await noStyles(page, "erisim adlar");
    await shot(page, "1440-light-erisim-adlar.png", true);
    // A locked name's link opens its row's sheet.
    await namesCard.locator('tr[data-ad="notlar.ev"]').getByTestId("name-row").click();
    sheet = rowSheet(page);
    await sheet.getByTestId("row-form").waitFor();
    assert.equal(await sheet.locator("h3").innerText(), "notlar · web");
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    await page.goto(url("#/erisim?sekme=adlar"));
    await namesCard.locator('tr[data-ad="paylas.ev"]').waitFor();
    // The draft: a record off, a record added, forwarding to Quad9.
    assert.equal(await page.getByTestId("dns-draft").count(), 0);
    assert.equal(await guarded(page), false, "no draft, no question");
    await namesCard.getByRole("switch", { name: "yazici.ev açık" }).click();
    await page.getByTestId("dns-draft").filter({ hasText: "1 değişiklik kaydedilmedi" }).waitFor();
    assert.equal(await guarded(page), true, "a DNS draft asks before the tab closes");
    await page.getByTestId("add-record").click();
    sheet = page.getByRole("dialog", { name: "Kayıt ekle" });
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
    await page.getByTestId("dns-draft").filter({ hasText: "3 değişiklik kaydedilmedi" }).waitFor();
    assert(await page.getByTestId("review-domain").isDisabled(), "no domain change over a draft");
    await shot(page, "1440-light-erisim-dns-taslak.png", true);
    await page.getByTestId("review-dns").click();
    sheet = page.getByRole("dialog", { name: "Yerel ad değişiklikleri" });
    await sheet.getByTestId("plan").waitFor();
    const DNS_BODY = { revision: "rev-1", dns: { records: [{ name: "yazici.ev", target: "192.0.2.40", enabled: false },
      { name: "nas.ev", target: "192.0.2.50", enabled: true }], forward: true, servers: ["9.9.9.9", "149.112.112.112"] } };
    assert.deepEqual(lastPost("ayarlar/plan"), DNS_BODY, "the plan asks for exactly the draft");
    assert.equal(await sheet.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.");
    assert.deepEqual(await sheet.locator(".plan-item .pill").allInnerTexts(), ["Değişir", "Eklenir", "Değişir"]);
    assert.deepEqual(await sheet.locator(".plan-group[data-alan] .plan-title").allInnerTexts(), ["Yerel adlar (DNS)"]);
    const off = sheet.locator('.plan-item[data-islem="degistir"]').first();
    assert.deepEqual([await off.locator(".plan-object").innerText(), await off.locator(".plan-before").innerText(), await off.locator(".plan-after").innerText()],
      ["yazici.ev", "192.0.2.40", "192.0.2.40 · kapalı"], "before → after");
    await shot(page, "1440-light-erisim-dns-plan.png");
    data.adlar = { ...names(), kayitlar: DNS_BODY.dns.records, sunucular: DNS_BODY.dns.servers };
    const namesReads = count("adlar");
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), DNS_BODY, "apply sends the planned body unchanged");
    await page.getByTestId("names-note").filter({ hasText: "Yerel adlar kaydedildi." }).waitFor();
    await waitFor(() => count("adlar") > namesReads, "names read again");
    await page.getByTestId("dns-draft").waitFor({ state: "detached" });
    assert.equal(await namesCard.getByRole("switch", { name: "yazici.ev açık" }).getAttribute("aria-checked"), "false");
    data.adlar = names();
    // A refused plan shows the backend's words and can be asked again.
    await namesCard.getByRole("switch", { name: "yazici.ev açık" }).click();
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
    await page.getByTestId("domain").getByText("Yeni yerel alan adını yazın (ör. ev).").waitFor();
    await page.getByTestId("domain-input").fill("Ev");
    assert.equal(await guarded(page), true, "a typed domain asks before the tab closes");
    await page.getByTestId("review-domain").click();
    await page.getByTestId("domain").getByText("Yerel alan adı zaten bu değerde.").waitFor();
    await page.getByTestId("domain-input").fill("ofis");
    await page.getByTestId("review-domain").click();
    sheet = page.getByRole("dialog", { name: "Yerel alan adı değişsin mi?" });
    await sheet.getByTestId("plan").waitFor();
    assert.deepEqual(lastPost("ayarlar/plan"), { revision: "rev-1", domain: "ofis" });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /5:00 içinde onaylamazsanız/);
    assert.match(await sheet.locator(".modal-list").innerText(), /Restrict to domain” ile ofis alanını ekleyin/);
    assert.equal(await sheet.locator(".plan-address").innerText(), "http://panel.ofis/");
    assert.equal(await sheet.getByTestId("apply").innerText(), "Yerel alan adını değiştir");
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
    assert.equal(await domainNote.getByRole("link", { name: "panel.ofis" }).getAttribute("href"), "http://panel.ofis/#/erisim?sekme=adlar");
    assert.equal(await domainNote.getByRole("link", { name: "panel.ev" }).getAttribute("href"), "http://panel.ev/#/erisim?sekme=adlar");
    assert(await banner.getByTestId("pending-confirm").isDisabled(), "a domain change is confirmed only from the new address");
    assert.equal(await page.getByTestId("domain-pending").getByRole("link").getAttribute("href"), "http://panel.ofis/#/erisim?sekme=adlar");
    assert(await page.getByTestId("review-domain").isDisabled(), "no new change while one is pending");
    await page.getByTestId("names-locked").waitFor();
    await shot(page, "1440-light-erisim-alan-bekliyor.png");
    await banner.getByTestId("pending-rollback").click();
    await banner.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/geri-al"), { id: "p-alan" });
    await page.getByTestId("pending-result").filter({ hasText: "Önceki ayarlar geri yüklendi." }).waitFor();
    await page.getByTestId("domain-pending").waitFor({ state: "detached" });
    await page.context().close();

    // ================= an address row: a new Tailscale name (an opening: 60 s), a long apply that stays busy
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    sheet = await openRow(page, NOTLAR);
    assert.equal(await satirOf(page), NOTLAR, "the panel is in the address");
    assert.equal(await sheet.locator("h3").innerText(), "notlar · web");
    assert.equal(await sheet.locator(".inline-panel-desc").innerText(), "8080/tcp · Adres");
    assert.deepEqual(await sheet.getByTestId("row-facts").locator("dd").allInnerTexts(), ["notlar · web · 8080/TCP", "127.0.0.1:62001 → 8080", "notlar.ev"]);
    assert.equal(await sheet.getByTestId("row-name").inputValue(), "notlar");
    assert(await sheet.getByTestId("row-name").evaluate((el) => el === document.activeElement), "the name has focus");
    assert.equal(await sheet.getByRole("switch", { name: "Tailscale portu" }).getAttribute("aria-checked"), "true");
    assert.equal(await sheet.getByTestId("row-ts-port").inputValue(), "8443");
    assert.equal(await sheet.getByRole("switch", { name: "İnternet adı" }).getAttribute("aria-checked"), "true");
    assert.equal(await sheet.getByTestId("row-host").inputValue(), "notlar.example.org");
    assert.equal(await sheet.getByTestId("row-dns").innerText(),
      "Alan adı sağlayıcınızda bir A kaydı gerekir: notlar.example.org → 203.0.113.10, proxy kapalı (DNS only), AAAA kaydı yok.");
    assert(await sheet.getByTestId("review").isDisabled(), "nothing changed yet");
    await shot(page, "1440-light-erisim-satir-adres.png");
    // Names are checked before the server is asked: Obhut's own, the rules, another row's.
    const plansBefore = posts("ayarlar/plan").length;
    await sheet.getByTestId("row-name").fill("panel");
    await sheet.getByTestId("review").click();
    await sheet.getByText("panel adı Obhut'undur; başka bir ad seçin.").waitFor();
    assert(await sheet.getByTestId("review").isDisabled(), "an invalid form cannot be reviewed");
    await sheet.getByTestId("row-name").fill("Yazi_1");
    await sheet.getByText("Küçük harf, rakam ve tire; tireyle başlamaz ya da bitmez (en çok 63).").waitFor();
    await sheet.getByTestId("row-name").fill("paylas");
    await sheet.getByText("paylas adı Obhut'undur; başka bir ad seçin.").waitFor();
    await sheet.getByTestId("row-name").fill("yazici");
    await sheet.getByText("yazici adı başka bir satırda kullanılıyor.").waitFor();
    assert.equal(posts("ayarlar/plan").length, plansBefore, "no plan for a form that does not pass");
    await sheet.getByTestId("row-name").fill("Yazilar");
    let body = await review(sheet);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "notlar", anahtar: "web:8080/tcp",
      satir: { tur: "adres", ad: "yazilar", tailscale_portu: 8443, internet: "notlar.example.org" } } });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /Süreli onay: uygulandıktan sonra 1:00 içinde onaylamazsanız/, "a rename opens: it waits");
    assert.deepEqual(await sheet.locator(".plan-group[data-alan] .plan-title").allInnerTexts(), ["Adresler"]);
    assert.equal(await sheet.getByTestId("plan-back").innerText(), "Geri");
    await shot(page, "1440-light-erisim-satir-plan.png");
    // Geri returns to the form as it was; İncele asks again.
    await sheet.getByTestId("plan-back").click();
    assert.equal(await sheet.getByTestId("row-name").inputValue(), "Yazilar");
    body = await review(sheet);
    // The apply restarts the service and waits until it is ready: it stays busy, counting, and cannot be closed.
    let release;
    const held = new Promise((resolve) => (release = resolve));
    await page.route("**/api/konsol/ayarlar/uygula", async (route) => {
      await held;
      return h.answer(route);
    });
    const erisimReads = count("erisim");
    await sheet.getByTestId("apply").click();
    await sheet.getByTestId("apply-progress").filter({ hasText: /^Uygulanıyor; servis gerekirse yeniden başlar ve hazır olması beklenir \(birkaç dakika sürebilir\)… \d+ sn$/ }).waitFor();
    await sheet.getByTestId("apply-progress").filter({ hasText: /… [2-9] sn$/ }).waitFor({ timeout: 6000 });
    assert.equal(await sheet.getByTestId("apply").innerText(), "Uygulanıyor…");
    assert(await sheet.getByTestId("apply").isDisabled(), "no second apply while it runs");
    assert(await sheet.getByTestId("plan-back").isDisabled());
    await page.keyboard.press("Escape");
    assert.equal(await sheet.count(), 1, "the sheet stays while the change is applied");
    await shot(page, "1440-light-erisim-satir-uygulaniyor.png");
    const renamed = body.erisim.satir;
    afterApply.push(() => (data.erisim = erisim({ hizmetler: rows({ notlar: renamed }) })));
    release();
    await sheet.waitFor({ state: "detached" });
    await page.unroute("**/api/konsol/ayarlar/uygula");
    assert.deepEqual(lastPost("ayarlar/uygula"), body, "apply sends the planned body unchanged");
    await page.getByTestId("addresses-note").filter({ hasText: "Değişiklik uygulandı; 60 saniye içinde yukarıdaki banttan onaylayın." }).waitFor();
    const rowPending = page.locator(".pending");
    await rowPending.waitFor();
    await page.getByTestId("countdown").filter({ hasText: /^(1:00|0:59)$/ }).waitFor();
    assert(await rowPending.getByTestId("pending-confirm").isEnabled(), "confirmed from Tailscale");
    await waitFor(() => count("erisim") > erisimReads, "Erişim read again after the apply");
    await page.getByTestId("access-rows").locator(`tr[data-satir="${NOTLAR}"] [data-hucre="tailscale"]`).filter({ hasText: "yazilar.ev" }).waitFor();
    assert.equal(await rowPending.getByTestId("pending-title").innerText(), "Bekleyen değişiklik: Erişim değişikliği · yazilar.ev", "the banner names the row");
    const notlarNow = page.getByTestId("access-rows").locator(`tr[data-satir="${NOTLAR}"]`);
    assert(await notlarNow.locator('[data-eylem="ayrinti"]').isDisabled(), "no new change while one is pending");
    assert(await notlarNow.getByRole("switch", { name: "notlar · Tailscale portu" }).isDisabled(), "the table's switches wait too");
    assert(await page.getByTestId("adres-ac").isDisabled());
    await page.getByTestId("addresses-locked").waitFor();
    await shot(page, "1440-light-erisim-satir-bekliyor.png");
    await rowPending.getByTestId("pending-confirm").click();
    await rowPending.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/onayla"), { id: "p-erisim" });
    await page.getByTestId("pending-result").filter({ hasText: "Ayarlar kalıcı olarak kaydedildi." }).waitFor();

    // A switch of the table that closes goes straight to the plan: the Tailscale port off commits at once; Geri shows
    // the form with the switch off.
    let [plans, planned] = await planFrom(page, notlarNow.getByRole("switch", { name: "notlar · Tailscale portu" }));
    assert.deepEqual(planned, { revision: "rev-1", erisim: { uygulama: "notlar", anahtar: "web:8080/tcp",
      satir: { tur: "adres", ad: "yazilar", tailscale_portu: null, internet: "notlar.example.org" } } }, "the row the server now holds, the port off");
    assert.equal(await plans.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.", "a closing commits at once");
    await plans.getByTestId("plan-back").click();
    assert.equal(await plans.getByRole("switch", { name: "Tailscale portu" }).getAttribute("aria-checked"), "false");
    // Closing: the internet name off too, from the form.
    await plans.getByRole("switch", { name: "İnternet adı" }).click();
    assert.equal(await plans.getByTestId("row-host").count(), 0);
    body = await review(plans);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "notlar", anahtar: "web:8080/tcp",
      satir: { tur: "adres", ad: "yazilar", tailscale_portu: null, internet: "" } } });
    assert.equal(await plans.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.", "a closing commits at once");
    const closed = body.erisim.satir;
    afterApply.push(() => (data.erisim = erisim({ hizmetler: rows({ notlar: closed }) })));
    await plans.getByTestId("apply").click();
    await plans.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), body);
    await page.getByTestId("addresses-note").filter({ hasText: "Değişiklik kaydedildi." }).waitFor();
    assert.equal(await page.locator(".pending").count(), 0, "nothing waits");
    // A switch that opens asks for its value first: the Tailscale port's field has the focus.
    await notlarNow.getByRole("switch", { name: "notlar · Tailscale portu", checked: false }).click();
    sheet = rowSheet(page);
    await sheet.getByTestId("row-form").waitFor();
    assert.equal(await sheet.getByRole("switch", { name: "Tailscale portu" }).getAttribute("aria-checked"), "true");
    assert.equal(await sheet.getByTestId("row-ts-port").inputValue(), "8080", "the container port to start with");
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "row-ts-port");
    await sheet.getByTestId("row-ts-port").fill("70000");
    await sheet.getByRole("switch", { name: "İnternet adı" }).click();
    await sheet.getByTestId("row-host").fill("https://yazilar.example.org/");
    await sheet.getByTestId("review").click();
    await sheet.getByText("1 ile 65535 arasında bir port yazın.").waitFor();
    await sheet.getByText("Tam alan adını girin; URL, IP, port veya yol eklemeyin.").waitFor();
    await sheet.getByTestId("row-ts-port").fill("9443");
    await sheet.getByTestId("row-host").fill("Yazilar.Example.org.");
    assert.equal(await sheet.getByTestId("row-dns").innerText(),
      "Alan adı sağlayıcınızda bir A kaydı gerekir: yazilar.example.org → 203.0.113.10, proxy kapalı (DNS only), AAAA kaydı yok.");
    body = await review(sheet);
    assert.deepEqual(body.erisim.satir, { tur: "adres", ad: "yazilar", tailscale_portu: 9443, internet: "yazilar.example.org" });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /1:00 içinde/);
    // The server refuses the apply (it rolled the change back): the panel says why and stays on the plan.
    expectedFailures = ["/api/konsol/ayarlar/uygula"];
    applyReplies.push({ status: 400, body: { error: "notlar · web hazır olmadı; değişiklik geri alındı." } });
    await sheet.getByTestId("apply").click();
    await sheet.getByTestId("apply-error").filter({ hasText: "notlar · web hazır olmadı; değişiklik geri alındı." }).waitFor();
    assert(await sheet.getByTestId("apply").isEnabled(), "another try stays possible");
    assert.equal(await page.locator(".pending").count(), 0);
    await shot(page, "1440-light-erisim-satir-hata.png");
    expectedFailures = [];
    await sheet.getByTestId("plan-back").click();
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    assert.equal(await satirOf(page), null);
    // The internet name's switch opens the form with the name's field first.
    await notlarNow.getByRole("switch", { name: "notlar · İnternet adı" }).click();
    sheet = rowSheet(page);
    await sheet.getByTestId("row-host").waitFor();
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "row-host");
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });

    // "Adresi kaldır": the port becomes a closed raw port on its container port; it commits at once.
    sheet = await openRow(page, NOTLAR);
    await sheet.getByTestId("row-remove").click();
    await sheet.getByTestId("plan").waitFor();
    body = lastPost("ayarlar/plan");
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "notlar", anahtar: "web:8080/tcp", satir: { tur: "ham", kapsam: "kapali", port: 8080 } } });
    assert.equal(await sheet.getByTestId("apply").innerText(), "Adresi kaldır");
    assert.match(await sheet.getByTestId("apply").getAttribute("class"), /btn-danger/);
    assert.equal(await sheet.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.");
    assert.deepEqual(await sheet.locator(".plan-item .pill").allInnerTexts(), ["Kaldırılır"]);
    await sheet.getByTestId("plan-back").click();
    await sheet.getByTestId("row-name").waitFor();
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    // The Tailscale name's switch off is the same removal, straight to its plan.
    [plans, planned] = await planFrom(page, notlarNow.getByRole("switch", { name: "notlar · Tailscale adı" }));
    assert.deepEqual(planned, body);
    assert.equal(await plans.getByTestId("apply").innerText(), "Adresi kaldır");
    await plans.getByTestId("apply").click();
    await plans.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), body);
    await page.getByTestId("addresses-note").filter({ hasText: "Adres kaldırıldı." }).waitFor();
    assert.equal(await page.locator(".pending").count(), 0);
    data.erisim = erisim();
    await page.context().close();

    // ================= raw rows: a scope from the table, Tailscale on another port (opening), the internet with the consent
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    const rawRow = (id) => page.getByTestId("raw-rows").locator(`tr[data-satir="${id}"]`);
    await rawRow(KUTU).waitFor();
    // "Yalnız Tailscale" in the table: an opening on the row's own port, straight to the plan; rolled back.
    [plans, planned] = await planFrom(page, rawRow(KUTU).getByRole("radio", { name: "Yalnız Tailscale" }));
    assert.deepEqual(planned, { revision: "rev-1", erisim: { uygulama: "kutu", anahtar: "app:9000/tcp", satir: { tur: "ham", kapsam: "tailscale", port: 9000 } } });
    assert.match(await plans.getByTestId("plan-window").innerText(), /1:00 içinde/, "a raw port opened waits");
    await plans.getByTestId("plan-back").click();
    assert.equal(await plans.locator('[data-kapsam="tailscale"] input').isChecked(), true, "the form holds the table's choice");
    assert.equal(await plans.getByTestId("row-port").inputValue(), "9000", "the container port by default");
    await plans.getByTestId("row-port").fill("9001");
    assert.equal(await plans.getByTestId("row-scope-hint").innerText(), "Tailscale cihazlarınız 100.64.0.2:9001 ile ulaşır.");
    assert.equal(await plans.getByTestId("row-consent").count(), 0, "no consent for Tailscale");
    await shot(page, "1440-light-erisim-satir-ham.png");
    body = await review(plans);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "kutu", anahtar: "app:9000/tcp", satir: { tur: "ham", kapsam: "tailscale", port: 9001 } } });
    await plans.getByTestId("apply").click();
    await plans.waitFor({ state: "detached" });
    await page.locator(".pending").waitFor();
    await page.locator(".pending").getByTestId("pending-rollback").click();
    await page.locator(".pending").waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/geri-al"), { id: "p-erisim" });
    // A UDP port to the internet from the table: no address for it; the form asks for the consent first.
    const consentPlans = posts("ayarlar/plan").length;
    await rawRow(MEDYA_UDP).getByRole("radio", { name: "İnternet" }).click();
    sheet = rowSheet(page);
    await sheet.getByTestId("row-consent").waitFor();
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "row-consent-box");
    assert.equal(posts("ayarlar/plan").length, consentPlans, "no plan without the consent");
    assert.equal(await sheet.getByTestId("row-open-address").count(), 0, "a UDP port cannot get an address");
    assert.equal(await sheet.getByTestId("row-scope-hint").innerText(), "İnternetteki herkes 203.0.113.10:1900 ile ulaşır; arada Caddy ve HTTPS yok.");
    assert.match(await sheet.getByTestId("row-consent").innerText(), /arada Caddy, HTTPS ve Konsol girişi olmaz/);
    await sheet.getByTestId("review").click();
    await sheet.getByText("Portu internete açmak için onay kutusunu işaretleyin.").waitFor();
    assert.equal(posts("ayarlar/plan").length, consentPlans, "no plan without the consent");
    await shot(page, "1440-light-erisim-satir-onay.png");
    await sheet.getByTestId("row-consent-box").check();
    body = await review(sheet);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "medya", anahtar: "web:1900/udp", satir: { tur: "ham", kapsam: "internet", port: 1900 },
      internet_onayi: true } });
    assert.equal((await sheet.locator('.plan-warning[data-seviye="warn"]').innerText()).replace(/^Uyarı:\s*/, ""), CONSENT_TEXT);
    assert.equal(await sheet.getByTestId("plan-blocked").count(), 0);
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), body);
    await page.locator(".pending").getByTestId("pending-confirm").click();
    await page.locator(".pending").waitFor({ state: "detached" });
    // Internet → Tailscale on the same port narrows access: no consent, no wait.
    sheet = await openRow(page, MEDYA);
    assert.equal(await sheet.locator('[data-kapsam="internet"] input').isChecked(), true);
    assert.equal(await sheet.getByTestId("row-consent").count(), 0, "already on the internet on this port");
    await sheet.getByTestId("row-port").fill("8097");
    await sheet.getByTestId("row-consent").waitFor();
    await sheet.getByTestId("row-port").fill("8096");
    await sheet.locator('[data-kapsam="tailscale"]').click();
    body = await review(sheet);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "medya", anahtar: "web:8096/tcp", satir: { tur: "ham", kapsam: "tailscale", port: 8096 } } });
    assert.equal(await sheet.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.");
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    await page.getByTestId("addresses-note").filter({ hasText: "Değişiklik kaydedildi." }).waitFor();
    // "Kapalı" from the table closes at once.
    [plans, planned] = await planFrom(page, rawRow(MEDYA).getByRole("radio", { name: "Kapalı" }));
    assert.deepEqual(planned.erisim.satir, { tur: "ham", kapsam: "kapali", port: 8096 });
    assert.equal(await plans.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.");
    await plans.getByRole("button", { name: "Geri" }).click();
    await plans.getByRole("button", { name: "Vazgeç" }).click();
    await plans.waitFor({ state: "detached" });

    // "Adres aç": a raw TCP port gets a Tailscale name (an opening), with a Tailscale port and an internet name if asked.
    sheet = await openRow(page, KUTU, "adres-ac");
    assert.equal(await sheet.locator("h3").innerText(), "kutu · app · Adres aç");
    assert.equal(await sheet.getByTestId("row-name").inputValue(), "kutu", "the application's name when it is free");
    assert.equal(await sheet.getByTestId("row-facts").count(), 0);
    await sheet.getByTestId("row-name").fill("notlar");
    await sheet.getByTestId("review").click();
    await sheet.getByText("notlar adı başka bir satırda kullanılıyor.").waitFor();
    await sheet.getByTestId("row-name").fill("kutu");
    await sheet.getByRole("switch", { name: "Tailscale portu" }).click();
    assert.equal(await sheet.getByTestId("row-ts-port").inputValue(), "9000");
    await sheet.getByRole("switch", { name: "İnternet adı" }).click();
    await sheet.getByTestId("row-host").fill("kutu.example.org");
    await shot(page, "1440-light-erisim-adres-ac.png");
    body = await review(sheet);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "kutu", anahtar: "app:9000/tcp",
      satir: { tur: "adres", ad: "kutu", tailscale_portu: 9000, internet: "kutu.example.org" } } });
    await sheet.getByTestId("plan-back").click();
    await sheet.getByRole("switch", { name: "Tailscale portu" }).click();
    await sheet.getByRole("switch", { name: "İnternet adı" }).click();
    body = await review(sheet);
    assert.deepEqual(body, { revision: "rev-1", erisim: { uygulama: "kutu", anahtar: "app:9000/tcp", satir: { tur: "adres", ad: "kutu", tailscale_portu: null, internet: "" } } });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /1:00 içinde/);
    assert.deepEqual(await sheet.locator(".plan-item .pill").allInnerTexts(), ["Eklenir"]);
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    await page.getByTestId("addresses-note").filter({ hasText: "Adres açıldı; 60 saniye içinde yukarıdaki banttan onaylayın." }).waitFor();
    await page.locator(".pending").getByTestId("pending-confirm").click();
    await page.locator(".pending").waitFor({ state: "detached" });
    sheet = await openRow(page, KUTU);
    await sheet.getByTestId("row-open-address").click();
    await sheet.locator("h3").filter({ hasText: "kutu · app · Adres aç" }).waitFor();
    assert.equal(await sheet.getByTestId("row-name").inputValue(), "kutu");
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });
    await page.context().close();

    // ================= the fixed rows: Konsol's internet name with the typed word, Paylaşımlar' Tailscale name
    page = await newPage();
    await page.goto(url("#/erisim?sekme=adresler"));
    await page.getByTestId("access-rows").locator('tr[data-satir="panel"]').getByRole("switch", { name: "Konsol · İnternet adı" }).click();
    sheet = rowSheet(page);
    await sheet.getByTestId("row-form").waitFor();
    assert.equal(await sheet.locator("h3").innerText(), "Konsol");
    assert.deepEqual(await sheet.getByTestId("row-facts").locator("dd").allInnerTexts(), ["Yönetim paneli", "Konsol soketi", "panel.ev"]);
    assert(await sheet.getByRole("switch", { name: "Tailscale adı" }).isDisabled(), "Konsol's Tailscale name stays on");
    assert.match(await sheet.locator(".row-col").first().innerText(), /panel\.ev · Konsol'un Tailscale adı hep açıktır\./);
    assert.equal(await sheet.getByRole("switch", { name: "İnternet adı" }).getAttribute("aria-checked"), "true", "the table's switch, made");
    await page.waitForFunction(() => document.activeElement?.dataset.testid === "row-host");
    await sheet.getByTestId("row-host").fill("konsol.example.org");
    await sheet.getByTestId("konsol-word").waitFor();
    assert.match(await sheet.getByTestId("konsol-word").innerText(), /https:\/\/konsol\.example\.org adresinde Konsol'un giriş sayfası internete açılır/);
    const konsolPlans = posts("ayarlar/plan").length;
    assert(await sheet.getByTestId("review").isDisabled(), "no plan before the typed word");
    await sheet.getByLabel("Onaylamak için onayla yazın").fill("onay");
    assert(await sheet.getByTestId("review").isDisabled());
    await shot(page, "1440-light-erisim-konsol.png");
    await sheet.getByLabel("Onaylamak için onayla yazın").fill("ONAYLA");
    body = await review(sheet);
    assert.equal(posts("ayarlar/plan").length, konsolPlans + 1);
    assert.deepEqual(body, { revision: "rev-1", web: { service: "panel", tail: true, enabled: true, domain: "konsol.example.org", confirm: "onayla" } });
    assert.match(await sheet.getByTestId("plan-window").innerText(), /1:00 içinde/);
    await sheet.getByTestId("apply").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("ayarlar/uygula"), body);
    await page.locator(".pending").getByTestId("pending-confirm").click();
    await page.locator(".pending").waitFor({ state: "detached" });
    // Paylaşımlar: its Tailscale name off from the table commits at once; its folders are Dosyalar' (a link).
    [plans, planned] = await planFrom(page, page.getByTestId("access-rows").locator('tr[data-satir="paylasim"]').getByRole("switch", { name: "Paylaşımlar · Tailscale adı" }));
    assert.deepEqual(planned, { revision: "rev-1", web: { service: "paylasim", tail: false, enabled: false, domain: "" } });
    assert.equal(await plans.getByTestId("plan-window").innerText(), "Hemen kaydedilir; onay beklenmez.");
    await plans.getByTestId("plan-back").click();
    assert.equal(await plans.locator("h3").innerText(), "Paylaşımlar");
    assert.equal(await plans.getByTestId("row-shares").getAttribute("href"), "#/dosyalar?sekme=paylasimlar");
    assert.equal(await plans.getByTestId("row-problem").innerText(), "Şifresiz HTTP", "its internet cell's warning");
    body = await review(plans);
    assert.deepEqual(body, planned);
    await plans.getByTestId("apply").click();
    await plans.waitFor({ state: "detached" });
    await page.getByTestId("addresses-note").filter({ hasText: "Değişiklik kaydedildi." }).waitFor();
    // A row that is not there says so.
    await page.goto(url("#/erisim?sekme=adresler&satir=uygulama:yok:web:80/tcp"));
    await page.getByTestId("row-missing").filter({ hasText: "uygulama:yok:web:80/tcp" }).waitFor();
    assert.equal(await page.getByRole("dialog").count(), 0);
    // A deep link with the row id encoded opens the same sheet.
    await page.goto(url(`#/erisim?sekme=adresler&satir=${enc(KUTU)}`));
    await rowSheet(page).getByTestId("row-form").waitFor();
    assert.equal(await rowSheet(page).locator("h3").innerText(), "kutu · app");
    await page.context().close();

    // ================= Güvenlik duvarı: the base's ports with the rules, a draft → plan → apply → 60 s → Onayla
    page = await newPage();
    await page.goto(url("#/erisim?sekme=guvenlik-duvari"));
    const fwView = page.getByTestId("firewall");
    const scopes = fwView.getByRole("radiogroup", { name: "Gelen ağ" }).getByRole("radio");
    await scopes.first().waitFor();
    assert.deepEqual(await scopes.allInnerTexts(), ["İnternet", "Tailscale", "WireGuard", "Yalnız bu sunucu"]);
    assert.equal(await fwView.getByTestId("fw-check").count(), 0, "a passing check says nothing");
    assert.equal(await fwView.locator(".tech-table, .listen-table").count(), 0, "the technical rules are Gelişmiş's");
    assert.equal(await fwView.getByTestId("fw-technical").getAttribute("href"), "#/gelismis?sekme=guvenlik-duvari");
    const fwRows = () => fwView.locator(".fw-table tbody tr");
    assert.deepEqual(await fwRows().evaluateAll((trs) => trs.map((t) => t.dataset.port)), ["tcp/22", "udp/61001", "tcp/8096"], "İnternet · IPv4");
    assert.deepEqual(await fwView.locator(".fw-table thead th").allInnerTexts(), ["Hizmet", "Port", "Kaynak", "İzin", "Eylemler"]);
    const ssh = fwView.locator('tr[data-port="tcp/22"]');
    assert.equal(await ssh.locator('td[data-label="Port"]').innerText(), "22/tcp");
    assert.equal(await ssh.getByTestId("rule-origin").innerText(), "Temel");
    assert.equal(await ssh.getByRole("switch").getAttribute("aria-checked"), "true");
    const fixed = fwView.locator('tr[data-port="tcp/8096"]');
    assert.equal(await fixed.getByRole("switch").count(), 0, "an application's raw port is locked");
    assert.equal(await fixed.getByTestId("fw-row-link").innerText(), "Adresler'de yönet");
    assert.equal(await fixed.getByTestId("fw-row-link").getAttribute("href"), `#/erisim?sekme=adresler&satir=${enc(MEDYA)}`, "it links to its access row");
    assert.equal(await fixed.getByTestId("rule-origin").innerText(), "Adresler");
    await noStyles(page, "erisim guvenlik-duvari");
    await shot(page, "1440-light-erisim-guvenlik.png", true);
    // A baseline port turned off: the switch writes the operator's rule for it.
    await ssh.getByRole("switch").click();
    assert.equal(await ssh.getByRole("switch").getAttribute("aria-checked"), "false");
    assert.equal(await ssh.getByTestId("rule-origin").innerText(), "Taslak\nYeni kural");
    await page.getByTestId("fw-draft").filter({ hasText: "1 değişiklik kaydedilmedi" }).waitFor();
    assert.equal(await guarded(page), true, "a firewall draft asks before the tab closes");
    // "Port kuralı": checked before it joins the draft.
    await fwView.getByTestId("add-rule").click();
    sheet = page.getByRole("dialog", { name: "Port kuralı ekle" });
    await sheet.waitFor();
    assert.equal(await sheet.getByLabel("Ağ", { exact: true }).inputValue(), "wan", "the chosen network");
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
    assert.equal(await game.getByTestId("rule-origin").innerText(), "Taslak\nYeni kural");
    assert.equal(await game.getByRole("button", { name: "Oyun kuralını düzenle" }).count(), 1);
    await page.getByTestId("fw-draft").filter({ hasText: "2 değişiklik kaydedilmedi" }).waitFor();
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
    await scopes.filter({ hasText: "Tailscale" }).click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("kapsam") === "tailscale");
    assert.deepEqual(await fwRows().evaluateAll((trs) => trs.map((t) => t.dataset.port)), ["tcp/80", "udp/53", "tcp/8443", "tcp/8097"]);
    const tsPort = fwView.locator('tr[data-port="tcp/8443"]');
    assert.equal(await tsPort.getByRole("switch").count(), 0, "a Tailscale port (K5) is locked");
    assert.equal(await tsPort.getByTestId("fw-row-link").getAttribute("href"), `#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`);
    assert.equal(await fwView.locator('tr[data-kural="u_medya"]').getByTestId("rule-origin").innerText(), "Elle");
    await scopes.filter({ hasText: "WireGuard" }).click();
    assert.equal(await fwView.locator(".meter-note").first().innerText(),
      "WireGuard cihazları yalnız internete çıkar; sunucu servisleri, özel ağlar ve diğer cihazlar engellenir. Bu politika değiştirilemez.");
    assert.deepEqual(await fwView.getByTestId("fw-wireguard").locator("li").allInnerTexts(), ["wg0 · Ana ağ · açık"]);
    assert.equal(await fwView.getByTestId("add-rule").count(), 0, "no rule for WireGuard devices");
    await scopes.filter({ hasText: "Yalnız bu sunucu" }).click();
    const lo = fwView.locator('tr[data-port="tcp/62001"]');
    assert.equal(await lo.getByRole("switch").count(), 0);
    assert.match(await lo.innerText(), /Korunur/);
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
    await scopes.filter({ hasText: "İnternet" }).click();
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
    // Without a WireGuard network its scope is not offered; an old address falls back to İnternet. A failing check says so.
    data["guvenlik-duvari"] = firewall({ aglar: [], denetim: { ok: false, metin: "Güvenlik duvarı kuralları beklenenden farklı; Sistem → Sağlık'tan onarın." } });
    page = await newPage();
    await page.goto(url("#/erisim?sekme=guvenlik-duvari&kapsam=wireguard"));
    const noNets = page.getByTestId("firewall");
    await noNets.locator(".fw-table").waitFor();
    assert.deepEqual(await noNets.getByRole("radiogroup", { name: "Gelen ağ" }).getByRole("radio").allInnerTexts(), ["İnternet", "Tailscale", "Yalnız bu sunucu"]);
    assert.equal(await noNets.getByRole("radio", { name: "İnternet" }).getAttribute("aria-checked"), "true");
    assert.equal(await noNets.getByTestId("fw-check").innerText(), "Güvenlik duvarı kuralları beklenenden farklı; Sistem → Sağlık'tan onarın.");
    await shot(page, "1440-light-erisim-guvenlik-wg-yok.png");
    await page.context().close();
    data["guvenlik-duvari"] = firewall();
    // A locked row's link opens its access row's panel in Adresler.
    page = await newPage();
    await page.goto(url("#/erisim?sekme=guvenlik-duvari"));
    await page.getByTestId("firewall").locator('tr[data-port="tcp/8096"]').getByTestId("fw-row-link").click();
    await page.waitForURL((u) => u.hash === `#/erisim?sekme=adresler&satir=${enc(MEDYA)}`);
    await rowSheet(page).getByTestId("row-form").waitFor();
    assert.equal(await rowSheet(page).locator("h3").innerText(), "medya · web");
    await page.context().close();

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

    // ================= the palette: Erişim's tabs; no Yayınla action
    page = await newPage();
    await page.goto(url("#/erisim"));
    await page.getByTestId("matrix").waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    const input = palette.getByRole("combobox");
    await input.fill("yayınla");
    assert.equal(await palette.locator('[data-key="yayinla"]').count(), 0, "no Yayınla action");
    await input.fill("dnsmasq");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Erişim → Yerel adlar", "Gelişmiş → DNS"], "names are changed in Erişim, read in Gelişmiş");
    await input.fill("doğrudan port");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(),
      ["Erişim", "Erişim → Adresler", "medya · 8096/TCP", "medya · 1900/UDP", "kutu · 9000/TCP", "Adres aç"], "each raw port by its application and port");
    await input.fill("dnsmasq");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=adlar");
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes: no style attribute, no horizontal scroll
    const VIEWS = [["genel", "#/erisim", "[data-testid=matrix]"], ["adresler", "#/erisim?sekme=adresler", "[data-testid=raw-rows] tbody tr"],
      ["adlar", "#/erisim?sekme=adlar", "[data-testid=names] tbody tr"], ["guvenlik", "#/erisim?sekme=guvenlik-duvari", ".fw-table"]];
    for (const colorScheme of ["light", "dark"]) {
      page = await newPage({ colorScheme });
      for (const [name, hash, ready] of VIEWS) {
        await page.goto(url(hash));
        await page.locator(ready).first().waitFor();
        await noStyles(page, `1440 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `1440 ${colorScheme} ${name}`);
        await shot(page, `1440-${colorScheme}-${name}.png`, true);
      }
      await page.goto(url(`#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`));
      await rowSheet(page).getByTestId("row-form").waitFor();
      await shot(page, `1440-${colorScheme}-satir.png`);
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
      await page.goto(url("#/erisim?sekme=adresler"));
      await page.getByTestId("access-rows").locator(`tr[data-satir="${NOTLAR}"]`).waitFor();
      assert.equal(await page.getByTestId("access-rows").locator("tbody tr").first().evaluate((el) => getComputedStyle(el).display), "grid", "access rows as cards");
      assert.equal(await page.getByTestId("raw-rows").locator("tbody tr").first().evaluate((el) => getComputedStyle(el).display), "grid", "raw ports as cards");
      for (const [id, shotName, setup] of [[NOTLAR, "satir-adres", null], [MEDYA_UDP, "satir-ham", "internet"], ["panel", "satir-konsol", "konsol"]]) {
        await page.goto(url(`#/erisim?sekme=adresler&satir=${enc(id)}`));
        sheet = rowSheet(page);
        await sheet.getByTestId("row-form").waitFor();
        if (setup === "internet") await sheet.locator('[data-kapsam="internet"]').tap();
        if (setup === "konsol") {
          await sheet.getByRole("switch", { name: "İnternet adı" }).tap();
          await sheet.getByTestId("row-host").fill("konsol.example.org");
        }
        if (id === NOTLAR) {
          const [card, panel] = await Promise.all([page.locator(`tr[data-satir="${NOTLAR}"]`).boundingBox(), sheet.boundingBox()]);
          assert(panel.y >= card.y + card.height - 1 && panel.x >= card.x && panel.x + panel.width <= card.x + card.width + 1 && panel.width >= 0.9 * card.width,
            "on a phone the panel is under its card, nearly as wide");
          assert(await noHorizontalScroll(page), "390 panel");
        }
        await noStyles(page, `390 ${colorScheme} ${shotName}`);
        await shot(page, `390-${colorScheme}-${shotName}.png`);
      }
      await page.goto(url(`#/erisim?sekme=adresler&satir=${enc(KUTU)}`));
      sheet = rowSheet(page);
      await sheet.getByTestId("row-form").waitFor();
      await sheet.locator('[data-kapsam="tailscale"]').tap();
      await sheet.getByTestId("review").tap();
      await sheet.getByTestId("plan").waitFor();
      await noStyles(page, `390 ${colorScheme} satir-plan`);
      await shot(page, `390-${colorScheme}-satir-plan.png`);
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      await shot(page, `320-${colorScheme}-satir-plan.png`);
      for (const [name, hash, ready] of VIEWS) {
        await page.goto(url(hash));
        await page.locator(ready).first().waitFor();
        await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        await noStyles(page, `320 ${colorScheme} ${name}`);
        assert(await noHorizontalScroll(page), `320 ${colorScheme} ${name}`);
        await shot(page, `320-${colorScheme}-${name}.png`, true);
      }
      await page.goto(url(`#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`));
      await rowSheet(page).getByTestId("row-form").waitFor();
      await shot(page, `320-${colorScheme}-satir-adres.png`);
      await page.context().close();
    }

    assert.equal(count("yayinlar") + count("yayinlar/plan"), 0, "nothing asks for the removed Yayınla routes");
    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol Erişim under the production CSP — Genel (summaries, the matrix with each cell's addresses and ports and no sentence, " +
      "each access row's link, an unreadable Erişim), Genel Bakış' links by duzelt (an access row's panel, the application, Tailscale) and the chip, " +
      "Tailscale (device, addresses, client, key expiry warning, exit node, admin console link, disconnected), Adresler (addresses with their " +
      "Tailscale name, Tailscale port, internet name and state; raw ports with their scope; Adres aç from the tab bar with another port chosen in " +
      "the panel), the access row panel under its own row, one at a time (Ayrıntı opens and closes it, another row's moves it, Esc closes it and " +
      "the focus returns; facts, name checks, a rename as an opening with the 60 s banner and Onayla, a long apply that stays busy " +
      "and counts, the table's switches: a closing straight to its plan with Geri to the form, an opening with its field focused; a refused apply, " +
      "Adresi kaldır from the panel and the Tailscale name's switch; raw scopes from the table (Tailscale planned at once, the internet with the " +
      "consent as internet_onayi, Kapalı), internet → Tailscale at once; Adres aç with a Tailscale port and an internet name; Konsol's internet " +
      "name with the typed word; Paylaşımlar' Tailscale name; deep links and a missing row), Yerel adlar (owners, the managed names read-only " +
      "with their row and no switch, the records' draft → plan → apply with exact bodies, a refused plan, the local domain: plan, 300 s, confirmation only from the new address, rollback), " +
      "Güvenlik duvarı (scopes, the base's ports with rules, locked rows linking to Adresler, a baseline switch and a new rule, checks, IPv6, " +
      "WireGuard only with networks, a failing check, Teknik kurallar to Gelişmiş, plan → apply → 60 s → Onayla and Geri al, a plan that cannot be " +
      "applied), the leave guard on the DNS, domain and firewall drafts, the stuck rollback (retry, typed discard), a refused confirmation, the " +
      "internet channel's confirmation message, Yayınla gone, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
