/* Konsol's new interface, phase 2 (DD-258): Genel Bakış, Uygulamalar and an application's page in the
   committed build under Data/console/yeni, with the production CSP and fixture replies for every endpoint
   they read or post to (yeni-harness.cjs). Fails on any console error, CSP violation or page error. Never
   contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulamalar-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737 addresses, example names); shapes as in api/sema.ts
const cell = (durum, adresler = [], uyari = "", not = "") => ({ durum, adresler, uyari, not });
const hcell = (durum, adresler = [], not = "", uyari = "") => ({ durum, adresler, not, uyari });
const app = (o) => ({ modul: null, konteyner: null, simge: null, durum: "calisiyor", islem: null, tailscale: cell("yok"), internet: cell("yok"),
  kaynak: { cpu: null, bellek: null }, guncelleme: "sabit", adres: { tailscale: null, internet: null }, sayfa: null, eylemler: [], revizyon: null,
  metinler: null, hesap: false, ...o });
// A package's own stop and removal words (its konsol.json), as App Store shows them.
const TORRENT_TEXTS = { durdur: "Süren indirmeler duraklar; başlatınca kaldığı yerden devam eder.",
  kaldir: [["box", "Konteyner durur ve açılışta başlamaz; imaj sunucuda kalır."], ["lock", "torrent.ev adı kalkar."]],
  veri_etiket: "Profili, torrent listesini ve imajı da sil", veri_kalir: "indirilenler /srv/indirilenler altında kalır; profil korunur.",
  veri_silinir: "Profil, torrent listesi ve konteyner imajı da silinir." };
const VPN_NOTE = "WireGuard cihazları yalnız internete çıkar; bu sunucudaki hizmetlere ulaşamaz.";
const OK_CHECKS = [
  { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" },
  { id: "caddy", name: "Caddy", status: "ok", detail: "çalışıyor" },
  { id: "dns", name: "DNS", status: "ok", detail: "yanıt veriyor" }];
const BAD_CHECK = { id: "units", name: "2 eski konteyner birimi başarısız", status: "bad", detail: "konsol-filebrowser ve konsol-gezgin-deneme her açılışta hata veriyor." };
const WARNING = { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda okunabilir.",
  duzelt: { bolum: "yayinlar", hedef: "paylasim" } };

function apps() {
  return [
    app({ id: "paket:gezgin", ad: "Gezgin", tur: "paket", aciklama: "Sunucudaki dosyalarınızı tarayıcıdan yönetin.", modul: "gezgin", konteyner: "gezgin", simge: "folder",
      tailscale: cell("acik", ["gezgin.ev"]), internet: cell("acik", ["gezgin.example.com"]), guncelleme: "bilinmiyor",
      adres: { tailscale: "http://gezgin.ev", internet: "https://gezgin.example.com" }, eylemler: ["durdur", "yeniden-baslat", "kaldir"], revizyon: "rev-gezgin-1" }),
    app({ id: "paket:torrent", ad: "qBittorrent", tur: "paket", aciklama: "Torrent indirmelerini yönetin.", modul: "torrent", konteyner: "torrent", simge: "download", hesap: true,
      tailscale: cell("acik", ["torrent.ev"]), internet: cell("kismen", ["203.0.113.10:63851/tcp+udp"], "", "Yalnız qBittorrent eş portu"),
      kaynak: { cpu: 3.2, bellek: 220200960 }, guncelleme: "yeni", adres: { tailscale: "http://torrent.ev", internet: null }, sayfa: "#/torrent",
      eylemler: ["durdur", "yeniden-baslat", "guncelle", "kaldir"], revizyon: "rev-torrent-7", metinler: TORRENT_TEXTS }),
    app({ id: "paket:wireguard", ad: "WireGuard", tur: "paket", aciklama: "Cihazlarınız için VPN bağlantısı.", modul: "wireguard", simge: "shield", sayfa: "#/wireguard",
      eylemler: ["durdur", "yeniden-baslat", "kaldir"] }),
    app({ id: "konteyner:notlar", ad: "notlar", tur: "konteyner", aciklama: "Konteyner · docker.io/library/nginx", konteyner: "notlar", durum: "durduruldu",
      tailscale: cell("kapali"), internet: cell("kapali"), guncelleme: "guncel", sayfa: "#/konteynerler/notlar", eylemler: ["baslat", "kaldir"] }),
    app({ id: "yerlesik:dosya", ad: "Dosyalar", tur: "yerlesik", aciklama: "Dosya yöneticisi · yerleşik", sayfa: "#/dosyalar" }),
    app({ id: "yerlesik:paylasim", ad: "Paylaşımlar", tur: "yerlesik", aciklama: "WebDAV · yerleşik · 2 klasör", tailscale: cell("acik", ["paylas.ev"], "", "2 klasör"),
      internet: cell("acik", ["http://203.0.113.10:61010"], "Şifresiz HTTP", "1 klasör"), sayfa: "#/dosyalar/paylasim" }),
  ];
}

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-244", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, interval: 10, read_at: 1791845000, sampled_at: 1791845000, cpu: [1.0, 2.0], mem: { total: 8375186227, used: 696254464, graph: [8.0] },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "bad", read_at: 1791844900, checks: [BAD_CHECK, ...OK_CHECKS] },
  guncelleme: { kurulu: "2026.08.06-v2-244", kurulu_surum: "1.0.0", son: "2026.08.06-v2-244", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false,
    denetlendi: 1791845000, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: 1791845000, alan: "ev", hizmetler: [], hatalar: [], uyarilar: [WARNING],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null }, internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] },
      wireguard: { kurulu: true, not: VPN_NOTE, aglar: [] }, sertifikalar: [] } },
  uygulamalar: { read_at: 1791845000, hatalar: [], katalog: [], altyapi: { podman: "5.4.2", calisiyor: true, imaj: 3, kullanilmayan_imaj: 1, birim: 2, ag: 3 }, items: apps() },
  ag: { read_at: 1791845000, iface: "eth0", window: 600, sampled_at: 1791845000, rx: 10240, tx: 38912, points: [],
    apps: [{ id: "torrent", name: "qBittorrent", state: "calisiyor", down: 932184064, up: 75497472, since: 1791000000, at: null },
      { id: "wireguard", name: "WireGuard", state: "calisiyor", down: 5368709120, up: 291504128, since: 1790000000, at: null }] },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
};

const row = (id, ad, tur, cells, ayrinti = []) => ({ id, ad, tur, aciklama: "Uygulama", uygulama: null, calisiyor: true, yerel: hcell("yok"), tailscale: hcell("yok"),
  wireguard: hcell("kapali", [], VPN_NOTE), internet: hcell("yok"), yayinlar: [], ayrinti, ...cells });
const box = (o) => ({ imaj: "", ag: "", kullanici: "", baslangic: null, saglik: "", yeniden_baslama: 0, portlar: [], baglamalar: [], ...o });
const ACCESS = {
  "paket:torrent": row("paket:torrent", "qBittorrent", "paket", { yerel: hcell("acik", ["127.0.0.1:62947 → 8080/tcp"]), tailscale: hcell("acik", ["torrent.ev"]),
    internet: hcell("kismen", ["203.0.113.10:63851/tcp+udp"], "Yalnız qBittorrent eş portu") },
  [{ baslik: "Konteyner portu", deger: "127.0.0.1:62947 → 8080/tcp" }, { baslik: "DNS", deger: "torrent.ev → 100.64.0.2" }]),
  "paket:gezgin": row("paket:gezgin", "Gezgin", "paket", { yerel: hcell("acik", ["127.0.0.1:8093"]), tailscale: hcell("acik", ["gezgin.ev"]), internet: hcell("acik", ["gezgin.example.com"]) },
    [{ baslik: "Caddy", deger: "gezgin.example.com → 127.0.0.1:8093" }]),
  "konteyner:notlar": row("konteyner:notlar", "notlar", "konteyner", { yerel: hcell("kapali"), tailscale: hcell("kapali"), internet: hcell("kapali") }),
  "yerlesik:paylasim": row("paylasim", "Paylaşımlar", "paylasim", { tailscale: hcell("acik", ["paylas.ev"], "2 klasör"),
    internet: hcell("acik", ["http://203.0.113.10:61010"], "1 klasör", "Şifresiz HTTP") }, [{ baslik: "Klasör · Filmler", deger: "Tailscale açık · İnternet açık" }]),
};
const BOXES = {
  "paket:torrent": box({ imaj: "lscr.io/linuxserver/qbittorrent@sha256:" + "a".repeat(64), ag: "torrent", kullanici: "1000:1000", baslangic: 1791800000, saglik: "healthy",
    yeniden_baslama: 2, portlar: [{ host_ip: "127.0.0.1", host_port: 62947, container_port: 8080, protocol: "tcp", scope: "local" }],
    baglamalar: [{ tur: "bind", kaynak: "/srv/indirilenler", hedef: "/downloads", yazilabilir: true, ad: "" },
      { tur: "bind", kaynak: "/srv/kitaplik", hedef: "/library", yazilabilir: false, ad: "" },
      { tur: "volume", kaynak: "/var/lib/containers/storage/volumes/torrent-config/_data", hedef: "/config", yazilabilir: true, ad: "torrent-config" }] }),
  "paket:gezgin": box({ imaj: "ghcr.io/example/gezgin@sha256:" + "b".repeat(64), ag: "gezgin", kullanici: "1000:1000", baslangic: 1791700000,
    baglamalar: [{ tur: "bind", kaynak: "/srv", hedef: "/srv", yazilabilir: true, ad: "" }, { tur: "volume", kaynak: "/v/gezgin-db", hedef: "/db", yazilabilir: true, ad: "gezgin-db" }] }),
  "konteyner:notlar": box({ imaj: "docker.io/library/nginx@sha256:" + "c".repeat(64), ag: "konsol" }),
};
// Phase 4a: the application page reads its container's own detail (konteynerler/ayrinti), Uygulamalar reads
// Podman's counts (konteynerler/liste), Ayarlar the package list, its account and its settings form's values;
// yeni-uygulama-ekle-ui.cjs covers them, here they only have to answer.
const crow = (o) => ({ id: "", image: "", state: "running", unit: "", network: "", ports: [], started: null, restarts: 0, health: "", live: true, source: "konsol",
  module_id: null, revision: null, actions: [], restricted_reason: "", cpu_percent: null, memory_bytes: null, busy: null, listening: null, update: null, ...o });
const CONTAINERS = {
  torrent: crow({ name: "torrent", id: "a1b2c3d4e5f6", image: "lscr.io/linuxserver/qbittorrent@sha256:" + "a".repeat(64), unit: "torrent.service", network: "torrent",
    source: "appstore", module_id: "torrent", revision: "rev-torrent-7", health: "healthy", actions: ["stop", "restart", "remove", "image-update", "save"],
    ports: [{ host_ip: "127.0.0.1", host_port: 62947, container_port: 8080, protocol: "tcp", scope: "local" }],
    update: { state: "var", channel: "lscr.io/linuxserver/qbittorrent:latest", error: "", checked_at: 1791844000 },
    config: { listener_port: 62947, peer_port: 63851, save: "/srv/indirilenler/torrent" }, editable: ["listener_port", "peer_port", "save"], protected_mounts: [],
    effective_autostart: true, user: "1000:1000", command: "" }),
  gezgin: crow({ name: "gezgin", id: "b2c3d4e5f6a1", image: "ghcr.io/example/gezgin@sha256:" + "b".repeat(64), unit: "gezgin.service", network: "gezgin", source: "appstore",
    module_id: "gezgin", revision: "rev-gezgin-1", actions: ["stop", "restart", "remove", "image-update"], config: { listener_port: 62983 }, editable: [], protected_mounts: [],
    effective_autostart: true, user: "1000:1000", command: "" }),
  notlar: crow({ name: "notlar", image: "docker.io/library/nginx@sha256:" + "c".repeat(64), state: "stopped", live: false, unit: "konsol-notlar.service", network: "konsol",
    actions: ["start", "save", "remove", "image-update"], revision: "rev-notlar-1",
    config: { name: "notlar", image: "docker.io/library/nginx@sha256:" + "c".repeat(64), image_ref: "docker.io/library/nginx:1.27-alpine", network: "bridge", ports: [], mounts: [],
      environment: [], command: [], autostart: true, manual_stop: false, restart: "on-failure", cpus: "", memory: "", user: "downloads" },
    editable: ["ports", "mounts", "environment", "command", "autostart", "restart", "cpus", "memory", "image", "network", "user"], protected_mounts: [], effective_autostart: true,
    user: "", command: "" }),
};
const PACKAGES = [
  { id: "torrent", runtime: "konteyner", installed: true, state: "calisiyor", live: "running", busy: false, progress: null, durdurulabilir: true,
    konsol: { ad: "qBittorrent", alt: "Torrent indirmelerini yönetin.", simge: "download", form: { ayar_baslik: "qBittorrent ayarları", oku: "/durum", yaz: "/ayar",
      alanlar: [{ ad: "username", tur: "metin", etiket: "Kullanıcı adı" }, { ad: "password", tur: "parola", etiket: "Parola", en_az: 8 },
        { ad: "save", tur: "klasor", etiket: "İndirme klasörü" }] } } },
  { id: "gezgin", runtime: "konteyner", installed: true, state: "calisiyor", live: "running", busy: false, progress: null, durdurulabilir: true,
    konsol: { ad: "Gezgin", alt: "Sunucudaki dosyalarınızı tarayıcıdan yönetin.", simge: "folder", form: { alanlar: [{ ad: "username", tur: "metin", etiket: "Kullanıcı adı" }] } } },
];
const LOG = Array.from({ length: 30 }, (_, i) => `2026-10-13T01:${String(10 + i).padStart(2, "0")}:00+03:00 torrent[812]: satır ${i + 1}`);
const BUSY = "Bir uygulama işlemi sürüyor; bitince yeniden deneyin.";

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-uygulamalar-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8769", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, count, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies
h.handlers["/api/konsol/konteynerler/ayrinti"] = ({ query }) => (CONTAINERS[query.get("ad")] ? { body: CONTAINERS[query.get("ad")] } : { status: 404, body: { error: "Konteyner bulunamadı" } });
h.handlers["/api/konsol/konteynerler/liste"] = () => ({ body: { read_at: 1791845000, runtime: { version: "5.4.2", ok: true, error: "" }, containers: Object.values(CONTAINERS),
  images: [], volumes: [], networks: [], storage: { images: 3, containers: 3, size: 1610612736 }, resource_errors: {} } });
h.handlers["/api/konsol/konteynerler/islem"] = ({ method, query }) => (method === "GET"
  ? { body: { id: query.get("id"), action: "image-update", name: "torrent", state: "done", step: "", result: { changed: true, version: "5.1.2" } } } : undefined);
h.handlers["/api/konsol/moduller"] = () => ({ body: { items: PACKAGES } });
h.handlers["/api/konsol/uygulamalar/hesap"] = ({ query }) => (query.get("id") === "paket:torrent"
  ? { body: { user: "admin", temp: false, host: "torrent.ev" } } : { status: 404, body: { error: "bu modülde hesap yok" } });
h.dynamic.push([/^\/api\/uygulama\/torrent\/durum$/, () => ({ body: { username: "admin", save: "/srv/indirilenler/torrent" } })]);
h.handlers["/api/konsol/uygulamalar/ayrinti"] = ({ query }) => {
  const id = query.get("id");
  const item = data.uygulamalar.items.find((a) => a.id === id);
  if (!item) return { status: 404, body: { error: "Uygulama bulunamadı." } };
  return { body: { uygulama: item, konteyner: BOXES[id] ?? null, erisim: ACCESS[id] ?? null } };
};
h.handlers["/api/konsol/uygulamalar/gunluk"] = ({ query }) => (query.get("id").startsWith("yerlesik:")
  ? { status: 404, body: { error: "Yerleşik uygulamaların günlüğü Ayarlar → Günlük bölümündedir." } }
  : { body: { satirlar: LOG, kesik: true } });
const islemReplies = [];  // replies for the next POSTs, before the default 202
let jobSeq = 0;
h.handlers["/api/konsol/uygulamalar/islem"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const forced = islemReplies.shift();
  if (forced) return forced;
  // Containers and image updates go to the container broker, which names its job; a package's engine does not.
  const broker = body.id.startsWith("konteyner:") || body.eylem === "guncelle";
  return { status: 202, body: { id: body.id, eylem: body.eylem, is: broker ? `is-${++jobSeq}` : null } };
};
const onarimReplies = [];
h.handlers["/api/konsol/onarim"] = ({ method }) => (method === "POST" ? onarimReplies.shift() ?? { status: 202, body: { kip: "onar" } } : undefined);

// ---- helpers
const url = (hash) => new URL("/yeni/" + hash, base).href;
const hashOf = (page) => page.evaluate(() => location.hash);
const active = (page) => page.evaluate(() => {
  const e = document.activeElement;
  return e ? (e.getAttribute("aria-label") || e.textContent || "").trim().replace(/\s+/g, " ") : "";
});
const rowNames = (page) => page.locator(".app-table tbody .app-name").allInnerTexts();
const lastPost = (key) => posts(key).at(-1);
const job = (o) => ({ tur: "modul", id: "torrent", ad: "qBittorrent · İşlem", durum: "calisiyor", adim: "", bitis: null, ...o });
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
    // Applications: every one but Files, which has its own section.
    await page.locator(".app-card").first().waitFor();
    assert.deepEqual(await page.locator(".app-card").evaluateAll((els) => els.map((e) => e.dataset.uygulama)),
      ["paket:gezgin", "paket:torrent", "paket:wireguard", "konteyner:notlar", "yerlesik:paylasim"]);
    assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (5)");
    assert.equal(await page.getByTestId("all-apps").getAttribute("href"), "#/uygulamalar");
    const card = (id) => page.locator(`.app-card[data-uygulama="${id}"]`);
    const open = card("paket:gezgin").getByRole("link", { name: "Gezgin uygulamasını yeni sekmede aç" });
    assert.deepEqual([await open.getAttribute("href"), await open.getAttribute("target"), await open.getAttribute("rel")], ["http://gezgin.ev", "_blank", "noopener noreferrer"]);
    assert.equal(await card("paket:gezgin").locator(".pill").innerText(), "Çalışıyor");
    assert.equal(await card("paket:gezgin").getByRole("link", { name: "Gezgin ayrıntıları" }).getAttribute("href"), "#/uygulamalar/paket:gezgin");
    assert.equal(await card("paket:torrent").locator(".app-line").innerText(), "torrent.ev · internette kısmen açık · yeni sürüm var");
    assert.equal(await card("paket:wireguard").locator('[data-eylem="ac"]').count(), 0, "nothing to open");
    assert.equal(await card("paket:wireguard").locator(".app-line").innerText(), "Cihazlarınız için VPN bağlantısı.");
    assert.equal(await card("konteyner:notlar").locator(".pill").innerText(), "Durdurulmuş");
    const shares = card("yerlesik:paylasim").locator('[data-eylem="ac"]');
    assert.deepEqual([await shares.getAttribute("href"), await shares.getAttribute("target")], ["/#/dosyalar/paylasim", null], "a built-in opens its page in the current interface");
    assert.equal(await card("yerlesik:paylasim").locator(".app-line").innerText(), "paylas.ev · internette açık · Şifresiz HTTP");
    // Resources, network and the server.
    assert.equal(await page.getByTestId("cpu").innerText(), "%2");
    assert.equal(await page.getByTestId("memory").innerText(), "664 MB / 7,8 GB");
    assert.equal(await page.getByTestId("disk").innerText(), "12,7 GB / 250,7 GB");
    await page.getByTestId("rx").filter({ hasText: "10 KB/s" }).waitFor();
    assert.equal(await page.getByTestId("tx").innerText(), "38 KB/s");
    assert.deepEqual(await page.locator(".net-list li").allInnerTexts(), ["qBittorrent\n↓ 889 MB · ↑ 72 MB", "WireGuard\n↓ 5,0 GB · ↑ 278 MB"]);
    assert.equal(await page.getByTestId("network").locator(".pill").innerText(), "Canlı");
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
    await page.locator('.sidebar [data-nav="uygulamalar"]').click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.clock.runFor(15000);
    await page.waitForTimeout(150);
    assert.equal(count("ag"), n0 + 3, "no reads on another page");
    await page.context().close();

    // ================= the palette lists the applications and opens their pages
    page = await newPage();
    await page.goto(url("#/genel"));
    await page.locator(".app-card").first().waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.waitFor();
    assert.deepEqual(await palette.locator('[aria-labelledby="palet-grup-1"] .palette-label').allInnerTexts(), ["Gezgin", "qBittorrent", "WireGuard", "notlar", "Paylaşımlar"]);
    await palette.getByRole("combobox").fill("qbit");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent");
    await page.locator("main h1").filter({ hasText: "qBittorrent" }).waitFor();
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
    assert.deepEqual(await rowNames(page), ["Gezgin", "qBittorrent", "WireGuard", "notlar", "Paylaşımlar"]);
    assert(await page.locator(".app-table thead").isVisible(), "a table on a wide screen");
    const tr = (id) => page.locator(`tr[data-uygulama="${id}"]`);
    const chipsOf = (id) => tr(id).locator(".access-chip").evaluateAll((els) => els.map((e) => [e.querySelector(".access-text").textContent, e.className.replace("access-chip ", "")]));
    assert.equal(await tr("paket:torrent").locator(".col-state").innerText(), "Çalışıyor");
    assert.deepEqual(await chipsOf("paket:torrent"), [["Tailscale", "chip-tone-ok"], ["İnternet · kısmen", "chip-tone-accent"]]);
    assert.equal(await tr("paket:torrent").locator(".col-res").innerText(), "%3 · 210 MB");
    assert.equal(await tr("paket:torrent").locator(".col-ver").innerText(), "Yeni sürüm");
    assert.equal(await tr("paket:torrent").locator('[data-eylem="ac"]').getAttribute("href"), "http://torrent.ev");
    assert.deepEqual(await chipsOf("yerlesik:paylasim"), [["Tailscale", "chip-tone-ok"], ["İnternet · Şifresiz HTTP", "chip-tone-warning"]]);
    assert.equal(await tr("yerlesik:paylasim").locator('[data-eylem="ac"]').getAttribute("href"), "/#/dosyalar/paylasim");
    assert.equal(await tr("konteyner:notlar").locator(".col-state").innerText(), "Durdurulmuş");
    assert.deepEqual(await chipsOf("konteyner:notlar"), [["Tailscale kapalı", "chip-tone-neutral"], ["İnternet kapalı", "chip-tone-neutral"]]);
    assert.equal(await tr("konteyner:notlar").locator(".col-ver").innerText(), "Güncel");
    assert.equal(await tr("konteyner:notlar").locator('[data-eylem="ac"]').count(), 0);
    assert.equal(await tr("paket:gezgin").locator(".col-ver").innerText(), "—", "not checked yet: nothing shown, not an error");
    assert.equal(await tr("paket:gezgin").locator(".col-res").innerText(), "—", "unknown resources");
    assert.equal(await tr("paket:wireguard").locator(".col-access").innerText(), "—", "no cell applies");
    assert.equal(await tr("paket:wireguard").getByRole("link", { name: "WireGuard ayrıntıları" }).getAttribute("href"), "#/uygulamalar/paket:wireguard");
    await noStyles(page, "uygulamalar");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-uygulamalar.png", true);

    await chips.filter({ hasText: "Dikkat" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=dikkat");
    assert.deepEqual(await rowNames(page), ["qBittorrent", "Paylaşımlar"], "a newer image or a warning on how it is reached");
    assert.equal(await chips.filter({ hasText: "Dikkat" }).getAttribute("aria-pressed"), "true");
    await chips.filter({ hasText: "Durdurulmuş" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=durmus");
    assert.deepEqual(await rowNames(page), ["notlar"]);
    await chips.filter({ hasText: "Çalışan" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar?suzgec=calisan");
    assert.deepEqual(await rowNames(page), ["Gezgin", "qBittorrent", "WireGuard", "Paylaşımlar"]);
    await chips.filter({ hasText: "Tümü" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    // Turkish case rules: "DOSYALARINIZI" is "dosyalarınızı" (a plain toLowerCase would give "dosyalarinizi").
    const search = page.getByRole("searchbox", { name: "Uygulama ara" });
    await search.fill("DOSYALARINIZI");
    await page.waitForURL((u) => u.hash === "#/uygulamalar?ara=DOSYALARINIZI");
    assert.deepEqual(await rowNames(page), ["Gezgin"]);
    await search.fill("İNDİRMELERİNİ");
    assert.deepEqual(await rowNames(page), ["qBittorrent"]);
    await page.getByRole("status").filter({ hasText: "1 uygulama gösteriliyor" }).waitFor();
    // The view comes back from the address.
    await page.goto(url("#/uygulamalar?suzgec=dikkat&ara=payla%C5%9F"));
    await page.reload();
    await page.locator(".app-table").waitFor();
    assert.equal(await search.inputValue(), "paylaş");
    assert.equal(await chips.filter({ hasText: "Dikkat" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await rowNames(page), ["Paylaşımlar"]);
    await page.goto(url("#/uygulamalar?suzgec=durmus&ara=gezgin"));
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
    data.uygulamalar = { ...data.uygulamalar, items: apps() };
    // Adding an application, the infrastructure, and errors from the read model.
    await page.goto(url("#/uygulamalar"));
    await page.reload();
    const add = page.getByTestId("add-app");
    await add.getByText("Katalogdaki uygulamaların hepsi kurulu.").waitFor();
    // Since phase 4a the add flows open over this page (yeni-uygulama-ekle-ui.cjs drives them).
    assert.equal(await add.getByRole("link", { name: "Kataloğu aç" }).getAttribute("href"), "#/uygulamalar?ekle=katalog");
    assert.equal(await add.locator('[data-secenek="imaj"] a').getAttribute("href"), "#/uygulamalar?ekle=imaj");
    assert.equal(await add.locator('[data-secenek="benimse"] a').getAttribute("href"), "#/uygulamalar?ekle=sahiplen");
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
    assert.equal(await active(page), "Gezgin");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "Gezgin uygulamasını yeni sekmede aç");
    await page.keyboard.press("Tab");
    assert.equal(await active(page), "Gezgin ayrıntıları");
    data.uygulamalar = { ...data.uygulamalar, hatalar: ["Podman kullanılamıyor."], katalog: [{ id: "ornek", ad: "Örnek", aciklama: "Deneme paketi.", simge: null }] };
    await page.reload();
    await page.getByTestId("app-errors").getByText("Podman kullanılamıyor.").waitFor();
    assert.equal(await page.getByTestId("app-errors").getByRole("heading").innerText(), "Bazı bilgiler okunamadı");
    await add.getByText("1 uygulama kurulabilir.").waitFor();
    assert.equal(await add.getByRole("link", { name: "Örnek" }).getAttribute("href"), "#/uygulamalar?ekle=katalog&paket=ornek");
    await shot(page, "1440-light-uygulamalar-hatalar.png", true);
    data.uygulamalar = { ...data.uygulamalar, hatalar: [], katalog: [] };

    // ================= an application's page
    await page.reload();
    await page.locator(".app-table").waitFor();
    await tr("paket:torrent").getByRole("link", { name: "qBittorrent", exact: true }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent");
    await page.locator("main h1").filter({ hasText: "qBittorrent" }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the new page's heading has focus");
    assert.equal(await page.title(), "qBittorrent · Konsol");
    const trail = page.getByRole("navigation", { name: "Konum" });
    assert.equal(await trail.getByRole("link", { name: "Uygulamalar" }).getAttribute("href"), "#/uygulamalar");
    assert.equal(await trail.locator('[aria-current="page"]').innerText(), "qBittorrent");
    assert.equal(await page.locator('.sidebar [data-nav="uygulamalar"]').getAttribute("aria-current"), "true", "the section of the page");
    assert.equal(await page.getByTestId("app-state").innerText(), "Çalışıyor");
    await page.getByTestId("app-desc").filter({ hasText: "Torrent indirmelerini yönetin · App Store paketi · yeni sürüm var" }).waitFor();
    const actions = () => page.getByTestId("app-actions").locator("[data-eylem]").evaluateAll((els) => els.map((e) => e.dataset.eylem));
    assert.deepEqual(await actions(), ["ac", "yeniden-baslat", "durdur", "guncelle", "kaldir"]);
    const appOpen = page.getByTestId("app-actions").locator('[data-eylem="ac"]');
    assert.deepEqual([await appOpen.getAttribute("href"), await appOpen.getAttribute("target")], ["http://torrent.ev", "_blank"]);
    // Özet.
    const tabs = page.getByRole("tablist", { name: "qBittorrent bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Özet", "Erişim", "Depolama", "Ayarlar", "Günlük"]);
    assert.deepEqual(await tabs.evaluateAll((els) => els.map((e) => [e.getAttribute("aria-selected"), e.tabIndex])),
      [["true", 0], ["false", -1], ["false", -1], ["false", -1], ["false", -1]], "one tab stop");
    await page.getByTestId("started").filter({ hasText: dateTime(1791800000) }).waitFor();
    assert.equal(await page.getByTestId("app-health").innerText(), "Sağlıklı");
    assert.equal(await page.getByTestId("restarts").innerText(), "2");
    assert.equal(await page.getByTestId("account").innerText(), "1000:1000");
    assert.equal(await page.getByTestId("app-version").innerText(), "Yeni sürüm");
    assert.equal(await page.getByTestId("summary-state").getByText(/^lscr\.io/).innerText(), "lscr.io/linuxserver/qbittorrent@sha256:aaaaaaaaaaaa…");
    assert.equal(await page.locator('[data-erisim="internet"] .cell-value').innerText(), "203.0.113.10:63851/tcp+udp · Yalnız qBittorrent eş portu");
    assert.equal(await page.getByTestId("app-cpu").innerText(), "%3");
    assert.equal(await page.getByTestId("app-memory").innerText(), "210 MB");
    await noStyles(page, "uygulama");
    await shot(page, "1440-light-uygulama-ozet.png", true);
    // Arrow keys move and choose; the address follows.
    await tabs.first().focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=erisim");
    assert.equal(await active(page), "Erişim");
    await page.keyboard.press("End");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=gunluk");
    assert.equal(await active(page), "Günlük");
    await page.keyboard.press("Home");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent");
    assert.equal(await active(page), "Özet");
    await page.keyboard.press("ArrowLeft");
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=gunluk");
    assert.equal(await tabs.filter({ hasText: "Günlük" }).getAttribute("aria-selected"), "true");
    await tabs.filter({ hasText: "Özet" }).click();
    await page.getByTestId("summary-access").getByRole("button", { name: "Erişim ayrıntısı" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=erisim");
    // Erişim.
    const access = page.getByTestId("access");
    assert.deepEqual(await access.locator(".access-row strong").allInnerTexts(), ["Bu sunucu", "Tailscale", "WireGuard", "İnternet"]);
    assert.deepEqual(await access.locator(".access-row .pill").allInnerTexts(), ["Açık", "Açık", "Kapalı", "Kısmen"]);
    assert.equal(await access.locator('[data-hucre="wireguard"] .access-note').innerText(), VPN_NOTE);
    assert.equal(await access.locator('[data-hucre="internet"] .access-note').innerText(), "Yalnız qBittorrent eş portu");
    const technical = access.locator("details.technical");
    assert.equal(await technical.evaluate((d) => d.open), false);
    await technical.locator("summary").click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=erisim&teknik=1");
    assert.deepEqual(await technical.locator("dd").allInnerTexts(), ["127.0.0.1:62947 → 8080/tcp", "torrent.ev → 100.64.0.2"]);
    // Since phase 3 it opens the Yayınla flow over this page (yeni-erisim-ui.cjs drives the flow).
    assert.equal(await access.getByRole("button", { name: "Erişimi düzenle" }).count(), 1);
    await shot(page, "1440-light-uygulama-erisim.png", true);
    await page.reload();
    await access.locator(".access-row").first().waitFor();
    assert.equal(await tabs.filter({ hasText: "Erişim" }).getAttribute("aria-selected"), "true", "the tab comes back from the address");
    assert.equal(await technical.evaluate((d) => d.open), true, "and the open details too");
    // Depolama, Ayarlar.
    await tabs.filter({ hasText: "Depolama" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=depolama&teknik=1");
    assert.deepEqual(await page.getByTestId("folders").locator(".mount").allInnerTexts(),
      ["/srv/indirilenler\nOkuma-yazma · konteynerde /downloads", "/srv/kitaplik\nSalt okunur · konteynerde /library"]);
    assert.equal(await page.getByTestId("save-folder").innerText(), "Kayıt klasörü /srv/indirilenler/torrent; uygulamanın ayarıdır, Ayarlar'dan değişir.", "phase 4a");
    assert.deepEqual(await page.getByTestId("volumes").locator(".mount").allInnerTexts(), ["torrent-config\nOkuma-yazma · konteynerde /config"]);
    // Since phase 4a the settings are here (yeni-uygulama-ekle-ui.cjs drives them).
    await tabs.filter({ hasText: "Ayarlar" }).click();
    await page.getByTestId("adapter").waitFor();
    await page.getByTestId("package-settings").waitFor();
    await page.getByTestId("account-card").getByTestId("account-user").filter({ hasText: "admin" }).waitFor();
    assert.equal(await page.getByTestId("settings-link").count(), 0, "no link to the current interface's page");
    // Günlük.
    const logReads = count("uygulamalar/gunluk");
    await tabs.filter({ hasText: "Günlük" }).click();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByTestId("log-lines").locator("li").count(), 30);
    assert.equal(await page.getByTestId("log-lines").locator("li").first().innerText(), LOG[0]);
    await page.getByText("Yalnız son 200 satır gösteriliyor.").waitFor();
    assert.equal(count("uygulamalar/gunluk"), logReads + 1);
    assert.equal(h.requests.filter((r) => r.path === "/api/konsol/uygulamalar/gunluk").at(-1).query, "?id=paket%3Atorrent&satir=200");
    await page.getByRole("button", { name: "Yenile" }).click();
    await waitFor(() => count("uygulamalar/gunluk") === logReads + 2, "Yenile reads the log again");
    assert.equal(await page.getByTestId("live-switch").getAttribute("aria-checked"), "false");
    await shot(page, "1440-light-uygulama-gunluk.png", true);

    // Actions: each POST body exactly; a 202 shows in the activity drawer and its end reads the page again.
    await tabs.filter({ hasText: "Özet" }).click();
    const detailReads = () => count("uygulamalar/ayrinti");
    const button = (eylem) => page.getByTestId("app-actions").locator(`[data-eylem="${eylem}"]`);
    await button("yeniden-baslat").click();
    await waitFor(() => posts("uygulamalar/islem").length === 1, "restart posted");
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "paket:torrent", eylem: "yeniden-baslat", revizyon: "rev-torrent-7" });
    await page.getByTestId("action-note").filter({ hasText: "Yeniden başlatılıyor; ilerlemesi İşlemler'de görünür." }).waitFor();
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("islemler", { items: [job({ ad: "qBittorrent · Yeniden başlat", adim: "Adım 1/2 · Durduruluyor" })] });
    await page.getByRole("button", { name: "İşlemler, 1 çalışıyor" }).click();
    const drawer = page.getByRole("dialog", { name: "İşlemler" });
    assert.equal(await drawer.locator(".job-name").innerText(), "qBittorrent · Yeniden başlat");
    await page.keyboard.press("Escape");
    await drawer.waitFor({ state: "detached" });
    await page.waitForTimeout(200);
    const before = detailReads();
    push("islemler", { items: [job({ ad: "qBittorrent · Yeniden başlat", durum: "tamam", bitis: 1791845300 })] });
    await waitFor(() => detailReads() > before, "the application is read again when its job ends");
    await page.waitForFunction(() => document.querySelector('[data-testid="action-note"]').textContent === "", null, { timeout: 5000 });

    // Durdur asks first; Esc keeps it running and gives the focus back.
    await button("durdur").click();
    const stopDialog = page.getByRole("dialog", { name: "qBittorrent durdurulsun mu?" });
    await stopDialog.waitFor();
    assert.equal(await active(page), "Vazgeç");
    assert.equal(await stopDialog.locator(".modal-desc").innerText(), "Kurulu kalır; istediğinizde başlatırsınız.");
    assert.deepEqual(await stopDialog.locator(".modal-list li").allInnerTexts(),
      [TORRENT_TEXTS.durdur, "Açılışta da kapalı kalır; başlatılana kadar çalışmaz."], "the package's own stop note first");
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
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "paket:torrent", eylem: "durdur", revizyon: "rev-torrent-7" });
    // A direct action's error shows on the page.
    islemReplies.push({ status: 409, body: { error: BUSY } });
    await button("yeniden-baslat").click();
    await page.getByTestId("action-error").filter({ hasText: BUSY }).waitFor();
    assert.equal(await page.getByTestId("action-error").getAttribute("role"), "alert");
    // Güncelle: the container broker names the job; its end reads the page again.
    await button("guncelle").click();
    const updateDialog = page.getByRole("dialog", { name: "qBittorrent güncellensin mi?" });
    await updateDialog.waitFor();
    await updateDialog.getByRole("button", { name: "Güncelle" }).click();
    await updateDialog.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "paket:torrent", eylem: "guncelle", revizyon: "rev-torrent-7" });
    const brokerJob = `is-${jobSeq}`;
    push("islemler", { items: [job({ tur: "konteyner", id: brokerJob, ad: "torrent · İmaj güncelleme", adim: "İmaj indiriliyor" })] });
    await page.waitForTimeout(200);
    const beforeUpdate = detailReads();
    push("islemler", { items: [job({ tur: "konteyner", id: brokerJob, ad: "torrent · İmaj güncelleme", durum: "tamam", bitis: 1791845400 })] });
    await waitFor(() => detailReads() > beforeUpdate, "read again when the broker's job ends");
    // Kaldır: a sheet, the typed word, and the data choice of a package.
    await button("kaldir").click();
    const removeSheet = page.getByRole("dialog", { name: "qBittorrent kaldırılsın mı?" });
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
    // The package's own words: what goes, the data switch's label, what it deletes and what stays.
    assert.deepEqual(await removeSheet.locator(".modal-list li").allInnerTexts(),
      [...TORRENT_TEXTS.kaldir.map((p) => p[1]), "Kullanıcı alanındaki dosyalarınıza dokunulmaz."]);
    assert.equal(await removeSheet.locator(".modal-list li svg").count(), 3, "an unknown icon name falls back to a known one");
    assert.equal(await removeSheet.getByTestId("remove-data").locator("small").innerText(),
      `${TORRENT_TEXTS.veri_silinir} İşaretlemezseniz: ${TORRENT_TEXTS.veri_kalir}`);
    await removeSheet.getByRole("checkbox", { name: TORRENT_TEXTS.veri_etiket }).check();
    await shot(page, "1440-light-uygulama-kaldir.png");
    await removeButton.click();
    await removeSheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "paket:torrent", eylem: "kaldir", revizyon: "rev-torrent-7", veri: true });
    await page.context().close();
    expectedFailures = [];

    // ================= a Konsol container: no revision, no data choice; gone after its removal
    page = await newPage();
    await page.goto(url("#/uygulamalar/konteyner:notlar"));
    await page.locator("main h1").filter({ hasText: "notlar" }).waitFor();
    await page.getByTestId("app-state").filter({ hasText: "Durdurulmuş" }).waitFor();
    assert.deepEqual(await actions(), ["baslat", "imaj-guncelle", "kaldir"], "its image can be pulled again (phase 4a)");
    await button("baslat").click();
    await waitFor(() => lastPost("uygulamalar/islem")?.eylem === "baslat", "start posted");
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:notlar", eylem: "baslat" }, "no revizyon when it is null");
    await button("kaldir").click();
    const removeBox = page.getByRole("dialog", { name: "notlar kaldırılsın mı?" });
    await removeBox.waitFor();
    assert.equal(await removeBox.getByTestId("remove-data").count(), 0, "only a package's data can be removed with it");
    await removeBox.getByRole("textbox").fill("onayla");
    await removeBox.locator('[data-onay="kaldir"]').click();
    await removeBox.waitFor({ state: "detached" });
    assert.deepEqual(lastPost("uygulamalar/islem"), { id: "konteyner:notlar", eylem: "kaldir", veri: false });
    expectedFailures = ["/api/konsol/uygulamalar/ayrinti"];
    data.uygulamalar = { ...data.uygulamalar, items: data.uygulamalar.items.filter((a) => a.id !== "konteyner:notlar") };
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("islemler", { items: [job({ tur: "konteyner", id: `is-${jobSeq}`, ad: "notlar · Kaldır" })] });
    await page.waitForTimeout(200);
    push("islemler", { items: [job({ tur: "konteyner", id: `is-${jobSeq}`, ad: "notlar · Kaldır", durum: "tamam", bitis: 1791845500 })] });
    await page.getByText("Bu uygulama yok").waitFor();
    assert.equal(await page.getByText("Uygulama bulunamadı.").count(), 1, "the backend's words");
    assert.equal(await page.getByRole("link", { name: "Uygulamalar'a dön" }).getAttribute("href"), "#/uygulamalar");
    await page.context().close();
    data.uygulamalar = { ...data.uygulamalar, items: apps() };

    // A package that names no removal words gets the general ones.
    page = await newPage();
    await page.goto(url("#/uygulamalar/paket:wireguard"));
    await page.locator("main h1").filter({ hasText: "WireGuard" }).waitFor();
    await button("kaldir").click();
    const plainSheet = page.getByRole("dialog", { name: "WireGuard kaldırılsın mı?" });
    await plainSheet.waitFor();
    await plainSheet.getByRole("checkbox", { name: "Verilerini de sil" }).waitFor();
    assert.deepEqual(await plainSheet.locator(".modal-list li").allInnerTexts(),
      ["Uygulama durur ve kaldırılır; sayfası ve açtığı adresler gider.", "Kullanıcı alanındaki dosyalarınıza dokunulmaz."]);
    await page.keyboard.press("Escape");
    await plainSheet.waitFor({ state: "detached" });
    await page.context().close();

    // ================= Gezgin, a package without a Konsol page; built-ins; an unknown id
    page = await newPage();
    await page.goto(url("#/uygulamalar/paket:gezgin"));
    await page.locator("main h1").filter({ hasText: "Gezgin" }).waitFor();
    await page.getByTestId("app-actions").waitFor();
    assert.deepEqual(await actions(), ["ac", "yeniden-baslat", "durdur", "imaj-guncelle", "kaldir"]);
    assert.deepEqual([await button("ac").getAttribute("href"), await button("ac").getAttribute("target")], ["http://gezgin.ev", "_blank"]);
    await page.getByTestId("started").waitFor();
    assert.equal(await page.getByTestId("app-version").count(), 0, "an image not checked yet shows no version line");
    assert.equal(await page.getByTestId("app-health").innerText(), "Denetim tanımlı değil");
    assert.deepEqual([await page.getByTestId("app-cpu").innerText(), await page.getByTestId("app-memory").innerText()], ["—", "—"], "unknown resources");
    await page.getByText("Kaynak kullanımı şu an okunamıyor.").waitFor();
    expectedFailures = ["/api/konsol/uygulamalar/hesap"];  // a package without an account answers 404
    await page.getByRole("tab", { name: "Ayarlar" }).click();
    await page.getByText("Bu uygulamanın ayrı bir ayar sayfası yok").waitFor();
    expectedFailures = [];

    await page.goto(url("#/uygulamalar/yerlesik:paylasim"));
    await page.locator("main h1").filter({ hasText: "Paylaşımlar" }).waitFor();
    await page.getByTestId("app-actions").waitFor();
    assert.deepEqual(await actions(), ["ac"], "a built-in is not stopped or removed here");
    assert.deepEqual([await button("ac").getAttribute("href"), await button("ac").getAttribute("target")], ["/#/dosyalar/paylasim", null]);
    assert.equal(await page.getByTestId("summary-resources").count(), 0, "no resources without a container");
    await page.getByRole("tab", { name: "Erişim" }).click();
    const shareInternet = page.locator('[data-hucre="internet"]');
    await shareInternet.waitFor();
    assert.match(await shareInternet.locator(".pill").getAttribute("class"), /pill-warning/);
    assert.equal(await shareInternet.locator(".warn-text").innerText(), "Şifresiz HTTP");
    expectedFailures = ["/api/konsol/uygulamalar/gunluk"];
    await page.getByRole("tab", { name: "Günlük" }).click();
    await page.getByTestId("log-error").filter({ hasText: "Yerleşik uygulamaların günlüğü Ayarlar → Günlük bölümündedir." }).waitFor();
    assert.equal(await page.getByRole("link", { name: "Sistem → Günlük" }).getAttribute("href"), "#/sistem?sekme=gunluk");
    await page.goto(url("#/uygulamalar/yerlesik:dosya"));
    await page.locator("main h1").filter({ hasText: "Dosyalar" }).waitFor();
    await page.getByTestId("app-actions").waitFor();
    assert.equal(await button("ac").getAttribute("href"), "/#/dosyalar");
    await page.goto(url("#/uygulamalar/paket:wireguard?sekme=erisim"));
    await page.getByText("Bu uygulamanın yayınladığı bir adres yok").waitFor();
    await page.getByRole("tab", { name: "Depolama" }).click();
    await page.getByText("Bu uygulama bir konteynerde çalışmıyor").waitFor();
    expectedFailures = ["/api/konsol/uygulamalar/ayrinti"];
    await page.goto(url("#/uygulamalar/paket:yok"));
    await page.getByText("Bu uygulama yok").waitFor();
    assert.equal(await page.getByText("Uygulama bulunamadı.").count(), 1);
    await page.context().close();
    expectedFailures = [];

    // ================= the live log switch: every 5 s while on, from the address too
    page = await newPage({}, { clock: true });
    await page.goto(url("#/uygulamalar/paket:torrent?sekme=gunluk"));
    await page.getByTestId("log-lines").waitFor();
    await page.waitForTimeout(100);
    const l0 = count("uygulamalar/gunluk");
    await page.clock.runFor(10000);
    await page.waitForTimeout(150);
    assert.equal(count("uygulamalar/gunluk"), l0, "no reads while Canlı is off");
    const liveSwitch = page.getByRole("switch", { name: "Canlı" });
    await liveSwitch.click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=gunluk&canli=1");
    assert.equal(await liveSwitch.getAttribute("aria-checked"), "true");
    await page.clock.runFor(5000);
    await waitFor(() => count("uygulamalar/gunluk") === l0 + 1, "read after 5 s");
    await page.clock.runFor(5000);
    await waitFor(() => count("uygulamalar/gunluk") === l0 + 2, "and after 10 s");
    await liveSwitch.click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent?sekme=gunluk");
    await page.clock.runFor(15000);
    await page.waitForTimeout(150);
    assert.equal(count("uygulamalar/gunluk"), l0 + 2, "off again: no more reads");
    await page.goto(url("#/uygulamalar/paket:torrent?sekme=gunluk&canli=1"));
    await page.reload();
    await page.getByTestId("log-lines").waitFor();
    assert.equal(await page.getByRole("switch", { name: "Canlı" }).getAttribute("aria-checked"), "true", "on from the address");
    await page.context().close();

    // ================= over HTTPS (the public name) "Aç" leads to the internet address
    expectedFailures = ["/api/konsol/olaylar"];
    page = await h.newHttpsPage("konsol.example.test");
    await page.goto("https://konsol.example.test/yeni/#/genel");
    await page.locator(".app-card").first().waitFor();
    assert.equal(await page.locator('.app-card[data-uygulama="paket:gezgin"] [data-eylem="ac"]').getAttribute("href"), "https://gezgin.example.com");
    assert.equal(await page.locator('.app-card[data-uygulama="paket:torrent"] [data-eylem="ac"]').getAttribute("href"), "http://torrent.ev",
      "without an internet name the tailnet one is offered");
    await page.context().close();
    expectedFailures = [];

    // ================= 1440, 390 and 320 in both themes
    for (const colorScheme of ["light", "dark"]) {
      page = await newPage({ colorScheme });
      for (const [name, hash] of [["genel", "#/genel"], ["uygulamalar", "#/uygulamalar"], ["uygulama", "#/uygulamalar/paket:torrent"]]) {
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
      const tile = page.locator('.app-card[data-uygulama="paket:torrent"]');
      const tileBox = await tile.boundingBox();
      await tile.tap({ position: { x: tileBox.width - 14, y: 14 } });
      await page.waitForURL((u) => u.hash === "#/uygulamalar/paket:torrent");
      await page.getByTestId("summary-state").waitFor();
      assert.equal(await page.getByRole("navigation", { name: "Alt menü" }).getByRole("link", { name: "Uygulamalar" }).getAttribute("aria-current"), "true");
      assert(await noHorizontalScroll(page), "390 uygulama");
      await shot(page, `390-${colorScheme}-uygulama.png`, true);
      await page.getByTestId("app-actions").locator('[data-eylem="kaldir"]').tap();
      const sheet = page.getByRole("dialog", { name: "qBittorrent kaldırılsın mı?" });
      await sheet.waitFor();
      const sheetBox = await sheet.boundingBox();
      assert(Math.abs(sheetBox.y + sheetBox.height - 844) <= 1 && sheetBox.width === 390, "a bottom sheet on a phone");
      await shot(page, `390-${colorScheme}-kaldir.png`);
      await sheet.getByRole("button", { name: "Kapat" }).tap();
      await sheet.waitFor({ state: "detached" });
      await page.goto(url("#/uygulamalar"));
      await page.locator(".app-table").waitFor();
      assert.equal(await page.locator('tr[data-uygulama="paket:torrent"]').evaluate((el) => getComputedStyle(el).display), "grid", "cards on a phone");
      assert.equal(await page.locator(".app-table thead").evaluate((el) => getComputedStyle(el).position), "absolute", "column heads only for screen readers");
      assert.equal(await page.locator('tr[data-uygulama="paket:torrent"] .col-state').evaluate((el) => getComputedStyle(el, "::before").content), '"Durum"');
      await noStyles(page, `390 ${colorScheme} uygulamalar`);
      assert(await noHorizontalScroll(page), "390 uygulamalar");
      await shot(page, `390-${colorScheme}-uygulamalar.png`, true);
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      for (const [name, hash] of [["uygulamalar", "#/uygulamalar"], ["genel", "#/genel"], ["uygulama", "#/uygulamalar/paket:torrent?sekme=erisim"]]) {
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
    console.log("PASS: /yeni/ phase 2 under the production CSP — Genel Bakış (problems with their fix, repair confirmation, POST {kip:onar}, error, " +
      "running and ended repair, calm state, locked repair with its reason, apps without Files, Aç over HTTP and HTTPS, resources, network, server), " +
      "network reads every 5 s only while shown and visible, palette opens application pages, Uygulamalar (summary, filter chips with counts, " +
      "Turkish-aware search, URL state and reload, empty states, add panel, infrastructure, errors, keyboard order and focus ring), application " +
      "page (trail, heading focus, tabs with arrow keys and URL, Erişim with technical details in the URL, Depolama, Ayarlar, Günlük with Yenile " +
      "and the Canlı switch), exact POST bodies (yeniden-baslat, durdur, guncelle, kaldir with veri true/false, baslat without revizyon), " +
      "dialog focus trap, Esc and focus return, typed confirmation, error replies, jobs in the drawer and their end reading the page again, " +
      "a removed application, built-ins, Gezgin, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
