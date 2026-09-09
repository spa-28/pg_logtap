#!/bin/sh
# TLS acceptance against a self-signed python receiver on the host:
#   phase 1  verify=on + export_tls_ca = the receiver's own certificate →
#            https:// events delivered
#   phase 2  ca cleared → handshake must FAIL (send_cycles_failed grows,
#            nothing delivered); ca restored → the buffered events arrive
#            (RAM backlog / fallback replay over TLS)
#   phase 2b ca file exists but holds no certificates → handshake fails the
#            same way (send_cycles_failed grows, nothing delivered)
#   phase 2c the ca-cleared failure with the fallback file on → https parks
#            on the queue like any transport and replays over TLS once the
#            ca returns
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
#   phase 8  the ambiguous close: the receiver's TLS layer takes the whole
#            request body, then the connection dies before any status — the
#            send must fail (status read), the events survive in RAM and are
#            replayed whole to the next url; the body the closer did accept
#            is the duplicate window this scenario is contractually allowed
#   phase 9  authenticated https: a receiver demanding a tenant header plus
#            Authorization answers 401 to every send without them (failed
#            cycles, nothing accepted) and delivers with the plain
#            multi-line bearer form (bare \n between lines — normalized on
#            the wire) and with Basic credentials
#   phase 10 the dribbling peer: one handshake-record byte every 2s — each
#            read succeeds inside its SO_RCVTIMEO, so only the absolute
#            per-attempt deadline ends the handshake (failed cycles grow,
#            nothing delivered, worker alive after repointing)
#   phase 11 rapid trust rotation through SIGHUP: ca/name/url alternated
#            across reloads, two rounds of verified → cleared-ca fail →
#            root-pinned chain → name-mismatch fail — the per-handshake
#            bundle rebuild must land the right decision every time
#   phase 12 a receiver pinned to TLS 1.2 ONLY (min=max=TLSv1_2): the 1.2
#            half of the documented 1.2/1.3 support, acceptance-tested —
#            verified delivery, and the negotiated version asserted from
#            the receiver side (every recorded session = TLSv1.2)
#   phase 13 the write-side dribbler on plain http: a receiver draining its
#            socket one byte per second — every body-write syscall succeeds
#            inside its per-write SO_SNDTIMEO (each partial write resets the
#            wait), so only the between-syscall absolute deadline can fail
#            the send (failed cycles grow, the body replays once repointed)
# Markers are per-phase NAMED buckets (received counts DISTINCT markers), so
# a phase's asserts can never be satisfied by another phase's events.
# Usage: scripts/e2e-tls.sh [pg_container] [events_per_phase]
set -u
. "$(dirname "$0")/e2e-common.sh"
e2e_init tls "${1:-}"
N="${2:-10}"
e2e_gate
DIR=$OUT/tls # per-major under E2E_OUT: certs and sinks are rm'd/regenerated per run
OUT=$DIR/https-out.jsonl
TCPS_OUT=$DIR/tcps-out.jsonl
EVIL_OUT=$DIR/evil-out.jsonl
CHAIN_OUT=$DIR/chain-out.jsonl
AMBIG_OUT=$DIR/ambig-out.jsonl
AUTH_OUT=$DIR/auth-out.jsonl
T12_OUT=$DIR/tls12-out.jsonl
T12_VER=$DIR/tls12-ver.txt
CERT=$DIR/cert.pem
KEY=$DIR/key.pem
CA_IN_CT=/tmp/logtap-ca.pem
# E2E_TLS_BASE: the nine host-side listeners move per PG major in a parallel
# matrix (JOBS>1) — one base per major, 16 apart so the +1..+8 ranges cannot
# touch; sequentially the default keeps the historical ports.
TLS_BASE=${E2E_TLS_BASE:-18443}
PORT_HTTPS=$TLS_BASE
PORT_TCPS=$((TLS_BASE + 1))
PORT_EVIL=$((TLS_BASE + 2))
PORT_CHAIN=$((TLS_BASE + 3))
PORT_AMBIG=$((TLS_BASE + 4))
PORT_AUTH=$((TLS_BASE + 5))
PORT_DRIB=$((TLS_BASE + 6))
PORT_T12=$((TLS_BASE + 7))
PORT_WDRIB=$((TLS_BASE + 8))
B64=$(printf %s 'pglogtap:s3cret' | base64 | tr -d '\n') # phase 9's Basic credentials

# The receiver's address as seen from the pg container: the docker network
# gateway (the host). The certificate's SAN carries that IP — verification
# matches the URL host, which is exactly this address.
NET=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}' "$PG_CT")
GW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")

mkdir -p "$DIR"
rm -f "$OUT" "$TCPS_OUT" "$EVIL_OUT" "$CHAIN_OUT" "$AMBIG_OUT" "$AUTH_OUT" "$T12_OUT" "$T12_VER"
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

DIR="$DIR" PORT_HTTPS="$PORT_HTTPS" PORT_TCPS="$PORT_TCPS" PORT_EVIL="$PORT_EVIL" PORT_CHAIN="$PORT_CHAIN" PORT_AMBIG="$PORT_AMBIG" PORT_AUTH="$PORT_AUTH" PORT_DRIB="$PORT_DRIB" PORT_T12="$PORT_T12" PORT_WDRIB="$PORT_WDRIB" python3 - <<'PYEOF' &
import base64
import gzip
import os
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

d = os.environ["DIR"]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))
ctx_evil = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx_evil.load_cert_chain(os.path.join(d, "cert-evil.pem"), os.path.join(d, "key-evil.pem"))
ctx_chain = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx_chain.load_cert_chain(os.path.join(d, "chain.pem"), os.path.join(d, "leaf.key"))
# Phase 12's pinned-version receiver: TLS 1.2 ONLY — a 1.3-only client would
# fail the handshake here, which is exactly what the phase must not happen.
ctx12 = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx12.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))
ctx12.minimum_version = ssl.TLSVersion.TLSv1_2
ctx12.maximum_version = ssl.TLSVersion.TLSv1_2

class H(BaseHTTPRequestHandler):
    sink = "https-out.jsonl"
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        with open(os.path.join(d, type(self).sink), "ab") as f:
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
        data = b""
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
            while True:
                chunk = tls.recv(65536)
                if not chunk:
                    break
                data += chunk
            tls.close()
        except OSError as exc:
            # A probe or a client aborting mid-handshake; the dumper survives.
            # Zero bytes is that routine case. Bytes in hand are the news: a
            # discard here once ate a batch the asserts were counting (peer
            # closed with RST after a full batch — recv raises instead of
            # returning EOF, and the accumulated data went with it).
            if data:
                print(f"dump_tls {out}: {exc!r} after {len(data)} bytes", file=sys.stderr, flush=True)
        if data:
            with open(os.path.join(d, out), "ab") as f:
                f.write(data)
        try:
            conn.close()
        except OSError:
            pass

threading.Thread(target=dump_tls, args=(int(os.environ["PORT_TCPS"]), ctx, "tcps-out.jsonl"), daemon=True).start()
threading.Thread(target=dump_tls, args=(int(os.environ["PORT_EVIL"]), ctx_evil, "evil-out.jsonl"), daemon=True).start()
# Phase 10's dribbler: accept, then feed ONE handshake-record byte every 2s —
# each client read succeeds (per-read SO_RCVTIMEO never fires), only the
# absolute per-attempt deadline can end the handshake. It never completes,
# so verification settings are irrelevant; the bytes are discarded.
def dribble(port):
    raw = socket.socket()
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw.bind(("0.0.0.0", port))
    raw.listen(8)
    while True:
        conn, _ = raw.accept()
        conn.settimeout(30)
        try:
            while True:
                conn.send(b"\x16")
                time.sleep(2)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass

threading.Thread(target=dribble, args=(int(os.environ["PORT_DRIB"]),), daemon=True).start()
# The chain receiver ANSWERS an HTTP status (like the main one): phase 7
# exports to it over https://, and a raw dumper that never replies leaves
# every send dying at the status-read timeout — the batch still reaches the
# socket, so the suite once passed on the retry dump, 5 s per batch, and
# went dead once an inherited fallback file parked the retries.
class HChain(H):
    sink = "chain-out.jsonl"

httpd_chain = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_CHAIN"])), HChain)
httpd_chain.socket = ctx_chain.wrap_socket(httpd_chain.socket, server_side=True)
threading.Thread(target=httpd_chain.serve_forever, daemon=True).start()
# Phase 8's closer: takes the whole request body, then the session ends
# without any status line — never send_response; the client's status read
# sees clean EOF, the exact ambiguous close.
class HAmbig(H):
    sink = "ambig-out.jsonl"
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        with open(os.path.join(d, type(self).sink), "ab") as f:
            f.write(body)
        self.close_connection = True

httpd_ambig = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_AMBIG"])), HAmbig)
httpd_ambig.socket = ctx.wrap_socket(httpd_ambig.socket, server_side=True)
threading.Thread(target=httpd_ambig.serve_forever, daemon=True).start()
# Phase 9's gatekeeper: demands a tenant header AND a bearer token (the
# plain multi-line form — the sender normalizes the bare \n on the wire),
# or Basic credentials; anything less gets the 401 the exporter treats as
# a failed send. A rejected request's body is still read before the answer
# — an unread body turns the server's close into an RST that can discard
# the 401 status bytes still in flight.
BASIC = base64.b64encode(b"pglogtap:s3cret").decode()
class HAuth(H):
    sink = "auth-out.jsonl"
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        auth = self.headers.get("Authorization", "")
        if not ((auth == "Bearer e2e-token" and self.headers.get("X-Logtap-E2E") == "t9") or auth == "Basic " + BASIC):
            self.send_response(401)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"no")
            return
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        with open(os.path.join(d, "auth-out.jsonl"), "ab") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
httpd_auth = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_AUTH"])), HAuth)
httpd_auth.socket = ctx.wrap_socket(httpd_auth.socket, server_side=True)
threading.Thread(target=httpd_auth.serve_forever, daemon=True).start()
# Phase 12's receiver: same cert as the main one, TLS 1.2 pinned. Records the
# negotiated protocol of every session — the assert reads it back, so the
# phase proves WHICH version carried the events, not just that they arrived.
class HTls12(H):
    sink = "tls12-out.jsonl"
    def do_POST(self):
        with open(os.path.join(d, "tls12-ver.txt"), "a") as f:
            f.write(self.connection.version() + "\n")
        return super().do_POST()

httpd_t12 = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_T12"])), HTls12)
httpd_t12.socket = ctx12.wrap_socket(httpd_t12.socket, server_side=True)
threading.Thread(target=httpd_t12.serve_forever, daemon=True).start()
# Phase 13's write-dribbler: a PLAIN http receiver that drains its socket one
# byte per second forever, with a tiny receive buffer so the body cannot all
# sit in flight. Every body-write syscall the worker makes succeeds inside
# its SO_SNDTIMEO (each partial write resets the per-write wait), so only the
# between-syscall absolute deadline can fail the send — the write-side twin
# of the handshake dribbler above. The bytes are discarded.
def dribble_write(port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    srv.bind(("0.0.0.0", port))
    srv.listen(8)
    while True:
        conn, _ = srv.accept()
        try:
            while True:
                conn.recv(1)
                time.sleep(1)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass

threading.Thread(target=dribble_write, args=(int(os.environ["PORT_WDRIB"]),), daemon=True).start()
httpd = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_HTTPS"])), H)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
RECV=$!
trap 'kill $RECV 2>/dev/null' EXIT INT TERM
i=0
until python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT_HTTPS), 1); socket.create_connection(('127.0.0.1', $PORT_TCPS), 1); socket.create_connection(('127.0.0.1', $PORT_EVIL), 1); socket.create_connection(('127.0.0.1', $PORT_CHAIN), 1); socket.create_connection(('127.0.0.1', $PORT_AMBIG), 1); socket.create_connection(('127.0.0.1', $PORT_AUTH), 1); socket.create_connection(('127.0.0.1', $PORT_DRIB), 1); socket.create_connection(('127.0.0.1', $PORT_T12), 1); socket.create_connection(('127.0.0.1', $PORT_WDRIB), 1)" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "e2e-tls: receiver never listened" >&2; exit 1; }
  sleep 1
done

set_gucs() { # each ALTER SYSTEM its own -c: a multi-statement -c silently fails the batch
  for g in "$@"; do
    docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $g" >/dev/null
  done
  docker exec "$PG_CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null
  # Reload barrier, not a timed guess: SHOW runs in a fresh session, which
  # parses the current config generation — poll it until every value
  # landed (pg_reload_conf returns before the postmaster re-reads the
  # files). Then one export_timeout_ms of margin: the worker applies
  # config between cycles, and one in-flight send is bounded by that
  # timeout. Without the barrier, markers generated right after a url
  # switch could ride the OLD url — seen once on a cold stand, 6 of 10.
  for g in "$@"; do
    name=${g%% =*}; val=${g#* = }; val=${val#\'}; val=${val%\'}
    n=0
    while [ "$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW $name")" != "$val" ] && [ "$n" -lt 20 ]; do
      n=$((n + 1)); sleep 1
    done
    [ "$n" -lt 20 ] || fail "set_gucs: $name never became '$val'"
  done
  sleep 5
}

# Matrix predecessors (kill/silent/slow) leave a fallback file configured;
# this suite's deliberate failure phases would park to it, and the tiny
# inherited cap compacts the parked batches away — disk noise the TLS
# asserts do not want. RAM backlog only.
set_gucs "pg_logtap.export_fallback_file = ''"

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

# --- phase 2c: the same failure with the fallback file on — https parks on
# the queue like any transport and replays over TLS once the CA returns
FB_TLS=pglogtap-tlsfb.bin # PGDATA-relative, this suite's own queue
PGD=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW data_directory")
docker exec "$PG_CT" sh -c "rm -f '$PGD/$FB_TLS'"
set_gucs "pg_logtap.export_fallback_file = '$FB_TLS'"
set_gucs "pg_logtap.export_tls_ca = ''"
gen p2cfail "$N"
sleep 3
FAILED2C=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
[ "$FAILED2C" -gt "$FAILED2" ] 2>/dev/null || { echo "e2e-tls: phase 2c expected failed cycles with the ca cleared and the queue on, got $FAILED2C (was $FAILED2)"; exit 1; }
[ "$(received p2cfail "$OUT")" = 0 ] || { echo "e2e-tls: phase 2c leaked $(received p2cfail "$OUT") events through an unverified handshake"; exit 1; }
qsz=$(docker exec "$PG_CT" stat -c %s "$PGD/$FB_TLS" 2>/dev/null || echo 0)
[ "$qsz" -gt 8 ] || { echo "e2e-tls: phase 2c nothing parked on the fallback file ($qsz bytes — RAM backlog only?)"; exit 1; }
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen p2cre "$N"
wait_for p2cfail "$N" "$OUT"
wait_for p2cre "$N" "$OUT"
qsz=$(docker exec "$PG_CT" stat -c %s "$PGD/$FB_TLS" 2>/dev/null || echo 0)
[ "$qsz" = 0 ] || { echo "e2e-tls: phase 2c queue not drained after replay ($qsz bytes left)"; exit 1; }
set_gucs "pg_logtap.export_fallback_file = ''" # later failure phases stay RAM-only
echo "phase 2c ok: https parked to the fallback file over failed handshakes, replayed $((2 * N))/$((2 * N)) over TLS after the CA returned"

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
gen p4 "$N"
# Belt over the set_gucs reload barrier: this wait follows a worker
# TERM/respawn, and a freshly booted worker on a cold box (a CI runner)
# can still be settling when the first events flow. Success returns
# early; only the timeout widens.
wait_for p4 "$N" "$TCPS_OUT" 30
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

# --- phase 8: the ambiguous close — the worst at-least-once case. The
# receiver's TLS layer takes the whole request body, then the connection dies
# before any status line: no 2xx means NOT delivered (the events must survive
# and replay whole to the next url), while the body it did accept is the
# duplicate window the contract allows for exactly this shape.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_AMBIG/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'"
gen p8amb "$N"
sleep 3 # a couple of flush cycles of guaranteed ambiguous closes
FAILED5=$(statf send_cycles_failed)
[ "$FAILED5" -gt "$FAILED4" ] 2>/dev/null || { echo "e2e-tls: phase 8 expected failed cycles on the pre-status close, got $FAILED5 (was $FAILED4)"; exit 1; }
AMBIG_GOT=$(received p8amb "$AMBIG_OUT")
[ "$AMBIG_GOT" -ge 1 ] 2>/dev/null || { echo "e2e-tls: phase 8 the closer never saw a body — the scenario did not happen"; exit 1; }
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'"
wait_for p8amb "$N" "$OUT"
echo "phase 8 ok: pre-status close failed the send, body reached the closer ($AMBIG_GOT distinct, the allowed window), all $N replayed whole"

# --- phase 9: authenticated https. The gatekeeper demands a tenant header
# plus a bearer token — two lines, separated by the two-character \n
# sequence the docs show (ALTER SYSTEM rejects a value with a real newline,
# so the escape is the only multi-line form) — and then Basic credentials:
# the same wire path, the two spellings operators actually type. Without
# the headers every send eats a 401 (failed cycles, nothing accepted);
# the parked events flush whole once the header lands.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_AUTH/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'" \
  "pg_logtap.export_http_extra_headers = ''"
gen p9fail "$N"
sleep 3 # a couple of flush cycles of guaranteed 401s
FAILED6=$(statf send_cycles_failed)
[ "$FAILED6" -gt "$FAILED5" ] 2>/dev/null || { echo "e2e-tls: phase 9 expected failed cycles on the 401s, got $FAILED6 (was $FAILED5)"; exit 1; }
[ "$(received p9fail "$AUTH_OUT")" = 0 ] || { echo "e2e-tls: phase 9 leaked $(received p9fail "$AUTH_OUT") events past the 401 gate"; exit 1; }
set_gucs "pg_logtap.export_http_extra_headers = 'X-Logtap-E2E: t9\nAuthorization: Bearer e2e-token'"
gen p9ok "$N"
wait_for p9fail "$N" "$AUTH_OUT"
wait_for p9ok "$N" "$AUTH_OUT"
echo "phase 9 ok: 401 gate ($((FAILED6 - FAILED5)) failed cycles, zero accepted), $N buffered + $N live with the backslash-n separated bearer form"
set_gucs "pg_logtap.export_http_extra_headers = 'Authorization: Basic $B64'"
gen p9basic "$N"
wait_for p9basic "$N" "$AUTH_OUT"
echo "phase 9b ok: Basic credentials delivered $N/$N"
set_gucs "pg_logtap.export_http_extra_headers = ''"

# --- phase 10: the dribbling peer — the handshake timeout's worst case. One
# record byte every 2s, forever: every individual read succeeds inside its
# SO_RCVTIMEO, so only the ABSOLUTE per-attempt deadline can end the
# handshake. Without it the worker wedges inside the TLS handshake loop
# while the ring backs up (zero failed cycles, no liveness) — the
# discriminating assert is failed cycles GROWING against the dribbler.
TMOUT0=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_timeout_ms")
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_DRIB/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '3000'"
DRIB0=$(statf send_cycles_failed)
gen p10drib "$N"
n=0
while [ "$n" -lt 15 ]; do
  DRIB1=$(statf send_cycles_failed)
  [ "$DRIB1" -ge $((DRIB0 + 2)) ] && break
  n=$((n + 1)); sleep 1
done
[ "${DRIB1:-0}" -ge $((DRIB0 + 2)) ] 2>/dev/null || { echo "e2e-tls: phase 10 expected failed cycles against the dribbler, got ${DRIB1:-none} (was $DRIB0) — the handshake outlived the absolute deadline"; exit 1; }
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '$TMOUT0'"
wait_for p10drib "$N" "$OUT"
echo "phase 10 ok: dribbled handshake ended by the absolute deadline ($((DRIB1 - DRIB0)) failed cycles), all $N replayed once repointed"

# --- phase 11: rapid trust rotation through SIGHUP. The CA bundle is
# rebuilt per handshake; alternating ca/name/url across reloads must land
# the right trust decision EVERY time (no stale bundle, no stale name) with
# the worker alive through the churn. Two full rounds of four decisions
# each: verified → cleared-ca fail → root-pinned chain url → name mismatch.
ROTF=$DRIB1
r=1
while [ "$r" -le 2 ]; do
  set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
    "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
    "pg_logtap.export_tls_server_name = 'localhost'"
  gen rot$r-ok "$N"
  wait_for rot$r-ok "$N" "$OUT"
  set_gucs "pg_logtap.export_tls_ca = ''"
  gen rot$r-bad "$N"
  sleep 3 # a couple of flush cycles of guaranteed failures
  ROTF1=$(statf send_cycles_failed)
  [ "$ROTF1" -gt "$ROTF" ] 2>/dev/null || { echo "e2e-tls: phase 11 round $r: expected failed cycles with the ca cleared, got $ROTF1 (was $ROTF)"; exit 1; }
  [ "$(received rot$r-bad "$OUT")" = 0 ] || { echo "e2e-tls: phase 11 round $r leaked $(received rot$r-bad "$OUT") events past a cleared ca"; exit 1; }
  set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_CHAIN/insert/jsonline'" \
    "pg_logtap.export_tls_ca = '$CA_IN_CT.root'"
  gen rot$r-chain "$N"
  wait_for rot$r-chain "$N" "$CHAIN_OUT"
  set_gucs "pg_logtap.export_tls_server_name = 'mitm.example'"
  gen rot$r-name "$N"
  sleep 3
  ROTF2=$(statf send_cycles_failed)
  [ "$ROTF2" -gt "$ROTF1" ] 2>/dev/null || { echo "e2e-tls: phase 11 round $r: expected failed cycles on the rotated name mismatch, got $ROTF2 (was $ROTF1)"; exit 1; }
  [ "$(received rot$r-name "$CHAIN_OUT")" = 0 ] || { echo "e2e-tls: phase 11 round $r leaked $(received rot$r-name "$CHAIN_OUT") events past the name mismatch"; exit 1; }
  ROTF=$ROTF2
  r=$((r + 1))
done
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'"
echo "phase 11 ok: 2 rounds of verified → cleared-ca fail → root-pinned chain → name-mismatch through SIGHUP churn, no stale trust, no leaks"

# --- phase 12: TLS 1.2, explicitly. The receiver offers 1.2 ONLY
# (minimum=maximum=TLSv1_2) — the client's 1.3 offers cannot land, so a
# delivered batch proves the 1.2 handshake path end to end (key exchange,
# cipher, record framing), and the receiver-recorded session versions prove
# WHICH version carried it. Every other phase negotiates 1.3 silently.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_T12/insert/jsonline'"
gen p12 "$N"
wait_for p12 "$N" "$T12_OUT"
VERS=$(sort -u "$T12_VER" 2>/dev/null)
[ -n "$VERS" ] || { echo "e2e-tls: phase 12 no recorded session version — the receiver never answered"; exit 1; }
[ "$VERS" = "TLSv1.2" ] || { echo "e2e-tls: phase 12 negotiated '$VERS', want TLSv1.2 (receiver pinned to 1.2 only)"; exit 1; }
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'"
echo "phase 12 ok: TLS 1.2-only receiver delivered $N/$N, every session $VERS"

# --- phase 13: the write-side dribbler, on plain http — the body-write twin
# of phase 10. The receiver drains its socket one byte per second: a
# TCP-accepting sink whose every write syscall succeeds inside its per-write
# SO_SNDTIMEO (each partial write resets the wait), so only the
# between-syscall absolute deadline can fail the send. Without that check
# one body stretches across many individually-bounded waits — the worker
# wedges mid-body with zero failed cycles. 500 events ≈ 140 KB of body
# against ~40 KB of in-flight buffers, so the dribble outlives any cycle.
TMOUT1=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_timeout_ms")
set_gucs "pg_logtap.export_url = 'http://$GW:$PORT_WDRIB/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '3000'"
WDRIB0=$(statf send_cycles_failed)
gen p13wd 500
n=0
while [ "$n" -lt 15 ]; do
  WDRIB1=$(statf send_cycles_failed)
  [ "$WDRIB1" -ge $((WDRIB0 + 2)) ] && break
  n=$((n + 1)); sleep 1
done
[ "${WDRIB1:-0}" -ge $((WDRIB0 + 2)) ] 2>/dev/null || { echo "e2e-tls: phase 13 expected failed cycles against the write dribbler, got ${WDRIB1:-none} (was $WDRIB0) — the body write outlived the absolute deadline"; exit 1; }
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '$TMOUT1'"
wait_for p13wd 500 "$OUT" 60
echo "phase 13 ok: dribbled plain-http body write ended by the absolute deadline ($((WDRIB1 - WDRIB0)) failed cycles), all 500 replayed once repointed"

echo "events_per_phase=$N https_ok=$(received p1 "$OUT")+$(received p2fail "$OUT")+$(received p2re "$OUT")+$(received p2bfail "$OUT")+$(received p2bre "$OUT")+$(received p5fail "$OUT")+$(received p5re "$OUT")+$(received p6fail "$OUT")+$(received p6re "$OUT")+$(received p8amb "$OUT") chain_ok=$(received p7root "$CHAIN_OUT")+$(received p7inter "$CHAIN_OUT") tcps_ok=$(received p3 "$TCPS_OUT")+$(received p4 "$TCPS_OUT") auth_ok=$(received p9ok "$AUTH_OUT")+$(received p9basic "$AUTH_OUT") evil_leaks=$(received p5fail "$EVIL_OUT") ambig_body=$(received p8amb "$AMBIG_OUT") dribble_replayed=$(received p10drib "$OUT") rotation_leaks=$(( $(received rot1-bad "$OUT") + $(received rot1-name "$CHAIN_OUT") + $(received rot2-bad "$OUT") + $(received rot2-name "$CHAIN_OUT") )) tls12_ok=$(received p12 "$T12_OUT") tls12_versions=$VERS wdribble_replayed=$(received p13wd "$OUT")"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
