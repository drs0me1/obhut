# Architecture

## Overall architecture

`install.sh` provisions a single Debian 13 (trixie) host as a Tailscale
exit-node plus a fixed Docker Compose service bundle, and leaves behind a
continuously self-healing reconcile loop. This section describes the
system as it exists today, derived directly from reading the script (no
part of this is aspirational — see `docs/profiles.md` for planned, not-yet
-implemented changes).

### Installation stages

The script runs as seven sequential stages (0–7), gated by
`progress_stage_begin` / `progress_stage_done`, under `set -Eeuo pipefail`
with `ERR`/`EXIT`/`INT`/`TERM` traps for cleanup:

| Stage | Lines (approx.) | Purpose |
|-------|-----------------|---------|
| 0 | 523–612 | Interactive prompts: downloads path, optional local DNS domain; confirmation summary. Tailscale login is always interactive (browser) unless the host is already connected; wg-easy admin setup is not prompted for here — it's done manually via the web UI after install |
| 1 | 613–725 | Base OS prep: apt/timer quiescing, timezone, base packages |
| 2 | 726–953 | Tailscale install, exit-node + stateful filtering + netfilter configuration, UDP GRO tuning |
| 3 | 954–1649 | Docker install, `daemon.json` DNS override, generation of the `docker-tailscale-fw` firewall helper and its systemd unit |
| 4 | 1650–3326 | Data directories, `compose.yaml` + `.env` generation, `master-compose-ipv4` and `master-network-reconcile` helper scripts, systemd units for Compose and reconcile |
| 5 | 3327–3374 | Image pull, systemd dependency graph verification, firewall + Compose stack startup |
| 6 | 3375–3687 | Optional Tailnet-only `dnsmasq` + Caddy provisioning |
| 7 | 3688–4324 | Full runtime verification (systemd properties, firewall rule content, container/service health, DNS/WebDAV endpoints) and final summary |

Stage 0 is the only interactive stage; once the user confirms, output is
redirected to a root-only log file (`/var/log/master-setup/`) and the
terminal shows only a compact progress bar for the remainder of the run.

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

The `docker-tailscale-fw` helper (generated at `install.sh:1098-1621`,
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

### Reconcile and self-healing

`master-network-reconcile` (generated at `install.sh:1980-3209`, ~1230
lines) runs every 5 minutes via `master-network-reconcile.timer` and
checks, in order: WAN/Tailscale address drift, IP forwarding sysctls,
Tailscale preferences and netfilter backbone, the dedicated firewall
chains (via `docker-tailscale-fw --check`), Docker's own DNAT/FORWARD
rules, Compose container health and port bindings, the canonical
config-file bundle (state/dnsmasq/Caddy), and — if local DNS is enabled —
live DNS and Caddy HTTP responses.

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
| `/etc/master-stack/state.env` | `root:root 0600` | Live copy of stack configuration (schema version, ports, local DNS domain, wg-easy endpoint) |
| `/usr/local/share/master-stack/` | `root:root 0755` | Canonical copies of state/dnsmasq/Caddy config + `SHA256SUMS` manifest, used by reconcile to detect drift |
| `/root/docker/compose.yaml`, `/root/docker/.env` | `root:root 0600` | The Compose stack definition and its dynamic address values |

wg-easy no longer has any dedicated bootstrap/secret files (removed
2026-07-27, see `docs/design-decisions.md` DD-7) — its admin/peer
configuration lives entirely inside its own container state
(`/data/wg-easy/config`), managed manually by the operator.
