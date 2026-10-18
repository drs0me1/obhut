#!/usr/bin/env python3
"""PostToolUse hook: checks a shell script right after it is edited, as Data/tests/README.md's static checks do.

Every Bash file of the tree gets `bash -n`; those the static checks run shellcheck on (install.sh, common.sh,
scripts/*, kur.sh) also get `shellcheck -x -s bash`, from the file's own folder so its `source` lines resolve.
Anything else passes silently. Exit 2 hands the findings back to Claude; the edit itself has already happened.
"""
import json
import os
import shutil
import subprocess
import sys

SHELLCHECKED = ("Data/install.sh", "Data/common.sh", "kur.sh")


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    path = (event.get("tool_input") or {}).get("file_path")
    if not isinstance(path, str) or not os.path.isfile(path):
        return 0
    root = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or os.getcwd())
    real = os.path.realpath(path)
    if not real.startswith(root + os.sep):
        return 0
    rel = os.path.relpath(real, root)
    try:
        with open(real, "rb") as handle:
            first = handle.readline()
    except OSError:
        return 0
    bash = rel.endswith((".sh", ".command", ".bats")) or (first.startswith(b"#!") and b"bash" in first)
    if not bash or rel.endswith(".bats"):
        return 0
    problems = []
    syntax = subprocess.run(["bash", "-n", real], capture_output=True, text=True)
    if syntax.returncode:
        problems.append("bash -n %s:\n%s" % (rel, syntax.stderr.strip()))
    elif (rel in SHELLCHECKED or rel.startswith("Data/scripts/")) and shutil.which("shellcheck"):
        check = subprocess.run(["shellcheck", "-x", "-s", "bash", os.path.basename(real)], cwd=os.path.dirname(real),
                               capture_output=True, text=True)
        if check.returncode:
            problems.append("shellcheck -x -s bash %s:\n%s" % (rel, (check.stdout or check.stderr).strip()))
    if not problems:
        return 0
    print("\n\n".join(problems), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
