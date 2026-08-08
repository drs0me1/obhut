# Session Notes

This file carries context between Claude Code sessions for this
repository. Update it at the end of a working session so the next session
can pick up without re-deriving context.

## Current Task

**`2026.08.06-v2-33` live on `nrm` (DD-75 + pipe-subshell hotfix).**
v2-32/33 re-run + Tailscale/Docker smokes passed 2026-08-09.

Legacy monolith remains under `legacy/install.sh` / root history; active
work is `v2/`.

| | |
|---|---|
| Version (repo + nrm) | `2026.08.06-v2-33` |
| Export | not yet rebuilt for v2-33 |
| Next | commit v2-33 → P1 firewall invariants or P2 package |

### Verified 2026-08-07 (see CHANGELOG `[Unreleased]`)

1. Firewall hardening pack **v2-23…v2-27**: oneshot retry + DOCKER-USER wait;
   PartOf docker+tailscaled; minimal `--check`; drop `watch-tailnet-addr`;
   IPv4-only peer Compose binds.
2. Reboot smoke: fail=0.
3. Natural TS IPv4 change `…61` → `…77`: timer refresh ~1.5 min later;
   Caddy/WebDAV rebound; health 200. **Keep 5 min timer** (operator).
4. Mac exit-node: external IP = nrm WAN `203.0.113.10`; path via
   `ts-forward` + SNAT; not `MASTER-INPUT`.
5. DERP (`fra`) while Mac on hotspot NAT — **not** server firewall
   (`ts-input` 41641 counters live). No tune.

### Operator preferences locked in this session

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- Do not add MASTER-INPUT 41641 (already in `ts-input`).
- No reconcile / master-compose / iptables-persistent revival.

### Next session defaults

- Read `CHANGELOG.md` Unreleased “Live verification of v2-23…v2-27” first.
- `nrm` standing auth still applies for disposable testing.
- Background IP watcher on host may still be at `/tmp/ts-ip-watch.*` from
  this session; safe to kill if leftover.

## Older notes

Pre-v2 Quantum / Q1-* session history was truncated here once the lean v2
line became the active live target. Recover detail from `git log` and
older CHANGELOG sections if needed.
