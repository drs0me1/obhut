# Tests

Narrow critical-behaviour suite for the lean installer tree. Not a framework
coverage suite.

```bash
cd Data   # from the repository root; paths below are relative to Data/
bats tests
bash -n install.sh common.sh scripts/*
shellcheck -x -s bash install.sh common.sh scripts/*
```

`bats tests` runs every Bats file (`common.bats` and `share-networks.bats`);
`bats tests/common.bats`, used in some sections below, runs only the first.

The Bats fixture resolves its temporary directory with `pwd -P`: macOS `/var`
is a symlink and production no-follow readers correctly reject it. No shell
wrapper or relaxed production traversal is needed.
Mode/inode checks capture only successful GNU/BSD stat output; hashes use the
fixture's Python helper. Linux Bats needs the source guards' docs, root
`.gitignore`, `kur.sh` and `wireguard.command` too, not only the runtime tree. Copy only these allowlisted test inputs; never include private
`kurulum/` or WG profiles.
For a root-created test checkout under `mktemp -d`, set that checkout directory
to mode `0755` (`chmod 0755 /absolute/path/to/test-checkout`): non-root fixture
processes must traverse it. Do not relax private input/credential permissions.
Template tests exercise literal ampersands/backslashes and preservation of
Bash 5.2's `patsub_replacement` setting (Bash 3.2 has no such option).

Host acceptance (Debian 13 or supported Ubuntu target, after install) is
separate: DNS loopback vs Tailscale answers, WebDAV PROPFIND/read-only,
firewall `--check`, and the public ports: WAN SSH TCP, Tailscale UDP, each
registered WireGuard UDP port (if installed), plus the mode-selected WAN IPv4
WebDAV port: legacy HTTP `SHARE_PORT` only while a WAN share is active, or
configured HTTPS `SHARE_HTTPS_PORT` retained for renewal with no active folders.
Explicit HTTPS disable closes both WAN ports; Tailscale HTTP is unchanged.
With DD-191, an independently enabled qBittorrent publication keeps the shared
HTTPS port open; disable both rows to close it. A Tailscale row switch gates
that named route, not the shared Caddy listener.

**Browser suites.** Konsol's Playwright suites are the `yeni-*.cjs` files (their shared harness is
`yeni-harness.cjs`) and `giris-ui.cjs`. Since DD-267 the `yeni-*` suites run Konsol at `/`, served as
the installer lays it out: the build's files from `console/yeni/` at the root, the sign-in page, the
editor bundle and the marks from `console/` beside them (Caddy's `/yeni` redirect is checked by Bats, not
served here). Each starts its own static server on its `KONSOL_URL` (defaults from 8768 to 8776). The old interface's suites
were deleted with it (`app-install-ui`, `desktop-live`, `files-nav-ui`, `files-ui`, `konteynerler-ui`,
`panel-ui`, `publications-ui`, `settings-https-ui`, `settings-ui`, `share-connections-browser`,
`torrent-ui`, `update-ui` and `wireguard-ui`), and with the archive jobs and favourites
`archives-live.py`, `test_archives.py`, `test_rar.py` and `test_favorites.py`. Sections below written
for earlier builds name the suite that covers the behaviour now.

**Layout audit (v2-254, DD-270).** `duzen-denetimi.cjs` measures a page state in the browser: a horizontal page
scroll, an element past the window's edge outside a scroll box, content spilling over its box, content cut
off without an ellipsis, an ordinary word (12 characters or fewer) broken across lines because its box is
too narrow, text or controls drawn over each other (text measured where its glyphs are), and an open
dialog that neither fits the window nor scrolls. Every screenshot of the `yeni-*` suites runs it at the
screenshot's own width and a finding fails the suite like a console error; `giris-ui.cjs` runs it at each
of its widths. A sweep also measures every screenshot's state at 320, 360, 390, 768, 1024, 1280 and 1920
px (the viewport is restored; the phone menu, which a wider window closes, is measured at phone widths
only):

```bash
KONSOL_DUZEN=tara KONSOL_DUZEN_ATLA='paket-ayarlar' KONSOL_DUZEN_CIKTI=/tmp/duzen.jsonl \
  PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulama-ekle-ui.cjs
```

Before a screenshot the harness waits for every finite animation, not only Vue's transition classes (a
sheet's own slide outlasts them). `KONSOL_DUZEN_ATLA` leaves a state out of the sweep that a resize changes (the account card hides a revealed
password when the tab hides, which Playwright's resize triggers); `KONSOL_DUZEN=0` turns the audit off.
Ellipses and long tokens wrapping in their box (addresses, digests) are counted, not reported. The first
sweep (2026-10-16, v2-254) measured the suites' 393 states at their own width and again at seven widths
(2,882 measurements), and the live Konsol on the test host: 43 states (every section and tab, the add,
publish, share and new-folder flows, a removal question, the palette) at eleven widths in the light theme
and four in the dark, and the activity drawer at the nine desktop sizes (on a phone it shows only while a
job runs). The only real fault was a card table cell on a phone whose long address ran into the next
column, fixed in v2-254.

## Redesign phase 1: route table, Erişim, live events (v2-243, DD-259)

`test_api.py` checks that every route of `panel/master_api.py` has its `api_<name>` handler method,
that `docs/konsol-api.json` and `tools/konsol-ui/src/api/sema.ts` are exactly what the table generates
(regenerate with `python3 panel/master_api.py openapi > docs/konsol-api.json` and
`python3 panel/master_api.py ts > tools/konsol-ui/src/api/sema.ts`), that the schema check refuses
wrong shapes, and that the table's routes answer through the real handler with their declared shapes.
`test_erisim.py` feeds `master_erisim.build()` the shapes the backend's sources return (documentation
addresses only): the four cells of each service, a package's peer port as a partly open internet cell,
a manual address joining its container, WireGuard closed for every service, warnings (plain HTTP
WebDAV, a container port straight on the WAN, an unknown publication address, a publication that is on
but failing, Tailscale disconnected, certificate expiry), operator rules, unreadable sources as error
lines; then the route on a temporary Unix socket and its gates. `test_container_manager.py` checks
`Inventory.reach()` (one `podman ps`, stopped definitions with their configured ports).
`test_olaylar.py` drives the producer with a fake clock (changed topics only, a failing topic logged
once, a slow topic in its own thread, the per-channel limit, the producer stopping when idle), the
activity drawer's operations (App Store progress through to "bitti"/"hata", container records, the
update and the repair, the 120 s window) and the pending change; then real streams on a temporary Unix
socket: headers without `Content-Length`, `retry:`, frames, heartbeats, a change reaching an open
stream, the end of a stream, 503 at the limit, the `X-Konsol` gate, and an internet session that ends
while its stream is open. `common.bats` checks that every module `master-panel` imports is installed,
the uncompressed stream in the Caddy snippet, the stream limits, the absent gate exception and the
installer's placement of the build at the console's root (DD-267).

## Konsol shell (v2-243, DD-259; at `/` since DD-267)

`yeni-ui.cjs` drives the committed build at `/` under the production CSP read from
`templates/Caddyfile` (with `font-src 'self'` for the local Outfit font). Through `yeni-harness.cjs` it
starts a static server for the installed layout on the address in `KONSOL_URL` (default `http://127.0.0.1:8768`); that server
also holds `/api/konsol/olaylar` open as an event stream so the suite can push events, while the other
`/api/*` reads are fixtures. Any console error, CSP violation or page error fails it. It first checks
that `console/yeni/kaynak.sha256` equals `kaynak-ozeti.sh`'s digest (the build matches its sources) and
that `app.js` opens with the licence banner naming the pinned Vue and vue-router versions. It covers the
sidebar counts (Uygulamalar, Sistem, Erişim), the problem chip, the Tailscale and version card, the
stream (an `X-Konsol` fetch, multi-line data, comments and unknown events, `kapat` with an immediate
reconnect), the activity drawer, the pending-change banner and its local countdown, the command palette
(Ctrl+K and Meta+K, Turkish case rules, arrow keys, Enter to a page, Esc with focus return), the theme
kept across a reload, an old address landing on its new home, the
skip link, the phone's bottom
bar and menu sheet at 390 and 320 px, both themes, polling when the stream answers 404 or 503
(resources 10 s, health 60 s, jobs and the pending change 5 s) and after three
failed attempts (retried after 3 s and 6 s, polling ends once the stream is back), unknown values
shown as "—" and a 401 going to the sign-in page. Screenshots go to a fresh temporary directory, printed
at the end.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-ui.cjs
cd Data/tools/konsol-ui && npx vue-tsc --noEmit
```

To rebuild: `cd Data/tools/konsol-ui && npm ci && npm run derle` (vue-tsc, Vite with `lisanslar.mjs`
writing that banner — a bundled package under another licence than MIT stops the build — then
`console/yeni/kaynak.sha256`: the sha256 of the lines "<sha256>  <path>" for every file under
`tools/konsol-ui` except `node_modules/`, in byte order of the path). `tools/konsol-ui/kaynak-ozeti.sh`
prints the same digest with POSIX tools (`sha256sum`, or `shasum -a 256`), so a test can tell whether the
committed build matches its sources without Node.

## Redesign phase 2: Uygulamalar (v2-245, DD-261)

`test_uygulamalar.py` feeds `master_uygulamalar.build()` the backend's own shapes (the package list, the
container inventory, the Erişim view) and checks each answer against the `Uygulamalar` schema: every
application in one list, a package with its container, access cells and update state, a Konsol
container with its manual address, states and running operations, an image that can move but was not
checked (`bilinmiyor`, not `sabit`), the built-ins and unreadable sources. Then the route on a temporary
Unix socket and its gates, a container application's detail and log, the one action entry (packages to
the engine, containers and image updates to the worker with the revision, built-ins refused), the
repair route, and the background update check (at most once a minute, only for a stale cache, a failure
kept in its thread). `test_api.py` also checks each route's status and request body in the OpenAPI
description.

## New interface phase 2: Genel Bakış, Uygulamalar and the application page (v2-245, DD-261)

`yeni-harness.cjs` is the shared harness of Konsol's suites: the static server for the installed layout
(since DD-267) with
the production CSP, the held-open event stream, fixture replies for `/api/*` (a `handlers` table answers
by method, path and query before the plain fixtures; every request is logged with its parsed POST body),
`newHttpsPage()` for a page whose origin is `https://` (Playwright answers every request, no TLS), the
console/CSP/page-error collector and the build check (digest, licence banner). `yeni-ui.cjs` uses it
unchanged in substance; since phase 2 its fixtures read `/api/konsol/uygulamalar` instead of `moduller`
(the sidebar count and the palette's applications come from there) and it no longer expects placeholders
on Genel Bakış and Uygulamalar.

`yeni-uygulamalar-ui.cjs` drives the phase 2 pages on `KONSOL_URL` (default `http://127.0.0.1:8769`):
Genel Bakış with problems first (each health check with "Denetle ve onar": a confirmation, then
`POST /api/konsol/onarim` with exactly `{"kip":"onar"}`, a refused start shown in the dialog, the running
and ended repair through `islemler`; each Erişim warning with "Düzelt"), the calm state, the locked repair
on the internet channel with its reason, application cards without Files, "Aç" in a new tab (the internet
name on an HTTPS origin), resources, the network card (read every 5 s only while the page is shown and the
tab visible) and the server card; the palette opening an application's page; Uygulamalar with its summary,
filter chips and counts (Dikkat: a failed state, an access warning or a newer image), a Turkish-aware
search, the view in the address across a reload, empty states, the add panel, the infrastructure card and
read errors, keyboard order and a visible focus ring; an application's page with its trail, tabs (arrow
keys, Home/End, `?sekme=`), Erişim with "Teknik ayrıntı" in the address (`teknik=1`), Depolama, Ayarlar,
Günlük with "Yenile" and the "Canlı" switch (`canli=1`, every 5 s while on); the exact
`POST /api/konsol/uygulamalar/islem` bodies of every action (no `revizyon` when it is null, `veri` with
Kaldır), the dialogs' focus trap, Esc and focus return, the typed `onayla`, error replies in the backend's
words, jobs in the activity drawer whose end reads the page again, a removed application, built-ins, a
package without a Konsol page and an unknown id; 1440, 390 and 320 px in both themes with no style
attribute and no horizontal scroll. Screenshots go to a fresh temporary directory, printed at the end.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulamalar-ui.cjs
```

## New interface phase 3: Erişim, the Yayınla flow and the pending change (DD-258)

Two suites drive the committed build through `yeni-harness.cjs`, which since phase 3 also answers a reply
with `contentType` as it is (a PNG, a text file) and takes `h.dynamic` handlers for paths with variable
parts (a package's `/api/uygulama/<id>/…` routes).

`yeni-erisim-ui.cjs` (`KONSOL_URL`, default `http://127.0.0.1:8771`): Erişim → Genel (warnings first, each
"Düzelt" by its `duzelt`: the Yayınla flow on Adresler, the application's page or the Tailscale tab; the
summaries; every service's four cells in plain words, `teknik=1` adding addresses and the technical lines),
Tailscale (device, addresses, version, key expiry under 14 days, exit node, the admin console link, the
disconnected state), Adresler (the publications with state, certificate and who guards them; the local names
with Konsol's own locked; a DNS draft → `POST /api/konsol/ayarlar/plan` → `…/uygula` with the exact same
body; a refused plan and "Yeniden denetle"; the local domain with its 300 s window, confirmed only from
`http://panel.<new>`, rolled back from the banner; removing a manual address with `{web: {service, sil: true}}`),
the Yayınla flow (a package's internet name with the DNS record and the certificate wait; the Konsol row,
planned only after the typed word, sent as `onay`; a container without a loopback port: the plan's
container request unchanged to `…/konteynerler/islem`, the job's end through a pushed `islemler` event, then
the settings request unchanged; a failing second step and a failing job; another port as a new manual
address through `ayarlar/plan`; an `engel` and "Yeniden denetle"; both names off; a stopped package; an
unknown target), Güvenlik duvarı (the catalogue merged with the rules, listeners, locked rows, a baseline
switch and a new `u_…` rule with its checks, IPv6, the network tabs, the technical rules with counters, plan
→ apply → the 60 s banner → Onayla and Geri al, a plan that cannot be applied), a stuck rollback (retry,
typed discard), a refused confirmation, the internet channel's message (`newHttpsPage`), an application
page's Erişim tab opening the flow in place, the palette, and 1440/390/320 px in both themes.

`yeni-wireguard-ui.cjs` (default `http://127.0.0.1:8772`) feeds a fixture of the WireGuard package's own API
that changes as the page asks: networks as tabs (`ag=`), on at once and off after a question, devices with
their state, DNS, keepalive, addresses, last seen and traffic, the exact bodies of every write (devices,
DNS and keepalive, networks, the name and default DNS with the revision and a 409 on a stale one,
regenerating and removing with the typed `onayla`), QR codes and profiles fetched only on a click with
`cache: "no-store"` and their object URLs revoked (the QR's when decoded, the profile's after 10 s, checked
with Playwright's clock), the limit, no network yet, the stopped and the not-installed package, and `/state`
read every 10 s only while the tab is shown and the browser tab visible.

`yeni-ui.cjs` and `yeni-uygulamalar-ui.cjs` changed only where phase 3 meant them to: Erişim is no longer a
placeholder, the palette's current-interface views no longer list Caddy, Dnsmasq and the firewall, the
pending banner confirms and rolls back itself, and "Düzelt" and an application's "Erişimi düzenle" lead to
the new views.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-erisim-ui.cjs
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-wireguard-ui.cjs
```

The backend (DD-265): `test_settings.py` checks the plan of firewall, DNS, domain and publication
changes (before/after, restarts, the confirmation window, a plan refused like `apply`, nothing written,
`uygulanabilir` false from the internet channel and for a rule that would cut the caller off);
`test_publications.py` the plan of one publication row; `test_yayin.py` the candidates (packages, Konsol and
foreign containers, a container joined to its manual address, the reasons an internet name is blocked),
`free_port`, the one- and two-step plans, `engel` and the routes through the real handler;
`test_erisim.py` the warnings' row ids and `duzelt` and the Tailscale summary; `test_wg_settings.py` a
network's new name through the package's API and its rejected names. Bats checks the routes in the table,
`master-wg net-settings` renaming a network without touching keys, profiles or services (and refusing bad
names) and that the installer ships `master_yayin.py`.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_yayin.py'
```

## New interface phase 4a: Sistem and Gelişmiş (DD-258, DD-266)

`yeni-sistem-ui.cjs` (`KONSOL_URL`, default `http://127.0.0.1:8773`) drives the committed build through
`yeni-harness.cjs`. Sistem → Sağlık: every check with problems first and the last check time; the last
repair report (who ran it, the mode, start and end, each step with its state); "Denetle" at once and "Onar"
after a confirmation (`POST /api/konsol/onarim` with `{kip}`), a refusal, the report read every 2 s while a
run goes on and its end through a pushed `islemler` event; the repair log as the server's plain text in a
sheet (`gunluk=72s|7g` in the address, scrolled to the newest line, copied whole, a failed read, an empty
log). Güncellemeler: installed and newest version with their builds, "Yeniden denetle" (`?yenile=1`), the
confirmation's words, a refusal, the stage from the `guncelleme` job, an earlier run's end ignored, the page
reloading after success, a failed run without reload, a failed check. Hesap: creating the account on the
tailnet with master_auth's rules and a refusal, the tailnet password without the current one, the internet
password with it, a wrong current password (401 without `giris`) shown on the form while an ended session
(401 with `giris`) goes to the sign-in page, and the leave guard. Sunucu: the facts and the reboot (typed
word, a refusal, the wait, the server going away and back with a shorter uptime, the reload). Görünüm and
Günlük (newest first, the packages' `gunluk` templates from `moduller`, kind chips `tur=`, a Turkish-aware
search `ara=`, a missing package list). The internet channel (`newHttpsPage`): repair, update and reboot
locked with their reasons, "Çıkış yap" in the sidebar and the phone's menu sheet. Gelişmiş: Caddy's sites
(routes, owner, access, scheme), the raw files (`ham=1`) with copy, "Yenile" past the cache and a failed
read; DNS from the same read; the firewall tab's links to Erişim's technical rules; Podman's images,
volumes and networks (`kaynak=`): what may not be removed and why, "İmaj çek" with the reference check, the
exact `…/konteynerler/islem` bodies, each job's steps and end through `islemler`, a failed job, removal with
the typed word, a sheet closed while its job runs, an unreadable collection, a runtime that does not answer.
Also "Tüm denetimler", the palette's new tabs, keyboard and focus, and 1440/390/320 px in both themes with
no style attribute and no horizontal scroll.

`yeni-ui.cjs`, `yeni-uygulamalar-ui.cjs` and `yeni-erisim-ui.cjs` changed only where phase 4a meant them to:
Sistem and Gelişmiş are no longer placeholders, the palette's current-interface views no longer list
Settings' system view and log, "Tüm denetimler" leads to `#/sistem?sekme=saglik`, "dnsmasq" also finds
Gelişmiş → DNS, and Erişim's DNS, domain and firewall drafts ask before the browser tab closes.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-sistem-ui.cjs
```

The phase 4a backend (DD-266): `test_api.py` checks the moved and new table routes through the real
handler (the account state, the audit log, the repair log as plain text, the folder picker, Gelişmiş's
configuration, the Podman reads, a package's account with and without `parola=1`, `kur` with its form,
a body of another shape refused); `test_container_worker.py` checks that a job waits for a held install
lock and refuses after the wait.

## New interface phase 4a: adding applications and their settings (DD-258)

`yeni-uygulama-ekle-ui.cjs` (`KONSOL_URL`, default `http://127.0.0.1:8774`) drives Uygulamalar' add flows
and the application page's container views through `yeni-harness.cjs`, with every request body compared
exactly and every job's end pushed as an `islemler` event. Uygulamalar: the add card (catalogue links,
the number of adoptable containers, no links to the old interface's App Store or Podman) and Altyapı
(unhealthy, update-available and storage counts from `GET /api/konsol/konteynerler/liste`, links to
Gelişmiş's Podman lists). Katalogdan (`?ekle=katalog&paket=<id>`): only packages not installed, a
package's own words, its install form drawn from the `konsol.json` declaration (the declared default, an
unrendered `__X__` default treated as none, required, pattern, length, the repeated password, the folder
picker with free space, entering a folder, Esc closing only the picker), a refusal keeping the draft, an
older finished job of the same package not counted as this install's end, the progress line, the
application's page on success, a package without a form and a failed job. Bir imajdan (`?ekle=imaj`):
the checks of every field (image, name, ports with scope and the internet acknowledgement, duplicates,
volumes and server folders, the writable-bind account rule, environment with secrets, command, limits),
the review with internet ports called out and "Oluşturunca başlat", a refusal, a failed job keeping the
draft and the new application's page. Var olanı yönetime al (`?ekle=sahiplen&ad=<name>`): only foreign
containers with the server's reasons, the preview job and its record, every scope chosen again, the
account rule, the typed word, the exact adoption request, unsupported options blocking and a failed
preview. The application page: a Konsol container's Özet (source, unit, ID, tag, update state with
channel and time, `?yenile=1`, limits, command, environment without secret values, how it starts), the
ports by scope and a host container's listening sockets, Depolama, Günlük (`?satir=`, `?ara=` with marked
matches and Turkish case rules), Güncelle and İmajı güncelle with their results, the definition editor
(the draft surviving tab switches and reads, the field-by-field diff and consequences, a stale revision
with "Güncel tanımı yükle", the save with a kept secret, a failed job, start after saving a stopped one,
the leave guard), adopting from the page, an App Store adapter (checks, picker, diff, save), the
package's settings form (no password read, only changed fields, a blank password kept, a refusal), the
first-login account (the password fetched only on request, shown for 30 s with Playwright's clock, hidden
with the browser tab, copied without being shown), a package without settings, the palette's add
entries, and 1440/390/320 px in both themes with no horizontal scroll or overflowing card.

`yeni-ui.cjs` and `yeni-uygulamalar-ui.cjs` changed only where phase 4a meant them to: Uygulamalar reads
Podman's counts, the add card and Altyapı lead to the new flows and Gelişmiş, an application page reads
its container's detail, a container offers "İmajı güncelle", and Ayarlar holds the settings instead of a
link to the old interface.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulama-ekle-ui.cjs
```

## New interface phase 4b: Dosyalar (DD-258, DD-267)

`yeni-dosyalar-ui.cjs` (`KONSOL_URL`, default `http://127.0.0.1:8775`) drives Dosyalar' Depolama, Sunucu
klasörleri, Çöp kutusu and Sistem dosyaları through `yeni-harness.cjs`, with an in-memory files backend
that answers `/api/*` and `/api/sistem/*` in the real backend's shapes and words (state, list with
`dirs=1`, text with its encoding and version, save, download, raw-body upload, mkdir, rename, move, trash,
restore, purge, empty, delete with the typed confirmation) and every request body compared exactly. The
real editor bundle (`console/duzenleyici.js`) is served at `/duzenleyici.js`. Depolama: the disk (used,
free, the user area without the trash, its own mount), the trash in short with its link, Gezgin's address
or the way to install it, the top folders in Turkish order with size, count and who uses them
(applications' binds with access and container path, a bind of the whole user area in short on every
folder, folder shares, a package's own folder with its owner, binds outside the listed folders, a failed
`GET /api/konsol/depolama`). Sunucu klasörleri: Turkish order with numbers, sizes and times, the share
marks with "Paylaş" (`?sekme=paylasimlar&yeni=<path>`) and "Paylaşımı yönet" (`&paylasim=<id>`), the filter
(`ara=`, Turkish case rules), ticks and "Tümünü seç", folders as history entries (`yol=`), a folder that
cannot be opened, a package's folder and one that holds it (no ticks, no changes, uploads refused),
uploads from the picker and a drop (a name already there skipped, one at a time with progress, a waiting
and a running upload cancelled, a refusal, the leave guard), download, new folder, rename, move (the
dialog browses with `dirs=1`, never into a moved folder or a package's folder, a refusal) and trash. The
editor (`dosya=`): CodeMirror under the CSP, the language, the cursor position, Ctrl+S and Kaydet with the
version the last save returned, a 409 with "Yeniden aç", another encoding, Kapat, Esc and Back with unsaved
changes asking inside the sheet, read-only files with their reason, a binary refused, the bundle failing
to load. Çöp kutusu: restore of several items with a taken name numbered, a broken record, a refusal,
permanent delete and empty with the typed word. Sistem dosyaları: the root warning, no trash or shares, a
permanent delete confirmed with the item's own name (several with "onayla"), a mount point refused, the
editor's root-save warning, upload and move on `/api/sistem/*`, the other tab's folder left behind, the
backend's refusal (403/404) as a tailnet-only explanation and no tab over HTTPS. Also 1440/390/320 px in
both themes with no horizontal scroll and no style attribute outside CodeMirror's own tree (it positions
its gutters and cursor through the CSSOM, which the CSP allows).

The harness gained three additive helpers for the files backend: `h.raw(path)` marks POST paths whose
body is a raw upload (logged as `{size, text}`), `h.unsigned(path)` marks GET paths a plain link opens
without `X-Konsol` (a download; Playwright does not route downloads, so the static server answers them
from the same handler), and a handler may return a promise to hold a reply back (an upload in flight that
the page may cancel). `yeni-ui.cjs` gained fixtures for the files backend's state and listing and for
`GET /api/konsol/depolama`, which Depolama reads.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-dosyalar-ui.cjs
```

## Gezgin package (v2-245, DD-262)

`test_gezgin_package.py` drives `magaza/gezgin/ayar.py` with faked commands: the install form (every
field refused before the hash is made, the password only on Caddy's standard input, a hash that is not
bcrypt refused, a 0600 seed with the hash only), `kur-uygula` and `kur-geri` (the name and the hash in
`ilk.env` with `$` literal; the earlier file restored, or removed when there was none), seeds that are
not private or not their shape, the CLI (no password printed, nothing to edit from the Podman page) and
the data folder under `/var/lib`. The adapter: nothing editable, the protected mounts, a revision that
follows the placed Quadlet and the registry line. The image update: an up-to-date channel, the new
digest pinned everywhere with one restart, rollback on a failed restart, a stale revision and a missing
channel. `yayin.py` against a local HTTP server: the probe needs `/health` 200 and an anonymous API
call refused with 401, listing probes nothing, a closed port raises for the caller. The package files:
every placeholder resolves, a pinned image and a unique port, the Quadlet's loopback publication, mounts
and dropped capabilities, the form matching the worker's limits, the hook's refusal of a same-named
container of another manager (with a fake `podman`), the account written before the first start and
emptied after it, and the masked random password. `common.bats` checks every container package's
Quadlet for the DD-223 lines, the installer summary's Gezgin line and that `master-modul kur` builds
the container guard again after the registry line.

## Files favourites (v2-232, DD-250; removed in DD-267)

The root backend no longer stores favourites: `test_favorites.py` is gone, and `test_overview.py` checks
that `/api/konsol/favoriler` answers 404 and writes nothing. A Bats test runs the installer's removal of
an old `KONSOL_AUTH_DIR/favoriler.json` (regular file only).

## Text editor (v2-231, DD-249)

`test_text_edit.py` covers the backend in temporary directories: the version and the reasons the text
view gives, an atomic replace that keeps mode, owner (as root) and extended attributes, CRLF and the
UTF-8 BOM kept, Windows-1254 written back, unencodable text refused, a changed file or a swap before the
rename refused (409), oversized text, symlinks and folders refused, and no `.konsol-kayit-*` left behind.
`test_system_files.py` saves through the real handler on the root view (a body above `MAX_BODY`, a stale
version, the gate). `yeni-dosyalar-ui.cjs` opens the real bundle under the production CSP in both trees
(phase 4b above).
`common.bats` checks the bundle's banner against `tools/duzenleyici/package.json`. To rebuild the bundle:
`cd Data/tools/duzenleyici && npm ci && npm run derle` (the output is byte-identical for the same lockfile).

## Sistem dosyaları, the root view (v2-214, DD-235)

`test_system_files.py` runs the backend's `--sistem` mode in temporary directories and on a temporary
Unix socket: read-only `/proc` `/sys` `/dev` `/run`, root modes for new items, no reserved names,
permanent delete refused at a mount point (or a mount below) and at a device change, `mountinfo`
unescaping, the channel/client/Host gate (200 only for another Tailscale device on the tailnet site),
system-only routes, name/`onayla` confirmation, and the settings view's Caddy parser leaving the route
out of the public site. `common.bats` checks the unit, the tailnet-only Caddy matcher, the installer wiring and
the stage-7 probes. `yeni-dosyalar-ui.cjs` covers the tab (tailnet only, no trash or shares,
`/api/sistem/` calls, the typed-name delete). The Caddy matcher was also
adapted with Caddy 2.10 (the `{args[0]}` placeholder needs Caddy ≥ 2.7; Debian's 2.6 cannot check it).

## Files account for writable folders (v2-205, DD-227)

`test_container_worker.py` checks:
- the Files-account render (`User`/`Group`, `DropCapability=all`, `--umask=0002`);
- the refusal of the image account with a writable folder before any Podman call, while read-only
  folders and volumes are allowed;
- the defaults: new definitions get the Files account, a value is preserved when omitted, and older
  definitions render as before;
- that invalid ids fail closed with 503;
- that `ready()` proves the account and the empty capability sets, printed as `null` (Podman 5.4.2)
  or `[]`, and fails closed when a field is missing (mutations that skip the check, accept a missing
  field or reject `null` turn it red);
- the adoption mapping.

The fake runtime reflects the Quadlet's account lines and prints a fully dropped capability set as
`null`, as Podman 5.4.2 does. `yeni-uygulama-ekle-ui.cjs` checks the account rule on create, in
adoption and in the definition editor.

The live worker fixture owns its writable folder by the downloads account, as `/srv` is.

## Pinned bind sources (v2-204, DD-226)

`test_container_binds.py` runs the real helper with fake mount calls. It checks that:
- the bound directory is the one behind the walked descriptor, even when the path is swapped for
  a link right after the walk;
- links (final or intermediate), hidden, outside, root, file, missing, `..` and bad-character
  sources are refused, and partial anchors are released;
- an unmounted anchor is never accepted;
- unsafe anchor directories are refused;
- `birak` removes only empty folders;
- a stale anchor is released first;
- the helper loads no package code and takes no lock.

`test_container_worker.py` checks the generated lines: guard check first, then `bagla`, the anchor in
`Volume=`, `RequiresMountsFor` with the real path, and `ExecStopPost` only with binds.
`containers-worker-linux.py` copies the helper, gives its fixture an anchor directory, and refuses
to delete its scratch tree while an anchor is still mounted.

## Private package state (v2-203, DD-225)

The Bats test "package private state is hidden" checks the new `PRIVATE_STATE_ROOT` key. The
WebDAV unit must have exactly one `InaccessiblePaths=` line (trash,
`/var/lib`), `RequiresMountsFor` and no `SystemCallErrorNumber`. The Files unit must mask only
`/var/lib`, and the installer must pass the key. Neither unit may name an application, and
qBittorrent's profile directory must lie under `/var/lib`. The test also renders both templates
with every placeholder filled and checks the resulting mask lines.

## Container egress (v2-202, DD-224)

`test_container_network.py` pins the rule order:
- the one-rule path for traffic that neither enters nor leaves a bridge;
- the reply returns;
- then the IPv6, `tailscale0` and per-prefix drops, in `VPN_BLOCK_DEST4` order (from
  `config/defaults.env`, with no address literal in the module);
- a /32 rendered as an address.

It also checks that a missing, empty or invalid list fails closed with 503, and that health
detects a deleted or swapped egress rule. The live namespace suite `containers-network-linux.py`
adds echo servers next to the host and probes from the container namespace. 192.0.2.2 and
198.51.100.2 are reachable. The tailnet, WireGuard, 192.168, 169.254 and IPv6 peers are not.
Tailscale-scope and WAN publication replies still pass. `containers-worker-linux.py` gives its
fixture the same list.

## Container start precondition (v2-201, DD-223)

`test_container_worker.py` checks the generated Konsol Quadlet: `Wants=` and `After=` on
`master-firewall.service`, no `Requires=`, `BindsTo=` or `PartOf=`, one `ExecStartPre` that ends
in `--check`, `RestartSec=10s`, and no check for a container without a network.
`test_container_network.py` checks that `check()` names a missing guard table and still reports
other read errors as before. It also checks that a loopback-only port change leaves the policy
unchanged, which is what lets qBittorrent's interface-port restart pass its start check. A Bats
catalogue rule applies the same unit lines to every package that declares its own bridge.

## Pending package changes across a failed run (v2-200, DD-222)

The Bats test "pending module markers" runs the real `render_package_dir`,
`ensure_module_files` and `reapply_modules` against a fake one-package repository.
`install`/`chown` and `master-modul` are stubbed. Each simulated installer run is its own
subshell, as each real run is its own process. A run renders a changed Quadlet and then fails
before stage 7. The next run renders nothing new and still calls `uygula` exactly once; the run
after that calls nothing. The test also checks that a failed `uygula` keeps the marker and
warns, that the next run retries, and that a package that is not installed loses its marker
without a call. For the built-in WebDAV, a `paylasim` marker reaches `master-modul yerlesik`
after a failed run and is then cleared. The wiring of stages 4, 6 and 7 is checked statically.

## Container manager (v2-190, DD-211)

Local checks need no server:

```bash
python3 -m unittest discover -s tests -p 'test_container*.py'
```

Use Python 3.11 or newer (nrm uses 3.13); macOS's system Python 3.9 does not parse
the nanosecond RFC3339 timestamps returned by the runtime. The suites cover merged
inventory/stopped definitions, real Podman JSON shapes, API gates, private results,
stale revisions, recreate/rollback, explicit adoption, volume/network boundaries,
package port overrides, bridge DNS INPUT permissions, ownership-aware listener
conflicts and the existing tailnet event's bounded refresh job.
The browser suites (`yeni-uygulamalar-ui.cjs`, `yeni-uygulama-ekle-ui.cjs`, and `yeni-sistem-ui.cjs` for
Gelişmiş → Podman) exercise the build with mocked API state; they do not prove Podman, firewall or server
mutations.

`containers-network-linux.py` requires Linux/root and is run inside a disposable
network namespace (`unshare --net --fork`). It tests actual TCP/UDP packet paths,
scope revocation, direct/IPv6 ingress and preservation of foreign nftables tables.
`containers-worker-linux.py` requires a disposable rootful Podman/systemd host with
the project firewall already active. It creates only uniquely named test resources
and cleans them up; it checks real Quadlet execution and lifecycle behavior.
Do not run live fixtures concurrently with installation or another nrm test.
Installation/reboot persistence and the actual application/browser journey remain
separate acceptance checks; record exact runs and untested platforms in the change's DD entry
(its live check) and `CHANGELOG.md`.

## Public Konsol over HTTPS (v2-167, DD-195)

`test_publications.py` covers the Panel row: the tailnet switch cannot close, an
account and the server-checked word `onayla` are required when turning on or
renaming, DNS/duplicate/legacy-HTTP checks, the generated
`panel-wan.caddy` (WAN bind, TLS-ALPN, HSTS, only `import konsol internet`), its
certificate status, the shared TCP 443 firewall output with WebDAV's WAN off,
removal at the next publish after an account reset and rollback after a
certificate failure. `test_konsol_auth.py` covers the shared public failure
budget, one password check per address and two at once, and the root backend's
channel rules on a Unix socket: closed publication, refused account creation, `Secure`
cookie, own-address and unmarked clients refused, `kanal` in the session state and
the 5-second publication cache, and the budget re-check after a hash slot.
`test_settings.py` checks that a local-domain change rewrites the snippet's
backend Host and that a confirmation through the public channel is refused.
`common.bats` checks the snippet, the Caddy-written channel header, the backend
connection cap, the forwarded host and channel on confirmations, and the
installer cleanup; `yeni-erisim-ui.cjs` drives the Konsol row in the Yayınla flow
with the typed word; `giris-ui.cjs` the Tailscale/internet label.

v2-168: `test_resources.py` checks the module listing's `urls` for qBittorrent
(tailnet name always; the public name only while that publication is active or
`null`); `yeni-uygulamalar-ui.cjs` checks "Aç" on an `https://` origin (the internet name).

v2-177 (DD-203, store phase 3): the shared share fixture (`test_share_manager_networks.
torrent_package`) renders the torrent package folder — manifest with `PAKET_KLASORLER`,
`klasorler.py`, `torrent.env` — so `test_shares.py`, `test_stage3_share_paths.py` and
`test_backend_hardening.py` exercise declared and reported folders through the package
module (fail closed on an unreadable profile); `test_shares.py` checks the WebDAV server
hides and refuses a reported folder inside a share by path; `test_webdav_*` configs use the
root-relative `protected` list; `test_torrent_api.py` covers `package_env`, the standalone
worker reading `torrent.env` beside itself and `klasorler.yazilan`; `test_resources.py`
resolves a `PAKET_PORTLAR` key from the package's env file; `test_publications.py`,
`firewall-linux.py` and `publications-proxy-linux.py` write `torrent.env` into their
package folders, and `settings-domain-linux.py` takes the torrent site's port from it. Bats checks the installer helpers (`paket_korunan_klasorler`,
`paket_arkauc_yollar`, `paket_ayar_oku`) against rendered manifests, the `--protected`
file-backend argument and that no base file names an application or carries a `TORRENT_*`
key. Browser fixtures return `protected: [{path, owner}]` from `/api/state`.

v2-176 (DD-202, store phase 2c): `test_torrent_api.py` drives the qBittorrent package
worker (`ayar.py`: hash format, INI preservation, the read-only view without the hash,
validation before any service change, stop/write/start order, failed-start recovery,
stopped-state preservation, the narrow drop-in and its rollback, the CLI) and its API
module through a fake context and through the real dispatcher (gates, the package-folder
rule for worker scripts, the private stdin run, the `torrent:ayar` audit line; since DD-269 `/ayar`
is the only write and `/hesap`, `/dizin` answer 404);
the package's settings form on the application's Ayarlar tab is `yeni-uygulama-ekle-ui.cjs`'s (the
package's own page went in DD-267); `test_backend_hardening.py` points the profile-reader checks at
`ayar.read_conf`; `settings-linux.py` runs the worker's functions against real
qBittorrent; Bats checks the status view, the private worker run and that the shell
and the settings page name no application.

v2-173 (DD-199, store phase 1b): `test_publications.py` renders the qBittorrent
manifest and copies `yayin.py` into the fixture `MODULES_DIR`, so rows, sites and
checks come from the package; it also covers a failing, unparsable and missing
check module (row closed, app never exposed) and a manifest without a loopback
upstream (no row). `publications-proxy-linux.py` does the same against real
Caddy and qBittorrent, and `firewall-linux.py` copies the manifest and module so
the shared TCP 443 permission still follows an active qBittorrent row.

v2-172 (DD-198, store phase 1b): the firewall Bats test and `firewall-linux.py`
copy the WireGuard package's hook into the fake `MODULES_DIR` and drive the
firewall through its `vpn` declarations (malformed or clashing declarations stop
before any chain changes); `test_stage4_health.py` derives the fake
`master-modul saglik` output from the fixture registry; `test_resources.py` and
`test_firewall_view.py` build port rows from copied manifests, including a
malformed manifest whose rows are skipped.

v2-171 (DD-197, store phase 1a): the Bats fixtures copy each package's
`paket.env` and `kanca` from `magaza/` into the fake `MODULES_DIR`, so the
module tests run the real engine against the real hooks; the engine itself is
checked to contain no application id. Installer tests check the generic
renderer (`render_package_dir`), the manifest-driven reapply flag and the
summary built from manifests and `paket_ozet`.

v2-170 (DD-196, store phase 0): the Bats test "store phase 0" checks the repo
layout (`magaza/`, the WireGuard tool and drop-in inside the package), that the
base installer neither installs nor keeps them, that `master-modul` places and
removes them, the package-neutral stage-7 probe, the Caddy unit without
`--environ`, the backend's unit name and Konsol's log labels by source.

v2-169: `test_publications.py` adds the fresh-install case: with WebDAV in
legacy HTTP mode, Panel/qBittorrent HTTPS is refused only while a folder is
actually shared over plaintext HTTP, publishes once that connection is closed,
keeps legacy HTTP unavailable (cards and the WebDAV row say why) while the
HTTPS row is on, and reopens it when the row is turned off; the firewall port
follows. Paylaşımlar shows the server's reasons (`yeni-paylasim-ui.cjs`).

```bash
python3 Data/tests/panel-public-live.py --host nrm --domain konsol.example.com
```

`panel-public-live.py` is opt-in and **mutating**: it needs the operator's existing
Konsol account and a name with a DNS-only A record to the host's WAN IPv4 (no
AAAA). It publishes Panel on that name through the real settings API (`ayarlar/uygula`; the
rows come from `yayinlar`), checks HSTS, the sign-in page, session protection of pages/Files/root
APIs, account creation refused over the internet, one wrong sign-in and a root-issued automation session over the public
address, then restores the Panel row exactly and checks that the name no longer
reaches Konsol. It exits 3 without changes when there is no account or Panel is
already public.

## Install form (DD-210)

`test_torrent_api.py` covers the worker's `kur-hazirla` (every field refused before any write, the seed
only in `RUNTIME_DIR`, 0600, hash only, writability probed as the service user), `kur-uygula` into a kept
profile (only the four keys change, other preferences stay, the folder drop-in, no service command) and
`kur-geri` (profile and drop-in restored byte for byte), refusal of a readable, linked or malformed seed,
the combined `ayar` save (validation first, one stop/start, blank password keeps the hash, failure restores
both files, a stopped app stays stopped), the CLI, the API module's `/ayar` route, and the real backend's
install (`POST /api/konsol/uygulamalar/islem` with `eylem: "kur"`) on a Unix socket (form required, worker before engine, password only on stdin and never in
argv or audit, seed removed when the engine cannot start, installed package refused before the worker,
WireGuard refuses a form). `common.bats` runs the real engine and hook against the fake Podman/systemd:
no install without a seed or with a readable one (no image pulled), the form's account and folder in the
profile at the first start, the seed gone afterwards, a kept profile's preferences preserved with a
library-folder drop-in, failed installs restoring the previous profile and drop-in, and the backend's
worker-then-engine order. `yeni-uygulama-ekle-ui.cjs` drives the catalogue's install form and the
settings form (phase 4a above); `yeni-uygulamalar-ui.cjs` the launch in a new tab and the actions.

## Peer port editor (v2-199, DD-221)

`test_container_package.py` changes the peer port through the package adapter (`konteyner_ayar`):
a stopped app gets both WAN `PublishPort` lines and `TORRENTING_PORT` moved in the rendered Quadlet,
`Session\Port` in the profile and an override holding only `TORRENT_PEER_PORT` (no interface-port
pin, no port drop-in, no Caddy change); a running app gets the placed Quadlet moved too and the
container guard applied before the start; a failed start restores every file and reapplies the guard
before the app starts again.
Refused before any service action: a non-integer, out-of-range or interface-equal port, another
service's port (base `*_PORT`, a saved definition's UDP port), a port the WAN probe finds taken, a
Quadlet whose WAN lines or `TORRENTING_PORT` do not match, and an unknown config key. The probe
itself refuses a held TCP and UDP port. `yeni-uygulama-ekle-ui.cjs` edits it in the adapter card on the
application's Ayarlar tab (checks, the diff, the save). `common.bats` pins the guard-before-start order and the allowlist.

## Data removal keeps Konsol's choices (v2-198, DD-220)

The `common.bats` engine test sets a durable `TORRENT_UI_PORT` choice (`PACKAGE_OVERRIDES_DIR`) and the
port drop-in `85-konteyner.conf` before `kaldir --veri`, and asserts that both survive while the image
(removed by id) and the folder drop-in go and the fixture profile (outside `/var/lib`) stays; the
`/var/lib`-only profile guard is pinned statically. The later reinstall steps run with the override in
place; it holds the fixture's default port, so they do not exercise a non-default one.

## qBittorrent on its own bridge (v2-195, DD-217)

`test_container_network.py` builds a registered package with a placed Quadlet: the guard lets
through only its WAN publications (TCP and UDP) into the package bridge, needs no rule for the
loopback interface, ignores an address that is not the server's, and publishes nothing for a stopped
or unregistered package or for a placed Quadlet on another network (the installer's upgrade window).
`test_container_package.py` moves the loopback `PublishPort` line with the interface port in the
rendered and the placed Quadlet, restores both on failure and refuses a Quadlet without that line
before stopping anything; `test_torrent_api.py` checks that the install writes `WebUI\Address=*`.
`test_container_listening.py` labels published addresses (the WAN one as internet access) and names
the bridge in the detail. `common.bats` drives the engine with fake podman: the bridge is created
once with the guard's interface name and the package label, removed with the package, and an
unexpected publication stops the install; it also pins the three `PublishPort` lines.
`yeni-uygulama-ekle-ui.cjs` shows the ports by scope and a host container's listening sockets on the
application page.

## Listening ports (v2-194, DD-215)

`test_container_listening.py` builds a small `/proc` and cgroup v2 tree: only the container's own
processes' sockets count (TCP LISTEN, unconnected bound UDP; peer connections, connected UDP, unbound
and link-local binds, and the host's own listeners left out), IPv4-mapped and IPv6 addresses, child
cgroups, the root cgroup never widening to the host, unknown as `None` and never an empty list, the
address kinds (the server's own WAN address wins over the CGNAT range), and the manager reading only
running host-network rows with the installer's WAN/Tailscale addresses. `yeni-uygulama-ekle-ui.cjs`
shows a host container's listening sockets on its application page.

## Image update check (v2-193, DD-214)

`test_container_updates.py` covers `update_status()` (index by host platform digest, single
manifest by config digest, pinned/unreachable/missing answers, manifests only), the manager's
cached status (TTL, one forced check a minute, cache emptied after a successful image change,
no pull target to the browser), `image-update` only for packages with a channel and an adapter,
and the GET-only route behind the gates. `test_torrent_api.py` `ImageUpdateTests` drives the
qBittorrent adapter: no-op when current, exact-digest pull after validation, patched Quadlet and
manifest lines plus the override (port choice kept), restart/UI/ImageName checks, full rollback on
a failed restart or a wrong image, a stopped app, and refusals that change nothing.
`yeni-uygulama-ekle-ui.cjs` checks the update state with its channel and time, "Güncellemeleri denetle"
(`?yenile=1`) and "Güncelle"/"İmajı güncelle" with their results; `yeni-uygulamalar-ui.cjs` the update
state in the list. `common.bats` pins the manifest-only check, the adapter order, the channel
keys and the absence of any automatic update.

## Podman in the base and qBittorrent in Podman (v2-186, DD-208, DD-209)

`test_containers.py` drives `panel/master_containers.py` with canned `podman` JSON: the list
(containers, host network, ps ports, images, storage size), a calm answer when podman is
missing or fails, `inspect` mapping (sorted mounts, port bindings, three labels, health, never
the environment), unfiltered log lines (DD-251) with a bounded tail, name and path
gates and RFC 3339 parsing; a route test runs the real backend handler on a Unix socket (shared
gates, 400/404 answers, no write route: POST → 404, no podman write verb).
The browser side of the container manager is `yeni-uygulama-ekle-ui.cjs` (create, adopt, the definition
editor) and `yeni-sistem-ui.cjs` (Gelişmiş → Podman's images, volumes and networks).
`common.bats` pins the stage-1/7 Podman install and check (no daemon units), the base view's
files and routes, the engine's quadlet slot and digest-only image (`docker|compose` stay banned,
no `/etc/containers` literal in the engine), the qBittorrent quadlet (its own bridge
`Network=__TORRENT_NETWORK__` with exactly three `PublishPort` lines since DD-217, `Pull=never`,
two same-path mounts, no `NoNewPrivileges`), and the qBittorrent lifecycle against a fake
`podman`/`systemctl`/`ss`: pull once by digest, seed before the first start, host uid / mount /
exact `podman port` set / loopback-listener checks with rollback, stop removes the quadlet, a changed quadlet restarts,
`--veri` removes the image by id.
`test_torrent_api.py` covers the worker's quadlet drop-in (same-path `Volume=` only outside the
downloads tree, unmountable names refused, the wait for the interface after a restart) and
`settings-linux.py` runs the same worker against a real qBittorrent with a scratch
`KONTEYNER_BIRIM_DIR`.

## Backend write paths (v2-184, DD-207)

`common.bats` checks that the installer lists declared write paths one per line, creates them
before the backend (re)starts and restarts a backend whose mount table lacks a writable mount
for one (fixture mountinfo: present rw, missing, read-only, no running backend); that the store
engine creates a missing path and restarts the backend only when needed after `kur`, `baslat`
and `uygula`; and that `master-wg` refuses writing commands on a read-only folder with the
Turkish remedy while reading still works (skipped when the runner is root).

## Network card and retired routes (DD-206, DD-212, DD-267)

`test_overview.py` checks that the retired layout, favourites and old-shell routes (DD-267:
`/api/konsol/duzen`, `/favoriler`, `/ayarlar`, `/ayarlar/durum`, `/moduller/<id>/…`) answer 404
behind the X-Konsol and Host gates and write nothing, and covers the WAN rate sampler (the
last rate only since DD-269: deltas, the 1.5 s step, counter resets, a stale baseline, interface name checks, a new
interface), `/api/konsol/ag` with package traffic modules in a temporary catalogue (installed,
stopped, unregistered, undeclared and built-in packages; broken modules reported once; the
2 s cache; no bytecode in the package folder; the 120 s window) and both packages'
`trafik.py` (qBittorrent's real `AllStats` line from nrm, large totals through a Qt-style
escaper, no file yet and damaged records; the WireGuard registry and interface counters).
`yeni-uygulamalar-ui.cjs` checks Genel Bakış's network card (read every 5 s only while the page is shown
and the browser tab visible). `common.bats` pins the source guards; fixture browsers do not establish
live deployment or fresh-install acceptance.

## Konsol sign-in (v2-166, DD-194; v2-181, DD-205)

`test_konsol_auth.py` covers the account store (creation without a code and without a
session, user and password rules, scrypt-only storage, the name revealed only to a
trusted caller, decoy work for unknown users, session expiry/limit/malformed tokens,
password change keeping only the current session, the tailnet password change ending
every session, reset, automation sessions, unsafe directory/symlink/FIFO/oversized/corrupt
records), the per-address attempt limit, the root CLI and the real root-backend
endpoints on a Unix socket: `/oturum-denetle` answers by channel (tailnet 204 without a
cookie and `/giris.html` → `/`; without Caddy's headers 302 page, 401 API, 204 with a
session and an open sign-in page; 403 for host-local or foreign Host), account creation
from the tailnet only, cookie attributes, 429 with Retry-After, sign-out and both
password changes, and audit lines without secrets. `common.bats` checks the Caddy
`forward_auth` matcher and order, the open sign-in files, the backend's channel
branches, installer wiring/stage-7 probes and that no setup code remains anywhere.

`giris-ui.cjs` drives `giris.html` with intercepted APIs and the production CSP: internet
sign-in failure/limit/success, return to the original page, the no-account notice (Sistem →
Hesap), the tailnet and signed-in shortcuts back to Konsol and Konsol's redirect after a 401 (an
old address first taken to its new home, `#/ayarlar` → `#/sistem`). It needs a preview on port
8766 (`KONSOL_URL` overrides it) that serves the installed layout from one folder: the build's
files from `console/yeni/` with `giris.html`, `giris.js`, `giris.css`, `duzenleyici.js` and
`obhut.svg`/`obhut.png` from `console/` beside them (the redirect test loads the real interface
at `/`). `yeni-sistem-ui.cjs` covers Sistem → Hesap on both channels and the sidebar sign-out.

```bash
preview="$(mktemp -d)"
cp -R Data/console/yeni/. "$preview"/
cp Data/console/giris.html Data/console/giris.js Data/console/giris.css Data/console/duzenleyici.js \
   Data/console/obhut.svg Data/console/obhut.png "$preview"/
python3 -m http.server 8766 --bind 127.0.0.1 --directory "$preview"
# In a second terminal:
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/giris-ui.cjs
python3 Data/tests/konsol-login-live.py --host nrm
```

`konsol-login-live.py` is an opt-in **mutating** test for an authorized host that
has **no** Konsol account yet (it exits 3 otherwise and changes nothing). From the
Mac, a tailnet device, it checks that Konsol, Files and the root API open without a
sign-in and that the sign-in page goes back to Konsol, creates a temporary internet
account through the real Caddy path, changes its password from the tailnet, signs
in/out with it, checks the attempt limit, then resets the account and restarts the
root backend to clear the limit. Passwords and tokens are never printed.

Live tests that call Konsol through Caddy from the Mac (`share-connections-live`,
`https-live`, `publications-live`, `panel-public-live`, `backend-hardening-live`) open a short
root-issued session with `master-konsol oturum-ac` via `konsol_session.py` and close
it at the end. Host-side tests (`shares-live.py`) use the
loopback Files backend and the root socket instead, because Caddy refuses
host-local Konsol callers (DD-180).

## Per-connection WebDAV policies and dual-card Shares (v2-164, DD-192)

From the repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_share_connections.py'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_webdav_connections.py'
```

These fixtures cover exact schema-3 migration and idempotent schema-4 preparation,
malformed/conflicting policies, independent defaults, nested partial saves under
locks, preserved omitted expiry, both-off, per-scope RW acknowledgement, legacy
HTTP consent, global publication gates and candidate-versus-active URLs. Protocol
checks cover both RO/RW directions, listener/header isolation, cached authentication,
all DAV writes, disabled/expired scopes, live chunks and staged-publication checks.
`yeni-paylasim-ui.cjs` checks each connection's controls and the scoped payloads with intercepted
APIs (phase 4b).

Opt-in **mutating** acceptance from an authorized Tailscale client against a
disposable host with schema 4, working public HTTPS and both global routes enabled:

```bash
python3 Data/tests/share-connections-live.py --host nrm
```

It creates one temporary folder/account and checks independent RO/RW in both
directions, listing/ranges, scope-header spoof rejection, both switches/both-off,
preserved peer expiry and stale global-policy/pause API rejection. WAN-only expiry
is accelerated only for its fixture using an atomic registry write under
`install.lock` → `modul.lock` → `paylasim.lock`, then restart/publication. Cleanup
removes only its own account/files and verifies the original registry is
byte-identical by SHA-256. Credentials remain in memory/SSH stdin and are not
printed; Caddy settings are not changed. **Share edits restart active WebDAV and
interrupt all transfers/playback.** Run outside active playback and do not edit
real shares concurrently.

The main implementation task reports: 36 new tests passed on macOS and Debian;
full Python suite 366 tests (macOS four skips, Linux one); Bats 165 tests (three
skips); six browser fixture suites passed with screenshots reviewed. After a
successful portable deployment on `nrm`, the opt-in live script above and the (since removed)
read-only browser check of the installed UI passed: live HTTPS/Tailscale policies and
byte-identical cleanup, and the installed UI at three widths/two themes with zero errors or API
writes. See [the archived session notes](../docs/archive/SESSION-to-v2-206.md)
for exact run evidence and final host health. These results do not certify native
Infuse/Finder clients or a fresh supported-OS installation.

## Caddy publication table (v2-162, DD-191)

`test_publications.py` covers immutable Panel, exact catalogue/payloads,
independent DAV network gates, remembered off domains, native qBittorrent auth
requirements, duplicate/DNS rejection, first-row certificate failure, crash
rollback and module projection persistence. It reuses isolated transaction
fixtures and does not claim real ACME issuance.
Publication failure causes (v2-237, DD-254): `test_publications.py` reads Caddy's JSON error and `Error:`
lines and the firewall's "HATA:" line, and checks that a failing `caddy validate`, `master-firewall` or
reload (Caddy's journal) is named in the settings error with the previous state restored;
`test_https_settings.py` checks the folder share save names the publication's cause.
Caddy repository outage (v2-236, DD-253): `common.bats` runs `apt_update_caddy_tolerant` against a
stubbed apt-get/dpkg-query: a 402 on Caddy's repository alone passes and records "402 Payment Required"
on a host with Caddy, another failing repository or a host without Caddy stops, a clean refresh passes
untouched; stage 1 uses it, stage 6's first-install refresh stays strict, and the
repository URL lives only in `defaults.env`. The root-only `master-guncelle` test checks that the
closing "env failed with exit status N." line is skipped in Konsol's message.
Manual addresses (v2-235, DD-252): the tailnet and public sites and the `modul-elle.conf` line, no
Konsol routes on the public site, refused upstreams (other hosts, Konsol's own and package ports,
malformed ports) and names (fixed, package, DNS-answered, invalid), the limit, the tailnet switch and
removal leaving no file, a failed dnsmasq restart rolling back sites, name and settings, a local-domain
rename, and stale-site cleanup that keeps a name ending in `-wan`. `yeni-erisim-ui.cjs` adds one
through the plan and removes one.

`python3 Data/tests/publications-live.py --host nrm` is an opt-in **mutating**
test for a provisioned disposable host with verified DAV HTTPS and qBittorrent
installed (private or already public). It reads the public names from the host
and probes a missing name under the reserved `example.net`. It rejects Panel
WAN/duplicate/missing DNS through the real API, toggles each private route across
module reapply (every template address must answer 403, DD-193), and
disables/restores DAV HTTPS; a public qBittorrent must keep serving meanwhile.
It restores effective network choices and checks the folder-account digest. It
may interrupt transfers, never enables a new public hostname and never changes
application credentials.

On a Linux host with Caddy, qBittorrent, OpenSSL, iproute2 and setpriv:

```bash
unshare --net --fork python3 Data/tests/publications-proxy-linux.py --port 443
unshare --net --fork python3 Data/tests/publications-proxy-linux.py --port 18443
# exits 3 without changes when the host has no qbittorrent-nox package
```

This refuses the host network namespace and uses a temporary profile and local
test certificate (no ACME or trust-store change). The generated Caddy route is
real: native login/cookies, API access, incorrect password, CSRF, overwritten
forwarded Host, strict SNI/Host and Panel isolation are tested on both ports.
Host omits the public port for native listener validation; X-Forwarded-Host
keeps the external authority for CSRF. This does not certify public DNS/ACME.
`firewall-linux.py` additionally tests qBittorrent-only and shared DAV HTTPS
permissions, one shared port rule, and stopped/unsafe-native-auth closure.

## Public WebDAV HTTPS (v2-161, DD-190)

From the repository root, run the local tests without a live domain:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_https_*.py'
```

`test_https_settings.py` covers full-domain/DNS validation (exact assigned WAN
IPv4, no AAAA/proxy), pinned chain/hostname verification, durable commit,
failure/crash rollback, explicit off without HTTP downgrade, retained renewal
listener after last-share pause, preserved accounts/local domain and legacy
HTTP consent. `test_https_panel.py` covers status/expiry warnings at 14 days or
less, unknown/error handling, selected firewall ports, Caddy scheme/source
parsing and the existing gated Settings API. These are fixtures, not real
Let's Encrypt issuance or public-reachability tests.

The browser side (the WebDAV row and its HTTPS name in Erişim → Adresler, the shares' transports in
Paylaşımlar) is `yeni-erisim-ui.cjs` and `yeni-paylasim-ui.cjs`.

External acceptance is opt-in, from an authorized Tailscale client to a disposable
host. Supply a real public domain whose DNS resolves only to that host's assigned
WAN IPv4, with no AAAA/proxy, and permit inbound TCP 443. Konsol's pinned local
certificate probe does not itself prove that external path. From the repository root:

```bash
# Requires the matching domain already saved and certificate status ready:
python3 Data/tests/https-live.py --host nrm --domain dav.example.com
# Alternatively, deliberately save the real domain through the settings API first:
python3 Data/tests/https-live.py --host nrm --domain dav.example.com --configure
```

Replace the example domain; the script uses public TCP 443. `--configure` is a
real, persistent settings change: **the domain remains saved after cleanup**.
Without that flag, the script requires the matching saved domain to be ready (the shares' WAN
mode and domain from `paylasim`, the certificate state from the WebDAV row of `yayinlar`).
It verifies public TLS trust, denies `/` and administrative routes, checks old
WAN HTTP closed, and creates three temporary shares: RO and RW on both networks,
plus Tailscale-only. It exercises HTTPS/Tailscale reads, PROPFIND, ranges, download
integrity, RO rejection, WAN scope, PUT/MOVE/DELETE and both connections off.
Cleanup removes only its accounts/files and checks the original registry digest;
credentials stay in memory/SSH stdin and are not printed. Account creation,
connection changes and removal restart
WebDAV and interrupts current transfers: run outside active playback and do not
edit real shares concurrently. Domain disable/re-enable, reboot, supported-OS
fresh installs and native-client acceptance are separate tests.

This runbook describes test scope, not completed results. Record actual runs in
`CHANGELOG.md` and the change's DD entry (its live check).

## Remaining audit stages (v2-160, DD-187–189)

`test_install_hardening.py` checks descriptor-based selective permission repair,
unsafe parents, replacement races, hard links, special files and excluded trees.
`install-hardening-linux.py` adds real root ownership and competing/inherited
flock tests; run as root in a temporary test tree, never by sourcing install.sh.
`firewall-linux.py` adds cold malformed-registry rescue, valid-policy/manual-deny
preservation, secondary-interface default drop and successful recovery in isolated
network namespaces. It does not alter the host's policy.

`test_stage3_webdav.py` covers separate auth pools, short waits/cache rechecks,
single-flight sharing of identical concurrent logins and its failed/slow-leader
fallbacks (DD-193), 503 versus credential 429, bounded overload replies, slow PUT/COPY independence,
late target/source/parent/share/expiry/precondition conflicts and stage cleanup.
`test_stage3_files.py` covers deep JSON and socket inactivity; share-path tests
distinguish incomplete/internal roots from existing-share overlap.
`test_stage4_dns_json.py` covers `/4` projection and explicit IPv6 records plus
controlled deep HTTP/worker JSON. `test_stage4_health.py` tests required/inactive
and deliberately stopped units, unknown probes and kernel boot-link evidence.

Live acceptance must additionally validate Caddy/dnsmasq/systemd, cgroup OOM
events under WAN/Tailscale transfers, real A/AAAA replies and health before/after
reboot. Synthetic clients do not certify native Infuse or a fresh Ubuntu image.

## Backend admission and filesystem guards (v2-159, DD-186)

`test_backend_hardening.py` opens 24 real sockets per server before starting
the accept loop, isolating the listen backlog from HTTP processing limits.
Temporary fixtures exercise both qBittorrent readers against FIFOs (with a
subprocess deadline), final/parent symlinks, directories and oversized files.
Files tests cover reserved sources, all-selection validation before mutation,
reserved destination promotion, safe restore and ordinary file operations.
Run this suite on Linux too; no host configuration or credentials are used.
The backlog test is not a throughput benchmark or a substitute for cold-cache
Infuse concurrency tests. Existing WAN budgets are intentionally unchanged.

`backend-hardening-live.py --host nrm` runs 100 requests per API with 20
parallel fresh client connections and 120 direct cold Unix-socket requests.
It then creates a disposable RO WAN+Tailscale share, reads two 256 MiB files
with SHA256 verification, samples cgroup `anon`/`file`/`current`/`peak`, and
checks parallel PROPFIND and ranges on each network. Only the test files'
clean cache pages are evicted before reading, not the host cache. Cleanup
removes the temporary account/files and compares the original registry digest.
This restarts WebDAV twice; use an authorized test host outside active playback.
The measured cache increase does not prove the cause of a historical peak.
The WAN half follows the host's mode (DD-193): HTTPS on the configured public
name, or legacy HTTP on `SHARE_PORT`; a host with WAN off is refused up front.

## Folder network selection and WAN admission (v2-153, DD-179)

`test_share_manager_networks.py` covers opt-in, immutable
credentials/identity/expiry on network edits, public projection, rollback and
interrupted-change recovery. `test_webdav_networks.py` checks scope before
hash/filesystem work, header spoofing, sliding failure windows, bounded tables,
parallel hashes/requests, distinct loopback pools, timeout/abort cleanup and
expect-continue/pipeline behavior. Run on Linux as well: macOS skips the test
that binds the same port on a second loopback address. `share-networks.bats`
checks deployment wiring and conditional firewall/edge limits.

With explicit disposable-host authorization, run from an external client against
legacy HTTP WAN mode (no HTTPS setting; use `https-live.py` for HTTPS). On any
other host it prints `SKIP` and exits 3 before creating anything (DD-193):

```bash
python3 Data/tests/share-networks-live.py --host nrm
```

Only temporary folders/accounts are published, with random credentials kept in
memory/SSH stdin. The test exercises actual WAN and Tailscale Caddy endpoints,
cross-scope refusal, GET/PROPFIND/ranges, RO/RW, forged Host/client-IP, idle TCP
admission, simultaneous-request/login caps, tailnet availability, last-share
pause and timed expiry. WAN ingress packet counters confirm external routing.
Cleanup removes only the fixture prefix/accounts, never existing shares.
Fresh supported-OS installation, reboot and native Infuse/Finder acceptance are
separate; protocol tests do not certify every DAV client.

## Resources (DD-160, v2-131)

`test_resources.py` covers independent sampling, guest CPU accounting, unknown
measurements and real HTTP Host/header/origin gates.

## qBittorrent integration-only seed (DD-178, v2-152)

Bats requires an exact six-key seed allowlist (startup notice, two download-path compatibility keys
and three authenticated WebUI keys; DD-218's chosen defaults were reverted by DD-219). The module
fixture renders that real seed; reapply and remove/reinstall must preserve user
UPnP/discovery/temporary-path choices byte-for-byte and never apply the firewall.

On an authorized Linux test host with Podman and the package's image present (set
`TORRENT_TEST_IMAGE` to the digest the host runs when it differs from `torrent.env`):

```bash
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/torrent-defaults-linux.py
```

This refuses the host network namespace, runs the package image (`--network host` of the private
namespace, never the server's, no pull) as uid 1000 in disposable profiles, and compares the actual
seed against the same qBittorrent's defaults: no user preference is forced (UPnP, LSD, encryption,
anonymous mode, queue, temporary folder, preallocation and the rest stay native). It checks local
authentication (qBittorrent 5.2 answers a good login with an empty 204),
the download location and restart persistence of user choices (UPnP, LSD, a temporary folder, the
active-download limit). No torrents are added, no installed config
is read, no host service is controlled, and fixture passwords are never printed.
It does not replace clean Debian/Ubuntu installation or service-sandbox tests.

## The old `.pay` tree (DD-171, retired by DD-269)

The Bats suite checks that stage 3 never creates `.pay`, that stage 0 refuses to install beside an
existing one (a folder or a link) before the confirmation, that nothing in the tree names
`SHARE_DIR` any more, that registry preparation is idempotent and public lifecycle actions refuse.
`test_backend_hardening.py` checks the name is an ordinary folder in Files. Folder-sharing tests are
described below.

## Built-in ZIP/RAR (DD-159, DD-166, DD-170; removed in DD-267)

DD-267 removed Konsol's archive jobs (archives are Gezgin's): `test_archives.py`, `test_rar.py` and
`archives-live.py` are gone. `common.bats` checks that stage 1 adds no RAR repository and installs
neither `unrar` nor `python3-rarfile`, removes only the installer's own source file, and that stage 7
removes the old `SERVER_ROOT/.arsiv` only while it is a real 0700 folder of the downloads uid;
`test_backend_hardening.py` checks the name is an ordinary folder for the files backend now.

From the repository root, run all Python suites with an OpenSSL-enabled Python:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_*.py'
```

## Settings management (DD-156/DD-157, v2-127)

WireGuard internet-only (DD-177): `yeni-wireguard-ui.cjs` tests creation and settings through
`/api/uygulama/wireguard/*` (no Local selector, DNS-only saves, the name), polling, the stopped
network and explicit regeneration. `test_wg_settings.py` drives the package's
API module through the root backend's dispatcher: it rejects a supplied `scope`
field on both routes, checks revision/gates, the `master-wg` argument lines and
the `wireguard:<verb>` audit prefix; `test_resources.py` covers the module listing's
`konsol` field (no `sayfa` since DD-267) and the API module's load/unload with the registry. Bats
verifies DNS-only preservation and rejects access-scope CLI arguments.
`firewall-linux.py` tests actual IPv4/IPv6 host deny (including prior flows),
internet forwarding/NAT, private destinations through WAN, and tailnet isolation.
Veth fixtures pin WG IPv6 neighbors because real WireGuard uses no NDP.

Firewall categories (DD-164, v2-134): `test_firewall_view.py` covers read-only
socket scope classification, IPv6 normalization/zones, read failures, public-only
network metadata, service-name reuse and WAN endpoint versus tunnel permissions.
`yeni-erisim-ui.cjs` tests Erişim → Güvenlik duvarı's network tabs, IPv6, locked rows, drafts and
the listeners.

Minimum tailnet exposure (DD-172, v2-146): `test_tailnet.py` verifies configured
service ports, validated Self-only PeerAPI discovery and daemon-startup fallback.
The view suite also rejects listener-implies-access and preserves WG endpoints.
Run `unshare --net --fork python3 Data/tests/firewall-linux.py` as root on the
authorized Linux test host. It refuses the host namespace and uses nested veth
clients/echo listeners to test actual IPv4/IPv6 WAN, tailnet and WG input packets,
operator allow/deny precedence, idempotency and extra-rule detection. No installed
service, account or host firewall is modified; all fixtures are temporary.

Tailnet catalogue cleanup (DD-173, v2-147): the view tests exclude arbitrary
peer/backend/admin sockets, retain configured per-family ports even without
listeners, and keep registered WG endpoints with no active peers/sockets.
The browser side (Erişim → Güvenlik duvarı: rule drafts, the port-rule sheet and the plan) is
`yeni-erisim-ui.cjs`.
Live checks must also verify raw diagnostics and required local services remain.

WAN/tunnel catalogue cleanup (DD-174, v2-148): view tests cover configured SSH/
Tailscale ports and IPv4-only WAN WG endpoints independent
of sockets/peer count; retired tunnel permits stay absent. The browser side is
`yeni-erisim-ui.cjs` (above).

Firewall source cleanup (DD-175, v2-149): `firewall-linux.py` additionally starts
from absent module/network files, then verifies preserved networks cannot revive
an absent/empty/stopped module. Test teardown/re-add, no empty forwarding/NAT
chains, repeatability of both tables/families, stale extra INPUT/FORWARD/NAT rules,
unchanged third-party jumps/chains and retained network files. The view suite
covers single-port WG rules and intentionally absent chains versus real failures.
These are isolated policy fixtures, not a fresh Debian/Ubuntu image installation.

DNS-only Apply (DD-163, v2-133): unit tests cover immediate persistence past
the old deadline/reboot, pre-write panel-name protection, mixed confirmation,
restart/commit failure rollback, pre/post-commit crashes and recovery retries.
In the browser (`yeni-erisim-ui.cjs`) the DNS draft goes through its plan ("Hemen kaydedilir; onay
beklenmez."), one apply sends the planned body unchanged, and a refused plan can be asked again. The isolated Linux
DNS test checks immediate commit and failed-apply recovery with real dnsmasq.

Firewall tables (DD-162, v2-132): the browser side is `yeni-erisim-ui.cjs` (above).

Folder sharing (v2-128, DD-158): also run `python3 -m unittest discover -s
Data/tests -p test_shares.py` and `node Data/tests/yeni-paylasim-ui.cjs` from the repository
root. Python must have OpenSSL scrypt (the macOS system Python may not; use an
OpenSSL-enabled Python 3.12+). Linux distribution Python is the production runtime.
`yeni-paylasim-ui.cjs` checks each address with its copy button and Infuse's fields; copy APIs are
intercepted, so native iPhone clipboard behaviour is not covered.
Inline Shares and compact trash (v2-142, DD-169): `yeni-paylasim-ui.cjs` checks the partial
payloads, the RW question, refusals, controls disabled while a change is under way and
account-only editing; `yeni-dosyalar-ui.cjs` the trash. Permanent-delete guards remain tested. `test_shares.py` covers omitted-field preservation, required RW
acknowledgement, rollback and never rebinding a replaced folder via inline edits.
Password policy (v2-141, DD-168): the settings/shares Python and browser suites
reject seven-character passwords and accept eight, preserving blank edits.
`test_shares.py` also verifies real WebDAV GET/PROPFIND authentication and the
read-only write boundary with eight characters. `settings-linux.py` verifies
native qBittorrent login and restart persistence with a disposable eight-character
account inside its private network namespace; it never changes installed accounts.
`shares-live.py prepare` is a **mutating disposable-host test**, using installed
services, two scratch accounts and a random folder. Keep its printed manifest
path for `verify <manifest>` after rerun/reboot and `cleanup <manifest>` afterward.
It does not certify Finder/Infuse clients or Tailscale recipient ACLs.

From the repository root:

```bash
LC_ALL=C PYTHONDONTWRITEBYTECODE=1 bats Data/tests/common.bats
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p test_settings.py
```

On the operator Mac (2026-09-30) Node comes from Homebrew and Playwright is a
global npm package outside the repository, so point the suites at it:

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-ui.cjs
```

`giris-ui.cjs` uses a preview on port 8766 (see Konsol sign-in); the `yeni-*` suites start their own
servers. The health card is `yeni-sistem-ui.cjs`'s and the stuck-rollback discard `yeni-erisim-ui.cjs`'s
(DD-182).

`PLAYWRIGHT_MODULE`, `PLAYWRIGHT_CHROMIUM` and `KONSOL_URL` may override the
module, browser executable and preview URL. The suites intercept APIs with
fixtures and never modify a server; the settings views (rules, DNS, the plan,
confirmation/rollback, the domain with its new-address links and the old-host
refusal) are `yeni-erisim-ui.cjs`'s. Screenshots go to a fresh temporary directory.

On a Linux test host with root, iptables/ip6tables, dnsmasq, dig, qBittorrent
and systemd (no additional packages are installed by these tests):

```bash
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/settings-linux.py
PYTHONDONTWRITEBYTECODE=1 python3 Data/tests/settings-systemd.py
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/settings-domain-linux.py
```

The first refuses the host network namespace, uses scratch profiles and
dummy interfaces, and substitutes only service control; firewall, DNS and
qBittorrent are real. The package worker's account and folder functions (DD-202)
verify real new/old login results, restart persistence, failed-restart recovery,
the save path with its drop-in, and stopped-state preservation.
A local upstream fixture verifies forwarding without
internet access and proves private names are not forwarded. The second uses
real transient systemd work/timer units with a scratch pending record and no
firewall/DNS/qBittorrent changes. Both remove only their own scratch state.
These checks do not replace a fresh Debian/Ubuntu installer acceptance run.

`settings-domain-linux.py` needs Caddy, dnsmasq, dig, curl, setpriv and Python,
but not qBittorrent. It starts the real Caddy and both production API backends
against scratch files, with private DNS/network interfaces. It checks domain
apply/rollback/confirm, real Caddy reload, both Host/header gates, no `health.`
name or site, persisted domain and staged templates. Only systemctl is adapted to
those processes; host services and their settings are never touched. Unit tests
also cover timeout/reboot/crash recovery, state IP preservation, invalid suffixes,
stale renderings, inactive services and installer saved-domain readback.

## Acceptance-check lessons (2026-09-11)

- `tailscale status --json .Self.ExitNodeOption` is **not** an installer
  assertion. It turns true only after the exit node is approved in the admin
  console — the manual step the install summary lists. The installer's own
  obligation is `AdvertiseRoutes` containing `0.0.0.0/0` in
  `tailscale debug prefs`; assert that, and report `ExitNodeOption` as
  information.

## Pitfall: an early-exiting pipe consumer under `pipefail` (2026-09-12)

`install.sh` runs with `set -Eeuo pipefail`. A read-back written as
`apt-config dump | awk '/pattern/{print $2; exit}'` looked harmless and
passed every static check, but on the host it aborted the install with exit
141 after all seven stages had run: `awk` exits on the first match,
`apt-config` gets SIGPIPE writing the rest, `pipefail` turns that into 141,
and `set -e` exits at the assignment. Let the consumer read the whole stream
(`{v=$2} END{print v}`) or guard the pipeline with `|| true`, as the `dig |
head -n1 || true` read-backs do. A bats test now rejects `| awk … exit`
patterns in the installer tree.

## Pitfall: a second `tailscaled` on a provisioned host (2026-09-13)

`tailscaled --statedir=DIR` does not isolate a test daemon. `--state` has a
compiled default of `/var/lib/tailscale/tailscaled.state`, so the daemon
loads the production node's identity and preferences. On `nrm` such a daemon
came up `Running` as the production node for a few seconds and rewrote
`/etc/resolv.conf`; the production daemon restored it within the same second
(`trample: resolv.conf again matches expected content`). The state file,
login and prefs were unaffected, and a `BackendState == NeedsLogin` gate
stopped the test before `tailscale up`.

Run test daemons inside a container with the binaries bind-mounted
read-only, pass `--state` explicitly, and gate on `NeedsLogin` before any
`up`.

## Konsol update button (v2-212, DD-233)

`test_update.py` covers the GitHub check (tip commit, version at that commit, cache, failure
back-off, forced-check gap, malformed answers), the job state/stage, the start rules, the pinned
`systemd-run` call and the Tailscale-only start route. `common.bats` runs `kur.sh` in update mode
(pinned commit, refused version mismatch, no terminal) and `master-guncelle` with local fixtures.
`yeni-sistem-ui.cjs` checks Sistem → Güncellemeler (the confirmation, the stage, a failure, the reload,
the internet lock) with fixtured APIs.

Another generation (v2-260, DD-277): `test_update.py` reads `OBHUT_NESIL` from the offered commit's
`install.sh` (absent or `"1"` offered as before; `"2"` reported as `yeni_nesil` with the notice, never
offered, the start refused with the same text, even when its build number is not `v2-<n>`; malformed lines
count as absent) and runs `master-guncelle` with a fake `id` and `file://` downloads (`KUR_KURULUM_URL`,
`KUR_BETIK_URL`): a target of another generation, any `OBHUT_NESIL=` line that is not exactly `"1"`, or an
unreadable `install.sh` stops before `kur.sh` runs and is recorded as the failure. The root-only Bats test
checks the same. `test_obhut.py` checks `sudo obhut durum|guncelle` with the notice, `yeni-sistem-ui.cjs`
the notice instead of "Güncelle" at 1440/390/320 (light, and dark at 390) with the layout audit, and
`yeni-uygulamalar-ui.cjs` "yeni nesil çıktı" beside the version on Genel Bakış and in the sidebar.

## New interface phase 4b: Paylaşımlar and the old addresses (DD-258, DD-267)

`yeni-paylasim-ui.cjs` (`KONSOL_URL`, default `http://127.0.0.1:8776`) drives Dosyalar → Paylaşımlar
(`#/dosyalar?sekme=paylasimlar`) through `yeni-harness.cjs`, with every request body compared exactly.
The page: the boundary notice with its detail in the address (`?sinir=1`, plain HTTP named only while the
internet connection is HTTP), the service-stopped and not-installed warnings, n/max and the limit, the
transports (Tailscale, plain HTTP with address and port, an HTTPS name, closed with the server's reason)
and the way to Erişim's WebDAV publication; one card per share (state, folder under the user area, the
account with copy) with its two connections: state, reason, switch, permission, duration with the expiry
and renewal from today, the address with copy and Infuse's host, port and path. The bodies: `{enabled}`,
`{permission: "rw", ack_write: true}` only after the question, `{permission: "ro"}` at once, `{days}`
(the current "Süresiz" again sends nothing), `ack_wan_http` only when the internet goes on over plain
HTTP (declining sends nothing; over HTTPS there is no question); a refusal in the server's words on its
card with a fresh read; every control off while a change is under way; removal with the typed word, a
refusal kept in the question, the card gone and focus on the heading. The create sheet (`?yeni=<folder>`):
the rules before any request, the folder chooser over the user area (`GET /api/list?path=&dirs=1`, hidden
folders left out, shared ones marked, Esc closing only the panel, the chosen folder in the address), the
user name (pattern, taken in any case), the password (length, `:`, show/hide, a 40-digit generated one,
copy), both connections' drafts with their acknowledgements, the whole body, a refusal keeping the form,
an empty form after closing, an already shared folder offering its share. The edit sheet
(`?paylasim=<id>`): only changed fields (`username`; `path` with `password`), nothing to save until
something changes, removal from the sheet. Deep links: a folder, an already shared folder opening its
share, an unknown share, a hidden folder refused. Erişim's WebDAV rows (Genel and Adresler) and the
built-in Paylaşımlar (Aç, Ayarlar) lead here; the palette has no "Eski arayüz" group. The old Konsol's
addresses (32 of them: App Store and its packages, the Podman page and its containers, Settings' tabs,
Files' folders, trash and shares, WireGuard, a package's own page, unknown ones) land on their new homes on
a fresh load and inside a running page; without the application list an application address gives up
after six seconds. Those new homes' own reads answer 404 there (their suites drive them), and each page is
closed only once its reads have ended, so no intercepted read reaches the static server. 1440/390/320 px
in both themes: no style attribute, no horizontal scroll, the connections side by side or stacked, the
sheet at the bottom on a phone.

`yeni-ui.cjs` and `yeni-uygulamalar-ui.cjs` changed only where phase 4b meant them to: the palette has no
group for the old interface (the trash is Dosyalar' tab, the last entry is an action), an old address
replaces the legacy links, and a built-in opens its section in this interface (`#/dosyalar?sekme=paylasimlar`).

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-paylasim-ui.cjs
```

## Phase 5: the installable app and `obhut` (DD-268)

`yeni-ui.cjs` reads the app manifest through Chrome's own parser (`Page.getAppManifest`: no error under
the production CSP with `manifest-src 'self'`), checks its name, start URL, scope, display and the 192/512
px icons (any and maskable) answering with their types, and that no service worker controls the page.
`test_obhut.py` drives each `obhut` command against a fake backend (the exact requests, what it prints,
the refusals, the update only when the backend says newer, root only) and the socket client against the
real backend on a Unix socket as its local caller. Bats checks the manifest and its icons in the build,
the CSP, the open paths before a session, and where `obhut` is installed and how it reaches the backend.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_obhut.py'
```
