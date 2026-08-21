#!/bin/sh
# Failure-mode acceptance — the contract under test lives in docs/delivery.md:
#   A receiver down → up : backlog holds events, zero lost, zero duplicate seqs
#   B SIGKILL postmaster : in-RAM events gone (the documented loss), counters
#                          restart from zero, seq strictly above every pre-kill
#                          seq (wall-clock seeded → dedup-by-seq spans restarts)
#   C fallback file      : receiver dead + export_fallback_file set → zero
#                          lost, every event in the file
#   D worker kill -9     : postmaster emergency-restarts, delivery resumes
# Usage: scripts/e2e-kill.sh [pg_container]
set -eu
PG_CT="${1:-pglogtap-pg}"
NET=logtap-e2e
OUT=/tmp/logtap-kill
VEC=pglogtap-vector-kill

fail() { echo "e2e-kill: FAILED: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

docker network create "$NET" >/dev/null 2>&1 || true
docker network connect "$NET" "$PG_CT" 2>/dev/null || true
docker rm -f "$VEC" >/dev/null 2>&1 || true
rm -rf "$OUT" && mkdir -p "$OUT"
docker run -d --name "$VEC" --network "$NET" \
  -v "$(pwd)/tests/e2e/vector.yaml:/etc/vector/vector.yaml:ro" \
  -v "$OUT:/var/log" timberio/vector:0.57.0-alpine \
  --config /etc/vector/vector.yaml >/dev/null
sleep 3

setguc() { docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $1 = '$2'" >/dev/null; }
reload() { docker exec "$PG_CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null; }
gen() { # gen <marker> <count> — distinct events from one psql round trip.
  # WARNING: above the default log_min_messages (so it reaches the hook) and
  # not an error (so the loop is not aborted); a caught RAISE EXCEPTION never
  # reaches the server log at all.
  docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
    WHILE i < $2 LOOP
      RAISE WARNING 'logtap kill $1 %', i;
      i := i + 1;
    END LOOP; END \$\$" >/dev/null 2>&1
}
# Count distinct marker events; the trailing digit requirement keeps out the
# duration-log line of the generating DO statement itself (its message quotes
# the RAISE format string when log_min_duration_statement is on).
received() { grep -oE "logtap kill $1 [0-9]+" "$OUT/vector-out.jsonl" 2>/dev/null | sort -u | wc -l; }
seqs_of() { grep -E "logtap kill $1 [0-9]+" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | cut -d: -f2; }
# TCP probe only: the official image's temporary initdb server answers a plain
# pg_isready on the unix socket before the real server exists.
wait_ready() {
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$PG_CT" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && return 0
    n=$((n + 1)); sleep 1
  done
  fail "postgres in $PG_CT not ready after 60s"
}
stats() { docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"; }
statf() { s=$(stats); v=${s#*$1=}; echo "${v%% *}"; }
wait_for() { # wait_for <marker> <count>
  n=0
  while [ "$n" -lt 15 ]; do
    [ "$(received "$1")" -ge "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
}

echo "== A: receiver down → up =="
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.export_fallback_file ''; reload; sleep 2
gen a1 20; wait_for a1 20
gen a2 100 # more baseline traffic, all delivered while the receiver is up
wait_for a2 100
docker stop "$VEC" >/dev/null
gen a3 100; sleep 3 # failed cycles → events buffer in the worker backlog
docker start "$VEC" >/dev/null; sleep 3
gen a4 20
wait_for a3 100; wait_for a4 20
dups=$(grep -o '"seq":[0-9]*' "$OUT/vector-out.jsonl" | sort | uniq -d | wc -l)
[ "$(received a1)" = 20 ] && [ "$(received a3)" = 100 ] && [ "$(received a4)" = 20 ] \
  || fail "A: loss (a1=$(received a1) a3=$(received a3) a4=$(received a4))"
[ "$dups" = 0 ] || fail "A: $dups duplicate seqs — dedup-by-seq contract broken"
[ "$(statf lost)" = 0 ] && [ "$(statf dropped)" = 0 ] \
  || fail "A: counters lost=$(statf lost) dropped=$(statf dropped)"
ok "140/140 delivered, 0 duplicate seqs, lost=0 dropped=0"

echo "== B: SIGKILL postmaster with a backlog =="
setguc pg_logtap.export_url "http://127.0.0.1:1"; setguc pg_logtap.export_fallback_file ''
reload; sleep 2 # dead port: dial fails instantly, no fallback — pure RAM backlog
# Baseline after the reload: the live URL may still export during the switch.
base_cap=$(statf captured); base_exp=$(statf exported)
gen b1 300; sleep 3
[ $(( $(statf captured) - base_cap )) -ge 300 ] || fail "B: events not captured"
[ $(( $(statf exported) - base_exp )) = 0 ] || fail "B: exported moved with a dead receiver"
[ "$(statf lost)" = 0 ] || fail "B: backlog overflowed (ring too small for 300 events?)"
pre_seq=$(grep -o '"seq":[0-9]*' "$OUT/vector-out.jsonl" | cut -d: -f2 | sort -n | tail -1)
docker kill "$PG_CT" >/dev/null # SIGKILL: postmaster, worker, shmem — all gone
docker start "$PG_CT" >/dev/null; wait_ready
# Fresh shmem: only the postmaster's own boot noise is captured (<50 events),
# nothing delivered. Had the old segment survived, captured would be ≥300.
[ "$(statf captured)" -lt 50 ] && [ "$(statf exported)" = 0 ] && [ "$(statf lost)" = 0 ] \
  || fail "B: counters did not reset from zero after restart"
ok "counters fresh (captured=$(statf captured) boot noise); the 300 in-RAM events are the documented restart loss"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
gen b2 20; wait_for b2 20
new_min=$(seqs_of b2 | sort -n | head -1)
[ "$(received b2)" = 20 ] || fail "B: no delivery after restart"
[ "$new_min" -gt "$pre_seq" ] \
  || fail "B: seq regressed across restart (new min $new_min <= pre-kill max $pre_seq)"
ok "delivery resumed, min new seq $new_min > pre-kill max $pre_seq"

echo "== C: fallback file (compressed queue + replay) =="
FB_REL=pg_logtap-fallback.bin # relative: must resolve against PGDATA
FB_DIR=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW data_directory")
FB="$FB_DIR/$FB_REL"
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen c1 600; sleep 3 # >2 chunks: multiple framed members
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
docker exec "$PG_CT" head -c 8 "$FB" | grep -q PGLTFB01 || fail "C: no queue magic in $FB"
docker exec "$PG_CT" grep -q "logtap kill c1" "$FB" 2>/dev/null && fail "C: file is plain text, not compressed"
[ "$(statf lost)" = 0 ] || fail "C: lost>0 despite the fallback file"
ok "receiver dead → 600 events queued compressed ($fb_sz bytes), lost=0"
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
# The queue is on disk: a cluster restart must not lose it — replay after boot.
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for c1 600
[ "$(received c1)" = 600 ] || fail "C: replay delivered $(received c1)/600"
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$fb_sz" = 0 ] || fail "C: queue not truncated after replay ($fb_sz bytes left)"
c1_dups=$(seqs_of c1 | sort | uniq -d | wc -l)
[ "$c1_dups" = 0 ] || fail "C: $c1_dups duplicate seqs in replay"
[ "$(statf lost)" = 0 ] || fail "C: lost>0 during replay"
ok "restart + receiver back → 600/600 replayed, queue truncated, 0 duplicate seqs"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2

echo "== D: worker kill -9 =="
# debug1 makes the postmaster log during the emergency restart — its emit_log
# hook calls happen while shmem is unmapped, which used to SEGV the cluster.
setguc log_min_messages debug1; setguc pg_logtap.level_min 10; reload
wpid=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$wpid" ] || fail "D: worker not found in pg_stat_activity"
docker exec "$PG_CT" kill -9 "$wpid"
sleep 5; wait_ready; sleep 2 # postmaster emergency-restarts the cluster
setguc log_min_messages warning; setguc pg_logtap.level_min 15; reload
gen d1 20; wait_for d1 20
[ "$(received d1)" = 20 ] || fail "D: no delivery after worker crash"
ok "worker crash → cluster restarted itself, delivery resumed"

setguc pg_logtap.export_url ''; setguc pg_logtap.export_fallback_file ''; reload
docker rm -f "$VEC" >/dev/null
echo "e2e-kill: all scenarios passed"
