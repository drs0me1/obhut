# Architecture

**Status:** the layout and data flow of Obhut generation 2, as the tree under `Data/` builds it. Read
[`contract.md`](contract.md) first: it says *what* Obhut does and refuses; this document says *where each
part lives* and *how data moves*. Rationale is in [`design-decisions.md`](design-decisions.md). The
newcomer's entry point is the repository's [`README.md`](../../README.md).

Bare paths are relative to `Data/`. Keys in capitals are declared once in `config/defaults.env`.

## Contents

1. [Layers](#1-layers)
2. [One owner per fact](#2-one-owner-per-fact)
3. [The repository](#3-the-repository)
4. [Files and folders on the host](#4-files-and-folders-on-the-host)
5. [Processes and units](#5-processes-and-units)
6. [Data flows](#6-data-flows)
7. [Locks and jobs](#7-locks-and-jobs)
8. [Decision ownership](#8-decision-ownership)
9. [OS-divergence inventory](#9-os-divergence-inventory)
10. [Verification layers](#10-verification-layers)

---

## 1. Layers

| Layer | Contents |
|---|---|
| Who connects | This server (loopback and Konsol's sockets), Tailscale devices, WireGuard devices (to the internet only), the internet |
| Gate | The firewall (`MASTER-SETTINGS`, `MASTER-INPUT`, WireGuard's `MASTER-FORWARD`/`MASTER-NAT`, the container guard's nft table), Caddy (names, certificates, Konsol's session check), dnsmasq (local names) |
| Obhut | Konsol (the built interface, the root backend on a socket, `sudo obhut`), Files (the file backend and the system files view), folder WebDAV, WireGuard (`master-wg`), the access projection, health and repair (`master-onar`), update (`master-guncelle`) |
| Application engine | YAML reader → Compose or Kubernetes reader → the model → inspector → generator → records; lifecycle jobs through the container broker and its root worker |
| Applications | Podman containers under Quadlet units, each application on its own bridge `ksl-<app>` |
| Base | Debian 13, Ubuntu 24.04 or 26.04; `kur.sh` → `install.sh`; Tailscale; Podman |

```
              operator (SSH: kur.sh, sudo obhut)          Tailscale devices          internet
                         │                                       │                       │
                         ▼                                       ▼                       ▼
                 install.sh stages 0–7                  dnsmasq (lo, tailscale0)   MASTER-INPUT (SSH, UDP,
                         │                                       │                 the one Caddy WAN port)
     ┌───────────────────┼─────────────────────┐                 ▼                       │
     ▼                   ▼                     ▼        Caddy :80 on TAILSCALE_IPV4 ◄────┘ :443 on WAN_IPV4
 config.env          state.env           units, files          │  forward_auth (session check)
 (choices)       (detected facts)        rendered once          ├─ /api/konsol/* ──► master-panel (Unix socket, root)
                         │                                      ├─ /api/sistem/* ──► master-sistem-dosya (socket, root)
                         ▼                                      ├─ /api/*        ──► master-files-panel (127.0.0.1)
          firewall, Caddy, dnsmasq, backends                    ├─ pages         ──► CONSOLE_WEB_DIR
                                                                ├─ paylas.       ──► master-paylasim (127.0.0.1)
                                                                └─ <name>.       ──► 127.0.0.1:<pool port> ──► container
```

## 2. One owner per fact

- **Ports, paths, chain names and limits of the base:** `config/defaults.env`, written into `state.env`.
  A literal repeated elsewhere is a bug.
- **Konsol's request and reply shapes:** the route table in `panel/master_api.py`; `docs/konsol-api.json`
  and `tools/konsol-ui/src/api/sema.ts` are generated from it.
- **An application:** its record under `UYGULAMA_STATE_DIR/<app>/` (the file, the answers, the checked
  definition, the allocations, the access rows). Units, Caddy sites, DNS names and guard rules are derived
  from it, never edited by hand.
- **Confirmed choices** (operator firewall rules, DNS records and forwarding, the local domain, the fixed
  rows of Konsol and Paylaşımlar): `SETTINGS_FILE`, written only by the settings transaction.
- **Folder accounts and policies:** `SHARE_STATE_FILE`, written only by `master_shares.py`.
- **The Konsol account and sessions:** `KONSOL_AUTH_DIR`, through `master_auth.py`.
- **WireGuard:** `WG_CONF_DIR` (networks file, stopped marker, per-network configuration and profiles),
  written only by `master-wg`.
- **One home per object in the interface:** an application on its page, an address in Erişim, a folder in
  Dosyalar; other places show a summary and a link.

## 3. The repository

### 3.1 Layout

```
.
├── kur.sh                  server bootstrap: downloads the archive, places the runtime tree, starts install.sh (DD-228)
├── wireguard.command       WireGuard peer menu over SSH (macOS; calls master-wg)
├── onar.command            "Denetle ve onar" over SSH (macOS; DD-239)
├── kurulum/                Git-ignored: kurulum.env (SSH_HOST) and downloaded device profiles
├── README.md, CLAUDE.md    entry points
├── .cursor/rules/          working rules for assistants (not shipped)
└── Data/
    ├── install.sh          orchestrator: gates, the domain, stages 0–7, summary
    ├── common.sh           logging, die, root and OS gates, the lock, bounded retry, atomic writes, templates
    ├── config/             defaults.env (single source of truth); kurulum.env.example (the Mac's SSH host)
    ├── templates/          Caddyfile, dnsmasq.conf, paylasim.caddy, paylasim-dnsmasq.conf
    ├── scripts/            firewall.sh (→ master-firewall), master-wg, refresh-tailnet-config, wait-tailnet-addr,
    │                       tailscale-udp-gro, master-guncelle, master-onar, master-konsol, obhut
    ├── systemd/            units, timers and the wg-quick@ drop-in
    ├── panel/              the root backend master-panel and its modules (below)
    ├── files-panel/        master-files-panel (the file backend and, with --sistem, the system files view)
    ├── console/            the sign-in page, the editor bundle, the marks and yeni/ (Konsol's committed build)
    ├── tools/konsol-ui/    Konsol's Vue 3 + TypeScript + Vite sources (not shipped)
    ├── tools/duzenleyici/  the CodeMirror 6 editor bundle's sources (not shipped)
    ├── tests/              bats, Python, browser and Linux suites (not shipped; tests/README.md)
    ├── docs/               contract, architecture, design decisions, folder shares, rebuild plan, API, archive/
    ├── CHANGELOG.md        change history (not shipped)
    └── OKUBENI.txt         the operator's Turkish notes (not shipped)
```

`kur.sh` places only `install.sh`, `common.sh`, `config`, `templates`, `scripts`, `systemd`, `panel`,
`files-panel` and `console` on the host, under `/root/debian-server-installer`.

### 3.2 One sentence per file

| File | Job | Deliberately does not know |
|---|---|---|
| `install.sh` | The gates, the domain question, the stages in order, the summary | What a firewall rule or a Caddy directive looks like |
| `common.sh` | Logging, `die`, `require_root`, `require_supported_os`, `acquire_lock`, `retry`, `atomic_write`, `render_template` | Any fact of the stack |
| `config/defaults.env` | Every base constant once | How any of them is used |
| `templates/Caddyfile` | The `(konsol)` routes (session check, sockets, file backend, pages and headers), the tailnet site, the WAN listener options, the admin socket, proxy logging, `import CADDY_MODULES_DIR/*.caddy` | The Tailscale address (read as `{$TAILSCALE_IPV4}` at start); applications |
| `templates/dnsmasq.conf` | The resolver on `lo` and `tailscale0` and the base name `panel.` | The current address (`bind-dynamic` and `interface-name` follow it) |
| `templates/paylasim.caddy`, `templates/paylasim-dnsmasq.conf` | WebDAV's tailnet site (`paylas.` and `TAILSCALE_IPV4:SHARE_PORT`) and its name | Folders, accounts, the internet side |
| `scripts/firewall.sh` → `master-firewall` | `apply` and `--check` of the project chains, the operator's rules, WireGuard's rules from its registry and the container guard | Other software's chains; the Tailscale address (it matches the interface) |
| `scripts/master-wg` | WireGuard networks and peers, profiles and QR codes, start and stop as a whole; the settings worker's caller mode | Installer input; anything on the Mac |
| `scripts/refresh-tailnet-config` | Tailscale address changes into `state.env` and a Caddy restart; the firewall watchdog, failed Caddy and WireGuard recovery, the applications' address refresh | General health, file drift |
| `scripts/wait-tailnet-addr` | Caddy's `ExecStartPre`: wait until `tailscale0` carries the state's IPv4, fail fast on a stale one | Caddy's configuration |
| `scripts/tailscale-udp-gro` | The two ethtool flags on the default-route interfaces | Tailscale itself |
| `scripts/master-guncelle` | The update unit's work: the pinned commit's `kur.sh` in update mode, its result file | Which version to offer |
| `scripts/master-onar`, `panel/master_onar.py` | Denetle ve onar: 21 fixed steps, a report, journal lines | Anything a step does not name |
| `scripts/master-konsol`, `panel/master_auth.py` | The Konsol account, sessions, sign-in budgets; the root CLI | Passwords or tokens in clear text; roles |
| `scripts/obhut`, `panel/master_obhut.py` | `sudo obhut`: state and recovery through Konsol's socket | TCP, a shell, timed confirmations |
| `panel/master-panel` | The root backend on `PANEL_SOCKET`: gates, the session check, the route table's handlers, read models, samplers, job and worker dispatch | Static pages; any TCP listener; system writes (workers do them) |
| `panel/master_api.py` | The route table with request and reply shapes; OpenAPI and TypeScript generation | The handlers |
| `panel/master_settings.py` | The settings transaction: validate, plan, apply, confirm, roll back, the guard; DNS projection and the operator's rules for the firewall | Arbitrary commands; secrets |
| `panel/master_publications.py` | The access projection's content: the fixed rows, the applications' Caddy sites and DNS file; the `erisim` section's checks and plan text | ACME (Caddy owns it); public DNS writes |
| `panel/master_https.py` | Internet-name validation, the bounded DNS check, the pinned certificate probe, WebDAV's internet site | Keys and renewal |
| `panel/master_shares.py` | The folder-share registry and its changes; the projection's writer (`publish`) and its 30 s guard | Plain passwords |
| `panel/master_webdav.py` | The unprivileged WebDAV server on two loopback listeners | The registry's writer |
| `panel/master_erisim.py` | `GET /api/konsol/erisim`: who reaches what from where | Probes or changes of its own |
| `panel/master_olaylar.py` | One producer for every Server-Sent Events stream | Topics' content |
| `panel/master_update.py` | The update offer (GitHub, generation, build number) and the update unit's state | Installer code |
| `panel/master_wireguard.py` | Konsol's WireGuard routes over `master-wg`; the `wireguard` settings section's checks and plan text | Keys in listings |
| `panel/master_yaml.py` | The YAML subset reader | Compose or Kubernetes |
| `panel/master_compose.py`, `panel/master_kube.py` | A file's documents → the one application model, refusals and notes with lines | Answers, the host |
| `panel/master_inspector.py` | The model → questions, guesses, refusals; answers → the checked definition and the secret values | The server's state (names taken, folders) |
| `panel/master_generator.py` | The definition and allocations → every unit, environment file, folder, bind and publication (pure) | Files, commands, clocks |
| `panel/master_applications.py` | Records, the pool, the guard's input, access rows, names taken, read models, install summaries, drafts, sizes, the cleanup's items | Running anything that writes |
| `panel/master_container_manager.py` | The inventory and the applications' read model in the backend; the job broker (transient units, at most four jobs) and the image update check | Writes (the worker does them) |
| `panel/master_container_worker.py` | Every container write: install, start, stop, restart, update, edit, remove, drafts, the cleanup, access-row unit changes, `--adres-yenile` | Reconciliation |
| `panel/master_container_network.py` | The container guard's nft table: apply and exact check | Netavark's NAT; other tables |
| `panel/master_container_binds.py` | A unit's `ExecStartPre`/`ExecStopPost`: pin `/srv` bind sources onto anchors | Which folders may be bound (the inspector decides) |
| `panel/master_containers.py` | Read-only Podman mapping, listening sockets, the manifest-only update check | Starting or stopping anything |
| `panel/master_container_config.py` | Shared errors, private file helpers, systemd quoting, the managed label | Applications |
| `panel/master_permissions.py` | The installer's descriptor-pinned folder creation and selective owner/mode repair (run from the tree) | Symlinks, special or multiply linked files |
| `files-panel/master-files-panel` | The file API for `SERVER_ROOT` as the Files account; with `--sistem` the same API for `/` as root on a socket | Shares, credentials, WireGuard |
| `console/giris.*` | The internet name's sign-in page, in Konsol's colours with `/tema.js` | Any other data |
| `console/yeni/`, `tools/konsol-ui/` | Konsol's interface: six sections, palette, İşlemler, the pending banner, the new-build notice (`src/build.ts`: its own files' ETag looked at again when the build number changes or the tab comes back, **DD-280**); `kaynak.sha256` ties the build to the sources | Inline code, external loads, application names |
| `console/duzenleyici.js`, `tools/duzenleyici/` | The text editor, loaded when the first file opens | Requests of its own |
| `systemd/` | Ordering, coupling, restart and schedules | The scripts they start |

### 3.3 Placeholder convention

Templates use `__NAME__` tokens, never `${NAME}` (systemd expands it) or `{$NAME}` (Caddy expands it at
start from `state.env`). `render_template` substitutes, writes a temporary file, sets the mode and renames
it; an unfilled token is a hard error.

---

## 4. Files and folders on the host

### 4.1 `config.env` and `state.env`

| | `config.env` (`CONFIG_FILE`) | `state.env` (`STATE_FILE`) |
|---|---|---|
| Holds | `LOCAL_DOMAIN`, `TIMEZONE` | Detected facts (WAN interface and addresses, Tailscale addresses, OS identity, kernel) and every runtime constant the tools read (ports, paths, chains, WireGuard defaults, limits, the generation, the versions) |
| Written by | the installer, once per run | the installer each run; `refresh-tailnet-config` (Tailscale addresses only); the settings worker (`LOCAL_DOMAIN` only, on a confirmed rename) |
| Read by | the installer | the firewall, Caddy (`EnvironmentFile=`), every backend, worker and tool |
| Secrets | none | none |

`state.env` must parse in bash and in systemd: plain `KEY=value`, lists in double quotes. It holds current
facts only; the WAN address is detected again on every run.

### 4.2 The host layout

| Path (key) | Written by | Contents |
|---|---|---|
| `/root/debian-server-installer` | `kur.sh` | the runtime tree the installer runs from |
| `/etc/master-stack/` (`STATE_DIR`) | installer | `config.env`, `state.env` (0600), `nesil` (`NESIL_FILE`) |
| `SETTINGS_FILE` (`ayarlar.json`), `SETTINGS_PENDING_FILE` (`ayarlar-bekleyen.json`) | settings worker | confirmed choices; the pending change with its file snapshots (root only) |
| `SHARE_STATE_FILE` (`webdav.json`, `.pending`) | `master_shares.py` | folder accounts (scrypt), both connection policies, folder identity; 0600 |
| `KONSOL_AUTH_DIR` (`/etc/master-stack/konsol/`) | backend, `master-konsol` | `hesap.json`, `oturumlar.json`, `.kilit`; 0700/0600 |
| `KONTEYNER_STATE_DIR` (`/etc/master-stack/containers/`) | container worker | `operations/<id>.json` (job records with their logs, never requests) |
| `UYGULAMA_STATE_DIR/<app>/` | container worker, settings worker (rows) | `kaynak.yaml`, `kaynak.json`, `yanitlar.json`, `tanim.json`, `yerler.json`, `erisim.json`, `env/<service>.env`; 0700/0600 |
| `UYGULAMA_VERI_DIR/<app>/<folder>/` (`/var/lib/master-stack/uygulamalar/`) | container worker | applications' data; 0700 root, the service's own user inside |
| `KONTEYNER_BIRIM_DIR` (`/etc/containers/systemd/`) | container worker | `konsol-<app>.network`, `konsol-<app>_<service>.container`, `konsol-<app>.pod` |
| `/var/lib/containers/storage/` | Podman | images (pinned by digest), layers, volumes; Podman's secret store (`obhut_<app>_<hex>`) |
| `KONTEYNER_BAGLAMA_DIR/<container>/<hash>` | `master_container_binds.py` | bind anchors of running services; recreated at every start, gone at reboot |
| `CADDYFILE` (`/etc/caddy/Caddyfile`) | installer | the base Caddyfile |
| `CADDY_MODULES_DIR` (`/etc/caddy/moduller/`) | installer, the access projection | `paylasim.caddy`, `paylasim-wan.caddy`, `panel-wan.caddy`, `uygulama-<app>.caddy`, `uygulama-<app>-wan.caddy` |
| `SHARE_CADDY_SOURCE` | installer | WebDAV's tailnet site, filled; the projection filters it into `CADDY_MODULES_DIR` |
| `DNSMASQ_CONF_DIR` (`/etc/dnsmasq.d/`) | installer, settings worker, the projection | `local-services.conf` (`DNSMASQ_CONF_FILE`), `modul-paylasim.conf`, `modul-uygulama.conf`, `konsol.conf` (`SETTINGS_DNS_FILE`) |
| `CONSOLE_WEB_DIR` (`/usr/local/share/master-stack/konsol/`) | installer | Konsol's pages, nothing else |
| `SBIN_DIR` (`/usr/local/sbin/`) | installer | the scripts, `master-panel`, `master-files-panel` and every `master_*.py` module |
| `UNIT_DIR` (`/etc/systemd/system/`) | installer | the units and timers of `systemd/`; drop-ins `caddy.service.d/`, `dnsmasq.service.d/`, `wg-quick@.service.d/`, `apt-daily-upgrade.timer.d/` (`APT_UPGRADE_TIMER_DROPIN`) |
| `WG_CONF_DIR` (`/etc/wireguard/`, 0700) | installer (folder), `master-wg` | `networks` (`WG_NETWORKS_FILE`), `.durduruldu` (`WG_STOPPED_FILE`), `wgN.conf`, `clients-wgN/` |
| `WG_MODULES_LOAD_FILE`, `TCP_MODULES_LOAD_FILE` | installer | kernel modules loaded at boot |
| `SYSCTL_NETBUF_FILE`, `SYSCTL_FORWARD_FILE`, `SYSCTL_TCP_FILE` | installer | sysctl drop-ins sorting last |
| `APT_PERIODIC_FILE`, `APT_UNATTENDED_POLICY_FILE`, the Tailscale and Caddy apt sources and keyrings | installer | update policy and repositories |
| `/etc/systemd/resolved.conf.d/master-stack.conf` | installer (only where resolved runs) | `DNSStubListener=no` |
| `SERVER_ROOT` (`/srv`) | installer (folders), the Files account's services | `downloads`, `media/{movies,series}`, `.cop/<id>/` + `<id>.json` (the trash) |
| `RUNTIME_DIR` (`/run/master-stack/`) | every tool | the locks of §7, `share-network-applied.json` (the projection's marker), short-lived temporary files |
| `PANEL_SOCKET`, `SYSTEM_FILES_SOCKET`, `CADDY_ADMIN_SOCKET` | their services | the three Unix sockets |
| `LOG_DIR` (`/var/log/master-setup/`) | installer, `master-guncelle`, `master-onar` | `install.log`, `GUNCELLEME_DURUM_FILE`, `GUNCELLEME_LOG_FILE`, `ONARIM_DURUM_FILE` |

Two absences are decisions: there is no rendered Caddy environment file (Caddy reads `state.env`, so the
address is in one file, **DD-61**), and there is no canonical copy, generation pointer or restore manifest
of any managed file (a re-run is the repair).

---

## 5. Processes and units

### 5.1 Long-running services

| Service | User | Listens | Notes |
|---|---|---|---|
| `tailscaled` | root | Tailscale's UDP port, `tailscale0` | the package's unit |
| `caddy` | caddy | `TAILSCALE_IPV4`:80, `:SHARE_PORT`, Tailscale ports; `WAN_IPV4`:443 or `:SHARE_PORT` when published; admin socket | package unit + drop-in (§8 of the contract) |
| `dnsmasq` | dnsmasq | `127.0.0.1:53`, the Tailscale address | package unit + drop-in |
| `master-panel` | root | `PANEL_SOCKET` | threads: the request handlers, the resource sampler (CPU, WAN and each application bridge every 10 s), WireGuard's sampler, the event producer, the background image check |
| `master-files-panel` | the Files account | `127.0.0.1:FILES_PANEL_PORT` | strict sandbox, loopback only |
| `master-sistem-dosya` | root | `SYSTEM_FILES_SOCKET` | no network |
| `master-paylasim` | the Files account | `127.0.0.1:SHARE_PORT`, `SHARE_WAN_BACKEND:SHARE_PORT` | the registry as a credential |
| `konsol-<app>_<service>` | root (Podman) | the container's ports inside its bridge; publications per row | the service's own start mode inside |

### 5.2 Oneshots and timers

`master-firewall` (boot, tailscaled restarts, every writer that changes rules), `tailscale-udp-gro` (boot),
`wg-quick@wgN` (each enabled network), `refresh-tailnet-config` (timer, Caddy's `OnFailure`,
`master-onar`), `master-duvar-denetim` (hourly), `master-share-network` (every 30 s),
`master-settings-guard` (every 2 s while a change is pending), and the distribution's `apt-daily` timers.

### 5.3 Transient units

| Unit | Started by | Runs | Limit |
|---|---|---|---|
| `master-container-<id>` | the broker | `master_container_manager.py … <action>` → the worker | 1800 s (cleanup 900 s) |
| `master-container-adres-yenile` | `refresh-tailnet-config` | `master_container_worker.py --adres-yenile` | 1800 s |
| settings worker (`systemd-run --wait --pipe`) | the backend | `master_settings.py apply|confirm|rollback|discard` | 150 s, 1800 s for an access row |
| share worker (same) | the backend | `master_shares.py save|remove` | 150 s |
| `GUNCELLEME_UNIT` | the backend | `master-guncelle uygula <commit> <version>` | — |
| `ONARIM_UNIT` | the backend | `master-onar --kaynak konsol [--denetle]` | — |
| `master-yeniden-baslat` | the backend | `systemctl reboot` after 5 s | — |

Each worker gets its request as JSON on standard input, never in argv, the environment or the journal.
The backend's own sandbox (`ProtectSystem=full`: `/usr`, `/boot` and `/etc` read-only except `WG_CONF_DIR` and
`KONSOL_AUTH_DIR`) is why every system write leaves it for a worker unit.

---

## 6. Data flows

### 6.1 An install

```
kur.sh ── archive ──► /root/debian-server-installer ──► install.sh (under systemd-inhibit)
  stage 0  gates → domain → confirmation → NESIL_FILE, config.env
  stage 1  apt: base, Podman, WireGuard tools
  stage 2  Tailscale (repository, login, preferences)
  stage 3  addresses → state.env; /srv folders and ownership
  stage 4  modules and tools → SBIN_DIR; units; WireGuard's drop-in and module
  stage 5  master-firewall (+ container guard)
  stage 6  dnsmasq files → the operator's records (project-dns) → dnsmasq --test; Caddyfile, WebDAV's site → filter → caddy validate;
           CONSOLE_WEB_DIR; master-panel, master-files-panel, master-sistem-dosya, master-paylasim
  stage 7  built-ins proven → master_shares.py publish (the access projection) → WireGuard networks → checks
```

### 6.2 A request through Caddy

A tailnet device asks dnsmasq for `panel.<domain>` and gets the Tailscale IPv4. Caddy's site imports the
`(konsol)` routes with the channel `tailscale`:

1. `forward_auth` (unless the path is one of the open sign-in files) asks `master-panel`'s socket
   `GET /oturum-denetle`, with the original URI, the client address, `Host: panel.<domain>` and the
   channel. The backend's gate checks the Host, that the client is another Tailscale device (or, on the
   internet channel, that Konsol's internet row is active and the client is not the server), the path's
   segments and `X-Konsol` on `/api/*`; the session gate answers 204, 302 or 401 (contract §6.3).
2. `/api/konsol/*` goes to the same socket with `X-Forwarded-Host`; the backend matches the route table,
   checks the body's shape and calls the handler. Reads come from read models; writes go to a worker
   (§5.3).
3. `/api/sistem/*` (tailnet site only) goes to `SYSTEM_FILES_SOCKET`; the view checks the channel and the
   client again.
4. Any other `/api/*` goes to `127.0.0.1:FILES_PANEL_PORT`.
5. Everything else is a file of `CONSOLE_WEB_DIR` with the CSP and cache headers.

An internet request arrives on `WAN_IPV4:443` for Konsol's internet name (`panel-wan.caddy`), passes
`MASTER-SETTINGS`' connection limits and `MASTER-INPUT`'s single WAN port, and imports the same routes with
the channel `internet`.

An application's address: `<name>.<domain>` → Caddy (`uygulama-<app>.caddy`) → `127.0.0.1:<pool port>` →
the host's output DNAT (Netavark) → the container port on `ksl-<app>`. Its internet name takes the same
path from `WAN_IPV4:443` (`uygulama-<app>-wan.caddy`). A raw port takes no Caddy: the client reaches the
Tailscale or WAN address on the host port, Netavark DNATs it in `PREROUTING`, and the container guard's
forward chain lets in exactly that publication.

### 6.3 Adding an application

```
Konsol "Uygulama ekle"
  POST uygulamalar/kaynak         (address: fetched and checked here; image: a draft job; container: a draft)
  POST uygulamalar/denetle        inspector: refusals, questions, the checked definition (nothing written)
  POST uygulamalar/kur {plan}     the worker's install checks in the backend, read-only commands only
  POST uygulamalar/kur            checks again → broker → systemd-run master-container-<id> (request on stdin)
     worker (install.lock + KONTEYNER_LOCK): record → guard apply → folders → pull and pin → Podman secrets
       → generator → env files → Quadlet dry run → units → daemon-reload → start in order → ready (300 s)
       → master_shares publish (Caddy sites, DNS names, firewall, Caddy reload) → [takeover: old container removed]
     every step and fact is a line of the job's log; a container that does not come up adds its own last lines
     (journalctl CONTAINER_NAME=…, the job's secret values masked) before the rollback
     on failure: everything the job made is undone in reverse; the job record names the step (and a direct
     start's question)
  GET konteynerler/islem?id=… every second: the page's Kurulum step shows the log; the event stream's
  "islemler" follows the job in İşlemler
```

### 6.4 An access change

```
Erişim sheet ─ POST ayarlar/plan ─► master_settings.plan (in the backend: checks on a copy)
             ─ POST ayarlar/uygula ─► systemd-run master_settings.py apply (stdin; install/settings/state locks)
                 prepare (validate, master_publications.section) → guard timer on → pending file + snapshots
                 → erisim: master_container_worker.Manager.row_change (KONTEYNER_LOCK): units, restart, ready
                 → master-firewall (+ guard) → publish (paylasim.lock) → certificate wait for a new internet name
                 → closing change: commit at once │ opening change: phase "awaiting", 60 s
Pending banner ─ POST ayarlar/onayla (Tailscale only) ─► commit (SETTINGS_FILE, pending file removed)
master-settings-guard.timer (2 s) ─ deadline passed / reboot ─► rollback: files back, row_restore,
                 firewall, publish, files back again
```

A fixed row (`web`) goes the same way without the container side; WireGuard's actions run `master-wg` in
its caller mode with the held `install.lock` descriptor; DNS-only changes project `konsol.conf`, test and
restart dnsmasq and commit at once; a domain rename rewrites its tokens and waits 300 s for confirmation
through the new name.

### 6.5 The container guard

`master-firewall apply` (and the container worker and settings worker, under their locks) run
`master_container_network.py apply`: it reads every application record (`guard_input`: each bridge, its
pool publications on `127.0.0.1` and its open raw publications), reads the host's current Tailscale and
WAN addresses when a raw publication needs them, builds the table (input chain: the host closed to
bridges except replies and gateway DNS; forward chain: egress to the internet only, same-bridge traffic,
one DNAT-exact permit per raw publication on an address the host has, then drop), replaces the table in one
nft transaction and compares the result exactly. `master-firewall --check` and every application unit's
`ExecStartPre` run the same comparison without writing; a unit that finds the guard missing fails and is
retried every 10 s.

### 6.6 Address changes

`refresh-tailnet-config` reads `tailscale0`'s addresses after `tailscale wait`, rewrites only
`TAILSCALE_IPV4`/`TAILSCALE_IPV6` in `state.env` under `state.lock`, restarts Caddy and starts
`--adres-yenile`, which rewrites the units of applications whose raw Tailscale or internet ports publish on
an older address. dnsmasq and the firewall match the interface by name and need nothing. The WAN address is
not tracked live (contract §5.6).

### 6.7 Folder WebDAV

```
Dosyalar → Paylaşımlar ─ POST paylasim/kaydet|kaldir ─► systemd-run master_shares.py (stdin;
    install.lock + paylasim.lock; refused while a settings change is pending)
  → registry .pending snapshot → webdav.json (0600) → restart master-paylasim (wait for its 401)
  → publish (WebDAV's internet site, firewall) → snapshot removed; on failure the old registry comes back
master-paylasim (Files account) ◄─ LoadCredential registry ─ systemd
  127.0.0.1:SHARE_PORT          ◄─ Caddy paylas.<domain>, TAILSCALE_IPV4:SHARE_PORT  (Tailscale policy)
  SHARE_WAN_BACKEND:SHARE_PORT  ◄─ Caddy WAN_IPV4:443 /s/* (or legacy :SHARE_PORT)  (internet policy)
```

---

## 7. Locks and jobs

| Lock | Taken by | Wait |
|---|---|---|
| `RUNTIME_DIR/install.lock` | the installer (the whole run); the settings worker; the share manager and its guard; container jobs and the address refresh; `master-wg` (unless in caller mode); probed by `kur.sh` | installer 5 s; settings and shares fail at once ("biraz sonra yeniden deneyin"; the guard skips its round); container jobs 5 s; `master-wg` 10 s; `kur.sh` refuses |
| `RUNTIME_DIR/settings.lock`, `state.lock` | the settings worker; `state.lock` also `refresh-tailnet-config` | non-blocking; the refresh leaves the round |
| `RUNTIME_DIR/paylasim.lock` | the share manager (change, guard); the settings worker around `publish` | non-blocking |
| `KONTEYNER_LOCK` (`containers.lock`) | container jobs; the settings worker's container side of a row change | 5 s |
| `RUNTIME_DIR/firewall.lock` | `master-firewall` | 5 s |
| `RUNTIME_DIR/onarim.lock` | `master-onar` | 120 s for a requested run, none for the hourly check |
| `KONSOL_AUTH_DIR/.kilit` | `master_auth` (backend and `master-konsol`) | blocking, short |

Order: `install.lock` first, then the specific lock. The pending settings change is itself a gate: the
installer, share changes, application jobs and every `master-wg` verb that changes WireGuard's state or the
files the plan restores (`net-add`, `net-remove`, `net ac|kapat`, `net-settings`, `reset`, `durdur`, `baslat`;
outside the caller mode, which accepts only the worker's own change while it is applied or rolled back)
refuse while it exists; the peer verbs do not.

Jobs: at most four container jobs at once and one per target; a job's record lives in
`KONTEYNER_STATE_DIR/operations/` and the broker keeps at most 256 records in memory; İşlemler shows running
jobs and those finished in the last two minutes, with the update and the repair.

---

## 8. Decision ownership

| Question | Single answerer |
|---|---|
| What are the WAN and Tailscale addresses? | `install.sh` (write), `refresh-tailnet-config` (Tailscale update) |
| Is the firewall policy in force? | `master-firewall --check` |
| Is the container guard in force? | `master_container_network.py --check` (inside `master-firewall --check`) |
| Has the Tailscale address changed? | `refresh-tailnet-config` |
| May this port be taken? | `config/defaults.env` for the base; `master_publications.port_problem` and `master_applications.row_conflict` for rows |
| Is this Tailscale name free? | `master_applications.taken_names` |
| What is an application's state? | its record (`master_applications.Records`) and systemd's units |
| Is a service healthy? | nobody continuously: systemd's `Restart=`; Konsol's health card only reports; `master-onar` on request |
| Has a managed file drifted? | nobody: a re-run is the repair |
| Is the stack working end to end? | stage 7, once per run |

---

## 9. OS-divergence inventory

Every point where behaviour depends on the distribution is marked in `install.sh` with
`# OS-DIVERGENCE: <slug>` and listed here; `bats` asserts that the two sets are equal. Prefer capability
probes; use distribution identity only to pick repository suites (**DD-102**, **DD-104**).

<!-- OS-DIVERGENCE-INVENTORY:BEGIN -->

| Slug | Kind | Affects | What differs | DD |
|---|---|---|---|---|
| `tailscale-repo-suite` | identity-derived | both | apt suite and keyring URL come from `OS_ID`/`OS_CODENAME`; both vendors publish the same URL shape | DD-102 |
| `ufw-gate` | probe | ubuntu in practice | ufw active is a fail-closed stop; no package, no-op | DD-102 |
| `netfilter-binaries` | probe | debian | a minimal Debian image ships no `iptables`; stage 0 checks only what exists, stage 1 makes it mandatory | DD-108 |
| `needrestart-suspend` | probe-free no-op | ubuntu | `NEEDRESTART_SUSPEND=1`; Debian has no needrestart, so the variable is unread | DD-103 |
| `resolved-stub` | probe | ubuntu in practice | `DNSStubListener=no` written only when resolved is active; on Debian the whole block is skipped and no drop-in is created. Ubuntu 26.04 / systemd 259 accepts and ignores the key, so the achieved state is read back and reported rather than assumed | DD-102, DD-109 |
| `resolvconf-symlink` | probe | ubuntu | `/etc/resolv.conf` is repointed only when it targets the stub; Tailscale takes the file over later | DD-102 |

<!-- OS-DIVERGENCE-INVENTORY:END -->

The Caddy repository line (`any-version`, distribution-agnostic) is deliberately not a divergence.

---

## 10. Verification layers

| Check | Scope | On the workstation |
|---|---|---|
| `bash -n`, `shellcheck -x` | `install.sh`, `common.sh`, `scripts/*`, `kur.sh`, the `.command` files | yes |
| `bats tests` | shell and contract checks | yes, with explicit skips for missing Linux tools |
| Python unit tests, browser suites with the layout audit (**DD-270**) | backends, engine, interface against fixtures | yes |
| TypeScript build and `kaynak.sha256` | Konsol's sources and the committed build | yes |
| `caddy validate`, `dnsmasq --test` | the rendered files | no: stage 6 runs them on the target with real values (**DD-106**) |
| `systemd-analyze verify`, nft, iptables | units and rules | no: the Linux suites only |
| Live checks on the test host | everything above, installed | no |

A missing validator is reported as not verified, never as a pass. Commands and what each suite covers are
in [`../tests/README.md`](../tests/README.md).
