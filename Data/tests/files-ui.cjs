/* Production Files UI: independent account forms, navigation, list/cards, trash. */
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const shots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-v144-files-"));
const csp = fs.readFileSync(path.join(__dirname, "../templates/Caddyfile"), "utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
const shares = { enabled: true, running: true, max: 32, host: "http://100.64.0.2:61010", items: [] };
const trashFixtures = [
  {id:"trash-short",name:"notlar.txt",type:"file",from:"",size:1024,deleted:Date.now()/1000-300},
  {id:"trash-long",name:"Uzun.dosya.adı.".repeat(12)+"1080p.2026.zip",type:"file",from:"downloads/"+"çok-uzun-klasör/".repeat(12),size:7*1024**3,deleted:Date.now()/1000-3600},
  {id:"trash-unbroken",name:"x".repeat(251)+".zip",type:"file",from:"media/"+"y".repeat(255),size:2*1024**4,deleted:Date.now()/1000-86400},
  {id:"trash-folder",name:"Belgeler ve Türkçe klasör adı",type:"dir",from:"media/Belgeler",size:4096,deleted:Date.now()/1000-172800},
];
let trash = [], trashWrites = [];
let submitted, failShare = false, holdShare = false, releaseShare;
const shareWrites = [], deleted = [], longFile = "x".repeat(251) + ".iso";
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    await page.addInitScript(() => {
      window.copiedShareTexts = [];
      window.requestedDownloads = [];
      const click = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        if (this.hasAttribute("download")) { window.requestedDownloads.push(this.href); return; }
        return click.call(this);
      };
      if (navigator.clipboard) navigator.clipboard.writeText = async text => { window.copiedShareTexts.push(text); };
      const original = document.execCommand.bind(document);
      document.execCommand = (command, ...args) => {
        if (command !== "copy") return original(command, ...args);
        window.copiedShareTexts.push(document.querySelector("textarea[aria-hidden=true]").value);
        return true;
      };
    });
    const checkShareAddress = async locator => {
      const expected = shares.items[0].url;
      assert.equal(await locator.locator("code").textContent(), expected);
      assert(!/[^\x21-\x7e]/.test(expected), "share URL contains whitespace or non-ASCII characters");
      const geometry = await locator.evaluate(el => {
        const rect = node => { const r=node.getBoundingClientRect(); return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}; };
        return {group:rect(el),text:rect(el.querySelector("code")),button:rect(el.querySelector("button"))};
      });
      assert(Math.abs(geometry.button.left-geometry.text.right-6)<1, "copy button must directly follow address");
      assert(geometry.button.right<=geometry.group.right+1, "copy button outside address group");
      assert(geometry.text.left>=geometry.group.left-1, "address outside group");
      await locator.getByRole("button").click();
      assert.equal(await page.evaluate(() => window.copiedShareTexts.at(-1)),expected);
    };
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (/Content Security Policy|Refused to/.test(m.text())) errors.push(m.text()); });
    await page.route("**/*", async (route) => {
      if (route.request().resourceType() !== "document") return route.continue();
      const response = await route.fetch();
      await route.fulfill({response, headers:{...response.headers(), "content-security-policy":csp}});
    });
    await page.route("**/api/**", async (route) => {
      const req = route.request(), url = new URL(req.url()), p = url.pathname;
      let result;
      if (p === "/api/konsol/moduller") result = { items: ["wireguard", "torrent"].map((id) => ({ id, installed: false, state: "yok", runtime: id === "wireguard" ? "konsol" : "host", live: "-" })) };
      else if (p === "/api/archives") result = {items:[], limits:{bytes:2147483648,entries:10000,layers:5,seconds:900}};
      else if (p === "/api/konsol/kaynaklar") result = { host: "nrm", version: "v128", domain: "ayc", os: "Debian 13", kernel: "test", uptime: 300, cores: 2, cpu: [1], mem: { total: 10000, used: 200, graph: [20] }, net: { wan: "192.0.2.1", tailscale: "100.64.0.2" }, root: "/srv", disk: { total: 100000, free: 80000 }, ports: [{ port: 22, proto: "tcp", scope: "internet", name: "SSH" }] };
      else if (p === "/api/wg/islemler") result = { items: [] };
      else if (p === "/api/state") result = { root: "/srv", downloads:"downloads", temp: "downloads/incomplete", disk: { total: 100000, free: 80000 }, trash: { count: 0, size: 0 } };
      else if (p === "/api/list") result = { path: url.searchParams.get("path") || "", entries: [
        ...(url.searchParams.get("path") ? ["movies", "series"] : ["media", "downloads", "Belgeler ve uzun klasör adı"]).map((name) => ({ name, type: "dir", count: 2, size: 1024, mtime: Date.now() / 1000 })),
        ...(!url.searchParams.get("path") && !url.searchParams.get("dirs") ? [longFile,"sample.part02.rar"].map(name=>({name,type:"file",size:840*1024**2,mtime:Date.now()/1000})) : [])] };
      else if (p === "/api/konsol/paylasim") result = shares;
      else if (p === "/api/konsol/paylasim/kaydet") {
        submitted = req.postDataJSON();
        shareWrites.push(submitted);
        if (holdShare) await new Promise(resolve => { releaseShare = resolve; });
        if (failShare) { failShare = false; return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Test: önceki paylaşım korundu."})}); }
        const id = submitted.id || "a".repeat(24);
        let s = shares.items.find((i) => i.id === id);
        if (!s) { s = { id, paused: false, available: true, expired: false, created: Date.now() / 1000, expires: null }; shares.items.push(s); }
        if (submitted.path !== undefined) Object.assign(s, { name: submitted.path.split("/").pop(), path: submitted.path });
        for (const key of ["username", "permission"]) if (submitted[key] !== undefined) s[key] = submitted[key];
        if (submitted.days != null) s.expires = submitted.days ? Math.floor(Date.now()/1000) + submitted.days * 86400 : null;
        s.url = shares.host + "/s/" + id + "/";
        result = shares;
      } else if (p.endsWith("/durum")) { const d = req.postDataJSON(); shares.items.find((s) => s.id === d.id).paused = d.paused; result = shares; }
      else if (p.endsWith("/kaldir")) { const d = req.postDataJSON(); shares.items = shares.items.filter((s) => s.id !== d.id); result = shares; }
      else if (p === "/api/trash") {
        if (req.method() === "POST") { deleted.push(req.postDataJSON()); result = {ok:true}; }
        else result = { items: trash };
      }
      else if (["/api/trash/restore", "/api/trash/purge", "/api/trash/empty"].includes(p)) {
        assert.equal(req.method(), "POST");
        const data = req.postDataJSON();
        trashWrites.push({path:p, data});
        trash = p.endsWith("/empty") ? [] : trash.filter(t => !data.ids.includes(t.id));
        result = {ok:true, purged:trashFixtures.length};
      }
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
    const sharePassword = page.getByLabel("Parola", { exact: true });
    assert.equal(await sharePassword.evaluate(input => input.minLength), 8);
    await sharePassword.fill("1234567");
    await page.getByRole("button", { name: "Paylaşımı oluştur", exact: true }).click();
    assert.equal(submitted, undefined, "Seven-character password must not reach the API");
    assert.equal(await sharePassword.evaluate(input => input.checkValidity()), false);
    await sharePassword.fill("Pass8!xy");
    await page.getByLabel("Erişim izni", { exact: true }).selectOption("rw");
    assert(await page.locator("#dav-ack").evaluate((input) => input.required));
    await page.locator("#dav-ack").check();
    await page.screenshot({ path: path.join(shots, "editor.png"), fullPage: true });
    await page.getByRole("button", { name: "Paylaşımı oluştur", exact: true }).click();
    await page.waitForFunction(() => !document.querySelector("#sh").open);
    assert.equal(submitted.permission, "rw");
    assert.equal(submitted.ack_write, true);
    assert.equal(submitted.password, "Pass8!xy");
    assert(!JSON.stringify(await page.evaluate(() => ({ ...localStorage }))).includes("Pass8!xy"));
    await page.getByRole("button", { name: "media ayrıntıları", exact: true }).click();
    await checkShareAddress(page.locator("#fs-detail .dav-address"));
    await page.locator("#fs-tabs").getByRole("button", { name: "Paylaşımlar", exact: true }).click();
    await checkShareAddress(page.locator(".dav-share-name .dav-address"));
    assert.equal(await page.locator('.dav-actions [aria-label="media adresi kopyala"]').count(),0);
    await page.getByRole("button", { name: "Yönet", exact: true }).click();
    assert.equal(await page.getByLabel("Yeni parola (isteğe bağlı)", { exact: true }).inputValue(), "");
    assert.equal(await page.locator("#sh select, #sh #dav-ack").count(), 0, "Manage only edits folder and account");
    await page.getByRole("button", { name: "Güncelle", exact: true }).click();
    await page.waitForFunction(() => !document.querySelector("#sh").open);
    assert.equal(submitted.password, "");
    assert.equal(submitted.days, undefined);
    assert.equal(submitted.permission, undefined);
    assert.equal(shares.items[0].permission, "rw");
    const permission = page.getByRole("combobox", {name:"media erişim izni",exact:true});
    const days = page.getByRole("combobox", {name:"media paylaşım süresi",exact:true});
    const ready = () => page.waitForFunction(() => document.querySelector('.dav-shares')?.getAttribute('aria-busy') === 'false');
    await permission.selectOption("ro"); await ready();
    assert.deepEqual(submitted, {id:"a".repeat(24),permission:"ro",ack_write:false});
    const beforeAck = shareWrites.length;
    await permission.selectOption("rw");
    assert.equal(await permission.inputValue(), "ro");
    await page.locator("#cf-cancel").click();
    assert.equal(shareWrites.length, beforeAck);
    await permission.selectOption("rw"); await page.keyboard.press("Escape");
    assert.equal(shareWrites.length, beforeAck);
    await permission.selectOption("rw"); await page.locator("#cf-go").click(); await ready();
    assert.deepEqual(submitted, {id:"a".repeat(24),permission:"rw",ack_write:true});
    for (const value of ["1", "7", "30", "0"]) {
      await days.selectOption(value); await ready();
      assert.deepEqual(submitted, {id:"a".repeat(24),days:Number(value)});
      assert.equal(await days.inputValue(), value === "0" ? "0" : "keep");
      assert.equal(shares.items[0].permission, "rw");
      assert.equal(shares.items[0].username, "family-media");
    }
    const noOp = shareWrites.length;
    await days.selectOption("0"); assert.equal(shareWrites.length,noOp);
    failShare = true;
    await permission.selectOption("ro"); await ready();
    assert.equal(await permission.inputValue(), "rw", "Failed write restores confirmed value");
    await page.getByText("Test: önceki paylaşım korundu.", {exact:true}).waitFor();
    holdShare = true;
    await days.selectOption("7");
    while (!releaseShare) await page.waitForTimeout(10);
    assert(await permission.isDisabled());
    assert(await days.isDisabled());
    assert(await page.getByRole("button", {name:"Yönet",exact:true}).isDisabled());
    holdShare = false; releaseShare(); await ready();
    await page.getByRole("switch", { name: "media paylaşımı duraklatılmamış" }).click();
    await page.getByText("Duraklatıldı", { exact: true }).waitFor();
    await days.selectOption("0"); await ready();
    assert.equal(shares.items[0].paused, true);
    for (const width of [2560, 1440, 1351, 1350, 1024, 736, 390, 320]) {
      await page.setViewportSize({ width, height: 950 });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await checkShareAddress(page.locator(".dav-share-name .dav-address"));
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `shares overflow ${width}`);
      const cells = await page.locator('.dav-share-row').evaluate(row => {
        const r = row.getBoundingClientRect();
        return [...row.children].map(cell => {const c=cell.getBoundingClientRect();return {left:c.left,right:c.right,scroll:cell.scrollWidth,client:cell.clientWidth,inside:c.left>=r.left && c.right<=r.right};});
      });
      assert(cells.every(c=>c.inside && c.scroll<=c.client+1), `share column overflow ${width}`);
      assert.equal(await page.locator('.dav-share-row select').count(),2);
      if (width>1350) {
        const headers = await page.locator('.dav-share-head').evaluate(row=>[...row.children].map(c=>c.getBoundingClientRect().left));
        cells.forEach((c,i)=>assert(Math.abs(c.left-headers[i])<1,`share column/header alignment ${width}`));
      }
      await page.screenshot({path:path.join(shots,`shares-${width}.png`),fullPage:true});
      await page.getByRole("button", { name: "Dosyalar", exact: true }).click();
      await page.getByRole("button", { name: "media ayrıntıları", exact: true }).click();
      await checkShareAddress(page.locator("#fs-detail .dav-address"));
      for (const mode of ["Kartlar", "Liste"]) {
        await page.getByRole("button", { name: mode, exact: true }).click();
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${mode} overflow ${width}`);
      }
      await page.locator("#fs-tabs").getByRole("button", { name: "Paylaşımlar", exact: true }).click();
    }
    await page.emulateMedia({ colorScheme: "dark" });
    await checkShareAddress(page.locator(".dav-share-name .dav-address"));
    await page.screenshot({ path: path.join(shots, "mobile-shares-dark.png"), fullPage: true });
    await page.getByRole("button", { name: "Dosyalar", exact: true }).click();
    await page.getByRole("button", { name: "Kartlar", exact: true }).click();
    await page.screenshot({ path: path.join(shots, "mobile-cards-dark.png"), fullPage: true });
    // Move-to-trash is a short confirmation, with full names and no explanatory rows.
    for (const theme of ["light", "dark"]) {
      await page.emulateMedia({colorScheme:theme});
      for (const width of [1440,1024,736,390,320]) {
        await page.setViewportSize({width,height:950});
        await page.getByRole('button',{name:longFile+' ayrıntıları',exact:true}).click();
        await page.locator('#fs-detail').getByRole('button',{name:'Çöpe taşı',exact:true}).click();
        assert.equal(await page.locator('#cf-title').textContent(), 'Çöpe taşınsın mı?');
        assert.equal(await page.locator('#cf-sub').textContent(), longFile);
        assert.equal(await page.locator('#cf-sub').getAttribute('title'), longFile);
        assert(await page.locator('#cf-list').isHidden());
        assert(await page.locator('#cf-word-row').isHidden());
        assert.equal(await page.locator('#cf button:visible').count(),2);
        const fits = await page.locator('#cf').evaluate(d=>{
          const r=d.getBoundingClientRect();
          return r.height<240 && r.left>=0 && r.right<=innerWidth && d.scrollWidth<=d.clientWidth+1 &&
            [...d.querySelectorAll('#cf-title,.dlg-foot button')].every(e=>{const b=e.getBoundingClientRect();return b.left>=r.left && b.right<=r.right && b.bottom<=r.bottom;});
        });
        assert(fits, `trash confirmation overflow ${theme}/${width}`);
        await page.screenshot({path:path.join(shots,`confirm-${theme}-${width}.png`),fullPage:true});
        await page.locator('#cf-cancel').click();
      }
    }
    assert.deepEqual(deleted,[]);
    // Model B keeps six stable icon/label slots for every selection type.
    const dock = page.locator(".fs-dock"), dockActions = page.locator(".fs-dock-actions");
    const actionNames = ["İndir","Taşı","Arşiv oluştur","Arşiv açıcı","Paylaş","Çöpe at"];
    const checkActions = async disabled => {
      assert.deepEqual(await dockActions.locator("button span").allTextContents(),actionNames);
      assert.deepEqual(await dockActions.locator("button").evaluateAll(buttons=>buttons.map(b=>b.disabled)),disabled);
      assert.equal(await dock.locator(".sel-cnt").textContent(),"1 öge seçili");
    };
    await page.getByRole('checkbox',{name:longFile+' seç',exact:true}).click();
    await checkActions([false,false,false,true,true,false]);
    await dock.getByRole("button",{name:"Seçimi bırak",exact:true}).focus();
    await page.keyboard.press("Tab");
    assert.equal(await page.locator(":focus").textContent(),"İndir");
    assert(await page.locator(":focus").evaluate(b=>getComputedStyle(b).boxShadow!=="none"));
    await page.keyboard.press("Tab"); await page.keyboard.press("Enter");
    await page.locator("#sh .movelist .fname").first().waitFor();
    await page.locator("#sh").getByRole("button",{name:"Vazgeç",exact:true}).click();
    await dock.getByRole("button",{name:"Arşiv oluştur",exact:true}).click();
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/downloads");
    assert.equal(await page.locator("#sh h3").textContent(),"Arşiv oluştur");
    await page.locator("#sh").getByRole("button",{name:"Vazgeç",exact:true}).click();
    await page.keyboard.press("Escape");
    assert(await page.locator("#fs-dock").isHidden());
    await page.getByRole('checkbox',{name:'sample.part02.rar seç',exact:true}).click();
    await checkActions([false,false,false,false,true,false]);
    await dock.getByRole("button",{name:"Arşiv açıcı",exact:true}).click();
    assert.equal(await page.locator("#sh h3").textContent(),"Arşiv açıcı");
    assert.equal(await page.locator("#archive-name").inputValue(),"sample");
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/downloads");
    await page.locator("#sh").getByRole("button",{name:"Vazgeç",exact:true}).click();
    await dock.getByRole("button",{name:"Seçimi bırak",exact:true}).click();
    assert(await page.locator("#fs-dock").isHidden());
    await page.getByRole('checkbox',{name:'media seç',exact:true}).click();
    await checkActions([true,false,false,true,false,false]);
    await dock.getByRole("button",{name:"Paylaş",exact:true}).click();
    await page.getByLabel("Kullanıcı adı",{exact:true}).waitFor();
    await page.locator("#sh").getByRole("button",{name:"Vazgeç",exact:true}).click();
    await dock.getByRole("button",{name:"Seçimi bırak",exact:true}).click();
    await page.getByRole('checkbox',{name:longFile+' seç',exact:true}).click();
    await page.getByRole('checkbox',{name:'media seç',exact:true}).click();
    assert.deepEqual(await dockActions.locator("button").evaluateAll(buttons=>buttons.map(b=>b.disabled)),[false,false,false,true,true,false]);
    await dock.getByRole("button",{name:"İndir",exact:true}).click();
    assert.deepEqual(await page.evaluate(()=>window.requestedDownloads.map(url=>{
      const u=new URL(url); return {path:u.pathname,file:u.searchParams.get("path")};
    })),[{path:"/api/download",file:longFile}],"Download links exclude selected folders");
    for (const theme of ["light", "dark"]) {
      await page.emulateMedia({colorScheme:theme,reducedMotion:"reduce"});
      for (const width of [2560,1440,1024,761,760,600,390,320]) {
        await page.setViewportSize({width,height:800});
        assert(await page.getByRole("navigation",{name:"Konum",exact:true}).isVisible(), "Selection preserves the address bar");
        const geometry = await page.locator(".fs-dock").evaluate(d=>{
          const r=d.getBoundingClientRect();
          return {bottom:r.bottom,height:r.height,inside:r.left>=0 && r.right<=innerWidth,scroll:document.documentElement.scrollWidth,
            controls:[...d.querySelectorAll('button')].every(b=>{const x=b.getBoundingClientRect(); return x.left>=r.left && x.right<=r.right && x.top>=r.top && x.bottom<=r.bottom;})};
        });
        assert(geometry.inside && geometry.controls && geometry.scroll<=width+1 && geometry.height<=220 && geometry.bottom<=800,`dock overflow ${theme}/${width}: ${JSON.stringify(geometry)}`);
        const icons = await dockActions.locator("button").evaluateAll(buttons=>buttons.map(b=>{
          const r=b.getBoundingClientRect(), icon=b.querySelector("svg").getBoundingClientRect(), label=b.querySelector("span").getBoundingClientRect();
          return {width:r.width,top:r.top,above:icon.bottom<label.top,inside:label.left>=r.left && label.right<=r.right && label.bottom<=r.bottom};
        }));
        assert(icons.every(b=>Math.abs(b.width-icons[0].width)<1 && b.above && b.inside),`equal icon/label cells ${theme}/${width}`);
        assert.equal(new Set(icons.map(b=>b.top)).size,width<=600?2:1,"Desktop row / mobile 3×2 grid");
        assert(await dock.locator(".fs-dock-selection").evaluate(header=>header.querySelector("span").getBoundingClientRect().right<header.querySelector("button").getBoundingClientRect().left));
        assert.equal(await dock.locator(".fs-dock-danger").evaluate(b=>getComputedStyle(b).backgroundColor),"rgba(0, 0, 0, 0)","Trash has no filled danger rectangle");
        if (await page.locator("#toast").isVisible()) {
          assert(await page.evaluate(()=>document.querySelector('#toast').getBoundingClientRect().bottom < document.querySelector('.fs-dock').getBoundingClientRect().top),"Notifications must not cover dock actions");
        }
        await page.screenshot({path:path.join(shots,`dock-${theme}-${width}.png`),fullPage:true});
      }
    }
    await page.getByRole("searchbox",{name:"Bu klasörde ara"}).fill("no-match");
    assert(await page.locator("#fs-dock").isHidden());
    await page.getByRole("searchbox",{name:"Bu klasörde ara"}).fill("");
    assert(await page.locator("#fs-dock").isVisible());
    await page.locator("#fs-tabs").getByRole("button",{name:"Paylaşımlar",exact:true}).click();
    assert.equal(await page.locator("#fs-dock").count(),0);
    await page.locator("#fs-tabs").getByRole("button",{name:"Dosyalar",exact:true}).click();
    await page.getByRole('button',{name:'Çöpe at',exact:true}).click();
    assert.equal(await page.locator('#cf-title').textContent(),'2 öge çöpe taşınsın mı?');
    await page.keyboard.press('Escape'); assert.deepEqual(deleted,[]);
    await page.getByRole('button',{name:'Çöpe at',exact:true}).click();
    await page.locator('#cf-go').click();
    await page.waitForFunction(()=>!document.querySelector('#cf').open && document.querySelector('#fs-dock').hidden);
    assert.equal(deleted.length,1);
    assert.equal(deleted[0].path,'');
    assert.deepEqual(deleted[0].names.slice().sort(), ['media',longFile].sort());
    await page.getByRole('button',{name:'media ayrıntıları',exact:true}).click();
    await page.getByRole("button", { name: "Klasörü aç", exact: true }).click();
    await page.getByRole("button", { name: "movies ayrıntıları", exact: true }).waitFor();
    await page.getByRole("searchbox", { name: "Bu klasörde ara" }).fill("series");
    assert.equal(await page.getByRole("button", { name: "movies ayrıntıları", exact: true }).count(), 0);
    assert.equal(await page.getByRole("button", { name: "series ayrıntıları", exact: true }).count(), 1);
    const trashTab = page.locator("#fs-tabs").getByRole("button", {name:"Çöp",exact:true});
    await trashTab.click();
    await page.getByText("Çöp boş", {exact:true}).waitFor();
    trash = [...trashFixtures];
    await page.getByRole("button", {name:"Dosyalar",exact:true}).click();
    await trashTab.click();
    await page.locator(".trash-t > .tr:not(.head)").nth(3).waitFor();
    for (const theme of ["light", "dark"]) {
      await page.emulateMedia({colorScheme:theme});
      for (const width of [1440, 1101, 1100, 1024, 736, 390, 320]) {
        await page.setViewportSize({width,height:1000});
        await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
        const geometry = await page.locator(".trash-t").evaluate(table => {
          const rect = el => {const r=el.getBoundingClientRect();return {x:r.x,y:r.y,right:r.right,bottom:r.bottom,w:r.width,h:r.height};};
          return {table:rect(table), head:[...table.querySelector(".head").children].map(rect), rows:[...table.querySelectorAll(".tr:not(.head)")].map(row => ({
            cells:[...row.children].map(rect), text:rect(row.querySelector(".fname > span:last-child")),
            parts:[...row.querySelectorAll(".fname strong,.fname small")].map(el=>({scroll:el.scrollWidth,client:el.clientWidth})),
            buttons:[...row.querySelectorAll("button")].map(rect),
          }))};
        });
        for (const row of geometry.rows) {
          const [name,size,date,actions]=row.cells;
          assert(name.w>180, `trash name squeezed: ${theme}/${width}: ${name.w}`);
          assert(row.text.w>130, `trash text squeezed ${width}`);
          assert(row.parts.every(p=>p.scroll<=p.client+1), `trash text clipped ${width}`);
          assert(row.cells.every(c=>c.x>=geometry.table.x && c.right<=geometry.table.right), `trash cell escaped ${width}`);
          assert(row.buttons.every(b=>b.x>=actions.x && b.right<=actions.right+1 && b.h>=30), `trash actions escaped ${width}`);
          if (width>1100) {
            row.cells.forEach((c,i)=>assert(Math.abs(c.x-geometry.head[i].x)<1, `trash header alignment ${width}`));
            assert(name.right<=size.x && size.right<=date.x && date.right<=actions.x, `trash cell overlap ${width}`);
          } else {
            assert(size.y>=name.bottom && date.y>=name.bottom, `trash metadata overlaps name ${width}`);
            assert(actions.y>=Math.max(size.bottom,date.bottom), `trash actions overlap metadata ${width}`);
            assert.equal(name.x,actions.x);
          }
        }
        assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1), `trash page overflow ${theme}/${width}`);
        await page.screenshot({path:path.join(shots,`trash-${theme}-${width}.png`),fullPage:true});
      }
    }
    assert.deepEqual(trashWrites, []);
    // All mutations are fixtures: never restore/purge real operator trash in UI tests.
    await page.getByRole("button",{name:"Geri yükle",exact:true}).first().click();
    await page.waitForFunction(()=>document.querySelectorAll(".trash-t > .tr:not(.head)").length===3);
    assert.deepEqual(trashWrites.at(-1),{path:"/api/trash/restore",data:{ids:["trash-short"]}});
    await page.getByRole("button",{name:"Kalıcı sil",exact:true}).last().click();
    await page.locator("#cf").getByRole("button",{name:"Vazgeç",exact:true}).click();
    assert.equal(trashWrites.length,1);
    await page.getByRole("button",{name:"Kalıcı sil",exact:true}).last().click();
    await page.locator("#cf-go").click();
    await page.waitForFunction(()=>document.querySelectorAll(".trash-t > .tr:not(.head)").length===2);
    assert.deepEqual(trashWrites.at(-1),{path:"/api/trash/purge",data:{ids:["trash-folder"]}});
    await page.getByRole("button",{name:/Çöpü boşalt/}).click();
    assert(await page.locator("#cf-go").isDisabled());
    await page.locator("#cf-word").fill("onayla");
    await page.locator("#cf-go").click();
    await page.getByText("Çöp boş",{exact:true}).waitFor();
    assert.deepEqual(trashWrites.at(-1),{path:"/api/trash/empty",data:{confirm:"onayla"}});
    assert.deepEqual(errors, []);
    console.log("PASS: Model B dock fixed slots/eligibility/icon-label alignment/keyboard/action routing/download links/mobile grid; inline share access/expiry, RW acknowledgement/cancel, partial payloads, failed/busy saves, account-only editor, aligned responsive columns/copy; compact trash confirmation/full long names/cancel/Escape/multi-select, permanent trash guards retained, layouts/light+dark/CSP. Screenshots: " + shots);
  } finally { await browser.close(); }
})().catch((e) => { console.error(e); process.exit(1); });
