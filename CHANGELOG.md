# Changelog

## 0.4.0 (in PR #12, unreleased)

### Added

- `pg_logtap.message_max` (postmaster, default 1024 bytes): variable-width
  message slots. The ring now pays for the messages it actually carries
  (~1.8 µs/KB capture cost) instead of a fixed slot width; shared memory
  cost is `ring_capacity × (message_max + ~2.4 KB)` — byte-identical to
  0.3.x at the defaults. The shmem layout changed internally: restart the
  server after replacing the binary.
- `events_compacted` counter: events dropped by the `fallback_max_mb` cap
  trim while not yet delivered (also counted in `events_lost`).
  `delivered = sent + replayed` now counts only events a receiver actually
  got (compacted events used to count as replayed too), and
  `queue_backlog = queued − replayed − compacted`. Exposed in
  `pg_logtap_stats()`, the Prometheus exposition and the
  `pg_logtap_delivery` view (the 0.3.0 → 0.4.0 upgrade script adds the
  attribute and re-creates the view).
- Bind-parameter values are masked on statement lines: with
  `log_parameter_max_length` on, extended-protocol logs now export
  `parameters: $1 = '<REDACTED>'` instead of the literal values.
- One WARNING per divert when parking into an unbounded queue
  (`fallback_max_mb = 0`) — an unattended outage filling the disk is no
  longer silent.

### Changed

- `pattern_exclude` matches the whole event text (message, detail, hint,
  context and the captured query); `pattern_include` stays message-only,
  as documented.
- The fallback cap compaction runs under the flush cycle's abort budget:
  a shutdown flush never waits out a cap/2 rewrite (an interrupted
  compaction leaves the original file untouched and retries on the next
  append past the cap). The final park's fdatasync stays deliberately
  non-abortable — it is the durability the crash contract rests on.

### Fixed

- A SIGHUP while `pg_logtap.redact_pattern` was being assigned could PANIC
  the postmaster: the gauge update takes an LWLock, which requires a
  PGPROC. Processes without one (the postmaster) now skip the gauge.
- A stale `<queue>.compact` left by a compaction crashed mid-rewrite is
  removed at worker start (up to cap/2 of litter).
- The `/metrics` serve buffer is sized to the body: a long-uptime
  exposition with wide counters could overflow it and close the
  connection instead of answering.

## 0.3.0 (2026-08-27)

### Added

- The fallback queue: `pg_logtap.export_fallback_file` parks failed
  http/tcp batches as a compressed, fdatasynced on-disk queue (internal
  `PGLTFB01` framing, one gzip member per batch) and replays it
  automatically once the receiver answers. Survives postmaster crashes;
  torn tails from a crash mid-append are cut at the member boundary.
- `pg_logtap.fallback_max_mb` (default 512 MB, `0` = unlimited): bounds
  the queue by compacting to the newest half of the cap; undelivered
  events dropped by a compaction count into `events_lost`.
- Gauges `dns_fail_streak`, `fallback_broken`, `redact_pattern_failed` in
  `pg_logtap_stats()` and the Prometheus exposition.
- A failed pattern compile reports glibc's `regerror` text in the server
  log; redaction clips are reported separately from slot truncation (the
  `redacted` array in the event schema).

### Changed

- The graceful-shutdown flush is bounded (~1 s of work plus one send
  timeout, enforced between syscalls), and a second SIGTERM to the worker
  closes the in-flight connection and exits immediately. The final park
  to the fallback file is local-disk work with no deadline.
- The password cut fires on extended-protocol statement lines too, not
  only on plain queries.

### Fixed

- The capture re-entrancy guard covers the call into the previous
  `emit_log_hook` in the chain.
