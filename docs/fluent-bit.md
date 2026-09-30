# Fluent Bit

pg_logtap can send the same newline-delimited JSON directly to Fluent Bit over
HTTP or raw TCP. Neither path requires Vector or OpenTelemetry Collector:

```text
PostgreSQL + pg_logtap
  ├─ HTTP POST, NDJSON labelled application/json, optional gzip → http input
  └─ raw TCP, one JSON object per line                         → tcp input
```

The checked-in configuration targets:

```text
fluent/fluent-bit:4.0.14
sha256:945b0bdb80ff2886cebedbfa5130d0856877320368b7d9bd0431512907b75177
```

Both paths are available in pg_logtap 0.6.0. The HTTP path requires 0.6.0 or
newer because Fluent Bit needs the configurable `export_http_content_type`
setting.

## Fluent Bit configuration

[`tests/e2e/fluent-bit.conf`](../tests/e2e/fluent-bit.conf) gives each input a
distinct tag and file sink:

```ini
[SERVICE]
    Flush             1
    Log_Level         info

[INPUT]
    Name              http
    Listen            0.0.0.0
    Port              9880
    Buffer_Max_Size   16M

[INPUT]
    Name              tcp
    Listen            0.0.0.0
    Port              5170
    Tag               pg_logtap_tcp
    Format            json
    Separator         \n
    Buffer_Size       16M

[OUTPUT]
    Name              file
    Match             pg_logtap_http
    Path              /var/log/fluent-bit
    File              pg-logtap-http.jsonl
    Format            plain
    Mkdir              true

[OUTPUT]
    Name              file
    Match             pg_logtap_tcp
    Path              /var/log/fluent-bit
    File              pg-logtap-tcp.jsonl
    Format            plain
    Mkdir             true
```

A request to `/pg_logtap_http` receives the URI-derived tag
`pg_logtap_http`; the TCP input uses its explicit `pg_logtap_tcp` tag. The
exact `Match` values keep the two test outputs isolated. `Format plain` writes
the decoded pg_logtap JSON object without adding a Fluent Bit tag/timestamp
wrapper. Replace the file outputs with the required production plugins.

## HTTP (recommended)

```ini
pg_logtap.export_url = 'http://fluent-bit:9880/pg_logtap_http'
pg_logtap.export_http_content_type = 'application/json'
pg_logtap.export_gzip = on
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

Fluent Bit 4.0.14 accepts multiple NDJSON objects in one `application/json`
request and transparently inflates request gzip. It returns HTTP 201; pg_logtap
accepts any 2xx response as acknowledgement of the complete batch. A lost
response can still produce a whole-batch retry, so deduplicate downstream on
`(host, cluster, seq)` when duplicates matter.

The request path is part of the routing contract: `/pg_logtap_http` becomes the
`pg_logtap_http` tag. Do not set the HTTP input's `tag_key` unless records are
intentionally allowed to override that route.

For an untrusted network, put TLS on the HTTP receiver (or a validating TLS
proxy) and use `https://` with pg_logtap's CA/name verification settings.

## TCP

```ini
pg_logtap.export_url = 'tcp://fluent-bit:5170'
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

`Format json` parses each line as one record, and `Separator \n` matches
pg_logtap's TCP framing. TCP has no application-level acknowledgement: a
successful socket write counts as delivered, so live delivery is at-most-once;
fallback replay can overlap data already accepted by Fluent Bit. See
[Delivery contract](delivery.md).

For an untrusted network, use `tcps://` and configure Fluent Bit's TCP input
with `tls on`, a certificate and a private key. Configure
`pg_logtap.export_tls_ca` and, when needed, `export_tls_server_name` on the
sender.

## Why the override is required

Fluent Bit 4.0.14 returns HTTP 400 for
`Content-Type: application/x-ndjson`, with or without gzip. The same NDJSON
body returns a 2xx response and is split into individual records when labelled
`application/json`; gzip also works. `export_http_content_type` changes only
that sender-owned label. `export_http_extra_headers` continues to reject a
second `Content-Type`, avoiding conflicting headers.

## Tested result

A PostgreSQL 18 stand using the pg_logtap 0.6.0 build was checked directly
against both Fluent Bit inputs. It received exactly 20/20 HTTP events and 20/20
TCP events. The HTTP request used `application/json` with gzip; both outputs
contained valid JSON, the route markers stayed isolated, and
`events_dropped`, `send_cycles_failed` and `events_lost` did not increase.

The released 0.5.2 TCP stand below received 100 indexed events: 20 each at
`DEBUG1`, `LOG`, `INFO`, `NOTICE` and `WARNING`, with exact indexes and valid
JSON. DEBUG5+ capture also produced PostgreSQL internal records at every level
from `DEBUG1` through `DEBUG5`; the sender kept
`events_dropped=0 events_queued=0 send_cycles_failed=0 events_lost=0`.

## Reproduce the released 0.5.2 TCP stand

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
NET="pglogtap-fluent-bit-check-net-$RUN_ID"
FB="pglogtap-fluent-bit-check-$RUN_ID"
PG="pglogtap-fluent-bit-check-pg-$RUN_ID"
RUNTIME_DIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)

cleanup() {
  docker rm -fv "$PG" "$FB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$RUNTIME_DIR" "$OUTPUT_DIR"
}

on_exit() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    docker logs "$PG" 2>/dev/null || true
    docker logs "$FB" 2>/dev/null || true
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

Start Fluent Bit with the checked-in configuration. No receiver port is
published to the host:

```sh
docker network create "$NET"

docker run -d --name "$FB" \
  --network "$NET" --network-alias fluent-bit \
  -v "$PWD/tests/e2e/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro" \
  -v "$OUTPUT_DIR:/var/log/fluent-bit" \
  fluent/fluent-bit:4.0.14@sha256:945b0bdb80ff2886cebedbfa5130d0856877320368b7d9bd0431512907b75177 \
  /fluent-bit/bin/fluent-bit -c /fluent-bit/etc/fluent-bit.conf

attempt=0
while :; do
  fb_logs=$(docker logs "$FB" 2>&1)
  if printf '%s\n' "$fb_logs" | grep -F '[input:http:http.' >/dev/null && \
     printf '%s\n' "$fb_logs" | grep -F '[input:tcp:tcp.' >/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf 'Fluent Bit did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done
```

Start PostgreSQL with DEBUG5+ capture. These DEBUG settings are specific to the
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
  -c pg_logtap.export_url=tcp://fluent-bit:5170 \
  -c pg_logtap.export_fallback_file=pg_logtap-fallback.bin \
  -c pg_logtap.flush_interval=100 \
  -c pg_logtap.cluster_name=fluent-bit-e2e

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

Generate 20 indexed events at each selected level:

```sh
MARKER="fluent-bit-direct-$(date +%s)"
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

Wait for the complete batch and verify the exact level/index matrix:

```sh
OUT="$OUTPUT_DIR/pg-logtap-tcp.jsonl"
attempt=0
count=0
while [ "$attempt" -lt 60 ]; do
  if [ -f "$OUT" ]; then
    count=$(python3 - "$OUT" "$MARKER" <<'PY'
import json, pathlib, sys
path, marker = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
if text and not text.endswith("\n"):
    lines = lines[:-1]
print(sum(json.loads(line).get("message", "").startswith(marker + " ")
          for line in lines))
PY
)
  fi
  [ "$count" -ge 100 ] && break
  attempt=$((attempt + 1))
  sleep 1
done
[ "$count" -eq 100 ]

python3 - "$OUT" "$MARKER" <<'PY'
import collections, json, pathlib, sys
path, marker = pathlib.Path(sys.argv[1]), sys.argv[2]
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
    elif row.get("level") in {"DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5"}:
        internal_debug[row["level"]] += 1

expected = {"DEBUG1", "LOG", "INFO", "NOTICE", "WARNING"}
assert set(seen) == expected
for level in sorted(expected):
    assert sorted(seen[level]) == list(range(20))
    print(level, len(seen[level]), "indexes_ok=1")
for level in ("DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5"):
    assert internal_debug[level] > 0, (level, internal_debug)
PY
```

Check the sender counters. The Boolean result must be `t`; `events_sent` can be
higher than 100 because the test also captures PostgreSQL's internal logs:

```sh
docker exec "$PG" psql -U postgres -Atc \
  'SELECT events_dropped = 0
       AND events_queued = 0
       AND send_cycles_failed = 0
       AND events_lost = 0
   FROM pg_logtap_delivery'

docker exec "$PG" psql -U postgres -Atc 'SELECT pg_logtap_stats()'
```

## View received logs

The file sink writes one pg_logtap JSON object per line. View the latest events
before removing the stand:

```sh
tail -n 50 "$OUTPUT_DIR/pg-logtap-tcp.jsonl"
```

If `jq` is available, pretty-print the stream or select severe events:

```sh
jq . "$OUTPUT_DIR/pg-logtap-tcp.jsonl"
jq 'select(.level == "ERROR" or .level == "FATAL" or .level == "PANIC")' \
  "$OUTPUT_DIR/pg-logtap-tcp.jsonl"
```

Inspect only the generated batch:

```sh
jq --arg marker "$MARKER" \
  'select(.message | startswith($marker + " "))' \
  "$OUTPUT_DIR/pg-logtap-tcp.jsonl"
```

Fluent Bit's own operational log is separate:

```sh
docker logs "$FB"
```

Remove only this isolated stand, its anonymous PostgreSQL volume, downloaded
runtime and received test file:

```sh
trap - EXIT
cleanup
```
