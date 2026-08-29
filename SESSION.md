# Session Notes

Cross-session continuity for this repository.

## Current Task

**v2-72 in [Unreleased] (2026-08-29):** Ubuntu 24.04/26.04 LTS support —
`require_supported_os` matrix, repo lines from `os-release`, ufw gate,
resolv.conf stub repoint, dpkg-lock wait (**DD-102**). **Live-verified
on noble:** `nrm` was reimaged to a clean Ubuntu 24.04.4 host and a
full v2-72 install passed stages 0–7 plus independent post-checks
(firewall --check, 6/6 containers, dual-resolver DNS, Caddy health,
WebDAV 401 ×3, resolv.conf repoint, host DNS intact). Resolute (26.04)
remains statically verified only. Last release: **v2-71** (2026-08-28, tag
`2026.08.06-v2-71`) — pull disk floor, single-pass downloads repair,
plus the v2-65…70 line (**DD-98…101**).

| | |
|---|---|
| Version | `2026.08.06-v2-72` (unreleased) |
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
