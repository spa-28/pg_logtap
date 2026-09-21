#!/bin/sh
# Acceptance: a receiver that accepts the TCP connection but never answers
# must fail the send after pg_logtap.export_timeout_ms instead of hanging
# the worker loop. Repeated SIGHUP must not restart a stale relative
# SO_RCVTIMEO after EINTR and stretch one attempt past its absolute deadline.
# Without the fixes the first status-line recv blocks forever (or until the
# signal storm stops): no timely failed cycle, nothing diverts to fallback,
# and /healthz is never served again — all asserted here.
# Usage: scripts/e2e-silent-receiver.sh [pg_container] [sink_port]
# The mute receiver is the compose stand's `silent` service.
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init silent "${1:-}"
PORT="${2:-9499}"
SINK=pglogtap-silent
e2e_gate

# 1s timeout, fallback file on: failed sends must divert, not lose.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_timeout_ms = 1000" \
  -qc "ALTER SYSTEM SET pg_logtap.flush_interval = 100" \
  -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'" \
  -qc "ALTER SYSTEM SET pg_logtap.metrics_port = 9187" \
  -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$SINK:$PORT'" \
  -qc "SELECT pg_reload_conf()" >/dev/null
sleep 2

base=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()")
bfail=${base#*send_cycles_failed=}; bfail=${bfail%% *}
bque=${base#*events_queued=}; bque=${bque%% *}
bdrp=${base#*events_dropped=}; bdrp=${bdrp%% *}
blost=${base#*events_lost=}; blost=${blost%% *}

wpid=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$wpid" ] || fail "silent receiver: worker not found"
started_ms=$(date +%s%3N)
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN FOR i IN 1..300 LOOP RAISE WARNING 'silent receiver e2e %', i; END LOOP; END \$\$" >/dev/null 2>&1
sleep 0.2 # flush_interval=100ms: let the worker enter the blocked status recv
(
  i=0
  while [ "$i" -lt 40 ]; do
    docker exec "$PG_CT" kill -HUP "$wpid" >/dev/null 2>&1 || true
    i=$((i + 1))
    sleep 0.1
  done
) &
storm_pid=$!

# The first attempt must expire under its original one-second budget while the
# longer HUP storm is still interrupting recv. Before the fix every EINTR
# retried with the stale one-second SO_RCVTIMEO and this transition waited
# until the storm ended plus one final full timeout.
failed_at_ms=0
storm_active=0
n=0
while [ "$n" -lt 30 ]; do
  if [ "$(statf send_cycles_failed)" -gt "$bfail" ]; then
    failed_at_ms=$(date +%s%3N)
    kill -0 "$storm_pid" 2>/dev/null && storm_active=1
    break
  fi
  n=$((n + 1))
  sleep 0.1
done
wait "$storm_pid"
[ "$failed_at_ms" -gt 0 ] || fail "silent receiver: no failed cycle within 3s under repeated SIGHUP"
elapsed_ms=$((failed_at_ms - started_ms))
[ "$storm_active" = 1 ] || fail "silent receiver: first failed cycle appeared only after the SIGHUP storm ended (${elapsed_ms}ms)"
[ "$elapsed_ms" -le 2500 ] || fail "silent receiver: first failed cycle took ${elapsed_ms}ms, beyond the one-second attempt budget"
failure_line=$(docker logs "$PG_CT" 2>&1 | grep "pg_logtap export failing (" | tail -1)
case "$failure_line" in
  *"status read errno=0"*|*"status read errno=4"*)
    fail "silent receiver: helper-owned deadline reason overwritten by stale errno: $failure_line" ;;
esac

stats=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()")
echo "  $stats"
fail=${stats#*send_cycles_failed=}; fail=${fail%% *}
que=${stats#*events_queued=}; que=${que%% *}
drp=${stats#*events_dropped=}; drp=${drp%% *}
lost=${stats#*events_lost=}; lost=${lost%% *}
fail=$((fail - bfail)); que=$((que - bque)); drp=$((drp - bdrp)); lost=$((lost - blost))

# Scrape happens between flush cycles; worst case one in-flight send timeout
# delays it. bash read -t on purpose — an external `timeout` SIGTERMs its
# process, and the postmaster (PID 1 in a container) emergency-restarts the
# whole cluster when it reaps an unknown signalled child: a container
# footgun that looks exactly like an extension crash. On unfixed code the
# read times out (status >128, no signal escapes).
healthz=$(docker exec "$PG_CT" bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/9187 && printf "GET /healthz HTTP/1.0\r\n\r\n" >&3 && IFS= read -r -t 8 line <&3 && echo "$line"' \
  2>/dev/null)

echo "first_failed_ms=$elapsed_ms failed_cycles=$fail queued=$que dropped=$drp lost=$lost healthz=${healthz:-none}"
[ "$fail" -ge 1 ] && [ "$que" -ge 1 ] && [ "$drp" -eq 0 ] && [ "$lost" -eq 0 ] && [ -n "$healthz" ]
