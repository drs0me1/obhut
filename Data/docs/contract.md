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
| R10 | Generate a Compose file for Dozzle (replaced Portainer, **DD-116**), Transmission (replaced qBittorrent, **DD-117**), FileBrowser (classic), Unpackerr and loopback WebDAV (rclone) |
| R11 | Publish every web interface on `127.0.0.1` only |
| R12 | Publish publicly the WireGuard UDP port (host kernel since v2-86, **DD-120**; formerly wg-easy) and the torrent (Transmission) peer port (TCP+UDP) |
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
  written files are byte-identical. A host with no recorded OS (v2-73 or
  earlier) is not treated as a release change. Architecture outside
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

### 1.2 Tailscale

- Official Tailscale repository and package (**R3**).
- The optional Tailscale auth key is `TS_AUTH_KEY` in the input file, and
  is ignored when the node is already online. With a key, stage 2 runs
  `tailscale up --auth-key=file:<root-only tmpfs file> --advertise-exit-node
  --ssh` and skips the browser step. The key is never written to
  `config.env`, `state.env`, the log or a command line. An empty value, or a
  key that is rejected or times out, uses the interactive login below
  (**DD-115**, **DD-119**).
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
- One Compose file with exactly five services: `dozzle`, `filebrowser`,
  `transmission`, `unpackerr`, `webdav` (**R10**, **DD-77**, **DD-116**,
  **DD-117**, **DD-120**).
- Transmission (LinuxServer image) takes its user name and password from
  root-only files under `/etc/master-stack/transmission-auth`, mounted
  read-only and read through `FILE__USER`/`FILE__PASS`; they never appear in
  `compose.yaml` or `docker inspect`. They come from the input file and are
  rewritten, with a Transmission restart, only when they differ from it
  (**DD-119**). On a fresh install it seeds
  `/etc/master-stack/transmission/settings.json` with the download layout
  (`/downloads`, partial files in `/downloads/incomplete`), port forwarding
  off and `rpc-port` 9091, which the image's clean-shutdown script requires,
  plus the operator's preferences: DHT, PeX and local peer discovery off and
  a download queue of 12 (**DD-118**); from then on the file belongs to
  Transmission. A leftover `qbittorrent`
  container stops the installer in stage 0 before any change, because it
  holds the peer port; the installer never removes it (**DD-96**, **DD-117**).
- Dozzle runs with `DOZZLE_AUTH_PROVIDER=simple` and actions enabled (start,
  stop, restart, remove, update), no shell, read-only root, all capabilities
  dropped and `no-new-privileges`. Its `users.yml` is written by the
  installer from the input file, using the image's own `generate` command
  with the password on stdin and the `actions` role. It is regenerated, with
  a Dozzle restart, only when it no longer holds exactly that account
  (**DD-119**).
  An old `portainer` container is never removed by the installer; stage 7
  warns while it is still running (**DD-96**, **DD-116**).
- FileBrowser's account comes from the input file (user name, and a
  password of at least `FILEBROWSER_MIN_PASSWORD_LENGTH`, 12, FileBrowser's
  own minimum). Before Compose starts, the installer builds the Bolt database
  in a temporary directory with the image's CLI in a network-less one-shot
  container — `config init` with the settings the image's first start would
  choose, then `users import` of an admin whose bcrypt hash `htpasswd` made
  from stdin — verifies it holds exactly that admin, and moves it into
  `/etc/master-stack/filebrowser-data`. The password never reaches argv, a log
  or a plaintext file, and no first-start random admin password is ever
  created (**DD-118**). An existing `filebrowser.db` is compared with the
  input file on a copy, so a running container is not touched. If the account
  differs, the container is stopped, `users import --overwrite` writes the
  name and hash into a fresh copy under the same id, and the verified copy is
  moved in before the container starts again. A password changed in
  FileBrowser's UI therefore returns to the file's value on the next run;
  other users are left alone (**DD-119**).
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
  (no full-tree rewrite). Transmission, FileBrowser and Unpackerr share
  read/write that way. WebDAV remains read-only via the Compose service
  (`:ro` mount + `--read-only`).

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

- `wg-quick@wg0` in the host kernel: `10.8.0.1/24` and
  `fdcc:ad94:bacf:61a4::cafe:1/112`, UDP `${WG_PUBLIC_PORT}`, MTU 1420.
- **The server is the source of truth.** `/etc/wireguard/wg0.conf` (`0600`)
  holds the server key and one `# peer: <name>` + `[Peer]` block per device.
  Nothing WireGuard-related is sent from the workstation.
- **The installer manages `[Interface]` only.** A first install generates the
  server key with `wg genkey`; later runs keep the key and every `[Peer]` block
  byte for byte. It installs `wireguard-tools` and `qrencode`
  (`--no-install-recommends`), `master-wg`, and writes no `PostUp`.
- **Peers are managed with `master-wg`** (`/usr/local/sbin`, root), driven from
  the workstation by `wireguard.command`:
  - `add NAME DNS KEEPALIVE MTU` runs `wg genkey`, `wg pubkey` and `wg genpsk`,
    takes the next free address (IPv4 from `.2`, IPv6 with the same host
    number in hex), stores the device profile in `/etc/wireguard/clients/`
    (`0600`) and appends the `[Peer]` block. It validates the name, DNS list,
    keepalive (0–65535) and MTU (1280–1500) before any change.
  - `remove NAME` deletes the block and the stored profile.
  - `list` prints name, address, last handshake, transfer and whether a
    profile is stored; `profile NAME` and `qr NAME` print the stored profile
    or its QR code.
  - It takes the installer's lock, so the two never write `wg0.conf` at once.
  - A failed apply restores the previous `wg0.conf` and removes a new profile.
- **Changes reach a running interface with `wg syncconf`** (no restart;
  connected devices stay up). `wg-quick@wg0` restarts only when it is not
  running, when `Address`/`MTU` changed, or when `syncconf` fails; an empty
  `wg-quick strip` output is never passed on (**DD-123**).
- **`wireguard.command`** (repository root, macOS) reads only `SSH_HOST` from
  `kurulum.env`. It refuses a server whose `master-wg version` differs from
  the repository's `V2_VERSION`. It asks for the name, DNS, keepalive and MTU
  (defaults from `defaults.env`), prints the QR code and saves the profile as
  `kurulum/wireguard/<name>.conf` (`600`). That folder is a copy for the
  operator; the installer never reads it.
- **A reinstall generates a new server key and starts with no peers**; devices
  are added again with `wireguard.command`.
- **What clients reach:** internet egress (IPv4 and IPv6, masqueraded) and the
  Dozzle, Transmission and FileBrowser UIs at `http://10.8.0.1:<port>`.
  Nothing else: not the tailnet, WebDAV, SSH, dnsmasq, Docker networks or
  other peers (§9).
- The UIs are served by `caddy-wg.service` (`/etc/caddy/Caddyfile.wg`, admin
  API off). It binds only `10.8.0.1`, follows `wg-quick@wg0` and has no
  Tailscale dependency, so the path survives a Tailscale outage.

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
| **Default-password auditing of FileBrowser** | ~50 lines, a daily login attempt against the container | Nothing to audit: since v2-84 the installer creates the account, since v2-85 from the input file, and no first-boot password exists (**DD-118**, **DD-119**). |
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
| Transmission (peer) | `0.0.0.0` (IPv4-only; firewall scopes WAN) | `${TORRENT_PUBLIC_PORT}` (61005) | **TCP + UDP** |

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
| FileBrowser (classic) | `127.0.0.1` | 61007 |
| Transmission WebUI | `127.0.0.1` | 61006 (**DD-117**) |
| WebDAV (Compose rclone) | `127.0.0.1` | `${WEBDAV_PORT}` (61003) |

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
| caddy-wg → Dozzle, Transmission, FileBrowser | `10.8.0.1` | 61002, 61006, 61007 (TCP, HTTP only) |

No names, no WebDAV, no dnsmasq on `wg0` (**DD-120**).

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
- The six names live in one list in the templates; adding a service means
  editing that one list.

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
    (Transmission TCP+UDP `${TORRENT_PUBLIC_PORT}`; WireGuard is a host
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
  the container volumes, the Transmission settings and credential files,
  `wg0.conf` (its key and every `[Peer]` block are kept; only `[Interface]`
  follows the installer), `/etc/wireguard/clients/`, the operator's chosen
  local domain.
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

5. `docker port` shows public publications for Transmission TCP+UDP
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
    through Caddy (`Host:` + `${TS_IPV4}`); Dozzle's `/api/events/stream`
    and Transmission's `/transmission/rpc` answer `401` without a login.
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
