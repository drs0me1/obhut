# Behaviour Contract

**Status:** the authoritative statement of what Obhut (generation 2) does and what it deliberately
refuses: the installer, the base, the application engine, access, Konsol, and the health, repair and
update paths. It is implemented by `install.sh` and the helpers it installs. Where the code and this
document disagree, the code wins and this file is corrected.

Companion documents: [architecture.md](architecture.md) (where each part lives and how data moves),
[folder-shares.md](folder-shares.md) (folder WebDAV's protocol and limits),
[design-decisions.md](design-decisions.md) (why; one line per entry in
[decisions-index.md](decisions-index.md)), [konsol-api.json](konsol-api.json) (Konsol's routes, generated
from `panel/master_api.py`). History is in [../CHANGELOG.md](../CHANGELOG.md) and [archive/](archive/).

Bare paths are relative to `Data/`. A key in capitals (`SHARE_PORT`, `UYGULAMA_STATE_DIR`) is declared
once in `config/defaults.env` and written into `state.env`; a value given beside it here is an
illustration, the file is the source.

## Contents

1. [What Obhut is](#1-what-obhut-is)
2. [The installer](#2-the-installer)
3. [The base](#3-the-base)
4. [Applications](#4-applications)
5. [Access](#5-access)
6. [Konsol](#6-konsol)
7. [Health, repair, update and recovery](#7-health-repair-update-and-recovery)
8. [systemd lifecycle](#8-systemd-lifecycle)
9. [What Obhut refuses](#9-what-obhut-refuses)
10. [Manual Tailscale admin steps](#10-manual-tailscale-admin-steps)
11. [Success criteria](#11-success-criteria)

---

## 1. What Obhut is

- **One host, root only.** Obhut turns a fresh Debian 13 or Ubuntu 24.04/26.04 LTS server into a
  Tailscale exit node with local names, Caddy on the tailnet, a persistent firewall and a web console,
  Konsol (**DD-255**: the project's name; paths and units keep their `master-stack` names).
- **Built-ins:** Konsol, Tailscale, Caddy, dnsmasq, the firewall (project chains and the container
  guard), Files (server folders, trash, system files), folder WebDAV (Paylaşımlar) and WireGuard
  (installed and off). Podman is base infrastructure, the runtime of applications (**DD-208**); there is
  no Docker (**DD-152**).
- **Applications** are Podman containers the operator adds from the software's own Docker Compose or
  Kubernetes YAML file. Obhut reads the file, refuses what is unsafe, asks what only the operator can
  answer and writes its own Quadlet units (§4). Obhut knows no application: no name, default, mechanism
  or code path exists for any one of them (**DD-271**).
- **A port reaches outside only through an access row** in Erişim: an address (a Caddy row) or a raw
  port (§5). The host ports a file names are never used.
- **Generation 2 installs only on a clean operating system** (**DD-271**, **DD-272**). A host that carries
  an older Obhut stops at stage 0; 1.x servers cannot be updated in place. There is no migration, no
  compatibility option and no redirect for old addresses.
- **There is no reconcile engine** (§9). Nothing runs unasked except the bounded timers listed in §8.

The security floor, which every change must keep:

- Konsol's root backend listens only on a Unix socket behind Caddy's session check (`forward_auth`);
  nothing serves it on TCP (**DD-180**, **DD-194**).
- The interface carries a strict CSP: no inline code, no `eval`, nothing loaded from elsewhere.
- The tailnet comes first: Konsol's tailnet address always stays, and every change that can cut the
  operator off is planned, applied and confirmed from Tailscale within a deadline, else rolled back
  (§5.5).
- Irreversible actions need a typed word.
- Containers may open connections to the internet only, never to the tailnet, private ranges or the host
  itself (**DD-224**, **DD-229**).
- Secret values are never written in plain text, never logged and never sent to the browser after they
  are set.

---

## 2. The installer

### 2.1 Starting it (DD-228)

The operator runs, on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/drs0me1/obhut/main/kur.sh | sudo bash
```

`kur.sh` (repository root):

- needs root, `curl`, `tar` and `sha256sum`, and an interactive terminal (`ssh -t`) unless it runs as an
  update (§2.6);
- downloads the repository archive of `KUR_REF` (default `main`; a commit or tag) from GitHub, or
  `KUR_URL` (an archive of a tree not yet on GitHub, `https://` or a `file://` path on the server), and
  prints its SHA-256;
- unpacks it without owners and without `__pycache__`, and copies only the runtime tree (`install.sh`,
  `common.sh`, `config`, `templates`, `scripts`, `systemd`, `panel`, `files-panel`, `console`) to
  `/root/debian-server-installer` through an incoming folder and a swap; a failed swap puts the previous
  copy back. Documents and tests never reach the server;
- checks `install.sh` with `bash -n`, and refuses while `RUNTIME_DIR/install.lock` is held (an install, an
  application job or a settings worker is running);
- starts `install.sh` with the terminal as standard input.

`install.sh` runs itself again under `systemd-inhibit --what=shutdown:sleep --mode=block`, so a shutdown
cannot land in the middle of a stage; without `systemd-inhibit` it does not start.

### 2.2 Gates (stage 0, before any configuration is written)

In this order:

1. Root.
2. A supported system (**DD-102**): `ID`, `VERSION_CODENAME` and the major `VERSION_ID` of `os-release`
   together are Debian 13 (trixie), Ubuntu 24.04 (noble) or Ubuntu 26.04 (resolute); anything else stops.
3. **The generation gate** (**DD-272**): when `STATE_DIR` exists, `NESIL_FILE` must be a regular file
   holding exactly the installer's `OBHUT_NESIL` (`2`), and no path of `ESKI_NESIL_IZLERI` (the 1.x store
   engine and registries) may exist. Otherwise: "Bu sunucuda eski nesil bir Obhut var …; bu sürüm yalnız
   temiz bir işletim sistemine kurulur".
4. The architecture is recorded; anything but `amd64` warns (arm64 is not live-verified).
5. The recorded OS identity in `state.env` is compared with the live one (**DD-104**); a change re-applies
   the OS-dependent steps even when files are byte-identical. A missing record is not a change.
6. `iptables`/`ip6tables`, when present, must use the nft backend tailscaled uses (**DD-108**); stage 1
   makes the check mandatory once the package is installed.
7. An interactive terminal (not in update mode).
8. An active ufw stops the run: two owners of `INPUT` are refused.
9. `RUNTIME_DIR/install.lock` within `LOCK_WAIT_SECONDS`.
10. A pending Konsol settings change (`SETTINGS_PENDING_FILE`) stops the run until it is confirmed,
    rolled back or discarded.
11. `SERVER_ROOT` must be an absolute path under `/srv` (**DD-144**); system directories are refused.
12. In update mode a first install (no saved domain) and a host whose Tailscale is not logged in are
    refused.

The generation marker and `config.env` are written only after the operator's confirmation, so a cancelled
run leaves no configuration behind ("kurulum iptal edildi; hiçbir ayar değiştirilmedi"); only the log
folder and the runtime folder exist.

### 2.3 What it asks

- **Only the local domain, on a first install.** One DNS label, `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`, with
  no default; the question repeats until the answer is valid. The name becomes `panel.<domain>` and the
  other local names. A later run takes, in this order, the name confirmed in Konsol (`SETTINGS_FILE`
  `domain`, **DD-157**) or the previous run's (`config.env`) and asks nothing.
- Then one summary (no password in it) and one confirmation, `E/h` with `h` as the default.
- **No account, password, key or Tailscale auth key** comes from installer input (**DD-147**,
  **DD-205**): the node joins Tailscale through the login link stage 2 prints, the Konsol account is
  created by the operator in Sistem → Hesap, folder accounts in Dosyalar → Paylaşımlar.
- In update mode there is no question: the confirmation was given in Konsol.

### 2.4 Stages

| Stage | Work |
|---|---|
| 0 | The gates and the domain above; the confirmation; `NESIL_FILE`; `config.env` (`LOCAL_DOMAIN`, `TIMEZONE`) |
| 1 | Restart managers suspended for apt (`NEEDRESTART_SUSPEND=1`, **DD-103**); `apt-get update` that tolerates an unreachable Caddy repository on a host that has Caddy (**DD-253**); `full-upgrade` on every run; the base packages (`ca-certificates curl ethtool iproute2 procps kmod iptables nftables coreutils util-linux diffutils jq dnsutils unattended-upgrades python3`, **DD-153**); the nft check, now mandatory; `podman netavark aardvark-dns catatonit` and `wireguard-tools qrencode` without recommends; `podman info`; the timezone; unattended-upgrades (§3.1) |
| 2 | Tailscale's repository (suite from `os-release`, its `Release` probed first, **DD-106**), the UDP buffer floor and BBR before the package (**DD-18**, **DD-111**), the package, forwarding sysctls, the UDP GRO unit, the login with its 410 recovery, the exit-node and SSH preferences, online within `TS_ONLINE_DEADLINE_SECONDS` (§3.2) |
| 3 | WAN and Tailscale addresses detected and `state.env` written; the user area's folders created and its ownership repaired (§3.3) |
| 4 | The backend modules, workers and tools into `SBIN_DIR`; `KONTEYNER_STATE_DIR`, `UYGULAMA_STATE_DIR`, `UYGULAMA_VERI_DIR` (0700); the settings guard and share timers; WireGuard's tool, `wg-quick@` drop-in, kernel module and `WG_CONF_DIR`; the firewall, address refresh and hourly firewall check units; the settings guard timer enabled |
| 5 | `master-firewall` enabled and applied when its inputs changed or it is not active (with the container guard); the address refresh and hourly firewall timers enabled |
| 6 | dnsmasq and Caddy installed masked when missing; dnsmasq's files rendered, filtered by Konsol's DNS choices and validated (`dnsmasq --test`); systemd-resolved's stub handled (§3.4); the Caddyfile and WebDAV's site rendered, an internet site bound to a WAN address the host no longer has dropped (**DD-182**), Konsol's files placed (§6.1), `caddy validate` with the real Tailscale address; the drop-ins; each service restarted only when needed; Konsol's root backend, the Files backend, the system files view and folder WebDAV (registry prepared first) |
| 7 | The built-ins proven (Files on loopback, WebDAV's 401 as the Files account, `paylas.<domain>` and `TAILSCALE_IPV4:SHARE_PORT`); the access projection published (§5.2) and the share timer enabled; WireGuard's open networks started unless WireGuard is stopped; `master-firewall --check`; `podman info`; the settings guard enabled; forwarding read back (fatal), buffer floor, BBR and the update policy read back (warnings); DNS of every name in `SERVICE_NAMES` at `127.0.0.1` and the Tailscale address; out-of-domain `REFUSED`; WireGuard's networks; Konsol's gates (§11) |
| — | The summary and the manual Tailscale steps (§10) |

Addresses are detected once, in stage 3, into `state.env`; every later stage reads them there.

### 2.5 Re-runs (idempotency)

- A re-run is the same program: `full-upgrade`, one confirmation, the domain kept.
- Every managed file is written through a temporary file and an atomic rename with an explicit mode
  (`atomic_write`); a symlinked target is refused. Templates use `__NAME__` tokens; a token left unfilled
  is fatal. With unchanged inputs a re-run changes no byte of a generated file and restarts only a service
  whose files changed, that is not active or whose configuration is newer than its last start; an OS
  change restarts the edge services once.
- What survives a re-run: `config.env` choices, `SETTINGS_FILE`, the WebDAV registry (IDs, hashes, both
  connection policies), the Konsol account and sessions, WireGuard's networks, keys, device profiles and
  stopped marker, and the applications. The installer does not write applications' records, units or
  data and does not restart them; stage 7 publishes the access projection again from their records.
- Stage 7 starts every open WireGuard network (its `wg-quick@` unit enabled) unless WireGuard is stopped as
  a whole (`WG_STOPPED_FILE`); a network closed on its own stays closed across a re-run and Konsol's update.
- The installer owns only its own files (**DD-96**): it does not hunt for earlier units, users, packages
  or data, and never runs a global `apt purge` or `userdel`.

### 2.6 The update path (DD-233, DD-260)

- **Offer.** Konsol's backend reads the tip commit of `GUNCELLEME_DAL` on `GUNCELLEME_REPO` (the GitHub
  API) and that commit's `Data/install.sh`: `V2_VERSION`, `OBHUT_SURUM` and `OBHUT_NESIL` (a file without
  it is generation 1). A build is offered only when its generation equals `state.env`'s `OBHUT_NESIL` and
  its build number (`v2-<n>`) is higher; another generation is reported as needing a clean installation.
  The answer is cached six hours, a failed check is retried after 15 minutes, a manual check runs at most
  once a minute. `OBHUT_SURUM` is the version people see; only the build number decides.
- **Start.** Sistem → Güncellemeler or `sudo obhut guncelle`, only from a Tailscale device or the socket's
  local caller, only for the commit and version shown, never while an update runs or a settings change is
  pending. The backend starts `master-guncelle uygula <commit> <version>` as the transient unit
  `GUNCELLEME_UNIT`; it fetches that commit's `kur.sh`, which accepts only a 40-hex commit and refuses a
  downloaded `V2_VERSION` other than the confirmed one, and runs the installer with `V2_GUNCELLEME=1`.
- **Result.** `GUNCELLEME_DURUM_FILE` (key=value) and `GUNCELLEME_LOG_FILE` (0600); Konsol shows the stage
  and, on failure, the last meaningful line. There is no automatic update and no rollback: the previous
  code is in Git.

### 2.7 Fail-closed behaviour

A failure must never leave the host more exposed than before the run.

| Failure | Behaviour |
|---|---|
| Any stage aborts | Non-zero exit naming the stage, the line and the log path (`LOG_DIR`) |
| Caddy's repository unreachable on a host that has Caddy | Stage 1 goes on, Caddy is not upgraded this run, a warning names the cause; any other failing repository, or a host without Caddy, stops (**DD-253**) |
| A network step | Bounded retries with wall-clock budgets; the last attempt's code is reported (**DD-24**, **DD-55**) |
| Firewall apply fails partway | The staging chain is discarded and the active policy stays; a cold boot with an unreadable registry gets a narrow rescue guard (SSH, Tailscale transport, established, loopback, IPv6 control) and `--check` keeps failing, so Caddy and WireGuard stay down |
| `ip6tables` missing while IPv6 forwarding is on | Hard failure, never an IPv4-only policy (**DD-45**) |
| dnsmasq or Caddy installed but not yet configured | The unit stays masked, so no open resolver on `0.0.0.0:53` and no default site |
| Stage 6 aborts | dnsmasq and/or Caddy stay masked (off); a re-run is the recovery |
| A rendered dnsmasq or Caddy configuration does not validate | Stop with the tool's line and directive before any restart (**DD-106**) |
| Tailscale never comes online | Stop before anything is published |
| WebDAV registry preparation fails | Stop before the service starts; systemd refuses the unit without its credential |
| A file cannot be written with its owner and mode | Hard failure; the temporary file is removed |

Nothing is repaired silently and nothing is retried forever: every wait has a deadline and says which.

---

## 3. The base

### 3.1 System and packages

- Only what the base uses is installed (**DD-153**); the installer's own `.deb` downloads are not kept
  (`APT::Keep-Downloaded-Packages=false`, **DD-125**).
- `unattended-upgrades` follows the distribution's own origins (Debian stable and security, Ubuntu
  security) plus the Tailscale and Caddy repositories, runs daily at `APT_UPGRADE_TIME` (04:00) plus up to
  30 minutes, and never reboots by itself (**DD-113**, **DD-184**).
- sysctl drop-ins sort last (`99-zz-…`, **DD-105**): IPv4/IPv6 forwarding (read back in stage 7, fatal),
  a UDP socket buffer floor of `NET_BUF_FLOOR_BYTES` that never lowers a higher value (**DD-18**), and
  BBR with `fq` when `tcp_bbr` loads (**DD-111**; otherwise the default stays and a warning is logged).
- The timezone is `TIMEZONE`.

### 3.2 Tailscale

- The official repository and package. The node always joins through the login link; the operator
  approves it in a browser (**DD-147**).
- `tailscale up --advertise-exit-node --ssh` with three bounded attempts; a dead auth path (HTTP 410) is
  classified from the LocalAPI, never from the journal, and the daemon is restarted without its
  dependants between attempts (**DD-37**, **DD-42**). Then `tailscale set --advertise-exit-node
  --ssh=true --stateful-filtering=true --netfilter-mode=on --snat-subnet-routes=true` holds the
  preferences (**DD-43**, **DD-74**).
- UDP GRO forwarding is set once per boot on the default-route interfaces (`tailscale-udp-gro`,
  **DD-11**).
- The Tailscale IPv4 and IPv6 are written to `state.env`; IPv4 is mandatory.
- Who may use the exit node is the tailnet policy's decision: grant `autogroup:internet`, not broad
  private access. The installer edits no ACL or grant.

### 3.3 The user area

- `SERVER_ROOT` is `/srv` (**DD-144**). The installer creates, when absent, `downloads`, `media`,
  `media/movies`, `media/series` and the trash `.cop` (`FILES_PANEL_TRASH`), all opened through pinned
  descriptors (**DD-187**).
- On every run the tree's owner and mode are repaired selectively: only directories and single-link
  regular files whose owner differs from `DOWNLOADS_UID:DOWNLOADS_GID` or whose mode differs from
  0775/0664 change; nothing is followed through a symlink and links and special files are skipped
  (**DD-84**, **DD-187**).
- The Files account: systemd needs a user entry for `DOWNLOADS_UID`. An existing name for the uid and gid
  is used, otherwise the system account and group `DOWNLOADS_ACCOUNT` (no login, no home) is created.
  Ownership on disk stays numeric.
- `PRIVATE_STATE_ROOT` (`/var/lib`) holds the server's private state (Tailscale, Podman, applications'
  data) and is invisible to the Files account's services (**DD-225**).

### 3.4 Local names (dnsmasq)

- dnsmasq listens on `lo` and `tailscale0` only, with `bind-dynamic`; no DHCP, `no-resolv`, `no-hosts`,
  `local=/<domain>/`, `local-ttl=60` (**DD-60**).
- Names point at the current Tailscale IPv4 through `interface-name=<name>,tailscale0/4`; the address is
  never written into a dnsmasq file, so a changed address needs nothing regenerated.
  - `panel.<domain>`: the base's file `DNSMASQ_CONF_FILE` (`SERVICE_NAMES` is `panel`);
  - `paylas.<domain>`: WebDAV's `modul-paylasim.conf`;
  - each application's Tailscale names: `modul-uygulama.conf`, written by the access projection (§5.2);
  - the operator's records and forwarding: `SETTINGS_DNS_FILE` (a Tailscale target or a fixed IPv4/IPv6
    address; up to 100 records; up to four public upstream servers).
- A query outside the local domain is `REFUSED` unless forwarding is switched on; a local name the server
  does not answer (unknown, or a record switched off) never goes upstream.
- Erişim → Yerel adlar edits the operator's records (each can be switched off) and forwarding; DNS-only
  changes commit at once (**DD-163**). The managed names (Konsol's own, WebDAV's `paylas.<domain>` whose
  Tailscale access is Paylaşımlar' switch in Erişim → Adresler, each application's) are listed read-only
  with their owner and a link to their row, their only home (§5.4); no managed name is switched off. The
  settings' `dns` object holds only `records`, `forward` and `servers`; any other key is refused.
- Where systemd-resolved is active (Ubuntu), `DNSStubListener=no` is written and its effect read back, and
  `/etc/resolv.conf` is pointed from the stub to resolved's uplink file (**DD-102**, **DD-109**).

### 3.5 Caddy

- Caddy binds the Tailscale IPv4 by default (`{$TAILSCALE_IPV4}` from `state.env` through the drop-in's
  `EnvironmentFile=`) and serves plain HTTP on `CADDY_HTTP_PORT` (80) inside the tailnet, whose transport
  Tailscale encrypts. Its admin API is the Unix socket `CADDY_ADMIN_SOCKET` in a folder only Caddy can
  open; TCP 2019 is closed and `systemctl reload caddy` uses the socket (**DD-180**).
- The base Caddyfile holds the `(konsol)` routes (§6.1), the tailnet site `http://panel.<domain>` and
  `import CADDY_MODULES_DIR/*.caddy`. That folder holds WebDAV's tailnet site, each application's sites and
  the internet sites, all written by the installer (WebDAV's tailnet site) or by the access projection
  (§5.2).
- Every upstream is `127.0.0.1` or one of Konsol's Unix sockets; there is no other host, no tunnel and no
  automatic DNS write.
- Internet names share one listener, `WAN_IPV4:SHARE_HTTPS_PORT` (443): HTTP/1.1 and HTTP/2 only
  (`protocols h1 h2`, no HTTP/3 or UDP 443), `strict_sni_host on` (a Host/SNI mismatch is 421), a 10 s
  header deadline and a 30 s idle limit. Certificates come from Let's Encrypt through TLS-ALPN on 443 only
  (HTTP challenge disabled, `auto_https disable_redirects`): no WAN port 80 and no DNS API token. Caddy owns
  the keys and the renewal.
- Proxy messages are logged at ERROR and above only, so a client closing a stream is not a warning
  (**DD-193**).

### 3.6 The host firewall

`master-firewall` (`scripts/firewall.sh`) owns `CHAIN_INPUT` (`MASTER-INPUT`), `CHAIN_SETTINGS`
(`MASTER-SETTINGS`), `CHAIN_FORWARD` (`MASTER-FORWARD`) and `CHAIN_NAT` (`MASTER-NAT`) in both families
(**DD-59**), and the container guard (§3.7). Nothing is persisted to disk (**DD-17**):
`master-firewall.service` applies the policy at boot and whenever tailscaled restarts (`PartOf=`).

**`MASTER-SETTINGS`**, at position 1 of `INPUT` (before tailscaled's `ts-input`, whose blanket accept would
otherwise bypass a deny; **DD-156**, **DD-172**):

1. every WireGuard interface dropped (host ingress from a VPN client, before anything else);
2. loopback and established/related return;
3. while a WAN Caddy listener is published: per-source (16) and total (64) connection limits on its port
   (reset, before any operator rule);
4. the operator's rules (Erişim → Güvenlik duvarı): family, scope `wan` or `tail`, TCP/UDP port, optional
   source CIDR, allow or deny; at most 100. A rule on a port an application row holds is refused;
5. the tailnet allowlist (return): SSH, Caddy HTTP (IPv4), DNS TCP/UDP, `SHARE_PORT` (IPv4), Tailscale's
   own PeerAPI ports read from its status, each address row's Tailscale port (§5.3, IPv4) and each
   WireGuard network's UDP port, plus ICMP/ICMPv6;
6. every other new tailnet connection to the host dropped (**DD-172**, **DD-173**).

**`MASTER-INPUT`**, right behind `ts-input` (re-added when tailscaled lost its jump):

1. WireGuard interfaces dropped; loopback; established/related; everything arriving on `tailscale0` (the
   allowlist above already decided);
2. IPv4: DNS (TCP/UDP 53) from an application bridge (`KONTEYNER_BRIDGE_PREFIX+`) to that bridge's own
   address, for Aardvark (**DD-229**);
3. IPv6: the NDP, PMTU and echo ICMPv6 types;
4. new WAN connections only to Tailscale's UDP port, host SSH (`SSH_PUBLIC_PORT`), each open WireGuard
   network's UDP port (IPv4) and the one WAN Caddy port while it is published (IPv4, §5.1);
5. one WAN drop, then an unconditional drop.

**WireGuard forwarding** (only for open networks while WireGuard is not stopped, **DD-177**; a network is
open while its `wg-quick@` unit is enabled, the one state `master-wg net ac|kapat`, `net-add` and
`baslat|durdur` write):
`MASTER-FORWARD` drops every `VPN_BLOCK_DEST4`/`VPN_BLOCK_DEST6` destination from each `wgN` (private,
CGNAT, loopback, link-local, multicast, reserved, NAT64), accepts `wgN` → WAN, drops any other `wgN`
ingress, and lets only established replies from the WAN back in. `MASTER-NAT` masquerades each subnet out
of the WAN. With no active network both chains and their jumps are absent, not empty (**DD-175**).
wg-quick carries no `PostUp`: every rule is `master-firewall`'s.

Rules of the firewall:

- Each chain is built in a staging chain (`CHAIN_STAGING_PREFIX`) and swapped in, so the host never runs a
  partial policy; leftover staging chains are removed at the end of a good apply (**DD-1**, **DD-95**).
- The WAN interface is the live default route at apply time; a renamed NIC warns and still gets a policy
  (**DD-94**).
- Third-party rules in `INPUT`, `FORWARD` and `POSTROUTING` are never deleted; tailscaled's `ts-*` chains
  are never flushed; only one jump per project chain is inserted.
- The WireGuard registry is validated first (interface `wg0`–`wg9`, scope `inet`, ports, subnets, no
  symlink, no duplicate), closed networks included; a malformed line changes no rule. Only open networks
  get rules.
- `master-firewall --check` verifies shape and count, not presence: exactly one jump per parent, the WAN
  drop after every WAN allow with no unconditional accept before it, the exact number of WAN allows, the
  exact rule count of each chain, the operator rules in order, no staging leftover, the absence of
  WireGuard chains without networks, and the container guard (**DD-94**, **DD-95**). Caddy and every
  `wg-quick@` network start only after it passes (`ExecStartPre=+master-firewall --check`, **DD-180**).
- A measured window of about 850 ms at boot between a usable WAN address and the policy is accepted; only
  sshd, which the policy allows anyway, listened then (**DD-95**).

### 3.7 The container guard

One nftables table, `inet KONTEYNER_NFT_TABLE`, with a forward and an input chain at priority −10, so an
accept in Netavark's or Tailscale's chains cannot bypass its drops (**DD-211**, **DD-224**, **DD-229**).
Netavark keeps its own NAT; no foreign table is touched.

- **Input (the host closed to containers):** traffic from a bridge to any host address is dropped, except
  replies to connections the host opened and DNS (TCP/UDP 53) to the bridge's own gateway address.
- **Forward:** traffic that neither enters nor leaves a bridge passes (exit node, WireGuard); replies to
  container-originated connections pass; a container's new connection out of its bridge is dropped over
  IPv6, toward `tailscale0` and toward any `VPN_BLOCK_DEST4` range, so it reaches the internet only;
  traffic within one application's bridge passes (Netavark isolates bridges from each other).
- **Ingress:** an open raw port (§5.3) is let in only as the DNAT Podman made for it: into that
  application's bridge, from `tailscale0` or the WAN interface, IPv4, its protocol, exactly that original
  address and host port, to that container port (**DD-217**'s rule). A permit is written only while the
  address is the host's now (read from the interfaces); everything else into a bridge is dropped. A pool
  port on `127.0.0.1` needs no permit: the host reaches it through its output path.
- **Input to the guard:** the application records (`master_applications.guard_input`). A record it cannot
  read, a bridge name outside `KONTEYNER_BRIDGE_PREFIX` + 10 hex, or a publication other than a TCP pool
  port on `127.0.0.1` or a raw port on an IPv4 address fails the whole guard closed: the old rules stay.
- **Writers and readers:** `master-firewall` applies it; the container worker and the settings worker
  apply it under their locks when rows or applications change. Delete and rebuild are one nft
  transaction, followed by an exact comparison. Application units only check it (`--check`) in
  `ExecStartPre` and are retried until it is in place (**DD-223**).

### 3.8 Files

**The file backend** (`files-panel/master-files-panel`, `master-files-panel.service`, **DD-139**,
**DD-159**) serves Dosyalar' Sunucu klasörleri, Çöp kutusu and Depolama's folder list for `SERVER_ROOT`.

- It runs as the Files account, never as root, and listens only on `127.0.0.1:FILES_PANEL_PORT`; Caddy
  routes Konsol's `/api/*` (other than `/api/konsol/*` and `/api/sistem/*`) to it. Unit: no capabilities,
  `ProtectSystem=strict` with only `SERVER_ROOT` writable, `PRIVATE_STATE_ROOT` inaccessible,
  `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `NoNewPrivileges`, network to and from loopback only,
  `@system-service`, `ProtectProc=invisible`, `PrivateIPC`, `MemoryDenyWriteExecute`, 512 MiB, 64 tasks.
- It sees no session (Caddy asks the root backend first) but keeps its own gates: the Host
  `panel.<domain>`, `X-Konsol: 1` and a same-origin fetch on `/api/*` (a download, opened as a link, needs
  no header and is still refused cross-site), CSP and `no-store`.
- Paths never leave the root: each step is opened from a directory descriptor with `O_NOFOLLOW`, a symlink
  is listed but never followed, `..` and `/` in a name are refused. Names over 255 bytes, with `/` or
  (when new) with control characters or outer spaces are refused.
- Nothing overwrites: rename and move use `renameat2(RENAME_NOREPLACE)` and refuse an existing target; a
  folder cannot move into itself; the root's `.cop` is never a move or trash source.
- Upload: `POST /api/upload?path=&name=` with the file as the body, up to 64 GiB, streamed to a temporary
  name, synced and renamed into place (an existing name is 409); refused before the body (507) and stopped
  while streaming when free space would fall under min(5 GiB, 10 % of the file system) (**DD-145**,
  **DD-180**).
- Delete moves the item into `SERVER_ROOT/.cop/<id>/` with an origin record on the same disk. Restore puts
  it back (into the root when its folder is gone; a taken name gets a number). Permanent delete works only
  from the trash; it and emptying the trash need the typed word in the interface. The trash is reachable
  through no other path and hidden in the root listing.
- Text: the first 1 MiB of a regular file; NUL in the first 8 KiB is binary; the encoding is guessed
  (UTF-8, else Windows-1254; `.nfo` as CP437) or chosen. **The editor** (**DD-249**): a file the backend
  calls editable (read whole, decodable without loss, one hard link, no setuid/setgid, owned by the
  account in the `/srv` view) is saved only while its SHA-256 version is unchanged (409) and the encoded
  text fits 1 MiB (413), in the same encoding and line endings; a missing character is refused. The save
  is the one exception to "nothing overwrites": a temporary file with the old owner, mode and extended
  attributes, the old file checked again, then a rename.
- Folder rows carry their item count and walked size (a walk budget; no size when empty or unwalked,
  **DD-247**).

**The system files view** (`master-sistem-dosya.service`, **DD-235**, **DD-238**, **DD-248**): the same
program with `--sistem --root /` as root, for the whole server, under `/api/sistem/*`.

- It listens only on `SYSTEM_FILES_SOCKET` (0660 root and `CADDY_GROUP`, peer credentials checked), with
  `IPAddressDeny=any`. Caddy routes `/api/sistem/*` to it on the tailnet site only; the internet site sends
  that path to the file backend, which answers 404.
- It refuses (403) any request whose Caddy-written channel is not `tailscale` or whose client is not
  another Tailscale device, and a wrong Host.
- Same traversal and no-overwrite rules; no trash: delete is permanent and needs the item's name (or
  `onayla` for several); a mount point or an item with a mount below it is refused and a recursive delete
  stops at a device change. Sizes are walked only on local disk file systems and never across devices.
  Every write and download is an audit line.
- Trade-off: every tailnet device gets root file access, as Konsol has no tailnet sign-in (**DD-205**).

### 3.9 Folder WebDAV

Folders are shared over WebDAV by the built-in `master-paylasim.service` (`panel/master_webdav.py`,
**DD-158**, **DD-159**, **DD-192**), managed in Dosyalar → Paylaşımlar. The binding rules, limits and
tests are in [folder-shares.md](folder-shares.md); the contract in short:

- Each share is one folder under the user area with its own stable 24-hex ID, `/s/<id>/` path, user name
  and password (scrypt hash; 8–256 characters, **DD-168**), and two independent connection policies,
  Tailscale and internet, each `{enabled, permission ro|rw, expires}`. At most 32 non-overlapping shares;
  the root, hidden folders and the trash are never shared.
- `SHARE_STATE_FILE` is a 0600 root registry of schema 4; any other schema, or a key this version does not
  write, fails closed. The service reads it as a systemd credential (`LoadCredential`); no password enters
  argv, environment, logs or browser storage.
- The service runs as the Files account on loopback only: `127.0.0.1:SHARE_PORT` for Tailscale and
  `SHARE_WAN_BACKEND:SHARE_PORT` for the internet. The listener, not a header, chooses the policy; RW on
  one connection never grants write on the other. Caddy publishes `paylas.<domain>` and
  `TAILSCALE_IPV4:SHARE_PORT` (**DD-98**) on the tailnet and, optionally, an internet site (§5.4).
- Every share change restarts an active WebDAV service and interrupts all transfers; a failure restores the
  previous registry.

### 3.10 WireGuard (built in, off)

- **Installed with the base, off** (**DD-271** K6, **DD-272**): stage 1 installs `wireguard-tools` and
  `qrencode`, stage 4 installs `master-wg` into `SBIN_DIR`, the `wg-quick@` drop-in, the kernel module
  (and `WG_MODULES_LOAD_FILE`) and an empty `WG_CONF_DIR` (0700). No network is created; the first one
  is created in Erişim → WireGuard.
- **The server is the source of truth** (**DD-124**, **DD-143**): `WG_CONF_DIR/wgN.conf` (0600) holds a
  network's key and one `# peer: <name>` block per device; device profiles live in `WG_CLIENTS_DIR-wgN/`
  (0600 in 0700); `WG_NETWORKS_FILE` holds one tab-separated line per network (interface, UDP port, the
  fixed scope `inet`, server and subnet IPv4 and IPv6, default DNS, name). Nothing is read from or sent to
  the operator's workstation.
- **Networks** `wg0`…`wg9` (`WG_NETWORKS_MAX`): `wgN` is `WG_ADDR_BASE4.N.0/24` and
  `WG_ADDR_BASE6::N:0/112` (server `.1`/`::N:1`; a device's IPv6 ends in the hex of its IPv4 host number,
  **DD-135**), MTU `WG_MTU`. A new network's UDP port is 1024–65535 and may not be a base port, another
  network's, an application's open raw port or a UDP port in use; the interface suggests
  `WG_PORT_DEFAULT` for the first network and the first free port from `WG_PORT_NEXT` for later ones (the
  state's `defaults.port`). Adding one writes the files, enables the unit, applies the firewall, then starts
  the network; a failing step removes every trace.
- **Internet only** (**DD-177**): a device reaches the internet through WAN masquerading and nothing on
  this server or behind it (§3.6); there is no WireGuard listener of any service.
- **Peers** through `master-wg` only (same validation, the installer's lock, live apply): add (keys made on
  the server, the next free address, the profile stored), remove, DNS (only the profile's line,
  **DD-130**), keepalive, a peer switched off (its block commented out, so it stays off across reboots,
  **DD-140**), profile and QR (PNG only to a non-terminal, **DD-132**). Changes reach a running interface
  with `wg syncconf`; `wg-quick@wgN` restarts only when needed (**DD-123**). A device is "Bağlı" while its
  received bytes grew within 45 s and its handshake is under three minutes old; a sampler reads every
  network every 10 s (**DD-137**). The endpoint is `WAN_IPV4` (**DD-138**).
- **Through the settings plan** (**DD-275**): starting WireGuard as a whole, adding a network and opening
  one wait for the 60 s confirmation; stopping it (`master-wg durdur`: the open networks listed in
  `WG_STOPPED_FILE`, their units disabled, the firewall drops their ports, forwarding and NAT,
  **DD-229**), closing and removing a network commit at once; regenerating a network's key commits at once
  after the typed word, as does removal. A network's DNS and name and every peer action stay immediate.
  Only the networks file and the stopped marker enter the pending change, never a key or a profile.
  While a settings change is pending, `master-wg` refuses every verb that changes WireGuard's state or
  those files (`net-add`, `net-remove`, `net ac|kapat`, `net-settings`, `reset`, `durdur`, `baslat`)
  outside the worker's caller mode; the peer verbs stay open (they touch only a network's peer blocks and
  device profiles, which no plan restores). A network closed on its own keeps its registry line, keys and
  profiles but no UDP port, forwarding or NAT: opening or closing it applies the firewall again; stopping
  WireGuard as a whole removes every port.
- `wireguard.command` (repository root, macOS) drives the same tool over SSH for the operator; it refuses
  a server whose `master-wg version` differs from the repository's build.

### 3.11 Podman

- `podman`, `netavark`, `aardvark-dns` and `catatonit` without recommends; `podman info` must work in
  stages 1 and 7 (**DD-208**). No Podman daemon, socket or auto-update timer is enabled.
- Applications' Quadlet files live in `KONTEYNER_BIRIM_DIR`; systemd's generator turns them into
  services at each `daemon-reload`. Images and layers live in `/var/lib/containers/storage`.
- Ubuntu 24.04 ships Podman 4.9; the two features that need Podman 5 are refused there before any write
  (§4.7).

---

## 4. Applications

An application is installed from its own Compose or Kubernetes file and the operator's answers
(**DD-271** to **DD-276**). One model serves both formats, one inspector checks it, one generator writes
the units; Quadlet and systemd are the only runtime (no Compose runtime, no `podman kube play`).

### 4.1 Sources (K2)

"Uygulama ekle" takes:

- **a file**, pasted or uploaded, at most 256 KiB of UTF-8 text;
- **an `https` address**: every address the name resolves to must be public (not loopback, private,
  link-local, CGNAT, tailnet, multicast, reserved or a `VPN_BLOCK_DEST4/6` range), the connection goes to
  the checked address with the certificate verified, at most three redirects (each checked again),
  256 KiB, 10 s, uncompressed UTF-8 text; nothing is installed;
- **an image name**, as a job: the image is pulled and a Compose draft with its exposed ports and volumes
  is written;
- **a standalone container** (one no application or other manager owns): a Compose draft from
  `podman inspect`; secret-looking variables are left empty and refused settings are written as they are,
  so the inspector shows them.

A draft is only text for the inspector; the operator reads it, answers and installs.

### 4.2 Reading the file

- **YAML** (`panel/master_yaml.py`, K4, **DD-273**): Obhut's own subset reader, standard library only.
  Block mappings and sequences, plain and quoted scalars, flow collections, literal and folded blocks,
  comments, several documents; YAML 1.2 core scalars. Anchors, aliases, merge keys, tags, complex keys,
  directives, duplicate keys, tab indentation and multi-line plain or quoted scalars stop with their line
  and column. At most 256 KiB, 64 levels and 100,000 nodes.
- **Compose** (`master_compose.py`): `services` with `image` (required), `command`, `entrypoint`,
  `environment`, `ports` (`C`, `H:C`, `IP:H:C`, `/udp`; the host side is never used), `volumes` (named,
  relative, absolute, `:ro`), `user`, `restart`, `healthcheck`, `depends_on`, `working_dir`, `tmpfs`,
  `cap_add` (Podman's default set only), `cap_drop`, `labels`, `stop_signal`, `stop_grace_period`,
  `hostname`, `init`, `read_only`, `shm_size`, `ulimits`, `pids_limit`, `mem_limit`, `cpus`,
  `deploy.resources.limits` (one replica), `security_opt: no-new-privileges`; top level `services`,
  `volumes`, `networks` (ignored), `name`, `version`. Interpolation `${VAR}`, `${VAR:-x}`, `${VAR-x}`,
  `${VAR:?msg}`, `$$`. Noted and ignored: `container_name`, `expose`, `tty`, `stdin_open`, `logging`,
  `platform`, `pull_policy`, the rest of `deploy`, `x-` keys (A3). **Refused with their line:** `build`,
  `extends`, `env_file`, `secrets`, `configs`, `profiles`, `include`, `privileged`, `network_mode`, `pid`,
  `ipc`, `devices`, `sysctls`, `volumes_from`, `dns`, `dns_search`, `extra_hosts`, `group_add`, `links`,
  `external_links`, `domainname`, `mac_address`, any other `security_opt`, `cap_add` outside the default
  set, Podman's own labels (`io.containers.*`, `io.podman.*`), Obhut's labels (`io.master-stack.*`), and
  any key the reader does not know.
- **Kubernetes** (`master_kube.py`): one `Pod` or one `Deployment` with a single replica, and
  `PersistentVolumeClaim`s (each a folder). Containers: `name`, `image`, `command`, `args`, `env`
  (`value`, `valueFrom.secretKeyRef`), `ports` (`hostPort` ignored), `volumeMounts`, `securityContext`
  (`runAsUser`/`runAsGroup`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`, capability drops and
  default-set adds), `livenessProbe`/`readinessProbe` (`exec`, `httpGet`), `workingDir`,
  `resources.limits`; volumes `hostPath`, `persistentVolumeClaim`, `emptyDir` (tmpfs). `$(VAR)` in
  `command`, `args` and env values is expanded from the container's own earlier non-secret entries.
  What `podman kube generate` writes reads cleanly (its metadata are notes). **Refused:** `hostNetwork`,
  `hostPID`, `hostIPC`, `privileged`, other capability adds, `initContainers`, `ConfigMap` and `Secret`
  objects, other kinds and unknown keys.
- **Mounts** of system paths (`/`, `/etc`, `/proc`, `/sys`, `/dev`, `/boot`, `/root`, `/usr`, `/bin`,
  `/sbin`, `/lib*`, `/run`, `/var/run`, `/var/lib/containers`, `/var/lib/docker`, Obhut's own state) and of
  any container engine socket are refused.

### 4.3 The inspector

`inspect(text)` (`panel/master_inspector.py`) returns the format, a suggested name, refusals, notes, line
marks and the questions; `check(inspection, answers)` validates every answer and returns the checked
definition and, separately, the secret values. Neither raises: a reader bug refuses the file. The dry run
`POST /api/konsol/uygulamalar/denetle` writes, runs and fetches nothing and never returns a secret value.

- **Limits:** 16 services, 64 ports, 256 questions, 500 listed refusals or notes, values of 4,096
  characters.
- **Questions:** the application's name (`[a-z][a-z0-9-]{0,29}`; the name of its units, network and data
  folder); every TCP port (an address with its Tailscale name, or a raw port; nothing preselected, A1);
  every UDP port (raw only, closed, A2); every `${VAR}` (a value; a secret-looking name is a hidden value
  and offers "Rastgele üret" for passwords and secrets, not for tokens or keys); every secret-looking or
  empty literal and every Kubernetes secret key (one question per secret and key); every mount (the
  application's folder or a folder under `/srv`; the file's own host path is never used, A5); every
  container's start mode (A4).
- **Guesses** are shown beside the questions and never applied to ports: a web interface, a well-known
  service port (raw suggested), a secret-looking name, a `/srv`-like target. The start suggestion comes
  from the file alone: a file that sets `user:` without added capabilities is suggested "direct", any
  other "root".
- A secret-looking variable may be used only inside an environment value; a plain value may not hold a
  line break or NUL (an env file holds one line per variable). An environment value mixing text and a
  secret becomes one secret holding the composed value.

### 4.4 Start modes (A4)

- **Direct:** the service starts as the file's user or the Files account (`DOWNLOADS_UID:DOWNLOADS_GID`)
  with every capability dropped and `NoNewPrivileges`, which the install proves after the start.
- **Root, which may switch to its own user:** Podman's default capability set less `SETFCAP` and
  `SYS_CHROOT`, and less `NET_BIND_SERVICE` when no container port is below 1024, plus the file's own
  `cap_add` from the default set; the file's drops only narrow it.
- Privileged mode, devices and host namespaces never.
- The inspector suggests the direct start only when the file names the user and adds no capability. A
  service whose environment has `PUID` (with `PGID`) is told why the root start fits: the image starts as
  root and switches to that user itself, so a direct start cannot (**DD-279**).

### 4.5 Folders and binds (A5, DD-226, DD-227)

- An application's data lives in `UYGULAMA_VERI_DIR/<app>/<folder>/` (0700 root; under
  `PRIVATE_STATE_ROOT`, so invisible to Files and WebDAV). Named volumes and PersistentVolumeClaims become
  sub-folders. A direct service mounts its folders with Podman's `U`, so they become its user's; an
  existing sub-folder keeps the owner its container gave it.
- A folder under `/srv` may be bound: never `/srv` itself, never a hidden component or `..`, only
  `A-Za-z0-9 ._-`. At every start the unit's `ExecStartPre` walks each source from `/` without following a
  link and binds the directory behind that descriptor onto a root-owned anchor under
  `KONTEYNER_BAGLAMA_DIR`, which the Quadlet mounts instead of the path; a missing or symlinked folder keeps
  the container down; `ExecStopPost` releases the anchors (**DD-226**).
- A direct start as the Files account writes with `--umask=0002`. A root start, or a direct start as
  another user, with a writable `/srv` folder is allowed with a warning the inspector, the edit plan and
  the application page show (**DD-227** as amended by **DD-274**).

### 4.6 Secrets

Each secret value becomes a Podman secret (`obhut_<app>_<8 hex>`) created on standard input and handed to
the container as `Secret=<name>,type=env,target=<VAR>`. The record keeps only the mapping from the
inspector's logical names; the answers keep `{"set": true}`. An edit may keep a value the application has
(`{"keep": true}`); a renewed value is a new secret and the old one is removed only after the new units
are ready. No secret value reaches an argument, a file of Obhut's, a record, a log line or a reply.

### 4.7 The generator's units (DD-274)

`panel/master_generator.py` is pure: the checked definition and the engine's allocations become every
unit file, the environment files, the folders, the binds, the start and stop order and the publications.

- **Names** (application names have no `_`, so no two applications can meet): container
  `<app>_<service>`, unit `konsol-<app>_<service>.container`, network `konsol-<app>.network` (Podman name
  `ksl-<app>`, interface `KONTEYNER_BRIDGE_PREFIX` + 10 hex of its name's SHA-256), a Kubernetes Pod with
  several containers `konsol-<app>.pod` (infra `<app>__infra`). Every object carries
  `io.master-stack.managed=uygulama` and `io.master-stack.uygulama=<app>`.
- **Compose services** share the application's bridge and reach each other by name (a network alias per
  service); a multi-container Pod shares `localhost`.
- **Images** are pulled by the worker and pinned by digest; units carry `Pull=never`.
- **Publications:** an address row's port on `127.0.0.1:<pool port>`; an open raw row's on the Tailscale
  or WAN IPv4 address and its host port; nothing else. No host port of the file is used.
- **Units** keep the proven lines: `After=`/`Wants=` the firewall without `Requires=`, the guard check in
  `ExecStartPre` (**DD-223**), the bind anchors, journald logs, `UMask=0077`, the file's restart policy with
  `RestartSec=10s`, `[Install]` only while the application is not stopped. A `depends_on` service gets
  `Requires=`/`After=` on its dependency.
- Every Quadlet key used is in Podman 4.9's set; later options go through `PodmanArgs=` with validated
  values. Only a multi-container Pod (`.pod`) and a Compose `condition: service_healthy`
  (`Notify=healthy`, 300 s start) need Podman 5; on Podman 4.9 (Ubuntu 24.04) the install is refused
  before any write. Health checks become Quadlet health settings; values Quadlet cannot carry are refused.

### 4.8 Records

`UYGULAMA_STATE_DIR/<app>/` (0700 root, every file 0600, written atomically, read without following a
link, owner, mode and size checked):

| File | Holds |
|---|---|
| `kaynak.yaml` | the file exactly as given |
| `kaynak.json` | source kind, address, image or container, fetch time, SHA-256 |
| `yanitlar.json` | the answers without port answers and without secret values |
| `tanim.json` | the checked definition; each port only its number and protocol |
| `yerler.json` | what the engine allocated: revision, stopped, pool ports, Podman secret names, pinned images |
| `erisim.json` | the access rows (§5.3) |
| `env/<service>.env` | the plain environment |

The record is the single source: units, rows and names are generated again from it whenever the worker
writes them. This is not a reconcile engine; nothing runs unasked.

### 4.9 Lifecycle and jobs

Every write is a job: the backend hands it to the broker (`master_container_manager.py`), which runs it as
the transient unit `master-container-<id>` (at most 1800 s; the cleanup 900 s) with the request on
standard input only, and the worker (`master_container_worker.py`) does it. A job's record
(`KONTEYNER_STATE_DIR/operations/<id>.json`, 0600 root) names the job and its steps, never the request, and
keeps its log (`gunluk`: each step and fact with its time, why it failed said once; the newest 300 lines of at
most 400 characters, **DD-279**). At most four
jobs run at once and one per target; a job takes `install.lock` and `KONTEYNER_LOCK` (waiting up to 5 s)
and is refused while a settings change is pending. Each write is a line `uygulama-<verb>` in İşlem geçmişi.

- **Install:** first every check the install makes before writing (the file and answers again on the
  server, the name free everywhere, the Tailscale names free, the `/srv` folders, a takeover's source, the
  pool ports, a preliminary render, Podman 5); then the record, the guard, the folders, the pulls and
  digests, the secrets, Quadlet's dry run, the units, the start in order and the wait (300 s) until each
  unit is active and each container is its own, running and healthy; then the access projection. Any
  failure takes back everything the job made and names the step. A container that does not come up leaves
  its own last 20 lines since the job began (journald's `CONTAINER_NAME`) in the job's log before the rollback
  removes its unit, each secret value the job holds masked; a direct start that stopped at once says the
  usual reason (an image that switches to its own user from root) and the record names that start question
  (`soru`). `kur` with `plan: true` runs every check and writes, pulls and creates nothing.
- **Takeover:** installing from a standalone container copies its named volumes into the new folders and
  removes the old container (never its volumes) once the application is ready.
- **Start, stop, restart:** stop removes `[Install]`, so a stopped application stays stopped across
  reboots; restart only for a running application.
- **Update the image** (**DD-214**): on the operator's confirmation, the same tags are pulled; nothing
  changes when no digest moved.
- **Edit (Tanım, K3):** the file and the answers again, with a plan of the difference (units, environment,
  ports, folders, secrets, start modes, warnings); applying it restarts the application. A staying port's
  answer is filled from its row; a different one is refused ("Bu portun kullanımı Erişim'den değişir.").
- **Refresh from the source address:** fetched and inspected again; only new questions are new.
- **Remove (K9):** the units, containers, pod, network, secrets, record and rows go; the data stays unless
  the application's name is typed for `sil`; images stay for the cleanup; `/srv` is never touched.

### 4.10 Image updates (DD-214)

Konsol checks, never applies. Each service's pinned digest is compared with what its tag points to now,
reading registry manifests only (`podman manifest inspect`, this host's architecture): `guncel`, `yeni`,
`sabit` (the file pins a digest), `denetlenemedi` (with a reason) or `bilinmiyor`. The answer is cached six
hours; the list refreshes a stale cache in the background (at most once a minute) and the page can force a
check. Sistem → Güncellemeler counts the applications with an update; each is confirmed on its own page.
There is no timer and no automatic update.

### 4.11 Gelişmiş's cleanup (K8)

Gelişmiş is read-only except one job: removing images, networks and volumes nothing uses and the data
folders of removed applications (at most 200 items; Podman's default network is never offered). Each item
is checked again right before it goes. Containers Obhut does not manage are listed read-only.

---

## 5. Access

### 5.1 Exposure classes

Nothing listens on `0.0.0.0` except what the table says; a port number appears once, in
`config/defaults.env` or in a row.

| Class | What | Where |
|---|---|---|
| WAN (new connections) | Host SSH `SSH_PUBLIC_PORT` (TCP) | `MASTER-INPUT` |
| | Tailscale `TAILSCALE_UDP_PORT` | `MASTER-INPUT` |
| | Each open WireGuard network's UDP port (IPv4), while WireGuard is not stopped | `MASTER-INPUT` |
| | Caddy's one WAN port (IPv4): `SHARE_HTTPS_PORT` while any internet name is published, else `SHARE_PORT` while WebDAV's legacy HTTP is (§5.4) | `MASTER-INPUT`, with the connection limits in `MASTER-SETTINGS` |
| | An application's raw port opened to the internet (IPv4, its protocol) | the container guard's ingress permit |
| Tailnet (`tailscale0`) | Caddy HTTP 80 (IPv4): Konsol, `paylas.`, applications' Tailscale names | allowlist |
| | Caddy on `TAILSCALE_IPV4:SHARE_PORT` (WebDAV for clients without names, **DD-98**) | allowlist |
| | Caddy on `TAILSCALE_IPV4:<port>` for each address row's Tailscale port (K5) | allowlist |
| | dnsmasq 53 (TCP/UDP), SSH, PeerAPI, WireGuard UDP | allowlist |
| | An application's raw port opened to Tailscale | the container guard's ingress permit |
| Loopback | File backend `127.0.0.1:FILES_PANEL_PORT` | — |
| | WebDAV `127.0.0.1:SHARE_PORT` (Tailscale scope) and `SHARE_WAN_BACKEND:SHARE_PORT` (internet scope) | — |
| | Address rows' pool ports `127.0.0.1:UYGULAMA_PORT_ILK`–`UYGULAMA_PORT_SON` | — |
| Unix sockets | Konsol's root backend `PANEL_SOCKET`, the system files view `SYSTEM_FILES_SOCKET` (0660 root:`CADDY_GROUP`), Caddy's admin `CADDY_ADMIN_SOCKET` | — |

IPv6 on the WAN admits only SSH, Tailscale's UDP port and ICMPv6 control; Caddy and WebDAV bind IPv4 only.
WireGuard devices reach no host service at all. There is no NAT discovery, provider port forwarding or
automatic public DNS write.

### 5.2 The access projection

`master_shares.Manager.publish` (run by the settings worker, the share manager, the container worker, the
installer's stage 7 and the 30 s share timer) writes, from `SETTINGS_FILE` and the application records:

- `CADDY_MODULES_DIR/paylasim.caddy` (WebDAV's tailnet site, or a 403 stub on the same addresses while its
  Tailscale switch is off), `paylasim-wan.caddy`, `panel-wan.caddy`;
- `uygulama-<app>.caddy`: each address row's `http://<name>.<domain>` and, with a Tailscale port,
  `http://{$TAILSCALE_IPV4}:<port>`, both to the row's pool port; `uygulama-<app>-wan.caddy`: each internet
  name (bind `WAN_IPV4`, TLS-ALPN, the client's address as `X-Forwarded-For`), while the WAN IPv4 is
  assigned to the host;
- `DNSMASQ_CONF_DIR/modul-uygulama.conf`: one `interface-name` line per address row.

Stale `uygulama-*` files are removed. Then `caddy validate`, `master-firewall`, a dnsmasq restart when the
names changed and a graceful Caddy reload; any failure puts every previous file back and names its step
(**DD-254**). A record that cannot be read stops the projection: the last applied state stays. Nothing is
rewritten when the signature of the applied projection is unchanged.

### 5.3 Access rows (DD-275)

Every exposed container port of an application has exactly one row in its `erisim.json`, keyed
`<service>:<port>/<proto>`; its id everywhere is `uygulama:<app>:<service>:<port>/<proto>`.

- **Address** (TCP only): a Tailscale name `<name>.<domain>` (renamable), an optional Tailscale port (K5,
  off by default) and an optional internet name. The upstream is the row's `127.0.0.1` pool port, kept
  across edits.
- **Raw port:** `kapali` (closed), `tailscale` or `internet`, with a host port that defaults to the
  container port. A raw port is published on the Tailscale or WAN IPv4 address and carried by the container
  guard; it is never published on loopback and bypasses the operator's firewall rules (the plan says so).
  The firewall view shows it as a fixed row linked to its row.
- **Seeding:** an install seeds each row from the answers (an address with the answered name, no Tailscale
  port, no internet name; a raw port closed on its own number). An edit keeps a staying port's row, seeds a
  new port's and drops a gone port's. From then on Erişim is the only home of how a port is reached.
- **"Adres aç"** turns a raw port into an address, **"Adresi kaldır"** an address into a closed raw port;
  both rewrite and restart the service.
- **Conflicts are refused:** a Tailscale name, an internet name, a Tailscale port or an open raw port held
  twice; a host port that is a `*_PORT` key of `state.env`, inside the pool range, a WireGuard network's
  port, named by an operator firewall rule on the same scope and protocol, or listened on at that address
  or a wildcard. An internet raw port needs the consent `internet_onayi` (A2).
- `GET /api/konsol/erisim` is the read model: every row (Konsol, Paylaşımlar, each application port,
  containers no application owns with their published ports, system ports, WireGuard, the operator's
  rules) with four cells (this server, Tailscale, WireGuard, internet), certificates and warnings that name
  where each is fixed.

### 5.4 Names and the fixed rows

- **Tailscale names** follow one rule, `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`. Taken names: `panel` and
  `paylas`, every `interface-name` of the base's and WebDAV's DNS files, the operator's DNS records and
  every other row's name.
- **Internet names** are full domain names (at least two labels, a real top-level label; no scheme, port,
  path, IP address or wildcard; `localhost`, `local`, `internal`, `invalid`, `test`, `example` and `onion`
  are refused). Public DNS must resolve to exactly the assigned `WAN_IPV4` (an A record, no AAAA, no
  proxy), checked when a name is switched on or changed. One name serves one row. The certificate is
  waited for (60 s) with a probe pinned to the WAN IPv4 and the name as SNI: ready is not proof of
  reachability from the internet. Health warns at 14 days or less.
- **An application's internet name** is guarded only by the application's own login; Konsol puts no
  sign-in in front of it, and the plan says so.
- **Konsol's row** (`panel`, **DD-195**): its Tailscale name is fixed on. Its internet name, on or renamed,
  needs the typed word `onayla` (checked by the server), an existing Konsol account, and no folder shared
  over plaintext internet WebDAV. The public site imports the same routes with the channel `internet`,
  pins the backends' Host to `panel.<domain>` and sends HSTS for a year. Its requests are accepted only
  while the row is on, the WAN IPv4 is the host's and the account exists (re-read at most every 5 s), and
  never from one of the server's own addresses. A reset account closes it at once; the site goes at the
  next projection.
- **Paylaşımlar' row** (`paylasim`): a Tailscale switch (off: a 403 on the same addresses; the service keeps
  running) and an internet switch with its name. WebDAV's internet mode follows the row in
  `SETTINGS_FILE` `web` (**DD-179**, **DD-190**):

  | WebDAV row | Internet endpoint |
  |---|---|
  | never saved | consent-gated plaintext HTTP on `WAN_IPV4:SHARE_PORT`, only while an enabled, unexpired, valid internet connection exists and no internet name of Konsol or an application is enabled |
  | internet on with a name | HTTPS on `WAN_IPV4:SHARE_HTTPS_PORT`, kept for certificate renewal even with no active folder |
  | saved, internet off | closed; the name is remembered; never a fallback to HTTP |

  The internet site passes only `/s/*` to `SHARE_WAN_BACKEND`; every other path is 404. Folder policies
  and authentication still apply to every request.
- All internet names share TCP 443, its strict SNI and its per-source and total socket budgets.

### 5.5 The settings transaction (DD-156, DD-265, DD-275)

Every change to access goes through one transaction (`panel/master_settings.py`), run as an independent
worker unit with JSON on standard input under `install.lock`, `settings.lock` and `state.lock`.

- **Sections** (`AyarIstegi`, a closed shape): the operator's firewall rules and DNS (together or alone),
  the local domain, a fixed row (`web`), one application access row (`erisim`) and a WireGuard action
  (`wireguard`); each of the last four alone in a request. The request carries the settings revision (a
  hash over `SETTINGS_FILE`, `state.env`, the DNS and Caddy files, every `erisim.json` and WireGuard's
  networks file and stopped marker); a stale one is 409.
- **Plan:** `POST /api/konsol/ayarlar/plan` runs apply's own checks on a copy (no lock, file, timer or
  service touched) and returns what changes before and after, what restarts, warnings, the confirmation
  window and whether it is applicable (a consent or typed word missing; a timed change asked from the
  internet; firewall rules that would cut the confirming client off).
- **Apply:** a change that needs the timed confirmation, asked from the internet channel (the backend passes
  the channel Caddy wrote), is refused with the plan's reason before anything is written. Then the guard
  timer starts, the pending file (`SETTINGS_PENDING_FILE`, root-only) with snapshots of
  every file the change may touch is durable before the first write, then the sections apply: WireGuard
  through `master-wg`'s caller mode (it inherits the held `install.lock` descriptor and the pending
  change's id, accepted only while that change is applied or rolled back); a fixed row through the projection and, for a new name, the certificate wait; an access
  row through the container side in the same process (units rewritten, the service restarted and waited
  for), then the firewall, the projection and the certificate; the domain; DNS; the firewall. The applying
  deadline is 180 s (900 s for an access row, whose worker may run 1800 s); a failure rolls back at once.
- **Confirmation windows (decision 1 of DD-275):**

  | Change | Window |
  |---|---|
  | Opens or widens access: an address added (Adres aç), a Tailscale name renamed, a Tailscale port added or changed, an internet name added or changed, a raw port opened, moved or widened to the internet; a fixed row's Tailscale or internet name switched on or renamed; WireGuard started, a network added or opened; firewall rules (with or without DNS) | 60 s |
  | The local domain | 300 s, confirmed through the new name `panel.<new domain>` |
  | Only closes or narrows: a Tailscale port or internet name removed, a raw port closed or narrowed to Tailscale on the same port, Adresi kaldır; a fixed row switched off; WireGuard stopped, a network closed or removed, a key regenerated; DNS alone | commits at once |

  An unconfirmed close never reopens. Removing a network and regenerating a key also need the typed word.
- **Confirm** (`ayarlar/onayla`) only from a Tailscale address through the tailnet site, within the window,
  in the same boot, and only when the new rules do not block the confirming client's Konsol or DNS and
  Konsol's own name stays on. The local caller cannot confirm.
- **Rollback:** `ayarlar/geri-al` or the guard. `master-settings-guard.timer` runs every 2 s only while a
  change is pending (an idle run stops it under the locks; it runs once 15 s after boot, **DD-181**); a
  deadline passed, a reboot or a crash during apply rolls back from the snapshots in reverse, the container
  side included. A failing rollback is retried after 15, 30, 60 and 120 s; after the fifth failure it is
  `stuck` (**DD-182**) and Konsol offers "Yeniden dene" and "Bırak" (the typed word; files stay as they
  are, a re-run applies the saved settings). The commit marker keeps a durable commit from being undone
  after a crash.
- **While a change is pending** the installer, share changes and application jobs are refused.
- `SETTINGS_FILE` keeps the confirmed firewall rules, DNS choices, local domain and fixed rows across
  re-runs; access rows live in the records and WireGuard's state in its files.
- **The local domain** (**DD-157**) is renamed as structured tokens only in the base's, WebDAV's and the
  applications' DNS and Caddy files, the Files units' `--domain` and `state.env`; the Files backends and
  dnsmasq restart and Caddy reloads. The operator adds the new name to Tailscale's DNS settings first;
  no alias of the old name remains.

### 5.6 Address changes

| Consumer | On a Tailscale address change |
|---|---|
| dnsmasq | nothing: `interface-name` and `bind-dynamic` follow the interface |
| Caddy | restarted by `refresh-tailnet-config` after `state.env` is updated |
| WebDAV, the Files backends | nothing: loopback and sockets |
| The firewall | nothing: it matches `tailscale0`; the watchdog re-applies a changed PeerAPI port |
| Applications' raw Tailscale ports | `refresh-tailnet-config` starts `master_container_worker.py --adres-yenile` as its own unit, which rewrites and restarts only services whose units publish on an older address |

A WAN address change is not tracked live: WebDAV's internet side reports the address as gone ("kurulumu
yeniden çalıştırın"), the 30 s projection removes every internet site, and a Caddy that could not start
on the old address is started without it; the guard writes no permit for an address the host no longer
has. A re-run records the new `WAN_IPV4`, drops sites bound to the old one before Caddy restarts and
publishes them again in stage 7; the boot and nightly address refresh then moves raw internet ports.
WireGuard profiles carry the endpoint they were made with (**DD-138**).

---

## 6. Konsol

### 6.1 Where it is served (DD-140, DD-267, DD-268)

- `http://panel.<domain>` on the tailnet, always; optionally one internet name (§5.4). Caddy serves the
  page files from `CONSOLE_WEB_DIR` and routes `/api/konsol/*` to the root backend's socket, `/api/sistem/*`
  (tailnet site only) to the system files socket and any other `/api/*` to the file backend.
- The page files are the committed build of `tools/konsol-ui` (Vue 3 + TypeScript + Vite; nothing is
  built on the server) kept in `console/yeni/`, placed at the root of `CONSOLE_WEB_DIR` beside the sign-in
  page (`giris.html`, `giris.js`, `giris.css`), the editor bundle (`duzenleyici.js`) and the marks
  (`obhut.svg`, `obhut.png`). Only web file types and no hidden files are placed; every other file there
  is deleted; a `CONSOLE_WEB_DIR` outside `/usr/local/share/master-stack/` and a build file that would
  overwrite a sign-in file are refused. `console/yeni/kaynak.sha256` ties the build to its sources.
- Headers: CSP `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:;
  font-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none';
  frame-ancestors 'none'`, `Cache-Control: no-cache`, `nosniff`, `X-Frame-Options: DENY`, no referrer.
  Pages and API replies are compressed (zstd, gzip) except the event stream (**DD-181**).
- The app manifest (`manifest.json` with two icons) makes Konsol installable; there is no service worker.
- Views are hash routes (`#/genel`, `#/erisim?sekme=adresler`, `#/uygulamalar/<app>`); a tab and a
  view's state are in the query, so a reload or a bookmark opens the same view. `/` and any unknown address
  open Genel Bakış.

### 6.2 Sections (DD-276)

The sidebar (a bottom bar on phones) lists six sections; the top bar holds the problem chip (it leads to
the problem), the theme switch and İşlemler; a command palette (⌘K / Ctrl+K) finds sections, tabs,
applications, access rows, Uygulama ekle, Adres aç and the themes; a timed change shows as a banner with
its countdown and Onayla/Geri al.

| Section | Tabs and contents |
|---|---|
| Genel Bakış | Dikkat (problems, most serious first, each with its place), Uygulamalar, Erişim özeti, Kaynaklar, Ağ (WAN rate and the busiest applications' rates from their bridges), Sunucu |
| Uygulamalar | The list (state, reach, resources, live rate, update state); "Uygulama ekle" (a full-window page of its own, `#/uygulama-ekle`: Kaynak, Denetçi with the file beside the questions, Plan, Kurulum with the job's log; leaving with something entered asks, **DD-279**); an application's page with Özet (actions, update card), Erişim (its rows, read-only, linking to Adresler), Depolama (folders with sizes), Tanım (the file and answers, the difference as a plan) and Günlük (its units' journal, 100–1000 lines, unfiltered, **DD-251**) |
| Erişim | Genel, Adresler (Konsol, Paylaşımlar, every application row; "Adres aç"), Yerel adlar (the managed names read-only, records, forwarding, the local domain), Tailscale, WireGuard, Güvenlik duvarı (the operator's rules and the locked application rows) |
| Dosyalar | Depolama (the disk, who uses which folder, Uygulama verileri with a bounded cached walk), Sunucu klasörleri, Çöp kutusu, Paylaşımlar, Sistem dosyaları (tailnet only) |
| Sistem | Sağlık (with Onarım kaydı), Güncellemeler (Obhut and the count of application updates), Hesap, Sunucu (facts and "Yeniden başlat"), İşlem geçmişi |
| Gelişmiş | Caddy, DNS, Güvenlik duvarı (technical rules and listeners), Podman (read-only, and the cleanup) |

The interface names no application, loads no script of anyone else's, inserts names as text only and
never stores a secret in the browser.

### 6.3 Sign-in by channel (DD-194, DD-195, DD-205)

Caddy asks the root backend (`GET /oturum-denetle`) before every panel request except the sign-in page's
files, the marks, the manifest and its icons, and `/api/konsol/oturum[/*]`. Caddy writes the channel
(`X-Konsol-Kanal`) and the client address; a client's own values are overwritten.

- **Tailnet site:** the request must come from another Tailscale device (100.64.0.0/10 or
  fd7a:115c:a1e0::/48 and not one of the server's own addresses); then it passes without a session, and
  `/giris.html` redirects to `/`. Tailscale's ACLs decide which devices administer the server.
- **Internet site:** only while Konsol's internet row is active (§5.4); `/giris.html` is open, everything
  else needs a valid `konsol_oturum` cookie: a page redirects to the sign-in page, `/api/*` answers 401
  with `giris: true`.
- **The local caller** (the socket without Caddy's headers: root or Caddy's group, e.g. `sudo obhut`, the
  installer's checks) is trusted for the routes; through `/oturum-denetle` it needs a session.
- **The account** (`KONSOL_AUTH_DIR`, 0700 root): one user (3–32 characters, `[A-Za-z0-9][A-Za-z0-9._-]`)
  and a password of 10–256 characters as a scrypt hash; sessions as SHA-256 of their tokens, at most 16,
  seven days from sign-in. It is created only over Tailscale (`oturum/kur`, 403 on the internet). The
  cookie is `HttpOnly; SameSite=Strict; Path=/`, plus `Secure` over HTTPS. A password change over the
  internet needs the current password and keeps this session; on the tailnet the new one alone suffices and
  every session ends.
- **Budgets:** five failed sign-ins or current-password checks from one address within 60 s block it for
  300 s (429 with `Retry-After`); on the internet failures also share one budget (20 within 600 s close
  public sign-in for 900 s while Tailscale stays open); one password check per address and two at once.
- Updates, repairs, reboots, the system files view and timed confirmations are tailnet only.

### 6.4 Backend gates (DD-147, DD-180)

Both backends refuse a Host other than `panel.<domain>` (DNS rebinding) and require `X-Konsol: 1` and a
same-origin `Sec-Fetch-Site` on `/api/*` (CSRF). The root backend also refuses a path with empty, `.` or
`..` segments, accepts only GET, HEAD and POST, checks each connecting process's credentials on its socket
(root or Caddy's group), reads a body only up to its route's limit (64 KiB by default, 1 MiB for whole
files) within 30 s, and answers with `no-store`, its own CSP, `nosniff`, `DENY` and no referrer. Caddy
opens at most 16 connections per site to each socket.

### 6.5 The route table (DD-259)

The root backend answers only the routes of `panel/master_api.py`'s table, plus `/oturum-denetle` and the
sign-in `POST /api/konsol/oturum/giris`; a request body without its route's shape is 400, a path parameter
without its shape matches nothing. The OpenAPI description [konsol-api.json](konsol-api.json) and the
interface's TypeScript types (`tools/konsol-ui/src/api/sema.ts`) are generated from the table; a committed
copy that differs fails the tests. By area:

| Area | Routes (under `/api/konsol/`) |
|---|---|
| Overview and live state | `kaynaklar`, `saglik`, `ag`, `etkinlik`, `bekleyen`, `olaylar` (§6.6) |
| Applications | `uygulamalar` (list), `uygulamalar/{app}` (detail), `…/{app}/gunluk`, `POST uygulamalar/denetle` (dry run), `…/kaynak` (drafts), `…/kur` (install or its plan, 202), `…/{app}/islem` (start, stop, restart, update; 202), `…/{app}/tanim` (plan or apply), `…/{app}/yenile`, `…/{app}/kaldir` (202); `konteynerler/liste`, `konteynerler/islem` (a job's record) |
| Access | `erisim`, `guvenlik-duvari`, `adlar`, `POST ayarlar/plan`, `ayarlar/uygula`, `ayarlar/onayla`, `ayarlar/geri-al`, `ayarlar/birak` |
| WireGuard | `wireguard/state`; per network `nets/{iface}/ayarlar`, `nets/{iface}/peers`; per device `…/peers/{name}/remove`, `dns`, `keepalive`, `durum`, `profile` (download), `qr.png` |
| Files | `paylasim`, `POST paylasim/kaydet`, `paylasim/kaldir`, `depolama` |
| System | `oturum`, `oturum/kur`, `oturum/cikis`, `hesap/parola`, `guncelleme` (GET, POST), `onarim` (GET, POST), `onarim/gunluk` (text), `yeniden-baslat`, `islemler` |
| Gelişmiş | `gelismis`, `gelismis/temizlik` (GET, POST) |

Writes that take long return 202 with a job id; a stale revision is 409. A device's profile and QR code
carry its private key and are given only on an explicit request, with an audit line that never holds the
content; listings never carry keys.

### 6.6 Live events

`GET /api/konsol/olaylar` is a Server-Sent Events stream read with `fetch` (so `X-Konsol` stays): topics
`kaynaklar`, `saglik`, `islemler`, `bekleyen` and `kapat`; only changed topics are sent, a heartbeat every
15 s, a stream ends after about 10 minutes and the page reconnects; at most four streams per channel, then
503; an internet stream checks its publication and session every 30 s. One producer serves every stream.

### 6.7 İşlem geçmişi (the audit log)

Each backend writes one journal line per write: `panel: <actor> <client> <action> <detail> -> ok|hata` and
`dosya: …` (the system view's actor is `sistem`). Kinds include `ayar-<action>`, `paylasim-<action>`,
`uygulama-<verb>`, `temizlik`, `wireguard-<verb>`, `guncelleme`, `onarim`, `yeniden-baslat`, the account
actions and the file actions. Sistem → İşlem geçmişi lists the newest 40 of the last seven days from the
three backends' journals. No line holds a password, a secret value or a key.

---

## 7. Health, repair, update and recovery

### 7.1 Sağlık (DD-182, DD-189)

`GET /api/konsol/saglik` (cached 30 s) reports and never repairs: the required units (the core and the
timers, plus each registered WireGuard network unless WireGuard is stopped or the network was switched
off), Tailscale (running, online, key expiry within 14 days), `master-firewall --check`, a pending reboot
(the flag, else the boot links' kernel against the running one), clock sync, free space and inodes of the
system disk and the user area against the upload reserve, a pending or stuck settings change, WebDAV's
internet availability and its certificate. An unknown probe is a warning, never green.

### 7.2 Denetle ve onar (`master-onar`, DD-239, DD-241)

On request only: from Konsol (Sistem → Sağlık or Genel Bakış, tailnet only, as `ONARIM_UNIT`), over SSH
(`sudo master-onar`, `sudo obhut onar`, `onar.command` on the Mac) or `--denetle` to change nothing. One
run at a time, never beside an update, an application job or the cleanup. Its 21 fixed steps put back what the installer set up and never write new configuration:

- **Repairs:** the firewall (`--check`, re-apply), forwarding and buffer sysctls, Tailscale (start, the
  exit-node and SSH flags; a login is never forced), the Tailscale address (hands over to
  `refresh-tailnet-config`), the installer's timers, the base services and the WireGuard networks that are
  meant to run, SSH, the clock sync, DNS (`panel.<domain>`), Konsol and the Files backend on the side that
  does not answer, the modes of its private records, disk space below the upload reserve (apt's cache and
  the journal to 200 MB, never the trash or user files), `dpkg --configure -a` when apt is idle.
- **Reports only:** a changed WAN address, an invalid Caddyfile, Podman or the container guard missing,
  WireGuard peers that never connected, a read-only root, OOM kills, a pending reboot, a half-finished
  update or settings change, other failed units (applications included).

Every step reports `ok`, `onarildi`, `sorun`, `hata` or `atlandi`; the report is `ONARIM_DURUM_FILE`, the
lines go to the journal as `master-onar` and Sistem → Sağlık shows them with `refresh-tailnet-config`'s for
72 hours or a week.

### 7.3 Bounded watchdogs

- `refresh-tailnet-config` (after boot, nightly between 03:00 and 04:00, on Caddy's `OnFailure` and from
  `master-onar`; **DD-61**, **DD-87**, **DD-240**): re-applies a failed or broken firewall, reopens failed
  enabled WireGuard networks once the check passes (**DD-180**), waits for Tailscale, updates
  `TAILSCALE_IPV4/6` in `state.env` and restarts Caddy on a change, recovers a failed Caddy (resetting its
  start limit), and starts the applications' address refresh.
- `master-duvar-denetim.timer` (hourly): `master-onar --duvar`, the firewall step only.
- `master-share-network.timer` (every 30 s): finishes an interrupted share change and publishes the access
  projection when it differs (expired legacy HTTP WebDAV closed, a lost WAN address or a reset account
  taken out); it waits while the installer or a settings change holds the locks.
- `master-settings-guard.timer`: the rollback of an unconfirmed settings change (§5.5).

Nothing else restarts services, reverts files or checks drift.

### 7.4 `sudo obhut` (DD-268)

The server's state and recovery over SSH, as root, through Konsol's socket as the local caller:
`durum [--json]` (version, health, applications, the pending change; when the backend does not answer,
the core units from systemd and a pointer to `obhut onar`), `denetle` and `onar` (`master-onar`),
`guncelle [--evet]` (only a newer build of the same generation), `hesap durum|sifirla` (`master-konsol`),
`uygulama liste [--json]|baslat|durdur|yeniden-baslat <app>`, `erisim liste [--json]|kapat <row>|--hepsi`
(closes a row's internet side; it commits at once) and `geri-al` (rolls back a pending change).

### 7.5 `master-konsol`

`sudo master-konsol durum | sifirla | oturum-ac [--sure N] | oturum-kapat`: the account's state; deleting
the account and every session (the internet name closes; a new account is created in Konsol over
Tailscale); a short automation session of at most an hour, its token printed once; closing it.

### 7.6 Reboot (DD-246)

Sistem → Sunucu → "Yeniden başlat" (a typed word in the interface, tailnet only) is refused while an
update, a repair, an application job or the cleanup runs, or a settings change is being applied (one
waiting for its confirmation is rolled back after the boot); a transient timer runs `systemctl reboot` 5 s later and the page reloads once the
server answers.

---

## 8. systemd lifecycle

| Unit | Ordering and coupling | Restart |
|---|---|---|
| `tailscale-udp-gro.service` | after `network-online.target` | oneshot, `RemainAfterExit` |
| `master-firewall.service` | after `network-online.target tailscaled.service`; `PartOf=tailscaled.service`; `WantedBy=` multi-user and tailscaled; `ExecStartPost=--check` | `on-failure`, 10 s, 12 starts in 300 s |
| `caddy.service` (drop-in) | `Wants`/`After` tailscaled and `master-firewall`; `EnvironmentFile=state.env`; `ExecStartPre=+master-firewall --check` and `wait-tailnet-addr` (the state IPv4 on the interface, **DD-85**); `OnFailure=refresh-tailnet-config.service` | `on-failure`, 5 s, 3 starts in 600 s |
| `dnsmasq.service` (drop-in) | `Wants`/`After` tailscaled | `on-failure`, 5 s |
| `master-panel.service` | after `network-online.target`; Unix socket only; root with `ProtectSystem=full` (`/usr`, `/boot` and `/etc` read-only except `WG_CONF_DIR` and `KONSOL_AUTH_DIR`), `NoNewPrivileges`, `ProtectHome`, `PrivateTmp`, kernel protections, `AF_UNIX/INET/INET6/NETLINK` | `on-failure`, 3 s |
| `master-files-panel.service` | after `network-online.target`; `RequiresMountsFor=SERVER_ROOT`; the Files account; sandbox in §3.8 | `on-failure`, 3 s |
| `master-sistem-dosya.service` | after `network-online.target`; root; socket only; `IPAddressDeny=any` | `on-failure`, 3 s |
| `master-paylasim.service` | after `network-online.target`; `RequiresMountsFor=SERVER_ROOT`; the Files account; `LoadCredential`; loopback only | `on-failure`, 3 s, 5 starts in 600 s |
| `refresh-tailnet-config.timer` | `OnBootSec=2min`, nightly 03:00 with up to 55 min delay | — |
| `master-duvar-denetim.timer` | `OnBootSec=10min`, hourly | — |
| `master-share-network.timer` | 30 s after boot and after each run | — |
| `master-settings-guard.timer` | every 2 s while a change is pending; once 15 s after boot | — |
| `apt-daily-upgrade.timer` (drop-in) | `APT_UPGRADE_TIME` with up to 30 min delay | — |
| `wg-quick@wgN.service` (drop-in) | `Wants`/`After` `master-firewall`; `ExecStartPre=+master-firewall --check` | the package's; a failed enabled network is reopened by the address refresh |
| `konsol-<app>_<service>.service` (Quadlet) | `Wants`/`After` `network-online.target master-firewall.service`, no `Requires=` on the firewall; the guard check and the bind anchors in `ExecStartPre`; `Requires=`/`After=` its dependencies; `[Install]` unless stopped | the file's policy, 10 s |
| Transient: `master-container-<id>`, `master-container-adres-yenile`, the settings and share workers, `GUNCELLEME_UNIT`, `ONARIM_UNIT`, `master-yeniden-baslat` | started by the backend or a tool with `systemd-run`, collected when done | — |

Invariants:

- Restarting tailscaled re-applies the firewall and leaves every application and service running
  (**DD-223**). Caddy restarts only on an address change, its own failure or the operator's request.
- `state.env` is parsed by bash and by systemd: plain `KEY=value`, no spaces around `=`, lists in double
  quotes. There is no separately rendered environment file (**DD-61**).
- After a reboot every enabled unit and every application not stopped comes back; a stopped application,
  a network switched off and a stopped WireGuard stay so.

---

## 9. What Obhut refuses

- **No reconcile or self-healing engine.** No probe restarts services on its own, no canonical copies or
  restore manifests revert files, no restart-cooldown stamps (systemd's start limits do it), no disk or
  inode monitor in the installer, no installer-stage rollback machine for DNS or Caddy (a failed stage 6
  leaves them masked). Repair is `master-onar` on request; the watchdogs of §7.3 are the whole list.
- **No migration and no older generation.** No upgrade of a 1.x host, no compatibility options, no
  redirects for old addresses (§2.2).
- **No application-specific code.** No catalogue, package, form or default for any named software; every
  application comes from its own file.
- **No unsafe container.** No privileged mode, devices, host namespaces, host networking, engine sockets,
  system-path mounts, images built on the server, Compose runtime or `kube play`; no automatic image
  update; no container egress to the tailnet, private ranges or the host.
- **No port without a row.** A file's host ports are ignored; nothing is published but pool ports on
  loopback and the raw ports the operator opens.
- **No TCP for Konsol's root backend**, no Caddy admin on TCP, no default credential, no setup code, no
  debug switch and no route outside the table (§6.5).
- **No public DNS writes, tunnels, NAT discovery, upstreams other than `127.0.0.1` and Konsol's sockets,
  HTTP/3 or WAN port 80.**
- **No Tailscale account change.** ACLs, grants, DNS settings and exit-node approval are the operator's
  (§10).
- **No Docker** (**DD-152**) and nothing from the operator's workstation on the server (**DD-143**).
- **No other software's firewall chains** are deleted or flushed; no UDP-only decision is silently widened.

---

## 10. Manual Tailscale admin steps

The installer prints these and cannot perform them:

1. **DNS → Nameservers → Add nameserver → Custom:** the Tailscale IPv4 printed at the end of the run.
2. **Restrict to domain:** on, with `LOCAL_DOMAIN`; without it the tailnet sends all DNS to this host,
   which answers `REFUSED` outside the local domain unless forwarding is on.
3. **Machines → this host → approve the exit-node route.**
4. **Key expiry:** decide whether to disable it for an always-on server.

dnsmasq and Caddy follow the current `tailscale0` address, so after a re-registration only step 1 needs
the new address. Who may administer the server is decided here too: every tailnet device that reaches
`panel.<domain>` manages it without a password; restrict Konsol and SSH to administrators and give share
recipients only the WebDAV port.

---

## 11. Success criteria

A run is successful when all of these hold on the host. Stage 7 checks those marked ✓ itself.

**Base and Tailscale**

1. `tailscale status --json`: `BackendState=Running`, `Self.Online=true`; the preferences advertise the
   exit node, SSH, stateful filtering and netfilter mode on.
2. ✓ `net.ipv4.ip_forward` is 1; IPv6 forwarding is 1; the buffer floor and BBR read back (warnings).
3. `state.env` holds a valid `TAILSCALE_IPV4`; `NESIL_FILE` holds `2`.
4. ✓ `podman info` works.

**Names and edge**

5. ✓ Every name of `SERVICE_NAMES` answers `TAILSCALE_IPV4` at `127.0.0.1` and at
   `TAILSCALE_IPV4`; an out-of-domain query is `REFUSED` unless forwarding is on.
6. dnsmasq listens on `127.0.0.1:53` and the Tailscale address only and serves no DHCP.
7. Caddy listens on the Tailscale address (80, `SHARE_PORT`, each Tailscale port) and on the WAN address
   only for a published internet site or legacy WebDAV HTTP.
8. ✓ The root backend, the system files view and Caddy's admin are sockets with the expected owners and
   modes; the Files account cannot connect to any of them; `127.0.0.1:2019` is closed; `systemctl reload
   caddy` works.

**Konsol gates**

9. ✓ `/giris.js` opens on the tailnet name; `/` requested from the server itself through Caddy is 403;
   the session check gives a session-less local request 401 on `/api/*` and 302 on a page, and another
   Tailscale device 204 (and 302 from `/giris.html`).
10. ✓ Both backends refuse a missing `X-Konsol` and a foreign Host with 403; the system files view accepts
    only the `tailscale` channel from another Tailscale device; the file backend does not answer on a
    WireGuard network's server address (the root backend has no TCP port at all).

**Built-ins**

11. ✓ The Files backend answers on loopback and runs as `DOWNLOADS_UID`, never root.
12. ✓ WebDAV runs as `DOWNLOADS_UID`, answers an anonymous request with 401 on loopback, and
    `paylas.<domain>` and `TAILSCALE_IPV4:SHARE_PORT` answer 401 (403 when its Tailscale switch is off).
13. Each account opens only its folder; read-only connections refuse writes; a disabled or expired
    connection is refused on that listener only (see [folder-shares.md](folder-shares.md)).
14. ✓ `master-wg version` works and the kernel module and drop-in are in place; every enabled network
    listens on its registry port with its server address.

**Firewall**

15. ✓ `master-firewall --check` passes, the container guard included.
16. `INPUT` holds exactly one jump to `MASTER-SETTINGS` (first) and one to `MASTER-INPUT` (behind
    `ts-input`); `FORWARD`/`POSTROUTING` one jump each to `MASTER-FORWARD`/`MASTER-NAT` only while
    WireGuard networks are active; a third-party rule in `INPUT` or `FORWARD` survives a run; tailscaled's
    chains are untouched; the active SSH session survives the apply.

**Lifecycle and idempotency**

17. `systemctl restart tailscaled` re-applies the firewall and leaves every service and application
    running.
18. After a reboot: the core units, every application not stopped and every enabled WireGuard network run,
    every name resolves, Konsol and WebDAV answer; `systemctl --failed` is empty.
19. A second run with the same inputs changes no byte of a generated file, restarts nothing that did not
    change and preserves the WebDAV registry, the Konsol account, WireGuard's files and every application.
