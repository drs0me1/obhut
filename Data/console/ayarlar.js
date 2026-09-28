/* Approved v08 interaction model, live implementation (DD-156).
   Drafts/passwords stay in memory only. No localStorage, no inline HTML. */
"use strict";
window.createSettingsPage = ({ h, svg, api, post, toast, fail, paintWeb, loadSettings, systemContent, logContent, paintLog }) => {
  let root = document.getElementById("settings-page");
  const clone = (x) => JSON.parse(JSON.stringify(x));
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const tabs = [["system", "Sistem"], ["fw", "Güvenlik Duvarı"], ["web", "Caddy"], ["dns", "Dnsmasq"], ["log", "Günlük"]];
  const scopeName = (s) => ({ wan: "İnternet", tail: "Tailscale", wg: "WireGuard", lo: "Sunucu içi" }[s] || s);
  let live = null, draft = null, qdraft = {}, tab = "system", family = 4, scope = "tail", mode = "ports", wgNetwork = "all";
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
  function table(headers, rows, className = "", caption = "") {
    return h("div", { class: "as-tablewrap" + (caption ? " as-fw-scroll" : ""),
      ...(caption ? {role:"region", "aria-label":caption, tabindex:"0"} : {}) },
      h("table", { class: className }, caption ? h("caption", null, caption) : null,
        h("thead", null, h("tr", null, ...headers.map((x) => h("th", { scope: "col" }, x)))),
        h("tbody", null, ...(rows.length ? rows : [h("tr", null, h("td", {colspan:headers.length}, "Bu seçimde kayıt yok."))]))));
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
    if (!live?.manage?.config || !draft) return [];
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
    if (qdraft.save !== undefined) out.push(`Yeni indirmeler → ${qdraft.save}; mevcut dosyalar taşınmaz.`);
    return out;
  }
  function reset() {
    draft = clone(live.manage.config); qdraft = {}; baseRevision = live.manage.revision; message = ""; draw();
  }
  async function submitChanges(close) {
    if (locked() || !dirty()) return;
    const payload = { revision: baseRevision };
    if (!same(draft.firewall, live.manage.config.firewall)) payload.firewall = draft.firewall;
    if (!same(draft.dns, live.manage.config.dns)) payload.dns = draft.dns;
    if (Object.keys(qdraft).length) payload.torrent = qdraft;
    close(); busy = true; message = "Sunucuda doğrulanıyor ve uygulanıyor…"; draw();
    try {
      const result = await post("/api/konsol/ayarlar/uygula", payload);
      qdraft = {}; pending = result.pending;
      if (result.committed) {
        draft = null; clearTimeout(poll);
        message = "Dnsmasq ayarları uygulandı ve kaydedildi.";
        toast(message);
      } else {
        message = "Değişiklikler geçici olarak uygulandı. Bağlantınızı onaylayın.";
        startPoll();
      }
      await loadSettings(true);
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
      } catch (_e) { message = pending ? "Sunucuya erişilemiyor. Onay verilmezse sunucu değişiklikleri geri alır." : "Sunucuya erişilemiyor. İşlemin sonucunu ayarları yenileyerek kontrol edin."; draw(); }
      if (pending) startPoll();
    }, 2000);
  }
  function ruleForm(existing = null) {
    const selectedScope = scope === "wg" ? (wgNetwork === "all" ? wgScopes()[0] : wgNetwork) : scope;
    const r = existing || { name: "", family, scope: selectedScope && selectedScope !== "lo" ? selectedScope : "tail", proto: "tcp", port: "", source: "", allow: true };
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
  const wgScopes = () => [...new Set([...(live.firewall.networks || []).map((n) => n.iface),
    ...(live.firewall.ports || []).map((r) => r.scope).filter((s) => /^wg\d+$/.test(s))])];
  function addressNote(address) {
    const ip = address.split("%")[0].replace(/^\[|\]$/g, "");
    if (ip === "0.0.0.0") return "Tüm IPv4 arayüzlerinde dinler.";
    if (ip === "::") return "Tüm IPv6 arayüzlerinde dinler.";
    if (ip === "*") return "Tüm yerel arayüzlerde dinler.";
    if (ip.startsWith("127.") || ip === "::1") return "Yalnız sunucu içinden erişilir.";
    if (ip === live.tailscale || ip === live.tailscale6) return "Sunucunun Tailscale adresi.";
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
    return rows.filter((r) => r.family === family && (scope === "wg"
      ? wgScopes().includes(r.scope) && (wgNetwork === "all" || r.scope === wgNetwork) : r.scope === scope));
  }
  function bindingStatus(binds, row) {
    if (live.firewall.listeners == null) return "Okunamadı";
    if (!binds.length) return "Dinleyici yok";
    if (binds.some((b) => b.scope === "any" || b.scope === row.scope))
      return row.scope === "lo" ? "Sunucu içinde dinliyor" : "Bu ağda dinliyor";
    if (binds.every((b) => b.scope === "lo")) return "Yalnız sunucu içinde";
    if (binds.some((b) => !b.scope || b.scope === "unknown")) return "Ağ eşleşmesi bilinmiyor";
    return "Başka adreste dinliyor";
  }
  function serviceNote(row) {
    const known = [
      ["SSH", "Sunucuya uzaktan terminal bağlantısı."],
      ["Tailscale", "Tailscale tünelinin bağlantı trafiği."],
      ["WireGuard", "WireGuard VPN ağına cihaz bağlantısı."],
      ["Caddy", "Panel ve servislerin web adreslerini sunar."],
      ["dnsmasq", "Yerel alan adlarını DNS ile çözer."],
      ["Paylaşım WebDAV", "Dosyalar uygulamasındaki klasör paylaşımları."],
      ["Konsol · WireGuard", "Panelin ağ ve sistem yönetimi arka ucu."],
      ["Konsol · dosya", "Panelin dosya ve ZIP işlemleri arka ucu."],
      ["qBittorrent", "Torrent uygulamasının web arayüzü."],
    ];
    return known.find(([prefix]) => row.name.startsWith(prefix))?.[1]
      || (row.rule ? "Kullanıcının tanımladığı port izni." : "Servis adı eşleştirilemedi; dinlenen adresi kontrol edin.");
  }
  function ruleNote(row) {
    if (row.spec.startsWith("Politika: ")) return "Bu zincirde eşleşmeyen paketler için varsayılan karar.";
    if (row.spec === "Özel zincir") return "Başka bir kuralın yönlendirmesiyle çalıştırılan zincir.";
    // Explain only an unambiguous terminal target; keep the complete rule visible.
    const target = row.spec.match(/(?:^|\s)-j ([A-Za-z0-9_-]+)$/)?.[1];
    const notes = {ACCEPT:"Eşleşen pakete bu zincirde izin verir.", DROP:"Eşleşen paketi yanıt vermeden düşürür.",
      REJECT:"Eşleşen paketi ret yanıtıyla engeller.", RETURN:"Çağıran zincire döner; ana zincirde varsayılan karar uygulanır.",
      MASQUERADE:"Kaynak adresini çıkış arayüzünün adresine dönüştürür."};
    if (notes[target]) return notes[target];
    return "Ham kuraldaki eşleşme ve hedef seçenekleri geçerlidir.";
  }
  function firewall() {
    const groups = ["tail", "wan", ...(live.firewall.wireguard_installed ? ["wg"] : []), "lo"];
    if (!groups.includes(scope)) scope = "tail";
    if (wgNetwork !== "all" && !wgScopes().includes(wgNetwork)) wgNetwork = "all";
    const chooseScope = (key) => { scope = key; mode = "ports"; draw(); document.getElementById("as-fw-tab-" + key)?.focus(); };
    const categories = h("nav", {class:"as-fw-tabs", role:"tablist", "aria-label":"Trafik kategorileri"}, ...groups.map((key) => h("button", {
      type:"button", role:"tab", id:"as-fw-tab-" + key, "aria-controls":"as-fw-content", "aria-selected":scope === key, tabindex:scope === key ? "0" : "-1",
      onclick:() => chooseScope(key), onkeydown:(e) => {
        const delta = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
        if (!delta && !["Home", "End"].includes(e.key)) return;
        e.preventDefault(); chooseScope(groups[e.key === "Home" ? 0 : e.key === "End" ? groups.length - 1 : (groups.indexOf(key) + delta + groups.length) % groups.length]);
      }
    }, scopeName(key))));
    const descriptions = {
      tail:"Tailscale ağından sunucuya gelen bağlantılar. Panel, yerel DNS ve dosya paylaşımları bu ağda kullanılır.",
      wan:"İnternet arayüzünden gelen bağlantılar. SSH ve VPN bağlantı portları burada yer alır; listede olmayan portlar varsayılan olarak engellenir.",
      wg:"WireGuard tünellerindeki cihazlardan sunucuya gelen bağlantılar. VPN’in UDP bağlantı portu İnternet sekmesindedir; yönlendirme ve NAT kuralları Teknik kurallar görünümündedir.",
      lo:"Sunucunun kendi iç bağlantıları (loopback). Servislerin arka uçları burada çalışır; bu izinler korunur ve değiştirilemez."
    };
    const toolbar = h("div", { class: "as-toolbar as-fw-controls" },
      field("Adres ailesi", select([[4, "IPv4"], [6, "IPv6"]], family, (v) => { family = Number(v); draw(); })),
      mode === "ports" && scope === "wg" && wgScopes().length ? field("WireGuard ağı", select([["all", "Tüm WireGuard ağları"], ...wgScopes().map((s) => {
        const net = (live.firewall.networks || []).find(n => n.iface === s);
        return [s, `${s}${net?.label ? " · " + net.label : ""}${net && !net.active ? " · durduruldu" : ""}`];
      })], wgNetwork, (v) => { wgNetwork = v; draw(); })) : null,
      mode === "ports" && scope !== "lo" && (scope !== "wg" || wgScopes().length) ? btn("+ Port kuralı", () => ruleForm()) : null,
      btn(mode === "rules" ? "Portlara dön" : "Teknik kurallar", () => { mode = mode === "rules" ? "ports" : "rules"; draw(); }, false, true));
    let content;
    if (mode === "rules") {
      const rules = live.firewall.rules || { rows: [], errors: ["Kurallar okunamadı"] };
      const rows = rules.rows.filter(r => r.family === family);
      content = h("div", {class:"as-fw-rules"}, ...rules.errors.map((e) => note(e, true)),
        table(["Tablo / zincir", "Sıra", "Ham kural", "Kısa açıklama", "Sayaç", "Sahibi / yönetim"], rows.map((r) => h("tr", null,
          h("th", {scope:"row"}, h("strong", null, r.chain), h("small", null, `${r.table} · IPv${r.family}`)), td(r.position), td(h("code", null, r.spec)),
          td(ruleNote(r)), td(`${r.packets.toLocaleString("tr-TR")} paket`, h("small", null, `${r.bytes.toLocaleString("tr-TR")} bayt`)),
          td(r.owner, h("small", null, r.owner === "Konsol" ? "Salt okunur · izinler trafik sekmelerinde yönetilir." : "Salt okunur · bu panelden değiştirilmez.")))),
        "as-rules as-fw-table", `Canlı kurallar · IPv${family} · ${rows.length} satır`),
        note("Tüm ağlar · INPUT, FORWARD ve NAT dahil tüm tablolar. Kurallar zincir içindeki sırayla değerlendirilir; sayaçlar son okumanın değeridir. Bu görünüm salt okunurdur."));
    } else {
      const rows = fwRows();
      content = table(["Servis / açıklama", "Port / protokol", "Kaynak IP / CIDR", "Dinleme / adres", "Firewall izni", "Aç / kapa", "İşlemler"], rows.map((r, i) => {
        const rule = r.rule, allow = rule ? rule.allow : r.baseline;
        const saved = live.manage.config.firewall.find(x => rule ? x.id === rule.id
          : x.family === r.family && x.scope === r.scope && x.proto === r.proto && x.port === r.port && !x.source);
        const changed = rule ? !same(rule, saved) : !!saved;
        const sockets = live.firewall.listeners;
        const binds = (sockets || []).filter((s) => s.port === r.port && s.proto === r.proto && s.family === family);
        const iface = r.scope === "wan" ? live.wan?.iface : r.scope === "tail" ? live.ts_if : r.scope;
        return h("tr", { class: changed ? "changed" : "" },
          h("th", {scope:"row"}, h("strong", null, r.name.split(" — ")[0]), h("small", null, serviceNote(r)), h("small", null, `IPv${r.family} · ${iface || "arayüz okunamadı"}`)),
          td(h("code", null, String(r.port)), h("small", null, r.proto.toUpperCase())),
          td(h("code", null, rule?.source || "Tüm kaynaklar"), h("small", null, rule?.source ? "Yalnız bu IP / ağ eşleşir." : "Seçilen gelen ağdaki tüm kaynaklar.")),
          td(h("strong", {class:"as-binding"}, bindingStatus(binds, r)), ...[...new Set(binds.map(b => b.address))].map((address) =>
            h("div", { class: "as-address" }, h("code", null, address), h("small", null, addressNote(address)))),
            sockets == null ? h("small", null, "Dinleyici durumu bilinmiyor.") : !binds.length ? h("small", null, "Bu adres ailesi ve protokolde servis görülmedi.") : null),
          td(badge(allow ? "İzinli" : "Engelli", allow), h("small", null, changed ? "Taslak · henüz uygulanmadı" : rule ? "Kullanıcı kuralı" : "Temel politika"),
            changed ? h("small", null, saved ? `Kayıtlı: ${saved.allow ? "izinli" : "engelli"}` : "Yeni kullanıcı kuralı") : null),
          td(toggle(`${r.name} ${scopeName(r.scope)} ${r.proto} ${r.port}`, allow, (on) => {
            if (rule) rule.allow = on;
            else draft.firewall.push({ id: `p_${r.family}_${r.scope}_${r.proto}_${r.port}`, name: r.name.slice(0, 64), family: r.family, scope: r.scope, proto: r.proto, port: r.port, source: "", allow: on });
          }, "as-port-" + i, r.scope === "lo"), r.scope === "lo" ? h("small", null, "Sunucu içi · korunur") : null),
          td(rule ? h("div", { class:"as-fw-actions" }, btn("Düzenle", () => ruleForm(rule)), btn("Kuralı kaldır", () => {
            draft.firewall = draft.firewall.filter(x => x.id !== rule.id); draw();
          })) : h("small", null, r.scope === "lo" ? "Değiştirilemez" : "Anahtarla kullanıcı kuralı eklenir.")));
      }), "as-ports as-fw-table", `${scopeName(scope)}${scope === "wg" && wgNetwork !== "all" ? " · " + wgNetwork : ""} · IPv${family} · ${rows.length} satır`);
    }
    return card("Güvenlik Duvarı", "Gelen ağa göre port izinleri · IPv4 / IPv6", mode === "ports" ? categories : null, toolbar,
      !live.firewall.ok ? note(live.firewall.check || "Güvenlik duvarı denetimi uyardı.", true) : null,
      h("div", {id:"as-fw-content", ...(mode === "ports" ? {role:"tabpanel", "aria-labelledby":"as-fw-tab-" + scope} : {})},
        mode === "ports" ? note(descriptions[scope]) : null,
        mode === "ports" && scope === "wg" && !wgScopes().length ? note("Henüz yönetilebilir bir WireGuard ağı yok. WireGuard uygulamasından ağ oluşturun veya durdurulmuş modülü başlatın.") : content),
      note("Dinleme ve izin ayrıdır; bu ağda dinlemesi erişim garantisi değildir. Tailscale ACL, kaynak kısıtları ve diğer kurallar da etkilidir. Yenile, güncel durumu yeniden okur."),
      note("Aç/kapa yalnız yeni bağlantıların iznini değiştirir; servisi başlatmaz. Mevcut bağlantılar korunur. Dar ekranda tabloyu yatay kaydırabilirsiniz."));
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
      }, "as-dns-" + i, r.name === "panel." + live.domain)), td(r.source === "Özel" ? btn("Sil", () => { d.records = d.records.filter((x) => x.name !== r.name); draw(); }) : null)));
    const providers = [["cloudflare", "Cloudflare", ["1.1.1.1", "1.0.0.1"]], ["google", "Google", ["8.8.8.8", "8.8.4.4"]], ["quad9", "Quad9", ["9.9.9.9", "149.112.112.112"]]];
    const provider = providers.find((x) => same(x[2], d.servers))?.[0] || "custom";
    const providerSelect = select([...providers.map((x) => [x[0], x[1]]), ["custom", "Özel IP adresleri"]], provider, (v) => { if (v !== "custom") d.servers = providers.find((x) => x[0] === v)[2].slice(); else d.servers = []; draw(); });
    providerSelect.disabled = !d.forward || locked();
    const upstream = h("input", { value: d.servers.join(", "), disabled: !d.forward || locked(), placeholder: "1.1.1.1, 1.0.0.1", "aria-label": "Üst DNS adresleri",
      onchange: (e) => { d.servers = e.target.value.split(",").map((x) => x.trim()).filter(Boolean); draw(); } });
    return h("div", { class: "as-stack" }, card("Yerel adlar", `${live.domain} · adları kapatmak servisleri durdurmaz`, h("div", { class: "as-toolbar" }, note(`Dinleme: ${live.dns.listen.join(", ")}`), btn("+ Alan adı", addDns)),
      table(["Ad", "Yanıt", "Sahibi", "Durum", ""], rows, "as-dns"), note("DNS önbellekleri hemen silinmez. Yeni ad eklemek Caddy sitesi oluşturmaz. Panel erişimi için Konsol'un kendi DNS adı korunur.")),
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
  async function saveAccount(account) {
    if (locked()) return;
    busy = true; message = "qBittorrent hesabı kaydediliyor…"; draw();
    try {
      // Account-only: never submit unrelated DNS/firewall/folder drafts (DD-165).
      const result = await post("/api/konsol/ayarlar/uygula", { revision: baseRevision, torrent: account });
      delete account.password;
      pending = result.pending;
      if (!result.committed || pending) {
        startPoll();
        throw new Error("Sunucu kalıcı kaydı doğrulamadı; işlem durumunu kontrol edin.");
      }
      if (account.username !== undefined) live.manage.username = account.username;
      message = "qBittorrent hesabı kaydedildi. Web arayüzüne yeni bilgilerle giriş yapabilirsiniz.";
      toast(message);
      await loadSettings(true);
      // Keep other drafts, but rebase them after our own committed profile write.
      baseRevision = live.manage.revision;
    } catch (e) {
      error(new Error(`Hesap kaydı doğrulanamadı. ${e.message} Sonucu Yenile ile kontrol edin; yeniden denemek için parolayı tekrar girin.`));
    } finally { delete account.password; busy = false; draw(); }
  }
  function torrent() {
    if (!live.torrent.installed) return card("qBittorrent", "Kurulu değil", note("Önce App Store’dan qBittorrent’i kurun."));
    const username = h("input", { name: "username", required: true, value: live.manage.username, maxlength: 64, pattern: "[A-Za-z0-9._@\\-]{1,64}", autocomplete: "username", disabled: locked() });
    const password = h("input", { name: "password", type: "password", minlength: 8, maxlength: 256, autocomplete: "new-password", disabled: locked() });
    const repeat = h("input", { name: "repeat", type: "password", autocomplete: "new-password", disabled: locked() });
    const form = h("form", { class: "as-body", onsubmit: (e) => {
      e.preventDefault();
      if (locked()) return;
      if (password.value !== repeat.value) { repeat.setCustomValidity("Parolalar aynı olmalı."); repeat.reportValidity(); return; }
      const account = {};
      if (username.value !== live.manage.username) account.username = username.value;
      if (password.value) account.password = password.value;
      if (!Object.keys(account).length) { toast("Hesap bilgilerinde değişiklik yok."); return; }
      password.value = repeat.value = "";
      saveAccount(account);
    } }, h("div", { class: "as-formgrid" }, field("Kullanıcı adı", username), h("div"), field("Yeni parola", password, "Boş bırakılırsa kayıtlı parola korunur; en az 8 karakter."), field("Yeni parola (tekrar)", repeat)),
    h("div", { class: "as-inline" }, h("button", { type: "submit", class: "btn btn-primary", disabled: locked() }, "Hesabı kaydet")),
    note("Doğrudan kaydedilir; ek onay gerekmez. Çalışıyorsa qBittorrent kısa süre yeniden başlar. Diğer ayar taslakları uygulanmaz."),
    note("Henüz kalıcı parola belirlenmediyse geçici ilk giriş parolası yeniden başlatmada değişebilir. Kalıcı giriş için yeni parola belirleyin."));
    repeat.addEventListener("input", () => repeat.setCustomValidity(""));
    password.addEventListener("input", () => repeat.setCustomValidity(""));
    return h("div", { class: "as-stack" }, card("Web arayüzü hesabı", "Mevcut parola gösterilmez", form),
      card("İndirme dizini", "Yalnız yeni torrentlerin varsayılanı", h("div", { class: "as-body" }, h("code", null, qdraft.save ?? live.manage.save),
        h("div", null, btn("Klasör seç", chooseFolder)), note("Seçilen dizin mevcut ve servis kullanıcısına yazılabilir olmalı. Gerekli systemd yazma izni yalnız o dizine eklenir. Mevcut torrentler ve yarım indirmelerin dizini değiştirilmez.")),
      note(`Profil: ${live.torrent.profile}. Çöp, paylaşım iç dizinleri, gizli klasörler ve sembolik bağlantılar seçilemez.`)));
  }
  function draw() {
    const previousTable = root.querySelector(".as-fw-scroll");
    const tableScroll = previousTable ? {name:previousTable.getAttribute("aria-label"), top:previousTable.scrollTop, left:previousTable.scrollLeft} : null;
    const choose = (key) => { location.hash = "#/ayarlar/" + key; };
    const nav = h("nav", { class: "as-tabs", role: "tablist", "aria-label": "Ayar sekmeleri" }, ...tabs.map(([key, name]) => h("button", {
      type: "button", role: "tab", id: "as-tab-" + key, "aria-selected": key === tab, "aria-controls": "as-view", tabindex: key === tab ? "0" : "-1", onclick: () => choose(key),
      onkeydown: (e) => { const delta = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0; if (!delta && !["Home", "End"].includes(e.key)) return; e.preventDefault(); choose(tabs[e.key === "Home" ? 0 : e.key === "End" ? tabs.length - 1 : (tabs.findIndex(([k]) => k === key) + delta + tabs.length) % tabs.length][0]); }
    }, name)));
    const ready = !!(live?.manage && !live.manage.error && draft);
    const content = tab === "system" ? systemContent() : tab === "log" ? logContent() : !ready
      ? note(live?.manage?.error || "Ayarlar okunuyor…", !!live?.manage?.error)
      : tab === "fw" ? firewall() : tab === "dns" ? dns() : tab === "qb" ? torrent() : caddy();
    const view = h("div", { id: "as-view", ...(tab === "qb" ? {} : {role: "tabpanel", "aria-labelledby": "as-tab-" + tab}) }, content);
    const list = changes();
    const directDns = ready && (tab === "dns" || !same(draft.dns, live.manage.config.dns))
      && same(draft.firewall, live.manage.config.firewall) && !Object.keys(qdraft).length;
    const restoreFocus = document.activeElement?.getAttribute("role") === "tab" ? document.activeElement.id : "";
    root.replaceChildren(...[tab === "qb" ? null : nav,
      pending ? h("div", { class: "as-rollback", role: "status" }, h("strong", null, pending.phase === "awaiting" ? `${pending.seconds} sn içinde bağlantıyı onaylayın` : "Sunucuda işlem sürüyor…"),
        h("p", null, "Onay verilmezse önceki ayarlar sunucuda geri yüklenir. Sayfayı kapatmak bunu durdurmaz."),
        h("div", { class: "as-inline" }, h("button", { type: "button", class: "btn btn-primary", disabled: busy || pending.phase !== "awaiting" || pending.seconds <= 0 || (!!pending.domain && location.hostname !== "panel." + pending.domain.new), onclick: () => finish("onayla") }, "Bağlantı çalışıyor · onayla"),
          h("button", { type: "button", class: "btn", disabled: busy || pending.phase === "applying", onclick: () => finish("geri-al") }, "Geri al"))) : null,
      pending?.domain || migration ? domainLinks(pending?.domain || migration) : null,
      message ? h("p", { class: "as-message", role: "status" }, message) : null, view,
      ready && (list.length || !["system", "log", "qb"].includes(tab)) ? h("footer", { class: "as-footer" }, h("div", null, h("strong", null, list.length ? `${list.length} değişiklik taslakta` : "Kaydedilmemiş değişiklik yok"),
        h("small", null, directDns ? "Uygula ile DNS ayarları doğrudan kaydedilir; süreli onay gerekmez." : "İnceleyip uygulayana kadar sunucu değişmez.")), h("div", { class: "as-inline" },
        h("button", { type: "button", class: "btn btn-quiet", disabled: locked() || !list.length, onclick: reset }, "Vazgeç"),
        h("button", { type: "button", class: "btn btn-primary", disabled: locked() || !list.length, onclick: directDns ? () => submitChanges(() => {}) : review }, directDns ? "Uygula" : "İncele ve uygula"))) : null].filter(Boolean));
    if (tab === "web" && ready) paintWeb();
    if (tab === "log") paintLog();
    const nextTable = root.querySelector(".as-fw-scroll");
    if (tableScroll && nextTable?.getAttribute("aria-label") === tableScroll.name) {
      nextTable.scrollTop = tableScroll.top; nextTable.scrollLeft = tableScroll.left;
    }
    if (restoreFocus && tab !== "qb") document.getElementById(restoreFocus.startsWith("as-fw-tab-") ? "as-fw-tab-" + scope : "as-tab-" + tab)?.focus();
  }
  window.addEventListener("beforeunload", (e) => { if ((dirty() || (domainInput && domainInput !== live?.domain)) && !pending && !migration) { e.preventDefault(); e.returnValue = ""; } });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      root.querySelectorAll('input[type="password"]').forEach((x) => { x.value = ""; });
    }
  });
  return { render(data, section = "system") {
    tab = section;
    const next = document.getElementById(section === "qb" ? "torrent-settings" : "settings-page");
    if (root !== next) { root.replaceChildren(); root = next; }
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
