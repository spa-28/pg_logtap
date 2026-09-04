/* 0.4.3 → 0.4.4: no schema changes — delivery-robustness fixes only (the
   HTTP status line and the /metrics request line are read across TCP recv
   boundaries, compaction's loss accounting for corrupt members matches
   replay's, a failed file:// rollback warns once, and the fallback framing
   sanity bound is derived from the member contract instead of 512 MiB).
   This script exists so ALTER EXTENSION pg_logtap UPDATE has a path; the
   fixes are binary-only. */
