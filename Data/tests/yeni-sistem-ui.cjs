/* Konsol's Sistem and Gelişmiş (DD-258, DD-266; rebuild phase 5, A7 and K8): Sistem (Sağlık with "Denetle ve onar"
   and its Onarım kaydı, Güncellemeler with the applications' image updates, Hesap, Sunucu with the reboot, İşlem
   geçmişi with every audit kind in words; no Görünüm) and Gelişmiş (Caddy, DNS, the firewall's technical rules and
   listeners, Podman's inventory read-only and its cleanup as a job) in the committed build under
   Data/console/yeni, with the production CSP and fixture replies for every endpoint they read or post to
   (yeni-harness.cjs), on the tailnet and on the internet channel. Also the shell's "Çıkış yap" and the
   palette's entries. Fails on any console error, CSP violation or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-sistem-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737/6598 addresses, example names); shapes as in api/sema.ts
const NOW = 1791845000;
const DAY = 86400;
const HEX = (c) => c.repeat(32);
const { uygulama, uygulamalar } = require("./yeni-harness.cjs").fixtures;

const CHECKS = [
  { id: "firewall", name: "Güvenlik duvarı", status: "ok", detail: "Kurallar beklendiği gibi" },
  { id: "units", name: "Servisler", status: "bad", detail: "Çalışmayan: master-files-panel.service" },
  { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor · 100.64.0.2" },
  { id: "disk", name: "Disk", status: "warn", detail: "/srv %91 dolu" },
];
const STEPS = [
  { id: "firewall", ad: "Güvenlik duvarı", durum: "ok", detay: "Kurallar yerinde" },
  { id: "units", ad: "Servisler", durum: "onarildi", detay: "Yeniden başlatıldı: master-files-panel.service" },
  { id: "tailscale", ad: "Tailscale", durum: "sorun", detay: "Durum: NeedsLogin; giriş gerekiyorsa sunucuda: sudo tailscale up" },
  { id: "ssh", ad: "SSH", durum: "atlandi", detay: "ssh.service kurulu değil" },
];
const REPORT = { durum: "tamam", kip: "onar", kaynak: "terminal", baslangic: NOW - 3 * 3600, bitis: NOW - 3 * 3600 + 40, adimlar: STEPS };
const repairState = (o = {}) => ({ calisiyor: false, kurulu: true, baslatilabilir: true, rapor: JSON.parse(JSON.stringify(REPORT)), ...o });
const update = (o = {}) => ({ kurulu: "2026.08.06-v2-248", kurulu_surum: "1.1.0", son: "2026.10.12-v2-252", son_surum: "1.2.0", commit: "abcdef1" + "0".repeat(33),
  yeni: true, denetlendi: NOW - 3600, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true,
  uygulamalar: { sayi: 1, adlar: ["notlar"], denetlendi: NOW - 600 }, ...o });
const LOG72 = Array.from({ length: 80 }, (_, i) => `2026-10-13T0${Math.floor(i / 20)}:${String(i % 60).padStart(2, "0")}:00+03:00 master-onar[9${i}]: adım ${i + 1} tamam`).join("\n") + "\n";
const LOG7 = "2026-10-07T03:10:00+03:00 refresh-tailnet-config[401]: adres değişmedi\n2026-10-08T03:12:00+03:00 master-onar[402]: güvenlik duvarı denetlendi\n";

// Every kind the backends write (master-panel, master_wireguard, master_settings.audit_detail, the file backends), with
// their real details: WireGuard's device lines ("wg0/telefon", "wg0/telefon 25"), the settings actions naming an access
// row or a WireGuard action, an application's verbs, the cleanup's kinds, the files' paths.
const ROW = "uygulama:notlar:web:8080/tcp";
const AUDIT = [
  { at: NOW - 60, source: "panel", user: "konsol", client: "100.64.0.5", action: "onarim", detail: "onar", ok: true },
  { at: NOW - 300, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-apply", detail: "wireguard durdur", ok: true },
  { at: NOW - 400, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-confirm", detail: "wireguard ag-ac wg0", ok: true },
  { at: NOW - 500, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-apply", detail: "wireguard ag-ekle UDP 51821", ok: true },
  { at: NOW - 600, source: "panel", user: "konsol", client: "100.64.0.5", action: "wireguard-ekle", detail: "wg0/telefon", ok: true },
  { at: NOW - 750, source: "panel", user: "konsol", client: "100.64.0.5", action: "wireguard-keepalive", detail: "wg0/telefon 25", ok: true },
  { at: NOW - 900, source: "panel", user: "konsol", client: "100.64.0.5", action: "wireguard-peer-durum", detail: "wg0/telefon kapatıldı", ok: true },
  { at: NOW - 950, source: "panel", user: "konsol", client: "100.64.0.5", action: "wireguard-ag-ayarlar", detail: "wg0", ok: true },
  { at: NOW - 1000, source: "panel", user: "konsol", client: "100.64.0.5", action: "wireguard-qr", detail: "wg0/telefon", ok: true },
  { at: NOW - 1050, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-apply", detail: `erisim ${ROW} adres notlar tailscale-portu kapali internet notlar.example.org`, ok: true },
  { at: NOW - 1100, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-rollback", detail: `erisim ${ROW}`, ok: true },
  { at: NOW - 1150, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-apply", detail: "erisim uygulama:ornek:app:9000/udp ham internet 9001", ok: true },
  { at: NOW - 1200, source: "panel", user: "konsol", client: "100.64.0.5", action: "temizlik", detail: "imaj cccccccccccc; ağ eski-ag; klasör eskiuygulama", ok: true },
  { at: NOW - 1300, source: "panel", user: "konsol", client: "100.64.0.5", action: "uygulama-taslak", detail: "imaj registry.example/ornek:1", ok: true },
  { at: NOW - 1400, source: "panel", user: "konsol", client: "100.64.0.5", action: "uygulama-kur", detail: "ornek", ok: true },
  { at: NOW - 1500, source: "panel", user: "konsol", client: "100.64.0.5", action: "uygulama-guncelle", detail: "ornek", ok: true },
  { at: NOW - 1600, source: "panel", user: "konsol", client: "100.64.0.5", action: "uygulama-kaldir", detail: "notlar (veri: sakla)", ok: true },
  { at: NOW - 1700, source: "dosya", user: "dosyalar", client: "100.64.0.6", action: "yükle", detail: "Filmler/kayit.mkv", ok: true },
  { at: NOW - 1800, source: "dosya", user: "dosyalar", client: "100.64.0.6", action: "klasor", detail: "Filmler", ok: true },
  { at: NOW - 1900, source: "dosya", user: "root", client: "100.64.0.6", action: "sil", detail: "etc ['eski.conf']", ok: true },
  { at: NOW - 2000, source: "panel", user: "konsol", client: "100.64.0.5", action: "giris", detail: "-", ok: true },
  { at: NOW - 2100, source: "panel", user: "konsol", client: "203.0.113.50", action: "parola-degis", detail: "-", ok: false },
  { at: NOW - 2400, source: "panel", user: "konsol", client: "100.64.0.5", action: "ayar-confirm", detail: "ayarlar", ok: true },
  { at: NOW - 2500, source: "panel", user: "konsol", client: "100.64.0.5", action: "guncelleme", detail: "2026.10.12-v2-252", ok: true },
  { at: NOW - 2700, source: "panel", user: "konsol", client: "100.64.0.5", action: "yeniden-baslat", detail: "5 sn", ok: true },
  { at: NOW - 2 * DAY, source: "panel", user: "konsol", client: "100.64.0.5", action: "paylasim-save", detail: "klasör paylaşımı", ok: true },
];
const AUDIT_LINES = [
  "Denetim ve onarım başlatıldı", "WireGuard'ı kapat · uygulandı", "wg0 ağını aç · onaylandı", "WireGuard ağı ekle (UDP 51821) · uygulandı",
  "wg0/telefon cihazı eklendi", "wg0/telefon cihazının canlı tutma süresi: 25 sn", "wg0/telefon cihazı kapatıldı",
  "wg0 ağının adı ve varsayılan DNS'i güncellendi", "wg0/telefon QR kodu görüntülendi",
  "Erişim değişikliği · notlar · web 8080/TCP (Tailscale adı notlar, Tailscale portu kapalı, internet adı notlar.example.org) · uygulandı",
  "Erişim değişikliği · notlar · web 8080/TCP · geri alındı",
  "Erişim değişikliği · ornek · app 9000/UDP (doğrudan port, internet, sunucu portu 9001) · uygulandı",
  "Podman temizliği istendi (imaj cccccccccccc; ağ eski-ag; klasör eskiuygulama)", "Taslak dosya istendi: imaj registry.example/ornek:1",
  "Uygulama kurulumu istendi: ornek", "Uygulama imaj güncellemesi istendi: ornek", "Uygulama kaldırma istendi: notlar (veriler saklanır)",
  "Yüklendi: Filmler/kayit.mkv", "Yeni klasör: Filmler", "Kalıcı silindi (Sistem dosyaları): etc ['eski.conf']", "Konsol girişi",
  "Konsol parolası değiştirildi — başarısız", "Güvenlik duvarı, yerel adlar ya da alan adı değişikliği · onaylandı",
  "Obhut güncellemesi başlatıldı: 2026.10.12-v2-252", "Sunucunun yeniden başlatılması istendi (5 sn)", "Klasör paylaşımı kaydedildi",
];

const CADDYFILE = "{\n\tadmin off\n}\nhttp://panel.ev {\n\treverse_proxy 127.0.0.1:62000\n}\n";
const ADVANCED = {
  read_at: NOW,
  caddy: {
    entries: [
      { address: "panel.ev", routes: [{ path: "/api/*", kind: "proxy", to: "unix//run/master-panel/api.sock" }, { path: "", kind: "files", to: "" }], source: "base", access: "tailscale", scheme: "http" },
      { address: "100.64.0.2:61010", routes: [{ path: "", kind: "proxy", to: "127.0.0.1:61011" }], source: "base", access: "tailscale", scheme: "http" },
      { address: "paylas.ev", routes: [{ path: "", kind: "proxy", to: "127.0.0.1:61010" }], source: "paylasim", access: "tailscale", scheme: "http" },
      { address: "notlar.ev", routes: [{ path: "", kind: "proxy", to: "127.0.0.1:62100" }], source: "uygulama-notlar", access: "tailscale", scheme: "http" },
      { address: "notlar.example.org", routes: [{ path: "", kind: "proxy", to: "127.0.0.1:62100" }], source: "uygulama-notlar-wan", access: "wan", scheme: "https" },
      { address: "konsol.example.org", routes: [{ path: "/api/*", kind: "proxy", to: "unix//run/master-panel/api.sock" }, { path: "", kind: "files", to: "" }], source: "panel-wan", access: "wan", scheme: "https" },
      { address: "203.0.113.10:61010", routes: [{ path: "", kind: "respond", to: "yalnız WebDAV" }], source: "paylasim-wan", access: "wan", scheme: "http" },
    ],
    raw: [{ file: "/etc/caddy/Caddyfile", text: CADDYFILE }, { file: "/etc/caddy/moduller/uygulama-notlar.caddy", text: "http://notlar.ev {\n\treverse_proxy 127.0.0.1:62100\n}\n" }],
  },
  dnsmasq: {
    listen: ["tailscale0", "lo"], domains: ["ev"], dhcp: false,
    names: [{ name: "panel.ev", iface: "tailscale0", family: 4, address: "100.64.0.2", source: "base" },
      { name: "notlar.ev", iface: "tailscale0", family: null, address: "100.64.0.2, fd7a:115c:a1e0::2", source: "uygulama" },
      { name: "yazici.ev", iface: "", family: 4, address: "192.0.2.40", source: "base" }],
    raw: [{ file: "/etc/dnsmasq.d/master-stack.conf", text: "interface=tailscale0\nlocal=/ev/\ninterface-name=panel.ev,tailscale0/4\n" },
      { file: "/etc/dnsmasq.d/modul-uygulama.conf", text: "interface-name=notlar.ev,tailscale0\n" }],
  },
};
const ID = (c) => c.repeat(64);
const resources = (o = {}) => ({
  read_at: NOW, runtime: { version: "5.4.2", ok: true, error: "" }, containers: [],
  images: [
    { id: ID("a"), name: "quay.io/example/yedekci@sha256:" + ID("1"), size: 214958080, created: NOW - 30 * DAY, used_by: [], managed: false },
    { id: ID("b"), name: "docker.io/library/nginx:1.27", size: 196083712, created: NOW - 10 * DAY, used_by: ["notlar"], managed: true },
    { id: ID("c"), name: "docker.io/library/redis:7.4", size: 41943040, created: NOW - 2 * DAY, used_by: [], managed: true },
  ],
  volumes: [
    { name: "notlar-veri", driver: "local", size: null, used_by: ["notlar"], managed: false },
    { name: "ornek-veri", driver: "local", size: null, used_by: [], managed: true },
    { name: "eski", driver: "local", size: null, used_by: [], managed: false },
  ],
  networks: [
    { name: "podman", id: ID("d"), driver: "bridge", subnets: ["10.88.0.0/16"], used_by: [], managed: false, internal: false },
    { name: "konsol", id: ID("e"), driver: "bridge", subnets: ["10.89.0.0/24"], used_by: ["notlar"], managed: true, internal: false },
    { name: "kapali-ag", id: ID("f"), driver: "bridge", subnets: ["10.89.7.0/24"], used_by: [], managed: true, internal: true },
  ],
  storage: { images: 3, containers: 2, size: 452984832 }, resource_errors: {}, ...o,
});

// Gelişmiş → Güvenlik duvarı: the technical rules and the listeners (GET /api/konsol/guvenlik-duvari).
const FIREWALL = {
  revizyon: "rev-1", denetim: { ok: true, metin: "Güvenlik duvarı kuralları beklendiği gibi." }, kurallar: [], portlar: [], aglar: [], hatalar: [],
  dinleyiciler: [
    { proto: "tcp", aile: 4, port: 22, adres: "0.0.0.0", kapsam: "any" },
    { proto: "tcp", aile: 4, port: 80, adres: "100.64.0.2", kapsam: "tail" },
    { proto: "tcp", aile: 4, port: 62001, adres: "127.0.0.1", kapsam: "lo" },
    { proto: "tcp", aile: 6, port: 80, adres: "fd7a:115c:a1e0::2", kapsam: "tail" }],
  teknik: [
    { aile: 4, tablo: "filter", zincir: "MASTER-INPUT", sira: "1", paket: 12345, bayt: 6789012, kural: "-A MASTER-INPUT -i lo -j ACCEPT", sahip: "Obhut" },
    { aile: 4, tablo: "filter", zincir: "ts-input", sira: "1", paket: 10, bayt: 900, kural: "-A ts-input -j RETURN", sahip: "Tailscale" },
    { aile: 6, tablo: "filter", zincir: "MASTER-INPUT", sira: "1", paket: 7, bayt: 560, kural: "-A MASTER-INPUT -i lo -j ACCEPT", sahip: "Obhut" }],
};
// Gelişmiş → Podman's cleanup (GET /api/konsol/gelismis/temizlik): what nothing uses and the unmanaged containers.
const DATA_DIR = "/var/lib/master-stack/uygulamalar";
const cleanupView = (o = {}) => ({
  read_at: NOW,
  imajlar: [{ id: ID("c"), etiketler: ["docker.io/library/redis:7.4"], boyut: 41943040, olusturuldu: NOW - 2 * DAY },
    { id: ID("a"), etiketler: [], boyut: 214958080, olusturuldu: NOW - 30 * DAY }],
  aglar: [{ ad: "eski-ag", surucu: "bridge", arayuz: "podman3" }],
  birimler: [{ ad: "eski", surucu: "local", olusturuldu: NOW - 5 * DAY }],
  klasorler: [{ ad: "eskiuygulama", yol: DATA_DIR + "/eskiuygulama", boyut: 1288490188, neden: "" },
    { ad: "buyuk", yol: DATA_DIR + "/buyuk", boyut: null, neden: "Ölçüm süreye sığmadı; klasörde çok fazla öge var." }],
  konteynerler: [{ ad: "deneme", imaj: "registry.example/deneme:1", durum: "running", yonetici: "podman" },
    { ad: "yetim", imaj: "registry.example/yetim:2", durum: "exited", yonetici: "kayitsiz" },
    { ad: "baskasi", imaj: "registry.example/baskasi:3", durum: "running", yonetici: "baska" }],
  hatalar: [], ...o,
});

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-248", surum: "1.1.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0-1-amd64", uptime: 5 * DAY + 3600,
    cores: 4, read_at: NOW, sampled_at: NOW, cpu: 2.0, mem: { total: 8375186227, used: 696254464 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "fd7a:115c:a1e0::2" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "bad", read_at: NOW - 120, checks: CHECKS },
  guncelleme: update(),
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: NOW, alan: "ev", hizmetler: [], uyarilar: [], hatalar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "", surum: "", adresler: [], cikis_dugumu: null },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, durduruldu: false, aglar: [] }, sertifikalar: [] } },
  uygulamalar: uygulamalar([uygulama("notlar", { guncelleme: "yeni", servisler: [{ ad: "web", durum: "calisiyor", imaj: "registry.example/notlar:1", guncelleme: "yeni" }] })]),
  onarim: repairState(),
  islemler: { items: AUDIT },
  gelismis: ADVANCED,
  "konteynerler/liste": resources(),
  "guvenlik-duvari": FIREWALL,
  "gelismis/temizlik": cleanupView(),
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-sistem-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8773", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, count, posts, noHorizontalScroll, styleAttributes, shot } = h;

// ---- dynamic replies
let session = { durum: "giris", kullanici: "yonetici", kanal: "tailscale" };
h.handlers["/api/konsol/oturum"] = ({ method }) => (method === "GET" ? { body: session } : undefined);
const createReplies = [];
h.handlers["/api/konsol/oturum/kur"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const forced = createReplies.shift();
  if (forced) return forced;
  session = { durum: "giris", kullanici: body.kullanici, kanal: session.kanal };
  return { body: { durum: "kuruldu" } };
};
const passwordReplies = [];
h.handlers["/api/konsol/hesap/parola"] = ({ method }) => (method === "POST" ? passwordReplies.shift() ?? { body: { durum: "degisti" } } : undefined);
h.handlers["/api/konsol/oturum/cikis"] = ({ method }) => {
  if (method !== "POST") return undefined;
  session = { durum: "giris", kanal: session.kanal };
  return { body: { durum: "cikis" } };
};
const repairReplies = [];
h.handlers["/api/konsol/onarim"] = ({ method, body }) => (method === "POST" ? repairReplies.shift() ?? { status: 202, body: { kip: body.kip } } : undefined);
const logReplies = [];
h.handlers["/api/konsol/onarim/gunluk"] = ({ query }) =>
  logReplies.shift() ?? { contentType: "text/plain; charset=utf-8", body: query.get("sure") === "7g" ? LOG7 : LOG72 };
const updateReplies = [];
h.handlers["/api/konsol/guncelleme"] = ({ method, body }) => (method === "POST" ? updateReplies.shift() ?? { status: 202, body: { surum: body.surum } } : undefined);
const rebootReplies = [];
h.handlers["/api/konsol/yeniden-baslat"] = ({ method }) => (method === "POST" ? rebootReplies.shift() ?? { status: 202, body: { sure: 5 } } : undefined);
const cleanupReplies = [];
h.handlers["/api/konsol/gelismis/temizlik"] = ({ method }) => (method === "POST" ? cleanupReplies.shift() ?? { status: 202, body: { is: HEX("7") } } : undefined);
let jobRecord = null;
h.handlers["/api/konsol/konteynerler/islem"] = ({ query }) => (jobRecord && query.get("id") === jobRecord.id ? { body: jobRecord } : { status: 404, body: { error: "İşlem bulunamadı." } });

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const hashOf = (page) => page.evaluate(() => location.hash);
const queryOf = async (page) => new URLSearchParams((await hashOf(page)).split("?")[1] ?? "");
const lastPost = (key) => posts(key).at(-1);
const gets = (key) => h.requests.filter((r) => r.method === "GET" && r.path === "/api/konsol/" + key);
const job = (o) => ({ tur: "konteyner", id: HEX("0"), ad: "İş", durum: "calisiyor", adim: "", bitis: null, ...o });
const dateTime = (s) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }).format(new Date(s * 1000));
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
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
/** Marks the current document; `reloaded` is true once the page has loaded again. */
const mark = (page) => page.evaluate(() => (window.__eski = true));
const reloaded = (page) => page.evaluate(() => window.__eski !== true).catch(() => false);

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= Sistem → Sağlık: every check, the last repair report, Denetle, Onar, the log
    let page = await newPage({ permissions: ["clipboard-read", "clipboard-write"] });
    await page.goto(url("#/sistem"));
    assert.equal(await page.locator("main h1").innerText(), "Sistem");
    const tabs = page.getByRole("tablist", { name: "Sistem bölümleri" }).getByRole("tab");
    assert.deepEqual(await tabs.allInnerTexts(), ["Sağlık", "Güncellemeler", "Hesap", "Sunucu", "İşlem geçmişi"], "no Görünüm: the theme is the top bar's");
    assert.equal(await page.getByTestId("page-desc").innerText(), "Obhut'un kendisi: sağlık, sürüm, hesap ve sunucu.");
    assert.deepEqual(await page.locator('.sidebar .nav-item[aria-current="page"] .nav-label').allInnerTexts(), ["Sistem"]);
    const checks = page.getByTestId("checks");
    await checks.locator("tbody tr").first().waitFor();
    assert.deepEqual(await checks.locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.denetim)), ["units", "disk", "firewall", "tailscale"], "problems first");
    assert.deepEqual(await checks.locator("tbody tr .pill").allInnerTexts(), ["Sorun var", "Dikkat", "Sorunsuz", "Sorunsuz"]);
    assert.equal(await checks.locator('tr[data-denetim="units"] td[data-label="Ayrıntı"]').innerText(), "Çalışmayan: master-files-panel.service");
    assert.equal(await checks.locator(".card-actions .pill").innerText(), "Sorun var");
    assert.match(await page.getByTestId("checks-read").innerText(), /^1 sorun · 1 uyarı · 2 sorunsuz · son denetim \d\d:\d\d \(\d+ dakika önce\)$/);
    // The last report: run over SSH, each step with its state.
    const repair = page.getByTestId("repair");
    await page.getByTestId("repair-facts").waitFor();
    assert.equal(await page.getByTestId("repair-head").innerText(), "Son onarım: " + dateTime(REPORT.bitis));
    assert.deepEqual(await page.getByTestId("repair-facts").locator("dd").allInnerTexts(), ["Denetim ve onarım", "SSH (sudo master-onar)", dateTime(REPORT.baslangic), dateTime(REPORT.bitis)]);
    assert.equal(await repair.locator(".repair-summary .pill").innerText(), "Tamamlandı · 1 sorun");
    assert.deepEqual(await page.getByTestId("repair-steps").locator(".repair-step .pill").allInnerTexts(), ["Sorunsuz", "Onarıldı", "Sorun var", "Atlandı"]);
    assert.equal(await page.getByTestId("repair-steps").locator('[data-adim="units"] .cell-note').innerText(), STEPS[1].detay);
    assert.equal(await page.getByTestId("repair-lock").count(), 0, "the tailnet may start it");
    await shot(page, "1440-light-saglik.png", true);

    // Denetle starts at once (a check changes nothing); the report is read every 2 s while it runs.
    data.onarim = repairState({ calisiyor: true, rapor: { durum: "calisiyor", kip: "denetle", kaynak: "konsol", baslangic: NOW + 10, bitis: null, adimlar: [STEPS[0]] } });
    await page.getByTestId("repair-check").click();
    await waitFor(() => posts("onarim").length === 1, "the check's POST");
    assert.deepEqual(lastPost("onarim"), { kip: "denetle" });
    await page.getByTestId("repair-note").filter({ hasText: "Denetim başladı." }).waitFor();
    await page.getByTestId("repair-head").filter({ hasText: "Denetim sürüyor…" }).waitFor();
    assert(await page.getByTestId("repair-check").isDisabled() && await page.getByTestId("repair-fix").isDisabled(), "one run at a time");
    assert.equal(await repair.getAttribute("aria-busy"), "true");
    await page.getByTestId("repair-steps").locator('[data-adim="firewall"]').waitFor();
    const reads = gets("onarim").length;
    data.onarim.rapor.adimlar.push({ id: "units", ad: "Servisler", durum: "calisiyor", detay: "" });
    await page.getByTestId("repair-steps").locator('[data-adim="units"] .pill').filter({ hasText: "Denetleniyor…" }).waitFor({ timeout: 5000 });
    assert(gets("onarim").length > reads, "read again while it runs");
    push("islemler", { items: [job({ tur: "onarim", id: "onarim", ad: "Denetle", adim: "Servisler" })] });
    data.onarim = repairState({ rapor: { durum: "tamam", kip: "denetle", kaynak: "konsol", baslangic: NOW + 10, bitis: NOW + 30,
      adimlar: [STEPS[0], { id: "units", ad: "Servisler", durum: "sorun", detay: "Çalışmayan: master-files-panel.service" }] } });
    push("islemler", { items: [job({ tur: "onarim", id: "onarim", ad: "Denetle", durum: "tamam", bitis: NOW + 30 })] });
    await page.getByTestId("repair-head").filter({ hasText: "Son denetim: " + dateTime(NOW + 30) }).waitFor();
    assert.deepEqual(await page.getByTestId("repair-facts").locator("dd").allInnerTexts(), ["Yalnız denetim", "Konsol", dateTime(NOW + 10), dateTime(NOW + 30)]);
    assert(await page.getByTestId("repair-fix").isEnabled());
    // Onar asks first; Esc keeps everything as it was and focus returns to Onar.
    await page.getByTestId("repair-fix").click();
    let dialog = page.getByRole("dialog", { name: "Denetim ve onarım başlasın mı?" });
    await dialog.waitFor();
    assert.equal(await activeText(page), "Vazgeç", "the safe choice has focus");
    await shot(page, "1440-light-onar-sor.png");
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "detached" });
    assert(await page.getByTestId("repair-fix").evaluate((el) => el === document.activeElement), "focus returns to Onar");
    assert.equal(posts("onarim").length, 1, "nothing started");
    // A refusal stays in the dialog with the backend's words.
    expectedFailures = ["/api/konsol/onarim"];
    repairReplies.push({ status: 409, body: { error: "Onarım zaten sürüyor." } });
    await page.getByTestId("repair-fix").click();
    await dialog.waitFor();
    await dialog.getByTestId("repair-go").click();
    await dialog.getByTestId("repair-dialog-error").filter({ hasText: "Onarım zaten sürüyor." }).waitFor();
    data.onarim = repairState({ calisiyor: true, rapor: null });
    await dialog.getByTestId("repair-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(posts("onarim"), [{ kip: "denetle" }, { kip: "onar" }, { kip: "onar" }]);
    await page.getByTestId("repair-note").filter({ hasText: "Denetim ve onarım başladı." }).waitFor();
    await page.getByTestId("repair-head").filter({ hasText: "Denetim ve onarım sürüyor…" }).waitFor();
    data.onarim = repairState();
    push("islemler", { items: [job({ tur: "onarim", id: "onarim", ad: "Denetle ve onar", durum: "tamam", bitis: NOW + 60 })] });
    await page.getByTestId("repair-head").filter({ hasText: "Son onarım:" }).waitFor();
    expectedFailures = [];

    // Onarım kaydı (A7): plain text in a sheet, at its newest line, copyable; the span is in the address.
    assert.equal(await page.getByTestId("repair-log").innerText(), "Onarım kaydı");
    await page.getByTestId("repair-log").click();
    let sheet = page.getByRole("dialog", { name: "Onarım kaydı" });
    await sheet.waitFor();
    assert.equal((await queryOf(page)).get("kayit"), "72s");
    assert.equal(await sheet.locator(".modal-desc").innerText(), "Son 72 saat");
    const logText = sheet.getByTestId("repair-log-text");
    await logText.waitFor();
    assert.equal(await logText.innerText(), LOG72.trim());
    assert.equal(gets("onarim/gunluk").at(-1).query, "?sure=72s");
    assert(await logText.evaluate((el) => el.scrollHeight > el.clientHeight && el.scrollTop + el.clientHeight >= el.scrollHeight - 2), "scrolled to the newest line");
    assert.equal(await sheet.locator('[data-sure="72s"]').getAttribute("aria-pressed"), "true");
    await sheet.getByRole("button", { name: "Onarım kaydı kopyala" }).click();
    await sheet.getByRole("status").filter({ hasText: "Onarım kaydı kopyalandı." }).waitFor();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), LOG72.trim(), "the whole text is copied");
    await shot(page, "1440-light-onarim-gunlugu.png");
    await sheet.locator('[data-sure="7g"]').click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("kayit") === "7g");
    await logText.filter({ hasText: "refresh-tailnet-config" }).waitFor();
    assert.equal(await sheet.locator(".modal-desc").innerText(), "Son 1 hafta");
    assert.equal(gets("onarim/gunluk").at(-1).query, "?sure=7g");
    // A reload opens the same sheet; a failed read says so; Esc closes it and the address forgets it.
    expectedFailures = ["/api/konsol/onarim/gunluk"];
    logReplies.push({ status: 502, body: { error: "Günlük okunamadı." } });
    await page.reload();
    sheet = page.getByRole("dialog", { name: "Onarım kaydı" });
    await sheet.getByTestId("repair-log-error").filter({ hasText: "Günlük okunamadı." }).waitFor();
    expectedFailures = [];
    logReplies.push({ contentType: "text/plain; charset=utf-8", body: "\n" });
    await sheet.locator('[data-sure="72s"]').click();
    await sheet.getByTestId("repair-log-text").filter({ hasText: "Bu sürede kayıt yok." }).waitFor();
    await page.keyboard.press("Escape");
    await sheet.waitFor({ state: "detached" });
    assert.equal(await hashOf(page), "#/sistem");
    // Keyboard: the tabs move with the arrows and the choice is in the address.
    await tabs.filter({ hasText: "Sağlık" }).focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForURL((u) => u.hash === "#/sistem?sekme=guncellemeler");
    assert.equal(await activeText(page), "Güncellemeler");
    await page.keyboard.press("End");
    await page.waitForURL((u) => u.hash === "#/sistem?sekme=gecmis");
    await page.keyboard.press("Home");
    await page.waitForURL((u) => u.hash === "#/sistem");
    await page.context().close();

    // ================= Güncellemeler: versions, Yeniden denetle, the confirmation, the run, the reload
    page = await newPage();
    await page.goto(url("#/sistem?sekme=guncellemeler"));
    const facts = page.getByTestId("update-facts");
    await facts.waitFor();
    assert.deepEqual(await facts.locator("dd").allInnerTexts(), ["1.1.0 yapı 2026.08.06-v2-248", "1.2.0 yapı 2026.10.12-v2-252 · abcdef1",
      `${dateTime(NOW - 3600)} (60 dakika önce)`]);
    assert.equal(await page.getByTestId("update-state").innerText(), "Yeni sürüm var");
    assert.equal(await page.locator("#surum-baslik").innerText(), "Obhut");
    // The applications' image updates: counted here, each confirmed on its own page.
    const appUpdates = page.getByTestId("app-updates");
    assert.equal(await appUpdates.getByTestId("app-updates-count").innerText(), "1 bekliyor");
    assert.deepEqual(await appUpdates.locator(".update-app .cell-stack").allInnerTexts(), ["notlar\nregistry.example/notlar:1 · yeni yapı"]);
    assert.equal(await appUpdates.getByRole("link", { name: "notlar: uygulamaya git" }).getAttribute("href"), "#/uygulamalar/notlar");
    assert.equal(await appUpdates.getByTestId("app-updates-note").innerText(), `Son denetim ${dateTime(NOW - 600)} (10 dakika önce). Güncelleme uygulamanın sayfasında onaylanır.`);
    await shot(page, "1440-light-guncellemeler.png", true);
    data.guncelleme = update({ denetlendi: NOW, uygulamalar: { sayi: 0, adlar: [], denetlendi: NOW - 60 } });
    await page.getByTestId("update-check").click();
    await page.getByTestId("update-note").filter({ hasText: "Yeni sürüm var: 1.2.0" }).waitFor();
    assert.equal(gets("guncelleme").at(-1).query, "?yenile=1", "past the server's cache");
    await appUpdates.getByText("Bütün uygulamalar güncel.").waitFor();
    assert.equal(await appUpdates.getByTestId("app-updates-count").innerText(), "Yok");
    await appUpdates.getByRole("link", { name: "notlar: uygulamaya git" }).waitFor({ state: "detached" });
    // The confirmation says what happens; a refusal stays in it.
    await page.getByTestId("update-start").click();
    dialog = page.getByRole("dialog", { name: "Sunucu 1.2.0 sürümüne güncellensin mi?" });
    await dialog.waitFor();
    assert.equal(await dialog.locator(".modal-desc").innerText(), "Kurulu: 1.1.0 → 1.2.0");
    assert.deepEqual(await dialog.locator(".modal-list li").allInnerTexts(), ["Kod GitHub'dan indirilir (commit abcdef1).",
      "Sistem paketleri de güncellenir; birkaç dakika sürebilir.", "Konsol ve servisler yeniden başlar; bitince sayfa kendini yeniler."]);
    await shot(page, "1440-light-guncelle-sor.png");
    expectedFailures = ["/api/konsol/guncelleme"];
    updateReplies.push({ status: 409, body: { error: "Bir uygulama işlemi sürüyor; bitince yeniden deneyin." } });
    await dialog.getByTestId("update-go").click();
    await dialog.getByTestId("update-dialog-error").filter({ hasText: "Bir uygulama işlemi sürüyor; bitince yeniden deneyin." }).waitFor();
    expectedFailures = [];
    await dialog.getByTestId("update-go").click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(posts("guncelleme"), [{ surum: "2026.10.12-v2-252", commit: "abcdef1" + "0".repeat(33) }, { surum: "2026.10.12-v2-252", commit: "abcdef1" + "0".repeat(33) }]);
    const run = page.getByTestId("update-run");
    await run.getByTestId("update-stage").filter({ hasText: "İndiriliyor" }).waitFor();
    // The server now reports the run (its unit is active).
    data.guncelleme = update({ is: { durum: "calisiyor", hedef: "2026.10.12-v2-252", mesaj: "", bitis: null, asama: "İndiriliyor" } });
    assert(await page.getByTestId("update-check").isDisabled(), "no check while it runs");
    // An earlier run's end, still listed, does not count.
    push("islemler", { items: [job({ tur: "guncelleme", id: "guncelleme", ad: "Güncelleme · 1.1.0", durum: "tamam", bitis: NOW - 3000 })] });
    await page.waitForTimeout(300);
    assert.equal(await run.getByTestId("update-stage").innerText(), "İndiriliyor");
    push("islemler", { items: [job({ tur: "guncelleme", id: "guncelleme", ad: "Güncelleme · 2026.10.12-v2-252", adim: "Paketler kuruluyor" })] });
    await run.getByTestId("update-stage").filter({ hasText: "Paketler kuruluyor" }).waitFor();
    await shot(page, "1440-light-guncelleniyor.png");
    await mark(page);
    data.guncelleme = update({ kurulu: "2026.10.12-v2-252", kurulu_surum: "1.2.0", yeni: false, is: { durum: "tamam", hedef: "2026.10.12-v2-252", mesaj: "", bitis: NOW + 900, asama: "" } });
    push("islemler", { items: [job({ tur: "guncelleme", id: "guncelleme", ad: "Güncelleme · 2026.10.12-v2-252", durum: "tamam", bitis: NOW + 900 })] });
    await page.getByTestId("update-done").filter({ hasText: "Güncelleme tamamlandı: 1.2.0. Sayfa yenileniyor…" }).waitFor();
    await page.waitForEvent("load", { timeout: 6000 });
    assert(await reloaded(page), "the page loaded Konsol's new files");
    await page.getByTestId("update-state").filter({ hasText: "Güncel" }).waitFor();
    await page.context().close();
    // A failed run: its message, no reload.
    data.guncelleme = update();
    page = await newPage();
    await page.goto(url("#/sistem?sekme=guncellemeler"));
    await page.getByTestId("update-start").click();
    await page.getByRole("dialog").getByTestId("update-go").click();
    await page.getByTestId("update-run").waitFor();
    await mark(page);
    push("islemler", { items: [job({ tur: "guncelleme", id: "guncelleme", ad: "Güncelleme", durum: "hata", adim: "İndirme başarısız: ağ hatası", bitis: NOW + 900 })] });
    await page.getByTestId("update-failed").filter({ hasText: "Güncelleme başarısız: İndirme başarısız: ağ hatası" }).waitFor();
    await page.waitForTimeout(3000);
    assert(!(await reloaded(page)), "a failed run does not reload");
    assert.equal(await page.getByTestId("update-run").count(), 0);
    assert(await page.getByTestId("update-start").isEnabled(), "may be tried again");
    await page.context().close();
    // A check that failed.
    data.guncelleme = update({ yeni: false, son: null, son_surum: null, commit: null, hata: "GitHub'a ulaşılamadı.", is: { durum: "hata", hedef: "", mesaj: "imza doğrulanamadı", bitis: NOW - 50, asama: "" } });
    page = await newPage();
    await page.goto(url("#/sistem?sekme=guncellemeler"));
    await page.getByTestId("update-state").filter({ hasText: "Denetlenemedi" }).waitFor();
    assert.equal(await page.getByTestId("update-error").innerText(), "Sürüm denetlenemedi: GitHub'a ulaşılamadı.");
    assert.equal(await page.getByTestId("update-last-failure").innerText(), "Son deneme başarısız: imza doğrulanamadı");
    assert.equal(await page.getByTestId("update-start").count(), 0, "nothing to update to");
    await page.context().close();
    // Applications never checked yet.
    data.guncelleme = update({ uygulamalar: { sayi: 0, adlar: [], denetlendi: null } });
    page = await newPage();
    await page.goto(url("#/sistem?sekme=guncellemeler"));
    await page.getByTestId("app-updates").getByText("İmajlar henüz denetlenmedi.").waitFor();
    assert.equal(await page.getByTestId("app-updates-note").innerText(), "Güncelleme uygulamanın sayfasında onaylanır.");
    await page.context().close();
    data.guncelleme = update();

    // ================= Hesap on the tailnet: create the account, change the password, no sign-out
    session = { durum: "kurulum", kanal: "tailscale" };
    page = await newPage();
    await page.goto(url("#/sistem?sekme=hesap"));
    const account = page.getByTestId("account");
    await page.getByTestId("account-state").filter({ hasText: "Hesap yok" }).waitFor();
    assert.equal(await page.getByTestId("account-channel").innerText(), "Tailscale");
    assert.equal(await page.getByTestId("account-user").innerText(), "Henüz yok");
    assert.match(await page.getByTestId("account-note").innerText(), /^Tailscale'den giriş parolasızdır/);
    assert.equal(await page.getByTestId("sign-out").count(), 0, "no sign-out on the tailnet");
    const create = page.getByTestId("account-create");
    assert.equal(await guarded(page), false, "nothing typed yet");
    await create.getByTestId("account-create-go").click();
    assert.deepEqual(await create.locator(".field-error").allInnerTexts(), [
      "Kullanıcı adı 3–32 karakter olmalı: harf, rakam veya . _ - (ilk karakter harf ya da rakam).",
      "Parola 10–256 karakter olmalı ve kontrol karakteri içermemeli."]);
    await create.getByLabel("Kullanıcı adı").fill("-yonetici");
    await create.getByLabel("Parola", { exact: true }).fill("kisa");
    assert.equal(await guarded(page), true, "a typed account asks before leaving");
    await create.getByLabel("Parola", { exact: true }).fill("uzun-bir-parola-1");
    await create.getByLabel("Parola (tekrar)").fill("uzun-bir-parola-2");
    assert.deepEqual(await create.locator(".field-error").allInnerTexts(), [
      "Kullanıcı adı 3–32 karakter olmalı: harf, rakam veya . _ - (ilk karakter harf ya da rakam).", "Parolalar aynı değil."]);
    assert.equal(posts("oturum/kur").length, 0, "nothing sent while the form is wrong");
    await create.getByLabel("Kullanıcı adı").fill("  yonetici ");
    await create.getByLabel("Parola (tekrar)").fill("uzun-bir-parola-1");
    expectedFailures = ["/api/konsol/oturum/kur"];
    createReplies.push({ status: 409, body: { error: "Konsol hesabı zaten var." } });
    await create.getByTestId("account-create-go").click();
    await create.getByTestId("account-create-error").filter({ hasText: "Konsol hesabı zaten var." }).waitFor();
    expectedFailures = [];
    await create.getByTestId("account-create-go").click();
    await page.getByTestId("account-done").filter({ hasText: "Konsol hesabı oluşturuldu; internet adresi bu hesapla açılır." }).waitFor();
    assert.deepEqual(lastPost("oturum/kur"), { kullanici: "yonetici", parola: "uzun-bir-parola-1" });
    assert.equal(await page.getByTestId("account-user").innerText(), "yonetici");
    assert.equal(await create.count(), 0);
    assert.equal(await activeText(page), "Parolayı değiştir", "focus goes to what follows the form");
    assert.equal(await guarded(page), false, "the draft is gone with the account");
    // The tailnet sets the password without the current one; every session ends.
    await page.getByTestId("password-open").click();
    assert.equal((await queryOf(page)).get("parola"), "1");
    const pw = page.getByTestId("password");
    await pw.waitFor();
    assert.equal(await pw.getByLabel("Mevcut parola").count(), 0, "not asked on the tailnet");
    assert(await pw.getByLabel("Yeni parola", { exact: true }).evaluate((el) => el === document.activeElement), "focus in the form");
    assert.equal(await pw.getByTestId("password-note").innerText(), "Tailscale cihazından mevcut parola sorulmaz; internet adresindeki tüm oturumlar kapanır.");
    await pw.getByLabel("Yeni parola", { exact: true }).fill("yeni-uzun-parola");
    await pw.getByLabel("Yeni parola (tekrar)").fill("yeni-uzun-parol");
    await pw.getByTestId("password-go").click();
    await pw.locator(".field-error").filter({ hasText: "Yeni parolalar aynı değil." }).waitFor();
    await shot(page, "1440-light-hesap-parola.png", true);
    await pw.getByLabel("Yeni parola (tekrar)").fill("yeni-uzun-parola");
    await pw.getByTestId("password-go").click();
    await page.getByTestId("account-done").filter({ hasText: "Konsol parolası değişti; internet oturumları kapatıldı." }).waitFor();
    assert.deepEqual(lastPost("hesap/parola"), { yeni: "yeni-uzun-parola" });
    assert.equal((await queryOf(page)).get("parola"), null);
    assert.equal(await activeText(page), "Parolayı değiştir");
    // Vazgeç closes the form and forgets what was typed.
    await page.getByTestId("password-open").click();
    await pw.getByLabel("Yeni parola", { exact: true }).fill("yarim");
    assert.equal(await guarded(page), true);
    await pw.getByRole("button", { name: "Vazgeç" }).click();
    await pw.waitFor({ state: "detached" });
    assert.equal(await guarded(page), false);
    assert.equal(await page.getByTestId("account-sign-out").count(), 0, "no sign-out on the tailnet");
    await page.context().close();

    // ================= Sunucu: the facts; the reboot with the typed word, the wait and the reconnect
    page = await newPage();
    await page.goto(url("#/sistem?sekme=sunucu"));
    const server = page.getByTestId("server-facts");
    await server.locator("dd").first().waitFor();
    const fact = (id) => server.locator(`[data-bilgi="${id}"]`).innerText();
    assert.deepEqual(await Promise.all(["host", "os", "kernel", "version", "build", "uptime", "tailscale", "wan", "panel", "root"].map(fact)), [
      "sunucu", "Debian GNU/Linux 13 (trixie)", "6.12.0-1-amd64", "1.1.0", "2026.08.06-v2-248", "5 gün", "100.64.0.2 · fd7a:115c:a1e0::2", "203.0.113.10 (eth0)",
      "panel.ev", "/srv"]);
    await page.getByTestId("reboot-open").click();
    sheet = page.getByRole("dialog", { name: "Sunucu yeniden başlatılsın mı?" });
    await sheet.waitFor();
    assert.equal(await sheet.locator(".modal-desc").innerText(), "sunucu");
    const go = sheet.getByTestId("reboot-go");
    assert(await go.isDisabled(), "the typed word first");
    const word = sheet.getByLabel("Onaylamak için onayla yazın");
    assert(await word.evaluate((el) => el === document.activeElement), "the field has focus");
    await word.fill("onay");
    assert(await go.isDisabled());
    await word.fill(" ONAYLA ");
    assert(await go.isEnabled(), "Turkish case rules, spaces ignored");
    await shot(page, "1440-light-yeniden-baslat.png");
    expectedFailures = ["/api/konsol/yeniden-baslat"];
    rebootReplies.push({ status: 409, body: { error: "Güncelleme sürüyor; bitince yeniden deneyin." } });
    await go.click();
    await sheet.getByTestId("reboot-error").filter({ hasText: "Güncelleme sürüyor; bitince yeniden deneyin." }).waitFor();
    expectedFailures = ["/api/konsol/kaynaklar"];
    await go.click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(posts("yeniden-baslat"), [{}, {}]);
    const wait = page.getByTestId("reboot-wait");
    await wait.filter({ hasText: "Sunucu 5 saniye içinde yeniden başlıyor; Konsol birkaç dakika ulaşılamaz." }).waitFor();
    assert(await page.getByTestId("reboot-open").isDisabled(), "asked once");
    await mark(page);
    h.status["/api/konsol/kaynaklar"] = 503;
    await page.locator('[data-testid="reboot-wait"][data-asama="kapali"]').waitFor({ timeout: 6000 });
    await shot(page, "1440-light-yeniden-basliyor.png");
    delete h.status["/api/konsol/kaynaklar"];
    data.kaynaklar = { ...data.kaynaklar, uptime: 40 };
    await page.locator('[data-testid="reboot-wait"][data-asama="acildi"]').waitFor({ timeout: 6000 });
    await page.waitForEvent("load", { timeout: 6000 });
    assert(await reloaded(page), "the page reconnects by loading again");
    expectedFailures = [];
    data.kaynaklar = { ...data.kaynaklar, uptime: 5 * DAY + 3600 };
    await page.context().close();

    // ================= no Görünüm: an old tab address shows Sağlık; the theme is the top bar's (yeni-ui.cjs)
    page = await newPage();
    await page.goto(url("#/sistem?sekme=gorunum"));
    await page.getByTestId("checks").waitFor();
    assert.equal(await page.getByRole("tab", { selected: true }).innerText(), "Sağlık");
    assert.equal(await page.getByRole("radio", { name: "Koyu" }).count(), 0);

    // ================= İşlem geçmişi: newest first, every kind in words, kinds and search
    await page.goto(url("#/sistem?sekme=gecmis"));
    const audit = page.getByTestId("audit");
    await audit.locator("tbody tr").first().waitFor();
    assert.equal(await audit.locator(".card-title").innerText(), "İşlem geçmişi");
    assert.deepEqual(await audit.getByTestId("audit-line").allInnerTexts(), AUDIT_LINES);
    assert.deepEqual(await audit.locator('td[data-label="Tür"]').allInnerTexts(), [
      "Konsol", "WireGuard", "WireGuard", "WireGuard", "WireGuard", "WireGuard", "WireGuard", "WireGuard", "WireGuard", "Erişim", "Erişim", "Erişim",
      "Gelişmiş", "Uygulamalar", "Uygulamalar", "Uygulamalar", "Uygulamalar", "Dosyalar", "Dosyalar", "Dosyalar", "Konsol", "Konsol", "Erişim", "Konsol",
      "Konsol", "Paylaşımlar"]);
    assert.deepEqual(await audit.locator('tr[data-tur="wireguard"]').evaluateAll((rows) => rows.map((r) => r.dataset.eylem)),
      ["ayar-apply", "ayar-confirm", "ayar-apply", "wireguard-ekle", "wireguard-keepalive", "wireguard-peer-durum", "wireguard-ag-ayarlar", "wireguard-qr"]);
    const failed = audit.locator('tr[data-eylem="parola-degis"]');
    assert.match(await failed.getAttribute("class"), /audit-failed/);
    assert.equal(await failed.locator('td[data-label="Kim"]').innerText(), "konsol\n203.0.113.50");
    assert.equal(await audit.locator("tbody tr").first().locator("time").getAttribute("datetime"), new Date((NOW - 60) * 1000).toISOString());
    const chips = audit.getByRole("group", { name: "Türe göre süz" }).locator(".filter-chip");
    // The fixed kinds in their own order, whatever order the lines come in.
    assert.deepEqual((await chips.allInnerTexts()).map((t) => t.replace(/\s+/g, " ")),
      ["Tümü 26", "Konsol 5", "Uygulamalar 4", "Erişim 4", "WireGuard 8", "Paylaşımlar 1", "Dosyalar 3", "Gelişmiş 1"]);
    await chips.filter({ hasText: "WireGuard" }).click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("tur") === "wireguard");
    assert.equal(await chips.filter({ hasText: "WireGuard" }).getAttribute("aria-pressed"), "true");
    assert.deepEqual(await audit.getByTestId("audit-line").allInnerTexts(), AUDIT_LINES.slice(1, 9));
    await chips.filter({ hasText: "Tümü" }).click();
    const search = audit.getByTestId("audit-search");
    assert.equal(await search.getAttribute("placeholder"), "Geçmişte ara");
    await search.fill("İMAJ GÜNCELLEME");
    assert.deepEqual(await audit.getByTestId("audit-line").allInnerTexts(), ["Uygulama imaj güncellemesi istendi: ornek"], "İ folds to i");
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("ara") === "İMAJ GÜNCELLEME");
    await search.fill("ımaj");
    await audit.getByText("Eşleşen kayıt yok").waitFor();
    await search.fill("203.0.113.50");
    assert.deepEqual(await audit.getByTestId("audit-line").allInnerTexts(), ["Konsol parolası değiştirildi — başarısız"], "the address is searched too");
    // A shared link opens the same view; "Süzgeci temizle" empties both.
    await page.goto(url("#/sistem?sekme=gecmis&tur=dosya&ara=yok-boyle"));
    await audit.getByText("Eşleşen kayıt yok").waitFor();
    assert.equal(await search.inputValue(), "yok-boyle");
    assert.equal(await chips.filter({ hasText: "Dosyalar" }).getAttribute("aria-pressed"), "true");
    await audit.getByRole("button", { name: "Süzgeci temizle" }).click();
    await page.waitForURL((u) => u.hash === "#/sistem?sekme=gecmis");
    assert.equal(await audit.getByTestId("audit-line").count(), AUDIT.length);
    await page.context().close();

    // ================= the internet channel: locks, the account with the current password, sign-out
    session = { durum: "acik", kullanici: "yonetici", oturum_gun: 7, kanal: "internet" };
    data.onarim = repairState({ baslatilabilir: false });
    data.guncelleme = update({ baslatilabilir: false });
    expectedFailures = ["/api/konsol/olaylar"];
    page = await h.newHttpsPage("konsol.example.org");
    await page.goto("https://konsol.example.org/#/sistem");
    await page.getByTestId("repair-lock").filter({ hasText: "Onarım yalnız Tailscale adresinden başlatılır." }).waitFor();
    assert(await page.getByTestId("repair-check").isDisabled() && await page.getByTestId("repair-fix").isDisabled());
    assert(await page.getByTestId("repair-log").isEnabled(), "the log is read anywhere");
    const signOut = page.locator(".sidebar").getByTestId("sign-out");
    await signOut.waitFor();
    assert.equal(await signOut.innerText(), "Çıkış yap");
    await page.getByRole("tab", { name: "Güncellemeler" }).click();
    await page.getByTestId("update-lock").filter({ hasText: "Güncelleme yalnız Tailscale adresinden başlatılır." }).waitFor();
    assert(await page.getByTestId("update-start").isDisabled());
    await page.getByRole("tab", { name: "Sunucu" }).click();
    await page.getByTestId("reboot-lock").filter({ hasText: "Yeniden başlatma yalnız Tailscale adresinden istenir." }).waitFor();
    assert(await page.getByTestId("reboot-open").isDisabled());
    await page.getByRole("tab", { name: "Hesap" }).click();
    await page.getByTestId("account-session").filter({ hasText: "Açık · 7 gün geçerli" }).waitFor();
    assert.equal(await page.getByTestId("account-channel").innerText(), "İnternet adresi");
    assert.equal(await page.getByTestId("account-note").innerText(), "Giriş yapan: yonetici. Oturum 7 gün açık kalır.");
    await page.getByTestId("password-open").click();
    const pwi = page.getByTestId("password");
    assert(await pwi.getByLabel("Mevcut parola").evaluate((el) => el === document.activeElement), "the current password first");
    assert.equal(await pwi.getByTestId("password-note").innerText(), "Bu tarayıcı açık kalır; diğer tüm oturumlar kapanır.");
    await pwi.getByTestId("password-go").click();
    await pwi.locator(".field-error").filter({ hasText: "Mevcut parolayı yazın." }).waitFor();
    // A wrong current password is shown on the form; it does not send the browser to the sign-in page.
    expectedFailures = ["/api/konsol/olaylar", "/api/konsol/hesap/parola"];
    passwordReplies.push({ status: 401, body: { error: "Mevcut parola hatalı." } });
    await pwi.getByLabel("Mevcut parola").fill("yanlis-parola");
    await pwi.getByLabel("Yeni parola", { exact: true }).fill("yeni-uzun-parola");
    await pwi.getByLabel("Yeni parola (tekrar)").fill("yeni-uzun-parola");
    await pwi.getByTestId("password-go").click();
    await pwi.getByTestId("password-error").filter({ hasText: "Mevcut parola hatalı." }).waitFor();
    assert.equal(new URL(page.url()).pathname, "/", "still here");
    assert.equal(await pwi.getByLabel("Mevcut parola").inputValue(), "", "the wrong one is cleared");
    await pwi.getByLabel("Mevcut parola").fill("dogru-parola-1");
    await pwi.getByTestId("password-go").click();
    await page.getByTestId("account-done").filter({ hasText: "Konsol parolası değişti; diğer oturumlar kapatıldı." }).waitFor();
    assert.deepEqual(lastPost("hesap/parola"), { eski: "dogru-parola-1", yeni: "yeni-uzun-parola" });
    await shot(page, "1440-light-internet-hesap.png", true);
    // An ended session's 401 (with the sign-in mark) still leaves for the sign-in page.
    passwordReplies.push({ status: 401, body: { error: "Oturum gerekli; yeniden giriş yapın.", giris: true } });
    await page.getByTestId("password-open").click();
    await pwi.getByLabel("Mevcut parola").fill("dogru-parola-1");
    await pwi.getByLabel("Yeni parola", { exact: true }).fill("baska-uzun-parola");
    await pwi.getByLabel("Yeni parola (tekrar)").fill("baska-uzun-parola");
    await pwi.getByTestId("password-go").click();
    await page.waitForURL((u) => u.pathname === "/giris.html" && u.search === "");
    await page.context().close();
    // Sign-out from the sidebar and from the phone's menu sheet.
    session = { durum: "acik", kullanici: "yonetici", oturum_gun: 7, kanal: "internet" };
    page = await h.newHttpsPage("konsol.example.org", { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await page.goto("https://konsol.example.org/#/genel");
    await page.getByRole("button", { name: "Daha fazla" }).tap();
    const menu = page.getByRole("dialog", { name: "Menü" });
    await menu.getByTestId("sign-out").waitFor();
    await shot(page, "390-light-internet-menu.png");
    await menu.getByTestId("sign-out").tap();
    await page.waitForURL((u) => u.pathname === "/giris.html" && u.search === "");
    assert.deepEqual(lastPost("oturum/cikis"), {});
    await page.context().close();
    session = { durum: "giris", kullanici: "yonetici", kanal: "tailscale" };
    data.onarim = repairState();
    data.guncelleme = update();
    expectedFailures = [];

    // ================= Gelişmiş → Caddy and DNS: the effective configuration and the raw files
    page = await newPage({ permissions: ["clipboard-read", "clipboard-write"] });
    await page.goto(url("#/gelismis"));
    assert.equal(await page.locator("main h1").innerText(), "Gelişmiş");
    assert.deepEqual(await page.getByRole("tablist", { name: "Gelişmiş bölümleri" }).getByRole("tab").allInnerTexts(), ["Caddy", "DNS", "Güvenlik duvarı", "Podman"]);
    const caddy = page.getByTestId("caddy");
    await caddy.locator("tbody tr").first().waitFor();
    assert.equal(await page.getByTestId("caddy-count").innerText(), "Caddy · 5 ad, 2 IP adresi");
    const site = (address) => caddy.locator(`tr[data-adres="${address}"]`);
    assert.equal(await site("panel.ev").locator(".cell-sub").innerText(), "Sunucu yönetim paneli");
    assert.deepEqual(await site("panel.ev").locator(".route-list li").allInnerTexts().then((l) => l.map((x) => x.replace(/\s+/g, " "))), ["/api/* → unix//run/master-panel/api.sock", "diğer → sayfa dosyaları"]);
    assert.equal(await site("100.64.0.2:61010").locator(".cell-sub").innerText(), "Temel servis · ad çözmeyen cihazlar için (ör. Infuse)");
    // Owners: the base's sites (the panel's public one too) are Temel, the shares' public site Paylaşımlar,
    // every other site its source as it is (no "-wan"), even when an application has a similar name.
    assert.deepEqual(await caddy.locator('tbody td[data-label="Kaynak"]').allInnerTexts(),
      ["Temel", "Temel", "paylasim", "uygulama-notlar", "uygulama-notlar", "Temel", "Paylaşımlar"]);
    assert.equal(await site("paylas.ev").locator(".cell-sub").innerText(), "paylasim");
    assert.equal(await site("notlar.ev").locator(".cell-sub").innerText(), "uygulama-notlar");
    assert.equal(await site("notlar.example.org").locator(".cell-sub").innerText(), "uygulama-notlar · kendi girişiyle");
    assert.equal(await site("notlar.example.org").locator('td[data-label="Erişim"]').innerText(), "İnternet");
    assert.equal(await site("notlar.example.org").locator('td[data-label="Şema"]').innerText(), "HTTPS");
    assert.equal(await site("konsol.example.org").locator(".cell-sub").innerText(), "Sunucu yönetim paneli · internet girişi");
    assert.equal(await site("203.0.113.10:61010").locator('td[data-label="Şema"]').innerText(), "HTTP · şifresiz");
    assert.equal(await site("203.0.113.10:61010").locator('td[data-label="Nereye gider"]').innerText(), "sabit yanıt “yalnız WebDAV”");
    assert.equal(await site("203.0.113.10:61010").locator(".cell-sub").innerText(), "İnternet üzerinden seçili klasör paylaşımları");
    await caddy.getByText("İnternet üzerinden HTTP parolaları ve dosyaları şifrelemez.").waitFor();
    // The raw files: closed until asked (in the address), each with its own copy button.
    const raw = caddy.getByTestId("raw");
    assert.equal(await raw.evaluate((d) => d.open), false);
    assert.equal(await raw.locator(".raw-count").innerText(), "· Caddyfile ve üretilen siteler · 2 dosya");
    await raw.locator("summary").click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("ham") === "1");
    assert.deepEqual(await raw.locator(".raw-path").allInnerTexts(), ["/etc/caddy/Caddyfile", "/etc/caddy/moduller/uygulama-notlar.caddy"]);
    assert.equal(await raw.locator('[data-dosya="Caddyfile"] pre').innerText(), CADDYFILE.trim());
    await raw.getByRole("button", { name: "Caddyfile kopyala" }).click();
    await raw.getByRole("status").filter({ hasText: "Caddyfile kopyalandı." }).waitFor();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), CADDYFILE, "the file as it is");
    await shot(page, "1440-light-caddy.png", true);
    // "Yenile" asks past the cache; a failed read keeps the last view and says so.
    await page.getByTestId("advanced-refresh").click();
    await waitFor(() => gets("gelismis").some((r) => r.query === "?yenile=1"), "fresh read");
    expectedFailures = ["/api/konsol/gelismis"];
    h.status["/api/konsol/gelismis"] = 503;
    await page.getByTestId("advanced-refresh").click();
    await page.getByTestId("advanced-error").filter({ hasText: "fixture" }).waitFor();
    assert(await caddy.locator("tbody tr").count() === 7, "the last view stays");
    delete h.status["/api/konsol/gelismis"];
    expectedFailures = [];
    // DNS shares the same read.
    const advancedReads = gets("gelismis").length;
    await page.getByRole("tab", { name: "DNS" }).click();
    const dns = page.getByTestId("dns");
    await dns.waitFor();
    assert.equal(gets("gelismis").length, advancedReads, "one read for Caddy and DNS");
    assert.deepEqual(await page.getByTestId("dns-facts").locator("dd").allInnerTexts(), ["tailscale0, lo", "ev", "Kapalı"]);
    assert.deepEqual(await dns.locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.ad)), ["panel.ev", "notlar.ev", "yazici.ev"]);
    assert.deepEqual(await dns.locator('tbody td[data-label="Kaynak"]').allInnerTexts(), ["Temel", "uygulama", "Temel"], "base is Temel, any other source as it is");
    assert.deepEqual(await dns.locator('tr[data-ad="notlar.ev"] td').allInnerTexts(), ["100.64.0.2, fd7a:115c:a1e0::2", "IPv4 + IPv6", "uygulama"]);
    assert.equal(await dns.getByRole("link", { name: "Yerel adları Erişim'de değiştir" }).getAttribute("href"), "#/erisim?sekme=adlar");
    assert.equal(await dns.getByTestId("raw").evaluate((d) => d.open), true, "?ham=1 stays in the address");
    assert.deepEqual(await dns.locator(".raw-path").allInnerTexts(), ["/etc/dnsmasq.d/master-stack.conf", "/etc/dnsmasq.d/modul-uygulama.conf"]);
    // Güvenlik duvarı: the technical rules and the listeners per family, read-only, with the way to Erişim.
    await page.getByRole("tab", { name: "Güvenlik duvarı" }).click();
    const fw = page.getByTestId("advanced-firewall");
    const technical = fw.getByTestId("fw-technical");
    await technical.locator("tbody tr").first().waitFor();
    assert.equal(await technical.getByTestId("fw-manage").getAttribute("href"), "#/erisim?sekme=guvenlik-duvari");
    assert.deepEqual(await technical.locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.zincir)), ["MASTER-INPUT", "ts-input"], "IPv4 first");
    assert.deepEqual(await technical.locator('tr[data-zincir="MASTER-INPUT"] td').allInnerTexts(),
      ["1", "-A MASTER-INPUT -i lo -j ACCEPT", "12.345 paket · 6.789.012 bayt", "Obhut"]);
    const listeners = fw.getByTestId("fw-listeners");
    assert.deepEqual(await listeners.locator('td[data-label="Ağ"]').allInnerTexts(), ["Tüm arayüzler", "Tailscale", "Yalnız bu sunucu"]);
    assert.equal(await fw.getByRole("button", { name: /Uygula|Kaydet|Ekle/ }).count(), 0, "nothing is changed here");
    await shot(page, "1440-light-gelismis-duvar.png", true);
    await fw.locator('[data-aile="6"]').click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("aile") === "6");
    assert.deepEqual(await technical.locator("tbody tr").evaluateAll((rows) => rows.map((r) => r.dataset.zincir)), ["MASTER-INPUT"]);
    assert.equal(await technical.locator(".cell-sub").innerText(), "filter · IPv6");
    assert.deepEqual(await listeners.locator("tbody .mono").allInnerTexts(), ["80", "fd7a:115c:a1e0::2"]);
    // "Yenile" asks past the cache; a listener read that failed says so.
    data["guvenlik-duvari"] = { ...FIREWALL, dinleyiciler: null };
    await fw.getByTestId("fw-refresh").click();
    await listeners.getByTestId("fw-listeners-error").filter({ hasText: "Dinleyiciler okunamadı." }).waitFor();
    assert.equal(gets("guvenlik-duvari").at(-1).query, "?yenile=1");
    data["guvenlik-duvari"] = FIREWALL;
    await page.context().close();

    // ================= Gelişmiş → Podman: the inventory read-only, the cleanup its only write
    page = await newPage();
    await page.goto(url("#/gelismis?sekme=podman"));
    const podman = page.getByTestId("podman");
    await podman.getByTestId("images").locator("tbody tr").first().waitFor();
    assert.match(await page.getByTestId("podman-runtime").innerText(), /Podman 5\.4\.2 · bu sunucu, rootful, systemd ile yönetilir/);
    const resTabs = podman.getByRole("tablist", { name: "Podman kaynakları" }).getByRole("tab");
    assert.deepEqual(await resTabs.allInnerTexts(), ["İmajlar\n3", "Birimler\n3", "Ağlar\n3"]);
    assert.deepEqual(await podman.getByRole("button").allInnerTexts(), ["Yenile", "Yenile", "Temizle…"], "nothing to pull, create, start or adopt");
    const images = podman.getByTestId("images");
    const image = (name) => images.locator(`tr[data-imaj="${name}"]`);
    const redis = image("docker.io/library/redis:7.4");
    assert.deepEqual(await redis.locator("td").allInnerTexts(), ["cccccccccccc", "40 MB", new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", year: "numeric" }).format(new Date((NOW - 2 * DAY) * 1000)), "kullanılmıyor"]);
    // An application's name in "Kullanan" leads to its page.
    assert.equal(await image("docker.io/library/nginx:1.27").getByRole("link", { name: "notlar" }).getAttribute("href"), "#/uygulamalar/notlar");
    await resTabs.filter({ hasText: "Birimler" }).click();
    await page.waitForURL((u) => new URLSearchParams(u.hash.split("?")[1]).get("kaynak") === "birimler");
    const volumes = podman.getByTestId("volumes");
    assert.deepEqual(await volumes.locator("tbody th .pill").allInnerTexts(), ["Dışarıda", "Obhut", "Dışarıda"]);
    await resTabs.filter({ hasText: "Ağlar" }).click();
    const networks = podman.getByTestId("networks");
    const network = (name) => networks.locator(`tr[data-ag="${name}"]`);
    assert.deepEqual(await network("kapali-ag").locator(".pill").allInnerTexts(), ["Obhut", "İç ağ"]);
    assert.equal(await network("podman").locator(".pill").innerText(), "Sistem");
    assert.equal(await network("konsol").locator('td[data-label="Alt ağ"]').innerText(), "10.89.0.0/24");
    // The containers Obhut does not manage: read-only, each with who runs it.
    const unmanaged = podman.getByTestId("unmanaged");
    assert.deepEqual(await unmanaged.locator("[data-konteyner]").evaluateAll((rows) => rows.map((r) => r.dataset.konteyner)), ["deneme", "yetim", "baskasi"]);
    assert.match(await unmanaged.locator('[data-konteyner="deneme"]').innerText(), /registry\.example\/deneme:1\nYalnız Podman; Uygulama ekle'de var olan konteyner olarak seçilebilir/);
    assert.match(await unmanaged.locator('[data-konteyner="yetim"]').innerText(), /Bir uygulamanın etiketini taşıyor ama kaydı yok/);
    assert.equal(await unmanaged.locator("button, a").count(), 0, "no action on them");

    // The cleanup: what nothing uses, in groups; nothing goes before it is ticked, named and the word typed.
    const cleanup = podman.getByTestId("cleanup");
    assert.deepEqual(await cleanup.locator("fieldset").evaluateAll((g) => g.map((x) => x.dataset.tur)), ["imajlar", "aglar", "birimler", "klasorler"]);
    assert.deepEqual(await cleanup.locator("legend").allInnerTexts(), ["Kullanılmayan imajlar (2)", "Kullanılmayan ağlar (1)", "Kullanılmayan birimler (1)",
      "Kaldırılmış uygulamaların klasörleri (2)"]);
    const item = (kind, value) => cleanup.locator(`fieldset[data-tur="${kind}"] [data-oge="${value}"]`);
    assert.equal(await item("imajlar", ID("a")).locator("strong").innerText(), "<etiketsiz> aaaaaaaaaaaa");
    assert.match(await item("klasorler", "eskiuygulama").locator(".cell-note").innerText(), /^Uygulama eskiuygulama kaldırılmış · 1,2 GB$/);
    assert.equal(await item("klasorler", "buyuk").locator(".cell-note").innerText(), "Uygulama buyuk kaldırılmış · Ölçüm süreye sığmadı; klasörde çok fazla öge var.");
    const start = cleanup.getByTestId("cleanup-start");
    assert(await start.isDisabled(), "nothing ticked");
    assert.equal(await cleanup.getByTestId("cleanup-chosen").innerText(), "Kaldırılacakları seçin.");
    await item("imajlar", ID("c")).getByRole("checkbox").check();
    await item("klasorler", "eskiuygulama").getByRole("checkbox").check();
    await cleanup.locator('[data-hepsi="aglar"]').check();
    assert.equal(await cleanup.getByTestId("cleanup-chosen").innerText(), "3 öge seçili · 1,2 GB");
    assert.equal(await cleanup.locator('[data-hepsi="imajlar"]').evaluate((el) => el.indeterminate), true, "some of a group");
    await shot(page, "1440-light-temizlik.png", true);
    await start.click();
    dialog = page.getByRole("dialog", { name: "Temizlensin mi?" });
    await dialog.waitFor();
    assert.equal(await dialog.locator(".modal-desc").innerText(), "3 öge kalıcı olarak kaldırılır.");
    assert.deepEqual(await dialog.getByTestId("cleanup-dialog-list").locator("li").allInnerTexts(), [
      "docker.io/library/redis:7.4\nKullanılmayan imaj · 40 MB", "eski-ag\nKullanılmayan ağ", `${DATA_DIR}/eskiuygulama\nKaldırılmış uygulamanın klasörü · 1,2 GB`]);
    const goClean = dialog.getByTestId("cleanup-go");
    assert(await goClean.isDisabled(), "the typed word first");
    await dialog.getByLabel("Onaylamak için temizle yazın").fill("TEMIZLE");
    assert(await goClean.isDisabled(), "Turkish case rules: I folds to ı");
    await dialog.getByLabel("Onaylamak için temizle yazın").fill(" TEMİZLE ");
    assert(await goClean.isEnabled(), "İ folds to i, spaces ignored");
    await shot(page, "1440-light-temizlik-sor.png");
    // A refusal stays in the dialog with the backend's words.
    expectedFailures = ["/api/konsol/gelismis/temizlik"];
    cleanupReplies.push({ status: 409, body: { error: "Bir uygulama işlemi sürüyor; bitince yeniden deneyin." } });
    await goClean.click();
    await dialog.getByTestId("cleanup-dialog-error").filter({ hasText: "Bir uygulama işlemi sürüyor; bitince yeniden deneyin." }).waitFor();
    expectedFailures = [];
    await goClean.click();
    await dialog.waitFor({ state: "detached" });
    assert.deepEqual(posts("gelismis/temizlik"), [{ imajlar: [ID("c")], aglar: ["eski-ag"], klasorler: ["eskiuygulama"] }, { imajlar: [ID("c")], aglar: ["eski-ag"], klasorler: ["eskiuygulama"] }]);
    // The job runs in İşlemler; its end says what went.
    await cleanup.getByTestId("cleanup-running").waitFor();
    assert(await cleanup.getByTestId("cleanup-start").isDisabled(), "one cleanup at a time");
    push("islemler", { items: [job({ id: HEX("7"), ad: "Podman · Temizlik", adim: "Kaldırılıyor: eski-ag" })] });
    await cleanup.getByTestId("cleanup-running").filter({ hasText: "Temizlik sürüyor · Kaldırılıyor: eski-ag" }).waitFor();
    await cleanup.getByTestId("cleanup-jobs").click();
    const drawer = page.getByRole("dialog", { name: "İşlemler" });
    await drawer.locator(".job").filter({ hasText: "Podman · Temizlik" }).filter({ hasText: "Gelişmiş · Kaldırılıyor: eski-ag" }).waitFor();
    await page.keyboard.press("Escape");
    jobRecord = { id: HEX("7"), action: "temizlik", name: "Podman", state: "done", step: "",
      result: { ok: true, kaldirilan: [{ tur: "imaj", ad: ID("c") }, { tur: "ag", ad: "eski-ag" }, { tur: "klasor", ad: "eskiuygulama" }] } };
    data["gelismis/temizlik"] = cleanupView({ imajlar: [cleanupView().imajlar[1]], aglar: [], klasorler: [cleanupView().klasorler[1]] });
    const cleanupReads = gets("gelismis/temizlik").length;
    push("islemler", { items: [job({ id: HEX("7"), ad: "Podman · Temizlik", durum: "tamam", bitis: NOW + 60 })] });
    await cleanup.getByTestId("cleanup-result").filter({ hasText: "Temizlendi: 3 öge kaldırıldı (imaj cccccccccccc, ağ eski-ag, klasör eskiuygulama)." }).waitFor();
    await waitFor(() => gets("gelismis/temizlik").length > cleanupReads, "the list read again");
    await cleanup.locator('fieldset[data-tur="aglar"]').waitFor({ state: "detached" });
    // A job that left items names them and why.
    await item("birimler", "eski").getByRole("checkbox").check();
    await cleanup.getByTestId("cleanup-start").click();
    await dialog.getByLabel("Onaylamak için temizle yazın").fill("temizle");
    cleanupReplies.push({ status: 202, body: { is: HEX("8") } });
    await dialog.getByTestId("cleanup-go").click();
    await dialog.waitFor({ state: "detached" });
    push("islemler", { items: [job({ id: HEX("8"), ad: "Podman · Temizlik", durum: "hata", bitis: NOW + 90,
      adim: "1 öge kaldırılmadı (0 kaldırıldı): eski: Birim bir konteynerde kullanılıyor." })] });
    await cleanup.getByTestId("cleanup-result").filter({ hasText: "Temizlik tamamlanamadı: 1 öge kaldırılmadı (0 kaldırıldı): eski: Birim bir konteynerde kullanılıyor." }).waitFor();
    assert.match(await cleanup.getByTestId("cleanup-result").getAttribute("class"), /notice-warning/);
    // "Yenile" measures the folders again.
    await cleanup.getByTestId("cleanup-refresh").click();
    await waitFor(() => gets("gelismis/temizlik").some((r) => r.query === "?yenile=1"), "measured again");
    assert.equal(posts("konteynerler/islem").length, 0);
    await page.context().close();

    // Nothing to clean; a cleanup read that failed; a collection that could not be read; a runtime that does not answer.
    data["gelismis/temizlik"] = cleanupView({ imajlar: [], aglar: [], birimler: [], klasorler: [], konteynerler: [], hatalar: ["notlar: tanım okunamadı."] });
    page = await newPage();
    await page.goto(url("#/gelismis?sekme=podman"));
    await page.getByTestId("cleanup").getByText("Temizlenecek bir şey yok").waitFor();
    assert.equal(await page.getByTestId("cleanup-warning").innerText(), "notlar: tanım okunamadı.");
    assert.equal(await page.getByTestId("cleanup-start").count(), 0);
    assert.equal(await page.getByTestId("unmanaged").locator(".card-text").innerText(), "Yok: bütün konteynerler bir uygulamanın.");
    await page.context().close();
    expectedFailures = ["/api/konsol/gelismis/temizlik"];
    h.status["/api/konsol/gelismis/temizlik"] = 503;
    data["konteynerler/liste"] = resources({ volumes: undefined, resource_errors: { volumes: "Birimler okunamadı: podman volume ls 125" } });
    delete data["konteynerler/liste"].volumes;
    page = await newPage();
    await page.goto(url("#/gelismis?sekme=podman&kaynak=birimler"));
    await page.getByTestId("cleanup-error").filter({ hasText: "fixture" }).waitFor();
    assert.equal(await page.getByTestId("unmanaged").count(), 0, "not shown as empty");
    await page.getByTestId("volumes-error").filter({ hasText: "Birimler okunamadı: podman volume ls 125" }).waitFor();
    assert.equal(await page.getByRole("tab", { name: /Birimler/ }).innerText(), "Birimler\nokunamadı");
    data["konteynerler/liste"] = resources({ runtime: { version: "", ok: false, error: "Podman yanıt vermedi (podman info 125)." } });
    await page.getByTestId("podman-refresh").click();
    await page.getByTestId("podman-runtime-error").filter({ hasText: "Podman yanıt vermedi (podman info 125)." }).waitFor();
    await page.getByTestId("volumes-error").filter({ hasText: "Podman yanıt vermedi (podman info 125)." }).waitFor();
    await page.context().close();
    delete h.status["/api/konsol/gelismis/temizlik"];
    expectedFailures = [];
    data["konteynerler/liste"] = resources();
    data["gelismis/temizlik"] = cleanupView();

    // ================= the shell: Uyarılar leads here, the palette knows the new tabs
    page = await newPage();
    await page.goto(url("#/uyarilar"));
    assert.equal(await page.getByRole("link", { name: "Tüm denetimler" }).getAttribute("href"), "#/sistem");
    await page.getByRole("link", { name: "Tüm denetimler" }).click();
    await page.waitForURL((u) => u.hash === "#/sistem");
    await page.getByTestId("checks").waitFor();
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    const input = palette.getByRole("combobox");
    await input.fill("işlem geçmişi");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Sistem", "Sistem → İşlem geçmişi"], "the first tab is the section itself");
    await input.fill("onarım kaydı");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Sistem"], "Sağlık is the section's own page");
    await input.fill("görünüm");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Tema: sistem", "Tema: açık", "Tema: koyu"], "no Görünüm tab");
    await input.fill("temizlik");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Gelişmiş", "Gelişmiş → Podman", "İşlemleri göster"]);
    await input.fill("geçmiş");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/sistem?sekme=gecmis");
    await page.keyboard.press("Control+K");
    await input.fill("imaj");
    const found = await palette.locator(".palette-option .palette-label").allInnerTexts();
    assert(found.includes("Gelişmiş → Podman") && !found.some((l) => l.startsWith("Ayarlar")), "the old Settings views are gone: " + found);
    await input.fill("parola");
    assert.deepEqual(await palette.locator(".palette-option .palette-label").allInnerTexts(), ["Sistem → Hesap"]);
    await page.keyboard.press("Escape");
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes: no style attribute, no horizontal scroll
    const VIEWS = [
      ["saglik", "#/sistem", "[data-testid=repair-steps]"],
      ["guncellemeler", "#/sistem?sekme=guncellemeler", "[data-testid=update-facts]"],
      ["hesap", "#/sistem?sekme=hesap&parola=1", "[data-testid=password]"],
      ["sunucu", "#/sistem?sekme=sunucu", "[data-bilgi=root]"],
      ["gecmis", "#/sistem?sekme=gecmis", "[data-testid=audit] tbody tr"],
      ["caddy", "#/gelismis?ham=1", "[data-testid=caddy] tbody tr"],
      ["dns", "#/gelismis?sekme=dns&ham=1", "[data-testid=dns] tbody tr"],
      ["guvenlik", "#/gelismis?sekme=guvenlik-duvari", "[data-testid=fw-technical] tbody tr"],
      ["imajlar", "#/gelismis?sekme=podman", "[data-testid=cleanup] fieldset"],
      ["birimler", "#/gelismis?sekme=podman&kaynak=birimler", "[data-testid=volumes] tbody tr"],
      ["aglar", "#/gelismis?sekme=podman&kaynak=aglar", "[data-testid=networks] tbody tr"],
    ];
    const SHEETS = [["onarim-kaydi", "#/sistem?kayit=72s", "[data-testid=repair-log-text]"]];
    for (const colorScheme of ["light", "dark"]) {
      for (const [width, height, mobile] of [[1440, 900, false], [390, 844, true], [320, 640, true]]) {
        page = await newPage({ colorScheme, viewport: { width, height }, ...(mobile ? { isMobile: true, hasTouch: true, reducedMotion: "reduce" } : {}) });
        for (const [name, hash, ready] of [...VIEWS, ...SHEETS]) {
          await page.goto(url(hash));
          await page.locator(ready).first().waitFor();
          await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
          await noStyles(page, `${width} ${colorScheme} ${name}`);
          assert(await noHorizontalScroll(page), `${width} ${colorScheme} ${name}`);
          await shot(page, `${width}-${colorScheme}-${name}.png`, !SHEETS.some((s) => s[0] === name));
        }
        if (width === 390) {
          await page.goto(url("#/sistem"));
          assert.equal(await page.locator(".check-table tbody tr").first().evaluate((el) => getComputedStyle(el).display), "grid", "cards on a phone");
          await page.goto(url("#/sistem?kayit=72s"));
          const box = await page.getByRole("dialog", { name: "Onarım kaydı" }).boundingBox();
          assert(Math.abs(box.y + box.height - height) <= 1 && box.width === width, "a bottom sheet on a phone");
        }
        await page.context().close();
      }
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol's Sistem and Gelişmiş under the production CSP — Sağlık (every check with problems first, the last " +
      "repair report with its source and steps, Denetle at once, Onar after a confirmation, a refusal, the report read every 2 s while a run " +
      "goes on, its end through islemler, Onarım kaydı as plain text in a sheet: 72 h / 1 week in the address, newest line, copy, a failed " +
      "read, an empty log), Güncellemeler (Obhut's versions and builds, Yeniden denetle with ?yenile=1, the confirmation's words, a refusal, " +
      "the run's stage through islemler, an earlier run ignored, the reload after success, a failed run without reload, a failed check; the " +
      "applications' image updates with their links, none, never checked), Hesap (create on the tailnet with master_auth's rules, a refusal, " +
      "the tailnet password without the current one, the internet password with it, a wrong current password shown on the form, an ended " +
      "session's 401 to sign-in, the leave guard), Sunucu (facts, the reboot's typed word, a refusal, the wait, the server going away and " +
      "coming back, the reload), no Görünüm, İşlem geçmişi (newest first, every audit kind in words, the fixed kinds in their order, Turkish " +
      "search, the address), the internet channel's locks and sign-out (sidebar and phone menu), Gelişmiş (Caddy's sites with routes, owners " +
      "as their sources, access and scheme, raw files in the address with copy, Yenile, a failed read; DNS from the same read with raw " +
      "sources; the firewall's technical rules and listeners per family, Yenile, an unreadable listener list; Podman's inventory read-only " +
      "with application links, the unmanaged containers read-only, the cleanup: groups, ticks, the dialog naming what goes, the typed word, " +
      "a refusal, the exact body, the job in İşlemler, what went, what stayed and why, nothing to clean, a failed read), Tüm denetimler, the " +
      "palette, keyboard and focus, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
