// Hash routes (#/genel …), so Caddy needs no rewrite. Unknown addresses open Genel Bakış.
// The six sections with their tabs in the query (#/erisim?sekme=adresler, #/dosyalar?sekme=paylasimlar) and an
// application's page (#/uygulamalar/paket:torrent). The addresses of the Konsol before phase 4b (DD-267)
// land on their new homes, since old bookmarks arrive here: the fixed ones through sections.ts (oldHome),
// the ones that depend on what is installed once the application list is known (a package's own page
// "#/torrent", "#/moduller/<id>", a container "#/konteynerler/<ad>").
import { watch, type Component } from "vue";
import { createRouter, createWebHashHistory, type RouteLocationNormalized, type RouteLocationRaw, type RouteRecordRaw } from "vue-router";
import OverviewPage from "./pages/OverviewPage.vue";
import AppsPage from "./pages/AppsPage.vue";
import AppPage from "./pages/AppPage.vue";
import AccessPage from "./pages/AccessPage.vue";
import SystemPage from "./pages/SystemPage.vue";
import AdvancedPage from "./pages/AdvancedPage.vue";
import FilesPage from "./pages/FilesPage.vue";
import { SECTIONS, addRoute, oldHome, type SectionId } from "./sections";
import { live } from "./live";
import type { Uygulamalar } from "./api/sema";

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

// ---- the old addresses

/** How long an old application address waits for the application list before it gives up. */
const APPS_WAIT_MS = 6000;

/** The application list once it is known (at once when it is); null when it did not arrive in time. */
function knownApps(): Promise<Uygulamalar | null> {
  if (live.uygulamalar) return Promise.resolve(live.uygulamalar);
  return new Promise((resolve) => {
    const timer = window.setTimeout(() => {
      stop();
      resolve(live.uygulamalar);
    }, APPS_WAIT_MS);
    const stop = watch(
      () => live.uygulamalar,
      (value) => {
        if (!value) return;
        clearTimeout(timer);
        stop();
        resolve(value);
      },
    );
  });
}

const appPage = (id: string): RouteLocationRaw => ({ name: "uygulama", params: { id } });

function decoded(part: string): string {
  try {
    return decodeURIComponent(part);
  } catch {
    return part;
  }
}

/** The new home of an old address that depends on what is installed (null: Genel Bakış). */
function oldAppHome(path: string, list: Uygulamalar | null): RouteLocationRaw | null {
  const parts = path.split("/").filter(Boolean).map(decoded);
  const items = list?.items ?? [];
  const [head, sub, third] = parts;
  // App Store's package: its page when installed, else its install in the catalogue.
  if (head === "moduller" && sub) {
    const app = items.find((a) => a.tur === "paket" && a.modul === sub);
    return app ? appPage(app.id) : addRoute("katalog", { paket: sub });
  }
  // The Podman page's container: the application it belongs to (a package's container is the package).
  const box = head === "konteynerler" ? sub : head === "ayarlar" && sub === "konteynerler" ? third : undefined;
  if (box) {
    const app = items.find((a) => a.konteyner === box);
    return appPage(app ? app.id : "konteyner:" + box);
  }
  // A package's own page (#/torrent): the application's page; one that is not installed any more opens its
  // install in the catalogue, as the old Konsol sent such a bookmark to App Store.
  if (head && !sub) {
    const app = items.find((a) => a.tur === "paket" && (a.sayfa === "#/" + head || a.modul === head));
    if (app) return appPage(app.id);
    if (list?.katalog.some((k) => k.id === head)) return addRoute("katalog", { paket: head });
  }
  return null;
}

async function toNewHome(to: RouteLocationNormalized): Promise<RouteLocationRaw> {
  const fixed = oldHome(to.path);
  if (fixed) return fixed;
  return oldAppHome(to.path, await knownApps()) ?? "/genel";
}

// Never shown: every old address redirects before its page would render.
const Moving = { name: "EskiAdres", render: () => null };
const OLD: RouteRecordRaw[] = [
  "/moduller/:eski(.*)*",
  "/konteynerler/:eski(.*)*",
  "/ayarlar/:eski(.*)*",
  "/dosyalar/:eski(.*)+",
  "/wireguard",
  "/:eski([a-z][a-z0-9_-]*)",
].map((path) => ({ path, component: Moving, beforeEnter: toNewHome }));

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/genel" },
    ...SECTIONS.map((s) => ({ path: "/" + s.id, name: s.id, component: PAGES[s.id], meta: { section: s.id } })),
    { path: "/uygulamalar/:id", name: "uygulama", component: AppPage, meta: { section: "uygulamalar" } },
    ...OLD,
    { path: "/:rest(.*)*", redirect: "/genel" },
  ],
  // A new page starts at the top; a changed view of the same page (a tab, a filter) keeps the scroll.
  scrollBehavior: (to, from, saved) => saved ?? (to.path === from.path ? false : { top: 0 }),
});

/** The address of an application's page. */
export const appRoute = (id: string) => ({ name: "uygulama", params: { id } }) as const;
