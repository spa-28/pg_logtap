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
RESTORE="/tmp/logtap-metrics/$PG_CT/restore$SUF.sql"
docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -Atc "
  SELECT format('ALTER SYSTEM SET %s = %L;', name, current_setting(name))
    FROM unnest(ARRAY[
      'pg_logtap.pattern', 'pg_logtap.pattern_exclude', 'pg_logtap.level_min',
      'pg_logtap.flush_interval', 'pg_logtap.export_slow_ms', 'pg_logtap.export_timeout_ms',
      'pg_logtap.export_fallback_file', 'pg_logtap.fallback_max_mb', 'pg_logtap.export_url',
      'pg_logtap.metrics_addr', 'pg_logtap.metrics_port'
    ]) AS gucs(name)" > "$RESTORE" || fail "could not snapshot GUCs"
cleanup() {
  cleanup_status=$?
  trap - EXIT
  docker exec -i "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 < "$RESTORE" >/dev/null \
    && reload && rm -f "$RESTORE" || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup EXIT
http_code() { # route; the shell read deadline avoids signalling a postmaster child
  docker exec "$PG_CT" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/"$2" || exit
    printf "GET %s HTTP/1.0\r\n\r\n" "$1" >&3
    IFS= read -r -t 8 line <&3 || exit
    set -- $line; printf "%s\n" "$2"
  ' bash "$1" "$PORT" 2>/dev/null
}
wait_code() { # route, expected status
  n=0
  while [ "$n" -lt 15 ]; do
    [ "$(http_code "$1")" = "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
  fail "$1 did not become $2"
}
prom_backlog() {
  docker exec "$PG_CT" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/"$1" || exit
    printf "GET /metrics HTTP/1.0\r\n\r\n" >&3
    while IFS= read -r -t 8 line <&3; do
      case "$line" in "pg_logtap_queue_backlog "*) printf "%s\n" "${line#* }"; exit 0;; esac
    done
    exit 1
  ' bash "$PORT" 2>/dev/null
}
assert_backlog() { # exact expected value, after stopping capture and waiting for publication
  sql=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")
  prom=$(prom_backlog) || fail "queue backlog gauge missing"
  [ "$sql" = "$1" ] && [ "$prom" = "$sql" ] \
    || fail "quiescent backlog: SQL=$sql Prometheus=$prom expected=$1"
}
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

# Only named suite markers are captured: reload/startup logs cannot secretly
# send a batch and hide a readiness reset or change data between SQL and Prom.
setguc pg_logtap.pattern '^logtap metrics ' || fail "could not isolate capture"
setguc pg_logtap.pattern_exclude '' || fail "could not clear exclude pattern"
setguc pg_logtap.level_min 19 || fail "could not set capture level"
setguc pg_logtap.flush_interval 100 || fail "could not set flush interval"
setguc pg_logtap.export_slow_ms 0 || fail "could not disable slow throttling"
setguc pg_logtap.export_timeout_ms 1000 || fail "could not set timeout"
setguc pg_logtap.export_url "http://$VEC:8686" || fail "could not set receiver"
reload || fail "capture isolation reload failed"
sleep 2
wait_vector
drain_ring
n=0
while [ "$n" -lt 30 ]; do
  [ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 0 ] && break
  n=$((n + 1)); sleep 1
done
assert_backlog 0
setguc pg_logtap.export_fallback_file "pg_logtap-metrics$SUF.bin" || fail "could not set suite queue"
setguc pg_logtap.fallback_max_mb 64 || fail "could not bound suite queue"
reload || fail "queue setup reload failed"
sleep 1

# A fresh worker has no successful delivery to remember, despite responsive
# liveness. No markers are emitted until this startup assertion has passed.
oldpid=$(worker_pid)
[ -n "$oldpid" ] || fail "worker not found"
docker exec "$PG_CT" kill -TERM "$oldpid" || fail "worker TERM failed"
n=0
while [ "$n" -lt 15 ]; do
  newpid=$(worker_pid)
  [ -n "$newpid" ] && [ "$newpid" != "$oldpid" ] && break
  n=$((n + 1)); sleep 1
done
[ -n "${newpid:-}" ] && [ "$newpid" != "$oldpid" ] || fail "worker did not respawn"
wait_code /readyz 503
[ "$(http_code /healthz)" = 200 ] && [ "$(http_code /livez)" = 200 ] || fail "startup liveness failed"
gen warmup 1
wait_code /readyz 200
drain_ring
sleep 1
sent0=$(statf events_sent)
replayed0=$(statf events_replayed)
setguc pg_logtap.flush_interval 200 || fail "could not set unrelated GUC"
reload || fail "unrelated reload failed"
sleep 1
[ "$(http_code /readyz)" = 200 ] || fail "unrelated SIGHUP cleared readiness"
[ "$(statf events_sent)" = "$sent0" ] && [ "$(statf events_replayed)" = "$replayed0" ] \
  || fail "unexpected delivery hid the unrelated-SIGHUP readiness decision"

# A URL change must discard stale success BEFORE any send can fail. The
# silent endpoint stays idle until the 503 check and failure-counter check.
failed0=$(statf send_cycles_failed)
setguc pg_logtap.export_url 'http://pglogtap-silent:9499' || fail "could not select silent receiver"
reload || fail "URL-change reload failed"
wait_code /readyz 503
[ "$(statf send_cycles_failed)" = "$failed0" ] || fail "URL reset was tested only after a failed send"
gen backlog 10
n=0
while [ "$n" -lt 20 ]; do
  [ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 10 ] && break
  n=$((n + 1)); sleep 1
done
assert_backlog 10
[ "$(http_code /readyz)" = 503 ] || fail "failed receiver reported ready"
[ "$(http_code /healthz)" = 200 ] && [ "$(http_code /livez)" = 200 ] || fail "failed receiver liveness failed"
setguc pg_logtap.export_url "http://$VEC:8686" || fail "could not restore receiver"
reload || fail "recovery reload failed"
wait_code /readyz 200
n=0
while [ "$n" -lt 30 ]; do
  [ "$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT queue_backlog FROM pg_logtap_delivery")" = 0 ] && break
  n=$((n + 1)); sleep 1
done
assert_backlog 0
setguc pg_logtap.export_url '' || fail "could not disable export"
reload || fail "disable reload failed"
wait_code /readyz 503
[ "$(http_code /healthz)" = 200 ] && [ "$(http_code /livez)" = 200 ] || fail "disabled export liveness failed"
ok "startup/disabled 503, URL-change reset without a send, unrelated HUP preserves 200, SQL/Prometheus backlog 10→0"

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
