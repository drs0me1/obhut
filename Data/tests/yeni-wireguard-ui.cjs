/* Konsol's new interface, phase 3 (DD-258): Erişim's WireGuard tab in the committed build under
   Data/console/yeni, with the production CSP and a fixture of the package's own API (/api/uygulama/wireguard,
   magaza/wireguard/api.py) that changes as the page asks (yeni-harness.cjs). Every function of the package's
   page: networks as tabs, on/off, devices (on/off, QR, profile, DNS and keepalive, delete), adding a device
   and a network, the network's name and default DNS with its revision, regenerating and removing (typed
   word); the stopped and the not-installed package; polling only while visible. QR codes and profiles are
   fetched only on a click, with cache "no-store", and their object URLs are revoked. Fails on any console
   error, CSP violation or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-wireguard-ui.cjs */
const assert = require("node:assert/strict");

// ---- fixtures: documentation values only (RFC 5737/6598 addresses, example names)
const NOW = 1791845000;
const CF = "1.1.1.1, 1.0.0.1, 2606:4700:4700::1001";
const QUAD9 = "9.9.9.9, 149.112.112.112, 2620:fe::fe";
const ADGUARD = "94.140.14.14, 94.140.15.15, 2a10:50c0::ad1:ff";
const REV = (c) => c.repeat(64);
// A 1×1 PNG: the page shows the QR from a blob URL and revokes it once the image is decoded.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
const ucell = (durum) => ({ durum, adresler: [], uyari: "", not: "" });
const app = (o) => ({ modul: null, konteyner: null, simge: null, durum: "calisiyor", islem: null, tailscale: ucell("yok"), internet: ucell("yok"),
  kaynak: { cpu: null, bellek: null }, guncelleme: "sabit", adres: { tailscale: null, internet: null }, sayfa: null, eylemler: [], revizyon: null,
  metinler: null, aciklama: "", ...o });
const WG_APP = app({ id: "paket:wireguard", ad: "WireGuard", tur: "paket", modul: "wireguard", simge: "shield", aciklama: "Cihazlarınız için VPN bağlantısı.",
  eylemler: ["durdur", "yeniden-baslat", "kaldir"] });

const peer = (o) => ({ name: "", ipv4: "", ipv6: "", handshake: 0, rx: 0, tx: 0, profile: true, dns: CF, provider: "Cloudflare", keepalive: 21, mtu: 1420,
  enabled: true, online: false, active_at: null, ...o });
const net = (i, o) => ({ iface: `wg${i}`, port: 61001, server4: `10.8.${i}.1`, subnet4: `10.8.${i}.0/24`, server6: `fd42:8:${i}::1`, subnet6: `fd42:8:${i}::/64`,
  dns: CF, label: "", active: true, count: 0, revision: REV(String(i)), peers: [], ...o });
function networks() {
  return [
    net(0, { count: 3, peers: [
      peer({ name: "iphone", ipv4: "10.8.0.2", ipv6: "fd42:8:0::2", handshake: NOW - 30, rx: 52428800, tx: 10485760, online: true, active_at: NOW - 5 }),
      peer({ name: "macbook", ipv4: "10.8.0.3", ipv6: "fd42:8:0::3", handshake: NOW - 3600, rx: 2048, tx: 1024, dns: QUAD9, provider: "Quad9", keepalive: 25 }),
      peer({ name: "tv", ipv4: "10.8.0.4", ipv6: "fd42:8:0::4", handshake: NOW - 90000, enabled: false, keepalive: 0 })] }),
    net(1, { port: 61020, label: "Misafir", dns: ADGUARD, active: false, count: 1, peers: [
      peer({ name: "misafir-tel", ipv4: "10.8.1.2", ipv6: "fd42:8:1::2", dns: ADGUARD, provider: "AdGuard" })] }),
  ];
}
const wg = { state: null };
function reset(o = {}) {
  wg.state = { endpoint: "203.0.113.10", max: 10, reserved: [22, 53, 80, 443, 41641, 61010], defaults: { dns: CF, keepalive: 21, mtu: 1420, port: 61001 },
    now: NOW, active_window: 45, networks: networks(), ...o };
}
reset();

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-248", surum: "1.1.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, interval: 10, read_at: NOW, sampled_at: NOW, cpu: [2.0], mem: { total: 8375186227, used: 696254464, graph: [8.0] },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "ok", read_at: NOW - 60, checks: [{ id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  guncelleme: { kurulu: "2026.08.06-v2-248", kurulu_surum: "1.1.0", son: "2026.08.06-v2-248", son_surum: "1.1.0", commit: "0".repeat(40), yeni: false,
    denetlendi: NOW, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: NOW, alan: "ev", hizmetler: [], uyarilar: [], hatalar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "", surum: "", adresler: [], cikis_dugumu: null },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, not: "", aglar: [] }, sertifikalar: [] } },
  uygulamalar: { read_at: NOW, hatalar: [], katalog: [], altyapi: { podman: "5.4.2", calisiyor: true, imaj: 1, kullanilmayan_imaj: 0, birim: 0, ag: 1 }, items: [WG_APP] },
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-wireguard-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8772", data,
  expected: () => expectedFailures });
const { base, waitFor, newPage, noHorizontalScroll, styleAttributes, shot } = h;

// ---- the package's API, changing as asked
const BASE = "/api/uygulama/wireguard";
const nets = () => wg.state.networks;
const netOf = (iface) => nets().find((n) => n.iface === iface);
let stateStatus = 0;  // a forced status for GET /state
h.handlers[BASE + "/state"] = ({ method }) => {
  if (method !== "GET") return undefined;
  if (stateStatus) return { status: stateStatus, body: { error: "WireGuard kurulu değil" } };
  return { body: JSON.parse(JSON.stringify(wg.state)) };
};
const forced = [];  // replies for the next POSTs to /api/uygulama/wireguard
h.handlers[BASE + "/nets"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  if (forced.length) return forced.shift();
  const used = new Set(nets().map((n) => n.iface));
  let i = 0;
  while (used.has(`wg${i}`)) i += 1;
  nets().push(net(i, { port: Number(body.port), dns: body.dns, label: body.label }));
  return { status: 201, body: { iface: `wg${i}`, port: Number(body.port) } };
};
h.dynamic.push([/^\/api\/uygulama\/wireguard\/nets\/(wg\d)\/(ayarlar|remove|durum|reset|peers)$/, ({ method, body }, m) => {
  if (method !== "POST") return undefined;
  if (forced.length) return forced.shift();
  const n = netOf(m[1]);
  if (!n) return { status: 400, body: { error: "geçersiz arayüz" } };
  switch (m[2]) {
    case "ayarlar":
      if (body.revision !== n.revision) return { status: 409, body: { error: "Ağ ayarları değişmiş; pencereyi kapatıp yeniden açın" } };
      Object.assign(n, { dns: body.dns, label: body.label, revision: REV("e") });
      return { body: { iface: n.iface, dns: body.dns, label: body.label } };
    case "remove":
      wg.state.networks = nets().filter((x) => x !== n);
      return { body: { iface: n.iface, peers: n.peers.length } };
    case "durum":
      n.active = body.on;
      return { body: { iface: n.iface, active: body.on } };
    case "reset": {
      const count = n.peers.length;
      n.peers = [];
      return { body: { peers: count, profiles: count } };
    }
    default: {
      const ipv4 = `10.8.${n.iface.slice(2)}.${n.peers.length + 2}`;
      n.peers.push(peer({ name: body.name, ipv4, ipv6: `fd42:8:${n.iface.slice(2)}::${n.peers.length + 2}`, dns: body.dns, keepalive: body.keepalive, mtu: body.mtu,
        provider: body.dns === ADGUARD ? "AdGuard" : "Özel" }));
      return { status: 201, body: { name: body.name, ipv4 } };
    }
  }
}]);
h.dynamic.push([/^\/api\/uygulama\/wireguard\/nets\/(wg\d)\/peers\/([^/]+)\/(remove|durum|keepalive|dns|qr\.png|profile)$/, ({ method, body }, m) => {
  const n = netOf(m[1]);
  const name = decodeURIComponent(m[2]);
  const p = n?.peers.find((x) => x.name === name);
  if (!p) return { status: 404, body: { error: "peer yok" } };
  if (method === "GET" && m[3] === "qr.png") return { contentType: "image/png", body: PNG, headers: { "Content-Disposition": `attachment; filename="${name}.png"` } };
  if (method === "GET" && m[3] === "profile") {
    return { contentType: "text/plain; charset=utf-8", body: `[Interface]\nAddress = ${p.ipv4}/32\nPrivateKey = fixture\n`,
      headers: { "Content-Disposition": `attachment; filename="${name}.conf"` } };
  }
  if (method !== "POST") return undefined;
  if (forced.length) return forced.shift();
  if (m[3] === "remove") n.peers = n.peers.filter((x) => x !== p);
  else if (m[3] === "durum") p.enabled = body.on;
  else if (m[3] === "keepalive") p.keepalive = body.keepalive;
  else p.dns = body.dns;
  return { body: { ok: true } };
}]);

// ---- helpers
const url = (hash) => new URL("/yeni/" + hash, base).href;
const queryOf = async (page) => new URLSearchParams((await page.evaluate(() => location.hash)).split("?")[1] ?? "");
const wgPosts = (suffix) => h.requests.filter((r) => r.method === "POST" && r.path === BASE + suffix).map((r) => r.body);
const wgGets = (suffix) => h.requests.filter((r) => r.method === "GET" && r.path.startsWith(BASE) && r.path.endsWith(suffix)).length;
const states = () => h.requests.filter((r) => r.method === "GET" && r.path === BASE + "/state").length;
const lastWg = (suffix) => wgPosts(suffix).at(-1);
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
// Records the secret downloads' fetch options and the object URLs made and revoked (an init script, outside the CSP).
async function spy(page) {
  await page.addInitScript(() => {
    window.__secrets = [];
    window.__urls = { made: [], revoked: [] };
    const original = window.fetch;
    window.fetch = function (input, init) {
      const address = typeof input === "string" ? input : input.url;
      if (/\/api\/uygulama\/wireguard\/.*\/(qr\.png|profile)$/.test(address)) window.__secrets.push({ address, cache: init && init.cache });
      return original.apply(this, arguments);
    };
    const make = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (blob) => {
      const made = make(blob);
      window.__urls.made.push(made);
      return made;
    };
    URL.revokeObjectURL = (address) => {
      window.__urls.revoked.push(address);
      revoke(address);
    };
  });
}
const secrets = (page) => page.evaluate(() => window.__secrets);
const objectUrls = (page) => page.evaluate(() => window.__urls);
async function open(options = {}, clock = false) {
  const page = await newPage(options, { clock });
  await spy(page);
  return page;
}
const panel = (page) => page.locator(".modal-sheet");

(async () => {
  h.checkBuild();
  await h.start();
  try {
    // ================= networks as tabs, the network card and its devices
    let page = await open();
    await page.goto(url("#/erisim?sekme=wireguard"));
    const tab = page.getByTestId("wireguard");
    const netTabs = tab.getByRole("tablist", { name: "WireGuard ağları" }).getByRole("tab");
    await netTabs.first().waitFor();
    assert.deepEqual(await netTabs.evaluateAll((ts) => ts.map((t) => [t.querySelector(".tab-label").textContent, t.querySelector(".tab-hint").textContent])),
      [["wg0 · Ana ağ", "1/3 bağlı · UDP 61001"], ["wg1 · Misafir", "Kapalı · UDP 61020"]]);
    const card = tab.locator(".wg-net");
    assert.equal(await card.locator("h2").innerText(), "wg0 · Ana ağ");
    assert.equal(await card.locator(".wg-net-title .meter-note").innerText(), "UDP 61001 · 10.8.0.0/24 · Yalnız internet");
    assert.deepEqual(await card.getByTestId("wg-summary").locator("dd").allInnerTexts(), ["1 / 3 cihaz · 1 kapalı", "61001 · UDP açık", "Yalnız internet", "10.8.0.1/24"]);
    const row = (name) => card.locator(`tr[data-cihaz="${name}"]`);
    assert.deepEqual(await card.getByTestId("device-state").allInnerTexts(), ["Bağlı", "Boşta", "Kapalı"]);
    assert.equal(await row("iphone").locator(".cell-sub").innerText(), "DNS Cloudflare · keepalive 21 sn");
    assert.equal(await row("macbook").locator(".cell-sub").innerText(), "DNS Quad9 · keepalive 25 sn");
    assert.equal(await row("tv").locator(".cell-sub").innerText(), "DNS Cloudflare · keepalive kapalı");
    assert.equal(await row("iphone").locator('td[data-label="Adres"]').innerText(), "10.8.0.2\nfd42:8:0::2");
    assert.deepEqual(await card.locator('td[data-label="Son görülme"]').allInnerTexts(), ["az önce", "60 dakika önce", "—"]);
    assert.equal(await row("iphone").locator(".traffic").innerText(), "↓ 50 MB\n↑ 10 MB");
    assert.equal(wgGets("qr.png") + wgGets("/profile"), 0, "no secret is read before a click");
    await noStyles(page, "wireguard");
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-wireguard.png", true);
    // The selected network is in the address and survives a reload.
    await netTabs.nth(1).click();
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=wireguard&ag=wg1");
    await card.locator("h2").filter({ hasText: "wg1 · Misafir" }).waitFor();
    await card.getByTestId("wg-off").waitFor();
    assert.deepEqual(await card.getByTestId("device-state").allInnerTexts(), ["Ağ kapalı"]);
    assert(await card.getByRole("switch", { name: "misafir-tel bağlantısı" }).isDisabled(), "devices of a stopped network wait");
    assert.equal(await card.getByTestId("wg-summary").locator("dd").first().innerText(), "Kapalı · 1 cihaz bekliyor");
    await page.reload();
    await card.locator("h2").filter({ hasText: "wg1 · Misafir" }).waitFor();
    await shot(page, "1440-light-wireguard-kapali.png", true);
    // Turning a network on is immediate; turning it off asks first.
    await card.getByRole("switch", { name: "wg1 ağı açık" }).click();
    await waitFor(() => wgPosts("/nets/wg1/durum").length === 1, "network on");
    assert.deepEqual(lastWg("/nets/wg1/durum"), { on: true });
    await tab.getByTestId("wg-note").filter({ hasText: "wg1 açıldı: UDP 61020 dinleniyor" }).waitFor();
    await card.getByTestId("wg-off").waitFor({ state: "detached" });
    await card.getByRole("switch", { name: "wg1 ağı açık" }).click();
    const off = page.getByRole("dialog", { name: "wg1 · Misafir kapatılsın mı?" });
    await off.waitFor();
    assert.match(await off.locator(".modal-list").innerText(), /Bu ağdaki 1 cihaz bağlanamaz/);
    assert.equal(wgPosts("/nets/wg1/durum").length, 1, "nothing sent before the answer");
    await off.getByRole("button", { name: "Vazgeç" }).click();
    await off.waitFor({ state: "detached" });
    await card.getByRole("switch", { name: "wg1 ağı açık" }).click();
    await off.getByRole("button", { name: "Ağı kapat" }).click();
    await off.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets/wg1/durum"), { on: false });
    await card.getByTestId("wg-off").waitFor();

    // A device on or off at once.
    await netTabs.first().click();
    await card.locator("h2").filter({ hasText: "wg0 · Ana ağ" }).waitFor();
    await row("tv").getByRole("switch", { name: "tv bağlantısı" }).click();
    await waitFor(() => wgPosts("/nets/wg0/peers/tv/durum").length === 1, "device on");
    assert.deepEqual(lastWg("/nets/wg0/peers/tv/durum"), { on: true });
    await tab.getByTestId("wg-note").filter({ hasText: "tv açıldı: cihaz birkaç saniye içinde kendiliğinden bağlanır." }).waitFor();
    await row("tv").getByRole("switch", { name: "tv bağlantısı", checked: true }).waitFor();

    // ================= the QR code and the profile: fetched on a click, never cached, URLs revoked
    await row("iphone").getByRole("button", { name: "iphone QR kodu" }).click();
    const qr = page.getByRole("dialog", { name: "iphone · QR" });
    await qr.locator("img").waitFor();
    await page.waitForFunction(() => window.__urls.revoked.length === 1);
    let urls = await objectUrls(page);
    assert.deepEqual(urls.revoked, urls.made, "the QR's object URL is revoked once the image is decoded");
    assert.match(await qr.locator("img").getAttribute("src"), /^blob:/);
    assert.equal(await qr.locator("img").getAttribute("alt"), "iphone için WireGuard QR kodu");
    assert.match(await qr.innerText(), /QR ve profil cihazın gizli anahtarını taşır\. Yalnız cihazın kendisine okutun; ekran görüntüsü almayın\./);
    assert.equal(await qr.locator(".modal-desc").innerText(), "wg0 · 10.8.0.2 · Cloudflare DNS");
    assert.deepEqual(await secrets(page), [{ address: "/api/uygulama/wireguard/nets/wg0/peers/iphone/qr.png", cache: "no-store" }]);
    const download = page.waitForEvent("download");
    await qr.getByRole("button", { name: "Profili indir" }).click();
    assert.equal((await download).suggestedFilename(), "iphone.conf");
    assert.deepEqual((await secrets(page))[1], { address: "/api/uygulama/wireguard/nets/wg0/peers/iphone/profile", cache: "no-store" });
    await qr.locator(".modal-foot").getByRole("button", { name: "Kapat" }).click();
    await qr.waitFor({ state: "detached" });
    assert.equal(await page.locator("img[src^='blob:']").count(), 0, "nothing of the QR stays on the page");
    // The profile from the row (revoked after ~10 s; checked with the clock below).
    const rowDownload = page.waitForEvent("download");
    await row("macbook").getByRole("button", { name: "macbook profilini indir (gizli anahtar içerir)" }).click();
    assert.equal((await rowDownload).suggestedFilename(), "macbook.conf");
    assert.equal(wgGets("qr.png"), 1, "the QR was read once, on its click");

    // ================= add a device: name checks, DNS, keepalive, MTU; the QR opens afterwards
    await card.getByTestId("wg-add-device").click();
    let sheet = panel(page);
    await sheet.getByRole("heading", { name: "wg0 ağına cihaz ekle" }).waitFor();
    const go = sheet.getByTestId("panel-go");
    assert(await go.isDisabled());
    await sheet.getByLabel("Cihaz adı").fill("iphone");
    await sheet.getByText("Bu ağda aynı adlı bir cihaz zaten var.").waitFor();
    assert(await go.isDisabled());
    await sheet.getByLabel("Cihaz adı").fill("ipad mini");
    await sheet.getByText("Harf, rakam, nokta, alt çizgi ve tire; en çok 32 karakter.").waitFor();
    await sheet.getByLabel("Cihaz adı").fill("ipad");
    assert.equal(await sheet.locator('[data-dns="Cloudflare"] input').isChecked(), true, "the network's default DNS");
    assert.equal(await sheet.locator('[data-dns="Cloudflare"] .badge').innerText(), "ağın varsayılanı");
    await sheet.locator('[data-dns="AdGuard"]').click();
    assert.equal(await sheet.getByLabel("PersistentKeepalive (saniye)").inputValue(), "21");
    await sheet.getByRole("button", { name: "25 sn" }).click();
    assert.equal(await sheet.getByRole("button", { name: "25 sn" }).getAttribute("aria-pressed"), "true");
    assert.match(await sheet.innerText(), /MTU 1420/);
    await shot(page, "1440-light-wireguard-cihaz-ekle.png");
    await go.click();
    const fresh = page.getByRole("dialog", { name: "ipad · QR" });
    await fresh.locator("img").waitFor();
    assert.deepEqual(lastWg("/nets/wg0/peers"), { name: "ipad", dns: ADGUARD, keepalive: 25, mtu: 1420 });
    await row("ipad").waitFor();
    await fresh.getByRole("button", { name: "Bitti" }).click();
    await fresh.waitFor({ state: "detached" });
    await tab.getByTestId("wg-note").filter({ hasText: "“ipad” eklendi." }).waitFor();

    // ================= a device's DNS and keepalive; afterwards the new QR is offered
    await row("macbook").getByRole("button", { name: "macbook düzenle" }).click();
    sheet = panel(page);
    await sheet.getByRole("heading", { name: "macbook · düzenle" }).waitFor();
    assert.equal(await sheet.locator(".modal-desc").innerText(), "wg0 · 10.8.0.3 · şu an DNS Quad9, keepalive 25 sn");
    assert.equal(await sheet.locator('[data-dns="Quad9"] .badge').innerText(), "şu an");
    assert(await sheet.getByTestId("panel-go").isDisabled(), "nothing changed yet");
    await sheet.locator('[data-dns="Özel"]').click();
    await sheet.getByRole("textbox", { name: "DNS sunucuları · özel adresler" }).fill("192.0.2.53,  2001:db8::53");
    await sheet.getByRole("button", { name: "Kapalı" }).click();
    await sheet.getByTestId("panel-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets/wg0/peers/macbook/dns"), { dns: "192.0.2.53, 2001:db8::53" });
    assert.deepEqual(lastWg("/nets/wg0/peers/macbook/keepalive"), { keepalive: 0 });
    await tab.getByTestId("wg-note").filter({ hasText: "macbook güncellendi: DNS Özel, keepalive kapalı. Cihazda yeni QR'ı okutun." }).waitFor();
    await tab.getByTestId("qr-offer").click();
    await page.getByRole("dialog", { name: "macbook · QR" }).locator("img").waitFor();
    await page.getByRole("dialog", { name: "macbook · QR" }).locator(".modal-foot").getByRole("button", { name: "Kapat" }).click();
    // An invalid custom address is refused before the server.
    await row("macbook").getByRole("button", { name: "macbook düzenle" }).click();
    sheet = panel(page);
    await sheet.getByRole("textbox", { name: "DNS sunucuları · özel adresler" }).fill("dns.example.org");
    await sheet.getByText("Geçerli IPv4 ya da IPv6 adreslerini virgülle ayırarak yazın.").waitFor();
    assert(await sheet.getByTestId("panel-go").isDisabled());
    await sheet.getByRole("button", { name: "Vazgeç" }).click();
    await sheet.waitFor({ state: "detached" });

    // ================= delete a device (asked first)
    await row("tv").getByRole("button", { name: "tv sil" }).click();
    const del = page.getByRole("dialog", { name: "“tv” silinsin mi?" });
    await del.waitFor();
    assert.match(await del.innerText(), /10\.8\.0\.4 adresi boşa çıkar/);
    await del.getByRole("button", { name: "Cihazı sil" }).click();
    await del.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets/wg0/peers/tv/remove"), {});
    await row("tv").waitFor({ state: "detached" });

    // ================= the network's name and default DNS, guarded by its revision
    await card.getByTestId("wg-net-settings").click();
    sheet = panel(page);
    await sheet.getByRole("heading", { name: "wg0 · ağ ayarları" }).waitFor();
    assert.equal(await sheet.locator('[data-dns="Cloudflare"] .badge').innerText(), "kayıtlı");
    await sheet.getByLabel("Ağın adı").fill(" Ev");
    await sheet.getByText("Ağ adının başında ya da sonunda boşluk olamaz.").waitFor();
    await sheet.getByLabel("Ağın adı").fill("Ev ağı");
    await sheet.locator('[data-dns="Quad9"]').click();
    await shot(page, "1440-light-wireguard-ag-ayarlari.png");
    await sheet.getByTestId("panel-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets/wg0/ayarlar"), { dns: QUAD9, revision: REV("0"), label: "Ev ağı" });
    await tab.getByTestId("wg-note").filter({ hasText: "wg0 ayarları kaydedildi. Mevcut anahtarlar ve cihaz profilleri korundu." }).waitFor();
    await card.locator("h2").filter({ hasText: "wg0 · Ev ağı" }).waitFor();
    // Changed meanwhile (another tab): the server refuses the stale revision and the panel says so.
    await card.getByTestId("wg-net-settings").click();
    sheet = panel(page);
    await sheet.getByLabel("Ağın adı").fill("Ev");
    netOf("wg0").revision = REV("f");
    expectedFailures = ["/api/uygulama/wireguard/nets/wg0/ayarlar"];
    await sheet.getByTestId("panel-go").click();
    await sheet.getByTestId("panel-error").filter({ hasText: "Ağ ayarları değişmiş; pencereyi kapatıp yeniden açın" }).waitFor();
    assert.deepEqual(lastWg("/nets/wg0/ayarlar"), { dns: QUAD9, revision: REV("e"), label: "Ev" }, "the revision read when the panel opened");
    expectedFailures = [];

    // ================= regenerate the key (typed word, the devices listed)
    await sheet.getByTestId("wg-regen").click();
    await sheet.getByRole("heading", { name: "wg0 · Ev ağı yeniden üretilsin mi?" }).waitFor();
    assert.match(await sheet.locator(".modal-list").innerText(), /3 cihazın profili ve QR kodu silinir \(iphone, macbook, ipad\)/);
    assert(await sheet.getByTestId("panel-go").isDisabled());
    assert(await sheet.getByLabel("Onaylamak için onayla yazın").evaluate((el) => el === document.activeElement), "the typed word has focus");
    await sheet.getByLabel("Onaylamak için onayla yazın").fill("onayla");
    await sheet.getByTestId("panel-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets/wg0/reset"), { confirm: "onayla" });
    await tab.getByTestId("wg-note").filter({ hasText: "wg0 yeniden üretildi: 3 cihaz silindi, yeni sunucu anahtarı etkin." }).waitFor();
    await card.getByText("Bu ağda henüz cihaz yok").waitFor();

    // ================= add a network: the next free one, port checks, name, DNS
    await tab.getByTestId("wg-add-net").click();
    sheet = panel(page);
    await sheet.getByRole("heading", { name: "Ağ ekle" }).waitFor();
    assert.equal((await sheet.getByTestId("wg-ident").innerText()).replace(/\s+/g, " "), "wg2 10.8.2.0/24 sunucu 10.8.2.1 Yalnız internet");
    assert.equal(await sheet.getByLabel("UDP portu").inputValue(), "61021", "61020 and up, skipping used ports");
    await sheet.getByLabel("UDP portu").fill("61001");
    await sheet.getByText("UDP 61001 kullanımda (wg0); başka bir port yazın.").waitFor();
    await sheet.getByLabel("UDP portu").fill("41641");
    await sheet.getByText("UDP 41641 kullanımda (sunucu); başka bir port yazın.").waitFor();
    await sheet.getByLabel("UDP portu").fill("80");
    await sheet.getByText("1024 ile 65535 arasında bir port yazın.").waitFor();
    assert(await sheet.getByTestId("panel-go").isDisabled());
    await sheet.getByLabel("UDP portu").fill("61030");
    await sheet.getByLabel("Ağın adı · isteğe bağlı").fill("İş");
    assert.match(await sheet.locator(".modal-list").innerText(), /UDP 61030 internete açılır/);
    await sheet.getByTestId("panel-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets"), { port: "61030", dns: CF, label: "İş" });
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=wireguard&ag=wg2");
    await card.locator("h2").filter({ hasText: "wg2 · İş" }).waitFor();
    await tab.getByTestId("wg-note").filter({ hasText: "wg2 oluşturuldu: UDP 61030 açık. Şimdi Cihaz ekle ile cihaz ekleyin." }).waitFor();

    // ================= remove a network (typed word)
    await card.getByTestId("wg-net-settings").click();
    sheet = panel(page);
    await sheet.getByTestId("wg-remove").click();
    await sheet.getByRole("heading", { name: "wg2 · İş kaldırılsın mı?" }).waitFor();
    assert.equal(await sheet.getByTestId("wg-last").count(), 0, "not the last network");
    assert.match(await sheet.locator(".modal-list").innerText(), /UDP 61030 kapanır/);
    await sheet.getByLabel("Onaylamak için onayla yazın").fill("onayla");
    await sheet.getByTestId("panel-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets/wg2/remove"), { confirm: "onayla" });
    await page.waitForURL((u) => u.hash === "#/erisim?sekme=wireguard");
    await tab.getByTestId("wg-note").filter({ hasText: "wg2 kaldırıldı: 0 cihaz silindi, UDP 61030 kapandı." }).waitFor();
    assert.deepEqual(await netTabs.evaluateAll((ts) => ts.map((t) => t.dataset.sekme)), ["wg0", "wg1"]);
    // The last network: the removal says what follows.
    wg.state.networks = [netOf("wg1")];
    await page.reload();
    await card.locator("h2").filter({ hasText: "wg1 · Misafir" }).waitFor();
    await card.getByTestId("wg-net-settings").click();
    await panel(page).getByTestId("wg-remove").click();
    await panel(page).getByTestId("wg-last").waitFor();
    await panel(page).getByRole("button", { name: "Vazgeç" }).click();
    await page.context().close();

    // ================= the limit, no network yet, a refused write
    reset({ max: 2 });
    page = await open();
    await page.goto(url("#/erisim?sekme=wireguard"));
    await page.getByTestId("wg-add-net").waitFor();
    assert(await page.getByTestId("wg-add-net").isDisabled(), "at the limit");
    assert.equal(await page.locator("#wg-sinir").innerText(), "En çok 2 ağ");
    assert.equal(await page.getByTestId("wg-add-net").getAttribute("aria-describedby"), "wg-sinir");
    // A refusal shows the server's words.
    expectedFailures = ["/api/uygulama/wireguard/nets/wg0/peers"];
    forced.push({ status: 400, body: { error: "geçersiz peer adı (harf, rakam, . _ -; en çok 32)" } });
    await page.getByTestId("wg-add-device").click();
    await panel(page).getByLabel("Cihaz adı").fill("tablet");
    await panel(page).getByTestId("panel-go").click();
    await panel(page).getByTestId("panel-error").filter({ hasText: "geçersiz peer adı (harf, rakam, . _ -; en çok 32)" }).waitFor();
    await panel(page).getByRole("button", { name: "Vazgeç" }).click();
    expectedFailures = [];
    await page.context().close();

    reset({ networks: [] });
    page = await open();
    await page.goto(url("#/erisim?sekme=wireguard"));
    await page.getByTestId("wg-empty").getByText("WireGuard yapılandırılmadı").waitFor();
    await shot(page, "1440-light-wireguard-bos.png");
    await page.getByTestId("wg-setup").click();
    sheet = panel(page);
    await sheet.getByRole("heading", { name: "WireGuard'ı yapılandır" }).waitFor();
    assert.equal(await sheet.getByLabel("UDP portu").inputValue(), "61001", "the installation's default port for the first network");
    assert.match(await sheet.getByTestId("wg-ident").innerText(), /wg0/);
    await sheet.getByTestId("panel-go").click();
    await sheet.waitFor({ state: "detached" });
    assert.deepEqual(lastWg("/nets"), { port: "61001", dns: CF, label: "" });
    await page.getByTestId("wireguard").locator(".wg-net h2").filter({ hasText: "wg0 · Ana ağ" }).waitFor();
    await page.context().close();

    // ================= the package stopped: a banner, writes off, secrets still readable
    reset();
    data.uygulamalar = { ...data.uygulamalar, items: [{ ...WG_APP, durum: "durduruldu", eylemler: ["baslat", "kaldir"] }] };
    page = await open();
    await page.goto(url("#/erisim?sekme=wireguard"));
    const stopped = page.getByTestId("wg-stopped");
    await stopped.waitFor();
    assert.equal(await stopped.getByRole("link").getAttribute("href"), "#/uygulamalar/paket:wireguard");
    await page.locator('tr[data-cihaz="iphone"]').waitFor();
    for (const name of ["wg0 ağı açık", "iphone bağlantısı", "macbook bağlantısı"]) assert(await page.getByRole("switch", { name }).isDisabled(), name);
    for (const id of ["wg-add-device", "wg-add-net"]) assert(await page.getByTestId(id).isDisabled(), id);
    assert(await page.getByRole("button", { name: "iphone sil" }).isDisabled());
    assert(await page.getByRole("button", { name: "iphone QR kodu" }).isEnabled(), "the QR stays readable");
    await noStyles(page, "wireguard stopped");
    await shot(page, "1440-light-wireguard-durdu.png", true);
    await page.context().close();

    // ================= not installed: no read of its API, a way to install it
    data.uygulamalar = { ...data.uygulamalar, items: [] };
    const before = states();
    page = await open();
    await page.goto(url("#/erisim?sekme=wireguard"));
    const missing = page.getByTestId("wg-missing");
    await missing.getByText("WireGuard kurulu değil").waitFor();
    assert.equal(await missing.getByRole("link").getAttribute("href"), "#/uygulamalar");
    await page.waitForTimeout(200);
    assert.equal(states(), before, "the package's API is not asked");
    await page.context().close();
    data.uygulamalar = { ...data.uygulamalar, items: [WG_APP] };

    // ================= polling: every 10 s while the tab is shown and the browser tab visible
    reset();
    page = await open({}, true);
    await page.goto(url("#/erisim?sekme=wireguard"));
    await page.locator('tr[data-cihaz="iphone"]').waitFor();
    await page.waitForTimeout(100);
    const s0 = states();
    await page.clock.runFor(10000);
    await waitFor(() => states() === s0 + 1, "read after 10 s");
    // The page skips a tick while a read is in flight; let it take the answer before the clock moves on.
    await page.waitForTimeout(200);
    await page.clock.runFor(10000);
    await waitFor(() => states() === s0 + 2, "and after 20 s");
    // The profile's object URL goes after 10 s.
    const later = page.waitForEvent("download");
    await page.locator('tr[data-cihaz="iphone"]').getByRole("button", { name: /^iphone profilini indir/ }).click();
    await later;
    urls = await objectUrls(page);
    assert.equal(urls.made.length, 1);
    assert.deepEqual(urls.revoked, [], "kept while the download starts");
    await page.clock.runFor(10000);
    await page.waitForFunction(() => window.__urls.revoked.length === 1);
    const s1 = states();
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await page.clock.runFor(30000);
    await page.waitForTimeout(150);
    assert.equal(states(), s1, "no reads while the browser tab is hidden");
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await waitFor(() => states() === s1 + 1, "read when visible again");
    await page.getByRole("tab", { name: "Genel" }).click();
    await page.waitForURL((u) => u.hash === "#/erisim");
    const s2 = states();
    await page.clock.runFor(30000);
    await page.waitForTimeout(150);
    assert.equal(states(), s2, "no reads once another tab is shown");
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes
    for (const colorScheme of ["light", "dark"]) {
      reset();
      page = await open({ colorScheme });
      await page.goto(url("#/erisim?sekme=wireguard"));
      await page.locator('tr[data-cihaz="iphone"]').waitFor();
      await noStyles(page, `1440 ${colorScheme}`);
      assert(await noHorizontalScroll(page), `1440 ${colorScheme}`);
      await shot(page, `1440-${colorScheme}-wireguard.png`, true);
      await page.context().close();
      page = await open({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
      await page.goto(url("#/erisim?sekme=wireguard"));
      await page.locator('tr[data-cihaz="iphone"]').waitFor();
      assert.equal(await page.locator('tr[data-cihaz="iphone"]').evaluate((el) => getComputedStyle(el).display), "grid", "devices as cards");
      await noStyles(page, `390 ${colorScheme}`);
      assert(await noHorizontalScroll(page), `390 ${colorScheme}`);
      await shot(page, `390-${colorScheme}-wireguard.png`, true);
      await page.getByTestId("wg-add-device").tap();
      const box = await panel(page).boundingBox();
      assert(Math.abs(box.y + box.height - 844) <= 1 && box.width === 390, "the side panel is a bottom sheet on a phone");
      await shot(page, `390-${colorScheme}-wireguard-panel.png`);
      await panel(page).locator(".modal-close").tap();
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320);
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await noStyles(page, `320 ${colorScheme}`);
      assert(await noHorizontalScroll(page), `320 ${colorScheme}`);
      await shot(page, `320-${colorScheme}-wireguard.png`, true);
      await page.context().close();
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: /yeni/ phase 3 WireGuard under the production CSP — networks as tabs (label, port, x/y bağlı, Kapalı, ?ag= across a " +
      "reload), the network card (summary, on at once, off asked first), devices (state, DNS provider and keepalive, addresses, last seen, " +
      "traffic, on/off at once), QR and profile only on a click with cache no-store and revoked object URLs (QR on load, profile after 10 s), " +
      "add device (duplicate and name checks, DNS presets, keepalive chips, MTU, the QR afterwards), DNS and keepalive (custom DNS, invalid " +
      "custom refused, the new QR offered), delete, the network's name and default DNS with its revision (409 on a stale one), regenerate and " +
      "remove with the typed word (devices listed, last network warned), add network (next wgN, port checks against networks and reserved " +
      "ports, name), the limit, no network yet, a refused write, the stopped package, not installed, polling every 10 s only while shown and " +
      "visible, 1440/390/320 in light and dark. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
