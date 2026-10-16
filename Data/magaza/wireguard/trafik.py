"""WireGuard package: traffic totals for Konsol's network card (DD-206).

The kernel counts each network's interface (wgN in the package's registry, read from
/sys/class/net); the counters start when the network comes up (wg-quick@wgN). Totals are given
as the VPN's users see them: down = bytes the server sent to the peers (what the devices
downloaded through the VPN), up = bytes received from them. The base loads this file from the
rendered package folder and calls trafik(env); networks that are down add nothing.
"""
import re
from pathlib import Path

from master_settings import env_read, read_regular

PACKAGE_DIR = Path(__file__).resolve().parent
SYS_NET = Path("/sys/class/net")
IFACE_RE = re.compile(r"^wg[0-9]$")


def networks():
    """Interface names from the registry (WG_NETWORKS_FILE, first tab-separated field)."""
    path = env_read(PACKAGE_DIR / "wireguard.env")["WG_NETWORKS_FILE"]
    try:
        raw, _ = read_regular(path)
    except FileNotFoundError:
        return []
    names = [line.split("\t", 1)[0] for line in raw.decode("utf-8").splitlines()]
    return [name for name in names if IFACE_RE.fullmatch(name)]


def counters(iface):
    base = SYS_NET / iface / "statistics"
    return (int((base / "rx_bytes").read_text(encoding="ascii").strip()),
            int((base / "tx_bytes").read_text(encoding="ascii").strip()))


def trafik(env):
    down = up = 0
    for iface in networks():
        try:
            rx, tx = counters(iface)
        except (OSError, ValueError):
            continue
        down, up = down + tx, up + rx
    return {"down": down, "up": up}
