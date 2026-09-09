# Changelog

## 0.5.0 (2026-09-07)

TLS export and HTTP auth-header round. Upgrade is the
0.4.5 → 0.5.0 script (the four warn-counter attributes and the re-created
view) + binary replace + restart; the four new GUCs are all SIGHUP.

### Added

- `https://` and `tcps://` export URLs — the existing http/tcp transports
  over TLS 1.2/1.3 (std.crypto.tls; no new dependencies; client
  certificates / mTLS not supported). One handshake per batch over the
  already-dialed socket, inside the existing `export_timeout_ms` and
  SIGTERM-abort discipline; a failed handshake is an ordinary failed send.
- `export_tls_ca` — PEM file with the receiver's CA (the receiver's own
  certificate for a self-signed one); empty = the system CA roots, a set
  file replaces them. Re-read before every handshake, so rotation needs no
  restart — clearing the GUC falls back to the system roots on the next
  handshake.
- `export_tls_verify` (default on) and `export_tls_server_name` — the name
  to verify and the SNI to send when it differs from the URL host:
  IP-literal URLs (name verification matches dNSName SANs only) and
  TLS-terminating load balancers.
- `export_http_extra_headers` — extra header line(s) on every http(s)
  request, e.g. `'Authorization: Bearer <token>'`. Multiple lines are
  separated by the two-character `\n` sequence — a GUC value cannot carry
  a real newline (ALTER SYSTEM rejects one outright), so the escape is the
  only multi-line form; each line is CRLF-terminated on send, and the
  plain quoted form just works.
- `scripts/e2e-tls.sh` — acceptance against a self-signed receiver: verified
  https delivery, handshake must fail (and later replay) with the CA cleared
  and with an empty CA file, tcps delivery, verify=off delivering with
  exactly one WARNING. Two substitution negatives: an impostor certificate
  carrying the right name but its own key is rejected on the chain alone
  (nothing reaches the impostor), and a `server_name` absent from the SANs
  fails the handshake on the name alone — both recovering by SIGHUP. An
  intermediate-CA chain: pinning only the root verifies through the
  server-sent intermediate, and the intermediate itself works as the trust
  anchor. The auth gate: a receiver demanding a tenant header plus
  Authorization answers 401 to every send without them (failed cycles,
  nothing accepted) and delivers with the `\n`-separated bearer form and
  with Basic credentials.
- Warning counters in `pg_logtap_stats()` / `pg_logtap_delivery`:
  `warn_tls_no_verify`, `warn_fallback_open`, `warn_fallback_skipped`,
  `warn_fallback_unbounded` — the cumulative, queryable copy of the
  operator-facing WARNING lines (verify=off seen, fallback queue
  unopenable, unreadable member skipped, divert into an unbounded queue).
  The log lines stay edge-triggered; the counters are for alerts and the
  e2e suites — in the Prometheus exposition too (named like their SQL
  fields, no `_total`). In `pg_logtap_delivery` after the update script
  (a stored view does not follow type changes, so the script re-creates
  it); until the hop runs, the 0.4.x view keeps working —
  `jsonb_populate_record` ignores the new fields.

### Hardening

- A `file://` rollback after a failed `fdatasync` is synced too: the failed
  sync may already have pushed the batch's pages and size out, and an
  unsynced `ftruncate` could resurrect them after an OS crash — where the
  retried batch, parked on the fallback queue, would replay a second copy
  after the resurrected one. A rollback sync that fails as well keeps the
  retry (at-least-once), the same trade the rollback-failed path documents.
- A send attempt runs on one absolute budget. Each socket syscall was
  already bounded by `export_timeout_ms`, but the stages were not: a
  stalled resolver could spend seconds before a connect that bought its
  own full timeout, then a write, then a status read — several budgets in
  one attempt. The timeout is armed as a deadline at send start and
  re-armed on the socket at every stage boundary and loop iteration
  (post-dial, TLS handshake, body chunks, status reads); an attempt past
  its budget fails as an ordinary send and the batch takes the usual
  retry/fallback path. DNS stays outside the budget, as before and as the
  GUC table documents (getaddrinfo has no timeout knob).
- `export_http_extra_headers` cannot malform a request: a raw CR/LF byte and
  an embedded empty line are rejected at SET (each would end the header
  section early), and everything else about line endings is normalized on
  send — each configured line gets its CRLF and the value is always
  terminated, so the fixed headers after it always start on a fresh line.
  Unit-tested in export.zig, gate-tested by e2e-tls phase 9.
- TLS failures name their fix instead of an error name: a certificate name
  mismatch appends the `export_tls_server_name` hint (IP-literal URLs always
  need it), an unknown CA appends the `export_tls_ca` hint, decode-class
  errors say the receiver may not be speaking TLS on that port (an https://
  URL at a plain-http port is the classic). A `export_tls_ca` file that
  cannot be read, or parses but holds no certificates (created empty, wrong
  file), fails with the path in the reason instead of an opaque chain error
  on every handshake.
- `export_tls_verify=off` logs one WARNING per worker life at the first
  TLS send — the documented development escape hatch now leaves an
  operator-visible trace in the server log.
- A fallback member that inflates past the framing bound cannot grow the
  worker's memory: the `member_max` check bounds only the compressed input,
  so a small crafted member (a decompression bomb) could inflate into an
  unbounded buffer before the post-inflate check ran. The inflate buffer is
  fixed at `member_max` now — a member that crosses it fails the write and
  is skipped as unreadable exactly like a gzip-damaged one (framing intact,
  counted in `events_lost`, `fallback_broken` untouched), in replay and in
  the compaction walk alike. ~5 MB allocated once on first replay.
- A failed compaction `fdatasync` counts in `fb_sync_failures` and warns
  like any other sync failure: a landed compaction is one of the queue's
  documented durability points, so its failed sync belongs in the counter
  (safety unchanged — the rewrite is abandoned, the original queue stands).
- A `file://` export_url and `export_fallback_file` cannot resolve to the
  same file: the NDJSON sink and the `PGLTFB01` framing corrupt each other.
  Whichever GUC lands second is rejected at SET/`ALTER SYSTEM`. The docs
  now state the fallback queue's scope for what it already was — every
  transport parks there, `file://` included — and the same-reload
  double-flip residual (the foreign-content latch handles that pair loudly).
- The alias rule above is enforced on the filesystem object, not just the
  path string: a symlink or hardlink names the same inode under a different
  string, which the SET-time check cannot see. At open time, on both sides,
  the actual `(st_dev, st_ino)` decides — the `file://` sink refuses the
  send (warned once; events ride the RAM backlog) when its fd is the
  queue's file, and the queue latches `fallback_broken` exactly like any
  unusable queue when its fd is the sink's file. The check is symmetric, so
  an alias disables both writers and the shared file never holds mixed
  formats; recovery is one GUC repoint. Residual, by design: a path swapped
  between its check and the other side's open (a racing writer inside the
  data directory) can still land both on one inode — the foreign-content
  latch keeps that from silent corruption. e2e-kill drives both shapes
  (symlinked sink, hardlinked queue) and asserts the file stays empty.
- Every socket read inside a TLS handshake or session is re-armed to the
  send attempt's absolute deadline: the TLS library's handshake loop has no
  bound on the number of reads it will do, so a peer dribbling one record
  fragment per just-under-timeout interval could pin the worker inside the
  handshake forever — each individual recv succeeded, the per-read
  `SO_RCVTIMEO` never fired. The TLS socket reader wraps the deadline now
  (`remaining = deadline − now` before every read), so the handshake and
  the status reads after it are strictly inside `export_timeout_ms`; the
  residual multiple is on the write side only, and it is a constant —
  one 64 KB chunk's ~4 TLS records, each waiting at most what was armed at
  the chunk's start, never batch-proportional; the next chunk boundary
  fails the send once the budget is spent.
  After a successful send that consumed the budget, the best-effort
  `close_notify` is skipped (the fd close is the backstop). e2e-tls phase
  10 drives a one-byte-per-2s dribbler and asserts failed cycles grow.
- The plain `http://`/`tcp://` body write checks the send attempt's
  absolute deadline between syscalls, like every other stage: each partial
  write resets the socket's per-write wait, so a receiver accepting one
  byte per just-under-timeout interval could stretch one body across many
  individually-bounded waits (TLS already re-armed per chunk). The
  deadline is an explicit argument to the shared writer, not ambient —
  the compaction copy and metrics replies stay abort-aware without
  measuring against a stale send deadline.
- A metrics client that connects but dribbles its request line gets 50 ms
  (was 100 ms) before its connection is dropped — a loopback scraper's
  line lands in the first poll and a legitimately laggy client's
  inter-fragment gap stays covered (e2e-metrics drives a 20 ms one), so
  the tightening costs nothing real while halving the per-cycle tax a
  broken scraper can levy; the 250 ms per-cycle scrape budget still caps
  the total.

### Internal

- SIGHUP resets the receiver-slow flag (a stale flag from the previous
  receiver — or from a threshold since disabled — parked the new
  destination's batches until a quiet cycle re-probed it), and the
  unparseable-URL warning re-arms when a URL parses again (bad → fixed →
  bad warns twice, like the file:// latches). A TLS receiver closing the
  session cleanly before any status line is reported as `tls eof`, not as
  the previous attempt's leftover error text.
- The `events_queued` Prometheus HELP and the fallback section of
  delivery.md call it a lifecycle stage like the counters glossary already
  did, and delivery.md's `events_captured ≈ …` invariant subtracts
  `events_compacted` from the backlog term — compacted events sit in both
  `queued − replayed` and `events_lost`, so the formula double-counted
  them.
- The Makefile is the single entry point now: `make check` (fmt + lint +
  unit tests + the .so compile), `make container` (the same battery in the
  pgzx-build container), `make e2e` (the docker matrix), `make deploy` —
  thin aliases over the scripts, plus the conventional
  `make && make install`. CI runs the make targets itself, so the interface
  cannot drift from the real build.
- The extension's update chain is continuous again: the
  0.4.4 → 0.4.5 hop was missing (0.4.5 changed no SQL, but every version
  ships one — without it `ALTER EXTENSION UPDATE` could not leave 0.4.4).
  It ships now, comment-only, alongside this version's 0.4.5 → 0.5.0
  script.
- SIGHUP no longer leaks the source-identity strings (hostname/cluster/
  pgdata were duped on every reload and never freed; the copies are owned
  now, and a reload with unchanged values keeps the allocation), and the
  oid→name cache is bounded (4096 entries per map — a database/role
  create-drop storm grew it forever; past the bound the maps reset and
  re-fill lazily from the catalog).
- `fb_sync_failures` non-zero is history, not current state, everywhere the
  counter appears (README, delivery.md, the /metrics HELP): the next
  successful sync — or a compaction, whose rewrite is fdatasynced before
  the rename — makes the queue durable again while the counter stays;
  alert on its growth, not its level.
- e2e-tls phase 11, rapid trust rotation through SIGHUP: ca / server_name /
  url alternated across reloads, two rounds of verified → cleared-CA fail →
  root-pinned chain → name-mismatch fail — the per-handshake bundle rebuild
  must land the right trust decision every time (no stale bundle, no stale
  name), with failed-cycle and zero-leak asserts at every step.
- e2e-tls phase 12, a receiver pinned to TLS 1.2 only (min = max =
  TLSv1_2): verified delivery with the negotiated version asserted from the
  receiver side — the 1.2 half of the documented TLS 1.2/1.3 support is
  acceptance-tested instead of implied by the 1.3 passes (Zig's client
  offers both).
- The DNS last-known-good address has explicit semantics, documented with
  the `export_url` schemes: it is used only while in-process resolution
  fails, only for the host that produced it, and only within 60 s of the
  last successful dial (a successful dial refreshes it). On
  `https://`/`tcps://` a stale address that no longer serves the host fails
  certificate verification; on plain `http://`/`tcp://` a reassigned IP can
  receive logs for at most that window.
- e2e-tls phase 8, the ambiguous close: a receiver whose TLS layer takes
  the whole request body and then ends the session before any status line.
  The send fails on the status read (with tls.zig's stage detail folded
  into the reason now), the events survive in RAM and replay whole to the
  next url, and the body the closer did accept is asserted present — the
  duplicate window the contract allows for exactly this shape.
- The eleven e2e scripts share `scripts/e2e-common.sh` instead of a
  copy-pasted prologue: container/GUC/marker helpers, the ready gate and a
  per-container `flock` so two suites cannot race one stand. The container
  argument is now optional everywhere (defaults to the running compose
  stand), and e2e-tls counts per-phase named markers instead of number
  ranges, so one phase's asserts cannot be satisfied by another's events.
  e2e-kill's no-loss asserts became deltas — the counters are
  per-cluster-life and a reused container already carried a previous run's
  deliberate losses.
- The e2e suites run under plain `set -u` (asserts are explicit; `set -e`
  only bred `|| true` noise around every expected-to-fail command), and
  `wait_for` FAILS on timeout instead of silently falling through — a wait
  that rode the fall-through once green-lit suites on follow-up asserts or
  on nothing. The four WARNING-count checks read the new warn_* counters
  via `pg_logtap_stats()` instead of grepping `docker logs` (torn-tail
  escalations via the `fallback_broken` gauge), and robust's
  pattern_exclude control event is actually awaited now — the old marker
  never matched.
- The TLS suite is a `test-matrix.sh` phase (`PHASES=…,tls,…`, on by
  default): every PG major gets the verified/impostor/server_name/
  intermediate/tcps/verify=off acceptance, not just the dev stand's
  major. The receivers run host-side, so the phase needs `openssl` and
  `python` on the host. `set_gucs` applies a reload barrier instead of
  timed sleeps — SHOW polled in a fresh session until the new config
  generation is visible, plus one `export_timeout_ms` for the worker's
  worst in-flight send — so markers generated after a url switch cannot
  ride the old destination; the suite also clears any fallback file
  inherited from earlier matrix phases, whose failure-phase parking
  belonged to those suites' scenarios, not this one's.
- `JOBS=N test-matrix.sh` runs the PG majors in parallel (~1.7× on four):
  each major gets its own output dir, its own vector receiver (the
  kill/robust suites stop THEIR receiver mid-scenario — with one shared
  vector those phases serialized the whole matrix behind a lock, measured
  slower than sequential; vlogs and the mute silent receiver stay shared,
  nothing stops them and the vlogs asserts are marker-filtered), its own
  TLS receiver ports and per-container names for the ephemeral receivers
  (slow/faults/metrics/frag/hookchain). The tested pg containers are plain
  `docker run` on the stand's network — compose offers one container per
  project+service, and the cross-major recreate/label-rm dance existed
  only to fake per-major service slots. Builds and stand bring-ups
  serialize on one lock (shared zig-out and the pgzx-build cache).
- The fallback queue moved out of worker.zig into src/fb.zig (~540 lines):
  the queue owns its GUCs (`export_fallback_file`, `fallback_max_mb`), the
  chunk bounds shared with buildBody, and its boot path (compaction-litter
  cleanup, backlog credit). No behavior change — the same functions under
  `fb.` with namespaced state; the worker keeps the transports, deadlines
  and the metrics server.

## 0.4.5 (2026-09-04)

Boot-safety and delivery-contract documentation round. No schema, GUC or
counter changes; upgrade is binary replace + restart.

### Fixed

- The `seq` seed is clamped at zero: a wall clock before 2000-01-01 (a
  dead CMOS battery, a boot ahead of NTP sync) made the raw seed
  negative and the `@intCast` panicked in ReleaseSafe during shared
  memory init — inside the postmaster, so the cluster failed to boot
  with pg_logtap preloaded. At 0 the ordering and dedup claims hold;
  the bound is noted where the seed is set.

### Documentation

- `events_queued` is commented as what delivery.md already declares: a
  lifecycle stage, not a durability claim — `fb_sync_failures` says
  which cycles are not durable.
- The receiver dedup recipe is cluster-safe: `fields.match` includes
  `cluster` (null while `cluster_name` is unset, matching everything —
  the one-cluster-per-host case, so the recipe is never worse than
  before). The ordering/identity section now spells out both caveats: a
  wall clock stepped backwards can regress the seed (dedup on
  `(host, seq, timestamp)` for absolute safety), and two clusters on
  one host seed overlapping `seq` ranges (set `cluster_name` and dedup
  on `(host, cluster, seq)`).

## 0.4.4 (2026-09-04)

TCP-stream parsing and accounting round.
Upgrade is the 0.4.3 → 0.4.4 script (schema unchanged — the script only
provides the update path) + binary replace + restart; no new GUCs or
counters.

### Fixed

- The HTTP status line is read across recv boundaries. A receiver whose
  "HTTP/1.1 200" lands as two reads (TCP preserves no write boundaries)
  failed the one-recv read — a batch the receiver had already accepted
  got parked and replayed (a contract-legal duplicate) while the fallback
  divert fired on a live receiver. The read now accumulates to the bytes
  the status parse needs; each recv stays bounded by the send timeout.
- A /metrics request line is read across recv boundaries the same way: a
  fragmented GET parsed as a wrong path and was answered 404 (the scraper
  retries, but the endpoint now sees a complete request line; the whole
  read is still bounded by the previous ~100ms wait).
- Compaction counts an unreadable (corrupt gzip) member it drops as one
  lost event, exactly as the replay path counts the same member — before,
  the same corrupt file produced a lower `events_lost` through compaction
  than through replay.
- A file:// rollback that itself fails (the `ftruncate` cutting away a
  torn write's prefix) warns once instead of passing silently: one torn
  line stays in the sink and the next batch appends after it — a
  dying-disk signal. Both file:// warned-once latches (sync, rollback)
  re-arm after a clean batch, so the next independent failure is visible.

### Hardening

- Fallback framing sanity bound: a member's compressed length is refused
  above `body_cap` + one serialized event (+64K of slack) — the largest
  member this build (or 0.3.x, ≤ ~371KB) can write — instead of the
  previous 512 MiB catch-all, so garbage framing cannot request an
  absurd allocation before the short-pread/torn-tail check frees it.

### Internal

- e2e: a receiver answering "HTTP/1." … "1 200 OK" in two writes 300ms
  apart is accepted (every event delivered once, nothing parked on the
  live receiver); a fragmented `GET /metrics` gets the metrics body
  instead of a 404.

## 0.4.3 (2026-09-03)

Filesystem-hardening round. Upgrade is the
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
  they are instead of being masked by a second open — and an unopenable
  queue sets `fallback_broken=1` with one WARNING, exactly like a foreign
  one, instead of silently retrying the open every flush cycle.
- Truncating the fully delivered queue is a durability point now: the
  `fdatasync` after `ftruncate(0)` closes the crash window in which
  members the receiver already has could resurrect from an unsynced
  inode and replay as duplicates. A failed sync counts into
  `fb_sync_failures` like any other; it only re-opens the documented
  at-least-once duplicate window, losing nothing. The truncate also
  re-verifies the queue magic on the file it is about to zero — one
  swapped into the path by a rename between the drain and the truncate
  is left alone — and a partially written queue header is rolled back to
  empty instead of disabling the fallback as "foreign content" on the
  next open.

### Internal

- e2e: a damaged gzip member mid-queue (framing intact) is skipped,
  counted lost, and the later members still replay, with replay staying
  on; and a symlink at the queue path is refused, the file it names
  stays untouched, and the events ride the RAM backlog to the receiver
  (asserting `fallback_broken=1` and the single refusal WARNING; the
  corrupt-member walk fails fast if a flush stall merged two marker
  generations into one member).

## 0.4.2 (2026-09-02)

Delivery-hardening round. Upgrade is the
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

Hardening round. No schema or shmem
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
