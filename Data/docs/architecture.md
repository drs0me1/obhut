# Architecture

**Status:** current architecture for the installer tree under `Data/`.
Read [`contract.md`](contract.md) first — that document says *what* the installer
does; this one says *where each part of it lives* and *how data moves*.
Operator entry point: [`README.md`](../../README.md).

**v2-130 (DD-160):** [Model A](model-a-clean-install.md) is a single-workspace
admin panel, not a desktop launcher. `panel.css` styles the sidebar and resource
meters. Host CPU sampling runs independently of WireGuard; the resources API
does not enumerate networks, ports or invoke external commands. The old
`/api/wg/sistem` remains compatible. One Settings controller renders either
system settings or the qBittorrent application form. **DD-165:** account-only
Save uses the same worker but commits directly; other drafts remain separate
and unapplied. Folder/network edits retain their confirmation flow.

**Built-ins (DD-159/166/170):** Files, folder WebDAV and archive tools are built in.
Creation produces ZIP; extraction automatically detects multipart RAR and nested
ZIP/RAR, with internal safety limits. The App Store
catalogue contains WireGuard/qBittorrent only. Internal `dosya`/`paylasim` paths
and registry IDs remain for compatibility, not public lifecycle operations.
The [desktop/archive architecture](desktop-and-archives.md) supplements this
document with the archive API and its security boundaries.

v1's structural problem was not its size but its ownership model: the same
fact (a port number, a container name, an expected binding) was asserted in
three or four places, and the same decision (is this healthy?) was made by
the installer, by a helper and by a final test. The rule is one owner per
fact and one owner per decision.

---

## 1. Data flow

```
                     operator input
                   (SSH host, local domain)
                            │
                            ▼
              ┌──────────────────────────────┐
              │  /etc/master-stack/config.env│   persistent choices
              │  (rendered from              │   survives re-runs
              │   config/defaults.env)       │
              └──────────────┬───────────────┘
                             │
                             ▼
                    address detection
                    (install.sh + refresh-tailnet-config)
              WAN if + WAN IPv4, tailscale0
                    IPv4 + IPv6
                             │
                             ▼
              ┌──────────────────────────────┐
              │  /etc/master-stack/state.env │   detected runtime facts
              │  (regenerated every run and  │   never hand-edited
              │   by refresh-tailnet-config) │
              └──────────────┬───────────────┘
                             │
        ┌────────────┬───────┴────────┬──────────────┐
        ▼            ▼                ▼              ▼
    modules/<id>  dnsmasq conf     Caddyfile     firewall
                  (lo +          (TAILSCALE_    (in memory)
                   tailscale0)    IPV4:80)
        │            │                │              │
        ▼            ▼                ▼              ▼
   master-modul   dnsmasq         caddy         MASTER-INPUT
   (from Konsol;   .service        .service      MASTER-FORWARD
    on loopback)
```

Only Caddy binds the Tailscale address (including Infuse
`${TAILSCALE_IPV4}:${SHARE_PORT}/s/<id>/`). dnsmasq and the firewall are written against
the *interface name*, and WebDAV binds loopback only (**DD-77** / **DD-98**).
That is what makes an address change a Caddy-only restart rather than a
stack-wide one.

Panel choices have a separate owner: `master_settings.py` commits firewall,
DNS and domain overrides to `/etc/master-stack/ayarlar.json`, which the installer
and service renderers preserve on re-runs. The domain takes precedence over old
installer input. qBittorrent account/path changes are written to its own profile.
The independent settings guard handles unconfirmed transactions; DNS-only and
account-only applies commit directly. WebDAV credentials go through
`master_shares.py` into a separate hash-only registry (§4).

---

## 2. `config.env` versus `state.env`

Two files, two lifetimes, two owners. Conflating them is what made v1's
`state.env` carry both a schema version and a frozen `WG_ENDPOINT_HOST` that
later became a permanent drift alarm.

| | `config.env` | `state.env` |
|---|---|---|
| **Path** | `/etc/master-stack/config.env` | `/etc/master-stack/state.env` |
| **Contains** | Effective local domain and timezone | Detected facts plus runtime constants: WAN interface/addresses, `TAILSCALE_IPV4/6`, install version, paths/ports; `WG_ENDPOINT_HOST` equals the current `WAN_IPV4` (**DD-138**) |
| **Source** | `config/defaults.env` + the installer input file `kurulum/kurulum.env` (**DD-119**) | installer / `refresh-tailnet-config` at run time |
| **Written by** | The installer, once per run | The installer, and `refresh-tailnet-config` when an address changes |
| **Lifetime** | Persistent; each run resolves defaults/input and any confirmed panel domain, then rewrites it | Regenerated from current constants and detected facts |
| **Hand-editable** | No — initial domain comes from installer input; later domain changes use Settings | No — it will be overwritten |
| **Read by** | The installer, template rendering | The installer, `master-firewall`, Caddy (`EnvironmentFile=`), `refresh-tailnet-config` |
| **Contains secrets** | **No** | **No** |

`config.env` is not a port editor. Constants live in `config/defaults.env`;
WireGuard network ports live in `/etc/wireguard/networks`. Panel overrides live
in `ayarlar.json`. Changing a detected address is not a human action.

**Why v1's frozen `WG_ENDPOINT_HOST` is not repeated:** a detected value
recorded in a file and then compared against reality on every cycle produces
a permanent failure the moment the provider changes the IP. In v2 the
public IPv4 lives in `state.env` as a *current* fact that is simply
re-detected, never as an expectation to be violated.

---

## 3. File responsibilities

### 3.1 Repository layout

```
.
├── <V2_VERSION>.command               current portable installer (double-click; copied by the exporter)
├── wireguard.command                  WireGuard peer menu (double-click; calls master-wg over SSH)
├── kurulum/                           installer inputs: kurulum.env; wireguard/ (only profiles + QR .png that wireguard.command was asked to download; DD-143) (Git-ignored)
├── versiyon/                          frozen copies of verified working versions (<V2_VERSION>/ + OKUBENI.txt; no kurulum/, no Data/app)
├── README.md, CLAUDE.md               entry points
├── .cursor/rules/master-stack.mdc     repository rules (not shipped to host)
└── Data/
    ├── install.sh                     orchestration
    ├── common.sh                      logging, guards, file writing, rendering
    ├── config/defaults.env            single source of truth for constants
    ├── templates/                     Caddyfile, dnsmasq.conf
    ├── scripts/                       installed to /usr/local/sbin (firewall.sh → master-firewall, …)
    ├── systemd/                       units (firewall, GRO, refresh timer, master-wg-panel)
    ├── panel/                         Konsol WireGuard and system backend: master-wg-panel (Python), API only
    ├── files-panel/                   unprivileged file/archive backend (Python), API only
    ├── console/                       Konsol pages: index.html, konsol.css, konsol.js (one origin, no external loads)
    ├── app/<V2_VERSION>.command       the current portable install app (older ones in Git)
    ├── dev/export-installer.sh        build the portable install app (+ .command wrapper)
    ├── docs/                          contract, architecture, design decisions
    └── tests/                         bats suites (not on host)
```

The root holds only what the operator double-clicks (2026-09-13). Paths in the
rest of this document are relative to `Data/`, which is also the layout the
installer has on the host under `/root/debian-server-installer`.

`.cursor/rules/` covers the repository tree. It describes how to build this
installer and ships no runtime behaviour — nothing installs it,
nothing reads it at run time — so it appears in the repository layout and
nowhere in §3.4's host layout.

One rule set, one active file:

| Path | Role |
|---|---|
| `.cursor/rules/master-stack.mdc` | **The active source.** Plain text with repository-wide frontmatter. Edits to the rules go here and only here. |
| `docs/archive/master-stack-rules-source.rtf` | **Archive.** The operator's original RTF, byte-for-byte, kept as the historical record. Never edited, never loaded. |

The `.rtf` moved out of `.cursor/rules/` because Cursor never parses it as
a rule, and a rule file sitting beside the real one invites edits that
silently do not apply. There is deliberately **no synchronisation
mechanism and no test** comparing the two: the archive is a snapshot of
what was first written, not a second copy of the truth, and it is expected
to fall behind as the `.mdc` evolves.

Three documents govern the installer, and they are not interchangeable:

| Source | Governs |
|---|---|
| `.cursor/rules/` | How to work: process, Bash conventions, per-phase verification, the hard "do not" list |
| `docs/contract.md` | What the result must do, and the success criteria |
| `docs/architecture.md` | Where each part lives and how data moves |

The rules describe working constraints; the contract and its linked feature
documents describe runtime behaviour. Historical disagreements are recorded in
§10. Update stale summaries instead of treating old wording as a new requirement.

### 3.2 One sentence per file

| File | Single responsibility | Deliberately does not know |
|---|---|---|
| `.cursor/rules/master-stack.mdc` | Carry the working rules for any AI assistant editing this tree — the single active, editable rule source | Anything about runtime behaviour — it is never installed to the host and never read by the installer |
| `install.sh` | Read the operator's input file, call the stages in order (including address detection), print the summary | What a firewall rule looks like, what Caddy syntax is |
| `common.sh` | Logging, error trapping, the root/OS gates, the stack lock, bounded network retry, atomic file installation, template rendering | Any stack-specific fact |
| `config/defaults.env` | Declare every constant exactly once: ports, paths, chain names, interface name, the WebDAV registry path | How any of them is used |
| `templates/Caddyfile` | The base HTTP sites and their loopback upstreams, plus `import CADDY_MODULES_DIR/*.caddy` for module sites (**DD-149**) | The Tailscale address (read as `{$TAILSCALE_IPV4}` from `state.env` at daemon start); which modules are installed |
| `scripts/master-wg` | WireGuard networks and peers, profiles/QR, DNS settings; coordinate internet-only network firewall changes | Installer inputs or Mac backups |
| `panel/master-wg-panel` | Root loopback `/api/wg/*` and `/api/konsol/*`, Host/CSRF gates, resources, audit/settings views and fixed worker dispatch | Static pages; module installation implementation |
| `panel/master_wg_upgrade.py` | Installer-only retirement of WG host access: fixed policy column, old WG overrides and exact old Caddy artifacts; preserves profiles/keys | General cleanup or account migration |
| `panel/master_settings.py` | Validate/apply settings, snapshot/rollback/confirm with independent guard, render committed overrides | Arbitrary shell commands, client-visible password hashes |
| `panel/master_shares.py`, `panel/master_webdav.py` | Root-owned folder-account registry and separate unprivileged WebDAV data service (§4) | Shared plaintext credentials or a writable symlink share tree |
| `scripts/master-modul` | Public WireGuard/qBittorrent app lifecycle, registry/progress/locks; installer-only `yerlesik` activates/checks built-in Files/WebDAV and their names, retaining accounts (**DD-159**) | Templates and inputs; user files; public removal of built-ins |
| `modules/<id>/` | One module's files as templates, rendered by the installer to `MODULES_DIR/<id>/`: `paylasim/master-paylasim.service` (the folder WebDAV unit), `paylasim.caddy`, `dnsmasq.conf` (**DD-148**, **DD-149**, **DD-152**); `torrent/qBittorrent.conf` (first settings only), `master-stack.conf`, `torrent.caddy`, `dnsmasq.conf` (**DD-151**) | Whether the module is installed |
| `files-panel/master-files-panel` | File API as downloads uid; Host/CSRF gates, descriptor-safe paths, no-overwrite operations, `.cop` trash, text and archive jobs; old share APIs remain compatibility-only | Anything outside `SERVER_ROOT`; WebDAV credentials; WireGuard administration |
| `files-panel/master_archives.py`, `files-panel/master_rar.py` | Single bounded ZIP creation or ZIP/RAR extraction job; descriptor-safe paths, resource-limited RAR subprocess, private staging, atomic publication and history | Root privileges, shell extraction, backups or resumable jobs |
| `console/panel.css`, `console/arsiv.js` | Model A shell styling and archive dialogs/history/cancellation, using the real file API | OS sessions, fake progress, service credentials |
| `console/index.html`, `konsol.css`, `konsol.js`, `ayarlar.js` | Files, App Store, installed app pages, sidebar resources and tabbed Settings; served by Caddy from `CONSOLE_WEB_DIR`, same-origin only (**DD-160**) | Keys — it asks for a QR or profile only when the operator does; file contents as HTML — names and text are inserted as text only |
| `templates/dnsmasq.conf` | Base `panel` name and fail-closed resolver on `lo` + `tailscale0`; built-in WebDAV and installed qBittorrent add their own files | The current address (`bind-dynamic` tracks it) |
| `scripts/tailscale-udp-gro` | Set the two ethtool flags on the default-route interfaces | Tailscale itself |
| `scripts/firewall.sh` → `master-firewall` | Project INPUT/FORWARD/NAT plus `MASTER-SETTINGS`, using installed apps, network registry and confirmed overrides; `--check` verifies critical policy | Other software's chain contents; the Tailscale address (matches its interface) |
| `scripts/refresh-tailnet-config` | Detect Tailscale address changes, update state and restart Caddy; bounded failed-Caddy recovery and independent firewall check/reapply (DD-87/94) | General module health, file drift, disk space or stack-wide reconciliation |
| `systemd/*.service` (+ timer) | Ordering, coupling and restart policy | The contents of the scripts they start |
| `dev/export-installer.sh` | Write `app/<V2_VERSION>.command` and replace the repository-root copy of the current version | Host runtime |
| `tests/` | Assert the contract, once per fact | Implementation details of the scripts |

### 3.3 Placeholder convention

Templates use `__NAME__` tokens, not `${NAME}` and not `{$NAME}`. Both of
those already have meanings in the generated files: systemd expands
`${…}` in unit command lines, and Caddy expands
`{$TAILSCALE_IPV4}` from `state.env` at daemon start. A distinct install-time
token makes it impossible to confuse "substituted once, by the installer"
with "expanded later, by the consumer".

Rendering is a single function in `common.sh`; it substitutes tokens,
writes to a temporary file, sets owner and mode, and renames atomically. A
template with an unsubstituted `__…__` token left in the output is a hard
error, not a warning.

### 3.4 Runtime layout on the host

| Host path | Written by | Contents |
|---|---|---|
| `/etc/master-stack/config.env` | installer | operator choices, `0600` |
| `/etc/master-stack/state.env` | installer, `refresh-tailnet-config` | detected addresses and identification, `0600` |
| `/etc/master-stack/webdav.json` | `master_shares.py` | Independent accounts, scrypt hashes, folder identity, permission, pause and expiry; 0600 root, systemd credential (DD-158) |
| `/etc/master-stack/ayarlar.json`, `ayarlar-bekleyen.json` | `master_settings.py` | Committed firewall/DNS/domain choices and pending transaction recovery; the independent guard rolls unconfirmed work back |
| `/var/lib/qbittorrent/` | qBittorrent (module) | its profile: settings (seeded once by `master-modul`) and torrent list, owned by the downloads uid (**DD-151**) |
| `/etc/systemd/system/qbittorrent-nox@.service.d/master-stack.conf` | `master-modul` (qBittorrent) | the unit drop-in: profile, `UMask`, sandbox (**DD-151**) |
| `/etc/wireguard/wgN.conf` | `master-wg` (the installer writes none, **DD-143**) | that network's key, peer public keys, PSKs, `AllowedIPs` (**DD-124**), `0600` |
| `/etc/wireguard/clients-wgN/<name>.conf` | `master-wg` | device profiles for `profile`/`qr`, `0600` |
| `/usr/local/sbin/master-wg` | installer | peer list/add/remove/profile/qr, `0755` |
| `/usr/local/sbin/master-wg-panel`, `master_settings.py`, `master_shares.py`, `master_webdav.py` | installer | Root API, settings/account workers and unprivileged WebDAV handler; pages are separate |
| `/usr/local/sbin/master-files-panel`, `/usr/local/share/master-stack/konsol/` | installer | file backend and the console pages Caddy serves, `0755` / `0644` (**DD-139**, **DD-140**) |
| `/usr/local/sbin/master-modul`, `/usr/local/share/master-stack/moduller/<id>/` | installer | module helper and rendered module files, `0755` / `0644` (**DD-148**) |
| `/etc/master-stack/moduller` | `master-modul` (installer creates it empty) | installed modules: `id<TAB>calisiyor|durduruldu`, `0644` (**DD-148**) |
| `/run/master-stack/modul-<id>.ilerleme`, `modul.lock` | `master-modul` | the last operation's progress line; the module lock (**DD-148**) |
| `SERVER_ROOT/.pay/` | reserved legacy path; no active writer | Never created or repaired since v145. Existing data remains hidden/blocked in Files, WebDAV and qBittorrent; no marker or legacy-account reader (DD-171) |
| `/etc/caddy/moduller/<id>.caddy` | installer (folder), `master-modul` (files) | module sites imported by the base Caddyfile; Paylaşım: `paylas.<domain>` and `<ts-ip>:61010` (**DD-149**) |
| `/etc/dnsmasq.d/modul-<id>.conf` | `master-modul` | module names; Paylaşım: `interface-name=paylas.<domain>,tailscale0` (**DD-149**) |
| `SERVER_ROOT/.cop/` | installer (folder), file panel (contents) | Trash: `<id>/<item>` plus `<id>.json` (origin, time); outside downloads and excluded from WebDAV/qBittorrent access |
| `/etc/wireguard/networks` | `master-wg` | Networks wg0…wg9 (`WG_NETWORKS_MAX` is the highest slot index): port, fixed `inet` policy column, addresses, default DNS, label; `0600` |
| `/etc/wireguard/wgN.conf`, `/etc/wireguard/clients-wgN/` | `master-wg` | a panel network's interface and profiles, `0600`/`0700` |
| `/etc/modules-load.d/master-stack-wireguard.conf` | `master-modul` (WireGuard) | `wireguard`, `0644`; removed with the module (**DD-150**) |
| `/etc/systemd/system/master-files-panel.service` | installer via `master-modul yerlesik`; template in `MODULES_DIR/dosya/` | built-in file/archive backend, always enabled (**DD-159**) |
| `/srv/.arsiv/`, `jobs.json` | unprivileged archive worker | private staging (0700) and last 20 jobs (0600); excluded from installer recursive permission repair; never a backup (**DD-159**) |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52master-stack-unattended` | installer | periodic unattended upgrades on, automatic reboot off (**DD-113**), `0644` |
| `/etc/dnsmasq.d/local-services.conf` | installer | Base `panel` record/resolver policy, `0644`; other names in separate managed files |
| `/etc/caddy/Caddyfile` | installer | Panel static/API routes plus imported service sites, `0644` |
| `/usr/local/sbin/{tailscale-udp-gro,master-firewall,refresh-tailnet-config}` | installer | `0755` |
| `/etc/systemd/system/{tailscale-udp-gro,master-firewall,refresh-tailnet-config}.service` (+ `.timer`) | installer | `0644`; `wg-quick@.service` comes from `wireguard-tools`; `master-wg` enables `wg-quick@wgN` |
| `/etc/systemd/system/{caddy,dnsmasq}.service.d/master-stack.conf` | installer | drop-ins, `0644` |
| `/run/master-stack/` | helpers | ephemeral runtime state (the stack lock) |
| `/var/log/master-setup/` | installer | run logs, `0700` dir / `0600` files |

`/usr/local/share/master-stack` contains live static assets and module templates,
not a canonical recovery copy. There is no generation pointer or runtime
restore manifest.

Two absences in that table are decisions rather than oversights.

**There is no rendered Caddy environment file.** Caddy's drop-in reads
`/etc/master-stack/state.env` directly as its `EnvironmentFile=`, so the
address exists in exactly one place on disk and `refresh-tailnet-config`
has one file to update instead of two. The cost is a formatting
constraint: `state.env` must be parseable both by `source` in bash and by
systemd's `EnvironmentFile=`, which means plain `KEY=value` lines with no
unescaped shell expansion or spaces around `=`. Prefix lists use double quotes. That constraint is
the writer's job to enforce, and the test suite asserts it.

**No module needs Tailscale or WAN facts in its own files** (**DD-76**). Web
UIs and WebDAV bind loopback; there is no Docker and no public peer port
(**DD-151**, **DD-152**).

---

## 4. Folder WebDAV ownership (DD-158)

Folder form → root API → fixed master_shares.py worker (stdin) → 0600 root
webdav.json (scrypt hashes, root identity, permission, pause and expiry) →
systemd LoadCredential → unprivileged master_webdav.py → validated descriptors.

The file-manager backend sees no credential. Caddy publishes the existing
tailnet port and name; /s/<id>/ selects independent accounts. Account changes
restart the active data service, cutting existing transfers. Per-folder isolation
is in the handler, not separate OS sandboxes. No per-share listener is needed.

See [folder-shares.md](folder-shares.md) for protocol limits, security boundaries,
migration and tests. DD-158 replaces the shared rclone account/symlink design.

---

## 5. Address change handling

Three consumers depend on an address, and each is handled differently
according to what it actually binds:

| Consumer | Binds to | On Tailscale address change |
|---|---|---|
| dnsmasq | `lo` and `tailscale0` **by name** | Nothing — `interface-name` + `bind-dynamic` follow the interface, and the config is never regenerated |
| Caddy | `{$TAILSCALE_IPV4}` read from `state.env` | Restarted after `state.env` is updated |
| WebDAV | `127.0.0.1` only | Nothing — loopback publish does not track Tailscale |
| Module services | no Tailscale bind | Nothing — no module binds a Tailscale address |
| Firewall | `tailscale0` **by name**; configured service allowlist and registered WG ports; Self PeerAPI ports per family (DD-172) | Existing restart hook/watchdog regenerates changed PeerAPI ports; ordinary listener discovery never grants access |

`refresh-tailnet-config` owns the Tailscale side of this table, and its
scope is bounded: read IPv4/IPv6, compare with `state.env`, and update it and
restart Caddy when needed. Independently of address changes, it runs the
firewall's own check and reapplies a broken firewall (DD-94), and can recover a
failed Caddy (DD-87). It has no general module health, file drift, disk-space or
binary-version reconciliation. The address-only rows above describe IP effects,
not these separately bounded recovery paths.

Two rows above say "nothing" for structural reasons worth naming, because
they are what keep the helper small. dnsmasq and the firewall are both
written against the *interface name* rather than the address it currently
carries, so the address can change — or `tailscale0` can be destroyed and
recreated — with no file to regenerate and no rule to reinstall.

**A Tailscale address change never restarts a module.** This is the single
most important lifecycle difference from v1, where `master-compose.service`
carried `PartOf=tailscaled.service` and therefore made every
`systemctl restart tailscaled` bounce the whole Compose set. There is no
Compose set any more (**DD-152**).

**Public IPv4 change — settled.** Nothing publishes on a WAN address, so a new
public IPv4 needs no re-render. `master-firewall` re-applies on boot and on
a Tailscale restart and reads current WAN facts from `state.env` / the
interface.
`WG_ENDPOINT_HOST` in `state.env` is an operator hint only; WireGuard client
profiles that baked an old endpoint still need manual client updates
(**DD-76**). There is no Compose `.env` path and no
`refresh-tailnet-config` extension for WAN IP.

---

## 6. Decision ownership

The v1 failure mode this table prevents: the same question answered in the
installer, in a helper and in the final test, with three implementations
that could disagree.

| Question | Single owner |
|---|---|
| What is the WAN interface / WAN IPv4 / WAN IPv6 / Tailscale IPv4 / IPv6? | `install.sh` (write) / `refresh-tailnet-config` (update) |
| Is the firewall policy in force? | `scripts/firewall.sh` installed as `/usr/local/sbin/master-firewall --check` |
| Has the Tailscale address changed? | `scripts/refresh-tailnet-config` |
| Is a module healthy? | **Nobody.** systemd's `Restart=` handles crashes; `master-modul` checks only when it installs, starts or re-applies |
| Has a managed file drifted? | **Nobody.** Re-running the installer is the repair |
| Is the stack working end to end? | The final verification stage, once |
| Is a port number correct? | `config/defaults.env` |

A check that appears in two of these rows is an installer bug, not defence in
depth.

---

## 7. Installer stage outline

Stage boundaries are the same shape as v1's, minus the work that no longer
exists. Stage 4 in v1 was 2396 lines; here it is a rendering pass.

| Stage | Work | Owns |
|---|---|---|
| 0 | Gates (root, tty, supported OS, nft `iptables`, ufw inactive, lock, inhibit); detect release change; read/delete input, reject pending Settings transaction, resolve confirmed domain, one confirmation; write `config.env`; full-upgrade question on re-run. No backup restore | operator input |
| 1 | Suspend third-party restart managers (**DD-103**); `apt update`; optional `full-upgrade`; base packages — only what the base uses (**DD-153**: no gnupg, gawk or apache2-utils); timezone | `apt` |
| 2 | Tailscale: repository, package, sysctls, UDP GRO, login with 410 recovery, exit-node and SSH preferences | `tailscaled` |
| 3 | Address detection → `state.env`; selective downloads ownership/mode repair (**DD-84**) | installer |
| 4 | Install scripts, render module files and units; run scoped WG access retirement before firewall; no Docker (**DD-152**) | templates |
| 5 | Apply `master-firewall` (WireGuard rules come from the registry, and only while the WireGuard module is installed; none when it is empty); enable refresh timer. The WireGuard layer (`wireguard-tools`, `qrencode`, kernel module, `/etc/wireguard`, starting the registry's networks) belongs to the WireGuard module since **DD-150** | firewall |
| 6 | dnsmasq/Caddy, Konsol root backend/pages, Files/archive code and staged unit; restart changed services only | DNS/HTTP |
| 7 | `master-modul yerlesik` enables/checks Files/WebDAV; reapply changed optional apps and installed WireGuard; core contracts, Caddy/API gates and optional network checks (**DD-159**) | verification |
| — | Print summary and the manual Tailscale admin steps | operator guidance |

Note the ordering change from v1: **addresses are detected once, in stage 3,
into `state.env`**, and every later stage reads them from there instead of
re-deriving them. v1 derived the same route information in four separate
places.

---

## 7.1 OS-divergence inventory

Every point where behaviour depends on the host distribution is marked in the
source with `# OS-DIVERGENCE: <slug>` and listed here. The two sets are
asserted equal by `bats`, so a divergence cannot be added to the code without
appearing here, or removed from here while it still exists in the code.

`grep -n 'OS-DIVERGENCE:' install.sh` prints the live inventory.

The list is short on purpose. Prefer capability probes; use distribution
identity when selecting repository suites/components (including RAR dependencies).
The old `debian-keyring` branch was dropped in v2-90 (**DD-125**). See
**DD-102** and **DD-104**, and `archive/os-aware-review.md` for why the tree is not
forked into per-distribution paths.

<!-- OS-DIVERGENCE-INVENTORY:BEGIN -->

| Slug | Kind | Affects | What differs | DD |
|---|---|---|---|---|
| `tailscale-repo-suite` | identity-derived | both | apt suite and keyring URL come from `OS_ID`/`OS_CODENAME`; both vendors publish the same URL shape | DD-102 |
| `rar-repository` | candidate probe + identity-derived | both | when RAR dependencies have no apt candidate, add only a managed signed source: Debian non-free, Ubuntu universe/multiverse; Ubuntu arm uses ports | DD-166 |
| `ufw-gate` | probe | ubuntu in practice | ufw active is a fail-closed stop; no package, no-op | DD-102 |
| `netfilter-binaries` | probe | debian | a minimal Debian image ships no `iptables`; stage 0 checks only what exists, stage 1 makes it mandatory | DD-108 |
| `needrestart-suspend` | probe-free no-op | ubuntu | `NEEDRESTART_SUSPEND=1`; Debian has no needrestart, so the variable is unread | DD-103 |
| `resolved-stub` | probe | ubuntu in practice | `DNSStubListener=no` written only when resolved is active; on Debian the whole block is skipped and no drop-in is created. Ubuntu 26.04 / systemd 259 accepts and ignores the key, so the achieved state is read back and reported rather than assumed | DD-102, DD-109 |
| `resolvconf-symlink` | probe | ubuntu | `/etc/resolv.conf` is repointed only when it targets the stub; Tailscale takes the file over later | DD-102 |

<!-- OS-DIVERGENCE-INVENTORY:END -->

Two things are **deliberately not** divergences and must not become branches:
the Caddy cloudsmith repo line (`any-version`, distro-agnostic) and the legacy
IPv4 netfilter `modprobe` set, which is applied on every OS because the problem
it solves was merely *found* on Ubuntu (**DD-10**).

## 8. Implementation status

The `Data/` tree is executable: `install.sh` runs the seven stages on a
Debian 13 or Ubuntu 24.04/26.04 LTS host. `dev/export-installer.sh` embeds a runtime-only tarball
(excluding `.cursor/`, `dev/`, `tests/`, `app/`) into
`app/<V2_VERSION>.command`, copied to the repository root as the one
installer there, which uploads and starts install over
`ssh -t`.

Static checks for this tree:

```bash
bats tests
bash -n install.sh common.sh scripts/*
shellcheck -x -s bash install.sh common.sh scripts/*
```

There is no root `scripts/check-all.sh` wrapper; run the three workstation
commands above directly. A missing tool must fail visibly — never report a
silent pass.

---

## 9. Per-phase verification

Use checks appropriate to the changed layer. Do not report a missing Linux
validator or an unrun fresh-host acceptance test as a pass:

| Check | Scope | Available on the dev workstation? |
|---|---|---|
| `bash -n` | Root `*.sh`, `scripts/*` and the exporter | **yes** |
| `shellcheck -x` | Same set; `-x` so sourced libraries are followed | **yes** |
| `bats tests/` | Shell/unit contracts; some require Linux tools | **yes**, with explicit skips for unavailable tools |
| Python unittest / browser suites | Backend and production UI with isolated fixtures | **yes**, with optional native-RAR tests skipped without Linux dependencies |
| `caddy validate` | The rendered `Caddyfile` | **no** — runs on the target, in stage 6, with the real env (**DD-106**) |
| `dnsmasq --test -C` | The rendered dnsmasq config | **no** — runs on the target, in stage 6 (**DD-106**) |
| `systemd-analyze verify` | Generated units and drop-ins | **no** — runs on the target during installation (**DD-106**) |

The split matters: workstation checks and Linux renderer checks are distinct.
A phase that changes a rendered template is
**not** verifiable on the workstation alone, and claiming otherwise is the
failure mode those host-only checks exist to prevent (a missing tool must
report *doğrulanamadı*, never a pass).

Since v2-74 the three renderer checks are no longer only a manual option:
`install.sh` runs each of them on the target, against the file it just
rendered, before the unit that consumes it is restarted (**DD-106**). The
workstation still cannot run them — the split above is unchanged — but a bad
render now fails with a line number and a directive name instead of a failed
`systemctl restart`.

Two consequences for the phase that lands real rendering:

1. The three renderers must be invocable without installing anything, so
   that a rendered artefact can be produced on the workstation and carried
   to the target for validation.
2. `refresh-tailnet-config` must validate before reloading — the rules
   require it, and a reload on an invalid config is how a working DNS server
   becomes a stopped one.

## 10. Decisions taken, and what remains open

### 10.1 Settled on 2026-08-05

Four questions that were disagreements between `.cursor/rules/` and the
decisions taken in conversation, plus the DD-9 supersession, were answered
together. Each has a full entry in `docs/design-decisions.md`; the
one-line versions:

| # | Question | Answer |
|---|---|---|
| **DD-58** | Does the single-file model survive into v2? | No. DD-9 is superseded; v2 ships as a repository tree. |
| **DD-59** | Chain names | `MASTER-INPUT` (plus `MASTER-FORWARD`/`MASTER-NAT` for WireGuard), declared only in `config/defaults.env`. `MASTER-DOCKER` went with Docker (**DD-152**). |
| **DD-60** | Does dnsmasq listen on loopback? | Yes — `lo` and `tailscale0`, `bind-dynamic`, nothing else, no DHCP. |
| **DD-61** | Does the refresh helper re-render configs? | No. Address changes update `state.env` and restart Caddy; later DD-87/94 add bounded Caddy/firewall recovery (§5), not general reconciliation. |
| **DD-77** | Where does WebDAV run? | Was Compose on `127.0.0.1`; since **DD-152** the host unit `master-paylasim.service` on `127.0.0.1`, Caddy reverse_proxy. |
| **DD-98** | Apple TV without MagicDNS? | Caddy listens on `${TAILSCALE_IPV4}:${SHARE_PORT}` → loopback WebDAV; the service has no Tailscale bind. Current folder URLs include `/s/<id>/`. |
| **DD-62** | Portainer's upstream | Superseded by **DD-116**: Portainer was replaced by Dozzle on plain loopback HTTP `127.0.0.1:61002`. |

**DD-59 removed a chain that was never decided on.** `defaults.env`
previously also declared `MASTER-TS-FORWARD`, carried over from v1's
mangle-table chain. It is not part of the fixed name set and no clause of
the contract requires it, so it is gone. If the firewall phase finds that
a `FORWARD`- or mangle-table chain is genuinely needed, that is a new
decision with a new name, not a constant that survives by inertia.

### 10.2 Follow-up status

1. **Public IPv4 change handling** — settled in §5: refresh detects Tailscale
   addresses, not WAN changes; baked client endpoints require manual updates.
2. **Comment policy.** Settled for `install.sh` (DD-44: no
   editorial comments; rationale in `docs/design-decisions.md`). Helper
   scripts under `scripts/` may keep short operational comments.
3. **Whether `master-compose.service` returns in a later phase.** Closed by
   **DD-152**: there is no Docker and no Compose at all.
4. **`systemd-resolved` vs dnsmasq on `127.0.0.1:53`.** Stage 6 writes
   `DNSStubListener=no` when resolved is active. Confirmed on noble and
   resolute: dnsmasq owns loopback/Tailscale DNS, host DNS survives, and on
   resolute Tailscale can legitimately replace the uplink symlink with its
   direct-mode MagicDNS file after restart/reboot. Unusual images still need
   the same live check.
5. **What a loopback query actually answers.** `interface-name` is
   expected to return the `tailscale0` address regardless of the arrival
   interface, which is the entire reason the loopback listener is useful
   for testing. Measured on the live host in stage 7 (both `@127.0.0.1`
   and `@TAILSCALE_IPV4`). The DNS phase carries it as an
   acceptance test on a clean Debian 13 target: `dig +short NAME
   @127.0.0.1` and `dig +short NAME @${TAILSCALE_IPV4}` must agree, and must
   both return `${TAILSCALE_IPV4}`.
