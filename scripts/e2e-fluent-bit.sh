#!/bin/sh
# Direct Fluent Bit acceptance: HTTP NDJSON with request gzip and an
# application/json label, then raw TCP JSON lines. Distinct tags/files prove
# that both receiver routes handled only their own marker batch.
# Usage: scripts/e2e-fluent-bit.sh [pg_container] [events_per_transport]
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init fluent-bit "${1:-}"
EVENTS="${2:-20}"
e2e_gate

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
FB="$PG_CT-fluent-bit"
FB_IMAGE='fluent/fluent-bit:4.0.14@sha256:945b0bdb80ff2886cebedbfa5130d0856877320368b7d9bd0431512907b75177'
FB_OUT="$OUT/fluent-bit-$$"
HTTP_OUT="$FB_OUT/pg-logtap-http.jsonl"
TCP_OUT="$FB_OUT/pg-logtap-tcp.jsonl"
WIRE_PROOF="$FB_OUT/http-wire.txt"
WIRE_LOG="$FB_OUT/http-wire.log"
WIRE_BASE=${E2E_TLS_BASE:-18443}
WIRE_PORT=${E2E_FLUENT_BIT_PORT:-$((WIRE_BASE + 10))}
WIRE_PID=
mkdir -p "$FB_OUT"
chmod 0777 "$FB_OUT"

guc() {
  guc_name_valid "$1" || return 2
  docker exec "$PG_CT" psql -X -U postgres -At -v ON_ERROR_STOP=1 -c "SHOW $1"
}
snapshot_fail() {
  echo "e2e-fluent-bit: could not snapshot the original sender GUC state" >&2
  rm -rf "$FB_OUT"
  exit 1
}
OLD_URL=$(guc pg_logtap.export_url) || snapshot_fail
OLD_URL_AUTO_HAS=$(guc_auto_has pg_logtap.export_url) || snapshot_fail
OLD_URL_AUTO=$(guc_auto_value pg_logtap.export_url) || snapshot_fail
OLD_TYPE=$(guc pg_logtap.export_http_content_type) || snapshot_fail
OLD_TYPE_AUTO_HAS=$(guc_auto_has pg_logtap.export_http_content_type) || snapshot_fail
OLD_TYPE_AUTO=$(guc_auto_value pg_logtap.export_http_content_type) || snapshot_fail
OLD_GZIP=$(guc pg_logtap.export_gzip) || snapshot_fail
OLD_GZIP_AUTO_HAS=$(guc_auto_has pg_logtap.export_gzip) || snapshot_fail
OLD_GZIP_AUTO=$(guc_auto_value pg_logtap.export_gzip) || snapshot_fail
OLD_FALLBACK=$(guc pg_logtap.export_fallback_file) || snapshot_fail
OLD_FALLBACK_AUTO_HAS=$(guc_auto_has pg_logtap.export_fallback_file) || snapshot_fail
OLD_FALLBACK_AUTO=$(guc_auto_value pg_logtap.export_fallback_file) || snapshot_fail
OLD_HEADERS=$(guc pg_logtap.export_http_extra_headers) || snapshot_fail
OLD_HEADERS_AUTO_HAS=$(guc_auto_has pg_logtap.export_http_extra_headers) || snapshot_fail
OLD_HEADERS_AUTO=$(guc_auto_value pg_logtap.export_http_extra_headers) || snapshot_fail

restore_guc() { # <name> <had-auto-conf-entry> <auto-conf-value>
  if [ "$2" = t ]; then
    setguc "$1" "$3"
  else
    resetguc "$1"
  fi
}
sender_restored() {
  [ "$(guc pg_logtap.export_url)" = "$OLD_URL" ] &&
    [ "$(guc pg_logtap.export_http_content_type)" = "$OLD_TYPE" ] &&
    [ "$(guc pg_logtap.export_gzip)" = "$OLD_GZIP" ] &&
    [ "$(guc pg_logtap.export_fallback_file)" = "$OLD_FALLBACK" ] &&
    [ "$(guc pg_logtap.export_http_extra_headers)" = "$OLD_HEADERS" ]
}
restore_sender() {
  restore_rc=0
  restore_guc pg_logtap.export_url "$OLD_URL_AUTO_HAS" "$OLD_URL_AUTO" || restore_rc=1
  restore_guc pg_logtap.export_http_content_type "$OLD_TYPE_AUTO_HAS" "$OLD_TYPE_AUTO" || restore_rc=1
  restore_guc pg_logtap.export_gzip "$OLD_GZIP_AUTO_HAS" "$OLD_GZIP_AUTO" || restore_rc=1
  restore_guc pg_logtap.export_fallback_file "$OLD_FALLBACK_AUTO_HAS" "$OLD_FALLBACK_AUTO" || restore_rc=1
  restore_guc pg_logtap.export_http_extra_headers "$OLD_HEADERS_AUTO_HAS" "$OLD_HEADERS_AUTO" || restore_rc=1
  reload || restore_rc=1
  n=0
  while [ "$restore_rc" -eq 0 ] && ! sender_restored; do
    n=$((n + 1))
    [ "$n" -lt 20 ] || { restore_rc=1; break; }
    sleep 1
  done
  if [ "$restore_rc" -eq 0 ]; then
    timeout_ms=$(guc pg_logtap.export_timeout_ms) || restore_rc=1
  fi
  # Keep the temporary receiver alive until a cycle using the old route can no
  # longer be in flight. Fresh SHOW sessions only prove the GUC generation.
  [ "$restore_rc" -ne 0 ] || sleep $(((timeout_ms + 999) / 1000 + 1))
  return "$restore_rc"
}
cleanup() {
  status=$?
  trap - EXIT
  restore_status=0
  restore_sender || restore_status=$?
  [ -z "$WIRE_PID" ] || { kill "$WIRE_PID" >/dev/null 2>&1 || true; wait "$WIRE_PID" 2>/dev/null || true; }
  docker rm -f "$FB" >/dev/null 2>&1 || true
  rm -rf "$FB_OUT"
  if [ "$restore_status" -ne 0 ]; then
    echo "e2e-fluent-bit: failed to restore the original sender GUC state" >&2
    [ "$status" -ne 0 ] || status=$restore_status
  fi
  exit "$status"
}
trap cleanup EXIT

fail_extra() {
  docker logs "$FB" >&2 2>/dev/null || true
  for file in "$HTTP_OUT" "$TCP_OUT" "$WIRE_LOG" "$WIRE_PROOF"; do
    [ -f "$file" ] && { echo "-- $file" >&2; tail -10 "$file" >&2; }
  done
}

wait_guc() { # <name> <expected>: fresh sessions observe the reloaded generation
  name=$1
  expected=$2
  n=0
  while [ "$n" -lt 20 ]; do
    [ "$(guc "$name")" = "$expected" ] && return 0
    n=$((n + 1))
    sleep 1
  done
  fail "$name never became '$expected'"
}

apply_sender() { # <url> <content-type> <gzip>
  setguc pg_logtap.export_url "$1" || fail "could not set export_url"
  setguc pg_logtap.export_http_content_type "$2" || fail "could not set export_http_content_type"
  setguc pg_logtap.export_gzip "$3" || fail "could not set export_gzip"
  setguc pg_logtap.export_fallback_file '' || fail "could not clear export_fallback_file"
  setguc pg_logtap.export_http_extra_headers '' || fail "could not clear export_http_extra_headers"
  reload || fail "could not reload sender configuration"
  wait_guc pg_logtap.export_url "$1"
  wait_guc pg_logtap.export_http_content_type "$2"
  wait_guc pg_logtap.export_gzip "$3"
  wait_guc pg_logtap.export_fallback_file ''
  wait_guc pg_logtap.export_http_extra_headers ''
  # The worker applies SIGHUP between cycles; one old in-flight request is
  # bounded by export_timeout_ms, so do not generate into the previous route.
  timeout_ms=$(guc pg_logtap.export_timeout_ms)
  sleep $(((timeout_ms + 999) / 1000 + 1))
}

docker rm -f "$FB" >/dev/null 2>&1 || true
docker run -d --name "$FB" --network "$NET" \
  -v "$ROOT/tests/e2e/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro" \
  -v "$FB_OUT:/var/log/fluent-bit" \
  "$FB_IMAGE" \
  /fluent-bit/bin/fluent-bit -c /fluent-bit/etc/fluent-bit.conf >/dev/null \
  || fail "could not start Fluent Bit"

ready=0
n=0
while [ "$n" -lt 60 ]; do
  if docker exec "$PG_CT" bash -c \
    "exec 3<>/dev/tcp/$FB/9880 && exec 4<>/dev/tcp/$FB/5170" \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  n=$((n + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail "Fluent Bit did not open HTTP and TCP inputs"

GATEWAY=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")
FB_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$FB")
WIRE_MARKER="logtap $E2E_TAG http$E2E_SUF "
WIRE_PORT="$WIRE_PORT" FB_IP="$FB_IP" WIRE_PROOF="$WIRE_PROOF" WIRE_MARKER="$WIRE_MARKER" \
  python3 - <<'PY' >"$WIRE_LOG" 2>&1 &
import gzip
import json
import os
import socket
import socketserver
import traceback

port = int(os.environ["WIRE_PORT"])
upstream = (os.environ["FB_IP"], 9880)
proof = os.environ["WIRE_PROOF"]
marker = os.environ["WIRE_MARKER"]


def receive_request(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        data.extend(chunk)
        if len(data) > 65536:
            raise ValueError("HTTP request headers exceed 64 KiB")
    head, body = bytes(data).split(b"\r\n\r\n", 1)
    headers = {}
    for line in head.split(b"\r\n")[1:]:
        name, value = line.split(b":", 1)
        headers[name.strip().lower()] = value.strip()
    length = int(headers[b"content-length"])
    if length > 64 * 1024 * 1024:
        raise ValueError("HTTP request body exceeds 64 MiB")
    while len(body) < length:
        chunk = sock.recv(min(65536, length - len(body)))
        if not chunk:
            raise EOFError("HTTP request body ended early")
        body += chunk
    return head + b"\r\n\r\n" + body[:length], headers, body[:length]


def forward(request):
    with socket.create_connection(upstream, timeout=10) as sock:
        sock.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(65536)
            if not chunk:
                raise EOFError("HTTP response headers ended early")
            response.extend(chunk)
        head, body = bytes(response).split(b"\r\n\r\n", 1)
        headers = {}
        for line in head.split(b"\r\n")[1:]:
            name, value = line.split(b":", 1)
            headers[name.strip().lower()] = value.strip()
        length = int(headers.get(b"content-length", b"0"))
        while len(body) < length:
            chunk = sock.recv(min(65536, length - len(body)))
            if not chunk:
                raise EOFError("HTTP response body ended early")
            body += chunk
    return head + b"\r\n\r\n" + body[:length]


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            request = receive_request(self.request)
            if request is None:
                return
            raw, headers, body = request
            if headers.get(b"content-encoding", b"").lower() != b"gzip":
                raise ValueError("missing Content-Encoding: gzip")
            if headers.get(b"content-type", b"").lower() != b"application/json":
                raise ValueError("unexpected Content-Type")
            if not body.startswith(b"\x1f\x8b"):
                raise ValueError("request body lacks gzip magic")
            rows = [json.loads(line) for line in gzip.decompress(body).splitlines() if line]
            matching = sum(str(row.get("message", "")).startswith(marker) for row in rows)
            response = forward(raw)
            status = response.split(b"\r\n", 1)[0].split()
            if len(status) < 2 or not status[1].startswith(b"2"):
                raise ValueError("Fluent Bit did not return HTTP 2xx")
            if matching:
                tmp = proof + ".tmp"
                with open(tmp, "w", encoding="ascii") as output:
                    output.write("content_encoding=gzip\n")
                    output.write("content_type=application/json\n")
                    output.write("gzip_magic=1f8b\n")
                    output.write(f"matching_events={matching}\n")
                os.replace(tmp, proof)
            self.request.sendall(response)
        except Exception:
            traceback.print_exc()
            try:
                self.request.sendall(
                    b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
            except OSError:
                pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("0.0.0.0", port), Handler) as server:
    server.serve_forever()
PY
WIRE_PID=$!

ready=0
n=0
while [ "$n" -lt 20 ]; do
  if docker exec "$PG_CT" bash -c "exec 3<>/dev/tcp/$GATEWAY/$WIRE_PORT" >/dev/null 2>&1; then
    ready=1
    break
  fi
  n=$((n + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail "HTTP gzip inspection proxy did not become ready"

apply_sender "http://$GATEWAY:$WIRE_PORT/pg_logtap_http" application/json on
base_dropped=$(statf events_dropped)
base_failed=$(statf send_cycles_failed)
base_lost=$(statf events_lost)
gen http "$EVENTS"
wait_for http "$EVENTS" "$HTTP_OUT" 30
[ "$(received http "$HTTP_OUT")" = "$EVENTS" ] || fail "HTTP distinct marker count changed"
[ "$(json_check http "$HTTP_OUT")" = "$EVENTS" ] || fail "HTTP output has duplicates or invalid JSON"
[ "$(received http "$TCP_OUT")" = 0 ] || fail "HTTP markers leaked into the TCP route"
n=0
while [ "$n" -lt 20 ] && [ ! -f "$WIRE_PROOF" ]; do
  n=$((n + 1))
  sleep 1
done
[ -f "$WIRE_PROOF" ] || fail "HTTP marker batch bypassed gzip wire inspection"
grep -qx 'content_encoding=gzip' "$WIRE_PROOF" || fail "HTTP request lacked Content-Encoding: gzip"
grep -qx 'content_type=application/json' "$WIRE_PROOF" || fail "HTTP request used the wrong Content-Type"
grep -qx 'gzip_magic=1f8b' "$WIRE_PROOF" || fail "HTTP request body lacked gzip magic"
grep -Eq '^matching_events=[1-9][0-9]*$' "$WIRE_PROOF" || fail "wire inspection missed the HTTP marker batch"
ok "Fluent Bit HTTP accepted $EVENTS/$EVENTS wire-verified gzip NDJSON events with application/json"

apply_sender "tcp://$FB:5170" application/x-ndjson off
gen tcp "$EVENTS"
wait_for tcp "$EVENTS" "$TCP_OUT" 30
[ "$(received tcp "$TCP_OUT")" = "$EVENTS" ] || fail "TCP distinct marker count changed"
[ "$(json_check tcp "$TCP_OUT")" = "$EVENTS" ] || fail "TCP output has duplicates or invalid JSON"
[ "$(received tcp "$HTTP_OUT")" = 0 ] || fail "TCP markers leaked into the HTTP route"
ok "Fluent Bit TCP accepted $EVENTS/$EVENTS newline-delimited JSON events"

[ "$(statf events_dropped)" = "$base_dropped" ] || fail "events_dropped increased"
[ "$(statf send_cycles_failed)" = "$base_failed" ] || fail "send_cycles_failed increased"
[ "$(statf events_lost)" = "$base_lost" ] || fail "events_lost increased"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
