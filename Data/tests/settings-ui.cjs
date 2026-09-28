/* Real production UI with deterministic API fixtures; no server mutations. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const screenshots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-v136-ui-"));
const copy = (x) => JSON.parse(JSON.stringify(x));
const config = { firewall: [{id:"fixture-ci",name:"CI",family:4,scope:"wan",proto:"tcp",port:9443,source:"192.0.2.0/24",allow:false}], dns: { disabled: [], records: [], forward: false, servers: [] } };
const data = {
  read_at: 1780000000, version: "2026.08.06-v2-134", domain: "ayc", tailscale: "100.64.0.2", ts_if: "tailscale0", wan: { iface: "eth0", ipv4: "192.0.2.1" },
  firewall: { ok: true, check: "ok", wireguard_installed:false, networks:[], ports: [{ name: "SSH", family: 4, scope: "wan", port: 22, proto: "tcp", baseline: true },
      { name: "Caddy", family: 4, scope: "tail", port: 80, proto: "tcp", baseline: true }, { name: "Caddy", family: 4, scope: "wan", port: 80, proto: "tcp", baseline: false },
      { name: "Konsol · dosya arka ucu", family: 4, scope: "lo", port: 61009, proto: "tcp", baseline: true },
      { name: "SSH", family: 6, scope: "wan", port: 22, proto: "tcp", baseline: true }],
    listeners: [{ port: 22, proto: "tcp", family: 4, address: "0.0.0.0", scope:"any" },
      {port:80,proto:"tcp",family:4,address:"100.64.0.2",scope:"tail"},
      {port:61009,proto:"tcp",family:4,address:"127.0.0.1",scope:"lo"}],
    rules: { errors: [], rows: [{ family: 4, table: "filter", chain: "ts-input", position: 1, packets: 12, bytes: 1024, spec: "-i tailscale0 -j ACCEPT", owner: "Tailscale" }] } },
  web: { entries: [{ address: "panel.ayc", source: "base", access: "tailscale", routes: [{ kind: "proxy", path: "/api/*", to: "127.0.0.1:61008" }] }], raw: [] },
  dns: { listen: ["lo", "tailscale0"] }, torrent: { installed: true, profile: "/var/lib/qbittorrent" },
  manage: { revision: "r1", config: copy(config), pending: null, username: "admin", save: "/srv/downloads/", names: [{ name: "panel.ayc", target: "tailscale", source: "base" }, { name: "torrent.ayc", target: "tailscale", source: "torrent" }] },
};
let lastApply = null, writes = 0, failApply = false, holdAccount = false, releaseAccount;
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", m => {if (/violates.*Content Security Policy|Refused to|not a valid regular expression/.test(m.text())) errors.push(m.text());});
    const csp = fs.readFileSync(path.join(__dirname,"../templates/Caddyfile"),"utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
    await page.route("**/*", async route => {
      if (route.request().resourceType() !== "document") return route.continue();
      const response = await route.fetch();
      await route.fulfill({response, headers:{...response.headers(),"content-security-policy":csp}});
    });
    await page.route("**/api/**", async (route) => {
      if (route.request().method() === "POST") writes++;
      const url = new URL(route.request().url()), endpoint = url.pathname;
      let result = {};
      if (endpoint === "/api/konsol/moduller") result = { items: [{ id: "torrent", installed: true, state: "calisiyor", runtime: "host", live: "running" }] };
      else if (endpoint === "/api/konsol/kaynaklar") result = { host: "test", version: data.version, domain: "ayc", os: "Debian 13", kernel: "test", uptime: 120, cores: 2, cpu: [1], mem: { total: 1000, used: 200, graph: [20] }, net: { wan: "192.0.2.1", tailscale: data.tailscale }, root: "/srv", disk: { total: 1000, free: 800 }, ports: [{ port: 22, proto: "tcp", scope: "internet", name: "SSH" }] };
      else if (endpoint === "/api/wg/islemler") result = { items: [] };
      else if (endpoint === "/api/state") result = {root:"/srv", temp:"downloads/incomplete", disk:{total:10000,free:8000}, trash:{count:0,size:0}};
      else if (endpoint === "/api/list") result = {path:"",entries:[]};
      else if (endpoint === "/api/archives") result = {items:[], limits:{bytes:2147483648,entries:10000,layers:5,seconds:900}};
      else if (endpoint === "/api/konsol/moduller/torrent/hesap") result = {user:"admin",temp:false};
      else if (endpoint === "/api/konsol/ayarlar") result = data;
      else if (endpoint === "/api/konsol/ayarlar/durum") result = data.manage;
      else if (endpoint === "/api/konsol/ayarlar/klasorler") result = { items: [{ path: "/srv/downloads", free: 10000000000 }, { path: "/srv/media", free: 10000000000 }] };
      else if (endpoint === "/api/konsol/ayarlar/uygula") {
        lastApply = route.request().postDataJSON();
        assert.equal(lastApply.revision, data.manage.revision, "Draft revision follows our own account commit");
        if (holdAccount && lastApply.torrent) await new Promise(resolve => { releaseAccount = resolve; });
        if (failApply) {
          failApply = false;
          return route.fulfill({status:400, contentType:"application/json", body:JSON.stringify({error:lastApply.torrent ? "Hesap sınama hatası; önceki ayarlar korundu." : "DNS sınama hatası; önceki ayarlar korundu."})});
        }
        if (lastApply.firewall) data.manage.config.firewall = copy(lastApply.firewall);
        if (lastApply.dns) data.manage.config.dns = copy(lastApply.dns);
        data.manage.pending = { id: "transaction", seconds: 60, phase: "awaiting" };
        if (lastApply.domain) {
          data.manage.pending.domain = { old: "ayc", new: lastApply.domain };
          data.manage.pending.seconds = 300;
        }
        result = { pending: data.manage.pending };
        if (Object.keys(lastApply).sort().join(",") === "dns,revision") {
          data.manage.pending = null; data.manage.revision += "-dns";
          result = {pending:null, committed:true};
        }
        if (Object.keys(lastApply).sort().join(",") === "revision,torrent" && !lastApply.torrent.save) {
          data.manage.username = lastApply.torrent.username ?? data.manage.username;
          data.manage.pending = null; data.manage.revision += "-account";
          result = {pending:null, committed:true};
        }
      } else if (endpoint.endsWith("/onayla")) { data.manage.pending = null; data.manage.revision = "r2"; result = { ok: true }; }
      else if (endpoint.endsWith("/geri-al")) { data.manage.pending = null; data.manage.config = copy(config); result = { ok: true }; }
      else throw new Error("Unexpected endpoint " + endpoint);
      await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(result) });
    });
    await page.goto((process.env.KONSOL_URL || "http://127.0.0.1:8766") + "/#/ayarlar");
    await page.getByRole("tab", { name: "Güvenlik Duvarı" }).click();
    const category = name => page.getByRole("tablist",{name:"Trafik kategorileri",exact:true}).getByRole("tab",{name,exact:true});
    assert.equal(await category("Tailscale").getAttribute("aria-selected"),"true");
    assert.equal(await category("WireGuard").count(),0);
    assert.match(await page.locator(".as-ports").innerText(), /Bu ağda dinliyor/);
    assert.equal(await page.locator(".as-ports details").count(),0);
    assert.equal(await page.locator(".as-ports thead th").count(),7);
    assert.equal(await page.locator(".as-ports th[scope=row]").count(),1);
    await category("Tailscale").focus(); await page.keyboard.press("ArrowRight");
    assert.equal(await category("İnternet").getAttribute("aria-selected"),"true");
    assert.equal(await page.evaluate(() => document.activeElement.id),"as-fw-tab-wan");
    assert.match(await page.locator(".as-ports").innerText(), /Tüm IPv4 arayüzlerinde dinler/);
    assert.match(await page.locator(".as-ports").innerText(),/Sunucuya uzaktan terminal bağlantısı/);
    assert.match(await page.locator(".as-ports").innerText(),/192\.0\.2\.0\/24/);
    assert.match(await page.locator(".as-ports").innerText(),/Başka adreste dinliyor/);
    await page.keyboard.press("End");
    assert.equal(await category("Sunucu içi").getAttribute("aria-selected"),"true");
    assert(await page.getByRole("switch",{name:"Konsol · dosya arka ucu Sunucu içi tcp 61009",exact:true}).isDisabled());
    assert.match(await page.locator(".as-ports").innerText(),/Sunucu içinde dinliyor/);
    assert.equal(await page.getByRole("button",{name:"+ Port kuralı",exact:true}).count(),0);
    await page.keyboard.press("Home");
    assert.equal(await page.locator(".as-ports tbody tr").count(),1);
    await category("İnternet").click();
    await page.getByRole("combobox",{name:"Adres ailesi",exact:true}).selectOption("6");
    assert.equal(await page.locator(".as-ports th[scope=row]").count(),1);
    assert.match(await page.locator(".as-ports").innerText(),/Dinleyici yok/);
    await category("Tailscale").click();
    assert.match(await page.locator(".as-ports").innerText(),/Bu seçimde kayıt yok/);
    await page.getByRole("combobox",{name:"Adres ailesi",exact:true}).selectOption("4");
    await category("İnternet").click();
    const ci = page.locator(".as-ports tbody tr").filter({has:page.getByRole("rowheader",{name:/^CI /})});
    await ci.getByRole("button",{name:"Düzenle",exact:true}).click();
    await page.getByRole("textbox",{name:"Kaynak IP/CIDR",exact:true}).fill("192.0.2.5/32");
    await page.getByRole("button",{name:"Devam et",exact:true}).click();
    assert.match(await ci.innerText(),/192\.0\.2\.5\/32/);
    assert.match(await ci.innerText(),/Taslak · henüz uygulanmadı/);
    await ci.getByRole("button",{name:"Kuralı kaldır",exact:true}).click();
    assert.equal(await ci.count(),0);
    assert.equal(writes,0, "Table edits only stage drafts");
    await page.getByRole("button",{name:"Vazgeç",exact:true}).click();
    await page.getByRole("switch", { name: "SSH İnternet tcp 22", exact: true }).click();
    assert.match(await page.locator(".as-footer").innerText(), /1 değişiklik/);
    await category("Tailscale").click();
    assert.match(await page.locator(".as-footer").innerText(), /1 değişiklik/);
    await category("İnternet").click();
    assert.equal(await page.getByRole("switch", { name: "SSH İnternet tcp 22", exact: true }).getAttribute("aria-checked"), "false");
    await page.getByRole("button", { name: "Vazgeç", exact: true }).click();
    assert.equal(await page.getByRole("switch", { name: "SSH İnternet tcp 22", exact: true }).getAttribute("aria-checked"), "true");
    await page.getByRole("button", { name: "Teknik kurallar", exact: true }).click();
    assert.match(await page.locator(".as-rules").innerText(), /ts-input/);
    assert.match(await page.locator(".as-rules").innerText(), /Eşleşen pakete bu zincirde izin verir/);
    assert.match(await page.locator(".as-rules").innerText(), /Salt okunur · bu panelden değiştirilmez/);
    assert.equal(await page.locator(".as-rules").getByRole("switch").count(),0);
    await page.getByRole("tab", { name: "Caddy", exact: true }).click();
    assert.match(await page.locator("#cfg-web").innerText(), /panel.ayc/);
    await page.getByRole("tab", { name: "Dnsmasq", exact: true }).click();
    assert(await page.getByRole("switch", {name:"panel.ayc", exact:true}).isDisabled());
    const dnsWrites = writes;
    await page.getByRole("switch", {name:"torrent.ayc", exact:true}).click();
    await page.getByRole("button", {name:"Uygula", exact:true}).click();
    await page.waitForFunction(() => document.querySelector(".as-message")?.textContent.includes("Dnsmasq ayarları uygulandı ve kaydedildi"));
    await page.waitForFunction(() => document.querySelector(".as-footer")?.textContent.includes("Kaydedilmemiş değişiklik yok"));
    assert.equal(writes, dnsWrites + 1, "DNS uses a single Apply request, no confirmation POST");
    assert.deepEqual(Object.keys(lastApply).sort(), ["dns", "revision"]);
    assert.deepEqual(data.manage.config.dns.disabled, ["torrent.ayc"]);
    assert.equal(await page.locator("dialog[open], .as-rollback").count(), 0);
    await page.reload();
    await page.getByRole("switch", {name:"torrent.ayc", exact:true}).waitFor();
    assert.equal(await page.getByRole("switch", {name:"torrent.ayc", exact:true}).getAttribute("aria-checked"), "false");
    await page.getByRole("switch", {name:"torrent.ayc", exact:true}).click();
    failApply = true;
    await page.getByRole("button", {name:"Uygula", exact:true}).click();
    await page.waitForFunction(() => document.querySelector(".as-message")?.textContent.includes("DNS sınama hatası"));
    assert.deepEqual(data.manage.config.dns.disabled, ["torrent.ayc"]);
    assert.equal(await page.locator(".as-rollback").count(), 0);
    assert.match(await page.locator(".as-footer").innerText(), /1 değişiklik taslakta/);
    await page.getByRole("button", {name:"Uygula", exact:true}).click();
    await page.waitForFunction(() => document.querySelector(".as-footer")?.textContent.includes("Kaydedilmemiş değişiklik yok"));
    assert.deepEqual(data.manage.config.dns.disabled, []);
    await page.getByRole("switch", { name: "torrent.ayc", exact: true }).click();
    await page.getByRole("button", { name: "+ Alan adı", exact: true }).click();
    await page.getByRole("textbox", { name: "Tam alan adı" }).fill("nas.ayc");
    await page.getByRole("button", { name: "Devam et" }).click();
    await page.getByRole("switch", { name: "Üst DNS'e yönlendirme", exact: true }).click();
    await page.getByLabel("Sağlayıcı", { exact: true }).selectOption("google");
    await page.locator('.nav [data-route="torrent"]').click();
    const accountWrites = writes;
    const username = page.getByRole("textbox", {name:"Kullanıcı adı", exact:true});
    const password = page.getByLabel("Yeni parola", {exact:true});
    const repeat = page.getByLabel("Yeni parola (tekrar)", {exact:true});
    const saveAccount = page.getByRole("button", {name:"Hesabı kaydet", exact:true});
    await username.fill("bad user");
    assert.equal(await username.evaluate(el => el.checkValidity()), false);
    await saveAccount.click();
    assert.equal(writes, accountWrites);
    await username.fill("new-user");
    assert.equal(await username.evaluate(el => el.checkValidity()), true);
    assert.equal(await password.evaluate(el => el.minLength), 8);
    await password.fill("1234567"); await repeat.fill("1234567");
    await saveAccount.click();
    assert.equal(writes, accountWrites);
    await password.fill("sample-ui-only-password"); await repeat.fill("mismatched-password");
    await saveAccount.click();
    assert.equal(writes, accountWrites);
    await repeat.fill("sample-ui-only-password");
    holdAccount = true;
    await saveAccount.click();
    await page.waitForFunction(() => document.querySelector(".as-message")?.textContent.includes("hesabı kaydediliyor"));
    assert(await saveAccount.isDisabled());
    assert(await password.isDisabled());
    assert.equal(await password.inputValue(), "");
    while (!releaseAccount) await page.waitForTimeout(10);
    holdAccount = false; releaseAccount();
    await page.waitForFunction(() => document.querySelector(".as-message")?.textContent.includes("hesabı kaydedildi."));
    await page.waitForFunction(() => !document.querySelector('input[name=username]').disabled);
    assert.equal(writes, accountWrites + 1, "One click = one account-only request, no confirmation");
    assert.deepEqual(Object.keys(lastApply).sort(), ["revision", "torrent"]);
    assert.deepEqual(lastApply.torrent, {username:"new-user", password:"sample-ui-only-password"});
    assert.equal(await username.inputValue(), "new-user");
    assert.equal(await password.inputValue(), "");
    assert.equal(await page.locator("dialog[open], .as-rollback").count(), 0);
    assert(!((await page.locator("body").innerText()).includes("sample-ui-only-password")));
    assert.match(await page.locator(".as-footer").innerText(), /3 değişiklik taslakta/, "Unrelated DNS drafts remain unapplied");
    assert.equal(data.manage.config.dns.records.length, 0);
    // Username-only preserves the password; password-only leaves the username alone.
    await username.fill("another-user"); await saveAccount.click();
    await page.waitForFunction(() => !document.querySelector('input[name=username]').disabled);
    assert.deepEqual(lastApply.torrent, {username:"another-user"});
    await page.getByLabel("Yeni parola", { exact: true }).fill("Pass8!xy");
    await page.getByLabel("Yeni parola (tekrar)", { exact: true }).fill("Pass8!xy");
    await saveAccount.click();
    await page.waitForFunction(() => !document.querySelector('input[name=username]').disabled);
    assert.deepEqual(lastApply.torrent, {password:"Pass8!xy"});
    const noChangeWrites = writes;
    await saveAccount.click();
    assert.equal(writes, noChangeWrites, "Unchanged account does not restart the service");
    failApply = true;
    await username.fill("failed-user");
    await password.fill("failed-test-password"); await repeat.fill("failed-test-password");
    await saveAccount.click();
    await page.waitForFunction(() => document.querySelector(".as-message")?.textContent.includes("Hesap kaydı doğrulanamadı"));
    assert.equal(data.manage.username, "another-user");
    assert.equal(await password.inputValue(), "");
    assert.equal(await repeat.inputValue(), "");
    assert.equal(await page.locator(".as-rollback").count(), 0);
    await username.fill("new-user");
    await password.fill("sample-ui-only-password"); await repeat.fill("sample-ui-only-password");
    await saveAccount.click();
    await page.waitForFunction(() => !document.querySelector('input[name=username]').disabled);
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
    assert.deepEqual(lastApply.torrent, {save:"/srv/media"}, "Account secrets are never staged with other settings");
    await page.getByRole("button", { name: "Bağlantı çalışıyor · onayla" }).click();
    await page.waitForFunction(() => !document.querySelector(".as-rollback"));
    await page.reload();
    await username.waitFor();
    assert.equal(await username.inputValue(), "new-user");
    assert.equal(await page.locator(".as-footer").count(), 0, "No misleading draft footer on the clean account page");
    for (const colorScheme of ["light", "dark"]) {
      await page.emulateMedia({colorScheme});
      for (const width of [1400, 1024, 736, 390, 320]) {
        await page.setViewportSize({width, height:1000});
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        const boxes = await page.locator("#torrent-settings").evaluate(root => {
          const rect = el => {const r = el.getBoundingClientRect(); return {x:r.x, y:r.y, width:r.width, height:r.height};};
          return {fields:[...root.querySelectorAll("input")].map(rect),
            headers:[...root.querySelectorAll(".card-head")].map(rect),
            buttons:[...root.querySelectorAll(".as-body button")].map(rect),
            path:rect(root.querySelector("div.as-body > code"))};
        });
        const [user, pass, again] = boxes.fields;
        const near = (a,b) => Math.abs(a-b) < 1;
        assert(near(user.height,pass.height) && near(pass.height,again.height), `equal controls at ${width}`);
        assert(user.height >= 44, "Readable input height");
        assert(near(user.x, boxes.headers[0].x) && near(user.x, boxes.buttons[0].x), "Heading/field/Save left edge");
        assert(near(boxes.path.x, boxes.headers[1].x), "Download path aligned with heading");
        if (width > 700) {
          assert(near(pass.y,again.y) && near(pass.width,again.width), `password row at ${width}`);
          assert(near(boxes.path.y + boxes.path.height/2, boxes.buttons[1].y + boxes.buttons[1].height/2), "Path and folder action share a row");
        } else {
          assert(near(user.x,again.x) && near(user.width,again.width) && again.y > pass.y + pass.height);
          assert(near(boxes.path.x, boxes.buttons[1].x), "Mobile folder action left edge");
        }
        await page.screenshot({path:path.join(screenshots, `account-${colorScheme}-${width}.png`), fullPage:true});
      }
    }
    const originalSave = data.manage.save;
    data.manage.save = "/srv/downloads/" + "long-folder-name-".repeat(24);
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await page.getByText(data.manage.save,{exact:true}).waitFor();
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "Long folder path wraps on mobile");
    data.manage.save = originalSave;
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await page.getByText(originalSave,{exact:true}).waitFor();
    await page.emulateMedia({colorScheme:"light"});
    await page.setViewportSize({width:1400, height:1000});
    await page.locator('.nav [data-route="ayarlar"]').click();
    await page.getByRole("tab", { name: "Güvenlik Duvarı" }).click();
    await category("İnternet").click();
    await page.getByRole("button", { name: "+ Port kuralı", exact: true }).click();
    await page.getByRole("textbox", { name: "Ad", exact: true }).fill("Test port");
    await page.getByRole("spinbutton", { name: "Port", exact: true }).fill("12345");
    await page.getByRole("button", { name: "Devam et" }).click();
    await page.getByRole("switch",{name:"Test port İnternet tcp 12345",exact:true}).click();
    assert.equal(await page.getByRole("switch",{name:"Test port İnternet tcp 12345",exact:true}).getAttribute("aria-checked"),"false");
    await page.getByRole("button", { name: "İncele ve uygula" }).click();
    await page.getByRole("button", { name: "Sunucuda uygula", exact: true }).click();
    await page.locator(".as-rollback").waitFor();
    assert.equal(lastApply.firewall.find(r => r.name === "Test port").allow,false);
    assert(await page.getByRole("switch",{name:"Test port İnternet tcp 12345",exact:true}).isDisabled());
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
    for (const width of [1400, 1024, 736, 390, 320]) {
      await page.setViewportSize({ width, height: 900 });
      for (const name of ["Sistem", "Güvenlik Duvarı", "Caddy", "Dnsmasq", "Günlük"]) {
        await page.getByRole("tab", { name, exact: true }).click();
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `overflow at ${width} / ${name}`);
        if (name === "Güvenlik Duvarı") {
          for (const label of ["Teknik kurallar","Portlara dön"]) {
            await page.getByRole("button",{name:label,exact:true}).click();
            const region = page.locator(".as-fw-scroll");
            assert.equal(await region.locator("thead").evaluate(el => getComputedStyle(el).display),"table-header-group");
            assert.equal(await region.locator("tbody tr").first().evaluate(el => getComputedStyle(el).display),"table-row");
            if (width <= 736) {
              assert(await region.evaluate(el => el.scrollWidth > el.clientWidth));
              await region.focus(); await page.keyboard.press("ArrowRight"); await page.waitForTimeout(120);
              assert(await region.evaluate(el => el.scrollLeft > 0),"Keyboard scroll");
            }
            const bounds = await page.evaluate(() => ({window:innerWidth, page:document.documentElement.scrollWidth,
              boxes:[...document.querySelectorAll('.main,.content,#settings-page,#as-view,.as-card,.as-fw-scroll')].map(el => [el.className || el.id,el.clientWidth,el.scrollWidth])}));
            assert(bounds.page <= bounds.window + 1,`${width}/${label}: ${JSON.stringify(bounds)}`);
          }
          // The toggle remains reachable in the actual horizontally scrolled table.
          const ssh = page.getByRole("switch",{name:"SSH İnternet tcp 22",exact:true});
          await ssh.click(); assert.equal(await ssh.getAttribute("aria-checked"),"false");
          await page.getByRole("button",{name:"Vazgeç",exact:true}).click();
        }
      }
    }
    await page.emulateMedia({ colorScheme: "dark" });
    await page.getByRole("tab",{name:"Güvenlik Duvarı",exact:true}).click();
    await page.screenshot({path:path.join(screenshots,"firewall-mobile-dark.png"),fullPage:true});
    await page.setViewportSize({width:1440,height:1000});
    await page.screenshot({path:path.join(screenshots,"firewall-desktop-dark.png"),fullPage:true});
    await page.getByRole("tab", { name: "Dnsmasq", exact: true }).click();
    await page.screenshot({ path: path.join(screenshots, "mobile-dark.png"), fullPage: true });
    // Installation state controls the VPN category, independently of network count.
    await page.getByRole("tab", { name: "Güvenlik Duvarı", exact: true }).click();
    data.firewall.wireguard_installed = true;
    await page.getByRole("button", {name:"Yenile",exact:true}).click();
    await category("WireGuard").click();
    assert.match(await page.locator("#as-fw-content").innerText(),/Henüz yönetilebilir bir WireGuard ağı yok/);
    assert.equal(await page.getByRole("button",{name:"+ Port kuralı",exact:true}).count(),0);
    data.firewall.networks = [{iface:"wg0",label:"Ev",active:true}, {iface:"wg1",label:"Telefon",active:false}];
    data.firewall.ports.push(
      {name:"WireGuard wg0",family:4,scope:"wan",port:51820,proto:"udp",baseline:true},
      {name:"VPN arayüzü",family:4,scope:"wg0",port:8080,proto:"tcp",baseline:true},
      {name:"VPN arayüzü",family:4,scope:"wg1",port:8080,proto:"tcp",baseline:false});
    data.firewall.listeners.push({port:8080,proto:"tcp",family:4,address:"10.8.0.1",scope:"wg0"});
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await page.getByRole("combobox",{name:"WireGuard ağı",exact:true}).waitFor();
    await page.waitForFunction(() => document.querySelectorAll(".as-ports th[scope=row]").length === 2);
    assert(!((await page.locator(".as-ports").innerText()).includes("51820")));
    await page.getByRole("combobox",{name:"WireGuard ağı",exact:true}).selectOption("wg1");
    assert.equal(await page.locator(".as-ports th[scope=row]").count(),1);
    assert.match(await page.locator(".as-ports").innerText(),/Başka adreste dinliyor/);
    await page.getByRole("button",{name:"+ Port kuralı",exact:true}).click();
    assert.equal(await page.getByRole("combobox",{name:"Kapsam",exact:true}).inputValue(),"wg1");
    await page.getByRole("textbox",{name:"Ad",exact:true}).fill("VPN draft");
    await page.getByRole("spinbutton",{name:"Port",exact:true}).fill("9000");
    await page.getByRole("button",{name:"Devam et",exact:true}).click();
    assert(await page.getByRole("switch",{name:"VPN draft wg1 tcp 9000",exact:true}).count());
    await category("İnternet").click();
    assert(await page.getByRole("switch",{name:"WireGuard wg0 İnternet udp 51820",exact:true}).count());
    assert.match(await page.locator(".as-footer").innerText(),/1 değişiklik/);
    await page.getByRole("button",{name:"Vazgeç",exact:true}).click();
    await category("WireGuard").click();
    await page.screenshot({path:path.join(screenshots,"wireguard-networks.png"),fullPage:true});
    data.firewall.wireguard_installed = false;
    data.firewall.networks = [];
    data.firewall.ports = data.firewall.ports.filter(r => !r.scope.startsWith("wg") && r.port !== 51820);
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await category("WireGuard").waitFor({state:"detached"});
    assert.equal(await category("Tailscale").getAttribute("aria-selected"),"true");
    // An allowed policy must never disguise a loopback-only or unreadable socket.
    data.firewall.listeners = [{port:80,proto:"tcp",family:4,address:"127.0.0.1",scope:"lo"}];
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await page.getByText("Yalnız sunucu içinde",{exact:true}).waitFor();
    assert.equal(await page.getByRole("switch",{name:"Caddy Tailscale tcp 80",exact:true}).getAttribute("aria-checked"),"true");
    data.firewall.listeners = [{port:80,proto:"tcp",family:4,address:"10.10.0.1",scope:"unknown"}];
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await page.getByText("Ağ eşleşmesi bilinmiyor",{exact:true}).waitFor();
    data.firewall.listeners = null;
    await page.getByRole("button",{name:"Yenile",exact:true}).click();
    await page.getByText("Dinleyici durumu bilinmiyor.",{exact:true}).waitFor();
    assert.deepEqual(errors, []);
    assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
    console.log("PASS: network categories/WG lifecycle and multi-network selection/listener versus permission/keyboard tabs/draft retention, full firewall tables/toggles/rollback, DNS immediate single Apply/persistence/failure/retry/protected panel/mixed confirmation, credentials/path, qBittorrent field/heading/action alignment and long paths in 5 widths/both themes, domain transaction, keyboard scroll, production CSP. Screenshots: " + screenshots);
  } finally { await browser.close(); }
})().catch((err) => { console.error(err); process.exit(1); });
