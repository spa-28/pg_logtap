# Vector

Vector can receive pg_logtap directly over HTTP or raw TCP. Both sources decode
one JSON object per line and can feed any Vector transform or sink:

```text
PostgreSQL + pg_logtap
  ├─ HTTP POST, NDJSON, optional request gzip → Vector http_server
  └─ raw TCP, newline-delimited JSON          → Vector socket
```

The configuration below was tested with:

```text
pg_logtap 0.5.2 on PostgreSQL 18
vector 0.57.0
timberio/vector:0.57.0-alpine
sha256:19e3526faf4d4b1ed0c28a0d68d4cc3a1e13e437099986a5b7a768707907497c
```

## Vector configuration

The checked-in configuration is
[`tests/e2e/vector-direct.yaml`](../tests/e2e/vector-direct.yaml):

```yaml
data_dir: /var/lib/vector

sources:
  pg_logtap_http:
    type: http_server
    address: 0.0.0.0:8686
    decoding:
      codec: json
    framing:
      method: newline_delimited

  pg_logtap_tcp:
    type: socket
    mode: tcp
    address: 0.0.0.0:54525
    decoding:
      codec: json
    framing:
      method: newline_delimited

sinks:
  http_file:
    type: file
    inputs: [pg_logtap_http]
    path: /var/log/vector/pg-logtap-http.jsonl
    encoding:
      codec: json
    framing:
      method: newline_delimited

  tcp_file:
    type: file
    inputs: [pg_logtap_tcp]
    path: /var/log/vector/pg-logtap-tcp.jsonl
    encoding:
      codec: json
    framing:
      method: newline_delimited
```

The file sinks make the stand below self-contained. In production, connect the
sources to the required transforms and output sinks instead.

### HTTP

HTTP is the recommended transport when both are available:

```ini
pg_logtap.export_url = 'http://vector:8686'
pg_logtap.export_gzip = on
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

Vector's `http_server` source accepts pg_logtap's default
`Content-Type: application/x-ndjson`, splits at newline boundaries and
transparently decompresses request gzip. A Vector HTTP 2xx response acknowledges
the complete batch; network/non-2xx failures enter pg_logtap's retry path and,
when configured, its fallback file.

### TCP

Use the socket source when HTTP request/response handling is not wanted:

```ini
pg_logtap.export_url = 'tcp://vector:54525'
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

TCP has no application-level acknowledgement. A successful socket write is
counted as delivered, so live delivery is at-most-once; fallback replay can
overlap data already accepted by Vector. Deduplicate downstream on
`(host, cluster, seq)` when that overlap matters. The complete semantics for
both transports are in [Delivery contract](delivery.md).

For untrusted networks use `https://` or `tcps://`, configure TLS on the
corresponding Vector source, and set pg_logtap's CA/name verification options.

## Record shape

The JSON decoder preserves every pg_logtap field. Vector 0.57.0 also adds
source metadata at the top level:

| Source | Added fields |
|---|---|
| `http_server` | `source_type = "http_server"`, request `path` |
| TCP `socket` | `source_type = "socket"`, peer `port` |

The test file sinks re-encode the object as JSON, so key order can differ from
the wire order. Numeric `seq` values remain exact integers.

## Tested result

In the reproduced DEBUG5+ run, each source received 100 indexed marker events:
20 each at `DEBUG1`, `LOG`, `INFO`, `NOTICE` and `WARNING`. Both files contained
exactly the indexes `0` through `19` at every level, without duplicates, and the
complete files parsed as JSON. Each source also received PostgreSQL internal
records at every level from `DEBUG1` through `DEBUG5`. HTTP request gzip was
enabled, Vector reported no error-level diagnostics, and both senders kept:

```text
events_dropped=0 events_queued=0 send_cycles_failed=0 events_lost=0
```

## Reproduce the test stand

Run all blocks below in the same Bash shell from a working copy of this
repository. The extension comes from GitHub Releases, so Zig and PostgreSQL
development packages are not required. Resource names are unique to the run;
a failure prints available container logs and cleans up automatically.

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
NET="pglogtap-vector-check-net-$RUN_ID"
VECTOR="pglogtap-vector-check-$RUN_ID"
HTTP_PG="pglogtap-vector-check-pg-http-$RUN_ID"
TCP_PG="pglogtap-vector-check-pg-tcp-$RUN_ID"
RUNTIME_DIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)

cleanup() {
  docker rm -fv "$HTTP_PG" "$TCP_PG" "$VECTOR" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$RUNTIME_DIR" "$OUTPUT_DIR"
}

on_exit() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    docker logs "$HTTP_PG" 2>/dev/null || true
    docker logs "$TCP_PG" 2>/dev/null || true
    docker logs "$VECTOR" 2>/dev/null || true
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

Validate the checked-in configuration, then start Vector. Its receiver ports
remain private to the isolated Docker network:

```sh
VECTOR_IMAGE='timberio/vector:0.57.0-alpine@sha256:19e3526faf4d4b1ed0c28a0d68d4cc3a1e13e437099986a5b7a768707907497c'

docker run --rm \
  -v "$PWD/tests/e2e/vector-direct.yaml:/etc/vector/vector.yaml:ro" \
  "$VECTOR_IMAGE" validate /etc/vector/vector.yaml

docker network create "$NET"
docker run -d --name "$VECTOR" \
  --network "$NET" --network-alias vector \
  -v "$PWD/tests/e2e/vector-direct.yaml:/etc/vector/vector.yaml:ro" \
  -v "$OUTPUT_DIR:/var/log/vector" \
  "$VECTOR_IMAGE"

attempt=0
until docker run --rm --network "$NET" alpine:3.20 sh -c \
  'nc -z vector 8686 && nc -z vector 54525'; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf 'Vector did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done
```

Start one PostgreSQL sender per transport. The DEBUG settings are specific to
this test; pg_logtap normally defaults to `level_min=15` (`LOG`).

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

start_pg "$HTTP_PG" 'http://vector:8686' on  vector-http-e2e
start_pg "$TCP_PG"  'tcp://vector:54525'  off vector-tcp-e2e

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

Generate 20 indexed events at each selected level through each source:

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

HTTP_MARKER="vector-http-$(date +%s)"
TCP_MARKER="vector-tcp-$(date +%s)"
emit_matrix "$HTTP_PG" "$HTTP_MARKER"
emit_matrix "$TCP_PG" "$TCP_MARKER"
```

Wait for both complete batches, then verify valid JSON and each exact level/index
set. A final unterminated line is ignored only while Vector is actively
appending; every completed line must parse:

```sh
HTTP_OUT="$OUTPUT_DIR/pg-logtap-http.jsonl"
TCP_OUT="$OUTPUT_DIR/pg-logtap-tcp.jsonl"

marker_count() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
path, marker = pathlib.Path(sys.argv[1]), sys.argv[2]
count = 0
if path.exists():
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if text and not text.endswith("\n"):
        lines = lines[:-1]
    for line in lines:
        row = json.loads(line)
        count += row.get("message", "").startswith(marker + " ")
print(count)
PY
}

attempt=0
while [ "$attempt" -lt 60 ]; do
  http_count=$(marker_count "$HTTP_OUT" "$HTTP_MARKER")
  tcp_count=$(marker_count "$TCP_OUT" "$TCP_MARKER")
  [ "$http_count" -ge 100 ] && [ "$tcp_count" -ge 100 ] && break
  attempt=$((attempt + 1))
  sleep 1
done
[ "$http_count" -eq 100 ]
[ "$tcp_count" -eq 100 ]

python3 - \
  "$HTTP_OUT" "$HTTP_MARKER" HTTP \
  "$TCP_OUT" "$TCP_MARKER" TCP <<'PY'
import collections, json, pathlib, sys
expected_levels = {"DEBUG1", "LOG", "INFO", "NOTICE", "WARNING"}
debug_levels = ("DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5")
for offset in (1, 4):
    path = pathlib.Path(sys.argv[offset])
    marker, transport = sys.argv[offset + 1:offset + 3]
    seen = collections.defaultdict(list)
    internal_debug = collections.Counter()
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if text and not text.endswith("\n"):
        lines = lines[:-1]
    for line in lines:
        row = json.loads(line)
        message = row.get("message", "")
        if message.startswith(marker + " "):
            _, level, index = message.rsplit(" ", 2)
            assert row["level"] == level
            seen[level].append(int(index))
        elif row.get("level") in debug_levels:
            internal_debug[row["level"]] += 1
    assert set(seen) == expected_levels
    for level in sorted(expected_levels):
        assert sorted(seen[level]) == list(range(20))
        print(transport, level, len(seen[level]), "indexes_ok=1")
    for level in debug_levels:
        assert internal_debug[level] > 0, (transport, level, internal_debug)
PY
```

Inspect both senders. Each Boolean result must be `t`:

```sh
for pg in "$HTTP_PG" "$TCP_PG"; do
  docker exec "$pg" psql -U postgres -Atc \
    'SELECT events_dropped = 0
         AND events_queued = 0
         AND send_cycles_failed = 0
         AND events_lost = 0
     FROM pg_logtap_delivery'
  docker exec "$pg" psql -U postgres -Atc 'SELECT pg_logtap_stats()'
done
```

## View received logs

View the most recent records from either source before removing the stand:

```sh
tail -n 50 "$HTTP_OUT"
tail -n 50 "$TCP_OUT"
```

With `jq`, filter by severity or inspect only a generated batch:

```sh
jq 'select(.level == "ERROR" or .level == "FATAL" or .level == "PANIC")' \
  "$HTTP_OUT"

jq --arg marker "$TCP_MARKER" \
  'select(.message | startswith($marker + " "))' \
  "$TCP_OUT"
```

Vector's own operational log is separate:

```sh
docker logs "$VECTOR"
```

Remove only this isolated stand, its anonymous PostgreSQL volumes, downloaded
runtime and received test files:

```sh
trap - EXIT
cleanup
```
