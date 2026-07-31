# Architecture

## Overall architecture

`install.sh` provisions a single Debian 13 (trixie) host as a Tailscale
exit-node plus a fixed Docker Compose service bundle, and leaves behind a
continuously self-healing reconcile loop. This section describes the
system as it exists today, derived directly from reading the script.
Nothing here is aspirational: the one document that was
(`docs/profiles.md`) describes a model that was closed as won't-do on
2026-07-28 and is retained only as a design note.

### Installation stages

The script runs as seven sequential stages (0–7), gated by
`progress_stage_begin` / `progress_stage_done`, under `set -Eeuo pipefail`
with `ERR`/`EXIT`/`INT`/`TERM` traps for cleanup:

| Stage | Lines (approx.) | Purpose |
|-------|-----------------|---------|
| 0 | 656–813 | Interactive prompts: downloads path, optional local DNS domain; confirmation summary. Tailscale login is always interactive (browser) unless the host is already connected; wg-easy admin setup is not prompted for here — it's done manually via the web UI after install |
| 1 | 814–932 | Base OS prep: apt/timer quiescing, timezone, `apt-get update` → `full-upgrade` → base packages (in that order, so the base packages arrive already current and are not upgraded twice) |
| 2 | 933–1228 | UDP-socket-buffer sysctl (written **before** the Tailscale package install — see M11/DD-19), Tailscale install, forwarding sysctl, UDP GRO tuning (`tailscale-udp-gro` helper at `1036–1111`), interactive login, exit-node + stateful filtering + netfilter configuration |
| 3 | 1229–1949 | Docker install, `daemon.json` DNS override, generation of the `docker-tailscale-fw` firewall helper (`1338–1882`) and its systemd unit |
| 4 | 1950–4129 | Data directories, `compose.yaml` + `.env` generation, `master-compose-ipv4` (`2304–2345`) and `master-network-reconcile` (`2385–3851`) helper scripts, `master-docker-netfilter-recovery` (`3855–3911`), `master-webdav-serve` (`4003–4071`), systemd units for Compose, WebDAV and reconcile |
| 5 | 4130–4232 | Image pull, systemd dependency graph verification, firewall + Compose stack startup |
| 6 | 4233–4548 | Tailnet-only `dnsmasq` + Caddy provisioning (unconditional since `V1-8`) (`caddy-tailnet-env` helper at `4356–4388`), then the single atomic publication of the canonical bundle (see DD-14) |
| 7 | 4549–5251 | Full runtime verification (systemd properties, firewall rule content, container/service health, DNS/WebDAV endpoints) and final summary |

(Line numbers as of `install.sh` 5251 lines — `V1-17`, 2026-07-31. They
drift with every change; regenerate with `grep -n 'progress_stage_begin [0-7] '`
rather than trusting them after a batch of edits. **This has now drifted
twice**: 18 lines across stages 5–7 before `V1-11` caught it, and again in
`V1-15`, where a block added above stage 1 shifted stages 0–4 by 14 lines
while only the tail of the table was refreshed. Regenerating the *whole*
table is the only reliable move; patching the rows you think changed is
what caused both.)

Stage 0 is the only interactive stage; once the user confirms, output is
redirected to a root-only log file (`/var/log/master-setup/`) and the
terminal shows only a compact progress bar for the remainder of the run.

Note: as of 2026-07-27, wg-easy's admin/peer configuration is intentionally
**not** automated — the script only provisions the container, port, volume,
network, and firewall rules. The user creates the admin account through
wg-easy's own web UI on first access, the same as Portainer. See
`docs/design-decisions.md` (DD-7) for the history of this decision.

### Systemd unit graph

Custom units created by the script, and their key relationships:

```
tailscaled.service ──Wants/Before──> docker-tailscale-fw.service
                    ──Wants/Before──> master-compose.service
                    ──Wants/Before──> caddy.service (optional)

docker.service      ──Wants───────> docker-tailscale-fw.service
                    ──Wants───────> master-compose.service

docker-tailscale-fw.service ──Requires/After/PartOf──> docker.service, tailscaled.service
                            ──OnFailure──────────────> master-network-reconcile.service

master-compose.service     ──Requires/After/PartOf──> docker.service, docker-tailscale-fw.service, tailscaled.service
                           ──OnFailure──────────────> master-network-reconcile.service

master-network-reconcile.timer ──(every 20 min)──> master-network-reconcile.service
master-network-reconcile.service ──After──────────> docker.service, tailscaled.service
                                  ──(may start)────> master-docker-netfilter-recovery.service

master-webdav.service      ──Wants/After/PartOf──> tailscaled.service
                           ──OnFailure──────────────> master-network-reconcile.service

dnsmasq.service / caddy.service (optional) ──Wants/After──> tailscaled.service
                                            ──OnFailure───> master-network-reconcile.service
caddy.service ──PartOf──> tailscaled.service
```

**Confirmed intentional by the user (2026-07-27):** the `PartOf` coupling
(restarting `docker`/`tailscaled` cascades into the firewall, Compose
stack, and Caddy) is a deliberate choice to enforce strict ordering — not
an oversight. It's now called out explicitly in the final install summary.

Key design point: `master-network-reconcile.service` deliberately does
**not** sit in the `After=` chain of `docker-tailscale-fw.service` or
`master-compose.service`, to avoid a self-ordering wait when it restarts
them from inside its own `OnFailure`-triggered execution.

### Firewall model

The `docker-tailscale-fw` helper (generated at `install.sh:1338-1882`,
deployed to `/usr/local/sbin/docker-tailscale-fw`) builds two dedicated
chains:

- `MASTER-DOCKER` (filter table, jumped to from `DOCKER-USER`)
- `MASTER-TS-FORWARD` (mangle table, jumped to from `FORWARD`, ahead of
  Docker's own filter-table jumps)

Both are built using an atomic **staging-chain swap**: a new, randomly
named chain (`MASTER-NEXT-$RANDOM` / `MASTER-TS-NEXT-$RANDOM`) is fully
populated first, spliced in as the first jump target, and only then is the
old chain torn down and the new one renamed into its canonical name. This
means the firewall is never briefly wide-open or briefly fully blocking
during an update.

Default posture is fail-closed: any WAN → Tailnet or Tailnet → Docker/LAN
traffic not explicitly allowed is dropped. The one broad ACCEPT is the
exit-node path itself (`tailscale0` → detected WAN interface, marked and
accepted in both the mangle and filter tables so Tailscale's own
`ts-postrouting` MASQUERADE still applies). Only two narrow allows exist
beyond that:

- qBittorrent's peer port (TCP+UDP) DNAT'd to the public IPv4
- wg-easy's WireGuard UDP port DNAT'd to the public IPv4

Both are WAN → Docker. As of `V1-3` the **Tailnet → Docker direction has
no exceptions at all**: the one that existed — SFTPGo's WebDAV TCP port,
allowed only for packets whose original destination (via `--ctorigdst`)
was the current Tailscale IPv4 — disappeared when WebDAV moved to a host
service, whose traffic arrives on the INPUT path the guard chain never
sees. See DD-20.

### Network topology

- WAN interface and public IPv4 are auto-detected via `ip route get
  1.1.1.1` (`detect_ipv4_route`, reused by the firewall helper and the
  reconcile script).
- Tailscale IPv4 is read from `tailscale0`'s global-scope address.
- Both addresses are dynamic: `master-compose-ipv4` (an `ExecStartPre` for
  `master-compose.service`) and the reconcile timer keep
  `/root/docker/.env`, the firewall rules, and (if enabled) dnsmasq/Caddy
  bindings in sync whenever either address changes.
- `wg-easy` runs on its own Docker bridge network (`wg`,
  `10.42.42.0/24` + a ULA `/64`) rather than the default bridge, isolating
  its internal WireGuard routing from the other five containers.

### Service inventory

See `README.md` → **Docker Services** for the full table of images, ports,
and volumes. All five containers (Portainer, Filebrowser, qBittorrent,
Unpackerr, wg-easy) are defined in one generated
`/root/docker/compose.yaml` with pinned image tags. WebDAV is the sixth
service but is **not** a container: since `V1-3` it is `master-webdav.service`,
a hardened host unit running `rclone serve webdav` read-only against
`$DOWNLOADS_PATH/media`, bound to the Tailscale IPv4 only (DD-20).

`qbittorrent` and `unpackerr` (2026-07-28, **M1**) run with `cap_drop:
[ALL]` and `security_opt: no-new-privileges`. `unpackerr` (already
non-root) also runs `read_only: true` and keeps hardware-sized
`mem_limit`/`cpus` ceilings; `qbittorrent`'s ceilings were removed the
same day after real high-throughput usage showed each raise was chasing
the workload rather than bounding it (see `SECURITY_REVIEW.md` M1 for
the accepted residual risk). `qbittorrent` gets back the
minimal capability set its linuxserver.io entrypoint needs to fix
`PUID`/`PGID` ownership on first run (`cap_add: [CHOWN, SETUID, SETGID,
DAC_OVERRIDE, FOWNER]`) — `read_only` was tested and found to break that
same mechanism (files end up owned by the image's default UID/GID
instead of `1000:1000`), so it's deliberately not applied there. See
`SECURITY_REVIEW.md` (M1) for how these were determined.

### Reconcile and self-healing

`master-network-reconcile` (generated at `install.sh:2385-3851`, 1466
lines) accepts three modes: the default `reconcile` (detect + repair),
`--check` (read-only drift report, used by Stage 7 and by `--status`),
and `--status` (added `V1-2`): a lock-free, read-only one-screen summary
— installed version + script SHA256 from `state.env`, per-container
state/health, failed systemd units, downloads-disk usage, the
`/run`-based repair stamps, and a full `--check` run whose exit code the
mode passes through. It runs every 20 minutes via
`master-network-reconcile.timer` and
checks, in order: WAN/Tailscale address drift, IP forwarding sysctls,
**disk space on the filesystem backing `$DOWNLOADS_PATH`** (added
2026-07-28 — reported via `disk_space_ok()` when usage crosses 90%, but
never auto-repaired, since deleting user data isn't a safe automated
action), Tailscale preferences and netfilter backbone, the dedicated
firewall chains (via `docker-tailscale-fw --check`), Docker's own
DNAT/FORWARD rules, Compose container health and port bindings, the
canonical config-file bundle (state/dnsmasq/Caddy), **the host WebDAV
service** (added `V1-3`, unconditional — unlike Caddy/dnsmasq it does not
depend on the local-DNS option), and — if local DNS is enabled — live DNS
and Caddy HTTP responses. WebDAV is checked on two independent signals,
the same shape as UDP GRO's: whether `master-webdav.service` is active,
and whether a real `PROPFIND` request (`Depth: 0`) to the *current*
Tailscale IPv4 returns 401. `PROPFIND` rather than `OPTIONS` because
rclone does not authenticate `OPTIONS` at all and answers it 200 — the
`V1-6` live test found all three of the installer's 401 probes were
measuring a method rclone leaves open, where sftpgo had returned 401.
The second signal catches the case the first cannot — the unit
reading `active` while `rclone` is still bound to a Tailscale address the
host no longer holds, which is exactly what a node re-registration
produces. Repair is `systemctl restart`, whose `ExecStart` re-resolves the
address. It also guards UDP GRO
(added 2026-07-29) on two independent signals: whether
`tailscale-udp-gro.service` is active, and whether the `ethtool` flags on
the IPv4 WAN interface are actually set. The unit is `Restart=no`, so a
boot-time failure would otherwise persist until the next reboot; and
because the unit uses `RemainAfterExit=yes`, flags cleared without the
unit failing would leave it reading `active` while the optimization is
gone. Repair for either signal is `systemctl restart`, keeping systemd the
single execution path. Both checks sit outside
`all_critical_state_healthy()` and do not affect the exit code, because
UDP GRO is a throughput optimization rather than a connectivity
precondition — see DD-11.

A wg-easy container still sitting on its `/setup` screen is reported
(`UYARI`) but is deliberately *not* a failure: it sets `WG_SETUP_PENDING`,
which suppresses wg-easy's automatic restart — restarting a container
waiting for its first web setup fixes nothing — without setting
`RECOVERY_FAILED`. Until `V1-11` both conditions shared the single
`WG_CONFIGURATION_INVALID` flag, which produced a signal that lied exactly
when it mattered: a healthy host exited 0 through the
`all_critical_state_healthy()` early return, but the moment reconcile
actually repaired something it fell past that gate and exited 1 *despite
the repair succeeding*. A genuine internal-port mismatch still sets
`WG_CONFIGURATION_INVALID` and still fails, because that one is a real
misconfiguration no restart can fix.

Repairs are scoped and cooldown-gated:

- Container restarts are throttled to once per 15 minutes per container
  (`RESTART_STATE_DIR/*.last-restart`).
- A full Docker daemon restart (via
  `master-docker-netfilter-recovery.service`) is a last-resort remedy for
  Docker-owned DNAT/FORWARD drift, gated by its own 15-minute cooldown and
  only triggered when the lighter-weight checks fail.
- Core daemons (`docker`, `tailscaled`) are never restarted synchronously
  from inside the reconcile pass itself — the script defers to their own
  systemd restart policies to avoid ordering cycles.

Reconcile treats the canonical (installer-written) copies of
firewall/dnsmasq/Caddy configuration as the source of truth: any drift,
including a manual operator edit, is reverted within one 20-minute cycle.
See `docs/design-decisions.md` for the rationale. **Confirmed intentional
by the user (2026-07-27):** this guarantees dnsmasq/Caddy reachability
against accidental or unauthorized drift, and is documented explicitly in
the final install summary so operators aren't surprised by it.

### Network-dependent steps: bounded retry, mandatory timeout

Every step that talks to the network goes through `retry_network`
(`install.sh:244`): three attempts, an explicit per-attempt `timeout`, and
a 5s/15s backoff. Applied at five call sites — `apt-get update` (four
occurrences), the Tailscale keyring and repo list, the Docker GPG key, the
Caddy GPG key and repo list, and `docker compose pull`.

**The timeout matters more than the retry**, which is the inverse of how
L8 was first framed. The script runs under `systemd-inhibit
--what=shutdown:sleep --mode=block` and holds the `flock` it shares with
reconcile, so a single hung download blocks shutdown *and* leaves the
20-minute reconcile timer unable to run, indefinitely. The Docker Hub 502
that prompted this failed loudly and safely — the install stopped and the
immediate re-run succeeded. A hang would not have.

**No error classification.** Permanent failures (`manifest unknown`,
`unauthorized`, a full disk) return in seconds, so three blind attempts
cost them ~20s of backoff before the same clear error. Only transient
faults and hangs consume real time, and those are the target. Matching
stderr text would be locale- and upstream-format-dependent for no gain.

Budgets were chosen against measured baselines rather than guessed
(2026-07-31, on the netcup host): cold `docker compose pull` 10.9s for
885 MB across three registries, warm pull 3.2s, `apt-get update` 0.9s,
keyring fetches 36–127 ms. Bulk transfers get 300s then 180s — ~27× the
measured cold pull — and small fetches 60s then 30s. Worst case for a true
hang at the pull is about 11 minutes instead of forever.

One measurement worth keeping in mind: **the warm pull still takes 3.2s**,
because it re-checks manifests at all three registries. The pull step is a
hard network dependency on *every* run, including runs where nothing has
changed — which is exactly how a transient registry fault reached an
otherwise no-op re-run.

`apt-get full-upgrade` and `apt-get install` are deliberately **not**
wrapped: they drive dpkg transactions, and interrupting and reissuing one
is a different problem class that interacts with `--force-conf*`. Wrapping
them would move the risk, not reduce it.

### Re-running the installer

`install.sh` is the upgrade path; there is no separate upgrade script,
and adding one would mean a second copy of the canonical
unit/firewall/Compose/DNS definitions when the whole self-healing model
depends on there being exactly one.

Measured on 2026-07-31 against a healthy host: **25 seconds, zero
container restarts** *when no image tag has moved.* All five `StartedAt`
timestamps identical before and after, the wg-easy peer and `wg0` listen
port intact, Portainer's `InstanceID` unchanged, `webdav.htpasswd`
untouched, `--check` rc 0.

Since `V1-12` the qualifier matters: image tags float (DD-23), so
`docker compose pull` can fetch a newer image and `up -d` will then
recreate **exactly those containers whose image actually changed** — the
others still keep their uptime. A re-run is therefore a no-op when
nothing upstream has moved and a scoped upgrade when something has.

That is a property of the unit design rather than a happy accident.
`master-compose.service` is `Type=oneshot` with `RemainAfterExit=yes`
and **no `ExecStop`**, so Stage 5's `systemctl stop master-compose` marks
the unit inactive without signalling the containers; the following
`docker compose up -d --wait` then converges to the same state and does
nothing. Containers are only recreated when `compose.yaml` genuinely
changes. `master-webdav` is the one service restarted unconditionally,
because its unit definition or its `LoadCredential` source may have
changed — a second or two of WebDAV unavailability.

What a re-run rewrites regardless: `compose.yaml`, every embedded helper
script, every systemd unit, the firewall chains, the dnsmasq/Caddy
configuration and the canonical bundle. What it preserves: the media
tree, `/data/*` (wg-easy keys and peers, Portainer's database,
qBittorrent's session), `webdav.htpasswd`, the Tailscale node identity
and login, and gid-1000 group membership.

Two consequences worth stating plainly:

- **Manual edits to `compose.yaml` are silently overwritten.** Reconcile
  deliberately only reports Compose drift and never reverts it (M10), but
  `install.sh` rewrites the file unconditionally — the asymmetry is
  intentional and easy to be surprised by. A lasting change belongs in
  `install.sh`.
- **A re-run upgrades nothing by itself.** Image tags are pinned to exact
  versions in the generated `compose.yaml`, so `docker compose pull`
  fetches what is already present. Upgrades happen only when the pins in
  `install.sh` change.

### State and configuration files

| Path | Mode | Purpose |
|------|------|---------|
| `/etc/master-stack/state.env` | `root:root 0600` | Live copy of stack configuration (schema version, ports, local DNS domain, wg-easy endpoint, downloads path — the last one added 2026-07-28 for reconcile's disk-space check). Since `V1-2` it also records `STACK_VERSION` and `STACK_SHA256` (the installing script's own hash), so a host self-reports which revision built it; both keys are informational — shown by `master-network-reconcile --status`, required by nothing. `STACK_SCHEMA` is `10` as of `V1-12`, which added the five `IMAGE_DIGEST_*` keys; `9` (`V1-8`) had dropped `LOCAL_DNS_ENABLED` when Tailnet DNS/Caddy stopped being optional. The digest keys are appended after Stage 5 rather than written with the heredoc block, because the images only exist locally once they have been pulled (DD-23) |
| `/etc/sysctl.d/99-tailscale.conf` | `root:root 0644` | IPv4/IPv6 forwarding; content and ownership are verified and repaired by reconcile |
| `/etc/sysctl.d/99-master-stack-netbuf.conf` | `root:root 0644` | UDP socket buffer ceilings (`net.core.rmem_max`/`wmem_max`), floored at 16 MiB and never lowered. Written **before** `apt-get install -y tailscale`, because the package's postinst starts `tailscaled` and `wireguard-go` requests its buffer once at socket-open time (M11). Not reconciled — a `sysctl.d` file survives reboots by construction, so the file on disk is the guarantee (DD-18) |
| `/usr/local/share/master-stack/` | `root:root 0755` | Canonical copies of state/`compose.yaml`/dnsmasq/Caddy config + `SHA256SUMS` manifest, used by reconcile to detect drift. Published as one atomic set at the end of Stage 6 (DD-14). `compose.yaml` is compared and **reported** on drift but never auto-restored (M10), unlike the dnsmasq/Caddy files |
| `/root/docker/compose.yaml`, `/root/docker/.env` | `root:root 0600` | The Compose stack definition and its dynamic address values |
| `/etc/master-stack/webdav.htpasswd` | `root:root 0600` | WebDAV Basic-auth credential (bcrypt) for `master-webdav.service`, generated in Stage 4 from the Stage 0 prompt. The service reads it via systemd `LoadCredential=`, so the file never needs to be readable by the service user. Deliberately **not** part of the canonical bundle: reconcile must not revert or recreate a credential. Preserved across re-runs — delete it and re-run to set a new one |

wg-easy no longer has any dedicated bootstrap/secret files (removed
2026-07-27, see `docs/design-decisions.md` DD-7) — its admin/peer
configuration lives entirely inside its own container state
(`/data/wg-easy/config`), managed manually by the operator.
