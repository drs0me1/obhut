/* Klasör başına WebDAV yönetimi (DD-158). Parola tarayıcı deposuna yazılmaz. */
window.createSharesPage = function ({ h, svg, post, toast, fail, copyButton, getShares, setShares, root, showDialog, closeDialog, ask }) {
  const stateText = (s) => !s.available ? "Klasör bulunamadı" : s.expired ? "Süresi doldu" : s.paused ? "Duraklatıldı" : "Açık";
  const access = (s) => s.permission === "rw" ? "Okuma ve yazma" : "Salt okunur";
  const expiry = (s) => s.expires ? new Date(s.expires * 1000).toLocaleDateString("tr-TR") : "Süresiz";
  const button = (text, icon, fn, primary = false) => h("button", { type: "button", class: "btn btn-sm " + (primary ? "btn-primary" : "btn-quiet"), onclick: fn }, svg(icon), text);
  function warning() {
    return h("details", { class: "dav-boundary" }, h("summary", null, svg("shield"), "Paylaşmadan önce erişim sınırını kontrol edin"),
      h("p", null, "Alıcıya yalnız WebDAV portunu açın; Konsol ve SSH yalnız yöneticide kalmalı. Konsol parolasızdır: panele ulaşan kişi tüm dosyaları yönetebilir. Tailscale ACL/grants kuralları burada değiştirilmez."),
      h("p", null, "HTTP adresi Tailscale tünelinde taşınır. HTTPS veya dosya kilidi isteyen istemciler bu adresle uyumlu olmayabilir; Infuse/Finder uyumu istemcide ayrıca sınanmalıdır."));
  }
  function update(action, body) {
    return post("/api/konsol/paylasim/" + action, body).then((data) => { setShares(data); return data; });
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
      h("div", { class: "dav-pair" }, h("small", null, "Tailscale üzerinden WebDAV"), h("code", { class: "dav-url" }, s.url), copyButton(s.url, "WebDAV adresi")),
      h("div", { class: "dav-actions" }, button("Düzenle", "pencil", () => edit(s)),
        button(s.paused ? "Devam ettir" : "Duraklat", s.paused ? "play" : "pause", () => pause(s)),
        button("Kaldır", "trash", () => remove(s))),
      h("p", { class: "hint-s" }, "Mevcut parola geri okunamaz. Gerekirse Düzenle ile yenisini belirleyin."));
  }
  function form(path, existing, onDone) {
    const username = h("input", { id: "dav-user", autocomplete: "off", required: true, minlength: 3, maxlength: 32,
      pattern: "[A-Za-z0-9][A-Za-z0-9._-]{2,31}", value: existing ? existing.username : "", placeholder: "ör. aile-medya" });
    const password = h("input", { type: "password", id: "dav-password", autocomplete: "new-password", required: !existing,
      minlength: 12, maxlength: 256, placeholder: existing ? "Boş bırak: mevcut parola korunsun" : "En az 12 karakter" });
    const target = h("input", { id: "dav-path", required: true, value: path, autocomplete: "off", spellcheck: "false" });
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
      ...[["1", "1 gün"], ["7", "7 gün"], ["30", "30 gün"], ["0", "Süresiz"]].map(([value, label]) =>
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
      h("label", { for: "dav-permission" }, "Erişim izni", permission), acknowledgement,
      h("label", { for: "dav-days" }, "Süre", days),
      h("p", { class: "hint-s" }, "Kaydetme WebDAV servisini yeniler ve devam eden aktarımları keser. Duraklatılmış paylaşım kendiliğinden açılmaz."),
      error, h("div", { class: "dav-actions" }, save, button("Vazgeç", "close", onDone)));
    frm.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!frm.reportValidity()) return;
      const data = { id: existing ? existing.id : "", path: target.value.trim(), username: username.value.trim(),
        password: password.value, permission: permission.value, ack_write: ack.checked,
        days: days.value === "keep" ? null : Number(days.value) };
      save.disabled = true; error.hidden = true;
      update("kaydet", data).then(() => { password.value = ""; onDone(); toast(existing ? "Paylaşım güncellendi." : "Klasör paylaşımı hazır."); })
        .catch((err) => { error.textContent = err.message; error.hidden = false; save.disabled = false; })
        .finally(() => { data.password = ""; });
    });
    return frm;
  }
  function edit(s) { showDialog(`${s.name} · paylaşımı düzenle`, form(s.path, s, closeDialog)); }
  function create(item, path) {
    if (item.type !== "dir") { toast("WebDAV için bir klasör seçin."); return; }
    const found = (getShares()?.items || []).find((s) => s.path === path);
    if (found) { edit(found); return; }
    showDialog(`${item.name} · WebDAV ile paylaş`, form(path, null, closeDialog));
  }
  function list(body) {
    const data = getShares();
    body.append(warning());
    if (!data) { body.append(h("p", { class: "hint-s" }, "Paylaşımlar okunuyor…")); return; }
    if (!data.running) body.append(h("p", { class: "dav-warning" }, "WebDAV hizmeti çalışmıyor. Hesaplar korunuyor; sunucuda master-paylasim hizmetini kontrol edin."));
    body.append(h("div", { class: "dav-list-head" }, h("div", null, h("h2", null, "WebDAV paylaşımları"),
      h("p", { class: "hint-s" }, `${data.items.length}/${data.max} klasör · her klasörün hesabı ve adresi ayrı`))));
    if (!data.items.length) {
      body.append(h("div", { class: "dav-empty" }, svg("share"), h("h3", null, "Henüz paylaşım yok"),
        h("p", null, "Klasörler sekmesinde bir klasörün Ayrıntılar düğmesini seçin, ardından WebDAV ile paylaşın.")));
    }
    body.append(h("div", { class: "dav-shares" }, ...data.items.map((s) => h("article", { class: "dav-share-row" },
      h("div", { class: "dav-share-name" }, h("strong", null, s.name), h("small", null, `${root()}/${s.path}`), h("code", null, s.url)),
      h("div", { class: "dav-share-meta" }, h("span", { class: "shchip" }, stateText(s)), h("span", null, `${s.username} · ${access(s)}`), h("small", null, expiry(s))),
      h("div", { class: "dav-actions" }, copyButton(s.url, `${s.name} adresi`),
        button("Yönet", "pencil", () => edit(s)),
        h("button", { type: "button", class: "sw", role: "switch", "aria-checked": !s.paused,
          "aria-label": `${s.name} paylaşımı duraklatılmamış`, title: s.paused ? "Devam ettir" : "Duraklat", onclick: () => pause(s) }),
        button("Kaldır", "trash", () => remove(s)))))));
  }
  return { list, create, edit, info, warning, stateText };
};
