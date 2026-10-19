#!/usr/bin/env bash
# Formal overhead benchmark: pgbench OLTP before/after the extension (docs/bench.md).
# Six measured jobs on one stand — identical hardware, fixed seed, warmup
# before each:
#   off-quiet / on-quiet — default logging (log_min_messages=warning, no
#                          statement logging): typical production shape; the
#                          delta is the hook cost when the filter rejects
#                          nearly everything
#   off-loud  / on-loud  — debug1 + log_min_duration_statement=0: every
#                          statement captured and exported; delta = worst
#                          case, and on-loud yields events/s, worker RSS and
#                          capture→receiver latency percentiles
#   off-mute  / on-mute  — same loud config with log_destination='' (valid;
#                          mutes the server's own stderr, emit_log_hook still
#                          fires): the delta is pg_logtap with zero
#                          stderr-logging cost in either job
# Logging flips need only a reload; preload swaps need restarts, so each
# preload state runs its jobs back to back.
# Usage: benchmarks/bench-overhead.sh [secs] [container]   (default 300s per job)
# Needs the stand from test-matrix.sh phase_stand (so deployed). The CPU
# governor must be `performance` — a scaling governor halves TPS on developer
# boxes and the numbers become garbage (checked below).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tests/e2e/e2e-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../tests/e2e/e2e-common.sh"

cleanup() { docker rm -f "$RX" >/dev/null 2>&1 || true; }

wait_ready() {
  for _ in $(seq 1 60); do
    docker exec "$C" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "pg in $C not ready after 60s" >&2; return 1
}

set_preload() { # <''|pg_logtap>
  unset E2E_EXPORT_EPOCH # the existing restart starts a new counter epoch
  # '' as an explicit SET is a postmaster FATAL (dlopen "" — the default and
  # an empty SET are not the same), so the off-job RESETs the entry instead.
  if [ -n "$1" ]; then
    docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET shared_preload_libraries = '$1'" >/dev/null
  else
    docker exec "$C" psql -U postgres -qc "ALTER SYSTEM RESET shared_preload_libraries" >/dev/null
  fi
  docker restart "$C" >/dev/null; wait_ready
}

set_logging() { # <quiet|loud>
  if [ "$1" = quiet ]; then
    docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_min_messages = 'warning'" \
      -qc "ALTER SYSTEM SET log_min_duration_statement = -1" \
      -qc "ALTER SYSTEM SET pg_logtap.level_min = 15" >/dev/null
  else
    docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_min_messages = 'debug1'" \
      -qc "ALTER SYSTEM SET log_min_duration_statement = 0" \
      -qc "ALTER SYSTEM SET pg_logtap.level_min = 10" >/dev/null
  fi
  docker exec "$C" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 2
}

set_mute() { # <on|off>: '' is a valid log_destination and mutes the server's
  # own output while emit_log_hook still fires — the mute jobs below compare
  # full capture+export against a server that writes nothing at all.
  if [ "$1" = on ]; then
    docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_destination = ''" >/dev/null
  else
    docker exec "$C" psql -U postgres -qc "ALTER SYSTEM RESET log_destination" >/dev/null
  fi
  docker exec "$C" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 2
}

# One measured job: warmup run, then T seconds with the container CPU sampled
# alongside it. Appends "tag tps lat_ms cpu_pct" lines to $OUT/jobs.
run_job() ( # <tag> [warmed]: run_loud owns its warmup/counter boundary
  samp='' work=''
  trap '[ -z "$samp" ] || { kill "$samp" 2>/dev/null || true; wait "$samp" 2>/dev/null || true; }; [ -z "$work" ] || { kill "$work" 2>/dev/null || true; wait "$work" 2>/dev/null || true; }' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ "${2:-}" != warmed ]; then
    if [ "$1" = on-mute ]; then e2e_drain_export || exit 1; fi
    docker exec "$C" pgbench -U postgres -c 8 -j 2 -T "$WARMUP" --random-seed=$SEED postgres >/dev/null 2>&1 || exit $?
    # on-loud drains in run_loud; on-mute is the other exporting profile.
    if [ "$1" = on-mute ]; then e2e_drain_export || exit 1; fi
  fi
  docker exec "$C" pgbench -U postgres -c 8 -j 2 -T "$SECS" --random-seed=$SEED postgres > "$OUT/pgbench" 2>&1 &
  work=$!
  e2e_sample_cpu "$work" "$OUT/cpu" &
  samp=$!
  wait "$work" || exit $?
  work=
  kill "$samp" 2>/dev/null || true
  wait "$samp" 2>/dev/null || true
  samp=
  tps=$(awk '/^tps = / {print $3}' "$OUT/pgbench" | tail -1)
  lat=$(awk '/^latency average = / {print $4}' "$OUT/pgbench" | tail -1)
  cpu=$(awk '{s += $1} END {if (n = NR) printf "%.0f", s / n}' "$OUT/cpu")
  echo "$1 $tps $lat $cpu" >> "$OUT/jobs"
  echo "  $1: tps=$tps lat=${lat}ms cpu=${cpu}%"
)

stats_field() { # <name> — value from pg_logtap_stats()
  docker exec "$C" psql -U postgres -Atc "SELECT pg_logtap_stats()" | sed "s/.*$1=\([0-9]*\).*/\1/"
}

run_loud() (
e2e_drain_export || exit 1
docker exec "$C" pgbench -U postgres -c 8 -j 2 -T "$WARMUP" --random-seed=$SEED postgres >/dev/null 2>&1 || exit $?
e2e_drain_export || exit 1
base_cap=$(stats_field events_captured)
base_snt=$(stats_field events_sent)
base_drp=$(stats_field events_dropped)
latency_since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
run_job on-loud warmed || exit $?
e2e_drain_export || exit 1

cap=$(( $(stats_field events_captured) - base_cap ))
drp=$(( $(stats_field events_dropped) - base_drp ))
snt=$(( $(stats_field events_sent) - base_snt ))
rss=$(docker exec "$C" ps -eo rss=,args= | awk '/pg_logtap exporter/ {print $1; exit}')
echo "  events/s=$((cap / SECS)) captured=$cap dropped=$drp sent=$snt worker_rss=$((rss / 1024))MB"

echo "-- latency capture→receiver (on-loud)"
docker logs --since "$latency_since" "$RX" 2>/dev/null | grep -E '^[0-9.]+$' | python3 -c '
import sys
v = sorted(float(x) for x in sys.stdin)
if not v:
    raise SystemExit("no latency samples")
p = lambda q: v[min(len(v) - 1, int(q * len(v)))]
print("  n=%d p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms" % (len(v), p(0.5), p(0.95), p(0.99), v[-1]))
'
)

main() {
  set -euo pipefail
  cd "$(dirname "$0")/.."
  SECS=${1:-300}
  C=${2:-pglogtap-mx18}
  E2E_CT=$C E2E_TAG=bench
  unset E2E_EXPORT_EPOCH # never trust inherited provenance
  e2e_lock || return 1
  WARMUP=30
  SEED=20260825
  RX=pglogtap-bench-rx          # one-shot latency receiver, removed on exit
  NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$C")
  OUT=/tmp/logtap-bench
  mkdir -p "$OUT"
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    [ "$gov" = performance ] || echo "WARNING: cpu governor='$gov' — set performance or the TPS deltas are garbage" >&2
  fi
  trap cleanup EXIT

  echo "== pg_logtap overhead benchmark: $(date -u +%FT%TZ) secs=$SECS commit=$(git rev-parse --short HEAD) arch=$(uname -m) =="
: > "$OUT/jobs"
docker exec "$C" pgbench -i -q -s 8 -U postgres postgres >/dev/null 2>&1

echo "-- preload off"
set_preload ""
set_logging quiet; run_job off-quiet
set_logging loud;  run_job off-loud
set_mute on;       run_job off-mute
set_mute off # the ALTER SYSTEM entry would survive the restart below

echo "-- preload on"
set_preload pg_logtap
docker exec "$C" psql -U postgres -qc "CREATE EXTENSION IF NOT EXISTS pg_logtap" >/dev/null
# Latency receiver: stamps arrival time per event line, prints per-event
# (arrival − event timestamp) in ms to its docker logs.
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
set_logging quiet
e2e_export_begin || return 1
docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = ''" \
  -qc "SELECT pg_reload_conf()" >/dev/null
run_job on-quiet
set_logging loud
docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$RX:8687'" \
  -qc "SELECT pg_reload_conf()" >/dev/null
run_loud
# Last job: same loud config with the server's own stderr muted — on-mute −
# off-mute isolates pg_logtap with zero stderr-logging cost in either job.
# export_url stays pointed at the receiver from on-loud (docker logs is read
# above, before this job's samples can mix in).
set_mute on; run_job on-mute
set_mute off

echo "-- summary (tps / txn latency / container cpu)"
column -t "$OUT/jobs" 2>/dev/null || cat "$OUT/jobs"

# Leave the stand in its matrix shape: extension loaded, vector receiver.
set_logging quiet
docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector:8686'" \
  -qc "SELECT pg_reload_conf()" >/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
