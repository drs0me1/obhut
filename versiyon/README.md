# Exported installer revisions — `quantum` branch

One directory per exported revision. **Every directory contains four files,
without exception** (standing rule, 2026-08-01):

| File | Why |
|---|---|
| `install-<TAG>.sh` | the frozen export, byte-identical to its tag |
| `deploy.sh` | asks for a host, copies, verifies the SHA256, can start the install |
| `deploy.command` | the same thing, double-clickable from Finder |
| `README.md` | **operator-facing**: version identity, then a plain-language description of what gets installed, what to do first, and what to watch out for |

The README is deliberately non-technical — these folders get carried to
other machines on their own, and whoever opens one is installing, not
developing. Internals belong in [`../docs/`](../docs/), not here.

| Directory | Version | Tags | Web file manager | Status |
|---|---|---|---|---|
| [`Q1-13/`](Q1-13/) | `2026.08.02-Q1-13` | `Q1-13` | `ghcr.io/gtsteffaniak/filebrowser:stable` | **Current on this branch** |
| [`V1-20/`](V1-20/) | `2026.07.31-V1-20` | `V1-20`, `R2.0` | `filebrowser/filebrowser:v2` | Branch point, expires 2026-09-01 |

```sh
cd versiyon/Q1-13
./deploy.sh nrm --run
```

From Finder, double-click `deploy.command` instead.

> **This is not `master`.** `master` answered the filebrowser question with
> dufs (`V2-2` / `R2.1`, DD-26). This branch forked from `V1-20` and swaps
> only the web file manager for FileBrowser Quantum — see **DD-27**. The two
> lines are alternatives, not a sequence.

`R2.2` is a **release point rather than a revision** and points at the same
installer `Q1-11` shipped, which is why it never had a directory of its own:
a second copy of an identical installer is exactly what the retirement rule
below exists to prevent. `R*` tags mark repository state you might want to
return to; `V*`/`Q*` tags identify a revision of the installer itself. There
is no `R` tag on `Q1-13` yet — none was asked for.

Every export is byte-identical to the tag it is named after:

```sh
git show Q1-13:install.sh | sha256sum
sha256sum Q1-13/install-Q1-13.sh
```

## Retired directories

Only the current revision and the branch point are kept as directories; the
export a new one replaces is removed rather than accumulated, so there is
never a question of which folder to hand someone. `Q1-1` was retired when
`Q1-4` was exported, `Q1-4` when `Q1-8` was, `Q1-8` when `Q1-11` was, and
`Q1-11` when `Q1-13` was.
Nothing is lost — the tag still holds the exact file:

```sh
git show Q1-8:install.sh > install-Q1-8.sh
```

The `Q1` tag is a line marker rather than a revision: it follows the head of
this line: `Q1-4` → `Q1-8` on 2026-08-01, `Q1-8` → `Q1-11` on 2026-08-02.
Moving it means deleting and recreating it, so it is only done when asked —
**as of `Q1-13` it still points at `Q1-11`**, one revision behind the head.
`Q1-4`, `Q1-8`, `Q1-11`, `Q1-13` and every other revision tag stay where
they are — those are fixed identities.

## Why the deploy scripts are duplicated

`deploy.sh` and `deploy.command` are **byte-identical copies** in every
version directory, not a shared script plus wrappers. Each directory has to
work when lifted out on its own, and a wrapper pointing at a parent breaks
the moment you copy one elsewhere.

That trades self-containment for a drift risk this repository has lost to
four times — the repair cooldown, `STACK_SCHEMA`, the architecture stage
table and the "fixed image" strings. The mitigation is that the copies are
*identical* rather than merely similar, so drift is one command away:

```sh
diff versiyon/V1-20/deploy.sh versiyon/Q1-13/deploy.sh
diff versiyon/V1-20/deploy.command versiyon/Q1-13/deploy.command
```

Any change to one copy must be applied to the others in the same commit.

## Adding a new export

```sh
mkdir versiyon/<TAG>
git show <TAG>:install.sh > versiyon/<TAG>/install-<TAG>.sh
chmod +x versiyon/<TAG>/install-<TAG>.sh
cp versiyon/Q1-13/deploy.sh versiyon/<TAG>/deploy.sh
cp versiyon/Q1-13/deploy.command versiyon/<TAG>/deploy.command
```

Then write the `README.md` — it is not optional, see the table at the top.

Keep **exactly one** `install-*.sh` per directory — `deploy.sh` refuses to
run otherwise, on purpose: a second file makes it silently ambiguous which
revision gets installed.
