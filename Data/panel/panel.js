/* WireGuard paneli (DD-133). Bütün değişiklikler sunucuda master-wg ile yapılır. */
(function () {
  "use strict";
  var GiB = 1073741824, MiB = 1048576;
  var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/;
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

  var st = null, offset = 0, confirming = null, busy = false, shape = "";
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
  function state(p) {
    if (!p.handshake) return { cls: "never", label: "Görülmedi" };
    var a = now() - p.handshake;
    if (a < 180) return { cls: "ok", label: "Bağlı" };
    if (a < 86400) return { cls: "idle", label: "Boşta" };
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
  function iface() { return st ? st.interface : "wg0"; }
  // Satır yalnız adresler arasında bölünür, bir adresin ortasında değil.
  function ipList(dns) {
    return dns.split(",").map(function (t) { return t.trim(); }).filter(Boolean)
      .map(function (t) { return '<span class="ip">' + esc(t) + '</span>'; }).join(", ");
  }
  var CONFIRM_WORD = "onayla";
  function dative(name) {
    var d = name.slice(-1);
    var map = { "0": "'a", "1": "'e", "2": "'ye", "3": "'e", "4": "'e", "5": "'e", "6": "'ya", "7": "'ye", "8": "'e", "9": "'a" };
    return name + (map[d] || "'e");
  }
  function accusative(name) {
    var d = name.slice(-1);
    var map = { "0": "'ı", "1": "'i", "2": "'yi", "3": "'ü", "4": "'ü", "5": "'i", "6": "'yı", "7": "'yi", "8": "'i", "9": "'u" };
    return name + (map[d] || "'i");
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
      render();
    }).catch(function (e) { toast(e.message, true); });
  }

  /* ---------- Rendering ---------- */
  function renderHeader() {
    $("host").textContent = st.host || "sunucu";
    document.title = (st.host || "sunucu") + " · WireGuard paneli";
    var chip = $("chip-active");
    chip.className = "chip " + (st.active === false ? "down" : "live");
    $("chip-active-text").textContent = st.active === false ? iface() + " durdu" : "Çalışıyor";
    $("chip-endpoint").textContent = st.endpoint + ":" + st.port;
    $("chip-version").textContent = (st.version || "").replace(/^.*-(v2-\d+)$/, "$1");
    var b = st.backup, pill = $("backup-pill");
    pill.classList.toggle("stale", !b.fresh);
    $("backup-text").textContent = b.fresh ? "Mac yedeği güncel" : (b.at ? "Mac yedeği eski · 6) Yedek al" : "Mac yedeği alınmadı · 6) Yedek al");
    $("backup-detail").textContent = b.at ? " Son yedek: " + new Date(b.at * 1000).toLocaleString("tr-TR") + "." : "";
    $("open-add").disabled = false;
    $("open-add-text").textContent = dative(iface()) + " peer ekle";
  }

  function renderTabs() {
    var on = st.peers.some(function (p) { return state(p).cls === "ok"; });
    $("tabs").innerHTML = '<button class="tab" role="tab" type="button" id="tab-0" aria-controls="panel" aria-selected="true">' +
      '<span class="tdot' + (on ? " on" : "") + '" aria-hidden="true"></span><span class="tif">' + esc(iface()) + '</span>' +
      '<span class="tcount">' + st.peers.length + '</span></button>';
    $("panel").setAttribute("aria-labelledby", "tab-0");
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
    var on = 0, rx = 0, tx = 0, name = iface();
    st.peers.forEach(function (p) { if (state(p).cls === "ok") on++; rx += p.rx; tx += p.tx; });
    var list = st.peers.length
      ? '<div class="row head" aria-hidden="true"><div>Durum</div><div>Cihaz</div><div>Adres</div><div>DNS</div><div>Son el sıkışma</div><div class="c-traffic">Trafik</div><div></div></div>' +
        st.peers.map(rowHtml).join("")
      : '<div class="empty"><strong>' + esc(name) + ' hazır, kayıtlı peer yok</strong><span>İlk cihazı ekleyin; QR hemen görünür.</span>' +
        '<button class="btn btn-primary" type="button" data-act="add">' + esc(dative(name)) + ' peer ekle</button></div>';
    var focused = document.activeElement && document.activeElement.id === "reset-confirm";
    var typed = $("reset-confirm") ? $("reset-confirm").value : "";
    $("panel").innerHTML =
      '<div class="net-head"><div class="net-title"><span class="big">' + esc(name) + '</span>' +
      '<div class="chips"><span class="chip">Sunucu <span class="mono">' + esc(st.server4) + '/24</span></span>' +
      '<span class="chip">UDP <span class="mono">' + st.port + '</span></span>' +
      '<span class="chip">IPv6 <span class="mono">' + esc(st.subnet6) + '</span></span>' +
      '<span class="chip">İnternet + arayüzler</span></div></div></div>' +
      '<dl class="summary"><div><dt>Peer</dt><dd class="num">' + st.peers.length + '<small>/ 253 adres</small></dd></div>' +
      '<div><dt>Şu an bağlı</dt><dd class="num"><span id="sum-on">' + on + '</span><small>son 3 dk</small></dd></div>' +
      '<div><dt>Gelen</dt><dd class="num" id="sum-rx">' + bytes(rx) + '</dd></div>' +
      '<div><dt>Giden</dt><dd class="num" id="sum-tx">' + bytes(tx) + '</dd></div></dl>' +
      '<div class="list"><div class="section-head"><h2>' + esc(name) + ' peer\'ları</h2><p class="hint">Durum son el sıkışmaya göre: 3 dakikadan yeni ise bağlı. Liste 10 sn\'de bir yenilenir.</p></div>' +
      '<div class="peers">' + list + '</div></div>' +
      '<section class="danger" aria-labelledby="danger-title"><div><h2 id="danger-title">' + esc(accusative(name)) + ' yeniden üret</h2>' +
      '<p>Yeni sunucu anahtarı; bütün peer\'lar ve profiller silinir, cihazlar yeniden eklenir. Geri alınamaz.</p></div>' +
      '<div class="confirm-field"><label for="reset-confirm"><span class="mono">' + CONFIRM_WORD + '</span> yazın</label>' +
      '<input type="text" id="reset-confirm" autocomplete="off" spellcheck="false" maxlength="12" placeholder="' + CONFIRM_WORD + '">' +
      '<button class="btn btn-danger btn-sm" id="reset-run" type="button" disabled>Yeniden üret</button></div></section>' +
      '<div class="footnote"><span>Uç nokta <span class="mono">' + esc(st.endpoint) + ':' + st.port + '</span></span>' +
      '<span>Alt ağ <span class="mono">' + esc(st.subnet4) + '</span></span>' +
      '<span>Cihazlar arası trafik kapalı; panel yalnız Tailscale\'den açılır</span></div>';
    var rc = $("reset-confirm");
    rc.value = typed;
    resetEnabled();
    if (focused) rc.focus();
  }

  // Yapı (peer'lar, adresleri, DNS'leri, onay satırı) değişmediyse satırlar yeniden
  // çizilmez: yalnız durum, süre ve trafik yerinde güncellenir. Böylece 10 sn'lik
  // yenileme bir tıklamanın ortasında düğmeyi değiştirmez.
  function shapeOf() {
    return JSON.stringify([confirming, st.interface, st.port, st.server4, st.subnet4, st.subnet6, st.endpoint,
      st.peers.map(function (p) { return [p.name, p.ipv4, p.ipv6, p.dns, p.provider, p.profile]; })]);
  }
  function updateLive() {
    var on = 0, rx = 0, tx = 0;
    st.peers.forEach(function (p) {
      var s = state(p);
      if (s.cls === "ok") on++;
      rx += p.rx; tx += p.tx;
      Array.prototype.forEach.call(document.querySelectorAll('[data-status="' + CSS.escape(p.name) + '"]'), function (el) {
        el.className = "status " + s.cls;
        el.lastChild.textContent = s.label;
      });
      Array.prototype.forEach.call(document.querySelectorAll('[data-ago="' + CSS.escape(p.name) + '"]'), function (el) { el.textContent = ago(p); });
      Array.prototype.forEach.call(document.querySelectorAll('[data-rx="' + CSS.escape(p.name) + '"]'), function (el) { el.textContent = bytes(p.rx); });
      Array.prototype.forEach.call(document.querySelectorAll('[data-tx="' + CSS.escape(p.name) + '"]'), function (el) { el.textContent = bytes(p.tx); });
    });
    if ($("sum-on")) { $("sum-on").textContent = on; $("sum-rx").textContent = bytes(rx); $("sum-tx").textContent = bytes(tx); }
    var dot = document.querySelector("#tabs .tdot");
    if (dot) dot.classList.toggle("on", on > 0);
  }
  function render() {
    renderHeader();
    var next = shapeOf();
    if (next === shape && $("sum-on")) { updateLive(); return; }
    shape = next;
    renderTabs();
    renderPanel();
  }

  function resetEnabled() {
    var v = ($("reset-confirm").value || "").trim().toLocaleLowerCase("tr-TR");
    $("reset-run").disabled = busy || v !== CONFIRM_WORD;
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
  Array.prototype.forEach.call(document.querySelectorAll("dialog"), function (d) {
    d.addEventListener("click", function (e) {
      if (e.target === d || e.target.closest("[data-close]")) closeDlg(d);
    });
  });
  function withBusy(button, label, promise) {
    var old = button.textContent;
    busy = true; button.disabled = true; button.textContent = label;
    return promise.then(function (v) { return v; }, function (e) { throw e; }).finally(function () {
      busy = false; button.disabled = false; button.textContent = old;
    });
  }

  /* ---------- DNS presets ---------- */
  function presetsFor(current) {
    var list = [{ dns: st.defaults.dns, tag: "Önerilen" }];
    EXTRA_PRESETS.forEach(function (d) { list.push({ dns: d, tag: "" }); });
    st.peers.forEach(function (p) {
      if (p.dns && !list.some(function (x) { return x.dns === p.dns; })) list.push({ dns: p.dns, tag: "Bu sunucuda" });
    });
    if (current && !list.some(function (x) { return x.dns === current; })) list.push({ dns: current, tag: "Şu anki" });
    return list;
  }
  function presetList(container, group, selectedDns, customInput) {
    var list = presetsFor(selectedDns), html = "";
    list.forEach(function (p, i) {
      var checked = p.dns === selectedDns;
      html += '<div class="preset"><input type="radio" name="' + group + '" id="' + group + '-' + i + '" value="' + esc(p.dns) + '"' + (checked ? " checked" : "") + '>' +
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

  /* ---------- Add ---------- */
  function nextHost() {
    var used = {};
    st.peers.forEach(function (p) { used[parseInt(p.ipv4.split(".").pop(), 10)] = true; });
    for (var n = 2; n < 255; n++) if (!used[n]) return n;
    return 0;
  }
  function nameHelp(msg, bad) {
    var h = $("add-name-help");
    h.className = bad ? "err" : "";
    h.textContent = msg || "Harf, rakam ve . _ - ; en çok 32 karakter.";
  }
  function openAdd() {
    if (!st) return;
    var n = nextHost(), v4prefix = st.server4.replace(/\.\d+$/, "."), v6prefix = st.server6.replace(/[0-9a-fA-F]*$/, "");
    $("add-form").reset();
    nameHelp();
    $("add-title").textContent = dative(iface()) + " peer ekle";
    $("add-ka").value = st.defaults.keepalive;
    $("add-mtu").value = st.defaults.mtu;
    presetList($("add-presets"), "add-dns", st.defaults.dns, $("add-custom"));
    $("add-assign").innerHTML = n
      ? 'Atanacak adres <span class="mono">' + esc(v4prefix + n) + '</span><span class="mono">' + esc(v6prefix + n.toString(16)) + '</span>'
      : "Adres havuzu dolu (253 peer).";
    openDlg($("add-dialog"));
    setTimeout(function () { $("add-name").focus(); }, 30);
  }
  $("open-add").addEventListener("click", openAdd);
  $("add-form").addEventListener("submit", function (e) {
    e.preventDefault();
    if (busy) return;
    var name = $("add-name").value.trim();
    if (!NAME_RE.test(name)) { nameHelp("Ad harf ya da rakamla başlamalı; yalnız harf, rakam, . _ - (en çok 32).", true); $("add-name").focus(); return; }
    if (st.peers.some(function (p) { return p.name === name; })) { nameHelp("'" + name + "' adında bir peer zaten var.", true); $("add-name").focus(); return; }
    var dns = chosenDns($("add-presets"), $("add-custom"));
    if (!dns) { toast("DNS virgülle ayrılmış IP adresleri olmalı.", true); $("add-custom").focus(); return; }
    var body = { name: name, dns: dns, keepalive: $("add-ka").value, mtu: $("add-mtu").value };
    withBusy($("add-submit"), "Oluşturuluyor…", api("/api/peers", { method: "POST", body: body }))
      .then(function (r) {
        closeDlg($("add-dialog"));
        return refresh().then(function () {
          openQR(name, name + " eklendi · " + r.ipv4 + " · bağlantılar kopmadan uygulandı");
        });
      })
      .catch(function (err) { nameHelp(err.message, true); });
  });

  /* ---------- QR ---------- */
  var qrTimer = null, qrLeft = 60, qrName = null, qrUrl = null;
  function veil() {
    clearInterval(qrTimer); qrTimer = null;
    $("qr-plate").classList.add("veiled");
    $("qr-timer").textContent = "60";
    var img = $("qr-img");
    img.hidden = true;
    img.removeAttribute("src");
    if (qrUrl) { URL.revokeObjectURL(qrUrl); qrUrl = null; }
  }
  function openQR(name, sub) {
    var p = st.peers.filter(function (x) { return x.name === name; })[0];
    qrName = name;
    veil();
    $("qr-title").textContent = name + " profili";
    $("qr-sub").textContent = sub || (p ? p.ipv4 + " · DNS " + (p.provider || provider(p.dns)) : "");
    $("qr-profile").textContent = "Yükleniyor…";
    openDlg($("qr-dialog"));
    api("/api/peers/" + encodeURIComponent(name) + "/profile?masked=1", { raw: true })
      .then(function (res) { return res.text(); })
      .then(function (t) { if (qrName === name) $("qr-profile").textContent = t; })
      .catch(function (err) { $("qr-profile").textContent = err.message; });
  }
  $("qr-reveal").addEventListener("click", function () {
    var name = qrName;
    api("/api/peers/" + encodeURIComponent(name) + "/qr.png", { raw: true })
      .then(function (res) { return res.blob(); })
      .then(function (blob) {
        if (qrName !== name || !$("qr-dialog").open) return;
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
    var name = qrName, path = "/api/peers/" + encodeURIComponent(name) + (kind === "png" ? "/qr.png" : "/profile");
    api(path, { raw: true })
      .then(function (res) { return res.blob(); })
      .then(function (blob) {
        var url = URL.createObjectURL(blob), a = document.createElement("a");
        a.href = url; a.download = name + (kind === "png" ? ".png" : ".conf");
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
      })
      .catch(function (err) { toast(err.message, true); });
  }
  $("dl-conf").addEventListener("click", function () { download("conf"); });
  $("dl-png").addEventListener("click", function () { download("png"); });

  /* ---------- DNS ---------- */
  var dnsName = null;
  function openDns(name) {
    var p = st.peers.filter(function (x) { return x.name === name; })[0];
    if (!p) return;
    dnsName = name;
    $("dns-title").textContent = name + " · DNS değiştir";
    $("dns-err").hidden = true;
    presetList($("dns-presets"), "dns-choice", p.dns, $("dns-custom"));
    openDlg($("dns-dialog"));
  }
  $("dns-form").addEventListener("submit", function (e) {
    e.preventDefault();
    if (busy) return;
    var dns = chosenDns($("dns-presets"), $("dns-custom")), name = dnsName;
    var p = st.peers.filter(function (x) { return x.name === name; })[0];
    if (!dns) {
      $("dns-err").hidden = false;
      $("dns-err").textContent = "DNS virgülle ayrılmış IP adresleri olmalı (ör. 9.9.9.9, 149.112.112.112).";
      return;
    }
    if (p && dns === p.dns) { closeDlg($("dns-dialog")); toast("DNS aynı; değişiklik yok."); return; }
    withBusy($("dns-submit"), "Kaydediliyor…", api("/api/peers/" + encodeURIComponent(name) + "/dns", { method: "POST", body: { dns: dns } }))
      .then(function () {
        closeDlg($("dns-dialog"));
        return refresh().then(function () { openQR(name, "DNS değişti → " + dns + " · yeni QR'ı cihazda okutun, eski tüneli silin"); });
      })
      .catch(function (err) { $("dns-err").hidden = false; $("dns-err").textContent = err.message; });
  });

  /* ---------- Row actions and reset ---------- */
  document.addEventListener("click", function (e) {
    var b = e.target.closest("[data-act]");
    if (!b || busy) return;
    var act = b.getAttribute("data-act"), name = b.getAttribute("data-name");
    if (act === "add") openAdd();
    else if (act === "qr") openQR(name);
    else if (act === "dns") openDns(name);
    else if (act === "remove") { confirming = name; render(); }
    else if (act === "remove-no") { confirming = null; render(); }
    else if (act === "remove-yes") {
      withBusy(b, "Çıkarılıyor…", api("/api/peers/" + encodeURIComponent(name) + "/remove", { method: "POST", body: {} }))
        .then(function () { confirming = null; toast(name + " çıkarıldı; profili silindi."); return refresh(); })
        .catch(function (err) { confirming = null; toast(err.message, true); render(); });
    }
  });
  $("panel").addEventListener("input", function (e) { if (e.target.id === "reset-confirm") resetEnabled(); });
  $("panel").addEventListener("click", function (e) {
    if (e.target.id !== "reset-run" || e.target.disabled || busy) return;
    var confirmWord = $("reset-confirm").value.trim().toLocaleLowerCase("tr-TR");
    withBusy(e.target, "Üretiliyor…", api("/api/reset", { method: "POST", body: { confirm: confirmWord } }))
      .then(function (r) {
        confirming = null;
        $("reset-confirm").value = "";
        toast(iface() + " yeniden üretildi: " + r.peers + " peer ve " + r.profiles + " profil silindi; yeni sunucu anahtarı etkin.");
        return refresh();
      })
      .catch(function (err) { toast(err.message, true); });
  });

  /* ---------- Backup note ---------- */
  $("backup-pill").addEventListener("click", function () {
    var n = $("backup-note"), open = n.hidden;
    n.hidden = !open;
    this.setAttribute("aria-expanded", String(open));
  });

  /* ---------- Live ---------- */
  setInterval(function () { if (st) updateLive(); }, 1000);
  setInterval(function () {
    var dialogOpen = Array.prototype.some.call(document.querySelectorAll("dialog"), function (d) { return d.open; });
    if (document.visibilityState === "visible" && !busy && !dialogOpen && confirming === null) refresh();
  }, 10000);
  refresh();
})();
