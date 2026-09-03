# Changelog

## 0.4.3 (2026-09-03)

Filesystem-hardening round from the third external review. Upgrade is the
0.4.2 → 0.4.3 script (schema unchanged — the script only provides the
update path) + binary replace + restart; no new GUCs or counters.

### Fixed

- A symlink planted at the fallback queue's path is no longer followed.
  `fbOpen` retried its failed `O_EXCL` create with a plain open (no
  `O_NOFOLLOW`), so a symlink resolved — and `fbTruncate` opened the path
  `O_WRONLY` the same way, then truncated it to zero: anything with write
  access to the data directory could aim the queue at another file and
  have it appended to or wiped. Both opens now refuse symlinks, as the
  compaction temp has since 0.4.1; a refused queue degrades to the RAM
  backlog (delivery contract unchanged). The failed `O_EXCL` create is
  also retried on `EEXIST` only — `EACCES`/`EROFS`/`ENOTDIR` now fail as
  they are instead of being masked by a second open.
- Truncating the fully delivered queue is a durability point now: the
  `fdatasync` after `ftruncate(0)` closes the crash window in which
  members the receiver already has could resurrect from an unsynced
  inode and replay as duplicates. A failed sync counts into
  `fb_sync_failures` like any other; it only re-opens the documented
  at-least-once duplicate window, losing nothing.

### Internal

- e2e: a damaged gzip member mid-queue (framing intact) is skipped,
  counted lost, and the later members still replay, with replay staying
  on; and a symlink at the queue path is refused, the file it names
  stays untouched, and the events ride the RAM backlog to the receiver.

## 0.4.2 (2026-09-02)

Delivery-hardening round from the second external review. Upgrade is the
0.4.1 → 0.4.2 script (one new counter attribute) + binary replace +
restart.

### Fixed

- A failed `fdatasync` no longer makes the sender re-send — and the
  queue re-append — a batch that IS in the file. `fbAppend` now
  distinguishes three outcomes: *failed* (partial writes rolled back,
  batch retried from RAM), *appended*, and *not_durable* (member kept
  and counted queued, never re-appended — the pre-fix behavior doubled
  the member on every retry). The `file://` sink applies the same rule:
  after a failed sync it rolls the batch back and reports failure only
  if the rollback took, so a dying disk means one maybe-lost batch
  instead of a guaranteed duplicate NDJSON batch.
- A partial write into the queue is truncated back to the member
  boundary before the retry — a torn `[len][half-member]` left in place
  used to shift the framing of every later append (the whole tail then
  read as "gzip damaged" instead of one batch retrying).

### Added

- `fb_sync_failures` counter — failed `fdatasync` calls on the fallback
  queue, cumulative — in `pg_logtap_stats()`, the `pg_logtap_delivery`
  view, the Prometheus exposition and as a `PgLogtapFbSyncFailing`
  alert rule: the server-log WARNING is once per failure streak, the
  counter is the monotonic dying-disk signal.

### Internal

- Fault-injection e2e, new `faults` matrix phase: a throwaway postgres
  under an LD_PRELOAD shim fails `fdatasync` for one named file, N
  times per process — the sync/write failure paths above are
  regression-tested now, not just reasoned about.

## 0.4.1 (2026-09-01)

Hardening round from the 0.4.0 external review. No schema or shmem
changes; upgrade is a binary replace + restart as usual.

### Fixed

- The cap compaction's temp file is created exclusively and never
  through a symlink: the predictable `<queue>.compact.tmp` path was a
  symlink-attack and cross-process race window on a shared data
  directory.
- A cap/2 rewrite in a *normal* flush cycle ran under a deadline that
  only a shutdown flush sets — mid-cycle it could hold the worker for
  the whole walk + inflate + copy, starving drain, `/metrics` and
  SIGHUP. The rewrite now has its own deadline in every cycle.
- Password-assigned values (`password = '…'` in a DETAIL/HINT/CONTEXT
  line) are masked, not just the password token in statement text.
- An event's `redacted` marker survives when a redaction layer clips at
  the scratch size and a later layer matches nothing — previously the
  marker was overwritten and a clipped event shipped as untouched.
- Fallback durability failures are audible: a dying `fdatasync` warns
  once (per failure streak) instead of being indistinguishable from
  success, and a torn tail that cannot be truncated back to its member
  boundary disables replay with a WARNING instead of misparsing.
- A socket whose `SO_RCVTIMEO`/`SO_SNDTIMEO` options failed to land is
  abandoned before `connect` — proceeding meant the unbounded block the
  timeouts exist to prevent. The send socket's two close routes (sender
  defer, double-SIGTERM punch) go through one helper, closing the
  fd-slot double-close window.

### Changed

- `pg_logtap.export_fallback_file` is validated at SET time: a value
  whose resolved path leaves no room for the `.compact` rewrite suffix
  under the 4096-byte path limit is rejected instead of failing only
  when a compaction first needs the name. Relative paths still resolve
  against the data directory; the empty default still passes.

### Internal

- Declaration names under three characters fail the lint build (`c` —
  worker.zig's C-alias — excepted).
- The e2e suite refuses to run against a stale extension load (every
  script checks `pg_logtap_version()` against the tree), and log-window
  asserts count before/after deltas instead of trusting
  `docker logs --since`.
- Counters glossary, alerts and the metrics HELP lines name
  `events_compacted` and all three `events_lost` causes; SECURITY.md
  states the redaction stance (best-effort, erring toward masking too
  much).

## 0.4.0 (2026-09-01)

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
