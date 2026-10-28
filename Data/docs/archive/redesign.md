# Konsol redesign

> **Archived (rebuild phase 6):** the plan of the 1.x Konsol redesign (DD-258), finished in v2-252. The rebuild (DD-271, [`rebuild.md`](../rebuild.md)) replaced its App Store, packages, Yayınla and container definitions; current behaviour is in [`contract.md`](../contract.md) and [`architecture.md`](../architecture.md).

Status: direction accepted on 2026-10-13 (**DD-258**). Phase 0 is done: the clickable prototype (a
private design canvas with the overview, the application list and an application page, Erişim with
its WireGuard tab, the Yayınla flow, Dosyalar, Sistem, Gelişmiş, the command palette and two phone
screens) was approved the same day. Phase 1 is in v2-243 (**DD-259**): the route table, `/erisim`,
`/olaylar` and the shell at `/yeni/`. Phase 2 is in v2-245 (**DD-261**, **DD-262**): Genel Bakış,
Uygulamalar and the application page with their read model and action route, and the Gezgin package.
Phase 3 is in v2-248 (**DD-265**): Erişim, the Yayınla flow and the settings plan. Phase 4 is done, in
two parts: 4a in v2-249 (**DD-266**: Sistem, Gelişmiş, adding applications and their settings) and 4b in
v2-250 (**DD-267**: Dosyalar with Paylaşımlar, the interface at `/` with `/yeni` redirected, the old
interface, Konsol's archive jobs and favourites removed). Phase 5 is in v2-252 (**DD-268**): Konsol as an
installable app and the `obhut` recovery tool. Sharing stays in Konsol; Gezgin shares its own content
(DD-268). The redesign is complete.

This document is the plan. Each phase lands with its own `DD-*` entry, tests and a live check on the
test host, and `main` stays installable at every step.

## Why

A review of the Konsol of 2026-10-13 (code, documents and the live panel; the interface it describes
was removed in v2-250) found:

- **Navigation follows technologies, not tasks.** Settings has tabs named after daemons
  (Güvenlik Duvarı, Caddy, Dnsmasq).
- **"Who can reach what, from where" is split across five places:** the Caddy publication table,
  container port scopes on the Podman page, folder-share policies, firewall tabs and the WireGuard
  page. Publishing a container's web interface on the internet took about 11 clicks, 8 fields and
  2 unlinked pages, with the port typed twice.
- **Applications live in three homes:** App Store packages appear as home tiles; a hand-made container
  (Gezgin) appears only on the Podman page; built-ins sit in the sidebar. One package's settings can be
  edited in up to five places.
- **Problems are buried:** the health card lives under Settings → Sistem; the home page shows nothing
  when a service fails.
- **Seven save models:** draft + review + timed confirmation, draft + immediate, per-row save,
  per-control save, a three-step sheet, direct save, per-action save.
- **Parallel components:** 3 switch styles, 4 tab implementations, 4 table kinds, 5 field wrappers,
  5 folder pickers and 4 dialog systems with 34 variants, in about 5,000 lines of hand-built JS
  (`konsol.js` alone 2,773) and a 2,641-line backend file.
- **Two file managers:** Konsol's Files and Gezgin do the same jobs (trash, favourites, shares,
  archives).

What works and must stay: the root backend listens only on a Unix socket behind Caddy's
`forward_auth`; the CSP allows no inline code, no `eval` and nothing from elsewhere; the tailnet comes
first; irreversible actions need a typed word; settings changes are transactional with a guard timer
and automatic rollback; repair covers 21 checks; packages are declared, not coded into the shell.

## Goals

Each goal is checked by a test or a measured flow when its phase lands.

1. Every service's reachability is visible in one view (Erişim), with warnings such as plaintext HTTP
   shown there and on the overview.
2. Publishing an application takes one flow with four decisions (what, who, which name, plan).
3. One page per application; no setting is editable in more than one place.
4. Two save models only: instant with undo for safe toggles; plan → apply (→ timed confirmation when
   the change can cut the operator off) for anything that changes reachability.
5. One implementation per component: switch, tabs, table (cards on narrow screens), field,
   dialog/sheet, folder picker, status pill, typed confirmation, plan review.
6. Health problems are visible from every page (top bar) and first on the overview.
7. Every view state is in the URL (tabs, filters, the selected network, open details).
8. The security floor above is unchanged.

## Information architecture

| Section | Contents |
|---|---|
| **Genel Bakış** | Health first ("everything is fine" or what needs attention, each with its fix), then applications, resources, network and the server |
| **Uygulamalar** | Every application in one list: App Store packages, Konsol containers, built-ins. Each has the same page: Özet · Erişim · Depolama · Ayarlar · Günlük. "+ Uygulama ekle": from the catalogue, from an image, adopt an existing container |
| **Erişim** | The reachability matrix (this server · Tailscale · WireGuard · internet) with the technical details on demand, and the "Yayınla" flow. Under it: Adresler (names and certificates), Tailscale, WireGuard, Güvenlik duvarı |
| **Dosyalar** | Gezgin as the file application; Depolama (storage and folders with the applications that use them); Sunucu klasörleri (a lean rescue view of `/srv`), Çöp kutusu, Paylaşımlar; the root "Sistem dosyaları" view (tailnet only) |
| **Sistem** | Sağlık ve onarım, Güncellemeler, Hesap ve oturum, Sunucu, Görünüm (light/dark/system), Günlük |
| **Gelişmiş** | The effective Caddy configuration, DNS records, technical firewall rules (a link to Erişim), Podman images/volumes/networks. Logs are each application's Günlük and Sistem → Günlük, not a raw-log view |

Shared behaviour:

- **Command palette** (⌘K / Ctrl+K and the search field): pages, applications, settings and actions,
  with Turkish-aware matching (İ/ı).
- **Top bar:** health dot and problem count, an activity drawer for running jobs (App Store
  operations, image pulls, updates, repair), the pending-change banner with its countdown.
- **Progressive disclosure:** plain words by default ("İnternete açık", "Yalnız Tailscale'den");
  addresses, ports and rules behind "Teknik ayrıntı".
- **Mobile:** a bottom bar (Genel · Uygulamalar · Erişim · Dosyalar · Daha fazla), actions in bottom
  sheets, tables become cards.
- **Visual language:** calm opaque surfaces for work; the wallpaper only on the overview; design
  tokens in one file; one icon set; the Ôbhut wordmark in the sidebar.

## Technology

- **Backend: Python, standard library only**, still a root process on a Unix socket.
  - `master-panel` is split by domain behind one route table that declares each request's and
    reply's shape; a test generates the OpenAPI description from it, and the frontend's TypeScript
    types are generated from that.
  - New endpoints:
    - `GET /api/konsol/erisim`: one read model joining the publication rows, container port scopes
      (including the container nft guard), share policies, WireGuard networks, firewall rules and
      listeners, DNS names and certificates.
    - `GET /api/konsol/olaylar`: Server-Sent Events for resources, health, jobs and the pending
      change, with a heartbeat well inside the 180 s socket timeout; it replaces the 5 s/10 s polling
      and the per-feature fast loops.
    - `POST /api/konsol/ayarlar/plan`: a dry run of the settings transaction that returns what would
      change.
- **Frontend: Vue 3 + TypeScript + Vite** in `Data/tools/konsol-ui`, the same stack as Gezgin.
  - The build output is committed under `Data/console/` (precedent: the editor bundle, DD-249), and a
    test fails when it does not match the sources. Node is needed only on the build machine.
  - Templates are precompiled (no runtime compiler, no `eval`); styles live in files; style bindings
    go through the CSSOM. The CSP stays as it is, plus `font-src 'self'` for a local Outfit.
  - Design tokens and base components were to be shared with Gezgin at build time; Konsol keeps its
    own (`src/styles/tokens.css`), Gezgin being a separate project.
- **Phase 5 (DD-268):** a PWA manifest with the Ô icons; the `obhut` command-line tool over the same
  socket API for recovery over SSH.
- **Not used:** Java (JVM memory and start-up cost, a large dependency surface in a root process, no
  gain for a single-operator panel); a runtime template compiler; CDN assets; framing Gezgin inside
  Konsol.

## Gezgin

- Gezgin becomes an App Store container package, `Data/magaza/gezgin`, like qBittorrent (done in
  v2-245, **DD-262**; its data is a folder, `/var/lib/gezgin`, rather than a `gezgin-db` volume):
  digest-pinned image, its own bridge (DD-217), the Files account (DD-227), declared folders, a declared
  publication (one loopback port, a tailnet name, an optional public name) in place of today's manual
  address and direct tailnet ports, update checks applied only on the operator's confirmation
  (DD-214), an install form for the first administrator, and removal that asks whether to keep its
  data.
- Sharing does not move (DD-268): Konsol's folder shares stay, with their separate tailnet and internet
  policies; Gezgin, as a container, shares its own content with its own links and tailnet WebDAV
  (DD-264). Konsol decides whether Gezgin is reachable at all (Erişim).
- Konsol keeps a lean file tool: the root "Sistem dosyaları" view (tailnet only) and a rescue view of
  `/srv` for when Podman or Gezgin is down (done in v2-250, **DD-267**: Dosyalar with Depolama, Sunucu
  klasörleri, Çöp kutusu, Paylaşımlar and Sistem dosyaları; DD-159 amended). Konsol's archive jobs and
  favourites left with the old interface; Gezgin has them.
- Gezgin keeps its own sign-in (it has no proxy authentication, by design); Konsol opens it in a new
  tab.
- Gezgin should publish tagged releases so the package pins a meaningful version.

## Migration

The new interface was built beside the old one at `/yeni/` on the same origin, behind the same
`forward_auth` and CSP, and replaced `/` in v2-250, once it covered every view (**DD-267**); `/yeni` and
`/yeni/*` now redirect to `/`, and the old interface's addresses open their new places.

| Phase | Delivers |
|---|---|
| 0 | DD-258, this plan, the clickable prototype and the design tokens |
| 1 | Route table and schemas, `/erisim`, `/olaylar`, the `konsol-ui` toolchain and its freshness test, the new shell at `/yeni/` (navigation, palette, top bar, activity drawer, pending-change banner, theme, mobile bar) |
| 2 | Genel Bakış and Uygulamalar; the Gezgin package (v2-245, DD-261, DD-262) |
| 3 | Erişim, the Yayınla flow and the plan endpoint (v2-248, DD-265) |
| 4a | Sistem, Gelişmiş, Uygulamalar' add flows (catalogue with install forms, an image, adoption) and an application's settings (v2-249, DD-266) |
| 4b | Dosyalar (storage and folders, a lean `/srv` view, the root view) with Paylaşımlar; `/yeni/` becomes `/`; the old shell and its scripts are removed (v2-250, DD-267) |
| 5 | PWA (manifest and icons, no service worker) and the `obhut` tool (v2-252, DD-268); sharing stays in Konsol, Gezgin shares its own content |

## Decisions revisited

These rules change when their phase lands, each with its own DD entry:

- DD-159: Files and WebDAV as permanent built-ins (phases 4 and 5). Amended in phase 4b (DD-267):
  Files keeps the server folders, the trash and Sistem dosyaları, archives are Gezgin's; WebDAV stays
  for good: phase 5 kept sharing in Konsol (DD-268).
- DD-204: the glass skin on every page (wallpaper only on the overview). Retired in phase 4b (DD-267).
- DD-212 and DD-216: home cards and sidebar entries (one Uygulamalar section replaces both). DD-216
  retired and DD-212 amended in phase 4b (DD-267; its cumulative-totals rule holds for Genel Bakış).
- The "no frontend build step" rule (`architecture.md`, `contract.md`): the Konsol UI is built from
  `Data/tools/konsol-ui` into committed static files (since phase 1, DD-259).
- `contract.md`: the page set and sidebar, the five Settings tabs and the per-row publication save.
  Rewritten in phases 3 and 4 (DD-265, DD-266, DD-267): the sections, the plan before every
  reachability write and Dosyalar.
