#!/bin/bash
set -euo pipefail

template() { eval $'cat <<_EOF\n'"$(awk '1;END{print"_EOF"}')"; }
sponge() { cat <<<"$(cat)" >"$1"; }
filter() { for i in "$@"; do template <"$i" | sponge "$i" || rm "$i"; done; }
filter /etc/vector/sinks/*.toml 2>&-
echo 'Configured sinks:'
find /etc/vector/sinks -type f -exec basename -s '.toml' {} \;

# Start Vector in the background so we can watch it.
vector -c /etc/vector/vector.toml -C /etc/vector/sinks &
VECTOR_PID=$!

# ── Watchdog ─────────────────────────────────────────────────────────────────
# If the signoz sink accumulates new errors but makes no delivery progress for
# 30 consecutive minutes, kill Vector and exit 1 so Fly restarts the machine.
# The disk buffer survives the restart and drains once the endpoint recovers.
#
# Uses Vector's Prometheus endpoint (port 9598) — same port exposed as [[metrics]].
# Metric names: component_sent_events_total / component_errors_total (component_id="signoz")
(
  readonly METRICS="http://localhost:9598/metrics"
  readonly CHECK_INTERVAL=300   # seconds between checks (5 min)
  readonly MAX_STALE=1          # stale cycles before exit  (1 × 5 min = 5 min)

  # Give Vector time to start up and establish the NATS connection.
  sleep 120

  last_sent=0
  last_errors=0
  stale_cycles=0

  while kill -0 "${VECTOR_PID}" 2>/dev/null; do
    sleep "${CHECK_INTERVAL}"

    # Read counters from Prometheus endpoint; fall back to last values on failure.
    sent=$(
      curl -sf --max-time 5 "${METRICS}" 2>/dev/null \
        | grep -E '^[a-z].*component_sent_events' \
        | grep '"signoz"' \
        | awk '{sum += $NF} END {printf "%.0f", sum+0}' \
      || echo "${last_sent}"
    )
    errors=$(
      curl -sf --max-time 5 "${METRICS}" 2>/dev/null \
        | grep -E '^[a-z].*component_errors' \
        | grep '"signoz"' \
        | awk '{sum += $NF} END {printf "%.0f", sum+0}' \
      || echo "${last_errors}"
    )

    delta_sent=$(( sent   - last_sent   ))
    delta_errors=$(( errors - last_errors ))

    if [ "${delta_errors}" -gt 0 ] && [ "${delta_sent}" -eq 0 ]; then
      stale_cycles=$(( stale_cycles + 1 ))
      echo "signoz sink: ${delta_errors} new error(s), 0 delivered — stale for $((stale_cycles * CHECK_INTERVAL / 60))min"

      if [ "${stale_cycles}" -ge "${MAX_STALE}" ]; then
        echo "signoz sink stalled 30+ minutes with persistent errors — exiting for Fly restart"
        kill "${VECTOR_PID}" 2>/dev/null || true
        exit 1
      fi
    else
      if [ "${stale_cycles}" -gt 0 ]; then
        echo "signoz sink recovered (sent ${delta_sent} events) — resetting stale counter"
      fi
      stale_cycles=0
    fi

    last_sent="${sent}"
    last_errors="${errors}"
  done
) &

# Wait for Vector; propagate its exit code so Fly sees a failure when Vector crashes.
wait "${VECTOR_PID}"
