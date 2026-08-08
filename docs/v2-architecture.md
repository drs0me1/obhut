# v2 Architecture

**Status:** architecture for the lean `v2/` tree (updated 2026-08-09).
Read [`v2-contract.md`](v2-contract.md) first — that document says *what* v2
does; this one says *where each part of it lives* and *how data moves*.
Operator entry point: [`v2/README.md`](../v2/README.md).

v1's structural problem was not its size but its ownership model: the same
fact (a port number, a container name, an expected binding) was asserted in
three or four places, and the same decision (is this healthy?) was made by
the installer, by a helper and by a final test. v2's rule is one owner per
fact and one owner per decision.

---

## 1. Data flow

```
                     operator input
                   (domain, downloads path,
                    WebDAV user + password)
                            │
                            ▼
              ┌──────────────────────────────┐
              │  /etc/master-stack/config.env│   persistent choices
              │  (rendered from              │   survives re-runs
              │   v2/config/defaults.env)    │
              └──────────────┬───────────────┘
                             │
                             ▼
                    address detection
                    (v2/install.sh + refresh-tailnet-config)
              WAN if + WAN IPv4, tailscale0
                    IPv4 + IPv6
                             │
                             ▼
              ┌──────────────────────────────┐
              │  /etc/master-stack/state.env │   detected runtime facts
              │  (regenerated every run and  │   never hand-edited
              │   by refresh-tailnet-config) │
              └──────────────┬───────────────┘
                             │
        ┌────────────┬───────┴────────┬──────────────┐
        ▼            ▼                ▼              ▼
    compose.yaml  dnsmasq conf     Caddyfile     firewall
                  (lo +          (TAILSCALE_    (in memory)
                   tailscale0)    IPV4:80)
        │            │                │              │
        ▼            ▼                ▼              ▼
   6 containers   dnsmasq         caddy         MASTER-INPUT
   (incl. webdav  .service        .service      MASTER-DOCKER
    on loopback)
```

Only Caddy reads the Tailscale address. dnsmasq and the firewall are
written against the *interface name*, and WebDAV binds loopback only
(**DD-77**). That is what makes an address change a Caddy-only restart
rather than a stack-wide one (§5).

The WebDAV **password** does not appear anywhere in this diagram after the
first arrow. It is hashed immediately into a separate credential file; see
§4.

---

## 2. `config.env` versus `state.env`

Two files, two lifetimes, two owners. Conflating them is what made v1's
`state.env` carry both a schema version and a frozen `WG_ENDPOINT_HOST` that
later became a permanent drift alarm.

| | `config.env` | `state.env` |
|---|---|---|
| **Path** | `/etc/master-stack/config.env` | `/etc/master-stack/state.env` |
| **Contains** | Choices: local domain, downloads path, timezone, `WG_PUBLIC_PORT`, WebDAV port | Detected facts: WAN interface, WAN IPv4, `TAILSCALE_IPV4`, `TAILSCALE_IPV6`, install version; `WG_ENDPOINT_HOST` is a derived hint equal to current `WAN_IPV4` (not an operator prompt) |
| **Source** | `v2/config/defaults.env` + operator answers | installer / `refresh-tailnet-config` at run time |
| **Written by** | The installer, once per run | The installer, and `refresh-tailnet-config` when an address changes |
| **Lifetime** | Persistent; a re-run offers the previous value as the default | Regenerated freely; nothing in it is a decision |
| **Hand-editable** | Yes, by an operator who then re-runs the installer | No — it will be overwritten |
| **Read by** | The installer, template rendering | The installer, `master-firewall`, Caddy (`EnvironmentFile=`), `refresh-tailnet-config` |
| **Contains secrets** | **No** | **No** |

Practical consequence: changing a port is editing `config.env` and re-running.
Changing an address is not a human action at all — detection handles it.

**Why v1's frozen `WG_ENDPOINT_HOST` is not repeated:** a detected value
recorded in a file and then compared against reality on every cycle produces
a permanent failure the moment the provider changes the IP. In v2 the
public IPv4 lives in `state.env` as a *current* fact that is simply
re-detected, never as an expectation to be violated.

---

## 3. File responsibilities

### 3.1 Repository layout

```
v2/
├── README.md                      operator / export entry
├── .cursor/rules/master-stack.mdc v2-scoped Cursor rules (not shipped to host)
├── install.sh                     orchestration
├── common.sh                      logging, guards, file writing, rendering
├── config/defaults.env            single source of truth for constants
├── templates/                     compose.yaml, Caddyfile, dnsmasq.conf
├── scripts/                       installed to /usr/local/sbin (firewall.sh → master-firewall, …)
├── systemd/                       units (firewall, GRO, refresh timer)
├── app/<V2_VERSION>.command       versioned portable install apps (export output)
├── app/latest.command             most recent export
├── dev/export-v2.sh               build the portable install app (+ .command wrapper)
└── tests/                         bats suites (not on host)
```

`.cursor/rules/` is a pre-existing component of this tree, not something the
refactor created, and it is scoped to `v2/` on purpose: the rules describe
how to build v2 and must not be applied to `legacy/install.sh`, which is
frozen for reference only. It ships no runtime behaviour — nothing installs
it, nothing reads it at run time — so it appears in the repository layout
and nowhere in §3.4's host layout.

One rule set, one active file:

| Path | Role |
|---|---|
| `v2/.cursor/rules/master-stack.mdc` | **The active source.** Plain text with `globs: v2/**` frontmatter, so Cursor actually loads it. Edits to the rules go here and only here. |
| `docs/archive/master-stack-rules-source.rtf` | **Archive.** The operator's original RTF, byte-for-byte, kept as the historical record. Never edited, never loaded. |

The `.rtf` moved out of `.cursor/rules/` because Cursor never parses it as
a rule, and a rule file sitting beside the real one invites edits that
silently do not apply. There is deliberately **no synchronisation
mechanism and no test** comparing the two: the archive is a snapshot of
what was first written, not a second copy of the truth, and it is expected
to fall behind as the `.mdc` evolves.

Three documents govern v2, and they are not interchangeable:

| Source | Governs |
|---|---|
| `v2/.cursor/rules/` | How to work: process, Bash conventions, per-phase verification, the hard "do not" list |
| `docs/v2-contract.md` | What the result must do, and the success criteria |
| `docs/v2-architecture.md` | Where each part lives and how data moves |

Where they overlap they agree. Where the rules file is silent — it predates
the WebDAV decisions and does not mention WebDAV at all — the contract
extends it rather than contradicting it. Genuine disagreements are recorded
in §10, not resolved silently.

### 3.2 One sentence per file

| File | Single responsibility | Deliberately does not know |
|---|---|---|
| `.cursor/rules/master-stack.mdc` | Carry the v2-scoped working rules for any AI assistant editing this tree — the single active, editable rule source | Anything about runtime behaviour — it is never installed to the host and never read by the installer |
| `install.sh` | Ask the operator, call the stages in order (including address detection), print the summary | What a firewall rule looks like, what Caddy syntax is |
| `common.sh` | Logging, error trapping, the root/OS gates, the stack lock, bounded network retry, atomic file installation, template rendering | Any stack-specific fact |
| `config/defaults.env` | Declare every constant exactly once: ports, container names, image references, paths, chain names, interface name | How any of them is used |
| `templates/compose.yaml` | The six services (incl. loopback WebDAV), volumes, port publications | Where it is written, which addresses are current |
| `templates/Caddyfile` | Six HTTP sites and their loopback upstreams | The Tailscale address (read as `{$TAILSCALE_IPV4}` from `state.env` at daemon start) |
| `templates/dnsmasq.conf` | Six `interface-name` records and the fail-closed resolver posture on `lo` + `tailscale0` | The current address (`bind-dynamic` tracks it) |
| `scripts/tailscale-udp-gro` | Set the two ethtool flags on the default-route interfaces | Tailscale itself |
| `scripts/firewall.sh` → `master-firewall` | Build and atomically install `MASTER-INPUT` and `MASTER-DOCKER`; `--check` verifies jumps, `ts-input` order, and a short IPv4 ACCEPT/DROP set | Containers, DNS, WebDAV, and the Tailscale *address* — it matches the interface |
| `scripts/refresh-tailnet-config` | Detect a Tailscale address change, update `state.env`, restart Caddy — nothing else | Container health, file drift, disk space, dnsmasq, the firewall, WebDAV |
| *(removed v2-26)* `watch-tailnet-addr` | — | Replaced by timer + `WantedBy=tailscaled` only |
| *(removed v2-36)* `scripts/webdav.sh` / `master-webdav` | — | Replaced by Compose `webdav` on loopback (**DD-77**) |
| `systemd/*.service` (+ timer) | Ordering, coupling and restart policy | The contents of the scripts they start |
| `dev/export-v2.sh` | Write `app/<V2_VERSION>.command` (+ `latest`) portable installer | Host runtime |
| `tests/` | Assert the contract, once per fact | Implementation details of the scripts |

### 3.3 Placeholder convention

Templates use `__NAME__` tokens, not `${NAME}` and not `{$NAME}`. Both of
those already have meanings in the generated files: Compose expands
`${…}` from Compose `.env` at container start, and Caddy expands
`{$TAILSCALE_IPV4}` from `state.env` at daemon start. A distinct install-time
token makes it impossible to confuse "substituted once, by the installer"
with "expanded later, by the consumer".

Rendering is a single function in `common.sh`; it substitutes tokens,
writes to a temporary file, sets owner and mode, and renames atomically. A
template with an unsubstituted `__…__` token left in the output is a hard
error, not a warning.

### 3.4 Runtime layout on the host

| Host path | Written by | Contents |
|---|---|---|
| `/etc/master-stack/config.env` | installer | operator choices, `0600` |
| `/etc/master-stack/state.env` | installer, `refresh-tailnet-config` | detected addresses and identification, `0600` |
| `/etc/master-stack/webdav.htpasswd` | installer, once | bcrypt hash, `0600`; mounted into Compose `webdav` |
| `/etc/master-stack/filebrowser.yaml` | installer | FileBrowser policy, `0644` |
| `/root/docker/compose.yaml` | installer | six services, `0600` |
| `/etc/dnsmasq.d/local-services.conf` | installer | six records, `0644` |
| `/etc/caddy/Caddyfile` | installer | six sites, `0644` |
| `/usr/local/sbin/{tailscale-udp-gro,master-firewall,refresh-tailnet-config}` | installer | `0755` |
| `/etc/systemd/system/{tailscale-udp-gro,master-firewall,refresh-tailnet-config}.service` (+ `.timer`) | installer | `0644` |
| `/etc/systemd/system/{caddy,dnsmasq}.service.d/master-stack.conf` | installer | drop-ins, `0644` |
| `/run/master-stack/` | helpers | ephemeral runtime state (the stack lock) |
| `/var/log/master-setup/` | installer | run logs, `0700` dir / `0600` files |

There is no `/usr/local/share/master-stack` in v2: no canonical copy, no
manifest, no generation pointer.

Two absences in that table are decisions rather than oversights.

**There is no rendered Caddy environment file.** Caddy's drop-in reads
`/etc/master-stack/state.env` directly as its `EnvironmentFile=`, so the
address exists in exactly one place on disk and `refresh-tailnet-config`
has one file to update instead of two. The cost is a formatting
constraint: `state.env` must be parseable both by `source` in bash and by
systemd's `EnvironmentFile=`, which means plain `KEY=value` lines with no
quoting, no spaces around `=`, and no shell expansion. That constraint is
the writer's job to enforce, and the test suite asserts it.

**Compose's `.env` is not written.** No container needs a Compose env file
for Tailscale or WAN facts (**DD-76**). Web UIs and WebDAV bind loopback;
the two public peer ports bind the WAN address via Docker publish.

---

## 4. WebDAV credential design

**Rule: the plaintext password exists only inside the installer process, for
as long as it takes to hash it.**

```
operator types password (echo off, twice, compared)
        │
        ▼
htpasswd -i -B  ──►  /etc/master-stack/webdav.htpasswd   root:root 0600
        │                     │
        ▼                     │
   variable unset             │
                              ▼
              Compose volume mount (read-only)
              → /run/secrets/webdav_htpasswd
                              │
                              ▼
                    rclone serve webdav --htpasswd=…
                    (Compose service `webdav`, loopback)
```

### 4.1 The decision, stated as properties

Recorded so that a later phase cannot quietly weaken it. The same list, in
contract form, is `v2-contract.md` §6.2. **DD-77** replaced the former
systemd `LoadCredential=` path.

1. Credentials live in a **separate, root-owned credential file**:
   `/etc/master-stack/webdav.htpasswd`.
2. Its mode is **at most `0600`**, owner `root:root`, verified after writing.
3. Compose mounts the file at **`/run/secrets/webdav_htpasswd`** (read-only).
4. rclone is pointed at that **path** only (`--htpasswd=…`).
5. The password is **not in Compose YAML or systemd unit content**.
6. The password is **not in any environment file**: not `config.env`, not
   `state.env`, not `v2/config/defaults.env`. There is no `webdav.env`.
7. The password **does not appear on a command line**.
8. The password is **not written to logs**.
9. Exposure checks against the running container assert items 7–8 (§4.3).

### 4.2 Where the username lives, and why

**The username is managed with the credential, not with the
configuration.** It lives inside `webdav.htpasswd`, because the htpasswd
format is already `user:hash`.

The alternative — `WEBDAV_USER` in `config.env` — was rejected: the name
would then exist in two places and could drift from the hash. One file, one
pair.

Consequence: `WEBDAV_USER` does not appear in configuration files, and
`defaults.env` names it in its forbidden-keys list alongside
`WEBDAV_PASSWORD`, `WEBDAV_PASSWORD_HASH` and `WEBDAV_USER_PASSWORD`.

### 4.3 Verified at implementation time, not assumed

rclone must take credentials from a *file*. If it could only take
`--user`/`--pass`, the secret would land on the command line.

Stage 7 and the live checklist assert: no password or username in container
args / environ; host htpasswd remains `0600` `root:root`.

### 4.4 Tunables (no `webdav.env`)

Port, image pin, and read-only posture live in `defaults.env` + the Compose
template. There is no separate `webdav.env`; Stage 4 deletes a leftover file
from older revisions.

### 4.5 Re-run behaviour

If the credential file exists and is non-empty, the installer says so and
does not ask again. Resetting is deleting the file and re-running, and the
installer's output states that. This is what keeps a second run from
silently invalidating the Apple TV's stored credentials. Host
`master-webdav` leftovers are disabled and removed.

---

## 5. Address change handling

Three consumers depend on an address, and each is handled differently
according to what it actually binds:

| Consumer | Binds to | On Tailscale address change |
|---|---|---|
| dnsmasq | `lo` and `tailscale0` **by name** | Nothing — `interface-name` + `bind-dynamic` follow the interface, and the config is never regenerated |
| Caddy | `{$TAILSCALE_IPV4}` read from `state.env` | Restarted after `state.env` is updated |
| WebDAV | `127.0.0.1` only | Nothing — loopback publish does not track Tailscale |
| Compose containers | no Tailscale bind | Nothing — no container binds a Tailscale address |
| Firewall | `tailscale0` **by name**; WAN peer ports from config/state | Nothing — no Tailscale rule names an address |

`refresh-tailnet-config` owns the Tailscale side of this table, and its
scope is exactly that: read the current IPv4 and IPv6, compare with
`state.env`, exit successfully without touching a service if they match,
and otherwise update `state.env` atomically and restart Caddy. It has no
opinion about container health, file contents, disk space or image digests,
and it holds no cooldown stamps, drift flags or recovery logic. **DD-61**
(narrowed by **DD-77**) states the scope exhaustively.

Two rows above say "nothing" for structural reasons worth naming, because
they are what keep the helper small. dnsmasq and the firewall are both
written against the *interface name* rather than the address it currently
carries, so the address can change — or `tailscale0` can be destroyed and
recreated — with no file to regenerate and no rule to reinstall.

**A Tailscale address change never restarts the Compose stack.** This is
the single most important lifecycle difference from v1, where
`master-compose.service` carried `PartOf=tailscaled.service` and therefore
made every `systemctl restart tailscaled` bounce all five containers.

**Public IPv4 change — open question for a later phase.** The firewall
re-applies itself on boot or Docker restart and therefore picks up a new
public address, but the Compose port publications are baked into the running
containers. Until a decision is made, the documented answer is: a changed
public IPv4 requires re-running the installer. Options to evaluate later
are (a) extending `refresh-tailnet-config` to re-render `.env` and recreate
only `qbittorrent` and `wg-easy`, or (b) accepting the manual re-run on a
host whose address is effectively static. This is recorded here so it is a
decision rather than a gap.

---

## 6. Decision ownership

The v1 failure mode this table prevents: the same question answered in the
installer, in a helper and in the final test, with three implementations
that could disagree.

| Question | Single owner |
|---|---|
| What is the WAN interface / WAN IPv4 / Tailscale IPv4 / IPv6? | `install.sh` (write) / `refresh-tailnet-config` (update) |
| Is the firewall policy in force? | `scripts/master-firewall --check` |
| Has the Tailscale address changed? | `scripts/refresh-tailnet-config` |
| Is a container healthy? | **Nobody.** Compose's restart policy handles crashes; there is no health arbiter |
| Has a managed file drifted? | **Nobody.** Re-running the installer is the repair |
| Is the stack working end to end? | The final verification stage, once |
| Is a port number correct? | `config/defaults.env` |

A check that appears in two of these rows is a bug in v2, not defence in
depth.

---

## 7. Installer stage outline

Stage boundaries are the same shape as v1's, minus the work that no longer
exists. Stage 4 in v1 was 2396 lines; here it is a rendering pass.

| Stage | Work | Owns |
|---|---|---|
| 0 | Gates (root, tty, Debian 13, lock, inhibit); ask domain, downloads path, ports, WebDAV credentials; `config.env`; optional full-upgrade prompt on re-run | operator input |
| 1 | `apt update`; optional `full-upgrade`; base packages (`apache2-utils` for htpasswd); WebDAV htpasswd if new; timezone | `apt` |
| 2 | Tailscale: repository, package, sysctls, UDP GRO, login with 410 recovery, exit-node and SSH preferences | `tailscaled` |
| 3 | Address detection → `state.env`; downloads tree `chown` `DOWNLOADS_UID:GID` | installer |
| 4 | Docker; render `compose.yaml` / FileBrowser config; remove host WebDAV leftovers; install scripts and units | templates |
| 5 | apply `master-firewall`; enable refresh timer | firewall |
| 6 | dnsmasq/Caddy: mask+apt only if packages missing; render; restart only if config changed | DNS/HTTP |
| 7 | Compose `up` if needed; cheap contract checks (incl. WebDAV loopback + Caddy) | verification |
| — | Print summary and the manual Tailscale admin steps | operator guidance |

Note the ordering change from v1: **addresses are detected once, in stage 3,
into `state.env`**, and every later stage reads them from there instead of
re-deriving them. v1 derived the same route information in four separate
places.

---

## 8. Implementation status

The lean `v2/` tree is executable: `install.sh` runs the seven stages on a
Debian 13 host. `v2/dev/export-v2.sh` embeds a runtime-only tarball
(excluding `.cursor/`, `dev/`, `tests/`, `app/`) into
`v2/app/<V2_VERSION>.command`, which uploads and starts install over
`ssh -t`.

Static checks for this tree:

```bash
bats v2/tests
bash -n v2/install.sh v2/common.sh v2/scripts/*
shellcheck -x -s bash v2/install.sh v2/common.sh v2/scripts/*
```

Root `scripts/check-all.sh` still targets legacy `install.sh` until v1 is
retired.

---

## 9. Per-phase verification

`v2/.cursor/rules/` requires six checks at the end of every phase, not two.
Recorded here so a phase cannot quietly declare itself done on `bash -n`
alone:

| Check | Scope | Available on the dev workstation? |
|---|---|---|
| `bash -n` | Every `v2/*.sh` and `v2/scripts/*` | **yes** |
| `shellcheck -x` | Same set; `-x` so sourced libraries are followed | **yes** |
| `bats v2/tests/` | Unit suites (repo convention, not from the rules file) | **yes** |
| `docker compose config` | The rendered `compose.yaml` | **no** — Debian target only |
| `caddy validate` | The rendered `Caddyfile` | **no** — Debian target only |
| `dnsmasq --test` | The rendered dnsmasq config | **no** — Debian target only |
| `systemd-analyze verify` | Every generated unit and drop-in | **no** — Debian target only |

The split matters: the first three can gate every commit, the last four can
only run where the software exists. So a phase that renders a template is
**not** verifiable on the workstation alone, and claiming otherwise is the
failure mode `scripts/check-all.sh` was written to prevent (a missing tool
must report *doğrulanamadı*, never a pass).

Two consequences for the phase that lands real rendering:

1. The three renderers must be invocable without installing anything, so
   that a rendered artefact can be produced on the workstation and carried
   to the target for validation.
2. `refresh-tailnet-config` must validate before reloading — the rules
   require it, and a reload on an invalid config is how a working DNS server
   becomes a stopped one.

## 10. Decisions taken, and what remains open

### 10.1 Settled on 2026-08-05

Four questions that were disagreements between `v2/.cursor/rules/` and the
decisions taken in conversation, plus the DD-9 supersession, were answered
together. Each has a full entry in `docs/design-decisions.md`; the
one-line versions:

| # | Question | Answer |
|---|---|---|
| **DD-58** | Does the single-file model survive into v2? | No. DD-9 is superseded; v2 ships as a repository tree. |
| **DD-59** | Chain names | `MASTER-INPUT` and `MASTER-DOCKER`, declared only in `config/defaults.env`. `MASTER-DOCKER-FILTER` is not used. |
| **DD-60** | Does dnsmasq listen on loopback? | Yes — `lo` and `tailscale0`, `bind-dynamic`, nothing else, no DHCP. |
| **DD-61** | Does the refresh helper re-render configs? | No. It updates `state.env` and restarts Caddy (WebDAV was dropped from the set by **DD-77**). dnsmasq, the firewall and the stack are untouched. |
| **DD-77** | Where does WebDAV run? | Compose on `127.0.0.1`, Caddy reverse_proxy; host unit removed. |
| **DD-62** | Portainer's upstream | HTTPS `127.0.0.1:9443` with loopback-only `tls_insecure_skip_verify`. |

**DD-59 removed a chain that was never decided on.** `defaults.env`
previously also declared `MASTER-TS-FORWARD`, carried over from v1's
mangle-table chain. It is not part of the fixed name set and no clause of
the contract requires it, so it is gone. If the firewall phase finds that
a `FORWARD`- or mangle-table chain is genuinely needed, that is a new
decision with a new name, not a constant that survives by inertia.

### 10.2 Still open

1. **Public IPv4 change handling** (§5) — extend the refresh helper, or
   document a manual re-run. Note that **DD-61** closes the door on
   solving this inside `refresh-tailnet-config` as currently scoped: doing
   so would mean recreating containers, which that helper must not do.
2. **Comment policy for v2.** Settled for `install.sh` (DD-44: no
   editorial comments; rationale in `docs/design-decisions.md`). Helper
   scripts under `v2/scripts/` may keep short operational comments.
3. **Whether `master-compose.service` returns in a later phase.** It is out
   of the first release; if a public IPv4 change is to be handled
   automatically, it may need to come back in a much smaller form.
4. **`systemd-resolved` vs dnsmasq on `127.0.0.1:53`.** Stage 6 writes
   `DNSStubListener=no` when resolved is active; still worth confirming on
   unusual images.
5. **What a loopback query actually answers.** `interface-name` is
   expected to return the `tailscale0` address regardless of the arrival
   interface, which is the entire reason the loopback listener is useful
   for testing. Measured on the live host in stage 7 (both `@127.0.0.1`
   and `@TAILSCALE_IPV4`). The DNS phase carries it as an
   acceptance test on a clean Debian 13 target: `dig +short NAME
   @127.0.0.1` and `dig +short NAME @${TAILSCALE_IPV4}` must agree, and must
   both return `${TAILSCALE_IPV4}`.
