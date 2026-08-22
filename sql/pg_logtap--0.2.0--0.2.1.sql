/* 0.2.0 → 0.2.1: security fix, retroactive for 0.2.0 installs.
   Same block as the base script — see the comment there. */
REVOKE EXECUTE ON FUNCTION pg_logtap_dump(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_logtap_stats() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_logtap_stats_json() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_logtap_stats() TO pg_monitor;
GRANT EXECUTE ON FUNCTION pg_logtap_stats_json() TO pg_monitor;
GRANT SELECT ON pg_logtap_delivery TO pg_monitor;
