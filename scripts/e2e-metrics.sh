#!/bin/sh
# M4 acceptance: worker serves /metrics; Vector prometheus_scrape reads it.
# Usage: scripts/e2e-metrics.sh [pg_container] [port]
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init metrics "${1:-}"
PORT="${2:-9187}"
e2e_gate
OUT=/tmp/logtap-metrics/$PG_CT/vector-metrics.jsonl # per container: parallel majors truncate it
docker rm -f "$PG_CT-vector-metrics" >/dev/null 2>&1
mkdir -p "/tmp/logtap-metrics/$PG_CT"
: > "$OUT" # fresh scrape log for this run's count
# Scrape target follows $PG_CT (no hardcoded container); the listener is
# loopback-only by default, so the script opens metrics_addr for Vector.
cat > "/tmp/logtap-metrics/$PG_CT/vector.yaml" <<EOF
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
docker run -d --name "$PG_CT-vector-metrics" --network "$NET" \
  -v "/tmp/logtap-metrics/$PG_CT/vector.yaml:/etc/vector/vector.yaml:ro" \
  -v "/tmp/logtap-metrics/$PG_CT:/var/log" \
  timberio/vector:0.57.0-alpine --config /etc/vector/vector.yaml >/dev/null
sleep 3

# Enable the endpoint (SIGHUP applies it on the next worker cycle) and make
# sure the counters have something to show. The listener is loopback-only by
# default; Vector scrapes from another container, so open it up explicitly.
docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.metrics_addr = '0.0.0.0'" \
  -qc "ALTER SYSTEM SET pg_logtap.metrics_port = $PORT" -qc "SELECT pg_reload_conf()" >/dev/null
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN RAISE EXCEPTION 'metrics e2e'; END \$\$" >/dev/null 2>&1

got=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -f "$OUT" ] && got=$(grep -c 'pg_logtap_events_captured_total' "$OUT" 2>/dev/null)
  [ "$got" -ge 1 ] && break
  sleep 1
done
# Let Vector's file sink flush its batch before counting and rm.
sleep 2

echo "scrapes_with_metrics=$got"
tail -1 "$OUT" 2>/dev/null
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"

# Fragmented GET: TCP owes the client no write boundaries — a request line
# straddling recvs must still parse. A one-recv request read sees "GET /met",
# parses the path as "/met" and answers 404. Send in two pieces (gap inside
# the worker's 50ms per-client line wait — 20ms still sits far above
# container-network RTT, with runner jitter headroom on the other side) and
# demand the real metrics body.
echo "== fragmented GET: the request line straddles recvs =="
docker run --rm --network "$NET" python:3-alpine python -c "
import socket, time
s = socket.create_connection(('$PG_CT', $PORT), timeout=8)
s.sendall(b'GET /met')
time.sleep(0.02)
s.sendall(b'rics HTTP/1.1\r\n\r\n')
time.sleep(0.3)
data = s.recv(65536)
assert data.startswith(b'HTTP/1.1 200'), data.split(b'\r\n', 1)[0]
assert b'pg_logtap_' in data, 'metrics body missing'
print('frag-get ok:', data.split(b'\r\n', 1)[0].decode())
" || {
  echo "e2e-metrics: FAILED: fragmented GET not answered with the metrics body" >&2
  docker rm -f "$PG_CT-vector-metrics" >/dev/null
  exit 1
}
docker rm -f "$PG_CT-vector-metrics" >/dev/null
[ "$got" -ge 1 ]
