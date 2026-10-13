/* Konsol'un tema seçimi (DD-258): sayfa çizilmeden önce uygulanır ki koyu tema açık zeminle başlamasın.
   Seçim yoksa ya da depolama kapalıysa sistemin teması geçerlidir. Asıl yönetim src/theme.ts'tedir. */
(function () {
  try {
    var choice = localStorage.getItem("konsol.tema");
    if (choice === "acik") document.documentElement.setAttribute("data-theme", "light");
    else if (choice === "koyu") document.documentElement.setAttribute("data-theme", "dark");
  } catch (e) { /* özel pencere ya da kapalı depolama: sistem teması */ }
})();
