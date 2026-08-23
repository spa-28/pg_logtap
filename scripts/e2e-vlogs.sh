#!/bin/sh
# Acceptance: the prod-shaped chain pg_logtap → Vector → VictoriaLogs
# (jsonline insert with the field mapping, tests/e2e/vector.yaml's
# logs_victoria sink). N distinct events must arrive EXACTLY: the query
# counts only this run's markers (PID suffix), so count < N is loss and
# count > N is duplicate delivery — both fail.
# Usage: scripts/e2e-vlogs.sh [pg_container] [events]
set -eu
PG_CT="${1:-pglogtap-pg}"
EVENTS="${2:-50}"
VEC=pglogtap-vector
NET=pglogtap-e2e_default
M="logtap vlogs -$$"

[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] || {
  echo "e2e-vlogs: stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d" >&2
  exit 1
}
docker network connect "$NET" "$PG_CT" 2>/dev/null || true # non-stand pg arg

docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://$VEC:8686'" -qc "SELECT pg_reload_conf()" >/dev/null
sleep 2

# One psql round trip; WARNING reaches the hook and does not abort the loop.
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
  WHILE i < $EVENTS LOOP
    RAISE WARNING '$M %', i;
    i := i + 1;
  END LOOP; END \$\$" >/dev/null 2>&1

# Phrase query fetches the raw records; the exact count is client-side, on
# the full "_msg":"<marker> <index>" value — a stats count() would also
# match the duration-log line, which quotes the RAISE format string
# (same trap e2e-kill's trailing-digit requirement avoids).
enc() { printf '%s' "$1" | sed 's/ /%20/g; s/"/%22/g; s/|/%7C/g'; }
count=0
n=0
while [ "$n" -lt 20 ]; do
  resp=$(docker run --rm --quiet --network "$NET" alpine:3.20 \
    wget -qO- "http://vlogs:9428/select/logsql/query?query=$(enc "\"$M\" | limit 10000")" \
    2>/dev/null || true)
  count=$(printf '%s' "$resp" | grep -c "\"_msg\":\"$M " || true)
  [ "${count:-0}" -ge "$EVENTS" ] && break
  n=$((n + 1)); sleep 1
done

echo "events=$EVENTS vlogs_received=${count:-0} marker='$M'"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
[ "${count:-0}" = "$EVENTS" ]
