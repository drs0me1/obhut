# Debian Server Installer

**Version: V1-11** (2026-07-31) — see [`CHANGELOG.md`](CHANGELOG.md) for
the full release history. The script reports itself as
`2026.07.31-V1-11` in its banner, log header and final summary; note this
is distinct from `STACK_SCHEMA`, which versions `state.env`'s on-disk
format and is currently `9`. The latest tagged release is `V1-1` (the
**M11** socket-buffer ordering fix, verified by a live install). Since
then, **unreleased and not yet live-verified**: `V1-2` added version/hash
self-reporting on the host plus `master-network-reconcile --status`, and
`V1-3` replaced the `sftpgo` container with `master-webdav.service`, a
hardened host `rclone serve webdav` unit — which also removed the last
Tailnet → Docker firewall exception (DD-20) — and `V1-4`/`V1-5` reworked the WebDAV
block in the final install summary. `V1-6` through `V1-8` were driven by
live installs (four bugs no static check caught), `V1-9`/`V1-10` moved the
reconcile timer to 20 minutes (DD-21), and `V1-11` stopped reconcile from
reporting failure after a successful repair on a host whose wg-easy web
setup is still pending. Both the `V1-10` install with its four-scenario
sweep and the `V1-11` fix on top of it are live-verified (2026-07-31).

## Project Overview

`install.sh` is a single, self-contained Bash script that turns a fresh
**Debian 13 (trixie)** host into a hardened **Tailscale exit-node** running a
fixed **Docker Compose** service bundle (VPN, file management, torrent
client, and optional Tailnet-only reverse proxy/DNS).

The script is designed to be run as root, interactively, on a dedicated
server. It is **idempotent by design**: it can be re-run safely against an
already-provisioned host to reconcile drift, pick up new image versions, or
recover from a partially failed prior run. Beyond the initial install, it
also writes a **20-minute self-healing reconcile timer** that continuously
verifies and repairs network addressing, firewall state, container health,
and (optionally) DNS/Caddy configuration for the lifetime of the server.

The script has seven sequential installation stages (0–7), root-only
structured logging with a live progress bar, layered rollback/cleanup traps,
and an extensive runtime verification pass at the end of the install.

## Features

- **OS guard**: refuses to run on anything other than Debian 13 (trixie);
  requires root, an interactive TTY, and a held `systemd-inhibit` lock for
  the duration of the run.
- **Tailscale exit-node**: installs Tailscale, brings it up (interactive
  browser login, or keeps an existing connection if the host is already
  enrolled), and configures it as an exit-node with stateful filtering,
  netfilter mode, and subnet SNAT.
- **Hardened Docker/Tailscale firewall**: a generated helper script
  (`docker-tailscale-fw`) builds dedicated `iptables`/`ip6tables` chains
  using an atomic "staging chain" swap technique so that Docker's
  `DOCKER-USER` chain and the Tailscale forwarding path stay fail-closed by
  default, with narrow, explicit allow rules for the public services.
- **Fixed Compose stack**: Portainer, Filebrowser, qBittorrent, Unpackerr
  and wg-easy, deployed with pinned image versions, plus a hardened host
  `rclone` WebDAV unit (`master-webdav.service`) serving the media tree
  read-only to the Tailnet.
- **Optional Tailnet-only DNS + reverse proxy**: `dnsmasq` (bound to
  `tailscale0` only) and Caddy (bound to the current Tailscale IPv4) can be
  provisioned for friendly `*.<domain>` names to each service.
- **Self-healing reconcile timer**: a `master-network-reconcile.timer`
  (every 20 minutes) re-verifies and repairs WAN/Tailscale addressing,
  firewall rule sets, Tailscale preferences, container health/port
  bindings, and managed DNS/Caddy configuration, with restart cooldowns to
  avoid flapping.
- **Layered rollback on failure**: a single `EXIT` trap restores
  pre-install timer state and unwinds a partially-configured DNS/Caddy
  stack, regardless of where the script failed.
- **Root-only logging with live progress**: verbose stage-by-stage logs go
  to `/var/log/master-setup/`, while the interactive terminal only shows a
  compact `[stage/7] [bar] percent · label` progress line.
- **Extensive self-verification (Stage 7)**: re-checks systemd unit
  dependency graphs (`systemd-analyze verify` plus explicit
  `Requires`/`After`/`PartOf`/`OnFailure` assertions), firewall rule content
  and ordering, container port bindings, and live HTTP/DNS/WebDAV endpoints
  before declaring success.

## Current Architecture

The script runs as seven stages, gated by `progress_stage_begin`/
`progress_stage_done` and driven by `set -Eeuo pipefail` with `ERR`/`EXIT`/
`INT`/`TERM` traps for cleanup:

| Stage | Purpose |
|-------|---------|
| 0 | Interactive prompts (downloads path, optional local DNS domain, WebDAV username/password), confirmation summary. Tailscale login is always interactive (browser) unless already connected; wg-easy admin setup is not prompted for — it's done manually via the web UI after install |
| 1 | Base OS prep: apt/timer quiescing, timezone, `apt-get update` → `full-upgrade` → base packages |
| 2 | UDP-socket-buffer sysctl, Tailscale install, interactive browser login, exit-node + stateful filtering + netfilter configuration, UDP GRO tuning |
| 3 | Docker install, daemon.json DNS override, generation of the `docker-tailscale-fw` firewall helper and its systemd unit |
| 4 | Data directories, `compose.yaml` + `.env` generation, WebDAV `htpasswd`, `master-compose-ipv4` / `master-network-reconcile` / `master-webdav-serve` helper scripts, systemd units for Compose, WebDAV and reconcile |
| 5 | Image pull, systemd dependency graph verification, firewall + Compose stack startup |
| 6 | Optional Tailnet-only `dnsmasq` + Caddy provisioning |
| 7 | Full runtime verification (systemd properties, firewall rule content, container/service health, DNS/WebDAV endpoints) and final summary |

Custom systemd units created by the script:

- `tailscale-udp-gro.service` — one-shot UDP GRO forwarding tuning
- `docker-tailscale-fw.service` — applies the dedicated firewall chains
- `master-compose.service` — brings up the Compose stack once WAN/Tailscale
  addresses are ready
- `master-webdav.service` — hardened `rclone serve webdav` unit, read-only
  over the media tree, bound to the Tailscale IPv4 only (`V1-3`, DD-20)
- `master-network-reconcile.service` + `.timer` — the 20-minute self-healing
  check/repair pass
- `master-docker-netfilter-recovery.service` — last-resort Docker daemon
  restart to recover Docker-owned DNAT/FORWARD rules
- `caddy.service.d` / `dnsmasq.service.d` / `tailscaled.service.d`
  drop-ins — ordering and `PartOf`/`OnFailure` wiring for the optional
  DNS/Caddy stack

See [`docs/architecture.md`](docs/architecture.md) for a deeper breakdown
and [`docs/design-decisions.md`](docs/design-decisions.md) for the
rationale behind specific choices (e.g. the staging-chain firewall swap,
the canonical-bundle checksum model for reconcile).

## Installation Flow

1. **Stage 0** collects all interactive input up front (downloads path,
   optional local DNS domain, and — unless a credential file already
   exists — the WebDAV username/password) and prints a summary before
   asking for final confirmation. All subsequent stages run non-interactively.
2. Once confirmed, logging switches to `/var/log/master-setup/master-setup-<timestamp>-<pid>.log`;
   the terminal only shows the live progress bar from this point on.
3. Stages 1–3 prepare the base OS, Tailscale, and Docker plus the dedicated
   firewall helper — each stage validates its own preconditions and exits
   non-zero on failure, which triggers the `EXIT` trap's rollback logic.
4. Stage 4 writes all state (`/etc/master-stack/state.env`), the Compose
   file, and the reconcile/recovery helper scripts, but does not yet start
   anything.
5. Stage 5 pulls images, verifies the systemd dependency graph
   (`systemd-analyze verify`), and applies the firewall and starts the
   Compose stack. wg-easy comes up unconfigured on a fresh install — its
   admin account is created manually via its web UI afterward, the same
   as Portainer's.
6. Stage 6 optionally provisions `dnsmasq` + Caddy for Tailnet-only service
   names, using a fail-closed pattern (services are `mask`ed until their
   generated configuration is validated).
7. Stage 7 re-derives all addresses (they may have changed during a long
   install) and runs a comprehensive battery of runtime checks — systemd
   unit properties, firewall rule content/order, container port bindings,
   HTTP/DNS/WebDAV probes — before printing the final summary and enabling
   the 20-minute reconcile timer.

Re-running the script against an already-provisioned host is expected and
supported: most stages detect existing state (Docker daemon.json content,
canonical config checksums, timer states) and skip or reconcile rather
than blindly re-applying.

## Docker Services

All services are defined in a single generated `/root/docker/compose.yaml`
with pinned image tags and shared JSON-file logging (10m × 3 files).

| Service | Image (pinned) | Exposure | Purpose |
|---------|-----------------|----------|---------|
| `portainer` | `portainer/portainer-ce` | `127.0.0.1:9443` (+ optional Tailnet via Caddy) | Docker management UI; mounts `/var/run/docker.sock` |
| `filebrowser` | `filebrowser/filebrowser` | `127.0.0.1:7113` (+ optional Tailnet via Caddy) | Web file browser over the downloads/media tree |
| `qbittorrent` | `lscr.io/linuxserver/qbittorrent` | `127.0.0.1:13087` (WebUI) + public IPv4 on the configured peer port (tcp+udp) | Torrent client |
| `unpackerr` | `ghcr.io/unpackerr/unpackerr` | none (no published ports) | Watches the media tree and extracts nested archives |
| `wg-easy` | `ghcr.io/wg-easy/wg-easy` | `127.0.0.1:51821` (admin UI) + public IPv4 UDP (WireGuard) | WireGuard VPN server with a web admin UI |

WebDAV is **not** a container. `master-webdav.service` (a host systemd
unit, since `V1-3`) runs `rclone serve webdav --read-only` against the
media tree, bound to `<tailscale-ip>:65113` only — never loopback, never
the public IPv4. Credentials come from a bcrypt `htpasswd` file created
from a Stage 0 prompt and passed in via systemd `LoadCredential=`. See
DD-20 for why it stopped being a container.

Notes:

- `wg-easy` runs with `cap_add: [NET_ADMIN]` only and `INSECURE: "true"`
  (required because Caddy reverse-proxies it over plain HTTP inside the
  Tailnet). The WireGuard kernel module, plus `ip6_tables`/`ip6table_nat`
  (needed by `wg-quick`'s legacy-mode ip6tables rules — not loaded by
  anything else on the host, which uses the nftables backend for its own
  firewall), are loaded independently on the host in Stage 4 (standalone,
  best-effort `modprobe` calls, unrelated to Tailscale's own networking
  path) so the container itself never needs `SYS_MODULE` or a
  `/lib/modules` mount (resolved 2026-07-27, see **H1** in
  `SECURITY_REVIEW.md`; the `ip6_tables`/`ip6table_nat` gap was a
  regression found and fixed via live testing on 2026-07-28).
- `qbittorrent` and `unpackerr` run with `cap_drop: [ALL]`; `unpackerr`
  (already non-root) also runs `read_only: true`. `qbittorrent` gets back
  the minimal capability set its linuxserver.io entrypoint needs
  (`cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER]`) — `read_only`
  was tested and found to break that entrypoint's `PUID`/`PGID` handling,
  so it's deliberately not applied there (see **M1** in
  `SECURITY_REVIEW.md`).
- `filebrowser` uses Docker-managed named volumes (`filebrowser_database`,
  `filebrowser_config`) rather than host bind mounts for its own state.
- The downloads/media tree is bind-mounted read-write into `qbittorrent`
  and `unpackerr`; the host WebDAV unit reads it directly, read-only.
- Only `wg-easy` currently defines a Compose healthcheck; the reconcile
  timer substitutes external port/HTTP/DNS probes for the rest of the
  stack.
- The service set is currently fixed — there is no per-service opt-out or
  installation profile (see **Current Limitations** and
  [`docs/profiles.md`](docs/profiles.md)).

## Networking

- **Exit-node**: Tailscale is configured with `--advertise-exit-node
  --stateful-filtering=true --netfilter-mode=on --snat-subnet-routes=true`.
  The WAN interface and public IPv4 are auto-detected from the default
  route (`ip route get 1.1.1.1`).
- **Dedicated firewall chains**: the `docker-tailscale-fw` helper builds
  two custom chains — `MASTER-DOCKER` (filter/`DOCKER-USER`) and
  `MASTER-TS-FORWARD` (mangle/`FORWARD`) — using a randomized staging-chain
  name that is fully populated and then atomically renamed into place, so
  the firewall is never briefly open or briefly fully closed during an
  update.
- **Default posture is fail-closed**: any WAN → Tailnet or Tailnet →
  Docker/LAN traffic that isn't explicitly allowed is dropped; the exit-node
  path (`tailscale0` → detected WAN interface) is the one broad ACCEPT.
- **Narrow public exposure**: only the qBittorrent peer port and the
  wg-easy WireGuard UDP port are DNAT'd to the public IPv4. WebDAV binds
  directly to the current Tailscale IPv4 and nothing else; since `V1-3`
  the Tailnet → Docker direction has **no** firewall exceptions at all
  (the `--ctorigdst` WebDAV allow was the last one, and it left with the
  container — DD-20).
- **Dynamic addressing**: WAN IPv4 and Tailscale IPv4 can change at
  runtime (DHCP renewal, node re-registration); `master-compose-ipv4` and
  the reconcile timer keep `/root/docker/.env`, the firewall rules, and
  (if enabled) dnsmasq/Caddy bindings in sync with the current addresses.
- **Optional Tailnet-only DNS/Caddy**: when enabled, `dnsmasq` listens only
  on `tailscale0` and answers a private zone (`*.your-domain`) with
  interface-derived A records; Caddy binds only to the current Tailscale
  IPv4 and reverse-proxies each service under a friendly hostname. Both are
  installed `mask`ed and only unmasked after their generated configuration
  passes validation, so a partially-configured daemon can never be
  reachable on reboot.
- **Docker container networking**: `wg-easy` runs on its own bridge network
  (`wg`, `10.42.42.0/24` + a ULA IPv6 range) so its internal WireGuard
  routing doesn't interact with the default Docker bridge used by the other
  services.

See [`docs/architecture.md`](docs/architecture.md) for rule-level detail
and the reconcile drift-detection model.

## Security Notes

A full, line-referenced audit is tracked in
[`SECURITY_REVIEW.md`](SECURITY_REVIEW.md). Highlights:

- **No script-managed secrets**: as of 2026-07-27, `install.sh` no longer
  handles any service admin credentials at all — wg-easy's unattended
  bootstrap subsystem was removed (**M6**), so Portainer and wg-easy
  admin accounts are created manually by the operator through each
  service's own web UI. The one exception since `V1-3` is the WebDAV
  credential: Stage 0 prompts for it, and Stage 4 writes only its bcrypt
  hash to `/etc/master-stack/webdav.htpasswd` (`root:root 0600`) — the
  plaintext never reaches disk. `state.env`, `compose.yaml`, and `.env`
  remain `root:root 0600` for the non-secret configuration they do hold.
- **Docker socket exposure (accepted risk, 2026-07-28)**: `portainer`
  mounts `/var/run/docker.sock` directly — a compromise of Portainer is
  equivalent to root on the host. A docker-socket-proxy was considered
  and rejected: Portainer's actual management features (creating/
  recreating containers, deploying stacks) need close to the same broad
  API access that makes this risky in the first place, so a meaningfully
  restrictive proxy would break Portainer's usefulness rather than
  contain the risk. (A read-only socket mount is not a real mitigation
  either — Unix domain sockets don't gate read/write access via the
  mount's `ro` flag.) The user confirmed Portainer is actively used for
  container monitoring/intervention and accepted this as the highest-value
  target in the stack, scoped down by network exposure (`127.0.0.1` +
  tailnet-only) rather than by API restriction. See **C1** in
  `SECURITY_REVIEW.md`.
- **Fail-closed defaults**: firewall, dnsmasq, and Caddy are all brought up
  in a masked/deny-by-default state and only opened once their final,
  validated configuration is in place — including across a mid-install
  failure (the `EXIT` trap restores the pre-install masked/active state).
- **Self-healing vs. operator changes**: the reconcile timer treats the
  canonical (installer-written) copies of the firewall/dnsmasq/Caddy
  configuration as the source of truth and will silently restore them
  within 20 minutes if they drift — including manual operator edits made
  outside the script.
- **Container capabilities**: `wg-easy` was previously granted `SYS_MODULE`
  in addition to `NET_ADMIN`; this was removed on 2026-07-27 in favor of a
  host-level `modprobe wireguard` step, so the container now runs with
  only `NET_ADMIN` (see **H1** in `SECURITY_REVIEW.md`).
- **Tailscale device registration is not ephemeral**: the interactive
  browser login used to join the tailnet registers a normal, persistent
  device. Rebuilding this server (e.g. reinstalling from scratch) will
  leave the old device entry behind in the Tailscale admin console —
  remove it manually there; `install.sh` has no way to control this from
  its side (see **L2** in `SECURITY_REVIEW.md`).
- **First-run admin setup isn't automated**: Portainer and wg-easy both
  require the operator to create their admin account through
  each service's own web UI on first access (the install summary reminds
  you of this and lists the URLs). Do this promptly — until it's done,
  anyone else who can already reach the tailnet could complete that
  service's setup screen first (see **L5** in `SECURITY_REVIEW.md`).

## Current Limitations

- **Monolithic script**: all logic — including the ~600-line firewall
  helper and the ~1300-line reconcile helper — lives in a single
  `install.sh`, embedded as heredocs. These embedded scripts are not
  covered by running `shellcheck`/`bash -n` against `install.sh` itself.
- **No installation profiles**: the five-container Compose bundle plus the
  host WebDAV unit is fixed;
  there is no way to opt out of an individual service (e.g. skip Portainer
  to avoid exposing `docker.sock`, or skip the torrent stack). See
  [`docs/profiles.md`](docs/profiles.md).
- **No CI; unit + live-integration testing exist but aren't automated**:
  end-to-end correctness has been verified via real, live installs (four
  successful ones as of 2026-07-28, plus a full operational stress test —
  see [`docs/testing.md`](docs/testing.md)), but there is no CI pipeline
  running any of this automatically, and Tier 3 still requires a human to
  relay `install.sh`'s interactive prompts. Static analysis of the
  embedded heredoc scripts (`scripts/lint-embedded-scripts.sh`) and 32
  `bats-core` unit tests for their pure-logic functions (`test/*.bats`)
  do exist. See [`docs/testing.md`](docs/testing.md) for the full
  breakdown.
- **Tight service coupling**: several systemd units use `PartOf=docker.service
  tailscaled.service`, meaning a routine `systemctl restart tailscaled`
  (or `docker`) also stops and restarts the entire Compose stack, the
  firewall, and (if enabled) Caddy — a non-obvious side effect for
  operators.
- **No automatic disk-space recovery**: reconcile (as of 2026-07-28)
  reports when the filesystem backing the downloads path crosses 90%
  used, but never frees space itself — deleting user data isn't a safe
  automated action. A full disk stays a reported, non-self-healing
  failure state until an operator intervenes.

See [`TODO.md`](TODO.md) and [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md)
for the full, prioritized list.

## Roadmap

Tracked in detail in [`TODO.md`](TODO.md) and [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md).

**Done, as of 2026-07-29 (`v1rc`):** every finding is now resolved,
accepted or closed except **M7**, whose remainder is parked. That covers
the original 18 audit findings (**C2**, **M6**, **M5**, **H1**,
**H2**/**H3** and **C1** — documented as intentional design or accepted
risk rather than changed — **M4**, **L1**, **L2**, **L4**, **L5**,
**M2**, **L3**, **H4**, **M1**, plus **M3** closed as won't-do), the
three found through live testing and real use (**H5**, **H6**, **H7**),
and the five from the post-R1.0 whole-file review (**M8**, **M9**,
**M10**, **L6**, and **L7** closed as won't-do). Notably:
- **M1** (container hardening) is fully applied: `security_opt:
  no-new-privileges` and an empirically-determined minimal
  `cap_drop`/`cap_add` set for both `qbittorrent` and `unpackerr`, plus
  `read_only: true` for `unpackerr` (found to break `qbittorrent`'s
  `PUID`/`PGID` handling, so deliberately not applied there).
  `unpackerr` also has hardware-sized `mem_limit`/`cpus` ceilings;
  `qbittorrent`'s were removed after real usage showed each raise was
  chasing the workload rather than bounding it — an accepted deviation
  documented under **M1** in `SECURITY_REVIEW.md`.
- **M7**'s testing strategy: Tier 1 (static analysis of all six embedded
  heredoc scripts) is done; Tier 2 has **57** `bats-core` unit tests
  across five files with no identified gaps left; Tier 3 has succeeded
  end-to-end on seven separate live installs, plus a full operational
  validation round (deliberate drift injection into the reconcile loop,
  resource-limit enforcement, real WireGuard/Tailscale-exit-node
  traffic, CPU stress) and four reboots — see
  [`docs/testing.md`](docs/testing.md) for the full results.
- A final architecture review (reconcile's full monitored-state list,
  systemd dependencies, IPv6, container DNS, wg-easy's kernel-module
  approach, Caddy/dnsmasq boot-race safety) found no functional defects,
  and added the one real gap found — disk-space monitoring for the
  filesystem backing `$DOWNLOADS_PATH` — to `master-network-reconcile`.
  Tagged **R1.0**.

**Remaining, at a high level:**

- **M7** is the only finding still open, and its remainder is **parked**:
  Tier 1 is done and Tier 2 has 57 unit tests with no identified gaps
  left, so all that is missing is a CI pipeline — and the repository
  stays local with no git remote by decision (2026-07-28), leaving a
  runner nowhere to build from. Running the four checks manually
  (`bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh`,
  `bats test/`) is the substitute.
- Installation profiles (**M3**) and the hardcoded firewall ports
  (**L7**) were **closed as won't-do** on 2026-07-28: this installer
  targets a single-purpose, single-operator host built from scratch every
  time, with all six services in use, so neither problem can arise.
  [`docs/profiles.md`](docs/profiles.md) is kept as a design note in case
  that ever changes.
- Consider making the `PartOf` service-coupling behavior configurable,
  not just documented (**H3** confirmed it as intentional; no
  opt-out exists today).

## Development Workflow

- **Running the installer requires the user's explicit, specific
  approval for that exact action, every time** — it makes systemd,
  firewall, and Docker daemon-level changes that only mean something
  against a real host with real `systemd`. A prior approval does not
  carry over to a later turn or a different action, and an AI assistant
  must never choose configuration values on the user's behalf — every
  prompt is relayed to and answered by the user directly. In practice
  (2026-07-28), this has been exercised successfully against the user's
  own server, reimaged clean between attempts specifically so there was
  no production data at risk — see [`docs/testing.md`](docs/testing.md)
  Tier 3 for the full methodology (including how to drive the script's
  `/dev/tty`-based prompts non-interactively via `tmux`) and results.
- Before proposing any change to `install.sh`, run:
  - `bash -n install.sh` (syntax check)
  - `shellcheck install.sh` (static analysis — note this does **not**
    cover the embedded heredoc scripts; see **Current Limitations**)
- Read [`CLAUDE.md`](CLAUDE.md) for repository-specific working
  conventions before making changes.
- Design rationale for non-obvious choices (staging-chain firewall swaps,
  the canonical-bundle checksum model, `PartOf` coupling, etc.) belongs in
  [`docs/design-decisions.md`](docs/design-decisions.md) — check there
  before "fixing" something that may be intentional.
- Track in-progress work and open questions in [`SESSION.md`](SESSION.md)
  and prioritized work items in [`TODO.md`](TODO.md).
- Record user-facing changes in [`CHANGELOG.md`](CHANGELOG.md).
