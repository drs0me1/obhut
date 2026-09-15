/* WireGuard paneli (DD-133, DD-136). Bütün değişiklikler sunucuda master-wg ile yapılır. */
(function () {
  "use strict";
  var GiB = 1073741824, MiB = 1048576;
  var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/;
  var CONFIRM_WORD = "onayla";
  var PROVIDERS = [
    ["Cloudflare", ["1.1.1.", "1.0.0.", "2606:4700:4700::"]],
    ["Google", ["8.8.8.", "8.8.4.", "2001:4860:4860::"]],
    ["Quad9", ["9.9.9.", "149.112.112.", "2620:fe::"]],
    ["NextDNS", ["45.90.28.", "45.90.30.", "2a07:a8c0:", "2a07:a8c1:"]]
  ];
  var EXTRA_PRESETS = [
    "8.8.8.8, 8.8.4.4, 2001:4860:4860::8888",
    "9.9.9.9, 149.112.112.112, 2620:fe::fe"
  ];

  var st = null, offset = 0, confirming = null, busy = false, shape = "", cur = "wg0";
  try { cur = localStorage.getItem("wg-panel-net") || "wg0"; } catch (e) {}
  var $ = function (id) { return document.getElementById(id); };
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function now() { return Date.now() / 1000 + offset; }
  function dec(v, d) { return v.toFixed(d).replace(".", ","); }
  function bytes(b) {
    if (!b) return "0 B";
    if (b >= GiB) return dec(b / GiB, 1) + " GiB";
    if (b >= MiB) return Math.round(b / MiB) + " MiB";
    return Math.max(1, Math.round(b / 1024)) + " KiB";
  }
  function provider(dns) {
    var tokens = dns.split(",").map(function (t) { return t.trim(); }).filter(Boolean);
    for (var i = 0; i < PROVIDERS.length; i++) {
      var pre = PROVIDERS[i][1];
      var all = tokens.length && tokens.every(function (t) {
        return pre.some(function (p) { return t.indexOf(p) === 0; });
      });
      if (all) return PROVIDERS[i][0];
    }
    return "Özel";
  }
  // DD-137: "Bağlı" sunucunun söylediğidir (son 45 sn'de cihazdan veri geldi); el sıkışma
  // 2 dakikada bir yenilendiği için tek başına kapanan cihazı 3 dakika bağlı gösterirdi.
  function state(p) {
    if (p.online) return { cls: "ok", label: "Bağlı" };
    if (p.handshake && now() - p.handshake < 86400) return { cls: "idle", label: "Boşta" };
    return { cls: "never", label: "Görülmedi" };
  }
  function ago(p) {
    if (!p.handshake) return "hiç";
    var a = Math.max(0, Math.floor(now() - p.handshake));
    if (a < 120) return a + " sn önce";
    if (a < 7200) return Math.floor(a / 60) + " dk önce";
    if (a < 172800) return Math.floor(a / 3600) + " sa önce";
    return Math.floor(a / 86400) + " gün önce";
  }
  function normDns(s) {
    var parts = s.split(",").map(function (t) { return t.replace(/\s+/g, ""); }).filter(Boolean);
    if (!parts.length) return null;
    for (var i = 0; i < parts.length; i++) {
      if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(parts[i]) && !/^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$/.test(parts[i])) return null;
    }
    return parts.join(", ");
  }
  // Satır yalnız adresler arasında bölünür, bir adresin ortasında değil.
  function ipList(dns) {
    return dns.split(",").map(function (t) { return t.trim(); }).filter(Boolean)
      .map(function (t) { return '<span class="ip">' + esc(t) + '</span>'; }).join(", ");
  }
  /* Türkçe hâl ekleri rakamın okunuşuna göre: wg1'e, wg1'i. */
  function dative(name) {
    return name + ({ "0": "'a", "1": "'e", "2": "'ye", "3": "'e", "4": "'e", "5": "'e", "6": "'ya", "7": "'ye", "8": "'e", "9": "'a" }[name.slice(-1)] || "'e");
  }
  function accusative(name) {
    return name + ({ "0": "'ı", "1": "'i", "2": "'yi", "3": "'ü", "4": "'ü", "5": "'i", "6": "'yı", "7": "'yi", "8": "'i", "9": "'u" }[name.slice(-1)] || "'i");
  }
  function nets() { return st ? st.networks : []; }
  function net() {
    var list = nets();
    return list.filter(function (n) { return n.iface === cur; })[0] || list[0];
  }
  function peerPath(n, name, tail) {
    return "/api/nets/" + encodeURIComponent(n.iface) + "/peers/" + encodeURIComponent(name) + tail;
  }

  /* ---------- API ---------- */
  function api(path, opts) {
    opts = opts || {};
    var headers = { "X-WG-Panel": "1" };
    var init = { method: opts.method || "GET", headers: headers, credentials: "same-origin", cache: "no-store" };
    if (opts.body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.body);
    }
    return fetch(path, init).then(function (res) {
      if (res.status === 401) { location.reload(); throw new Error("giriş gerekli"); }
      if (opts.raw) {
        if (!res.ok) return res.json().catch(function () { return {}; }).then(function (j) { throw new Error(j.error || ("HTTP " + res.status)); });
        return res;
      }
      return res.json().catch(function () { return {}; }).then(function (j) {
        if (!res.ok) throw new Error(j.error || ("HTTP " + res.status));
        return j;
      });
    });
  }

  function refresh() {
    return api("/api/state").then(function (s) {
      st = s;
      offset = s.now - Date.now() / 1000;
      if (!net()) return;
      if (net().iface !== cur) selectNet(net().iface, false);
      render();
    }).catch(function (e) { toast(e.message, true); });
  }

  /* ---------- Rendering ---------- */
  function renderHeader() {
    var n = net();
    $("host").textContent = st.host || "sunucu";
    document.title = (st.host || "sunucu") + " · WireGuard paneli";
    var down = nets().filter(function (x) { return !x.active; });
    $("chip-active").className = "chip " + (down.length ? "down" : "live");
    $("chip-active-text").textContent = down.length ? down.map(function (x) { return x.iface; }).join(", ") + " durdu" : "Çalışıyor";
    $("chip-count").innerHTML = '<span class="mono">' + nets().length + '</span>&nbsp;arayüz';
    $("chip-endpoint").textContent = st.endpoint + ":" + n.port;
    $("chip-version").textContent = (st.version || "").replace(/^.*-(v2-\d+)$/, "$1");
    $("open-add").disabled = false;
    $("add-menu-btn").disabled = false;
    $("open-add-text").textContent = dative(n.iface) + " peer ekle";
    $("menu-peer-text").textContent = dative(n.iface) + " peer ekle";
    $("menu-net").disabled = nets().length >= st.max;
  }

  function renderTabs() {
    var html = nets().map(function (n) {
      var on = n.peers.some(function (p) { return state(p).cls === "ok"; }), sel = n.iface === cur;
      return '<button class="tab" role="tab" type="button" id="tab-' + esc(n.iface) + '" aria-controls="panel" aria-selected="' + sel + '" tabindex="' + (sel ? 0 : -1) + '" data-tab="' + esc(n.iface) + '">' +
        '<span class="tdot' + (on ? " on" : "") + '" aria-hidden="true" data-dot="' + esc(n.iface) + '"></span><span class="tif">' + esc(n.iface) + '</span>' +
        (n.label ? '<span>' + esc(n.label) + '</span>' : '') +
        '<span class="tcount">' + n.peers.length + '</span></button>';
    }).join("");
    if (nets().length < st.max) {
      html += '<button class="tab tab-add" type="button" data-act="add-net"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M8 3v10M3 8h10"/></svg>Arayüz ekle</button>';
    }
    $("tabs").innerHTML = html;
    $("panel").setAttribute("aria-labelledby", "tab-" + cur);
  }

  function rowHtml(p) {
    var s = state(p), nm = esc(p.name);
    var actions = confirming === p.name
      ? '<div class="confirm"><span>Çıkarılsın mı?</span><button class="btn btn-danger" type="button" data-act="remove-yes" data-name="' + nm + '">Çıkar</button><button class="btn btn-quiet btn-sm" type="button" data-act="remove-no">Vazgeç</button></div>'
      : '<div class="row-actions">' +
        '<button class="btn btn-quiet btn-sm" type="button" data-act="qr" data-name="' + nm + '"' + (p.profile ? "" : " disabled") + '>QR</button>' +
        '<button class="btn btn-quiet btn-sm" type="button" data-act="dns" data-name="' + nm + '"' + (p.profile ? "" : " disabled") + '>DNS</button>' +
        '<button class="btn btn-quiet btn-sm" type="button" data-act="remove" data-name="' + nm + '">Çıkar</button></div>';
    return '<div class="row">' +
      '<div class="c-status"><span class="status ' + s.cls + '" data-status="' + nm + '"><span class="dotmark"></span><span>' + s.label + '</span></span></div>' +
      '<div class="c-name"><span class="pname">' + nm + '</span></div>' +
      '<div class="c-addr"><span class="cell-label">Adres</span><span class="addr"><span class="mono">' + esc(p.ipv4) + '</span>' +
        (p.ipv6 ? '<span class="mono v6">' + esc(p.ipv6) + '</span>' : '') + '</span></div>' +
      '<div class="c-dns"><span class="cell-label">DNS</span><span>' +
        (p.profile ? '<span class="dnsname">' + esc(p.provider || provider(p.dns)) + '</span><span class="mono">' + ipList(p.dns) + '</span>'
                   : '<span class="dnsname">Profil yok</span>') + '</span></div>' +
      '<div class="c-hs"><span class="cell-label">El sıkışma</span><span class="num" data-ago="' + nm + '">' + ago(p) + '</span></div>' +
      '<div class="c-traffic"><span class="cell-label">Trafik</span><span class="traffic num"><span><i>↓</i><b data-rx="' + nm + '">' + bytes(p.rx) + '</b></span><span><i>↑</i><b data-tx="' + nm + '">' + bytes(p.tx) + '</b></span></span></div>' +
      '<div class="c-actions">' + actions + '</div></div>';
  }

  function renderPanel() {
    var n = net(), on = 0, rx = 0, tx = 0, name = n.iface, main = name === "wg0";
    n.peers.forEach(function (p) { if (state(p).cls === "ok") on++; rx += p.rx; tx += p.tx; });
    var list = n.peers.length
      ? '<div class="row head" aria-hidden="true"><div>Durum</div><div>Cihaz</div><div>Adres</div><div>DNS</div><div>Son el sıkışma</div><div class="c-traffic">Trafik</div><div></div></div>' +
        n.peers.map(rowHtml).join("")
      : '<div class="empty"><strong>' + esc(name) + ' hazır, kayıtlı peer yok</strong><span>Sunucu anahtarı ve UDP ' + n.port + ' açık. İlk cihazı ekleyin; QR hemen görünür.</span>' +
        '<button class="btn btn-primary" type="button" data-act="add">' + esc(dative(name)) + ' peer ekle</button></div>';
    var focused = document.activeElement ? document.activeElement.id : "";
    var typedReset = $("reset-confirm") ? $("reset-confirm").value : "";
    var typedDrop = $("drop-confirm") ? $("drop-confirm").value : "";
    var danger =
      '<div class="danger-item"><div><h2 id="danger-title">' + esc(accusative(name)) + ' yeniden üret</h2>' +
      '<p>Yeni sunucu anahtarı; bu ağın bütün peer\'ları ve profilleri silinir, cihazlar yeniden eklenir. Diğer ağlara dokunulmaz. Geri alınamaz.</p></div>' +
      '<div class="confirm-field"><label for="reset-confirm"><span class="mono">' + CONFIRM_WORD + '</span> yazın</label>' +
      '<input type="text" id="reset-confirm" autocomplete="off" spellcheck="false" maxlength="12" placeholder="' + CONFIRM_WORD + '">' +
      '<button class="btn btn-danger btn-sm" id="reset-run" type="button" disabled>Yeniden üret</button></div></div>';
    danger += main
      ? '<div class="danger-item"><div><p>wg0 kurulumun ağıdır ve kaldırılamaz.</p></div></div>'
      : '<div class="danger-item"><div><h2>' + esc(accusative(name)) + ' kaldır</h2>' +
        '<p>Arayüz, anahtarı, bütün peer\'ları ve güvenlik duvarı kuralları silinir; UDP ' + n.port + ' kapanır.</p></div>' +
        '<div class="confirm-field"><label for="drop-confirm"><span class="mono">' + CONFIRM_WORD + '</span> yazın</label>' +
        '<input type="text" id="drop-confirm" autocomplete="off" spellcheck="false" maxlength="12" placeholder="' + CONFIRM_WORD + '">' +
        '<button class="btn btn-danger btn-sm" id="drop-run" type="button" disabled>Arayüzü kaldır</button></div></div>';
    $("panel").innerHTML =
      '<div class="net-head"><div class="net-title"><span class="big">' + esc(name) + '</span>' + (n.label ? '<span class="lab">' + esc(n.label) + '</span>' : '') +
      '<div class="chips"><span class="chip">Sunucu <span class="mono">' + esc(n.server4) + '/24</span></span>' +
      '<span class="chip">UDP <span class="mono">' + n.port + '</span></span>' +
      '<span class="chip">IPv6 <span class="mono">' + esc(n.subnet6) + '</span></span>' +
      (n.scope === "ui" ? '<span class="chip scope-ui">İnternet + arayüzler</span>' : '<span class="chip">Yalnız internet</span>') +
      (n.active ? '' : '<span class="chip down">Durdu</span>') + '</div></div></div>' +
      '<dl class="summary"><div><dt>Peer</dt><dd class="num">' + n.peers.length + '<small>/ 253 adres</small></dd></div>' +
      '<div><dt>Şu an bağlı</dt><dd class="num"><span id="sum-on">' + on + '</span><small>son ' + (st.active_window || 45) + ' sn</small></dd></div>' +
      '<div><dt>Gelen</dt><dd class="num" id="sum-rx">' + bytes(rx) + '</dd></div>' +
      '<div><dt>Giden</dt><dd class="num" id="sum-tx">' + bytes(tx) + '</dd></div></dl>' +
      '<div class="list"><div class="section-head"><h2>' + esc(name) + ' peer\'ları</h2><p class="hint">Bağlı: son ' + (st.active_window || 45) + ' sn içinde cihazdan veri geldi. Liste 10 sn\'de bir yenilenir.</p></div>' +
      '<div class="peers">' + list + '</div></div>' +
      '<section class="danger" aria-labelledby="danger-title">' + danger + '</section>' +
      '<div class="footnote"><span>Uç nokta <span class="mono">' + esc(st.endpoint) + ':' + n.port + '</span></span>' +
      '<span>Alt ağ <span class="mono">' + esc(n.subnet4) + '</span></span>' +
      '<span>Ağlar arası ve cihazlar arası trafik kapalı; panel yalnız Tailscale\'den açılır</span></div>';
    $("reset-confirm").value = typedReset;
    if ($("drop-confirm")) $("drop-confirm").value = typedDrop;
    confirmEnabled();
    if (focused && $(focused)) $(focused).focus();
  }

  // Yapı (ağlar, peer'lar, adresleri, DNS'leri, onay satırı) değişmediyse yeniden
  // çizilmez: yalnız durum, süre ve trafik yerinde güncellenir. Böylece 10 sn'lik
  // yenileme bir tıklamanın ortasında düğmeyi değiştirmez.
  function shapeOf() {
    return JSON.stringify([cur, confirming, st.max, nets().map(function (n) {
      return [n.iface, n.port, n.scope, n.label, n.active, n.server4, n.subnet4, n.subnet6,
        n.peers.map(function (p) { return [p.name, p.ipv4, p.ipv6, p.dns, p.provider, p.profile]; })];
    })]);
  }
  function each(sel, fn) { Array.prototype.forEach.call(document.querySelectorAll(sel), fn); }
  function updateLive() {
    var n = net(), on = 0, rx = 0, tx = 0;
    n.peers.forEach(function (p) {
      var s = state(p), key = CSS.escape(p.name);
      if (s.cls === "ok") on++;
      rx += p.rx; tx += p.tx;
      each('[data-status="' + key + '"]', function (el) { el.className = "status " + s.cls; el.lastChild.textContent = s.label; });
      each('[data-ago="' + key + '"]', function (el) { el.textContent = ago(p); });
      each('[data-rx="' + key + '"]', function (el) { el.textContent = bytes(p.rx); });
      each('[data-tx="' + key + '"]', function (el) { el.textContent = bytes(p.tx); });
    });
    if ($("sum-on")) { $("sum-on").textContent = on; $("sum-rx").textContent = bytes(rx); $("sum-tx").textContent = bytes(tx); }
    nets().forEach(function (x) {
      var dot = document.querySelector('[data-dot="' + CSS.escape(x.iface) + '"]');
      if (dot) dot.classList.toggle("on", x.peers.some(function (p) { return state(p).cls === "ok"; }));
    });
  }
  function render() {
    renderHeader();
    var next = shapeOf();
    if (next === shape && $("sum-on")) { updateLive(); return; }
    shape = next;
    renderTabs();
    renderPanel();
  }
  function selectNet(iface, focus) {
    cur = iface;
    confirming = null;
    try { localStorage.setItem("wg-panel-net", iface); } catch (e) {}
    if (!st) return;
    render();
    if (focus && $("tab-" + iface)) $("tab-" + iface).focus();
  }

  function confirmEnabled() {
    [["reset-confirm", "reset-run"], ["drop-confirm", "drop-run"]].forEach(function (pair) {
      if (!$(pair[0])) return;
      $(pair[1]).disabled = busy || ($(pair[0]).value || "").trim().toLocaleLowerCase("tr-TR") !== CONFIRM_WORD;
    });
  }

  var toastTimer;
  function toast(msg, bad) {
    var t = $("toast");
    t.textContent = msg;
    t.classList.toggle("bad", !!bad);
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, bad ? 7000 : 4200);
  }
  function openDlg(d) { if (d.showModal) d.showModal(); else d.setAttribute("open", ""); }
  function closeDlg(d) { if (d.close) d.close(); else d.removeAttribute("open"); }
  each("dialog", function (d) {
    d.addEventListener("click", function (e) {
      if (e.target === d || e.target.closest("[data-close]")) closeDlg(d);
    });
  });
  function withBusy(button, label, promise) {
    var old = button.textContent;
    busy = true; button.disabled = true; button.textContent = label;
    return promise.finally(function () {
      busy = false; button.disabled = false; button.textContent = old;
    });
  }

  /* ---------- Tabs and add menu ---------- */
  $("tabs").addEventListener("click", function (e) {
    var t = e.target.closest('[role="tab"]');
    if (t) selectNet(t.getAttribute("data-tab"), false);
  });
  $("tabs").addEventListener("keydown", function (e) {
    if (!e.target.matches('[role="tab"]')) return;
    var list = nets().map(function (n) { return n.iface; }), i = list.indexOf(cur);
    var to = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: list.length - 1 }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    selectNet(list[(to + list.length) % list.length], true);
  });
  function setMenu(open) {
    $("add-menu").hidden = !open;
    $("add-menu-btn").setAttribute("aria-expanded", String(open));
    if (open) $("menu-peer").focus();
  }
  $("add-menu-btn").addEventListener("click", function (e) { e.stopPropagation(); setMenu($("add-menu").hidden); });
  $("add-menu").addEventListener("keydown", function (e) {
    var items = [$("menu-peer"), $("menu-net")].filter(function (b) { return !b.disabled; });
    var i = items.indexOf(document.activeElement);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); items[(i + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length].focus(); }
    if (e.key === "Escape") { setMenu(false); $("add-menu-btn").focus(); }
  });
  document.addEventListener("click", function (e) { if (!e.target.closest(".split")) setMenu(false); });
  $("menu-peer").addEventListener("click", function () { setMenu(false); openAdd(); });
  $("menu-net").addEventListener("click", function () { setMenu(false); openNet(); });
  $("open-add").addEventListener("click", openAdd);

  /* ---------- DNS presets ---------- */
  function presetsFor(current, preferred) {
    var list = [{ dns: st.defaults.dns, tag: "Önerilen" }];
    if (preferred && preferred !== st.defaults.dns) list.unshift({ dns: preferred, tag: "Ağın varsayılanı" });
    EXTRA_PRESETS.forEach(function (d) { if (!list.some(function (x) { return x.dns === d; })) list.push({ dns: d, tag: "" }); });
    nets().forEach(function (n) {
      n.peers.forEach(function (p) {
        if (p.dns && !list.some(function (x) { return x.dns === p.dns; })) list.push({ dns: p.dns, tag: "Bu sunucuda" });
      });
    });
    if (current && !list.some(function (x) { return x.dns === current; })) list.push({ dns: current, tag: "Şu anki" });
    return list;
  }
  function presetList(container, group, selectedDns, customInput, preferred) {
    var html = "";
    presetsFor(selectedDns, preferred).forEach(function (p, i) {
      html += '<div class="preset"><input type="radio" name="' + group + '" id="' + group + '-' + i + '" value="' + esc(p.dns) + '"' + (p.dns === selectedDns ? " checked" : "") + '>' +
        '<label for="' + group + '-' + i + '"><span class="pn">' + esc(provider(p.dns)) + '</span><span class="pt">' + esc(p.tag) + '</span>' +
        '<span class="pv">' + esc(p.dns) + '</span></label></div>';
    });
    html += '<div class="preset"><input type="radio" name="' + group + '" id="' + group + '-custom" value=""><label for="' + group + '-custom"><span class="pn">Özel</span><span class="pt"></span><span class="pv">Virgülle ayrılmış IP adresleri</span></label></div>';
    container.innerHTML = html;
    if (!container.querySelector("input:checked")) container.querySelector("input").checked = true;
    customInput.hidden = true;
    customInput.value = "";
    container.onchange = function () {
      var v = container.querySelector("input:checked").value;
      customInput.hidden = v !== "";
      if (v === "") customInput.focus();
    };
  }
  function chosenDns(container, customInput) {
    var v = container.querySelector("input:checked").value;
    return v === "" ? normDns(customInput.value) : v;
  }

  /* ---------- Add peer ---------- */
  function nextHost(n) {
    var used = {};
    n.peers.forEach(function (p) { used[parseInt(p.ipv4.split(".").pop(), 10)] = true; });
    for (var h = 2; h < 255; h++) if (!used[h]) return h;
    return 0;
  }
  function nameHelp(msg, bad) {
    var h = $("add-name-help");
    h.className = bad ? "err" : "";
    h.textContent = msg || "Harf, rakam ve . _ - ; en çok 32 karakter. Ad bu ağda benzersiz olmalı.";
  }
  var addNet = null;
  function openAdd() {
    if (!st) return;
    var n = net(), h = nextHost(n);
    addNet = n.iface;
    $("add-form").reset();
    nameHelp();
    $("add-title").textContent = dative(n.iface) + " peer ekle" + (n.label ? " · " + n.label : "");
    $("add-ka").value = st.defaults.keepalive;
    $("add-mtu").value = st.defaults.mtu;
    presetList($("add-presets"), "add-dns", n.dns || st.defaults.dns, $("add-custom"), n.dns);
    $("add-assign").innerHTML = h
      ? 'Atanacak adres <span class="mono">' + esc(n.server4.replace(/\.\d+$/, "." + h)) + '</span><span class="mono">' +
        esc(n.server6.replace(/[0-9a-fA-F]*$/, h.toString(16))) + '</span><span>uç nokta <span class="mono">:' + n.port + '</span></span>'
      : "Bu ağın adres havuzu dolu (253 peer).";
    openDlg($("add-dialog"));
    setTimeout(function () { $("add-name").focus(); }, 30);
  }
  $("add-form").addEventListener("submit", function (e) {
    e.preventDefault();
    if (busy) return;
    var n = nets().filter(function (x) { return x.iface === addNet; })[0], name = $("add-name").value.trim();
    if (!n) return;
    if (!NAME_RE.test(name)) { nameHelp("Ad harf ya da rakamla başlamalı; yalnız harf, rakam, . _ - (en çok 32).", true); $("add-name").focus(); return; }
    if (n.peers.some(function (p) { return p.name === name; })) { nameHelp("'" + name + "' adında bir peer " + n.iface + " içinde zaten var.", true); $("add-name").focus(); return; }
    var dns = chosenDns($("add-presets"), $("add-custom"));
    if (!dns) { toast("DNS virgülle ayrılmış IP adresleri olmalı.", true); $("add-custom").focus(); return; }
    var body = { name: name, dns: dns, keepalive: $("add-ka").value, mtu: $("add-mtu").value };
    withBusy($("add-submit"), "Oluşturuluyor…", api("/api/nets/" + encodeURIComponent(n.iface) + "/peers", { method: "POST", body: body }))
      .then(function (r) {
        closeDlg($("add-dialog"));
        return refresh().then(function () {
          openQR(n.iface, name, name + " " + dative(n.iface) + " eklendi · " + r.ipv4 + " · bağlantılar kopmadan uygulandı");
        });
      })
      .catch(function (err) { nameHelp(err.message, true); });
  });

  /* ---------- Add network ---------- */
  function nextNet() {
    var used = {};
    nets().forEach(function (n) { used[n.iface] = true; });
    for (var i = 1; i < st.max; i++) if (!used["wg" + i]) return i;
    return 0;
  }
  function usedPorts() {
    return st.reserved.concat(nets().map(function (n) { return n.port; }));
  }
  function portHelp(msg, bad) {
    var h = $("net-port-help");
    h.className = bad ? "err" : "";
    h.textContent = msg || "Sunucunun internete açtığı port; cihaz profillerinde uç nokta olarak yazılır.";
  }
  function openNet() {
    if (!st) return;
    var id = nextNet();
    if (!id) { toast("En çok " + st.max + " arayüz (wg0–wg" + (st.max - 1) + ") olabilir.", true); return; }
    var wg0 = nets()[0], port = 61001 + id * 10;
    while (usedPorts().indexOf(port) >= 0) port += 10;
    $("net-form").reset();
    portHelp();
    $("net-err").hidden = true;
    $("net-port").value = port;
    $("net-ifname").innerHTML = "wg" + id + "<small>sıradaki boş arayüz</small>";
    $("net-assign").innerHTML = 'Alt ağ <span class="mono">' + esc(wg0.server4.replace(/\.\d+\.\d+$/, "." + id + ".0/24")) + '</span>' +
      '<span>IPv6 <span class="mono">' + esc(wg0.server6.replace(/[0-9a-fA-F]*$/, "") + id + ":0/112") + '</span></span>' +
      '<span>Sunucu <span class="mono">' + esc(wg0.server4.replace(/\.\d+\.\d+$/, "." + id + ".1")) + '</span></span>';
    presetList($("net-presets"), "net-dns", st.defaults.dns, $("net-custom"));
    openDlg($("net-dialog"));
    setTimeout(function () { $("net-label").focus(); }, 30);
  }
  $("net-form").addEventListener("submit", function (e) {
    e.preventDefault();
    if (busy) return;
    var port = parseInt($("net-port").value, 10);
    if (!(port >= 1024 && port <= 65535)) { portHelp("Port 1024–65535 arası olmalı.", true); $("net-port").focus(); return; }
    if (usedPorts().indexOf(port) >= 0) { portHelp("UDP " + port + " sunucuda kullanılıyor; başka bir port seçin.", true); $("net-port").focus(); return; }
    var dns = chosenDns($("net-presets"), $("net-custom"));
    if (!dns) { $("net-err").hidden = false; $("net-err").textContent = "Varsayılan DNS virgülle ayrılmış IP adresleri olmalı."; return; }
    var body = {
      port: String(port), dns: dns, label: $("net-label").value.trim(),
      scope: document.querySelector('input[name="net-scope"]:checked').value
    };
    withBusy($("net-submit"), "Oluşturuluyor…", api("/api/nets", { method: "POST", body: body }))
      .then(function (r) {
        closeDlg($("net-dialog"));
        cur = r.iface;
        try { localStorage.setItem("wg-panel-net", cur); } catch (err) {}
        return refresh().then(function () {
          toast(r.iface + " oluşturuldu · UDP " + r.port + " açıldı · ilk cihazı ekleyin.");
          if ($("tab-" + r.iface)) $("tab-" + r.iface).focus();
        });
      })
      .catch(function (err) { $("net-err").hidden = false; $("net-err").textContent = err.message; });
  });

  /* ---------- QR ---------- */
  var qrTimer = null, qrLeft = 60, qrTarget = null, qrUrl = null;
  function veil() {
    clearInterval(qrTimer); qrTimer = null;
    $("qr-plate").classList.add("veiled");
    $("qr-timer").textContent = "60";
    var img = $("qr-img");
    img.hidden = true;
    img.removeAttribute("src");
    if (qrUrl) { URL.revokeObjectURL(qrUrl); qrUrl = null; }
  }
  function openQR(iface, name, sub) {
    var n = nets().filter(function (x) { return x.iface === iface; })[0];
    if (!n) return;
    var p = n.peers.filter(function (x) { return x.name === name; })[0];
    qrTarget = { net: n, name: name };
    veil();
    $("qr-title").textContent = name + " profili";
    $("qr-sub").textContent = sub || (iface + (p ? " · " + p.ipv4 + " · DNS " + (p.provider || provider(p.dns)) : ""));
    $("qr-profile").textContent = "Yükleniyor…";
    openDlg($("qr-dialog"));
    var target = qrTarget;
    api(peerPath(n, name, "/profile?masked=1"), { raw: true })
      .then(function (res) { return res.text(); })
      .then(function (t) { if (qrTarget === target) $("qr-profile").textContent = t; })
      .catch(function (err) { $("qr-profile").textContent = err.message; });
  }
  $("qr-reveal").addEventListener("click", function () {
    var target = qrTarget;
    if (!target) return;
    api(peerPath(target.net, target.name, "/qr.png"), { raw: true })
      .then(function (res) { return res.blob(); })
      .then(function (blob) {
        if (qrTarget !== target || !$("qr-dialog").open) return;
        qrUrl = URL.createObjectURL(blob);
        var img = $("qr-img");
        img.src = qrUrl;
        img.hidden = false;
        $("qr-plate").classList.remove("veiled");
        qrLeft = 60; $("qr-timer").textContent = qrLeft;
        clearInterval(qrTimer);
        qrTimer = setInterval(function () {
          qrLeft -= 1; $("qr-timer").textContent = qrLeft;
          if (qrLeft <= 0) veil();
        }, 1000);
      })
      .catch(function (err) { toast(err.message, true); });
  });
  $("qr-dialog").addEventListener("close", veil);
  function download(kind) {
    var target = qrTarget;
    if (!target) return;
    api(peerPath(target.net, target.name, kind === "png" ? "/qr.png" : "/profile"), { raw: true })
      .then(function (res) { return res.blob(); })
      .then(function (blob) {
        var url = URL.createObjectURL(blob), a = document.createElement("a");
        a.href = url; a.download = target.name + (kind === "png" ? ".png" : ".conf");
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
      })
      .catch(function (err) { toast(err.message, true); });
  }
  $("dl-conf").addEventListener("click", function () { download("conf"); });
  $("dl-png").addEventListener("click", function () { download("png"); });

  /* ---------- DNS ---------- */
  var dnsTarget = null;
  function openDns(name) {
    var n = net(), p = n.peers.filter(function (x) { return x.name === name; })[0];
    if (!p) return;
    dnsTarget = { net: n, name: name, dns: p.dns };
    $("dns-title").textContent = name + " · DNS değiştir";
    $("dns-err").hidden = true;
    presetList($("dns-presets"), "dns-choice", p.dns, $("dns-custom"), n.dns);
    openDlg($("dns-dialog"));
  }
  $("dns-form").addEventListener("submit", function (e) {
    e.preventDefault();
    if (busy || !dnsTarget) return;
    var dns = chosenDns($("dns-presets"), $("dns-custom")), target = dnsTarget;
    if (!dns) {
      $("dns-err").hidden = false;
      $("dns-err").textContent = "DNS virgülle ayrılmış IP adresleri olmalı (ör. 9.9.9.9, 149.112.112.112).";
      return;
    }
    if (dns === target.dns) { closeDlg($("dns-dialog")); toast("DNS aynı; değişiklik yok."); return; }
    withBusy($("dns-submit"), "Kaydediliyor…", api(peerPath(target.net, target.name, "/dns"), { method: "POST", body: { dns: dns } }))
      .then(function () {
        closeDlg($("dns-dialog"));
        return refresh().then(function () {
          openQR(target.net.iface, target.name, "DNS değişti → " + dns + " · yeni QR'ı cihazda okutun, eski tüneli silin");
        });
      })
      .catch(function (err) { $("dns-err").hidden = false; $("dns-err").textContent = err.message; });
  });

  /* ---------- Row actions, reset and remove ---------- */
  document.addEventListener("click", function (e) {
    var b = e.target.closest("[data-act]");
    if (!b || busy) return;
    var act = b.getAttribute("data-act"), name = b.getAttribute("data-name"), n = net();
    if (act === "add") openAdd();
    else if (act === "add-net") openNet();
    else if (act === "qr") openQR(n.iface, name);
    else if (act === "dns") openDns(name);
    else if (act === "remove") { confirming = name; render(); }
    else if (act === "remove-no") { confirming = null; render(); }
    else if (act === "remove-yes") {
      withBusy(b, "Çıkarılıyor…", api(peerPath(n, name, "/remove"), { method: "POST", body: {} }))
        .then(function () { confirming = null; toast(name + " " + n.iface + " içinden çıkarıldı; profili silindi."); return refresh(); })
        .catch(function (err) { confirming = null; toast(err.message, true); render(); });
    }
  });
  $("panel").addEventListener("input", function (e) {
    if (e.target.id === "reset-confirm" || e.target.id === "drop-confirm") confirmEnabled();
  });
  $("panel").addEventListener("click", function (e) {
    var id = e.target.id, n = net();
    if ((id !== "reset-run" && id !== "drop-run") || e.target.disabled || busy) return;
    var input = $(id === "reset-run" ? "reset-confirm" : "drop-confirm");
    var word = input.value.trim().toLocaleLowerCase("tr-TR");
    var path = "/api/nets/" + encodeURIComponent(n.iface) + (id === "reset-run" ? "/reset" : "/remove");
    withBusy(e.target, id === "reset-run" ? "Üretiliyor…" : "Kaldırılıyor…", api(path, { method: "POST", body: { confirm: word } }))
      .then(function (r) {
        input.value = "";
        if (id === "reset-run") {
          toast(n.iface + " yeniden üretildi: " + r.peers + " peer ve " + r.profiles + " profil silindi; yeni sunucu anahtarı etkin.");
        } else {
          toast(n.iface + " kaldırıldı (" + r.peers + " peer); UDP " + n.port + " kapandı.");
          selectNet("wg0", false);
        }
        return refresh();
      })
      .catch(function (err) { toast(err.message, true); });
  });

  /* DD-139: dosya paneline geçiş; yalnız Caddy adıyla (wg.<alan>) açılınca görünür. */
  if (location.hostname.indexOf("wg.") === 0) {
    $("app-files").href = location.protocol + "//dosya." + location.hostname.slice(3) + (location.port ? ":" + location.port : "") + "/";
    $("apps").hidden = false;
  }

  /* ---------- Live ---------- */
  setInterval(function () { if (st && net()) updateLive(); }, 1000);
  setInterval(function () {
    var dialogOpen = Array.prototype.some.call(document.querySelectorAll("dialog"), function (d) { return d.open; });
    if (document.visibilityState === "visible" && !busy && !dialogOpen && confirming === null) refresh();
  }, 10000);
  refresh();
})();
