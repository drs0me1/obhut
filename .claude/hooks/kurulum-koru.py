#!/usr/bin/env python3
"""PreToolUse hook: refuses a tool call that names the Git-ignored kurulum/ folder or its kurulum.env.

CLAUDE.md: never open, print or copy kurulum/kurulum.env (the operator's SSH host); downloaded WireGuard
device profiles and QR codes under kurulum/wireguard/ hold private keys. Running wireguard.command or
onar.command stays possible: their command lines do not name the folder. The template
Data/config/kurulum.env.example is not the file and stays readable. A call that does not name the folder is not
seen: a recursive search or archive of the repository root from the shell would still reach it (the Grep tool
respects .gitignore); never run one there.

Input: the hook's JSON on standard input. Exit 2 with a reason on standard error blocks the call.
"""
import json
import os
import re
import sys

# A path token that starts at the folder: "kurulum/…", "./kurulum/…", "…/kurulum/…".
FOLDER_RE = re.compile(r"""(?:^|[\s'"=:(<>|;&`])(?:\S*/)?kurulum/""")
# The file itself, named without its folder (but not the .example template).
FILE_RE = re.compile(r"kurulum\.env(?!\.example)")


def project_root(event):
    return os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or os.getcwd())


def inside(path, folder):
    path = os.path.realpath(path)
    return path == folder or path.startswith(folder + os.sep)


def reason(event):
    tool = event.get("tool_name", "")
    given = event.get("tool_input") or {}
    root = project_root(event)
    folder = os.path.join(root, "kurulum")
    if tool == "Bash":
        command = str(given.get("command", ""))
        if FOLDER_RE.search(command) or FILE_RE.search(command):
            return "the command names kurulum/ or kurulum.env"
        return ""
    for key in ("file_path", "notebook_path", "path"):
        value = given.get(key)
        if isinstance(value, str) and value:
            target = value if os.path.isabs(value) else os.path.join(event.get("cwd") or root, value)
            if inside(target, folder) or FILE_RE.search(os.path.basename(value)):
                return "%s points into kurulum/" % key
    pattern = given.get("pattern") if tool == "Glob" else given.get("glob")
    if isinstance(pattern, str) and (FOLDER_RE.search(" " + pattern) or FILE_RE.search(pattern)):
        return "the pattern reaches kurulum/"
    return ""


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    why = reason(event)
    if not why:
        return 0
    print("Blocked (CLAUDE.md): kurulum/ holds the operator's SSH host and private WireGuard profiles; never open, "
          "print or copy it (%s). Run wireguard.command or onar.command only when the user asks in chat." % why,
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
