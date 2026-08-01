# `V2-2` — current

The revision the repository is on. Deploy this one unless you have a
specific reason to roll back.

| | |
|---|---|
| Tag | `V2-2` / `R2.1` (commit `05de0ff`) |
| Version | `2026.08.01-V2-2` |
| SHA256 | `b3b161395c9974b04df27da37156c625305d06afa9f17773322838c6eecd785c` |
| Lines | 5459 |
| `STACK_SCHEMA` | 11 |
| Web file manager | `sigoden/dufs:v0.46.0` |

## Deploying

```sh
./deploy.sh nrm          # copy + verify the SHA256 on the host
./deploy.sh nrm --run    # copy + verify + start the install over SSH
```

The host argument defaults to `nrm`. `deploy.sh` computes the hash from
the file next to it rather than carrying a hardcoded copy — a stored hash
would be a second source of truth to keep in sync, and this repository has
lost that bet four times (the repair cooldown, `STACK_SCHEMA`, the
architecture stage table, the "fixed image" strings).

From the provider console instead, after copying the file by hand:

```sh
bash /root/master.sh
```

**Open the Tailscale login link the moment it appears, then leave the
session alone.** Restarting the installer generates a new nodekey and
invalidates the pending auth path — the failure reads `410 auth path not
found`. A slow login is waited out, not retried.

## What changed from `V1-20`

filebrowser was replaced by dufs. Its upstream archives on **2026-09-01**,
after which it gets no releases and no security fixes, and three of its
advisories are already permanently unpatched (one critical). The `v2` tag
was never deprecated — that was the reported symptom, and the registry
disproved it. Full reasoning in `docs/design-decisions.md` → **DD-26**.

Three consequences worth knowing before you install:

- **`STACK_SCHEMA` moved 10 → 11**, because the recorded digest key set
  changed (`IMAGE_DIGEST_FILEBROWSER` → `IMAGE_DIGEST_DUFS`). A `V1-20`
  reconcile rejects a schema-11 host outright.
- **One credential now covers both file services.** The Stage 0
  user/password protects the host WebDAV service *and* dufs, hashed twice
  (bcrypt into `webdav.htpasswd`, sha-512 crypt into `dufs.auth`). On a
  host upgrading from `V1-20` the prompt fires once more, because
  `dufs.auth` doesn't exist yet and a half-written credential pair would
  leave dufs unauthenticated.
- **dufs serves the media tree at its root**, where filebrowser showed a
  `/srv/media` nesting level.

## Rolling back

`../V1-20/` holds the last filebrowser build. Read its README first — the
schema difference above makes it a clean-install-only option, not an
in-place downgrade.
