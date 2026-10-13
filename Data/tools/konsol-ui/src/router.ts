// Hash routes (#/genel …), so Caddy needs no rewrite for /yeni/. Unknown addresses open Genel Bakış.
// Genel Bakış, Uygulamalar and an application's page (#/uygulamalar/paket:torrent) are built (phase 2);
// the other sections are still placeholders that lead to the current interface.
import { createRouter, createWebHashHistory, type RouteRecordRaw } from "vue-router";
import SectionPage from "./pages/SectionPage.vue";
import OverviewPage from "./pages/OverviewPage.vue";
import AppsPage from "./pages/AppsPage.vue";
import AppPage from "./pages/AppPage.vue";
import { SECTIONS, type SectionId } from "./sections";

declare module "vue-router" {
  interface RouteMeta {
    /** The section a page belongs to (the sidebar's current entry). */
    section?: SectionId;
  }
}

const PAGES: Partial<Record<SectionId, RouteRecordRaw["component"]>> = { genel: OverviewPage, uygulamalar: AppsPage };

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/genel" },
    ...SECTIONS.map((s) => ({ path: "/" + s.id, name: s.id, component: PAGES[s.id] ?? SectionPage, meta: { section: s.id } })),
    { path: "/uygulamalar/:id", name: "uygulama", component: AppPage, meta: { section: "uygulamalar" } },
    { path: "/:rest(.*)*", redirect: "/genel" },
  ],
  // A new page starts at the top; a changed view of the same page (a tab, a filter) keeps the scroll.
  scrollBehavior: (to, from, saved) => saved ?? (to.path === from.path ? false : { top: 0 }),
});

/** The address of an application's page. */
export const appRoute = (id: string) => ({ name: "uygulama", params: { id } }) as const;
