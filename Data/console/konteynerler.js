/* Ayarlar → Konteynerler (DD-208): tabandaki Podman'ın salt okunur görünümü. Kabuk bu fabrikayı
   bir kez kurar; görünümün kök düğümü kalıcıdır, Ayarlar her çizimde aynı düğümü yerine koyar, böylece
   açık ayrıntı ve günlük kartı durumunu korur. Yalnız /api/konsol/konteynerler/* yollarını GET ile
   okur: konteyner başlatma, durdurma ve silme yoktur (konteyner onu kuran uygulamanındır); durum,
   bağlamalar, portlar ve maskelenmiş günlük gösterilir. Satırlar ada göre yerinde güncellenir,
   açık günlük yerinde yenilenir (kaydırma korunur). CSP altında: satır içi biçem ve betik yok. */
"use strict";
window.createContainersView = ({ h, svg, api, enc, fail, bytes, since, clock, stamp }) => {
  const BASE = "/api/konsol/konteynerler";
  const root = h("div", { class: "pd-root", id: "pd-root" },
    h("div", { class: "card pd-head", id: "pd-head" }),
    h("div", { class: "table pd-list", id: "pd-list", hidden: true }),
    h("div", { class: "table pd-empty", id: "pd-empty", hidden: true }));
  // Kök belgeye bağlı olmasa da (başka sekme) kendi içinde aranır.
  const $ = (id) => root.querySelector("#" + id);
  const TAILS = [100, 200, 500, 1000];
  let LIST = null, listFailed = false, readAt = 0;
  let open = "";                                   // açık ayrıntının konteyner adı (tek ayrıntı)
  let DETAIL = null, detailError = "", detailSeq = 0;
  let LOG = null, logError = "", logTail = 200, logOpen = false, logSeq = 0, logPending = false;
  let mountsKey = "", portsKey = "";             // ayrıntı tabloları yalnız içerik değişince yeniden kurulur
  let want = "";                                  // derin bağlantının açmak istediği konteyner
  const hhmm = (at) => new Date(at * 1000).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
  const when = (at) => (at ? new Date(at * 1000).toLocaleString("tr-TR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "—");

  /* ---------- küçük yapı taşları ---------- */
  const card = (title, subtitle, icon, ...body) => h("article", { class: "card pd-card" },
    h("div", { class: "card-head" }, h("div", null, h("h2", null, icon ? svg(icon) : null, title), subtitle ? h("small", { class: "hint-s" }, subtitle) : null)), ...body);
  const fact = (dt, dd, small, cls) => h("div", { class: cls || null }, h("dt", null, dt), h("dd", null, dd, small ? [" ", h("small", null, small)] : null));
  const mono = (text) => h("span", { class: "mono" }, text);
  const STATE = {
    running: ["ok", "Çalışıyor"], exited: ["idle", "Durdu"], created: ["idle", "Oluşturuldu"],
    paused: ["warn", "Duraklatıldı"], stopping: ["warn", "Durduruluyor"], unknown: ["warn", "Bilinmiyor"],
  };
  function statePill(c) {
    const [tone, label] = STATE[c.state] || ["warn", c.state || "Bilinmiyor"];
    const text = c.state === "exited" ? `Durdu (çıkış ${Number.isFinite(c.exit_code) ? c.exit_code : "?"})` : label;
    return h("span", { class: `hm ${tone} pd-state` }, c.state === "running" ? h("span", { class: "dotmark live", "aria-hidden": "true" }) : null, text);
  }
  const HEALTH = { healthy: ["ok", "Sağlıklı"], unhealthy: ["bad", "Sağlıksız"], starting: ["warn", "Başlıyor"] };
  const healthPill = (hs) => (HEALTH[hs] ? h("span", { class: `hm ${HEALTH[hs][0]}` }, HEALTH[hs][1]) : "—");
  const portText = (p) => `${p.host_port}→${p.container_port}/${p.protocol || "tcp"}`;
  const portSummary = (c) => ((c.ports || []).length ? c.ports.map(portText).join(", ") : c.network === "host" ? "host ağı" : "port yok");
  const anyIp = (ip) => !ip || ip === "0.0.0.0" || ip === "::";
  function timeText(c) {
    const base = c.state === "running" && c.started ? `Başladı ${since(c.started)}` : `Oluşturuldu ${since(c.created)}`;
    return c.restarts ? `${base} · ${c.restarts} yeniden başlatma` : base;
  }
  const runtimeError = (rt) => (/^Podman kullanılamıyor/.test(rt.error || "") ? rt.error : `Podman kullanılamıyor: ${rt.error || "bilinmeyen hata"}`);

  /* ---------- liste (tabanın salt okunur API'si) ---------- */
  function loadList() {
    return api(`${BASE}/liste`).then((d) => {
      LIST = d; listFailed = false; readAt = Date.now() / 1000;
      if (Number.isFinite(d.read_at)) clock.sync(d.read_at);
      paint();
      if (want && (d.containers || []).some((c) => c.name === want) && open !== want) toggle(want);
      want = "";
    }).catch((e) => { listFailed = true; paint(); fail(e); });
  }
  function renderHead() {
    const box = $("pd-head");
    if (!box) return;
    if (!LIST) {
      box.replaceChildren(h("div", { class: "pd-runtime" }, svg("box"),
        listFailed ? h("span", { class: "hm warn" }, "Konteyner listesi okunamadı") : h("span", { class: "hm" }, "Okunuyor…")));
      return;
    }
    const rt = LIST.runtime || {}, cs = rt.ok ? LIST.containers || [] : [], st = LIST.storage || {};
    const running = cs.filter((c) => c.state === "running").length;
    box.replaceChildren(
      h("div", { class: "pd-runtime" }, svg("box"),
        rt.ok ? h("span", { class: "hm ok" }, h("span", { class: "dotmark live", "aria-hidden": "true" }), `Podman ${rt.version} · çalışıyor`)
          : h("span", { class: "hm warn pd-wrap" }, runtimeError(rt)),
        listFailed ? h("span", { class: "hm warn" }, "Son okuma başarısız") : null),
      rt.ok ? h("dl", { class: "pd-counts" },
        fact("Konteyner", String(cs.length), `${running} çalışıyor`),
        fact("İmaj", String((LIST.images || []).length)),
        fact("Depolama", bytes(st.size))) : null);
  }
  const rowOf = (name) => [...($("pd-list") || { children: [] }).children].find((r) => r.dataset.name === name) || null;
  function rowCells(c) {
    return [
      statePill(c),
      h("span", { class: "pd-who" }, h("strong", null, c.name), h("span", { class: "mono pd-image" }, c.image || "—")),
      h("span", { class: "pd-meta" }, h("span", null, timeText(c)), c.unit ? h("span", { class: "mono pd-unit" }, c.unit) : null),
      h("span", { class: "pd-ports" }, portSummary(c)),
      h("span", { class: "pd-mounts" }, c.mounts ? `${c.mounts} bağlama` : "bağlama yok"),
      h("span", { class: "pd-chev", "aria-hidden": "true" }, svg("chev")),
    ];
  }
  function makeRow(c) {
    return h("article", { class: "pd-row", "data-name": c.name },
      h("button", { type: "button", class: "pd-rowbtn", "data-name": c.name, "aria-expanded": false, onclick: () => toggle(c.name) }));
  }
  // Satırlar ada göre yerinde güncellenir: açık ayrıntı (ve günlüğü) olduğu yerde kalır, odak kaybolmaz.
  function renderList() {
    const list = $("pd-list"), empty = $("pd-empty");
    if (!list) return;
    const rt = (LIST && LIST.runtime) || {}, cs = LIST && rt.ok ? LIST.containers || [] : [];
    const keep = new Set();
    cs.forEach((c, i) => {
      let row = rowOf(c.name);
      if (!row) row = makeRow(c);
      keep.add(c.name);
      const btn = row.querySelector(".pd-rowbtn");
      btn.replaceChildren(...rowCells(c));
      btn.setAttribute("aria-expanded", String(open === c.name));
      if (open === c.name) btn.setAttribute("aria-controls", "pd-detail"); else btn.removeAttribute("aria-controls");
      row.classList.toggle("pd-open", open === c.name);
      if (list.children[i] !== row) list.insertBefore(row, list.children[i] || null);
    });
    [...list.children].forEach((row) => { if (!keep.has(row.dataset.name)) row.remove(); });
    if (open && !keep.has(open)) closeDetail();
    list.hidden = !cs.length;
    empty.hidden = !!cs.length;
    if (cs.length) { empty.replaceChildren(); return; }
    if (!LIST) {
      empty.replaceChildren(h("div", { class: "empty-row" }, h("strong", null, listFailed ? "Konteyner listesi okunamadı" : "Okunuyor…"),
        h("span", null, listFailed ? "Yenile ile tekrar deneyin." : "")));
    } else if (!rt.ok) {
      empty.replaceChildren(h("div", { class: "empty-row" }, h("strong", null, "Konteynerler okunamadı"),
        h("span", null, rt.error || "Podman yanıt vermedi."), h("span", null, "Podman kurulumla gelir; kurulumu yeniden çalıştırın, sonra Yenile’ye basın.")));
    } else {
      empty.replaceChildren(h("div", { class: "empty-row" }, h("strong", null, "Henüz konteyner yok."),
        h("span", null, "Konteynerler App Store’dan kurulan uygulamalarla gelir; burada durumlarını, bağlamalarını, portlarını ve günlüklerini görürsünüz.")));
    }
  }

  /* ---------- ayrıntı: tek açık konteyner ---------- */
  function toggle(name) {
    if (open === name) { closeDetail(); renderList(); return; }
    closeDetail();
    const row = rowOf(name);
    if (!row) return;
    open = name;
    row.append(buildDetail(name));
    renderList();
    loadDetail();
    if (logOpen) loadLog(true);
  }
  function closeDetail() {
    const d = $("pd-detail");
    if (d) d.remove();
    open = ""; DETAIL = null; detailError = ""; LOG = null; logError = ""; logPending = false; mountsKey = portsKey = "";
    detailSeq++; logSeq++;
  }
  function buildDetail(name) {
    return h("div", { class: "pd-detail", id: "pd-detail" },
      card("Ayrıntılar", "", "info", h("div", { id: "pd-facts" }, h("p", { class: "hint-s" }, "Okunuyor…"))),
      h("div", { class: "pd-grid" },
        card("Bağlamalar", "Konteyner yolu → sunucu yolu", "folder", h("div", { id: "pd-mounts" })),
        card("Portlar", "Sunucuda dinlenen portlar", "globe", h("div", { id: "pd-ports" }))),
      logCard(name));
  }
  function loadDetail() {
    const name = open, seq = ++detailSeq;
    if (!name) return Promise.resolve();
    return api(`${BASE}/ayrinti?ad=${enc(name)}`).then((d) => {
      if (open !== name || seq !== detailSeq) return;
      DETAIL = d; detailError = ""; renderDetail();
    }).catch((e) => {
      if (open !== name || seq !== detailSeq) return;
      detailError = e.message; renderDetail();
    });
  }
  function renderDetail() {
    const facts = $("pd-facts"), mounts = $("pd-mounts"), ports = $("pd-ports");
    if (!facts || !mounts || !ports) return;
    if (detailError) {
      facts.replaceChildren(h("p", { class: "err-s", role: "alert" }, detailError));
      mounts.replaceChildren(); ports.replaceChildren();
      return;
    }
    if (!DETAIL) { facts.replaceChildren(h("p", { class: "hint-s" }, "Okunuyor…")); return; }
    const d = DETAIL, lab = d.labels || {}, running = d.state === "running";
    facts.replaceChildren(h("dl", { class: "pd-facts" }, ...[
      fact("Durum", statePill(d)),
      fact("Sağlık", healthPill(d.health)),
      fact("Kimlik", mono(d.id || "—")),
      fact("İmaj", mono(d.image || "—"), d.image_digest ? `sha256:${d.image_digest}…` : ""),
      fact("Ağ", d.network || "—"),
      fact("Oluşturuldu", when(d.created)),
      fact("Başladı", d.started ? since(d.started) : "—", d.started ? when(d.started) : ""),
      // Çalışan konteynerde inspect eski FinishedAt'i taşır; "Bitti" yalnız durmuş konteyner için anlamlı.
      fact("Bitti", !running && d.finished ? since(d.finished) : "—", running ? "" : d.finished ? `${when(d.finished)} · çıkış ${d.exit_code}` : `çıkış ${d.exit_code}`),
      fact("Yeniden başlatma", String(d.restarts || 0)),
      fact("Birim", d.unit ? mono(d.unit) : "—"),
      lab.version ? fact("Sürüm", lab.version) : null,
      lab.title ? fact("Başlık", lab.title) : null,
      // Kaynak adresi düz metindir, bağlantı değil: sayfa dış adres açmaz (CSP).
      lab.source ? fact("Kaynak", h("span", { class: "pd-src" }, lab.source)) : null,
      fact("Komut", d.command ? mono(d.command) : "—", "", "pd-cmd"),
    ].filter(Boolean)));
    const mk = JSON.stringify(d.mounts || []), pk = JSON.stringify([d.network, d.ports || []]);
    if (mk !== mountsKey || !mounts.childElementCount) { mountsKey = mk; mounts.replaceChildren(mountsTable(d.mounts || [])); }
    if (pk !== portsKey || !ports.childElementCount) { portsKey = pk; ports.replaceChildren(...portsBlock(d)); }
  }
  const MOUNT_TYPE = { bind: "Klasör (bind)", volume: "Birim (volume)", tmpfs: "Bellek (tmpfs)" };
  function mountsTable(list) {
    if (!list.length) return h("p", { class: "hint-s" }, "Bağlama yok.");
    return h("div", { class: "table pd-t pd-mounts-t" },
      h("div", { class: "tr head" }, h("span", null, "Konteyner yolu"), h("span", null, "Sunucu yolu"), h("span", null, "Erişim"), h("span", null, "Tür")),
      ...list.map((m) => h("div", { class: "tr" },
        h("span", { class: "mono pd-path", "data-l": "Konteyner yolu" }, m.destination || "—"),
        h("span", { class: "mono pd-path", "data-l": "Sunucu yolu" }, m.source || m.name || "—"),
        h("span", { "data-l": "Erişim" }, h("span", { class: "hm" + (m.rw ? "" : " idle") }, m.rw ? "RW" : "RO")),
        h("span", { "data-l": "Tür" }, MOUNT_TYPE[m.type] || m.type || "—"))));
  }
  function portsBlock(d) {
    const out = [], ports = d.ports || [];
    if (d.network === "host") out.push(h("p", { class: "as-note pd-note" }, "Konteyner sunucunun ağını doğrudan kullanır (host)."));
    if (ports.length) {
      out.push(h("div", { class: "table pd-t pd-ports-t" },
        h("div", { class: "tr head" }, h("span", null, "Sunucu"), h("span", null, "Konteyner"), h("span", null, "Protokol")),
        ...ports.map((p) => h("div", { class: "tr" },
          h("span", { class: "mono", "data-l": "Sunucu" }, String(p.host_port), anyIp(p.host_ip) ? null : h("small", { class: "pd-ip" }, ` ${p.host_ip}`)),
          h("span", { class: "mono", "data-l": "Konteyner" }, String(p.container_port)),
          h("span", { "data-l": "Protokol" }, p.protocol || "tcp")))));
    } else if (d.network !== "host") out.push(h("p", { class: "hint-s" }, "Yayınlanan port yok."));
    return out;
  }

  /* ---------- günlük: yerinde güncellenir, kaydırma korunur ---------- */
  function logCard(name) {
    const det = h("details", { class: "card pd-card pd-logcard", id: "pd-logcard", open: logOpen },
      h("summary", null, h("h2", null, svg("file"), "Günlük"), h("small", { class: "hint-s", id: "pd-log-sub" }, `son ${logTail} satır`)),
      h("div", { class: "pd-logtools" },
        h("div", { class: "pd-tail", role: "group", "aria-label": "Satır sayısı" },
          ...TAILS.map((n) => h("button", { type: "button", class: "btn btn-sm btn-quiet", "aria-pressed": n === logTail, onclick: () => setTail(n) }, String(n)))),
        h("button", { type: "button", class: "btn btn-sm btn-quiet", onclick: () => loadLog(false) }, svg("refresh"), "Yenile")),
      h("pre", { class: "pd-log", id: "pd-log", tabindex: "0", "aria-label": `${name} günlüğü` }, ""),
      h("p", { class: "hint-s", id: "pd-log-hint" }, ""),
      h("p", { class: "as-note pd-note" }, "Gizli görünen değerler (parola, token) arka uçta maskelenir."));
    // Açık doğan <details> da toggle yayar; toggle() zaten yüklemeyi başlattıysa ikinci istek gitmez.
    det.addEventListener("toggle", () => { logOpen = det.open; if (det.open && !LOG && !logPending) loadLog(true); else if (det.open && !logPending) loadLog(false); });
    return det;
  }
  function loadLog(fresh) {
    const name = open, seq = ++logSeq, tail = logTail;
    if (!name) return Promise.resolve();
    logPending = true;
    return api(`${BASE}/gunluk?ad=${enc(name)}&satir=${tail}`).then((r) => {
      if (seq === logSeq) logPending = false;
      if (open !== name || seq !== logSeq) return;
      LOG = r; logError = ""; paintLog(fresh);
    }).catch((e) => {
      if (seq === logSeq) logPending = false;
      if (open !== name || seq !== logSeq) return;
      logError = e.message; paintLog(fresh);
    });
  }
  function paintLog(fresh) {
    const pre = $("pd-log"), hint = $("pd-log-hint"), sub = $("pd-log-sub");
    if (!pre || !hint) return;
    if (sub) sub.textContent = `son ${logTail} satır`;
    if (logError) { hint.className = "err-s"; hint.textContent = logError; return; }
    hint.className = "hint-s";
    const lines = (LOG && Array.isArray(LOG.lines) ? LOG.lines : []).map(String);
    const text = lines.length ? lines.join("\n") : "Günlük kaydı yok.";
    hint.textContent = !lines.length ? "" : LOG.truncated
      ? `Yalnız son ${lines.length} satır gösteriliyor; daha eskisi için satır sayısını artırın.` : `${lines.length} satır · en yenisi altta`;
    pre.classList.toggle("pd-empty", !lines.length);
    // Kaydırma: operatör yukarı kaydırdıysa yeri korunur; en alttaysa (ya da görünüm yeniyse) yeni satırları izler.
    const follow = fresh || pre.scrollHeight - pre.scrollTop - pre.clientHeight < 6;
    if (pre.textContent !== text) pre.textContent = text;
    if (follow) pre.scrollTop = pre.scrollHeight;
  }
  function setTail(n) {
    if (!TAILS.includes(n)) return;
    logTail = n;
    root.querySelectorAll("#pd-logcard .pd-tail button").forEach((b) => b.setAttribute("aria-pressed", String(Number(b.textContent) === n)));
    loadLog(true);
  }

  /* ---------- görünüm ---------- */
  const stampText = () => (readAt ? "Son okuma " + hhmm(readAt) : "Okunuyor…");
  function paint() {
    renderHead();
    renderList();
    if (stamp) stamp(stampText());
  }
  function refresh() {
    loadList();
    if (open) { loadDetail(); if (logOpen) loadLog(false); }
  }
  return {
    content: () => root,
    stampText,
    show(name) { want = name || ""; paint(); refresh(); },
    refresh,
    poll() { if (root.isConnected) refresh(); },
  };
};
