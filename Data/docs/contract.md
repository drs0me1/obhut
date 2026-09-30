# Behaviour Contract

**Status:** current behaviour contract, evolved from the 2026-08-05 requirements.
Implemented by `Data/install.sh` and helpers. Where live code and this
document diverge, prefer the code and update this file.

This document is the authoritative statement of what the installer does
and — just as importantly — what it deliberately refuses to do. Companion
contracts: [folder-shares.md](folder-shares.md) (folder WebDAV),
[desktop-and-archives.md](desktop-and-archives.md) (Files and archives) and
[model-a-clean-install.md](model-a-clean-install.md) (Konsol layout and
clean-install acceptance).

**Relationship to `.cursor/rules/`:** those rules cover the repository and
govern *how* the work is done — process, Bash conventions, the
per-phase verification set, and the hard prohibitions (do not delete other
software's chains such as Tailscale's `ts-*`, do not silently turn the
UDP-only decision into TCP+UDP, do not grow
a general-purpose reconcile engine). This document governs *what the result
must do*. Where the rules do not specify a feature in detail, this contract
extends them. Settled disagreements with early rule drafts — dnsmasq
listening scope, chain name and refresh helper scope — are recorded as
**DD-59** through **DD-61** in `design-decisions.md`.

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
| R8 | Create the user root `/srv`, downloads `/srv/downloads` and media `/srv/media` (**DD-144**) |
| R9 | Withdrawn (**DD-152**) |
| R10 | Optional qBittorrent is a host service; Files, per-folder Python WebDAV and bounded archive tools are built in (**DD-151**, **DD-158**, **DD-159**) |
| R11 | Publish every web interface on loopback only (`127.0.0.1`; WebDAV's WAN scope on `SHARE_WAN_BACKEND`, **DD-179**) |
| R12 | Publish publicly the WireGuard UDP port of each network, only while WireGuard is installed (host kernel, **DD-120**). The torrent peer port is not opened (**DD-151**): qBittorrent makes outgoing connections only |
| R13 | Read the local domain from the installer input file (**DD-119**) |
| R14 | Resolve the defined service names to the Tailscale IPv4 with dnsmasq |
| R15 | Have Caddy listen on the Tailscale IPv4 only, over HTTP (plus the opt-in WAN WebDAV site, §3.1, **DD-179**) |
| R16 | Reverse-proxy the service names to the loopback interfaces through Caddy |
| R17 | Tell the operator to configure Custom DNS and Restrict-to-domain manually in the Tailscale admin panel |
| R18 | Reapply firewall on boot: default Tailscale access, Tailscale UDP, registered WireGuard UDP, WAN SSH and the opt-in WAN WebDAV port (**DD-179**); confirmed panel overrides take precedence. No incoming torrent peer port (**DD-151**, **DD-156**) |
| R19 | Withdrawn (**DD-152**) |
| R20 | Keep the installation re-runnable |

---

## 1. Included features

### 1.1 Base system

- Supported-OS hard gate (**R1**, **DD-102**): Debian 13 (trixie),
  Ubuntu 24.04 LTS (noble) or Ubuntu 26.04 LTS (resolute); the installer
  refuses any other OS or release. The Tailscale apt repo suite is derived
  from `os-release` (`OS_ID`/`OS_CODENAME`), never hardcoded, and its
  `dists/<codename>/Release` is probed before the source file is written
  (**DD-106**). On a host with
  ufw active the installer stops before any mutation. The
  `iptables`/`ip6tables` backend must be the nft one tailscaled uses, because
  `MASTER-INPUT` is ordered behind its `ts-input` (**DD-152**); stage 0
  asserts this for whichever binaries the host already has and stage 1
  asserts it unconditionally once the package is installed, because a
  minimal Debian image ships none (**DD-106**, **DD-108**).
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
  no `gawk` (the distribution's `mawk` is `awk`). Folder WebDAV uses the base
  Python runtime (**DD-158**). Distribution-signed `unrar` and `python3-rarfile`
  are base dependencies of the archive opener: if the existing apt sources lack
  them, one managed source enables Debian non-free or Ubuntu
  universe/multiverse with the installed distribution keyring; no operator
  source is overwritten (**DD-166**).
- `unattended-upgrades` is installed and enabled for the distribution's own
  origins (Debian stable + security; Ubuntu security), with automatic reboot
  off (**DD-113**). The Tailscale and Caddy repositories are added to its
  origins (`origin=Tailscale,label=Tailscale`, `origin=cloudsmith/caddy/stable`),
  and the daily run starts at `APT_UPGRADE_TIME` (04:00) plus a random delay of
  up to 30 min; an update restarts that service briefly (**DD-184**).
  WebDAV code updates with the installer (§7).
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
    full-upgrade; an interactive TTY stays required.
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
  (**R7**).

### 1.3 Modules are host services (DD-151, DD-152)

- Every module and built-in service is a systemd unit on the host (§1.11);
  there is no container runtime (**DD-152**).
- The installer's own apt downloads are not kept in `/var/cache/apt/archives`
  (`APT::Keep-Downloaded-Packages=false`) (**DD-125**).
- **qBittorrent is a host module (DD-151)**, installed from Konsol (§1.11): the
  distribution's `qbittorrent-nox` runs on the server as the downloads account.
  `modules/torrent/qBittorrent.conf` seeds minimal settings only when absent.
  The installer holds no account or incoming peer-port setting. Later
  account/download-folder edits use the settings worker and qBittorrent profile.
- Every web interface and WebDAV listens on loopback only (`127.0.0.1`;
  WebDAV's WAN scope on `SHARE_WAN_BACKEND`, **DD-179**) (**R11**).
- Module services survive a reboot as enabled systemd units; a module stopped
  from Konsol is disabled and stays stopped (§1.11). systemd's `Restart=`
  handles a crash.

### 1.4 Directories

- `/srv/downloads`, `/srv/media`, `/srv/media/movies` and
  `/srv/media/series` are created when absent (**R8**, **DD-144**).
- **The downloads tree is repaired selectively on every run** (**DD-84**):
  entries whose UID/GID differ from `DOWNLOADS_UID`/`DOWNLOADS_GID`
  (defaults `1000:1000`) are `chown -h`'d; directories not mode `0775` and
  files not mode `0664` are `chmod`'d. Matching entries are left untouched
  (no full-tree rewrite). qBittorrent and Konsol's file backend share
  read/write that way. WebDAV enforces each account's RO/RW permission (DD-158).
- The private `.arsiv` work/history tree and the reserved `.pay` name
  (`SHARE_DIR`) are excluded from ordinary ownership/mode repair. `.pay` is
  never created or read; the file backend hides and refuses it (the name is
  reserved), WebDAV and qBittorrent cannot access it, and its contents are
  never deleted (**DD-171**).
  `.cop` and `.pay` are internal areas, not shareable folders.

### 1.5 DNS and Caddy

- dnsmasq bound to loopback and `tailscale0`, tracking the interface address with
  `interface-name` + `bind-dynamic`, resolving the installed service names to the
  current Tailscale IPv4 (**R14**).
- Caddy listening on the Tailscale IPv4, port 80 (and `SHARE_PORT` for folder
  WebDAV), HTTP only, reverse-proxying to loopback upstreams (**R15**, **R16**).
- The real Konsol page and backend/gate checks verify the HTTP edge; there is
  no separate health endpoint or DNS name (**DD-157**).
- While a WAN share is active, Caddy also binds `WAN_IPV4:SHARE_PORT`, over
  HTTP, for `/s/<id>/` only (**DD-179**, §3.1).

### 1.6 Firewall

- A host `INPUT` policy and, for WireGuard, a forwarding and NAT policy, all
  fail-closed (**R18**). Full contract in §8 and §9.
- The **staging-chain swap** is preserved wherever it applies: rules are
  built in a throwaway chain and swapped in atomically, so there is no
  window in which the host runs with a partial policy.
- Nothing is persisted to disk. `master-firewall.service` re-applies the
  policy on boot and whenever `tailscaled` restarts
  (`PartOf=tailscaled.service` only, **DD-152**), which keeps `MASTER-INPUT`
  behind tailscaled's `ts-input`.

### 1.7 WebDAV

The share WebDAV is a built-in host service (**DD-158**, **DD-159**).
Contract in §5–§7 and `folder-shares.md`.

### 1.8 Operator guidance

- The manual Tailscale admin steps are printed at the end (**R17**, §13).
- No service accounts come from installer input; folder accounts are set in
  Files and qBittorrent manages its own account (**DD-147/151/158**).

### 1.9 WireGuard (DD-120, DD-124)

- **A fresh install has no WireGuard (DD-143, DD-150).** WireGuard is a Konsol
  module (§1.11). The installer only puts `master-wg` and an empty `/etc/wireguard` (`0700`, the root backend's only
  writable path) in place. Installing the module installs `wireguard-tools`
  and `qrencode` (`--no-install-recommends`), loads the kernel module (and
  writes `WG_MODULES_LOAD_FILE`), creates `/etc/wireguard`, re-applies the
  firewall and starts whatever networks the registry already holds. Nothing
  generates a key, writes a `.conf` or brings up an interface of its own.
- Without the module `master-firewall` ignores the network registry (no
  WireGuard port or rule), `master-wg` refuses every command but `version`,
  and the root backend answers `/api/wg/state` with `installed: false` and
  refuses changes with `409`. Removing the module closes every network
  (`wg-quick@` disabled) and keeps `/etc/wireguard`, so a
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
- **Internet-only (DD-177).** No access selector, no WG host-rule override and
  no per-network Caddy listener. API creation/settings reject a supplied
  `scope` field; CLI creation is `net-add PORT DNS LABEL`, and settings is
  `--if wgN net-settings DNS REVISION`. Network settings change only the
  default DNS for future peers, under revision and install-lock checks; they
  never regenerate keys, change existing profiles or start a stopped network
  (**DD-167**).
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
- **What clients reach:** IPv4/IPv6 internet egress via WAN masquerading.
  All WG-originated host traffic (including existing connections and ping) is
  dropped before established/ICMPv6/Tailscale accepts. Other peers, VPN networks
  and private/CGNAT/link-local destinations routed via WAN are blocked (§9).
  There is no WG web proxy or listener; administration uses Tailscale.
- **WireGuard web panel (DD-133).** Konsol's WireGuard page at
  `http://panel.${LOCAL_DOMAIN}` (**DD-140**) uses the API of
  `master-wg-panel.service` to list, add and remove peers, show a peer's QR
  code, download its profile or picture, change its DNS and regenerate a
  network.
  - The backend runs Python 3's standard library only and has no TCP port: it listens
    on the Unix socket `WG_PANEL_SOCKET` (`/run/master-wg-panel/api.sock`,
    `0660 root:caddy`), and also checks the connecting process's identity
    (`SO_PEERCRED`: root or Caddy's group, **DD-180**). Caddy exposes it on the
    tailnet; nothing exposes it on a WireGuard network, the WAN or loopback TCP.
    A request Caddy relays must come from another tailnet device: a Tailscale
    address that is not the server's own (Caddy writes the real client address).
    So a compromised downloads-account process (qBittorrent, unrar) reaches it
    neither directly nor through Caddy's tailnet listener; stage 7 proves both.
  - Every change goes through `master-wg` (`info`, `add`, `remove`, `dns`,
    `reset --onay`, `profile`, `png`): same validation, lock and live apply as
    `wireguard.command`.
  - **No password** (**DD-147**): Konsol opens for any device on the tailnet;
    narrowing that is a Tailscale ACL matter. There is no account, no login
    prompt and no lockout.
  - Because nothing else guards it, two gates are mandatory and stage 7 proves
    both on both backends: a request with another `Host` than
    `panel.${LOCAL_DOMAIN}` is refused (DNS rebinding; the root backend accepts
    no loopback name since **DD-180**),
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
- **WireGuard networks from the panel (DD-136/143).** "Arayüz ekle" creates
  `wg0`…`wg9` at run time with `master-wg net-add PORT DNS LABEL`; each
  network has its own tab, server key, UDP port and addresses.
  - Addressing: `wgN` is `10.8.N.0/24` (server `10.8.N.1`) and
    `fdcc:ad94:bacf:61a4::N:0/112` (server `…::N:1`); peers get `10.8.N.H`
    and `…::N:H` (H in hex). Profiles live in `/etc/wireguard/clients-wgN`;
    the interface in `/etc/wireguard/wgN.conf`.
  - The same internet-only policy applies to every network and peer.
  - The registry `/etc/wireguard/networks` (one tab-separated line per
    network: interface, port, reserved fixed `inet` field, server and subnet IPv4 and IPv6, default
    DNS, label) is written by `master-wg` and read by `master-firewall`
    and the panel. A malformed or clashing registry stops the firewall
    before any chain changes; stage 7 stops on a fixed field other than `inet`.
  - A new network's port may not be a stack port, another network's port or a
    UDP port already listened on; the next free number is taken (from `wg0`, at
    most `WG_NETWORKS_MAX + 1` slots, currently 10).
  - Order when adding: files and registry, `master-firewall` restart, then
    `wg-quick@wgN`. A failing step removes
    every trace of the network and restores the firewall.
  - `master-wg --if wgN` runs any peer command on that network;
    `net-remove wgN --onay` stops its units, deletes its files, key, peers and
    registry line and re-applies the firewall. Every network can be removed,
    `wg0` included (**DD-143**); removing the last one leaves the layer ready
    and Konsol back at "Yapılandır".
  - The panel confirms regenerating or removing a network with `onayla`.
  - **Switches (DD-140).** `master-wg [--if wgN] net ac|kapat` stops or starts
    `wg-quick@wgN`; the registry, keys and profiles stay
    and the UDP port stays open with nothing listening. `master-wg peer AD
    ac|kapat` comments the peer's block out of the interface configuration, so
    it leaves the running interface at once and stays off across a reboot with
    its key, address and profile intact. `master-wg keepalive AD SANİYE`
    rewrites only the profile's `PersistentKeepalive`.
  - Registered networks and their units survive reboots and installer re-runs.
    There is no special installer-owned wg0. The SSH menu operates on the
    selected network; downloaded profiles are for devices.

### 1.10 Konsol and the file backend (DD-139, DD-140, DD-150)

- The file backend and bounded ZIP/RAR worker are built in (**DD-159/166**). The
  installer prepares their downloads account, `SERVER_ROOT`, private archive
  workspace and staged unit; `master-modul yerlesik` installs/enables/checks the
  unit. Files is always present in Konsol, independent of the app catalogue.

- **One console (DD-140).** `http://panel.${LOCAL_DOMAIN}` is the only
  administration page. Caddy serves the page files itself from
  `CONSOLE_WEB_DIR` (CSP, `no-cache` so a browser revalidates instead of
  re-downloading, `nosniff`, `X-Frame-Options: DENY`, no referrer; pages and API
  replies are compressed with zstd/gzip, **DD-181**), sends `/api/wg/*` and `/api/konsol/*` to `master-wg-panel` and
  every other `/api/*` to `master-files-panel`. Both backends
  accept only that host and require the header `X-Konsol` on `/api/*`
  (**DD-147**).
  - Pages (**DD-160**): Dosyalar (the landing page), App Store (§1.11), the
    WireGuard and qBittorrent pages only while installed, and Ayarlar, in one
    responsive sidebar. CPU, memory and disk sit below the sidebar menu, read
    from the gated `/api/konsol/kaynaklar` endpoint; missing or stale
    measurements show as unknown, never as zero. An unknown route opens
    Dosyalar; a page of an absent application opens App Store.
  - Ayarlar (**DD-156**, superseding DD-155) has five tabs: Sistem, Güvenlik
    Duvarı, Caddy, Dnsmasq and Günlük. `GET
    /api/konsol/ayarlar` retains the same gates and 5 s cache (`?yenile=1`
    bypasses it); `/durum` reads transaction state and `/klasorler` lists
    allowed existing download folders. No password/hash is returned.
    - Sistem shows server facts and the read-only health card (`GET
      /api/konsol/saglik`, cached 30 s, **DD-182**): failed units, Tailscale
      state and key expiry, `master-firewall --check`, a pending reboot, NTP
      sync, free space and inodes against the upload reserve, a pending or
      stuck settings change and a WAN share whose address is gone. It never
      repairs anything.
    - Güvenlik Duvarı shows real IPv4/IPv6 rules and counters from all
      iptables tables, listening sockets, and the baseline policy check.
      Structured port overrides have family, WAN/tailnet scope,
      TCP/UDP port, optional source CIDR and allow/deny action. Only these
      overrides are editable; core and third-party rules are read-only.
      `CHAIN_SETTINGS` precedes `ts-input`, so a tailnet deny is effective.
      Loopback, established flows and ICMPv6 protections remain intact outside WG;
      the mandatory WG deny precedes them.
      Permission does not imply a reachable listener; no bind address is changed.
      **DD-164:** group port permissions by incoming network: Tailscale (default),
      Internet, WireGuard only when installed (selectable tunnel interfaces), and
      protected loopback. WireGuard public UDP endpoints belong to Internet,
      not to tunnel-client traffic. Technical rules is a separate, all-network
      read-only view including forwarding/NAT. Socket bindings carry explicit
      scope metadata; unknown/unreadable and no listener remain distinct from
      policy. Refresh re-reads the live state; switching tabs preserves drafts.
    - Caddy shows base/module sites and their routes. Its local-domain
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
      DNS-only Apply validates, restarts dnsmasq and commits immediately, with
      no 60 s confirmation (**DD-163**). The console's own name cannot be
      disabled; reject that request before writing files or restarting services.
    - Günlük lists both backends' audit lines from the last 7 days
      (`/api/wg/islemler`), including archive job results (**DD-183**).
  - The qBittorrent page (only while installed, **DD-160**) holds its service
    controls, Web UI link and account/folder form, which uses the same
    settings transaction as Ayarlar. The form permits username, optional new
    password (8–256 characters) and the default folder for new torrents.
    Blank in the UI preserves the password. Only canonical existing non-hidden
    downloads/media directories may be chosen; write permission is probed as
    the service UID and narrowly added to its systemd sandbox. Existing
    files/torrent locations and incomplete paths are not moved.
    Stop/snapshot/write/restart avoids overwriting a live application's
    settings. **DD-165:** account-only Save commits immediately in one
    request, with explicit success/failure feedback and no
    draft/review/countdown. Other pending drafts are neither submitted nor
    discarded. Blank preserves a stored password; a temporary startup password
    can rotate on restart. Stopped services remain stopped. Folder changes
    retain review/confirmation.
  - Settings transactions: `POST /api/konsol/ayarlar/{uygula,onayla,geri-al,birak}`
    runs an independent
    worker with JSON on stdin, never a password on argv/in logs. DNS-only and
    qBittorrent account-only (username/password, no folder or other section)
    requests return `{pending: null, committed: true}` after a durable commit;
    only the server determines eligibility from the supplied change sections.
    Other requests retain review and a 60 s confirmation window (300 s for a
    domain change), including mixed DNS/firewall or DNS/qBittorrent requests.
    Failed immediate applies restore snapshots; interrupted pre-commit writes retain
    guard recovery. The commit marker prevents recovery from undoing a durable
    commit after a crash. The server-side guard timer
    restores unconfirmed settings after disconnect, timeout or reboot. It runs
    only while a change is pending (**DD-181**): apply starts it before the
    pending file exists, an idle run stops it while holding the locks, and at
    boot it runs once; the unit stays enabled;
    failed recovery remains pending and is retried after 15, 30, 60 and 120 s.
    After the fifth failure it is "stuck" (**DD-182**): no more automatic
    attempts; Konsol shows the last error with "Yeniden dene" and "Bırak"
    (typed `onayla`; files stay as they are, re-run the installer to apply the
    saved settings). The installer refuses to run while anything is pending. Stale revisions and concurrent
    installer/module writes are refused. Confirmation cannot preserve a rule
    that blocks the confirming client's new console/DNS connections or the
    console's own DNS name. `SETTINGS_FILE` owns confirmed firewall/DNS/domain
    choices across re-runs; `SETTINGS_PENDING_FILE` is root-only recovery data,
    not a portable backup. qBittorrent remains the owner of its profile.
  - A peer or a whole network can be switched off and on (§1.9).
- **Folder shares (DD-158):** Files v09 offers list/cards, details and a WebDAV
  tab. The root backend manages separate accounts, RO/RW, expiry and pause.
  Access and expiry are edited inline in the Shares list (DD-170); Manage edits
  folder, account and networks (**DD-179**). Partial updates preserve omitted
  values under the lock and do not rebind a folder unless a path is explicitly
  supplied. See §5–7.
- **Archives (DD-166, DD-170):** selecting files opens a contextual action
  dock. Archive creation produces ZIP; the archive opener automatically
  detects multipart RAR and nested ZIP/RAR (unencrypted RAR3/RAR5, solid and
  multipart sets) through an unprivileged, resource-limited RAR helper, never a
  shell extraction command. The destination defaults to downloads with a
  folder picker. Depth/size/time limits are enforced internally, without a
  nesting prompt; source archives are kept. Jobs, limits, private history and
  atomic publication are specified in
  [desktop-and-archives.md](desktop-and-archives.md).
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
  - **Disk reserve (DD-180):** an upload is refused before its body (507) and
    stopped while streaming when free space would fall under min(5 GiB, 10% of
    the filesystem); the temporary file is removed. WebDAV PUT and file COPY
    keep the same reserve.
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
    - Because unrar opens untrusted RAR files here (**DD-180**): network only to
      and from loopback (`IPAddressDeny=any`, `IPAddressAllow=localhost`),
      `SystemCallFilter=@system-service`, `ProtectProc=invisible`,
      `PrivateIPC` and `MemoryDenyWriteExecute`. Loopback services (DNS, the
      qBittorrent WebUI with its password) stay reachable from it.
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
  - Move-to-trash has a short confirmation; long names remain available in its
    subtitle/tooltip without overflowing. Permanent deletion guards are unchanged.
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
- The page protects the conventional temporary folder
  (`DOWNLOADS_SUBDIR/TORRENT_TEMP_DIR`) for existing/user-configured downloads.
  Since DD-178 new profiles do not automatically enable separate temporary
  storage. Keeping this existing path guard does not enable it in qBittorrent.

### 1.11 App Store and built-ins (DD-148, DD-149, DD-159)

- A clean install includes Files, folder WebDAV and archive tools. Optional applications
  are installed/removed from Konsol → App Store: `wireguard` and `torrent` only.
  qBittorrent also supports start/stop; WireGuard has its own network switches.
  Public module verbs reject `dosya`/`paylasim`;
  they are protected internal IDs, not installable/removable applications.
- The installer, on every run:
  - installs `/usr/local/sbin/master-modul` and renders each module's files to
    `MODULES_DIR/<id>/` (`/usr/local/share/master-stack/moduller`): for the
    built-in WebDAV (`paylasim`) `master-paylasim.service` (the credential-loaded unit), `paylasim.caddy` and `dnsmasq.conf`; for
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
    [LINES]`, `uygula ID`; `hesap torrent [--parola]` reads the temporary login;
    the installer's `yerlesik` activates the built-ins (below).
    Any other id, verb or argument is refused before anything runs.
  - Changes take `RUNTIME_DIR/modul.lock`; a second operation waits up to 5 s
    and then fails.
  - Progress is one line in `RUNTIME_DIR/modul-<id>.ilerleme`:
    `action step total text`, ending with step `bitti` or `hata` and the
    reason. Each step is also written to the journal (`master-modul`).
    `uygula` writes no progress line.
  - A host application (`torrent`) is a systemd unit. `kur` installs, starts, checks and registers
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
  - Its settings are written once, when the profile has none (**DD-178**): save
    path `DOWNLOADS_PATH`, WebUI on `127.0.0.1:TORRENT_UI_PORT` with local
    authentication, and startup legal notice acceptance for the headless service.
    No UPnP/automatic port-mapping, Local Peer Discovery, temporary folder/enable,
    performance, peer-limit or other user-preference override is seeded. Those
    follow the installed qBittorrent version's defaults until the user changes
    them. Reinstall/reapply preserves the entire existing profile; account and
    folder changes go through Konsol's qBittorrent page (§1.10).
  - `kur` checks that it runs as `DOWNLOADS_UID`, that the trash and share root
    are inaccessible to it, that its API answers `403` without a login on
    `127.0.0.1:TORRENT_UI_PORT` and through `torrent.${LOCAL_DOMAIN}`, and that
    the name resolves; a failed install is taken back.
  - Names: `torrent.${LOCAL_DOMAIN}` (Caddy site and dnsmasq name); no
    WireGuard publication.
  - No inbound peer port: the firewall opens nothing for it. qBittorrent
    still listens on its own random peer port on every interface; new WAN
    traffic to it is dropped in both families; tailnet access requires an explicit rule.
  - The account is not Konsol's: qBittorrent prints a temporary password to
    its journal on each start until one is set in its UI. `hesap torrent`
    reads this run's journal (`_SYSTEMD_INVOCATION_ID`) and prints
    `user<TAB>gecici|ayarli` (with `--parola` also the temporary password);
    `gunluk` masks that line.
  - `durdur` disables and stops the unit (the name stays); `kaldir` removes the
    names and the drop-in and stops the unit but leaves the package installed;
    `--veri` deletes the profile (settings and torrent list) — only under
    `/var/lib` — never a downloaded file.
- Built-in WebDAV (`paylasim`, **DD-158/159**): `yerlesik` prepares a registry
  only if absent, places/enables the unprivileged service, checks UID/anonymous
  401, then publishes/checks Caddy and DNS. Unchanged reruns do not rewrite
  accounts or restart healthy services. Remove individual accounts through
  Files; no module verb stops or removes the service.
- The root backend (`master-wg-panel`):
  - `GET /api/konsol/moduller` → `{items: [{id, runtime, installed, state,
    live, busy, progress}]}`. `busy` is a running `master-modul-<id>.service`,
    read with `systemctl list-units`.
  - `POST /api/konsol/moduller/<id>/(kur|baslat|durdur|kaldir)`, JSON
    body, `{"veri": true}` honoured for `kaldir` only. The id
    must be in `liste` (else `404`). It starts `systemd-run
    --unit=master-modul-<id>.service --collect master-modul <verb> <id>` and
    answers `202`; while that unit is active the answer is `409`. The audit
    line is `modul-<verb>`.
  - `GET /api/konsol/moduller/torrent/hesap` → `{user, temp, host}`; with
    `?parola=1` also the temporary password while one is in use (audited as
    `modul-hesap`). Any other or uninstalled module answers `404`.
  - Folder shares use `GET /api/konsol/paylasim` and `POST
    /api/konsol/paylasim/{kaydet,durum,kaldir}`.
  - `GET /api/konsol/moduller/<id>/gunluk` → the last 80 log lines as text.
  - The same Host and `X-Konsol` gates as `/api/wg/*` apply (**DD-147**).
- Konsol never retrieves a stored WebDAV password; enter or generate it in the
  folder form. Blank password on edit preserves its hash (DD-158).

---

## 2. Deliberately excluded features

The installer deliberately does not provide these:

- **No reconcile or self-healing engine.** `refresh-tailnet-config` reacts to
  a Tailscale address change and watches only the network edge (§10); there
  is no general health probe that restarts services and no reconcile
  `--check` surface. systemd's `Restart=` handles a crash. **A Tailscale
  restart must not restart a module.**
- **No canonical copies or automatic restore.** There is no generation
  directory, `SHA256SUMS` manifest or timer that reverts a managed file. An
  operator edit is the operator's decision; a drifted file is repaired by a
  re-run (**R20**).
- **No restart-cooldown stamp files.** systemd rate-limits restarts with
  `StartLimitIntervalSec`/`StartLimitBurst`.
- **No installer disk or inode threshold checks.** The installer does not
  monitor; Konsol's health card only reports (§1.10, **DD-182**).
- **No DNS/Caddy rollback state machine.** A failed stage 6 leaves dnsmasq
  and/or Caddy masked, which is safe; recovery is a re-run (§12).
- **No migration cleanup.** The upgrade path is a fresh install or a re-run
  that overwrites what the installer owns. The installer does not hunt for
  earlier revisions' units, users, packages or data; a global `apt-get
  purge` or a `userdel` is outside its boundary (**DD-96**).

---

## 3. Port publication contract

Three exposure classes, and nothing may straddle them.

### 3.1 Public (WAN IPv4)

No module gets a WAN port. qBittorrent has no inbound peer port
(**DD-151**): it makes outgoing connections only.

**WireGuard is a host listener (DD-120/143):** each registered network's UDP
port is admitted by the base WAN policy while the application is installed.
`WG_PORT_DEFAULT` (61001) is only a suggestion for a new network, not an
automatically created listener.

**Host SSH is a separate MASTER-INPUT exception:** inbound TCP
`${SSH_PUBLIC_PORT}` (default 22) on the WAN interface is accepted so
console recovery and public-IP SSH keep working.

**Folder WebDAV is an opt-in WAN exception (DD-179):** while at least one
unpaused, unexpired WAN share exists, Caddy binds `${WAN_IPV4}:${SHARE_PORT}`
over plain HTTP (the share form requires plaintext-risk consent) and proxies
only `/s/<id>/` to the WebDAV's WAN scope on `SHARE_WAN_BACKEND`; every other
path answers `404` and no administrative interface is exposed. New WAN
sockets to that port are capped per source IP and in total before any
operator allow rule. Pausing or removing the last WAN share removes the
listener and the firewall permission at once; expiry does so on the next run
of `master-share-network.timer`. Exact limits and recovery
are in [folder-shares.md](folder-shares.md). Every other service stays
tailnet-only.

The firewall limits NEW WAN traffic to each WireGuard network's UDP port
(IPv4 only), host SSH, Tailscale's own UDP port (`TAILSCALE_UDP_PORT`) and,
only while a WAN share is active, TCP `${SHARE_PORT}` (IPv4 only).

### 3.2 Tailnet (Tailscale IPv4) — reachable only over `tailscale0`

| Service | Listen address | Port | Protocol |
|---|---|---|---|
| Caddy | `${TAILSCALE_IPV4}` | 80 and `${SHARE_PORT}` (61010, folder WebDAV) | TCP, HTTP only |
| dnsmasq | `${TAILSCALE_IPV4}` (via `bind-dynamic`) | 53 | UDP + TCP |

dnsmasq also listens on `127.0.0.1:53` (**DD-60**), so the host itself can
resolve the service names and the installation can verify DNS without
bringing a tailnet device into the loop. Those two interfaces — `lo` and
`tailscale0` — are the only ones it binds. No WAN interface, no ordinary
LAN interface, no unbounded `0.0.0.0` listener, and no DHCP service.

### 3.3 Loopback only

| Service | Listen address | Port |
|---|---|---|
| qBittorrent WebUI (`torrent` module; only while installed) | `127.0.0.1` | 61006 (**DD-127**, **DD-151**) |
| Konsol WireGuard backend (`master-wg-panel`) | Unix socket `/run/master-wg-panel/api.sock` (`0660 root:caddy`) | none (**DD-133**, **DD-140**, **DD-180**) |
| Caddy admin API | Unix socket `/run/caddy/admin.sock` (folder `0700 caddy`) | none; `systemctl reload caddy` uses it (**DD-180**) |
| Konsol file/archive backend (`master-files-panel`; built in) | `127.0.0.1` | 61009 (**DD-159**) |
| Per-folder WebDAV (`paylasim` internal ID; built in) | `127.0.0.1` (Tailscale scope) and `SHARE_WAN_BACKEND` `127.0.0.2` (WAN scope) | 61010 (**DD-158**, **DD-159**, **DD-179**) |

Reached from the tailnet through Caddy (**R11**, **R16**, **DD-98**):
the share WebDAV on `paylas.*:80` and `${TAILSCALE_IPV4}:${SHARE_PORT}`. No
loopback service names the Tailscale address. None of them listens on
`0.0.0.0` or a WAN address; the only stack-owned WAN TCP listener is Caddy's
opt-in share site (§3.1).

### 3.4 Single source of truth

Every number above is declared exactly once, in `config/defaults.env`,
and reaches the module templates, the Caddyfile, the firewall script and the
state file by substitution. A port literal appearing twice is a bug.

### 3.5 WireGuard (`wgN`) — internet-only

No host service is exposed to WireGuard clients. Each registered network's UDP
transport endpoint remains admitted on WAN/Tailscale while the module is installed.
This transport permission does not grant tunnel clients access to the host.

---

## 4. DNS and Caddy service map

`${LOCAL_DOMAIN}` initially comes from the installer input file (**R13**, **DD-119**);
an empty value takes `DEFAULT_LOCAL_DOMAIN` from `defaults.env`. A domain
subsequently confirmed in Konsol (`SETTINGS_FILE.domain`) takes precedence
on re-runs (**DD-157**); the operator's Mac input file is never edited.

| Name | dnsmasq answer | Caddy site | Upstream |
|---|---|---|---|
| `torrent.${LOCAL_DOMAIN}` (qBittorrent module only) | `${TAILSCALE_IPV4}` | `http://torrent.…` | `127.0.0.1:61006` (**DD-117**, **DD-151**) |
| `paylas.${LOCAL_DOMAIN}` (built-in folder sharing) | `${TAILSCALE_IPV4}` | `http://paylas.…/s/<id>/` and `http://${TAILSCALE_IPV4}:61010/s/<id>/`; while a WAN share is active also `http://${WAN_IPV4}:61010/s/<id>/` (**DD-179**) | `127.0.0.1:61010`; the WAN site → `SHARE_WAN_BACKEND:61010` (**DD-158**, **DD-159**) |
| `panel.${LOCAL_DOMAIN}` (Konsol) | `${TAILSCALE_IPV4}` | `http://panel.…` | page files from `CONSOLE_WEB_DIR`; `/api/wg/*` and `/api/konsol/*` → Unix socket `WG_PANEL_SOCKET` (`/run/master-wg-panel/api.sock`, **DD-180**), other `/api/*` → `127.0.0.1:61009` (**DD-140**) |

`SERVICE_NAMES` is `panel`.

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
  `${TAILSCALE_IPV4}` — not `127.0.0.1` or `NXDOMAIN`. Stage 7 measures
  `dig +short … @127.0.0.1` and `@${TAILSCALE_IPV4}` for every name in
  `SERVICE_NAMES`; both must return `${TAILSCALE_IPV4}`.
- Every Caddy site is explicitly `http://`. No automatic HTTPS, no ACME,
  no certificate machinery — the tailnet is the transport security boundary;
  the opt-in WAN share site is deliberately plaintext (**DD-179**).
- Every upstream is plain HTTP on loopback or the root backend's Unix socket.
- The base names live in one list (`SERVICE_NAMES`) mirrored in both templates;
  adding a service means editing that list and both templates. A module's
  names live in its own files and come and go with it (**DD-149**).

---

## 5. Folder WebDAV: purpose (DD-158)

Selected folders, not a shared symlink root, are published through independent
accounts and stable /s/<id>/ URLs. RO is the default; RW includes permanent
delete/overwrite and requires acknowledgement. Each share selects Tailscale,
WAN IPv4 or both (**DD-179**); new shares default to Tailscale, and adding WAN
requires explicit consent that HTTP over the internet is unencrypted. The
listener scope, not a request header, decides which shares a request may
reach; each scope has its own attempt limits and connection budget (§3.1).
The binding implementation details are in [folder-shares.md](folder-shares.md).

## 6. WebDAV credentials and permissions (DD-158)

SHARE_STATE_FILE is a 0600 root-owned schema-3 JSON registry of networks, users, salted
scrypt hashes, folder identity, RO/RW, pause and expiry; any other schema is
refused. No plaintext password copy exists. The root API projects only non-secret metadata; fixed workers
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

master-paylasim.service runs master_webdav.py as DOWNLOADS_UID/GID on loopback
(127.0.0.1 for the Tailscale scope, SHARE_WAN_BACKEND for the WAN scope),
with no capabilities, system paths read-only, user area writable, internal
trash/share paths inaccessible, and network restricted to loopback. Caddy
publishes the `paylas.` name and Tailscale IP:SHARE_PORT and, while a WAN share
is active, the WAN IPv4:SHARE_PORT site (DD-179). No extra port number or
Tailscale policy change.

The installer prepares an empty registry only when absent and enables this
built-in service. Reruns preserve accounts; public module removal is refused.
Address refresh changes Caddy, not WebDAV. No route broader than `/s/<id>/`
exists.

The supported DAV subset, filesystem and concurrency limits and test
commands are specified in [folder-shares.md](folder-shares.md). Finder/Infuse
and recipient ACL reachability need separate operator acceptance.

---

## 8. Host firewall contract (`INPUT`)

Base policy (confirmed panel overrides are applied by `MASTER-SETTINGS` before
Tailscale acceptance; WG host ingress is dropped first in both project chains):

0. Drop all WG host ingress before any established, ICMPv6 or Tailscale accept.

1. Loopback (`lo`) traffic.
2. `ESTABLISHED,RELATED` connections — this is what keeps the operator's
   **currently active SSH session alive** while the policy is installed.
3. Inbound traffic arriving on `tailscale0` only for SSH, Caddy, DNS TCP/UDP,
   folder WebDAV, self-advertised Tailscale PeerAPI TCP and registered WireGuard
   UDP endpoints, subject to confirmed overrides (**DD-172**). Other new tailnet
   host connections are dropped in `MASTER-SETTINGS` before `ts-input` can accept
   them. Listener binding and firewall permission remain separate facts.
   The Tailscale port catalogue comes from this per-family allowlist and the WG
   registry, not arbitrary host sockets; explicit user rules remain manageable.
   Raw listeners and technical rules stay unfiltered (**DD-173**).
4. New inbound TCP on the WAN interface to `${SSH_PUBLIC_PORT}` (host sshd).
5. New inbound UDP for Tailscale and each registered WireGuard network.
6. Only while a WAN share is active (**DD-179**): new inbound IPv4 TCP on the
   WAN interface to `${SHARE_PORT}`, after the per-source and total
   connection-limit rejects that `MASTER-SETTINGS` places before operator rules.

Dropped:

7. Every other new inbound connection arriving on the WAN interface, and any
   new tailnet host service connection outside the allowlist/explicit overrides.

Rules:

- The policy is applied through a staging chain and swapped in atomically,
  so there is no moment at which SSH is unreachable. At the **end** of a
  successful apply every leftover staging chain is removed together with its
  parent jump, including one left referenced by an interrupted earlier run
  (**DD-95**).
- Boot exposes a measured ~850 ms window between the WAN address becoming
  usable and the policy landing; sshd, which the policy allows anyway, was
  the only WAN listener in it when measured. Rules
  are not persisted to disk (**DD-66**), so this window is accepted, not
  closed (**DD-95**).
- Established/related acceptance precedes the default WAN drop.
- The WAN interface is the **live default route at apply time**, not the
  `WAN_INTERFACE` recorded in `state.env`. A renamed NIC produces a warning
  and a correct policy, never a failed unit with no policy at all
  (**DD-94**).
- There is no **default** WAN permission for WebDAV, Caddy, dnsmasq or an
  application web interface; WAN WebDAV is only the per-share opt-in of item 6.
  Custom firewall allows do not change socket binds.
- The Internet port catalogue lists only configured per-family base permits;
  local/tailnet sockets do not create closed WAN placeholders. WireGuard lists
  the fixed internet-only policy with no editable host port. Explicit WAN/tailnet
  rules, required VPN endpoints and technical diagnostics remain visible; these
  lists do not discard requirements based on activity or peer count (**DD-174**).
- IPv6 `INPUT` follows the same shape and is equally fail-closed. Tailscale
  IPv6 traffic uses the service allowlist except Caddy/WebDAV (their templates
  bind IPv4 only); WAN IPv6 allows NDP/ICMPv6 essentials, host
  SSH TCP and Tailscale UDP, and drops other NEW WAN traffic, including the
  WebDAV share port.

---

## 9. Forwarding firewall contract (WireGuard)

This section covers the WireGuard forwarding and NAT policy and the shape
check shared with §8.

**Chain names are fixed** (**DD-59**): `MASTER-INPUT` for the host policy,
`MASTER-FORWARD` and `MASTER-NAT` for WireGuard (**DD-120**).
`MASTER-SETTINGS` owns confirmed panel overrides, followed by the core tailnet
allowlist/default drop, before the `ts-input` jump (**DD-156**, **DD-172**);
`MASTER-INPUT` remains behind it. User-created WireGuard endpoint ports remain
requirements regardless of current peer count or recent activity.
The same logical
names serve IPv4 and IPv6 — separate tables mean no collision — and all are
declared in `config/defaults.env` and nowhere else.

- The installer creates **only its own chains** and inserts **one
  idempotent jump** to each (`INPUT` → `MASTER-INPUT` behind `ts-input`,
  `FORWARD` → `MASTER-FORWARD`, `nat POSTROUTING` → `MASTER-NAT`; the latter
  two exist only while the installed WireGuard module has registered networks).
- tailscaled's own chains (`ts-input`, `ts-forward`) are **never** flushed or
  deleted; the firewall only orders `MASTER-INPUT` behind the `ts-input`
  jump (re-adding that jump when it is missing), which is why the
  nft-backend gate stays (§1.1).
- **Third-party rules already present in `INPUT`, `FORWARD` and
  `POSTROUTING` are never deleted**: the installer adds its jumps and leaves
  everything else in place.
- WireGuard (**DD-120/143/150**), for registered networks while installed:
  - `MASTER-SETTINGS` and `MASTER-INPUT` drop all WG ingress first.
    WG-scoped user rules are refused; no user rule can bypass the mandatory
    policy.
  - `MASTER-FORWARD` first drops destinations in `WG_BLOCK_DEST4/6`
    (private, CGNAT, loopback, link-local, multicast/reserved and standard NAT64
    prefixes), then accepts `wgN` → WAN. Other WG ingress is dropped.
    Only established/related replies arriving from WAN can reach WG; all other
    traffic toward WG is dropped. Prefix lists have one owner: defaults.env.
  - `MASTER-NAT`, in `nat POSTROUTING`, masquerades the WireGuard subnets out
    of the WAN.
  - wg-quick carries no `PostUp`: every rule belongs to `master-firewall`.
- IPv6 policy is explicit and fail-closed; it is generated even without an
  IPv6 WAN route. Missing IPv6 connectivity never switches off its protection.
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
  SSH, TCP `${SHARE_PORT}` while a WAN share is active and one UDP port per
  WireGuard network (none without the module), for IPv6 the first two. `MASTER-FORWARD` must hold four base rules plus the configured blocked-prefix rules per
  network, `MASTER-NAT` one per subnet, and INPUT's entire rule count and
  all IPv6 control types are checked. No managed chain emits a redundant
  terminal `RETURN`; intermediate settings returns remain essential. Any extra WAN pass, whether a blanket
  `-i eth0 -j ACCEPT` or one more port, fails the check (**DD-95**).
- **DD-175:** absent/empty/non-running WireGuard module registration never
  activates a retained network file. With no configured active-module networks,
  `MASTER-FORWARD`/`MASTER-NAT` and their jumps are absent, not empty placeholders.
  Removing the final network/module removes only these project-owned chains;
  adding a network recreates them. Interface state/peer count never decides
  whether a registered network's required endpoint or policy is kept.

---

## 10. systemd lifecycle

| Unit | After | Coupling | Restart |
|---|---|---|---|
| `tailscale-udp-gro.service` | `network-online.target` | none | `no`, oneshot, `RemainAfterExit` |
| `master-firewall.service` | `network-online.target tailscaled.service` | `PartOf=tailscaled.service` only (**DD-152**) | `on-failure` (oneshot, `RemainAfterExit`, `RestartSec=10s`, `StartLimitBurst=12` / 300s) |
| `refresh-tailnet-config.timer` | — | address poll + firewall watchdog (checked again once Tailscale answers); resets a failed Caddy's start limit before restarting it; reopens failed WireGuard networks (**DD-180**, **DD-182**) | starts oneshot every 5 min (`OnBootSec=2min`) |
| `caddy.service` (drop-in) | `tailscaled.service master-firewall.service` | `Wants=` both (no `PartOf`); `ExecStartPre=+master-firewall --check` (**DD-179**); `OnFailure=refresh-tailnet-config.service` (**DD-87**) | `on-failure` + StartLimit (drop-in) |
| `dnsmasq.service` (drop-in) | `tailscaled.service` | `Wants=tailscaled.service` | `on-failure`, `RestartSec=5s` (drop-in) |
| `master-wg-panel.service` (Konsol root backend) | `network-online.target` | none; Unix socket only (**DD-180**) | `on-failure`, `RestartSec=3s` |
| `master-files-panel.service` (built in) | `network-online.target` | none; `127.0.0.1` listener, `RequiresMountsFor=SERVER_ROOT`, always enabled by `master-modul yerlesik` | `on-failure`, `RestartSec=3s` |
| `master-paylasim.service` (built-in WebDAV) | `network-online.target` | none; `127.0.0.1` and `SHARE_WAN_BACKEND` listeners, always enabled by `master-modul yerlesik` | `on-failure`, `RestartSec=3s` |
| `master-share-network.timer` | — | closes expired WAN share projections and recovers interrupted share operations (**DD-179**) | starts oneshot 30 s after boot and 30 s after each run |
| `master-settings-guard.timer` | — | rollback deadline of an unconfirmed Settings change; active only while one is pending (**DD-181**) | starts oneshot every 2 s while active; once 15 s after boot |
| `apt-daily-upgrade.timer` (drop-in, **DD-184**) | — | distribution unit; `OnCalendar` at `APT_UPGRADE_TIME` (04:00), `RandomizedDelaySec=30m`, the distribution's `Persistent=true` kept | daily |
| `wg-quick@wgN.service` (drop-in, **DD-180**) | `master-firewall.service` | `Wants=`; `ExecStartPre=+master-firewall --check`, so a network never forwards without the owned rules | package default; a network left failed is reopened by `refresh-tailnet-config` once the check passes |

The Caddy drop-in also carries
`EnvironmentFile=/etc/master-stack/state.env`, which is how
`{$TAILSCALE_IPV4}` in the Caddyfile is resolved at daemon start. There is
no separately rendered environment file (**DD-61**), so `state.env` must be
written in a form both bash and systemd can parse: plain `KEY=value`,
no spaces around `=`; whitespace-separated prefix lists use double quotes
with no shell expansion. `ExecStartPre=wait-tailnet-addr` requires
that address on `tailscale0` (**DD-85**).

Invariants:

- **Restarting `tailscaled` re-applies the firewall
  (`master-firewall` is `PartOf=tailscaled.service`) and leaves every module
  running.** Caddy is restarted when `refresh-tailnet-config` sees an
  address change, when Caddy fails and `OnFailure=` starts that oneshot
  (**DD-87**), or when the operator restarts it. The share WebDAV is a host
  service with no tie to `tailscaled`.
- **The firewall unit orders itself only after `network-online.target` and
  `tailscaled.service`.** Host `INPUT` must land as early as possible
  (**DD-94**).
- **One bounded watchdog, at the network edge only.**
  `refresh-tailnet-config` — which already runs every 5 minutes — restarts
  `master-firewall` when the unit is `failed` or `--check` fails, after a
  `reset-failed` so an exhausted start limit cannot block the recovery. It
  skips the round while the oneshot is mid-apply. Beyond the firewall it only
  restarts a failed Caddy and reopens failed enabled WireGuard networks
  (**DD-180**, **DD-182**): no module, file, or binary is reconciled
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
  every `wgN.conf` and `clients-wgN/` with the networks registry (keys and
  device profiles are never rewritten), the operator's chosen local domain.
- Firewall application is idempotent by construction: each chain is rebuilt
  from scratch and swapped in, and each parent jump is inserted only when
  absent.
- Directory creation is conditional; ownership/mode repair under downloads
  is selective (mismatched UID/GID/mode only — **DD-84**), not a full-tree
  rewrite and not limited to newly created directories.
- No step is unconditionally expensive: package installation and daemon
  restarts happen only when something actually
  changed.
- The only re-run question is the optional full-upgrade (default **hayır**).
  Folder WebDAV code is part of the installer (§7).

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
| WebDAV registry preparation (`master_shares.py prepare`) fails | `master-modul yerlesik` stops before the service is started; systemd also refuses a unit whose credential file (the registry) is missing |
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

5. No application web service gets a default WAN listener. A clean install
   creates no WireGuard network. With WireGuard installed, each active network
   matches the registry's address/port, `master-wg version` runs, and all
   networks are internet-only with no WG service listener.
6. No module web interface listens on a non-loopback address.
7. The loopback services of §3.3 (Konsol file backend, built-in WebDAV and the
   installed qBittorrent UI) listen on loopback only (`127.0.0.1`; WebDAV
   also on `SHARE_WAN_BACKEND`). The root backend and Caddy's admin API have no TCP port; stage 7 checks
   the socket modes, that the downloads account cannot connect to either, that
   `127.0.0.1:2019` is closed and that `systemctl reload caddy` still works (**DD-180**).
8. Main Caddy listens on `${TAILSCALE_IPV4}:80` and
   `${TAILSCALE_IPV4}:${SHARE_PORT}` (Infuse), and on `${WAN_IPV4}:${SHARE_PORT}`
   only while a WAN share is active; no WG web listener exists.
9. dnsmasq answers on `${TAILSCALE_IPV4}:53` **and** `127.0.0.1:53`, and on no
   other address; it serves no DHCP.

### DNS and Caddy

10. Enabled base/installed-module names resolve to `${TAILSCALE_IPV4}` when queried
    against `${TAILSCALE_IPV4}`; `health.` is not a built-in name.
11. A query for an out-of-domain name against `${TAILSCALE_IPV4}` returns
    `REFUSED` by default (or resolves via configured upstreams when enabled).
12. `curl -H "Host: panel.${LOCAL_DOMAIN}" http://${TAILSCALE_IPV4}/` returns
    the Konsol page, HTTP 200; both installed API backends pass their checks.
13. Backend API gates reject missing `X-Konsol` and unrelated Host headers.
    With the qBittorrent module installed, `master-modul kur torrent` checks
    that `/api/v2/app/version` answers `403` without a login on loopback and
    through `torrent.${LOCAL_DOMAIN}`; a `200` means a localhost or subnet
    authentication bypass is on (**DD-127**, **DD-151**).
14. WebDAV listens only on loopback as DOWNLOADS_UID; Caddy owns the tailnet
    port and, only while a WAN share is active, `${WAN_IPV4}:${SHARE_PORT}`.
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

### Firewall

24. The base policy accepts loopback, `ESTABLISHED,RELATED`, Tailscale,
    WAN SSH/Tailscale UDP, registered WireGuard UDP ports and, only while a
    WAN share is active, WAN IPv4 TCP `${SHARE_PORT}`; other NEW WAN
    input is dropped. Confirmed `MASTER-SETTINGS` overrides are tested separately.
25. `INPUT` holds exactly one jump to `MASTER-INPUT`, behind `ts-input`;
    `FORWARD` exactly one to `MASTER-FORWARD` and `nat POSTROUTING` exactly
    one to `MASTER-NAT`, in both families, while WireGuard networks are
    registered (§9). `MASTER-SETTINGS` has its own single jump before `ts-input`.
26. A third-party rule planted in `INPUT` or `FORWARD` before the run is
    still present after it.
27. tailscaled's own chains (`ts-input`, `ts-forward`) are not flushed or
    deleted.
28. `MASTER-FORWARD` permits no NEW WAN traffic into a WireGuard network.
29. The active SSH session survives policy application.

### Lifecycle

30. `systemctl restart tailscaled` leaves every installed module running.
31. `systemctl restart tailscaled` also results in a re-applied firewall
    policy, `MASTER-INPUT` behind `ts-input`.
32. After a full reboot: every module marked `calisiyor` running, every name resolving,
    public wg UDP published, built-in WebDAV answering `401` via Caddy.
33. `systemctl --failed` is empty.

### Idempotency

34. A second complete run changes no byte of any generated file, restarts
    no module service it did not need to, and preserves the folder share
    registry (`SHARE_STATE_FILE`).
