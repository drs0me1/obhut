# Session Notes

Cross-session continuity for this repository.

## Current Task

**v2-48:** Caddy `OnFailure=refresh-tailnet-config.service` (**DD-87**).
`nrm` poison smoke: timer stopped → fail → OnFailure → state fixed +
Caddy active in ~2s.

Also in tree (uncommitted with this unless asked): **v2-46** DD-85,
**v2-47** DD-86.

| | |
|---|---|
| Version | `2026.08.06-v2-48` |
| Branch | `quantum` |
| Next | commit / export when asked |

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- Do not add MASTER-INPUT 41641 (already in `ts-input`).
- No reconcile / master-compose / iptables-persistent revival.
