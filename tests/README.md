# Tests

Narrow critical-behaviour suite for the lean installer tree. Not a framework
coverage suite.

```bash
bats tests
bash -n install.sh common.sh scripts/*
shellcheck -x -s bash install.sh common.sh scripts/*
```

Host acceptance (Debian 13 or supported Ubuntu target, after install) is
separate: DNS loopback vs Tailscale answers, WebDAV PROPFIND/read-only,
firewall `--check`, and the two public UDP ports.

## Pitfall: simulating a fresh Docker install on a provisioned host

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
`ip route get <wg-easy address>` chooses.

