/* pg_logtap 0.1.0 → 0.2.0: adds the stats JSON function and the monitoring
   view. ALTER EXTENSION pg_logtap UPDATE; — counters live in shared memory,
   so nothing to migrate. The functions above are unchanged. */
CREATE FUNCTION pg_logtap_stats_json() RETURNS text
AS 'MODULE_PATHNAME', 'pg_logtap_stats_json'
LANGUAGE C STRICT VOLATILE PARALLEL UNSAFE;

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

/* Security fix, retroactive for 0.1.0 installs: dump/stats were PUBLIC by
   default (CREATE FUNCTION grants EXECUTE to PUBLIC) and pg_logtap_dump can
   expose other sessions' queries and errors. Owner-only for dump; counters
   move to pg_monitor. */
REVOKE EXECUTE ON FUNCTION pg_logtap_dump(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_logtap_stats() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_logtap_stats_json() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_logtap_stats() TO pg_monitor;
GRANT EXECUTE ON FUNCTION pg_logtap_stats_json() TO pg_monitor;
GRANT SELECT ON pg_logtap_delivery TO pg_monitor;
