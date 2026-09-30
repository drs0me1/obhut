# Session Notes

Cross-session continuity for this repository.

## Current Task

**2026-09-30 — Auto-updates and maintenance cleanup, v2-158 (DD-184, DD-185):**
- User went through the five open topics from the analysis: WAN folder sharing
  unchanged; Konsol identity check unchanged (single Tailscale account, all
  devices the user's); "güncellemeleri açalım" → Tailscale and Caddy origins in
  unattended-upgrades, timer at 04:00 + 30 min random delay; SSH stays the main
  channel with Tailscale SSH as backup; maintenance recommendation applied
  (docs trimmed first, then old-version compatibility code removed).
- Docs: 75 retired DD entries, CHANGELOG before v2-145 and SESSION history moved
  verbatim to `docs/archive/`; `docs/decisions-index.md` added.
- Code removals and the deliberate keeps are listed in DD-185.
- Deployed via the portable launcher with scratch kurulum.env (exit 0); live
  checks and regression batch listed under CHANGELOG v2-158 "Verified on nrm".
  nrm scratch folder removed; no test shares left.
- Not committed yet.

## Previous Task

**2026-09-30 — Archive jobs page removed, v2-157 (DD-183):**
- User: remove Files → "Arşiv işleri"; states belong in the log. The log had only
  an opaque start id and no result, and the page held progress/cancel; user chose
  "Günlük + ince çubuk" (AskUserQuestion).
- Files backend audits arsiv-olustur/arsiv-ac (sources → result), arsiv-iptal and,
  via `Archives(report=report_archive)`, arsiv-sonuc when a job ends or is found
  interrupted (client "-"). Konsol: tab removed, bar above the Files list while a
  job is queued/running (name, state, message, İptal et), no navigation after
  start, `#/dosyalar/arsiv` opens Files, Günlük texts for the new actions.
- Deployed via the portable launcher with scratch inputs (exit 0). Live: archives
  -live wrote readable lines; Günlük API returned them. Visual check through a
  local mock (console files + recorded nrm API replies) in the built-in browser.
- Afterwards the user allowed installing Node and Playwright on the Mac:
  `brew install node` (26.10), `npm install -g playwright`, Chromium headless
  shell in ~/Library/Caches/ms-playwright; nothing added to the repository.
  panel-ui/files-ui/settings-ui/wireguard-ui all pass after updating panel-ui
  (bar instead of jobs page, /api/konsol/saglik fixture) and settings-ui (health
  card, stuck rollback retry/discard with typed word).
- Committed with v2-154..156 as c80e2af on branch quantum (2026-09-30).

## Previous tasks (historical; newer decisions take precedence)

Older entries (v2-153 and earlier), the stale v2-79 status table and the 2026-08-28 rejected-ideas list: [`docs/archive/SESSION-history.md`](docs/archive/SESSION-history.md).

**2026-09-30 — Resilience package, v2-156 (DD-182):**
- User: "v2-156 için başla" (after v2-154/155; commit still not requested).
- Stuck settings rollback: automatic attempts after 15/30/60/120 s, then phase
  `stuck` (guard stops, its timer idles); Konsol shows the error with "Yeniden
  dene" and "Bırak" (typed onayla, only when stuck, API `/api/konsol/ayarlar/birak`
  → `master_settings.py discard`). Installer message names both actions.
- WAN address change: `master_shares.assigned()` probe (no port, only
  EADDRNOTAVAIL = gone) in `wan_info()` with a Turkish reason; publish starts a
  stopped Caddy instead of restoring the old projection when reload fails;
  installer stage 6 removes a site whose bind is not the current WAN_IPV4.
- Watchdog: reset-failed before restarting Caddy; second firewall check after
  `tailscale wait`. Archive history: invalid jobs.json set aside as
  jobs.json.bozuk-<time>. Archive submit waits (≤10 s) for a finishing job's
  cleanup instead of 409 (race found by archives-live on nrm).
- Health card: `/api/konsol/saglik` (30 s cache), Settings → Sistem first card.
- Deployed twice via the portable launcher with scratch kurulum.env (SSH_HOST
  nrm, blank LOCAL_DOMAIN), default no full-upgrade, E; both exit 0. Live
  checks listed in CHANGELOG v2-156 "Verified on nrm"; nrm rebooted into kernel
  6.12.111 afterwards, all green. Test share/folders/state backups removed;
  refresh unit was runtime-masked for one test and unmasked.
- Known: settings-linux.py failed once when qBittorrent took >20 s to stop under
  load; passed twice on rerun. Caddy start-limit scenario not reproducible on
  Debian 13. Not done: health card has no notification. Committed with
  v2-154/155/157 as c80e2af on branch quantum (2026-09-30).

**2026-09-30 — Security core and speed/log-noise packages, v2-154 (DD-180) + v2-155 (DD-181):**
- Source: the 2026-09-29 read-only four-lens analysis (security, resilience,
  performance, modularity) of v2-153. User approved "v2-154 ile başla", then
  asked to move on to v2-155 and test everything together at the end.
- v2-154: root backend on a Unix socket only (0660 root:caddy, SO_PEERCRED);
  proxied requests must come from a non-local Tailscale address (the review
  showed the downloads uid reached the backend through Caddy's tailnet listener;
  reproduced 200, now 403); probe fails closed except EADDRNOTAVAIL. Caddy admin
  on /run/caddy/admin.sock (0700 dir). Pre-existing request smuggling fixed
  (connection closes after errors/unread bodies). WebDAV per-IP limit on the
  tailnet listener too, per-share 100/h budget with known-address exemption,
  decoy scrypt; disk reserve min(5 GiB,10%) for PUT/COPY and Files uploads;
  Files unit sandbox; wg-quick@ waits for `master-firewall --check`, refresh
  timer reopens failed networks. WG_PANEL_PORT removed; WG_PANEL_SOCKET,
  CADDY_ADMIN_SOCKET in state.env.
- v2-155: WebDAV login memory (10 min, 256), tailnet slots 64, Connection: close
  on closing replies, TCP_NODELAY in WebDAV and Files handlers (found live:
  44 ms → 1 ms per request through Caddy); settings guard timer on demand
  (apply starts, idle guard stops under the locks; stage 7 checks enabled);
  SyslogLevel/LogLevelMax=notice for both short timers; no request log lines in
  the root backend; Caddy zstd/gzip + no-cache for page files; single-flight
  settings view; qBittorrent Nice=10/CPUWeight=50; niced archive threads and
  ZIP_STORED for compressed media.
- Review workflow (4 lenses + adversarial verification): 4 confirmed (Caddy
  bypass, smuggling, fail-open probe, overclaimed sandbox comment), all fixed;
  1 refuted (ip_nonlocal_bind, unsupported config, documented).
- Deployed twice via the portable launcher with scratch kurulum.env (SSH_HOST
  nrm, blank LOCAL_DOMAIN), default no full-upgrade, E: v2-154 then v2-155 (twice,
  second after the Nagle fix). All exit 0, stage 7 passed. Operator input never
  opened. firewall-linux.py and settings-linux.py were already failing at v2-153
  (missing master_shares.py in their fixtures); fixed and passing.
- Evidence: see CHANGELOG v2-154/v2-155 "Verified on nrm". Final nrm: v2-155,
  no failed units, empty share registry, guard timer idle/enabled, firewall
  check ok, /tmp test trees removed. One mistaken command piped a tar stream
  into a root shell on nrm; every line failed ("command not found") and bash
  stopped at a syntax error; state checked clean afterwards.
- Committed with v2-156/157 as c80e2af on branch quantum (2026-09-30).
- Not done: no fresh-OS install/reboot; share-network recovery,
  Files folder-size cache, WG state reuse, iptables-save settings view, qBittorrent
  sandbox and RAR network namespace remain open. Next planned package: v2-156
  resilience (rollback retry cap, WAN IP change, Caddy reset-failed, Sağlık card).

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- No reconcile / master-compose / iptables-persistent revival.
- `MASTER-INPUT` already accepts Tailscale UDP `${TAILSCALE_UDP_PORT}`
  (**DD-73**); do not treat that as a missing rule.
