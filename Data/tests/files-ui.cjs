/* Production Files UI: independent account forms, navigation, list/cards, mobile. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const shots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-v128-files-"));
const shares = { enabled: true, running: true, max: 32, host: "http://100.64.0.2:61010", items: [] };
let submitted;
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.route("**/api/**", async (route) => {
      const req = route.request(), url = new URL(req.url()), p = url.pathname;
      let result;
      if (p === "/api/konsol/moduller") result = { items: ["wireguard", "torrent"].map((id) => ({ id, installed: false, state: "yok", runtime: id === "wireguard" ? "konsol" : "host", live: "-" })) };
      else if (p === "/api/archives") result = {items:[], limits:{bytes:2147483648,entries:10000,layers:5,seconds:900}};
      else if (p === "/api/wg/sistem") result = { host: "nrm", version: "v128", domain: "ayc", os: "Debian 13", kernel: "test", uptime: 300, cores: 2, cpu: [1], mem: { total: 10000, used: 200, graph: [20] }, net: { wan: "192.0.2.1", tailscale: "100.64.0.2" }, root: "/srv", disk: { total: 100000, free: 80000 }, ports: [{ port: 22, proto: "tcp", scope: "internet", name: "SSH" }] };
      else if (p === "/api/wg/islemler") result = { items: [] };
      else if (p === "/api/state") result = { root: "/srv", temp: "downloads/incomplete", disk: { total: 100000, free: 80000 }, trash: { count: 0, size: 0 } };
      else if (p === "/api/list") result = { path: url.searchParams.get("path") || "", entries: (url.searchParams.get("path") ? ["movies", "series"] : ["media", "downloads", "Belgeler ve uzun klasör adı"]).map((name) => ({ name, type: "dir", count: 2, size: 1024, mtime: Date.now() / 1000 })) };
      else if (p === "/api/konsol/paylasim") result = shares;
      else if (p === "/api/konsol/paylasim/kaydet") {
        submitted = req.postDataJSON();
        const id = submitted.id || "a".repeat(24);
        let s = shares.items.find((i) => i.id === id);
        if (!s) { s = { id, paused: false, available: true, expired: false, created: Date.now() / 1000, expires: null }; shares.items.push(s); }
        Object.assign(s, { name: submitted.path.split("/").pop(), path: submitted.path, username: submitted.username, permission: submitted.permission, url: shares.host + "/s/" + id + "/" });
        result = shares;
      } else if (p.endsWith("/durum")) { const d = req.postDataJSON(); shares.items.find((s) => s.id === d.id).paused = d.paused; result = shares; }
      else if (p.endsWith("/kaldir")) { const d = req.postDataJSON(); shares.items = shares.items.filter((s) => s.id !== d.id); result = shares; }
      else if (p === "/api/trash") result = { items: [] };
      else throw new Error("Unexpected endpoint: " + p);
      await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(result) });
    });
    await page.goto((process.env.KONSOL_URL || "http://127.0.0.1:8766") + "/#/dosyalar");
    await page.getByRole("button", { name: "media ayrıntıları", exact: true }).click();
    assert.match(await page.locator("#fs-detail").innerText(), /media/);
    await page.screenshot({ path: path.join(shots, "desktop-list.png"), fullPage: true });
    await page.getByRole("button", { name: "WebDAV ile paylaş", exact: true }).click();
    assert.equal(await page.getByLabel("Erişim izni", { exact: true }).inputValue(), "ro");
    await page.getByLabel("Kullanıcı adı", { exact: true }).fill("family-media");
    await page.getByLabel("Parola", { exact: true }).fill("ui-test-only-secret");
    await page.getByLabel("Erişim izni", { exact: true }).selectOption("rw");
    assert(await page.locator("#dav-ack").evaluate((input) => input.required));
    await page.locator("#dav-ack").check();
    await page.screenshot({ path: path.join(shots, "editor.png"), fullPage: true });
    await page.getByRole("button", { name: "Paylaşımı oluştur", exact: true }).click();
    await page.waitForFunction(() => !document.querySelector("#sh").open);
    assert.equal(submitted.permission, "rw");
    assert.equal(submitted.ack_write, true);
    assert.equal(submitted.password, "ui-test-only-secret");
    assert(!JSON.stringify(await page.evaluate(() => ({ ...localStorage }))).includes("secret"));
    await page.locator("#fs-tabs").getByRole("button", { name: "Paylaşımlar", exact: true }).click();
    await page.getByRole("button", { name: "Yönet", exact: true }).click();
    assert.equal(await page.getByLabel("Yeni parola (isteğe bağlı)", { exact: true }).inputValue(), "");
    await page.getByLabel("Erişim izni", { exact: true }).selectOption("ro");
    await page.getByRole("button", { name: "Güncelle", exact: true }).click();
    await page.waitForFunction(() => !document.querySelector("#sh").open);
    assert.equal(submitted.password, "");
    assert.equal(submitted.days, null);
    await page.getByRole("switch", { name: "media paylaşımı duraklatılmamış" }).click();
    await page.getByText("Duraklatıldı", { exact: true }).waitFor();
    for (const width of [1440, 1024, 736, 390, 320]) {
      await page.setViewportSize({ width, height: 950 });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `shares overflow ${width}`);
      await page.getByRole("button", { name: "Klasörler", exact: true }).click();
      for (const mode of ["Kartlar", "Liste"]) {
        await page.getByRole("button", { name: mode, exact: true }).click();
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${mode} overflow ${width}`);
      }
      await page.locator("#fs-tabs").getByRole("button", { name: "Paylaşımlar", exact: true }).click();
    }
    await page.emulateMedia({ colorScheme: "dark" });
    await page.screenshot({ path: path.join(shots, "mobile-shares-dark.png"), fullPage: true });
    await page.getByRole("button", { name: "Klasörler", exact: true }).click();
    await page.getByRole("button", { name: "Kartlar", exact: true }).click();
    await page.screenshot({ path: path.join(shots, "mobile-cards-dark.png"), fullPage: true });
    await page.getByRole("button", { name: "Klasörü aç", exact: true }).click();
    await page.getByRole("button", { name: "movies ayrıntıları", exact: true }).waitFor();
    await page.getByRole("searchbox", { name: "Bu klasörde ara" }).fill("series");
    assert.equal(await page.getByRole("button", { name: "movies ayrıntıları", exact: true }).count(), 0);
    assert.equal(await page.getByRole("button", { name: "series ayrıntıları", exact: true }).count(), 1);
    assert.deepEqual(errors, []);
    console.log("PASS: Files forms/default RO/RW acknowledgement/save/edit/blank password/expiry preservation/pause/navigation/search/list/cards, 5 viewports. Screenshots: " + shots);
  } finally { await browser.close(); }
})().catch((e) => { console.error(e); process.exit(1); });
