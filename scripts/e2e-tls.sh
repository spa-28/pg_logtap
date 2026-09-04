#!/bin/sh
# TLS acceptance against a self-signed python receiver on the host:
#   phase 1  verify=on + export_tls_ca = the receiver's own certificate →
#            https:// events delivered
#   phase 2  ca cleared → handshake must FAIL (send_cycles_failed grows,
#            nothing delivered); ca restored → the buffered events arrive
#            (RAM backlog / fallback replay over TLS)
#   phase 2b ca file exists but holds no certificates → handshake fails the
#            same way (send_cycles_failed grows, nothing delivered)
#   phase 3  tcps:// → raw NDJSON over TLS, no HTTP framing
#   phase 4  verify=off → delivery continues, exactly one WARNING in the log
# Usage: scripts/e2e-tls.sh [pg_container] [events_per_phase]
set -eu
PG_CT="${1:-pglogtap-e2e}"
N="${2:-10}"
DIR=/tmp/logtap-e2e/tls
OUT=$DIR/https-out.jsonl
TCPS_OUT=$DIR/tcps-out.jsonl
CERT=$DIR/cert.pem
KEY=$DIR/key.pem
CA_IN_CT=/tmp/logtap-ca.pem
PORT_HTTPS=18443
PORT_TCPS=18444
MARK="logtap tls e2e -$$"

[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] || {
  echo "e2e-tls: stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d" >&2
  exit 1
}
# A stale .so (copied without a restart) would test yesterday's code.
"$(dirname "$0")/e2e-require-ext.sh" "$PG_CT"

# The receiver's address as seen from the pg container: the docker network
# gateway (the host). The certificate's SAN carries that IP — verification
# matches the URL host, which is exactly this address.
NET=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}' "$PG_CT")
GW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")

mkdir -p "$DIR"
rm -f "$OUT" "$TCPS_OUT"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=logtap-e2e-tls" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$GW" \
  -keyout "$KEY" -out "$CERT" 2>/dev/null
docker cp "$CERT" "$PG_CT:$CA_IN_CT"

DIR="$DIR" PORT_HTTPS="$PORT_HTTPS" PORT_TCPS="$PORT_TCPS" python3 - <<'PYEOF' &
import gzip, os, ssl, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

d = os.environ["DIR"]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        with open(os.path.join(d, "https-out.jsonl"), "ab") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a):
        pass

def tcps():
    raw = socket.socket()
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw.bind(("0.0.0.0", int(os.environ["PORT_TCPS"])))
    raw.listen(8)
    while True:
        conn, _ = raw.accept()
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
            data = b""
            while True:
                chunk = tls.recv(65536)
                if not chunk:
                    break
                data += chunk
            with open(os.path.join(d, "tcps-out.jsonl"), "ab") as f:
                f.write(data)
            tls.close()
        except Exception:
            conn.close() # e.g. the readiness probe: connects, sends nothing, closes

threading.Thread(target=tcps, daemon=True).start()
httpd = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_HTTPS"])), H)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
RECV=$!
trap 'kill $RECV 2>/dev/null || true' EXIT INT TERM
i=0
until python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT_HTTPS), 1); socket.create_connection(('127.0.0.1', $PORT_TCPS), 1)" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "e2e-tls: receiver never listened" >&2; exit 1; }
  sleep 1
done

set_gucs() { # each ALTER SYSTEM its own -c: a multi-statement -c silently fails the batch
  for g in "$@"; do
    docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $g" >/dev/null
  done
  docker exec "$PG_CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null
}

gen() { # gen <first> <count>
  j=0
  while [ "$j" -lt "$2" ]; do
    docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN RAISE EXCEPTION '$MARK %', $(($1 + j)); END \$\$" >/dev/null 2>&1 || true
    j=$((j + 1))
  done
}

got() { # got <file> — distinct markers of this run in the file
  grep -o "$MARK [0-9]*" "$1" 2>/dev/null | sort -u | wc -l
}

wait_for() { # wait_for <file> <count>
  i=0
  while [ "$(got "$1")" -lt "$2" ]; do
    i=$((i + 1)); [ "$i" -lt 30 ] || return 1
    sleep 1
  done
}

# --- phase 1: verified https. server_name exercises the GUC AND the std
# limitation it exists for: verifyHostName matches dNSName SANs only, an
# iPAddress SAN never matches the IP-literal URL host.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'" \
  "pg_logtap.export_tls_verify = on"
gen 0 "$N"
wait_for "$OUT" "$N" || { echo "e2e-tls: phase 1 (verified https) delivered $(got "$OUT")/$N"; exit 1; }
echo "phase 1 ok: verified https delivered $N/$N"

# --- phase 2: no CA → handshake must fail, then recover with replay
set_gucs "pg_logtap.export_tls_ca = ''"
# Let the reload land BEFORE generating: the worker applies GUCs on its own
# SIGHUP; events raced into the old cycle would deliver verified and make
# the "leaked" check below lie.
sleep 3
gen "$N" "$N"
sleep 3 # a couple of flush cycles of guaranteed failures
FAILED=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
BEFORE=$(got "$OUT")
[ "$FAILED" -gt 0 ] 2>/dev/null || { echo "e2e-tls: phase 2 expected failed cycles with the ca cleared, got $FAILED"; exit 1; }
[ "$BEFORE" -eq "$N" ] || { echo "e2e-tls: phase 2 leaked $((BEFORE - N)) events through an unverified handshake"; exit 1; }
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen $((2 * N)) "$N" # live events join the buffered ones on recovery
wait_for "$OUT" $((3 * N)) || { echo "e2e-tls: phase 2 (replay after ca restored) delivered $(got "$OUT")/$((3 * N))"; exit 1; }
echo "phase 2 ok: $FAILED failed cycles, nothing delivered unverified, $((2 * N)) buffered+live replayed"

# --- phase 2b: a CA file that exists but holds no certificates (created
# empty, or the wrong file pointed at) must fail the handshake the same way
# — not silently fall back to any verification path
docker exec "$PG_CT" touch "$CA_IN_CT.empty"
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT.empty'"
sleep 3
gen $((3 * N)) "$N" # numbers 3N..4N-1: got() counts DISTINCT markers, so a
# range reused from an earlier phase can never grow the count
sleep 3
FAILED2=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
[ "$FAILED2" -gt "$FAILED" ] 2>/dev/null || { echo "e2e-tls: phase 2b expected failed cycles with an empty ca file, got $FAILED2 (was $FAILED)"; exit 1; }
[ "$(got "$OUT")" -eq "$((3 * N))" ] || { echo "e2e-tls: phase 2b leaked $(( $(got "$OUT") - 3 * N )) events through a certificate-less CA"; exit 1; }
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen $((4 * N)) "$N"
wait_for "$OUT" $((5 * N)) || { echo "e2e-tls: phase 2b (replay after ca restored) delivered $(got "$OUT")/$((5 * N))"; exit 1; }
echo "phase 2b ok: empty-ca file failed $((FAILED2 - FAILED)) cycles, nothing delivered"

# --- phase 3: tcps, raw NDJSON over TLS
set_gucs "pg_logtap.export_url = 'tcps://$GW:$PORT_TCPS'"
gen $((3 * N)) "$N"
wait_for "$TCPS_OUT" "$N" || { echo "e2e-tls: phase 3 (tcps) delivered $(got "$TCPS_OUT")/$N"; exit 1; }
echo "phase 3 ok: tcps delivered $N/$N"

# --- phase 4: verify=off keeps delivering but says so — exactly one WARNING
# per worker life, the operator-visible trace of the footgun
set_gucs "pg_logtap.export_tls_verify = 'off'"
sleep 3
gen "$N" "$N"
wait_for "$TCPS_OUT" $((2 * N)) || { echo "e2e-tls: phase 4 (verify=off) delivered $(got "$TCPS_OUT"))/$((2 * N))"; exit 1; }
WARNS=$(docker logs "$PG_CT" 2>&1 | grep -c "export_tls_verify=off")
[ "$WARNS" -eq 1 ] || { echo "e2e-tls: phase 4 expected exactly one verify=off WARNING, got $WARNS"; exit 1; }
set_gucs "pg_logtap.export_tls_verify = 'on'"
echo "phase 4 ok: verify=off delivered, warned once"

echo "events_per_phase=$N https_total=$(got "$OUT") tcps_total=$(got "$TCPS_OUT")"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
