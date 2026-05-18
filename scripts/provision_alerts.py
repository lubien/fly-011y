#!/usr/bin/env python3
"""
Provisions all Fly.io observability alert rules into SigNoz.

Covers every alert from docs/alerts-proposal.md (sections 1–7) plus the four
critical pipeline-health alerts. Section 8 (anomaly) is intentionally omitted —
those require ≥7 days of history before they produce reliable signals.

All alerts automatically use every configured notification channel so you
never have to think about it. Add or remove channels in SigNoz →
Settings → Alert Channels and re-run this script to sync.

Usage:
  install.sh provision-alerts

Manual:
  SIGNOZ_URL=http://localhost:3301 python3 scripts/provision_alerts.py
  SIGNOZ_TOKEN=<jwt> python3 scripts/provision_alerts.py

Idempotent: re-running updates existing rules matched by name and creates
any that are missing.
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
    result = _json(
        "POST",
        "/api/v2/sessions/email_password",
        {"email": email, "password": password, "orgId": orgs[0]["id"]},
    )
    TOKEN = (result.get("data") or result).get("accessToken", "")
    if not TOKEN:
        print(f"Login returned no accessToken: {result}", file=sys.stderr)
        sys.exit(1)

HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def api_get(path):
    return _json("GET", path, headers=HEADERS)


def api_post(path, payload):
    return _json("POST", path, payload, headers=HEADERS)


def api_put(path, payload):
    return _json("PUT", path, payload, headers=HEADERS)


# ── Notification channels ─────────────────────────────────────────────────────
def fetch_channels():
    """Return names of ALL configured notification channels."""
    resp = api_get("/api/v1/channels")
    return [c["name"] for c in (resp.get("data") or []) if c.get("name")]


# ── Alert builders ────────────────────────────────────────────────────────────
def _rule(name, desc, severity, alert_type, rule_type, window, condition):
    return {
        "alert": name,
        "description": desc,
        "alertType": alert_type,
        "ruleType": rule_type,
        "version": "v5",
        "evalWindow": window,
        "frequency": "1m0s",
        "condition": condition,
        "labels": {"severity": severity},
        "annotations": {"description": desc, "summary": name},
        "preferredChannels": [],  # injected at runtime from all configured channels
        "disabled": False,
    }


def pa(name, desc, severity, window, query, op, target, match="at_least_once"):
    """PromQL-based metric alert."""
    return _rule(
        name,
        desc,
        severity,
        "METRIC_BASED_ALERT",
        "promql_rule",
        window,
        {
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
            "matchType": match,
            "selectedQueryName": "A",
            "targetUnit": "",
            "requireMinPoints": False,
        },
    )


def la(name, desc, severity, window, filter_expr, threshold, match="at_least_once"):
    """Log-count-based alert. Fires when count of matching logs > threshold."""
    return _rule(
        name,
        desc,
        severity,
        "LOGS_BASED_ALERT",
        "threshold_rule",
        window,
        {
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
                            "stepInterval": "60s",
                            "filter": {"expression": filter_expr},
                            "aggregations": [
                                {"expression": "count()", "alias": "count"}
                            ],
                            "groupBy": [],
                        },
                    }
                ],
            },
            "op": "above",
            "target": threshold,
            "matchType": match,
            "selectedQueryName": "A",
            "targetUnit": "",
            "requireMinPoints": False,
        },
    )


# ── Alert catalogue ───────────────────────────────────────────────────────────
# NOTE: fly_instance_* metrics store the VM ID as `exported_instance` (not
# `instance`) because the Prometheus receiver renames the `instance` label to
# avoid collision with the scrape target address. fly_edge_* and fly_volume_*
# are not affected — they don't have an `instance` label.

ALERTS = [
    # ══════════════════════════════════════════════════════════════════════════
    # Pipeline health — the plumbing that delivers all other signals
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[P0] Log Pipeline Silent",
        "The otel-collector has received 0 log records for 15 minutes. "
        "Log shippers (Vector on Fly.io) are likely down or unreachable. "
        "Check: fly status --app <log-shipper-app>",
        "critical",
        "15m0s",
        "sum(rate(otelcol_receiver_accepted_log_records[5m]))",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    pa(
        "[P0] Metrics Pipeline Silent",
        "The otel-collector has received 0 metric points for 10 minutes. "
        "The Prometheus federation scrape against api.fly.io may be failing. "
        "Check: docker logs signoz-otel-collector | grep prometheus",
        "critical",
        "10m0s",
        "sum(rate(otelcol_receiver_accepted_metric_points[5m]))",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    pa(
        "[P0] Collector Dropping Telemetry",
        "The otel-collector export queues are full — telemetry is being permanently lost. "
        "ClickHouse may not be accepting writes fast enough. "
        "Check: docker logs signoz-otel-collector | grep 'Dropping data'",
        "critical",
        "5m0s",
        "sum(increase(otelcol_exporter_enqueue_failed_log_records[5m])) + "
        "sum(increase(otelcol_exporter_enqueue_failed_metric_points[5m])) + "
        "sum(increase(otelcol_exporter_enqueue_failed_spans[5m]))",
        "above",
        0,
        "at_least_once",
    ),
    pa(
        "[P1] Collector ClickHouse Write Errors",
        "The otel-collector has sustained ClickHouse write failures for 10 minutes. "
        "ClickHouse may be overloaded (too many parts from a backlog flush). "
        "Telemetry is being retried but may eventually drop if unresolved.",
        "warning",
        "10m0s",
        "sum(rate(otelcol_exporter_send_failed_log_records[5m])) + "
        "sum(rate(otelcol_exporter_send_failed_metric_points[5m])) + "
        "sum(rate(otelcol_exporter_send_failed_spans[5m]))",
        "above",
        0,
        "all_the_times",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 1. Availability
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[1.1] All Machines Down",
        "All Fly.io VMs for an app have stopped reporting fly_instance_up. "
        "The application is likely completely unreachable.",
        "critical",
        "5m0s",
        "sum by (app) (fly_instance_up)",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    pa(
        "[1.2] Instance Disappeared",
        "A specific Fly.io VM has stopped reporting fly_instance_up for 5 minutes. "
        "It may be OOM-killed without restarting or stuck in a boot loop.",
        "critical",
        "5m0s",
        "sum by (app, exported_instance) (fly_instance_up)",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    pa(
        "[1.3] App Has Zero Running Instances",
        "All instances for an app are reporting fly_instance_up=0. "
        "The app may be stopped or crashing on start.",
        "critical",
        "5m0s",
        "sum by (app) (fly_instance_up == bool 1)",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    pa(
        "[1.4] No HTTP Traffic Received",
        "The Fly edge is receiving no requests for 15 minutes. "
        "Machines may be up but unreachable, or a routing / health-check failure occurred.",
        "warning",
        "15m0s",
        "sum by (app) (rate(fly_edge_http_responses_count[5m]))",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 2. Error Rate / SLO
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[2.1] HTTP 5xx Error Rate — Critical",
        "More than 5% of requests are returning 5xx errors — SLO breach. "
        "User-facing impact is ongoing.",
        "critical",
        "5m0s",
        'sum by (app) (rate(fly_edge_http_responses_count{status=~"5.."}[5m])) / '
        "sum by (app) (rate(fly_edge_http_responses_count[5m]))",
        "above",
        0.05,
        "on_average",
    ),
    pa(
        "[2.2] HTTP 5xx Error Rate — Warning",
        "Between 1–5% of requests are returning 5xx errors. "
        "May indicate a partial failure — investigate before it escalates.",
        "warning",
        "10m0s",
        'sum by (app) (rate(fly_edge_http_responses_count{status=~"5.."}[5m])) / '
        "sum by (app) (rate(fly_edge_http_responses_count[5m]))",
        "above",
        0.01,
        "on_average",
    ),
    pa(
        "[2.3] HTTP 4xx Error Rate Spike",
        "More than 20% of requests are returning 4xx responses. "
        "May indicate a bad deploy, broken API contract, or credential regression.",
        "warning",
        "10m0s",
        'sum by (app) (rate(fly_edge_http_responses_count{status=~"4.."}[5m])) / '
        "sum by (app) (rate(fly_edge_http_responses_count[5m]))",
        "above",
        0.20,
        "on_average",
    ),
    pa(
        "[2.4] HTTP Success Rate Below SLO",
        "HTTP success rate has dropped below the 99.9% SLO target.",
        "critical",
        "5m0s",
        'sum by (app) (rate(fly_edge_http_responses_count{status=~"2.."}[5m])) / '
        "sum by (app) (rate(fly_edge_http_responses_count[5m]))",
        "below",
        0.999,
        "on_average",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 3. Latency SLO
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[3.1] P99 Latency — Critical",
        "The 99th percentile response time exceeds 2.5 seconds. "
        "Often caused by GC pauses, database lock contention, or a cold-starting machine.",
        "critical",
        "5m0s",
        "histogram_quantile(0.99, sum by (app, le) (rate(fly_edge_http_response_time_seconds_bucket[5m])))",
        "above",
        2.5,
        "on_average",
    ),
    pa(
        "[3.2] P99 Latency — Warning",
        "The 99th percentile response time has been above 1 second for 10 minutes.",
        "warning",
        "10m0s",
        "histogram_quantile(0.99, sum by (app, le) (rate(fly_edge_http_response_time_seconds_bucket[5m])))",
        "above",
        1.0,
        "on_average",
    ),
    pa(
        "[3.3] P50 Latency Elevated",
        "Median (P50) response time has been above 500ms for 15 minutes. "
        "Unlike P99 spikes this indicates a widespread, systemic slowdown.",
        "warning",
        "15m0s",
        "histogram_quantile(0.50, sum by (app, le) (rate(fly_edge_http_response_time_seconds_bucket[5m])))",
        "above",
        0.5,
        "on_average",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 4. Machine Crashes and OOM
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[4.1] OOM Kill Detected",
        "A Fly.io VM was killed by the Linux OOM killer. "
        "The process had no graceful shutdown. Investigate memory limit and potential leaks.",
        "critical",
        "5m0s",
        "sum by (app, exported_instance) (increase(fly_instance_exit_oom[5m]))",
        "above",
        0,
        "at_least_once",
    ),
    pa(
        "[4.2] Abnormal Exit Code",
        "A Fly.io VM exited with a non-zero exit code (process crash, not graceful stop). "
        "Frequent abnormal exits drain capacity and may trigger Fly restart backoff.",
        "warning",
        "5m0s",
        "sum by (app, exported_instance) (fly_instance_exit_code)",
        "above",
        0,
        "at_least_once",
    ),
    pa(
        "[4.3] Repeated OOM Kills",
        "An app has been OOM-killed 3 or more times in 30 minutes — likely a crash loop. "
        "Consider increasing the memory limit or investigating a memory leak.",
        "warning",
        "30m0s",
        "sum by (app) (increase(fly_instance_exit_oom[30m]))",
        "above_or_equal",
        3,
        "on_average",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 5. Resource Saturation
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[5.1] CPU Throttling — Critical",
        "A Fly.io VM is CPU-throttled more than 80% of the time. "
        "The machine is CPU-starved — latency spikes and timeouts will follow.",
        "critical",
        "10m0s",
        "sum by (app, exported_instance) (rate(fly_instance_cpu_throttle[5m]))",
        "above",
        0.8,
        "on_average",
    ),
    pa(
        "[5.2] CPU Throttling — Warning",
        "A Fly.io VM is CPU-throttled more than 30% of the time for 15 minutes. "
        "Performance is degrading — consider scaling before it becomes critical.",
        "warning",
        "15m0s",
        "sum by (app, exported_instance) (rate(fly_instance_cpu_throttle[5m]))",
        "above",
        0.3,
        "on_average",
    ),
    pa(
        "[5.3] CPU Burst Balance Depleted",
        "A shared-CPU Fly.io VM has exhausted its burst credits. "
        "It is now running at reduced baseline CPU — latency will be elevated.",
        "warning",
        "10m0s",
        "sum by (app, exported_instance) (fly_instance_cpu_balance)",
        "below_or_equal",
        0,
        "all_the_times",
    ),
    pa(
        "[5.4] Memory Available — Critical",
        "Less than 5% memory available — OOM kill is imminent. "
        "Consider restarting the instance or scaling memory immediately.",
        "critical",
        "5m0s",
        "sum by (app, exported_instance) (fly_instance_memory_mem_available) / "
        "sum by (app, exported_instance) (fly_instance_memory_mem_total)",
        "below",
        0.05,
        "all_the_times",
    ),
    pa(
        "[5.5] Memory Available — Warning",
        "Less than 15% memory available — system is under pressure. "
        "Investigate the cause before the OOM threshold is breached.",
        "warning",
        "10m0s",
        "sum by (app, exported_instance) (fly_instance_memory_mem_available) / "
        "sum by (app, exported_instance) (fly_instance_memory_mem_total)",
        "below",
        0.15,
        "on_average",
    ),
    pa(
        "[5.6] Disk Volume Usage — Critical",
        "A Fly volume is more than 90% full. Writes may fail imminently. "
        "Run: fly volumes list --app <app>",
        "critical",
        "5m0s",
        "fly_volume_used_pct",
        "above",
        90,
        "all_the_times",
    ),
    pa(
        "[5.7] Disk Volume Usage — Warning",
        "A Fly volume is more than 75% full. Plan a volume extension soon.",
        "warning",
        "15m0s",
        "fly_volume_used_pct",
        "above",
        75,
        "on_average",
    ),
    pa(
        "[5.8] Filesystem Blocks — Critical",
        "The root filesystem has less than 5% blocks free. "
        "Log writes and temp file creation will fail. Check for large log files.",
        "critical",
        "5m0s",
        "sum by (app, exported_instance) (fly_instance_filesystem_blocks_avail) / "
        "sum by (app, exported_instance) (fly_instance_filesystem_blocks)",
        "below",
        0.05,
        "all_the_times",
    ),
    pa(
        "[5.9] File Descriptor Exhaustion",
        "A VM is using more than 80% of its max file descriptors. "
        "A connection or file handle leak may be in progress.",
        "warning",
        "10m0s",
        "sum by (app, exported_instance) (fly_instance_filefd_allocated) / "
        "sum by (app, exported_instance) (fly_instance_filefd_maximum)",
        "above",
        0.80,
        "on_average",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 6. Fly Postgres
    # ══════════════════════════════════════════════════════════════════════════
    pa(
        "[6.1] Postgres Replication Lag — Critical",
        "A Postgres replica is more than 30 seconds behind the primary. "
        "A failover now would lose committed transactions.",
        "critical",
        "5m0s",
        "pg_replication_lag",
        "above",
        30,
        "on_average",
    ),
    pa(
        "[6.2] Postgres Replication Lag — Warning",
        "A Postgres replica is more than 5 seconds behind the primary.",
        "warning",
        "10m0s",
        "pg_replication_lag",
        "above",
        5,
        "on_average",
    ),
    pa(
        "[6.3] Postgres Deadlocks",
        "Deadlocks are occurring in a Postgres database. "
        "Each deadlock aborts a transaction. Investigate transaction ordering in application code.",
        "warning",
        "10m0s",
        "sum by (app, datname) (rate(pg_stat_database_deadlocks[5m]))",
        "above",
        0,
        "on_average",
    ),
    pa(
        "[6.4] Postgres Rollback Rate High",
        "More than 5% of Postgres transactions are rolling back. "
        "Indicates application errors, constraint violations, or serialization failures.",
        "warning",
        "15m0s",
        "sum by (app, datname) (rate(pg_stat_database_xact_rollback[5m])) / "
        "(sum by (app, datname) (rate(pg_stat_database_xact_commit[5m])) + "
        "sum by (app, datname) (rate(pg_stat_database_xact_rollback[5m])))",
        "above",
        0.05,
        "on_average",
    ),
    pa(
        "[6.5] Postgres Long-Running Transaction",
        "A Postgres transaction has been open for more than 60 seconds. "
        "Long transactions hold locks, block autovacuum, and cause table bloat.",
        "critical",
        "5m0s",
        "pg_stat_activity_max_tx_duration",
        "above",
        60,
        "all_the_times",
    ),
    pa(
        "[6.6] Postgres Cache Hit Rate Low",
        "Postgres buffer cache hit rate is below 90% — queries are reading from disk. "
        "May indicate shared_buffers is too small or a new full-scan query.",
        "warning",
        "30m0s",
        "sum by (app, datname) (rate(pg_stat_database_blks_hit[5m])) / "
        "(sum by (app, datname) (rate(pg_stat_database_blks_hit[5m])) + "
        "sum by (app, datname) (rate(pg_stat_database_blks_read[5m])))",
        "below",
        0.90,
        "on_average",
    ),
    pa(
        "[6.7] Postgres WAL Archiver Failures",
        "WAL archiving is failing — PITR backups may be silently broken. "
        "Check: SELECT * FROM pg_stat_archiver;",
        "warning",
        "10m0s",
        "sum by (app) (rate(pg_stat_archiver_failed_count[5m]))",
        "above",
        0,
        "on_average",
    ),
    # ══════════════════════════════════════════════════════════════════════════
    # 7. Log-Based Alerts (Fly proxy error codes + application errors)
    # ══════════════════════════════════════════════════════════════════════════
    la(
        "[7.1] Proxy: No Healthy Machines (PR01)",
        "The Fly proxy logged PR01 — no healthy machines available for routing. "
        "Users are receiving 502/503. Check: fly status --app <app>",
        "critical",
        "5m0s",
        "body contains 'PR01'",
        0,
        "at_least_once",
    ),
    la(
        "[7.2] Proxy: Connection Timeout Spike (PC05)",
        "The Fly proxy logged PC05 connection timeouts — machines are alive but not responding. "
        "Typically caused by an overloaded machine or a blocked event loop.",
        "warning",
        "10m0s",
        "body contains 'PC05'",
        5,
        "in_total",
    ),
    la(
        "[7.3] Proxy: Machine Wake Failures (PM02/PM03)",
        "Scale-to-zero cold starts are failing (PM02/PM03). "
        "Users are receiving errors instead of a slow but successful wake-up.",
        "warning",
        "10m0s",
        "body contains 'PM02' OR body contains 'PM03'",
        3,
        "in_total",
    ),
    la(
        "[7.4] Proxy: Concurrency Overload (PL01/PL02)",
        "The Fly proxy hit machine concurrency limits (PL01/PL02). "
        "The app is receiving more connections than configured limits allow.",
        "warning",
        "10m0s",
        "body contains 'PL01' OR body contains 'PL02'",
        5,
        "in_total",
    ),
    la(
        "[7.5] Application Error Log Spike",
        "An app emitted more than 50 ERROR-level log lines in 5 minutes. "
        "Often the first signal of a new bug before HTTP metrics move.",
        "warning",
        "5m0s",
        "severity_text = 'ERROR'",
        50,
        "in_total",
    ),
    la(
        "[7.6] Application Error Log — Sustained High Rate",
        "An app has been emitting a high volume of ERROR logs for 15 minutes — "
        "the failure has not self-healed. Escalate and investigate.",
        "critical",
        "15m0s",
        "severity_text = 'ERROR'",
        200,
        "in_total",
    ),
]


# ── Upsert logic ──────────────────────────────────────────────────────────────
def fetch_existing():
    resp = api_get("/api/v1/rules")
    rules = (resp.get("data") or {}).get("rules") or []
    return {r.get("alert", ""): r for r in rules if isinstance(r, dict)}


def upsert_alert(definition, existing_by_name):
    name = definition["alert"]
    existing = existing_by_name.get(name)
    if existing:
        rule_id = existing.get("id", "")
        api_put(f"/api/v1/rules/{rule_id}", definition)
        return "updated"
    else:
        api_post("/api/v1/rules", definition)
        return "created"


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print(f"Target: {SIGNOZ_URL}")
    print(f"Provisioning {len(ALERTS)} alert rule(s)\n")

    # Fetch all notification channels once.
    # Every alert is sent to ALL configured channels automatically —
    # add/remove channels in SigNoz and re-run to sync.
    channels = fetch_channels()
    if not channels:
        print(
            "ERROR: no notification channels found.\n"
            "Create one in SigNoz → Settings → Alert Channels, then re-run.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"Sending to all {len(channels)} channel(s): {', '.join(channels)}\n")

    # Inject all channels into every alert.
    alerts = [{**a, "preferredChannels": channels} for a in ALERTS]

    existing = fetch_existing()
    print(f"SigNoz currently has {len(existing)} rule(s)\n")

    created = updated = 0
    for alert in alerts:
        status = upsert_alert(alert, existing)
        sev = alert["labels"].get("severity", "?")
        icon = "🔴" if sev == "critical" else "🟡"
        print(f"  {icon} {status:7s}  {alert['alert']}")
        if status == "created":
            created += 1
        else:
            updated += 1

    print(f"\nDone. {created} created, {updated} updated.")


if __name__ == "__main__":
    main()
