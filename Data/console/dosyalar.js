/* Klasör başına WebDAV yönetimi (DD-158). Parola tarayıcı deposuna yazılmaz. */
window.createSharesPage = function ({ h, svg, post, toast, fail, copyButton, getShares, setShares, root, showDialog, closeDialog, ask }) {
  let busy = false;
  const durations = [["1", "1 gün"], ["7", "7 gün"], ["30", "30 gün"], ["0", "Süresiz"]];
  const stateText = (s) => !s.available ? "Klasör bulunamadı" : s.expired ? "Süresi doldu" : s.paused ? "Duraklatıldı" : "Açık";
  const access = (s) => s.permission === "rw" ? "Okuma ve yazma" : "Salt okunur";
  const expiry = (s) => s.expires ? new Date(s.expires * 1000).toLocaleDateString("tr-TR") : "Süresiz";
  const button = (text, icon, fn, primary = false) => h("button", { type: "button", class: "btn btn-sm " + (primary ? "btn-primary" : "btn-quiet"), onclick: fn }, svg(icon), text);
  const networkChoices = [["tailscale", "Tailscale"], ["wan", "WAN"]];
  const networks = (s) => s?.networks ?? ["tailscale"];
  const networkBadges = (s) => h("div", { class: "dav-network-badges" }, ...networkChoices
    .filter(([value]) => networks(s).includes(value)).map(([value, label]) => h("span", { class: "shchip", "data-network": value }, label)));
  const addresses = (s, boxed = false) => h("div", { class: "dav-addresses" }, ...networkChoices
    .filter(([value]) => networks(s).includes(value)).map(([value, label]) => {
      const url = s.urls?.[value];
      return h("div", { class: "dav-pair", "data-network": value }, h("small", null, `${label} · HTTP`),
        url ? h("div", { class: "dav-address" + (boxed ? " dav-url" : "") }, h("code", null, url), copyButton(url, `${s.name} ${label} adresi`))
          : h("small", null, value === "wan" ? getShares()?.wan?.reason || "WAN adresi kullanılamıyor." : "Tailscale adresi kullanılamıyor."));
    }));
  function warning() {
    return h("details", { class: "dav-boundary" }, h("summary", null, svg("shield"), "Paylaşmadan önce erişim sınırını kontrol edin"),
      h("p", null, "Alıcıya yalnız WebDAV portunu açın; Konsol ve SSH yalnız yöneticide kalmalı. Konsol parolasızdır: panele ulaşan kişi tüm dosyaları yönetebilir. Tailscale ACL/grants kuralları burada değiştirilmez."),
      h("p", null, "Tailscale bağlantısı şifreli tünelde taşınır. WAN üzerinden HTTP, parola ve verileri şifrelemeden gönderir. Dosya kilidi isteyen istemciler bu adresle uyumlu olmayabilir; Infuse/Finder uyumu istemcide ayrıca sınanmalıdır."));
  }
  function update(action, body) {
    if (busy) return Promise.reject(new Error("Paylaşım kaydediliyor; lütfen bekleyin."));
    busy = true; setShares(getShares());
    return post("/api/konsol/paylasim/" + action, body).then((data) => { setShares(data); return data; })
      .finally(() => { busy = false; setShares(getShares()); });
  }
  function options(s) {
    const permission = h("select", { "aria-label": `${s.name} erişim izni`, disabled: busy, onchange: (event) => {
      const value = event.target.value;
      event.target.value = s.permission;
      if (value === s.permission) return;
      const save = () => update("kaydet", { id: s.id, permission: value, ack_write: value === "rw" })
        .then(() => toast("Erişim izni kaydedildi.")).catch(fail);
      if (value === "rw") ask({ title: "Yazma izni açılsın mı?", sub: s.name, go: "Yazma izni ver",
        items: [["info", "Yükleme, üzerine yazma ve kalıcı silme izni verir."]], onOk: save });
      else save();
    } }, ...[["ro", "Salt okunur"], ["rw", "Okuma ve yazma"]].map(([value, label]) =>
      h("option", { value, selected: value === s.permission }, label)));
    const days = h("select", { "aria-label": `${s.name} paylaşım süresi`, disabled: busy, onchange: (event) => {
      const value = days.value === "keep" ? null : Number(days.value);
      event.target.value = s.expires ? "keep" : "0";
      if (value === null || (value === 0 && !s.expires)) return;
      update("kaydet", { id: s.id, days: value }).then(() => toast("Paylaşım süresi kaydedildi.")).catch(fail);
    } }, s.expires ? h("option", { value: "keep", selected: true }, `Bitiş ${expiry(s)}`) : null,
      ...durations.map(([value, label]) => h("option", { value, selected: !s.expires && value === "0" }, label)));
    return [h("div", { class: "dav-cell dav-access" }, h("span", { class: "dav-label" }, "Erişim"), permission),
      h("div", { class: "dav-cell dav-expiry" }, h("span", { class: "dav-label" }, "Süre"), days)];
  }
  function pause(s) {
    return update("durum", { id: s.id, paused: !s.paused }).then(() => toast(s.paused ? "Paylaşım devam ediyor." : "Paylaşım duraklatıldı.")).catch(fail);
  }
  function remove(s) {
    closeDialog();
    ask({ title: `“${s.name}” paylaşımı kaldırılsın mı?`, sub: `${root()}/${s.path}`, danger: true, go: "Paylaşımı kaldır",
      items: [["key", "Bu klasörün adresi ve hesabı iptal edilir."], ["folder", "Klasör ve içindeki dosyalar silinmez."],
        ["info", "WebDAV servisi yenilenir; diğer paylaşımların sürmekte olan aktarımları da kesilir, yeniden bağlanabilirler."]],
      onOk: () => update("kaldir", { id: s.id }).then(() => toast("Paylaşım kaldırıldı; dosyalar korundu.")).catch(fail) });
  }
  function info(s) {
    return h("div", { class: "dav-summary" },
      h("div", { class: "dav-pair" }, h("small", null, "Erişim"), h("strong", null, access(s))),
      h("div", { class: "dav-pair" }, h("small", null, "Kullanıcı"), h("span", null, s.username, copyButton(s.username, "Kullanıcı"))),
      h("div", { class: "dav-pair" }, h("small", null, "Durum · bitiş"), h("span", null, `${stateText(s)} · ${expiry(s)}`)),
      h("div", { class: "dav-pair" }, h("small", null, "Ağ"), networkBadges(s)),
      addresses(s, true),
      h("div", { class: "dav-actions" }, button("Düzenle", "pencil", () => edit(s)),
        button(s.paused ? "Devam ettir" : "Duraklat", s.paused ? "play" : "pause", () => pause(s)),
        button("Kaldır", "trash", () => remove(s))),
      h("p", { class: "hint-s" }, "Mevcut parola geri okunamaz. Gerekirse Düzenle ile yenisini belirleyin."));
  }
  function form(path, existing, onDone) {
    const username = h("input", { id: "dav-user", autocomplete: "off", required: true, minlength: 3, maxlength: 32,
      pattern: "[A-Za-z0-9][A-Za-z0-9._-]{2,31}", value: existing ? existing.username : "", placeholder: "ör. aile-medya" });
    const password = h("input", { type: "password", id: "dav-password", autocomplete: "new-password", required: !existing,
      minlength: 8, maxlength: 256, placeholder: existing ? "Boş bırak: mevcut parola korunsun" : "En az 8 karakter" });
    const target = h("input", { id: "dav-path", required: true, value: path, autocomplete: "off", spellcheck: "false" });
    const hadWan = !!existing && networks(existing).includes("wan");
    const wanAvailable = getShares()?.wan?.available === true;
    const tailscale = h("input", { type: "checkbox", id: "dav-tailscale", checked: networks(existing).includes("tailscale") });
    const wan = h("input", { type: "checkbox", id: "dav-wan", checked: hadWan, disabled: !wanAvailable && !hadWan,
      "aria-describedby": !wanAvailable ? "dav-wan-status" : null });
    const ackWan = h("input", { type: "checkbox", id: "dav-ack-wan" });
    const wanAcknowledgement = h("label", { class: "dav-warning dav-check", hidden: true }, ackWan,
      h("span", null, "WAN üzerinden HTTP, parola ve verileri şifrelemeden gönderir. Onaylıyorum."));
    const validateNetworks = () => {
      tailscale.setCustomValidity(tailscale.checked || wan.checked ? "" : "En az bir ağ seçin: Tailscale veya WAN.");
      ackWan.required = wan.checked && !hadWan;
      wanAcknowledgement.hidden = !ackWan.required;
      if (!ackWan.required) ackWan.checked = false;
    };
    tailscale.addEventListener("change", validateNetworks);
    wan.addEventListener("change", validateNetworks);
    validateNetworks();
    const permission = h("select", { id: "dav-permission", "aria-label": "Erişim izni" },
      h("option", { value: "ro", selected: !existing || existing.permission === "ro" }, "Salt okunur"),
      h("option", { value: "rw", selected: existing && existing.permission === "rw" }, "Okuma ve yazma"));
    const ack = h("input", { type: "checkbox", id: "dav-ack" });
    const acknowledgement = h("label", { class: "dav-warning dav-check", hidden: permission.value !== "rw" }, ack,
      h("span", null, "Yazma; yükleme, üzerine yazma, taşıma ve silmeyi kapsar. WebDAV ile silinenler Çöp'e gitmez. Onaylıyorum."));
    permission.addEventListener("change", () => { acknowledgement.hidden = permission.value !== "rw"; ack.required = permission.value === "rw"; });
    ack.required = permission.value === "rw";
    const days = h("select", { id: "dav-days", "aria-label": "Süre" },
      existing ? h("option", { value: "keep", selected: true }, `Mevcut süreyi koru · ${expiry(existing)}`) : null,
      ...durations.map(([value, label]) =>
        h("option", { value, selected: !existing && value === "7" }, label)));
    const error = h("p", { class: "err-s", role: "alert", hidden: true });
    const save = h("button", { type: "submit", class: "btn btn-primary" }, svg("share"), existing ? "Güncelle" : "Paylaşımı oluştur");
    const frm = h("form", { class: "dav-form" },
      h("label", { for: "dav-path" }, `Klasör · ${root()}/`, target),
      h("label", { for: "dav-user" }, "Kullanıcı adı", username),
      h("label", { for: "dav-password" }, existing ? "Yeni parola (isteğe bağlı)" : "Parola", password),
      h("div", { class: "dav-actions" }, button("Parola üret", "key", () => {
        const values = new Uint8Array(20); crypto.getRandomValues(values);
        password.value = Array.from(values, (v) => v.toString(16).padStart(2, "0")).join("");
        password.type = "text";
      }), button("Göster / gizle", "eye", () => { password.type = password.type === "password" ? "text" : "password"; })),
      h("small", { class: "hint-s" }, "Parolayı kaydetmeden önce not edin; daha sonra gösterilmez. Tarayıcı deposuna kaydedilmez."),
      h("fieldset", { class: "dav-networks" }, h("legend", null, "Erişim ağı"),
        h("div", { class: "dav-network-choices" }, h("label", { class: "dav-check" }, tailscale, "Tailscale"),
          h("label", { class: "dav-check" }, wan, "WAN (internet)")),
        h("small", { class: "hint-s" }, "En az bir ağ seçin; ikisini birlikte kullanabilirsiniz."),
        !wanAvailable ? h("p", { class: "hint-s", id: "dav-wan-status" }, `WAN kullanılamıyor: ${getShares()?.wan?.reason || "Sunucuda WAN adresi hazır değil."}`) : null),
      wanAcknowledgement,
      h("small", { class: "hint-s" }, "WAN sınırları: 60 saniyede 5 hatalı giriş → 5 dakika engel; IP başına 4, toplam 8 eşzamanlı istek. Güvenlik duvarındaki engeller ve sağlayıcı kuralları ayrıca geçerlidir."),
      !existing ? h("label", { for: "dav-permission" }, "Erişim izni", permission) : null,
      !existing ? acknowledgement : null,
      !existing ? h("label", { for: "dav-days" }, "Süre", days) : null,
      h("p", { class: "hint-s" }, "Kaydetme WebDAV servisini yeniler ve devam eden aktarımları keser. Duraklatılmış paylaşım kendiliğinden açılmaz."),
      error, h("div", { class: "dav-actions" }, save, button("Vazgeç", "close", onDone)));
    frm.addEventListener("submit", (event) => {
      event.preventDefault();
      validateNetworks();
      if (!frm.reportValidity()) return;
      const data = { id: existing ? existing.id : "", path: target.value.trim(), username: username.value.trim(), password: password.value,
        networks: [tailscale.checked ? "tailscale" : null, wan.checked ? "wan" : null].filter(Boolean) };
      if (wan.checked && !hadWan) data.ack_wan_http = ackWan.checked;
      if (!existing) Object.assign(data, { permission: permission.value, ack_write: ack.checked, days: Number(days.value) });
      save.disabled = true; error.hidden = true;
      update("kaydet", data).then(() => { password.value = ""; onDone(); toast(existing ? "Paylaşım güncellendi." : "Klasör paylaşımı hazır."); })
        .catch((err) => { error.textContent = err.message; error.hidden = false; save.disabled = false; })
        .finally(() => { data.password = ""; });
    });
    return frm;
  }
  function openForm(title, path, existing) {
    const content = form(path, existing, closeDialog);
    showDialog(title, content);
    const subtitle = content.closest("dialog")?.querySelector(".dlg-head p");
    if (subtitle) subtitle.textContent = "Klasör başına ayrı hesap · seçili ağlar üzerinden HTTP";
  }
  function edit(s) { openForm(`${s.name} · paylaşımı düzenle`, s.path, s); }
  function create(item, path) {
    if (item.type !== "dir") { toast("WebDAV için bir klasör seçin."); return; }
    const found = (getShares()?.items || []).find((s) => s.path === path);
    if (found) { edit(found); return; }
    openForm(`${item.name} · WebDAV ile paylaş`, path, null);
  }
  function list(body) {
    const data = getShares();
    body.append(warning());
    if (!data) { body.append(h("p", { class: "hint-s" }, "Paylaşımlar okunuyor…")); return; }
    if (!data.running) body.append(h("p", { class: "dav-warning" }, "WebDAV hizmeti çalışmıyor. Hesaplar korunuyor; sunucuda master-paylasim hizmetini kontrol edin."));
    body.append(h("div", { class: "dav-list-head" }, h("div", null, h("h2", null, "WebDAV paylaşımları"),
      h("p", { class: "hint-s" }, `${data.items.length}/${data.max} klasör · seçimler anında kaydedilir; süre bugünden başlar. Değişiklikler WebDAV aktarımlarını kesebilir.`))));
    if (!data.items.length) {
      body.append(h("div", { class: "dav-empty" }, svg("share"), h("h3", null, "Henüz paylaşım yok"),
        h("p", null, "Klasörler sekmesinde bir klasörün Ayrıntılar düğmesini seçin, ardından WebDAV ile paylaşın.")));
    }
    if (!data.items.length) return;
    body.append(h("div", { class: "dav-shares", "aria-busy": busy },
      h("div", { class: "dav-share-head", "aria-hidden": true }, ...["Klasör ve adres", "Kullanıcı", "Ağ", "Erişim", "Süre", "Durum", "İşlemler"].map(label => h("span", null, label))),
      ...data.items.map((s) => h("article", { class: "dav-share-row", "data-share-id": s.id },
      h("div", { class: "dav-share-name" }, h("strong", null, s.name), h("small", null, `${root()}/${s.path}`), addresses(s)),
      h("div", { class: "dav-cell dav-user" }, h("span", { class: "dav-label" }, "Kullanıcı"), h("span", null, s.username)),
      h("div", { class: "dav-cell dav-network" }, h("span", { class: "dav-label" }, "Ağ"), networkBadges(s)),
      ...options(s),
      h("div", { class: "dav-cell dav-state" }, h("span", { class: "dav-label" }, "Durum"),
        h("span", { class: "shchip" }, stateText(s)),
        h("button", { type: "button", class: "sw", role: "switch", "aria-checked": !s.paused, disabled: busy,
          "aria-label": `${s.name} paylaşımı duraklatılmamış`, title: s.paused ? "Devam ettir" : "Duraklat", onclick: () => pause(s) })),
      h("div", { class: "dav-actions" }, ...[button("Yönet", "pencil", () => edit(s)), button("Kaldır", "trash", () => remove(s))]
        .map(b => { b.disabled = busy; return b; }))))));
  }
  return { list, create, edit, info, warning, stateText,
    interacting: () => busy || !!document.activeElement?.closest(".dav-shares select") };
};
