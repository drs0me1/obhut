# Tests

Narrow critical-behaviour suite for the lean installer tree. Not a framework
coverage suite.

```bash
cd Data   # from the repository root; paths below are relative to Data/
bats tests
bash -n install.sh common.sh scripts/*
shellcheck -x -s bash install.sh common.sh scripts/*
```

Host acceptance (Debian 13 or supported Ubuntu target, after install) is
separate: DNS loopback vs Tailscale answers, WebDAV PROPFIND/read-only,
firewall `--check`, and the two public UDP ports.

## Pitfall: simulating a fresh Docker install on a provisioned host (up to v2-85)

Since v2-86 no Compose network has a fixed subnet, so this no longer applies;
kept for the record.

Purging Docker (`apt-get purge docker-ce …` and removing `/var/lib/docker`)
does not remove the old dockerd's kernel bridges. They remain until the next
reboot, down and unknown to the new dockerd. Networks with dynamic subnets
avoid them, but the fixed-subnet `wg` network (`WG_BRIDGE_SUBNET` in
`config/defaults.env`) is created a second time on the same range, and the
kernel keeps routing that range through the dead bridge. Stage 7 then fails on
`wg.ayc` with `502` / `connection reset by peer`, a message that points at
Caddy rather than at the duplicate route (**DD-110**).

**Reboot between the purge and the install.** To diagnose, check whether more
than one interface carries the `wg` gateway address
(`ip -o -4 addr show | grep <gateway>`) and which interface
`ip route get <WireGuard address>` chooses.

## Acceptance-check lessons (2026-09-11)

- `tailscale status --json .Self.ExitNodeOption` is **not** an installer
  assertion. It turns true only after the exit node is approved in the admin
  console — the manual step the install summary lists. The installer's own
  obligation is `AdvertiseRoutes` containing `0.0.0.0/0` in
  `tailscale debug prefs`; assert that, and report `ExitNodeOption` as
  information.
- After a reboot, give healthchecks their `start_period` before asserting
  `healthy`. On Debian 13 the host was back 11 s after boot and filebrowser
  reached healthy 8 s later; a check that runs the moment SSH returns will
  report a false failure. Stage 7's own `wait_webdav_healthy` already waits;
  an external check must too.

## Pitfall: an early-exiting pipe consumer under `pipefail` (2026-09-12)

`install.sh` runs with `set -Eeuo pipefail`. A read-back written as
`apt-config dump | awk '/pattern/{print $2; exit}'` looked harmless and
passed every static check, but on the host it aborted the install with exit
141 after all seven stages had run: `awk` exits on the first match,
`apt-config` gets SIGPIPE writing the rest, `pipefail` turns that into 141,
and `set -e` exits at the assignment. Let the consumer read the whole stream
(`{v=$2} END{print v}`) or guard the pipeline with `|| true`, as the `dig |
head -n1 || true` read-backs do. A bats test now rejects `| awk … exit`
patterns in the installer tree.

## Pitfall: a second `tailscaled` on a provisioned host (2026-09-13)

`tailscaled --statedir=DIR` does not isolate a test daemon. `--state` has a
compiled default of `/var/lib/tailscale/tailscaled.state`, so the daemon
loads the production node's identity and preferences. On `nrm` such a daemon
came up `Running` as the production node for a few seconds and rewrote
`/etc/resolv.conf`; the production daemon restored it within the same second
(`trample: resolv.conf again matches expected content`). The state file,
login and prefs were unaffected, and a `BackendState == NeedsLogin` gate
stopped the test before `tailscale up`.

Run test daemons inside a container with the binaries bind-mounted
read-only, pass `--state` explicitly, and gate on `NeedsLogin` before any
`up`.
