/* Konsol sign-in and first-account pages (DD-194) with intercepted APIs and the real CSP.
   Uses the shared console preview on port 8766; never contacts a server. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const shots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-giris-ui-"));
const base = process.env.KONSOL_URL || "http://127.0.0.1:8766";
const csp = fs.readFileSync(path.join(__dirname, "../templates/Caddyfile"), "utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
let state = { durum: "kurulum", kod: false }, reply = null, konsolUnauthorized = false;
const posts = [], errors = [];
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (/Content Security Policy|Refused to|not a valid regular expression/.test(m.text())) errors.push(m.text()); });
    await page.route("**/*", async (route) => {
      const request = route.request(), url = new URL(request.url());
      if (request.resourceType() === "document" && url.pathname === "/" && !konsolUnauthorized) {
        // Successful sign-in leaves this page; Konsol itself is covered by the other suites.
        return route.fulfill({ status: 200, contentType: "text/html", headers: { "content-security-policy": csp }, body: "<!doctype html><title>Konsol</title>" });
      }
      if (url.pathname.startsWith("/api/")) {
        assert.equal(request.headers()["x-konsol"], "1", "every sign-in API call carries the CSRF header");
        if (url.pathname === "/api/konsol/oturum") return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(state) });
        if (url.pathname.startsWith("/api/konsol/oturum/")) {
          posts.push({ path: url.pathname, body: request.postDataJSON() });
          const answer = reply || { status: 200, body: { durum: "acik" } };
          reply = null;
          return route.fulfill({ status: answer.status, contentType: "application/json", headers: answer.headers || {}, body: JSON.stringify(answer.body) });
        }
        // Konsol pages reached without a session get forward_auth's API answer.
        return route.fulfill({ status: 401, contentType: "application/json", body: JSON.stringify({ error: "Oturum gerekli; yeniden giriş yapın.", giris: true }) });
      }
      if (request.resourceType() !== "document") return route.continue();
      const response = await route.fetch();
      return route.fulfill({ response, headers: { ...response.headers(), "content-security-policy": csp } });
    });
    const note = page.locator("#login-note");
    // A fresh load each time: a fragment-only change would not rerun the page script.
    const open = async (url) => { await page.goto("about:blank"); await page.goto(base + url); };
    // No valid code: the page says how to get one and still offers the form.
    await open("/giris.html");
    await page.locator("#form-setup").waitFor();
    assert.match(await note.innerText(), /sudo master-konsol sifirla/);
    assert(await page.locator("#form-login").isHidden());
    assert.equal(await page.locator("#login-title").innerText(), "İlk hesap");
    // A valid code: client checks first, then the server's answers.
    state = { durum: "kurulum", kod: true };
    await open("/giris.html#/ayarlar");
    await page.locator("#form-setup").waitFor();
    assert.match(await note.innerText(), /Mac terminalinde gösterilen tek kullanımlık kodu/);
    assert.equal(await page.evaluate(() => document.activeElement.id), "setup-code");
    await page.locator("#setup-code").fill("abcd-efgh-jkmn");
    await page.locator("#setup-user").fill("-kotu");
    await page.locator("#setup-pass").fill("fixture-password");
    await page.locator("#setup-pass2").fill("fixture-password");
    await page.locator("#setup-submit").click();
    assert.equal(posts.length, 0, "an invalid user name never leaves the browser");
    await page.locator("#setup-user").fill("yonetici");
    await page.locator("#setup-pass2").fill("fixture-passw0rd");
    await page.locator("#setup-submit").click();
    assert.equal(posts.length, 0, "different passwords never leave the browser");
    await page.locator("#setup-pass2").fill("fixture-password");
    reply = { status: 401, body: { error: "Kurulum kodu hatalı." } };
    await page.locator("#setup-submit").click();
    await page.getByText("Kurulum kodu hatalı.", { exact: true }).waitFor();
    assert.equal(await page.locator("#setup-pass").inputValue(), "fixture-password", "a wrong code keeps the chosen password");
    assert(!(await page.locator("#setup-submit").isDisabled()));
    for (const colorScheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme });
      for (const width of [1280, 768, 390, 320]) {
        await page.setViewportSize({ width, height: 900 });
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `setup ${colorScheme}/${width}`);
        await page.screenshot({ path: path.join(shots, `setup-${colorScheme}-${width}.png`), fullPage: true });
      }
    }
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.locator("#setup-submit").click();
    await page.waitForURL((url) => url.pathname === "/" && url.hash === "#/ayarlar");
    assert.deepEqual(posts.at(-1), { path: "/api/konsol/oturum/kur", body: { kod: "abcd-efgh-jkmn", kullanici: "yonetici", parola: "fixture-password" } });
    // Sign-in: wrong password clears it; the attempt limit's message is shown as sent.
    state = { durum: "giris" };
    await open("/giris.html#/dosyalar");
    await page.locator("#form-login").waitFor();
    assert(await page.locator("#form-setup").isHidden());
    assert.equal(await page.evaluate(() => document.activeElement.id), "login-user");
    assert.equal(await page.locator("#login-access").innerText(), "Sunucu yönetimi · Tailscale");
    await page.locator("#login-user").fill(" yonetici ");
    await page.locator("#login-pass").fill("wrong-password");
    reply = { status: 401, body: { error: "Kullanıcı adı veya parola hatalı." } };
    await page.locator("#login-submit").click();
    await page.getByText("Kullanıcı adı veya parola hatalı.", { exact: true }).waitFor();
    assert.equal(await page.locator("#login-pass").inputValue(), "");
    await page.locator("#login-pass").fill("wrong-password");
    reply = { status: 429, headers: { "Retry-After": "300" }, body: { error: "Çok fazla hatalı deneme; 300 saniye sonra yeniden deneyin." } };
    await page.locator("#login-submit").click();
    await page.getByText("Çok fazla hatalı deneme; 300 saniye sonra yeniden deneyin.", { exact: true }).waitFor();
    for (const colorScheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme });
      for (const width of [1280, 390, 320]) {
        await page.setViewportSize({ width, height: 900 });
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `login ${colorScheme}/${width}`);
        await page.screenshot({ path: path.join(shots, `login-${colorScheme}-${width}.png`), fullPage: true });
      }
    }
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.locator("#login-pass").fill("fixture-password");
    await page.locator("#login-submit").click();
    await page.waitForURL((url) => url.pathname === "/" && url.hash === "#/dosyalar");
    assert.deepEqual(posts.at(-1), { path: "/api/konsol/oturum/giris", body: { kullanici: "yonetici", parola: "fixture-password" } });
    // DD-195: the brand line names the address the backend saw.
    state = { durum: "giris", kanal: "internet" };
    await open("/giris.html");
    await page.locator("#form-login").waitFor();
    assert.equal(await page.locator("#login-access").innerText(), "Sunucu yönetimi · internet (HTTPS)");
    // An already signed-in browser goes straight back.
    state = { durum: "acik", kullanici: "yonetici", oturum_gun: 7 };
    await open("/giris.html#/moduller");
    await page.waitForURL((url) => url.pathname === "/" && url.hash === "#/moduller");
    // Real Konsol whose session ended: its first API answer sends the browser to sign in.
    state = { durum: "giris" }; konsolUnauthorized = true;
    await open("/#/ayarlar");
    await page.waitForURL((url) => url.pathname === "/giris.html" && url.hash === "#/ayarlar");
    await page.locator("#form-login").waitFor();
    assert.deepEqual(await page.evaluate(() => [Object.keys(localStorage), Object.keys(sessionStorage)]), [[], []]);
    assert.deepEqual(errors, []);
    console.log("PASS: first account (no/valid code, client checks, wrong code keeps password), sign-in (wrong/limit/success), return to the original page, signed-in shortcut, Tailscale/internet label, Konsol 401 redirect, production CSP, no browser storage, widths/both themes. Screenshots: " + shots);
  } finally { await browser.close(); }
})().catch((err) => { console.error(err); process.exit(1); });
