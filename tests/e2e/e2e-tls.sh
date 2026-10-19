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
#            cycles, nothing accepted), validates application/json followed
#            by a SIGHUP reload to the default application/x-ndjson, and
#            delivers with both bearer and Basic credentials
#   phase 10 the dribbling peer: one handshake-record byte every 2s while a
#            repeated worker-SIGHUP storm interrupts readv — every EINTR retry
#            must re-arm from the absolute deadline, so the first failed cycle
#            lands near the original budget while the longer storm still runs
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
#   phase 14 the TLS write-dribbler, both encrypted schemes: the handshake
#            completes, then the receiver drains one decrypted byte per
#            second. During https, repeated SIGHUP interrupts sendmsg; each
#            retry must re-arm from the absolute deadline. First-failure
#            timing proves it lands before the longer storm ends; tcps then
#            covers the same writer without the signal harness
# Markers are per-phase NAMED buckets (received counts DISTINCT markers), so
# a phase's asserts can never be satisfied by another phase's events.
# Guarded system-root probe: PG_LOGTAP_TLS_SYSTEM_ROOT_PROBE=run invokes a
# controller-provided, task-owned PG whose generated chain root is mounted
# read-only at /etc/ssl/certs/ca-certificates.crt. Required controller values:
# LT_TLS_ROOT_PG_CONTAINER, LT_TLS_ROOT_EXPECTED_ID, LT_TLS_ROOT_LABEL_KEY,
# LT_TLS_ROOT_LABEL_VALUE, LT_TLS_ROOT_CA_SOURCE, LT_TLS_ROOT_CA_SHA256 and
# LT_TLS_ROOT_URL (the existing chain receiver URL).
# Usage: tests/e2e/e2e-tls.sh [pg_container] [events_per_phase]
[ -z "${PG_LOGTAP_TLS_SYSTEM_ROOT_PROBE:-}" ] || E2E_TAG=tls-system-root
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tests/e2e/e2e-common.sh
. "$(dirname "$0")/e2e-common.sh"

tls_root_fail() {
  printf '%s\n' "e2e-$E2E_TAG: FAILED: $*" >&2
  exit 1
}

tls_root_psql() {
  docker exec "$tls_root_target" psql -X -U postgres -v ON_ERROR_STOP=1 "$@"
}

tls_root_set_guc() {
  case "$1" in
    pg_logtap.export_url|pg_logtap.export_tls_ca|pg_logtap.export_tls_verify|pg_logtap.export_tls_server_name|pg_logtap.export_fallback_file|pg_logtap.metrics_port) ;;
    *) tls_root_fail "system-root probe: unsupported GUC $1" ;;
  esac
  docker exec -i "$tls_root_target" psql -X -U postgres -v ON_ERROR_STOP=1 \
    -v "guc=$1" -v "value=$2" >/dev/null <<'SQL'
SELECT format('ALTER SYSTEM SET %s = %L', :'guc', :'value')
\gexec
SQL
}

tls_root_expect_guc() {
  n=0
  while [ "$n" -lt 20 ]; do
    [ "$(tls_root_psql -Atc "SHOW $1")" = "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
  tls_root_fail "system-root probe: $1 never became '$2'"
}

tls_root_counter() {
  tls_root_psql -Atc "SELECT substring(pg_logtap_stats() from '$1=([0-9]+)')"
}

tls_root_http_code() {
  docker exec "$tls_root_target" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/9187 || exit
    printf "GET %s HTTP/1.0\r\n\r\n" "$1" >&3
    IFS= read -r -t 8 line <&3 || exit
    set -- $line; printf "%s\n" "$2"
  ' bash "$1" 2>/dev/null
}

tls_system_root_probe() {
  [ -n "${LT_TLS_ROOT_PG_CONTAINER:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_PG_CONTAINER is required"
  [ -n "${LT_TLS_ROOT_EXPECTED_ID:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_EXPECTED_ID is required"
  [ -n "${LT_TLS_ROOT_LABEL_KEY:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_LABEL_KEY is required"
  [ -n "${LT_TLS_ROOT_LABEL_VALUE:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_LABEL_VALUE is required"
  [ -n "${LT_TLS_ROOT_CA_SOURCE:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_CA_SOURCE is required"
  [ -n "${LT_TLS_ROOT_CA_SHA256:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_CA_SHA256 is required"
  [ -n "${LT_TLS_ROOT_URL:-}" ] || tls_root_fail "system-root probe: LT_TLS_ROOT_URL is required"
  case "$LT_TLS_ROOT_LABEL_KEY" in ''|*[!A-Za-z0-9_.-]*) tls_root_fail "system-root probe: invalid label key" ;; esac
  case "$LT_TLS_ROOT_URL" in https://*) ;; *) tls_root_fail "system-root probe: chain receiver must use https" ;; esac

  tls_root_id=$(docker inspect -f '{{.Id}}' "$LT_TLS_ROOT_PG_CONTAINER") || tls_root_fail "system-root probe: cannot inspect supplied PG container"
  [ "$tls_root_id" = "$LT_TLS_ROOT_EXPECTED_ID" ] || tls_root_fail "system-root probe: supplied PG container ID does not match"
  tls_root_target=$tls_root_id
  tls_root_label=$(docker inspect -f "{{index .Config.Labels \"$LT_TLS_ROOT_LABEL_KEY\"}}" "$tls_root_target") || tls_root_fail "system-root probe: cannot read supplied PG label"
  [ "$tls_root_label" = "$LT_TLS_ROOT_LABEL_VALUE" ] || tls_root_fail "system-root probe: supplied PG container label does not match"
  [ "$(docker inspect -f '{{.State.Running}}' "$tls_root_target")" = true ] || tls_root_fail "system-root probe: supplied PG container is not running"
  tls_root_mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/ssl/certs/ca-certificates.crt"}}{{.Source}}|{{.RW}}{{end}}{{end}}' "$tls_root_target") || tls_root_fail "system-root probe: cannot inspect CA mount"
  [ "$tls_root_mount" = "$LT_TLS_ROOT_CA_SOURCE|false" ] || tls_root_fail "system-root probe: generated root is not the expected read-only system-store mount"
  tls_root_hash=$(docker exec "$tls_root_target" sha256sum /etc/ssl/certs/ca-certificates.crt) || tls_root_fail "system-root probe: cannot hash mounted root"
  tls_root_hash=${tls_root_hash%% *}
  [ "$tls_root_hash" = "$LT_TLS_ROOT_CA_SHA256" ] || tls_root_fail "system-root probe: mounted root does not match generated chain root"

  tls_root_set_guc pg_logtap.export_url "$LT_TLS_ROOT_URL" || tls_root_fail "system-root probe: cannot set export_url"
  tls_root_set_guc pg_logtap.export_tls_ca '' || tls_root_fail "system-root probe: cannot clear export_tls_ca"
  tls_root_set_guc pg_logtap.export_tls_verify on || tls_root_fail "system-root probe: cannot set export_tls_verify"
  tls_root_set_guc pg_logtap.export_tls_server_name localhost || tls_root_fail "system-root probe: cannot set export_tls_server_name"
  tls_root_set_guc pg_logtap.export_fallback_file '' || tls_root_fail "system-root probe: cannot clear export_fallback_file"
  tls_root_set_guc pg_logtap.metrics_port 9187 || tls_root_fail "system-root probe: cannot set metrics_port"
  tls_root_psql -qc 'SELECT pg_reload_conf()' >/dev/null || tls_root_fail "system-root probe: cannot reload configuration"
  tls_root_expect_guc pg_logtap.export_url "$LT_TLS_ROOT_URL"
  tls_root_expect_guc pg_logtap.export_tls_ca ''
  tls_root_expect_guc pg_logtap.export_tls_verify on
  tls_root_expect_guc pg_logtap.export_tls_server_name localhost
  tls_root_expect_guc pg_logtap.export_fallback_file ''
  tls_root_expect_guc pg_logtap.metrics_port 9187

  tls_root_sent0=$(tls_root_counter events_sent)
  tls_root_failed0=$(tls_root_counter send_cycles_failed)
  tls_root_psql -qc "DO \$\$ BEGIN RAISE WARNING 'logtap tls-system-root'; END \$\$" >/dev/null || tls_root_fail "system-root probe: cannot emit warning"
  n=0
  while [ "$n" -lt 30 ]; do
    tls_root_sent1=$(tls_root_counter events_sent)
    tls_root_failed1=$(tls_root_counter send_cycles_failed)
    if [ "$tls_root_sent1" -gt "$tls_root_sent0" ] 2>/dev/null &&
       [ "$tls_root_failed1" = "$tls_root_failed0" ] &&
       [ "$(tls_root_http_code /readyz)" = 200 ]; then
      ok "system-root chain verification delivered and readyz stayed 200 without new failed cycles"
      return 0
    fi
    n=$((n + 1)); sleep 1
  done
  [ "${tls_root_failed1:-}" = "$tls_root_failed0" ] || tls_root_fail "system-root probe: failed cycles rose from $tls_root_failed0 to ${tls_root_failed1:-?}"
  [ "${tls_root_sent1:-0}" -gt "$tls_root_sent0" ] 2>/dev/null || tls_root_fail "system-root probe: no delivery through the system-root chain"
  tls_root_fail "system-root probe: readyz did not become 200"
}

case "${PG_LOGTAP_TLS_SYSTEM_ROOT_PROBE:-}" in
  '') ;;
  run) tls_system_root_probe; exit $? ;;
  *) printf '%s\n' 'PG_LOGTAP_TLS_SYSTEM_ROOT_PROBE must be run' >&2; exit 2 ;;
esac

e2e_init tls "${1:-}"
N="${2:-10}"
e2e_gate
METRICS_PORT0=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.metrics_port") \
  || fail "could not snapshot metrics port"
http_code() {
  docker exec "$PG_CT" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/9187 || exit
    printf "GET %s HTTP/1.0\r\n\r\n" "$1" >&3
    IFS= read -r -t 8 line <&3 || exit
    set -- $line; printf "%s\n" "$2"
  ' bash "$1" 2>/dev/null
}
expect_ready() {
  n=0
  while [ "$n" -lt 15 ]; do
    [ "$(http_code /readyz)" = "$1" ] && return 0
    n=$((n + 1)); sleep 1
  done
  fail "TLS receiver readyz did not become $1"
}
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
# E2E_TLS_BASE: the ten host-side listeners move per PG major in a parallel
# matrix (JOBS>1) — one base per major, 16 apart so the +1..+9 ranges cannot
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
PORT_TDRIB=$((TLS_BASE + 9))
B64=$(printf %s 'pglogtap:s3cret' | base64 | tr -d '\n') # phase 9's Basic credentials

# E2E_TLS_PYTHON opts into the controller-owned, container-local fixture. It
# keeps normal CI's host receiver unchanged while avoiding host listeners for
# the private owned-run adapter.
TLS_PYTHON=${E2E_TLS_PYTHON:-}
TLS_CT_ID=
TLS_DIR_IN_CT=
TLS_PID_IN_CT=
TLS_DIR_CLEANUP=0
if [ -n "$TLS_PYTHON" ]; then
  TLS_CT_ID=$(docker inspect -f '{{.Id}}' "$PG_CT") || fail "could not identify TLS fixture container"
  [ -n "$TLS_CT_ID" ] || fail "TLS fixture container has no immutable ID"
  GW=127.0.0.1
else
  # The normal receiver's address as seen from the pg container is the Docker
  # network gateway (the host); its certificate carries that IP.
  NET=$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}' "$PG_CT")
  GW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")
fi

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

cat > "$DIR/receiver.py" <<'PYEOF'
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
# Phase 5 must exercise the same complete status-only HTTP acknowledgement as
# the trusted sink: record the decoded body before returning its numeric status.
class HEvil(H):
    sink = "evil-out.jsonl"

httpd_evil = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_EVIL"])), HEvil)
httpd_evil.socket = ctx_evil.wrap_socket(httpd_evil.socket, server_side=True)
threading.Thread(target=httpd_evil.serve_forever, daemon=True).start()
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
        with open(os.path.join(d, "drib-evidence"), "a") as f:
            f.write("connected\n")
        conn.settimeout(30)
        try:
            while True:
                if not conn.send(b"\x16"):
                    break
                with open(os.path.join(d, "drib-evidence"), "a") as f:
                    f.write("bytes\n")
                time.sleep(2)
        except OSError:
            pass
        finally:
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
# Phase 9's gatekeeper: bearer requests name the Content-Type they expect
# through the tenant marker, while Basic credentials require the default.
# Anything unauthenticated gets the 401 the exporter treats as a failed send;
# a valid credential with the wrong sender-owned Content-Type gets 415. Every
# rejected request's body is still read before the answer — an unread body
# turns the server's close into an RST that can discard the status bytes.
BASIC = base64.b64encode(b"pglogtap:s3cret").decode()
class HAuth(H):
    sink = "auth-out.jsonl"
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        auth = self.headers.get("Authorization", "")
        tenant = self.headers.get("X-Logtap-E2E", "")
        expected_type = {
            "t9-json": "application/json",
            "t9-default": "application/x-ndjson",
        }.get(tenant)
        if auth == "Bearer e2e-token":
            authenticated = expected_type is not None
        elif auth == "Basic " + BASIC:
            authenticated = True
            expected_type = "application/x-ndjson"
        else:
            authenticated = False
        if not authenticated:
            self.send_response(401)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"no")
            return
        if self.headers.get("Content-Type") != expected_type:
            self.send_response(415)
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
        with open(os.path.join(d, "wdrib-evidence"), "a") as f:
            f.write("connected\n")
        try:
            while True:
                chunk = conn.recv(1)
                if not chunk:
                    break
                with open(os.path.join(d, "wdrib-evidence"), "a") as f:
                    f.write("bytes\n")
                time.sleep(1)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

threading.Thread(target=dribble_write, args=(int(os.environ["PORT_WDRIB"]),), daemon=True).start()
# Phase 14's TLS write-dribbler: the phase-13 drain wrapped in a COMPLETED
# handshake — the write-side twin of phase 10. The handshake answers
# normally, then the receiver reads ONE decrypted byte per second with the
# same tiny receive buffer: every TLS record write the worker makes
# succeeds inside its SO_SNDTIMEO, and a 64 KB chunk spans several records,
# so only the per-write re-arm of the absolute deadline can fail the send.
# One listener serves the https and tcps sub-cases — neither ever reaches
# a status read. The bytes are discarded.
def dribble_write_tls(port, ctx):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    srv.bind(("0.0.0.0", port))
    srv.listen(8)
    def handle(conn):
        tls = None
        stage = None
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
            while True:
                chunk = tls.recv(1)
                if not chunk:
                    break
                if stage is None:
                    # HTTP starts POST; raw tcps NDJSON starts with its JSON body.
                    stage = "https" if chunk == b"P" else "tcps"
                    with open(os.path.join(d, "tdrib-evidence"), "a") as f:
                        f.write(f"{stage}-connected\n{stage}-handshake\n{stage}-bytes\n")
                else:
                    with open(os.path.join(d, "tdrib-evidence"), "a") as f:
                        f.write(f"{stage}-bytes\n")
                time.sleep(1)
        except OSError:
            pass
        finally:
            if tls is not None:
                try:
                    tls.close()
                except OSError:
                    pass
            try:
                conn.close()
            except OSError:
                pass
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()

threading.Thread(target=dribble_write_tls, args=(int(os.environ["PORT_TDRIB"]), ctx), daemon=True).start()
httpd = ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT_HTTPS"])), H)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
RECV=
cleanup() {
  cleanup_status=$?
  trap - EXIT INT TERM
  if [ -n "$TLS_PYTHON" ] && [ "$TLS_DIR_CLEANUP" = 1 ]; then
    if [ "$cleanup_status" -ne 0 ]; then
      mkdir -p "$DIR/receiver-failed" 2>/dev/null || true
      docker cp "$TLS_CT_ID:$TLS_DIR_IN_CT/." "$DIR/receiver-failed/" >/dev/null 2>&1 || true
    fi
    docker exec "$TLS_CT_ID" sh -c 'test ! -r "$1" || kill "$(cat "$1")" 2>/dev/null || true; rm -rf "$2"' sh "$TLS_PID_IN_CT" "$TLS_DIR_IN_CT" >/dev/null 2>&1 || true
  else
    kill "$RECV" 2>/dev/null || true
  fi
  setguc pg_logtap.metrics_port "$METRICS_PORT0" && reload || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup EXIT INT TERM
if [ -n "$TLS_PYTHON" ]; then
  TLS_DIR_IN_CT="/tmp/pg-logtap-tls-$E2E_TAG-$$"
  TLS_PID_IN_CT="$TLS_DIR_IN_CT/receiver.pid"
  docker exec "$TLS_CT_ID" test -x "$TLS_PYTHON" || fail "E2E_TLS_PYTHON is not executable in the owned container"
  TLS_DIR_CLEANUP=1 # private unique path: cleanup is armed before mkdir/copy/start
  docker exec "$TLS_CT_ID" mkdir -p "$TLS_DIR_IN_CT" || fail "could not create private TLS fixture directory"
  docker cp "$DIR/." "$TLS_CT_ID:$TLS_DIR_IN_CT/" || fail "could not copy TLS fixture into owned container"
  LD_LIBRARY_PATH=${E2E_TLS_LD_LIBRARY_PATH:-} docker exec -e LD_LIBRARY_PATH \
    -e "DIR=$TLS_DIR_IN_CT" -e "PORT_HTTPS=$PORT_HTTPS" -e "PORT_TCPS=$PORT_TCPS" \
    -e "PORT_EVIL=$PORT_EVIL" -e "PORT_CHAIN=$PORT_CHAIN" -e "PORT_AMBIG=$PORT_AMBIG" \
    -e "PORT_AUTH=$PORT_AUTH" -e "PORT_DRIB=$PORT_DRIB" -e "PORT_T12=$PORT_T12" \
    -e "PORT_WDRIB=$PORT_WDRIB" -e "PORT_TDRIB=$PORT_TDRIB" "$TLS_CT_ID" sh -c \
    'gate="$4.start"; rm -f "$4" "$gate"; nohup sh -c '\''while [ ! -e "$3" ]; do sleep 1; done; exec "$1" -I -S -u "$2"'\'' sh "$1" "$2" "$gate" >"$3" 2>&1 & pid=$!; printf "%s\n" "$pid" >"$4" || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; exit 1; }; : >"$gate"' sh \
    "$TLS_PYTHON" "$TLS_DIR_IN_CT/receiver.py" "$TLS_DIR_IN_CT/receiver.log" "$TLS_PID_IN_CT" \
    || fail "could not start container-local TLS receiver"
else
  (
    export DIR PORT_HTTPS PORT_TCPS PORT_EVIL PORT_CHAIN PORT_AMBIG PORT_AUTH PORT_DRIB PORT_T12 PORT_WDRIB PORT_TDRIB
    exec python3 "$DIR/receiver.py"
  ) &
  RECV=$!
fi

sync_receiver_file() {
  [ -z "$TLS_PYTHON" ] && return 0
  remote=$TLS_DIR_IN_CT/$(basename "$1")
  if docker exec "$TLS_CT_ID" test -e "$remote"; then
    docker cp "$TLS_CT_ID:$remote" "$1" || fail "could not transfer receiver evidence $remote"
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "could not inspect receiver evidence $remote"
  [ ! -e "$1" ] || fail "receiver evidence disappeared remotely: $remote"
}
received() { # TLS receiver outputs are copied back only for the opt-in adapter.
  file=${2:-$OUT}
  sync_receiver_file "$file"
  grep -oE "logtap $E2E_TAG $1$E2E_SUF [0-9]+" "$file" 2>/dev/null | sort -u | wc -l
}
received_count() { # checked count for callers that cannot preserve substitution status.
  RECEIVED=$(received "$@") || fail "could not count required receiver evidence ${2:-$OUT}"
}
require_tdrib_stage() { # stage-specific evidence prevents HTTPS satisfying tcps.
  stage=$1
  evidence=${2:-$DIR/tdrib-evidence}
  if grep -qx "$stage-connected" "$evidence" && grep -qx "$stage-handshake" "$evidence" && grep -qx "$stage-bytes" "$evidence"; then
    return 0
  fi
  fail "e2e-tls: phase 14 $stage timed out before its own TLS connection, handshake, and decrypted body progress"
}
receiver_ready() {
  probe="import socket; [socket.create_connection(('127.0.0.1', p), 1).close() for p in ($PORT_HTTPS, $PORT_TCPS, $PORT_EVIL, $PORT_CHAIN, $PORT_AMBIG, $PORT_AUTH, $PORT_DRIB, $PORT_T12, $PORT_WDRIB, $PORT_TDRIB)]"
  if [ -n "$TLS_PYTHON" ]; then
    LD_LIBRARY_PATH=${E2E_TLS_LD_LIBRARY_PATH:-} docker exec -e LD_LIBRARY_PATH "$TLS_CT_ID" "$TLS_PYTHON" -I -S -c "$probe"
  else
    python3 -c "$probe"
  fi
}
i=0
until receiver_ready 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "e2e-tls: receiver never listened" >&2; exit 1; }
  sleep 1
done
if [ -n "$TLS_PYTHON" ]; then
  docker exec "$TLS_CT_ID" sh -c ': > "$1"; : > "$2"; : > "$3"' sh \
    "$TLS_DIR_IN_CT/drib-evidence" "$TLS_DIR_IN_CT/wdrib-evidence" "$TLS_DIR_IN_CT/tdrib-evidence" \
    || fail "could not reset TLS stage evidence"
fi
: > "$DIR/drib-evidence"
: > "$DIR/wdrib-evidence"
: > "$DIR/tdrib-evidence"
# A successful controlled request proves the impostor detector itself is live;
# phase 5's nonce cannot otherwise distinguish a dead fixture from good trust.
EVIL_PROBE='import gzip,socket,ssl,sys; b=gzip.compress(b"{\"detector\":\"evil-live\"}\n"); s=ssl._create_unverified_context().wrap_socket(socket.create_connection(("127.0.0.1",int(sys.argv[1]))),server_hostname="localhost"); s.sendall(b"POST /insert/jsonline HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: "+str(len(b)).encode()+b"\r\nConnection: close\r\n\r\n"+b); assert b" 200 " in s.recv(128); s.close()'
if [ -n "$TLS_PYTHON" ]; then
  LD_LIBRARY_PATH=${E2E_TLS_LD_LIBRARY_PATH:-} docker exec -e LD_LIBRARY_PATH "$TLS_CT_ID" "$TLS_PYTHON" -I -S -c "$EVIL_PROBE" "$PORT_EVIL" || fail "impostor control request failed"
else
  python3 -c "$EVIL_PROBE" "$PORT_EVIL" || fail "impostor control request failed"
fi
sync_receiver_file "$EVIL_OUT"
grep -Fqx '{"detector":"evil-live"}' "$EVIL_OUT" || fail "impostor did not record the accepted control request"

start_hup_storm() { # worker-pid, 100ms signal count; sets HUP_STORM_PID
  docker exec "$PG_CT" sh -c "i=0; while [ \$i -lt $2 ]; do kill -HUP '$1' 2>/dev/null || true; i=\$((i + 1)); sleep 0.1; done" >/dev/null 2>&1 &
  HUP_STORM_PID=$!
}

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
set_gucs "pg_logtap.export_fallback_file = ''" "pg_logtap.metrics_port = '9187'"

# --- name GUC bounds: these ALTER SYSTEM rejections happen while export is
# disabled, so neither invalid value can start a socket send. The TLS boundary
# has its own invalid-fd unit proof for values that bypass this hook.
set_gucs "pg_logtap.export_url = ''" "pg_logtap.export_tls_server_name = ''"
NAME255=$(python3 -c 'print("a" * 255)')
NAME256=$(python3 -c 'print("a" * 256)')
NAME65536=$(python3 -c 'print("a" * 65536)')
apply_server_name() {
  setguc pg_logtap.export_tls_server_name "$1" || return 1
  reload || return 1
  n=0
  while [ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SHOW pg_logtap.export_tls_server_name')" != "$1" ] && [ "$n" -lt 20 ]; do
    n=$((n + 1)); sleep 1
  done
  [ "$n" -lt 20 ]
}
apply_server_name "$NAME255" || fail "TLS server_name: could not apply the accepted 255-byte value"
SENT_NAME0=$(statf events_sent)
FAILED_NAME0=$(statf send_cycles_failed)
reject_server_name() {
  if setguc pg_logtap.export_tls_server_name "$1" >/dev/null 2>&1; then
    fail "TLS server_name: accepted ${#1}-byte value"
  fi
}
reject_server_name "$NAME256"
reject_server_name "$NAME65536"
[ "$(docker exec "$PG_CT" psql -U postgres -Atc 'SHOW pg_logtap.export_tls_server_name')" = "$NAME255" ] \
  || fail "TLS server_name: rejected value replaced the active 255-byte name"
[ "$(statf events_sent)" = "$SENT_NAME0" ] && [ "$(statf send_cycles_failed)" = "$FAILED_NAME0" ] \
  || fail "TLS server_name: rejected GUC started an export send"
apply_server_name '' || fail "TLS server_name: could not restore the empty value"
echo "TLS server_name bounds ok: empty and 255 bytes accepted; 256 and 65536 rejected before send"

# --- phase 1: verified https. server_name exercises the GUC AND the std
# limitation it exists for: verifyHostName matches dNSName SANs only, an
# iPAddress SAN never matches the IP-literal URL host.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'" \
  "pg_logtap.export_tls_verify = on"
gen p1 "$N"
wait_for p1 "$N" "$OUT"
expect_ready 200
echo "phase 1 ok: verified https delivered $N/$N, readyz=200"

# --- phase 2: no CA → handshake must fail, then recover with replay
set_gucs "pg_logtap.export_tls_ca = ''"
gen p2fail "$N"
sleep 3 # a couple of flush cycles of guaranteed failures
FAILED=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
[ "$FAILED" -gt 0 ] 2>/dev/null || { echo "e2e-tls: phase 2 expected failed cycles with the ca cleared, got $FAILED"; exit 1; }
received_count p2fail "$OUT"
[ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 2 leaked $RECEIVED events through an unverified handshake"; exit 1; }
expect_ready 503
[ "$(http_code /healthz)" = 200 ] && [ "$(http_code /livez)" = 200 ] \
  || fail "TLS CA failure broke liveness"
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen p2re "$N" # live events join the buffered ones on recovery
wait_for p2fail "$N" "$OUT"
wait_for p2re "$N" "$OUT"
expect_ready 200
echo "phase 2 ok: $FAILED failed cycles, nothing delivered unverified, $N buffered + $N live replayed; same URL readyz=503→200"

# --- phase 2b: a CA file that exists but holds no certificates (created
# empty, or the wrong file pointed at) must fail the handshake the same way
# — not silently fall back to any verification path
docker exec "$PG_CT" touch "$CA_IN_CT.empty"
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT.empty'"
gen p2bfail "$N"
sleep 3
FAILED2=$(docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" | grep -o 'send_cycles_failed=[0-9]*' | head -1 | cut -d= -f2)
[ "$FAILED2" -gt "$FAILED" ] 2>/dev/null || { echo "e2e-tls: phase 2b expected failed cycles with an empty ca file, got $FAILED2 (was $FAILED)"; exit 1; }
received_count p2bfail "$OUT"
[ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 2b leaked $RECEIVED events through a certificate-less CA"; exit 1; }
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
received_count p2cfail "$OUT"
[ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 2c leaked $RECEIVED events through an unverified handshake"; exit 1; }
qsz=$(docker exec "$PG_CT" stat -c %s "$PGD/$FB_TLS" 2>/dev/null || echo 0)
[ "$qsz" -gt 8 ] || { echo "e2e-tls: phase 2c nothing parked on the fallback file ($qsz bytes — RAM backlog only?)"; exit 1; }
expect_ready 503
set_gucs "pg_logtap.export_tls_ca = '$CA_IN_CT'"
gen p2cre "$N"
wait_for p2cfail "$N" "$OUT"
wait_for p2cre "$N" "$OUT"
expect_ready 200
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
P5_FAILED0=$(statf send_cycles_failed)
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_EVIL/insert/jsonline'" \
  "pg_logtap.export_tls_server_name = 'localhost'"
gen p5fail "$N"
n=0
while [ "$n" -lt 15 ]; do
  FAILED3=$(statf send_cycles_failed)
  [ "$FAILED3" -gt "$P5_FAILED0" ] && break
  n=$((n + 1)); sleep 1
done
[ "${FAILED3:-0}" -gt "$P5_FAILED0" ] 2>/dev/null || fail "e2e-tls: phase 5 had no failed cycle against the live impostor"
# The p5 nonce is current-run-local; after a settled failed cycle it must stay
# absent from the accepting impostor's decoded sink.
n=0
while [ "$n" -lt 3 ]; do
  received_count p5fail "$EVIL_OUT"
  [ "$RECEIVED" = 0 ] || fail "e2e-tls: phase 5 leaked $RECEIVED events to the impostor"
  n=$((n + 1)); sleep 1
done
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'"
gen p5re "$N"
wait_for p5fail "$N" "$OUT"
wait_for p5re "$N" "$OUT"
echo "phase 5 ok: live impostor chain rejected ($((FAILED3 - P5_FAILED0)) failed cycles), settled current-run zero leaks, $N buffered + $N live verified at the real receiver"

# --- phase 6: server_name mismatch. The real receiver, the right CA — only
# the name to verify is absent from the SANs. The handshake must fail on the
# name alone; recovery is one SIGHUP away.
set_gucs "pg_logtap.export_tls_server_name = 'mitm.example'"
gen p6fail "$N"
sleep 3
FAILED4=$(statf send_cycles_failed)
[ "$FAILED4" -gt "$FAILED3" ] 2>/dev/null || { echo "e2e-tls: phase 6 expected failed cycles on the name mismatch, got $FAILED4 (was $FAILED3)"; exit 1; }
received_count p6fail "$OUT"
[ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 6 leaked $RECEIVED events past the name mismatch"; exit 1; }
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
received_count p8amb "$AMBIG_OUT"
AMBIG_GOT=$RECEIVED
[ "$AMBIG_GOT" -ge 1 ] 2>/dev/null || { echo "e2e-tls: phase 8 the closer never saw a body — the scenario did not happen"; exit 1; }
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'"
wait_for p8amb "$N" "$OUT"
echo "phase 8 ok: pre-status close failed the send, body reached the closer ($AMBIG_GOT distinct, the allowed window), all $N replayed whole"

# --- phase 9: authenticated https plus sender-owned Content-Type reload. The
# gatekeeper demands a tenant header AND bearer token — two lines separated by
# the two-character \n form — and checks application/json first, then the
# application/x-ndjson default after a second SIGHUP. Basic credentials finish
# on that restored default. Without headers every send eats a 401 (failed
# cycles, nothing accepted); the parked events flush whole once auth lands.
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_AUTH/insert/jsonline'" \
  "pg_logtap.export_tls_ca = '$CA_IN_CT'" \
  "pg_logtap.export_tls_server_name = 'localhost'" \
  "pg_logtap.export_http_content_type = 'application/x-ndjson'" \
  "pg_logtap.export_http_extra_headers = ''"
gen p9fail "$N"
sleep 3 # a couple of flush cycles of guaranteed 401s
FAILED6=$(statf send_cycles_failed)
[ "$FAILED6" -gt "$FAILED5" ] 2>/dev/null || { echo "e2e-tls: phase 9 expected failed cycles on the 401s, got $FAILED6 (was $FAILED5)"; exit 1; }
received_count p9fail "$AUTH_OUT"
[ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 9 leaked $RECEIVED events past the 401 gate"; exit 1; }
set_gucs "pg_logtap.export_http_content_type = 'application/json'" \
  "pg_logtap.export_http_extra_headers = 'X-Logtap-E2E: t9-json\nAuthorization: Bearer e2e-token'"
gen p9json "$N"
wait_for p9fail "$N" "$AUTH_OUT"
wait_for p9json "$N" "$AUTH_OUT"
echo "phase 9a ok: 401 gate ($((FAILED6 - FAILED5)) failed cycles), then application/json delivered $N buffered + $N live"
set_gucs "pg_logtap.export_http_content_type = 'application/x-ndjson'" \
  "pg_logtap.export_http_extra_headers = 'X-Logtap-E2E: t9-default\nAuthorization: Bearer e2e-token'"
gen p9default "$N"
wait_for p9default "$N" "$AUTH_OUT"
echo "phase 9b ok: SIGHUP restored application/x-ndjson and delivered $N/$N"
set_gucs "pg_logtap.export_http_extra_headers = 'Authorization: Basic $B64'"
gen p9basic "$N"
wait_for p9basic "$N" "$AUTH_OUT"
echo "phase 9c ok: Basic credentials delivered $N/$N on the default Content-Type"
set_gucs "pg_logtap.export_http_extra_headers = ''" \
  "pg_logtap.export_http_content_type = 'application/x-ndjson'"

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
DRIB_WPID=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$DRIB_WPID" ] || fail "e2e-tls: phase 10 worker not found"
DRIB_T0=$(date +%s%3N)
gen p10drib "$N"
sleep 0.2
start_hup_storm "$DRIB_WPID" 100
DRIB_FIRST=0
DRIB_STORM_ACTIVE=0
n=0
while [ "$n" -lt 80 ]; do
  DRIB1=$(statf send_cycles_failed)
  if [ "$DRIB1" -ge $((DRIB0 + 1)) ]; then
    DRIB_FIRST=$(date +%s%3N)
    kill -0 "$HUP_STORM_PID" 2>/dev/null && DRIB_STORM_ACTIVE=1
    break
  fi
  n=$((n + 1)); sleep 0.1
done
wait "$HUP_STORM_PID"
[ "$DRIB_FIRST" -gt 0 ] || fail "e2e-tls: phase 10 no failed cycle within 8s under repeated SIGHUP"
DRIB_FIRST_MS=$((DRIB_FIRST - DRIB_T0))
[ "$DRIB_STORM_ACTIVE" = 1 ] \
  || fail "e2e-tls: phase 10 first failure appeared only after the SIGHUP storm ended (${DRIB_FIRST_MS}ms)"
[ "$DRIB_FIRST_MS" -le 6000 ] \
  || fail "e2e-tls: phase 10 first failure took ${DRIB_FIRST_MS}ms with a 3000ms attempt budget"
sync_receiver_file "$DIR/drib-evidence"
if ! grep -qx connected "$DIR/drib-evidence" || ! grep -qx bytes "$DIR/drib-evidence"; then
  fail "e2e-tls: phase 10 timed out before the dribbler accepted and wrote a handshake byte"
fi
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
echo "phase 10 ok: SIGHUP-interrupted TLS reads failed in ${DRIB_FIRST_MS}ms while the storm ran ($((DRIB1 - DRIB0)) failed cycles), all $N replayed once repointed"

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
  received_count rot$r-bad "$OUT"
  [ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 11 round $r leaked $RECEIVED events past a cleared ca"; exit 1; }
  set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_CHAIN/insert/jsonline'" \
    "pg_logtap.export_tls_ca = '$CA_IN_CT.root'"
  gen rot$r-chain "$N"
  wait_for rot$r-chain "$N" "$CHAIN_OUT"
  set_gucs "pg_logtap.export_tls_server_name = 'mitm.example'"
  gen rot$r-name "$N"
  sleep 3
  ROTF2=$(statf send_cycles_failed)
  [ "$ROTF2" -gt "$ROTF1" ] 2>/dev/null || { echo "e2e-tls: phase 11 round $r: expected failed cycles on the rotated name mismatch, got $ROTF2 (was $ROTF1)"; exit 1; }
  received_count rot$r-name "$CHAIN_OUT"
  [ "$RECEIVED" = 0 ] || { echo "e2e-tls: phase 11 round $r leaked $RECEIVED events past the name mismatch"; exit 1; }
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
sync_receiver_file "$T12_VER"
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
sync_receiver_file "$DIR/wdrib-evidence"
if ! grep -qx connected "$DIR/wdrib-evidence" || ! grep -qx bytes "$DIR/wdrib-evidence"; then
  fail "e2e-tls: phase 13 timed out before the plain dribbler accepted and read body bytes"
fi
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '$TMOUT1'"
wait_for p13wd 500 "$OUT" 60
echo "phase 13 ok: dribbled plain-http body write ended by the absolute deadline ($((WDRIB1 - WDRIB0)) failed cycles), all 500 replayed once repointed"

# --- phase 14: the TLS write-dribbler — phase 13's drain over TLS, both
# encrypted schemes. The handshake completes normally; the receiver then
# drains ONE decrypted byte per second. The https attempt also takes repeated
# SIGHUP while blocked in sendmsg: each EINTR must return through arm(), not
# restart the stale relative SO_SNDTIMEO. The first failure must land under
# the original absolute budget while the longer signal storm is still alive.
# tcps then covers the same writer without the harness; both bodies replay to
# the repointed https sink.
TMOUT2=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW pg_logtap.export_timeout_ms")
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_TDRIB/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '3000'"
TDRIB0=$(statf send_cycles_failed)
TDRIB_WPID=$(docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'")
[ -n "$TDRIB_WPID" ] || fail "e2e-tls: phase 14 worker not found"
TDRIB_T0=$(date +%s%3N)
gen p14h 500
sleep 0.2
start_hup_storm "$TDRIB_WPID" 100
TDRIB_FIRST=0
TDRIB_STORM_ACTIVE=0
n=0
while [ "$n" -lt 90 ]; do
  TDRIB1=$(statf send_cycles_failed)
  if [ "$TDRIB1" -ge $((TDRIB0 + 1)) ]; then
    TDRIB_FIRST=$(date +%s%3N)
    kill -0 "$HUP_STORM_PID" 2>/dev/null && TDRIB_STORM_ACTIVE=1
    break
  fi
  n=$((n + 1)); sleep 0.1
done
wait "$HUP_STORM_PID"
[ "$TDRIB_FIRST" -gt 0 ] || fail "e2e-tls: phase 14 https had no failed cycle within 9s under repeated SIGHUP"
TDRIB_FIRST_MS=$((TDRIB_FIRST - TDRIB_T0))
[ "$TDRIB_STORM_ACTIVE" = 1 ] \
  || fail "e2e-tls: phase 14 https first failure appeared only after the SIGHUP storm ended (${TDRIB_FIRST_MS}ms)"
[ "$TDRIB_FIRST_MS" -le 8000 ] \
  || fail "e2e-tls: phase 14 https first failure took ${TDRIB_FIRST_MS}ms with a 3000ms attempt budget"
sync_receiver_file "$DIR/tdrib-evidence"
require_tdrib_stage https
n=0
while [ "$n" -lt 15 ]; do
  TDRIB1=$(statf send_cycles_failed)
  [ "$TDRIB1" -ge $((TDRIB0 + 2)) ] && break
  n=$((n + 1)); sleep 1
done
[ "${TDRIB1:-0}" -ge $((TDRIB0 + 2)) ] 2>/dev/null || { echo "e2e-tls: phase 14 https expected failed cycles against the TLS write dribbler, got ${TDRIB1:-none} (was $TDRIB0) — the encrypted body write outlived the absolute deadline"; exit 1; }
set_gucs "pg_logtap.export_url = 'tcps://$GW:$PORT_TDRIB'"
TDRIB2=$(statf send_cycles_failed)
gen p14t 500
n=0
while [ "$n" -lt 15 ]; do
  TDRIB3=$(statf send_cycles_failed)
  [ "$TDRIB3" -ge $((TDRIB2 + 2)) ] && break
  n=$((n + 1)); sleep 1
done
[ "${TDRIB3:-0}" -ge $((TDRIB2 + 2)) ] 2>/dev/null || { echo "e2e-tls: phase 14 tcps expected failed cycles against the TLS write dribbler, got ${TDRIB3:-none} (was $TDRIB2) — the encrypted body write outlived the absolute deadline"; exit 1; }
sync_receiver_file "$DIR/tdrib-evidence"
require_tdrib_stage tcps
set_gucs "pg_logtap.export_url = 'https://$GW:$PORT_HTTPS/insert/jsonline'" \
  "pg_logtap.export_timeout_ms = '$TMOUT2'"
wait_for p14h 500 "$OUT" 60
wait_for p14t 500 "$OUT" 60
echo "phase 14 ok: SIGHUP-interrupted https sendmsg failed in ${TDRIB_FIRST_MS}ms; https+tcps stayed deadline-bounded ($((TDRIB1 - TDRIB0)) + $((TDRIB3 - TDRIB2)) failed cycles), all 1000 replayed once repointed"

received_count p1 "$OUT"; P1=$RECEIVED
received_count p2fail "$OUT"; P2FAIL=$RECEIVED
received_count p2re "$OUT"; P2RE=$RECEIVED
received_count p2bfail "$OUT"; P2BFAIL=$RECEIVED
received_count p2bre "$OUT"; P2BRE=$RECEIVED
received_count p5fail "$OUT"; P5FAIL=$RECEIVED
received_count p5re "$OUT"; P5RE=$RECEIVED
received_count p6fail "$OUT"; P6FAIL=$RECEIVED
received_count p6re "$OUT"; P6RE=$RECEIVED
received_count p8amb "$OUT"; P8AMB=$RECEIVED
received_count p7root "$CHAIN_OUT"; P7ROOT=$RECEIVED
received_count p7inter "$CHAIN_OUT"; P7INTER=$RECEIVED
received_count p3 "$TCPS_OUT"; P3=$RECEIVED
received_count p4 "$TCPS_OUT"; P4=$RECEIVED
received_count p9fail "$AUTH_OUT"; P9FAIL=$RECEIVED
received_count p9json "$AUTH_OUT"; P9JSON=$RECEIVED
received_count p9default "$AUTH_OUT"; P9DEFAULT=$RECEIVED
received_count p9basic "$AUTH_OUT"; P9BASIC=$RECEIVED
received_count p5fail "$EVIL_OUT"; EVIL_LEAKS=$RECEIVED
received_count p8amb "$AMBIG_OUT"; AMBIG_BODY=$RECEIVED
received_count p10drib "$OUT"; P10DRIB=$RECEIVED
received_count rot1-bad "$OUT"; ROT1BAD=$RECEIVED
received_count rot1-name "$CHAIN_OUT"; ROT1NAME=$RECEIVED
received_count rot2-bad "$OUT"; ROT2BAD=$RECEIVED
received_count rot2-name "$CHAIN_OUT"; ROT2NAME=$RECEIVED
received_count p12 "$T12_OUT"; P12=$RECEIVED
received_count p13wd "$OUT"; P13WD=$RECEIVED
received_count p14h "$OUT"; P14H=$RECEIVED
received_count p14t "$OUT"; P14T=$RECEIVED
echo "events_per_phase=$N https_ok=$P1+$P2FAIL+$P2RE+$P2BFAIL+$P2BRE+$P5FAIL+$P5RE+$P6FAIL+$P6RE+$P8AMB chain_ok=$P7ROOT+$P7INTER tcps_ok=$P3+$P4 auth_ok=$P9FAIL+$P9JSON+$P9DEFAULT+$P9BASIC evil_leaks=$EVIL_LEAKS ambig_body=$AMBIG_BODY dribble_replayed=$P10DRIB rotation_leaks=$(( ROT1BAD + ROT1NAME + ROT2BAD + ROT2NAME )) tls12_ok=$P12 tls12_versions=$VERS wdribble_replayed=$P13WD tdribble_replayed=$P14H+$P14T"
docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"
