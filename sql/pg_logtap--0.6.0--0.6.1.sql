/* 0.6.0 → 0.6.1: normalize the physical order of pg_logtap_stats_t and
   pg_logtap_delivery. Fresh 0.6.0 installs already have the canonical order;
   historical ALTER EXTENSION chains appended fields and can have either of
   two older orders. The canonical path deliberately performs no object DDL,
   preserving OIDs and external dependencies. */
DO $migration$
DECLARE
    extension_oid oid;
    extension_schema_oid oid;
    extension_owner oid;
    invoking_role oid;
    extension_schema name;
    stats_oid oid;
    stats_relation_oid oid;
    stats_array_oid oid;
    delivery_oid oid;
    delivery_type_oid oid;
    delivery_array_oid oid;
    stats_json_oid oid;
    monitor_oid oid;
    stats_order text[];
    delivery_order text[];
    column_list text;
    qualified_column_list text;
    actual_view_definition text;
    expected_view_tail text;
    saved_search_path text;
    canonical_order constant text[] := ARRAY[
        'events_captured',
        'events_dropped',
        'events_sent',
        'events_queued',
        'events_replayed',
        'events_compacted',
        'queue_backlog',
        'delivered',
        'events_lost',
        'send_cycles_failed',
        'ring_events',
        'ring_capacity',
        'dns_fail_streak',
        'fallback_broken',
        'fb_sync_failures',
        'redact_pattern_failed',
        'warn_tls_no_verify',
        'warn_fallback_open',
        'warn_fallback_skipped',
        'warn_fallback_unbounded'
    ];
    attribute_count integer;
    dropped_count integer;
    mismatch_count integer;
    metadata_count integer;
    acl_matches boolean;
BEGIN
    SELECT e.oid, e.extnamespace, e.extowner, n.nspname
      INTO extension_oid, extension_schema_oid, extension_owner,
           extension_schema
      FROM pg_catalog.pg_extension AS e
      JOIN pg_catalog.pg_namespace AS n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_logtap';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_logtap extension catalog entry is missing';
    END IF;

    SELECT r.oid
      INTO invoking_role
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = current_user;

    SELECT r.oid
      INTO monitor_oid
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = 'pg_monitor';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'required role pg_monitor is missing';
    END IF;

    SELECT t.oid, t.typrelid, t.typarray
      INTO stats_oid, stats_relation_oid, stats_array_oid
      FROM pg_catalog.pg_type AS t
      JOIN pg_catalog.pg_class AS c ON c.oid = t.typrelid
     WHERE t.typnamespace = extension_schema_oid
       AND t.typname = 'pg_logtap_stats_t'
       AND t.typtype = 'c'
       AND c.relkind = 'c';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'pg_logtap_stats_t is not the expected composite type in schema %',
            extension_schema;
    END IF;

    SELECT c.oid, c.reltype, t.typarray
      INTO delivery_oid, delivery_type_oid, delivery_array_oid
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_type AS t ON t.oid = c.reltype
     WHERE c.relnamespace = extension_schema_oid
       AND c.relname = 'pg_logtap_delivery'
       AND c.relkind = 'v';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'pg_logtap_delivery is not the expected view in schema %',
            extension_schema;
    END IF;

    SELECT p.oid
      INTO stats_json_oid
      FROM pg_catalog.pg_proc AS p
     WHERE p.pronamespace = extension_schema_oid
       AND p.proname = 'pg_logtap_stats_json'
       AND p.pronargs = 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'pg_logtap_stats_json() is missing from schema %',
            extension_schema;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_depend AS d
         WHERE d.classid = 'pg_catalog.pg_type'::pg_catalog.regclass
           AND d.objid = stats_oid
           AND d.objsubid = 0
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid = extension_oid
           AND d.deptype = 'e'
    ) OR NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_depend AS d
         WHERE d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
           AND d.objid = delivery_oid
           AND d.objsubid = 0
           AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
           AND d.refobjid = extension_oid
           AND d.deptype = 'e'
    ) THEN
        RAISE EXCEPTION
            'pg_logtap_stats_t and pg_logtap_delivery must remain extension members';
    END IF;

    SELECT count(*), count(*) FILTER (WHERE a.attisdropped),
           array_agg(a.attname::text ORDER BY a.attnum)
      INTO attribute_count, dropped_count, stats_order
      FROM pg_catalog.pg_attribute AS a
     WHERE a.attrelid = stats_relation_oid
       AND a.attnum > 0;
    IF attribute_count <> 20 OR dropped_count <> 0 THEN
        RAISE EXCEPTION
            'pg_logtap_stats_t must have exactly 20 active attributes and no dropped attributes';
    END IF;

    WITH expected(attribute_name, type_oid) AS (
        VALUES
            ('events_captured', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('events_dropped', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('events_sent', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('events_queued', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('events_replayed', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('events_compacted', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('queue_backlog', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('delivered', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('events_lost', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('send_cycles_failed', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('ring_events', 'pg_catalog.int4'::pg_catalog.regtype::oid),
            ('ring_capacity', 'pg_catalog.int4'::pg_catalog.regtype::oid),
            ('dns_fail_streak', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('fallback_broken', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('fb_sync_failures', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('redact_pattern_failed', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('warn_tls_no_verify', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('warn_fallback_open', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('warn_fallback_skipped', 'pg_catalog.int8'::pg_catalog.regtype::oid),
            ('warn_fallback_unbounded', 'pg_catalog.int8'::pg_catalog.regtype::oid)
    ), actual AS (
        SELECT a.attname::text AS attribute_name, a.atttypid AS type_oid
          FROM pg_catalog.pg_attribute AS a
         WHERE a.attrelid = stats_relation_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
    )
    SELECT count(*)
      INTO mismatch_count
      FROM expected AS e
      FULL JOIN actual AS a USING (attribute_name)
     WHERE e.attribute_name IS NULL
        OR a.attribute_name IS NULL
        OR e.type_oid <> a.type_oid;
    IF mismatch_count <> 0 THEN
        RAISE EXCEPTION
            'pg_logtap_stats_t does not have the released 20-column name/type set';
    END IF;

    SELECT count(*), count(*) FILTER (WHERE a.attisdropped),
           array_agg(a.attname::text ORDER BY a.attnum)
      INTO attribute_count, dropped_count, delivery_order
      FROM pg_catalog.pg_attribute AS a
     WHERE a.attrelid = delivery_oid
       AND a.attnum > 0;
    IF attribute_count <> 20 OR dropped_count <> 0
       OR delivery_order IS DISTINCT FROM stats_order THEN
        RAISE EXCEPTION
            'pg_logtap_delivery must have the same 20-column order as pg_logtap_stats_t';
    END IF;

    SELECT count(*)
      INTO mismatch_count
      FROM pg_catalog.pg_attribute AS ta
      JOIN pg_catalog.pg_attribute AS va
        ON va.attrelid = delivery_oid
       AND va.attnum = ta.attnum
     WHERE ta.attrelid = stats_relation_oid
       AND ta.attnum > 0
       AND (ta.atttypid <> va.atttypid
         OR ta.atttypmod <> va.atttypmod
         OR ta.attcollation <> va.attcollation);
    IF mismatch_count <> 0 THEN
        RAISE EXCEPTION
            'pg_logtap_delivery column types do not match pg_logtap_stats_t';
    END IF;

    /* Fresh 0.6.0 is already canonical. Return before every metadata guard and
       all object DDL so OIDs, ownership, ACLs, comments and arbitrary external
       dependencies survive unchanged. */
    IF stats_order = canonical_order THEN
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_type AS t
          JOIN pg_catalog.pg_class AS c ON c.oid = stats_relation_oid
          JOIN pg_catalog.pg_type AS a ON a.oid = stats_array_oid
          JOIN pg_catalog.pg_class AS v ON v.oid = delivery_oid
          JOIN pg_catalog.pg_type AS vt ON vt.oid = delivery_type_oid
          JOIN pg_catalog.pg_type AS va ON va.oid = delivery_array_oid
         WHERE t.oid = stats_oid
           AND (t.typowner <> extension_owner
             OR c.relowner <> extension_owner
             OR a.typowner <> extension_owner
             OR v.relowner <> extension_owner
             OR vt.typowner <> extension_owner
             OR va.typowner <> extension_owner
             OR a.typnamespace <> extension_schema_oid
             OR a.typname <> '_pg_logtap_stats_t'
             OR a.typelem <> stats_oid
             OR vt.typnamespace <> extension_schema_oid
             OR vt.typrelid <> delivery_oid
             OR va.typnamespace <> extension_schema_oid
             OR va.typname <> '_pg_logtap_delivery'
             OR va.typelem <> delivery_type_oid)
    ) THEN
        RAISE EXCEPTION
            'pg_logtap SQL objects have nonbaseline ownership or array metadata; restore extension-owner defaults and retry';
    END IF;

    SELECT string_agg(pg_catalog.format('%I', u.attribute_name), ', '
                      ORDER BY u.ordinality),
           string_agg(pg_catalog.format('jsonb_populate_record.%I', u.attribute_name), ', '
                      ORDER BY u.ordinality)
      INTO column_list, qualified_column_list
      FROM unnest(stats_order) WITH ORDINALITY AS u(attribute_name, ordinality);
    saved_search_path := current_setting('search_path');
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog', true);
    /* Normalize only whitespace outside quoted identifiers. PG15 qualifies
       projection columns; accept that spelling without rewriting schema names. */
    SELECT pg_catalog.btrim(pg_catalog.string_agg(
               CASE WHEN r.token[1] ~ '^[[:space:]]+$' THEN ' '
                    ELSE r.token[1] END,
               '' ORDER BY r.ordinality))
      INTO actual_view_definition
      FROM pg_catalog.regexp_matches(
               pg_catalog.pg_get_viewdef(delivery_oid, false),
               '"(?:[^"]|"")*"|[[:space:]]+|[^"[:space:]]+', 'g'
           ) WITH ORDINALITY AS r(token, ordinality);
    PERFORM pg_catalog.set_config('search_path', saved_search_path, true);
    expected_view_tail := pg_catalog.format(
        ' FROM jsonb_populate_record(NULL::%I.pg_logtap_stats_t, (%I.pg_logtap_stats_json())::jsonb) jsonb_populate_record(%s);',
        extension_schema, extension_schema, column_list);
    IF actual_view_definition NOT IN (
        'SELECT ' || column_list || expected_view_tail,
        'SELECT ' || qualified_column_list || expected_view_tail
    ) THEN
        RAISE EXCEPTION
            'pg_logtap_delivery has a custom definition; restore the released view and retry the update';
    END IF;

    IF (SELECT count(*) FROM pg_catalog.pg_rewrite AS r
         WHERE r.ev_class = delivery_oid) <> 1
       OR NOT EXISTS (
           SELECT 1
             FROM pg_catalog.pg_rewrite AS r
            WHERE r.ev_class = delivery_oid
              AND r.rulename = '_RETURN'
              AND r.ev_type = '1'
              AND r.is_instead
       )
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_trigger AS t
            WHERE t.tgrelid = delivery_oid
              AND NOT t.tgisinternal
       )
       OR NOT EXISTS (
           SELECT 1
             FROM pg_catalog.pg_rewrite AS r
             JOIN pg_catalog.pg_depend AS d
               ON d.classid = 'pg_catalog.pg_rewrite'::pg_catalog.regclass
              AND d.objid = r.oid
            WHERE r.ev_class = delivery_oid
              AND d.refclassid = 'pg_catalog.pg_type'::pg_catalog.regclass
              AND d.refobjid = stats_oid
       )
       OR NOT EXISTS (
           SELECT 1
             FROM pg_catalog.pg_rewrite AS r
             JOIN pg_catalog.pg_depend AS d
               ON d.classid = 'pg_catalog.pg_rewrite'::pg_catalog.regclass
              AND d.objid = r.oid
            WHERE r.ev_class = delivery_oid
              AND d.refclassid = 'pg_catalog.pg_proc'::pg_catalog.regclass
              AND d.refobjid = stats_json_oid
       ) THEN
        RAISE EXCEPTION
            'pg_logtap_delivery is not the released jsonb_populate_record view';
    END IF;

    SELECT count(*)
      INTO metadata_count
      FROM pg_catalog.pg_attribute AS a
     WHERE a.attrelid IN (stats_relation_oid, delivery_oid)
       AND a.attnum > 0
       AND (a.attacl IS NOT NULL
         OR a.atthasdef
         OR a.attstattarget <> -1
         OR a.attoptions IS NOT NULL
         OR a.attfdwoptions IS NOT NULL);
    IF metadata_count <> 0 THEN
        RAISE EXCEPTION
            'pg_logtap columns have custom ACLs, defaults or options; remove them and retry the update';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_class AS c
         WHERE c.oid IN (stats_relation_oid, delivery_oid)
           AND (c.reloptions IS NOT NULL
             OR c.relrowsecurity
             OR c.relforcerowsecurity)
    ) THEN
        RAISE EXCEPTION
            'pg_logtap SQL objects have custom relation options; remove them and retry the update';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_description AS d
         WHERE (d.classoid = 'pg_catalog.pg_type'::pg_catalog.regclass
                AND d.objoid IN (stats_oid, stats_array_oid, delivery_type_oid, delivery_array_oid))
            OR (d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
                AND d.objoid IN (stats_relation_oid, delivery_oid))
    ) OR EXISTS (
        SELECT 1
          FROM pg_catalog.pg_seclabel AS s
         WHERE (s.classoid = 'pg_catalog.pg_type'::pg_catalog.regclass
                AND s.objoid IN (stats_oid, stats_array_oid, delivery_type_oid, delivery_array_oid))
            OR (s.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
                AND s.objoid IN (stats_relation_oid, delivery_oid))
    ) THEN
        RAISE EXCEPTION
            'pg_logtap SQL objects have comments or security labels; remove them and retry the update';
    END IF;

    WITH actual AS (
        SELECT t.oid, x.grantor, x.grantee, x.privilege_type, x.is_grantable
          FROM pg_catalog.pg_type AS t
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(t.typacl, pg_catalog.acldefault('T', t.typowner))) AS x
         WHERE t.oid IN (stats_oid, delivery_type_oid)
    ), expected AS (
        SELECT t.oid, x.grantor, x.grantee, x.privilege_type, x.is_grantable
          FROM pg_catalog.pg_type AS t
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              pg_catalog.acldefault('T', extension_owner)) AS x
         WHERE t.oid IN (stats_oid, delivery_type_oid)
    )
    SELECT NOT EXISTS (
        (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        UNION ALL
        (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    ) INTO acl_matches;
    IF NOT acl_matches THEN
        RAISE EXCEPTION
            'pg_logtap composite types have nonbaseline privileges; restore baseline grants and retry the update';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_type AS t
         WHERE t.oid IN (stats_array_oid, delivery_array_oid)
           AND t.typacl IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'pg_logtap array types have custom privileges; restore defaults and retry the update';
    END IF;

    WITH actual AS (
        SELECT x.grantor, x.grantee, x.privilege_type, x.is_grantable
          FROM pg_catalog.pg_class AS c
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) AS x
         WHERE c.oid = delivery_oid
    ), expected AS (
        SELECT x.grantor, x.grantee, x.privilege_type, x.is_grantable
          FROM pg_catalog.aclexplode(
              pg_catalog.acldefault('r', extension_owner)) AS x
        UNION ALL
        SELECT extension_owner, monitor_oid, 'SELECT'::text, false
    )
    SELECT NOT EXISTS (
        (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        UNION ALL
        (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    ) INTO acl_matches;
    IF NOT acl_matches THEN
        RAISE EXCEPTION
            'pg_logtap_delivery has nonbaseline privileges; revoke custom grants and retry the update';
    END IF;

    /* Recreating under changed ALTER DEFAULT PRIVILEGES would silently add
       grants that were absent from the released objects. Refuse that state
       rather than trying to reinterpret role-specific defaults. */
    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_default_acl AS d
         WHERE d.defaclrole IN (extension_owner, invoking_role)
           AND d.defaclobjtype IN ('r', 'T')
           AND d.defaclnamespace IN (0, extension_schema_oid)
    ) THEN
        RAISE EXCEPTION
            'custom default privileges affect recreated pg_logtap objects; reset them for this schema and retry the update';
    END IF;

    /* RESTRICT makes unsupported external dependencies fail the whole ALTER
       EXTENSION transaction. PostgreSQL restores the old view, type, order and
       extversion on error. */
    EXECUTE pg_catalog.format(
        'DROP VIEW %I.pg_logtap_delivery RESTRICT', extension_schema);
    EXECUTE pg_catalog.format(
        'DROP TYPE %I.pg_logtap_stats_t RESTRICT', extension_schema);

    EXECUTE pg_catalog.format($ddl$
        CREATE TYPE %I.pg_logtap_stats_t AS (
            events_captured bigint,
            events_dropped bigint,
            events_sent bigint,
            events_queued bigint,
            events_replayed bigint,
            events_compacted bigint,
            queue_backlog bigint,
            delivered bigint,
            events_lost bigint,
            send_cycles_failed bigint,
            ring_events integer,
            ring_capacity integer,
            dns_fail_streak bigint,
            fallback_broken bigint,
            fb_sync_failures bigint,
            redact_pattern_failed bigint,
            warn_tls_no_verify bigint,
            warn_fallback_open bigint,
            warn_fallback_skipped bigint,
            warn_fallback_unbounded bigint
        )$ddl$, extension_schema);
    EXECUTE pg_catalog.format(
        'ALTER TYPE %I.pg_logtap_stats_t OWNER TO %I',
        extension_schema, pg_catalog.pg_get_userbyid(extension_owner));

    EXECUTE pg_catalog.format($ddl$
        CREATE VIEW %I.pg_logtap_delivery AS
        SELECT * FROM pg_catalog.jsonb_populate_record(
            NULL::%I.pg_logtap_stats_t,
            %I.pg_logtap_stats_json()::pg_catalog.jsonb
        )$ddl$, extension_schema, extension_schema, extension_schema);
    EXECUTE pg_catalog.format(
        'ALTER VIEW %I.pg_logtap_delivery OWNER TO %I',
        extension_schema, pg_catalog.pg_get_userbyid(extension_owner));
    EXECUTE pg_catalog.format(
        'GRANT SELECT ON %I.pg_logtap_delivery TO pg_monitor',
        extension_schema);
END
$migration$;
