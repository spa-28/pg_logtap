/* 0.4.2 → 0.4.3: no schema changes — filesystem hardening of the fallback
   queue only (a symlink at the queue's path is refused instead of followed,
   the post-replay truncate is fdatasynced). This script exists so
   ALTER EXTENSION pg_logtap UPDATE has a path; the fixes are binary-only. */
