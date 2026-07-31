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
| 0 | 554–709 | Interactive prompts: downloads path, optional local DNS domain; confirmation summary. Tailscale login is always interactive (browser) unless the host is already connected; wg-easy admin setup is not prompted for here — it's done manually via the web UI after install |
| 1 | 710–826 | Base OS prep: apt/timer quiescing, timezone, `apt-get update` → `full-upgrade` → base packages (in that order, so the base packages arrive already current and are not upgraded twice) |
| 2 | 827–1116 | UDP-socket-buffer sysctl (written **before** the Tailscale package install — see M11/DD-19), Tailscale install, forwarding sysctl, UDP GRO tuning (`tailscale-udp-gro` helper at `924–999`), interactive login, exit-node + stateful filtering + netfilter configuration |
| 3 | 1117–1833 | Docker install, `daemon.json` DNS override, generation of the `docker-tailscale-fw` firewall helper (`1222–1766`) and its systemd unit |
| 4 | 1834–3973 | Data directories, `compose.yaml` + `.env` generation, `master-compose-ipv4` (`2187–2228`) and `master-network-reconcile` (`2268–3702`) helper scripts, `master-docker-netfilter-recovery` (`3706–3755`), `master-webdav-serve` (`3847–3915`), systemd units for Compose, WebDAV and reconcile |
| 5 | 3974–4036 | Image pull, systemd dependency graph verification, firewall + Compose stack startup |
| 6 | 4037–4339 | Tailnet-only `dnsmasq` + Caddy provisioning (unconditional since `V1-8`) (`caddy-tailnet-env` helper at `4147–4179`), then the single atomic publication of the canonical bundle (see DD-14) |
| 7 | 4340–4984 | Full runtime verification (systemd properties, firewall rule content, container/service health, DNS/WebDAV endpoints) and final summary |

(Line numbers as of `install.sh` 4984 lines — `V1-11`, 2026-07-31. They
drift with every change; regenerate with `grep -n 'progress_stage_begin [0-7] '`
rather than trusting them after a batch of edits — the stage 5–7 rows had
silently drifted 18 lines before `V1-11` caught it, which is why the
regeneration command above is worth actually running.)

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

The `docker-tailscale-fw` helper (generated at `install.sh:1222-1766`,
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

`master-network-reconcile` (generated at `install.sh:2268-3702`, 1433
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

### State and configuration files

| Path | Mode | Purpose |
|------|------|---------|
| `/etc/master-stack/state.env` | `root:root 0600` | Live copy of stack configuration (schema version, ports, local DNS domain, wg-easy endpoint, downloads path — the last one added 2026-07-28 for reconcile's disk-space check). Since `V1-2` it also records `STACK_VERSION` and `STACK_SHA256` (the installing script's own hash), so a host self-reports which revision built it; both keys are informational — shown by `master-network-reconcile --status`, required by nothing. `STACK_SCHEMA` is `9` as of `V1-8`, which dropped `LOCAL_DNS_ENABLED` when Tailnet DNS/Caddy stopped being optional |
| `/etc/sysctl.d/99-tailscale.conf` | `root:root 0644` | IPv4/IPv6 forwarding; content and ownership are verified and repaired by reconcile |
| `/etc/sysctl.d/99-master-stack-netbuf.conf` | `root:root 0644` | UDP socket buffer ceilings (`net.core.rmem_max`/`wmem_max`), floored at 16 MiB and never lowered. Written **before** `apt-get install -y tailscale`, because the package's postinst starts `tailscaled` and `wireguard-go` requests its buffer once at socket-open time (M11). Not reconciled — a `sysctl.d` file survives reboots by construction, so the file on disk is the guarantee (DD-18) |
| `/usr/local/share/master-stack/` | `root:root 0755` | Canonical copies of state/`compose.yaml`/dnsmasq/Caddy config + `SHA256SUMS` manifest, used by reconcile to detect drift. Published as one atomic set at the end of Stage 6 (DD-14). `compose.yaml` is compared and **reported** on drift but never auto-restored (M10), unlike the dnsmasq/Caddy files |
| `/root/docker/compose.yaml`, `/root/docker/.env` | `root:root 0600` | The Compose stack definition and its dynamic address values |
| `/etc/master-stack/webdav.htpasswd` | `root:root 0600` | WebDAV Basic-auth credential (bcrypt) for `master-webdav.service`, generated in Stage 4 from the Stage 0 prompt. The service reads it via systemd `LoadCredential=`, so the file never needs to be readable by the service user. Deliberately **not** part of the canonical bundle: reconcile must not revert or recreate a credential. Preserved across re-runs — delete it and re-run to set a new one |

wg-easy no longer has any dedicated bootstrap/secret files (removed
2026-07-27, see `docs/design-decisions.md` DD-7) — its admin/peer
configuration lives entirely inside its own container state
(`/data/wg-easy/config`), managed manually by the operator.
