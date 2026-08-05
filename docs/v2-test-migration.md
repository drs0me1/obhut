# v2 Test Migration Plan

**Status:** classification only, written 2026-08-05. **No existing test file
has been changed, moved or deleted.** All 22 suites and 264 tests in `test/`
still run against the production `install.sh` and must keep passing until v1
is retired.

The current suite is 5409 lines of bats covering 264 tests. Roughly half of
it tests mechanisms that v2 deliberately does not have (canonical bundle,
reconcile engine, cooldown stamps, restore paths). Deleting those tests is
not a loss of coverage — the behaviour they cover is itself being removed —
but deleting them *early* would remove coverage from the installer that is
still in production. Hence the four classes below, and the rule that
class C and class D only take effect when v1 is retired.

## Classes

| Class | Meaning | Action now |
|---|---|---|
| **A — direct migration** | Tests a behaviour v2 keeps, in a form that survives the move; only the extraction harness changes | Copy to `v2/tests/`, repoint at the standalone script |
| **B — rewrite** | Tests a behaviour v2 keeps, but the mechanism, chain names or expected rule set changed; some are *inverted* (v2 must **not** do what v1 did) | Rewrite for the v2 contract |
| **C — legacy only** | Tests a v1 mechanism that stays in production until v1 retires | Leave untouched; repoint at `legacy/install.sh` at retirement, or delete then |
| **D — remove** | Tests a mechanism v2 removes and v1 will not need after retirement | Nothing now; delete with v1 |

**Every file name in the classification below is a real file in `test/`, and
every quoted `@test` name is a real test case.** Nothing here is estimated or
invented. The one exception is clearly marked: the *proposed* v2 suite names
in "New suites v2 needs", which do not exist yet and are naming suggestions,
not existing files.

**Classification is per test case, not per file.** A suite is only assigned
to a single class when every case in it belongs there. Eight of the 22 files
mix behaviours that v2 keeps with behaviours it removes, and putting such a
file wholesale in one class would either drag dead mechanisms into v2 or
throw away a test that still guards something real. Those eight are listed
case by case in the next section.

## Harness change that affects every migrated test

Every current suite extracts a heredoc out of `install.sh` before it can
test anything, e.g.:

```bash
sed -n "/<<'GRO_SCRIPT'$/,/^GRO_SCRIPT$/p" install.sh | sed '1d;$d' > "$script"
```

In v2 the same script is a real file at `v2/scripts/tailscale-udp-gro`, so
the extraction step disappears and the suite sources or runs the file
directly. That is the entire diff for a class A test. It also makes
`scripts/lint-embedded-scripts.sh` unnecessary for v2 — `shellcheck` sees
these files natively.

---

## Files that must be split at test-case level

These eight files cannot be classified as a unit. The counts are actual
`@test` counts, and the case names are quoted verbatim from the files.

| File | Cases | Keep (migrate or rewrite) | Drop with the mechanism |
|---|---|---|---|
| `firewall_functions.bats` | 27 | 24: the `route_value` (4), `resolve_wan_ipv4` (3), `wait_for_wan_ipv4` (2), `chain_rules_exact` (3), `jump_is_first_and_single` (4), `no_stale_staging_chains` (3), `docker_forward_has_no_terminal_drop` (3) groups, plus the two `docker-tailscale-fw:` cases | 3: `forward_prefix_is_exact` — the expected prefix is defined by v1's chain layout and has no v2 counterpart until the new layout exists |
| `policy_functions.bats` | 17 | 16, all rewritten against the v2 chain set | 0 dropped, but **1 inverted**: `"check_ipv4_policy: rejects an extra rule appended to DOCKER-USER"` becomes its own opposite (see B2) |
| `compose_address_binding.bats` | 8 | 5: `"both present are both recorded"`, `"a missing Tailscale address does not block the stack"`, `"a missing WAN address still fails closed"`, `"no leftover temp file when the WAN wait fails"`, `"compose_env_addresses_current: true only when both lines match"` | 3: the `"reconcile: …"` cases — `"only a public address change forces a stack restart"`, `"a stale address record is refreshed without a stack restart"`, `"the three host services still repair on a Tailscale change"`. Their intent moves to N2 against `refresh-tailnet-config` |
| `reconcile_probes.bats` | 36 | 19: the `forwarding_config_ok` group (10) and the `gro_flags_ok` group (9). Both assert facts v2 still verifies once, in stage 7 | 17: `port_binding_exists` (6), `docker_network_tuple` (5), `record_container_restart` (6) — container probing, network-tuple inspection and cooldown stamps, all removed by decisions 13–14 |
| `quantum_config_repair.bats` | 11 | 1: `"installer recreates filebrowser when generated policy changes"`, rewritten as ordinary idempotent installation | 10: every case testing the *repair* path — drift replacement, directory-to-file conversion, container removal, staging cleanup, daemon-failure discrimination, and `"generic runtime recovery recreates FileBrowser instead of restarting a stale mount"` |
| `wait_deadlines.bats` | 5 | 3: `"master-webdav-serve: its wait ends on the clock, not on a count"`, `"Stage 2's tailscaled socket wait is bounded by a deadline"`, `"no iteration-counted loop promises a duration"` (broadened to scan `v2/scripts/` and `v2/lib/`) | 2: `"master-compose-ipv4: its wait ends on the clock, not on a count"` and `"reconcile: the address-ready wait is bounded by a deadline"` — neither script exists in v2 |
| `generated_files_bundled.bats` | 6 | 1 in spirit: `"every bundled source is a file install.sh actually generates"` becomes a template-coverage test | 5: everything naming the bundle, the exclusion allowlist, the sha256sum list or the `current` pointer — `"every generated file is either bundled or explicitly excluded"`, `"no stale entries on the exclusion allowlist"`, `"nothing is both bundled and excluded"`, `"the canonical publish and the sha256sum list name the same files"`, `"canonical publication verifies a generation before swapping current"` |
| `media_tree_chown.bats` | 3 | 0 as written — but the fixture is reused. All three assert that v1's recursive `chown` is symlink-safe; v2 does not run one, so the property to test is different (see B4). The planted-symlink fixture from `"find selects the planted symlink (the hazard is real)"` becomes the fixture for the v2 assertion | 3 as assertions |

The remaining 14 files are uniform and take a single class: six in A, five in
C, three in D.

## Class A — direct migration (6 suites, 42 tests)

| Suite | Tests | Covers | Note |
|---|---|---|---|
| `gro_functions.bats` | 5 | `add_default_netdev`: default-route device detection, deduplication, empty/malformed `ip` output | **UDP GRO interface detection is preserved verbatim** (decision 21). Source becomes `v2/scripts/tailscale-udp-gro` |
| `retry_network.bats` | 5 | `retry_network`: immediate success, exhaustion, timeout distinguished from command failure, late recovery, argument pass-through | **Network retry preserved.** Moves to `v2/lib/common.sh`; the timeout-vs-failure distinction is the load-bearing part |
| `tailscale_login.bats` | 14 | Bounded login attempts, `auth_path_dead` classification, daemon reset between attempts, URL re-emission | **The 410 login recovery** (decision 20). The single most valuable suite in the repository — it encodes a real incident |
| `tailscale_journal.bats` | 3 | Journal classification of `node not found` / auth-path failures | Companion to the above |
| `tailscale_online_gate.bats` | 7 | `BackendState=Running` + `Self.Online` gate, malformed JSON, missing fields | Keeps the stack from being built against a half-registered node |
| `tailscaled_job_isolation.bats` | 8 | The login restart does not drag dependent units with it | Directly supports "a Tailscale restart must not restart the Compose stack" |

For all six, the assertions are unchanged; only the setup changes.

---

## Class B — rewrite (8 suites)

### B1. `firewall_functions.bats` (27 tests) — mostly survives

Keep and repoint:

- `route_value` (4 tests) — moves to `v2/lib/network.sh`, which becomes the
  only place a route is parsed. These four tests move with it.
- `resolve_wan_ipv4` (3), `wait_for_wan_ipv4` (2) — same move; the
  wall-clock deadline assertion is kept as is.
- `chain_rules_exact` (3), `jump_is_first_and_single` (4) — the helpers
  survive; the **expected rule sets change** because the chain layout does.
- `no_stale_staging_chains` (3) — **staging-chain logic is preserved**
  (decision 22), so these are kept and extended to the new `MASTER-INPUT`
  staging chain.
- `--check` never enters a waiting path (2) — keep.

Rewrite:

- `forward_prefix_is_exact` (3) — the prefix changes with the new chain set.
- `docker_forward_has_no_terminal_drop` (3) — keep the intent (v2 must not
  put a terminal DROP in a Docker-owned chain) against the v2 chain names.

New in this suite:

- `MASTER-INPUT` staging chain is swapped atomically, and an
  `ESTABLISHED,RELATED` accept precedes the WAN drop — i.e. **the active SSH
  session survives**.

### B2. `policy_functions.bats` (17 tests) — rewrite around the new contract

The helper shape (`check_ipv4_policy` / `check_ipv6_policy` fed a fake
`iptables-save`) is exactly right and is kept. The expected policies change:

Kept in spirit, rewritten in detail: terminal WAN DROP present; mangle jump
first; no duplicated `DOCKER-USER` jump; no leftover staging chain in either
table; no terminal DROP inside a Docker-owned chain; IPv6 accepted both with
and without an IPv6 WAN; a specific diagnostic when `ip6tables` is missing
(never a silent IPv4-only degradation).

**Inverted — `"rejects an extra rule appended to DOCKER-USER"`.** In v1 an
extra `DOCKER-USER` rule was drift to be flagged and removed. In v2,
**third-party `DOCKER-USER` rules must be preserved** (decision 23), so the
v2 test asserts the opposite: after applying the policy, a third-party rule
planted in `DOCKER-USER` before the run is **still present**, and the
`MASTER-DOCKER` jump is still first and singular. This inversion is the
single most important behavioural change in the firewall and needs its own
test, not a modified assertion inside another one.

Kept and made stricter: `"rejects a resurrected narrow WebDAV allow"` — v2
must contain **no WAN permission for WebDAV at all**, in either address
family, because WebDAV is reachable purely through the blanket `tailscale0`
accept (contract §7.5).

New in this suite:

- No rule anywhere permits public **TCP** to `${QBIT_PUBLIC_PORT}`
  (decisions 9–10).
- Exactly two WAN accepts exist, both UDP.
- Docker's own chains are unchanged in name, count and order after the run.

### B3. `compose_address_binding.bats` (8 tests) — split

- Keep, rewritten: both addresses recorded; a missing WAN address still
  **fails closed**; no leftover temporary file when the wait fails.
- Rewrite: `"a missing Tailscale address does not block the stack"` — still
  true in v2 and worth keeping, since no container binds to the Tailscale
  address.
- **Drop the three `reconcile:` tests.** They test
  `master-network-reconcile`, which does not exist in v2. Their *intent* —
  "a Tailscale address change does not restart the stack" — moves to a new
  test against `refresh-tailnet-config` (see New Suites, N2).

### B4. `media_tree_chown.bats` (3 tests) — inverted

v1's three tests assert that its recursive `chown` is symlink-safe (`-h`,
non-dereferencing). v2 does not run an unconditional recursive `chown` at
all (decision 24), so symlink safety is not the property to test.

The v2 test asserts the stronger property: **a run against an existing
`/downloads` tree performs no recursive ownership change** — plant files
with foreign ownership, run the directory stage, assert the ownership is
untouched and that only newly created directories were chowned. The
symlink-hazard fixture from the v1 suite is worth reusing as the fixture
for that assertion.

### B5. `wait_deadlines.bats` (5 tests) — rewrite, keep the meta-test

The property — **no wait promises a duration while counting iterations** —
is the reason three v1 timeout bugs were caught, and it must survive.

- Keep: `master-webdav-serve`'s wait ends on the clock (its v2 equivalent
  resolves the Tailscale IPv4 with a bounded wait at start).
- Keep: Tailscale socket wait bounded by a deadline.
- Keep and broaden: `"no iteration-counted loop promises a duration"` — in
  v2 it scans all of `v2/scripts/` and `v2/lib/` rather than extracted
  heredocs, which makes it stronger and cheaper.
- Drop: the `master-compose-ipv4` and `reconcile` cases; neither script
  exists in v2.

### B6. `reconcile_probes.bats` (36 tests) — salvage two groups, drop three

Two of its five probe groups test facts v2 still asserts, in stage 7's
one-shot verification rather than on a timer:

- `forwarding_config_ok` (10 cases) — the forwarding sysctls are enabled
  (**R6**). Migrates nearly as is, including the ownership/mode case.
- `gro_flags_ok` (9 cases) — the UDP GRO flags are actually set. Migrates,
  but **shrinks**: five of the nine assert that the probe reports *healthy*
  when it cannot tell (`"healthy when ethtool is not installed"`,
  `"healthy when the WAN interface has not been detected"`, `"healthy when
  the driver reports neither feature"`, `"healthy when the driver reports
  only one of the two"`, `"healthy when ethtool fails on the interface"`).
  That leniency existed so a drift engine would not restart things on
  incomplete information. A one-shot verification has the opposite duty: it
  should *report* that it could not confirm the flags. So those five become
  one case asserting the check reports "unverified", not "healthy".

The other three groups go with the engine: `port_binding_exists` (6),
`docker_network_tuple` (5), `record_container_restart` (6).

### B7. `generated_files_bundled.bats` (6 tests) — replaced by a template test

v1's version asserts that every generated file is registered in the
canonical bundle. There is no bundle in v2. The equivalent guard for a
template-based installer is worth having, so this becomes one small test:
**every file under `v2/templates/` is rendered by `install.sh`, and every
rendered target has a template** — i.e. no orphan template, no inline
heredoc that escaped the template directory. Add a second: **rendering
leaves no unsubstituted `__TOKEN__` in the output.**

### B8. `quantum_config_repair.bats` (11 tests) — one test survives

Ten of the eleven test the *repair* path: drift detection, container
removal, staging cleanup, recreation through Compose. None of it exists in
v2 (no file restore, no container self-healing).

The one that survives is `"installer recreates filebrowser when generated
policy changes"`, rewritten as: **the installer writes the FileBrowser
policy file and recreates the container when the rendered policy actually
changed** — which is normal idempotent installation, not self-healing.

---

## Class C — legacy only (5 suites, 61 tests)

These test v1 mechanisms that stay in production until v1 is retired. Leave
them exactly as they are. At retirement they are deleted along with the
mechanism; there is no v2 counterpart to repoint them at.

| Suite | Tests | Mechanism |
|---|---|---|
| `dns_stack_rollback.bats` | 7 | The DNS/Caddy rollback state machine. v2 keeps only fail-closed masking, which needs one test, not seven |
| `onfailure_arc.bats` | 10 | `OnFailure=` → recovery-unit arcs. v2 has no repair engine, so no unit carries `OnFailure=` |
| `canonical_stage_cleanup.bats` | 11 | Canonical staging-directory cleanup |
| `reconcile_control_flow.bats` | 15 | Reconcile lock, cycle ordering, exit-code contract |
| `compose_runtime_probe.bats` | 18 | `probe_compose_runtime` and its restart decisions |

`compose_runtime_probe.bats` currently has uncommitted local modifications;
those belong to v1 and should be finished or reverted on their own terms,
independently of this migration.

---

## Class D — remove at v1 retirement (3 suites, 48 tests)

Same handling as class C — untouched now, deleted with v1 — listed
separately because these cover mechanisms the architectural decisions
explicitly forbid re-testing in v2.

| Suite | Tests | Mechanism forbidden in v2 |
|---|---|---|
| `canonical_bundle.bats` | 12 | Canonical generation, `SHA256SUMS` manifest, `current` pointer (decision 11) |
| `canonical_bundle_degrade.bats` | 8 | Degraded-bundle handling; nothing to degrade |
| `reconcile_functions.bats` | 28 | Cooldown stamps, restart accounting, digest recovery, drift flags (decisions 12–15) |

---

## Explicitly do **not** write v2 tests for

Per the architectural decisions. Each of these has a test in `test/` today;
none gets a v2 counterpart, and a future contributor adding one is
reintroducing a removed mechanism.

- qBittorrent public **TCP** publication or TCP firewall permission — the
  v2 test asserts its **absence**, never its behaviour.
- Canonical generation directories, the `current` pointer, generation
  rotation.
- `SHA256SUMS` manifests, bundle verification, automatic file restore.
- Restart cooldown stamp files, and the stamp exemptions layered on them.
- General container self-healing / health-probe-driven restarts.
- Image-digest-based recovery decisions.
- `master-compose.service` at all, and specifically its
  `PartOf=tailscaled.service` coupling. The v2 test asserts the *outcome*
  (restarting `tailscaled` leaves the containers running), not the unit.
- The 25 reconcile `--check` drift flags.
- WebDAV being continuously audited by a general reconcile engine.
- WebDAV restart cooldown stamps.
- Disk/inode thresholds and default-password auditing.

---

## New suites v2 needs (nothing in `test/` covers these)

**The file names in this section are proposals, not existing files.** No
file named below exists in `test/` or `v2/tests/` today; they are named here
so the phases have something to refer to. Every file name in the
classification *above* is real.

### N1. `webdav_contract.bats`

WebDAV has, remarkably, **no unit test at all** today despite being a core
feature. The v2 suite covers, once each:

1. The resolved listen address is `${TS_IPV4}:${WEBDAV_PORT}` — and the
   service refuses to start bound to `0.0.0.0`, the WAN address, or a LAN
   address.
2. An unauthenticated request returns **`401`**.
3. A `PROPFIND` with valid credentials **succeeds**.
4. `/downloads/media`, `…/movies`, `…/series` are listable.
5. A write attempt (`PUT`/`MKCOL`/`DELETE`) is **refused** — read-only is
   enforced, not assumed.
6. The credential file is `0600`, `root:root`, and the password appears in
   no log, no argument list and neither `config.env` nor `state.env`.
7. A re-run **preserves** an existing credential file.
8. The serve invocation never receives the password as an argument.

Items 2–5 are end-to-end and need a running service, so they belong in the
live Tier 3 checklist as well as here; the static half (1, 6, 7, 8) is
unit-testable against the generated unit and script.

### N2. `refresh_tailnet.bats`

1. An unchanged address is a no-op — nothing is restarted.
2. A changed Tailscale IPv4 updates `state.env`, re-prepares Caddy, and
   restarts `master-webdav`.
3. A changed Tailscale IPv4 restarts **no container** — the successor to the
   dropped `compose_address_binding` reconcile tests, and the test that
   guards decision 19.
4. The helper touches nothing else: no container inspection, no file
   comparison, no disk check.

### N3. `host_input_policy.bats`

The host `INPUT` policy is new in v2 and has no v1 counterpart:

1. Loopback accepted.
2. `ESTABLISHED,RELATED` accepted, and ordered **before** the WAN drop.
3. All inbound on `tailscale0` accepted, as a class, with no per-service
   rules.
4. Exactly the two WAN UDP ports accepted.
5. Every other new WAN inbound dropped.
6. IPv6 `INPUT` fail-closed with the same shape.
7. No WAN permission exists for WebDAV, Caddy, dnsmasq or any container UI.

### N4. `caddy_dnsmasq_contract.bats`

1. All six service names appear in both the dnsmasq and the Caddy render,
   from one shared list — a name in one and not the other is a failure.
2. Every Caddy site is explicitly `http://`; no ACME or TLS directive exists.
3. Caddy's bind address is the Tailscale IPv4 and nothing else.
4. dnsmasq answers only for `${LOCAL_DOMAIN}` and is not a forwarder.
5. `webdav.${LOCAL_DOMAIN}` proxies to the WebDAV upstream (the Caddy
   hostname path from the contract).
6. Container upstreams are loopback addresses only.

### N5. `single_source_of_truth.bats`

The guard that keeps v2 from re-growing v1's divergence risk: **no port
number, container name, image reference or chain name appears as a literal
more than once outside `config/defaults.env`.** A grep-based test, cheap to
run, and it fails the moment someone hard-codes `65173` in a second place.

### N6. `idempotency.bats`

Static half of **R20**: every generated file is written through the same
atomic render-and-install helper, with an explicit owner and mode, and no
stage performs an unconditional destructive or expensive operation. The
byte-for-byte second-run comparison remains a live Tier 3 check.

---

## Summary

| Class | Suites | Cases | When |
|---|---|---|---|
| A — direct migration | 6 | 42 → 42 | With the phase that lands the corresponding script |
| B — rewrite, split per case | 8 | 113 → 70 kept | With the phase that lands the corresponding script |
| C — legacy only | 5 | 61 | Deleted at v1 retirement |
| D — remove | 3 | 48 | Deleted at v1 retirement |
| N — new (proposed names) | 6 | — | Written alongside the feature, not after |
| **Current total** | **22** | **264** | **unchanged today** |

So 112 of the 264 existing cases carry forward in some form (42 + 70), and
152 are dropped along with the mechanisms they cover: 43 from the split
files, 61 in class C, 48 in class D. The drop is not a coverage loss — it is
the test surface of the canonical bundle, the reconcile engine, the cooldown
stamps and the repair paths, none of which v2 has. The six new suites cover
ground v1 never tested at all, WebDAV most notably.

The nine behaviours the decisions single out for preservation map as
follows, and none of them may regress:

| Behaviour to preserve | Where it lands |
|---|---|
| Tailscale 410 login recovery | A: `tailscale_login.bats`, `tailscale_journal.bats` |
| Network retry | A: `retry_network.bats` |
| UDP GRO interface detection | A: `gro_functions.bats` |
| Firewall staging-chain logic | B1: `no_stale_staging_chains` + new `MASTER-INPUT` staging test |
| Third-party `DOCKER-USER` rules preserved | B2, inverted assertion — new test |
| WebDAV `401` without credentials | N1 |
| WebDAV `PROPFIND` with valid credentials | N1 |
| WebDAV read-only enforcement | N1 |
| WebDAV listens only on the Tailscale IPv4 | N1 |
| `webdav.${LOCAL_DOMAIN}` through Caddy | N4 |
