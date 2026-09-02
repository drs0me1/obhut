# Session Notes

Cross-session continuity for this repository.

## Current Task

**v2-77 in [Unreleased] (2026-09-02):** the private seed is now a passwordless
schema-3 tarball. On a clean host carrying that seed, Stage 0 asks whether to
restore settings; only an explicit yes restores the four services, while the
default/no answer deletes the uploaded seed and performs a clean service
installation. The configured portable is mode `0700`; server-side seed and
staging material are removed after use/skip/failure. Because the portable now
directly contains production keys and credential databases, it must never
leave gitignored `v2/private/`. The private output is
`2026.08.06-v2-77-WITH-SETTINGS.command`. Linux harnesses passed default/no,
explicit yes, existing-host and marker paths; isolated restore copied the
expected 6+2+1+2 files without changing any production container ID. Both
portable exports are byte-reproducible and the special artifact embeds the
schema-3 tarball byte-for-byte.

**v2-76 (2026-09-02):** the private seed schema now permits
only qBittorrent's `qBittorrent.conf`, retaining Web UI credentials and user
preferences while excluding categories, RSS, watched folders, client data,
GeoDB, logs and torrent session/resume data. Reusable installers continue to
exclude Tailscale node identity. A fresh node can be assigned the old numeric
IP by an administrator in Tailscale IP management; copying `tailscaled.state`
is only a separate single-host recovery option while the old node is offline.
The private output is
`2026.08.06-v2-76-WITH-SETTINGS.command` and its schema-2 seed contains 11
service files.

**v2-75 (2026-09-02):** portable banner and first-install log
now state unmistakably whether the encrypted four-service seed is present.
This follows a real clean install where the generic v2-74 artifact was used:
the server correctly had no bundle/marker/restore log. The intended seed was
then applied safely in place to only the four target services; wg-easy's three
peers, Portainer/FileBrowser/qBittorrent state, all six service checks,
firewall and zero-failed-units passed. The next private artifact is named
`2026.08.06-v2-75-WITH-SETTINGS.command`.

**v2-74 (2026-09-02):** optional encrypted, first-install-only
settings seed for Portainer, FileBrowser, qBittorrent and wg-easy (**DD-103**).
The private seed/output live under gitignored `v2/private/`; generic portable
exports contain no settings. Restore uses GPG stdin passphrase input, validates
path/schema/file type and per-file SHA256, writes only empty targets before
Compose starts, records the encrypted-bundle hash and removes plaintext from
`/run` on success or failure. On clean Debian 13 `nrm`, an 18-file source
snapshot was restored byte/owner/mode-identically into isolated volumes;
Compose adoption and wrong-password cleanup passed without touching the live
containers. A configured v2-74 no-op re-run skipped the seed, preserved all
four target container IDs/start times and passed current-host six-container,
Caddy UI, wg-easy (healthy, three peers), qBittorrent peer-port, DNS and
firewall checks. Full clean-install acceptance of the configured portable
remains to be run after the next reimage.

**v2-73 (2026-08-30):** Ubuntu 26.04's nft-default host did
not load the legacy IPv4 `ip_tables`/`iptable_nat` modules required by
wg-easy's in-container `iptables-legacy`; `wg-quick up wg0` therefore failed
at its IPv4 NAT rule. Stage 4 now preloads and boot-persists those modules
alongside `wireguard`, `ip6_tables` and `ip6table_nat` (**DD-10**). The live
host recovered after loading both modules and restarting only wg-easy. A
v2-73 default re-run preserved all six container IDs/start times; a cold
reboot then loaded all five modules through `systemd-modules-load`, brought
wg-easy up healthy on UDP 61001 with no current-boot iptables errors, and
passed firewall, dual-path DNS, Caddy, authenticated/read-only WebDAV and
zero-failed-unit checks.

**v2-72 (2026-08-29):** Ubuntu 24.04/26.04 LTS support —
`require_supported_os` matrix, repo lines from `os-release`, ufw gate,
resolv.conf stub repoint, dpkg-lock wait (**DD-102**). **Live-verified on
both Ubuntu lines:** noble 24.04.4 on 2026-08-29 and resolute 26.04.1 on
2026-08-30. The resolute run covered a fresh install through stages 0–7,
independent contract checks, a byte/container/service-stable re-run,
Tailscale and Docker restart recovery, firewall re-application, and a full
reboot. Six containers, dual-resolver DNS, Caddy, authenticated/read-only
WebDAV and host DNS all passed. On reboot Tailscale may replace the stage-6
uplink symlink with its direct-mode MagicDNS `resolv.conf`; this is expected
and host DNS remains healthy. Last release: **v2-71** (2026-08-28, tag
`2026.08.06-v2-71`) — pull disk floor, single-pass downloads repair,
plus the v2-65…70 line (**DD-98…101**).

| | |
|---|---|
| Version | `2026.08.06-v2-77` (unreleased) |
| Branch | `quantum` |
| Last tag | `2026.08.06-v2-71` |
| Tests | 84 bats cases: 81 pass + 3 expected macOS `timeout` skips |

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- No reconcile / master-compose / iptables-persistent revival.
- `MASTER-INPUT` already accepts Tailscale UDP `${TAILSCALE_UDP_PORT}`
  (**DD-73**); do not treat that as a missing rule.
- No `COMPOSE_PROJECT_NAME` change on provisioned hosts: named volumes
  (`qbit_config`, `wg_easy_data`, …) live under the project-name prefix
  and would be orphaned. The host-wide prune trade-off stays as decided
  in **DD-99**.
- Never commit or publish `v2/private/`: it contains passwordless production
  identities and custom configured portable installers.

### Evaluated and rejected (2026-08-28 review)

- Gating `apt-get install` calls on dpkg state — would silently drop the
  "re-run refreshes docker/tailscale to the current repo version"
  behaviour.
- Timestamp/state gating of the downloads-tree repair — reconcile-engine
  shaped; the single-pass find is the accepted optimization instead.
