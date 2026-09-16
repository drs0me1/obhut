# Architecture

**Status:** architecture for the lean root-level installer tree.
Read [`contract.md`](contract.md) first — that document says *what* the installer
does; this one says *where each part of it lives* and *how data moves*.
Operator entry point: [`README.md`](../../README.md).

v1's structural problem was not its size but its ownership model: the same
fact (a port number, a container name, an expected binding) was asserted in
three or four places, and the same decision (is this healthy?) was made by
the installer, by a helper and by a final test. The rule is one owner per
fact and one owner per decision.

---

## 1. Data flow

```
                     operator input
                   (domain, downloads path,
                    WebDAV user + password)
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
    compose.yaml  dnsmasq conf     Caddyfile     firewall
                  (lo +          (TAILSCALE_    (in memory)
                   tailscale0)    IPV4:80)
        │            │                │              │
        ▼            ▼                ▼              ▼
   6 containers   dnsmasq         caddy         MASTER-INPUT
   (incl. paylasim .service        .service      MASTER-DOCKER
    on loopback)
```

Only Caddy reads the Tailscale address (including Infuse
`${TS_IPV4}:${WEBDAV_PORT}`). dnsmasq and the firewall are written against
the *interface name*, and WebDAV binds loopback only (**DD-77** / **DD-98**).
That is what makes an address change a Caddy-only restart rather than a
stack-wide one.

The WebDAV **password** does not appear anywhere in this diagram after the
first arrow. It is hashed immediately into a separate credential file; see
§4.

---

## 2. `config.env` versus `state.env`

Two files, two lifetimes, two owners. Conflating them is what made v1's
`state.env` carry both a schema version and a frozen `WG_ENDPOINT_HOST` that
later became a permanent drift alarm.

| | `config.env` | `state.env` |
|---|---|---|
| **Path** | `/etc/master-stack/config.env` | `/etc/master-stack/state.env` |
| **Contains** | Choices: local domain, downloads path, timezone, `WG_PUBLIC_PORT`, WebDAV port | Detected facts: WAN interface, WAN IPv4, WAN IPv6 (empty if none), `TAILSCALE_IPV4`, `TAILSCALE_IPV6`, install version; `WG_ENDPOINT_HOST` equals the current `WAN_IPV4` (not an operator prompt; no address is written by hand, **DD-138**) |
| **Source** | `config/defaults.env` + the installer input file `kurulum/kurulum.env` (**DD-119**) | installer / `refresh-tailnet-config` at run time |
| **Written by** | The installer, once per run | The installer, and `refresh-tailnet-config` when an address changes |
| **Lifetime** | Persistent; every run rewrites it from the input file (an empty value takes `defaults.env`) | Regenerated freely; nothing in it is a decision |
| **Hand-editable** | No — edit `kurulum/kurulum.env` and re-run the installer | No — it will be overwritten |
| **Read by** | The installer, template rendering | The installer, `master-firewall`, Caddy (`EnvironmentFile=`), `refresh-tailnet-config` |
| **Contains secrets** | **No** | **No** |

Practical consequence: changing a port is editing `config.env` and re-running.
Changing an address is not a human action at all — detection handles it.

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
├── kurulum/                           installer inputs: kurulum.env; wireguard/ (profiles + QR .png + sunucu/wg0.conf) pulled by wireguard.command → 6) Yedek al (Git-ignored)
├── versiyon/                          frozen copies of verified working versions (<V2_VERSION>/ + OKUBENI.txt; no kurulum/, no Data/app)
├── README.md, CLAUDE.md               entry points
├── .cursor/rules/master-stack.mdc     repository rules (not shipped to host)
└── Data/
    ├── install.sh                     orchestration
    ├── common.sh                      logging, guards, file writing, rendering
    ├── config/defaults.env            single source of truth for constants
    ├── templates/                     compose.yaml, Caddyfile, Caddyfile.wg, dnsmasq.conf, qBittorrent.conf
    ├── scripts/                       installed to /usr/local/sbin (firewall.sh → master-firewall, …)
    ├── systemd/                       units (firewall, GRO, refresh timer, caddy-wg@ template, master-wg-panel)
    ├── panel/                         Konsol WireGuard and system backend: master-wg-panel (Python), API only
    ├── files-panel/                   Konsol file backend: master-files-panel (Python), also serves the pages
    ├── console/                       Konsol pages: index.html, konsol.css, konsol.js (one origin, no external loads)
    ├── app/<V2_VERSION>.command       every exported portable install app
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

Where they overlap they agree. Where the rules file is silent — it predates
the WebDAV decisions and does not mention WebDAV at all — the contract
extends it rather than contradicting it. Genuine disagreements are recorded
in §10, not resolved silently.

### 3.2 One sentence per file

| File | Single responsibility | Deliberately does not know |
|---|---|---|
| `.cursor/rules/master-stack.mdc` | Carry the working rules for any AI assistant editing this tree — the single active, editable rule source | Anything about runtime behaviour — it is never installed to the host and never read by the installer |
| `install.sh` | Read the operator's input file, call the stages in order (including address detection), print the summary | What a firewall rule looks like, what Caddy syntax is |
| `common.sh` | Logging, error trapping, the root/OS gates, the stack lock, bounded network retry, atomic file installation, template rendering | Any stack-specific fact |
| `config/defaults.env` | Declare every constant exactly once: ports, container names, image references, paths, chain names, interface name | How any of them is used |
| `templates/compose.yaml` | The six services (two loopback rclone servers: the Infuse WebDAV and the share WebDAV), volumes, port publications | Where it is written, which addresses are current |
| `templates/Caddyfile` | Seven HTTP sites and their loopback upstreams | The Tailscale address (read as `{$TAILSCALE_IPV4}` from `state.env` at daemon start) |
| `scripts/master-wg` | WireGuard peers on the server: list/info, add, remove, profile, QR, PNG, DNS, reset (**DD-124**, **DD-130**, **DD-132**) | The firewall, the installer's inputs |
| `panel/master-wg-panel` | Serve `/api/wg/*` on loopback as root: HTTP Basic against a PBKDF2 hash, CSRF/Host gates, JSON API over `master-wg`, plus the server's own numbers (CPU, memory, uptime, ports, audit lines) (**DD-133**, **DD-140**) | WireGuard files and tools — it only calls `master-wg`; page files — it serves none |
| `files-panel/master-files-panel` | Serve the console pages and the file API on loopback as the downloads uid: same login as the WireGuard backend (hash via `LoadCredential`), directory-descriptor walks with `O_NOFOLLOW`, no-overwrite renames, the `.cop` trash, text decoding (**DD-139**, **DD-140**) | Anything outside `DOWNLOADS_PATH`; WireGuard — those calls go to the other backend |
| `console/index.html`, `konsol.css`, `konsol.js` | The console: overview, WireGuard, files and log, everything from its own origin (**DD-140**) | Keys — it asks for a QR or profile only when the operator does; file contents as HTML — names and text are inserted as text only |
| `templates/qBittorrent.conf` | qBittorrent keys the installer manages; the account is added from the input file (**DD-129**) | ports, generated keys, account |
| `templates/Caddyfile.wg` | The three UI ports on `{$WG_BIND}`, shared by every `caddy-wg@<interface>` instance (**DD-120**, **DD-136**) | Tailscale, names, WebDAV, which network it serves |
| `templates/dnsmasq.conf` | Seven `interface-name` records and the fail-closed resolver posture on `lo` + `tailscale0` | The current address (`bind-dynamic` tracks it) |
| `scripts/tailscale-udp-gro` | Set the two ethtool flags on the default-route interfaces | Tailscale itself |
| `scripts/firewall.sh` → `master-firewall` | Build and atomically install `MASTER-INPUT` and `MASTER-DOCKER`; `--check` verifies jumps, `ts-input` order, and a short IPv4 ACCEPT/DROP set | Containers, DNS, WebDAV, and the Tailscale *address* — it matches the interface |
| `scripts/refresh-tailnet-config` | Detect a Tailscale address change, update `state.env`, restart Caddy — nothing else | Container health, file drift, disk space, dnsmasq, the firewall, WebDAV |
| *(removed v2-26)* `watch-tailnet-addr` | — | Replaced by timer + `WantedBy=tailscaled` only |
| *(removed v2-36)* `scripts/webdav.sh` / `master-webdav` | — | Replaced by a Compose rclone on loopback (**DD-77**); since **DD-142** the only one serves the share root |
| `systemd/*.service` (+ timer) | Ordering, coupling and restart policy | The contents of the scripts they start |
| `dev/export-installer.sh` | Write `app/<V2_VERSION>.command` and replace the repository-root copy of the current version | Host runtime |
| `tests/` | Assert the contract, once per fact | Implementation details of the scripts |

### 3.3 Placeholder convention

Templates use `__NAME__` tokens, not `${NAME}` and not `{$NAME}`. Both of
those already have meanings in the generated files: Compose expands
`${…}` from Compose `.env` at container start, and Caddy expands
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
| `/etc/master-stack/paylasim.htpasswd` | installer | bcrypt hash of the share account, `0600`; mounted into Compose `paylasim` (**DD-142**) |
| `/etc/master-stack/filebrowser-data/` | installer | Classic FileBrowser Bolt DB, created once with the stage-0 account (**DD-118**), + `config/` bind (`0750`, DOWNLOADS_UID) |
| `/root/docker/compose.yaml` | installer | five services, `0600` |
| `/etc/wireguard/wg0.conf` | installer (`[Interface]`), `master-wg` (`[Peer]` blocks) | server key, peer public keys, PSKs, `AllowedIPs` (**DD-124**), `0600` |
| `/etc/wireguard/clients/<name>.conf` | `master-wg` | device profiles for `profile`/`qr`, `0600` |
| `/usr/local/sbin/master-wg` | installer | peer list/add/remove/profile/qr, `0755` |
| `/usr/local/sbin/master-wg-panel`, `/usr/local/share/master-stack/wg-panel/` | installer | WireGuard panel service and page, `0755` / `0644` (**DD-133**) |
| `/etc/master-stack/wg-panel.auth` | installer | panel account: user and PBKDF2-SHA256 hash, `0600`; also the file panel's account (**DD-139**) |
| `/usr/local/sbin/master-files-panel`, `/usr/local/share/master-stack/konsol/` | installer | file backend and the console pages, `0755` / `0644` (**DD-139**, **DD-140**) |
| `/etc/master-stack/paylasim.htpasswd`, `paylasim.cred` | installer | share account: bcrypt for rclone, plaintext for the console to show, `0600 root` (**DD-141**) |
| `DOWNLOADS_PATH/.pay/` | file backend | share root `w/` (symlinks) and the registry beside it, uid 1000 (**DD-141**) |
| `DOWNLOADS_PATH/.cop/` | installer (folder), file panel (contents) | the file panel's trash: `<id>/<item>` plus `<id>.json` (origin, time); an empty tmpfs inside `unpackerr` |
| `/etc/wireguard/networks` | `master-wg net-add`/`net-remove` | panel networks wg1…wg9: port, scope, addresses, default DNS, label (**DD-136**), `0600` |
| `/etc/wireguard/wgN.conf`, `/etc/wireguard/clients-wgN/` | `master-wg` | a panel network's interface and profiles, `0600`/`0700` |
| `/etc/wireguard/caddy-wg-<interface>.env` | installer (`wg0`), `master-wg` (`ui` networks) | `WG_BIND` for that `caddy-wg@` instance, `0644` |
| `/etc/modules-load.d/master-stack-wireguard.conf` | installer | `wireguard`, `0644` |
| `/etc/caddy/Caddyfile.wg` | installer | `caddy-wg@<interface>`: three UI ports on that network's server address, `0644` |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52master-stack-unattended` | installer | periodic unattended upgrades on, automatic reboot off (**DD-113**), `0644` |
| `/etc/dnsmasq.d/local-services.conf` | installer | seven records, `0644` |
| `/etc/caddy/Caddyfile` | installer | seven sites, `0644` |
| `/usr/local/sbin/{tailscale-udp-gro,master-firewall,refresh-tailnet-config}` | installer | `0755` |
| `/etc/systemd/system/{tailscale-udp-gro,master-firewall,refresh-tailnet-config}.service`, `caddy-wg@.service` (+ `.timer`) | installer | `0644`; `wg-quick@.service` comes from `wireguard-tools`; `master-wg` enables `wg-quick@wgN`/`caddy-wg@wgN` |
| `/etc/systemd/system/{caddy,dnsmasq}.service.d/master-stack.conf` | installer | drop-ins, `0644` |
| `/run/master-stack/` | helpers | ephemeral runtime state (the stack lock) |
| `/var/log/master-setup/` | installer | run logs, `0700` dir / `0600` files |

There is no `/usr/local/share/master-stack`: no canonical copy, no
manifest, no generation pointer.

Two absences in that table are decisions rather than oversights.

**There is no rendered Caddy environment file.** Caddy's drop-in reads
`/etc/master-stack/state.env` directly as its `EnvironmentFile=`, so the
address exists in exactly one place on disk and `refresh-tailnet-config`
has one file to update instead of two. The cost is a formatting
constraint: `state.env` must be parseable both by `source` in bash and by
systemd's `EnvironmentFile=`, which means plain `KEY=value` lines with no
quoting, no spaces around `=`, and no shell expansion. That constraint is
the writer's job to enforce, and the test suite asserts it.

**Compose's `.env` is not written.** No container needs a Compose env file
for Tailscale or WAN facts (**DD-76**). Web UIs and WebDAV bind loopback;
the two public peer ports bind the WAN address via Docker publish.

---

## 4. WebDAV credential design

**Rule: the plaintext password exists only inside the installer process, for
as long as it takes to hash it.**

```
operator types password (echo off, twice, compared)
        │
        ▼
htpasswd -i -B  ──►  /etc/master-stack/paylasim.htpasswd  root:root 0600
        │                     │
        ▼                     │
   variable unset             │
                              ▼
              Compose volume mount (read-only)
              → /run/secrets/paylasim_htpasswd
                              │
                              ▼
                    rclone serve webdav --htpasswd=…
                    (Compose service `paylasim`, loopback, share root)
```

### 4.1 The decision, stated as properties

Recorded so that a later phase cannot quietly weaken it. The same list, in
contract form, is `contract.md` §6.2. **DD-77** replaced the former
systemd `LoadCredential=` path.

1. Credentials live in a **separate, root-owned credential file**:
   `/etc/master-stack/paylasim.htpasswd` (plus the plaintext copy the console
   shows, `paylasim.cred`, same owner and mode — **DD-141**).
2. Its mode is **at most `0600`**, owner `root:root`, verified after writing.
3. Compose mounts the file at **`/run/secrets/paylasim_htpasswd`** (read-only).
4. rclone is pointed at that **path** only (`--htpasswd=…`).
5. The password is **not in Compose YAML or systemd unit content**.
6. The password is **not in any environment file**: not `config.env`, not
   `state.env`, not `config/defaults.env`. There is no `paylasim.env`.
7. The password **does not appear on a command line**.
8. The password is **not written to logs**.
9. Exposure checks against the running container assert items 7–8 (§4.3).

### 4.2 Where the username lives, and why

**The username is managed with the credential, not with the
configuration.** It lives inside `paylasim.htpasswd`, because the htpasswd
format is already `user:hash`.

The alternative — `SHARE_USER` in `config.env` — was rejected: the name
would then exist in two places and could drift from the hash. One file, one
pair.

Consequence: `WEBDAV_USER` does not appear in configuration files, and
`defaults.env` names it in its forbidden-keys list alongside
`WEBDAV_PASSWORD`, `WEBDAV_PASSWORD_HASH` and `WEBDAV_USER_PASSWORD`.

### 4.3 Verified at implementation time, not assumed

rclone must take credentials from a *file*. If it could only take
`--user`/`--pass`, the secret would land on the command line.

Stage 7 and the live checklist assert: no password or username in container
args / environ; host htpasswd remains `0600` `root:root`.

### 4.4 Tunables (no `webdav.env`)

Port, image pin, and read-only posture live in `defaults.env` + the Compose
template. There is no separate `webdav.env`; Stage 4 deletes a leftover file
from older revisions.

### 4.5 Re-run behaviour

If the credential file exists and is non-empty, the installer says so and
does not ask again. Resetting is deleting the file and re-running, and the
installer's output states that. This is what keeps a second run from
silently invalidating the Apple TV's stored credentials. Host
`master-webdav` leftovers are disabled and removed.

---

## 5. Address change handling

Three consumers depend on an address, and each is handled differently
according to what it actually binds:

| Consumer | Binds to | On Tailscale address change |
|---|---|---|
| dnsmasq | `lo` and `tailscale0` **by name** | Nothing — `interface-name` + `bind-dynamic` follow the interface, and the config is never regenerated |
| Caddy | `{$TAILSCALE_IPV4}` read from `state.env` | Restarted after `state.env` is updated |
| WebDAV | `127.0.0.1` only | Nothing — loopback publish does not track Tailscale |
| Compose containers | no Tailscale bind | Nothing — no container binds a Tailscale address |
| Firewall | `tailscale0` **by name**; WAN peer ports from config/state | Nothing — no Tailscale rule names an address |

`refresh-tailnet-config` owns the Tailscale side of this table, and its
scope is exactly that: read the current IPv4 and IPv6, compare with
`state.env`, exit successfully without touching a service if they match,
and otherwise update `state.env` atomically and restart Caddy. It has no
opinion about container health, file contents, disk space or image digests,
and it holds no cooldown stamps, drift flags or recovery logic. **DD-61**
(narrowed by **DD-77**) states the scope exhaustively.

Two rows above say "nothing" for structural reasons worth naming, because
they are what keep the helper small. dnsmasq and the firewall are both
written against the *interface name* rather than the address it currently
carries, so the address can change — or `tailscale0` can be destroyed and
recreated — with no file to regenerate and no rule to reinstall.

**A Tailscale address change never restarts the Compose stack.** This is
the single most important lifecycle difference from v1, where
`master-compose.service` carried `PartOf=tailscaled.service` and therefore
made every `systemctl restart tailscaled` bounce the whole Compose set
(five containers then; six with WebDAV now).

**Public IPv4 change — settled.** Compose publishes the peer ports on
`0.0.0.0` (not a WAN address baked into the file), so a new public IPv4
does **not** require re-rendering Compose or recreating containers for
DNAT/publish. `master-firewall` re-applies on boot / Docker / Tailscale
restart and reads current WAN facts from `state.env` / the interface.
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
| Is a container healthy? | **Nobody.** Compose's restart policy handles crashes; there is no health arbiter |
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
| 0 | Gates (root, tty, supported OS — Debian 13 / Ubuntu 24.04 / 26.04, nft `iptables` backend, ufw inactive, lock, inhibit); record the OS identity and detect a release change (**DD-104**); read and delete the input file, move and validate pulled settings (**DD-128**), validate domain, downloads path, ports and the WebDAV/Dozzle/FileBrowser/qBittorrent/WireGuard panel accounts, one confirmation (**DD-119**); `config.env`; full-upgrade and image-pull questions on re-run | operator input |
| 1 | Suspend third-party restart managers (**DD-103**); `apt update`; optional `full-upgrade`; base packages (`apache2-utils` for htpasswd); WebDAV htpasswd when it differs from the input file; timezone | `apt` |
| 2 | Tailscale: repository, package, sysctls, UDP GRO, login with 410 recovery, exit-node and SSH preferences | `tailscaled` |
| 3 | Address detection → `state.env`; selective downloads ownership/mode repair (**DD-84**) | installer |
| 4 | Docker; sync the Dozzle and FileBrowser accounts to the input file (**DD-119**); sync `qBittorrent.conf` to `templates/qBittorrent.conf` and the input account, stopping the client only to change it (**DD-129**); render `compose.yaml` / FileBrowser config; remove host WebDAV leftovers; install scripts and units | templates |
| 5 | apply `master-firewall` (incl. WireGuard INPUT/FORWARD/NAT); enable refresh timer; then restore a pulled `wg0.conf` + profiles if absent (**DD-128**), `wireguard-tools`, `[Interface]` of `wg0.conf` (key generated once, peers kept) and `wg-quick@wg0` (**DD-120**, **DD-124**) | firewall, WireGuard |
| 6 | dnsmasq/Caddy: mask+apt only if packages missing; render; restart only if config changed; `caddy-wg` for the UIs over WireGuard; WireGuard panel service, page and account (**DD-133**) | DNS/HTTP |
| 7 | Compose `up` if needed; cheap contract checks (incl. WebDAV loopback + Caddy, WireGuard port/`master-wg`/`caddy-wg`, panel 401 without and `/api/state` with the input account, nothing on `10.8.0.1:61008`) | verification |
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

The list is short on purpose. No entry is a genuine `if OS = debian`
branch any more: the last one, `debian-keyring`, was dropped in v2-90
(**DD-125**). Two entries are the same code with an `os-release` value
substituted. The remaining five are *capability probes* that ask the host what
it has rather than what it is called. A probe keeps working on a release the
installer was never run against; a distro switch statement does not. See
**DD-102** and **DD-104**, and `archive/os-aware-review.md` for why the tree is not
forked into per-distribution paths.

<!-- OS-DIVERGENCE-INVENTORY:BEGIN -->

| Slug | Kind | Affects | What differs | DD |
|---|---|---|---|---|
| `tailscale-repo-suite` | identity-derived | both | apt suite and keyring URL come from `OS_ID`/`OS_CODENAME`; both vendors publish the same URL shape | DD-102 |
| `docker-repo-suite` | identity-derived | both | `URIs`/`Suites` from `OS_ID`/`OS_CODENAME` | DD-102 |
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

The lean root tree is executable: `install.sh` runs the seven stages on a
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

`.cursor/rules/` requires six checks at the end of every phase, not two.
Recorded here so a phase cannot quietly declare itself done on `bash -n`
alone:

| Check | Scope | Available on the dev workstation? |
|---|---|---|
| `bash -n` | Root `*.sh`, `scripts/*` and the exporter | **yes** |
| `shellcheck -x` | Same set; `-x` so sourced libraries are followed | **yes** |
| `bats tests/` | Unit suites (repo convention, not from the rules file) | **yes** |
| `docker compose config -q` | The rendered `compose.yaml` | **no** — runs on the target, in stage 4 (**DD-106**) |
| `caddy validate` | The rendered `Caddyfile` | **no** — runs on the target, in stage 6, with the real env (**DD-106**) |
| `dnsmasq --test -C` | The rendered dnsmasq config | **no** — runs on the target, in stage 6 (**DD-106**) |
| `systemd-analyze verify` | Every generated unit and drop-in | **no** — not run; the units are static tree files, covered by bats |

The split matters: the first three can gate every commit, the last four can
only run where the software exists. So a phase that renders a template is
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
| **DD-59** | Chain names | `MASTER-INPUT` and `MASTER-DOCKER`, declared only in `config/defaults.env`. `MASTER-DOCKER-FILTER` is not used. |
| **DD-60** | Does dnsmasq listen on loopback? | Yes — `lo` and `tailscale0`, `bind-dynamic`, nothing else, no DHCP. |
| **DD-61** | Does the refresh helper re-render configs? | No. It updates `state.env` and restarts Caddy (WebDAV was dropped from the set by **DD-77**). dnsmasq, the firewall and the stack are untouched. |
| **DD-77** | Where does WebDAV run? | Compose on `127.0.0.1`, Caddy reverse_proxy; host unit removed. |
| **DD-98** | Apple TV without MagicDNS? | Caddy listens on `${TS_IPV4}:${WEBDAV_PORT}` → loopback WebDAV; Compose has no TS IP. |
| **DD-62** | Portainer's upstream | Superseded by **DD-116**: Portainer was replaced by Dozzle on plain loopback HTTP `127.0.0.1:61002`. |

**DD-59 removed a chain that was never decided on.** `defaults.env`
previously also declared `MASTER-TS-FORWARD`, carried over from v1's
mangle-table chain. It is not part of the fixed name set and no clause of
the contract requires it, so it is gone. If the firewall phase finds that
a `FORWARD`- or mangle-table chain is genuinely needed, that is a new
decision with a new name, not a constant that survives by inertia.

### 10.2 Still open

1. **Public IPv4 change handling** (§5) — extend the refresh helper, or
   document a manual re-run. Note that **DD-61** closes the door on
   solving this inside `refresh-tailnet-config` as currently scoped: doing
   so would mean recreating containers, which that helper must not do.
2. **Comment policy.** Settled for `install.sh` (DD-44: no
   editorial comments; rationale in `docs/design-decisions.md`). Helper
   scripts under `scripts/` may keep short operational comments.
3. **Whether `master-compose.service` returns in a later phase.** It is out
   of the first release; if a public IPv4 change is to be handled
   automatically, it may need to come back in a much smaller form.
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
