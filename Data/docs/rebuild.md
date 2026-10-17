# Obhut rebuild: one container model

Status: direction accepted on 2026-10-17 (**DD-271**). Work happens on the branch `yeni-yapi`; `main`
stays on the 1.x line until the whole rebuild is done, tested on a clean server and merged. This
document is the plan and the place where progress is tracked: each phase below has a checklist that
is ticked in the same commit that does the work.

The clickable prototypes behind the decisions (private artifacts, not part of the repository): the
inspector demo, the structure plan and the Konsol preview of 2026-10-16.

## Contents

1. [What changes](#1-what-changes)
2. [Ground rules](#2-ground-rules)
3. [Decisions](#3-decisions)
4. [Target architecture](#4-target-architecture)
5. [Removed for good](#5-removed-for-good)
6. [Phases](#6-phases)
7. [Checks at the end of every phase](#7-checks-at-the-end-of-every-phase)
8. [Open questions](#8-open-questions)

## 1. What changes

Obhut becomes fixed infrastructure with a fixed set of built-ins, and runs every other piece of
software as a Podman container that the operator adds from the software's own definition file.

- **Built-ins:** Konsol, Tailscale (exit node), Caddy, dnsmasq, the firewall, Files (server folders,
  trash, system files), folder WebDAV (Paylaşımlar) and WireGuard.
- **Applications:** only Podman containers. The operator adds one from a Docker Compose file or a
  Kubernetes YAML file (or from an image name or a running container, both turned into such a file
  first). An inspector (*denetçi*) reads the file, refuses what is unsafe, asks what only the operator
  can answer, and Obhut writes its own Quadlet units. systemd starts them; Podman runs them. There
  is no Docker, no Compose runtime and no Kubernetes.
- **Obhut knows no application.** The App Store catalogue and its packages leave the repository. Every
  application is added the same way, from its own Compose or Kubernetes file: what the file asks for is
  what the inspector reads, refuses or asks about. No application gets a mechanism, a default or a code
  path of its own, and nothing in the shipped tree names an application.
- **A port reaches outside only through Erişim.** Every container port is either an address (a Caddy
  row: Tailscale name, optional Tailscale port, optional internet name) or a raw port (closed,
  Tailscale or internet). The file's own host ports are never used.

## 2. Ground rules

These rules apply to every phase and are checked before a phase is called done.

1. **No compatibility layer.** The new generation installs only on a clean operating system. There is
   no migration code, no "accepted and ignored for one release" option, no retired setting kept for
   old hosts and no redirect for old addresses.
2. **Remove, do not disable.** A removed feature leaves no file, unit, route, setting key, test,
   fixture, interface text or documentation sentence behind. History stays only in `CHANGELOG.md`
   and `docs/archive/`.
3. **No back doors.** Every request the root backend answers is in the route table, except the
   session check (`/oturum-denetle`) and the sign-in POST. No debug switch, no undocumented flag, no
   default credential, no code path that exists only for tests in a shipped file. Secret values are
   never written in plain text, never logged and never sent to the browser after they are set.
4. **Fail closed.** The YAML reader and the inspector stop at anything they do not understand and
   name its line; nothing is skipped or guessed silently.
5. **One home per object.** An application is managed on its page, an address in Erişim, a folder in
   Dosyalar. Other places show a summary and a link; no setting is editable in two places.
6. **Single sources of truth.** Ports, paths and chain names in `config/defaults.env`; request and
   reply shapes in the route table (`panel/master_api.py`), from which the OpenAPI file and the
   TypeScript types are generated.
7. **The security floor stays.** The root backend on a Unix socket behind Caddy's `forward_auth`; the
   CSP (no inline code, no `eval`, nothing from elsewhere); the tailnet first; typed words for
   irreversible actions; plan → apply with a timed confirmation for anything that can cut the
   operator off; repair (`master-onar`); container egress only to the internet (DD-224).
8. **Smallest complete step.** A phase delivers working features end to end or removes them
   completely; it never leaves half of a feature for a later phase to finish silently.

## 3. Decisions

Taken on 2026-10-16 and 2026-10-17. The prototypes show each one in place.

| | Decision |
|---|---|
| **Model** | Compose and Kubernetes YAML are both accepted (the dual model); one inspector, one generator, Quadlet + systemd as the only runtime |
| **K1** | No migration: a host that ran an older Obhut needs a clean install |
| **K2** | "Uygulama ekle" takes four sources: a file (pasted or uploaded), an `https` address, an image name, an existing container; the last two become a draft file first |
| **K3** | An application's settings change in its **Tanım** tab: the source file and the answers; the inspector shows the difference as a plan. Package forms are gone |
| **K4** | Obhut's own small YAML reader in standard-library Python; no new package |
| **K5** | Each address row may also open a Tailscale port (`<tailscale-ip>:<port>`); off by default |
| **K6** | WireGuard is installed with the base, turned off; Erişim → WireGuard turns it on |
| **K7** | No "file manager" card; Dosyalar → Depolama lists which application uses which folder |
| **K8** | Gelişmiş is read-only; its only write is the cleanup of unused images, networks and the folders of removed applications |
| **K9** | Removing an application asks whether to keep its data; keeping is the default; `/srv` is never touched |
| **A1** | No TCP port is preselected for a Caddy row; the operator answers each one, with the inspector's guess beside it |
| **A2** | Raw ports come closed; opening one to the internet needs an extra consent |
| **A3** | No `x-obhut` block: `x-` keys are ignored and the inspector guesses port, folder and secret kinds, which the operator confirms |
| **A4** | Each container asks how it starts: directly as its own user (all capabilities dropped, `NoNewPrivileges`) or as root that may switch to its own user (Podman's defaults less `SETFCAP` and `SYS_CHROOT`, and `NET_BIND_SERVICE` too when no port is below 1024). The default follows the file's `user:`. Privileged mode never |
| **A5** | An application's data lives in a visible folder, `/var/lib/master-stack/uygulamalar/<app>/`; the file's named volumes become sub-folders. Binds come only from `/srv` (with the Files account) and from that folder |
| **A6** | The Compose and Kubernetes readers ship together |
| **A7** | Erişim gets its own "Yerel adlar" tab; Sistem → Görünüm goes (the theme moves to the top bar and the palette); "Günlük" names are split (İşlem geçmişi, Onarım kaydı, an application's Günlük); Genel Bakış gets an access summary |
| **S1** | The layout audit (DD-270) lands on `main` before the rebuild starts |
| **S2** | The rebuild lives on `yeni-yapi` and merges once, complete |
| **S3** | Any older Obhut on a host stops the installer at stage 0; old hosts are not offered the new generation as an update |
| **S4** | During the phases the test host is cleaned by hand; before the final test the operator resets its operating system |

## 4. Target architecture

### 4.1 Layers

| Layer | Contents |
|---|---|
| Who connects | This server (loopback), Tailscale devices, WireGuard devices, the internet |
| Gate | Firewall (project chains and the container guard), Caddy (names, certificates, the Konsol session check), dnsmasq (local names) |
| Obhut | Konsol (built interface, root backend on a socket, `sudo obhut`), Files, folder WebDAV, WireGuard, addresses and local names, health and repair, update |
| Application engine | Readers → model → inspector → generator → records; lifecycle jobs through the existing root worker |
| Applications | Podman containers, each application on its own bridge `ksl-<app>` |
| Base | Debian 13, Ubuntu 24.04 or 26.04; `kur.sh` → `install.sh`; Tailscale; Podman |

### 4.2 The application engine

New modules in `panel/` (names may be refined when the phase starts; the split is the point):

| Module | Job |
|---|---|
| `master_yaml.py` | The YAML subset reader (K4). Mappings, sequences, plain and quoted scalars, the flow forms `[...]` and `{...}`, `|` and `>` blocks, comments, several documents separated by `---`. Anchors, aliases, merge keys, tags and complex keys stop with their line |
| `master_compose.py` | Compose → model |
| `master_kube.py` | Kubernetes YAML → model |
| `master_inspector.py` | Model → refusals, guesses and questions; answers → a checked application definition |
| `master_generator.py` | Definition → Quadlet units, secrets, access rows, folders |
| `master_applications.py` | Records, the read model, lifecycle (add, start, stop, restart, update image, refresh from source, edit definition, remove) |

The existing container modules are reused where they fit and lose whatever only served packages,
adoption or single-container definitions: `master_container_worker.py` (prepare, apply, rollback),
`master_container_manager.py` (broker, jobs, update checks, cgroup usage, journal),
`master_container_network.py` (the nft guard), `master_container_binds.py` (bind anchors).

**The model** (one for both formats): an application name; containers with image, command,
entrypoint, working directory, environment (values and `${VAR}` references), ports (container port,
protocol), mounts (named volume, relative path, absolute path; read-only flag), user, health check,
restart policy, dependencies; Compose services share one network and reach each other by name, a
Kubernetes Pod becomes a Quadlet `.pod` whose containers share `localhost`.

**Supported Compose keys (first version).** Services: `image` (required), `command`, `entrypoint`,
`environment` (list or map), `ports` (`C`, `H:C`, `IP:H:C`, `/udp`; the host side is ignored),
`volumes` (named, relative, absolute, `:ro`), `user`, `restart`, `healthcheck`, `depends_on` (list or
map), `working_dir`, `tmpfs`, `cap_add` (only names from Podman's default set), `cap_drop`, `labels`,
`stop_signal`, `stop_grace_period`, `hostname`, `init`, `read_only`, `shm_size`, `ulimits`, `pids_limit`,
`mem_limit`, `cpus`, `deploy.resources.limits` (`deploy.replicas` only 1), and `security_opt` only as
`no-new-privileges`. Noted and ignored: `container_name`, `expose`, `networks`, `tty`, `stdin_open`,
`logging`, `platform`, `pull_policy`, the rest of `deploy`. Top level: `services`, `volumes`, `networks`
(ignored), `name`, `version`. Interpolation: `${VAR}`, `${VAR:-default}`, `${VAR-default}`,
`${VAR:?message}`, `$$`. Refused with their line: `build`, `extends`, `env_file`, `secrets`, `configs`,
`profiles`, `include`, `privileged`, `network_mode`, `pid`, `ipc`, `devices`, `dns`, `extra_hosts`,
`group_add`, `links`, `sysctls`, `volumes_from`, any other `security_opt`, `cap_add` outside the default
set, Podman's own labels (`io.containers.*`, `io.podman.*`), and any key not listed.

**Supported Kubernetes kinds (first version).** `Pod`; `Deployment` with one replica;
`PersistentVolumeClaim` (becomes a sub-folder). Containers: `name`, `image`, `command`, `args`, `env`
(`value`, `valueFrom.secretKeyRef`), `ports` (`containerPort`, `protocol`; `hostPort` ignored),
`volumeMounts`, `securityContext.runAsUser`/`runAsGroup`, `readOnlyRootFilesystem`,
`allowPrivilegeEscalation`, `livenessProbe`/`readinessProbe` (`exec`, `httpGet`), `workingDir`,
`resources.limits`; `$(VAR)` in `command`/`args` is expanded from the container's own non-secret
environment, as Kubernetes does. Volumes: `hostPath`, `persistentVolumeClaim`, `emptyDir` (tmpfs).
Refused: `hostNetwork`, `hostPID`, `hostIPC`, `privileged`, added capabilities outside the default
set, `initContainers`, `ConfigMap` and `Secret` objects, other kinds.

**Inspector questions.** The application name; every TCP port (Caddy row with its Tailscale name, or
raw port; nothing preselected, A1); every UDP port (raw, closed, A2); every `${VAR}` (a value, or for a
secret-looking name a hidden value with "Rastgele üret"); every mount (the application's folder or a
folder under `/srv`: the file's own host path is never used, and system paths and engine sockets are
refused); every container's start mode (A4, suggested from the file's `user:` alone). Guesses (web
interface, known service port, secret-looking name) are shown, never applied to ports.

**Generator rules.** One bridge `ksl-<app>`; Compose services get a network alias each; a Kubernetes
Pod gets a `.pod`. `PublishPort` only on `127.0.0.1:<pool port>` for address rows and on the Tailscale
or WAN IPv4 address for open raw rows. Images are pulled by the worker and pinned by digest; units use
`Pull=never`. Start mode per A4. Secrets as `Secret=<name>,type=env,target=<VAR>` under the names the
inspector gives (`<app>-<variable>` or `<app>-<entry>`), created through standard input. Health checks become Quadlet health settings. No privileged mode, no devices, no host
namespaces, no host ports from the file.

**Records.** `UYGULAMA_STATE_DIR/<app>/` (`KONTEYNER_STATE_DIR/uygulamalar/`), mode 0600 files, root only:
`kaynak.yaml` (the file exactly as given), `kaynak.json` (source kind, address, fetch time, SHA-256),
`yanitlar.json` (answers, never secret values), `tanim.json` (the checked definition), `yerler.json`
(what the engine allocated: pool ports, Podman secret names, image digests, stopped, revision) and `env/`.
Units in `KONTEYNER_BIRIM_DIR` (`konsol-<app>.network`, `konsol-<app>_<service>.container`,
`konsol-<app>.pod`; application names have no `_`, so no two applications share a name). Data in
`UYGULAMA_VERI_DIR/<app>/<folder>/` (`/var/lib/master-stack/uygulamalar/`, A5; outside the Files account's
view like every private state, DD-225). The record is
the single source: units, rows and names can be generated again from it on request. This is not a
reconcile engine; nothing runs unasked.

**Lifecycle.** Add (inspect → plan → pull, write, start, health; roll back on failure); start, stop,
restart; update the image of the same tag on the operator's confirmation (DD-214); refresh from the
source address (only new lines are asked); edit the definition (Tanım, K3); remove (keep data by
default, K9). Every write is a job in İşlemler and a line in İşlem geçmişi.

### 4.3 Access rows

One row per exposed container port, keyed by application, container and port (not by a loopback port
number), plus the fixed rows of Konsol and Paylaşımlar.

- **Address (Caddy row):** a Tailscale name `<name>.<domain>` (renamable), an optional Tailscale port
  (K5), an optional internet name (HTTPS on the shared 443 listener; DNS must point only to the WAN
  IPv4). Upstream is the application's `127.0.0.1` pool port.
- **Raw port:** closed, Tailscale or internet (A2); carried by the container guard; shown locked in
  the firewall view with a link to its row.
- All changes go through the settings plan; anything touching the internet or the firewall needs the
  60 s confirmation; Konsol on the internet needs the typed word and an existing account (DD-195).

### 4.4 WireGuard as a built-in

`wireguard-tools` and `qrencode` in stage 1; `master-wg` installed by stage 4 from `scripts/`; the
`wg-quick@` drop-in from `systemd/`; the `WG_*` keys in `config/defaults.env`; the firewall reads the
networks file and the stopped marker itself; Konsol talks to `panel/master_wireguard.py` through typed
routes. Off after install (K6). From phase 4 on, turning it on, off or regenerating a network is a
settings plan like every other access change; phase 1 keeps today's immediate writes.

### 4.5 Konsol

The six sections stay. The prototype is the reference for every screen:

- **Genel Bakış:** problems with their fix, applications, the access summary (A7), resources, network,
  server. The top bar's problem chip goes where the problem is.
- **Uygulamalar:** the list; "Uygulama ekle" with four sources, the inspector and the plan; an
  application page with Özet, Erişim (read-only), Depolama, Tanım and Günlük.
- **Erişim:** Genel, Adresler (addresses and raw ports, "Adres aç"), Yerel adlar, Tailscale, WireGuard,
  Güvenlik duvarı.
- **Dosyalar:** Depolama, Sunucu klasörleri, Çöp kutusu, Paylaşımlar, Sistem dosyaları.
- **Sistem:** Sağlık (with Onarım kaydı), Güncellemeler (Obhut, and a count of application updates),
  Hesap, Sunucu, İşlem geçmişi.
- **Gelişmiş:** Caddy, DNS, Güvenlik duvarı (the technical rules), Podman (read-only, cleanup).

Words used in the interface: Adres (technical detail: "Caddy satırı"), Tailscale adı, Tailscale portu,
İnternet adı, Ham port, Yerel alan adı ("alan adı" only for this), Yalnız bu sunucu (loopback). A
button that opens a flow has one name everywhere.

### 4.6 The generation gate (S3)

`install.sh` stage 0 stops when the host carries an older Obhut: a `STATE_DIR` without the new
generation's marker, or any file that only the 1.x line writes. The message says that this version
installs only on a clean operating system. Re-runs of the new generation pass. Konsol's update check
offers only builds of its own generation. On the 1.x line, a last release teaches the old Konsol to
show "the new generation needs a clean install" instead of an update; a 1.x host that updates before
receiving it stops at stage 0 with the same message, so nothing is half-installed either way.

## 5. Removed for good

Removed in the phase named in brackets; the leftover sweep (section 7) proves it.

- The store engine `scripts/master-modul`, the registry, `MODULES_*` keys, pending markers, package
  overrides, `ensure_module_files`, `reapply_modules` and every `paket_*` helper in `install.sh` [1].
- `magaza/` entirely: the application packages, `wireguard` (moves into the base), and the built-in
  manifests `dosya` and `paylasim` (their units are installed directly) [1].
- Every `PAKET_*` consumer in the panel, the firewall, the shares and the container modules; package
  APIs under `/api/uygulama/*`; `/api/konsol/moduller`; the `kur` action; `/uygulamalar/hesap`;
  package traffic modules [1].
- The 1.x leftovers: the ignored `--archive-dir` and `--share` options, `RETIRED_*` keys, the `.pay`
  gate, the `/yeni` redirect, old Konsol address redirects [1].
- Single-container Konsol definitions, adoption by import, the "İmajdan konteyner" and "Yönetime al"
  flows and their routes [3]; container port scopes `tailscale`/`public`, manual `elle-*` rows and the
  Yayınla flow [4].
- Interface: the catalogue, package forms and settings, the account card, the adapter editor, the
  file-manager note in Dosyalar, the Görünüm tab, Gelişmiş's create actions, every special case for a
  named application [1, 5].
- Documentation and tests that describe any of the above, moved to `docs/archive/` or deleted; the
  superseded DD entries retired [6].

## 6. Phases

Each phase ends with the checks in section 7, its own DD entry, a `V2_VERSION` bump on the branch and
a `CHANGELOG.md` entry under `[Unreleased]`.

### Phase 0: preparation

- [x] The layout audit committed to `main` (DD-270, S1)
- [x] Branch `yeni-yapi` from `main`
- [x] This plan and DD-271

### Phase 1: a clean base

The base installs and runs with its built-ins only; no store engine, no package, WireGuard built in.
Done in v2-255 (DD-272), live-verified on the test host on 2026-10-17.

- [x] Generation gate in stage 0 and the new generation marker
- [x] Files and folder WebDAV installed directly by `install.sh` (no manifests)
- [x] WireGuard in the base (4.4), off after install
- [x] Store engine, packages and every `PAKET_*` consumer removed (section 5)
- [x] 1.x leftovers removed (section 5)
- [x] Konsol: catalogue and package views removed; WireGuard tab on the new routes; Uygulamalar shows
      an empty state until phase 3
- [x] Tests for the gate, the built-ins and WireGuard; package tests removed

### Phase 2: reading and inspecting

Pure functions, no writes: the YAML reader, both format readers, the model and the inspector.
Done in v2-256 (DD-273), live-verified on the test host on 2026-10-17.

- [x] `master_yaml.py` with tests for every supported form and every refusal
- [x] `master_compose.py` and `master_kube.py`
- [x] `master_inspector.py`: refusals, guesses, questions, answer checking
- [x] A dry-run route (`POST /api/konsol/uygulamalar/denetle`) in the route table
- [x] Acceptance fixtures: published Compose files as projects ship them (named volumes, a placeholder
      host path, a linuxserver image), a two-service application with a database, a Kubernetes Pod from
      `podman kube generate`, and a deliberately unsafe file

### Phase 3: generating and running

Done in v2-257 (DD-274), live-verified on the test host on 2026-10-17. A Kubernetes Pod with more than one
container and a Compose `service_healthy` need Podman 5 (Quadlet `.pod`, `Notify=healthy`): Ubuntu 24.04's
Podman 4.9 refuses them before any write. The base installs `catatonit` for pods and `init: true`.

- [x] `master_generator.py`: units, secrets, folders, rows (rows applied in phase 4)
- [x] `master_applications.py` on the existing worker: add, start, stop, restart, update image,
      refresh from source, edit definition, remove (keep or delete data)
- [x] Multi-container applications: one network, aliases, ordering, health; Kubernetes `.pod`
- [x] Bind rule (A5) and start modes (A4); DD-226 and DD-227 amended (a root start may write `/srv`, with
      a warning: the operator's decision of 2026-10-17)
- [x] Image name and existing container turned into draft files (K2)
- [x] Single-container definitions, adoption and their routes removed

### Phase 4: access rows

- [ ] Row model keyed by application, container and port; Konsol and Paylaşımlar rows
- [ ] Caddy rows from the inspector's answers; renamable Tailscale names
- [ ] Tailscale port (K5) with its tailnet allow entries (DD-172 amended)
- [ ] Raw ports through the container guard; locked rows in the firewall view
- [ ] "Adres aç" for a port without an address; plan → apply → timed confirmation
- [ ] WireGuard on/off and network regeneration through the settings plan (4.4)
- [ ] `elle-*` rows, package rows and the Yayınla flow removed; the settings writer for the old
      WebDAV-only `https` key goes with them (it passes the route check only because `AyarIstegi` is an
      open object)

### Phase 5: Konsol

- [ ] Uygulamalar: list, "Uygulama ekle" (four sources, inspector, plan), application page
- [ ] Erişim: Adresler, Yerel adlar (A7), WireGuard, Güvenlik duvarı as in the prototype
- [ ] Genel Bakış access summary; the problem chip goes where the problem is
- [ ] Dosyalar (K7), Sistem (A7 names, no Görünüm), Gelişmiş read-only with cleanup (K8)
- [ ] Command palette, İşlemler, the pending banner for every timed change
- [ ] Old components removed; UI suites rewritten; layout audit clean at every width

### Phase 6: documents, sweep and the clean-server test

- [ ] `contract.md`, `architecture.md`, `CLAUDE.md`, `README.md`, `tests/README.md` describe only the
      new structure
- [ ] Superseded DD entries retired to the archive; new entries complete
- [ ] Final leftover sweep and back-door review (section 7), including the switches that exist only
      for tests: `master-panel --state-env`, `--allow-host` in both backends, the `PANEL_ACTIVE_WINDOW`
      and `PANEL_SAMPLE_SECONDS` environment variables, the hidden `--state` of `obhut` and `--kaynak` of
      `master-onar`: each one is removed or moved behind the test harness
- [ ] The test host reset by the operator (S4); install from the branch on the clean system;
      applications the operator chooses added from their own published files; every flow of the
      prototype done live
- [ ] On `main`, a last 1.x release that turns the update offer into the clean-install notice (4.6)
- [ ] Merge to `main`; release when the operator asks (section 8)

## 7. Checks at the end of every phase

1. **Static:** `bash -n` and `shellcheck` for shell, `python3.13 -m py_compile` for Python, the
   TypeScript build and its freshness hash (`console/yeni/kaynak.sha256`).
2. **Tests:** `bats tests`, the Python unit tests, the UI suites with the layout audit (DD-270). Known
   macOS-only Python failures are listed in `tests/README.md`; nothing else may fail.
3. **Leftover sweep:** over the shipped tree and the Konsol sources (not `docs/archive/`, not
   `CHANGELOG.md` history, not test fixtures that hold third-party files), for the terms of the phase
   and finally all of: `master-modul`, `MODULES_`, `PAKET_`, `magaza`, `katalog`, `App Store`, `paket:`,
   `/api/uygulama/`, `torrent`, `qbittorrent`, `gezgin`, `sahiplen`, `yayinla`, `elle-`, `RETIRED_`,
   `archive-dir`, `.pay`, `/yeni`. Every remaining hit is either removed or justified in the phase's DD
   entry.
4. **Back doors:** a test fails if the backend answers a path outside the route table other than the
   session check and the sign-in POST; no listener appears that `config/defaults.env` does not declare;
   no secret value reaches a log, a reply or a world-readable file.
5. **Live:** the test host is cleaned (S4), the branch is installed (with `KUR_REF=yeni-yapi`, or before
   its commit the same tree as an archive through `KUR_URL`), the phase's features are exercised, and the report says what was run and what happened. No server-side
   backups on the test host.

## 8. Open questions

To be settled when the named phase starts:

- **Phase 5:** Genel Bakış's per-application traffic totals: read generically from each container's
  own network counters, or drop the per-application split.
- **Phase 6:** the release numbers: the merge as 2.0.0 and the last 1.x as 1.2.0 are proposed
  (DD-260: a release only when the operator asks).
