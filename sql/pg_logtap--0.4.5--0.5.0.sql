/* 0.4.5 → 0.5.0: TLS export (https:// and tcps:// URLs — the four new
   export_tls_* / export_http_header GUCs are SIGHUP and have no SQL surface
   of their own) and the four warning counters the 0.5.0 stats functions
   now return. Binary replace + restart, then ALTER EXTENSION UPDATE;
   until the hop runs, the 0.4.x view keeps working — jsonb_populate_record
   ignores the fields it does not know. */
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE warn_tls_no_verify bigint;
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE warn_fallback_open bigint;
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE warn_fallback_skipped bigint;
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE warn_fallback_unbounded bigint;

/* Same as the 0.3.0 → 0.4.0 script: a stored view does not follow later
   type changes, so re-create it or SELECT * keeps the old column list and
   hides the new counters. Replacing keeps the view's ACL, so the
   pg_monitor grant carries over. */
CREATE OR REPLACE VIEW pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(NULL::pg_logtap_stats_t,
                                    pg_logtap_stats_json()::jsonb);
