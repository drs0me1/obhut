# Session Notes

Cross-session continuity for this repository.

## Current Task

**v2-49:** Structural close-out — contract/architecture/rules/SESSION
aligned; Stage 7 asserts Caddy UI sites non-5xx (**DD-88**); portable
export refreshed.

Prior live work on `nrm`: v2-46…48 recovery path + real TS IP change
verified. Repo is v2-only.

| | |
|---|---|
| Version | `2026.08.06-v2-49` |
| Branch | `quantum` |

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- No reconcile / master-compose / iptables-persistent revival.
- `MASTER-INPUT` already accepts Tailscale UDP `${TAILSCALE_UDP_PORT}`
  (**DD-73**); do not treat that as a missing rule.
