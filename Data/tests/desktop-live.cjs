/* Real disposable-host browser acceptance. ZIP writes only inside ARCHIVE_FIXTURE.
   Optional app lifecycle is explicitly enabled with TEST_APP_LIFECYCLE=1. */
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const screenshots = fs.mkdtempSync(path.join(os.tmpdir(), "konsol-v129-live-"));
const fixture = process.env.ARCHIVE_FIXTURE;
assert(/^archive-test-[a-f0-9]+$/.test(fixture || ""), "Pass the owned live archive fixture name");
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.PLAYWRIGHT_CHROMIUM ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM} : {})});
  try {
    const page = await browser.newPage({viewport:{width:1440,height:1000}});
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.goto(process.env.KONSOL_URL || "http://panel.ayc/");
    await page.getByRole("heading", {name:"Dosyalar", exact:true}).waitFor();
    await page.getByRole("button", {name:fixture + " ayrıntıları", exact:true}).click();
    await page.getByRole("button", {name:"Klasörü aç", exact:true}).click();
    await page.getByRole("button", {name:"source ayrıntıları", exact:true}).click();
    await page.locator("#fs-detail").getByRole("button", {name:"ZIP oluştur", exact:true}).click();
    await page.locator("#archive-name").fill("browser.zip");
    await page.locator("#archive-target").fill("../outside");
    await page.locator("#sh").getByRole("button", {name:"ZIP oluştur", exact:true}).click();
    await page.locator("#sh [role=alert]").waitFor();
    await page.locator("#archive-target").fill(fixture);
    await page.locator("#sh").getByRole("button", {name:"ZIP oluştur", exact:true}).click();
    await page.waitForFunction(() => !document.querySelector("#sh").open);
    await page.getByRole("button", {name:"browser.zip ayrıntıları", exact:true}).click();
    await page.locator("#fs-detail").getByRole("button", {name:"ZIP aç", exact:true}).click();
    assert.equal(await page.locator("#archive-nested").isChecked(), true);
    await page.locator("#archive-name").fill("browser-expanded");
    await page.locator("#sh").getByRole("button", {name:"ZIP aç", exact:true}).click();
    await page.getByRole("button", {name:"browser-expanded ayrıntıları", exact:true}).waitFor();
    await page.screenshot({path:path.join(screenshots,"files-desktop.png"),fullPage:true});
    await page.locator("#fs-tabs").getByRole("button", {name:"Paylaşımlar", exact:true}).click();
    await page.locator(".dav-shares").waitFor();
    assert.match(await page.locator("#fs-body").innerText(), /Duraklatıldı/);
    await page.locator(".desktop-dock").getByRole("link", {name:"Uygulamalar",exact:true}).click();
    await page.locator("#desktop-apps").waitFor();
    await page.screenshot({path:path.join(screenshots,"applications-desktop.png"),fullPage:true});
    await page.locator("#window-min").click();
    assert(await page.locator("body").evaluate(el => el.classList.contains("desktop-minimized")));
    await page.locator(".desktop-dock").getByRole("link", {name:"Uygulamalar",exact:true}).click();
    assert(!(await page.locator("body").evaluate(el => el.classList.contains("desktop-minimized"))));
    await page.locator("#window-max").click();
    assert.equal(await page.locator("#window-max").getAttribute("aria-pressed"), "true");
    await page.locator("#window-max").click();
    await page.locator(".desktop-dock").getByRole("link", {name:"App Store",exact:true}).click();
    await page.locator("#modc-torrent").waitFor();
    assert.equal(await page.locator("#modc-paylasim,#modc-dosya").count(),0);
    assert.equal(await page.locator("#mod-grid > article").count(),2);
    if (process.env.TEST_APP_LIFECYCLE === "1") {
      const card = page.locator("#modc-torrent");
      await card.getByRole("button", {name:"Kur",exact:true}).click();
      await card.getByRole("button", {name:"Kaldır",exact:true}).waitFor({timeout:180000});
      await card.getByRole("button", {name:"Durdur",exact:true}).click();
      await page.locator("#cf-go").click();
      await card.getByRole("button", {name:"Başlat",exact:true}).waitFor({timeout:60000});
      await card.getByRole("button", {name:"Başlat",exact:true}).click();
      await card.getByRole("button", {name:"Durdur",exact:true}).waitFor({timeout:60000});
      await page.screenshot({path:path.join(screenshots,"store-installed.png"),fullPage:true});
      await card.getByRole("button", {name:"Kaldır",exact:true}).click();
      assert.equal(await page.locator("#mod-veri").isChecked(),false);
      await page.locator("#cf-go").click();
      await card.getByRole("button", {name:"Kur",exact:true}).waitFor({timeout:60000});
      console.log("PASS: real App Store qBittorrent install/stop/start/remove; profile retained.");
    }
    for (const width of [1440,1024,736,390,320]) {
      await page.setViewportSize({width,height:950});
      for (const app of ["Uygulamalar","App Store","Ayarlar"]) {
        await page.locator(".desktop-dock").getByRole("link", {name:app,exact:true}).click();
        if (app === "Ayarlar") {
          for (const name of ["Güvenlik Duvarı","Caddy","Dnsmasq","qBittorrent"]) {
            await page.getByRole("tab", {name,exact:true}).click();
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${width}/${app}/${name}`);
          }
        } else assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${width}/${app}`);
      }
    }
    await page.emulateMedia({colorScheme:"dark"});
    await page.locator(".desktop-dock").getByRole("link", {name:"Uygulamalar",exact:true}).click();
    await page.screenshot({path:path.join(screenshots,"applications-mobile-dark.png"),fullPage:true});
    assert.deepEqual(errors,[]);
    console.log("PASS: real desktop launch/minimize/maximize, ZIP create/unzip/error recovery, shares, protected builtins, settings, 5 widths. Screenshots: " + screenshots);
  } finally { await browser.close(); }
})().catch(err => {console.error(err); process.exit(1);});
