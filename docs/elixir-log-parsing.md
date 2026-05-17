# Elixir / Phoenix Log Parsing

## Overview

A single HTTP request produces **multiple log lines**, all sharing the same `request_id`
in Logger metadata. Two lines come from `Plug.Logger`; the rest come from `Phoenix.Logger`
(Phoenix-only). A complete pipeline should parse all of them and correlate via `request_id`.

```
12:23:44.108 request_id=GLBZ1PeBLlwXONcAAAdx [info] GET /users/123                         ← Plug.Logger  (1) request start
12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info] Processing with MyAppWeb.UserController.show/2   ← Phoenix.Logger (3) router dispatch
12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info]   Parameters: %{"id" => "123"}
12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info]   Pipelines: [:browser]
12:23:44.184 request_id=GLBZ1PeBLlwXONcAAAdx [info] Sent 200 in 76ms                       ← Plug.Logger  (2) response
```

---

## Time Unit Rules (from `Plug.Logger` / `Phoenix.Logger` source — identical logic)

```
defp formatted_diff(diff) when diff > 1000, do: [diff |> div(1000) |> Integer.to_string(), "ms"]
defp formatted_diff(diff), do: [Integer.to_string(diff), "µs"]
```

- Duration is always measured in **microseconds** internally.
- `> 1000 µs` → divide by 1000, emit as `ms`.
- `≤ 1000 µs` → emit as `µs`.
- **No `s` (seconds) unit exists.** A 60 s request shows as `60000ms`.
- `µ` is Unicode **U+00B5** (MICRO SIGN). Config files must be UTF-8.

---

## Line-by-Line Patterns and Regexes

### 1 — Request Start (Plug.Logger)

```
12:23:44.108 request_id=GLBZ1PeBLlwXONcAAAdx [info] GET /users/123
```

```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<http_method>GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)\s+(?P<http_path>\S+)$
```

| Group | Example | OTel attribute |
|---|---|---|
| `request_id` | `GLBZ1PeBLlwXONcAAAdx` | `attributes["request_id"]` |
| `http_method` | `GET` | `attributes["http.request.method"]` |
| `http_path` | `/users/123` | `attributes["url.path"]` |

> **Note:** The path here is the raw path as received — it may contain path parameters like `/users/123`. Phoenix normalises this to a route template (`/users/:id`) in the router dispatch line below; prefer that for grouping metrics.

---

### 2 — Response (Plug.Logger)

```
12:23:44.184 request_id=GLBZ1PeBLlwXONcAAAdx [info] Sent 200 in 76ms
```

```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<connection_type>Sent|Chunked)\s+(?P<http_status>\d{3})\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)
```

| Group | Example | OTel attribute |
|---|---|---|
| `request_id` | `GLBZ1PeBLlwXONcAAAdx` | correlation key |
| `connection_type` | `Sent` / `Chunked` | `attributes["http.connection_type"]` |
| `http_status` | `200` | `attributes["http.response.status_code"]` |
| `duration` + `duration_unit` | `76` + `ms` | see duration conversion below |

**Duration → seconds** (OTel `http.server.request.duration` uses seconds):
- `ms` → `duration / 1_000`
- `µs` → `duration / 1_000_000`

---

### 3 — Router Dispatch (Phoenix.Logger only)

```
12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info] Processing with MyAppWeb.UserController.show/2
12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info]   Parameters: %{"id" => "123"}
12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info]   Pipelines: [:browser]
```

These are three separate log lines. Parse the first one; the Parameters and Pipelines lines
are continuation lines with fixed prefixes (they share the same `request_id`).

**Processing line:**
```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Processing with\s+(?P<controller>[A-Za-z0-9_.]+)\.(?P<action>[a-z_]+)/(?P<arity>\d)
```

**Parameters line** (raw Elixir map string — hard to parse reliably, log as-is):
```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Parameters:\s+(?P<params>.+)$
```

**Pipelines line:**
```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Pipelines:\s+(?P<pipelines>.+)$
```

| Group | Example | OTel attribute |
|---|---|---|
| `controller` | `MyAppWeb.UserController` | `attributes["phoenix.controller"]` |
| `action` | `show` | `attributes["phoenix.action"]` |
| `params` | `%{"id" => "123"}` | `attributes["phoenix.params"]` (string) |
| `pipelines` | `[:browser]` | `attributes["phoenix.pipelines"]` (string) |

> **Why controller/action matter for metrics:** The raw `http_path` from line 1 is per-request
> (e.g. `/users/123`, `/users/456`). Grouping by `controller.action` gives you stable cardinality
> for dashboards and SLOs without needing route-template normalisation.

---

### 4 — Error Rendered (Phoenix.Logger only)

Emitted when an exception is caught and converted to an HTTP error response.

```
12:23:44.110 request_id=GLBZ1PeBLlwXONcAAAdx [info] Converted error Elixir.Ecto.NoResultsError to 404 response
```

```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Converted\s+(?P<error_kind>error|throw|exit)\s+(?P<error_type>\S+)\s+to\s+(?P<error_status>\d{3})\s+response
```

| Group | Example | OTel attribute |
|---|---|---|
| `error_kind` | `error` | `attributes["exception.type"]` |
| `error_type` | `Elixir.Ecto.NoResultsError` | `attributes["exception.message"]` |
| `error_status` | `404` | `attributes["http.response.status_code"]` |

---

### 5 — WebSocket Connect (Phoenix.Logger only)

```
12:23:44.108 request_id=GLBZ1PeBLlwXONcAAAdx [info] CONNECTED TO MyAppWeb.UserSocket in 142µs
  Transport: :websocket
  Serializer: Phoenix.Socket.V2.JSONSerializer
  Parameters: %{"token" => "[FILTERED]"}
```

```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<ws_result>CONNECTED TO|REFUSED CONNECTION TO)\s+(?P<socket_module>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)
```

| Group | Notes |
|---|---|
| `ws_result` | `CONNECTED TO` or `REFUSED CONNECTION TO` |
| `socket_module` | e.g. `MyAppWeb.UserSocket` |
| `duration` + `duration_unit` | WebSocket handshake time |

---

### 6 — Channel Join (Phoenix.Logger only)

```
12:23:44.109 [info] JOINED room:lobby in 154µs
  Parameters: %{}
```

> Channel logs do **not** include `request_id` in metadata by default — they use a different
> process and Logger metadata context. Correlate via topic instead.

```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<join_result>JOINED|REFUSED JOIN)\s+(?P<topic>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)
```

---

### 7 — Channel Message Handled (Phoenix.Logger only)

```
12:23:44.112 [info] HANDLED new_msg INCOMING ON room:lobby (MyAppWeb.RoomChannel) in 2ms
  Parameters: %{"body" => "hello"}
```

```
^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+HANDLED\s+(?P<event>\S+)\s+INCOMING ON\s+(?P<topic>\S+)\s+\((?P<channel_module>[^)]+)\)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)
```

---

## Full OTel Collector Config (SigNoz)

```yaml
receivers:
  filelog:
    include: [/app/logs/*.log]
    operators:
      # ── 1. Request start ────────────────────────────────────────────────────
      - type: regex_parser
        id: parse_request_start
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<http_method>GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)\s+(?P<http_path>\S+)$'
        parse_to: attributes
        on_error: send  # pass non-matching lines to the next operator

      # ── 2. Response ─────────────────────────────────────────────────────────
      - type: regex_parser
        id: parse_response
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<connection_type>Sent|Chunked)\s+(?P<http_status>\d{3})\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)'
        parse_to: attributes
        on_error: send

      # ── 3. Router dispatch ───────────────────────────────────────────────────
      - type: regex_parser
        id: parse_router_dispatch
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Processing with\s+(?P<controller>[A-Za-z0-9_.]+)\.(?P<action>[a-z_]+)/(?P<arity>\d)'
        parse_to: attributes
        on_error: send

      # ── 4. Error rendered ────────────────────────────────────────────────────
      - type: regex_parser
        id: parse_error_rendered
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Converted\s+(?P<error_kind>error|throw|exit)\s+(?P<error_type>\S+)\s+to\s+(?P<error_status>\d{3})\s+response'
        parse_to: attributes
        on_error: send

      # ── 5. WebSocket connect ─────────────────────────────────────────────────
      - type: regex_parser
        id: parse_ws_connect
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<ws_result>CONNECTED TO|REFUSED CONNECTION TO)\s+(?P<socket_module>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)'
        parse_to: attributes
        on_error: send

      # ── 6. Channel join ──────────────────────────────────────────────────────
      - type: regex_parser
        id: parse_channel_join
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<join_result>JOINED|REFUSED JOIN)\s+(?P<topic>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)'
        parse_to: attributes
        on_error: send

      # ── 7. Channel message handled ───────────────────────────────────────────
      - type: regex_parser
        id: parse_channel_msg
        regex: '^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+HANDLED\s+(?P<event>\S+)\s+INCOMING ON\s+(?P<topic>\S+)\s+\((?P<channel_module>[^)]+)\)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)'
        parse_to: attributes
        on_error: send

      # ── Severity normalisation ───────────────────────────────────────────────
      - type: severity_parser
        parse_from: attributes.log_level
        on_error: send

      # ── Duration → seconds ───────────────────────────────────────────────────
      # (where duration was captured — non-matching lines will have no duration attr)
      - type: add
        id: duration_to_seconds
        if: 'attributes["duration"] != nil'
        field: attributes["duration_seconds"]
        value: 'EXPR(attributes["duration_unit"] == "ms" ? float(attributes["duration"]) / 1000.0 : float(attributes["duration"]) / 1000000.0)'
```

> **Note:** OTel Collector runs operators sequentially. Each `on_error: send` means "if this
> regex doesn't match, pass the log through unchanged to the next operator." Only one regex
> will match any given line, so the others effectively become no-ops for that line.

---

## What Each Line Contributes to SigNoz Dashboards

| Line | Key fields | Useful for |
|---|---|---|
| Request start | `http_method`, `http_path` | Request volume by method; path-level breakdown |
| Response | `http_status`, `duration_seconds` | Latency histogram, error rate, p99 SLO |
| Router dispatch | `controller`, `action` | Latency/error rate grouped by endpoint (stable cardinality) |
| Error rendered | `error_type`, `error_status` | Exception frequency, top error types |
| WS connect | `ws_result`, `socket_module`, `duration_seconds` | WebSocket connection success rate, handshake latency |
| Channel join | `join_result`, `topic` | Channel join success rate per topic |
| Channel message | `event`, `channel_module`, `duration_seconds` | Channel message handling latency per event type |

---

## Testing

```python
import re

patterns = {
    "request_start":  r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<http_method>GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)\s+(?P<http_path>\S+)$',
    "response":       r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<connection_type>Sent|Chunked)\s+(?P<http_status>\d{3})\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)',
    "router_dispatch":r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Processing with\s+(?P<controller>[A-Za-z0-9_.]+)\.(?P<action>[a-z_]+)/(?P<arity>\d)',
    "error_rendered": r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+Converted\s+(?P<error_kind>error|throw|exit)\s+(?P<error_type>\S+)\s+to\s+(?P<error_status>\d{3})\s+response',
    "ws_connect":     r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+request_id=(?P<request_id>\S+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<ws_result>CONNECTED TO|REFUSED CONNECTION TO)\s+(?P<socket_module>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)',
    "channel_join":   r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+(?P<join_result>JOINED|REFUSED JOIN)\s+(?P<topic>\S+)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)',
    "channel_msg":    r'^(?P<timestamp>\d{2}:\d{2}:\d{2}\.\d+)\s+\[(?P<log_level>[^\]]+)\]\s+HANDLED\s+(?P<event>\S+)\s+INCOMING ON\s+(?P<topic>\S+)\s+\((?P<channel_module>[^)]+)\)\s+in\s+(?P<duration>\d+)(?P<duration_unit>µs|ms)',
}

lines = [
    ("request_start",  "12:23:44.108 request_id=GLBZ1PeBLlwXONcAAAdx [info] GET /users/123"),
    ("response",       "12:23:44.184 request_id=GLBZ1PeBLlwXONcAAAdx [info] Sent 200 in 76ms"),
    ("response",       "12:23:44.184 request_id=GLBZ1PeBLlwXONcAAAdx [info] Sent 200 in 842µs"),
    ("router_dispatch","12:23:44.109 request_id=GLBZ1PeBLlwXONcAAAdx [info] Processing with MyAppWeb.UserController.show/2"),
    ("error_rendered", "12:23:44.110 request_id=GLBZ1PeBLlwXONcAAAdx [info] Converted error Elixir.Ecto.NoResultsError to 404 response"),
    ("ws_connect",     "12:23:44.108 request_id=GLBZ1PeBLlwXONcAAAdx [info] CONNECTED TO MyAppWeb.UserSocket in 142µs"),
    ("channel_join",   "12:23:44.109 [info] JOINED room:lobby in 154µs"),
    ("channel_msg",    "12:23:44.112 [info] HANDLED new_msg INCOMING ON room:lobby (MyAppWeb.RoomChannel) in 2ms"),
]

for expected_pattern, line in lines:
    m = re.match(patterns[expected_pattern], line)
    status = "OK" if m else "FAIL"
    print(f"[{status}] {expected_pattern}: {m.groupdict() if m else line}")
```
