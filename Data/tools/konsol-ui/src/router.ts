// Hash routes (#/genel …), so Caddy needs no rewrite for /yeni/. Unknown addresses open Genel Bakış.
import { createRouter, createWebHashHistory } from "vue-router";
import SectionPage from "./pages/SectionPage.vue";
import { SECTIONS } from "./sections";

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/genel" },
    ...SECTIONS.map((s) => ({ path: "/" + s.id, name: s.id, component: SectionPage })),
    { path: "/:rest(.*)*", redirect: "/genel" },
  ],
  scrollBehavior: () => ({ top: 0 }),
});
