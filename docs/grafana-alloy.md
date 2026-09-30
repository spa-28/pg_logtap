# Grafana Alloy to Loki

Loki is not a direct pg_logtap HTTP destination. Grafana Alloy can accept the
newline-delimited JSON (NDJSON), turn each line into a Loki entry and forward it
to Loki:

```text
PostgreSQL + pg_logtap
  → HTTP POST, NDJSON, no request gzip
  → Grafana Alloy loki.source.api /loki/api/v1/raw
  → Grafana Alloy loki.write
  → Loki /loki/api/v1/push
```

The configuration below was tested with:

```text
pg_logtap 0.5.2 on PostgreSQL 18
grafana/alloy:v1.20.1
sha256:2aa2099af76c0098d4af7a4d6e48f86cb66dc1a000222ad927a1c67c6542d13f
grafana/loki:3.7.8
sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193
```

Both digests are multi-platform image indexes containing Linux AMD64 and ARM64
manifests.

## Alloy configuration

The checked-in manual-stand configuration is
[`tests/e2e/alloy-loki.alloy`](../tests/e2e/alloy-loki.alloy):

```alloy
loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}

loki.source.api "pg_logtap" {
  http {
    listen_address = "0.0.0.0"
    listen_port    = 9880
  }

  labels = {
    job       = "pg_logtap",
    transport = "http",
  }

  forward_to = [loki.write.local.receiver]
}
```

`loki.source.api` exposes `/loki/api/v1/raw` on port 9880. The raw endpoint
splits the request body at newline boundaries and forwards each pg_logtap JSON
object as the complete Loki log line. `loki.write` performs the Loki-specific
encoding required by `/loki/api/v1/push`.

The configuration intentionally has no `loki.process` stage. Loki uses Alloy's
receipt time as the entry timestamp, while the original microsecond timestamp
stays in the JSON line. This is safe for fallback replay: an old pg_logtap event
does not become an old or out-of-order Loki sample. Parse the preserved fields
at query time with `| json`.

Only the static `job` and `transport` labels are configured in Alloy. Do not
promote `seq`, PID, message, query, source location, client address, timestamp
or other per-event values to Loki labels. The stock Loki 3.7.8 configuration
used in the stand additionally returned its automatically discovered
`service_name="pg_logtap"` and low-cardinality `detected_level` values. The
complete pg_logtap record remains the log line in every stream.

## pg_logtap settings

```ini
pg_logtap.export_url = 'http://alloy:9880/loki/api/v1/raw'
pg_logtap.export_gzip = off
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

The endpoint accepts pg_logtap's default
`Content-Type: application/x-ndjson`; no Content-Type override is needed.
Request gzip must remain **off**. Alloy's raw endpoint reads the request body as
lines and does not decode `Content-Encoding: gzip`; enabling gzip would send the
compressed bytes to the line reader rather than the original NDJSON records.

For an untrusted network, put an authenticating TLS proxy in front of the Alloy
listener and use pg_logtap's `https://`, CA/name verification and HTTP header
settings. Configure TLS/authentication separately on Alloy's `loki.write`
endpoint when Loki is not on the same trusted network.

## Why direct Loki URLs do not work

Neither Loki ingestion endpoint accepts pg_logtap NDJSON directly:

```ini
# Wrong: /push expects Loki's streams JSON envelope or Snappy protobuf.
pg_logtap.export_url = 'http://loki:3100/loki/api/v1/push'

# Wrong: /otlp/v1/logs expects an OTLP ExportLogsServiceRequest.
pg_logtap.export_url = 'http://loki:3100/otlp/v1/logs'
```

Changing `pg_logtap.export_http_content_type` changes only the MIME label; it
does not wrap the body in a Loki streams object or convert it to OTLP. Alloy is
the protocol adapter in this pipeline.

## Acknowledgement boundary

The raw Alloy endpoint returns HTTP 204 after accepting the entries into
Alloy's in-process pipeline. pg_logtap treats that 2xx response as the complete
HTTP batch acknowledgement. A connection failure or non-2xx response still
uses pg_logtap's RAM retry backlog and optional fallback file.

The 204 does **not** prove that `loki.write` subsequently persisted the entries.
Once Alloy has acknowledged the request, a later Alloy-to-Loki failure is
outside pg_logtap's retry boundary. Monitor Alloy's `loki_write` retry/drop
metrics and verify important deployments by querying Loki. As with every
at-least-once pg_logtap HTTP path, deduplicate on `(host, cluster, seq)` when a
lost acknowledgement can cause a whole-batch replay.

## Tested result

The isolated stand below queried Loki and found exactly 100 indexed marker
events: 20 each at `DEBUG1`, `LOG`, `INFO`, `NOTICE` and `WARNING`, with indexes
`0` through `19` exactly once at every level. Every stored line parsed as JSON;
`seq`, timestamp, level, database, user, host, cluster and truncation/redaction
metadata were preserved, and all `(host, cluster, seq)` tuples were unique.

The pg_logtap sender reported:

```text
events_dropped=0 events_queued=0 send_cycles_failed=0 events_lost=0 queue_backlog=0
```

With DEBUG5+ capture enabled, PostgreSQL also generated thousands of internal
records, so total captured/sent counts are timing-dependent and are not a pass
criterion. Alloy's write metrics recorded successful HTTP 204 batches to Loki;
`loki_write_batch_retries_total` and every
`loki_write_dropped_{entries,bytes}_total` series remained zero. The Loki query,
not Alloy's 204, was the end-to-end persistence check.

## Reproduce the tested stand

Run all command blocks below in the same Bash shell from a working copy of this
repository on Linux Docker Engine. The extension comes from GitHub Releases, so
Zig and PostgreSQL development packages are not required. No container port is
published to the host; the query commands use the containers' private bridge
addresses. Resource names are unique to the run, and cleanup removes only those
resources.

Download the pg_logtap 0.5.2 runtime matching the host architecture and define
cleanup:

```sh
set -euo pipefail

VERSION=0.5.2
PG_MAJOR=18
ALLOY_IMAGE='grafana/alloy:v1.20.1@sha256:2aa2099af76c0098d4af7a4d6e48f86cb66dc1a000222ad927a1c67c6542d13f'
LOKI_IMAGE='grafana/loki:3.7.8@sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193'
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) printf 'unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

RUN_ID="$(date +%s)-$$"
NET="pglogtap-alloy-loki-check-net-$RUN_ID"
LOKI="pglogtap-alloy-loki-check-loki-$RUN_ID"
ALLOY="pglogtap-alloy-loki-check-alloy-$RUN_ID"
PG="pglogtap-alloy-loki-check-pg-$RUN_ID"
RUNTIME_DIR=$(mktemp -d)
RESULT_DIR=$(mktemp -d)

cleanup() {
  docker rm -fv "$PG" "$ALLOY" "$LOKI" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$RUNTIME_DIR" "$RESULT_DIR"
}

on_exit() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    docker logs "$PG" 2>/dev/null || true
    docker logs "$ALLOY" 2>/dev/null || true
    docker logs "$LOKI" 2>/dev/null || true
  fi
  cleanup
  return "$status"
}
trap on_exit EXIT

PACKAGE="pg_logtap-${VERSION}-pg${PG_MAJOR}-${ARCH}"
curl -fL \
  "https://github.com/spa-28/pg_logtap/releases/download/v${VERSION}/${PACKAGE}.tar.gz" \
  -o "$RUNTIME_DIR/$PACKAGE.tar.gz"
tar -xzf "$RUNTIME_DIR/$PACKAGE.tar.gz" -C "$RUNTIME_DIR"
test -f "$RUNTIME_DIR/lib/pg_logtap.so"
test -f "$RUNTIME_DIR/extension/pg_logtap.control"
test -f "$RUNTIME_DIR/extension/pg_logtap--${VERSION}.sql"
```

Validate the checked-in Alloy configuration and Loki's bundled local
configuration with the exact pinned images:

```sh
docker run --rm \
  -v "$PWD/tests/e2e/alloy-loki.alloy:/etc/alloy/config.alloy:ro" \
  "$ALLOY_IMAGE" validate /etc/alloy/config.alloy

docker run --rm "$LOKI_IMAGE" \
  -config.file=/etc/loki/local-config.yaml \
  -verify-config=true
```

Create the isolated network, start Loki and wait for its functional readiness
endpoint:

```sh
docker network create "$NET"

docker run -d --name "$LOKI" \
  --network "$NET" --network-alias loki \
  "$LOKI_IMAGE" \
  -config.file=/etc/loki/local-config.yaml

LOKI_IP=$(docker inspect -f \
  "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" \
  "$LOKI")
attempt=0
until curl -fsS "http://$LOKI_IP:3100/ready" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf 'Loki did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done
```

Start Alloy with its management API private to the same network, then wait for
both process readiness and the `loki.source.api` receiver's `/ready` endpoint:

```sh
docker run -d --name "$ALLOY" \
  --network "$NET" --network-alias alloy \
  -v "$PWD/tests/e2e/alloy-loki.alloy:/etc/alloy/config.alloy:ro" \
  "$ALLOY_IMAGE" \
  run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy

ALLOY_IP=$(docker inspect -f \
  "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" \
  "$ALLOY")
attempt=0
until curl -fsS "http://$ALLOY_IP:12345/-/ready" >/dev/null 2>&1 &&
      curl -fsS "http://$ALLOY_IP:9880/ready" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf 'Alloy did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done
```

Start PostgreSQL with DEBUG5+ capture. The DEBUG settings are specific to this
test; pg_logtap normally defaults to `level_min=15` (`LOG`).

```sh
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v "$RUNTIME_DIR/lib/pg_logtap.so:/usr/lib/postgresql/18/lib/pg_logtap.so:ro" \
  -v "$RUNTIME_DIR/extension/pg_logtap.control:/usr/share/postgresql/18/extension/pg_logtap.control:ro" \
  -v "$RUNTIME_DIR/extension/pg_logtap--${VERSION}.sql:/usr/share/postgresql/18/extension/pg_logtap--${VERSION}.sql:ro" \
  postgres:18 \
  -c shared_preload_libraries=pg_logtap \
  -c log_min_messages=debug5 \
  -c pg_logtap.level_min=10 \
  -c pg_logtap.export_url=http://alloy:9880/loki/api/v1/raw \
  -c pg_logtap.export_gzip=off \
  -c pg_logtap.export_fallback_file=pg_logtap-fallback.bin \
  -c pg_logtap.flush_interval=100 \
  -c pg_logtap.cluster_name=alloy-loki-e2e

attempt=0
until docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf 'PostgreSQL did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done

docker exec "$PG" psql -U postgres -v ON_ERROR_STOP=1 \
  -qc 'CREATE EXTENSION pg_logtap'
[ "$(docker exec "$PG" psql -U postgres -Atc \
  'SELECT pg_logtap_version()')" = "$VERSION" ]
[ "$(docker exec "$PG" psql -U postgres -Atc \
  'SHOW pg_logtap.export_url')" = 'http://alloy:9880/loki/api/v1/raw' ]
[ "$(docker exec "$PG" psql -U postgres -Atc \
  'SHOW pg_logtap.export_gzip')" = 'off' ]
[ "$(docker exec "$PG" psql -U postgres -Atc \
  'SHOW pg_logtap.cluster_name')" = 'alloy-loki-e2e' ]
[ "$(docker exec "$PG" psql -U postgres -Atc \
  'SHOW pg_logtap.level_min')" = '10' ]
[ "$(docker exec "$PG" psql -U postgres -Atc \
  'SHOW log_min_messages')" = 'debug5' ]
```

Generate 20 indexed events at each selected level. Record the query start time
before generation because Loki indexes the Alloy receipt time:

```sh
START_NS=$(date +%s%N)
MARKER="alloy-loki-$RUN_ID"
docker exec "$PG" psql -U postgres -v ON_ERROR_STOP=1 -qc \
  "DO \$\$ DECLARE i int := 0; BEGIN
     WHILE i < 20 LOOP
       RAISE DEBUG '$MARKER DEBUG1 %', i;
       RAISE LOG '$MARKER LOG %', i;
       RAISE INFO '$MARKER INFO %', i;
       RAISE NOTICE '$MARKER NOTICE %', i;
       RAISE WARNING '$MARKER WARNING %', i;
       i := i + 1;
     END LOOP;
   END \$\$"
```

Poll Loki for the complete batch. `limit=1000` is explicit because Loki's
default limit of 100 could hide duplicates:

```sh
QUERY="{job=\"pg_logtap\",transport=\"http\"} |= \"$MARKER \""
attempt=0
count=0
while [ "$attempt" -lt 60 ]; do
  END_NS=$(date +%s%N)
  curl -fsS -G "http://$LOKI_IP:3100/loki/api/v1/query_range" \
    --data-urlencode "query=$QUERY" \
    --data-urlencode "start=$START_NS" \
    --data-urlencode "end=$END_NS" \
    --data-urlencode 'direction=forward' \
    --data-urlencode 'limit=1000' >"$RESULT_DIR/query.json"
  count=$(python3 - "$RESULT_DIR/query.json" "$MARKER" <<'PY'
import json, pathlib, sys
response = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
marker = sys.argv[2] + " "
rows = []
for stream in response.get("data", {}).get("result", []):
    rows.extend(json.loads(line) for _, line in stream.get("values", []))
print(sum(row.get("message", "").startswith(marker) for row in rows))
PY
)
  [ "$count" -ge 100 ] && break
  attempt=$((attempt + 1))
  sleep 1
done
[ "$count" -eq 100 ]
```

Validate every marker record, all streams and the exact index matrix:

```sh
python3 - "$RESULT_DIR/query.json" "$MARKER" <<'PY'
import collections, datetime, json, pathlib, sys
response = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert response["status"] == "success", response
marker = sys.argv[2]
expected_labels = {"job": "pg_logtap", "transport": "http"}
rows = []
streams = response["data"]["result"]
for stream in streams:
    labels = stream["stream"]
    assert all(labels.get(k) == v for k, v in expected_labels.items()), labels
    unexpected = set(labels) - set(expected_labels) - {
        "service_name", "detected_level"
    }
    assert not unexpected, labels
    assert labels.get("service_name") in (None, "pg_logtap"), labels
    for _, line in stream["values"]:
        row = json.loads(line)
        if row.get("message", "").startswith(marker + " "):
            rows.append(row)

assert len(rows) == 100, len(rows)
seen = collections.defaultdict(list)
identities = set()
for row in rows:
    _, level, index = row["message"].rsplit(" ", 2)
    assert row["level"] == level, row
    seen[level].append(int(index))
    assert row["database"] == "postgres", row
    assert row["user"] == "postgres", row
    assert row["cluster"] == "alloy-loki-e2e", row
    assert isinstance(row["seq"], int) and row["seq"] > 0, row
    assert isinstance(row["host"], str) and row["host"], row
    assert isinstance(row["truncated"], list), row
    assert isinstance(row["redacted"], list), row
    assert isinstance(row["timestamp"], str) and row["timestamp"].endswith("Z")
    datetime.datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
    identity = (row["host"], row["cluster"], row["seq"])
    assert identity not in identities, identity
    identities.add(identity)

expected_levels = {"DEBUG1", "LOG", "INFO", "NOTICE", "WARNING"}
assert set(seen) == expected_levels, seen
for level in sorted(expected_levels):
    assert sorted(seen[level]) == list(range(20)), (level, seen[level])
    print(level, len(seen[level]), "indexes_ok=1")
print("rows=100 unique_identities=100")
print("stream_labels=" + json.dumps(
    [stream["stream"] for stream in streams], sort_keys=True
))
PY
```

Check the sender's loss/failure counters. The Boolean result must be `t`;
`events_sent` can be higher than 100 because DEBUG5 captures PostgreSQL's own
internal logs:

```sh
docker exec "$PG" psql -U postgres -Atc \
  'SELECT events_dropped = 0
       AND events_queued = 0
       AND send_cycles_failed = 0
       AND events_lost = 0
       AND queue_backlog = 0
   FROM pg_logtap_delivery'

docker exec "$PG" psql -U postgres -Atc 'SELECT pg_logtap_stats()'
```

Confirm that Alloy did not retry or drop Loki writes:

```sh
curl -fsS "http://$ALLOY_IP:12345/metrics" >"$RESULT_DIR/alloy.prom"
python3 - "$RESULT_DIR/alloy.prom" <<'PY'
import collections, pathlib, sys
values = collections.defaultdict(list)
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line or line.startswith("#"):
        continue
    sample, value = line.rsplit(None, 1)
    values[sample.split("{", 1)[0]].append(float(value))
for name in (
    "loki_write_batch_retries_total",
    "loki_write_dropped_entries_total",
    "loki_write_dropped_bytes_total",
):
    assert name in values, name
    assert sum(values[name]) == 0, (name, values[name])
print("alloy_loki_write_retries_and_drops=0")
PY
```

Inspect the component logs before cleanup. Loki's bundled single-process
configuration can emit a transient `empty ring` message during startup; use the
readiness check and the downstream query rather than treating pre-readiness
startup noise as an ingestion failure.

```sh
docker logs "$ALLOY"
docker logs "$LOKI"
```

## View logs

Query all pg_logtap streams and parse the JSON fields in LogQL:

```logql
{job="pg_logtap", transport="http"} | json
```

Filter parsed fields without turning them into stored labels:

```logql
{job="pg_logtap", transport="http"} | json | level = "ERROR"
```

From the test shell, query recent records through Loki's API and pretty-print
the response when `jq` is available:

```sh
curl -fsS -G "http://$LOKI_IP:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="pg_logtap",transport="http"} | json' \
  --data-urlencode "start=$START_NS" \
  --data-urlencode "end=$(date +%s%N)" \
  --data-urlencode 'direction=backward' \
  --data-urlencode 'limit=50' | jq .
```

Remove only this isolated stand and its temporary files:

```sh
trap - EXIT
cleanup
```

For a persistent deployment, use durable Loki storage instead of the bundled
local configuration, expose only authenticated endpoints, and monitor Alloy's
`loki_write_batch_retries_total`, `loki_write_dropped_entries_total` and
`loki_write_dropped_bytes_total` alongside pg_logtap's delivery counters.
