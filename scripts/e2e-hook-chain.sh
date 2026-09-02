#!/bin/sh
# emit_log_hook interop: pg_logtap must chain to a previously-installed hook,
# not silently replace it (PROBLEMS.md B1). hookchain.c (companion extension)
# is preloaded BEFORE pg_logtap, which makes it pg_logtap's prev_hook — every
# event must reach it first AND still be captured by pg_logtap.
# Usage: scripts/e2e-hook-chain.sh [pg_container]   (restarts it twice)
set -eu
PG_CT="${1:-pglogtap-pg}"
OUT=/tmp/logtap-hookchain

fail() { echo "e2e-hook-chain: FAILED: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
psql_ct() { docker exec "$PG_CT" psql -U postgres "$@"; }

# A stale .so (copied without a restart) would test yesterday's code.
"$(dirname "$0")/e2e-require-ext.sh" "$PG_CT"

wait_ready() {
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$PG_CT" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && return 0
    n=$((n + 1)); sleep 1
  done
  fail "postgres in $PG_CT not ready after 60s"
}

# Build hookchain.so against the target major's server headers (the fmgr
# magic block is version-checked at load, so a pg18 .so won't load into 15).
MAJ=$(psql_ct -Atc "SHOW server_version" | cut -d. -f1)
LIBDIR=$(docker exec "$PG_CT" pg_config --pkglibdir)
mkdir -p "$OUT"
if command -v pg_config >/dev/null 2>&1; then # CI: server-dev for this major
  # -Wno-ignored-attributes: PG headers mark printf functions gnu_printf,
  # which zig cc's clang does not accept — header noise, not our code.
  zig cc -shared -fPIC -Wno-ignored-attributes -I"$(pg_config --includedir-server)" \
    tests/e2e/hookchain.c -o "$OUT/hookchain.so"
else # local: the pgzx-build container has server-dev 15-18
  INC=$(docker exec pgzx-build "/usr/lib/postgresql/$MAJ/bin/pg_config" --includedir-server)
  docker cp tests/e2e/hookchain.c pgzx-build:/tmp/hookchain.c
  docker exec pgzx-build /opt/zig016/files/zig cc -shared -fPIC -Wno-ignored-attributes -I"$INC" \
    /tmp/hookchain.c -o /tmp/hookchain.so
  docker cp pgzx-build:/tmp/hookchain.so "$OUT/hookchain.so"
fi
docker cp "$OUT/hookchain.so" "$PG_CT:$LIBDIR/"

# Preload hookchain first; the original setting goes back afterwards. List
# GUCs via ALTER SYSTEM need one quoted element per library — a single
# 'a,b' literal is stored as ONE element and the postmaster then fails to
# load a file literally named "a,b" (FATAL at boot, crash loop).
SAVED=$(psql_ct -Atc "SHOW shared_preload_libraries")
SAVED_LIST=$(echo "$SAVED" | sed "s/[,[:space:]]\+/', '/g") # '' | 'a' | 'a', 'b'
restore() {
  psql_ct -qc "ALTER SYSTEM SET shared_preload_libraries = '$SAVED_LIST'" \
    -qc "ALTER SYSTEM SET pg_logtap.export_url = '$URL_SAVED'" >/dev/null
  docker restart "$PG_CT" >/dev/null
  docker exec "$PG_CT" sh -c "rm -f '$LIBDIR/hookchain.so'" >/dev/null 2>&1 || true
  wait_ready
}
trap restore EXIT INT TERM

psql_ct -qc "ALTER SYSTEM SET shared_preload_libraries = 'hookchain', 'pg_logtap'" >/dev/null
docker restart "$PG_CT" >/dev/null; wait_ready

# SQL-visible counter; reads the session's process-local hook_calls.
psql_ct -qc "CREATE OR REPLACE FUNCTION public.hookchain_count() RETURNS integer
  AS '\$libdir/hookchain', 'hookchain_count' LANGUAGE C STRICT" >/dev/null

# Mute the exporter for the check below: a live export_url drains the ring
# between the DO and the dump, and the marker events would never be IN it.
URL_SAVED=$(psql_ct -Atc "SHOW pg_logtap.export_url")
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
ARMED_INRING=$(psql_ct -Atc "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line)
  WHERE line LIKE '%\"message\":\"logtap hookchain-armed%'")
NESTED_INRING=$(psql_ct -Atc "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line)
  WHERE line LIKE '%hookchain nested%'")
[ "$ARMED_INRING" = 1 ] || fail "marker not captured under the logging hook ($ARMED_INRING in ring)"
[ "$NESTED_INRING" = 0 ] || fail "nested hook line captured — guard does not cover the chain call"
ok "logging chained hook bounded ($((A2 - A1)) call, marker captured, nested line not)"
