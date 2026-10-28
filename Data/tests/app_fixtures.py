"""Shared fixtures for the application tests (DD-271, phases 3 and 4): a neutral two-service Compose file, its
answers, a state.env for a temporary root and a complete application record (with its access rows) written
through master_applications. Images are registry.example's; nothing here names a real application."""
import copy
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_applications as apps  # noqa: E402
import master_inspector  # noqa: E402

DATA = Path(__file__).resolve().parents[1]
SECRET = "Gizli-deger-7f3a9"
# A web service and its database: an address port, a secret, a data folder each, a /srv folder, a health check
# the web service waits for (service_healthy: Podman 5).
TEXT = """# A neutral two-service application.
name: notlar
services:
  web:
    image: registry.example/notlar/web:1.4
    user: "1000:1000"
    depends_on:
      db:
        condition: service_healthy
    environment:
      DB_PASSWORD: ${DB_PASSWORD}
      LOG_LEVEL: info
    ports:
      - "8080"
    volumes:
      - uploads:/app/uploads
      - /srv/media:/media:ro
  db:
    image: registry.example/notlar/db:16
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/db
    healthcheck:
      test: ["CMD", "check-db", "--quiet"]
      interval: 10s
volumes:
  uploads:
  db-data:
"""
# One service, no dependency, no secret: Podman 4.9 can run it.
SIMPLE = """name: sayac
services:
  app:
    image: registry.example/sayac:2
    ports:
      - "9000"
    volumes:
      - veri:/data
volumes:
  veri:
"""
VERSION = (5, 4)


def answers():
    return {"name": "notlar", "answers": {
        "var:DB_PASSWORD": {"value": SECRET},
        "port:web:8080/tcp": {"use": "caddy", "tailscale_name": "notlar"},
        "mount:web:/app/uploads": {"to": "app"},
        "mount:web:/media": {"to": "srv", "path": "/srv/media", "read_only": True},
        "start:web": {"mode": "direct"},
        "mount:db:/var/lib/db": {"to": "app"},
        "start:db": {"mode": "root"}}}


SIMPLE_ANSWERS = {"name": "sayac", "answers": {"port:app:9000/tcp": {"use": "caddy", "tailscale_name": "sayac"},
                                               "mount:app:/data": {"to": "app"}, "start:app": {"mode": "root"}}}


def env(root):
    """state.env keys of a temporary root. SERVER_ROOT stays /srv (the inspector's and the generator's); a
    test that walks real folders patches the worker's check."""
    root = Path(root).resolve()
    return {"KONTEYNER_STATE_DIR": str(root / "containers"), "UYGULAMA_STATE_DIR": str(root / "containers/uygulamalar"),
            "UYGULAMA_VERI_DIR": str(root / "veri"), "KONTEYNER_BIRIM_DIR": str(root / "quadlet"),
            "KONTEYNER_LOCK": str(root / "run/containers.lock"), "RUNTIME_DIR": str(root / "run"),
            "KONTEYNER_BAGLAMA_DIR": str(root / "run/konteyner-baglama"), "KONTEYNER_BRIDGE_PREFIX": "ksl",
            "KONTEYNER_NFT_TABLE": "master_containers", "TAILSCALE_IF": "tailscale0", "SBIN_DIR": str(root / "sbin"),
            "SERVER_ROOT": "/srv", "FILES_PANEL_TRASH": ".cop", "STATE_FILE": str(root / "state.env"), "DOWNLOADS_UID": "1000", "DOWNLOADS_GID": "1000",
            "UYGULAMA_PORT_ILK": "62100", "UYGULAMA_PORT_SON": "62109", "FILES_PANEL_PORT": "61009", "SHARE_PORT": "61010",
            "LOCAL_DOMAIN": "ev", "TAILSCALE_IPV4": "100.64.0.2", "WAN_IPV4": "203.0.113.10",
            "VPN_BLOCK_DEST4": "0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 "
                               "224.0.0.0/4 240.0.0.0/4",
            "VPN_BLOCK_DEST6": "::/96 ::ffff:0:0/96 64:ff9b::/96 64:ff9b:1::/48 fc00::/7 fe80::/10 ff00::/8"}


def write_state(root, values):
    path = Path(root) / "state.env"
    path.write_text("".join("%s=%s\n" % kv for kv in values.items()))
    return path


def checked(text, given, existing=frozenset()):
    inspection = master_inspector.inspect(text)
    assert not inspection["refusals"], inspection["refusals"]
    definition, values, errors = master_inspector.check(inspection, given, existing_secrets=frozenset(existing))
    assert not errors, errors
    return inspection, definition, values


def record(values, text=None, given=None, app="notlar", stopped=False, ports=None, revision="a" * 32, source=None, rows=None):
    """A complete record through master_applications.Records (as the worker writes it): the rows seeded from the
    answers (or the given rows), the stored definition, pinned images, a pool port per address row and a Podman
    secret name per secret."""
    text = text if text is not None else TEXT
    given = given if given is not None else answers()
    inspection, definition, _values = checked(text, given)
    rows = rows if rows is not None else apps.next_rows(definition)
    stored = apps.stored_definition(definition)
    images = {s["name"]: apps.reference(s["image"])[0] + "@sha256:" + "%02x" % n * 32 for n, s in enumerate(definition["services"], 1)}
    ports = ports if ports is not None else {k: 62100 + n for n, k in enumerate(apps.address_keys(rows))}
    secrets = {s["name"]: "obhut_%s_%08x" % (app, n) for n, s in enumerate(definition["secrets"], 1)}
    places = {"revision": revision, "stopped": stopped, "ports": ports, "secrets": secrets, "images": images}
    apps.Records(values).write(app, text=text, source=apps.source_record(source or {"tur": "dosya"}, text, 1_800_000_000),
                               answers=apps.stored_answers(inspection, given), definition=stored, places=places, rows=rows)
    return {"inspection": inspection, "definition": stored, "checked": definition, "places": copy.deepcopy(places),
            "text": text, "rows": copy.deepcopy(rows)}
