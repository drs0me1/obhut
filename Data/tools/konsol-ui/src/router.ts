// Hash routes (#/genel …), so Caddy needs no rewrite. The eight sections with their tabs in the query
// (#/erisim?sekme=adresler, #/dosyalar?sekme=paylasimlar), an application's page by its name
// (#/uygulamalar/notlar), Uyarılar (#/uyarilar, the page the top bar's count opens, under Genel Bakış) and
// Uygulama ekle, a full-window page of its own (#/uygulama-ekle: under #/uygulamalar/ it would be an application
// named "ekle"). Any other address opens Genel Bakış.
import type { Component } from "vue";
import { createRouter, createWebHashHistory } from "vue-router";
import OverviewPage from "./pages/OverviewPage.vue";
import ProblemsPage from "./pages/ProblemsPage.vue";
import AppsPage from "./pages/AppsPage.vue";
import PodmanPage from "./pages/PodmanPage.vue";
import AppPage from "./pages/AppPage.vue";
import AddAppPage from "./pages/AddAppPage.vue";
import AccessPage from "./pages/AccessPage.vue";
import WireGuardPage from "./pages/WireGuardPage.vue";
import SystemPage from "./pages/SystemPage.vue";
import AdvancedPage from "./pages/AdvancedPage.vue";
import FilesPage from "./pages/FilesPage.vue";
import { SECTIONS, type SectionId } from "./sections";

declare module "vue-router" {
  interface RouteMeta {
    /** The section a page belongs to (the sidebar's current entry). */
    section?: SectionId;
    /** A full-window page: the shell shows no sidebar, page head or bottom bar; the page has its own. */
    full?: boolean;
  }
}

const PAGES: Record<SectionId, Component> = {
  genel: OverviewPage,
  uygulamalar: AppsPage,
  podman: PodmanPage,
  erisim: AccessPage,
  wireguard: WireGuardPage,
  sistem: SystemPage,
  gelismis: AdvancedPage,
  dosyalar: FilesPage,
};

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/genel" },
    ...SECTIONS.map((s) => ({ path: "/" + s.id, name: s.id, component: PAGES[s.id], meta: { section: s.id } })),
    { path: "/uygulamalar/:ad", name: "uygulama", component: AppPage, meta: { section: "uygulamalar" } },
    { path: "/uyarilar", name: "uyarilar", component: ProblemsPage, meta: { section: "genel" } },
    { path: "/uygulama-ekle", name: "uygulama-ekle", component: AddAppPage, meta: { section: "uygulamalar", full: true } },
    { path: "/:rest(.*)*", redirect: "/genel" },
  ],
  // A new page starts at the top; a changed view of the same page (a tab, a filter) keeps the scroll.
  scrollBehavior: (to, from, saved) => saved ?? (to.path === from.path ? false : { top: 0 }),
});

/** The address of an application's page. */
export const appRoute = (ad: string) => ({ name: "uygulama", params: { ad } }) as const;
export const ADD_APP = "/uygulama-ekle";
export const PROBLEMS = "/uyarilar";
