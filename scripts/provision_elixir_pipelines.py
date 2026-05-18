#!/usr/bin/env python3
"""
Provisions a single "Elixir Logs" pipeline into SigNoz with all Plug.Logger /
Phoenix.Logger processors chained inside it.

The pipeline filter is left broad on purpose — narrow it in the SigNoz UI to
scope it to your Elixir apps (Settings → Logs Pipelines → Elixir Logs).

Usage (URL and token auto-detected from secrets.env when run via install.sh):
  install.sh provision-elixir-pipeline

Manual usage:
  SIGNOZ_URL=https://NAME.sprites.app python3 scripts/provision_elixir_pipelines.py
  SIGNOZ_TOKEN=<jwt> SIGNOZ_URL=... python3 scripts/provision_elixir_pipelines.py

Idempotent: re-running removes the old "elixir-logs" pipeline and re-creates it.

See docs/signoz-ui-log-pipelines.md for the full explanation.
"""

import getpass
import json
import os
import sys
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

# ── Config ────────────────────────────────────────────────────────────────────
# Default to the local SigNoz port — the script runs on the same machine.
# Override with SIGNOZ_URL if you need to target a remote instance.
SIGNOZ_URL = os.environ.get("SIGNOZ_URL", "http://localhost:3301").rstrip("/")


def _http(
    method: str, path: str, payload: dict | None = None, headers: dict | None = None
) -> bytes:
    """Raw HTTP helper used before HEADERS is established."""
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


def _json(
    method: str, path: str, payload: dict | None = None, headers: dict | None = None
) -> dict:
    body = _http(method, path, payload, headers)
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        print(f"{method} {path} returned non-JSON ({exc}):", file=sys.stderr)
        print(body.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)


TOKEN = os.environ.get("SIGNOZ_TOKEN", "")
if not TOKEN:
    email = input("SigNoz email: ")
    password = getpass.getpass("SigNoz password: ")

    # 1. Resolve orgId for this email
    ctx = _json("GET", f"/api/v2/sessions/context?email={email}&ref=http://localhost")
    orgs = ctx.get("data", {}).get("orgs", [])
    if not orgs:
        print("No organisations found for that email.", file=sys.stderr)
        sys.exit(1)
    org_id = orgs[0]["id"]

    # 2. Exchange credentials for a token
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

PIPELINE_ALIAS = "elixir-logs"


def api_get(path: str) -> dict:
    return _json("GET", path, headers=HEADERS)


def api_post(path: str, payload: dict) -> dict:
    return _json("POST", path, payload, headers=HEADERS)


# ── Regexes ───────────────────────────────────────────────────────────────────
# Source of truth: docs/elixir-log-parsing.md
# \xb5 = µ (U+00B5 MICRO SIGN) kept as ASCII escape

# Matches any Plug/Phoenix log line that carries OTel trace context, e.g.:
#   21:19:24.401 request_id=X trace_id=a793410e0269ca86... span_id=53ea3ddf... [info] ...
RE_TRACE_CONTEXT = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)"
    r"\s+trace_id=(?P<trace_id>[0-9a-f]{32})\s+span_id=(?P<span_id>[0-9a-f]{16})"
)

RE_REQUEST_START = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)"
    r"\s+\[(?P<log_level>[^\]]+)\]\s+"
    r"(?P<http_method>GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)"
    r"\s+(?P<http_path>\S+)$"
)
RE_RESPONSE = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)"
    r"\s+\[(?P<log_level>[^\]]+)\]\s+(?P<connection_type>Sent|Chunked)"
    r"\s+(?P<http_status>\d{3})\s+in\s+(?P<duration>\d+)(?P<duration_unit>\xb5s|ms)"
)
RE_ROUTER = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)"
    r"\s+\[(?P<log_level>[^\]]+)\]\s+Processing with\s+"
    r"(?P<controller>[A-Za-z0-9_.]+)\.(?P<action>[a-z_]+)/(?P<arity>\d)"
)
RE_ERROR = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)"
    r"\s+\[(?P<log_level>[^\]]+)\]\s+Converted\s+(?P<error_kind>error|throw|exit)"
    r"\s+(?P<error_type>\S+)\s+to\s+(?P<error_status>\d{3})\s+response"
)
RE_WS = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)"
    r"\s+\[(?P<log_level>[^\]]+)\]\s+"
    r"(?P<ws_result>CONNECTED TO|REFUSED CONNECTION TO)"
    r"\s+(?P<socket_module>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>\xb5s|ms)"
)
RE_CHANNEL_JOIN = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+"
    r"(?P<join_result>JOINED|REFUSED JOIN)\s+(?P<topic>\S+)"
    r"\s+in\s+(?P<duration>\d+)(?P<duration_unit>\xb5s|ms)"
)
RE_CHANNEL_MSG = (
    r"^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+"
    r"HANDLED\s+(?P<event>\S+)\s+INCOMING ON\s+(?P<topic>\S+)"
    r"\s+\((?P<channel_module>[^)]+)\)\s+in\s+(?P<duration>\d+)(?P<duration_unit>\xb5s|ms)"
)

DURATION_EXPR = (
    'EXPR(attributes["duration_unit"] == "ms"'
    ' ? float(attributes["duration"]) / 1000.0'
    ' : float(attributes["duration"]) / 1000000.0)'
)


# ── Processor builder helpers ─────────────────────────────────────────────────
def uid() -> str:
    return str(uuid.uuid4())


def regex(name: str, regex_str: str) -> dict:
    return {
        "id": uid(),
        "orderId": 0,  # patched by chain()
        "type": "regex_parser",
        "name": name,
        "enabled": True,
        "parse_from": "body",
        "parse_to": "attributes",
        "regex": regex_str,
        "on_error": "send",
        "output": "",  # patched by chain()
    }


def severity(name: str) -> dict:
    return {
        "id": uid(),
        "orderId": 0,
        "type": "severity_parser",
        "name": name,
        "enabled": True,
        "parse_from": "attributes.log_level",
        "mapping": {
            "info": ["info"],
            "warn": ["warning"],
            "error": ["error"],
            "debug": ["debug"],
        },
        "output": "",
    }


def trace_context_parser(name: str) -> dict:
    """Promotes attributes.trace_id / span_id to OTel trace context."""
    return {
        "id": uid(),
        "orderId": 0,
        "type": "trace_parser",
        "name": name,
        "enabled": True,
        "trace_id": {"parse_from": "attributes.trace_id"},
        "span_id": {"parse_from": "attributes.span_id"},
        "output": "",
    }


def duration(name: str) -> dict:
    return {
        "id": uid(),
        "orderId": 0,
        "type": "add",
        "name": name,
        "enabled": True,
        "field": "attributes.duration_seconds",
        "value": DURATION_EXPR,
        "output": "",
    }


def chain(ops: list[dict]) -> list[dict]:
    """Assign orderId and wire output references through the list."""
    for i, op in enumerate(ops):
        op["orderId"] = i + 1
        op["output"] = ops[i + 1]["id"] if i < len(ops) - 1 else ""
    return ops


# ── Pipeline definition ───────────────────────────────────────────────────────
def make_pipeline() -> dict:
    processors = chain(
        [
            # OTel trace context — must come first
            regex("Trace Context: regex", RE_TRACE_CONTEXT),
            trace_context_parser("Trace Context: trace_parser"),
            # Plug.Logger: request start
            regex("Request Start: regex", RE_REQUEST_START),
            # Plug.Logger: response
            regex("Response: regex", RE_RESPONSE),
            severity("Response: severity"),
            duration("Response: duration"),
            # Phoenix.Logger: router dispatch
            regex("Router Dispatch: regex", RE_ROUTER),
            # Phoenix.Logger: error rendered
            regex("Error Rendered: regex", RE_ERROR),
            # Phoenix.Logger: WebSocket connect
            regex("WebSocket Connect: regex", RE_WS),
            duration("WebSocket Connect: duration"),
            # Phoenix.Logger: channel join
            regex("Channel Join: regex", RE_CHANNEL_JOIN),
            # Phoenix.Logger: channel message handled
            regex("Channel Message: regex", RE_CHANNEL_MSG),
            duration("Channel Message: duration"),
        ]
    )

    return {
        "id": uid(),
        "orderId": 1,  # re-numbered by main after merging
        "name": "Elixir Logs",
        "alias": PIPELINE_ALIAS,
        "description": (
            "Parses all Plug.Logger and Phoenix.Logger log lines. "
            "Set the filter in the SigNoz UI to scope to your service."
        ),
        "enabled": True,
        # Minimal valid filter — narrow it in the SigNoz UI after provisioning.
        "filter": {
            "op": "AND",
            "items": [
                {
                    "key": {
                        "key": "body",
                        "dataType": "string",
                        "type": "",
                        "isColumn": True,
                    },
                    "op": "!=",
                    "value": "",
                }
            ],
        },
        "config": processors,
    }


# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"Target: {SIGNOZ_URL}")

    # 1. Fetch current pipelines
    existing = (
        api_get("/api/v1/logs/pipelines/latest").get("data", {}).get("pipelines", [])
    )
    print(f"Found {len(existing)} existing pipeline(s)")

    # 2. Drop previous Elixir pipeline
    kept = [p for p in existing if p.get("alias") != PIPELINE_ALIAS]
    print(f"Keeping {len(kept)} other pipeline(s)")

    # 3. Build and merge
    all_pipelines = kept + [make_pipeline()]
    for i, p in enumerate(all_pipelines, start=1):
        p["orderId"] = i

    # 4. POST (full replace)
    result = api_post("/api/v1/logs/pipelines", {"pipelines": all_pipelines})
    n = len(result.get("data", {}).get("pipelines", []))
    print(f"Done. SigNoz now has {n} pipeline(s).")
    print(
        f"\n⚠  The '{PIPELINE_ALIAS}' pipeline is ENABLED with a broad filter (body != \"\")."
    )
    print("   Narrow it in SigNoz → Settings → Logs Pipelines → Elixir Logs:")
    print('   e.g. set the filter to  service_name = "my-elixir-app"')
