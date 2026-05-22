#!/usr/bin/env bash
# keep_alive.sh — Sprite heartbeat that prevents the VM from suspending.
#
# The Sprite Tasks API keeps the current run active as long as at least one
# task has a future expires_at.  This loop upserts "signoz-keep-alive" with a
# 5-minute TTL every 55 seconds — four missed heartbeats of margin before the
# hold would expire on its own.
#
# Why this matters for the SigNoz stack:
#   When the Sprite suspends (even to "warm"), in-flight TCP connections to
#   ClickHouse drop.  The OTel collector's send queues then flood with i/o
#   timeouts, fill up, and start permanently dropping telemetry.  Keeping the
#   Sprite alive prevents that entire cascade.
#
# Registered as a sprite-env service by: install.sh setup-keep-alive
# The service auto-starts on boot and survives both warm and cold wakes.

set -euo pipefail

TASK_NAME="signoz-keep-alive"

while true; do
  curl -sf \
    --unix-socket /.sprite/api.sock \
    -H "Content-Type: application/json" \
    -X PUT "http://sprite/v1/tasks/${TASK_NAME}" \
    -d '{"expire":"5m"}' \
    >/dev/null \
  || echo "[keep-alive] $(date -u '+%Y-%m-%dT%H:%M:%SZ') task upsert failed" >&2
  sleep 55
done
