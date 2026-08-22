/* pg_logtap 0.2.0 */
CREATE FUNCTION pg_logtap_version() RETURNS text
AS 'MODULE_PATHNAME', 'pg_logtap_version'
LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION pg_logtap_stats() RETURNS text
AS 'MODULE_PATHNAME', 'pg_logtap_stats'
LANGUAGE C STRICT VOLATILE PARALLEL UNSAFE;

CREATE FUNCTION pg_logtap_dump(row_limit int DEFAULT 100) RETURNS text[]
AS 'MODULE_PATHNAME', 'pg_logtap_dump'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

/* Same counters as pg_logtap_stats(), as JSON with full column names. */
CREATE FUNCTION pg_logtap_stats_json() RETURNS text
AS 'MODULE_PATHNAME', 'pg_logtap_stats_json'
LANGUAGE C STRICT VOLATILE PARALLEL UNSAFE;

/* The monitoring view: one row, counters ordered along the delivery flow.
   Event counters (each event counted once per stage it passes):
     events_captured — entered the ring
     events_dropped  — the ring was full at capture time
     events_sent     — delivered by a live send
     events_queued   — durably appended to the fallback file
     events_replayed — delivered out of the fallback file
     queue_backlog   — stuck in the fallback file right now (queued − replayed)
     delivered       — sent + replayed, everything handed to a receiver
     events_lost     — permanently lost (no fallback file / unreadable member)
   send_cycles_failed counts failed send CYCLES, not events (receiver down).
   ring_events/ring_capacity are gauges for capture-ring pressure. */
CREATE TYPE pg_logtap_stats_t AS (
    events_captured    bigint,
    events_dropped     bigint,
    events_sent        bigint,
    events_queued      bigint,
    events_replayed    bigint,
    queue_backlog      bigint,
    delivered          bigint,
    events_lost        bigint,
    send_cycles_failed bigint,
    ring_events        int,
    ring_capacity      int
);

CREATE VIEW pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(NULL::pg_logtap_stats_t,
                                    pg_logtap_stats_json()::jsonb);

/* Log content is other sessions' data (queries via field_query, errors,
   detail/context with SQL text): dump stays owner-only by default — GRANT
   EXECUTE to a specific role if a monitoring user needs it. Counters are
   cluster metadata: PUBLIC loses them, the built-in pg_monitor role keeps
   them (agents usually already carry it). */
REVOKE EXECUTE ON FUNCTION pg_logtap_dump(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_logtap_stats() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_logtap_stats_json() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_logtap_stats() TO pg_monitor;
GRANT EXECUTE ON FUNCTION pg_logtap_stats_json() TO pg_monitor;
GRANT SELECT ON pg_logtap_delivery TO pg_monitor;
