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
    boxOpen: '<path d="M9 6L3 3 1 6l6 3 2-3 6-3 2 3-6 3-2-3M3 7v6l6 3 6-3V7M9 10v6"/>',
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
    const init = { method: opts.method || "GET", headers, credentials: "same-origin", cache: "no-store", signal: opts.signal };
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
  let resourceBusy = false, resourceReceived = 0, resourceFailed = false;
  async function loadSystem() {
    if (resourceBusy) return;
    resourceBusy = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12000);
    try {
      S.sys = await api("/api/konsol/kaynaklar", { signal: controller.signal });
      resourceReceived = performance.now(); resourceFailed = false;
      paintSystem();
    } catch (_err) {
      resourceFailed = true; paintResources();
    } finally { clearTimeout(timeout); resourceBusy = false; }
  }
  function loadActions() {
    return api("/api/wg/islemler").then((s) => { S.actions = s.items || []; paintActions(); }).catch(fail);
  }
  function loadFsState() {
    return api("/api/state").then((s) => { S.fs = s; paintFsState(); }).catch(fail);
  }
  // Folder sharing is a built-in Files capability.
  function loadShares() {
    if (sharesPage.interacting()) return Promise.resolve();
    const previous = S.share;
    return api("/api/konsol/paylasim").then((s) => {
      if (S.share !== previous || sharesPage.interacting()) return;
      S.share = s; if (current === "dosyalar") renderFs();
    })
      .catch((e) => { if (S.share === previous && !sharesPage.interacting()) { S.share = null; fail(e); } });
  }
  const paintWg = () => {
    if (view() !== "wireguard") return;
    if (!document.querySelector('[data-view="wgadd"]').hidden) {
      if (NA.i === null) renderAddNet();
    } else renderWg();
  };
  const paintActions = () => { if (current === "ayarlar" && settingsTab === "log") renderLog(); };
  const paintFsState = () => { if (current === "dosyalar") renderRail(); };

  /* ---------- Independent host resources (DD-160) ---------- */
  function paintResources() {
    const s = S.sys, age = s ? (performance.now() - resourceReceived) / 1000 : Infinity;
    const fresh = !!s && !resourceFailed && age <= 30;
    const cpuFresh = fresh && Number.isFinite(s.sampled_at) && s.read_at - s.sampled_at + age <= 30;
    const cpu = cpuFresh && s.cpu.length ? s.cpu[s.cpu.length - 1] : null;
    const mem = fresh && s.mem.total > 0 ? 100 * s.mem.used / s.mem.total : null;
    const disk = fresh && s.disk?.total > 0 ? 100 * (s.disk.total - s.disk.free) / s.disk.total : null;
    for (const [id, value] of [["cpu", cpu], ["mem", mem], ["disk", disk]]) {
      const known = Number.isFinite(value);
      $("resource-" + id).textContent = known ? "%" + Math.round(value) : "—";
      $("bar-" + id).hidden = !known;
      if (known) $("bar-" + id).value = Math.max(0, Math.min(100, value));
    }
    $("detail-cpu").textContent = Number.isFinite(cpu) ? s.cores + " çekirdek" : fresh ? "Örnek bekleniyor" : "Güncel ölçüm yok";
    $("detail-mem").textContent = Number.isFinite(mem) ? bytes(s.mem.used) + " / " + bytes(s.mem.total) : "Güncel ölçüm yok";
    $("detail-disk").textContent = Number.isFinite(disk) ? bytes(s.disk.total - s.disk.free) + " / " + bytes(s.disk.total) + " · " + bytes(s.disk.free) + " boş · " + s.root : "Güncel ölçüm yok";
    const status = !s && !resourceFailed ? "Kaynaklar okunuyor…" : !fresh ? "Bağlantı yok · ölçümler eski" : !cpuFresh ? "İşlemci örneği bekleniyor" : "Sunucu kaynakları · canlı";
    if ($("resource-status").textContent !== status) $("resource-status").textContent = status;
  }
  function paintSystem() {
    const s = S.sys;
    if (!s) return;
    $("brand-host").textContent = s.host;
    $("brand-host-m").textContent = s.host;
    $("brand-sub").textContent = s.domain ? "panel." + s.domain : "Konsol";
    document.title = s.host + " · Konsol";
    $("foot-version").textContent = s.version || "—";
    $("foot-ts").textContent = s.net.tailscale || "—";
    paintResources();
    if (current === "ayarlar" && settingsTab === "system") renderSettings();
    if (current === "torrent") renderTorrentStatus();
  }

  /* ---------- Audit log, shown only in Settings ---------- */
  const ACTION_TEXT = {
    ekle: (e) => `${e.detail} eklendi`, cikar: (e) => `${e.detail} silindi`,
    dns: (e) => `${e.detail} için DNS değişti`, keepalive: (e) => `${e.detail.split(" ")[0]} için keepalive ${e.detail.split(" ")[1] || ""} sn`,
    "ag-ayarlar": (e) => `${e.detail} varsayılan DNS / local erişim ayarları güncellendi`,
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
          h("button", { type: "button", class: "nt-act", title: `${n.iface} ayarları: DNS, local erişim ve yeniden üret`, "aria-label": `${n.iface} arayüz ayarları`, onclick: () => openNetSettings(n) }, svg("sliders")),
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

  function openNetSettings(n) {
    let local = n.scope === "ui", busy = false, picker;
    const error = h("p", {class:"err-s", role:"alert", hidden:true});
    const dnsBox = h("div", {class:"sugg", role:"radiogroup", "aria-label":"Varsayılan DNS"});
    const localText = h("small", {class:"hint-s", id:"wn-local-desc"});
    const toggle = h("button", {type:"button", class:"sw", role:"switch", "aria-label":"Local erişim",
      "aria-describedby":"wn-local-desc", onclick:()=>{ local=!local; update(); }});
    const save = h("button", {type:"submit", class:"btn btn-primary", id:"wn-save"}, "Ayarları kaydet");
    const fields = h("fieldset", {class:"wg-net-fields"},
      h("div", {class:"field"}, h("span", {class:"lbl"}, "Varsayılan DNS"), dnsBox,
        h("small", {class:"hint-s"}, "Yalnız yeni eklenecek cihazlara önerilir. Mevcut cihazların DNS ayarı ve QR/profili değişmez; cihazın Düzenle menüsünden ayrıca değiştirilebilir.")),
      h("div", {class:"wg-net-local"}, h("div", null, h("strong", null, "Local erişim"), localText), toggle),
      h("p", {class:"hint-s"}, "Local erişim yalnız qBittorrent arayüzünü kapsar (uygulama kuruluysa). Konsol, SSH, WebDAV ve diğer ağlar açılmaz. Ek güvenlik duvarı kısıtlamaları korunur."),
      h("p", {class:"hint-s"}, "Kaydet anahtarları, cihazları, portu ve adresleri değiştirmez. Kapalı bir ağı başlatmaz."), error,
      h("div", {class:"dlg-foot"}, h("button", {type:"button", class:"btn btn-quiet", onclick:shClose}, "Vazgeç"), save),
      h("div", {class:"wg-net-danger"}, h("p", null, "Yeniden üret tüm cihaz profillerini siler ve sunucu anahtarını değiştirir. Kaydedilmemiş DNS/local seçimleri bu işlemde uygulanmaz."),
        h("button", {type:"button", class:"btn btn-sm btn-danger", onclick:()=>{shClose(); askRegen(netOf(n.iface) || n);}}, svg("refresh"), "Anahtarı yeniden üret")));
    function update() {
      toggle.setAttribute("aria-checked", String(local));
      localText.textContent = local
        ? `Açık: qBittorrent arayüzü ${n.server4} adresinden kullanılabilir.`
        : "Kapalı: bu ağ yalnız internete çıkar; local arayüz erişimi kapanır.";
      const dns = picker.value();
      save.disabled = busy || !picker.check() || !dns || (dns === n.dns && local === (n.scope === "ui"));
    }
    const form = h("form", {class:"wg-net-settings", onsubmit:async event=>{
      event.preventDefault();
      if (save.disabled) return;
      busy=true; fields.disabled=true; error.hidden=true; update();
      try {
        await post(netPath(n.iface,"/ayarlar"), {scope:local?"ui":"inet",dns:picker.value(),revision:n.revision});
        shClose(); await loadWg();
        toast(`${n.iface} ayarları kaydedildi. Mevcut anahtarlar ve cihaz profilleri korundu.`);
      } catch (err) { error.textContent=err.message; error.hidden=false; }
      finally {busy=false; fields.disabled=false; update();}
    }}, fields);
    $("sh-body").replaceChildren(shHead(`${n.iface} · Arayüz ayarları`, `${labelOf(n)} · UDP ${n.port} · ${n.subnet4}`, "sliders"), form);
    picker = makeDnsPicker(dnsBox,"wn-dns",{badge:ips=>ips===n.dns?"kayıtlı":"",onChange:update});
    picker.set(n.dns); update(); $("sh").showModal(); toggle.focus();
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
    $("cf").classList.toggle("compact", !!o.compact);
    $("cf-title").textContent = o.title;
    $("cf-sub").textContent = o.sub || "";
    $("cf-sub").title = o.compact ? o.sub || "" : "";
    $("cf-sub").hidden = !o.sub;
    $("cf-list").replaceChildren(...(o.items || []).map(([ic, text]) => h("li", null, svg(ic), h("span", null, text))));
    $("cf-list").hidden = !o.items?.length;
    $("cf-list").classList.toggle("calm", !!o.calm);
    $("cf-extra").replaceChildren(...(o.extra ? [o.extra] : []));
    $("cf-extra").hidden = !o.extra;
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
  let fsFocus = "", fsLayout = "list";
  try { fsLayout = localStorage.getItem("konsol-files-view") === "cards" ? "cards" : "list"; } catch (e) { /* özel pencere */ }
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
    fsFocus = "";
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
    location.hash = v === "trash" ? "#/dosyalar/cop" : v === "shares" ? "#/dosyalar/paylasim" : v === "archives" ? "#/dosyalar/arsiv" : "#/dosyalar";
    renderFs();
    if (v === "trash") loadTrash();
    else if (v === "shares") loadShares();
    else if (v === "files" && !fsList) loadFs();
  }

  /* ---- kısayol sütunu: kök, üst klasörler, paylaşımlar, çöp, disk ---- */
  function railBtn(o) {
    return h("button", { type: "button", class: "rl" + (o.cur ? " cur" : ""), "aria-current": o.cur ? "true" : "false", title: o.title, onclick: o.onclick },
      h("span", { class: `rl-ico ${o.tone}` }, svg(o.icon)),
      h("span", { class: "rl-nm" }, o.title),
      o.count ? h("span", { class: "rl-c" }, String(o.count)) : null);
  }
  function renderRail() {
    const rail = $("fs-rail");
    rail.hidden = fsView !== "files";
    rail.replaceChildren(
      railBtn({ cur: !fsPath.length, icon: "server", tone: "t-dir", title: "Sunucu", onclick: () => fsOpen([]) }),
      ...(fsRootDirs || []).map((d) => railBtn({ cur: fsPath[0] === d.name, icon: "folder", tone: "t-dir",
        title: d.name, onclick: () => fsOpen([d.name]) })));
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
  function clearSel() { if (!fsSel.size) return; fsSel.clear(); renderDock(); renderRows(); }
  function toggleSel(name, range) {
    const names = fsShown().map((e) => e.name);
    if (range && fsSel.size) {
      const last = names.indexOf(fsLast), now = names.indexOf(name);
      if (last >= 0 && now >= 0) {
        for (let i = Math.min(last, now); i <= Math.max(last, now); i++) fsSel.add(names[i]);
        fsLast = name; renderDock(); renderRows(); return;
      }
    }
    if (fsSel.has(name)) fsSel.delete(name); else fsSel.add(name);
    fsSel.forEach((n) => { if (inTemp(pathText(fsPath.concat(n)))) fsSel.delete(n); });
    fsLast = name;
    renderDock();
    renderRows();
  }

  function renderFs() {
    renderRail();
    $("fs-tabs").replaceChildren(...[["files", "Dosyalar"], ["shares", "Paylaşımlar"], ["archives", "Arşiv işleri"], ["trash", "Çöp"]].map(([id, label]) =>
      h("button", { type: "button", "aria-pressed": fsView === id, onclick: () => fsSetView(id) }, label)));
    const body = $("fs-body");
    body.textContent = "";
    body.classList.remove("with-dock");
    if (fsView === "archives") {
      const archiveBox = h("div", {id:"archive-jobs"});
      body.append(archiveBox); archiveTools.mount(archiveBox); return;
    }
    if (fsView === "trash") { renderTrashList(body); return; }
    if (fsView === "shares" && !shareOn()) {
      fsView = "files";
      history.replaceState(null, "", "#/dosyalar");
    }
    if (fsView === "shares") { renderShareList(body); return; }
    if (!fsList) { body.append(h("p", { class: "hint-s" }, "Yükleniyor…")); return; }
    if (!fsList.entries.some((x) => x.name === fsFocus)) fsFocus = "";
    body.append(h("div", { id: "fs-bar" }), h("div", { class: "fs09-layout " + fsLayout },
      h("div", { id: "fs-rows" }), h("aside", { id: "fs-detail", class: "fs09-detail", "aria-label": "Öge ayrıntıları" })),
      h("div", { id:"fs-dock", class:"fs-dock-wrap", hidden:true }));
    initDrop();
    renderBar();
    renderRows();
    renderDetail();
  }

  function renderDock() {
    const dock = $("fs-dock");
    if (!dock) return;
    const sel = selItems();
    dock.hidden = !sel.length;
    $("fs-body").classList.toggle("with-dock", !!sel.length);
    dock.replaceChildren();
    if (sel.length) {
      const one = sel.length === 1 ? sel[0] : null;
      const canExtract = !!one && one.type !== "dir" && archiveTools.canExtract(one.name);
      const canShare = shareOn() && !!one && one.type === "dir" && !inTemp(pathText(fsPath.concat(one.name)));
      const action = (icon, label, attrs) => h("button", { type:"button", class:"fs-dock-action", ...attrs }, svg(icon), h("span", {}, label));
      dock.append(h("div", { class: "fs-dock", role:"group", "aria-label":"Seçilen ögeler için işlemler" },
        h("div", {class:"fs-dock-selection"},
          h("span", { class: "sel-cnt", "aria-live":"polite" }, `${sel.length} öge seçili`),
          h("button", { type: "button", class: "pf-btn", title: "Seçimi bırak", "aria-label": "Seçimi bırak", onclick: clearSel }, svg("close"))),
        h("div", {class:"fs-dock-actions"},
          action("download", "İndir", { disabled:sel.every(i => i.type === "dir"), onclick:() => sel.forEach(i => i.type !== "dir" && download(i)) }),
          action("move", "Taşı", { onclick:() => openMove(sel) }),
          action("box", "Arşiv oluştur", { onclick:() => archiveTools.open("zip", pathText(fsPath), sel) }),
          action("boxOpen", "Arşiv açıcı", { disabled:!canExtract, onclick:() => canExtract && archiveTools.open("unzip", pathText(fsPath), sel) }),
          action("share", "Paylaş", { disabled:!canShare, title:one ? "" : "Paylaşım tek tek verilir", onclick:() => canShare && openShareCreate(one, pathText(fsPath.concat(one.name))) }),
          action("trash", "Çöpe at", { class:"fs-dock-action fs-dock-danger", onclick:() => askTrash(sel) }))));
    }
  }
  function renderBar() {
    const bar = $("fs-bar");
    if (!bar) return;
    renderDock();
    const shown = fsShown();
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
          oninput: (e) => { fsQuery = e.target.value; renderRows(); renderDock(); updateMeta(); },
          onkeydown: (e) => { if (e.key === "Escape") { fsQuery = ""; e.target.value = ""; renderRows(); renderDock(); updateMeta(); } } })),
      h("div", { class: "fs09-view", "aria-label": "Görünüm" }, ...[["list", "Liste"], ["cards", "Kartlar"]].map(([id, label]) =>
        h("button", { type: "button", "aria-pressed": fsLayout === id, onclick: () => {
          fsLayout = id; try { localStorage.setItem("konsol-files-view", id); } catch (e) { /* özel pencere */ } renderFs();
        } }, label))),
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
    return sh ? h("span", { class: "shchip", title: sh.url }, svg("share"), sharesPage.stateText(sh)) : null;
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
    return h("div", { class: "tr" + (on ? " on" : "") + (fsFocus === item.name ? " focused" : "") },
      h("span", { class: "c-sel" },
        locked ? null : h("button", { type: "button", class: "chk" + (on ? " on" : ""), role: "checkbox", "aria-checked": on ? "true" : "false",
          "aria-label": `${item.name} seç`, onclick: (e) => toggleSel(item.name, e.shiftKey) }, on ? svg("check") : null)),
      name,
      h("span", { class: "c-size" }, bytes(item.size)),
      h("span", { class: "c-date" }, since(item.mtime)),
      h("span", { class: "acts" },
        h("button", { type: "button", class: "btn btn-sm btn-quiet fs09-info", "aria-label": `${item.name} ayrıntıları`,
          onclick: () => { fsFocus = item.name; renderRows(); renderDetail(); } }, "Ayrıntılar"),
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
    ask({
      title: items.length === 1 ? "Çöpe taşınsın mı?" : `${items.length} öge çöpe taşınsın mı?`,
      sub: items.length === 1 ? items[0].name : "", compact: true,
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
      cred.append(h("p", { class: "hint-s" }, "Hesap okunamadı. Servisin çalıştığını kontrol edip sayfayı yenileyin."));
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
          : "Parola kayıtlı; Konsol mevcut parolayı göstermez. qBittorrent sayfasından yeni kullanıcı adı veya parola belirleyebilirsiniz."))].filter(Boolean));
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
  const sharesPage = window.createSharesPage({
    h, svg, post, toast, fail, copyButton, root: fsRoot, getShares: () => S.share,
    setShares: (data) => { S.share = data; renderFs(); },
    showDialog: (title, content) => { $("sh-body").replaceChildren(shHead(title, "Klasör başına ayrı hesap · yalnız Tailscale", "share"), content); if (!$("sh").open) $("sh").showModal(); },
    closeDialog: shClose, ask,
  });
  $("sh").addEventListener("close", () => { const pw = $("dav-password"); if (pw) pw.value = ""; });
  const archiveTools = window.createArchiveTools({h, api, post, toast, fail, root:fsRoot, downloads:() => S.fs?.downloads,
    refresh:() => { loadFsState(); if (current === "dosyalar" && fsView === "files") loadFs(); },
    openFolder:(path) => fsOpen(path ? path.split("/") : []),
    showDialog:(title, content) => { $("sh-body").replaceChildren(shHead(title, "", "box"), content); if (!$("sh").open) $("sh").showModal(); },
    closeDialog:shClose});
  const renderShareList = (body) => sharesPage.list(body);
  const openShareCreate = (item, path) => sharesPage.create(item, path);
  const openShareInfo = (sh) => sharesPage.edit(sh);
  function renderDetail() {
    const box = $("fs-detail");
    if (!box) return;
    box.hidden = !fsFocus;
    box.parentElement.classList.toggle("with-detail", !!fsFocus);
    const item = fsList && fsList.entries.find((x) => x.name === fsFocus);
    if (!item) {
      box.replaceChildren(h("div", { class: "dav-empty" }, svg("folder"), h("h3", null, "Bir öge seçin"), h("p", null, "Ayrıntılar ile bilgileri ve paylaşım ayarlarını açın.")));
      return;
    }
    const path = pathText(fsPath.concat(item.name)), sh = shareOf(path), directory = item.type === "dir";
    const eligible = directory && !inTemp(path) && !(tempRel() && tempRel().startsWith(path + "/")) && !path.split("/").some((p) => p.startsWith("."));
    const action = (label, icon, fn) => h("button", { type: "button", class: "btn btn-sm btn-quiet", onclick: fn }, svg(icon), label);
    box.replaceChildren(h("div", { class: "fs09-detail-head" }, h("span", { class: "ticon t-dir" }, svg(directory ? "folder" : "file")),
      h("div", null, h("h2", null, item.name), h("small", null, `${fsRoot()}/${path}`)),
      h("button", {type:"button", class:"ib", "aria-label":"Ayrıntıları kapat", onclick:() => { fsFocus = ""; renderRows(); renderDetail(); }}, svg("close"))),
      h("div", { class: "fs09-detail-body" },
        h("div", { class: "dav-pair" }, h("small", null, directory ? "Klasör" : "Dosya"),
          h("span", null, `${bytes(item.size)} · ${directory ? (item.count ?? "?") + " öge" : "Son değişiklik " + since(item.mtime)}`)),
        h("div", { class: "dav-actions" },
          directory ? action("Klasörü aç", "folder", () => fsGo(fsPath.concat(item.name))) : action("İndir", "download", () => download(item)),
          action("Adlandır", "pencil", () => { fsRename = item.name; renderFs(); const inp = $("rn-name"); if (inp) { inp.focus(); inp.select(); } }),
          action("Taşı", "move", () => openMove(item)), action("Çöpe taşı", "trash", () => askTrash(item))),
        !inTemp(path) ? h("div", {class:"dav-actions"},
          action("Arşiv oluştur", "box", () => archiveTools.open("zip", pathText(fsPath), [item])),
          !directory && archiveTools.canExtract(item.name) ? action("Arşiv açıcı", "box", () => archiveTools.open("unzip", pathText(fsPath), [item])) : null) : null,
        sh ? sharesPage.info(sh) : !shareOn()
          ? h("p", { class: "hint-s" }, "Klasör hesabı oluşturmak için Modüller → Paylaşım'ı kurun.")
          : eligible ? h("div", { class: "dav-summary" },
            h("p", { class: "hint-s" }, "Bu klasör paylaşılmıyor. Bağımsız kullanıcı ve parolayla yalnız bu klasörü açabilirsiniz."),
            h("button", { type: "button", class: "btn btn-primary", onclick: () => openShareCreate(item, path) }, svg("share"), "WebDAV ile paylaş"))
          : h("p", { class: "hint-s" }, directory ? "Geçici/iç alan içeren klasör paylaşılmaz. Bir alt klasör seçin." : "WebDAV paylaşımı klasörlere verilir; dosyayı bir klasöre yerleştirin."),
        sharesPage.warning()));
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
            h("span", null, h("strong", null, t.name), h("small", null, `Nereden: ${fsRoot()}${t.from ? "/" + t.from : ""}`))),
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
    torrent: () => {
      const sys = S.sys || {}, d = sys.domain || "…", root = sys.root || "/srv";
      const prof = (sys.torrent && sys.torrent.profile) || "…";
      return { name: "qBittorrent", sub: "Torrent indirmelerini yönetin.", icon: "download", tone: "t-video", firstLogin: true,
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
    wireguard: { name: "WireGuard", sub: "Cihazlarınız için VPN bağlantısı.", icon: "shield", tone: "t-dir", noStop: true,
      desc: "Çekirdek WireGuard katmanını kurar ve Konsol'a WireGuard sayfasını ekler. Ağları ve cihazları o sayfadan kurarsınız.",
      will: [["box", "Paketler: wireguard-tools, qrencode · çekirdek modülü"], ["shield", "Güvenlik duvarına WireGuard kancası eklenir"], ["shield", "WireGuard sayfası açılır (ilk ağ: Yapılandır)"]],
      facts: ["Debian paketleri + Konsol modülü", "port ağ kurulunca açılır"],
      steps: [["Paketler kuruluyor", "apt · wireguard-tools, qrencode"], ["Çekirdek modülü", "modprobe wireguard"], ["Güvenlik duvarı kancası", ""], ["WireGuard sayfası açılıyor", ""]],
      page: ["#/wireguard", "shield", "WireGuard sayfasına git"], logSrc: "journalctl -u wg-quick@*",
      removeWhat: [["shield", "Bütün ağlar kapanır, UDP portları ve kurallar kalkar."], ["folder", "WireGuard sayfası kalkar."]],
      removeLabel: "Ağ anahtarlarını ve profilleri de sil",
      removeKeep: "ağ anahtarları ve cihaz profilleri /etc/wireguard'da korunur; yeniden kurunca ağlar geri gelir.",
      removeDrop: "Ağ anahtarları ve bütün cihaz profilleri de silinir; cihazları yeniden eklemeniz gerekir." },
  };
  const META_FALLBACK = { sub: "", icon: "box", tone: "t-text", desc: "", will: [], facts: [], steps: [], removeWhat: [], removeKeep: "", removeDrop: "", stopNote: "" };
  function metaOf(id) {
    const m = MOD_META[id];
    return Object.assign({ name: id }, META_FALLBACK, typeof m === "function" ? m() : m || {});
  }
  const modName = (detail) => { const id = String(detail || "").split(" ")[0]; return ({dosya:"Dosyalar", paylasim:"WebDAV"}[id] || metaOf(id).name); };
  const RUNTIME = { host: ["host", "server", "Host"], konsol: ["konsol", "gauge", "Konsol"] };
  let MODS = null, modTimer = null;
  const modOn = (id) => !!((MODS || []).find((m) => m.id === id) || {}).installed;
  // Files is built in; optional application pages follow the server registry.
  const fsOn = () => true;
  const wgOn = () => modOn("wireguard");
  const shareOn = () => true;
  // Sayfanın sıraya koyduğu işlemler (bağlı modül önce kurulur, en son kaldırılır).
  const modQueue = [];
  function queueRun() {
    if (!modQueue.length || (MODS || []).some((m) => m.busy)) return;
    const [id, action, veri] = modQueue.shift();
    const m = (MODS || []).find((x) => x.id === id);
    if (m) modAct(m, action, veri);
  }
  function paintNav() {
    document.querySelectorAll('[data-route="wireguard"]').forEach((a) => { a.hidden = !wgOn(); });
    document.querySelectorAll('[data-route="torrent"]').forEach((a) => { a.hidden = !modOn("torrent"); });
    $("installed-label").hidden = !wgOn() && !modOn("torrent");
  }
  const modLogs = {};
  const modLogLoading = new Set();
  let modSelected = null, modRenderKey = "";
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
    if (want === "kur" && m.id === "torrent") CFG = null;
    if (meta.account && (want === "kur" || want === "parola")) {
      acctFailed.delete(m.id);
      revealPass(m.id, want === "kur" ? "Yeni hesap — şimdi kopyalayın" : "Yeni parola — şimdi kopyalayın");
    }
  }
  function loadModules() {
    return api("/api/konsol/moduller").then((r) => {
      MODS = r.items || [];
      MODS.forEach((m) => {
        if (!m.installed) { forgetAccount(m.id); delete modLogs[m.id]; }
        const want = modPending[m.id];
        if (!want) return;
        if (!m.busy) { delete modPending[m.id]; modDone(m, want); return; }
        const p = m.progress;
        if (!p || p.action !== want || p.step === "bitti" || p.step === "hata") m.progress = { action: want, step: "0", total: 0, text: "" };
      });
      paintNav();
      if ((current === "wireguard" && !wgOn()) || (current === "torrent" && !modOn("torrent"))) location.hash = "#/moduller";
      if (!wgOn()) S.wg = null;
      if (current === "moduller") renderModules();
      if (current === "torrent") renderTorrentStatus();
      clearTimeout(modTimer);
      if (MODS.some((m) => m.busy)) modTimer = setTimeout(loadModules, 1500);
    }).catch(fail);
  }
  function modAct(m, action, veri) {
    return post(`/api/konsol/moduller/${enc(m.id)}/${action}`, { veri: !!veri })
      .then(() => {
        modPending[m.id] = action;
        // An unchanged poll may retain DOM handlers while replacing the catalogue objects.
        const live = (MODS || []).find(x => x.id === m.id) || m;
        live.busy = true; live.progress = { action, step: "0", total: 0, text: "" };
        renderModules(); if (current === "torrent") renderTorrentStatus(); return loadModules();
      }).catch(fail);
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
  function modRow(m) {
    const meta = metaOf(m.id), p = m.progress || {};
    const need = meta.requires && !modOn(meta.requires) ? (MODS || []).find((x) => x.id === meta.requires) : null;
    const queued = modQueue.some(([id]) => id === m.id);
    const disabled = !!(m.busy || queued || (need && need.busy));
    return h("article", { class:"store-row", id:`modc-${m.id}`, "aria-labelledby":`mod-name-${m.id}` },
      h("span", {class:`svc-ico ${meta.tone}`}, svg(meta.icon)),
      h("div", {class:"store-who"}, h("h2", {id:`mod-name-${m.id}`}, meta.name), h("p", null, meta.sub)),
      h("div", {class:"store-state", role:"status"}, modPill(m)),
      h("div", {class:"store-actions"},
        h("button", {type:"button", class:"btn btn-sm btn-quiet", id:`mod-details-${m.id}`,
          "aria-expanded":String(modSelected === m.id), "aria-controls":"mod-detail", onclick:() => {
            modSelected = modSelected === m.id ? null : m.id; renderModules();
          }}, "Ayrıntı"),
        m.installed
          ? h("button", {type:"button", class:"btn btn-sm btn-primary", id:`mod-open-${m.id}`, disabled,
              "data-go":meta.page ? meta.page[0] : "#/torrent"}, "Aç")
          : h("button", {type:"button", class:"btn btn-sm btn-primary", id:`mod-install-${m.id}`, disabled, onclick:() => {
              if (!need) { modAct(m, "kur"); return; }
              modQueue.push([m.id, "kur", false]);
              modAct(need, "kur");
            }}, need ? `${metaOf(need.id).name} ile birlikte kur` : "Kur")),
      m.busy ? h("p", {class:"store-progress", role:"status"}, p.text || "İşlem sunucuda sürüyor…")
        : p.step === "hata" ? h("p", {class:"store-progress store-error", role:"alert"}, "Son işlem başarısız: " + (p.text || "İşlem tamamlanamadı.")) : null);
  }
  function modDetail(m) {
    const meta = metaOf(m.id), p = m.progress || {};
    const [rtCls, rtIcon, rtLabel] = RUNTIME[m.runtime] || RUNTIME.host;
    const kids = [h("div", {class:"store-detail-head"}, h("h2", {id:"mod-detail-title"}, meta.name),
      h("button", {type:"button", class:"btn btn-sm btn-quiet", id:"mod-detail-close", onclick:() => {
        modSelected = null; renderModules(); $("mod-details-" + m.id)?.focus();
      }}, "Kapat")),
      h("p", {class:"mod-desc"}, meta.desc),
      h("div", {class:"mod-facts"}, h("span", {class:`rt-chip ${rtCls}`}, svg(rtIcon), rtLabel), meta.facts.map(t => h("span", null, t))),
      h("ul", {class:"will"}, meta.will.map(([ic,t]) => h("li", null, svg(ic), h("span", null, t))))];
    if (m.busy) {
      // Progress comes from the server; no timer-driven or invented step completion.
      kids.push(h("p", {class:"hint-s"}, p.text || "İşlem sunucuda sürüyor…"),
        h("p", {class:"hint-s"}, "Sayfadan çıkabilirsiniz; işlem sunucuda sürer."));
    }
    if (m.installed) {
      if (meta.firstLogin) kids.push(h("a", {href:"#/torrent", class:"linkbtn"}, "qBittorrent ayarları ve ilk giriş bilgileri"));
      const running = m.state === "calisiyor";
      const dependents = (MODS || []).filter(x => x.installed && metaOf(x.id).requires === m.id);
      kids.push(h("div", {class:"store-detail-actions"},
        meta.noStop ? null : h("button", {type:"button", class:"btn btn-sm btn-quiet", id:`mod-service-${m.id}`, disabled:!!m.busy, onclick:() => {
          if (!running) { modAct(m, "baslat"); return; }
          ask({title:`${meta.name} durdurulsun mu?`, sub:"Kurulu kalır; istediğinizde başlatırsınız", calm:true, go:"Durdur",
            items:[["pause",meta.stopNote],["info","Açılışta da kapalı kalır; başlatılana kadar çalışmaz."]], onOk:() => modAct(m,"durdur")});
        }}, svg(running ? "pause" : "play"), running ? "Durdur" : "Başlat"),
        h("button", {type:"button", class:"btn btn-sm btn-quiet", id:`mod-log-${m.id}`, disabled:!!m.busy || modLogLoading.has(m.id),
          "aria-expanded":String(modLogs[m.id] != null), "aria-controls":"mod-log-output", onclick:() => {
            if (modLogs[m.id] != null) { delete modLogs[m.id]; renderModules(); return; }
            modLogLoading.add(m.id); renderModules();
            fetch(`/api/konsol/moduller/${enc(m.id)}/gunluk`, {headers:{"X-Konsol":"1"}, cache:"no-store"})
              .then(r => { if (!r.ok) throw new Error(`Günlük okunamadı (HTTP ${r.status}).`); return r.text(); })
              .then(txt => { if (modOn(m.id)) modLogs[m.id] = txt; }).catch(fail)
              .finally(() => { modLogLoading.delete(m.id); renderModules(); });
          }}, svg("list"), modLogLoading.has(m.id) ? "Okunuyor…" : modLogs[m.id] != null ? "Günlüğü gizle" : "Günlük"),
        h("button", {type:"button", class:"btn btn-sm btn-quiet danger-text", id:`mod-remove-${m.id}`,
          disabled:!!m.busy || dependents.some(d => d.busy), onclick:() => {
            const box = h("input", {type:"checkbox", id:"mod-veri"});
            const names = dependents.map(d => metaOf(d.id).name).join(", ");
            const daDe = w => (/[aıou][^aeıioöuü]*$/i.test(w) ? "da" : "de");
            ask({title:`${meta.name} kaldırılsın mı?`,
              sub:dependents.length ? `${names} ${daDe(names)} kaldırılır (buna bağlı)` : "Uygulama ve açtığı erişimler kaldırılır",
              go:dependents.length ? "Birlikte kaldır" : "Kaldır", danger:true,
              items:[...meta.removeWhat, ...dependents.map(d => [metaOf(d.id).icon, `${metaOf(d.id).name} buna bağlı olduğu için önce o kaldırılır; hesabı ve kayıtları korunur.`]),
                ["folder","Kullanıcı alanındaki dosyalarınıza dokunulmaz."]],
              extra:h("label", {class:"opt", for:"mod-veri"}, box, h("span", null, meta.removeLabel || "Uygulamanın verisini de sil",
                h("small", null, `${meta.removeDrop} İşaretlemezseniz: ${meta.removeKeep}`))),
              onOk:() => {
                if (!dependents.length) { modAct(m, "kaldir", box.checked); return; }
                dependents.slice(1).forEach(d => modQueue.push([d.id,"kaldir",false]));
                modQueue.push([m.id, "kaldir", box.checked]);
                modAct(dependents[0],"kaldir",false);
              }});
          }}, svg("trash"), "Kaldır")));
    }
    kids.push(h("div", {id:"mod-log-output", class:"logbox", hidden:modLogs[m.id] == null},
      h("div", {class:"acct-head"}, h("span", null, "Günlük"), h("span", {class:"src"}, meta.logSrc || m.id)),
      h("pre", {id:`mod-log-text-${m.id}`, tabindex:"0"}, modLogs[m.id] || "(boş)")));
    return kids;
  }
  function renderModules() {
    if (!MODS) { $("mod-grid").replaceChildren(h("p", { class: "hint-s" }, "Yükleniyor…")); return; }
    const n = MODS.filter((m) => m.installed).length;
    if ($("mod-sum")) $("mod-sum").textContent = `${n} kurulu · ${MODS.length - n} kurulabilir`;
    const selected = MODS.find(m => m.id === modSelected);
    if (!selected) modSelected = null;
    const key = JSON.stringify([MODS, modQueue, modSelected, modLogs, [...modLogLoading], S.sys?.domain, S.sys?.root, S.sys?.torrent]);
    if (key === modRenderKey) return;
    modRenderKey = key;
    const focused = document.activeElement;
    const focusId = focused?.closest("#mod-grid, #mod-detail") ? focused.id : null;
    const focusApp = focused?.closest(".store-row")?.id.replace("modc-", "") || modSelected;
    const pre = $("mod-detail").querySelector("pre");
    const scroll = pre ? [pre.id, pre.scrollTop, pre.scrollLeft] : null;
    $("mod-grid").replaceChildren(...MODS.map(modRow));
    $("mod-detail").hidden = !selected;
    $("mod-detail").replaceChildren(...(selected ? modDetail(selected) : []));
    if (focusId) {
      const target = $(focusId);
      (target && !target.disabled ? target : $("mod-details-" + focusApp))?.focus({preventScroll:true});
    }
    if (scroll && $(scroll[0])) { $(scroll[0]).scrollTop = scroll[1]; $(scroll[0]).scrollLeft = scroll[2]; }
  }

  /* ---------- Ayarlar (DD-156) ---------- */
  let CFG = null, cfgBusy = false;
  const hhmm = (sec) => new Date(sec * 1000).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
  // replaceChildren boş öğeyi "null" metni olarak basar: yalnız gerçek öğeler konur.
  const fill = (id, ...kids) => $(id).replaceChildren(...kids.flat(Infinity).filter(Boolean));
  function loadSettings(fresh) {
    if (cfgBusy) return;
    cfgBusy = true;
    return api(fresh === true ? "/api/konsol/ayarlar?yenile=1" : "/api/konsol/ayarlar").then((d) => { CFG = d; renderSettings(); }).catch(fail).finally(() => { cfgBusy = false; });
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

  const isIpPort = (a) => /^\d+\.\d+\.\d+\.\d+:\d+$/.test(a);
  function webDesc(e) {
    if (e.source === "wireguard") return `WireGuard'dan · ${e.label || e.iface}`;
    const extra = isIpPort(e.address) ? " · ad çözmeyen cihazlar için (ör. Infuse)" : "";
    if (e.source === "base") return (e.address.startsWith("panel.") ? "Sunucu yönetim paneli" : "Temel servis") + extra;
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
      h("div", { class: "card-foot" }, h("span", null, "Bu adresler internete doğrudan açık değildir. Caddy, Tailscale ve izin verilen WireGuard ağlarında çalışır. HTTP kullanılır; ağ tünelleri trafiği şifreler.")));
  }
  function systemContent() {
    const s = S.sys;
    const row = (label, value) => h("div", null, h("dt", null, label), h("dd", null, value || "—"));
    return h("div", {class:"as-stack"},
      h("article", {class:"card"}, h("h2", null, "Panel ve sunucu"),
        h("p", {class:"page-note"}, "Debian üzerinde yönetim konsolu. Kaynak kullanımı sol menüde; servis ayrıntıları kendi sekmelerinde."),
        s ? h("dl", {class:"system-facts"},
          row("Sunucu", s.host), row("Sistem", s.os), row("Çekirdek", s.kernel), row("Panel sürümü", s.version),
          row("Çalışma süresi", duration(s.uptime)), row("Tailscale", s.net.tailscale),
          row("Panel adresi", "panel." + s.domain), row("Kullanıcı alanı", s.root),
          row("Son okuma", hhmm(s.read_at))) : h("p", {class:"hint-s"}, "Sunucu bilgisi bekleniyor…")),
      h("article", {class:"card"}, h("h2", null, "Yerleşik altyapı"),
        h("p", {class:"page-note"}, "Dosyalar, WebDAV ve ZIP/RAR açma panelle birlikte hazırdır. Tailscale, Caddy, Dnsmasq ve güvenlik duvarı temel bağımlılıklardır; App Store’dan kaldırılmaz."),
        h("p", {class:"hint-s"}, "Uygulamalar App Store’dan kurulur. Kaldırma sırasında profil/veri silme ayrıca onaylanır; kullanıcı dosyaları korunur.")));
  }
  const logContent = () => h("div", {class:"logwrap"},
    h("p", {class:"page-note"}, "Konsol’dan yapılan son işlemler. Servis günlükleri App Store → Ayrıntı bölümünde bulunur."),
    h("div", {class:"chipset", id:"log-filter", role:"group", "aria-label":"Süzgeç"}),
    h("div", {class:"table log-t", id:"log-table"}));
  let settingsTab = "system";
  const settingsPage = window.createSettingsPage({ h, svg, api, post, toast, fail, paintWeb, loadSettings, systemContent, logContent, paintLog:renderLog });
  function renderSettings() {
    const stamp = $("cfg-stamp");
    if (stamp) stamp.textContent = CFG ? "Son okuma " + hhmm(CFG.read_at) : "Okunuyor…";
    settingsPage.render(CFG, current === "torrent" ? "qb" : settingsTab);
  }
  function renderTorrentStatus() {
    const m = (MODS || []).find((x) => x.id === "torrent");
    const box = $("torrent-status");
    if (!m?.installed) { box.replaceChildren(h("p", {class:"hint-s"}, "Kurulum durumu okunuyor…")); return; }
    const running = m.state === "calisiyor";
    box.replaceChildren(modPill(m),
      h("button", {type:"button", class:"btn btn-quiet", disabled:!!m.busy, onclick:() => {
        if (!running) { modAct(m, "baslat"); return; }
        ask({title:"qBittorrent durdurulsun mu?", calm:true, go:"Durdur", items:[["pause","Süren indirmeler duraklar. Başlatana kadar servis kapalı kalır."]],
          onOk:() => modAct(m, "durdur")});
      }}, svg(running ? "pause" : "play"), running ? "Durdur" : "Başlat"),
      S.sys?.domain && running ? h("a", {class:"btn btn-primary", href:location.protocol + "//torrent." + S.sys.domain, target:"_blank", rel:"noopener"}, "Web arayüzünü aç ↗") : null,
      h("a", {class:"linkbtn", href:"#/moduller"}, "App Store’da yönet"));
  }
  $("torrent-account").parentElement.addEventListener("toggle", (e) => {
    if (e.currentTarget.open) { $("torrent-account").replaceChildren(accountBlock("torrent", "card")); loadAccount("torrent"); }
    else { hidePass("torrent"); $("torrent-account").replaceChildren(); }
  });

  /* ---------- One workspace, stable legacy bookmarks ---------- */
  function setMenu(open) {
    $("menu-toggle").setAttribute("aria-expanded", String(open));
    $("panel-sidebar").classList.toggle("menu-open", open);
  }
  $("menu-toggle").addEventListener("click", () => setMenu($("menu-toggle").getAttribute("aria-expanded") !== "true"));
  document.querySelector(".skip-link").addEventListener("click", (e) => { e.preventDefault(); $("main-content").focus(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && $("menu-toggle").getAttribute("aria-expanded") === "true") { setMenu(false); $("menu-toggle").focus(); } });
  const settingsActions = () => [h("span", {class:"hm", id:"cfg-stamp"}, "Okunuyor…"),
    h("button", {type:"button", class:"btn btn-quiet", onclick:() => {
      if (current === "ayarlar" && settingsTab === "log") loadActions();
      else if (current === "ayarlar" && settingsTab === "system") loadSystem();
      else loadSettings(true);
    }}, svg("refresh"), "Yenile")];
  const ROUTES = {
    wireguard: { title: "WireGuard", eyebrow: "Cihazlar ve ağlar", actions: () => [], render: () => { renderWg(); if (wgOn()) loadWg(); } },
    torrent: { title:"qBittorrent", eyebrow:"Hesap, indirme dizini ve servis", actions:settingsActions,
      render:() => { renderTorrentStatus(); renderSettings(); loadSettings(); } },
    dosyalar: { title: "Dosyalar", eyebrow: "Sunucu alanı", actions: () => [],
      render: () => { renderFs(); if (fsView === "trash") loadTrash(); else if (fsView === "shares") loadShares(); else if (fsView === "files") { loadShares(); if (!fsList) loadFs(); } } },
    moduller: { title: "App Store", eyebrow: "", actions: () => [h("span", {class:"hm", id:"mod-sum"}, "Okunuyor…")], render: () => { renderModules(); loadModules(); } },
    ayarlar: { title: "Ayarlar", eyebrow: "Panel ve sunucu yapılandırması", actions:settingsActions,
      render: () => { renderSettings(); if (settingsTab === "log") loadActions(); loadSettings(); } },
  };
  const ADD_ROUTE = { title: "Arayüz ekle", eyebrow: "WireGuard · yeni ağ", first: true,
    actions: () => [h("button", { type: "button", class: "btn btn-quiet", "data-go": "#/wireguard" }, svg("back"), "WireGuard")], render: renderAddNet };
  let current = "dosyalar";
  const view = () => current;
  function route() {
    let raw = location.hash.replace(/^#\/?/, "").split("/");
    const alias = {uygulamalar:"dosyalar", genel:"dosyalar", gunluk:"ayarlar/log"};
    if (alias[raw[0]] || (raw[0] === "ayarlar" && raw[1] === "qb")) {
      history.replaceState(null, "", "#/" + (alias[raw[0]] || "torrent"));
      raw = location.hash.slice(2).split("/");
    }
    let key = ROUTES[raw[0]] ? raw[0] : "dosyalar";
    setMenu(false);
    // An absent application sends a saved bookmark to App Store.
    if (MODS && ((key === "torrent" && !modOn("torrent")) || (key === "wireguard" && !wgOn()))) {
      history.replaceState(null, "", "#/moduller");
      key = "moduller";
    }
    if (key === "dosyalar") fsView = raw[1] === "cop" ? "trash" : raw[1] === "paylasim" ? "shares" : raw[1] === "arsiv" ? "archives" : "files";
    if (key === "ayarlar") settingsTab = ["fw","web","dns","log"].includes(raw[1]) ? raw[1] : "system";
    const v = key === "wireguard" && raw[1] === "ekle" ? "wgadd" : key;
    const r = v === "wgadd" ? ADD_ROUTE : ROUTES[key];
    if (key !== current) hideAllPass();
    current = key;
    document.querySelectorAll("[data-view]").forEach((s) => { s.hidden = s.dataset.view !== v; });
    document.querySelectorAll("[data-route]").forEach((a) => {
      if (a.dataset.route === key) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    });
    $("title").textContent = v === "wgadd" && S.wg && !nets().length ? "WireGuard'ı yapılandır" : r.title;
    $("eyebrow").textContent = r.eyebrow;
    $("eyebrow").hidden = !r.eyebrow;
    $("top-actions").replaceChildren(...r.actions());
    if (r.render) r.render();
    window.scrollTo({ top: 0 });
  }
  window.addEventListener("hashchange", route);
  document.addEventListener("click", (e) => {
    const go = e.target.closest("[data-go]");
    if (go && go.dataset.go) location.hash = go.dataset.go;
  });

  /* Keep the shell independent; poll expensive application data only on its page. */
  loadSystem();
  route();
  loadModules().then(() => { if (current === "wireguard" && wgOn()) loadWg(); });
  setInterval(() => {
    if (document.hidden) return;
    loadSystem();
    if (current === "wireguard" && wgOn()) loadWg();
    if (current === "ayarlar" && settingsTab === "log") loadActions();
    if (current === "dosyalar") { loadFsState(); if (fsView === "shares") loadShares(); }
    if (["moduller","torrent"].includes(current) && !(MODS || []).some((m) => m.busy)) loadModules();
  }, 10000);
  setInterval(() => { if (!document.hidden) paintResources(); }, 1000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { paintResources(); loadSystem(); loadModules(); } });
  loadFsState();
})();
