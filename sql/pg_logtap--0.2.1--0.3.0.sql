/* 0.2.1 → 0.3.0: three new gauges in the stats snapshot (see the base
   script for their meaning). ALTER TYPE ADD ATTRIBUTE only — the JSON
   gains the same keys, and jsonb_populate_record matches by name, so old
   binaries writing the 0.2.1 JSON would simply leave the columns NULL.
   The view is re-created because a stored view does not follow later type
   changes: without CREATE OR REPLACE it would keep the old column list
   and drop the new gauges from SELECT *. */
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE dns_fail_streak bigint;
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE fallback_broken bigint;
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE redact_pattern_failed bigint;

CREATE OR REPLACE VIEW pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(NULL::pg_logtap_stats_t,
                                    pg_logtap_stats_json()::jsonb);
