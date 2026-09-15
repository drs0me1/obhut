/* Dosya paneli (DD-139). Bütün işlemleri sunucu yapar (master-files-panel); sayfa yalnız ister ve gösterir. */
(() => {
  "use strict";

  const ICON = {
    folder: '<path d="M2.2 5.2c0-.9.7-1.6 1.6-1.6h3.1l1.7 1.9h5.6c.9 0 1.6.7 1.6 1.6v6.1c0 .9-.7 1.6-1.6 1.6H3.8c-.9 0-1.6-.7-1.6-1.6z"/>',
    video: '<rect x="2.2" y="3.6" width="13.6" height="10.8" rx="1.8"/><path d="M7.4 6.7v4.6l3.9-2.3z"/>',
    archive: '<rect x="2.6" y="2.6" width="12.8" height="12.8" rx="1.8"/><path d="M9 2.6v1.6M9 5.4v1.4M9 8v1.2"/><rect x="7.6" y="10.4" width="2.8" height="2.6" rx=".6"/>',
    text: '<path d="M4.6 2.4h5.8l3 3v10.2H4.6z"/><path d="M10.2 2.4v3.2h3.2M6.8 9h4.4M6.8 11.6h4.4"/>',
    image: '<rect x="2.4" y="3.2" width="13.2" height="11.6" rx="1.8"/><circle cx="6.4" cy="7" r="1.3"/><path d="M2.8 13.2l4-3.6 2.8 2.4 2.2-1.8 3.6 3"/>',
    file: '<path d="M4.6 2.4h5.8l3 3v10.2H4.6z"/><path d="M10.2 2.4v3.2h3.2"/>',
    pencil: '<path d="M11.8 3.2l3 3-8.4 8.4H3.4v-3z"/><path d="M10.2 4.8l3 3"/>',
    move: '<path d="M2.2 5.2c0-.9.7-1.6 1.6-1.6h3.1l1.7 1.9h5.6c.9 0 1.6.7 1.6 1.6v6.1c0 .9-.7 1.6-1.6 1.6H3.8c-.9 0-1.6-.7-1.6-1.6z"/><path d="M6.4 10.1h4.8M9.4 8.2l1.9 1.9-1.9 1.9"/>',
    trash: '<path d="M3.2 5h11.6M7.2 5V3.4h3.6V5M4.6 5l.8 9.6h7.2l.8-9.6"/><path d="M7.6 8v4M10.4 8v4"/>',
    download: '<path d="M9 2.8v8.4M5.6 7.9L9 11.3l3.4-3.4M3.2 14.6h11.6"/>',
    restore: '<path d="M3.6 8.8a5.4 5.4 0 1 0 1.6-3.9"/><path d="M3.4 2.6v3.2h3.2"/>',
    refresh: '<path d="M14.4 9a5.4 5.4 0 1 1-1.6-3.9"/><path d="M14.6 2.6v3.2h-3.2"/>',
    up: '<path d="M9 14.4V3.8M4.8 8L9 3.8 13.2 8"/>',
    search: '<circle cx="8" cy="8" r="4.8"/><path d="M11.6 11.6l3.4 3.4"/>',
    chevRight: '<path d="M7 4.5l4.5 4.5L7 13.5"/>',
    chevDown: '<path d="M4.5 7l4.5 4.5L13.5 7"/>',
    chevUp: '<path d="M4.5 11l4.5-4.5 4.5 4.5"/>',
    chevLeft: '<path d="M11 4.5L6.5 9l4.5 4.5"/>',
    eye: '<path d="M1.8 9S4.4 4.2 9 4.2 16.2 9 16.2 9 13.6 13.8 9 13.8 1.8 9 1.8 9z"/><circle cx="9" cy="9" r="2.2"/>',
    plus: '<path d="M9 3.5v11M3.5 9h11"/>',
    close: '<path d="M4.5 4.5l9 9M13.5 4.5l-9 9"/>',
    shield: '<path d="M9 2.2l5.6 2v4.4c0 3.4-2.4 5.9-5.6 7.2-3.2-1.3-5.6-3.8-5.6-7.2V4.2z"/>',
    info: '<circle cx="9" cy="9" r="6.8"/><path d="M9 8.2v4.2M9 5.6v.1"/>',
    warn: '<path d="M9 2.2l7 12.6H2z"/><path d="M9 7.2v3.4M9 12.6v.1"/>',
    lock: '<rect x="3.6" y="8" width="10.8" height="7.4" rx="1.6"/><path d="M6 8V5.8a3 3 0 0 1 6 0V8"/>',
    link: '<path d="M7.6 10.4l2.8-2.8M8 5.2l1.2-1.2a2.9 2.9 0 0 1 4.1 4.1L12.1 9.3M10 12.8l-1.2 1.2a2.9 2.9 0 0 1-4.1-4.1l1.2-1.2"/>',
    list: '<path d="M6.6 4.6h8.4M6.6 9h8.4M6.6 13.4h8.4"/><circle cx="3.3" cy="4.6" r=".95" fill="currentColor" stroke="none"/><circle cx="3.3" cy="9" r=".95" fill="currentColor" stroke="none"/><circle cx="3.3" cy="13.4" r=".95" fill="currentColor" stroke="none"/>',
    grid: '<rect x="2.6" y="2.6" width="5.3" height="5.3" rx="1.2"/><rect x="10.1" y="2.6" width="5.3" height="5.3" rx="1.2"/><rect x="2.6" y="10.1" width="5.3" height="5.3" rx="1.2"/><rect x="10.1" y="10.1" width="5.3" height="5.3" rx="1.2"/>',
  };
  function svg(name) {
    const t = document.createElement("template");
    t.innerHTML = '<svg viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICON[name] + "</svg>";
    return t.content.firstChild;
  }
  const $ = (id) => document.getElementById(id);
  // Öge adları hep metin düğümü olarak eklenir; HTML olarak yorumlanmaz.
  function h(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
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

  const CONFIRM_WORD = "onayla";
  const TEXT_EXT = /^(txt|log|nfo|srt|sub|ass|ssa|vtt|md|json|ya?ml|ini|conf|cfg|csv|xml|sh|py)$/;
  const LAYOUT_KEY = "dosya-paneli-gorunum";
  const ENC_LABEL = { "utf-8": "UTF-8", cp1254: "Türkçe (Windows-1254)", cp437: "DOS (CP437)" };
  const KB = 1024;
  const COLL = new Intl.Collator("tr", { numeric: true, sensitivity: "base" });
  const NF1 = new Intl.NumberFormat("tr-TR", { maximumFractionDigits: 1 });
  const NF2 = new Intl.NumberFormat("tr-TR", { maximumFractionDigits: 2 });
  const DF = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short", year: "numeric" });
  const TF = new Intl.DateTimeFormat("tr-TR", { hour: "2-digit", minute: "2-digit" });

  function fmtSize(b) {
    if (b == null) return "—";
    if (b < KB) return `${b} B`;
    const units = ["KB", "MB", "GB", "TB"];
    let v = b / KB, i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return `${(v < 10 ? NF2 : NF1).format(v)} ${units[i]}`;
  }
  function fmtDate(sec) {
    const d = new Date(sec * 1000), today = new Date();
    const y = new Date(today);
    y.setDate(today.getDate() - 1);
    if (d.toDateString() === today.toDateString()) return `Bugün ${TF.format(d)}`;
    if (d.toDateString() === y.toDateString()) return `Dün ${TF.format(d)}`;
    return DF.format(d);
  }
  const extOf = (name) => (name.match(/\.([^.]+)$/) || [, ""])[1].toLowerCase();
  function kindOf(n) {
    if (n.type === "dir") return "dir";
    if (n.type === "link") return "link";
    const ext = extOf(n.name);
    if (/^(mkv|mp4|avi|mov|m4v|webm|ts)$/.test(ext)) return "video";
    if (/^(rar|r\d\d|zip|7z|gz|tar|bz2|xz)$/.test(ext)) return "archive";
    if (/^(jpe?g|png|heic|webp|gif)$/.test(ext)) return "image";
    if (TEXT_EXT.test(ext)) return "text";
    return "file";
  }
  function typeIcon(n) {
    const k = kindOf(n);
    return h("span", { class: `ticon t-${k}` }, svg(k === "dir" ? "folder" : k));
  }
  const previewable = (n) => n.type === "file" && TEXT_EXT.test(extOf(n.name));
  const same = (a, b) => !!a && !!b && a.length === b.length && a.every((p, i) => p === b[i]);
  const startsWith = (a, prefix) => prefix.length <= a.length && prefix.every((p, i) => a[i] === p);
  const splitPath = (p) => (p ? p.split("/") : []);
  const totalOf = (list) => list.reduce((a, n) => a + (n.size || 0), 0);

  // ---- durum ----
  const S = { st: null, view: "files", parts: [], entries: [], skipped: 0, sel: new Set(), last: null,
    sort: { key: "name", dir: 1 }, filter: "", hidden: false, layout: "list", renaming: null, creating: false,
    confirmPurge: null, trash: [] };
  let drag = null;
  try { if (localStorage.getItem(LAYOUT_KEY) === "grid") S.layout = "grid"; } catch (e) { /* depolama yok */ }

  const rootPath = (parts) => (S.st ? S.st.root : "") + (parts.length ? "/" + parts.join("/") : "");
  const isTempDir = (parts, name) => !!(S.st && S.st.temp && !parts.length && name === S.st.temp);
  const inTemp = (parts) => !!(S.st && S.st.temp && parts[0] === S.st.temp);

  async function api(path, body) {
    const init = { method: body === undefined ? "GET" : "POST", headers: { "X-Files-Panel": "1" },
      credentials: "same-origin", cache: "no-store" };
    if (body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    const res = await fetch(path, init);
    if (res.status === 401) { location.reload(); throw new Error("giriş gerekli"); }
    let data = {};
    try { data = await res.json(); } catch (e) { /* gövde yok */ }
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }
  const q = (parts) => encodeURIComponent(parts.join("/"));

  let toastTimer;
  function toast(msg, bad, action) {
    const t = $("toast");
    t.textContent = "";
    t.className = "toast" + (bad ? " bad" : "");
    t.append(h("span", null, msg));
    if (action) t.append(h("button", { type: "button", onclick: () => { t.hidden = true; clearTimeout(toastTimer); action.fn(); } }, action.label));
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, action ? 7000 : 4500);
  }

  // ---- konum (adres çubuğunda #/Klasör/Alt ya da #cop; geri tuşu çalışır) ----
  function hashRoute() {
    const raw = location.hash.replace(/^#/, "");
    if (raw === "cop") return null;
    const clean = raw.replace(/^\//, "");
    if (!clean) return [];
    try { return clean.split("/").filter(Boolean).map(decodeURIComponent); } catch (e) { return []; }
  }
  const routeHash = (parts) => (parts === null ? "#cop" : "#/" + parts.map(encodeURIComponent).join("/"));
  function setRoute(parts, push) {
    const target = routeHash(parts);
    if (location.hash === target) return;
    if (push) history.pushState(null, "", target);
    else history.replaceState(null, "", target);
  }
  window.addEventListener("popstate", () => route());
  function route() {
    const r = hashRoute();
    return r === null ? showTrash(false) : go(r, false);
  }

  async function refreshState() {
    try {
      S.st = await api("/api/state");
      renderChips();
      renderTabs();
    } catch (e) { toast(e.message, true); }
  }

  async function go(parts, push = true) {
    let data;
    try {
      data = await api(`/api/list?path=${q(parts)}`);
    } catch (e) {
      toast(e.message, true);
      if (parts.length) return go([], push);
      $("panel").replaceChildren(h("p", { class: "hint" }, `İndirme klasörü açılamadı: ${e.message}`));
      return;
    }
    S.view = "files";
    S.parts = parts;
    S.entries = data.entries;
    S.skipped = data.skipped;
    S.sel.clear(); S.last = null; S.filter = ""; S.renaming = null; S.creating = false;
    setRoute(parts, push);
    render();
  }

  // Aynı klasörü yeniden okur; süzgeç ve (select verilmezse) seçim korunur.
  async function reload(select) {
    if (S.view === "trash") return loadTrash();
    try {
      const data = await api(`/api/list?path=${q(S.parts)}`);
      S.entries = data.entries;
      S.skipped = data.skipped;
      const names = new Set(S.entries.map((e) => e.name));
      S.sel = new Set((select || [...S.sel]).filter((n) => names.has(n)));
      S.last = null;
      renderList();
    } catch (e) {
      toast(e.message, true);
      if (S.parts.length) await go([], false);
    }
  }
  const afterChange = (select) => Promise.all([reload(select), refreshState()]);

  // ---- çizim ----
  function render() {
    renderTabs();
    renderChips();
    if (S.view === "files") renderFiles(); else renderTrash();
    syncSel();
  }

  function renderChips() {
    const st = S.st;
    if (!st) return;
    $("host").textContent = st.host || "sunucu";
    document.title = `${st.host || "sunucu"} · Dosya paneli`;
    const used = st.disk.total - st.disk.free;
    $("chip-disk").textContent = `${fmtSize(st.disk.free)} boş / ${fmtSize(st.disk.total)}`;
    $("disk-meter").style.width = `${st.disk.total ? Math.min(100, (used / st.disk.total) * 100).toFixed(1) : 0}%`;
    $("chip-trash").textContent = fmtSize(st.trash.size);
    $("chip-version").textContent = st.version || "–";
    $("new-folder").disabled = S.view !== "files";
  }

  function renderTabs() {
    const bar = $("tabs");
    bar.textContent = "";
    bar.append(h("button", { type: "button", class: "tab", role: "tab", "aria-selected": S.view === "files", onclick: () => go([]) },
      h("span", null, "İndirilenler"), h("span", { class: "tif" }, S.st ? S.st.root : "")));
    bar.append(h("span", { class: "tab-spacer" }));
    bar.append(h("button", { type: "button", class: "tab", role: "tab", "aria-selected": S.view === "trash", onclick: () => showTrash(true) },
      svg("trash"), h("span", null, "Çöp"), h("span", { class: "tcount" }, S.st ? S.st.trash.count : "–")));
  }

  function dropTarget(el, target) {
    el.addEventListener("dragover", (e) => {
      if (drag && canDrop(target)) { e.preventDefault(); el.classList.add("drop"); }
    });
    el.addEventListener("dragleave", () => el.classList.remove("drop"));
    el.addEventListener("drop", (e) => {
      e.preventDefault();
      el.classList.remove("drop");
      if (drag && canDrop(target)) doMove(drag, target);
    });
  }
  const canDrop = (target) => !same(target, S.parts) && !drag.some((n) => startsWith(target, S.parts.concat(n)));

  function setLayout(v) {
    S.layout = v;
    S.renaming = null; S.creating = false;
    try { localStorage.setItem(LAYOUT_KEY, v); } catch (e) { /* depolama yok */ }
    renderFiles();
  }

  function renderFiles() {
    const p = $("panel");
    p.textContent = "";
    const crumbs = h("ol", { class: "crumbs" });
    for (let i = 0; i <= S.parts.length; i++) {
      const target = S.parts.slice(0, i), last = i === S.parts.length;
      const label = i === 0 ? S.st.root : S.parts[i - 1];
      const cls = "crumb" + (i === 0 ? " root" : "");
      const item = last ? h("span", { class: cls + " cur", "aria-current": "page" }, label)
        : h("button", { type: "button", class: cls, onclick: () => go(target) }, label);
      if (!last) dropTarget(item, target);
      crumbs.append(h("li", null, item));
    }
    const up = h("button", { type: "button", class: "btn btn-quiet btn-sm iconbtn", "aria-label": "Üst klasör", title: "Üst klasör",
      disabled: !S.parts.length, onclick: () => S.parts.length && go(S.parts.slice(0, -1)) }, svg("up"));
    const refresh = h("button", { type: "button", class: "btn btn-quiet btn-sm iconbtn", "aria-label": "Yenile", title: "Yenile",
      onclick: () => afterChange() }, svg("refresh"));
    const filter = h("input", { type: "search", id: "filter", placeholder: "Bu klasörde süz", "aria-label": "Bu klasörde süz", value: S.filter,
      oninput: (e) => { S.filter = e.target.value; renderList(); } });
    const hidden = h("label", { class: "toggle" },
      h("input", { type: "checkbox", id: "hidden-toggle", checked: S.hidden, onchange: (e) => { S.hidden = e.target.checked; renderList(); } }),
      "Gizlileri göster");
    const layout = h("div", { class: "seg", role: "group", "aria-label": "Görünüm" },
      h("button", { type: "button", title: "Liste", "aria-pressed": S.layout === "list", onclick: () => setLayout("list") }, svg("list"), h("span", null, "Liste")),
      h("button", { type: "button", title: "Simge", "aria-pressed": S.layout === "grid", onclick: () => setLayout("grid") }, svg("grid"), h("span", null, "Simge")));
    p.append(h("div", { class: "pathbar" }, up, refresh, h("nav", { class: "crumbwrap", "aria-label": "Konum" }, crumbs),
      h("div", { class: "tools" }, h("span", { class: "search" }, svg("search"), filter), hidden, layout)));
    if (inTemp(S.parts)) {
      p.append(h("div", { class: "warnline" }, svg("warn"),
        h("span", null, "qBittorrent yarım kalan indirmeleri bu klasöre yazar. Buradaki dosyaları taşımak ya da silmek süren indirmeyi bozar.")));
    }
    const sortSel = h("select", { id: "sort-select", "aria-label": "Sıralama", onchange: (e) => {
      const [key, d] = e.target.value.split(":");
      S.sort = { key, dir: Number(d) };
      renderList();
    } }, [["name:1", "Ad (A–Z)"], ["name:-1", "Ad (Z–A)"], ["size:-1", "Boyut (büyükten)"], ["size:1", "Boyut (küçükten)"],
      ["mtime:-1", "En yeni"], ["mtime:1", "En eski"]].map(([v, label]) =>
      h("option", { value: v, selected: `${S.sort.key}:${S.sort.dir}` === v }, label)));
    p.append(h("div", { class: "list-head" }, h("p", { class: "hint num", id: "list-sum" }),
      S.layout === "grid" ? h("div", { class: "list-tools" },
        h("label", { class: "toggle" }, h("input", { type: "checkbox", id: "select-all",
          onchange: (e) => { visible().forEach((n) => (e.target.checked ? S.sel.add(n.name) : S.sel.delete(n.name))); syncSel(); } }), "Tümünü seç"),
        h("label", { class: "sortsel" }, "Sırala", sortSel)) : null));
    p.append(h("div", { class: S.layout === "grid" ? "tiles" : "files", id: "files", role: "list" }));
    p.append(h("p", { class: "footnote" },
      h("span", null, svg("lock"), `Yalnız ${S.st.root} görünür`),
      h("span", null, svg("link"), "Sembolik bağlantılar izlenmez"),
      h("span", null, svg("info"), "Aynı adlı öge üzerine yazılmaz; her işlem günlüğe yazılır"),
      S.skipped ? h("span", null, svg("warn"), `Adı UTF-8 olmayan ${S.skipped} öge gösterilmiyor`) : null));
    renderList();
  }

  function visible() {
    const q2 = S.filter.trim().toLocaleLowerCase("tr");
    const k = S.sort.key, d = S.sort.dir;
    const val = (n) => (k === "size" ? (n.size == null ? -1 : n.size) : n.mtime);
    return S.entries
      .filter((n) => (S.hidden || !n.name.startsWith(".")) && (!q2 || n.name.toLocaleLowerCase("tr").includes(q2)))
      .sort((a, b) => (a.type === b.type ? 0 : a.type === "dir" ? -1 : b.type === "dir" ? 1 : 0)
        || d * (k === "name" ? COLL.compare(a.name, b.name) : val(a) - val(b))
        || COLL.compare(a.name, b.name));
  }
  const selNodes = () => S.entries.filter((n) => S.sel.has(n.name));

  function sortHead(key, label, cls) {
    const on = S.sort.key === key;
    return h("span", { class: cls || "" }, h("button", { type: "button", class: "sortbtn" + (on ? " on" : ""),
      onclick: () => { S.sort = on ? { key, dir: -S.sort.dir } : { key, dir: key === "name" ? 1 : -1 }; renderList(); } },
      label, on ? svg(S.sort.dir > 0 ? "chevUp" : "chevDown") : null));
  }

  function renderList() {
    const box = $("files");
    if (!box) return;
    box.textContent = "";
    const items = visible(), grid = S.layout === "grid";
    if (!grid) {
      box.append(h("div", { class: "frow head" },
        h("span", null, h("input", { type: "checkbox", id: "select-all", "aria-label": "Tümünü seç",
          onchange: (e) => { items.forEach((n) => (e.target.checked ? S.sel.add(n.name) : S.sel.delete(n.name))); syncSel(); } })),
        sortHead("name", "Ad"), sortHead("size", "Boyut", "c-size r"), sortHead("mtime", "Değiştirilme", "c-date"), h("span", { class: "c-act" })));
    }
    if (S.creating) box.append(grid ? createTile() : createRow());
    if (!items.length && !S.creating) {
      box.append(h("div", { class: "empty" }, S.filter
        ? h("span", null, `“${S.filter}” ile eşleşen öge yok.`)
        : [h("strong", null, "Bu klasör boş"), h("span", null, "Dosyaları buraya sürükleyin ya da yeni klasör açın.")]));
    }
    items.forEach((n, i) => box.append(grid ? fileTile(n, i, items) : fileRow(n, i, items)));
    const dirs = items.filter((n) => n.type === "dir").length;
    const sum = $("list-sum");
    if (sum) sum.textContent = `${items.length} öge${dirs ? ` · ${dirs} klasör` : ""} · ${fmtSize(totalOf(items))}`;
    syncSel();
    const inp = box.querySelector("input.rename");
    if (inp) {
      inp.focus();
      const node = S.renaming ? S.entries.find((e) => e.name === S.renaming) : null, dot = inp.value.lastIndexOf(".");
      inp.setSelectionRange(0, node && node.type === "file" && dot > 0 ? dot : inp.value.length);
    }
  }

  function toggle(n, i, items, shift) {
    if (shift && S.last != null && items[S.last]) {
      const [a, b] = S.last < i ? [S.last, i] : [i, S.last];
      for (let k = a; k <= b; k++) S.sel.add(items[k].name);
    } else if (S.sel.has(n.name)) S.sel.delete(n.name);
    else S.sel.add(n.name);
    S.last = i;
    syncSel();
  }

  function openItem(n, i, items, e) {
    if (n.type === "dir") go(S.parts.concat(n.name));
    else if (previewable(n)) openViewer(n);
    else toggle(n, i, items, e.shiftKey);
  }

  function iconBtn(icon, label, fn, cls) {
    return h("button", { type: "button", class: "ib" + (cls ? " " + cls : ""), "aria-label": label, title: label, onclick: fn }, svg(icon));
  }

  function metaParts(n) {
    return [
      n.type === "dir" ? h("span", null, n.count == null ? "? öge" : `${n.count} öge`) : null,
      n.type === "link" ? h("span", null, "sembolik bağlantı") : null,
      isTempDir(S.parts, n.name) && n.type === "dir" ? h("span", { class: "chip tiny tmp" }, "qBittorrent geçici") : null,
    ];
  }

  function fileRow(n, i, items) {
    const sel = S.sel.has(n.name), isDir = n.type === "dir";
    const row = h("div", { class: "frow" + (sel ? " sel" : ""), "data-name": n.name, role: "listitem", draggable: S.renaming ? null : "true" });
    const cb = h("input", { type: "checkbox", "aria-label": `${n.name} seç`, checked: sel, onclick: (e) => toggle(n, i, items, e.shiftKey) });
    let name;
    if (S.renaming === n.name) {
      name = h("div", { class: "fname static" }, typeIcon(n), renameBox(n));
    } else {
      name = h("button", { type: "button", class: "fname" + (isDir ? " is-dir" : ""), onclick: (e) => openItem(n, i, items, e) },
        typeIcon(n), h("span", { class: "nm" }, h("span", { class: "nt" }, n.name),
          h("small", { class: "meta" }, metaParts(n), h("span", { class: "m-narrow num" }, `${fmtSize(n.size)} · ${fmtDate(n.mtime)}`))));
    }
    row.append(h("span", null, cb), name,
      h("span", { class: "c-size" }, fmtSize(n.size)),
      h("span", { class: "c-date" }, fmtDate(n.mtime)),
      h("div", { class: "c-act" }, h("div", { class: "ract" },
        previewable(n) ? iconBtn("eye", "Görüntüle", () => openViewer(n)) : null,
        n.type === "file" ? iconBtn("download", "İndir", () => download(S.parts.concat(n.name))) : null,
        iconBtn("pencil", "Yeniden adlandır (F2)", () => startRename(n)),
        iconBtn("move", "Taşı", () => openMove([n])),
        iconBtn("trash", "Çöpe taşı (Del)", () => openDelete([n]), "danger"))));
    makeDraggable(row, n);
    return row;
  }

  function fileTile(n, i, items) {
    const sel = S.sel.has(n.name), isDir = n.type === "dir";
    const tile = h("div", { class: "tile" + (sel ? " sel" : ""), "data-name": n.name, role: "listitem", draggable: S.renaming ? null : "true" });
    const cb = h("input", { type: "checkbox", class: "tcheck", "aria-label": `${n.name} seç`, checked: sel, onclick: (e) => toggle(n, i, items, e.shiftKey) });
    const icon = typeIcon(n);
    icon.classList.add("big");
    const body = S.renaming === n.name
      ? h("div", { class: "tbody static" }, icon, renameBox(n))
      : h("button", { type: "button", class: "tbody" + (isDir ? " is-dir" : ""), title: `${n.name}\n${fmtDate(n.mtime)}`,
        onclick: (e) => openItem(n, i, items, e) },
        icon, h("span", { class: "tname" }, n.name), h("small", { class: "tmeta num" }, metaParts(n), h("span", null, fmtSize(n.size))));
    tile.append(cb, body);
    makeDraggable(tile, n);
    return tile;
  }

  function makeDraggable(el, n) {
    el.addEventListener("dragstart", (e) => {
      drag = S.sel.has(n.name) ? [...S.sel] : [n.name];
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", drag.join("\n"));
      el.classList.add("dragging");
    });
    el.addEventListener("dragend", () => {
      drag = null;
      el.classList.remove("dragging");
      document.querySelectorAll(".drop").forEach((x) => x.classList.remove("drop"));
    });
    if (n.type === "dir") dropTarget(el, S.parts.concat(n.name));
  }

  function nameError(v, self) {
    if (!v.trim()) return "Ad boş olamaz.";
    if (v !== v.trim()) return "Ad boşlukla başlayamaz ya da bitemez.";
    if (v.includes("/")) return "Ad “/” içeremez.";
    if (v === "." || v === "..") return "Bu ad kullanılamaz.";
    if (/[ -]/.test(v)) return "Ad denetim karakteri içeremez.";
    if (new TextEncoder().encode(v).length > 255) return "Ad en fazla 255 bayt olabilir.";
    if (S.entries.some((e) => e.name === v && e.name !== self)) return "Bu klasörde aynı adla bir öge var.";
    return "";
  }
  function showErr(input, err, msg) { err.textContent = msg; err.hidden = false; input.setAttribute("aria-invalid", "true"); }

  function renameBox(n) {
    const err = h("small", { class: "err", hidden: true });
    return h("div", { class: "rn" },
      h("input", { type: "text", class: "rename", value: n.name, "aria-label": "Yeni ad", spellcheck: "false",
        onkeydown: (e) => {
          if (e.key === "Enter") { e.preventDefault(); commitRename(n, e.target, err, false); }
          else if (e.key === "Escape") { e.preventDefault(); S.renaming = null; renderList(); }
        },
        onblur: (e) => commitRename(n, e.target, err, true) }), err);
  }

  function uniqueName(base) {
    if (!S.entries.some((e) => e.name === base)) return base;
    for (let i = 2; ; i++) { const c = `${base} (${i})`; if (!S.entries.some((e) => e.name === c)) return c; }
  }

  function createBox() {
    const err = h("small", { class: "err", hidden: true });
    return h("div", { class: "rn" },
      h("input", { type: "text", class: "rename", value: uniqueName("Yeni klasör"), "aria-label": "Klasör adı", spellcheck: "false",
        onkeydown: (e) => {
          if (e.key === "Enter") { e.preventDefault(); commitCreate(e.target, err, false); }
          else if (e.key === "Escape") { e.preventDefault(); S.creating = false; renderList(); }
        },
        onblur: (e) => commitCreate(e.target, err, true) }), err);
  }
  function createRow() {
    return h("div", { class: "frow creating" }, h("span"),
      h("div", { class: "fname static" }, h("span", { class: "ticon t-dir" }, svg("folder")), createBox()),
      h("span", { class: "c-size" }), h("span", { class: "c-date" }), h("span", { class: "c-act" }));
  }
  function createTile() {
    return h("div", { class: "tile creating" },
      h("div", { class: "tbody static" }, h("span", { class: "ticon t-dir big" }, svg("folder")), createBox()));
  }

  function startRename(n) { S.renaming = n.name; S.creating = false; renderList(); }

  async function commitRename(n, input, err, fromBlur) {
    if (S.renaming !== n.name) return;
    const v = input.value;
    if (v === n.name) { S.renaming = null; renderList(); return; }
    const msg = nameError(v, n.name);
    if (msg) {
      if (fromBlur) { S.renaming = null; renderList(); toast(`Ad değişmedi: ${msg}`, true); }
      else showErr(input, err, msg);
      return;
    }
    S.renaming = null;
    const parts = S.parts.slice(), old = n.name;
    try {
      await api("/api/rename", { path: parts.join("/"), name: old, to: v });
      await afterChange([]);
      toast(`Yeni ad: ${v}`, false, { label: "Geri al", fn: async () => {
        try { await api("/api/rename", { path: parts.join("/"), name: v, to: old }); } catch (e) { toast(e.message, true); }
        await afterChange([]);
      } });
    } catch (e) {
      renderList();
      toast(e.message, true);
    }
  }

  async function commitCreate(input, err, fromBlur) {
    if (!S.creating) return;
    const v = input.value, msg = nameError(v, null);
    if (msg) {
      if (fromBlur) { S.creating = false; renderList(); }
      else showErr(input, err, msg);
      return;
    }
    S.creating = false;
    const parts = S.parts.slice();
    try {
      await api("/api/mkdir", { path: parts.join("/"), name: v });
      await afterChange([]);
      toast(`Klasör açıldı: ${v}`, false, { label: "Aç", fn: () => go(parts.concat(v)) });
    } catch (e) {
      renderList();
      toast(e.message, true);
    }
  }

  function syncSel() {
    const nodes = selNodes();
    document.querySelectorAll("#files [data-name]").forEach((r) => {
      const on = S.sel.has(r.dataset.name);
      r.classList.toggle("sel", on);
      const cb = r.querySelector("input[type=checkbox]");
      if (cb) cb.checked = on;
    });
    const box = $("files");
    if (box) box.classList.toggle("picking", nodes.length > 0);
    const all = $("select-all");
    if (all) {
      const vis = visible();
      all.checked = vis.length > 0 && vis.every((n) => S.sel.has(n.name));
      all.indeterminate = !all.checked && vis.some((n) => S.sel.has(n.name));
    }
    const show = S.view === "files" && nodes.length > 0;
    $("selbar").hidden = !show;
    document.body.classList.toggle("has-sel", show);
    if (show) {
      $("sel-n").textContent = nodes.length;
      $("sel-size").textContent = fmtSize(totalOf(nodes));
      $("sel-rename").hidden = nodes.length !== 1;
    }
  }

  function download(parts) {
    const a = h("a", { href: `/api/download?path=${q(parts)}`, download: parts[parts.length - 1] });
    document.body.append(a);
    a.click();
    a.remove();
  }

  // ---- taşıma ----
  async function doMove(names, target) {
    const from = S.parts.slice();
    try {
      const r = await api("/api/move", { path: from.join("/"), names, to: target.join("/") });
      await afterChange([]);
      toast(`${r.moved.length} öge taşındı: ${rootPath(target)}`, false, { label: "Geri al", fn: () => undoMove(r.moved, target, from) });
    } catch (e) {
      toast(e.message, true);
      await afterChange();
    }
  }
  async function undoMove(names, at, back) {
    try {
      await api("/api/move", { path: at.join("/"), names, to: back.join("/") });
      toast("Taşıma geri alındı.");
    } catch (e) { toast(e.message, true); }
    await afterChange();
  }

  let M = null;
  function openMove(items) {
    if (!items.length) return;
    M = { from: S.parts.slice(), names: items.map((x) => x.name), target: null, cache: new Map(), counts: new Map(),
      open: new Set(), busy: false, error: "",
      temp: inTemp(S.parts) || items.some((x) => isTempDir(S.parts, x.name)) };
    for (let i = 0; i <= S.parts.length; i++) M.open.add(S.parts.slice(0, i).join("/"));
    $("move-title").textContent = items.length === 1 ? `Taşı: ${items[0].name}` : `${items.length} ögeyi taşı`;
    $("move-what").replaceChildren(h("span", null, `${items.length} öge · ${fmtSize(totalOf(items))}`),
      h("span", null, "Şu an: ", h("span", { class: "mono" }, rootPath(M.from))));
    renderMove();
    $("move-dialog").showModal();
    M.open.forEach((key) => loadNode(key));
  }
  async function loadNode(key) {
    const m = M;
    if (!m || m.cache.has(key)) return;
    m.cache.set(key, null);
    try {
      const d = await api(`/api/list?path=${encodeURIComponent(key)}&dirs=1`);
      d.entries.forEach((k) => m.counts.set(key ? `${key}/${k.name}` : k.name, k.count));
      m.cache.set(key, d.entries);
    } catch (e) {
      m.cache.set(key, []);
    }
    if (M === m) renderMove();
  }
  function moveError(m) {
    if (same(m.target, m.from)) return "Seçilenler zaten bu klasörde.";
    if (m.names.some((n) => startsWith(m.target, m.from.concat(n)))) return "Bir klasör kendi içine taşınamaz.";
    return "";
  }
  function renderMove() {
    if (!M) return;
    const tree = $("move-tree");
    tree.textContent = "";
    const walk = (parts, depth) => {
      const key = parts.join("/"), kids = M.cache.get(key);
      const blocked = M.names.some((n) => startsWith(parts, M.from.concat(n)));
      const open = depth === 0 || M.open.has(key);
      const leaf = (Array.isArray(kids) && !kids.length) || M.counts.get(key) === 0;
      const chev = depth > 0 && !blocked && !leaf
        ? h("button", { type: "button", class: "tchev", "aria-label": open ? "Kapat" : "Aç", "aria-expanded": open,
          onclick: () => { if (open) M.open.delete(key); else { M.open.add(key); loadNode(key); } renderMove(); } }, svg(open ? "chevDown" : "chevRight"))
        : h("span", { class: "tchev" });
      const row = h("div", { class: "tnode" + (same(M.target, parts) ? " on" : ""), role: "treeitem" }, chev,
        h("button", { type: "button", class: "tpick", disabled: blocked, "aria-pressed": same(M.target, parts),
          onclick: () => { M.target = parts; M.error = ""; renderMove(); } }, svg("folder"),
          h("span", { class: depth === 0 ? "root-path" : "" }, depth === 0 ? S.st.root : parts[parts.length - 1])));
      row.style.setProperty("--d", String(depth));
      tree.append(row);
      if (!open || blocked) return;
      if (!Array.isArray(kids)) {
        const wait = h("div", { class: "tnode" }, h("span", { class: "tchev" }), h("span", { class: "tload" }, "Yükleniyor…"));
        wait.style.setProperty("--d", String(depth + 1));
        tree.append(wait);
        return;
      }
      kids.filter((k) => S.hidden || !k.name.startsWith(".")).sort((a, b) => COLL.compare(a.name, b.name))
        .forEach((k) => walk(parts.concat(k.name), depth + 1));
    };
    walk([], 0);
    const msg = M.target ? moveError(M) || M.error : "";
    $("move-dest").textContent = M.target ? rootPath(M.target) : "Bir klasör seçin";
    $("move-err").textContent = msg;
    $("move-err").hidden = !msg;
    $("move-submit").disabled = !M.target || !!moveError(M) || M.busy;
    $("move-warn").hidden = !M.temp;
  }
  $("move-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const job = M;
    if (!job || !job.target || moveError(job) || job.busy) return;
    job.busy = true;
    renderMove();
    try {
      const r = await api("/api/move", { path: job.from.join("/"), names: job.names, to: job.target.join("/") });
      $("move-dialog").close();
      await afterChange([]);
      toast(`${r.moved.length} öge taşındı: ${rootPath(job.target)}`, false, { label: "Geri al", fn: () => undoMove(r.moved, job.target, job.from) });
    } catch (err) {
      job.busy = false;
      job.error = err.message;
      renderMove();
      await afterChange();
    }
  });
  $("move-dialog").addEventListener("close", () => { M = null; });

  // ---- silme ve çöp ----
  let DEL = null;
  function openDelete(items) {
    if (!items.length) return;
    DEL = { parts: S.parts.slice(), names: items.map((x) => x.name) };
    $("del-title").textContent = items.length === 1 ? `“${items[0].name}” çöpe taşınsın mı?` : `${items.length} öge çöpe taşınsın mı?`;
    $("del-total").textContent = fmtSize(totalOf(items));
    const list = $("del-list");
    list.textContent = "";
    items.slice(0, 5).forEach((x) => list.append(h("li", null,
      h("span", { class: "dn" }, typeIcon(x), h("span", null, x.name)), h("span", { class: "mono" }, fmtSize(x.size)))));
    if (items.length > 5) list.append(h("li", { class: "more" }, `ve ${items.length - 5} öge daha`));
    $("del-warn").hidden = !(inTemp(S.parts) || items.some((x) => isTempDir(S.parts, x.name)));
    $("del-err").hidden = true;
    $("del-submit").disabled = false;
    $("del-dialog").showModal();
    $("del-submit").focus();
  }
  $("del-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const job = DEL;
    if (!job) return;
    $("del-submit").disabled = true;
    try {
      const r = await api("/api/trash", { path: job.parts.join("/"), names: job.names });
      DEL = null;
      $("del-dialog").close();
      await afterChange([]);
      toast(`${r.ids.length} öge çöpe taşındı.`, false, { label: "Geri al", fn: () => restoreIds(r.ids, true) });
    } catch (err) {
      $("del-err").textContent = err.message;
      $("del-err").hidden = false;
      await afterChange();
    }
  });

  async function restoreIds(ids, undo) {
    try {
      const r = await api("/api/trash/restore", { ids });
      await afterChange();
      const first = r.restored[0];
      if (undo) toast(`${r.restored.length} öge geri yüklendi.`);
      else if (first) {
        const at = splitPath(first.path);
        toast(`Geri yüklendi: ${rootPath(at.concat(first.name))}`, false, { label: "Göster", fn: () => go(at) });
      }
    } catch (e) {
      toast(e.message, true);
      await afterChange();
    }
  }

  async function showTrash(push) {
    try {
      S.trash = (await api("/api/trash")).items;
    } catch (e) { toast(e.message, true); return; }
    S.view = "trash";
    S.sel.clear(); S.renaming = null; S.creating = false; S.confirmPurge = null;
    setRoute(null, push);
    render();
  }
  async function loadTrash() {
    try {
      S.trash = (await api("/api/trash")).items;
      renderTrash();
    } catch (e) { toast(e.message, true); }
  }

  function renderTrash() {
    if (S.view !== "trash") return;
    const p = $("panel");
    p.textContent = "";
    const total = totalOf(S.trash);
    p.append(h("div", { class: "net-head" }, h("span", { class: "big" }, "Çöp"), h("span", { class: "lab num" }, `${S.trash.length} öge · ${fmtSize(total)}`)));
    p.append(h("div", { class: "infoline" }, svg("info"), h("span", null,
      "Silinen ögeler indirme klasöründeki gizli çöp klasöründe durur: disk alanı boşalmaz, geri yüklenebilir. Kalıcı silinince alan boşalır.")));
    const box = h("div", { class: "files trash" });
    box.append(h("div", { class: "frow head" }, h("span", null, "Ad"), h("span", null, "Nereden"), h("span", { class: "r" }, "Boyut"), h("span", null, "Silinme"), h("span")));
    if (!S.trash.length) box.append(h("div", { class: "empty" }, h("strong", null, "Çöp boş"), h("span", null, "Silinen dosyalar burada görünür.")));
    S.trash.forEach((t) => box.append(trashRow(t)));
    p.append(box);
    if (!S.trash.length) return;
    const btn = h("button", { type: "button", class: "btn btn-danger btn-sm", disabled: true, onclick: async () => {
      btn.disabled = true;
      try {
        const r = await api("/api/trash/empty", { confirm: $("purge-word").value });
        await afterChange();
        toast(`${r.purged} öge kalıcı silindi; ${fmtSize(total)} boşaldı.`);
      } catch (e) {
        toast(e.message, true);
        await afterChange();
      }
    } }, "Çöpü boşalt");
    p.append(h("section", { class: "danger" }, h("div", { class: "danger-item" },
      h("div", null, h("h2", null, "Çöpü boşalt"), h("p", null, `${S.trash.length} öge, ${fmtSize(total)} kalıcı silinir ve disk alanı boşalır. Geri alınamaz.`)),
      h("div", { class: "confirm-field" },
        h("label", { for: "purge-word" }, "Onay için onayla yazın"),
        h("input", { type: "text", id: "purge-word", autocomplete: "off", spellcheck: "false",
          oninput: (e) => { btn.disabled = e.target.value.trim().toLocaleLowerCase("tr") !== CONFIRM_WORD; } }),
        btn))));
  }

  function trashRow(t) {
    const actions = S.confirmPurge === t.id
      ? h("div", { class: "ract" }, h("span", { class: "confirm-q" }, "Kalıcı silinsin mi?"),
        h("button", { type: "button", class: "btn btn-quiet btn-sm", onclick: () => { S.confirmPurge = null; renderTrash(); } }, "Vazgeç"),
        h("button", { type: "button", class: "btn btn-danger btn-sm", onclick: async () => {
          S.confirmPurge = null;
          try {
            await api("/api/trash/purge", { ids: [t.id] });
            toast(`“${t.name}” kalıcı silindi; ${fmtSize(t.size)} boşaldı.`);
          } catch (e) { toast(e.message, true); }
          await afterChange();
        } }, "Sil"))
      : h("div", { class: "ract" },
        t.broken ? null : h("button", { type: "button", class: "btn btn-quiet btn-sm", onclick: () => restoreIds([t.id], false) }, svg("restore"), "Geri yükle"),
        h("button", { type: "button", class: "btn btn-quiet btn-sm danger-q", onclick: () => { S.confirmPurge = t.id; renderTrash(); } }, "Kalıcı sil"));
    return h("div", { class: "frow" },
      h("div", { class: "fname static" }, typeIcon(t), h("span", { class: "nm" }, h("span", { class: "nt" }, t.name),
        h("small", { class: "meta" }, t.type === "dir" && t.count != null ? h("span", null, `${t.count} öge`) : null,
          h("span", { class: "m-narrow num" }, `${fmtSize(t.size)} · ${fmtDate(t.deleted)}`)))),
      h("span", { class: "from" }, t.from == null ? "bilinmiyor (köke döner)" : rootPath(splitPath(t.from))),
      h("span", { class: "c-size" }, fmtSize(t.size)),
      h("span", { class: "c-date" }, fmtDate(t.deleted)),
      h("div", { class: "c-act" }, actions));
  }

  // ---- metin görüntüleyici (sunucu çözer; içerik yalnız metin düğümü olarak eklenir) ----
  let V = null;
  function openViewer(n) {
    const list = visible().filter(previewable).map((x) => x.name);
    V = { parts: S.parts.slice(), list, index: Math.max(0, list.indexOf(n.name)), enc: "auto", wrap: true, data: null, error: "", req: 0 };
    $("view-dialog").showModal();
    showViewerFile();
    $("view-text").focus();
  }
  function showViewerFile() {
    V.enc = "auto";
    V.wrap = !/\.nfo$/i.test(V.list[V.index]);
    loadViewer();
  }
  async function loadViewer() {
    const v = V, req = ++v.req, name = v.list[v.index];
    v.data = null;
    v.error = "";
    renderViewer();
    $("view-text").scrollTop = 0;
    $("view-text").scrollLeft = 0;
    try {
      const d = await api(`/api/text?path=${q(v.parts.concat(name))}&enc=${encodeURIComponent(v.enc)}`);
      if (V !== v || v.req !== req) return;
      v.data = d;
    } catch (e) {
      if (V !== v || v.req !== req) return;
      v.error = e.message;
    }
    renderViewer();
  }
  function renderViewer() {
    const v = V;
    if (!v) return;
    const name = v.list[v.index], d = v.data;
    $("view-icon").replaceChildren(typeIcon({ name, type: "file" }));
    $("view-title").textContent = name;
    $("view-sub").textContent = d ? `${rootPath(v.parts)} · ${fmtSize(d.size)} · ${fmtDate(d.mtime)}` : rootPath(v.parts);
    $("view-count").textContent = `${v.index + 1} / ${v.list.length}`;
    $("view-prev").disabled = v.index === 0;
    $("view-next").disabled = v.index === v.list.length - 1;
    const sel = $("view-enc");
    sel.options[0].textContent = d ? `Otomatik (${ENC_LABEL[d.detected] || d.detected})` : "Otomatik";
    sel.value = v.enc;
    $("view-wrap").checked = v.wrap;
    $("view-trunc").hidden = !(d && d.truncated);
    if (d && d.truncated) $("view-trunc-text").textContent = `Dosya ${fmtSize(d.size)}; ilk ${fmtSize(S.st.textLimit)} gösteriliyor. Tamamı için indirin.`;
    const view = $("view-text");
    view.className = "textview" + (v.wrap ? " wrapped" : "");
    view.textContent = "";
    if (!d) {
      view.append(h("span", { class: "l msg" }, v.error || "Yükleniyor…"));
      return;
    }
    const frag = document.createDocumentFragment();
    d.text.replace(/\n$/, "").split("\n").forEach((line) => frag.append(h("span", { class: "l" }, line.replace(/\r$/, ""))));
    view.append(frag);
  }
  $("view-prev").addEventListener("click", () => { if (V && V.index > 0) { V.index--; showViewerFile(); } });
  $("view-next").addEventListener("click", () => { if (V && V.index < V.list.length - 1) { V.index++; showViewerFile(); } });
  $("view-enc").addEventListener("change", (e) => { V.enc = e.target.value; loadViewer(); });
  $("view-wrap").addEventListener("change", (e) => { V.wrap = e.target.checked; renderViewer(); });
  $("view-dl").addEventListener("click", () => { if (V) download(V.parts.concat(V.list[V.index])); });
  $("view-dialog").addEventListener("keydown", (e) => {
    if (e.target.tagName === "SELECT" || e.target.tagName === "INPUT") return;
    if (e.key === "ArrowLeft") $("view-prev").click();
    else if (e.key === "ArrowRight") $("view-next").click();
  });
  $("view-dialog").addEventListener("close", () => { V = null; });

  // ---- genel olaylar ----
  document.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => b.closest("dialog").close()));
  $("new-folder").addEventListener("click", () => {
    if (S.view !== "files") return;
    S.creating = true;
    S.renaming = null;
    renderList();
  });
  $("sel-rename").addEventListener("click", () => { const s = selNodes(); if (s.length === 1) startRename(s[0]); });
  $("sel-move").addEventListener("click", () => openMove(selNodes()));
  $("sel-del").addEventListener("click", () => openDelete(selNodes()));
  $("sel-clear").addEventListener("click", () => { S.sel.clear(); S.last = null; syncSel(); });

  document.addEventListener("keydown", (e) => {
    if (document.querySelector("dialog[open]") || S.view !== "files") return;
    const t = e.target;
    if ((t.tagName === "INPUT" && t.type !== "checkbox") || t.tagName === "TEXTAREA" || t.tagName === "SELECT") return;
    if ((e.metaKey && e.key === "Backspace") || e.key === "Delete") {
      const s = selNodes();
      if (s.length) { e.preventDefault(); openDelete(s); }
    } else if (e.key === "Backspace" || (e.altKey && e.key === "ArrowUp")) {
      if (S.parts.length) { e.preventDefault(); go(S.parts.slice(0, -1)); }
    } else if (e.key === "F2") {
      const s = selNodes();
      if (s.length === 1) { e.preventDefault(); startRename(s[0]); }
    } else if (e.key === "Escape") {
      S.sel.clear(); S.last = null; syncSel();
    } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "a") {
      e.preventDefault();
      visible().forEach((n) => S.sel.add(n.name));
      syncSel();
    } else if (/^Arrow(Down|Up|Left|Right)$/.test(e.key)) {
      const grid = S.layout === "grid";
      if (!grid && (e.key === "ArrowLeft" || e.key === "ArrowRight")) return;
      const btns = [...document.querySelectorAll("#files button.fname, #files button.tbody")];
      if (!btns.length) return;
      e.preventDefault();
      const cols = grid ? getComputedStyle($("files")).gridTemplateColumns.split(" ").length : 1;
      const step = { ArrowDown: cols, ArrowUp: -cols, ArrowRight: 1, ArrowLeft: -1 }[e.key];
      const i = btns.indexOf(document.activeElement);
      btns[i < 0 ? 0 : Math.min(btns.length - 1, Math.max(0, i + step))].focus();
    } else if (e.key === " " && t.classList && (t.classList.contains("fname") || t.classList.contains("tbody"))) {
      e.preventDefault();
      const items = visible(), n = S.entries.find((x) => x.name === t.closest("[data-name]").dataset.name);
      if (n) toggle(n, items.indexOf(n), items, e.shiftKey);
    }
  });

  // Sekmeye dönünce liste tazelenir (qBittorrent bu arada dosya eklemiş olabilir).
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible" || !S.st) return;
    if (document.querySelector("dialog[open]") || S.renaming || S.creating || drag) return;
    afterChange();
  });

  // İki panel arasında geçiş: wg.<alan> ⇄ dosya.<alan> (yalnız Caddy adıyla açılınca).
  if (location.hostname.startsWith("dosya.")) {
    $("app-wg").href = `${location.protocol}//wg.${location.hostname.slice(6)}${location.port ? ":" + location.port : ""}/`;
    $("apps").hidden = false;
  }

  (async () => {
    await refreshState();
    if (!S.st) {
      $("panel").replaceChildren(h("p", { class: "hint" }, "Panel durumu okunamadı; sayfayı yenileyin."));
      return;
    }
    await route();
  })();
})();
