# ClickHouse

pg_logtap can send logs directly to ClickHouse over HTTP. Its wire format is
newline-delimited JSON, which ClickHouse accepts as `JSONEachRow`; no Vector or
OpenTelemetry Collector is required.

```text
PostgreSQL + pg_logtap
  → HTTP POST, NDJSON, optional request gzip
  → ClickHouse HTTP interface
  → MergeTree table
```

The configuration below was tested with:

```text
pg_logtap 0.5.2 on PostgreSQL 18
clickhouse/clickhouse-server:25.8.33.6
sha256:0152dd511befe6a2c2ef53e930726179669b08116da78500b37c51c96ff5ee77
```

## Table schema

Create a column for every field in the pg_logtap event. The checked-in schema
is [`tests/e2e/clickhouse.sql`](../tests/e2e/clickhouse.sql):

```sql
CREATE DATABASE IF NOT EXISTS pg_logtap;

CREATE TABLE IF NOT EXISTS pg_logtap.logs
(
    `seq` UInt64,
    `timestamp` DateTime64(6, 'UTC'),
    `level` LowCardinality(String),
    `message` String,
    `detail` Nullable(String),
    `hint` Nullable(String),
    `context` Nullable(String),
    `sqlerrcode` FixedString(5),
    `filename` Nullable(String),
    `lineno` UInt32,
    `funcname` Nullable(String),
    `database` Nullable(String),
    `user` Nullable(String),
    `app` Nullable(String),
    `client_host` Nullable(String),
    `host` Nullable(String),
    `cluster` Nullable(String),
    `pgdata` Nullable(String),
    `pid` Int32,
    `backend_type` Nullable(String),
    `query` Nullable(String),
    `truncated` Array(String),
    `redacted` Array(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(`timestamp`)
ORDER BY (ifNull(`host`, ''), ifNull(`cluster`, ''), `seq`);
```

`DateTime64(6, 'UTC')` preserves pg_logtap's microsecond timestamp precision.
The ordering key keeps each source's sequence ordered while accepting a null
cluster name. The schema intentionally does not enable
`input_format_skip_unknown_fields`: a wire-schema change fails visibly instead
of silently discarding a new field.

## pg_logtap configuration

The ClickHouse HTTP interface accepts the pg_logtap request body directly:

```ini
pg_logtap.export_url = 'http://clickhouse:8123/?query=INSERT%20INTO%20pg_logtap.logs%20FORMAT%20JSONEachRow&date_time_input_format=best_effort&wait_end_of_query=1'
pg_logtap.export_gzip = on
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

`date_time_input_format=best_effort` lets ClickHouse parse pg_logtap's RFC 3339
UTC timestamps. `wait_end_of_query=1` asks ClickHouse to finish the insert
before returning the HTTP response; without it, an early HTTP 200 can precede
a parsing or insertion error in the response body. Request gzip is supported
and reduces the NDJSON payload without changing the stored fields.

Use the HTTP port, normally `8123`. `tcp://clickhouse:9000` does not work:
port 9000 speaks the ClickHouse native binary protocol, while pg_logtap's TCP
transport sends newline-framed JSON without that protocol envelope.

For an untrusted network, use `https://`, configure `pg_logtap.export_tls_ca`,
and authenticate with an HTTP `Authorization` header through
`pg_logtap.export_http_extra_headers`. The unauthenticated configuration in the stand
below is limited to an isolated Docker network with no published ports.

With `wait_end_of_query=1`, pg_logtap uses ClickHouse's HTTP 2xx response as
the batch acknowledgement. HTTP/network/insert failures use the normal
in-memory retry backlog and optional fallback file; see
[Delivery contract](delivery.md). Deduplicate on `(host, cluster, seq)` when a
fallback replay overlaps a batch already committed by ClickHouse.

## Tested result

The stand below inserted 100 indexed marker events: 20 each at `DEBUG1`,
`LOG`, `INFO`, `NOTICE` and `WARNING`. ClickHouse returned exactly 20 distinct
indexes per level, without duplicates. With DEBUG5+ enabled, PostgreSQL's own
startup/workload messages also produced records at every level from `DEBUG1`
through `DEBUG5`.

The pg_logtap sender reported:

```text
events_dropped=0 events_queued=0 send_cycles_failed=0 events_lost=0
```

Every event field, including nullable context/catalog fields and the
`truncated`/`redacted` arrays, was accepted by the typed table. The timestamp
was stored at microsecond precision and gzip delivery completed without HTTP
failures.

## Reproduce the test stand

Run all command blocks below in the same Bash shell from a working copy of
this repository. The extension is downloaded from GitHub Releases, so the
stand does not require Zig or local PostgreSQL development packages. A failure
prints available container logs and removes only this run's uniquely named
resources.

Download the pg_logtap 0.5.2 runtime matching the host architecture:

```sh
set -euo pipefail

VERSION=0.5.2
PG_MAJOR=18
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) printf 'unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

RUN_ID="$(date +%s)-$$"
NET="pglogtap-clickhouse-check-net-$RUN_ID"
CH="pglogtap-clickhouse-check-$RUN_ID"
PG="pglogtap-clickhouse-check-pg-$RUN_ID"
RUNTIME_DIR=$(mktemp -d)

cleanup() {
  docker rm -fv "$PG" "$CH" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$RUNTIME_DIR"
}

on_exit() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    docker logs "$PG" 2>/dev/null || true
    docker logs "$CH" 2>/dev/null || true
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

Create an isolated network and start ClickHouse with the checked-in schema:

```sh
docker network create "$NET"

docker run -d --name "$CH" \
  --network "$NET" --network-alias clickhouse \
  -e CLICKHOUSE_SKIP_USER_SETUP=1 \
  -v "$PWD/tests/e2e/clickhouse.sql:/docker-entrypoint-initdb.d/pg_logtap.sql:ro" \
  clickhouse/clickhouse-server:25.8.33.6@sha256:0152dd511befe6a2c2ef53e930726179669b08116da78500b37c51c96ff5ee77

ready=0
attempt=0
while [ "$ready" -lt 2 ] && [ "$attempt" -lt 60 ]; do
  if [ "$(docker exec "$CH" clickhouse-client \
    --query 'EXISTS TABLE pg_logtap.logs' 2>/dev/null || true)" = 1 ]; then
    ready=$((ready + 1))
  else
    ready=0
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$ready" -ne 2 ]; then
  printf 'ClickHouse did not become ready\n' >&2
  exit 1
fi
```

The two consecutive checks avoid the short handoff between ClickHouse's
initialization server and its normal server process.

Start PostgreSQL with direct ClickHouse export. The DEBUG settings are specific
to this test; pg_logtap normally defaults to `level_min=15` (`LOG`).

```sh
EXPORT_URL='http://clickhouse:8123/?query=INSERT%20INTO%20pg_logtap.logs%20FORMAT%20JSONEachRow&date_time_input_format=best_effort&wait_end_of_query=1'

docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v "$RUNTIME_DIR/lib/pg_logtap.so:/usr/lib/postgresql/18/lib/pg_logtap.so:ro" \
  -v "$RUNTIME_DIR/extension/pg_logtap.control:/usr/share/postgresql/18/extension/pg_logtap.control:ro" \
  -v "$RUNTIME_DIR/extension/pg_logtap--${VERSION}.sql:/usr/share/postgresql/18/extension/pg_logtap--${VERSION}.sql:ro" \
  postgres:18 \
  -c shared_preload_libraries=pg_logtap \
  -c log_min_messages=debug5 \
  -c pg_logtap.level_min=10 \
  -c "pg_logtap.export_url=$EXPORT_URL" \
  -c pg_logtap.export_gzip=on \
  -c pg_logtap.export_fallback_file=pg_logtap-fallback.bin \
  -c pg_logtap.flush_interval=100 \
  -c pg_logtap.cluster_name=clickhouse-e2e

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
```

Generate 20 events at each selected level:

```sh
MARKER="clickhouse-direct-$(date +%s)"
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

Wait for the complete batch, then verify the per-level count and exact index
set. The third result column must be `1` for every level:

```sh
attempt=0
count=0
while [ "$attempt" -lt 30 ]; do
  count=$(docker exec "$CH" clickhouse-client --query \
    "SELECT count() FROM pg_logtap.logs WHERE startsWith(message, '$MARKER ')")
  [ "$count" -eq 100 ] && break
  attempt=$((attempt + 1))
  sleep 1
done
[ "$count" -eq 100 ]

docker exec "$CH" clickhouse-client --format TSV --query \
  "SELECT
     level,
     count(),
     arraySort(groupArray(toUInt32(arrayElement(splitByChar(' ', message), -1)))) = range(20) AS indexes_ok
   FROM pg_logtap.logs
   WHERE startsWith(message, '$MARKER ')
   GROUP BY level
   ORDER BY level"
```

Expected output:

```text
DEBUG1  20  1
INFO    20  1
LOG     20  1
NOTICE  20  1
WARNING 20  1
```

Confirm that PostgreSQL also emitted non-marker internal records across the
complete DEBUG range and inspect the delivery counters:

```sh
for level in DEBUG1 DEBUG2 DEBUG3 DEBUG4 DEBUG5; do
  count=$(docker exec "$CH" clickhouse-client --query \
    "SELECT count() FROM pg_logtap.logs
     WHERE level = '$level' AND NOT startsWith(message, '$MARKER ')")
  [ "$count" -gt 0 ] || { printf 'missing %s\n' "$level" >&2; exit 1; }
  printf '%s=%s\n' "$level" "$count"
done

docker exec "$PG" psql -U postgres -Atc 'SELECT pg_logtap_stats()'
```

## View stored logs

The stand does not publish ClickHouse ports to the host, so run
`clickhouse-client` inside its container. Show the latest 50 events:

```sh
docker exec "$CH" clickhouse-client --query '
  SELECT timestamp, level, `database`, `user`, message
  FROM pg_logtap.logs
  ORDER BY timestamp DESC
  LIMIT 50
  FORMAT Vertical'
```

Filter by severity:

```sh
docker exec "$CH" clickhouse-client --query "
  SELECT timestamp, level, message
  FROM pg_logtap.logs
  WHERE level IN ('ERROR', 'FATAL', 'PANIC')
  ORDER BY timestamp DESC
  LIMIT 100"
```

Inspect the generated test batch or aggregate all stored levels:

```sh
docker exec "$CH" clickhouse-client --query "
  SELECT timestamp, level, message
  FROM pg_logtap.logs
  WHERE startsWith(message, '$MARKER ')
  ORDER BY timestamp, level"

docker exec "$CH" clickhouse-client --query "
  SELECT level, count()
  FROM pg_logtap.logs
  GROUP BY level
  ORDER BY level"
```

Use `FORMAT JSONEachRow` instead of `FORMAT Vertical` when the result is going
to another command or file.

If a check fails, inspect both components before cleanup:

```sh
docker logs "$PG"
docker logs "$CH"
```

Remove only the isolated stand, its anonymous volumes and the downloaded
runtime:

```sh
trap - EXIT
cleanup
```
