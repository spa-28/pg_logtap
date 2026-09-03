#!/bin/sh
# Fault-injection acceptance: the sync/write paths cannot be driven to
# failure from SQL, so this suite runs a THROWAWAY postgres under an
# LD_PRELOAD shim (tests/e2e/fsyncfail.c) that fails fdatasync with EIO for
# one named file, N times, and leaves every other fd (WAL included) alone.
# The stand is not touched: the shim needs container env set at create time,
# so this brings up its own pglogtap-faults container and removes it at exit.
#   sink-sync-fail    : file:// sink fdatasync fails -> batch rolled back,
#                       retried whole, exactly one copy of every event
#   fallback-sync-fail: queue fdatasync fails -> member stays (not durable),
#                       no duplicate member, fb_sync_failures counts it, replay
#                       delivers every event once
#   dev-full          : file:///dev/full write fails mid-batch -> torn line
#                       rolled back, events held in the RAM backlog, delivered
#                       whole on the next receiver
# Usage: scripts/e2e-faults.sh <pg_major>   (needs dist/pg<major> from `stand`)
set -eu
V=$1
[ -n "$V" ] || { echo "usage: $0 <pg_major>" >&2; exit 2; }
CT=pglogtap-faults
OUT=/tmp/logtap-faults
SO=dist/pg$V/lib/pg_logtap.so
[ -f "$SO" ] || { echo "e2e-faults: $SO missing — run the stand phase first" >&2; exit 2; }

fail() {
  echo "e2e-faults: FAILED: $*" >&2
  docker exec "$CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" >&2 || true
  echo "shim target: $(docker exec "$CT" cat /tmp/fsyncfail-target 2>/dev/null || echo '<unset>')" >&2
  docker exec "$CT" sh -c 'sort /tmp/fsyncfail.log 2>/dev/null | uniq -c' >&2 || true
  docker exec "$CT" sh -c "ls -la '$PGDATA_C/$FB_REL' 2>/dev/null" >&2 || true
  docker logs "$CT" 2>&1 | grep -iE "logtap.*(fdatasync|fallback|divert|failing)" | tail -5 >&2 || true
  exit 1
}
ok() { echo "  ok: $*"; }

mkdir -p "$OUT"
cc -shared -fPIC -Wall -Wextra tests/e2e/fsyncfail.c -o "$OUT/fsyncfail.so" -ldl

FB_REL=pgfaults-queue.bin # PGDATA-relative, like a real deployment
docker rm -f -v "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" -e POSTGRES_PASSWORD=dev \
  -v "$OUT/fsyncfail.so:/tmp/fsyncfail.so:ro" \
  -e LD_PRELOAD=/tmp/fsyncfail.so \
  -e FSYNCFAIL_COUNT=2 \
  postgres:"$V" >/dev/null || fail "could not start postgres:$V"
cleanup() { docker rm -f -v "$CT" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

wait_ready() {
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$CT" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && return 0
    n=$((n + 1)); sleep 1
  done
  docker logs --tail 30 "$CT" >&2 || true
  fail "postgres in $CT not ready after 60s"
}
wait_ready

# The shim's watched path depends on PGDATA, which differs across majors
# (pg18 images use /var/lib/postgresql/18/docker, older ones .../data) and
# is only known once the server is up — so the harness tells the shim what
# to watch through a file it reads per call. Until the file exists the shim
# passes everything through, so the boot itself is never faulted.
PGDATA_C=$(docker exec "$CT" psql -U postgres -Atc "SHOW data_directory")
set_target() { docker exec "$CT" sh -c "printf '%s' '$1' > /tmp/fsyncfail-target"; }

# Deploy (the stand phase's recipe, minus the stand): library, control, SQL,
# preload, then the extension itself.
LIBDIR=$(docker exec "$CT" pg_config --pkglibdir)
EXTDIR=$(docker exec "$CT" pg_config --sharedir)/extension
docker cp "$SO" "$CT:$LIBDIR/"
docker cp pg_logtap.control "$CT:$EXTDIR/"
for f in sql/*.sql; do docker cp "$f" "$CT:$EXTDIR/"; done
# Core GUC first, restart, THEN the pg_logtap.* ones: PG<=16 rejects ALTER
# SYSTEM on unregistered custom GUCs, so the library must load first (same
# two-step the matrix's stand phase does).
docker exec "$CT" psql -U postgres -qc "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'" >/dev/null
docker restart "$CT" >/dev/null; wait_ready
docker exec "$CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.flush_interval = 100" \
  -qc "SELECT pg_reload_conf()" >/dev/null
docker exec "$CT" psql -U postgres -qc "CREATE EXTENSION pg_logtap" >/dev/null
"$(dirname "$0")/e2e-require-ext.sh" "$CT"

setguc() { docker exec "$CT" psql -U postgres -qc "ALTER SYSTEM SET $1 = '$2'" >/dev/null; }
reload() { docker exec "$CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null; }
stats() { docker exec "$CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"; }
statf() { s=$(stats); v=${s#*"$1"=}; echo "${v%% *}"; }
# Markers in a file:// sink: count distinct events and duplicate seqs there.
sink_lines() { docker exec "$CT" sh -c "grep -oE 'logtap fault $1 [0-9]+' /tmp/$2.log 2>/dev/null" | sort -u | wc -l; }
sink_dups() { docker exec "$CT" sh -c "grep 'logtap fault' /tmp/$1.log 2>/dev/null" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l; }
gen() { docker exec "$CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
  WHILE i < $2 LOOP
    RAISE WARNING 'logtap fault $1 %', i;
    i := i + 1;
  END LOOP; END \$\$" >/dev/null; }

echo "== file:// sink: fdatasync fails -> rollback + whole retry, one copy =="
SUF=f$$
docker exec "$CT" sh -c "rm -f /tmp/sink.log"
set_target /tmp/sink.log
setguc pg_logtap.export_url 'file:///tmp/sink.log'
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
gen "sink1-$SUF" 20; sleep 3 # cycles 1-2: EIO -> ftruncate -> retry; then clean
[ "$(sink_lines "sink1-$SUF" sink)" = 20 ] \
  || fail "sink sync-fail: $(sink_lines "sink1-$SUF" sink)/20 events in the sink — batch lost or not retried"
[ "$(sink_dups sink)" = 0 ] \
  || fail "sink sync-fail: duplicate seqs — failed-sync retry double-wrote the batch"
[ "$(statf events_lost)" = 0 ] || fail "sink sync-fail: lost>0"
ok "20/20 in the sink, 0 duplicate seqs (failed sync rolled back and retried whole)"

echo "== fallback queue: fdatasync fails -> member kept, not duplicated, counted =="
docker exec "$CT" sh -c "rm -f '$PGDATA_C/$FB_REL' /tmp/sink.log"
# Point the shim at the queue BEFORE the restart: the freshly booted worker
# still exports to scenario A's sink URL until the reload below, and its
# boot-noise fdatasyncs on the sink would spend the shim's whole per-process
# failure budget before the queue is ever synced. With the target already
# moved, those syncs simply do not match. The restart itself is what resets
# the budget: scenario A spent it in this same worker process.
set_target "$PGDATA_C/$FB_REL"
docker restart "$CT" >/dev/null; wait_ready
setguc pg_logtap.export_url 'http://127.0.0.1:1' # dead port: send fails fast
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
# Bursts across flush cycles: the first two syncs of the queue fail EIO
# (member stays, not durable), later ones go clean.
gen "fb1-$SUF" 20; sleep 1; gen "fb2-$SUF" 20; sleep 1; gen "fb3-$SUF" 20; sleep 3
syncfails=$(statf fb_sync_failures)
[ "$syncfails" -ge 1 ] 2>/dev/null || fail "fallback sync-fail: fb_sync_failures=$syncfails — gauge did not count the EIOs"
[ "$(statf events_lost)" = 0 ] || fail "fallback sync-fail: lost>0 with the queue on"
# A duplicate member (the pre-fix bug: sync fail re-appended the batch)
# would double-deliver at replay; queued past captured is its smoke signal.
q=$(statf events_queued)
setguc pg_logtap.export_url 'file:///tmp/replay.log'; reload
n=0; while [ "$n" -lt 15 ]; do
  [ "$(sink_lines "fb1-$SUF" replay)" -ge 20 ] && [ "$(sink_lines "fb2-$SUF" replay)" -ge 20 ] && [ "$(sink_lines "fb3-$SUF" replay)" -ge 20 ] && break
  n=$((n + 1)); sleep 1
done
R1=$(sink_lines "fb1-$SUF" replay); R2=$(sink_lines "fb2-$SUF" replay); R3=$(sink_lines "fb3-$SUF" replay)
[ "$R1" = 20 ] && [ "$R2" = 20 ] && [ "$R3" = 20 ] \
  || fail "fallback sync-fail: replay delivered $R1/$R2/$R3 of 20/20/20"
[ "$(sink_dups replay)" = 0 ] || fail "fallback sync-fail: duplicate seqs in replay — sync-failed member re-appended"
bl=$(docker exec "$CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$bl" = 0 ] || fail "fallback sync-fail: queue_backlog=$bl after replay"
ok "fb_sync_failures=$syncfails, 60/60 replayed once each, queue drained (queued was $q)"

echo "== /dev/full: write fails mid-batch -> torn line rolled back, held in RAM =="
docker exec "$CT" sh -c "rm -f /tmp/replay.log"
setguc pg_logtap.export_fallback_file '' # no queue: the RAM backlog is the only hold
setguc pg_logtap.export_url 'file:///dev/full'; reload; sleep 2
gen "full1-$SUF" 20; sleep 3 # ENOSPC on every write; backlog accumulates
[ "$(statf events_lost)" = 0 ] || fail "/dev/full: lost>0 without the queue"
[ "$(statf events_dropped)" = 0 ] || fail "/dev/full: ring dropped (ring too small?)"
setguc pg_logtap.export_url 'file:///tmp/full.log'; reload; sleep 2
n=0; while [ "$n" -lt 15 ]; do
  [ "$(sink_lines "full1-$SUF" full)" -ge 20 ] && break
  n=$((n + 1)); sleep 1
done
[ "$(sink_lines "full1-$SUF" full)" = 20 ] || fail "/dev/full: $(sink_lines "full1-$SUF" full)/20 delivered after the outage"
[ "$(sink_dups full)" = 0 ] || fail "/dev/full: duplicate seqs — torn line not rolled back before the retry"
ok "write-fail held 20 events in the RAM backlog, delivered 20/20 whole"

echo "e2e-faults: all scenarios passed"
