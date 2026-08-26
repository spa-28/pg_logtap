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
- **Capture-time redaction** — the `password` token in statement text is cut before anything leaves the server; an opt-in regex masks tokens/PII in every text field ([details](#sensitive-data-in-events)).
- **Loss-free under load** — ring drain is interleaved with sends; verified exact delivery at ~45k events/s sustained for 5 minutes (OLTP overhead and latency percentiles, measured before/after the extension: [docs/bench.md](docs/bench.md)), and 0 lost across an 11M-event debug storm with a 10-minute receiver outage (full numbers: [docs/delivery.md](docs/delivery.md)).
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
curl -LO https://github.com/spa-28/pg_logtap/releases/download/v0.2.1/pg_logtap-0.2.1-pg18-amd64.tar.gz
tar -xzf pg_logtap-0.2.1-pg18-amd64.tar.gz          # → lib/ + extension/
sudo install -m 755 lib/pg_logtap.so "$(pg_config --pkglibdir)/pg_logtap.so"
sudo install -m 644 extension/* "$(pg_config --sharedir)/extension/"
```

Release binaries cover **amd64 and arm64**, built with ReleaseSafe against
glibc 2.28 — the oldest glibc among current distributions (RHEL 8, both
arches; glibc is forward-compatible), so they run on RHEL/Rocky/Alma 8+,
Debian 11+, Ubuntu 20.04+, Amazon Linux 2023 — including their arm64 ports.
On other architectures or musl, build from source as below.

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
| `pg_logtap.level_min` | `15` (LOG) | SIGHUP | Minimum elevel to capture (10=DEBUG5 … 23=PANIC — see the level table below). |
| `pg_logtap.pattern` | `''` | SIGHUP | POSIX ERE; capture only matching messages. Plain EREs are linear on glibc/musl (measured ≤3 ms at 1000 chars), but avoid backreferences (`\1`) — they drop glibc off its fast matcher (measured ~20 s worst case at the 1024-byte message cap; matching runs in every logging backend). |
| `pg_logtap.pattern_exclude` | `''` | SIGHUP | POSIX ERE; skip matching messages. |
| `pg_logtap.field_query` | `false` | SIGHUP | Capture the current query text with each event. ⚠ sensitive — see below. |
| `pg_logtap.redact_pattern` | `''` (off) | SIGHUP | POSIX ERE; every match in `message`/`detail`/`hint`/`context`/`query` is replaced with `<REDACTED>` **at capture** — masked text is what travels the wire, sits in the ring and in the fallback file. Best-effort like any pattern-based masking; avoid backreferences (see `pattern`). |
| `pg_logtap.ring_capacity` | `1024` (128–8192) | postmaster | Ring buffer size in events. |
| `pg_logtap.export_url` | `''` (no export) | SIGHUP | Destination, see below. |
| `pg_logtap.cluster_name` | `''` | SIGHUP | Cluster label in every event's `cluster` field. Empty = fall back to the server's `cluster_name` GUC (empty by default → field is `null`). |
| `pg_logtap.export_gzip` | `false` | SIGHUP | Compress `http://` batches with `Content-Encoding: gzip` (10–20× less wire). Receiver must accept gzipped request bodies — see Receivers. |
| `pg_logtap.export_fallback_file` | `''` (off) | SIGHUP | Failed `http://`/`tcp://` batches go here instead of being lost: a compressed durable queue (fdatasynced) that the worker replays and truncates itself once the receiver answers — survives restarts. Relative resolves against the data directory. See [docs/delivery.md](docs/delivery.md). |
| `pg_logtap.flush_interval` | `1000` ms | SIGHUP | Push cycle. |
| `pg_logtap.export_timeout_ms` | `5000` ms | SIGHUP | connect/send/receive timeout on export sockets — a receiver that accepts but never answers fails the send after this instead of hanging the worker (the batch retries via the usual path). |
| `pg_logtap.export_slow_ms` | `250` ms | SIGHUP | a live send that answers but takes at least this long means the receiver cannot keep up: while it stays this slow, live batches park on the `export_fallback_file` instead of piling up in RAM (a slow round trip would otherwise stall the worker and starve capture); a fast send on the drain path clears the flag. `0` = off. |
| `pg_logtap.export_backlog_max` | `65536` events | SIGHUP | RAM backlog depth before the oldest events are trimmed (`events_lost`). Absorbs throughput spikes while batches park on disk; sustained parking matches capture, so trimming at this depth signals real capacity shortfall, not noise. Ceiling cost ≈ depth × ring slot (~3.4 KB), touched only when parking falls behind. Clamped up to `ring_capacity`. |
| `pg_logtap.fallback_max_mb` | `512` MB | SIGHUP | Size cap for `export_fallback_file`: once an append pushes the file past it, the file is compacted to the newest half of the cap (atomic rewrite; dropped undelivered events count as `events_lost`). `0` = unlimited (the 0.2.1 behavior — grows until the disk is full). A cap smaller than one queue member (~a hundred KB compressed) bounds the file only at member granularity. |
| `pg_logtap.metrics_port` | `0` (off) | SIGHUP | Prometheus `/metrics` + `/healthz` port. |
| `pg_logtap.metrics_addr` | `127.0.0.1` | SIGHUP | Bind address for the metrics listener (IP literal, v4/v6). Loopback by default — the counters name the host, cluster and data directory; set `0.0.0.0` when a scraper on the network needs them. |

### Setting the minimum level

`pg_logtap.level_min` is the numeric PostgreSQL elevel; every event at or
above it is exported, everything below is dropped at capture (before the
ring — it never occupies memory, never counts in the stats):

| value | level | what you get |
|---|---|---|
| `10`–`14` | DEBUG5 … DEBUG1 | everything, including per-statement debug noise — storm volumes, use for troubleshooting only |
| `15` | LOG | server operational messages: connections, checkpoints, autovacuum, duration lines from `log_min_duration_statement` — **the default** |
| `16`–`18` | LOG_SERVER_ONLY / INFO / NOTICE | user-facing informational messages (RAISE INFO/NOTICE) plus LOG |
| `19` | WARNING | warnings and everything above — the usual "no noise" export |
| `21` | ERROR | errors only |
| `22`/`23` | FATAL / PANIC | crash-level events only |

Two filters stack, and both must let an event through: the server's own
`log_min_messages` decides whether a line reaches the hook at all, then
`level_min` decides whether pg_logtap exports it. So an export of
`level_min = 21` (ERROR) with the default `log_min_messages = warning`
works as expected, but `level_min = 15` (LOG) exports LOG lines only if the
server also logs them (`log_min_messages = log` or lower). One PostgreSQL
quirk to keep in mind: in `log_min_messages` the server ranks `LOG` between
`ERROR` and `FATAL` for its own output, while `level_min` uses the raw
elevel numbers, where LOG is 15.

Apply without a restart — both settings reload on SIGHUP:

```sql
ALTER SYSTEM SET pg_logtap.level_min = 19;   -- WARNING and up
SELECT pg_reload_conf();
```

Only `ring_capacity` (postmaster context) and `shared_preload_libraries`
itself need a restart. On PostgreSQL ≤ 16, the first `ALTER SYSTEM SET
pg_logtap.*` is rejected until the extension has loaded once — preload,
restart, then set GUCs.

A typical first setup, end to end:

```ini
# postgresql.conf (or ALTER SYSTEM): the tap itself
shared_preload_libraries = 'pg_logtap'
```

```sql
-- after restart:
CREATE EXTENSION pg_logtap;
ALTER SYSTEM SET pg_logtap.export_url = 'http://vector:8686';
ALTER SYSTEM SET pg_logtap.level_min = 19;            -- warnings and up
ALTER SYSTEM SET pg_logtap.pattern_exclude = 'checkpoint complete:.*';
SELECT pg_reload_conf();

-- verify: emit a warning, watch it arrive, then check the counters
DO $$ BEGIN RAISE WARNING 'hello from pg_logtap'; END $$;
SELECT pg_logtap_stats();
```

### Sizing the ring buffer

`pg_logtap.ring_capacity` (postmaster — a restart applies it) is how many
events fit between the logging backends and the worker: backends push into
the ring under an LWLock, the worker drains it every `flush_interval`. It is
a **spike absorber, not a queue** — the worker sustains tens of thousands of
events per second, so the default `1024` only has to cover what accumulates
between two push cycles. When it fills, new events are refused and counted
in `events_dropped` — a live receiver should never get there.

Leave it alone unless `/metrics` shows `events_dropped` growing while the
receiver is up (spiky capture, e.g. `level_min = 10` debug storms or
connection bursts on `log_connections`). Memory cost is `capacity × slot
(≈3.4 KB)`: `8192` (the max) ≈ 28 MB of shared memory, paid at boot. A slow
or dead receiver is *not* a ring problem — that is what `export_backlog_max`
and the fallback file absorb (next section).

### Tuning delivery

All SIGHUP — re-tune on a running cluster:

- `flush_interval` — the push cycle. Lower = fresher events at the receiver,
  higher = larger batches (less HTTP overhead). 1000 ms suits most setups.
- `export_timeout_ms` — connect/send/receive timeout for export sockets; a
  receiver that accepts but never answers fails a batch after this instead
  of stalling the worker.
- `export_slow_ms` — once a live send takes at least this long, live batches
  park on the `export_fallback_file` instead of piling up in RAM while the
  receiver limps; `0` disables the parking.
- `export_backlog_max` — RAM backlog depth before the oldest events are
  trimmed (`events_lost`). Ceiling cost ≈ depth × 3.4 KB, paid only while
  parking falls behind.

The full delivery contract — what is guaranteed, what is counted, and the
loss boundaries per failure scenario — is
[docs/delivery.md](docs/delivery.md).

### Sensitive data in events

Query text can carry secrets — passwords (`CREATE ROLE ... PASSWORD`),
tokens, personal data — and two independent paths ship it: `field_query`
(whole query as a field) and `log_min_duration_statement` / `log_statement`
(query text inside the `message` of duration lines, regardless of
`field_query`). PostgreSQL itself logs those statements the same way, so the
exposure follows your existing logging posture — but an export destination
extends the audience. Two layers mask such text **at capture** — the ring,
the fallback file and the receiver all hold the masked form only:

- **Password cut, always on.** When the captured `query` field, or a
  `message` line that embeds a statement — `statement: ...` from
  `log_statement` / `log_min_duration_statement`, and the extended-protocol
  phase lines `parse <name>: ...` / `bind ...` / `execute <name>: ...` that
  JDBC, psycopg and `pgbench -M extended` produce (same GUCs, no
  `statement:` marker) — contains the standalone word `password`
  (case-insensitive, word boundaries respected — `user_passwords` does not
  trigger it), everything after that word is dropped and replaced with
  `<REDACTED>`:

  ```
  duration: 3.2 ms  statement: CREATE ROLE app PASSWORD 'hunter2'
  → duration: 3.2 ms  statement: CREATE ROLE app PASSWORD <REDACTED>
  ```

  A message that merely mentions the word (a warning, an app-level line) is
  not statement text and passes verbatim. The cut covers the common
  `PASSWORD '...'` shapes, not every way a secret can be encoded in SQL.
- **`pg_logtap.redact_pattern`** — a POSIX ERE applied to
  `message`/`detail`/`hint`/`context`/`query`; every match becomes
  `<REDACTED>`:

  ```sh
  ALTER SYSTEM SET pg_logtap.redact_pattern = 'sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9._-]+';
  SELECT pg_reload_conf();
  ```

  Empty (the default) disables the layer. It runs in every logging backend,
  so keep the pattern plain (see the backreference note under `pattern`), and
  treat it as damage reduction: any single pattern can be evaded by a
  determined writer, and a masked field is still evidence that something
  sensitive was there.

On top of that, the operational knobs:

- keep `field_query` off (the default) and be deliberate about
  `log_min_duration_statement`;
- keep `log_parameter_max_length`/`log_parameter_max_length_on_error` at
  `-1` (the default): when they are set, PostgreSQL puts **bind-parameter
  values** into the event's `DETAIL` — and the password cut never fires
  there (its statement-marker gate applies to `message`/`query`), so a
  bound secret ships unless your `redact_pattern` catches it;
- `pg_logtap.pattern_exclude` suppresses whole events at capture — e.g.
  `'PASSWORD|IDENTIFIED BY'` never leaves the server at all;
- scrub at the collector — Vector's `redact` transform (built-in filters for
  emails/SSNs/custom regex) still applies to whatever else slips through.

`export_url` schemes (gzip applies to the `http://` scheme only):

- `http://host:port[/path]` — HTTP/1.1 POST, `application/x-ndjson` (no TLS). Hostnames resolve via getaddrinfo on every dial — resolution is bounded by resolver timeouts, not `export_timeout_ms`; IP literals skip it;
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
  "truncated": [],
  "redacted": []
}
```

Notes: `sqlerrcode` is the canonical 5-char SQLSTATE string. `app` /
`client_host` come from the session (`[local]` for unix sockets). `host` /
`cluster` / `pgdata` identify the sending server. Fields are copied into
fixed-size slots — `message` up to 1024 bytes, other fields up to 256; invalid
bytes become U+FFFD. One event per log record, never split. A field can be cut
for two different reasons, reported as separate arrays:
`truncated` names fields that did not fit their slot (the tail is gone —
fetch the full record from the server log if needed); `redacted` names fields
a redaction layer had to clip at its scratch size — PII context beyond the
clip may be gone. Both cuts back off to a UTF-8 character boundary, and a
field can appear in both arrays.

## Monitoring

```sql
SELECT * FROM pg_logtap_delivery;          -- monitoring view, one row (see below)
SELECT pg_logtap_stats();                  -- same counters as compact text
SELECT unnest(pg_logtap_dump(100));        -- last events as JSON, non-destructive
```

Privileges: `pg_logtap_dump` exposes other sessions' log content (queries,
errors) and is owner-only by default — GRANT EXECUTE to a specific role if a
monitoring user needs it. The counters (`pg_logtap_stats()`,
`pg_logtap_stats_json()`, the view) are executable/readable by the built-in
`pg_monitor` role and the owner; nobody else.

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
| `events_lost` | events | permanently gone: RAM backlog overflow — capture sustained past export capacity (or receiver down with no fallback file) — or an unreadable queue member |
| `send_cycles_failed` | **cycles** | one per flush cycle whose send attempt failed — the receiver-down signal; events are safe, not lost |
| `ring_events` / `ring_capacity` | events | ring fill right now / ring size |

The view adds two derived columns: `queue_backlog` (`events_queued −
events_replayed`, stuck in the file right now) and `delivered`
(`events_sent + events_replayed`, everything handed to a receiver).

With `metrics_port` set: `pg_logtap_{events_captured,events_dropped,
events_sent,events_queued,events_replayed,send_cycles_failed,events_lost}_total`
(counters) + `pg_logtap_ring_{events,capacity}` and
`pg_logtap_{dns_fail_streak,fallback_broken,redact_pattern_failed}` (gauges),
plus `/healthz`. No TLS/auth — closed networks only. Ready alert rules:
[`alerts/pg_logtap.rules.yml`](alerts/pg_logtap.rules.yml) (events lost, ring
dropped, export failing, fallback file broken, DNS failing, redact pattern
failed).

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

The e2e suites run against a docker-compose stand — postgres plus the
receivers, brought up gated on real readiness (pg healthcheck, the
receiver's port actually accepting):

```sh
PG_MAJOR=18 docker compose -f tests/e2e/compose.yaml up -d
# deploy the build into it, then:
scripts/e2e-vector.sh pglogtap-e2e 20        # 20 events through a real Vector
scripts/e2e-vlogs.sh pglogtap-e2e 50         # Vector → VictoriaLogs: exactly 50 arrive
scripts/e2e-kill.sh pglogtap-e2e             # failure modes: receiver outage, SIGKILL postmaster, fallback queue replay, torn tail, worker crash/TERM, graceful stop
scripts/e2e-robust.sh pglogtap-e2e           # huge fields past slot caps, backend SIGKILL mid-emit (the PANIC path), 60k-event storm into a dead receiver: bounded RAM, exact loss accounting
scripts/e2e-hook-chain.sh pglogtap-e2e       # another emit_log_hook extension: chained, not replaced
scripts/e2e-metrics.sh pglogtap-e2e 9187     # /metrics scraped, values checked
scripts/e2e-silent-receiver.sh pglogtap-e2e  # mute receiver: timeout fires, fallback absorbs, /healthz alive
scripts/e2e-slow-receiver.sh pglogtap-e2e    # slow receiver: batches park losslessly (export_slow_ms), queue drains on recovery
scripts/test-matrix.sh                       # per major: build + deploy into the stand + every suite + pgbench storm
PHASES=stand,bench scripts/test-matrix.sh 300 18  # overhead benchmark: 6 pgbench jobs before/after the extension (docs/bench.md)
scripts/build.sh 18 test                     # unit tests (any zig build target; needs pg_config)
scripts/build.sh 18 fmt && scripts/build.sh 18 lint   # zig fmt + zlinter
```

`test-matrix.sh` runs each stage as a phase; `PHASES=storm,kill
scripts/test-matrix.sh 5 18` replays a subset against a stand the full run
brought up — for load-shaped local research.

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
pgbench storm (`dropped=0`), and the failure/robustness classes — receiver
outage and slow/mute receivers, postmaster SIGKILL, worker crash and TERM
mid-send, fallback-queue replay with torn tails, fields past slot caps, a
logging backend SIGKILLed mid-emit (the emergency-restart path a PANIC
takes), 60k-event storm into a dead receiver with bounded RAM and exact loss
accounting. CI: `.github/workflows/build.yml` (fmt/lint/test + per-version
matrix). A new major: add it to the CI matrix, extend the `pgzx-build`
container with `postgresql-server-dev-19`.

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

The version lives in four places that must stay in sync (CI checks this):
`pg_logtap.control` (`default_version`), the `sql/pg_logtap--X.Y.Z.sql`
filename, `build.zig.zon`, and `src/version.zig` (what
`pg_logtap_version()` returns). To cut a release:

```sh
# 1. bump the version in all three files (rename the sql file accordingly)
# 2. add sql/pg_logtap--<old>--<new>.sql — the delta script (comment-only if
#    the SQL didn't change); every version needs one, it is the ALTER EXTENSION
#    UPDATE hop, and chains compose (0.1.0 → 0.2.0 → 0.3.0 in one command)
# 3. commit, tag, push
git tag v0.2.1 && git push origin v0.2.1
# 4. create a Release for the tag in the GitHub UI (or: gh release create v0.2.1)
```

Publishing the Release triggers CI, which rebuilds the matrix (PG majors ×
amd64/arm64, each arch natively on its own runner) and attaches one package
per combination as `pg_logtap-<version>-pg<N>-<arch>.tar.gz` — a `lib/` +
`extension/` tree ready to untar into the PostgreSQL installation.

## Roadmap

Deferred designs and known ceilings live in [`docs/TODO.md`](docs/TODO.md).

## License

MIT. Depends on [pgzx](https://github.com/spa-28/pgzx) (fork of
[xataio/pgzx](https://github.com/xataio/pgzx), Apache-2.0) via a Zig package
dependency.
