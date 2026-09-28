/* Network settings use fixture APIs only, under the production CSP. */
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const assert=require('node:assert/strict'), fs=require('node:fs'), path=require('node:path'), os=require('node:os');
const shots=fs.mkdtempSync(path.join(os.tmpdir(),'konsol-wg-settings-'));
const csp=fs.readFileSync(path.join(__dirname,'../templates/Caddyfile'),'utf8').match(/Content-Security-Policy "([^"]+)"/)[1];
const dns='1.1.1.1, 1.0.0.1, 2606:4700:4700::1001';
const nets=[0,1].map(i=>({iface:`wg${i}`,port:61001+i,scope:i?'inet':'ui',server4:`10.8.${i}.1`,subnet4:`10.8.${i}.0/24`,server6:`fd00::${i}:1`,subnet6:`fd00::${i}:0/112`,dns,label:i?'Kapalı ağ':'Ana ağ',active:!i,count:1,revision:String(i+1).repeat(64),
 peers:[{name:'fixture',ipv4:`10.8.${i}.2`,ipv6:`fd00::${i}:2`,enabled:true,profile:true,dns,keepalive:21,rx:0,tx:0,handshake:0,online:false}]}));
const writes=[], errors=[]; let failure=false, stateReads=0;
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHROMIUM?{executablePath:process.env.PLAYWRIGHT_CHROMIUM}:{})});
 try {
  const page=await browser.newPage({viewport:{width:1440,height:1000}});
  page.on('pageerror',e=>errors.push(e.message));
  page.on('console',m=>{if(/violates.*Content Security Policy|Refused to/.test(m.text()))errors.push(m.text());});
  await page.route('**/*',async route=>{
   const req=route.request(), p=new URL(req.url()).pathname;
   if(!p.startsWith('/api/')){
    if(req.resourceType()!=='document')return route.continue();
    const response=await route.fetch(); return route.fulfill({response,headers:{...response.headers(),'content-security-policy':csp}});
   }
   let data={};
   if(req.method()==='POST') {
    assert.match(p,/^\/api\/wg\/nets\/wg[01]\/ayarlar$/,'settings never calls reset or peer mutation');
    const body=req.postDataJSON(); writes.push({p,...body});
    const net=nets.find(n=>p.includes('/'+n.iface+'/'));
    if(failure||net.revision!==body.revision)return route.fulfill({status:409,contentType:'application/json',body:JSON.stringify({error:'Ağ ayarları değişmiş; pencereyi kapatıp yeniden açın'})});
    Object.assign(net,{dns:body.dns,scope:body.scope,revision:'b'.repeat(64)}); data={iface:net.iface};
   } else if(p==='/api/wg/state') {stateReads++; data={host:'fixture',version:'test',installed:true,networks:nets,now:Date.now()/1000,max:10,defaults:{dns,keepalive:21,mtu:1420},reserved:[]};}
   else if(p==='/api/konsol/moduller') data={items:[{id:'wireguard',installed:true,state:'calisiyor',runtime:'konsol',live:'running'},{id:'torrent',installed:false,state:'yok',runtime:'host',live:'-'}]};
   else if(p==='/api/konsol/kaynaklar')data={host:'fixture',domain:'ayc',version:'test',root:'/srv',read_at:Date.now()/1000,sampled_at:null,cpu:[],mem:null,disk:null,net:{}};
   else if(p==='/api/konsol/paylasim')data={items:[],enabled:true};
   else if(p==='/api/state')data={root:'/srv',temp:'downloads/incomplete',trash:{count:0,size:0},disk:{total:100,free:80}};
   else if(['/api/wg/islemler','/api/archives','/api/trash'].includes(p))data={items:[]};
   else if(p==='/api/list')data={path:'',entries:[]};
   else errors.push('unexpected endpoint '+p);
   return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});
  });
  await page.goto((process.env.KONSOL_URL||'http://127.0.0.1:8766')+'/#/wireguard');
  const open=async iface=>page.getByRole('button',{name:iface+' arayüz ayarları',exact:true}).click();
  await open('wg0');
  const dialog=page.locator('#sh');
  assert.equal(await page.locator('#wn-save').isDisabled(),true);
  assert.equal(await dialog.getByRole('switch',{name:'Local erişim'}).getAttribute('aria-checked'),'true');
  assert.match(await dialog.innerText(),/Mevcut cihazların DNS ayarı ve QR\/profili değişmez/);
  await dialog.getByRole('radio',{name:/^Quad9/}).click();
  assert.equal(writes.length,0,'DNS choice must not submit form');
  await dialog.getByRole('switch',{name:'Local erişim'}).click();
  const previous=stateReads;
  await page.waitForResponse(r=>new URL(r.url()).pathname==='/api/wg/state'&&stateReads>previous);
  assert.equal(await dialog.getByRole('radio',{name:/^Quad9/}).getAttribute('aria-checked'),'true','poll must preserve draft');
  assert.equal(await dialog.getByRole('switch',{name:'Local erişim'}).getAttribute('aria-checked'),'false');
  for(const width of [1440,736,390,320]) {
   await page.setViewportSize({width,height:1000});
   await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`width ${width}`);
   assert(await dialog.locator('fieldset').evaluate(e=>e.scrollWidth<=e.clientWidth+1),`fieldset ${width}`);
  }
  await page.screenshot({path:path.join(shots,'network-mobile.png'),fullPage:true});
  await page.locator('#wn-save').click();
  await page.waitForFunction(()=>!document.querySelector('#sh').open);
  assert.deepEqual(writes[0],{p:'/api/wg/nets/wg0/ayarlar',scope:'inet',dns:'9.9.9.9, 149.112.112.112, 2620:fe::fe',revision:'1'.repeat(64)});
  assert.equal(nets[0].peers[0].dns,dns);
  await page.locator('#wg-add').click();
  assert.equal(await dialog.getByRole('radio',{name:/^Quad9/}).getAttribute('aria-checked'),'true','new peers use saved network DNS');
  await dialog.getByRole('button',{name:'Vazgeç',exact:true}).click();
  await open('wg0');
  assert.equal(await page.locator('#wn-save').isDisabled(),true);
  await dialog.getByRole('radio',{name:/^Custom/}).click();
  await page.locator('#wn-dns-custom').fill('bad-domain.test');
  assert.equal(await page.locator('#wn-save').isDisabled(),true);
  await page.locator('#wn-dns-custom').fill('8.8.8.8');
  failure=true; await page.locator('#wn-save').click();
  await dialog.getByRole('alert').waitFor();
  assert.equal(await page.locator('#sh').evaluate(e=>e.open),true);
  assert.equal(await page.locator('#wn-dns-custom').inputValue(),'8.8.8.8');
  assert.equal(nets[0].dns,'9.9.9.9, 149.112.112.112, 2620:fe::fe');
  await dialog.getByRole('button',{name:'Vazgeç',exact:true}).click();
  failure=false;
  await open('wg1');
  await dialog.getByRole('switch',{name:'Local erişim'}).click();
  await page.locator('#wn-save').click();
  await page.waitForFunction(()=>!document.querySelector('#sh').open);
  assert.equal(nets[1].active,false);
  await open('wg0');
  await dialog.getByRole('button',{name:'Anahtarı yeniden üret',exact:true}).click();
  assert.equal(await page.locator('#cf').evaluate(e=>e.open),true);
  assert.equal(await page.locator('#cf-go').isDisabled(),true);
  await page.locator('#cf-word').fill('onayla');
  assert.equal(await page.locator('#cf-go').isDisabled(),false);
  await page.locator('#cf-cancel').click();
  assert.equal(writes.length,3,'regenerate cancelled without POST');
  await page.setViewportSize({width:1440,height:1000});
  await page.emulateMedia({colorScheme:'dark'}); await open('wg0');
  await page.screenshot({path:path.join(shots,'network-desktop-dark.png'),fullPage:true});
  assert.deepEqual(errors,[]);
  console.log('PASS WireGuard settings DNS/local save, no peer reset, polling draft, failure/retry, stopped network, explicit regeneration confirmation, 4 widths/dark/CSP. Screenshots: '+shots);
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
