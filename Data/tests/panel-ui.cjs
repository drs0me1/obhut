/* Model A production assets, deterministic APIs, and the actual production CSP. */
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const shots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-v131-panel-"));
const base = process.env.KONSOL_URL || "http://127.0.0.1:8766";
const csp = fs.readFileSync(path.join(__dirname,"../templates/Caddyfile"),"utf8").match(/Content-Security-Policy "([^"]+)"/)[1];
const config = {firewall:[],dns:{disabled:[],records:[],forward:false,servers:[]}};
const settings = {read_at:Date.now()/1000,domain:"ayc",tailscale:"100.64.0.2",ts_if:"tailscale0",wan:{iface:"eth0",ipv4:"192.0.2.1"},
  firewall:{ok:true,ports:[],listeners:[],rules:{errors:[],rows:[]}}, web:{entries:[],raw:[]}, dns:{listen:["lo","tailscale0"]},
  torrent:{installed:true,profile:"/var/lib/qbittorrent"},
  manage:{revision:"r1",config,pending:null,username:"admin",save:"/srv/downloads/",names:[]}};
const modules = ["wireguard","torrent"].map(id => ({id,installed:false,state:"yok",runtime:id === "wireguard" ? "konsol" : "host",live:"-"}));
const calls = [], errors = [], jobs = [];
const longArchiveFolder = "archive." + "a".repeat(150);
let resources = "normal", submitted, resourceCount = 0, holdInstall = false, logStatus = 200, pickerFailure = false, archiveFailure = false;
const entry = (name,type="dir") => ({name,type,count:3,size:2048,mtime:Date.now()/1000});
(async () => {
  const browser = await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHROMIUM ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM} : {})});
  try {
    const context = await browser.newContext({viewport:{width:1440,height:1000}});
    await context.route("**/*", async route => {
      if (route.request().resourceType() !== "document") return route.continue();
      const response = await route.fetch();
      await route.fulfill({response,headers:{...response.headers(),"content-security-policy":csp}});
    });
    const page = await context.newPage();
    page.on("pageerror", e => errors.push(e.message));
    page.on("console", msg => { if (/violates.*Content Security Policy|Refused to/.test(msg.text())) errors.push(msg.text()); });
    await page.route("**/api/**", async route => {
      const req = route.request(), url = new URL(req.url()), p = url.pathname;
      calls.push(p);
      let result;
      if (p === "/api/konsol/moduller") result = {items:modules};
      else if (/\/moduller\/torrent\/(kur|durdur|baslat|kaldir)$/.test(p)) {
        const action = p.split("/").pop(), m = modules[1];
        submitted = req.postDataJSON();
        if (action === "kur" && holdInstall) {
          m.busy = true; m.progress = {action,step:"1",total:4,text:"Paket kuruluyor"};
          return route.fulfill({status:200,contentType:"application/json",body:'{"ok":true}'});
        }
        m.busy = false;
        m.installed = action !== "kaldir"; m.state = action === "kaldir" ? "yok" : action === "durdur" ? "durduruldu" : "calisiyor";
        m.live = m.state === "calisiyor" ? "running" : "inactive";
        m.progress = {action,step:"bitti"}; result = {ok:true};
      } else if (p.endsWith("/torrent/gunluk")) return route.fulfill({status:logStatus,contentType:"text/plain",body:"<img src=x onerror=alert(1)>\nfixture service log"});
      else if (p.endsWith("/torrent/hesap")) result = {user:"admin",temp:false};
      else if (p === "/api/konsol/kaynaklar") {
        resourceCount++;
        if (resources === "offline") return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"fixture offline"})});
        const now = Date.now()/1000;
        result = {host:"nrm",version:"2026.08.06-v2-131",domain:"ayc",os:"Debian 13",kernel:"test",uptime:900,cores:2,
          read_at:now,sampled_at:resources === "stale" ? now-90 : now,cpu:[18],mem:{total:4*1024**3,used:1024**3},
          disk:{total:100*1024**3,free:72*1024**3},root:"/srv",net:{tailscale:"100.64.0.2",wan:"192.0.2.1"}};
      } else if (p === "/api/state") result = {root:"/srv",downloads:"downloads",temp:"downloads/incomplete",trash:{count:0,size:0},disk:{total:100*1024**3,free:72*1024**3}};
      else if (p === "/api/list") {
        if (pickerFailure && url.searchParams.get("dirs") === "1") return route.fulfill({status:403,contentType:"application/json",body:JSON.stringify({error:"Klasör okunamadı"})});
        result = {path:url.searchParams.get("path") || "",entries:[entry("media"),entry("downloads"),entry("Belgeler"),entry(longArchiveFolder),...["sample.zip","sample.rar","sample.r00","sample.part01.rar","not-an-archive.txt"].map(name=>entry(name,"file"))]};
      }
      else if (p === "/api/konsol/paylasim") result = {enabled:true,running:true,max:32,host:"http://100.64.0.2:61010",items:[]};
      else if (p === "/api/trash" || p === "/api/wg/islemler") result = {items:[]};
      else if (p === "/api/konsol/ayarlar") result = settings;
      else if (p === "/api/wg/state") result = {now:Date.now()/1000,installed:true,networks:[],reserved:[]};
      else if (p === "/api/archives") {
        if (req.method() === "POST") {
          submitted = req.postDataJSON();
          if (archiveFailure) { archiveFailure = false; return route.fulfill({status:409,contentType:"application/json",body:JSON.stringify({error:"Hedef klasör değişti"})}); }
          const job = {...submitted,id:String(jobs.length+1),status:"running",entries:0,bytes:0,message:"İşleniyor",result:null};
          jobs.unshift(job); result = {job};
        } else result = {items:jobs,limits:{bytes:2147483648,entries:10000,layers:5,seconds:900}};
      } else if (p === "/api/archives/cancel") {
        jobs.find(j => j.id === req.postDataJSON().id).status = "cancelled"; result = {ok:true};
      } else {
        errors.push("Unexpected endpoint: " + p);
        return route.fulfill({status:404,body:"unexpected fixture request"});
      }
      await route.fulfill({status:200,contentType:"application/json",body:JSON.stringify(result)});
    });
    const navigate = async hash => { await page.evaluate(h => { location.hash = h; }, hash); await page.waitForTimeout(50); };
    const refreshResources = async () => {
      const before = resourceCount;
      await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
      await page.waitForFunction(() => true);
      for (let n=0; n<100 && resourceCount === before; n++) await page.waitForTimeout(20);
      assert(resourceCount > before);
    };
    await page.goto(base + "/");
    await page.getByRole("button", {name:"media ayrıntıları",exact:true}).waitFor();
    await page.waitForFunction(() => document.querySelector("#resource-cpu").textContent === "%18");
    assert.equal(await page.locator("#title").innerText(),"Dosyalar");
    assert.deepEqual(await page.locator(".nav a:visible").allTextContents(),["Dosyalar","App Store","Ayarlar"]);
    assert.equal(await page.locator('[data-view="genel"],[data-view="uygulamalar"],.desktop-dock,#window-min').count(),0);
    assert.equal(await page.locator("#fs-detail:visible").count(),0);
    assert.equal(await page.locator("#resource-mem").innerText(),"%25");
    assert.equal(await page.locator("#resource-disk").innerText(),"%28");
    assert(!calls.includes("/api/wg/state") && !calls.includes("/api/wg/islemler") && !calls.includes("/api/wg/sistem"));
    await page.screenshot({path:path.join(shots,"model-a-files.png"),fullPage:true});
    for (const old of ["#/uygulamalar","#/genel"]) {
      await navigate(old); await page.waitForURL("**/#/dosyalar");
    }
    await navigate("#/gunluk"); await page.waitForURL("**/#/ayarlar/log");
    await page.locator("#log-table").waitFor();
    assert.equal(await page.getByRole("tab").count(),5);
    await page.getByRole("tab",{name:"Sistem",exact:true}).click();
    await page.getByRole("tab",{name:"Sistem",exact:true}).press("ArrowRight");
    await page.waitForURL("**/#/ayarlar/fw");
    await page.waitForFunction(() => document.activeElement.textContent === "Güvenlik Duvarı");
    assert.equal(await page.evaluate(() => document.activeElement.textContent),"Güvenlik Duvarı");
    await page.locator(".skip-link").focus();
    await page.locator(".skip-link").press("Enter");
    assert.equal(await page.evaluate(() => document.activeElement.id),"main-content");
    assert(page.url().endsWith("#/ayarlar/fw"));
    await navigate("#/wireguard"); await page.waitForURL("**/#/moduller");
    assert.equal(await page.locator("#mod-grid > article").count(),2);
    const card = page.locator("#modc-torrent");
    const detail = page.locator("#mod-detail");
    const toggle = card.getByRole("button",{name:"Ayrıntı",exact:true});
    assert.equal(await page.locator("#mod-sum").innerText(),"0 kurulu · 2 kurulabilir");
    assert.equal(await page.locator("#eyebrow").isVisible(),false);
    assert.equal(await detail.isVisible(),false);
    assert((await card.boundingBox()).height <= 80, "Collapsed desktop rows stay compact");
    await page.screenshot({path:path.join(shots,"store-list.png"),fullPage:true});
    await toggle.focus(); await toggle.press("Enter");
    assert.equal(await toggle.getAttribute("aria-expanded"),"true");
    await detail.getByRole("heading",{name:"qBittorrent",exact:true}).waitFor();
    assert.equal(await detail.getByRole("button",{name:"Kaldır",exact:true}).count(),0);
    await refreshResources();
    assert.equal(await page.evaluate(() => document.activeElement.id),"mod-details-torrent");
    assert.equal(await detail.isVisible(),true);
    await page.locator("#mod-details-wireguard").click();
    await detail.getByRole("heading",{name:"WireGuard",exact:true}).waitFor();
    assert.equal(await toggle.getAttribute("aria-expanded"),"false");
    await detail.getByRole("button",{name:"Kapat",exact:true}).click();
    assert.equal(await detail.isVisible(),false);
    assert.equal(await page.evaluate(() => document.activeElement.id),"mod-details-wireguard");
    holdInstall = true;
    await card.getByRole("button",{name:"Kur",exact:true}).click();
    await card.getByText("Paket kuruluyor",{exact:true}).waitFor();
    assert.equal(await card.getByRole("button",{name:"Kur",exact:true}).isDisabled(),true);
    await toggle.click();
    await detail.getByText("Paket kuruluyor",{exact:true}).waitFor();
    await toggle.focus();
    modules[1].progress = {action:"kur",step:"2",total:4,text:"Servis birimi"};
    await refreshResources();
    await card.getByText("Servis birimi",{exact:true}).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.id),"mod-details-torrent");
    await toggle.click();
    modules[1].busy = false; modules[1].progress = {action:"kur",step:"hata",text:"Fixture package failure"};
    await refreshResources();
    await card.getByRole("alert").waitFor();
    assert.match(await card.getByRole("alert").innerText(),/Fixture package failure/);
    assert.equal(await detail.isVisible(),false);
    holdInstall = false;
    await card.getByRole("button",{name:"Kur",exact:true}).click();
    await page.locator('.nav [data-route="torrent"]').waitFor();
    await toggle.click();
    await detail.getByRole("button",{name:"Durdur",exact:true}).click();
    await page.locator("#cf-go").click();
    await detail.getByRole("button",{name:"Başlat",exact:true}).click();
    await detail.getByRole("button",{name:"Durdur",exact:true}).waitFor();
    logStatus = 503;
    await detail.getByRole("button",{name:"Günlük",exact:true}).click();
    await page.getByRole("status").filter({hasText:"Günlük okunamadı (HTTP 503)."}).waitFor();
    assert.equal(await page.locator("#mod-log-output").isVisible(),false);
    logStatus = 200;
    await detail.getByRole("button",{name:"Günlük",exact:true}).click();
    await detail.locator("pre").waitFor();
    assert.match(await detail.locator("pre").innerText(),/<img src=x onerror=alert\(1\)>/);
    assert.equal(await detail.locator("img").count(),0);
    assert(!calls.some(p => p.endsWith("/hesap")), "Store never auto-reads account data");
    await page.screenshot({path:path.join(shots,"store-details.png"),fullPage:true});
    await card.getByRole("button",{name:"Aç",exact:true}).click();
    await page.getByRole("textbox",{name:"Kullanıcı adı",exact:true}).waitFor();
    assert.equal(await page.getByRole("tab").count(),0);
    await page.locator("#torrent-status").getByRole("button",{name:"Durdur",exact:true}).click();
    await page.locator("#cf-go").click();
    await page.locator("#torrent-status").getByRole("button",{name:"Başlat",exact:true}).click();
    await page.locator("#torrent-status").getByRole("button",{name:"Durdur",exact:true}).waitFor();
    await navigate("#/moduller");
    await detail.getByRole("button",{name:"Kaldır",exact:true}).click();
    assert.equal(await page.locator("#mod-veri").isChecked(),false);
    await page.locator("#cf-cancel").click();
    assert.equal(modules[1].installed,true);
    await detail.getByRole("button",{name:"Kaldır",exact:true}).click();
    await page.locator("#cf-go").click();
    await card.getByRole("button",{name:"Kur",exact:true}).waitFor();
    assert.equal(submitted.veri,false);
    assert.equal(await page.locator('.nav [data-route="torrent"]:visible').count(),0);
    assert.equal(await page.locator("#mod-log-output").isVisible(),false);
    await navigate("#/dosyalar");
    await page.getByRole("button",{name:"media ayrıntıları",exact:true}).click();
    await page.locator("#fs-detail").getByRole("button",{name:"Arşiv oluştur",exact:true}).click();
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/downloads");
    await page.locator("#archive-name").fill("media-backup");
    pickerFailure = true;
    await page.getByRole("button",{name:"Hedef klasör seç",exact:true}).click();
    await page.getByText("Klasör okunamadı",{exact:true}).waitFor();
    assert(await page.getByRole("button",{name:"Bu klasörü seç",exact:true}).isDisabled());
    assert(await page.locator("#sh").getByRole("button",{name:"Oluştur",exact:true}).isDisabled());
    pickerFailure = false;
    await page.getByRole("button",{name:"Yeniden dene",exact:true}).click();
    await page.locator("#archive-picker").getByRole("button",{name:"Sunucu",exact:true}).click();
    await page.locator("#archive-picker").getByRole("button",{name:"Belgeler",exact:true}).click();
    await page.getByRole("button",{name:"Bu klasörü seç",exact:true}).click();
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/Belgeler");
    await page.getByRole("button",{name:"Hedef klasör seç",exact:true}).click();
    await page.locator("#archive-picker").getByRole("button",{name:"Sunucu",exact:true}).click();
    await page.locator("#archive-picker").getByRole("button",{name:"Geri",exact:true}).click();
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/Belgeler", "Cancel retains the selected destination");
    archiveFailure = true;
    await page.locator("#sh").getByRole("button",{name:"Oluştur",exact:true}).click();
    await page.getByText("Hedef klasör değişti",{exact:true}).waitFor();
    assert.equal(await page.locator("#archive-name").inputValue(),"media-backup");
    await page.locator("#sh").getByRole("button",{name:"Oluştur",exact:true}).click();
    await page.waitForURL("**/#/dosyalar/arsiv");
    assert.equal(submitted.operation,"zip");
    assert.equal(submitted.name,"media-backup.zip");
    assert.equal(submitted.target,"Belgeler");
    assert.deepEqual(submitted.names,["media"]);
    await page.getByRole("button",{name:"İptal et",exact:true}).click();
    await page.getByText("media-backup.zip · İptal edildi",{exact:true}).waitFor();
    await page.locator("#fs-tabs").getByRole("button",{name:"Dosyalar",exact:true}).click();
    await page.getByRole("button",{name:"sample.zip ayrıntıları",exact:true}).click();
    await page.locator("#fs-detail").getByRole("button",{name:"Arşiv açıcı",exact:true}).click();
    assert.equal(await page.locator("#archive-nested,#archive-layers,.archive-form .archive-limits").count(),0);
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/downloads");
    await page.locator("#sh").getByRole("button",{name:"Arşivi aç",exact:true}).click();
    await page.waitForURL("**/#/dosyalar/arsiv");
    assert.equal(submitted.operation,"unzip"); assert.equal(submitted.nested,undefined); assert.equal(submitted.layers,undefined);
    assert.equal(submitted.target,"downloads");
    jobs[0].status = "done"; jobs[0].result = "sample";
    await page.getByRole("button",{name:"Sonucu göster",exact:true}).click();
    await page.waitForURL("**/#/dosyalar");
    await page.getByRole("button",{name:"media ayrıntıları",exact:true}).waitFor();
    for (const filename of ["sample.rar","sample.r00","sample.part01.rar"]) {
      await page.getByRole("button",{name:filename+" ayrıntıları",exact:true}).click();
      await page.locator("#fs-detail").getByRole("button",{name:"Arşiv açıcı",exact:true}).click();
      assert.equal(await page.locator("#archive-name").inputValue(),"sample");
      assert(!/ZIP|RAR|katman|işlenen veri|10.000/.test(await page.locator("#sh").innerText()));
      await page.locator("#sh").getByRole("button",{name:"Arşivi aç",exact:true}).click();
      await page.waitForURL("**/#/dosyalar/arsiv");
      assert.deepEqual(submitted.names,[filename]);
      assert.equal(submitted.nested,undefined);
      jobs[0].status="failed"; jobs[0].message="Eksik RAR parçası; sonuç yayımlanmadı.";
      await page.locator("#fs-tabs").getByRole("button",{name:"Dosyalar",exact:true}).click();
    }
    await page.getByRole("button",{name:"not-an-archive.txt ayrıntıları",exact:true}).click();
    assert.equal(await page.locator("#fs-detail").getByRole("button",{name:"Arşiv açıcı",exact:true}).count(),0);
    await page.getByRole("button",{name:longArchiveFolder+" ayrıntıları",exact:true}).click();
    await page.locator("#fs-detail").getByRole("button",{name:"Klasörü aç",exact:true}).click();
    await page.getByRole("button",{name:"sample.rar ayrıntıları",exact:true}).click();
    await page.locator("#fs-detail").getByRole("button",{name:"Arşiv açıcı",exact:true}).click();
    await page.getByRole("button",{name:"Hedef klasör seç",exact:true}).click();
    await page.locator("#archive-picker").getByRole("button",{name:longArchiveFolder,exact:true}).click();
    for (const width of [1440,736,390,320]) {
      await page.setViewportSize({width,height:1000});
      await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
      const layout=await page.evaluate(()=>({width:innerWidth,actual:document.documentElement.scrollWidth,items:[...document.querySelectorAll('body *')].filter(e=>e.scrollWidth>e.clientWidth+1&&e.getBoundingClientRect().width>0).map(e=>({tag:e.tagName,cls:String(e.className),client:e.clientWidth,scroll:e.scrollWidth,text:e.textContent.slice(0,80)})).slice(-20)}));
      assert(layout.actual<=width+1,`archive path at ${width}: ${JSON.stringify(layout)}`);
      assert(await page.locator('.archive-form').evaluate(e=>e.scrollWidth<=e.clientWidth+1),`archive form at ${width}`);
      await page.screenshot({path:path.join(shots,`archive-picker-${width}.png`),fullPage:true});
    }
    await page.locator('#sh').getByRole('button',{name:'Vazgeç',exact:true}).click();
    await page.setViewportSize({width:1440,height:1000});
    resources = "stale"; await refreshResources();
    await page.waitForFunction(() => document.querySelector("#resource-cpu").textContent === "—");
    assert.equal(await page.locator("#resource-mem").innerText(),"%25");
    resources = "offline"; await refreshResources();
    await page.waitForFunction(() => document.querySelector("#resource-mem").textContent === "—");
    assert.equal(await page.locator("#bar-disk:visible").count(),0);
    resources = "normal"; await refreshResources();
    await page.waitForFunction(() => document.querySelector("#resource-cpu").textContent === "%18");
    // A direct bookmark must populate the new-network form after its async first fetch.
    modules[0].installed = true; modules[0].state = "calisiyor";
    await page.goto(base + "/?deep-link-test=1#/wireguard/ekle");
    await page.waitForFunction(() => document.querySelector("#na-port").value !== "");
    await page.locator("#na-label").fill("Keep my draft");
    await refreshResources();
    assert.equal(await page.locator("#na-label").inputValue(),"Keep my draft");
    for (const width of [1440,1024,736,390,320]) {
      await page.setViewportSize({width,height:950});
      for (const hash of ["#/dosyalar","#/dosyalar/paylasim","#/dosyalar/arsiv","#/dosyalar/cop","#/moduller","#/ayarlar"]) {
        await navigate(hash);
        await page.waitForTimeout(80);
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1),`${width}/${hash}`);
        if (hash === "#/moduller") {
          assert(await card.locator(".store-state").isVisible(), "Status stays visible on mobile");
          await page.locator("#mod-details-wireguard").click();
          await detail.getByRole("heading",{name:"WireGuard",exact:true}).waitFor();
          assert.equal(await detail.getByRole("button",{name:"Durdur",exact:true}).count(),0);
          assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1),`${width}/store details`);
          await detail.getByRole("button",{name:"Kapat",exact:true}).click();
        }
      }
      if (width < 761) {
        await page.locator("#menu-toggle").click();
        assert(await page.locator("#resource-cpu").isVisible());
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth+1));
        await page.keyboard.press("Escape");
        assert.equal(await page.locator("#menu-toggle").getAttribute("aria-expanded"),"false");
      }
    }
    await page.emulateMedia({colorScheme:"dark",reducedMotion:"reduce"});
    await navigate("#/moduller");
    await toggle.click();
    await page.screenshot({path:path.join(shots,"store-mobile-dark.png"),fullPage:true});
    await navigate("#/dosyalar");
    await page.locator("#menu-toggle").click();
    await page.screenshot({path:path.join(shots,"model-a-mobile-dark.png"),fullPage:true});
    assert.deepEqual(errors,[]);
    console.log("PASS: Model A routes/navigation, compact Store rows/details/progress/failure/focus/logs/no credentials/lifecycle, shared settings, keyboard/5 widths/dark, resources/stale/offline/recovery, archive create/cancel/unzip/results, WG deep link, production CSP. Screenshots: " + shots);
  } finally { await browser.close(); }
})().catch(err => {console.error(err); process.exit(1);});
