# OpenTelemetry Collector

pg_logtap emits newline-delimited JSON (NDJSON), not OTLP. OpenTelemetry
Collector Contrib can receive it through the generic HTTP `webhook_event`
receiver or the newline-framed `tcp_log` receiver, transform each object into
an OpenTelemetry log record, and forward it through an OTLP exporter.

The configurations below were validated with pg_logtap 0.5.2 and:

```text
otel/opentelemetry-collector-contrib:0.161.0
sha256:fd328de2552466ad78385e1b1289c3f2402b1c45f265b252aab1955b42845ac1
```

Pin the Collector version: `webhook_event` is Beta and `tcp_log` is Alpha.
Both are Contrib components and are not available together in the core
`otel/opentelemetry-collector` image.

## HTTP: `webhook_event` (recommended)

HTTP preserves pg_logtap's batch acknowledgement: any 2xx response marks the
batch delivered. A failed request follows the normal RAM backlog / fallback
queue path. Request-body gzip is supported by Collector's HTTP server.

PostgreSQL configuration:

```ini
pg_logtap.export_url = 'http://otel-collector:8088/pg-logtap'
pg_logtap.export_gzip = on
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

Collector configuration:

```yaml
receivers:
  webhook_event/pg_logtap:
    endpoint: 0.0.0.0:8088
    path: /pg-logtap
    split_logs_at_json_boundary: true
    # The receiver default is 100 KiB. pg_logtap targets 4 MiB per batch but
    # admits the event that crosses the target; a maximally escaped wide event
    # can take the request above 10 MiB.
    max_request_body_size: 16777216

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128

  transform/pg_logtap:
    error_mode: propagate
    log_statements:
      - merge_maps(log.attributes, ParseJSON(log.body), "upsert") where IsString(log.body)
      # ParseJSON represents JSON numbers as float64. Keep the dedup key as an
      # OTLP integer (the pg_logtap seq value is also JSON/JS-safe).
      - set(log.attributes["seq"], Int(log.attributes["seq"])) where log.attributes["seq"] != nil
      - set(log.time, Time(log.attributes["timestamp"], "%Y-%m-%dT%H:%M:%S.%f%z")) where log.attributes["timestamp"] != nil
      - set(log.severity_text, log.attributes["level"]) where log.attributes["level"] != nil
      - set(log.severity_number, SEVERITY_NUMBER_DEBUG) where IsString(log.attributes["level"]) and IsMatch(log.attributes["level"], "^DEBUG")
      - set(log.severity_number, SEVERITY_NUMBER_INFO) where log.attributes["level"] == "LOG" or log.attributes["level"] == "INFO"
      - set(log.severity_number, SEVERITY_NUMBER_WARN) where log.attributes["level"] == "NOTICE" or log.attributes["level"] == "WARNING"
      - set(log.severity_number, SEVERITY_NUMBER_ERROR) where log.attributes["level"] == "ERROR"
      - set(log.severity_number, SEVERITY_NUMBER_FATAL) where log.attributes["level"] == "FATAL" or log.attributes["level"] == "PANIC"
      - set(resource.attributes["service.name"], "postgresql")
      - set(resource.attributes["host.name"], log.attributes["host"]) where log.attributes["host"] != nil
      - set(resource.attributes["service.namespace"], log.attributes["cluster"]) where log.attributes["cluster"] != nil
      - set(log.body, log.attributes["message"]) where log.attributes["message"] != nil

  batch: {}

exporters:
  otlp:
    endpoint: observability-backend:4317
    tls:
      # Use certificate verification instead for an untrusted network.
      insecure: true

service:
  pipelines:
    logs/pg_logtap:
      receivers: [webhook_event/pg_logtap]
      processors: [memory_limiter, transform/pg_logtap, batch]
      exporters: [otlp]
```

`split_logs_at_newline: true` also recognizes pg_logtap NDJSON, but Collector
0.161.0 implements it as a literal newline split. Every pg_logtap batch ends
with a newline, so that mode creates one extra empty log record per request.
JSON-boundary splitting ignores the trailing whitespace and emits exactly one
record per pg_logtap object. pg_logtap's serializer always produces valid JSON;
invalid JSON is therefore not an expected input to this receiver.

Do not point pg_logtap at the standard OTLP/HTTP endpoint:

```ini
# Wrong: /v1/logs expects an OTLP ExportLogsServiceRequest, not NDJSON.
pg_logtap.export_url = 'http://otel-collector:4318/v1/logs'
```

pg_logtap sends `Content-Type: application/x-ndjson` by default; changing that
label does not turn its NDJSON body into an OTLP request. OTLP/HTTP accepts
OTLP protobuf or the OTLP protobuf-JSON envelope, so Collector responds with
HTTP 415 to the pg_logtap body. `webhook_event` is the adapter from NDJSON to
the OTel logs data model.

## TCP: `tcp_log`

TCP is the smaller protocol, but has no application-level ACK. A successful
socket write counts as delivered even if the Collector later fails to process
or forward the record. See [Delivery contract](delivery.md) for the exact
at-most-once / fallback duplicate window.

PostgreSQL configuration:

```ini
pg_logtap.export_url = 'tcp://otel-collector:54525'
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

Collector configuration:

```yaml
receivers:
  tcp_log/pg_logtap:
    listen_address: 0.0.0.0:54525
    encoding: utf-8
    # The default 1 MiB is enough for the default pg_logtap.message_max. This
    # value also admits a maximally escaped event at message_max = 1 MiB.
    max_log_size: 8MiB
    # Keep newline tokenization. TCP writes/packets are not record boundaries.
    one_log_per_packet: false
    operators:
      - type: json_parser
        parse_from: body
        parse_to: attributes
        parse_ints: true
        on_error: drop
        timestamp:
          parse_from: attributes.timestamp
          layout_type: gotime
          layout: '2006-01-02T15:04:05.000000Z'
        severity:
          parse_from: attributes.level

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128

  transform/pg_logtap:
    error_mode: propagate
    log_statements:
      - set(resource.attributes["service.name"], "postgresql")
      - set(resource.attributes["host.name"], log.attributes["host"]) where log.attributes["host"] != nil
      - set(resource.attributes["service.namespace"], log.attributes["cluster"]) where log.attributes["cluster"] != nil
      - set(log.body, log.attributes["message"]) where log.attributes["message"] != nil

  batch: {}

exporters:
  otlp:
    endpoint: observability-backend:4317
    tls:
      # Use certificate verification instead for an untrusted network.
      insecure: true

service:
  pipelines:
    logs/pg_logtap:
      receivers: [tcp_log/pg_logtap]
      processors: [memory_limiter, transform/pg_logtap, batch]
      exporters: [otlp]
```

The current receiver name is `tcp_log`; `tcplog` is a deprecated alias.
Do not set `one_log_per_packet: true`: in Collector 0.161.0 that mode reads the
connection until EOF as one record. pg_logtap sends a stream of newline-framed
objects, and TCP packet boundaries have no message semantics.

For encrypted transport use `tcps://` on the pg_logtap side and configure the
receiver's `tls.cert_file` / `tls.key_file`. pg_logtap verifies the server with
`export_tls_ca` and, when needed, `export_tls_server_name`.

## Field mapping

Both examples retain every non-null pg_logtap JSON field as a log attribute,
including `host`, `cluster`, `seq`, `database`, `user`, `sqlerrcode`, source
location and truncation/redaction metadata. They additionally map:

| pg_logtap field | OpenTelemetry field |
|---|---|
| `message` | log body |
| `timestamp` | log timestamp |
| `level` | severity text and number |
| fixed value | `service.name = postgresql` |
| `host` | resource `host.name` |
| `cluster` | resource `service.namespace` |

Deduplicate downstream on `(host, cluster, seq)`; `cluster` may be null unless
`pg_logtap.cluster_name` or PostgreSQL's `cluster_name` is set.

## Tested downstream example: VictoriaLogs

The receiver examples above deliberately keep a generic OTLP exporter. The
following exporter was tested as one concrete downstream destination; it does
not make VictoriaLogs a requirement for OpenTelemetry Collector:

```yaml
exporters:
  otlp_http/victorialogs:
    logs_endpoint: http://victorialogs:9428/insert/opentelemetry/v1/logs
    encoding: proto
    compression: gzip
```

Reference it from either logs pipeline as
`exporters: [otlp_http/victorialogs]`. The complete two-receiver configuration
used for the test is
[`tests/e2e/otel-victorialogs.yaml`](../tests/e2e/otel-victorialogs.yaml).

The end-to-end test used:

```text
pg_logtap 0.5.2 on PostgreSQL 18
otel/opentelemetry-collector-contrib:0.161.0
sha256:fd328de2552466ad78385e1b1289c3f2402b1c45f265b252aab1955b42845ac1
victoriametrics/victoria-logs:v1.52.0
sha256:47b820890d64c4575a2a0a46415dcd8a4fd59a0f1fcd6a377693d7aea639442e
```

Each path was tested with 100 indexed marker events: 20 each at `DEBUG1`,
`LOG`, `INFO`, `NOTICE` and `WARNING`.

```text
HTTP NDJSON + gzip → webhook_event → OTLP/HTTP protobuf + gzip → VictoriaLogs
TCP JSON lines      → tcp_log      → OTLP/HTTP protobuf + gzip → VictoriaLogs
```

VictoriaLogs returned exactly 20 distinct indexes per level for each marker,
without duplicates. Both PostgreSQL senders kept `events_dropped`,
`events_queued`, `send_cycles_failed` and `events_lost` at zero. Counts above
100 are expected because `log_min_messages=debug5` also enables PostgreSQL's
internal startup/debug messages; the tested PostgreSQL 18 run produced records
at every level from `DEBUG1` through `DEBUG5`.

Manual inspection of the tested Collector and VictoriaLogs logs found no
export errors. Sample returned rows preserved the pg_logtap fields, used
`message` as `_msg` and `timestamp` as `_time`, and included the `service.name`,
`host.name` and `service.namespace` resource mapping. VictoriaLogs renders OTLP
attribute numbers and arrays as strings in its JSON query response; for example,
an exact `seq` appeared as `"843919748833004"` and an empty `truncated` array as
`"[]"`.

In those sample rows, `webhook_event` 0.161.0 added receiver/source
instrumentation-scope attributes. `tcp_log` did not, so VictoriaLogs reported
`scope.name=unknown` and `scope.version=unknown` for the TCP records. This did
not affect the original pg_logtap fields or resource attributes.

## Reproduce the tested stand

The stand below is intentionally specific to the tested downstream example;
the general HTTP and TCP receiver configurations remain backend-neutral. Run
the commands from any working copy of this repository. The extension runtime
is downloaded from the v0.5.2 GitHub release, so no Zig or PostgreSQL build
toolchain is required.

Download the runtime package matching the host architecture:

```sh
VERSION=0.5.2
PG_MAJOR=18
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) printf 'unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

RUNTIME_DIR=$(mktemp -d)
PACKAGE="pg_logtap-${VERSION}-pg${PG_MAJOR}-${ARCH}"
curl -fL \
  "https://github.com/spa-28/pg_logtap/releases/download/v${VERSION}/${PACKAGE}.tar.gz" \
  -o "$RUNTIME_DIR/$PACKAGE.tar.gz"
tar -xzf "$RUNTIME_DIR/$PACKAGE.tar.gz" -C "$RUNTIME_DIR"
test -f "$RUNTIME_DIR/lib/pg_logtap.so"
test -f "$RUNTIME_DIR/extension/pg_logtap.control"
test -f "$RUNTIME_DIR/extension/pg_logtap--${VERSION}.sql"
```

Create an isolated Docker network and start VictoriaLogs and Collector:

```sh
NET=pglogtap-otel-vlogs-check-net
VL=pglogtap-otel-vlogs-check
OTEL=pglogtap-otel-vlogs-check-otel
HTTP_PG=pglogtap-otel-vlogs-check-pg-http
TCP_PG=pglogtap-otel-vlogs-check-pg-tcp
VL_IMAGE='victoriametrics/victoria-logs:v1.52.0@sha256:47b820890d64c4575a2a0a46415dcd8a4fd59a0f1fcd6a377693d7aea639442e'
OTEL_IMAGE='otel/opentelemetry-collector-contrib:0.161.0@sha256:fd328de2552466ad78385e1b1289c3f2402b1c45f265b252aab1955b42845ac1'

docker network create "$NET"

docker run -d --name "$VL" \
  --network "$NET" --network-alias victorialogs \
  "$VL_IMAGE"

docker run -d --name "$OTEL" \
  --network "$NET" --network-alias otel-collector \
  -v "$PWD/tests/e2e/otel-victorialogs.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  "$OTEL_IMAGE" \
  --config=/etc/otelcol-contrib/config.yaml

until docker run --rm --network "$NET" alpine:3.20 sh -c \
  'nc -z victorialogs 9428 && nc -z otel-collector 8088 && nc -z otel-collector 54525'
do
  sleep 1
done
```

Start one PostgreSQL sender per transport. Separate senders make the receiver
path unambiguous. They also avoid a configuration trap: a
`pg_logtap.export_url` supplied with `postgres -c` has higher precedence than
`ALTER SYSTEM`, so it cannot be switched in place through
`postgresql.auto.conf`.

```sh
start_pg() {
  docker run -d --name "$1" --network "$NET" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$RUNTIME_DIR/lib/pg_logtap.so:/usr/lib/postgresql/18/lib/pg_logtap.so:ro" \
    -v "$RUNTIME_DIR/extension/pg_logtap.control:/usr/share/postgresql/18/extension/pg_logtap.control:ro" \
    -v "$RUNTIME_DIR/extension/pg_logtap--${VERSION}.sql:/usr/share/postgresql/18/extension/pg_logtap--${VERSION}.sql:ro" \
    postgres:18 \
    -c shared_preload_libraries=pg_logtap \
    -c log_min_messages=debug5 \
    -c pg_logtap.level_min=10 \
    -c "pg_logtap.export_url=$2" \
    -c pg_logtap.export_gzip=on \
    -c pg_logtap.export_fallback_file=pg_logtap-fallback.bin \
    -c pg_logtap.flush_interval=100 \
    -c pg_logtap.cluster_name=otel-vlogs-e2e
}

start_pg "$HTTP_PG" 'http://otel-collector:8088/pg-logtap'
start_pg "$TCP_PG"  'tcp://otel-collector:54525'

for pg in "$HTTP_PG" "$TCP_PG"; do
  until docker exec "$pg" pg_isready -U postgres >/dev/null 2>&1; do
    sleep 1
  done
  docker exec "$pg" psql -U postgres -v ON_ERROR_STOP=1 \
    -qc 'CREATE EXTENSION pg_logtap'
done
```

The two debug settings are test-specific. PostgreSQL defaults to
`log_min_messages=warning`, while pg_logtap defaults to `level_min=15` (`LOG`);
setting `debug5` and `10` enables the complete DEBUG5+ range for this run.

Generate 20 indexed events at each selected level through each receiver:

```sh
emit_matrix() {
  docker exec "$1" psql -U postgres -v ON_ERROR_STOP=1 -qc \
    "DO \$\$ DECLARE i int := 0; BEGIN
       WHILE i < 20 LOOP
         RAISE DEBUG '$2 DEBUG1 %', i;
         RAISE LOG '$2 LOG %', i;
         RAISE INFO '$2 INFO %', i;
         RAISE NOTICE '$2 NOTICE %', i;
         RAISE WARNING '$2 WARNING %', i;
         i := i + 1;
       END LOOP;
     END \$\$"
}

HTTP_MARKER="otel-vlogs-http-$(date +%s)"
TCP_MARKER="otel-vlogs-tcp-$(date +%s)"
emit_matrix "$HTTP_PG" "$HTTP_MARKER"
emit_matrix "$TCP_PG" "$TCP_MARKER"
```

Query VictoriaLogs. The function waits for exactly 20 rows per level and
verifies every index from `0` through `19`:

```sh
query_marker() {
  marker=$1
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    response=$(docker run --rm --network "$NET" alpine:3.20 \
      wget -qO- \
      "http://victorialogs:9428/select/logsql/query?query=%22${marker}%22%20%7C%20limit%201000")
    count=$(printf '%s\n' "$response" | grep -c "\"_msg\":\"$marker " || true)
    complete=1
    for level in DEBUG1 LOG INFO NOTICE WARNING; do
      level_count=$(printf '%s\n' "$response" | \
        grep -c "\"_msg\":\"$marker $level " || true)
      [ "$level_count" -eq 20 ] || complete=0
      index=0
      while [ "$index" -lt 20 ]; do
        printf '%s\n' "$response" | \
          grep -F "\"_msg\":\"$marker $level $index\"" >/dev/null || complete=0
        index=$((index + 1))
      done
    done
    if [ "$count" -eq 100 ] && [ "$complete" -eq 1 ]; then
      printf '%s\n' "$response"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  printf 'expected 20 DEBUG1/LOG/INFO/NOTICE/WARNING rows for %s, got %s total\n' \
    "$marker" "$count" >&2
  return 1
}

query_marker "$HTTP_MARKER"
query_marker "$TCP_MARKER"

for pg in "$HTTP_PG" "$TCP_PG"; do
  docker exec "$pg" psql -U postgres -Atc \
    'SELECT events_dropped = 0
         AND events_queued = 0
         AND send_cycles_failed = 0
         AND events_lost = 0
     FROM pg_logtap_delivery' | grep -qx t
  docker exec "$pg" psql -U postgres -Atc 'SELECT pg_logtap_stats()'
done
```

For this 100-event marker run, `events_dropped`, `events_queued`,
`send_cycles_failed` and `events_lost` must remain zero. `events_sent` can be
higher than 100 because PostgreSQL's own debug/startup lines are also captured.

Inspect component logs if either query does not pass:

```sh
docker logs "$OTEL"
docker logs "$VL"
docker logs "$HTTP_PG"
docker logs "$TCP_PG"
```

Remove only the isolated stand, its anonymous PostgreSQL volumes and the
downloaded runtime:

```sh
docker rm -fv "$HTTP_PG" "$TCP_PG" "$OTEL" "$VL"
docker network rm "$NET"
rm -rf "$RUNTIME_DIR"
```
