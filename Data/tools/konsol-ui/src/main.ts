// Konsol (DD-258), served at / since phase 4b (DD-267).
import { createApp } from "vue";
import App from "./App.vue";
import { router } from "./router";
import { initTheme } from "./theme";
import { startLive } from "./live";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/shell.css";
import "./styles/ui.css";
import "./styles/pages.css";
import "./styles/erisim.css";
import "./styles/sistem.css";
import "./styles/podman.css";
import "./styles/uygulama.css";
import "./styles/paylasim.css";
import "./styles/dosyalar.css";

initTheme();
createApp(App).use(router).mount("#app");
startLive();
