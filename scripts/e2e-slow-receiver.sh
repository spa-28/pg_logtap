#!/bin/sh
# Acceptance: a receiver that answers but slowly (each response >=
# pg_logtap.export_slow_ms) must not decide what gets lost: while it stays
# slow, live batches park on the fallback file. Once the receiver is fast,
# one rate-limited oldest-member probe must detect recovery and drain the
# queue even while capture remains continuously busy.
# Usage: scripts/e2e-slow-receiver.sh [pg_container] [sink_port]
# The stand (tests/e2e/compose.yaml) provides the network; this sink is
# suite-local because the test changes its response delay in place.
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init slow "${1:-}"
PORT="${2:-9498}"
SINK=pglogtap-slow-${PG_CT#pglogtap-}
FB_REL="pg_logtap-slow$SUF.bin"
producer_app="logtap-slow-producer$SUF"
producer_pid=''
e2e_gate
STATE="$OUT/slow-state$SUF"
(umask 077; mkdir "$STATE") || fail "slow receiver: could not create private state directory"
restore_ready=0
FB_DIR=''

# socat forks per connection; each child reads the current delay from a mounted
# file. Changing that file preserves the container name/IP and existing worker
# state, unlike replacing the sink at the slow→fast transition.
up_sink() { # $1 = seconds to delay subsequent responses
  printf '%s\n' "$1" > "$STATE/delay"
  [ "$(docker inspect -f '{{.State.Status}}' "$SINK" 2>/dev/null)" = running ] && return 0
  docker rm -f "$SINK" >/dev/null 2>&1
  docker run -d --name "$SINK" --network "$NET" -v "$STATE:/state:ro" alpine/socat \
    "TCP-LISTEN:$PORT,reuseaddr,fork" \
    SYSTEM:"(sleep \$(cat /state/delay); printf 'HTTP/1.0 200 OK\r\n\r\n') & cat >/dev/null" >/dev/null \
    || fail "slow receiver: could not start suite-local sink"
  sleep 1
}
stop_producer() {
  [ -n "$producer_pid" ] || return 0
  docker exec "$PG_CT" psql -U postgres -Atc \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$producer_app'" \
    >/dev/null 2>&1 || return 1
  wait "$producer_pid" 2>/dev/null || true # terminated psql normally exits nonzero
  producer_pid=''
}
cleanup() {
  cleanup_status=$?
  trap - EXIT
  cleanup_failed=0
  restore_failed=0
  stop_producer || cleanup_failed=1
  if [ "$restore_ready" = 1 ]; then
    docker exec -i "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 \
      < "$STATE/restore.sql" >/dev/null || restore_failed=1
    reload || restore_failed=1
    sleep 1
  fi
  if docker inspect "$SINK" >/dev/null 2>&1; then
    docker rm -f "$SINK" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [ "$restore_failed" = 0 ]; then
    rm -f "$STATE/restore.sql" || cleanup_failed=1
  else
    echo "e2e-slow: cleanup could not restore GUCs; recovery SQL: $STATE/restore.sql" >&2
    cleanup_failed=1
  fi
  if [ "$cleanup_status" = 0 ] && [ "$cleanup_failed" = 0 ] && [ -n "$FB_DIR" ]; then
    docker exec "$PG_CT" rm -f "$FB_DIR/$FB_REL" || cleanup_failed=1
  fi
  rm -f "$STATE/delay" || cleanup_failed=1
  if [ "$restore_failed" = 0 ]; then
    rmdir "$STATE" || cleanup_failed=1
  fi
  if [ "$cleanup_failed" != 0 ]; then
    echo "e2e-slow: cleanup failed" >&2
    [ "$cleanup_status" != 0 ] || cleanup_status=1
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
# A hard-killed prior run cannot execute its trap; discard its sink because it
# is mounted to that run's PID-specific state directory.
docker rm -f "$SINK" >/dev/null 2>&1
backlog_now() {
  docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery"
}

FB_DIR=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW data_directory") \
  || fail "slow receiver: could not read data directory"
# Save every setting this suite changes, before even a partial setup can fail.
# current_setting preserves units; format quotes regexes and URLs as SQL values.
docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -Atc "
  SELECT format('ALTER SYSTEM SET %s = %L;', name, current_setting(name))
    FROM unnest(ARRAY[
      'pg_logtap.pattern', 'pg_logtap.pattern_exclude', 'pg_logtap.redact_pattern',
      'pg_logtap.level_min', 'pg_logtap.flush_interval', 'pg_logtap.export_slow_ms',
      'pg_logtap.export_timeout_ms', 'pg_logtap.export_backlog_max',
      'pg_logtap.export_fallback_file', 'pg_logtap.fallback_max_mb',
      'pg_logtap.export_gzip', 'pg_logtap.metrics_port', 'pg_logtap.export_url'
    ]) AS gucs(name)" > "$STATE/restore.sql" \
  || fail "slow receiver: could not snapshot GUCs"
restore_ready=1
docker exec "$PG_CT" rm -f "$FB_DIR/$FB_REL" || fail "slow receiver: could not clear suite fallback"
setguc pg_logtap.pattern '' || fail "slow receiver: could not reset pattern"
setguc pg_logtap.pattern_exclude '' || fail "slow receiver: could not reset exclude pattern"
setguc pg_logtap.redact_pattern '' || fail "slow receiver: could not reset redact pattern"
setguc pg_logtap.level_min 19 || fail "slow receiver: could not set capture level"
setguc pg_logtap.flush_interval 100 || fail "slow receiver: could not set flush interval"
setguc pg_logtap.export_slow_ms 250 || fail "slow receiver: could not set slow threshold"
setguc pg_logtap.export_timeout_ms 3000 || fail "slow receiver: could not set timeout"
setguc pg_logtap.export_backlog_max 65536 || fail "slow receiver: could not set RAM backlog"
setguc pg_logtap.export_fallback_file "$FB_REL" || fail "slow receiver: could not set fallback file"
setguc pg_logtap.fallback_max_mb 64 || fail "slow receiver: could not bound fallback file"
setguc pg_logtap.export_gzip off || fail "slow receiver: could not disable gzip"
setguc pg_logtap.metrics_port 9187 || fail "slow receiver: could not enable metrics"
up_sink 1
setguc pg_logtap.export_url "http://$SINK:$PORT" || fail "slow receiver: could not set sink URL"
reload || fail "slow receiver: reload failed"
sleep 1
bque=$(statf events_queued)
brep=$(statf events_replayed)
bdrp=$(statf events_dropped)
blost=$(statf events_lost)

# One backend emits steadily for long enough to span the slow answer, its 10x
# cooldown, and fast recovery. The sink discards bodies, so this test asserts
# queue/counter behavior rather than ordering or duplicate content.
docker exec -e "PGAPPNAME=$producer_app" "$PG_CT" psql -U postgres -v ON_ERROR_STOP=1 -qc "
  DO \$\$ DECLARE
    stop_at timestamptz := clock_timestamp() + interval '30 seconds';
    i bigint := 0;
  BEGIN
    WHILE clock_timestamp() < stop_at LOOP
      RAISE WARNING 'slow receiver continuous %', i;
      i := i + 1;
      PERFORM pg_sleep(0.01);
    END LOOP;
  END \$\$" >/dev/null 2>&1 &
producer_pid=$!

backlog=0
n=0
while [ "$n" -lt 20 ]; do
  backlog=$(backlog_now)
  [ "$backlog" -gt 0 ] && break
  n=$((n + 1)); sleep 1
done
[ "$backlog" -gt 0 ] || fail "slow receiver: live traffic never entered the fallback queue"
kill -0 "$producer_pid" 2>/dev/null || fail "slow receiver: producer ended before recovery transition"
healthz=$(docker exec "$PG_CT" bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/9187 && printf "GET /healthz HTTP/1.0\r\n\r\n" >&3 && IFS= read -r -t 8 line <&3 && echo "$line"' \
  2>/dev/null)
[ -n "$healthz" ] || fail "slow receiver: worker stopped serving healthz while parking"

queued_before=$backlog
up_sink 0
decreased=0
drained_while_live=0
n=0
while [ "$n" -lt 25 ]; do
  current=$(backlog_now)
  [ "$current" -lt "$queued_before" ] && decreased=1
  if [ "$current" = 0 ]; then
    kill -0 "$producer_pid" 2>/dev/null \
      || fail "slow receiver: queue drained only after continuous input stopped"
    drained_while_live=1
    break
  fi
  kill -0 "$producer_pid" 2>/dev/null \
    || fail "slow receiver: producer ended before queue recovery"
  n=$((n + 1)); sleep 1
done
[ "$decreased" = 1 ] || fail "slow receiver: backlog never decreased after sink recovery"
[ "$drained_while_live" = 1 ] || fail "slow receiver: backlog did not reach zero under continuous input"

stop_producer || fail "slow receiver: could not stop producer"
drain_ring
n=0
while [ "$n" -lt 20 ]; do
  [ "$(backlog_now)" = 0 ] && break
  n=$((n + 1)); sleep 1
done
[ "$(backlog_now)" = 0 ] || fail "slow receiver: queue refilled or remained after producer stop"
queued=$(( $(statf events_queued) - bque ))
replayed=$(( $(statf events_replayed) - brep ))
dropped=$(( $(statf events_dropped) - bdrp ))
lost=$(( $(statf events_lost) - blost ))
[ "$queued" -gt 0 ] || fail "slow receiver: no events were counted queued"
[ "$replayed" -gt 0 ] || fail "slow receiver: no queued events were replayed"
[ "$dropped" = 0 ] || fail "slow receiver: events_dropped increased by $dropped"
[ "$lost" = 0 ] || fail "slow receiver: events_lost increased by $lost"
ok "backlog $queued_before→0 while producer stayed active; queued=$queued replayed=$replayed lost=0 dropped=0"
