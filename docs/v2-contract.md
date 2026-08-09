# v2 Behaviour Contract

**Status:** behaviour contract (frozen intent 2026-08-05). Implemented by the
lean tree under `v2/` (`install.sh` and helpers). Where live code and this
document diverge, prefer the code and update this file.

This document is the authoritative statement of what the v2 installer does
and — just as importantly — what it deliberately refuses to do. Removals
relative to the retired monolith (no reconcile engine, no
canonical-bundle machinery, no host WebDAV unit) are decisions, not
oversights. The repository is v2-only; there is no parallel v1 tree.

**Relationship to `v2/.cursor/rules/`:** those rules are scoped to the `v2/`
tree and govern *how* the work is done — process, Bash conventions, the
per-phase verification set, and the hard prohibitions (do not delete Docker's
chains, do not silently turn the UDP-only decision into TCP+UDP, do not grow
a general-purpose reconcile engine). This document governs *what the result
must do*. Where the rules are silent (for example on WebDAV), this contract
extends them. Settled disagreements with early rule drafts — dnsmasq
listening scope, chain name, refresh helper scope, Portainer upstream
scheme — are recorded as **DD-59** through **DD-62** in
`design-decisions.md`.

The single active rule source is `v2/.cursor/rules/master-stack.mdc`. The
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
| R10 | Generate a Compose file for Portainer, wg-easy, qBittorrent, FileBrowser (classic), Unpackerr and loopback WebDAV (rclone) |
| R11 | Publish every web interface on `127.0.0.1` only |
| R12 | Publish publicly the wg-easy UDP port and the qBittorrent peer port (TCP+UDP) |
| R13 | Ask the operator for a local domain at the start of the installation |
| R14 | Resolve the defined service names to the Tailscale IPv4 with dnsmasq |
| R15 | Have Caddy listen on the Tailscale IPv4 only, over HTTP |
| R16 | Reverse-proxy the service names to the loopback interfaces through Caddy |
| R17 | Tell the operator to configure Custom DNS and Restrict-to-domain manually in the Tailscale admin panel |
| R18 | Create persistent firewall rules that permit Tailscale traffic, the public peer ports (wg UDP + qBit TCP+UDP), and WAN host SSH TCP `${SSH_PUBLIC_PORT}` |
| R19 | Filter Docker ports through `DOCKER-USER` |
| R20 | Keep the installation re-runnable |

---

## 1. Features v2 includes

### 1.1 Base system

- Debian 13 (trixie) hard gate; the installer refuses any other OS or
  release (**R1**).
- `apt-get update` + `full-upgrade`, then the package set the stack needs
  (**R1**, **R2**). `apache2-utils` stays for `htpasswd`; rclone runs only
  as the Compose image (see §5, **DD-77**). No host `rclone` or `acl`
  package.
- Timezone set to the configured value.
- Root-only, interactive, single-host, `flock`-serialised, wrapped in
  `systemd-inhibit` so a shutdown cannot land mid-transaction.

### 1.2 Tailscale

- Official Tailscale repository and package (**R3**).
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

- Docker Engine, CLI, containerd, buildx and the Compose plugin (**R9**).
- One Compose file with exactly six services: `portainer`, `filebrowser`,
  `qbittorrent`, `unpackerr`, `wg-easy`, `webdav` (**R10**, **DD-77**).
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
  (no full-tree rewrite). qBittorrent, FileBrowser and Unpackerr share
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

- A host `INPUT` policy (new in v2 — v1 had none) and a Docker forwarding
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
- Portainer, wg-easy and FileBrowser admin-account warnings are printed.

---

## 2. Features v2 deliberately excludes

Each entry names the v1 mechanism, its cost, and why it is gone.

| Excluded | v1 cost | Why it is not in v2 |
|---|---|---|
| **Canonical generation directory, `SHA256SUMS` manifest, `current` pointer** | ~400 lines, 3 bats suites, 6 DD entries | Served no requirement. The correct way to repair a drifted managed file is to re-run the installer (**R20**), not to have a timer silently revert it. |
| **Automatic file restore from a canonical copy** | ~90 lines of restore blocks | Same. An operator edit is now an operator's decision; v2 never silently reverts it. |
| **The 1821-line `master-network-reconcile`** | 33% of the file | Replaced by `refresh-tailnet-config`, which does one thing: react to a Tailscale address change. |
| **General container self-healing** | `probe_compose_runtime` + 12 probes + restart engine | Compose's own restart policy handles crashes. A health probe that restarts containers turns every upstream image change into a restart loop. |
| **Restart cooldown stamp files** | ~120 lines, `/run` stamps, 4 duplicated constants | systemd already rate-limits with `StartLimitIntervalSec`/`StartLimitBurst`. A second, parallel accounting system that then exempts itself is not a safety net. |
| **Image-digest-based recovery** | digest recording + final cross-check | Digests are still *recorded* for identification; nothing acts on a mismatch. |
| **Disk and inode threshold checks** | ~40 lines | Reports without repairing — that is monitoring, not installation. |
| **Default-password auditing of FileBrowser** | ~50 lines, a daily login attempt against the container | The end-of-install warning conveys the same information without a recurring authentication attempt. |
| **`master-compose.service`** | 24-line unit + ~45 dependency assertions | Not in the first v2 release. Compose restart policy covers reboot; nothing else needed a unit. |
| **`master-compose` coupled to `tailscaled` via `Requires`/`PartOf`** | — | No container binds to the Tailscale address, so the coupling only meant that restarting `tailscaled` bounced the entire stack. **A Tailscale restart must not restart the Compose stack.** |
| **Host `master-webdav.service` / `webdav.env` / distro `rclone`** | unit + ACL user + apt | Replaced by Compose `webdav` on loopback (**DD-77**). Re-runs call `purge_host_webdav_leftovers` (**DD-79**): unit/sbin/env, `master-webdav` user/group, downloads ACL, `apt-get purge rclone`. |
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
| wg-easy (WireGuard) | `0.0.0.0` (IPv4-only; firewall scopes WAN) | `${WG_PUBLIC_PORT}` (61001) | **UDP only** |
| qBittorrent (peer) | `0.0.0.0` (IPv4-only; firewall scopes WAN) | `${QBIT_PUBLIC_PORT}` (61005) | **TCP + UDP** |

**Host SSH is a separate MASTER-INPUT exception:** inbound TCP
`${SSH_PUBLIC_PORT}` (default 22) on the WAN interface is accepted so
console recovery and public-IP SSH keep working; it is not a Docker
publish and does not appear in `docker port`.

Public peer ports are IPv4-only host binds (`0.0.0.0:port:port/...`), not
dual-stack unqualified publishes and not a specific WAN IP. Firewall
limits NEW WAN traffic to wg UDP, qBit TCP+UDP, and SSH.
(R12 revised 2026-08-06: qBit peer TCP restored to match legacy
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
| Portainer | `127.0.0.1` | 9443 (HTTPS — **DD-62**) |
| FileBrowser (classic) | `127.0.0.1` | 61007 |
| qBittorrent WebUI | `127.0.0.1` | 61006 |
| wg-easy WebUI | `127.0.0.1` | 51821 |
| WebDAV (Compose rclone) | `127.0.0.1` | `${WEBDAV_PORT}` (61003) |

Reached from the tailnet only through Caddy (**R11**, **R16**, **DD-77**).
WebDAV is not bound on `${TS_IPV4}` and has no WAN publish.

### 3.4 Single source of truth

Every number above is declared exactly once, in `v2/config/defaults.env`,
and reaches the Compose file, the Caddyfile, the firewall script and the
state file by substitution. A port literal appearing twice in v2 is a bug.

---

## 4. DNS and Caddy service map

`${LOCAL_DOMAIN}` is asked at the start of the installation (**R13**) and
defaults to the value recorded in `state.env` on a re-run.

| Name | dnsmasq answer | Caddy site | Upstream |
|---|---|---|---|
| `portainer.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://portainer.…` | `https://127.0.0.1:9443` (**DD-62**, skip-verify on loopback) |
| `wg.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://wg.…` | `127.0.0.1:51821` |
| `qbit.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://qbit.…` | `127.0.0.1:61006` |
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
- **Portainer is the only HTTPS upstream** (**DD-62**): Caddy proxies
  `https://127.0.0.1:9443` with loopback-only `tls_insecure_skip_verify`.
  Other upstreams stay plain HTTP on loopback. Compose publishes
  `127.0.0.1:9443:9443` and does not pass `--http-enabled`.
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
on loopback, Caddy is the Infuse path, and Docker down means WebDAV down —
same dependency as the media producers.

---

## 6. WebDAV authentication and read-only contract

### 6.1 Credentials

- The installer asks for a WebDAV **username** and **password** at the start.
- The password is read with echo disabled, asked **twice**, and the two
  entries must match.
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
   `config.env`, not `state.env`, not `v2/config/defaults.env`. The
   forbidden keys are named explicitly in `defaults.env`:
   `WEBDAV_PASSWORD`, `WEBDAV_PASSWORD_HASH`, `WEBDAV_USER_PASSWORD`.
   There is no `webdav.env`.
7. **The password does not appear on a command line.** The server is
   pointed at a file path, so `ps` / `docker inspect` args contain no
   secret.
8. **The password is not written to logs.** The prompt reads with echo
   disabled, the hashing tool takes it on stdin, and no log statement
   echoes the variable.
9. **The username is managed with the credential, not with the
   configuration.** The htpasswd format already stores `user:hash`, so
   recording the name separately would create a second source of truth
   that can drift from the hash. `WEBDAV_USER` therefore does not exist in
   any of the configuration files either.
10. **On a re-run, an existing valid credential file is preserved.** The
    operator resets it by deleting the file and re-running, and the
    installer says so. A host `master-webdav` unit / `webdav.env` left from
    an older revision is disabled and removed.

### 6.3 Where each piece lives

| Item | Location | Mode | Secret |
|---|---|---|---|
| Username + password hash | `/etc/master-stack/webdav.htpasswd` | `0600` | **yes** |
| Port (loopback publish) | `v2/config/defaults.env` → Compose + Caddy | — | no |
| Credential file **path** | `v2/config/defaults.env`, Compose volume | — | no |
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
| Tailscale coupling | **none** | WebDAV does not bind `${TS_IPV4}` |
| Restart | Compose `unless-stopped` | No custom cooldown stamp system |

### 7.3 Reacting to a Tailscale address change

WebDAV does not bind the Tailscale address. When the Tailscale IPv4
changes, `refresh-tailnet-config` updates `state.env` and restarts **only
Caddy**:

```
Tailscale IPv4 change
  → state.env updated (atomically)
  → caddy          restarted
  → WebDAV         untouched (loopback)
  → dnsmasq        untouched
  → firewall       untouched
  → Compose stack  untouched
```

The same oneshot also acts as the firewall watchdog (§10), but that path is
independent of the address change: on an address change the firewall is not
touched.

**DD-61** originally named Caddy + host WebDAV; **DD-77** narrows the
restart set to Caddy alone. dnsmasq and the firewall still match the
interface name rather than an address.

`master-firewall` may still be `PartOf=tailscaled.service` so policy is
re-applied on Tailscale restart; that must never bounce Compose.

### 7.4 Access path decision

| Path | Address | Purpose |
|---|---|---|
| Preferred (MagicDNS) | `http://webdav.${LOCAL_DOMAIN}` | Phone Infuse / clients with MagicDNS |
| Apple TV Infuse (no MagicDNS) | `http://${TS_IPV4}/` (port 80) | Caddy site alias; Host = Tailscale IPv4 (**DD-78**) |
| Loopback (host-local) | `http://127.0.0.1:${WEBDAV_PORT}` | Installer / debug probes |

Caddy proxies both `webdav.${LOCAL_DOMAIN}` and `http://{$TAILSCALE_IPV4}`
to `127.0.0.1:${WEBDAV_PORT}`. Compose stays loopback-only and never names
the Tailscale address (**DD-77**).

**Direct `http://${TS_IPV4}:${WEBDAV_PORT}` is not supported** — nothing
listens there. Bare-IP access is only via Caddy on port 80.

No TLS between Caddy and WebDAV: both endpoints are on the same host, and
the hop is loopback.

### 7.5 Firewall consequence

**No WAN firewall permission is created for WebDAV.** Tailnet clients reach
it only because inbound on `tailscale0` is permitted as a class (§8) and
Caddy listens on `${TS_IPV4}:80`. WebDAV's own port never leaves loopback.

---

## 8. Host firewall contract (`INPUT`)

New in v2. v1 filtered only Docker's forwarded traffic and left host
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
6. New inbound TCP and UDP on the WAN interface to `${QBIT_PUBLIC_PORT}`.

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
`v2/config/defaults.env` and nowhere else.

- v2 creates **only its own chain** (`MASTER-DOCKER`) and inserts **one
  idempotent jump** to it at the top of `DOCKER-USER`.
- Docker's own chains (`DOCKER`, `DOCKER-FORWARD`, `DOCKER-ISOLATION-*`,
  `ts-forward`) are **never** flushed, deleted or reordered.
- **Third-party rules already present in `DOCKER-USER` are never deleted.**
  v2 adds its jump and leaves everything else in place. v1's
  `activate_staging_chain` deleted every other `DOCKER-USER` rule; that
  behaviour is gone, and its absence is a tested property.
- Inside `MASTER-DOCKER`:
  - `ESTABLISHED,RELATED` returns early.
  - Container traffic arriving over `tailscale0` is accepted.
  - New WAN traffic to the public peer publications is accepted
    (wg-easy UDP `${WG_PUBLIC_PORT}`; qBittorrent TCP+UDP
    `${QBIT_PUBLIC_PORT}`).
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
  the container volumes, the qBittorrent configuration, the wg-easy
  configuration, the operator's chosen local domain (offered as the
  default).
- Firewall application is idempotent by construction: the chain is rebuilt
  from scratch and swapped in, and the `DOCKER-USER` jump is inserted only
  when absent.
- Directory creation is conditional; ownership/mode repair under downloads
  is selective (mismatched UID/GID/mode only — **DD-84**), not a full-tree
  rewrite and not limited to newly created directories.
- No step is unconditionally expensive: package installation, image pulls
  and daemon restarts happen only when something actually changed.

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

A v2 run is successful when every one of these holds on the target host.

### Base and Tailscale

1. `tailscale status --json` reports `BackendState=Running` and
   `Self.Online=true`.
2. `tailscale debug prefs` shows exit-node advertisement for `0.0.0.0/0`
   and `::/0`, `RunSSH=true`, stateful filtering on, netfilter mode 2.
3. `net.ipv4.ip_forward` and `net.ipv6.conf.all.forwarding` are `1`.
4. `state.env` contains a valid `TAILSCALE_IPV4` **and** `TAILSCALE_IPV6`.

### Ports

5. `docker port` shows public publications for wg-easy UDP
   `${WG_PUBLIC_PORT}` and qBittorrent TCP+UDP `${QBIT_PUBLIC_PORT}`
   (IPv4 `0.0.0.0` 1:1 publish; not a specific WAN IP; no `[::]` peer
   publish).
6. No container web interface is published on a non-loopback address.
7. The four container web interfaces listen on `127.0.0.1` only.
8. Caddy listens on `${TS_IPV4}:80` and on no other address.
9. dnsmasq answers on `${TS_IPV4}:53` **and** `127.0.0.1:53`, and on no
   other address; it serves no DHCP.

### DNS and Caddy

10. All six names resolve to `${TS_IPV4}` when queried against
    `${TS_IPV4}`.
11. A query for an out-of-domain name against `${TS_IPV4}` returns
    `REFUSED`.
12. `curl -H "Host: health.${LOCAL_DOMAIN}" http://${TS_IPV4}/` returns
    `ok`.
13. Each of `portainer`, `wg`, `qbit` and `file` returns a non-5xx status
    through Caddy (`Host:` + `${TS_IPV4}`).
14. `docker port webdav` shows only `127.0.0.1:${WEBDAV_PORT}`; nothing
    listens on `${TS_IPV4}:${WEBDAV_PORT}`, `0.0.0.0`, WAN, or LAN.
15. An unauthenticated request to loopback and via Caddy returns `401`.
16. A `PROPFIND` with valid credentials succeeds through Caddy.
17. `/downloads/media`, `…/movies` and `…/series` are listable.
18. Install-time: running container has Cmd `--read-only`,
    `ReadonlyRootfs=true`, and `/downloads` mount `RW=false` (**DD-81**).
    Authenticated write refusal remains a live/manual check.
19. Infuse paths: `http://webdav.${LOCAL_DOMAIN}` (MagicDNS) and
    `http://${TS_IPV4}/` on port 80 (Apple TV / no MagicDNS — **DD-78**).

### WebDAV credential handling (§6.2, §6.4)

20. `/etc/master-stack/webdav.htpasswd` is `root:root` and at most `0600`.
21. Neither the password nor the username appears in `config.env`,
    `state.env`, Compose YAML, or any systemd unit.
22. Container process args show the htpasswd *path* only — no password and
    no username; container environ shows no password.
23. No host `master-webdav.service` / `webdav.env` / host `rclone` package
    remains after install.

### Firewall

24. `MASTER-INPUT` accepts loopback, `ESTABLISHED,RELATED`, all
    `tailscale0` inbound, WAN TCP `${SSH_PUBLIC_PORT}` (host SSH), WAN
    UDP `${WG_PUBLIC_PORT}`, and WAN TCP+UDP `${QBIT_PUBLIC_PORT}`; it
    drops other new WAN inbound.
25. `DOCKER-USER` contains exactly one jump to `MASTER-DOCKER`, as its
    first rule.
26. A third-party rule planted in `DOCKER-USER` before the run is still
    present after it.
27. Docker's own chains are unchanged in name, count and order.
28. `MASTER-DOCKER` permits NEW WAN TCP and UDP to `${QBIT_PUBLIC_PORT}`
    and NEW WAN UDP to `${WG_PUBLIC_PORT}`.
29. The active SSH session survives policy application.

### Lifecycle

30. `systemctl restart tailscaled` leaves all six containers running.
31. `systemctl restart docker` results in a re-applied firewall policy.
32. After a full reboot: six containers running, all six names resolving,
    public wg UDP + qBit TCP/UDP published, WebDAV answering `401` via
    Caddy.
33. `systemctl --failed` is empty.

### Idempotency

34. A second complete run changes no byte of any generated file, starts no
    container it did not need to, and preserves the WebDAV credential.
