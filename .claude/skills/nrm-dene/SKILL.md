---
name: nrm-dene
description: Installs the current working tree on the test host nrm through kur.sh (an archive of the runtime tree, KUR_URL, the re-run's default answers and E), then reports the build that runs there. Only when the user asks for it.
disable-model-invocation: true
---

# nrm-dene: the working tree on the test host

CLAUDE.md's standing authorization covers `nrm` only: the installer, `sudo`, reboots and data loss there are
fine, server-side backups are not made, other hosts are never touched. This skill proves the written code on the
real server the way an operator gets it: `kur.sh` with the tree as an archive (`KUR_URL`, DD-228).

```bash
.claude/skills/nrm-dene/nrm-dene.sh            # a re-run over an existing install (no question but "E")
.claude/skills/nrm-dene/nrm-dene.sh ev         # a first install on a clean host: the local domain (a scratch one)
```

- Run the script in the background; it prints the log's path first and the installer's exit code and the
  server's `V2_VERSION` last. Do not poll it in a loop: wait for it to end.
- A first install stops at the Tailscale login: read the log for the `https://login.tailscale.com/a/...` line,
  relay **only that URL** to the user and wait; it expires if left unused. Never relay anything else from the log.
- The log is local and holds the server's addresses: quote from it only what the user needs, never copy it into
  the repository, and keep host addresses out of commits and messages.
- The archive takes `kur.sh`'s own list of runtime items, so it never holds the Git-ignored installer inputs.
- After it ends, check what the change was for (Konsol at `http://panel.<domain>` over Tailscale, journals over
  `ssh nrm`) and report what was actually run and the real outcome. Test applications made for the check are
  removed again with their data unless the user wants them kept.
