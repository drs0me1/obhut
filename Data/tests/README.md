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

## Desktop and ZIP (DD-159, v2-129)

From the repository root, run all Python suites with an OpenSSL-enabled Python:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_*.py'
```

`test_archives.py` covers round trips, nested depth on/off, name collisions,
traversal/links/duplicates, byte/entry/central-directory/deadline limits,
malformed inner archives, cancellation/concurrency and interrupted-job recovery.
`KONSOL_FILES_BACKEND` can point at the installed backend for Linux tests.

`archives-live.py prepare` is a **mutating disposable-host test** through the
installed Caddy/file service. Keep the printed manifest for `verify <manifest>`
after rerun/reboot and `cleanup <manifest>` afterward. Cleanup removes only its
scratch tree/manifest, retaining ordinary job history as an audit record.

`desktop-live.cjs` tests the **real host**, not fixtures. Set `ARCHIVE_FIXTURE`
to the basename of that live test tree; it creates/extracts browser ZIP outputs.
It checks launcher/dock/window controls, built-in shares, settings and five
viewport widths. `TEST_APP_LIFECYCLE=1` explicitly enables qBittorrent
install/stop/start/remove (requires it absent initially, leaves its package and
profile, never requests data deletion). `KONSOL_URL` defaults to `http://panel.ayc/`.
Playwright variables below also apply; screenshots go to a temporary directory.
Do not run live tests against an unauthorized host.

## Settings management (DD-156/DD-157, v2-127)

Folder sharing (v2-128, DD-158): also run `python3 -m unittest discover -s
Data/tests -p test_shares.py` and `node Data/tests/files-ui.cjs` from the repository
root. Python must have OpenSSL scrypt (the macOS system Python may not; use an
OpenSSL-enabled Python 3.12+). Linux distribution Python is the production runtime.
`shares-live.py prepare` is a **mutating disposable-host test**, using installed
services, two scratch accounts and a random folder. Keep its printed manifest
path for `verify <manifest>` after rerun/reboot and `cleanup <manifest>` afterward.
It does not certify Finder/Infuse clients or Tailscale recipient ACLs.

From the repository root:

```bash
LC_ALL=C PYTHONDONTWRITEBYTECODE=1 bats Data/tests/common.bats
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p test_settings.py
python3 -m http.server 8766 --bind 127.0.0.1 --directory Data/console
# In a second terminal, with Playwright installed:
node Data/tests/settings-ui.cjs
```

`PLAYWRIGHT_MODULE`, `PLAYWRIGHT_CHROMIUM` and `KONSOL_URL` may override the
module, browser executable and preview URL. The test intercepts APIs with
fixtures; it never modifies a server. It covers tabs, review/discard, custom
rules, DNS, credentials/folder, confirmation/rollback, address explanations,
domain review/new-address links/old-host confirmation refusal, four widths and dark
mode. Screenshots go to a fresh temporary directory.

On a Linux test host with root, iptables/ip6tables, dnsmasq, dig, qBittorrent
and systemd (no additional packages are installed by these tests):

```bash
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/settings-linux.py
PYTHONDONTWRITEBYTECODE=1 python3 Data/tests/settings-systemd.py
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/settings-domain-linux.py
```

The first refuses the host network namespace, uses scratch profiles and
dummy interfaces, and substitutes only service control; firewall, DNS and
qBittorrent are real. A local upstream fixture verifies forwarding without
internet access and proves private names are not forwarded. The second uses
real transient systemd work/timer units with a scratch pending record and no
firewall/DNS/qBittorrent changes. Both remove only their own scratch state.
These checks do not replace a fresh Debian/Ubuntu installer acceptance run.

`settings-domain-linux.py` needs Caddy, dnsmasq, dig, curl, setpriv and Python,
but not qBittorrent. It starts the real Caddy and both production API backends
against scratch files, with private DNS/network interfaces. It checks domain
apply/rollback/confirm, real Caddy reload, both Host/header gates, retired health
content, persisted domain and staged templates. Only systemctl is adapted to
those processes; host services and their settings are never touched. Unit tests
also cover timeout/reboot/crash recovery, state IP preservation, invalid suffixes,
stale renderings, inactive services and installer saved-domain readback.

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
