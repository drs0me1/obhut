# Design Decisions

## Design decisions and rationale

This document records the *why* behind non-obvious choices in
`install.sh`, so future changes don't accidentally "fix" something that
was deliberate. Entries are derived from reading the script's own inline
comments plus structural inference from the 2026-07-27 audit
(`SECURITY_REVIEW.md`).

Entries that describe removed or replaced behaviour are kept verbatim in
[`archive/design-decisions-retired.md`](archive/design-decisions-retired.md),
and [`decisions-index.md`](decisions-index.md) lists every `DD-*` number
with its status and the file that holds it.

Konsol's old interface was removed in DD-267 (v2-250). Live entries written
before it still name its places (Ayarlar → Caddy, Ayarlar → Sistem, App Store,
the Podman page, Ana Menü, the Files window); DD-267 says where each went.

The rebuild (DD-271, phases DD-272 to DD-276) removed the App Store with its
store engine and packages (qBittorrent, Gezgin), package forms and publications,
Konsol's single-container definitions and adoption, Yayınla and the manual
`elle-*` addresses. Entries that only described them moved to the archive in its
phase 6; live entries that still mention them end with a note naming what no
longer applies and which entry replaced it.

### DD-284: "Doğrudan port", the applications list's server → container mapping, one row per application in Genel (v2-271)

- **Why:** the operator found "Ham" meaningless ("Ham 8092 · Tailscale" in Uygulamalar said nothing about what
  reaches what), asked for ports to be named by their protocol and the list to show server port → container port
  as a mapping, Erişim → Genel to stop repeating an application's name on every port's row, and a folder opened
  from an application's Depolama to have a way back (2026-10-19).
- **The word:** the row kind DD-275 calls a *raw port* in English is "doğrudan port" in Turkish: the port
  published as itself, directly, with no Caddy row. One word everywhere (the row's kind, Adresler' "Doğrudan
  portlar", the inspector's question, the plan's lines, the errors); the protocol is always beside it in the port
  itself ("8092/tcp", "9000/UDP"), so the label never repeats it. The row's number field is "Sunucu portu" (the
  port opened on the server). The API keeps `tur: "ham"`, `use: "raw"` and the ids: a word for people, not a
  schema change.
- **The list's mapping (`accessMap`):** for each access row of the application, the addresses and ports of its
  Tailscale and internet cells, straight from Erişim's read model and in the cells' colours (so the list and
  Erişim → Genel never disagree), beside the container port (`anahtar`'s port; its service when the application
  has more than one). The loopback pool port is left out: it is Caddy's, shown on the application's Erişim. The
  two halves are one grid per cell with the header's labels in the same columns, so they line up whatever an
  entry's height; on a phone each container port goes under its addresses. The update column went: a newer image
  is the page's (Özet) and the Dikkat filter's, and the column was "—" for most rows.
- **One row per application in Genel:** the rows stay per port in the read model (DD-275: the row is the model;
  Adresler, the palette, the counts and `obhut erisim liste` read them); the table merges them on the client: the
  ports under the name, each cell every port's addresses with the state that matters most (a fault, else open),
  a warning from any of them. The name leads to the row in Adresler when there is one port, and to the
  application's own Erişim tab when there are more, since Adresler' panel is one row's.
- **"Geri" and "Genel Bakış" in Dosyalar:** a page other sections link into asks the shell for them (`nav` in the
  page head); "Geri" is the browser's back (the router keeps the page before in the history entry, so the button
  is disabled on a direct open), "Genel Bakış" the section the sidebar's home icon names. Only Dosyalar asks: the
  other sections are reached through the sidebar and the breadcrumb.
- **Tests:** the wording in every suite; the mapping's entries, colours and container ports, no chips and no
  update column; the merged rows, their ports line, links and cells; the way back from a folder.

### DD-283: An access row's panel opens under its own row (v2-270)

- **Why:** in Erişim → Adresler "Ayrıntı" opened the row's form in a sheet from the right, away from the row and
  over the page; the operator asked for it to open as a card under its own row, open and close there, and only
  for the row chosen (2026-10-18), as long flows already left side sheets (DD-279).
- **What:** the row's panel (`AccessRowPanel`, the former sheet) is a table row under the row, in both tables
  (Adresler and Doğrudan portlar), as one tinted block with it. It is a compact card, not the sheet moved down: the
  row's facts on one line beside the close button (the row above names it, so the title is for screen readers,
  except "Adres aç"), the fields side by side like the row's own columns (Tailscale name | Tailscale port |
  internet name; scope | host port), flat, short hints, notices across the width, and "Adresi kaldır" or "Adres
  aç" at the start of the actions (the plan says what they do). The card gives the table's columns none of its
  width (`contain: inline-size`), so opening it never reflows the rows. "Ayrıntı" (and a raw row's "Adres aç") opens and
  closes it (`aria-expanded`, a chevron); choosing another row moves it there; a switch or a scope of the table
  opens it with its change made, as before. `?satir=` and `?kip=adres-ac` still name it, so every link into a row
  (Genel Bakış, the matrix, the firewall's locked rows, Yerel adlar, an application's page, the palette) opens
  it under its row. The other Erişim tabs keep their sheets.
- **The panel in the page (`InlinePanel`):** the sheet's parts without a layer: the page is not inert. When it
  opens, its row and the panel come into view (the row at the top when both do not fit; scroll margins keep them
  clear of a phone's bars) and the focus goes to its first field; when a step replaces the focused control (the
  form → the plan) the focus comes back into the panel; Esc and "Kapat" close it and the focus returns to the
  row's "Ayrıntı". `SettingsPlanSheet` renders either form (`inline`).
- **What a sheet gave for free, kept:** while an apply runs (a service restart can take minutes) the table's
  switches, scopes and buttons wait (`busy`), so the panel is not moved away from its running apply; while the
  panel holds a change, closing the browser tab asks first and a new Konsol build waits (DD-280), which the modal
  surface did before.
- **Tests:** the panel under its row, one at a time, opened and closed by "Ayrıntı", moved by another row, Esc
  and the focus back; every flow of the row (closings straight to the plan, openings with their field, the
  long apply, the refusal, Adres aç with another port) in the panel; on a phone under its card at 390 and 320.

### DD-282: An application's page says what its processes run as (v2-268)

- **Why:** a root start with a writable `/srv` folder carries the inspector's warning that the container "may write
  files the Files account cannot open unless it switches to its own user", and the service card said only "kendi
  kullanıcısına geçebilir". Whether it did switch was not known; the operator asked to see it (2026-10-18).
- **What is read:** for each running service, every process of the container's own cgroup (its init's
  `/proc/<pid>/cgroup`, the subtree's `cgroup.procs`, as DD-215's listening sockets) with its effective user
  (`/proc/<pid>/status`) and command name; one entry per user, the others before root, at most three command names
  each. The name for a uid comes from the container's own `/etc/passwd`, opened through `/proc/<pid>/root` without
  following a link inside the container (an image could point it at a host file). Rootful Podman without a user
  namespace: the container's uid is the host's. Unknown stays unknown (`null`).
- **Not `podman top`:** it joins the container's namespaces, which the backend's `RestrictNamespaces` forbids
  (the same reason DD-263 reads cgroup files instead of `podman stats`); `/proc` is readable (no `ProtectProc`).
- **The warning now:** each `/srv` warning (a root start, or a direct start as another user) carries a sentence
  about the present: still root (files under `/srv` belong to root), switched to the Files account
  (`DOWNLOADS_UID`: what it writes opens in Dosyalar; settled, the card turns into a note) or another uid (Dosyalar
  may not open its files); the root processes left (an init) are counted. The warning itself and the list's count
  stay as the definition gives them.
- **The service card:** "Root başladı · abc olarak çalışıyor", "Root olarak çalışıyor" or the direct start, and a
  "Süreçler" line per user with its commands; the definition's own wording (Tanım) says how it starts.
- **Tests:** the reader on a fixture `/proc` and cgroup tree (a link in the container's `/etc` is not followed), the
  warning's sentences, the detail reading only running containers by their own process; the page's pill, process
  lines and both warning states at 1440, 390 and 320.

### DD-281: Removing an application leaves nothing behind unless asked (v2-266)

- **Why:** the operator removed an application and found its data folder (kept by default, K9) and its image
  (left for Gelişmiş's cleanup) still on the server, besides job records holding its container's lines. A full scan
  of the test host found nothing else: record, Quadlet and systemd units, containers, pod, bridge, Podman secrets,
  bind anchors, Caddy sites, dnsmasq names, iptables and the container guard's nft rules all went. The operator
  decided that a removal cleans everything by default (2026-10-18).
- **Data:** Konsol's removal dialog now deletes the data by default; the typed application name stays the
  confirmation (an irreversible action, rebuild.md ground rule 7). "Verileri sakla" keeps the folder for a
  reinstall under the same name; Gelişmiş's cleanup still offers such a folder. The request is unchanged
  (`veri: sil|sakla`, `onay` for `sil`); only the default moved.
- **Images:** each image the record pinned goes after the record does, with the cleanup's own checks (no other
  record names it, no container in any state comes from it, never `--force`). One that stays is a line of the job's
  log, never its failure: the application is gone either way, and the cleanup offers the image later.
- **Job records:** with the data, the application's earlier records in `KONTEYNER_STATE_DIR/operations/` go (a
  failed install's record holds its container's own lines); the removal's own record stays, and İşlem geçmişi
  keeps its lines (who did what, when). Records of an application that was never installed go after 30 days
  (DD-280).
- **systemd's memory:** a unit whose file went stays listed while it is failed (a container killed because it would
  not stop in time, one that never came up), so a removal, an install's rollback and an edit that drops a service
  reset the failed state of their units (`systemctl reset-failed`, never a job failure). Found on the test host: a
  removed application's service showed as `not-found failed` in `systemctl --failed`.
- **Left on purpose:** `/srv` folders an application used (the operator's), İşlem geçmişi, and the journal, which
  rotates.
- **Tests:** the worker's removal (an unused image goes, one a container uses stays and is named, the data and the
  job records go with `sil` and only this application's, every unit's failed state reset), a rollback's and an
  edit's reset; the removal dialog's default, focus and texts; live on the test host.

### DD-280: An open Konsol notices a new build (v2-265)

- **Why:** after the installer ran again from the terminal, an open Konsol page kept running the code it had
  loaded; the operator saw neither the new Uygulama ekle page nor any hint, and the update check rightly offered
  nothing (the server already ran the newest build). Konsol reloaded itself only after an update started from its
  own Güncelle (2026-10-18).
- **What the page watches:** its own script's and style sheet's identity, their ETag asked with HEAD and never
  from a cache, noted when it starts. Not the build number alone: the installer writes `V2_VERSION` to
  `state.env` in stage 3 and Konsol's files only in stage 6, so a reload on the number would load the old files
  again and then never notice. When the build number in `kaynaklar` (every 2 s on the event stream) changes, the
  page looks at its files every 5 s until they change or 20 minutes pass; it looks once more whenever the tab
  comes back into view (a re-run that kept the number). An install that did not touch Konsol's files changes
  nothing on the page.
- **What it does:** a notice above every page, the full-window ones too. With nothing unsaved and no dialog open
  the page reloads itself after 2 s; with a draft (the leave guard's) or a dialog open it waits for "Şimdi
  yenile", since a reload drops what was entered.
- **Nothing changes on the server:** the files and their headers are Caddy's as before; no route, no new file.
- **Also in v2-265, from a review of DD-279:** secret values are masked in a failed install's raw container
  output before a line is cleaned (a multi-line value line by line too, a value with a tab whole); job records
  older than 30 days go when a job begins; the direct start's reason and `soru` come with any job whose direct
  start stopped, as the code already did, and the documents say so.
- **Tests:** `yeni-ui.cjs` (a new number alone changes nothing; new files show the notice and reload the page;
  with something entered it waits, above Uygulama ekle's head); the worker's masking and pruning.

### DD-279: Uygulama ekle is a full-window page; an install shows its own log (v2-264)

- **Why:** on the test host a Compose file whose image starts as root and switches to the user its `PUID`/`PGID`
  name was installed with the direct start as `1000:1000`. The image's init stopped at once ("/run belongs to
  uid 0 instead of 1000 …"), the install was rolled back as it should be, and the side sheet showed one line
  below the plan; the operator could not tell what happened. The operator asked for a full-window add flow and a
  log that shows the install as it runs (2026-10-18).
- **The page:** `#/uygulama-ekle` (route meta `full`; under `#/uygulamalar/` it would be an application named
  `ekle`). The shell drops its sidebar, page head and bottom bar there and keeps only the pending-change banner,
  since a change waiting for its confirmation must stay in sight. Four steps: Kaynak (the sources beside the
  chosen one; a file can be dropped), Denetçi (on a wide screen the file beside the questions, each pane
  scrolling on its own; on a phone one of the two; the questions grouped by service; the question in hand lights
  its line, a click on a marked line shows its question, "Bekleyene git"), Plan (what the install creates beside
  its order) and Kurulum (the job's log, its result and the way on). The sheet and its `?ekle=1` are gone.
- **Leaving:** with something entered, leaving asks inside Konsol too (DD-266 asked only when the tab closes), since
  a page this size holds more work; leaving a running install does not stop it (İşlemler follows it); a
  finished install stays on its log until the operator moves on.
- **The job's log:** the worker's record carries `gunluk` (`t`, `tur` of `adim`/`bilgi`/`cikti`/`hata`/`tamam`,
  `ileti`; the newest 300 lines of at most 400 characters). Every step is a line, facts are lines (an image
  pinned, a service running), and a failed job says why once. Konsol reads the record every second
  (`GET konteynerler/islem`); the event stream's İşlemler is unchanged.
- **A container's own lines:** an install whose container does not come up adds that container's last 20 lines
  since the job began (`journalctl CONTAINER_NAME=…`) before its rollback removes the unit, so the reason
  survives the rollback. Each secret value the job holds is masked first, so the operator's values never reach
  the record. Only the install does this: after any other failed job the application is still there and its
  Günlük shows the same journal. Lines an application prints about itself (its own generated password, say) are
  what Günlük shows too; the record is root's (0600) like the journal.
- **The usual reason, said:** a direct start that stops at once adds that such an image may start as root and
  switch to its own user, and the record names that start question (`soru: start:<service>`); the page offers
  "Başlatma sorusuna dön" with every answer kept. The inspector says the same before the install when a service
  without `user:` and without added capabilities has `PUID` in its environment (with `PGID`); its suggestion
  stays the root start. This reads the file's own words; no image or application is named.
- **Tests:** the worker's log, its order, the masking, the cap, no journal read for other jobs; the inspector's
  `PUID`; the three affected Konsol suites with the layout audit at 1440, 390 and 320.
- **Amended in v2-265 (DD-280):** the masking works on the raw output (a multi-line secret line by line too);
  records older than 30 days go when a job begins; any job whose direct start stopped names its question.

### DD-278: The rebuild's phase 6: documents, sweep and back doors (v2-261)

- **Scope (`rebuild.md` phase 6):** the documents describe only generation 2, superseded decisions are
  archived, the switches that existed only for tests are gone, the leftover sweep and the back-door review are
  done, and what documenting the code found is fixed. The clean-server test and the release follow.
- **Version numbers:** the last 1.x release on `main` is 1.2.0 with build v2-260 (its entry is DD-277 on that
  line); this branch skips v2-260 and the merge becomes 2.0.0 (the operator's decision, 2026-10-17).
- **Documents:** `contract.md`, `architecture.md`, `folder-shares.md`, `CLAUDE.md` (the operator's rules kept;
  two facts corrected), `README.md`, `OKUBENI.txt`, `tests/README.md` and the Cursor rules rewritten against the
  code; `redesign.md`, `model-a-clean-install.md` and `design/` moved to `docs/archive/`. Twenty-five entries
  that describe removed things moved to `archive/design-decisions-retired.md`; forty-four that stay carry a note
  naming what no longer applies.
- **No switch for tests in the shipped tree:** `master-panel --state-env`, `--allow-host` in both backends,
  `PANEL_ACTIVE_WINDOW`/`PANEL_SAMPLE_SECONDS` (now constants), the hidden `--state` of `obhut`,
  `master-guncelle`'s `KUR_BETIK_URL` (the updater fetches only the fixed GitHub address over https),
  `TAILNET_ADDR_WAIT_SECONDS`, the `FIREWALL_BIN` and `V2_OS_RELEASE_PATH` overrides and `kur.sh`'s `KUR_ROOT`
  are gone; tests patch module constants or start the backend through `tests/panel-harness.py`. `master-onar
  --kaynak` is used by Konsol and is now shown in its help; `kur.sh`'s `KUR_URL` stays to install a tree that is
  not on GitHub yet (section 7). A bats guard fails if a removed switch or a hidden option comes back.
- **Back doors:** route-table tests for the root backend, the files backend and its system-files mode (any
  other path 404, other methods 501); every listener's port or socket is a `defaults.env` key (bats); private
  modes of state, settings, WireGuard, the Konsol account and the application records (bats).
- **Found while documenting, fixed:**
  - A re-run (and Konsol's update) reopened a WireGuard network the operator had closed; a closed network kept
    its WAN port. The wg-quick unit's enablement is now the one source of "open": the installer starts only
    enabled networks, the firewall admits only them, `net ac|kapat` apply the firewall.
  - `master-wg` refuses every verb that changes networks or the stopped marker while a settings change is
    pending, except the settings worker's own documented caller mode (phase `applying` or `rollback`).
  - A timed change sent from the internet channel was applied and then rolled back after 60 s; apply now
    refuses it before writing anything.
  - Reboot and repair refuse while an application job or the cleanup runs; reboot also while a change is
    being applied.
  - `paylas.<domain>` could be switched in two places; with it, every managed local name is read-only in Yerel
    adlar (its row is its home), so the name switch (`dns.disabled`, `filter-dns`, the off marker) is removed;
    the operator's own records, forwarding and the local domain stay.
  - An application's new internet name warns in the plan that only the application's own login guards it.
  - A Compose file that writes a secret-looking value in clear gets a note on that line: the value is not used,
    but the file is kept as given and shows it.
  - Unit templates take `SBIN_DIR` like the rest; WireGuard's next suggested port is `WG_PORT_NEXT` in
    `defaults.env`; the installer's and `master-wg`'s operator strings match Konsol (Yerel adlar, Aç/Kapat,
    six sections).
- **Tests:** Python 881 with only the eight known macOS failures; `bats` 187/187; the eight Konsol suites and the
  sign-in suite with the layout audit.
- **The clean-server test (v2-262, 2026-10-18):** the operator reset the test host to Debian 13; the branch was
  installed from GitHub with `kur.sh` and `KUR_REF=yeni-yapi` (domain asked once, Tailscale joined through the
  login link, generation 2, no failed unit). Gezgin was added through the real Konsol by uploading the
  project's own `compose.yaml` (the operator's local copy of the published file; the repository is private,
  so the address source could not fetch it): its web port as an address, its WebDAV port raw and closed, two
  application folders, `/srv/media` writable, started directly as 1000:1000 with no capabilities; its page
  answered. Then through the interface: the WebDAV port opened to Tailscale and the web address given a
  Tailscale port (each 60 s, confirmed from the banner; both answered, the WAN stayed closed); WireGuard turned
  on by adding a network (confirmed) and a test device added with its QR; Tanım's difference planned; a local
  DNS record added and removed (at once). After a reboot every one of them answered again with no failed unit;
  28 screen states read clean at 390 and 1440 px in both themes. One fix came out of it: an edit's plan listed
  every service's start mode as a change ("Değişir" for direct → direct); it now lists only real changes, so
  an unchanged definition plans nothing.

### DD-277: The last 1.x release points to the clean-install generation (v2-260, 1.2.0)

- **Request:** the rebuild on the branch `yeni-yapi` (DD-271, plan `rebuild.md` on that branch) is a new
  generation that installs only on a clean operating system (its decision S3). Its §4.6: on the 1.x line, a
  last release teaches the old Konsol to show that the new generation needs a clean install instead of an
  update. 1.2.0 is that release. DD-271 to DD-276 are the rebuild's entries on `yeni-yapi`; this entry takes
  the next number free on both lines, and the build number skips v2-255 to v2-259, which that branch uses.
- **Generation 1:** the 1.x line is generation 1 and writes no generation line of its own. Konsol's check
  (`master_update.py`) reads `OBHUT_NESIL` from the newest commit's `Data/install.sh` the way the
  generation-2 module reads it (`^OBHUT_NESIL="([1-9][0-9]{0,2})"$`; a commit without the line is
  generation 1, as every 1.x commit is).
- **Another generation:** `GET /api/konsol/guncelleme` answers `yeni: false`, `hata: ""` and
  `yeni_nesil: {nesil, metin}` (null otherwise); `metin` is the notice: a new generation of Obhut is out,
  it installs only on a clean operating system and never comes to this server as an update, nothing
  changes here, and moving means backing up what is needed and installing on a clean system with `kur.sh`.
  `POST /api/konsol/guncelleme` refuses with the same text (409). Sistem → Güncellemeler shows the notice
  where "Güncelle" was, with the state "Yeni nesil çıktı" and the newest build in "En yeni"; the sidebar
  and Genel Bakış say "yeni nesil çıktı" beside the version; `sudo obhut durum` and `sudo obhut guncelle`
  print it and start nothing. Another generation is reported even when its build number is not in the
  `YYYY.MM.DD-v2-<n>` format, so a later change of numbering cannot turn the notice into a failed check.
- **Second gate:** `master-guncelle` downloads the target commit's `Data/install.sh` before its `kur.sh`
  and stops when any `OBHUT_NESIL=` assignment in it is not exactly `OBHUT_NESIL="1"`, or when the file
  cannot be read (fail closed). It writes only its own result and log files, so the reason shows as the
  last attempt's failure in Güncellemeler; the installer checkout and the system are untouched.
- **Hosts before 1.2.0** do not know the generation and would offer the new generation as an ordinary
  update; the new generation's stage-0 gate stops them (S3), so nothing is half-installed either way.
- **Rejected:** comparing build numbers alone (a newer generation would be offered and fail at its own
  gate); reporting it in `hata`, as the generation-2 module does for its own check (this interface would
  say "Sürüm denetlenemedi" for a check that worked); hiding the newer generation (the operator would not
  learn that 1.x gets no further releases); migrating 1.x hosts (K1 of the rebuild: none).

### DD-276: The rebuild's phase 5: Konsol (v2-259)

- **Scope (`rebuild.md` phase 5):** Konsol's screens follow the prototype the operator approved (sections,
  tabs, flows, wording), built in the existing Vue code; the prototype's annotations and its mock data (which
  named real applications) were not copied: the interface and every suite use neutral names.
- **The operator's decision (2026-10-17):** each application's live download and upload rate comes from its
  own bridge's counters (`/sys/class/net/<interface>/statistics`, the interface from the generator), sampled
  by the WAN sampler's loop; rates only, no totals (the counters restart with the bridge). Shown in the list,
  on the application page and under the WAN rate in Genel Bakış (the busiest five).
- **Uygulamalar (K2, K3):** the list (state, reach, resources, live rate, update state); "Uygulama ekle"
  (`#/uygulamalar?ekle=1`) in three steps: Kaynak (a pasted or uploaded file of at most 256 KiB, an `https`
  address, an image name as a job, a standalone container), Denetçi (the file with line numbers and the
  inspector's marks, refusals stopping the flow with their lines, every question; answers re-checked as they
  change) and Plan (`kur` with `plan: true`: every check the install makes before its first write, nothing
  written; a refusal leads back to its question), then the install job. The application page: Özet, Erişim
  (read-only rows linking to Adresler), Depolama (with sizes), Tanım (the file and the answers; staying ports
  read-only, their home is Erişim; secrets kept unless renewed; "Kaynaktan yenile" for an address; the
  difference as a plan; apply as a job) and Günlük. Secret values never reach an address, browser storage or
  a GET. "Güncelle" is on Özet's update card only (one name, one place).
- **Erişim (A7):** Genel, Adresler, Yerel adlar (its own tab), Tailscale, WireGuard, Güvenlik duvarı (the
  operator's rules and the locked application rows; the technical rules moved to Gelişmiş).
- **Genel Bakış:** Dikkat (the problems, most serious first, each with its place), Uygulamalar (Aç opens the
  first address of a running application), Erişim özeti (Tailscale addresses, internet names (a name must
  exist: WebDAV's switch without a name is not one), raw ports on the internet and on Tailscale, WireGuard,
  a chip per thing open to the internet), Kaynaklar, Ağ, Sunucu. The top bar's problem chip goes to the
  problem.
- **Dosyalar (K7):** Depolama with an "Uygulama verileri" card (each application's data folders with sizes
  from a bounded, cached walk, "Yeniden ölç"); no file-manager card.
- **Sistem (A7):** Sağlık ("Onarım kaydı"), Güncellemeler (Obhut and the count of application image updates,
  each confirmed on its application's page), Hesap, Sunucu, İşlem geçmişi (every audit kind the backends
  write, in the interface's words). The Görünüm tab is gone: the theme switch is in the top bar and the
  palette.
- **Gelişmiş (K8):** Caddy, DNS, Güvenlik duvarı (technical rules and listeners), Podman: read-only, and one
  write, the cleanup (`GET/POST /api/konsol/gelismis/temizlik`) of unused images, networks and volumes and
  of removed applications' data folders, each re-checked right before it goes; containers Obhut does not
  manage are listed read-only. Pulling images and creating or removing Podman resources by hand are gone
  (with `POST /api/konsol/konteynerler/islem`); so are `GET /api/konsol/konteynerler/ayrinti` and
  `GET /api/konsol/ayarlar/klasorler`, which no screen used.
- **The frame:** the command palette (sections, tabs, applications, access rows by name, Uygulama ekle,
  Adres aç, the themes, İşlemler), İşlemler (application jobs, the cleanup, the pending change), and the
  pending banner naming every timed change.
- **Found live and fixed:** `podman images --format json` lists an image once per tag, so the cleanup list
  and the unused-image count showed a twice-tagged image twice.
- **Tests:** Python 871 with only the eight known macOS failures; `bats` 181/181; nine browser suites
  (`yeni-uygulama-ekle-ui` new) and the sign-in suite pass with the layout audit, and the seven-width sweep on
  every suite changed.
- **Live check (test host, 2026-10-17):** the bridge counters' directions (a download inside a container is
  `indirme`, a page served to the Mac is `yukleme`); the install plan refusing a taken application name and
  a taken Tailscale name on their questions and writing nothing; "Uygulama ekle" through the real Konsol in a
  browser with a two-service file (questions, plan, install, the application's page; its address answered);
  33 screen states of every section at 390 px and at 1440 px in both themes with no layout finding and no
  console error; the cleanup through the interface removing an unused image with the typed word, its audit
  line written.
- **Note (DD-279):** "Uygulama ekle" is no longer a sheet at `#/uygulamalar?ekle=1` but a full-window page at
  `#/uygulama-ekle` with a fourth step, Kurulum, that shows the install job's log.

### DD-275: The rebuild's phase 4: access rows (v2-258)

- **Scope (`rebuild.md` phase 4):** every exposed container port of an application has one access row, and
  every change to access (application rows, Konsol and Paylaşımlar, WireGuard's openings) is a settings plan.
  Konsol's screens follow minimally; phase 5 redesigns them.
- **The operator's decisions (2026-10-17):**
  1. Opening or widening access waits for the 60 s confirmation from Tailscale and rolls back unconfirmed;
     closing or narrowing commits at once (an unconfirmed close never reopens). A rename is an opening.
     This applies to Konsol's and Paylaşımlar' rows too; DD-195's typed word and account stay.
  2. "Adres aç" restarts the service: only a port with an address is published on `127.0.0.1` (a pool port);
     a raw port is never published on loopback.
  3. A raw port's host number defaults to the container port and may be changed; conflicts are refused.
  4. WireGuard: turning it on, adding a network and opening one (each opens a WAN UDP port) are plans with
     the 60 s confirmation; turning it off, closing and removing a network commit at once; regenerating a
     network's key commits at once after the typed word; peers, their DNS and keepalive, a network's DNS
     and name stay immediate.
- **The row model (one home):** `UYGULAMA_STATE_DIR/<app>/erisim.json`, keyed `<service>:<port>/<proto>`:
  `adres` (TCP; Tailscale name, optional Tailscale port (K5), optional internet name) or `ham` (closed,
  Tailscale or internet, host port). Row id `uygulama:<app>:<key>`. Install seeds the rows from the answers;
  from then on the rows are the only home of how a port is reached: `yanitlar.json` keeps no port answers,
  the stored definition keeps each port's number and protocol, and an edit fills a staying port's answer
  from its row (a different one is refused: "Bu portun kullanımı Erişim'den değişir."). One name rule for
  every Tailscale name (the inspector's), one `taken_names` (master_applications): other applications,
  `panel`/`paylas`, the base and `modul-*.conf` names, the operator's DNS records.
- **The settings transaction:** `AyarIstegi` is a closed `one_of` (rules, domain, `web` for Konsol and
  Paylaşımlar, `erisim`, `wireguard`); the old WebDAV-only `https` section and its writer are gone. The
  revision covers every `erisim.json` and WireGuard's files. An `erisim` change is validated on the server
  (shape, names, internet name DNS per DD-252, host port conflicts with every `*_PORT`, the pool range,
  WireGuard ports, operator rules, other rows and live listeners; A2's `internet_onayi` for a raw internet
  port), planned (container restart, Caddy, dnsmasq, firewall, certificate; warnings for A2, for raw ports
  that bypass the operator's rules and for renames), applied (snapshot of the app's rows, places and units
  and the Caddy and DNS files → the container side in the same process (`Manager.row_change`, holding only
  `KONTEYNER_LOCK` beside the settings locks) → firewall → `publish()` → certificate wait) and rolled back
  in reverse (`row_restore`). Its worker may run 1800 s and its applying deadline is 900 s (a 300 s ready
  wait fits); the guard timer's start limit is 1200 s. Other sections keep their limits.
- **Rendering:** `uygulama-<app>.caddy` (tailnet `http://<ad>.<domain>` and K5 `http://{$TAILSCALE_IPV4}:<port>`
  to the pool port) and `uygulama-<app>-wan.caddy` (internet names, DD-252's site shape);
  `modul-uygulama.conf` with one `interface-name` per address, written by the projection, not switchable in
  Yerel adlar (shown locked with a link to the row). The 443 gate and DD-190's plaintext-WebDAV rule include
  application internet names. An application's internet name is guarded only by the application's own login:
  Konsol puts no sign-in in front of it (DD-252's trade-off, carried over; the plan says so). DD-172 amended:
  each K5 port is a configured tailnet entry
  (`konsol-base:tail-tcp-<port>`). Raw ports: `PublishPort=<Tailscale or WAN IPv4>:<host>:<port>/<proto>`;
  the guard's per-address ingress permit is back (only for an address the host has now; a malformed
  publication fails the guard closed). `master_container_worker.py --adres-yenile` rewrites the units of
  applications whose raw rows' address changed; `refresh-tailnet-config` starts it.
- **WireGuard through the plan:** a `wireguard` section; `master-wg` has one documented caller mode for the
  settings worker (`OBHUT_KILIT_FD`, an inherited descriptor that holds `install.lock`, verified by device,
  inode and lock state; `OBHUT_AYAR_ISLEMI`, the pending change's id in phase `applying`, and since phase 6
  also `rollback`, when the worker undoes its own change). Only the networks
  file and the stopped marker enter the pending file, never a key or a profile. The immediate routes for
  the planned actions are gone.
- **Read models:** Erişim has one row per application port (and keeps containers no application owns with
  their public-port warning); the firewall view shows raw and K5 ports as fixed rows linked to their row,
  and an operator rule on such a port is refused; the application page shows each port's row.
- **Removed:** Yayınla (`master_yayin.py`, `/api/konsol/yayinlar[/plan]`, its shapes and flow), manual
  `elle-*` addresses (DD-252), package publication rows (DD-199, already without code), the `https` key
  writer (DD-193), `obhut yayin` (now `obhut erisim liste|kapat`, closing at once). The pool keys are now
  `UYGULAMA_PORT_ILK`/`UYGULAMA_PORT_SON`.
- **Known limits:** a busy settings worker still answers 400 with "biraz sonra yeniden deneyin" (as before
  this phase); closing one WireGuard network leaves its UDP port open while the network is registered
  (phase 1 behaviour; fixed in phase 6: the firewall admits only open networks); `paylas.<domain>` can still
  be switched both in Yerel adlar and by WebDAV's Tailscale switch (phase 5; fixed in phase 6: no managed name
  is switched in Yerel adlar any more, DD-156); an `erisim` apply holds its request until the worker ends; an internet name was not
  issued live (it needs a domain whose A record points at the test host).
- **Tests:** the access rows 34 (every validation and conflict class, plan items and `onay_sn`, apply and
  each rollback, rendering, K5, firewall view, locked names, closed request shapes), settings 50 (13 for
  WireGuard), WireGuard 16, applications 25, generator 37, guard 15, worker 49; HTTPS tests on `web.paylasim`;
  bats with the master-wg caller mode and the K5 exact-count check; Python 856 with only the eight known
  macOS failures; `bats` 181/181; the seven browser suites and the sign-in suite with the layout audit.
- **Live check (test host, Debian 13, 2026-10-17):** an application with a web port, a raw TCP and a raw
  UDP port installed with its address active at once (`http://<name>.<domain>` over Tailscale); a rename
  (60 s, confirmed; the old name no longer resolves); a Tailscale port (`<tailscale-ip>:8080`, its tailnet
  entry in the firewall); the raw TCP port to Tailscale (echo over Tailscale, nothing from the WAN); the raw
  UDP port to the internet refused without the consent and answering from the internet with it; an
  unconfirmed widening (Tailscale → internet) rolled back after 60 s; closing at once; "Adres aç" (pool port,
  Caddy site) and "Adresi kaldır" (pool port released); WireGuard: a network added (60 s, confirmed),
  closed at once, an unconfirmed opening rolled back, stopped at once, started (confirmed), its key
  regenerated only with the typed word, removed; after a reboot the address, the Tailscale port and the raw
  port answered again with no failed unit. Konsol's Erişim screens read clean at 390 and 1440 px.

### DD-274: The rebuild's phase 3: generating and running applications (v2-257)

- **Scope (`rebuild.md` phase 3):** an application is installed from its own Compose or Kubernetes file and
  the operator's answers, and then started, stopped, restarted, updated, edited, refreshed from its address
  and removed. The routes are in place; Konsol's add flow and editor are phase 5, access rows phase 4.
- **The generator (`panel/master_generator.py`):** pure; the checked definition plus the engine's
  allocations (pinned images, pool ports, Podman secret names, stopped) become every unit file, the
  environment files, the folders, the `/srv` binds, the start and stop order and the publications.
  - Names: application names have no `_`, so `_` joins application and service and two applications can
    never make the same name: container `<app>_<service>`, unit `konsol-<app>_<service>.container`,
    network `konsol-<app>.network` (`ksl-<app>`, interface `ksl` + 10 hex of its name's SHA-256), pod
    `konsol-<app>.pod` (`<app>`, infra `<app>__infra`), secret `obhut_<app>_<8 hex>`. Every object carries
    `io.master-stack.managed=uygulama` and `io.master-stack.uygulama=<app>`; files may not set
    `io.master-stack.*` labels. `ownership()` knows the class `uygulama`.
  - Units keep the proven lines of the old renderer: the firewall ordering without `Requires=` and the
    guard check in `ExecStartPre` (DD-223), the bind anchors (DD-226), `Pull=never`, journald, `UMask=0077`.
  - Every key is in Podman 4.9's Quadlet (checked against `quadlet.go` of v4.9.3); what came later goes
    through `PodmanArgs=` with values the generator validated (`--entrypoint` as JSON, `--network-alias`,
    `--stop-signal`, `--stop-timeout`, `--cpus`, `--memory`, `--ulimit`, `--umask`, the network's
    `--interface-name`, the pod's `--infra-name` and `--label`). Only a Kubernetes Pod with more than one
    container (`.pod`) and a Compose `condition: service_healthy` (`Notify=healthy` on the dependency,
    `TimeoutStartSec=300`) need Podman 5: on Podman 4.9 (Ubuntu 24.04) the install is refused before any
    write with "… Podman 5 gerekir; bu sunucuda 4.9". A Kubernetes file with one container needs no pod.
  - Health checks: `CMD` and `CMD-SHELL` as Podman's JSON forms, `NONE` → `none`, the file's timings;
    no health check in the file keeps the image's own. Values Quadlet or an env file cannot carry
    (line breaks, NUL, a bare `;`) are refused, by the inspector where the operator can fix them.
- **Start modes (A4):** direct: `User=` the file's user or the Files account, `DropCapability=all`,
  `NoNewPrivileges=true`, proven after the start (user, empty capability sets); root: Podman's default set
  minus `SETFCAP`, `SYS_CHROOT` and, when no container port is below 1024, `NET_BIND_SERVICE`, plus the
  file's `cap_add`. The live check met the consequence: a file that declares 8080 while its image listens
  on 80 stops at once; the job names the service and its journal and leaves nothing behind.
- **Folders (A5) and DD-226:** `/srv` sub-folders through the bind anchors (the anchor key is the container
  name; the name limit is now 128); application data under `UYGULAMA_VERI_DIR/<app>/<folder>` (0700 root;
  a direct service mounts its folders with Podman's `U`, so they become its user's; an existing sub-folder
  keeps the owner its container gave it, as an image's start-up chowns it). The inspector refuses `/srv`
  itself and every path the anchors would refuse at start (hidden, `..`, characters outside
  `A-Za-z0-9 ._-`). Bind sources are still pinned at every start.
- **DD-227 amended (the operator's decision, 2026-10-17):** a container that starts as root may have a
  writable `/srv` folder. DD-227 rejected this path; the operator chose "İzin ver, açıkça uyar": the
  definition carries a warning for each such service ("Bu konteyner root olarak başlıyor; kendi
  kullanıcısına geçmezse /srv'ye Dosyalar hesabının açamayacağı dosyalar yazabilir."), shown by the
  inspector, the edit plan and the application page. A direct start as a user other than the Files account
  with a writable `/srv` folder gets the same kind of warning. A direct start as the Files account keeps
  DD-227's `--umask=0002`.
- **Secrets:** each value becomes a Podman secret created on standard input; the record maps the
  inspector's logical names to them. An edit may keep a value (`{"keep": true}`, only when the application
  has it); a renewed value is a new secret, the old one is removed only after the new units are ready.
  Live: the database password reached the container and no file, journal line or reply.
- **Ports:** an address answer gets a loopback pool port (`YAYIN_PORT_ILK`–`YAYIN_PORT_SON`, free of every
  other use), kept across edits; its Caddy row is phase 4. A raw port publishes nothing yet (A2). The
  container guard reads the application records: each bridge gets its own return rule; any publication
  other than `127.0.0.1` fails closed in this phase.
- **Records and lifecycle (`panel/master_applications.py`, the worker):** `UYGULAMA_STATE_DIR/<app>/`
  (`kaynak.yaml`, `kaynak.json`, `yanitlar.json` without secret values, `tanim.json`, `yerler.json`,
  `env/`), all 0600 root. Every write is a job of the one broker (`systemd-run`, the request on standard
  input only, never in the job record) with an audit line `uygulama-<verb>`. Install checks everything
  before its first write (the file again on the server, free names, `/srv` folders, pool ports, a
  preliminary render, Podman 5), then writes, pulls and pins, creates secrets, runs Quadlet's dry run,
  starts in order and waits until each unit is active, each container is its own and healthy (300 s);
  any failure takes back everything the job made. The wait stops at once when systemd restarts a unit
  that exited, naming its journal. Stop removes `[Install]`; update pulls the same tags and changes
  nothing when no digest moved; edit has a dry run (units, environment, ports, folders, secrets, start
  modes, warnings) and restarts the application; remove keeps the data unless the application's name is
  typed for `sil`; images stay for Gelişmiş's cleanup.
- **Draft sources (K2):** an `https` address (every resolved address must be public, the connection goes
  to the checked address, at most three redirects, 256 KiB, 10 s); an image name (a job: pull, then a
  Compose draft with the image's exposed ports and volumes only); a standalone container (a Compose
  draft from `podman inspect`: secret-looking variables are left empty, refused settings are written as
  they are so the inspector shows them). Taking over a container copies its named volumes into the new
  folders and removes the old container (never its volumes) only when the application is ready.
- **Routes:** `GET /api/konsol/uygulamalar[/{app}[/gunluk]]`, `POST …/uygulamalar/kaynak`, `…/kur`,
  `…/{app}/islem`, `…/{app}/tanim`, `…/{app}/yenile`, `…/{app}/kaldir`, typed in the route table.
- **Removed:** single-container definitions and everything that served them (store, validation, renderer,
  create, save, adoption and its import, the container start/stop/remove of unmanaged containers, the
  definitions' Tailscale address refresh, `KONTEYNER_NETWORK`, `GET /api/konsol/konteynerler/guncellemeler`,
  Yayınla's step that added a loopback port to a container, `master_uygulamalar.py`), and in Konsol the
  add flows, the definition editor and the container settings tab. Gelişmiş keeps its Podman resource
  actions until phase 5.
- **Found live and fixed:** the base installs `catatonit` (Podman builds a pod's pause image with it, and
  `init: true` needs it); a job read while the worker had only reserved its record answered "kayıt
  okunamadı" instead of "running"; a container that exited between `exists` and `inspect` failed the wait
  with a tool error.
- **Limits for later phases:** an edit restarts every service of the application; the address is shown as
  given (with its query); Ubuntu 24.04 is not live-verified for applications; `contract.md`,
  `architecture.md` and `design/container-manager-api.md` still describe removed routes (phase 6 rewrote the
  first two and moved the third to `archive/design/container-manager-api.md`).
- **Tests:** the generator 35 (golden unit files for every accepted fixture; every Quadlet key checked
  against Podman 4.9's set; no secret value in any plan), the inspector 30, the records, pool and drafts
  19, the worker 31 (every install step's rollback, a restarted or vanished container, takeover, edit,
  remove; no secret value in any argv, file, record or reply), the manager 20, the routes 11, the guard 12;
  Python 797 with only the eight known macOS failures; `bats` 178/178; the seven browser suites and the
  sign-in suite pass with the layout audit.
- **Live check (test host, Debian 13, Podman 5.4.2, 2026-10-17):** installed through the routes: nginx
  from a file with a read-only `/srv` folder (served on its pool port), a busybox site started directly
  as the Files account (its folder became the account's, no capabilities), PostgreSQL with a secret and
  a dependant waiting for `service_healthy` (reached it as `db`), a two-container Kubernetes Pod (shared
  `localhost`), a Pod fetched from an `https` address and refreshed from it (the changed port came back as
  a new question), a draft from an image name, and a standalone Redis container taken over with its data.
  Start, stop (no `[Install]`, unit inactive), restart, update (no new digest: nothing changed), an edit
  keeping the secret and one renewing it (new Podman secret, old removed), removal keeping the data and
  removal deleting it after the typed name; private, loopback and CGNAT addresses and `http` refused for
  drafts. After a reboot every application came back. A re-run of the installer left the running
  applications alone. Konsol's list, Genel Bakış and every tab of four applications read clean at 390 and
  1440 px.
- **Note (DD-281):** a removal now deletes the data by default once the name is typed ("sakla" keeps it), takes
  the images nothing else uses, and with the data the application's job records.

### DD-273: The rebuild's phase 2: reading and inspecting application files (v2-256)

- **Scope (`rebuild.md` phase 2):** pure functions and one dry-run route; nothing is written on the
  server. Phase 3 installs what this phase's definition describes.
- **The YAML reader (`panel/master_yaml.py`, K4):** standard library only. Block mappings and sequences
  (also a sequence at its key's own indentation, as `podman kube generate` writes), plain and quoted
  scalars, flow collections over several lines, literal and folded block scalars with their indicators,
  comments, several documents. YAML 1.2 core schema for scalars; mapping keys stay the written text.
  Anchors, aliases, merge keys, tags, complex keys, directives, duplicate keys, tab indentation and
  multi-line plain or quoted scalars stop with their line and column; 256 KiB, 64 levels and 100,000 nodes
  at most. Every mapping and sequence carries the line of each key and item. 200,000 random inputs raised
  nothing but its own error.
- **One model for both formats (`master_compose.py`, `master_kube.py`):** services with image, command,
  entrypoint, working directory, user, environment, ports, mounts, health, restart, dependencies, added
  and dropped capabilities, labels, stop settings, host name, init, read-only root, shared memory and
  limits; Compose variables with their uses. The supported, noted and refused keys are listed in
  `rebuild.md` 4.2. Harmless keys common in published files (`logging`, `init`, `read_only`, `cap_drop`,
  `deploy.resources`, `ulimits`, `security_opt: no-new-privileges`) read or are noted, so such files do
  not fail; anything that widens what a container may do is refused with its line. `x-` keys are ignored
  (A3). Kubernetes `$(VAR)` in `command`, `args` and env values is expanded from the container's own
  earlier non-secret entries, as Kubernetes does; a reference to a secret is refused.
- **The inspector (`master_inspector.py`):** `inspect(text)` returns the format, the suggested name,
  refusals, notes, line marks and the questions: the name, every port (nothing preselected for TCP, A1;
  UDP only raw, A2), every variable and file-literal or Kubernetes secret (one question per secret and
  key), every mount (the application's folder or a folder under `/srv`, A5), every container's start mode
  (A4, with the capabilities it leaves open). `check(inspection, answers)` validates every answer and
  returns the definition for phase 3 and, separately, the secret values; an environment value mixing
  text and a secret becomes one secret holding the composed value. Neither function raises.
- **The route:** `POST /api/konsol/uygulamalar/denetle` in the route table, with a per-route body limit
  (1 MiB; the text at most 256 KiB). No write, no subprocess, no network; secret values are never in the
  reply. `do_POST` now matches the route before reading the body, so each route keeps its own limit.
- **Install:** the four modules are installed beside the backend; the bats test now follows imports
  through every installed module.
- **Tests:** the reader 28, Compose 37, Kubernetes 14, the inspector 21, route tests in `test_api`;
  fixtures in `tests/fixtures/uygulama/` (a published-style file with named volumes and a placeholder
  path, linuxserver qBittorrent, a web application with PostgreSQL and a secret, a Pod and a Deployment as Podman writes them, a
  hardened file, an unsafe file). Python 760 with only the eight known macOS failures; `bats` 177/177; the
  nine browser suites pass.
- **Live check (test host, 2026-10-17, v2-256 re-run over v2-255):** the seven fixtures through Caddy and
  the real backend in 130-260 ms each; the unsafe file refused on eight lines; answers to the web
  application with a database gave its two-service definition with two Podman secret names and no secret
  value in the reply; a body over the limit and broken JSON were refused with 400.
- **No application-specific behaviour:** the start question's suggestion comes from the file alone (A4):
  a file that sets `user:` is suggested "direct", any other "root"; what an image does inside is its own
  matter, and a file that needs more asks for it and is read or refused like any other.
- **For phase 3 (`rebuild.md`):** the generator renders the new definition fields and decides the health
  check, `httpGet` probes, the root mode's user and short image names.

### DD-272: The rebuild's phase 1: a clean base without the App Store (v2-255)

- **Scope (`rebuild.md` phase 1):** the base installs with its built-ins only (Konsol, Tailscale, Caddy,
  dnsmasq, firewall, Files, folder WebDAV, WireGuard). No store engine, no package, no `PAKET_*`, no code
  kept for hosts installed by 1.x. Konsol's single-container definitions stay until phase 3.
- **Generation gate (DD-271 S3):** `install.sh` declares `OBHUT_NESIL="2"` and records it in `state.env`.
  `check_generation` runs in stage 0 right after the OS check, before the lock and before any write: it
  stops when `STATE_DIR` exists without `NESIL_FILE` holding exactly `2`, or when a path in
  `ESKI_NESIL_IZLERI` exists (the 1.x store engine and registries). The marker is written by
  `write_generation` just before `write_config`, after the operator's confirmation, so the "nothing was
  changed" promise of a cancelled install still holds. Konsol's update check offers a build only from the
  same generation; otherwise it says why (`master_update.py`).
- **Built-ins installed directly:** the Files and WebDAV units are rendered into `UNIT_DIR`; WebDAV's site
  source is installed at `SHARE_CADDY_SOURCE` and filtered by `master_publications.py filter-caddy paylasim`
  into the Caddy import folder; its name went through `master_settings.py filter-dns` (gone in phase 6 with
  the name switches, DD-156); stage 7 runs `verify_builtins`. The live file names (`paylasim.caddy`,
  `modul-paylasim.conf`) are kept.
- **WireGuard built in (K6):** its keys live in `config/defaults.env` and `state.env`; `master-wg` is a base
  script with two new subcommands, `durdur` (writes the open networks to `WG_STOPPED_FILE`, disables their
  units, re-applies the firewall) and `baslat` (firewall first, then the listed networks); both take the
  install lock and refuse while a Konsol setting is pending. Stage 1 installs `wireguard-tools` and
  `qrencode`, stage 4 the tool, the drop-in, the kernel module and `WG_CONF_DIR`; no network is created.
  The firewall reads the networks file and the stopped marker itself and is stricter than the package
  hook was (interface `wg[0-9]`, scope `inet`, no symlinked registry, a malformed line stops the run).
  Konsol talks to `panel/master_wireguard.py` through typed routes under `/api/konsol/wireguard` with
  path parameters (`{iface}`, `{name}`, checked after decoding; a bad one answers 404); numbers must be
  numbers; `/state` gains `kurulu`, `durduruldu` and the reserved ports `master-wg` refuses. Audit kinds are
  `wireguard-<verb>`, worded in the interface's table. Writes stay immediate until phase 4.
- **Only the route table answers:** the backend answers nothing outside `master_api.ROUTES` except
  `/oturum-denetle` and the sign-in POST, and only GET, HEAD and POST (`test_api` enforces it with the
  table emptied). The package loader and `/api/uygulama/*`, `/moduller`, `/uygulamalar/hesap` and `kur` are
  gone.
- **Removed:** `master-modul`, `magaza/`, the registry, `MODULES_*`, `PACKAGE_OVERRIDES_DIR`, every `paket_*`
  helper and package hook, package traffic (the overview keeps WAN rates), package health, package
  publications, package-protected folders, the package parts of the container modules, the `modul` job kind,
  the catalogue and every package screen, the Gezgin note, App Store wording, built-ins in Uygulamalar, the
  1.x cleanups and gates (`.pay`, RAR repository, archive workspace, `RETIRED_*`), `--archive-dir`, `--share`,
  `--protected`, the `/yeni` redirect, old Konsol address redirects, the folder shares' schema-3 migration,
  `master_permissions`' excluded names. A share record with a key this version does not write fails closed.
- **Kept on purpose:** `PRIVATE_STATE_ROOT` (it hides `/var/lib` from Files and WebDAV); the
  `CADDY_MODULES_DIR` and `modul-*.conf` names (Caddy's import folder and dnsmasq file names); the firewall
  view's `sabit` field (phase 4's locked raw ports); external containers in Uygulamalar (adoption until
  phase 3).
- **Moved to later phases (`rebuild.md`):** WireGuard writes through the settings plan and the old
  WebDAV `https` settings writer (phase 4); the switches that exist only for tests (phase 6).
- **Tests:** `bats` 177/177; Python 657 with only the eight known macOS failures; the nine browser suites
  with the layout audit pass. Package tests are deleted; new ones cover the gate, the built-ins, WireGuard in
  the base, `master-wg durdur/baslat`, the WireGuard routes, the update check's generation and the
  route-table rule.
- **Live check (test host, 2026-10-17):** the 1.x install removed by hand (S4), the branch installed from
  the working tree on Debian 13: every built-in active, the marker `2`, no 1.x trace, WireGuard installed and
  off. Through Konsol's routes: first network created (UDP 61001 opened), a test device added (QR served),
  stopped (rule and interface gone, marker lists `wg0`) and started again; after a reboot onto the new
  kernel every unit, `wg0` and its rule came back. A re-run changed nothing and restarted nothing. With a
  fake 1.x trace, and with the marker moved away, stage 0 stopped before writing. The live Konsol at 390 and
  1440 px: 23 states, no console error, no layout finding; old addresses land on Genel Bakış; the update
  check reports GitHub's 1.x as another generation. The test device and network were removed afterwards.

### DD-271: The rebuild: one container model, Obhut knows no application (accepted 2026-10-17)

- **Request (user, 2026-10-16/17):** Obhut's built-ins stay fixed; external software runs only as Podman
  containers added from their own Compose or Kubernetes YAML through an inspector that asks for paths,
  secrets and ports; Obhut must not know Gezgin or qBittorrent; WireGuard is a built-in; a port reaches
  outside only through a Caddy row or a raw-port row managed in Erişim. "Kalıntı veya arka kapı bırakmadan
  temiz ilerleyelim."
- **Plan:** [`rebuild.md`](rebuild.md) holds the decisions (K1–K9, A1–A7, S1–S4), the target architecture,
  what is removed for good, six phases with checklists and the checks every phase must pass. Work happens
  on the branch `yeni-yapi` and merges to `main` once, complete (S2); `main` stays installable on 1.x
  meanwhile.
- **Key choices:** both formats through one model, inspector and generator, with Quadlet + systemd as the
  only runtime (no Docker, no Compose runtime, no `kube play`); Obhut's own YAML subset reader in standard
  library Python (K4); no `x-obhut` block, the inspector guesses and the operator confirms (A3); every TCP
  port answered by the operator (A1); raw ports closed by default (A2); start mode asked per container (A4);
  application data in a visible folder under `/var/lib/master-stack/uygulamalar/` (A5); WireGuard installed
  turned off (K6).
- **No compatibility layer (K1, S3):** the new generation installs only on a clean operating system; stage 0
  stops on any older Obhut. No migration, no ignored options, no redirects for old addresses; the store
  engine, the packages and every leftover of the 1.x line are removed, not disabled.
- **Supersedes, when the phases land:** the store model and its phases (DD-196 to DD-203, DD-207), the
  packages (DD-209, DD-210, DD-219 to DD-222, DD-262, DD-264), Konsol's single-container definitions and
  adoption (DD-211, DD-266 in part), WireGuard as a module (DD-150), package publications (DD-199) and the
  manual rows (DD-252). Each phase's DD entry retires what it replaces.
- **Rejected:** keeping the App Store beside the new model (two ways to run software, and Obhut would keep
  knowing applications); a Compose runtime or `podman kube play` (Obhut's ports, binds and guard rules
  would have to be patched in afterwards); migrating 1.x hosts (code that exists only to be deleted, against
  the request); `python3-yaml` (the operator chose a reader with no new package, K4).

### DD-270: Konsol's layout is measured on every screenshot of its browser suites (v2-254)

- **Request (user, 2026-10-16):** "Webui arayüzü tara ve şablonların sınırlarını koruduğunu taşma silinme
  olup olmadığını. Pencere boyutlarının birbirlerini ezmediğini yapının bozulmadığını doğrula."
- **Audit (`tests/duzen-denetimi.cjs`):** one measurement in the page, no change to it. It reports a
  horizontal page scroll, an element past the window's edge outside a scroll box, content spilling over its
  box, content cut off without an ellipsis, a squeezed box (an ordinary word broken across lines), text or
  controls drawn over each other, and an open dialog that neither fits the window nor scrolls.
- **What it does not count, and why:**
  - an ellipsis: shortening on purpose;
  - a token longer than 12 characters wrapping inside its box (an address, an image digest): that is the
    intended fallback, the alternative being an overflow;
  - screen-reader-only, inert, SVG and hidden elements, and the content of a closed `<details>` (Chrome lays
    it out without painting it);
  - text overlaps measured on the boxes: inline boxes that wrap and pills beside text share boxes without
    their glyphs touching. Overlaps are measured where the glyphs are, which also catches text running out of
    a narrow cell into the next one.
- **Where it runs:** every `shot()` of the `yeni-*` suites at the screenshot's width; a finding fails the
  suite like a console error. `giris-ui.cjs` at each of its widths. A sweep (`KONSOL_DUZEN=tara`) measures
  each state again at seven widths from 320 to 1920 px and restores the viewport; the phone menu, which a
  wider window closes on purpose, is swept at phone widths only, and `KONSOL_DUZEN_ATLA` leaves out a state
  a resize changes (the account card hides a revealed password when the tab hides). Before a screenshot the
  harness also waits for every finite animation: Vue drops a transition's classes when its root's
  transition ends, and the editor sheet's own slide ran a frame longer (it measured 1 px past the edge).
- **Found and fixed:** on a phone a card table cell (`td[data-label]`, a flex column) could not break a long
  address such as `100.64.0.2%tailscale0` or `100.64.0.2:62984`, which then ran over the next
  column (Erişim → Güvenlik duvarı's listeners, an application's port card, Gelişmiş → DNS). The cells now
  take `overflow-wrap: anywhere`. Nothing else was found.
- **Live check (test host, 2026-10-16, v2-254):** 43 states of the live Konsol (every section and tab, the
  add, publish, share and new-folder flows, a removal question, the palette) at eleven widths from 320 to
  1920 px in the light theme and four in the dark, and the activity drawer at nine desktop sizes: no
  finding; the two spilling cells now wrap in their column. The suites' 393 states, at their own width and
  swept, have none either.
- **Rejected:** screenshot comparison against stored images (every data or font change breaks it, and it
  tells a changed picture, not a broken one); a sweep on every run (the resize changes some states, and
  seven widths take a suite's time several times over).

### DD-268: The redesign's phase 5: Konsol as an installable app and the `obhut` recovery tool (v2-252)

- **Request (user, 2026-10-16):** "Faz 5 e geçelim" (phase 5 of DD-258). Choices: the app is a manifest
  with icons, no service worker; `obhut` covers state and recovery, not every action; and "Paylaşım kalsın
  kaldırmayalım gezgin kontainer olarak kendi içeriğini paylaşacak": sharing does not move to Gezgin.
- **Installable app:** `manifest.json` (name "Obhut Konsol", short "Obhut", `start_url` `/#/genel`, scope
  `/`, standalone, the Ô icons at 192 and 512 px — the touch icon's composition, the mark inside the
  maskable safe zone — plus the SVG) and the head tags for theme colours and the iPhone home screen. The
  CSP gains `manifest-src 'self'`; the manifest and its icons are open before a session like the sign-in
  page's files, as the browser fetches them without cookies. No service worker: Konsol is a live panel,
  an offline shell would only show stale state, and a cached build could outlive an update; on the
  tailnet's plain HTTP a worker would not run anyway.
- **`sudo obhut`** (`panel/master_obhut.py`, wrapper `scripts/obhut`, installed to `SBIN_DIR`): `durum`
  (version and build, addresses, health with what fails, applications, a pending change, a newer
  release; `--json`), `denetle` and `onar` (master-onar, which works without the backend), `guncelle`
  (only when the backend says a newer build exists; asks, or `--evet`), `hesap durum|sifirla`
  (master-konsol), `uygulama liste|baslat|durdur|yeniden-baslat <id>` (the actions the application
  offers, with its revision), `yayin liste|kapat <id>|--hepsi` (the internet name off through the
  settings transaction, the Tailscale name kept) and `geri-al` (a pending settings change). It speaks to
  the backend on its own socket as the local caller (`Host: panel.<domain>`, `X-Konsol`, DD-180), never
  over TCP or a shell; when the backend does not answer, `durum` reads the core units from systemd and
  points to `sudo obhut onar`. Root only.
- **Live check (test host, v2-252):** `durum`, `uygulama liste`, `yayin liste`, `hesap durum`, `geri-al`
  with nothing pending and `guncelle` on a build newer than GitHub's (no update offered); with
  master-panel stopped, `durum` listed the units and `onar` brought the backend back; `uygulama
  yeniden-baslat gezgin` re-created the container and `baslat` on a running one was refused; `yayin kapat
  paylasim` closed WebDAV's internet name and `--hepsi` then found nothing open. The manifest came as
  `application/json` under a CSP with `manifest-src 'self'`, its icons as PNG, Chrome read it without an
  error and reported no installability error.
- **Sharing stays in Konsol (amends DD-258):** Konsol's folder shares (WebDAV, Dosyalar → Paylaşımlar,
  DD-158/192) are permanent, with their separate Tailscale and internet policies, HTTPS publication and
  attempt and connection budgets. Gezgin, as an App Store container, shares its own content with its own
  links and tailnet WebDAV (DD-264); the two sit side by side and neither replaces the other.
- **Rejected:** a service worker (stale state and builds for no gain on a live panel); an `obhut` that
  mirrors every interface action (the interface stays the place for planned changes; the tool is for
  getting back in).
- **Partly retired by the rebuild (DD-272, DD-275):** `obhut yayin` is now `obhut erisim liste|kapat`
  (DD-275), and Gezgin with its own shares is gone (DD-272); the app manifest, `sudo obhut` and Konsol's
  folder shares hold.

### DD-267: The redesign's phase 4b: Dosyalar, Paylaşımlar, Konsol at `/` and the old interface removed (v2-250)

- **Request (user, 2026-10-16):** "faz 4b'ye geçelim" (phase 4 of DD-258, second part; DD-266 was 4a).
  Choices: Dosyalar stays lean and leans on Gezgin; folder shares move under Dosyalar; the old interface
  goes now; archive jobs and favourites leave the backend with their interface; the text editor works in
  both the server folders and Sistem dosyaları; the Ana Menü edit mode goes; one delivery.
- **Dosyalar** (`#/dosyalar`, tabs in `sekme=`): Depolama (the disk, what the user area holds, whether
  `/srv` is its own mount, the trash, the top folders with size and count and who uses each — every
  application's bind mounts from the new `GET /api/konsol/depolama`, folder shares, the folders a
  package writes —, and Gezgin: "Gezgin'de açın" or "Gezgin'i kurun"); Sunucu klasörleri (one folder
  browser: crumbs, folders first in Turkish order with count and size, a filter, tick boxes, an upload
  queue with progress and cancel, download, new folder, rename, move, trash, a package's folders locked,
  share marks leading to Paylaşımlar, the text editor; the folder, filter and open file in the address
  as `yol=`, `ara=`, `dosya=`); Çöp kutusu (restore, permanent delete and empty behind the typed word);
  Paylaşımlar; Sistem dosyaları (the same browser over `/api/sistem/*`, tailnet only, permanent delete
  by the item's own name, the editor warning that it saves as root). The editor is the existing
  CodeMirror bundle (DD-249) loaded on first use from `/duzenleyici.js`. Not carried over (Gezgin has
  them): archive jobs, favourites, the Finder-style window, the grid/list switch and its keyboard set.
- **Paylaşımlar:** the share manager's view and writes move into the route table unchanged
  (`GET /api/konsol/paylasim`, `POST paylasim/kaydet`, `POST paylasim/kaldir`); the old pause request
  (`durum`) is gone, as DD-192 made it a connection switch. One card per share with both connections
  (switch, RO/RW with its question, 1/7/30 days or unlimited, the address with copy and the Infuse
  fields, the server's reason), the create and edit sheets (folder chooser over the user area, user
  name, a password typed or generated), removal behind the typed word, and the deep links
  `yeni=<folder>` and `paylasim=<id>` from the folder lists; Erişim's WebDAV rows lead to the tab.
- **Konsol at `/`:** the build (still kept in `console/yeni/`) is the console's root; the installer
  places it with the sign-in page, the editor bundle and the marks, and deletes every other file or link
  under `CONSOLE_WEB_DIR` (the old interface, the `/yeni/` copy, the packages' `uygulama/<id>/` pages)
  and the folders left empty; it refuses a `CONSOLE_WEB_DIR` outside `/usr/local/share/master-stack/`
  and a build file that would overwrite one of the files placed beside it. Caddy sends `/yeni` and
  `/yeni/*` to `/` (308; the browser keeps the `#view`). The sign-in page carries its own styles in
  Konsol's colours and loads `/tema.js`; these, the font and the marks are open before a session (they
  carry nothing private). The session check returns to `/`; `geri=yeni` is gone. Old hash addresses land
  on their new homes (`#/moduller` → the catalogue, `#/konteynerler/<ad>` → the application,
  `#/ayarlar/fw` → Erişim's firewall, `#/ayarlar/konteynerler` → Gelişmiş → Podman,
  `#/dosyalar/klasor/<yol>` → Sunucu klasörleri, `#/wireguard` → Erişim's WireGuard tab, `#/torrent` →
  the application's page or its install, …; an address that depends on what is installed waits up to 6 s
  for the application list); the interface has no links to the old one any more.
- **Removed with the old interface:** the shell's files (`index.html`, `konsol.*`, `panel.css`,
  `ayarlar.*`, `dosyalar.*`, `arsiv.js`, `konteynerler.*`) and their Playwright suites; the ZIP/RAR jobs
  (`master_archives.py`, `master_rar.py`, `/api/archives*`, `--archive-dir` — accepted and ignored for
  one release so an install stopped between stages cannot leave Files down —, the RAR apt source,
  `unrar`/`python3-rarfile` no longer installed; Files no longer reserves the `.arsiv` name, and WebDAV
  and Gezgin no longer mask it); favourites (`/api/konsol/favoriler`); the Ana Menü layout
  (`/api/konsol/duzen`); the routes only the old shell used (GET `/api/konsol/ayarlar` and
  `/ayarlar/durum`, `/moduller/<id>/*`); the packages' page scripts (`sayfa.js`/`sayfa.css`,
  `PAKET_SAYFA`, the engine's `paket_sayfa_koy`/`kaldir`, `konsol.json` `sayfa`, `Modul.sayfa`,
  `Uygulama.sayfa`; `state.env` no longer carries `CONSOLE_WEB_DIR`, which only the engine's page helper
  read). Outside the route table the root backend keeps only the session check, the sign-in POST and the
  packages' own APIs.
- **What a re-run removes,** each only as what an earlier run left: the RAR source file (a regular file,
  before stage 1's `apt-get update`), `duzen.json` and `favoriler.json` in `KONSOL_AUTH_DIR` (regular
  files, after the new backend runs), `master_archives.py` and `master_rar.py` in `SBIN_DIR`, and
  `SERVER_ROOT/.arsiv` in stage 7 after the new units run, only while it is a real directory directly
  under the user area owned by the downloads uid with mode exactly 0700 (a folder of that name made
  later is 0775 and stays; the removal does not cross file systems and a failure is a warning).
  Installed `unrar` and `python3-rarfile` are left; on Debian they get no updates without another
  non-free source (`apt purge unrar python3-rarfile`).
- **Operator messages** name the new places (Sistem → Hesap, Erişim → Adresler, Sistem → Günlük, Sistem
  → Güncellemeler, the catalogue in Uygulamalar, the application's own settings), and the installer's
  closing summary lists the sections. Gelişmiş's Caddy view now reads a `redir` with a path or a named
  matcher before its target as that path's route (it showed `redir /yeni / 308` as the root sending to
  `/yeni`).
- **Tests:** the `yeni-*.cjs` suites run the interface at `/` (two new ones: `yeni-dosyalar-ui.cjs`,
  `yeni-paylasim-ui.cjs`); Bats runs the installer's console placement on a fixture.
- **Retired or amended by this entry:** retired: DD-161 (the App Store page), DD-166, DD-170 and DD-183
  (archive jobs), DD-204, DD-213, DD-216, DD-230, DD-231 and DD-242 (the old Ana Menü, its skin, tiles,
  widgets and edit mode, the sidebar entries), DD-232, DD-236, DD-237, DD-243 and DD-244 (the old Files
  window), DD-245 (the old update control and Ayarlar → Sistem), DD-250 (favourites). Amended, as parts
  still hold: DD-145, DD-155, DD-159, DD-160, DD-169, DD-180, DD-181, DD-182, DD-185, DD-192, DD-200,
  DD-202, DD-206 (the network card's data feeds Genel Bakış), DD-208, DD-210, DD-211, DD-212 (cumulative
  totals), DD-214, DD-215, DD-221, DD-225, DD-227, DD-229 (WireGuard stops as a whole; the host stays
  closed to containers), DD-233, DD-235, DD-239, DD-241, DD-246, DD-247, DD-249, DD-253, DD-258, DD-259,
  DD-261, DD-262, DD-265.
- **Live check (test host, v2-250):** a re-run over v2-249 removed the RAR source (the packages stayed),
  `/srv/.arsiv` (owned by the downloads uid, 0700), the old archive helpers and every old console file;
  every service came back. `/` opened Konsol, `/yeni/` answered 308 to `/`, the tailnet's `/giris.html`
  went back to `/`. Dosyalar: Depolama; a folder made in `/srv`, a file uploaded, edited and saved in the
  editor (the saved text read back), renamed, moved to the trash, restored, trashed again and deleted for
  good; Sistem dosyaları opened `/etc/hostname` with the root warnings and made and deleted a folder under
  `/tmp` by its typed name. Paylaşımlar: a share made for a test folder answered WebDAV from a tailnet
  device (PROPFIND 207), refused a write while read-only (403), took one after read-write was confirmed
  (201) and refused the account after removal (401). Seven old addresses opened through `/yeni/` landed on
  their new places with the `#view` kept.
- **Rejected:** keeping the old interface at `/eski/` for a release (two interfaces to keep safe and
  working; the operator chose to remove it now); renaming `console/yeni/` (pure churn across the build,
  its digest and the tests); keeping archive jobs in the backend without an interface (an
  untrusted-input parser nobody can reach is still attack surface).
- **Partly retired by DD-272 (v2-255, the rebuild):** the `/yeni` redirect, the old hash addresses, the re-run
  removals of earlier runs' leftovers, the catalogue, the packages' APIs and every Gezgin mention are gone;
  Dosyalar, the share routes, Konsol at `/` and the console placement rules hold.

### DD-266: The redesign's phase 4a: Sistem, Gelişmiş, adding applications and their settings (v2-249)

- **Request (user, 2026-10-15):** "Sıradaki aşamaya geçelim" (phase 4 of DD-258). Choices: Dosyalar
  stays lean and leans on Gezgin; folder shares move under Dosyalar; the old interface goes at the end
  of phase 4; phase 4 lands in two parts. 4a (this entry) builds everything except Dosyalar beside the
  current Konsol; 4b builds Dosyalar with Paylaşımlar, makes `/yeni/` the address `/` and removes the
  old shell (done in DD-267).
- **Routes moved into the table, same paths and answers** (the current Konsol keeps using them): the
  Podman reads (`konteynerler/liste|ayrinti|gunluk|guncellemeler|islem`), `ayarlar/klasorler`, `oturum`
  with `oturum/kur|cikis` and `hesap/parola`, `POST guncelleme`, `POST yeniden-baslat`,
  `onarim/gunluk` (plain text: a route may declare `text`) and `islemler`. `oturum/giris` stays outside:
  only the sign-in page uses it.
- **New routes:** `GET /api/konsol/gelismis` (the settings view's Caddy and dnsmasq parts: sites with
  their typed routes, names, raw files; read-only), `GET /api/konsol/uygulamalar/hesap?id=paket:<id>`
  (the first-login account, shared with the old `moduller/<id>/hesap`; the temporary password only
  with `parola=1`, audited) and `eylem: "kur"` in `POST /api/konsol/uygulamalar/islem` (a catalogue
  package with its install form, through the same `module_install` App Store uses, DD-210). A package
  and an application carry `hesap` (PAKET_HESAP), so the page asks only packages that have an account.
- **Sistem:** Sağlık (every check, "Denetle" at once and "Onar" after a question, the last report
  with its steps, the repair log as text), Güncellemeler (versions and builds, "Yeniden denetle", the
  update with the old confirmation and a reload when it ends), Hesap (create the Konsol account on the
  tailnet, change the password — the current one only on the internet name —, sign out; the sidebar's
  "Çıkış yap" on the internet name), Sunucu (facts and the reboot: a typed word, a wait, the page
  reloads when the server answers again), Görünüm and Günlük (the audit log with kinds and search).
  Update, repair and reboot stay locked on the internet name.
- **Gelişmiş:** Caddy and DNS (effective configuration, raw files with copy), Güvenlik duvarı (a link
  to Erişim's technical rules, no second firewall page) and Podman's images, volumes and networks
  (pull, create, remove with the typed word; a used or pinned one cannot be removed).
- **Uygulamalar:** "Uygulama ekle" with the catalogue (a package's own words and its install form drawn
  from `konsol.json`: text, password with a repeat, folder through the new folder picker), a container
  from an image (every field of the old editor, a review that calls out internet ports) and adopting a
  foreign container (preview, every scope chosen again, the typed word; unsupported options block it).
  The application page gets the container's details (unit, ID, tag, update state with "Güncellemeleri
  denetle", limits, command, environment without secret values, how it starts, ports and listening
  sockets), a log with 100–1000 lines and search, "İmajı güncelle" whenever the container offers it, and
  an Ayarlar tab: the Konsol container's definition editor (field-by-field diff, the re-creation said
  first, a stale revision offers the current definition), an App Store package's adapter settings, the
  package's settings form (`form.oku/yaz`, only changed fields, a blank password kept; a field the
  adapter card edits is left out) and the first-login account (shown for 30 s on request, copied
  without being shown). A finished removal leads back to the list.
- **Packages are drawn from their declarations:** the new shell loads no package script; a package's
  install and settings forms, account, stop and removal words come from `konsol.json` and the manifest
  (DD-200's page scripts serve the current Konsol until 4b). What qBittorrent's own page showed beyond
  that (its profile path and last error, the note on a folder outside the downloads root, a 10 s status
  refresh) is not carried over.
- **Shared pieces:** a copy button with the plain-HTTP fallback (the tailnet name has no secure
  context), a leave guard (the browser asks before closing a tab with a draft; Erişim's drafts use it
  too) and the folder picker. A 401 leaves for the sign-in page only when it says `giris`.
- **Live check (test host, v2-249):** every Sistem and Gelişmiş tab; "Denetle" and the repair log;
  the update check; a Podman volume and an internal network made and removed; a container created from
  an image already on the server (a loopback port answering, a volume, an environment value), its
  definition edited (re-created with the new value), its log searched and the container removed; an
  adoption refused with the image's unsupported options shown; WireGuard installed from the catalogue
  and removed; qBittorrent installed with its form, its user name changed through the settings form
  (confirmed by the package's status), its account card shown and removed with its data; the server
  rebooted from Sunucu and the page back by itself.
- **Found by the live check:** a container job failed at once with "Kurulum veya başka bir konteyner
  işlemi sürüyor" when it met the share guard, which holds install/modul.lock for a moment every 30 s;
  the worker now waits up to 5 s for each lock, as `master-modul` does (`flock -w 5`), in the same
  order, so no new deadlock is possible. The create form offered a new volume name, which the worker
  refuses (it mounts only existing volumes); the form now refuses it and says where to create one.
- **Rejected:** loading package scripts into the new shell (code from a package in the page's own
  origin, against goal 5's one implementation per component); a second firewall page in Gelişmiş;
  creating a missing volume silently on container creation (a removed volume would come back empty).
- **Amended by DD-269 (v2-253):** `GET /api/konsol/konteynerler/gunluk` is gone; an application's log is
  `uygulamalar/gunluk`.
- **Partly retired by the rebuild (DD-272, DD-274, DD-276):** the add flows (catalogue with install forms, an
  image, adoption), an application's Ayarlar tab, `uygulamalar/hesap` and `kur` (DD-272, DD-274), Gelişmiş's
  create and remove actions, `konteynerler/ayrinti|islem`, `ayarlar/klasorler` and Görünüm (DD-276) are gone;
  Sistem, the routes moved into the table, the copy button, the leave guard and the workers' lock wait hold.
- **Amended by DD-279 (v2-264):** leaving Uygulama ekle, now a page of its own, with something entered asks
  inside Konsol too, not only when the tab closes.

### DD-265: The redesign's third phase: Erişim, the Yayınla flow and the settings plan (v2-248)

- **Request (user, 2026-10-15):** "faz 3'e başlayalım" (phase 3 of DD-258, [`archive/redesign.md`](archive/redesign.md)).
  Choices: Yayınla works from both channels as the current Konsol does; a Konsol container with no
  loopback port is published in two steps in order; a WireGuard network's name can be changed
  afterwards; the WireGuard functions stay as they are.
- **`POST /api/konsol/ayarlar/plan`, the dry run:** `Manager.prepare` now holds every check `apply`
  makes (revision, no pending change, validation, the Konsol name's DNS guard, the Caddyfile check for a
  domain change), and `plan` runs it on a copy of the request: no lock, pending file, timer, service or
  file is touched, and a check that fails is the same 400 `apply` would give. The answer lists each
  change with its before and after (firewall rules, local names and records, forwarding, the domain,
  each publication row), what restarts or reloads, the confirmation window (`onay_sn`: 0 for local
  names, records, forwarding and publications, 60 when the firewall changes, 300 for the domain) and warnings. It is
  `uygulanabilir: false` when a timed change is asked from the internet name (only Tailscale confirms,
  DD-195) or when the new firewall would cut the caller's own address off Caddy or DNS
  (`client_blocked`, the check `onayla` already made). The page shows this plan before every write.
- **`ayarlar/uygula|onayla|geri-al|birak` and `konteynerler/islem`** move into the route table on the
  same workers, with their request shapes. `KonteynerIstegi` keeps `revision` optional so the current
  Podman page still works.
- **New reads:** `/api/konsol/guvenlik-duvari` (the operator's rules, the port catalogue, listeners,
  WireGuard networks, the technical rules and the firewall check; `yenile=1` reads again),
  `/api/konsol/adlar` (local names with their owner, records, forwarding and the domain) and
  `/api/konsol/yayinlar` (`panel/master_yayin.py`: every publication row and every Konsol container
  that could have one, with its guard text, the typed word for Konsol's own name and why the internet
  name cannot be opened yet).
- **Yayınla (`POST /api/konsol/yayinlar/plan`):** four decisions (what, who, which name, the plan)
  become the requests the page then sends to the existing write routes. A publication row goes through
  the settings transaction. A Konsol container that listens on no `127.0.0.1` port first gets one
  through the container save job (DD-211), on the first free port of `YAYIN_PORT_ILK`–`YAYIN_PORT_SON`
  (62100–62899, `config/defaults.env`) that no definition, publication or listener holds; the row is
  then a manual address (DD-252) joined to the container by that port. The two steps run in order and
  are not one transaction (separate locks, revisions and rollbacks): when the second fails, the
  loopback port stays, which is harmless because it listens on this server only. A container managed
  outside Konsol without a loopback port is listed but cannot be chosen until it is adopted on the
  Podman page.
  Turning both names off keeps the row closed; "Kaldır" on Adresler deletes a manual address.
- **Erişim's warnings** name their row by its id and carry a fix target (`duzelt`: Yayınlar, the
  application, Tailscale); the Tailscale summary adds its name, version, addresses and the exit-node
  offer.
- **WireGuard network name:** `master-wg net-settings DNS REVİZYON [ETİKET]` and `/nets/<if>/ayarlar`
  (`label`) rename a network under the same revision and install lock (at most 64 bytes, no leading or
  trailing space, no control character); keys, profiles and the network's state are untouched. Adding
  a network now refreshes the settings view, so the firewall and Erişim pages see it at once.
- **The new interface's Erişim section:** Genel (warnings with "Düzelt", the Tailscale, internet,
  WireGuard and certificate cards, the who-reaches-what matrix with its technical detail), Adresler
  (publications, local names and records, forwarding, the local domain), Tailscale, WireGuard (the
  networks, devices, QR and profiles through the package's own API, network settings with the name)
  and Güvenlik duvarı (rules by network and family as a draft, reviewed in the plan sheet, the
  listeners and the technical rules). Yayınla opens from every row and from the section's button
  (`?yayinla=<id>|sec|yeni`). Every write shows the plan, then applies; a timed change ends in the
  shell's pending-change banner with its countdown and Onayla/Geri al. The section's state is in the
  address (`sekme`, `teknik`, `kapsam`, `aile`, `kurallar`, `ag`, `yayinla`).
- **Live check (test host, v2-248):** every Erişim tab loaded with no console error; a Tailscale port
  rule went through draft, plan, apply, the 60-second confirmation and removal; a port-less Konsol
  container was published on the tailnet in two steps (loopback port 62100, then the name, which then
  answered from a tailnet device), unpublished and its address removed; WireGuard was installed, its
  first network created, a test device added and deleted, the network renamed (the name shown in the
  registry, the matrix, the firewall page and the current Konsol's WireGuard page) and removed, and the
  package removed again.
- **Rejected:** one transaction across the container broker and the settings transaction (two lock
  and rollback models for a gain the harmless loopback port does not need); a plan that writes a
  candidate file; offering Yayınla for a container the operator manages by hand; renaming a network by
  deleting and adding it again (new keys and profiles for every device).
- **Amended by DD-267 (v2-250):** the Podman page is gone; a container managed outside Konsol is adopted
  through Uygulamalar' add flow (DD-266) before Yayınla can choose it.
- **Partly retired by DD-275 (v2-258, the rebuild):** Yayınla and `/api/konsol/yayinlar` are gone; every
  access change is a row's settings plan. The plan itself (DD-156's dry run) stays, and so do
  `/guvenlik-duvari`, `/adlar`, Erişim's warnings with their fix target and the WireGuard network's name.
- **Amended in v2-269:** Genel's matrix shows each cell's addresses and ports, or its state in one word, with
  its state (or a warning: a raw port on the internet, unencrypted WebDAV) as a colour; the technical detail with
  its `teknik` address key, the WireGuard note under the table and the explanatory sentences in the cells are
  gone (the operator asked for the addresses and ports without explanations). The read model's rows no longer
  carry `ayrinti`, `ozet.wireguard` has no `not`, and a cell's `not` is set only when it is `hata`, the reason
  that also becomes the warning; an operator rule's row says "İzin kuralı" or "Engelleme kuralı".

### DD-263: Container CPU and memory come from cgroup files, not `podman stats` (v2-246)

- **Report (nrm, 2026-10-13):** Konsol's Podman inventory never showed CPU or memory; every listing
  carried `resource_errors.stats` and null numbers, and `/api/konsol/uygulamalar` inherited the gap.
  `master-panel.service` runs with `RestrictNamespaces=yes`, and `podman stats` switches into each
  container's network namespace to read its network counters: "error switching to ns
  /run/netns/netns-…: operation not permitted", exit 125. A transient unit with the backend's
  properties reproduces it; without `RestrictNamespaces` the same command works.
- **Now:** for a running container the backend takes `State.CgroupPath` from the `podman inspect` it
  already runs and reads `memory.current`, `memory.stat` and `cpu.stat` in that cgroup v2 directory.
  No namespace is entered and no command is added; `ProtectControlGroups=yes` leaves `/sys/fs/cgroup`
  readable. The sandbox is unchanged: relaxing `RestrictNamespaces` would let the root backend, which
  also loads package modules, create and enter namespaces only to show two numbers.
- **The path is checked before any read:** absolute, at most 1024 characters, plain parts of
  unit-name characters (no empty, `.` or `..` part), and the last part must carry the container's
  64-hex ID — `libpod-<id>.scope` for `podman run`, `libpod-payload-<id>` inside a quadlet unit's
  cgroup (`--cgroups=split`), both seen on nrm — so a slice, a unit or the root cgroup is never shown
  as the container's. Files are read with `read_regular`: every directory opened without following a
  symlink, a regular file, a bounded read.
- **Memory** is `memory.current` less `memory.stat`'s `inactive_file`, the figure `docker stats`
  shows (Podman 5.4 shows only `anon`). `memory.current` alone counts file cache the kernel drops at
  once: a probe that had read a 64 MiB file showed 66 MiB against 48 KiB of process memory, and for
  qBittorrent the cache would make up most of the number.
- **CPU** is the percent of one core between two readings, as `podman stats` counts it: the
  long-lived `Service` keeps the last `usage_usec` and monotonic time per container run (its ID and
  start time), so the first reading is null and a restart, or a counter that went back, starts over.
  A reading less than two seconds after the last repeats its figure, so a list and a detail asked
  together agree; at most 256 readings are kept. `podman stats --no-stream` gave the average since the
  container started; with the page's ten-second refresh the figure is now the recent use.
- A running container whose files cannot be read keeps null numbers and is named in
  `resource_errors.stats` ("Kaynak kullanımı okunamadı: <ad>."); a first reading without a CPU figure
  is not an error. The detail (`ayrinti`) carries the same numbers; before, its nulls hid the list's
  numbers in the page's detail panel.
- **Amended by DD-276 (v2-259, the rebuild):** `konteynerler/ayrinti` is gone; the same figures feed
  Uygulamalar and an application's page.

### DD-261: The redesign's second phase: Genel Bakış, Uygulamalar and the application page (v2-245)

- **Request (user, 2026-10-13):** "faz 2 ye başlayalım o zaman. adres kısmını tam anlamamışım" (phase 2
  of DD-258, [`archive/redesign.md`](archive/redesign.md)).
- **`GET /api/konsol/uygulamalar` (`panel/master_uygulamalar.py`):** every application in one list:
  App Store packages, Konsol's own containers and the built-ins (Files, WebDAV). Each has its state
  (`calisiyor`, `durduruldu`, `islemde`, `hata`, `bilinmiyor`), a running operation, its Tailscale and
  internet cells from the Erişim read model (DD-259), CPU and memory from the Podman inventory, the
  image update state, its addresses, the current interface's page (`#/torrent`) while the new one has
  none, the actions it accepts and the revision a change must carry. A package also brings its own
  stop and removal words from its `konsol.json` (`metinler`: what stopping interrupts, what removal
  takes away, the data switch's label, what it deletes and what stays), so the new dialogs say what
  App Store said. The answer adds the catalogue of packages not installed, Podman's counts (images,
  unused images, units, networks) and `hatalar`: a source that cannot be read adds a line instead of
  failing the list. It joins what the backend already reads and changes nothing.
- **Image update state:** `guncel`, `yeni` and `denetlenemedi` come from DD-214's cached check;
  `bilinmiyor` is an image that can move but has not been checked yet, `sabit` one that cannot move.
  Only the Podman page asked for the check, so the list now starts it in a background thread when the
  cache is older than its six hours, at most once a minute; a request never waits for a registry.
- **`GET /api/konsol/uygulamalar/ayrinti?id=`** (one application with its container: image, network,
  user, ports, mounts, start time and restarts, plus its Erişim row) and **`GET
  /api/konsol/uygulamalar/gunluk?id=&satir=`** (the container's journal, or the package's own log).
- **`POST /api/konsol/uygulamalar/islem`, one action entry:** `{id, eylem, revizyon?, veri?}` with
  `baslat`, `durdur`, `yeniden-baslat`, `guncelle` and `kaldir`. Packages go to the store engine as from
  App Store (DD-149); containers and image updates go to the container worker with the revision (a
  stale one is 409, DD-211); built-ins refuse with 409. The answer is 202 with the operation's id when
  there is one.
- **Requests are checked too:** a table route may declare its request's shape, and the backend refuses
  another shape with 400 before the handler. `/api/konsol/ag` and `/api/konsol/onarim` (the report and
  starting a check or repair), which the overview reads, moved into the table unchanged.
- **The new interface's pages** replace the shell's links to the current Konsol for these views.
  Genel Bakış puts problems first: each failing health check with "Denetle ve onar" (asked first, then
  `{"kip": "onar"}`; locked on the internet name, as before) and each Erişim warning with "Düzelt";
  then the applications as cards with "Aç" and "Ayrıntı", the resources, the network (read every 5 s
  only while the page is shown) and the server's facts. Uygulamalar is a table with filters, search and
  the view in the address, the add panel (the catalogue opens App Store, an image or an existing
  container the Podman page, for now) and Podman's counts. An application's page has its actions,
  each asked first where it stops or changes something (removal needs the typed `onayla` and offers
  the package's data switch with its own words), and the tabs Özet, Erişim, Depolama, Ayarlar and
  Günlük in the address (`sekme`, `teknik`, `canli`). "Aç" prefers the address of the channel the
  page is on and falls back to the other. Files is left out of these lists: Dosyalar is its own
  section. The shell's counts and palette read the new list instead of `moduller`. One Vue component
  per kind (status pill, tabs, dialog and sheet with a focus trap, typed confirmation, card, empty
  state, usage bar).
- **The address:** the current Konsol stays at `/` until phase 4; its sidebar footer now links to
  `/yeni/` ("Yeni arayüzü dene") on both channels.
- **Resources:** CPU and memory come from the Podman inventory, which reads each container's cgroup
  files since DD-263 (v2-246); before that, `podman stats` could not run in the hardened backend
  (`RestrictNamespaces=yes`) and the list had none.
- **Rejected:** separate action routes per kind of application (the page would have to know which
  manager owns an application); waiting for the registry inside the list request; widening
  `RestrictNamespaces` for `podman stats`; general words in the removal dialog where the package says
  exactly what goes.
- **Amended by DD-267 (v2-250):** `Uygulama.sayfa` (the old interface's page) and the old sidebar's link
  to `/yeni/` are gone; a built-in's "Aç" leads to its section (Files to Dosyalar, WebDAV to Dosyalar →
  Paylaşımlar).
- **Partly retired by the rebuild (DD-272, DD-274, DD-276):** `master_uygulamalar.py` (packages, the
  catalogue, built-ins, `ayrinti` and the one action entry) is gone: applications come from their records with
  their own routes (DD-274), on DD-276's pages. Request shapes checked from the table and the background
  image-update check hold.

### DD-260: Releases carry a semantic version beside the build number (v2-244, 1.0.0)

- **Request (user, 2026-10-13):** "Düzgün bir sürüm numarası verelim; v2-243 çok fazla ileri gitti ve
  çok major değişikliklere gidildi", with a tag and release notes; then "1.0.0", shown everywhere.
- **Decision:** `OBHUT_SURUM` in `install.sh` is the version people see, in semantic versioning. It
  changes only at a release, which is tagged `vX.Y.Z` and gets its `CHANGELOG.md` section and a
  GitHub release. `V2_VERSION` stays the build number: it rises with every behavioural change and is
  what servers compare when Konsol offers an update. 1.0.0 is the first tagged release under the
  name Obhut; builds v2-145 to v2-244 make it up.
- **Why two numbers:** every installed server's update check (`master_update.number`),
  `master-guncelle` and `kur.sh` accept only the `YYYY.MM.DD-v2-<n>` build string. Replacing it would
  leave each of them without an update offer, or need a bridge release first. With the build number
  deciding, a commit without the new line is offered as before, and a newer release name on an older
  build is never offered.
- **Where it shows:** Konsol's version fact (the build number in its title), the update button and its
  confirmation, the new interface's sidebar, the installer's first and last lines and
  `master-panel check`. `/api/konsol/kaynaklar` gains `surum`; `/api/konsol/guncelleme` gains
  `kurulu_surum` and `son_surum` (read from the offered commit's `install.sh`; null when absent). The
  identity checks stay on the build number (`master-wg version` against `wireguard.command`, the Files
  backend's `--version`).
- **Rejected:** switching `V2_VERSION` itself to semantic versioning (strands installed servers);
  2.0.0 or 3.0.0 (the user chose 1.0.0).

### DD-259: The redesign's first phase: route table, Erişim read model, live events, the shell at /yeni/ (v2-243)

- **Request (user, 2026-10-13):** "commit ve push et, faz 1 geçelim tasarım onaylıyorum" (phase 1 of
  DD-258, [`archive/redesign.md`](archive/redesign.md)).
- **Route table (`panel/master_api.py`):** the new interface's routes with the shape of each reply (a
  subset of JSON Schema). The backend dispatches them from the table; tests check real replies against
  the shapes and generate the OpenAPI description (`docs/konsol-api.json`) and the interface's
  TypeScript types (`tools/konsol-ui/src/api/sema.ts`) from it; a stale committed copy fails. Routes
  that predate the table stay where they are until their page moves; `kaynaklar`, `saglik`, `moduller`
  and `guncelleme`, which the shell reads, moved into it unchanged.
- **`GET /api/konsol/erisim` (`panel/master_erisim.py`):** one view of who reaches which service from
  where, projected from what the backend already reads: the publication table, folder share policies,
  container port scopes (`Inventory.reach()`, one `podman ps`; the container guard admits exactly
  these, DD-217), the packages' VPN networks, the port catalogue and the operator's rules. Each service
  has four cells (this server, Tailscale, WireGuard, internet): open, partly open (a package's peer
  port while its interface is not published), closed, not applicable, or switched on but not working.
  WireGuard cells are closed by design: VPN networks lead only to the internet (DD-177). A manual
  address (DD-252) joins the container whose loopback port it leads to. Warnings: WebDAV over the
  internet in plain HTTP, a container port published straight on the WAN, an unknown publication
  address, a publication that is on but not working, Tailscale disconnected, a certificate within
  14 days. It changes nothing and probes nothing new: a manual address row now carries the
  `answers` result its status already computed. A source that cannot be read adds a line to
  `hatalar` instead of failing the view.
- **`GET /api/konsol/olaylar` (`panel/master_olaylar.py`), Server-Sent Events:** one producer runs
  while any stream is open and publishes a topic again only when it changed: `kaynaklar` (a new
  sample), `bekleyen` (each second while a change is pending), `islemler` (2 s: App Store progress
  lines, container operation records, the update and the repair, kept 120 s after they end) and
  `saglik` (60 s, in its own thread because it runs the firewall check). A 15 s heartbeat stays well
  inside the 180 s socket timeout (DD-257); a stream ends after 10 minutes (`kapat`, `sure`) and the
  page reconnects; on the internet site the publication and the session are asked again every 30 s
  (`kapat`, `oturum`), since Caddy asked only when the stream began (DD-194). At most 4 streams per
  channel: Caddy keeps 16 connections per site to the backend and the rest stay for requests; a fifth
  gets 503 and the page polls `kaynaklar`, `saglik`, `etkinlik` and `bekleyen`. Caddy does not
  compress the stream (`@sikistir`), so small events are not held back.
- **The page reads the stream with `fetch`, not `EventSource`:** `EventSource` cannot send the
  `X-Konsol` header, and the CSRF gate (DD-180) keeps no exception.
- **The shell (`tools/konsol-ui` → `console/yeni/`):** Vue 3 + TypeScript + Vite with exact pins and no
  install scripts; the build is committed and `console/yeni/kaynak.sha256` (the digest of the sources,
  recomputed by `kaynak-ozeti.sh` with POSIX tools) ties it to them. It has the sections, the palette,
  the problem count, the activity drawer, the pending-change banner, the theme and the phone bar; its
  pages open the current Konsol. The installer places only web files (no hidden ones) and removes what an
  older build left; the CSP gains `font-src 'self'` for the local Outfit font (OFL).
- **Sign-in keeps the interface:** `/yeni/` paths, and the sign-in page asked with `?geri=yeni` (the only
  value it takes, never an address), return to `/yeni/` with the same view; everything else returns to
  `/` as before.
- **Rejected:** an `X-Konsol` exception for the stream; one producer per stream (cost grows with
  tabs); building the reachability view in the browser from five endpoints (the same rules in two
  languages); reading the container guard's nft state in this view (phase 3, with the plan endpoint).
- **Amended by DD-267 (v2-250):** the interface is at `/`: the sign-in page and the session check
  return to `/`, `geri=yeni` is gone and the installer places the build at the console's root.
  Nearly every route is in the table now; outside it the backend keeps only the session check, the
  sign-in POST and the packages' own APIs.
- **Partly retired by the rebuild (DD-272, DD-275):** `moduller` and the packages' VPN networks are gone
  (WireGuard is built in, DD-272); the Erişim read model projects the access rows instead of container port
  scopes and manual addresses (DD-275), and `islemler` carries no App Store lines. The route table, the
  generated types, the event stream and its limits hold.

### DD-258: Konsol is redesigned around tasks, with Gezgin as its file application (accepted 2026-10-13)

- **Request (user, 2026-10-13):** "konsolun çalışma mantığını … daha öncesini bilmiyor gibi incele;
  kullanıcı arayüzü ve görünümleri tamamen değiştirmek, daha kullanışlı bir biçime geçmek istiyor …
  akışkan bir menü tasarımı … hangi yapıları önerirsin". After the review: "önerileri kabul ediyorum
  başlayabilirsin".
- **Decision:** the plan in [`archive/redesign.md`](archive/redesign.md). Navigation by task (Genel Bakış, Uygulamalar,
  Erişim, Dosyalar, Sistem, Gelişmiş); one reachability view and a "Yayınla" flow; two save models; one
  component per kind; health first on the overview; view state in the URL. Backend stays standard-library
  Python, split behind a declared route table, with an exposure read model, Server-Sent Events and a
  dry-run plan. Frontend moves to Vue 3 + TypeScript + Vite (Gezgin's stack), built into committed
  static files under the same CSP. Gezgin becomes an App Store container package and the file
  application; Konsol keeps the root view and a rescue view; sharing moves to Gezgin after parity
  (dropped by DD-268: Konsol's shares stay, Gezgin shares its own content).
- **Built beside the current UI** at `/yeni/` and switched over when it covers every view, so the
  running panel never loses a feature mid-way.
- **Prototype (approved 2026-10-13, "tasarım onaylıyorum"):** a light work surface with the wallpaper
  only on the overview; the sidebar carries the Ôbhut wordmark, the server's name and counts on
  Uygulamalar, Erişim and Sistem; the top bar holds search (the palette), the problem count and the
  activity entry. WireGuard is Erişim's WireGuard tab: networks as tabs with "Ağ ekle", a network card
  with its on/off switch, the devices with on/off, QR, profile and details, and one side panel for
  adding a device, a device's DNS and keepalive, the network's label and default DNS, regenerating and
  removing (typed "onayla"). Every WireGuard function of today's page is kept; none is added.
- **Rejected:** Java (JVM footprint and dependency surface in a root process); keeping the no-build
  rule with Web Components (loses the shared stack with Gezgin); a single big-bang rewrite; framing
  Gezgin in Konsol or signing in through a trusted header (Gezgin removed proxy authentication on
  purpose).
- **Revisits, each in its own phase:** DD-159, DD-204, DD-212, DD-216, the no-build rule and the
  `contract.md` sections on the page set, the Settings tabs and the per-row publication save.
- **Amended by DD-267 (v2-250):** the switch happened in v2-250: the interface is at `/`, `/yeni/`
  redirects there and the old interface is gone (DD-267). Of the revisits listed here, DD-204 and DD-216
  are retired, DD-159 and DD-212 amended and `contract.md`'s page sections rewritten; sharing's move to
  Gezgin, planned for phase 5, was dropped by DD-268.
- **Partly retired by the rebuild (DD-272, DD-275):** Gezgin as an App Store package and the Yayınla flow are
  gone; the six sections, the Vue 3 + TypeScript build, the route table, the exposure read model, the event
  stream and the dry-run plan hold (`rebuild.md` 4.5).

### DD-257: Security and stability review after Gezgin (v2-241)

- **Request (user, 2026-10-12):** "paneli fonksiyonları güvenlik ve stabilite açısından incele
  göz at ve temizlik yapılması gereken yapıları tesbit et ve temizle". Five read-only reviews
  (root backend and sign-in; Files and folder shares; containers and App Store; installer and
  firewall; dead code and stale files). Every finding was checked in the code and against the
  DD entries before a change; each fix has a test that fails without it.
- **Firewall (DD-198 kept):** `load_package_rules` reads the declarations into a variable and exits
  when they fail. The `die` inside the process substitution used to end only that subshell, so the
  rules were written from a partial list.
- **qBittorrent settings:** `change()` restores only the files it snapshotted (a failed stop used
  to unlink the never-snapshotted profile) and stops an inactive unit without requiring success.
- **Root backend:** a body must arrive within `BODY_SECONDS` (30 s) in all, besides a 180 s
  per-operation socket timeout (above Caddy's two-minute keep-alive). A path with `.`, `..` or empty
  segments, also percent-encoded, is refused with 400 before routing: Caddy matches its routes and
  the session check on the cleaned path but passes the raw one on. `Panel.lock` was never used.
- **Files:** the trash is emptied and purged with `rmtree_onedev` on the trash's own device; a disk
  mounted inside a trashed folder answers 409. Upload writes loop over short writes.
- **Updates, repair, WireGuard:** `kur.sh` refuses to swap the tree while `install.lock` (path from
  `defaults.env`) is held; `master-onar` run from Konsol or a terminal waits up to 120 s for the
  hourly check's lock; `master_update` counts `http.client.HTTPException` as a failed check;
  `master-wg net` takes the install lock like every other writing verb (DD-229).
- **Cleanup:** the `.dav-summary`/`.dav-pair` styles (markup gone since v2-211), the unused
  `ports_of` import, the `pending` action of `master_settings.py`, the unreachable `--check`
  positional choice of `master_container_network.py`, the `RCLONE_VERSION` test fixture line, and
  stale text about the exporter and `<sürüm>.command`.
- **Not changed, for the operator:** retiring Konsol's Files module now that Gezgin exists
  (Gezgin K52); the archived docs, design mockups (they carry tailnet addresses of the test host)
  and the size of `SESSION.md`/`CHANGELOG.md`; `.cursor/rules` beside CLAUDE.md; the Files
  backend's loopback port answering any local process; the channel default when the header is
  missing (DD-195 keeps it); a container publication whose address is missing blocking every
  container's start (DD-223); App Store bind sources not pinned like DD-226's.
- **Partly retired by DD-272 (v2-255, the rebuild):** the firewall's package declarations and qBittorrent's
  settings worker are gone; the backend's body deadline and path refusal, the trash's one-device purge and the
  update, repair and WireGuard locks hold.

### DD-256: The Obhut mark is the letter O wearing a roof (v2-239)

- **Request (user, 2026-10-11):** "Bir logo ve simge tasarım öner", then "tasarımı baştan düşün ve
  basitleştirelim". Illustrative candidates (a birdhouse, a roof over a server with LEDs) lost
  their detail at 16 px and sat in the stock "roof over a thing" family of smart-home icons.
- **Decision:** the mark is "Ô": a ring and a detached chevron, two strokes of one weight
  (`console/obhut.svg`, viewBox 0 0 64 64: ring centre 32,41 radius 14.5, chevron 20,16 → 32,9 →
  44,16, stroke 7, round caps). It is the name itself: Turkish "şapkalı O", German *Hut* (hat;
  "O mit Hut"), English *hut*; the chevron is the roof, the ring the home. It is a letter, so it
  needs no explanation at favicon size, and it is also the first letter of the wordmark: the ring
  is Outfit SemiBold's O (0.72 em tall, stroke 19 % of the diameter, the same as the font's) and
  "bhut" follows in that face. The chevron is narrower than the ring (24 of 36 units) and 6 units
  clear of it; closing that gap or widening the chevron turns the mark back into a house.
- **Colour:** the SVG carries the Konsol accents (`#1F6F8B`, `#6FC3DC` under
  `prefers-color-scheme: dark`), so it adapts as a favicon and inside README. The PNG
  (`console/obhut.png`, 180 px, white mark on `#1F6F8B`) is the `apple-touch-icon`, because
  Safari ignores SVG icons.
- **Where it is used:** `<link rel="icon">` and `<link rel="apple-touch-icon">` on `index.html`
  and `giris.html`, served by Caddy with the other console files (CSP `img-src 'self'`); the
  README. Konsol's own name and sidebar wordmark are unchanged; Gezgin and the App Store keep
  their names.
- **Wordmark:** `docs/obhut-yazi.svg` is the mark followed by "bhut" as outlines taken from
  Outfit SemiBold (OFL; the font itself is not in the repository). The ring is scaled to the
  font's O (ink 725 units tall at 1000 per em) and "b" starts at the font's own O–b distance less
  the wordmark's −0.02 em letter-spacing, so the first letter is the mark and the rest is the
  typeface. The README shows this file. The sign-in page (v2-240) shows the same wordmark in
  place of its "Konsol." text, inline in `giris.html` so that `currentColor` follows Konsol's
  light/dark setting (an `<img>` would only follow the system's). Konsol's sidebar and mobile
  header (v2-242) show the same inline wordmark where they showed the server's name with the
  accent dot; the server's name and the panel address move to the small line under it
  ("<host> · panel.<domain>"), so the operator still sees which server this is.
- **Not done:** no PNG favicon set for browsers without SVG icon support beyond the touch icon.

### DD-255: The project is named Obhut; internal names stay (v2-238)

- **Request (user, 2026-10-11):** "Myserver projesine isim verelim"; among German candidates the user
  picked "Obhut güzel" (German for safekeeping, care) and approved renaming the repository and the
  names the operator sees, but not the internal ones.
- **Now:** the repository is `drs0me1/obhut`. `kur.sh`'s `repo`, `GUNCELLEME_REPO` in `defaults.env`
  and the documented install line follow it. The operator sees the name in `kur.sh`'s banner
  ("=== Obhut — kurulum ==="), the installer's first log line ("Obhut <version> başlıyor"), the
  `systemd-inhibit` reason, `README.md` and `OKUBENI.txt`. Konsol, Gezgin and the App Store keep
  their names.
- **Unchanged on purpose:** `/root/debian-server-installer`, `/etc/master-stack`, `/run/master-stack`,
  the `master-*` commands and units, the marker comments in generated files and the update check's
  `User-Agent`. Renaming them would migrate every installed host for nothing the operator sees.
- **Installed hosts:** `state.env` keeps the `GUNCELLEME_REPO` written by the last run. GitHub keeps a
  renamed repository's old name working: `api.github.com` answers 301 to the repository's id, which
  `urllib` follows, while `raw.githubusercontent.com` and `codeload.github.com` serve the content
  directly. A host with the old name therefore still finds and installs the next version, and that
  run writes the new name from `defaults.env`.
- **Constraint:** never create a repository named `myserver` under `drs0me1` again: it would take the
  old name over and break the redirect for hosts that have not updated yet and for old links.

### DD-254: A failed publication names its step and cause (v2-237)

- **Request (user, 2026-10-10):** "Asıl neden gösterilsin". Adding the Gezgin address in Settings →
  Caddy failed with only "WAN dinleyicisi/güvenlik duvarı uygulanamadı."; the cause (an operator's
  hand-made `gezgin-gecici.caddy` naming the same host, which Caddy rejects as "ambiguous site
  definition") had to be found on the server.
- **Now:** the share publisher records which step failed (writing the Caddy files, `caddy validate`,
  `master-firewall`, `systemctl reload caddy`) and the reason its tool printed: Caddy's `Error:` line,
  else its last error-level JSON log message, else the last plain line without the
  "[hh:mm:ss] HATA: " prefix, cut at 300 characters. For a failed reload of a running Caddy, systemctl
  says only that the job failed, so Caddy's own journal since the reload is read. The message is
  "WAN dinleyicisi/güvenlik duvarı uygulanamadı (<step>: <reason>); önceki yayın geri yüklendi.";
  rollback is unchanged. A folder share save that fails on the publication also names the cause.
- Reasons are Caddy's and the firewall's own text, shown only to the operator (Tailscale or the
  signed-in public Konsol); the Caddy configuration holds no credentials.

### DD-253: A Caddy repository outage does not stop a host that has Caddy (v2-236)

- **Report (user, 2026-10-10):** Konsol's update of `nrm` to v2-235 stopped in stage 1 with
  "env failed with exit status 1.". The log showed the cause: Caddy's apt repository on Cloudsmith
  answered `402 Payment Required` for every file (its bandwidth limit, a known recurring state that
  lasts until the limit rolls over), so `apt-get update` failed three times and the run died. The
  user chose to go on with a warning ("apt-get update çalıştırmadan devam edelim").
- **Now:** stage 1's refresh (and the RAR repository refresh) runs through
  `apt_update_caddy_tolerant`. When the refresh fails, Caddy is installed and every `E:` line names
  `CADDY_APT_REPO` (or is apt's generic "Some index files failed" line), the run goes on with the
  other lists and logs "Caddy deposu yanıt vermiyor (402 Payment Required); Caddy bu kez
  güncellenmeden devam ediliyor". Any other failing repository still stops the run; a host without
  Caddy still stops, because stage 6 installs Caddy from that repository. apt keeps the repository
  disabled (no `trusted=yes`, no relaxed signature check); Caddy keeps its installed version until
  the repository answers. The repository URL is `CADDY_APT_REPO` in `defaults.env` only.
- **Konsol's message:** `install.sh` runs under `systemd-inhibit … env bash install.sh`, which ends a
  failed run with "env failed with exit status N."; `master-guncelle` showed that last line. It now
  skips it and shows the installer's own last line.
- **Amended by DD-267 (v2-250):** the RAR repository refresh went with the RAR source (DD-267); a re-run
  deletes that source file before stage 1's refresh.

### DD-251: Container logs in full and unfiltered (v2-234)

- **Request (user, 2026-10-08):** after a filebrowser test container's first password could not be found
  in Günlük: "konsol içerisindeki günlük tam olarak gösterim sağlasın", then "konsol kontainer
  günlüklerini olduğu gibi almalı, herhangi bir filtre olmadan çalışmalı".
- **Two causes:** the log came from `podman logs`, which shows only the current container; a Konsol
  restart re-creates it, so the earlier run's lines (the generated password) were gone from the view
  although the journal kept them. And DD-208 replaced values after password/token/key words with
  "••••" before they left the server.
- **Now:** a Konsol definition (`konsol-<name>.service`) or an App Store container (its package unit)
  is read with `journalctl -u <unit> -n <tail> -o short-iso` whether the container is live or not, so
  the tail spans every start, restart and re-creation and also shows the unit's own start/stop lines.
  Any other container keeps `podman logs --timestamps`. No line is masked or otherwise changed; only
  blank lines are dropped. The `masked` field is gone from the answer.
- **Trade-off (flagged, the operator's choice):** what an application prints — temporary passwords,
  tokens — is shown to whoever opens the page, also over the public HTTPS name when that is on (it
  needs the Konsol account). Environment variables stay hidden as before (DD-208). Package pages'
  own logs (`master-modul gunluk`, e.g. qBittorrent's temporary password line) are not part of this.
- **Amended by the rebuild (DD-272, DD-274):** Konsol definitions, App Store containers and package logs are
  gone; an application's Günlük reads each service unit's journal the same way (`journalctl -u`), unmasked.

### DD-249: Files text editor (CodeMirror 6); saves as root in "Sistem (/)" (v2-231)

- **Request (user, 2026-10-07):** "dosyalar menüsünde sunucu erişimi tam erişim olarak ayarlayalım.
  salt okunur dosyalar da tam erişime sahip olsun" (clarified: the "Sistem (/)" view) and "dosyalarda
  tıklanan bir dosya text editör ile açabilir miyiz … filebrowser gibi". Of a plain built-in editor,
  a CodeMirror editor with syntax colours and the filebrowser application, the CodeMirror editor was
  chosen; mock-ups were shown first.
- **What "read-only" was:** the root view already runs with every capability (DD-235, DD-238); what
  made every existing file read-only was the backend rule that nothing overwrites. The editor's save
  is the one deliberate exception, narrowed to an existing regular text file of at most 1 MiB that has
  not changed since it was opened.
- **Bundle:** `console/duzenleyici.js` (~640 KB, ~230 KB compressed by Caddy) is built with esbuild
  from exact versions in `tools/duzenleyici` (`package.json`, `package-lock.json`, entry `giris.js`,
  `derle.mjs`; `npm ci && npm run derle` reproduces it byte for byte). `kur.sh` never copies `tools/`.
  The banner names every bundled package (all MIT; a non-MIT package stops the build) and carries the
  licence text; `common.bats` checks it against `package.json`. Konsol loads the bundle only when an
  editor opens. Not a CDN: the CSP allows `script-src 'self'` only, and the tailnet site must work
  without the internet.
- **CSP:** style-mod adds a `<style>` element to documents, which `style-src 'self'` refuses. The
  entry replaces `StyleModule.mount` with one constructed `CSSStyleSheet` kept in style-mod's module
  order (constructed sheets are CSSOM, not inline style). Konsol's colours come from `dosyalar.css`
  through the `classHighlighter` token classes; the search panel's words are Turkish phrases.
- **Save:** `version` is the SHA-256 of the bytes the editor got; the save re-reads the file and
  refuses another version (409). The temporary file `.konsol-kayit-<hex>` (short, so a 255-byte name
  still fits) is created `O_EXCL|O_NOFOLLOW` in the same folder, gets owner, group, mode and every
  extended attribute of the old file (a failure aborts: no silent loss of ACLs), is synced, the old
  file is compared once more (device, inode, size, mtime_ns) and the temporary file is renamed over
  it; the folder is synced. Line endings: CRLF if the old file had any, else LF; a UTF-8 BOM is kept.
- **Refused for editing (shown read-only with the reason):** over 1 MiB, not lossless in the chosen
  encoding, more than one hard link (a rename would split them), setuid/setgid (the root unit has
  `RestrictSUIDSGID`; such files are not text to edit anyway), and in `/srv` a file the downloads
  account does not own (it could not keep the owner). The root view may edit any of the rest.
- **Not chosen:** filebrowser as a package (its own login and root bind mounts beside Konsol's
  checks); writing in place (a crash mid-write would leave half a config file); a backup copy next
  to the file (it would litter `/etc`); a typed confirmation per save (the strip says root and no
  undo; Günlük records `duzenle`).
- **Also fixed:** the text view passed `null` to `replaceChildren` when the file was small, which
  printed a "null" line.
- **Amended by DD-267 (v2-250):** the editor is opened by Dosyalar' editor sheet in Sunucu klasörleri
  and Sistem dosyaları, which loads the bundle from `/duzenleyici.js` on the first file opened; its
  colours come from the new interface's `dosyalar.css` (`tools/konsol-ui`). The bundle and the save
  rules are unchanged.

### DD-248: "Sistem (/)" walks folder sizes on local disks, one device at a time (v2-230)

- **Request (user, 2026-10-07):** "dosya görünümünü sunucu kök dosyalarda da görelim": the DD-247
  "N öge · size" line in the root view as well.
- **Amends DD-235**, which listed "folder sizes are not walked" without its own rationale. The risks
  behind it are real: `/proc` alone is ~51,000 entries on `nrm` with `kcore` reporting terabytes,
  `/sys` another ~23,000, mounts inside a folder would be counted again, and a network mount can stall
  a listing. Measured on `nrm`: the whole root file system is ~57,000 entries and walks in about
  0.1 s, well inside the per-listing `WALK_BUDGET` of 200,000.
- **Rule:** `listing()` in `--sistem` mode reads `/proc/self/mountinfo` once (`local_devices()`) and
  keeps the devices whose type is in `LOCAL_FS` (ext2/3/4, xfs, btrfs, f2fs, jfs, reiserfs, zfs, vfat,
  exfat, ntfs, ntfs3, tmpfs). A folder whose own device is not in that set gets `size: null`; one that
  is gets `dir_size(..., dev)`, which skips every entry on another device (neither counted nor
  entered). So `/boot` excludes `/boot/efi`, `/var` excludes container overlays, `/run` excludes
  nested tmpfs and nsfs mounts. An unreadable mountinfo gives an empty set: no sizes, as before.
- **Unchanged:** the `/srv` view (`local` stays `None`, the walk is not limited to one device), the
  budget, the folder-only listing used by Taşı (no walk, no mountinfo read), the delete path.
- **Trade-off:** a few hundred milliseconds more per root-view listing on a busy host, as root, in
  exchange for the sizes; the per-listing budget still bounds it, and a folder past it shows only
  its count.

### DD-247: Folder tiles give the item count and the total size (v2-229)

- **Request (user, 2026-10-07):** "dosyalar menüsünde klasör görünümlerinin altında öğe sayısı yazıyor.
  toplam boyut bilgisi de yazalım"; of three mock-ups (one line, two lines, size first) the one-line
  "248 öge · 1,82 TB" was approved.
- **Why one line:** the details panel with nothing selected and "Çöpü boşalt" already say "N öge · size",
  and a second line would make folder tiles taller than the file tiles beside them.
- **Data:** no backend change. `/api/list` already walks each folder (`dir_size`, one `WALK_BUDGET` of
  200,000 entries per listing) and the list view's Boyut column shows it. A folder past the budget, an
  unreadable one and every folder in "Sistem (/)" (DD-235: sizes not walked) arrive with `size: null`.
  *(Amended by DD-248: "Sistem (/)" walks folders on local disk file systems.)*
- **Rendering:** `dirFacts` gives the tile's `.fx-sub`, its `aria-label` and the details' info line the
  same parts. The size is left out when it is `null` or the folder is empty: no "—" and no "0 B". Each
  part is a `nowrap` span, so a narrow tile wraps only at the "·".
- **Amended by DD-267 (v2-250):** the tiles are gone; Sunucu klasörleri and Depolama show each folder's
  item count and size from the same `/api/list` fields.

### DD-246: Reboot from Konsol; Sağlık in two rows; the settings guard timer is on demand (v2-228)

- **Request (user, 2026-10-07):** the health card in two rows "açıklamalar alta sığabilsin"; a restart
  trigger in Settings; "güncel denetimde zamanlayıcılar hata veriyor" (a screenshot showed
  "Yeniden açıldı: master-settings-guard.timer").
- **Timers:** DD-241 listed `master-settings-guard.timer` among the timers that must be enabled and
  waiting, but DD-181 runs it only while a settings change is pending (an idle guard stops it). Every
  Denetle reported it as stopped and every Onar started it again. `master-onar` now only requires it to be
  enabled (`ON_DEMAND_TIMERS`) and re-enables it without `--now`.
- **Reboot:** `POST /api/konsol/yeniden-baslat`, refused from the internet channel (403) and beside
  the update unit, the repair unit or a package operation (409); it runs `systemd-run
  --unit=master-yeniden-baslat --on-active=5 systemctl reboot`, so the answer reaches the page first,
  and logs `yeniden-baslat`. The button is in the "Panel ve sunucu" card's head; the confirmation
  needs the typed word "onayla".
- **Sağlık:** the checks split over `ceil(n/2)` columns (two to six), each detail wrapping under its
  name (at most three lines).
- **Amended by DD-267 (v2-250):** the reboot is Sistem → Sunucu's "Yeniden başlat" (the typed word,
  tailnet only; the page waits and loads itself again, DD-266); the Sağlık card layout went with the old
  interface. The route and the on-demand timer are unchanged.
- **Amended by DD-272 (v2-255, the rebuild):** with no packages, the reboot is refused beside an update or a
  repair only.

### DD-241: `master-onar` covers what the installer sets up; Sağlık shows the last run and a log (v2-223)

- **Request (user, 2026-10-07):** after a scope study, "A ve B yi kabul ediyorum"; the disk clean-up and
  `dpkg --configure -a` run inside Onar as proposed; instead of a nightly report the card shows the last
  check's time and a "Günlük" for the last 72 hours or the last week.
- **Repairs (A), each limited to what the installer itself set:** forwarding and buffers (`sysctl -p` of
  the installer's three files; still overridden → error naming the cause), Tailscale's exit-node and SSH
  flags (`tailscale set`, never a login), the installer's timers (`enable --now`), SSH (`ssh.socket` when
  that is how the host starts it), the clock (`systemd-timesyncd`), `tailscale-udp-gro`, Konsol split
  into its backend socket and the Caddy path (restart only the silent one), the Files backend's
  loopback port, the modes of `config.env`, `state.env`, the Konsol account folder and the repair and
  update logs (owner = the running root), disk (below `min(5 GiB, 10 %)`: `apt-get clean`,
  `journalctl --vacuum-size=200M`; never trash or user data; still low → reported), and half-configured
  packages (`dpkg --configure -a`; a held lock → "apt meşgul", not an error).
- **Reports only (B):** WAN IPv4 change (the fix is an installer re-run), `caddy validate` with the
  state values, `podman info` and the container guard's nft table, WireGuard peers without a
  handshake, a read-only `/` or user area, OOM kills in 24 h, `/run/reboot-required`, the node key
  under 14 days, an update left "calisiyor" by a vanished unit, a pending settings change. Report-only
  findings do not make a repair run fail.
- **Log:** every step line also goes to the journal (`SYSLOG_IDENTIFIER=master-onar`), plus a start and
  an end line; the hourly firewall check writes only findings. Units print to stdout only for a
  terminal so the journal has each line once. `GET /api/konsol/onarim/gunluk?sure=72s|7g` returns
  `journalctl -t master-onar -t refresh-tailnet-config` (3000 lines, 512 KiB at most) as text; the
  card's "Günlük" shows it in a dialog with 72 saat / 1 hafta. The card's head shows the last run's
  date and time and whether it came from SSH.
- `state.env` gains `CONFIG_FILE`, `SYSCTL_FORWARD_FILE`, `SYSCTL_NETBUF_FILE`, `SYSCTL_TCP_FILE` and
  `NET_BUF_FLOOR_BYTES` for these steps.
- **Amended by DD-267 (v2-250):** the log opens from Sistem → Sağlık as a sheet with 72 saat / 1 hafta
  (DD-266); the route and the steps are unchanged.

### DD-240: The address refresh also runs nightly between 03:00 and 04:00 (v2-222)

- **Request (user, 2026-10-07):** limit the former 5-minute service to once a day and after boots;
  "gece 3-4 arası uygun".
- `refresh-tailnet-config.timer`: `OnBootSec=2min` plus `OnCalendar=*-*-* 03:00:00` with
  `RandomizedDelaySec=55min` (always inside 03:00–03:55). No `Persistent=`: a night missed while the
  server was off is covered by the boot run. A changed Tailscale address is now picked up by the next
  night at the latest instead of only by a repair (DD-239's trade-off narrows to under a day).
- The hourly firewall check (`master-duvar-denetim.timer`) is unchanged.

### DD-239: Repair on request ("Denetle ve onar", `master-onar`) instead of a 5-minute loop (v2-221)

- **Request (user, 2026-10-07):** stop the round-the-clock service; run it from Ayarlar → Sağlık with one
  button, give it more repair capacity, and keep an SSH script for when Konsol cannot be reached. The
  plan, including the trade-offs below, was approved; the firewall keeps an hourly check
  ("security over convenience").
- **Schedule:** `refresh-tailnet-config.timer` keeps only `OnBootSec=2min` (once after boot); Caddy's
  `OnFailure` still starts it at once. The new `master-duvar-denetim.timer` runs `master-onar --duvar`
  hourly. Supersedes the "every 5 minutes" in DD-87/DD-94/DD-180/DD-182 and the old "do not shorten
  the timer" note.
- **`master-onar` (`panel/master_onar.py`, root):** seven fixed steps (firewall, tailscaled,
  Tailscale address via `refresh-tailnet-config`, base and running-package units, DNS, Konsol through
  Caddy, other failed units listed only). `--denetle` changes nothing. A lock allows one run; the
  report (`ONARIM_DURUM_FILE`, JSON, rewritten after every step) feeds Konsol; a terminal gets one
  line per step. It restarts only units that are not active and never rewrites configuration, so it
  stays an operator tool, not the reconcile engine contract §2 excludes.
- **Konsol:** `GET/POST /api/konsol/onarim`; the start is tailnet only, never beside a running update
  or another repair, and runs as its own unit (`ONARIM_UNIT`) because it may restart Caddy or Konsol.
  The Sağlık card shows "Denetle" (no confirmation) and "Onar" (confirmation), the steps live while it
  runs and the last report afterwards. Audit: `onarim <kip>`.
- **SSH:** `sudo master-onar` on the server; `onar.command` at the repository root does it from the
  Mac (reads only `SSH_HOST`, `sudo` when the SSH user is not root).
- **Trade-off:** a Tailscale address change (rare: the node re-registered) is no longer picked up
  within 5 minutes; Konsol stays unreachable on the tailnet until a repair over SSH. A flushed rule
  set stays open for up to an hour. In return nothing polls every 5 minutes.
- **Amended by DD-267 (v2-250):** "Denetle ve onar" is in Sistem → Sağlık and on Genel Bakış's problem
  list (DD-261, DD-266); the report, the unit and the tailnet-only start are unchanged.

### DD-238: "Sistem (/)" without read-only roots or the root warning strip (v2-220)

- **Request (user, 2026-10-07):** "Root olarak çalışıyorsunuz ibaresini kaldıralım. salt okunur dosyalara
  da admin tam erişim sağlasın."
- **Change:** the system view (DD-235) no longer refuses writes under `/proc`, `/sys`, `/dev` and
  `/run` (`SYSTEM_READONLY` and `check_writable` are gone, `/api/sistem/state` has no `readonly`), and
  the red "Root olarak çalışıyorsunuz…" strip is gone. The red lock on the sidebar entry and the
  delete confirmation (type the item's name; "Root olarak silinir…") stay.
- **What "full access" means here:** Konsol has no operation that writes into an existing file, so
  kernel settings under `/proc/sys` or `/sys` cannot be changed and a device under `/dev` cannot be
  overwritten from it. What opens is creating, renaming, moving and permanently deleting items there;
  the kernel still refuses most of that on `/proc` and `/sys` (EPERM/EROFS, shown as the error).
- **Trade-off (accepted by the administrator):** deleting or moving under `/run` (sockets, PID files,
  locks) or `/dev` (device nodes) can stop services or devices until they recreate them or the host
  reboots; a mount point or anything with a mount below it is still never deleted, and tailnet-only
  access, the separate root unit and the typed confirmation are unchanged.

### DD-235: Files' "Sistem (/)" view: the whole server as root, tailnet only (v2-214)

- **Request (user, 2026-10-06):** see the whole server in Files as root, read and write, over
  Tailscale. Decisions: delete is permanent and confirmed by typing the item's name; the key folders
  (`/etc/master-stack`, `/etc/wireguard`) stay open like everything else; then a clean install on `nrm`.
- **Reverses part of DD-139 on purpose.** DD-139 rejected "running as root with a path check: one
  missed case would expose the host". The `/srv` view keeps that rule unchanged (`master-files-panel`
  as the downloads account, `ProtectSystem=strict`). The root view is a **separate** unit,
  `master-sistem-dosya`, running the same code in `--sistem` mode with `--root /`, so a bug in the
  `/srv` view still cannot reach the host and the root view's exposure is one switchable unit.
- **Same core, fewer features.** Every path step is still an `O_NOFOLLOW` open from a directory
  descriptor (a symlink is listed, never followed: `/bin` shows as a link, `/usr/bin` is browsed) and
  nothing overwrites (`RENAME_NOREPLACE`). Differences:
  - No trash: `/` spans several file systems, a trash would turn deletes into copies. Delete is
    permanent: one item needs its own name typed, several need `onayla` (the existing bulk word).
  - Delete refuses a mount point or an item with anything mounted below it (`/proc/self/mountinfo`),
    and the recursive delete stops at a device change; a bind mount of the same disk would otherwise
    lose its source's files.
  - `/proc`, `/sys`, `/dev` and `/run` are listed but read-only; folder sizes are not walked.
    *(Amended by DD-238: no read-only roots, no warning strip. Amended by DD-248: sizes are walked on
    local disk file systems, one device at a time.)*
  - New folders are `0755`, uploads `0644` (root's), not the downloads tree's `0775/0664`.
  - No archives, shares or package-folder warnings (those belong to `/srv`).
- **Tailnet only, twice.** The unit listens on `SYSTEM_FILES_SOCKET` (0660 root:caddy, peer
  credentials checked) and no TCP port. Caddy routes `/api/sistem/*` only in the Tailscale site (a
  matcher whose expression compares the snippet's channel argument with `tailscale`; on the public
  HTTPS site the path falls to the files backend and gets 404). The backend itself refuses a request
  whose Caddy-written `X-Konsol-Kanal` is not `tailscale` or whose `X-Forwarded-For` is not another
  Tailscale device (DD-180's own-address check, duplicated in a few lines as DD-139 duplicated the
  login check). Stage 7 proves the socket mode, 200 for a tailnet peer, 403 for the internet channel
  and for the server's own address, and 403 through Caddy from the downloads account.
- **Audit:** writes and downloads are logged as `dosya: sistem <address> ...`; Günlük also reads
  this unit's journal. The health card lists the unit.
- **Trade-off (security over convenience, flagged):** Konsol asks no sign-in on the tailnet (DD-205),
  so every device on the tailnet now has root file access, including `/etc/shadow` and private keys.
  Tailscale's ACLs are the boundary, as they already are for the rest of Konsol. The unit has no
  `ProtectSystem`/`ProtectHome`/`PrivateTmp`/`PrivateDevices` by design; it keeps
  `NoNewPrivileges`, `RestrictSUIDSGID`, `IPAddressDeny=any` and no listening port.
- **Not done:** no text editor, no copy, no chmod/chown, no archive jobs in the root view.
  *(Amended by DD-249: a text editor in both views.)*
- **Amended by DD-267 (v2-250):** the view is Dosyalar → Sistem dosyaları (`#/dosyalar?sekme=sistem`),
  shown on the tailnet only, beside Sunucu klasörleri for `/srv`; a delete still needs the item's own
  name (or `onayla` for several). The unit, the socket and the channel checks are unchanged.

### DD-233: Konsol update button, pinned to a GitHub commit (v2-212)

- **Request (user, 2026-10-05):** "ana menüde saat ve tarih satırının hemen yanına bir Güncelle
  butonu ekleyelim. githubda güncel versiyon gelince sunucu güncellemeyi görsün ve tıklayınca
  güncelleme yapabilsin".
- **Check:** the root backend (`master_update.py`) asks `api.github.com` for the tip commit of
  `GUNCELLEME_DAL` (one short request, the plain SHA) and reads `V2_VERSION` from that commit's
  `Data/install.sh` on `raw.githubusercontent.com`. Only `YYYY.MM.DD-v2-<n>` counts; the offer is
  a higher `<n>` than the installed state. Six-hour cache, 15 minutes after a failure, "Güncel"
  re-checks at most once a minute: the unauthenticated GitHub API allows 60 requests an hour.
- **Pinned:** the page sends back the commit and version it showed; the backend starts only that
  pair, `master-guncelle` downloads `kur.sh` from that commit, and `kur.sh` refuses an archive
  whose `V2_VERSION` differs. A push between the click and the download never installs unseen code.
- **Unattended re-run, narrowly:** the contract's TTY requirement stays for every terminal run. The
  update runs as its own transient unit (`GUNCELLEME_UNIT`), because the installer restarts Konsol
  and Caddy, and runs `install.sh` with `V2_GUNCELLEME=1`. That mode refuses what needs a person
  at a terminal: a first install (no domain) and a Tailscale login link.
- **Who may start it:** a Tailscale device (or root on the socket). The public HTTPS Konsol sees the
  offer but cannot start it: it runs root code fetched from GitHub, the same trust as the curl line,
  so it stays behind the device check rather than a password alone. Not beside a package operation,
  a pending settings change or another update.
- **Progress:** the unit writes `GUNCELLEME_DURUM_FILE` (running/done/failed, target, last output
  line) and its output to `GUNCELLEME_LOG_FILE` (0600); Konsol shows the latest "Aşama n/7" and,
  after a finished run, reloads the page once because its own files changed. A run that vanished
  (reboot) reads as failed. Audit: `guncelleme <version>`.
- **Not done:** no automatic update, no rollback (Git keeps every version; `KUR_REF` installs an older
  commit from the terminal), no authenticated GitHub access.
- **Trade-off:** convenience against the TTY rule; kept small by the pin, the device check and the
  refusals. A server below v2-212 needs one terminal run to get the button.
- **Amended by DD-267 (v2-250):** the button is in Sistem → Güncellemeler (DD-266), which follows the
  run in the activity list and reloads the page when it ends well; the check, the pin and the unattended
  re-run are unchanged.
- **Amended by DD-272 (v2-255, the rebuild):** with no packages, the start is refused beside a pending
  settings change or another update only.
- **Amended by DD-277 (v2-260):** the check also reads the newest commit's generation (`OBHUT_NESIL`,
  absent = 1); another generation is shown as a clean-install notice instead of an offer, the start refuses
  it, and `master-guncelle` refuses a target of another generation before it fetches `kur.sh`.

### DD-229: Overview controls, WireGuard as a whole, and a host closed to containers (v2-207)

- **Request (user, 2026-10-05):** "düzenle seçeneğini ekranın sağ en altına alalım", "wireguard
  kartının altına da durdur başlat ekleyelim. durdurma tüm wireguard fonksiyonunu durdurabilelim",
  "durdur/başlat yazı olarak yazsın, ayarlar için dişli çark simgesi, log için de konsol-terminal
  simgesi", "dosyalar sayfasındaki kartlar görünümünü kaldıralım. liste görünümü default olsun",
  "podman ağ yönetimini denetleyelim … kontainer içerisinden sunucu içerisine erişimi tamamen
  kapatalım."
- **Overview:** "Düzenle" is fixed to the screen's bottom-right corner (supersedes DD-213's
  bottom-left sticky pill); the overview keeps 72 px below the last row so it never covers a tile
  once scrolled. The tile actions read "Durdur"/"Başlat" as text, settings is a gear, logs a
  terminal icon. Files has one list view; the card switch and its browser-storage key are gone.
- **WireGuard stops as a whole:** `PAKET_DURDURULABILIR=1`. `paket_durdur` first writes the list
  of enabled `wg-quick@wgN` units to `WG_STOPPED_FILE` (kept on a repeated stop), disables them,
  marks the package `durduruldu` and reapplies the firewall, which reads only `calisiyor`
  packages: WireGuard's UDP ports, forwarding and NAT disappear. Disabled units keep it down at
  boot; `paket_uygula` leaves a stopped WireGuard down on installer re-runs; `master-wg` refuses
  `net ac` and `net-add` while the file exists. `paket_baslat` applies the firewall first, then
  reopens only the recorded networks (a network closed on its own stays closed; one deleted while
  stopped is skipped) and removes the file. Removal deletes the file too. The installer's final
  check (`paket_denetle`) skips the interfaces of a stopped WireGuard and of a network closed on
  its own (v2-209; v2-207/208 stopped an installer run on a stopped WireGuard).
- **Audit of container networking (what was already in place):** generic containers cannot use
  host networking or the default `podman` network; bridges are IPv4; the forward guard (DD-224)
  blocks the tailnet, VPN ranges, private/CGNAT/link-local/loopback destinations and IPv6, and
  lets in only the declared publications; MASTER-INPUT accepts only DNS on the bridge's own
  address from container bridges and drops the rest.
- **Gap and fix:** traffic a container opens to the host's own addresses takes the input hook,
  which only MASTER-INPUT guarded. Chains before it in INPUT (Tailscale's `ts-input` accepts its
  UDP port from any interface) and any moment MASTER-INPUT is missing (boot order, a failed
  firewall run) left host services reachable from a container. The project's nft table now has
  an `input` chain at priority -10: anything from a `ksl*` bridge is dropped except replies to
  host-opened connections (`ct direction reply`, established/related; host → published port
  still works) and TCP/UDP 53 to an address of the incoming bridge itself (`fib daddr . iif type
  local`, so 127.0.0.1 via `route_localnet` does not count). Aardvark DNS is the one deliberate
  exception: without it containers cannot resolve names. The same health check (exact rule
  comparison) covers the new chain, and container units still start only behind it (DD-223).
  The namespace test shows the old guard let a container reach a host listener on the bridge
  gateway; the new one refuses every host address.
- **Amended by DD-267 (v2-250):** the overview controls (the fixed Düzenle, the tiles' action words and
  icons) and Files' list view went with the old interface. WireGuard's stop as a whole
  (`PAKET_DURDURULABILIR=1`, `WG_STOPPED_FILE`) and the host closed to containers (the nft `input`
  chain) are unchanged.
- **Amended by DD-272 (v2-255, the rebuild):** WireGuard is a built-in: `master-wg durdur` and `baslat` stop
  and start it as a whole through `WG_STOPPED_FILE`, without `PAKET_DURDURULABILIR` or `paket_*` hooks, and
  the firewall reads the marker itself.

### DD-228: Install from the public repository with one curl line on the server (v2-206)

- **Request (user, 2026-10-05):** "repoyu public yapalım. kurulumun ssh bağlantısı yapması
  adımlarını çıkaralım. kurulum direkt server upgrade ve kurulum yapmaya başlasın. curl ile linki
  çekeriz." The repository moved to the public `drs0me1/myserver` (current tree only; host
  addresses and domains in the docs replaced with documentation examples).
- **Decision:** the operator SSHes in and runs
  `curl -fsSL https://raw.githubusercontent.com/drs0me1/myserver/main/kur.sh | sudo bash`.
  `kur.sh` downloads the GitHub archive of `main` (or `KUR_REF`), copies only the runtime tree
  to `/root/debian-server-installer` with the launcher's atomic swap, and `exec`s `install.sh`
  with `/dev/tty` as stdin. The body sits in `main()` so a truncated download runs nothing.
  *(Amended by DD-255: the repository is now `drs0me1/obhut`; the old name redirects.)*
- **Retired with it:** the portable `.command` and its exporter (DD-154's "one current
  export"), the input file's transport to `/run` and `read_input_file` (DD-119). The only
  input left, the local domain, has no default (user's choice: "default bir değer
  oluşturmayalım"): a first install asks in stage 0 until the answer is a valid label;
  re-runs keep the Konsol-confirmed (DD-157) or previous name without asking, and Konsol →
  Ayarlar changes it. `DEFAULT_LOCAL_DOMAIN` is gone from `defaults.env`.
  `kurulum/kurulum.env` remains only as `wireguard.command`'s `SSH_HOST`.
- **Full-upgrade on every run** (user's choice): the re-run question and `V2_FULL_UPGRADE`
  are gone; re-runs take longer.
- **Trade-offs:** integrity rests on HTTPS to GitHub and on who can push to `main`; there is
  no embedded SHA-256 to compare. `kur.sh` prints the archive's SHA-256, and `KUR_REF` pins a
  commit. Every push to `main` reaches the next install, so `main` must stay installable.
- **Amended by the rebuild (phase 6):** the install folder is fixed (`KUR_ROOT`, used only by tests, is
  gone; the Bats tests run a copy of `kur.sh` with the folder replaced). `KUR_URL` stays as the operator's
  way to install a tree not yet on GitHub as an archive (`https://` or a `file://` path on the server,
  `rebuild.md` section 7.5); unset, the GitHub archive of `KUR_REF` is downloaded.

### DD-227: Writable server folders only through the Files account (v2-205)

- **Finding (measured on nrm, 2026-10-05):** a generic container ran as its image's user. For alpine
  that was root, with 11 effective capabilities (`podman inspect`). Podman is rootful without user
  namespaces (DD-208/209), so such a container, or an exploit in it, was host root over every writable
  `/srv` bind. It could chown or plant setuid files, and leave root-owned files that the installer's
  repair walk would silently fix. DD-226 closed the path swap; this closes the privilege.
- **Decision:** a definition carries `user`: `downloads` or `image`.
  - `downloads` renders `User=`/`Group=` from the state's `DOWNLOADS_UID`/`GID`, which must be digits
    and non-zero, else 503. It also renders `DropCapability=all` and a fixed `--umask=0002`, because
    `/srv` is 0775/0664 by the repair walk. `NoNewPrivileges` stays.
  - `validate()` refuses `image` together with any writable bind, before any pull or stop: "Sunucu
    klasörüne yalnız Dosyalar hesabıyla yazılabilir…".
  - After each start the worker proves the account: `Config.User` is `uid:gid`, and the effective and
    bounding capability sets are empty. Podman 5.4.2 prints an empty set as `null`, others may print
    `[]`; both count. A missing field fails closed.
  - A new definition defaults to `downloads`. An omitted value on save keeps the stored one. A
    definition stored before this counts as `image` and keeps running unchanged; it needs the switch
    only when it is saved with a writable folder.
  - Adoption maps the Files uid to `downloads`.
  - The Podman page has "Çalıştıran hesap" (Dosyalar preselected on create), blocks the review until
    the rule holds, and lists the change with its consequences. Details show the running user.
- **Rejected:**
  - An acknowledgement path for root images on writable folders: one preserved boolean is weaker than
    the per-port public acknowledgement. Root-init images that must write `/srv` (LSIO style) belong in
    App Store packages, which have a reviewed home.
  - User namespaces (`UserNS=auto`): they change `/etc/subuid`/`subgid`, and Ubuntu is unverified.
- **Consequences:**
  - Podman sets a named volume's owner once, at its first use (measured on nrm). A new volume at a path
    the image lacks becomes the Files account's. Over an image directory it takes that directory's owner,
    and a volume used before keeps its owner. Either may be root-owned and so read-only for the Files
    account.
  - Images that need root or a port below 1024 may not start under it. The UI says so.
  - qBittorrent's own LSIO image is out of scope.
- **Amended by DD-267 (v2-250):** the account choice ("Çalıştıran hesap") is in the new interface's
  container forms: creating from an image, adoption and the definition editor on the application's
  Ayarlar tab (DD-266).
- **Amended by DD-274 (v2-257, the rebuild):** applications replace definitions; their start mode is the
  operator's answer per container (A4). A root start may have a writable `/srv` folder, with a warning in
  the inspector, the edit plan and the application page: the operator chose this over the rejected
  acknowledgement path (2026-10-17). A direct start as the Files account keeps `--umask=0002`.

### DD-226: A Konsol container's bind sources are pinned at every start (v2-204)

- **Finding (measured on nrm, 2026-10-05):**
  - A temporary alpine Quadlet bound `/srv/bindsrc-test/data` read-only.
  - Acting as uid 1000, the test renamed the folder and left a symbolic link to a root-only
    directory in its place.
  - At the next `systemctl start` the container listed the root-only canary file.
  - `podman inspect` still showed the old path.
  - Podman resolves `Volume=` sources by path at every start. Konsol validated them only when
    saving. Under `SERVER_ROOT`, which the downloads account writes, a uid-1000 compromise (Files,
    WebDAV, unrar, qBittorrent) plus any restart of a root generic container meant host root
    access through the bind.
- **Decision:** a base helper, `master_container_binds.py`, runs in each generated unit.
  - `ExecStartPre … bagla NAME SOURCE…` runs after the guard check. It walks each source from `/`
    component by component with `O_DIRECTORY|O_NOFOLLOW` and requires a directory. It checks that
    `/run`, `RUNTIME_DIR` and `KONTEYNER_BAGLAMA_DIR` are root-owned and writable by no one else,
    and releases stale anchors.
  - It then binds the descriptor (`/proc/self/fd/N`, `MS_BIND|MS_REC`, then `MS_PRIVATE`) onto
    `KONTEYNER_BAGLAMA_DIR/NAME/<sha256(index:source)[:16]>`. It verifies that the anchor is a
    mount point with the walked `(st_dev, st_ino)`. On any failure it releases what it pinned and
    the unit fails.
  - `ExecStopPost=-… birak NAME` detaches and removes only empty anchor folders, never data.
  - The Quadlet mounts the anchor, never the path. `RequiresMountsFor=` keeps the real folder as
    a mount dependency. Anchor names are deterministic, so refresh_tailnet's byte comparison holds.
  - Start-time checks are the base invariants only: absolute, no `..`, a non-hidden subfolder of
    `SERVER_ROOT`. Package-declared folders stay a save-time check, so no package code (or its
    uid-1000-owned report) can block an unrelated container at start. The helper takes no lock.
- **Limits:**
  - The pinned directory is the one the walk found. A folder swapped before the start is either
    refused (a link) or a different real folder that uid 1000 could have bound anyway.
  - App Store containers are out of scope: qBittorrent's `torrent_verify` compares the inspected
    source.
  - Existing Konsol containers get the new unit when saved, started from Konsol or re-rendered for
    Tailscale; there is no migration code.
- **Reverse direction:** a root container planting files in `/srv` is DD-227's subject.
- **Amended by DD-274 (v2-257, the rebuild):** the anchor key is the application's container name
  (`<app>_<service>`, at most 128 characters); application data folders under `UYGULAMA_VERI_DIR` are root's
  own and bound directly. The inspector refuses a `/srv` answer the anchors would refuse at start.

### DD-225: Packages' private state is hidden from the uid-1000 data units (v2-203)

- **Finding (measured on nrm, 2026-10-05):**
  - Inside WebDAV's mount namespace `.cop` is mode 000, but `/srv/.arsiv` (the archive staging
    area, 0700 uid 1000) is visible and accessible. The handler alone keeps it out.
  - `/var/lib/qbittorrent`, which holds the WebUI hash and tracker passkeys and is owned by uid
    1000, is readable from WebDAV's namespace as uid 1000, and so from Files and its unrar child.
  - Reads only: `ProtectSystem=strict`.
  - The pivot the hash once allowed is closed since DD-217. A sandboxed unit gets no answer from
    the loopback publication (measured), so this is a confidentiality leak of low severity.
- **Decision:**
  - New `defaults.env` key `PRIVATE_STATE_ROOT="/var/lib"`. The base names no application.
  - `master-paylasim.service` keeps exactly one `InaccessiblePaths=` line: trash, `.arsiv`,
    `-.pay` and `PRIVATE_STATE_ROOT`. A second assignment would reset the list. `.arsiv` has no
    `-`: the Files backend creates it at start, and a missing one keeps WebDAV down (fail closed).
  - WebDAV also gets `RequiresMountsFor=SERVER_ROOT`, like Files.
  - `master-files-panel.service` gets `InaccessiblePaths=PRIVATE_STATE_ROOT` only, because Files
    owns the trash, the staging area and the share name.
  - Package rule: a package's private host state lives under `PRIVATE_STATE_ROOT` or is
    root-only. qBittorrent (`/var/lib/qbittorrent`) and WireGuard (`/etc/wireguard`, 0600 root)
    already comply.
- **Rejected:**
  - A per-package manifest list of masked paths (`-` masks): a path created after the unit
    started stays visible (the DD-207 lesson), and keeping it right needs mountinfo-driven
    restarts.
  - `SystemCallErrorNumber=EPERM` on WebDAV: it weakens the SIGSYS default on the WAN-facing
    service.
- **Cost:** the next installer run restarts Files (a running archive job is marked interrupted)
  and WebDAV (open transfers are cut) once.
- **Amended by DD-267 (v2-250):** `.arsiv` left with the archive jobs: WebDAV's one `InaccessiblePaths=`
  line lists the trash, `-.pay` and `PRIVATE_STATE_ROOT`, and no unrar child runs.
- **Amended by the rebuild (DD-272, DD-274):** `-.pay` left WebDAV's line with the 1.x leftovers (DD-272), and
  the package rule is the base's: applications' data lives under `UYGULAMA_VERI_DIR`, inside
  `PRIVATE_STATE_ROOT` (DD-274).

### DD-224: Containers may reach the internet, not private or tailnet destinations (v2-202)

- **Finding:** no project layer filtered what a container opens itself. The guard's first rule
  returned every packet not entering a bridge. MASTER-FORWARD matches only WireGuard
  interfaces, and `VPN_BLOCK_DEST4` applied only to WireGuard clients.
- **Measured on nrm (2026-10-05)** from qBittorrent's network namespace:
  - internet by IP: reachable;
  - a tailnet peer: dropped by Tailscale's stateful filtering (`--stateful-filtering=true`,
    DD-74), while the host itself reaches it;
  - quad-100: dropped;
  - the metadata address: no answer; nrm has no private networks.

  So on nrm the change is defense in depth. On a home LAN, or with a provider that serves
  metadata, it closes real paths. It does not depend on a Tailscale flag.
- **Decision:** the guard keeps one rule for traffic that neither enters nor leaves a bridge
  (exit node, WireGuard), so that path still costs one rule (DD-181). Next come the existing
  reply returns, so replies to Tailscale and WAN publications pass. Then, for traffic that leaves
  a bridge for another interface:
  - IPv6 dropped (the bridges are IPv4-only);
  - anything out of `TAILSCALE_IF` dropped;
  - one rule per `VPN_BLOCK_DEST4` prefix, in list order, dropped.

  The list's single owner stays `defaults.env`, and no literal is repeated in the code. A missing,
  empty or invalid list fails closed with 503, so no guard is written and master-firewall reports
  it. Health stays an exact comparison, with one rule per prefix and no anonymous set that nft
  could merge or reorder.
- **Consequences:** a container can no longer reach a NAS or anything else on the LAN, the tailnet,
  or a provider's private network. Konsol's internal networks ("iç ağ") still give no egress at
  all. Internet exfiltration of mounted data stays possible for containers that need the internet;
  qBittorrent does.
- **Not done:** per-network egress modes (no workload needs them yet) and a TCP 25 block.

### DD-223: Container units wait for the checked guard, without Requires= (v2-201)

- **Finding (measured on nrm, 2026-10-05):**
  - qBittorrent's Quadlet had only `After=master-firewall.service`. With the container guard
    table deleted, `systemctl restart qbittorrent` started it anyway: `After=` orders a start,
    it does not hold one back when the firewall failed.
  - Konsol's generated units had `Requires=master-firewall.service` and an `ExecStartPre` that
    applied the guard. `systemctl restart master-firewall` restarted a running Konsol container
    (measured). Every restart source restarted them: a Tailscale upgrade (`PartOf`), a WireGuard
    network change, an installer run or a watchdog repair. A failed apply inside such a restart
    left them stopped.
  - The unit's own apply was an unlocked writer. It could re-open a publication the worker had
    just revoked.
- **Decision:**
  - Package and Konsol container units use `Wants=` + `After=master-firewall.service`, with no
    `Requires=`, `BindsTo=` or `PartOf=`.
  - Their `ExecStartPre` only checks the guard (`master_container_network.py --check`), and
    `RestartSec=10s` retries until it is in place. A container without a network gets no check.
  - Only the locked writers write the guard:
    - `master-firewall`, at boot and on every restart;
    - the package engine, after placing a quadlet;
    - the container and package workers, before a start that changes publications.
  - `check()` now names a missing table ("Konteyner yönlendirme koruması eksik veya güncel
    değil.") instead of a generic read error.
- **Trade-offs:**
  - A container waits until the firewall has applied the guard, retrying every 10 s with no start
    limit.
  - A crash-looping container also retries every 10 s, instead of stopping at the start limit.
  - qBittorrent's interface-port change restarts it without reapplying the guard. Loopback
    publications are not part of the policy, so its start check passes; a test pins this.
- **Not done:** a fail-closed bridge drop in the firewall's cold recovery, and listing waiting or
  dependency-stopped Konsol containers on the Sağlık card.
- **Upgrade:** the next installer run re-places qBittorrent's Quadlet and restarts it once. That
  goes through the DD-222 path, so a failed run cannot skip it. Existing Konsol containers keep their
  old unit, with `Requires=`, until they are saved once in Konsol; there is no migration code.
- **Amended by the rebuild (DD-272, DD-274):** package units and the package engine's writer are gone; every
  application unit keeps the `Wants=`/`After=` order and the guard check in `ExecStartPre` (DD-274).

### DD-217: qBittorrent on its own bridge; ports published per address in its Quadlet (v2-195)

- **Request (user, 2026-10-04):** the Podman page showed many qBittorrent ports on every address
  (DD-215): "hangileri gerekli ise sadece onu açalım. arayüz erişimi, peer yayın portu açmamız
  yeterli. tüm yüzeylerde peer yayın portu açılması gerekli olmayabilir. quadlet dosyasında port
  açılmasını yüzey bazında kısıtlama yapabilir miyiz". Asked to choose, the user opened the peer
  port to the internet and chose a bridge network with Quadlet `PublishPort` over the recommended
  host network plus qBittorrent's own binding and the firewall.
- **What was found (nrm):** on the host network qBittorrent listened on every address (its peer
  port on WAN, Tailscale and loopback, LSD 6771/udp, UPnP/NAT-PMP sockets), but the WAN INPUT chain
  dropped all of them; the tailnet accepted everything. With `Network=host` Quadlet cannot restrict
  anything: Podman ignores published ports there.
- **Decision:** the container joins its own bridge `torrent` (`PAKET_KONTEYNER_AG`, generic engine
  key) and the quadlet publishes exactly `127.0.0.1:TORRENT_UI_PORT/tcp` and
  `WAN_IPV4:TORRENT_PEER_PORT` over TCP and UDP (`TORRENT_PEER_PORT=61008`, fixed through the image's
  `TORRENTING_PORT`). Inside the bridge the interface listens on the container's address
  (`WebUI\Address=*`, written by the seed template and the install for fresh and kept profiles);
  only the loopback publication reaches it. LSD/UPnP keep their defaults (DD-178): their sockets stay
  inside the container and nothing is published for them.
- **Why the guard changes:** Netavark DNATs a publication into the bridge, so the packet takes the
  forward path, not INPUT. The bridge is named with the guard's prefix, so the existing default drop
  covers it from the first second; `package_publications()` reads registered packages' placed
  quadlets and lets through only their WAN/Tailscale IPv4 publications (an unparseable or foreign
  address, or a placed quadlet on another network, is simply not let through; found live: an
  installer run renders the new manifest at stage 4 but places the new quadlet at stage 7, and
  refusing the mismatch stopped the firewall at stage 5). The engine refreshes
  the guard after placing and removing the quadlet; `master-firewall` refreshes it at boot before
  containers start.
- **Port moves:** a Quadlet drop-in cannot replace `PublishPort` (lists merge), so a Podman-page
  interface port change patches the single loopback line in the rendered and the placed quadlet,
  like DD-214's image line; the durable override makes the next render identical.
- **Trade-offs, stated:** NAT on the peer path; no IPv6 peers (the managed bridges are IPv4-only and
  the guard opens no IPv6); the WAN address is baked in at render time, so a changed WAN address
  needs an installer run; the peer port is internet-facing (libtorrent's listener).
- **Amended (v2-197, DD-219):** the interface port is 62947 and the peer port 63851 (were 61006 and 61008).
- **Existing installs:** fresh-install rule; a profile written by earlier versions carries
  `WebUI\Address=127.0.0.1` and the interface would not answer on the bridge. The manual step is
  reinstalling qBittorrent from App Store (the install writes `*`), or setting that key to `*` while
  the app is stopped.
- **Amended (v2-201, DD-223):** `After=master-firewall.service` did not hold the start back when the
  firewall failed. The package Quadlet now also checks the guard in `ExecStartPre` and retries
  every 10 s until it is in place.
- **Partly retired by the rebuild (DD-272, DD-275):** qBittorrent and the package publications are gone. Its
  guard rules hold for applications: each runs on its own bridge (`ksl-<app>`, DD-274), and a raw port's
  Tailscale or WAN publication is let in only as the DNAT Podman made for it (DD-275).

### DD-215: The Podman page shows the ports a host-network container listens on (v2-194)

- **Request (user, 2026-10-04):** the Access column showed only "Sunucu ağı (host)" for qBittorrent;
  show the ports the container opens (for example the peer port and the interface port) as ip:port.
- **Why not Podman:** a host-network container has no port mappings, so `podman ps`/`inspect` know no
  ports. The ports are the sockets its processes hold. `master_containers.listening()` takes the
  container's init PID (`State.Pid`), the processes of its own cgroup v2 subtree (never the root
  cgroup: then only the init process), their socket fds, and matches them against
  `/proc/<pid>/net/{tcp,tcp6,udp,udp6}` of that network namespace: TCP in LISTEN and unconnected bound
  UDP. IPv4-mapped addresses read as IPv4, IPv6 link-local binds are left out, duplicates collapse. No
  `ss`, no new tool, no podman call; it runs only for running host-network containers on each list or
  detail read (about 5 ms for qBittorrent on nrm, inside a replica of the backend's sandbox).
- **Honest labels:** each socket carries the kind of address it is bound to: all addresses, the
  server's WAN or Tailscale address (from the installer's state, then the tailnet ranges), another
  address, or loopback ("Yalnız bu sunucu"). This is not reachability: on the host network the
  firewall decides, and the detail says so. Unreadable processes or tables give `null` (unknown),
  never an empty "no ports".
- **Display:** the list shows one line per port with its widest address (IPv4 first), the protocols
  and the address kinds, at most three ports and "+N port daha"; the detail's "Ağ ve portlar" lists
  every address. Published bridge ports keep their mapping lines unchanged.
- **Not done:** no firewall evaluation, no process names, no per-port labels from packages.
- **Amended (v2-195, DD-217):** qBittorrent left the host network; the reader remains for any other
  host-network container.
- **Amended by DD-267 (v2-250):** the listening sockets are shown in the container details on the
  application's page (DD-266).
- **Amended by the rebuild (DD-272, DD-274, DD-276):** qBittorrent is gone and applications never use the host
  network (DD-274); the reader serves host-network containers Obhut does not manage, listed read-only in
  Gelişmiş → Podman (DD-276).

### DD-214: Konsol checks image updates, the operator applies them; row controls before the name (v2-193)

- **Request (user, 2026-10-04):** after the explanation of Podman, Quadlet files and digest pins, the
  user chose the "approved update" model for qBittorrent: "konsol güncelleme olup olmadığını
  denetlesin kullanıcı isterse güncellesin". Same request: on the Konteynerler page put start/stop and
  edit right before the container name, keep remove at the end, and use icons that suit the theme.
- **Check, never apply:** `master_containers.update_status()` compares the installed digest with what a
  channel tag points to now using `podman manifest inspect` (manifests only, no layer download): a
  multi-arch index by this host's platform manifest digest, a single manifest by its config digest
  (the local image id). It runs inside the backend's sandbox (verified on nrm with a replica of the
  unit's hardening). App Store packages name their channel with `PAKET_IMAJ_KANAL`; a Konsol
  definition's channel is its tag reference; digest references are `sabit`. `Service.updates()` caches
  the answers for six hours, forced checks are limited to one a minute, and a successful image-changing
  operation empties the cache. The page asks on open and on the operator's button only; there is no
  timer, no `AutoUpdate=`, no `podman-auto-update.timer`, and the browser never sees a pull target.
- **Apply on request (App Store):** `image-update` is offered when a package declares both a channel and
  a container adapter. qBittorrent's adapter (`ayar.py konteyner-guncelle`) re-checks under the settings
  lock, validates the files that name the image, then pulls the exact digest the check saw, rewrites the
  single `Image=` line of the rendered and the placed Quadlet and the `PAKET_IMAJ` line of the rendered
  manifest, records `TORRENT_IMAGE` as the package's durable override (`PAKET_AYAR_ANAHTARLAR`), restarts a
  running app, waits for its interface and checks the container's `ImageName`. Any failure restores every
  file and the previous service; the previous image is removed (by id, never forced) only after success.
- **Why patch files instead of a drop-in:** live check on nrm (Podman 5.4.2): a Quadlet drop-in's
  `Image=` is ignored (the generator keeps the main file's value), while multi-valued keys such as
  `Volume=`/`Environment=` merge. Patching exactly the image line keeps the Quadlet the readable truth
  about what runs, and the override makes the installer's next render produce the same bytes, so the
  engine's placement never reverts the update. A stopped app only gets the rendered files; its next
  start uses them. `kaldir --veri` drops the override with the other package settings (superseded by
  DD-220, v2-198: `--veri` keeps the override and the port drop-in).
- **Row controls:** start/stop and edit move into the name cell, before the application icon and name;
  remove stays in the last column (DD-213's fixed slots and capabilities unchanged). The icons and their
  bare style are the home tiles' own (`.tile-act`): play/pause, the settings sliders, trash; colour only
  on hover, remove turns to the danger colour. Keyboard order follows: start/stop, edit, name, the
  "Güncelleme var" chip when present, remove.
- **Not done:** no update for external or Compose/pod containers, no image signature verification, no
  automatic or scheduled update, no rollback after a successful update other than updating again.
- **Amended by DD-267 (v2-250):** the Podman page's row controls are gone. The check and the approved
  update are the application page's "Güncellemeleri denetle" and "İmajı güncelle" (DD-266), and
  Uygulamalar lists the update state (DD-261); the check, its cache and the apply path are unchanged.
- **Amended by the rebuild (DD-272, DD-274):** the App Store's apply path (`PAKET_IMAJ_KANAL`, qBittorrent's
  adapter, the override) and Konsol definitions are gone; an application's update pulls its own tags on the
  operator's confirmation and changes nothing when no digest moved (DD-274). The check, its cache and the
  no-automatic-update rule hold.

### DD-211: Main-sidebar container management with explicit ownership (v2-190)

- **Amended (v2-194, DD-216):** the sidebar entry and page title read "Podman"; the route stays
  `#/konteynerler`. Host-network containers show their listening sockets (DD-215).

- **Request (2026-10-03):** move Containers out of Settings and implement the accepted
  Portainer-like prototype: lifecycle, editable ports/mounts and real resource management.
  The frozen proposal is `docs/archive/design/konsol-konteynerler-v01.html`; corrected semantics
  and the implementation interface are recorded alongside it.
- **Ownership:** App Store applications retain `master-modul` and package-owned settings.
  Generic containers created/adopted in Konsol have private persisted definitions and
  `konsol-<name>.container` Quadlets. Unmanaged standalone containers have explicit
  lifecycle controls and an adoption preview. Compose/pod/systemd-controlled or unsupported
  definitions are never silently converted. The worker rechecks ownership under locks.
- **Writes:** the root socket backend brokers a fixed set of actions to a transient root
  systemd unit with a 900-second runtime bound. HTTP 202 means accepted, not successful.
  Private operation records expose progress and terminal success/failure, including an
  interrupted worker. Install/module/container locks serialize mutations; stale revisions
  refuse overwrite. Reads stay in the existing backend sandbox.
- **Persistence:** validate image, network, mounts and generated unit before stopping the
  old container. Images resolve to immutable digests. Explicit save/update can recreate;
  a failed replacement attempts configuration/runtime rollback and reports failure.
  This does not roll application data back. Stopped saves stay stopped; manual stop
  suppresses boot startup independently of the configured autostart preference. Secret
  environment values stay in 0600 files, with only presence returned by the API.
- **Networking:** Netavark retains NAT. A separate `inet` nftables forward guard at
  priority -10 covers only managed bridge interfaces. Local/Tailscale/public mappings
  are explicit; public access requires acknowledgement. Original DNAT destination and
  host port are checked, direct ingress and IPv6 are denied, and an established inbound
  flow does not bypass a newly revoked scope. Foreign tables/chains remain untouched.
  Aardvark DNS is an explicit dependency: managed bridge TCP/UDP 53 can reach only
  that bridge's own host address, including after the project firewall is reapplied.
  Existing tailnet address events mark a bounded refresh job; only changed Tailscale
  bindings are rerendered, stopped state is retained. There is no new timer/reconciler.
- **Data/resources:** container removal keeps volumes and bind data. Volume deletion is
  a separate unused-resource operation; custom volume drivers/options cannot bypass
  bind-path restrictions. Generic host binds are confined to real user folders under
  `SERVER_ROOT`, excluding protected package/share/trash paths. Managed bridge creation
  checks explicit subnet overlaps; runtime sockets, host networking and raw Podman flags
  are not part of the editor. In-use resources and package-pinned images are protected.
- **Package settings:** manifests may declare a container adapter and allowlisted durable
  overrides. qBittorrent's one listener port drives its profile, Quadlet drop-in, Caddy
  upstream, health/publication checks and installer rendering. Its existing account form
  remains the account owner. Required mounts are shown as protected in the generic editor.
  DD-221 (v2-199) adds the peer port: both WAN publications, `TORRENTING_PORT`, the profile's
  `Session\Port`, the container guard and installer rendering follow the same kind of override.
- **Scope:** one host/rootful Podman, no Docker daemon, shell console, Compose editor,
  cluster scheduler or automatic image updates. DD-208 still owns Podman base installation;
  its former read-only Settings placement is superseded by this decision.
- **Verification:** tests and live evidence are recorded in `SESSION.md`; the mockup is
  design evidence only, not proof of runtime or OS compatibility.
- **Amended (v2-205, DD-227):** writable server folders need the Files account (no capabilities);
  a root image gets volumes or read-only folders only.
- **Amended (v2-204, DD-226):** bind sources are walked and pinned at every start; the Quadlet
  mounts the anchor, and a missing or symlinked folder keeps the container down.
- **Amended (v2-201, DD-223):** generated units no longer carry `Requires=master-firewall.service`,
  so a firewall restart leaves running containers alone. Their `ExecStartPre` only checks the guard
  that the locked writers apply.
- **Amended by DD-267 (v2-250):** the main-sidebar Podman page is gone. A container's lifecycle,
  definition editor, log and image update are on its application's page in Uygulamalar, creating one and
  adopting one are Uygulamalar' add flows, and images, volumes and networks are Gelişmiş → Podman
  (DD-266). Ownership, the brokered writes, persistence, networking and the resource rules above are
  unchanged.
- **Amended by DD-269 (v2-253):** the read-only container view for a state file without
  `KONTEYNER_STATE_DIR` is gone; the routes always read the manager's view.
- **Partly retired by the rebuild (DD-272, DD-274):** App Store ownership, package settings, single-container
  definitions, adoption and the controls for unmanaged containers are gone; applications replace them
  (DD-274). The broker (a transient root unit, operation records, locks, stale revisions refused), the managed
  bridges with their forward guard and DNS exception, and the resource rules hold.

### DD-208: Podman is base infrastructure; Settings → Konteynerler is its read-only view (v2-185, v2-186)

- **Request (user, 2026-10-02):** after setting the "iOS-like store" restructuring aside
  ("amacımız stabilite"), the user asked to try qBittorrent as a container beside the native
  one and, on the assistant's comparison, chose Podman over Docker ("öneriyi kabul ediyorum");
  the trial on nrm (quadlet unit, host network, PUID 1000) left the firewall rule set untouched,
  needed no daemon and survived a reboot (SESSION.md, 2026-10-02). Then: "podman da çalışan
  konteyner'ı panelden görebileceğimiz bir yapı … kabaca kontainer durumu, mount dosyaları,
  portlar ve log görmek istiyorum sadece". v2-185 first shipped this as an App Store package
  (`magaza/podman/`, never committed). On 2026-10-03 the user corrected it: "podman bir platform
  sonuçta ayrı bir uygulama gibi görülmesin … app store tarafından kullanılabilen bir taban
  yapı olarak birlikte kurulsun".
- **Decision (v2-186):** Podman is part of the base. Stage 1 installs `podman netavark` without
  recommends (no buildah, criu, slirp4netns, passt or uidmap: host-network rootful containers
  need none; `netavark` is named because Ubuntu noble's podman does not depend on it) and dies
  unless `podman info` answers; stage 7 checks it again and the summary prints its version. No
  daemon: Debian ships `podman.socket`, `podman.service` and `podman-auto-update.timer`
  disabled and the installer never enables them. The App Store catalogue is the applications
  only; container applications use the runtime (DD-209).
- **The view:** Settings → **Konteynerler** (a sixth tab; the sidebar's "installed applications"
  stays for applications). `panel/master_containers.py` maps `podman ps/inspect/images/system
  df/logs` for `GET /api/konsol/konteynerler/{liste,ayrinti,gunluk}` (shared Konsol gates, no
  write route at all); `console/konteynerler.js`/`.css` render every container on the host with
  state, image, unit, mounts, ports and a masked log tail (100–1000 lines, in-place refresh that
  keeps the scroll). The tab's DOM node is persistent across Settings redraws, does not load
  the settings document, and opens a named container from `#/ayarlar/konteynerler/<name>` —
  the link an application page uses for its own container.
- **Safety of the read path:** the reads run inside `master-panel`'s sandbox (verified on nrm:
  `ProtectSystem=full`, `RestrictNamespaces`, `NoNewPrivileges` do not block them), container
  names are validated, `Config.Env` is never returned (images carry passwords there) and
  `password|parola|passwd|secret|token|api key|private key … : value` is masked in log lines
  before they leave the server. *(Amended by DD-251: no masking; managed containers' logs are their
  unit journals.)* Nothing here starts, stops or removes a container: that belongs
  to the application that owns it.
- **Why base and not a package:** a runtime is not something an operator "uses"; applications
  depend on it, and the engine has no dependency key. As a package it would also have needed a
  removal refusal ("remove the containers first") and a store-wide `podman system reset` for
  `--veri`, both wrong once applications run in it. DD-152 holds: no Docker, no daemon, no
  iptables churn (host network only).
- **Amended (v2-190, v2-195):** the read-only Settings tab became the main-sidebar Podman page
  with brokered writes (DD-211, DD-216). Stage 1 installs `podman netavark aardvark-dns`.
  Containers no longer use the host network only: Konsol's managed bridges (DD-211) and a
  package's own bridge (DD-217) run with Netavark-owned NAT, a project-owned `inet` forward
  guard and a MASTER-INPUT exception for each bridge's own DNS. The project never edits
  Netavark's or Tailscale's rules.
- **Amended by DD-267 (v2-250):** the read-only Settings tab, the Podman page that followed it and
  `console/konteynerler.js` are gone. A container's state, mounts, ports and log are on its
  application's page in Uygulamalar, Podman's images, volumes and networks in Gelişmiş → Podman
  (DD-266); the read routes and their safety rules are unchanged. An old `#/ayarlar/konteynerler/<name>`
  address opens the container's application page.
- **Amended by DD-272 (v2-255, the rebuild):** there is no App Store; Podman runs the applications (DD-271),
  and its resources are read-only in Gelişmiş → Podman apart from the cleanup (DD-276).

### DD-207: A package's backend write paths exist before the backend starts (v2-184)

- **Report (user, 2026-10-02):** creating the first WireGuard network from Konsol failed with
  "install: cannot change permissions of '/etc/wireguard/clients-wg0': No such file or
  directory". Reproduced on nrm inside the root backend's mount namespace: `/etc/wireguard`
  was read-only there (`mkdir` → EROFS) while writable on the host.
- **Cause.** DD-203 renders `ReadWritePaths=-/etc/wireguard` into `master-panel.service`; systemd
  binds such a path writable only if it exists when the service starts and silently skips it
  otherwise (the `-`). On a host where WireGuard was never installed, `/etc/wireguard` appears
  only when the App Store installs the package (its hook, or `wireguard-tools`), after the
  backend started, so the backend keeps seeing it through the read-only `/etc` until it
  restarts. The same happens when the folder is removed while the backend runs (the kernel
  detaches the bind) and created again — on nrm the assistant's test cleanup purged
  `wireguard-tools`, which removed the empty folder, and the operator's reinstall surfaced it.
  The v2-177 live test passed only because `/etc/wireguard` already existed when the backend
  started.
- **Fix.** (1) The installer creates every catalogued declared path (0700 root) before it
  (re)starts the backend, so a fresh host binds `/etc/wireguard` from the start; while
  WireGuard is not installed the folder is empty. (2) The installer also restarts a running
  backend whose `/proc/<pid>/mountinfo` lacks a writable mount at a declared path, so a re-run
  repairs a host in that state. (3) The store engine runs the same check after `kur`, `baslat`
  and `uygula` and restarts the backend once when needed (only in the removed-and-recreated
  case); Konsol keeps following a running operation quietly through that brief restart instead
  of dropping it after one failed poll. (4) `master-wg` checks that its folder is writable
  before any writing command and otherwise says so in Turkish with the remedy.
- **Rejected:** running every `master-wg` call through a transient unit outside the backend's
  sandbox (latency on every peer action and a larger change), and a per-install drop-in with an
  unconditional backend restart (DD-203's reason still holds).
- **UI in the same version:** the new-network screen became one card as wide as the windows
  (560 px: label and port side by side, the DNS picker, the outcome lines, the buttons) instead
  of three cards and a summary column; DNS options take two lines (name and badge, then
  description · addresses), so the network settings, peer add and peer edit windows show the
  whole list without an inner scroll; the network settings window has one hint instead of two.
- **Partly retired by DD-272 (v2-255, the rebuild):** packages and their declared write paths are gone, and so
  are the installer's mountinfo check and the engine's restart after `kur`. The rule holds for the base's
  WireGuard folder: stage 4 creates `WG_CONF_DIR` before the backend starts, and `master-wg` checks that its
  folder is writable before a writing command.

### DD-206: Overview edit mode, a server-side layout and a network card (v2-183)

- **Request (user, 2026-10-02):** "ana ekrana sol alta bir düzenle seçeneği ekleyelim … uygulama
  simgelerinin yerini değiştirebilelim ve widgetlarda boyut ayarlaması yapabilelim", then, on the
  assistant's plan: width only ("yükseklik sabit"), a show/hide switch, the clock card without
  version details (time, date, uptime, Tailscale and WAN addresses), and a network card with the
  server's download/upload every 1–2 s plus WireGuard's and qBittorrent's totals in one card.
- **Edit mode.** A "Düzenle" pill bottom-left, below the tiles and sticky to the bottom of the
  screen on a long page (a fixed pill covered the last row's controls on a short page — seen in the
  live look; sticky rests below the tiles at the end), opens a draft: tiles wiggle and become non-link groups with ‹ › buttons, and can be dragged with
  pointer events (one path for mouse and touch; listeners sit on the document because moving the
  dragged tile in the DOM drops pointer capture — found by the browser test). Widgets get − / +
  (1–4 of four columns) and Gizle/Göster; a hidden widget stays visible, dimmed, while editing.
  "Bitti" saves, "Vazgeç"/Escape/leaving the page drops the draft, "Varsayılan" returns to the
  defaults (a draft equal to the defaults deletes the record). Data refreshes do not redraw while
  editing; numbers keep updating in place. Reduced motion stops the wiggle. The tiles (and
  Düzenle) wait for the module list's first answer, so installed applications do not jump in
  after the page and a draft never misses them.
- **Layout on the server, not in the browser:** the same overview on every device. The root
  backend stores `KONSOL_AUTH_DIR/duzen.json` through the account store's safe writer (0600,
  atomic, no-follow, its lock), checks only the shape — keys, counts, width 1–4, boolean
  visibility — and leaves meaning to the shell, so the backend names no tile or widget. A damaged
  record falls back to the defaults. Widgets keep a fixed order (clock, status, network); only
  tiles are reordered. Grid: four columns (two below 1100 px, one below 480 px), the row sets the
  height; charts shrink inside a one-column card (container queries).
- **Network card.** Server rates come from the WAN interface's sysfs counters: the background
  sampler adds a point every 10 s and each `/api/konsol/ag` request one more when 1.5 s passed,
  so the card's 2-s polling gives live rates and the chart has the last 120 s at once; no command
  runs. Applications report through a new optional manifest key, `PAKET_TRAFIK` (a module in the
  package folder exposing `trafik(env) → {down, up, since}`, loaded like `yayin.py`/`klasorler.py`
  and cached 2 s), so the shell and the backend still name no application. Direction is as the
  application's users see it. qBittorrent: its own all-time totals (AlltimeDL/AlltimeUL), read
  from `qBittorrent-data.conf` ([Stats] AllStats, a QVariantHash that QSettings streams in the Qt
  4.0 format behind INI escapes) with the file's time as `at` — no login, no command; qBittorrent
  writes the file every few minutes while transferring and when it stops, so the figure can lag
  by that much and the card says when it was saved. WireGuard: the bytes its interfaces sent to
  (down) and received from (up) the peers, `since` the earliest running network's unit start.
- **Rejected on the live host — systemd IP accounting.** The first version counted qBittorrent's
  unit with `IPAccounting=yes`. On nrm (Debian 13, systemd 257) every `daemon-reload` dropped the
  counters of units loaded from disk ("[no data]" until the service restarts; transient units kept
  theirs), and installer runs, package installs and apt all reload systemd, so the card showed
  "ölçülemedi" most of the time. qBittorrent's API would give live all-time figures but needs its
  login, and a localhost bypass would open it to every local client behind Caddy.
- **Clock card:** time, date, uptime, Tailscale and WAN IPv4; host, OS and kernel stay in
  Ayarlar → Sistem.
- **Not done:** widget reordering, per-device layouts, all-time application totals, per-peer or
  per-network breakdown in the card.
- **Amended by DD-267 (v2-250):** the edit mode, the server-side layout (`/api/konsol/duzen`; a re-run
  deletes `duzen.json`) and the old home cards went with the old interface. The network card's data
  stays: the WAN sampler, `GET /api/konsol/ag` (in the route table since DD-261) and the packages'
  `PAKET_TRAFIK` modules feed Genel Bakış's Ağ card, read every 5 s while it is shown.
- **Amended by DD-269 (v2-253):** `ag` gives the last WAN rate (none older than 120 s) instead of a
  history, and each package's `{down, up}` only; the traffic modules no longer report `since`/`at`.
- **Partly retired by the rebuild (DD-272, DD-276):** the packages' `PAKET_TRAFIK` modules and their totals
  are gone; each application's live rate comes from its bridge's counters (DD-276). The WAN sampler and `GET
  /api/konsol/ag` hold.

### DD-205: No sign-in on the tailnet; the account is the public name's credential (v2-181)

- **Request (user, 2026-10-02):** "Panel girişinde eğer tailscale adı ile panel erişimi varsa
  parola sormadan açabilelim. ama https arayüzden erişim olursa kullanıcı adı ve parola ile
  erişim sağlayalım. kullanıcı ilk kullanımı tailscale arayüz ile yapar ve https arayüz
  kullanıcı adı ve şifresini oluşturur sonra giriş yapabilir olsun" — accepted with the
  assistant's recommendation: passwordless tailnet, the account made in Settings, no setup
  code, tailnet password change without the current one.
- **Trade-off (flagged):** every device in the tailnet is a full administrator without a
  password — a shared node, another tailnet user or an unlocked phone included. DD-194 was
  added one day earlier against exactly that; the user now prefers the convenience on the
  tailnet and keeps the password for the public name. Tailscale ACLs remain the only limit
  on who reaches `panel.<domain>`; the installer does not touch them.
- **The channel decides:** Caddy still asks the root backend before every protected request
  (`forward_auth`); the backend answers by the channel Caddy wrote (`X-Konsol-Kanal`,
  DD-195). `tailscale`: 204 without a cookie — `gate()` has already required another
  Tailscale device (DD-180), so host-local programs still cannot reach Konsol or the Files
  API through Caddy — and `/giris.html` gets 302 to `/`. `internet`, and a caller without
  Caddy's forwarding headers: a `konsol_oturum` session as before; only `/giris.html` is
  open without one. The sign-in page therefore moved behind `forward_auth` (its files and
  the sign-in API stay open in Caddy), which is what lets the backend redirect it on the
  tailnet.
- **Account = public credential:** the one-time setup code is gone (file, CLI verb,
  installer printout, sign-in form). `POST /api/konsol/oturum/kur` takes only user name and
  password, is refused over the internet (403) and opens no session; Settings → Sistem →
  Konsol hesabı offers it on the tailnet while no account exists. The Panel's internet switch
  (DD-195) keeps requiring an existing account, so the public site cannot open before the
  operator chose a password. `GET /api/konsol/oturum` tells the account name to the tailnet
  without a session (`reveal`), never to an anonymous internet visitor, and names the
  channel; the page shows the sign-out and the current-password field only on the public
  name and never guesses the channel from the URL.
- **Password change:** on the public name as before (current password, this session stays,
  the others end). On the tailnet `{yeni}` alone: the device is the credential, no session
  is needed and every session ends (`Store.set_password`). This replaces the SSH reset as
  the recovery path; `sudo master-konsol sifirla` still deletes the account and closes the
  public name, and `durum`, `oturum-ac`, `oturum-kapat` stay for state and scripted checks.
- **Budgets:** unchanged for the public name (per address and shared). `kur` and the tailnet
  password change check no secret, so they only use the bounded hash slots; the audit journal
  records them as `hesap-kur` and `parola-degis` with the device's address.
- **Not done:** no per-device identity on the tailnet (`tailscale whois`), no roles, no
  second factor for the public name, no account deletion in the UI.

### DD-195: Konsol over public HTTPS through the publication table (v2-167)

- **Amended by DD-205:** there is no setup code any more; account creation stays
  refused over the internet, and the tailnet site no longer asks for a sign-in.
- **Request (user, 2026-10-01):** after creating the first Konsol account, "panel
  sayfası için caddy adresini de https olarak açabilelim" — the Panel row of
  Settings → Caddy gets an internet switch and a public name like qBittorrent and
  WebDAV. The tailnet address stays the always-open management path.
- **Trade-off (flagged):** a public Konsol is full administration (firewall,
  WireGuard, files, App Store) behind one password and no second factor. The
  operator chooses it explicitly; the dialog asks for the typed word `onayla` and
  recommends a long, unique password. Tailscale-only stays the default.
- **One set of routes:** the panel site's routes move into the Caddy snippet
  `(konsol)`. `http://panel.<domain>` imports it as `tailscale`; the generated
  `moduller/panel-wan.caddy` (`https://<name>:SHARE_HTTPS_PORT`, bound to the WAN
  IPv4, TLS-ALPN, HSTS one year) imports it as `internet`. Both therefore have the
  same `forward_auth` session check, sign-in exceptions, CSP and backends; there is
  no other upstream. Backends always see `Host: panel.<domain>` (a local-domain
  change rewrites those lines too), so their DNS-rebinding checks are unchanged.
- **Channel, written only by Caddy:** the snippet sets `X-Konsol-Kanal` on
  `forward_auth` and the root backend route, overwriting anything a client sent.
  The root backend keeps DD-180 for `tailscale` (the client must be another
  tailnet device). For `internet` it requires an active publication (re-read at
  most every 5 s: enabled row, assigned global WAN IPv4, existing Konsol account)
  and a client that is not one of the server's own addresses. A request without
  the mark from a non-tailnet address is refused as before. Timed Settings
  confirmations also require the `tailscale` channel, not only a 100.64.0.0/10
  address (that range is carrier NAT space too), and the domain-change check
  reads the browser's real name from Caddy's `X-Forwarded-Host`, because `Host`
  is now pinned.
- **Load from the internet:** every public request costs one `forward_auth`
  round trip to the single Python root backend, and HTTP/2 lets one connection
  carry many requests. Each site therefore opens at most 16 connections to the
  backend (`max_conns_per_host`, session check and root API separately), and the
  unit raises `LimitNOFILE`: with exhausted descriptors the own-address probe
  fails closed and would have refused Tailscale too. Scanners can still keep the
  public sign-in locked (20 failures per 15 minutes); that is the accepted cost.
- **Sign-in over the internet:** the one-time setup code is refused (403); the
  first account is created only on the tailnet address, and enabling the row
  requires an existing account. The session cookie gets `Secure` whenever Caddy
  reports HTTPS. Failures over the internet also count in one shared budget:
  20 within 600 s close public sign-in for 900 s (429 + Retry-After) while
  Tailscale sign-in stays open; existing sessions keep working. Each address may
  run one password check at a time and at most two scrypt checks (16 MiB each)
  run at once, because one HTTP/2 connection can carry many requests.
- **Publication lifecycle:** a Settings transaction like qBittorrent's: DNS check
  before mutation, listener check, certificate wait, rollback on failure. The
  row's Tailscale switch is fixed on. Turning the internet on, or changing the
  public name, carries `confirm: onayla`, which the server checks as well as the
  page. Like qBittorrent it shares TCP 443 and the WebDAV socket budgets and
  cannot run beside folders shared over legacy WebDAV HTTP right now (v2-169: the
  live listener, not WebDAV's mode; the page says so before the dialog).
  The 30 s share guard re-runs the projection outside a pending Settings
  transaction, so a reset account (`master-konsol sifirla`) or a lost WAN address
  removes the public site and, if nothing else needs it, closes TCP 443; the
  backend refuses within 5 s before that.
- **Unchanged:** Settings changes that need a timed confirmation (firewall, local
  domain) are still confirmed only from a Tailscale address, so a public session
  cannot make them permanent. No Tunnel, no DNS writes, no IPv6 listener.
- **Amendment (v2-168, user report):** opened on its public address, Konsol
  linked qBittorrent as `torrent.<domain>`, unreachable from the internet. The
  module listing now carries `urls.tailscale` and `urls.internet` (the latter
  only while the qBittorrent publication is active, DD-191); the page picks by
  its own scheme and otherwise points to Settings → Caddy. Konsol never proxies
  qBittorrent under its own name: the app keeps its Host/CSRF checks and login.
- **Amended by the rebuild (DD-272, DD-275):** qBittorrent's row and `urls` are gone; Konsol's internet name
  is its fixed row in Erişim, opened through the settings plan with the 60 s confirmation (DD-275). The
  snippet, the channel, the budgets and the account rule hold.

### DD-194: Konsol sign-in with a one-time setup code (v2-166)

- **Amended by DD-195:** Konsol can also be published over HTTPS. The public site
  shares this `forward_auth` check; there the setup code is refused, the cookie is
  `Secure`, and public failures also count in one shared budget.
- **Amended by DD-205:** the tailnet address asks for no sign-in any more and the
  one-time code is gone; the account is the public name's credential, created in
  Settings over Tailscale. The session, cookie and budget rules below now apply to
  the public name only.
- **Request (user, 2026-10-01):** "panel girişine kullanıcı adı ve parola" — option B
  (Konsol's own sign-in page) with option 1 (a one-time code shown at the end of the
  install), seven-day sessions. This reverses DD-147's "no password" for Konsol; its
  other part (Tailscale joins by the login link only) is unchanged.
- **Threat model:** protects Konsol from someone using one of the operator's tailnet
  devices or a device shared into the tailnet, and is the prerequisite for any later
  public panel (still locked, DD-191). It does not protect the server itself: Tailscale
  SSH (`--ssh`) and the public SSH port keep their own access rules; WebDAV and
  qBittorrent keep their own logins.
- **Enforcement point:** Caddy's `forward_auth` on the panel site asks the root backend
  (`GET /oturum-denetle` over its Unix socket) before every request except the sign-in
  page, its three files and the sign-in API. Pages, Files API, archive downloads and the
  root API are therefore covered in one place, including the Files backend, which never
  sees sessions. A missing session answers 302 to `/giris.html` for pages and 401
  `{giris: true}` for `/api/*`, which Konsol turns into the same redirect. The backend's
  existing Host, `X-Konsol`, same-origin and DD-180 local-caller rules stay in front of
  the session check, so host-local programs going through Caddy are still refused.
- **Records:** `KONSOL_AUTH_DIR` (`/etc/master-stack/konsol`, 0700 root) holds the account
  (`hesap.json`: user name, scrypt n=16384 hash with salt), sessions (`oturumlar.json`:
  SHA-256 of a 256-bit token, creation and absolute expiry, at most 16) and the setup code
  (`kurulum-kodu.json`: scrypt hash, 24-hour expiry). Files are 0600, read without
  following links and bounded; writes are atomic under one `flock`. The root backend gets
  write access to that folder only (`ReadWritePaths`); sessions survive service restarts.
- **First account:** when no account exists the installer runs `master-konsol kod` at the
  very end and prints the code with `printf` to the operator's terminal only — never through
  `log()`, so it is not in `install.log`; the launcher keeps no local transcript. Each such
  run replaces the previous code. The code (12 characters without 0/O/1/I/L) is single use;
  the account name (3–32 characters) and password (10–256, no control characters) are
  chosen on `/giris.html`. `kurulum.env` still holds no account.
- **Sessions:** cookie `konsol_oturum`, `HttpOnly; SameSite=Strict; Path=/; Max-Age=604800`,
  no `Secure` because the panel is HTTP inside the tailnet (Tailscale encrypts the
  transport). Seven days from sign-in, not renewed by use. Changing the password keeps the
  browser that changed it and ends every other session; sign-out ends the current one.
- **Attempt limit:** sign-in, setup-code and current-password failures share the WebDAV
  numbers (DD-180): five per client address within 60 s block that address for 300 s
  (429 with Retry-After); the table is bounded and fails closed. A wrong user name costs
  the same scrypt check as a wrong password. The limit is in memory; a backend restart
  clears it. The audit journal records only the action, address and result.
- **Recovery and automation:** `sudo master-konsol sifirla` deletes the account and all
  sessions and prints a new code; `durum` shows the state. `oturum-ac --sure N` (60–3600 s)
  prints a short root-issued session token for scripted checks; live tests read it over
  SSH, keep it in memory and close it with `oturum-kapat` (stdin). Root can already do
  everything on the host, so this adds no new authority.
- **Installer checks:** stage 7 loads `/giris.html` through Caddy, proves a host-local page
  request reaches the backend and gets 403 (DD-180), and asks `/oturum-denetle` over the
  socket for 401 (API) and 302 (page). The Files self-check now uses its loopback port.
- **Not done:** no multi-user roles, no account in `kurulum.env`, no session list in the UI,
  no public panel publication. Host-side test helpers use the loopback Files backend or the
  root socket instead of Caddy.

### DD-193: Cross-review follow-ups for v2-159..v2-164 (v2-165)

- **Request:** after reading v2-159..v2-164 (implemented with another assistant),
  the user asked to fix every open item of that review.
- **Publication saves fail fast:** a `web` row that enables internet access now
  checks the real listener before waiting for a certificate: WebDAV through
  `wan_active()` (with `wan_info()`'s reason), qBittorrent through
  `torrent_active()`. An unavailable WAN used to cost the full 60 s certificate
  wait and end with a misleading DNS/CAA hint.
- **Recovery chains:** `startup_input_guard` and `startup_forward_guard` are
  separate and all-or-nothing. An incomplete INPUT guard is never attached, so a
  failed accept rule cannot lock out SSH; the FORWARD guard no longer depends on
  it. A failed ICMPv6 rule used `return` while every other step skipped the
  family. The command still fails and a later good apply purges leftovers.
- **Tailscale gate in shares:** a new folder starts with Tailscale on only while
  Settings → Caddy publishes WebDAV on Tailscale, and an off→on folder switch is
  refused while that gate is closed — the same rule as WAN and the UI. A policy
  that is already on stays on (the gate still blocks access) and can be turned off.
- **Single-flight logins:** requests carrying the byte-identical Authorization
  value for the same share and listener wait up to 2 s for the verification in
  progress and reuse its success; a failed or slow leader makes each follower
  check itself under the normal bounded path. A cold Infuse burst therefore costs
  one scrypt check instead of competing for the WAN 4 / Tailscale 2 slots. Slot
  counts, the 200 ms slot wait, 503/429 replies and all budgets are unchanged;
  different credentials (or spellings) still need their own slot, and decoy
  hashes still occupy slots by design (DD-180).
- **One HTTPS editor:** the standalone public-HTTPS card could not appear (the
  panel always returns the DD-191 table) and its browser test exercised a path no
  host showed; it is removed with its CSS. The table edits public WebDAV HTTPS;
  turning its internet switch off remembers the name. The stored `https` key and
  its API writer stay (data model and `https-live.py --configure`).
  `master_https.status()` adds `https_port`, so the table names the HTTPS port in
  legacy HTTP mode too, where `port` is `SHARE_PORT`.
- **Console details:** a forced settings refresh requested while another load is
  in flight now runs after it, so a save never redraws pre-commit data. A closed
  WAN share card is labelled "WAN" with a neutral icon instead of HTTPS/lock; the
  create form starts Tailscale off and locked while its publication is closed.
- **Caddy journal:** the default logger excludes `http.handlers.reverse_proxy`; a
  named logger keeps that namespace at ERROR and above. Media players closing a
  probe or stream no longer log a WARN per request; dial errors and 5xx answers
  are still logged by `http.log.error`. Trade-off: an upstream that truncates a
  response is no longer reported by Caddy; the backend's journal and health stay.
- **Installer temp-file leak (found while cleaning the test host):**
  `render_template` removed its `/tmp` copy through a `RETURN` trap, but Bash
  traps are global and `atomic_write` set its own `RETURN` trap, replacing it.
  On Bash 5 (Debian/Ubuntu) every rendered template left a root-only 0600 file
  in `/tmp` until reboot; Bash 3.2 on the Mac hid it. Neither function uses a
  trap any more: `render_template` streams into `atomic_write`, which cleans up
  explicitly and returns non-zero on a write failure. A Bats test checks Bash 5
  leaves no file and that a caller's own `RETURN` trap still runs.
- **Smaller fixes:** 403 stubs take the module template's address line instead
  of hard-coded names (single source); an unknown publication service gets its
  own message; stopped, uninstalled or unsafe qBittorrent rows name the cause;
  the two remaining panel JSON parse sites catch deep nesting; the health WAN
  card shows the share manager's reason; Files names the reserved-destination case.
- **Test tooling:** `publications-live.py` reads the operator's names from the
  host (missing-DNS probe under reserved `example.net`) and accepts an already
  public qBittorrent; `backend-hardening-live.py` uses the host's WAN mode;
  `share-networks-live.py` exits 3 before any change unless legacy HTTP is
  active; `settings-https-ui.cjs` drives the table.
- **Unchanged on purpose:** TCP/HTTP budgets (DD-188), restart on share save
  (DD-158/192), the refresh-page refusal of `durum`/`pause` (DD-192) and the
  schema-3 migration.
- **Amended by DD-269 (v2-253):** `master_https.status()` no longer adds `https_port` or `wan_ip`;
  nothing read them after DD-267.
- **Partly retired by the rebuild (DD-272, DD-275):** qBittorrent's listener check, the stored `https` key
  with its writer (DD-275) and the schema-3 migration (DD-272) are gone; the other fixes hold.

### DD-192: Per-connection WebDAV policies and dual-card Shares (v2-164)

- **Decision:** retain one folder, stable share ID and account/password while
  giving Tailscale and WAN independent enabled state, RO/RW and absolute expiry.
  This permits Tailscale RW with WAN RO, or the reverse, without overlapping
  folder grants or duplicated accounts. Both off is valid and keeps the account.
  New shares default to Tailscale enabled/RO/seven days and WAN off/RO/seven days.
- **One policy source:** schema 4 stores `connections.tailscale` and
  `connections.wan`, each exactly `{enabled: bool, permission: "ro"|"rw",
  expires: Unix-seconds|null}`. Shared `permission`, `expires`, `paused` and
  `networks` are removed; their presence in a schema-4 item is a conflict and
  fails closed. Valid schema 3 converts in memory, copying the exact shared
  permission/expiry to both policies, enabled only for a previously selected
  network when not paused. IDs, path/account, salt/hash, folder identity and
  `created`/`changed` stay unchanged; `prepare` persists schema 4. This is a
  narrow exception to DD-185, not restored schema-2 support or general cleanup.
- **Partial writes:** `POST /api/konsol/paylasim/kaydet` accepts one or both
  nested scope patches with `enabled?`, `permission?`, `days?` (0/1/7/30) and
  `ack_write?`. Read omitted values under the existing operation locks; never
  reset the other scope or extend an omitted expiry. Toggling does not renew an
  expired connection. Explicit RW requires `ack_write: true` in that same scope,
  even when already RW or off. Shared account/path/password edits stay separate.
  Old global-policy fields and `.../durum`/`pause` requests are rejected with a
  refresh-page message, so a stale browser cannot silently rewrite both policies.
- **Enforcement:** the receiving loopback listener selects the policy, never a
  client header. Every DAV write, live transfer chunk and staged PUT/COPY final
  publication enforces the applicable enabled/permission/expiry checks. A cached
  password success cannot bypass authorization. Descriptor/root checks, budgets,
  rollback and secret handling remain mandatory.
- **UI and state:** each Shares entry has two cards with its own switch,
  permission, expiry, address/copy and Infuse details. WAN is HTTPS when
  configured; legacy HTTP is labeled honestly with its plaintext warning and
  consent. Manage edits the shared folder/account/password. Public connection
  state adds `expired`, `available` (global gate), `active`, `reason` and `url`.
  An available transport can supply a candidate URL even while the card is off
  or expired; `row.urls` contains only active connections. A card explains why a
  DD-191 global Caddy gate blocks access and cannot override that gate.
- **Retained lifecycle:** configured HTTPS keeps its renewal listener with no
  active folders, subject to the global publication gate and DD-190 prerequisites.
  Share edits still restart active WebDAV and interrupt all transfers; retain
  that warning. This does not add hot reload, new listeners or a new ACL model.
- **Verification:** see [the test runbook](../tests/README.md) for fixture and
  opt-in live/UI checks, and [SESSION-to-v2-206.md](archive/SESSION-to-v2-206.md) for the main implementation
  task's exact v2-164 results and host health. Main reports successful `nrm`
  deployment, exact migration preservation, real HTTPS/Tailscale acceptance with
  byte-identical registry cleanup, and read-only installed UI acceptance.
- **Amended by DD-267 (v2-250):** Shares is Dosyalar → Paylaşımlar: one card per share holds both
  connections with these controls. The backend has no `paylasim/durum` route any more (an unknown route,
  404); the manager still refuses old global-policy fields and its own `pause` action with the
  refresh-page message.
- **Amended by DD-269 (v2-253):** the share manager's `pause` action is gone (an unknown action is
  refused); old fields still ask for a reload.
- **Amended by the rebuild (DD-272, DD-275):** the schema-3 conversion is gone: only schema 4 loads, and a
  share record with a key this version does not write fails closed (DD-272). The DD-191 global gate is
  Paylaşımlar' fixed row in Erişim (DD-275).

### DD-191: Fixed publication table with independent private and public gates (v2-162)

- **Amended by DD-252:** the operator may add addresses for a port on this server's loopback (its
  own tailnet name and an optional public name, the application's own login as the guard). Other
  upstreams, Tunnels and DNS API tokens stay excluded.
- **Amended by DD-195:** the Panel row's internet switch and name are editable;
  its Tailscale switch stays fixed on. See DD-195 for the extra backend gate.
- **Amended (v2-169, user report):** a fresh install refused the first HTTPS
  publication because WebDAV without a saved name is "legacy HTTP mode". The
  real constraint is Caddy's single WAN port, so the rule now follows the live
  listener: enabling qBittorrent or Panel HTTPS is refused only while folders
  are actually shared over plaintext HTTP; while an HTTPS row is on, legacy HTTP
  WebDAV internet access is unavailable (cards name the reason) until an HTTPS
  name is saved. Folder connections are never rewritten.
- **Amended by DD-194:** a Konsol sign-in now exists; publishing the panel on the
  internet remains a separate, not yet taken decision, so its WAN row stays locked.
- **Amended by DD-192:** folder gates are now per-connection policies. Cards
  expose candidate addresses while locally off, but globally disabled routes
  still have no advertised address and `row.urls` contains only active scopes.

- **Decision:** extend DD-190 to a real Settings → Caddy table, not a general
  proxy editor. The fixed catalogue is Panel, qBittorrent and WebDAV. Panel
  Tailscale is on and WAN is locked in both UI and API until a separate login
  design exists. No Cloudflare Tunnel, arbitrary upstream or DNS API token.
- `master_publications.py` reads saved `web.<service>` rows containing `tail`,
  `enabled` and `domain`. A disabled public name is remembered, never converted
  to plaintext HTTP. Existing DD-190 HTTPS settings migrate on first row save;
  the old HTTPS endpoint remains compatible. Two enabled rows cannot share a
  hostname. qBittorrent HTTPS cannot run while folders are shared over legacy
  WebDAV HTTP: convert that row to HTTPS or close those folders' internet
  connections first (v2-169; earlier the mode alone blocked it).
- Both public names use the same assigned IPv4/TCP `SHARE_HTTPS_PORT`, strict
  SNI/Host and existing socket limits. qBittorrent upstream remains fixed to
  loopback `TORRENT_UI_PORT`; its permanent native password, mandatory local
  login, disabled subnet bypass, CSRF/Host checks and login-attempt ban are
  prerequisites. An anonymous API probe must return 403. Preferences, peer
  discovery and UPnP are not rewritten. Native application bans may cover
  the proxy address unless the operator configures trusted reverse proxies;
  these are not WebDAV's per-client password budgets.
- Saving is an isolated revision-checked Settings transaction. DNS is checked
  before mutation and certificate trust/name before commit. Private projections
  are snapshotted too: first-row failure or process crash must restore the old
  route even when no saved `web` row existed. No extra timed user confirmation.
- Disabling a Tailscale publication renders an explicit 403 route (including
  WebDAV by IP); it does not stop the app or remove shared Caddy ports. Folder
  network/account/RO/RW/expiry remains a second gate. No folder records change,
  and Files omits URLs for globally disabled networks. Graceful Caddy reload
  permits in-flight transfers to finish; account edits still restart WebDAV.
- The existing narrowly scoped publication guard and module lifecycle refresh
  known projections; unchanged output is a no-op. Module reapply and installer
  consume saved choices. Stopped/removed qBittorrent loses its WAN site; unsafe
  native auth configuration also suppresses it on the next guard run. This is
  not instantaneous monitoring of qBittorrent's in-memory preferences.
- Unit/browser fixtures are not public reachability or native-client proof.
  Live acceptance must separately check DNS, real TLS, both network gates,
  private API isolation, rerun persistence and unchanged folder accounts.
- **Partly retired by the rebuild (DD-272, DD-275):** qBittorrent's row and the manual addresses are gone; the
  table keeps the fixed Konsol and Paylaşımlar rows (`web.panel`, `web.paylasim`), shown in Erişim beside the
  applications' access rows (DD-275).

### DD-190: Optional public WebDAV HTTPS without widening private administration (v2-161)

- **Amended by DD-193:** the separate Settings card is gone; the DD-191 table is
  the only editor. The stored `https` key and its API writer remain.

- **Decision:** Settings → Caddy accepts a separate full public domain for
  folder WebDAV. `master_https.py` interprets the saved mode, checks DNS and
  certificates and generates the WAN site; `master_settings.py` owns the
  existing revision/lock/pending/commit workflow, and `master_shares.py` owns
  publication. This supersedes DD-179's HTTP-only boundary, not its per-folder
  network selection, authentication, limits or private administration boundary.
- **DNS and transport:** the name must resolve to exactly the host's assigned,
  globally routable `WAN_IPV4`, with no AAAA or proxy. Caddy owns Let's Encrypt
  keys, issuance and renewal through TLS-ALPN on TCP `SHARE_HTTPS_PORT` (443).
  HTTP challenge is disabled and `auto_https disable_redirects` avoids a WAN
  port-80 listener. No Cloudflare/DNS API token, DNS write, NAT discovery, new
  certificate daemon or public IPv6 publication. Private names and Tailscale
  HTTP on `SHARE_PORT` (61010) remain unchanged.
- **Host/SNI boundary:** only the WAN HTTPS `servers` block enables
  [`strict_sni_host on`](https://caddyserver.com/docs/caddyfile/options#strict_sni_host),
  rejecting a request whose Host differs from its TLS SNI with 421. Previously,
  an unmatched/spoofed Host could receive Caddy's empty default 200; it exposed
  neither an API nor private content. This makes rejection explicit without
  changing private HTTP listeners. `protocols h1 h2` permits only HTTP/1.1 and
  HTTP/2 over TCP; HTTP/3 is disabled and no UDP 443 listener or firewall
  permission is added.
- **Three deliberate modes:** no `https` key preserves the existing explicitly
  consented HTTP WAN behavior. A nonempty domain selects HTTPS; an explicitly
  empty domain selects off, never HTTP fallback. Accounts, network selections,
  IDs, hashes, permissions and expiry are not rewritten by this setting.
  In HTTPS mode the listener/permission remains for renewal even with no active
  folders, while the assigned address, valid registry and running registration
  remain available. Every folder still authenticates and enforces its network,
  identity, permission, pause and expiry. For the configured public Host, only
  `/s/*` is proxied; other paths, including the administrative APIs, return 404.
- **Save is a transaction, not a second connectivity confirmation:** reject
  mixed/stale requests; record durable pending state before publication;
  commit only after a trusted chain and matching hostname verify. Caddy/firewall
  or certificate failure restores the previous saved projection. The independent
  Settings guard recovers a pre-commit crash; the durable commit marker protects
  a completed save. Restoring the prior mode after a failed first enablement
  can restore its consented HTTP endpoint; a committed HTTPS setting never
  silently downgrades when a certificate later fails. Explicit removal closes
  new WAN connections through graceful Caddy reload; existing transfers may
  finish. Account mutations still restart DAV and interrupt transfers.
- **Status is narrowly evidenced:** connect locally to the assigned WAN IPv4,
  with the domain used for SNI and chain/hostname verification, never as an
  arbitrary connection target. Report expiry and warn at 14 days or less.
  “Ready” proves that local certificate check, not public DNS propagation,
  provider firewall reachability or native-client compatibility. Public access
  requires separate external acceptance.
- **Coverage and limits:** `test_https_settings.py`, `test_https_panel.py` and
  `settings-https-ui.cjs` exercise transactions, rollback/recovery, mode-specific
  URLs/ports, certificate status and the private UI/API boundary. Opt-in
  `https-live.py` uses three temporary shares and turns their connections off,
  removes its own fixtures and checks the original registry digest;
  `--configure` deliberately leaves the real public domain saved. Run instructions are in `tests/README.md`;
  execution results belong in `CHANGELOG.md`/`SESSION.md`, not inferred here.
- **Amended by DD-275 (v2-258, the rebuild):** the `https` key and its writer are gone; WebDAV's public name
  is its `web.paylasim` row. With no row ever saved, a folder's internet connection is the consented HTTP; a
  saved row without an enabled name closes WAN.

### DD-189: Audit stage 4 distinguishes unknown health and IPv4-only names (v2-160)

- Generated `interface-name` records for IPv4-bound services use `/4`. Both
  DNS readers understand the suffix; explicitly supplied IPv6 host records
  remain IPv6. Returning an unusable AAAA is not a reachability improvement.
- Health checks the desired core services/timers and running optional modules,
  including enabled WG networks, not merely systemd's failed list. Deliberately
  stopped optional services are not failures. Unreadable probes/registries show
  unknown/warning instead of success. Deep JSON is a controlled input error.
- `/run/reboot-required` remains authoritative when present. Without it, compare
  the running kernel with the distribution's `/vmlinuz` or `/boot/vmlinuz`
  target, requiring matching flavor and a nonempty boot image/initrd pair. No
  lexical package-version guess; missing, broken or custom boot evidence is
  unknown. `ProtectKernelModules` hides module directories inside the panel;
  their invisibility is not treated as a missing kernel and the sandbox stays
  unchanged. The comparison is a distribution boot-link check, not a certification
  of an administrator's custom bootloader choice. Reboot remains manual.

### DD-188: Audit stage 3 bounds authentication and shortens write locks (v2-160)

- **Amended by DD-193:** identical concurrent credentials first share one
  verification (single flight); only then do requests compete for a slot.

- WAN and Tailscale have separate four-slot/two-slot scrypt budgets. A request
  waits up to 200 ms and rechecks the successful-login cache before hashing.
  Exhausted processing capacity yields 503 plus Retry-After; bad-password
  throttling remains 429. Full connection pools send a best-effort nonblocking
  503 without spawning another worker. No unbounded admission queue is added.
- PUT/COPY receive/copy/fsync a private sibling outside the mutation lock.
  Final publication rechecks share identity, permission, scope, expiry, pinned
  parents, source/target versions and HTTP preconditions under the lock. A
  conflict removes the temporary result; it never silently replaces a concurrent
  write. Existing disk reserve, size limits and atomic publication remain.
- WebDAV adds syscall/process/IPC isolation, TasksMax=96, MemoryMax=512M and a
  5-per-10-minute automatic start budget. Explicit operator renewals still reset
  start throttling. Page cache counts toward MemoryMax and is reclaimable; a
  historical memory peak is not evidence of a process leak.
- Tailnet proxy keepalive becomes 30 s, below the backend's 60 s idle limit;
  WAN remains nonpersistent upstream. Files gets a 180 s inactivity timeout
  (longer than its proxy keepalive) and controlled deep-JSON rejection.
- Keep TCP 16/IP, 64 total and HTTP 4/IP, 8 WAN/64 tailnet workers for now.
  Zero measured TCP overflow does not justify removing the resource ceiling;
  these budgets are not volumetric DDoS protection. Account edits still restart
  DAV and interrupt transfers. HTTP WAN risks and the local proxy-header trust
  boundary remain explicit; this package does not add TLS or a hot-reload engine.

### DD-187: Audit stage 2 keeps boot failure closed and pins privileged paths (v2-160)

- **Amended by DD-193:** the INPUT and FORWARD recovery guards are independent
  and each is all-or-nothing; an incomplete INPUT guard is never attached.

- **Registry failure:** validation remains strict. An apply with unreadable
  settings/share/WireGuard data preserves an existing owned default-deny policy
  and manual denials. If none exists, a small owned guard before `ts-input`
  allows loopback, established replies, SSH, Tailscale transport and essential
  IPv6 control traffic; unknown WG interfaces cannot forward. The command still
  fails, so the firewall health/pre-start gates cannot call recovery healthy.
  A subsequent successful apply removes these temporary owned guards. Read-only
  `--check` never repairs or mutates, and third-party chains remain untouched.
- **Other interfaces:** both INPUT policies end with an unconditional DROP,
  after the explicit WAN DROP. An extra interface no longer falls through to
  the host's ACCEPT policy; explicit operator rules remain authoritative.
- **Privileged paths:** installer directory creation, private archive mode and
  selective data-tree repair use pinned directory descriptors and no-follow
  traversal. Only directories and single-link regular files are changed, only
  where UID/GID/mode differs. Symlinks, special files, hard links and the reserved
  top-level `.pay`/private `.arsiv` trees are not traversed by ordinary repair.
  This replaces path-based `find -exec chown/chmod` (DD-53/DD-84 implementation).
- **Lock order:** module mutations take install then module locks. A child
  invoked by the locked installer reuses its inherited flock descriptor only
  after checking the descriptor's inode against the canonical install lock;
  an environment flag alone is not a bypass. Standalone modules acquire it.
- **Third qBittorrent read:** the CLI's first-login username lookup also reuses
  the bounded no-follow reader; FIFO input cannot hold the module/install locks.
- **Linux verification follow-up:** Bash 5.2 enables `patsub_replacement`, unlike
  macOS Bash 3.2. Template rendering temporarily disables it, then restores the
  caller's option, so literal `&` and backslashes are not interpreted as a match.
- **Partly retired by DD-272 (v2-255, the rebuild):** the module lock, the third qBittorrent read and the
  `.pay`/`.arsiv` exclusions are gone; the recovery guard, the final DROP, the pinned repair and the
  inherited-descriptor check hold.

### DD-186: Audit stage 1 separates admission queues from workload limits (v2-159)

- **Evidence:** the v2-158 review found Caddy 502s from `EAGAIN` on the root
  backend's Unix socket. All three Python server classes inherited a listen
  backlog of 5. No TCP listen overflow was observed, so a larger TCP backlog
  is preventive, not proof of the first Infuse delay's cause.
- **Decision:** set `request_queue_size = 128` on all three server classes.
  This queues pending connections; it does not raise WebDAV's simultaneous
  request/hash budgets, the firewall TCP limits or bandwidth. Capacity tuning
  and authentication admission belong to a separate, measured stage.
- **Service-owned configuration:** reuse `master_settings.read_regular` in
  both qBittorrent readers: descriptor-relative no-follow traversal,
  nonblocking open, regular-file check and bounded reads. The panel retains
  its 64 KiB limit and allowlist; sharing uses the helper's 1 MiB limit and
  fails closed on unsafe/unreadable input. Missing profiles remain allowed.
- **Internal directory sources:** listing/path guards and destination-name
  checks did not protect root `.cop`, `.pay` and `.arsiv` as mutation sources.
  Validate every selected source before any rename/move/trash work; also
  disallow promoting a nested reserved name into the root. Trash restore uses
  an alternate name instead of creating a reserved root entry. This is an
  administrative Files API guard, not an anonymous WAN authentication issue.
- **Scope:** no share/account changes, migrations, automatic reboot, WAN
  exposure changes or new dependencies. The historical 670 MB memory peak
  may include page cache but cannot be attributed retrospectively without
  that invocation's `memory.stat` samples.
- **Partly retired by the rebuild (DD-267, DD-272):** the qBittorrent readers and the `.pay`/`.arsiv` source
  guards are gone (the trash, `.cop`, stays reserved); the listen queues hold.

### DD-185: Fresh-install-only cleanup and a documentation index (v2-158)

- **Narrow exception in DD-192:** valid schema-3 WebDAV registries now convert
  to schema 4 without changing identity/account or renewing expiry. Schema 2
  and the other retired migrations below remain unsupported.

- **Request:** the user accepted the 2026-09-29 maintenance recommendation: trim
  the documentation first, then delete code that only served upgrades from
  earlier versions (fresh install only, no migrations).
- **Removed:** `panel/master_wg_upgrade.py` and its stage-4 call (DD-177 upgrade
  helper) with the settings filter for old wgN-scope rules; `GET /api/wg/sistem`
  and the `ports`/`share` keys it added to the resources reply; schema-2 share
  registry conversion (only schema 3 loads); the retired `health.<domain>`
  cleanup; the HTTP 410 answers for `/api/paylas*` (now 404); master-modul's old
  shared-account warning; the `ui`/`ping` WireGuard input kinds in the settings
  view (a hand-added WG→host ACCEPT is now shown as unknown); Konsol's rewrites of
  retired bookmarks; log labels for actions no backend writes; the retired login
  event kind, unused JS identifiers and 93 lines of CSS no page uses.
- **Kept on purpose:** the reserved `.pay` protection (it hides data a reused
  disk could still hold, DD-171); the registry's fixed `inet` column (a format
  change, not a deletion); the refusal of a `scope` field (rejects input, stores
  nothing); the archive API's `nested`/`layers` options and the
  missing-`SHARE_WAN_BACKEND` guards (option handling and fixtures, little gain).
  Tests that assert removed features stay absent are kept as regression guards.
- **Documentation:** retired and superseded decisions moved verbatim to
  `docs/archive/design-decisions-retired.md` (75 entries; DD-133, DD-149 and
  DD-155 stay live because parts are still current), with a one-line-per-entry
  `docs/decisions-index.md`; CHANGELOG entries before v2-145 and SESSION history
  moved verbatim to `docs/archive/`; contract, architecture, README, CLAUDE.md
  and test notes describe current behaviour only.
- **Consequence:** a host installed with an older version needs a fresh install;
  the installer no longer rewrites its WireGuard registry, settings or shares.
- **Amended by DD-267 (v2-250):** the archive API's `nested`/`layers` options kept here left with the
  archive jobs.
- **Amended by DD-269 and DD-272 (the rebuild):** what it kept on purpose (the `.pay` protection, the archive
  options, DD-192's schema-3 exception) is gone, and no migration code remains (K1, DD-271). The documentation
  index holds.

### DD-184: Tailscale and Caddy join unattended upgrades, at night (v2-158)

- **Request:** the user accepted the 2026-09-29 recommendation to update these
  automatically. Supersedes DD-113's "Tailscale/Caddy only on a re-run".
- **Why:** tailscaled is always reachable from the internet (UDP 41641) and Caddy
  is while a WAN share is published; a fix in either waited for a manual re-run.
- **How:** `52master-stack-unattended` adds `Unattended-Upgrade::Origins-Pattern`
  entries for the two repositories' Release fields (read on nrm: Tailscale
  `Origin/Label: Tailscale`, Caddy `Origin: cloudsmith/caddy/stable`). The list is
  appended to the distribution's, never replaces it. A timer drop-in moves the
  daily upgrade from 06:00 (+60 min) to `APT_UPGRADE_TIME` 04:00 (+30 min);
  `Persistent=true` from the distribution unit still catches up after downtime.
  Stage 7 warns when the effective configuration lacks either pattern.
- **Trade-off:** an update restarts tailscaled (the exit node and tailnet drop for
  a few seconds; the firewall reapplies through `PartOf`) or Caddy; a bad upstream
  release can arrive unattended. Automatic reboot stays off. Tailscale's own
  `--auto-update` was not used, to keep one mechanism and one schedule.

### DD-182: Capped rollback, WAN address change, watchdog resets, damaged history, health card (v2-156)

- **Source:** the 2026-09-29 resilience review (risks 1, 3, 8, 9, 10) and the
  health-card proposal. User approved "v2-156 için başla".
- **Stuck rollback:** an unconfirmed settings change whose rollback keeps
  failing used to be retried every 2 s forever while the installer, modules and
  shares refused to run. Automatic attempts now wait 15, 30, 60, 120 s; the
  fifth failure sets phase `stuck`: the guard stops trying and its timer sleeps.
  Konsol shows the last error with "Yeniden dene" (a manual attempt) and
  "Bırak" (only when stuck, typed `onayla`): the pending file is removed and
  files stay as they are; re-running the installer applies the saved settings.
  Chosen over an automatic give-up so a person sees why the rollback failed.
- **WAN address change:** the share site binds WAN_IPV4 from the install; a new
  provider address made Caddy fail (Konsol included) and the installer die in
  stage 6. `wan_info()` now also requires the address to be assigned (probe
  bind without a port; only EADDRNOTAVAIL means gone), so the 30 s guard removes
  the site. If Caddy is already down, a failed reload starts it with the new
  projection instead of restoring the old one; the next guard run confirms.
  Stage 6 removes a site bound to another address before restarting Caddy.
- **Watchdog:** `reset-failed` before restarting a failed Caddy (a boot race
  could use up 3 starts/600 s and leave Konsol down ~10 min); the firewall is
  checked again after `tailscale wait`, since the tailnet allowlist includes
  PeerAPI read from tailscaled.
- **Archive history:** invalid `jobs.json` is renamed to
  `jobs.json.bozuk-<time>` in the private workspace and history starts empty;
  I/O errors still stop the service (a real disk problem).
- **Health card:** `GET /api/konsol/saglik`, read-only, cached 30 s, shown on
  Settings → Sistem: failed units, Tailscale state/online/key expiry (warn
  under 14 days), `master-firewall --check`, `/run/reboot-required`, NTP sync,
  free space/inodes of `/` and SERVER_ROOT against the upload reserve, pending
  or stuck settings change, and a WAN share whose address is gone. No
  notifications and no automatic repair.
- **Amended by DD-267 (v2-250):** the archive history bullet no longer applies (archive jobs removed).
  The health card is Sistem → Sağlık and Genel Bakış's problem list (DD-261, DD-266).

### DD-181: Remember WebDAV logins, idle rollback timer, quieter journal, compressed Konsol (v2-155)

- **Measured on nrm (2026-09-29):** each WebDAV request re-ran scrypt (~22 ms
  locally, more on a VPS vCPU; Infuse browsing sends hundreds). The settings
  guard ran 1266 times an hour and made 77% of the journal; the WAN-share timer
  added 354 lines an hour. Konsol re-downloaded ~270 KB uncompressed on each
  load. The root backend logged every request, pushing audit lines out of the
  400 lines "Son işlemler" reads.
- **WebDAV:** successful logins are remembered in memory (10 min, 256 entries;
  key: share, stored hash, HMAC of the Authorization value under a per-process
  key). No change to what is checked: pause, expiry, scope, per-IP and
  per-share limits apply to every request. A registry edit restarts the service,
  which clears the memory. Tailnet slots go from 16 to 64 because Caddy keeps up
  to 32 idle upstream connections that could hold every slot; every closing
  reply now says `Connection: close`.
- **Nagle (found while measuring on nrm):** the WebDAV and Files backends write
  headers and body separately. On Caddy's kept-alive loopback connection Nagle
  held the second write for the peer's delayed ACK, so every request through
  Caddy took ~44 ms (a new connection: 1 ms). Both handlers now set
  `TCP_NODELAY` (`disable_nagle_algorithm`). The root backend uses a Unix socket
  and was not affected.
- **Rollback timer:** apply starts it (under the locks, before the pending
  file); an idle guard run stops it only while holding the same locks, so it
  cannot stop a timer an apply still needs. Enabled for boot. Stage 7 checks
  "enabled", not "active".
- **Journal:** both 30 s/2 s oneshots set `SyslogLevel=notice` and
  `LogLevelMax=notice`: PID 1's per-run start/finish lines are dropped, the
  helpers' own messages are kept. The root backend no longer logs request lines
  (the Files backend never did); audit lines remain.
- **Konsol:** `encode zstd gzip` on the panel site; page files use `no-cache`
  (ETag revalidation) instead of `no-store`. API replies keep `no-store`. The
  WebDAV sites are not compressed (video).
- **Settings view:** concurrent refreshes share one computation; "Yenile" still
  recomputes unless one finished while it waited.
- **CPU priority:** qBittorrent runs with `Nice=10` and `CPUWeight=50`, so
  tailscaled (the exit node's throughput limit) and Konsol come first. Archive
  job threads (and the unrar they start) are niced to 10; already-compressed
  media is stored, not deflated, in ZIPs.
- **Not done:** folder-size caching in Files, reusing the WireGuard sampler for
  `/api/wg/state`, building the settings view from one `iptables-save`.
- **Amended by DD-267 (v2-250):** Konsol's archive jobs, and with them the niced job threads, are gone.
- **Amended by DD-272 (v2-255, the rebuild):** qBittorrent's CPU priority went with its package.

### DD-180: Private sockets, shared login limits, disk reserve, sandboxed unrar, firewall-first WireGuard (v2-154)

- **Finding (2026-09-29 review):** loopback was treated as a trust boundary. The
  password-less root backend accepted any local process on `127.0.0.1:61008`
  (its only other gate, `X-Konsol`, is a header a client sets), and Caddy's
  admin API on `127.0.0.1:2019` was open to every uid; verified from the
  downloads account on nrm. A code-execution bug in a downloads-uid process
  (qBittorrent with untrusted peers, unrar with untrusted RARs, the WAN-facing
  WebDAV) could therefore become root or publish the root backend.
- **Decision:** the root backend listens only on `WG_PANEL_SOCKET` (`0660
  root:CADDY_GROUP`, folder `0755` via `RuntimeDirectory`) and also checks
  `SO_PEERCRED` (root or Caddy's group). Loopback Host names are no longer
  accepted. Caddy's admin API moves to `CADDY_ADMIN_SOCKET` in a `0700 caddy`
  runtime folder; `admin off` was rejected because `systemctl reload caddy`
  (modules, domain rename) needs the API. Stage 7 proves both as the downloads
  account and reloads Caddy once.
- **Relayed from the host itself (found by the v2-154 review):** Caddy's
  tailnet listener is reachable from local programs too, so the socket alone
  still let the downloads account reach the root backend through Caddy
  (reproduced: HTTP 200). A request that carries Caddy's X-Forwarded-For is now
  accepted only from a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48)
  that is not one of the server's own (a probe bind succeeds only for local
  addresses; loopback/link-local always count as local). Caddy overwrites the
  client's header, so it cannot be forged. Stage 7 proves the 403 as the
  downloads account and runs its own backend check over the socket. The probe
  does not reserve a port (`IP_BIND_ADDRESS_NO_PORT`) and only
  `EADDRNOTAVAIL` counts as "not local": port or descriptor exhaustion caused
  by a local attacker rejects the request instead of letting it through.
  `net.ipv4.ip_nonlocal_bind=1` would make every client look local (Konsol
  refuses everything); the installer never sets it.
- **WebDAV logins:** the per-IP rule (5/60 s → 300 s) now also covers the
  Tailscale listener, keyed on Caddy's header; local probes share one key and
  still receive the uncounted 401 challenge. A per-share, per-listener budget
  (100 failures/hour) closes that share for an hour to addresses that have not
  logged in since the service started, so distributed guessing is bounded
  while the connected recipient keeps working. A wrong user, paused or unknown
  share costs one scrypt check (decoy record), closing the timing oracle. The
  one-hour lock and forgetting known addresses on restart are accepted
  trade-offs; a Konsol flag is left to the planned health card.
- **Disk reserve:** WebDAV PUT/COPY and Files uploads refuse (507) before and
  while writing when free space would drop under min(5 GiB, 10%). The review
  suggested max(5%, 5 GiB); a flat 5 GiB protects journald/apt/state on large
  disks without idling tens of GB, and 10% keeps small disks usable.
  qBittorrent and archive jobs are outside this reserve.
- **unrar sandbox:** the Files unit adds `IPAddressDeny=any` with loopback
  allowed, `SystemCallFilter=@system-service`, `ProtectProc=invisible`,
  `PrivateIPC` and `MemoryDenyWriteExecute`. This blocks direct egress and the
  Caddy tailnet path, not loopback services: dnsmasq (which forwards when Konsol
  DNS forwarding is on), resolved on Ubuntu and the password-protected
  qBittorrent WebUI remain reachable. A separate network namespace for the RAR
  helper is left for later.
  - **Amended (2026-10-05):** since DD-217 qBittorrent's interface is a container
    publication on loopback, not a host socket. A uid-1000 unit with this address
    filter got no answer from it on nrm (control without the filter: HTTP 200), so
    only host loopback services such as dnsmasq remain reachable.
- **Request smuggling (pre-existing, found by the review):** the root backend
  answered rejected POSTs without reading their body on a keep-alive
  connection, so a body hidden in a cross-site text/plain POST was parsed as a
  second request that passed the CSRF gate (and could forge the client
  address). It now closes the connection after every error and whenever a
  request body was not fully read, as the Files backend already did.
- **WireGuard:** a template drop-in orders `wg-quick@` after
  `master-firewall.service` and runs `master-firewall --check` first, as Caddy
  does. Without owned rules the default FORWARD policy is open and DD-177's
  private-destination block does not exist. A network that fails for this
  reason is reopened by `refresh-tailnet-config` once the check passes.
- **Not changed:** qBittorrent's own sandbox, the Files backend's loopback TCP
  (uid 1000 already owns its data), HTTP on WAN (DD-179), Konsol identity.
- **Amended by DD-267 (v2-250):** unrar no longer runs on the server (Konsol's archive jobs were
  removed); the Files unit keeps this sandbox for the files and requests the browser sends it.
- **Amended by DD-272 (v2-255, the rebuild):** qBittorrent is gone; the socket, peer-credential and
  relayed-host checks, the login budgets, the disk reserve, the smuggling fix and WireGuard's firewall-first
  order hold.

### DD-179: Per-folder HTTP WAN opt-in with separate admission budgets (v2-153)

- **Amended by DD-190/DD-192:** HTTPS is optional; connection policies are
  independent in schema 4, both may be off, and valid schema 3 converts safely.
  The shared-policy/schema wording below records the earlier implementation.

- **Changed in v2-158:** the schema-2 registry migration is removed; only a
  schema-3 `webdav.json` is accepted. New shares still default to Tailscale only.

- **Decision:** keep HTTP as explicitly requested. A folder selects Tailscale,
  WAN IPv4 or both; schema-2 migration/new shares are Tailscale-only. Adding WAN
  requires explicit plaintext-risk consent; TLS and provider/NAT automation are
  not implied. The same account, ID, permissions and expiry serve both addresses.
- **Boundary:** Caddy binds an explicit WAN IP only when needed, proxies only
  `/s/*` to a distinct loopback address on the same port, and overwrites the
  real-client-IP header. Listener scope decides access before credentials/file
  IO; forwarded headers cannot turn a WAN request into a Tailscale request.
- **Limits:** 5 failures/60s blocks the IP for 300s; bounded 4096-entry history,
  4 concurrent scrypt checks; 8 WAN backend connections, 4 requests/IP, 16 separate
  tailnet slots, 30s WAN idle timeout. Edge TCP connlimit is 16/IP and 64 total,
  before manual allows; denials remain effective. These are not bandwidth caps.
- **Lifecycle:** locked atomic registry plus private pending snapshot; failed
  publication rolls back. A narrow 30s expiry/recovery timer removes the last
  expired WAN projection; unchanged projections do nothing. Immediate request
  expiry remains in the unprivileged handler. No broad reconcile engine.
- **Trade-offs:** HTTP reveals credentials/content on the internet; account
  edits still interrupt all DAV streams and reset in-memory attempt blocks.
  Conntrack can retain closing sockets temporarily. TLS and native-client/fresh
  Ubuntu acceptance remain separate from this initial disposable-host test.
- **Amended by DD-272 (v2-255, the rebuild):** the schema-3 conversion is gone too; only schema 4 loads.

### DD-1: Atomic staging-chain swap for firewall rules

- **Decision:** Firewall updates build a brand-new, randomly named chain
  fully, then splice it in and only afterward tear down the old one,
  instead of flushing and rebuilding the canonical chain in place.
- **Context:** `install.sh:1336-1390` (`create_staging_chain`,
  `activate_staging_chain`) and the mangle-table equivalent.
- **Rationale:** Flushing `MASTER-DOCKER`/`MASTER-TS-FORWARD` in place
  would leave a window where the chain is empty — either briefly
  fail-open (dangerous) or briefly fail-closed (drops exit-node traffic).
  The staging-chain-then-rename approach keeps the previous, complete rule
  set live until the new one is fully ready.
- **Trade-off:** More complex code (stale-chain cleanup, `$RANDOM`-based
  naming) than a simple flush-and-rebuild, but avoids any exposure window.

### DD-6: Fail-closed masking for optional DNS/Caddy services

- **Decision:** `dnsmasq` and `caddy` are installed already `mask`ed, and
  only `unmask`ed after their generated configuration has been validated
  (`dnsmasq --test`, `caddy validate`).
- **Rationale:** Prevents the packaged default (wildcard-listening)
  configuration from ever being reachable — even transiently across a
  reboot mid-install — before the Tailnet-only configuration is confirmed
  good.
- **Trade-off:** Adds bookkeeping (capturing and restoring prior
  mask/enable/active state in the `EXIT` trap) but is necessary for the
  security guarantee to hold across a failed or interrupted install.

### DD-11: UDP GRO forwarding is applied once, not continuously reconciled (2026-07-28)

- **Decision:** `tailscale-udp-gro.service`'s one-time Stage 2 setup
  (helper script + oneshot systemd unit, re-applied at every boot) is
  kept, but the ~54 lines that used to make `master-network-reconcile`
  detect and repair GRO drift every 5 minutes were removed.
- **Context:** `install.sh:830-940` (setup); the removed reconcile logic
  previously lived around where `all_critical_state_healthy()` is now
  defined in the `master-network-reconcile` heredoc.
- **Rationale:** UDP GRO forwarding is a pure throughput optimization for
  Tailscale's exit-node traffic — it never affects connectivity, only
  performance under load. It was already excluded from
  `all_critical_state_healthy()`, so its drift never affected any
  pass/fail postcondition; the only thing continuous reconciliation
  bought was auto-fixing a drift that isn't caused by a reboot (ethtool
  NIC flags don't persist across reboots on their own, which is why the
  one-time, per-boot setup step still exists and is not being removed).
  Resolves **L3** in `SECURITY_REVIEW.md`.
- **Trade-off:** If GRO settings are reset by something other than a
  reboot (rare — e.g. a NIC driver hot-reload, or certain virtualization
  live-migration events), the script no longer notices or fixes this
  within 5 minutes. It will be re-applied on the next reboot or the next
  `install.sh` re-run instead. Accepted by the user as a reasonable trade
  given GRO is throughput-only.
- **Side effect caught during this change:** two variables
  (`ETHTOOL_BIN`, `CURRENT_WAN6_IF`) inside the `master-network-reconcile`
  heredoc were only ever used by the removed GRO check, and became dead
  code. `shellcheck install.sh` did **not** flag them, since it cannot see
  inside heredoc bodies (see **H4**) — this had to be caught by manual
  review, a concrete illustration of why H4 is a real gap and not just a
  theoretical one.
- **Amended 2026-07-29 (first pass) — the unit is checked again.**
  Reconcile reads `tailscale-udp-gro.service`'s `ActiveState` and restarts
  it (15-minute cooldown via the existing `restart_budget_available`
  stamp) when it is not active.
- **Amended again 2026-07-29 (second pass) — the flags are checked too,
  because live testing showed the unit check alone proves nothing about
  throughput.** The fault-injection run made the gap concrete: after
  `systemctl stop tailscale-udp-gro`, `ethtool -k eth0` still reported
  `rx-udp-gro-forwarding: on`. Stopping the unit does not undo the flags,
  so a unit-only check verifies bookkeeping rather than the optimization
  it exists to protect. Reconcile now also runs `gro_flags_ok()` against
  `CURRENT_WAN4_IF` (already computed for address-drift detection) and
  repairs on either signal. `ETHTOOL_BIN` is reinstated for this — the
  variable this decision originally noted as dead code.
  - **What is still *not* re-added:** the removed logic polled both the
    IPv4 and IPv6 default interfaces and reimplemented the helper's apply
    path. The new check reads the IPv4 WAN interface only and never
    applies anything itself — repair is always `systemctl restart`, so
    systemd stays the single execution path and the unit's state keeps
    reflecting reality. That is why this is ~15 lines rather than the ~54
    that were removed.
  - **Everything the check cannot evaluate is treated as healthy:** no
    `ethtool` binary, no detected WAN interface, a driver that does not
    report the two features, or one that reports them `[fixed]`. This
    mirrors the helper, which exits successfully in exactly those cases,
    so the two cannot disagree and produce a restart loop.
  - Reported as `gro_flags=` alongside `gro_unit=` in `--check`; both stay
    outside `all_critical_state_healthy()` and the exit code.
- **The gap that motivated the amendment.** The unit is `Type=oneshot`
  with `Restart=no`. If it fails at boot — the exact case Stage 2 already
  anticipates, where the network is not ready yet and `install.sh` prints
  "reconcile yeniden deneyecek" and calls `reset-failed` — then nothing
  retried it. It stayed `failed` until the next reboot or `install.sh`
  re-run. The unit file's own comment claimed reconcile retried every five
  minutes, which had been **false since this decision removed that code**;
  that stale comment is corrected in the same change.
- **Placement detail worth knowing.** The repair runs *before* the
  `all_critical_state_healthy()` early `exit 0`, because otherwise a
  healthy system would return before ever reaching it. It is still
  excluded from that function and from the exit code: a GRO failure is
  throughput-only and must not make `--check` report an unhealthy host.
  It is reported as `gro_unit=` in `--check` output.

### DD-17: Nothing persists firewall rules to disk (2026-07-29)

- **Decision/observation:** no `iptables-persistent`, no `/etc/iptables`,
  and `nftables.service` left disabled. The complete rule set is rebuilt
  from scratch on every boot by `docker.service` (its own chains),
  `tailscaled` (`ts-*`) and `docker-tailscale-fw.service` (`MASTER-*`).
- **Confirmed 2026-07-29:** packet counters reset across a reboot, proving
  the rules are new objects rather than a restored dump, and the rebuilt
  set matches the previous one apart from Docker's container-IP churn
  (DD-16).
- **Rationale:** a persisted dump would be a second source of truth that
  could drift from `install.sh`, and would restore stale addresses at boot
  before the helpers had a chance to detect the current ones. Rebuilding
  is slower by roughly a second and always correct.
- **Consequence for failure analysis:** if the firewall helper ever fails
  to run, the host does not fall back to an older policy — it has *no*
  managed policy until the helper succeeds. That is why
  `docker-tailscale-fw.service` failing triggers reconcile via
  `OnFailure=` immediately rather than waiting for the 5-minute timer.

### DD-18: UDP socket buffer ceilings are floored by the installer, and they are a Tailscale setting — not a WireGuard one (2026-07-29)

- **Decision:** Stage 2 writes `/etc/sysctl.d/99-master-stack-netbuf.conf`
  with `net.core.rmem_max` / `wmem_max` set to
  `max(current_value, 16 MiB)`. `rmem_default` is deliberately left alone.
- **v2 realignment (2026-08-06, `v2-12`):** Early v2 had hardcoded
  `7500000` in `99-master-tailscale.conf` after `apt install tailscale`.
  That under-shot the legacy floor and violated M11 ordering. v2 now
  matches this decision again via `apply_udp_netbuf_floor` before the
  Tailscale package install; forwarding stays in a separate conf file.
- **Why it was needed:** on the live host both values were already 64 MiB
  — but from `/etc/sysctl.d/99-nc-kernel.conf`, a **file shipped by the
  VPS provider's image**, not by this installer. Nothing in `install.sh`
  set them. On any host without that file they fall back to Debian's
  default of 208 KB.
- **Who actually benefits — and the mis-attribution that produced this
  entry.** This was first proposed as a *WireGuard* optimization. That was
  wrong, and measurement is what caught it. Kernel WireGuard (what
  `wg-easy` uses) attaches an `encap_rcv` callback to its UDP socket;
  `udp_queue_rcv_one_skb()` hands the packet to that callback **before**
  the socket receive queue is involved, so `rmem_max` never gates its data
  path. The evidence, taken inside the container's netns after 6.19 GiB of
  real peer traffic:

  ```
  Udp: InDatagrams 5074319 ... RcvbufErrors 0  SndbufErrors 0  MemErrors 0
  /proc/net/udp  00000000:FE93 (port 65171 = wg0)  rx_queue=00000000  drops=0
  ```

  The setting matters for **Tailscale**, which is *userspace* WireGuard
  (`wireguard-go`) and does read from a UDP socket: `tailscaled` was
  observed holding `rb14680064` (14 MiB). At Debian's 208 KB ceiling that
  request would have been clamped ~70× smaller, silently costing
  exit-node throughput. Since being a Tailscale exit-node is this host's
  primary function, the finding survived — it just changed owner.
- **Why raising a ceiling is safe here, and why the qBittorrent
  experience does not apply.** `mem_limit`/`cpus` are cgroup ceilings that
  *constrain*: hitting one takes throughput away, which is exactly what
  happened in **M1**. `rmem_max` is the opposite kind of ceiling — it
  allocates nothing and only sets the largest value a process may request
  via `setsockopt(SO_RCVBUF)`. Raising it cannot slow anything down; it
  can only stop clamping. `rmem_default` *is* applied to every socket that
  does not ask for a size, so touching that one would have raised baseline
  memory use across the system — which is why it is excluded.
- **Raise-only, never lower.** The value is computed as a `max()` against
  whatever is already in effect, so a provider that sets 64 MiB keeps it
  and a re-run is idempotent. Simulated across the Debian default, a
  provider 64 MiB, an exact-floor value, and malformed/empty input.
- **Not reconciled, and that is deliberate.** Unlike ethtool flags, a
  `sysctl.d` file survives reboots by construction — the file on disk *is*
  the guarantee, so there is nothing for a 5-minute loop to repair. This
  is the same reasoning as DD-11, applied to a setting that happens to be
  persistent rather than volatile.
- **Known limitation:** `sysctl.d` applies files in lexical order, so a
  provider file sorting after ours that sets a *lower* value would win.
  The `max()` handles the realistic case (provider sets it higher); the
  inverted case is accepted as exotic and is not defended against.

### DD-19: The Tailscale login stays in Stage 2 — reordering it was tried, measured, and reverted (2026-07-29)

`install.sh` has exactly one step that blocks on a human: `tailscale up`
prints a `login.tailscale.com` URL and waits for the browser flow. It sits
in the middle of Stage 2, behind `apt-get full-upgrade` and two package
installs. A user reported it as "the link falls behind, I can't see it; it
only shows up after a very long wait", and a reordering was built and
shipped as `v1.1-1`: TUN check, Tailscale repo, sysctls, package install,
daemon start and login all moved into Stage 1, with `full-upgrade` moved
behind them. **It was reverted the same day.** Keep this entry so the
reordering is not proposed a second time on the same reasoning.

- **What the measurement showed.** On a clean install of `v1.1-1`:

  ```
  19:17:15  Stage 1 begins
  19:17:25  login banner on screen        (+10s, was ~4-6 min)
  19:17:25  control: RegisterReq sent
  19:22:06  control: AuthURL is https://login.tailscale.com/a/...
  ```

  The reorder did exactly what it was designed to do — the script reaches
  the login in ten seconds instead of minutes. It did **not** fix the
  complaint, because **4m41s of the wait is Tailscale's control plane
  taking that long to answer the first `RegisterReq`**, and nothing in
  `install.sh` influences that. The URL reached the terminal in the same
  second `tailscaled` received it, which also disproves the buffering
  hypothesis for good: `tee`'s stdout is fd 5 (`/dev/tty`), glibc
  line-buffers it, and delivery is immediate.
- **The network was eliminated as a cause.** IPv4 and IPv6 both reached
  `controlplane.tailscale.com` in ~25 ms, 1500-byte frames passed `-M do`
  on both stacks (no PMTU blackhole), and the TCP connection to the
  control plane was `ESTAB` with an empty queue the whole time.
  `tailscaled` logged nothing between `19:17:30` and `19:22:06`; it was
  simply waiting.
- **Why it was reverted.** The user's call: the reorder bought ~4-6
  minutes of apt work moved behind the login while leaving the dominant
  ~4m41s untouched, so it did not solve the reported problem.
- **The `RegisterReq` latency is control-plane variance, and a warm-up
  race was ruled out.** A V1 install run 22 minutes later on the same
  host, with the original ordering, produced:

  ```
  19:39:47  Starting tailscaled.service
  19:39:48  health(warnable=warming-up): error: Tailscale is starting.
  19:39:48  StartLoginInteractiveAs("root")
  19:39:48  control: RegisterReq: fup=false
  19:39:53  health(warnable=warming-up): ok
  19:39:54  control: RegisterReq: got response; authURL=true
  ```

  **6 seconds instead of 4m41s** — and note that the original ordering
  issues `LoginInteractive` one second after the daemon starts, *inside*
  the same warm-up window. An earlier draft of this entry claimed the GRO
  block gives the daemon "3-6 seconds to settle" that the reorder removed;
  that is wrong, and this measurement is what disproves it. Both orderings
  log in during warm-up, so warm-up cannot explain the difference. The
  4m41s was Tailscale-side variance, not something either ordering
  caused.
- **What a future attempt would have to beat.** With the control-plane
  latency established as variable and usually small, the only thing left
  for a reorder to buy is the apt time ahead of the login — real on a
  genuinely fresh host, near-zero on a re-install (the V1 run above
  completed Stage 1 in 7 seconds because `full-upgrade` and the packages
  were already current). Measure that on a cleanly reimaged host before
  proposing the restructuring again.
- **Separable ideas that did not cause the revert.** The framed login
  banner (bell + bold-cyan frame closing *before* the URL, so the link is
  the last thing on screen) and the Stage 0 heads-up are independent of
  ordering and could be re-applied on their own. So was the **M11** sysctl
  ordering defect, which the reorder happened to fix as a side effect and
  which the revert reintroduced — it was then fixed on its own in `V1-1`
  by moving the netbuf block ahead of `apt-get install -y tailscale`,
  without any of the Stage 1/2 restructuring.
- **A packaging fact both orderings have to respect.** Debian's
  `tailscale.postinst` runs `deb-systemd-invoke restart
  'tailscaled.service'`, so the daemon starts inside `apt-get install -y
  tailscale`; the script's own `systemctl enable --now tailscaled` is a
  no-op. Verified 2026-07-29: `dpkg configure tailscale` 19:17:24,
  `systemd: Starting tailscaled.service` 19:17:24, `status installed`
  19:17:25. This makes the intuitive "install Tailscale first, tune for it
  afterwards" ordering wrong for anything that must be in place before the
  daemon opens its UDP socket — `net.core.rmem_max` in particular. It does
  not apply to `ip_forward`, which is read dynamically and only needs to
  be set before `tailscale set --advertise-exit-node`.

### DD-24: Network steps get a bounded retry and a mandatory timeout (2026-07-31)

- **Decision:** every network-dependent step in `install.sh` runs through
  `retry_network` — three attempts, an explicit per-attempt `timeout`,
  5s/15s backoff. Applied to `apt-get update`, the three keyring/repo
  fetches, and `docker compose pull`. Not applied to
  `apt-get full-upgrade` or `apt-get install`.
- **The timeout is the point, not the retry** — the reverse of how the
  finding (L8) was originally framed. What prompted it was a Docker Hub
  502 during `docker compose pull`, and a retry does fix that. But
  reading the surrounding code moved the priority: the script runs under
  `systemd-inhibit --what=shutdown:sleep --mode=block` and holds the
  `flock` it shares with `master-network-reconcile`. A hung download
  therefore blocks shutdown *and* prevents the 20-minute reconcile timer
  from running, with no bound at all. The 502 failed loudly and safely —
  install stopped, re-run succeeded. A hang would have failed silently
  and held two locks while doing it.
- **No error classification, deliberately.** The first design sketched
  matching stderr to decide what was retryable. It is unnecessary:
  permanent failures (`manifest unknown`, `unauthorized`, a full disk)
  return within seconds, so three blind attempts cost them roughly 20s of
  backoff and then the same clear error. Only transient faults and hangs
  consume meaningful time, and those are precisely what we want retried
  or bounded. String-matching upstream error text would also be locale-
  and format-dependent — fragile, for no gain.
- **Budgets measured, not guessed** (2026-07-31, netcup host): cold
  `docker compose pull` 10.9s for 885 MB across three registries, warm
  pull 3.2s, `apt-get update` 0.9s, keyring fetches 36–127 ms. Bulk gets
  300s then 180s (~27× the measured cold pull); small fetches 60s then
  30s. A link would have to be ~27× slower than this host for a legitimate
  pull to be cut — and even then the operator gets a timeout message
  naming the budget rather than a silent stall.
- **Why apt transactions are excluded:** `full-upgrade` and `install`
  drive dpkg. Interrupting one mid-transaction and reissuing it is a
  different problem class, and it interacts with the `--force-confdef
  --force-confold` handling. Wrapping them would relocate the risk rather
  than reduce it. `apt-get update` is wrapped because it is genuinely
  idempotent.
- **The Caddy GPG fetch was restructured** rather than wrapped as-is: it
  used to be `curl … | gpg --dearmor`, and retrying the whole pipeline
  would also retry the local dearmor step, which can never be fixed by
  retrying (bad input is bad three times). The download now goes to a
  temp file inside the retry, and `gpg` runs once outside it.
- **All four control-flow paths are verified**, and the design note that
  preceded this entry was wrong to claim otherwise. It said the recovery
  path — transient failure followed by success — could not be tested
  deterministically without a real flaky network. A stub that fails once
  and then succeeds reproduces it exactly. `test/retry_network.bats`
  covers first-attempt success, exhaustion, timeout (asserting `124` and
  that the message differs from an ordinary failure), recovery, and
  argument pass-through. The suite self-skips where GNU `timeout` is
  absent, so it skips on the macOS workstation and runs for real on the
  Debian target — where the full suite passes with zero skips (62 cases at
  the time; 74 after the `M7` coverage correction later the same day).

### DD-37: The interactive Tailscale login recovers by timeout, not by diagnosing the failure (2026-08-02)

The installer used to run a bare `tailscale up` and wait forever. On
2026-08-02 a real install wedged there and nothing in the script noticed.

**The failure.** The daemon generates a nodekey, gets an auth path
(`/a/<id>`) bound to it from the control plane, and long-polls that path.
A *new* registration for the same node — which is exactly what restarting
the installer causes — or completing an *older* link in the browser
invalidates the pending path, and the poll returns `410: auth path not
found`. What makes it unrecoverable is the next line:

```
control: doLogin(regen=false, hasUrl=true)
```

`regen=false`: the daemon retries the **same dead path** forever instead of
generating a new key. So one 410 wedges the login permanently, `tailscale
up` blocks indefinitely, and — the part that misleads the operator —
`tailscale status` keeps printing the dead link as though it were live.
The reported symptom was "I logged in but it is still waiting."

Measured on the host: two separate links, each dead ~13 seconds after being
issued, four 410 events, the install stuck until it was killed by hand.
`tailscale logout` did **not** clear it — the daemon still returned the same
dead URL afterwards. Only `systemctl restart tailscaled` cleared it, which
is why recovery is built on the restart.

**The fix deliberately does not diagnose anything.** Three earlier versions
tried to detect the wedge from `journalctl`, and all three were wrong in
different ways. Each was caught by running the function against the real
journal, not by reading it:

1. *"A 410 appeared, therefore wedged."* Wrong — a 410 is part of the
   **successful** flow too. When the operator completes the browser step
   the control plane retires the auth path, the in-flight poll takes a 410,
   and the daemon immediately re-registers and gets `machineAuthorized=true`.
   All within the same second, measured at 18:12:49.
2. *"A 410 with no recovery after it."* The check was
   `journalctl … | grep -q`, and under `pipefail` `grep -q` exits on first
   match, `journalctl` takes SIGPIPE, and 141 becomes the pipeline's status
   — so a **found** match reported failure. Intermittent, because it
   depended on whether journalctl had finished writing.
3. *"No recovery after the last 410", with no upper bound.* A later,
   unrelated login's success counted as recovery for an earlier wedge.

The direction of the false positive is what settled it: wrongly declaring a
wedge kills a login that is one second from succeeding, restarts the daemon
and forces the operator to authenticate again — the fix would manufacture
the very failure it exists to repair. Three wrong iterations were treated as
evidence that the diagnosis itself is fragile, not that the third attempt
needed a fourth.

**What replaced it is dumber and therefore safer.** If the login has not
completed within `TAILSCALE_LOGIN_TIMEOUT` (300s), for *any* reason, the
daemon is restarted and a fresh link is printed, up to
`TAILSCALE_LOGIN_ATTEMPTS` (3). This covers the wedge and every other stall
class, and its worst failure mode is "the operator was handed a new link".
The retry banner says the previous link is dead and that opening an old tab
will kill the new one, since that is what produces the 410 in the first
place. After three attempts it prints the manual recipe, including the
non-obvious part: **`logout` is not enough, restart the daemon.**

**Verified before shipping.** The retry machinery was exercised against
stub `tailscale`/`systemctl` binaries: a login that never completes
produced two links, two `systemctl restart tailscaled` calls, the
"previous link is void" banner between them, and the manual recipe at the
end. The success path was tested the same way — it returns as soon as
`tailscale up` exits, with **no** restart, and streams the URL to both the
terminal and the log. The live success path itself was exercised on a real
from-scratch install the same day.

> **Amended by DD-42 / Q1-21.** The live `login-state` shape was later
> observed twice with two distinct nodekeys, so early recovery no longer
> requires guessing. The timeout remains the unknown-state fallback; only the
> measured, persistent LocalAPI signature can bypass it.

### DD-42: Persistent Tailscale 410 is classified from LocalAPI, never the journal (2026-08-02)

DD-37 deliberately rejected three journal-based attempts to identify a dead
interactive-login auth path. The rejection remains correct: a 410 also occurs
inside a successful authorization, journal producer/consumer timing caused a
separate SIGPIPE inversion, and an unbounded window let an unrelated later
success satisfy an earlier failure. A false positive restarts a daemon whose
login may be one second from succeeding.

Q1-21 changes the evidence, not that safety rule. A later clean-image R2.5 run
produced two independent failures without an installer restart. The first
nodekey received its link and entered the dead state 27 seconds later; the
second did so after 42 seconds. In both cases `tailscale status --json` exposed
the same simultaneous state: `BackendState=NeedsLogin`, `Self.Online=false`,
empty `Self.ID`, no Tailscale IP and a `Health` entry containing `http 410:
auth path not found`. The admin console showed an offline record because the
browser side had created/authorized one, but the daemon had never received a
usable machine identity. Restarting only tailscaled and issuing a third link
then produced a non-empty node ID/IP and `Running/Online`; the install finished
7/7.

That structured state is now a named classifier. One sample is still not a
decision: the main loop requires three consecutive samples, two seconds apart,
and resets the count on `pending`, `unknown` or successful state. Thus the
known successful transient 410 cannot survive the persistence gate. A
confirmed dead path terminates only the waiting `tailscale up` child and uses
DD-37's existing daemon restart/fresh-link path immediately. The 300-second
timeout remains unchanged for every state that does not match exactly, so
operator thinking time and unknown control-plane delays are not shortened.

Success is also stronger. Exit code zero from `tailscale up` is followed by a
15-second LocalAPI grace and is accepted only with `Running`, online, a
non-empty node ID and at least one Tailscale IP. Failure of that postcondition
uses the same bounded retry instead of allowing the later Stage 2 probe to be
the first place the inconsistency appears.

> **Amended by `Q1-22` (2026-08-02).** The postcondition stays; its *remedy*
> does not. Sending a failed 15-second grace into the bounded retry restarts
> the daemon and demands a second browser authorization — for a login that
> already succeeded, since `tailscale up` returned zero. That is DD-37's
> false-positive class arriving through a different door, and this time the
> door was narrower than the one already behind it: the very next block in
> Stage 2 waits **180 seconds** for the same condition (`tailscale ip -4` plus
> `tailscale_is_online`). Two gates for one condition, and the strict one held
> the destructive remedy.
>
> The goal above — surface the inconsistency here rather than letting a later
> probe be the first to mention it — was right, and is kept: the grace window
> now prints an explicit note when it expires. What changed is that it returns
> **success** and lets the 180-second check adjudicate. The reasoning is that
> a node which will not come online after an accepted login has a connectivity
> problem, not an authentication one; a fresh browser link cannot fix it,
> while the 180-second wait either resolves it or fails with a clear error.
> The 15 seconds is now a fast path, not a ceiling.
>
> Covered by a fourteenth Bats case, mutation-verified: it fails against the
> `Q1-21` behaviour (`status` non-zero, daemon restarted, a second `tailscale
> up` demanded) and passes against `Q1-22`.

Thirteen Bats cases cover the live JSON signature, incomplete and malformed
states, command failure, a completed node carrying a transient 410 line, the
three-sample early restart and a one-sample 410 followed by success with no
restart. The full local wrapper is clean. The real input signature and the
equivalent manual child-termination/restart path are live measurements; the
exact automatic Q1-21 branch remains deliberately unclaimed until a later
fresh authorization run exercises it. At the operator's explicit request the
same installer was exported untagged as an R2.6 manual-test candidate; that
packaging action does not change the pending live-verification claim.

### DD-43: Exit-node and Tailscale SSH are requested by `tailscale up`, then held by `tailscale set` (2026-08-03)

- **Decision:** the interactive login runs `tailscale up --advertise-exit-node
  --ssh` instead of a bare `tailscale up`, and the `tailscale set` call that
  follows gains `--ssh=true` alongside the flags it already carried. Tailscale
  SSH is now part of the node's steady state: `tailscale_prefs_ok()` requires
  `.RunSSH == true`, so the reconcile timer treats a lost `--ssh` as drift and
  repairs it with the same `tailscale set` invocation it already used for
  exit-node/netfilter drift.
- **Why both places, not one.** `tailscale up` runs **only** when
  `TAILSCALE_NEEDS_LOGIN` is 1 — a fresh node, an expired key, or a node
  deleted from the tailnet. On the ordinary re-run against an already-joined
  host it never executes. So it cannot be the only place these preferences are
  set without making them silently optional on every re-install. `tailscale
  set` runs unconditionally and is the idempotent path; `tailscale up` now
  merely asks for the same end state one step earlier.
- **A second reason to name the flags on `up`.** `tailscale up` refuses to
  silently revert non-default preferences: when the current profile has flags
  set that the command line does not mention, it errors and asks the operator
  to re-run mentioning them. On the re-login paths above the profile can
  already carry `--advertise-exit-node`, which a bare `tailscale up` would be
  proposing to drop. Naming the flags removes that failure mode rather than
  adding one.
- **The security trade-off, stated rather than assumed.** `--ssh` makes
  tailscaled answer SSH on the node's Tailscale address itself, authenticated
  by the tailnet's ACL `ssh` block rather than by the host's `authorized_keys`.
  It is reachable only from the tailnet — the same trust boundary that already
  governs every web interface in the bundle — and adds nothing to the
  internet-facing surface, which stays behind the fail-closed firewall. What it
  does change is that tailnet ACL policy, not the host's SSH configuration,
  becomes the thing that decides who gets a root shell. A new tailnet's default
  policy permits `autogroup:member` → `autogroup:self` as root with `check`
  (periodic browser re-authorization). An operator who does not want that must
  narrow the tailnet's `ssh` block; the installer deliberately does not edit
  account-level ACLs.

### DD-45: The firewall helper requires ip6tables instead of degrading toward it (2026-08-03)

- **Decision:** `docker-tailscale-fw` hard-fails at the top when
  `command -v ip6tables` finds nothing, before it takes its lock and before it
  touches a single chain. The three `[[ -n "$bin" ]] || return 0` early
  returns in `ensure_forward_prefix`, `apply_tailnet_guard` and `apply_ipv6`
  are gone, and `apply_ipv6`'s "DOCKER-USER missing → warn and skip" branch is
  now the same hard failure `apply_ipv4` already used.
- **Why:** the helper claimed two contradictory contracts. Four branches
  promised graceful degradation when IPv6 tooling was unavailable, and then
  `check_policy` — `check_ipv4_policy && check_ipv6_policy`, with
  `check_ipv6_policy` returning 1 outright on a missing binary — made the run
  exit 1 anyway. The graceful path could not lead anywhere except the same
  failure, so it bought nothing and cost a reader the time to work that out.
- **Why *require* rather than *skip*.** Stage 2 writes
  `net.ipv6.conf.all.forwarding = 1`. Without ip6tables there is no
  `MASTER-DOCKER`/`MASTER-TS-FORWARD` on the v6 side, so continuing would mean
  IPv6 forwarding enabled with no Tailnet isolation guard behind it — the
  exposure the helper exists to prevent. Failing closed is the only answer
  consistent with the rest of the file. In practice nothing changes: the
  `iptables` Debian package installed in Stage 1 provides `ip6tables`.
- **One branch was provably dead, not merely redundant.** `apply_ipv6`'s
  DOCKER-USER warning could never fire: `ensure_forward_prefix
  "$IP6TABLES_BIN"` runs first and returns 1 — under `set -e`, killing the
  helper — if that same chain is absent.
- **`check_ipv6_policy`'s own `[[ -z "$IP6TABLES_BIN" ]]` guard is deliberately
  kept.** It is **M5**'s remediation ("this must not be masked behind the
  generic policy-drift error") and it has a Bats case that calls the extracted
  function directly. The top-level guard makes it unreachable in production,
  but removing it would delete a security finding's test to save four lines,
  and the suite's function-extraction technique cannot test a top-level guard
  in its place. It stands as an independently verified precondition on the
  function rather than as dead code.
- **Measured, not assumed.** The embedded helper was extracted and run against
  a PATH containing stub `ip`/`iptables`/`flock` and **no** `ip6tables`. New
  behaviour: rc 1 in both `apply` and `--check`, the specific message, and
  **zero `iptables` invocations** — proven by an invocation log the stub wrote.
  Old behaviour under the same conditions: `--check` reached rc 1 only after
  address resolution and an `iptables` call, printing the specific message
  *and* the generic "politika sapmış" line; `apply` installs the full IPv4
  policy first, because the apply order is `ensure_forward_prefix →
  apply_tailnet_guard → apply_ipv4 → apply_ipv6 → check_policy`. The old
  `apply` run could not be driven to completion — the crude `iptables` stub
  answers every `-C` probe with success, which makes `remove_legacy_wide_rules`
  loop forever; that is the stub's defect, not the helper's.
  `./scripts/check-all.sh` clean at 176 cases, M5's case among them.

### DD-50: The installer has one definition of "online", and its waits count time rather than iterations (2026-08-04)

- **Decision:** `tailscale_is_online()` is deleted. Its three call sites in
  Stage 2 now call `tailscale_login_complete()`, which is JSON-backed. Both
  Stage 2 waits are bounded by a wall-clock deadline instead of an iteration
  count.
- **Why the old predicate had to go.** It decided from human-readable output:
  `tailscale status --self | head -n 1`, true when the line was non-empty and
  did not contain the substring `offline`. That is a locale- and
  format-dependent parse standing next to two JSON-based siblings, and it was
  the only one of the three with no test coverage at all.
- **It was not merely fragile — it could say yes when the answer was no.**
  With `BackendState=Starting` the self line prints and contains no "offline",
  so Stage 2's final 180-second gate could pass on a node that was not
  Running. `tailscale_login_complete` requires `BackendState == "Running"`,
  `Self.Online == true`, a non-empty `Self.ID` and non-empty
  `Self.TailscaleIPs`; the `Self.ID` clause is also the signal the surrounding
  code was already trying to infer from the journal for a node deleted in the
  admin panel.
- **Why the loops changed too.** `tailscale_login_complete` wraps
  `tailscale status --json` in `timeout $TAILSCALE_LOGIN_STATUS_TIMEOUT` (3
  seconds). Against a wedged daemon each probe costs seconds rather than
  milliseconds, so `for _ in $(seq 1 90); do …; sleep 2; done` would run for up
  to 450 seconds while its own error message says "180 saniye içinde". Both
  waits now compute a deadline from `SECONDS` — the idiom
  `tailscale_interactive_login` already uses — so the printed durations stay
  true whatever a probe costs. This also removes a smaller pre-existing
  inaccuracy: the old loops were never exactly 60 or 180 seconds either, since
  each probe's own runtime was unaccounted for.
- **Precondition checked, not assumed:** `jq` is in Stage 1's package list, so
  it is present at the first call site, which runs before the interactive
  login.
- **Two things the original audit note got wrong, corrected here.** It claimed
  the change takes three definitions to one; it does not. Reconcile's
  `tailscale_online()` lives in a separately generated script that cannot call
  an installer function, so **two** JSON-based definitions remain in two
  programs, and what is removed is the text-parsing one. The note also missed
  the loop-duration consequence entirely.
- **Reconcile's predicate is deliberately left looser** (`BackendState` and
  `Self.Online` only). It answers a different question — "is this established
  node still online", asked every twenty minutes — rather than "did
  registration complete". Tightening a steady-state health predicate is a
  separate behaviour change with its own blast radius and its own tests.
- **`tailscale status --self` still runs once**, purely to print which node was
  found. That is output, not a decision, and `test/tailscale_online_gate.bats`
  pins that exactly one use survives.
- **Verified by mutation, including the timing claim.** Five mutations were
  applied to install.sh and each was caught: restoring the text predicate and
  using it at the gate, reverting either wait to an iteration-bounded loop, and
  removing the `break` so the success path waits out the deadline. A fifth —
  moving the deadline 30 seconds later while keeping its shape — made the
  wall-clock case fail after ~33 seconds, which is what shows that assertion
  measures the bound rather than passing vacuously. `./scripts/check-all.sh`
  clean at 224 cases.

### DD-51: Stage 2 bounces the tailscaled daemon without bouncing the stack (2026-08-04)

- **Decision:** Stage 2 no longer enqueues dependency-carrying jobs against
  `tailscaled`. `systemctl enable --now tailscaled` became
  `systemctl enable tailscaled` followed by
  `systemctl is-active --quiet tailscaled || systemctl start tailscaled`, and
  the login retry loop's daemon reset became
  `systemctl restart --job-mode=ignore-dependencies tailscaled`.
- **What couples them.** Two drop-ins written later in the same run make
  `tailscaled` the runtime anchor of the whole stack:
  `tailscaled.service.d/98-master-stack.conf` declares
  `Wants=docker-tailscale-fw.service master-compose.service
  master-webdav.service` and `99-caddy-tailnet.conf` adds `Wants=caddy.service`;
  the same four units declare `PartOf=tailscaled.service` back. On a **fresh**
  install neither half exists yet when Stage 2 runs, so this is invisible. On a
  **reinstall** both already exist on disk, and every job Stage 2 enqueues
  against `tailscaled` reaches all four.
- **Two different mechanisms, which is why one fix would not have done.** A
  *start* job pulls the `Wants=` set; a *restart* job propagates through
  `PartOf=`, and that clause lives on the four stack units, not on `tailscaled`.
  Deleting the drop-in would therefore have silenced the first and left the
  second untouched. `--job-mode=ignore-dependencies` suppresses both, which is
  why the restart path needs nothing else.
- **Measured, not reasoned.** On the test host, with the reconcile timer stopped
  and reconcile confirmed inactive so it could not be the cause:
  `systemctl enable --now tailscaled` against an *already active* `tailscaled`
  started `caddy` and `master-webdav` from inactive. The same command returned in
  0 seconds while `master-compose` was still `activating`, so the pulled jobs are
  **not** waited on. And `systemctl restart --job-mode=ignore-dependencies
  tailscaled` restarted the daemon while leaving `caddy`/`master-webdav`
  inactive and `master-compose`'s `ExecMainStartTimestampMonotonic` unchanged.
- **Why non-blocking is the bad news, not the good news.** The pulled units run
  *concurrently* with the rest of the installer. `master-compose`'s `ExecStart`
  (`docker compose up -d --remove-orphans --wait`) and its `ExecStartPre`
  (`master-compose-ipv4`, which rewrites `/root/docker/.env`) take no lock —
  unlike reconcile, which takes `master-stack.lock` with `flock -n` and defers
  with exit 75, and unlike `docker-tailscale-fw`, which has its own separate
  lock. So the installer's own `flock` on `/run/lock/master-stack.lock` does not
  exclude them. A background `docker compose up` against the *previous* version's
  `compose.yaml` therefore overlaps Stage 4 rewriting that file and Stage 5
  running its own compose commands on the same project — the same class as the
  `<id>_<name>` replace-name orphan recorded in `TODO.md`.
- **The case that actually bites is the repair reinstall.** When all four units
  are active, `enable --now` is a no-op for them; that is why every upgrade on
  the test host looked clean. The units are inactive precisely when someone
  reruns the installer *because* something is broken.
- **What the original audit note got wrong.** It named the login retry loop's
  `systemctl restart tailscaled` as the trigger and proposed
  `systemctl stop master-compose.service` before it. Three errors: that line runs
  only when a reinstall *also* needs a fresh login, while the unconditional
  trigger is the `enable --now` that runs on every single invocation; the
  affected set is four units including `caddy`, which is Stage 6, not "Stage 3/4
  units"; and stopping `master-compose` would not have helped, because the
  restart's `Wants=` pull starts it straight back and the other three units are
  not covered at all.
- **The operator recovery hint is deliberately left alone.** The message that
  prints `systemctl restart tailscaled && tailscale up` is advice for a human
  running it with the installer stopped, where pulling the stack back up is the
  entire point. `test/tailscaled_job_isolation.bats` distinguishes the two by
  requiring the guard only on lines whose first word is `systemctl`.
- **Verified by mutation.** Five mutations, each caught by a specific set of
  cases: restoring `enable --now` (cases 2, 3, 6, 7), dropping the job-mode flag
  (4, 8), splitting the restart into a `stop`/`start` pair (4, 8), and removing
  the drop-in's `Wants=` line (1, the case that asserts the coupling still
  exists). A sixth — moving the flag *after* the unit name — was measured on the
  test host and turns out **not** to be a defect: `systemctl` permutes its
  arguments and the job is isolated either way, so the test pins the flag
  reaching `systemctl` in one invocation rather than pinning argument order.
  `./scripts/check-all.sh` clean at 232 cases.

### DD-53: The media-tree ownership repair never dereferences (2026-08-04)

- **Decision:** Stage 4's `find "$DOWNLOADS_PATH/media" \( ! -uid 1000 -o
  ! -gid 1000 \) -exec chown …` now runs `chown -h`.
- **The defect.** `find` defaults to `-P`: it does not follow symlinks, it
  *reports* them. `chown` without `-h` dereferences whatever path it is
  handed. A symlink inside the media tree owned by anything other than
  `1000:1000` therefore satisfied the predicate and redirected the ownership
  change onto its target, anywhere on the host.
- **Measured before the fix, on the test host.** A root-owned
  `tree/innocent.mkv -> /tmp/d3/SENTINEL` left the symlink at `0:0` and moved
  the sentinel from `0:0` to `1000:1000`. After the fix the same fixture
  leaves the sentinel at `0:0`, moves the symlink itself to `1000:1000`, and
  still repairs a genuine `0:0` regular file — so the repair's actual job is
  intact.
- **Reachability was measured, not assumed.** The tree is bind-mounted into
  `qbittorrent` as `/downloads`; `docker exec qbittorrent id` reports
  `uid=0(root)` because the compose service sets no `user:`; and a symlink
  planted from inside the container appears on the host as `lrwxrwxrwx 1 0 0`,
  which is exactly the ownership the predicate selects. `1000` is the uid
  qbittorrent's own process runs under, so the target becomes a host file the
  container can then read or write. The trigger is an installer re-run, which
  this project does routinely.
- **Why `-h` rather than `! -type l`.** Skipping symlinks would leave a
  root-owned symlink in a tree that is otherwise uniformly `1000:1000`, and
  would leave the next reader to rediscover why. `-h` repairs the link's own
  ownership, which is what the loop was always trying to express, and removes
  the dereference as a class rather than excluding one case of it. On a
  non-symlink `-h` is a no-op, so the regular-file path is unchanged.
- **Deliberately out of scope:** `-xdev`. A separate filesystem mounted inside
  the media tree would still be walked. That is surprising but is not the
  same failure — it cannot be aimed at a chosen file — and bounding the walk
  is its own decision with its own blast radius.
- **Verified by mutation.** Three mutations, each caught by the case that
  claims it: dropping `-h`, moving `-h` after the owner spec where it no
  longer guards the first operand, and adding `! -type l` to the predicate —
  the last one confirms the "find selects the symlink" case measures
  selection rather than passing vacuously. The suite stubs `chown` on `PATH`
  and records its arguments, so the cases need no root and change no real
  ownership. `./scripts/check-all.sh` clean at 242 cases.

### DD-55: Every wait that promises a duration now measures one (2026-08-05)

- **Decision:** the four remaining waits whose error message names a number of
  seconds compute a deadline from `SECONDS` instead of counting iterations:
  Stage 2's tailscaled-socket wait, `master-compose-ipv4`,
  `master-network-reconcile`'s address-ready retry, and
  `master-webdav-serve`. This finishes what DD-50 started in Stage 2 and
  DD-52 continued in the firewall helper.
- **The rule, stated precisely.** Not "no `seq` loops" — the invariant is that
  *a loop must not count turns while its message promises seconds*. Several
  `for _ in $(seq 1 N)` loops in this file are correctly iteration-bounded and
  were deliberately left alone: `create_staging_chain` and
  `create_ts_guard_staging_chain` retry on a random-name collision and take no
  `sleep` at all, so turns are the right unit; and the postcondition retries
  after a repair (`tailscale_prefs_ok`, filebrowser health, WebDAV, Stage 7's
  probe) make no duration claim to be wrong about. A survey of all nine
  remaining sites found exactly one that qualified — the socket wait — which
  is why this revision fixes four sites rather than three.
- **Measured, on the two sites that are whole embedded scripts.** Both were
  extracted and run for real against a stub `ip` costing three seconds per
  probe, with their budget rewritten to three seconds. Each exits 1 in three
  to seven seconds and names the bound it honoured; an iteration-bounded loop
  under the same stub takes roughly four times as long, which is the
  separation the assertions measure. Lower bounds are asserted too, so a loop
  that never waited would fail rather than pass.
- **The messages now interpolate the bound** rather than repeating a literal,
  so the number printed and the number honoured cannot drift apart again —
  which is how all four got out of step in the first place.
- **One related loop was found and deliberately not changed.**
  `tailscale_daemon_ready` counts thirty turns around `tailscale status
  --json` with no `timeout` wrapper, so an unresponsive daemon makes each
  probe arbitrarily expensive. Its caller's message claims no duration, so it
  is not this defect; but it is the unbounded-probe half of DD-50's argument
  and is recorded in `TODO.md` rather than fixed here.
- **Two older tests pinned the shapes being replaced** and were updated to
  assert the new one: `reconcile_control_flow.bats`'s address-readiness case
  pinned `ADDRESS_READY_WAIT_SECONDS / 2`, and the new suite's whole-file
  backstop replaced an early draft that banned `seq` outright — which would
  have condemned the four legitimate loops above.
- **Verified by mutation.** Four, one per site, each caught by the case that
  claims it; the whole-file invariant independently caught two of them.
  `./scripts/check-all.sh` clean at 250 cases.

---

## Installer design decisions

The entries below describe the multi-file successor historically released
with `v2-*` version identifiers (see `docs/contract.md` and
`docs/architecture.md`). The active files now live under `Data/`.
They do not apply to the retired single-file monolith, which remains only in
Git history. They are numbered in the same sequence deliberately: a decision
that supersedes an earlier one should be findable next to it, not in a
separate document with its own numbering.

### DD-58: v2 abandons the single-file model — supersedes DD-9 (2026-08-05)

- **Decision:** v2 is a repository tree — one orchestrating `install.sh`,
  two libraries, four templates, four helper scripts and three systemd
  units — rather than a single script that carries its helpers as heredocs.
  DD-9 is superseded for the successor. At the time of this decision, the
  retired monolith kept its single-file model unchanged; DD-9 remains the
  accurate historical record of that file.
- **Rationale:** DD-9's trade-off line predicted this. The embedded scripts
  are invisible to `shellcheck install.sh` and `bash -n install.sh`, which
  is why `scripts/lint-embedded-scripts.sh` had to be written to lint
  string literals. At 5495 lines the mitigation stopped scaling: the file
  had 1179 comment lines removed in `Q1-24`/`Q1-25` partly because nobody
  read it in an editor, and three real bugs (**H1**'s regression, **H5**,
  **H6**) were reachable only through live execution because static review
  could not see into the heredocs. A file per responsibility gets all seven
  helpers under the normal linter with no custom tooling.
- **Replacement delivery model:** `git clone` (or a release tarball of the
  same tree), then `install.sh`. The curl-pipeable single artefact is
  the thing being given up, and that is the real cost of this decision —
  provisioning now needs the repository present on the host.
- **Trade-off accepted:** more files to keep in sync, and a class of bug
  that could not previously exist (a helper referring to a constant the
  installer never rendered). `config/defaults.env` as the single source of
  truth and the hard-error-on-unsubstituted-token rule in the renderer
  exist to bound that class.

### DD-59: The firewall owns two chains, named once (2026-08-05)

- **Decision:** `MASTER-INPUT` holds the host INPUT policy; `MASTER-DOCKER`
  holds the container policy reached through a single jump from
  `DOCKER-USER`. `MASTER-DOCKER-FILTER` is not used. The same two logical
  names are used for IPv4 and IPv6 — the tables are separate, so there is
  no collision — and both are declared in `config/defaults.env` and
  nowhere else. A chain name appearing as a literal in a second file is a
  defect.
- **Rationale:** Two sources proposed names (`MASTER-DOCKER` in
  conversation, `MASTER-DOCKER-FILTER` in `.cursor/rules/`), both as
  examples. The value is cosmetic but it is a single-source-of-truth value:
  the failure it prevents is a helper that creates one chain while the
  verification step looks for another, which fails open — an absent chain
  filters nothing.
- **A third chain was dropped.** `defaults.env` also carried
  `MASTER-TS-FORWARD`, inherited from v1's mangle-table chain. No clause of
  the v2 contract requires it and it was not part of the decided set, so it
  was removed rather than kept in case it turns out to be needed. If the
  firewall phase finds a genuine need for a `FORWARD`- or mangle-table
  chain, that is a new decision with an explicit name.
- **`MASTER-INPUT` is new in v2.** v1 filtered container traffic through
  `DOCKER-USER` but never wrote a host INPUT policy at all, so services
  listening on the host — WebDAV among them — were protected only by what
  they chose to bind to.
- **v2-3 (2026-08-06): `ts-input` must precede `MASTER-INPUT`.** Our
  INPUT jump must not shadow Tailscale's `ts-input` (UDP 41641 / spoof
  guards). `--check` asserts the order when the Tailscale chain exists.
- **v2-16 (2026-08-07): reorder without a gap.** The first
  `ensure_ts_input_precedence` deleted every `MASTER-INPUT` jump and then
  re-inserted it after `ts-input`, leaving INPUT briefly without our
  policy (default ACCEPT risk). Apply now inserts INPUT jumps after
  `ts-input` when present (`activate_named` / `ensure_jump`), and
  precedence repair uses insert-before-delete so a `MASTER-INPUT` jump
  always remains while wrong earlier jumps are removed.
- **v2-3: IPv6 INPUT must allow NDP/ICMPv6.** A terminal DROP of all NEW
  IPv6 (the first `apply_input6` shape) broke neighbor discovery for the
  provider's link-local default (`fe80::1` → `FAILED`), so IPv6 egress and
  Tailscale control-plane Happy Eyeballs paths hung while IPv4 stayed up.
  Essential ICMPv6 types are accepted before the WAN DROP.
- **v2-23 (2026-08-07): oneshot retry + DOCKER-USER wait.** Boot/Docker
  races where `DOCKER-USER` is briefly missing used to fail the oneshot
  once with no retry (`Restart=no`). The unit now uses `Restart=on-failure`,
  `RestartSec=2s`, and `StartLimitBurst=5` / `StartLimitIntervalSec=60`.
  `firewall.sh` waits up to 10s (`DOCKER_USER_WAIT_SECONDS`) for
  `DOCKER-USER` on both iptables and ip6tables before applying
  `MASTER-DOCKER`. No extra timer or recovery script.
- **v2-24 (2026-08-07): also `PartOf`/`WantedBy` `tailscaled`.** A
  Tailscale restart recreates `ts-input` but did not re-run firewall apply,
  so `MASTER-INPUT` ordering was not re-guaranteed. `master-firewall` now
  follows both `docker.service` and `tailscaled.service` stop/restart
  (Compose is never coupled). Expected after **DD-75**: `tailscaled`
  restart → firewall apply only; Caddy/WebDAV stay unless their address
  binding needs refresh.
- **v2-25 (2026-08-07): minimal `--check` content.** Beyond jumps and
  `ts-input` order, `--check` asserts IPv4 `MASTER-INPUT`/`MASTER-DOCKER`
  WAN DROP, WAN wg UDP ACCEPT, and WAN qBit TCP+UDP ACCEPT. Not a return
  to the old multi-flag reconcile surface.
- **v2-32 (2026-08-09): host INPUT no longer `Requires=docker`.** See
  **DD-75**.
- **v2-34 (2026-08-09): stronger invariants.** Exactly one jump, no
  staging leftovers, WAN if drift fail-closed, SSH + IPv6 TS UDP + NS/NA
  in `--check` (still not a reconcile surface).

### DD-60: dnsmasq binds loopback and `tailscale0`, and nothing else (2026-08-05)

- **Decision:** dnsmasq listens on `lo` and `tailscale0` with
  `bind-dynamic`. Not on WAN interfaces, not on ordinary LAN interfaces,
  never on an unbounded `0.0.0.0`, and it serves no DHCP. Records are
  interface-based (`interface-name=…,tailscale0`); the current Tailscale
  IPv4 is never written into the configuration.
- **Rationale for loopback:** the host must be able to resolve its own
  service names, and the installation must be able to verify DNS without
  borrowing a tailnet device to ask from. v1 bound `tailscale0` only, with
  `except-interface=lo`, which made the cheapest possible verification —
  `dig @127.0.0.1` — impossible.
- **Why the address stays out of the file:** `interface-name` resolves to
  whatever address the named interface currently holds, so destroying and
  recreating `tailscale0` requires no file to be regenerated. This is what
  lets **DD-61** leave dnsmasq alone entirely.
- **What a loopback query returns is an expectation, not a measurement.**
  Reading dnsmasq's documentation, `interface-name=NAME,tailscale0` should
  answer with the `tailscale0` address regardless of which interface the
  query arrived on — but this has not been observed on a real host, and the
  whole loopback-testability argument rests on it. It is therefore recorded
  as an acceptance test for the DNS phase, to be run on a clean Debian 13
  target: `dig +short NAME @127.0.0.1` must return the same address as
  `dig +short NAME @${TS_IPV4}`, and that address must be `${TS_IPV4}`. If
  the measurement disagrees — if a loopback query answers `127.0.0.1` or
  `NXDOMAIN` — the loopback listener stops being a test path and this
  decision needs revisiting, not a workaround.
- **Open implementation question, not a decision:** whether
  `systemd-resolved`'s stub listener already holds `127.0.0.1:53` on the
  target host. That is answered by looking at the host during the DNS
  phase.

### DD-61: `refresh-tailnet-config` restarts address-bound units and does nothing else (2026-08-05)

- **Superseded in part by DD-77 (2026-08-09):** host WebDAV no longer
  binds `${TS_IPV4}`; the live restart set is **Caddy only**.
- **Decision:** the helper reads the current Tailscale IPv4 and IPv6,
  compares them with `/etc/master-stack/state.env`, exits successfully
  without touching any service if they match, and otherwise updates
  `state.env` atomically and restarts the units that bind the address
  (originally Caddy and `master-webdav`; after DD-77, Caddy alone).
  Explicitly excluded: regenerating the dnsmasq configuration, restarting
  dnsmasq, restarting the Compose stack or any container, re-applying the
  firewall, cooldown stamps, drift flags, container recovery, and health
  repair of any kind.
- **Rationale:** this is the scope boundary that keeps v2 from regrowing
  `master-network-reconcile`, whose 1821 lines were one third of v1 and
  produced 25 drift flags, a stamp-based cooldown ledger and an image
  digest recovery path — none of which any requirement asked for. The rule
  that makes the small version sufficient is architectural rather than
  disciplinary: only address-bound consumers are restarted, because
  dnsmasq and the firewall are written against the *interface name*
  (**DD-60**) and (after DD-77) WebDAV binds loopback only.
- **Consequence for Caddy:** there is no rendered Caddy environment file.
  The drop-in reads `state.env` directly as its `EnvironmentFile=`, so the
  address exists in one place on disk and the helper has one file to
  update. The cost is that `state.env` must satisfy both `source` in bash
  and systemd's `EnvironmentFile=` parser: plain `KEY=value`, no quoting,
  no spaces around `=`, no expansion.
- **Consequence for a public IPv4 change:** it cannot be solved inside this
  helper without breaking the decision, because it would mean recreating
  containers. That remains an open question with a documented interim
  answer (re-run the installer).

### DD-64: Tailscale address refresh without a long-running watcher (revised 2026-08-07)

- **Decision (v2-26):** Drop `watch-tailnet-addr`. Address updates go through
  `refresh-tailnet-config` only: `WantedBy=tailscaled.service` (restart path)
  plus `refresh-tailnet-config.timer` (`OnBootSec=2min`,
  `OnUnitActiveSec=5min`). Installer disables/removes any leftover watch
  unit and sbin helper on re-run.
- **Context:** The netlink watcher and the five-minute timer both drove the
  same oneshot. Dual paths added always-on process cost for little gain
  once Tailscale restart already re-applies firewall and restarts
  Caddy/WebDAV (`PartOf=tailscaled`).
- **Rationale:** Prefer one refresh owner. Worst case for a silent CGNAT
  readdress without `tailscaled` restart is up to one timer interval before
  Caddy/WebDAV rebind — accepted for a simpler unit graph.
- **Supersedes:** The 2026-08-06 netlink watcher decision (sub-second IP
  change recovery via `ip monitor address`).

### DD-70: Portable export verifies SHA-256 and extracts atomically (2026-08-07)

- **Decision:** `export-installer.sh` records the runtime tarball SHA-256 only
  inside the `.command` (`PORTABLE_ARCHIVE_SHA256`). The launcher checks
  the hash after decode and again on the host before extract. Remote
  install unpacks into a temp directory, then moves the staged runtime into place
  (no `rm -rf` of the live tree until the new tree is ready to move).
  No separate `.sha256` sidecar is written.
- **Context:** A truncated scp/tar could leave the host without a usable
  installer tree mid-sync. An external sidecar duplicated the same digest
  without adding trust (it travels with the same file).
- **Rationale:** Hash catches corruption; staging extract avoids a window
  with no installer on disk. One deliverable keeps the Desktop/app
  surface a single double-clickable file.
- **Trade-off:** Slightly more remote disk during sync. External
  “checksum without opening the launcher” requires grepping
  `PORTABLE_ARCHIVE_SHA256` from the `.command` (or re-exporting).
- **Amendment (v2-64):** Deterministic pack uses `TZ=UTC` mtime
  `2000-01-01` and bsdtar `--no-xattrs --no-mac-metadata` (plus
  `xattr -cr` on the stage). Local `touch -t 197001010000` in TZ east of
  UTC lands before Unix epoch (stored as 0 → Debian “implausibly old”);
  Apple provenance xattrs became `LIBARCHIVE.*` pax keywords GNU tar
  does not understand. Reproducible hash stays; extract stays quiet.
- **Layout amendment (2026-09-02):** Repository and remote runtime files live
  directly under `debian-server-installer/`. The portable archive uses an
  `installer/` staging directory, atomically replaces the dedicated remote
  root, and starts `/root/debian-server-installer/install.sh`.
- **Amended by DD-228:** the portable `.command`, its exporter and the embedded digest are gone; `kur.sh`
  keeps the staged, atomic replacement of `/root/debian-server-installer`.

### DD-68: Stage 7 covers the cheap contract §14 checks (2026-08-07)

- **Decision:** End-of-install verification includes DNS against
  `127.0.0.1` and `${TAILSCALE_IPV4}`, an out-of-domain `REFUSED`, Caddy
  health, WebDAV unauthenticated `401` (direct + `webdav.` host),
  unauthenticated write rejected (`401`/`403`/`405`), public peer
  publishes for wg/qBit, and non-peer UI publishes only on `127.0.0.1`.
- **Context:** Stage 7 previously only checked loopback DNS, health, and
  WebDAV 401 — below contract §14’s success bar.
- **Rationale:** These checks are fast, deterministic, and catch the
  common “install said OK but ports/DNS wrong” failures without needing
  stored WebDAV passwords (authenticated PROPFIND/write remain manual /
  live Tier-3).
- **Trade-off:** Authenticated WebDAV list/write and full Caddy site
  non-5xx for every UI are still not asserted here.

### DD-67: Re-runs skip full-upgrade and unchanged edge/compose restarts (2026-08-07)

- **Decision:** `apt full-upgrade` runs on first install (no `state.env`),
  when `V2_FULL_UPGRADE=1`, or when the operator answers yes to a prompt
  (default **no** on re-run). `apt-get update` and package `install -y`
  still run. dnsmasq/Caddy are restarted only if their rendered files or
  drop-ins changed, or the unit is inactive; Compose `up -d` runs only if
  `compose.yaml`/`.env` changed or fewer than five containers are running.
  Edge `mask`+apt runs only when `dnsmasq`/`caddy` packages are missing.
- **Context:** Every re-run previously paid for a full upgrade and bounced
  the edge and Compose stack even when nothing changed.
- **Rationale:** Matches contract §11 (“no unconditionally expensive
  step”) while keeping first-install freshness and an explicit upgrade
  path.
- **Trade-off:** Operators who want updates on every re-run must answer
  yes or set `V2_FULL_UPGRADE=1`.
- **Amended by DD-228 (and DD-152):** full-upgrade runs on every run (no question, no `V2_FULL_UPGRADE`), and
  Compose is gone; the edge restarts stay change-driven.

### DD-66: Runtime firewall values come from state, not script fallbacks (2026-08-07)

- **Decision:** `master-firewall` requires `CHAIN_*`, `CHAIN_STAGING_PREFIX`,
  and public ports from `state.env` (`${VAR:?}`). Staging chain names are
  `${CHAIN_STAGING_PREFIX}` + `IN-` / `DK-` / `IN6-` / `DK6-`. DNS
  verification loops `SERVICE_NAMES`; wg bridge IPs/subnets live in
  `defaults.env` and are rendered into Compose.
- **Context:** Fallbacks in `firewall.sh` could silently keep an old port
  after the operator changed `defaults.env` / config. `SERVICE_NAMES` and
  bridge literals were declared but not wired.
- **Rationale:** Missing state must fail closed at apply time; a re-run of
  the installer rewrites a complete `state.env`.
- **Trade-off:** Hosts with a pre-v2-17 `state.env` need one installer
  re-run (or a manual state edit) before `master-firewall apply` succeeds.

### DD-65: Edge apt install keeps units masked; quiet the preset noise (revised 2026-08-07)

- **Decision:** Stage 6 **masks** `dnsmasq.service` and `caddy.service`
  before `apt-get install`, writes config/drop-ins, then `unmask` +
  `enable` + `restart`. Apt stdout/stderr is filtered only for the known
  `Failed to preset … is masked` / `deb-systemd-helper` / “static unit,
  not starting” lines (full apt text still appends to the install log).
  `policy-rc.d` is **not** used for this window.
- **Context:** An earlier revision replaced mask with `policy-rc.d` to
  silence apt. That removed the contract’s abort guarantee (§12): a failed
  stage 6 must leave the optional edge units **off** (masked), not merely
  “did not start during postinst”.
- **Rationale:** Mask is the fail-closed primitive the contract already
  documents. Log filtering restores operator clarity without weakening
  abort safety.
- **Trade-off:** Filter patterns are string-matched; a future apt wording
  change could let noise through again — not a safety regression.
- **Follow-up (2026-08-07, `v2-22`):** `retry` passes the command to
  `timeout`, which can only exec PATH binaries. Calling
  `apt_get_install_masked_quiet` through `retry` therefore failed with
  127 on the live host. `retry` now detects shell functions
  (`declare -F`) and wraps them as `export -f` +
  `timeout … bash -c '"$0" "$@"' fn args…`.

### DD-72: Address-bound units wait, fail visibly, and get recovered (2026-08-07)

- **Decision:** Three changes to the Tailscale-address recovery path.
  1. `refresh-tailnet-config` calls `systemctl restart` instead of
     `systemctl try-restart … || systemctl restart …`.
  2. It also calls `recover_failed_bound_units` on the **no-change** path,
     restarting `caddy` / `master-webdav` if they are in `failed`.
  3. The `caddy` drop-in gains `ExecStartPre=$SBIN_DIR/wait-tailnet-addr`,
     `TimeoutStartSec=150s`, `StartLimitIntervalSec=600` and
     `StartLimitBurst=3`.
- **Context:** `try-restart` restarts a unit **only if it is already
  running**. On a failed unit it does nothing *and returns 0*, so the `||`
  fallback was unreachable. Measured on the test host:
  `systemctl try-restart master-webdav.service; echo $?` → `0`, unit still
  `failed`. Separately, `caddy` had no wait for the address: it read
  `{$TAILSCALE_IPV4}` from `state.env`, failed to bind, and retried every
  5 s forever. With no `StartLimit*` it never reached `failed`, so
  `systemctl --failed` stayed empty while the whole tailnet surface was
  down (`NRestarts` observed climbing past 29).
- **Rationale:** The two failure shapes were mirror images. WebDAV waited
  correctly but then exhausted its start limit and stayed `failed` with
  nothing able to resurrect it; Caddy never failed and so was never
  visible. The combination — bounded wait, then visible failure, then
  recovery by the timer that already runs every five minutes — fixes both
  without adding a watcher, a timer, or a service.
- **Why the two waits stay separate:** `wait-tailnet-addr` only answers
  "does an address exist", which is all Caddy needs because it reads the
  value from `state.env`. `webdav.sh` keeps its own in-process wait because
  it needs the address *value* to pass to `rclone --addr`. These are
  different questions, not duplicated code.
- **Trade-off:** Caddy now takes up to 120 s to fail instead of crash-looping
  instantly, and `refresh-tailnet-config` does two `systemctl is-failed`
  checks per five-minute tick. Both are negligible next to a silent outage.
- **Verified live:** a `master-webdav` that had been `failed` for over forty
  minutes was recovered by one `refresh-tailnet-config` run with **no**
  address change. A subsequent `systemctl restart tailscaled` left
  `caddy` at `NRestarts=0` (previously 29 and climbing), containers
  untouched, `systemctl --failed` empty.

### DD-73: `MASTER-INPUT` accepts the Tailscale UDP port itself (2026-08-07)

- **Decision:** `TAILSCALE_UDP_PORT="41641"` is declared once in
  `defaults.env`, written to `state.env`, required by `firewall.sh`
  (`: "${TAILSCALE_UDP_PORT:?}"`), and accepted on the WAN interface in both
  `apply_input4` and `apply_input6`. Stage 0 rejects it as an operator port
  choice. `--check` asserts the IPv4 rule. `refresh-tailnet-config` also
  gains a one-line warning when the tailnet is unusable.
- **Context:** `MASTER-INPUT` carried no rule for Tailscale's own port and
  worked only because `ts-input` sits ahead of it in `INPUT` and accepts
  41641 there. Measured during the `tailscaled` restart test: with no
  netmap, Tailscale removed `ts-input` entirely, and `MASTER-INPUT`'s
  `-i eth0 -j DROP` counted 52 packets while `tailscaled` was still bound to
  `0.0.0.0:41641`. Separately, the node was deleted from the tailnet at
  15:08 and logged `404: node not found` 501 times over four hours while
  `systemctl --failed` stayed empty and every unit reported green.
- **Rationale:** Tailscale reinserts `ts-input` at `INPUT` position 1, so
  the ordering does self-correct and the impact is bounded — a fallback to
  DERP relay rather than an outage. But the correctness of this project's
  chain should not depend on a chain owned by another daemon being present
  and correctly positioned. One additive rule removes the coupling;
  `ensure_ts_input_precedence` stays, demoted from load-bearing to
  belt-and-braces.
- **Trade-off:** One more explicit WAN `ACCEPT`. It duplicates what
  `ts-input` already permits, which is the point: the two are independent
  now. If Tailscale is ever started on a non-default port the constant must
  follow, which is why it lives in `defaults.env` and not in the script.
- **On the warning:** it is a `printf` to stderr, nothing more. It does not
  attempt `tailscale up`, does not retry, and does not gate anything — a
  bats test asserts the helper never calls `tailscale up/set/login`. The
  four-hour silent outage needed visibility, not a repair engine.
- **Verified live:** both chains carry the rule, `--check` passes, and a
  missing `TAILSCALE_UDP_PORT` in `state.env` fails the script closed.

### DD-74: Tailscale stateful filtering stays on, deliberately (2026-08-07)

- **Decision:** `tailscale set … --stateful-filtering=true` is kept.
  Tailscale's own health warning about it in the presence of Docker is
  **expected output on this host**, not a defect to chase.
- **Context:** Tailscale made stateful filtering default-**off** in 1.78
  because it breaks containers that need to reach tailnet nodes, and the
  daemon reports:
  *"Stateful filtering is enabled and Docker was detected; this may prevent
  Docker containers on this host from resolving DNS and connecting to
  Tailscale nodes."*
  The rule it installs is visible in `ts-forward`:
  `-o tailscale0 -m conntrack ! --ctstate RELATED,ESTABLISHED -j DROP`.
- **Rationale:** The warning describes a capability this stack does not use.
  No container needs the tailnet: Docker's resolver is pinned to
  `1.1.1.1`/`1.0.0.1` in `daemon.json`, and none of the five services talks
  to a tailnet peer. Turning the filter off to silence a warning would
  loosen what may leave the host toward the tailnet in exchange for nothing.
- **The one real consequence, accepted:** wg-easy peers cannot reach tailnet
  devices — traffic from the wg bridge toward `tailscale0` is dropped by
  that rule (and by `ts-forward`'s `-s 100.64.0.0/10 -o tailscale0 -j DROP`).
  Reaching tailnet devices over the WireGuard VPN is not a requirement;
  tailnet devices are reached with the Tailscale client. Operator decision,
  2026-08-07.
- **Revisit if:** wg peers ever need to reach tailnet nodes, or a container
  is added that must. Then this is the setting to change first, and the
  contract's §14.2 success criterion must change with it.

### DD-75: Host firewall converges without Docker; address units drop PartOf (2026-08-09)

- **Decision (four changes, one revision):**
  1. `master-firewall.service` uses `Wants=docker.service`, not
     `Requires=`. Host INPUT apply/check always run; `MASTER-DOCKER` is
     applied/checked only when `DOCKER-USER` is present (or Docker is
     active and the wait for the chain succeeds). Docker inactive → skip
     Docker stage without failing the unit; Docker active but chain missing
     after the wait → fail closed.
  2. Stage 5 restarts `master-firewall` / `master-webdav` when
     `state.env`, helper scripts, unit files, or `webdav.env` actually
     changed (`FIREWALL_NEEDS_RESTART` / `WEBDAV_NEEDS_RESTART`), matching
     the Caddy/dnsmasq pattern. Bare `enable --now` on an already-active
     unit is not convergence.
  3. Caddy drop-in and `master-webdav.service` no longer declare
     `PartOf=tailscaled.service`. Firewall keeps `PartOf` for both
     `docker` and `tailscaled` so netfilter order is rebuilt on those
     restarts. Address binding recovery stays on `refresh-tailnet-config`
     (`WantedBy=tailscaled` + 5-minute timer) and `wait-tailnet-addr`.
  4. `tailscale_login` reaps a stuck `tailscale up` child with TERM, a
     bounded wait, then KILL before the next attempt — never an unbounded
     `wait` on a still-running auth process.
- **Why:** Live nrm tests (2026-08-09) showed (a) `systemctl start` on
  active firewall/WebDAV is a no-op so port/state edits never apply on
  re-run, (b) Tailscale restart bounced Caddy/WebDAV while containers and
  IPs stayed put, and (c) Docker boot failure would have blocked host
  INPUT via `Requires=docker` plus a hard `die` when `DOCKER-USER` was
  absent. Rejected on the same evidence: `accept_ra=2`,
  `stateful-filtering=false` (DD-74), treating start-limit as a permanent
  lock, and restoring `watch-tailnet-addr`.
- **Apply order:** host INPUT (IPv4 then IPv6, with `ts-input`
  precedence) first; Docker chains afterward so a missing Docker path
  cannot leave the host without WAN DROP.
- **v2-33 follow-up:** `sed | atomic_write` runs the function in a Bash
  pipe subshell, so `V2_LAST_ATOMIC_CHANGED` is discarded. WebDAV unit
  writes use process substitution (`atomic_write … < <(sed …)`) instead.
  Found on the first live v2-32 re-run: unit on disk updated, PID unchanged.
- **v2-34 follow-up:** `--check` (and apply) fail closed on WAN if drift;
  require exactly one final-chain jump; reject staging-prefix leftovers;
  assert SSH ACCEPT (v4/v6), IPv6 Tailscale UDP, and NS/NA. No automatic
  state rewrite on drift — operator re-runs the installer.

### DD-84: Selective downloads ownership repair + P3 hygiene (2026-08-09)

- **Decision (chown):** Stage 3 `ensure_downloads_tree` only `chown -h` /
  `chmod`s entries whose UID/GID or mode already diverge from
  `${DOWNLOADS_UID}:${DOWNLOADS_GID}` / `0775` dirs / `0664` files. No
  unconditional `chown -R`. Symlink targets are not rewritten (`-h`).
- **Decision (P3):** Drop timer `Requires=` (Unit= is enough); strip stale
  host-WebDAV wording from wait/refresh helpers; Caddyfile matches
  `caddy fmt`; firewall helper drops unused `WAN_IPV4` and `--check`s
  IPv6 `packet-too-big`; export builds a deterministic tarball (`touch`
  epoch + `gzip -n`, stable `PORTABLE_BUILT_AT`). `render_template`
  preserves trailing newlines (so `caddy fmt` stays clean).
- **Why:** Large media trees made every re-run pay a full rewrite; P3 items
  were low-risk noise that dirtied exports and docs without changing
  intent. WG Stage 7 listen/CGNAT checks stay out — operator tracks
  manually.
- **Not doing:** automatic image pull; Watchtower; WG endpoint Stage 7.

### DD-80: `refresh-tailnet-config` waits with `tailscale wait` (2026-08-09)

- **Decision:** Before reading `tailscale0` addresses, the helper runs
  `tailscale wait --timeout=${REFRESH_TAILNET_WAIT_TIMEOUT:-120s}` when the
  CLI supports it. On timeout it soft-exits 0 (timer retries). The unit sets
  `TimeoutStartSec=150s` so systemd does not kill the wait. The 5-minute
  timer and `WantedBy=tailscaled` both stay.
- **Why:** `WantedBy=tailscaled` fires when the daemon process starts, not
  when the interface has an IP. Live logs showed `BackendState=NoState` and
  immediate “IPv4 yok; atlanıyor”, deferring recovery to the timer.
  `tailscale wait` (supported on host 1.102.2) is the upstream tool for
  “backend running + interface + IP”.
- **Not doing:** removing the timer; infinite wait (`--timeout=0`); coupling
  Compose/WebDAV to this path.

### DD-98: Infuse uses Caddy on Tailscale IP:WEBDAV_PORT (2026-08-10)

- **Decision:** Caddyfile WebDAV site is
  `http://webdav.${LOCAL_DOMAIN}, http://{$TAILSCALE_IPV4}:{$WEBDAV_PORT}`
  → `127.0.0.1:{$WEBDAV_PORT}` (both placeholders from `state.env` via
  Caddy `EnvironmentFile=`). Compose stays loopback-only and never names
  the Tailscale address. Refresh-tailnet still restarts only Caddy; a
  re-run that changes `WEBDAV_PORT` sets `WEBDAV_PORT_CHANGED` so Caddy
  restarts even when the Caddyfile text is unchanged.
- **Why:** Infuse on Apple TV wants an explicit port (`61003`) without
  MagicDNS. Binding that port in Caddy (from `state.env`) keeps Compose
  free of Tailscale IPs while matching Infuse UX. Bare `:80` on the TS IP
  is no longer WebDAV (avoids Host=IP confusion with other sites).
- **Rejected (same day):** Compose publish on `${TS_IPV4}:${WEBDAV_PORT}`
  (brief v2-65) — embeds a moving address into Compose and forces
  `docker compose up -d webdav` on every Tailscale IP change.
- **Supersedes:** DD-78’s bare `http://{$TAILSCALE_IPV4}` (port 80) alias.

### DD-85: `wait-tailnet-addr` requires the state IPv4 on the interface (2026-08-09)

- **Decision:** When `TAILSCALE_IPV4` is set in the ExecStartPre
  environment (systemd `EnvironmentFile=state.env`),
  `wait-tailnet-addr` succeeds only if that exact address is present on
  `tailscale0`. If the interface already has a different global IPv4, the
  helper exits `1` immediately with a stale-state message instead of
  waiting out the deadline. If the variable is unset, “any global IPv4”
  remains sufficient.
- **Why:** Caddy binds `{$TAILSCALE_IPV4}` from state, not “whatever is on
  the iface”. The previous any-IP check turned green while Caddy stayed
  `activating` on a poisoned/stale address (measured on `nrm`, 2026-08-09
  resilience pass). Fail-fast hands recovery to the existing
  `refresh-tailnet-config` path (`recover_failed` / IP rewrite + restart)
  without a new watcher.
- **Amends:** DD-72’s “wait only answers does an address exist” for the
  Caddy pre-start helper; refresh still owns rewriting state.

### DD-86: Unusable-tailnet warning names BackendState and Online (2026-08-09)

- **Decision:** `warn_if_tailnet_unusable` logs
  `BackendState=… Online=…` when the node is not both `Running` and
  `Self.Online=true`. Still warning-only; no Tailscale repair.
- **Why:** Live `nrm` resilience pass printed
  `UYARI … (BackendState=Running)` while `Online` was false during a
  `tailscaled` restart — correct trigger, contradictory message. Naming
  both fields makes the line greppable without false “daemon is fine”
  readings.
- **Not doing:** hard-failing refresh; waiting for Online here (`tailscale
  wait` already covers readiness).

### DD-87: Caddy `OnFailure` starts `refresh-tailnet-config` (2026-08-09)

- **Decision:** The Caddy master-stack drop-in sets
  `OnFailure=refresh-tailnet-config.service`. No new timer, watcher, or
  probe oneshot.
- **Why:** After **DD-85**, a stale `state.env` IP fails `ExecStartPre`
  immediately and leaves Caddy `failed` until the next refresh tick
  (up to five minutes, or `OnBootSec=2min`). Wiring failure to the
  existing oneshot updates `state.env` from the interface and restarts
  Caddy in seconds. Refresh still writes the new address *before*
  restarting Caddy when the iface IP differs — it does not resurrect
  Caddy on the stale value.
- **Does not cover:** Silent Tailscale readdress while Caddy stays
  `active` (DD-64 timer / `WantedBy=tailscaled` remain that path).
- **Bounds:** Caddy `StartLimitBurst=3` / `600s` still caps fail loops if
  the tailnet never becomes usable.

### DD-93: Firewall Docker re-apply + install path hygiene (2026-08-09)

- **Decision (three fixes, one package):**
  1. Install `docker.service.d/master-stack.conf` with
     `ExecStartPost=-/bin/systemctl --no-block restart master-firewall.service`.
     DD-75 still allows INPUT without Docker, but a later `docker start`
     must not leave published peer ports unprotected when
     `RemainAfterExit` made `WantedBy` start a no-op. `--no-block` avoids
     a start-post deadlock (`After=docker` waiting while Docker waits for
     ExecStartPost).
  2. `master-firewall --check` requires DOCKER allow rules and asserts
     WAN DROP sits after WAN ACCEPT/RETURN in INPUT and DOCKER chains.
  3. Restore DD-8: merge `dns` into `/etc/docker/daemon.json` via `jq`
     instead of overwriting the file. Restrict `DOWNLOADS_PATH` to
     `/downloads`, `/data`, `/srv/downloads` (and subpaths) before
     recursive ownership repair. Scope `filebrowser` container removal to
     this Compose project / known images.
- **Why:** GPT live review of v2-58 on `nrm` (2026-08-09): healthy runtime,
  but fail-open gap after INPUT-only firewall apply, weak `--check`,
  daemon.json clobber, and over-broad downloads/FB cleanup on shared hosts.
- **Not doing:** disk-persisted iptables, reconcile engine, automatic WAN
  endpoint rewrite, or broadening healthchecks beyond the contract.

### DD-94: The firewall converges; it does not fail with no policy (2026-08-09)

- **Decision (one package, v2-60):**
  1. **Live WAN interface.** `resolve_wan_interface` reads the current
     default route on every apply and check. `state.env` `WAN_INTERFACE` is
     a hint: a mismatch is a warning, not a fatal error, and the live name
     is used. It is deliberately not written back — the value is consumed by
     this script alone at runtime.
  2. **Shape check, not presence check.** `check_chain_shape` replaces
     `check_wan_drop_after_allows`: exactly one WAN DROP per chain, after
     every WAN allow, and no unconditional `ACCEPT`/`RETURN` (no `-i`/`-p`/
     `-m`/`--dport` match) before it. The terminal `-j RETURN` is legal
     because it sits after the DROP.
  3. **Orphan staging purge.** An apply removes leftover staging chains that
     nothing jumps to. A referenced one may be the live policy mid-swap and
     is left alone.
  4. **No Docker ordering on the unit.** `After=`, `Wants=` and
     `WantedBy=docker.service` are removed so host `INPUT` lands as early as
     possible and cannot be delayed by a slow Docker start. `MASTER-DOCKER`
     comes from the DD-93 drop-in; `PartOf=docker.service` is kept as a
     belt-and-braces second trigger. The installer deletes the retired
     `docker.service.wants/master-firewall.service` symlink.
  5. **One bounded watchdog.** `refresh-tailnet-config`, which the timer
     already runs every 5 minutes, restarts `master-firewall` when the unit
     is `failed` or `--check` fails, after `reset-failed` so an exhausted
     start limit cannot block recovery. It runs before the Tailscale wait so
     a dead tailnet does not skip it, and it skips the round while the
     oneshot is `activating`.
  6. **Restart pacing** `RestartSec=10s` / `StartLimitIntervalSec=300` /
     `StartLimitBurst=12`: a transient netfilter or Docker-chain race gets
     ~2 minutes of retries instead of burning 5 attempts in 10 seconds.
  7. **Label-only FileBrowser cleanup.** Container and legacy volume removal
     requires `com.docker.compose.project` to match this project. The
     v2-59 image-name fallback could still delete a foreign `filebrowser`.
- **Why:** the v2-58 review's P1 was that the firewall could fail *with the
  host unprotected*: a renamed NIC or a stale state value aborted the apply
  while `INPUT`'s default policy stayed `ACCEPT`. Converging on the live
  interface, checking chain shape instead of rule existence, and giving the
  unit one bounded recovery path removes that class of outcome without
  persisting rules to disk.
- **Not doing:** disk-persisted iptables (DD-66 stands: the unit is the
  single source of policy), a general reconcile engine (contract §2), a
  `PartOf=docker.service` removal (the drop-in plus PartOf is cheap; a
  duplicate apply is idempotent), automatic `WG_ENDPOINT_HOST` rewrite on
  public-IP change, or watchdog coverage of anything but the firewall unit.

### DD-100: Skip a repo's apt-get update when its source file didn't change (2026-08-23)

- **Decision:** `stage_2` and `stage_4` each write an apt source file
  (`tailscale.list`, `docker.sources`) via `atomic_write`, then only run
  `apt-get update` when `V2_LAST_ATOMIC_CHANGED` is `1` from that write.
  Otherwise they log and skip it.
- **Why this is safe, not a staleness risk:** `stage_1` already runs
  `apt-get update` before either repo file is touched. On a re-run both
  files already exist on disk from the prior run, so they're already
  part of the sources `stage_1`'s update just refreshed — a second
  `apt-get update` moments later, with the file byte-identical, re-fetches
  the exact same index data. On first install the files are new
  (`V2_LAST_ATOMIC_CHANGED=1`), so the update still runs — apt has never
  seen that source before.
- **Why not drop the per-stage updates entirely:** a re-run where the
  operator's Tailscale/Docker apt config genuinely changed (key rotation,
  suite bump) still needs its own fresh index before `apt-get install`
  in that same stage; gating on the write result keeps that case correct
  while eliminating the common no-op case (**R20**: no step is
  unconditionally expensive).
- **Not doing:** consolidating all three `apt-get update` calls into one
  pass after every repo file is written — that would cross stage
  boundaries (Tailscale must be installed in stage_2, Docker in stage_4)
  for a saving only the re-run path has; smallest-change preferred.

### DD-102: Supported-OS matrix — Debian 13 plus the two Ubuntu LTS lines (2026-08-29)

- **Decision:** `require_debian_trixie` became `require_supported_os`,
  accepting exactly three ID/codename/major triples: `debian/trixie/13`,
  `ubuntu/noble/24`, `ubuntu/resolute/26`. The gate sets `OS_ID` and
  `OS_CODENAME`, and the Tailscale/Docker apt repo lines are rendered from
  those — verified live (2026-08-29) that both vendors publish
  `stable/ubuntu {noble,resolute}` and `linux/ubuntu` dists with the same
  URL shape as Debian. The Caddy cloudsmith line is already
  distro-agnostic (`any-version`) and Caddy's own Ubuntu instructions use
  the identical line.
- **Why pinned LTS releases, not `ID=ubuntu`:** same reason trixie was a
  hard gate — the installer's behaviour is only known on releases it was
  written against. Interim releases (25.04/25.10) have 9-month lives and
  add nothing; the two LTS lines cover real hosts through 2029+.
- **Ubuntu-specific guards that came with this:**
  - **ufw:** Ubuntu server ships it (inactive by default). If active, it
    manages INPUT alongside MASTER-INPUT — two owners for one chain.
    stage_0 dies before any mutation; the operator runs `ufw disable`
    first. Fail-closed, consistent with the rest of the tree.
  - **resolv.conf stub:** stage_6 already wrote `DNSStubListener=no` when
    systemd-resolved is active; on Ubuntu `/etc/resolv.conf` is a symlink
    to the stub (`127.0.0.53`), so disabling the stub alone breaks host
    DNS. When the symlink targets `stub-resolv.conf` it is repointed to
    `/run/systemd/resolve/resolv.conf` (resolved's uplink file). No-op on
    hosts without the stub symlink, including Debian. This is a safe
    bootstrap, not a permanent ownership claim: with Tailscale DNS enabled,
    Tailscale may later replace the symlink with its direct-mode MagicDNS
    `resolv.conf`. The resolute reboot test confirmed that steady state keeps
    host and split DNS healthy; forcing Tailscale onto the resolved stub would
    create a resolver loop on this dnsmasq layout and is deliberately not done.
    Confirmed end to end on a fresh v2-76 install (2026-09-10): the stub
    symlink was repointed at install time, Tailscale had replaced the file with
    its own after the reboot, host and split DNS stayed healthy throughout, and
    the post-reboot re-run correctly left the repoint alone because `readlink`
    no longer matches the stub.
  - **apt lock:** Ubuntu enables unattended-upgrades by default, so the
    dpkg lock can be held for minutes right when the installer starts.
    Every `apt-get` call now carries `-o DPkg::Lock::Timeout=60`
    (`APT_OPTS`), waiting on the lock instead of failing instantly;
    `retry` still wraps each call above that.
  - **debian-keyring:** installed only when `OS_ID=debian` — it came from
    Caddy's official Debian install set and has no function on Ubuntu
    (repo signing uses the downloaded cloudsmith keyring). **Dropped on every
    OS in v2-90 (DD-125).**
    - The two `apt_get_install_masked_quiet` installs (dnsmasq, Caddy) never
      received `APT_OPTS`, because `retry` runs functions in a child bash that
      does not inherit arrays. This was fixed in v2-90 (DD-125).
- **Verification status:** bats covers the gate matrix (accept ×3,
  reject ×5 including ID/codename and codename/version mismatches) and
  the repo-line derivation. **Live-verified on both Ubuntu lines:** noble
  24.04.4 on 2026-08-29 and resolute 26.04.1 on 2026-08-30. Both fresh
  installs passed stages 0–7 and independent checks for derived repos, host
  DNS, firewall, DNS/Caddy, WebDAV and 6/6 containers. Resolute additionally
  passed a byte/container/service-stable re-run, Tailscale and Docker restart
  recovery, firewall re-application, and a full reboot with no failed units.
- **Not doing:** distro-conditional package name mapping (the full
  package set — dnsmasq, caddy via vendor repo, apache2-utils, dnsutils,
  ethtool, jq, … — resolves identically on both), and no support for
  derivatives (Mint, Pop!_OS) whose os-release IDs differ.

### DD-103: The installer owns every restart it triggers (2026-09-08)

- **Decision:** `stage_1` exports `NEEDRESTART_SUSPEND=1` next to
  `DEBIAN_FRONTEND=noninteractive`.
- **Why:** Ubuntu ships `needrestart` with an apt `DPkg::Post-Invoke` hook.
  `/usr/sbin/needrestart` detects Ubuntu and, absent an explicit
  `$nrconf{ui}`, sets `$nrconf{restart} = 'a'` — **automatic**. Verified on
  `nrm` (needrestart 3.11, Ubuntu 26.04.1). `DEBIAN_FRONTEND=noninteractive`
  does not disable this: it only suppresses the prompt, and only for
  restart mode `i`, which Ubuntu mode has already replaced.
  The effect is that after any `apt-get install`/`full-upgrade` that pulls a
  library update, a process the installer does not own restarts `sshd`,
  `docker`, `containerd`, `tailscaled`, `caddy` and `dnsmasq` in the middle
  of stages 1, 2, 4 and 6. A `docker` restart there also fires the
  `docker.service.d` drop-in (`master-firewall restart`); a `tailscaled`
  restart fires `refresh-tailnet-config`. Both paths are re-entrant, so
  nothing has been observed to break — but this is the same "two owners for
  one thing" class the ufw gate refuses (**DD-102**), only silent.
- **Why the env var and not a config file:** `NEEDRESTART_SUSPEND` is read by
  `/usr/lib/needrestart/apt-pinvoke` and scoped to the installer's own
  process tree. Writing `/etc/needrestart/conf.d/*` would be the installer
  claiming a host policy it does not own after it exits (**DD-96**).
- **Not doing:** an `OS_ID` branch. Debian does not install needrestart by
  default, and an unread environment variable is a no-op there.
- **Live-measured (`nrm`, fresh Ubuntu 26.04.1, 2026-09-10):** with
  needrestart 3.11 installed and hooked into apt, a first install — which
  forces `full-upgrade` — produced zero needrestart journal records, and every
  service start time was attributable to an installer stage. `sshd` kept its
  boot timestamp throughout, which is the direct evidence: it is the daemon
  needrestart would otherwise have restarted mid-stage.

### DD-104: The OS is recorded, not just detected (2026-09-08)

- **Decision:** `require_supported_os` additionally sets `OS_VERSION_ID` and
  `OS_ARCH`; `write_state` records `OS_ID`, `OS_CODENAME`, `OS_VERSION_ID`,
  `OS_ARCH` and `KERNEL_RELEASE`; `stage_0` calls `detect_os_change`, which
  compares the recorded identity against the live one and, on a mismatch,
  sets `OS_CHANGED=1` and `FIREWALL_NEEDS_RESTART=1`. `OS_CHANGED` forces the
  Tailscale and Docker `apt-get update`, the `systemd-resolved` restart and
  one dnsmasq/Caddy restart, even when the written files are byte-identical.
- **Why:** the tree handles Debian/Ubuntu differences by *probing* the host
  (`command -v ufw`, `systemctl is-active systemd-resolved`, `readlink
  /etc/resolv.conf`) rather than branching on the distro label. That design
  is better than a switch statement and is kept. What it lacked was memory:
  after a `do-release-upgrade` from noble to resolute the repo lines change
  (so **DD-100**'s skip correctly triggers an update), but nothing else
  re-evaluates — the probes happen to still be right, by luck rather than by
  design. Recording the identity turns that luck into a decision, and gives
  a provisioned host a support record that previously had to be read live.
- **Absent record is not a change:** a host installed by v2-73 or earlier has
  no `OS_*` lines. That case logs "no OS record" and leaves `OS_CHANGED=0`;
  the fields are simply added on this run. Claiming a release change there
  would force needless work on every upgrading host.
- **Not doing:** gating on the recorded value, migration logic per release
  pair, or any comparison of non-OS state. `OS_CHANGED` re-runs steps that
  already exist unconditionally — it is a cache invalidation, not the
  reconcile engine contract §2 refuses.
- **Architecture:** recorded, warned about outside `amd64`/`arm64`, and not
  gated on. arm64 is untested, not unsupported; both apt vendors and all six
  images publish it.
- **Live-verified (`nrm`, 2026-09-08):** the v73 host logged "no OS record" and
  gained the fields without claiming a change. Seeding
  `OS_CODENAME=noble`/`OS_VERSION_ID=24.04` then produced
  `işletim sistemi değişmiş: ubuntu/noble/24.04 → ubuntu/resolute/26.04` and
  suppressed **every** skip path — both apt updates ran, and the firewall,
  dnsmasq and Caddy all restarted — after which `state.env` self-corrected.

### DD-105: sysctl drop-ins must sort last, and the runtime value is what counts (2026-09-08)

- **Decision:** the two drop-ins move to `99-zz-master-stack-netbuf.conf` and
  `99-zz-master-tailscale.conf` (paths in `defaults.env`), the v2-73 names are
  deleted on upgrade, and `stage_7` asserts the **live**
  `net.ipv4.ip_forward=1` and warns when `net.core.rmem_max` sits below
  `NET_BUF_FLOOR_BYTES`.
- **Why:** `/etc/sysctl.d` is applied in lexicographic order and the last
  assignment wins. On `nrm` the provider image ships
  `/etc/sysctl.d/99-nc-kernel.conf`, which sorts **after** both
  `99-master-*` files and writes `net.core.rmem_max`/`wmem_max` itself. Here
  it is harmless — it sets 64 MiB, four times the floor, and **DD-18**'s
  `max(current, floor)` correctly preserved it. But the same ordering applies
  to `99-master-tailscale.conf`, which carries `ip_forward`. On a host whose
  provider file sorts later and sets `ip_forward = 0`, the installer would
  apply forwarding at install time (`sysctl -p`, immediate) and lose it at the
  next reboot: an exit node that silently stops forwarding, with every unit
  green and every file on disk correct.
- **Why also assert at runtime:** file placement is a claim, not a
  measurement. A `99-zzz-*` file from a future image would beat the rename;
  reading the live value catches the class rather than the instance. This is
  the same reasoning as `master-firewall --check` (**DD-94**) — assert the
  effect, not the intent.
- **Why delete the old names:** two files writing one key is a second source
  of truth, and the old ones would keep losing the same race.
- **Live-verified across a cold reboot (`nrm`, 2026-09-08):** `/etc/sysctl.d`
  now lists `99-nc-kernel.conf` before `99-zz-master-stack-netbuf.conf` and
  `99-zz-master-tailscale.conf`, and after the boot `ip_forward=1`,
  `net.ipv6.conf.all.forwarding=1` and `rmem_max=67108864` (the provider's
  value, preserved by DD-18's `max()`). The rename only matters across a boot,
  so this is the test that counts.

### DD-106: Fail early, with the real cause (2026-09-08)

Three gates, one rationale: every one of them replaces a late, misleading
failure with an early, named one.

1. **Netfilter backend (`require_nft_iptables`, stage 0).** `firewall.sh` and
   Docker must use the same backend. With the alternatives set to
   `iptables-legacy`, Docker writes nft and the script reads legacy, so
   `DOCKER-USER` appears absent and `wait_for_docker_user` dies after 10 s
   with "Docker çalışıyor ama zincir yok" — the symptom, not the cause. The
   gate names the remedy (`update-alternatives --set iptables
   /usr/sbin/iptables-nft`). `nrm` verified `iptables v1.8.11 (nf_tables)`.
2. **Repo suite preflight (`assert_repo_suite`).** A codename the vendor has
   not published yet fails inside `apt-get update`, after 3 attempts of up to
   `APT_LOCK_TIMEOUT` each, with apt's own wording. One `curl -I` against
   `…/dists/$OS_CODENAME/Release` per repo says which vendor is missing which
   suite. Three attempts, because a transient network failure must not be
   reported as an unpublished release. All six current combinations verified
   to return 200 (2026-09-08).
3. **Rendered-config validation.** `dnsmasq --test -C`, `caddy validate` and
   `docker compose config -q` all run on the target — every binary is present
   there — before the unit that consumes the file is restarted. Previously the
   first sign of a bad render was `systemctl restart dnsmasq` failing under
   `set -e`, or Caddy burning its `StartLimitBurst` (**DD-72**). Both work;
   both say "restart failed" instead of "line 20: bad option". The realistic
   trigger is exactly what **DD-104** is about — a dnsmasq or Caddy version
   bump between OS releases dropping a directive. Verified on `nrm` that both
   validators accept the live configs and reject seeded errors with a line
   number and the offending directive.
- **Caddy is validated with the real environment.** The Caddyfile resolves
  `{$TAILSCALE_IPV4}` and `{$WEBDAV_PORT}` at daemon start; validating with an
  empty environment accepted a meaningless `http://:` site, so the values are
  passed in.
- **Not doing:** `systemd-analyze verify` on the generated units. The units are
  static files in the tree, not renders, and the bats suite already reads them.

### DD-108: A gate may only assert what the host already has (2026-09-08)

- **Decision:** `require_nft_iptables` becomes `check_nft_iptables
  optional|required`. Stage 0 calls it `optional`: it verifies the backend of
  whichever of `iptables`/`ip6tables` exist and, when neither does, logs that
  the check is deferred. Stage 1 calls it `required` immediately after the
  base package install, where the binaries are guaranteed.
- **Why:** DD-106 put the backend gate in stage 0 so a misconfigured host dies
  before any mutation. That was verified on Ubuntu, which ships `iptables`
  preinstalled — and it made **fresh Debian installs impossible**. A minimal
  Debian 13 image has no `iptables` at all (`command not found`, no dpkg
  entry, no `/usr/sbin/iptables*`); the package arrives in stage 1's base set.
  v2-74's gate therefore killed the run at stage 0, before the stage that
  would have installed the very binary it was inspecting. Verified on a fresh
  trixie host on 2026-09-08.
- **The general rule this encodes:** an early gate can only assert properties
  of a host as it *arrives*. A check whose subject the installer itself
  provides belongs after the step that provides it. Stage 0's other gates all
  satisfy this — `root`, `os-release`, TTY, ufw (`command -v` guarded), and
  `flock`, `ip`, `cmp` and `dpkg`, which are `required`/`essential` on both
  distributions and present on any minimal image.
- **Why not simply drop the stage-0 call:** a host whose alternatives were
  deliberately pointed at `iptables-legacy` still has the binaries, and that
  is the case the gate exists for. Checking what is present costs nothing and
  keeps the fail-before-mutation property for every host that can fail it.
- **Both families are checked.** `iptables` and `ip6tables` have separate
  `update-alternatives` links and `firewall.sh` drives both, so the loop
  covers both and names the failing one in the remedy.
- **Not doing:** installing `iptables` earlier just to keep the gate in stage
  0. That would move package installation before the input prompts and the
  lock, for no gain.
- **Live-verified (`nrm`, fresh Debian 13.6 trixie, 2026-09-08):** stage 0
  logged `iptables henüz kurulu değil (Debian minimal); nft arka uç denetimi
  aşama 1'e ertelendi` and the install ran through to stage 7 in 90 seconds.
  After stage 1 both binaries report `v1.8.11 (nf_tables)`. On the second
  run the stage-0 check passes silently, because the package is now present.

### DD-109: A setting whose effect is not guaranteed gets read back (2026-09-10)

- **Decision:** `stage_6` keeps writing `DNSStubListener=no` when
  systemd-resolved is active, and then calls `report_resolved_stub_state`,
  which reads whether `127.0.0.53` is actually bound and logs which way it
  went. Bounded by `RESOLVED_STUB_SETTLE_SECONDS`, because the stub socket
  appears a moment after a resolved restart.
- **Why:** on Ubuntu 26.04 / systemd 259 the key is accepted and ignored — the
  drop-in is present, last in the merge order, and `man resolved.conf` still
  documents it, yet the stub stays up and answering, on a fresh install and
  across a reboot. The installer was reporting success for a step that did
  nothing. Harmless is not the same as true.
- **What was NOT done, and why — a claim of ours that failed its own test.**
  The review's A1 entry also asserted a latent start-order race: that
  `bind-dynamic` "claims every address on the listed interfaces as they
  appear", so a dnsmasq restart while resolved was down would let dnsmasq take
  `127.0.0.53` and lock resolved out. The proposed fix was to replace
  `interface=lo` with `listen-address=127.0.0.1`. Tested on `nrm` before
  implementing: with resolved stopped and `.53` completely free, dnsmasq was
  restarted and **did not take it** — `bind-dynamic` binds the addresses
  *assigned to* an interface, and `lo` carries only `127.0.0.1/8` and
  `::1/128`; `127.0.0.53` is merely reachable through the 127/8 route.
  Resolved then rebound it cleanly. The race does not exist, so the binding
  change would have bought nothing while dropping `[::1]:53` — it was
  withdrawn. `archive/optimization-review.md` §7's protection of `bind-dynamic` now
  rests on a measurement rather than on reputation.
- **Why not delete the ineffective drop-in instead:** it would change behaviour
  on any host where the key still works, and there is no such host to verify
  against — Debian keeps resolved inactive, Ubuntu 26.04 ignores the key.
  Writing it and measuring the result is the honest position until one exists.
- **The general rule:** where the installer cannot guarantee that a setting
  takes effect, it reads the achieved state back and says so. Same principle as
  `master-firewall --check` (**DD-94**) and stage 7's live `ip_forward`
  assertion (**DD-105**): assert the effect, not the intent.
- **Not doing:** failing the install over it. The state is benign here, and a
  gate on a third party's configuration parser would be a new failure mode for
  no gain.

### DD-111: TCP congestion control is BBR, measured before adopting it (2026-09-11)

- **Decision:** stage 2 loads `tcp_bbr` and writes
  `net.ipv4.tcp_congestion_control = bbr` and `net.core.default_qdisc = fq` to
  `99-zz-master-tcp.conf` (values in `defaults.env`), plus a `modules-load.d`
  entry. If the module cannot be loaded, the install continues on the kernel
  default and says so. Stage 7 reads the live value back and warns on a
  mismatch; it does not fail, because this is an optimisation, not a contract
  item.
- **Why — measured on `nrm` (Ubuntu 26.04.1, kernel 7.0.0-31, 2026-09-11):** a
  256 MiB file served by Caddy over WebDAV was downloaded by a MacBook over the
  direct tailnet path (RTT ~59–67 ms, MSS 1228). The runs were interleaved
  (cubic, bbr, bbr, cubic, cubic, bbr), and each run's congestion control was
  confirmed on the live socket with `ss -tin`:

  | | Runs (Mbit/s) | Mean |
  |---|---|---|
  | cubic | 439.9 · 444.8 · 355.1 | 413.3 |
  | bbr + fq | 445.4 · 435.4 · 442.0 | 440.9 |

  An earlier batch adds three more cubic runs: 436.4, 361.1 and 348.4. That
  batch was meant to alternate with BBR, but a harness bug left every run on
  cubic, which the same socket probe confirmed. Across all six cubic runs,
  three hit a burst of about 2,000 retransmissions and lost roughly 20%. None
  of BBR's three runs did. **Peak throughput is the same (~440 Mbit/s, the
  path's ceiling).** BBR's gain is that cubic's loss-driven dips go away.
- **Scope, and a correction to the review:** `archive/os-aware-review.md` D1 said BBR
  would help "an exit node relaying other devices' TCP". It does not. The two
  endpoints of a TCP connection run its congestion control; a router that only
  forwards the flow never does. On this host BBR affects only TCP that ends
  here: Caddy's WebDAV stream to Infuse, qBittorrent's uploads and the web
  UIs. For WebDAV that is the path that matters, and on lossy client networks
  such as a phone or a remote Infuse session, cubic's sensitivity to loss grows
  where BBR's does not.
- **Why adopt it when nothing is broken:** even cubic's worst run (348
  Mbit/s) is 3.5–7× what a 4K HDR remux needs (50–100 Mbit/s), so this does
  not remove a bottleneck. It is adopted because the measured effect was
  consistent, the mechanism is standard, it costs two sysctls in a pattern the
  tree already uses, and a host that cannot load the module simply keeps its
  default. It is an opportunistic improvement, not a fix, and is recorded that
  way.
- **Trade-offs accepted:** mainline `tcp_bbr` is BBRv1. It can take more than
  its share against cubic flows at a shared bottleneck, and it retransmits
  more on shallow buffers. Neither matters on a single-tenant host serving one
  household. qBittorrent uploads become somewhat more assertive toward peers'
  links.
- **Not doing:** replacing existing qdiscs at runtime. `default_qdisc` only
  applies to interfaces created afterwards, so on a re-run `tailscale0` keeps
  `fq_codel` until tailscaled restarts or the host reboots. BBR has paced
  internally since Linux 4.13, so `fq` complements it but is not required.
  Also not doing: per-socket `setsockopt(TCP_CONGESTION)` in any service.
- **Not an OS divergence:** this is a capability probe, not an
  `OS-DIVERGENCE` entry. `tcp_bbr` ships as a module on the Ubuntu 26.04
  kernel and on the Debian 13 kernel (`6.12.107+deb13-amd64`,
  `tcp_bbr.ko.xz`) — both verified live. If a future kernel drops it, the
  install stays on the default, which is what the probe is for.
- **Live-verified on Ubuntu 26.04.1 (`nrm`, 2026-09-11):** before the run the
  host was on cubic with `fq_codel`, and `tcp_bbr` was not loaded. The v2-79
  run logged `TCP: congestion_control=bbr default_qdisc=fq`, stage 7 raised no
  warning, and the run exited 0. Both files were written and no container was
  recreated. **`ss -tin` showed `bbr` on the WebDAV socket Caddy had accepted,**
  so the setting reached the socket that matters. Both qdisc predictions
  held. On the re-run `tailscale0` kept `fq_codel`, because existing qdiscs
  are not replaced. **After a reboot it came up with `fq`,** because
  `default_qdisc` was applied before tailscaled created the interface. After
  the reboot, `modules-load.d` had loaded `tcp_bbr` and the live value was
  still `bbr`. There were 0 failed units, and the post-reboot re-run exited 0
  and recreated nothing. The live-tested code differs from the committed code
  in one comment only. That comment was corrected afterwards so that it no
  longer describes the Debian module as verified.
- **Live-verified on Debian 13.6 (`nrm`, 2026-09-11), fresh install:** the
  preflight found `tcp_bbr.ko.xz` in the 6.12 kernel; stage 2 logged
  `TCP: congestion_control=bbr default_qdisc=fq`; the WebDAV socket Caddy
  accepted ran `bbr`; and after a reboot the module was loaded from
  `modules-load.d`, the live value was still `bbr` and `tailscale0` came up
  with `fq`. Both supported distributions have now had the same measurement.

### DD-113: Security updates install themselves; reboots stay with the operator (2026-09-12)

- **Partly superseded by DD-184 (v2-158):** Tailscale and Caddy now join
  the unattended upgrades at `APT_UPGRADE_TIME`; the "Why the distribution's
  filter" clause below no longer holds for them, and Docker is gone (DD-152).

- **Decision:** stage 1 installs `unattended-upgrades` and writes
  `20auto-upgrades` (`Update-Package-Lists "1"`, `Unattended-Upgrade "1"`)
  and a `52master-stack-unattended` drop-in with `Automatic-Reboot "false"`,
  then enables the `apt-daily` timers. The package's origin filter is left
  at the distribution default: Debian stable + security, Ubuntu security
  (+ESM). Stage 7 reads the effective `APT::Periodic::Unattended-Upgrade`
  back and checks `apt-daily-upgrade.timer`; a mismatch warns, as in DD-111.
- **Why:** the netcup Debian 13 image ships without `unattended-upgrades`
  (Ubuntu's ships with it, enabled). Until now a Debian host got security
  fixes only when the operator re-ran the installer and answered the
  full-upgrade prompt. For a host with sshd, WireGuard and Tailscale on the
  WAN, that gap was the one thing the 2026-09-12 review of the fresh Debian
  host found worth changing; everything else measured was already where it
  should be.
- **Why the distribution's filter:** Docker, Tailscale and Caddy come from
  their own repositories (origins `Docker`, `Tailscale`,
  `cloudsmith/caddy/stable`), which the default `Origins-Pattern` does not
  match. So the daemon that runs the containers, the tailnet daemon and the
  reverse proxy are never upgraded behind the operator's back; a re-run of
  the installer updates them, as before. Debian's default also takes stable
  point-release updates (`label=Debian`), which are conservative by design.
- **Why no automatic reboot:** a kernel update lands but takes effect at the
  next reboot, and `/var/run/reboot-required` says so. Rebooting an exit
  node in the night because a kernel arrived is a policy the operator
  should hold, not the package. The drop-in pins the default so a future
  distribution change cannot flip it.
- **Ubuntu interplay:** on Ubuntu `needrestart` runs in automatic mode during
  unattended upgrades and may restart sshd, tailscaled or dockerd after a
  library update; that was already the case before this change, because the
  package was present and enabled. DD-103 suspends it only for the
  installer's own apt calls. On Debian `needrestart` is absent, so updated
  libraries are picked up at the next service restart or reboot.
- **Not an OS divergence:** the same package and files on both
  distributions; on Ubuntu the install is a no-op and the periodic file
  matches what the image already had. Not adding a mail/report hook,
  `-updates` on Ubuntu, or `Remove-Unused-Dependencies`.
- **Live-verified on Debian 13.6 (`nrm`, 2026-09-12):** a re-run over the
  restored v2-79 host installed the package, wrote both files and changed no
  container; the effective apt-config shows the periodic upgrade on and
  automatic reboot off, and a `--dry-run --debug` lists only the three Debian
  origins as allowed. The first attempt exited 141 at the new read-back —
  `apt-config dump | awk '...; exit'` under `pipefail` — after every stage
  had completed; the read-back now lets `awk` consume the whole stream (see
  `tests/README.md`). Ubuntu: not re-run; the files match what the Ubuntu
  image already carries, and the package is present there by default.

### DD-120: WireGuard runs in the host kernel from kurulum/wireguard; wg-easy is removed (2026-09-14)

- **Decision:**
  - **What goes away:** the `wg-easy` Compose service, its bridge network,
    volume definition, `WG_EASY_IMAGE`, `WG_UI_PORT` and `WG_BRIDGE_*`, plus
    the tailnet name `wg.${LOCAL_DOMAIN}` and its Caddy site. WireGuard is
    `wg-quick@wg0` on the host with the same addresses as wg-easy
    (`10.8.0.1/24`, `fdcc:ad94:bacf:61a4::cafe:1/112`, UDP `WG_PUBLIC_PORT`,
    MTU 1420), so existing client profiles connect unchanged.
  - **Inputs:** `kurulum/wireguard/sunucu.key` (the server private key) and
    one wg-easy-format profile per device, `kurulum/wireguard/<device>.conf`.
    The launcher sends them with `kurulum.env` as a tar stream to `INPUT_DIR`
    on `tmpfs`, each file mode-checked. Stage 0 reads the WireGuard folder
    into memory and deletes it before parsing `kurulum.env`, then deletes the
    whole input folder.
  - **Validation in stage 0, before any change:**
    - One `[Interface]` and one `[Peer]` per profile.
    - Well-formed keys and a PSK when present.
    - An IPv4 inside `WG_SUBNET4` that is not the network, broadcast or server
      address, and has no leading zeros.
    - An optional IPv6 in the server's `/112` written the wg-easy way.
    - Unique addresses and private keys, an `Endpoint` port equal to
      `WG_PUBLIC_PORT`, and a safe file name.
    - Messages name the file and the address, never a key.
  - **`ensure_wireguard`, at the end of stage 5, after the firewall:**
    - Installs `wireguard-tools` with `--no-install-recommends`, so no
      `wireguard-dkms`.
    - Checks that every profile's `[Peer] PublicKey` equals `wg pubkey` of
      `sunucu.key`.
    - Derives each peer's public key from its private key, key on stdin.
    - Writes `/etc/wireguard/wg0.conf` (`0600`) with the server key, peer
      public keys, PSKs and `AllowedIPs` only. Client private keys never reach
      the disk, and the file carries no `PostUp`.
    - Restarts `wg-quick@wg0` only when the file changed.
  - **Firewall (`firewall.sh` owns every rule, DD-16/DD-17):**
    - `MASTER-INPUT` accepts, from `wg0`, only TCP to `10.8.0.1` on the three
      UI ports and ping; everything else from `wg0` is dropped (IPv6: all).
    - A new `MASTER-FORWARD` chain at the top of `FORWARD` accepts `wg0` → WAN
      and replies, and drops everything else to or from `wg0`: the tailnet,
      Docker networks, other peers.
    - A new `MASTER-NAT` chain in `nat POSTROUTING` masquerades both WireGuard
      subnets out of the WAN.
    - The WireGuard `ctorigdstport` return leaves `MASTER-DOCKER`; the port
      stays in `MASTER-INPUT`.
    - `--check` asserts the new rules, their order (read from `iptables -S`,
      where `-d` precedes `-i`) and the exact `MASTER-FORWARD` rule count.
  - **UIs over WireGuard:** a second Caddy, `caddy-wg.service` with
    `templates/Caddyfile.wg`, has `admin off` and `default_bind 10.8.0.1`. It
    proxies `http://10.8.0.1:{61002,61006,61007}` to the loopback UIs, with no
    names and no WebDAV. It `Requires`/`PartOf` `wg-quick@wg0` and has no
    Tailscale dependency.
  - **Stage 7:** checks the listen port, that the peer count equals the
    profile count, the `wg0` address, and a non-5xx from each `caddy-wg` port.
  - **No leftover gate:** a stale `wg-easy` container is not detected. The
    operator reinstalls from scratch, and the migration host had it removed by
    hand.
- **Why:** the peers never change, and wg-easy's layers were the source of
  past failures:
  - in-container `iptables-legacy` needing host modules (DD-10);
  - the IPv6 egress drop (DD-71);
  - the fixed bridge IP;
  - the first-run web setup (DD-12/DD-22).

  The tunnel itself was already the host kernel module; only the management
  layer changes.
- **Why a second Caddy and not the tailnet one:** Caddy refuses to start when
  any listener cannot bind, and the tailnet Caddy binds the Tailscale address.
  One process would take the WireGuard path down whenever Tailscale is down,
  which is exactly when the user wants the backup path.
- **Why no tailnet over WireGuard (the user's call, 2026-09-14):** it would
  need NAT to `tailscale0`, and a lost device would become a tailnet member
  with this node's rights. `ts-forward` already drops new connections into the
  tailnet from other interfaces; `MASTER-FORWARD` is a second layer.
- **Measured on `nrm` (2026-09-14):**
  - The OpenSSL 3.5 X25519 derivation equals `wg pubkey`, and macOS LibreSSL
    3.3.6 cannot derive, so key checks run on the server.
  - wg-easy v15's client template is `Address = <v4>/32, <v6>/128`, `DNS`,
    `MTU`, and `[Peer]
    PublicKey`/`PresharedKey`/`AllowedIPs`/`PersistentKeepalive`/`Endpoint =
    host:port`.
  - `caddy validate` accepts the `Caddyfile.wg` shape, and `caddy adapt` shows
    listeners `10.8.0.1:<port>`.
  - Docker leaves the `FORWARD` policy `ACCEPT` here because forwarding was
    already on.
  - `wireguard-tools` recommends `wireguard-dkms`.
- **Rollback:** the `docker_wg_easy_data` volume is kept. Disabling
  `wg-quick@wg0` and `caddy-wg` and re-running v2-85 brings wg-easy back with
  the same keys.
- **Verified (2026-09-14):**
  - bats 119 ok, with `bash -n` and `shellcheck` clean. The new tests cover
    input parsing in wg-easy's format, thirteen rejection cases that never
    echo a key, `wg0.conf` rendering (public keys only, restart only on
    change, a foreign server key stopping before the file changes), firewall
    rule presence and order, the `MASTER-FORWARD` count and order checks, and
    the `caddy-wg` wiring. Four deliberate mutations each failed their test.
  - **Migration on `nrm`:**
    - The four device profiles were generated from wg-easy's database into
      `kurulum/wireguard/` without printing a key.
    - Each profile's derived public key, PSK and server key matched the
      running wg-easy peers, and the interface key matched `sunucu.key`.
    - `docker rm -f wg-easy` (volume kept).
    - The exported v2-86 `.command` then ran with the operator's own
      `kurulum/` folder, never opened. That night the node had been deleted
      from the tailnet (00:52 CEST); the auth key in the file logged it back
      in during stage 2, and it kept its Tailscale IP.
    - Result: exit 0 in 20 s. `wg0` listened on 61001 with 4 peers, `wg0.conf`
      was `0600` with one `PrivateKey`, and `caddy-wg` listened on the three
      `10.8.0.1` ports. `--check` passed, `MASTER-FORWARD` was first in
      `FORWARD`, the input folder was gone and the log held no key material.
  - **A temporary runtime peer in a network namespace** (`wg set`, never
    written to a file):
    - Allowed: ping `10.8.0.1`; Dozzle 307, Transmission 401 and FileBrowser
      200 on `10.8.0.1`; IPv4 and IPv6 internet egress, seen as the WAN
      addresses.
    - Blocked: SSH to `10.8.0.1` and to the WAN address, WebDAV on the TS IP,
      tailnet Caddy, dnsmasq, the WebDAV container's bridge IP, an online
      tailnet device (reachable from the host itself) and another peer.
    - The peer and the namespace were removed afterwards.
  - **A second run with the same folder:** a full no-op; every account, the
    firewall, WireGuard, dnsmasq, Caddy and `caddy-wg` were unchanged, and no
    container or unit start time moved.
  - **A reboot:** every unit active and none failed, Tailscale online, `wg0`
    with 4 peers, `caddy-wg` on its three ports, `--check` passing with
    `MASTER-FORWARD` first, and the UIs, DNS and WebDAV (401) answering.
  - **A real device** (one of the four migrated profiles, unchanged on the
    device) connected, handshook and opened Dozzle at
    `http://10.8.0.1:61002`, confirmed by the user.
  - **Not verified:** a fresh install on a bare Debian host with these
    inputs.

### DD-122: container-backup is retired; kurulum/ is the only thing to keep (2026-09-14)

- **Note (DD-128, 2026-09-14):** `kurulum/` now also holds settings pulled by
  `ayarlar.command` (WireGuard, qBittorrent). This is a narrow snapshot the
  installer restores where absent, not a container backup.

- **Decision:** `container-backup.command`, its worker
  `dev/container-backup-remote.sh`, `docs/container-backup.md` and
  `tests/backup-roundtrip.sh` are removed. A test fails if any of them
  returns. `/backup/` stays Git-ignored so old archives cannot be committed;
  nothing reads them.
- **Why:** since v2-86 the backup had nothing left to carry. It saved one file
  per service (DD-114), and every one of them now comes from the installer:
  the accounts from `kurulum.env` (DD-119), the Transmission preferences from
  the installer (DD-118), and the WireGuard keys and peers from
  `kurulum/wireguard/` (DD-120, DD-121) instead of `wg-easy.db`. A reinstall
  from `kurulum/` produces the same host. The user keeps that folder on the
  workstation and asked for the tool to go.
- **Not doing:** a replacement that archives `kurulum/`. The user keeps the
  folder on the workstation and does not want it copied elsewhere.
- **Supersedes:** DD-112 and DD-114 (the tool they describe no longer exists).

### DD-123: WireGuard changes are applied the kernel WireGuard way, without a restart (2026-09-14)

- **Decision:** when `wg0.conf` changes and `wg-quick@wg0` is running with the
  same `Address` and `MTU`, the installer applies it with `wg syncconf wg0
  <(wg-quick strip wg0)`. That covers adding or removing a peer, a PSK, the
  listen port and the server key. The interface is restarted only when it is
  not running, when `Address` or `MTU` changed (the settings only `wg-quick`
  applies), or when `syncconf` fails. An empty `wg-quick strip` is never
  passed on: syncconf would remove the key and every peer.
- **Why:** this is how kernel WireGuard is meant to be changed, and the user
  asked to follow the native protocol rather than wg-easy. v2-86/87 restarted
  the interface on any change, dropping every connected device and restarting
  `caddy-wg` (`PartOf`) just to add one `[Peer]` block. `syncconf` updates
  only what differs, so existing sessions and handshakes stay up.
- **How the WireGuard model maps (for the record):** the server has one key
  pair. Every device has its own random key pair, unrelated to the server's.
  The device profile carries the server's public key, and the server's
  `wg0.conf` carries one `[Peer]` block per device (its public key, PSK and
  `AllowedIPs`). Adding a device adds such a block; nothing is derived from
  the server's private key.
- **Verified:** bats covers the live path, a no-op, a failed syncconf falling
  back to a restart, an empty strip output never reaching syncconf, and an MTU
  change restarting. Two deliberate mutations each failed the test.
- **Live on `nrm` (v2-88, the operator's folder):**
  - The temporary peer `deneme` was removed from `WG_PEERS`. The run logged
    the change as applied live and the unlisted-profile warning for
    `deneme.conf`, and went from 5 peers to 4, the other four unchanged.
  - `wg-quick@wg0` and `caddy-wg` kept their start times. `master-firewall`
    restarted because the version change rewrote `state.env`, as on every
    version bump.
  - After `deneme.conf` was deleted, a further run reported WireGuard, the
    firewall, dnsmasq, Caddy and `caddy-wg` unchanged.

### DD-124: The server generates and owns WireGuard peers; wireguard.command manages them (2026-09-14)

- **Amended by DD-128 (2026-09-14):** the server stays the source of truth
  while it lives, but `ayarlar.command` pulls `wg0.conf` and the profiles into
  `kurulum/`, and a fresh install restores them. A reinstall then keeps the
  key and peers, instead of "nothing sent, new key".

- **Decision:**
  - `/etc/wireguard/wg0.conf` on the server is the WireGuard source of truth.
    The installer writes only its `[Interface]` part: the server key is
    generated with `wg genkey` when the file is missing and kept afterwards,
    together with every `[Peer]` block.
  - Peers are added and removed on the server by `master-wg`, installed to
    `/usr/local/sbin`. It generates the keys and PSK with the `wg` tools,
    allocates the next address, stores the device profile in
    `/etc/wireguard/clients/` and applies the change with `wg syncconf`
    (DD-123). A failed apply is rolled back, and it shares the installer's
    lock.
  - `wireguard.command`, at the repository root, is the operator's menu: list,
    add (name, DNS, keepalive, MTU), remove, show QR. It calls `master-wg`
    over SSH with `%q`-quoted arguments, prints the QR code and saves the
    profile to `kurulum/wireguard/<name>.conf` (`600`). It reads only
    `SSH_HOST` from `kurulum.env` and refuses a server running another
    version.
  - Removed: `WG_PEERS`, `WG_CLIENT_DNS`, `WG_CLIENT_KEEPALIVE` and
    `WG_CLIENT_DNS_OVERRIDE` in `kurulum.env`; profile parsing, validation and
    regeneration in the installer; sending `kurulum/wireguard` to the server;
    and the launcher's fetch-back. The DNS and keepalive defaults moved to
    `defaults.env` as prompt defaults (keepalive 21, the user's value).
- **Why:** the user wanted peer management to work the way WireGuard is
  administered natively, easy to add and remove, with nothing secret sent to
  the server: "the server generates, we take it". Each device profile carries
  its own DNS, keepalive and MTU, which are client-side settings the server
  never uses. Keeping a workstation folder as the truth (DD-120/121) would
  have made the installer overwrite per-peer choices or require sending keys
  up.
- **Trade-off (accepted by the user):** a reinstall generates a new server key
  and starts with no peers; devices are added again with the menu. The copies
  in `kurulum/wireguard/` are for re-importing on a device, not for rebuilding
  the server. `nrm` is a test host and its old peers were not carried over.
- **Also fixed while testing:**
  - `state.env` now quotes `WG_CLIENT_ALLOWED_IPS`: its space made `source
    state.env` run `::/0` as a command, which would have broken `master-wg`
    and `master-firewall`.
  - `master-wg list` used a helper that overwrote the loop's `line` variable,
    losing the next peer's name.
- **Supersedes:** DD-121, and DD-120's input model (the kernel interface,
  firewall and `caddy-wg` parts of DD-120 stand).
- **Verified:** bats 120 ok, with `bash -n` and `shellcheck` clean. Functional
  tests run the real `master-wg` against PATH stand-ins for `wg`, `wg-quick`,
  `systemctl`, `flock` and `qrencode`. They cover: add (keys generated
  server-side, profile `0600` with the asked DNS/keepalive/MTU, next address,
  live apply), list, profile, QR and version; eight rejected inputs and a
  duplicate that change nothing; removal of exactly one block and reuse of its
  address; rollback of a failed apply; an empty strip never reaching syncconf.
  `ensure_wireguard` is covered for a first install, a re-run that keeps the
  peers byte for byte, a live port change, an MTU restart and a missing server
  key. Three deliberate mutations each failed their test.
- **Live on a freshly reset `nrm` (Debian 13), with the operator's `kurulum/`
  folder:**
  - The exported v2-89 `.command` installed from bare metal: exit 0 in about a
    minute. The auth key logged in to Tailscale, a server key was generated,
    `wg0.conf` held `[Interface]` only (`0600`), `master-wg` answered its
    version, `--check` passed, and neither password nor auth key reached the
    log.
  - `wireguard.command`, driven under `expect`:
    - `test1` with the defaults got `10.8.0.2`: DNS `1.1.1.1,
      2606:4700:4700::1111`, keepalive 21, MTU 1420.
    - `test2` with DNS `9.9.9.9, 149.112.112.112`, keepalive 0 and MTU 1380
      got `10.8.0.3`.
    - Both printed a QR code and saved a `600` profile to
      `kurulum/wireguard/`.
    - A second `test1` was refused. The list showed both; the QR display
      re-fetched a profile.
  - The fetched `test1` profile, used as a client in a network namespace:
    handshook and the list showed its transfer. It reached ping, the three UIs
    and the internet over IPv4 and IPv6, and was refused SSH, WebDAV on the TS
    IP, tailnet Caddy and the other peer.
  - Removing `test2` from the menu deleted its block, its server profile and
    the local copy.
  - A re-run with the same folder restarted no unit and no container and left
    `wg0.conf` byte-identical, with `test1` kept.
  - After a reboot every unit was active and none failed, `test1` was still
    there, `--check` passed with `MASTER-FORWARD` first, and the UIs answered.
  - `test1` was removed at the end: the server has no peers and
    `kurulum/wireguard/` is empty.
- **Real devices (2026-09-14):**
  - The operator added `pppp` (`10.8.0.2`) and this Mac, `mmmm` (`10.8.0.3`),
    from the menu. Both handshook and passed traffic.
  - On the Mac, over the tunnel:
    - Egress used the server's IPv4 and IPv6, and the MTU of 1420 held.
    - DNS did not leak: Tailscale's resolver forwards to the tunnel's `1.1.1.1`.
    - The three UIs answered on `10.8.0.1`.
    - These stayed closed when bound to the tunnel interface: SSH on all three
      addresses, WebDAV, tailnet Caddy, dnsmasq, another tailnet node, the other
      peer and the UIs over IPv6. The `wg0` DROP counters rose.
    - With Tailscale also up, the `*.ayc` names and WebDAV kept working.
  - Speed to public test sites was 120–210 Mbit/s through the tunnel against
    265–407 Mbit/s direct. The server CPU stayed about 97% idle, so the limit
    was the server's path to those sites. The Mac-to-server measurement under
    "Failure tests" below replaces it.
- **Known limit, kept by choice:**
  - `SSH_HOST` points at the server's public IP. While the Mac itself is on
    the full tunnel, that IP is routed into `wg0`, where SSH is dropped, so
    `wireguard.command` times out.
  - The operator switches WireGuard off on the Mac before using the menu.
  - A hint, a Tailscale fallback or SSH over `wg0` were offered and declined.
- **Failure tests on `nrm` (2026-09-14), with this Mac on the tunnel:**
  - Setup:
    - Each disruptive step ran as a transient `systemd-run` script on the
      server, so a lost SSH session could not leave it half done. A Mac loop
      polled `10.8.0.1` and the internet meanwhile.
    - Temporary pieces (a sender on `10.8.0.1:5201-5205`, its `MASTER-INPUT`
      accept rule, the scripts and a safety timer) were removed afterwards, and
      `--check` passed.
  - **Throughput, Mac to server** (zeros, no compression; outside the tunnel
    over SSH on the Mac's physical interface):

    | | Through `wg0` | Outside the tunnel (SSH) |
    |---|---|---|
    | Download, 1 stream | 461–498 Mbit/s | 237–241 Mbit/s |
    | Download, 4 streams | 386–465 Mbit/s | 495–526 Mbit/s |
    | Upload, 1 stream | 48 Mbit/s | 51 Mbit/s |

    - With 4 streams the server was 75–80% idle, with the `wg-crypt-wg0`
      workers spread over all 4 cores. The Mac was only about 40% idle.
    - The ceiling is the Mac's WireGuard client and the home line (about 50
      Mbit/s up), not the server.
    - Public test sites began answering 429 and were dropped as a
      measurement.
  - **`wg-quick@wg0`:**
    - `restart`: `caddy-wg` restarted with it (`PartOf`). Both peers came
      back, `wg0.conf` was unchanged, and `--check` passed. The Mac recovered
      in about 15 s, the WireGuard handshake retry.
    - `stop`: `caddy-wg` stopped with it, and the Mac's internet stopped too:
      the client fails closed.
    - `start`: `caddy-wg` came back through its `WantedBy`, and the Mac
      recovered at once.
  - **`systemctl restart docker`:**
    - Containers were healthy again in 11 s; `caddy-wg` answered 502 in
      between.
    - `master-firewall` re-applied itself (`PartOf`), with `MASTER-FORWARD`
      still first and `DOCKER-USER` jumping to `MASTER-DOCKER`.
    - Transmission's bridge IP moved from `.5` to `.4` (DD-16). Bridge IPs
      were unreachable over WireGuard before and after.
    - The Mac's poll with a 1 s timeout showed scattered timeouts around this
      step, some before the restart. They did not recur: 40/40 polls
      succeeded afterwards and ping loss was 0%.
  - **`tailscaled` stopped for 3 min 37 s:**
    - The WireGuard path held: 109/109 Mac polls got the three UIs and
      internet egress.
    - `caddy-wg`, `wg0`, dnsmasq and Docker stayed active, and the firewall
      rules and `--check` held. `master-firewall` showed inactive through
      `PartOf`, but has no `ExecStop`, so its rules stayed in place.
    - Tailnet names, WebDAV and DNS on the TS IP were unreachable, as
      expected.
    - `tailscaled` came back online in 1 s, and names, WebDAV and DNS
      answered at once. Caddy was not restarted: its sockets on the TS IP
      stayed bound.
    - `master-firewall` re-applied with `MASTER-FORWARD` first, the exit node
      was offered again and no unit failed.
  - **Open:** `pppp` had not handshaken since the `wg0` restart. Its tunnel was
    probably off or the phone asleep; the user checks it on the phone.

### DD-125: A smaller footprint — no Docker recommends, no kept apt downloads, no debian-keyring (2026-09-14)

- **Docker part superseded by DD-152 (2026-09-19):** Docker is not installed at all.

- **Context:** after a fresh v2-89 install the operator saw disk use grow by
  about 1.7 GB.
  - Measured on `nrm`: 672 MB of new packages, 421 MB of images and a 303 MB
    apt cache holding all 73 downloaded `.deb` files.
  - Of the packages, about 200 MB served nothing in this stack: Docker's
    recommends (`git` with `perl`, `docker-ce-rootless-extras`) and
    `docker-buildx-plugin`.
  - The rest of the gap in the provider panel was freed but untrimmed blocks,
    released by the weekly `fstrim.timer`.
- **Decision:**
  - **Docker:** installed with `--no-install-recommends` as `docker-ce
    docker-ce-cli containerd.io docker-compose-plugin apparmor pigz`.
    - The stack never builds images and never runs rootless, so buildx, git
      and rootless-extras go.
    - Two recommends the runtime uses are named explicitly. `apparmor`
      provides the parser for the `docker-default` profile when the kernel has
      AppArmor on. `pigz` speeds up layer decompression.
  - **apt downloads:** `APT_OPTS` carries `APT::Keep-Downloaded-Packages=false`,
    so every `.deb` the installer downloads is deleted once installed.
    Nothing else in the cache is touched (DD-96), and unattended-upgrades is
    not reconfigured.
  - **debian-keyring:** no longer installed. The Caddy repo is verified by
    its `signed-by` cloudsmith keyring, so the package did nothing. This
    removes the tree's only real `if OS = debian` branch (`caddy-keyring-pkg`
    in the OS-divergence inventory).
  - **Fix found on the way:** `retry` runs a shell function through
    `export -f` and `bash -c`, and arrays do not cross into that child.
    - As a result, `apt_get_install_masked_quiet` (dnsmasq, Caddy) had run
      with an empty `APT_OPTS` since DD-102: no lock timeout, and now no
      download cleanup.
    - The callers now pass `"${APT_OPTS[@]}"` as arguments, and a bats test
      runs the helper under `retry` with a mocked `apt-get`.
- **Not doing:**
  - Switching Docker from the containerd image store back to `overlay2`. It
    would drop about 114 MB of compressed layers, but go against the Docker 29
    default.
  - Removing anything from existing hosts. A re-run installs nothing new and
    removes nothing, so buildx, git or debian-keyring already on a host stay
    until the operator removes them.
- **Trade-off:** `apparmor` and `pigz` become manually installed packages in
  apt's view. Both were already present, from the image or through Docker.
- **Verification:**
  - bats 122 ok. `shellcheck -x` is clean.
  - Deliberate mutations each failed a test: recommends back, the apt option
    dropped, buildx back, a masked-quiet caller without `APT_OPTS`.
  - **Live on `nrm` (Debian 13), with the scratch test inputs and the real
    account files saved and restored:**
    - Fresh-path simulation:
      - `apt-get clean`.
      - Docker, containerd, compose, buildx, rootless-extras, git/perl, pigz,
        Caddy, dnsmasq and debian-keyring purged, `/var/lib/docker` and
        `/var/lib/containerd` removed.
      - The Caddy repo list and keyring deleted.
    - The first v2-90 run stopped at stage 7 on a transient registry error
      (`error from registry: retry-after …`) while pulling. A plain re-run
      finished with exit 0.
      - That run showed the two masked-quiet installs without the options: 4
        `.deb` files left, and apt history lines without `-o`. This led to the
        fix above.
    - After the fix, purged again, one run with exit 0 in 41 s:
      - apt's "Recommended packages" listed rootless-extras, git and buildx as
        not installed.
      - All three apt history lines carried both options, and the cache held
        0 `.deb` files.
      - The cloudsmith InRelease verified with no warning and no
        debian-keyring.
      - Docker 29.8.0 with Compose v5.5.1 and no buildx. The AppArmor
        `docker-default` profile was enforced.
      - All 5 containers were up (the 3 with health checks healthy), and every
        unit was active with none failed.
      - `--check` passed with `MASTER-FORWARD` first. Both WireGuard peers were
        kept.
      - The UIs, tailnet names, DNS and WebDAV answered.
      - The log held no test password.
    - A second run was a full no-op, and its before/after snapshot was
      identical: unit and container start times, `wg0.conf`, both
      Caddyfiles, `compose.yaml` and the cache.
    - `df` used on `/`: 2389 MB with v2-89, 1940 MB with v2-90 (−449 MB).
      `fstrim` then returned freed blocks to the virtual disk.

### DD-126: Negated bats assertions must be able to fail under bash 3.2 (2026-09-14)

- **Context:** the suite runs under macOS `/bin/bash` 3.2 (Bats 1.14.0).
  - A mid-test `! cmd` never fails a test, because errexit ignores negated
    commands.
  - A mid-test `[[ ]]` does not fail under bash 3.2 either.
  - So most negative assertions in `tests/common.bats` checked nothing.
  - The finding and a first conversion came from a separate session on a
    v2-84 base. That work was never merged and is kept on branch
    `wip/bats-negation-v2-84`; v2-91 redoes it on the current tree.
- **Decision:**
  - Every negation is `run !`: 115 statements, 86 simple ones converted
    mechanically and the rest by hand. Pipelines are captured into a variable,
    guarded with `[ -n ]` so an empty awk range cannot pass, and checked with
    `run ! grep … <<<"$var"`.
  - Every `[[ ]]` is `[ ]` or `case`.
  - A guard test fails the suite if a bare `! ` or `[[ ` statement appears
    again.
- **What the now-effective assertions exposed:**
  - **Four tests matched comments or deliberate text** and now look at code
    lines only:
    - the deprecated `--disable-exec` named in a compose comment;
    - `try-restart` in refresh-tailnet-config's DD-72 comment;
    - the old FileBrowser password hints matching the DD-118 comment in
      `install.sh`;
    - `docker rm` / `docker volume rm` in the qBittorrent and Portainer
      `die`/`log` messages, which tell the operator what to run
      (DD-116, DD-117). DD-96's guard wording now says so.
  - **One was real:**
    - `stage_6` still recreated `webdav` when it published
      `${TAILSCALE_IPV4}:${WEBDAV_PORT}`. Only the uncommitted v2-65 working
      tree ever had that layout, so no host needs the step.
    - It is migration cleanup, which DD-96 excludes, and the test forbidding
      it had been silent since v2-67. The block is removed. The user chose
      this (option A).
- **Verification:**
  - bats 123 ok; the same 3 `timeout yok` skips as before.
  - `shellcheck -x` is clean.
  - A diagnostic copy of the suite logged the exit code of every negated
    command: all 144 evaluations returned 1, and none passed on a grep error
    (2).
  - Deliberate mutations each failed their test:
    - a real `docker rm` command;
    - a real `try-restart` line;
    - `--disable-exec` in code;
    - the removed WebDAV log line put back;
    - a code line with the old password hint;
    - a bare `!` assertion.
  - The removed block could only run on the uncommitted v2-65 layout, so no
    live run was needed.

### DD-130: wireguard.command changes a peer's DNS and regenerates wg0 (2026-09-14)

- **Extended the same day:** the user did not want to wait for a manual
  backup. Options 2 (add), 3 (remove) and 7 (DNS) now run option 6 after a
  successful change, as option 8 already did.
  - Before, the menu only printed a reminder. A forgotten backup left
    `kurulum/wireguard/` behind the server, and a reinstall on a fresh server
    brought back a removed peer or missed a new one (DD-128).
  - A refused confirmation or a failed server call takes no backup. A failed
    backup does not undo the change; it warns and points to option 6.
  - Only `wireguard.command` changed. It is not part of the installer
    archive, so `V2_VERSION` stays v2-97 and the server needs no re-run.
  - bats 135 ok. Mutations were each caught: no backup after add, remove or
    DNS; a backup after a failed add; a backup after a declined remove.

- **Context:** the user benchmarked resolvers and wanted to point one peer at
  NextDNS without removing it. They also wanted a clean `wg0`: a new server
  key, with every peer and profile deleted when some exist.
- **Decision — DNS change (option 7, `master-wg dns NAME DNS`):**
  - Only the `DNS =` line of the stored profile's `[Interface]` changes. The
    keys, PSK, address and `wg0.conf` stay the same.
  - DNS is a client setting the server never sees, so nothing is applied and
    connected devices stay up. The device imports the new profile or QR code.
  - The list is validated as IPv4/IPv6 addresses and normalised to
    `a, b`, the form `add` writes.
  - The menu offers the current DNS as the default and saves the new profile
    to `kurulum/wireguard/`.
- **Decision — regenerate `wg0` (option 8, `master-wg reset --onay`):**
  - The `[Interface]` lines are kept (comment, address, port, MTU); only
    `PrivateKey` is new. Every `[Peer]` block and every profile in
    `/etc/wireguard/clients/` is removed. With no peers it is just a new key.
  - It goes through the same `write_and_apply` as `add`/`remove`, under the
    installer lock. A failed apply restores the previous `wg0.conf`, and
    profiles are deleted only after a successful apply.
  - Two guards: the server tool refuses without `--onay`, and the menu lists
    the peers and asks for `SIL` (or `SİL`). Anything else changes nothing.
  - The menu then runs option 6 "Yedek al". Otherwise `kurulum/wireguard/`
    would keep the old `wg0.conf` and profiles, a reinstall on a fresh server
    would restore the old key (DD-128), and deleted profiles would come back.
- **Rejected:**
  - Rebuilding `wg0.conf` from `defaults.env`: it would override a live
    interface the installer already manages (DD-124); a re-run of the
    installer does that part anyway.
  - Keeping peers with a new server key: every device would still need a new
    profile, so it is no better than adding them again.
  - Changing DNS by removing and re-adding the peer: new keys and address
    for a client-only setting.
- **Verified (2026-09-14):**
  - bats 134 ok; mutations of the `--onay` guard, the profile deletion, the
    `[Interface]` scoping of the DNS rewrite, the `SIL` check and the backup
    after reset were each caught.
  - On `nrm`, the new `master-wg` ran against a throwaway `wgtst0` interface
    (its own `STATE_FILE`, subnet `10.99.0.0/24`, port 61901) with two test
    peers.
    - `dns` wrote the NextDNS IPv6 pair; every other profile line,
      `wgtst0.conf` and the interface key were unchanged, with 2 peers still
      up. A hostname was refused.
    - `reset` without `--onay` was refused. With it: "2/2", a new key, 0
      peers on the interface and in the file, no profiles, the four
      `[Interface]` lines kept, mode 600, the unit still active on its port.
    - `wg0` (key and peers) was unchanged; the test interface and files were
      removed afterwards.

### DD-131: WireGuard client DNS default — Cloudflare IPv4 first, one IPv6 third (2026-09-14)

- **Context:** the user wanted the lowest-latency Cloudflare setup as the
  default of `wireguard.command` → 2) ekle. The old default was
  `1.1.1.1, 2606:4700:4700::1111`. Peers' DNS queries leave through `nrm`,
  so the `nrm`→Cloudflare leg is the part the address choice can change.
- **Measured from `nrm` (2026-09-14, raw UDP queries, orders shuffled):**
  - All four addresses reach Cloudflare's Frankfurt PoP (`colo=FRA`), with
    no loss.
  - Ping: IPv4 about 4.3 ms, IPv6 about 3.8 ms.
  - Uncached names (random `*.cloudflare.com`): IPv4 median 7.3–8.4 ms, IPv6
    median 16.8–17.8 ms.
  - The same cached name 100 times: `1.1.1.1` answered 97–99 under 7 ms.
    `2606:4700:4700::1111` was bimodal: 46–53 under 7 ms and 46–54 at 12 ms
    or more. Ping answers at the edge; the DNS answer comes from a resolver
    behind it, so the lower ping did not mean faster DNS.
  - `::1001` against `::1111`, three runs of 120 cached and 60 uncached
    queries each:
    - Cached: `::1001` was ahead in every run (median 5.3–5.9 against 14.8 ms;
      mean 9.4–9.8 against 10.1–10.5 ms; 50–54% against 43–46% under 7 ms).
    - Uncached: mixed, overall mean 13.2 against 13.5 ms. Both stayed bimodal.
- **Decision:** `WG_CLIENT_DNS_DEFAULT="1.1.1.1, 1.0.0.1, 2606:4700:4700::1001"`.
  - The two IPv4 anycast addresses come first; either covers the other.
  - One IPv6 address is third, as a fallback for a client that only
    reaches IPv6; `::1001` for its slightly better cached answers.
  - IPv4 resolvers still return AAAA records, so IPv6 browsing through the
    tunnel is unaffected.
  - No other provider is mixed in: clients may spread queries across the
    list.
- **Scope:** only the menu's default for new peers. Existing peers keep their
  DNS until changed with option 7. The server never reads this key, so
  `V2_VERSION` stays v2-97 and the launcher is re-exported under the same
  version.
- **Revisit:** a single day's measurement from one host. If Cloudflare's
  IPv6 answers stop being bimodal, measure again before reordering.
- **Verified:** bats 135 ok. Option 2 with Enter sends exactly the defaults.env
  value, and `master-wg` writes it back unchanged, so option 7 offers it
  as-is. A hard-coded menu default and an unnormalised default list were each
  caught.

### DD-132: The QR code comes to the Mac as a PNG with the profile (2026-09-15)

- **Context:** the user wanted each profile's QR code saved next to it in
  `kurulum/wireguard/`, as JPG or PNG, to show it on a screen or another
  device without opening the menu.
- **Decision:**
  - PNG, not JPG: a QR code needs sharp module edges, and JPG compression
    blurs them. `qrencode` writes PNG directly.
  - The server makes it. `master-wg png NAME` runs
    `qrencode -t PNG -s 8 -o -` on the stored profile (616×616 px and about
    1.4 KB for a 388-byte profile).
    - It refuses when standard output is a terminal, so binary data is never
      printed.
  - `wireguard.command` saves `<name>.png` whenever it saves `<name>.conf`:
    add, DNS change, and "4) QR göster" with the refresh answer.
    - It goes through a temporary file, mode `600`, and is kept only when it
      starts with the PNG signature. Otherwise the menu warns and the profile
      stays.
  - "3) Peer çıkar" deletes both files locally, even when the backup after
    it fails.
  - The backup (option 6, and the automatic one) makes a PNG for every
    profile on the server.
    - They are made in `mktemp -d /run/wg-yedek.*` (tmpfs, root-only, removed
      on exit) at the same relative path as the profiles, and sent in the
      same tar.
    - A profile whose PNG fails still comes through, with a warning.
    - The Mac mirrors `.png` like `.conf`: a picture whose profile the server
      no longer has is removed.
  - The launcher still sends only `*.conf` (and `sunucu/wg0.conf`), so
    pictures never reach the server and stage 0's allow-list is unchanged.
- **Security:** the picture encodes the whole profile, client private key
  included, so it is protected exactly like the `.conf` file: mode `600` in
  the Git-ignored `kurulum/`, never printed, never sent to the server.
  Sharing the picture shares the tunnel.
- **Rejected:**
  - Making the PNG on the Mac: macOS has no QR encoder, and adding Homebrew
    `qrencode` would add a tool to install.
  - Keeping the PNG on the server: nothing there needs it, and it would be a
    second copy of the key to manage.
- **Fixed the same day:** with no profiles the script ended with
  `tar … -C <temp dir>` and no member after it. GNU tar 1.35 rejects that
  (exit 2), so the automatic backup after "8) wg0 yeniden üret" failed and
  the Mac kept the old files. macOS tar accepts it, which is why bats missed
  it. The `-C` part is now added only when a picture exists. A test runs the
  script with a GNU-strict `tar` wrapper, with and without profiles.
- **Cost:** `master-wg` changed, so this is v2-98. The menu refuses a server
  on another version; re-run the installer once. Peers, keys and accounts
  are kept.
- **Verified (2026-09-15):**
  - bats 137 ok. Eight mutations were each caught: terminal QR instead of PNG;
    no terminal check; no PNG-signature check; no PNG download in the
    backup; no stale-PNG removal; PNG not added to the tar; the server
    temporary directory kept; no local PNG removal on a remove whose backup
    fails.
  - On `nrm`, with the new `master-wg` against a throwaway `wgtst0`
    interface and two test peers:
    - `png` gave a valid PNG (616×616, 1,397 bytes), identical when made
      twice. On a pseudo-terminal it was refused; an unknown peer was
      refused.
    - The backup script listed `wgtst0.conf`, both profiles and both
      pictures, and left nothing in `/run/wg-yedek.*`. Its picture matched
      the one `png` made.
    - The test picture, decoded on the Mac with CoreImage, gave the
      388-byte profile byte for byte.
    - `wg0` (4 peers, 4 profiles) was untouched, and the test interface and
      files were removed.

### DD-133: A WireGuard web panel on the tailnet, built on master-wg (2026-09-15)

- **Partly superseded by DD-140, DD-147 and DD-180:** the separate
  `wg.<domain>` panel, its input-file account, Basic auth, lockout and the
  `127.0.0.1:61008` listener are gone; the backend is Konsol's root backend on
  a Unix socket. Still current: every change goes through `master-wg`,
  previews mask the keys, and the CSP, `no-store`/`DENY` headers and the unit
  sandbox stay.

- **Context:** the user liked the menu but wanted to manage peers from a
  browser as well: add, remove, show and download the QR code and profile,
  change DNS. A design prototype was approved, including tabs per interface.
  - Multiple interfaces (`wg1`, `wg2`, …) were agreed as a second step. This
    decision covers `wg0` only; the tab strip is ready for more.
  - Access option A was chosen: the tailnet only, with a password.
- **Decision:**
  - **Server-side and small.** `master-wg-panel` uses Python 3's standard
    library (already installed for the qBittorrent hash). There is no Docker
    and no new package. It listens on `127.0.0.1:61008`, and the tailnet
    Caddy proxies `http://wg.${LOCAL_DOMAIN}` to it. Nothing listens on `wg0`
    or the WAN, and stage 7 proves that.
  - **One rule set.** Every change calls `master-wg`, so the panel and
    `wireguard.command` share validation, the installer lock, the live
    `wg syncconf` apply and the rollback. `master-wg info` was added for the
    listing: `list`'s six fields plus IPv6, DNS, keepalive and MTU, never a
    key. `list` keeps its format for the menu.
  - **Account from the input file (DD-119).** `WG_PANEL_USER`/`WG_PANEL_PASS`
    are required keys; the password needs at least 12 characters, like
    FileBrowser, because the panel can mint tunnels.
    - The installer runs `master-wg-panel account` with the password on stdin.
      It stores PBKDF2-SHA256 (600000 rounds, 16-byte salt) in a `0600` file
      and keeps it while it verifies. The panel re-reads the file when it
      changes.
    - Stage 7 signs in with the input account through Caddy (`check`, also
      password on stdin) and then forgets the password.
  - **Authentication and abuse.**
    - HTTP Basic, the browser's own prompt. The tailnet (WireGuard) encrypts
      it, as for the other UIs.
    - A verified `Authorization` header is cached in memory for 15 minutes as
      a SHA-256 digest, so PBKDF2 runs once, not on every request.
    - Each wrong password waits one second. Ten in 15 minutes lock that client
      out for 15 minutes, keyed by the `X-Forwarded-For` Caddy sets, trusted
      only from loopback.
  - **Browser attacks.**
    - Basic credentials are sent automatically, so every `/api/*` request
      needs `X-WG-Panel: 1`. A cross-site page cannot add that header without
      a CORS preflight the panel never grants. A `Sec-Fetch-Site` other than
      `same-origin` or `none` is refused.
    - A `Host` other than `wg.${LOCAL_DOMAIN}` or the loopback port is refused
      (DNS rebinding).
    - The CSP allows only `'self'` (plus `blob:` for the QR picture), with no
      inline code. Responses are `no-store`, no-referrer and `DENY` for
      frames.
    - The page uses system fonts and loads nothing from other hosts.
  - **Secrets on demand.** The profile preview masks `PrivateKey` and
    `PresharedKey` on the server. The QR picture is fetched only after "QR'ı
    göster" and dropped after 60 seconds. Downloads fetch the full profile or
    picture only when clicked. The journal names user, client, action and
    peer.
  - **Least privilege that still works.** `master-wg` needs root
    (`wg syncconf`, `/etc/wireguard`). The unit adds `NoNewPrivileges`,
    `ProtectSystem=full` with only `/etc/wireguard` writable (the lock lives in
    `/run`), `ProtectHome`, `PrivateTmp`, kernel protections, no namespaces or
    realtime, and four address families.
  - **Backup state.** `wireguard.command`'s backup script touches
    `/etc/master-stack/wg-backup.at` after a successful archive. The panel
    shows "Mac yedeği eski" while `wg0.conf` or the profile directory is
    newer. Panel changes still reach the Mac only through option 6, since the
    server cannot write to it.
  - **DNS choices.** The default comes from `WG_CLIENT_DNS_DEFAULT` (DD-131),
    plus Google, Quad9 and every DNS list already used by a peer (for example
    the operator's NextDNS pair), and custom. No personal resolver address is
    hard-coded.
  - `wg` becomes a service name again. wg-easy's use ended with DD-120; the
    wg-easy test now checks that `wg.` points to the loopback panel.
- **Rejected:**
  - A login form with a session cookie: more code (cookie flags without
    HTTPS, session store, logout) for the same protection on the tailnet.
  - Caddy `basic_auth`: the hash would sit in the world-readable Caddyfile or
    need a group-readable import. Local processes could reach the upstream
    without a password. The panel would need a shared secret header to tell
    Caddy's requests apart.
  - A Unix socket: tighter, but the panel would need `caddy` group handling,
    and loopback with its own authentication already refuses local callers
    without the password.
  - Exposing the panel on WireGuard (option B): a device on `wg0` could delete
    its own tunnel or regenerate `wg0` and lock everyone out.
  - Reading `/etc/wireguard` directly from Python: a second parser and a
    second writer beside `master-wg`.
- **Cost:** v2-99 adds two required keys to `kurulum.env`; the installer stops
  with a clear message until they are there. One service, one Caddy site, one
  DNS name and port 61008 are added.
- **Verified (2026-09-15, bats):**
  - 143 ok. The panel was started against a fake `master-wg` for these checks:
    - 401 without or with a wrong password and 200 with the account;
    - the CSP, `no-store` and `DENY` headers;
    - 403 for another `Host`, for `/api` without the header and for a
      cross-site fetch;
    - JSON state with backup freshness;
    - exact `add`/`dns`/`remove`/`reset --onay` arguments;
    - bad names, bodies and confirmations never reaching `master-wg`;
    - `master-wg` refusals returned as messages;
    - a masked preview against a full download;
    - PNG only on request;
    - an audit log without secrets;
    - a new account read without a restart;
    - a 429 lockout for one client while another passes.
  - `account` keeps a matching hash, rewrites a changed one, stores no
    plaintext and leaves no temporary file.
  - `master-wg info` gives exact fields: keepalive 0 when absent, empty profile
    fields without a profile, no key material.
  - Thirteen mutations were caught, one of each guard: the panel header,
    `Sec-Fetch-Site`, `Host`, account reload, masking, the name check, the
    reset confirmation, the lockout, keeping a matching hash, keepalive 0 and
    the API origin gate.
- **Verified live (2026-09-15, `nrm`, Debian 13):**
  - The v2-99 launcher ran with a scratch input file and exited 0. Stage 7
    signed in to the panel through Caddy ("4 peer"). The operator's account
    files were saved and restored; FileBrowser's account export matched.
  - Through the tailnet Caddy (`Host: wg.ayc`):
    - 401 without or with a wrong password, and 200 with the account;
    - CSS and JS served with their types and the CSP; 403 for `/api` without
      the header;
    - state with the four real peers;
    - `paneltest` added (4 → 5 peers on `wg0`), a duplicate refused with
      master-wg's message;
    - the masked preview carried no key, the download carried it, and the QR
      PNG equalled `qrencode` of the stored profile;
    - DNS changed and a hostname refused;
    - removed (back to 4); `wg0.conf` and the profile list byte-identical to
      before the test;
    - a reset without `SIL` refused.
  - Another `Host` never reached the panel: Caddy answered its empty default.
    Nothing answered on `10.8.0.1:61008` or the WAN.
  - The unit showed `NoNewPrivileges=yes`, `ProtectSystem=full`, `/etc/wireguard`
    writable and four address families. The journal had audit lines and no
    password or key.
  - With the same sandbox (`systemd-run`) on a throwaway `wgtst0`:
    - two adds;
    - an add while the interface was stopped, which restarted it through
      `systemctl` from inside the sandbox;
    - a `SİL` reset (3 peers and 3 profiles removed, new key, unit active);
    - no permission errors, `wg0` untouched.
  - The scratch panel account was deleted afterwards, so the panel stays
    locked until the operator's install writes theirs.
- **Browser check (2026-09-15):** the real page ran against a loopback copy
  with sign-in removed, sample peers and a fake `master-wg`, never published.
  - Add opened the QR dialog with the masked profile, and the QR appeared on
    "QR'ı göster" with the 60 s countdown. The DNS presets included the
    operator's NextDNS pair as "Bu sunucuda". DNS change and inline remove
    confirmation worked, and typing `sil` enabled regeneration, which ended in
    the empty state.
  - A mouse click on "Çıkar" was lost once because the 10-second refresh
    replaced the rows. The refresh now updates status, age, traffic and
    totals in place while the peer set is unchanged; the same button element
    survived a refresh, and the click then worked.
- **Amended by DD-269 (v2-253):** the masked profile preview (`?masked=1`) is gone; a profile is a
  download or a QR only.

### DD-134: Regenerating wg0 is confirmed with "onayla"; the panel layout is tightened (2026-09-15)

- **Context:** after using v2-99, the user asked for three changes:
  - a smaller regenerate section;
  - the confirmation word "onayla" instead of "SIL";
  - wider table columns, because the DNS column wrapped a single character
    onto a new line and spare room sat beside the traffic column.
- **Decision:**
  - **One word everywhere.** The panel (page and server check) and
    `wireguard.command` option 8 accept `onayla` in any case; "SIL" no longer
    confirms. `master-wg reset --onay` is unchanged. The word lives once in
    each tool: `CONFIRM_WORD` in `master-wg-panel` and `panel.js`, the `case`
    in the menu.
  - **Compact danger row.** Smaller padding, title and text, a short input
    with `onayla` as placeholder, and a small button on one line. It keeps
    the red border, stays at the bottom, and the button stays disabled until
    the word is typed.
  - **Columns sized to their content.**
    - Status 7rem, name `minmax(6rem, .7fr)`, address `minmax(13rem, 1.2fr)`,
      DNS `minmax(14rem, 1.5fr)`, handshake 7.5rem, traffic 6rem, actions
      10.5rem.
    - Headers stay on one line.
    - An address never breaks: the IPv6 address is `nowrap`, and each DNS
      address is its own `nowrap` span, so lists wrap only after a comma.
- **Found in the browser check:** the confirmation input was full width. The
  generic `input[type="text"]` rule came later with equal specificity; the
  danger rule is now more specific.
- **The `cafe` in the IPv6 addresses:** not a protocol requirement. The
  `fdcc:ad94:bacf:61a4::cafe:0/112` range is wg-easy's default. DD-120 kept it
  so existing profiles connected unchanged; `cafe` is just a readable hex
  group. Changing it would give every peer a new address and profile, so it
  stays.
- **Verified (2026-09-15):**
  - bats 143 ok. The panel test now refuses `SIL` and accepts `Onayla`; the
    menu test refuses `SIL` and accepts `Onayla`. Two mutations were caught:
    accepting `sil` again in the panel and dropping the menu's lower-casing.
  - Browser check of the page against sample peers (Cloudflare, Google, Quad9)
    at 1440 px: one-line headers, no address split, and a one-line danger row.

### DD-135: WireGuard IPv6 addresses without a word: fdcc:ad94:bacf:61a4::N (2026-09-15)

- **Context:** the user asked to replace `cafe` in `fdcc:ad94:bacf:61a4::cafe:N`,
  the range kept from wg-easy by DD-120.
  - `root` and `peer` are not valid: IPv6 groups are hexadecimal (0–9, a–f).
  - Among the valid choices the user picked plain numbers.
- **Decision:**
  - `WG_SERVER_IPV6="fdcc:ad94:bacf:61a4::1"` and
    `WG_SUBNET6="fdcc:ad94:bacf:61a4::/112"` (the canonical form `ip6tables`
    prints). A peer's address stays the hex of its IPv4 host number:
    `10.8.0.2` → `…::2`, `10.8.0.10` → `…::a`.
  - `master-wg`, the panel and the firewall already derive everything from
    these two values; no code depended on `cafe`.
  - **Stricter snapshot check.** `wg_snapshot_check` used to test only that
    an address starts with the prefix. With `…::` as the prefix, `…::1:2`
    (outside the /112) or `…::cafe:2` would have passed. Now the part after
    the prefix must be only a hex host number (`/128`), and for IPv4 only
    digits (`/32`).
  - **No migration, by the user's rule (2026-09-15):**
    the scenario is a fresh install on a test server. Nothing converts, keeps
    or accepts peers, profiles or backups made with the `cafe` range.
    - A pulled `kurulum/wireguard` from before stops stage 0 with "AllowedIPs
      WireGuard alt ağı dışında"; delete it and install fresh.
    - Installing over a server that still has `cafe` peers leaves those peers
      without IPv6; reset and re-add them.
  - A stage-0 gate for old peers and an exception for an old backup were
    written and then removed at the user's request.
- **Verified (2026-09-15):**
  - bats 143 ok. Fixtures use the new range: `master-wg add` writes `…::2/128`
    and `info` lists it.
  - The snapshot check rejects `…::cafe:3/128`, `…::1:3/128` and
    `10.8.0.3.4/32`; two mutations (prefix-only IPv6 and IPv4 checks) were
    caught.
  - On `nrm`, `ip6tables -t nat -C … -s fdcc:ad94:bacf:61a4::/112` parsed the
    subnet (read-only).
  - The operator's pulled backup was rejected as expected (`…::cafe:2/128`).

### DD-136: More WireGuard networks from the panel; the panel stops pointing to the Mac backup (2026-09-15)

- **Context:** the user approved the tabbed design and asked for the second
  step: "Arayüz ekle" in the panel creating `wg1`, `wg2`, … with peers added
  and removed per network. They also asked to drop "Mac yedeği alınmadı" from
  the panel: `wireguard.command` is tracked separately, and the panel does not
  redirect to it.
- **Decision:**
  - **Runtime networks, not installer inputs.** Extra networks are created
    and removed from the panel through `master-wg net-add`/`net-remove`; the
    installer manages only `wg0`. Re-runs, reboots and firewall restarts keep
    them.
  - **One registry, three readers.** `/etc/wireguard/networks` holds one
    tab-separated line per network with every value spelled out (interface,
    port, scope, server and subnet IPv4/IPv6, default DNS, label).
    - `master-wg` computes the addresses once and writes the line;
      `master-firewall` and the panel read it and derive nothing.
    - It sits in `/etc/wireguard` because the hardened panel service may
      write only there (`ProtectSystem=full`), as do the per-instance Caddy
      env files.
  - **Addressing** follows DD-135: `wgN` = `10.8.N.0/24` and
    `fdcc:ad94:bacf:61a4::N:0/112`, a peer `10.8.N.H` / `…::N:H`. `wg0` stays
    `…::H`. At most `WG_NETWORKS_MAX` (9) extra networks.
  - **`master-wg --if wgN`** swaps every `WG_*` value (interface, port,
    addresses, `wgN.conf`, `clients-wgN`) before any command runs. So `add`,
    `remove`, `dns`, `reset`, `info`, `profile`, `qr` and `png` are unchanged
    and share one code path, lock and rollback.
  - **Safe order when adding.** Files and registry, then the firewall (the
    port opens and forwarding/NAT exist before the interface), then
    `wg-quick@wgN`, then `caddy-wg@wgN` for `ui`. A failure tears the network
    down and re-applies the firewall.
    - Ports are checked against the stack's ports (from `state.env`: SSH,
      torrent, WebDAV, UIs, Tailscale, panel, DNS, HTTP), wg0, other networks
      and live UDP listeners.
    - Stage 0 in turn refuses a `wg0`/WebDAV port a panel network uses.
  - **Firewall loops over networks.** `load_wg_networks` reads `wg0` from
    `state.env` plus the registry and validates everything (interface names,
    ports, scopes, addresses, duplicates) before any chain is built.
    - Per network: a WAN UDP accept; on INPUT an echo-request and a DROP, plus
      the UI ports on its own address only for `ui`; on FORWARD
      `-i wgN -o WAN ACCEPT`, `-i wgN DROP`, replies back and `-o wgN DROP`;
      a NAT masquerade per subnet.
    - A packet from one network to another dies at its own `-i … DROP`.
    - `--check` asserts every rule, forbids UI ports on an `inet` network and
      expects exactly `4 × networks + 1` FORWARD rules.
  - **`caddy-wg` becomes a template.** One `Caddyfile.wg` with
    `default_bind {$WG_BIND}`; `caddy-wg@<interface>` reads
    `/etc/wireguard/caddy-wg-<interface>.env`, requires and follows its
    `wg-quick@`. The installer restarts panel networks' instances when the
    shared file changes.
  - **Panel.**
    - `/api/state` returns every network with its peers.
    - Peer routes move under `/api/nets/<iface>/…`.
    - `POST /api/nets` adds a network; `/api/nets/<iface>/remove` and
      `/reset` need `onayla`.
    - The page shows a tab per network, a split "Peer ekle" button with
      "Arayüz ekle", a network drawer (next free `wgN`, suggested port, label,
      scope, default DNS) and a danger row per network (regenerate; remove for
      `wg1+`).
    - The network's default DNS leads the presets when adding a peer.
  - **Backup marker removed.** The panel's backup pill, the
    `/etc/master-stack/wg-backup.at` marker and its `touch` in
    `wireguard.command` are gone.
- **Not covered, by the user's split:** `wireguard.command` manages `wg0`
  only, and the Mac backup and the restore on a fresh install cover `wg0`
  only; panel networks are recreated in the panel. Earlier single-network
  servers are not migrated: the old `caddy-wg.service` stays on a server
  installed before v2-101, so install fresh (DD-135 rule).
- **Rejected:**
  - Networks in `kurulum.env`: the user wanted them created from the page.
  - A second Caddy per network file: one shared file and a template instance
    keep the UI surface identical.
  - Deriving addresses in each reader: three copies of the same arithmetic.
  - Letting the panel write `/etc/master-stack`: a wider sandbox for no gain.
- **Verified (2026-09-15):**
  - bats 145 ok.
    - The firewall's rules are generated for wg0 + an `inet` wg1 + a `ui` wg2
      and checked line by line (ports, UI only on `ui`, FORWARD order and the
      count of 13, NAT per subnet); a broken or clashing registry is refused
      before any rule.
    - `master-wg` tests cover `net-add` (addresses, registry, env file, order
      firewall → interface → Caddy, refusals, rollback on an interface or
      Caddy failure, the limit), `--if`, `nets` and `net-remove`.
    - The panel passes each network's actions with the right `--if` and
      refuses bad interfaces and confirmations.
    - Mutations were caught: WAN port only for wg0, UI ports on `inet`, no
      FORWARD DROP between networks, a duplicate port accepted, the interface
      before the firewall, a registry line left after rollback, wg0 removable,
      a panel network writing wg0's profiles, no interface check in the panel
      and removal without confirmation.
  - **Live on `nrm`** (v2-101 over a v2-100 install with scratch inputs; the
    old `caddy-wg.service` was removed by hand first):
    - Stage 7 passed ("1 ağ, 0 peer").
    - Through the panel API: wg1 (`inet`, 61011) and wg2 (`ui`, 61021) were
      created and a duplicate port was refused. The firewall showed three WAN
      UDP ports, 13 FORWARD rules in IPv4 and IPv6 and three NAT subnets, and
      `--check` passed. `caddy-wg@wg2` listened on `10.8.2.1`.
    - Real WireGuard clients in network namespaces:
      - wg1 reached the internet over IPv4 and IPv6 and its own server by
        ping. It was refused its own UI ports, wg0's and wg2's addresses,
        the tailnet Caddy, SSH and port 61008.
      - wg2 reached the internet and its own Dozzle (307), qBittorrent (200)
        and FileBrowser (200), and was refused wg0's and wg1's addresses.
      - wg1 ↔ wg2 and wg2 → a wg0 peer address were blocked.
    - Removing wg1 needed `onayla`. It stopped the unit, deleted its files,
      closed 61011, left 9 FORWARD rules and passed `--check`.
    - After a reboot, wg0, wg2, both `caddy-wg@` instances, the firewall and
      the panel came back with no failed unit.
    - wg2 and the test peer were removed through the panel. The operator's
      accounts, including the panel account, were restored.
  - **Browser check** of the page against sample networks: tabs with labels
    and counts, per-network header and chips, the network drawer with the
    next free `wg2`, port 61021 and addresses, and the new tab opening after
    creation.

### DD-137: The panel's "Bağlı" follows traffic, not the handshake (2026-09-15)

- **Context:** the user connected two peers, disconnected one, and both still
  showed "Bağlı". The status came from the last handshake (< 180 s), and a
  WireGuard handshake stays fresh for up to three minutes after a device
  goes away, whether or not it sends anything.
- **Decision:**
  - A peer is online when its received bytes grew within `ACTIVE_WINDOW`
    (45 s) **and** its last handshake is under 180 s. A connected device
    sends at least a keepalive (25 s by default) within that window.
  - A sampler thread reads every network every `SAMPLE_SECONDS` (10 s), so
    the counter history does not depend on an open page.
  - Until a peer has been watched for a whole window (after a panel restart
    or a new peer), the handshake decides as before.
  - The page shows "Bağlı" from `online`, otherwise "Boşta" within 24 hours
    of a handshake and "Görülmedi" after. The hint explains the window.
  - `PANEL_ACTIVE_WINDOW` and `PANEL_SAMPLE_SECONDS` exist only for tests.
- **Rejected:**
  - A shorter handshake limit: a quiet but connected device (keepalive off)
    would flap.
  - Probing the device: the server has no way to ping through a peer's
    firewall, and a probe would be traffic it never asked for.
- **Verified (2026-09-15):** bats 146 ok. Live on `nrm` with the Mac as a peer:
  "Bağlı" 2–5 s after connecting, "Boşta" 47–48 s after disconnecting.
- **Amended by the rebuild (phase 6):** the two environment variables are gone (no switch exists only for
  tests); `ACTIVE_WINDOW` (45 s) and `SAMPLE_SECONDS` (10 s) are plain constants in `master_wireguard.py`
  and `master-panel`. The Bats test sets them through the test harness `tests/panel-harness.py`
  (`--active-window`, `--sample-seconds`), which is never installed.

### DD-138: The server's IPv4 and IPv6 are detected and stored, never written by hand (2026-09-15)

- **Context:** the user asked whether the endpoint `203.0.113.10` had been
  typed by hand. Server addresses may change, so no file may hold a fixed IP;
  the installer should detect IPv4 and IPv6 on the server, store them, and
  every part should read them from there.
- **Finding:** the IPv4 endpoint was already detected on every run
  (`ip -4 route get 1.1.1.1` → `WAN_IPV4` → `WG_ENDPOINT_HOST` in
  `state.env`), and `master-wg` and the panel read it from there. The literal
  address appeared only in test fixtures and history. IPv6 was not detected.
- **Decision:**
  - `detect_wan` also reads the source of `ip -6 route get 2606:4700:4700::1111`
    and keeps it only if it is a global address on the WAN interface; otherwise
    `WAN_IPV6` is empty. Nothing is sent and no outside service is asked.
  - `state.env` gets `WAN_IPV6`, and the summary's WAN line shows it.
  - It is not an endpoint. The firewall opens WireGuard's UDP ports on the
    IPv4 WAN only (IPv6 WAN allows Tailscale and SSH, contract §9), so
    profiles and the panel keep the IPv4 `WG_ENDPOINT_HOST`. A first draft
    showed an IPv6 endpoint; the live check on `nrm` found the port closed on
    IPv6 and the label was dropped.
  - Opening WireGuard on the IPv6 WAN is left to the user: it changes the
    firewall contract (2 → 2 + networks IPv6 allows).
  - Test fixtures use the documentation address `203.0.113.7`; a test fails
    if a public IPv4 literal appears in the installer, `master-wg`, the panel
    or `defaults.env`.
- **Not doing:** rewriting profiles or `state.env` automatically when the
  address changes (DD-76 still applies). A re-run detects the new address;
  existing devices need a new profile, and stage 5 warns about stale ones.
- **Verified (2026-09-15):**
  - bats 147 ok.
  - Live on `nrm` (v2-103 over v2-102, scratch inputs, accounts restored):
    `state.env` holds `WAN_IPV4` and the detected `WAN_IPV6`, the summary
    shows both, profiles keep `Endpoint = <WAN_IPV4>:port`, `--check`
    passes, 0 failed units.

### DD-139: A file panel for the downloads folder, run as the downloads uid (2026-09-15)

- **Context:** after the WireGuard panel, the user asked for a second
  FileBrowser-like page. It should browse the server's folders, and delete,
  move and rename.
  - They approved the design artifact (list/icon view, trash, text viewer) and
    asked for text files to open in the page.
  - Their decisions: `/downloads` only, delete goes to a trash, the same account
    as the WireGuard panel, FileBrowser stays, no access over WireGuard.
- **Decision:**
  - **A separate service, not a tab of the WireGuard panel.** The WireGuard
    panel runs as root because `master-wg` needs it. A file manager inside it
    would move files with root rights. `master-files-panel` runs as
    `DOWNLOADS_UID`, the owner of every file qBittorrent, Unpackerr and
    FileBrowser write, with no capabilities and only `DOWNLOADS_PATH` writable.
    - systemd refused a numeric `User=1000` without a user entry (seen live:
      `217/USER`). The installer therefore uses the uid's existing name or
      creates `master-downloads` (system, no login, no home). Ownership on disk
      stays numeric.
  - **Same account without a second copy on disk.** `/etc/master-stack` is
    `0700 root`. `LoadCredential` gives the service its own copy of
    `wg-panel.auth` at start. When the installer rewrites the account, the file
    panel restarts.
    - The PBKDF2 check and the lockout are duplicated from the WireGuard panel
      (a few dozen lines) instead of refactoring the working panel. A bats test
      signs in to the file panel with an account written by
      `master-wg-panel account`, so the two cannot drift apart silently.
  - **Root confinement in the server, not the page.** Every request names a
    path relative to the root. The server walks it from a directory descriptor,
    one `O_NOFOLLOW` open per step, and acts with `*at` calls on single names.
    A symlink is shown but never followed, so a link to `/etc` or a swapped
    directory cannot lead outside.
  - **Nothing is overwritten.** Renames and moves use `renameat2` with
    `RENAME_NOREPLACE` through `ctypes`. Where the file system lacks it (and
    in the macOS tests), a check-then-rename under the panel lock is used.
    Moves check every target first and refuse the whole request on a clash.
  - **Trash on the same disk.** Delete renames the item into
    `DOWNLOADS_PATH/.cop/<id>/`, with `<id>.json` holding the origin and time,
    so deleting is instant and reversible.
    - Restore goes back to the origin, or to the root when it is gone, with a
      free numbered name.
    - Permanent delete is fd-based and never follows a link. It works only on
      trash entries, and emptying needs `onayla`.
  - **Unpackerr and WebDAV must not see the trash.** Live test: Unpackerr
    watches hidden folders too and extracted a zip inside `/downloads/.coptest`.
    `UN_FOLDER_0_EXCLUDE_PATHS_0` did not stop it.
    - An empty read-only tmpfs over `/downloads/.cop` in `unpackerr` and
      `webdav` did: a zip placed in the trash stayed packed while a visible one
      was extracted.
    - Infuse sees an empty `.cop`, like `.unpackerr`. Stage 7 checks the mount
      in both containers.
  - **Text view on the server.** The server reads the first 1 MiB and refuses a
    NUL in the first 8 KiB. It decodes with the guessed or chosen encoding:
    UTF-8, else Windows-1254 for Turkish subtitles, CP437 for `.nfo`. The page
    inserts the result as text nodes; a download is `application/octet-stream`
    as an attachment.
  - **CSRF for downloads.** API calls need `X-Files-Panel: 1`. A download is a
    link and cannot send a header; it only reads, and it is still refused when
    `Sec-Fetch-Site` says `cross-site` or `same-site`.
- **Rejected:**
  - Running as root with a path check: one missed case would expose the host. (Still true for this
    unit; the separate root view of DD-235 accepts that risk on purpose, tailnet only.)
  - A copy of the hash owned by uid 1000: a second secret file to keep in sync.
  - Dropping privileges inside Python, or `setpriv`: more code or a lost
    credential, for what `User=` already does.
  - A trash outside `/downloads`: not guaranteed to be on the same disk, so
    delete would become a copy.
  - Upload, copy, thumbnails and cross-disk moves in the first version:
    FileBrowser already has them.
- **Verified (2026-09-15):**
  - bats 152 ok.
    - Five new tests: login and gates; root confinement and no overwrite; the
      trash round trip; text, encodings, the 1 MiB cut and downloads; installer
      wiring.
    - Ten mutations were caught: no `O_NOFOLLOW`, an overwriting fallback, the
      trash reachable by path, empty without `onayla`, no cross-site check, no
      header check, wrong host accepted, binary shown as text, the service as
      root, and the WebDAV tmpfs missing.
  - **Live on `nrm`** (v2-104 over v2-103, scratch inputs):
    - The first run failed at stage 7 with `217/USER`. The account fix above,
      a `getent` exit status under `pipefail`, and a start limit left by the
      failed runs (`reset-failed`) followed.
    - The third run passed stage 7 ("kök /downloads, çöpte 0 öge"). The service
      runs as `master-downloads` (uid 1000); `systemd-analyze security` gives
      3.0 OK.
    - From the Mac over Tailscale and Caddy:
      - A symlink to `/etc` was listed, and neither listing nor reading through
        it worked.
      - A rename onto an existing file was refused on ext4 (`renameat2`).
      - Windows-1254 and CP437 files were decoded; the download worked.
      - Move and mkdir worked, and a move into itself was refused.
      - A folder with a zip and the `/etc` link went to the trash. Unpackerr
        left the zip packed and both containers saw an empty `.cop`.
      - Restore went to the origin. Purging the link left `/etc` intact, and
        emptying needed `onayla`.
    - After a reboot the panel and both tmpfs mounts came back, with 0 failed
      units. The operator's accounts were restored and the file panel
      restarted; the test account now gets 401 on both panels.

### DD-177: Retire Local access; WireGuard is internet-only (2026-09-28)

- **Changed in v2-158:** the stage-4 upgrade helper (`master_wg_upgrade.py`)
  and the Settings filter that dropped old `wgN`-scope overrides are removed; a
  fresh install never has those rows. Settings still rejects WG scopes, the API
  still refuses a `scope` field, and stage 7 still checks that registry column 3
  is `inet`.

- **Decision (v2-151):** supersedes DD-176 and DD-167's Local toggle. All
  existing/new WG networks and peers get internet egress only. Remove selectors
  from creation/settings, reject API scope, remove the CLI scope argument and
  reject/filter WG host overrides in Settings. DNS-only editing remains.
- **Enforcement:** WG INPUT drops precede established/ICMP and Tailscale accepts;
  FORWARD blocks private/CGNAT/link-local/multicast/reserved destinations before
  WAN allow, permits replies only from WAN and drops other WG traffic. NAT and
  required per-network transport UDP ports remain. Constants live in defaults.env.
- **Upgrade:** a stage-4 helper under install/module/settings locks normalizes
  only registry column 3 to fixed inet, removes WG overrides, disables exact old
  caddy-wg instances and removes their template/config/env files. It is fatal on
  failure and idempotent, not a general cleanup engine (narrow DD-96 exception).
  Keys, profiles, addresses, ports, DNS and other services remain unchanged.
- **Compatibility:** keep the nine-column registry layout to avoid unrelated
  data migration; no access setting is exposed. History remains historical.
  Existing profiles need no reimport unless they use a private DNS server,
  which is no longer reachable through this internet-only tunnel.
- **Verification:** HTTP/CLI refusal, upgrade/fresh/repeat/failure tests, UI
  creation/settings and read-only WG firewall category, plus real isolated
  Linux IPv4/IPv6 internet NAT/return and blocked host/private/tailnet traffic.

### DD-175: Remove obsolete firewall generation, not VPN requirements (2026-09-28)

- **Decision (v2-149):** remove the pre-module fallback that treated a missing
  module registry as WireGuard installed. Only an explicit `wireguard/calisiyor`
  record activates preserved network definitions. No configured networks means
  no project FORWARD/NAT chains or parent jumps, including after removal/rerun.
- Remove eight redundant terminal `RETURN` rules (four chains, two families)
  on a host with WG networks. User-chain fall-through has the same result;
  conditional settings returns, ordering, staging and recovery remain intact.
  Replace the obsolete one-element multiport generator with a single qB UI port
  match. The diagnostic reader accepts both spellings during upgrades.
- Check INPUT's full cardinality/guards/all ICMPv6 types and NAT cardinality,
  in addition to existing WAN/order/forward/settings checks. Stale extra rules
  must fail verification; applying the current source replaces them rather than
  importing old raw firewall dumps. A missing expected WG chain is still an error.
- **Not dead:** registered VPN endpoints (even stopped/zero-peer networks),
  loopback/established/control traffic, Tailscale's own chains and marks, exit-node
  forwarding, and the WAN Tailscale UDP fallback (DD-73). No counters-based deletion,
  package purge, network/profile deletion, peer-port opening or account change.
  Built-in Files/WebDAV/archive services remain; retired Docker/wg-easy/shared-root
  WebDAV generation is not reintroduced. Explicit user overrides stay authoritative.
- **Verification:** isolated Linux tests cover clean/repeated policy application,
  missing/empty/stopped module records with preserved networks, teardown/re-add,
  stale INPUT/FORWARD/NAT detection/removal and untouched third-party chains.
  Packet tests exercise IPv4/IPv6 allow/deny behavior. This is not a new OS image
  installation, reboot or real WireGuard-client throughput acceptance.
- **Amended by DD-272 (v2-255, the rebuild):** WireGuard is built in: the firewall builds the rules of the
  networks in its networks file, not from a module record, and none while the stopped marker exists; the
  qBittorrent UI rule is gone.

### DD-174: Remove synthetic closed WAN and tunnel-local port rows (2026-09-28)

- **Decision (v2-148):** extend DD-173 to Internet and WireGuard. WAN rows now
  describe only configured SSH/Tailscale ingress and registered IPv4 WG UDP
  endpoints; do not duplicate local/tailnet services, arbitrary listeners or
  PeerAPI into closed WAN entries. IPv6 WG endpoint placeholders are omitted
  because the existing WAN IPv6 policy does not permit those endpoints.
- Tunnel-local rows follow `master-firewall`: only IPv4 qBittorrent UI permits
  for networks whose Local access (`ui`) is configured. No closed placeholder
  for an `inet` network or IPv6 UI. Keep configured permissions independently
  of live sockets, stopped interfaces, peer count or recent traffic; the network
  selector and required VPN UDP endpoints remain intact even for an empty list.
- Explicit user allow/deny rules remain visible and editable through the existing
  draft merge, including a required base port the operator has turned off. Only
  synthetic defaults disappear. Loopback inventory, raw listeners and all technical
  rules are untouched. No service, saved rule, WG network or actual firewall policy
  is removed; unlisted ingress remains blocked by the existing default deny.
- **Amended (DD-177, DD-272):** the tunnel-local qBittorrent rows went with Local access (DD-177) and
  qBittorrent (DD-272).

### DD-173: Tailnet port catalogue is configuration-driven, not socket-driven (2026-09-28)

- **Decision (v2-147):** stop synthesizing Tailscale management rows from every
  host listener. Generate them only from the shared per-family core allowlist
  and registered WireGuard endpoints, even when no socket is currently present.
  Operator-defined allows/denies remain independently visible and editable.
- The reported ports were not stale allow/deny rules: 20902 was qBittorrent peer
  traffic, 61006 its local UI, 61008/61009 the panel backends, and 2019 Caddy's
  loopback admin endpoint used for reload. Keep these required service settings;
  remove their implicit tailnet catalogue entries at the backend source, with
  no hardcoded port blacklist or frontend-only concealment. IPv6 Caddy/WebDAV
  entries are likewise absent while their configured service is IPv4-only.
- Default deny still blocks unconfigured new tailnet ingress. Keep raw listener
  inventory, technical firewall rules and explicit user overrides unfiltered.
  Do not alter socket bindings, qBittorrent's interface choice, Tailscale-owned
  chains, credentials, WG networks, forwarding or NAT. This is catalogue cleanup,
  not removal of listening services or a new firewall policy.

### DD-172: Minimum tailnet host ingress without changing VPN requirements (2026-09-28)

- **Decision (v2-146):** retain operator overrides at the head of CHAIN_SETTINGS,
  then allow only host SSH, Caddy, DNS TCP/UDP, folder WebDAV, Self PeerAPI TCP
  endpoints and registered WireGuard UDP endpoints from the tailnet. Caddy and
  WebDAV permits are IPv4-only, matching their actual template binds. Return these
  to the existing downstream policy; drop other new tailnet ingress before the
  unconditional acceptance in `ts-input`. Never edit Tailscale-owned rules.
- Registered WireGuard ports are intentional requirements, regardless of peers,
  handshakes or counters. Preserve their WAN/tailnet permissions, tunnel-local
  UI rules, interface state, forwarding, NAT, profiles and keys. Leave outbound
  torrent connections and established/related replies untouched.
- Use existing defaults/state port keys, not socket discovery, to admit ordinary
  services. Only Tailscale's own Self-advertised PeerAPI URLs may add dynamic TCP
  ports, validated against Self addresses and split by address family. Never
  allow a dynamic range, another peer's endpoint or an arbitrary listening app.
  Missing/not-ready daemon status does not prevent base host protection. The
  existing restart hook/watchdog checks changed endpoints; no new timer/cache.
- The port table derives tailnet baseline permissions from the same helper.
  Kernel firewall permission, socket binding and Tailscale's userspace services
  remain separate concepts: host INPUT is not a replacement for tailnet ACLs.
- Loopback/established guards precede overrides; overrides precede core allow/drop.
  Presence, exact cardinality and ordered comment identities are checked together
  so inserting a blanket RETURN/ACCEPT cannot silently bypass the new default.
  ICMP control traffic remains allowed. No package removal or listener restart is
  needed to close unnecessary *new inbound* qBittorrent peer connections.
- **Amended by DD-275 (v2-258, the rebuild):** each application address row's Tailscale port (K5) is a configured tailnet entry, `konsol-base:tail-tcp-<port>`, read from the access rows.

### DD-169: Compact trash confirmation and inline share controls (2026-09-28)

- **Shares layout superseded by DD-192:** two connection cards replace the
  shared permission/duration columns. Partial updates, per-scope RW consent,
  exact expiry preservation and separate account management retain this rationale.

- **Decision (v2-142):** remove move-to-trash explanations/path/size and show
  only a short question, filename (ellipsized with full tooltip) or count,
  Cancel and Move. Bound dialog content so long names cannot push buttons out.
  Permanent purge warnings and typed confirmation for emptying Trash remain.
- Replace the stretched share cards with aligned responsive columns: folder/URL,
  username, access, duration, state and actions. Use native selects for access
  and 1/7/30-day or unlimited lifetime; save on change, still explicitly confirm
  granting write/delete access. Keep address and copy button adjacent.
- Manage now changes folder/account only; creation still offers RO/seven-day
  defaults. Reuse the existing save endpoint with partial existing-share bodies.
  Read omitted fields from the registry under its existing locks, not from a
  potentially stale browser row. Do not recalculate folder identity when only
  access/expiry changes. Existing RW grants need no new acknowledgement for an
  unrelated account/expiry edit; an explicitly supplied RW setting still does.
- Disable conflicting list actions during saves; ignore older list reads, retain
  confirmed values on failure and avoid polling redraws while a select has focus.
  The existing active WebDAV restart/rollback and stopped-service behavior remain.
  Durations start now, never silently extend during account/permission changes.
- **Amended by DD-267 (v2-250):** the trash dialog and the share columns described here went with the
  old interface. Dosyalar' Çöp kutusu asks for the typed word before a permanent delete or emptying, and
  Paylaşımlar (DD-192, DD-267) keeps the backend rules above: partial saves read omitted fields under
  the registry's locks, an explicit RW needs its acknowledgement, durations start now.

### DD-168: Eight-character minimum for service passwords (2026-09-28)

- **Decision (v2-141):** at the operator's request, lower the Konsol minimum
  from 12 to 8 characters for qBittorrent and folder WebDAV, in both browser
  forms and server validation. This was a panel policy, not a service limit.
  qBittorrent 5.1.0 accepts eight-character passwords; WebDAV's scrypt verifier
  has no twelve-character requirement.
- Keep the 256-character maximum, existing character restrictions, salted
  password hashing, blank-on-edit preservation and long random WebDAV password
  generator unchanged. Existing accounts are not rewritten or shortened.
- Eight characters allow weaker choices than twelve. This is a minimum, not
  a recommendation; longer unique passwords remain preferable.
- Regression tests reject seven characters before a write, accept eight,
  preserve blank edits, and check real HTTP authentication using isolated
  WebDAV fixtures and a disposable native qBittorrent profile.
- **Amended by DD-272 (v2-255, the rebuild):** qBittorrent is gone; the minimum holds for folder WebDAV.

### DD-167: Edit a WireGuard network without regenerating it (2026-09-28)

- **Need:** the network-card refresh action should also expose default DNS and
  local access. Previously the refresh icon meant destructive regeneration.
- **Decision:** replace that entry with “Arayüz ayarları”. Save edits the selected
  registry row's default DNS and `inet`/`ui` scope only. Keep key regeneration
  inside a separate danger section with the existing typed `onayla` confirmation;
  unsaved form choices are never silently applied by regeneration.
- **DNS:** a default for newly added peers, not a DNS server setting or a push
  to existing client devices. Existing profiles, keys, addresses, peer states,
  labels and ports are untouched. Existing peer DNS retains its own edit/QR flow.
- **Local access:** same narrow boundary as before: qBittorrent's UI via that
  network's IPv4-bound `caddy-wg@`, not Konsol/SSH/WebDAV/DNS or other networks.
  Explicit firewall overrides remain authoritative. Close the Caddy listener
  before restricting policy; open policy before starting it. Never restart
  WireGuard or wake a stopped network; stage its Caddy enablement for next start.
- **Concurrency/failures:** `master-wg --if wgN net-settings` holds the existing
  installer lock, checks the selected row's SHA256 revision under lock, and
  refuses pending settings transactions. Use bounded systemctl calls; ordinary
  failures/signals restore registry, Caddy env, firewall and prior listener state.
  Report incomplete rollback explicitly. This is a scoped command transaction,
  not a power-loss/SIGKILL recovery engine. Save is immediate: this setting does
  not change the Tailscale-only access path to Konsol.
- **Explicit attempts:** local-access changes reset the start-limit counters
  of the firewall and selected Caddy instance before applying, as module actions
  already do. Live repeated toggles exhausted the firewall's 12/300s budget and
  prevented rollback. Do not change the automatic restart-loop limits or reset
  other networks' counters; DNS-only changes still perform no service actions.
- **API/UI:** `POST /api/wg/nets/<iface>/ayarlar` accepts `{scope,dns,revision}`,
  retains Host/header/origin/module gates and validates IPs before delegation.
  Invalidate Settings' read cache after the attempt. Polling never overwrites
  the open form; failures preserve the draft and stale forms must be reopened.
- **Amended (DD-177, DD-272):** the local-access scope went with DD-177; the default DNS (and the name,
  DD-265) is saved through the typed `/api/konsol/wireguard` routes (DD-272).

### DD-164: Incoming-network firewall tabs, not service buckets (2026-09-27)

- **Decision (v2-134):** implement the approved Tailscale (default), Internet,
  optional WireGuard and protected loopback categories. A service can have
  different permissions on different incoming networks, so it must not be
  assigned to just one global service bucket. WireGuard supports per-interface
  selection; installed-without-networks gets an empty state, not a fictional wg0.
- Public VPN UDP endpoints stay under Internet. Tunnel-client INPUT permissions
  are under WireGuard; Technical rules remains an all-network read-only view
  with original specs, order, ownership and counters, including FORWARD/NAT.
- A socket binding is not an end-to-end reachability test. The backend annotates
  addresses using state/network metadata and IPv6 zones, without scanning ports
  or inferring ownership from private IP prefixes. Fix ss's bracketed link-local
  zone parsing; keep unreadable/unknown distinct from no listener. Preserve known
  service names when the same listener appears under another traffic category.
- No firewall policy/worker, API write contract, dependency, bind address or
  privilege change. Preserve drafts across tabs, keyboard navigation, protected
  loopback and the existing apply/confirmation/rollback flow. DNS-only immediate
  Apply (DD-163) remains unchanged. Refresh is explicit, not background polling.

### DD-163: Immediate DNS-only Apply, retaining transactional recovery (2026-09-27)

- **Decision (v2-133):** remove the one-minute connection confirmation for
  DNS-only edits as requested. One Apply action validates, projects and restarts
  dnsmasq, then durably commits. Return an explicit committed result and refresh
  the UI without a review dialog, countdown or confirmation POST.
- The worker, not a client bypass flag, classifies DNS-only requests. Mixed
  firewall/qBittorrent drafts retain the existing review and 60 s confirmation;
  domain migration retains its separate 300 s/new-Host confirmation.
- Protect `panel.<LOCAL_DOMAIN>` before any mutation and disable its UI switch.
  Previously its disable could be staged but could never be confirmed. This
  preserves that restriction without relying on a now-removed confirmation.
  *Amended in the rebuild's phase 6:* no managed name can be switched off any
  more (DD-156's note), so this guard went with the switches.
- Keep locks, revision checks, validators, snapshots and the independent guard
  for apply failures/process death. Share the existing durable commit marker
  with confirmed transactions: a post-commit crash must not undo saved DNS.
  Successful DNS changes no longer automatically revert after disconnection.

### DD-162: Explicit firewall tables without changing policy authority (2026-09-27)

- **Decision (v2-132):** the user requested a full table, including short
  explanations, retaining on/off controls. Replace per-row disclosures and
  mobile cards with semantic row/column headers and bounded table scrolling.
  Service descriptions, source CIDR, address scope, draft/saved policy and
  edit/remove actions are visible together. Keep family/scope filters.
- Preserve the distinction between intended permission, an observed listener
  and actual reachability. No port scan or Tailscale ACL claim is inferred from
  an enabled switch. Loopback is protected; existing connections are not cut.
- The all-rules view adds conservative explanations without replacing raw
  specifications/order/counters. Foreign chains remain read-only. This is not
  an iptables editor/parser; port changes use the existing validated controller.
- No API, firewall worker, transaction deadline or privilege boundary changes.
  Switching a row only edits the in-memory draft until reviewed and applied.

### DD-160: Model A, one admin workspace and independent resources (2026-09-27)

- **Decision (v2-130):** implement the user's approved Model A. Remove the
  Applications launcher, Overview, dock and imitation window controls. Files is
  the default route; the sidebar contains App Store, installed apps and Settings.
  This supersedes DD-159's shell presentation only, not its service boundaries.
- CPU/RAM/disk belong below the sidebar menu. Sample CPU on a separate backend
  thread so a slow WireGuard command cannot stall host measurements. The gated
  resource endpoint does not enumerate ports/networks or invoke subprocesses;
  the legacy system API remains available. The browser polls independently and
  displays unknown values after failure/staleness instead of stale healthy data.
- Settings has System, Firewall, Caddy, Dnsmasq and Log. qBittorrent's own page
  holds its service controls, Web UI link and account/path forms. One shared
  draft/transaction controller prevents duplicated state or rollback logic.
- Files has Files, Shares, Archive jobs and Trash tabs, optional item details,
  and folder shortcuts only. ZIP submission opens job history; results return
  to Files. Background work and the existing unprivileged sandbox are unchanged.
- Clean installation still provisions protected infrastructure/Files/WebDAV,
  never optional apps or old credentials. No new production dependencies,
  external assets, auth bypass, network ports or automatic restore are introduced.
- v130 is prepared locally. Deployment/reset and fresh Debian/Ubuntu acceptance
  are separate steps; details and verification are in `archive/model-a-clean-install.md`.
- **Amended by DD-267 (v2-250):** the page set described here (Files as the landing route, the sidebar,
  Settings' and Files' tabs, qBittorrent's own page, archive jobs) went with the old interface; Genel
  Bakış is the landing page and the sections are DD-258's. The separate CPU sampling thread and the
  gated resource endpoint stay.

### DD-159: Desktop shell with protected Files, sharing and bounded ZIP (2026-09-25)

- **Decision (v2-129):** implement the approved desktop prototype after explicit
  authorization to deploy/test on `nrm`. A lightweight single-workspace web shell,
  not KDE; existing Settings and backend authority boundaries are retained.
- Files and folder WebDAV are permanent panel capabilities. ZIP is part of Files,
  not a separately installed unpacker. Only WireGuard/qBittorrent remain in the
  public App Store catalogue; infrastructure cannot be removed from its UI/API.
- Retain the internal `dosya`/`paylasim` template paths and registry rows so
  domain renaming, status and firewall consumers remain compatible. The installer
  activates/checks both; unchanged reruns do not bounce healthy services or
  rewrite account/history data. Older stopped instances become enabled built-ins.
  This supersedes DD-148/150/158's optional Files/WebDAV lifecycle only.
- Use a stdlib ZIP worker inside the unprivileged file service, with one job at
  a time, global byte/entry/depth/deadline limits, early central-directory checks
  and descriptor-safe access. Atomic no-replace publication avoids half-extracted
  visible results; errors/cancellation discard private staging. This is bounded
  ZIP support, not an arbitrary-format archive daemon or a filesystem snapshot.
- `/srv/.arsiv` is private staging and bounded history, not a backup. Installer
  permission repair excludes it. Restart records interruption rather than claiming
  to resume work. Source ZIPs remain, including nested ZIPs; unsafe duplicates,
  links and cross-device paths fail closed.
- Exact limits, API and recovery caveats: `desktop-and-archives.md`.
- **Amended by DD-267 (v2-250):** Files keeps the server folders, the trash and Sistem dosyaları
  (Dosyalar); Konsol's ZIP/RAR jobs and `/srv/.arsiv` are gone, archives are Gezgin's, an App Store
  package (DD-262), and `desktop-and-archives.md` moved to `docs/archive/` as history. The catalogue
  is WireGuard, qBittorrent and Gezgin. Files and folder WebDAV stay built in with their internal
  `dosya`/`paylasim` IDs.
- **Amended by DD-272 (v2-255, the rebuild):** there is no catalogue; the installer installs Files and WebDAV
  directly, without manifests or `master-modul yerlesik`, and keeps the live file names (`paylasim.caddy`,
  `modul-paylasim.conf`).

### DD-158: Independent folder accounts and descriptor-safe WebDAV (2026-09-25)

- **Extended by DD-192:** the account/folder remains shared between its two
  connections; enabled state, permission and expiry are now per connection.

- **Decision (v2-128):** implement Files v09 and replace the single shared
  account with a bounded folder registry, separate users, RO/RW and stable IDs.
  The user authorized implementation and deployment to disposable `nrm`.
- **Implementation choice:** reuse the existing Python stdlib backend approach
  with a descriptor-based DAV handler, not the proposal's tentative per-share
  rclone processes. A single credential-loaded service avoids per-share ports,
  Caddy configuration and process lifecycle. Root management and unprivileged
  data access stay separate; hashes never go to the file-manager API/browser.
- **Trade-off:** filesystem isolation between shares is application-level,
  not one OS sandbox per account. The supported DAV subset deliberately lacks
  locks, PROPPATCH and directory COPY; native-client acceptance is still required.
  No claim of full WebDAV compliance. See `folder-shares.md` for exact limits.
- Per-request root birth-time/inode checks fail closed on a replaced folder;
  explicit path editing keeps the share ID. Parent/child grants are rejected.
  Expiry runs on access/transfer chunks. Registry mutation restarts the active
  server and cuts existing transfers; stopped modules stay stopped.
- Passwordless Konsol remains an administrator interface. Recipient access must
  be restricted to WebDAV by manually reviewed Tailscale policy; the installer
  does not edit policy. Legacy broad accounts/URLs are not kept as a bypass.
- Supersedes DD-141/149/152's common-account, writable-symlink-root and rclone
  details, not their Tailscale-only publication or module lifecycle boundaries.

### DD-157: Rename the local domain as a confirmed transaction (2026-09-25)

- **Request:** explain firewall addresses, remove the unnecessary health site,
  and let the operator rename `ayc` from the Caddy tab. The static v08 mockup
  remains frozen; this extends the production implementation only.
- **Health:** the standalone `ok` response duplicates stage 7's real Konsol
  page and backend checks. Remove its site, DNS record and dedicated probe;
  retain the stronger page/API/Host/header checks. An unmatched Host may receive
  an empty Caddy response; HTTP status alone is not evidence of a health route.
- **Scope:** a single validated local suffix, not an arbitrary Caddy editor or
  public-domain/HTTPS workflow. All installer-owned active and staged names move
  together. Custom DNS targets and disabled state survive (since the rebuild's
  phase 6 only the records' own switch: no managed name is switched off, DD-156);
  account/profile/data files and IP-based share links are not part of the write set.
- **Transaction:** use DD-156's worker, durable snapshots and independent guard,
  but prohibit combining a domain change with other settings. Give five minutes
  for a new-address connection. Only the HTTP Host supplied by the server, not
  one in the client's JSON body, proves the new panel name at confirmation.
  No retained aliases. The root backend reads state dynamically and is not
  restarted; Caddy reloads gracefully. Restart the file backend only if active,
  since its allowed Host is a startup argument. Warn about active file transfers.
- **Persistence:** `SETTINGS_FILE.domain` becomes authoritative only on commit,
  and overrides stale installer input on re-runs. The portable installer never
  copies or rewrites the operator's input file. Module renderings are included
  so reinstalling a module cannot reintroduce the old suffix.
- **Concurrency/recovery:** settings and tailnet refresh share `state.lock`;
  refresh skips a busy cycle. Rollback replaces only `LOCAL_DOMAIN`, preserving
  any newly detected Tailscale addresses. File snapshots and commit-marker crash
  recovery retain DD-156's behavior. A stopped file module is never started.
- **Manual boundary:** the user must first add the new restricted DNS suffix in
  Tailscale Admin and retain the old mapping until successful confirmation.
  The UI shows both URLs even if the old request disconnects. No Tailscale
  account/ACL writes are attempted. See [Tailscale DNS reference](https://tailscale.com/docs/reference/dns-in-tailscale)
  and [Caddy reload](https://caddyserver.com/docs/command-line#caddy-reload).

### DD-156: Transactional settings management in Konsol (2026-09-24)

- **Context:** the operator approved the four-tab v08 prototype and then
  requested implementation and a version bump. This supersedes DD-155's
  read-only restriction for firewall, DNS and the selected qBittorrent fields;
  Caddy and third-party firewall chains remain read-only.
- **One persistent owner:** `SETTINGS_FILE` holds confirmed firewall overrides
  and DNS choices. The installer, module DNS rendering and firewall refresh
  consume it, rather than resetting it. qBittorrent's own profile remains
  its account/path source; no duplicate account store or backup exporter.
- **Safety transaction:** a separate systemd worker consumes JSON on stdin,
  under install/module/settings locks. Before any mutation, root-only
  `SETTINGS_PENDING_FILE` records the previous affected files, service state,
  candidate policy, boot ID and monotonic deadline. A permanent systemd timer
  recovers abandoned work (180 s apply deadline, then 60 s to confirm).
  Failed rollback remains pending for retry. A commit marker makes recovery
  safe across a crash between writing the confirmed file and deleting pending.
- **Confirmation:** trusted proxy client information must identify a tailnet
  address. An existing TCP connection alone is not proof that the next one
  will work: effective denies of the confirming client's Caddy/DNS ports, or
  disabling the console's own DNS name, cannot be committed. This is not an
  external port scan or a test of Tailscale ACLs. The UI separates permissions
  and listeners, and warns before applying exposure changes.
- **Firewall:** a dedicated `CHAIN_SETTINGS`, before `ts-input`, holds only
  validated TCP/UDP port rules (family, scope, optional source CIDR, action).
  Loopback/established flows return to the baseline; ICMPv6 is not editable.
  No Tailscale/third-party chain is rewritten. All live table rules/counters
  are visible; only operator port overrides are editable. Ordering and exact
  membership are verified. The existing refresh mechanism consumes overrides.
- **DNS:** base/module interface-name entries retain their owner and get a
  reversible disabled marker; custom exact records and upstream IPs have a
  separate file. Only names inside `LOCAL_DOMAIN` may be added. Base/module
  name collisions, non-public upstreams and configured self-addresses are
  rejected. `no-resolv` and `local=/DOMAIN/` stay; forwarding never leaks
  disabled/missing private names or changes Tailscale Admin DNS. DNS is
  syntax-checked before restart. No public listener is added.
- **qBittorrent:** stop, snapshot the flushed profile, change only requested
  keys, restart if it was running. New passwords use qBittorrent's PBKDF2
  format; absent password means preserve. UI/API/logs never return a hash or
  new password. Snapshot files contain only existing profile data, mode 0600.
  Descriptor-relative no-follow file access protects the user-owned profile
  path. Download targets must exist, be canonical and non-hidden, and lie
  under downloads/media; a write probe runs as the service UID, with no
  recursive ownership changes. A dedicated unit drop-in grants that path.
  Existing torrent data and incomplete locations are never migrated.
- **Scope:** new HTTP APIs retain Host, `X-Konsol`, same-origin and no-store
  protections. Drafts are browser-memory-only. No new dependency, Docker,
  reconciliation engine, automatic deployment or server backup is introduced.
- **Verification:** isolated real-binary Debian 13 tests, including actual
  qBittorrent login with the new hash, DNS forwarding/private-zone separation,
  firewall order/tailscale preservation and rollback; real systemd timer/worker;
  Python/Bats tests and Playwright on the production page at desktop/mobile
  widths. Ubuntu was not freshly provisioned for this revision.
- **Amended by the rebuild (DD-272, DD-275):** the qBittorrent fields (moved to its package by DD-202) are
  gone with it; the transaction also carries Konsol's and Paylaşımlar' rows, the applications' access rows and
  WireGuard (DD-275).
- **Amended by the rebuild (phase 6):** the DNS part's disabled marker is gone. Every managed name has its
  own row (Konsol's `panel.`, WebDAV's `paylas.` behind Paylaşımlar' Tailscale switch, each application's
  address row, DD-275), so switching one off in Yerel adlar had nothing left to act on. Removed:
  `dns.disabled` with its validation and plan items, the `# konsol-off: ` marker, `filter-dns` and
  `dns-enabled` (and their callers in stages 6 and 7), the name switches in Konsol and the `kapali` and
  `kilitli` fields of `/api/konsol/adlar`. Yerel adlar lists the managed names read-only with their owner and
  a link to their row; the settings file's `dns` holds `records`, `forward` and `servers` only, and any other
  key is refused. Records (with their own switch), forwarding and the local domain are unchanged.

### DD-155: Konsol shows the server's settings, read-only (2026-09-19)

- **Partly superseded by DD-156:** the read-only restriction is lifted by
  transactional settings. Still current: `GET /api/konsol/ayarlar`, the
  classification of live firewall rules and the `TORRENT_KEYS` read.

- **Context:** the user wanted to see, in Konsol, the firewall rules, the
  Caddy addresses, qBittorrent's download path and dnsmasq's names. The
  design (`docs/archive/design/konsol-ayarlar-v07.html`, values read from `nrm`) was
  accepted with three choices the user confirmed: read-only, raw views kept
  in closed boxes, packet counters shown.
- **Decision:**
  - A new page, Ayarlar, fed by one `GET /api/konsol/ayarlar` on the root
    backend (it already runs as root and behind the Host and `X-Konsol`
    gates). It reads only when the page asks; a 5 s cache absorbs repeated
    loads and "Yenile" (`?yenile=1`) skips it.
  - **Read-only on purpose.** Every value already has one owner: the
    installer (`kurulum.env` and the defaults), a module, or qBittorrent
    itself (**DD-151**). Writing from Konsol would open a second source of
    truth that the next install reverts, and move towards the reconcile
    engine the project refuses. Each row says where its value is changed.
  - **Firewall from the live rules, not from the intent.** The backend runs
    `iptables`/`ip6tables -v -S` on the three project chains and classifies
    each rule by interface using the same `state.env` and network registry
    the ports card reads. A rule it does not recognise (added by hand, or
    drift) is listed under "Tanımsız kurallar" instead of being hidden.
    `master-firewall --check` gives the status. Counters show what each rule
    caught since boot (on `nrm`: over 1600 packets dropped on the WAN within
    hours).
  - **Caddy and dnsmasq from their files.** A small parser reads the
    installer's own templates as rendered (site lines, `@matcher path`,
    `handle`, `reverse_proxy`, `file_server`, `respond`), not Caddy's full
    grammar. Module files are attributed to their module; `Caddyfile.wg`
    is expanded per `ui` WireGuard network. `CADDY_WG_FILE` joins
    `state.env` for this.
  - **qBittorrent: paths only.** Only the path and port keys of
    `qBittorrent.conf` are read (`TORRENT_KEYS`); the password hash never is.
    The page warns when the save or temporary path leaves `DOWNLOADS_PATH`:
    the unit's sandbox (**DD-151**) refuses writes there, so downloads would
    fail and never show in Dosyalar.
- **Found on `nrm`:** the WireGuard registry writes an IPv6 subnet as
  `…::0:0/112` while `ip6tables` prints `…::/112`; subnets are compared as
  networks (`ipaddress`), not as text.
- **Amended by DD-267 (v2-250):** `GET /api/konsol/ayarlar` and its Ayarlar page are gone with the old
  interface. The same settings view (the live firewall classification, the Caddy and dnsmasq parser)
  feeds Erişim's reads (`erisim`, `guvenlik-duvari`) and Gelişmiş (`gelismis`, DD-259, DD-265, DD-266).
- **Amended by DD-269 (v2-253):** the old Settings page's rule groups are gone; the view keeps the
  `master-firewall --check` result, and Erişim's technical rows come from `iptables-save`.
- **Amended by DD-272 (v2-255, the rebuild):** the `TORRENT_KEYS` read left with qBittorrent (DD-202, DD-272);
  the Caddy and dnsmasq parser and the firewall check behind Erişim and Gelişmiş hold.

### DD-154: One console name, one current export (2026-09-19)

- **Context:** simplifying after **DD-152**/**DD-153**. The Caddyfile still
  redirected `wg.`, `dosya.` and `file.${LOCAL_DOMAIN}` to Konsol (the old
  WireGuard panel, file panel and FileBrowser names, **DD-140**, **DD-146**),
  each with a dnsmasq name and a stage 7 check. `Data/app/` held every
  exported installer since v2-96.
- **Decision (the user agreed to both, 2026-09-19):**
  - The three old names are gone: no Caddy site, no dnsmasq record, no check.
    `SERVICE_NAMES` is `health panel`. Bookmarks must use `panel.<domain>`.
    The backends already accepted only `panel.<domain>` as Host.
  - The exporter keeps only the current version in `Data/app/`, as it already
    did in the repository root; older exports live in Git history.
- **Amended by DD-269 (v2-253):** `SERVICE_NAMES` is `panel` only since the health name went (v2-127,
  DD-157), and there is no `Data/app/` or exporter since DD-228; the one-console-name rule stands.

### DD-153: The base installs only what the base uses (2026-09-19)

- **Context:** after **DD-152** the user asked to clean the services' old
  dependencies before simplifying further. A fresh v2-122 install on `nrm`
  pulled 51 packages. Checked one by one against the code: every
  `defaults.env` and `state.env` key has a reader, every shell function is
  called and no unit names a removed service — but three base packages
  served nothing the base does.
- **Decision:**
  - `gnupg` goes. It was there for one `gpg --dearmor` of Caddy's repository
    key and brought about 15 packages (dirmngr, gpg-agent, gpgsm, pinentry…).
    The armored key is now stored as `caddy-stable-archive-keyring.asc` and
    named in `signed-by=`; apt reads armored keys itself (apt 1.4+, measured
    with apt 3.0.3 on `nrm`: `InRelease` verified). Tailscale's key is already
    a binary `.gpg` download.
  - `gawk` goes. It came with the v1 installer; no script uses a gawk-only
    feature (no regex intervals, `gensub`, `strftime`, `asort`, `IGNORECASE`,
    `PROCINFO`), and the code already avoided intervals for mawk. `awk` is the
    distribution's `mawk` (1.3.4 on Debian 13).
  - `apache2-utils` leaves the base: only Paylaşım's account uses `htpasswd`,
    so `master-modul` installs it (`share_tools`) before every step that
    writes or checks the account (`kur`, `baslat`, `parola`, `uygula`).
    `hesap` only reads the plain account file and never needs it.
- **Kept on purpose:** `jq` (Tailscale login state), `dnsutils` (`dig` in the
  name checks), `python3` (Konsol and `master-modul`), `ethtool` (UDP GRO),
  `unattended-upgrades` (**DD-113**) and the essential tools listed for
  clarity (`coreutils`, `util-linux`, `diffutils`).
- **Upgrading:** a host installed earlier keeps the packages; nothing removes
  them (fresh-install rule).
- **Amended (DD-158, DD-272):** `apache2-utils` is not installed at all (WebDAV has no htpasswd since DD-158)
  and `master-modul` is gone (DD-272); `python3` serves Konsol.

### DD-152: No Docker — Paylaşım runs rclone on the host, Arşiv açıcı is dropped (2026-09-19)

- **Context:** after **DD-151** only two modules used Docker: Paylaşım (rclone)
  and Arşiv açıcı (unpackerr). For them the installer kept a whole layer:
  Docker's apt repository and packages, `daemon.json`, a `docker.service`
  drop-in, the `MASTER-DOCKER` chain behind a `DOCKER-USER` jump, and the
  engine itself (dockerd, containerd, shims and port proxies: about 110–150 MB
  of memory measured on `nrm`). On 2026-09-19 the user decided to remove the
  Docker dependency completely, to drop Arşiv açıcı, and to run the share
  WebDAV on the host.
- **Decision:**
  - The installer installs no Docker: no repository, packages, daemon
    settings or drop-in. The firewall has no `MASTER-DOCKER` chain and never
    touches `DOCKER-USER`; `CHAIN_DOCKER` is gone from the defaults and the
    state file; `master-firewall.service` is `PartOf=tailscaled.service` only.
    The nft backend gate (**DD-106**) stays: the firewall still orders its
    chain behind tailscaled's `ts-input`.
  - Arşiv açıcı (unpackerr) leaves the catalogue, the templates, Konsol and
    the downloads tree (`.unpackerr`). Nothing replaces it.
  - Paylaşım becomes `master-paylasim.service` with the container's exact
    command: `rclone serve webdav SERVER_ROOT/SHARE_DIR/w --copy-links
    --read-only --dir-cache-time=10s` with the htpasswd account, on
    `127.0.0.1:SHARE_PORT`. Caddy, the names, the account (**DD-149**) and the
    share links (**DD-141**) are unchanged, so Infuse sees no difference.
- **Which rclone (the user chose among three):**
  - Chosen: rclone's official release binary. `RCLONE_VERSION` (1.75.1) and one
    SHA256 per architecture are pinned in `defaults.env`, taken from rclone's
    signed `SHA256SUMS` (key `FBF7 37EC E9F8 AB18 604B D2AC 9393 5E02 FF3B 54FA`,
    good signature checked on `nrm`); downloads.rclone.org and the GitHub
    release list the same values. This is the program the container ran.
  - Rejected: the distribution package. Debian 13, Ubuntu 24.04 and 26.04 ship
    1.60.1 (2022); Debian's security tracker lists about 25 open CVEs for it in
    trixie, one of them (CVE-2026-88015, a Range-header panic) in HTTP/WebDAV
    serving itself.
  - Rejected: nginx with the WebDAV module — a second web server next to Caddy,
    a new configuration never tried with Infuse, and on Ubuntu the module
    lives in universe.
- **Getting rclone:** `master-modul` downloads only when the installed binary's
  `rclone version` is not the pinned one: HTTPS only, the checksum before the
  archive is opened (Python's `zipfile`, no `unzip` package), the binary
  written next to `RCLONE_BIN` (`/usr/local/lib/master-stack/rclone`) and
  moved over it. `kaldir` keeps it, as qBittorrent's package stays
  (**DD-151**). The unit's description carries the version, so a new pin
  changes the rendered unit and the next installer run re-applies an
  installed share: download, then restart.
- **Sandbox:** the service runs as `DOWNLOADS_UID` (it reads what qBittorrent
  and Konsol write, never as root), with `ProtectSystem=strict` and nothing
  writable, `ProtectHome`, private `/tmp` and devices, no new privileges, an
  empty capability set, `IPAddressDeny=any` with `IPAddressAllow=localhost`
  (it cannot connect out), the kernel protections and
  `MemoryDenyWriteExecute`. The account file stays root-only on disk and
  reaches the service as a systemd credential (`LoadCredential=`); systemd
  copies it at start, so "Yeni parola" restarts the service.
- **The trash is an empty tmpfs, not an inaccessible path:** measured on
  `nrm`, a single share link pointing into an `InaccessiblePaths=` directory
  makes rclone's whole listing fail (`EACCES`, HTTP 500, every share gone),
  while a dangling link (`ENOENT`) is only skipped.
  `TemporaryFileSystem=SERVER_ROOT/.cop:ro` turns a link into the trash into a
  dangling one. The container, which mounted all of `/srv`, could see the
  trash; the service cannot.
- **Checks (`kur`, `baslat`, `uygula`, `parola`):** the unit is active, runs as
  `DOWNLOADS_UID` with the expected command line, has the trash tmpfs, its
  own sockets are only `127.0.0.1:SHARE_PORT`, an unauthenticated request gets
  `401` and the account `207`; then the name and the Infuse address as
  before. A failed install is taken back (names, marker, unit).
- **Upgrading:** per the fresh-install rule there is no clean-up code: a host
  from an earlier version keeps Docker, its containers and images until it
  is reset. Reset and install fresh; Paylaşım generates a new account.
- **Amended (recorded 2026-10-05):** rclone and its trash tmpfs are gone. Since
  v2-126..v2-129 (commit 18b7ba7, DD-158) the Python WebDAV unit lists the trash,
  and `.pay` when present, in `InaccessiblePaths=` (mode 000 inside the unit, checked
  on nrm 2026-10-05). The tmpfs reasoning above applied to rclone's link following.
- **Found in the live trial (v2-122):** right after `systemctl restart` a
  `Type=simple` unit is "active" while its process is still root (systemd
  switches to `User=` just before exec), so an immediate owner check failed
  once ("Yeni parola"). The unit is `Type=exec` now, and `master-modul` reads
  the owner of every module's main process until it matches (about 5 s at
  most). rclone exits with 143 on SIGTERM; `SuccessExitStatus=143` keeps a
  stopped share from showing as failed.

### DD-149: Paylaşım is a module with a generated account (2026-09-18)

- **Partly superseded by DD-158 (and DD-152, DD-159, DD-171):** the generated
  shared account, htpasswd, rclone and `.pay/acik` marker are gone and WebDAV
  is built in. Still current: the module-name lifecycle (Caddy imports from
  `CADDY_MODULES_DIR`, dnsmasq drop-ins, validate-then-swap, Caddy reloaded
  and dnsmasq restarted, `master-modul uygula` re-applies changed files).

- **Context:** stage 2 of **DD-148**. The share WebDAV (rclone, `paylas.<domain>`,
  `<ts-ip>:61010` for Infuse) was wired into every installer stage and took
  its account from `SHARE_USER`/`SHARE_PASS` in `kurulum.env`. The approved
  design (`docs/archive/design/konsol-moduller-v06.html`) makes it a Konsol module
  that generates a strong account and offers "Yeni parola".
- **Decision:**
  - The base Compose file keeps Dozzle and qBittorrent. `modules/paylasim/`
    holds the rclone service (unchanged hardening), a Caddy site and a dnsmasq
    name; the installer renders them and never installs the module.
  - The account is generated on the server: user `SHARE_ACCOUNT` (`paylasim`),
    `SHARE_PASSWORD_LENGTH` (20) characters from an alphabet without
    `0 O 1 l I` (it is typed on a TV remote), from Python's `secrets`. The
    plain `paylasim.cred` is the source of truth and the bcrypt
    `paylasim.htpasswd` is derived from it; both are `0600 root`. The password
    goes through stdin only (`htpasswd -i`, curl `-K -`): never an argv, the
    progress file, the journal, `state.env` or Caddy's environment (Caddy
    runs with `--environ`, which logs its environment).
  - bcrypt keeps htpasswd's default cost: the password is random with about
    117 bits, and rclone checks Basic auth on every Infuse request.
  - **DD-119** ("the input file is the truth") no longer covers the share:
    there is no input. A valid existing account is reused on `kur`, so a
    reinstall keeps Infuse working; `kaldir --veri` or "Yeni parola" changes it.
- **Why the root backend shows the account:** the file backend used
  `LoadCredential=` with an absolute path. systemd refuses to start a unit
  whose credential file is missing, so without the module (or after
  `kaldir --veri`) the whole file API would be down, and the copy it held
  would go stale after "Yeni parola". The root backend reads the file through
  `master-modul hesap` inside its read-only sandbox; the password is returned
  only on `?parola=1`, audited without the value, and hidden again in the
  page after 30 s. The file backend never sees the account.
- **Why a marker file:** `/etc/master-stack` is `0700`, so the file backend
  (uid 1000) cannot read the module registry. `master-modul` writes
  `SERVER_ROOT/.pay/acik` on `kur` and removes it on `kaldir`; without it the
  backend refuses new shares (`409`) and Konsol hides the share controls. It
  is created with `mktemp` and renamed, because `.pay` belongs to uid 1000.
- **Names come and go with the module:** the base Caddyfile imports
  `CADDY_MODULES_DIR/*.caddy` (after the global options; an empty glob is
  valid), and the name is a drop-in in `/etc/dnsmasq.d`. Temporary files
  start with a dot, which Caddy's glob and dnsmasq's directory scan skip. Each
  change is validated first (Caddy with the real address; the whole dnsmasq
  configuration, not only the base file) and taken back if it fails. Caddy
  is reloaded, never restarted: it also serves Konsol, whose page is polling
  the progress, and a failed reload keeps the old configuration. dnsmasq is
  restarted, because SIGHUP does not re-read `interface-name`.
  - The port is written into the site literally. An unset `{$SHARE_PORT}`
    would silently fold the site onto port 80. The address stays
    `{$TAILSCALE_IPV4}`, which `refresh-tailnet-config` keeps current.
  - The names follow the *installed* state: they stay while the module is
    stopped (the name answers 502) and go on `kaldir`, before the container.
    The container is started and checked before the names are published.
- **Checks move with the module:** stage 7's share checks (health, single
  network, read-only runtime, loopback-only publish, `401`, the name and the
  Infuse address) run in `master-modul`, plus a `207` with the account. A
  failed `kur` takes back the names, the marker and the container. Stage 7
  keeps the share-root owner and the qBittorrent-cannot-see-`.pay` checks.
- **Re-runs:** `master-modul uygula` re-applies an installed module whose
  rendered files changed (a new domain, a new image) and starts it only if it
  is registered as running; it writes no progress line.
- **Removal:** `kaldir` keeps the account, the registry and the links, so a
  reinstall restores the same links and login. `--veri` deletes the account
  files, `.pay/kayit.json` and the symbolic links in `.pay/w` with
  `find -maxdepth 1 -type l -delete`; link targets and anything else in that
  folder stay. **DD-148**'s "files under `SERVER_ROOT` are never module data"
  now reads "user files are never module data".
- **Network name:** the module uses its project's default network
  (`paylasim_default`), so it never collides with the `paylasim` network the
  old base project left on an upgraded host. Per the fresh-install rule there
  is no migration code; the leftover network is harmless.
- **Not doing:** a periodic sweep of expired shares (they are still swept
  when Konsol lists them) and account changes other than a new password.
- **Amended by DD-272 (v2-255, the rebuild):** `master-modul` and the module lifecycle are gone; the installer
  and the settings and share writers keep the import folder (`CADDY_MODULES_DIR`), the `modul-*.conf` names,
  validation before the swap, Caddy's reload and dnsmasq's restart.

### DD-147: Konsol without a password; Tailscale joins by link only (2026-09-16)

- **Superseded in part by DD-194 (2026-10-01):** Konsol has a user name/password sign-in
  again, enforced by Caddy's forward_auth. Joining Tailscale by the login link is unchanged.

- **Context:** the user is turning Konsol into the place where modules are
  installed with one click and service accounts live (Hesaplar design v03). A
  Konsol account in `kurulum.env` was one more secret on the Mac, and Konsol is
  reachable only from the tailnet anyway. The Tailscale auth key was the other
  secret in that file, used only to skip one browser click.
- **Decision (user):** Konsol has no password — "erişim sadece tailscale olacağı
  için katman yeterince güvenli". Tailscale always joins through the login link
  shown during the install; the auth key input is removed.
- **What keeps it safe:** Caddy serves `panel.<domain>` on the Tailscale address
  only, so who can open Konsol is decided by tailnet membership and ACLs. Two
  gates remain and become load-bearing: the backends refuse any `Host` but
  `panel.<domain>` (a DNS-rebinding page cannot reach them), and `/api/*`
  requires the `X-Konsol` header with a same-origin fetch (a page on another
  site cannot send it, so it cannot drive Konsol through the operator's
  browser). Stage 7 proves both on both backends.
- **Accepted trade-off:** every member of the tailnet — and any device shared
  into it that ACLs allow to reach the server — gets full Konsol rights. For a
  single-owner tailnet that is the operator; for more, restrict with ACLs.
- **Removed with it:** PBKDF2 account file, HTTP Basic, lockout, the account CLI,
  `LoadCredential` for the file backend, the auth-key file and fallback path.

### DD-145: The console uploads into the list; no separate upload area (2026-09-16)

- **Context:** the file panel could do everything FileBrowser could except
  upload, select many items and search — the three reasons the container was
  still installed. The user asked for the upload to live *inside* the file list
  ("yükleme alanını ayrıca alta almak yerine dosyalar alanının içerisine
  sürükle bırak"), not as a panel at the bottom.
- **Decision:** the list is the drop target. While files are dragged over it the
  list draws a dashed frame and a target strip; on drop each file becomes a row
  at the top of that list with its progress bar inside the row, and turns into
  an ordinary row when it finishes. The only permanent chrome is a small summary
  in the toolbar. Selection turns the same toolbar into an action bar rather
  than adding a second bar. The dashed frame is drawn only during `dragover`.
- **Mechanics:** `POST /api/upload?path=&name=` takes the file as the body
  (`XMLHttpRequest`, so the row can show progress). The panel writes
  `.yukleniyor-<rastgele>` in the target folder, `fsync`s, then
  `renameat2(RENAME_NOREPLACE)`s it into place: a half file is never listed and
  an existing name is never overwritten. The stream runs without the panel
  lock — a multi-gigabyte upload must not freeze listing, rename or trash — and
  only the rename takes it. Uploads run one at a time, in order.
- **Why not multipart:** the body-is-the-file form needs no parser in the panel
  (stdlib only, **DD-139**) and streams straight to disk.
- **Cost:** the frontend grew a selection model and an upload queue; the backend
  gained one endpoint. In return FileBrowser, its account, its port and its name
  can be retired next.
- **Amended by DD-267 (v2-250):** Dosyalar' Sunucu klasörleri takes a drop or the file picker into an
  upload queue beside the browser (one file at a time whatever the folder, progress and cancel, a name
  the folder already holds skipped before anything is sent). `POST /api/upload` and its no-overwrite
  rename are unchanged.

### DD-144: The user area is a fixed /srv, not an asked-for path (2026-09-16)

- **Context:** `DOWNLOADS_PATH` was an input key with an allowlist
  (`/downloads`, `/data`, `/srv/downloads`). The user wanted one fixed area
  "completely outside the system" and asked whether `/srv` is what that is.
- **Decision:** it is. FHS 3.0 defines `/srv` as "site-specific data which is
  served by this system" and Debian Policy reserves it for the local
  administrator — no package writes there. `SERVER_ROOT=/srv` is a constant in
  `defaults.env`, the question is gone from `kurulum.env`, and `config.env` no
  longer stores a path the operator could have chosen.
- **Layout:** `downloads/` (torrents, with `incomplete/` and `.unpackerr/`),
  `media/{movies,series}`, `.cop` (trash) and `.pay/w` (share root) are
  siblings under the root.
- **Consequence that removed code:** the torrent client and unpackerr mount
  only `/srv/downloads`, so the trash and the share root are outside their
  mount. The `ro,size=16k` tmpfs curtain that used to hide those folders from
  unpackerr is deleted, and stage 7 asserts the containers cannot see them.
- **Cost:** a rebuild starts with an empty `/srv`; data under an old
  `/downloads` is moved by hand (fresh-install rule). The operator must delete
  the `DOWNLOADS_PATH` line from `kurulum/kurulum.env`.
- **Amended by DD-269 (v2-253):** the `/data` allowance is gone; the user area is `/srv` only.

### DD-143: The installer prepares WireGuard; Konsol creates it (2026-09-16)

- **Context:** the user asked to cut the Mac-side link — no reading of
  `kurulum/wireguard`, no peer preservation, no upload — so that every install
  leaves a clean WireGuard, with interfaces and devices created from the panel.
  They approved the shape below, including "a re-run must not wipe the networks
  the panel created".
- **Decision:**
  - **No privileged `wg0`.** Every network lives in `/etc/wireguard/networks`
    and is created by `master-wg net-add`, which already ordered the steps
    correctly (files and registry → firewall → `wg-quick@wgN` → `caddy-wg@wgN`,
    with a full teardown when a step fails). Allocation now starts at `wg0`;
    profiles live in `clients-wg<N>` for every network.
    - `state.env`'s `WG_SERVER_IPV4`, `WG_SUBNET*` and `WG_PUBLIC_PORT` are now
      *defaults* (address base, suggested first port), not "the wg0 network".
      `WG_INTERFACE` is gone.
  - **The installer prepares, never creates.** `ensure_wireguard_ready`
    installs `wireguard-tools`/`qrencode`, loads the module and creates
    `/etc/wireguard`; `ensure_wg_networks_running` enables and starts what the
    registry holds. No key is generated, no `.conf` written, no interface
    started by the installer — so a re-run cannot overwrite or resurrect
    anything, and a fresh server simply has no WireGuard.
  - **The firewall is registry-only and valid with zero networks.** Empty
    arrays are guarded for bash 3.2 (the tests run there), and the NAT chain is
    created empty rather than skipped.
  - **The panel's empty state is the entry point.** With no networks the
    WireGuard page shows one card — what will happen, then **Yapılandır** —
    which routes to the same "Arayüz ekle" page. One creation path, no second
    bootstrap code.
  - **`wireguard.command` stays an SSH client.** It picks the network (asks
    only when there is more than one), and lost "Yedek al", the auto-backup and
    the embedded server-side tar script.
- **Why:** the old flow had two ways to get a network (installer for `wg0`,
  panel for the rest), kept server keys on the Mac, and made a rebuild silently
  restore old peers. Measured before the change (live on `nrm`): deleting
  `wg0.conf` left `master-wg list` failing with a raw shell error and the panel
  logging "sayaç okunamadı" every 10 s, while the panel still showed a phantom
  `wg0` card that could not be switched on — the fragility came from `wg0`
  being special, not from the panel.
- **Cost:** rebuilding a server means creating the network and re-adding the
  devices from Konsol. Accepted by the user; nothing on the Mac holds a server
  key any more.
- **Follow-up (v2-111):** the settings files kept describing `wg0` after the
  installer stopped creating it — `WG_CONF_FILE=/etc/wireguard/wg0.conf`, the
  first network's server addresses and subnets, and a `WG_PUBLIC_PORT` in
  `config.env` that an older run could still impose. They are a base only now
  (`WG_CONF_DIR`, `WG_ADDR_BASE4`, `WG_ADDR_BASE6`, `WG_PORT_DEFAULT`), so the
  host carries no preset network anywhere: not on disk, not in `state.env`, not
  in `config.env`. A bats test holds the line.

### DD-140: One console (Konsol) instead of two panels, and switchable peers (2026-09-16)

- **Context:** after the file panel the user asked for the WireGuard and file
  pages to become one server-administration tool. The design was iterated as a
  mockup until they approved it (frozen in `docs/archive/design/konsol-v01.html`).
  Their decisions: the address is `panel.<domain>` with `wg.` and `dosya.`
  redirecting, the browser's own login prompt is enough, no services page or
  status collector anywhere, and a network turned off in the console comes back
  with an installer re-run.
- **Decision:**
  - **One page, two backends.** The privileges that made two services necessary
    (DD-139) do not change: `master-wg-panel` stays root because `master-wg`
    needs it, and `master-files-panel` stays the downloads uid. Caddy sends
    `/api/wg/*` to the first and everything else — the pages included — to the
    second, so the console is one origin with one login.
    - The WireGuard backend no longer serves files: its `--web` argument and
      the old page files are gone, and every route moved under `/api/wg/`.
    - Both backends answer only to the host `panel.<domain>`, use the header
      `X-Konsol` for CSRF and the realm `Konsol`, so the browser reuses the
      same credentials for both.
  - **Switching a peer off keeps everything.** `master-wg peer AD kapat`
    prefixes the peer's block in `wgN.conf` with `#kapali#`. `wg-quick` and
    `wg-quick strip` ignore comments, so the peer leaves the running interface
    at once and stays off after a reboot, while its key, preshared key, address
    and client profile stay untouched. `master-wg info` reports the state as an
    eleventh field, `cmd_add` skips a disabled peer's address when it hands out
    the next one, and `peer_count` counts it.
    - `write_and_apply` no longer starts an interface that is switched off: it
      writes the file and returns when the unit is disabled.
  - **Switching a network off is the unit.** `master-wg [--if wgN] net kapat`
    disables `wg-quick@wgN` (and `caddy-wg@wgN`); the registry, keys and
    profiles stay. The firewall keeps the UDP port open — nothing listens on
    it — instead of a second, drifting source of truth for "which port is
    open". *Amended in the rebuild's phase 6:* the unit's enablement stays the
    one source of "open", and the firewall now reads it: a closed network keeps
    its registry line but no port, forwarding or NAT, and `net ac|kapat` apply
    the firewall again (opening enables the unit before the firewall).
  - **The overview reads the server, not the containers.** The root backend
    samples `/proc/stat` and `/proc/meminfo` every 10 s and keeps the last two
    minutes, reads `/proc/uptime` and `/etc/os-release`, and builds the ports
    card from `state.env` plus the network registry — no scanning, no container
    status collector (the user rejected one). "Son işlemler" parses the two
    services' own audit lines out of the journal, cached for 15 s.
    - The disk bar needs a size the root backend cannot cheaply get, so the
      file backend walks the downloads tree at most every 5 minutes (the same
      budget as a listing) and reports `null` when the budget is exceeded; the
      console then shows a single "Kullanılan" segment.
- **Why:** two pages meant two logins, two looks and no place for anything that
  belongs to the server rather than to one of them (load, disk, ports, log).
  One console also makes the switches possible: they are the first controls
  that touch both a unit and a configuration file.
- **Verified (2026-09-16):** bats 152 ok. The page was exercised against a mock
  backend (all four pages, the move, peer-add and confirm dialogs, no console
  errors) before the live run.

### DD-96: The installer owns its own files and nothing else (2026-08-09)

- **Cleanup (v2-96, 2026-09-14):** with the only host freshly rebuilt on v2-95,
  the last transition aids went:
  - the stage 0 Transmission container gate and `TRANSMISSION_*` removed-key
    hints (with `read_input_file`'s removed-keys argument);
  - the stage 7 Portainer warning;
  - the v2-73 sysctl file-name migration (`remove_legacy_sysctl_files`,
    `SYSCTL_LEGACY_FILES`);
  - the "no OS record (v2-73)" log branch.

  Stale wg-easy wording in comments was corrected, and the two dated reviews
  moved to `docs/archive/`.

- **Decision:** All migration cleanup is removed (v2-62). The installer no
  longer deletes `master-webdav.service`, its user, group and downloads ACL,
  no longer runs `apt-get purge rclone` / `apt-get autoremove`, no longer
  removes the `filebrowser` container or the legacy `*_filebrowser_data`
  volumes, and no longer deletes `filebrowser.yaml`, the `watch-tailnet-addr`
  unit, the retired `docker.service.wants` symlink, or `$COMPOSE_DIR/.env`.
  The upgrade path is a fresh install, or a re-run that overwrites the files
  the installer itself renders.
- **Why:** three reasons converged.
  1. **Boundary.** A global `apt-get purge`, an `apt-get autoremove` and a
     `userdel` are host-wide actions taken on the installer's own guess about
     what an older revision left behind. The v2-58 review flagged exactly
     this as cleanup exceeding the stack boundary, and narrowing the scope
     (v2-59, v2-60) treated the symptom, not the cause.
  2. **Idempotency.** `remove_stale_filebrowser` ran unconditionally, so a
     re-run recreated the container every time. Measured on `nrm`: all 16
     managed files byte-identical, Caddy/dnsmasq/Docker untouched, but the
     FileBrowser container id changed and the service blinked for ~2 s. That
     is a re-run changing state for no reason (**R20**).
  3. **Cost.** 83 lines and five bats assertions existed only to migrate
     hosts provisioned by revisions we no longer run.
- **Consequence (accepted):** a host installed by an old revision keeps its
  leftovers. It is not repaired by a re-run; it is reinstalled. Single-host,
  interactive, destructive-by-design — reinstalling is the cheap path.
- **Guard:** a bats test fails the suite if `apt-get purge`, `userdel`,
  `setfacl`, `docker rm`, `docker volume rm` or `disable --now` reappear in
  `install.sh`, so the pattern cannot creep back one convenience at a time.
  - `docker rm` and `docker volume rm` count only as commands the installer
    runs. A leftover gate may name them in a `die` or `log` message for the
    operator to run by hand (DD-116, DD-117).
  - Until v2-91 the negated assertions never failed under macOS bash 3.2
    (DD-126), so the guard was silent.
- **Not doing:** an uninstall command. Removing what v2 installed is a
  separate, explicit operation, not a side effect of installing.

### DD-95: Counting WAN allows, and adopting referenced staging (2026-08-09)

- **Decision (two fixes, v2-61):**
  1. **The WAN allow count must match the list.** DD-94's `check_chain_shape`
     treated only a bare `-j ACCEPT` / `-j RETURN` body as a bypass. An
     interface-qualified pass — `-i eth0 -j ACCEPT` in `MASTER-INPUT`, or
     `-i eth0 -j RETURN` in `MASTER-DOCKER` — was instead recorded as a
     legitimate WAN allow, so it satisfied the ordering rule and passed. So
     did an extra port (`--dport 3306`). Pattern checks find a *missing*
     rule; they structurally cannot find an *extra* one. `check_wan_allow_count`
     now asserts that the number of `-i WAN … -j ACCEPT|RETURN` rules equals
     the length of the allow list (5/2 for INPUT v4/v6, 3/0 for DOCKER),
     and the same list feeds the per-rule `check_rule` calls, so the ports
     are still written once.
  2. **Staging cleanup runs at the end of apply and removes the jump.**
     `activate_named` jumps the staging chain from its parent before the
     rename, so an interruption in that window leaves it *referenced*.
     DD-94's purge skipped referenced chains to avoid deleting a live policy;
     the result was a chain nothing would ever adopt, a permanently failing
     `check_no_staging_artifacts`, a permanently failed unit and a watchdog
     restarting it every 5 minutes with the same outcome. Moving the purge to
     the end of a successful apply removes the dilemma: the final chain is
     already bound to the parent, so any remaining staging artifact is dead
     by definition and its parent jump can go with it.
- **Why:** a second review of v2-60 (2026-08-09). Both are drift the stack
  never produces itself; they matter because `--check` is what the watchdog
  trusts, and a check that cannot see a hole is worse than no check.
- **Boot window (no change, measured):** ~850 ms passes between the WAN
  address becoming usable and the policy landing (eth0 DAD 21:33:42.742 →
  apply finished ~21:33:43.6 on `nrm`). The only WAN listener in that window
  is sshd, which the policy allows anyway; Docker and every published
  container port start ~2 s later, behind the policy. Closing it would mean
  either persisting rules to disk (a second source of policy, against DD-66)
  or ordering the unit before `network-online.target`, which DD-94's live
  WAN detection needs. Accepted and documented instead.
