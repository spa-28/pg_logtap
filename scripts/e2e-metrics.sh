#!/bin/sh
# M4 acceptance: worker serves /metrics; Vector prometheus_scrape reads it.
# Usage: scripts/e2e-metrics.sh [pg_container] [port]
set -eu
PG_CT="${1:-pglogtap-pg}"
PORT="${2:-9187}"
OUT=/tmp/logtap-metrics/vector-metrics.jsonl
NET=pglogtap-e2e_default

# Its own throwaway Vector (a scrape config, unlike the stand's receiver).
[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] || {
  echo "e2e-metrics: stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d" >&2
  exit 1
}
# A stale .so (copied without a restart) would test yesterday's code.
"$(dirname "$0")/e2e-require-ext.sh" "$PG_CT"
docker network connect "$NET" "$PG_CT" 2>/dev/null || true # non-stand pg arg
docker rm -f pglogtap-vector-metrics >/dev/null 2>&1 || true
mkdir -p /tmp/logtap-metrics
: > "$OUT" # fresh scrape log for this run's count
# Scrape target follows $PG_CT (no hardcoded container); the listener is
# loopback-only by default, so the script opens metrics_addr for Vector.
cat > /tmp/logtap-metrics/vector.yaml <<EOF
sources:
  prom:
    type: prometheus_scrape
    endpoints:
      - http://$PG_CT:$PORT/metrics
    scrape_interval_secs: 1

sinks:
  file_out:
    type: file
    inputs: [prom]
    path: /var/log/vector-metrics.jsonl
    encoding: { codec: json }
EOF
docker run -d --name pglogtap-vector-metrics --network "$NET" \
  -v /tmp/logtap-metrics/vector.yaml:/etc/vector/vector.yaml:ro \
  -v /tmp/logtap-metrics:/var/log \
  timberio/vector:0.57.0-alpine --config /etc/vector/vector.yaml >/dev/null
sleep 3

# Enable the endpoint (SIGHUP applies it on the next worker cycle) and make
# sure the counters have something to show. The listener is loopback-only by
# default; Vector scrapes from another container, so open it up explicitly.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.metrics_addr = '0.0.0.0'" \
  -qc "ALTER SYSTEM SET pg_logtap.metrics_port = $PORT" -qc "SELECT pg_reload_conf()" >/dev/null
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN RAISE EXCEPTION 'metrics e2e'; END \$\$" >/dev/null 2>&1 || true

got=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -f "$OUT" ] && got=$(grep -c 'pg_logtap_events_captured_total' "$OUT" 2>/dev/null || true)
  [ "$got" -ge 1 ] && break
  sleep 1
done
# Let Vector's file sink flush its batch before counting and rm.
sleep 2

echo "scrapes_with_metrics=$got"
tail -1 "$OUT" 2>/dev/null || true
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
docker rm -f pglogtap-vector-metrics >/dev/null
[ "$got" -ge 1 ]
