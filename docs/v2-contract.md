# v2 Behaviour Contract

**Status:** design contract, frozen 2026-08-05. No v2 code implements it yet;
`v2/` currently holds a non-executable skeleton.

This document is the authoritative statement of what the v2 installer does
and — just as importantly — what it deliberately refuses to do. It exists
because v1 (`legacy/install.sh`, 5495 lines) grew a large self-healing layer
that no functional requirement ever asked for. Every removal below is a
decision, not an oversight.

**Relationship to v1:** `install.sh` at the repository root remains the
running production installer until v2 reaches parity and is verified on a
real host. `legacy/install.sh` is its frozen, byte-identical reference copy
(`sha256 547a9132…`). v2 is developed beside them, never on top of them.

**Relationship to `v2/.cursor/rules/`:** those rules are scoped to the `v2/`
tree and govern *how* the work is done — process, Bash conventions, the
per-phase verification set, and the hard prohibitions (do not delete Docker's
chains, do not silently turn the UDP-only decision into TCP+UDP, do not grow
a general-purpose reconcile engine). This document governs *what the result
must do*. The rules file predates the WebDAV decisions and does not mention
WebDAV; where it is silent this contract extends it. The four places where
the two genuinely disagreed — the dnsmasq listening scope, the chain name,
the refresh helper's scope, and Portainer's upstream scheme — were settled
on 2026-08-05 and are recorded as **DD-59** through **DD-62** in
`design-decisions.md`; this document states the resolved position
throughout. The rules must not be applied to `legacy/install.sh`.

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
| R10 | Generate a Compose file for Portainer, wg-easy, qBittorrent, FileBrowser Quantum and Unpackerr |
| R11 | Publish every web interface on `127.0.0.1` only |
| R12 | Publish publicly the wg-easy UDP port and the qBittorrent peer port (TCP+UDP) |
| R13 | Ask the operator for a local domain at the start of the installation |
| R14 | Resolve the defined service names to the Tailscale IPv4 with dnsmasq |
| R15 | Have Caddy listen on the Tailscale IPv4 only, over HTTP |
| R16 | Reverse-proxy the service names to the loopback interfaces through Caddy |
| R17 | Tell the operator to configure Custom DNS and Restrict-to-domain manually in the Tailscale admin panel |
| R18 | Create persistent firewall rules that permit Tailscale traffic, the two public UDP ports, and WAN host SSH TCP `${SSH_PUBLIC_PORT}` |
| R19 | Filter Docker ports through `DOCKER-USER` |
| R20 | Keep the installation re-runnable |

---

## 1. Features v2 includes

### 1.1 Base system

- Debian 13 (trixie) hard gate; the installer refuses any other OS or
  release (**R1**).
- `apt-get update` + `full-upgrade`, then the package set the stack needs
  (**R1**, **R2**). `rclone` and `apache2-utils` stay in the set because
  WebDAV stays (see §5).
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
- One Compose file with exactly five services: `portainer`, `filebrowser`,
  `qbittorrent`, `unpackerr`, `wg-easy` (**R10**).
- Every web interface published on `127.0.0.1` only (**R11**).
- Containers survive a reboot through the Compose **restart policy**
  (`restart: unless-stopped`), not through a systemd unit. `master-compose.service`
  does not exist in the first v2 release.

### 1.4 Directories

- `/downloads`, `/downloads/media`, `/downloads/media/movies`,
  `/downloads/media/series` and the Unpackerr work directory are created
  when absent (**R8**).
- **No unconditional recursive `chown` over an existing media tree.**
  Ownership is set on directories the installer itself creates. An
  operator-visible warning is printed if existing content is owned such
  that the containers cannot use it; repairing it is an explicit,
  separately invoked action, never a side effect of a re-run.

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
  policy on boot and whenever Docker restarts, which is also how a changed
  public IPv4 reaches the rules.

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
| wg-easy (WireGuard) | host (all IFs; firewall scopes WAN) | `${WG_PUBLIC_PORT}` (65171) | **UDP only** |
| qBittorrent (peer) | host (all IFs; firewall scopes WAN) | `${QBIT_PUBLIC_PORT}` (65173) | **TCP + UDP** |

**Host SSH is a separate MASTER-INPUT exception:** inbound TCP
`${SSH_PUBLIC_PORT}` (default 22) on the WAN interface is accepted so
console recovery and public-IP SSH keep working; it is not a Docker
publish and does not appear in `docker port`.

Public ports are not bound to a WAN IP in Compose (1:1 host publish);
firewall limits NEW WAN traffic to wg UDP, qBit TCP+UDP, and SSH.
(R12 revised 2026-08-06: qBit peer TCP restored to match legacy
connectivity.)

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
| WebDAV (host rclone) | `${TS_IPV4}` | `${WEBDAV_PORT}` (65113) | TCP |

**The WebDAV port is not a Docker published port.** It belongs to a host
service and is reachable only inside the tailnet.

### 3.3 Loopback only

| Service | Listen address | Port |
|---|---|---|
| Portainer | `127.0.0.1` | 9443 (HTTPS — **DD-62**) |
| FileBrowser Quantum | `127.0.0.1` | 7113 |
| qBittorrent WebUI | `127.0.0.1` | 13087 |
| wg-easy WebUI | `127.0.0.1` | 51821 |

Reached from the tailnet only through Caddy (**R11**, **R16**).

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
| `qbit.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://qbit.…` | `127.0.0.1:13087` |
| `file.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://file.…` | `127.0.0.1:7113` |
| `webdav.${LOCAL_DOMAIN}` | `${TS_IPV4}` | `http://webdav.…` | `${TS_IPV4}:${WEBDAV_PORT}` (see §7.4) |
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
- **Acceptance test, not an assumption:** whether a query arriving over
  loopback answers `${TS_IPV4}` — rather than `127.0.0.1` or `NXDOMAIN` —
  must be measured on a clean Debian 13 target during the DNS phase.
  `dig +short webdav.${LOCAL_DOMAIN} @127.0.0.1` and the same query against
  `@${TS_IPV4}` must both return `${TS_IPV4}`. The loopback listener's value
  as a test path depends on this, and it has not yet been observed.
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
- The installer creates only the directories it needs. It does not run a
  recursive `chown` over an existing `/downloads` tree (see §1.4).

This is why WebDAV is a host service and not a container: it must bind to
the Tailscale address, which lives on the host, and it must survive Docker
restarts untouched.

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
3. **`master-webdav.service` receives the credential through systemd
   `LoadCredential=`.** The unit references a *path*; it never carries a
   value.
4. **`master-webdav-serve` reads the credential from
   `$CREDENTIALS_DIRECTORY`.** It therefore needs no read permission on
   `/etc/master-stack`, which is what lets the service run as an
   unprivileged user.
5. **The password is not present in the systemd unit content** — not as
   `Environment=`, not as an `ExecStart` argument, not in a drop-in.
6. **The password is not written to any environment file** — not
   `webdav.env`, not `config.env`, not `state.env`, not
   `v2/config/defaults.env`. The forbidden keys are named explicitly in
   `webdav.env.tmpl`: `WEBDAV_PASSWORD`, `WEBDAV_PASSWORD_HASH`,
   `WEBDAV_USER_PASSWORD`.
7. **The password does not appear on a command line.** The server is
   pointed at a file path, so `ps` output contains no secret.
8. **The password is not written to logs.** The prompt reads with echo
   disabled, the hashing tool takes it on stdin, and no log statement
   echoes the variable.
9. **The username is managed with the credential, not with the
   configuration.** The htpasswd format already stores `user:hash`, so
   recording the name separately would create a second source of truth
   that can drift from the hash. `WEBDAV_USER` therefore does not exist in
   any of the four configuration files either.
10. **On a re-run, an existing valid credential file is preserved.** The
    operator resets it by deleting the file and re-running, and the
    installer says so.

### 6.3 Where each piece lives

| Item | Location | Mode | Secret |
|---|---|---|---|
| Username + password hash | `/etc/master-stack/webdav.htpasswd` | `0600` | **yes** |
| Bind address override (normally empty) | `webdav.env` | `0644` | no |
| Port, served root, read-only flag, cache time, log level, realm | `webdav.env` | `0644` | no |
| Credential file **path** | `v2/config/defaults.env`, unit `LoadCredential=` | — | no |

The plaintext password exists only inside the installer process, for as
long as it takes to hash it.

### 6.4 To be verified at implementation time

**How rclone actually receives the credential must be confirmed by a
separate security test, not assumed.** The concern is specific: a server
that accepts an htpasswd file path is safe, but one that only accepts
`--user`/`--pass` would put the secret on the command line and defeat item
7 above. The test must assert, against a running service:

- `ps -eo args` for the service process contains no password and no
  username,
- the process environment (`/proc/<pid>/environ`) contains no password,
- the journal for the unit contains no password,
- the credential is readable by the service only through
  `$CREDENTIALS_DIRECTORY`.

If rclone turns out not to support a file-based credential in the required
form, that is a blocking finding and the transport must change — not the
contract.

### 6.5 Read-only enforcement

- The serve process runs with an explicit read-only flag.
- It serves only the `/downloads` root — no other host path is reachable
  through it.
- It runs as a dedicated unprivileged system user, not root.
- systemd sandboxing restricts the filesystem view so that the read-only
  guarantee does not rest on the application flag alone.
- A write attempt must be refused by the service. This is a tested
  behaviour, not an assumption.

---

## 7. WebDAV systemd lifecycle

### 7.1 Unit

One host unit: `master-webdav.service`.

### 7.2 Ordering and coupling

| Property | Value | Reason |
|---|---|---|
| `After=` | `network-online.target tailscaled.service` | The Tailscale address must exist before binding |
| Docker coupling | **none** | A Docker or Compose restart must not touch WebDAV |
| Compose coupling | **none** | `master-compose.service` does not exist in v2 |
| Start condition | current Tailscale IPv4 available | The unit does not start without an address to bind |
| `Restart=` | `on-failure`, with a bounded `RestartSec` and systemd's own start limit | No custom cooldown stamp system |

### 7.3 Reacting to a Tailscale address change

The address is resolved **at service start**, by the serve script, with a
bounded wait. It is never frozen into a rendered file at install time,
because a stale rendered address is worse than a short wait.

When the Tailscale IPv4 changes, `refresh-tailnet-config` — a small helper,
not a reconcile engine — updates `state.env` and restarts **only** the
services that bind to the address:

```
Tailscale IPv4 change
  → state.env updated (atomically)
  → caddy          restarted
  → master-webdav  restarted
  → dnsmasq        untouched
  → firewall       untouched
  → Compose stack  untouched
```

The exhaustive scope of that helper is **DD-61**. Three of those "untouched"
lines are the point of the design rather than an omission: dnsmasq follows
the interface through `bind-dynamic`, the firewall's Tailscale rules match
on the interface name rather than an address, and no container binds the
Tailscale address at all. If the address changes and nothing is running that
binds it, the helper exits successfully having done nothing.

If `PartOf=tailscaled.service` is used, it must be verified that its only
effect is on WebDAV (and Caddy) — never on the Compose stack. The
alternative, and the preferred one, is the refresh helper above: it
restarts WebDAV **only when the address actually changed**, rather than on
every `tailscaled` restart.

### 7.4 Access path decision

Two access paths are supported, deliberately:

| Path | Address | Purpose |
|---|---|---|
| Direct | `http://${TS_IPV4}:${WEBDAV_PORT}` | What the service actually binds; the fallback if Caddy is down |
| Preferred | `http://webdav.${LOCAL_DOMAIN}` | What the operator configures in Infuse |

Caddy proxies `webdav.${LOCAL_DOMAIN}` to `${TS_IPV4}:${WEBDAV_PORT}`.

**Security consequence of supporting both, stated explicitly:** the WebDAV
port is reachable from every device in the tailnet, not only through Caddy.
Both paths are inside the tailnet, both require the same authentication,
and neither is reachable from the WAN — so the exposure is identical; only
the number of listening sockets differs. The alternative (bind WebDAV to
`127.0.0.1` and let only Caddy reach it) removes one tailnet-reachable
socket, but it also removes the fallback path and makes Caddy a single
point of failure for the Apple TV. The direct path is kept for that reason.

No TLS is introduced between Caddy and WebDAV: both endpoints are on the
same host, and the hop is loopback-equivalent.

### 7.5 Firewall consequence

**No WAN firewall permission is created for WebDAV.** It works purely
because inbound traffic arriving on `tailscale0` is permitted as a class
(§8). If WebDAV does not listen on IPv6, there is no IPv6 exception for it
either.

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
  so there is no moment at which SSH is unreachable.
- Ordering guarantees that rule 2 precedes rule 7.
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
  - New WAN traffic to the two public UDP publications is accepted.
  - Every other WAN → container flow is dropped.
- IPv6 policy is explicit and fail-closed with the same shape. If the host
  has no IPv6 WAN route, the rule set reduces accordingly rather than
  silently permitting.
- The helper refuses to run if `ip6tables` is unavailable while IPv6
  forwarding is enabled, rather than degrading to an IPv4-only policy.
- The policy lives only in memory; `master-firewall.service` re-applies it
  after boot and after a Docker restart (`PartOf=docker.service`).

---

## 10. systemd lifecycle

| Unit | After | Coupling | Restart |
|---|---|---|---|
| `tailscale-udp-gro.service` | `network-online.target` | none | `no`, oneshot, `RemainAfterExit` |
| `master-firewall.service` | `docker.service tailscaled.service` | `PartOf=docker.service` | `no`, oneshot, `RemainAfterExit` |
| `master-webdav.service` | `tailscaled.service` | none to Docker/Compose | `on-failure`, bounded |
| `watch-tailnet-addr.service` | `tailscaled.service` | none | `always` (runs `ip monitor address`) |
| `refresh-tailnet-config.timer` | — | backup poll | starts oneshot every 5 min |
| `caddy.service` (drop-in) | `tailscaled.service` | `PartOf=tailscaled.service` | `on-failure` |
| `dnsmasq.service` (drop-in) | `tailscaled.service` | none | `on-failure` |

The Caddy drop-in also carries
`EnvironmentFile=/etc/master-stack/state.env`, which is how `{$TS_IPV4}` in
the Caddyfile is resolved at daemon start. There is no separately rendered
environment file (**DD-61**), so `state.env` must be written in a form both
bash and systemd can parse: plain `KEY=value`, unquoted, no spaces around
`=`.

Invariants:

- **Restarting `tailscaled` re-prepares Caddy and WebDAV, and nothing else.**
  The Compose stack keeps running.
- **Restarting `docker` re-applies the firewall policy.** It does not touch
  Caddy, dnsmasq or WebDAV.
- No unit carries `OnFailure=` pointing at a repair engine, because there is
  no repair engine. A failed unit stays failed and visible.
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
- Directory creation is conditional; ownership is applied to newly created
  directories only.
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
   (host 1:1 publish; not necessarily bound to a specific WAN IP).
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
13. Each of the four container sites returns a non-5xx status through
    Caddy.

### WebDAV

14. The service listens on `${TS_IPV4}:${WEBDAV_PORT}` and **not** on
    `0.0.0.0`, the WAN address, or any LAN address.
15. An unauthenticated request returns `401`.
16. A `PROPFIND` with valid credentials succeeds.
17. `/downloads/media`, `…/movies` and `…/series` are listable.
18. A write attempt (`PUT`/`MKCOL`/`DELETE`) is refused.
19. The same works through `http://webdav.${LOCAL_DOMAIN}`.

### WebDAV credential handling (§6.2, §6.4)

20. `/etc/master-stack/webdav.htpasswd` is `root:root` and at most `0600`.
21. Neither the password nor the username appears in `webdav.env`,
    `config.env`, `state.env`, or the unit file.
22. `ps -eo args` for the service process shows no password and no
    username; `/proc/<pid>/environ` shows no password; the unit's journal
    shows no password.
23. The service reads the credential only through
    `$CREDENTIALS_DIRECTORY`, and runs as an unprivileged user with no read
    access to `/etc/master-stack`.

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

30. `systemctl restart tailscaled` leaves all five containers running.
31. `systemctl restart docker` results in a re-applied firewall policy.
32. After a full reboot: five containers running, all six names resolving,
    public wg UDP + qBit TCP/UDP published, WebDAV answering `401`.
33. `systemctl --failed` is empty.

### Idempotency

34. A second complete run changes no byte of any generated file, starts no
    container it did not need to, and preserves the WebDAV credential.
