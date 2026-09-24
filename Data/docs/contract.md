# Behaviour Contract

**Status:** behaviour contract (frozen intent 2026-08-05). Implemented by the
lean tree at the repository root (`install.sh` and helpers). Where live code and this
document diverge, prefer the code and update this file.

This document is the authoritative statement of what the installer does
and — just as importantly — what it deliberately refuses to do. Removals
relative to the retired monolith (no reconcile engine, no
canonical-bundle machinery, no legacy `master-webdav.service`) are decisions, not
oversights. There is no parallel legacy installer tree.

**v2-129 amendment (DD-159):** Files and folder WebDAV are now installer-owned
built-ins; only WireGuard/qBittorrent remain in the public App Store catalogue.
The [desktop and ZIP contract](desktop-and-archives.md) defines the archive API,
limits, private history and upgrade behavior. This supersedes older optional
Files/Paylaşım lifecycle references below, not their security or data boundaries.

**Relationship to `.cursor/rules/`:** those rules cover the repository and
govern *how* the work is done — process, Bash conventions, the
per-phase verification set, and the hard prohibitions (do not delete other
software's chains such as Tailscale's `ts-*`, do not silently turn the
UDP-only decision into TCP+UDP, do not grow
a general-purpose reconcile engine). This document governs *what the result
must do*. Where the rules are silent (for example on WebDAV), this contract
extends them. Settled disagreements with early rule drafts — dnsmasq
listening scope, chain name, refresh helper scope, Portainer upstream
scheme — are recorded as **DD-59** through **DD-62** in
`design-decisions.md`. Portainer itself was replaced by Dozzle in v2-82
(**DD-116**), and Dozzle was dropped in v2-118 (**DD-151**).

The single active rule source is `.cursor/rules/master-stack.mdc`. The
original RTF is archived unchanged at
`docs/archive/master-stack-rules-source.rtf` and is a historical record
only — it is not edited and nothing synchronises it back.

The twenty numbered requirements referenced as **R1**–**R20** throughout are
the ones agreed on 2026-08-05:

| | Requirement |
|---|---|
| R1 | Update the Debian system |
| R2 | Install required packages |
| R3 | Install Tailscale |
| R4 | Advertise the server as an exit node |
| R5 | Enable Tailscale SSH |
| R6 | Apply IP forwarding and the official Linux exit-node optimisations |
| R7 | Store the Tailscale IPv4 and IPv6 addresses as variables and in a state file |
| R8 | Create `/downloads` and `/downloads/media` |
| R9 | Withdrawn in v2-121 (**DD-152**): Docker Engine and the Compose plugin are not installed; every module is a host systemd service |
| R10 | No Compose at all: Dozzle is gone and qBittorrent is a host module since v2-118 (**DD-151**); since v2-121 the share WebDAV runs rclone on the host and Unpackerr (Arşiv açıcı) is dropped (**DD-148**, **DD-149**, **DD-152**). FileBrowser was retired; Konsol manages the files (**DD-146**) |
| R11 | Publish every web interface on `127.0.0.1` only |
| R12 | Publish publicly the WireGuard UDP port of each network (host kernel since v2-86, **DD-120**; formerly wg-easy). The torrent peer port is no longer opened (**DD-151**): qBittorrent makes outgoing connections only |
| R13 | Ask the operator for a local domain at the start of the installation (since v2-85 read from the installer input file, **DD-119**) |
| R14 | Resolve the defined service names to the Tailscale IPv4 with dnsmasq |
| R15 | Have Caddy listen on the Tailscale IPv4 only, over HTTP |
| R16 | Reverse-proxy the service names to the loopback interfaces through Caddy |
| R17 | Tell the operator to configure Custom DNS and Restrict-to-domain manually in the Tailscale admin panel |
| R18 | Create persistent firewall rules that permit Tailscale traffic, the public peer ports (wg UDP + torrent peer TCP+UDP), and WAN host SSH TCP `${SSH_PUBLIC_PORT}` |
| R19 | Withdrawn in v2-121 (**DD-152**): no Docker, so nothing to filter through `DOCKER-USER`; the firewall never touches that chain |
| R20 | Keep the installation re-runnable |

---

## 1. Included features

### 1.1 Base system

- Supported-OS hard gate (**R1**, **DD-102**): Debian 13 (trixie),
  Ubuntu 24.04 LTS (noble) or Ubuntu 26.04 LTS (resolute); the installer
  refuses any other OS or release. The Tailscale apt repo suite is derived
  from `os-release` (`OS_ID`/`OS_CODENAME`), never hardcoded, and its
  `dists/<codename>/Release` is probed before the source file is written
  (**DD-106**; the Docker repository went with **DD-152**). On a host with
  ufw active the installer stops before any mutation. The
  `iptables`/`ip6tables` backend must be the nft one tailscaled uses, because
  `MASTER-INPUT` is ordered behind its `ts-input` (**DD-152**); stage 0
  asserts this for whichever binaries the host already has and stage 1
  asserts it unconditionally once the package is installed, because a
  minimal Debian image ships none (**DD-106**, **DD-108**). Live-verified on fresh
  Ubuntu 24.04.4 (noble) and Ubuntu 26.04.1 (resolute) hosts on
  2026-08-29/30: full installs passed stages 0–7 and the §14 checks;
  resolute additionally passed a no-op re-run, Tailscale/Docker restart
  recovery and a full reboot.
- The detected release is **recorded**, not only used (**DD-104**):
  `state.env` carries `OS_ID`, `OS_CODENAME`, `OS_VERSION_ID`, `OS_ARCH`
  and `KERNEL_RELEASE`. A re-run whose recorded identity differs from the
  live one warns and re-applies the OS-dependent steps even when the
  written files are byte-identical. A missing record is not treated as a
  release change. Architecture outside
  `amd64` warns; it is not refused.
- Third-party restart managers are suspended for the installer's apt calls
  (`NEEDRESTART_SUSPEND=1`, **DD-103**). Ubuntu's `needrestart` otherwise
  restarts `sshd`, `tailscaled`, `caddy` and `dnsmasq` automatically in the
  middle of a stage.
- Every rendered config is validated on the target before the unit that
  consumes it restarts: `dnsmasq --test -C` and `caddy validate` with the
  real `TAILSCALE_IPV4` (**DD-106**); a module's Caddy site and dnsmasq name
  are validated by `master-modul` before they take effect (§1.11).
- `apt-get update` + `full-upgrade`, then the package set the stack needs
  (**R1**, **R2**): only what the base itself uses (**DD-153**) — no `gnupg`
  (apt reads the armored Caddy key, `signed-by=…caddy-stable-archive-keyring.asc`),
  no `gawk` (the distribution's `mawk` is `awk`), no `apache2-utils`, rclone
  download or `acl` package. Folder WebDAV uses the base Python runtime (DD-158).
- `unattended-upgrades` is installed and enabled for the distribution's own
  origins (Debian stable + security; Ubuntu security), with automatic reboot
  off; Tailscale and Caddy packages are updated only by a re-run
  (**DD-113**). WebDAV code updates with the installer (§7).
- Timezone set to the configured value.
- Root-only, single-host, `flock`-serialised, wrapped in `systemd-inhibit`
  so a shutdown cannot land mid-transaction.
- **Inputs come from one file, not prompts (DD-119).**
  - The operator fills `kurulum/kurulum.env` (git-ignored, mode `600`;
    template `config/kurulum.env.example`) beside the portable `.command`.
  - The launcher sends it only to `INPUT_FILE` in `/run` (`tmpfs`). Stage 0
    reads it right after the root check and deletes it before any other gate,
    whether or not it validates.
  - It is never sourced: one `KEY=value` per line, values taken literally.
    Unknown, duplicate, missing, quoted, padded or CRLF lines stop the
    install. Messages name the line and key, never the value.
  - Stage 0 validates every value, prints them without passwords and asks for
    one confirmation before `config.env` is written. Re-runs still ask about
    full-upgrade (the image-pull question went with **DD-151**); an
    interactive TTY stays required.
- **Nothing but `kurulum.env` reaches the server (DD-143).** The launcher sends
  that one file; no WireGuard configuration, key or profile is read from
  `kurulum/` or uploaded, and nothing is fetched back. `wireguard.command` may
  download a profile and its QR picture on request (**DD-132**), for the
  operator only.

### 1.2 Tailscale

- Official Tailscale repository and package (**R3**).
- There is no auth key input (**DD-147**): the node always joins through the
  login link that stage 2 prints, and the operator approves it in a browser.
  Nothing Tailscale-related is typed into or stored by the installer.
- `tailscale up --advertise-exit-node --ssh`, then `tailscale set` to hold
  exit-node, SSH, stateful filtering, netfilter mode and subnet-route SNAT
  (**R4**, **R5**).
- **The 410 login-recovery mechanism is preserved** — three bounded
  attempts, `auth_path_dead` classified from the LocalAPI (never from the
  journal), daemon reset between attempts, dependency-isolated restart.
  This is the one failure mode an operator cannot recover from unaided, and
  it was earned by a real incident.
- IPv4 and IPv6 forwarding sysctls, UDP socket buffer floor, and the
  **UDP GRO optimisation** are all preserved (**R6**).
- The Tailscale IPv4 **and IPv6** are written to `/etc/master-stack/state.env`
  (**R7**). v1 never persisted the IPv6 address; v2 closes that gap.

### 1.3 No Docker; modules are host services (DD-152)

- **No Docker (v2-121, DD-152).** The installer adds no Docker apt
  repository and installs no `docker-ce`, `containerd` or Compose package; it
  writes no `/etc/docker/daemon.json` and no `docker.service.d` drop-in, and
  there is no container, image or Compose file. Every module is a systemd
  service on the host (§1.11) (**R9** withdrawn).
- The installer's own apt downloads are not kept in `/var/cache/apt/archives`
  (`APT::Keep-Downloaded-Packages=false`) (**DD-125**).
- Dozzle is gone (**DD-151**): every module card has a Günlük panel reading
  the unit's journal. There is no image-pull question on re-runs.
- Arşiv açıcı (Unpackerr) is dropped (**DD-152**): it left the catalogue,
  the templates, Konsol and the downloads tree. Nothing replaces it.
- **qBittorrent is a host module (DD-151)**, installed from Konsol (§1.11): the
  distribution's `qbittorrent-nox` runs on the server as the downloads account.
  The installer holds no qBittorrent account, settings template or peer port;
  `TORRENT_USER`/`TORRENT_PASS` are gone with DD-129's settings sync.
- There is no FileBrowser (**DD-146**): no service, no account in the input
  file, no port and no database. Files are managed in Konsol (§1.10). The
  old name `file.${LOCAL_DOMAIN}` is gone (**DD-154**).
- Every web interface and WebDAV listens on `127.0.0.1` only (**R11**).
- Module services survive a reboot as enabled systemd units; a module stopped
  from Konsol is disabled and stays stopped (§1.11). systemd's `Restart=`
  handles a crash.

### 1.4 Directories

- `/downloads`, `/downloads/media`, `/downloads/media/movies` and
  `/downloads/media/series` are created when absent (**R8**); there is no
  Unpackerr work directory since **DD-152**.
- **The downloads tree is repaired selectively on every run** (**DD-84**):
  entries whose UID/GID differ from `DOWNLOADS_UID`/`DOWNLOADS_GID`
  (defaults `1000:1000`) are `chown -h`'d; directories not mode `0775` and
  files not mode `0664` are `chmod`'d. Matching entries are left untouched
  (no full-tree rewrite). qBittorrent and Konsol's file backend share
  read/write that way. WebDAV enforces each account's RO/RW permission (DD-158).

### 1.5 DNS and Caddy

- dnsmasq bound to loopback and `tailscale0`, tracking the interface address with
  `interface-name` + `bind-dynamic`, resolving the installed service names to the
  current Tailscale IPv4 (**R14**).
- Caddy listening on the Tailscale IPv4, port 80, HTTP only, reverse-proxying
  to loopback upstreams (**R15**, **R16**).
- The real Konsol page and backend/gate checks verify the HTTP edge. The
  redundant `health.<domain>` endpoint and DNS record are removed (**DD-157**).

### 1.6 Firewall

- A host `INPUT` policy (the retired installer had none) and, for WireGuard,
  a forwarding and NAT policy, all fail-closed (**R18**). There is no Docker
  forwarding policy since v2-121 (**DD-152**). Full contract in §8 and §9.
- The **staging-chain swap** is preserved wherever it applies: rules are
  built in a throwaway chain and swapped in atomically, so there is no
  window in which the host runs with a partial policy.
- Nothing is persisted to disk. `master-firewall.service` re-applies the
  policy on boot and whenever `tailscaled` restarts
  (`PartOf=tailscaled.service` only, **DD-152**), which keeps `MASTER-INPUT`
  behind tailscaled's `ts-input`.

### 1.7 WebDAV

The share WebDAV is a built-in host service since v2-129 (**DD-159**), using
the folder-scoped Python backend introduced in v2-128 (**DD-158**).
Contract in §5–§7 and `folder-shares.md`.

### 1.8 Operator guidance

- The manual Tailscale admin steps are printed at the end (**R17**, §13).
- No password reminders are printed: every service account comes from
  `kurulum/kurulum.env` (**DD-119**).

### 1.9 WireGuard (DD-120, DD-124)

- **A fresh install has no WireGuard (DD-143, DD-150).** WireGuard is a Konsol
  module (§1.11). The installer only puts `master-wg`, the `caddy-wg@` template,
  `Caddyfile.wg` and an empty `/etc/wireguard` (`0700`, the root backend's only
  writable path, v2-119) in place. Installing the module installs `wireguard-tools`
  and `qrencode` (`--no-install-recommends`), loads the kernel module (and
  writes `WG_MODULES_LOAD_FILE`), creates `/etc/wireguard`, re-applies the
  firewall and starts whatever networks the registry already holds. Nothing
  generates a key, writes a `.conf` or brings up an interface of its own.
- Without the module `master-firewall` ignores the network registry (no
  WireGuard port or rule), `master-wg` refuses every command but `version`,
  and the root backend answers `/api/wg/state` with `installed: false` and
  refuses changes with `409`. Removing the module closes every network
  (`wg-quick@`/`caddy-wg@` disabled) and keeps `/etc/wireguard`, so a
  reinstall brings the networks back; `--veri` also deletes the keys, the
  device profiles and the registry.
- **Networks are created from Konsol** (WireGuard → Yapılandır → Arayüz ekle) or
  with `master-wg net-add`. The first one defaults to `wg0`, `10.8.0.0/24`,
  `fdcc:ad94:bacf:61a4::/112` (peers `…::N`, the hex of the IPv4 host number;
  **DD-135**), UDP `${WG_PORT_DEFAULT}`, MTU `${WG_MTU}`; later ones take the next
  free `wgN` and a port from 61020 upward. No setting describes an installed
  network: `defaults.env` and `state.env` carry only the address base
  (`WG_ADDR_BASE4`, `WG_ADDR_BASE6`), the suggested first port and the peer
  profile defaults.
- **The server is the source of truth.** `/etc/wireguard/wgN.conf` (`0600`)
  holds that network's key and one `# peer: <name>` + `[Peer]` block per device;
  the registry holds the network's parameters. Nothing is restored from the
  workstation (§1.1).
- **Peers are managed with `master-wg`** (`/usr/local/sbin`, root), driven from
  the workstation by `wireguard.command`:
  - `add NAME DNS KEEPALIVE MTU` runs `wg genkey`, `wg pubkey` and `wg genpsk`,
    takes the next free address (IPv4 from `.2`, IPv6 with the same host
    number in hex), stores the device profile in `/etc/wireguard/clients-wgN/`
    (`0600`) and appends the `[Peer]` block. It validates the name, DNS list,
    keepalive (0–65535) and MTU (1280–1500) before any change.
  - `remove NAME` deletes the block and the stored profile.
  - `dns NAME DNS` rewrites only the `DNS =` line in the `[Interface]` part of
    the stored profile. Keys, address and the network's `.conf` stay the same and
    nothing is applied on the server: DNS is a client setting, so the device
    imports the new profile (**DD-130**).
  - `reset --onay` issues a new server key and drops every `[Peer]` block and
    every stored profile. The other `[Interface]` lines are kept. It applies
    like any change; a failed apply restores the network's previous `.conf`
    and keeps the profiles. Without `--onay` it changes nothing (**DD-130**).
  - `list` prints name, address, last handshake, transfer and whether a
    profile is stored; `profile NAME` and `qr NAME` print the stored profile
    or its QR code.
  - `png NAME` writes the profile's QR code as a PNG (8 pixels per module) to
    standard output, and refuses when that output is a terminal (**DD-132**).
  - It takes the installer's lock, so the two never write a `.conf` at once.
  - A failed apply restores the previous `.conf` and removes a new profile.
- **Changes reach a running interface with `wg syncconf`** (no restart;
  connected devices stay up). `wg-quick@wgN` restarts only when it is not
  running, when `Address`/`MTU` changed, or when `syncconf` fails; an empty
  `wg-quick strip` output is never passed on (**DD-123**).
- **`wireguard.command`** (repository root, macOS) reads only `SSH_HOST` from
  `kurulum.env`. It refuses a server whose `master-wg version` differs from
  the repository's `V2_VERSION`. It asks for the name, DNS, keepalive and MTU
  (defaults from `defaults.env`; DNS is Cloudflare IPv4 first, **DD-131**), prints the QR code and saves the profile as
  `kurulum/wireguard/<name>.conf` and its QR picture as `<name>.png` (both
  `600`, **DD-132**). A picture without the PNG signature is not kept; the
  menu warns and the profile stays.
  - Option 7 "DNS değiştir" offers the peer's current DNS as the default,
    then prints the new QR code and saves the new profile.
  - Option 8 "Ağı yeniden üret" lists the peers of the selected network that
    will be lost and runs
    `reset --onay` only after the operator types `onayla`, in any case (**DD-130**, **DD-134**).
  - The menu keeps nothing on the Mac beyond a profile the operator asked for
    (**DD-143**): it never uploads, and a reinstall cannot bring back a removed
    peer, a removed network or an old key.
- **What clients reach:** internet egress (IPv4 and IPv6, masqueraded) and the
  qBittorrent UI at `http://<that network's server address>:${TORRENT_UI_PORT}`
  when its scope is `ui` and the qBittorrent module is installed (**DD-151**). Files are not reachable over WireGuard: Konsol is
  tailnet-only and FileBrowser is gone (**DD-146**).
  Nothing else: not the tailnet, WebDAV, SSH, dnsmasq, other networks or
  other peers (§9).
- The UIs are served by `caddy-wg@wgN.service` (`/etc/caddy/Caddyfile.wg`, admin
  API off, address from `/etc/wireguard/caddy-wg-wgN.env`, written by `master-wg`
  when the network is created). Each instance binds only its own network's server
  address, follows its `wg-quick@wgN` and has no Tailscale dependency, so the
  path survives a Tailscale outage.
- **WireGuard web panel (DD-133).** `master-wg-panel.service` serves a page at
  `http://panel.${LOCAL_DOMAIN}` (**DD-140**) to list, add and remove peers, show a peer's QR code, download its
  profile or picture, change its DNS and regenerate a network.
  - It runs Python 3's standard library only and listens on
    `127.0.0.1:61008`. Caddy exposes it on the tailnet; nothing exposes it on
    a WireGuard network or the WAN.
  - Every change goes through `master-wg` (`info`, `add`, `remove`, `dns`,
    `reset --onay`, `profile`, `png`): same validation, lock and live apply as
    `wireguard.command`.
  - **No password** (**DD-147**): Konsol opens for any device on the tailnet;
    narrowing that is a Tailscale ACL matter. There is no account, no login
    prompt and no lockout.
  - Because nothing else guards it, two gates are mandatory and stage 7 proves
    both on both backends: a request with another `Host` than
    `panel.${LOCAL_DOMAIN}` (or the loopback port) is refused (DNS rebinding),
    and `/api/*` needs the `X-Konsol: 1` header and a same-origin fetch, which a
    page on another site cannot send (CSRF). Adds, removes, DNS changes and regenerations need a
    JSON body; regeneration also needs `confirm` `onayla` (any case, **DD-134**).
  - Responses carry `Cache-Control: no-store`, a CSP with only `'self'` sources
    (plus `blob:` images), `X-Frame-Options: DENY` and no referrer. The page
    loads nothing from other hosts.
  - Keys are never in a listing or preview. The profile preview masks
    `PrivateKey` and `PresharedKey`. The full profile and the QR picture are
    returned only on an explicit request, and the audit line in the journal
    names the user, client, action and peer, never the content.
  - The unit runs with `NoNewPrivileges`, `ProtectSystem=full` with
    `/etc/wireguard` writable (optional: a missing folder never keeps Konsol
    down), `ProtectHome`, `PrivateTmp`, the kernel
    protections and `AF_UNIX`/`AF_INET`/`AF_INET6`/`AF_NETLINK` only.
  - A peer shows "Bağlı" only while data arrives from it: its received bytes
    grew within the last 45 s and its handshake is under 3 minutes old. A
    background sampler reads every network every 10 s (**DD-137**).
  - The header shows the endpoint `WG_ENDPOINT_HOST`, the IPv4 the installer
    detected on the server; no address is written by hand (**DD-138**).
  - Nothing on the Mac is tracked (**DD-143**); `wireguard.command` is managed
    on its own and asks which network to work on.
- **More WireGuard networks from the panel (DD-136).** "Arayüz ekle" creates
  `wg1`…`wg9` at run time with `master-wg net-add PORT SCOPE DNS LABEL`; each
  network has its own tab, server key, UDP port and addresses.
  - Addressing: `wgN` is `10.8.N.0/24` (server `10.8.N.1`) and
    `fdcc:ad94:bacf:61a4::N:0/112` (server `…::N:1`); peers get `10.8.N.H`
    and `…::N:H` (H in hex). Profiles live in `/etc/wireguard/clients-wgN`;
    the interface in `/etc/wireguard/wgN.conf`.
  - Scope per network: `inet` reaches only the internet; `ui` also reaches
    qBittorrent (module) on its own server address through
    `caddy-wg@wgN`. Every network pings its own server address; nothing
    reaches another network, the tailnet, SSH, DNS, WebDAV or the panel.
  - The registry `/etc/wireguard/networks` (one tab-separated line per
    network: interface, port, scope, server and subnet IPv4 and IPv6, default
    DNS, label) is written only by `master-wg`, and read by `master-firewall`
    and the panel. A malformed or clashing registry stops the firewall
    before any chain changes.
  - A new network's port may not be a stack port, another network's port or a
    UDP port already listened on; the next free number is taken (from `wg0`, at
    most `WG_NETWORKS_MAX`, 9).
  - Order when adding: files and registry, `master-firewall` restart, then
    `wg-quick@wgN`, then `caddy-wg@wgN` for `ui`. A failing step removes
    every trace of the network and restores the firewall.
  - `master-wg --if wgN` runs any peer command on that network;
    `net-remove wgN --onay` stops its units, deletes its files, key, peers and
    registry line and re-applies the firewall. Every network can be removed,
    `wg0` included (**DD-143**); removing the last one leaves the layer ready
    and Konsol back at "Yapılandır".
  - The panel confirms regenerating or removing a network with `onayla`.
  - **Switches (DD-140).** `master-wg [--if wgN] net ac|kapat` stops or starts
    `wg-quick@wgN` (and `caddy-wg@wgN`); the registry, keys and profiles stay
    and the UDP port stays open with nothing listening. `master-wg peer AD
    ac|kapat` comments the peer's block out of the interface configuration, so
    it leaves the running interface at once and stays off across a reboot with
    its key, address and profile intact. `master-wg keepalive AD SANİYE`
    rewrites only the profile's `PersistentKeepalive`.
  - Networks and their units survive reboots and installer re-runs; the
    installer manages only `wg0` and refuses a `wg0` or WebDAV port that a
    panel network uses. The Mac backup and the restore cover `wg0` only.

### 1.10 Konsol and the file backend (DD-139, DD-140, DD-150)

- The file backend and bounded ZIP worker are built in (**DD-159**). The
  installer prepares their downloads account, `SERVER_ROOT`, private archive
  workspace and staged unit; `master-modul yerlesik` installs/enables/checks the
  unit. Files is always present in Konsol, independent of the app catalogue.

- **One console (DD-140).** `http://panel.${LOCAL_DOMAIN}` is the only
  administration page. Caddy serves the page files itself from
  `CONSOLE_WEB_DIR` (CSP, `no-store`, `nosniff`, `X-Frame-Options: DENY`, no
  referrer), sends `/api/wg/*` and `/api/konsol/*` to `master-wg-panel` and
  every other `/api/*` to `master-files-panel`. The old names `wg.`, `dosya.`
  and `file.${LOCAL_DOMAIN}` no longer exist (**DD-154**). Both backends
  accept only that host and require the header `X-Konsol` on `/api/*`
  (**DD-147**).
  - Pages: Genel bakış (server card with CPU, memory and disk, WireGuard
    devices, last actions, ports in use), installed WireGuard, Dosyalar,
    App Store (§1.11), Günlük and Ayarlar; a launcher and dock wrap them (DD-159).
  - Ayarlar (**DD-156**, superseding DD-155) has four tabs. `GET
    /api/konsol/ayarlar` retains the same gates and 5 s cache (`?yenile=1`
    bypasses it); `/durum` reads transaction state and `/klasorler` lists
    allowed existing download folders. No password/hash is returned.
    - Güvenlik Duvarı shows real IPv4/IPv6 rules and counters from all
      iptables tables, listening sockets, and the baseline policy check.
      Structured port overrides have family, WAN/tailnet/WireGuard scope,
      TCP/UDP port, optional source CIDR and allow/deny action. Only these
      overrides are editable; core and third-party rules are read-only.
      `CHAIN_SETTINGS` precedes `ts-input`, so a tailnet deny is effective.
      Loopback, established flows and ICMPv6 protections remain intact.
      Permission does not imply a reachable listener; no bind address is changed.
    - Caddy shows base/module/WireGuard sites and their routes. Its local-domain
      field changes the single-label suffix (1–63 lowercase letters/digits/hyphens,
      no leading/trailing hyphen) as a separate transaction (**DD-157**).
      Base/module DNS and Caddy renderings, custom record suffixes, disabled
      names, `state.env` and staged/installed file-backend units move together.
      Only an active file backend restarts; Caddy reloads gracefully. Credentials,
      VPN profiles, IP-based share links and download data stay untouched.
      Before applying, the operator adds the new restricted domain to Tailscale
      Admin DNS and retains the old mapping until confirmation. The server
      cannot edit those account settings. Confirmation must arrive through
      the new panel Host within five minutes; otherwise the guard restores
      the previous domain. No old-name alias or arbitrary Caddy editor is added.
    - Dnsmasq permits on/off for managed names, exact custom names within
      `LOCAL_DOMAIN`, and optional public upstream IPs. Missing/disabled
      private names stay local. Base/module collisions and local/self
      upstreams are rejected; loopback/tailnet listeners stay unchanged.
      This neither creates Caddy sites nor edits Tailscale Admin DNS.
    - qBittorrent permits username, optional new password (12–256 characters)
      and the default folder for new torrents. Blank in the UI preserves
      the password. Only canonical existing non-hidden downloads/media
      directories may be chosen; write permission is probed as the service
      UID and narrowly added to its systemd sandbox. Existing files/torrent
      locations and incomplete paths are not moved. Stop/snapshot/write/
      restart avoids overwriting a live application's settings.
    `POST /api/konsol/ayarlar/{uygula,onayla,geri-al}` runs an independent
    worker with JSON on stdin, never a password on argv/in logs. Review is
    followed by a 60 s confirmation window (300 s for a domain change). The server-side guard timer
    restores unconfirmed settings after disconnect, timeout or reboot;
    failed recovery remains pending for retry. Stale revisions and concurrent
    installer/module writes are refused. Confirmation cannot preserve a rule
    that blocks the confirming client's new console/DNS connections or the
    console's own DNS name. `SETTINGS_FILE` owns confirmed firewall/DNS/domain
    choices across re-runs; `SETTINGS_PENDING_FILE` is root-only recovery data,
    not a portable backup. qBittorrent remains the owner of its profile.
  - The ports card is built from `state.env`, the module registry and the
    network registry; nothing is scanned.
  - A peer or a whole network can be switched off and on (§1.9).
- **Folder shares (DD-158):** Files v09 offers list/cards, details and a WebDAV
  tab. The root backend manages separate accounts, RO/RW, expiry and pause.
  The file backend's legacy share mutations return 410. See §5–7.
- `master-files-panel.service` serves a file manager API for
  `SERVER_ROOT`: browse, search the current folder, select many items, new
  folder, rename, move, move to trash, restore, delete from the trash, empty
  the trash, read a text file, download a file and **upload** files
  (**DD-145**).
  - Upload is `POST /api/upload?path=&name=`, the body being the file itself.
    It writes a temp name in the target folder, `fsync`s, then renames into
    place, so a half-written file never appears in the listing and an existing
    name is never overwritten (409). The stream runs without the panel lock;
    only the final rename takes it. The file lands `0664`.
  - The console has no separate upload area: files are dropped onto the list
    itself, appear there as rows and show their progress in the row.
  - It runs Python 3's standard library only and listens on
    `127.0.0.1:61009`. Caddy exposes it on the tailnet; nothing exposes it on
    WireGuard or the WAN.
  - It runs as `DOWNLOADS_UID`/`DOWNLOADS_GID`, never as root.
    - systemd needs a user entry for that uid. The installer uses an existing
      name, or creates the system account and group `DOWNLOADS_ACCOUNT`
      (`master-downloads`, no login, no home). File ownership stays numeric.
    - The unit has no capabilities and `ProtectSystem=strict` with only
      `DOWNLOADS_PATH` writable, plus `ProtectHome`, `PrivateTmp`,
      `PrivateDevices` and `NoNewPrivileges`.
  - No password, like the WireGuard backend (**DD-147**). `Host` check, CSP,
    `no-store` and the audit log match it (the actor is logged as `konsol` with
    the client address). `/api/*` needs the `X-Konsol: 1` header and a
    same-origin fetch; only a download, opened as a link, needs no header, and a
    cross-site download is still refused.
- The file panel never leaves its root and never overwrites.
  - Every path step is opened from a directory descriptor with `O_NOFOLLOW`. A
    symbolic link is listed but never followed, and `..` and `/` are refused.
  - Rename and move use `renameat2(RENAME_NOREPLACE)`. An existing target
    refuses the operation, and a folder cannot move into itself.
  - Names over 255 bytes or with `/` are refused; new names may not contain
    control characters or leading and trailing spaces.
- Delete moves the item into `DOWNLOADS_PATH/.cop/<id>/` with a small origin
  record, on the same disk.
  - Restore puts it back where it was, or into the root if that folder is gone.
    A taken name gets a number.
  - Deleting permanently works only from the trash; emptying it needs
    `onayla`. The trash is not reachable through any path, and the root listing
    hides it.
  - The installer creates the folder. It lies outside `SERVER_ROOT/downloads`,
    so qBittorrent never sees it (**DD-144**); the share WebDAV serves only
    the share root and sees the trash as an empty tmpfs (**DD-152**).
- Text view: the first 1 MiB of a regular file.
  - A file with a NUL in the first 8 KiB is refused as binary.
  - The encoding is guessed (UTF-8, else Windows-1254; `.nfo` in CP437) or chosen
    by the operator, and decoded on the server.
  - The page inserts the text as text nodes only.
- The page marks qBittorrent's temporary folder (`DOWNLOADS_SUBDIR/TORRENT_TEMP_DIR`,
  the one the module's first settings name) and warns before moving or
  deleting there.
- It replaced FileBrowser (**DD-146**).

### 1.11 App Store and built-ins (DD-148, DD-149, DD-159)

- A clean install includes Files, folder WebDAV and ZIP. Optional applications
  are installed/removed from Konsol → App Store: `wireguard` and `torrent` only.
  qBittorrent also supports start/stop; WireGuard has its own network switches.
  No Docker or separate unpacker. Public module verbs reject `dosya`/`paylasim`;
  they are protected internal IDs, not installable/removable applications.
- The installer, on every run:
  - installs `/usr/local/sbin/master-modul` and renders each module's files to
    `MODULES_DIR/<id>/` (`/usr/local/share/master-stack/moduller`): for
    Paylaşım `master-paylasim.service` (the credential-loaded unit), `paylasim.caddy` and `dnsmasq.conf`; for
    qBittorrent `qBittorrent.conf` (the first settings), `master-stack.conf`
    (the unit drop-in), `torrent.caddy` and `dnsmasq.conf`;
  - creates `MODULES_FILE` (`/etc/master-stack/moduller`) empty when absent,
    and `CADDY_MODULES_DIR` (`/etc/caddy/moduller`), which the base Caddyfile
    imports (`import …/*.caddy`, after the global options); the file backend's
    unit is staged in `MODULES_DIR/dosya/` before built-in activation;
  - invokes `master-modul yerlesik` to enable/check Files and WebDAV, preserve
    their account/history state, and restart only changed/inactive services;
  - never automatically installs/removes optional apps. When a rendered file
    changed and the optional module is registered
    (`calisiyor` or `durduruldu`), stage 7 first runs
    `master-modul uygula <id>`; WireGuard is re-applied on every run while
    installed. A failure is a warning, not a stop.
  - always checks built-in Files/WebDAV; checks WireGuard networks only while
    the optional application is installed.
- `master-modul` (root):
  - `liste` prints, per catalogued module, `id runtime registry live action
    step total text` separated by tabs; `runtime` is `konsol` or `host`,
    `registry` is `yok`, `calisiyor` or `durduruldu`.
  - `kur ID`, `baslat ID`, `durdur ID`, `kaldir ID [--veri]`, `gunluk ID
    [LINES]`, `uygula ID`; `hesap torrent [--parola]` reads the temporary login.
    The old shared-account commands refuse. Any other id, verb or argument is refused before
    anything runs.
  - Changes take `RUNTIME_DIR/modul.lock`; a second operation waits up to 5 s
    and then fails.
  - Progress is one line in `RUNTIME_DIR/modul-<id>.ilerleme`:
    `action step total text`, ending with step `bitti` or `hata` and the
    reason. Each step is also written to the journal (`master-modul`).
    `uygula` writes no progress line.
  - A host application (`torrent`) is a systemd unit; there is no
    Docker module (**DD-152**). `kur` installs, starts, checks and registers
    it; on failure it takes back what it did and registers nothing. `durdur`
    disables and stops the unit (it stays stopped after a reboot; the names
    stay). `uygula` re-applies a registered module's files and starts it only
    if it is registered as running.
  - `--veri` deletes only the module's own data. User files are never module
    data.
- Built-in Files (`dosya`, **DD-159**): `yerlesik` places its unit, enables and
  checks it as `DOWNLOADS_UID`, verifies Caddy and the `X-Konsol` gate. Public
  module operations cannot remove it or empty its trash. Archive behavior is
  specified in `desktop-and-archives.md`.
- WireGuard (`wireguard`, **DD-150**): `kur` in four steps — packages, kernel
  module, firewall hook (the module is registered, then `master-firewall` is
  restarted), networks from the registry. `kaldir` closes the networks,
  unregisters the module, re-applies the firewall and removes
  `WG_MODULES_LOAD_FILE`; `--veri` also empties `WG_CONF_DIR`. `uygula`
  (every installer run while installed) makes sure of the packages, the kernel
  module and the networks. `gunluk` reads `journalctl -u wg-quick@*`.
- qBittorrent (`torrent`, **DD-151**): `kur` in four steps — package
  (`qbittorrent-nox`), service unit, service start, name.
  - It runs as `qbittorrent-nox@<downloads account>.service`, the package's
    template unit plus the drop-in `UNIT_DIR/qbittorrent-nox@.service.d/master-stack.conf`:
    profile in `TORRENT_PROFILE_DIR` (`/var/lib/qbittorrent`), `UMask=0002`,
    `ProtectSystem=strict` with only the profile and `DOWNLOADS_PATH`
    writable, the trash and the share root inaccessible, no new privileges.
  - Its settings are written once, when the profile has none: save path
    `DOWNLOADS_PATH`, temporary folder `DOWNLOADS_PATH/TORRENT_TEMP_DIR`, web UI
    on `127.0.0.1:TORRENT_UI_PORT` with local authentication, UPnP, port
    forwarding and Local Peer Discovery off (v2-120), the legal notice
    accepted. After that nothing touches them; changes made in qBittorrent
    stay.
  - `kur` checks that it runs as `DOWNLOADS_UID`, that the trash and share root
    are inaccessible to it, that its API answers `403` without a login on
    `127.0.0.1:TORRENT_UI_PORT` and through `torrent.${LOCAL_DOMAIN}`, and that
    the name resolves; a failed install is taken back.
  - Names: `torrent.${LOCAL_DOMAIN}` (Caddy site and dnsmasq name, like
    Paylaşım's). On WireGuard networks with local access `caddy-wg` serves the
    same interface on the network's server address.
  - No inbound peer port: the firewall opens nothing for it. qBittorrent
    still listens on its own random peer port on every interface; new WAN
    traffic to it is dropped in both families, the tailnet can reach it.
  - The account is not Konsol's: qBittorrent prints a temporary password to
    its journal on each start until one is set in its UI. `hesap torrent`
    reads this run's journal (`_SYSTEMD_INVOCATION_ID`) and prints
    `user<TAB>gecici|ayarli` (with `--parola` also the temporary password);
    `gunluk` masks that line.
  - `durdur` disables and stops the unit (the name stays); `kaldir` removes the
    names and the drop-in and stops the unit but leaves the package installed;
    `--veri` deletes the profile (settings and torrent list) — only under
    `/var/lib` — never a downloaded file.
- Built-in Paylaşım (**DD-158/159**): prepare a registry only if absent,
  place/enable the unprivileged service, check UID/anonymous 401, then publish/
  check Caddy and DNS. An upgrade activates older stopped instances. Unchanged
  reruns do not rewrite accounts or restart healthy services. Remove individual
  accounts through Files; module stop/removal is no longer exposed.
- The root backend (`master-wg-panel`):
  - `GET /api/konsol/moduller` → `{items: [{id, runtime, installed, state,
    live, busy, progress}]}`. `busy` is a running `master-modul-<id>.service`,
    read with `systemctl list-units` (v2-120: `is-active` on a collected
    transient unit wrote two journal lines per query).
  - `POST /api/konsol/moduller/<id>/(kur|baslat|durdur|kaldir|parola)`, JSON
    body, `{"veri": true}` honoured for `kaldir` only; `parola` only for
    no module since DD-158 (404). The id
    must be in `liste` (else `404`). It starts `systemd-run
    --unit=master-modul-<id>.service --collect master-modul <verb> <id>` and
    answers `202`; while that unit is active the answer is `409`. The audit
    line is `modul-<verb>`.
  - Retired shared-account hesap/parola endpoints return 404. Folder shares use
    GET /api/konsol/paylasim and POST kaydet/durum/kaldir below that path.
  - `GET /api/konsol/moduller/<id>/gunluk` → the last 80 log lines as text.
  - The `SHARE_PORT` row of the ports card and `share.on` in
    `/api/wg/sistem` follow the Paylaşım module, the `TORRENT_UI_PORT` rows
    the qBittorrent module and the `FILES_PANEL_PORT` row the Dosya yöneticisi
    module (v2-120); the ports stay reserved for WireGuard networks either
    way.
  - The same Host and `X-Konsol` gates as `/api/wg/*` apply (**DD-147**).
- Konsol never retrieves a stored WebDAV password; enter or generate it in the
  folder form. Blank password on edit preserves its hash (DD-158).

---

## 2. Deliberately excluded features

Each entry names the v1 mechanism, its cost, and why it is gone.

| Excluded | Legacy cost | Why it is excluded |
|---|---|---|
| **Canonical generation directory, `SHA256SUMS` manifest, `current` pointer** | ~400 lines, 3 bats suites, 6 DD entries | Served no requirement. The correct way to repair a drifted managed file is to re-run the installer (**R20**), not to have a timer silently revert it. |
| **Automatic file restore from a canonical copy** | ~90 lines of restore blocks | Same. An operator edit is now an operator's decision; v2 never silently reverts it. |
| **The 1821-line `master-network-reconcile`** | 33% of the file | Replaced by `refresh-tailnet-config`, which does one thing: react to a Tailscale address change. |
| **General container self-healing** | `probe_compose_runtime` + 12 probes + restart engine | systemd's `Restart=` handles a module's crashes (Compose's restart policy did until v2-121, **DD-152**). A health probe that restarts services turns every upstream change into a restart loop. |
| **Restart cooldown stamp files** | ~120 lines, `/run` stamps, 4 duplicated constants | systemd already rate-limits with `StartLimitIntervalSec`/`StartLimitBurst`. A second, parallel accounting system that then exempts itself is not a safety net. |
| **Image-digest-based recovery** | digest recording + final cross-check | No image is used since v2-121 (**DD-152**). Since v2-128 the folder WebDAV runtime is shipped with the installer; no rclone release download (**DD-158**). |
| **Disk and inode threshold checks** | ~40 lines | Reports without repairing — that is monitoring, not installation. |
| **Default-password auditing of FileBrowser** | ~50 lines, a daily login attempt against the container | Nothing to audit: FileBrowser itself was retired in v2-114 (**DD-146**). |
| **`master-compose.service`** | 24-line unit + ~45 dependency assertions | Not in the first v2 release, and there is no Compose since v2-121 (**DD-152**): every module is its own enabled systemd unit. |
| **`master-compose` coupled to `tailscaled` via `Requires`/`PartOf`** | — | No module binds to the Tailscale address, so the coupling only meant that restarting `tailscaled` bounced the entire stack. **A Tailscale restart must not restart a module.** |
| **Host `master-webdav.service` / `webdav.env` / distro `rclone`** | unit + ACL user + apt | Replaced by Compose `webdav` on loopback (**DD-77**), and since v2-121 by the Paylaşım module's `master-paylasim.service` with rclone's pinned release binary, not the distribution package (**DD-152**). The installer never installs the old unit, file or package; it also no longer hunts for them — the migration cleanup was removed in v2-62 (**DD-96**). |
| **Migration cleanup for older revisions** | `purge_host_webdav_leftovers`, `remove_stale_filebrowser`, retired unit/symlink deletion (~83 lines) | The upgrade path is a fresh install or a re-run that overwrites what the installer owns. A global `apt-get purge`, a `userdel`, or deleting a container the operator may still want is outside the installer's boundary (**DD-96**). |
| **`master-docker-netfilter-recovery`** | 47-line script + unit | Docker's own chains were re-established by Docker and v2 re-applied only its own chain; since v2-121 there is no Docker at all (**DD-152**). |
| **DNS/Caddy rollback state machine** | ~155 lines, 19 globals, 7 tests | Fail-closed masking is kept (2 lines); a failed install leaves the optional services *masked*, which is safe. Recovery is a re-run. |
| **The 25-flag reconcile `--check` surface** | — | Replaced by a small set of checks with one owner each. |
| **Progress bar, ANSI colour, extra file descriptors 3/4/5** | ~210 lines | Plain timestamped stage lines plus a log file. |

---

## 3. Port publication contract

Three exposure classes, and nothing may straddle them.

### 3.1 Public (WAN IPv4)

No module gets a WAN port, and there is no Docker publish (**DD-152**). The
torrent peer port (61005) is gone since v2-118 (**DD-151**): qBittorrent is
a host module that makes outgoing connections only.

**WireGuard is a host listener (DD-120):** the kernel's `wg0` socket on UDP
`${WG_PUBLIC_PORT}` (61001) is admitted by `MASTER-INPUT` on the WAN
interface.

**Host SSH is a separate MASTER-INPUT exception:** inbound TCP
`${SSH_PUBLIC_PORT}` (default 22) on the WAN interface is accepted so
console recovery and public-IP SSH keep working.

The firewall limits NEW WAN traffic to each WireGuard network's UDP port
(IPv4 only), host SSH and Tailscale's own UDP port (`TAILSCALE_UDP_PORT`).
(R12 was revised on 2026-08-06/07 for the Docker-published torrent peer
port; that port went with **DD-151**, Docker with **DD-152**.)

### 3.2 Tailnet (Tailscale IPv4) — reachable only over `tailscale0`

| Service | Listen address | Port | Protocol |
|---|---|---|---|
| Caddy | `${TS_IPV4}` | 80 | TCP, HTTP only |
| dnsmasq | `${TS_IPV4}` (via `bind-dynamic`) | 53 | UDP + TCP |

dnsmasq also listens on `127.0.0.1:53` (**DD-60**), so the host itself can
resolve the service names and the installation can verify DNS without
bringing a tailnet device into the loop. Those two interfaces — `lo` and
`tailscale0` — are the only ones it binds. No WAN interface, no ordinary
LAN interface, no unbounded `0.0.0.0` listener, and no DHCP service.
### 3.3 Loopback only

| Service | Listen address | Port |
|---|---|---|
| qBittorrent WebUI (`torrent` module; only while installed) | `127.0.0.1` | 61006 (**DD-127**, **DD-151**) |
| Konsol WireGuard backend (`master-wg-panel`) | `127.0.0.1` | 61008 (**DD-133**, **DD-140**) |
| Konsol file backend (`master-files-panel`; Dosya yöneticisi module only) | `127.0.0.1` | 61009 (**DD-139**, **DD-140**, **DD-150**) |
| WebDAV — shares only (`paylasim` module; only while installed) | `127.0.0.1` | 61010 (**DD-141**, **DD-142**, **DD-149**) |

Reached from the tailnet through Caddy (**R11**, **R16**, **DD-98**):
the share WebDAV on `paylas.*:80` and `${TS_IPV4}:${SHARE_PORT}`. No
loopback service names the Tailscale address. No WAN / `0.0.0.0` listener.

### 3.4 Single source of truth

Every number above is declared exactly once, in `config/defaults.env`,
and reaches the module templates, the Caddyfile, the firewall script and the
state file by substitution. A port literal appearing twice is a bug.

### 3.5 WireGuard (`wg0`) — reachable only by WireGuard clients

| Service | Listen address | Port |
|---|---|---|
| caddy-wg@wgN → qBittorrent (`ui` networks; module only) | that network's server address | 61006 (TCP, HTTP only) |

No names, no WebDAV, no dnsmasq on any WireGuard network (**DD-120**,
**DD-136**). Each network's UDP port is open on the WAN in `MASTER-INPUT`.

---

## 4. DNS and Caddy service map

`${LOCAL_DOMAIN}` initially comes from the installer input file (**R13**, **DD-119**);
an empty value takes `DEFAULT_LOCAL_DOMAIN` from `defaults.env`. A domain
subsequently confirmed in Konsol (`SETTINGS_FILE.domain`) takes precedence
on re-runs (**DD-157**); the operator's Mac input file is never edited.

| Name | dnsmasq answer | Caddy site | Upstream |
|---|---|---|---|
| `torrent.${LOCAL_DOMAIN}` (qBittorrent module only) | `${TS_IPV4}` | `http://torrent.…` | `127.0.0.1:61006` (**DD-117**, **DD-151**) |
| `paylas.${LOCAL_DOMAIN}` (Paylaşım module only) | `${TS_IPV4}` | `http://paylas.…` and `http://${TS_IPV4}:61010` | `127.0.0.1:61010` (**DD-149**) |
| `panel.${LOCAL_DOMAIN}` (Konsol) | `${TS_IPV4}` | `http://panel.…` | page files from `CONSOLE_WEB_DIR`; `/api/wg/*` and `/api/konsol/*` → `127.0.0.1:61008`, other `/api/*` → `127.0.0.1:61009` (**DD-140**) |

The old names `wg.`, `dosya.` and `file.${LOCAL_DOMAIN}` no longer exist
(**DD-154**); `health.` is also retired (**DD-157**). `SERVICE_NAMES` is `panel`.

Rules:

- dnsmasq answers locally for `${LOCAL_DOMAIN}`. Other queries are `REFUSED`
  by default; optional public upstream forwarding is configured in Ayarlar
  (**DD-156**). Private-domain misses/disabled names never go upstream.
- dnsmasq listens on `lo` and `tailscale0`, with `bind-dynamic`, and on
  nothing else (**DD-60**).
- **The current Tailscale IPv4 is never written into the dnsmasq
  configuration.** Records are interface-based (`interface-name=…,tailscale0`),
  which resolves to whatever address the interface currently holds, so
  tearing down and recreating `tailscale0` needs nothing regenerated.
- **Acceptance test:** a query arriving over loopback must answer
  `${TS_IPV4}` — not `127.0.0.1` or `NXDOMAIN`. Stage 7 measures
  `dig +short … @127.0.0.1` and `@${TS_IPV4}` for every name in
  `SERVICE_NAMES`; both must return `${TS_IPV4}`.
- Every Caddy site is explicitly `http://`. No automatic HTTPS, no ACME,
  no certificate machinery — the tailnet is the transport security boundary.
- Every upstream is plain HTTP on loopback. The only HTTPS upstream,
  Portainer's (**DD-62**), went with Portainer in v2-82 (**DD-116**).
- The base names live in one list (`SERVICE_NAMES`) mirrored in both templates;
  adding a service means editing that list and both templates. A module's
  names live in its own files and come and go with it (**DD-149**).

---

## 5. Folder WebDAV: purpose (DD-158)

Selected folders, not a shared symlink root, are published through independent
accounts and stable /s/<id>/ URLs. RO is the default; RW includes permanent
delete/overwrite and requires acknowledgement. The binding implementation
details are in [folder-shares.md](folder-shares.md).

## 6. WebDAV credentials and permissions (DD-158)

SHARE_STATE_FILE is a 0600 root-owned schema-2 JSON registry of users, salted
scrypt hashes, folder identity, RO/RW, pause and expiry. No plaintext password
copy exists. The root API projects only non-secret metadata; fixed workers
receive mutations on stdin under the existing panel gates and operation locks.
The unprivileged data service receives a LoadCredential copy at start.
No password enters argv, logs, environment files or browser storage.

Each request authenticates against exactly one share. Directory descriptors,
nofollow and birth-time/inode checks enforce its root. Expiry is checked on
requests and transfer chunks, not listings. PUT replaces only after completion.
Account changes restart the active data service and interrupt all transfers;
stopped services stay stopped. Remove revokes only access, not shared files.
Root administrators and passwordless Konsol remain outside this isolation boundary.

## 7. WebDAV service lifecycle (DD-158)

master-paylasim.service runs master_webdav.py as DOWNLOADS_UID/GID on loopback,
with no capabilities, system paths read-only, user area writable, internal
trash/share paths inaccessible, and network restricted to loopback. There is
no rclone download or shared account. Caddy publishes the existing name and
Tailscale IP:SHARE_PORT. No WAN listener, extra port or Tailscale policy change.

The installer prepares an empty registry only when absent and enables this
built-in service. Reruns preserve accounts; public module removal is refused.
It keeps the existing staged templates for compatibility. Address refresh changes
Caddy, not WebDAV. Old shared-account URLs are retired; recreating folder
accounts is required. Existing files remain; no broader route is retained.

The supported DAV subset, filesystem and concurrency limits, migration and test
commands are specified in [folder-shares.md](folder-shares.md). Finder/Infuse
and recipient ACL reachability need separate operator acceptance.

---

## 8. Host firewall contract (`INPUT`)

The retired installer filtered only Docker's forwarded traffic and left host
services exposed to whatever the provider's network allowed.

Accepted:

1. Loopback (`lo`) traffic.
2. `ESTABLISHED,RELATED` connections — this is what keeps the operator's
   **currently active SSH session alive** while the policy is installed.
3. **All inbound traffic arriving on `tailscale0`.** This is the single
   permission that makes WebDAV, Caddy and dnsmasq reachable; none of them
   gets an individual rule.
4. New inbound TCP on the WAN interface to `${SSH_PUBLIC_PORT}` (host sshd).
5. New inbound UDP on the WAN interface to `${WG_PUBLIC_PORT}`.

Dropped:

6. Every other new inbound connection arriving on the WAN interface.

Rules:

- The policy is applied through a staging chain and swapped in atomically,
  so there is no moment at which SSH is unreachable. At the **end** of a
  successful apply every leftover staging chain is removed together with its
  parent jump, including one left referenced by an interrupted earlier run
  (**DD-95**).
- Boot exposes a measured ~850 ms window between the WAN address becoming
  usable and the policy landing; sshd, which the policy allows anyway, was
  the only WAN listener in it when measured (Docker then started later,
  behind the policy; there is no Docker since **DD-152**). Rules
  are not persisted to disk (**DD-66**), so this window is accepted, not
  closed (**DD-95**).
- Ordering guarantees that rule 2 precedes rule 7.
- The WAN interface is the **live default route at apply time**, not the
  `WAN_INTERFACE` recorded in `state.env`. A renamed NIC produces a warning
  and a correct policy; it no longer makes the unit fail with no policy at
  all (**DD-94**).
- There is **no** WAN permission for WebDAV, Caddy, dnsmasq, or any
  module web interface.
- IPv6 `INPUT` follows the same shape and is equally fail-closed. Tailscale
  IPv6 traffic is permitted; WAN IPv6 allows NDP/ICMPv6 essentials, host
  SSH TCP, and drops other NEW WAN traffic.

---

## 9. Forwarding firewall contract (Docker part removed)

The Docker part was removed in v2-121 (**DD-152**): Docker is not
installed, so there is no `MASTER-DOCKER` chain, the firewall never touches
`DOCKER-USER`, and `CHAIN_DOCKER` is gone from `defaults.env` and
`state.env`. What remains here is the WireGuard forwarding and NAT policy
and the shape check shared with §8.

**Chain names are fixed** (**DD-59**): `MASTER-INPUT` for the host policy,
`MASTER-FORWARD` and `MASTER-NAT` for WireGuard (**DD-120**).
`MASTER-DOCKER-FILTER` and `MASTER-DOCKER` are not used. The same logical
names serve IPv4 and IPv6 — separate tables mean no collision — and all are
declared in `config/defaults.env` and nowhere else.

- The installer creates **only its own chains** and inserts **one
  idempotent jump** to each (`INPUT` → `MASTER-INPUT` behind `ts-input`,
  `FORWARD` → `MASTER-FORWARD`, `nat POSTROUTING` → `MASTER-NAT`).
- tailscaled's own chains (`ts-input`, `ts-forward`) are **never** flushed or
  deleted; the firewall only orders `MASTER-INPUT` behind the `ts-input`
  jump (re-adding that jump when it is missing), which is why the
  nft-backend gate stays (§1.1).
- **Third-party rules already present in `INPUT`, `FORWARD` and
  `POSTROUTING` are never deleted**: the installer adds its jumps and leaves
  everything else in place. The retired installer's `activate_staging_chain`
  deleted every other `DOCKER-USER` rule; that behaviour is gone.
- WireGuard (**DD-120**), all interface-based and in both families:
  - `MASTER-INPUT` accepts from `wg0` only TCP to `10.8.0.1` on the
    qBittorrent UI port (open whether or not the module is installed;
    `caddy-wg` answers `502` without it) and ping (IPv4), and drops
    everything else from `wg0`.
  - `MASTER-FORWARD`, jumped at the top of `FORWARD`, accepts `wg0` → WAN
    and its replies and drops all other traffic to or from `wg0` (tailnet,
    other networks, other peers).
  - `MASTER-NAT`, in `nat POSTROUTING`, masquerades the WireGuard subnets out
    of the WAN.
  - wg-quick carries no `PostUp`: every rule belongs to `master-firewall`.
- IPv6 policy is explicit and fail-closed with the same shape. If the host
  has no IPv6 WAN route, the rule set reduces accordingly rather than
  silently permitting.
- The helper refuses to run if `ip6tables` is unavailable while IPv6
  forwarding is enabled, rather than degrading to an IPv4-only policy.
- The policy lives only in memory; `master-firewall.service` re-applies it
  after boot and after a `tailscaled` restart (`PartOf=tailscaled.service`
  only, **DD-152**).
- `master-firewall --check` verifies **shape and cardinality, not just
  presence**: each parent holds exactly one jump to its chain; in
  `MASTER-INPUT` (both families) there must be exactly one
  WAN DROP, it must follow every WAN allow, no unconditional
  `ACCEPT`/`RETURN` may precede it (**DD-94**), and the number of WAN allows
  must equal the allow list exactly — for IPv4 Tailscale's UDP port, host
  SSH and one UDP port per WireGuard network (none without the module), for
  IPv6 the first two. `MASTER-FORWARD` must hold exactly four rules per
  network plus its `RETURN`. Any extra WAN pass, whether a blanket
  `-i eth0 -j ACCEPT` or one more port, fails the check (**DD-95**).

---

## 10. systemd lifecycle

| Unit | After | Coupling | Restart |
|---|---|---|---|
| `tailscale-udp-gro.service` | `network-online.target` | none | `no`, oneshot, `RemainAfterExit` |
| `master-firewall.service` | `network-online.target tailscaled.service` | `PartOf=tailscaled.service` only (no Docker, **DD-152**) | `on-failure` (oneshot, `RemainAfterExit`, `RestartSec=10s`, `StartLimitBurst=12` / 300s) |
| `refresh-tailnet-config.timer` | — | address poll + firewall watchdog | starts oneshot every 5 min (`OnBootSec=2min`) |
| `caddy.service` (drop-in) | `tailscaled.service` | After only (no `PartOf`); `OnFailure=refresh-tailnet-config.service` (**DD-87**) | `on-failure` + StartLimit (drop-in) |
| `dnsmasq.service` (drop-in) | `tailscaled.service` | none | package default |
| `master-paylasim.service` (Paylaşım module) | `network-online.target` | none; loopback listener, enabled while registered `calisiyor` | `on-failure`, `RestartSec=3s` |

The Caddy drop-in also carries
`EnvironmentFile=/etc/master-stack/state.env`, which is how
`{$TAILSCALE_IPV4}` in the Caddyfile is resolved at daemon start. There is
no separately rendered environment file (**DD-61**), so `state.env` must be
written in a form both bash and systemd can parse: plain `KEY=value`,
unquoted, no spaces around `=`. `ExecStartPre=wait-tailnet-addr` requires
that address on `tailscale0` (**DD-85**).

Invariants:

- **Restarting `tailscaled` re-applies the firewall
  (`master-firewall` is `PartOf=tailscaled.service`) and leaves every module
  running.** Caddy is restarted when `refresh-tailnet-config` sees an
  address change, when Caddy fails and `OnFailure=` starts that oneshot
  (**DD-87**), or when the operator restarts it. The share WebDAV is a host
  service with no tie to `tailscaled`.
- **There is no Docker trigger** (**DD-152**): no `docker.service`, no
  `docker.service.d` drop-in and no `PartOf=docker.service`.
- **The firewall unit orders itself only after `network-online.target` and
  `tailscaled.service`.** Host `INPUT` must land as early as possible
  (**DD-94**).
- **One bounded watchdog, at the network edge only.**
  `refresh-tailnet-config` — which already runs every 5 minutes — restarts
  `master-firewall` when the unit is `failed` or `--check` fails, after a
  `reset-failed` so an exhausted start limit cannot block the recovery. It
  skips the round while the oneshot is mid-apply. It inspects the firewall
  unit and nothing else: no module, file, or binary is reconciled
  (**DD-94**).
- **No general-purpose repair engine.** The only `OnFailure=` in the stack
  is Caddy → `refresh-tailnet-config` (same oneshot the timer /
  `WantedBy=tailscaled` already use). There is no reconcile loop that
  reverts files or restarts arbitrary units.
- Module services come back after a reboot as enabled units; a module
  registered `durduruldu` stays disabled.

---

## 11. Idempotency expectations

**R20**: a second run against an already-provisioned host must be safe.

- Every managed file is rendered from a template and written through a
  temporary file plus atomic rename, with explicit owner and mode.
- Re-running must not change a single byte of any generated file when the
  inputs are unchanged. This is verifiable: `sha256sum` the generated set
  before and after a second run.
- Existing state that must survive a re-run: the folder share registry
  (IDs, hashes, policies and paused state), qBittorrent's profile (its settings are
  written once, by the module, **DD-151**),
  every `wgN.conf` and `clients-wgN/` with the networks registry (the installer
  reads them, writes none — **DD-143**), the operator's chosen local domain.
- Firewall application is idempotent by construction: each chain is rebuilt
  from scratch and swapped in, and each parent jump is inserted only when
  absent.
- Directory creation is conditional; ownership/mode repair under downloads
  is selective (mismatched UID/GID/mode only — **DD-84**), not a full-tree
  rewrite and not limited to newly created directories.
- No step is unconditionally expensive: package installation and daemon
  restarts happen only when something actually
  changed.
- There is no image-refresh question any more: the pull prompt (**DD-99**,
  with **DD-101**'s disk floor) went with **DD-151**, and no image exists
  since **DD-152**. Folder WebDAV code is part of the installer (§7).
  The one operator-driven exception left is the optional full-upgrade
  question on a re-run (default **hayır**).

---

## 12. Fail-closed behaviour on error

The rule: **a failure must never leave the host more exposed than before
the run started.**

| Failure point | Behaviour |
|---|---|
| Any stage aborts | The installer exits non-zero with the failing stage and line, and the log path |
| Firewall application fails partway | The staging chain is discarded; the previously active policy stays in force. A host that cannot get a complete policy does not get a partial one |
| `ip6tables` missing while IPv6 forwarding is on | Hard failure. No IPv4-only degradation |
| dnsmasq installed but not yet configured | The unit is **masked** during the window between package installation and configuration, so it cannot start as an open resolver on `0.0.0.0:53` |
| Caddy installed but not yet configured | Same masking window |
| Stage 6 aborts midway | dnsmasq and/or Caddy remain masked — i.e. **off**. There is no rollback machinery; recovery is a re-run |
| Tailscale never comes online | Hard failure before anything is published. The stack is not started against a missing address |
| Paylaşım account setup fails | `master-modul` stops before the service is started; systemd also refuses a unit whose credential file is missing |
| Folder account service renewal fails | Previous registry is restored and restart retried; if recovery also fails, report it explicitly. No plaintext password is returned (**DD-158**) |
| A module's Caddy site or dnsmasq name does not validate | The previous file is put back and a `kur` is taken back (§1.11) |
| A generated file cannot be written with the intended owner/mode | Hard failure, temporary file removed |

Nothing is repaired silently. Nothing is retried indefinitely: every wait
has a wall-clock deadline and reports which deadline it hit.

---

## 13. Manual Tailscale admin steps (R17)

The installer prints these and cannot perform them; they live in the
Tailscale control plane, not on the host.

1. **DNS → Nameservers → Add nameserver → Custom**
   - Nameserver IP: the Tailscale IPv4 printed at the end of the run.
2. **Restrict to domain** — enable it, and enter `${LOCAL_DOMAIN}`.
   Without this the tailnet sends *all* DNS to this host, which will answer
   `REFUSED` for everything outside `${LOCAL_DOMAIN}` unless upstream
   forwarding was explicitly enabled in Ayarlar.
3. **Machines → this host → Review exit-node route → Approve.** An
   advertised exit node is not usable until it is approved.
4. **Machines → this host → key expiry** — decide whether to disable it for
   an always-on server.

Note printed alongside: dnsmasq and Caddy follow the current `tailscale0`
address automatically, so if the device is deleted and re-registered, the
only thing that needs updating is the nameserver IP in step 1.

---

## 14. Success criteria

An installer run is successful when every one of these holds on the target host.

### Base and Tailscale

1. `tailscale status --json` reports `BackendState=Running` and
   `Self.Online=true`.
2. `tailscale debug prefs` shows exit-node advertisement for `0.0.0.0/0`
   and `::/0`, `RunSSH=true`, stateful filtering on, netfilter mode 2.
3. `net.ipv4.ip_forward` and `net.ipv6.conf.all.forwarding` are `1`.
4. `state.env` contains a valid `TAILSCALE_IPV4` **and** `TAILSCALE_IPV6`.

### Ports

5. No module gets a WAN port (**DD-151**, **DD-152**).
   `wg show wg0 listen-port` is
   `${WG_PUBLIC_PORT}`, `10.8.0.1` is on `wg0`, `master-wg version` runs, and
   with the qBittorrent module installed `caddy-wg` answers non-5xx on its
   port (**DD-120**, **DD-124**, **DD-151**).
6. No module web interface listens on a non-loopback address.
7. The loopback services of §3.3 (the Konsol backends and, with their
   modules, qBittorrent's UI and the share WebDAV) listen on `127.0.0.1`
   only.
8. Caddy listens on `${TS_IPV4}:80` and, with Paylaşım installed,
   `${TS_IPV4}:${SHARE_PORT}` (Infuse), and on no other address.
9. dnsmasq answers on `${TS_IPV4}:53` **and** `127.0.0.1:53`, and on no
   other address; it serves no DHCP.

### DNS and Caddy

10. Enabled base/installed-module names resolve to `${TS_IPV4}` when queried
    against `${TS_IPV4}`; retired `health.` is not a built-in name.
11. A query for an out-of-domain name against `${TS_IPV4}` returns
    `REFUSED` by default (or resolves via configured upstreams when enabled).
12. `curl -H "Host: panel.${LOCAL_DOMAIN}" http://${TS_IPV4}/` returns
    the Konsol page, HTTP 200; both installed API backends pass their checks.
13. Backend API gates reject missing `X-Konsol` and unrelated Host headers.
    With the qBittorrent module installed, `master-modul kur torrent` checks
    that `/api/v2/app/version` answers `403` without a login on loopback and
    through `torrent.${LOCAL_DOMAIN}`; a `200` means a localhost or subnet
    authentication bypass is on (**DD-127**, **DD-151**).
14. WebDAV listens only on loopback as DOWNLOADS_UID; Caddy owns the tailnet port.
15. Anonymous requests return 401; each account opens only its selected folder.
16. PROPFIND/read/range succeed; RO write methods are rejected.
17. RW changes stay inside the share; cross-share Destination and unsafe paths fail.
18. Pause, expiry, rotation and removal revoke access as specified in §6.
19. URLs include /s/<id>/; native-client acceptance is a separate test.

### WebDAV credential handling (§6)

20. SHARE_STATE_FILE remains 0600 root, with hashes only.
21. No secret enters environment files, argv, browser storage or audit logs.
22. The service command line contains only the credential path.
23. Reruns and reboot preserve IDs, hashes, policies and paused state.
    No retired shared account/rclone route is retained as a bypass.

### Firewall

24. `MASTER-INPUT` accepts loopback, `ESTABLISHED,RELATED`, all
    `tailscale0` inbound, WAN TCP `${SSH_PUBLIC_PORT}` (host SSH) and WAN
    UDP `${WG_PUBLIC_PORT}`; it drops other new WAN inbound.
25. `INPUT` holds exactly one jump to `MASTER-INPUT`, behind `ts-input`;
    `FORWARD` exactly one to `MASTER-FORWARD` and `nat POSTROUTING` exactly
    one to `MASTER-NAT`, in both families (replaces the `DOCKER-USER` jump,
    **DD-152**).
26. A third-party rule planted in `INPUT` or `FORWARD` before the run is
    still present after it.
27. tailscaled's own chains (`ts-input`, `ts-forward`) are not flushed or
    deleted (replaces the Docker-chain check, **DD-152**).
28. `MASTER-FORWARD` permits no NEW WAN traffic into a WireGuard network
    (replaces the `MASTER-DOCKER` check, **DD-152**).
29. The active SSH session survives policy application.

### Lifecycle

30. `systemctl restart tailscaled` leaves every installed module running.
31. `systemctl restart tailscaled` also results in a re-applied firewall
    policy, `MASTER-INPUT` behind `ts-input` (replaces the Docker restart
    check, **DD-152**).
32. After a full reboot: every module marked `calisiyor` running, every name resolving,
    public wg UDP published, WebDAV (with Paylaşım installed) answering
    `401` via Caddy.
33. `systemctl --failed` is empty.

### Idempotency

34. A second complete run changes no byte of any generated file, restarts
    no module service it did not need to, and preserves the Paylaşım
    account.
