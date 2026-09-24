/* Approved v08 interaction model, live implementation (DD-156).
   Drafts/passwords stay in memory only. No localStorage, no inline HTML. */
"use strict";
window.createSettingsPage = ({ h, svg, api, post, toast, fail, paintWeb, loadSettings }) => {
  const root = document.getElementById("settings-page");
  const clone = (x) => JSON.parse(JSON.stringify(x));
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const tabs = [["fw", "Güvenlik Duvarı"], ["web", "Caddy"], ["dns", "Dnsmasq"], ["qb", "qBittorrent"]];
  const scopeName = (s) => ({ wan: "İnternet", tail: "Tailscale", lo: "Sunucu içi" }[s] || s);
  let live = null, draft = null, qdraft = {}, tab = "fw", family = 4, scope = "all", mode = "ports";
  let pending = null, busy = false, poll = null, message = "", baseRevision = "";
  let domainInput = "", migration = null;
  const dirty = () => live?.manage?.config && draft && (!same(draft.firewall, live.manage.config.firewall) || !same(draft.dns, live.manage.config.dns) || Object.keys(qdraft).length);
  const locked = () => busy || !!pending;
  const btn = (text, action, primary = false, available = false) => h("button", { type: "button", class: "btn btn-sm" + (primary ? " btn-primary" : ""), disabled: !available && locked(), onclick: action }, text);
  const note = (text, warn = false) => h("p", { class: "as-note" + (warn ? " warn" : "") }, text);
  const badge = (text, good = false) => h("span", { class: "as-badge" + (good ? " good" : "") }, text);
  const card = (title, subtitle, ...body) => h("article", { class: "card as-card" }, h("div", { class: "card-head" }, h("div", null, h("h2", null, title), h("small", null, subtitle))), ...body);
  function field(label, control, hint) {
    control.setAttribute("aria-label", label);
    return h("label", { class: "as-field" }, h("span", null, label), control, hint ? h("small", null, hint) : null);
  }
  function select(items, value, change) {
    return h("select", { onchange: (e) => change(e.target.value) }, ...items.map(([v, label]) => h("option", { value: v, selected: String(v) === String(value) }, label)));
  }
  function toggle(label, value, action, id, disabled = false) {
    return h("button", { type: "button", id, class: "as-switch", role: "switch", "aria-label": label, "aria-checked": !!value,
      disabled: disabled || locked(), onclick: () => { action(!value); draw(); document.getElementById(id)?.focus(); } }, value ? "Açık" : "Kapalı");
  }
  function table(headers, rows, className = "") {
    return h("div", { class: "as-tablewrap" }, h("table", { class: className }, h("thead", null, h("tr", null, ...headers.map((x) => h("th", { scope: "col" }, x)))),
      h("tbody", null, ...rows)));
  }
  const td = (...kids) => h("td", null, ...kids);
  function modal(title, content, submit) {
    const dialog = h("dialog", { class: "as-dialog", "aria-labelledby": "as-dialog-title" });
    const close = () => { dialog.close(); dialog.remove(); };
    dialog.addEventListener("cancel", () => dialog.remove());
    const form = h("form", { class: "dlg", onsubmit: (e) => { e.preventDefault(); if (submit) submit(form, close); } },
      h("h3", { id: "as-dialog-title" }, title), content,
      h("div", { class: "dlg-foot" }, btn("Vazgeç", close, false, true), submit ? h("button", { type: "submit", class: "btn btn-primary" }, "Devam et") : null));
    dialog.append(form); document.body.append(dialog); dialog.showModal();
    return dialog;
  }
  function error(e) { message = e.message || String(e); fail(e); draw(); }
  function changes() {
    if (!live || !draft) return [];
    const out = [], old = live.manage.config;
    for (const r of draft.firewall) {
      if (!same(r, old.firewall.find((x) => x.id === r.id))) out.push(`${r.name}: IPv${r.family} · ${scopeName(r.scope)} · ${r.proto.toUpperCase()} ${r.port} · ${r.source || "tüm kaynaklar"} → ${r.allow ? "izin ver" : "engelle"}`);
    }
    for (const r of old.firewall) if (!draft.firewall.some((x) => x.id === r.id)) out.push(`${r.name}: kullanıcı kuralı kaldırılacak; temel politika geçerli olacak.`);
    if (!same(draft.dns, old.dns)) {
      for (const n of live.manage.names) {
        if (draft.dns.disabled.includes(n.name) !== old.dns.disabled.includes(n.name)) out.push(`${n.name} → ${draft.dns.disabled.includes(n.name) ? "kapalı" : "açık"}`);
      }
      for (const r of draft.dns.records) if (!same(r, old.dns.records.find((x) => x.name === r.name))) out.push(`${r.name} → ${r.target} · ${r.enabled ? "açık" : "kapalı"}`);
      for (const r of old.dns.records) if (!draft.dns.records.some((x) => x.name === r.name)) out.push(`${r.name}: silinecek`);
      if (draft.dns.forward !== old.dns.forward || !same(draft.dns.servers, old.dns.servers)) out.push(`Üst DNS → ${draft.dns.forward ? draft.dns.servers.join(", ") : "kapalı"}`);
    }
    if (qdraft.username !== undefined) out.push(`qBittorrent kullanıcısı → ${qdraft.username}`);
    if (qdraft.password !== undefined) out.push("qBittorrent parolası değişecek (gösterilmez).");
    if (qdraft.save !== undefined) out.push(`Yeni indirmeler → ${qdraft.save}; mevcut dosyalar taşınmaz.`);
    return out;
  }
  function reset() {
    draft = clone(live.manage.config); qdraft = {}; baseRevision = live.manage.revision; message = ""; draw();
  }
  async function submitChanges(close) {
    const payload = { revision: baseRevision };
    if (!same(draft.firewall, live.manage.config.firewall)) payload.firewall = draft.firewall;
    if (!same(draft.dns, live.manage.config.dns)) payload.dns = draft.dns;
    if (Object.keys(qdraft).length) payload.torrent = qdraft;
    close(); busy = true; message = "Sunucuda doğrulanıyor ve uygulanıyor…"; draw();
    try {
      const result = await post("/api/konsol/ayarlar/uygula", payload);
      qdraft = {}; pending = result.pending; message = "Değişiklikler geçici olarak uygulandı. Bağlantınızı onaylayın.";
      startPoll(); loadSettings(true);
    } catch (e) { delete qdraft.password; error(e); startPoll(); }
    finally { busy = false; draw(); }
  }
  function review() {
    const list = changes();
    if (!list.length) return;
    let dialog;
    dialog = modal("Değişiklikleri incele", h("div", null,
      h("ul", { class: "as-changes" }, ...list.map((t) => h("li", null, t))),
      note("Uygulama sonrası 60 saniye içinde onay gerekir. Sekme/bağlantı kapanırsa sunucu eski ayarları geri yükler. qBittorrent değişecekse indirmeler kısa süre duraklar.", true),
      note("İnternete izin vermek servisin dinlediği adresi değiştirmez. İlk eşleşen kullanıcı kuralı geçerlidir; açık bağlantılar korunur.")),
    (_form, close) => submitChanges(close));
    dialog.querySelector('[type="submit"]').textContent = "Sunucuda uygula";
  }
  async function finish(action) {
    if (busy || !pending) return;
    busy = true; draw();
    try {
      await post("/api/konsol/ayarlar/" + action, { id: pending.id });
      pending = null; qdraft = {}; draft = null; message = action === "onayla" ? "Ayarlar kalıcı olarak kaydedildi." : "Önceki ayarlar geri yüklendi.";
      toast(message); loadSettings(true);
    } catch (e) { error(e); }
    finally { busy = false; draw(); }
  }
  function startPoll() {
    clearTimeout(poll);
    poll = setTimeout(async () => {
      try {
        const s = await api("/api/konsol/ayarlar/durum");
        const was = pending; pending = s.pending;
        if (was && !pending) { draft = null; qdraft = {}; message = "İşlem tamamlandı; sunucudaki ayarlar yeniden okunuyor."; loadSettings(true); }
        draw();
      } catch (_e) { message = "Sunucuya erişilemiyor. Onay verilmezse sunucu değişiklikleri geri alır."; draw(); }
      if (pending) startPoll();
    }, 2000);
  }
  function ruleForm(existing = null) {
    const r = existing || { name: "", family, scope: scope !== "all" && scope !== "lo" ? scope : "wan", proto: "tcp", port: "", source: "", allow: true };
    const input = (name, value, attrs = {}) => h("input", { name, value, ...attrs });
    const opts = (name, choices, value) => { const s = select(choices, value, () => {}); s.name = name; return s; };
    modal(existing ? "Kuralı düzenle" : "Port kuralı ekle", h("div", { class: "as-formgrid" },
      field("Ad", input("name", r.name, { required: true, maxlength: 64 })),
      field("Kapsam", opts("scope", [["wan", "İnternet"], ["tail", "Tailscale"], ...wgScopes().map((x) => [x, x])], r.scope)),
      field("Adres ailesi", opts("family", [[4, "IPv4"], [6, "IPv6"]], r.family)),
      field("Protokol", opts("proto", [["tcp", "TCP"], ["udp", "UDP"]], r.proto)),
      field("Port", input("port", r.port, { type: "number", required: true, min: 1, max: 65535 })),
      field("Kaynak IP/CIDR", input("source", r.source, { placeholder: "boş = tüm kaynaklar", maxlength: 64 })),
      field("Eylem", opts("allow", [["true", "İzin ver"], ["false", "Engelle"]], String(r.allow)))), (form, close) => {
      const f = new FormData(form);
      const item = { id: existing ? existing.id : "u_" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8),
        name: f.get("name").trim(), family: Number(f.get("family")), scope: f.get("scope"), proto: f.get("proto"), port: Number(f.get("port")), source: f.get("source").trim(), allow: f.get("allow") === "true" };
      const clash = draft.firewall.find((x) => x.id !== item.id && x.family === item.family && x.scope === item.scope && x.proto === item.proto && x.port === item.port && x.source === item.source);
      if (clash) { toast("Bu port/kaynak için zaten bir kural var; mevcut satırı düzenleyin."); return; }
      if (existing) draft.firewall[draft.firewall.indexOf(existing)] = item;
      else draft.firewall.push(item);
      close(); draw();
    });
  }
  const wgScopes = () => [...new Set((live.firewall.ports || []).map((r) => r.scope).filter((s) => s.startsWith("wg")))];
  function addressNote(address) {
    const ip = address.replace(/^\[|\]$/g, "").split("%")[0];
    if (ip === "0.0.0.0") return "Tüm IPv4 arayüzlerinde dinler.";
    if (ip === "::") return "Tüm IPv6 arayüzlerinde dinler.";
    if (ip === "*") return "Tüm yerel arayüzlerde dinler.";
    if (ip.startsWith("127.") || ip === "::1") return "Yalnız sunucu içinden erişilir.";
    if (ip === live.tailscale || ip.startsWith("fd7a:115c:a1e0:")) return "Sunucunun Tailscale adresi.";
    if (ip === live.wan?.ipv4 || ip === live.wan?.ipv6) return "Sunucunun internet arayüzü.";
    return "Yalnız bu yerel IP üzerinde dinler.";
  }
  function fwRows() {
    const rows = clone(live.firewall.ports || []);
    for (const r of draft.firewall) {
      const found = rows.find((x) => x.family === r.family && x.scope === r.scope && x.proto === r.proto && x.port === r.port && !x.rule);
      if (found && !r.source) { found.rule = r; continue; }
      rows.push({ ...r, rule: r, baseline: r.scope === "tail" });
    }
    return rows.filter((r) => r.family === family && (scope === "all" || r.scope === scope));
  }
  function firewall() {
    const toolbar = h("div", { class: "as-toolbar" }, h("div", { class: "seg" }, ...[["ports", "Portlar"], ["rules", "Tüm kurallar"]].map(([key, name]) => h("button", { type: "button", "aria-pressed": mode === key, onclick: () => { mode = key; draw(); } }, name))),
      field("Adres ailesi", select([[4, "IPv4"], [6, "IPv6"]], family, (v) => { family = Number(v); draw(); })),
      mode === "ports" ? field("Gelen ağ", select([["all", "Tüm ağlar"], ["wan", "İnternet"], ["tail", "Tailscale"], ["lo", "Sunucu içi"], ...wgScopes().map((s) => [s, s])], scope, (v) => { scope = v; draw(); })) : null,
      btn("+ Port kuralı", () => ruleForm()));
    let content;
    if (mode === "rules") {
      const rules = live.firewall.rules || { rows: [], errors: ["Kurallar okunamadı"] };
      content = h("div", null, ...rules.errors.map((e) => note(e, true)), table(["Tablo / zincir", "Sıra", "Kural", "Sayaç", "Sahibi"], rules.rows.filter((r) => r.family === family).map((r) => h("tr", null,
        td(h("strong", null, r.table), h("small", null, r.chain)), td(r.position), td(h("code", null, r.spec)), td(`${r.packets.toLocaleString("tr-TR")} pkt`, h("small", null, `${r.bytes} bayt`)), td(r.owner, h("small", null, "salt okunur")))), "as-rules"));
    } else {
      content = table(["Servis / kaynak", "Port", "Dinlenen adres", "Politika", "İzin", "Ayrıntı"], fwRows().map((r, i) => {
        const rule = r.rule, allow = rule ? rule.allow : r.baseline;
        const sockets = live.firewall.listeners;
        const binds = (sockets || []).filter((s) => s.port === r.port && s.proto === r.proto && (!s.family || s.family === family)).map((s) => s.address);
        const detail = h("details", null, h("summary", null, "Ayrıntı"), h("p", null, `IPv${r.family} · ${scopeName(r.scope)} · kaynak ${rule?.source || "tümü"}`),
          note("Bu izin politikasıdır; port taraması/erişim garantisi değildir. Tailscale ACL ve üçüncü taraf kuralları da etkili olabilir."),
          rule ? h("div", { class: "as-inline" }, btn("Düzenle", () => ruleForm(rule)), btn("Kuralı kaldır", () => { draft.firewall = draft.firewall.filter((x) => x.id !== rule.id); draw(); })) : null);
        return h("tr", { class: rule && !same(rule, live.manage.config.firewall.find((x) => x.id === rule.id)) ? "changed" : "" },
          td(h("strong", null, r.name), h("small", null, scopeName(r.scope), rule?.source ? ` · ${rule.source}` : "")),
          td(h("code", null, `${r.port}/${r.proto}`)), td(sockets === null ? "Okunamadı" : binds.length ?
            [...new Set(binds)].map((address) => h("div", { class: "as-address" }, h("code", null, address), h("small", null, addressNote(address)))) :
            [h("span", null, "Dinleyici yok"), h("small", null, "Bu portta çalışan servis görülmedi.")]),
          td(badge(allow ? "İzinli" : "Engelli", allow), h("small", null, rule ? "kullanıcı kuralı" : "temel politika")),
          td(toggle(`${r.name} ${scopeName(r.scope)} ${r.proto} ${r.port}`, allow, (on) => {
            if (rule) rule.allow = on;
            else draft.firewall.push({ id: `p_${r.family}_${r.scope}_${r.proto}_${r.port}`, name: r.name.slice(0, 64), family: r.family, scope: r.scope, proto: r.proto, port: r.port, source: "", allow: on });
          }, "as-port-" + i, r.scope === "lo")), td(detail));
      }), "as-ports");
    }
    return card("Güvenlik Duvarı", "Canlı kurallar ve dinleyiciler · IPv4 / IPv6", toolbar,
      live.firewall.ok ? note("Temel kurallar çalışıyor. Eklediğiniz kurallar, ilgili portun varsayılan izninden önce değerlendirilir.") : note(live.firewall.check || "Güvenlik duvarı denetimi uyardı.", true), content,
      note("Anahtarlar yeni bağlantılara izin verir veya engeller; servisi başlatmaz ve dinlediği adresi değiştirmez. Listede olmayan internet portları varsayılan olarak kapalıdır. Sunucu içi ve mevcut bağlantılar korunur."));
  }
  const domainUrl = (domain) => `http://panel.${domain}/#/ayarlar`;
  function domainLinks(change) {
    return h("div", { class: "as-domain-links" },
      h("a", { href: domainUrl(change.new), target: "_blank", rel: "noopener" }, `Yeni Konsol'u aç: panel.${change.new}`),
      h("small", null, "Yeni sayfada bağlantıyı onaylayın. Açılmazsa 5 dakika içinde eski ayarlar geri gelir."),
      h("a", { href: domainUrl(change.old), target: "_blank", rel: "noopener" }, `Geri dönüş adresi: panel.${change.old}`));
  }
  async function submitDomain(domain, close) {
    const change = { old: live.domain, new: domain };
    close(); migration = change; busy = true; message = "Alan adı güncelleniyor; yeni adres bağlantısını aşağıda bulabilirsiniz."; draw();
    try {
      const result = await post("/api/konsol/ayarlar/uygula", { revision: baseRevision, domain });
      pending = result.pending; domainInput = "";
      message = "Yeni Konsol adresini açıp 5 dakika içinde onaylayın. Bu sayfanın eski adresi artık yanıt vermeyebilir.";
      startPoll();
    } catch (e) { message = `${e.message} Yeni adresi kontrol edin; onaylanmayan işlem otomatik geri alınır.`; }
    finally { busy = false; draw(); }
  }
  function caddy() {
    const input = h("input", { name: "domain", value: domainInput || live.domain, required: true, maxlength: 63,
      pattern: "[a-z0-9]([a-z0-9\\-]{0,61}[a-z0-9])?", disabled: locked(), autocapitalize: "none", spellcheck: false,
      oninput: (e) => { domainInput = e.target.value; } });
    const form = h("form", { class: "as-body", onsubmit: (e) => {
      e.preventDefault();
      if (locked()) return;
      if (dirty()) { toast("Önce diğer sekmelerdeki taslakları uygulayın veya vazgeçin."); return; }
      const domain = input.value;
      if (domain === live.domain) { toast("Alan adı zaten bu değerde."); return; }
      const dialog = modal("Yerel alan adını değiştir", h("div", { class: "as-stack" },
        note(`${live.domain} → ${domain}. Panel, torrent, paylaşım ve özel DNS adlarının son eki birlikte değişir.`),
        note(`Önce Tailscale Admin → DNS'te ${live.tailscale} sunucusuna, “Restrict to domain” ile ${domain} alanını ekleyin. Onay bitene kadar eski ${live.domain} eşleştirmesini de koruyun.`, true),
        note("Uygulamadan sonra aşağıdaki yeni adresi açıp 5 dakika içinde onaylayın. Aksi halde sunucu eski ada döner. Dosya yöneticisi açıksa kısa süre yeniden başlar; devam eden dosya aktarımlarını önce bitirin."),
        h("code", null, domainUrl(domain))), (_form, close) => submitDomain(domain, close));
      dialog.querySelector('[type="submit"]').textContent = "Alan adını güncelle";
    } }, field("Yerel alan adı", input, "Örneğin ayc yerine ev. Yalnız küçük harf, rakam ve tire; nokta veya http:// eklemeyin."),
    h("div", null, h("button", { type: "submit", class: "btn btn-primary", disabled: locked() || !!dirty() }, "Güncelle")));
    return h("div", { class: "as-stack" }, card("Yerel alan adı", `Geçerli adres: panel.${live.domain}`, form,
      note("Bu yerel ad değişikliği internet alan adı satın almaz veya HTTPS açmaz. DNS kayıtlarının açık/kapalı durumu ve hedefleri korunur. IP ile kullanılan paylaşım bağlantıları değişmez."),
      dirty() ? note("Alan adını değiştirmeden önce diğer ayar taslaklarını tamamlayın.", true) : null), h("article", { class: "card", id: "cfg-web" }));
  }
  function addDns() {
    let targetType = "tailscale";
    const name = h("input", { name: "name", required: true, maxlength: 253, placeholder: "yeni." + live.domain });
    const ip = h("input", { name: "ip", placeholder: "IPv4 veya IPv6", disabled: true });
    modal("Yerel alan adı ekle", h("div", { class: "as-formgrid" }, field("Tam alan adı", name, `Yalnız .${live.domain} alanı`),
      field("Hedef", select([["tailscale", "Dinamik Tailscale adresi"], ["fixed", "Sabit IP"]], targetType, (v) => { targetType = v; ip.disabled = v === "tailscale"; ip.required = v !== "tailscale"; })), field("Sabit IP", ip)), (form, close) => {
      const value = form.elements.name.value.trim().toLowerCase();
      if ([...live.manage.names, ...draft.dns.records].some((x) => x.name === value)) { toast("Bu ad zaten var."); return; }
      if (!value.endsWith("." + live.domain)) { toast(`Ad .${live.domain} ile bitmeli.`); return; }
      draft.dns.records.push({ name: value, target: targetType === "tailscale" ? "tailscale" : ip.value.trim(), enabled: true }); close(); draw();
    });
  }
  function dns() {
    const d = draft.dns;
    const names = [...live.manage.names.map((r) => ({ ...r, enabled: !d.disabled.includes(r.name) })), ...d.records.map((r) => ({ ...r, source: "Özel" }))];
    const rows = names.map((r, i) => h("tr", null, td(h("strong", null, r.name)), td(r.target === "tailscale" ? live.tailscale : r.target), td(r.source === "base" ? "Temel" : r.source),
      td(toggle(r.name, r.enabled, (on) => {
        if (r.source === "Özel") d.records.find((x) => x.name === r.name).enabled = on;
        else d.disabled = on ? d.disabled.filter((n) => n !== r.name) : [...d.disabled, r.name];
      }, "as-dns-" + i)), td(r.source === "Özel" ? btn("Sil", () => { d.records = d.records.filter((x) => x.name !== r.name); draw(); }) : null)));
    const providers = [["cloudflare", "Cloudflare", ["1.1.1.1", "1.0.0.1"]], ["google", "Google", ["8.8.8.8", "8.8.4.4"]], ["quad9", "Quad9", ["9.9.9.9", "149.112.112.112"]]];
    const provider = providers.find((x) => same(x[2], d.servers))?.[0] || "custom";
    const providerSelect = select([...providers.map((x) => [x[0], x[1]]), ["custom", "Özel IP adresleri"]], provider, (v) => { if (v !== "custom") d.servers = providers.find((x) => x[0] === v)[2].slice(); else d.servers = []; draw(); });
    providerSelect.disabled = !d.forward || locked();
    const upstream = h("input", { value: d.servers.join(", "), disabled: !d.forward || locked(), placeholder: "1.1.1.1, 1.0.0.1", "aria-label": "Üst DNS adresleri",
      onchange: (e) => { d.servers = e.target.value.split(",").map((x) => x.trim()).filter(Boolean); draw(); } });
    return h("div", { class: "as-stack" }, card("Yerel adlar", `${live.domain} · adları kapatmak servisleri durdurmaz`, h("div", { class: "as-toolbar" }, note(`Dinleme: ${live.dns.listen.join(", ")}`), btn("+ Alan adı", addDns)),
      table(["Ad", "Yanıt", "Sahibi", "Durum", ""], rows, "as-dns"), note("DNS önbellekleri hemen silinmez. Yeni ad eklemek Caddy sitesi oluşturmaz. Konsol'un kendi adını kapatan değişiklik onaylanamaz; sunucu geri alır.")),
    card("Üst DNS'e yönlendirme", "Yerel alan dışındaki sorgular için", h("div", { class: "as-body" },
      h("div", { class: "as-inline" }, toggle("Üst DNS'e yönlendirme", d.forward, (on) => { d.forward = on; if (on && !d.servers.length) d.servers = providers[0][2].slice(); }, "as-forward"), h("span", null, "Genel adları çöz")),
      field("Sağlayıcı", providerSelect),
      field("DNS IP adresleri", upstream, "En çok dört genel DNS adresi; virgülle ayırın. Sunucuların hangi sırada kullanılacağı garanti edilmez.")),
    note(`.${live.domain} içindeki adlar, kapalı veya bulunamayanlar dahil, dış DNS'e gönderilmez. İnternete DNS erişimi açılmaz. Üst DNS bağlantısı DoH/DoT ile şifrelenmez; Tailscale Admin DNS ayarları değişmez.`)));
  }
  function chooseFolder() {
    const box = h("div", { class: "as-stack" });
    const dialog = modal("İndirme klasörü seç", box);
    async function show(path) {
      box.replaceChildren(note("Klasörler okunuyor…"));
      try {
        const r = await api("/api/konsol/ayarlar/klasorler" + (path ? "?path=" + encodeURIComponent(path) : ""));
        box.replaceChildren(btn("Başlangıç dizinleri", () => show(), false, true), ...(path ? [note(path)] : []),
          ...r.items.map((x) => h("div", { class: "as-folder" }, h("div", null, h("strong", null, x.path), h("small", null, `${(x.free / 1073741824).toFixed(1)} GB boş`)),
            btn("İçine gir", () => show(x.path), false, true), btn("Seç", () => { qdraft.save = x.path; dialog.close(); dialog.remove(); draw(); }, false, true))));
      } catch (e) { box.replaceChildren(note(e.message, true)); }
    }
    show();
  }
  function torrent() {
    if (!live.torrent.installed) return card("qBittorrent", "Kurulu değil", note("Önce Modüller sayfasından qBittorrent'i kurun."));
    const username = h("input", { name: "username", required: true, value: qdraft.username ?? live.manage.username, pattern: "[A-Za-z0-9._@-]{1,64}", autocomplete: "username", disabled: locked() });
    const password = h("input", { name: "password", type: "password", minlength: 12, maxlength: 256, autocomplete: "new-password", disabled: locked() });
    const repeat = h("input", { name: "repeat", type: "password", autocomplete: "new-password", disabled: locked() });
    const form = h("form", { class: "as-body", onsubmit: (e) => {
      e.preventDefault();
      if (password.value !== repeat.value) { repeat.setCustomValidity("Parolalar aynı olmalı."); repeat.reportValidity(); return; }
      if (username.value !== live.manage.username) qdraft.username = username.value; else delete qdraft.username;
      if (password.value) qdraft.password = password.value;
      password.value = repeat.value = ""; draw(); toast("Hesap değişikliği taslağa eklendi.");
    } }, h("div", { class: "as-formgrid" }, field("Kullanıcı adı", username), h("div"), field("Yeni parola", password, "Boş bırakılırsa mevcut parola korunur; en az 12 karakter."), field("Yeni parola (tekrar)", repeat)),
    h("div", { class: "as-inline" }, h("button", { type: "submit", class: "btn btn-sm", disabled: locked() }, "Hesabı taslağa ekle"), qdraft.password ? badge("Yeni parola taslakta") : null));
    repeat.addEventListener("input", () => repeat.setCustomValidity(""));
    password.addEventListener("input", () => repeat.setCustomValidity(""));
    return h("div", { class: "as-stack" }, card("Web arayüzü hesabı", "Mevcut parola gösterilmez", form),
      card("İndirme dizini", "Yalnız yeni torrentlerin varsayılanı", h("div", { class: "as-body" }, h("code", null, qdraft.save ?? live.manage.save),
        h("div", null, btn("Klasör seç", chooseFolder)), note("Seçilen dizin mevcut ve servis kullanıcısına yazılabilir olmalı. Gerekli systemd yazma izni yalnız o dizine eklenir. Mevcut torrentler ve yarım indirmelerin dizini değiştirilmez.")),
      note(`Profil: ${live.torrent.profile}. Çöp, paylaşım iç dizinleri, gizli klasörler ve sembolik bağlantılar seçilemez.`)));
  }
  function draw() {
    if (!live) { root.replaceChildren(note("Ayarlar okunuyor…")); return; }
    if (!live.manage || live.manage.error) { root.replaceChildren(note(live.manage?.error || "Ayar yönetimi için güncel kurulumu tamamlayın.", true)); return; }
    if (!draft) return;
    const nav = h("nav", { class: "as-tabs", role: "tablist", "aria-label": "Ayar sekmeleri" }, ...tabs.map(([key, name]) => h("button", {
      type: "button", role: "tab", id: "as-tab-" + key, "aria-selected": key === tab, "aria-controls": "as-view", tabindex: key === tab ? "0" : "-1", onclick: () => { tab = key; draw(); document.getElementById("as-tab-" + key).focus(); },
      onkeydown: (e) => { const delta = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0; if (!delta && !["Home", "End"].includes(e.key)) return; e.preventDefault(); tab = tabs[e.key === "Home" ? 0 : e.key === "End" ? 3 : (tabs.findIndex(([k]) => k === tab) + delta + 4) % 4][0]; draw(); document.getElementById("as-tab-" + tab).focus(); }
    }, name)));
    const view = h("div", { id: "as-view", role: "tabpanel", "aria-labelledby": "as-tab-" + tab },
      tab === "fw" ? firewall() : tab === "dns" ? dns() : tab === "qb" ? torrent() : caddy());
    const list = changes();
    root.replaceChildren(...[nav,
      pending ? h("div", { class: "as-rollback", role: "status" }, h("strong", null, pending.phase === "awaiting" ? `${pending.seconds} sn içinde bağlantıyı onaylayın` : "Sunucuda işlem sürüyor…"),
        h("p", null, "Onay verilmezse önceki ayarlar sunucuda geri yüklenir. Sayfayı kapatmak bunu durdurmaz."),
        h("div", { class: "as-inline" }, h("button", { type: "button", class: "btn btn-primary", disabled: busy || pending.phase !== "awaiting" || pending.seconds <= 0 || (!!pending.domain && location.hostname !== "panel." + pending.domain.new), onclick: () => finish("onayla") }, "Bağlantı çalışıyor · onayla"),
          h("button", { type: "button", class: "btn", disabled: busy || pending.phase === "applying", onclick: () => finish("geri-al") }, "Geri al"))) : null,
      pending?.domain || migration ? domainLinks(pending?.domain || migration) : null,
      message ? h("p", { class: "as-message", role: "status" }, message) : null, view,
      h("footer", { class: "as-footer" }, h("div", null, h("strong", null, list.length ? `${list.length} değişiklik taslakta` : "Kaydedilmemiş değişiklik yok"),
        h("small", null, "İnceleyip uygulayana kadar sunucu değişmez.")), h("div", { class: "as-inline" },
        h("button", { type: "button", class: "btn btn-quiet", disabled: locked() || !list.length, onclick: reset }, "Vazgeç"),
        h("button", { type: "button", class: "btn btn-primary", disabled: locked() || !list.length, onclick: review }, "İncele ve uygula")))].filter(Boolean));
    if (tab === "web") paintWeb();
  }
  window.addEventListener("beforeunload", (e) => { if ((dirty() || (domainInput && domainInput !== live?.domain)) && !pending && !migration) { e.preventDefault(); e.returnValue = ""; } });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      root.querySelectorAll('input[type="password"]').forEach((x) => { x.value = ""; });
      if (qdraft.password) { delete qdraft.password; message = "Sekme gizlendiği için parola taslağı temizlendi; gerekiyorsa yeniden girin."; draw(); }
    }
  });
  return { render(data) {
    if (!data) { draw(); return; }
    const keepDraft = dirty();
    live = data;
    if (live.manage && !live.manage.error) {
      pending = live.manage.pending;
      if (!draft || !keepDraft || pending) { draft = clone(live.manage.config); baseRevision = live.manage.revision; }
      if (pending) startPoll();
    }
    draw();
  } };
};
