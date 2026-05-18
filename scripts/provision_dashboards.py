#!/usr/bin/env python3
"""
Upserts all dashboard JSON files from the dashboards/ directory into SigNoz.

For each file:
  - If a dashboard with the same title already exists → PUT (update)
  - Otherwise → POST (create)

This makes the command safe to re-run after editing a dashboard JSON.

Usage (runs on the Sprite, URL auto-detected):
  install.sh provision-dashboards

Manual usage:
  SIGNOZ_URL=https://NAME.sprites.app python3 scripts/provision_dashboards.py
  SIGNOZ_TOKEN=<jwt> python3 scripts/provision_dashboards.py
"""

import getpass
import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

# ── Config ────────────────────────────────────────────────────────────────────
DASHBOARDS_DIR = Path(__file__).parent.parent / "dashboards"

SIGNOZ_URL = os.environ.get("SIGNOZ_URL", "http://localhost:3301").rstrip("/")


# ── HTTP helpers ──────────────────────────────────────────────────────────────
def _http(method: str, path: str, payload=None, headers: dict | None = None) -> bytes:
    data = json.dumps(payload).encode() if payload is not None else None
    h = {"Content-Type": "application/json", **(headers or {})}
    req = Request(f"{SIGNOZ_URL}{path}", data=data, headers=h, method=method)
    try:
        with urlopen(req) as resp:
            return resp.read()
    except HTTPError as exc:
        body = exc.read()
        print(
            f"{method} {path} failed (HTTP {exc.code}): {body.decode(errors='replace')}",
            file=sys.stderr,
        )
        sys.exit(1)


def _json(method: str, path: str, payload=None, headers: dict | None = None) -> dict:
    body = _http(method, path, payload, headers)
    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        print(f"{method} {path} returned non-JSON ({exc}):", file=sys.stderr)
        print(body.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)


# ── Auth ──────────────────────────────────────────────────────────────────────
TOKEN = os.environ.get("SIGNOZ_TOKEN", "")
if not TOKEN:
    email = input("SigNoz email: ")
    password = getpass.getpass("SigNoz password: ")

    ctx = _json("GET", f"/api/v2/sessions/context?email={email}&ref=http://localhost")
    orgs = ctx.get("data", {}).get("orgs", [])
    if not orgs:
        print("No organisations found for that email.", file=sys.stderr)
        sys.exit(1)
    org_id = orgs[0]["id"]

    result = _json(
        "POST",
        "/api/v2/sessions/email_password",
        {"email": email, "password": password, "orgId": org_id},
    )
    TOKEN = (result.get("data") or result).get("accessToken", "")
    if not TOKEN:
        print(
            f"Login succeeded but no accessToken in response: {result}", file=sys.stderr
        )
        sys.exit(1)

HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def api_get(path: str) -> dict:
    return _json("GET", path, headers=HEADERS)


def api_post(path: str, payload: dict) -> dict:
    return _json("POST", path, payload, headers=HEADERS)


def api_put(path: str, payload: dict) -> dict:
    return _json("PUT", path, payload, headers=HEADERS)


# ── Dashboard upsert ──────────────────────────────────────────────────────────
def fetch_existing() -> dict[str, dict]:
    """Return a mapping of title → existing dashboard (with uuid)."""
    resp = api_get("/api/v1/dashboards")
    dashboards = resp.get("data", []) or []
    if dashboards:
        first = dashboards[0]
        print(f"  [debug] first dashboard top-level keys: {sorted(first.keys())}")
        print(
            f"  [debug] first dashboard.data keys: {sorted(first.get('data', {}).keys())}"
        )
    return {d.get("data", {}).get("title", ""): d for d in dashboards}


def upsert_dashboard(definition: dict, existing_by_title: dict[str, dict]) -> str:
    title = definition.get("title", "<untitled>")
    existing = existing_by_title.get(title)

    if existing:
        uuid = existing.get("uuid") or existing.get("data", {}).get("uuid", "")
        api_put(f"/api/v1/dashboards/{uuid}", definition)
        return f"updated  {title!r}"
    else:
        api_post("/api/v1/dashboards", definition)
        return f"created  {title!r}"


# ── Main ──────────────────────────────────────────────────────────────────────
def main() -> None:
    files = sorted(DASHBOARDS_DIR.glob("*.json"))
    if not files:
        print(f"No dashboard JSON files found in {DASHBOARDS_DIR}", file=sys.stderr)
        sys.exit(1)

    print(f"Target:  {SIGNOZ_URL}")
    print(f"Dashboards directory: {DASHBOARDS_DIR}")
    print(f"Found {len(files)} file(s)\n")

    existing = fetch_existing()
    print(f"SigNoz currently has {len(existing)} dashboard(s)\n")

    results = []
    for path in files:
        try:
            definition = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            print(f"  SKIP  {path.name} — invalid JSON: {exc}", file=sys.stderr)
            continue

        status = upsert_dashboard(definition, existing)
        results.append((path.name, status))
        print(f"  ✓  {status}  ({path.name})")

    print(f"\nDone. {len(results)} dashboard(s) provisioned.")


if __name__ == "__main__":
    main()
