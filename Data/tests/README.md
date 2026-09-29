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

## Folder network selection and WAN admission (v2-153, DD-179)

`test_share_manager_networks.py` covers opt-in, schema-2 migration, immutable
credentials/identity/expiry on network edits, public projection, rollback and
interrupted-change recovery. `test_webdav_networks.py` checks scope before
hash/filesystem work, header spoofing, sliding failure windows, bounded tables,
parallel hashes/requests, distinct loopback pools, timeout/abort cleanup and
expect-continue/pipeline behavior. Run on Linux as well: macOS skips the test
that binds the same port on a second loopback address. `share-networks.bats`
checks deployment wiring and conditional firewall/edge limits.

With explicit disposable-host authorization, run from an external client:

```bash
python3 Data/tests/share-networks-live.py --host nrm
```

Only temporary folders/accounts are published, with random credentials kept in
memory/SSH stdin. The test exercises actual WAN and Tailscale Caddy endpoints,
cross-scope refusal, GET/PROPFIND/ranges, RO/RW, forged Host/client-IP, idle TCP
admission, simultaneous-request/login caps, tailnet availability, last-share
pause and timed expiry. WAN ingress packet counters confirm external routing.
Cleanup removes only the fixture prefix/accounts, never existing shares.
Fresh supported-OS installation, reboot and native Infuse/Finder acceptance are
separate; protocol tests do not certify every DAV client.

## Model A and compact App Store (DD-160/DD-161, v2-131)

Serve the real `Data/console` tree locally as below, then run
`node Data/tests/panel-ui.cjs` from the repository root. It applies the actual
Caddy CSP and fixtures all API calls: clean/installed sidebar, removed-page
redirects, qBittorrent lifecycle and own settings, keyboard tabs, five widths,
resource stale/offline/recovery, ZIP create/cancel/nested-unzip/result routes,
and async WireGuard new-network bookmarks. No server is modified.
App Store checks include compact row height, only one details panel, keyboard
focus across polls, real-progress fixtures, failures with details closed,
stop/start/removal and cancellation, default data retention, log HTTP errors
and safe text rendering, no account reads, and visible status at mobile widths.
`test_resources.py` covers independent sampling, guest CPU accounting, unknown
measurements, legacy compatibility and real HTTP Host/header/origin gates.

## qBittorrent integration-only seed (DD-178, v2-152)

Bats requires an exact six-key seed allowlist (startup notice, two download-path
compatibility keys and three authenticated loopback WebUI keys). The module
fixture renders that real seed; reapply and remove/reinstall must preserve user
UPnP/discovery/temporary-path choices byte-for-byte and never apply the firewall.

On an authorized Linux test host with qBittorrent, iproute2 and setpriv installed:

```bash
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/torrent-defaults-linux.py
```

This refuses the host network namespace, starts native qBittorrent as uid 1000
in disposable profiles, and compares the actual seed against application
defaults. It checks loopback/local authentication, download location and native
restart persistence of user choices. No torrents are added, no installed config
is read, no host service is controlled, and fixture passwords are never printed.
It does not replace clean Debian/Ubuntu installation or service-sandbox tests.

## Legacy cleanup boundaries (DD-171)

The Bats suite exercises stage 3 with an absent legacy sharing tree, then with
private existing metadata; reruns must not create markers or repair old modes.
Built-in fixtures also verify marker symlinks and old account files are untouched,
current registry preparation is idempotent and public lifecycle actions refuse.
Retired Files endpoints return 410 only after Host/header/origin checks and never
advertise a fake active empty list. Current folder-sharing tests remain below.
Portable validation should compare the complete embedded file set with runtime
sources, excluding Python caches, metadata, tests, docs and private input.

## Built-in ZIP/RAR (DD-159, DD-166, DD-170)

v143 adds automatic nested extraction/default depth-ceiling rollback tests and
installer-driven default-destination state. The native RAR suite submits without
legacy depth flags. `panel-ui.cjs` checks the compact form, automatic ZIP suffix,
default downloads, folder picker navigation/cancel/read-error/retry and failed
submit draft retention. `files-ui.cjs` checks the bottom selection dock at eight
widths/both themes, stable breadcrumbs/search, hidden-view/selection lifecycle,
and notifications never covering its actions. Run browser suites sequentially
against the simple preview server to avoid parallel request-queue timeouts.
v144 additionally checks six stable icon/label slots, single-file/archive/folder
and mixed-selection eligibility, keyboard focus and activation, download excluding
folders, archive/share/move dialog routing, equal cells, a mobile 3×2 grid and
unfilled danger styling under both themes.

From the repository root, run all Python suites with an OpenSSL-enabled Python:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_*.py'
```

`test_archives.py` covers round trips, nested depth on/off, name collisions,
traversal/links/duplicates, byte/entry/central-directory/deadline limits,
malformed inner archives, cancellation/concurrency and interrupted-job recovery.
`KONSOL_FILES_BACKEND` can point at the installed backend for Linux tests.

`test_rar.py` adds mocked multipart/unsafe-input/budget tests and real subprocess
deadline/cancel/output-cap checks on all hosts. Native RAR→ZIP→RAR is tested on
Linux with `/usr/bin/unrar` and distro `python3-rarfile`; otherwise it is explicitly
skipped. Set `RAR_FIXTURES` to a private directory containing the upstream
markokr/rarfile `test/files` fixtures named by the optional native test to cover
compressed RAR3/RAR5, solid/old/new volumes, Unicode, encryption and link rejection.
Tests copy them into TemporaryDirectory; no downloads or package installs happen
inside tests. Browser fixtures test `.rar`, `.r00`, `.part01.rar` selection and
submission as well as ZIP; ordinary files never offer extraction.

`archives-live.py prepare` is a **mutating disposable-host test** through the
installed Caddy/file service. Keep the printed manifest for `verify <manifest>`
after rerun/reboot and `cleanup <manifest>` afterward. Cleanup removes only its
scratch tree/manifest, retaining ordinary job history as an audit record.

`desktop-live.cjs` tests the **real host**, not fixtures. Set `ARCHIVE_FIXTURE`
to the basename of that live test tree; it creates/extracts browser ZIP outputs.
It checks Model A navigation/resource indicators, built-in shares, settings and five
viewport widths. `TEST_APP_LIFECYCLE=1` explicitly enables qBittorrent
install/stop/start/remove (requires it absent initially, leaves its package and
profile, never requests data deletion). `KONSOL_URL` defaults to `http://panel.ayc/`.
Playwright variables below also apply; screenshots go to a temporary directory.
Do not run live tests against an unauthorized host.

## Settings management (DD-156/DD-157, v2-127)

WireGuard internet-only (DD-177): `wireguard-ui.cjs` tests creation/settings with
no Local selector, DNS-only saves, polling/error/cancel/stopped-network behavior,
explicit regeneration and four widths/CSP. `test_wg_settings.py` rejects legacy
scope on both HTTP routes and checks revision/gates. Bats verifies DNS-only
preservation and rejects old CLI arguments. `test_wg_upgrade.py` tests scoped
retirement, fresh/repeated runs, invalid/pending/symlink/failure boundaries,
opaque key/profile preservation and refusal/filtering of old WG overrides.
`firewall-linux.py` tests actual IPv4/IPv6 host deny (including prior flows),
internet forwarding/NAT, private destinations through WAN, and tailnet isolation.
Veth fixtures pin WG IPv6 neighbors because real WireGuard uses no NDP.

Firewall categories (DD-164, v2-134): `test_firewall_view.py` covers read-only
socket scope classification, IPv6 normalization/zones, read failures, public-only
network metadata, service-name reuse and WAN endpoint versus tunnel permissions.
`settings-ui.cjs` tests default Tailscale, nested keyboard tabs, draft retention,
absent/empty/multiple WireGuard networks, read-only internet-only WG policy, protected
loopback and listener-versus-policy labels (including unknown/unreadable).

Minimum tailnet exposure (DD-172, v2-146): `test_tailnet.py` verifies configured
service ports, validated Self-only PeerAPI discovery and daemon-startup fallback.
The view suite also rejects listener-implies-access and preserves WG endpoints.
Run `unshare --net --fork python3 Data/tests/firewall-linux.py` as root on the
authorized Linux test host. It refuses the host namespace and uses nested veth
clients/echo listeners to test actual IPv4/IPv6 WAN, tailnet and WG input packets,
operator allow/deny precedence, idempotency and extra-rule detection. No installed
service, account or host firewall is modified; all fixtures are temporary.

Tailnet catalogue cleanup (DD-173, v2-147): the view tests exclude arbitrary
peer/backend/admin sockets, retain configured per-family ports even without
listeners, and keep registered WG endpoints with no active peers/sockets.
Browser fixtures preserve explicit tailnet allow/deny rules, editable drafts,
remove/cancel behavior and fallback to default deny without invented port rows.
Live checks must also verify raw diagnostics and required local services remain.

WAN/tunnel catalogue cleanup (DD-174, v2-148): view tests cover configured SSH/
Tailscale ports and IPv4-only WAN WG endpoints independent
of sockets/peer count; retired tunnel permits stay absent. Browser fixtures exercise
explicit allow/deny toggle/remove/cancel for WAN and Tailscale; a closed
user rule remains visible even where no automatic row exists.

Firewall source cleanup (DD-175, v2-149): `firewall-linux.py` additionally starts
from absent module/network files, then verifies preserved networks cannot revive
an absent/empty/stopped module. Test teardown/re-add, no empty forwarding/NAT
chains, repeatability of both tables/families, stale extra INPUT/FORWARD/NAT rules,
unchanged third-party jumps/chains and retained network files. The view suite
covers single-port WG rules and intentionally absent chains versus real failures.
These are isolated policy fixtures, not a fresh Debian/Ubuntu image installation.

DNS-only Apply (DD-163, v2-133): unit tests cover immediate persistence past
the old deadline/reboot, pre-write panel-name protection, mixed confirmation,
restart/commit failure rollback, pre/post-commit crashes and recovery retries.
Browser fixtures assert a single Apply request, no dialog/countdown/confirmation,
reload persistence, failed-apply draft retention and retry. The isolated Linux
DNS test checks immediate commit and failed-apply recovery with real dnsmasq.

Firewall tables (DD-162, v2-132): `settings-ui.cjs` additionally verifies full
semantic tables at five widths, row explanations/source CIDRs, filter/empty
states, protected loopback, on/off drafts, edit/remove, lock during confirmation,
payload/rollback, production CSP and keyboard scrolling without page overflow.

Folder sharing (v2-128, DD-158): also run `python3 -m unittest discover -s
Data/tests -p test_shares.py` and `node Data/tests/files-ui.cjs` from the repository
root. Python must have OpenSSL scrypt (the macOS system Python may not; use an
OpenSSL-enabled Python 3.12+). Linux distribution Python is the production runtime.
The Files UI suite also checks exact share clipboard input and adjacent address/
copy-button geometry in the list and folder details at five widths (v2-138).
Copy APIs are intercepted in fixtures; native iPhone clipboard behavior is not
covered by those checks.
Inline Shares and compact trash (v2-142, DD-169): `files-ui.cjs` checks partial
access/expiry payloads, RW confirmation/cancel/Escape, failed saves, disabled
in-flight controls, account-only editing, eight responsive widths and short
long-filename trash dialogs in both themes. Existing permanent-delete guards
remain tested. `test_shares.py` covers omitted-field preservation, required RW
acknowledgement, rollback and never rebinding a replaced folder via inline edits.
Password policy (v2-141, DD-168): the settings/shares Python and browser suites
reject seven-character passwords and accept eight, preserving blank edits.
`test_shares.py` also verifies real WebDAV GET/PROPFIND authentication and the
read-only write boundary with eight characters. `settings-linux.py` verifies
native qBittorrent login and restart persistence with a disposable eight-character
account inside its private network namespace; it never changes installed accounts.
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
account-only single Save (validation, duplicate blocking, failure/retry, reload,
blank-password preservation, unrelated-draft retention and revision refresh),
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
qBittorrent are real. Account-only save verifies real new/old login results,
restart persistence, failed-commit recovery and stopped-state preservation.
A local upstream fixture verifies forwarding without
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
