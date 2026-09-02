/* 0.4.1 → 0.4.2:
   - fb_sync_failures gauge: failed fdatasync calls on the fallback queue,
     cumulative. The WARNING in the server log is edge-triggered (once per
     failure streak); this counter is the alertable, monotonic signal of a
     disk that cannot make queued events durable. Delivery-side fixes of
     this release (no duplicate batch/member on a failed fdatasync, partial
     appends rolled back) are binary-only. */
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE fb_sync_failures bigint;

/* jsonb_populate_record matches by name, so a binary that still writes the
   0.4.1 JSON would simply leave the column NULL; the view is re-created
   because a stored view does not follow later type changes: without CREATE
   OR REPLACE it would keep the old column list and drop the new gauge from
   SELECT *. */
CREATE OR REPLACE VIEW pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(NULL::pg_logtap_stats_t,
                                    pg_logtap_stats_json()::jsonb);
