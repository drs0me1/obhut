# Session Notes

Cross-session continuity for this repository.

## Current Task

**v2-71 released (2026-08-28):** maintenance cut after the v2-64 GA —
Infuse/WebDAV addressing via Caddy on `TS_IPV4:WEBDAV_PORT` (v2-65…67,
**DD-98**), opt-in image pull with dangling-image prune and a fail-closed
disk floor (v2-68/69/71, **DD-99**/**DD-101**), re-run cost reductions:
gated per-repo `apt-get update` (v2-70, **DD-100**) and a single-pass
downloads repair (v2-71). Nothing is currently unreleased.

| | |
|---|---|
| Version | `2026.08.06-v2-71` |
| Branch | `quantum` |
| Git tag | `2026.08.06-v2-71` |
| Tests | 80 bats, all green on the workstation |

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
