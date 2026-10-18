# Design decisions index

Every `DD-*` number with its title, status and file, sorted by number (DD-89 belonged to the reverted v2-52 copyparty change and lives only in Git history; DD-90, DD-91 and DD-234 were never assigned).
`live` entries are current rules in `design-decisions.md`; superseded and historical entries are kept verbatim in `archive/design-decisions-retired.md`.
Entries the rebuild (DD-271 to DD-276) retired name it in their status; live entries it retired in part say so and end with a note in `design-decisions.md`.

| DD | Title | Status | Where |
|---|---|---|---|
| DD-1 | Atomic staging-chain swap for firewall rules | live | design-decisions.md |
| DD-2 | Canonical-bundle SHA256 manifest for reconcile | historical | archive/design-decisions-retired.md |
| DD-3 | Reconcile reverts operator edits instead of merging them | historical | archive/design-decisions-retired.md |
| DD-4 | `PartOf` fate-sharing between core daemons and managed units | superseded by DD-75 | archive/design-decisions-retired.md |
| DD-5 | Reconcile avoids restarting core daemons synchronously | historical | archive/design-decisions-retired.md |
| DD-6 | Fail-closed masking for optional DNS/Caddy services | live | design-decisions.md |
| DD-7 | wg-easy admin/peer setup is manual | historical | archive/design-decisions-retired.md |
| DD-8 | Docker daemon DNS hardcoded to public resolvers | historical | archive/design-decisions-retired.md |
| DD-9 | Everything lives in one script, deployed via heredocs | superseded by DD-58 | archive/design-decisions-retired.md |
| DD-10 | `wg-easy`'s WireGuard kernel module is loaded independently of Tailscale | superseded by DD-120 | archive/design-decisions-retired.md |
| DD-11 | UDP GRO forwarding is applied once, not continuously reconciled | live | design-decisions.md |
| DD-12 | wg-easy's pending first-run setup must never gate Stage 7 or `--check` | historical | archive/design-decisions-retired.md |
| DD-13 | Reconcile's disk-space check reports but never auto-repairs | historical | archive/design-decisions-retired.md |
| DD-14 | The canonical bundle is published through a verified generation pointer | historical | archive/design-decisions-retired.md |
| DD-15 | Docker's chain layout is assumed, and Docker itself is deliberately not pinned | historical | archive/design-decisions-retired.md |
| DD-16 | Managed firewall rules never reference container IPs | historical | archive/design-decisions-retired.md |
| DD-17 | Nothing persists firewall rules to disk | live | design-decisions.md |
| DD-18 | UDP socket buffer ceilings are floored by the installer, and they are a Tailscale setting — not a WireGuard one | live | design-decisions.md |
| DD-19 | The Tailscale login stays in Stage 2 — reordering it was tried, measured, and reverted | live | design-decisions.md |
| DD-20 | WebDAV is a hardened host service (rclone), not a container | superseded by DD-158 | archive/design-decisions-retired.md |
| DD-21 | The reconcile timer runs every 20 minutes, aligned with the repair cooldown | historical | archive/design-decisions-retired.md |
| DD-22 | A wg-easy still on its `/setup` screen is reported, not failed | historical | archive/design-decisions-retired.md |
| DD-23 | Container images float at the patch level, and their digests are recorded | historical | archive/design-decisions-retired.md |
| DD-24 | Network steps get a bounded retry and a mandatory timeout | live | design-decisions.md |
| DD-25 | The repair cooldown is duplicated on purpose, and asserted | historical | archive/design-decisions-retired.md |
| DD-26 | Reserved (not used on this branch) | historical | archive/design-decisions-retired.md |
| DD-27 | FileBrowser Quantum replaces filebrowser, and its admin password is deliberately not set | historical | archive/design-decisions-retired.md |
| DD-28 | The WebDAV directory cache is one minute, and `--poll-interval` is deliberately absent | historical | archive/design-decisions-retired.md |
| DD-29 | The policy file's target is normalised before writing, container included | historical | archive/design-decisions-retired.md |
| DD-30 | Reconcile reports the default filebrowser password without failing on it | historical | archive/design-decisions-retired.md |
| DD-31 | Inodes are checked separately from bytes, and `-` counts as healthy | historical | archive/design-decisions-retired.md |
| DD-32 | The Quantum policy file joins the canonical bundle | historical | archive/design-decisions-retired.md |
| DD-33 | The default-password probe runs once per cycle, and `429` is reported as unknown | historical | archive/design-decisions-retired.md |
| DD-34 | Unpackerr's file log is given a rotation cap, and the queue heartbeat is slowed to 30m | historical | archive/design-decisions-retired.md |
| DD-35 | The Quantum policy file stays a separate host file, because `read_only: true` forbids the alternative | historical | archive/design-decisions-retired.md |
| DD-36 | Three file-manager alternatives investigated, FileBrowser Quantum kept | historical | archive/design-decisions-retired.md |
| DD-37 | The interactive Tailscale login recovers by timeout, not by diagnosing the failure | live | design-decisions.md |
| DD-38 | DNS/Caddy file rollback commits with the canonical pointer | historical | archive/design-decisions-retired.md |
| DD-39 | Journal classifiers consume their complete producer stream | historical | archive/design-decisions-retired.md |
| DD-40 | FileBrowser policy replacement and activation are one retryable operation | historical | archive/design-decisions-retired.md |
| DD-41 | Reconcile repairs bounded local state, but exposes core failures | historical | archive/design-decisions-retired.md |
| DD-42 | Persistent Tailscale 410 is classified from LocalAPI, never the journal | live | design-decisions.md |
| DD-43 | Exit-node and Tailscale SSH are requested by `tailscale up`, then held by `tailscale set` | live | design-decisions.md |
| DD-44 | `install.sh` comments say what a block does; the rationale lives here | historical | archive/design-decisions-retired.md |
| DD-45 | The firewall helper requires ip6tables instead of degrading toward it | live | design-decisions.md |
| DD-46 | A failed canonical bundle verification degrades reconcile instead of aborting it | historical | archive/design-decisions-retired.md |
| DD-47 | `cleanup_master_setup` asks `canonical_stage_is_current` instead of re-deriving it | historical | archive/design-decisions-retired.md |
| DD-48 | `probe_compose_runtime` measures; the caller reports | historical | archive/design-decisions-retired.md |
| DD-49 | Every unit on the `OnFailure` arc is restarted behind the repair cooldown | historical | archive/design-decisions-retired.md |
| DD-50 | The installer has one definition of "online", and its waits count time rather than iterations | live | design-decisions.md |
| DD-51 | Stage 2 bounces the tailscaled daemon without bouncing the stack | live | design-decisions.md |
| DD-52 | `--check` does not pay a readiness wait for a value no rule uses | historical | archive/design-decisions-retired.md |
| DD-53 | The media-tree ownership repair never dereferences | live | design-decisions.md |
| DD-54 | Readability is not trust — reconcile stops reading configuration from a bundle it rejected | historical | archive/design-decisions-retired.md |
| DD-55 | Every wait that promises a duration now measures one | live | design-decisions.md |
| DD-56 | The Compose stack does not depend on the Tailscale address | historical | archive/design-decisions-retired.md |
| DD-57 | A probe in a predicate position puts back what it measured | historical | archive/design-decisions-retired.md |
| DD-58 | v2 abandons the single-file model — supersedes DD-9 | live | design-decisions.md |
| DD-59 | The firewall owns two chains, named once | live | design-decisions.md |
| DD-60 | dnsmasq binds loopback and `tailscale0`, and nothing else | live | design-decisions.md |
| DD-61 | `refresh-tailnet-config` restarts address-bound units and does nothing else | live | design-decisions.md |
| DD-62 | Portainer is proxied to loopback HTTPS on 9443 (with the earlier DD-62-archive block) | historical; see DD-116, DD-151 | archive/design-decisions-retired.md |
| DD-63 | qBittorrent peer port is TCP+UDP | superseded by DD-151 | archive/design-decisions-retired.md |
| DD-64 | Tailscale address refresh without a long-running watcher | live | design-decisions.md |
| DD-65 | Edge apt install keeps units masked; quiet the preset noise | live | design-decisions.md |
| DD-66 | Runtime firewall values come from state, not script fallbacks | live | design-decisions.md |
| DD-67 | Re-runs skip full-upgrade and unchanged edge/compose restarts | live; amended by DD-228 | design-decisions.md |
| DD-68 | Stage 7 covers the cheap contract §14 checks | live | design-decisions.md |
| DD-69 | Downloads tree is recursively `1000:1000` for stack R/W | superseded by DD-84, DD-144 | archive/design-decisions-retired.md |
| DD-70 | Portable export verifies SHA-256 and extracts atomically | live; amended by DD-228 | design-decisions.md |
| DD-71 | IPv6 `MASTER-DOCKER` drops WAN only, like IPv4 | historical; see DD-152 | archive/design-decisions-retired.md |
| DD-72 | Address-bound units wait, fail visibly, and get recovered | live | design-decisions.md |
| DD-73 | `MASTER-INPUT` accepts the Tailscale UDP port itself | live | design-decisions.md |
| DD-74 | Tailscale stateful filtering stays on, deliberately | live | design-decisions.md |
| DD-75 | Host firewall converges without Docker; address units drop PartOf | live | design-decisions.md |
| DD-76 | Compose does not own the WireGuard endpoint hint | historical; see DD-152, DD-144 | archive/design-decisions-retired.md |
| DD-77 | WebDAV runs in Compose on loopback, not as a host unit | historical; see DD-152, DD-158 | archive/design-decisions-retired.md |
| DD-78 | Caddy WebDAV site aliases the Tailscale IPv4 | superseded by DD-98 | archive/design-decisions-retired.md |
| DD-79 | Host WebDAV leftovers are purged on every Stage 4 | historical; see DD-96 | archive/design-decisions-retired.md |
| DD-80 | `refresh-tailnet-config` waits with `tailscale wait` | live | design-decisions.md |
| DD-81 | Stage 7 proves WebDAV read-only via inspect, not PUT 401 | historical; see DD-152, DD-158 | archive/design-decisions-retired.md |
| DD-82 | WebDAV healthcheck and isolated `webdav` network | historical; see DD-152 | archive/design-decisions-retired.md |
| DD-83 | Compose images are tag@digest pins, not floating tags | historical; see DD-97, DD-152 | archive/design-decisions-retired.md |
| DD-84 | Selective downloads ownership repair + P3 hygiene | live | design-decisions.md |
| DD-85 | `wait-tailnet-addr` requires the state IPv4 on the interface | live | design-decisions.md |
| DD-86 | Unusable-tailnet warning names BackendState and Online | live | design-decisions.md |
| DD-87 | Caddy `OnFailure` starts `refresh-tailnet-config` | live | design-decisions.md |
| DD-88 | Stage 7 asserts Caddy UI sites are non-5xx | superseded by DD-147, DD-154 | archive/design-decisions-retired.md |
| DD-92 | Classic FileBrowser replaces Quantum | historical; see DD-146 | archive/design-decisions-retired.md |
| DD-93 | Firewall Docker re-apply + install path hygiene | live | design-decisions.md |
| DD-94 | The firewall converges; it does not fail with no policy | live | design-decisions.md |
| DD-95 | Counting WAN allows, and adopting referenced staging | live | design-decisions.md |
| DD-96 | The installer owns its own files and nothing else | live | design-decisions.md |
| DD-97 | Prefer upstream stable tracks over patch@digest pins | historical; see DD-152 | archive/design-decisions-retired.md |
| DD-98 | Infuse uses Caddy on Tailscale IP:WEBDAV_PORT | live | design-decisions.md |
| DD-99 | Image pull is a re-run prompt, not a background reconciler | historical; see DD-151, DD-152 | archive/design-decisions-retired.md |
| DD-100 | Skip a repo's apt-get update when its source file didn't change | live | design-decisions.md |
| DD-101 | The opted-in pull has a fail-closed disk floor | historical; see DD-151, DD-152 | archive/design-decisions-retired.md |
| DD-102 | Supported-OS matrix — Debian 13 plus the two Ubuntu LTS lines | live | design-decisions.md |
| DD-103 | The installer owns every restart it triggers | live | design-decisions.md |
| DD-104 | The OS is recorded, not just detected | live | design-decisions.md |
| DD-105 | sysctl drop-ins must sort last, and the runtime value is what counts | live | design-decisions.md |
| DD-106 | Fail early, with the real cause | live | design-decisions.md |
| DD-107 | Container logs are rotated | historical; see DD-110, DD-152 | archive/design-decisions-retired.md |
| DD-108 | A gate may only assert what the host already has | live | design-decisions.md |
| DD-109 | A setting whose effect is not guaranteed gets read back | live | design-decisions.md |
| DD-110 | Daemon config before the daemon; log policy in the service definition | historical; see DD-152 | archive/design-decisions-retired.md |
| DD-111 | TCP congestion control is BBR, measured before adopting it | live | design-decisions.md |
| DD-112 | Backups are password-encrypted with the OS's `openssl`; restore uploads once | historical; see DD-122 | archive/design-decisions-retired.md |
| DD-113 | Security updates install themselves; reboots stay with the operator | live; parts superseded by DD-184 | design-decisions.md |
| DD-114 | Container backups carry one operator-state file per service | historical; see DD-122 | archive/design-decisions-retired.md |
| DD-115 | An optional Tailscale auth key replaces the browser step | historical; see DD-147 | archive/design-decisions-retired.md |
| DD-116 | Dozzle replaces Portainer | historical; see DD-151 | archive/design-decisions-retired.md |
| DD-117 | Transmission replaces qBittorrent | historical; see DD-127 | archive/design-decisions-retired.md |
| DD-118 | The installer sets up FileBrowser and Transmission; the backup keeps only wg-easy | historical; see DD-127, DD-146, DD-122, DD-120 | archive/design-decisions-retired.md |
| DD-119 | Installer inputs come from one git-ignored file, and that file is the truth | superseded by DD-228 (input file and its transport retired) | archive/design-decisions-retired.md |
| DD-120 | WireGuard runs in the host kernel from kurulum/wireguard; wg-easy is removed | live | design-decisions.md |
| DD-121 | kurulum.env lists the WireGuard peers; the server generates what is missing and hands it back | superseded by DD-124 | archive/design-decisions-retired.md |
| DD-122 | container-backup is retired; kurulum/ is the only thing to keep | live | design-decisions.md |
| DD-123 | WireGuard changes are applied the kernel WireGuard way, without a restart | live | design-decisions.md |
| DD-124 | The server generates and owns WireGuard peers; wireguard.command manages them | live | design-decisions.md |
| DD-125 | A smaller footprint — no Docker recommends, no kept apt downloads, no debian-keyring | live | design-decisions.md |
| DD-126 | Negated bats assertions must be able to fail under bash 3.2 | live | design-decisions.md |
| DD-127 | qBittorrent returns; its settings and account are its own | superseded by DD-151 | archive/design-decisions-retired.md |
| DD-128 | Pulled WireGuard and qBittorrent settings rebuild a server; restored only where absent | superseded by DD-143, DD-129 | archive/design-decisions-retired.md |
| DD-129 | The installer writes qBittorrent's settings from a template and the account from kurulum.env | superseded by DD-151 | archive/design-decisions-retired.md |
| DD-130 | wireguard.command changes a peer's DNS and regenerates wg0 | live | design-decisions.md |
| DD-131 | WireGuard client DNS default — Cloudflare IPv4 first, one IPv6 third | live | design-decisions.md |
| DD-132 | The QR code comes to the Mac as a PNG with the profile | live | design-decisions.md |
| DD-133 | A WireGuard web panel on the tailnet, built on master-wg | live; parts superseded by DD-140, DD-147, DD-180; amended by DD-269 | design-decisions.md |
| DD-134 | Regenerating wg0 is confirmed with "onayla"; the panel layout is tightened | live | design-decisions.md |
| DD-135 | WireGuard IPv6 addresses without a word: fdcc:ad94:bacf:61a4::N | live | design-decisions.md |
| DD-136 | More WireGuard networks from the panel; the panel stops pointing to the Mac backup | live | design-decisions.md |
| DD-137 | The panel's "Bağlı" follows traffic, not the handshake | live | design-decisions.md |
| DD-138 | The server's IPv4 and IPv6 are detected and stored, never written by hand | live | design-decisions.md |
| DD-139 | A file panel for the downloads folder, run as the downloads uid | live; a separate root view added by DD-235 | design-decisions.md |
| DD-140 | One console (Konsol) instead of two panels, and switchable peers | live | design-decisions.md |
| DD-141 | Share links over one read-only WebDAV, built from symlinks | superseded by DD-158 | archive/design-decisions-retired.md |
| DD-142 | One rclone; the downloads folder is never published | superseded by DD-158, DD-152 | archive/design-decisions-retired.md |
| DD-143 | The installer prepares WireGuard; Konsol creates it | live | design-decisions.md |
| DD-144 | The user area is a fixed /srv, not an asked-for path | live; amended by DD-269 | design-decisions.md |
| DD-145 | The console uploads into the list; no separate upload area | live; amended by DD-267 | design-decisions.md |
| DD-146 | Retire FileBrowser; Konsol is the file manager | historical | archive/design-decisions-retired.md |
| DD-147 | Konsol without a password; Tailscale joins by link only | partly superseded (DD-194) | design-decisions.md |
| DD-148 | A clean install is the base; Konsol installs modules | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-149 | Paylaşım is a module with a generated account | live; parts superseded by DD-158; amended by DD-272 | design-decisions.md |
| DD-150 | Dosya yöneticisi and WireGuard are Konsol modules | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-151 | qBittorrent is a host module; Dozzle and the base Compose project go | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-152 | No Docker — Paylaşım runs rclone on the host, Arşiv açıcı is dropped | live; rclone and the trash tmpfs superseded by DD-158 | design-decisions.md |
| DD-153 | The base installs only what the base uses | live; amended by DD-158, DD-272 | design-decisions.md |
| DD-154 | One console name, one current export | partly superseded by DD-228 (no exported installer); amended by DD-269 | design-decisions.md |
| DD-155 | Konsol shows the server's settings, read-only | live; parts superseded by DD-156; amended by DD-267, DD-269; amended by DD-272 | design-decisions.md |
| DD-156 | Transactional settings management in Konsol | live; amended by DD-272, DD-275; DNS name switches removed in the rebuild's phase 6 | design-decisions.md |
| DD-157 | Rename the local domain as a confirmed transaction | live | design-decisions.md |
| DD-158 | Independent folder accounts and descriptor-safe WebDAV | live; connection policy extended by DD-192 | design-decisions.md |
| DD-159 | Desktop shell with protected Files, sharing and bounded ZIP | live; ZIP/RAR and the desktop shell removed by DD-267; amended by DD-272 | design-decisions.md |
| DD-160 | Model A, one admin workspace and independent resources | live; amended by DD-267 | design-decisions.md |
| DD-161 | Compact App Store with optional details | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-162 | Explicit firewall tables without changing policy authority | live | design-decisions.md |
| DD-163 | Immediate DNS-only Apply, retaining transactional recovery | live | design-decisions.md |
| DD-164 | Incoming-network firewall tabs, not service buckets | live | design-decisions.md |
| DD-165 | One-click qBittorrent account save | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-166 | Bounded multipart and nested RAR in Files | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-167 | Edit a WireGuard network without regenerating it | live; amended by DD-177, DD-272 | design-decisions.md |
| DD-168 | Eight-character minimum for service passwords | live; amended by DD-272 | design-decisions.md |
| DD-169 | Compact trash confirmation and inline share controls | live; Shares layout superseded by DD-192; amended by DD-267 | design-decisions.md |
| DD-170 | Contextual Files dock and automatic archive extraction | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-171 | Remove dead sharing lifecycle without deleting legacy data | retired by DD-269 and DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-172 | Minimum tailnet host ingress without changing VPN requirements | live; amended by DD-275 | design-decisions.md |
| DD-173 | Tailnet port catalogue is configuration-driven, not socket-driven | live | design-decisions.md |
| DD-174 | Remove synthetic closed WAN and tunnel-local port rows | live; amended by DD-177, DD-272 | design-decisions.md |
| DD-175 | Remove obsolete firewall generation, not VPN requirements | live; amended by DD-272 | design-decisions.md |
| DD-176 | Local access by default when creating a WireGuard network | superseded by DD-177 | archive/design-decisions-retired.md |
| DD-177 | Retire Local access; WireGuard is internet-only | live | design-decisions.md |
| DD-178 | Seed qBittorrent integration, not user preferences | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-179 | Per-folder HTTP WAN opt-in with separate admission budgets | live; HTTP-only boundary superseded by DD-190, shared policy by DD-192; amended by DD-272 | design-decisions.md |
| DD-180 | Private sockets, shared login limits, disk reserve, sandboxed unrar, firewall-first WireGuard | live; qBittorrent reach amended 2026-10-05; amended by DD-267; amended by DD-272 | design-decisions.md |
| DD-181 | Remember WebDAV logins, idle rollback timer, quieter journal, compressed Konsol | live; amended by DD-267; amended by DD-272 | design-decisions.md |
| DD-182 | Capped rollback, WAN address change, watchdog resets, damaged history, health card | live; amended by DD-267 | design-decisions.md |
| DD-183 | No archive jobs page; results in Günlük, running job as a bar | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-184 | Tailscale and Caddy join unattended upgrades, at night | live | design-decisions.md |
| DD-185 | Fresh-install-only cleanup and a documentation index | live; narrow schema-3 migration exception in DD-192; amended by DD-267; amended by DD-269, DD-272 | design-decisions.md |
| DD-186 | Audit stage 1: listen queues, safe configuration reads and reserved sources | live; partly retired by DD-267, DD-272 | design-decisions.md |
| DD-187 | Audit stage 2: boot recovery guard, pinned permissions and canonical locks | live; partly retired by DD-272 | design-decisions.md |
| DD-188 | Audit stage 3: bounded authentication, short write locks and resource sandbox | live | design-decisions.md |
| DD-189 | Audit stage 4: desired-service/kernel health and IPv4 DNS projection | live | design-decisions.md |
| DD-190 | Optional public WebDAV HTTPS without widening private administration | live; amended by DD-275 | design-decisions.md |
| DD-191 | Fixed publication table with independent private and public gates | live; Panel row opened by DD-195; manual loopback addresses by DD-252; partly retired by DD-272, DD-275 | design-decisions.md |
| DD-192 | Per-connection WebDAV policies and dual-card Shares | live; amended by DD-267, DD-269; amended by DD-272, DD-275 | design-decisions.md |
| DD-193 | Cross-review follow-ups for v2-159..v2-164 | live; amended by DD-269; partly retired by DD-272, DD-275 | design-decisions.md |
| DD-194 | Konsol sign-in with a one-time setup code | live for the public name; public rules by DD-195, tailnet sign-in and the code removed by DD-205 | design-decisions.md |
| DD-195 | Konsol over public HTTPS through the publication table | live; amended by DD-272, DD-275 | design-decisions.md |
| DD-196 | The store model, phase 0 | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-197 | The store engine and package format, phase 1a | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-198 | Firewall, health and port catalogue from package declarations, phase 1b | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-199 | Publication rows from package declarations, phase 1b | retired by DD-275 (rebuild phase 4) | archive/design-decisions-retired.md |
| DD-200 | Konsol pages and application API from packages, phase 2a | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-201 | A neutral backend, package-owned settings and self-checking packages, phase 2b | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-202 | The qBittorrent page and its settings in the package, phase 2c | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-203 | Package-declared folders, settings and backend write paths, phase 3 | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-204 | CasaOS-inspired skin and an overview page for Konsol | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-205 | No sign-in on the tailnet; the account is the public name's credential | live | design-decisions.md |
| DD-206 | Overview edit mode, a server-side layout and a network card | live; widget set, width and totals table presentation amended by DD-212; edit mode and layout removed by DD-267, network card data kept; rate history and `since`/`at` removed by DD-269; partly retired by DD-272, DD-276 ; the WAN rate and its route removed by DD-287 | design-decisions.md |
| DD-207 | A package's backend write paths exist before the backend starts | live; partly retired by DD-272 (the WireGuard folder rule kept) | design-decisions.md |
| DD-208 | Podman is base infrastructure; Settings → Konteynerler is its read-only view | live; page moved by DD-211/216, bridges by DD-211/217; amended by DD-267; amended by DD-272 | design-decisions.md |
| DD-209 | qBittorrent runs as a Podman container: quadlet, digest-pinned image, host network | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-210 | App Store install form, direct app launch and the icon-only tile action row | retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-211 | Main-sidebar container manager, explicit ownership and durable Quadlet operations | live; named Podman by DD-216; amended by DD-267, DD-269; partly retired by DD-272, DD-274 (broker and guard kept) | design-decisions.md |
| DD-212 | Installed application home tiles, fixed action slots and one full-width network widget | retired by DD-267 and DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-213 | Compact Ana Menü, five-second refresh and direct container actions | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-214 | Konsol checks image updates, the operator applies them; row controls before the name | v2-193; `--veri` keeps the override since DD-220; amended by DD-267; amended by DD-272, DD-274 | design-decisions.md |
| DD-215 | The Podman page shows the ports a host-network container listens on | v2-194; qBittorrent left the host network (DD-217); amended by DD-267; amended by DD-272, DD-274, DD-276 | design-decisions.md |
| DD-216 | Applications open from Ana Menü only; the container page is named Podman | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-217 | qBittorrent on its own bridge; ports published per address in its Quadlet | v2-195; ports moved by DD-219; start check by DD-223; partly retired by DD-272 (qBittorrent), guard rules kept for applications (DD-275) | design-decisions.md |
| DD-218 | qBittorrent's fresh-profile defaults are the user's choice | retired (v2-196, reverted by DD-219) | archive/design-decisions-retired.md |
| DD-219 | qBittorrent back to its own defaults; its ports moved to uncommon fixed ports | v2-197; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-220 | Removing qBittorrent with its data keeps Konsol's port and image choice | v2-198; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-221 | The Podman page changes qBittorrent's peer port | v2-199; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-222 | A package's unapplied change survives a failed install (durable pending marker) | v2-200; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-223 | Container units wait for the checked guard, without Requires= | v2-201; live-verified on nrm 2026-10-05; amended by DD-272, DD-274 | design-decisions.md |
| DD-224 | Containers may reach the internet, not private or tailnet destinations | v2-202; live-verified on nrm 2026-10-05 | design-decisions.md |
| DD-225 | Packages' private state is hidden from the uid-1000 data units | v2-203; live-verified on nrm 2026-10-05; amended by DD-267; amended by DD-272, DD-274 | design-decisions.md |
| DD-226 | A Konsol container's bind sources are pinned at every start | v2-204; live-verified on nrm 2026-10-05; amended by DD-274 | design-decisions.md |
| DD-227 | Writable server folders only through the Files account | v2-205; live-verified on nrm 2026-10-05; amended by DD-267 and DD-274 | design-decisions.md |
| DD-228 | Install from the public repository with one curl line on the server | v2-206; repository renamed by DD-255 (v2-238) | design-decisions.md |
| DD-229 | Overview controls, WireGuard as a whole, and a host closed to containers | v2-207; tile word amended by DD-230; overview controls removed by DD-267, WireGuard stop and container input guard kept; WireGuard's stop moved into master-wg by DD-272 | design-decisions.md |
| DD-230 | Home widgets on the tiles' grid, a "Sunucu" widget and uniform Store cards | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-231 | Home widgets in 1×1 and 2×2 cells; live rates split from application traffic | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-233 | Konsol "Güncelle" button: GitHub version check, pinned commit, unattended re-run in its own unit | v2-212; amended by DD-267; amended by DD-272; amended by DD-277 | design-decisions.md |
| DD-232 | Finder-style Files window (icons, right-hand places/detail column, no dock) and a two-card sidebar | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-287 | Genel Bakış is the applications alone; Kaynaklar and the server as cards at the sidebar's foot; the WAN rate and `/api/konsol/ag` removed, each application's totals under its rate in Uygulamalar | v2-275 | design-decisions.md |
| DD-286 | Genel Bakış: Kaynaklar and Ağ above the applications, no Erişim özeti; the server's facts in the sidebar's card | v2-274 | design-decisions.md |
| DD-285 | Uyarılar (`#/uyarilar`) lists every problem with its place behind the top bar's count; Genel Bakış carries no Dikkat card | v2-273 | design-decisions.md |
| DD-284 | "Doğrudan port" instead of "ham port" in every operator-facing text (the API keeps `ham`); Uygulamalar maps server → container per access row and drops the update column; Erişim → Genel merges an application's ports into one row; every page's head starts with "Geri" and "Genel Bakış" | v2-271; v2-272 | design-decisions.md |
| DD-283 | An access row's panel opens under its own row in Erişim → Adresler (one at a time, "Ayrıntı" opens and closes it; the page stays usable; the table waits during an apply; `?satir=` links open it in place) | v2-270 | design-decisions.md |
| DD-282 | An application's page says what each running service's processes run as (cgroup processes, `/proc` users, names from the container's own `/etc/passwd` without following its links; not `podman top`), and each `/srv` warning says whether that settles it (switched to the Files account) | v2-268 | design-decisions.md |
| DD-281 | Removing an application cleans up by default: the data (after the typed name; "Verileri sakla" keeps it), its unused images (the cleanup's checks; one in use stays and is named), with the data its earlier job records (amends K9) | v2-266 | design-decisions.md |
| DD-280 | An open Konsol notices a new build: its own files' ETag (HEAD, not cached) looked at again when the build number changes (until the files change, the installer writes them three stages later) or the tab comes back; a notice, then a reload after 2 s, or "Şimdi yenile" while something is entered | v2-265 | design-decisions.md |
| DD-279 | Uygulama ekle as a full-window page (`#/uygulama-ekle`, the shell keeps only the pending banner; file beside the questions; leaving with input asks inside Konsol too) with a Kurulum step showing the job's log (`gunluk` in the record; a failed install keeps its container's last lines, secret values masked; a direct start that stopped names its question); the inspector explains `PUID`/`PGID` | v2-264 | design-decisions.md |
| DD-278 | Rebuild phase 6: documents describe only generation 2, superseded entries archived, no switch for tests in the shipped tree, route-table and listener checks, fixes found while documenting (WireGuard open/closed state, pending-change refusals, timed changes from the internet, reboot during jobs, read-only managed names) | v2-261 | design-decisions.md |
| DD-277 | The last 1.x release points to the clean-install generation: Konsol reads `OBHUT_NESIL` from the newest commit's `install.sh` (absent = 1), another generation is `yeni_nesil` (a notice instead of "Güncelle", the start refused, the same text in `sudo obhut`), `master-guncelle` refuses such a target before `kur.sh`; the build skips v2-255 to v2-259 (the rebuild's) | v2-260, 1.2.0 | design-decisions.md |
| DD-276 | Rebuild phase 5: Konsol per the prototype: Uygulama ekle (four sources, inspector, plan, install), the application page with Tanım editing, Erişim with Yerel adlar, Genel Bakış' access summary, Sistem without Görünüm, Gelişmiş read-only with the cleanup; per-application live rates from each bridge's counters | v2-259; live-verified on the test host 2026-10-17; Uygulama ekle amended by DD-279 | design-decisions.md |
| DD-275 | Rebuild phase 4: one access row per application port (`erisim.json`: address with Tailscale name, Tailscale port and internet name, or raw port closed/Tailscale/internet), every access change a settings plan (openings wait 60 s, closings commit at once), raw ports through the guard, K5 tailnet entries, WireGuard's openings through the plan (master-wg caller mode), Yayınla, manual addresses and the `https` writer removed | v2-258; live-verified on the test host 2026-10-17 | design-decisions.md |
| DD-274 | Rebuild phase 3: the generator (Quadlet units for Compose services and Kubernetes Pods, names joined by `_`, Podman 4.9 keys, Pods and `service_healthy` need Podman 5), application records, lifecycle jobs with full rollback, secrets on standard input, pool ports, draft sources (address, image, container), single-container definitions and adoption removed; DD-226/227 amended (root start may write `/srv` with a warning) | v2-257; live-verified on the test host 2026-10-17; removal amended by DD-281 | design-decisions.md |
| DD-273 | Rebuild phase 2: Obhut's own YAML subset reader (line of every key and item; anchors, tags and multi-line plain text refused), one model for Compose and Kubernetes, the inspector (refusals, questions, answer checking, definition and separate secrets) and `POST /api/konsol/uygulamalar/denetle`; nothing written | v2-256; live-verified on the test host 2026-10-17 | design-decisions.md |
| DD-272 | Rebuild phase 1: a clean base. Generation gate (`OBHUT_NESIL` 2, marker after the confirmation, 1.x traces refused, same-generation updates only); Files and WebDAV installed directly; WireGuard in the base, off after install (`master-wg durdur/baslat`, typed `/api/konsol/wireguard` routes with path parameters); only the route table answers; store engine, packages and 1.x leftovers removed | v2-255; live-verified on the test host 2026-10-17 | design-decisions.md |
| DD-271 | The rebuild: one container model (Compose or Kubernetes YAML → inspector → Quadlet), Obhut knows no application, WireGuard built in, no compatibility layer; on the branch `yeni-yapi` (plan: `rebuild.md`) | accepted 2026-10-17 | design-decisions.md |
| DD-270 | Konsol's layout is measured on every screenshot of its browser suites (spill, cut-off, squeezed text, overlaps by glyphs, dialogs that do not fit; optional seven-width sweep); card cells wrap long addresses | v2-254 | design-decisions.md |
| DD-269 | After the redesign: code, reply fields and wording only the old interface used removed (the old Settings rule groups, CPU and WAN rate histories, `konteynerler/gunluk`, qBittorrent's `/hesap` and `/dizin`, WireGuard's masked preview, the traffic modules' `since`/`at`, dead installer switches) and the code kept for installs before v2-190 (the `.pay` reservation, replaced by an install gate; the native qBittorrent unit check; `/data`); broken live scripts moved to current routes | v2-253; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-268 | Redesign phase 5: Konsol as an installable app (`manifest.json`, Ô icons 192/512 any and maskable, `manifest-src 'self'`, no service worker) and `sudo obhut` (state, checks and repairs, update, account, applications, closing internet names, rolling back a pending change; Konsol's socket, systemd when the backend is down); sharing stays in Konsol, Gezgin shares its own content | v2-252; partly retired by DD-272, DD-275 | design-decisions.md |
| DD-267 | Redesign phase 4b: Dosyalar (Depolama with `GET /api/konsol/depolama`, Sunucu klasörleri, Çöp kutusu, Paylaşımlar with the share routes in the table, Sistem dosyaları on the tailnet; the CodeMirror editor in both trees); Konsol at `/` with `/yeni` redirected and old hash addresses sent to their new homes; the old interface, Konsol's ZIP/RAR jobs (unrar no longer installed), favourites, the Ana Menü layout, the old shell's routes and the packages' page scripts removed; a re-run deletes what earlier runs left | v2-250; partly retired by DD-272 | design-decisions.md |
| DD-266 | Redesign phase 4a: Sistem (health and repair, updates, account, server and reboot, theme, audit log), Gelişmiş (effective Caddy/dnsmasq, Podman images/volumes/networks), Uygulamalar' add flows (catalogue with install forms, an image, adoption) and an application's settings, drawn from package declarations; old routes moved into the table unchanged, `gelismis`, `uygulamalar/hesap` and `kur` added; container jobs wait up to 5 s for the locks | v2-249; amended by DD-269; partly retired by DD-272, DD-274, DD-276; leaving Uygulama ekle asks inside Konsol too (DD-279) | design-decisions.md |
| DD-265 | Redesign phase 3: `POST /api/konsol/ayarlar/plan` (apply's checks on a copy, before/after, restarts, confirmation window, whether this address and channel can confirm); settings and container writes in the route table; `/guvenlik-duvari`, `/adlar`, `/yayinlar` and the Yayınla plan (a Konsol container first gets a loopback port from `YAYIN_PORT_ILK`–`YAYIN_PORT_SON`, then the row; two ordered steps, not one transaction); WireGuard network rename; Erişim at `/yeni/` | v2-248; amended by DD-267; partly retired by DD-275 (Yayınla; the dry run and the reads kept); amended in v2-269 (Genel's table: addresses and ports only) | design-decisions.md |
| DD-264 | Gezgin's WebDAV shares: `GEZGIN_WEBDAV_PORT=62984` inside and published on the Tailscale address only; the port catalogue, the hook's check and the App Store text name it; not on the internet; `@TAILSCALE_IPV4@` filled from state.env when the engine places a unit, so a new address comes at the next placement | v2-251; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-263 | Container CPU and memory from the container's own cgroup v2 files (`State.CgroupPath` checked; memory less the inactive file cache; CPU between two readings) instead of `podman stats`, which the backend's `RestrictNamespaces` blocks; the sandbox is unchanged | v2-246; amended by DD-276 | design-decisions.md |
| DD-262 | Gezgin as an App Store container package: digest-pinned image with a `1.0` update channel, its own bridge, interface on loopback only, the Files account with no capabilities, the user area as one mount with Konsol's trash and archive work covered, data in `/var/lib/gezgin`, the first administrator from the install form (bcrypt by Caddy, handed over in `ilk.env` and emptied), a same-named foreign container refused, a publication check with no setting to read; the container guard rebuilt once an install registers a package | v2-245; retired by DD-272 (rebuild phase 1) | archive/design-decisions-retired.md |
| DD-261 | Redesign phase 2: `/api/konsol/uygulamalar` read model (packages, containers and built-ins with state, access, resources, update state, actions, a package's own stop and removal words), its detail, log and one action entry; request shapes checked from the table; a stale image-update cache refreshed in the background; Genel Bakış, Uygulamalar and the application page at `/yeni/`; the current Konsol links to `/yeni/` | v2-245; amended by DD-267; partly retired by DD-272, DD-274, DD-276 | design-decisions.md |
| DD-260 | Releases carry a semantic version (`OBHUT_SURUM`, tagged `vX.Y.Z`, 1.0.0 first) beside the build number `V2_VERSION`, which alone decides update offers; Konsol, the new interface and the installer show the release version | v2-244, 1.0.0 | design-decisions.md |
| DD-259 | Redesign phase 1: route table with reply shapes, generated OpenAPI and TypeScript types; `/api/konsol/erisim` read model (four reachability cells per service, warnings); `/api/konsol/olaylar` Server-Sent Events read with fetch (one producer, changed topics only, heartbeat, per-channel limit, session re-check); the Vue shell at `/yeni/` | v2-243; amended by DD-267; partly retired by DD-272, DD-275 | design-decisions.md |
| DD-258 | Konsol redesign by task (Genel Bakış, Uygulamalar, Erişim, Dosyalar, Sistem, Gelişmiş), Vue 3 + TS build, exposure read model and SSE, Gezgin as an App Store package; built beside the old UI at `/yeni/`, at `/` since DD-267 (plan: `archive/redesign.md`) | accepted 2026-10-13; phase 1 in v2-243 (DD-259); phase 2 in v2-245 (DD-261, DD-262); phase 3 in v2-248 (DD-265); phase 4 in v2-249/v2-250 (DD-266, DD-267); phase 5 in v2-252 (DD-268); complete, cleaned up in v2-253 (DD-269); partly retired by DD-272, DD-275 | design-decisions.md |
| DD-257 | Security and stability review: firewall stops on an unreadable package declaration, qBittorrent rollback restores only snapshotted files, the trash never crosses into a mounted disk, a request body deadline and dot-segment refusal in the root backend, no tree swap under a running install, cleanup | v2-241; partly retired by DD-272 | design-decisions.md |
| DD-256 | The Obhut mark "Ô" (ring + detached chevron, `console/obhut.svg`, PNG touch icon): Konsol's favicon and the README image; the wordmark's first letter; the sign-in page's and Konsol's sidebar brand | v2-239; sign-in wordmark v2-240; sidebar v2-242 | design-decisions.md |
| DD-255 | The project is named Obhut: repository `drs0me1/obhut`, installer banner and docs; internal paths, units and commands keep their names; hosts with the old name follow GitHub's redirect | v2-238 | design-decisions.md |
| DD-254 | A failed Caddy publication names the failing step (validate, firewall, reload) and the tool's own reason; folder share saves too | v2-237 | design-decisions.md |
| DD-253 | A Caddy repository outage (Cloudsmith 402) does not stop stage 1 on a host that has Caddy; Konsol's update message skips systemd-inhibit's "env failed" line | v2-236; amended by DD-267 | design-decisions.md |
| DD-252 | Manual Caddy addresses: a tailnet name and an optional public HTTPS name for a `127.0.0.1` port, the application's own login as the guard (amends DD-191) | v2-235; retired by DD-275 (rebuild phase 4) | archive/design-decisions-retired.md |
| DD-251 | Container logs exactly as written: unit journal for Konsol/App Store containers across restarts, no masking (amends DD-208) | v2-234; amended by DD-272, DD-274 | design-decisions.md |
| DD-250 | Favourite folders in Files: a star after the folder's name in the details, listed first in the places column, kept in `KONSOL_AUTH_DIR/favoriler.json` | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-249 | Files text editor (CodeMirror 6 bundle, CSP-safe styles); atomic, version-checked saves, as root in "Sistem (/)" (amends DD-235) | v2-231; amended by DD-267 | design-decisions.md |
| DD-248 | "Sistem (/)" walks folder sizes on local disk file systems, one device at a time (amends DD-235) | v2-230 | design-decisions.md |
| DD-247 | Folder tiles give the item count and the total size | v2-229; amended by DD-267 | design-decisions.md |
| DD-246 | Konsol reboot (typed confirmation, tailnet only, delayed transient unit); Sağlık in two rows; the settings guard timer is on-demand for `master-onar` (amends DD-241, DD-245) | v2-228; amended by DD-267; amended by DD-272 | design-decisions.md |
| DD-245 | Update control as an icon (words only while running); Ayarlar → Sistem in three cards, "Yerleşik altyapı" removed (amends DD-233, DD-239) | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-244 | Files details: one info line under the name, word actions, share actions in the row; a "Seç" picking mode (amends DD-243) | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-243 | Files as three separate panels; an 82 px one-line details panel with icon actions; no count in the path bar (amends DD-237) | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-242 | Home widgets in order: Sunucu and Hız side by side, Ağ a 2×1 row below, ◀ ▶ reorder them (amends DD-231) | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-241 | `master-onar` covers the installer's own settings (sysctl, Tailscale flags, timers, SSH, clock, modes, disk, dpkg) and reports the rest; Sağlık shows the last run and a 72 h / 1 week log | v2-223; amended by DD-267 | design-decisions.md |
| DD-240 | Address refresh after boot and nightly 03:00–04:00 (amends DD-239) | v2-222 | design-decisions.md |
| DD-239 | Repair on request (Konsol "Denetle ve onar", `master-onar`, `onar.command`) instead of the 5-minute refresh loop; hourly firewall check | v2-221; amended by DD-267 | design-decisions.md |
| DD-238 | "Sistem (/)": no read-only roots, no root warning strip (amends DD-235) | v2-220 | design-decisions.md |
| DD-237 | Files details in a fixed bottom panel, one-line share, short Favoriler, folder path in the address | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-236 | Files navigates like a file manager: frame built once, fixed window, history/cache, inert loading, keyboard | superseded by DD-267 | archive/design-decisions-retired.md |
| DD-235 | Files' "Sistem (/)" view: the whole server as root in a separate unit, tailnet only, permanent delete by name | v2-214; amended by DD-267 | design-decisions.md |
