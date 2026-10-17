/* Konsol's shell at / (DD-258, phase 1; DD-267; phase 2 pages in yeni-uygulamalar-ui.cjs): the committed
   build under Data/console/yeni with the real CSP from Data/templates/Caddyfile on every page response,
   fixture APIs, and the event stream served by the suite's own static server (yeni-harness.cjs) so that
   it can stay open and push events. Fails on any console error, CSP violation or page error. Never
   contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-ui.cjs */
const assert = require("node:assert/strict");

// Documentation values only (RFC 5737/6598 addresses, the DD examples' host and domain); shapes as in
// tools/konsol-ui/src/api/sema.ts.
const { uygulama, uygulamalar } = require("./yeni-harness.cjs").fixtures;
const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-242", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: 1791845000, sampled_at: 1791845000, cpu: 2.0, mem: { total: 8300000000, used: 700000000 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 250700000000, free: 238000000000 } },
  saglik: { status: "bad", read_at: 1791845000, checks: [
    { id: "units", name: "Servisler", status: "bad", detail: "Çalışmayan: konsol-eski.service" },
    { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  // Two applications; the sidebar counts every item of the list.
  uygulamalar: uygulamalar([uygulama("notlar"), uygulama("medya")]),
  ag: { read_at: 1791845000, sampled_at: 1791845000, rx: 1024, tx: 2048 },
  onarim: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null },
  guncelleme: { kurulu: "2026.08.06-v2-242", kurulu_surum: "1.0.0", son: "2026.08.06-v2-242", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false, denetlendi: 1791845000, hata: "",
    is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: 1791845000, alan: "ev", hizmetler: [], hatalar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null }, internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] },
      wireguard: { kurulu: true, durduruldu: false, not: "", aglar: [] }, sertifikalar: [] },
    uyarilar: [{ seviye: "warn", hizmet: "paylasim", metin: "Paylaşımlar internete şifresiz HTTP ile açık" }] },
};
let expectedFailures = [];  // URL fragments whose failed loads (401/404/502/503) are part of the scenario
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8768", data,
  expected: () => expectedFailures });
const { base, shots, status, calls, errors, stream, push, waitFor, newPage, count, noHorizontalScroll, shot } = h;
// Gelişmiş (phase 4a) reads the effective configuration when it opens; yeni-sistem-ui.cjs covers the page.
h.handlers["/api/konsol/gelismis"] = () => ({ body: { read_at: 1791845000, caddy: { entries: [], raw: [] }, dnsmasq: { listen: [], domains: [], dhcp: false, names: [], raw: [] } } });
// Phase 4b: Dosyalar' Depolama reads the files backend and who uses which folder (yeni-dosyalar-ui.cjs covers it).
h.handlers["/api/state"] = () => ({ body: { root: "/srv", writable: true, textLimit: 1048576, trash: { count: 0, size: 0 },
  disk: { total: 250700000000, free: 238000000000, used: 0, mount: false } } });
h.handlers["/api/list"] = () => ({ body: { path: "", entries: [], skipped: 0 } });
h.handlers["/api/konsol/depolama"] = () => ({ body: { read_at: 1791845000, kok: "/srv", kullananlar: [], hatalar: [] } });
const clippedBarLabels = (page) => page.locator(".bottom-bar .bb-item span").evaluateAll((els) => els.filter((e) => e.scrollWidth > e.clientWidth + 0.5).map((e) => e.textContent));
const badge = (page, id) => page.locator(`.sidebar [data-badge="${id}"]`);
const optionLabels = (page) => page.locator(".palette-option .palette-label").allInnerTexts();

(async () => {
  // The suite tests the committed build: it must match its sources and name the pinned packages it bundles.
  h.checkBuild();

  await h.start();
  try {
    // ================= desktop, light, live stream
    let page = await newPage();
    const fontResponse = page.waitForResponse((r) => r.url().endsWith("/fonts/Outfit-Variable.woff2"));
    await page.goto(new URL("/", base).href);
    await page.waitForURL((u) => u.pathname === "/" && u.hash === "#/genel");
    const h1 = page.locator("main h1");
    assert.equal(await h1.innerText(), "Genel Bakış");
    assert.equal(await page.title(), "Genel Bakış · Konsol");
    await page.locator(".brand-host").filter({ hasText: "sunucu · panel.ev" }).waitFor();
    assert.deepEqual(await page.locator(".sidebar .nav-item .nav-label").allInnerTexts(), ["Genel Bakış", "Uygulamalar", "Erişim", "Dosyalar", "Sistem", "Gelişmiş"]);
    assert.deepEqual(await page.locator('.sidebar .nav-item[aria-current="page"]').allInnerTexts(), ["Genel Bakış"]);
    await badge(page, "uygulamalar").filter({ hasText: /^2$/ }).waitFor();
    await badge(page, "sistem").filter({ hasText: /^1$/ }).waitFor();
    await badge(page, "erisim").filter({ hasText: /^1$/ }).waitFor();
    assert.match(await badge(page, "uygulamalar").getAttribute("class"), /badge-neutral/);
    assert.match(await badge(page, "sistem").getAttribute("class"), /badge-danger/);
    assert.match(await badge(page, "erisim").getAttribute("class"), /badge-warning/);
    assert.equal(await page.locator(".sidebar").getByRole("link", { name: /^Sistem\s*,\s*1 hata$/ }).count(), 1, "the count's meaning is spoken, the digit is not");
    assert.equal(await page.locator(".sidebar").getByRole("link", { name: /^Uygulamalar\s*,\s*2 kurulu uygulama$/ }).count(), 1);
    const chip = page.locator(".desktop-tools .chip");
    assert.equal(await chip.innerText(), "2 konu", "one health error and one Erişim warning");
    assert.match(await chip.getAttribute("class"), /chip-danger/);
    assert.equal(await chip.getAttribute("href"), "#/sistem");
    assert.equal(await page.getByTestId("tailscale").innerText(), "Tailscale bağlı");
    assert.match(await page.getByTestId("tailscale").getAttribute("class"), /is-ok/);
    assert.equal(await page.getByTestId("version").innerText(), "Obhut 1.0.0 · güncel");
    // Phase 2: Genel Bakış is built (yeni-uygulamalar-ui.cjs covers it) and starts with health.
    assert.equal(await page.locator("#saglik-baslik").innerText(), "2 konu dikkat istiyor", "the same two topics as the chip");
    assert.equal(await page.locator(".pending").count(), 0);
    assert.equal(await page.getByRole("button", { name: "İşlemler", exact: true }).count(), 1);
    assert.deepEqual(await page.locator("body *").evaluateAll((els) => els.filter((e) => e.hasAttribute("style")).map((e) => e.tagName)), [], "no style attributes");
    // DD-268: installable as an app; the browser reads the manifest (manifest-src 'self') without an error,
    // its icons answer, and nothing registers a service worker.
    const cdp = await page.context().newCDPSession(page);
    const manifest = await cdp.send("Page.getAppManifest");
    assert.match(manifest.url, /\/manifest\.json$/);
    assert.deepEqual(manifest.errors, [], "the manifest parses without an error");
    const declared = JSON.parse(manifest.data);
    assert.deepEqual([declared.name, declared.short_name, declared.start_url, declared.scope, declared.display],
      ["Obhut Konsol", "Obhut", "/#/genel", "/", "standalone"]);
    for (const icon of declared.icons) {
      const res = await page.request.get(new URL(icon.src, base).href);
      assert.equal(res.status(), 200, icon.src);
      assert.equal(res.headers()["content-type"], icon.type, icon.src);
    }
    assert.deepEqual(declared.icons.filter((i) => i.type === "image/png").map((i) => i.sizes + " " + i.purpose),
      ["192x192 any", "512x512 any", "512x512 maskable"]);
    assert.equal(await page.evaluate(() => navigator.serviceWorker?.controller ?? null), null, "no service worker");
    // The font is the local Outfit, allowed by font-src 'self'.
    assert.equal((await fontResponse).status(), 200);
    assert(await page.evaluate(async () => { await document.fonts.ready; return document.fonts.check("600 30px Outfit"); }), "Outfit loaded");
    assert.match(await h1.evaluate((el) => getComputedStyle(el).fontFamily), /^Outfit/);
    assert(await noHorizontalScroll(page));
    await shot(page, "1440-light-genel.png", true);

    // The stream: one fetch with X-Konsol and Accept: text/event-stream.
    await waitFor(() => stream.clients.size === 1, "event stream connected");
    await page.locator('.app[data-baglanti="canli"]').waitFor();
    assert.deepEqual(stream.headers[0], { konsol: "1", accept: "text/event-stream" });
    push("saglik", { status: "ok", read_at: 1791845100, checks: data.saglik.checks.map((c) => ({ ...c, status: "ok", detail: "çalışıyor" })) });
    await badge(page, "sistem").waitFor({ state: "detached" });
    await chip.filter({ hasText: /^1 konu$/ }).waitFor();
    assert.match(await chip.getAttribute("class"), /chip-warning/, "only Erişim's warning is left");
    push("kaynaklar", { ...data.kaynaklar, domain: "ev2" });
    await page.locator(".brand-host").filter({ hasText: "sunucu · panel.ev2" }).waitFor();
    // Unknown events and comments are ignored; data split over several lines is joined.
    for (const res of stream.clients) res.write(": canli\n\nevent: bilinmeyen\ndata: {}\n\nevent: kaynaklar\ndata: {\"host\":\"sunucu\",\"version\":\"2026.08.06-v2-242\",\ndata: \"domain\":\"ev\"}\n\n");
    await page.locator(".brand-host").filter({ hasText: /^sunucu · panel\.ev$/ }).waitFor();

    // Running jobs and the activity drawer.
    const job = { tur: "uygulama", id: "a".repeat(32), ad: "notlar · İmaj güncelleme", durum: "calisiyor", adim: "İmaj indiriliyor", bitis: null };
    push("islemler", { items: [job] });
    const activity = page.getByRole("button", { name: "İşlemler, 1 çalışıyor" });
    await activity.waitFor();
    await activity.click();
    const drawer = page.getByRole("dialog", { name: "İşlemler" });
    await drawer.waitFor();
    assert.equal(await page.evaluate(() => document.querySelector(".app").inert), true, "the page behind the drawer is inert");
    assert.equal(await page.evaluate(() => document.activeElement.getAttribute("aria-label")), "Kapat");
    assert.equal(await drawer.locator(".job-name").innerText(), "notlar · İmaj güncelleme");
    assert.equal(await drawer.locator(".job-meta").innerText(), "Uygulama · İmaj indiriliyor");
    assert.equal(await drawer.locator(".pill").innerText(), "Çalışıyor");
    assert.equal(await drawer.getByTestId("connection").innerText(), "Canlı bağlantı açık.");
    for (let n = 0; n < 3; n++) await page.keyboard.press("Tab");
    assert(await drawer.evaluate((d) => d.contains(document.activeElement)), "Tab stays in the drawer");
    await shot(page, "1440-light-drawer.png");
    await page.keyboard.press("Escape");
    await drawer.waitFor({ state: "detached" });
    assert.equal(await page.evaluate(() => document.activeElement.classList.contains("activity-btn")), true, "focus returns to İşlemler");
    const appsBefore = count("uygulamalar");
    push("islemler", { items: [{ ...job, durum: "tamam", adim: "", bitis: 1791845100 }] });
    await waitFor(() => count("uygulamalar") > appsBefore, "a finished job reloads the applications");
    await page.getByRole("button", { name: "İşlemler", exact: true }).click();
    await drawer.locator(".empty").filter({ hasText: "Şu an çalışan işlem yok" }).waitFor();
    assert.equal(await drawer.locator('.job[data-durum="tamam"] .pill').innerText(), "Tamamlandı");
    await drawer.getByRole("button", { name: "Kapat" }).click();
    await drawer.waitFor({ state: "detached" });

    // A pending settings change: the banner counts down locally from `seconds`.
    push("bekleyen", { bekleyen: { id: "p1", phase: "awaiting", seconds: 45 } });
    const banner = page.locator(".pending");
    await banner.waitFor();
    assert.equal(await banner.locator("strong").innerText(), "Bekleyen bir ayar değişikliği var");
    assert.match(await page.getByTestId("countdown").innerText(), /^0:4[45]$/);
    // Since phase 3 the banner confirms and rolls back itself (yeni-erisim-ui.cjs drives both).
    assert.deepEqual(await banner.locator(".pending-actions button").allInnerTexts(), ["Onayla", "Geri al"]);
    await page.getByTestId("countdown").filter({ hasText: /^0:4[0-3]$/ }).waitFor({ timeout: 4000 });
    await shot(page, "1440-light-pending.png");
    push("bekleyen", { bekleyen: { id: "p1", phase: "applying", seconds: 170 } });
    await banner.locator(".pending-detail").filter({ hasText: "Değişiklik sunucuda uygulanıyor…" }).waitFor();
    assert.equal(await page.getByTestId("countdown").count(), 0, "no countdown while applying");
    push("bekleyen", { bekleyen: null });
    await banner.waitFor({ state: "detached" });

    // The server closes each stream with "kapat" after a while; the page reconnects at once.
    await waitFor(() => Date.now() - stream.lastConnect > 5500, "stream older than the planned-close minimum", 8000);
    const before = stream.connections;
    for (const res of stream.clients) { res.write('event: kapat\ndata: {"neden":"sure"}\n\n'); res.end(); }
    const closedAt = Date.now();
    await waitFor(() => stream.connections === before + 1 && stream.clients.size === 1, "reconnect after kapat", 2500);
    assert(Date.now() - closedAt < 2000, "reconnected without waiting for retry");

    // Command palette: Ctrl+K, groups, Turkish-aware filtering, keyboard, Enter navigates.
    await page.locator("body").click({ position: { x: 900, y: 600 } });
    await page.keyboard.press("Control+K");
    const palette = page.getByRole("dialog", { name: "Komut paleti" });
    await palette.waitFor();
    const input = palette.getByRole("combobox");
    assert(await input.evaluate((el) => el === document.activeElement), "the field has focus");
    assert.deepEqual(await palette.locator(".palette-group-name").allInnerTexts(), ["Sayfalar", "Uygulamalar", "Eylemler"], "no group for the old interface (phase 4b)");
    assert.deepEqual(await palette.locator('[aria-labelledby="palet-grup-1"] .palette-label').allInnerTexts(), ["notlar", "medya"]);
    assert.equal(await palette.locator('[data-key="uygulama-notlar"] .palette-hint').innerText(), "Uygulama", "an application opens its own page (phase 2)");
    await shot(page, "1440-light-palette.png");
    await input.fill("İŞ");
    let labels = await optionLabels(page);
    assert(labels.includes("Erişim") && labels.includes("Gelişmiş"), "İŞ finds iş: " + labels);
    assert(!labels.includes("Sistem"), "İŞ does not find is");
    await input.fill("ıs");
    labels = await optionLabels(page);
    assert(!labels.some((l) => /is/i.test(l.toLocaleLowerCase("tr-TR")) && !l.toLocaleLowerCase("tr-TR").includes("ıs")), "ıs does not match is: " + labels);
    await palette.locator(".palette-empty").filter({ hasText: "Sonuç yok." }).waitFor();
    await input.fill("is");
    assert((await optionLabels(page)).includes("Sistem"));
    await input.fill("");
    const selected = () => palette.locator('[aria-selected="true"] .palette-label').innerText();
    assert.equal(await selected(), "Genel Bakış");
    await page.keyboard.press("ArrowDown");
    assert.equal(await selected(), "Uygulamalar");
    assert.equal(await input.getAttribute("aria-activedescendant"), await palette.locator('[aria-selected="true"]').getAttribute("id"));
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowUp");
    assert.equal(await selected(), "Çalışan işlemleri göster", "↑ from the first wraps to the last");
    await input.fill("gel");
    assert.equal(await selected(), "Gelişmiş");
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => u.hash === "#/gelismis");
    await palette.waitFor({ state: "detached" });
    assert.equal(await h1.innerText(), "Gelişmiş");
    assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "the new page's heading has focus");
    assert.deepEqual(await page.locator('.sidebar .nav-item[aria-current="page"]').allInnerTexts(), ["Gelişmiş"]);
    // Meta+K too; Esc closes and focus returns where it was.
    const search = page.getByRole("button", { name: "Ara ya da komut yaz" });
    await search.focus();
    await page.keyboard.press("Meta+K");
    await palette.waitFor();
    await page.keyboard.press("Escape");
    await palette.waitFor({ state: "detached" });
    assert(await search.evaluate((el) => el === document.activeElement), "focus back on the search field");
    await search.click();
    await palette.waitFor();
    for (let n = 0; n < 2; n++) await page.keyboard.press("Tab");
    assert(await input.evaluate((el) => el === document.activeElement), "Tab stays in the palette");
    await page.keyboard.press("Escape");
    await palette.waitFor({ state: "detached" });
    assert(await search.evaluate((el) => el === document.activeElement));
    // An action: the theme from the palette.
    await page.keyboard.press("Control+K");
    await input.fill("tema koyu");
    await page.keyboard.press("Enter");
    await palette.waitFor({ state: "detached" });
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), "rgb(15, 21, 25)");
    // Where things moved: Caddy to Erişim, the log to Sistem, Files' views to Dosyalar' tabs.
    await page.keyboard.press("Control+K");
    await input.fill("caddy");
    assert.deepEqual(await optionLabels(page), ["Erişim", "Erişim → Adresler", "Gelişmiş"], "Caddy's addresses are Erişim's (phase 3)");
    await input.fill("günlük");
    assert.deepEqual(await optionLabels(page), ["Sistem", "Sistem → Günlük"], "the log is Sistem's (phase 4a)");
    await input.fill("dosya çöp");
    assert.deepEqual(await optionLabels(page), ["Dosyalar", "Dosyalar → Çöp kutusu"], "the trash is Dosyalar' tab (phase 4b)");
    await page.keyboard.press("Escape");
    await palette.waitFor({ state: "detached" });
    await page.goto(new URL("/#/sistem?sekme=gorunum", base).href);

    // Theme on the Sistem page, kept across a reload.
    await h1.filter({ hasText: "Sistem" }).waitFor();
    const radios = page.getByRole("radiogroup", { name: "Tema" }).getByRole("radio");
    assert.deepEqual(await radios.allInnerTexts(), ["Sistem", "Açık", "Koyu"]);
    assert.equal(await page.getByRole("radio", { name: "Koyu" }).getAttribute("aria-checked"), "true", "the palette's choice is kept");
    await page.getByRole("radio", { name: "Açık" }).click();
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "light");
    await page.getByRole("radio", { name: "Koyu" }).click();
    assert.equal(await page.evaluate(() => localStorage.getItem("konsol.tema")), "koyu");
    await page.reload();
    await h1.filter({ hasText: "Sistem" }).waitFor();
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
    assert.equal(await page.getByRole("radio", { name: "Koyu" }).getAttribute("aria-checked"), "true");
    await shot(page, "1440-dark-sistem-chosen.png", true);
    await page.getByRole("radio", { name: "Koyu" }).focus();
    await page.keyboard.press("ArrowRight");
    assert.equal(await page.getByRole("radio", { name: "Sistem" }).getAttribute("aria-checked"), "true", "arrow keys move and choose");
    assert(await page.getByRole("radio", { name: "Sistem" }).evaluate((el) => el === document.activeElement));
    assert.equal(await page.evaluate(() => document.documentElement.hasAttribute("data-theme")), false, "Sistem follows the system");
    assert.equal(await page.evaluate(() => localStorage.getItem("konsol.tema")), "sistem");
    // Only the six sections and an application's page exist: any other address (an old one too) lands on Genel Bakış.
    for (const unknown of ["#/moduller/x", "#/bilinmeyen"]) {
      await page.evaluate(() => { location.hash = "#/sistem"; });
      await h1.filter({ hasText: "Sistem" }).waitFor();
      await page.evaluate((hash) => { location.hash = hash; }, unknown);
      await page.waitForFunction(() => location.hash === "#/genel");
      await h1.filter({ hasText: "Genel Bakış" }).waitFor();
      assert.deepEqual(await page.locator('.sidebar .nav-item[aria-current="page"]').allInnerTexts(), ["Genel Bakış"], unknown);
    }
    // The skip link is the first stop and focuses the page.
    await page.evaluate(() => { location.hash = "#/sistem"; });
    await h1.filter({ hasText: "Sistem" }).waitFor();
    await page.reload();
    await h1.filter({ hasText: "Sistem" }).waitFor();
    await page.keyboard.press("Tab");
    assert.equal(await page.evaluate(() => document.activeElement.className), "skip-link");
    await page.keyboard.press("Enter");
    assert.equal(await page.evaluate(() => document.activeElement.id), "icerik");
    await page.context().close();

    // ================= desktop and phone, both themes (system setting), screenshots and geometry
    for (const colorScheme of ["light", "dark"]) {
      page = await newPage({ colorScheme });
      await page.goto(new URL("/#/genel", base).href);
      await badge(page, "uygulamalar").waitFor();
      push("bekleyen", { bekleyen: { id: "p3", phase: "awaiting", seconds: 58 } });
      await page.locator(".pending").waitFor();
      assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), colorScheme === "dark" ? "rgb(15, 21, 25)" : "rgb(243, 245, 247)");
      assert(await noHorizontalScroll(page));
      await shot(page, `1440-${colorScheme}-system-theme.png`, true);
      push("bekleyen", { bekleyen: null });
      await page.context().close();

      page = await newPage({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
      await page.goto(new URL("/#/genel", base).href);
      await page.locator(".mobile-top .chip").filter({ hasText: /^2$/ }).waitFor();
      assert.equal(await page.locator(".sidebar").isVisible(), false, "no sidebar on a phone");
      assert.equal(await page.locator(".desktop-tools").isVisible(), false);
      assert.equal(await page.locator(".mobile-top .chip").getAttribute("aria-label"), "2 konu dikkat istiyor");
      assert(await page.locator(".mobile-top .wordmark").isVisible());
      assert(await page.getByRole("button", { name: "Ara", exact: true }).isVisible());
      const bar = page.getByRole("navigation", { name: "Alt menü" });
      assert.deepEqual(await bar.locator(".bb-item").allInnerTexts(), ["Genel", "Uygulamalar", "Erişim", "Dosyalar", "Daha fazla"]);
      for (const box of await bar.locator(".bb-item").evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height))) assert(box >= 44, "touch target " + box);
      assert(await noHorizontalScroll(page));
      await shot(page, `390-${colorScheme}-genel.png`, true);
      await bar.getByRole("link", { name: "Uygulamalar" }).tap();
      await page.waitForURL((u) => u.hash === "#/uygulamalar");
      assert.equal(await page.locator("main h1").innerText(), "Uygulamalar");
      assert.equal(await bar.getByRole("link", { name: "Uygulamalar" }).getAttribute("aria-current"), "page");
      assert.deepEqual(await clippedBarLabels(page), [], "the active label fits at 390 px");
      const more = bar.getByRole("button", { name: "Daha fazla" });
      await more.tap();
      const sheet = page.getByRole("dialog", { name: "Menü" });
      await sheet.waitFor();
      assert.deepEqual(await sheet.locator(".nav-label").allInnerTexts(), ["Genel Bakış", "Uygulamalar", "Erişim", "Dosyalar", "Sistem", "Gelişmiş"]);
      assert.equal(await sheet.getByTestId("version").innerText(), "Obhut 1.0.0 · güncel");
      await shot(page, `390-${colorScheme}-sheet.png`);
      await page.keyboard.press("Escape");
      await sheet.waitFor({ state: "detached" });
      assert(await more.evaluate((el) => el === document.activeElement), "focus back on Daha fazla");
      await more.tap();
      await sheet.getByRole("link", { name: /^Sistem/ }).tap();
      await sheet.waitFor({ state: "detached" });
      await page.waitForURL((u) => u.hash === "#/sistem");
      assert.match(await more.getAttribute("class"), /is-active/, "Daha fazla marks Sistem and Gelişmiş");
      assert.equal(await page.evaluate(() => document.activeElement.tagName), "H1", "a new page takes the focus");
      await more.tap();
      await sheet.getByRole("link", { name: /^Sistem/ }).tap();
      await sheet.waitFor({ state: "detached" });
      assert(await more.evaluate((el) => el === document.activeElement), "the page already open gives focus back to Daha fazla");
      await page.getByRole("button", { name: "Ara", exact: true }).tap();
      const palette = page.getByRole("dialog", { name: "Komut paleti" });
      await palette.waitFor();
      assert(await noHorizontalScroll(page));
      await shot(page, `390-${colorScheme}-palette.png`);
      await page.keyboard.press("Escape");
      await palette.waitFor({ state: "detached" });
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => innerWidth === 320 && matchMedia("(max-width: 360px)").matches);
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assert(await noHorizontalScroll(page), "320 px");
      assert.deepEqual(await clippedBarLabels(page), [], "labels fit at 320 px");
      await shot(page, `320-${colorScheme}-sistem.png`, true);
      await page.context().close();
    }

    // ================= no stream (404): polling, kaynaklar 10 s, saglik 60 s, etkinlik and bekleyen 5 s
    stream.mode = 404;
    status["/api/konsol/erisim"] = 404;
    expectedFailures = ["/api/konsol/olaylar", "/api/konsol/erisim"];
    for (const k of Object.keys(calls)) delete calls[k];
    const connectionsBefore = stream.connections;
    page = await newPage({}, { clock: true });
    await page.goto(new URL("/#/genel", base).href);
    await page.locator('.app[data-baglanti="yoklama"]').waitFor();
    await badge(page, "sistem").waitFor();
    assert.equal(await badge(page, "erisim").count(), 0, "no Erişim count without the read model");
    assert.equal(await page.locator(".desktop-tools .chip").innerText(), "1 konu");
    await waitFor(() => count("etkinlik") >= 1 && count("bekleyen") >= 1, "first reads");
    await page.waitForTimeout(100);
    const c0 = { k: count("kaynaklar"), s: count("saglik"), e: count("etkinlik"), b: count("bekleyen"), m: count("uygulamalar"), g: count("guncelleme") };
    await page.clock.runFor(5000);
    await waitFor(() => count("etkinlik") === c0.e + 1 && count("bekleyen") === c0.b + 1, "5 s reads");
    assert.equal(count("kaynaklar"), c0.k, "resources wait 10 s");
    await page.clock.runFor(5000);
    await waitFor(() => count("kaynaklar") === c0.k + 1 && count("etkinlik") === c0.e + 2, "10 s reads");
    assert.equal(count("saglik"), c0.s, "health waits 60 s");
    data.bekleyen = { bekleyen: { id: "p2", phase: "awaiting", seconds: 30 } };
    await page.clock.runFor(5000);
    await page.getByTestId("countdown").filter({ hasText: "0:30" }).waitFor();
    await page.clock.runFor(3000);
    await page.getByTestId("countdown").filter({ hasText: "0:27" }).waitFor();
    data.bekleyen = { bekleyen: null };
    await page.clock.runFor(45000);
    await waitFor(() => count("saglik") === c0.s + 1 && count("uygulamalar") === c0.m + 1 && count("guncelleme") === c0.g + 1, "60 s reads");
    await page.locator(".pending").waitFor({ state: "detached" });
    assert.equal(stream.connections, connectionsBefore + 1, "a 404 stream is not asked again");
    await page.getByRole("button", { name: "İşlemler", exact: true }).click();
    assert.equal(await page.getByTestId("connection").innerText(), "Canlı bağlantı yok; durum birkaç saniyede bir okunuyor.");
    await page.context().close();

    // 503 (too many streams) polls as well.
    stream.mode = 503;
    expectedFailures = ["/api/konsol/olaylar", "/api/konsol/erisim"];
    page = await newPage();
    await page.goto(new URL("/#/genel", base).href);
    await page.locator('.app[data-baglanti="yoklama"]').waitFor();
    await page.context().close();

    // A stream that keeps failing (502): retried after 3 s, then 6 s; after the third failure the page polls
    // while it keeps retrying (12 s), and a stream that answers again ends the polling.
    for (const k of Object.keys(status)) delete status[k];
    stream.mode = 502;
    expectedFailures = ["/api/konsol/olaylar"];
    const failingFrom = stream.connections;
    page = await newPage({}, { clock: true });
    await page.goto(new URL("/#/genel", base).href);
    await page.locator('.app[data-baglanti="yeniden"]').waitFor();
    const settle = () => page.waitForTimeout(150);
    await settle();
    await page.clock.runFor(2900);
    assert.equal(stream.connections, failingFrom + 1, "no retry before 3 s");
    await page.clock.runFor(200);
    await waitFor(() => stream.connections === failingFrom + 2, "second try after 3 s");
    await settle();
    await page.clock.runFor(5900);
    assert.equal(stream.connections, failingFrom + 2, "the wait doubles");
    await page.clock.runFor(200);
    await waitFor(() => stream.connections === failingFrom + 3, "third try after 6 s");
    await page.locator('.app[data-baglanti="yoklama"]').waitFor();
    const polledBefore = count("etkinlik");
    await page.clock.runFor(5000);
    await waitFor(() => count("etkinlik") > polledBefore, "polling while the stream is down");
    stream.mode = "live";
    await page.clock.runFor(7000);
    await waitFor(() => stream.clients.size === 1, "the stream is back");
    await page.locator('.app[data-baglanti="canli"]').waitFor();
    const afterBack = count("etkinlik");
    await page.clock.runFor(10000);
    await page.waitForTimeout(100);
    assert.equal(count("etkinlik"), afterBack, "no polling once the stream is back");
    await page.context().close();

    // Nothing answers: every value stays unknown ("—"), never 0, and nothing breaks.
    for (const key of Object.keys(data)) status["/api/konsol/" + key] = 503;
    stream.mode = 503;
    expectedFailures = ["/api/konsol/"];
    for (const k of Object.keys(calls)) delete calls[k];
    page = await newPage();
    await page.goto(new URL("/#/genel", base).href);
    await page.locator('.app[data-baglanti="yoklama"]').waitFor();
    await waitFor(() => Object.keys(data).every((key) => count(key) >= 1), "every read tried");
    await page.waitForTimeout(200);
    assert.equal(await page.locator(".brand-host").innerText(), "—");
    assert.equal(await page.locator(".desktop-tools .chip").innerText(), "Durum —");
    assert.match(await page.locator(".desktop-tools .chip").getAttribute("class"), /chip-unknown/);
    assert.equal(await page.locator(".sidebar .badge").count(), 0, "no counts while unknown");
    assert.equal(await page.getByTestId("tailscale").innerText(), "Tailscale —");
    assert.equal(await page.getByTestId("version").innerText(), "Obhut —");
    await page.getByRole("button", { name: "İşlemler", exact: true }).click();
    await page.getByRole("dialog", { name: "İşlemler" }).locator(".empty").filter({ hasText: "Çalışan işlemler henüz okunamadı." }).waitFor();
    await shot(page, "1440-light-unknown.png");
    await page.context().close();
    for (const key of Object.keys(data)) delete status["/api/konsol/" + key];

    // An ended internet session (401) goes to the sign-in page, which returns to this interface and the
    // same view (DD-267: Konsol is at /, so the sign-in page needs no return value).
    stream.mode = "live";
    status["/api/konsol/kaynaklar"] = 401;
    expectedFailures = ["/api/konsol/kaynaklar", "/api/konsol/erisim"];
    page = await newPage();
    await page.goto(new URL("/#/sistem", base).href);
    await page.waitForURL((u) => u.pathname === "/giris.html" && u.search === "" && u.hash === "#/sistem");
    await page.locator("#form-login").waitFor();
    await page.fill("#login-user", "yonetici");
    await page.fill("#login-pass", "fixture-password");
    await page.click("#login-submit");
    await page.waitForURL((u) => u.pathname === "/" && u.hash === "#/sistem");
    await page.context().close();

    assert.deepEqual(errors, []);
    console.log("PASS: Konsol shell (build matches its sources, licence banner) under the production CSP — sidebar counts (Uygulamalar 2, Sistem 1 danger, Erişim 1 warning), problem chip, " +
      "Tailscale and version card, event stream (X-Konsol fetch, multi-line data, unknown events, kapat → immediate reconnect), activity drawer " +
      "(focus trap, Esc, focus return, finished job reloads the applications), pending banner with local countdown and phases, palette (Ctrl+K/Meta+K, groups, " +
      "İŞ/ıs/is, ↑↓, Enter to a page, no old-interface group, theme action, Esc and focus return), theme radios kept across a reload, an unknown address → Genel Bakış, " +
      "skip link, phone bottom bar and sheet, 1440/390/320 in light and dark, polling without a stream (404/503: 5/10/60 s, no settings status), " +
      "a failing stream (502: 3 s, 6 s, polling after the third failure, polling ends when the stream is back), " +
      "unknown values as —, 401 → sign-in, local Outfit font. Screenshots: " + shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + shots);
  process.exit(1);
});
