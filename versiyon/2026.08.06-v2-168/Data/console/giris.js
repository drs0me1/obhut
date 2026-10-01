/* Konsol girişi ve ilk hesap kurulumu (DD-194). Parola yalnız istek gövdesinde gider;
   tarayıcı deposuna yazılmaz. Başarılı girişten sonra gelinen Konsol sayfasına dönülür. */
"use strict";
(() => {
  const $ = (id) => document.getElementById(id);
  const back = () => location.replace("/" + (location.hash.startsWith("#/") ? location.hash : ""));
  async function call(path, body) {
    const init = { method: body ? "POST" : "GET", headers: { "X-Konsol": "1" }, credentials: "same-origin", cache: "no-store" };
    if (body) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(body); }
    const res = await fetch(path, init);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `Sunucu yanıtı: HTTP ${res.status}`);
    return data;
  }
  function show(state, note) {
    $("form-login").hidden = state !== "giris";
    $("form-setup").hidden = state !== "kurulum";
    $("login-title").textContent = state === "kurulum" ? "İlk hesap" : "Giriş";
    $("login-note").textContent = note;
    const first = state === "kurulum" ? $("setup-code") : state === "giris" ? $("login-user") : null;
    first?.focus();
  }
  function bind(form, button, error, path, payload) {
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (button.disabled || !form.reportValidity()) return;
      const body = payload();
      if (!body) return;
      button.disabled = true; error.hidden = true;
      try {
        await call(path, body);
        back();
      } catch (err) {
        error.textContent = err.message; error.hidden = false;
        button.disabled = false;
        // A failed sign-in clears the password; a failed setup keeps it (often only the code was wrong).
        if (form.id === "form-login") $("login-pass").value = "";
      }
    });
  }
  bind($("form-login"), $("login-submit"), $("login-error"), "/api/konsol/oturum/giris",
    () => ({ kullanici: $("login-user").value.trim(), parola: $("login-pass").value }));
  bind($("form-setup"), $("setup-submit"), $("setup-error"), "/api/konsol/oturum/kur", () => {
    const again = $("setup-pass2");
    again.setCustomValidity($("setup-pass").value === again.value ? "" : "Parolalar aynı değil.");
    if (!again.reportValidity()) return null;
    return { kod: $("setup-code").value, kullanici: $("setup-user").value.trim(), parola: $("setup-pass").value };
  });
  $("setup-pass2").addEventListener("input", (e) => e.target.setCustomValidity(""));
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) document.querySelectorAll('input[type="password"]').forEach((input) => { input.value = ""; });
  });
  call("/api/konsol/oturum").then((state) => {
    // DD-195: the backend names the Caddy site that carried the request.
    $("login-access").textContent = "Sunucu yönetimi · " + (state.kanal === "internet" ? "internet (HTTPS)" : "Tailscale");
    if (state.durum === "acik") { back(); return; }
    if (state.durum === "kurulum") {
      show("kurulum", state.kod
        ? "Kurulumun sonunda Mac terminalinde gösterilen tek kullanımlık kodu girin; kullanıcı adınızı ve parolanızı siz belirleyin."
        : "Geçerli kurulum kodu yok. Sunucuda sudo master-konsol sifirla komutuyla yeni kod alın veya kurulumu yeniden çalıştırın.");
      return;
    }
    show("giris", "Kullanıcı adınız ve parolanızla giriş yapın.");
  }).catch((err) => show("", "Oturum durumu okunamadı: " + err.message + " Sayfayı yenileyin."));
})();
