#!/bin/sh
# M3 acceptance: generate N events in Postgres, assert Vector received >= N.
# The receiver is the compose stand's vector (tests/e2e/compose.yaml); its
# output file accumulates across runs, so counting is by distinct markers.
# Usage: scripts/e2e-vector.sh [pg_container] [events]
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init vector "${1:-}"
EVENTS="${2:-20}"
e2e_gate
OUT=${E2E_OUT:-/tmp/logtap-e2e}/vector-out.jsonl # file path, unlike e2e_init's dir

# Point pg_logtap at Vector (URL is re-read every flush cycle, no restart
# needed) and reset the counters' baseline.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$VEC:8686'" -qc "SELECT pg_reload_conf()" >/dev/null
sleep 2

i=0
while [ "$i" -lt "$EVENTS" ]; do
  # Distinct messages, run-unique ($$ suffix — the output accumulates across
  # runs): identical markers would hide fan-out, dedup and this-run bugs.
  docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN RAISE EXCEPTION 'logtap e2e event -$$ %', $i; END \$\$" >/dev/null 2>&1
  i=$((i + 1))
done

got=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$OUT" ] && got=$(grep -o "logtap e2e event -$$ [0-9]*" "$OUT" 2>/dev/null | sort -u | wc -l)
  [ "$got" -ge "$EVENTS" ] && break
  sleep 1
done
# Дать Vector дописать батч в файл до подсчёта (иначе теряем хвост).
sleep 2

echo "events_sent=$EVENTS vector_received=$(wc -l < "$OUT" 2>/dev/null || echo 0) distinct_messages=$got"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
[ "$got" -ge "$EVENTS" ]
