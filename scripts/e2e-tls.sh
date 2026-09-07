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
#   phase 5  an impostor receiver presents a certificate carrying the RIGHT
#            name (same CN/SANs) but its own key; ca still = the real
#            certificate → the handshake must fail on the chain alone and
#            nothing may reach the impostor; recovery delivers verified
#   phase 6  the real receiver and the right CA, but server_name is not in
#            the certificate's SANs → the handshake fails on the name alone
#   phase 7  intermediate CA, the real-world PKI shape: the server presents
#            leaf+intermediate; pinning only the ROOT must build the path
#            through the server-sent intermediate, and pinning the
#            intermediate itself (anchor below the root) must work too
# Markers are per-phase NAMED buckets (received counts DISTINCT markers), so
# a phase's asserts can never be satisfied by another phase's events.
# Usage: scripts/e2e-tls.sh [pg_container] [events_per_phase]
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init tls "${1:-}"
N="${2:-10}"
e2e_gate
DIR=/tmp/logtap-e2e/tls
OUT=$DIR/https-out.jsonl
TCPS_OUT=$DIR/tcps-out.jsonl
EVIL_OUT=$DIR/evil-out.jsonl
CHAIN_OUT=$DIR/chain-out.jsonl
CERT=$DIR/cert.pem
KEY=$DIR/key.pem
CA_IN_CT=/tmp/logtap-ca.pem
PORT_HTTPS=18443
PORT_TCPS=18444
PORT_EVIL=18445
PORT_CHAIN=18446

# The receiver's address as seen from the pg container: the docker network
# gateway (the host). The certificate's SAN carries that IP — verification
# matches the URL host, which is exactly this address.
NET=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}' "$PG_CT")
GW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")

mkdir -p "$DIR"
rm -f "$OUT" "$TCPS_OUT" "$EVIL_OUT" "$CHAIN_OUT"
# The impostor's certificate: identical CN and SANs, its own key — only the
# pinned CA can tell it from the real one. That is the phase 5 point.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=logtap-e2e-tls" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$GW" \
  -keyout "$KEY" -out "$CERT" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=logtap-e2e-tls" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$GW" \
  -keyout "$DIR/key-evil.pem" -out "$DIR/cert-evil.pem" 2>/dev/null
# A mini PKI for phase 7: root -> intermediate -> leaf. The server presents
# leaf+intermediate (chain.pem); the client pins only the root.
printf 'basicConstraints=critical,CA:TRUE\n' > "$DIR/inter.ext"
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:%s\n' "$GW" > "$DIR/leaf.ext"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=logtap-e2e-root" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -keyout "$DIR/root.key" -out "$DIR/root.pem" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=logtap-e2e-inter" \
  -keyout "$DIR/inter.key" -out "$DIR/inter.csr" 2>/dev/null
openssl x509 -req -in "$DIR/inter.csr" -CA "$DIR/root.pem" -CAkey "$DIR/root.key" \
  -CAcreateserial -days 2 -extfile "$DIR/inter.ext" -out "$DIR/inter.pem" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=logtap-e2e-tls" \
  -keyout "$DIR/leaf.key" -out "$DIR/leaf.csr" 2>/dev/null
openssl x509 -req -in "$DIR/leaf.csr" -CA "$DIR/inter.pem" -CAkey "$DIR/inter.key" \
  -CAcreateserial -days 2 -extfile "$DIR/leaf.ext" -out "$DIR/leaf.pem" 2>/dev/null
cat "$DIR/leaf.pem" "$DIR/inter.pem" > "$DIR/chain.pem"
docker cp "$CERT" "$PG_CT:$CA_IN_CT"
docker cp "$DIR/root.pem" "$PG_CT:$CA_IN_CT.root"
docker cp "$DIR/inter.pem" "$PG_CT:$CA_IN_CT.inter"

DIR="$DIR" PORT_HTTPS="$PORT_HTTPS" PORT_TCPS="$PORT_TCPS" PORT_EVIL="$PORT_EVIL" PORT_CHAIN="$PORT_CHAIN" python3 - <<'PYEOF' &
import gzip, os, ssl, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

d = os.environ["DIR"]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))
ctx_evil = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx_evil.load_cert_chain(os.path.join(d, "cert-evil.pem"), os.path.join(d, "key-evil.pem"))
ctx_chain = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx_chain.load_cert_chain(os.path.join(d, "chain.pem"), os.path.join(d, "leaf.key"))

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

def dump_tls(port, ctx, out):
    raw = socket.socket()
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw.bind(("0.0.0.0", port))
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
            with open(os.path.join(d, out), "ab") as f:
                f.write(data)
            tls.close()
        except Exception:
            conn.close() # e.g. the readiness probe: connects, sends nothing, closes

threading.Thread(target=dump_tls, args=(int(os.environ["PORT_TCPS"]), ctx, "tcps-out.jsonl"), daemon=True).start()
threading.Thread(target=dump_tls, args=(int(os.environ["PORT_EVIL"]), ctx_evil, "evil-out.jsonl"), daemon=True).start()
threading.Thread(target=dump_tls, args=(int(os.environ["PORT_CHAIN"]), ctx_chain, "chain-out.jsonl"), daemon=True).start()
httpd = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_HTTPS"])), H)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
RECV=$!
trap 'kill $RECV 2>/dev/null' EXIT INT TERM
i=0
until python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT_HTTPS), 1); socket.create_connection(('127.0.0.1', $PORT_TCPS), 1); socket.create_connection(('127.0.0.1', $PORT_EVIL), 1); socket.create_connection(('127.0.0.1', $PORT_CHAIN), 1)" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "e2e-tls: receiver never listened" >&2; exit 1; }
  sleep 1
done

set_gucs() { # each ALTER SYSTEM its own -c: a multi-statement -c silently fails the batch
  for g in "$@"; do
    docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $g" >/dev/null
  done
  docker exec "$PG_CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null
}

# --- phase 1: verified https. server_name exercises the GUC AND the std
# limitation it exists for: verifyHostName matches dNSName SANs only, an
# iPAddress SAN never matches the IP-literal URL host.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'" \
  "pg_logtap.export_tls_verify = on"
gen p1 "$N"
wait_for p1 "$N" "$OUT"
echo "phase 1 ok: verified https delivered $N/$N"

# --- phase 2: no CA → handshake must fail, then recover with replay
set_gucs "pg_logtap.export_tls_ca = ''"
# Let the reload land BEFORE generating: the worker applies GUCs on its own
# SIGHUP; events raced into the old cycle would deliver verified and make
# the "leaked" check below lie.
sleep 3
gen p2fail "$N"
sleep 3 # a couple of flush cycles of guaranteed failures
FAILED=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
[ "$FAILED" -gt 0 ] 2>/dev/null || { echo "e2e-tls: phase 2 expected failed cycles with the ca cleared, got $FAILED"; exit 1; }
[ "$(received p2fail "$OUT")" = 0 ] || { echo "e2e-tls: phase 2 leaked $(received p2fail "$OUT") events through an unverified handshake"; exit 1; }
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen p2re "$N" # live events join the buffered ones on recovery
wait_for p2fail "$N" "$OUT"
wait_for p2re "$N" "$OUT"
echo "phase 2 ok: $FAILED failed cycles, nothing delivered unverified, $N buffered + $N live replayed"

# --- phase 2b: a CA file that exists but holds no certificates (created
# empty, or the wrong file pointed at) must fail the handshake the same way
# — not silently fall back to any verification path
docker exec "$PG_CT" touch "$CA_IN_CT.empty"
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT.empty'"
sleep 3
gen p2bfail "$N"
sleep 3
FAILED2=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
[ "$FAILED2" -gt "$FAILED" ] 2>/dev/null || { echo "e2e-tls: phase 2b expected failed cycles with an empty ca file, got $FAILED2 (was $FAILED)"; exit 1; }
[ "$(received p2bfail "$OUT")" = 0 ] || { echo "e2e-tls: phase 2b leaked $(received p2bfail "$OUT") events through a certificate-less CA"; exit 1; }
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen p2bre "$N"
wait_for p2bfail "$N" "$OUT"
wait_for p2bre "$N" "$OUT"
echo "phase 2b ok: empty-ca file failed $((FAILED2 - FAILED)) cycles, nothing delivered"

# --- phase 3: tcps, raw NDJSON over TLS
set_gucs "pg_logtap.export_url = 'tcps://$GW:$PORT_TCPS'"
gen p3 "$N"
wait_for p3 "$N" "$TCPS_OUT"
echo "phase 3 ok: tcps delivered $N/$N"

# --- phase 4: verify=off keeps delivering but says so — exactly one WARNING
# per worker life, the operator-visible trace of the footgun. Restart the
# worker (postmaster respawns the bgworker; shmem counters survive) so the
# once-per-life flag is provably fresh: this phase must add exactly one
# warn_tls_no_verify, whatever earlier runs left in the counter. verify
# goes back ON first — a previously failed run may have left it off, and a
# worker booting with it off would warn before the baseline is taken.
set_gucs "pg_logtap.export_tls_verify = 'on'"
old_wpid=$(worker_pid)
docker exec "$PG_CT" kill -TERM "$old_wpid"
n=0; while [ "$n" -lt 15 ]; do
  newpid=$(worker_pid)
  [ -n "$newpid" ] && [ "$newpid" != "$old_wpid" ] && break
  n=$((n + 1)); sleep 1
done
[ -n "${newpid:-}" ] && [ "$newpid" != "$old_wpid" ] || fail "e2e-tls: worker did not respawn after TERM"
warns0=$(statf warn_tls_no_verify)
set_gucs "pg_logtap.export_tls_verify = 'off'"
sleep 3
gen p4 "$N"
wait_for p4 "$N" "$TCPS_OUT"
WARNS=$(( $(statf warn_tls_no_verify) - warns0 ))
[ "$WARNS" -eq 1 ] || { echo "e2e-tls: phase 4 expected exactly one verify=off WARNING, got $WARNS"; exit 1; }
set_gucs "pg_logtap.export_tls_verify = 'on'"
echo "phase 4 ok: verify=off delivered, warned once"

# --- phase 5: substituted chain. The impostor's certificate carries the right
# name, so only the pinned CA can reject it — a passing handshake here would
# mean verification is off. Buffered events must later arrive at the real
# receiver, verified.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_EVIL/insert/jsonline'" \
  "pg_logtap.export_tls_server_name = 'localhost'"
sleep 3 # let the reload land before generating
gen p5fail "$N"
sleep 3 # a couple of flush cycles of guaranteed rejections
FAILED3=$(statf send_cycles_failed)
[ "$FAILED3" -gt "$FAILED2" ] 2>/dev/null || { echo "e2e-tls: phase 5 expected failed cycles against the impostor, got $FAILED3 (was $FAILED2)"; exit 1; }
[ "$(received p5fail "$EVIL_OUT")" = 0 ] || { echo "e2e-tls: phase 5 leaked $(received p5fail "$EVIL_OUT") events to the impostor"; exit 1; }
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'"
gen p5re "$N"
wait_for p5fail "$N" "$OUT"
wait_for p5re "$N" "$OUT"
echo "phase 5 ok: impostor chain rejected ($((FAILED3 - FAILED2)) failed cycles), zero leaks, $N buffered + $N live verified at the real receiver"

# --- phase 6: server_name mismatch. The real receiver, the right CA — only
# the name to verify is absent from the SANs. The handshake must fail on the
# name alone; recovery is one SIGHUP away.
set_gucs "pg_logtap.export_tls_server_name = 'mitm.example'"
sleep 3
gen p6fail "$N"
sleep 3
FAILED4=$(statf send_cycles_failed)
[ "$FAILED4" -gt "$FAILED3" ] 2>/dev/null || { echo "e2e-tls: phase 6 expected failed cycles on the name mismatch, got $FAILED4 (was $FAILED3)"; exit 1; }
[ "$(received p6fail "$OUT")" = 0 ] || { echo "e2e-tls: phase 6 leaked $(received p6fail "$OUT") events past the name mismatch"; exit 1; }
set_gucs "pg_logtap.export_tls_server_name = 'localhost'"
gen p6re "$N"
wait_for p6fail "$N" "$OUT"
wait_for p6re "$N" "$OUT"
echo "phase 6 ok: name mismatch rejected ($((FAILED4 - FAILED3)) failed cycles), recovered by SIGHUP alone"

# --- phase 7: intermediate CA, the real-world PKI shape. The chain receiver
# presents leaf+intermediate; the client pins only the root — the handshake
# must build the path through the server-sent intermediate. Then the
# intermediate pinned directly (a trust anchor below the root) must work too.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_CHAIN/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT.root'" \
  "pg_logtap.export_tls_server_name = 'localhost'"
gen p7root "$N"
wait_for p7root "$N" "$CHAIN_OUT"
echo "phase 7 ok: root-pinned verification through the server-sent intermediate, $N/$N"
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT.inter'"
gen p7inter "$N"
wait_for p7inter "$N" "$CHAIN_OUT"
echo "phase 7b ok: intermediate pinned as the trust anchor, $N/$N"

echo "events_per_phase=$N https_ok=$(received p1 "$OUT")+$(received p2fail "$OUT")+$(received p2re "$OUT")+$(received p2bfail "$OUT")+$(received p2bre "$OUT")+$(received p5fail "$OUT")+$(received p5re "$OUT")+$(received p6fail "$OUT")+$(received p6re "$OUT") chain_ok=$(received p7root "$CHAIN_OUT")+$(received p7inter "$CHAIN_OUT") tcps_ok=$(received p3 "$TCPS_OUT")+$(received p4 "$TCPS_OUT") evil_leaks=$(received p5fail "$EVIL_OUT")"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
