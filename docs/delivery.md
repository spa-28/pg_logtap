# Delivery contract

What pg_logtap promises, per failure scenario, with numbers. The assumptions:
`ring_capacity` = R (default 1024, max 8192, POSTMASTER), capture rate = r events/s,
`flush_interval` = f (default 1000 ms), RAM backlog depth =
`export_backlog_max` (default 65536, SIGHUP). One event's slot in shared memory
is `message_max + ~2.4 KB` (default width ≈ 3.4 KB — an 8192-slot ring ≈ 28 MB;
at `message_max = 1 MB` the same ring is ≈ 8.6 GB, and the RAM backlog ceiling
likewise scales: `export_backlog_max × (message_max + ~2.4 KB)`). Counters are
**per cluster life** — shared memory dies
with the postmaster, so `pg_logtap_stats()` (and the `pg_logtap_delivery`
view) restarts from zero on every restart.

## Semantics per destination

| Scheme | Semantics | ACK | Duplicate window |
|---|---|---|---|
| `http://` | **at-least-once**, batch granularity (≤ 256 events/chunk) | any HTTP 2xx status line | server persisted the body but the response was lost → whole chunk resent |
| `tcp://` | **at-most-once** | none — `write(2)` success counts as delivered | none; a receiver dying after accept loses silently. Use `http://` for loss-sensitive receivers |
| `file://` | durable append (O_APPEND, 0600) + **fdatasync per batch** | the write itself | a failed partial write rolls the file back to the last full batch and retries it whole on the next cycle |
| fallback queue | durable (fdatasynced once per flush cycle), **replayed automatically** on recovery | the write itself | a crash mid-replay restarts from byte 0 → already-delivered members resent; the receiver may also have accepted the failed send that queued them |

Three honesty notes on those ACKs. `http://`: **any 2xx** counts as
delivered — the standard semantics of HTTP log receivers (Vector,
VictoriaLogs, Fluent Bit), but a proxy that answers 200 without
forwarding defeats any status check you could make. `tcp://`: the
protocol has no framing or ACK, so a **partial write can tear the last
line** mid-batch — the receiver's codec must tolerate or resync (a
length-delimited codec does; a strict line parser will not). `file://`:
the rollback above makes the file whole batches only — a receiver
reading it concurrently may see a batch disappear for the length of
the retry, then reappear complete.

Measured end-to-end (v0.3.0, pg_logtap → Vector http → VictoriaLogs
jsonline insert, docker stand, warning-size lines): a 1000-event batch
becomes queryable in VictoriaLogs ~2 s after generation — one
`flush_interval` plus Vector's sink batch (~1 s each); a 60 000-event
burst is fully queryable within 3 s. The receiver chain absorbs
capture-rate bursts; it is not the bottleneck (a dead-endpoint storm
captures at ~12 k ev/s, above).

Everywhere, **dedup by `(host, seq)`** (recipe below) makes at-least-once
effectively exactly-once.

## Ordering and identity

One export worker per cluster → strict **FIFO** by capture order; `seq` is
gapless and increasing within a batch and across batches. Capture-time drops do
not consume `seq`, so a gap in `seq` on the receiver always means loss, never
reordering.

`seq` is seeded from the wall clock (µs since 2000-01-01, ~8·10¹⁴ < 2⁵³ —
JSON/JS-safe) at shared-memory init. Each second of uptime advances the seed by
10⁶ µs but consumes fewer than 10⁶ values unless capture exceeds 1M events/s,
so `seq` never repeats on a host across restarts and `(host, seq)` is a safe
dedup key long-term. Caveat: a wall clock stepped backwards can regress the
seed; for absolute safety dedup on `(host, seq, timestamp)`.

Receiver-side dedup recipe (Vector):

```yaml
transforms:
  dedup:
    type: dedup
    inputs: ["pg_logtap"]
    fields.match: ["host", "seq"]
    cache.num_events: 100000   # ~one retry window of duplicates
```

## What is never captured

The hook skips lines logged by processes without a PGPROC — in practice the
postmaster itself. This is not negotiable: during an emergency restart the
postmaster logs from inside PGSharedMemoryCreate, after the old shared-memory
segment is unmapped, and even reading the capture state SEGVs there. Its lines
still reach the ordinary server log (stderr/csvlog) — they are just not
exported: shutdown requests ("received fast shutdown request"), the shutdown
sequence itself, fatal postmaster decisions ("terminating any other active
server processes"), FATALs about missing sockets or lock files. The **startup
process does have a PGPROC**, so crash-recovery lines — "database system was
interrupted", "database system was ready to accept read-only connections" —
**are** captured and exported like any backend line.

## Loss boundaries per scenario

Buffers: the shmem ring (≤ R events) + the worker RAM backlog (trimmed to the
newest `export_backlog_max` events, 65536 by default). Everything else is
already delivered.

### Worker pinned in one send

While the worker sits in a single blocked send — up to `export_timeout_ms`
against a receiver that accepted the connection but never answers — backends
keep capturing, and only the ring absorbs it. Capture drops start when

```
r × export_timeout_ms > ring_capacity        (events/s × s > events)
```

With defaults (R = 1024, timeout 5 s) that is a mere ~205 ev/s; at 1 k ev/s
either raise `ring_capacity` to 8192 (POSTMASTER, ~28 MB shmem — buys 8 s) or
cut `export_timeout_ms` to a few hundred ms. This is the structural reason a
mute-but-accepting receiver is the worst case for capture, worse than a dead
one (connection refused fails in milliseconds and the batch parks on the
fallback file).

### Receiver down for T minutes

Without a fallback file, events survive downtime only while they fit in
ring + backlog. **Zero-loss downtime ≈ export_backlog_max / r** (the ring is
negligible next to it):

| export_backlog_max | @100 ev/s | @1 k ev/s | @8 k ev/s (debug storm) |
|---|---|---|---|
| 65536 (default) | 10.9 min | 65 s | 8 s |
| 16384 (low-RAM box) | 2.7 min | 16 s | 2 s |

Beyond that the backlog drops **oldest-first** (`events_lost`), and on recovery
the newest `export_backlog_max` events are delivered. 10 min at 1 k ev/s ≈ 600k
events → ~535k lost, 65536 delivered. With `export_fallback_file` set (below):
**zero lost, for any T** — failed batches are diverted to a compressed
on-disk queue and replayed when the receiver answers.

### Postmaster SIGKILL / node crash

Without a fallback file, both buffers are volatile. Everything
captured-but-not-yet-delivered is lost: **up to R + export_backlog_max events,
uncounted** (the counters die with the shmem). Graceful shutdown
(SIGTERM/postmaster stop) runs one final flush first, bounded twice over: the
whole flush gets ~1 s of work plus one send timeout (enforced between syscalls
— a dribbling receiver cannot stretch a single send past the socket timeout it
already survived), and a **second SIGTERM** to the worker closes the in-flight
connection and exits immediately. Whatever the flush cannot deliver live is
parked to the fallback file in full (parking is local-disk work with no
deadline); SIGKILL skips all of it.
With `export_fallback_file` set, the queue is on disk and **survives the
crash** — the restarted worker replays it; the exposure shrinks to roughly one
`flush_interval` of events (in RAM at the moment of the kill) plus the
in-flight chunk.

### Export worker crash

A bgworker dying by signal is treated by the postmaster like a backend crash:
**emergency restart of the whole cluster** → identical to a postmaster crash. The capture path
(emit_log_hook → ring) never touches the worker, so database logging is not
blocked for an instant either way. A soft worker exit is auto-restarted after
1 s: ring and counters survive (shmem intact), but the RAM backlog
(≤ export_backlog_max events) vanishes uncounted.

### Disk full

pg_logtap uses no disk while exporting over the network — shmem, RAM and
sockets only; capture and export are unaffected (PostgreSQL itself will fail
on WAL writes first — a different failure domain). A full disk does close the
fallback queue: appends fail, and events fall back to the RAM-backlog behavior
above (oldest-first loss once the backlog is full, counted in `events_lost`).
A `file://` destination on a full disk behaves the same way.

## The fallback queue

```ini
pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'
```

A relative path resolves against the data directory (the `log_directory`
convention), so the file lives with your data by default; an absolute path
works too. Keep it there — not in `/tmp` or `/var/log`: it is the durable copy
and must survive reboots and log cleanup.

When an `http://`/`tcp://` send fails and the path is set, the batch is
appended to the queue — one **gzip member per batch** behind a length framing
(`PGLTFB01` magic, 0600, fdatasynced once per flush cycle) — and counted as
`events_queued`: it left pg_logtap durably, and is counted again as
`events_replayed` when delivered. The queue is an internal format, not a
tailable log.
Once the receiver answers, the worker drains the queue in order, sends the
members, and truncates the file back to empty; no shipper, rotation or manual
step is involved. On restart the same replay happens automatically (the
`fallback-queue` scenario of `scripts/e2e-kill.sh`: SIGKILL with a full
queue, receiver back after boot → all events delivered, queue empty, zero
duplicate seqs).

Crash windows: a crash mid-append leaves a torn trailing member — detected and
truncated on the next read. A crash mid-replay loses only the in-memory
offset: replay restarts from byte 0, so the receiver can see already-delivered
members again — dedup by `(host, seq)` as above makes that harmless. Events
may also appear twice because the failed send that queued them may have
partially landed — same dedup.

The truncate-when-drained order (ftruncate first, then the consumer offset
resets) was chosen over the reverse deliberately: the offset is worker-local
state, so it dies with the process in every crash scenario that could land
between the two statements — the reverse order would instead create a *live*
window where a failed ftruncate leaves an empty-looking file that gets
re-flooded by replay of the whole queue, doubling it on every attempt.

Two clusters must never share one fallback file (or one absolute path on a
shared volume): both writers share the framing magic, and their interleaved
appends tear each other's members — both queues then read as corrupt and
disable themselves. One file per cluster; `cluster_name` keeps the events
apart downstream.

### Size cap: `fallback_max_mb`

The queue grows without bound through an outage — by default until the disk
is full (then the RAM-backlog loss semantics take over). `pg_logtap.
fallback_max_mb` (default 512, `0` = unlimited) bounds it instead: once an
append pushes the file past the cap, it is compacted to the **newest half of
the cap** (atomic tmp+rename rewrite; the worker stalls for that one flush
cycle). Delivered members at the head are dropped free; undelivered dropped
members count into **both** `events_compacted` (they left the queue — keeps
`queue_backlog = queued − replayed − compacted` truthful, and `delivered =
sent + replayed` counts only events a receiver actually got) and
`events_lost` (they never arrived — `PgLogtapEventsLost` fires, correctly
reading "the outage outlasted the queue"). After recovery the newest ≈ cap/2
of data is delivered in order.
A cap smaller than one member (~a hundred KB compressed) bounds the file
only at member granularity. Fill rate measured (v0.3.0, one 16-core
host, 8-client pgbench with every statement duration-logged into a dead
endpoint — the debug-storm profile): 0.82 MB/s of queue at ~12.2k ev/s,
~71 compressed bytes per event, so the default 512 MB cap is first
reached after ~10 minutes of that storm; ordinary production rates (tens
to hundreds of events/s) fill it over hours to days.

A file the worker did not write (foreign content, or framing damaged past
the readable) sets `fallback_broken=1`: the queue is disabled — neither
appended to nor replayed — and durability degrades to the RAM-backlog bound
until the GUC points at a **different** path or the worker restarts (the
repoint re-checks the file; pointing back at the same bad path changes
nothing).

Placement caveat, measured (v0.2.0, one 16-core host, nvme, docker
overlay; debug-level storm, 16 pgbench clients, duration logging on,
receiver down for a full 10 minutes, queue on the same device as WAL):

| | stderr on | stderr off (`log_destination=''`) |
|---|---|---|
| storm throughput, everything diverted to the queue | 6.2k ev/s (tps 892) | 11.5k ev/s (tps 1643) |
| live storm while the queue replays | 7.3k ev/s (tps 1046) | 13.6k ev/s (tps 1941) |
| queue cost | 75 B/event | 65 B/event |
| dropped / lost | 0 / 0 | 0 / 0 |

Two conclusions. First, the queue itself is cheap: worst-case write rate
~0.75 MB/s (every event diverted, gzip ~5× on debug-storm lines, ~30× on
repetitive ones), fdatasynced once per flush cycle, and pooled buffers
keep the worker out of malloc's mmap path (the per-chunk ~100KB+ transients
used to cross the threshold and their TLB shootdowns taxed every core).
Second, the dominant disk cost under a debug storm is not pg_logtap but
stderr duplication into the container log: turning it off
(`log_destination=''` — the hook captures everything regardless, it sits
before destination routing) raised storm throughput by 84%. End-to-end,
the same run took a 10-minute receiver outage under storm — 11M events
total, zero dropped, zero lost — and drained the 642 MB queue afterwards
at 5–7k events/s, live traffic joining in FIFO order the whole time.

Backends never block or wait on the queue; the residual cost is disk
contention with WAL. If debug storms and receiver outages regularly
coincide and the tps matters, keep stderr off during them (the events
still get captured and exported) and give PGDATA — and the queue with
it — its own device.

Transition lines in the server log mark divert start/stop:

```
pg_logtap export diverting batches to fallback file (receiver failing)
pg_logtap fallback closed, receiver delivery resumed
```

During catch-up after a long outage, live events join the queue itself
(appended after the older members, global seq order holds) rather than
waiting in RAM — catch-up stays lossless even when the live rate exceeds the
drain rate. The ring never idles behind `flush_interval` either: the worker
publishes its latch in shared memory and the first event pushed into an empty
ring wakes it immediately, so even a connection burst (~85k events/s from 16
pgbench connects at debug1) is drained as it arrives instead of overflowing
the ring during one sleep. The queue drains one gzip member per flush cycle
(plus a bounded 64 members before the worker yields to counters/metrics/SIGHUP),
so delivery resumes without a RAM-backlog loss path. A receiver that answers
but is too slow to keep up (`export_slow_ms`) parks live batches on the same
file losslessly instead of stalling the worker, so `events_lost` there too
grows only on sustained capture past export capacity, a full disk, or an
unreadable queue member (then the RAM-backlog semantics apply to the excess).

## Alerting

Ready-to-apply rules in [`alerts/pg_logtap.rules.yml`](../alerts/pg_logtap.rules.yml):

- `PgLogtapEventsLost` — `increase(pg_logtap_events_lost_total[5m]) > 0`: backlog overflow — capture sustained past export capacity (receiver too slow or down longer than export_backlog_max/r).
- `PgLogtapRingDropped` — `increase(pg_logtap_events_dropped_total[5m]) > 0`: capture-time ring overflow (worker stalled or r above drain rate).
- `PgLogtapExportFailing` — `increase(pg_logtap_send_cycles_failed_total[5m]) > 0` for 5m: sends failing right now (benign while the fallback file absorbs, but the receiver is not keeping up).
- `PgLogtapFallbackQueueBroken` — `pg_logtap_fallback_broken == 1` for 5m: the fallback file failed its framing check (foreign content, or two clusters sharing one file) and delivery degraded to the RAM bound — needs an operator: point the GUC at a different path or restart.
- `PgLogtapDnsFailing` — `pg_logtap_dns_fail_streak > 10` for 5m: the worker's DNS lookups keep failing (streak, not count — 10 consecutive flush cycles); events park on the fallback file meanwhile.
- `PgLogtapRedactPatternFailed` — `pg_logtap_redact_pattern_failed == 1`: `redact_pattern` did not compile; redaction is OFF (fail-open by design — a bad pattern must not stop export), fix the pattern.

Counters reset on restart (per cluster life) — `increase()` handles that
natively as long as the Prometheus scrape interval is shorter than the restart.

## Counter glossary

Each event is counted once per lifecycle stage it actually passes through.
The delivery invariant is `events_captured ≈ events_sent +
(events_queued - events_replayed) + events_dropped + events_lost +
in-flight/ring`. Names are identical in `pg_logtap_stats()` text, the
`pg_logtap_delivery` view and the Prometheus exposition; the view adds
derived `queue_backlog` and `delivered`.

One asymmetry: `events_replayed ≤ events_queued` holds within one worker
life, but a soft worker exit resets the worker-local replay offset, and the
restarted worker replays the queue from byte 0 — already-delivered members
count as replayed again. At startup the offset is re-derived and the backlog
credited (`fbCreditBacklog`), so `queue_backlog` stays truthful; only the
cumulative `events_replayed` (and `delivered`) can exceed what that worker
itself queued. Persisting the offset in the file header is on the roadmap.

| counter | unit | grows when |
|---|---|---|
| `events_captured` | events | a log line entered the shared ring |
| `events_dropped` | events | the ring was full at capture time (worker drain behind the capture rate) |
| `events_sent` | events | delivered to the export URL by a live send |
| `events_queued` | events | durably appended to the fallback file |
| `events_replayed` | events | delivered out of the fallback file after the receiver recovered |
| `events_lost` | events | permanently gone: RAM backlog overflow with no fallback file, an unreadable queue member skipped, or a `fallback_max_mb` compaction dropping undelivered members |
| `send_cycles_failed` | **cycles** | one per flush cycle whose send attempt failed — the receiver-down signal; events are safe, not lost |
| `ring_events`/`ring_capacity` | events | ring fill right now / ring size |
