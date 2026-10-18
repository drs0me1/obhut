/* Konsol's shell at / (DD-258, phase 1; DD-267) and Genel Bakış (rebuild phase 5): the committed build under
   Data/console/yeni with the real CSP from Data/templates/Caddyfile on every page response, fixture APIs, and the
   event stream served by the suite's own static server (yeni-harness.cjs) so that it can stay open and push
   events. Genel Bakış: Dikkat with each problem's place (a health check → Sistem → Sağlık, an Erişim warning →
   its row, an application → its page; a newer image listed, not counted), the calm state, the applications
   (state, address, Aç, Ayrıntı), the access summary with a chip per opening to the internet, resources, the
   network with the busiest applications (read every 5 s only while shown and visible), the server; the top
   bar's chip goes where the most serious problem is. The frame (rebuild phase 5): the palette (sections, tabs,
   applications, access rows by name, "Uygulama ekle", "Adres aç", the theme), İşlemler (application and cleanup
   jobs, the pending change), the pending banner naming every timed change, and the top bar's theme button (A7: no
   Görünüm tab). Fails on any console error, CSP violation or page error. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-ui.cjs */
const assert = require("node:assert/strict");

// Documentation values only (RFC 5737/6598 addresses, the DD examples' host and domain); shapes as in
// tools/konsol-ui/src/api/sema.ts.
const { uygulama, uygulamalar, ayrinti } = require("./yeni-harness.cjs").fixtures;
const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-242", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: 1791845000, sampled_at: 1791845000, cpu: 2.0, mem: { total: 8300000000, used: 700000000 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 250700000000, free: 238000000000 } },
  saglik: { status: "bad", read_at: 1791845000, checks: [
    { id: "units", name: "Servisler", status: "bad", detail: "Çalışmayan: konsol-eski.service" },
    { id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  // Two applications; the sidebar counts every item of the list.
  uygulamalar: uygulamalar([uygulama("notlar"), uygulama("medya")]),
  ag: { read_at: 1791845000, sampled_at: 1791845000, rx: 1024, tx: 2048, uygulamalar: [] },
  guncelleme: { kurulu: "2026.08.06-v2-242", kurulu_surum: "1.0.0", son: "2026.08.06-v2-242", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false, denetlendi: 1791845000, hata: "",
    is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: 1791845000, alan: "ev", hizmetler: [], hatalar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null }, internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] },
      wireguard: { kurulu: true, durduruldu: false, aglar: [] }, sertifikalar: [] },
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
// Sistem → Sağlık reads the last repair report (yeni-sistem-ui.cjs covers it); Genel Bakış does not.
h.handlers["/api/konsol/onarim"] = () => ({ body: { calisiyor: false, kurulu: true, baslatilabilir: true, rapor: null } });
// Erişim → Adresler reads the local names (the palette's access rows lead there; yeni-erisim-ui.cjs covers it).
h.handlers["/api/konsol/adlar"] = () => ({ body: { revizyon: "rev-1", alan: "ev", hatalar: [], adlar: [], kayitlar: [], yonlendirme: false, sunucular: [] } });
// An application's page (Genel Bakış' links lead there; yeni-uygulamalar-ui.cjs covers the page).
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)$/, (req, m) => {
  const item = data.uygulamalar.items.find((a) => a.ad === m[1]);
  return item ? { body: ayrinti(item) } : { status: 404, body: { error: "Uygulama bulunamadı." } };
}]);
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
    assert.equal(await chip.getAttribute("href"), "#/sistem", "the most serious problem's place");
    assert.equal(await page.getByTestId("tailscale").innerText(), "Tailscale bağlı");
    assert.match(await page.getByTestId("tailscale").getAttribute("class"), /is-ok/);
    assert.equal(await page.getByTestId("version").innerText(), "Obhut 1.0.0 · güncel");
    // Genel Bakış starts with what needs attention (covered below).
    assert.equal(await page.locator("#saglik-baslik").innerText(), "Dikkat · 2", "the same two topics as the chip");
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
    assert.equal(await chip.getAttribute("href"), "#/erisim", "a warning without its own place leads to Erişim");
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
    assert.equal(await banner.getByTestId("pending-title").innerText(), "Bekleyen değişiklik: Güvenlik duvarı ya da yerel adlar",
      "a change that names no row, network or domain is the firewall's or the local names'");
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
    assert.deepEqual(await palette.locator(".palette-group-name").allInnerTexts(), ["Sayfalar", "Uygulamalar", "Eylemler"], "no access row read yet, no old-interface group");
    assert.deepEqual(await palette.locator('[aria-labelledby="palet-grup-2"] .palette-label').allInnerTexts(),
      ["Uygulama ekle", "Tema: sistem", "Tema: açık", "Tema: koyu", "İşlemleri göster"], "no Adres aç without a raw TCP port");
    assert.deepEqual(await palette.locator('[aria-labelledby="palet-grup-1"] .palette-label').allInnerTexts(), ["notlar", "medya"]);
    assert.equal(await palette.locator('[data-key="uygulama-notlar"] .palette-hint').innerText(), "Uygulama", "an application opens its own page (phase 2)");
    await shot(page, "1440-light-palette.png");
    await input.fill("İŞ");
    let labels = await optionLabels(page);
    assert(labels.includes("Erişim") && labels.includes("Gelişmiş"), "İŞ finds iş: " + labels);
    assert(!labels.includes("Dosyalar → Sistem dosyaları"), "İŞ does not find is: " + labels);
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
    assert.equal(await selected(), "İşlemleri göster", "↑ from the first wraps to the last");
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
    await input.fill("işlem geçmişi");
    assert.deepEqual(await optionLabels(page), ["Sistem", "Sistem → İşlem geçmişi"], "the audit log is Sistem's İşlem geçmişi (A7)");
    await input.fill("görünüm");
    assert.deepEqual(await optionLabels(page), ["Tema: sistem", "Tema: açık", "Tema: koyu"], "no Görünüm tab: the theme is an action");
    await input.fill("dosya çöp");
    assert.deepEqual(await optionLabels(page), ["Dosyalar", "Dosyalar → Çöp kutusu"], "the trash is Dosyalar' tab (phase 4b)");
    await page.keyboard.press("Escape");
    await palette.waitFor({ state: "detached" });

    // The top bar's theme button (A7): it names the choice and steps sistem → açık → koyu, kept across a reload.
    await page.goto(new URL("/#/sistem", base).href);
    await h1.filter({ hasText: "Sistem" }).waitFor();
    const themeButton = page.locator(".desktop-tools").getByTestId("theme");
    assert.equal(await themeButton.getAttribute("aria-label"), "Tema: koyu; değiştir", "the palette's choice is kept");
    assert.equal(await page.getByRole("tab", { name: "Görünüm" }).count(), 0, "no Görünüm tab");
    await themeButton.click();
    assert.equal(await page.evaluate(() => document.documentElement.hasAttribute("data-theme")), false, "Sistem follows the system");
    assert.equal(await page.evaluate(() => localStorage.getItem("konsol.tema")), "sistem");
    assert.equal(await page.locator(".desktop-tools [role=status]").innerText(), "Tema: sistem", "the new choice is said");
    await themeButton.click();
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "light");
    assert.equal(await themeButton.getAttribute("title"), "Tema: açık");
    await themeButton.click();
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
    assert.equal(await page.evaluate(() => localStorage.getItem("konsol.tema")), "koyu");
    await page.reload();
    await h1.filter({ hasText: "Sistem" }).waitFor();
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
    assert.equal(await themeButton.getAttribute("aria-label"), "Tema: koyu; değiştir");
    await shot(page, "1440-dark-sistem-chosen.png", true);
    await themeButton.click();
    assert.equal(await page.evaluate(() => localStorage.getItem("konsol.tema")), "sistem");
    // An old tab address shows the section's own page; no address is redirected for it.
    await page.goto(new URL("/#/sistem?sekme=gorunum", base).href);
    await page.getByRole("tab", { name: "Sağlık", selected: true }).waitFor();
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

    // ================= Genel Bakış: Dikkat with each problem's place, the applications, the access summary, the cards
    {
      const saved = { saglik: data.saglik, uygulamalar: data.uygulamalar, erisim: data.erisim, ag: data.ag };
      const NOTLAR = "uygulama:notlar:web:8080/tcp", MEDYA = "uygulama:medya:web:8096/tcp", KUTU = "uygulama:kutu:app:9000/udp";
      const enc = (id) => new URLSearchParams({ satir: id }).toString().slice("satir=".length);
      const cell = (durum, adresler = [], not = "", uyari = "") => ({ durum, adresler, not, uyari });
      const row = (id, ad, tur, o = {}) => ({ id, ad, tur, aciklama: "", uygulama: null, servis: null, anahtar: null, calisiyor: true, yerel: cell("yok"),
        tailscale: cell("kapali"), wireguard: cell("kapali"), internet: cell("kapali"), satir: null, web: null, ...o });
      const appRow = (id, satir, o) => {
        const [, app, service, port] = id.split(":");
        return row(id, `${app} · ${service}`, "uygulama", { uygulama: app, servis: service, anahtar: `${service}:${port}`, satir, ...o });
      };
      const BAD = { id: "units", name: "Servisler", status: "bad", detail: "Çalışmayan: konsol-eski.service" };
      const OK = [{ id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }, { id: "dns", name: "DNS", status: "ok", detail: "yanıt veriyor" }];
      const WARNINGS = [
        { seviye: "warn", hizmet: "paylasim", metin: "İnternetten gelen WebDAV bağlantıları şifresiz.", duzelt: { bolum: "adresler", hedef: "paylasim" } },
        { seviye: "warn", hizmet: MEDYA, metin: "medya · web: 8096/tcp doğrudan internete açık.", duzelt: { bolum: "adresler", hedef: MEDYA } }];
      const erisim = (o = {}) => ({ read_at: 1791845000, alan: "ev", revizyon: "rev-1", hatalar: [], uyarilar: WARNINGS,
        hizmetler: [
          row("panel", "Konsol", "konsol", { tailscale: cell("acik", ["panel.ev"]), web: { tail: true, enabled: false, domain: "" } }),
          appRow(NOTLAR, { tur: "adres", ad: "notlar", tailscale_portu: null, internet: "notlar.example.org" },
            { yerel: cell("acik"), tailscale: cell("acik", ["notlar.ev"]), internet: cell("acik", ["notlar.example.org"]) }),
          appRow(MEDYA, { tur: "ham", kapsam: "internet", port: 8096 }, { internet: cell("acik", ["203.0.113.10:8096/tcp"], "", "Şifreleme ve giriş uygulamanın kendisinde.") }),
          appRow(KUTU, { tur: "ham", kapsam: "tailscale", port: 9000 }, { tailscale: cell("acik", ["100.64.0.2:9000/udp"]) }),
          row("paylasim", "Paylaşımlar", "paylasim", { tailscale: cell("acik", ["paylas.ev"]), internet: cell("acik", ["http://203.0.113.10:61010"], "", "Şifresiz HTTP"),
            web: { tail: true, enabled: false, domain: "" } }),
          row("sistem:ssh", "SSH", "sistem", { tailscale: cell("acik"), internet: cell("acik", ["203.0.113.10:22/tcp"]) })],
        ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "sunucu", surum: "1.88.3", adresler: ["100.64.0.2"], cikis_dugumu: true },
          internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] },
          wireguard: { kurulu: true, durduruldu: false, aglar: [{ arayuz: "wg0", ad: "", etkin: true, port: 61001 }, { arayuz: "wg1", ad: "", etkin: false, port: 61002 }] },
          sertifikalar: [{ ad: "notlar.example.org", hizmet: NOTLAR, durum: "gecerli", bitis: 1791845000 + 60 * 86400 }] },
        ...o });
      const apps = () => [
        uygulama("notlar", { adres: "http://notlar.ev", guncelleme: "yeni", uyari: 1, servisler: [{ ad: "web", durum: "calisiyor", imaj: "registry.example/notlar:2", guncelleme: "yeni" }] }),
        uygulama("medya", { durum: "kismen", adres: "http://medya.ev" }),
        uygulama("kutu", { durum: "hata" }),
        uygulama("yedek", { durum: "durduruldu", durduruldu: true, adres: "http://yedek.ev" })];
      data.saglik = { status: "bad", read_at: 1791844900, checks: [BAD, ...OK] };
      data.erisim = erisim();
      data.uygulamalar = uygulamalar(apps());
      data.ag = { read_at: 1791845000, sampled_at: 1791845000, rx: 3145728, tx: 348160, uygulamalar: [{ ad: "medya", indirme: 2097152, yukleme: 20480 },
        { ad: "notlar", indirme: 4096, yukleme: 1024 }] };
      page = await newPage();
      await page.goto(new URL("/#/genel", base).href);
      await page.locator("#saglik-baslik").filter({ hasText: "Dikkat · 6" }).waitFor();
      const problems = page.locator(".problem");
      await page.locator('.problem[data-kind="uygulama"]').first().waitFor();
      assert.deepEqual(await problems.evaluateAll((els) => els.map((e) => [e.dataset.kind, e.className.replace("problem problem-", "")])), [
        ["saglik", "danger"], ["uygulama", "danger"], ["erisim", "warning"], ["erisim", "warning"], ["uygulama", "warning"], ["uygulama", "accent"]],
        "the most serious first, news last");
      assert.deepEqual(await problems.locator("strong").allInnerTexts(), ["Servisler", "kutu çalışmıyor", WARNINGS[0].metin, WARNINGS[1].metin,
        "medya kısmen çalışıyor", "notlar için yeni imaj var"]);
      assert.equal(await problems.nth(0).locator(".problem-text span").innerText(), BAD.detail);
      assert.equal(await problems.nth(3).locator(".problem-text span").innerText(), "Erişim · medya", "a warning is named after its application");
      assert.equal(await problems.nth(5).locator(".problem-text span").innerText(), "registry.example/notlar:2 etiketinin yeni yapısı yayımlandı.");
      assert.deepEqual(await problems.locator('[data-eylem="duzelt"]').evaluateAll((as) => as.map((a) => [a.textContent.trim(), a.getAttribute("href")])), [
        ["Sağlık'ta incele", "#/sistem"], ["Uygulamaya git", "#/uygulamalar/kutu"],
        ["Erişim'de incele", "#/erisim?sekme=adresler&satir=paylasim"], ["Erişim'de incele", `#/erisim?sekme=adresler&satir=${enc(MEDYA)}`],
        ["Uygulamaya git", "#/uygulamalar/medya"], ["Uygulamaya git", "#/uygulamalar/notlar"]]);
      assert.equal(await page.getByRole("link", { name: "Tüm denetimler" }).getAttribute("href"), "#/sistem");
      assert.equal(await page.getByRole("button", { name: "Denetle ve onar" }).count(), 0, "the repair is Sistem → Sağlık's");
      const topChip = page.locator(".desktop-tools .chip");
      assert.equal(await topChip.innerText(), "5 konu", "news is not counted");
      // Applications: state, address, Aç for one that runs with an address, Ayrıntı.
      assert.deepEqual(await page.locator(".app-card").evaluateAll((els) => els.map((e) => e.dataset.uygulama)), ["notlar", "medya", "kutu", "yedek"]);
      assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (4)");
      assert.equal(await page.getByTestId("all-apps").getAttribute("href"), "#/uygulamalar");
      const card = (ad) => page.locator(`.app-card[data-uygulama="${ad}"]`);
      assert.deepEqual(await page.locator(".app-card .pill").allInnerTexts(), ["Çalışıyor", "Kısmen çalışıyor", "Sorun var", "Durdurulmuş"]);
      assert.equal(await card("notlar").locator(".app-line").innerText(), "notlar.ev · 1 uyarı · yeni imaj var");
      assert.equal(await card("kutu").locator(".app-line").innerText(), "Dışarıya açık adresi yok");
      assert.equal(await card("yedek").locator(".app-line").innerText(), "yedek.ev");
      assert.deepEqual(await page.locator('.app-card [data-eylem="ac"]').evaluateAll((as) => as.map((a) => [a.closest(".app-card").dataset.uygulama,
        a.getAttribute("href"), a.getAttribute("target"), a.getAttribute("rel")])),
      [["notlar", "http://notlar.ev", "_blank", "noopener noreferrer"], ["medya", "http://medya.ev", "_blank", "noopener noreferrer"]], "a stopped one has nothing to open");
      assert.equal(await card("notlar").getByRole("link", { name: "notlar ayrıntıları" }).getAttribute("href"), "#/uygulamalar/notlar");
      // The access summary: counts and a chip for whatever is open to the internet, each leading to its row.
      const summary = page.getByTestId("access-summary");
      assert.deepEqual(await summary.locator(".stat").evaluateAll((els) => els.map((e) => [e.querySelector("dt").textContent, e.querySelector("dd").textContent])), [
        ["Tailscale adresi", "3"], ["internet adı", "1"], ["internete açık doğrudan port", "1"], ["Tailscale'de doğrudan port", "1"], ["WireGuard ağı açık", "1"]]);
      assert.deepEqual(await summary.locator(".access-chip").evaluateAll((as) => as.map((a) => [a.textContent.trim(), a.getAttribute("href"), a.className.replace("access-chip ", "")])), [
        ["notlar · notlar.example.org", `#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`, "access-chip-accent"],
        ["medya · 8096/TCP doğrudan", `#/erisim?sekme=adresler&satir=${enc(MEDYA)}`, "access-chip-warning"],
        ["Paylaşımlar · http://203.0.113.10:61010", "#/erisim?sekme=adresler&satir=paylasim", "access-chip-warning"]], "SSH has no row: no chip");
      assert.equal(await summary.getByRole("link", { name: "Erişim'e git" }).getAttribute("href"), "#/erisim");
      // Resources, the network with the busiest applications, the server.
      assert.equal(await page.getByTestId("cpu").innerText(), "%2");
      assert.equal(await page.getByTestId("memory").innerText(), "668 MB / 7,7 GB");
      assert.equal(await page.getByTestId("disk").innerText(), "11,8 GB / 233,5 GB");
      await page.getByTestId("rx").filter({ hasText: "3 MB/s" }).waitFor();
      assert.equal(await page.getByTestId("tx").innerText(), "340 KB/s");
      assert.equal(await page.getByTestId("network").locator(".pill").innerText(), "Canlı");
      const busiest = page.getByTestId("net-apps");
      assert.deepEqual(await busiest.locator("li").evaluateAll((els) => els.map((e) => e.dataset.uygulama)), ["medya", "notlar"]);
      assert.deepEqual(await busiest.locator('li[data-uygulama="medya"] .net-app-rate').evaluateAll((els) => els.map((e) => e.textContent)), ["↓İndirme 2 MB/s", "↑Yükleme 20 KB/s"]);
      assert.equal(await busiest.getByRole("link", { name: "medya" }).getAttribute("href"), "#/uygulamalar/medya");
      assert.deepEqual(await page.getByTestId("server").locator("dd").allInnerTexts(), ["Debian GNU/Linux 13 (trixie)", "5 gün", "100.64.0.2", "203.0.113.10", "1.0.0 · güncel"]);
      assert.deepEqual(await page.locator("body *").evaluateAll((els) => els.filter((e) => e.hasAttribute("style")).map((e) => e.tagName)), [], "no style attributes");
      assert(await noHorizontalScroll(page));
      await shot(page, "1440-light-genel-dikkat.png", true);
      // The chip goes where the most serious problem is.
      await topChip.click();
      await page.waitForURL((u) => u.hash === "#/sistem");
      await page.goto(new URL("/#/genel", base).href);
      await problems.nth(1).locator('[data-eylem="duzelt"]').click();
      await page.waitForURL((u) => u.hash === "#/uygulamalar/kutu");
      await page.context().close();
      // Without a health problem the chip leads to the failed application.
      data.saglik = { status: "ok", read_at: 1791844900, checks: [{ ...BAD, status: "ok" }, ...OK] };
      page = await newPage();
      await page.goto(new URL("/#/genel", base).href);
      await page.locator("#saglik-baslik").filter({ hasText: "Dikkat · 5" }).waitFor();
      await page.locator(".desktop-tools .chip").filter({ hasText: "4 konu" }).waitFor();
      assert.equal(await page.locator(".desktop-tools .chip").getAttribute("href"), "#/uygulamalar/kutu");
      await page.context().close();

      // The frame with access rows: the palette names each row (an address by its Tailscale name, a raw port by its
      // application and port) and opens its sheet; "Uygulama ekle" and "Adres aç" open their flows.
      page = await newPage();
      await page.goto(new URL("/#/genel", base).href);
      await page.locator(".access-chip").first().waitFor();
      await page.keyboard.press("Control+K");
      const pal = page.getByRole("dialog", { name: "Komut paleti" });
      const palInput = pal.getByRole("combobox");
      await pal.waitFor();
      assert.deepEqual(await pal.locator(".palette-group-name").allInnerTexts(), ["Sayfalar", "Uygulamalar", "Adresler", "Eylemler"]);
      const rowOptions = pal.locator('[aria-labelledby="palet-grup-2"] .palette-option');
      assert.deepEqual(await rowOptions.locator(".palette-label").allInnerTexts(), ["panel.ev", "notlar.ev", "medya · 8096/TCP", "kutu · 9000/UDP", "paylas.ev"],
        "SSH has no row");
      assert.deepEqual(await rowOptions.locator(".palette-hint").allInnerTexts(), ["Konsol · Adres", "notlar · Adres", "medya · Doğrudan port", "kutu · Doğrudan port",
        "Paylaşımlar · Adres"]);
      assert.deepEqual(await pal.locator('[aria-labelledby="palet-grup-3"] .palette-label').allInnerTexts(),
        ["Uygulama ekle", "Adres aç", "Tema: sistem", "Tema: açık", "Tema: koyu", "İşlemleri göster"]);
      await palInput.fill("notlar.example");
      assert.deepEqual(await optionLabels(page), ["notlar.ev"], "a row is found by its internet name too");
      await page.keyboard.press("Enter");
      await page.waitForURL((u) => u.hash === `#/erisim?sekme=adresler&satir=${enc(NOTLAR)}`);
      await page.locator("main h1").filter({ hasText: "Erişim" }).waitFor();
      await page.getByRole("region", { name: "notlar · web" }).waitFor();
      await page.keyboard.press("Escape");
      await page.getByRole("region", { name: "notlar · web" }).waitFor({ state: "detached" });
      await page.keyboard.press("Control+K");
      await palInput.fill("adres aç");
      assert.deepEqual(await optionLabels(page), ["Erişim → Adresler", "Adres aç"]);
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("Enter");
      await page.waitForURL((u) => u.hash === `#/erisim?sekme=adresler&satir=${enc(MEDYA)}&kip=adres-ac`, { timeout: 3000 });
      await page.keyboard.press("Escape");
      await page.keyboard.press("Control+K");
      await palInput.fill("uygulama ekle");
      await page.keyboard.press("Enter");
      await page.waitForURL((u) => u.hash === "#/uygulama-ekle");
      await page.getByTestId("add-flow").getByRole("button", { name: "Kapat" }).click();
      await page.waitForURL((u) => u.hash === "#/uygulamalar");

      // Every timed change is named in the banner and in İşlemler: an access row, WireGuard, the local domain, a fixed row.
      const pendingTitle = page.getByTestId("pending-title");
      const NAMED = [
        [{ erisim: NOTLAR }, "Erişim değişikliği · notlar.ev"],
        [{ erisim: MEDYA }, "Erişim değişikliği · medya · 8096/TCP"],
        [{ wireguard: { eylem: "baslat", iface: null } }, "WireGuard'ı aç"],
        [{ wireguard: { eylem: "ag-kapat", iface: "wg1" } }, "wg1 ağını kapat"],
        [{ wireguard: { eylem: "ag-ekle", iface: null } }, "WireGuard ağı ekle"],
        [{ domain: { old: "ev", new: "evim" } }, "Yerel alan adı · ev → evim"],
        [{ web: true }, "Erişim değişikliği · Konsol ya da Paylaşımlar"]];
      for (const [i, [subject, title]] of NAMED.entries()) {
        push("bekleyen", { bekleyen: { id: "n" + i, phase: "awaiting", seconds: 58, ...subject } });
        await pendingTitle.filter({ hasText: "Bekleyen değişiklik: " + title }).waitFor();
      }
      push("bekleyen", { bekleyen: { id: "n9", phase: "awaiting", seconds: 58, erisim: NOTLAR } });
      await pendingTitle.filter({ hasText: "notlar.ev" }).waitFor();
      push("islemler", { items: [
        { tur: "uygulama", id: "b".repeat(32), ad: "notlar · Kurulum", durum: "calisiyor", adim: "İmaj indiriliyor", bitis: null },
        { tur: "konteyner", id: "c".repeat(32), ad: "Podman · Temizlik", durum: "hata", bitis: 1791845100,
          adim: "1 öge kaldırılmadı (1 kaldırıldı): eski: Birim bir konteynerde kullanılıyor." }] });
      await page.getByRole("button", { name: "İşlemler, 1 çalışıyor" }).click();
      const jobs = page.getByRole("dialog", { name: "İşlemler" });
      const drawerPending = jobs.getByTestId("drawer-pending");
      await drawerPending.waitFor();
      assert.equal(await drawerPending.locator(".job-name").innerText(), "Erişim değişikliği · notlar.ev");
      assert.equal(await drawerPending.locator(".pill").innerText(), "Onay bekliyor");
      assert.equal(await drawerPending.locator(".job-meta").innerText(), "Bekleyen ayar değişikliği · onay ve geri alma sayfanın üstündeki bantta");
      assert.equal(await jobs.locator('.job[data-durum="calisiyor"] .job-meta').innerText(), "Uygulama · İmaj indiriliyor");
      const cleanupJob = jobs.locator('.job[data-durum="hata"]');
      assert.equal(await cleanupJob.locator(".job-name").innerText(), "Podman · Temizlik");
      assert.match(await cleanupJob.locator(".job-meta").innerText(), /^Gelişmiş · 1 öge kaldırılmadı \(1 kaldırıldı\): eski: Birim bir konteynerde kullanılıyor\. · \d\d:\d\d$/,
        "what stayed and why");
      assert.equal(await cleanupJob.locator(".pill").innerText(), "Hata");
      await shot(page, "1440-light-islemler-bekleyen.png");
      push("bekleyen", { bekleyen: { id: "n9", phase: "stuck", seconds: 0, attempts: 5, error: "dnsmasq başlamadı", erisim: NOTLAR } });
      await drawerPending.locator(".pill").filter({ hasText: "Geri alma takıldı" }).waitFor();
      push("bekleyen", { bekleyen: null });
      await drawerPending.waitFor({ state: "detached" });
      push("islemler", { items: [] });
      await page.keyboard.press("Escape");
      await page.context().close();

      // The calm state: nothing to fix; nothing open to the internet; WireGuard off.
      // WebDAV's internet switch on with no name configured (as a fresh install has it) is not an internet name.
      data.erisim = erisim({ uyarilar: [], hizmetler: [...erisim().hizmetler.filter((h) => h.id === "panel"),
        row("paylasim", "Paylaşımlar", "paylasim", { tailscale: cell("acik", ["paylas.ev"]), web: { tail: true, enabled: true, domain: "" } })],
        ozet: { ...erisim().ozet, wireguard: { kurulu: true, durduruldu: false, aglar: [] }, sertifikalar: [] } });
      data.uygulamalar = uygulamalar([uygulama("notlar")]);
      data.ag = { read_at: 1791845000, sampled_at: 1791845000, rx: 1024, tx: 2048, uygulamalar: [] };
      page = await newPage();
      await page.goto(new URL("/#/genel", base).href);
      await page.locator("#saglik-baslik").filter({ hasText: "Her şey yolunda" }).waitFor();
      await page.getByTestId("health-sub").filter({ hasText: "3 denetim sorunsuz · son denetim 1 dakika önce" }).waitFor();
      assert.equal(await page.locator(".problem").count(), 0);
      assert.equal(await page.locator(".desktop-tools .chip").innerText(), "Her şey yolunda");
      assert.equal(await page.locator(".desktop-tools .chip").getAttribute("href"), "#/sistem");
      assert.equal(await page.getByTestId("nothing-open").innerText(), "İnternete açık hiçbir şey yok.");
      assert.deepEqual(await page.getByTestId("access-summary").locator(".stat dd").allInnerTexts(), ["2", "0", "0", "0", "—"]);
      assert.equal(await page.getByTestId("access-summary").locator('[data-stat="wireguard"] dt').innerText(), "WireGuard kapalı");
      assert.equal(await page.getByTestId("net-apps").count(), 0, "no busy application");
      await shot(page, "1440-light-genel-sakin.png");
      await page.context().close();

      // The network card reads every 5 s only while Genel Bakış is shown and the tab visible.
      page = await newPage({}, { clock: true });
      await page.goto(new URL("/#/genel", base).href);
      await page.getByTestId("rx").filter({ hasText: "1 KB/s" }).waitFor();
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
      // A failed read says so and is no longer live; the next one that answers clears it.
      expectedFailures = ["/api/konsol/ag"];
      status["/api/konsol/ag"] = 503;
      await page.clock.runFor(5000);
      await page.getByTestId("net-error").filter({ hasText: "Ağ bilgisi okunamadı." }).waitFor();
      assert.equal(await page.getByTestId("network").locator(".pill").count(), 0, "not live while the reads fail");
      delete status["/api/konsol/ag"];
      await page.clock.runFor(5000);
      await page.getByTestId("net-error").waitFor({ state: "detached" });
      await page.getByTestId("network").locator(".pill").filter({ hasText: "Canlı" }).waitFor();
      expectedFailures = [];
      const n1 = count("ag");
      await page.locator('.sidebar [data-nav="uygulamalar"]').click();
      await page.waitForURL((u) => u.hash === "#/uygulamalar");
      await page.clock.runFor(15000);
      await page.waitForTimeout(150);
      assert.equal(count("ag"), n1, "no reads on another page");
      await page.context().close();

      // A clean server: no applications yet.
      data.uygulamalar = uygulamalar([]);
      page = await newPage();
      await page.goto(new URL("/#/genel", base).href);
      const overviewApps = page.getByTestId("overview-apps");
      await overviewApps.locator(".empty-title").filter({ hasText: "Henüz uygulama yok." }).waitFor();
      assert.equal(await overviewApps.locator(".empty-text").innerText(), "Uygulamalar bölümünden bir Compose ya da Kubernetes dosyasıyla eklenir.");
      assert.equal(await page.getByTestId("all-apps").innerText(), "Tümü (0)");
      await shot(page, "1440-light-genel-bos.png", true);
      await page.context().close();

      // A phone: two tiles per row; a tap anywhere on a tile opens its page. 390 and 320 in both themes.
      data.saglik = { status: "bad", read_at: 1791844900, checks: [BAD, ...OK] };
      data.erisim = erisim();
      data.uygulamalar = uygulamalar(apps());
      for (const colorScheme of ["light", "dark"]) {
        page = await newPage({ colorScheme });
        await page.goto(new URL("/#/genel", base).href);
        await page.locator(".access-chip").first().waitFor();
        assert(await noHorizontalScroll(page));
        await shot(page, `1440-${colorScheme}-genel-tam.png`, true);
        await page.context().close();
        page = await newPage({ colorScheme, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, reducedMotion: "reduce" });
        await page.goto(new URL("/#/genel", base).href);
        await page.locator(".access-chip").first().waitFor();
        const tiles = await page.locator(".app-card").evaluateAll((els) => els.slice(0, 2).map((e) => Math.round(e.getBoundingClientRect().top)));
        assert.equal(tiles[0], tiles[1], "two tiles per row");
        assert(await noHorizontalScroll(page), "390 genel");
        await shot(page, `390-${colorScheme}-genel-tam.png`, true);
        const tile = page.locator('.app-card[data-uygulama="kutu"]');
        const tileBox = await tile.boundingBox();
        await tile.tap({ position: { x: tileBox.width - 14, y: 14 } });
        await page.waitForURL((u) => u.hash === "#/uygulamalar/kutu");
        await page.goto(new URL("/#/genel", base).href);
        await page.locator(".access-chip").first().waitFor();
        await page.setViewportSize({ width: 320, height: 640 });
        await page.waitForFunction(() => innerWidth === 320);
        await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        assert(await noHorizontalScroll(page), "320 genel");
        await shot(page, `320-${colorScheme}-genel-tam.png`, true);
        await page.context().close();
      }
      Object.assign(data, saved);
    }

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
      assert(await page.locator(".mobile-top").getByTestId("theme").isVisible(), "the theme on a phone's top bar too");
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

    // ================= a new build while the page is open (DD-280): the page's own files, asked with HEAD
    let etag = '"yapi-1"';
    const heads = [];
    const ownFiles = (p) => p.route(/\/app\.(js|css)$/, (route) => {
      if (route.request().method() !== "HEAD") return route.continue();
      heads.push(route.request().url());
      return route.fulfill({ status: 200, headers: { ETag: etag + (route.request().url().endsWith(".css") ? "-css" : "-js") } });
    });
    page = await newPage();
    await ownFiles(page);
    await page.goto(new URL("/#/genel", base).href);
    await waitFor(() => stream.clients.size === 1 && heads.length === 2, "the page noted its script and style sheet");
    const buildNotice = page.getByTestId("build-notice");
    // The installer writes the new build number first (stage 3); while the files are the old ones nothing happens.
    push("kaynaklar", { ...data.kaynaklar, version: "2026.08.06-v2-243" });
    await waitFor(() => heads.length >= 4, "looked again at once");
    await page.waitForTimeout(500);
    assert.equal(await buildNotice.count(), 0, "the same files: no notice, no reload");
    // The files change (stage 6): the notice, and the page reloads itself.
    etag = '"yapi-2"';
    await buildNotice.filter({ hasText: "Konsol güncellendi (yapı v2-243). Sayfa yenileniyor…" }).waitFor({ timeout: 8000 });
    const reloaded = page.waitForEvent("load", { timeout: 6000 });
    await reloaded;
    await page.locator("main h1").filter({ hasText: "Genel Bakış" }).waitFor();
    assert.equal(await buildNotice.count(), 0, "the reloaded page runs the new files");
    await page.context().close();
    // With something entered the page waits for the operator.
    etag = '"yapi-2"';
    heads.length = 0;
    page = await newPage();
    await ownFiles(page);
    const heldNotice = page.getByTestId("build-notice");
    await page.goto(new URL("/#/uygulama-ekle", base).href);
    await page.getByTestId("add-flow").getByRole("radio", { name: /Dosya/ }).check();
    await page.getByTestId("paste").getByRole("textbox").fill("services:\n  web:\n    image: registry.example/web:1\n");
    await waitFor(() => stream.clients.size === 1 && heads.length === 2, "noted");
    push("kaynaklar", { ...data.kaynaklar, version: "2026.08.06-v2-243" });
    etag = '"yapi-3"';
    await heldNotice.filter({ hasText: "Yeni arayüz sayfa yenilenince açılır; yenileyince girdikleriniz silinir." }).waitFor({ timeout: 8000 });
    await page.waitForTimeout(2500);
    assert.equal(new URL(page.url()).hash, "#/uygulama-ekle");
    assert.match(await page.getByTestId("paste").getByRole("textbox").inputValue(), /registry\.example\/web:1/, "nothing dropped while it waits");
    assert(await heldNotice.evaluate((e) => e.getBoundingClientRect().bottom <= document.querySelector(".add-head").getBoundingClientRect().top), "above the page's head");
    await shot(page, "1440-light-yeni-yapi.png");
    page.once("dialog", (dialog) => void dialog.accept());
    const reloadedByHand = page.waitForEvent("load", { timeout: 6000 });
    await heldNotice.getByRole("button", { name: "Şimdi yenile" }).click();
    await reloadedByHand;
    await page.getByTestId("add-flow").waitFor();
    assert.equal(await heldNotice.count(), 0);
    await page.context().close();

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
      "Tailscale and version card, Genel Bakış (Dikkat ordered with each problem's place and the chip following the most serious one, news " +
      "not counted, the calm state, applications with their address, Aç and Ayrıntı, the access summary's counts and chips to their rows, the " +
      "busiest applications, network reads every 5 s only while shown and visible, a failed read, no applications, phone tiles), event stream (X-Konsol fetch, multi-line data, unknown events, kapat → immediate reconnect), activity drawer " +
      "(focus trap, Esc, focus return, finished job reloads the applications, the pending change named with its phase, a cleanup job's reason), " +
      "pending banner naming every timed change (an access row, WireGuard, the local domain, a fixed row, the firewall or names) with local " +
      "countdown and phases, palette (Ctrl+K/Meta+K, groups, İŞ/ıs/is, ↑↓, Enter to a page, access rows by name opening their panel, Uygulama " +
      "ekle, Adres aç, theme actions, no Görünüm, Esc and focus return), the top bar's theme button stepping sistem → açık → koyu kept across a " +
      "reload, an unknown address → Genel Bakış, " +
      "skip link, phone bottom bar and sheet, 1440/390/320 in light and dark, polling without a stream (404/503: 5/10/60 s, no settings status), " +
      "a failing stream (502: 3 s, 6 s, polling after the third failure, polling ends when the stream is back), " +
      "a new build while a page is open (a new build number alone changes nothing; new files show the notice and reload the page; " +
      "with something entered it waits for Şimdi yenile, above Uygulama ekle's head), " +
      "unknown values as —, 401 → sign-in, local Outfit font. Screenshots: " + shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + shots);
  process.exit(1);
});
