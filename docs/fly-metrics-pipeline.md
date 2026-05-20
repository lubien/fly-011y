# Fly.io Metrics Pipeline

This document describes every transformation applied to Fly.io metrics between
the Prometheus scrape and their final storage in ClickHouse (SigNoz).

## Architecture overview

```
Fly.io VMs
  └── Prometheus endpoint  (https://api.fly.io/prometheus/<org>/federate)
        │  scrape every 60 s
        ▼
signoz-otel-collector  (signoz/signoz-otel-collector)
  └── metrics/prometheus   raw pass-through + host.name annotation → ClickHouse

otelcol-contrib sidecar  (otel/opentelemetry-collector-contrib)
  └── metrics/host   Sprite host metrics only (unrelated to Fly.io VMs)
```

---

## Label rename: `instance` → `exported_instance`

Before any transformation, the Prometheus receiver renames every Fly.io metric
label `instance` to `exported_instance`. This happens automatically because
Prometheus reserves the `instance` label for the scrape-target address; any
incoming label of that name is prefixed with `exported_` to avoid a collision.

All pipelines therefore refer to the machine ID as `exported_instance`, not
`instance`.

---

## Pipeline — `metrics/prometheus`

**Purpose:** Store every scraped Fly.io metric in ClickHouse and annotate
`fly_instance_*` series with `host.name = exported_instance` so that the Fly.io
machine ID is available as both a resource attribute and a data-point attribute.

**Processors (in order):**

### `groupbyattrs/fly-promote-to-resource`
Moves `exported_instance`, `app`, and `region` from data-point labels into the
OTel resource scope.  For non-instance metrics (`fly_edge_*`, `fly_app_*`,
etc.) that lack these labels this is a no-op.

### `resource/fly-set-hostname`
Sets `host.name = exported_instance` as a resource attribute.  For non-instance
metrics where `exported_instance` was not promoted, this is a no-op.

### `transform/fly-copy-hostname-to-dp`
Copies `host.name`, `exported_instance`, `app`, and `region` back from resource
attributes to data-point attributes so the SigNoz Query Builder can discover
and group by them.

### `batch`
Standard batching before writing to ClickHouse.

**Result:** All `fly_instance_*`, `fly_edge_*`, `fly_app_*`, `fly_volume_*`,
`pg_*`, `otelcol_*`, and `clickhouse_*` metrics land in ClickHouse with their
original labels.  `fly_instance_*` series additionally carry
`host.name = exported_instance` as both a resource and data-point attribute.
These are the metrics used by every dashboard panel.

---

## Summary — what lands in ClickHouse

| Metric | Type | Used by |
|---|---|---|
| `fly_instance_*` (all raw) | as scraped | PromQL dashboards |
| All other scraped metrics | as scraped | PromQL dashboards |
