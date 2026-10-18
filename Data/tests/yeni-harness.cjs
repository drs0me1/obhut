/* Shared harness of Konsol's suites (DD-258): a static server for the committed build in Data/console with
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
     h.dynamic [[/regex/, (req, match) => reply | undefined], …] answers paths with variable parts
               (WireGuard's /api/konsol/wireguard/nets/<iface>/… routes) after the exact handlers;
               a handler may also return a promise of its reply (an upload the suite holds back); the page
               may give up on such a request meanwhile (it is cancelled), which is not an error;
     h.raw     (path) => true for POST paths whose body is the raw upload, not JSON (the files backend's
               …/upload): such a request is logged with body { size, text } of its bytes;
     h.unsigned(path) => true for GET paths a plain link opens without X-Konsol (a file's download);
               Playwright does not route a download, so the static server answers such a path from its
               exact handler (logged like the routed requests);
     expected  URL fragments whose failed loads (4xx/5xx) are part of the current scenario.

   const { uygulama, servis, uygulamalar, ayrinti, soru, inceleme } = require("./yeni-harness.cjs").fixtures;
     builders of the application shapes (api/sema.ts: Uygulama, UygulamaServisi, Uygulamalar, UygulamaAyrinti)
     with neutral defaults (registry.example images), and of the inspector's (Soru*, Inceleme: `inceleme`
     derives the line marks from the refusals, questions and notes as master_inspector.py does); every field can
     be overridden. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs"), http = require("node:http"), os = require("node:os"), path = require("node:path");

const root = path.join(__dirname, "../console");
// The layout audit's widths: the smallest phone, common phones, a tablet, small and large desktops.
const DUZEN_GENISLIKLER = [320, 360, 390, 768, 1024, 1280, 1920];
const tools = path.join(__dirname, "../tools/konsol-ui");
const csp = fs.readFileSync(path.join(__dirname, "../templates/Caddyfile"), "utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
assert.match(csp, /font-src 'self'/, "the console CSP allows the local Outfit font");

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".png": "image/png", ".txt": "text/plain; charset=utf-8", ".sha256": "text/plain; charset=utf-8",
  ".json": "application/json" };

/** The file for a request path as the installer lays the console out (DD-267): the build in console/yeni
    at the root, the sign-in page and the editor bundle beside it; "" when it would leave those folders. */
function staticFile(pathname) {
  let rel = "";
  try {
    rel = decodeURIComponent(pathname) + (pathname.endsWith("/") ? "index.html" : "");
  } catch {
    return "";
  }
  for (const dir of [path.join(root, "yeni"), root]) {
    const file = path.normalize(path.join(dir, rel));
    if (file.startsWith(dir + path.sep) && fs.existsSync(file) && fs.statSync(file).isFile()) return file;
  }
  return path.join(root, "yeni", "bulunamadi");
}

function staticHeaders(file) {
  return { "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff", "Cache-Control": "no-cache",
    "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" };
}

function create({ name, url, data, expected = () => [] }) {
  const base = new URL(url);
  const h = {
    base, data,
    shots: fs.mkdtempSync(path.join(os.tmpdir(), name + "-")),
    status: {},
    handlers: {},
    calls: {},
    dynamic: [],
    raw: () => false,
    unsigned: () => false,
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
    if (u.pathname.startsWith("/api/") && req.method === "GET" && h.unsigned(u.pathname) && h.handlers[u.pathname]) {
      h.calls[u.pathname] = (h.calls[u.pathname] || 0) + 1;
      h.requests.push({ method: "GET", path: u.pathname, query: u.search, body: null });
      const r = h.handlers[u.pathname]({ method: "GET", path: u.pathname, query: u.searchParams, body: null }) || { status: 404, body: { error: "fixture" } };
      res.writeHead(r.status ?? 200, { "Content-Type": r.contentType || "application/json", ...(r.headers || {}) });
      return res.end(r.contentType ? r.body : JSON.stringify(r.body));
    }
    if (u.pathname.startsWith("/api/")) {
      h.errors.push("API request reached the static server: " + u.pathname);
      res.writeHead(404);
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
    if (request.headers()["x-konsol"] !== "1" && !(request.method() === "GET" && h.unsigned(p))) h.errors.push("missing X-Konsol: " + p);
    if (p === "/api/konsol/olaylar") return route.continue();
    let body = null;
    if (request.method() === "POST" && h.raw(p)) {
      const bytes = request.postDataBuffer() || Buffer.alloc(0);
      body = { size: bytes.length, text: bytes.toString("utf8") };
    } else if (request.method() === "POST") {
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
    const held = Boolean(handled && typeof handled.then === "function");
    if (held) handled = await handled;
    const respond = () => {
      if (handled && handled.contentType) {
        return route.fulfill({ status: handled.status ?? 200, contentType: handled.contentType, headers: handled.headers, body: handled.body });
      }
      return reply(handled.status ?? 200, handled.body);
    };
    // A held reply's request may have been cancelled by the page meanwhile (an upload's "İptal").
    if (handled) return held ? respond().catch(() => undefined) : respond();
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
  // Screenshots wait for the dialogs' enter/leave transitions to end. Every screenshot's state is also measured
  // by the layout audit (duzen-denetimi.cjs) at its own width; a finding fails the suite like a console error.
  // KONSOL_DUZEN=tara also measures it at DUZEN_GENISLIKLER (the viewport is restored; a state that a resize
  // changes, such as a countdown that hides with the tab, is left out with KONSOL_DUZEN_ATLA, a pattern of
  // screenshot names); KONSOL_DUZEN=0 turns the audit off. KONSOL_DUZEN_CIKTI collects one JSON line per state.
  h.shot = async (page, file, fullPage = false) => {
    await page.waitForFunction(() => !document.querySelector('[class*="-enter-"], [class*="-leave-"]'));
    // Vue drops a transition's classes when its root's transition ends; a child's own (a sheet sliding in)
    // can run a few frames longer. Wait for every finite animation (spinners loop and are left alone).
    await page.waitForFunction(() => document.getAnimations().every((a) => a.playState !== "running" || a.effect?.getComputedTiming().iterations === Infinity));
    if (process.env.KONSOL_DUZEN !== "0") {
      const skip = process.env.KONSOL_DUZEN_ATLA && new RegExp(process.env.KONSOL_DUZEN_ATLA).test(file);
      const widths = process.env.KONSOL_DUZEN === "tara" && !skip ? DUZEN_GENISLIKLER : [];
      const results = await require("./duzen-denetimi.cjs").audit(page, widths);
      for (const r of results) {
        for (const f of r.findings) h.errors.push(`layout ${file} @${r.width}: ${f.kind} ${f.el} — ${f.detail}`);
      }
      if (process.env.KONSOL_DUZEN_CIKTI) {
        const line = { suite: name, shot: file, url: page.url().replace(/^https?:\/\/[^/]+/, ""), results };
        fs.appendFileSync(process.env.KONSOL_DUZEN_CIKTI, JSON.stringify(line) + "\n");
      }
    }
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

// ---- application fixtures (DD-271, phase 3)
const servis = (ad, o = {}) => ({ ad, durum: "calisiyor", imaj: `registry.example/${ad}:1`, guncelleme: "sabit", ...o });

const uygulama = (ad, o = {}) => ({ ad, durum: "calisiyor", bicim: "compose", servisler: [servis("web")], kaynak: { cpu: null, bellek: null },
  guncelleme: "sabit", eylemler: ["durdur", "yeniden-baslat"], revizyon: "rev-" + ad, is: null, koken: "dosya", durduruldu: false, uyari: 0, ag: null,
  adres: null, ...o });

const uygulamalar = (items, o = {}) => ({ read_at: 1791845000, items, kaynaklar: [], hatalar: [], ...o });

/** An application's detail from its list item; `servisler` overrides each service's detail by name. */
function ayrinti(item, o = {}, servisler = {}) {
  const svc = (s) => ({ ad: s.ad, durum: s.durum, baslangic: "direct", kullanici: null, imaj: s.imaj, ozet: null, kanal: s.imaj, guncelleme: s.guncelleme,
    konteyner: `${item.ad}_${s.ad}`, birim: `konsol-${item.ad}_${s.ad}.service`, calisma: null, saglik: "", yeniden_baslama: 0, portlar: [], baglamalar: [],
    gizliler: [], surecler: null, ...(servisler[s.ad] || {}) });
  return { uygulama: item, servisler: item.servisler.map(svc), gizliler: [], uyarilar: [],
    koken: { tur: item.koken, adres: null, imaj: null, konteyner: null, alindi: 1791700000, sha256: "0".repeat(64) },
    metin: "services:\n" + item.servisler.map((s) => `  ${s.ad}:\n    image: ${s.imaj}\n`).join(""), yanitlar: { name: item.ad, answers: {} },
    birimler: [`konsol-${item.ad}.network`, ...item.servisler.map((s) => `konsol-${item.ad}_${s.ad}.container`)].sort(),
    veri: `/var/lib/master-stack/uygulamalar/${item.ad}`, ag: `ksl-${item.ad}`, pod: null, guncelleme_denetlendi: null, ...o };
}

// ---- the inspector's shapes (rebuild phase 2; api/sema.ts: Soru*, Inceleme)
const soru = {
  ad: (suggest, o = {}) => ({ id: "name", kind: "name", line: 2, title: "Uygulamanın adı",
    why: "Birimlerin, ağın ve verilerin klasörünün adı olur: küçük harf, rakam ve '-', en çok 30 karakter.", suggest, ...o }),
  port: (service, port, o = {}) => {
    const protocol = o.protocol || "tcp";
    const udp = protocol === "udp";
    return { id: `port:${service}:${port}/${protocol}`, kind: "port", line: 4, title: `${service}: ${port}/${protocol.toUpperCase()}`,
      why: udp ? "UDP doğrudan port olarak eklenir ve kapalı gelir; kapsamı (Tailscale ya da internet) Erişim'den seçilir."
        : "Web arayüzü olabilir: bir adres (Caddy satırı, Tailscale adı) ya da doğrudan port olarak eklenir. Seçim sizin; dosyadaki sunucu portu kullanılmaz.",
      service, port, protocol, guess: udp ? "raw" : "web", choices: udp ? ["raw"] : ["caddy", "raw"], suggest: null, host_port: null, ...o };
  },
  degisken: (name, o = {}) => ({ id: "var:" + name, kind: "var", line: 6, title: `Değişken: \${${name}}`,
    why: o.secret ? "Gizli bir değer gibi görünüyor; Podman secret olarak verilir, diske ve tarayıcıya açık yazılmaz." : "Dosya bu değeri dışarıdan (.env) bekliyor.",
    name, secret: false, generate: false, default: null, required: false, services: ["web"], ...o }),
  gizli: (service, env, o = {}) => ({ id: `secret:${service}:${env}`, kind: "secret", line: 7, title: `${service}: ${env} (gizli değer)`,
    why: "Dosyada boş; değerini siz verirsiniz, Podman secret olur.", service, env, generate: false, services: [service], uses: [{ service, env }], ...o }),
  klasor: (service, target, o = {}) => ({ id: `mount:${service}:${target}`, kind: "mount", line: 5, title: `${service}: ${target}`,
    why: "Uygulamanın klasörüne ya da /srv altından bir klasöre bağlanır; başka bir sunucu yolu kullanılmaz.", service, target, source: "veri",
    source_kind: "named", read_only: false, suggest: "app", folder: "veri", srv_path: null, ...o }),
  baslangic: (service, o = {}) => ({ id: "start:" + service, kind: "start", line: 2, title: `${service}: nasıl başlasın?`,
    why: "Dosya kullanıcı belirtmiyor: imaj büyük olasılıkla root başlayıp kendi kullanıcısına geçiyor. Doğrudan başlatılırsa 1000:1000 ile başlar ve açılmayabilir.",
    service, suggest: "root", user: null, direct_user: "1000:1000", caps_add: [],
    open_caps: ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "SETGID", "SETPCAP", "SETUID"], ...o }),
};

/** An inspection; without `marks` they are derived as the inspector does (refusals, questions, notes by line). */
function inceleme(o = {}) {
  const value = { format: "compose", name: "ornek", pod: false, services: [], variables: [], refusals: [], notes: [], questions: [], ...o };
  if (!o.marks) {
    const order = { refuse: 0, question: 1, note: 2 };
    value.marks = [...value.refusals.map((r) => ({ line: r.line, kind: "refuse", text: r.text })),
      ...value.questions.map((q) => ({ line: q.line, kind: "question", text: q.title })),
      ...value.notes.map((n) => ({ line: n.line, kind: "note", text: n.text }))].sort((a, b) => a.line - b.line || order[a.kind] - order[b.kind]);
  }
  return value;
}

module.exports = { create, fixtures: { servis, uygulama, uygulamalar, ayrinti, soru, inceleme } };
