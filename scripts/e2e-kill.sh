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
#   corrupt-member     : a damaged gzip member mid-queue (framing intact) is
#                        skipped and counted lost; later members still replay
#   bomb-member        : a member under the compressed bound that inflates
#                        far past it (gzip bomb) is skipped like a damaged
#                        one; the worker's memory stays flat, later members
#                        still replay
#   url-fb-aliasing    : a file:// export_url and the fallback path naming
#                        one file are rejected at SET, in both directions
#   symlink-queue      : a symlink at the fallback path is refused — the file
#                        it names stays intact, fallback_broken=1 + one
#                        WARNING, events ride the RAM backlog
#   inode-aliasing     : symlink/hardlink aliases the SET-time string check
#                        cannot see are refused at OPEN time on both sides —
#                        the sink refuses to send (queue framing stays
#                        intact), the queue latches broken (the live sink
#                        keeps delivering pure NDJSON)
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
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init kill "${1:-}"
e2e_gate

# Ground truth on the receiver name at failure time: a fresh glibc lookup
# (what the bash probe uses) vs the worker's wedged one, plus the container's
# actual network registration — repeated, because the wedge sets in AFTER a
# brief good window following docker start.
fail_extra() {
  n=1; while [ "$n" -le 3 ]; do
    docker exec "$E2E_CT" getent hosts "$VEC" >&2 2>&1 || echo "  getent #$n: FAIL" >&2
    n=$((n + 1)); sleep 2
  done
  docker inspect -f "receiver nets: {{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}={{\$v.IPAddress}} {{end}}" "$VEC" >&2
  docker exec "$E2E_CT" getent hosts "$E2E_CT" >&2
  docker logs "$VEC" 2>&1 | grep -iE "panic|fatal|shut" | tail -3 >&2
  docker logs --tail 8 "$VEC" >&2 2>&1
}

echo "== receiver outage: down → up =="
# Counters are per-cluster-life: a previous kill run's lossy scenarios
# (fallback_max_mb) leave them non-zero on a reused container, so the
# no-loss asserts below are DELTAS from here, not absolute zeros.
lost0=$(statf events_lost); drp0=$(statf events_dropped)
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.export_fallback_file ''; reload; sleep 2
gen outage1 20; wait_for outage1 20
gen outage2 100 # more baseline traffic, all delivered while the receiver is up
wait_for outage2 100
docker stop "$VEC" >/dev/null
gen outage3 100; sleep 3 # failed cycles → events buffer in the worker backlog
docker start "$VEC" >/dev/null; wait_vector
gen outage4 20
wait_for outage3 100; wait_for outage4 20
# A vector that dies right after docker start (seen in CI: silent exit ~1s in,
# the name leaves docker DNS, every dial fails fast) is a receiver-infra
# failure, not an extension loss — the worker correctly buffers outage4. Revive
# it and let the backlog drain; only a live receiver with short counts is loss.
if ! { [ "$(received outage3)" = 100 ] && [ "$(received outage4)" = 20 ]; }; then
  if ! docker exec "$PG_CT" bash -c "exec 3<>/dev/tcp/$VEC/8686" 2>/dev/null; then
    echo "  receiver died mid-scenario — restarting, buffered backlog should drain"
    docker start "$VEC" >/dev/null; wait_vector
    wait_for outage3 100; wait_for outage4 20
  fi
fi
dups=$(grep 'logtap kill' "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$(received outage1)" = 20 ] && [ "$(received outage3)" = 100 ] && [ "$(received outage4)" = 20 ] \
  || fail "receiver outage: loss (outage1=$(received outage1) outage3=$(received outage3) outage4=$(received outage4))"
[ "$dups" = 0 ] || fail "receiver outage: $dups duplicate seqs — dedup-by-seq contract broken"
[ "$(( $(statf events_lost) - lost0 ))" = 0 ] && [ "$(( $(statf events_dropped) - drp0 ))" = 0 ] \
  || fail "receiver outage: counters lost=$(( $(statf events_lost) - lost0 )) dropped=$(( $(statf events_dropped) - drp0 ))"
ok "140/140 delivered, 0 duplicate seqs, lost=0 dropped=0"

echo "== postmaster kill: SIGKILL with a RAM backlog =="
setguc pg_logtap.export_url "http://127.0.0.1:1"; setguc pg_logtap.export_fallback_file ''
reload; sleep 2 # dead port: dial fails instantly, no fallback — pure RAM backlog
# Baseline after the reload: the live URL may still export during the switch.
base_cap=$(statf events_captured); base_exp=$(statf events_sent)
gen kill1 300; sleep 3
[ $(( $(statf events_captured) - base_cap )) -ge 300 ] || fail "postmaster kill: events not captured"
[ $(( $(statf events_sent) - base_exp )) = 0 ] || fail "postmaster kill: sent moved with a dead receiver"
[ "$(( $(statf events_lost) - lost0 ))" = 0 ] || fail "postmaster kill: backlog overflowed (ring too small for 300 events?)"
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
# R-4: parking into an UNBOUNDED queue (fallback_max_mb=0) must say so —
# exactly one WARNING per divert, not one per append. The warn_fallback_unbounded
# counter (in pg_logtap_stats) is the queryable copy of that log line.
warns0=$(statf warn_fallback_unbounded)
setguc pg_logtap.fallback_max_mb 0; reload
# SHOW barrier, not a timed sleep: on a slow runner the whole 2600-event
# burst parks before the worker applies the reload, every divert sees the
# old cap and the unbounded warning never fires (seen on a CI arm64 box).
n=0; while [ "$n" -lt 20 ] && [ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.fallback_max_mb")" != 0 ]; do
  n=$((n + 1)); sleep 1
done
sleep 1 # one flush cycle for the worker to apply the landed config
gen queue1 2600; sleep 3 # >2 members at chunk_max=1024: multi-member replay
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
docker exec "$PG_CT" head -c 8 "$FB" | grep -q PGLTFB01 || fail "fallback queue: no queue magic in $FB"
docker exec "$PG_CT" grep -q "logtap kill queue1" "$FB" 2>/dev/null && fail "fallback queue: file is plain text, not compressed"
[ "$(statf events_lost)" = 0 ] || fail "fallback queue: lost>0 despite the fallback file"
warns=$(( $(statf warn_fallback_unbounded) - warns0 ))
[ "$warns" = 1 ] || fail "fallback-queue: unbounded-queue WARNING count is $warns, want exactly 1"
ok "receiver dead → 2600 events queued compressed ($fb_sz bytes), lost=0, unbounded warned once"
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
setguc pg_logtap.fallback_max_mb 512 # back to the default for later scenarios
ok "restart + receiver back → 2600/2600 replayed, queue truncated, 0 duplicate seqs"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2

echo "== torn queue tail: crash mid-append =="
# The exact shape a crash mid-append leaves: magic, a member header claiming
# 1000 bytes, then only 100. The worker's next read (its boot-time queue
# walk) must cut the file back to the member boundary and append there —
# not disable replay, not misparse the framing (fallback_broken stays 0).
corr0=$(statf fallback_broken)
# Write the template while the fallback is still off (export_fallback_file=''
# since the previous scenario) — the worker does not open the file at all.
# Writing it after the reload instead raced the worker's own appends: parking
# had already started (receiver pointed at a dead port), and the interleaved
# writes left garbage at offset 8, which the boot walk then rightfully reported
# as framing corrupt instead of cutting the torn member (seen on pg16).
docker exec "$PG_CT" sh -c "printf 'PGLTFB01' > '$FB'; printf '\350\003\000\000' >> '$FB'; head -c 100 /dev/zero >> '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
sleep 2 # boot queue walk reads the file and truncates the torn tail
gen torn1 20; sleep 3 # parks at the member boundary the walk left
sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$sz" -gt 112 ] || fail "torn queue tail: nothing appended after the cut (size $sz)"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for torn1 20
[ "$(received torn1)" = 20 ] || fail "torn queue tail: replay broken (torn1=$(received torn1)/20)"
[ "$(statf fallback_broken)" = "$corr0" ] || fail "torn queue tail: misparsed as corrupt instead of cut (fallback_broken=$(statf fallback_broken))"
ok "torn tail cut at the member boundary, appends resumed, 20/20 replayed"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2

echo "== corrupt member mid-queue: skipped, later members still replay =="
# A/CORRUPT/B/C: park four marker batches with the receiver dead, smash
# every member holding cmX (gzip payload, framing [len] intact), restart,
# revive the receiver. The walk must skip exactly the damaged members
# (counted lost), credit and replay the rest — and NOT escalate to
# "replay disabled", which a framing-level corruption would cause.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen cmA 10; sleep 1; gen cmX 10; sleep 1; gen cmB 10; sleep 1; gen cmC 10; sleep 2
# Find EVERY member holding cmX by walking the framing ([len:4][gzip
# payload] per member after the 8-byte magic) and inflating each candidate
# on the spot. Two reasons a marker is not "one member": noise events
# (scenario-switch traffic) park ahead of or between the markers, and a
# flush-cycle boundary mid-burst splits one gen across members (a 10-event
# gen parks 1+9). Smash them all; each [len] framing around them survives.
sz=$(docker exec "$PG_CT" stat -c %s "$FB")
off=8; hits=""; nhits=0
while [ "$off" -lt "$sz" ]; do
  len=$(docker exec "$PG_CT" od -An -tu4 -j"$off" -N4 "$FB" | tr -d ' \n')
  [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null || fail "corrupt member: framing unreadable at $off (len='$len')"
  end=$((off + 4 + len)); [ "$end" -le "$sz" ] || fail "corrupt member: torn member at $off (end=$end sz=$sz)"
  body=$(docker exec "$PG_CT" sh -c "dd if='$FB' bs=1 skip=$((off + 4)) count=$len 2>/dev/null | gzip -dc" 2>/dev/null)
  case "$body" in
    *"logtap kill cmX"*)
      # A member holding cmX AND another marker means a flush-cycle stall
      # merged two gens: smashing it would eat intact events and every assert
      # below would point at the wrong thing. Scenario arithmetic broke, not
      # the product — say so instead of failing cryptically.
      echo "$body" | grep -qE "logtap kill cm[ABC]" \
        && fail "corrupt member: cmX shares its member with A/B/C (flush stall merged the gens) — rerun the scenario"
      hits="$hits $off"; nhits=$((nhits + 1)) ;;
  esac
  off=$end
done
[ "$nhits" -ge 1 ] || fail "corrupt member: no cmX member found in the queue"
for h in $hits; do
  docker exec "$PG_CT" sh -c "dd if=/dev/zero of='$FB' bs=1 seek=$((h + 4)) count=16 conv=notrunc" >/dev/null 2>&1
done
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for cmA 10; wait_for cmB 10; wait_for cmC 10
[ "$(received cmA)" = 10 ] && [ "$(received cmB)" = 10 ] && [ "$(received cmC)" = 10 ] \
  || fail "corrupt member: intact members not replayed (cmA=$(received cmA) cmB=$(received cmB) cmC=$(received cmC))"
[ "$(received cmX)" = 0 ] || fail "corrupt member: damaged member delivered $(received cmX) events"
# Fresh shmem at the restart: the skips are the only thing that touched
# lost — one per damaged member (the member, not its events, is the loss
# unit)
[ "$(statf events_lost)" = "$nhits" ] || fail "corrupt member: events_lost=$(statf events_lost), want $nhits"
skip=$(statf warn_fallback_skipped)
# twice per member by design: the boot walk that credits the backlog counts
# it, then the drain's own read of the damaged member counts it again
[ "$skip" = $((2 * nhits)) ] || fail "corrupt member: 'unreadable, skipped' fired $skip times, want $((2 * nhits))"
[ "$(statf fallback_broken)" = 0 ] || fail "corrupt member: damaged payload escalated to a framing error"
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$fb_sz" = 0 ] || fail "corrupt member: queue not truncated after replay ($fb_sz bytes left)"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "$nhits damaged member(s) skipped (lost=$(statf events_lost)), A/B/C replayed 30/30, framing held"

echo "== decompression-bomb member: inflate bounded, member skipped not inflated =="
# A member whose COMPRESSED length passes the framing bound but which
# inflates far past member_max: the fixed inflate buffer is the ceiling —
# the member is skipped as unreadable exactly like a damaged one, the
# worker's memory stays flat, and later members replay. An unbounded
# inflate would have taken 512MB of RSS before a post-hoc size check.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen bombX 10; sleep 1; gen bombA 10; sleep 2
# The bomb: 512MB of zeros gzip-9s to well under the ~5.2MB framing bound
# and inflates a hundredfold past it. Built in-container — dd and gzip are
# the same tools the walk above uses.
docker exec "$PG_CT" sh -c "dd if=/dev/zero bs=1048576 count=512 2>/dev/null | gzip -9 -c > /tmp/bomb.gz"
blen=$(docker exec "$PG_CT" stat -c %s /tmp/bomb.gz)
[ "$blen" -lt 5000000 ] 2>/dev/null || fail "bomb member: compressed $blen not under the framing bound — scenario broken"
# Replace every bombX member's gzip payload with the bomb (framing [len]
# rewritten to the bomb's length) — same walk as the corrupt-member phase.
sz=$(docker exec "$PG_CT" stat -c %s "$FB")
off=8; segs=""; nb=0
while [ "$off" -lt "$sz" ]; do
  len=$(docker exec "$PG_CT" od -An -tu4 -j"$off" -N4 "$FB" | tr -d ' \n')
  [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null || fail "bomb member: framing unreadable at $off (len='$len')"
  end=$((off + 4 + len)); [ "$end" -le "$sz" ] || fail "bomb member: torn member at $off (end=$end sz=$sz)"
  body=$(docker exec "$PG_CT" sh -c "dd if='$FB' bs=1 skip=$((off + 4)) count=$len 2>/dev/null | gzip -dc" 2>/dev/null)
  case "$body" in
    *"logtap kill bombX"*) segs="$segs $off:$end"; nb=$((nb + 1)) ;;
  esac
  off=$end
done
[ "$nb" -ge 1 ] || fail "bomb member: no bombX member found in the queue"
# Splice in ONE docker exec ending in an atomic mv: a worker cycle landing
# mid-rebuild sees either the old or the new file, never a torn one.
b0=$((blen & 255)); b1=$(((blen >> 8) & 255)); b2=$(((blen >> 16) & 255)); b3=$(((blen >> 24) & 255))
lesc=$(printf '\\%03o\\%03o\\%03o\\%03o' "$b0" "$b1" "$b2" "$b3")
docker exec "$PG_CT" sh -c "
  : > /tmp/fb.new
  prev=0
  for s in $segs; do
    o=\${s%:*}; e=\${s#*:}
    tail -c +\$((prev + 1)) '$FB' | head -c \$((o - prev)) >> /tmp/fb.new
    printf '$lesc' >> /tmp/fb.new
    cat /tmp/bomb.gz >> /tmp/fb.new
    prev=\$e
  done
  tail -c +\$((prev + 1)) '$FB' >> /tmp/fb.new
  mv /tmp/fb.new '$FB'; rm -f /tmp/bomb.gz
"
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
sleep 2 # the boot queue walk hits the bomb here — this is the bounded-inflate moment
hwm=$(docker exec "$PG_CT" cat "/proc/$(worker_pid)/status" 2>/dev/null | awk '/^VmHWM/{print $2}')
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for bombA 10
[ "$(received bombA)" = 10 ] || fail "bomb member: later members not replayed (bombA=$(received bombA)/10)"
[ "$(received bombX)" = 0 ] || fail "bomb member: bomb content delivered?? (bombX=$(received bombX))"
# Fresh shmem at the restart, so absolutes: one loss per bomb member (the
# member, not its events), two skips per member (boot walk + drain), and
# the skip must never escalate to a framing error.
[ "$(statf events_lost)" = "$nb" ] || fail "bomb member: events_lost=$(statf events_lost), want $nb"
[ "$(statf warn_fallback_skipped)" = $((2 * nb)) ] || fail "bomb member: 'unreadable, skipped' fired $(statf warn_fallback_skipped) times, want $((2 * nb))"
[ "$(statf fallback_broken)" = 0 ] || fail "bomb member: overflow escalated to a framing error"
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$fb_sz" = 0 ] || fail "bomb member: queue not truncated after replay ($fb_sz bytes left)"
[ -n "$hwm" ] && [ "$hwm" -lt 200000 ] 2>/dev/null \
  || fail "bomb member: worker peak RSS ${hwm:-unreadable}kB — the 512MB bomb was inflated, not bounded"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "$nb bomb member(s) skipped, worker peak RSS ${hwm}kB bounded, bombA replayed 10/10"

echo "== file:// url == fallback path: the pair is rejected at SET =="
# The NDJSON sink and the PGLTFB01 queue framing cannot share a file; the
# SET-time check rejects whichever GUC lands second. A reload between the
# two ALTER SYSTEMs is load-bearing: the check hook in a fresh session
# reads the peer GUC as the postmaster last parsed it, and ALTER SYSTEM
# alone applies the value nowhere — without the reload the hook would still
# see the old url and wave the pair through. Throwaway paths throughout:
# while url=file:// is live the worker writes NDJSON there (no fallback is
# set at that point, so no queue ever sees it), and all values are restored
# at the end.
al=/tmp/logtap-alias.bin
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'file://$al'" >/dev/null
reload; sleep 2
out=$(docker exec "$PG_CT" psql -U postgres -c "ALTER SYSTEM SET pg_logtap.export_fallback_file = '$al'" 2>&1)
echo "$out" | grep -q ERROR || fail "aliasing: fallback='$al' accepted with url=file://$al"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_fallback_file")" = "" ] \
  || fail "aliasing: rejected ALTER SYSTEM still changed the fallback GUC"
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$VEC:8686'" >/dev/null
reload; sleep 2
# the other direction: fallback first (accepted — the url is http), then
# the file:// url naming the same file
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = '$al'" >/dev/null
reload; sleep 2
out=$(docker exec "$PG_CT" psql -U postgres -c "ALTER SYSTEM SET pg_logtap.export_url = 'file://$al'" 2>&1)
echo "$out" | grep -q ERROR || fail "aliasing: url=file://$al accepted with fallback='$al'"
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = ''" >/dev/null
reload; sleep 2
# control: a DIFFERENT fallback path under a file:// url is fine — the
# rejection is the aliasing, not file:// itself. The fallback is loaded
# first so the check hook really sees it (same postmaster-parse rule), and
# the SHOW after the reload proves the pair landed.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = '/tmp/logtap-other.bin'" >/dev/null
reload; sleep 2
out3=$(docker exec "$PG_CT" psql -U postgres -c "ALTER SYSTEM SET pg_logtap.export_url = 'file:///tmp/logtap-other2.bin'" 2>&1)
echo "$out3" | grep -q ERROR && fail "aliasing: distinct file:// url + fallback rejected — the check overfires"
reload; sleep 2
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_url")" = "file:///tmp/logtap-other2.bin" ] \
  || fail "aliasing: control pair not accepted"
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$VEC:8686'" >/dev/null
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = ''" >/dev/null
reload; sleep 2
docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_url" | grep -q "http://$VEC:8686" \
  || fail "aliasing: rejected ALTER SYSTEM still changed the url GUC"
ok "file:// url == fallback path rejected in both directions, a distinct pair accepted"

echo "== symlink at the queue path: refused, RAM backlog carries the events =="
# Anything able to write to the data directory must not be able to aim the
# queue at another file: a symlink at the fallback path is refused
# (O_NOFOLLOW, like the compaction temp), the file it points at stays
# byte-identical, and delivery degrades to the RAM backlog — zero loss
# once the receiver returns. The refusal is visible like any other broken
# queue: fallback_broken=1 and one WARNING (fb_broken stops the re-opens;
# repointing the GUC or a restart re-checks — the foreign-file recovery).
docker exec "$PG_CT" sh -c "rm -f '$FB'; printf 'CANARY-INTACT\n' > '$FB_DIR/pg_logtap-canary'; ln -s pg_logtap-canary '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
warn0=$(statf warn_fallback_open)
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen sl1 20; sleep 3
canary=$(docker exec "$PG_CT" cat "$FB_DIR/pg_logtap-canary" 2>/dev/null || echo GONE)
[ "$canary" = "CANARY-INTACT" ] || fail "symlink queue: canary written through the symlink ('$canary')"
[ "$(statf fallback_broken)" = 1 ] || fail "symlink queue: fallback_broken=$(statf fallback_broken), want 1 — a refused open must show on the gauge"
warn=$(( $(statf warn_fallback_open) - warn0 ))
[ "$warn" = 1 ] || fail "symlink queue: 'cannot be opened' warned $warn time(s), want 1 (once — fb_broken stops the re-opens)"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for sl1 20
[ "$(received sl1)" = 20 ] || fail "symlink queue: RAM backlog did not drain ($(received sl1)/20)"
docker exec "$PG_CT" sh -c "rm -f '$FB' '$FB_DIR/pg_logtap-canary'"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "symlink refused: canary intact, fallback_broken=1 warned once, 20/20 via the RAM backlog"

echo "== file:// sink via symlink -> the queue's file: refused at the inode =="
# The SET-time check compares PATH STRINGS; a symlink names the same inode
# under a different string, so the pair loads. The open-time inode check is
# what catches it — and it is symmetric (each side stats the other's file),
# so BOTH refuse: no send lands raw NDJSON in the queue's framing, the queue
# never appends PGLTFB01 into the sink, and the RAM backlog carries the
# events until the GUC is repointed. A FRESH queue name on purpose: the
# symlink phase left the old string broken-latched, and path() re-checks
# only on a string change — fbOpen must actually run to create the file
# the sink-side stat compares against.
FB2_REL=pg_logtap-fallback2.bin
FB2="$FB_DIR/$FB2_REL"
docker exec "$PG_CT" sh -c "rm -f '$FB2' '$FB_DIR/logtap-sink-alias.bin'; ln -s '$FB2_REL' '$FB_DIR/logtap-sink-alias.bin'"
# fallback FIRST, while the url is still http: fbOpen creates the (empty)
# queue file; with the url not yet file:// neither check fires and nothing
# writes through the symlink. Only then does the url land, and the first
# send meets both refusals — so "file stayed empty" is deterministic.
setguc pg_logtap.export_fallback_file "$FB2_REL"; reload; sleep 2
setguc pg_logtap.export_url "file://$FB_DIR/logtap-sink-alias.bin"; reload; sleep 2
failA0=$(statf send_cycles_failed)
gen salias 20; sleep 3
[ "$(statf send_cycles_failed)" -gt "$failA0" ] \
  || fail "sink alias: send cycles not failing against the symlinked sink"
[ "$(statf fallback_broken)" = 1 ] || fail "sink alias: fallback_broken=$(statf fallback_broken), want 1 — the queue-side inode check must fire too"
asize=$(docker exec "$PG_CT" stat -c %s "$FB2" 2>/dev/null || echo 0)
[ "$asize" = 0 ] \
  || fail "sink alias: $asize bytes at the queue path — one of the two writers landed in the other's file"
[ "$(docker exec "$PG_CT" grep -c "logtap $E2E_TAG" "$FB2" 2>/dev/null)" = 0 ] \
  || fail "sink alias: raw NDJSON marker lines landed in the queue file"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for salias 20
docker exec "$PG_CT" sh -c "rm -f '$FB2' '$FB_DIR/logtap-sink-alias.bin'"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "symlinked sink refused at the inode: file stayed empty, 20/20 carried by the RAM backlog"

echo "== fallback path hardlinked to the file:// sink: refused at the inode =="
# The mirror case through a HARDLINK (O_NOFOLLOW passes those; the SET
# strings differ): the file:// url names the real path, the fallback GUC
# names its hardlink. Yet another FRESH queue name — path() re-checks only
# on a string change, and the symlink scenario left fallback2 latched
# broken. Same symmetric outcome: the queue latches broken, the sink
# refuses, the shared file stays empty, recovery is one repoint. Both
# files live in PGDATA: a hardlink cannot cross filesystems.
FB3_REL=pg_logtap-fallback3.bin
FB3="$FB_DIR/$FB3_REL"
# -u postgres: docker exec defaults to root, and a root-owned file is EACCES
# to the worker — the scenario would test permissions, not inodes.
docker exec -u postgres "$PG_CT" sh -c "rm -f '$FB3' '$FB_DIR/logtap-real2.bin'; : > '$FB_DIR/logtap-real2.bin'; ln '$FB_DIR/logtap-real2.bin' '$FB3'"
# Same order as the symlink scenario: the fallback loads while the url is
# still http (fbOpen sees the hardlink, no file:// side to alias yet), then
# the url lands and both refusals fire before the first write.
warnB0=$(statf warn_fallback_open)
setguc pg_logtap.export_fallback_file "$FB3_REL"; reload; sleep 2
setguc pg_logtap.export_url "file://$FB_DIR/logtap-real2.bin"; reload; sleep 2
failB0=$(statf send_cycles_failed)
gen halias 20; sleep 3
[ "$(statf fallback_broken)" = 1 ] || fail "hardlink queue: fallback_broken=$(statf fallback_broken), want 1"
[ "$(( $(statf warn_fallback_open) - warnB0 ))" -ge 1 ] || fail "hardlink queue: no WARNING for the refused queue open"
[ "$(statf send_cycles_failed)" -gt "$failB0" ] \
  || fail "hardlink queue: send cycles not failing against the aliased sink"
bsize=$(docker exec "$PG_CT" stat -c %s "$FB_DIR/logtap-real2.bin" 2>/dev/null || echo 0)
[ "$bsize" = 0 ] || fail "hardlink queue: $bsize bytes in the shared file — one of the two writers landed in the other's file"
# Reload before the rm: a file:// worker whose sink path vanishes re-creates
# it (O_CREAT) and "delivers" the backlog there — the url must point at the
# vector first, the files go after the drain.
setguc pg_logtap.export_url "http://$VEC:8686"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
wait_for halias 20
docker exec "$PG_CT" sh -c "rm -f '$FB3' '$FB_DIR/logtap-real2.bin'"
ok "hardlinked queue refused at the inode: fallback_broken=1 warned, file stayed empty, 20/20 via the RAM backlog"

echo "== worker crash: kill -9, emergency cluster restart =="
# debug1 makes the postmaster log during the emergency restart — its emit_log
# hook calls happen while shmem is unmapped, which used to SEGV the cluster.
setguc log_min_messages debug1; setguc pg_logtap.level_min 10; reload
# A crash between fbCompact's tmp creation and its rename would leave
# <fallback>.compact behind forever; the restarted worker must unlink it
# at boot. Plant one and check it after the restart.
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 1
docker exec "$PG_CT" sh -c "printf garbage > '$FB.compact'"
wpid=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$wpid" ] || fail "worker crash: worker not found in pg_stat_activity"
docker exec "$PG_CT" kill -9 "$wpid"
sleep 5; wait_ready; sleep 2 # postmaster emergency-restarts the cluster
setguc log_min_messages warning; setguc pg_logtap.level_min 15; reload
docker exec "$PG_CT" sh -c "test ! -e '$FB.compact'" \
  || fail "worker crash: stale $FB_REL.compact survived the worker restart"
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

echo "== worker double-TERM vs mute receiver: final flush is abortable =="
# A mute receiver with a 30s timeout pins the shutdown flush's writeAll/recv
# per syscall; the first TERM starts that flush, the second must end it. The
# parked fallback file carries the backlog across the restart (at-least-once).
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_timeout_ms 30000
setguc pg_logtap.export_url "http://$SILENT:9499"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
wpid=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$wpid" ] || fail "double-TERM: worker not found"
gen dterm 300; sleep 1
docker exec "$PG_CT" kill -TERM "$wpid"
sleep 2 # flush entered its recv against the mute receiver
docker exec "$PG_CT" kill -TERM "$wpid" 2>/dev/null # worker ignores? no: exit now
gone_s=-1; n=0
while [ "$n" -lt 10 ]; do
  docker exec "$PG_CT" psql -U postgres -Atc \
    "SELECT 1 FROM pg_stat_activity WHERE pid = $wpid" | grep -q 1 || { gone_s=$n; break; }
  n=$((n + 1)); sleep 0.5
done
[ "$gone_s" -ge 0 ] || fail "double-TERM: worker still alive ${n}x0.5s after the second TERM — final flush ignores it (stuck for the 30s timeout)"
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.export_timeout_ms 5000; reload; sleep 2
# 40s, not the usual 15: the postmaster-restarted worker starts with the
# stale auto.conf URL (silent, 30s timeout) and may sit one full stuck recv
# out before the reload reaches it
n=0; while [ "$n" -lt 40 ] && [ "$(received dterm)" -lt 300 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(received dterm)" = 300 ] || fail "double-TERM: $(received dterm)/300 delivered after restart — parked backlog lost"
dups=$(grep "logtap kill dterm$SUF" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$dups" = 0 ] || fail "double-TERM: $dups duplicate seqs — replay re-sent delivered members"
ok "second TERM ended the flush in $((gone_s / 2)).$(( (gone_s % 2) * 5 ))s, 300/300 replayed after restart, dup=0"

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

echo "== dns_fail_streak gauge: unresolvable host, then recovery =="
setguc pg_logtap.export_fallback_file '' # this scenario is about dns, not the queue
setguc pg_logtap.export_url "http://no-such-logtap-host$SUF:8686"
reload; sleep 1
gen dnsfail 5; sleep 2 # traffic forces a dial: getaddrinfo NONAME → streak ≥ 1
# (the events buffer in the RAM backlog — no fallback file in this scenario)
streak=$(statf dns_fail_streak)
[ "$streak" -ge 1 ] 2>/dev/null || fail "dns-fail gauge: dns_fail_streak=$streak after failed lookups — not exported?"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for dnsfail 5 # the buffered events ride the recovery
[ "$(statf dns_fail_streak)" = 0 ] || fail "dns-fail gauge: streak did not reset after recovery ($(statf dns_fail_streak))"
ok "dns_fail_streak $streak→0, visible in pg_logtap_stats()"

echo "== fallback_broken gauge: foreign file disables the queue, gauge says so =="
docker exec "$PG_CT" sh -c "echo 'not a pg_logtap queue' > '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"; reload; sleep 1
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2 # queue scan hits the foreign magic → fb_broken
[ "$(statf fallback_broken)" = 1 ] || fail "fallback_broken gauge: $(statf fallback_broken) with a foreign fallback file"
# While broken the worker won't touch that path again. The flag (and the
# queue) recover when the GUC points at a DIFFERENT path — the path-string
# change resets consumer state and re-checks the file — or on a restart.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
FB_REL2=pg_logtap-fallback2.bin
setguc pg_logtap.export_fallback_file "$FB_REL2"; reload; sleep 2
[ "$(statf fallback_broken)" = 0 ] || fail "fallback_broken gauge: did not clear on repoint to a fresh path ($(statf fallback_broken))"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 1
ok "fallback_broken 1→0: foreign file flagged, fresh path recovers the queue"

echo "== fallback_max_mb: a capped queue keeps the newest tail, counts the rest lost =="
# Sizing: this run's queue scenario shows ~15 compressed bytes per event, so
# a 1MB cap holds ~68k events. 150k events (~2.2MB) force at least one
# compaction to the newest 512KB even when the 8192-deep RAM backlog trims
# part of the burst on the way (a 90k storm sat exactly at the cap and
# whether compaction fired depended on parking's race with the storm). The
# exact split is compression-dependent; the asserts are the CONTRACT: file
# bounded, newest tail delivered, dropped events counted lost (compacted
# when the file was trimmed, lost when the backlog was), no duplicate
# replay.
docker exec "$PG_CT" sh -c "rm -f '$FB_DIR/$FB_REL2'"
setguc pg_logtap.fallback_max_mb 1
# The default backlog depth (65536 × ~3.4KB ≈ 220MB of worker RAM, documented
# ceiling) is legal but heavy: this container's memory.peak is later asserted
# under a 256MB cgroup ceiling (robust backlog-bound), and peak accumulates
# from birth — a full-depth transient here would trip that assert on a phase
# that was not even running. The GUC floor keeps the storm at ~28MB; the
# contract under test (file bound, newest tail, loss counting) needs the
# backlog only as a conveyor to the file, not at depth.
setguc pg_logtap.export_backlog_max 8192
setguc pg_logtap.export_url "http://127.0.0.1:1"; reload; sleep 1
D0=$(statf events_dropped) # ring may legally overflow while the worker
# gzip-parks the burst — those events close the universe in dropped, not lost
gen cap1 150000; sleep 8 # storm parks >2MB of members; compaction must fire
sz=$(docker exec "$PG_CT" stat -c %s "$FB_DIR/$FB_REL2" 2>/dev/null || echo 0)
[ "$sz" -le 1500000 ] || fail "fallback_max_mb: queue file $sz bytes with a 1MB cap"
L=$(statf events_lost)
[ "$L" -ge 1 ] 2>/dev/null || fail "fallback_max_mb: compaction did not count lost events (lost=$L)"
C=$(statf events_compacted)
[ "$C" -ge 1 ] 2>/dev/null || fail "fallback_max_mb: compaction did not count compacted events (compacted=$C)"
# delivered must EXCLUDE cap-dropped events: they were never handed to any
# receiver (the pre-T5 bug counted them as replayed → delivered lied)
DV=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT delivered - events_sent - events_replayed FROM pg_logtap_delivery")
[ "$DV" = 0 ] 2>/dev/null || fail "fallback_max_mb: delivered ≠ sent + replayed ($DV)"
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.fallback_max_mb 512
setguc pg_logtap.export_backlog_max 65536; reload
n=0; while [ "$n" -lt 30 ]; do
  sleep 1; n=$((n + 1))
  backlog=$(( $(statf events_queued) - $(statf events_replayed) - $(statf events_compacted) ))
  [ "$(received cap1)" -gt 0 ] && [ "$backlog" -le 0 ] && break
done
R=$(received cap1)
# "Newest tail" is WHICH events survive, not HOW MANY: bytes-per-event is
# compression- and timing-dependent (an arm64 runner parked smaller batches,
# ~21B/event vs amd64's ~15B — 25k survived where ~68k were "expected"; the
# contract held, the count did not). Assert the property instead: the oldest
# of the last 1000 delivered is exactly 149000 — a hole inside the tail or an
# undelivered final event pulls it lower, and so does a delivery count under
# 1000. Even with zero compression the 512KB newest slice holds ~5k of these
# events, so 1000 never clips legitimate survivors.
last1k=$(grep -oE "logtap kill cap1$SUF [0-9]+" "$OUT/vector-out.jsonl" \
  | grep -oE '[0-9]+$' | sort -n | tail -n 1000 | head -n 1)
[ "$last1k" = 149000 ] || fail "fallback_max_mb: newest tail broken — oldest of the last 1000 delivered is $last1k (want 149000, delivered=$R)"
dups=$(grep "logtap kill cap1$SUF" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$dups" = 0 ] || fail "fallback_max_mb: $dups duplicate seqs — compaction replayed delivered members"
D=$(( $(statf events_dropped) - D0 ))
[ "$((R + L + D))" -ge 140000 ] || fail "fallback_max_mb: delivered($R) + lost($L) + dropped($D) < 140000 of 150000"
ok "1MB cap held the file at ${sz}B, newest tail delivered ($R), loss counted ($L), compacted=$C excluded from delivered, ring-dropped ($D), dup=0"

setguc pg_logtap.export_url ''; setguc pg_logtap.export_fallback_file ''
setguc pg_logtap.fallback_max_mb 512
setguc pg_logtap.export_timeout_ms 5000; reload
echo "e2e-kill: all scenarios passed"
