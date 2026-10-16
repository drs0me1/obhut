# Clean-install readiness

## What ships

Konsol is the task-based interface of DD-258 at `/` (since v2-250, **DD-267**; the
Model A interface this file once described, with Ana Menü, the Files window, App Store,
Konteynerler and Settings, is gone). Genel Bakış (`#/genel`) is the landing page: health
first, then the applications, resources, the network card and the server. The sidebar
(a bottom bar on phones) holds the six sections with the server's name, the command
palette, the problem count and the activity list.

| Section | Responsibility |
| --- | --- |
| Genel Bakış | Problems with their fix ("Denetle ve onar", "Düzelt"), application cards with "Aç", resources, the network card (every 5 s while shown), the server |
| Uygulamalar | Every application (packages, Konsol's containers, built-ins); add from the catalogue with its install form, from an image or by adoption; an application's page with Özet, Erişim, Depolama, Ayarlar and Günlük |
| Erişim | Who reaches what from where; Adresler (publications, local names, the local domain), Tailscale, WireGuard (networks, devices, QR and profiles), Güvenlik duvarı; Yayınla and the plan before every write |
| Dosyalar | Depolama, Sunucu klasörleri, Çöp kutusu, Paylaşımlar (folder WebDAV) and, on the tailnet, Sistem dosyaları |
| Sistem | Sağlık and repair, Güncellemeler, Hesap, Sunucu (reboot), Görünüm, Günlük |
| Gelişmiş | Effective Caddy and dnsmasq configuration, Podman images, volumes and networks |

`/` and unknown routes open Genel Bakış; `/yeni` redirects to `/`, and the old
interface's bookmarks open their new places. Resource values come from
`/api/konsol/kaynaklar` and the event stream; missing or stale values show as unknown,
never as zero. Disk is the filesystem containing the configured user root, not a sum
of directory sizes.

No production dependency or privilege boundary changed. Tailscale, Caddy,
Dnsmasq, firewall, Files and per-folder WebDAV remain protected (Konsol's ZIP/RAR jobs were
removed in DD-267; archives are Gezgin's, an App Store package). Optional
app removal preserves profiles unless the user separately confirms data deletion.
The settings plan, timed confirmation, server rollback, folder boundaries,
same-origin gates and CSP remain in force.

## Before installing

1. Prepare a supported fresh Debian 13 host. Ubuntu 24.04/26.04 remain supported
   targets, but this release has not yet had a fresh Ubuntu acceptance run.
2. A provider reset is separate from running the installer. This package does
   not wipe the host, restore backups or recover old credentials/peer identities.
   Save any data that must survive before a reset. On an existing host, rerunning
   the installer preserves managed data and is **not** a clean installation.
3. The installer is started on the server (**DD-228**):
   `curl -fsSL https://raw.githubusercontent.com/drs0me1/obhut/main/kur.sh | sudo bash`.
   The only input is the local domain, asked in stage 0 on a first install (no default).
4. Confirm SSH works. If a reset changed the SSH host key, independently verify
   its new fingerprint before replacing only that server's known-host entry.
   Injecting the same client public key does not preserve the server host key.
5. Run that line over SSH, inspect the summary and confirm.
   Complete the Tailscale login URL if requested; configure the restricted
   local domain and exit-node approval in Tailscale Admin. A fresh node can
   receive a different Tailscale address. Account/ACL changes are manual.

For agent-driven tests on `nrm`, type a scratch domain on a first install. Historical acceptance: v131 and v132 were deployed as in-place updates on the user's
v130 Debian installation. Portable validation, live read-only Store/firewall checks and
local regression suites passed; no reset/reboot or fresh Ubuntu run was performed.
Those results do not certify a fresh install of later releases. See `SESSION.md`
for exact scope and results.

## Fresh-host acceptance checklist (pending)

- Installer exits 0 after all seven stages, including rendered Caddy/dnsmasq/
  systemd validation and firewall/API gate checks.
- `panel.<domain>` opens Genel Bakış over the tailnet, with only the built-ins before
  installation; Uygulamalar offers the catalogue. The six sections are present. No old
  settings, peers or accounts appear.
- Resource values become live without installing WireGuard. Disconnecting
  marks values unknown; reconnecting recovers them.
- In Dosyalar, upload/create/move/trash/restore and per-folder RO/RW sharing with
  each connection switched on and off (Paylaşımlar) work. The file backend remains
  unprivileged.
- qBittorrent from the catalogue (install form) → its application page → Ayarlar →
  stop/start → removal succeeds; Uygulamalar follows the installed state. WireGuard
  install → first network in Erişim → WireGuard → test peer succeeds; removal closes
  network access.
- DNS-only changes and qBittorrent's settings form commit immediately. An account
  save must accept the new login after restart and report failures without claiming
  success. Firewall and mixed changes still confirm or roll back after 60 seconds.
  Domain changes require the existing separate five-minute new-host confirmation.
- Same-version rerun preserves accounts/profiles/history; reboot returns core
  services, DNS, panel and firewall. Test Ubuntu targets separately.

The interface's Playwright suites (`tests/yeni-*.cjs`) run Konsol at `/` against
local fixtures; they validate UI/API integration, not a real apt installation or
boot. See `tests/README.md` before running live suites.
