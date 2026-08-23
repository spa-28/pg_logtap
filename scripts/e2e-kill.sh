#!/bin/sh
# Failure-mode acceptance — the contract under test lives in docs/delivery.md:
#   receiver-outage    : receiver down → up; backlog holds events, zero lost,
#                        zero duplicate seqs
#   postmaster-kill    : SIGKILL with a RAM backlog; in-RAM events gone (the
#                        documented loss), counters restart from zero, seq
#                        strictly above every pre-kill seq (wall-clock seeded
#                        → dedup-by-seq spans restarts)
#   fallback-queue     : receiver dead + export_fallback_file set → zero
#                        lost, every event in the file
#   torn-queue-tail    : a member header claiming more bytes than the file
#                        holds (crash mid-append) is cut at the member
#                        boundary at the next read; appends resume there,
#                        replay stays on
#   worker-crash       : worker kill -9 → postmaster emergency-restarts the
#                        cluster, delivery resumes
#   worker-term-midsend: worker SIGTERM inside a blocked send; the shutdown
#                        flush parks the RAM backlog the dying process would
#                        otherwise drop (ring events survive anyway — the
#                        restarted worker picks them up)
#   postmaster-stop    : graceful stop (SIGTERM) with a backlog finishes in
#                        bounded time (final flush ≈1 s + one send timeout)
#                        and the parked queue survives the restart
# Usage: scripts/e2e-kill.sh [pg_container]
# The receiver comes from the compose stand (tests/e2e/compose.yaml); its
# readiness gate must have passed.
set -eu
PG_CT="${1:-pglogtap-pg}"
NET=pglogtap-e2e_default
OUT=/tmp/logtap-e2e
VEC=pglogtap-vector
SILENT=pglogtap-silent

fail() {
  echo "e2e-kill: FAILED: $*" >&2
  # Post-mortem for the log: counters, worker liveness, export transition
  # lines, the receiver's own log. The server-log grep scans the WHOLE log
  # and only then tails: a burst of the very events being lost once pushed
  # the "export failing (fail_reason)" line past a plain tail -15.
  docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" >&2 || true
  docker exec "$PG_CT" psql -U postgres -Atc \
    "SELECT pid || ' ' || backend_type FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'" >&2 || true
  docker logs "$PG_CT" 2>&1 | grep -iE "logtap.*(failing|recovered|divert|fallback|lost)|PANIC|FATAL" | tail -8 >&2 || true
  docker logs --tail 8 "$VEC" >&2 2>&1 || true
  exit 1
}
ok() { echo "  ok: $*"; }

wait_vector() { # until the receiver actually accepts TCP again after the
  # suite itself stopped it (docker start): vector rebinds its port SLOWLY on
  # a loaded host (observed 30 s locally), and generating before that fails
  # every send and burns the wait_for windows.
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$PG_CT" bash -c "exec 3<>/dev/tcp/$VEC/8686" 2>/dev/null && return 0
    n=$((n + 1)); sleep 1
  done
  fail "receiver $VEC not accepting connections after 60s"
}

# Stand gate: the compose one-shot must have passed — pg healthy AND the
# receiver port answering at boot (tests/e2e/compose.yaml, `ready`).
[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] \
  || fail "e2e stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d"

docker network connect "$NET" "$PG_CT" 2>/dev/null || true # non-stand pg arg
mkdir -p "$OUT" # vector-out.jsonl accumulates across runs BY DESIGN:
                # counting is marker-based, never line-total-based

setguc() { docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $1 = '$2'" >/dev/null; }
reload() { docker exec "$PG_CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null; }
SUF="-$$" # per-run marker suffix: vector-out.jsonl accumulates across runs
gen() { # gen <marker> <count> — distinct events from one psql round trip.
  # Markers carry the run's PID ($SUF): vector-out.jsonl accumulates across
  # runs, and identical markers would make an old run's lines satisfy this
  # run's asserts. WARNING: above the default log_min_messages (so it reaches
  # the hook) and not an error (so the loop is not aborted); a caught RAISE
  # EXCEPTION never reaches the server log at all.
  docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
    WHILE i < $2 LOOP
      RAISE WARNING 'logtap kill $1$SUF %', i;
      i := i + 1;
    END LOOP; END \$\$" >/dev/null 2>&1 || echo "  gen $1: psql FAILED (events never emitted)" >&2
}
# Count distinct marker events; the trailing digit requirement keeps out the
# duration-log line of the generating DO statement itself (its message quotes
# the RAISE format string when log_min_duration_statement is on).
received() { grep -oE "logtap kill $1$SUF [0-9]+" "$OUT/vector-out.jsonl" 2>/dev/null | sort -u | wc -l; }
seqs_of() { grep -E "logtap kill $1$SUF [0-9]+" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | cut -d: -f2; }
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
statf() { s=$(stats); v=${s#*"$1"=}; echo "${v%% *}"; }
wait_for() { # wait_for <marker> <count>
  n=0
  while [ "$n" -lt 15 ]; do
    [ "$(received "$1")" -ge "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
}

echo "== receiver outage: down → up =="
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.export_fallback_file ''; reload; sleep 2
gen outage1 20; wait_for outage1 20
gen outage2 100 # more baseline traffic, all delivered while the receiver is up
wait_for outage2 100
docker stop "$VEC" >/dev/null
gen outage3 100; sleep 3 # failed cycles → events buffer in the worker backlog
docker start "$VEC" >/dev/null; wait_vector
gen outage4 20
wait_for outage3 100; wait_for outage4 20
dups=$(grep 'logtap kill' "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$(received outage1)" = 20 ] && [ "$(received outage3)" = 100 ] && [ "$(received outage4)" = 20 ] \
  || fail "receiver outage: loss (outage1=$(received outage1) outage3=$(received outage3) outage4=$(received outage4))"
[ "$dups" = 0 ] || fail "receiver outage: $dups duplicate seqs — dedup-by-seq contract broken"
[ "$(statf events_lost)" = 0 ] && [ "$(statf events_dropped)" = 0 ] \
  || fail "receiver outage: counters lost=$(statf events_lost) dropped=$(statf events_dropped)"
ok "140/140 delivered, 0 duplicate seqs, lost=0 dropped=0"

echo "== postmaster kill: SIGKILL with a RAM backlog =="
setguc pg_logtap.export_url "http://127.0.0.1:1"; setguc pg_logtap.export_fallback_file ''
reload; sleep 2 # dead port: dial fails instantly, no fallback — pure RAM backlog
# Baseline after the reload: the live URL may still export during the switch.
base_cap=$(statf events_captured); base_exp=$(statf events_sent)
gen kill1 300; sleep 3
[ $(( $(statf events_captured) - base_cap )) -ge 300 ] || fail "postmaster kill: events not captured"
[ $(( $(statf events_sent) - base_exp )) = 0 ] || fail "postmaster kill: sent moved with a dead receiver"
[ "$(statf events_lost)" = 0 ] || fail "postmaster kill: backlog overflowed (ring too small for 300 events?)"
pre_seq=$(grep -o '"seq":[0-9]*' "$OUT/vector-out.jsonl" | cut -d: -f2 | sort -n | tail -1)
docker kill "$PG_CT" >/dev/null # SIGKILL: postmaster, worker, shmem — all gone
docker start "$PG_CT" >/dev/null; wait_ready
# Fresh shmem: only the postmaster's own boot noise is captured (well under
# kill1's 300 even at debug1 verbosity), nothing delivered. Had the old segment
# survived, captured would be ≥300.
[ "$(statf events_captured)" -lt 150 ] && [ "$(statf events_sent)" = 0 ] && [ "$(statf events_lost)" = 0 ] \
  || fail "postmaster kill: counters did not reset from zero after restart"
ok "counters fresh (captured=$(statf events_captured) boot noise); the 300 in-RAM events are the documented restart loss"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
gen kill2 20; wait_for kill2 20
new_min=$(seqs_of kill2 | sort -n | head -1)
[ "$(received kill2)" = 20 ] || fail "postmaster kill: no delivery after restart"
[ "$new_min" -gt "$pre_seq" ] \
  || fail "postmaster kill: seq regressed across restart (new min $new_min <= pre-kill max $pre_seq)"
ok "delivery resumed, min new seq $new_min > pre-kill max $pre_seq"

echo "== fallback queue: compressed append + replay =="
FB_REL=pg_logtap-fallback.bin # relative: must resolve against PGDATA
FB_DIR=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW data_directory")
FB="$FB_DIR/$FB_REL"
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen queue1 2600; sleep 3 # >2 members at chunk_max=1024: multi-member replay
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
docker exec "$PG_CT" head -c 8 "$FB" | grep -q PGLTFB01 || fail "fallback queue: no queue magic in $FB"
docker exec "$PG_CT" grep -q "logtap kill queue1" "$FB" 2>/dev/null && fail "fallback queue: file is plain text, not compressed"
[ "$(statf events_lost)" = 0 ] || fail "fallback queue: lost>0 despite the fallback file"
ok "receiver dead → 2600 events queued compressed ($fb_sz bytes), lost=0"
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
# The queue is on disk: a cluster restart must not lose it — replay after boot.
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for queue1 2600
[ "$(received queue1)" = 2600 ] || fail "fallback queue: replay delivered $(received queue1)/2600"
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$fb_sz" = 0 ] || fail "fallback queue: queue not truncated after replay ($fb_sz bytes left)"
queue_dups=$(seqs_of queue1 | sort | uniq -d | wc -l)
[ "$queue_dups" = 0 ] || fail "fallback queue: $queue_dups duplicate seqs in replay"
[ "$(statf events_lost)" = 0 ] || fail "fallback queue: lost>0 during replay"
ok "restart + receiver back → 2600/2600 replayed, queue truncated, 0 duplicate seqs"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2

echo "== torn queue tail: crash mid-append =="
# The exact shape a crash mid-append leaves: magic, a member header claiming
# 1000 bytes, then only 100. The worker's next read (its boot-time queue
# walk) must cut the file back to the member boundary and append there —
# not disable replay, not misparse the framing.
since0=$(date -u +%Y-%m-%dT%H:%M:%S)
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload
docker exec "$PG_CT" sh -c "printf 'PGLTFB01' > '$FB'; printf '\350\003\000\000' >> '$FB'; head -c 100 /dev/zero >> '$FB'"
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
sleep 2 # boot queue walk reads the file and truncates the torn tail
gen torn1 20; sleep 3 # parks at the member boundary the walk left
sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$sz" -gt 112 ] || fail "torn queue tail: nothing appended after the cut (size $sz)"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for torn1 20
[ "$(received torn1)" = 20 ] || fail "torn queue tail: replay broken (torn1=$(received torn1)/20)"
docker logs --since "$since0" "$PG_CT" 2>&1 \
  | grep -qE "replay disabled|framing corrupt|not a pg_logtap queue" \
  && fail "torn queue tail: misparsed as corrupt instead of cut"
ok "torn tail cut at the member boundary, appends resumed, 20/20 replayed"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2

echo "== worker crash: kill -9, emergency cluster restart =="
# debug1 makes the postmaster log during the emergency restart — its emit_log
# hook calls happen while shmem is unmapped, which used to SEGV the cluster.
setguc log_min_messages debug1; setguc pg_logtap.level_min 10; reload
wpid=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$wpid" ] || fail "worker crash: worker not found in pg_stat_activity"
docker exec "$PG_CT" kill -9 "$wpid"
sleep 5; wait_ready; sleep 2 # postmaster emergency-restarts the cluster
setguc log_min_messages warning; setguc pg_logtap.level_min 15; reload
gen crash1 20; wait_for crash1 20
[ "$(received crash1)" = 20 ] || fail "worker crash: no delivery after worker crash"
ok "worker crash → cluster restarted itself, delivery resumed"

echo "== worker SIGTERM mid-send: shutdown flush parks the RAM backlog =="
# A mute receiver (accepts, never answers) pins the worker in recv for the
# full export_timeout_ms — recvSome retries EINTR, so the window is
# deterministic, not a race. term1 (600 > chunk_max) leaves ~344 events in
# the RAM backlog when the cycle parks the first chunk; the backlog dies
# with the process, so only the worker's shutdown flush can park it. term2
# lands in the ring during the same window and rides the worker restart
# instead. The mute receiver is the stand's `silent` service.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_timeout_ms 3000
setguc pg_logtap.export_url "http://$SILENT:9499"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
wpid=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$wpid" ] || fail "worker SIGTERM: worker not found"
gen term1 600; sleep 1 # worker: drains term1, send → recv blocked for 3s
gen term2 100 # captured during the blocked recv
docker exec "$PG_CT" kill -TERM "$wpid" # inside the 3s recv window
sleep 8 # recv timeout → park chunk → shutdown flush parks the backlog → restart
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for term1 600; wait_for term2 100
[ "$(received term1)" = 600 ] || fail "worker SIGTERM: RAM backlog lost on worker TERM (term1=$(received term1)/600)"
[ "$(received term2)" = 100 ] || fail "worker SIGTERM: ring events lost on worker TERM (term2=$(received term2)/100)"
# Counter invariant: the restarted worker must not re-credit the parked file
# (its predecessor already counted those appends) — backlog = queued - replayed
# would read 700 forever while the file itself is empty.
term_bl=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$term_bl" = 0 ] || fail "worker SIGTERM: queue_backlog=$term_bl after replay — counter drift on worker restart"
ok "worker TERM mid-send: shutdown flush parked the backlog, 700/700 replayed, queue_backlog=0"

echo "== postmaster graceful stop: bounded final flush, queue survives =="
# delivery.md: a graceful stop runs ONE final flush cycle, bounded (~1 s of
# work plus one send timeout). An unbounded flush would hang the stop until
# docker's own 10 s SIGKILL — the bound is the contract under test.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1" # dead port: dial fails instantly
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen stop1 300; sleep 3 # all parked to the queue
start_s=$(date +%s)
docker stop "$PG_CT" >/dev/null
stop_s=$(( $(date +%s) - start_s ))
[ "$stop_s" -lt 10 ] || fail "postmaster stop: graceful stop took ${stop_s}s — final flush unbounded?"
docker start "$PG_CT" >/dev/null; wait_ready
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for stop1 300
[ "$(received stop1)" = 300 ] || fail "postmaster stop: queue lost across graceful stop (stop1=$(received stop1)/300)"
ok "graceful stop in ${stop_s}s (bounded), queue carried 300/300 across the shutdown"

setguc pg_logtap.export_url ''; setguc pg_logtap.export_fallback_file ''
setguc pg_logtap.export_timeout_ms 5000; reload
echo "e2e-kill: all scenarios passed"
