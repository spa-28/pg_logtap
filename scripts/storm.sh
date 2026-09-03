#!/usr/bin/env bash
# Single-job log storm, self-contained: builds the CURRENT tree, brings up
# the e2e stand's pg, deploys, installs, runs pgbench under it, reports
# health per mode — TPS, events/s, exact delivery, worker RSS, capture→
# receiver latency percentiles. The modes are the "extension on" profiles
# from scripts/bench-overhead.sh (docs/bench.md):
#   loud  — debug1 + every statement duration-logged, level_min=10: worst
#           case, every statement captured and exported
#   quiet — warning, no statement logging, level_min=15: typical production,
#           the hook rejects nearly everything
#   mute  — the loud config with log_destination='' (valid; mutes the
#           server's own stderr while emit_log_hook still fires): isolates
#           pg_logtap's cost from the server's own logging
# The benchmark's off/jobs (extension not loaded) are deliberately not here:
# without a baseline run there is nothing to compare them against — use
# bench-overhead.sh for that. No baseline jobs, so one run answers "how does
# the build behave under a storm" in ~7 min per mode; modes share one stand
# (a mode flip is a reload, no restarts).
# The stand is LEFT UP for post-mortem; the teardown line prints at the end.
# Usage: scripts/storm.sh [secs] [pg_major] [modes]   (default 300 18 loud)
# The CPU governor must be `performance` (checked; a scaling governor halves
# TPS on developer boxes).
set -euo pipefail
cd "$(dirname "$0")/.."
SECS=${1:-300}
V=${2:-18}
MODES=${3:-loud}
C=pglogtap-mx$V
WARMUP=30
SEED=20260825
RX=pglogtap-storm-rx
COMPOSE="docker compose -f tests/e2e/compose.yaml"
OUT=/tmp/logtap-storm
mkdir -p "$OUT"

case "$(uname -m)" in
  x86_64)  ZIG_TARGET="x86_64-linux-gnu.2.28" ;;
  aarch64) ZIG_TARGET="aarch64-linux-gnu.2.28" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
  [ "$gov" = performance ] || echo "WARNING: cpu governor='$gov' — set performance or the numbers are garbage" >&2
fi

wait_ready() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  echo "pg in $C not ready after 120s" >&2
  docker logs --tail 40 "$C" >&2 || true
  return 1
}

stats_field() { # <name> — value from pg_logtap_stats()
  docker exec "$C" psql -U postgres -Atc "SELECT pg_logtap_stats()" | sed "s/.*$1=\([0-9]*\).*/\1/"
}

# Every knob is assigned explicitly (nothing toggled), so a rerun reproduces
# the mode from any stand state. ALTER SYSTEM one statement per -qc.
set_mode() { # <loud|quiet|mute>
  local msg_min=warning lvl=15 dest=stderr
  case $1 in
    loud | mute) msg_min=debug1 lvl=10 ;;
    quiet) ;;
    *) echo "unknown mode '$1' (loud|quiet|mute)" >&2; exit 1 ;;
  esac
  local dur=-1
  [ "$msg_min" = debug1 ] && dur=0
  [ "$1" = mute ] && dest=""
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_min_messages = '$msg_min'" \
    -qc "ALTER SYSTEM SET log_min_duration_statement = $dur" \
    -qc "ALTER SYSTEM SET pg_logtap.level_min = $lvl" \
    -qc "ALTER SYSTEM SET log_destination = '$dest'" \
    -qc "SELECT pg_reload_conf()" >/dev/null
}

# One-shot latency receiver: stamps arrival time per event line against each
# event's timestamp. Recreated per mode so the docker-logs samples never mix.
start_rx() {
  docker rm -f "$RX" >/dev/null 2>&1 || true
  docker run -d --rm --name "$RX" --network "$NET" python:3-alpine python -u -c '
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import time
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        now = time.time()
        out = []
        for line in body.split(b"\n"):
            i = line.find(b"\"timestamp\":\"")
            if i < 0:
                continue
            ts = datetime.fromisoformat(line[i + 13:line.find(b"\"", i + 13)].decode())
            if ts.tzinfo is None:  # PG timestamps are UTC; naive .timestamp() would read local
                ts = ts.replace(tzinfo=timezone.utc)
            out.append(str((now - ts.timestamp()) * 1000.0))
        if out:
            print("\n".join(out), flush=True)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
HTTPServer(("0.0.0.0", 8687), H).serve_forever()
' >/dev/null
  sleep 2
}

echo "== storm: $(date -u +%FT%TZ) secs=$SECS modes=$MODES commit=$(git rev-parse --short HEAD) pg$V =="

echo "-- build (ReleaseSafe, release target)"
if command -v pg_config >/dev/null 2>&1; then
  zig build -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe -p "dist/pg$V"
else
  scripts/build.sh "$V" -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe >/dev/null
  mkdir -p "dist/pg$V/lib" && cp zig-out/lib/pg_logtap.so "dist/pg$V/lib/"
fi

echo "-- stand: pg first and alone, then the receivers"
# The service container may live under another major's name from a previous
# run (compose tracks project+service, not the container name): remove by
# label so `up` always creates fresh, with a fresh data volume.
docker ps -aq --filter "label=com.docker.compose.project=pglogtap-e2e" \
  --filter "label=com.docker.compose.service=pg" \
  | xargs -r docker rm -f -v >/dev/null 2>&1 || true
docker rm -f -v "$C" >/dev/null 2>&1 || true
PG_MAJOR=$V PG_CT=$C $COMPOSE up -d --no-deps pg >/dev/null
wait_ready
PG_MAJOR=$V PG_CT=$C $COMPOSE up -d >/dev/null
wait_ready
NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$C")

echo "-- deploy"
LIBDIR=$(docker exec "$C" pg_config --pkglibdir)
EXTDIR=$(docker exec "$C" pg_config --sharedir)/extension
docker cp "dist/pg$V/lib/pg_logtap.so" "$C:$LIBDIR/"
docker cp pg_logtap.control "$C:$EXTDIR/"
for f in sql/*.sql; do docker cp "$f" "$C:$EXTDIR/"; done
# Two restarts, as in the matrix stand: core GUCs need the library loaded
# before custom ones exist (PG<=16 rejects ALTER SYSTEM on unknown GUCs).
docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'" \
  -qc "ALTER SYSTEM SET cluster_name = 'storm-pg$V'" >/dev/null
docker restart "$C" >/dev/null; wait_ready
docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.ring_capacity = 8192" \
  -qc "ALTER SYSTEM SET pg_logtap.flush_interval = 100" >/dev/null
docker restart "$C" >/dev/null; wait_ready
docker exec "$C" psql -U postgres -qc "CREATE EXTENSION pg_logtap" >/dev/null
echo "  version: $(docker exec "$C" psql -U postgres -Atc 'SELECT pg_logtap_version()')"

docker exec "$C" pgbench -i -q -s 8 -U postgres postgres >/dev/null 2>&1

for mode in ${MODES//,/ }; do
  echo "== mode=$mode: warmup ${WARMUP}s (discarded) + storm ${SECS}s =="
  set_mode "$mode"
  start_rx
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$RX:8687'" \
    -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 2

  docker exec "$C" pgbench -U postgres -c 8 -j 2 -T "$WARMUP" --random-seed=$SEED postgres >/dev/null 2>&1
  base_cap=$(stats_field events_captured); base_snt=$(stats_field events_sent)
  base_drp=$(stats_field events_dropped);  base_lst=$(stats_field events_lost)

  : > "$OUT/cpu.$mode"
  # --no-stream per sample: streaming docker stats decorates output with
  # terminal control codes even off-tty, which poisons the average.
  ( for _ in $(seq "$SECS"); do
      docker stats --no-stream --format '{{.CPUPerc}}' "$C" || true
      sleep 1
    done ) > "$OUT/cpu.$mode" &
  samp=$!
  res=$(docker exec "$C" pgbench -U postgres -c 8 -j 2 -T "$SECS" -s 8 --random-seed=$SEED postgres 2>&1)
  kill "$samp" 2>/dev/null || true # docker stats takes ~1-2s a call: the loop overruns the storm
  wait "$samp" 2>/dev/null || true
  sleep 5 # drain

  echo "$res" | grep -E "^tps = |^latency average = " | head -2
  cpu=$(awk '{s += $1} END {if (n = NR) printf "%.0f", s / n}' "$OUT/cpu.$mode")
  cap=$(( $(stats_field events_captured) - base_cap ))
  drp=$(( $(stats_field events_dropped) - base_drp ))
  lst=$(( $(stats_field events_lost) - base_lst ))
  snt=$(( $(stats_field events_sent) - base_snt ))
  rss=$(docker exec "$C" ps -eo rss=,args= | awk '/pg_logtap exporter/ {print $1; exit}')
  echo "RESULT[$mode] events/s=$((cap / SECS)) captured=$cap sent=$snt dropped=$drp lost=$lst worker_rss=$((rss / 1024))MB cpu=${cpu}%"

  docker logs "$RX" 2>/dev/null | grep -E '^[0-9.]+$' > "$OUT/lat.$mode"
  # quiet legitimately captures nothing the receiver would see — no samples
  # is the expected outcome there, not an error
  python3 - "$OUT/lat.$mode" <<'PYEOF'
import sys
v = sorted(float(x) for x in open(sys.argv[1]))
if not v:
    print("RESULT[%s] lat n=0 (no events reached the receiver)" % sys.argv[1].rsplit(".", 1)[-1])
else:
    p = lambda q: v[min(len(v) - 1, int(q * len(v)))]
    print("RESULT[%s] lat n=%d p50=%.1fms p95=%.1fms p99=%.1fms p99.9=%.1fms"
          % (sys.argv[1].rsplit(".", 1)[-1], len(v), p(0.5), p(0.95), p(0.99), p(0.999)))
PYEOF
done

echo "-- restore quiet config"
docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_min_messages = 'warning'" \
  -qc "ALTER SYSTEM SET log_min_duration_statement = -1" \
  -qc "ALTER SYSTEM SET pg_logtap.level_min = 15" \
  -qc "ALTER SYSTEM RESET log_destination" \
  -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector:8686'" \
  -qc "SELECT pg_reload_conf()" >/dev/null
docker rm -f "$RX" >/dev/null 2>&1 || true
echo "stand left up for post-mortem: $C (+compose receivers)"
echo "teardown: docker rm -f $C && $COMPOSE down"
