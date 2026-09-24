/* Built-in ZIP jobs. Progress is reported by the server, never simulated. */
"use strict";
window.createArchiveTools = function ({h, api, post, toast, fail, bytes, showDialog, closeDialog, root, refresh, openFolder}) {
  let jobs = [], limits = null, timer = null, loading = false, started = false;
  const active = (job) => ["queued", "running"].includes(job.status);
  const labels = {queued:"Sırada", running:"Çalışıyor", done:"Tamamlandı", skipped:"Atlandı", failed:"Başarısız", cancelled:"İptal edildi", interrupted:"Kesildi"};
  const containers = new Set();
  function paint() {
    for (const container of containers) {
      if (!container.isConnected) { containers.delete(container); continue; }
      const opened = container.firstElementChild?.open;
      const details = h("details", {class:"archive-panel", open:opened || jobs.some(active)},
        h("summary", null, `Arşiv işlemleri · ${jobs.filter(active).length} çalışıyor · ${jobs.length} kayıt`),
        h("div", {class:"archive-status", "aria-live":"polite"},
          ...jobs.slice(0,20).map((job) => h("div", {class:`archive-row ${job.status}`},
            h("div", null, h("strong", null, `${job.name} · ${labels[job.status] || job.status}`),
              h("small", null, job.message), h("small", null, `${job.entries} öge · ${bytes(job.bytes)} işlendi${job.archives ? ` · ${job.archives} ZIP` : ""}`)),
            active(job) ? h("button", {type:"button", class:"btn btn-sm btn-quiet", onclick: async (e) => {
              e.currentTarget.disabled = true;
              try { await post("/api/archives/cancel", {id:job.id}); await load(); } catch (err) { fail(err); await load(); }
            }}, "İptal et") : job.result ? h("button", {type:"button", class:"btn btn-sm btn-quiet", onclick:() => openFolder(job.operation === "unzip" ? job.result : job.target)}, "Sonucu göster") : null)),
          !jobs.length ? h("p", {class:"archive-limits"}, "Henüz işlem yok. Bir dosya veya klasör seçip ZIP oluşturabilir; ZIP dosyasının ayrıntılarından açabilirsiniz.") : null));
      container.replaceChildren(details);
    }
  }
  async function load(report = false) {
    if (loading) return;
    loading = true;
    try {
      const data = await api("/api/archives");
      const previous = new Map(jobs.map((j) => [j.id, j]));
      jobs = data.items; limits = data.limits;
      for (const job of jobs) if (started && !active(job) && previous.has(job.id) && active(previous.get(job.id))) {
        toast(`${job.name}: ${job.message}`);
        if (job.status === "done") refresh();
      }
      started = true;
      paint();
    } catch (err) { if (report) fail(err); }
    finally {
      loading = false; clearTimeout(timer);
      timer = setTimeout(() => { if (!document.hidden) load(); else timer = null; }, jobs.some(active) ? 1500 : 10000);
    }
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden && started) load(); });
  function mount(container) { containers.add(container); paint(); load(true); }
  function open(operation, path, items) {
    const unzip = operation === "unzip";
    const initial = items.length === 1 ? items[0].name.replace(/\.zip$/i, "") : "arsiv";
    const field = (label, input) => h("label", null, label, input);
    const name = h("input", {id:"archive-name", required:true, value:unzip ? initial || "acilan" : initial + ".zip", maxlength:150, autocomplete:"off"});
    const target = h("input", {id:"archive-target", value:path, autocomplete:"off", placeholder:`${root()} kökü için boş bırakın`});
    const nested = h("input", {id:"archive-nested", type:"checkbox", checked:true});
    const layers = h("select", {id:"archive-layers"}, ...[1,2,3,4,5].map((n) => h("option", {value:String(n), selected:n === 3}, `${n} katman`)));
    const conflict = h("select", {id:"archive-conflict"}, ...[["rename","Yeni ad ver: ad (2)"],["skip","Sonucu atla"],["stop","İşlemi durdur"]].map(([value,label]) => h("option", {value}, label)));
    const error = h("p", {class:"err-s", role:"alert", hidden:true});
    const submit = h("button", {type:"submit", class:"btn btn-primary"}, unzip ? "ZIP aç" : "ZIP oluştur");
    const form = h("form", {class:"dav-form", onsubmit:async (event) => {
      event.preventDefault(); submit.disabled = true; error.hidden = true;
      try {
        const response = await post("/api/archives", {operation,path,names:items.map((item) => item.name),target:target.value.trim(),name:name.value.trim(),nested:unzip && nested.checked,layers:Number(layers.value),conflict:conflict.value});
        jobs = [response.job, ...jobs.filter((j) => j.id !== response.job.id)].slice(0,20);
        started = true;
        closeDialog(); toast("Arşiv işlemi başladı; sayfa kapansa da sunucuda sürer."); await load(true);
      } catch (err) { error.textContent = err.message; error.hidden = false; submit.disabled = false; }
    }}, h("p", {class:"hint-s"}, `${items.length} öge · ${root()}/${path}`),
    field(unzip ? "Yeni sonuç klasörü" : "ZIP dosya adı", name), field(`Hedef klasör · ${root()} altında göreli yol`, target),
    unzip ? h("label", {class:"dav-check"}, nested, "İç içe ZIP dosyalarını da aç") : null,
    unzip ? field("Katman sınırı (ilk ZIP dahil)", layers) : null,
    field("Hedefte sonuç adı zaten varsa", conflict),
    h("p", {class:"archive-limits"}, "Kaynaklar silinmez; mevcut dosyaların üzerine yazılmaz. Açılan içerik yeni bir klasörde toplanır. İç ZIP dosyaları da korunur. ",
      limits ? `${bytes(limits.bytes)} toplam işlenen veri · ${limits.entries.toLocaleString("tr-TR")} öge · ${limits.seconds / 60} dakika · aynı anda tek işlem. ` : "",
      "Yalnız şifresiz ZIP (Store/Deflate); ZIP64, RAR ve 7z desteklenmez. İçerikte çakışan/güvensiz ad veya bozuk ZIP varsa hiçbir sonuç yayımlanmaz."),
    error, h("div", {class:"dlg-foot"}, h("button", {type:"button", class:"btn btn-quiet", onclick:closeDialog}, "Vazgeç"), submit));
    showDialog(unzip ? "ZIP aç" : "ZIP oluştur", form); name.focus(); name.select();
  }
  return {mount, load, open};
};
