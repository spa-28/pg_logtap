#!/bin/sh
# Fault-injection acceptance: the sync/write paths cannot be driven to
# failure from SQL, so this suite runs a THROWAWAY postgres under an
# LD_PRELOAD shim (tests/e2e/fsyncfail.c) that fails fdatasync with EIO for
# one named file, N times, and leaves every other fd (WAL included) alone.
# The stand is not touched: the shim needs container env set at create time,
# so this brings up its own pglogtap-faults container and removes it at exit.
#   sink-sync-fail    : file:// sink fdatasync fails -> batch rolled back,
#                       retried whole, exactly one copy of every event; the
#                       rollback's own sync fails too (COUNT=2: both EIOs
#                       land on the sink) -> the not-durable window is
#                       named in the log, warned once
#   fallback-sync-fail: queue fdatasync fails -> member stays (not durable),
#                       no duplicate member, fb_sync_failures counts it, replay
#                       delivers every event once
#   compact-open-fail  : a non-EEXIST temp open failure preserves an existing
#                        .compact canary; after the fault clears, normal EEXIST
#                        litter cleanup lets the cap land
#   compact-sync-fail  : the compaction temp's fdatasync fails -> rewrite
#                        abandoned (queue whole, nothing lost) and counted in
#                        fb_sync_failures; the cap lands once syncs heal
#   chmod-fail         : otherwise secure sink/queue/temp fchmod fails -> no IO,
#                        RAM retry or intact queue; same-path HUP repairs queue
#   partial-write      : worker-owned regular sink takes a prefix then ENOSPC ->
#                        torn tail rolled back, RAM retry delivers one whole copy
#   sync-soft-restart  : shared fb_sync_failures survives TERM/replacement and
#                        reload; the next real EIO increases SQL and Prometheus
# Usage: scripts/e2e-faults.sh <pg_major>   (needs dist/pg<major> from `stand`)
set -u
. "$(dirname "$0")/e2e-common.sh"
V=$1
[ -n "$V" ] || { echo "usage: $0 <pg_major>" >&2; exit 2; }
CT=pglogtap-faults-$V # per major: parallel matrix runs
E2E_TAG=fault
E2E_CT=$CT
E2E_SUF= # throwaway container: fresh sinks each run, no per-run suffix needed
OUT=/tmp/logtap-faults-$V
SO=dist/pg$V/lib/pg_logtap.so
[ -f "$SO" ] || { echo "e2e-faults: $SO missing — run the stand phase first" >&2; exit 2; }

fail_extra() { # shim-specific post-mortem
  echo "sync target: $(docker exec "$CT" cat /tmp/fsyncfail-target 2>/dev/null || echo '<unset>')" >&2
  echo "open target: $(docker exec "$CT" cat /tmp/openfail-target 2>/dev/null || echo '<unset>')" >&2
  echo "chmod target: $(docker exec "$CT" cat /tmp/chmodfail-target 2>/dev/null || echo '<unset>')" >&2
  echo "write target: $(docker exec "$CT" cat /tmp/writefail-target 2>/dev/null || echo '<unset>')" >&2
  docker exec "$CT" sh -c 'sort /tmp/fsyncfail.log 2>/dev/null | uniq -c' >&2
  docker exec "$CT" sh -c "ls -la '${PGDATA_C:-}/$FB_REL' '${PGDATA_C:-}/$FB_REL.compact' 2>/dev/null" >&2
}

mkdir -p "$OUT"
e2e_lock
cc -shared -fPIC -Wall -Wextra tests/e2e/fsyncfail.c -o "$OUT/fsyncfail.so" -ldl

FB_REL=pgfaults-queue.bin # PGDATA-relative, like a real deployment
docker rm -f -v "$CT" >/dev/null 2>&1
docker run -d --name "$CT" -e POSTGRES_PASSWORD=dev \
  -v "$OUT/fsyncfail.so:/tmp/fsyncfail.so:ro" \
  -e LD_PRELOAD=/tmp/fsyncfail.so \
  -e FSYNCFAIL_COUNT=2 \
  -e OPENFAIL_COUNT=100000 \
  -e OPENFAIL_ERRNO=13 \
  postgres:"$V" >/dev/null || fail "could not start postgres:$V"
cleanup() { docker rm -f -v "$CT" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM

wait_ready

# The shim's watched path depends on PGDATA, which differs across majors
# (pg18 images use /var/lib/postgresql/18/docker, older ones .../data) and
# is only known once the server is up — so the harness tells the shim what
# to watch through a file it reads per call. Until the file exists the shim
# passes everything through, so the boot itself is never faulted.
PGDATA_C=$(docker exec "$CT" psql -U postgres -Atc "SHOW data_directory")
set_target() { docker exec "$CT" sh -c "printf '%s' '$1' > /tmp/fsyncfail-target"; }
clear_target() { docker exec "$CT" rm -f /tmp/fsyncfail-target; }
set_open_target() { docker exec "$CT" sh -c "printf '%s' '$1' > /tmp/openfail-target"; }
clear_open_target() { docker exec "$CT" rm -f /tmp/openfail-target; }
set_chmod_target() { docker exec "$CT" sh -c "printf '%s' '$1' > /tmp/chmodfail-target"; }
clear_chmod_target() { docker exec "$CT" rm -f /tmp/chmodfail-target; }
set_write_target() { docker exec "$CT" sh -c "printf '%s' '$1' > /tmp/writefail-target"; }
clear_write_target() { docker exec "$CT" rm -f /tmp/writefail-target; }
# The image already has bash; no curl install or extra scraper container needed.
prom_syncfails() {
  docker exec "$CT" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9187; printf "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3; timeout 5 cat <&3' \
    | tr -d '\r' | awk '$1 == "pg_logtap_fb_sync_failures" { print $2 }'
}
assert_syncfails() { # SQL text/JSON and the real HTTP export, same shared total
  [ "$(statf fb_sync_failures)" = "$1" ] \
    && [ "$(docker exec "$CT" psql -U postgres -Atc "SELECT pg_logtap_stats_json()::jsonb->>'fb_sync_failures'")" = "$1" ] \
    && [ "$(prom_syncfails)" = "$1" ] \
    || fail "sync counter: expected $1 in SQL/JSON/Prometheus (SQL=$(statf fb_sync_failures), Prom=$(prom_syncfails))"
}

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
setguc pg_logtap.metrics_port 9187; reload
docker exec "$CT" psql -U postgres -qc "CREATE EXTENSION pg_logtap" >/dev/null
"$(dirname "$0")/e2e-require-ext.sh" "$CT"

# Markers in a file:// sink: count distinct events and duplicate seqs there.
sink_lines() { docker exec "$CT" sh -c "grep -oE 'logtap fault $1 [0-9]+' /tmp/$2.log 2>/dev/null" | sort -u | wc -l; }
sink_dups() { docker exec "$CT" sh -c "grep 'logtap fault' /tmp/$1.log 2>/dev/null" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l; }
gen_wide() { # marker count: incompressible enough to cross a 1MB queue cap
  docker exec "$CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
    WHILE i < $2 LOOP
      RAISE WARNING 'logtap fault $1 % %', i, (SELECT string_agg(md5(random()::text), '') FROM generate_series(1, 32));
      i := i + 1;
    END LOOP; END \$\$" >/dev/null 2>&1
}

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
# The rollback's own sync failed too (the shim's second EIO): the window
# where an OS crash resurrects the truncated batch must be NAMED, not
# silent — the warn-once latch's regression assert.
[ "$(docker logs "$CT" 2>&1 | grep -c 'rollback after a failed fdatasync is not durable')" -ge 1 ] \
  || fail "sink sync-fail: the failed rollback sync was not warned (not-durable window silent)"
ok "20/20 in the sink, 0 duplicate seqs (failed sync rolled back and retried whole), failed rollback sync warned"

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
assert_syncfails "$syncfails"
# Remove injection before replacing just the worker: the postmaster/shmem must
# stay alive. Fresh worker BSS is exactly where a local absolute total regressed.
clear_target
postmaster0=$(docker exec "$CT" psql -U postgres -Atc 'SELECT pg_postmaster_start_time()')
wpid=$(worker_pid); [ -n "$wpid" ] || fail "sync soft restart: worker not found"
docker exec "$CT" kill -TERM "$wpid"
n=0; new_wpid=$wpid
while [ "$n" -lt 20 ] && { [ -z "$new_wpid" ] || [ "$new_wpid" = "$wpid" ]; }; do
  n=$((n + 1)); sleep 1; new_wpid=$(worker_pid)
done
[ -n "$new_wpid" ] && [ "$new_wpid" != "$wpid" ] || fail "sync soft restart: worker did not restart"
[ "$(docker exec "$CT" psql -U postgres -Atc 'SELECT pg_postmaster_start_time()')" = "$postmaster0" ] \
  || fail "sync soft restart: cluster restarted, retention check is invalid"
sleep 2
assert_syncfails "$syncfails"
# A soft reload must not clear history either. Then spend the replacement
# process's fresh fault budget on genuine queue fdatasync failures.
reload; sleep 1; assert_syncfails "$syncfails"
set_target "$PGDATA_C/$FB_REL"
gen "fb4-$SUF" 20; sleep 1; gen "fb5-$SUF" 20; sleep 2
syncfails2=$(statf fb_sync_failures)
[ "$syncfails2" -gt "$syncfails" ] 2>/dev/null \
  || fail "sync soft restart: next real EIO did not increase $syncfails (got $syncfails2)"
clear_target
assert_syncfails "$syncfails2"
setguc pg_logtap.export_url 'file:///tmp/replay.log'; reload
n=0; while [ "$n" -lt 15 ]; do
  [ "$(sink_lines "fb1-$SUF" replay)" -ge 20 ] && [ "$(sink_lines "fb2-$SUF" replay)" -ge 20 ] && [ "$(sink_lines "fb3-$SUF" replay)" -ge 20 ] && break
  n=$((n + 1)); sleep 1
done
R1=$(sink_lines "fb1-$SUF" replay); R2=$(sink_lines "fb2-$SUF" replay); R3=$(sink_lines "fb3-$SUF" replay)
n=0; while [ "$n" -lt 15 ] && [ "$(sink_lines "fb5-$SUF" replay)" -lt 20 ]; do
  n=$((n + 1)); sleep 1
done
R4=$(sink_lines "fb4-$SUF" replay); R5=$(sink_lines "fb5-$SUF" replay)
[ "$R1" = 20 ] && [ "$R2" = 20 ] && [ "$R3" = 20 ] && [ "$R4" = 20 ] && [ "$R5" = 20 ] \
  || fail "fallback sync-fail: replay delivered $R1/$R2/$R3/$R4/$R5 of 20 each"
[ "$(sink_dups replay)" = 0 ] || fail "fallback sync-fail: duplicate seqs in replay — sync-failed member re-appended"
bl=$(docker exec "$CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$bl" = 0 ] || fail "fallback sync-fail: queue_backlog=$bl after replay"
assert_syncfails "$syncfails2"
ok "SQL/Prom sync history $syncfails retained across TERM/reload, next EIO → $syncfails2; 100/100 replayed once (queued was $q)"

echo "== compaction temp: non-EEXIST open failure preserves existing object =="
# The queue compactor may remove its own stale temp only after open(O_EXCL)
# reports EEXIST. Inject EACCES while a canary occupies the predictable path:
# the canary must survive. Once injection stops, the real EEXIST path may
# unlink that stale object and the cap must land normally.
clear_target
clear_open_target
docker restart "$CT" >/dev/null; wait_ready
docker exec "$CT" sh -c "rm -f '$PGDATA_C/$FB_REL' '$PGDATA_C/$FB_REL.compact' /tmp/open-compact.log"
setguc pg_logtap.export_url 'http://127.0.0.1:1'
setguc pg_logtap.export_fallback_file "$FB_REL"
setguc pg_logtap.fallback_max_mb 1; reload; sleep 2
CANARY="pg_logtap compact canary $SUF"
docker exec -u postgres "$CT" sh -c "printf '%s' '$CANARY' > '$PGDATA_C/$FB_REL.compact'"
set_open_target "$PGDATA_C/$FB_REL.compact"
compacted0=$(statf events_compacted)
gen_wide "open-$SUF" 4000
sleep 4
qsize=$(docker exec "$CT" stat -c %s "$PGDATA_C/$FB_REL" 2>/dev/null || echo 0)
[ "$qsize" -gt 1048576 ] 2>/dev/null \
  || fail "compact open-fail: queue size $qsize never crossed the 1MB cap"
got_canary=$(docker exec "$CT" cat "$PGDATA_C/$FB_REL.compact" 2>/dev/null || true)
[ "$got_canary" = "$CANARY" ] \
  || fail "compact open-fail: .compact canary was removed or changed after injected EACCES"
[ "$(statf events_compacted)" = "$compacted0" ] \
  || fail "compact open-fail: a compaction landed while every exclusive temp open returned EACCES"

clear_open_target
# The new temp is regular/worker-owned, but fchmod itself can still fail.
# Refuse before copying any queue data or publishing a compaction loss.
sync0=$(statf fb_sync_failures)
set_chmod_target "$PGDATA_C/$FB_REL.compact"
gen "compact-chmod-$SUF" 20; sleep 2
[ "$(statf fb_sync_failures)" = "$sync0" ] || fail "compact chmod-fail: refusal counted as fdatasync failure"
[ "$(statf events_compacted)" = "$compacted0" ] \
  || fail "compact chmod-fail: rewrite landed despite failed permission check"
[ "$(docker exec "$CT" stat -c %s "$PGDATA_C/$FB_REL")" -gt 1048576 ] \
  || fail "compact chmod-fail: original queue was trimmed"
docker exec "$CT" grep -q '^fchmod EPERM$' /tmp/fsyncfail.log \
  || fail "compact chmod-fail: injection never reached the temp fd"
docker exec "$CT" test ! -e "$PGDATA_C/$FB_REL.compact" \
  || fail "compact chmod-fail: rejected temp left behind"
clear_chmod_target
gen "open-heal-$SUF" 20
n=0; while [ "$n" -lt 15 ]; do
  compacted_now=$(statf events_compacted)
  [ "$compacted_now" -gt "$compacted0" ] 2>/dev/null && break
  n=$((n + 1)); sleep 1
done
compacted_now=$(statf events_compacted)
[ "$compacted_now" -gt "$compacted0" ] 2>/dev/null \
  || fail "compact open-fail: cap did not land after EACCES injection cleared"
if docker exec "$CT" test -e "$PGDATA_C/$FB_REL.compact"; then
  fail "compact open-fail: stale .compact canary remained after normal EEXIST recovery"
fi
setguc pg_logtap.export_url 'file:///tmp/open-compact.log'; reload
n=0; while [ "$n" -lt 15 ]; do
  [ "$(docker exec "$CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 0 ] && break
  n=$((n + 1)); sleep 1
done
bl=$(docker exec "$CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$bl" = 0 ] || fail "compact open-fail: queue_backlog=$bl after replay"
ok "EACCES preserved the canary; clearing it exercised EEXIST cleanup and the cap landed"

echo "== compaction temp: fdatasync fails -> rewrite abandoned, counted, cap still lands =="
# A landed compaction is a durability point (its temp is fdatasynced before
# the rename), so an EIO there must count in fb_sync_failures like any other
# sync failure — while the safety shape stays: rewrite abandoned, original
# queue stands, nothing lost, no temp litter; once the syncs heal, the cap
# rewrite lands.
docker restart "$CT" >/dev/null; wait_ready # fresh worker: the shim's per-process budget resets
docker exec "$CT" sh -c "rm -f '$PGDATA_C/$FB_REL' '$PGDATA_C/$FB_REL.compact' /tmp/replay.log"
set_target "$PGDATA_C/$FB_REL.compact"
setguc pg_logtap.export_url 'http://127.0.0.1:1'
setguc pg_logtap.fallback_max_mb 1; reload; sleep 2
# ~1MB cap needs incompressible bulk. One md5 repeated is gzip candy (a
# 4000-event burst parked as 181KB once); 32 INDEPENDENT md5s per event are
# random hex ≈ 4 bits/char under gzip, so 4000 x ~512B ≈ 2MB really crosses.
gen_wide "cmp-$SUF" 4000
sleep 4 # park, cross the cap, fail the temp syncs, then heal past the budget
syncfails=$(statf fb_sync_failures)
[ "$syncfails" -ge 1 ] 2>/dev/null || fail "compact sync-fail: fb_sync_failures=$syncfails — the temp fdatasync EIO was not counted"
[ "$(statf fallback_broken)" = 0 ] || fail "compact sync-fail: fallback_broken=1 — the abandoned rewrite broke the queue"
[ "$(docker exec "$CT" stat -c %s "$PGDATA_C/$FB_REL.compact" 2>/dev/null || echo 0)" = 0 ] \
  || fail "compact sync-fail: abandoned temp left behind"
[ "$(statf events_compacted)" -ge 1 ] 2>/dev/null \
  || fail "compact sync-fail: no compaction ever landed (events_compacted=0) — the cap cannot work after an EIO"
# Replay what survived the cap: every delivered event exactly once.
setguc pg_logtap.export_url 'file:///tmp/compact.log'; reload
n=0; while [ "$n" -lt 15 ]; do
  [ "$(docker exec "$CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 0 ] && break
  n=$((n + 1)); sleep 1
done
bl=$(docker exec "$CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
[ "$bl" = 0 ] || fail "compact sync-fail: queue_backlog=$bl after replay"
got=$(sink_lines "cmp-$SUF" compact)
[ "$got" -ge 500 ] 2>/dev/null || fail "compact sync-fail: only $got/4000 cmp events survived to replay — backlog=0 is vacuous"
[ "$(sink_dups compact)" = 0 ] || fail "compact sync-fail: duplicate seqs after the EIO'd rewrites"
setguc pg_logtap.export_fallback_file ''; setguc pg_logtap.fallback_max_mb 512
ok "temp fdatasync EIO counted (fb_sync_failures=$syncfails), queue whole, cap landed after healing, replay drained with 0 dups"

echo "== fchmod failure: sink refused before writing, queue repaired by same-path HUP =="
clear_target
setguc pg_logtap.export_fallback_file ''
# Watching fchmod on a foreign inode proves owner validation precedes chmod,
# not merely that a real EPERM happened to leave the mode alone.
docker exec "$CT" sh -c "printf 'FOREIGN-CANARY\n' > /tmp/chmod-foreign.log; chmod 0666 /tmp/chmod-foreign.log; rm -f /tmp/fsyncfail.log"
foreign_before=$(docker exec "$CT" sha256sum /tmp/chmod-foreign.log)
set_chmod_target /tmp/chmod-foreign.log
setguc pg_logtap.export_url 'file:///tmp/chmod-foreign.log'; reload; sleep 1
failed0=$(statf send_cycles_failed)
gen "chmodforeign-$SUF" 10; sleep 2
[ "$(statf send_cycles_failed)" -gt "$failed0" ] \
  && [ "$(docker exec "$CT" sha256sum /tmp/chmod-foreign.log)" = "$foreign_before" ] \
  && [ "$(docker exec "$CT" stat -c '%u:%a' /tmp/chmod-foreign.log)" = '0:666' ] \
  || fail "foreign fd: not refused intact"
docker exec "$CT" test ! -e /tmp/fsyncfail.log || fail "foreign fd: fchmod called before owner validation"
clear_chmod_target
docker exec -u postgres "$CT" sh -c "printf '{\"canary\":\"chmod\"}\n' > /tmp/chmod-sink.log; chmod 0644 /tmp/chmod-sink.log"
sink_before=$(docker exec "$CT" sha256sum /tmp/chmod-sink.log)
sync0=$(statf fb_sync_failures); lost0=$(statf events_lost)
docker exec "$CT" rm -f /tmp/fsyncfail.log
set_chmod_target /tmp/chmod-sink.log
setguc pg_logtap.export_url 'file:///tmp/chmod-sink.log'; reload; sleep 1
failed0=$(statf send_cycles_failed)
gen "chmods-$SUF" 20; sleep 2
[ "$(statf send_cycles_failed)" -gt "$failed0" ] || fail "sink chmod-fail: send did not fail"
docker exec "$CT" grep -q '^fchmod EPERM$' /tmp/fsyncfail.log || fail "sink chmod-fail: fault never reached fchmod"
[ "$(docker exec "$CT" sha256sum /tmp/chmod-sink.log)" = "$sink_before" ] \
  && [ "$(docker exec "$CT" stat -c %a /tmp/chmod-sink.log)" = 644 ] \
  || fail "sink chmod-fail: rejected file contents/mode changed"
[ "$(statf fb_sync_failures)" = "$sync0" ] || fail "sink chmod-fail: refusal incremented sync failures"
clear_chmod_target
n=0; while [ "$n" -lt 15 ] && [ "$(sink_lines "chmods-$SUF" chmod-sink)" -lt 20 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(sink_lines "chmods-$SUF" chmod-sink)" = 20 ] && [ "$(sink_lines "chmodforeign-$SUF" chmod-sink)" = 10 ] \
  && [ "$(sink_dups chmod-sink)" = 0 ] \
  && [ "$(docker exec "$CT" stat -c %a /tmp/chmod-sink.log)" = 600 ] \
  || fail "sink chmod-fail: secure retry did not deliver 20/20 once"

CHMODQ="$PGDATA_C/chmod-queue.bin"
docker exec -u postgres "$CT" sh -c "rm -f '$CHMODQ'; : > '$CHMODQ'; chmod 0644 '$CHMODQ'"
queue_before=$(docker exec "$CT" sha256sum "$CHMODQ")
docker exec "$CT" rm -f /tmp/fsyncfail.log
set_chmod_target "$CHMODQ"
setguc pg_logtap.export_url 'http://127.0.0.1:1'
setguc pg_logtap.export_fallback_file "$CHMODQ"; reload; sleep 1
q0=$(statf events_queued)
gen "chmodq-$SUF" 20; sleep 2
docker exec "$CT" grep -q '^fchmod EPERM$' /tmp/fsyncfail.log || fail "queue chmod-fail: fault never reached fchmod"
[ "$(statf fallback_broken)" = 1 ] && [ "$(statf events_queued)" = "$q0" ] \
  && [ "$(docker exec "$CT" sha256sum "$CHMODQ")" = "$queue_before" ] \
  && [ "$(docker exec "$CT" stat -c %a "$CHMODQ")" = 644 ] \
  || fail "queue chmod-fail: insecure queue used or modified"
[ "$(statf fb_sync_failures)" = "$sync0" ] || fail "queue chmod-fail: refusal incremented sync failures"
clear_chmod_target
sleep 1
[ "$(statf fallback_broken)" = 1 ] || fail "queue chmod-fail: broken queue retried without HUP"
# Same resolved path, not a new pathname or process. HUP must revalidate it.
reload; sleep 2
[ "$(statf fallback_broken)" = 0 ] && [ "$(statf events_queued)" -gt "$q0" ] \
  && [ "$(docker exec "$CT" stat -c %a "$CHMODQ")" = 600 ] \
  || fail "queue chmod-fail: same-path HUP did not reopen/tighten/park"
setguc pg_logtap.export_url 'file:///tmp/chmod-replay.log'; reload
n=0; while [ "$n" -lt 15 ] && [ "$(sink_lines "chmodq-$SUF" chmod-replay)" -lt 20 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(sink_lines "chmodq-$SUF" chmod-replay)" = 20 ] && [ "$(sink_dups chmod-replay)" = 0 ] \
  && [ "$(docker exec "$CT" psql -U postgres -Atc 'SELECT queue_backlog FROM pg_logtap_delivery')" = 0 ] \
  && [ "$(statf events_lost)" = "$lost0" ] \
  || fail "queue chmod-fail: repaired queue failed complete lossless replay"
ok "foreign fd refused before fchmod; injected EPERM refused sink/queue before IO; secure retry and same-path HUP delivered 50/50 once"

echo "== regular sink: partial write + ENOSPC -> unchanged prefix, whole RAM retry =="
# /dev/full is now refused as a special file before write. A regular private
# sink and the target-controlled shim exercise the actual torn-tail rollback.
lost0=$(statf events_lost); drp0=$(statf events_dropped)
setguc pg_logtap.export_fallback_file ''
docker exec -u postgres "$CT" sh -c "printf '{\"canary\":\"partial\"}\n' > /tmp/partial.log; chmod 0600 /tmp/partial.log"
partial_before=$(docker exec "$CT" sha256sum /tmp/partial.log)
docker exec "$CT" rm -f /tmp/fsyncfail.log
set_write_target /tmp/partial.log
setguc pg_logtap.export_url 'file:///tmp/partial.log'; reload; sleep 1
failed0=$(statf send_cycles_failed)
gen "partial1-$SUF" 20; sleep 2
[ "$(statf send_cycles_failed)" -gt "$failed0" ] || fail "partial write: send did not fail"
if ! docker exec "$CT" grep -q '^write partial$' /tmp/fsyncfail.log \
  || ! docker exec "$CT" grep -q '^write ENOSPC$' /tmp/fsyncfail.log; then
  fail "partial write: no real prefix write followed by ENOSPC"
fi
[ "$(docker exec "$CT" sha256sum /tmp/partial.log)" = "$partial_before" ] \
  || fail "partial write: rollback left a torn tail or changed the original sink"
[ "$(statf events_lost)" = "$lost0" ] && [ "$(statf events_dropped)" = "$drp0" ] \
  || fail "partial write: RAM backlog lost/dropped events"
# Heal the SAME sink: a surviving torn prefix would break JSON and the copy
# count here (switching sinks would never observe whether rollback worked).
clear_write_target
n=0; while [ "$n" -lt 15 ] && [ "$(sink_lines "partial1-$SUF" partial)" -lt 20 ]; do
  n=$((n + 1)); sleep 1
done
[ "$(sink_lines "partial1-$SUF" partial)" = 20 ] && [ "$(sink_dups partial)" = 0 ] \
  || fail "partial write: RAM retry did not deliver 20/20 exactly once"
docker cp "$CT:/tmp/partial.log" "$OUT/partial.log" >/dev/null
[ "$(json_check "partial1-$SUF" "$OUT/partial.log")" = 20 ] || fail "partial write: retry left invalid JSON or incomplete lines"
[ "$(head -n 1 "$OUT/partial.log")" = '{"canary":"partial"}' ] || fail "partial write: pre-existing prefix changed"
ok "17-byte write then ENOSPC rolled back to the intact sink; same-file RAM retry delivered 20/20 valid JSON, no dups"

echo "e2e-faults: all scenarios passed"
