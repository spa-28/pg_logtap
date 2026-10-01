#!/bin/sh
# Acceptance: every released SQL origin reaches one canonical 0.6.1 API.
# Fresh 0.6.0 keeps object OIDs; historical orders are replaced only when
# ownership, ACLs and dependencies make that replacement lossless.
# Usage: scripts/e2e-upgrade.sh [pg_container]
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init upgrade "${1:-}"
e2e_gate
EXTDIR=$(docker exec "$PG_CT" pg_config --sharedir)/extension
docker cp "$(dirname "$0")/../tests/e2e/fixtures/pg_logtap--0.1.0.sql" \
  "$PG_CT:$EXTDIR/" >/dev/null \
  || fail "upgrade: could not install the 0.1.0 test fixture"

SCHEMA=logtap_ext
PROBE_ROLE=lt_upgrade_probe_$$
OWNER_ROLE=lt_upgrade_owner_$$
DB_DIRECT=lt_up_direct_$$
DB_CANONICAL=lt_up_canonical_$$
DB_HISTORICAL=lt_up_historical_$$
DB_041=lt_up_041_$$
DB_OWNER=lt_up_owner_$$
DB_QUOTED=lt_up_quoted_$$
DATABASES="$DB_DIRECT $DB_CANONICAL $DB_HISTORICAL $DB_041 $DB_OWNER $DB_QUOTED"
CANONICAL_ORDER='events_captured,events_dropped,events_sent,events_queued,events_replayed,events_compacted,queue_backlog,delivered,events_lost,send_cycles_failed,ring_events,ring_capacity,dns_fail_streak,fallback_broken,fb_sync_failures,redact_pattern_failed,warn_tls_no_verify,warn_fallback_open,warn_fallback_skipped,warn_fallback_unbounded'

query() { # query <database> <sql>
  docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -At -d "$1" -c "$2"
}
psql_db() { # psql_db <database>, SQL on stdin
  docker exec -i "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -d "$1"
}
object_ids() {
  query "$1" "SELECT '$SCHEMA.pg_logtap_stats_t'::regtype::oid || '|' || '$SCHEMA.pg_logtap_delivery'::regclass::oid"
}
column_order() {
  query "$1" "SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_catalog.pg_attribute WHERE attrelid = '$SCHEMA.pg_logtap_stats_t'::regclass AND attnum > 0 AND NOT attisdropped"
}
extversion() {
  query "$1" "SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_logtap'"
}
expect_update_fail() { # <database> <reason> [diagnostic fragment]
  update_oids_before=$(object_ids "$1") \
    || fail "upgrade: could not read OIDs before $2"
  update_order_before=$(column_order "$1") \
    || fail "upgrade: could not read column order before $2"
  update_fingerprint_before=$(fingerprint "$1") \
    || fail "upgrade: could not fingerprint before $2"
  if update_error=$(docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -d "$1" \
    -c "ALTER EXTENSION pg_logtap UPDATE TO '0.6.1'" 2>&1); then
    fail "upgrade: accepted $2"
  fi
  case "$update_error" in
    *"${3:-}"*) ;;
    *) fail "upgrade: rejected $2 for the wrong reason: $update_error" ;;
  esac
  [ "$(extversion "$1")" = 0.6.0 ] \
    || fail "upgrade: rejected $2 but changed extversion"
  [ "$(object_ids "$1")" = "$update_oids_before" ] \
    || fail "upgrade: rejected $2 but changed OIDs"
  [ "$(column_order "$1")" = "$update_order_before" ] \
    || fail "upgrade: rejected $2 but changed column order"
  [ "$(fingerprint "$1")" = "$update_fingerprint_before" ] \
    || fail "upgrade: rejected $2 but changed SQL API fingerprint"
}
create_database() {
  docker exec "$PG_CT" dropdb -U postgres --if-exists --force "$1" >/dev/null 2>&1
  docker exec "$PG_CT" createdb -U postgres "$1"
}
install_version() { # <database> <version>
  psql_db "$1" >/dev/null <<SQL
CREATE SCHEMA $SCHEMA;
CREATE EXTENSION pg_logtap WITH SCHEMA $SCHEMA VERSION '$2';
SQL
}
cleanup() {
  for database in $DATABASES; do
    docker exec "$PG_CT" dropdb -U postgres --if-exists --force "$database" >/dev/null 2>&1
  done
  docker exec "$PG_CT" psql -X -U postgres \
    -qc "DROP ROLE IF EXISTS $PROBE_ROLE" \
    -qc "DROP ROLE IF EXISTS $OWNER_ROLE" >/dev/null 2>&1
}
trap cleanup EXIT

check_final() { # <database>
  psql_db "$1" >/dev/null <<SQL
DO \$check\$
DECLARE
    extension_oid oid;
    extension_owner oid;
    monitor_oid oid;
    type_oid oid := '$SCHEMA.pg_logtap_stats_t'::regtype;
    view_oid oid := '$SCHEMA.pg_logtap_delivery'::regclass;
    got text;
    function_count integer;
BEGIN
    SELECT e.oid, e.extowner
      INTO extension_oid, extension_owner
      FROM pg_catalog.pg_extension AS e
      JOIN pg_catalog.pg_namespace AS n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_logtap'
       AND e.extversion = '0.6.1'
       AND n.oid = (SELECT t.typnamespace FROM pg_catalog.pg_type AS t
                     WHERE t.oid = type_oid);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'wrong extension version or schema';
    END IF;

    SELECT r.oid INTO monitor_oid
      FROM pg_catalog.pg_roles AS r WHERE r.rolname = 'pg_monitor';

    SELECT string_agg(a.attname::text, ',' ORDER BY a.attnum)
      INTO got
      FROM pg_catalog.pg_attribute AS a
     WHERE a.attrelid = type_oid
       AND a.attnum > 0
       AND NOT a.attisdropped;
    IF got <> '$CANONICAL_ORDER' THEN
        RAISE EXCEPTION 'noncanonical type order: %', got;
    END IF;

    SELECT string_agg(a.attname::text, ',' ORDER BY a.attnum)
      INTO got
      FROM pg_catalog.pg_attribute AS a
     WHERE a.attrelid = view_oid
       AND a.attnum > 0
       AND NOT a.attisdropped;
    IF got <> '$CANONICAL_ORDER' THEN
        RAISE EXCEPTION 'noncanonical view order: %', got;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_attribute AS a
         WHERE a.attrelid IN (
                   (SELECT t.typrelid FROM pg_catalog.pg_type AS t
                     WHERE t.oid = type_oid),
                   view_oid)
           AND a.attnum > 0
           AND (a.attisdropped
             OR (a.attname IN ('ring_events', 'ring_capacity')
                 AND a.atttypid <> 'pg_catalog.int4'::regtype)
             OR (a.attname NOT IN ('ring_events', 'ring_capacity')
                 AND a.atttypid <> 'pg_catalog.int8'::regtype))
    ) THEN
        RAISE EXCEPTION 'wrong pg_logtap column type';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_type AS t
          JOIN pg_catalog.pg_class AS c ON c.oid = t.typrelid
          JOIN pg_catalog.pg_type AS a ON a.oid = t.typarray
          JOIN pg_catalog.pg_class AS v ON v.oid = view_oid
         WHERE t.oid = type_oid
           AND (t.typowner <> extension_owner
             OR c.relowner <> extension_owner
             OR a.typowner <> extension_owner
             OR v.relowner <> extension_owner)
    ) THEN
        RAISE EXCEPTION 'pg_logtap object owner differs from extension owner';
    END IF;

    SELECT count(*) INTO function_count
      FROM pg_catalog.pg_proc AS p
     WHERE p.pronamespace = (SELECT e.extnamespace
                               FROM pg_catalog.pg_extension AS e
                              WHERE e.oid = extension_oid)
       AND p.proname IN ('pg_logtap_version', 'pg_logtap_stats',
                         'pg_logtap_dump', 'pg_logtap_stats_json');
    IF function_count <> 4 THEN
        RAISE EXCEPTION 'wrong function set';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS p
         WHERE p.oid = '$SCHEMA.pg_logtap_version()'::regprocedure
           AND p.prorettype = 'pg_catalog.text'::regtype
           AND p.pronargs = 0 AND p.pronargdefaults = 0
           AND p.proisstrict AND p.provolatile = 'i' AND p.proparallel = 's'
           AND p.prosrc = 'pg_logtap_version'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS p
         WHERE p.oid = '$SCHEMA.pg_logtap_stats()'::regprocedure
           AND p.prorettype = 'pg_catalog.text'::regtype
           AND p.pronargs = 0 AND p.pronargdefaults = 0
           AND p.proisstrict AND p.provolatile = 'v' AND p.proparallel = 'u'
           AND p.prosrc = 'pg_logtap_stats'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS p
         WHERE p.oid = '$SCHEMA.pg_logtap_stats_json()'::regprocedure
           AND p.prorettype = 'pg_catalog.text'::regtype
           AND p.pronargs = 0 AND p.pronargdefaults = 0
           AND p.proisstrict AND p.provolatile = 'v' AND p.proparallel = 'u'
           AND p.prosrc = 'pg_logtap_stats_json'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS p
         WHERE p.oid = '$SCHEMA.pg_logtap_dump(integer)'::regprocedure
           AND p.prorettype = 'pg_catalog._text'::regtype
           AND p.pronargs = 1 AND p.proargtypes[0] = 'pg_catalog.int4'::regtype
           AND p.pronargdefaults = 1 AND NOT p.proisstrict
           AND p.provolatile = 'v' AND p.proparallel = 'u'
           AND p.prosrc = 'pg_logtap_dump'
           AND pg_catalog.pg_get_function_arguments(p.oid) = 'row_limit integer DEFAULT 100'
    ) THEN
        RAISE EXCEPTION 'wrong function signature or property';
    END IF;

    IF $SCHEMA.pg_logtap_version() <> '0.6.1' THEN
        RAISE EXCEPTION 'binary/SQL version mismatch';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc AS p
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS x
         WHERE p.oid IN (
                   '$SCHEMA.pg_logtap_dump(integer)'::regprocedure,
                   '$SCHEMA.pg_logtap_stats()'::regprocedure,
                   '$SCHEMA.pg_logtap_stats_json()'::regprocedure)
           AND x.grantee NOT IN (p.proowner, monitor_oid)
    ) OR EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc AS p
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS x
         WHERE p.oid = '$SCHEMA.pg_logtap_dump(integer)'::regprocedure
           AND x.grantee = monitor_oid
    ) OR NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc AS p
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS x
         WHERE p.oid = '$SCHEMA.pg_logtap_stats()'::regprocedure
           AND x.grantee = monitor_oid
           AND x.privilege_type = 'EXECUTE'
           AND NOT x.is_grantable
    ) OR NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc AS p
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS x
         WHERE p.oid = '$SCHEMA.pg_logtap_stats_json()'::regprocedure
           AND x.grantee = monitor_oid
           AND x.privilege_type = 'EXECUTE'
           AND NOT x.is_grantable
    ) THEN
        RAISE EXCEPTION 'wrong function ACL';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_class AS c
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) AS x
         WHERE c.oid = view_oid
           AND x.grantee NOT IN (c.relowner, monitor_oid)
    ) OR NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_class AS c
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) AS x
         WHERE c.oid = view_oid
           AND x.grantee = monitor_oid
           AND x.privilege_type = 'SELECT'
           AND NOT x.is_grantable
    ) THEN
        RAISE EXCEPTION 'wrong view ACL';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_depend AS d
         WHERE d.classid = 'pg_catalog.pg_type'::regclass
           AND d.objid = type_oid
           AND d.refclassid = 'pg_catalog.pg_extension'::regclass
           AND d.refobjid = extension_oid AND d.deptype = 'e'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_depend AS d
         WHERE d.classid = 'pg_catalog.pg_class'::regclass
           AND d.objid = view_oid
           AND d.refclassid = 'pg_catalog.pg_extension'::regclass
           AND d.refobjid = extension_oid AND d.deptype = 'e'
    ) THEN
        RAISE EXCEPTION 'objects lost extension membership';
    END IF;
END
\$check\$;
SELECT count(*) FROM $SCHEMA.pg_logtap_delivery;
SQL
}

fingerprint() { # OID-independent final SQL API fingerprint
  query "$1" "
WITH extension_data AS (
    SELECT e.oid, e.extversion, e.extnamespace
      FROM pg_catalog.pg_extension AS e
     WHERE e.extname = 'pg_logtap'
), functions AS (
    SELECT string_agg(
               p.proname || ':' || pg_catalog.pg_get_function_arguments(p.oid)
               || ':' || pg_catalog.pg_get_function_result(p.oid)
               || ':' || p.provolatile::text || p.proparallel::text
               || p.proisstrict::text || ':' || coalesce(p.proacl::text, '<null>'),
               E'\\n' ORDER BY p.proname) AS value
      FROM pg_catalog.pg_proc AS p, extension_data AS e
     WHERE p.pronamespace = e.extnamespace
       AND p.proname LIKE 'pg_logtap_%'
), members AS (
    SELECT string_agg(
               pg_catalog.pg_describe_object(d.classid, d.objid, d.objsubid),
               E'\\n' ORDER BY pg_catalog.pg_describe_object(
                   d.classid, d.objid, d.objsubid)) AS value
      FROM pg_catalog.pg_depend AS d, extension_data AS e
     WHERE d.refclassid = 'pg_catalog.pg_extension'::regclass
       AND d.refobjid = e.oid
       AND d.deptype = 'e'
)
SELECT md5(concat_ws(E'\\n',
    e.extversion,
    (SELECT n.nspname FROM pg_catalog.pg_namespace AS n
      WHERE n.oid = e.extnamespace),
    (SELECT string_agg(a.attname::text || ':'
                       || pg_catalog.format_type(a.atttypid, a.atttypmod),
                       ',' ORDER BY a.attnum)
       FROM pg_catalog.pg_attribute AS a
      WHERE a.attrelid = '$SCHEMA.pg_logtap_stats_t'::regclass
        AND a.attnum > 0 AND NOT a.attisdropped),
    (SELECT string_agg(a.attname::text || ':'
                       || pg_catalog.format_type(a.atttypid, a.atttypmod),
                       ',' ORDER BY a.attnum)
       FROM pg_catalog.pg_attribute AS a
      WHERE a.attrelid = '$SCHEMA.pg_logtap_delivery'::regclass
        AND a.attnum > 0 AND NOT a.attisdropped),
    pg_catalog.pg_get_viewdef('$SCHEMA.pg_logtap_delivery'::regclass, false),
    (SELECT value FROM functions),
    (SELECT t.typacl::text FROM pg_catalog.pg_type AS t
      WHERE t.oid = '$SCHEMA.pg_logtap_stats_t'::regtype),
    (SELECT c.relacl::text FROM pg_catalog.pg_class AS c
      WHERE c.oid = '$SCHEMA.pg_logtap_delivery'::regclass),
    (SELECT value FROM members)
))
  FROM extension_data AS e"
}

routes=$(query postgres "SELECT count(*) FROM pg_catalog.pg_extension_update_paths('pg_logtap') WHERE source IN ('0.1.0', '0.4.1', '0.6.0') AND target = '0.6.1' AND path IS NOT NULL")
[ "$routes" = 3 ] || fail "upgrade: expected three update routes to 0.6.1, got $routes"

docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 \
  -qc "DROP ROLE IF EXISTS $PROBE_ROLE" \
  -qc "DROP ROLE IF EXISTS $OWNER_ROLE" \
  -qc "CREATE ROLE $PROBE_ROLE" \
  -qc "CREATE ROLE $OWNER_ROLE SUPERUSER" >/dev/null
for database in $DATABASES; do create_database "$database"; done

# Direct 0.6.1 installation is the reference fingerprint.
install_version "$DB_DIRECT" 0.6.1
check_final "$DB_DIRECT" || fail "upgrade: direct 0.6.1 shape check failed"
reference=$(fingerprint "$DB_DIRECT") \
  || fail "upgrade: could not fingerprint direct 0.6.1"

# Fresh 0.6.0 is already canonical: dependencies, OIDs and custom metadata
# must survive because this path performs no object DDL.
install_version "$DB_CANONICAL" 0.6.0
# Roll back this probe so explicit baseline ACLs do not affect the clean
# direct-install fingerprint checked below.
psql_db "$DB_CANONICAL" >/dev/null <<SQL || fail "upgrade: canonical extended metadata probe failed"
BEGIN;
ALTER VIEW $SCHEMA.pg_logtap_delivery ALTER COLUMN events_sent SET DEFAULT 7;
COMMENT ON TYPE $SCHEMA.pg_logtap_delivery IS 'canonical rowtype comment';
COMMENT ON TYPE $SCHEMA._pg_logtap_delivery IS 'canonical array comment';
REVOKE USAGE ON TYPE $SCHEMA.pg_logtap_delivery FROM PUBLIC;
DO \$check\$
DECLARE
    type_oid oid := '$SCHEMA.pg_logtap_stats_t'::regtype;
    view_oid oid := '$SCHEMA.pg_logtap_delivery'::regclass;
    rowtype_oid oid := '$SCHEMA.pg_logtap_delivery'::regtype;
    array_oid oid := (SELECT typarray FROM pg_catalog.pg_type WHERE oid = rowtype_oid);
BEGIN
    ALTER EXTENSION pg_logtap UPDATE TO '0.6.1';
    IF '$SCHEMA.pg_logtap_stats_t'::regtype::oid <> type_oid
       OR '$SCHEMA.pg_logtap_delivery'::regclass::oid <> view_oid
       OR '$SCHEMA.pg_logtap_delivery'::regtype::oid <> rowtype_oid
       OR (SELECT typarray FROM pg_catalog.pg_type WHERE oid = rowtype_oid) <> array_oid
       OR NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_extension
            WHERE extname = 'pg_logtap' AND extversion = '0.6.1'
       ) THEN
        RAISE EXCEPTION 'canonical update changed OIDs or failed to update version';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute AS a
        JOIN pg_catalog.pg_attrdef AS d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
         WHERE a.attrelid = view_oid AND a.attname = 'events_sent'
           AND a.atthasdef AND pg_catalog.pg_get_expr(d.adbin, d.adrelid) = '7'
    ) OR pg_catalog.obj_description(rowtype_oid, 'pg_type') IS DISTINCT FROM 'canonical rowtype comment'
      OR pg_catalog.obj_description(array_oid, 'pg_type') IS DISTINCT FROM 'canonical array comment'
      OR EXISTS (
          SELECT 1 FROM pg_catalog.pg_type AS t
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(t.typacl, pg_catalog.acldefault('T', t.typowner))) AS x
           WHERE t.oid = rowtype_oid AND x.grantee = 0 AND x.privilege_type = 'USAGE'
      ) THEN
        RAISE EXCEPTION 'canonical update lost default, type comment or revoked privileges';
    END IF;
END
\$check\$;
ROLLBACK;
SQL
canonical_before=$(object_ids "$DB_CANONICAL")
psql_db "$DB_CANONICAL" >/dev/null <<SQL
CREATE VIEW public.keep_delivery AS SELECT * FROM $SCHEMA.pg_logtap_delivery;
CREATE TABLE public.keep_stats (snapshot $SCHEMA.pg_logtap_stats_t);
GRANT SELECT ON $SCHEMA.pg_logtap_delivery TO $PROBE_ROLE;
COMMENT ON VIEW $SCHEMA.pg_logtap_delivery IS 'canonical metadata survives';
ALTER EXTENSION pg_logtap UPDATE TO '0.6.1';
SQL
canonical_after=$(object_ids "$DB_CANONICAL")
[ "$canonical_after" = "$canonical_before" ] \
  || fail "upgrade: canonical 0.6.0 update changed type/view OIDs"
[ "$(query "$DB_CANONICAL" "SELECT count(*) FROM public.keep_delivery")" = 1 ] \
  || fail "upgrade: canonical dependent view did not survive"
query "$DB_CANONICAL" "SELECT count(*) FROM public.keep_stats" >/dev/null \
  || fail "upgrade: canonical dependent table did not survive"
[ "$(query "$DB_CANONICAL" "SELECT has_table_privilege('$PROBE_ROLE', '$SCHEMA.pg_logtap_delivery', 'SELECT')")" = t ] \
  || fail "upgrade: canonical view grant did not survive"
[ "$(query "$DB_CANONICAL" "SELECT obj_description('$SCHEMA.pg_logtap_delivery'::regclass, 'pg_class')")" = 'canonical metadata survives' ] \
  || fail "upgrade: canonical view comment did not survive"
query "$DB_CANONICAL" "REVOKE SELECT ON $SCHEMA.pg_logtap_delivery FROM $PROBE_ROLE; COMMENT ON VIEW $SCHEMA.pg_logtap_delivery IS NULL" >/dev/null
check_final "$DB_CANONICAL" || fail "upgrade: canonical 0.6.0 shape check failed"
canonical_fingerprint=$(fingerprint "$DB_CANONICAL") \
  || fail "upgrade: could not fingerprint canonical 0.6.0 chain"
[ "$canonical_fingerprint" = "$reference" ] \
  || fail "upgrade: canonical 0.6.0 fingerprint differs"

# 0.1.0 follows every historical hop. External dependencies must make the
# noncanonical replacement fail transactionally, then clean retry must work.
install_version "$DB_HISTORICAL" 0.1.0
query "$DB_HISTORICAL" "ALTER EXTENSION pg_logtap UPDATE TO '0.6.0'" >/dev/null
[ "$(column_order "$DB_HISTORICAL")" != "$CANONICAL_ORDER" ] \
  || fail "upgrade: 0.1.0 chain did not produce its historical order"
historical_before=$(object_ids "$DB_HISTORICAL")
historical_order=$(column_order "$DB_HISTORICAL")
psql_db "$DB_HISTORICAL" >/dev/null <<SQL
CREATE VIEW public.keep_delivery AS SELECT * FROM $SCHEMA.pg_logtap_delivery;
CREATE TABLE public.keep_stats (snapshot $SCHEMA.pg_logtap_stats_t);
SQL
expect_update_fail "$DB_HISTORICAL" 'historical objects with external dependencies'
[ "$(object_ids "$DB_HISTORICAL")" = "$historical_before" ] \
  || fail "upgrade: dependency failure changed historical OIDs"
[ "$(column_order "$DB_HISTORICAL")" = "$historical_order" ] \
  || fail "upgrade: dependency failure changed historical order"
[ "$(query "$DB_HISTORICAL" "SELECT count(*) FROM public.keep_delivery")" = 1 ] \
  || fail "upgrade: dependency failure lost external view"
query "$DB_HISTORICAL" "SELECT count(*) FROM public.keep_stats" >/dev/null \
  || fail "upgrade: dependency failure lost external table"

# With the external view gone, DROP VIEW succeeds inside the update and the
# table's composite-type dependency must make DROP TYPE fail. Transactional
# DDL must restore the extension view and both OIDs.
query "$DB_HISTORICAL" "DROP VIEW public.keep_delivery" >/dev/null
expect_update_fail "$DB_HISTORICAL" 'historical type dependency'
[ "$(object_ids "$DB_HISTORICAL")" = "$historical_before" ] \
  || fail "upgrade: type-dependency failure did not restore type/view OIDs"
[ "$(column_order "$DB_HISTORICAL")" = "$historical_order" ] \
  || fail "upgrade: type-dependency failure changed historical order"
query "$DB_HISTORICAL" "SELECT count(*) FROM public.keep_stats" >/dev/null \
  || fail "upgrade: type-dependency failure lost external table"

psql_db "$DB_HISTORICAL" >/dev/null <<SQL
DROP TABLE public.keep_stats;
ALTER EXTENSION pg_logtap UPDATE TO '0.6.1';
SQL
[ "$(object_ids "$DB_HISTORICAL")" != "$historical_before" ] \
  || fail "upgrade: historical normalization preserved stale OIDs"
check_final "$DB_HISTORICAL" || fail "upgrade: historical chain shape check failed"
historical_fingerprint=$(fingerprint "$DB_HISTORICAL") \
  || fail "upgrade: could not fingerprint historical chain"
[ "$historical_fingerprint" = "$reference" ] \
  || fail "upgrade: historical chain fingerprint differs"

# Direct 0.4.1 has the third released order. Exercise representative
# fail-closed metadata guards before a clean normalization.
install_version "$DB_041" 0.4.1
query "$DB_041" "ALTER EXTENSION pg_logtap UPDATE TO '0.6.0'" >/dev/null
[ "$(column_order "$DB_041")" != "$CANONICAL_ORDER" ] \
  || fail "upgrade: direct 0.4.1 did not produce its historical order"
order_041=$(column_order "$DB_041")
oids_041=$(object_ids "$DB_041")

query "$DB_041" "ALTER VIEW $SCHEMA.pg_logtap_delivery OWNER TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'owner drift'
query "$DB_041" "ALTER VIEW $SCHEMA.pg_logtap_delivery OWNER TO postgres" >/dev/null

query "$DB_041" "GRANT SELECT ON $SCHEMA.pg_logtap_delivery TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'custom view ACL'
query "$DB_041" "REVOKE ALL ON $SCHEMA.pg_logtap_delivery FROM $PROBE_ROLE" >/dev/null

query "$DB_041" "GRANT SELECT (events_captured) ON $SCHEMA.pg_logtap_delivery TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'column ACL'
query "$DB_041" "REVOKE SELECT (events_captured) ON $SCHEMA.pg_logtap_delivery FROM $PROBE_ROLE" >/dev/null

query "$DB_041" "GRANT USAGE ON TYPE $SCHEMA.pg_logtap_stats_t TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'custom type ACL'
query "$DB_041" "REVOKE USAGE ON TYPE $SCHEMA.pg_logtap_stats_t FROM $PROBE_ROLE" >/dev/null

query "$DB_041" "ALTER VIEW $SCHEMA.pg_logtap_delivery ALTER COLUMN events_sent SET DEFAULT 7" >/dev/null \
  || fail "upgrade: could not stage view default"
expect_update_fail "$DB_041" 'view column default' 'custom ACLs, defaults or options'
[ "$(query "$DB_041" "SELECT a.atthasdef AND pg_get_expr(d.adbin, d.adrelid) = '7' FROM pg_catalog.pg_attribute AS a JOIN pg_catalog.pg_attrdef AS d ON d.adrelid = a.attrelid AND d.adnum = a.attnum WHERE a.attrelid = '$SCHEMA.pg_logtap_delivery'::regclass AND a.attname = 'events_sent'")" = t ] \
  || fail "upgrade: refused update lost the view default"
query "$DB_041" "ALTER VIEW $SCHEMA.pg_logtap_delivery ALTER COLUMN events_sent DROP DEFAULT" >/dev/null \
  || fail "upgrade: could not remove view default"

query "$DB_041" "COMMENT ON TYPE $SCHEMA.pg_logtap_delivery IS 'historical rowtype comment'" >/dev/null \
  || fail "upgrade: could not stage rowtype comment"
expect_update_fail "$DB_041" 'implicit rowtype comment' 'comments or security labels'
[ "$(query "$DB_041" "SELECT obj_description('$SCHEMA.pg_logtap_delivery'::regtype, 'pg_type')")" = 'historical rowtype comment' ] \
  || fail "upgrade: refused update lost rowtype comment"
query "$DB_041" "COMMENT ON TYPE $SCHEMA.pg_logtap_delivery IS NULL" >/dev/null \
  || fail "upgrade: could not remove rowtype comment"

query "$DB_041" "COMMENT ON TYPE $SCHEMA._pg_logtap_delivery IS 'historical array comment'" >/dev/null \
  || fail "upgrade: could not stage rowtype array comment"
expect_update_fail "$DB_041" 'implicit rowtype array comment' 'comments or security labels'
[ "$(query "$DB_041" "SELECT obj_description(typarray, 'pg_type') FROM pg_catalog.pg_type WHERE oid = '$SCHEMA.pg_logtap_delivery'::regtype")" = 'historical array comment' ] \
  || fail "upgrade: refused update lost rowtype array comment"
query "$DB_041" "COMMENT ON TYPE $SCHEMA._pg_logtap_delivery IS NULL" >/dev/null \
  || fail "upgrade: could not remove rowtype array comment"

query "$DB_041" "REVOKE USAGE ON TYPE $SCHEMA.pg_logtap_delivery FROM PUBLIC" >/dev/null \
  || fail "upgrade: could not revoke rowtype PUBLIC USAGE"
rowtype_acl=$(query "$DB_041" "SELECT typacl::text FROM pg_catalog.pg_type WHERE oid = '$SCHEMA.pg_logtap_delivery'::regtype") \
  || fail "upgrade: could not read rowtype ACL"
expect_update_fail "$DB_041" 'implicit rowtype revoked PUBLIC USAGE' 'composite types have nonbaseline privileges'
[ "$(query "$DB_041" "SELECT typacl::text FROM pg_catalog.pg_type WHERE oid = '$SCHEMA.pg_logtap_delivery'::regtype")" = "$rowtype_acl" ] \
  || fail "upgrade: refused update changed revoked rowtype privileges"
query "$DB_041" "GRANT USAGE ON TYPE $SCHEMA.pg_logtap_delivery TO PUBLIC" >/dev/null \
  || fail "upgrade: could not restore rowtype baseline privileges"

query "$DB_041" "GRANT USAGE ON TYPE $SCHEMA.pg_logtap_delivery TO $PROBE_ROLE" >/dev/null \
  || fail "upgrade: could not stage custom rowtype grant"
rowtype_acl=$(query "$DB_041" "SELECT typacl::text FROM pg_catalog.pg_type WHERE oid = '$SCHEMA.pg_logtap_delivery'::regtype") \
  || fail "upgrade: could not read custom rowtype ACL"
expect_update_fail "$DB_041" 'implicit rowtype custom grant' 'composite types have nonbaseline privileges'
[ "$(query "$DB_041" "SELECT typacl::text FROM pg_catalog.pg_type WHERE oid = '$SCHEMA.pg_logtap_delivery'::regtype")" = "$rowtype_acl" ] \
  || fail "upgrade: refused update lost custom rowtype grant"
query "$DB_041" "REVOKE USAGE ON TYPE $SCHEMA.pg_logtap_delivery FROM $PROBE_ROLE" >/dev/null \
  || fail "upgrade: could not restore rowtype baseline ACL"

psql_db "$DB_041" >/dev/null <<SQL
CREATE OR REPLACE VIEW $SCHEMA.pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(
  NULL::$SCHEMA.pg_logtap_stats_t,
  $SCHEMA.pg_logtap_stats_json()::jsonb
) WHERE false;
SQL
expect_update_fail "$DB_041" 'custom view definition'
psql_db "$DB_041" >/dev/null <<SQL
CREATE OR REPLACE VIEW $SCHEMA.pg_logtap_delivery AS
SELECT * FROM jsonb_populate_record(
  NULL::$SCHEMA.pg_logtap_stats_t,
  $SCHEMA.pg_logtap_stats_json()::jsonb
);
SQL

query "$DB_041" "ALTER DEFAULT PRIVILEGES IN SCHEMA $SCHEMA GRANT SELECT ON TABLES TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'schema table default ACL'
query "$DB_041" "ALTER DEFAULT PRIVILEGES IN SCHEMA $SCHEMA REVOKE SELECT ON TABLES FROM $PROBE_ROLE" >/dev/null

query "$DB_041" "ALTER DEFAULT PRIVILEGES IN SCHEMA $SCHEMA GRANT USAGE ON TYPES TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'schema type default ACL'
query "$DB_041" "ALTER DEFAULT PRIVILEGES IN SCHEMA $SCHEMA REVOKE USAGE ON TYPES FROM $PROBE_ROLE" >/dev/null

query "$DB_041" "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO $PROBE_ROLE" >/dev/null
expect_update_fail "$DB_041" 'global table default ACL'
query "$DB_041" "ALTER DEFAULT PRIVILEGES REVOKE SELECT ON TABLES FROM $PROBE_ROLE" >/dev/null

[ "$(object_ids "$DB_041")" = "$oids_041" ] \
  || fail "upgrade: rejected metadata changed 0.4.1-chain OIDs"
[ "$(column_order "$DB_041")" = "$order_041" ] \
  || fail "upgrade: rejected metadata changed 0.4.1-chain order"
query "$DB_041" "ALTER EXTENSION pg_logtap UPDATE TO '0.6.1'" >/dev/null
[ "$(object_ids "$DB_041")" != "$oids_041" ] \
  || fail "upgrade: 0.4.1-chain normalization preserved stale OIDs"
check_final "$DB_041" || fail "upgrade: 0.4.1 chain shape check failed"
fingerprint_041=$(fingerprint "$DB_041") \
  || fail "upgrade: could not fingerprint 0.4.1 chain"
[ "$fingerprint_041" = "$reference" ] \
  || fail "upgrade: 0.4.1 chain fingerprint differs"

# Recreate under a superuser different from the extension owner: the migration
# must restore ownership, and default ACLs owned by either role must block it.
psql_db "$DB_OWNER" >/dev/null <<SQL
CREATE SCHEMA $SCHEMA AUTHORIZATION $OWNER_ROLE;
SET ROLE $OWNER_ROLE;
CREATE EXTENSION pg_logtap WITH SCHEMA $SCHEMA VERSION '0.4.1';
ALTER EXTENSION pg_logtap UPDATE TO '0.6.0';
ALTER DEFAULT PRIVILEGES IN SCHEMA $SCHEMA GRANT USAGE ON TYPES TO $PROBE_ROLE;
RESET ROLE;
SQL
expect_update_fail "$DB_OWNER" 'extension-owner default ACL'
psql_db "$DB_OWNER" >/dev/null <<SQL
SET ROLE $OWNER_ROLE;
ALTER DEFAULT PRIVILEGES IN SCHEMA $SCHEMA REVOKE USAGE ON TYPES FROM $PROBE_ROLE;
RESET ROLE;
ALTER EXTENSION pg_logtap UPDATE TO '0.6.1';
SQL
check_final "$DB_OWNER" || fail "upgrade: non-invoking owner was not restored"
[ "$(query "$DB_OWNER" "SELECT pg_get_userbyid(extowner) FROM pg_catalog.pg_extension WHERE extname = 'pg_logtap'")" = "$OWNER_ROLE" ] \
  || fail "upgrade: owner scenario changed extension owner"

# Compare within the same namespace: fingerprints intentionally include schema
# names. Quoted identifiers and alias-like names must not be rewritten.
for SCHEMA in '"two  spaces"' '"embedded""quote"' pre_jsonb_populate_record '"jsonb_populate_record.schema"'; do
  for origin in 0.1.0 0.4.1; do
    create_database "$DB_QUOTED" || fail "upgrade: could not create quoted-schema reference database"
    install_version "$DB_QUOTED" 0.6.1 || fail "upgrade: quoted-schema direct installation failed"
    check_final "$DB_QUOTED" || fail "upgrade: quoted-schema direct shape check failed"
    quoted_reference=$(fingerprint "$DB_QUOTED") \
      || fail "upgrade: could not fingerprint quoted-schema direct installation"
    create_database "$DB_QUOTED" || fail "upgrade: could not recreate quoted-schema database"
    install_version "$DB_QUOTED" "$origin" || fail "upgrade: quoted-schema historical installation failed"
    query "$DB_QUOTED" "ALTER EXTENSION pg_logtap UPDATE TO '0.6.0'" >/dev/null \
      || fail "upgrade: quoted-schema historical hop failed"
    [ "$(column_order "$DB_QUOTED")" != "$CANONICAL_ORDER" ] \
      || fail "upgrade: quoted-schema origin $origin did not produce historical order"
    query "$DB_QUOTED" "ALTER EXTENSION pg_logtap UPDATE TO '0.6.1'" >/dev/null \
      || fail "upgrade: normalization failed in schema $SCHEMA from $origin"
    check_final "$DB_QUOTED" || fail "upgrade: quoted-schema normalized shape check failed"
    quoted_fingerprint=$(fingerprint "$DB_QUOTED") \
      || fail "upgrade: could not fingerprint quoted-schema historical upgrade"
    [ "$quoted_fingerprint" = "$quoted_reference" ] \
      || fail "upgrade: quoted-schema historical fingerprint differs"
  done
  ok "historical origins converged in schema $SCHEMA"
done
SCHEMA=logtap_ext

ok "direct, canonical and historical origins converged; OID/dependency/metadata/ACL/owner guards passed"
