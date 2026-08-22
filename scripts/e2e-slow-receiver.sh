#!/bin/sh
# Acceptance: a receiver that answers but slowly (each response >=
# pg_logtap.export_slow_ms) must not decide what gets lost: while it stays
# slow, live batches park on the fallback file (lossless) instead of filling
# the RAM backlog; once it answers fast again, the queue drains in order.
# Without export_slow_ms such a receiver trimmed the RAM backlog
# oldest-first (events_lost > 0 under load); without the cycle deadline the
# worker loop itself stalled behind every slow round trip.
# Usage: scripts/e2e-slow-receiver.sh [pg_container] [sink_port]
set -eu
PG_CT="${1:-pglogtap-pg}"
PORT="${2:-9498}"
NET=logtap-e2e
SINK=pglogtap-slow

docker network create "$NET" >/dev/null 2>&1 || true
docker network connect "$NET" "$PG_CT" 2>/dev/null || true

# socat forks per connection; the background (sleep N; printf) answers with a
# bare 200 after N seconds while `cat` drains the request body. N=1: every
# send succeeds (failure path never fires) yet every send is "slow".
up_sink() { # $1 = seconds to delay the response
  docker rm -f "$SINK" >/dev/null 2>&1 || true
  docker run -d --name "$SINK" --network "$NET" alpine/socat \
    TCP-LISTEN:$PORT,reuseaddr,fork \
    SYSTEM:"(sleep $1; printf 'HTTP/1.0 200 OK\r\n\r\n') & cat >/dev/null" >/dev/null
  sleep 1
}
cleanup() { docker rm -f "$SINK" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 250ms slow threshold, 1s answers, 3s hard timeout.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_slow_ms = 250" \
  -qc "ALTER SYSTEM SET pg_logtap.export_timeout_ms = 3000" \
  -qc "ALTER SYSTEM SET pg_logtap.export_fallback_file = 'pg_logtap-fallback.bin'" \
  -qc "ALTER SYSTEM SET pg_logtap.metrics_port = 9187" \
  -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$SINK:$PORT'" \
  -qc "SELECT pg_reload_conf()" >/dev/null

base=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()")
bque=${base#*events_queued=}; bque=${bque%% *}
brep=${base#*events_replayed=}; brep=${brep%% *}
bdrp=${base#*events_dropped=}; bdrp=${bdrp%% *}
blost=${base#*events_lost=}; blost=${blost%% *}
bsent=${base#*events_sent=}; bsent=${bsent%% *}

# --- phase A: slow but answering ------------------------------------------
up_sink 1
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN FOR i IN 1..400 LOOP RAISE WARNING 'slow receiver e2e %', i; END LOOP; END \$\$" >/dev/null 2>&1
sleep 8

st=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()")
que=${st#*events_queued=}; que=${que%% *}
sent=${st#*events_sent=}; sent=${sent%% *}
drp=${st#*events_dropped=}; drp=${drp%% *}; drp=$((drp - bdrp))
lost=${st#*events_lost=}; lost=${lost%% *}; lost=$((lost - blost))
que=$((que - bque)); sent=$((sent - bsent))

# The loop must keep serving between slow sends (cycle deadline), and the
# bash read -t pattern is deliberate — see e2e-silent-receiver.sh.
healthz=$(docker exec "$PG_CT" bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/9187 && printf "GET /healthz HTTP/1.0\r\n\r\n" >&3 && IFS= read -r -t 8 line <&3 && echo "$line"' \
  2>/dev/null || true)

echo "  phaseA: parked=$que sent=$sent dropped=$drp lost=$lost healthz=${healthz:-none}"
[ "$que" -ge 1 ] && [ "$drp" -eq 0 ] && [ "$lost" -eq 0 ] && [ -n "$healthz" ]

# --- phase B: receiver speeds up, the queue drains in order ---------------
up_sink 0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  bl=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
  [ "$bl" = 0 ] && break
  sleep 1
done
st=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()")
rep=${st#*events_replayed=}; rep=${rep%% *}; rep=$((rep - brep))
lost=${st#*events_lost=}; lost=${lost%% *}; lost=$((lost - blost))
bl2=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
echo "  phaseB: replayed=$rep backlog=$bl2 lost=$lost"
[ "$rep" -ge "$que" ] && [ "$bl2" = 0 ] && [ "$lost" -eq 0 ]
