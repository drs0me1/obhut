# Session Notes

Cross-session continuity for this repository.

## Current Task

**2026-09-05:** Added separate `container-backup.command` and Linux helper
`dev/container-backup-remote.sh`. Scope: Portainer data, FileBrowser DB/config,
wg-easy DB/keys/config, qBittorrent `qBittorrent.conf` only. Backups are private,
unencrypted and Git-ignored under `backup/`; no installer seed integration.
Initial live snapshot: `backup/20260905T173254Z-nrm-settings.nceicd/settings.tar.gz`.
All 11 data files passed isolated restore/hash/ownership/mode verification;
production restore was not performed. See `docs/container-backup.md`.

**v2-73 in [Unreleased] (2026-08-30):** Ubuntu 26.04's nft-default host did
not load the legacy IPv4 `ip_tables`/`iptable_nat` modules required by
wg-easy's in-container `iptables-legacy`; `wg-quick up wg0` therefore failed
at its IPv4 NAT rule. Stage 4 now preloads and boot-persists those modules
alongside `wireguard`, `ip6_tables` and `ip6table_nat` (**DD-10**). The live
host recovered after loading both modules and restarting only wg-easy. A
v2-73 default re-run preserved all six container IDs/start times; a cold
reboot then loaded all five modules through `systemd-modules-load`, brought
wg-easy up healthy on UDP 61001 with no current-boot iptables errors, and
passed firewall, dual-path DNS, Caddy, authenticated/read-only WebDAV and
zero-failed-unit checks.

**v2-72 (2026-08-29):** Ubuntu 24.04/26.04 LTS support —
`require_supported_os` matrix, repo lines from `os-release`, ufw gate,
resolv.conf stub repoint, dpkg-lock wait (**DD-102**). **Live-verified on
both Ubuntu lines:** noble 24.04.4 on 2026-08-29 and resolute 26.04.1 on
2026-08-30. The resolute run covered a fresh install through stages 0–7,
independent contract checks, a byte/container/service-stable re-run,
Tailscale and Docker restart recovery, firewall re-application, and a full
reboot. Six containers, dual-resolver DNS, Caddy, authenticated/read-only
WebDAV and host DNS all passed. On reboot Tailscale may replace the stage-6
uplink symlink with its direct-mode MagicDNS `resolv.conf`; this is expected
and host DNS remains healthy. Last release: **v2-71** (2026-08-28, tag
`2026.08.06-v2-71`) — pull disk floor, single-pass downloads repair,
plus the v2-65…70 line (**DD-98…101**).

| | |
|---|---|
| Version | `2026.08.06-v2-73` (unreleased) |
| Branch | `quantum` |
| Last tag | `2026.08.06-v2-71` |
| Tests | 82 bats, all green on the workstation |

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- No reconcile / master-compose / iptables-persistent revival.
- `MASTER-INPUT` already accepts Tailscale UDP `${TAILSCALE_UDP_PORT}`
  (**DD-73**); do not treat that as a missing rule.
- No `COMPOSE_PROJECT_NAME` change on provisioned hosts: named volumes
  (`qbit_config`, `wg_easy_data`, …) live under the project-name prefix
  and would be orphaned. The host-wide prune trade-off stays as decided
  in **DD-99**.

### Evaluated and rejected (2026-08-28 review)

- Gating `apt-get install` calls on dpkg state — would silently drop the
  "re-run refreshes docker/tailscale to the current repo version"
  behaviour.
- Timestamp/state gating of the downloads-tree repair — reconcile-engine
  shaped; the single-pass find is the accepted optimization instead.
