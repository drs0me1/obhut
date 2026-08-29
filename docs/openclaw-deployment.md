# OpenClaw deployment plan (companion service, outside the v2 contract)

**Status:** plan, approved direction 2026-08-29 — not yet executed.
**Scope boundary:** OpenClaw is NOT part of the v2 bundle. The contract's
fixed six-service set is untouched; the installer neither installs nor
manages it (**DD-96**: the installer owns its own files and nothing
else). A v2 re-run must leave OpenClaw completely alone — that is a
verification item below, not an assumption.

Facts below were checked against docs.openclaw.ai on 2026-08-29
(Node requirement, npm install command, systemd onboarding, port 18789,
loopback/tailnet exposure guidance).

## What lands on the host

| Piece | Choice | Why |
|---|---|---|
| Runtime | Node 26 via NodeSource apt repo (min supported: 22.22.3+) | OpenClaw's recommended runtime; apt keeps it patched with the rest of the system |
| Install | `npm install -g openclaw@latest --allow-scripts=openclaw` | Upstream's documented path; Docker is possible but not recommended by upstream for headless servers |
| Service | `openclaw onboard --install-daemon` as the **`openclaw` user** (user-level systemd unit + `loginctl enable-linger openclaw`) | Upstream default; survives reboots without a root-owned unit |
| UI/gateway | Loopback only, default port **18789** | Matches the stack's R11 posture: nothing new listens beyond loopback |
| Remote access | SSH `LocalForward 18789 127.0.0.1:18789` on the operator's existing `nrm` host block | The operator already tunnels the five UI ports this way; zero server-side surface added |
| First channel | Telegram (bot token) | Smallest-friction bridge; others (WhatsApp/Signal/…) can be added later via `openclaw.json` |
| Model API | Operator-supplied key, stored under `/home/openclaw` with `0600` | Key never enters this repo, `config.env`, `state.env` or any unit file |

## Steps

1. **User + runtime (root):**
   - `adduser --disabled-password --gecos "" openclaw` — no sudo, no
     `docker` group (docker-group membership is root-equivalent; see
     "integration rules" below).
   - NodeSource repo + `apt-get install nodejs` (Node 26.x).
   - `loginctl enable-linger openclaw`.
2. **Install + onboard (as `openclaw`):**
   - `npm install -g openclaw@latest --allow-scripts=openclaw` under the
     user prefix (`npm config set prefix ~/.npm-global`, PATH in
     `~/.profile`) so root's filesystem stays untouched.
   - `openclaw onboard --install-daemon` — interactive: model API key,
     Telegram bot token, admin allowlist (the operator's own Telegram
     account ONLY).
3. **Exposure check (root):** `ss -tlnp | grep 18789` must show
   `127.0.0.1:18789` and nothing else. No firewall change is needed or
   wanted — MASTER-INPUT already drops WAN and this binds loopback.
4. **Operator side (Mac):** add `LocalForward 18789 127.0.0.1:18789` to
   the existing `Host nrm` block; UI at `http://127.0.0.1:18789/`.
5. **Verification checklist:**
   - `systemctl --user -M openclaw@ status openclaw*` active; survives a
     host reboot.
   - Telegram round-trip (message in → reply out).
   - `ss -tlnp`: 18789 on loopback only.
   - `master-firewall --check` still green; `systemctl --failed` empty.
   - **A v2 re-run leaves OpenClaw running and untouched** (DD-96 in
     practice).

## Integration rules (chat-driven control of this stack)

- qBittorrent control goes through its WebUI API on
  `127.0.0.1:${QBIT_UI_PORT}` with qBittorrent credentials — never by
  mounting or talking to `docker.sock`.
- Read-only status for chat ("is the stack healthy?") may shell out to
  `systemctl is-active`/`docker ps` equivalents only if the `openclaw`
  user is granted a *narrow* sudoers entry per command; start with none
  and add on demand.
- Prompt-injection posture: the agent must not have write access to
  anything the stack owns (`/etc/master-stack`, `/root/docker`,
  `/etc/caddy`, …). Its user account owning nothing outside
  `/home/openclaw` and `/downloads` (via group, if ever needed) is the
  enforcement, not politeness.

## Options considered and deferred

- **`openclaw.ayc` via Caddy/dnsmasq:** would put the name in
  `SERVICE_NAMES` and the site in the Caddy template — a real contract
  change (fixed bundle, N4 name-list test) requiring its own version
  bump and DD entry. Deferred until the SSH-tunnel path proves limiting.
- **Binding the gateway to the Tailscale IP:** upstream blesses tailnet
  exposure and MASTER-INPUT already accepts `tailscale0`, but the TS
  address can change and nothing outside the v2 bundle tracks
  `state.env`. Loopback + tunnel has no moving parts. Revisit only if
  phone-side access without SSH becomes a requirement.
- **Docker deployment:** upstream documents but does not recommend it
  for headless hosts; a container would also invite exactly the
  docker.sock coupling the integration rules forbid.
