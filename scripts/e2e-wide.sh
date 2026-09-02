#!/bin/sh
# Wide-message acceptance — pg_logtap.message_max (POSTMASTER). With the slot
# widened, a message past the default 1024 bytes arrives whole at the
# receiver; past the configured width it is cut at a UTF-8 character
# boundary and named in "truncated"; aux fields (detail) stay 256 bytes
# whatever the width. Runs the whole cycle itself: ALTER SYSTEM, restart,
# probes, then restores the default width.
# Usage: scripts/e2e-wide.sh [pg_container]
# The receiver comes from the compose stand (tests/e2e/compose.yaml); its
# readiness gate must have passed.
set -eu
PG_CT="${1:-pglogtap-pg}"
NET=pglogtap-e2e_default
OUT=/tmp/logtap-e2e
VEC=pglogtap-vector
WIDE=8192

fail() {
  echo "e2e-wide: FAILED: $*" >&2
  docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" >&2 || true
  exit 1
}
ok() { echo "  ok: $*"; }

# Stand gate: the compose one-shot must have passed.
[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] \
  || fail "e2e stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d"
# A stale .so (copied without a restart) would test yesterday's code.
"$(dirname "$0")/e2e-require-ext.sh" "$PG_CT"
docker network connect "$NET" "$PG_CT" 2>/dev/null || true # non-stand pg arg
mkdir -p "$OUT" # vector-out.jsonl accumulates across runs BY DESIGN

setguc() { docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $1 = '$2'" >/dev/null; }
SUF="-$$" # per-run marker suffix
received() { grep -c "logtap wide $1$SUF" "$OUT/vector-out.jsonl" 2>/dev/null || true; }
stats() { docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"; }
statf() { s=$(stats); v=${s#*"$1"=}; echo "${v%% *}"; }
wait_ready() { # TCP probe: the restarting server's socket comes and goes
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$PG_CT" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && return 0
    n=$((n + 1)); sleep 1
  done
  fail "postgres in $PG_CT not ready after 60s"
}
wait_vector() {
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$PG_CT" bash -c "exec 3<>/dev/tcp/$VEC/8686" 2>/dev/null && return 0
    n=$((n + 1)); sleep 1
  done
  fail "receiver $VEC not accepting connections after 60s"
}
wait_for() { # wait_for <marker> <count> [tries]
  n=0; tries=${3:-30}
  while [ "$n" -lt "$tries" ]; do
    [ "$(received "$1")" -ge "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
}

# Every delivered marker line must parse as JSON — a torn slot or a botched
# sanitization would surface here as invalid JSON or broken UTF-8.
json_check() { # json_check <marker>: prints "json_ok <n>"
  python3 - "$OUT/vector-out.jsonl" "logtap wide $1$SUF" <<'EOF'
import json, sys
path, marker = sys.argv[1], sys.argv[2]
n = 0
for line in open(path, encoding="utf-8"):
    if marker in line:
        json.loads(line)  # raises on invalid JSON or non-UTF-8 bytes
        n += 1
print(n)
EOF
}

echo "== wide: pg_logtap.message_max = $WIDE =="
# message_max is POSTMASTER: apply + restart, then wait out the worker's
# first flush cycle so probes cannot race it.
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.export_fallback_file ''
setguc pg_logtap.message_max "$WIDE"
docker restart "$PG_CT" >/dev/null
wait_ready; wait_vector
sleep 2

# Probe 1: 5000 multibyte bytes into the 8192-wide slot — the whole message,
# no truncation bit (before 0.4.0 this arrived clipped at 1024).
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'logtap wide full$SUF %', repeat('é', 2500);
  END \$\$" >/dev/null 2>&1 || true
wait_for full 1 20
[ "$(received full)" = 1 ] || fail "wide: $(received full) events for the full-message probe (expected 1)"
json_check full >/dev/null || fail "wide: delivered line is not valid JSON/UTF-8"
python3 - "$OUT/vector-out.jsonl" "logtap wide full$SUF" <<'EOF' || fail "wide: full-message contract"
import json, sys
path, marker = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    if marker in line:
        e = json.loads(line)
        # the marker prefix rides in message; whole == the é-run intact at the end
        assert e["message"].encode().endswith("é".encode() * 2500), "message not delivered whole"
        assert "message" not in e["truncated"], e["truncated"]
        break
EOF
ok "5000B message delivered whole, truncated=[]"

# Probe 2: 9000 bytes of 3-byte chars — the cut at 8192 lands mid-character,
# backs off to 8190, names message in truncated.
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'logtap wide clip$SUF %', repeat('€', 3000);
  END \$\$" >/dev/null 2>&1 || true
wait_for clip 1 20
[ "$(received clip)" = 1 ] || fail "wide: $(received clip) events for the clip probe (expected 1)"
json_check clip >/dev/null || fail "wide: delivered line is not valid JSON/UTF-8"
python3 - "$OUT/vector-out.jsonl" "logtap wide clip$SUF" <<'EOF' || fail "wide: clip contract"
import json, sys
path, marker = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    if marker in line:
        e = json.loads(line)
        # clip at 8192 minus the marker prefix (pid-length) backs off to the
        # nearest 3-byte € boundary: 8190..8192 depending on prefix length
        mlen = len(e["message"].encode())
        assert 8190 <= mlen <= 8192, "cut not at the char boundary: %d" % mlen
        assert "message" in e["truncated"], e["truncated"]
        assert e["message"].endswith("€"), "cut left a partial character"
        break
EOF
ok "9000B message cut at a char boundary (~8192B), truncated=[message]"

# Probe 3: the width widens message only — a 2000-byte DETAIL stays capped at
# its 256-byte slot and is named separately.
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'logtap wide aux$SUF %', repeat('é', 100)
    USING DETAIL = repeat('д', 1000);
  END \$\$" >/dev/null 2>&1 || true
wait_for aux 1 20
[ "$(received aux)" = 1 ] || fail "wide: $(received aux) events for the aux probe (expected 1)"
json_check aux >/dev/null || fail "wide: delivered line is not valid JSON/UTF-8"
python3 - "$OUT/vector-out.jsonl" "logtap wide aux$SUF" <<'EOF' || fail "wide: aux-field contract"
import json, sys
path, marker = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    if marker in line:
        e = json.loads(line)
        assert e["message"].encode().endswith("é".encode() * 100), "message affected by the aux probe"
        assert "message" not in e["truncated"], e["truncated"]
        assert len(e["detail"].encode()) <= 256, "detail over its slot cap"
        assert "detail" in e["truncated"], e["truncated"]
        break
EOF
ok "detail still 256B (truncated=[detail]) while message rides the wide slot"

# Probe 4: sustained wide traffic. 12000 events x ~8KB is past the 8192-event
# ring of the matrix stand, so the worker must drain continuously through the
# burst — any sustained capture-past-drain gap shows up as events_dropped.
N=12000
bcap=$(statf events_captured); bdrp=$(statf events_dropped); bsent=$(statf events_sent)
t0=$(date +%s)
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
  WHILE i < $N LOOP
    RAISE WARNING 'logtap wide burst$SUF % %', i, repeat('é', 4000);
    i := i + 1;
  END LOOP; END \$\$" >/dev/null 2>&1 || true
t1=$(date +%s)
wait_for burst "$N" 120
capd=$(( $(statf events_captured) - bcap )); drpd=$(( $(statf events_dropped) - bdrp ))
sentd=$(( $(statf events_sent) - bsent )); got=$(received burst)
dups=$(grep "logtap wide burst$SUF" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
echo "  wide burst: $N events (~$((N * 8 / 1000))MB) generated in $((t1 - t0))s, delivered=$got"
[ "$drpd" = 0 ] || fail "wide burst: $drpd events dropped at capture (drain behind wide inflow)"
[ "$capd" -ge "$N" ] || fail "wide burst: captured $capd < $N"
[ "$sentd" = "$capd" ] || fail "wide burst: sent $sentd != captured $capd"
[ "$got" -ge "$N" ] || fail "wide burst: receiver saw $got < $N"
[ "$dups" = 0 ] || fail "wide burst: $dups duplicate seqs"
ok "$capd wide events, dropped=0, delivery exact, no duplicate seqs"

# Restore the default width so a standalone run against a standing container
# leaves it as it was (the matrix removes the container anyway).
setguc pg_logtap.message_max 1024
docker restart "$PG_CT" >/dev/null
wait_ready
echo "e2e-wide: all scenarios passed"
