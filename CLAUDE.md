# CLAUDE.md

Working guide for any AI assistant in this repository. Read this first.

## Project Overview

The project is named **Obhut** (repository `drs0me1/obhut`, **DD-255**); paths, units and
commands on the server keep their earlier `master-stack`/`debian-server-installer` names.
Active code lives under `Data/`; the repository root holds the server bootstrap
`kur.sh` (run on the server: `curl -fsSL https://raw.githubusercontent.com/drs0me1/obhut/main/kur.sh | sudo bash`,
**DD-228**), `wireguard.command` (WireGuard devices over SSH) and `onar.command` (SSH "Denetle ve onar",
**DD-239**), plus the Git-ignored `kurulum/` (the SSH host both use and downloaded
WireGuard device profiles/QR codes), this file and `README.md`. The repository is public: never commit host
addresses, real domains, credentials or personal paths. Bare paths in this file and in `Data/docs/` (`install.sh`,
`config/defaults.env`, `tests/`, `CHANGELOG.md`, …) are relative to `Data/`.

This is generation 2 of Obhut (`OBHUT_NESIL="2"` in `install.sh`, **DD-271**). The installer turns a clean
Debian 13 (trixie) or Ubuntu 24.04/26.04 LTS host into a Tailscale exit node with host dnsmasq + Caddy on
the tailnet, a persistent firewall and Konsol, the web console. The built-ins are fixed: Konsol, Tailscale,
Caddy, dnsmasq, the firewall, Files (server folders, trash, system files), folder WebDAV (Paylaşımlar) and
WireGuard (installed turned off, **DD-272**). Everything else is an application: Podman containers the
operator adds from the software's own Docker Compose or Kubernetes YAML file (the dual model). Obhut's YAML
reader and inspector (*denetçi*) read the file, refuse what is unsafe and ask what only the operator can
answer; the generator writes Quadlet units; systemd starts them and Podman runs them (**DD-273**,
**DD-274**). There is no Docker (**DD-152**), no Compose runtime, no `podman kube play` and no App Store:
Obhut knows no application. A container port reaches outside only through its access row in Erişim, an
address (a Caddy row) or a raw port (**DD-275**). Generation 2 installs only on a clean operating system:
stage 0 stops on any older Obhut (**DD-272**). There is no reconcile / self-healing engine by design.

Authoritative behaviour: [`Data/docs/contract.md`](Data/docs/contract.md).
Architecture: [`Data/docs/architecture.md`](Data/docs/architecture.md).
Non-obvious rationale: [`Data/docs/design-decisions.md`](Data/docs/design-decisions.md)
(`DD-*` entries; one-line index in [`Data/docs/decisions-index.md`](Data/docs/decisions-index.md)).
Konsol's API: [`Data/docs/konsol-api.json`](Data/docs/konsol-api.json), generated from the route table.

**How generation 2 was built (DD-271):** on the branch `yeni-yapi`, merged to `main` as 2.0.0 on
2026-10-18 (S2). The plan, its decisions (K1–K9, A1–A7, S1–S4), the phases with their checklists and the
checks each phase passed are in [`Data/docs/rebuild.md`](Data/docs/rebuild.md), the record of how
generation 2 was built; the phases' entries are **DD-272** to **DD-276** and **DD-278**; the last 1.x release (1.2.0) is **DD-277**.

Cursor rules for the tree:
`.cursor/rules/master-stack.mdc`.

The installer is destructive: firewall, systemd, network state. Treat every change as production-infrastructure work.

## Language Rules

- **Speak to the user in Turkish.** Conversational replies only.
- **Operator-facing strings are Turkish** (messages printed by
  `install.sh` and helpers). Match existing style in each file.
- **Markdown documentation and commit messages stay in English.**
- **`tests/*.bats` stay English** for comments and `@test` names
  (Turkish `@test` names break `bats` under `tr_TR.UTF-8`).
- Keep each artifact internally consistent.

## Execution Rules

- **The `nrm` host is a disposable test target under standing
  authorization (2026-07-31, reaffirmed 2026-10-03; data loss is acceptable
  until explicitly revoked).** Unless the user says otherwise, on `nrm`
  only: run the installer, `sudo`, mutating `systemctl`, firewall
  changes, wipes, and reboots without per-turn approval. Drive the installer
  with `kur.sh` (or `install.sh` from a checkout) and a scratch domain on a first install.
  The installer asks for no accounts:
  the Konsol account is the operator's, created by them in Sistem → Hesap over
  Tailscale (**DD-205**; the tailnet asks for no sign-in, the public name needs
  the account) — never create or keep one on their behalf; scripted checks use
  `sudo master-konsol oturum-ac` sessions where a session matters, and
  `konsol-login-live.py` runs only while no account exists and resets afterwards.
  Folder shares are managed in Konsol (Dosyalar → Paylaşımlar); an application's
  passwords and other secrets are the inspector's questions in Uygulama ekle and
  become Podman secrets (**DD-274**). Add and
  remove test peers with `master-wg`/`wireguard.command` (never print a
  profile; QR codes of test peers only). Answer the
  re-run questions with their defaults and `E` at the confirmation, and report
  what was used. **Do not create server-side backups for installations on `nrm`
  (explicit instruction, 2026-10-03).** The goal is to prove the written code works
  on the real server; data loss is acceptable. Use scoped fixtures when useful,
  without adding preservation or backup steps to the installation workflow.
  The earlier instruction to preserve a real Infuse credential on `nrm` is
  superseded by the user's latest test-host instruction. Other hosts are not covered.
  Non-default config values still need the user.
- **Never open, print or copy `kurulum/kurulum.env`** — it holds the
  operator's SSH host for `wireguard.command` and `onar.command`, not service passwords. Downloaded device
  profiles contain private keys and must also stay
  private. There is no Tailscale auth key any more
  (**DD-147**): the node joins through the login link. Running `wireguard.command`
  with the operator's folder is allowed only when the user asks for it in chat.
- **Relay only the Tailscale login URL** (`https://login.tailscale.com/a/...`)
  and wait; it expires if left unused.
- That authorization does **not** cover: local Mac outside this repo;
  `git reset --hard`, `git push`, force-push, tag deletion, history
  rewrite; other hosts; Tailscale account/ACL changes; publishing repo
  content elsewhere.
- Read-only inspection is always fine.
- **Report what was actually run** and the real outcomes.

## Working Conventions

- Prefer static analysis first (`bash -n`, `shellcheck`, `bats tests`).
  Escalate to live `nrm` installs when static review cannot catch the
  failure mode — still report destructive commands.
- Analyze before editing; check `docs/design-decisions.md` and
  `docs/contract.md` before "fixing" intentional behaviour.
- Wait for approval before making changes unless the user already asked
  for that change.
- Smallest possible change. No opportunistic refactors.
- Show the diff before committing. Commit only when the user asks (unless
  a user rule says otherwise for that turn).
- Keep version history in Git. `kur.sh` installs whatever `main` holds (**DD-228**):
  every push to `main` reaches the next install, so `main` must stay installable.
  There is no exported installer to rebuild.
- Releases (**DD-260**): `OBHUT_SURUM` in `install.sh` is the semantic version people see; change it
  only when the user asks for a release, then turn `[Unreleased]` into `## [X.Y.Z] — <date>` in
  `CHANGELOG.md`, tag `vX.Y.Z` and publish the GitHub release. `V2_VERSION` stays the build number
  that servers compare.
- Bump `V2_VERSION` in `install.sh` on every behavioural change to the
  installer tree. Record user-facing changes under `[Unreleased]` in
  `CHANGELOG.md` and add a `DD-*` entry when rationale is non-obvious.
- Preserve idempotency: re-runs against a provisioned host must stay safe.
- Prefer security over convenience when both achieve the same result; flag
  the trade-off.
- Single source of truth for ports/paths/chain names:
  `config/defaults.env`. Do not restate literals elsewhere.
- Do not grow a general-purpose reconcile engine (contract + rules).

## Key Paths

| Path | Purpose |
|------|---------|
| `kur.sh` (root) | Server bootstrap (**DD-228**): downloads the repository archive (`main`, or `KUR_REF=<commit\|tag\|branch>`; `KUR_URL` takes an archive of a tree not on GitHub yet, `https://` or a `file://` path on the server), places the runtime tree in `/root/debian-server-installer` atomically and starts `install.sh` on the terminal. Konsol's "Güncelle" runs it through `master-guncelle`, pinned to a commit and its `V2_VERSION` (`KUR_GUNCELLE`, **DD-233**) |
| `.claude/` (root) | Claude Code's project setup: `settings.json` asks before `git push`, `git reset --hard`, tag deletion and history rewrites, and wires two hooks: `hooks/kurulum-koru.py` refuses a tool call that names `kurulum/` or its `kurulum.env` (also a command line that only mentions it: write such text with the file tools; a recursive search or archive of the repository root from the shell is not seen, so never run one there), `hooks/kabuk-denetle.py` runs `bash -n` and shellcheck on a shell script right after it is edited. Skills: `sinama` (the full local check round of `Data/tests/README.md`) and `nrm-dene` (the working tree on the test host through `kur.sh`, only when the user asks). Agent: `obhut-denetci` (a read-only review of a change against these rules before a commit) |
| `kurulum/kurulum.env` (root) | `SSH_HOST` of `wireguard.command` and `onar.command`, Git-ignored, mode 600; template `Data/config/kurulum.env.example` |
| `wireguard.command` (root) | WireGuard device menu over SSH (**DD-124**, **DD-143**): pick a network, list/add/remove/QR, 7) DNS change, 8) regenerate the network after typing `onayla`; it runs the server's `master-wg` and refuses a server whose build differs from the checkout's. No server backup/restore; only explicitly downloaded device profiles and QR codes are kept on the Mac |
| `onar.command` (root) | "Denetle ve onar" over SSH when Konsol cannot be reached (**DD-239**): runs `master-onar` (or `master-onar --denetle`) on the server |
| `kurulum/wireguard/` (root) | Only what `wireguard.command` downloads on request: device profiles and their QR pictures (**DD-132**), mode 600. The installer never reads this folder and nothing is sent to the server (**DD-143**) |
| `Data/install.sh` | Orchestrator, stages 0–7: gates and the one input (the generation gate `check_generation`, the domain, one confirmation), packages (with Podman, `catatonit`, `wireguard-tools`, `qrencode`), Tailscale, addresses and the user area, tools and units, firewall, dnsmasq + Caddy + Konsol + the built-ins, verification. `V2_VERSION` (build), `OBHUT_SURUM` (release), `OBHUT_NESIL` (generation) |
| `Data/common.sh` | Shared helpers (OS gate, atomic writes, templates, locks, retries) |
| `Data/config/defaults.env` | Ports, paths and chain names of the base, WireGuard's `WG_*` keys, the application folders (`UYGULAMA_STATE_DIR`, `UYGULAMA_VERI_DIR`), the loopback pool (`UYGULAMA_PORT_ILK`–`UYGULAMA_PORT_SON`), the generation gate's `NESIL_FILE` and `ESKI_NESIL_IZLERI`; `VPN_BLOCK_DEST4/6` is the firewall's and the container guard's vocabulary |
| `Data/panel/master_yaml.py`, `master_compose.py`, `master_kube.py`, `master_inspector.py` | Reading and inspecting (**DD-273**, pure): the YAML subset reader (K4; anchors, aliases, tags and the like stop with their line), Compose and Kubernetes YAML into one model, the inspector (refusals with their lines, guesses, questions; `check()` turns the answers into the checked definition and the secret values) |
| `Data/panel/master_generator.py` | The generator (**DD-274**, pure): definition + allocations → Quadlet units (`konsol-<app>.network`, `konsol-<app>_<service>.container`, `konsol-<app>.pod`), env files, folders, `/srv` binds, start order, publications; every key checked against Podman 4.9's Quadlet, what needs Podman 5 named |
| `Data/panel/master_applications.py` | Applications (**DD-274**, **DD-275**): the record and its access rows, the loopback pool, the container guard's input, the read model, the cleanup's items, folder sizes and the drafts (K2: an `https` address, an image name; no container is taken over, **DD-290**) |
| `Data/panel/master_container_worker.py`, `master_container_manager.py` | The root worker (install, start, stop, restart, update image, edit definition, refresh from source, remove, Podman's cleanup, an access row's container side and `--adres-yenile`; each a job with a durable record and its log in `KONTEYNER_STATE_DIR/operations/`, undone in reverse on failure) and the broker (inventory, the read model with live state, jobs through `systemd-run` with the request on standard input only, image update checks, journal) |
| `Data/panel/master_container_network.py`, `master_container_binds.py`, `master_container_config.py`, `master_containers.py` | The container guard (nft table `KONTEYNER_NFT_TABLE`: egress only to the internet, DD-224; a raw row's ingress permit, DD-275), bind anchors pinned at every start (**DD-226**), shared pieces, the read-only Podman mapper (**DD-208**) |
| Application records | `UYGULAMA_STATE_DIR/<app>/` (0700 root, files 0600): `kaynak.yaml` (the file as given), `kaynak.json`, `yanitlar.json` (never a secret value), `tanim.json` (checked definition), `yerler.json` (pool ports, Podman secret names, pinned digests, stopped, revision), `erisim.json` (the access rows), `env/`. Units in `KONTEYNER_BIRIM_DIR`; data in `UYGULAMA_VERI_DIR/<app>/<folder>/` (A5); the bridge `ksl-<app>`. The record is the single source; nothing runs unasked |
| Access rows | Row model in `erisim.json` keyed `<service>:<port>/<proto>`, row id `uygulama:<app>:<key>` (**DD-275**); Konsol's and Paylaşımlar' fixed rows in `SETTINGS_FILE` `web` (**DD-191**, **DD-195**). `master_publications.py` projects them (`CADDY_MODULES_DIR/uygulama-<app>.caddy`, `uygulama-<app>-wan.caddy`, `panel-wan.caddy`, `paylasim.caddy`; `DNSMASQ_CONF_DIR/modul-uygulama.conf`); `master_erisim.py` is Erişim's read model; `master_https.py` the pinned certificate and DNS checks |
| `Data/panel/master_settings.py` | The settings transaction (**DD-156**, **DD-265**, **DD-275**): plan → apply → timed confirmation → commit or rollback, in its own systemd unit under the installer's lock, with `master-settings-guard.timer`; sections `rules` (firewall, DNS), `domain`, `web`, `erisim`, `wireguard` (`AyarIstegi`) |
| `Data/scripts/master-wg`, `Data/panel/master_wireguard.py`, `Data/systemd/wg-quick-master-stack.conf` | WireGuard built in (**DD-272**): the server-side tool (installed to `SBIN_DIR` in stage 4; `durdur`/`baslat`, networks wg0…wg9 in `WG_NETWORKS_FILE`, the settings worker's caller mode, **DD-275**), Konsol's typed routes under `/api/konsol/wireguard`, the `wg-quick@` drop-in. The firewall reads the networks file and `WG_STOPPED_FILE` itself |
| `Data/panel/master-panel`, `master_api.py`, `master_olaylar.py` | Konsol's root backend (Python stdlib, root, Unix socket `PANEL_SOCKET` only, **DD-180**). It answers only the route table in `master_api.py` (request and reply shapes; `python3 panel/master_api.py openapi\|ts` generates `docs/konsol-api.json` and `tools/konsol-ui/src/api/sema.ts`) plus `/oturum-denetle` and the sign-in POST (**DD-272**); live events (Server-Sent Events read with fetch, **DD-259**) |
| `Data/panel/master_auth.py`, `Data/scripts/master-konsol` | Konsol account and sessions (**DD-194**, **DD-205**): Caddy `forward_auth` asks `/oturum-denetle` before every protected panel request; the tailnet address passes without a sign-in, the public name needs the account (scrypt hash, SHA-256 session tokens in `KONSOL_AUTH_DIR`, 0700 root), which the operator creates in Sistem → Hesap over Tailscale. Root CLI: `master-konsol durum\|sifirla\|oturum-ac\|oturum-kapat` |
| `Data/scripts/obhut`, `Data/panel/master_obhut.py` | `sudo obhut` (**DD-268**): `durum`, `denetle`, `onar`, `guncelle`, `hesap durum\|sifirla`, `uygulama liste\|baslat\|durdur\|yeniden-baslat`, `erisim liste\|kapat <row>\|--hepsi` (closes internet access at once), `geri-al`; over Konsol's socket, falling back to systemd's unit states |
| `Data/scripts/master-onar`, `Data/panel/master_onar.py` | Check and repair (**DD-239**, **DD-241**): 21 fixed steps that put the installer's own settings back; Konsol's Sistem → Sağlık runs it as `ONARIM_UNIT`, `master-duvar-denetim.timer` runs `--duvar` hourly |
| `Data/scripts/master-guncelle`, `Data/panel/master_update.py` | Konsol's "Güncelle" (**DD-233**): the GitHub check (only builds of the same generation, **DD-272**) and the pinned re-run as `GUNCELLEME_UNIT` |
| `Data/files-panel/master-files-panel` | Built-in Files backend (`master-files-panel`, loopback `FILES_PANEL_PORT`, downloads uid, no password; trash in `.cop`) behind Dosyalar' Sunucu klasörleri and Çöp kutusu; with `--sistem` it is Sistem dosyaları (unit `master-sistem-dosya`, root over `/`, Unix socket `SYSTEM_FILES_SOCKET`, Caddy `/api/sistem/*` on the tailnet site only, permanent delete by name, **DD-235**). Both units are rendered straight into `UNIT_DIR` (**DD-272**) |
| Built-in WebDAV (`paylasim`) | **DD-158/179/190/192:** `master_shares.py` owns `SHARE_STATE_FILE` (`/etc/master-stack/webdav.json`, 0600 root, scrypt hashes, schema 4); `master_webdav.py` runs as the downloads uid with a systemd credential (`master-paylasim.service`); `master-share-network.timer` enforces expiry. Each folder's `/s/<id>/` and account are shared by two independent Tailscale/WAN policies. Dosyalar → Paylaşımlar shows one card per share with both connections. See contract.md and `Data/docs/folder-shares.md` for limits and recipient ACL requirements |
| `Data/console/` | The sign-in page `giris.html`/`.js`/`.css`, the editor bundle `duzenleyici.js` (built from `Data/tools/duzenleyici`, **DD-249**), the Ô mark `obhut.svg`/`obhut.png` (**DD-256**) and `yeni/`, Konsol's committed build (with `manifest.json` and `obhut-192.png`/`obhut-512.png`, **DD-268**). The installer places these at the root of `CONSOLE_WEB_DIR` and deletes every other file there (**DD-267**); Caddy serves them at `panel.<domain>` on the tailnet, optionally on a public HTTPS name (**DD-195**) |
| `Data/tools/konsol-ui/` | Konsol's interface (**DD-258**, **DD-276**): Vue 3 + TypeScript + Vite sources (not shipped), built with `npm ci && npm run derle` into `console/yeni/` (the folder keeps its phase name); `console/yeni/kaynak.sha256` must match the sources (`kaynak-ozeti.sh`). Eight sections, plus Uyarılar (`#/uyarilar`, the page the top bar's count opens, **DD-285**): Genel Bakış, Uygulamalar (list, Uygulama ekle as a full-window page with the install's log (**DD-279**), each application's page: Özet, Erişim, Depolama, Tanım, Günlük), Podman (summaries, the containers, images/volumes/networks/leftover folders with the one write, removing what nothing uses, **DD-289**), Erişim (Genel, Adresler with each row's panel under the row (**DD-283**), Yerel adlar, Güvenlik duvarı; no Tailscale tab, **DD-288**), WireGuard (`#/wireguard`: the networks as tabs, their devices, QR codes and profiles, **DD-291**), Dosyalar (Depolama, Sunucu klasörleri, Çöp kutusu, Paylaşımlar, Sistem dosyaları), Sistem (Sağlık, Güncellemeler, Hesap, Sunucu with the Tailscale device, İşlem geçmişi) and Gelişmiş (read-only) |
| `Data/scripts/` | `firewall.sh` (installed as `master-firewall`), `refresh-tailnet-config`, `wait-tailnet-addr`, `tailscale-udp-gro`, `master-wg`, `master-onar`, `master-guncelle`, `master-konsol`, `obhut` |
| `Data/systemd/` | Unit, timer and drop-in templates: the backends (`master-panel`, `master-files-panel`, `master-sistem-dosya`, `master-paylasim`), `master-firewall`, the timers (`master-settings-guard`, `master-share-network`, `refresh-tailnet-config`, `master-duvar-denetim`), `tailscale-udp-gro` and the `wg-quick@` drop-in |
| `Data/templates/` | `Caddyfile` (the `(konsol)` snippet, the tailnet site, the import folder), `dnsmasq.conf`, `paylasim.caddy`, `paylasim-dnsmasq.conf` |
| `/etc/wireguard/networks` (host) | WireGuard's network registry, written by `master-wg net-add/net-remove`, read by `master-firewall`, `refresh-tailnet-config`, the installer's check and Konsol (**DD-136**) |
| `Data/tests/` | Bats, Python unittest, Playwright, layout audit, Linux namespace and live suites; `panel-harness.py` runs the backend with a test's values (never installed). See `Data/tests/README.md` |
| `Data/docs/contract.md` | What the installer and Obhut do and refuse |
| `Data/docs/architecture.md` | Layout and data flow |
| `Data/docs/design-decisions.md` | `DD-*` rationale |
| `Data/docs/decisions-index.md` | One line per `DD-*` entry with its status and file |
| `Data/docs/rebuild.md` | How generation 2 was built (**DD-271**) |
| `Data/docs/archive/` | Historical documents and retired `DD-*` entries (`design-decisions-retired.md`), older `CHANGELOG.md`/session history; not current behaviour |

## Constraints

- Root-only, single-host. The only input is the local domain, asked on the
  server terminal (**DD-228**); the installer needs a TTY and one confirmation. No unattended mode,
  except Konsol's "Güncelle" re-run of an existing install (**DD-233**: pinned commit, Tailscale-only start).
- Clean installs only (**DD-271** K1 and S3, **DD-272**): stage 0 stops before any write when `STATE_DIR`
  exists without `NESIL_FILE` holding `OBHUT_NESIL`, or when a path in `ESKI_NESIL_IZLERI` exists. No
  migration code, no option accepted and ignored, no redirect for old addresses; Konsol's update check
  offers only builds of the same generation. A removed feature leaves no file, unit, route, setting key,
  test or text behind (rebuild.md ground rule 2).
- Debian 13 (trixie), Ubuntu 24.04 (noble) or Ubuntu 26.04 (resolute)
  only (**DD-102**). Generation 2 is live-verified on Debian 13 (DD-272 to DD-276). Ubuntu 24.04's
  Podman 4.9 refuses, before any write, a Kubernetes Pod with more than one container and a Compose
  `condition: service_healthy` (both need Podman 5, **DD-274**).
- The built-ins are fixed: Konsol, Tailscale (exit node), Caddy, dnsmasq, the firewall, Files with
  Sistem dosyaları on the tailnet (**DD-235**), folder WebDAV and WireGuard. WireGuard is installed turned
  off: the installer creates no network; Konsol's WireGuard section (or `master-wg net-add`) creates them, and
  WireGuard devices reach only the internet (**DD-177**). Podman is base infrastructure (**DD-208**: no
  daemon, socket or auto-update timer); there is no Docker.
- Applications are Podman containers only, added from a Compose or Kubernetes file (or from an image name,
  turned into a draft file first, K2); a container Obhut did not install never becomes one (**DD-290**).
  Nothing in the shipped tree names an application: no mechanism, default, code path, fixture name or
  interface text of its own (**DD-271**, **DD-273**). The supported keys and kinds and the refusals are
  listed in rebuild.md 4.2 and the contract. Every TCP port is answered by the operator (A1), UDP ports
  are raw and closed (A2), each container's start mode is asked (A4; privileged mode never), binds come
  only from `/srv` folders and the application's own folder (A5), secret values become Podman secrets on
  standard input and never reach a file, log or reply, images are pinned by digest (`Pull=never`) and
  updated only on the operator's confirmation (**DD-214**), each application has its own bridge and its
  containers reach only the internet (**DD-224**). Removing an application deletes its data and its job
  records once its name is typed, unless the operator keeps the data, and its images when nothing else
  uses them (K9 as amended by **DD-281**).
- A container port reaches outside only through its access row (**DD-275**): an address (a Caddy row to a
  `127.0.0.1` pool port: Tailscale name, optional Tailscale port, optional internet name) or a raw port
  (closed, Tailscale or internet; the internet needs an extra consent; published on the Tailscale or WAN
  IPv4). The file's own host ports are never used. Every access change (application rows, Konsol's and
  Paylaşımlar' rows, WireGuard's openings) is a settings plan: an opening, widening or rename waits for
  the 60 s confirmation from Tailscale and rolls back unconfirmed; a closing commits at once; the local
  domain waits 300 s. An application's internet name is guarded only by the application's own login.
- DD-195: the Panel row's Tailscale switch is fixed on; its optional public HTTPS name imports the same
  `(konsol)` Caddy snippet (session check, Host pinned to `panel.<domain>`, Caddy-written
  `X-Konsol-Kanal`), needs an existing Konsol account and the typed word, refuses account creation and
  adds a shared public sign-in budget.
- DD-179/190/192: each folder has independent Tailscale/WAN connection policies (enabled, RO/RW, expiry);
  both off is valid. New shares use Tailscale on (while that transport is published)/RO/seven days and WAN
  off/RO/seven days. The registry is schema 4 only: another schema or a key this version does not write
  fails closed. Nested partial saves preserve omitted fields under locks; explicit RW requires same-scope
  acknowledgement. Share edits restart active WebDAV and interrupt transfers. WebDAV's internet name
  (Erişim → Adresler, the Paylaşımlar row) uses Let's Encrypt TLS-ALPN on `SHARE_HTTPS_PORT` (443), with
  DNS resolving only to the assigned WAN IPv4; no WAN port 80 or DNS API token. Without an internet name,
  consent-gated plain HTTP on `SHARE_PORT` (61010) remains; switching the name off closes WAN, never
  downgrades to HTTP. Configured HTTPS keeps its listener for renewal even with no active folders.
  Independent scope/auth enforcement and attempt/connection budgets remain mandatory. See
  `Data/docs/folder-shares.md` for limits and the scoped expiry timer.
- All public names (Konsol, WebDAV, applications) share TCP 443 and its socket budgets. No tunnel, no
  upstream other than a `127.0.0.1` port, no automatic DNS writes. Certificate readiness is a local
  pinned-IP trust/hostname check, not proof of public reachability.
- The security floor (rebuild.md ground rule 7): the root backend on a Unix socket behind Caddy's
  `forward_auth`, answering only its route table, `/oturum-denetle` and the sign-in POST; the CSP (no inline
  code, no `eval`, nothing from elsewhere); the tailnet first; typed words for irreversible actions; plan →
  apply with a timed confirmation for anything that can cut the operator off; repair (`master-onar`). The
  Konsol backends themselves stay private (socket/loopback). No switch, environment value or hidden option
  exists only for tests in a shipped file (ground rule 3; tests use `tests/panel-harness.py`).
- Request and reply shapes live in the route table (`panel/master_api.py`); `docs/konsol-api.json` and
  `tools/konsol-ui/src/api/sema.ts` are generated from it, and the committed build must match its sources.
- Do not delete or recreate other software's iptables chains (Tailscale's
  `ts-*`); manage only the project chains (`CHAIN_*`) and the container guard's nft table. Netavark owns
  the containers' DNAT/SNAT.
