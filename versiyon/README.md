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
| [`R2.5/`](R2.5/) | `2026.08.02-Q1-20` | `R2.5`, `Q1-20` | `ghcr.io/gtsteffaniak/filebrowser:stable` | **Current on this branch** |
| [`V1-20/`](V1-20/) | `2026.07.31-V1-20` | `V1-20`, `R2.0` | `filebrowser/filebrowser:v2` | Branch point, expires 2026-09-01 |

```sh
cd versiyon/R2.5
./deploy.sh nrm --run
```

From Finder, double-click `deploy.command` instead.

The working tree is currently `Q1-21`, which adds early recovery for a
measured persistent Tailscale browser-login 410. It is deliberately absent
from this table and from a new release directory until that exact automatic
branch completes a fresh live authorization. `R2.5` remains the only current
export; this avoids creating an unverified `R2.6` that would violate the
tag/export identity rule below.

> **This is not `master`.** `master` answered the filebrowser question with
> dufs (`V2-2` / `R2.1`, DD-26). This branch forked from `V1-20` and swaps
> only the web file manager for FileBrowser Quantum — see **DD-27**. The two
> lines are alternatives, not a sequence.

`R*` tags mark repository state you might want to return to; `V*`/`Q*` tags
identify a revision of the installer itself. Four release tags exist on this
branch:

| Tag | Same installer as | What it records |
|---|---|---|
| `R2.2` | `Q1-11` | tests, tooling and documentation tightened after the revision shipped |
| `R2.3` | `Q1-13` | the revision closed out: live-verified before tagging, exported, documentation resynced |
| `R2.4` | `Q1-15` | the Tailscale login can no longer hang forever (DD-37); verified by a from-scratch install |
| `R2.5` | `Q1-20` | the post-R2.4 reconcile/integrity review closed out; live upgrade, rerun and fault injection verified |

**The directory is named after the release, not the revision** (operator
decision, 2026-08-02). `R2.3/` therefore replaced `Q1-13/` rather than
joining it, `R2.4/` replaced `R2.3/`, and `R2.5/` replaced `R2.4/`. This is the one thing
not to get wrong: two directories holding a byte-identical installer is
exactly the ambiguity the retirement rule below exists to prevent, so a
release directory *supersedes* the one before it — it never sits beside it.
`R2.2` predates this
and never had a directory at all.

A release directory carries the revision's version string, because that is
what the script prints: `versiyon/R2.5/install-R2.5.sh` reports
`2026.08.02-Q1-20`. Its `README.md` says so up front, so nobody reads it as
a mismatch.

Every export is byte-identical to the tag it is named after:

```sh
git show R2.5:install.sh | sha256sum
sha256sum R2.5/install-R2.5.sh
```

## Retired directories

Only the current revision and the branch point are kept as directories; the
export a new one replaces is removed rather than accumulated, so there is
never a question of which folder to hand someone. `Q1-1` was retired when
`Q1-4` was exported, `Q1-4` when `Q1-8` was, `Q1-8` when `Q1-11` was,
`Q1-11` when `Q1-13` was, `Q1-13` when `R2.3` was cut from it, and `R2.3`
when `R2.4` superseded it, then `R2.4` when `R2.5` superseded it.
Nothing is lost — the tag still holds the exact file:

```sh
git show Q1-8:install.sh > install-Q1-8.sh
```

The `Q1` tag is a line marker rather than a revision: it follows the head of
this line. `Q1-4` → `Q1-8` on 2026-08-01, `Q1-8` → `Q1-11` on 2026-08-02,
`Q1-11` → the `R2.3` close-out later the same day. Moving it means deleting
and recreating it, so it is only done when asked.

It points at the **branch head**, not at the revision tag — since `R2.3`
the head carries the export directory and the resynced documentation as
well as the installer, and `git show Q1:install.sh` returns the same
script either way. It is behind again as of `R2.5`; moving it is a
separate, explicit request.

`Q1-4`, `Q1-8`, `Q1-11`, `Q1-13`, `Q1-15`, `Q1-20` and every other revision tag stay
where they are — those are fixed identities, as are the `R*` tags. `Q1` is
the only tag in this repository that moves.

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
diff versiyon/V1-20/deploy.sh versiyon/R2.5/deploy.sh
diff versiyon/V1-20/deploy.command versiyon/R2.5/deploy.command
```

Any change to one copy must be applied to the others in the same commit.

## Adding a new export

```sh
mkdir versiyon/<TAG>
git show <TAG>:install.sh > versiyon/<TAG>/install-<TAG>.sh
chmod +x versiyon/<TAG>/install-<TAG>.sh
cp versiyon/R2.5/deploy.sh versiyon/<TAG>/deploy.sh
cp versiyon/R2.5/deploy.command versiyon/<TAG>/deploy.command
```

Then write the `README.md` — it is not optional, see the table at the top.

Keep **exactly one** `install-*.sh` per directory — `deploy.sh` refuses to
run otherwise, on purpose: a second file makes it silently ambiguous which
revision gets installed.
