# Plan: Podman, live (step 1 of the Portainer-like direction)

Status: step 1 built on 2026-10-29 (DD-294, v2-282, 2.2.0). Where it differs from the text below, DD-294 is right:
the socket is enabled and checked in stages 1 and 7 (not stage 4); the reads stay on the `podman` command (they
already saw every container; only the event stream uses the API); the routes kept their `konteynerler/*` names
(`ayrinti`, `gunluk`, `eylem` beside `liste`, which stays); whole-project actions wait for the stacks of step 2; the
container page has no raw inspect tab (Podman's create command carries environment values); a unit's container is
removed by stopping the unit and then deleting its Quadlet file, or disabling a unit file; a unit label counts only
when systemd agrees; and the guard for every published port (step 3's closing half) came into this step, as
section 8a recommended. Opening such a port to the internet on purpose stays in step 3. Step 2 uses Docker's
`docker compose` client against Podman's Docker-compatible socket; DD-152 ("no Docker") is about the engine, and
that reading needs the operator's word before step 2 starts.

## 1. Why this step comes first

Today Konsol knows Podman only through Obhut's own records (DD-271 to DD-275) and reads the rest by running
the `podman` command for each request (`master_containers.py`, `master_container_manager.py`). There is no
Podman API socket (DD-208: "no daemon, socket or auto-update timer"). Three things follow:

- A container started outside Konsol (`podman run`, a script, another tool) is shown read-only and can never
  be managed (DD-290).
- A change inside Podman (a container stopped, an image pulled, a container crashing) reaches the page only
  on the next poll, and nothing tells the page that something happened.
- Step 2 (stacks through Compose) needs Podman's Docker-compatible API anyway.

The goal of step 1: Konsol reads Podman's whole live state through its API, follows Podman's event stream
while a Konsol tab is open, shows every container with its details and log, and can start, stop, restart and
remove any container under clear rules. Nothing that works today is removed in this step.

## 2. Scope

In:

1. `podman.socket` enabled by the installer (socket activation: `podman system service` runs only while a
   client is connected and exits when idle).
2. A small libpod API client in the root backend (stdlib only, HTTP over the Unix socket).
3. Every read of the Podman section from the API: containers, pods, images, volumes, networks, `system df`,
   stats, inspect, logs.
4. Podman's events followed by the live-events producer (DD-259) only while a stream is open, so the page
   updates within about a second.
5. A container page: summary, ports, mounts, networks, labels, live resources, the log with follow, and the
   inspect output with environment values removed.
6. Container actions for every container, routed by who owns it (section 4).
7. Grouping by Compose project label and by Obhut application in the container list (prepares step 2).

Out (later steps): deploying stacks, the published-port guard for any container, the Caddy and dnsmasq
editor, removing the Compose-to-Quadlet compiler. Section 9 lists them.

## 3. System side

- **Installer, stage 4 (tools and units):** `systemctl enable --now podman.socket`. Debian 13 ships Podman
  5.4, Ubuntu 24.04 ships 4.9; both carry the units. The socket is `/run/podman/podman.sock`, root only.
  `podman.service` keeps its own idle timeout, so no process stays up while nobody is connected.
  `podman-auto-update.timer` stays off (DD-214: images update only on the operator's confirmation).
- **`config/defaults.env`:** `PODMAN_SOCKET="/run/podman/podman.sock"` and `PODMAN_API="/v4.0.0/libpod"`
  (the lowest version both systems answer; checked on the test host before anything else, section 8).
- **Backend unit:** `master-panel.service` already allows `AF_UNIX` and runs as root; `ProtectSystem=full`
  leaves `/run` writable. No change expected; the live check confirms it.
- **Repair (`master-onar`):** one more step, "Podman API soketi": enabled and listening, re-enabled if not.
- **Not exposed anywhere:** the socket is root-equivalent. Caddy never proxies it; only the root backend
  talks to it. The Files backend (downloads uid) cannot reach it.

## 4. Who may act on which container

The operator's decision (2026-10-29): Obhut has full authority over Podman. It manages and removes every
container on the server, also one installed outside Konsol. The table says only how each action is carried
out so that it sticks.

| Container | How Konsol recognises it | Start, stop, restart | Remove |
|-----------|--------------------------|----------------------|--------|
| An Obhut application's | Obhut's labels and a record | Through the application, as today (its systemd unit; acting on the container directly would fight systemd) | By removing the application (its page links there), so its record, access rows and data go with it |
| Another systemd unit's (Quadlet or `podman generate systemd`) | `PODMAN_SYSTEMD_UNIT` label, no Obhut record | Through that unit (`systemctl start/stop/restart`), so systemd does not undo it | The unit is stopped and disabled, then the container is removed. A Quadlet file in `/etc/containers/systemd` would bring it back at the next boot: the dialog names the file and removes it too when ticked, ticked by default |
| A plain Podman container | Neither | Through the API | Through the API; its anonymous volumes with it when ticked |
| A Compose project's | `com.docker.compose.project` or `io.podman.compose.project` label | Through the API, one container or the whole project | One container or the whole project; the project's named volumes only when ticked |

Every removal asks for the typed word and names what goes. This replaces DD-290's "Obhut never starts, stops
or removes such a container". Every action is a job like the cleanup (K8): a durable record, the log in
İşlemler, the audit line, one at a time per container.

## 5. Backend

- **New `panel/master_podman_api.py`** (pure where it can be): `Client(socket, prefix)` with `get_json(path,
  query)`, `stream(path, query)` (chunked lines for events), `logs(id, tail, since)` (decodes the 8-byte frame
  header of a non-TTY log, plain text for a TTY one), `post(path)` for actions; timeouts and a size limit on
  every reply; errors as `PodmanApiError(status, message)` in Turkish for the page.
- **Reads moved to the API:** `Containers.runtime/ps/liste` and `Service.reach/cleanup` read
  `/info`, `/containers/json?all=true`, `/pods/json`, `/images/json`, `/volumes/json`, `/networks/json`,
  `/system/df`, `/containers/stats?stream=false`. The rows keep their shape, so Erişim, Uygulamalar and the
  cleanup keep working; the new fields are added beside them (pod, Compose project, health, owner kind).
  The `podman` command stays only where a job runs (install, update, cleanup), unchanged in this step.
- **Inspect, filtered:** a whitelist (image and digest, command, created, restart policy, health, mounts,
  ports, networks, labels, state with exit code and error). `Config.Env` and anything named like a secret are
  never returned, as today.
- **Events:** a thread started and stopped with the live-events producer (`master_olaylar.py`): it holds
  `/events?stream=true` with a filter on container, pod, image, volume and network events, and marks the new
  `podman` topic due on each event (debounced to one read per second). When the stream drops it reconnects
  with a backoff; while it is down the topic falls back to a 10 s read. No tab open: no stream, and the
  socket's service exits.
- **Routes (route table, `master_api.py`):**
  - `GET /api/konsol/podman` the section's whole view (runtime, counts, containers with pods and projects,
    images, volumes, networks, storage, what nothing uses);
  - `GET /api/konsol/podman/konteyner?ad=` one container's filtered inspect, owner and actions it allows;
  - `GET /api/konsol/podman/konteyner/gunluk?ad=&satir=&sonra=` the log's last lines or the lines after a
    cursor (the page follows with this every 2 s while the Günlük tab is open);
  - `POST /api/konsol/podman/konteyner/islem` `{ad, eylem, onay, birim_dosyasi, birimler}` starts the job
    (`baslat`, `durdur`, `yeniden-baslat`, `kaldir`; `kaldir` needs the typed word, the two ticks say whether a
    Quadlet file and the volumes go with it);
  - the `konteynerler/liste` route goes, its readers move to `podman` (no leftovers, rebuild ground rule 2).
  `docs/konsol-api.json` and `sema.ts` are generated again.

## 6. Konsol

- **Podman section** keeps its address `#/podman`. Tabs: Konteynerler, Podlar, İmajlar, Birimler, Ağlar.
  The containers' list groups rows under their Obhut application or Compose project (collapsible), plain ones
  below; each row shows state with health, image, CPU and memory, uptime and ports, and a menu with the actions
  section 4 allows. The summaries stay. Changes arrive through the live stream; the 10 s refresh goes.
- **Container page** `#/podman/konteyner/<ad>`, with the shell's trail back to Podman: Özet (state, image,
  created, restart policy, health, owner and where it is managed), Portlar, Bağlamalar (a `/srv` path opens in
  Dosyalar, any other in Sistem dosyaları), Ağlar, Etiketler, Günlük (follow, pause, filter, the line count),
  Kaynak (CPU and memory, live), İnceleme (the filtered inspect as JSON, copyable).
- **Actions:** the job opens in İşlemler; the row's state changes when Podman's event arrives, not when the
  job ends.
- **Uygulamalar** is unchanged in this step; an application's containers link to their container pages.

## 7. Tests

- **Python:** a fake libpod server on a temporary Unix socket (`socketserver.UnixStreamServer`): the client's
  JSON, chunked and framed replies, timeouts and size limits; the inspect filter (no environment, no secret
  names); events debounced, reconnecting and stopping with the producer; the owner rules and the jobs; the
  route table's shapes.
- **bats:** the installer enables `podman.socket` once and idempotently; the repair step.
- **Playwright:** the Podman section's groups, tabs and menus by owner; the container page's tabs, the log's
  follow and pause; an event changing a row without a reload; the typed word before removal; 1440, 390, 320,
  light and dark, with the layout audit.
- **Live on `nrm`:** the socket answers on Debian 13 with `PODMAN_API`; a container started with `podman run`
  from SSH appears within about a second; stopping, starting and removing it from Konsol; its log; an Obhut
  application's container acted on through its unit; a container of a Quadlet unit removed with its file and not
  back after a reboot; the socket's service exits when no tab is open; a reboot.

## 8. Order of work

1. Done 2026-10-29 on `nrm` (Debian 13, build v2-281), see section 8a.
2. The client and its tests; the installer, `defaults.env` and the repair step.
3. Reads moved to the API behind the existing shapes; the full local check round passes unchanged.
4. Events and the `podman` topic.
5. The new routes, the owner rules and the jobs.
6. Konsol: the section, the container page, the log.
7. Bookkeeping: `V2_VERSION` and `OBHUT_SURUM` 2.2.0 (behaviour the operator sees), CHANGELOG, a `DD-*`
   entry amending DD-208 and DD-290, contract and architecture; `nrm-dene` and the live checks.

## 8a. Findings on the test host (2026-10-29)

- Podman 5.4.2. `podman.socket` ships and was disabled; started by hand it answered `/v4.0.0/libpod/info` and
  `/v5.0.0/libpod/info` (200), the Docker-compatible `/version` (API 1.41) and the events route. `PODMAN_API`
  can stay `/v4.0.0/libpod`, which Ubuntu 24.04's 4.9 also answers. `podman.service` is
  `podman system service` with Podman's default idle timeout.
- **A published port of a container Obhut did not install is open to the internet today.** A
  `podman run -p 18080:80` on Podman's default network answered an HTTP request sent from the internet to
  the server's WAN address (checked from a client that does not exit through the server). The container
  guard's forward chain filters only Konsol's `ksl*` bridges, `FORWARD` accepts by default, and Netavark's
  DNAT never passes the host's input rules. So step 3 is not a later nicety: with Obhut managing every
  container, and stacks next, it should come right after this step or inside it (the operator decides).
- The test container, its image and the started socket were removed again; the host is as it was.

## 9. Later steps (not planned here)

- **Step 2, stacks:** a stack is a folder with `compose.yaml` and `.env`, edited in Konsol and deployed with
  Docker's `docker compose` against Podman's Docker-compatible socket; `podman-restart.service` brings
  `restart:` containers back after a reboot. The inspector warns instead of refusing.
- **Step 3, published ports (urgent, section 8a):** the container guard covers every container network: a
  published port is reachable from Tailscale, and from the internet only after the operator opens it in Erişim.
- **Step 4, Caddy and dnsmasq:** their files edited in Konsol, checked with `caddy validate` and
  `dnsmasq --test` before the reload, rolled back on failure; templates for a site in front of a container.
- **Step 5, the compiler:** the Compose-to-Quadlet path removed or kept as an option, decided after step 2.
- Each step that changes the application record is a new generation (clean install, DD-271 K1).
