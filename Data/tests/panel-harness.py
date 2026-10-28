#!/usr/bin/env python3
"""Test harness, never installed: runs master-panel's own main() in this process with the values a test
chooses where the installed backend has fixed ones (rebuild phase 6: no switch exists only for tests).

    python3 tests/panel-harness.py --tools DIR [--active-window S] [--sample-seconds S] \\
        serve --listen unix:SOCKET --state FILE

--tools DIR goes first on the base tools' PATH (master-panel's TOOL_PATH), so the backend runs a test's
fake systemd-run, systemctl, master-firewall, … instead of the host's. --active-window replaces
WireGuard's "Bağlı" window (master_wireguard.ACTIVE_WINDOW, DD-137) and --sample-seconds the samplers'
period (SAMPLE_SECONDS in both modules). Everything after these goes to master-panel unchanged.
"""
import argparse
import importlib.machinery
import importlib.util
from pathlib import Path
import sys

SOURCE = Path(__file__).resolve().parents[1] / "panel" / "master-panel"


def main():
    parser = argparse.ArgumentParser(prog="panel-harness")
    parser.add_argument("--tools", required=True)
    parser.add_argument("--active-window", type=float)
    parser.add_argument("--sample-seconds", type=float)
    parser.add_argument("panel", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    loader = importlib.machinery.SourceFileLoader("master_panel", str(SOURCE))
    panel = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(panel)
    panel.TOOL_PATH = args.tools + ":" + panel.TOOL_PATH
    if args.active_window is not None:
        panel.master_wireguard.ACTIVE_WINDOW = args.active_window
    if args.sample_seconds is not None:
        panel.SAMPLE_SECONDS = panel.master_wireguard.SAMPLE_SECONDS = args.sample_seconds
    sys.argv = ["master-panel"] + args.panel
    panel.main()


if __name__ == "__main__":
    main()
