#!/bin/sh
# M3 acceptance: generate N events in Postgres, assert Vector received >= N.
# Usage: scripts/e2e-vector.sh [pg_container] [events]
set -eu
PG_CT="${1:-pglogtap-pg}"
EVENTS="${2:-20}"
OUT=/tmp/logtap-e2e/vector-out.jsonl
NET=logtap-e2e

docker network create "$NET" >/dev/null 2>&1 || true
docker network connect "$NET" "$PG_CT" 2>/dev/null || true
docker rm -f pglogtap-vector-e2e >/dev/null 2>&1 || true
rm -rf /tmp/logtap-e2e && mkdir -p /tmp/logtap-e2e
docker run -d --name pglogtap-vector-e2e --network "$NET" \
  -v "$(pwd)/tests/e2e/vector.yaml:/etc/vector/vector.yaml:ro" \
  -v /tmp/logtap-e2e:/var/log \
  timberio/vector:0.57.0-alpine --config /etc/vector/vector.yaml >/dev/null
sleep 3

# Point pg_logtap at Vector (URL is re-read every flush cycle, no restart
# needed) and reset the counters' baseline.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector-e2e:8686'" -qc "SELECT pg_reload_conf()" >/dev/null
sleep 2

i=0
while [ "$i" -lt "$EVENTS" ]; do
  # Distinct messages: identical events would hide fan-out or dedup bugs.
  docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN RAISE EXCEPTION 'logtap e2e event %', $i; END \$\$" >/dev/null 2>&1 || true
  i=$((i + 1))
done

got=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$OUT" ] && got=$(wc -l < "$OUT")
  [ "$got" -ge "$EVENTS" ] && break
  sleep 1
done
# Дать Vector дописать батч в файл до подсчёта и rm (иначе теряем хвост).
sleep 2

echo "events_sent=$EVENTS vector_received=$(wc -l < "$OUT") distinct_messages=$(grep -o 'logtap e2e event [0-9]*' "$OUT" 2>/dev/null | sort -u | wc -l)"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
docker rm -f pglogtap-vector >/dev/null
[ "$got" -ge "$EVENTS" ]
