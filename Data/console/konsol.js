/* Konsol (DD-140): WireGuard ve dosya arka uçlarının tek arayüzü.
   Değişiklikler sunucuda master-wg ve dosya paneli ile yapılır; bu dosya yalnız
   API'yi çağırır. Sayfa CSP altında çalışır: satır içi biçem ve betik yok. */
(() => {
  "use strict";
  const ICON = {
    gauge: '<path d="M2.8 12.6a6.4 6.4 0 1 1 12.4 0"/><path d="M9 11.2l3-3.6"/><circle cx="9" cy="11.6" r="1.1"/>',
    shield: '<path d="M9 2.2l5.6 2v4.4c0 3.4-2.4 5.9-5.6 7.2-3.2-1.3-5.6-3.8-5.6-7.2V4.2z"/>',
    folder: '<path d="M2.2 5.2c0-.9.7-1.6 1.6-1.6h3.1l1.7 1.9h5.6c.9 0 1.6.7 1.6 1.6v6.1c0 .9-.7 1.6-1.6 1.6H3.8c-.9 0-1.6-.7-1.6-1.6z"/>',
    stack: '<rect x="2.6" y="2.8" width="12.8" height="4.4" rx="1.2"/><rect x="2.6" y="10.8" width="12.8" height="4.4" rx="1.2"/><path d="M5.2 5h.1M5.2 13h.1"/>',
    list: '<path d="M6.6 4.6h8.4M6.6 9h8.4M6.6 13.4h8.4"/><circle cx="3.3" cy="4.6" r=".95" fill="currentColor" stroke="none"/><circle cx="3.3" cy="9" r=".95" fill="currentColor" stroke="none"/><circle cx="3.3" cy="13.4" r=".95" fill="currentColor" stroke="none"/>',
    terminal: '<rect x="2.2" y="3.2" width="13.6" height="11.6" rx="1.8"/><path d="M5.2 7l2.2 2-2.2 2M9.4 11.4h3.2"/>',
    download: '<path d="M9 2.8v8.4M5.6 7.9L9 11.3l3.4-3.4M3.2 14.6h11.6"/>',
    disk: '<ellipse cx="9" cy="4.6" rx="6" ry="2.2"/><path d="M3 4.6v8.8c0 1.2 2.7 2.2 6 2.2s6-1 6-2.2V4.6M3 9c0 1.2 2.7 2.2 6 2.2S15 10.2 15 9"/>',
    server: '<rect x="2.6" y="2.6" width="12.8" height="12.8" rx="2"/><path d="M5.6 6.2h6.8M5.6 9h6.8M5.6 11.8h3.6"/>',
    plus: '<path d="M9 3.5v11M3.5 9h11"/>',
    trash: '<path d="M3.2 5h11.6M7.2 5V3.4h3.6V5M4.6 5l.8 9.6h7.2l.8-9.6"/><path d="M7.6 8v4M10.4 8v4"/>',
    info: '<circle cx="9" cy="9" r="6.8"/><path d="M9 8.2v4.2M9 5.6v.1"/>',
    video: '<rect x="2.2" y="3.6" width="13.6" height="10.8" rx="1.8"/><path d="M7.4 6.7v4.6l3.9-2.3z"/>',
    text: '<path d="M4.6 2.4h5.8l3 3v10.2H4.6z"/><path d="M10.2 2.4v3.2h3.2M6.8 9h4.4M6.8 11.6h4.4"/>',
    file: '<path d="M4.6 2.4h5.8l3 3v10.2H4.6z"/><path d="M10.2 2.4v3.2h3.2"/>',
    qr: '<rect x="2.6" y="2.6" width="5" height="5" rx=".8"/><rect x="10.4" y="2.6" width="5" height="5" rx=".8"/><rect x="2.6" y="10.4" width="5" height="5" rx=".8"/><path d="M10.4 10.4h2v2M15.4 10.4v5h-5"/>',
    more: '<circle cx="4.2" cy="9" r="1" fill="currentColor" stroke="none"/><circle cx="9" cy="9" r="1" fill="currentColor" stroke="none"/><circle cx="13.8" cy="9" r="1" fill="currentColor" stroke="none"/>',
    lock: '<rect x="3.6" y="8" width="10.8" height="7.4" rx="1.6"/><path d="M6 8V5.8a3 3 0 0 1 6 0V8"/>',
    move: '<path d="M2.2 5.2c0-.9.7-1.6 1.6-1.6h3.1l1.7 1.9h5.6c.9 0 1.6.7 1.6 1.6v6.1c0 .9-.7 1.6-1.6 1.6H3.8c-.9 0-1.6-.7-1.6-1.6z"/><path d="M6.4 10.1h4.8M9.4 8.2l1.9 1.9-1.9 1.9"/>',
    refresh: '<path d="M14.4 9a5.4 5.4 0 1 1-1.6-3.9"/><path d="M14.6 2.6v3.2h-3.2"/>',
    back: '<path d="M11 4.5L6.5 9l4.5 4.5"/>',
    copy: '<rect x="6.2" y="6.2" width="8.8" height="8.8" rx="1.6"/><path d="M11.8 6.2V4.6c0-.9-.7-1.6-1.6-1.6H4.6C3.7 3 3 3.7 3 4.6v5.6c0 .9.7 1.6 1.6 1.6h1.6"/>',
    check: '<path d="M3.8 9.4l3.2 3.2 7.2-7.4"/>',
    globe: '<circle cx="9" cy="9" r="6.6"/><path d="M2.4 9h13.2M9 2.4c1.8 1.9 2.7 4.1 2.7 6.6S10.8 13.7 9 15.6C7.2 13.7 6.3 11.5 6.3 9S7.2 4.3 9 2.4z"/>',
    pencil: '<path d="M11.8 3.2l3 3-8.4 8.4H3.4v-3z"/><path d="M10.2 4.8l3 3"/>',
    up: '<path d="M9 14.4V3.8M4.8 8L9 3.8 13.2 8"/>',
    home: '<path d="M2.8 8.6L9 3.2l6.2 5.4"/><path d="M4.6 7.2v7.4h8.8V7.2"/>',
    restore: '<path d="M3.6 8.8a5.4 5.4 0 1 0 1.6-3.9"/><path d="M3.4 2.6v3.2h3.2"/>',
    share: '<circle cx="4.8" cy="9" r="2"/><circle cx="13.2" cy="4.6" r="2"/><circle cx="13.2" cy="13.4" r="2"/><path d="M6.6 8.1l4.8-2.6M6.6 9.9l4.8 2.6"/>',
    eye: '<path d="M1.8 9S4.4 4.2 9 4.2 16.2 9 16.2 9 13.6 13.8 9 13.8 1.8 9 1.8 9z"/><circle cx="9" cy="9" r="2.2"/>',
    upload: '<path d="M9 11.6V3.2M5.6 6.6L9 3.2l3.4 3.4M3.2 14.6h11.6"/>',
    box: '<path d="M2.8 5.4L9 2.4l6.2 3v7.2L9 15.6l-6.2-3z"/><path d="M2.8 5.4L9 8.4l6.2-3M9 8.4v7.2"/>',
    play: '<path d="M5.6 3.6v10.8L14.2 9z"/>',
    pause: '<path d="M6 3.8v10.4M12 3.8v10.4"/>',
    search: '<circle cx="8" cy="8" r="4.8"/><path d="M11.6 11.6L15.4 15.4"/>',
    close: '<path d="M4.8 4.8l8.4 8.4M13.2 4.8l-8.4 8.4"/>',
    key: '<circle cx="5.8" cy="12" r="3.2"/><path d="M8.1 9.7l6.5-6.5M12.4 5.4l1.9 1.9M10.6 7.2l1.5 1.5"/>',
    restart: '<path d="M3.6 8.8a5.4 5.4 0 1 0 1.6-3.9"/><path d="M3.4 2.6v3.2h3.2"/>',
    sliders: '<path d="M3 5h7M13.5 5H15M3 13h2.5M9 13h6"/><circle cx="11.8" cy="5" r="1.8"/><circle cx="7.2" cy="13" r="1.8"/>',
    route: '<circle cx="4.4" cy="13.6" r="1.8"/><circle cx="13.6" cy="4.4" r="1.8"/><path d="M6.2 13.6h4.2a2.6 2.6 0 0 0 0-5.2H7.6a2.6 2.6 0 0 1 0-5.2h4.2"/>',
    chev: '<path d="M7 4.5L11.5 9 7 13.5"/>',
    arrow: '<path d="M3.4 9h11.2M10.6 5l4 4-4 4"/>',
  };
  const svg = (name) => {
    const t = document.createElement("template");
    t.innerHTML = '<svg viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICON[name] || ICON.file) + "</svg>";
    return t.content.firstChild;
  };
  const $ = (id) => document.getElementById(id);
  function h(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k === "style") { Object.assign(e.style, v); continue; }  // CSP: biçem özniteliği değil, CSSOM
      if (k.startsWith("aria-")) { e.setAttribute(k, String(v)); continue; }
      if (v == null || v === false) continue;
      if (k === "class") e.className = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v === true ? "" : v);
    }
    for (const c of kids.flat()) {
      if (c == null || c === false) continue;
      e.append(c.nodeType ? c : document.createTextNode(String(c)));
    }
    return e;
  }
  document.querySelectorAll("[data-icon]").forEach((el) => el.prepend(svg(el.dataset.icon)));

  let toastTimer;
  function toast(msg, action) {
    const t = $("toast");
    t.textContent = "";
    t.append(document.createTextNode(msg));
    if (action) t.append(h("button", { type: "button", class: "toast-act", onclick: () => { t.hidden = true; action.fn(); } }, action.label));
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, action ? 6500 : 4200);
  }
  const fail = (err) => toast(err && err.message ? err.message : String(err));

  /* ---------- API ---------- */
  function api(path, opts) {
    opts = opts || {};
    const headers = { "X-Konsol": "1" };
    const init = { method: opts.method || "GET", headers, credentials: "same-origin", cache: "no-store" };
    if (opts.body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.body);
    }
    return fetch(path, init).then((res) => {
      if (opts.blob) {
        if (!res.ok) return res.json().catch(() => ({})).then((j) => { throw new Error(j.error || `HTTP ${res.status}`); });
        return res.blob();
      }
      return res.json().catch(() => ({})).then((j) => {
        if (!res.ok) throw new Error(j.error || `HTTP ${res.status}`);
        return j;
      });
    });
  }
  const post = (path, body) => api(path, { method: "POST", body: body || {} });
  const enc = encodeURIComponent;
  const netPath = (iface, tail) => `/api/wg/nets/${enc(iface)}${tail || ""}`;
  const peerPath = (iface, name, tail) => `${netPath(iface)}/peers/${enc(name)}${tail || ""}`;

  /* ---------- biçimleme ---------- */
  const GiB = 1073741824, MiB = 1048576, KiB = 1024;
  const dec = (v, d) => v.toFixed(d).replace(".", ",");
  function bytes(b) {
    if (b == null) return "—";
    if (!b) return "0 B";
    if (b >= 1099511627776) return dec(b / 1099511627776, 2) + " TB";
    if (b >= GiB) return dec(b / GiB, 1) + " GB";
    if (b >= MiB) return Math.round(b / MiB) + " MB";
    return Math.max(1, Math.round(b / KiB)) + " KB";
  }
  const rate = (bps) => (bps >= MiB ? `${dec(bps / MiB, 1)} MB/sn` : `${Math.max(0, Math.round(bps / KiB))} KB/sn`);
  function since(seconds) {
    if (!seconds) return "hiç";
    const a = Math.max(0, Math.floor(now() - seconds));
    if (a < 90) return "şimdi";
    if (a < 7200) return `${Math.floor(a / 60)} dk önce`;
    if (a < 172800) return `${Math.floor(a / 3600)} sa önce`;
    return `${Math.floor(a / 86400)} gün önce`;
  }
  function duration(seconds) {
    const d = Math.floor(seconds / 86400), hh = Math.floor((seconds % 86400) / 3600), mm = Math.floor((seconds % 3600) / 60);
    if (d) return `${d} gün ${hh} sa açık`;
    if (hh) return `${hh} sa ${mm} dk açık`;
    return `${mm} dk açık`;
  }
  const DURATIONS = [[1, "1 gün"], [7, "7 gün"], [30, "30 gün"], [0, "Süresiz"]];
  const dayText = (at) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", year: "numeric" }).format(new Date(at * 1000));
  const shortDay = (at) => new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short" }).format(new Date(at * 1000));
  function leftText(expires) {
    if (!expires) return "süresiz";
    const days = Math.ceil((expires - now()) / 86400);
    return days <= 1 ? "bugün biter" : `${days} gün kaldı`;
  }
  const clock = (at) => new Date(at * 1000).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
  function stamp(at) {
    const d = new Date(at * 1000), today = new Date();
    if (d.toDateString() === today.toDateString()) return clock(at);
    today.setDate(today.getDate() - 1);
    if (d.toDateString() === today.toDateString()) return "Dün";
    return d.toLocaleDateString("tr-TR", { day: "numeric", month: "short" });
  }
  function normDns(v) {
    const parts = v.split(",").map((t) => t.replace(/\s+/g, "")).filter(Boolean);
    if (!parts.length) return null;
    for (const t of parts) {
      if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(t) && !/^[0-9a-f]*:[0-9a-f:]*$/i.test(t)) return null;
    }
    return parts.join(", ");
  }
  const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/;
  const kaText = (ka) => (ka ? `${ka} sn` : "kapalı");
  const dative = (name) => name + ({ 0: "'a", 1: "'e", 2: "'ye", 3: "'e", 4: "'e", 5: "'e", 6: "'ya", 7: "'ye", 8: "'e", 9: "'a" }[name.slice(-1)] || "'e");

  /* ---------- durum ---------- */
  const S = { wg: null, sys: null, fs: null, trash: null, actions: [], share: null, offset: 0, rates: new Map() };
  const now = () => Date.now() / 1000 + S.offset;
  const nets = () => (S.wg ? S.wg.networks : []);
  const netOf = (iface) => nets().find((n) => n.iface === iface);
  const allPeers = () => nets().flatMap((n) => n.peers.map((p) => Object.assign({ net: n }, p)));
  const DNS_PRESETS = [
    { name: "Cloudflare", tag: "Hızlı; kurulumun varsayılanı", ips: "1.1.1.1, 1.0.0.1, 2606:4700:4700::1001" },
    { name: "Cloudflare Aile", tag: "Zararlı ve yetişkin içerik engelli", ips: "1.1.1.3, 1.0.0.3, 2606:4700:4700::1113" },
    { name: "Quad9", tag: "Zararlı site engelli", ips: "9.9.9.9, 149.112.112.112, 2620:fe::fe" },
    { name: "AdGuard", tag: "Reklam ve izleyici engelli", ips: "94.140.14.14, 94.140.15.15, 2a10:50c0::ad1:ff" },
    { name: "Google", tag: "", ips: "8.8.8.8, 8.8.4.4, 2001:4860:4860::8888" },
  ];
  const providerOf = (ips, fallback) => (DNS_PRESETS.find((d) => d.ips === ips) || { name: fallback || "Özel" }).name;
  const STLABEL = { ok: "Bağlı", idle: "Boşta", never: "Görülmedi", off: "Kapalı", netoff: "Ağ kapalı" };
  const ORDER = ["ok", "idle", "never", "off", "netoff"];
  function effState(p) {
    if (!p.net.active) return "netoff";
    if (!p.enabled) return "off";
    if (p.online) return "ok";
    if (p.handshake && now() - p.handshake < 86400) return "idle";
    return "never";
  }
  const stClass = (st) => (st === "off" || st === "netoff" ? "off" : st);
  const scopeText = (n) => (n.scope === "ui" ? "İnternet + local" : "Yalnız internet");
  const labelOf = (n) => n.label || (n.iface === "wg0" ? "Ana ağ" : "Etiketsiz");

  /* aktarım hızı: iki örnek arasındaki fark */
  function trackRates(state) {
    const at = state.now;
    state.networks.forEach((n) => n.peers.forEach((p) => {
      const key = `${n.iface}/${p.name}`, prev = S.rates.get(key);
      let down = 0, up = 0;
      if (prev && at > prev.at && p.rx >= prev.rx) {
        down = (p.rx - prev.rx) / (at - prev.at);
        up = (p.tx - prev.tx) / (at - prev.at);
      }
      S.rates.set(key, { at, rx: p.rx, tx: p.tx, down, up });
      p.down = down;
      p.up = up;
    }));
  }

  /* ---------- yükleme ---------- */
  function loadWg() {
    return api("/api/wg/state").then((s) => {
      S.offset = s.now - Date.now() / 1000;
      trackRates(s);
      S.wg = s;
      paintWg();
    }).catch(fail);
  }
  function loadSystem() {
    return api("/api/wg/sistem").then((s) => { S.sys = s; paintSystem(); }).catch(fail);
  }
  function loadActions() {
    return api("/api/wg/islemler").then((s) => { S.actions = s.items || []; paintActions(); }).catch(fail);
  }
  function loadFsState() {
    return api("/api/state").then((s) => { S.fs = s; paintFsState(); }).catch(fail);
  }
  // DD-149: paylaşım bir modüldür; kurulu değilken liste istenmez ve eski liste ekranda kalmaz.
  function loadShares() {
    if (!shareOn()) { S.share = null; return Promise.resolve(); }
    return api("/api/paylas").then((s) => { S.share = s; if (current === "dosyalar") renderFs(); })
      .catch((e) => { S.share = null; fail(e); });
  }
  const paintWg = () => { renderPeersMini(); if (view() === "wireguard") renderWg(); renderNavCounts(); };
  const paintActions = () => { renderFeedMini(); if (view() === "gunluk") renderLog(); };
  const paintFsState = () => { renderDisk(); renderNavCounts(); };

  function renderNavCounts() {
    const online = allPeers().filter((p) => effState(p) === "ok").length;
    $("nav-wg").textContent = S.wg && wgOn() ? `${online} bağlı` : "";
    if (S.fs && fsOn() && S.fs.disk.total) {
      $("nav-fs").textContent = `%${Math.round(100 * (S.fs.disk.total - S.fs.disk.free) / S.fs.disk.total)}`;
    }
  }

  /* ---------- Genel bakış: sunucu ---------- */
  function drawSpark(id, data) {
    const box = $(id), w = 120, hgt = 40;
    const pts = (data.length > 1 ? data : [0, 0]).map((v, i, arr) =>
      [(i * w) / (arr.length - 1), hgt - (Math.min(100, Math.max(0, v)) / 100) * hgt]);
    const line = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join("");
    box.querySelector(".line").setAttribute("d", line);
    box.querySelector(".area").setAttribute("d", `${line}L${w},${hgt}L0,${hgt}Z`);
    box.querySelector(".enddot").style.top = `${100 - Math.min(100, Math.max(0, pts.length ? data[data.length - 1] || 0 : 0))}%`;
  }
  function paintSystem() {
    const s = S.sys;
    if (!s) return;
    $("brand-host").textContent = s.host;
    $("brand-host-m").textContent = s.host;
    $("brand-sub").textContent = s.domain ? `Konsol · panel.${s.domain}` : "Konsol";
    document.title = `${s.host} · Konsol`;
    $("foot-version").textContent = s.version || "–";
    $("foot-ts").textContent = s.net.tailscale || "–";
    $("sys-uptime").textContent = duration(s.uptime);
    $("sys-os").textContent = `${s.os} · çekirdek ${s.kernel}`;
    $("sys-wan").replaceChildren(s.net.wan || "—", ...(s.net.wan6 ? [h("br"), s.net.wan6] : []));
    $("sys-version").textContent = s.version || "—";
    $("eyebrow").textContent = ROUTES[view()] ? `${s.host} · ${s.os}` : $("eyebrow").textContent;
    const cpu = s.cpu.length ? s.cpu[s.cpu.length - 1] : 0;
    $("cpu-dt").textContent = `İşlemci · ${s.cores} çekirdek`;
    $("cpu-val").replaceChildren(`%${Math.round(cpu)}`, h("small", null, "şu an"));
    drawSpark("cpu-spark", s.cpu.length ? s.cpu : [0]);
    const mem = s.mem.graph.length ? s.mem.graph[s.mem.graph.length - 1] : 0;
    $("ram-dt").textContent = `Bellek · ${bytes(s.mem.total)}`;
    $("ram-val").replaceChildren(bytes(s.mem.used), h("small", null, `%${Math.round(mem)}`));
    drawSpark("ram-spark", s.mem.graph.length ? s.mem.graph : [0]);
    paintOtherLinks();
    renderPorts();
    if (!fsOn()) renderDisk();
  }

  /* disk: kullanıcı alanı, çöp ve sistem; boyutlar dosya arka ucundan */
  function renderDisk() {
    // DD-150: Dosya yöneticisi kurulu değilken disk root arka ucundan gelir (döküm yok).
    const sysDisk = S.sys && S.sys.disk;
    const fs = S.fs && fsOn() ? S.fs
      : sysDisk ? { disk: { total: sysDisk.total, free: sysDisk.free, used: null }, trash: { size: 0 }, root: S.sys.root, bare: true } : null;
    if (!fs) return;
    const total = fs.disk.total, free = fs.disk.free, used = Math.max(0, total - free);
    const trash = fs.trash.size || 0;
    const downloads = fs.disk.used == null ? null : Math.max(0, fs.disk.used - trash);
    const other = downloads == null ? null : Math.max(0, used - downloads - trash);
    const pct = total ? Math.round((100 * used) / total) : 0;
    $("disk-dt").textContent = `Disk · ${bytes(total)}`;
    $("disk-val").replaceChildren(bytes(used), h("small", null, `%${pct} dolu`));
    const seg = (cls, value) => h("span", { class: cls, style: { width: `${total ? (100 * value) / total : 0}%` } });
    const bar = $("disk-bar");
    bar.setAttribute("aria-label", `Disk %${pct} dolu; ${bytes(free)} boş`);
    if (downloads == null) {
      bar.replaceChildren(seg("seg-dl", used));
      $("disk-leg").replaceChildren(h("span", null, h("i", { class: "seg-dl" }), `Kullanılan ${bytes(used)}`),
        fs.bare ? h("span", null, "Döküm için Dosya yöneticisi") : h("span", null, h("i", { class: "seg-cop" }), `Çöp ${bytes(trash)}`));
    } else {
      bar.replaceChildren(seg("seg-dl", downloads), seg("seg-cop", trash), seg("seg-sys", other));
      $("disk-leg").replaceChildren(
        h("span", null, h("i", { class: "seg-dl" }), `Sunucu ${bytes(downloads)}`),
        h("span", null, h("i", { class: "seg-cop" }), `Çöp ${bytes(trash)}`),
        h("span", null, h("i", { class: "seg-sys" }), `Sistem ${bytes(other)}`));
    }
    $("disk-sub").replaceChildren(h("span", null, `${bytes(free)} boş`), h("span", null, fs.root));
  }

  function renderPeersMini() {
    const box = $("peers-mini");
    const list = allPeers().sort((a, b) => ORDER.indexOf(effState(a)) - ORDER.indexOf(effState(b)));
    box.replaceChildren(...list.slice(0, 5).map((p) => {
      const st = effState(p);
      return h("div", { class: "pm" },
        h("span", { class: `status ${stClass(st)}` }, h("span", { class: "dotmark" }), STLABEL[st]),
        h("div", { class: "who" }, h("strong", null, p.name, h("span", { class: "tag" }, p.net.iface)),
          h("small", null, st === "off" || st === "netoff" ? `${p.ipv4} · bağlantı kapalı` : `${p.ipv4} · son görülme ${since(p.handshake)}`)),
        st === "ok"
          ? h("div", { class: "rate" }, h("span", null, h("i", null, "↓"), rate(p.down)), h("span", null, h("i", null, "↑"), rate(p.up)))
          : h("div", { class: "rate" }, h("span", null, h("i", null, "toplam"), bytes(p.rx))));
    }));
    if (!wgOn()) {
      box.replaceChildren(h("div", { class: "empty-row" }, h("strong", null, "WireGuard kurulu değil"),
        h("span", null, "Konsol → Modüller → WireGuard ile kurulur; ağları sonra WireGuard sayfasında yapılandırırsınız.")));
    } else if (!list.length) {
      box.replaceChildren(h("div", { class: "empty-row" },
        h("strong", null, nets().length ? "Cihaz yok" : "WireGuard yapılandırılmadı"),
        h("span", null, nets().length ? "WireGuard sayfasından ilk cihazı ekleyin."
          : "WireGuard sayfasındaki Yapılandır ile ilk ağı kurun.")));
    }
    const online = list.filter((p) => effState(p) === "ok").length;
    $("sum-wg").replaceChildren(h("span", { class: "dotmark" }), `${online}/${list.length} bağlı`);
    $("wg-foot").textContent = nets().length
      ? nets().map((n) => `${n.iface} UDP ${n.port}${n.active ? "" : " (kapalı)"}`).join(" · ")
      : wgOn() ? "Ağ yok · Konsol → WireGuard → Yapılandır" : "Modül yok · Konsol → Modüller";
  }

  /* ---------- Genel bakış: son işlemler ---------- */
  const ACTION_TEXT = {
    ekle: (e) => `${e.detail} eklendi`, cikar: (e) => `${e.detail} silindi`,
    dns: (e) => `${e.detail} için DNS değişti`, keepalive: (e) => `${e.detail.split(" ")[0]} için keepalive ${e.detail.split(" ")[1] || ""} sn`,
    "peer-durum": (e) => `${e.detail.split(" ")[0]} ${e.detail.endsWith("kapat") ? "kapatıldı" : "açıldı"}`,
    "ag-durum": (e) => `${e.detail.split(" ")[0]} ağı ${e.detail.endsWith("kapat") ? "kapatıldı" : "açıldı"}`,
    "ag-ekle": (e) => `${e.detail} ağı oluşturuldu`, "ag-kaldir": (e) => `${e.detail} ağı kaldırıldı`,
    "yeniden-uret": (e) => `${e.detail} yeniden üretildi`, qr: (e) => `${e.detail} QR kodu görüntülendi`,
    profil: (e) => `${e.detail} profili indirildi`,
    klasor: (e) => `Yeni klasör: ${e.detail}`, ad: (e) => `Yeniden adlandırıldı: ${e.detail}`,
    tasi: (e) => `Taşındı: ${e.detail}`, cope: (e) => `Çöpe taşındı: ${e.detail}`,
    "geri-yukle": (e) => `Çöpten geri yüklendi: ${e.detail}`, "kalici-sil": (e) => `Kalıcı silindi: ${e.detail}`,
    "cop-bosalt": (e) => `Çöp boşaltıldı (${e.detail} öge)`, indir: (e) => `İndirildi: ${e.detail}`,
    paylas: (e) => `Paylaşıldı: ${e.detail}`, "paylas-kaldir": (e) => `Paylaşımdan çıkarıldı: ${e.detail}`,
    "modul-kur": (e) => `${modName(e.detail)} kurulumu başlatıldı`, "modul-baslat": (e) => `${modName(e.detail)} başlatıldı`,
    "modul-durdur": (e) => `${modName(e.detail)} durduruldu`,
    "modul-kaldir": (e) => `${modName(e.detail)} kaldırıldı${e.detail.endsWith("+veri") ? " · verisiyle" : ""}`,
    "modul-parola": (e) => `${modName(e.detail)} için yeni parola üretildi`,
    "modul-hesap": (e) => `${modName(e.detail)} parolası görüntülendi`,
  };
  const evKind = (e) => (e.action.startsWith("modul-") ? "mod" : e.source === "panel" ? "wg" : "fs");
  const EVICON = { wg: "shield", fs: "folder", sec: "lock", mod: "stack" };
  const EVLABEL = { wg: "WireGuard", fs: "Dosyalar", sec: "Giriş", mod: "Modüller" };
  function evText(e) {
    const fn = ACTION_TEXT[e.action];
    const text = fn ? fn(e) : `${e.action} ${e.detail}`;
    return e.ok ? text : `${text} — başarısız`;
  }
  function evRow(e, full) {
    const k = evKind(e);
    return h("div", { class: "ev" + (e.ok ? "" : " bad") }, h("time", null, stamp(e.at)),
      h("span", { class: `ico ${k}` }, svg(EVICON[k])),
      h("p", null, evText(e), h("small", null, full ? EVLABEL[k] : `${EVLABEL[k]} · ${e.user}`)),
      full ? h("span", { class: "who" }, `${e.user} · ${e.client}`) : null);
  }
  function renderFeedMini() {
    const box = $("feed-mini");
    box.replaceChildren(...S.actions.slice(0, 5).map((e) => evRow(e, false)));
    if (!S.actions.length) box.replaceChildren(h("div", { class: "empty-row" }, h("strong", null, "İşlem yok"), h("span", null, "Konsol'dan yapılan değişiklikler burada görünür.")));
    const day = S.actions.filter((e) => now() - e.at < 86400).length;
    $("feed-sum").textContent = `son 24 saatte ${day}`;
  }

  /* ---------- Genel bakış: portlar ---------- */
  const PGROUPS = [
    ["internet", "İnternet", "Dışarıdan erişilebilir"],
    ["tailscale", "Tailscale", "Yalnız tailnet'teki cihazlar"],
    ["wireguard", "WireGuard", "Local erişimi açık ağların sunucu adresinden"],
    ["loopback", "Yalnız sunucu içi", "127.0.0.1; dışarıdan erişilemez"],
  ];
  const PKEY = { internet: "wan", tailscale: "ts", wireguard: "wg", loopback: "lo" };
  function renderPorts() {
    if (!S.sys) return;
    const rows = S.sys.ports || [];
    const local = nets().filter((n) => n.scope === "ui" && n.active);
    const groups = PGROUPS.map(([scope, title, desc]) => ({
      scope, title,
      desc: scope === "wireguard" && !local.length ? "Local erişimi açık ağ yok" : desc,
      items: rows.filter((r) => r.scope === scope).map((r) => {
        const n = scope === "internet" && r.name.startsWith("WireGuard ") ? netOf(r.name.split(" ")[1]) : null;
        return Object.assign({}, r, { off: n ? !n.active : false,
          note: n ? (n.active ? labelOf(n) : `${labelOf(n)} · arayüz kapalı`)
            : scope === "wireguard" ? local.map((x) => `${x.server4} (${x.iface})`).join(", ") : "" });
      }),
    })).filter((g) => g.items.length || g.scope === "wireguard");
    $("ports").replaceChildren(...groups.map((g) => h("section", { class: "pgroup", "aria-label": g.title },
      h("div", { class: "pg-head" }, h("span", { class: `pdot ${PKEY[g.scope]}` }), h("strong", null, g.title),
        h("span", { class: "pg-n" }, g.items.filter((it) => !it.off).length)),
      h("div", { class: "pg-desc" }, g.desc),
      ...g.items.map((it) => h("div", { class: "prow" + (it.off ? " off" : "") },
        h("span", { class: "pnum" }, it.port),
        h("span", { class: "pname" }, it.name, h("span", { class: "pproto" }, it.proto.toUpperCase())),
        h("small", null, it.note))))));
    const open = groups[0].items.filter((it) => !it.off).length;
    $("ports-sum").textContent = `internete açık ${open} port`;
    $("ports-foot").textContent = `İnternete yalnız ${open} port açık. Web arayüzleri internete kapalı; Tailscale'den ya da local erişimi açık WireGuard ağlarından açılır.`;
  }

  /* ---------- WireGuard ---------- */
  let wgNet = "wg0";
  try { wgNet = localStorage.getItem("konsol-net") || "wg0"; } catch (e) { /* özel pencere */ }
  function selectNet(iface) {
    wgNet = iface;
    try { localStorage.setItem("konsol-net", iface); } catch (e) { /* özel pencere */ }
    renderWg();
  }
  function renderWg() {
    if (!S.wg) return;
    if (!nets().length) { renderWgEmpty(); return; }
    $("wg-wrap").hidden = false;
    $("wg-empty").hidden = true;
    if (!netOf(wgNet)) wgNet = nets()[0].iface;
    const tabs = $("wg-tabs");
    tabs.textContent = "";
    nets().forEach((n) => {
      const online = n.peers.filter((p) => effState(Object.assign({ net: n }, p)) === "ok").length;
      const sel = wgNet === n.iface;
      tabs.append(h("div", { class: "nettab" + (sel ? " sel" : "") + (n.active ? "" : " off") },
        h("button", { type: "button", class: "nt-main", role: "tab", "aria-selected": sel, onclick: () => selectNet(n.iface) },
          h("span", { class: "nt-top" }, h("span", { class: "nt-if" }, n.iface), h("span", { class: "nt-lab" }, labelOf(n))),
          h("small", null, "UDP ", h("span", { class: "mono" }, n.port), ` · ${n.subnet4} · ${scopeText(n)}`),
          h("span", { class: "nt-cnt" + (n.active && online ? " on" : "") }, h("span", { class: "dotmark" }),
            n.active ? `${online}/${n.peers.length} bağlı` : "Kapalı")),
        h("span", { class: "nt-actions" },
          h("button", { type: "button", class: "nt-act", title: `${n.iface} yeniden üret`, "aria-label": `${n.iface} arayüzünü yeniden üret`, onclick: () => askRegen(n) }, svg("refresh")),
          // DD-143: her ağ eşittir; wg0 da kaldırılabilir (son ağ kalkınca sayfa Yapılandır'a döner).
          h("button", { type: "button", class: "nt-act del", title: `${n.iface} arayüzünü kaldır`, "aria-label": `${n.iface} arayüzünü kaldır`, onclick: () => askDeleteNet(n) }, svg("trash")),
          h("button", { type: "button", class: "vsw", role: "switch", "aria-checked": n.active, title: n.active ? "Arayüzü kapat" : "Arayüzü aç",
            "aria-label": `${n.iface} arayüzü`, onclick: () => toggleNet(n) }))));
    });
    const next = nextNetId();
    tabs.append(h("button", { type: "button", class: "nettab add", "data-go": next ? "#/wireguard/ekle" : null, disabled: !next },
      h("span", { class: "nt-top" }, svg("plus"), h("span", { class: "nt-lab" }, "Arayüz ekle")),
      h("small", null, next ? `wg${next} · ayrı anahtar, port ve alt ağ` : "En çok 9 ek ağ oluşturulabilir")));

    const n = netOf(wgNet);
    if (!n) return;
    const list = n.peers.map((p) => Object.assign({ net: n }, p));
    const online = list.filter((p) => effState(p) === "ok").length, offCount = list.filter((p) => !p.enabled).length;
    const panel = $("wg-panel");
    panel.classList.toggle("first", nets().length > 0 && wgNet === nets()[0].iface);
    panel.classList.toggle("off", !n.active);
    const bar = $("wg-offbar");
    bar.hidden = n.active;
    bar.replaceChildren(h("div", null, h("strong", null, `${n.iface} kapalı. `),
      h("span", null, `Cihazlar bağlanamaz. Anahtarlar, cihazlar ve profiller duruyor; açınca kendiliğinden bağlanırlar.`)),
      h("button", { type: "button", class: "btn btn-primary btn-sm", onclick: () => toggleNet(n) }, "Arayüzü aç"));
    $("wg-summary").replaceChildren(
      h("div", null, h("dt", null, "Bağlı"), h("dd", null, n.active ? `${online} ` : "Kapalı ",
        h("small", null, n.active ? `/ ${list.length} cihaz${offCount ? ` · ${offCount} kapalı` : ""}` : `${list.length} cihaz bekliyor`))),
      h("div", null, h("dt", null, "Port"), h("dd", null, `${n.port} `, h("small", null, n.active ? "UDP açık" : "UDP dinlenmiyor"))),
      h("div", null, h("dt", null, "Erişim"), h("dd", null, h("small", { class: "plain" }, scopeText(n)))),
      h("div", null, h("dt", null, "Adres"), h("dd", null, h("small", { class: "plain mono" }, `${n.server4}/24`))));
    $("wg-table").replaceChildren(
      h("div", { class: "tr head" }, h("span", { class: "c-sw" }, "Açık"), h("span", null, "Durum"), h("span", null, "Cihaz"),
        h("span", { class: "c-addr" }, "Adres"), h("span", { class: "c-hs" }, "Son görülme"), h("span", { class: "c-traffic" }, "Trafik"), h("span", { class: "c-dns" }, "")),
      ...list.map((p) => {
        const st = effState(p), cut = st === "off" || st === "netoff";
        return h("div", { class: "tr" + (cut ? " p-off" : "") },
          h("span", { class: "c-sw" }, h("button", { type: "button", class: "sw", role: "switch", "aria-checked": p.enabled, disabled: !n.active,
            title: !n.active ? "Önce arayüzü açın" : p.enabled ? "Bağlantıyı kapat" : "Bağlantıyı aç",
            "aria-label": `${p.name} bağlantısı`, onclick: () => togglePeer(n, p) })),
          h("span", { class: `status ${stClass(st)}` }, h("span", { class: "dotmark" }), STLABEL[st]),
          h("span", { class: "who2" }, h("strong", null, p.name),
            h("small", null, `DNS ${providerOf(p.dns, p.provider)} · keepalive ${kaText(p.keepalive)}`)),
          h("span", { class: "addr c-addr" }, h("span", { class: "mono" }, p.ipv4), h("span", { class: "mono v6" }, p.ipv6)),
          h("span", { class: "c-hs" }, cut ? "—" : since(p.handshake)),
          h("span", { class: "traffic c-traffic" }, h("span", null, h("i", null, "↓ "), bytes(p.rx)), h("span", null, h("i", null, "↑ "), bytes(p.tx))),
          h("span", { class: "acts c-dns" },
            h("button", { type: "button", class: "ib", title: "QR ve profil", "aria-label": `${p.name} QR ve profil`, disabled: !p.profile, onclick: () => openQr(n, p) }, svg("qr")),
            h("button", { type: "button", class: "ib del", title: "Sil", "aria-label": `${p.name} sil`, onclick: () => askPeerDelete(n, p) }, svg("trash")),
            h("button", { type: "button", class: "ib more-btn", title: "Diğer", "aria-label": `${p.name} için diğer işlemler`, "aria-haspopup": "menu", "aria-expanded": false,
              onclick: (e) => openRowMenu(e.currentTarget, n, p) }, svg("more"))));
      }));
    if (!list.length) {
      $("wg-table").append(h("div", { class: "empty-row" }, h("strong", null, "Bu ağda henüz cihaz yok"),
        h("span", null, "Aşağıdaki Peer ekle ile ilk cihazı ekleyin; QR hemen hazır olur.")));
    }
    const add = $("wg-add");
    add.onclick = () => openPeerAdd(n);
    add.replaceChildren(h("span", { class: "plus" }, svg("plus")),
      h("span", null, h("strong", null, "Peer ekle"),
        h("small", null, `${n.iface} · ${labelOf(n)} ağına yeni cihaz; anahtarlar sunucuda üretilir, QR hemen hazır olur`)));
  }

  // DD-143: kurulum WireGuard ağı yaratmaz; ilk ağı buradan kurulur.
  function renderWgEmpty() {
    $("wg-wrap").hidden = true;
    $("wg-empty").hidden = false;
    $("wg-empty").replaceChildren(
      h("div", { class: "empty-card" },
        h("span", { class: "empty-ico" }, svg("shield")),
        h("h2", null, "WireGuard yapılandırılmadı"),
        h("p", null, "Sunucu kurulumu WireGuard ağı oluşturmaz. İlk ağı burada kurarsınız: anahtar sunucuda üretilir, UDP portu açılır ve cihaz eklemeye hazır olur."),
        h("ul", { class: "conseq calm" },
          h("li", null, svg("shield"), h("span", null, "wg0 · 10.8.0.0/24 · sunucu 10.8.0.1")),
          h("li", null, svg("lock"), h("span", null, "Local erişim kapalıysa cihazlar yalnız internete çıkar; açıksa qBittorrent arayüzü ağın sunucu adresinden açılır.")),
          h("li", null, svg("plus"), h("span", null, "Kurduktan sonra bu sayfadan cihaz (peer) eklersiniz; QR hemen hazır olur."))),
        h("button", { type: "button", class: "btn btn-primary", onclick: () => { location.hash = "#/wireguard/ekle"; } },
          svg("plus"), "Yapılandır")));
  }

  function togglePeer(n, p) {
    post(peerPath(n.iface, p.name, "/durum"), { on: !p.enabled })
      .then(() => loadWg())
      .then(() => toast(p.enabled
        ? `${p.name} kapatıldı: bağlantısı kesildi, profili ve adresi duruyor.`
        : `${p.name} açıldı: cihaz birkaç saniye içinde kendiliğinden bağlanır.`))
      .catch(fail);
  }

  function toggleNet(n) {
    const list = n.peers, online = list.filter((p) => effState(Object.assign({ net: n }, p)) === "ok").length;
    if (!n.active) {
      post(netPath(n.iface, "/durum"), { on: true })
        .then(() => loadWg()).then(() => toast(`${n.iface} açıldı: UDP ${n.port} dinleniyor, cihazlar birkaç saniye içinde bağlanır.`))
        .catch(fail);
      return;
    }
    ask({
      title: `${n.iface} · ${labelOf(n)} kapatılsın mı?`, sub: `UDP ${n.port} · ${n.subnet4} · ${scopeText(n)}`, calm: true,
      items: [
        ["shield", online ? `${online} bağlı cihazın bağlantısı hemen kesilir; ${list.length} cihazın hiçbiri bağlanamaz.` : `Bu ağdaki ${list.length} cihaz bağlanamaz.`],
        ["lock", "Arayüz durdurulur; açınca aynı anahtar ve adreslerle geri gelir."],
        ["refresh", n.iface === "wg0"
          ? "Anahtar, cihazlar ve profiller silinmez. Sunucu yeniden başlasa da kapalı kalır; kurulum yeniden çalışınca wg0 yeniden açılır."
          : "Anahtar, cihazlar ve profiller silinmez. Sunucu yeniden başlasa da kapalı kalır."],
      ],
      go: "Arayüzü kapat",
      onOk: () => post(netPath(n.iface, "/durum"), { on: false })
        .then(() => loadWg()).then(() => toast(`${n.iface} kapatıldı: ${list.length} cihazın bağlantısı kesildi.`)).catch(fail),
    });
  }

  function askRegen(n) {
    const names = n.peers.map((p) => p.name);
    ask({
      title: `${n.iface} · ${labelOf(n)} yeniden üretilsin mi?`, sub: `UDP ${n.port} · ${n.subnet4} · ${scopeText(n)}`, word: true, danger: true,
      items: [
        ["refresh", "Yeni sunucu anahtarı üretilir; port, adresler ve erişim aynı kalır."],
        ["shield", names.length ? `${names.length} cihazın profili ve QR kodu silinir (${names.join(", ")}); eski profillerle bağlanılamaz.` : "Bu ağda cihaz yok."],
        ["plus", "Cihazları Peer ekle ile yeniden eklemek gerekir. Geri alınamaz."],
      ],
      go: "Yeniden üret",
      onOk: () => post(netPath(n.iface, "/reset"), { confirm: "onayla" })
        .then((r) => loadWg().then(() => toast(`${n.iface} yeniden üretildi: ${r.peers} cihaz silindi, yeni sunucu anahtarı etkin.`))).catch(fail),
    });
  }

  function askDeleteNet(n) {
    const names = n.peers.map((p) => p.name);
    const last = nets().length === 1;
    ask({
      title: `${n.iface} · ${labelOf(n)} kaldırılsın mı?`, sub: `UDP ${n.port} · ${n.subnet4} · ${scopeText(n)}`, word: true, danger: true,
      items: [
        ["shield", names.length ? `${names.length} cihazın bağlantısı kesilir; profilleri ve QR kodları silinir (${names.join(", ")}).` : "Bu ağda cihaz yok."],
        ["lock", `UDP ${n.port} kapanır; bu ağın güvenlik duvarı kuralları kaldırılır.`],
        ["trash", "Sunucu anahtarı silinir. Geri alınamaz; aynı ağ yeniden eklenirse cihazlara yeni profil gerekir."],
        last ? ["plus", "Bu son ağ: kaldırınca WireGuard yapılandırılmamış duruma döner, yeni ağı Yapılandır ile kurarsınız."] : null,
      ].filter(Boolean),
      go: "Arayüzü kaldır",
      onOk: () => post(netPath(n.iface, "/remove"), { confirm: "onayla" }).then((r) => {
        if (wgNet === n.iface) wgNet = "";
        return loadWg().then(() => toast(`${n.iface} kaldırıldı: ${r.peers} cihaz silindi, UDP ${n.port} kapandı.`));
      }).catch(fail),
    });
  }

  function askPeerDelete(n, p) {
    ask({
      title: `“${p.name}” silinsin mi?`, sub: `${n.iface} · ${p.ipv4} · ${p.ipv6}`, danger: true,
      items: [
        ["shield", "Bağlantısı hemen kesilir."],
        ["qr", "Profili ve QR kodu silinir; bu cihazı yeniden bağlamak için yeniden eklemek gerekir."],
        ["refresh", `${p.ipv4} adresi boşa çıkar ve yeni cihazlara verilebilir.`],
      ],
      go: "Peer'ı sil",
      onOk: () => post(peerPath(n.iface, p.name, "/remove")).then(() => loadWg()).then(() => toast(`“${p.name}” silindi.`)).catch(fail),
    });
  }

  /* satır menüsü (…) */
  const rowMenu = h("div", { class: "popmenu", id: "rowmenu", role: "menu", hidden: true });
  document.body.append(rowMenu);
  let menuBtn = null;
  function closeRowMenu() {
    if (rowMenu.hidden) return;
    rowMenu.hidden = true;
    if (menuBtn) menuBtn.setAttribute("aria-expanded", "false");
    menuBtn = null;
  }
  function openRowMenu(btn, n, p) {
    if (menuBtn === btn) { closeRowMenu(); return; }
    closeRowMenu();
    menuBtn = btn;
    btn.setAttribute("aria-expanded", "true");
    rowMenu.replaceChildren(
      h("button", { type: "button", role: "menuitem", onclick: () => { closeRowMenu(); openEdit(n, p); } },
        svg("pencil"), h("span", null, "Düzenle"), h("small", null, "DNS ve keepalive")),
      h("button", { type: "button", role: "menuitem", disabled: !p.profile, onclick: () => { closeRowMenu(); downloadProfile(n, p); } },
        svg("download"), h("span", null, "Profili indir"), h("small", null, "gizli anahtar içerir")));
    rowMenu.hidden = false;
    const r = btn.getBoundingClientRect();
    rowMenu.style.left = `${Math.max(8, Math.min(window.innerWidth - 218, r.right - 210))}px`;
    rowMenu.style.top = `${Math.min(window.innerHeight - 90, r.bottom + 6)}px`;
    rowMenu.querySelector("button").focus();
  }
  document.addEventListener("click", (e) => { if (!e.target.closest("#rowmenu") && !e.target.closest(".more-btn")) closeRowMenu(); }, true);
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    closeRowMenu();
    if (current === "dosyalar" && fsSel.size && !document.querySelector("dialog[open]")) clearSel();
  });
  window.addEventListener("resize", closeRowMenu);
  window.addEventListener("scroll", closeRowMenu, true);

  /* ---------- DNS seçici ---------- */
  function makeDnsPicker(box, idp, opts) {
    const st = { choice: DNS_PRESETS[0].ips, custom: "" };
    const value = () => (st.choice === "custom" ? normDns(st.custom) : st.choice);
    function check() {
      const bad = st.choice === "custom" && st.custom.trim() !== "" && !value();
      const err = $(`${idp}-err`), inp = $(`${idp}-custom`);
      if (err) err.hidden = !bad;
      if (inp) inp.setAttribute("aria-invalid", String(bad));
      return !bad;
    }
    function render() {
      box.replaceChildren(...DNS_PRESETS.map((d) => {
        const sel = st.choice === d.ips;
        return h("button", { type: "button", class: "sug" + (sel ? " on" : ""), role: "radio", "aria-checked": sel,
          onclick: () => { st.choice = d.ips; render(); opts.onChange(); } },
          h("strong", null, d.name), h("span", { class: "badge" }, opts.badge(d.ips)),
          d.tag ? h("span", { class: "tagline" }, d.tag) : null, h("span", { class: "ips" }, d.ips));
      }));
      const isCustom = st.choice === "custom";
      const custom = h("div", { class: "sug custom" + (isCustom ? " on" : "") },
        h("button", { type: "button", class: "sug-head", role: "radio", "aria-checked": isCustom,
          onclick: () => { if (!isCustom) { st.choice = "custom"; render(); opts.onChange(); } $(`${idp}-custom`).focus(); } },
          h("strong", null, "Custom"), h("span", { class: "badge" }, opts.badge(null)),
          h("span", { class: "tagline" }, "Kendi DNS adreslerinizi yazın; birden çoksa virgülle ayırın")));
      if (isCustom) {
        custom.append(h("div", { class: "cwrap" },
          h("input", { type: "text", id: `${idp}-custom`, value: st.custom, placeholder: "ör. 192.168.1.10, fd00::53", autocomplete: "off", spellcheck: "false",
            "aria-label": "Custom DNS adresleri", oninput: (e) => { st.custom = e.target.value; opts.onChange(); } }),
          h("small", { class: "err-s", id: `${idp}-err`, hidden: true }, "Geçerli IPv4 ya da IPv6 adreslerini virgülle ayırarak yazın.")));
      }
      box.append(custom);
    }
    function set(ips) {
      const preset = DNS_PRESETS.find((d) => d.ips === ips);
      st.choice = preset ? preset.ips : "custom";
      st.custom = preset ? "" : ips || "";
      render();
    }
    return { set, value, check, render };
  }

  /* ---------- düzenle penceresi ---------- */
  let editing = null;
  const peDns = makeDnsPicker($("pe-sugg"), "pe-dns", {
    badge: (ips) => {
      if (!editing) return "";
      const isPreset = DNS_PRESETS.some((d) => d.ips === editing.p.dns);
      if (ips === null) return isPreset ? "" : "şu an";
      return ips === editing.p.dns ? "şu an" : ips === editing.n.dns ? "ağın varsayılanı" : "";
    },
    onChange: () => validateEdit(),
  });
  function openEdit(n, p) {
    editing = { n, p };
    $("pe-title").textContent = `${p.name} · düzenle`;
    $("pe-sub").textContent = `${n.iface} · ${p.ipv4} · şu an DNS ${providerOf(p.dns, p.provider)}, keepalive ${kaText(p.keepalive)}`;
    $("pe-ka").value = String(p.keepalive);
    peDns.set(p.dns);
    validateEdit();
    $("pe").showModal();
    const on = $("pe-sugg").querySelector('[aria-checked="true"]');
    if (on) on.focus();
  }
  function renderKaChips() {
    const v = $("pe-ka").value.trim();
    $("pe-ka-chips").replaceChildren(...[["0", "Kapalı"], ["21", "21 sn · önerilen"], ["25", "25 sn"]].map(([val, label]) =>
      h("button", { type: "button", "aria-pressed": v === val, onclick: () => { $("pe-ka").value = val; validateEdit(); } }, label)));
  }
  function validateEdit() {
    if (!editing) return;
    const p = editing.p;
    const dnsOk = peDns.check(), dns = peDns.value();
    const kaRaw = $("pe-ka").value.trim(), ka = /^\d+$/.test(kaRaw) ? Number(kaRaw) : NaN, kaOk = ka >= 0 && ka <= 65535;
    $("pe-ka").setAttribute("aria-invalid", String(!kaOk));
    $("pe-save").disabled = !dnsOk || !dns || !kaOk || (dns === p.dns && ka === p.keepalive);
    renderKaChips();
  }
  const xIcon = (btn) => { btn.append(svg("plus")); btn.firstChild.style.transform = "rotate(45deg)"; };
  xIcon($("pe-x"));
  $("pe-ka").addEventListener("input", validateEdit);
  const closeEdit = () => { $("pe").close(); editing = null; };
  $("pe-x").addEventListener("click", closeEdit);
  $("pe-cancel").addEventListener("click", closeEdit);
  $("pe-form").addEventListener("submit", (e) => {
    e.preventDefault();
    if ($("pe-save").disabled || !editing) return;
    const { n, p } = editing, dns = peDns.value(), ka = Number($("pe-ka").value.trim());
    const jobs = [];
    if (dns !== p.dns) jobs.push(() => post(peerPath(n.iface, p.name, "/dns"), { dns }));
    if (ka !== p.keepalive) jobs.push(() => post(peerPath(n.iface, p.name, "/keepalive"), { keepalive: ka }));
    closeEdit();
    jobs.reduce((chain, job) => chain.then(job), Promise.resolve())
      .then(() => loadWg())
      .then(() => toast(`${p.name} güncellendi: DNS ${providerOf(dns)}, keepalive ${kaText(ka)}. Cihazda yeni QR'ı okutun.`,
        { label: "QR'ı göster", fn: () => openQr(netOf(n.iface), (netOf(n.iface).peers.find((x) => x.name === p.name) || p)) }))
      .catch(fail);
  });

  /* ---------- peer ekle ve QR ---------- */
  const shClose = () => $("sh").close();
  function shHead(title, sub, icon) {
    const x = h("button", { type: "button", class: "dlg-x", "aria-label": "Kapat", onclick: shClose });
    xIcon(x);
    return h("div", { class: "dlg-head" },
      h("div", { class: "okhead" }, h("span", { class: "okico plain" }, svg(icon)),
        h("div", null, h("h3", { id: "sh-title" }, title), h("p", null, sub))), x);
  }
  let PA = null;
  function openPeerAdd(n) {
    PA = { n, name: "", dns: n.dns || (S.wg.defaults && S.wg.defaults.dns) || DNS_PRESETS[0].ips, ka: (S.wg.defaults && S.wg.defaults.keepalive) || 21 };
    renderPeerAdd();
    $("sh").showModal();
    const inp = $("pa-name");
    if (inp) inp.focus();
  }
  function renderPeerAdd() {
    const n = PA.n;
    const nameErr = PA.name && !NAME_RE.test(PA.name) ? "Harf, rakam, nokta, alt çizgi ve tire; en çok 32 karakter." : "";
    const taken = n.peers.some((p) => p.name === PA.name) ? "Bu ağda aynı adlı bir cihaz zaten var." : "";
    const err = nameErr || taken;
    const body = $("sh-body");
    body.replaceChildren(
      shHead(`${dative(n.iface)} peer ekle`, `${labelOf(n)} · ${n.subnet4} · anahtarlar sunucuda üretilir`, "shield"),
      h("div", { class: "field" },
        h("label", { for: "pa-name" }, "Cihaz adı"),
        h("input", { type: "text", id: "pa-name", value: PA.name, maxlength: "32", autocomplete: "off", spellcheck: "false",
          placeholder: "ör. iphone, macbook, tv-salon", "aria-invalid": String(!!err),
          oninput: (e) => { PA.name = e.target.value.trim(); updatePeerAdd(); } }),
        h("small", { class: "err-s", id: "pa-err", hidden: !err }, err),
        h("small", { class: "hint-s" }, "Profil dosyasının adı da bu olur.")),
      h("div", { class: "field" },
        h("span", { class: "lbl" }, "DNS sunucuları"),
        h("div", { class: "sugg", id: "pa-sugg", role: "radiogroup", "aria-label": "DNS sunucuları" })),
      h("div", { class: "field" },
        h("label", { for: "pa-ka" }, "PersistentKeepalive (saniye)"),
        h("div", { class: "ka-row" }, h("input", { type: "number", id: "pa-ka", min: "0", max: "65535", value: String(PA.ka), autocomplete: "off",
          oninput: (e) => { PA.ka = e.target.value.trim(); updatePeerAdd(); } }),
          h("div", { class: "chips-s" }, ...[["0", "Kapalı"], ["21", "21 sn · önerilen"], ["25", "25 sn"]].map(([val, label]) =>
            h("button", { type: "button", "aria-pressed": String(PA.ka) === val, onclick: () => { PA.ka = val; renderPeerAdd(); } }, label)))),
        h("small", { class: "hint-s" }, "0 = kapalı; mobil ağlarda 21 önerilir.")),
      h("div", { class: "dlg-foot" },
        h("button", { type: "button", class: "btn btn-quiet", onclick: shClose }, "Vazgeç"),
        h("button", { type: "button", class: "btn btn-primary", id: "pa-go", onclick: createPeer }, svg("plus"), "Peer ekle")));
    PA.picker = makeDnsPicker($("pa-sugg"), "pa-dns", {
      badge: (ips) => (ips === n.dns ? "ağın varsayılanı" : ips === DNS_PRESETS[0].ips ? "önerilen" : ""),
      onChange: () => updatePeerAdd(),
    });
    PA.picker.set(PA.dns);
    updatePeerAdd();
  }
  function updatePeerAdd() {
    const n = PA.n;
    const nameOk = NAME_RE.test(PA.name) && !n.peers.some((p) => p.name === PA.name);
    const ka = /^\d+$/.test(String(PA.ka)) ? Number(PA.ka) : NaN;
    const dns = PA.picker.value(), dnsOk = PA.picker.check();
    const err = $("pa-err");
    if (err) {
      const text = PA.name && !NAME_RE.test(PA.name) ? "Harf, rakam, nokta, alt çizgi ve tire; en çok 32 karakter."
        : n.peers.some((p) => p.name === PA.name) ? "Bu ağda aynı adlı bir cihaz zaten var." : "";
      err.textContent = text;
      err.hidden = !text;
    }
    const go = $("pa-go");
    if (go) go.disabled = !nameOk || !dns || !dnsOk || !(ka >= 0 && ka <= 65535);
  }
  function createPeer() {
    const n = PA.n, name = PA.name, dns = PA.picker.value(), ka = Number(PA.ka);
    const mtu = (S.wg.defaults && S.wg.defaults.mtu) || 1420;
    $("pa-go").disabled = true;
    post(netPath(n.iface, "/peers"), { name, dns, keepalive: ka, mtu })
      .then(() => loadWg())
      .then(() => {
        const fresh = netOf(n.iface), peer = fresh && fresh.peers.find((p) => p.name === name);
        if (fresh && peer) openQr(fresh, peer, true);
        toast(`“${name}” eklendi.`);
      })
      .catch((e) => { fail(e); updatePeerAdd(); });
  }

  function openQr(n, p, fresh) {
    $("sh-body").replaceChildren(
      shHead(`${p.name} · QR`, `${n.iface} · ${p.ipv4} · ${providerOf(p.dns, p.provider)} DNS`, "qr"),
      h("div", { class: "qrbox", id: "qr-box" }, h("p", { class: "hint-s" }, "QR hazırlanıyor…")),
      h("div", { class: "infoline-s" }, svg("lock"),
        h("span", null, "QR ve profil cihazın gizli anahtarını taşır. Yalnız cihazın kendisine okutun; ekran görüntüsü almayın.")),
      h("div", { class: "dlg-foot" },
        h("button", { type: "button", class: "btn btn-quiet", onclick: () => downloadProfile(n, p) }, svg("download"), "Profili indir"),
        h("button", { type: "button", class: "btn btn-primary", onclick: shClose }, fresh ? "Bitti" : "Kapat")));
    if (!$("sh").open) $("sh").showModal();
    api(peerPath(n.iface, p.name, "/qr.png"), { blob: true }).then((blob) => {
      const url = URL.createObjectURL(blob);
      const img = h("img", { src: url, alt: `${p.name} için WireGuard QR kodu` });
      img.addEventListener("load", () => URL.revokeObjectURL(url));
      const box = $("qr-box");
      if (box) box.replaceChildren(img);
    }).catch((e) => {
      const box = $("qr-box");
      if (box) box.replaceChildren(h("p", { class: "err-s" }, e.message));
    });
  }
  function downloadProfile(n, p) {
    api(peerPath(n.iface, p.name, "/profile"), { blob: true }).then((blob) => {
      const url = URL.createObjectURL(blob);
      const a = h("a", { href: url, download: `${p.name}.conf` });
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    }).catch(fail);
  }

  /* ---------- arayüz ekle ---------- */
  function nextNetId() {
    const max = (S.wg && S.wg.max ? S.wg.max : 10) - 1;
    for (let i = 0; i <= max; i++) if (!netOf(`wg${i}`)) return i;
    return null;
  }
  const PORT_START = 61020;
  function firstPort() {
    const def = S.wg && S.wg.defaults ? S.wg.defaults.port : 0;
    return def && !portOwner(def) ? def : suggestPort();
  }
  function portOwner(port) {
    const n = nets().find((x) => x.port === port);
    if (n) return n.iface;
    return (S.wg && S.wg.reserved || []).includes(port) ? "sunucu" : null;
  }
  function suggestPort() {
    let port = PORT_START;
    while (portOwner(port)) port++;
    return port;
  }
  const NA = { i: null, local: false };
  const naDns = makeDnsPicker($("na-sugg"), "na-dns", { badge: (ips) => (ips === DNS_PRESETS[0].ips ? "önerilen" : ""), onChange: () => updateAddNet() });
  function renderAddNet() {
    if (!S.wg) return;
    const i = nextNetId();
    if (i == null) { location.hash = "#/wireguard"; toast("En çok 9 ek ağ oluşturulabilir."); return; }
    NA.i = i;
    NA.local = false;
    $("na-label").value = "";
    $("na-port").value = String(nets().length ? suggestPort() : firstPort());
    $("na-ident").replaceChildren(h("span", { class: "big" }, `wg${i}`),
      h("span", { class: "mono" }, `10.8.${i}.0/24`), h("span", { class: "mono" }, `sunucu 10.8.${i}.1`));
    naDns.set(DNS_PRESETS[0].ips);
    updateAddNet();
    $("na-label").focus();
  }
  function addNetDraft() {
    const i = NA.i, label = $("na-label").value.trim();
    const raw = $("na-port").value.trim(), port = /^\d+$/.test(raw) ? Number(raw) : NaN;
    let portErr = "";
    if (!(port >= 1024 && port <= 65535)) portErr = "1024 ile 65535 arasında bir port yazın.";
    else if (portOwner(port)) portErr = `UDP ${port} kullanımda (${portOwner(port)}); bu port reddedildi, başka bir port yazın.`;
    return { i, id: `wg${i}`, label, port, portErr, scope: NA.local ? "ui" : "inet",
      scopeText: NA.local ? "İnternet + local" : "Yalnız internet", subnet: `10.8.${i}.0/24`, dns: naDns.value(), dnsOk: naDns.check() };
  }
  function updateAddNet() {
    if (NA.i == null) return;
    const d = addNetDraft();
    $("na-local").setAttribute("aria-checked", String(NA.local));
    $("na-local-row").classList.toggle("on", NA.local);
    $("na-local-desc").textContent = NA.local
      ? `Açık: internet + qBittorrent arayüzü bu ağın sunucu adresinden (10.8.${d.i}.1) açılır.`
      : "Kapalı: cihazlar yalnız internete çıkar; sunucudaki arayüzler bu ağa kapalı.";
    $("na-port-err").textContent = d.portErr;
    $("na-port-err").hidden = !d.portErr;
    $("na-port").setAttribute("aria-invalid", String(!!d.portErr));
    $("na-preview").replaceChildren(h("div", { class: "nettab sel preview" },
      h("div", { class: "nt-main" },
        h("span", { class: "nt-top" }, h("span", { class: "nt-if" }, d.id), h("span", { class: "nt-lab" }, d.label || "Etiketsiz")),
        h("small", null, "UDP ", h("span", { class: "mono" }, Number.isNaN(d.port) ? "—" : d.port), ` · ${d.subnet} · ${d.scopeText}`),
        h("span", { class: "nt-cnt" }, h("span", { class: "dotmark" }), "0/0 bağlı"))));
    const will = [
      "Yeni sunucu anahtarı üretilir.",
      `UDP ${Number.isNaN(d.port) ? "…" : d.port} internete açılır; güvenlik duvarı kuralları kurulur.`,
      d.scope === "ui" ? `qBittorrent arayüzü 10.8.${d.i}.1 adresinde açılır (modül kuruluysa).` : "Sunucudaki arayüzler bu ağa kapalı kalır.",
      `Yeni cihazlara ${d.dns ? providerOf(d.dns) : "seçilen"} DNS önerilir.`,
    ];
    $("na-will").replaceChildren(...will.map((text) => h("li", null, svg("check"), h("span", null, text))));
    $("na-create").disabled = !!d.portErr || !d.dns || !d.dnsOk;
  }
  $("na-label").addEventListener("input", updateAddNet);
  $("na-local").addEventListener("click", () => { NA.local = !NA.local; updateAddNet(); });
  $("na-port").addEventListener("input", updateAddNet);
  $("na-create").addEventListener("click", () => {
    const d = addNetDraft();
    if (d.portErr || !d.dns || !d.dnsOk) return;
    $("na-create").disabled = true;
    post("/api/wg/nets", { port: String(d.port), scope: d.scope, dns: d.dns, label: d.label })
      .then((r) => {
        wgNet = r.iface;
        return loadWg().then(() => {
          location.hash = "#/wireguard";
          toast(`${r.iface} oluşturuldu: UDP ${r.port} açık. Şimdi Peer ekle ile cihaz ekleyin.`);
        });
      })
      .catch((e) => { fail(e); updateAddNet(); });
  });

  /* ---------- onay penceresi ---------- */
  let askOk = null;
  function ask(o) {
    askOk = o.onOk;
    $("cf-title").textContent = o.title;
    $("cf-sub").textContent = o.sub || "";
    $("cf-list").replaceChildren(...o.items.map(([ic, text]) => h("li", null, svg(ic), h("span", null, text))));
    $("cf-list").classList.toggle("calm", !!o.calm);
    $("cf-extra").replaceChildren(...(o.extra ? [o.extra] : []));
    $("cf-word-row").hidden = !o.word;
    $("cf-word").value = "";
    const go = $("cf-go");
    go.textContent = o.go;
    go.className = "btn " + (o.danger ? "btn-danger" : "btn-primary");
    go.disabled = !!o.word;
    $("cf").showModal();
    (o.word ? $("cf-word") : $("cf-cancel")).focus();
  }
  xIcon($("cf-x"));
  $("cf-word").addEventListener("input", (e) => { $("cf-go").disabled = e.target.value.trim().toLocaleLowerCase("tr") !== "onayla"; });
  const closeAsk = () => { $("cf").close(); askOk = null; };
  $("cf-x").addEventListener("click", closeAsk);
  $("cf-cancel").addEventListener("click", closeAsk);
  $("cf-form").addEventListener("submit", (e) => {
    e.preventDefault();
    if ($("cf-go").disabled) return;
    const fn = askOk;
    closeAsk();
    if (fn) fn();
  });

  /* ---------- Dosyalar ---------- */
  let fsPath = [], fsView = "files", fsList = null, fsTrash = null, fsAdding = false, fsRename = null;
  /* DD-145: kısayol sütunu, arama, çoklu seçim ve listenin içine bırakarak yükleme. */
  let fsRootDirs = null, fsQuery = "", fsSel = new Set(), fsLast = "", fsUps = [], upSeq = 0, upBusy = false, dragDepth = 0;
  /* DD-144: kök kullanıcı alanı (/srv); adı arka uçtan gelir, hiçbir yerde sabit yazılmaz. */
  const fsRoot = () => (S.fs && S.fs.root) || "/srv";
  const fsHere = () => [fsRoot(), ...fsPath].join("/") || "/";
  const pathText = (parts) => parts.join("/");
  /* qBittorrent'in geçici klasörü köke göre verilir (ör. downloads/incomplete). */
  const tempRel = () => (S.fs && S.fs.temp) || "";
  const inTemp = (rel) => { const t = tempRel(); return !!t && (rel === t || rel.startsWith(t + "/")); };
  const kindOf = (item) => (item.type === "dir" ? "dir" : /\.(txt|log|nfo|srt|sub|md|json|conf|ini|csv|yml|yaml)$/i.test(item.name) ? "text"
    : /\.(mkv|mp4|avi|mov|m4v|ts|webm)$/i.test(item.name) ? "video" : "file");
  const isText = (item) => kindOf(item) === "text";

  function loadFs() {
    return api(`/api/list?path=${enc(pathText(fsPath))}`).then((r) => {
      fsList = r;
      fsSel.forEach((n) => { if (!r.entries.some((e) => e.name === n)) fsSel.delete(n); });
      if (!fsPath.length) fsRootDirs = r.entries.filter((e) => e.type === "dir").map((e) => ({ name: e.name, count: e.count }));
      renderFs();
      if (fsRootDirs == null) loadRootDirs();
    }).catch((e) => { fail(e); if (fsPath.length) { fsPath = []; loadFs(); } });
  }
  /* Alt klasörden açılan sayfada da kısayol sütunu dolsun. */
  function loadRootDirs() {
    return api("/api/list?path=&dirs=1").then((r) => {
      fsRootDirs = r.entries.map((e) => ({ name: e.name, count: e.count }));
      renderRail();
    }).catch(() => { fsRootDirs = []; });
  }
  function loadTrash() {
    return api("/api/trash").then((r) => { fsTrash = r.items || []; renderFs(); }).catch(fail);
  }
  function fsGo(parts) {
    fsPath = parts;
    fsAdding = false;
    fsRename = null;
    fsList = null;
    fsSel.clear();
    fsQuery = "";
    renderFs();
    loadFs();
  }
  function fsSetView(v) {
    fsView = v;
    location.hash = v === "trash" ? "#/dosyalar/cop" : v === "shares" ? "#/dosyalar/paylasim" : "#/dosyalar";
    renderFs();
    if (v === "trash") loadTrash();
    else if (v === "shares") loadShares();
    else if (!fsList) loadFs();
  }

  /* ---- kısayol sütunu: kök, üst klasörler, paylaşımlar, çöp, disk ---- */
  function railBtn(o) {
    return h("button", { type: "button", class: "rl" + (o.cur ? " cur" : ""), "aria-current": o.cur ? "true" : "false", title: o.title, onclick: o.onclick },
      h("span", { class: `rl-ico ${o.tone}` }, svg(o.icon)),
      h("span", { class: "rl-nm" }, o.title),
      o.count ? h("span", { class: "rl-c" }, String(o.count)) : null);
  }
  function renderRail() {
    const fs = S.fs;
    const total = fs ? fs.disk.total : 0, free = fs ? fs.disk.free : 0;
    const trashCount = fs ? fs.trash.count : 0;
    const shareCount = S.share ? S.share.items.length : (fs && fs.share ? fs.share.count : 0);
    const dirs = fsRootDirs || [];
    const out = [
      h("p", { class: "rl-t" }, "Kullanıcı alanı"),
      railBtn({ cur: fsView === "files" && !fsPath.length, icon: "server", tone: "t-dir", title: "Sunucu",
        count: dirs.length, onclick: () => fsOpen([]) }),
      ...dirs.map((d) => railBtn({ cur: fsView === "files" && fsPath[0] === d.name, icon: "folder", tone: "t-dir",
        title: d.name, count: d.count, onclick: () => fsOpen([d.name]) })),
      h("p", { class: "rl-t" }, "Yönetim"),
      shareOn() ? railBtn({ cur: fsView === "shares", icon: "share", tone: "t-share", title: "Paylaşımlar", count: shareCount, onclick: () => fsSetView("shares") }) : null,
      railBtn({ cur: fsView === "trash", icon: "trash", tone: "t-warn", title: "Çöp", count: trashCount, onclick: () => fsSetView("trash") }),
    ];
    if (total) {
      const pct = Math.round((100 * (total - free)) / total);
      out.push(h("div", { class: "rl-disk" },
        h("div", { class: "rl-dl" }, h("span", null, "Disk"), h("span", null, `%${pct}`)),
        h("div", { class: "rl-bar" }, h("i", { style: { width: `${pct}%` } })),
        h("div", { class: "rl-dl" }, h("span", null, `${bytes(free)} boş`), h("span", { class: "mono" }, fsRoot()))));
    }
    $("fs-rail").replaceChildren(...out.filter(Boolean));
  }
  function fsOpen(parts) {
    if (fsView !== "files") { fsView = "files"; location.hash = "#/dosyalar"; }
    fsGo(parts);
  }

  /* ---- liste: arama + sıralama ---- */
  function fsShown() {
    const q = fsQuery.trim().toLocaleLowerCase("tr");
    const all = fsList.entries.slice().sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name, "tr") : a.type === "dir" ? -1 : 1));
    return q ? all.filter((e) => e.name.toLocaleLowerCase("tr").includes(q)) : all;
  }
  const selItems = () => fsShown().filter((e) => fsSel.has(e.name));
  function clearSel() { if (!fsSel.size) return; fsSel.clear(); renderBar(); renderRows(); }
  function toggleSel(name, range) {
    const names = fsShown().map((e) => e.name);
    if (range && fsSel.size) {
      const last = names.indexOf(fsLast), now = names.indexOf(name);
      if (last >= 0 && now >= 0) {
        for (let i = Math.min(last, now); i <= Math.max(last, now); i++) fsSel.add(names[i]);
        fsLast = name; renderBar(); renderRows(); return;
      }
    }
    if (fsSel.has(name)) fsSel.delete(name); else fsSel.add(name);
    fsSel.forEach((n) => { if (inTemp(pathText(fsPath.concat(n)))) fsSel.delete(n); });
    fsLast = name;
    renderBar();
    renderRows();
  }

  function renderFs() {
    renderRail();
    const body = $("fs-body");
    body.textContent = "";
    if (fsView === "trash") { renderTrashList(body); return; }
    if (fsView === "shares" && !shareOn()) {
      fsView = "files";
      history.replaceState(null, "", "#/dosyalar");
    }
    if (fsView === "shares") { renderShareList(body); return; }
    if (!fsList) { body.append(h("p", { class: "hint-s" }, "Yükleniyor…")); return; }
    body.append(h("div", { id: "fs-bar" }), h("div", { id: "fs-rows" }));
    initDrop();
    renderBar();
    renderRows();
  }

  function renderBar() {
    const bar = $("fs-bar");
    if (!bar) return;
    const shown = fsShown(), sel = selItems();
    if (sel.length) {
      const size = sel.reduce((tot, i) => tot + (i.size || 0), 0);
      const one = sel.length === 1 ? sel[0] : null;
      bar.replaceChildren(h("div", { class: "pathfield selbar" },
        h("button", { type: "button", class: "pf-btn", title: "Seçimi bırak", "aria-label": "Seçimi bırak", onclick: clearSel }, svg("close")),
        h("span", { class: "sel-cnt" }, `${sel.length} öge seçildi · ${bytes(size)}`),
        h("span", { class: "pf-sep" }),
        h("button", { type: "button", class: "btn btn-sm", onclick: () => sel.forEach((i) => i.type !== "dir" && download(i)) }, svg("download"), "İndir"),
        h("button", { type: "button", class: "btn btn-sm", onclick: () => openMove(sel) }, svg("move"), "Taşı"),
        shareOn() ? h("button", { type: "button", class: "btn btn-sm", disabled: !one || inTemp(pathText(fsPath.concat(one.name))),
          title: one ? "" : "Paylaşım tek tek verilir", onclick: () => one && openShareCreate(one, pathText(fsPath.concat(one.name))) }, svg("share"), "Paylaş") : null,
        h("button", { type: "button", class: "btn btn-sm btn-danger", onclick: () => askTrash(sel) }, svg("trash"), "Çöpe at"),
        h("span", { class: "pf-meta" }, `${shown.length} ögenin ${sel.length} tanesi`)));
      return;
    }
    const crumbs = h("ol", { class: "crumbs" },
      h("li", null, h("button", { type: "button", class: "crumb root" + (fsPath.length ? "" : " cur"), onclick: () => fsGo([]) }, fsRoot())),
      ...fsPath.map((part, i) => h("li", null, h("button", { type: "button", class: "crumb" + (i === fsPath.length - 1 ? " cur" : ""),
        onclick: () => fsGo(fsPath.slice(0, i + 1)) }, part))));
    const sum = shown.reduce((tot, e) => tot + (e.size || 0), 0);
    const picker = h("input", { type: "file", id: "fs-file", multiple: true, class: "vis-hidden",
      onchange: (e) => { uploadFiles(e.target.files); e.target.value = ""; } });
    bar.replaceChildren(h("div", { class: "pathfield" },
      h("button", { type: "button", class: "pf-btn", title: "Üst klasör", "aria-label": "Üst klasör", disabled: !fsPath.length, onclick: () => fsGo(fsPath.slice(0, -1)) }, svg("up")),
      h("button", { type: "button", class: "pf-btn", title: "Sunucu kökü", "aria-label": "Sunucu kökü", disabled: !fsPath.length, onclick: () => fsGo([]) }, svg("home")),
      h("span", { class: "pf-sep" }),
      h("nav", { class: "pf-crumbs", "aria-label": "Konum" }, crumbs),
      h("span", { class: "fs-search" }, svg("search"),
        h("input", { type: "search", id: "fs-q", value: fsQuery, placeholder: "Bu klasörde ara", "aria-label": "Bu klasörde ara",
          autocomplete: "off", spellcheck: "false",
          oninput: (e) => { fsQuery = e.target.value; renderRows(); updateMeta(); },
          onkeydown: (e) => { if (e.key === "Escape") { fsQuery = ""; e.target.value = ""; renderRows(); updateMeta(); } } })),
      picker,
      h("button", { type: "button", class: "btn btn-sm", onclick: () => $("fs-file").click() }, svg("upload"), "Yükle"),
      h("button", { type: "button", class: "pf-btn", title: "Yeni klasör", "aria-label": "Yeni klasör",
        onclick: () => { fsAdding = true; renderRows(); const i = $("nf-name"); if (i) i.focus(); } }, svg("plus")),
      h("span", { class: "pf-meta", id: "fs-meta" }, `${shown.length} öge · ${bytes(sum)}`)));
  }
  function updateMeta() {
    const meta = $("fs-meta");
    if (!meta) return;
    const shown = fsShown();
    meta.textContent = fsQuery.trim()
      ? `${shown.length} sonuç`
      : `${shown.length} öge · ${bytes(shown.reduce((tot, e) => tot + (e.size || 0), 0))}`;
  }

  function renderRows() {
    const box = $("fs-rows");
    if (!box) return;
    const shown = fsShown();
    const kids = [];
    if (inTemp(pathText(fsPath))) {
      kids.push(h("div", { class: "offbar" }, h("div", null, h("strong", null, "qBittorrent bu klasöre yazıyor. "),
        h("span", null, "Buradaki dosyaları taşımak ya da silmek süren indirmeyi bozar."))));
    }
    const table = h("div", { class: "table fs-t" + (dragDepth ? " dragging" : ""), id: "fs-table" },
      dragDepth ? h("div", { class: "droptip" }, svg("upload"), h("span", null, "Bırakın — "), h("b", null, fsHere()), h("span", null, " içine yüklenir")) : null,
      h("div", { class: "tr head" }, h("span", null, ""), h("span", null, "Ad"), h("span", { class: "c-size" }, "Boyut"),
        h("span", { class: "c-date" }, "Değiştirilme"), h("span", null, "")),
      ...fsUps.filter((u) => u.path === pathText(fsPath)).map(upRow),
      ...shown.map(fsRow));
    if (fsAdding) table.append(newFolderRow());
    if (!shown.length && !fsAdding && !fsUps.length) {
      table.append(h("div", { class: "empty-row" },
        h("strong", null, fsQuery.trim() ? "Eşleşen öge yok" : "Bu klasör boş"),
        h("span", null, fsQuery.trim() ? "Aramayı değiştirin ya da Esc ile temizleyin." : "Dosyaları buraya sürükleyin ya da Yükle ile seçin.")));
    }
    kids.push(table);
    if (fsList.skipped) kids.push(h("p", { class: "hint-s" }, `${fsList.skipped} öge gösterilmedi (adı geçersiz).`));
    box.replaceChildren(...kids);
  }

  /* ---- yükleme: hedef listenin kendisi, ilerleme satırın içinde (DD-145) ---- */
  function upRow(u) {
    const pct = u.size ? Math.min(100, Math.round((100 * u.sent) / u.size)) : 0;
    return h("div", { class: "tr up" + (u.state === "wait" ? " wait" : "") + (u.state === "err" ? " err" : ""), id: `up-${u.id}` },
      h("span", { class: "c-sel" }),
      h("span", { class: "fname" }, h("span", { class: "ticon t-file" }, svg("upload")),
        h("span", null, h("strong", null, u.name),
          h("span", { class: "uprog" }, h("i", { id: `upb-${u.id}`, style: { width: `${pct}%` } })))),
      h("span", { class: "c-size" }, bytes(u.size)),
      h("span", { class: "c-date", id: `upm-${u.id}` }, upText(u, pct)),
      h("span", { class: "acts" }, h("button", { type: "button", class: "ib del", title: "İptal", "aria-label": "Yüklemeyi iptal et",
        onclick: () => cancelUp(u) }, svg("close"))));
  }
  const upText = (u, pct) => (u.state === "err" ? u.error || "yüklenemedi" : u.state === "wait" ? "sırada" : `%${pct}`);
  function upTick(u) {
    const bar = $(`upb-${u.id}`), meta = $(`upm-${u.id}`);
    const pct = u.size ? Math.min(100, Math.round((100 * u.sent) / u.size)) : 0;
    if (bar) bar.style.width = `${pct}%`;
    if (meta) meta.textContent = upText(u, pct);
  }
  function uploadFiles(list) {
    const here = pathText(fsPath);
    const files = Array.from(list || []);
    if (!files.length) return;
    // Aynı adlı öge zaten varsa dosya hiç gönderilmez: sunucu üzerine yazmaz, boşuna aktarım olmaz.
    const taken = new Set((fsList && fsList.path === here ? fsList.entries : []).map((e) => e.name));
    fsUps.filter((u) => u.path === here && u.state !== "err").forEach((u) => taken.add(u.name));
    for (const f of files) {
      const clash = taken.has(f.name);
      taken.add(f.name);
      fsUps.push({ id: ++upSeq, name: f.name, size: f.size, sent: 0, file: f, path: here,
        state: clash ? "err" : "wait", error: clash ? "zaten var; üzerine yazılmaz" : "" });
    }
    renderRows();
    pumpUp();
  }
  function pumpUp() {
    if (upBusy) return;
    const u = fsUps.find((x) => x.state === "wait");
    if (!u) return;
    upBusy = true;
    u.state = "up";
    upTick(u);
    const xhr = new XMLHttpRequest();
    u.xhr = xhr;
    xhr.open("POST", `/api/upload?path=${enc(u.path)}&name=${enc(u.name)}`);
    xhr.setRequestHeader("X-Konsol", "1");
    xhr.upload.addEventListener("progress", (e) => { u.sent = e.loaded; upTick(u); });
    xhr.addEventListener("load", () => {
      upBusy = false;
      if (xhr.status >= 200 && xhr.status < 300) {
        fsUps = fsUps.filter((x) => x !== u);
        if (u.path === pathText(fsPath)) loadFs().then(() => toast(`“${u.name}” yüklendi.`));
        else toast(`“${u.name}” yüklendi.`);
      } else {
        let message = `sunucu ${xhr.status}`;
        try { message = JSON.parse(xhr.responseText).error || message; } catch (err) { /* düz metin */ }
        u.state = "err";
        u.error = message;
        upTick(u);
      }
      pumpUp();
    });
    xhr.addEventListener("error", () => { upBusy = false; u.state = "err"; u.error = "bağlantı koptu"; upTick(u); pumpUp(); });
    xhr.addEventListener("abort", () => { upBusy = false; pumpUp(); });
    xhr.send(u.file);
  }
  function cancelUp(u) {
    if (u.xhr && u.state === "up") u.xhr.abort();
    fsUps = fsUps.filter((x) => x !== u);
    renderRows();
  }
  let dropReady = false;
  function initDrop() {
    if (dropReady) return;
    dropReady = true;
    const panel = $("fs-panel");
    const hasFiles = (e) => Array.from((e.dataTransfer && e.dataTransfer.types) || []).includes("Files");
    const setDrag = (on) => { const tb = $("fs-table"); if (tb) tb.classList.toggle("dragging", on); if (!on !== !dragDepth) renderRows(); };
    panel.addEventListener("dragenter", (e) => {
      if (fsView !== "files" || !hasFiles(e)) return;
      e.preventDefault(); dragDepth++; if (dragDepth === 1) renderRows();
    });
    panel.addEventListener("dragover", (e) => {
      if (fsView !== "files" || !hasFiles(e)) return;
      e.preventDefault(); e.dataTransfer.dropEffect = "copy";
    });
    panel.addEventListener("dragleave", (e) => {
      if (fsView !== "files" || !hasFiles(e)) return;
      dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) renderRows();
    });
    panel.addEventListener("drop", (e) => {
      if (fsView !== "files" || !hasFiles(e)) return;
      e.preventDefault(); dragDepth = 0; renderRows(); uploadFiles(e.dataTransfer.files);
    });
    for (const type of ["dragover", "drop"]) {
      document.addEventListener(type, (e) => { if (hasFiles(e)) e.preventDefault(); });
    }
  }

  const shareOf = (path) => (S.share && S.share.items || []).find((x) => x.path === path);
  function shareBtn(item, path) {
    const sh = shareOf(path);
    return h("button", { type: "button", class: "ib" + (sh ? " shared" : ""),
      title: sh ? "Paylaşım bilgileri" : "WebDAV ile paylaş",
      "aria-label": sh ? `${item.name} paylaşım bilgileri` : `${item.name} ögesini paylaş`,
      onclick: () => (sh ? openShareInfo(sh, false) : openShareCreate(item, path)) }, svg("share"));
  }
  function shareChip(path) {
    const sh = shareOf(path);
    return sh ? h("span", { class: "shchip", title: `Paylaşımda · ${S.share.host}` }, svg("share"), leftText(sh.expires)) : null;
  }

  function fsRow(item) {
    const kind = kindOf(item), dir = item.type === "dir";
    const name = fsRename === item.name
      ? h("span", { class: "fname" }, h("span", { class: `ticon t-${kind}` }, svg(dir ? "folder" : kind)),
        h("input", { type: "text", id: "rn-name", class: "inline-input", value: item.name, maxlength: "255", autocomplete: "off", spellcheck: "false",
          "aria-label": "Yeni ad",
          onkeydown: (e) => {
            if (e.key === "Escape") { fsRename = null; renderFs(); }
            if (e.key === "Enter") { e.preventDefault(); doRename(item, e.target.value.trim()); }
          },
          onblur: (e) => doRename(item, e.target.value.trim()) }))
      : h("button", { type: "button", class: "fname", onclick: () => (dir ? fsGo(fsPath.concat(item.name)) : isText(item) ? openText(item) : download(item)) },
        h("span", { class: `ticon t-${kind}` }, svg(dir ? "folder" : kind)),
        h("span", null, h("strong", null, item.name, shareChip(pathText(fsPath.concat(item.name)))),
          h("small", null, dir ? `${item.count == null ? "?" : item.count} öge` : isText(item) ? "metin dosyası" : "")));
    const here = pathText(fsPath.concat(item.name));
    const on = fsSel.has(item.name);
    // qBittorrent'in yazdığı klasör seçilmez, paylaşılmaz: süren indirme bozulmasın.
    const locked = inTemp(here) || inTemp(pathText(fsPath));
    return h("div", { class: "tr" + (on ? " on" : "") },
      h("span", { class: "c-sel" },
        locked ? null : h("button", { type: "button", class: "chk" + (on ? " on" : ""), role: "checkbox", "aria-checked": on ? "true" : "false",
          "aria-label": `${item.name} seç`, onclick: (e) => toggleSel(item.name, e.shiftKey) }, on ? svg("check") : null)),
      name,
      h("span", { class: "c-size" }, bytes(item.size)),
      h("span", { class: "c-date" }, since(item.mtime)),
      h("span", { class: "acts" },
        inTemp(here) || inTemp(pathText(fsPath)) || !shareOn() ? null : shareBtn(item, here),
        dir ? null : h("button", { type: "button", class: "ib", "aria-label": "İndir", title: "İndir", onclick: () => download(item) }, svg("download")),
        h("button", { type: "button", class: "ib", "aria-label": "Yeniden adlandır", title: "Yeniden adlandır", onclick: () => { fsRename = item.name; renderFs(); const i = $("rn-name"); if (i) { i.focus(); i.select(); } } }, svg("pencil")),
        h("button", { type: "button", class: "ib", "aria-label": "Taşı", title: "Taşı", onclick: () => openMove(item) }, svg("move")),
        h("button", { type: "button", class: "ib del", "aria-label": "Çöpe taşı", title: "Çöpe taşı", onclick: () => askTrash(item) }, svg("trash"))));
  }

  function newFolderRow() {
    const input = h("input", { type: "text", id: "nf-name", class: "inline-input", maxlength: "255", autocomplete: "off", spellcheck: "false",
      placeholder: "klasör adı", "aria-label": "Yeni klasör adı",
      onkeydown: (e) => {
        if (e.key === "Escape") { fsAdding = false; renderFs(); }
        if (e.key === "Enter") { e.preventDefault(); createFolder(e.target.value.trim()); }
      } });
    return h("div", { class: "tr" },
      h("span", { class: "c-sel" }),
      h("span", { class: "fname" }, h("span", { class: "ticon t-dir" }, svg("folder")), input),
      h("span", { class: "c-size" }, "—"), h("span", { class: "c-date" }, "—"),
      h("span", { class: "acts" }, h("button", { type: "button", class: "btn btn-quiet btn-sm", onclick: () => { fsAdding = false; renderFs(); } }, "Vazgeç")));
  }
  function createFolder(name) {
    if (!name) { fsAdding = false; renderFs(); return; }
    post("/api/mkdir", { path: pathText(fsPath), name })
      .then(() => { fsAdding = false; return loadFs(); })
      .then(() => toast(`“${name}” klasörü oluşturuldu.`))
      .catch(fail);
  }
  function doRename(item, to) {
    if (fsRename !== item.name) return;
    fsRename = null;
    if (!to || to === item.name) { renderFs(); return; }
    post("/api/rename", { path: pathText(fsPath), name: item.name, to })
      .then(() => loadFs()).then(() => toast(`“${item.name}” → “${to}”`)).catch((e) => { fail(e); renderFs(); });
  }
  function download(item) {
    const a = h("a", { href: `/api/download?path=${enc(pathText(fsPath.concat(item.name)))}`, download: item.name });
    document.body.append(a);
    a.click();
    a.remove();
  }
  /* Tek satırdan da seçim çubuğundan da çağrılır (DD-145). */
  const asList = (x) => (Array.isArray(x) ? x : [x]);
  const listLabel = (items) => (items.length === 1 ? `“${items[0].name}”` : `${items.length} öge`);
  function askTrash(what) {
    const items = asList(what);
    const size = items.reduce((tot, i) => tot + (i.size || 0), 0);
    ask({
      title: `${listLabel(items)} çöpe taşınsın mı?`, sub: `${fsHere()} · ${bytes(size)}`, calm: true,
      items: [
        ["trash", items.length === 1 ? "Öge kökteki çöp klasörüne taşınır; disk alanı boşalmaz."
          : `${items.length} öge kökteki çöp klasörüne taşınır; disk alanı boşalmaz.`],
        ["restore", "Çöp sekmesinden geri yüklenebilir."],
      ],
      go: "Çöpe taşı",
      onOk: () => post("/api/trash", { path: pathText(fsPath), names: items.map((i) => i.name) })
        .then(() => { fsSel.clear(); return Promise.all([loadFs(), loadFsState()]); })
        .then(() => toast(`${listLabel(items)} çöpe taşındı.`)).catch(fail),
    });
  }

  /* taşıma penceresi: hedef klasör ağacı */
  let MV = null;
  function openMove(what) {
    MV = { items: asList(what), dest: [], dirs: null };
    renderMove();
    $("sh").showModal();
    loadMoveDirs([]);
  }
  function loadMoveDirs(parts) {
    return api(`/api/list?path=${enc(pathText(parts))}&dirs=1`).then((r) => {
      MV.dirs = r.entries.map((e) => e.name).sort((a, b) => a.localeCompare(b, "tr"));
      renderMove();
    }).catch(fail);
  }
  function renderMove() {
    const items = MV.items, same = pathText(MV.dest) === pathText(fsPath);
    const size = items.reduce((tot, i) => tot + (i.size || 0), 0);
    const crumbs = h("ol", { class: "crumbs" },
      h("li", null, h("button", { type: "button", class: "crumb root" + (MV.dest.length ? "" : " cur"), onclick: () => { MV.dest = []; MV.dirs = null; renderMove(); loadMoveDirs([]); } }, fsRoot())),
      ...MV.dest.map((part, i) => h("li", null, h("button", { type: "button", class: "crumb" + (i === MV.dest.length - 1 ? " cur" : ""),
        onclick: () => { MV.dest = MV.dest.slice(0, i + 1); MV.dirs = null; renderMove(); loadMoveDirs(MV.dest); } }, part))));
    $("sh-body").replaceChildren(
      shHead(`${listLabel(items)} taşı`, `${fsHere()} · ${bytes(size)}`, "move"),
      h("div", { class: "pathfield" },
        h("button", { type: "button", class: "pf-btn", title: "Üst klasör", "aria-label": "Üst klasör", disabled: !MV.dest.length,
          onclick: () => { MV.dest = MV.dest.slice(0, -1); MV.dirs = null; renderMove(); loadMoveDirs(MV.dest); } }, svg("up")),
        h("span", { class: "pf-sep" }), h("nav", { class: "pf-crumbs", "aria-label": "Hedef" }, crumbs)),
      h("div", { class: "table fs-t movelist" },
        ...(MV.dirs == null ? [h("div", { class: "empty-row" }, h("span", null, "Yükleniyor…"))]
          : MV.dirs.length ? MV.dirs.map((name) => h("div", { class: "tr" },
            h("button", { type: "button", class: "fname", onclick: () => { MV.dest = MV.dest.concat(name); MV.dirs = null; renderMove(); loadMoveDirs(MV.dest); } },
              h("span", { class: "ticon t-dir" }, svg("folder")), h("span", null, h("strong", null, name)))))
            : [h("div", { class: "empty-row" }, h("span", null, "Bu klasörde alt klasör yok; buraya taşıyabilirsiniz."))])),
      h("div", { class: "infoline-s" }, svg("info"), h("span", null, "Aynı diskte taşıma anında biter; dosya kopyalanmaz. Aynı adlı bir öge varsa taşıma yapılmaz.")),
      h("div", { class: "dlg-foot" },
        h("button", { type: "button", class: "btn btn-quiet", onclick: shClose }, "Vazgeç"),
        h("button", { type: "button", class: "btn btn-primary", disabled: same, onclick: doMove },
          `Buraya taşı: ${[fsRoot(), ...MV.dest].join("/")}`)));
  }
  function doMove() {
    const items = MV.items, dest = MV.dest;
    post("/api/move", { path: pathText(fsPath), names: items.map((i) => i.name), to: pathText(dest) })
      .then(() => { shClose(); fsSel.clear(); return loadFs(); })
      .then(() => toast(`${listLabel(items)} taşındı → ${[fsRoot(), ...dest].join("/")}`))
      .catch(fail);
  }

  /* metin görüntüleyici */
  function openText(item, encName) {
    api(`/api/text?path=${enc(pathText(fsPath.concat(item.name)))}&enc=${enc(encName || "auto")}`).then((r) => {
      const pre = h("pre", { class: "textview", tabindex: "0" }, r.text);
      $("sh-body").replaceChildren(
        shHead(item.name, `${fsHere()} · ${bytes(item.size)} · ${r.encoding}`, "text"),
        r.truncated ? h("div", { class: "infoline-s" }, svg("info"), h("span", null, "Dosya büyük: yalnız ilk bölümü gösteriliyor.")) : null,
        h("div", { class: "field" },
          h("label", { for: "tv-enc" }, "Kodlama"),
          h("select", { id: "tv-enc", onchange: (e) => openText(item, e.target.value) },
            ...[["auto", "Otomatik"], ["utf-8", "UTF-8"], ["cp1254", "Türkçe (Windows-1254)"], ["cp437", "DOS (CP437)"]].map(([v, label]) =>
              h("option", { value: v, selected: (encName || "auto") === v }, label)))),
        pre,
        h("div", { class: "dlg-foot" },
          h("button", { type: "button", class: "btn btn-quiet", onclick: () => download(item) }, svg("download"), "İndir"),
          h("button", { type: "button", class: "btn btn-primary", onclick: shClose }, "Kapat")));
      if (!$("sh").open) $("sh").showModal();
    }).catch(fail);
  }

  /* paylaşımlar (DD-141): tek adres, tek hesap; hepsi aynı kökte görünür */
  const credRow = (k, v, acts, plain, cls) => h("div", { class: "cred-row" + (cls ? ` ${cls}` : "") }, h("span", { class: "k" }, k),
    h("span", { class: "v" + (plain ? " plain" : "") }, v), h("span", { class: "cred-acts" }, acts));
  // Konsol düz HTTP'den açılır: navigator.clipboard orada çalışmaz, eski yöntemle kopyalanır.
  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (e) { /* aşağıdaki eski yöntem denenir */ }
    const ta = h("textarea", { readonly: true, "aria-hidden": "true" });
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.append(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    ta.remove();
    return ok;
  }
  function copyButton(text, label) {
    const b = h("button", { type: "button", class: "ib", title: `${label} kopyala`, "aria-label": `${label} kopyala`, onclick: async () => {
      if (!(await copyText(text))) { toast("Pano kullanılamadı; değeri seçip kopyalayın."); return; }
      b.replaceChildren(svg("check"));
      setTimeout(() => b.replaceChildren(svg("copy")), 1200);
    } }, svg("copy"));
    return b;
  }
  // Infuse ve benzeri istemciler .ayc adını çözemeyebilir; aynı paylaşım IP:port ile de açılır.
  function shareIpUrl() {
    const sys = S.sys;
    if (!sys || !sys.net.tailscale || !sys.share || !sys.share.port || !sys.share.on) return "";
    return `${location.protocol}//${sys.net.tailscale}:${sys.share.port}`;
  }

  /* modül hesabı (DD-149): root arka ucundan okunur; parola yalnız göz ya da kopyala ile,
     açıkça istenince gelir, 30 sn sonra (sekme gizlenince hemen) ekrandan kalkar, hiç yoklanmaz. */
  const ACCT = {}, REVEAL = {}, acctLoading = new Set(), acctFailed = new Set();
  const REVEAL_SECONDS = 30;
  const acctUrl = (id, withPass) => `/api/konsol/moduller/${enc(id)}/hesap${withPass ? "?parola=1" : ""}`;
  function loadAccount(id) {
    if (acctLoading.has(id)) return Promise.resolve(ACCT[id]);
    acctLoading.add(id);
    return api(acctUrl(id, false)).then((a) => { ACCT[id] = a; acctFailed.delete(id); paintAccount(id); return a; })
      .catch(() => { delete ACCT[id]; acctFailed.add(id); paintAccount(id); }).finally(() => acctLoading.delete(id));
  }
  function forgetAccount(id) { hidePass(id); delete ACCT[id]; acctFailed.delete(id); }
  function revealPass(id, fresh) {
    return api(acctUrl(id, true)).then((a) => {
      ACCT[id] = Object.assign({}, a);
      delete ACCT[id].pass;
      hidePass(id);
      const r = REVEAL[id] = { pass: a.pass, left: REVEAL_SECONDS, fresh: fresh || "" };
      r.timer = setInterval(() => {
        r.left -= 1;
        if (r.left <= 0) { hidePass(id); return; }
        document.querySelectorAll(`[data-acct-left="${id}"]`).forEach((el) => { el.textContent = `${r.left} sn sonra gizlenir`; });
      }, 1000);
      paintAccount(id);
    }).catch(fail);
  }
  function hidePass(id) {
    const r = REVEAL[id];
    if (!r) return;
    clearInterval(r.timer);
    delete REVEAL[id];
    paintAccount(id);
  }
  const hideAllPass = () => Object.keys(REVEAL).forEach(hidePass);
  document.addEventListener("visibilitychange", () => { if (document.hidden) hideAllPass(); });
  function copyPassButton(id) {
    const b = h("button", { type: "button", class: "ib", title: "Parola kopyala", "aria-label": "Parola kopyala", onclick: async () => {
      let pass = REVEAL[id] && REVEAL[id].pass;
      if (!pass) {
        try { pass = (await api(acctUrl(id, true))).pass; } catch (e) { fail(e); return; }
      }
      const ok = await copyText(pass);
      pass = "";
      if (!ok) { toast("Pano kullanılamadı; parolayı gösterip seçerek kopyalayın."); return; }
      b.replaceChildren(svg("check"));
      setTimeout(() => b.replaceChildren(svg("copy")), 1200);
    } }, svg("copy"));
    return b;
  }
  // Hesap satırları; "card" modül kartında süre ve değişiklik satırını da taşır. paintAccount
  // yalnız bu öğeleri yeniler (sayfanın geri kalanı ve odak yerinde kalır).
  function accountBlock(id, variant) {
    const a = ACCT[id], r = REVEAL[id];
    const cred = h("div", { class: "cred" + (variant === "row3" ? " row3" : "") });
    if (!a && acctFailed.has(id)) {
      cred.append(h("p", { class: "hint-s" }, "Hesap okunamadı; Modüller'den Yeni parola ile yeniden üretebilirsiniz."));
    } else if (!a) {
      cred.append(h("p", { class: "hint-s" }, "Hesap okunuyor…"));
      loadAccount(id);
    } else if (id === "torrent") {
      // DD-151: qBittorrent'in geçici parolası yalnız bu açılışın günlüğündedir.
      cred.append(...[
        a.host ? credRow("Adres", a.host, [copyButton(a.host, "Adres")]) : null,
        credRow("Kullanıcı", a.user, [copyButton(a.user, "Kullanıcı")]),
        a.temp ? credRow("Geçici", r ? r.pass : "•".repeat(9), [
          h("button", { type: "button", class: "ib", title: r ? "Gizle" : "Günlükten göster", "aria-label": r ? "Geçici parolayı gizle" : "Geçici parolayı göster",
            onclick: () => (REVEAL[id] ? hidePass(id) : revealPass(id)) }, svg("eye")),
          copyPassButton(id)], false, r ? "" : "masked-row") : null,
        h("div", { class: "acct-wg" }, svg("info"), h("span", null, a.temp
          ? "qBittorrent ilk açılışta geçici parolayı günlüğüne yazar; Konsol onu oradan okur ve her yeniden başlatmada değişir. Girişten sonra parolayı qBittorrent arayüzünden (Tools → Options → WebUI) koyun."
          : "Parola qBittorrent arayüzünde ayarlanmış; Konsol onu bilmez. Unuttuysanız profildeki ayarı qBittorrent'in belgelerine göre sıfırlayın."))].filter(Boolean));
    } else {
      cred.append(...[
        a.host ? credRow("Adres", a.host, [copyButton(a.host, "Adres")]) : null,
        a.infuse ? credRow("Infuse", a.infuse, [copyButton(a.infuse, "Infuse adresi")]) : null,
        credRow("Kullanıcı", a.user, [copyButton(a.user, "Kullanıcı")]),
        credRow("Parola", r ? r.pass : "•".repeat(12), [
          h("button", { type: "button", class: "ib", title: r ? "Gizle" : "Göster", "aria-label": r ? "Parolayı gizle" : "Parolayı göster",
            onclick: () => (REVEAL[id] ? hidePass(id) : revealPass(id)) }, svg("eye")),
          copyPassButton(id)], false, (r && r.fresh ? "fresh" : "") + (r ? "" : " masked-row"))].filter(Boolean));
    }
    if (variant !== "card") {
      cred.dataset.acct = id;
      cred.dataset.variant = variant || "";
      return cred;
    }
    return h("div", { class: "acct-inner", "data-acct": id, "data-variant": "card" }, cred,
      h("div", { class: "acct-meta" },
        r && r.fresh ? h("span", { class: "fresh-msg" }, r.fresh) : h("span", null, a && a.changed ? `Son değişiklik: ${since(a.changed)}` : ""),
        r ? h("span", { "data-acct-left": id }, `${r.left} sn sonra gizlenir`) : null));
  }
  function paintAccount(id) {
    document.querySelectorAll(`[data-acct="${id}"]`).forEach((el) => el.replaceWith(accountBlock(id, el.dataset.variant)));
  }
  function renderShareList(body) {
    if (!S.share) { body.append(h("p", { class: "hint-s" }, "Yükleniyor…")); return; }
    const mod = shareMod();
    if (mod && mod.state === "durduruldu") {
      body.append(h("div", { class: "offbar" }, h("div", null, h("strong", null, "Paylaşım durduruldu. "),
        h("span", null, "Infuse ve öbür istemciler bağlanamaz; paylaşım kayıtları duruyor.")),
        h("button", { type: "button", class: "btn btn-quiet btn-sm", "data-go": "#/moduller" }, svg("stack"), "Modüller")));
    }
    body.append(h("div", { class: "offbar" }, h("div", null, h("strong", null, "Tek adres, tek hesap. "),
      h("span", null, "Paylaşılan her klasör ve dosya aşağıdaki adreste yan yana görünür · yalnız Tailscale'deki cihazlardan · salt okunur · Infuse adı çözemezse IP:port satırını kullanın"))));
    body.append(accountBlock("paylasim", "row3"));
    if (!S.share.items.length) {
      body.append(h("div", { class: "table" }, h("div", { class: "empty-row" }, h("strong", null, "Paylaşım yok"),
        h("span", null, "Dosyalar listesinde bir klasörün ya da dosyanın yanındaki paylaş simgesine basın."))));
      return;
    }
    body.append(h("div", { class: "table fs-t share-t" },
      h("div", { class: "tr head" }, h("span", null, "Paylaşılan"), h("span", { class: "c-user" }, "Eklendi"),
        h("span", { class: "c-exp" }, "Süre"), h("span", null, "")),
      ...S.share.items.map((sh) => h("div", { class: "tr" },
        h("span", { class: "fname plain" }, h("span", { class: `ticon t-${sh.type === "dir" ? "dir" : "file"}` }, svg(sh.type === "dir" ? "folder" : "file")),
          h("span", null, h("strong", null, sh.name), h("small", null, `${fsRoot()}/${sh.path}`))),
        h("span", { class: "c-user" }, shortDay(sh.created)),
        h("span", { class: "c-exp" }, leftText(sh.expires)),
        h("span", { class: "acts" },
          h("button", { type: "button", class: "btn btn-quiet btn-sm", onclick: () => openShareInfo(sh, false) }, svg("eye"), "Bilgiler"),
          h("button", { type: "button", class: "ib del", title: "Paylaşımdan çıkar",
            "aria-label": `${sh.name} ögesini paylaşımdan çıkar`, onclick: () => askUnshare(sh) }, svg("trash")))))));
  }

  let SH = null;
  function openShareCreate(item, path) {
    if (!shareOn()) return;
    if (!S.share) { loadShares().then(() => { if (S.share) openShareCreate(item, path); }); return; }
    SH = { item, path, days: 7 };
    renderShareCreate();
    $("sh").showModal();
  }
  function renderShareCreate() {
    const it = SH.item, count = S.share.items.length;
    $("sh-body").replaceChildren(
      shHead(`“${it.name}” paylaş`, `${fsRoot()}/${SH.path} · ${bytes(it.size)}`, "share"),
      h("ul", { class: "conseq calm" },
        h("li", null, svg("share"), h("span", null, count
          ? `${S.share.host} adresine eklenir; paylaşımdaki diğer ${count} ögeyle aynı kullanıcı ve parolayla açılır.`
          : `${S.share.host} adresinde açılır; adres, kullanıcı ve parola bütün paylaşımlarda aynıdır.`)),
        h("li", null, svg("folder"), h("span", null, it.type === "dir"
          ? "Yalnız bu klasör ve alt klasörleri görünür; üst klasörler ve paylaşılmayan indirmeler görünmez. Sonradan içine inen dosyalar kendiliğinden görünür."
          : "Yalnız bu dosya görünür; bulunduğu klasörün geri kalanı görünmez.")),
        h("li", null, svg("lock"), h("span", null, "Salt okunur: izlenir ve indirilir; silme, taşıma ya da yükleme yapılamaz.")),
        h("li", null, svg("globe"), h("span", null, `Yalnız Tailscale'e bağlı cihazlar açabilir; Infuse, VLC ya da Finder WebDAV olarak bağlanır${shareIpUrl() ? ` (Infuse için ${shareIpUrl()})` : ""}.`))),
      h("div", { class: "field" }, h("span", { class: "lbl" }, "Süre"),
        h("div", { class: "chips-s" }, ...DURATIONS.map(([d, label]) =>
          h("button", { type: "button", "aria-pressed": SH.days === d, onclick: () => { SH.days = d; renderShareCreate(); } }, label))),
        h("small", { class: "hint-s" }, SH.days
          ? `${dayText(now() + SH.days * 86400)} tarihinde kendiliğinden kapanır.`
          : "Siz paylaşımdan çıkarana kadar açık kalır.")),
      h("div", { class: "dlg-foot" },
        h("button", { type: "button", class: "btn btn-quiet", onclick: shClose }, "Vazgeç"),
        h("button", { type: "button", class: "btn btn-primary", id: "sh-go", onclick: createShare }, svg("share"), "Paylaşıma ekle")));
  }
  function createShare() {
    $("sh-go").disabled = true;
    post("/api/paylas", { path: SH.path, days: SH.days })
      .then((r) => loadShares().then(() => {
        openShareInfo(r.item, true);
        renderFs();
        toast(`“${r.item.name}” paylaşıma eklendi.`);
      }))
      .catch((e) => { fail(e); const go = $("sh-go"); if (go) go.disabled = false; });
  }
  function openShareInfo(sh, fresh) {
    SH = { share: sh, fresh };
    renderShareInfo();
    if (!$("sh").open) $("sh").showModal();
  }
  function renderShareInfo() {
    const sh = SH.share;
    $("sh-body").replaceChildren(
      shHead(SH.fresh ? "Paylaşıma eklendi" : `“${sh.name}” paylaşımda`, `${fsRoot()}/${sh.path}`, SH.fresh ? "check" : "share"),
      h("div", { class: "cred" }, credRow("Süre", sh.expires
        ? `${leftText(sh.expires)} · ${dayText(sh.expires)}` : "Süresiz; siz çıkarana kadar", [], true)),
      h("div", { class: "field" }, h("span", { class: "lbl" }, `Bağlantı bilgileri · ${S.share.items.length} paylaşımın hepsinde aynı`),
        accountBlock("paylasim")),
      h("div", { class: "infoline-s" }, svg("info"), h("span", null,
        `Infuse: Ekle › Paylaşım › WebDAV; "Infuse" satırındaki adresi (IP:port), kullanıcıyı ve parolayı yazın. Adı çözemeyen istemcilerde paylas.${(S.sys && S.sys.domain) || "…"} adresi çalışmaz. Bu hesabı bir kez ekleyen kişi sonraki paylaşımları da aynı yerde görür.`)),
      h("div", { class: "dlg-foot" },
        h("button", { type: "button", class: "btn btn-quiet danger-text", onclick: () => askUnshare(sh) }, "Paylaşımdan çıkar"),
        h("button", { type: "button", class: "btn btn-primary", onclick: shClose }, "Tamam")));
  }
  function askUnshare(sh) {
    if ($("sh").open) shClose();
    ask({
      title: `“${sh.name}” paylaşımdan çıkarılsın mı?`, sub: `${fsRoot()}/${sh.path}`, danger: true,
      items: [
        ["share", "Paylaşım adresinden kalkar; bağlı cihazlar bunu artık göremez."],
        ["lock", "Kullanıcı ve parola değişmez; diğer paylaşımlar açık kalır."],
        ["folder", "Dosyalar silinmez; yalnız paylaşımdan çıkar."],
      ],
      go: "Paylaşımdan çıkar",
      onOk: () => post("/api/paylas/kaldir", { name: sh.name })
        .then(() => loadShares()).then(() => { renderFs(); toast(`“${sh.name}” paylaşımdan çıkarıldı.`); }).catch(fail),
    });
  }

  /* çöp */
  function renderTrashList(body) {
    if (fsTrash == null) { body.append(h("p", { class: "hint-s" }, "Yükleniyor…")); return; }
    if (!fsTrash.length) {
      body.append(h("div", { class: "table" }, h("div", { class: "empty-row" }, h("strong", null, "Çöp boş"),
        h("span", null, "Silinen dosyalar burada görünür ve geri yüklenebilir."))));
      return;
    }
    body.append(h("div", { class: "table fs-t trash-t" },
      h("div", { class: "tr head" }, h("span", null, "Ad"), h("span", { class: "c-size" }, "Boyut"), h("span", { class: "c-date" }, "Silinme"), h("span", null, "")),
      ...fsTrash.map((t) => {
        const kind = t.type === "dir" ? "dir" : kindOf(t);
        return h("div", { class: "tr" },
          h("span", { class: "fname plain" }, h("span", { class: `ticon t-${kind}` }, svg(kind === "dir" ? "folder" : kind)),
            h("span", null, h("strong", null, t.name), h("small", null, `Nereden: /downloads${t.from ? "/" + t.from : ""}`))),
          h("span", { class: "c-size" }, bytes(t.size)),
          h("span", { class: "c-date" }, since(t.deleted || t.mtime)),
          h("span", { class: "acts" },
            h("button", { type: "button", class: "btn btn-quiet btn-sm", onclick: () => restore(t) }, svg("restore"), "Geri yükle"),
            h("button", { type: "button", class: "ib", title: "Kalıcı sil", "aria-label": "Kalıcı sil", onclick: () => askPurge(t) }, svg("trash"))));
      })));
    const total = fsTrash.reduce((sum, t) => sum + (t.size || 0), 0);
    body.append(h("button", { type: "button", class: "addrow danger", onclick: askEmptyTrash },
      h("span", { class: "plus" }, svg("trash")),
      h("span", null, h("strong", null, "Çöpü boşalt"), h("small", null, `${fsTrash.length} öge · ${bytes(total)} kalıcı silinir; geri alınamaz`))));
  }
  function restore(t) {
    post("/api/trash/restore", { ids: [t.id] })
      .then(() => Promise.all([loadTrash(), loadFsState(), fsView === "files" ? loadFs() : null]))
      .then(() => toast(`Geri yüklendi: ${t.name}`)).catch(fail);
  }
  function askPurge(t) {
    ask({
      title: `“${t.name}” kalıcı silinsin mi?`, sub: `${bytes(t.size)}`, danger: true,
      items: [["disk", `${bytes(t.size)} disk alanı boşalır.`], ["lock", "Geri alınamaz."]],
      go: "Kalıcı sil",
      onOk: () => post("/api/trash/purge", { ids: [t.id] })
        .then(() => Promise.all([loadTrash(), loadFsState()]))
        .then(() => toast(`“${t.name}” kalıcı silindi.`)).catch(fail),
    });
  }
  function askEmptyTrash() {
    const total = fsTrash.reduce((sum, t) => sum + (t.size || 0), 0);
    ask({
      title: "Çöp boşaltılsın mı?", sub: `${fsTrash.length} öge · ${bytes(total)}`, word: true, danger: true,
      items: [
        ["trash", `${fsTrash.length} öge kalıcı silinir.`],
        ["disk", `${bytes(total)} disk alanı boşalır.`],
        ["lock", "Geri alınamaz."],
      ],
      go: "Çöpü boşalt",
      onOk: () => post("/api/trash/empty", { confirm: "onayla" })
        .then((r) => Promise.all([loadTrash(), loadFsState()]).then(() => toast(`${r.purged} öge kalıcı silindi.`))).catch(fail),
    });
  }

  /* ---------- Günlük ---------- */
  let logFilter = "all";
  function renderLog() {
    $("log-filter").replaceChildren(...[["all", "Tümü"], ["wg", "WireGuard"], ["fs", "Dosyalar"], ["mod", "Modüller"]].map(([k, label]) =>
      h("button", { type: "button", class: "fchip", "aria-pressed": logFilter === k, onclick: () => { logFilter = k; renderLog(); } }, label)));
    const list = S.actions.filter((e) => logFilter === "all" || evKind(e) === logFilter);
    $("log-table").replaceChildren(...(list.length ? list.map((e) => evRow(e, true))
      : [h("div", { class: "empty-row" }, h("strong", null, "Kayıt yok"), h("span", null, "Konsol'dan yapılan değişiklikler burada görünür."))]));
  }

  /* ---------- Modüller (DD-148) ---------- */
  // Katalog sunucudan gelir (master-modul liste); burada yalnız görünüm bilgisi durur. Adres ve
  // port gibi değerler sunucudan (S.sys) gelir, burada yazılı değildir.
  const MOD_META = {
    dosya: () => {
      const root = (S.sys && S.sys.root) || "/srv";
      return { name: "Dosya yöneticisi", sub: `${root} içinde gez, yükle, taşı, çöp`, icon: "folder", tone: "t-dir", noStop: true,
        desc: `Konsol'a Dosyalar sayfasını ekler: ${root} kullanıcı alanında gezinme, yükleme, çoklu seçim, arama ve çöp.`,
        will: [["folder", "Dosyalar sayfası açılır"], ["lock", `Yalnız ${root}'ye yazar; root değil (uid 1000)`], ["info", "Paylaşım modülü buna bağlıdır"]],
        facts: ["Konsol modülü · systemd", "yalnız sunucu içi"],
        steps: [["Servis kuruluyor", "master-files-panel"], [`${root} kökü bağlanıyor`, "uid 1000"], ["Dosyalar sayfası açılıyor", ""]],
        page: ["#/dosyalar", "folder", "Dosyalar sayfasına git"], logSrc: "journalctl -u master-files-panel",
        removeWhat: [["folder", "Dosyalar sayfası kalkar, servis durur."]],
        removeLabel: "Çöpü de boşalt",
        removeKeep: `çöpteki ögeler ${root}/.cop'ta kalır.`, removeDrop: "Çöpteki ögeler kalıcı silinir." };
    },
    torrent: () => {
      const sys = S.sys || {}, d = sys.domain || "…", root = sys.root || "/srv";
      const prof = (sys.torrent && sys.torrent.profile) || "…";
      return { name: "qBittorrent", sub: "Torrent istemcisi", icon: "download", tone: "t-video", firstLogin: true,
        desc: "Debian paketiyle sunucunun kendisinde çalışır. İlk kurulumda en az ayarı bir kez yazar; sonra ayarlarına dokunmaz.",
        will: [["box", "Debian paketi qbittorrent-nox; apt güncellemeleriyle yenilenir"], ["globe", `torrent.${d} adı eklenir (arayüz yalnız sunucuda dinler)`],
          ["folder", `İndirme yeri ${root}/downloads, profil ${prof}`], ["info", "İnternete eş portu açılmaz; yalnız giden bağlantılar"]],
        facts: ["qbittorrent-nox · Debian", "arayüz yalnız sunucu"],
        steps: [["Paket kuruluyor", "apt · qbittorrent-nox"], ["Servis birimi", `profil ${prof} · indirmeler ${root}/downloads`], ["Servis başlatılıyor", "systemd"], ["Ad", `torrent.${d}`]],
        link: `torrent.${d}`, logSrc: "journalctl -u qbittorrent-nox@…",
        removeWhat: [["box", "Servis durur ve açılışta başlamaz; paket sunucuda kalır."], ["globe", `torrent.${d} adı kalkar.`]],
        removeLabel: "Profili ve torrent listesini de sil",
        removeKeep: `indirilenler ${root}/downloads'ta kalır; profil ve torrent listesi korunur.`,
        removeDrop: "Profil ve torrent listesi de silinir. İndirilen dosyalara dokunulmaz.",
        stopNote: "Süren indirmeler duraklar; başlatınca kaldığı yerden devam eder." };
    },
    wireguard: { name: "WireGuard", sub: "Cihazların sunucu üzerinden internete çıkışı", icon: "shield", tone: "t-dir", noStop: true,
      desc: "Çekirdek WireGuard katmanını kurar ve Konsol'a WireGuard sayfasını ekler. Ağları ve cihazları o sayfadan kurarsınız.",
      will: [["box", "Paketler: wireguard-tools, qrencode · çekirdek modülü"], ["shield", "Güvenlik duvarına WireGuard kancası eklenir"], ["shield", "WireGuard sayfası açılır (ilk ağ: Yapılandır)"]],
      facts: ["Debian paketleri + Konsol modülü", "port ağ kurulunca açılır"],
      steps: [["Paketler kuruluyor", "apt · wireguard-tools, qrencode"], ["Çekirdek modülü", "modprobe wireguard"], ["Güvenlik duvarı kancası", ""], ["WireGuard sayfası açılıyor", ""]],
      page: ["#/wireguard", "shield", "WireGuard sayfasına git"], logSrc: "journalctl -u wg-quick@*",
      removeWhat: [["shield", "Bütün ağlar kapanır, UDP portları ve kurallar kalkar."], ["folder", "WireGuard sayfası kalkar."]],
      removeLabel: "Ağ anahtarlarını ve profilleri de sil",
      removeKeep: "ağ anahtarları ve cihaz profilleri /etc/wireguard'da korunur; yeniden kurunca ağlar geri gelir.",
      removeDrop: "Ağ anahtarları ve bütün cihaz profilleri de silinir; cihazları yeniden eklemeniz gerekir." },
    paylasim: () => {
      const sys = S.sys || {}, d = sys.domain || "…", port = (sys.share && sys.share.port) || "…";
      const rc = (sys.share && sys.share.rclone) ? `rclone ${sys.share.rclone}` : "rclone";
      return { name: "Paylaşım", sub: "WebDAV · Infuse ve Finder", icon: "share", tone: "t-share", account: true, requires: "dosya",
        desc: "Dosyalar sayfasında paylaştıklarınızı tek adres ve tek hesapla, salt okunur sunar.",
        will: [["box", `${rc}: resmi sürüm, SHA256 doğrulanarak sunucuya iner (~30 MB)`], ["globe", `paylas.${d} adı; Infuse için Tailscale IP:${port}`],
          ["key", "Güçlü bir hesap üretilir"], ["lock", "Salt okunur; çöpü göremez, dışarı bağlanamaz"]],
        facts: [`${rc} · sunucu servisi`, `${port} · yalnız Tailscale`],
        steps: [["rclone indiriliyor", "resmi sürüm · SHA256"], ["Hesap üretiliyor", ""], ["Servis başlatılıyor", "systemd"], ["Ad ve adres açılıyor", `paylas.${d} · ${port}`]],
        logSrc: "journalctl -u master-paylasim",
        removeWhat: [["box", "Servis durur ve kalkar; rclone programı sunucuda kalır."], ["shield", `paylas.${d} adı ve ${port} kapanır.`]],
        removeLabel: "Hesabı ve paylaşım kayıtlarını da sil",
        removeKeep: "paylaşım kayıtları ve hesap korunur; yeniden kurunca aynı bağlantılar geri gelir.",
        removeDrop: "Hesap ve paylaşım kayıtları da silinir. Paylaşılan dosyalara dokunulmaz.",
        stopNote: "Infuse bağlantısı kesilir; paylaşım kayıtları durur." };
    },
  };
  const META_FALLBACK = { sub: "", icon: "box", tone: "t-text", desc: "", will: [], facts: [], steps: [], removeWhat: [], removeKeep: "", removeDrop: "", stopNote: "" };
  function metaOf(id) {
    const m = MOD_META[id];
    return Object.assign({ name: id }, META_FALLBACK, typeof m === "function" ? m() : m || {});
  }
  const modName = (detail) => metaOf(String(detail || "").split(" ")[0]).name;
  const RUNTIME = { host: ["host", "server", "Host"], konsol: ["konsol", "gauge", "Konsol"] };
  let MODS = null, modTimer = null;
  const shareMod = () => (MODS || []).find((m) => m.id === "paylasim");
  const modOn = (id) => !!((MODS || []).find((m) => m.id === id) || {}).installed;
  // DD-150: Dosyalar ve WireGuard sayfaları modülleriyle gelir. Liste gelmeden hiçbiri açık sayılmaz.
  const fsOn = () => modOn("dosya");
  const wgOn = () => modOn("wireguard");
  const shareOn = () => fsOn() && !!(shareMod() || {}).installed;
  // Sayfanın sıraya koyduğu işlemler (bağlı modül önce kurulur, en son kaldırılır).
  const modQueue = [];
  function queueRun() {
    if (!modQueue.length || (MODS || []).some((m) => m.busy)) return;
    const [id, action, veri] = modQueue.shift();
    const m = (MODS || []).find((x) => x.id === id);
    if (m) modAct(m, action, veri);
  }
  // "Diğer arayüzler": qBittorrent'in kendi arayüzü, modülü kuruluyken (DD-151).
  function paintOtherLinks() {
    const s = S.sys, on = !!(modOn("torrent") && s && s.domain), a = $("link-torrent");
    if (on) {
      a.href = `${location.protocol}//torrent.${s.domain}`;
      a.target = "_blank";
      a.rel = "noopener";
    }
    a.hidden = !on;
    $("side-other").hidden = !on;
  }
  // Menüdeki Dosyalar ve WireGuard bağlantıları modül kuruluyken görünür.
  function paintNav() {
    document.querySelectorAll('[data-route="dosyalar"]').forEach((a) => { a.hidden = !fsOn(); });
    document.querySelectorAll('[data-route="wireguard"]').forEach((a) => { a.hidden = !wgOn(); });
  }
  const modLogs = {};
  // İstek kabul edilince birim başlar ama ilerleme dosyasında bir an önceki işlemin satırı durur;
  // o arada istenen işlem gösterilir.
  const modPending = {};
  // Sayfanın başlattığı işlem bitince sonucu söyler; hesabı olan modülde yeni parolayı bir kez gösterir.
  function modDone(m, want) {
    const meta = metaOf(m.id), p = m.progress || {};
    if (p.step === "hata") { modQueue.length = 0; toast(`${meta.name}: ${p.text || "işlem başarısız"}`); return; }
    if (p.step !== "bitti") return;
    setTimeout(queueRun, 0);
    if (want === "kur") toast(`${meta.name} kuruldu.`);
    else if (want === "parola") toast(`${meta.name}: yeni parola hazır.`);
    else if (want === "kaldir") toast(`${meta.name} kaldırıldı.`);
    if (meta.account && (want === "kur" || want === "parola")) {
      acctFailed.delete(m.id);
      revealPass(m.id, want === "kur" ? "Yeni hesap — şimdi kopyalayın" : "Yeni parola — şimdi kopyalayın");
    }
  }
  function loadModules() {
    return api("/api/konsol/moduller").then((r) => {
      const wasShare = shareOn();
      MODS = r.items || [];
      MODS.forEach((m) => {
        if (!m.installed) forgetAccount(m.id);
        const want = modPending[m.id];
        if (!want) return;
        if (!m.busy) { delete modPending[m.id]; modDone(m, want); return; }
        const p = m.progress;
        if (!p || p.action !== want || p.step === "bitti" || p.step === "hata") m.progress = { action: want, step: "0", total: 0, text: "" };
      });
      paintNav();
      paintOtherLinks();
      // Kaldırılan modülün sayfasında kalınmaz; Genel bakış kartları yeniden çizilir.
      if ((current === "dosyalar" && !fsOn()) || (current === "wireguard" && !wgOn())) location.hash = "#/moduller";
      if (!wgOn()) S.wg = null;
      if (!fsOn()) S.fs = null;
      renderPeersMini();
      renderDisk();
      renderNavCounts();
      // Paylaşım kaldırılınca Dosyalar'daki eski liste, çipler ve düğmeler de gider.
      if (wasShare !== shareOn()) {
        if (!shareOn()) S.share = null;
        if (current === "dosyalar") { if (shareOn()) loadShares(); else renderFs(); }
      }
      const n = MODS.filter((m) => m.installed).length;
      $("nav-mods").textContent = MODS.length ? `${n}/${MODS.length}` : "";
      if (current === "moduller") renderModules();
      clearTimeout(modTimer);
      if (MODS.some((m) => m.busy)) modTimer = setTimeout(loadModules, 1500);
    }).catch(fail);
  }
  function modAct(m, action, veri) {
    return post(`/api/konsol/moduller/${enc(m.id)}/${action}`, { veri: !!veri })
      .then(() => { modPending[m.id] = action; m.busy = true; m.progress = { action, step: "0", total: 0, text: "" }; renderModules(); return loadModules(); }).catch(fail);
  }
  function modPill(m) {
    if (m.busy) {
      const label = { kur: "Kuruluyor", baslat: "Başlatılıyor", durdur: "Durduruluyor", kaldir: "Kaldırılıyor", parola: "Uygulanıyor" }[m.progress && m.progress.action] || "İşleniyor";
      return h("span", { class: "hm warn" }, h("span", { class: "spin", "aria-hidden": "true" }), label);
    }
    if (modQueue.some(([id]) => id === m.id)) return h("span", { class: "hm warn" }, "Sırada");
    if (!m.installed) return h("span", { class: "hm" }, "Kurulu değil");
    if (m.state === "durduruldu") return h("span", { class: "hm idle" }, "Durduruldu");
    if (m.runtime === "konsol") return m.live === "exited" ? h("span", { class: "hm warn" }, "Çalışmıyor")
      : h("span", { class: "hm ok" }, h("span", { class: "dotmark live", "aria-hidden": "true" }), "Kurulu");
    if (m.runtime === "host" && m.live !== "running") return h("span", { class: "hm warn" }, "Çalışmıyor");
    return h("span", { class: "hm ok" }, h("span", { class: "dotmark live", "aria-hidden": "true" }), "Çalışıyor");
  }
  function askNewPass(m, meta) {
    const user = (ACCT[m.id] || {}).user;
    ask({ title: `${meta.name} için yeni parola üretilsin mi?`, sub: user ? `Kullanıcı ${user} aynı kalır` : "Kullanıcı adı aynı kalır",
      calm: true, go: "Yeni parola üret",
      items: [["key", "Eski parola hemen geçersiz olur; Infuse ve öbür istemcilere yenisini girmeniz gerekir."],
        ["restart", `${meta.name} birkaç saniye yeniden başlar.`]],
      onOk: () => { hidePass(m.id); modAct(m, "parola"); } });
  }
  function modCard(m) {
    const meta = metaOf(m.id);
    const [rtCls, rtIcon, rtLabel] = RUNTIME[m.runtime] || RUNTIME.host;
    const kids = [h("div", { class: "card-head" },
      h("div", { class: "mod-who" }, h("span", { class: `svc-ico ${meta.tone}` }, svg(meta.icon)),
        h("div", null, h("h2", null, meta.name, h("span", { class: `rt-chip ${rtCls}` }, svg(rtIcon), rtLabel)), h("small", null, meta.sub))),
      h("div", { class: "head-right" }, modPill(m)))];
    const p = m.progress;
    if (m.busy && p && p.action === "kur") {
      const at = Number(p.step) || 1;
      kids.push(h("p", { class: "mod-desc" }, meta.desc),
        h("ol", { class: "steps", "aria-live": "polite" }, meta.steps.map((st, i) => {
          const [label, sub] = Array.isArray(st) ? st : [st, ""];
          return h("li", { class: "step" + (i + 1 < at ? " done" : i + 1 === at ? " now" : "") },
            h("span", { class: "mark" }, i + 1 < at ? svg("check") : i + 1 === at ? h("span", { class: "spin" }) : null),
            h("span", null, label), sub ? h("small", null, sub) : null);
        })),
        h("div", { class: "card-foot" }, h("span", { class: "hint-s" }, "Sayfadan çıkabilirsiniz; işlem sunucuda sürer.")));
    } else if (!m.installed) {
      const failed = p && p.step === "hata" && !m.busy ? p : null;
      const need = meta.requires && !modOn(meta.requires) ? (MODS || []).find((x) => x.id === meta.requires) : null;
      const queued = modQueue.some(([id]) => id === m.id);
      kids.push(h("p", { class: "mod-desc" }, meta.desc),
        h("div", { class: "acct-box" }, h("div", { class: "acct-head" }, h("span", null, "Kurunca")),
          h("ul", { class: "will" }, meta.will.map(([ic, t]) => h("li", null, svg(ic), h("span", null, t)))),
          need ? h("div", { class: "acct-wg" }, svg("info"), h("span", null, `${metaOf(need.id).name} modülüne bağlıdır; birlikte kurulur.`)) : null),
        failed ? h("div", { class: "offbar" }, h("div", null, h("strong", null, "Son işlem başarısız: "), h("span", null, failed.text))) : null,
        h("div", { class: "card-foot" },
          queued ? h("span", { class: "hint-s" }, "Önce bağlı modül kuruluyor…")
            : h("button", { type: "button", class: "btn btn-sm btn-primary", disabled: m.busy || (need && need.busy), onclick: () => {
              if (!need) { modAct(m, "kur"); return; }
              modQueue.push([m.id, "kur", false]);
              modAct(need, "kur");
            } }, svg("plus"), need ? `${metaOf(need.id).name} ile birlikte kur` : "Kur"),
          h("span", { class: "mod-facts grow" }, meta.facts.map((t) => h("span", null, t)))));
    } else {
      const failed = p && p.step === "hata" && !m.busy ? p : null;
      // Hesabı olan modülde açıklamanın yerini hesap alır (v06); qBittorrent'te ilk giriş.
      const body = meta.account
        ? [h("div", { class: "acct-head" }, h("span", null, "Hesap"),
            h("button", { type: "button", class: "linkbtn", disabled: m.busy, onclick: () => askNewPass(m, meta) }, "Yeni parola")),
          accountBlock(m.id, "card")]
        : meta.firstLogin
          ? [h("div", { class: "acct-head" }, h("span", null, "İlk giriş"), h("span", { class: "src" }, "Konsol bu hesabı yönetmez")),
            accountBlock(m.id, "card")]
          : [h("p", { class: "mod-desc" }, meta.desc)];
      if (failed) body.push(h("div", { class: "offbar" }, h("div", null, h("strong", null, "Son işlem başarısız: "), h("span", null, failed.text))));
      if (modLogs[m.id] != null) {
        body.push(h("div", { class: "logbox" },
          h("div", { class: "acct-head" }, h("span", null, "Günlük"), h("span", { class: "src" }, meta.logSrc || m.id)),
          h("pre", { tabindex: "0" }, modLogs[m.id] || "(boş)")));
      }
      const running = m.state === "calisiyor";
      const dependents = (MODS || []).filter((x) => x.installed && metaOf(x.id).requires === m.id);
      kids.push(h("div", { class: "mod-facts" }, meta.facts.map((t) => h("span", null, t))), h("div", { class: "acct-box" }, body),
        h("div", { class: "card-foot" },
          meta.noStop
            ? h("button", { type: "button", class: "btn btn-sm btn-primary", "data-go": meta.page[0] }, svg(meta.page[1]), meta.page[2])
            : running
            ? h("button", { type: "button", class: "btn btn-sm btn-quiet", disabled: m.busy, onclick: () => ask({
                title: `${meta.name} durdurulsun mu?`, sub: "Kurulu kalır; istediğinizde başlatırsınız", calm: true, go: "Durdur",
                items: [["pause", meta.stopNote], ["info", "Açılışta da kapalı kalır; başlatılana kadar çalışmaz."]],
                onOk: () => modAct(m, "durdur") }) }, svg("pause"), "Durdur")
            : h("button", { type: "button", class: "btn btn-sm btn-primary", disabled: m.busy, onclick: () => modAct(m, "baslat") }, svg("play"), "Başlat"),
          meta.link && running && S.sys && S.sys.domain
            ? h("a", { class: "btn btn-sm btn-quiet", href: `${location.protocol}//${meta.link}`, target: "_blank", rel: "noopener" }, svg(meta.icon), meta.name)
            : null,
          h("button", { type: "button", class: "btn btn-sm btn-quiet", "aria-expanded": String(modLogs[m.id] != null), onclick: () => {
            if (modLogs[m.id] != null) { delete modLogs[m.id]; renderModules(); return; }
            fetch(`/api/konsol/moduller/${enc(m.id)}/gunluk`, { headers: { "X-Konsol": "1" }, cache: "no-store" })
              .then((r) => r.text()).then((txt) => { modLogs[m.id] = txt; renderModules(); }).catch(fail);
          } }, svg("list"), modLogs[m.id] != null ? "Günlüğü gizle" : "Günlük"),
          h("button", { type: "button", class: "btn btn-sm btn-quiet danger-text grow", disabled: m.busy || dependents.some((d) => d.busy), onclick: () => {
            const box = h("input", { type: "checkbox", id: "mod-veri" });
            const names = dependents.map((d) => metaOf(d.id).name).join(", ");
            // Türkçe ek uyumu: son ünlüye göre "da" / "de".
            const daDe = (w) => (/[aıou][^aeıioöuü]*$/i.test(w) ? "da" : "de");
            ask({ title: `${meta.name} kaldırılsın mı?`,
              sub: dependents.length ? `${names} ${daDe(names)} kaldırılır (buna bağlı)` : "Modül ve açtığı her şey kalkar",
              go: dependents.length ? "Birlikte kaldır" : "Kaldır", danger: true,
              items: [...meta.removeWhat, ...dependents.map((d) => [metaOf(d.id).icon, `${metaOf(d.id).name} buna bağlı olduğu için önce o kaldırılır; hesabı ve kayıtları korunur.`]),
                ["folder", "Kullanıcı alanındaki dosyalarınıza dokunulmaz."]],
              extra: h("label", { class: "opt", for: "mod-veri" }, box, h("span", null, meta.removeLabel || "Modülün verisini de sil", h("small", null, `${meta.removeDrop} İşaretlemezseniz: ${meta.removeKeep}`))),
              onOk: () => {
                if (!dependents.length) { modAct(m, "kaldir", box.checked); return; }
                dependents.slice(1).forEach((d) => modQueue.push([d.id, "kaldir", false]));
                modQueue.push([m.id, "kaldir", box.checked]);
                modAct(dependents[0], "kaldir", false);
              } });
          } }, svg("trash"), "Kaldır")));
    }
    return h("article", { class: "card span-6 mod" + (m.installed || m.busy ? "" : " absent"), id: `modc-${m.id}`, "aria-busy": String(!!m.busy) }, kids);
  }
  function renderModules() {
    const sys = S.sys || {};
    const base = [
      ["gauge", "Konsol çekirdeği", "sayfalar, modül yöneticisi, günlük · parolasız, yalnız Tailscale"],
      ["globe", "Tailscale", sys.net && sys.net.tailscale ? `bağlı · ${sys.net.tailscale}` : "bağlı"],
      ["server", "Ad çözümleme + Caddy", "panel adresi; modüller kendi adlarını ekler"],
      ["shield", "Güvenlik duvarı", "modüller kural ekler, kaldırılınca kural kalkar"],
    ];
    $("mod-base").replaceChildren(...base.map(([ic, name, sub]) => h("div", { class: "base-item" },
      h("span", { class: "svc-ico t-dir" }, svg(ic)),
      h("div", null, h("strong", null, h("span", { class: "dotmark", "aria-hidden": "true" }), name), h("small", null, sub)))));
    if (!MODS) { $("mod-grid").replaceChildren(h("p", { class: "hint-s" }, "Yükleniyor…")); return; }
    const n = MODS.filter((m) => m.installed).length;
    $("mod-sum").textContent = `${n} kurulu · ${MODS.length - n} kurulabilir`;
    $("mod-grid").replaceChildren(...MODS.map(modCard));
  }

  /* ---------- Ayarlar (DD-155): sunucunun şu anki yapılandırması, salt okunur ---------- */
  let CFG = null, cfgFam = "v4", cfgBusy = false;
  const nfTr = new Intl.NumberFormat("tr-TR");
  const pkt = (n) => `${nfTr.format(n || 0)} pkt`;
  const hhmm = (sec) => new Date(sec * 1000).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
  // replaceChildren boş öğeyi "null" metni olarak basar: yalnız gerçek öğeler konur.
  const fill = (id, ...kids) => $(id).replaceChildren(...kids.flat(Infinity).filter(Boolean));
  function loadSettings(fresh) {
    if (cfgBusy) return;
    cfgBusy = true;
    api(fresh === true ? "/api/konsol/ayarlar?yenile=1" : "/api/konsol/ayarlar").then((d) => { CFG = d; renderSettings(); }).catch(fail).finally(() => { cfgBusy = false; });
  }
  const srcTag = (source) => source === "base" ? h("span", { class: "tag base first" }, "Temel")
    : source === "wireguard" ? h("span", { class: "tag wgt first" }, "WireGuard")
      : h("span", { class: "tag mod first" }, metaOf(source).name);
  function rawBox(title, src, text) {
    return h("details", { class: "raw" },
      h("summary", null, svg("chev"), title, h("span", { class: "src" }, src)),
      h("div", { class: "logbox" },
        h("div", { class: "rawhead" }, h("button", { type: "button", class: "btn btn-sm btn-quiet",
          onclick: async () => toast((await copyText(text)) ? "Kopyalandı." : "Pano kullanılamadı; metni seçip kopyalayın.") },
        svg("copy"), "Kopyala")),
        h("pre", { tabindex: "0" }, text || "(boş)")));
  }
  const pnum = (port, proto) => h("span", { class: "pnum" }, String(port), proto ? h("span", { class: "pproto" }, proto) : null);
  const psym = (s) => h("span", { class: "pnum sym" }, s);
  function fwRow(num, name, count, small, cls) {
    return h("div", { class: "prow" + (cls ? ` ${cls}` : "") }, num, h("span", { class: "pname" }, name),
      count == null ? h("span") : h("span", { class: "cnt" + (cls === "deny" && count > 0 ? " hot" : "") }, pkt(count)),
      small ? h("small", null, small) : null);
  }
  const fwGroup = (dot, title, iface, desc, rows) => h("section", { class: "pgroup", "aria-label": title },
    h("div", { class: "pg-head" }, h("span", { class: `pdot ${dot}` }), h("strong", null, title), iface ? h("span", { class: "pg-n" }, iface) : null),
    h("p", { class: "pg-desc" }, desc), rows);
  const sum = (list) => list.reduce((n, e) => n + (e.pkts || 0), 0);
  function fwGroups() {
    const fam = CFG.firewall[cfgFam] || { entries: [] }, v4 = (CFG.firewall.v4 || { entries: [] }).entries;
    const by = (g) => fam.entries.filter((e) => e.group === g);
    const wanOrder = { ssh: 0, tailscale: 1, wireguard: 2, drop: 9 };
    const wanRows = by("wan").sort((a, b) => (wanOrder[a.kind] ?? 5) - (wanOrder[b.kind] ?? 5)).map((e) =>
      e.kind === "ssh" ? fwRow(pnum(e.port, e.proto), "SSH", e.pkts, srcTag("base"))
        : e.kind === "tailscale" ? fwRow(pnum(e.port, e.proto), "Tailscale", e.pkts, [srcTag("base"), " doğrudan bağlantılar için"])
          : e.kind === "wireguard" ? fwRow(pnum(e.port, e.proto), `WireGuard · ${e.label || e.iface}`, e.pkts, [srcTag("wireguard"), " ağ başına bir port"])
            : fwRow(psym("✕"), "Gerisi düşer", e.pkts, "tarama ve istenmeyen bağlantılar", "deny"));
    if (cfgFam === "v6" && v4.some((e) => e.kind === "wireguard")) {
      wanRows.splice(wanRows.length - 1, 0, fwRow(psym("—"), "WireGuard", null, "IPv6'da açılmaz; uç nokta IPv4"));
    }
    const groups = [fwGroup("wan", "İnternet", CFG.wan.iface, "Yalnız bunlar açık", wanRows)];
    const ts = by("ts");
    if (ts.length) {
      groups.push(fwGroup("ts", "Tailscale", CFG.ts_if, "Tailnet'teki cihazlar",
        fwRow(psym("hepsi"), "Konsol, adlar ve modüller", sum(ts), "Sınırlamak Tailscale ACL'leriyle yapılır")));
    }
    const wgIfs = [...new Set(fam.entries.filter((e) => e.group.startsWith("wg:")).map((e) => e.group.slice(3)))].sort();
    for (const iface of wgIfs) {
      const es = by("wg:" + iface), label = (v4.find((e) => e.kind === "wireguard" && e.iface === iface) || {}).label || "";
      const nat = es.find((e) => e.kind === "nat");
      const rows = [];
      for (const e of es.filter((x) => x.kind === "ui")) {
        const names = e.ports.map((pp) => (pp.name === "qbittorrent" ? "qBittorrent arayüzü" : "Arayüz"));
        rows.push(fwRow(pnum(e.ports.map((pp) => pp.port).join(","), e.proto), names.join(", "), e.pkts, `yalnız ${e.addr} adresinde`));
      }
      for (const e of es.filter((x) => x.kind === "ping")) rows.push(fwRow(psym("ping"), "Sunucu adresi", e.pkts, e.addr));
      const egress = es.filter((x) => x.kind === "egress");
      if (egress.length) {
        rows.push(fwRow(psym("→"), "İnternete çıkış", sum(egress),
          nat ? `${nat.subnet} ${CFG.wan.iface} üzerinden maskelenir` : "maskeleme kuralı yok"));
      }
      const drops = es.filter((x) => ["drop", "fwd-drop", "fwd-in-drop"].includes(x.kind));
      if (drops.length) rows.push(fwRow(psym("✕"), "Gerisi düşer", sum(drops), "tailnet, SSH ve öbür ağlar kapalı", "deny"));
      const ui = es.some((x) => x.kind === "ui");
      groups.push(fwGroup("wg", "WireGuard", iface, `${label ? label + " · " : ""}${ui ? "internet + arayüzler" : "yalnız internet"}`, rows));
    }
    const self = by("self"), icmp = self.filter((e) => e.kind === "icmp6");
    const selfRows = self.filter((e) => e.kind !== "icmp6").map((e) => e.kind === "lo"
      ? fwRow(psym("lo"), "Yerel servisler", e.pkts, "127.0.0.1'deki arka uçlar")
      : fwRow(psym("↩"), "Kurulmuş bağlantıların dönüşü", e.pkts));
    if (icmp.length) selfRows.push(fwRow(psym("icmp6"), "Komşu bulma, ping", sum(icmp), "IPv6'nın çalışması için gerekli"));
    groups.push(fwGroup("lo", "Sunucunun kendisi", "lo", "Her zaman açık", selfRows));
    const other = by("other");
    if (other.length) {
      groups.push(fwGroup("wan", "Tanımsız kurallar", "", "Konsol bu kuralları tanımıyor: elle eklenmiş ya da eski olabilir",
        other.map((e) => fwRow(psym("?"), h("code", null, e.spec), e.pkts, null, "deny"))));
    }
    return groups;
  }
  function paintFirewall() {
    const fw = CFG.firewall, fam = fw[cfgFam] || { entries: [], raw: "", readable: false };
    const seg = h("span", { class: "seg", role: "group", "aria-label": "Adres ailesi" },
      ["v4", "v6"].map((f) => h("button", { type: "button", "aria-pressed": String(cfgFam === f),
        onclick: () => { cfgFam = f; paintFirewall(); } }, f === "v4" ? "IPv4" : "IPv6")));
    fill("cfg-fw", 
      h("div", { class: "card-head" }, h("h2", null, svg("shield"), "Güvenlik duvarı"),
        h("div", { class: "head-right" },
          fw.ok ? h("span", { class: "hm ok" }, h("span", { class: "dotmark live", "aria-hidden": "true" }), "Politika yerinde")
            : h("span", { class: "hm warn", title: fw.check }, "Denetim uyardı"), seg)),
      h("p", { class: "lede" }, "Sunucuya gelen bağlantılar geldiği arayüze göre ayrılır. Aşağıdakiler açık; listede olmayan her yeni bağlantı düşer. Sayılar açılıştan beri kurala takılan paketlerdir."),
      fw.ok ? null : h("div", { class: "warnline" }, svg("info"), h("span", null, fw.check || "Denetim başarısız.")),
      fam.readable ? null : h("div", { class: "warnline" }, svg("info"), h("span", null, "Kuralların bir kısmı okunamadı.")),
      h("div", { class: "portgrid rules" }, fwGroups()),
      rawBox("Ham kurallar", cfgFam === "v4" ? "iptables -S" : "ip6tables -S", fam.raw),
      h("div", { class: "card-foot" }, h("span", null, "Kuralları ", h("span", { class: "mono" }, "master-firewall"), " yazar; Konsol yalnız okur."),
        h("span", null, "Değişir: SSH portu kurulumla · WireGuard portları WireGuard sayfasından")));
  }
  const isIpPort = (a) => /^\d+\.\d+\.\d+\.\d+:\d+$/.test(a);
  function webDesc(e) {
    if (e.source === "wireguard") return `WireGuard'dan · ${e.label || e.iface}`;
    const extra = isIpPort(e.address) ? " · ad çözmeyen cihazlar için (ör. Infuse)" : "";
    if (e.source === "base") return (e.address.startsWith("panel.") ? "Konsol" : e.address.startsWith("health.") ? "kurulum denetimi" : "") + extra;
    return metaOf(e.source).name + extra;
  }
  function webHop(r, many) {
    const arrow = svg("arrow");
    const path = r.path ? h("code", null, r.path) : many ? h("span", { class: "muted" }, "diğer") : null;
    const what = r.kind === "proxy" ? h("code", null, r.to) : r.kind === "files" ? "sayfa dosyaları"
      : r.kind === "respond" ? `sabit yanıt “${r.to}”` : h("span", null, "→ ", h("code", null, r.to));
    return h("span", { class: "hop" }, path ? [path, arrow] : null, what);
  }
  function paintWeb() {
    const w = CFG.web, names = w.entries.filter((e) => !isIpPort(e.address)).length;
    const rows = w.entries.map((e) => h("div", { class: "tr" },
      h("span", { class: "a" }, e.address, h("small", null, webDesc(e))),
      h("span", { class: "to" }, e.routes.map((r) => webHop(r, e.routes.length > 1))),
      h("span", { class: "who" }, srcTag(e.source), h("span", { class: "tag" }, e.access === "wireguard" ? `WireGuard · ${e.label || e.iface}` : "Tailscale"))));
    fill("cfg-web", 
      h("div", { class: "card-head" }, h("h2", null, svg("globe"), "Web adresleri"),
        h("div", { class: "head-right" }, h("span", { class: "hm" }, `Caddy · ${names} ad, ${w.entries.length - names} IP adresi`))),
      h("div", { class: "table addr-t" }, h("div", { class: "tr head" }, h("span", null, "Adres"), h("span", null, "Nereye gider"), h("span", null, "Kaynak · erişim")), rows),
      rawBox("Ham yapılandırma", "Caddyfile · moduller/*.caddy · Caddyfile.wg", w.raw.map((f) => `# ${f.file}\n${f.text.trim()}`).join("\n\n")),
      h("div", { class: "card-foot" }, h("span", null, "Caddy yalnız Tailscale adresinde ve WireGuard sunucu adreslerinde dinler; HTTPS yok, iki tünel de zaten şifreli.")));
  }
  function paintDns() {
    const d = CFG.dns;
    fill("cfg-dns", 
      h("div", { class: "card-head" }, h("h2", null, svg("route"), "Ad çözümü"), h("div", { class: "head-right" }, h("span", { class: "hm" }, "dnsmasq"))),
      h("dl", { class: "facts" },
        h("dt", null, "Dinler"), h("dd", null, h("span", { class: "mono" }, d.listen.join(", ") || "—"), " · 53 udp+tcp"),
        h("dt", null, "Yanıtlar"), h("dd", null, d.domains.length ? ["yalnız ", h("span", { class: "mono" }, d.domains.map((x) => "." + x).join(", ")), "; başka her ada ", h("span", { class: "mono" }, "REFUSED")] : "—"),
        h("dt", null, "DHCP"), h("dd", null, d.dhcp ? "açık" : "yok")),
      h("div", { class: "dnsl" }, d.names.map((n) => h("div", { class: "dn" }, h("b", null, n.name), h("span", null, n.address || n.iface),
        h("small", null, srcTag(n.source), n.source === "base" ? null : " modülle gelir, modülle gider")))),
      h("div", { class: "infoline-s" }, svg("info"), h("span", null, `Adlar ${CFG.ts_if} adresini kendiliğinden izler. Cihazların çözmesi için Tailscale yönetici panelinde: DNS → Nameserver `,
        h("span", { class: "mono" }, CFG.tailscale || "—"), `, yalnız ${CFG.domain} alanı için.`)),
      rawBox("Ham yapılandırma", "dnsmasq.d", d.raw.map((f) => `# ${f.file}\n${f.text.trim()}`).join("\n\n")));
  }
  function paintTorrent() {
    const t = CFG.torrent || { installed: false };
    const head = (pill) => h("div", { class: "card-head" }, h("h2", null, svg("download"), "qBittorrent"), h("div", { class: "head-right" }, pill));
    if (!t.installed) {
      fill("cfg-qb", head(h("span", { class: "hm" }, "Kurulu değil")),
        h("p", { class: "lede" }, "qBittorrent kurulu değil. Modüller'den kurulunca indirme yeri ve portları burada görünür."),
        h("div", null, h("button", { type: "button", class: "btn btn-sm", "data-go": "#/moduller" }, svg("stack"), "Modüller")));
      return;
    }
    if (t.error) {
      fill("cfg-qb", head(h("span", { class: "hm warn" }, "Okunamadı")), h("div", { class: "warnline" }, svg("info"), h("span", null, t.error)));
      return;
    }
    const bad = !t.save_inside || (t.temp_on && !t.temp_inside);
    const mark = (ok) => ok ? h("span", { class: "path-ok" }, "✓ Dosyalar sayfasındaki klasör") : h("span", { class: "path-bad" }, "✕ qBittorrent buraya yazamaz");
    fill("cfg-qb", 
      head(bad ? h("span", { class: "hm warn" }, "İndirme yeri yazılamıyor") : h("span", { class: "hm ok" }, "İndirme yeri Dosyalar'da görünüyor")),
      h("dl", { class: "facts" },
        h("dt", null, "İndirme yeri"), h("dd", null, h("span", { class: "mono" }, t.save || "—"), " ", mark(t.save_inside)),
        h("dt", null, "Yarım indirmeler"), h("dd", null, t.temp_on ? [h("span", { class: "mono" }, t.temp), t.temp_inside ? null : [" ", mark(false)]] : "kapalı (indirme yerinde)"),
        h("dt", null, "Profil"), h("dd", { class: "mono" }, t.profile),
        h("dt", null, "Arayüz"), h("dd", null, h("span", { class: "mono" }, t.ui), " → ", h("span", { class: "mono" }, `torrent.${CFG.domain}`)),
        h("dt", null, "Eş portu"), h("dd", null, h("span", { class: "mono" }, String(t.peer_port || "—")), h("span", { class: "muted" }, " · internetten kapalı; qBittorrent yalnız dışa bağlanır"))),
      bad ? h("div", { class: "warnline" }, svg("info"), h("span", null, "qBittorrent yalnız ", h("span", { class: "mono" }, t.downloads),
        " altına yazabilir (kum havuzu). Bu klasöre inen torrentler hata verir ve Dosyalar'da görünmez. qBittorrent → Tools → Options → Downloads'tan düzeltin.")) : null,
      h("div", { class: "card-foot" }, h("span", null, "Kaynak: ", h("span", { class: "mono" }, "qBittorrent.conf"), " — yalnız yol ve port satırları okunur, parola asla."),
        h("span", null, "Ayarlar qBittorrent'indir; kurulum dokunmaz.")));
  }
  function renderSettings() {
    const stamp = $("cfg-stamp");
    if (stamp) stamp.textContent = CFG ? `Son okuma ${hhmm(CFG.read_at)}` : "Okunuyor…";
    if (!CFG) {
      for (const id of ["cfg-fw", "cfg-web", "cfg-dns", "cfg-qb"]) $(id).replaceChildren(h("p", { class: "hint-s" }, "Okunuyor…"));
      return;
    }
    fill("cfg-sum", 
      h("div", null, h("dt", null, "Alan adı"), h("dd", null, CFG.domain), h("small", null, "kurulum.env")),
      h("div", null, h("dt", { lang: "en" }, "Tailscale"), h("dd", null, CFG.tailscale || "—"), h("small", null, CFG.ts_if)),
      h("div", null, h("dt", null, "İnternet"), h("dd", null, CFG.wan.ipv4 || "—"), h("small", null, CFG.wan.iface)),
      h("div", null, h("dt", null, "Kurulum"), h("dd", null, (CFG.version.match(/v2-\d+$/) || [CFG.version])[0]), h("small", null, CFG.version)));
    paintFirewall();
    paintWeb();
    paintDns();
    paintTorrent();
  }
  document.addEventListener("click", (e) => {
    const j = e.target.closest("[data-jump]");
    if (j && $(j.dataset.jump)) $(j.dataset.jump).scrollIntoView({ behavior: "smooth", block: "start" });
  });

  /* ---------- yönlendirme ---------- */
  const ROUTES = {
    genel: { title: "Genel bakış", eyebrow: "Sunucu durumu",
      actions: () => [h("button", { type: "button", class: "btn btn-quiet", onclick: () => refreshAll().then(() => toast("Durum yenilendi.")) }, svg("refresh"), "Yenile")] },
    wireguard: { title: "WireGuard", eyebrow: "Cihazlar ve ağlar", actions: () => [], render: renderWg },
    dosyalar: { title: "Dosyalar", eyebrow: "Sunucu alanı, paylaşımlar ve çöp", actions: () => [],
      render: () => { renderFs(); if (fsView === "trash") loadTrash(); else if (fsView === "shares") loadShares(); else if (!fsList) loadFs(); } },
    moduller: { title: "Modüller", eyebrow: "Temiz kurulumda yalnız temel · gerisi buradan", actions: () => [], render: () => { renderModules(); loadModules(); } },
    gunluk: { title: "Günlük", eyebrow: "Konsol'dan yapılan işlemler", actions: () => [], render: () => { renderLog(); loadActions(); } },
    ayarlar: { title: "Ayarlar", eyebrow: "Sunucunun şu anki yapılandırması · salt okunur",
      actions: () => [h("span", { class: "hm", id: "cfg-stamp" }, "Okunuyor…"),
        h("button", { type: "button", class: "btn btn-quiet", onclick: () => loadSettings(true) }, svg("refresh"), "Yenile")],
      render: () => { renderSettings(); loadSettings(); } },
  };
  const ADD_ROUTE = { title: "Arayüz ekle", eyebrow: "WireGuard · yeni ağ", first: true,
    actions: () => [h("button", { type: "button", class: "btn btn-quiet", "data-go": "#/wireguard" }, svg("back"), "WireGuard")], render: renderAddNet };
  let current = "genel";
  const view = () => current;
  function route() {
    const raw = location.hash.replace(/^#\/?/, "").split("/");
    let key = ROUTES[raw[0]] ? raw[0] : "genel";
    // DD-150: modülü kurulu olmayan sayfa açılmaz; Modüller'e gidilir.
    if (MODS && ((key === "dosyalar" && !fsOn()) || (key === "wireguard" && !wgOn()))) {
      history.replaceState(null, "", "#/moduller");
      key = "moduller";
    }
    if (key === "dosyalar") fsView = raw[1] === "cop" ? "trash" : raw[1] === "paylasim" ? "shares" : "files";
    const v = key === "wireguard" && raw[1] === "ekle" ? "wgadd" : key;
    const r = v === "wgadd" ? ADD_ROUTE : ROUTES[key];
    if (key !== current) hideAllPass();
    current = key;
    document.querySelectorAll("[data-view]").forEach((s) => { s.hidden = s.dataset.view !== v; });
    document.querySelectorAll("[data-route]").forEach((a) => {
      if (a.dataset.route === key) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    });
    $("title").textContent = v === "wgadd" && S.wg && !nets().length ? "WireGuard'ı yapılandır" : r.title;
    $("eyebrow").textContent = S.sys && v !== "wgadd" ? `${S.sys.host} · ${S.sys.os}` : r.eyebrow;
    $("top-actions").replaceChildren(...r.actions());
    if (r.render) r.render();
    window.scrollTo({ top: 0 });
  }
  window.addEventListener("hashchange", route);
  document.addEventListener("click", (e) => {
    const go = e.target.closest("[data-go]");
    if (go && go.dataset.go) location.hash = go.dataset.go;
  });

  /* ---------- canlı ---------- */
  // DD-150: WireGuard ve dosya arka ucu yalnız modülleri kuruluyken sorulur.
  function refreshAll() {
    return Promise.all([wgOn() ? loadWg() : null, loadSystem(), fsOn() ? loadFsState() : null, loadActions()]);
  }
  loadModules().then(refreshAll).then(() => { route(); if (fsOn()) loadFs(); });
  setInterval(() => {
    if (document.hidden) return;
    if (wgOn()) loadWg();
    loadSystem();
    if (current === "genel" || current === "gunluk") loadActions();
    if (current === "dosyalar" && fsOn()) { loadFsState(); if (fsView === "shares") loadShares(); }
    if (current === "moduller" && !(MODS || []).some((m) => m.busy)) loadModules();
  }, 10000);
})();
