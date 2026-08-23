#!/bin/sh
# Acceptance: a receiver that accepts the TCP connection but never answers
# must fail the send after pg_logtap.export_timeout_ms instead of hanging
# the worker loop (SO_RCVTIMEO/SO_SNDTIMEO in dialTcp).
# Without the fix the first status-line recv blocks forever: no failed
# cycles, nothing diverts to the fallback file, and /healthz is never
# served again — all three asserted here.
# Usage: scripts/e2e-silent-receiver.sh [pg_container] [sink_port]
# The mute receiver is the compose stand's `silent` service.
set -eu
PG_CT="${1:-pglogtap-pg}"
PORT="${2:-9499}"
NET=pglogtap-e2e_default
SINK=pglogtap-silent

[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] || {
  echo "e2e-silent: stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d" >&2
  exit 1
}
docker network connect "$NET" "$PG_CT" 2>/dev/null || true # non-stand pg arg

# 1s timeout, fallback file on: failed sends must divert, not lose.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_timeout_ms = 1000" \
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

docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN FOR i IN 1..300 LOOP RAISE WARNING 'silent receiver e2e %', i; END LOOP; END \$\$" >/dev/null 2>&1
# 4x the timeout: enough for several full cycles (drain, timed-out send, divert).
sleep 4

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
# read times out (status >128, no signal escapes) — captured via || true.
healthz=$(docker exec "$PG_CT" bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/9187 && printf "GET /healthz HTTP/1.0\r\n\r\n" >&3 && IFS= read -r -t 8 line <&3 && echo "$line"' \
  2>/dev/null || true)

echo "failed_cycles=$fail queued=$que dropped=$drp lost=$lost healthz=${healthz:-none}"
[ "$fail" -ge 1 ] && [ "$que" -ge 1 ] && [ "$drp" -eq 0 ] && [ "$lost" -eq 0 ] && [ -n "$healthz" ]
