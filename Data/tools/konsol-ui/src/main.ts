// Konsol's new shell (DD-258), served at /yeni/ beside the current interface.
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

initTheme();
createApp(App).use(router).mount("#app");
startLive();
