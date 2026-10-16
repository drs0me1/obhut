// Hash routes (#/genel …), so Caddy needs no rewrite. The six sections with their tabs in the query
// (#/erisim?sekme=adresler, #/dosyalar?sekme=paylasimlar) and an application's page
// (#/uygulamalar/konteyner:notlar). Any other address opens Genel Bakış.
import type { Component } from "vue";
import { createRouter, createWebHashHistory } from "vue-router";
import OverviewPage from "./pages/OverviewPage.vue";
import AppsPage from "./pages/AppsPage.vue";
import AppPage from "./pages/AppPage.vue";
import AccessPage from "./pages/AccessPage.vue";
import SystemPage from "./pages/SystemPage.vue";
import AdvancedPage from "./pages/AdvancedPage.vue";
import FilesPage from "./pages/FilesPage.vue";
import { SECTIONS, type SectionId } from "./sections";

declare module "vue-router" {
  interface RouteMeta {
    /** The section a page belongs to (the sidebar's current entry). */
    section?: SectionId;
  }
}

const PAGES: Record<SectionId, Component> = {
  genel: OverviewPage,
  uygulamalar: AppsPage,
  erisim: AccessPage,
  sistem: SystemPage,
  gelismis: AdvancedPage,
  dosyalar: FilesPage,
};

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/genel" },
    ...SECTIONS.map((s) => ({ path: "/" + s.id, name: s.id, component: PAGES[s.id], meta: { section: s.id } })),
    { path: "/uygulamalar/:id", name: "uygulama", component: AppPage, meta: { section: "uygulamalar" } },
    { path: "/:rest(.*)*", redirect: "/genel" },
  ],
  // A new page starts at the top; a changed view of the same page (a tab, a filter) keeps the scroll.
  scrollBehavior: (to, from, saved) => saved ?? (to.path === from.path ? false : { top: 0 }),
});

/** The address of an application's page. */
export const appRoute = (id: string) => ({ name: "uygulama", params: { id } }) as const;
