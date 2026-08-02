# Exported installer revisions — `quantum` branch

One directory per exported revision. **Every directory contains four files,
without exception** (standing rule, 2026-08-01):

| File | Why |
|---|---|
| `install-<EXPORT>.sh` | the frozen export, byte-identical to its recorded source revision |
| `deploy.sh` | asks for a host, copies, verifies the SHA256, can start the install |
| `deploy.command` | the same thing, double-clickable from Finder |
| `README.md` | **operator-facing**: version identity, then a plain-language description of what gets installed, what to do first, and what to watch out for |

The README is deliberately non-technical — these folders get carried to
other machines on their own, and whoever opens one is installing, not
developing. Internals belong in [`../docs/`](../docs/), not here.

| Directory | Version | Tags | Web file manager | Status |
|---|---|---|---|---|
| [`R2.6/`](R2.6/) | `2026.08.02-Q1-22` | `R2.6`, `Q1-22` | `ghcr.io/gtsteffaniak/filebrowser:stable` | **Current; tagged for manual testing, live result pending** |
| [`V1-20/`](V1-20/) | `2026.07.31-V1-20` | `V1-20`, `R2.0` | `filebrowser/filebrowser:v2` | Branch point, expires 2026-09-01 |

```sh
cd versiyon/R2.6
./deploy.sh nrm --run
```

From Finder, double-click `deploy.command` instead.

`R2.6` was exported **and tagged before any live verification**, at the
operator's explicit request, so it can be carried to a machine and installed by
hand. This inverts the branch's normal order — every other release was tagged
only after a real install — so the tag carries no live-success claim, and both
its own `README.md` and the `R2.6` tag message say so. The last release that
*was* live-verified remains `R2.5` / `Q1-20`, reachable through its tag; it no
longer has a directory.

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
joining it, `R2.4/` replaced `R2.3/`, `R2.5/` replaced `R2.4/`, and the
operator-requested R2.6 test export replaced `R2.5/`. This is the one thing
not to get wrong: two directories holding a byte-identical installer is
exactly the ambiguity the retirement rule below exists to prevent, so a
release directory *supersedes* the one before it — it never sits beside it.
`R2.2` predates this
and never had a directory at all.

A release directory carries the revision's version string, because that is
what the script prints: `versiyon/R2.6/install-R2.6.sh` reports
`2026.08.02-Q1-22`. Its `README.md` says so up front, so nobody reads it as
a mismatch.

Every export is byte-identical to the tag it is named after — including
`R2.6`, whose exception is the *timing* of its tag, not its integrity:

```sh
git show R2.6:install.sh | sha256sum
sha256sum R2.6/install-R2.6.sh
```

## Retired directories

Only the current revision and the branch point are kept as directories; the
export a new one replaces is removed rather than accumulated, so there is
never a question of which folder to hand someone. `Q1-1` was retired when
`Q1-4` was exported, `Q1-4` when `Q1-8` was, `Q1-8` when `Q1-11` was,
`Q1-11` when `Q1-13` was, `Q1-13` when `R2.3` was cut from it, and `R2.3`
when `R2.4` superseded it, `R2.4` when `R2.5` superseded it, then the
`R2.5` directory when the operator requested the unverified R2.6 test export.
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
script either way. It is behind again as of the R2.6 test export; moving it is a
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
diff versiyon/V1-20/deploy.sh versiyon/R2.6/deploy.sh
diff versiyon/V1-20/deploy.command versiyon/R2.6/deploy.command
```

Any change to one copy must be applied to the others in the same commit.

## Adding a new export

```sh
mkdir versiyon/<EXPORT>
git show <SOURCE>:install.sh > versiyon/<EXPORT>/install-<EXPORT>.sh
chmod +x versiyon/<EXPORT>/install-<EXPORT>.sh
cp versiyon/R2.6/deploy.sh versiyon/<EXPORT>/deploy.sh
cp versiyon/R2.6/deploy.command versiyon/<EXPORT>/deploy.command
```

Then write the `README.md` — it is not optional, see the table at the top.

Keep **exactly one** `install-*.sh` per directory — `deploy.sh` refuses to
run otherwise, on purpose: a second file makes it silently ambiguous which
revision gets installed.
