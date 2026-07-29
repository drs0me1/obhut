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
| 0 | 543–682 | Interactive prompts: downloads path, optional local DNS domain; confirmation summary. wg-easy admin setup is not prompted for here — it's done manually via the web UI after install |
| 1 | 694–989 | Base OS prep: apt/timer quiescing, timezone, base packages, forwarding + UDP-socket-buffer sysctls, Tailscale install, **the interactive browser login**, then `apt-get full-upgrade` |
| 2 | 990–1125 | UDP GRO tuning (`tailscale-udp-gro` helper at `993–1066`), exit-node + stateful filtering + netfilter configuration |
| 3 | 1126–1853 | Docker install, `daemon.json` DNS override, generation of the `docker-tailscale-fw` firewall helper (`1231–1786`) and its systemd unit |
| 4 | 1854–3727 | Data directories, `compose.yaml` + `.env` generation, `master-compose-ipv4` (`2195–2235`) and `master-network-reconcile` (`2276–3605`) helper scripts, `master-docker-netfilter-recovery` (`3610–3658`), systemd units for Compose and reconcile |
| 5 | 3728–3775 | Image pull, systemd dependency graph verification, firewall + Compose stack startup |
| 6 | 3776–4092 | Optional Tailnet-only `dnsmasq` + Caddy provisioning (`caddy-tailnet-env` helper at `3888–3919`), then the single atomic publication of the canonical bundle (see DD-14) |
| 7 | 4093–4736 | Full runtime verification (systemd properties, firewall rule content, container/service health, DNS/WebDAV endpoints) and final summary |

(Line numbers as of `install.sh` 4736 lines — `v1.1-1`, 2026-07-29. They
drift with every change; regenerate with `grep -n '^progress_stage_begin'`
rather than trusting them after a batch of edits.)

Stage 0 is the only stage that *prompts*; once the user confirms, output is
redirected to a root-only log file (`/var/log/master-setup/`) and the
terminal shows only a compact progress bar for the remainder of the run.
Stage 1 still blocks once, on the Tailscale browser login — see
`docs/design-decisions.md` DD-19 for why that step sits where it does and
why it prints its own framed banner rather than a plain line.

Note: as of 2026-07-27, wg-easy's admin/peer configuration is intentionally
**not** automated — the script only provisions the container, port, volume,
network, and firewall rules. The user creates the admin account through
wg-easy's own web UI on first access, the same as Portainer and SFTPGo. See
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

master-network-reconcile.timer ──(every 5 min)──> master-network-reconcile.service
master-network-reconcile.service ──After──────────> docker.service, tailscaled.service
                                  ──(may start)────> master-docker-netfilter-recovery.service

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

The `docker-tailscale-fw` helper (generated at `install.sh:1231-1786`,
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
`ts-postrouting` MASQUERADE still applies). Only three narrow allows exist
beyond that:

- qBittorrent's peer port (TCP+UDP) DNAT'd to the public IPv4
- wg-easy's WireGuard UDP port DNAT'd to the public IPv4
- SFTPGo's WebDAV TCP port, allowed only for packets whose *original*
  destination (via `--ctorigdst`) is the current Tailscale IPv4 — never
  the public IPv4

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
and volumes. All six services (Portainer, Filebrowser, qBittorrent,
Unpackerr, wg-easy, SFTPGo) are defined in one generated
`/root/docker/compose.yaml` with pinned image tags.

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

`master-network-reconcile` (generated at `install.sh:2276-3605`, ~1329
lines) runs every 5 minutes via `master-network-reconcile.timer` and
checks, in order: WAN/Tailscale address drift, IP forwarding sysctls,
**disk space on the filesystem backing `$DOWNLOADS_PATH`** (added
2026-07-28 — reported via `disk_space_ok()` when usage crosses 90%, but
never auto-repaired, since deleting user data isn't a safe automated
action), Tailscale preferences and netfilter backbone, the dedicated
firewall chains (via `docker-tailscale-fw --check`), Docker's own
DNAT/FORWARD rules, Compose container health and port bindings, the
canonical config-file bundle (state/dnsmasq/Caddy), and — if local DNS is
enabled — live DNS and Caddy HTTP responses. It also guards UDP GRO
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
including a manual operator edit, is reverted within one 5-minute cycle.
See `docs/design-decisions.md` for the rationale. **Confirmed intentional
by the user (2026-07-27):** this guarantees dnsmasq/Caddy reachability
against accidental or unauthorized drift, and is documented explicitly in
the final install summary so operators aren't surprised by it.

### State and configuration files

| Path | Mode | Purpose |
|------|------|---------|
| `/etc/master-stack/state.env` | `root:root 0600` | Live copy of stack configuration (schema version, ports, local DNS domain, wg-easy endpoint, downloads path — the last one added 2026-07-28 for reconcile's disk-space check) |
| `/etc/sysctl.d/99-tailscale.conf` | `root:root 0644` | IPv4/IPv6 forwarding; content and ownership are verified and repaired by reconcile |
| `/etc/sysctl.d/99-master-stack-netbuf.conf` | `root:root 0644` | UDP socket buffer ceilings (`net.core.rmem_max`/`wmem_max`), floored at 16 MiB and never lowered. Written *before* `tailscaled` is first started, since `wireguard-go` requests its buffer once at socket-open time and is clamped against the ceiling then in effect (DD-19). Not reconciled — a `sysctl.d` file survives reboots by construction, so the file on disk is the guarantee (DD-18) |
| `/usr/local/share/master-stack/` | `root:root 0755` | Canonical copies of state/`compose.yaml`/dnsmasq/Caddy config + `SHA256SUMS` manifest, used by reconcile to detect drift. Published as one atomic set at the end of Stage 6 (DD-14). `compose.yaml` is compared and **reported** on drift but never auto-restored (M10), unlike the dnsmasq/Caddy files |
| `/root/docker/compose.yaml`, `/root/docker/.env` | `root:root 0600` | The Compose stack definition and its dynamic address values |

wg-easy no longer has any dedicated bootstrap/secret files (removed
2026-07-27, see `docs/design-decisions.md` DD-7) — its admin/peer
configuration lives entirely inside its own container state
(`/data/wg-easy/config`), managed manually by the operator.
