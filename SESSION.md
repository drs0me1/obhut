# Session Notes

Cross-session continuity for this repository.

## Current Task

**Repo is v2-only.** Legacy v1 trees (`install.sh`, `legacy/`, `versiyon/`,
root `test/`, root `scripts/`, `SECURITY_REVIEW.md`, `TODO.md`, and
v1-centric docs) were removed. Active work is `v2/`.

| | |
|---|---|
| Version | `2026.08.06-v2-45` |
| Branch | `quantum` |
| WebDAV | Compose loopback → Caddy (DD-77+) |
| Next | operator-driven |

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- Do not add MASTER-INPUT 41641 (already in `ts-input`).
- No reconcile / master-compose / iptables-persistent revival.

### Next session defaults

- Read `CHANGELOG.md` `[Unreleased]` and `docs/v2-contract.md` first.
- `nrm` standing auth still applies for disposable testing.
- Portable export: `v2/dev/export-v2.sh` (rebuild after shipping changes;
  `v2/app/` may lag `V2_VERSION` until the next export).
