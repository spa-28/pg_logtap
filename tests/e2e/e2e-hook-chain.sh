#!/bin/sh
# PostgreSQL hook interop: pg_logtap must chain to previously-installed
# emit_log, shmem-request and shmem-startup hooks, not silently replace them.
# hookchain.c is preloaded BEFORE pg_logtap.
# Usage: tests/e2e/e2e-hook-chain.sh [pg_container]   (restarts it twice)
set -eu
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tests/e2e/e2e-common.sh
. "$(dirname "$0")/e2e-common.sh"
e2e_init hookchain "${1:-}"
e2e_gate
OUT=${E2E_OUT:-/tmp/logtap-e2e}/hookchain # per container in a parallel matrix

psql_ct() { docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 "$@"; }

# Build hookchain.so against the target major's server headers (the fmgr
# magic block is version-checked at load, so a pg18 .so won't load into 15).
MAJ=$(psql_ct -Atc "SHOW server_version" | cut -d. -f1)
LIBDIR=$(docker exec "$PG_CT" pg_config --pkglibdir)
mkdir -p "$OUT"
e2e_stand_lock || fail "could not acquire build lock"
if HOST_CONFIG=$(e2e_pg_config "$MAJ"); then
  # -Wno-ignored-attributes: PG headers mark printf functions gnu_printf,
  # which zig cc's clang does not accept — header noise, not our code.
  INC=$("$HOST_CONFIG" --includedir-server) || fail "could not read PostgreSQL $MAJ headers"
  zig cc -shared -fPIC -Wno-ignored-attributes -I"$INC" \
    tests/e2e/hookchain.c -o "$OUT/hookchain.so" \
    || fail "could not build hookchain.so for PostgreSQL $MAJ"
else # local: the pgzx-build container has server-dev 15-18
  INC=$(docker exec pgzx-build "/usr/lib/postgresql/$MAJ/bin/pg_config" --includedir-server)
  docker cp tests/e2e/hookchain.c "pgzx-build:/tmp/hookchain-$PG_CT.c"
  docker exec pgzx-build /opt/zig016/files/zig cc -shared -fPIC -Wno-ignored-attributes -I"$INC" \
    /tmp/hookchain-"$PG_CT".c -o /tmp/hookchain-"$PG_CT".so \
    || fail "could not build hookchain.so for PostgreSQL $MAJ"
  docker cp "pgzx-build:/tmp/hookchain-$PG_CT.so" "$OUT/hookchain.so" \
    || fail "docker cp of built hookchain.so for PostgreSQL $MAJ failed"
fi
exec 7>&- # builder is shared; the container lock stays held through restore
docker cp "$OUT/hookchain.so" "$PG_CT:$LIBDIR/"

# Preload hookchain first; the original setting goes back afterwards. List
# GUCs via ALTER SYSTEM need one quoted element per library — a single
# 'a,b' literal is stored as ONE element and the postmaster then fails to
# load a file literally named "a,b" (FATAL at boot, crash loop).
SAVED=$(psql_ct -Atc "SHOW shared_preload_libraries")
URL_SAVED=$(psql_ct -Atc "SHOW pg_logtap.export_url")
SAVED_LIST=$(echo "$SAVED" | sed "s/[,[:space:]]\+/', '/g") # '' | 'a' | 'a', 'b'
restore() {
  status=$?
  cleanup_failed=0
  preload_restored=1
  trap - EXIT HUP INT TERM
  if [ -n "$SAVED" ]; then
    psql_ct -qc "ALTER SYSTEM SET shared_preload_libraries = '$SAVED_LIST'" >/dev/null || {
      cleanup_failed=1; preload_restored=0
    }
  else
    psql_ct -qc "ALTER SYSTEM RESET shared_preload_libraries" >/dev/null || {
      cleanup_failed=1; preload_restored=0
    }
  fi
  setguc pg_logtap.export_url "$URL_SAVED" || cleanup_failed=1
  docker restart "$PG_CT" >/dev/null || cleanup_failed=1
  if [ "$preload_restored" -eq 1 ]; then
    docker exec "$PG_CT" sh -c "rm -f '$LIBDIR/hookchain.so'" >/dev/null 2>&1 || cleanup_failed=1
  fi
  (wait_ready) || cleanup_failed=1
  [ "$status" -ne 0 ] || [ "$cleanup_failed" -eq 0 ] || status=1
  exit "$status"
}
trap restore EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

psql_ct -qc "ALTER SYSTEM SET shared_preload_libraries = 'hookchain', 'pg_logtap'" >/dev/null
docker restart "$PG_CT" >/dev/null; wait_ready

# SQL-visible probes: one process-local emit-hook counter and one inherited
# pointer/magic check proving both shmem hooks ran before backend fork.
psql_ct \
  -qc "CREATE OR REPLACE FUNCTION public.hookchain_count() RETURNS integer
    AS '\$libdir/hookchain', 'hookchain_count' LANGUAGE C STRICT" \
  -qc "CREATE OR REPLACE FUNCTION public.hookchain_shmem_ready() RETURNS boolean
    AS '\$libdir/hookchain', 'hookchain_shmem_ready' LANGUAGE C STRICT" >/dev/null
SHMEM_READY=$(psql_ct -Atc "SELECT hookchain_shmem_ready()")
[ "$SHMEM_READY" = t ] || fail "previous shmem hooks were not both chained"
ok "previous shmem request/startup hooks initialized their shared state"

# Mute the exporter for the check below: a live export_url drains the ring
# between the DO and the dump, and the marker events would never be IN it.
psql_ct -qc "ALTER SYSTEM SET pg_logtap.export_url = ''" -qc "SELECT pg_reload_conf()" >/dev/null

# One connection: baseline count, 5 marker warnings, after-count, and the
# cluster-wide capture counter after them all (deltas vs baseline below).
R=$(psql_ct -qAt \
  -c "SELECT hookchain_count()" \
  -c "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]" \
  -c "DO \$\$ DECLARE i int := 0; BEGIN WHILE i < 5 LOOP
        RAISE WARNING 'logtap hook %', i; i := i + 1; END LOOP; END \$\$" \
  -c "SELECT hookchain_count()" \
  -c "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]")
C1=$(echo "$R" | sed -n 1p)
CAP1=$(echo "$R" | sed -n 2p)
C2=$(echo "$R" | sed -n 3p)
CAP2=$(echo "$R" | sed -n 4p)

# The marker events themselves must be IN the ring (dump is non-destructive).
INRING=$(psql_ct -Atc "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line)
  WHERE line LIKE '%\"message\":\"logtap hook %'")

[ "$((C2 - C1))" -ge 5 ] || fail "hookchain saw $((C2 - C1)) of 5 events — pg_logtap did not forward to the previous hook"
[ "$((CAP2 - CAP1))" -ge 5 ] || fail "events_captured moved by $((CAP2 - CAP1)) < 5 — chaining broke capture"
[ "$INRING" -ge 5 ] || fail "only $INRING marker events in the ring"
ok "chained hook fired for all events ($((C2 - C1)) calls), capture intact ($INRING in ring)"

# Hostile mode: a chained hook that LOGS from inside the hook (audit-extension
# style). Forwarding to prev_hook with the re-entrancy guard down recurses
# hook → elog → hook until the backend's stack dies; with the guard up the
# nested line is exempt from hook processing (still server-logged, not
# captured, not re-forwarded).
psql_ct -qc "CREATE OR REPLACE FUNCTION public.hookchain_arm(boolean) RETURNS integer
  AS '\$libdir/hookchain', 'hookchain_arm' LANGUAGE C STRICT" >/dev/null
# Rows: count, arm(true)'s count, [DO logs but prints no row], count, arm(false)
nested_log_count() {
  if n=$(grep -Fc 'hookchain nested call'); then :; else
    status=$?
    [ "$status" = 1 ] || return "$status" # 1 means a valid zero-match count
  fi
  printf '%s\n' "$n"
}
SERVER_LOG0=$(docker logs "$PG_CT" 2>&1) || fail "could not read server log before hostile hook"
NESTED_LOG0=$(printf '%s\n' "$SERVER_LOG0" | nested_log_count) || fail "could not count server log before hostile hook"
R=$(psql_ct -qAt \
  -c "SELECT hookchain_count()" \
  -c "SELECT hookchain_arm(true)" \
  -c "DO \$\$ BEGIN RAISE WARNING 'logtap hookchain-armed'; END \$\$" \
  -c "SELECT hookchain_count()" \
  -c "SELECT hookchain_arm(false)") \
  || fail "backend died in the logging chained hook — unbounded recursion"
A1=$(echo "$R" | sed -n 1p)
A2=$(echo "$R" | sed -n 3p)
DELTA=$((A2 - A1))
[ "$DELTA" -ge 1 ] && [ "$DELTA" -lt 5 ] || fail "logging chained hook out of bounds: $DELTA hook calls for one event"
SERVER_LOG1=$(docker logs "$PG_CT" 2>&1) || fail "could not read server log after hostile hook"
NESTED_LOG1=$(printf '%s\n' "$SERVER_LOG1" | nested_log_count) || fail "could not count server log after hostile hook"
NESTED_LOG_DELTA=$((NESTED_LOG1 - NESTED_LOG0))
[ "$NESTED_LOG_DELTA" -ge 1 ] && [ "$NESTED_LOG_DELTA" -lt 5 ] \
  || fail "nested WARNING missing or unbounded in server log: $NESTED_LOG_DELTA lines"
ARMED_INRING=$(psql_ct -Atc "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line)
  WHERE line LIKE '%\"message\":\"logtap hookchain-armed%'")
NESTED_INRING=$(psql_ct -Atc "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line)
  WHERE line LIKE '%hookchain nested%'")
[ "$ARMED_INRING" = 1 ] || fail "marker not captured under the logging hook ($ARMED_INRING in ring)"
[ "$NESTED_INRING" = 0 ] || fail "nested hook line captured — guard does not cover the chain call"
ok "logging chained hook bounded ($((A2 - A1)) calls, $NESTED_LOG_DELTA nested WARNING in server log, marker captured, nested line not)"
