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
  manage:{revision:"r1",config,pending:null,names:[]}};
// DD-200: App Store texts, the page declaration and the page files come from each package folder.
const magaza = path.join(__dirname,"../magaza");
const meta = id => JSON.parse(fs.readFileSync(path.join(magaza,id,"konsol.json"),"utf8").replace(/__[A-Z_]+__/g,"x"));
const modules = ["wireguard","torrent"].map(id => ({id,installed:false,state:"yok",runtime:id === "wireguard" ? "konsol" : "konteyner",live:"-",
  durdurulabilir:id === "torrent",konsol:meta(id)}));
// DD-195 (v2-168): the backend names both qBittorrent addresses; the public one only while published.
modules[1].urls = {tailscale:"http://torrent.ayc",internet:null};
const calls = [], errors = [], jobs = [];
const temporaryPassword = "FixtureTemp8!";
let passwordReads = 0, temporaryLogin = true;
const longArchiveFolder = "archive." + "a".repeat(150);
let resources = "normal", submitted, resourceCount = 0, holdInstall = false, logStatus = 200, pickerFailure = false, archiveFailure = false;
// DD-206: network card (rates rise with each poll; package totals while installed) and the saved overview layout.
let netCount = 0, layoutSaved = null;
const layoutWrites = [];
const netApps = () => modules[1].installed ? [{id:"torrent",name:"qBittorrent",state:"calisiyor",down:5*1024**3,up:1024**3,since:null,at:Math.floor(Date.now()/1000)-600}] : [];
const entry = (name,type="dir") => ({name,type,count:3,size:2048,mtime:Date.now()/1000});
(async () => {
  const browser = await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHROMIUM ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM} : {})});
  try {
    const context = await browser.newContext({viewport:{width:1440,height:1000}});
    const packageFile = route => {
      const p = new URL(route.request().url()).pathname, file = path.join(magaza,p.slice("/uygulama/".length));
      return route.fulfill({status:200,contentType:p.endsWith(".css") ? "text/css" : "application/javascript",body:fs.readFileSync(file,"utf8")});
    };
    await context.route("**/*", async route => {
      if (new URL(route.request().url()).pathname.startsWith("/uygulama/")) return packageFile(route);
      if (route.request().resourceType() !== "document") return route.continue();
      const response = await route.fetch();
      await route.fulfill({response,headers:{...response.headers(),"content-security-policy":csp}});
    });
    const page = await context.newPage();
    await page.clock.install();
    page.on("pageerror", e => errors.push(e.message));
    page.on("console", msg => { if (/violates.*Content Security Policy|Refused to/.test(msg.text())) errors.push(msg.text()); });
    const apiHandler = async route => {
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
        // DD-202: the page files are offered only while installed; the shell loads them from /uygulama/<id>/.
        m.sayfa = m.installed ? ["sayfa.js","sayfa.css"] : undefined;
        m.live = m.state === "calisiyor" ? "running" : "inactive";
        m.progress = {action,step:"bitti"}; result = {ok:true};
      } else if (p === "/api/uygulama/torrent/durum") result = {installed:true,running:modules[1].state === "calisiyor",unit:"qbittorrent.service",container:"qbittorrent",
        profile:"/var/lib/qbittorrent",downloads:"/srv/downloads",save:"/srv/downloads/",save_inside:true,temp:"",temp_on:false,temp_inside:false,ui:"127.0.0.1:61006",peer_port:0,username:"admin"};
      else if (p.endsWith("/torrent/gunluk")) return route.fulfill({status:logStatus,contentType:"text/plain",body:"<img src=x onerror=alert(1)>\nfixture service log"});
      else if (p.endsWith("/torrent/hesap")) {
        result = {user:"admin",temp:temporaryLogin};
        if (url.searchParams.get("parola") === "1") { passwordReads++; result.pass = temporaryPassword; }
      }
      else if (p === "/api/konsol/saglik") result = {status:"ok",read_at:1,checks:[{id:"units",name:"Servisler",status:"ok",detail:"Başarısız servis yok"}]};
      else if (p === "/api/konsol/oturum") result = {durum:"acik",kullanici:"fixture",oturum_gun:7};
      else if (p === "/api/konsol/ag") {
        netCount++;
        const now = Math.floor(Date.now()/1000), rx = netCount*1024*1024, tx = 256*1024;
        result = {read_at:now,iface:"eth0",window:120,sampled_at:now,rx,tx,points:[[now-4,512*1024,128*1024],[now-2,rx/2,tx],[now,rx,tx]],apps:netApps()};
      }
      else if (p === "/api/konsol/duzen") {
        if (req.method() === "POST") {
          const body = req.postDataJSON(); layoutWrites.push(body);
          layoutSaved = body.sifirla ? null : {schema:1,...body.duzen};
        }
        result = {duzen:layoutSaved};
      }
      else if (p === "/api/konsol/kaynaklar") {
        resourceCount++;
        if (resources === "offline") return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"fixture offline"})});
        const now = Date.now()/1000;
        result = {host:"nrm",version:"2026.08.06-v2-131",domain:"ayc",os:"Debian 13",kernel:"test",uptime:900,cores:2,
          read_at:now,sampled_at:resources === "stale" ? now-90 : now,cpu:[18],mem:{total:4*1024**3,used:1024**3},
          disk:{total:100*1024**3,free:72*1024**3},root:"/srv",net:{tailscale:"100.64.0.2",wan:"192.0.2.1"}};
      } else if (p === "/api/state") result = {root:"/srv",downloads:"downloads",protected:[{path:"downloads/incomplete",owner:"Deneme Uygulaması"}],trash:{count:0,size:0},disk:{total:100*1024**3,free:72*1024**3}};
      else if (p === "/api/list") {
        if (pickerFailure && url.searchParams.get("dirs") === "1") return route.fulfill({status:403,contentType:"application/json",body:JSON.stringify({error:"Klasör okunamadı"})});
        result = {path:url.searchParams.get("path") || "",entries:[entry("media"),entry("downloads"),entry("Belgeler"),entry(longArchiveFolder),...["sample.zip","sample.rar","sample.r00","sample.part01.rar","not-an-archive.txt"].map(name=>entry(name,"file"))]};
      }
      else if (p === "/api/konsol/paylasim") result = {enabled:true,running:true,max:32,host:"http://100.64.0.2:61010",items:[]};
      else if (p === "/api/trash" || p === "/api/konsol/islemler") result = {items:[]};
      else if (p === "/api/konsol/ayarlar") result = settings;
      else if (p === "/api/uygulama/wireguard/state") result = {now:Date.now()/1000,networks:[],reserved:[],max:10,defaults:{dns:"1.1.1.1",keepalive:21,mtu:1420,port:61001}};
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
    };
    await page.route("**/api/**", apiHandler);
    const navigate = async hash => { await page.evaluate(h => { location.hash = h; }, hash); await page.waitForTimeout(50); };
    const refreshResources = async () => {
      const before = resourceCount;
      await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
      await page.waitForFunction(() => true);
      for (let n=0; n<100 && resourceCount === before; n++) await page.waitForTimeout(20);
      assert(resourceCount > before);
    };
    await page.goto(base + "/");
    // DD-204: the landing page is Genel bakış — widgets from the shell's own APIs and tiles for
    // Konsol's sections and installed applications; nothing is computed in the page.
    await page.locator("#genel-tiles .tile").first().waitFor();
    await page.waitForFunction(() => document.querySelector("#resource-cpu").textContent === "%18");
    assert.equal(await page.locator("#title").innerText(),"Genel bakış");
    assert.deepEqual(await page.locator(".nav a:visible").allTextContents(),["Genel bakış","Dosyalar","App Store","Konteynerler","Ayarlar"]);
    assert.equal(await page.locator('[data-view="uygulamalar"],.desktop-dock,#window-min').count(),0);
    assert.deepEqual(await page.locator("#genel-tiles .tile strong").allTextContents(),["Dosyalar","Paylaşımlar","App Store","Ayarlar"],"no application tile while none is installed");
    assert.equal(await page.locator('#genel-tiles .tile[data-tile="moduller"] small').innerText(),"0 kurulu · 2 kurulabilir");
    await page.locator("#genel-health").filter({hasText:"Sağlıklı"}).waitFor();
    assert.deepEqual(await page.locator("#genel-widgets .widget").evaluateAll(els => els.map(e => [e.dataset.widget,e.dataset.span])),[["saat","2"],["durum","2"],["ag","4"]],"clock, status and network (DD-206)");
    assert.equal(await page.locator("#genel-widgets .rings .big").count(),3);
    assert.equal(await page.locator("#genel-widgets .rings .big b").first().innerText(),"%18","the overview ring shows the same measurement as the sidebar");
    assert.equal(await page.locator("#genel-widgets .rings .pie-box").innerText(),"%28 Depolama","storage is a pie beside the rings with the sidebar's disk figure");
    assert.equal(await page.locator("#genel-widgets .pie.warn").count(),0);
    // v2-182: the status card carries the three charts only — no check texts — and they fill the card.
    assert.equal(await page.locator("#genel-widgets .rings .hint-s, #genel-widgets .rings .line").count(),0,"no explanation lines in the status card");
    const ringBox = await page.locator("#genel-widgets .ring").first().boundingBox();
    assert(ringBox.width >= 80 && ringBox.height >= 80, `charts are large: ${ringBox.width}x${ringBox.height}`);
    const statusBox = await page.locator('#genel-widgets .widget[aria-label="Sistem durumu"]').boundingBox(), clockBox = await page.locator('#genel-widgets .widget[aria-label="Saat ve sunucu"]').boundingBox();
    assert(Math.abs(statusBox.height - clockBox.height) <= 60, `the two widgets stay about the same height: ${statusBox.height} vs ${clockBox.height}`);
    assert(!calls.includes("/api/uygulama/wireguard/state") && !calls.includes("/api/konsol/islemler"));
    assert.equal(await page.locator('script[src^="/uygulama/"]').count(),0,"no package page is loaded while none is installed");
    // DD-206: the clock card shows time, date, uptime and both addresses — no host, OS or kernel line.
    const clockCard = page.locator('#genel-widgets .widget[data-widget="saat"]');
    assert.deepEqual(await clockCard.locator(".clock-facts dt").allTextContents(),["Çalışma süresi","Tailscale","WAN"]);
    assert.deepEqual(await clockCard.locator(".clock-facts dd").allTextContents(),["15 dk","100.64.0.2","192.0.2.1"]);
    assert.doesNotMatch(await clockCard.innerText(),/Debian|·/,"no version details in the clock card");
    // DD-206: the network card shows the WAN rates, a chart and the packages' totals, read every 2 s.
    const netCard = page.locator('#genel-widgets .widget[data-widget="ag"]');
    await netCard.locator("#ag-rx").filter({hasText:"MB/s"}).waitFor();
    assert.equal(await netCard.locator("#ag-sub").innerText(),"eth0 · son 2 dk");
    assert.equal(await netCard.locator("#ag-live").innerText(),"Canlı");
    assert.equal(await netCard.locator("#ag-tx").innerText(),"256 KB/s");
    assert.equal(await netCard.locator(".net-svg path.down").count(),1,"the chart draws the download line");
    assert.equal(await netCard.locator(".net-svg path.up").count(),1,"and the upload line");
    assert.match(await netCard.locator("#ag-apps").innerText(),/Trafiğini bildiren kurulu uygulama yok/);
    const firstRate = await netCard.locator("#ag-rx").innerText(), polls = netCount;
    await page.clock.runFor(2100);
    await page.waitForFunction(prev => document.querySelector("#ag-rx").textContent !== prev, firstRate);
    assert(netCount > polls,"the network card polls every 2 s");
    await page.clock.setSystemTime(new Date());
    await page.screenshot({path:path.join(shots,"model-a-overview.png"),fullPage:true});
    // DD-206: Düzenle — bottom-left of the content; tiles move by arrows or dragging, widgets change
    // width (1–4 columns, height not adjustable) and visibility; Bitti saves on the server.
    const bar = page.locator("#genel-edit"), order = () => page.locator("#genel-tiles .tile").evaluateAll(els => els.map(e => e.dataset.tile));
    const barBox = await bar.boundingBox(), gridBox0 = await page.locator("#genel-widgets").boundingBox(), tilesBox = await page.locator("#genel-tiles").boundingBox();
    assert(Math.abs(barBox.x - gridBox0.x) < 2 && barBox.y >= tilesBox.y + tilesBox.height, `Düzenle sits bottom-left, below the tiles: ${JSON.stringify(barBox)}`);
    await bar.getByRole("button",{name:"Düzenle",exact:true}).click();
    await bar.getByRole("button",{name:"Bitti",exact:true}).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.id),"genel-bitti");
    assert.equal(await page.locator("#genel-tiles a.tile").count(),0,"tiles are not links while editing");
    assert.equal(await page.locator("#genel-tiles.editing .tile .tile-move").count(),4);
    // Tiles wiggle while editing; readers who ask for reduced motion get still tiles (and the clicks
    // below need still targets).
    const wiggle = () => page.locator("#genel-tiles .tile").first().evaluate(e => getComputedStyle(e).animationName);
    assert.equal(await wiggle(),"tile-wiggle");
    await page.emulateMedia({reducedMotion:"reduce"});
    assert.equal(await wiggle(),"none");
    assert.deepEqual(await order(),["dosyalar","paylasim","moduller","ayarlar"]);
    assert(await page.getByRole("button",{name:"Dosyalar: sola taşı",exact:true}).isDisabled());
    await page.getByRole("button",{name:"Ayarlar: sola taşı",exact:true}).click();
    assert.deepEqual(await order(),["dosyalar","paylasim","ayarlar","moduller"]);
    assert.equal(await page.evaluate(() => document.activeElement.getAttribute("aria-label")),"Ayarlar: sola taşı","focus stays on the moved tile's button");
    // Dragging uses pointer events, the same code for a mouse and a finger.
    const from = await page.locator('#genel-tiles .tile[data-tile="moduller"] .ico').boundingBox();
    const to = await page.locator('#genel-tiles .tile[data-tile="dosyalar"]').boundingBox();
    await page.mouse.move(from.x + from.width/2, from.y + from.height/2);
    await page.mouse.down();
    await page.mouse.move(to.x + 12, to.y + to.height/2, {steps:16});
    await page.mouse.up();
    assert.deepEqual(await order(),["moduller","dosyalar","paylasim","ayarlar"],"dragging App Store to the front");
    const clockW = page.locator('#genel-widgets .widget[data-widget="saat"]'), statusW = page.locator('#genel-widgets .widget[data-widget="durum"]');
    await page.getByRole("button",{name:"Saat: daralt",exact:true}).click();
    assert.equal(await clockW.getAttribute("data-span"),"1");
    assert(await page.getByRole("button",{name:"Saat: daralt",exact:true}).isDisabled(),"one column is the minimum");
    await page.getByRole("button",{name:"Sistem durumu: genişlet",exact:true}).click();
    assert.equal(await statusW.getAttribute("data-span"),"3");
    const gridBox = await page.locator("#genel-widgets").boundingBox(), clockWBox = await clockW.boundingBox(), statusWBox = await statusW.boundingBox();
    assert(Math.abs(clockWBox.width - (gridBox.width - 42)/4) < 3, `span 1 is one of four columns: ${clockWBox.width}/${gridBox.width}`);
    assert(Math.abs(statusWBox.width - (3*(gridBox.width - 42)/4 + 28)) < 3, `span 3 is three columns: ${statusWBox.width}/${gridBox.width}`);
    assert(Math.abs(clockWBox.height - statusWBox.height) < 2, "widgets in a row share one height");
    const ringSmall = await statusW.locator(".ring").first().boundingBox();
    assert(ringSmall.width >= 80, "the status charts keep their size in a wide card");
    await page.getByRole("button",{name:"Ağ: gizle",exact:true}).click();
    assert.equal(await page.locator('#genel-widgets .widget[data-widget="ag"].is-hidden').count(),1,"a hidden widget stays visible, dimmed, while editing");
    assert.equal(await page.getByRole("button",{name:"Ağ: göster",exact:true}).count(),1);
    await page.screenshot({path:path.join(shots,"model-a-overview-edit.png"),fullPage:true});
    await bar.getByRole("button",{name:"Bitti",exact:true}).click();
    await page.getByText("Düzen kaydedildi.",{exact:true}).first().waitFor();
    assert.deepEqual(layoutWrites.at(-1),{duzen:{kareler:["moduller","dosyalar","paylasim","ayarlar"],
      widgetlar:[{id:"saat",genislik:1,gizli:false},{id:"durum",genislik:3,gizli:false},{id:"ag",genislik:4,gizli:true}]}});
    assert.equal(await page.locator('#genel-widgets .widget[data-widget="ag"]').count(),0,"a hidden widget is not shown");
    assert.equal(await page.locator("#genel-tiles a.tile").count(),4,"tiles are links again");
    assert.equal(await page.evaluate(() => document.activeElement.id),"genel-duzenle");
    const hiddenPolls = netCount;
    await page.clock.runFor(4100);
    await page.clock.setSystemTime(new Date());
    assert.equal(netCount,hiddenPolls,"a hidden network card is not polled");
    // The layout lives on the server: another device's order shows up on the next visit.
    layoutSaved = {schema:1,kareler:["ayarlar","moduller","dosyalar","paylasim"],widgetlar:[{id:"saat",genislik:1,gizli:false},{id:"durum",genislik:3,gizli:false},{id:"ag",genislik:4,gizli:true}]};
    await navigate("#/dosyalar"); await navigate("#/genel");
    await page.waitForFunction(() => document.querySelector("#genel-tiles .tile")?.dataset.tile === "ayarlar");
    // Vazgeç (Escape) drops a draft; Varsayılan + Bitti removes the saved layout.
    const writes = layoutWrites.length;
    await bar.getByRole("button",{name:"Düzenle",exact:true}).click();
    await page.getByRole("button",{name:"Ayarlar: sağa taşı",exact:true}).click();
    await page.keyboard.press("Escape");
    await bar.getByRole("button",{name:"Düzenle",exact:true}).waitFor();
    assert.deepEqual(await order(),["ayarlar","moduller","dosyalar","paylasim"]);
    assert.equal(layoutWrites.length,writes,"cancel saves nothing");
    await bar.getByRole("button",{name:"Düzenle",exact:true}).click();
    await bar.getByRole("button",{name:"Varsayılan",exact:true}).click();
    assert.deepEqual(await order(),["dosyalar","paylasim","moduller","ayarlar"]);
    assert.equal(await page.locator('#genel-widgets .widget:not(.is-hidden)').count(),3);
    await bar.getByRole("button",{name:"Bitti",exact:true}).click();
    await page.getByText("Genel bakış varsayılan düzene döndü.",{exact:true}).first().waitFor();
    assert.deepEqual(layoutWrites.at(-1),{sifirla:true});
    // On a long (phone) page the bar sticks to the bottom-left of the screen; scrolled to the end it rests below the tiles.
    await page.setViewportSize({width:390,height:760});
    await page.evaluate(() => window.scrollTo(0,0));
    const phoneBar = await bar.boundingBox();
    assert(phoneBar.x <= 20 && Math.abs(phoneBar.y + phoneBar.height - (760 - 12)) < 3, `sticky bottom-left on a phone: ${JSON.stringify(phoneBar)}`);
    await page.evaluate(() => window.scrollTo(0,document.documentElement.scrollHeight));
    const phoneEnd = await bar.boundingBox(), phoneTiles = await page.locator("#genel-tiles").boundingBox();
    assert(phoneEnd.y >= phoneTiles.y + phoneTiles.height, "at the end of the page the bar does not cover the last row");
    await page.setViewportSize({width:1440,height:1000});
    await page.emulateMedia({reducedMotion:"no-preference"});
    await netCard.locator("#ag-rx").waitFor();
    await page.locator('#genel-tiles .tile[data-tile="dosyalar"]').click();
    await page.getByRole("button", {name:"media ayrıntıları",exact:true}).waitFor();
    assert.equal(await page.locator("#title").innerText(),"Dosyalar");
    assert.equal(await page.locator("#fs-detail:visible").count(),0);
    assert.equal(await page.locator("#resource-mem").innerText(),"%25");
    assert.equal(await page.locator("#resource-disk").innerText(),"%28");
    await page.screenshot({path:path.join(shots,"model-a-files.png"),fullPage:true});
    // Fresh installs only: retired bookmarks are not rewritten; an unknown hash shows the overview.
    await navigate("#/uygulamalar");
    await page.getByRole("heading",{name:"Genel bakış",exact:true}).waitFor();
    await navigate("#/ayarlar/log");
    await page.locator("#log-table").waitFor();
    // Sistem, Güvenlik Duvarı, Caddy, Dnsmasq, Günlük; containers have their own sidebar page.
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
    // DD-204: App Store entries are tiles (icon, name, state, two buttons); the collapsed tile stays compact.
    const tileBox = await card.boundingBox();
    assert(tileBox.height <= 240 && tileBox.width <= 260, `Collapsed tiles stay compact: ${JSON.stringify(tileBox)}`);
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
    // DD-210: qBittorrent's Kur opens its install form; the install starts with the submitted form.
    const installTorrent = async () => {
      await card.getByRole("button",{name:"Kur",exact:true}).click();
      const form = page.locator("#sh");
      await form.getByLabel("Parola",{exact:true}).fill("fixture-install-phrase");
      await form.getByLabel("Parola (tekrar)",{exact:true}).fill("fixture-install-phrase");
      await form.getByRole("button",{name:"Kur ve başlat",exact:true}).click();
      await form.waitFor({state:"hidden"});
      assert.deepEqual(submitted, {form:{username:"admin",password:"fixture-install-phrase",save:"x"}});
    };
    holdInstall = true;
    await installTorrent();
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
    await installTorrent();
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
    // DD-210: Aç opens the running app's own web UI in a new tab; its Konsol page stays one link away.
    const openApp = card.getByRole("link",{name:"qBittorrent arayüzünü yeni sekmede aç",exact:true});
    assert.equal(await openApp.getAttribute("href"),"http://torrent.ayc");
    assert.equal(await openApp.getAttribute("target"),"_blank");
    if (!(await detail.isVisible())) await toggle.click();
    await detail.getByRole("link",{name:"qBittorrent ayarları ve ilk giriş bilgileri",exact:true}).click();
    await page.getByRole("textbox",{name:"Kullanıcı adı",exact:true}).waitFor();
    assert.equal(await page.getByRole("tab").count(),0);
    // Removing the old shared-account UI must preserve qBittorrent's opt-in secret.
    assert.equal(passwordReads,0);
    const firstLogin = page.locator(".app-account > summary");
    const account = page.locator("#torrent-account");
    const showPassword = account.getByRole("button",{name:"Geçici parolayı göster",exact:true});
    await firstLogin.click(); await showPassword.waitFor();
    assert.equal(passwordReads,0,"Expanding metadata must not request the password");
    await showPassword.click();
    await account.getByText(temporaryPassword,{exact:true}).waitFor();
    assert.equal(passwordReads,1);
    assert.equal(await page.locator(".cred.row3,.fresh-msg").count(),0);
    // Advance only the browser clock; no 30-second wall-clock wait is needed.
    await account.getByRole("button",{name:"Geçici parolayı gizle",exact:true}).click();
    await showPassword.click(); await account.getByText(temporaryPassword,{exact:true}).waitFor();
    await page.clock.runFor(31000);
    // API fixtures use the runner's wall clock; realign after the expiry probe.
    await page.clock.setSystemTime(new Date());
    assert.equal(await account.getByText(temporaryPassword,{exact:true}).count(),0);
    assert.equal(passwordReads,2,"Polling must not reread secrets");
    await showPassword.click(); await account.getByText(temporaryPassword,{exact:true}).waitFor();
    await page.evaluate(() => {
      Object.defineProperty(document,"hidden",{configurable:true,value:true});
      document.dispatchEvent(new Event("visibilitychange"));
      delete document.hidden;
    });
    assert.equal(await account.getByText(temporaryPassword,{exact:true}).count(),0);
    await showPassword.click(); await account.getByText(temporaryPassword,{exact:true}).waitFor();
    await firstLogin.click();
    await page.waitForFunction(() => !document.querySelector("#torrent-account").textContent);
    await firstLogin.click(); await showPassword.waitFor();
    assert.equal(passwordReads,4,"Reopening the card must keep the password hidden");
    await showPassword.click(); await account.getByText(temporaryPassword,{exact:true}).waitFor();
    await navigate("#/moduller"); await navigate("#/torrent");
    assert.equal(await account.getByText(temporaryPassword,{exact:true}).count(),0);
    assert.equal(passwordReads,5,"Navigation must not restore the secret");
    assert(!JSON.stringify(await page.evaluate(() => [localStorage,sessionStorage])).includes(temporaryPassword));
    await firstLogin.click();
    temporaryLogin = false;
    await firstLogin.click();
    await account.getByText(/^Parola kayıtlı;/).waitFor();
    assert.equal(await showPassword.count(),0,"Stored passwords cannot be revealed");
    assert.equal(passwordReads,5);
    await firstLogin.click();
    await page.locator("#torrent-status").getByRole("button",{name:"Durdur",exact:true}).click();
    await page.locator("#cf-go").click();
    await page.locator("#torrent-status").getByRole("button",{name:"Başlat",exact:true}).click();
    await page.locator("#torrent-status").getByRole("button",{name:"Durdur",exact:true}).waitFor();
    assert.equal(await page.locator("#torrent-open").getAttribute("href"),"http://torrent.ayc","tailnet Konsol links the tailnet name");
    assert.equal(await page.locator("#foot-access").innerText(),"Tailscale");
    // DD-204: the overview shows the installed application as a tile and links its page.
    await navigate("#/genel");
    const appTile = page.locator('#genel-tiles .tile[data-tile="torrent"]');
    await appTile.waitFor();
    assert.equal(await appTile.locator("strong").innerText(),"qBittorrent");
    assert.equal(await appTile.locator("small").innerText(),"çalışıyor");
    assert.equal(await appTile.locator(".dot.on").count(),1);
    assert(await appTile.locator(".ico.t-video").count() === 1, "the tile uses the package's declared tone");
    // DD-206: the network card lists the package's totals from its own traffic module.
    const appTraffic = page.locator('#ag-apps .net-app[data-app="torrent"]');
    await appTraffic.waitFor();
    assert.equal(await appTraffic.locator("strong").innerText(),"qBittorrent");
    assert.deepEqual(await appTraffic.locator(".v").allTextContents(),["↓ 5,0 GB","↑ 1,0 GB"]);
    assert.match(await appTraffic.locator("small").innerText(),/^tüm zamanlar · kayıt \d\d:\d\d$/,"all-time figures name the time qBittorrent saved them");
    assert.equal(await appTraffic.locator(".ico.t-video").count(),1);
    // DD-210: the tile opens the app's web UI in a new tab; the settings action beside it is separate.
    assert.equal(await appTile.locator("a.tile-link").getAttribute("href"),"http://torrent.ayc");
    assert.equal(await appTile.locator("a.tile-link").getAttribute("target"),"_blank");
    assert.equal(await appTile.getByRole("button",{name:"qBittorrent ayarları",exact:true}).count(),1);
    await navigate("#/torrent");
    await page.getByRole("textbox",{name:"Kullanıcı adı",exact:true}).waitFor();
    await navigate("#/torrent");
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
    // DD-183: no jobs page. Files stays open; a bar above the list shows the running job.
    const archiveBar = page.locator("#archive-bar");
    await archiveBar.getByText("media-backup.zip",{exact:true}).waitFor();
    assert.equal(await page.evaluate(() => location.hash),"#/dosyalar");
    assert.equal(await page.locator("#fs-tabs").getByRole("button",{name:"Arşiv işleri",exact:true}).count(),0);
    assert.match(await archiveBar.innerText(),/Çalışıyor · İşleniyor/);
    assert.equal(submitted.operation,"zip");
    assert.equal(submitted.name,"media-backup.zip");
    assert.equal(submitted.target,"Belgeler");
    assert.deepEqual(submitted.names,["media"]);
    await archiveBar.getByRole("button",{name:"İptal et",exact:true}).click();
    await archiveBar.waitFor({state:"hidden"});
    await page.getByText("media-backup.zip:",{exact:false}).first().waitFor();
    await page.getByRole("button",{name:"sample.zip ayrıntıları",exact:true}).click();
    await page.locator("#fs-detail").getByRole("button",{name:"Arşiv açıcı",exact:true}).click();
    assert.equal(await page.locator("#archive-nested,#archive-layers,.archive-form .archive-limits").count(),0);
    assert.equal(await page.locator("#archive-target").textContent(),"/srv/downloads");
    await page.locator("#sh").getByRole("button",{name:"Arşivi aç",exact:true}).click();
    await archiveBar.getByText("sample",{exact:true}).waitFor();
    assert.equal(submitted.operation,"unzip"); assert.equal(submitted.nested,undefined); assert.equal(submitted.layers,undefined);
    assert.equal(submitted.target,"downloads");
    jobs[0].status = "done"; jobs[0].result = "sample"; jobs[0].message = "Tamamlandı; kaynaklar korundu.";
    await archiveBar.waitFor({state:"hidden"});
    await page.getByText("sample: Tamamlandı",{exact:false}).first().waitFor();
    await page.getByRole("button",{name:"media ayrıntıları",exact:true}).waitFor();
    for (const filename of ["sample.rar","sample.r00","sample.part01.rar"]) {
      await page.getByRole("button",{name:filename+" ayrıntıları",exact:true}).click();
      await page.locator("#fs-detail").getByRole("button",{name:"Arşiv açıcı",exact:true}).click();
      assert.equal(await page.locator("#archive-name").inputValue(),"sample");
      assert(!/ZIP|RAR|katman|işlenen veri|10.000/.test(await page.locator("#sh").innerText()));
      await page.locator("#sh").getByRole("button",{name:"Arşivi aç",exact:true}).click();
      await archiveBar.getByText("sample",{exact:true}).waitFor();
      assert.deepEqual(submitted.names,[filename]);
      assert.equal(submitted.nested,undefined);
      jobs[0].status="failed"; jobs[0].message="Eksik RAR parçası; sonuç yayımlanmadı.";
      await archiveBar.waitFor({state:"hidden"});
    }
    await navigate("#/dosyalar");
    await page.getByRole("button",{name:"media ayrıntıları",exact:true}).waitFor();
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
    modules[0].installed = true; modules[0].state = "calisiyor"; modules[0].sayfa = ["sayfa.js","sayfa.css"];
    await page.goto(base + "/?deep-link-test=1#/wireguard/ekle");
    // The field exists only once the package script has mounted; wait for it, then for its value.
    await page.waitForFunction(() => (document.querySelector("#na-port") || {value:""}).value !== "");
    await page.locator("#na-label").fill("Keep my draft");
    await refreshResources();
    assert.equal(await page.locator("#na-label").inputValue(),"Keep my draft");
    // The page, its stylesheet and its sidebar link come from the package (DD-200).
    assert.equal(await page.locator('script[src="/uygulama/wireguard/sayfa.js"]').count(),1);
    assert.equal(await page.locator('link[href="/uygulama/wireguard/sayfa.css"]').count(),1);
    assert.deepEqual(await page.locator(".nav a[data-app]").allTextContents(),["WireGuard"]);
    assert.equal(await page.locator("#eyebrow").innerText(),"WireGuard · yeni ağ");
    for (const width of [1440,1024,736,390,320]) {
      await page.setViewportSize({width,height:950});
      for (const hash of ["#/genel","#/dosyalar","#/dosyalar/paylasim","#/dosyalar/cop","#/moduller","#/ayarlar"]) {
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
    // Konsol on its public HTTPS address (DD-195): qBittorrent opens by its own public name,
    // or the page points to Settings → Caddy while that publication is off.
    Object.assign(modules[1], {installed:true,state:"calisiyor",live:"running",busy:false,progress:null,sayfa:["sayfa.js","sayfa.css"],urls:{tailscale:"http://torrent.ayc",internet:"https://qbit.example.net"}});
    const secure = await context.newPage();
    secure.on("pageerror", e => errors.push(e.message));
    secure.on("console", msg => { if (/violates.*Content Security Policy|Refused to/.test(msg.text())) errors.push(msg.text()); });
    await secure.route("**/*", async route => {
      const url = new URL(route.request().url());
      if (url.pathname.startsWith("/api/")) return apiHandler(route);
      if (url.pathname.startsWith("/uygulama/")) return packageFile(route);
      const response = await route.fetch({url:base + url.pathname + url.search});
      await route.fulfill({response,headers:{...response.headers(),"content-security-policy":csp}});
    });
    await secure.goto("https://konsol.example/#/torrent");
    await secure.locator("#torrent-open").waitFor();
    assert.equal(await secure.locator("#torrent-open").getAttribute("href"),"https://qbit.example.net");
    assert.equal(await secure.locator("#foot-access").innerText(),"İnternet · HTTPS");
    await secure.locator("details:has(#torrent-account) > summary").click();
    await secure.locator("#torrent-account").getByText("qbit.example.net",{exact:true}).waitFor();
    modules[1].urls.internet = null;
    await secure.reload();
    await secure.locator("#torrent-open-note").waitFor();
    assert.equal(await secure.locator("#torrent-open").count(),0,"no tailnet link on the public address");
    assert.equal(await secure.locator("#torrent-open-note").getByRole("link").getAttribute("href"),"#/ayarlar/web");
    await secure.close();
    console.log("PASS: Model A routes/navigation, compact Store rows/details/progress/failure/focus/logs/no credentials/lifecycle, qBittorrent opt-in password/30s expiry/hidden-tab/card-close/navigation/no storage, shared settings, keyboard/5 widths/dark, resources/stale/offline/recovery, archive create/cancel/unzip/results, WG deep link, public-address qBittorrent link/hint, production CSP. Screenshots: " + shots);
  } finally { await browser.close(); }
})().catch(err => {console.error(err); process.exit(1);});
