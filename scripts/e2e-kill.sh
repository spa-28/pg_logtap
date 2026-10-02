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
#   torn-queue-tail    : a partial frame header or a header claiming more body
#                        bytes than the file holds is cut at the member boundary;
#                        appends resume there and replay stays on
#   legacy-queue       : clean PGLTFB01 frames replay and accept later v1
#                        appends; an unreadable v1 frame breaks rather than
#                        publishing a fabricated event count
#   corrupt-member     : a damaged counted member (framing intact) is skipped
#                        by its exact event count; later members still replay
#   count-metadata     : readable NDJSON outranks a damaged v2 event_count in
#                        replay and cap-compaction accounting
#   soft-worker-restart: the shmem replay cursor prevents re-skip/replay drift
#                        while the postmaster and its counters stay alive
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
#   private-files      : regular/euid/single-link checked before chmod or IO;
#                        worker-owned files tightened to 0600, insecure targets
#                        untouched, refused events recover via queue/RAM retry
#   fallback-reload    : same-path HUP repairs broken; unread active A survives
#                        configured B/disable and soft replacement; repeat HUP
#                        adopts B only after A drains, credits existing B once
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

echo "== transport configuration boundaries =="
host255=$(python3 -c 'print("h" * 255)')
host256=$(python3 -c 'print("h" * 256)')
url255="http://$host255:8686"
url256="http://$host256:8686"
baseline_url="http://$VEC:8686"
setguc pg_logtap.export_http_content_type 'application/x-ndjson'
setguc pg_logtap.export_http_extra_headers ''
setguc pg_logtap.export_url "$baseline_url"; reload; sleep 1
setguc pg_logtap.export_url "$url255" \
  || fail "transport validation: 255-byte host was rejected"
# Do not reload the deliberately unresolvable boundary hostname; overwrite its
# pending auto.conf value with the working receiver first.
setguc pg_logtap.export_url "$baseline_url"
if setguc pg_logtap.export_url "$url256" 2>/dev/null; then
  fail "transport validation: 256-byte host was accepted"
fi
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_url")" = "$baseline_url" ] \
  || fail "transport validation: rejected host replaced the active URL"

keep_header='X-Keep: yes'
long_path="/$(python3 -c 'print("p" * 1600)')"
wide_type=$(python3 -c 'print("a" * 256)')
mid_header="X-Fill: $(python3 -c 'print("a" * 250)')"
wide_header="X-Fill: $(python3 -c 'print("a" * 292)')"
setguc pg_logtap.export_http_extra_headers "$keep_header"
setguc pg_logtap.export_url "$baseline_url$long_path"
setguc pg_logtap.export_http_content_type "$wide_type"
reload; sleep 1
if setguc pg_logtap.export_http_extra_headers "$wide_header" 2>/dev/null; then
  fail "transport validation: HTTP head larger than 2048 bytes was accepted"
fi
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_url")" = "$baseline_url$long_path" ] \
  || fail "transport validation: rejected head changed export_url"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_http_content_type")" = "$wide_type" ] \
  || fail "transport validation: rejected head changed content type"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_http_extra_headers")" = "$keep_header" ] \
  || fail "transport validation: rejected head changed extra headers"

# Exercise the same aggregate-head guard through each candidate callback, not
# only through export_http_extra_headers.
setguc pg_logtap.export_url "$baseline_url" \
  || fail "transport validation: could not stage URL candidate baseline"
reload
setguc pg_logtap.export_http_content_type "$wide_type" \
  || fail "transport validation: could not stage wide content type"
setguc pg_logtap.export_http_extra_headers "$wide_header" \
  || fail "transport validation: could not stage wide extra header"
reload; sleep 1
if setguc pg_logtap.export_url "$baseline_url$long_path" 2>/dev/null; then
  fail "transport validation: URL candidate made the HTTP head exceed 2048 bytes"
fi
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_url")" = "$baseline_url" ] \
  || fail "transport validation: rejected URL candidate replaced the active URL"

setguc pg_logtap.export_http_content_type 'application/x-ndjson' \
  || fail "transport validation: could not stage content-type baseline"
setguc pg_logtap.export_http_extra_headers '' \
  || fail "transport validation: could not clear extra headers"
reload
setguc pg_logtap.export_url "$baseline_url$long_path" \
  || fail "transport validation: could not stage long URL"
reload
setguc pg_logtap.export_http_extra_headers "$mid_header" \
  || fail "transport validation: could not stage medium extra header"
reload; sleep 1
if setguc pg_logtap.export_http_content_type "$wide_type" 2>/dev/null; then
  fail "transport validation: content-type candidate made the HTTP head exceed 2048 bytes"
fi
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_http_content_type")" = 'application/x-ndjson' ] \
  || fail "transport validation: rejected content type replaced the active value"

setguc pg_logtap.export_url "$baseline_url"
setguc pg_logtap.export_http_content_type 'application/x-ndjson'
setguc pg_logtap.export_http_extra_headers ''; reload; sleep 1
ok "255-byte host and near-cap head accepted; oversized host and URL/header/content-type tuples rejected"

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
dups=$(grep -E "logtap kill (outage1|outage3|outage4)$SUF [0-9]+" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
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
write_v1_queue() { # write_v1_queue <full marker text> <partial-header bytes>
  python3 - "$1" "$2" <<'PY' | docker exec -i -u postgres "$PG_CT" sh -c "cat > '$FB'"
import gzip, json, struct, sys
body = (json.dumps({"seq": 1, "message": sys.argv[1]}, separators=(",", ":")) + "\n").encode()
compressed = gzip.compress(body, mtime=0)
sys.stdout.buffer.write(b"PGLTFB01" + struct.pack("<I", len(compressed)) + compressed + b"\0" * int(sys.argv[2]))
PY
}
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
gen queue1 2600; sleep 3 # >10 members at chunk_max=256: multi-member replay
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
docker exec "$PG_CT" head -c 8 "$FB" | grep -q PGLTFB02 || fail "fallback queue: no counted queue magic in $FB"
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

echo "== torn queue body: crash mid-append =="
# Counted magic, a complete [len,count] header claiming 1000 body bytes, then
# only 100. The boot scan cuts at the frame boundary; a later append must land
# there rather than behind the stale body.
corr0=$(statf fallback_broken)
docker exec -u postgres "$PG_CT" sh -c "printf 'PGLTFB02' > '$FB'; printf '\350\003\000\000\001\000\000\000' >> '$FB'; head -c 100 /dev/zero >> '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
sleep 2
gen torn1 20; sleep 3
sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$sz" -gt 16 ] || fail "torn queue body: nothing appended after the cut (size $sz)"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for torn1 20
[ "$(received torn1)" = 20 ] || fail "torn queue body: replay broken (torn1=$(received torn1)/20)"
[ "$(statf fallback_broken)" = "$corr0" ] || fail "torn queue body: misparsed as corrupt instead of cut (fallback_broken=$(statf fallback_broken))"
ok "torn counted body cut at the frame boundary, appends resumed, 20/20 replayed"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2


echo "== legacy queue: partial 1/2/3-byte frame headers are repaired =="
# Each file has one clean v1 frame plus a partial next length. The boot-time
# credit scan must repair the tail before any new event exists; the old frame
# then stays readable and a new failed-send batch appends in v1 without mixing
# formats. This is also the clean PGLTFB01 compatibility check.
tail_n=1
while [ "$tail_n" -le 3 ]; do
  docker exec "$PG_CT" sh -c "rm -f '$FB'"
  write_v1_queue "logtap $E2E_TAG v1tail$tail_n$E2E_SUF 0" "$tail_n" || fail "legacy partial header $tail_n: could not write fixture"
  with_tail=$(docker exec "$PG_CT" stat -c %s "$FB")
  clean=$((with_tail - tail_n))
  setguc pg_logtap.export_url "http://127.0.0.1:1"
  setguc pg_logtap.export_fallback_file "$FB_REL"
  # Do not reload into the old worker: a real crash tail is first seen by the
  # restarted worker's boot scan, before its startup events can append.
  docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
  sleep 2
  # Startup itself emits capturable lines, so after boot the repaired file may
  # already have valid appends behind the fixture. Walk every v1 frame: leaving
  # the stale 1..3 bytes would shift the next header/payload and fail this.
  repaired=$(docker exec "$PG_CT" stat -c %s "$FB")
  [ "$repaired" -ge "$clean" ] || fail "legacy partial header $tail_n: repair cut into the valid frame"
  off=8
  while [ "$off" -lt "$repaired" ]; do
    len=$(docker exec "$PG_CT" od -An -tu4 -j"$off" -N4 "$FB" | tr -d ' \n')
    [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null || fail "legacy partial header $tail_n: bad frame length at $off"
    end=$((off + 4 + len)); [ "$end" -le "$repaired" ] || fail "legacy partial header $tail_n: torn frame after boot"
    docker exec "$PG_CT" sh -c "dd if='$FB' bs=1 skip=$((off + 4)) count=$len 2>/dev/null | gzip -t" \
      || fail "legacy partial header $tail_n: stale prefix shifted the appended gzip payload"
    off=$end
  done
  [ "$off" = "$repaired" ] || fail "legacy partial header $tail_n: frame walk ended at $off, size $repaired"
  gen "v1new$tail_n" 10; sleep 3
  docker exec "$PG_CT" head -c 8 "$FB" | grep -q PGLTFB01 \
    || fail "legacy partial header $tail_n: append mixed/replaced the v1 format"
  [ "$(docker exec "$PG_CT" stat -c %s "$FB")" -gt "$repaired" ] \
    || fail "legacy partial header $tail_n: no frame appended after repair"
  setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
  wait_for "v1tail$tail_n" 1; wait_for "v1new$tail_n" 10
  [ "$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)" = 0 ] \
    || fail "legacy partial header $tail_n: queue not truncated after replay"
  [ "$(statf fallback_broken)" = 0 ] || fail "legacy partial header $tail_n: queue marked broken"
  setguc pg_logtap.export_fallback_file ''; reload; sleep 1
  tail_n=$((tail_n + 1))
done
ok "all partial v1 headers repaired before append; clean v1 frames and later v1 appends replayed"


echo "== legacy corrupt member: stop instead of inventing a count =="
docker exec "$PG_CT" sh -c "rm -f '$FB'"
write_v1_queue "logtap $E2E_TAG v1bad$E2E_SUF 0" 0 || fail "legacy corrupt member: could not write fixture"
docker exec "$PG_CT" sh -c "dd if=/dev/zero of='$FB' bs=1 seek=12 count=16 conv=notrunc" >/dev/null 2>&1
setguc pg_logtap.export_fallback_file "$FB_REL"; reload
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
sleep 2
[ "$(statf fallback_broken)" = 1 ] || fail "legacy corrupt member: unreadable v1 frame did not break the queue"
[ "$(statf events_lost)" = 0 ] || fail "legacy corrupt member: fabricated events_lost=$(statf events_lost)"
[ "$(statf warn_fallback_skipped)" = 0 ] || fail "legacy corrupt member: claimed an unknown-count frame was skipped"
[ "$(docker exec "$PG_CT" stat -c %s "$FB")" -gt 12 ] || fail "legacy corrupt member: frame was removed"
# This synthetic unknowable-count fixture is deliberately discarded. Disable
# cannot bypass unread/broken A; the full postmaster reset below is a manual
# test cleanup boundary, not a guarantee of discovering old configured paths.
setguc pg_logtap.export_fallback_file ''; reload; sleep 1
docker exec "$PG_CT" sh -c "rm -f '$FB'"
docker restart "$PG_CT" >/dev/null; wait_ready
ok "unreadable v1 frame left in place, fallback_broken=1, no fabricated loss count"


echo "== counted metadata mismatch: readable payload is authoritative =="
docker exec "$PG_CT" sh -c "rm -f '$FB'"
python3 - "$E2E_TAG" "$SUF" <<'PY' | docker exec -i -u postgres "$PG_CT" sh -c "cat > '$FB'"
import gzip, json, struct, sys

tag, suffix = sys.argv[1:]
out = bytearray(b"PGLTFB02")
for frame, stored in enumerate((0, 257, 9)):
    body = b"".join(
        (json.dumps({"seq": 700000 + frame * 10 + i, "message": f"logtap {tag} countmeta{suffix} {frame * 10 + i}"}, separators=(",", ":")) + "\n").encode()
        for i in range(10)
    )
    compressed = gzip.compress(body, mtime=0)
    out += struct.pack("<II", len(compressed), stored) + compressed
sys.stdout.buffer.write(out)
PY
setguc pg_logtap.level_min 23
setguc pg_logtap.export_url "http://$VEC:8686"
setguc pg_logtap.export_fallback_file "$FB_REL"
docker restart "$PG_CT" >/dev/null; wait_ready
wait_for countmeta 30
[ "$(statf events_lost)" = 0 ] || fail "count metadata: readable payloads counted lost ($(statf events_lost))"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 0 ] \
  || fail "count metadata: backlog did not drain"
[ "$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)" = 0 ] \
  || fail "count metadata: queue not truncated after readable mismatch"
setguc pg_logtap.export_fallback_file ''; setguc pg_logtap.level_min 15; reload; sleep 1
ok "stored counts 0/257/9 vs 10 readable lines each: replayed 30, lost=0, backlog=0"


echo "== counted metadata mismatch: compaction counts readable lines =="
docker exec "$PG_CT" sh -c "rm -f '$FB'"
python3 - "$E2E_TAG" "$SUF" <<'PY' | docker exec -i -u postgres "$PG_CT" sh -c "cat > '$FB'"
import base64, gzip, json, random, struct, sys

tag, suffix = sys.argv[1:]
out = bytearray(b"PGLTFB02")
for frame in range(4):
    pad = base64.b64encode(random.Random(8100 + frame).randbytes(600000)).decode()
    lines = []
    for i in range(10):
        row = {"seq": 710000 + frame * 10 + i, "message": f"logtap {tag} compactmeta{suffix} {frame * 10 + i}"}
        if i == 0:
            row["pad"] = pad
        lines.append(json.dumps(row, separators=(",", ":")) + "\n")
    compressed = gzip.compress("".join(lines).encode(), mtime=0)
    out += struct.pack("<II", len(compressed), 9 if frame == 0 else 10) + compressed
sys.stdout.buffer.write(out)
PY
fixture_size=$(docker exec "$PG_CT" stat -c %s "$FB")
[ "$fixture_size" -gt 2000000 ] || fail "count metadata compaction: fixture only ${fixture_size}B"
setguc pg_logtap.level_min 23
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"
setguc pg_logtap.fallback_max_mb 1
docker restart "$PG_CT" >/dev/null; wait_ready; sleep 2
setguc pg_logtap.level_min 15; reload; sleep 1
gen compacttrigger 1
n=0; while [ "$n" -lt 20 ] && [ "$(statf events_compacted)" -eq 0 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(statf events_compacted)" = 30 ] \
  || fail "count metadata compaction: compacted=$(statf events_compacted), want 30 readable events (not stored 29)"
[ "$(statf events_lost)" = 30 ] \
  || fail "count metadata compaction: lost=$(statf events_lost), want 30"
# Dispose of the remaining synthetic oversized fixture at the next testcase's
# full postmaster reset. An unread active queue cannot be disabled by reload;
# this manual fixture cleanup is not a delivery/reconfiguration guarantee.
setguc pg_logtap.level_min 23
setguc pg_logtap.export_fallback_file ''; setguc pg_logtap.fallback_max_mb 512; reload; sleep 1
docker exec "$PG_CT" sh -c "rm -f '$FB'"
ok "cap trim used readable line counts: compacted=lost=30, not corrupt stored total 29"


# This cursor test deliberately waits 30s between bounded replays. Scrapes
# are served at cycle boundaries, not by a separate listener/latch, so allow
# one full interval. Scrape only with a dead receiver or an empty queue:
# waking the worker or waiting on a live unread queue can advance its cursor.
prom_backlog() {
  docker exec "$PG_CT" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9187; printf "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3; timeout 35 cat <&3' \
    | tr -d '\r' | awk '$1 == "pg_logtap_queue_backlog" { print $2 }'
}

echo "== soft worker restart: replay cursor survives in shmem =="
setguc pg_logtap.metrics_port 9187
python3 - "$E2E_TAG" "$SUF" <<'PY' | docker exec -i -u postgres "$PG_CT" sh -c "cat > '$FB'"
import gzip, json, struct, sys

tag, suffix = sys.argv[1:]
out = bytearray(b"PGLTFB02")
bad = b"not-a-gzip-member-not-a-gzip-member"
out += struct.pack("<II", len(bad), 10) + bad
for i in range(70):
    body = (json.dumps({"seq": 720000 + i, "message": f"logtap {tag} cursor{suffix} {i}"}, separators=(",", ":")) + "\n").encode()
    compressed = gzip.compress(body, mtime=0)
    out += struct.pack("<II", len(compressed), 1) + compressed
sys.stdout.buffer.write(out)
PY
setguc pg_logtap.level_min 23
setguc pg_logtap.flush_interval 30000
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"
docker restart "$PG_CT" >/dev/null; wait_ready
n=0; while [ "$n" -lt 20 ] && [ "$(statf events_lost)" -lt 10 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(statf events_lost)" = 10 ] || fail "soft cursor: initial corrupt frame loss=$(statf events_lost), want 10"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 70 ] \
  || fail "soft cursor: initial backlog not 70"
[ "$(prom_backlog)" = 70 ] || fail "soft cursor: Prometheus backlog differs from SQL 70 after counted-member skip"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
n=0; while [ "$n" -lt 20 ] && [ "$(received cursor)" -lt 64 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(received cursor)" = 64 ] || fail "soft cursor: first bounded replay delivered $(received cursor), want 64"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 6 ] \
  || fail "soft cursor: backlog after first 64 is not 6"
lost_before=$(statf events_lost)
skip_before=$(statf warn_fallback_skipped)
failed_before=$(statf send_cycles_failed)
setguc pg_logtap.export_url "http://127.0.0.1:1"; reload
n=0; while [ "$n" -lt 20 ] && [ "$(statf send_cycles_failed)" -le "$failed_before" ]; do
  n=$((n + 1)); sleep 1
done
# Receiver is now dead, so waiting for the next scrape cycle cannot drain the
# six unread frames we need to carry across TERM. SQL still pins that cursor.
[ "$(statf send_cycles_failed)" -gt "$failed_before" ] \
  && [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 6 ] \
  || fail "soft cursor: dead-URL barrier did not preserve backlog 6"
[ "$(prom_backlog)" = 6 ] || fail "soft cursor: Prometheus backlog differs from SQL 6 after bounded replay"
wpid=$(worker_pid)
[ -n "$wpid" ] || fail "soft cursor: worker not found"
docker exec "$PG_CT" kill -TERM "$wpid"
n=0; new_wpid=$wpid
while [ "$n" -lt 20 ] && { [ -z "$new_wpid" ] || [ "$new_wpid" = "$wpid" ]; }; do
  n=$((n + 1)); sleep 1; new_wpid=$(worker_pid)
done
[ -n "$new_wpid" ] && [ "$new_wpid" != "$wpid" ] || fail "soft cursor: worker did not restart"
sleep 2
[ "$(statf events_lost)" = "$lost_before" ] \
  || fail "soft cursor: corrupt frame counted lost again ($(statf events_lost) vs $lost_before)"
[ "$(statf warn_fallback_skipped)" = "$skip_before" ] \
  || fail "soft cursor: replacement worker rescanned the corrupt prefix"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 6 ] \
  || fail "soft cursor: replacement worker drifted backlog from 6"
[ "$(prom_backlog)" = 6 ] || fail "soft cursor: replacement worker's Prometheus backlog differs from SQL 6"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for cursor 70 "" 40
cursor_dups=$(seqs_of cursor | sort -n | uniq -d | wc -l)
[ "$cursor_dups" = 0 ] || fail "soft cursor: replay resent $cursor_dups already-delivered events"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 0 ] \
  || fail "soft cursor: final backlog did not reach 0"
[ "$(prom_backlog)" = 0 ] || fail "soft cursor: Prometheus backlog differs from SQL 0 after drain"
[ "$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)" = 0 ] \
  || fail "soft cursor: queue not truncated after final replay"
setguc pg_logtap.export_fallback_file ''; setguc pg_logtap.flush_interval 1000
setguc pg_logtap.level_min 15; reload; sleep 1
ok "soft restart resumed after the published frame boundary: lost stayed 10, backlog 6→0, duplicates=0"


echo "== fallback path reload: active A survives configured B and worker replacement =="
# Shared active-path state is a SOFT worker-replacement contract. Full
# postmaster restart resets it: operators must first drain A or restore
# configured A; old paths require a manual drain, not automatic discovery.
PATH_A="$FB_DIR/logtap-path-a.bin"
PATH_B="$FB_DIR/logtap-path-b.bin"
write_path_queue() { # path, marker, count: private counted fixture, one frame/event
  docker exec "$PG_CT" rm -f "$1"
  python3 - "$E2E_TAG" "$E2E_SUF" "$2" "$3" <<'PY' | docker exec -i -u postgres "$PG_CT" sh -c "umask 077; cat > '$1'"
import gzip, json, struct, sys

tag, suffix, marker, count = sys.argv[1:]
base = {"pathA": 730000, "pathB": 740000, "pathDisable": 750000}[marker]
out = bytearray(b"PGLTFB02")
for i in range(int(count)):
    body = (json.dumps({"seq": base + i, "message": f"logtap {tag} {marker}{suffix} {i}"}, separators=(",", ":")) + "\n").encode()
    compressed = gzip.compress(body, mtime=0)
    out += struct.pack("<II", len(compressed), 1) + compressed
sys.stdout.buffer.write(out)
PY
}
# ERROR-only capture suppresses reload/worker boot noise so B's existing
# backlog credit can be checked exactly without resetting shmem/counters.
setguc pg_logtap.level_min 23
setguc pg_logtap.flush_interval 30000
setguc pg_logtap.export_url 'http://127.0.0.1:1'; reload; sleep 1
write_path_queue "$PATH_A" pathA 3 || fail "path reload: could not write A"
write_path_queue "$PATH_B" pathB 5 || fail "path reload: could not write B"
q0=$(statf events_queued); lost0=$(statf events_lost)
before_a=$(docker exec "$PG_CT" sha256sum "$PATH_A")
before_b=$(docker exec "$PG_CT" sha256sum "$PATH_B")
setguc pg_logtap.export_fallback_file "$PATH_A"; reload; sleep 2
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 3 ] \
  && [ "$(statf events_queued)" = "$((q0 + 3))" ] \
  || fail "path reload: A's existing backlog not credited exactly once"
setguc pg_logtap.export_fallback_file "$PATH_B"; reload; sleep 2
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SHOW pg_logtap.export_fallback_file')" = "$PATH_B" ] \
  || fail "path reload: B request did not land in configured GUC"
[ "$(docker exec "$PG_CT" sha256sum "$PATH_A")" = "$before_a" ] \
  && [ "$(docker exec "$PG_CT" sha256sum "$PATH_B")" = "$before_b" ] \
  && [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 3 ] \
  && [ "$(statf events_queued)" = "$((q0 + 3))" ] \
  || fail "path reload: requesting B orphaned A, touched B, or drifted accounting"
postmaster0=$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT pg_postmaster_start_time()')
wpid=$(worker_pid); [ -n "$wpid" ] || fail "path reload: worker not found"
docker exec "$PG_CT" kill -TERM "$wpid"
n=0; new_wpid=$wpid
while [ "$n" -lt 20 ] && { [ -z "$new_wpid" ] || [ "$new_wpid" = "$wpid" ]; }; do
  n=$((n + 1)); sleep 1; new_wpid=$(worker_pid)
done
[ -n "$new_wpid" ] && [ "$new_wpid" != "$wpid" ] || fail "path reload: worker did not restart"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT pg_postmaster_start_time()')" = "$postmaster0" ] \
  || fail "path reload: cluster restarted instead of replacing worker"
sleep 2
[ "$(docker exec "$PG_CT" sha256sum "$PATH_B")" = "$before_b" ] \
  && [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 3 ] \
  && [ "$(statf events_queued)" = "$((q0 + 3))" ] \
  || fail "path reload: replacement adopted configured B instead of shared active A"
# This HUP still sees unread A; it changes the receiver but must not activate B.
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for pathA 3
sleep 1
[ "$(received pathB)" = 0 ] && [ "$(docker exec "$PG_CT" sha256sum "$PATH_B")" = "$before_b" ] \
  && [ "$(docker exec "$PG_CT" stat -c %s "$PATH_A")" = 0 ] \
  && [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 0 ] \
  || fail "path reload: A did not drain alone; B auto-activated without repeat HUP"
# A is now proven empty. Repeat HUP adopts B and reuses boot credit; hold
# receiver dead for the exact five-event SQL backlog assertion before drain.
setguc pg_logtap.export_url 'http://127.0.0.1:1'; reload; sleep 2
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 5 ] \
  && [ "$(statf events_queued)" = "$((q0 + 8))" ] \
  || fail "path reload: existing B backlog not credited once on adoption"
reload; sleep 1
[ "$(statf events_queued)" = "$((q0 + 8))" ] || fail "path reload: same-path B reload double-credited existing events"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for pathB 5
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 0 ] \
  && [ "$(docker exec "$PG_CT" stat -c %s "$PATH_B")" = 0 ] \
  && [ "$(statf events_lost)" = "$lost0" ] \
  || fail "path reload: B did not drain/account losslessly"
python3 - "$OUT/vector-out.jsonl" "$E2E_TAG" "$E2E_SUF" <<'PY' || fail "path reload: markers were missing, duplicated, or delivered out of A/B order"
import json, sys

path, tag, suffix = sys.argv[1:]
got = []
for line in open(path, encoding="utf-8"):
    message = json.loads(line).get("message", "")
    for marker in ("pathA", "pathB"):
        prefix = f"logtap {tag} {marker}{suffix} "
        if message.startswith(prefix):
            got.append((marker, int(message[len(prefix):])))
assert got == [("pathA", i) for i in range(3)] + [("pathB", i) for i in range(5)], got
PY
ok "configured B/soft replacement retained active A; A then B delivered in order, B credit=5 once, backlog=0"

echo "== fallback disable/B while A is broken: refusal is not proof of empty =="
setguc pg_logtap.export_fallback_file ''; reload; sleep 1
write_path_queue "$PATH_A" pathDisable 3 || fail "path disable: could not write A"
setguc pg_logtap.export_url 'http://127.0.0.1:1'
q0=$(statf events_queued)
setguc pg_logtap.export_fallback_file "$PATH_A"; reload; sleep 2
[ "$(statf events_queued)" = "$((q0 + 3))" ] || fail "path disable: A fixture not credited"
a_hash=$(docker exec "$PG_CT" sha256sum "$PATH_A")
# Keep the unread contents, but force secure reopen to fail. No fchmod may
# touch the foreign-owned inode, and neither requested B nor '' may bypass it.
docker exec "$PG_CT" sh -c "chown root '$PATH_A'; chmod 0666 '$PATH_A'"
reload; sleep 1
[ "$(statf fallback_broken)" = 1 ] || fail "path disable: insecure A did not latch broken"
for requested in "$PATH_B" ''; do
  setguc pg_logtap.export_fallback_file "$requested"; reload; sleep 1
  [ "$(statf fallback_broken)" = 1 ] \
    && [ "$(docker exec "$PG_CT" sha256sum "$PATH_A")" = "$a_hash" ] \
    && [ "$(docker exec "$PG_CT" stat -c '%u:%a' "$PATH_A")" = '0:666' ] \
    && [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 3 ] \
    && [ "$(statf events_queued)" = "$((q0 + 3))" ] \
    || fail "path disable: requested '$requested' hid/replaced broken unread A"
done
# Restore configured A before repair so this is an unambiguous same-path HUP.
setguc pg_logtap.export_fallback_file "$PATH_A"
docker exec "$PG_CT" sh -c "chown postgres '$PATH_A'; chmod 0600 '$PATH_A'"
reload; sleep 1
[ "$(statf fallback_broken)" = 0 ] && [ "$(statf events_queued)" = "$((q0 + 3))" ] \
  || fail "path disable: repaired A did not reopen or was double-credited"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for pathDisable 3
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 0 ] \
  && [ "$(docker exec "$PG_CT" stat -c %s "$PATH_A")" = 0 ] \
  && [ "$(seqs_of pathDisable | sort | uniq -d | wc -l)" = 0 ] \
  || fail "path disable: repaired A did not drain once"
# Disable only after proven drain; dead receiver traffic must now stay in RAM,
# not revive A. This is another explicit request, not a pending-switch loop.
setguc pg_logtap.export_fallback_file ''
setguc pg_logtap.export_url 'http://127.0.0.1:1'
setguc pg_logtap.flush_interval 1000; setguc pg_logtap.level_min 15; reload; sleep 1
q0=$(statf events_queued)
gen pathDisabledRam 10; sleep 2
[ "$(statf events_queued)" = "$q0" ] && [ "$(docker exec "$PG_CT" stat -c %s "$PATH_A")" = 0 ] \
  || fail "path disable: repeat HUP after drain did not disable A"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for pathDisabledRam 10
docker exec "$PG_CT" rm -f "$PATH_A" "$PATH_B"
ok "broken unread A survived B/disable requests; same-path repair drained it once, repeat HUP then disabled queue"

echo "== corrupt member mid-queue: skipped, later members still replay =="
# A/CORRUPT/B/C: park four marker batches with the receiver dead, smash
# every member holding cmX (gzip payload, counted framing intact), restart,
# revive the receiver. The walk must skip the exact event_count stored in each
# damaged frame, credit and replay the rest, and leave no phantom backlog.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen cmA 10; sleep 1; gen cmX 10; sleep 1; gen cmB 10; sleep 1; gen cmC 10; sleep 2
# Find EVERY member holding cmX by walking [compressed_len,event_count,gzip]
# and inflating each candidate. A flush boundary may split one gen across
# frames, so the expected loss is the sum of their stored counts, not the
# number of frames.
sz=$(docker exec "$PG_CT" stat -c %s "$FB")
off=8; hits=""; nhits=0; lost_want=0
while [ "$off" -lt "$sz" ]; do
  len=$(docker exec "$PG_CT" od -An -tu4 -j"$off" -N4 "$FB" | tr -d ' \n')
  count=$(docker exec "$PG_CT" od -An -tu4 -j$((off + 4)) -N4 "$FB" | tr -d ' \n')
  [ -n "$len" ] && [ "$len" -gt 0 ] && [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null \
    || fail "corrupt member: framing unreadable at $off (len='$len' count='$count')"
  end=$((off + 8 + len)); [ "$end" -le "$sz" ] || fail "corrupt member: torn member at $off (end=$end sz=$sz)"
  body=$(docker exec "$PG_CT" sh -c "dd if='$FB' bs=1 skip=$((off + 8)) count=$len 2>/dev/null | gzip -dc" 2>/dev/null)
  case "$body" in
    *"logtap kill cmX"*)
      echo "$body" | grep -qE "logtap kill cm[ABC]" \
        && fail "corrupt member: cmX shares its member with A/B/C (flush stall merged the gens) — rerun the scenario"
      hits="$hits $off"; nhits=$((nhits + 1)); lost_want=$((lost_want + count)) ;;
  esac
  off=$end
done
[ "$nhits" -ge 1 ] || fail "corrupt member: no cmX member found in the queue"
for h in $hits; do
  docker exec "$PG_CT" sh -c "dd if=/dev/zero of='$FB' bs=1 seek=$((h + 8)) count=16 conv=notrunc" >/dev/null 2>&1
done
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for cmA 10; wait_for cmB 10; wait_for cmC 10
[ "$(received cmA)" = 10 ] && [ "$(received cmB)" = 10 ] && [ "$(received cmC)" = 10 ] \
  || fail "corrupt member: intact members not replayed (cmA=$(received cmA) cmB=$(received cmB) cmC=$(received cmC))"
[ "$(received cmX)" = 0 ] || fail "corrupt member: damaged member delivered $(received cmX) events"
# Fresh shmem at the restart: exact stored counts are the only losses.
[ "$(statf events_lost)" = "$lost_want" ] \
  || fail "corrupt member: events_lost=$(statf events_lost), want stored count $lost_want"
skip=$(statf warn_fallback_skipped)
# Three observations per frame here: boot credit scan, explicit same-path
# reload credit scan, then the real drain. Only the drain accounts the loss.
[ "$skip" = $((3 * nhits)) ] || fail "corrupt member: 'unreadable, skipped' fired $skip times, want $((3 * nhits))"
[ "$(statf fallback_broken)" = 0 ] || fail "corrupt member: damaged payload escalated to a framing error"
backlog=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$backlog" = 0 ] || fail "corrupt member: queue_backlog=$backlog after physical drain"
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$fb_sz" = 0 ] || fail "corrupt member: queue not truncated after replay ($fb_sz bytes left)"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "$nhits damaged frame(s) skipped by exact count ($lost_want), backlog=0, A/B/C replayed 30/30"

echo "== decompression-bomb member: inflate bounded, member skipped not inflated =="
# A final member whose compressed length passes the framing bound but inflates
# far past member_max: the fixed buffer is the ceiling. Keeping the bomb last
# also exercises the drain-only cleanup of a skipped final frame.
docker exec "$PG_CT" sh -c "rm -f '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
gen bombA 10; sleep 1; gen bombX 10; sleep 2
# The bomb: 512MB of zeros gzip-9s to well under the ~5.2MB framing bound
# and inflates a hundredfold past it. Built in-container — dd and gzip are
# the same tools the walk above uses.
docker exec "$PG_CT" sh -c "dd if=/dev/zero bs=1048576 count=512 2>/dev/null | gzip -9 -c > /tmp/bomb.gz"
blen=$(docker exec "$PG_CT" stat -c %s /tmp/bomb.gz)
[ "$blen" -lt 5000000 ] 2>/dev/null || fail "bomb member: compressed $blen not under the framing bound — scenario broken"
# Replace every bombX payload while retaining its stored event_count.
sz=$(docker exec "$PG_CT" stat -c %s "$FB")
off=8; segs=""; nb=0; bomb_lost=0; bomb_end=0
while [ "$off" -lt "$sz" ]; do
  len=$(docker exec "$PG_CT" od -An -tu4 -j"$off" -N4 "$FB" | tr -d ' \n')
  count=$(docker exec "$PG_CT" od -An -tu4 -j$((off + 4)) -N4 "$FB" | tr -d ' \n')
  [ -n "$len" ] && [ "$len" -gt 0 ] && [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null \
    || fail "bomb member: framing unreadable at $off (len='$len' count='$count')"
  end=$((off + 8 + len)); [ "$end" -le "$sz" ] || fail "bomb member: torn member at $off (end=$end sz=$sz)"
  body=$(docker exec "$PG_CT" sh -c "dd if='$FB' bs=1 skip=$((off + 8)) count=$len 2>/dev/null | gzip -dc" 2>/dev/null)
  case "$body" in
    *"logtap kill bombX"*)
      echo "$body" | grep -q "logtap kill bombA" \
        && fail "bomb member: bombX shares its frame with bombA — rerun the scenario"
      segs="$segs $off:$end"; nb=$((nb + 1)); bomb_lost=$((bomb_lost + count)); bomb_end=$end ;;
  esac
  off=$end
done
[ "$nb" -ge 1 ] || fail "bomb member: no bombX member found in the queue"
[ "$bomb_end" = "$sz" ] || fail "bomb member: bombX is not the final frame (end=$bomb_end size=$sz)"
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
    dd if='$FB' bs=1 skip=\$((o + 4)) count=4 2>/dev/null >> /tmp/fb.new
    cat /tmp/bomb.gz >> /tmp/fb.new
    prev=\$e
  done
  tail -c +\$((prev + 1)) '$FB' >> /tmp/fb.new
  chown postgres /tmp/fb.new; chmod 0600 /tmp/fb.new
  mv /tmp/fb.new '$FB'; rm -f /tmp/bomb.gz
"
docker kill "$PG_CT" >/dev/null; docker start "$PG_CT" >/dev/null; wait_ready
sleep 2 # the boot queue walk hits the bomb here — this is the bounded-inflate moment
hwm=$(docker exec "$PG_CT" cat "/proc/$(worker_pid)/status" 2>/dev/null | awk '/^VmHWM/{print $2}')
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for bombA 10
[ "$(received bombA)" = 10 ] || fail "bomb member: later members not replayed (bombA=$(received bombA)/10)"
[ "$(received bombX)" = 0 ] || fail "bomb member: bomb content delivered?? (bombX=$(received bombX))"
# Fresh shmem at restart: boot and same-path reload credit scans each observe
# every bomb frame without accounting loss. The real drain accounts the exact
# stored counts once and truncates the file after the skipped final frame.
[ "$(statf events_lost)" = "$bomb_lost" ] \
  || fail "bomb member: events_lost=$(statf events_lost), want stored count $bomb_lost"
[ "$(statf warn_fallback_skipped)" = $((3 * nb)) ] || fail "bomb member: 'unreadable, skipped' fired $(statf warn_fallback_skipped) times, want $((3 * nb))"
[ "$(statf fallback_broken)" = 0 ] || fail "bomb member: overflow escalated to a framing error"
backlog=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$backlog" = 0 ] || fail "bomb member: queue_backlog=$backlog after final-frame skip"
fb_sz=$(docker exec "$PG_CT" stat -c %s "$FB" 2>/dev/null || echo 0)
[ "$fb_sz" = 0 ] || fail "bomb member: skipped final frame did not truncate the queue ($fb_sz bytes left)"
[ -n "$hwm" ] && [ "$hwm" -lt 200000 ] 2>/dev/null \
  || fail "bomb member: worker peak RSS ${hwm:-unreadable}kB — the 512MB bomb was inflated, not bounded"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "$nb final bomb frame(s) skipped by exact count ($bomb_lost), backlog=0, peak RSS ${hwm}kB"

echo "== file:// url == fallback path: the pair is rejected at SET =="
# The NDJSON sink and the fallback queue framing cannot share a file; the
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
# The rejected SET was exported into our NDJSON sink. After deactivating that
# sink, remove it before reusing the pathname for a fresh fallback queue;
# foreign content must not strand the active queue in this SET-hook fixture.
docker exec -u postgres "$PG_CT" rm -f "$al" || fail "aliasing: cannot remove the deactivated test sink"
# the other direction: fallback first (accepted — the url is http), then
# the file:// url naming the same file
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = '$al'" >/dev/null
reload; sleep 2
[ "$(statf fallback_broken)" = 0 ] || fail "aliasing: fresh queue setup left fallback broken"
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

echo "== unparseable network url: rejected at ALTER SYSTEM, not first at send time =="
# checkUrl runs parseUrl: a control byte or a space in the host/path rides
# the HTTP request line verbatim, so it must fail ALTER SYSTEM loudly —
# not land in auto.conf and die in the worker's warnUrlOnce a cycle later.
# (SET cannot reach the hook at all: export_url is PGC_SIGHUP, a session
# SET dies with "cannot be changed now" before any value check runs.)
cr=$(printf '\r'); del=$(printf '\177') # $'..' is not POSIX sh — a dash host would expand it to the PID
for bad in "http://v:8686/a b" "http://v:8686/insert${cr}X-Evil: 1" "http://ba d:8686/" "http://v:8686/p${del}ath"; do
  out=$(docker exec "$PG_CT" psql -U postgres -c "ALTER SYSTEM SET pg_logtap.export_url = '$bad'" 2>&1)
  echo "$out" | grep -q ERROR || fail "bad url: '$bad' accepted at ALTER SYSTEM"
done
# file:// paths are local filenames — spaces stay legal there. No reload
# after: the next scenario's setguc repoints the url anyway.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'file:///tmp/my logs.jsonl'" >/dev/null \
  || fail "bad url: file:// with a space rejected"
# A file:// path past sendFile's 4096-byte buffers is rejected the same way
# (it loaded fine and failed every send silently before).
long="file:///tmp/$(printf '%*s' 4100 '' | tr ' ' a)"
out=$(docker exec "$PG_CT" psql -U postgres -c "ALTER SYSTEM SET pg_logtap.export_url = '$long'" 2>&1)
echo "$out" | grep -q ERROR || fail "bad url: a 4100-byte file:// path accepted at ALTER SYSTEM"
ok "space/DEL/CR/overlong-path urls rejected at ALTER SYSTEM; file:// keeps spaces"

echo "== symlink at the queue path: refused, RAM backlog carries the events =="
# Refuse a final-component queue symlink (parent directories remain trusted).
# Its target stays byte-identical; broken latches until explicit HUP, and the
# RAM backlog delivers all markers once the receiver returns.
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

echo "== pre-existing queue at 0644: tightened to 0600 on open =="
# The 0600 in fbOpen's open(2) applies at creation only. A queue file left
# world-readable by an operator is pulled down to 0600 on the first open —
# the queue holds the whole log stream; other local users must not read it
# (the same stance as creation). Pre-created as postgres so the open
# succeeds and the phase observes the MODE, not EACCES.
FB3_REL=pg_logtap-fallback3.bin
FB3="$FB_DIR/$FB3_REL"
docker exec -u postgres "$PG_CT" sh -c "rm -f '$FB3'; touch '$FB3'; chmod 0644 '$FB3'"
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB3_REL"; reload; sleep 2
q0=$(statf events_queued)
gen perm 20; sleep 3
mode=$(docker exec "$PG_CT" stat -c %a "$FB3")
[ "$mode" = 600 ] || fail "queue perms: mode=$mode after open, want 600"
[ "$(statf events_queued)" -gt "$q0" ] || fail "queue perms: events did not queue through the pre-existing file"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for perm 20
[ "$(received perm)" = 20 ] || fail "queue perms: replay did not drain ($(received perm)/20)"
docker exec "$PG_CT" sh -c "rm -f '$FB3'"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
ok "pre-existing 0644 queue tightened to 0600 on open, 20/20 queued and replayed"

echo "== pre-existing queue at 0666, root-owned: refused before chmod/IO =="
FB4_REL=pg_logtap-fallback4.bin
FB4="$FB_DIR/$FB4_REL"
docker exec "$PG_CT" sh -c "rm -f '$FB4'; printf 'ROOT-QUEUE-CANARY\n' > '$FB4'; chmod 0666 '$FB4'"
q_before=$(docker exec "$PG_CT" sha256sum "$FB4")
q_meta=$(docker exec "$PG_CT" stat -c '%u:%a:%h:%s' "$FB4")
sync0=$(statf fb_sync_failures); lost0=$(statf events_lost)
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB4_REL"; reload; sleep 2
q0=$(statf events_queued)
gen tightq 20; sleep 2
[ "$(docker exec "$PG_CT" sha256sum "$FB4")" = "$q_before" ] \
  && [ "$(docker exec "$PG_CT" stat -c '%u:%a:%h:%s' "$FB4")" = "$q_meta" ] \
  || fail "foreign queue: root-owned contents/owner/mode/link count changed"
[ "$(statf fallback_broken)" = 1 ] && [ "$(statf events_queued)" = "$q0" ] \
  || fail "foreign queue: insecure target accepted or not marked broken"
[ "$(statf fb_sync_failures)" = "$sync0" ] || fail "foreign queue: refusal counted as sync failure"
# Repair in place, then explicitly reopen the same configured path. Neither
# replacing the file alone nor an idle cycle may clear the broken latch.
docker exec "$PG_CT" rm -f "$FB4"
docker exec -u postgres "$PG_CT" sh -c ": > '$FB4'; chmod 0600 '$FB4'"
sleep 1
[ "$(statf fallback_broken)" = 1 ] || fail "foreign queue: repaired without explicit HUP"
reload; sleep 2
[ "$(statf fallback_broken)" = 0 ] && [ "$(statf events_queued)" -gt "$q0" ] \
  || fail "foreign queue: same-path reload did not revalidate/park RAM backlog"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for tightq 20
[ "$(received tightq)" = 20 ] && [ "$(statf events_lost)" = "$lost0" ] \
  || fail "foreign queue: recovery lost the RAM backlog"
[ "$(docker exec "$PG_CT" stat -c %a "$FB4")" = 600 ] || fail "foreign queue: repaired target not private"
setguc pg_logtap.export_fallback_file ''; reload; sleep 1
docker exec "$PG_CT" rm -f "$FB4"
ok "root-owned 0666 queue unchanged/refused; same-path repair+HUP parked and replayed 20/20 via worker-owned 0600"

echo "== file:// sink at 0666, root-owned: refused, RAM retry to private sink =="
SINK6=$FB_DIR/logtap-sink-0666.log
PRIVATE_SINK=$FB_DIR/logtap-private-sink.log
docker exec "$PG_CT" sh -c "rm -f '$SINK6' '$PRIVATE_SINK'; printf 'ROOT-SINK-CANARY\n' > '$SINK6'; chmod 0666 '$SINK6'"
sink_before=$(docker exec "$PG_CT" sha256sum "$SINK6")
sink_meta=$(docker exec "$PG_CT" stat -c '%u:%a:%h:%s' "$SINK6")
sync0=$(statf fb_sync_failures); lost0=$(statf events_lost)
setguc pg_logtap.export_url "file://$SINK6"; reload; sleep 1
failed0=$(statf send_cycles_failed)
gen tights 20; sleep 2
[ "$(statf send_cycles_failed)" -gt "$failed0" ] || fail "foreign sink: send did not fail"
[ "$(docker exec "$PG_CT" sha256sum "$SINK6")" = "$sink_before" ] \
  && [ "$(docker exec "$PG_CT" stat -c '%u:%a:%h:%s' "$SINK6")" = "$sink_meta" ] \
  || fail "foreign sink: root-owned contents/owner/mode/link count changed"
[ "$(statf fb_sync_failures)" = "$sync0" ] || fail "foreign sink: refusal counted as sync failure"
docker exec -u postgres "$PG_CT" sh -c ": > '$PRIVATE_SINK'; chmod 0600 '$PRIVATE_SINK'"
setguc pg_logtap.export_url "file://$PRIVATE_SINK"; reload
n=0; while [ "$n" -lt 15 ]; do
  docker cp "$PG_CT:$PRIVATE_SINK" "$OUT/private-sink.jsonl" >/dev/null
  [ "$(received tights "$OUT/private-sink.jsonl")" -ge 20 ] && break
  n=$((n + 1)); sleep 1
done
[ "$(received tights "$OUT/private-sink.jsonl")" = 20 ] \
  && [ "$(json_check tights "$OUT/private-sink.jsonl")" = 20 ] \
  && [ "$(seqs_of tights "$OUT/private-sink.jsonl" | sort | uniq -d | wc -l)" = 0 ] \
  && [ "$(statf events_lost)" = "$lost0" ] \
  || fail "foreign sink: private recovery did not deliver 20/20 whole once"
[ "$(docker exec "$PG_CT" stat -c '%u:%a:%h' "$PRIVATE_SINK")" = "$(docker exec -u postgres "$PG_CT" id -u):600:1" ] \
  || fail "foreign sink: recovery target is not worker-owned/private/single-link"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 1
docker exec "$PG_CT" rm -f "$SINK6" "$PRIVATE_SINK"
ok "root-owned 0666 sink unchanged/refused; RAM retry delivered 20/20 whole once to worker-owned 0600 sink"

echo "== insecure sink/queue targets: no symlink/hardlink/FIFO/special/directory IO =="
# Final symlinks and shared inodes are forbidden even when the referenced file
# belongs to postgres. A FIFO with no peer must fail without blocking the worker.
SEC_TARGET="$FB_DIR/logtap-insecure-target"
SEC_CANARY="$FB_DIR/logtap-security-canary"
for side in sink queue; do
  for kind in symlink hardlink fifo special directory; do
    setguc pg_logtap.export_url "http://$VEC:8686"
    setguc pg_logtap.export_fallback_file ''; reload; sleep 1
    docker exec "$PG_CT" sh -c "rm -rf '$SEC_TARGET'; rm -f '$SEC_CANARY'"
    docker exec -u postgres "$PG_CT" sh -c "printf 'PRIVATE-CANARY\n' > '$SEC_CANARY'; chmod 0644 '$SEC_CANARY'" \
      || fail "$side $kind: could not create private canary"
    case "$kind" in
      symlink) docker exec -u postgres "$PG_CT" ln -s "$SEC_CANARY" "$SEC_TARGET" ;;
      hardlink) docker exec -u postgres "$PG_CT" ln "$SEC_CANARY" "$SEC_TARGET" ;;
      fifo) docker exec -u postgres "$PG_CT" sh -c "mkfifo '$SEC_TARGET'; chmod 0666 '$SEC_TARGET'" ;;
      special) docker exec "$PG_CT" sh -c "mknod '$SEC_TARGET' c 1 7; chown postgres '$SEC_TARGET'; chmod 0666 '$SEC_TARGET'" ;;
      directory) docker exec -u postgres "$PG_CT" mkdir "$SEC_TARGET" ;;
    esac
    target_meta=$(docker exec "$PG_CT" stat -c '%F:%u:%a:%h:%s' "$SEC_TARGET")
    canary_meta=$(docker exec "$PG_CT" stat -c '%u:%a:%h:%s' "$SEC_CANARY")
    canary_hash=$(docker exec "$PG_CT" sha256sum "$SEC_CANARY")
    sync0=$(statf fb_sync_failures); lost0=$(statf events_lost)
    q0=$(statf events_queued)
    if [ "$side" = sink ]; then
      setguc pg_logtap.export_url "file://$SEC_TARGET"
    else
      setguc pg_logtap.export_url 'http://127.0.0.1:1'
      setguc pg_logtap.export_fallback_file "$SEC_TARGET"
    fi
    reload; sleep 1
    failed0=$(statf send_cycles_failed)
    gen "secure-$side-$kind" 10; sleep 2
    [ "$(statf send_cycles_failed)" -gt "$failed0" ] \
      || fail "$side $kind: worker blocked or insecure send succeeded"
    [ "$(docker exec "$PG_CT" stat -c '%F:%u:%a:%h:%s' "$SEC_TARGET")" = "$target_meta" ] \
      && [ "$(docker exec "$PG_CT" stat -c '%u:%a:%h:%s' "$SEC_CANARY")" = "$canary_meta" ] \
      && [ "$(docker exec "$PG_CT" sha256sum "$SEC_CANARY")" = "$canary_hash" ] \
      || fail "$side $kind: refused target/canary changed before validation"
    [ "$(statf fb_sync_failures)" = "$sync0" ] || fail "$side $kind: refusal counted as sync failure"
    if [ "$side" = queue ]; then
      [ "$(statf fallback_broken)" = 1 ] && [ "$(statf events_queued)" = "$q0" ] \
        || fail "queue $kind: refusal did not preserve accounting/broken gauge"
    fi
    # Deliver held events to a known regular 0600 sink, leaving the insecure
    # inode alone until delivery is proved. Broken A may remain active meanwhile.
    docker exec -u postgres "$PG_CT" sh -c "rm -f '$PRIVATE_SINK'; : > '$PRIVATE_SINK'; chmod 0600 '$PRIVATE_SINK'"
    setguc pg_logtap.export_url "file://$PRIVATE_SINK"; reload
    n=0; while [ "$n" -lt 15 ]; do
      docker cp "$PG_CT:$PRIVATE_SINK" "$OUT/private-sink.jsonl" >/dev/null
      [ "$(received "secure-$side-$kind" "$OUT/private-sink.jsonl")" -ge 10 ] && break
      n=$((n + 1)); sleep 1
    done
    [ "$(received "secure-$side-$kind" "$OUT/private-sink.jsonl")" = 10 ] \
      && [ "$(json_check "secure-$side-$kind" "$OUT/private-sink.jsonl")" = 10 ] \
      && [ "$(seqs_of "secure-$side-$kind" "$OUT/private-sink.jsonl" | sort | uniq -d | wc -l)" = 0 ] \
      && [ "$(statf events_lost)" = "$lost0" ] \
      || fail "$side $kind: recovery lost/corrupted/duplicated held events"
    [ "$(docker exec "$PG_CT" stat -c %a "$PRIVATE_SINK")" = 600 ] || fail "$side $kind: recovery sink not private"
    setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 1
    if [ "$side" = queue ]; then
      # A refused nonregular active path is not proof of emptiness. Repair A,
      # explicitly revalidate it, then request disable after it is proven empty.
      docker exec "$PG_CT" sh -c "rm -rf '$SEC_TARGET'"
      docker exec -u postgres "$PG_CT" sh -c ": > '$SEC_TARGET'; chmod 0600 '$SEC_TARGET'"
      reload; sleep 1
      [ "$(statf fallback_broken)" = 0 ] || fail "queue $kind: secure same-path repair did not reopen"
      setguc pg_logtap.export_fallback_file ''; reload; sleep 1
    fi
    docker exec "$PG_CT" sh -c "rm -rf '$SEC_TARGET'; rm -f '$SEC_CANARY' '$PRIVATE_SINK'"
  done
done
ok "sink and queue refused five insecure target types unchanged; all 100 markers recovered once via worker-owned 0600"

echo "== a 900KB control-byte message at message_max=1MB: parked and replayed whole =="
# JSON escaping turns a control byte into six bytes (\u00XX): one wide
# control-byte event serializes past the raw-width replay bound the queue
# once had — the member was written (control bytes compress ~1000:1, so the
# framing check passed) and then skipped on replay as if it were a
# decompression bomb: an event the system captured and counted as queued,
# lost. Boot the widest slot to drive it; the ring shrinks to keep shmem
# sane. Counters are read after the restart — shmem dies with the postmaster.
FB5_REL=pg_logtap-fallback5.bin
setguc pg_logtap.message_max 1048576
setguc pg_logtap.ring_capacity 128
docker restart "$PG_CT" >/dev/null; wait_ready
q0=$(statf events_queued); sk0=$(statf warn_fallback_skipped); l0=$(statf events_lost)
setguc pg_logtap.export_url "http://127.0.0.1:1"
setguc pg_logtap.export_fallback_file "$FB5_REL"; reload; sleep 2
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN RAISE WARNING 'logtap $E2E_TAG ctrlmsg$E2E_SUF 1 %', repeat(chr(1), 900000); END \$\$" >/dev/null
sleep 3
[ "$(statf events_queued)" -gt "$q0" ] || fail "ctrl-byte message: never parked on the wide-slot queue"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 2
wait_for ctrlmsg 1
[ "$(received ctrlmsg)" = 1 ] || fail "ctrl-byte message: not replayed whole ($(received ctrlmsg)/1)"
[ "$(statf warn_fallback_skipped)" = "$sk0" ] || fail "ctrl-byte message: the member was skipped as unreadable (warn_fallback_skipped grew)"
[ "$(statf events_lost)" = "$l0" ] || fail "ctrl-byte message: events lost"
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM RESET pg_logtap.message_max" >/dev/null
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM RESET pg_logtap.ring_capacity" >/dev/null
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
docker restart "$PG_CT" >/dev/null; wait_ready
ok "control-byte message at message_max=1MB: parked, replayed 1/1, nothing skipped or lost"

echo "== file:// final symlink -> queue: sink security and queue alias guards refuse =="
# The sink now fails O_NOFOLLOW before its inode-alias guard. The regular,
# single-link queue still needs its mirror alias guard: its peer names this
# same inode through the symlink. Both files must remain empty/private.
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
[ "$(docker exec "$PG_CT" stat -c %a "$FB2")" = 600 ] || fail "sink alias: queue mode changed"
docker exec "$PG_CT" rm -f "$FB_DIR/logtap-sink-alias.bin"
reload; sleep 1 # same-path revalidation after removing the alias
setguc pg_logtap.export_fallback_file ''; reload; sleep 1
docker exec "$PG_CT" rm -f "$FB2"
ok "final symlink sink and queue alias refused: file stayed empty/private, 20/20 carried by RAM"

echo "== fallback hardlinked to sink: both refuse shared inode before chmod/IO =="
# nlink=2 now rejects both fds at the security boundary before alias checks.
# Keep this no-write guard, and test single-link /./ aliases below so security
# refusal cannot make the inode-alias regression vacuously pass.
FB3_REL=pg_logtap-fallback3.bin
FB3="$FB_DIR/$FB3_REL"
# -u postgres: docker exec defaults to root, and a root-owned file is EACCES
# to the worker — the scenario would test permissions, not inodes.
docker exec -u postgres "$PG_CT" sh -c "rm -f '$FB3' '$FB_DIR/logtap-real2.bin'; : > '$FB_DIR/logtap-real2.bin'; chmod 0644 '$FB_DIR/logtap-real2.bin'; ln '$FB_DIR/logtap-real2.bin' '$FB3'"
# Same ordering, but the fallback now refuses nlink=2 already under HTTP.
# Loading the sink later must refuse that shared inode too, without chmod.
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
[ "$(docker exec "$PG_CT" stat -c %a "$FB3")" = 644 ] || fail "hardlink queue: validation chmodded the shared inode"
setguc pg_logtap.export_url "http://$VEC:8686"; reload; sleep 1
wait_for halias 20
docker exec "$PG_CT" rm -f "$FB_DIR/logtap-real2.bin" # nlink becomes one
reload; sleep 1 # same-path security revalidation now permits the empty queue
[ "$(statf fallback_broken)" = 0 ] || fail "hardlink queue: removing extra link did not repair on HUP"
setguc pg_logtap.export_fallback_file ''; reload; sleep 1
docker exec "$PG_CT" rm -f "$FB3"
ok "hardlink refused before chmod: shared mode stayed 0644, file empty, 20/20 recovered via RAM"

echo "== regular single-link /./ alias: inode guards remain load-bearing =="
FB_ALIAS_REL=pg_logtap-dot-alias.bin
FB_ALIAS="$FB_DIR/$FB_ALIAS_REL"
docker exec -u postgres "$PG_CT" sh -c "rm -f '$FB_ALIAS'; : > '$FB_ALIAS'; chmod 0600 '$FB_ALIAS'"
setguc pg_logtap.export_fallback_file "$FB_ALIAS_REL"; reload; sleep 1
# Different strings, same final regular file; O_NOFOLLOW and the ownership/
# nlink/mode checks all pass. Removing either inode guard must fail this case.
setguc pg_logtap.export_url "file://$FB_DIR/./$FB_ALIAS_REL" \
  || fail "dot alias: valid alternate spelling rejected before inode guards"
reload; sleep 1
failed0=$(statf send_cycles_failed)
gen dotAlias 20; sleep 2
[ "$(statf send_cycles_failed)" -gt "$failed0" ] && [ "$(statf fallback_broken)" = 1 ] \
  && [ "$(docker exec "$PG_CT" stat -c '%a:%h:%s' "$FB_ALIAS")" = '600:1:0' ] \
  || fail "dot alias: secure single-link alias was sent/queued instead of refused"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for dotAlias 20
[ "$(seqs_of dotAlias | sort | uniq -d | wc -l)" = 0 ] || fail "dot alias: recovery duplicated markers"
setguc pg_logtap.export_fallback_file ''; reload; sleep 1
docker exec "$PG_CT" rm -f "$FB_ALIAS"
ok "single-link regular alias passed security checks but both inode guards refused IO; 20/20 recovered once"

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
gen dnsfail 5 # traffic forces a dial: getaddrinfo NONAME → streak ≥ 1
# The worker may start that cycle just after a fixed sleep expires; wait on the
# gauge itself. The events buffer in the RAM backlog — no fallback file here.
n=0; while [ "$n" -lt 10 ] && [ "$(statf dns_fail_streak)" -lt 1 ]; do
  n=$((n + 1)); sleep 1
done
streak=$(statf dns_fail_streak)
[ "$streak" -ge 1 ] 2>/dev/null || fail "dns-fail gauge: dns_fail_streak=$streak after failed lookups — not exported?"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for dnsfail 5 # the buffered events ride the recovery
[ "$(statf dns_fail_streak)" = 0 ] || fail "dns-fail gauge: streak did not reset after recovery ($(statf dns_fail_streak))"
ok "dns_fail_streak $streak→0, visible in pg_logtap_stats()"

echo "== fallback_broken gauge: foreign format repaired by explicit same-path HUP =="
docker exec -u postgres "$PG_CT" sh -c "printf 'not a pg_logtap queue\n' > '$FB'; chmod 0600 '$FB'"
setguc pg_logtap.export_url "http://127.0.0.1:1"; reload; sleep 1
setguc pg_logtap.export_fallback_file "$FB_REL"; reload; sleep 2
[ "$(statf fallback_broken)" = 1 ] || fail "fallback_broken gauge: foreign format not marked broken"
foreign_before=$(docker exec "$PG_CT" sha256sum "$FB")
q0=$(statf events_queued)
gen samePathRepair 10; sleep 1
[ "$(docker exec "$PG_CT" sha256sum "$FB")" = "$foreign_before" ] && [ "$(statf events_queued)" = "$q0" ] \
  || fail "fallback_broken gauge: foreign file changed while broken"
# Operator repair is explicit and discards only this synthetic foreign canary,
# not a real queue. Repair alone leaves broken latched; HUP revalidates A.
docker exec -u postgres "$PG_CT" sh -c ": > '$FB'; chmod 0600 '$FB'"
sleep 1
[ "$(statf fallback_broken)" = 1 ] || fail "fallback_broken gauge: repaired without HUP"
reload; sleep 2
[ "$(statf fallback_broken)" = 0 ] && [ "$(statf events_queued)" -gt "$q0" ] \
  || fail "fallback_broken gauge: same-path reload failed to reopen and park held events"
setguc pg_logtap.export_url "http://$VEC:8686"; reload
wait_for samePathRepair 10
[ "$(seqs_of samePathRepair | sort | uniq -d | wc -l)" = 0 ] \
  && [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 0 ] \
  || fail "fallback_broken gauge: repaired same-path queue did not drain once"
# Switch only after the active file has drained; the capped scenario below
# uses this second queue, not a hidden old active A.
FB_REL2=pg_logtap-fallback2.bin
setguc pg_logtap.export_fallback_file "$FB_REL2"; reload; sleep 1
ok "fallback_broken 1→0 on same-path HUP; repaired queue parked/replayed 10/10 once, then safe path switch"

echo "== fallback_max_mb: a capped queue keeps the newest tail, counts the rest lost =="
# Sizing: this run's queue scenario shows ~15 compressed bytes per event, so
# a 1MB cap holds ~68k events. 150k events (~2.2MB) force at least one
# compaction to the newest 512KB. Pace this one producer below the observed
# queue drain rate: the scenario tests fallback compaction, not whether a fast
# backend can overflow the 1024-slot capture ring before enough events reach
# the queue. The exact split is compression-dependent; the asserts are the
# CONTRACT: file bounded, newest tail delivered, dropped events counted lost
# (compacted when the file was trimmed, lost when the backlog was), no
# duplicate replay.
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
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
  WHILE i < 150000 LOOP
    RAISE WARNING 'logtap $E2E_TAG cap1$E2E_SUF %', i;
    i := i + 1;
    IF i % 500 = 0 THEN PERFORM pg_sleep(0.15); END IF;
  END LOOP; END \$\$" >/dev/null 2>&1 || fail "fallback_max_mb: paced generator failed"
drain_ring
n=0; while [ "$n" -lt 20 ] && [ "$(statf events_compacted)" -eq 0 ]; do
  n=$((n + 1)); sleep 1
done
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
  backlog=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
  [ "$(received cap1)" -gt 0 ] && [ "$backlog" -le 0 ] && break
done
R=$(received cap1)
D=$(( $(statf events_dropped) - D0 ))
# "Newest tail" is WHICH events survive, not HOW MANY: bytes-per-event is
# compression- and timing-dependent (an arm64 runner parked smaller batches,
# ~21B/event vs amd64's ~15B — 25k survived where ~68k were "expected"; the
# contract held, the count did not). Assert the property instead, counting
# holes in the last-1000 window: a hole an OLDER-kept event left (compaction
# dropped backwards) fails, but the ring refusing the NEWEST under overload
# (documented events_dropped — a slow runner's compaction walks stall drain
# mid-storm; seen with 8729 holes under 11278 dropped) is accounted for by
# D. At D=0 this is exactly "oldest of the last 1000 = 149000". Even with
# zero compression the 512KB newest slice holds ~5k of these events, so
# 1000 never clips legitimate survivors.
last1k=$(grep -oE "logtap kill cap1$SUF [0-9]+" "$OUT/vector-out.jsonl" \
  | grep -oE '[0-9]+$' | sort -n | tail -n 1000 | head -n 1)
holes=$(( 150000 - last1k - 1000 ))
[ "$holes" -le "$D" ] 2>/dev/null || fail "fallback_max_mb: newest tail broken — oldest of the last 1000 delivered is $last1k ($holes holes > $D ring-dropped, delivered=$R)"
dups=$(grep "logtap kill cap1$SUF" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$dups" = 0 ] || fail "fallback_max_mb: $dups duplicate seqs — compaction replayed delivered members"
[ "$((R + L + D))" -ge 140000 ] || fail "fallback_max_mb: delivered($R) + lost($L) + dropped($D) < 140000 of 150000"
ok "1MB cap held the file at ${sz}B, newest tail delivered ($R), loss counted ($L), compacted=$C excluded from delivered, ring-dropped ($D), dup=0"

setguc pg_logtap.export_url ''; setguc pg_logtap.export_fallback_file ''
setguc pg_logtap.fallback_max_mb 512
setguc pg_logtap.export_timeout_ms 5000; reload
echo "e2e-kill: all scenarios passed"
