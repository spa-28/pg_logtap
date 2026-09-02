/* 0.4.0 → 0.4.1: hardening release — compaction temp hardening, cycle-budget
   compaction, redaction layer fixes, GUC validation, docs. No SQL-visible
   surface changed; this script exists so ALTER EXTENSION UPDATE has a path.
   As with any preload library change, restart the server after replacing
   the binary. */
