/* Shared harness of the /yeni/ suites (DD-258): a static server for the committed build in Data/console with
   the real CSP from Data/templates/Caddyfile on every page response, its own /api/konsol/olaylar event
   stream (held open so a suite can push events), fixture replies for every other /api/* request through
   Playwright routes, a log of those requests (POST bodies included), and a collector that fails the suite on
   any console error, CSP violation or page error. Never contacts a server.

   const h = require("./yeni-harness.cjs").create({ name, url, data, expected: () => [...] });
     data      { "<path after /api/konsol/>": reply } for GET requests, read at request time;
     h.status  { "/api/konsol/…": code } forces a status for that path;
     h.handlers{ "/api/konsol/…": (req) => ({ status, body }) | undefined } answers before data
               (req: { method, path, query (URLSearchParams), body (parsed JSON or null) }); a reply with
               `contentType` is sent as it is (a PNG, a text file) instead of as JSON;
     h.dynamic [[/regex/, (req, match) => reply | undefined], …] answers paths with variable parts (a
               package's /api/uygulama/<id>/… routes) after the exact handlers;
     expected  URL fragments whose failed loads (4xx/5xx) are part of the current scenario. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs"), http = require("node:http"), os = require("node:os"), path = require("node:path");

const root = path.join(__dirname, "../console");
const tools = path.join(__dirname, "../tools/konsol-ui");
const csp = fs.readFileSync(path.join(__dirname, "../templates/Caddyfile"), "utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
assert.match(csp, /font-src 'self'/, "the console CSP allows the local Outfit font");

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".png": "image/png", ".txt": "text/plain; charset=utf-8", ".sha256": "text/plain; charset=utf-8" };

/** The file under console/ for a request path, or "" when it would leave that folder. */
function staticFile(pathname) {
  let file = "";
  try {
    file = path.normalize(path.join(root, decodeURIComponent(pathname) + (pathname.endsWith("/") ? "index.html" : "")));
  } catch {
    return "";
  }
  return file.startsWith(root + path.sep) ? file : "";
}

function staticHeaders(file) {
  return { "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff", "Cache-Control": "no-cache",
    "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" };
}

function create({ name, url, data, expected = () => [] }) {
  const base = new URL(url);
  const h = {
    root, tools, csp, base, data,
    shots: fs.mkdtempSync(path.join(os.tmpdir(), name + "-")),
    status: {},
    handlers: {},
    calls: {},
    dynamic: [],
    requests: [],
    errors: [],
    stream: { mode: "live", clients: new Set(), connections: 0, lastConnect: 0, headers: [] },
    browser: null,
  };

  h.server = http.createServer((req, res) => {
    const u = new URL(req.url, base);
    if (u.pathname === "/api/konsol/olaylar") {
      h.stream.headers.push({ konsol: req.headers["x-konsol"], accept: req.headers.accept });
      h.stream.connections += 1;
      if (h.stream.mode !== "live") {
        res.writeHead(h.stream.mode, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: "fixture" }));
      }
      res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store" });
      res.write("retry: 3000\n\n: canli\n\n");
      h.stream.clients.add(res);
      h.stream.lastConnect = Date.now();
      req.on("close", () => h.stream.clients.delete(res));
      return;
    }
    if (u.pathname.startsWith("/api/")) {
      h.errors.push("API request reached the static server: " + u.pathname);
      res.writeHead(404);
      return res.end();
    }
    if (u.pathname === "/yeni") {
      res.writeHead(308, { Location: "/yeni/" });
      return res.end();
    }
    const file = staticFile(u.pathname);
    if (!file) {
      res.writeHead(403);
      return res.end();
    }
    fs.readFile(file, (err, body) => {
      res.writeHead(err ? 404 : 200, staticHeaders(file));
      res.end(err ? "bulunamadı" : body);
    });
  });

  h.push = (event, payload) => {
    const text = `event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`;
    for (const res of h.stream.clients) res.write(text);
  };

  h.waitFor = async (predicate, what, ms = 5000) => {
    const until = Date.now() + ms;
    while (!predicate()) {
      if (Date.now() > until) throw new Error("timed out: " + what);
      await new Promise((r) => setTimeout(r, 20));
    }
  };

  /** Answers one /api/* request from the handlers, the forced statuses and the fixtures. */
  h.answer = async (route) => {
    const request = route.request(), u = new URL(request.url()), p = u.pathname;
    h.calls[p] = (h.calls[p] || 0) + 1;
    if (request.headers()["x-konsol"] !== "1") h.errors.push("missing X-Konsol: " + p);
    if (p === "/api/konsol/olaylar") return route.continue();
    let body = null;
    if (request.method() === "POST") {
      if (request.headers()["content-type"] !== "application/json") h.errors.push("POST without application/json: " + p);
      try {
        body = JSON.parse(request.postData() || "null");
      } catch {
        h.errors.push("POST body is not JSON: " + p);
      }
    }
    h.requests.push({ method: request.method(), path: p, query: u.search, body });
    const reply = (status, value) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(value) });
    if (h.status[p]) {
      const code = h.status[p];
      return reply(code, code === 401 ? { error: "Oturum gerekli; yeniden giriş yapın.", giris: true } : { error: "fixture" });
    }
    const handler = h.handlers[p];
    const req = { method: request.method(), path: p, query: u.searchParams, body };
    let handled = handler && handler(req);
    for (const [pattern, answer] of handler ? [] : h.dynamic) {
      const match = pattern.exec(p);
      if (match && (handled = answer(req, match))) break;
    }
    if (handled && handled.contentType) {
      return route.fulfill({ status: handled.status ?? 200, contentType: handled.contentType, headers: handled.headers, body: handled.body });
    }
    if (handled) return reply(handled.status ?? 200, handled.body);
    if (p === "/api/konsol/oturum") return reply(200, { durum: "giris", kanal: "internet" });
    if (p === "/api/konsol/oturum/giris") {
      delete h.status["/api/konsol/kaynaklar"];  // signed in: the session works again
      return reply(200, { durum: "acik" });
    }
    const key = p.replace(/^\/api\/konsol\//, "");
    if (request.method() !== "GET" || !(key in h.data)) {
      h.errors.push(`unexpected request: ${request.method()} ${p}`);
      return reply(404, { error: "fixture" });
    }
    return reply(200, h.data[key]);
  };

  /** Collects console errors (except the expected failed loads), CSP violations and page errors. */
  h.watch = async (page) => {
    await page.addInitScript(() => {
      document.addEventListener("securitypolicyviolation", (e) => console.error(`CSP violation: ${e.violatedDirective} ${e.blockedURI}`));
    });
    page.on("pageerror", (e) => h.errors.push("pageerror: " + e.message));
    page.on("console", (m) => {
      if (m.type() !== "error" && !/Content Security Policy|Refused to/.test(m.text())) return;
      const where = m.location()?.url || "";
      if (/^Failed to load resource/.test(m.text()) && expected().some((f) => where.includes(f))) return;
      h.errors.push(`console ${m.type()}: ${m.text()} ${where}`);
    });
  };

  h.newPage = async (options = {}, { clock = false } = {}) => {
    const context = await h.browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: "light", reducedMotion: "no-preference", ...options });
    const page = await context.newPage();
    if (clock) await page.clock.install();
    await h.watch(page);
    await page.route("**/api/**", h.answer);
    return page;
  };

  /** A page whose origin is https://<host> (no real server or TLS: Playwright answers every request from
      console/ and the fixtures). The event stream answers 404 there, so the page polls. */
  h.newHttpsPage = async (host, options = {}) => {
    const context = await h.browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: "light", ...options });
    const page = await context.newPage();
    await h.watch(page);
    await page.route(`https://${host}/**`, async (route) => {
      const u = new URL(route.request().url());
      if (u.pathname === "/api/konsol/olaylar") {
        h.stream.connections += 1;
        return route.fulfill({ status: 404, contentType: "application/json", body: '{"error":"fixture"}' });
      }
      if (u.pathname.startsWith("/api/")) return h.answer(route);
      const file = staticFile(u.pathname);
      if (!file || !fs.existsSync(file)) return route.fulfill({ status: 404, body: "bulunamadı" });
      return route.fulfill({ status: 200, headers: staticHeaders(file), body: fs.readFileSync(file) });
    });
    return page;
  };

  h.count = (key) => h.calls["/api/konsol/" + key] || 0;
  h.posts = (key) => h.requests.filter((r) => r.method === "POST" && r.path === "/api/konsol/" + key).map((r) => r.body);
  h.noHorizontalScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1);
  /** Elements with an inline style: the CSP forbids them, so there must be none. An empty style="" is not
      counted: Playwright's screenshot leaves one on a text field it had to hide the caret of. */
  h.styleAttributes = (page) => page.locator("body *").evaluateAll((els) =>
    els.filter((e) => (e.getAttribute("style") ?? "").trim() !== "").map((e) => `${e.tagName}.${e.className}: ${e.getAttribute("style")}`));
  // Screenshots wait for the dialogs' enter/leave transitions to end.
  h.shot = async (page, file, fullPage = false) => {
    await page.waitForFunction(() => !document.querySelector('[class*="-enter-"], [class*="-leave-"]'));
    await page.screenshot({ path: path.join(h.shots, file), fullPage });
  };

  /** The suites test the committed build: it must match its sources and name the pinned packages it bundles. */
  h.checkBuild = () => {
    const digest = childProcess.execFileSync("sh", [path.join(tools, "kaynak-ozeti.sh")], { encoding: "utf8" }).trim();
    assert.equal(fs.readFileSync(path.join(root, "yeni/kaynak.sha256"), "utf8"), digest + "\n", "console/yeni is built from the current sources (npm run derle)");
    const pinned = JSON.parse(fs.readFileSync(path.join(tools, "package.json"), "utf8")).dependencies;
    const bundle = fs.readFileSync(path.join(root, "yeni/app.js"), "utf8");
    assert.match(bundle, /^\/\*! Konsol \(DD-258\)/);
    assert(bundle.includes(` *   vue-router ${pinned["vue-router"]} — Copyright`) && bundle.includes(` *   @vue/runtime-core ${pinned.vue} — Copyright`), "licence banner");
  };

  h.start = async () => {
    await new Promise((resolve, reject) => { h.server.once("error", reject); h.server.listen(Number(base.port || 80), base.hostname, resolve); });
    h.browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  };

  h.stop = async () => {
    if (h.browser) await h.browser.close();
    h.server.close();
    for (const res of h.stream.clients) res.destroy();
  };

  return h;
}

module.exports = { create };
