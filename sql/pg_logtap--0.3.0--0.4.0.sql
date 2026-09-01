/* 0.3.0 → 0.4.0:
   - events_compacted: events dropped by the fallback cap trim while not yet
     delivered. Previously they were counted as replayed too, so delivered
     (sent + replayed) included events no receiver ever saw; now delivered
     counts only real deliveries, and queue_backlog = queued − replayed −
     compacted. Also new in 0.4.0: variable-width message slots
     (pg_logtap.message_max) — an internal shmem/worker rework with no
     further SQL-visible surface. Shared memory layout changed (though
     byte-identical at the default message_max) — restart the server after
     updating the binary, as with any preload library. */
ALTER TYPE pg_logtap_stats_t ADD ATTRIBUTE events_compacted bigint;

/* jsonb_populate_record matches by name, so a binary that still writes the
   0.3.0 JSON would simply leave the column NULL; the view is re-created
   because a stored view does not follow later type changes: without CREATE
   OR REPLACE it would keep the old column list and drop the new counter
   from SELECT *. */
CREATE OR REPLACE VIEW pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(NULL::pg_logtap_stats_t,
                                    pg_logtap_stats_json()::jsonb);
