# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### 2026-10-02 — qBittorrent page and settings in its package, phase 2c (v2-176)

- The qBittorrent page is the package's `sayfa.js`/`sayfa.css`; its account and
  download-folder form posts to the package API `/api/uygulama/torrent/{hesap,dizin}`
  and reads `…/durum` (DD-202). Changes apply directly through the package worker
  `ayar.py` (stop, snapshot, write, start; a failure restores both files and restarts);
  the folder change no longer has a 60 s confirmation window.
- Settings has no qBittorrent tab and no `torrent` section; `GET /api/konsol/ayarlar`
  carries no `torrent` key and no account/folder fields. The shell, `ayarlar.js` and
  the root backend contain no qBittorrent code.
- Backend: `PackageContext.worker()` runs a package script that lives under the
  package's own folder as a transient root unit with JSON on stdin, the same private
  path as the base settings and share workers.
- The torrent package's hooks place the page files on install and re-run and remove
  them on rollback (the first live run showed only WireGuard's hooks did).
- Fresh install only; an in-place host receives the new package files on the next
  installer run.
- **Verified:** Mac — 408 Python, 169 Bats, browser suites `torrent-ui` (new),
  `panel-ui`, `settings-ui`, `files-ui`, `publications-ui`, `settings-https-ui`,
  `wireguard-ui`, `giris-ui`. nrm — portable run with scratch inputs on the in-place
  host (exit 0, no warnings; three runs, the first two surfaced the hook and `--lib`
  fixes); live acceptance: package files rendered, the page under
  `CONSOLE_WEB_DIR/uygulama/torrent` (0644 root) and served by Caddy, the module listing
  offers it, `GET /api/konsol/ayarlar` has no `torrent` key, `/api/uygulama/torrent/durum`
  answers 401 without a session and the paths without any hash, bad shapes answer 400
  before the worker, the folder policy refusal comes from the worker, a username change
  and its restore went through the worker (service restarted, profile 0640 uid 1000,
  password hash untouched, audit lines), a folder change to `/srv/media` and back wrote
  the `90-konsol.conf` drop-in and qBittorrent's default save path. Linux (nrm) — 408
  Python, 169 Bats, firewall, settings (package worker block), settings-domain,
  torrent-defaults, publications-proxy and install-hardening suites.

### 2026-10-02 — Neutral backend, package-owned settings, self-checking packages, phase 2b (v2-175)

- The root backend is `master-panel` on `PANEL_SOCKET` (`/run/master-panel/api.sock`);
  `master-wg-panel`, `WG_PANEL_SOCKET` and `WG_PANEL_RUNTIME` are gone (DD-201).
- WireGuard's settings moved into its package: `magaza/wireguard/wireguard.env` holds
  every `WG_*` default and path; `master-wg`, the hooks, the Konsol API module and the
  Mac launcher read it there. `defaults.env`/`state.env` carry no `WG_*` key; the VPN
  endpoint is `WAN_IPV4`; the firewall's destination block lists are `VPN_BLOCK_DEST4/6`.
- Stage 7 asks each installed package to check itself (`paket_denetle`) and verifies
  that absent packages left no tool or drop-in; the re-run prune and the summary note
  (`paket_not`) and counts (`paket_ozet`) come from the manifests and hooks.
- `master-wg net-add` reserves the ports every package manifest declares instead of
  naming qBittorrent, Files and WebDAV; the launcher's intro line names App Store.
- Fresh install only, as the whole store model: a host updated in place keeps the
  old `master-wg-panel.service` running beside the new one until the operator
  runs `systemctl disable --now master-wg-panel.service`, removes
  `/etc/systemd/system/master-wg-panel.service` and `/usr/local/sbin/master-wg-panel`
  and reloads systemd (done by hand on nrm).
- **Verified:** Mac — 403 Python, 169 Bats (browser suites unchanged by this phase).
  nrm — portable run with scratch inputs (exit 0, no warnings) on the in-place host;
  live acceptance: `master-panel` active on `/run/master-panel/api.sock`
  (`root:caddy 0660`), no `WG_*` key in `state.env`, `VPN_BLOCK_DEST4/6` present,
  the package env rendered; `master-wg net-add` refused 61006/61010/61009 naming
  `torrent`/`paylasim`/`dosya` from their manifests; the API state's endpoint and a
  masked profile's `Endpoint` carried `WAN_IPV4`, defaults came from `wireguard.env`,
  `master-firewall --check` passed and the journal lines sat under `master-panel`;
  a second installer run with wg0 and one peer installed passed the package's
  `paket_denetle`, and the summary printed "WireGuard: kurulu — 1 ağ, 1 peer" with
  the package's note; the network and the package were then removed (`--veri`),
  leaving the registry, `/etc/wireguard` and the console folder clean. Linux (nrm) —
  403 Python, 169 Bats, firewall, settings, settings-domain, torrent-defaults,
  publications-proxy and install-hardening suites.

### 2026-10-02 — Konsol pages and application API from packages, phase 2a (v2-174)

- The Konsol shell and the root backend no longer know WireGuard (DD-200). A
  package declares `PAKET_KONSOL` (App Store texts, page declaration and journal
  words in `konsol.json`, rendered by the installer), `PAKET_SAYFA` (its page files,
  placed under `CONSOLE_WEB_DIR/uygulama/<id>/` on install and removed with the
  package) and `PAKET_API` (a Python module the root backend loads from the
  package folder while the package is registered and serves at
  `/api/uygulama/<id>/*` behind the existing gates). WireGuard's page, stylesheet
  and API moved into `magaza/wireguard/`; qBittorrent's App Store texts into
  `magaza/torrent/konsol.json`.
- Konsol builds the "Kurulu uygulamalar" links and sections from the package
  declarations, loads an installed package's page on demand, unmounts it on
  removal and labels journal lines of package APIs (`<id>:<verb>`) with the
  package's own words. `/api/wg/*` is gone; the audit list is
  `/api/konsol/islemler`; Settings → Güvenlik Duvarı names its VPN category after
  the installed package (`vpn_installed`, `vpn_name`).
- Backend unit: no `--master-wg` argument and no WireGuard environment lines;
  `WG_CLIENT_DNS_DEFAULT`/`WG_CLIENT_KEEPALIVE_DEFAULT` are written to `state.env`.
  Stage 7 probes the package-neutral resources endpoint only.
- Found live and fixed before release: the installer did not write
  `CONSOLE_WEB_DIR` to `state.env` (the engine needs it for the page files), and the
  WireGuard hook placed the page after the registry line, so a failed step could
  leave a half-registered package; the page now goes in before the registry, and
  the last package's empty `uygulama/` folder is removed with it. The Linux lock
  tests (`install-hardening-linux.py`) gained the real torrent manifest; their
  fixture had carried no catalogue since the engine became manifest-driven.
- **Verified:** Mac — 403 Python, 169 Bats, all fixture browser suites
  (wireguard-ui, panel-ui, files-ui, settings-ui, settings-https-ui,
  publications-ui, giris-ui). Linux (nrm) — 403 Python, 169 Bats, firewall,
  settings, settings-domain, torrent-defaults, publications-proxy and
  install-hardening suites. nrm — portable run with scratch inputs (exit 0, no
  warnings); live acceptance through Caddy with a root-issued session: the module
  listing carries both packages' texts; without WireGuard its page file is 404
  (302 without a session) and its API 404/409; `kur` placed `sayfa.js`/`sayfa.css`
  (0644 root) and Caddy served them behind the session; network, peer, masked
  profile, QR, peer switch and DNS settings worked through
  `/api/uygulama/wireguard/*`; `master-firewall --check` passed; the journal
  carried `wireguard:<verb>` lines; Settings showed the VPN category, networks
  and port rows from the package; `kaldir --veri` removed the page, the API and
  the VPN category with the firewall check still clean.

### 2026-10-01 — Publication rows from package declarations, phase 1b (v2-173)

- Settings → Caddy no longer names qBittorrent (DD-199). A package publishes by
  declaring a row name, a local name, a loopback upstream and an optional check
  module in its manifest; `master_publications` builds rows, private stubs,
  public sites and status messages from that, loads the check module from the
  package folder and closes the row when the module is missing, broken or
  failing. A declaration without a loopback upstream produces no row.
- qBittorrent's native-login checks moved verbatim into `magaza/torrent/yayin.py`.
  The settings worker, share publisher, firewall helper and Konsol module
  listing use the generic package functions; the WebDAV and Konsol rows stay
  fixed. The manifest reader is shared by the backend and the publication module.
- **Verified:** Mac — 400 Python, 169 Bats, settings browser suites. Linux (nrm) —
  400 Python, both qBittorrent proxy suites (real Caddy and qBittorrent against
  the package's manifest and check module), firewall and domain suites. nrm —
  portable run with scratch inputs (exit 0, no warnings); the rendered package
  folder carries the manifest with its filled upstream and the check module,
  the table lists Panel, qBittorrent and WebDAV from the package catalogue, and
  turning the qBittorrent row on through the real API ran the package's checks,
  obtained the certificate and reached the module listing's public address; the
  row was then restored to its previous off state.

### 2026-10-01 — Firewall, health and ports from package declarations, phase 1b (v2-172)

- `master-firewall` no longer knows WireGuard (DD-198). Installed packages
  declare their needs through a `paket_firewall` hook in a one-word vocabulary
  (`vpn IFACE UDP_PORT NET4 NET6`); the firewall validates every line, keeps
  interfaces and ports unique, writes and checks the rules itself, and a
  malformed or unknown line changes nothing, as a corrupt registry did before.
- The health card asks `master-modul saglik` which units installed packages
  require; WireGuard's networks and qBittorrent's unit come from their hooks.
- Settings → Güvenlik Duvarı port rows for qBittorrent, WebDAV and the Files
  backend come from `PAKET_PORTLAR` in the manifests; the built-in Files got a
  manifest. Base rows are only Tailscale, SSH, Caddy and dnsmasq.
- **Verified:** Mac — 400 Python, 169 Bats, ShellCheck. Linux (nrm) — 400
  Python, firewall, settings and domain suites. nrm — portable run with scratch
  inputs (exit 0, no warnings); then on the real host: `master-firewall --check`
  clean, `master-modul saglik` names qBittorrent's unit, a WireGuard install plus
  `net-add` produced the UDP permit, 13 forward rules, NAT and the tailnet permit
  from the package's declaration with the check clean, a corrupt registry line
  made the firewall refuse without changing a rule, and `kaldir --veri` removed
  every rule again. Settings → Güvenlik Duvarı shows the manifest-declared port
  rows and the health card reads the package units.

### 2026-10-01 — Store engine and package format, phase 1a (v2-171)

- `master-modul` is now a package engine that knows no application (DD-197).
  Each package under `magaza/<id>/` carries a manifest (`paket.env`) and a hook
  file (`kanca`); the catalogue, runtime, start/stop and account capabilities,
  apt packages, tools, unit drop-ins, names and log units come from the
  manifest. The engine places and removes the declared artifacts itself and
  refuses to finish a removal that left any of them behind.
- The installer renders every package folder generically: files with `__KEY__`
  placeholders are filled from its own variables, executables keep 0755, and a
  package is re-applied when a file changed or its manifest says always. The
  summary takes names and info lines from the packages.
- WireGuard and qBittorrent lifecycles moved verbatim into their hooks; the
  built-in WebDAV got a manifest marked built-in. Commands, locks, progress and
  `liste` output are unchanged for Konsol.
- **Verified:** Mac — 400 Python, 169 Bats (fixtures now run the real engine
  against the real hooks), ShellCheck. Linux (nrm) — 400 Python, 169 Bats. nrm —
  portable run with scratch inputs (exit 0, no warnings): every package folder
  carries its manifest and hooks, qBittorrent was re-applied and kept running
  with its name and login state, and a real `kur wireguard`, `master-wg net-add`,
  `kaldir --veri` cycle left no tool, drop-in, modules-load file, key, registry
  row or interface behind, with the firewall check clean.

### 2026-10-01 — Store model, phase 0: the base owns no WireGuard (v2-170)

- Konsol → Ayarlar → Günlük labelled every root-backend event "WireGuard", so
  failed sign-ins and settings saves looked like WireGuard errors. Events are
  now labelled Konsol, Ayarlar, Paylaşımlar, Dosyalar, Uygulamalar or WireGuard
  by their real source, sign-in/settings/share events have their own words, and
  filter chips appear only for kinds present (DD-196).
- The repo folder `modules/` is now `magaza/`, and the WireGuard tool and
  `wg-quick@` drop-in live in `magaza/wireguard/`. The installer renders them
  into the package folder only; App Store install places them, removal takes
  them away, and a re-run removes leftovers when the package is absent. Stage 7
  requires the tool only with the package and its absence without it.
- The root backend's unit is "Konsol root backend"; the installer probes it
  through `/api/konsol/kaynaklar`; Caddy starts without `--environ`, so
  `state.env` is no longer dumped into the journal; the five-minute tailnet
  timer and the module log route look at WireGuard only while it is installed;
  the install summary and confirmation screen mention WireGuard only as a
  package.
- Fixed (found by the live removal test): `master-modul kaldir wireguard` never
  closed the networks on a real host. `systemctl list-unit-files` exits 1 when
  nothing matches, which ended the shutdown listing before the registry was
  read, so `wg0` stayed up with its unit enabled while keys and registry were
  gone. Each source is now read independently; the Bats fixture's systemctl
  exits like the real one.
- **Verified:** Mac — 400 Python, 169 Bats, panel and settings browser suites,
  ShellCheck. Linux (nrm) — 400 Python, 169 Bats, firewall, domain, torrent
  defaults and install-hardening suites. nrm — the fresh v2-169 host re-run
  with scratch inputs (exit 0, no warnings, account kept): the re-run removed
  the tool and drop-in the older base had left, the backend unit is named
  generically, Caddy runs without `--environ`, and the journal since the
  install carries no WireGuard line from our units. Then `master-modul kur
  wireguard`, `master-wg net-add`, and `kaldir --veri` on the real host: unit
  inactive and disabled, `wg0` gone, tool, drop-in, keys, registry row, UDP
  rule and forward chain gone, firewall check clean.

### 2026-10-01 — HTTPS publications no longer depend on WebDAV's mode (v2-169)

- On a fresh install, publishing Panel (or qBittorrent) over HTTPS failed with
  "Önce WebDAV için HTTPS kaydedin veya eski HTTP WAN erişimini kapatın" although
  no folder was shared on the internet: WebDAV without a saved HTTPS name counts
  as legacy HTTP mode, and the DD-191 rule looked at that mode. The real limit is
  Caddy's single WAN port. The rule now checks the live listener: enabling an
  HTTPS publication is refused only while folders are actually shared over
  plaintext HTTP, with a message naming both ways out. While a qBittorrent or
  Panel internet row is on, legacy HTTP WebDAV internet access stays closed and
  the folder cards say that an HTTPS name is needed; saved folder connections are
  not changed.
- Settings → Caddy shows whether legacy HTTP is live (`wan_active` on the WebDAV
  row) and words its note accordingly.
- **Verified:** Mac — 400 Python, 168 Bats, browser suites (publications,
  HTTPS settings with both notes, files, settings). Linux (nrm) — 400 Python,
  168 Bats, firewall and domain suites; the qBittorrent proxy suite needs the
  qbittorrent-nox package, which the fresh host does not have, and now exits 3
  there. nrm — the user's fresh install re-run with scratch inputs (exit 0, no
  warnings, account kept); `panel-public-live.py` then published Panel on
  `panel.example.net` from exactly the refused state (WebDAV in legacy HTTP mode,
  nothing shared) and restored the row.

### 2026-10-01 — qBittorrent link follows the Konsol address (v2-168)

- Konsol opened on its public HTTPS address linked qBittorrent by its tailnet
  name, which the internet cannot reach. The module listing now carries both
  addresses (`urls.tailscale`, `urls.internet`); the qBittorrent page's "Web
  arayüzünü aç" button and the first-login card's address use the public name
  when Konsol itself is on HTTPS and the qBittorrent row in Settings → Caddy is
  on and verified. Otherwise the page says to turn that row on, with a link to
  Settings → Caddy (DD-195 amendment). The tailnet address is unchanged.
- **Verified:** Mac — 399 Python, 168 Bats, seven browser suites including a
  new `https://` origin scenario. Linux (nrm) — 399 Python, 168 Bats. nrm — one
  portable run with scratch inputs (exit 0); on the public Konsol address the
  module listing names `https://qbit.example.net` for qBittorrent and that name
  answers; the public sign-in page keeps HSTS and the session redirect.

### 2026-10-01 — Konsol over public HTTPS (v2-167)

- The Panel row in Settings → Caddy now has an internet switch and an HTTPS name
  like qBittorrent and WebDAV (DD-195). Its Tailscale switch stays on. Enabling
  it needs an existing Konsol account, a DNS-only A record and the typed word
  `onayla`; the dialog states that a public Konsol is full administration behind
  one password.
- Caddy keeps the Konsol routes in one `(konsol)` snippet. The tailnet site and
  the generated public site (`moduller/panel-wan.caddy`, TLS-ALPN, HSTS) both
  import it, so the session check, sign-in exceptions, CSP and backends are the
  same. Backends always see `Host: panel.<domain>`; Caddy alone writes
  `X-Konsol-Kanal`.
- The root backend accepts the public channel only while the publication is
  active and never from the server's own addresses. The one-time setup code is
  refused there; the session cookie is `Secure` over HTTPS. Twenty failed public
  sign-ins within ten minutes close public sign-in for fifteen minutes while
  Tailscale sign-in stays open. One password check per address, two at once.
- The public site shares TCP 443 and the WebDAV socket budgets; it stays open
  even with WebDAV's WAN off. The 30-second guard removes it after an account
  reset or a lost WAN address. Firewall and local-domain changes are still
  confirmed only over Tailscale.
- Review follow-ups before release: each Caddy site opens at most 16 backend
  connections and the unit raises the descriptor limit, so an internet flood
  cannot make the backend refuse Tailscale; the shared sign-in budget is checked
  again after waiting for a hash slot; the typed `onayla` is verified by the
  server; timed confirmations require the Tailscale channel (100.64/10 is also
  carrier NAT) and the domain check reads the browser's real name; the page
  explains legacy WebDAV HTTP before the dialog and warns when renaming from the
  public address.
- Fixed: the installer's confirmation screen still said Konsol had no password.
- New tests: Panel row and site in `test_publications.py`, public channel and
  budget in `test_konsol_auth.py`, snippet wiring in `common.bats`, the editable
  row in `publications-ui.cjs`, opt-in `panel-public-live.py`.
- **Verified:** Mac — 398 Python (4 platform skips), 168 Bats, seven browser
  fixture suites, ShellCheck, Bash/JavaScript syntax. Linux (nrm) — 398 Python
  (1 optional skip), 168 Bats, domain (real Caddy), firewall, settings,
  qBittorrent defaults, settings-systemd, install-hardening and both
  publication-proxy suites. The snippet, `{args[0]}`, `header_up` inside
  `forward_auth`, `max_conns_per_host` and a generated public Konsol site were
  validated with nrm's Caddy 2.11.4.
- **nrm:** two portable runs with scratch inputs, both exit 0 with no warnings;
  the operator's Konsol account and sessions survived. `publications-live` and
  `backend-hardening-live` pass; a spoofed `X-Konsol-Kanal` on the tailnet site
  is overwritten by Caddy. The public acceptance (`panel-public-live.py`) still
  needs a real DNS-only name for the panel and has not run yet.

### 2026-10-01 — Konsol sign-in with a one-time setup code (v2-166)

- Konsol asks for a user name and password again (DD-194). Every page, file and
  API request is checked by the root backend through Caddy's `forward_auth`; only
  the sign-in page and its API are open. A missing session goes to the sign-in
  page and returns to the same Konsol page afterwards.
- The first account is created on the sign-in page with a one-time code that the
  installer prints at the very end while no account exists (24 hours, single use,
  never written to `install.log`). The input file still holds no account.
- Sessions last seven days (HttpOnly, SameSite=Strict cookie). Settings → Sistem
  shows the account with a password change that ends every other session, and
  the sidebar has "Çıkış yap". Five failed attempts from one address within a
  minute block it for five minutes.
- Server command `sudo master-konsol sifirla` deletes the account and sessions
  and prints a new code; `durum` shows the state.
- Stage 7 now checks the open sign-in page, that host-local page requests are
  refused and that the session check answers 401/302; the Files self-check uses
  its loopback port. The Panel row in Settings → Caddy stays Tailscale-only.
- Live tests use a short root-issued session (`master-konsol oturum-ac`) for
  Konsol calls through Caddy; host-side tests use the loopback Files backend.
  New: `test_konsol_auth.py`, `giris-ui.cjs`, `konsol-login-live.py`.
- **Verified:** Mac — 391 Python (4 platform skips), 167 Bats (3 skips), seven
  browser fixture suites, ShellCheck, Bash/JavaScript syntax. Linux (nrm) — 391
  Python (1 optional skip), 167 Bats (1 skip), domain (real Caddy), firewall,
  settings, qBittorrent defaults, settings-systemd and install-hardening suites.
  The panel site with `forward_auth` was validated by nrm's Caddy before release.
- **nrm:** the first two portable runs stopped at stage 7 — master-modul still
  checked Files through Caddy, then the sign-in files were missing from the
  installed page list; both fixed (and a Bats guard now requires every console
  file to be installed). Third run with scratch inputs exit 0. The one-time code
  appears only at the end of the terminal output: not in `install.log`, not in
  the journal. Share registry, qBittorrent profile, WireGuard registry and
  qBittorrent PID unchanged. Live: `konsol-login-live.py` (open sign-in files;
  302/401 for every page, file and API without a session; code creates the
  account once; sign-in, password change ending other sessions, old password
  refused, sign-out; 429 after five failures), share-connections, publications,
  backend-hardening over HTTPS WAN and Tailscale (100/100 Konsol and Files
  requests at 20 parallel with a session; 256 MiB SHA-verified 52.9/57.3 MB/s) and
  the read-only installed-UI browser suite with a session all pass. The test
  account was removed; the host waits for the operator's own first account.
- `publications-live.py` once hit a transient settings lock while restoring and
  left public WebDAV off for a few minutes; it was restored at once, and the test
  now retries that answer and restores every row independently.

### 2026-10-01 — Cross-review fixes for v2-159..v2-164 (v2-165)

- Saving an internet publication in Settings → Caddy now fails at once with the
  real cause when its listener cannot open, instead of waiting a minute for a
  certificate and suggesting a DNS/CAA problem (DD-193).
- Cold-boot recovery firewall: the INPUT and FORWARD guards are independent and
  each is all-or-nothing, so a failed rule can neither lock out SSH nor skip the
  WireGuard forwarding block.
- New folder shares start with Tailscale on only while WebDAV is published on
  Tailscale; turning a folder's Tailscale connection on is refused while that
  publication is closed (same rule as WAN). The create form starts that switch
  off and locked.
- Concurrent requests with the same credentials (an Infuse library scan) share
  one password check instead of competing for the hash slots, so a cold first
  connection no longer gets 503 replies. Limits are unchanged.
- The unreachable standalone HTTPS card is removed; public WebDAV HTTPS is edited
  in the address table, which now names the HTTPS port in legacy HTTP mode too.
  A save's refresh no longer draws data read before the save. A closed WAN share
  card says “WAN” instead of “HTTPS”.
- Caddy no longer logs a warning each time a media player closes a stream;
  proxy errors and failed upstream connections are still logged.
- Installer runs no longer leave a copy of every rendered template in the
  server's `/tmp` (a Bash 5-only cleanup bug; the files were root-only and
  vanished at reboot).
- Smaller: private 403 routes follow the module templates' addresses; clearer
  qBittorrent publication, Files and health messages; deep JSON handled in two
  more parse sites; `__pycache__/` ignored by Git.
- Live tests: `publications-live.py` no longer contains the operator's domain and
  works with a public qBittorrent; `backend-hardening-live.py` follows the
  host's WAN mode; `share-networks-live.py` skips (exit 3) on HTTPS hosts.
- **Verified:** Mac — 374 Python (4 platform skips), 166 Bats (3 skips), six
  browser fixture suites, ShellCheck, Bash/JavaScript syntax. Linux (nrm, Bash
  5.2) — 374 Python (1 optional skip), 166 Bats (1 skip), firewall (including
  cold rescue), settings, domain, qBittorrent defaults, publication proxy on 443
  and 18443, settings-systemd and install-hardening suites. The scoped Caddy
  logging validated against nrm's Caddy 2.11.4 before release.
- **nrm:** portable run with scratch inputs (SSH_HOST=nrm, blank LOCAL_DOMAIN,
  default no full-upgrade, `E`), exit 0. Share registry, qBittorrent profile and
  WireGuard registry digests and qBittorrent PID unchanged; installed helpers
  match source; no new `/tmp` file. Live: share-connections, publications
  (private 403 on every template address, DAV public off/on, restored choices)
  and backend-hardening over HTTPS WAN (57.9 MB/s) and Tailscale (56.9 MB/s,
  SHA-verified, OOM 0) pass; `share-networks-live.py` skipped with exit 3. A
  cold identical-login burst returned 8/8 (Tailscale) and 4/4 (WAN) HTTP 207,
  no 503; six mid-stream client resets wrote no Caddy log line. Health green.
  137 leaked template copies and old test trees were removed from `/tmp`.

### 2026-10-01 — Per-connection WebDAV policies and dual-card Shares (v2-164)

- Each folder keeps one ID/account while Tailscale and WAN independently control
  enabled state, RO/RW and expiry (DD-192). Both off is valid. New shares use
  Tailscale on/RO/seven days and WAN off/RO/seven days.
- Schema 4 stores both connection policies. Valid schema 3 converts in memory
  and `prepare` persists it without rotating accounts, changing identity/timestamps
  or renewing expiry. Schema 2 and conflicting legacy fields in schema 4 fail
  closed. Stale global-policy updates and pause requests require a page refresh.
- Nested partial saves preserve omitted values under the locks. Explicit RW needs
  acknowledgement in the selected scope; toggles never renew expiry. The receiving
  listener enforces its policy on DAV writes, transfer chunks and staged uploads,
  including cached logins.
- Shares shows two cards with independent controls, address/copy and Infuse
  details, HTTPS or honest legacy-HTTP labeling, and global Caddy gate reasons.
  Candidate card URLs may remain while off; `row.urls` lists only active scopes.
  Shared account/path/password management remains separate. Share edits still
  restart active WebDAV and interrupt all transfers; configured HTTPS renewal
  remains available with no active folders under its existing global gate.
- **Verification (reported by the main implementation task):** 36 new tests
  passed on macOS/Debian; full Python 366 (four macOS skips, one Linux skip);
  Bats 165 (three skips); six browser fixture suites passed, including Files at
  ten widths in both themes, with screenshots reviewed. Portable deployment on
  `nrm` exited 0; schema-3 migration matched the expected normalized schema 4
  exactly, preserving credentials, identities, IDs and absolute expiry. Settings
  and qBittorrent bytes and qBittorrent PID stayed unchanged. Real HTTPS/Tailscale
  connection acceptance passed with byte-identical registry cleanup; read-only
  installed UI passed at three widths/two themes with zero errors or API writes.
  See [SESSION.md](SESSION.md) for exact evidence and final host health; native
  client acceptance is not implied.

### 2026-09-30 — Compact local-domain settings and DNS guide (v2-163)

- Limit the Caddy local-domain card to 620 px, with its input and Update button
  on one row. Keep the publication table full-width and the mobile layout fluid.
- Add four manual Tailscale Admin DNS steps below the input, linking to the DNS
  console and showing the current server IP and saved local suffix. Unsaved
  edits do not change the guide. No Tailscale account/API changes are made.
- Preserve local-domain validation/confirmation/rollback and all independent
  HTTPS settings. The operator has now enabled `qbit.example.net` successfully.
- **Verified locally:** publication-table browser/CSP tests at five widths in
  both themes, dynamic guide values, cancelled domain-change flow, existing
  Settings and HTTPS UI regressions; 330 Python cases (4 platform/optional skips),
  JavaScript/Bash syntax, ShellCheck and exact 49-file portable payload parity.
- **nrm:** portable upgrade with scratch inputs, default no full-upgrade and E,
  exit 0. Read-only live browser checks pass at three widths in both themes;
  current IP/suffix and both ready certificates appear without browser errors.
  Settings/share/qBittorrent file digests and qBittorrent PID are unchanged.
  External trusted HTTPS returns qBittorrent login 200, anonymous API 403 and
  WebDAV root 404. Health is green; eight services active, no failed units;
  Caddy, dnsmasq, firewall and systemd validation pass. No fresh OS/reboot,
  authenticated client/transfer test, commit or Desktop copy for this UI change.

### 2026-09-30 — Independent Caddy address table (v2-162)

- Settings → Caddy now lists Panel, qBittorrent and WebDAV with independent
  Tailscale/Internet choices, public domain, certificate state and per-row Save.
  Panel stays private and locked in both UI/API. Local-domain configuration
  remains separate; the effective Caddy configuration is a collapsed detail.
  Responsive rows support both themes (DD-191).
- Direct HTTPS only; no Tunnel, DNS API, arbitrary upstream or new daemon.
  Native qBittorrent login, CSRF/Host protection and login-attempt limits are
  prerequisites, not silently rewritten preferences. Public names share one
  TCP443 permission and the existing connection budgets. Legacy DAV HTTP must
  be disabled or converted before enabling public qBittorrent.
- Off retains the domain without HTTP fallback. Private off answers 403 and
  survives module reapply. Folder accounts/network permissions are unchanged;
  disabled global networks no longer produce copyable share URLs. Transaction
  snapshots restore private routes after first-save failure/crash too.
- Real API rejection exposed duplicate Python exception classes when the
  Settings CLI imported itself via helpers; fixed module identity and added a
  subprocess regression. Native proxy tests caught nondefault-port Host
  rejection: upstream Host omits the public port, while X-Forwarded-Host keeps
  the external authority for CSRF without weakening either protection.
- **Verified:** 330 Python cases on macOS/Linux (4/1 skips), 165 Bats on both
  (3/1 skips), publication-table browser/CSP tests at five widths in both themes,
  existing HTTPS/settings/files/panel/WireGuard browser regressions,
  actual nrm page with no browser errors, syntax/ShellCheck and exact 49-file
  source/bundle/installed-tree parity. Linux firewall packet tests cover
  qBittorrent-only/shared HTTPS, stopped/unsafe-auth closure, manual denies and
  cold recovery. Real native password/settings and isolated Caddy/qBittorrent
  login/cookie/CSRF/Host/Panel-isolation tests pass on ports 443 and 18443.
- **nrm:** three portable runs with scratch SSH_HOST=nrm/blank LOCAL_DOMAIN,
  default no full-upgrade, E, exit 0. Actual private off/on, module reapply and
  public DAV off/on preserve effective choices, verified TLS and folder-account
  bytes. External HTTPS/Tailscale PROPFIND, RO/RW, Unicode PUT, absolute MOVE,
  DELETE, ranges and SHA-verified download pass (31.07 MB/s on a short 32 MiB
  sample; not a speed ceiling). Temporary test accounts/files were removed.
- Final state: Panel private/locked; qBittorrent private; WebDAV Tailscale plus
  `dav.example.net` HTTPS, certificate expiry 2026-12-29. `torrent.example.net` has no
  DNS record yet, so its public DNS/ACME path was not enabled or claimed tested.
  Caddy/dnsmasq/firewall checks pass, no failed units. Final Settings API burst
  (8 parallel, 32 requests) returns 32/32 HTTP200, slowest 213 ms; health is green.
  No fresh OS, reboot,
  native Infuse or future renewal test; no commit or Desktop copy.

### 2026-09-30 — Panel-managed public WebDAV HTTPS (v2-161)

- Settings → Caddy gains a separate public-domain card with DNS guidance,
  save/disable actions, certificate status and expiry. Local names and private
  administration stay unchanged. Only the public WebDAV endpoint moves to HTTPS;
  Files → Shares shows its new copyable address (DD-190).
- DNS must resolve exactly to the assigned public IPv4, without AAAA or proxy.
  Caddy obtains/renews Let's Encrypt certificates using TLS-ALPN on TCP 443;
  no DNS token, WAN port 80, UDP 443 or new daemon. The HTTPS listener requires
  matching Host/SNI. Account scope, password throttles and connection limits stay.
- Existing revision/lock/pending recovery owns the operation. Save commits after
  verified certificate chain/hostname; failure restores the prior setting.
  Explicit removal closes WAN without HTTP downgrade; accounts and Tailscale
  URLs survive. The configured HTTPS listener stays for renewal with no active
  folders. Certificate health is a local probe, not public-reachability proof.
- **Verified:** 318 Python cases on macOS/Linux (4/1 skips); 165 Bats on macOS/Linux
  (3/1 skips), five fixture browser suites, shell syntax/ShellCheck and exact
  48-file portable parity. Linux settings/DNS/domain/native qBittorrent tests
  pass. Isolated firewall packets cover HTTPS renewal/limits, legacy closure,
  Tailscale/WG preservation and cold corruption/recovery. DNS/certificate
  failure, pending crash recovery, stale/mixed requests,
  renewal with paused folders and no-plaintext fallback have regression coverage.
- **nrm:** three portable runs, scratch inputs, no full-upgrade, confirmation E,
  exit 0. Saved `dav.example.net` through the real Settings API; trusted TLS 1.3,
  Let's Encrypt certificate expires 2026-12-29. External HTTPS PROPFIND, RO/RW,
  GET/Range, Unicode PUT, absolute MOVE, DELETE, pause and network isolation pass.
  Private paths return 404; mismatched TLS/Host returns 421. A SHA-verified
  ~32 MiB transfer measured 29.53 MB/s (short acceptance run, not a speed ceiling).
- Actual disable/re-enable closes both WAN ports without breaking Tailscale;
  rerun preserves the domain/certificate. Original share registry remains
  byte-identical after temporary test-account cleanup. Live Caddy page has no
  browser errors, health is green and Caddy/dnsmasq/firewall validation passes.
  No fresh OS, reboot, native Infuse UI or real future certificate renewal was
  exercised. The old WAN HTTP URL no longer works after HTTPS is enabled;
  clients must use the newly displayed HTTPS address. No commit or Desktop copy.

### 2026-09-30 — Remaining audit stages: boot safety, WebDAV and health (v2-160)

- Firewall retains valid owned protection on registry errors; a cold boot gets
  a narrow rescue guard while strict health/pre-start checks still fail. Both
  INPUT policies deny otherwise unhandled interfaces (DD-187).
- Installer creates/repairs user directories through no-follow descriptors,
  skipping special/multiply-linked files and private trees. Module mutations
  share the install lock without nested deadlock; CLI account lookup also uses
  the safe qBittorrent reader.
- Full Linux shell verification found Bash 5.2's `patsub_replacement` changing
  literal ampersands in templates. Rendering now temporarily disables that
  option and restores the caller's setting; Bash 3.2 remains supported.
- Separate bounded scrypt pools, short wait/cache recheck and overload 503 with
  Retry-After preserve credential throttles. PUT/COPY stage outside the global
  mutation lock and revalidate before atomic publication. WebDAV sandbox,
  process/memory/start limits and proxy/backend idle ordering are tightened
  (DD-188); TCP/request budgets and explicit HTTP WAN remain unchanged.
- IPv4-only generated DNS, accurate parser projection, desired-service health,
  Debian kernel reboot detection, controlled deep-JSON errors and actionable
  incomplete-folder versus share-overlap messages (DD-189).
- **Verified:** 281 Python tests on macOS (4 skips) and Linux (1 optional RAR
  corpus skip); 165 Bats on both (Mac 3 skips, Linux 1 negative-flock skip),
  four fixture browser suites, shell syntax/shellcheck and complete 47-file
  portable parity. Real Linux ownership/flock: 28 tests. Isolated firewall
  (including cold settings/share/WG corruption, preserved denies, retry/recovery,
  second NIC and third-party rules), settings, domain/DNS, native qBittorrent
  defaults and transient systemd recovery all pass.
- **nrm:** three portable runs, exit 0; rebooted from 6.12.107 to
  6.12.111+deb13-amd64. Core/optional services and firewall healthy, two WG peers
  retained; kernel warning before reboot becomes green after. All three service
  names return A only, not unusable AAAA. Caddy/dnsmasq/unit validation passed.
- After reboot, 320 burst API requests all 200; 80 parallel PROPFIND all 207;
  WAN 59.36 MB/s and Tailscale 55.22 MB/s on separate SHA-verified 256 MiB
  transfers. Peak DAV cgroup usage reaches its 512 MiB cap by reclaiming cache,
  not growing anonymous memory (~35 MB); OOM and oom_kill remain zero.
- Temporary RO/RW accounts prove password rotation, isolation, pause, Unicode,
  ranges and persistence across rerun/reboot; cleaned afterwards. Original share
  account metadata is identical. qBittorrent config bytes stayed identical across
  installer reruns but its digest changed across the native service reboot;
  the pre-boot contents were not saved, so byte-for-byte profile persistence is
  not claimed. Native fixture tests do prove preservation of chosen preferences.
  No Desktop copy or commit. No fresh Ubuntu installation, native Infuse UI or remote WG-client
  session was tested; HTTP WAN and account-level Tailscale policy are unchanged.

### 2026-09-30 — Audit stage 1: burst admission and filesystem guards (v2-159)

- The Konsol Unix socket, Files and both WebDAV listeners now queue up to
  128 pending connections instead of Python's default 5. This addresses the
  observed Unix-socket admission failures; WAN request, login and TCP limits
  are unchanged (DD-186).
- Both root readers of the service-owned qBittorrent configuration use the
  existing descriptor-safe, bounded regular-file reader. Symlink components,
  FIFOs and other special files are rejected without waiting for input. A
  missing profile still works; an unsafe profile prevents share changes.
- Files rejects root `.cop`, `.pay` and `.arsiv` sources before a rename,
  move or trash batch starts. Moving a nested reserved name into the root is
  also refused; restoring an old trash entry chooses a harmless alternate name.
- Regression tests cover actual socket bursts, bounded FIFO rejection,
  symlink parents, oversized files, mixed selections and ordinary file actions.
- **Verified:** portable payload matches all 46 runtime files; deployed to nrm
  using scratch inputs, default no full-upgrade and `E` (exit 0). All four
  backend listeners report backlog 128; services active and firewall check
  passes. Local Python: 206 tests (4 skips); Linux Python: 206 (1 skip).
  Mac Bats: 163 (3 skips), with physical temporary paths for the no-follow
  fixtures. Shell syntax, shellcheck and diff whitespace checks pass.
  Live: Konsol and Files each 100/100 HTTP 200 at 20 parallel fresh client
  connections; direct Unix socket 120/120 at 24 parallel. Separate 256 MiB
  downloads: WAN 59.72 MB/s, Tailscale 57.53 MB/s, both SHA256 verified;
  each network passed 40 PROPFINDs at four parallel and byte ranges.
  Service memory grew from 15.3 MB to 559.2 MB, including 523.0 MB file cache
  and 34.4 MB anonymous memory. This demonstrates the speed-test/cache
  mechanism, not the cause of the historical 670 MB peak. Test account/files
  removed, existing share registry byte-for-byte unchanged. No reboot or
  fresh-OS/native Infuse test in this stage.

### 2026-09-30 — Tailscale/Caddy auto-updates and maintenance cleanup (v2-158)

- Unattended upgrades now also install Tailscale and Caddy updates from their
  own repositories, besides Debian/Ubuntu security updates. The daily run is
  moved to 04:00 (up to 30 min random delay) so a Tailscale or Caddy restart
  happens at night; stage 7 warns if either repository is missing from the
  policy (DD-184). Reboots stay manual.
- Removed code that only served hosts installed with earlier versions (fresh
  install only, DD-185): the WireGuard registry upgrade helper, the old
  `GET /api/wg/sistem` view, schema-2 share registry conversion, the retired
  health-site and old-share-link answers (now 404), Konsol's rewrites of retired
  bookmarks, the `ui`/`ping` WireGuard rule kinds in the settings view, log
  labels no backend writes and 93 lines of unused CSS. A host installed with an
  older version needs a fresh install.
- Documentation trimmed to current behaviour: retired decisions, CHANGELOG
  entries before v2-145 and older session notes moved verbatim to
  `docs/archive/`; new `docs/decisions-index.md` lists every DD with its status.
- **Verified on nrm:** deployed with the portable launcher and scratch inputs
  (exit 0). `apt-config` lists both new patterns; `unattended-upgrade --dry-run`
  names them as allowed origins and the installed tailscale and caddy packages
  match them; the timer's next run is 04:00. Over the tailnet
  `/api/wg/sistem` and `/api/paylas*` answer 404, resources and health 200.
  Linux unit tests (197), firewall/settings/domain/torrent namespace suites,
  settings-systemd, shares/archives/RAR live and the external WAN share test
  pass. Locally: 163 Bats, 197 Python, the four browser suites, shellcheck.

### 2026-09-30 — Archive jobs page removed (v2-157)

- Files no longer has an "Arşiv işleri" tab. A running job shows as one bar above
  the list with its progress and "İptal et"; starting a job stays in Files (DD-183).
- Ayarlar → Günlük now shows archive jobs readably: start ("sources → result"),
  cancel request and the result with the server's message, including jobs found
  interrupted after a restart. Before, only an opaque job id was logged.
- **Verified:** deployed to nrm; archives-live (ZIP, nested, conflict, invalid
  path, cancel) wrote readable arsiv-olustur/ac/iptal/sonuc lines and Konsol's
  Günlük API returned them. Local mock with recorded nrm replies: no jobs tab,
  bar with İptal et while running, gone after completion, old bookmark opens
  Files, no console errors. 163 Bats, 203 Python. With Node/Playwright now on the
  Mac, all four fixture browser suites pass, updated for the archive bar
  (panel-ui) and the health card plus typed discard (settings-ui).

### 2026-09-30 — Stuck rollback, WAN address change, watchdog, health card (v2-156)

- A settings rollback that keeps failing is retried after 15/30/60/120 s and
  then waits as "takıldı": Konsol shows the error with "Yeniden dene" and
  "Bırak" (typed onayla) instead of retrying every 2 s forever (DD-182).
- A WAN share whose address the provider changed is closed with a reason; a
  Caddy that could not start on the old address is started without it, and the
  installer no longer dies in stage 6 on that address.
- The Tailscale watchdog resets Caddy's start limit before restarting it and
  checks the firewall again once Tailscale answers.
- A damaged archive history is set aside instead of keeping Files from starting.
- New read-only Sağlık card on Settings → Sistem: failed services, Tailscale and
  key expiry, firewall, reboot needed, clock sync, disk/inodes, pending settings.
- A new archive job waits for the previous one to finish removing its staging
  area instead of answering "işlem sürüyor" right after it showed "done".
- **Verified on nrm:** installer removed a WAN site bound to a stale address in
  stage 6 and republished it; a runtime address change closed the site with a
  reason and a Caddy stuck on the old address came back; five failing rollbacks
  became "takıldı" (health red, timer idle), then retry and discard (wrong word
  refused) both worked; damaged history set aside with no restart; reboot into
  kernel 6.12.111: all units active, wg0 after the firewall, sockets 0660/0700,
  no TCP 61008/2019, health green after NTP sync. Caddy's start limit could not
  be reached on Debian 13 (automatic restarts continued), so the reset-failed
  change is precautionary. Local 163 Bats, 201 Python; Linux unit, namespace,
  systemd, share/archive/RAR and external WAN suites pass.

### 2026-09-30 — Faster WebDAV logins, quieter journal, compressed Konsol (v2-155)

- WebDAV remembers a successful login for 10 minutes, so Infuse/Finder requests
  no longer pay one scrypt check each; every limit and check still applies
  (DD-181). Tailnet WebDAV slots 16 → 64; closing replies say so.
- WebDAV and Files replies through Caddy no longer wait ~40 ms each for a
  delayed ACK (Nagle was on for the kept-alive loopback connection).
- The settings rollback timer runs only while a change is pending (it used to
  start every 2 s). Both short timers keep systemd's per-run lines out of the
  journal. The root backend logs audit lines only, no request lines.
- Konsol pages and API replies are compressed; page files revalidate (304)
  instead of downloading again. Concurrent settings refreshes share one run.
- qBittorrent gets lower CPU priority than Tailscale and Konsol; archive jobs
  run niced and store already-compressed media without re-deflating it.
- **Verified on nrm (with v2-154):** WebDAV PROPFIND through Caddy 44 → 1 ms;
  konsol.js 119 → 37 KB (zstd) and 304 on revalidation; guard/share timers wrote
  0 journal lines in 3 min (was ~200); real apply started and then stopped the
  timer; an unconfirmed firewall rule was rolled back after 66 s and the timer
  stopped; qBittorrent nice 10 / CPUWeight 50.

### 2026-09-30 — Private sockets and login, disk and WireGuard safeguards (v2-154)

- The root Konsol backend has no TCP port: a Unix socket for root and Caddy's
  group (`SO_PEERCRED` checked); Caddy's admin API moves from `127.0.0.1:2019`
  to a socket in a `0700` folder. What Caddy relays to the root backend must
  come from another tailnet device, not from the server itself. Downloads-account
  programs (qBittorrent, unrar) can no longer reach either, directly or through
  Caddy. Stage 7 proves it and reloads Caddy (DD-180).
- WebDAV: the 5-failure/60 s IP block also covers Tailscale; 100 failures in
  an hour close a share for an hour to addresses not yet logged in; wrong user,
  paused or unknown shares cost the same hash as a real check.
- WebDAV PUT/COPY and Files uploads stop with 507 before free space falls under
  min(5 GiB, 10%) and remove their temporary file.
- Files backend (unrar) sandbox: loopback-only network, system-call filter,
  hidden processes, private IPC, no writable-executable memory.
- WireGuard networks start only after `master-firewall --check` passes; the
  refresh timer reopens a network that failed for that reason.
- Root backend closes the connection after an error or an unread request body,
  so a body hidden in a cross-site POST can no longer run as a second request.
- **Verified on nrm (installed as v2-154, then v2-155):** no TCP 61008/2019;
  socket modes; downloads uid refused on both sockets and through Caddy (403);
  a supplementary-caddy-group user refused by SO_PEERCRED; Caddy reload works;
  tailnet WebDAV 5th bad login → 429 while local probes stay 401; nested
  RAR/ZIP/RAR extracted by real unrar in the sandbox (exposure 3.0 → 1.4); a
  broken firewall kept wg0 down until the timer repaired both. Local: 162 Bats
  (3 macOS skips), 191 Python (4 skips); Linux: 191 Python (1 skip), four
  namespace suites, real-systemd timer test, share/archive/WAN acceptance pass.

### 2026-09-29 — Per-folder Tailscale / HTTP WAN sharing (v2-153)

- Select Tailscale, WAN IPv4 or both per folder; one account/ID/permission/expiry.
  Existing schema-2 and new shares default to Tailscale; adding WAN requires
  explicit acknowledgement that HTTP exposes credentials/content (DD-179).
- Separate trusted listener scopes and connection pools; Caddy replaces the
  client-IP header. WAN: 5 bad logins/60s → 300s IP block with Retry-After,
  4096-entry bounded history, 4 parallel hashes, 8 backend connections total,
  4 requests/IP. Tailnet retains 16 connections. Edge TCP: 16/IP, 64 total;
  WAN header/idle timeouts are 10s/30s. No bandwidth limiter or new package.
- Open only the existing WebDAV port and `/s/*`; no admin interfaces, public
  IPv6, wildcard bind, NAT/ACL change or automatic exposure of existing shares.
  Manual firewall denies remain effective. Last active WAN share removal/pause
  closes the listener/owned rules; a scoped timer projects expiry and recovers
  interrupted registry operations. Caddy startup checks the firewall first.
- Show labeled copyable URLs/network badges, HTTP consent and limits. Keep
  inline RO/RW and duration controls. Caddy/firewall inventory identifies WAN
  correctly and parses proxy blocks as well as single-line upstreams.
- Add manager migration/publication/recovery tests, real-HTTP budget/scope
  regressions, UI network tests and a disposable external-client acceptance
  script. HTTP remains unsuitable for confidential internet traffic.
- **Verified on nrm:** portable upgrade, Caddy/systemd/DNS/firewall checks,
  external WAN/Tailscale isolation, TCP/request/login caps, pause/expiry cleanup
  and 66 installed Linux share tests. Local 159 Bats and 170 Python cases have
  three platform skips each. No fresh-OS/reboot/native-client certification.

### 2026-09-29 — Integration-only qBittorrent defaults (v2-152)

- Stop forcing UPnP/automatic port mapping, local peer discovery and separate
  temporary storage in new qBittorrent profiles (DD-178). Leave these and other
  user preferences at the installed application's defaults until changed.
- Keep the download path, authenticated loopback WebUI and headless startup
  notice, plus existing nonroot service/sandbox and DNS/Caddy integration.
  Existing profiles and host firewall permissions are unchanged.
- Add exact seed-key and reapply/reinstall preservation checks, plus a native
  isolated Linux comparison and user-choice restart test.
- **Verified:** 155 Bats cases (three platform skips), 126 Python cases (two
  optional native-RAR skips), Bash syntax/ShellCheck and 44-file portable payload
  equality. Native Debian qBittorrent 5.1.0-2 passed the isolated default/login/
  preference-persistence test twice. No installed profile/service was changed;
  full host upgrade, fresh OS installation and reboot were not run this turn.

### 2026-09-28 — WireGuard internet-only (v2-151)

- Retire Local access entirely (DD-177): no creation/settings selector, API
  scope or CLI argument. Network settings now change default DNS only.
- Drop WG host ingress before established/ICMP/Tailscale acceptance; block
  private/CGNAT/link-local destinations even via WAN. Keep internet NAT/return
  traffic and required user-created UDP endpoints.
- Upgrade existing registry policies without modifying keys, profiles, DNS,
  ports or addresses. Remove WG host-rule overrides and only the retired WG
  Caddy instances/template/env files; clean/repeat installs never recreate them.
- Firewall host overrides remain available for WAN/Tailscale only.
- **Verified:** 155 Bats cases (three platform skips), 126 Python cases (two
  native-RAR skips), WireGuard/Settings/Panel/Files browser suites and syntax/
  ShellCheck. Isolated Linux tests cover IPv4/IPv6 NAT, host/old-flow denial,
  private WAN destinations, retained networks and third-party chain preservation.
  nrm upgrade passed stages 0–7; real kernel WG clients on existing wg0 and an
  own new test network reached IPv4/IPv6 internet and public DNS, not host services.
  Test peers/network were removed; original keys/settings/accounts and qB process
  stayed unchanged. Transport was host-loopback to WG, not an external WAN device.
  Fresh OS installation and reboot acceptance are separate, not claimed here.

### 2026-09-28 — Default WireGuard Local access (v2-150)

- New Konsol networks default to Internet + local at the backend. Remove the
  creation access card/toggle and its unused code/styles; update preview/help.
- All peers inherit access to the installed qBittorrent UI on their own network;
  all other isolation remains. Existing network settings can still disable Local,
  and re-runs preserve that saved choice. Explicit CLI/API scopes remain supported
  (DD-176). No key/profile regeneration, new dependency or firewall widening.
- **Verified:** 157 Bats cases (three macOS skips), 121 Python cases (two
  native-RAR skips), WireGuard/Panel/Settings browser suites, syntax/ShellCheck.
  nrm portable upgrade passed stages 0–7. A scope-less test network created with
  `ui`, active WG/Caddy, the narrow firewall permit and qB UI HTTP 200; removed
  only that empty fixture. Eight services healthy, live desktop/mobile passed;
  original registry/configuration hashes, qB process and full normalized firewall
  match before/after. Existing wg0 was already Local-enabled. No fresh OS/reboot
  or external WG-client acceptance claimed.

### 2026-09-28 — Firewall source and rule cleanup (v2-149)

- Missing WireGuard module registration no longer revives retained networks.
  Omit/remove unused project forwarding/NAT chains when no networks are configured.
- Remove redundant terminal returns and single-element multiport generation.
  Preserve required VPN endpoints, actual permissions, user overrides and all
  third-party rules; no legacy service installer is restored (DD-175).
- Strengthen INPUT/NAT drift checks and add clean/repeat/removal regression
  fixtures, while keeping the panel accurate for intentionally absent chains.
- **Verified:** 157 Bats cases (three platform skips), 119 Python cases (two
  native-RAR skips), Settings browser suite, isolated Linux IPv4/IPv6 input and
  routed WG NAT/isolation tests. Portable upgrade and repeat install on nrm
  passed stages 0–7. Project rules decreased 81 → 73; all other firewall content,
  user settings, WG profiles and qB process remained unchanged. Eight services
  healthy; live API/desktop/mobile tests passed. No fresh OS/reboot claim.

### 2026-09-28 — Simplify Internet and WireGuard port lists (v2-148)

- Remove synthetic closed WAN rows for local/tailnet services, arbitrary sockets
  and unsupported IPv6 WG endpoints at the backend source (DD-174).
- List tunnel-local qBittorrent permissions only for IPv4 networks with Local
  access configured. Keep required VPN UDP endpoints regardless of peer/socket
  activity, explicit user allows/denies, network selectors and raw diagnostics.
  Actual firewall policy, services and saved settings are unchanged.
- **Verified:** 157 Bats cases (three platform skips), 117 Python cases (two
  native-RAR skips), Settings browser tests, syntax/ShellCheck and portable nrm
  upgrade. Live API/browser checks confirm WAN 4/2 rows (IPv4/IPv6), one wg0
  IPv4 UI row and no synthetic wg1/IPv6 UI rows; explicit-rule fixtures remain
  editable. Normalized full firewall rules, configuration hashes and qB process
  match before/after; eight services healthy. No fresh-install/reboot claim.

### 2026-09-28 — Remove synthetic Tailscale port entries (v2-147)

- Generate Tailscale port rows from the configured per-family allowlist and WG
  registry, not arbitrary host listeners (DD-173). Remove irrelevant peer/local
  backend/Caddy admin rows at their source; preserve explicit user rules and
  unfiltered technical diagnostics. No hardcoded port exclusions.
- Preserve default-deny protection, required local services, every configured
  WG endpoint, socket bindings, torrent settings and all forwarding/NAT policy.
- **Verified:** 157 Bats cases (three platform skips), 114 Python cases (two
  native-RAR skips), Settings browser suite, portable nrm upgrade and live
  IPv4/IPv6 API/socket checks. Desktop/mobile show only configured tailnet rows;
  raw diagnostics remain intact. Eight services active, no failed units; account,
  share, module/WG registry/profile hashes and qBittorrent process unchanged.
  No fresh install, Ubuntu, reboot or authenticated Infuse claim for this change.

### 2026-09-28 — Minimum tailnet host exposure (v2-146)

- Replace implicit all-port tailnet access with an explicit host allowlist before
  Tailscale's own INPUT acceptance (DD-172). Keep SSH, Caddy, DNS, folder WebDAV,
  self-advertised PeerAPI and every registered WireGuard endpoint. Block other
  new inbound ports by default, including qBittorrent peers and direct backends.
- Preserve operator overrides, loopback, established replies, ICMP, all WAN/WG
  and forwarding/NAT policies. No network deletion, credential change or package
  removal. Peer counts and counters never determine whether a WG port is needed.
- Make the port table use the same allowlist instead of treating any listener
  as tailnet-accessible. Add real IPv4/IPv6 packet, override and drift tests;
  helper changes now trigger both firewall refresh and panel restart.
- **Verified:** 157 Bats cases (three platform skips), 113 Python cases (two
  local RAR skips, native Debian coverage), Settings browser suite and isolated
  Linux packet/settings tests. Portable nrm upgrade and live dual-stack checks
  preserve service/config/WG state; qBittorrent's PID is unchanged. No clean
  Ubuntu/reboot, VPN client throughput or authenticated Infuse acceptance claim.

### 2026-09-28 — Runtime and installer cleanup (v2-145)

- Align active documentation, input-template and launcher messages with built-in
  Files/WebDAV/archive tools, App Store, current settings and no automatic backup.
  Remove unused frontend helpers, old shared-account UI and obsolete CSS.
- Remove unreachable built-in module install/remove/data-delete branches and
  shared-password plumbing. Stop creating `.pay/w` and its marker, exporting old
  credential paths or repairing legacy metadata permissions (DD-171).
- Preserve current folder accounts and all existing data; retain reserved-path
  guards and tolerate absent legacy paths in the WebDAV sandbox. Retired Files
  share routes now consistently answer 410; drop their obsolete state summary.
- Keep all used dependencies and runtime files; no package purge, automatic
  migration, data deletion or extra background service. Add regression checks
  for fresh/legacy trees, retired API gates and first-login secret handling.
- **Verified:** 157 local Bats cases (three platform skips), 108 local Python
  cases (two native RAR skips), four browser suites; all 108 Python cases pass
  on native Debian including real RAR. Reproducible 45-file portable payload,
  nrm upgrade, live UI/API, systemd absent/present-path sandbox and built-in
  idempotency checks pass. Accounts, settings, WG configs and qBittorrent process
  are unchanged. No fresh Ubuntu/full fresh-install/reboot acceptance claim.

Older entries (v2-144 and earlier) are archived verbatim in [`docs/archive/CHANGELOG-before-v2-145.md`](docs/archive/CHANGELOG-before-v2-145.md).
