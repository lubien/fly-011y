#!/usr/bin/env python3
"""
Provisions critical observability-pipeline health alerts into SigNoz.

These alerts fire when the plumbing that delivers your signals breaks —
the gap this stack had before the May 2026 log-shipper outage went unnoticed
for 1.5 hours because there was no alert for "logs have stopped flowing".

Alerts provisioned:
  1. [CRITICAL] Log Pipeline Silent — no logs received in 15 min
  2. [CRITICAL] Metrics Pipeline Silent — no Fly metrics in 10 min
  3. [CRITICAL] Collector Dropping Data — otelcol enqueue failures > 0
  4. [WARNING]  Collector Write Errors — otelcol export failures spiking

Usage (runs on the Sprite, URL auto-detected):
  install.sh provision-pipeline-alerts

Manual:
  SIGNOZ_URL=http://localhost:3301 python3 scripts/provision_pipeline_alerts.py
  SIGNOZ_TOKEN=<jwt> python3 scripts/provision_pipeline_alerts.py

Idempotent: re-running updates existing rules matched by name.
"""

import getpass
import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

# ── Config ────────────────────────────────────────────────────────────────────
SIGNOZ_URL = os.environ.get("SIGNOZ_URL", "http://localhost:3301").rstrip("/")


# ── HTTP helpers ──────────────────────────────────────────────────────────────
def _http(method, path, payload=None, headers=None):
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


def _json(method, path, payload=None, headers=None):
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


def api_get(path):
    return _json("GET", path, headers=HEADERS)


def api_post(path, payload):
    return _json("POST", path, payload, headers=HEADERS)


def api_put(path, payload):
    return _json("PUT", path, payload, headers=HEADERS)


# ── Alert definitions ─────────────────────────────────────────────────────────
def make_promql_alert(
    name,
    description,
    severity,
    eval_window,
    query,
    op,
    target,
    match_type="at_least_once",
    absent=False,
):
    """Build a PromQL-based alert rule (PostableRule format, version v5)."""
    condition = {
        "compositeQuery": {
            "queryType": "promql",
            "panelType": "graph",
            "unit": "",
            "queries": [
                {
                    "type": "promql",
                    "spec": {
                        "name": "A",
                        "query": query,
                        "disabled": False,
                        "legend": "",
                    },
                }
            ],
        },
        "op": op,
        "target": target,
        "matchType": match_type,
        "selectedQueryName": "A",
        "targetUnit": "",
        "alertOnAbsent": absent,
        "absentFor": 600000 if absent else 0,  # 10 min in ms
        "requireMinPoints": False,
    }
    return {
        "alert": name,
        "description": description,
        "alertType": "METRIC_BASED_ALERT",
        "ruleType": "promql_rule",
        "version": "v5",
        "evalWindow": eval_window,
        "frequency": "1m0s",
        "condition": condition,
        "labels": {"severity": severity},
        "annotations": {
            "description": description,
            "summary": name,
        },
        "disabled": False,
    }


def make_log_count_alert(
    name,
    description,
    severity,
    eval_window,
    filter_expr,
    threshold,
    match_type="at_least_once",
):
    """Build a log-count-based alert rule (PostableRule format, version v5)."""
    condition = {
        "compositeQuery": {
            "queryType": "builder",
            "panelType": "graph",
            "unit": "",
            "queries": [
                {
                    "type": "builder_query",
                    "spec": {
                        "signal": "logs",
                        "name": "A",
                        "disabled": False,
                        "stepInterval": "60",
                        "filter": {"expression": filter_expr},
                        "aggregations": [{"expression": "count()", "alias": "count"}],
                        "groupBy": [],
                    },
                }
            ],
        },
        "op": "above" if threshold > 0 else "below_or_equal",
        "target": threshold,
        "matchType": match_type,
        "selectedQueryName": "A",
        "targetUnit": "",
        "requireMinPoints": False,
    }
    return {
        "alert": name,
        "description": description,
        "alertType": "LOGS_BASED_ALERT",
        "ruleType": "threshold_rule",
        "version": "v5",
        "evalWindow": eval_window,
        "frequency": "1m0s",
        "condition": condition,
        "labels": {"severity": severity},
        "annotations": {
            "description": description,
            "summary": name,
        },
        "disabled": False,
    }


# ── Alert catalogue ───────────────────────────────────────────────────────────
ALERTS = [
    # ── 1. Log pipeline silent ───────────────────────────────────────────────
    # Fires when the otel-collector stops receiving any log records.
    # This would have caught the 1.5-hour log-shipper outage immediately.
    make_promql_alert(
        name="[P0] Log Pipeline Silent",
        description=(
            "The otel-collector has received 0 log records for 15 minutes. "
            "The log shippers (Vector on Fly.io) are likely down or the "
            "httplogreceiver is not reachable. Check: fly status --app <log-shipper-app>"
        ),
        severity="critical",
        eval_window="15m0s",
        query="sum(rate(otelcol_receiver_accepted_log_records[5m]))",
        op="below_or_equal",
        target=0,
        match_type="all_the_times",
    ),
    # ── 2. Metrics pipeline silent ───────────────────────────────────────────
    # Fires when no Fly Prometheus metrics are being received.
    # Absence of fly_instance_up means the federation scrape has stopped.
    make_promql_alert(
        name="[P0] Metrics Pipeline Silent",
        description=(
            "The otel-collector has received 0 metric points for 10 minutes. "
            "The Prometheus federation scrape against api.fly.io may be failing. "
            "Check otel-collector logs: docker logs signoz-otel-collector | grep prometheus"
        ),
        severity="critical",
        eval_window="10m0s",
        query="sum(rate(otelcol_receiver_accepted_metric_points[5m]))",
        op="below_or_equal",
        target=0,
        match_type="all_the_times",
    ),
    # ── 3. Collector dropping data ───────────────────────────────────────────
    # Fires when the otel-collector's export queue fills up and data is dropped.
    # This is the "no more retries left: Dropping data" event — directly signals
    # that telemetry is being permanently lost, not just delayed.
    make_promql_alert(
        name="[P0] Collector Dropping Telemetry",
        description=(
            "The otel-collector is dropping telemetry because its export queues "
            "are full. This means ClickHouse is not accepting writes fast enough "
            "and data is being permanently lost. "
            "Check: docker logs signoz-otel-collector | grep 'Dropping data'"
        ),
        severity="critical",
        eval_window="5m0s",
        query=(
            "sum(increase(otelcol_exporter_enqueue_failed_log_records[5m])) + "
            "sum(increase(otelcol_exporter_enqueue_failed_metric_points[5m])) + "
            "sum(increase(otelcol_exporter_enqueue_failed_spans[5m]))"
        ),
        op="above",
        target=0,
        match_type="at_least_once",
    ),
    # ── 4. Collector write errors elevated ───────────────────────────────────
    # Fires when ClickHouse write failures are sustained — early warning before
    # the queue fills and data starts dropping (alert 3).
    make_promql_alert(
        name="[P1] Collector ClickHouse Write Errors",
        description=(
            "The otel-collector has sustained ClickHouse write failures for 10 minutes. "
            "This may indicate ClickHouse is overloaded (too many parts from a backlog flush) "
            "or the connection to localhost:9000 is failing. "
            "Telemetry is being retried but may eventually drop if not resolved."
        ),
        severity="warning",
        eval_window="10m0s",
        query=(
            "sum(rate(otelcol_exporter_send_failed_log_records[5m])) + "
            "sum(rate(otelcol_exporter_send_failed_metric_points[5m])) + "
            "sum(rate(otelcol_exporter_send_failed_spans[5m]))"
        ),
        op="above",
        target=0,
        match_type="all_the_times",
    ),
]


# ── Upsert logic ──────────────────────────────────────────────────────────────
def fetch_existing():
    """Return dict of alert_name → rule (with id)."""
    resp = api_get("/api/v1/rules")
    rules = (resp.get("data") or {}).get("rules") or []
    # Flatten: some versions wrap each rule differently
    if isinstance(rules, list) and rules and isinstance(rules[0], dict):
        return {r.get("alert", r.get("name", "")): r for r in rules}
    return {}


def upsert_alert(definition, existing_by_name):
    name = definition["alert"]
    existing = existing_by_name.get(name)
    if existing:
        rule_id = existing.get("id", "")
        api_put(f"/api/v1/rules/{rule_id}", definition)
        return f"updated  {name!r}"
    else:
        api_post("/api/v1/rules", definition)
        return f"created  {name!r}"


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print(f"Target: {SIGNOZ_URL}")
    print(f"Provisioning {len(ALERTS)} pipeline health alert(s)\n")

    existing = fetch_existing()
    print(f"SigNoz currently has {len(existing)} alert rule(s)\n")

    for alert in ALERTS:
        status = upsert_alert(alert, existing)
        sev = alert["labels"].get("severity", "?")
        print(f"  ✓  [{sev}] {status}")

    print(f"\nDone.")
    print("\nNote: alerts fire but won't notify until you configure a notification")
    print("channel in SigNoz → Settings → Alert Channels and set preferredChannels.")


if __name__ == "__main__":
    main()
