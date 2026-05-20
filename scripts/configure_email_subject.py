#!/usr/bin/env python3
"""
Patches the SigNoz alertmanager config so that alert emails have a clean
subject line showing the human-readable rule name instead of the UUID.

Before:
  [FIRING:1] 019e3c92-65fd-7456-8ecb-a93912c91236 ([5.5] Memory Available — Warning ...)

After:
  [FIRING:1] [5.5] Memory Available — Warning

How it works:
  SigNoz stores the full Alertmanager config as JSON in its SQLite database.
  Each email receiver has a `headers` field where arbitrary email headers
  (including Subject) can be set as Go templates.  By default this is empty,
  so Alertmanager falls back to its built-in subject template which shows the
  alertname group label — which SigNoz sets to the rule UUID, not the name.

  The human-readable rule name is always available in the `summary` annotation
  (every rule in this repo populates it with the same text as the rule name).
  Using `.CommonAnnotations.summary` picks that up cleanly.

The script is idempotent: running it again when the Subject header is already
correct produces no change.

Usage (runs on the Sprite, SQLite path auto-detected):
  install.sh configure-email-subject

Manual usage:
  python3 scripts/configure_email_subject.py
  SIGNOZ_DB=/path/to/signoz.db python3 scripts/configure_email_subject.py
"""

import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_DB = Path("/var/lib/docker/volumes/signoz-sqlite/_data/signoz.db")
SIGNOZ_DB = Path(os.environ.get("SIGNOZ_DB", str(DEFAULT_DB)))

# The Go template written into headers["Subject"].
# Produces e.g.:  [FIRING:1] [5.5] Memory Available — Warning
#             or: [RESOLVED] [5.5] Memory Available — Warning
SUBJECT_TEMPLATE = (
    "[{{ .Status | toUpper }}"
    '{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] '
    "{{ .CommonAnnotations.summary }}"
)


# ── Helpers ───────────────────────────────────────────────────────────────────


def _config_hash(config_str: str) -> str:
    """MD5 of the raw config string, matching SigNoz's own hash calculation."""
    return hashlib.md5(config_str.encode()).hexdigest()


# ── Main ──────────────────────────────────────────────────────────────────────


def main() -> None:
    if not SIGNOZ_DB.exists():
        print(f"✗  SigNoz database not found at {SIGNOZ_DB}", file=sys.stderr)
        print("   Set SIGNOZ_DB=/path/to/signoz.db to override.", file=sys.stderr)
        sys.exit(1)

    con = sqlite3.connect(str(SIGNOZ_DB))
    cur = con.cursor()

    rows = cur.execute(
        "SELECT id, config FROM alertmanager_config ORDER BY created_at DESC LIMIT 1"
    ).fetchall()

    if not rows:
        print("✗  No alertmanager_config row found in the database.", file=sys.stderr)
        sys.exit(1)

    row_id, config_raw = rows[0]
    config = json.loads(config_raw)

    changed = False
    for receiver in config.get("receivers", []):
        for email_cfg in receiver.get("email_configs", []):
            headers = email_cfg.setdefault("headers", {})
            if headers.get("Subject") == SUBJECT_TEMPLATE:
                print(
                    f"  ✓  Receiver '{receiver['name']}': Subject already set correctly."
                )
                continue
            headers["Subject"] = SUBJECT_TEMPLATE
            print(f"  ▸  Receiver '{receiver['name']}': Subject header updated.")
            changed = True

    if not changed:
        print(
            "\nNothing to change — all email receivers already have the correct Subject."
        )
        return

    new_config_str = json.dumps(config)
    new_hash = _config_hash(new_config_str)

    cur.execute(
        "UPDATE alertmanager_config SET config = ?, hash = ?, updated_at = datetime('now') WHERE id = ?",
        (new_config_str, new_hash, row_id),
    )
    con.commit()
    con.close()

    print("\n  ✓  Database updated.  Restart the SigNoz container to apply:")
    print("       cd ~/fly-o11y/setup && docker compose restart signoz")


if __name__ == "__main__":
    main()
