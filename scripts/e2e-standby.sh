#!/bin/sh
# Worker lifecycle acceptance: no dependency on a database named `postgres`,
# and export while a physical standby remains in recovery. Owns a throwaway
# primary, standby and standby volume; the matrix stand supplies Vector only.
# Usage: scripts/e2e-standby.sh <pg_major>   (needs dist/pg<major> from `stand`)
set -u

V=${1:-}
[ -n "$V" ] || { echo "usage: $0 <pg_major>" >&2; exit 2; }
PRIMARY=pglogtap-standby-primary-$V
STANDBY=pglogtap-standby-replica-$V
VOLUME=pglogtap-standby-data-$V
SO=dist/pg$V/lib/pg_logtap.so
OUT=${E2E_OUT:-/tmp/logtap-e2e}
VEC=${E2E_VECTOR:-pglogtap-vector}
NET=pglogtap-e2e_default
SINK=$OUT/vector-out.jsonl
DB=logtap
SUF=$V-$$
PRIMARY_MARKER="logtap standby primary $SUF"
STANDBY_MARKER="logtap standby replica $SUF"

[ -f "$SO" ] || {
  echo "e2e-standby: $SO missing — run the stand phase first" >&2
  exit 2
}
mkdir -p "$OUT"
exec 9>"${E2E_LOCK_DIR:-$OUT}/lock.standby-$V"
flock -n 9 || {
  echo "e2e-standby: another pg$V standby scenario is running" >&2
  exit 1
}

dump_state() {
  CT=$1
  echo "-- $CT --" >&2
  docker inspect -f 'state={{.State.Status}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}' "$CT" >&2 2>/dev/null || true
  docker exec "$CT" psql -U postgres -d "$DB" -Atc \
    "SELECT 'recovery=' || pg_is_in_recovery()" >&2 2>/dev/null || true
  docker exec "$CT" psql -U postgres -d "$DB" -Atc \
    "SELECT pid || ' datname=' || coalesce(datname, '<null>') || ' type=' || backend_type
       FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'" >&2 2>/dev/null || true
  docker exec "$CT" psql -U postgres -d "$DB" -Atc \
    "SELECT pg_logtap_stats()" >&2 2>/dev/null || true
  docker logs "$CT" 2>&1 | grep -iE 'logtap|recovery|standby|FATAL|PANIC' | tail -20 >&2 || true
}

fail() {
  echo "e2e-standby: FAILED: $*" >&2
  dump_state "$PRIMARY"
  dump_state "$STANDBY"
  docker logs --tail 20 "$VEC" >&2 2>/dev/null || true
  [ -f "$SINK" ] && grep -F "$SUF" "$SINK" | tail -10 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f -v "$STANDBY" "$PRIMARY" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

db() { # <container> <psql args...>
  CT=$1
  shift
  docker exec "$CT" psql -U postgres -d "$DB" "$@"
}

wait_ready() {
  CT=$1
  N=0
  while [ "$N" -lt 60 ]; do
    docker exec "$CT" pg_isready -U postgres -d "$DB" -h 127.0.0.1 >/dev/null 2>&1 && return 0
    N=$((N + 1))
    sleep 1
  done
  fail "postgres in $CT not ready after 60s"
}

wait_vector() {
  CT=$1
  N=0
  while [ "$N" -lt 60 ]; do
    docker exec "$CT" bash -c "exec 3<>/dev/tcp/$VEC/8686" >/dev/null 2>&1 && return 0
    N=$((N + 1))
    sleep 1
  done
  fail "receiver $VEC not accepting connections after 60s"
}

worker_count() {
  db "$1" -Atc "SELECT count(*) FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'"
}

worker_pid() {
  db "$1" -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type LIKE '%logtap%' LIMIT 1"
}

wait_worker() {
  CT=$1
  N=0
  while [ "$N" -lt 30 ]; do
    [ "$(worker_count "$CT" 2>/dev/null || echo 0)" = 1 ] && return 0
    N=$((N + 1))
    sleep 1
  done
  fail "$CT has $(worker_count "$CT" 2>/dev/null || echo 0) pg_logtap workers, expected 1"
}

assert_worker() {
  CT=$1
  wait_worker "$CT"
  BOUND=$(db "$CT" -Atc \
    "SELECT count(*) FROM pg_stat_activity
       WHERE backend_type LIKE '%logtap%' AND datname IS NOT NULL")
  [ "$BOUND" = 0 ] || fail "$CT worker is bound to a database"
  PID1=$(worker_pid "$CT")
  sleep 3 # bgw_restart_time is 1 s: cross more than two restart intervals
  [ "$(worker_count "$CT")" = 1 ] || fail "$CT worker count changed during stability window"
  PID2=$(worker_pid "$CT")
  [ -n "$PID1" ] && [ "$PID1" = "$PID2" ] \
    || fail "$CT worker restarted during stability window ($PID1 -> $PID2)"
}

events_sent() {
  STATS=$(db "$1" -Atc "SELECT pg_logtap_stats()")
  VALUE=${STATS#*events_sent=}
  echo "${VALUE%% *}"
}

wait_marker() {
  MARKER=$1
  N=0
  while [ "$N" -lt 30 ]; do
    [ -f "$SINK" ] && grep -Fq "$MARKER" "$SINK" && return 0
    N=$((N + 1))
    sleep 1
  done
  fail "marker '$MARKER' did not reach Vector after 30s"
}

assert_names() {
  MARKER=$1
  python3 - "$SINK" "$MARKER" <<'PY' || fail "marker '$MARKER' lost database/user enrichment"
import json
import sys

path, marker = sys.argv[1:]
found = []
with open(path, encoding="utf-8") as stream:
    for line in stream:
        if marker in line:
            found.append(json.loads(line))
if not found:
    raise SystemExit("marker not found")
if not any(event.get("database") == "logtap" and event.get("user") == "postgres" for event in found):
    raise SystemExit(
        "resolved names missing: "
        + repr([(event.get("database"), event.get("user")) for event in found])
    )
PY
}

assert_delivery() {
  CT=$1
  MARKER=$2
  BEFORE=$(events_sent "$CT")
  db "$CT" -qc "SELECT '$MARKER'" >/dev/null || fail "marker query failed in $CT"
  wait_marker "$MARKER"
  AFTER=$(events_sent "$CT")
  [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null \
    || fail "$CT events_sent did not grow ($BEFORE -> $AFTER)"
  assert_names "$MARKER"
}

echo "== primary without a database named postgres =="
docker network inspect "$NET" >/dev/null 2>&1 \
  || fail "network $NET missing — run the stand phase first"
docker start "$VEC" >/dev/null 2>&1 || true
docker run -d --name "$PRIMARY" --hostname "$PRIMARY" \
  -e POSTGRES_PASSWORD=dev -e POSTGRES_DB="$DB" \
  --network "$NET" postgres:"$V" >/dev/null \
  || fail "could not start postgres:$V primary"
wait_ready "$PRIMARY"
wait_vector "$PRIMARY"

db "$PRIMARY" -v ON_ERROR_STOP=1 -qc "DROP DATABASE postgres WITH (FORCE)" >/dev/null \
  || fail "could not remove database postgres"
[ "$(db "$PRIMARY" -Atc "SELECT count(*) FROM pg_database WHERE datname = 'postgres'")" = 0 ] \
  || fail "database postgres still exists"

LIBDIR=$(docker exec "$PRIMARY" pg_config --pkglibdir)
EXTDIR=$(docker exec "$PRIMARY" pg_config --sharedir)/extension
docker cp "$SO" "$PRIMARY:$LIBDIR/" >/dev/null
docker cp pg_logtap.control "$PRIMARY:$EXTDIR/" >/dev/null
for SQL in sql/*.sql; do docker cp "$SQL" "$PRIMARY:$EXTDIR/" >/dev/null; done

db "$PRIMARY" -v ON_ERROR_STOP=1 \
  -qc "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'" \
  -qc "ALTER SYSTEM SET log_min_duration_statement = 0" >/dev/null \
  || fail "could not configure primary preload"
docker restart "$PRIMARY" >/dev/null || fail "primary restart failed"
wait_ready "$PRIMARY"

db "$PRIMARY" -v ON_ERROR_STOP=1 \
  -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$VEC:8686'" \
  -qc "ALTER SYSTEM SET pg_logtap.flush_interval = 100" \
  -qc "SELECT pg_reload_conf()" \
  -qc "CREATE EXTENSION pg_logtap" >/dev/null \
  || fail "could not configure pg_logtap in $DB"
assert_worker "$PRIMARY"
assert_delivery "$PRIMARY" "$PRIMARY_MARKER"
echo "  ok: unbound worker is stable and exports resolved names without database postgres"

echo "== permanent hot standby remains in recovery while exporting =="
PGDATA=$(db "$PRIMARY" -Atc "SHOW data_directory")
docker exec "$PRIMARY" sh -c \
  "printf '%s\n' 'host replication postgres all trust' >> '$PGDATA/pg_hba.conf'" \
  || fail "could not enable physical replication"
db "$PRIMARY" -qc "SELECT pg_reload_conf()" >/dev/null \
  || fail "primary pg_hba reload failed"

docker volume create "$VOLUME" >/dev/null \
  || fail "could not create standby volume"
docker run --rm -v "$VOLUME:$PGDATA" postgres:"$V" \
  chown postgres:postgres "$PGDATA" \
  || fail "could not prepare standby volume"
docker run --rm --network "$NET" --user postgres \
  -v "$VOLUME:$PGDATA" postgres:"$V" \
  pg_basebackup -h "$PRIMARY" -U postgres -D "$PGDATA" -R -X stream -c fast >/dev/null \
  || fail "pg_basebackup failed"

HOST_SO=$(readlink -f "$SO")
docker run -d --name "$STANDBY" --hostname "$STANDBY" \
  --network "$NET" -v "$VOLUME:$PGDATA" \
  -v "$HOST_SO:$LIBDIR/pg_logtap.so:ro" postgres:"$V" >/dev/null \
  || fail "could not start postgres:$V standby"
wait_ready "$STANDBY"
wait_vector "$STANDBY"
[ "$(db "$STANDBY" -Atc "SELECT pg_is_in_recovery()")" = t ] \
  || fail "standby was not in recovery before the worker check"
assert_worker "$STANDBY"
assert_delivery "$STANDBY" "$STANDBY_MARKER"
[ "$(db "$STANDBY" -Atc "SELECT pg_is_in_recovery()")" = t ] \
  || fail "standby left recovery during the export check"
echo "  ok: worker starts at consistent state and exports while recovery stays active"

echo "e2e-standby: all scenarios passed"
