#!/bin/sh
# M4 acceptance: worker serves /metrics; Vector prometheus_scrape reads it.
# Usage: scripts/e2e-metrics.sh [pg_container] [port]
set -eu
PG_CT="${1:-pglogtap-pg}"
PORT="${2:-9187}"
OUT=/tmp/logtap-e2e/vector-metrics.jsonl
NET=logtap-e2e

docker network create "$NET" >/dev/null 2>&1 || true
docker network connect "$NET" "$PG_CT" 2>/dev/null || true
docker rm -f pglogtap-vector >/dev/null 2>&1 || true
rm -rf /tmp/logtap-e2e && mkdir -p /tmp/logtap-e2e
docker run -d --name pglogtap-vector --network "$NET" \
  -v "$(pwd)/tests/e2e/vector-metrics.yaml:/etc/vector/vector.yaml:ro" \
  -v /tmp/logtap-e2e:/var/log \
  timberio/vector:0.57.0-alpine --config /etc/vector/vector.yaml >/dev/null
sleep 3

# Enable the endpoint (SIGHUP applies it on the next worker cycle) and make
# sure the counters have something to show.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.metrics_port = $PORT" -qc "SELECT pg_reload_conf()" >/dev/null
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
docker rm -f pglogtap-vector >/dev/null
[ "$got" -ge 1 ]
