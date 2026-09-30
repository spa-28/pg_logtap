# Fluentd

Fluentd can receive pg_logtap directly over HTTP or raw TCP:

```text
PostgreSQL + pg_logtap
  ├─ HTTP POST, NDJSON, optional request gzip → Fluentd in_http
  └─ raw TCP, newline-delimited JSON          → Fluentd in_tcp
```

Fluentd and Fluent Bit are separate products. Fluentd is the Ruby-based
collector and aggregator with its own plugin and configuration model; Fluent
Bit is the smaller C-based agent. Their receiver behavior also differs here:
the tested Fluentd `in_http` accepts pg_logtap's default
`application/x-ndjson`, while the tested Fluent Bit HTTP input requires the
same NDJSON body to be labelled `application/json`. See
[Fluent Bit](fluent-bit.md) for that configuration.

The configuration below was tested with:

```text
pg_logtap 0.5.2 on PostgreSQL 18
Fluentd 1.19.3
fluent/fluentd:v1.19.3-debian-2.4
sha256:57d670d33bb9fd420dce95cc8930eae9ab027b34097860fe295d33edb5ecae33
```

The digest is the multi-platform image index containing Linux AMD64 and ARM64
manifests.

## Fluentd configuration

The checked-in manual-stand configuration is
[`tests/e2e/fluentd.conf`](../tests/e2e/fluentd.conf):

```conf
<system>
  log_level info
</system>

<source>
  @type http
  @id pg_logtap_http
  bind 0.0.0.0
  port 9880
</source>

<source>
  @type tcp
  @id pg_logtap_tcp
  bind 0.0.0.0
  port 5170
  tag pg_logtap_tcp
  delimiter "\n"

  <parse>
    @type json
  </parse>
</source>

<match pg_logtap_http>
  @type file
  @id pg_logtap_http_file
  path /fluentd/log/pg-logtap-http
  append true

  <buffer>
    @type file
    path /tmp/fluentd-buffer/http
    flush_mode interval
    flush_interval 1s
    flush_at_shutdown true
  </buffer>

  <format>
    @type json
  </format>
</match>

<match pg_logtap_tcp>
  @type file
  @id pg_logtap_tcp_file
  path /fluentd/log/pg-logtap-tcp
  append true

  <buffer>
    @type file
    path /tmp/fluentd-buffer/tcp
    flush_mode interval
    flush_interval 1s
    flush_at_shutdown true
  </buffer>

  <format>
    @type json
  </format>
</match>
```

An HTTP request to `/pg_logtap_http` gets the tag `pg_logtap_http`; the TCP
source assigns `pg_logtap_tcp`. Exact-match outputs keep the two paths
separate. Explicit JSON formatting writes only the decoded pg_logtap record,
one object per line. Fluentd's file output uses daily names such as
`pg-logtap-http.20260928.log`, so commands below use globs rather than assuming
a fixed filename.

The file outputs make the stand self-contained and are the end of this tested
pipeline: the checked-in configuration does **not** forward records to
VictoriaLogs. Replace or duplicate the matches with the required production
filters and outputs to build a downstream pipeline; a Fluentd-to-VictoriaLogs
path is not part of this test.

## pg_logtap settings

### HTTP

```ini
pg_logtap.export_url = 'http://fluentd:9880/pg_logtap_http'
pg_logtap.export_gzip = on
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

Fluentd 1.19.3 accepts pg_logtap's default
`Content-Type: application/x-ndjson`, splits the decompressed body at newline
boundaries and parses every line as JSON. No Content-Type override is needed.
A Fluentd HTTP 2xx response acknowledges the complete batch; network and
non-2xx failures enter pg_logtap's retry path and, when configured, its
fallback file.

### TCP

```ini
pg_logtap.export_url = 'tcp://fluentd:5170'
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

The TCP input uses newline framing and the JSON parser, matching pg_logtap's
wire format. TCP has no application-level acknowledgement: a successful socket
write is counted as delivered. See [Delivery contract](delivery.md) for retry,
fallback and deduplication semantics.

For untrusted networks, terminate TLS in front of Fluentd or use a TLS-capable
Fluentd input/plugin that matches pg_logtap's `https://` or `tcps://` sender
configuration.

## Tested result

The final isolated run used `log_min_messages=debug5` and
`pg_logtap.level_min=10`, so pg_logtap received PostgreSQL's internal
`DEBUG1` through `DEBUG5` traffic in addition to the deterministic marker
batch. HTTP used the default `application/x-ndjson` with request gzip; TCP used
newline-delimited JSON.

Each path received exactly 100 indexed marker events: 20 each at `DEBUG1`,
`LOG`, `INFO`, `NOTICE` and `WARNING`, with indexes `0` through `19` exactly
once at every level. All records parsed as UTF-8 JSON, HTTP and TCP markers
stayed in their respective outputs, and the `seq`, `timestamp`, `level`,
`message`, `database`, `user`, `host`, `cluster`, `truncated` and `redacted`
fields were preserved.

A statistics snapshot taken while the workers were still draining reported:

```text
HTTP: events_captured=2054 events_sent=1956 ring_events=97
TCP:  events_captured=2054 events_sent=1958 ring_events=14
```

Both senders kept `events_dropped=0`, `events_queued=0`,
`send_cycles_failed=0` and `events_lost=0`. The lower `events_sent` values are
a concurrent snapshot, not loss: the ring and worker-local batches were still
draining.

After the statistics queries themselves generated more DEBUG traffic and the
receivers were allowed to flush, the Fluentd files contained:

| Transport | Total records | DEBUG1 | DEBUG2 | DEBUG3 | DEBUG4 | DEBUG5 |
|---|---:|---:|---:|---:|---:|---:|
| HTTP | 3596 | 51 | 8 | 1121 | 851 | 1483 |
| TCP | 3674 | 51 | 8 | 1147 | 868 | 1518 |

Only the 100 indexed marker events per transport are a deterministic pass
criterion. The total DEBUG volume varies with PostgreSQL image version, startup
timing, readiness probes and diagnostic queries; at `debug5`, even querying
`pg_logtap_stats()` produces additional records. Fluentd reported no parse,
buffer or output errors.

## Reproduce the tested stand

Run all blocks below in the same Bash shell from a working copy of this
repository. The extension comes from GitHub Releases, so Zig and PostgreSQL
development packages are not required. Receiver ports remain private to an
isolated Docker network, resource names are unique to the run, and cleanup
removes only resources created here.

Download the pg_logtap 0.5.2 runtime matching the host architecture and define
cleanup:

```sh
set -euo pipefail

VERSION=0.5.2
PG_MAJOR=18
FLUENTD_IMAGE='fluent/fluentd:v1.19.3-debian-2.4@sha256:57d670d33bb9fd420dce95cc8930eae9ab027b34097860fe295d33edb5ecae33'
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) printf 'unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

RUN_ID="$(date +%s)-$$"
NET="pglogtap-fluentd-check-net-$RUN_ID"
FLUENTD="pglogtap-fluentd-check-$RUN_ID"
HTTP_PG="pglogtap-fluentd-check-pg-http-$RUN_ID"
TCP_PG="pglogtap-fluentd-check-pg-tcp-$RUN_ID"
RUNTIME_DIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)
chmod 0777 "$OUTPUT_DIR"

cleanup() {
  docker rm -fv "$HTTP_PG" "$TCP_PG" "$FLUENTD" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$RUNTIME_DIR" "$OUTPUT_DIR"
}

on_exit() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    docker logs "$FLUENTD" 2>/dev/null || true
    docker logs "$HTTP_PG" 2>/dev/null || true
    docker logs "$TCP_PG" 2>/dev/null || true
  fi
  cleanup
  exit "$status"
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

Validate the checked-in configuration, then start Fluentd:

```sh
docker run --rm \
  -v "$PWD/tests/e2e/fluentd.conf:/fluentd/etc/fluent.conf:ro" \
  "$FLUENTD_IMAGE" --dry-run -c /fluentd/etc/fluent.conf

docker network create "$NET"
docker run -d --name "$FLUENTD" \
  --network "$NET" --network-alias fluentd \
  -v "$PWD/tests/e2e/fluentd.conf:/fluentd/etc/fluent.conf:ro" \
  -v "$OUTPUT_DIR:/fluentd/log" \
  "$FLUENTD_IMAGE"

attempt=0
until docker exec "$FLUENTD" ruby -rsocket -e \
  'TCPSocket.new("127.0.0.1", 9880).close; TCPSocket.new("127.0.0.1", 5170).close'
do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf 'Fluentd did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done
```

Start one PostgreSQL sender per transport. Separate processes make route
isolation explicit. The DEBUG settings are specific to this test: PostgreSQL
emits all internal `DEBUG1` through `DEBUG5` records, while pg_logtap accepts
the complete DEBUG5+ range. pg_logtap normally defaults to `level_min=15`
(`LOG`).

```sh
start_pg() {
  name=$1
  url=$2
  gzip=$3
  cluster=$4
  docker run -d --name "$name" --network "$NET" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$RUNTIME_DIR/lib/pg_logtap.so:/usr/lib/postgresql/18/lib/pg_logtap.so:ro" \
    -v "$RUNTIME_DIR/extension/pg_logtap.control:/usr/share/postgresql/18/extension/pg_logtap.control:ro" \
    -v "$RUNTIME_DIR/extension/pg_logtap--${VERSION}.sql:/usr/share/postgresql/18/extension/pg_logtap--${VERSION}.sql:ro" \
    postgres:18 \
    -c shared_preload_libraries=pg_logtap \
    -c log_min_messages=debug5 \
    -c pg_logtap.level_min=10 \
    -c "pg_logtap.export_url=$url" \
    -c "pg_logtap.export_gzip=$gzip" \
    -c pg_logtap.export_fallback_file=pg_logtap-fallback.bin \
    -c pg_logtap.flush_interval=100 \
    -c "pg_logtap.cluster_name=$cluster"
}

start_pg "$HTTP_PG" 'http://fluentd:9880/pg_logtap_http' on fluentd-http-e2e
start_pg "$TCP_PG" 'tcp://fluentd:5170' off fluentd-tcp-e2e

for pg in "$HTTP_PG" "$TCP_PG"; do
  attempt=0
  until docker exec "$pg" pg_isready -U postgres >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      printf '%s did not become ready\n' "$pg" >&2
      exit 1
    fi
    sleep 1
  done
  docker exec "$pg" psql -U postgres -v ON_ERROR_STOP=1 \
    -qc 'CREATE EXTENSION pg_logtap'
done
```

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

HTTP_MARKER="fluentd-http-$RUN_ID"
TCP_MARKER="fluentd-tcp-$RUN_ID"
emit_matrix "$HTTP_PG" "$HTTP_MARKER"
emit_matrix "$TCP_PG" "$TCP_MARKER"
```

Wait for both complete batches. The file output appends to date-suffixed files,
so the counter reads every matching file:

```sh
marker_count() {
  python3 - "$OUTPUT_DIR" "$1" "$2" <<'PY'
import json, pathlib, sys
root, prefix, marker = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
print(sum(json.loads(line).get("message", "").startswith(marker + " ")
          for path in root.glob(prefix + "*") if path.is_file()
          for line in path.read_text(encoding="utf-8").splitlines() if line))
PY
}

attempt=0
while [ "$attempt" -lt 60 ]; do
  http_count=$(marker_count pg-logtap-http "$HTTP_MARKER")
  tcp_count=$(marker_count pg-logtap-tcp "$TCP_MARKER")
  [ "$http_count" -ge 100 ] && [ "$tcp_count" -ge 100 ] && break
  attempt=$((attempt + 1))
  sleep 1
done
[ "$http_count" -eq 100 ]
[ "$tcp_count" -eq 100 ]
sleep 2
```

Verify valid UTF-8 JSON, exact indexes, preserved fields and route isolation:

```sh
python3 - \
  "$OUTPUT_DIR" pg-logtap-http "$HTTP_MARKER" "$TCP_MARKER" fluentd-http-e2e HTTP \
  "$OUTPUT_DIR" pg-logtap-tcp "$TCP_MARKER" "$HTTP_MARKER" fluentd-tcp-e2e TCP <<'PY'
import collections, json, pathlib, sys
expected_levels = {"DEBUG1", "LOG", "INFO", "NOTICE", "WARNING"}
for offset in (1, 7):
    root = pathlib.Path(sys.argv[offset])
    prefix, marker, foreign_marker, cluster, transport = sys.argv[offset + 1:offset + 6]
    paths = sorted(path for path in root.glob(prefix + "*") if path.is_file())
    assert paths, (transport, "no output files")
    rows = [json.loads(line) for path in paths
            for line in path.read_text(encoding="utf-8").splitlines() if line]
    levels = collections.Counter(row.get("level") for row in rows)
    assert not any(row.get("message", "").startswith(foreign_marker + " ")
                   for row in rows)
    matching = [row for row in rows
                if row.get("message", "").startswith(marker + " ")]
    assert len(matching) == 100, (transport, len(matching))
    seen = collections.defaultdict(list)
    for row in matching:
        _, level, index = row["message"].rsplit(" ", 2)
        assert row["level"] == level
        assert row["cluster"] == cluster
        assert row["database"] == "postgres"
        assert row["user"] == "postgres"
        assert isinstance(row["seq"], int) and row["seq"] > 0
        assert isinstance(row["timestamp"], str) and row["timestamp"].endswith("Z")
        assert isinstance(row["host"], str) and row["host"]
        assert isinstance(row["truncated"], list)
        assert isinstance(row["redacted"], list)
        seen[level].append(int(index))
    assert set(seen) == expected_levels
    for level in sorted(expected_levels):
        assert sorted(seen[level]) == list(range(20))
        print(transport, level, len(seen[level]), "indexes_ok=1")
    for level in ("DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5"):
        assert levels[level] > 0, (transport, level)
        print(transport, level, levels[level], "internal_records_present=1")
PY
```

Check sender counters and print one concurrent statistics snapshot. The first
column must be `t`. With `debug5`, this connection and query generate more log
records themselves, so do not treat the captured/sent totals as a fixed target:

```sh
for pg in "$HTTP_PG" "$TCP_PG"; do
  docker exec "$pg" psql -U postgres -Atc \
    'SELECT events_dropped = 0
         AND events_queued = 0
         AND send_cycles_failed = 0
         AND events_lost = 0,
       pg_logtap_stats()
     FROM pg_logtap_delivery'
done
```

Fluentd should have no parse, buffer or output errors:

```sh
docker logs "$FLUENTD"
```

## View received logs

View recent HTTP or TCP records before removing the stand:

```sh
tail -n 50 "$OUTPUT_DIR"/pg-logtap-http.*.log
tail -n 50 "$OUTPUT_DIR"/pg-logtap-tcp.*.log
```

With `jq`, pretty-print all records or inspect only a generated batch:

```sh
jq . "$OUTPUT_DIR"/pg-logtap-http.*.log
jq --arg marker "$TCP_MARKER" \
  'select(.message | startswith($marker + " "))' \
  "$OUTPUT_DIR"/pg-logtap-tcp.*.log
```

These files are the receiver output; this stand does not send their contents to
VictoriaLogs. The cleanup function deletes `OUTPUT_DIR`. To keep the events,
copy them first:

```sh
SAVED_OUTPUT="$PWD/fluentd-output-$RUN_ID"
mkdir -p "$SAVED_OUTPUT"
cp "$OUTPUT_DIR"/pg-logtap-*.log "$SAVED_OUTPUT"/
printf 'saved Fluentd records in %s\n' "$SAVED_OUTPUT"
```

Fluentd's own operational log remains separate:

```sh
docker logs "$FLUENTD"
```

Remove the isolated stand, its anonymous PostgreSQL volumes, downloaded runtime
and received files:

```sh
trap - EXIT
cleanup
```
