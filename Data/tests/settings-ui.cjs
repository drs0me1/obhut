/* Real production UI with deterministic API fixtures; no server mutations. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const screenshots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-v127-ui-"));
const copy = (x) => JSON.parse(JSON.stringify(x));
const config = { firewall: [], dns: { disabled: [], records: [], forward: false, servers: [] } };
const data = {
  read_at: 1780000000, version: "2026.08.06-v2-127", domain: "ayc", tailscale: "100.64.0.2", ts_if: "tailscale0", wan: { iface: "eth0", ipv4: "192.0.2.1" },
  firewall: { ok: true, check: "ok", ports: [{ name: "SSH", family: 4, scope: "wan", port: 22, proto: "tcp", baseline: true },
      { name: "Caddy", family: 4, scope: "tail", port: 80, proto: "tcp", baseline: true }, { name: "Caddy", family: 4, scope: "wan", port: 80, proto: "tcp", baseline: false }],
    listeners: [{ port: 22, proto: "tcp", family: 4, address: "0.0.0.0" }],
    rules: { errors: [], rows: [{ family: 4, table: "filter", chain: "ts-input", position: 1, packets: 12, bytes: 1024, spec: "-i tailscale0 -j ACCEPT", owner: "Tailscale" }] } },
  web: { entries: [{ address: "panel.ayc", source: "base", access: "tailscale", routes: [{ kind: "proxy", path: "/api/*", to: "127.0.0.1:61008" }] }], raw: [] },
  dns: { listen: ["lo", "tailscale0"] }, torrent: { installed: true, profile: "/var/lib/qbittorrent" },
  manage: { revision: "r1", config: copy(config), pending: null, username: "admin", save: "/srv/downloads/", names: [{ name: "panel.ayc", target: "tailscale", source: "base" }, { name: "torrent.ayc", target: "tailscale", source: "torrent" }] },
};
let lastApply = null;
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.route("**/api/**", async (route) => {
      const url = new URL(route.request().url()), endpoint = url.pathname;
      let result = {};
      if (endpoint === "/api/konsol/moduller") result = { items: [{ id: "torrent", installed: true, state: "calisiyor", runtime: "host", live: "running" }] };
      else if (endpoint === "/api/wg/sistem") result = { host: "test", version: data.version, domain: "ayc", os: "Debian 13", kernel: "test", uptime: 120, cores: 2, cpu: [1], mem: { total: 1000, used: 200, graph: [20] }, net: { wan: "192.0.2.1", tailscale: data.tailscale }, root: "/srv", disk: { total: 1000, free: 800 }, ports: [{ port: 22, proto: "tcp", scope: "internet", name: "SSH" }] };
      else if (endpoint === "/api/wg/islemler") result = { items: [] };
      else if (endpoint === "/api/state") result = {root:"/srv", temp:"downloads/incomplete", disk:{total:10000,free:8000}, trash:{count:0,size:0}};
      else if (endpoint === "/api/list") result = {path:"",entries:[]};
      else if (endpoint === "/api/archives") result = {items:[], limits:{bytes:2147483648,entries:10000,layers:5,seconds:900}};
      else if (endpoint === "/api/konsol/ayarlar") result = data;
      else if (endpoint === "/api/konsol/ayarlar/durum") result = data.manage;
      else if (endpoint === "/api/konsol/ayarlar/klasorler") result = { items: [{ path: "/srv/downloads", free: 10000000000 }, { path: "/srv/media", free: 10000000000 }] };
      else if (endpoint === "/api/konsol/ayarlar/uygula") {
        lastApply = route.request().postDataJSON();
        if (lastApply.firewall) data.manage.config.firewall = copy(lastApply.firewall);
        if (lastApply.dns) data.manage.config.dns = copy(lastApply.dns);
        data.manage.pending = { id: "transaction", seconds: 60, phase: "awaiting" };
        if (lastApply.domain) {
          data.manage.pending.domain = { old: "ayc", new: lastApply.domain };
          data.manage.pending.seconds = 300;
        }
        result = { pending: data.manage.pending };
      } else if (endpoint.endsWith("/onayla")) { data.manage.pending = null; data.manage.revision = "r2"; result = { ok: true }; }
      else if (endpoint.endsWith("/geri-al")) { data.manage.pending = null; data.manage.config = copy(config); result = { ok: true }; }
      else throw new Error("Unexpected endpoint " + endpoint);
      await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(result) });
    });
    await page.goto((process.env.KONSOL_URL || "http://127.0.0.1:8766") + "/#/ayarlar");
    await page.getByRole("tab", { name: "Güvenlik Duvarı" }).waitFor();
    assert.match(await page.locator(".as-ports").innerText(), /Tüm IPv4 arayüzlerinde dinler/);
    await page.getByRole("switch", { name: "SSH İnternet tcp 22", exact: true }).click();
    assert.match(await page.locator(".as-footer").innerText(), /1 değişiklik/);
    await page.getByRole("button", { name: "Vazgeç", exact: true }).click();
    assert.equal(await page.getByRole("switch", { name: "SSH İnternet tcp 22", exact: true }).getAttribute("aria-checked"), "true");
    await page.getByRole("button", { name: "Tüm kurallar", exact: true }).click();
    assert.match(await page.locator(".as-rules").innerText(), /ts-input/);
    await page.getByRole("tab", { name: "Caddy", exact: true }).click();
    assert.match(await page.locator("#cfg-web").innerText(), /panel.ayc/);
    await page.getByRole("tab", { name: "Dnsmasq", exact: true }).click();
    await page.getByRole("switch", { name: "torrent.ayc", exact: true }).click();
    await page.getByRole("button", { name: "+ Alan adı", exact: true }).click();
    await page.getByRole("textbox", { name: "Tam alan adı" }).fill("nas.ayc");
    await page.getByRole("button", { name: "Devam et" }).click();
    await page.getByRole("switch", { name: "Üst DNS'e yönlendirme", exact: true }).click();
    await page.getByLabel("Sağlayıcı", { exact: true }).selectOption("google");
    await page.getByRole("tab", { name: "qBittorrent", exact: true }).click();
    await page.getByRole("textbox", { name: "Kullanıcı adı", exact: true }).fill("newuser");
    await page.getByLabel("Yeni parola", { exact: true }).fill("sample-ui-only-password");
    await page.getByLabel("Yeni parola (tekrar)", { exact: true }).fill("sample-ui-only-password");
    await page.getByRole("button", { name: "Hesabı taslağa ekle", exact: true }).click();
    assert.equal(await page.getByLabel("Yeni parola", { exact: true }).inputValue(), "");
    await page.getByRole("button", { name: "Klasör seç", exact: true }).click();
    await page.locator(".as-folder").filter({ hasText: "/srv/media" }).getByRole("button", { name: "Seç", exact: true }).click();
    await page.getByRole("button", { name: "İncele ve uygula" }).click();
    assert.match(await page.locator(".as-changes").innerText(), /nas.ayc/);
    assert(!((await page.locator(".as-dialog").innerText()).includes("sample-ui-only-password")));
    await page.getByRole("button", { name: "Sunucuda uygula", exact: true }).click();
    await page.getByRole("button", { name: "Bağlantı çalışıyor · onayla" }).waitFor();
    assert.deepEqual(lastApply.dns.servers, ["8.8.8.8", "8.8.4.4"]);
    assert.equal(lastApply.torrent.save, "/srv/media");
    assert.equal(lastApply.torrent.password, "sample-ui-only-password");
    await page.getByRole("button", { name: "Bağlantı çalışıyor · onayla" }).click();
    await page.waitForFunction(() => !document.querySelector(".as-rollback"));
    await page.getByRole("tab", { name: "Güvenlik Duvarı" }).click();
    await page.getByRole("button", { name: "Portlar", exact: true }).click();
    await page.getByRole("button", { name: "+ Port kuralı", exact: true }).click();
    await page.getByRole("textbox", { name: "Ad", exact: true }).fill("Test port");
    await page.getByRole("spinbutton", { name: "Port", exact: true }).fill("12345");
    await page.getByRole("button", { name: "Devam et" }).click();
    await page.getByRole("button", { name: "İncele ve uygula" }).click();
    await page.getByRole("button", { name: "Sunucuda uygula", exact: true }).click();
    await page.getByRole("button", { name: "Geri al", exact: true }).click();
    await page.waitForFunction(() => !document.querySelector(".as-rollback"));
    assert.equal(await page.locator(".as-ports").getByText("Test port", { exact: true }).count(), 0);
    await page.screenshot({ path: path.join(screenshots, "desktop.png"), fullPage: true });
    await page.getByRole("tab", { name: "Caddy", exact: true }).click();
    await page.getByRole("textbox", { name: "Yerel alan adı", exact: true }).fill("bad.example");
    assert.equal(await page.getByRole("textbox", { name: "Yerel alan adı", exact: true }).evaluate((el) => el.checkValidity()), false);
    await page.getByRole("textbox", { name: "Yerel alan adı", exact: true }).fill("ev");
    await page.getByRole("button", { name: "Güncelle", exact: true }).click();
    assert.match(await page.locator(".as-dialog").innerText(), /Restrict to domain/);
    assert.match(await page.locator(".as-dialog").innerText(), /http:\/\/panel.ev/);
    await page.getByRole("button", { name: "Alan adını güncelle", exact: true }).click();
    await page.locator(".as-rollback").waitFor();
    assert.equal(lastApply.domain, "ev");
    assert.deepEqual(Object.keys(lastApply).sort(), ["domain", "revision"]);
    assert(await page.getByRole("button", { name: "Bağlantı çalışıyor · onayla" }).isDisabled());
    assert.equal(await page.getByRole("link", { name: "Yeni Konsol'u aç: panel.ev" }).getAttribute("href"), "http://panel.ev/#/ayarlar");
    await page.screenshot({ path: path.join(screenshots, "domain-change.png"), fullPage: true });
    await page.getByRole("button", { name: "Geri al", exact: true }).click();
    await page.waitForFunction(() => !document.querySelector(".as-rollback"));
    for (const width of [1024, 736, 390, 320]) {
      await page.setViewportSize({ width, height: 900 });
      for (const name of ["Güvenlik Duvarı", "Caddy", "Dnsmasq", "qBittorrent"]) {
        await page.getByRole("tab", { name, exact: true }).click();
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `overflow at ${width} / ${name}`);
      }
    }
    await page.emulateMedia({ colorScheme: "dark" });
    await page.getByRole("tab", { name: "Dnsmasq", exact: true }).click();
    await page.screenshot({ path: path.join(screenshots, "mobile-dark.png"), fullPage: true });
    assert.deepEqual(errors, []);
    assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
    console.log("PASS: tabs, draft/discard, address descriptions, firewall rules, DNS/provider, credentials/path, domain validation/review/links/old-host refusal, apply/confirm/rollback, 4 viewports, no JS errors. Screenshots: " + screenshots);
  } finally { await browser.close(); }
})().catch((err) => { console.error(err); process.exit(1); });
