# Delivery contract

What pg_logtap promises, per failure scenario, with numbers. The assumptions:
`ring_capacity` = R (default 1024, max 8192, POSTMASTER), capture rate = r events/s,
`flush_interval` = f (default 1000 ms). One event ≈ 3.4 KB of shared memory
(8192-slot ring ≈ 28 MB). Counters are **per cluster life** — shared memory dies
with the postmaster, so `pg_logtap_stats()` (and the `pg_logtap_delivery`
view) restarts from zero on every restart.

## Semantics per destination

| Scheme | Semantics | ACK | Duplicate window |
|---|---|---|---|
| `http://` | **at-least-once**, batch granularity (≤ 256 events/chunk) | HTTP 2xx status line | server persisted the body but the response was lost → whole chunk resent |
| `tcp://` | **at-most-once** | none — `write(2)` success counts as delivered | none; a receiver dying after accept loses silently. Use `http://` for loss-sensitive receivers |
| `file://` | durable append (O_APPEND, 0600) + **fdatasync per batch** | the write itself | a failed partial write retries the whole batch → duplicate lines possible |
| fallback queue | durable (fdatasynced once per flush cycle), **replayed automatically** on recovery | the write itself | a crash mid-replay restarts from byte 0 → already-delivered members resent; the receiver may also have accepted the failed send that queued them |

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

## Loss boundaries per scenario

Buffers: the shmem ring (≤ R events) + the worker RAM backlog (trimmed to the
newest R events). Everything else is already delivered.

### Receiver down for T minutes

Without a fallback file, events survive downtime only while they fit in
ring + backlog. **Zero-loss downtime = R / r**:

| R | @100 ev/s | @1 k ev/s | @8 k ev/s (debug storm) |
|---|---|---|---|
| 1024 (default) | 10 s | 1 s | 0.13 s |
| 8192 (max) | 82 s | 8 s | 1 s |

Beyond that the backlog drops **oldest-first** (`export_lost`), and on recovery
the newest R events are delivered. 10 min at 1 k ev/s ≈ 600k events → ~592k
lost, 8192 delivered. With `export_fallback_file` set (below): **zero lost,
for any T** — failed batches are diverted to a compressed on-disk queue and
replayed when the receiver answers.

### Postmaster SIGKILL / node crash

Without a fallback file, both buffers are volatile. Everything
captured-but-not-yet-delivered is lost: **up to 2·R events, uncounted** (the
counters die with the shmem). Graceful shutdown (SIGTERM/postmaster stop) runs
one final flush cycle first; SIGKILL skips it. With `export_fallback_file` set,
the queue is on disk and **survives the crash** — the restarted worker replays
it; the exposure shrinks to roughly one `flush_interval` of events (in RAM at
the moment of the kill) plus the in-flight chunk.

### Export worker crash

A bgworker dying by signal is treated by the postmaster like a backend crash:
**emergency restart of the whole cluster** → identical to a postmaster crash. The capture path
(emit_log_hook → ring) never touches the worker, so database logging is not
blocked for an instant either way. A soft worker exit is auto-restarted after
1 s: ring and counters survive (shmem intact), but the RAM backlog (≤ R events)
vanishes uncounted.

### Disk full

pg_logtap uses no disk while exporting over the network — shmem, RAM and
sockets only; capture and export are unaffected (PostgreSQL itself will fail
on WAL writes first — a different failure domain). A full disk does close the
fallback queue: appends fail, and events fall back to the RAM-backlog behavior
above (oldest-first loss once the backlog is full, counted in `export_lost`).
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
step is involved. On restart the same replay happens automatically (scenario C
of `scripts/e2e-kill.sh`: SIGKILL with a full queue, receiver back after boot
→ all events delivered, queue empty, zero duplicate seqs).

Crash windows: a crash mid-append leaves a torn trailing member — detected and
truncated on the next read. A crash mid-replay loses only the in-memory
offset: replay restarts from byte 0, so the receiver can see already-delivered
members again — dedup by `(host, seq)` as above makes that harmless. Events
may also appear twice because the failed send that queued them may have
partially landed — same dedup.

Placement caveat, measured under a debug-level storm (~16k events/s, 16
pgbench clients, receiver down, queue on the same overlay device as WAL):
the queue costs ~5-10% tps (2480-2510 quiet / 2250-2390 with the queue
absorbing everything, dropped=0 lost=0 across 11+ runs and 8-250 clients).
Two properties buy that: compression (~30×: 600 events 310 KB plain →
9.5 KB queued) and pooled buffers — the per-chunk ~100KB+ transients used
to cross glibc's mmap threshold, and the resulting TLB shootdowns taxed
every core; the worker now reuses its body/compressor/inflate buffers for
the process life and fdatasyncs once per flush cycle, not per member.
Backends never block or wait on the queue; the residual cost is disk
contention with WAL. If debug storms and receiver outages regularly
coincide and the tps matters, give PGDATA (and the queue with it) its
own device.

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
so delivery resumes without a RAM-backlog loss path; `lost` can still grow
only if the queue file itself becomes unreadable or the disk fills (then the
RAM-backlog semantics apply to the excess).

## Alerting

Ready-to-apply rules in [`alerts/pg_logtap.rules.yml`](../alerts/pg_logtap.rules.yml):

- `PgLogtapEventsLost` — `increase(pg_logtap_events_lost_total[5m]) > 0`: backlog overflow, receiver too slow or down past R/r.
- `PgLogtapRingDropped` — `increase(pg_logtap_events_dropped_total[5m]) > 0`: capture-time ring overflow (worker stalled or r above drain rate).
- `PgLogtapExportFailing` — `increase(pg_logtap_send_cycles_failed_total[5m]) > 0` for 5m: sends failing right now (benign while the fallback file absorbs, but the receiver is not keeping up).

Counters reset on restart (per cluster life) — `increase()` handles that
natively as long as the Prometheus scrape interval is shorter than the restart.

## Counter glossary

Each event is counted once per lifecycle stage it actually passes through.
The delivery invariant is `events_captured ≈ events_sent +
(events_queued - events_replayed) + events_dropped + events_lost +
in-flight/ring`. Names are identical in `pg_logtap_stats()` text, the
`pg_logtap_delivery` view and the Prometheus exposition; the view adds
derived `queue_backlog` and `delivered`.

| counter | unit | grows when |
|---|---|---|
| `events_captured` | events | a log line entered the shared ring |
| `events_dropped` | events | the ring was full at capture time (worker drain behind the capture rate) |
| `events_sent` | events | delivered to the export URL by a live send |
| `events_queued` | events | durably appended to the fallback file |
| `events_replayed` | events | delivered out of the fallback file after the receiver recovered |
| `events_lost` | events | permanently gone: RAM backlog overflow with no fallback file, or an unreadable queue member skipped |
| `send_cycles_failed` | **cycles** | one per flush cycle whose send attempt failed — the receiver-down signal; events are safe, not lost |
| `ring_events`/`ring_capacity` | events | ring fill right now / ring size |
