# pg_logtap

`pg_logtap` is a PostgreSQL extension (15–18) that captures server logs and pushes
them out as structured JSON events — to Vector, VictoriaLogs, ClickHouse, or any
HTTP/TCP/file receiver. No log files, no parsers, no sidecar agents. Written in
[Zig](https://ziglang.org).

## Core Concept

Instead of tailing `postgresql.log`, `pg_logtap` hooks into PostgreSQL's logging
pipeline (`emit_log_hook`), normalizes each event in shared memory, and a
background worker pushes them out. The hook fires before formatting, so nothing
about your logging configuration affects the captured data.

```
emit_log_hook ──► shmem ring ──► bgworker ──► JSON ──► receiver (http/tcp/file):
(every backend)   (LWLock)      (one per cluster)    Vector, VictoriaLogs, ClickHouse…
                                                                  │
                                                                  └─► /metrics (Prometheus)
```

Push, not pull: the extension sends events itself; the receiver just accepts
NDJSON over HTTP POST, JSON lines over TCP, or a file. Query strings in the URL
pass through, so some systems ingest directly without a collector in between.

## Features

- **Real-time capture** — hooks `emit_log_hook`; events are captured as `ErrorData`, before formatting.
- **Zero log-config coupling** — any `log_destination`, any `log_line_prefix`, `logging_collector` on or off.
- **Session context built in** — `app` (application_name, %a), `client_host` (client address, %h) — richer than `log_line_prefix` ever gives you.
- **Source identity** — every event carries `host` / `cluster` / `pgdata`, so one central Vector can serve many clusters without confusion.
- **Filtering** — by level and POSIX regex (include/exclude).
- **Loss-free under load** — ring drain is interleaved with sends; verified exact delivery at ~29k events/s.
- **Delivery guarantees** — bounded retry backlog (oldest-dropped, counted in `events_lost`), optional compressed on-disk queue that survives crashes and replays automatically when the receiver returns, gapless `seq` for receiver-side dedup. The full contract, with loss boundaries per failure scenario: [docs/delivery.md](docs/delivery.md).
- **Prometheus metrics** — `/metrics` and `/healthz` built into the worker; no extra exporter.
- **Runtime switching** — `export_url` is re-read on SIGHUP: move a cluster from Vector to ClickHouse without restart.

## PostgreSQL Logging Settings

The extension is indifferent to your logging configuration — it taps the
pipeline before any of it applies:

| Setting | Requirement |
|---|---|
| `logging_collector` | Optional. `off` (default) is fine — stderr keeps going to docker logs / journald, while pg_logtap exports the same events. Collector is only needed for `csvlog`/`jsonlog`/file rotation. |
| `log_destination` | Any; can be left unset (default `stderr`). |
| `log_line_prefix` | Irrelevant — prefix is a formatting-time concern; pg_logtap captures structured fields instead. |
| `log_min_messages` | The one shared filter: events below it never reach the hook. |
| `log_min_duration_statement` | Not a pg_logtap setting, but the usual source of LOG-level events (`0` = log every statement). |

## Installation

### From a release (no toolchain needed)

Grab the package matching your PostgreSQL major from the
[releases page](https://github.com/spa-28/pg_logtap/releases) —
`pg_logtap-<version>-pg<N>-amd64.tar.gz` — and unpack it into the running
installation:

```sh
curl -LO https://github.com/spa-28/pg_logtap/releases/download/v0.2.0/pg_logtap-0.2.0-pg18-amd64.tar.gz
tar -xzf pg_logtap-0.2.0-pg18-amd64.tar.gz          # → lib/ + extension/
sudo install -m 755 lib/pg_logtap.so "$(pg_config --pkglibdir)/pg_logtap.so"
sudo install -m 644 extension/* "$(pg_config --sharedir)/extension/"
```

Release binaries are x86-64, built with ReleaseSafe against glibc 2.28 —
the oldest glibc among current distributions (RHEL 8; glibc is
forward-compatible), so they run on RHEL/Rocky/Alma 8+, Debian 11+,
Ubuntu 20.04+, Amazon Linux 2023. On other architectures or musl, build
from source as below.

### From source

Prerequisites: Zig 0.16.0, `pg_config` for the target major on PATH, and
libpq headers (`postgresql-server-dev-NN` + `libpq-dev` on Debian/Ubuntu) —
the [pgzx](https://github.com/spa-28/pgzx) dependency (git dep in
`build.zig.zon`) translates the server headers and links libpq at build time.

```sh
make && make install          # uses pg_config from PATH
```

Enable (requires restart — the extension needs shared memory and a background
worker):

```ini
shared_preload_libraries = 'pg_logtap'
```

```sql
CREATE EXTENSION pg_logtap;
SELECT pg_logtap_version();
```

On PostgreSQL ≤ 16, `ALTER SYSTEM SET pg_logtap.*` before the first restart is
rejected (GUCs register in `_PG_init`) — enable the preload, restart, then set
GUCs and restart again.

## Configuration

| Option | Default | Context | Description |
|---|---|---|---|
| `pg_logtap.level_min` | `15` (LOG) | SIGHUP | Minimum elevel to capture (10=DEBUG5 … 22=PANIC). |
| `pg_logtap.pattern` | `''` | SIGHUP | POSIX ERE; capture only matching messages. |
| `pg_logtap.pattern_exclude` | `''` | SIGHUP | POSIX ERE; skip matching messages. |
| `pg_logtap.field_query` | `false` | SIGHUP | Capture the current query text with each event. |
| `pg_logtap.ring_capacity` | `1024` (128–8192) | postmaster | Ring buffer size in events. |
| `pg_logtap.export_url` | `''` (no export) | SIGHUP | Destination, see below. |
| `pg_logtap.cluster_name` | `''` | SIGHUP | Cluster label in every event's `cluster` field. Empty = fall back to the server's `cluster_name` GUC (empty by default → field is `null`). |
| `pg_logtap.export_gzip` | `false` | SIGHUP | Compress `http://` batches with `Content-Encoding: gzip` (10–20× less wire). Receiver must accept gzipped request bodies — see Receivers. |
| `pg_logtap.export_fallback_file` | `''` (off) | SIGHUP | Failed `http://`/`tcp://` batches go here instead of being lost: a compressed durable queue (fdatasynced) that the worker replays and truncates itself once the receiver answers — survives restarts. Relative resolves against the data directory. See [docs/delivery.md](docs/delivery.md). |
| `pg_logtap.flush_interval` | `1000` ms | SIGHUP | Push cycle. |
| `pg_logtap.metrics_port` | `0` (off) | SIGHUP | Prometheus `/metrics` + `/healthz` port. |

`export_url` schemes (gzip applies to the `http://` scheme only):

- `http://host:port[/path]` — HTTP/1.1 POST, `application/x-ndjson` (no TLS);
- `tcp://host:port` — raw JSON lines;
- `file:///abs/path` — append, mode 0600, fdatasync per batch (durable across OS crashes).

With `pg_logtap.export_gzip = on` the HTTP body is gzipped
(`Content-Encoding: gzip`) — same NDJSON after decompression, just less
wire. Request-body gzip is *not* universal: Vector `http_server`,
VictoriaLogs/VictoriaMetrics insert endpoints, Fluent Bit `http` and
Logstash `http` inputs decompress it natively; a hand-rolled endpoint that
reads the raw body does not — leave the GUC off for those.

## Receivers

The contract is deliberately trivial — NDJSON over HTTP POST, JSON lines over
TCP or file — so Vector is convenient but not required:

| Receiver | `pg_logtap.export_url` |
|---|---|
| **Vector** (primary) | `http://vector:8686` |
| **VictoriaLogs** direct | `http://vlogs:9428/insert/jsonline?_stream_fields=host,level&_msg_field=message&_time_field=timestamp` |
| **ClickHouse** | `http://ch:8123/?query=INSERT+INTO+logs+FORMAT+JSONEachRow` |
| **Fluent Bit / Fluentd** | HTTP source with JSON |
| **Logstash** | `tcp://logstash:5000` (+ `json_lines` codec) |
| file shippers (filebeat, promtail, rsyslog) | `file:///var/log/pg_logtap.jsonl` + tail |
| your own | any HTTP/TCP endpoint that reads lines |

Not direct (put a collector in between): **Kafka** (binary protocol);
**Loki / Elasticsearch / OpenSearch** (different body format); cloud endpoints
(Datadog, Elastic Cloud) — HTTPS and auth headers, which plaintext export
doesn't do by design. Principle: pg_logtap is a dumb reliable transporter of a
trivial format; transformation, TLS, auth and fan-out are the collector's job.

## Event Format

One JSON object per line:

```json
{
  "seq": 184,
  "timestamp": "2026-08-20T07:30:58.550079Z",
  "level": "ERROR",
  "message": "duplicate key value violates unique constraint",
  "detail": "Key (id)=(1) already exists.",
  "hint": null,
  "context": null,
  "sqlerrcode": "23505",
  "filename": "nbtinsert.c",
  "lineno": 671,
  "funcname": "_bt_check_unique",
  "database": "mydb",
  "user": "app",
  "app": "pgbench",
  "client_host": "10.0.0.7",
  "host": "pg1.example",
  "cluster": "prod-main",
  "pgdata": "/var/lib/postgresql/18/docker",
  "pid": 12345,
  "backend_type": "client backend",
  "query": null,
  "truncated": []
}
```

Notes: `sqlerrcode` is the canonical 5-char SQLSTATE string. `app` /
`client_host` come from the session (`[local]` for unix sockets). `host` /
`cluster` / `pgdata` identify the sending server. `truncated` lists fields cut
on fixed-size copy. Overlong fields are cut on UTF-8 boundaries.

## Monitoring

```sql
SELECT * FROM pg_logtap_delivery;          -- monitoring view, one row (see below)
SELECT pg_logtap_stats();                  -- same counters as compact text
SELECT unnest(pg_logtap_dump(100));        -- last events as JSON, non-destructive
```

Event counters — same names in `pg_logtap_stats()` text, the
`pg_logtap_delivery` view and the Prometheus exposition (each event counted
once per lifecycle stage it passes; stuck in the fallback queue right now =
`events_queued - events_replayed`):

| counter | unit | grows when |
|---|---|---|
| `events_captured` | events | a log line entered the shared ring |
| `events_dropped` | events | the ring was full at capture — worker drain behind the rate |
| `events_sent` | events | delivered to the export URL by a live send |
| `events_queued` | events | durably appended to the fallback file |
| `events_replayed` | events | delivered out of the fallback file after recovery |
| `events_lost` | events | permanently gone: RAM backlog overflow with no fallback file, or an unreadable queue member |
| `send_cycles_failed` | **cycles** | one per flush cycle whose send attempt failed — the receiver-down signal; events are safe, not lost |
| `ring_events` / `ring_capacity` | events | ring fill right now / ring size |

The view adds two derived columns: `queue_backlog` (`events_queued −
events_replayed`, stuck in the file right now) and `delivered`
(`events_sent + events_replayed`, everything handed to a receiver).

With `metrics_port` set: `pg_logtap_{events_captured,events_dropped,
events_sent,events_queued,events_replayed,send_cycles_failed,events_lost}_total`
(counters) + `pg_logtap_ring_{events,capacity}` (gauges),
plus `/healthz`. No TLS/auth — closed networks only. Ready alert rules:
[`alerts/pg_logtap.rules.yml`](alerts/pg_logtap.rules.yml) (events lost, ring
dropped, export failing).

## Development & Testing

The setup follows [pgzx](https://github.com/xataio/pgzx) conventions where they
fit, with two deliberate deviations: no Nix (a docker container is the dev
environment, because the version matrix needs many PostgreSQL installs, not
one relocated one), and Zig pinned to 0.16.0 (pgzx tracks master).

### Dev loop (docker)

```sh
docker run -d --name pglogtap-pg -e POSTGRES_PASSWORD=dev \
  -p 55432:5432 -p 9187:9187 postgres:18
scripts/dev-deploy.sh        # builds in the pgzx-build container, docker cp of .so/.control/.sql
docker exec pglogtap-pg psql -U postgres -qc \
  "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'"
docker restart pglogtap-pg   # .so replacement always requires a restart
```

Locally, `make && make install` does the same against the `pg_config` on PATH
(pgzx's `zig build -p $PG_HOME` pattern, wrapped in the conventional
PostgreSQL-extension interface).

### Testing

```sh
scripts/build.sh 18 test                    # unit tests (any zig build target; needs pg_config)
scripts/build.sh 18 fmt && scripts/build.sh 18 lint   # zig fmt + zlinter
scripts/e2e-vector.sh <pg-container> 20     # 20 events through a real Vector
scripts/e2e-metrics.sh <pg-container> 9187  # /metrics scraped, values checked
scripts/test-matrix.sh                      # build + deploy + e2e + pgbench storm per major
```

`scripts/build.sh [major] [args...]` runs `zig build` inside the `pgzx-build`
container (zig 0.16 + PGDG server-dev 15–18 + libpq); on a machine with a
local `pg_config` plain `zig build` / `make` works too. CI installs
`postgresql-server-dev-$major` per matrix job instead.

Unit tests deliberately differ from pgzx's `SELECT run_tests()` suites (which
run inside a live PostgreSQL): all PostgreSQL interop in pg_logtap is
concentrated in `capture.zig` / `worker.zig`, the rest (`ring`, `filter`,
`jsonl`, `export`, `metrics`) is pure and links without postgres symbols — so
`zig build test` runs standalone and identically across the whole 15–18 matrix.
Behavior that needs a real server is covered by the e2e scripts instead.

Verified on PostgreSQL 15/16/17/18: capture, export, exact delivery under a
pgbench storm (`dropped=0`). CI: `.github/workflows/build.yml` (fmt/lint/test +
per-version matrix). A new major: add it to the CI matrix, extend the
`pgzx-build` container with `postgresql-server-dev-19`.

### Debugging

Extension code runs inside backend processes — attach gdb to the session:

```sql
SELECT pg_backend_pid();
```

The exporter is a separate process (`pg_logtap exporter` in `ps`). Both map the
`.so` at load; replacing it on disk takes effect only after a restart.

### Project layout

```
src/lib.zig        entry: module magic, _PG_init, SQL functions
src/capture.zig    emit_log_hook → ring (all PG glue: hooks, GUCs, LWLock)
src/ring.zig       shmem ring: layout + pure ops + UTF-8 truncation (tested)
src/filter.zig     filters: level_min + POSIX regex via libc regcomp (tested)
src/jsonl.zig      event → JSON line: RFC3339, level names, escaping (tested)
src/export.zig     export_url parsing: http/tcp/file (tested)
src/worker.zig     bgworker exporter: drain, batches, retry backlog, libc IO
src/metrics.zig    /metrics + /healthz: Prometheus text, HTTP reply (tested)
scripts/           build, dev-deploy, e2e-*, test-matrix
```

pgzx comes in as a git dependency (spa-28/pgzx, pinned in `build.zig.zon`):
the 15–18 comptime branches and the Zig 0.16 port live upstream in the fork
instead of being vendored here.

ABI note: a `.so` built against X.Y runs on any X.* of the same major and arch
(headers are build-time only); release builds should target the oldest glibc
you support (e.g. debian:bookworm).

## Releases

The version lives in three places that must stay in sync (CI checks this):
`pg_logtap.control` (`default_version`), the `sql/pg_logtap--X.Y.Z.sql`
filename, and `build.zig.zon`. To cut a release:

```sh
# 1. bump the version in all three files (rename the sql file accordingly)
# 2. commit, tag, push
git tag v0.2.0 && git push origin v0.2.0
# 3. create a Release for the tag in the GitHub UI (or: gh release create v0.2.0)
```

Publishing the Release triggers CI, which rebuilds the matrix and attaches one
package per major as `pg_logtap-<version>-pg<N>-amd64.tar.gz` — a `lib/` +
`extension/` tree ready to untar into the PostgreSQL installation.

## License

MIT. Depends on [pgzx](https://github.com/spa-28/pgzx) (fork of
[xataio/pgzx](https://github.com/xataio/pgzx), Apache-2.0) via a Zig package
dependency.
