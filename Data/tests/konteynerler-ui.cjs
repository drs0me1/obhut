/* Settings → Konteynerler (DD-208): the base's read-only Podman view on the real console assets
   under the production CSP; every API call is fixtured and read-only, no server is modified.
   Also covers the deep link an application page uses (#/ayarlar/konteynerler/<name>). Covers the runtime head, the container list (state pills, port summary,
   unit, mounts), the single open detail (mounts table, ports table or host note, labels as text),
   the log tail (default 200, switch to 500, masked values, scroll follow), the runtime error and
   empty states, that nothing but GET ever leaves the page, four widths and the dark theme. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const shots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-konteynerler-ui-"));
const base = process.env.KONSOL_URL || "http://127.0.0.1:8766";
const csp = fs.readFileSync(path.join(__dirname, "../templates/Caddyfile"), "utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
// Podman is base infrastructure: no App Store item, no application page.
const modules = [];
const now = Math.floor(Date.now() / 1000);
const runtime = { version: "5.4.2", ok: true, error: "" };
const containers = [
  { id: "2073a1b2c3d4", name: "deneme-web", image: "docker.io/library/nginx:1.27", state: "running", status: "Up 9 minutes", created: now - 3600, started: now - 540,
    exit_code: 0, restarts: 0, unit: "deneme-web.service", network: "host", ports: [], mounts: 0 },
  { id: "9f8e7d6c5b4a", name: "arsiv-db", image: "docker.io/library/postgres:16", state: "exited", status: "Exited (1) 2 hours ago", created: now - 2 * 86400, started: now - 7300,
    exit_code: 1, restarts: 3, unit: "", network: "bridge",
    ports: [{ host_ip: "0.0.0.0", host_port: 61016, container_port: 8080, protocol: "tcp" }, { host_ip: "127.0.0.1", host_port: 61017, container_port: 5432, protocol: "tcp" }], mounts: 2 },
];
const details = {
  "deneme-web": { name: "deneme-web", id: "2073a1b2c3d4", image: "docker.io/library/nginx:1.27", image_digest: "a1b2c3d4e5f6", state: "running", status: "", created: now - 3600,
    started: now - 540, finished: now - 4000, exit_code: 0, restarts: 2, unit: "deneme-web.service", network: "host", health: "healthy", ports: [], mounts: [],  // inspect keeps the old FinishedAt while running
    labels: { version: "1.27.0", source: "https://example.invalid/deneme-web", title: "Deneme Web" }, command: "nginx -g daemon off;" },
  "arsiv-db": { name: "arsiv-db", id: "9f8e7d6c5b4a", image: "docker.io/library/postgres:16", image_digest: "9f8e7d6c5b4a", state: "exited", status: "", created: now - 2 * 86400,
    started: now - 7300, finished: now - 7200, exit_code: 1, restarts: 3, unit: "", network: "bridge", health: "",
    ports: [{ host_ip: "0.0.0.0", host_port: 61016, container_port: 8080, protocol: "tcp" }, { host_ip: "127.0.0.1", host_port: 61017, container_port: 5432, protocol: "tcp" }],
    mounts: [{ type: "bind", source: "/var/lib/master-stack/arsiv-db/config", destination: "/config", rw: true, name: "" },
      { type: "volume", source: "/var/lib/containers/storage/volumes/arsiv-data/_data", destination: "/var/lib/postgresql/data", rw: false, name: "arsiv-data" }],
    labels: { version: "", source: "", title: "" }, command: "postgres" },
};
let shown = containers, logVersion = 0;
// The backend masks secret values before they leave the server; the page shows the lines as they come.
const logLines = (n) => Array.from({ length: n }, (_, i) =>
  `2026-10-02T22:${String(Math.floor(i / 60) % 60).padStart(2, "0")}:${String(i % 60).padStart(2, "0")}+02:00 satır ${i + 1} sürüm ${logVersion}${i === n - 1 ? " token=••••" : ""}`);
const writes = [], errors = [], listReads = [], detailReads = [], logReads = [], settingsReads = [];
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    await context.route("**/*", async (route) => {
      const p = new URL(route.request().url()).pathname;
      if (route.request().resourceType() !== "document") return route.continue();
      const response = await route.fetch();
      await route.fulfill({ response, headers: { ...response.headers(), "content-security-policy": csp } });
    });
    const page = await context.newPage();
    await page.clock.install();
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (/violates.*Content Security Policy|Refused to/.test(m.text())) errors.push(m.text()); });
    await page.route("**/api/**", async (route) => {
      const req = route.request(), url = new URL(req.url()), p = url.pathname;
      if (req.method() !== "GET") writes.push({ method: req.method(), path: p });
      let result = {};
      if (p === "/api/konsol/moduller") result = { items: modules };
      else if (p === "/api/konsol/konteynerler/liste") {
        listReads.push(1);
        result = { read_at: Math.floor(Date.now() / 1000), runtime: { ...runtime }, containers: runtime.ok ? shown : [],
          images: runtime.ok ? [{ name: "docker.io/library/nginx:1.27", size: 190 * 1024 ** 2, created: now - 86400 }, { name: "docker.io/library/postgres:16", size: 322 * 1024 ** 2, created: now - 86400 }] : [],
          storage: { images: runtime.ok ? 2 : 0, containers: runtime.ok ? shown.length : 0, size: runtime.ok ? 512 * 1024 ** 2 : null } };
      }
      else if (p === "/api/konsol/konteynerler/ayrinti") {
        const name = url.searchParams.get("ad");
        detailReads.push(name);
        if (!details[name]) return route.fulfill({ status: 404, contentType: "application/json", body: JSON.stringify({ error: "Konteyner bulunamadı" }) });
        result = details[name];
      }
      else if (p === "/api/konsol/konteynerler/gunluk") {
        const name = url.searchParams.get("ad"), tail = Number(url.searchParams.get("satir") || 200);
        logReads.push(`${name}:${tail}`);
        assert([100, 200, 500, 1000].includes(tail), "tail is one of the allowed values");
        result = { name, lines: logLines(tail), truncated: tail < 1000, masked: true };
      }
      else if (p === "/api/konsol/kaynaklar") result = { host: "test", version: "test", domain: "ayc", os: "Debian 13", kernel: "test", uptime: 120, cores: 2, cpu: [1],
        mem: { total: 1000, used: 200 }, disk: { total: 1000, free: 500 }, root: "/srv", net: { tailscale: "100.64.0.2", wan: "192.0.2.1" }, read_at: Date.now() / 1000, sampled_at: Date.now() / 1000 };
      else if (p === "/api/konsol/saglik") result = { status: "ok", read_at: 1, checks: [] };
      else if (p === "/api/konsol/oturum") result = { durum: "giris", kullanici: "fixture", kanal: "tailscale" };
      else if (p === "/api/state") result = { root: "/srv", downloads: "downloads", protected: [], trash: { count: 0, size: 0 }, disk: { total: 1000, free: 500 } };
      else if (p === "/api/list") result = { path: "", entries: [] };
      else if (p === "/api/konsol/paylasim") result = { enabled: true, running: true, max: 32, host: "http://100.64.0.2:61010", items: [] };
      else if (p === "/api/konsol/duzen") result = { duzen: null };
      // Only the Sistem tab (visited by the deep-link check) reads the settings; the Konteynerler tab never does.
      else if (p === "/api/konsol/ayarlar") { settingsReads.push(1); result = { read_at: Math.floor(Date.now() / 1000), manage: { error: "fixture" } }; }
      else if (p === "/api/konsol/ag") result = { read_at: 0, iface: "eth0", window: 120, points: [], apps: [] };
      else if (p === "/api/trash" || p === "/api/konsol/islemler" || p === "/api/archives") result = { items: [] };
      else {
        errors.push("Unexpected endpoint: " + req.method() + " " + p);
        return route.fulfill({ status: 404, contentType: "application/json", body: JSON.stringify({ error: "unexpected fixture request" }) });
      }
      await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(result) });
    });
    const rows = page.locator("#pd-list .pd-row");
    const row = (name) => page.locator(`#pd-list .pd-row[data-name="${name}"]`);
    const detail = page.locator("#pd-detail");
    const head = page.locator("#pd-head");
    const refresh = () => page.locator("#top-actions").getByRole("button", { name: "Yenile", exact: true }).click();
    const squash = (s) => s.replace(/\s+/g, " ").trim();
    // Text nodes joined by spaces: CSS uppercases the small labels, so innerText would not show what the page wrote.
    const text = (loc) => loc.evaluate((el) => {
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), parts = [];
      while (walker.nextNode()) parts.push(walker.currentNode.textContent);
      return parts.join(" ");
    }).then(squash);
    const noOverflow = async (label) => {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `no horizontal page scroll: ${label}`);
      assert(await page.evaluate(() => [...document.querySelectorAll("#pd-head, #pd-list, #pd-detail, #pd-log, .pd-t")]
        .every((el) => el.getBoundingClientRect().right <= innerWidth + 1 && el.getBoundingClientRect().left >= -1)), `page blocks inside the viewport: ${label}`);
    };

    await page.goto(base + "/#/ayarlar/konteynerler");
    await rows.first().waitFor();
    // Shell: a Settings tab, not an application; the sidebar lists no Podman page.
    assert.equal(await page.locator("#title").innerText(), "Ayarlar");
    assert.deepEqual(await page.getByRole("tab").allInnerTexts(), ["Sistem", "Güvenlik Duvarı", "Caddy", "Dnsmasq", "Konteynerler", "Günlük"]);
    assert.equal(await page.getByRole("tab", { name: "Konteynerler", exact: true }).getAttribute("aria-selected"), "true");
    assert.equal(await page.locator(".nav a[data-app]").count(), 0, "no application link in the sidebar");
    assert.equal(await page.locator(".as-footer").count(), 0, "a read-only tab has no draft footer");
    // Head card: runtime pill, counts, last read.
    assert.equal(await head.locator(".hm.ok").innerText(), "Podman 5.4.2 · çalışıyor");
    const counts = await text(head.locator(".pd-counts"));
    for (const t of ["Konteyner 2 1 çalışıyor", "İmaj 2", "Depolama 512 MB"]) assert(counts.includes(t), `counts show "${t}": ${counts}`);
    assert.match(await page.locator("#cfg-stamp").innerText(), /^Son okuma \d{2}:\d{2}$/);
    // List: one row per container, state pills, name, image, time, unit, port summary and mount count.
    assert.equal(await rows.count(), 2);
    assert.equal(await row("deneme-web").locator(".pd-state").innerText(), "Çalışıyor");
    assert(await row("deneme-web").locator(".pd-state").evaluate((el) => el.classList.contains("ok")), "running → ok pill");
    assert.equal(await row("arsiv-db").locator(".pd-state").innerText(), "Durdu (çıkış 1)");
    assert(await row("arsiv-db").locator(".pd-state").evaluate((el) => el.classList.contains("idle")), "exited → idle pill");
    assert.equal(await row("deneme-web").locator("strong").innerText(), "deneme-web");
    assert.equal(await row("arsiv-db").locator(".pd-image").innerText(), "docker.io/library/postgres:16");
    assert.match(await row("deneme-web").locator(".pd-meta").innerText(), /^Başladı \d+ dk önce/);
    assert.match(await row("arsiv-db").locator(".pd-meta").innerText(), /^Oluşturuldu 2 gün önce · 3 yeniden başlatma$/);
    assert.equal(await row("deneme-web").locator(".pd-unit").innerText(), "deneme-web.service");
    assert.equal(await row("arsiv-db").locator(".pd-unit").count(), 0, "no unit line without a unit");
    assert.equal(await row("deneme-web").locator(".pd-ports").innerText(), "host ağı");
    assert.equal(await row("arsiv-db").locator(".pd-ports").innerText(), "61016→8080/tcp, 61017→5432/tcp");
    assert.equal(await row("deneme-web").locator(".pd-mounts").innerText(), "bağlama yok");
    assert.equal(await row("arsiv-db").locator(".pd-mounts").innerText(), "2 bağlama");
    assert.equal(await page.locator("#pd-detail").count(), 0, "nothing open at first");
    assert.deepEqual(detailReads, [], "no detail read before a row is opened");
    for (const name of ["deneme-web", "arsiv-db"]) assert.equal(await row(name).locator(".pd-rowbtn").getAttribute("aria-expanded"), "false");

    // Detail of the stopped container: mounts table, ports table (specific host IP shown), facts.
    await row("arsiv-db").locator(".pd-rowbtn").click();
    await detail.locator("#pd-mounts .tr:not(.head)").first().waitFor();
    assert.deepEqual(detailReads, ["arsiv-db"]);
    assert.equal(await row("arsiv-db").locator("#pd-detail").count(), 1, "the detail sits inside the open row");
    assert.equal(await row("arsiv-db").locator(".pd-rowbtn").getAttribute("aria-expanded"), "true");
    assert.equal(await text(detail.locator("#pd-mounts .tr.head")), "Konteyner yolu Sunucu yolu Erişim Tür");
    const mountRows = (await detail.locator("#pd-mounts .tr:not(.head)").allInnerTexts()).map(squash);
    assert.equal(mountRows.length, 2);
    assert.equal(mountRows[0], "/config /var/lib/master-stack/arsiv-db/config RW Klasör (bind)");
    assert.equal(mountRows[1], "/var/lib/postgresql/data /var/lib/containers/storage/volumes/arsiv-data/_data RO Birim (volume)");
    assert.equal(await text(detail.locator("#pd-ports .tr.head")), "Sunucu Konteyner Protokol");
    const portRows = (await detail.locator("#pd-ports .tr:not(.head)").allInnerTexts()).map(squash);
    assert.deepEqual(portRows, ["61016 8080 tcp", "61017 127.0.0.1 5432 tcp"]);
    assert.equal(await detail.locator("#pd-ports .as-note").count(), 0, "bridge network: no host note");
    let facts = await text(detail.locator("#pd-facts"));
    for (const t of ["Durum Durdu (çıkış 1)", "Sağlık —", "Kimlik 9f8e7d6c5b4a", "İmaj docker.io/library/postgres:16 sha256:9f8e7d6c5b4a…", "Ağ bridge",
      "Başladı 2 sa önce", "Bitti 2 sa önce", "çıkış 1", "Yeniden başlatma 3", "Birim —", "Komut postgres"]) assert(facts.includes(t), `facts show "${t}": ${facts}`);
    assert(!facts.includes("Sürüm") && !facts.includes("Kaynak") && !facts.includes("Başlık"), "empty labels are not listed");
    assert(!facts.includes("Exited"), "no English Podman status text in the detail");
    assert.equal(await detail.locator("a").count(), 0, "no links in the detail");

    // Switching rows keeps a single detail; host networking shows the note; labels are plain text.
    await row("deneme-web").locator(".pd-rowbtn").click();
    await page.waitForFunction(() => document.querySelector("#pd-detail #pd-facts")?.textContent.includes("Deneme Web"));
    assert.deepEqual(detailReads, ["arsiv-db", "deneme-web"]);
    assert.equal(await page.locator("#pd-detail").count(), 1, "single open detail");
    assert.equal(await row("deneme-web").locator("#pd-detail").count(), 1);
    assert.equal(await row("arsiv-db").locator(".pd-rowbtn").getAttribute("aria-expanded"), "false");
    assert.equal(await row("deneme-web").locator(".pd-rowbtn").getAttribute("aria-expanded"), "true");
    assert.equal(await row("arsiv-db").locator(".pd-rowbtn").getAttribute("aria-controls"), null, "closed rows control nothing");
    assert.equal(await row("deneme-web").locator(".pd-rowbtn").getAttribute("aria-controls"), "pd-detail");
    assert.equal(await detail.locator("#pd-ports .as-note").innerText(), "Konteyner sunucunun ağını doğrudan kullanır (host).");
    assert.equal(await detail.locator("#pd-ports .tr").count(), 0);
    assert.equal(await detail.locator("#pd-mounts .tr").count(), 0);
    assert.equal(await detail.locator("#pd-mounts").innerText(), "Bağlama yok.");
    facts = await text(detail.locator("#pd-facts"));
    for (const t of ["Durum Çalışıyor", "Sağlık Sağlıklı", "Ağ host", "Birim deneme-web.service", "Sürüm 1.27.0", "Başlık Deneme Web", "Yeniden başlatma 2",
      "Kaynak https://example.invalid/deneme-web", "Komut nginx -g daemon off;", "Bitti —"]) assert(facts.includes(t), `facts show "${t}": ${facts}`);
    assert(!facts.includes("Up 9 minutes") && !facts.includes("çıkış 0"), "a running container shows neither the English status nor a stale finish");
    assert.equal(await detail.locator("a").count(), 0, "the source label is text, not a link");
    assert.equal(await detail.locator(".hm.ok").count(), 2, "state and health pills");

    // Log card: closed until asked; default 200 lines, newest at the bottom, masked values as sent.
    const logcard = page.locator("#pd-logcard"), pre = page.locator("#pd-log");
    assert.equal(await logcard.evaluate((el) => el.open), false);
    assert.deepEqual(logReads, [], "no log request before the card is opened");
    await logcard.locator("summary").click();
    await page.waitForFunction(() => document.querySelector("#pd-log")?.textContent.includes("satır 200"));
    assert.deepEqual(logReads, ["deneme-web:200"]);
    assert.equal(await pre.evaluate((el) => el.textContent.split("\n").length), 200);
    assert((await pre.innerText()).includes("token=••••"), "masked value shown as the backend sent it");
    assert(await pre.evaluate((el) => el.textContent.trim().endsWith("token=••••")), "newest line at the bottom");
    const atBottom = () => pre.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight < 6);
    assert(await pre.evaluate((el) => el.scrollHeight > el.clientHeight + 50), "the log scrolls inside its box");
    assert(await atBottom(), "a fresh log opens at the newest line");
    assert.equal(await logcard.locator(".pd-tail button[aria-pressed='true']").innerText(), "200");
    assert.equal(await logcard.locator("#pd-log-sub").innerText(), "son 200 satır");
    assert((await logcard.locator(".as-note").innerText()).includes("Gizli görünen değerler (parola, token) arka uçta maskelenir."));
    await logcard.locator(".pd-tail").getByRole("button", { name: "500", exact: true }).click();
    await page.waitForFunction(() => document.querySelector("#pd-log")?.textContent.includes("satır 500"));
    assert.deepEqual(logReads, ["deneme-web:200", "deneme-web:500"]);
    assert.equal(await pre.evaluate((el) => el.textContent.split("\n").length), 500);
    assert.equal(await logcard.locator(".pd-tail button[aria-pressed='true']").innerText(), "500");
    assert.equal(await logcard.locator("#pd-log-sub").innerText(), "son 500 satır");
    assert(await atBottom(), "a new tail opens at the newest line");
    // Scroll follow: a log scrolled up keeps its place on refresh; one at the bottom follows the tail.
    await pre.evaluate((el) => { el.scrollTop = 120; });
    logVersion = 1;
    await logcard.getByRole("button", { name: "Yenile", exact: true }).click();
    await page.waitForFunction(() => document.querySelector("#pd-log")?.textContent.includes("sürüm 1"));
    assert.equal(await pre.evaluate((el) => el.scrollTop), 120, "a scrolled-up log keeps its position");
    await pre.evaluate((el) => { el.scrollTop = el.scrollHeight; });
    logVersion = 2;
    await logcard.getByRole("button", { name: "Yenile", exact: true }).click();
    await page.waitForFunction(() => document.querySelector("#pd-log")?.textContent.includes("sürüm 2"));
    assert(await atBottom(), "a log at the bottom follows new lines");
    assert.deepEqual(logReads, ["deneme-web:200", "deneme-web:500", "deneme-web:500", "deneme-web:500"]);
    // The shell's 10 s poll refreshes list, detail and the open log in place: same elements, same scroll.
    await pre.evaluate((el) => { el.scrollTop = 90; el.dataset.mark = "same"; document.querySelector("#pd-detail").dataset.mark = "same"; });
    const [lists, logs] = [listReads.length, logReads.length];
    logVersion = 3;
    await page.clock.runFor(10000);
    await page.waitForFunction(() => document.querySelector("#pd-log")?.textContent.includes("sürüm 3"));
    assert(listReads.length > lists && logReads.length === logs + 1, "poll reads the list and the log once");
    assert.equal(logReads.at(-1), "deneme-web:500", "poll keeps the chosen tail");
    assert.equal(await pre.evaluate((el) => el.dataset.mark), "same", "log element kept across the poll");
    assert.equal(await detail.evaluate((el) => el.dataset.mark), "same", "detail element kept across the poll");
    assert.equal(await pre.evaluate((el) => el.scrollTop), 90, "poll does not move the operator's scroll");
    assert.equal(await logcard.evaluate((el) => el.open), true);
    assert.equal(await rows.count(), 2);

    // Runtime error: warn pill with the backend's message, no rows, the open detail closes.
    Object.assign(runtime, { ok: false, version: "", error: "Podman kullanılamıyor: podman komutu başarısız" });
    await refresh();
    await head.locator(".hm.warn").waitFor();
    assert.equal(await head.locator(".hm.warn").innerText(), "Podman kullanılamıyor: podman komutu başarısız");
    assert.equal(await head.locator(".pd-counts").count(), 0);
    assert.equal(await rows.count(), 0);
    assert.equal(await page.locator("#pd-detail").count(), 0, "a vanished container closes its detail");
    assert((await page.locator("#pd-empty").innerText()).includes("Konteynerler okunamadı"));
    // Empty state: the runtime is fine but there is nothing to show yet.
    Object.assign(runtime, { ok: true, version: "5.4.2", error: "" });
    shown = [];
    await refresh();
    await page.getByText("Henüz konteyner yok.", { exact: true }).waitFor();
    assert.equal(await rows.count(), 0);
    assert((await page.locator("#pd-empty").innerText()).includes("App Store"), "the empty state says where containers come from");
    assert.equal(await text(head.locator(".pd-counts")), "Konteyner 0 0 çalışıyor İmaj 2 Depolama 512 MB");
    // Containers back: rows return, a detail with its log opens again for the layout checks.
    shown = containers;
    await refresh();
    await rows.first().waitFor();
    assert.equal(await rows.count(), 2);
    const logBefore = logReads.length;
    await row("arsiv-db").locator(".pd-rowbtn").click();
    await detail.locator("#pd-mounts .tr:not(.head)").first().waitFor();
    assert.equal(await logcard.evaluate((el) => el.open), true, "the log card remembers that it was open");
    await page.waitForFunction(() => document.querySelector("#pd-log")?.textContent.includes("satır 500"));
    assert.equal(logReads.at(-1), "arsiv-db:500");
    await page.evaluate(() => new Promise(requestAnimationFrame));
    assert.equal(logReads.length, logBefore + 1, "reopening a row fetches its log once (the open <details> toggle does not add a second request)");
    // Keyboard: the row is a button; Enter toggles it.
    await row("arsiv-db").locator(".pd-rowbtn").focus();
    await page.keyboard.press("Enter");
    assert.equal(await page.locator("#pd-detail").count(), 0, "Enter closes the open row");
    await page.keyboard.press("Enter");
    await detail.locator("#pd-mounts .tr:not(.head)").first().waitFor();
    assert.equal(await page.evaluate(() => document.activeElement?.dataset.name), "arsiv-db", "focus stays on the row");

    // Layout: four widths and both themes with the detail and the log open; nothing overflows the page.
    for (const colorScheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme });
      for (const width of [1440, 736, 390, 320]) {
        await page.setViewportSize({ width, height: 1000 });
        await page.evaluate(() => new Promise(requestAnimationFrame));
        await noOverflow(`${colorScheme} ${width}`);
        if (width <= 760) {
          assert(await page.locator("#pd-mounts .tr.head").evaluate((el) => getComputedStyle(el).display === "none"), "mobile tables drop the header row");
        }
        await page.screenshot({ path: path.join(shots, `konteynerler-${colorScheme}-${width}.png`), fullPage: true });
      }
    }
    // Deep link from an application page: the named container opens with its detail.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.emulateMedia({ colorScheme: "light" });
    await page.goto(base + "/#/genel");
    await page.goto(base + "/#/ayarlar/konteynerler/arsiv-db");
    await page.locator("#pd-detail #pd-mounts .tr:not(.head)").first().waitFor();
    assert.equal(await page.locator('#pd-list .pd-row[data-name="arsiv-db"] #pd-detail').count(), 1, "the deep link opens that container");
    assert.equal(settingsReads.length, 0, "the Konteynerler tab does not load the settings document");
    // Leaving the tab and coming back keeps the open detail (the view's node is persistent).
    await page.getByRole("tab", { name: "Sistem", exact: true }).click();
    await page.getByRole("tab", { name: "Konteynerler", exact: true }).click();
    await page.locator("#pd-detail").waitFor();
    assert.deepEqual(writes, [], "the page never sends anything but GET");
    // Static CSP guard: fixtures cannot catch innerHTML or CSSOM styles, so the source itself is checked.
    const src = fs.readFileSync(path.join(__dirname, "../console/konteynerler.js"), "utf8");
    assert(!/innerHTML|\bstyle\b|https?:|href/.test(src), "no innerHTML, inline style, URL or link in the page");
    assert.deepEqual(errors, []);
    assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
    console.log("PASS: Settings → Konteynerler — six tabs, runtime head and counts, container rows (state pills, port summary, unit, mounts), single detail with mounts/ports/host note and text labels, log tail (200 → 500, masked, scroll follow, in-place poll), runtime error and empty states, deep link, GET only, four widths/dark; screenshots in " + shots);
  } finally { await browser.close(); }
})().catch((err) => { console.error(err); process.exit(1); });
