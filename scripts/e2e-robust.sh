#!/bin/sh
# Robustness-class acceptance — the inputs and states the happy-path suites
# never produce:
#   huge-fields   : a message and detail far past their ring slots (1024/256
#                   bytes) arrive as ONE event, cut at a UTF-8 char boundary,
#                   named in "truncated", still valid JSON at the receiver
#   redact        : the password token in logged statement text is cut
#                   (pgaudit semantics, always on), a plain message merely
#                   mentioning the word is NOT touched, and redact_pattern
#                   matches become <REDACTED> — both at capture, so the
#                   secret is never on the wire nor in the fallback file.
#                   A redaction that clips and a slot that overflows are
#                   reported separately: "truncated" (slot) vs "redacted"
#                   (clip), each naming its fields
#   backend-kill  : a logging backend SIGKILLed mid-emit — the emergency
#                   restart path a PANIC takes (postmaster tears the cluster
#                   down and rebuilds it, logging through the hook chain).
#                   A slot torn by the death is never published (head does
#                   not advance), no garbage escapes to the receiver, seqs
#                   stay monotonic across the restart
#   backlog-bound : receiver down with no fallback file and a 60k-event
#                   storm: the RAM backlog trims at export_backlog_max (the
#                   documented loss), the worker's RSS stays at the bound
#                   (~depth × slot) instead of growing with the storm, and
#                   captured == sent + lost to the event — nothing vanishes
#                   outside the trim, nothing the receiver never got counts
#                   as sent
# Usage: scripts/e2e-robust.sh [pg_container]
# The receiver comes from the compose stand (tests/e2e/compose.yaml); its
# readiness gate must have passed.
set -eu
PG_CT="${1:-pglogtap-pg}"
NET=pglogtap-e2e_default
OUT=/tmp/logtap-e2e
VEC=pglogtap-vector

fail() {
  echo "e2e-robust: FAILED: $*" >&2
  docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" >&2 || true
  docker exec "$PG_CT" psql -U postgres -Atc \
    "SELECT pid || ' ' || backend_type FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'" >&2 || true
  docker logs "$PG_CT" 2>&1 | grep -iE "logtap|PANIC|terminated by signal|interrupted|reinitializ" | tail -12 >&2 || true
  docker inspect -f "pg: {{.State.Status}} oom={{.State.OOMKilled}}" "$PG_CT" >&2 || true
  docker inspect -f "receiver: {{.State.Status}} oom={{.State.OOMKilled}}" "$VEC" >&2 || true
  exit 1
}
ok() { echo "  ok: $*"; }

# Stand gate: the compose one-shot must have passed (pg healthy AND the
# receiver port answering at boot).
[ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] \
  || fail "e2e stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d"
docker network connect "$NET" "$PG_CT" 2>/dev/null || true # non-stand pg arg
# the ready gate is a one-shot that stays exited/0 forever; a run that failed
# inside backlog-bound leaves the receiver stopped and the next run would
# fail its first scenario on a dead hostname — start is a no-op when running
docker start "$VEC" >/dev/null 2>&1 || true
mkdir -p "$OUT" # vector-out.jsonl accumulates across runs BY DESIGN

setguc() { docker exec "$PG_CT" psql -U postgres -qc "ALTER SYSTEM SET $1 = '$2'" >/dev/null; }
reload() { docker exec "$PG_CT" psql -U postgres -qc "SELECT pg_reload_conf()" >/dev/null; }
SUF="-$$" # per-run marker suffix: vector-out.jsonl accumulates across runs
gen() { # gen <marker> <count> — distinct events from one psql round trip.
  docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ DECLARE i int := 0; BEGIN
    WHILE i < $2 LOOP
      RAISE WARNING 'logtap robust $1$SUF %', i;
      i := i + 1;
    END LOOP; END \$\$" >/dev/null 2>&1 || echo "  gen $1: psql FAILED (events never emitted)" >&2
}
received() { grep -oE "logtap robust $1$SUF [0-9]+" "$OUT/vector-out.jsonl" 2>/dev/null | sort -u | wc -l; }
seqs_of() { grep -E "logtap robust $1$SUF [0-9]+" "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | cut -d: -f2; }
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
stats() { docker exec "$PG_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"; }
statf() { s=$(stats); v=${s#*"$1"=}; echo "${v%% *}"; }
worker_pid() { docker exec "$PG_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type LIKE '%logtap%' LIMIT 1"; }
vmrss_kb() { # resident set of the worker inside the container
  docker exec "$PG_CT" cat "/proc/$(worker_pid)/status" 2>/dev/null | awk '/^VmRSS/{print $2}'
}
wait_for() { # wait_for <marker> <count> [tries]
  n=0; tries=${3:-30}
  while [ "$n" -lt "$tries" ]; do
    [ "$(received "$1")" -ge "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
}

# Wait for the worker to empty the ring: markers emitted into a full ring
# are dropped at emit (counted in events_dropped, never delivered).
drain_ring() {
  n=0
  while [ "$n" -lt 60 ]; do
    [ "$(statf ring_events)" = 0 ] && return 0
    n=$((n + 1)); sleep 1
  done
  fail "ring never drained (ring_events=$(statf ring_events))"
}

# Every delivered marker line must parse as JSON — a torn slot or a botched
# sanitization would surface here as invalid JSON or broken UTF-8.
json_check() { # json_check <marker>: prints "json_ok <n>"
  python3 - "$OUT/vector-out.jsonl" "logtap robust $1$SUF" <<'EOF'
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

echo "== huge fields: message and detail past their ring slots =="
# Reset every GUC a previous (possibly failed) run may have left armed — the
# scenarios below set their own; a leftover redact_pattern or field_query
# changes what this one must observe.
setguc log_min_duration_statement -1; setguc pg_logtap.field_query off; setguc pg_logtap.redact_pattern ''
setguc pg_logtap.export_url "http://$VEC:8686"; setguc pg_logtap.export_fallback_file ''; reload; sleep 2
# A previous run may have left the ring full of undrained backlog; markers
# emitted into a full ring are dropped at emit (counted, never delivered)
# and the first scenario would time out on them. Also fires on a freshly
# configured stand only after export_url is set above — an empty URL parks
# the worker's sends by design.
drain_ring
# 8k multibyte chars (16 KB into a 1024-byte slot) + a 2 KB detail (256-byte
# slot): the cut points land mid-character — the copy must back off to the
# char boundary and name both fields in "truncated".
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'logtap robust huge$SUF % %', 0, repeat('é', 8000)
    USING DETAIL = repeat('д', 1000), ERRCODE = '01000';
  END \$\$" >/dev/null 2>&1 || true
wait_for huge 1 20
[ "$(received huge)" = 1 ] || fail "huge-fields: $(received huge) events for one RAISE (expected exactly 1)"
json_check huge >/dev/null || fail "huge-fields: delivered line is not valid JSON/UTF-8"
python3 - "$OUT/vector-out.jsonl" "logtap robust huge$SUF" <<'EOF' || fail "huge-fields: truncation contract"
import json, sys
path, marker = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    if marker in line:
        e = json.loads(line)
        assert len(e["message"].encode()) <= 1024, "message over slot cap"
        assert "message" in e["truncated"] and "detail" in e["truncated"], e["truncated"]
        # the cut lands inside the é-run: only a whole char (never a
        # sanitized U+FFFD fragment) can legally end the field
        assert e["message"].endswith("é"), "cut not on a char boundary"
        break
EOF
ok "one event, message ≤1024B cut at a char boundary, truncated=[message,detail], valid JSON"

echo "== redaction: password token cut + redact_pattern =="
# Statement logging on: duration lines carry the raw SQL in message, and
# field_query captures it separately. Three probes: a CREATE ROLE with a
# password (the pgaudit case — token cut must fire in both message and
# query), a DO whose text embeds the token in a trailing comment (query cut)
# while its WARNING message merely contains the word (must stay verbatim),
# and a redact_pattern match inside a message.
setguc log_min_duration_statement 0; setguc pg_logtap.field_query on; reload; sleep 1
docker exec "$PG_CT" psql -U postgres -qc \
  "CREATE ROLE \"tmp_red$SUF\" PASSWORD 'SECRET-query$SUF-abc123'" >/dev/null
# token only in the statement text (trailing comment), not in the message
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redq$SUF 0 benign password note'; END \$do\$; -- password 'SECRET-do$SUF-abc123'" \
  >/dev/null 2>&1 || true
setguc pg_logtap.redact_pattern 'SECRET-[a-z0-9-]+'; reload; sleep 1
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redp$SUF 0 token=SECRET-msg$SUF-abc123'; END \$do\$" \
  >/dev/null 2>&1 || true
wait_for redq 1 20; wait_for redp 1 20
# vector-out.jsonl accumulates across runs BY DESIGN: the secrets carry this
# run's suffix so stale lines from earlier runs cannot fail this one.
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: contract"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
whole = open(path, encoding="utf-8").read()
for secret in ("SECRET-query" + suf + "-abc123", "SECRET-do" + suf + "-abc123", "SECRET-msg" + suf + "-abc123"):
    assert secret not in whole, secret + " reached the receiver unmasked"
q = p = role = False
for line in whole.splitlines():
    if "logtap robust red" not in line:
        continue
    e = json.loads(line)
    m = e.get("message", "")
    if m.startswith("logtap robust redq" + suf):
        # message path: the word alone is not statement text — verbatim
        assert "<REDACTED>" not in m and "benign password note" in m, m
        # query path: the token cut fired on the comment-carried token
        assert "<REDACTED>" in (e.get("query") or ""), repr(e.get("query"))
        q = True
    if m.startswith("logtap robust redp" + suf):
        assert "<REDACTED>" in m, m  # redact_pattern fired at capture
        p = True
for line in whole.splitlines():  # the role's duration line has no red marker
    if "tmp_red" + suf not in line:
        continue
    e = json.loads(line)
    m = e.get("message", "")
    if "CREATE ROLE" in m:
        assert "<REDACTED>" in m, m
        role = True
assert q and p and role, "probe events missing (q=%s p=%s role=%s)" % (q, p, role)
EOF
# truncated vs redacted are two different causes for a cut field (LT-1): a
# redaction that expands past the scratch cap clips WITHOUT slot-truncating
# (the clip result fits the slot exactly) → redacted only; a DETAIL past its
# 256-byte slot whose redaction also clips → both arrays name it.
setguc pg_logtap.redact_pattern 'ZZ'; reload; sleep 1
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redclip$SUF 0 %', repeat('ZZ ', 316);
  END \$do\$" >/dev/null 2>&1 || true
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redboth$SUF 0 x' USING DETAIL = repeat('ZZ ', 400);
  END \$do\$" >/dev/null 2>&1 || true
wait_for redclip 1 20; wait_for redboth 1 20
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: truncated/redacted split"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
clip = both = False
for line in open(path, encoding="utf-8"):
    if "logtap robust redclip" + suf not in line and "logtap robust redboth" + suf not in line:
        continue
    e = json.loads(line)
    m = e.get("message", "")
    if m.startswith("logtap robust redclip" + suf):
        # 978-byte message, every ZZ expands by 8 bytes: the redaction clips
        # at 1024 — the slot cap — so the slot itself never truncated it
        assert "message" in e["redacted"] and "message" not in e["truncated"], e
        assert len(m.encode()) == 1024 and "<REDACTED>" in m, len(m.encode())
        clip = True
    if m.startswith("logtap robust redboth" + suf):
        # 1200-byte DETAIL: redaction clip at the scratch cap AND the 256-byte
        # slot cut — both causes, both arrays
        d = e.get("detail") or ""
        assert "detail" in e["truncated"] and "detail" in e["redacted"], e
        assert len(d.encode()) <= 256 and "<REDACTED>" in d, len(d.encode())
        both = True
assert clip and both, "probes missing (clip=%s both=%s)" % (clip, both)
EOF
ok "redaction clip and slot overflow reported separately (redacted vs truncated)"
docker exec "$PG_CT" psql -U postgres -qc "DROP ROLE IF EXISTS \"tmp_red$SUF\"" >/dev/null 2>&1 || true
setguc log_min_duration_statement -1; setguc pg_logtap.field_query off; setguc pg_logtap.redact_pattern ''; reload
ok "statement passwords cut (message and query), benign message word verbatim, redact_pattern masked"

# An invalid redact_pattern fails OPEN (the layer turns off, logs flow) — the
# only durable signal is the redact_pattern_failed gauge, probed both ways.
# Empty pattern after reset is "layer off", not a failure: the flag reads 0.
setguc pg_logtap.redact_pattern '[unclosed'; reload; sleep 1
[ "$(statf redact_pattern_failed)" = 1 ] || fail "invalid redact_pattern did not set redact_pattern_failed=1"
setguc pg_logtap.redact_pattern ''; reload; sleep 1
[ "$(statf redact_pattern_failed)" = 0 ] || fail "pattern reset did not clear redact_pattern_failed"
ok "redact_pattern_failed: invalid pattern → 1, reset → 0 (fail-open is visible)"

# Extended protocol (JDBC, psycopg, pgbench -M extended): duration lines for
# parse/bind/execute carry the raw SQL WITHOUT the "statement: " marker — the
# cut must fire on the phase words too. The probe SQL puts the tag BEFORE the
# password token (survives the cut, marks the line) and the secret AFTER it
# (a prepared statement's secret position). redact_pattern stays off so only
# the token cut can mask.
setguc log_min_duration_statement 0; reload; sleep 1
docker exec "$PG_CT" sh -c "printf '%s\n' \"SELECT 'ext$SUF' AS tag, 'password' AS kw, 'SECRET-exec$SUF-abc123' AS val;\" > /tmp/probe-ext.sql"
docker exec "$PG_CT" pgbench -U postgres -M extended -c 1 -t 1 -f /tmp/probe-ext.sql postgres >/dev/null 2>&1 || true
n=0; while [ "$n" -lt 20 ]; do
  # tail: vector-out.jsonl grows to GiB across runs, but this run's lines
  # land at the end — grepping the tail keeps the wait cheap
  [ "$(tail -c 50000000 "$OUT/vector-out.jsonl" 2>/dev/null | grep -c "ext$SUF")" -gt 0 ] && break
  n=$((n + 1)); sleep 1
done
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: extended protocol password cut"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
whole = open(path, encoding="utf-8").read()
assert "SECRET-exec" + suf not in whole, "secret reached the receiver via an extended-protocol line"
saw = 0
for line in whole.splitlines():
    if "ext" + suf not in line:
        continue
    e = json.loads(line)
    m = e.get("message", "")
    if m.startswith(("parse ", "execute ", "duration: ")):
        # the token cut fired: everything after the password token is gone
        assert "kw" not in m and "<REDACTED>" in m, m
        saw += 1
assert saw > 0, "no extended-protocol phase lines reached the receiver"
EOF
setguc log_min_duration_statement -1; reload
ok "extended-protocol parse/execute duration lines get the password cut"

# Bind parameters: with log_parameter_max_length the server puts the actual
# values into DETAIL ("parameters: $1 = '...'") on statement lines — the SQL
# carries only $N placeholders, so the token cut cannot see the secret. The
# bind-value layer masks every quoted value on that line. psql \bind is psql
# 16+; on older servers the unit tests carry the contract.
setguc log_min_duration_statement 0; setguc log_parameter_max_length 100; reload; sleep 1
vnum=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW server_version_num")
if [ "$vnum" -ge 160000 ]; then
  # -i: without it docker exec does not forward stdin, psql reads an empty
  # buffer and silently runs nothing
  docker exec -i "$PG_CT" psql -U postgres >/dev/null 2>&1 <<EOF || true
SELECT 'bindtag$SUF' AS tag, \$1::text, \$2::text \bind 'SECRET-bind$SUF-xyz789' 'pw''d'
\g
EOF
  n=0; while [ "$n" -lt 20 ]; do
    [ "$(tail -c 50000000 "$OUT/vector-out.jsonl" 2>/dev/null | grep -c "bindtag$SUF")" -gt 0 ] && break
    n=$((n + 1)); sleep 1
  done
  python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: bind-parameter values masked"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
whole = open(path, encoding="utf-8").read()
assert "SECRET-bind" + suf not in whole, "bind value reached the receiver via DETAIL"
saw = 0
for line in whole.splitlines():
    if "bindtag" + suf not in line:
        continue
    e = json.loads(line)
    m, d = e.get("message") or "", e.get("detail") or "" # null ≠ absent in JSON
    if "duration:" in m and "Parameters: " in d:
        # every quoted value masked, the $N keys and structure verbatim
        assert d.startswith("Parameters: $1 = <REDACTED>"), d
        assert d.endswith("$2 = <REDACTED>"), d
        assert "SECRET" not in d and "pw" not in d, d
        saw += 1
assert saw > 0, "no bind-parameter detail lines reached the receiver"
EOF
else
  echo "  skip: bind-parameter masking (psql bind needs 16+, server is $vnum)"
fi
setguc log_min_duration_statement -1; setguc log_parameter_max_length -1; reload
ok "bind-parameter values masked on the parameters line"

# pattern_exclude matches the whole event text, not just the message: the
# token rides DETAIL (where RAISE ... USING DETAIL puts it) — the event must
# not ship at all, while a token-free neighbor emitted right after it flows.
setguc pg_logtap.pattern_exclude "HIDEME$SUF"; reload; sleep 1
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'exc-suppressed$SUF message is clean'
  USING DETAIL = 'detail carries HIDEME$SUF';
END \$\$" >/dev/null 2>&1
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'exc-control$SUF no token anywhere';
END \$\$" >/dev/null 2>&1
wait_for "exc-control$SUF" 1 10
[ "$(grep -c "exc-suppressed$SUF" "$OUT/vector-out.jsonl")" = 0 ] \
  || fail "pattern_exclude: event with the token in DETAIL reached the receiver"
[ "$(grep -c "HIDEME$SUF" "$OUT/vector-out.jsonl")" = 0 ] \
  || fail "pattern_exclude: the DETAIL token itself reached the receiver"
ok "pattern_exclude suppresses an event whose DETAIL carries the token"
setguc pg_logtap.pattern_exclude ''; reload

echo "== backend kill mid-emit: the PANIC path (emergency restart) =="
# pgbench drives sustained statement logging (every duration line is a
# captured event from a client backend); one of its backends is SIGKILLed
# mid-emit — the postmaster treats it exactly as a PANIC: teardown, shmem
# rebuild, recovery.
setguc log_min_duration_statement 0; reload
# -i is idempotent; the storm phase may not have run before this suite.
docker exec "$PG_CT" pgbench -i -q -U postgres postgres >/dev/null 2>&1 || true
# premax BEFORE pgbench starts: scanning the accumulated output file can take
# seconds, and pgbench's whole run is 30s — grep first, kill while the backend
# is guaranteed alive (the race killed a pg18 run: backend exited, "kill: No
# such process").
premax=$(grep -o '"seq":[0-9]*' "$OUT/vector-out.jsonl" 2>/dev/null | cut -d: -f2 | sort -n | tail -1)
[ -n "$premax" ] || premax=0 # every seq ever flushed before the kill
docker exec -d "$PG_CT" pgbench -U postgres -c 4 -T 30 postgres
bepid=''
n=0; while [ -z "$bepid" ] && [ "$n" -lt 15 ]; do
  bepid=$(docker exec "$PG_CT" psql -U postgres -Atc \
    "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgbench' LIMIT 1")
  [ -n "$bepid" ] || { n=$((n + 1)); sleep 1; }
done
[ -n "$bepid" ] || fail "backend-kill: no pgbench backend appeared"
# The pid can vanish between the lookup and the kill (seen in CI: a pgbench
# client hitting its -T deadline, or finishing, right in the window) — "kill:
# No such process" then aborts the whole suite under set -e. Re-find until
# the kill lands: the scenario needs an abnormal death, not a specific pid.
n=0; while [ "$n" -lt 10 ]; do
  docker exec "$PG_CT" bash -c "kill -9 $bepid" 2>/dev/null && break
  bepid=$(docker exec "$PG_CT" psql -U postgres -Atc \
    "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgbench' LIMIT 1")
  [ -n "$bepid" ] || sleep 1
  n=$((n + 1))
done
sleep 2; wait_ready # emergency restart: teardown, shmem rebuild, recovery
setguc log_min_duration_statement -1; reload
docker logs "$PG_CT" 2>&1 | grep -q "was terminated by signal 9" \
  || fail "backend-kill: no abnormal-death teardown in the server log"
docker logs "$PG_CT" 2>&1 | grep -q "database system was interrupted" \
  || fail "backend-kill: postmaster did not emergency-restart"
gen panic3 50; wait_for panic3 50
[ "$(received panic3)" = 50 ] || fail "backend-kill: post-restart delivery loss (panic3=$(received panic3)/50)"
json_check panic3 >/dev/null || fail "backend-kill: garbage escaped the torn slot (invalid JSON)"
dups=$(grep 'logtap robust' "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$dups" = 0 ] || fail "backend-kill: $dups duplicate seqs across the restart"
postmin=$(seqs_of panic3 | sort -n | head -1)
[ "$postmin" -gt "$premax" ] || fail "backend-kill: seq went backwards across the restart ($postmin ≤ $premax)"
ok "kill -9 of a logging backend → emergency restart, seq monotonic, no garbage, delivery resumed"

echo "== backlog bound: 60k events into a dead receiver, no fallback file =="
# Without a fallback file a dead receiver is DOCUMENTED loss (that is what
# the file is for): the RAM backlog and the ring absorb what they hold, the
# rest is dropped/trimmed and COUNTED. The contract under test: the worker's
# memory stays at the bound instead of growing with the storm — enforced by
# a hard cgroup ceiling with no swap, under which an unbounded backlog (~all
# 60k events ≈ 200MB over baseline) would push the server into the kernel
# OOM path — every lost event is accounted (captured == sent + dropped + lost
# once drained), and delivery resumes the moment the receiver returns.
OOM_LIMIT_MB=256
setguc pg_logtap.export_backlog_max 8192; reload; sleep 1 # the GUC minimum = ring capacity
docker update --memory ${OOM_LIMIT_MB}m --memory-swap ${OOM_LIMIT_MB}m "$PG_CT" >/dev/null
bcap=$(statf events_captured); bsent=$(statf events_sent); bdrp=$(statf events_dropped); blost=$(statf events_lost)
rss0=$(vmrss_kb)
docker stop "$VEC" >/dev/null
gen oom3 60000; sleep 5 # blocked/failed cycles: backlog fills, the bound bites
rss1=$(vmrss_kb)
# Bound: depth × slot ≈ 8192 × 3.4KB ≈ 28MB over baseline. An unbounded
# backlog would hold all 60k (~200MB) — anything near that fails here.
[ -n "$rss0" ] && [ -n "$rss1" ] || fail "backlog-bound: worker RSS unreadable (worker dead?)"
[ "$rss1" -lt $((rss0 + 102400)) ] \
  || fail "backlog-bound: worker RSS grew past the bound (baseline=${rss0}kB after=${rss1}kB)"
[ "$(docker inspect -f '{{.State.OOMKilled}}' "$PG_CT")" = false ] \
  || fail "backlog-bound: pg container OOM-killed under the ${OOM_LIMIT_MB}MB ceiling"
# High-water mark of the whole container (cgroup v2, v1 fallback): the wall
# must never even be touched — no reclaim storms, no OOM victim of any kind.
peak=$(docker exec "$PG_CT" cat /sys/fs/cgroup/memory.peak 2>/dev/null || \
       docker exec "$PG_CT" cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null || true)
[ -z "$peak" ] || [ "$peak" -lt $((OOM_LIMIT_MB * 1024 * 1024)) ] \
  || fail "backlog-bound: cgroup memory peak ${peak}B touched the ${OOM_LIMIT_MB}MB ceiling"
docker update --memory 0 --memory-swap 0 "$PG_CT" >/dev/null
docker start "$VEC" >/dev/null; wait_vector
# wait_vector only proves the listener socket is back. The worker is still
# holding the storm backlog (its connect was parked on the dead receiver for
# the whole outage): the ring stays full for seconds while it drains, and
# markers emitted into a full ring are dropped at emit — by design, counted
# in events_dropped. Delivery resuming = the drain finishing; only then can
# fresh post-recovery events be expected to arrive.
drain_ring
gen oom4 20; wait_for oom4 20
[ "$(received oom4)" = 20 ] || fail "backlog-bound: no delivery after recovery (oom4=$(received oom4)/20)"
acc3() { # sent + lost + dropped from one stats call
  s=$(stats); a=${s#*events_sent=}; a=${a%% *}; b=${s#*events_lost=}; b=${b%% *}; c=${s#*events_dropped=}; c=${c%% *}
  echo $((a + b + c))
}
n=0; prev=''; same=0 # settle: the accounting stops moving once the backlog drained
while [ "$n" -lt 60 ]; do
  cur=$(acc3)
  if [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; fi
  [ "$same" -ge 3 ] && break
  prev=$cur; n=$((n + 1)); sleep 1
done
capd=$(( $(statf events_captured) - bcap )); sentd=$(( $(statf events_sent) - bsent ))
drpd=$(( $(statf events_dropped) - bdrp )); lostd=$(( $(statf events_lost) - blost ))
# Two identities, both exact once drained: everything the hook saw either
# entered the ring or was refused-and-counted (emitted == captured + dropped),
# and everything captured was sent or trim-lost (captured == sent + lost) —
# nothing vanishes outside the counters.
[ $((capd - sentd - lostd)) -le 5 ] && [ $((sentd + lostd - capd)) -le 5 ] \
  || fail "backlog-bound: accounting broken (captured=$capd sent=$sentd lost=$lostd — events vanished unaccounted)"
[ $((capd + drpd)) -ge 55000 ] \
  || fail "backlog-bound: the storm is not accounted (captured=$capd dropped=$drpd of 60000)"
[ $((drpd + lostd)) -ge 40000 ] \
  || fail "backlog-bound: the bound was never exercised (dropped=$drpd lost=$lostd of 60000)"
ok "worker RSS ${rss0}→${rss1}kB (bounded), cgroup ceiling ${OOM_LIMIT_MB}MB never touched (peak ${peak:-?}B), accounted: emitted=$((capd + drpd)) = captured=$capd + dropped=$drpd, captured = sent=$sentd + lost=$lostd, delivery resumed"

echo "== redact gauge assign under live lock traffic =="
# The redact_pattern assign hook also runs in the postmaster on its own SIGHUP
# reload, and the gauge update takes the ring LWLock — contended there, it
# would PANIC ("cannot wait without a PGPROC structure") and take the whole
# cluster down. The capture-side MyProc gate must keep the postmaster off the
# lock; the window needs live lock traffic to matter, so flip an invalid
# pattern through several reloads while backends push logged statements. Runs
# AFTER the memory-peak assert on purpose: statement-rate logging at the
# default backlog depth is what that assert exists to forbid.
# Backlog is still clamped to 8192 by the scenario above, so the burst's RAM
# cost is the documented ~28MB, not a GUC-default surprise.
setguc log_min_duration_statement 0; reload
docker exec "$PG_CT" sh -c "printf '%s\n' 'SELECT 1;' > /tmp/probe-load$SUF.sql"
docker exec -d "$PG_CT" pgbench -U postgres -c 4 -T 12 -f "/tmp/probe-load$SUF.sql" postgres
flip=0
while [ "$flip" -lt 8 ]; do
  setguc pg_logtap.redact_pattern "[reload-under-load-$flip"
  reload; sleep 1
  flip=$((flip + 1))
done
docker exec "$PG_CT" psql -U postgres -qc "SELECT 1" >/dev/null 2>&1 || fail "redact_pattern reload under load crashed the server"
[ "$(statf redact_pattern_failed)" = 1 ] || fail "invalid pattern under load did not set redact_pattern_failed=1"
setguc pg_logtap.redact_pattern ''; setguc log_min_duration_statement -1; reload; sleep 1
ok "redact_pattern reloaded 8x under pgbench statement load: postmaster survived, gauge set"

dups=$(grep 'logtap robust' "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l)
[ "$dups" = 0 ] || fail "$dups duplicate seqs across the suite"
echo "e2e-robust: all scenarios passed"
