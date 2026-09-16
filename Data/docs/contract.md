# Behaviour Contract

**Status:** behaviour contract (frozen intent 2026-08-05). Implemented by the
lean tree at the repository root (`install.sh` and helpers). Where live code and this
document diverge, prefer the code and update this file.

This document is the authoritative statement of what the installer does
and — just as importantly — what it deliberately refuses to do. Removals
relative to the retired monolith (no reconcile engine, no
canonical-bundle machinery, no host WebDAV unit) are decisions, not
oversights. There is no parallel legacy installer tree.

**Relationship to `.cursor/rules/`:** those rules cover the repository and
govern *how* the work is done — process, Bash conventions, the
per-phase verification set, and the hard prohibitions (do not delete Docker's
chains, do not silently turn the UDP-only decision into TCP+UDP, do not grow
a general-purpose reconcile engine). This document governs *what the result
must do*. Where the rules are silent (for example on WebDAV), this contract
extends them. Settled disagreements with early rule drafts — dnsmasq
listening scope, chain name, refresh helper scope, Portainer upstream
scheme — are recorded as **DD-59** through **DD-62** in
`design-decisions.md`. Portainer itself was replaced by Dozzle in v2-82
(**DD-116**).

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
| R9 | Install Docker Engine and the Compose plugin |
| R10 | Generate a Compose file for Dozzle (replaced Portainer, **DD-116**), qBittorrent (replaced Transmission again, **DD-127**), Unpackerr and the share WebDAV (rclone). FileBrowser was retired; Konsol manages the files (**DD-146**) |
| R11 | Publish every web interface on `127.0.0.1` only |
| R12 | Publish publicly the WireGuard UDP port (host kernel since v2-86, **DD-120**; formerly wg-easy) and the torrent (qBittorrent) peer port (TCP+UDP) |
| R13 | Ask the operator for a local domain at the start of the installation (since v2-85 read from the installer input file, **DD-119**) |
| R14 | Resolve the defined service names to the Tailscale IPv4 with dnsmasq |
| R15 | Have Caddy listen on the Tailscale IPv4 only, over HTTP |
| R16 | Reverse-proxy the service names to the loopback interfaces through Caddy |
| R17 | Tell the operator to configure Custom DNS and Restrict-to-domain manually in the Tailscale admin panel |
| R18 | Create persistent firewall rules that permit Tailscale traffic, the public peer ports (wg UDP + torrent peer TCP+UDP), and WAN host SSH TCP `${SSH_PUBLIC_PORT}` |
| R19 | Filter Docker ports through `DOCKER-USER` |
| R20 | Keep the installation re-runnable |

---

## 1. Included features

### 1.1 Base system

- Supported-OS hard gate (**R1**, **DD-102**): Debian 13 (trixie),
  Ubuntu 24.04 LTS (noble) or Ubuntu 26.04 LTS (resolute); the installer
  refuses any other OS or release. Apt repo suites for Tailscale and
  Docker are derived from `os-release` (`OS_ID`/`OS_CODENAME`), never
  hardcoded, and each vendor's `dists/<codename>/Release` is probed before
  its source file is written (**DD-106**). On a host with ufw active the
  installer stops before any mutation. The `iptables`/`ip6tables` backend
  must be the nft one Docker uses; stage 0 asserts this for whichever
  binaries the host already has and stage 1 asserts it unconditionally once
  the package is installed, because a minimal Debian image ships none
  (**DD-106**, **DD-108**). Live-verified on fresh
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
  restarts `sshd`, `docker`, `containerd`, `tailscaled`, `caddy` and
  `dnsmasq` automatically in the middle of a stage.
- Every rendered config is validated on the target before the unit that
  consumes it restarts: `dnsmasq --test -C`, `caddy validate` with the real
  `TAILSCALE_IPV4`/`WEBDAV_PORT`, and `docker compose config -q`
  (**DD-106**).
- `apt-get update` + `full-upgrade`, then the package set the stack needs
  (**R1**, **R2**). `apache2-utils` stays for `htpasswd`; rclone runs only
  as the Compose image (see §5, **DD-77**). No host `rclone` or `acl`
  package.
- `unattended-upgrades` is installed and enabled for the distribution's own
  origins (Debian stable + security; Ubuntu security), with automatic reboot
  off; Docker, Tailscale and Caddy packages are updated only by a re-run
  (**DD-113**).
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
    full-upgrade and image pull; an interactive TTY stays required.
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

### 1.3 Docker and containers

- Docker Engine, CLI, containerd and the Compose plugin, installed without
  their recommended packages (no buildx, git or rootless extras) plus
  `apparmor` and `pigz` (**R9**, **DD-125**).
- The installer's own apt downloads are not kept in `/var/cache/apt/archives`
  (`APT::Keep-Downloaded-Packages=false`) (**DD-125**).
- One Compose file with exactly four services: `dozzle`, `qbittorrent`,
  `unpackerr`, `paylasim` (**R10**, **DD-116**, **DD-127**, **DD-142**,
  **DD-146**).
- qBittorrent (LinuxServer image) keeps `/config` on
  `/etc/master-stack/qbittorrent`, and its settings come from the installer
  (**DD-129**):
  - `templates/qBittorrent.conf` lists the managed keys: the operator's
    settings, derived from a clean-file diff, plus
    `WebUI\LocalHostAuth=true` and `WebUI\AuthSubnetWhitelistEnabled=false`.
    `TORRENT_USER`/`TORRENT_PASS` supply `WebUI\Username` and
    `WebUI\Password_PBKDF2`.
  - Stage 4 compares those keys with `QBITTORRENT_CONF_FILE` on every run.
    - Nothing differs: nothing is written and the container is not touched.
    - Something differs: qBittorrent is stopped (it rewrites its file on
      exit), only the differing keys are set in place or added, and it is
      started again.
    - No file: it is created from the template.
    - Keys qBittorrent adds itself are kept.
  - The password is stored only as qBittorrent's PBKDF2-SHA512 hash (100000
    iterations, 16-byte salt), computed by `python3` from stdin. An existing
    hash is kept when it verifies against `TORRENT_PASS`.
  - A setting changed in the UI for a managed key returns to the template on
    the next run; unmanaged settings stay.
  - Stage 7 logs in with the input account (password on stdin; success is
    `204`/`200` plus a `SID` cookie). It stops on the first refusal, because
    qBittorrent bans an IP after repeated failures. It then requires the
    username and both authentication bypasses off.
  - The web UI and peer ports come from `WEBUI_PORT`/`TORRENTING_PORT`, which
    the image passes on the command line at every start, so the config file
    cannot move them.
- Dozzle runs with `DOZZLE_AUTH_PROVIDER=simple` and actions enabled (start,
  stop, restart, remove, update), no shell, read-only root, all capabilities
  dropped and `no-new-privileges`. Its `users.yml` is written by the
  installer from the input file, using the image's own `generate` command
  with the password on stdin and the `actions` role. It is regenerated, with
  a Dozzle restart, only when it no longer holds exactly that account
  (**DD-119**).
- There is no FileBrowser (**DD-146**): no container, no account in the input
  file, no port and no database. Files are managed in Konsol (§1.10);
  `file.${LOCAL_DOMAIN}` redirects there. A re-run on a host that still has
  the old container removes it through `docker compose up --remove-orphans`;
  `/etc/master-stack/filebrowser-data` is left for the operator to delete.
- Every web interface and WebDAV published on `127.0.0.1` only (**R11**).
- Containers survive a reboot through the Compose **restart policy**
  (`restart: unless-stopped`), not through a systemd unit. `master-compose.service`
  does not exist in the first v2 release.

### 1.4 Directories

- `/downloads`, `/downloads/media`, `/downloads/media/movies`,
  `/downloads/media/series` and the Unpackerr work directory are created
  when absent (**R8**).
- **The downloads tree is repaired selectively on every run** (**DD-84**):
  entries whose UID/GID differ from `DOWNLOADS_UID`/`DOWNLOADS_GID`
  (defaults `1000:1000`) are `chown -h`'d; directories not mode `0775` and
  files not mode `0664` are `chmod`'d. Matching entries are left untouched
  (no full-tree rewrite). qBittorrent, Unpackerr and Konsol's file backend
  share read/write that way. The share WebDAV remains read-only (`:ro` mount +
  `--read-only`).

### 1.5 DNS and Caddy

- dnsmasq bound to `tailscale0` only, tracking the interface address with
  `interface-name` + `bind-dynamic`, resolving the six service names to the
  current Tailscale IPv4 (**R14**).
- Caddy listening on the Tailscale IPv4, port 80, HTTP only, reverse-proxying
  to loopback upstreams (**R15**, **R16**).
- A `health.<domain>` endpoint that answers `ok`, used as the single cheap
  end-to-end probe.

### 1.6 Firewall

- A host `INPUT` policy (the retired installer had none) and a Docker forwarding
  policy, both fail-closed (**R18**, **R19**). Full contract in §8 and §9.
- The **staging-chain swap** is preserved wherever it applies: rules are
  built in a throwaway chain and swapped in atomically, so there is no
  window in which the host runs with a partial policy.
- Nothing is persisted to disk. `master-firewall.service` re-applies the
  policy on boot and whenever Docker restarts (`PartOf=` plus a
  `docker.service.d` `ExecStartPost` restart so a prior INPUT-only apply
  cannot leave `RemainAfterExit` stuck without `MASTER-DOCKER`).

### 1.7 WebDAV

Preserved in full as a core feature. Contract in §5–§7.

### 1.8 Operator guidance

- The manual Tailscale admin steps are printed at the end (**R17**, §13).
- No password reminders are printed: every service account comes from
  `kurulum/kurulum.env` (**DD-119**).

### 1.9 WireGuard (DD-120, DD-124)

- **A fresh install has no WireGuard (DD-143).** The installer installs
  `wireguard-tools` and `qrencode` (`--no-install-recommends`), loads the kernel
  module, creates `/etc/wireguard` and `master-wg`, and starts whatever networks
  the registry already holds. It generates no key, writes no `.conf` and brings
  up no interface; it also never removes a network.
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
  Dozzle and qBittorrent UIs at `http://<that network's server address>:<port>`
  when its scope is `ui`. Files are not reachable over WireGuard: Konsol is
  tailnet-only and FileBrowser is gone (**DD-146**).
  Nothing else: not the tailnet, WebDAV, SSH, dnsmasq, Docker networks or
  other peers (§9).
- The UIs are served by `caddy-wg@wgN.service` (`/etc/caddy/Caddyfile.wg`, admin
  API off, address from `/etc/wireguard/caddy-wg-wgN.env`, written by `master-wg`
  when the network is created). Each instance binds only its own network's server
  address, follows its `wg-quick@wgN` and has no Tailscale dependency, so the
  path survives a Tailscale outage.
- **WireGuard web panel (DD-133).** `master-wg-panel.service` serves a page at
  `http://panel.${LOCAL_DOMAIN}` (**DD-140**; `wg.${LOCAL_DOMAIN}` redirects
  there) to list, add and remove peers, show a peer's QR code, download its
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
    `/etc/wireguard` writable, `ProtectHome`, `PrivateTmp`, the kernel
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
    Dozzle and qBittorrent on its own server address through
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

### 1.10 Konsol and the file backend (DD-139, DD-140)

- **One console (DD-140).** `http://panel.${LOCAL_DOMAIN}` is the only
  administration page. Caddy sends `/api/wg/*` to `master-wg-panel` and
  everything else, the page files included, to `master-files-panel`;
  `wg.${LOCAL_DOMAIN}` and `dosya.${LOCAL_DOMAIN}` answer with a 302 to it.
  Both backends accept only that host, require the header `X-Konsol` on
  `/api/*`, and use the realm `Konsol`, so one browser login covers both.
  - Pages: Genel bakış (server card with CPU, memory and disk, WireGuard
    devices, last actions, ports in use), WireGuard, Dosyalar and Günlük.
  - The ports card is built from `state.env` and the network registry; nothing
    is scanned and no container status is collected.
  - A peer or a whole network can be switched off and on (§1.9).
- **Share links (DD-141).** A folder or file in `DOWNLOADS_PATH` can be shared
  from the console. Every share appears in one read-only WebDAV root at
  `http://paylas.${LOCAL_DOMAIN}` (loopback `61010` behind Caddy, tailnet
  only), with one account for all of them (`SHARE_USER` / `SHARE_PASS`).
  - Sharing creates a relative symlink in `DOWNLOADS_PATH/SHARE_DIR/w`; the
    registry next to it (not served) holds the path, the creation time and the
    expiry. Nothing is copied.
  - A share lasts 1, 7 or 30 days or until it is removed. Expired shares and
    links with no registry entry are swept on every listing; files are never
    deleted.
  - The root itself, the trash and the share folder cannot be shared, and the
    file panel hides the share folder from listings.
  - The container runs `--read-only` with `--copy-links` and mounts
    `SERVER_ROOT` read-only; `qbittorrent` and `unpackerr` mount only
    `SERVER_ROOT/downloads`, so the share folder and the trash are outside what
    they can see (**DD-144**).
- `master-files-panel.service` serves the console pages and a file manager for
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
  - The installer creates the folder. The `unpackerr` and `webdav` containers
    mount an empty read-only tmpfs over `/downloads/.cop`, so archives in the
    trash are not extracted again and WebDAV lists only an empty folder.
- Text view: the first 1 MiB of a regular file.
  - A file with a NUL in the first 8 KiB is refused as binary.
  - The encoding is guessed (UTF-8, else Windows-1254; `.nfo` in CP437) or chosen
    by the operator, and decoded on the server.
  - The page inserts the text as text nodes only.
- The page marks qBittorrent's temporary folder (`Session\TempPath` from
  `templates/qBittorrent.conf`) and warns before moving or deleting there.
- A switch at the top links `wg.${LOCAL_DOMAIN}` and `dosya.${LOCAL_DOMAIN}`.
- It replaced FileBrowser (**DD-146**): `file.${LOCAL_DOMAIN}` redirects to
  the console.

---

## 2. Deliberately excluded features

Each entry names the v1 mechanism, its cost, and why it is gone.

| Excluded | Legacy cost | Why it is excluded |
|---|---|---|
| **Canonical generation directory, `SHA256SUMS` manifest, `current` pointer** | ~400 lines, 3 bats suites, 6 DD entries | Served no requirement. The correct way to repair a drifted managed file is to re-run the installer (**R20**), not to have a timer silently revert it. |
| **Automatic file restore from a canonical copy** | ~90 lines of restore blocks | Same. An operator edit is now an operator's decision; v2 never silently reverts it. |
| **The 1821-line `master-network-reconcile`** | 33% of the file | Replaced by `refresh-tailnet-config`, which does one thing: react to a Tailscale address change. |
| **General container self-healing** | `probe_compose_runtime` + 12 probes + restart engine | Compose's own restart policy handles crashes. A health probe that restarts containers turns every upstream image change into a restart loop. |
| **Restart cooldown stamp files** | ~120 lines, `/run` stamps, 4 duplicated constants | systemd already rate-limits with `StartLimitIntervalSec`/`StartLimitBurst`. A second, parallel accounting system that then exempts itself is not a safety net. |
| **Image-digest-based recovery** | digest recording + final cross-check | Digests are still *recorded* for identification; nothing acts on a mismatch. |
| **Disk and inode threshold checks** | ~40 lines | Reports without repairing — that is monitoring, not installation. |
| **Default-password auditing of FileBrowser** | ~50 lines, a daily login attempt against the container | Nothing to audit: FileBrowser itself was retired in v2-114 (**DD-146**). |
| **`master-compose.service`** | 24-line unit + ~45 dependency assertions | Not in the first v2 release. Compose restart policy covers reboot; nothing else needed a unit. |
| **`master-compose` coupled to `tailscaled` via `Requires`/`PartOf`** | — | No container binds to the Tailscale address, so the coupling only meant that restarting `tailscaled` bounced the entire stack. **A Tailscale restart must not restart the Compose stack.** |
| **Host `master-webdav.service` / `webdav.env` / distro `rclone`** | unit + ACL user + apt | Replaced by Compose `webdav` on loopback (**DD-77**). The installer never installs them; it also no longer hunts for them — the migration cleanup was removed in v2-62 (**DD-96**). |
| **Migration cleanup for older revisions** | `purge_host_webdav_leftovers`, `remove_stale_filebrowser`, retired unit/symlink deletion (~83 lines) | The upgrade path is a fresh install or a re-run that overwrites what the installer owns. A global `apt-get purge`, a `userdel`, or deleting a container the operator may still want is outside the installer's boundary (**DD-96**). |
| **`master-docker-netfilter-recovery`** | 47-line script + unit | Docker's own chains are re-established by Docker; v2 re-applies only its own chain. |
| **DNS/Caddy rollback state machine** | ~155 lines, 19 globals, 7 tests | Fail-closed masking is kept (2 lines); a failed install leaves the optional services *masked*, which is safe. Recovery is a re-run. |
| **The 25-flag reconcile `--check` surface** | — | Replaced by a small set of checks with one owner each. |
| **Progress bar, ANSI colour, extra file descriptors 3/4/5** | ~210 lines | Plain timestamped stage lines plus a log file. |

---

## 3. Port publication contract

Three exposure classes, and nothing may straddle them.

### 3.1 Public (WAN IPv4) — Compose publications

| Service | Listen address | Port | Protocol |
|---|---|---|---|
| qBittorrent (peer) | `0.0.0.0` (IPv4-only; firewall scopes WAN) | `${TORRENT_PUBLIC_PORT}` (61005) | **TCP + UDP** |

**WireGuard is a host listener, not a Compose publication (DD-120):** the
kernel's `wg0` socket on UDP `${WG_PUBLIC_PORT}` (61001) is admitted by
`MASTER-INPUT` on the WAN interface.

**Host SSH is a separate MASTER-INPUT exception:** inbound TCP
`${SSH_PUBLIC_PORT}` (default 22) on the WAN interface is accepted so
console recovery and public-IP SSH keep working; it is not a Docker
publish and does not appear in `docker port`.

Public peer ports are IPv4-only host binds (`0.0.0.0:port:port/...`), not
dual-stack unqualified publishes and not a specific WAN IP. Firewall
limits NEW WAN traffic to WireGuard UDP, torrent peer TCP+UDP, and SSH.
(R12 revised 2026-08-06: peer TCP restored to match legacy
connectivity. 2026-08-07: drop `[::]` peer publish — unused and already
dropped by IPv6 `MASTER-DOCKER`.)

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
| Dozzle | `127.0.0.1` | 61002 (**DD-116**) |
| qBittorrent WebUI | `127.0.0.1` | 61006 (**DD-127**) |
| Konsol WireGuard backend (`master-wg-panel`) | `127.0.0.1` | 61008 (**DD-133**, **DD-140**) |
| Konsol file backend and pages (`master-files-panel`) | `127.0.0.1` | 61009 (**DD-139**, **DD-140**) |
| WebDAV — shares only (`paylasim`) | `127.0.0.1` | 61010 (**DD-141**, **DD-142**) |

Reached from the tailnet through Caddy (**R11**, **R16**, **DD-98**):
`webdav.*:80` and `${TS_IPV4}:${WEBDAV_PORT}`. Compose never names the
Tailscale address. No WAN / `0.0.0.0` publish.

### 3.4 Single source of truth

Every number above is declared exactly once, in `config/defaults.env`,
and reaches the Compose file, the Caddyfile, the firewall script and the
state file by substitution. A port literal appearing twice is a bug.

### 3.5 WireGuard (`wg0`) — reachable only by WireGuard clients

| Service | Listen address | Port |
|---|---|---|
| caddy-wg@wgN → Dozzle, qBittorrent (`ui` networks) | that network's server address | 61002, 61006 (TCP, HTTP only) |
| caddy-wg@wgN (panel networks with scope `ui`) | `10.8.N.1` | 61002, 61006, 61007 (TCP, HTTP only) |

No names, no WebDAV, no dnsmasq on any WireGuard network (**DD-120**,
**DD-136**). Each network's UDP port is open on the WAN in `MASTER-INPUT`.

---

## 4. DNS and Caddy service map

`${LOCAL_DOMAIN}` comes from the installer input file (**R13**, **DD-119**);
an empty value takes `DEFAULT_LOCAL_DOMAIN` from `defaults.env`.

| Name | dnsmasq answer | Caddy site | Upstream |
|---|---|---|---|
| `dozzle.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://dozzle.…` | `127.0.0.1:61002` (**DD-116**) |
| `torrent.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://torrent.…` | `127.0.0.1:61006` (**DD-117**) |
| `file.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://file.…` | `127.0.0.1:61007` |
| `webdav.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://webdav.…` | `127.0.0.1:${WEBDAV_PORT}` (see §7.4) |
| `health.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://health.…` | `respond "ok" 200` |
| `wg.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://wg.…` | `127.0.0.1:61008` (**DD-133**) |
| `dosya.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://dosya.…` | `127.0.0.1:61009` (**DD-139**) |

Rules:

- dnsmasq answers **only** for `${LOCAL_DOMAIN}`; every other query is
  `REFUSED`. It is not a general-purpose resolver and never a forwarder.
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
- The six names live in one list (`SERVICE_NAMES`) mirrored in both templates;
  adding a service means editing that list and both templates.

---

## 5. WebDAV and Infuse: purpose

The WebDAV service exists for exactly one consumer: **the Infuse app on an
Apple TV**, reading the media library over the tailnet.

- Infuse needs plain WebDAV over HTTP with basic authentication. It does not
  need, and must not be given, WAN reachability.
- The served root is the host directory `/downloads`.
- Infuse is expected to browse:
  - `/downloads/media`
  - `/downloads/media/movies`
  - `/downloads/media/series`
- Access is **read-only**. Infuse never writes; the service must make a
  write impossible rather than merely discouraged.
- The installer creates only the directories it needs. Host ownership repair
  of `/downloads` is the selective Stage 3 pass in §1.4 (**DD-84**); WebDAV
  itself stays read-only.

WebDAV is a Compose service (**DD-77**), not a host unit: it publishes only
on loopback; Caddy is the Infuse path on `${TS_IPV4}:${WEBDAV_PORT}`
(**DD-98**). Docker down means WebDAV down — same dependency as the media
producers.

---

## 6. WebDAV authentication and read-only contract

### 6.1 Credentials

- The WebDAV **username** and **password** are `WEBDAV_USER` and
  `WEBDAV_PASS` in the installer input file (**DD-119**).
- Every run checks the htpasswd against them with `htpasswd -vi`, password on
  stdin. The file is rewritten, and `webdav` restarted, only when it no longer
  holds exactly that account.
- The username is validated against a safe character set:
  lowercase first character, then lowercase letters, digits, dot,
  underscore or hyphen, at most 32 characters.
- A minimum password length is enforced.

### 6.2 Credential storage — recorded decision

This is a binding decision, not a preference. Each numbered item is a
property the implementation must satisfy and a test must assert.

1. **WebDAV credentials live in a separate, root-owned credential file**,
   `/etc/master-stack/webdav.htpasswd` (bcrypt hash). Not in a
   configuration file, not in a unit, not in an environment file.
2. **Mode is at most `0600`**, owner `root:root`, verified after writing.
3. **The Compose `webdav` service mounts the file read-only at
   `/run/secrets/webdav_htpasswd`.** rclone is started with
   `--htpasswd=/run/secrets/webdav_htpasswd` (path only — no secret on the
   command line).
4. **The container may run as root** so it can read a host `0600`
   htpasswd without widening the file mode. Capability drop (`cap_drop:
   ALL`) and double read-only (`:ro` volume + `--read-only`) stay in force.
5. **The password is not present in Compose YAML or systemd unit content**
   — not as `environment:`, not as a command argument value, not in a
   drop-in.
6. **The password is not written to any environment file** — not
   `config.env`, not `state.env`, not `config/defaults.env`. The
   forbidden keys are named explicitly in `defaults.env`:
   `WEBDAV_PASSWORD`, `WEBDAV_PASSWORD_HASH`, `WEBDAV_USER_PASSWORD`.
   There is no `webdav.env`. The operator's input file
   (`kurulum/kurulum.env`) is not one of these files. It stays on the
   workstation, git-ignored with mode `600`, and reaches the server only in
   `/run` (`tmpfs`) until stage 0 deletes it (**DD-119**).
7. **The password does not appear on a command line.** The server is
   pointed at a file path, so `ps` / `docker inspect` args contain no
   secret.
8. **The password is not written to logs.** The input-file parser never
   prints a value, the hashing and verification tools take it on stdin, and
   no log statement echoes the variable.
9. **The username is managed with the credential, not with the
   configuration.** The htpasswd format already stores `user:hash`, so
   recording the name separately would create a second source of truth
   that can drift from the hash. `WEBDAV_USER` therefore does not exist in
   any of the configuration files either. The operator's input file is the
   source the htpasswd is derived from, and each run rewrites the htpasswd
   when it drifts (**DD-119**).
10. **On a re-run, an existing valid credential file is preserved.** The
    operator resets it by deleting the file and re-running, and the
    installer says so. Nothing left by an older revision is hunted down
    (**DD-96**).

### 6.3 Where each piece lives

| Item | Location | Mode | Secret |
|---|---|---|---|
| Username + password hash | `/etc/master-stack/webdav.htpasswd` | `0600` | **yes** |
| Port (loopback + Caddy Infuse) | `config/defaults.env` → Compose + Caddy | — | no |
| Credential file **path** | `config/defaults.env`, Compose volume | — | no |
| Read-only / image pin | Compose template + `RCLONE_IMAGE` | — | no |

The plaintext password exists only inside the installer process, for as
long as it takes to hash it.

### 6.4 Credential exposure checks

Against a running `webdav` container:

- `docker inspect` / process args contain no password and no username,
- the container environment contains no password,
- host `ps` for the container entrypoint shows only the htpasswd *path*,
- `/etc/master-stack/webdav.htpasswd` remains `root:root` `0600` on the host.

### 6.5 Read-only enforcement

- rclone runs with an explicit `--read-only` flag.
- `/downloads` is mounted `:ro`; no other host path is reachable through it.
- A write attempt must be refused by the service. This is a tested
  behaviour, not an assumption.

---

## 7. WebDAV Compose lifecycle

### 7.1 Service

One Compose service: `webdav` (`rclone/rclone` image). No host
`master-webdav.service`.

### 7.2 Ordering and coupling

| Property | Value | Reason |
|---|---|---|
| Publish | `127.0.0.1:${WEBDAV_PORT}:8080` | Tailnet reachability only via Caddy |
| Docker coupling | same lifecycle as the media stack | Accepted: Docker down ⇒ WebDAV down (**DD-77**) |
| Tailscale coupling | **none in Compose** | Caddy binds `${TS_IPV4}` from `state.env` |
| Restart | Compose `unless-stopped` | No custom cooldown stamp system |

### 7.3 Reacting to a Tailscale address change

WebDAV does not bind the Tailscale address. When the Tailscale IPv4
changes, `refresh-tailnet-config` updates `state.env` and restarts **only
Caddy** (both `:80` and `:${WEBDAV_PORT}` Infuse listeners):

```
Tailscale IPv4 change
  → state.env updated (atomically)
  → caddy          restarted
  → WebDAV         untouched (loopback)
  → dnsmasq        untouched
  → firewall       untouched
  → Compose stack  untouched
```

The same oneshot also acts as the firewall watchdog (§10), independent of
the address change.

dnsmasq and the firewall still match the interface name rather than an
address. `master-firewall` may still be `PartOf=tailscaled.service`; that
must never bounce Compose.

### 7.4 Access path decision

| Path | Address | Purpose |
|---|---|---|
| Preferred (MagicDNS) | `http://webdav.${LOCAL_DOMAIN}` | Phone Infuse / clients with MagicDNS |
| Apple TV Infuse (no MagicDNS) | `http://${TS_IPV4}:${WEBDAV_PORT}/` | Caddy site on that port → loopback (**DD-98**) |
| Loopback (host-local) | `http://127.0.0.1:${WEBDAV_PORT}` | Installer / Caddy upstream / debug |

Caddy proxies `webdav.${LOCAL_DOMAIN}` and
`http://{$TAILSCALE_IPV4}:{$WEBDAV_PORT}` to `127.0.0.1:{$WEBDAV_PORT}`
(placeholders from `state.env`). Compose stays loopback-only and never
names the Tailscale address (**DD-77**). Bare `http://${TS_IPV4}/` on
port 80 is **not** WebDAV. A re-run that changes `WEBDAV_PORT` rewrites
Compose and restarts Caddy.

No TLS between Caddy and WebDAV: both endpoints are on the same host, and
the hop is loopback.

### 7.5 Firewall consequence

**No WAN firewall permission is created for WebDAV.** Tailnet clients reach
it only because inbound on `tailscale0` is permitted as a class (§8) and
Caddy listens on `${TS_IPV4}:80`. WebDAV's own port never leaves loopback.

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
6. New inbound TCP and UDP on the WAN interface to `${TORRENT_PUBLIC_PORT}`.

Dropped:

7. Every other new inbound connection arriving on the WAN interface.

Rules:

- The policy is applied through a staging chain and swapped in atomically,
  so there is no moment at which SSH is unreachable. At the **end** of a
  successful apply every leftover staging chain is removed together with its
  parent jump, including one left referenced by an interrupted earlier run
  (**DD-95**).
- Boot exposes a measured ~850 ms window between the WAN address becoming
  usable and the policy landing; sshd, which the policy allows anyway, is the
  only WAN listener in it and Docker starts later, behind the policy. Rules
  are not persisted to disk (**DD-66**), so this window is accepted, not
  closed (**DD-95**).
- Ordering guarantees that rule 2 precedes rule 7.
- The WAN interface is the **live default route at apply time**, not the
  `WAN_INTERFACE` recorded in `state.env`. A renamed NIC produces a warning
  and a correct policy; it no longer makes the unit fail with no policy at
  all (**DD-94**).
- There is **no** WAN permission for WebDAV, Caddy, dnsmasq, or any
  container web interface.
- IPv6 `INPUT` follows the same shape and is equally fail-closed. Tailscale
  IPv6 traffic is permitted; WAN IPv6 allows NDP/ICMPv6 essentials, host
  SSH TCP, and drops other NEW WAN traffic.

---

## 9. Docker firewall contract

**Chain names are fixed** (**DD-59**): `MASTER-INPUT` for the host policy,
`MASTER-DOCKER` for the container policy reached through `DOCKER-USER`.
`MASTER-DOCKER-FILTER` is not used. The same two logical names serve IPv4
and IPv6 — separate tables mean no collision — and both are declared in
`config/defaults.env` and nowhere else.

- The installer creates **only its own chain** (`MASTER-DOCKER`) and inserts **one
  idempotent jump** to it at the top of `DOCKER-USER`.
- Docker's own chains (`DOCKER`, `DOCKER-FORWARD`, `DOCKER-ISOLATION-*`,
  `ts-forward`) are **never** flushed, deleted or reordered.
- **Third-party rules already present in `DOCKER-USER` are never deleted.**
  the installer adds its jump and leaves everything else in place. The retired installer's
  `activate_staging_chain` deleted every other `DOCKER-USER` rule; that
  behaviour is gone, and its absence is a tested property.
- Inside `MASTER-DOCKER`:
  - `ESTABLISHED,RELATED` returns early.
  - Container traffic arriving over `tailscale0` is accepted.
  - New WAN traffic to the public peer publications is accepted
    (qBittorrent TCP+UDP `${TORRENT_PUBLIC_PORT}`; WireGuard is a host
    listener admitted by `MASTER-INPUT`, **DD-120**).
- WireGuard (**DD-120**), all interface-based and in both families:
  - `MASTER-INPUT` accepts from `wg0` only TCP to `10.8.0.1` on the three UI
    ports and ping (IPv4), and drops everything else from `wg0`.
  - `MASTER-FORWARD`, jumped at the top of `FORWARD`, accepts `wg0` → WAN
    and its replies and drops all other traffic to or from `wg0` (tailnet,
    Docker networks, other peers).
  - `MASTER-NAT`, in `nat POSTROUTING`, masquerades the WireGuard subnets out
    of the WAN.
  - wg-quick carries no `PostUp`: every rule belongs to `master-firewall`.
  - Every other WAN → container flow is dropped.
- IPv6 policy is explicit and fail-closed with the same shape. If the host
  has no IPv6 WAN route, the rule set reduces accordingly rather than
  silently permitting.
- The helper refuses to run if `ip6tables` is unavailable while IPv6
  forwarding is enabled, rather than degrading to an IPv4-only policy.
- The policy lives only in memory; `master-firewall.service` re-applies it
  after boot and after a Docker restart (`PartOf=docker.service` and
  `docker.service.d` `ExecStartPost=… --no-block restart master-firewall`).
- `master-firewall --check` verifies **shape and cardinality, not just
  presence**: in `MASTER-INPUT` and `MASTER-DOCKER` there must be exactly one
  WAN DROP, it must follow every WAN allow, no unconditional
  `ACCEPT`/`RETURN` may precede it (**DD-94**), and the number of WAN allows
  must equal the allow list exactly — 5 for INPUT v4, 2 for INPUT v6, 3 for
  DOCKER v4, 0 for DOCKER v6. Any extra WAN pass, whether a blanket
  `-i eth0 -j ACCEPT` or one more port, fails the check (**DD-95**).

---

## 10. systemd lifecycle

| Unit | After | Coupling | Restart |
|---|---|---|---|
| `tailscale-udp-gro.service` | `network-online.target` | none | `no`, oneshot, `RemainAfterExit` |
| `master-firewall.service` | `network-online.target tailscaled.service` (**not** `docker.service`) | `PartOf=docker.service` + `PartOf=tailscaled.service`; also restarted from `docker.service.d` | `on-failure` (oneshot, `RemainAfterExit`, `RestartSec=10s`, `StartLimitBurst=12` / 300s) |
| `refresh-tailnet-config.timer` | — | address poll + firewall watchdog | starts oneshot every 5 min (`OnBootSec=2min`) |
| `caddy.service` (drop-in) | `tailscaled.service` | After only (no `PartOf`); `OnFailure=refresh-tailnet-config.service` (**DD-87**) | `on-failure` + StartLimit (drop-in) |
| `dnsmasq.service` (drop-in) | `tailscaled.service` | none | package default |
| Compose `webdav` | Docker / Compose | loopback publish | `unless-stopped` |

The Caddy drop-in also carries
`EnvironmentFile=/etc/master-stack/state.env`, which is how
`{$TAILSCALE_IPV4}` in the Caddyfile is resolved at daemon start. There is
no separately rendered environment file (**DD-61**), so `state.env` must be
written in a form both bash and systemd can parse: plain `KEY=value`,
unquoted, no spaces around `=`. `ExecStartPre=wait-tailnet-addr` requires
that address on `tailscale0` (**DD-85**).

Invariants:

- **Restarting `tailscaled` re-applies the firewall
  (`master-firewall` is `PartOf=tailscaled.service`) and leaves Compose
  running.** Caddy is restarted when `refresh-tailnet-config` sees an
  address change, when Caddy fails and `OnFailure=` starts that oneshot
  (**DD-87**), or when the operator restarts it. WebDAV is a container and
  is not tied to `tailscaled`.
- **Restarting `docker` re-applies the firewall policy and restarts
  containers (including WebDAV).** The `docker.service.d` drop-in forces
  `systemctl restart master-firewall` on Docker start so an earlier
  INPUT-only apply cannot remain "active" without `MASTER-DOCKER`. It does
  not touch Caddy or dnsmasq.
- **The firewall unit does not order itself after Docker.** Host `INPUT`
  must land as early as possible, so `After=`/`Wants=`/`WantedBy=` no longer
  name `docker.service`; `MASTER-DOCKER` arrives with the drop-in restart
  once `DOCKER-USER` exists (**DD-94**). `PartOf=docker.service` stays as a
  second trigger, and the installer removes the retired
  `docker.service.wants/master-firewall.service` symlink on upgrade.
- **One bounded watchdog, at the network edge only.**
  `refresh-tailnet-config` — which already runs every 5 minutes — restarts
  `master-firewall` when the unit is `failed` or `--check` fails, after a
  `reset-failed` so an exhausted start limit cannot block the recovery. It
  skips the round while the oneshot is mid-apply. It inspects the firewall
  unit and nothing else: no container, file, or image is reconciled
  (**DD-94**).
- **No general-purpose repair engine.** The only `OnFailure=` in the stack
  is Caddy → `refresh-tailnet-config` (same oneshot the timer /
  `WantedBy=tailscaled` already use). There is no reconcile loop that
  reverts files or restarts arbitrary units.
- Containers come back after a reboot through the Compose restart policy.

---

## 11. Idempotency expectations

**R20**: a second run against an already-provisioned host must be safe.

- Every managed file is rendered from a template and written through a
  temporary file plus atomic rename, with explicit owner and mode.
- Re-running must not change a single byte of any generated file when the
  inputs are unchanged. This is verifiable: `sha256sum` the generated set
  before and after a second run.
- Existing state that must survive a re-run: the WebDAV credential file,
  the container volumes, qBittorrent's `/config` apart from the managed keys,
  every `wgN.conf` and `clients-wgN/` with the networks registry (the installer
  reads them, writes none — **DD-143**), the operator's chosen local domain.
- Firewall application is idempotent by construction: the chain is rebuilt
  from scratch and swapped in, and the `DOCKER-USER` jump is inserted only
  when absent.
- Directory creation is conditional; ownership/mode repair under downloads
  is selective (mismatched UID/GID/mode only — **DD-84**), not a full-tree
  rewrite and not limited to newly created directories.
- No step is unconditionally expensive: package installation, image pulls
  and daemon restarts happen only when something actually changed.
- The one operator-driven exception: on a re-run (`state.env` already
  exists), the installer asks whether to refresh container images
  (`docker compose pull`, default **hayır**; `V2_PULL_IMAGES=1` answers
  non-interactively). Declining leaves this step a no-op, matching the
  rule above; accepting is an explicit, single-run opt-in, not a
  standing policy — see **DD-99**. Accepting also runs a host-wide
  `docker image prune -f` after containers are recreated, reclaiming the
  now-dangling old image layers; a prune failure is logged and does not
  fail the run. The pull refuses to start when the filesystem holding
  `/var/lib/docker` has less than `PULL_MIN_FREE_GB` free — fail-closed,
  before any bytes are fetched (**DD-101**).

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
| WebDAV credential setup fails | No service is started with a missing or empty credential file |
| Compose validation fails | No containers are started |
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
   `REFUSED` for everything outside `${LOCAL_DOMAIN}`.
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

5. `docker port` shows public publications for qBittorrent TCP+UDP
   `${TORRENT_PUBLIC_PORT}` (IPv4 `0.0.0.0` 1:1 publish; not a specific WAN
   IP; no `[::]` peer publish). `wg show wg0 listen-port` is
   `${WG_PUBLIC_PORT}`, `10.8.0.1` is on `wg0`, `master-wg version` runs, and
   `caddy-wg` answers non-5xx on its three ports (**DD-120**, **DD-124**).
6. No container web interface is published on a non-loopback address.
7. The five container web interfaces (incl. WebDAV) listen on `127.0.0.1`
   only.
8. Caddy listens on `${TS_IPV4}:80` and `${TS_IPV4}:${WEBDAV_PORT}` (Infuse)
   and on no other address.
9. dnsmasq answers on `${TS_IPV4}:53` **and** `127.0.0.1:53`, and on no
   other address; it serves no DHCP.

### DNS and Caddy

10. All five names resolve to `${TS_IPV4}` when queried against
    `${TS_IPV4}`.
11. A query for an out-of-domain name against `${TS_IPV4}` returns
    `REFUSED`.
12. `curl -H "Host: health.${LOCAL_DOMAIN}" http://${TS_IPV4}/` returns
    `ok`.
13. Each of `dozzle`, `torrent` and `file` returns a non-5xx status
    through Caddy (`Host:` + `${TS_IPV4}`). Without a login, Dozzle's
    `/api/events/stream` answers `401` and qBittorrent's
    `/api/v2/app/version` answers `403`. A `200` there means a localhost or
    subnet authentication bypass is on (**DD-127**). A login with the input
    account succeeds (**DD-129**).
14. `docker port webdav` shows only `127.0.0.1:${WEBDAV_PORT}`; nothing
    listens on `${TS_IPV4}:${WEBDAV_PORT}` in Docker (Caddy owns that
    socket), nor on `0.0.0.0`, WAN, or LAN.
15. An unauthenticated request to loopback, via Caddy (`webdav.*`), and to
    `${TS_IPV4}:${WEBDAV_PORT}` returns `401`.
16. A `PROPFIND` with valid credentials succeeds through Caddy on both
    Infuse paths.
17. `/downloads/media`, `…/movies` and `…/series` are listable.
18. Install-time: running container has Cmd `--read-only`,
    `ReadonlyRootfs=true`, and `/downloads` mount `RW=false` (**DD-81**).
    Authenticated write refusal remains a live/manual check.
19. Infuse paths: `http://webdav.${LOCAL_DOMAIN}` (MagicDNS) and
    `http://${TS_IPV4}:${WEBDAV_PORT}/` (Apple TV — **DD-98**).

### WebDAV credential handling (§6.2, §6.4)

20. `/etc/master-stack/webdav.htpasswd` is `root:root` and at most `0600`.
21. Neither the password nor the username appears in `config.env`,
    `state.env`, Compose YAML, or any systemd unit.
22. Container process args show the htpasswd *path* only — no password and
    no username; container environ shows no password.
23. The installer never creates a host `master-webdav.service`,
    `webdav.env`, or a host `rclone` package. It does not remove one left by
    an older revision either (**DD-96**).

### Firewall

24. `MASTER-INPUT` accepts loopback, `ESTABLISHED,RELATED`, all
    `tailscale0` inbound, WAN TCP `${SSH_PUBLIC_PORT}` (host SSH), WAN
    UDP `${WG_PUBLIC_PORT}`, and WAN TCP+UDP `${TORRENT_PUBLIC_PORT}`; it
    drops other new WAN inbound.
25. `DOCKER-USER` contains exactly one jump to `MASTER-DOCKER`, as its
    first rule.
26. A third-party rule planted in `DOCKER-USER` before the run is still
    present after it.
27. Docker's own chains are unchanged in name, count and order.
28. `MASTER-DOCKER` permits NEW WAN TCP and UDP to `${TORRENT_PUBLIC_PORT}`
    and NEW WAN UDP to `${WG_PUBLIC_PORT}`.
29. The active SSH session survives policy application.

### Lifecycle

30. `systemctl restart tailscaled` leaves all six containers running.
31. `systemctl restart docker` results in a re-applied firewall policy.
32. After a full reboot: six containers running, all six names resolving,
    public wg UDP + torrent peer TCP/UDP published, WebDAV answering `401` via
    Caddy.
33. `systemctl --failed` is empty.

### Idempotency

34. A second complete run changes no byte of any generated file, starts no
    container it did not need to, and preserves the WebDAV credential.
