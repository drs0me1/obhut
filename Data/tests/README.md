# Tests

How to run every suite of Obhut's generation 2 and what each one covers. The suites are narrow,
critical-behaviour checks of the installer tree, not framework coverage. Commands run from `Data/`
unless a block says otherwise; paths are relative to `Data/`.

| Kind | Files | Needs | Changes a host? |
|---|---|---|---|
| [Static checks](#static-checks) | the whole tree | `bash`, `shellcheck`, Python 3.13, Node for the build | no |
| [Bats](#bats) | `common.bats`, `share-networks.bats` | `bats` ≥ 1.5, Bash, Python 3 | no (temporary folders) |
| [Python unit tests](#python-unit-tests) | `test_*.py` | Python 3.11+ (3.13 on the test host) with OpenSSL scrypt | no (temporary folders, fakes) |
| [Browser suites](#browser-suites-and-the-layout-audit) | `yeni-*.cjs`, `giris-ui.cjs`, `duzen-denetimi.cjs` | Node, Playwright with Chromium | no (fixture APIs) |
| [Linux namespace suites](#linux-namespace-suites) | `*-linux.py`, `settings-systemd.py` | Linux, root, the named binaries | no (private namespaces and scratch state) |
| [Live scripts](#live-scripts) | `*-live.py` | an authorized test host over SSH and Tailscale | **yes** (opt-in, scoped) |

Before calling a change done (rebuild.md section 7): the static checks, `bats tests`, the Python unit
tests with only the known macOS failures below, and the browser suites of every screen the change
touches, with the layout audit.

## Static checks

```bash
for f in install.sh common.sh scripts/* ../kur.sh ../*.command; do bash -n "$f" || echo "$f"; done
shellcheck -x -s bash install.sh common.sh scripts/* ../kur.sh
python3.13 -m py_compile panel/*.py panel/master-panel files-panel/master-files-panel
cd tools/konsol-ui && npx vue-tsc --noEmit          # the interface's types (npm ci first)
```

On a Linux host with the packages: `caddy validate`, `dnsmasq --test` and `systemd-analyze verify` on
rendered files. The installer runs the first two itself (stage 6).

Two files are generated and committed; tests fail when they differ from their source:

- Konsol's API description and types come from the route table: `python3 panel/master_api.py openapi >
  docs/konsol-api.json` and `python3 panel/master_api.py ts > tools/konsol-ui/src/api/sema.ts`
  (`test_api.py`).
- Konsol's build: `cd tools/konsol-ui && npm ci && npm run derle` (vue-tsc, Vite with `lisanslar.mjs`
  writing the licence banner; a bundled package under another licence than MIT stops the build; then
  `console/yeni/kaynak.sha256`: the SHA-256 of the lines `<sha256>  <path>` for every file under
  `tools/konsol-ui` except `node_modules/`, in byte order of the path). `tools/konsol-ui/kaynak-ozeti.sh`
  prints the same digest with POSIX tools, so Bats and the browser suites check freshness without Node.
  Any edit under `tools/konsol-ui/` (a comment too) needs a rebuild. The editor bundle is built the same
  way in `tools/duzenleyici` (byte-identical for the same lockfile).

## Bats

```bash
bats tests                                   # both files
LC_ALL=C bats tests/common.bats -f 'master-wg'   # one file, tests whose name matches
```

`common.bats` (178 tests) and `share-networks.bats` (4). Under a Turkish locale run with `LC_ALL=C`:
`@test` names stay English for that reason. On macOS seven tests skip: three need root (kur.sh's tree
swap and update mode, `master-guncelle`), three need `timeout`, one needs Bash 4 (`ensure_console_pages`).

- The fixture resolves its temporary folder with `pwd -P`: macOS `/var` is a symlink and the
  no-follow readers rightly refuse it. Mode and inode checks use GNU or BSD `stat`, whichever answers;
  hashes use Python.
- The tests read files outside `Data/` too: `../kur.sh`, `../onar.command`, `../wireguard.command`,
  `../.gitignore` and `docs/`. For a Linux run copy those with the runtime tree, never `kurulum/` or a
  WireGuard profile. A root-created checkout under `mktemp -d` needs mode `0755` on that folder so the
  non-root fixture processes can traverse it; do not relax private input or credential modes.
- The backend tests start `master-panel` through `panel-harness.py` (below) with fake tools.

What they cover:

- **`common.sh` and the installer's shape:** logging, `atomic_write`, `render_template` (literal `&`,
  `/` and `\`, Bash 5.2's `patsub_replacement` kept), locks, `retry`; the OS gate (trixie, noble,
  resolute; os-release is parsed, not sourced) and the OS-divergence markers against architecture.md's
  table; apt (no kept downloads, no Docker, no RAR, the Caddy-repository outage rule, masked edge
  installs, the system upgrade on every run); sysctl drop-ins, TCP congestion control, the UDP buffer
  floor; every template placeholder filled; a config newer than its unit forcing a restart;
  `defaults.env` without unread keys; pipe consumers that never exit early under `pipefail`; no
  assertion relying on a bare negation (Bash 3.2).
- **Stage 0 and the generation gate:** the domain asked on the server until valid and confirmed before
  the first write, a confirmed or previous name kept, update mode never a first install; an older Obhut
  refused before any write and this generation marked (DD-271); no migration cleanup anywhere.
- **The built-ins:** Files and folder WebDAV rendered straight into the unit folder, run as the
  downloads uid with their sandbox, the private state hidden from them (DD-225), the share's site and
  name written with the base and through Konsol's choices, stage 7 proving both and their addresses;
  the system view on its own root socket and tailnet-only route; the Files backend's folder, trash,
  text, upload and download rules against a real process.
- **The firewall and the tailnet:** project chains only, no Docker chain, ports and chains from state,
  the WAN allow count from one list, `--check` on IPv4 and IPv6 shapes, staging cleanup, `ts-input`
  precedence, the hourly check; an application's Tailscale port as an IPv4 tailnet entry with the exact
  count following it; `refresh-tailnet-config` (Caddy only, restart not try-restart, the raw ports'
  address refresh, the boot and nightly timer), `wait-tailnet-addr`, Caddy's `OnFailure`.
- **WireGuard built in:** tool, drop-in, folder and kernel module after install with no network;
  `master-wg` (add, remove, dns, png, info, reset, `net-add`/`net-remove`, `--if`, network settings, a
  read-only folder), stopping and starting WireGuard as a whole, the settings worker's caller mode (the
  held install lock and the applying change's id), the backend's WireGuard routes (and none for the
  planned actions), the firewall's rules per network and its refusal of an untrusted registry,
  `wireguard.command` (talks to the server only, bash 3.2) and the `kurulum.env` template.
- **Konsol:** the backend's modules installed and wired (route table, Erişim, live events), Caddy's
  `forward_auth` (the tailnet passes, the internet signs in), the public Konsol snippet, private sockets
  for the backend and Caddy's admin API, the build at the console's root and its freshness, the CSP, the
  editor bundle, the marks and the app manifest; the browser suites' layout audit wiring.
- **Applications:** their records and data folders private to root, the bind helper, Podman as base
  infrastructure with private root workers, image updates only on confirmation.
- **Root tools:** `kur.sh` (the public repository, the runtime tree, the atomic swap, no swap under a
  running install, update mode pinned to a commit), `master-guncelle` (a fake `curl` first on PATH; only
  the confirmed commit's `kur.sh`, over HTTPS), `master-onar` and `onar.command`, `obhut`, the release
  and build numbers.
- **No switch for tests:** the shipped tree names none of the removed test switches, no Python program
  reads an environment value other than `STATE_FILE`, and no hidden option exists besides
  `master-onar --kaynak` (Konsol's own repair start).
- **`share-networks.bats`:** WAN sharing on a separate loopback address and the existing port, the
  bounded public Caddy timeouts, WAN connection admission before operator overrides, scoped expiry
  recovery wired by the installer.

## Python unit tests

```bash
PYTHONDONTWRITEBYTECODE=1 python3.13 -m unittest discover -s tests -p 'test_*.py'
(cd tests && python3.13 -m unittest test_generator test_inspector)       # some modules
python3.13 -m unittest discover -s tests -p 'test_share*.py'             # by pattern
```

872 tests. Use Python 3.11 or newer with OpenSSL's scrypt: macOS's `/usr/bin/python3` (3.9) parses
neither the runtime's nanosecond timestamps nor has scrypt; the test host runs 3.13. The suites use
temporary folders, temporary Unix sockets, fake tools and documentation addresses only.

**Known macOS-only failures (eight):** six tests of `test_text_edit` and
`test_system_files.SystemGateTests.test_text_save_through_the_handler` call `os.listxattr`/`os.setxattr`,
which exist only on Linux; `test_onar.RepairTests.test_address_change_hands_over_to_refresh_tailnet_config`
runs `refresh-tailnet-config`, whose `sed -i` is GNU's. Nothing else may fail. Six tests skip unless run as
root on Linux: four need root, one Linux peer credentials (`SO_PEERCRED`), one a `127.0.0.2` loopback alias.

**Test-only values stay outside the shipped tree** (rebuild.md ground rule 3). `panel-harness.py`
(never installed) runs `master-panel`'s own `main()` with `--tools DIR` (the test's fake tools first on
the base tools' PATH, `TOOL_PATH`), `--active-window` and `--sample-seconds` (WireGuard's "Bağlı"
window and the samplers' period); everything after them goes to `master-panel`. In-process tests patch
module constants (`TOOL_PATH`); the backends' arguments carry only their real options.

### The application engine

| Module | Covers |
|---|---|
| `test_yaml.py` | The YAML subset reader: every supported form with the line of each key and item; anchors, aliases, merge keys, tags, complex keys, duplicates, tabs and multi-line plain scalars stop with their line; the size, depth and node limits |
| `test_compose.py`, `test_kube.py` | Compose and Kubernetes YAML into the one model: every key rebuild.md 4.2 lists, interpolation, what `podman kube generate` writes, a Deployment with one replica and its claims, and a refusal with its line for everything else |
| `test_inspector.py` | Questions and guesses for the acceptance fixtures, the inspector's refusals, bad input never raising, `check()` on every answer (a kept secret, the root-start `/srv` warning, values an env file cannot carry), no secret value in the definition |
| `test_generator.py` | Golden units for every fixture the inspector accepts (`fixtures/uygulama/beklenen/<fixture>/`), names, both start modes, folders and anchors, aliases, the pod, publications of address and raw rows, start order and `Notify=healthy`, what needs Podman 5, every Quadlet key against Podman 4.9.3's set, quoting against models of the parsers the units meet, no secret value in the plan |
| `test_applications.py` | The record and its access rows (seeding, an edit's port rules, name checks), the loopback pool, the guard's input, the read model, the YAML emitter, the drafts (an image's ports and volumes, a container's settings) and the address fetch against a fake resolver (local, private, CGNAT, tailnet and mapped addresses refused; three checked redirects; size and time limits); the folder-size walker |
| `test_container_worker.py` | The root worker with fake Podman, systemctl and Quadlet: install (every refusal before a write, Podman 4.9's refusals, every step's rollback), takeover of a standalone container, start, stop, restart, update, an edit keeping and renewing secrets, removal keeping or deleting data, an access row's container side and its restore, `--adres-yenile`, the cleanup job; no secret value in an argument, file, record or reply |
| `test_container_manager.py` | The inventory, the applications' read model with live state, the edit plan, a service's journal, the broker (no request kept, one job per application, input limits), the cleanup's read model and routes |
| `test_uygulamalar.py` | Every application route through the real handler: shapes, revisions, the install plan writing nothing, audit lines `uygulama-<verb>`, the list's live rate and update count, no secret value in a reply |
| `test_container_updates.py` | Image update checks: registry manifests only, cached per application and service, a pinned digest never asked, `?yenile=1` |
| `test_container_network.py`, `test_container_dns.py` | The container guard's nft policy (egress only to the internet in `VPN_BLOCK_DEST4` order, the host closed but bridge DNS, fail closed on a bad list), a raw row's ingress permit, health detecting a changed rule |
| `test_container_binds.py` | Bind sources pinned at start: the bound folder is the walked one even when swapped for a link; links, hidden, outside and `..` sources refused; anchors released |
| `test_containers.py`, `test_container_integration_edges.py`, `test_container_listening.py` | The read-only Podman mapper and its route, environment values never returned, a host-network container's listening sockets from `/proc` |

Fixtures: `fixtures/uygulama/*.yaml` (published-style files with named volumes and a placeholder host
path, a web application with a database and a secret, a Pod and a Deployment as Podman writes them, a
hardened file, an unsafe file) and `app_fixtures.py` (a neutral two-service Compose file, its answers, a
state.env and a complete record; images are `registry.example`'s). After a deliberate generator change
rewrite the golden files and review the difference before committing:

```bash
python3.13 -I tests/test_generator.py --yaz
```

### Access, settings and the firewall

| Module | Covers |
|---|---|
| `test_access_rows.py` | The `erisim` settings section: request shape, names (free of fixed names, other applications, every `modul-*.conf` and DNS records), internet names (DNS, uniqueness, refused while WebDAV runs plaintext HTTP), every host-port conflict class, the internet consent; plan items and `onay_sn` (an opening 60 s, a closing 0); apply, confirmation and every rollback; the Caddy and dnsmasq projection; K5 entries, locked firewall rows and the read-only managed local names; closed `AyarIstegi` shapes |
| `test_settings.py` | The settings transaction: firewall rules, DNS (records and forwarding; a `disabled` or other unknown key refused) and the domain; plan (nothing written, the same refusals as apply), confirmation and its deadline across a reboot, DNS-only commits, rollback after a failed restart or a crash, a change that would cut the caller off, the internet channel refused; WireGuard's planned actions |
| `test_publications.py`, `test_https_settings.py`, `test_https_panel.py` | Konsol's and WebDAV's fixed rows (the tailnet switch fixed on, the account and typed word, DNS and duplicate checks, the public Konsol site, rollback on a certificate failure), WebDAV's internet name as an atomic transaction without a plaintext fallback, certificate status and expiry warnings, Caddy scheme parsing |
| `test_erisim.py` | Erişim's read model: each service's cells, one row per application port, warnings with their row and fix, unreadable sources as error lines; the route |
| `test_firewall_view.py`, `test_firewall_wan.py`, `test_tailnet.py` | The firewall view (socket scopes, IPv6 zones, configured rows only, WireGuard endpoints without host services), the firewall's WAN shell functions with fixtures, the tailnet allowlist and Self-only PeerAPI discovery |

### Konsol's backend and the root tools

| Module | Covers |
|---|---|
| `test_api.py` | Every route has its handler; the committed OpenAPI file and TypeScript types are what the table generates; the schema check refuses wrong shapes; routes answer with their declared shapes; nothing outside the table answers but the session check and the sign-in POST; the storage route |
| `test_konsol_auth.py` | The account store (no setup code, scrypt only, decoy work, session expiry and limits, unsafe records), the attempt limits, the root CLI and `/oturum-denetle` by channel on a Unix socket |
| `test_olaylar.py` | Live events: one producer for every stream, changed topics only, slow topics in their own thread, the per-channel limit, headers, frames, heartbeats, an internet session ending while its stream is open |
| `test_overview.py`, `test_resources.py` | The WAN rate sampler and each application's rate from its own bridge's counters, `/api/konsol/ag`; resources (unknown is never zero), Host, header and origin gates, private sockets and peer credentials |
| `test_wireguard.py` | WireGuard's routes: gates, path parameters, request shapes, the `master-wg` argument lines, audit lines, the stopped marker |
| `test_update.py`, `test_onar.py`, `test_obhut.py` | The update check (pinned commit, cache, back-off, the generation gate) and its start; `master-onar` with fake tools (check-only changes nothing, repair touches only what is broken, a stopped WireGuard left alone, `--duvar`); every `obhut` command against a fake backend and its socket client against the real one |
| `test_stage4_health.py`, `test_stage4_dns_json.py`, `test_backend_hardening.py` | The health card's decisions (required units, a failed application unit, WireGuard networks, Tailscale shapes, boot links), DNS family projections and controlled JSON failures, a connection burst before the accept loop and reserved names in Files |

### Files and folder shares

| Module | Covers |
|---|---|
| `test_text_edit.py`, `test_system_files.py`, `test_files_upload.py`, `test_stage3_files.py` | The text editor's save (version, encoding and line endings kept, owner/mode/xattrs copied, atomic), the root view (`--sistem`: read-only `/proc` and the like, delete refused at a mount point, the channel gate), the upload reserve, deep JSON and idle connections |
| `test_shares.py`, `test_share_connections.py`, `test_share_manager_networks.py`, `test_stage3_share_paths.py` | Real HTTP and descriptor isolation of WebDAV, schema 4 only (an older registry fails closed and is never rewritten), per-connection policies, nested partial saves, RW acknowledgement, rollback, the WAN publication closing with the last share |
| `test_webdav_connections.py`, `test_webdav_networks.py`, `test_stage3_webdav.py` | Per-connection authorization over loopback sockets, attempt and connection budgets, forged scope headers, the two loopback listeners on one port, concurrent logins and late preconditions |
| `test_install_hardening.py` | The installer's selective permission repair through pinned descriptors: unsafe parents, replacement races, hard links, special files |

## Browser suites and the layout audit

Konsol's Playwright suites drive the committed build in `console/yeni/` under the production CSP read
from `templates/Caddyfile`, with fixture replies for every API, and fail on any console error, CSP
violation, page error or layout finding. They never contact a server and prove no server-side change.
Playwright lives outside the repository (on the operator Mac it is a global npm package):

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node tests/yeni-ui.cjs
```

`PLAYWRIGHT_MODULE` points at the Playwright module, `PLAYWRIGHT_CHROMIUM` at a browser executable,
`KONSOL_URL` overrides a suite's address. Screenshots go to a fresh temporary folder, printed at the end.
The `yeni-*` suites share `yeni-harness.cjs`: a static server laying the build out as the installer does
(the build's files at the root, the sign-in page, the editor bundle and the marks from `console/`
beside them), the held-open event stream, fixture tables and handlers, the request log with POST bodies,
the build check (`kaynak.sha256` and the licence banner) and builders of the application and inspector
shapes with neutral `registry.example` images.

| Suite | Port | Covers |
|---|---|---|
| `yeni-ui.cjs` | 8768 | The frame and Genel Bakış: sidebar counts, the problem chip, Dikkat with each problem's place, the applications, the access summary, the network card, the event stream and polling fallback, İşlemler, the pending banner, the command palette, the theme button, the skip link, phone bars and sheets, the app manifest and no service worker |
| `yeni-uygulamalar-ui.cjs` | 8769 | Uygulamalar and an application's page: list, filters and search, reach chips, live rate, update state, the tabs Özet, Erişim, Depolama, Tanım and Günlük, actions and removal bodies, jobs in İşlemler |
| `yeni-uygulama-ekle-ui.cjs` | 8770 | Uygulama ekle (the four sources, the inspector's marks and every question kind, answers checked as they change, the plan with refusals leading to their question, the install job), Tanım's edit and "Kaynaktan yenile"; no secret value in an address, the browser's storage or a GET |
| `yeni-erisim-ui.cjs` | 8771 | Erişim's Genel, Adresler (addresses and raw ports, each sheet's exact settings body, "Adres aç", openings waiting for the 60 s banner, closings at once, deep links), Yerel adlar (the managed names read-only with their owner and link, the draft of records and forwarding, the local domain), Tailscale and Güvenlik duvarı (rules beside locked rows) |
| `yeni-wireguard-ui.cjs` | 8772 | Erişim → WireGuard: off after install, networks as tabs, devices, the planned actions with their bodies and the typed word, QR codes and profiles fetched only on a click and revoked, polling only while visible |
| `yeni-sistem-ui.cjs` | 8773 | Sistem (Sağlık with repair and Onarım kaydı, Güncellemeler with the applications' image updates, Hesap on both channels, Sunucu with the reboot, İşlem geçmişi) and Gelişmiş (Caddy, DNS, the technical firewall, Podman read-only and its cleanup with `temizle`) |
| `yeni-dosyalar-ui.cjs` | 8775 | Dosyalar: Depolama (with Uygulama verileri), Sunucu klasörleri with an in-memory files backend (uploads, moves, the real editor bundle under the CSP), Çöp kutusu, Sistem dosyaları on the tailnet only |
| `yeni-paylasim-ui.cjs` | 8776 | Dosyalar → Paylaşımlar: one card per share with its two connections, the acknowledgements' exact bodies, the create and edit sheets, removal with the typed word, deep links |
| `giris-ui.cjs` | 8766 | The sign-in page: internet sign-in failure, limit and success, the return to the page asked for, the no-account notice, the tailnet shortcut back to Konsol |

Each suite checks its screens at 1440, 390 and 320 px in both themes with no style attribute and no
horizontal scroll. `giris-ui.cjs` does not start a server; serve the installed layout on 8766 first:

```bash
preview="$(mktemp -d)"
cp -R console/yeni/. "$preview"/
cp console/giris.html console/giris.js console/giris.css console/duzenleyici.js \
   console/obhut.svg console/obhut.png "$preview"/
python3 -m http.server 8766 --bind 127.0.0.1 --directory "$preview"
# In a second terminal:
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node tests/giris-ui.cjs
```

**Layout audit (DD-270).** `duzen-denetimi.cjs` measures one page state: a horizontal page scroll, an
element past the window's edge outside a scroll box, content spilling over its box, content cut off
without an ellipsis, an ordinary word (12 characters or fewer) broken across lines, text or controls
drawn over each other, and an open dialog that neither fits the window nor scrolls. Ellipses and long
tokens wrapping in their box (addresses, digests) are counted, not reported. Every screenshot of the
`yeni-*` suites runs it at the screenshot's width; `giris-ui.cjs` runs it at each of its widths. The
sweep measures every screenshot's state again at 320, 360, 390, 768, 1024, 1280 and 1920 px:

```bash
KONSOL_DUZEN=tara KONSOL_DUZEN_CIKTI=/tmp/duzen.jsonl \
  PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node tests/yeni-uygulamalar-ui.cjs
```

`KONSOL_DUZEN_CIKTI` collects one JSON line per state, `KONSOL_DUZEN_ATLA` (a pattern of screenshot names)
leaves out a state that a resize changes, `KONSOL_DUZEN=0` turns the audit off. The harness waits for
every finite animation before a screenshot.

## Linux namespace suites

Linux and root; each refuses the host's network namespace or works only in private temporary state, and
changes no installed service, account or host firewall. A missing prerequisite is an error, never a pass.
Do not run them concurrently with an installation or another test on the same host.

```bash
unshare --net --fork python3 tests/firewall-linux.py
unshare --net --fork python3 tests/containers-network-linux.py
unshare --net --fork python3 tests/settings-linux.py
unshare --net --fork python3 tests/settings-domain-linux.py
python3 tests/settings-systemd.py
python3 tests/install-hardening-linux.py
```

- `firewall-linux.py` (iptables, ip6tables, iproute2): real packets through nested veth namespaces: the
  tailnet allowlist in both families, a second NIC's default deny, an application's Tailscale port (IPv4
  only, closed with its row), WebDAV's HTTPS renewal listener and its 16-per-address/64-total limits,
  WireGuard host isolation, forwarding and NAT, clean and repeated applies, stale rules repaired,
  third-party chains untouched, cold recovery from invalid input.
- `containers-network-linux.py` (iproute2, nftables): the container guard with Netavark-shaped
  DNAT/SNAT: an address row on `127.0.0.1`, an open raw row passing only as its own DNAT from its own
  interface, closed rows and other addresses refused, egress to the internet only, nothing on the host
  but DNS on the bridge, foreign tables preserved.
- `settings-linux.py` (iptables, ip6tables, dnsmasq, dig): the settings worker against real binaries in
  dummy interfaces: local names, forwarding, private-zone isolation, immediate DNS commit and rollback
  after a failed apply.
- `settings-domain-linux.py` (Caddy, dnsmasq, dig, curl, setpriv): real Caddy and both backends
  against scratch files: the domain's apply, rollback and confirmation, Caddy reload, the Host and header
  gates, no `health.` name.
- `settings-systemd.py`: the settings worker and its guard as real transient systemd units with a
  scratch pending record.
- `install-hardening-linux.py` (util-linux): real ownership and competing or inherited `flock`, `master-wg`
  against a private state file with a stand-in `systemctl`.

An application's real Podman and Quadlet lifecycle is not a namespace suite: it is each change's live
check on the test host.

## Live scripts

Opt-in acceptance against an authorized, disposable test host, run from a Tailscale client (the operator
Mac) with `--host <ssh name>`. They are **mutating**: each creates only its own scoped fixtures, cleans
them up and verifies the registry it touched afterwards (by SHA-256), but share edits restart WebDAV and
interrupt every transfer and playback; run outside active use and never beside an installation or a
manual share edit. Credentials and tokens stay in memory and SSH standard input and are never printed.
Calls through Caddy use a short root-issued session (`konsol_session.py`, `master-konsol oturum-ac`),
closed at the end. `konsol-login-live.py`, `panel-public-live.py` and `share-networks-live.py` exit 3
without changes on a host that does not fit; the others stop on their first check before any write.

| Script | Needs | Checks |
|---|---|---|
| `konsol-login-live.py --host H` | **no** Konsol account (exits 3 otherwise) | Konsol, Files and the root API open on the tailnet without a sign-in; a temporary internet account created through Caddy, its tailnet password change, sign-in and sign-out, the attempt limit; then the account is reset and the backend restarted |
| `panel-public-live.py --host H --domain D` | the operator's Konsol account; `D` with a DNS-only A record to the WAN IPv4 and no AAAA | Konsol published on `D` through the settings API and confirmed from Tailscale: HSTS, the sign-in page, session protection, account creation refused, one wrong sign-in; the Panel row restored exactly |
| `publications-live.py --host H` | WebDAV's internet name verified | Konsol's row refusals with their real causes, WebDAV's Tailscale switch (every template address 403 when off), its internet name off remembering the domain; every row restored |
| `https-live.py --host H --domain D [--configure]` | WebDAV's internet name `D` saved and ready (or `--configure` saves it, and it **stays saved**) | Public TLS trust, administrative routes denied, plain HTTP closed; three temporary shares (RO, RW, Tailscale-only): reads, PROPFIND, ranges, RO refusal, WAN scope, writes, both connections off |
| `share-connections-live.py --host H` | schema 4, working public HTTPS, both WebDAV transports on | One temporary share: independent RO/RW per connection, scope-header spoofing refused, both off, preserved expiry; its own WAN expiry accelerated under `install.lock` → `paylasim.lock` |
| `share-networks-live.py --host H` | WebDAV in plain HTTP WAN mode (no internet name) | Temporary shares over the real WAN and Tailscale endpoints: cross-scope refusal, RO/RW, forged Host and client address, admission and login caps, last-share pause, timed expiry |
| `backend-hardening-live.py --host H` | WAN sharing on (HTTPS or plain HTTP) | 100 requests per API with 20 parallel clients and 120 cold socket requests; a temporary RO share reading two 256 MiB files with SHA-256 and cgroup memory samples, parallel PROPFIND and ranges on each network |
| `shares-live.py prepare\|verify <manifest>\|cleanup <manifest>` | run **as root on the host** | Installed services through their real APIs with two scratch accounts and a random `/srv/dav-test-*` folder; keep the printed manifest to verify after a re-run or reboot and to clean up |

None of them certifies a fresh installation, a reboot, native Finder/Infuse clients, public DNS or ACME
on its own; record what was actually run in the change's DD entry and `CHANGELOG.md`.

**Host acceptance after an install** (Debian 13 or a supported Ubuntu) is separate: DNS answers on
loopback and on the Tailscale address, `master-firewall --check`, the built-ins and their addresses,
WebDAV PROPFIND and read-only refusal, and the public ports: WAN SSH, Tailscale UDP, each open
WireGuard network's UDP port, TCP 443 only while an internet name is configured (WebDAV keeps it for
renewal with no active folders), `SHARE_PORT` only while a folder is shared over plain HTTP, and an
application's raw internet port only while its row is open.

## Pitfalls

- `tailscale status --json` `.Self.ExitNodeOption` is not an installer assertion: it turns true only
  after the exit node is approved in the admin console. Assert `AdvertiseRoutes` containing `0.0.0.0/0`
  in `tailscale debug prefs` and report `ExitNodeOption` as information.
- An early-exiting pipe consumer under `pipefail`: `apt-config dump | awk '/x/{print; exit}'` makes the
  producer die of SIGPIPE, `pipefail` returns 141 and `set -e` ends the install. Let the consumer read the
  whole stream (`{v=$2} END{print v}`) or guard the pipeline with `|| true`; a Bats test rejects
  `| awk … exit` in the installer tree.
- A second `tailscaled` is not isolated by `--statedir`: `--state` defaults to
  `/var/lib/tailscale/tailscaled.state`, so a test daemon loads the production node's identity. Run test
  daemons in a container with the binaries bind-mounted read-only, pass `--state` explicitly and gate on
  `BackendState == NeedsLogin` before any `up`.
