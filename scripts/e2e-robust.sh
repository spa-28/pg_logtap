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
#   frag-status   : a receiver that answers "HTTP/1." … "1 200 OK" in two
#                   writes 300ms apart (TCP owes no write boundaries): the
#                   status line straddles recvs, the send must still count
#                   as delivered — a false failure parks a batch the
#                   receiver already has (duplicate + divert on live)
# Usage: scripts/e2e-robust.sh [pg_container]
# The receiver comes from the compose stand (tests/e2e/compose.yaml); its
# readiness gate must have passed.
#
# Isolated auth-DETAIL entry (never part of the normal suite):
#   PG_LOGTAP_AUTH_PROBE=run scripts/e2e-robust.sh
# Required: LT_AUTH_PG_CONTAINER, LT_AUTH_EXPECTED_ID, LT_AUTH_LABEL_KEY,
# LT_AUTH_LABEL_VALUE, LT_AUTH_ADMIN_USER, LT_AUTH_DB, LT_AUTH_CONNECT_HOST,
# LT_AUTH_CONNECT_PORT, LT_AUTH_USER, LT_AUTH_BAD_PASSWORD, LT_AUTH_REASON,
# LT_AUTH_HBA_TOKEN, LT_AUTH_CONTROL, and LT_AUTH_EXPORT_FILE. The controller
# supplies a disposable PG/HBA fixture; this script verifies its ID and label
# before it issues any command. LT_AUTH_HBA_TOKEN must occur only in the
# matched server HBA DETAIL, not the authentication message. `PG_LOGTAP_AUTH_PROBE=assert`
# only validates a captured export file and is useful for the parser smoke, not integration proof.
set -u
# e2e-common's fail helper prints E2E_TAG; the guarded modes intentionally
# bypass e2e_init, so give their preflight failures their own tag.
[ -z "${PG_LOGTAP_AUTH_PROBE:-}" ] || E2E_TAG=auth-detail
. "$(dirname "$0")/e2e-common.sh"

auth_require_assert_env() {
  [ -n "${LT_AUTH_EXPORT_FILE:-}" ] || fail "auth DETAIL probe: LT_AUTH_EXPORT_FILE is required"
  [ -n "${LT_AUTH_REASON:-}" ] || fail "auth DETAIL probe: LT_AUTH_REASON is required"
  [ -n "${LT_AUTH_HBA_TOKEN:-}" ] || fail "auth DETAIL probe: LT_AUTH_HBA_TOKEN is required"
  [ -r "$LT_AUTH_EXPORT_FILE" ] || fail "auth DETAIL probe: export file is unreadable"
}

auth_assert_export() {
  python3 - "$LT_AUTH_EXPORT_FILE" "$LT_AUTH_REASON" "$LT_AUTH_HBA_TOKEN" <<'EOF'
import json, sys
path, reason, token = sys.argv[1:]
for line in open(path, encoding="utf-8"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:  # receiver may be appending its final line
        continue
    message = event.get("message") or ""
    detail = event.get("detail")
    other_fields = (message, event.get("hint") or "", event.get("context") or "", event.get("query") or "")
    if reason in message and isinstance(detail, str) and token in detail and all(token not in field for field in other_fields):
        print("auth DETAIL export found")
        break
else:
    raise SystemExit("no failed-auth export with the HBA token only in effective DETAIL")
EOF
}

auth_count_export() {
  python3 - "$LT_AUTH_EXPORT_FILE" "$LT_AUTH_REASON" "$LT_AUTH_HBA_TOKEN" <<'EOF'
import json, sys
path, reason, token = sys.argv[1:]
count = 0
for line in open(path, encoding="utf-8"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    message = event.get("message") or ""
    detail = event.get("detail")
    other_fields = (message, event.get("hint") or "", event.get("context") or "", event.get("query") or "")
    if reason in message and isinstance(detail, str) and token in detail and all(token not in field for field in other_fields):
        count += 1
print(count)
EOF
}

auth_wait_export() {
  n=0
  while [ "$n" -lt 20 ]; do
    auth_assert_export >/dev/null 2>&1 && return 0
    n=$((n + 1)); sleep 1
  done
  fail "auth DETAIL probe: failed-auth event never reached export"
}

auth_count_control() {
  python3 - "$LT_AUTH_EXPORT_FILE" "$LT_AUTH_CONTROL" <<'EOF'
import json, sys
path, control = sys.argv[1:]
count = 0
for line in open(path, encoding="utf-8"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if control in (event.get("message") or ""):
        count += 1
print(count)
EOF
}

auth_wait_control() {
  auth_control_before=$1
  n=0
  while [ "$n" -lt 20 ]; do
    auth_control_after=$(auth_count_control)
    case "$auth_control_after" in ''|*[!0-9]*) fail "auth DETAIL probe: invalid control-event count" ;; esac
    [ "$auth_control_after" -gt "$auth_control_before" ] && return 0
    n=$((n + 1)); sleep 1
  done
  fail "auth DETAIL probe: post-exclusion control event never reached export"
}

auth_admin() {
  docker exec "$auth_target" psql -X -U "$LT_AUTH_ADMIN_USER" -d "$LT_AUTH_DB" -v ON_ERROR_STOP=1 "$@"
}

auth_restore_exclude() {
  [ "${auth_exclude_armed:-0}" = 1 ] || return 0
  auth_admin -qc "ALTER SYSTEM RESET pg_logtap.pattern_exclude" >/dev/null &&
    auth_admin -qc "SELECT pg_reload_conf()" >/dev/null || return 1
  auth_exclude_armed=0
}

auth_preflight_fail() {
  printf '%s\n' "e2e-$E2E_TAG: FAILED: $*" >&2
  exit 1
}

auth_check_owner() {
  auth_id=$(docker inspect -f '{{.Id}}' "$LT_AUTH_PG_CONTAINER") || auth_preflight_fail "auth DETAIL probe: cannot inspect supplied PG container"
  [ "$auth_id" = "$LT_AUTH_EXPECTED_ID" ] || auth_preflight_fail "auth DETAIL probe: supplied PG container ID does not match"
  auth_target=$auth_id
  case "$LT_AUTH_LABEL_KEY" in ''|*[!A-Za-z0-9_.-]*) auth_preflight_fail "auth DETAIL probe: invalid label key" ;; esac
  auth_label=$(docker inspect -f "{{index .Config.Labels \"$LT_AUTH_LABEL_KEY\"}}" "$auth_target") || auth_preflight_fail "auth DETAIL probe: cannot read supplied PG label"
  [ "$auth_label" = "$LT_AUTH_LABEL_VALUE" ] || auth_preflight_fail "auth DETAIL probe: supplied PG container label does not match"
  [ "$(docker inspect -f '{{.State.Running}}' "$auth_target")" = true ] || auth_preflight_fail "auth DETAIL probe: supplied PG container is not running"
  E2E_CT=$auth_target
}

auth_bad_login() {
  if docker exec -e "PGPASSWORD=$LT_AUTH_BAD_PASSWORD" "$auth_target" \
    psql -X -w -h "$LT_AUTH_CONNECT_HOST" -p "$LT_AUTH_CONNECT_PORT" -U "$LT_AUTH_USER" -d "$LT_AUTH_DB" -qc 'SELECT 1' >/dev/null 2>&1; then
    fail "auth DETAIL probe: bad-password login unexpectedly succeeded"
  fi
}

auth_detail_probe() {
  auth_require_assert_env
  [ -n "${LT_AUTH_PG_CONTAINER:-}" ] || fail "auth DETAIL probe: LT_AUTH_PG_CONTAINER is required"
  [ -n "${LT_AUTH_EXPECTED_ID:-}" ] || fail "auth DETAIL probe: LT_AUTH_EXPECTED_ID is required"
  [ -n "${LT_AUTH_LABEL_KEY:-}" ] || fail "auth DETAIL probe: LT_AUTH_LABEL_KEY is required"
  [ -n "${LT_AUTH_LABEL_VALUE:-}" ] || fail "auth DETAIL probe: LT_AUTH_LABEL_VALUE is required"
  [ -n "${LT_AUTH_ADMIN_USER:-}" ] || fail "auth DETAIL probe: LT_AUTH_ADMIN_USER is required"
  [ -n "${LT_AUTH_DB:-}" ] || fail "auth DETAIL probe: LT_AUTH_DB is required"
  [ -n "${LT_AUTH_CONNECT_HOST:-}" ] || fail "auth DETAIL probe: LT_AUTH_CONNECT_HOST is required"
  [ -n "${LT_AUTH_CONNECT_PORT:-}" ] || fail "auth DETAIL probe: LT_AUTH_CONNECT_PORT is required"
  [ -n "${LT_AUTH_USER:-}" ] || fail "auth DETAIL probe: LT_AUTH_USER is required"
  [ -n "${LT_AUTH_BAD_PASSWORD:-}" ] || fail "auth DETAIL probe: LT_AUTH_BAD_PASSWORD is required"
  [ -n "${LT_AUTH_CONTROL:-}" ] || fail "auth DETAIL probe: LT_AUTH_CONTROL is required"
  case "$LT_AUTH_HBA_TOKEN" in ''|*[!A-Za-z0-9_]*) fail "auth DETAIL probe: HBA token must be a literal-safe unique token" ;; esac
  case "$LT_AUTH_CONTROL" in ''|*[!A-Za-z0-9_]*) fail "auth DETAIL probe: control must be a literal-safe unique token" ;; esac
  case "$LT_AUTH_CONTROL" in *"$LT_AUTH_HBA_TOKEN"*) fail "auth DETAIL probe: control must not contain the excluded HBA token" ;; esac
  case "$LT_AUTH_CONNECT_PORT" in ''|*[!0-9]*) fail "auth DETAIL probe: port must be numeric" ;; esac

  auth_check_owner
  [ "$(auth_admin -Atc 'SHOW pg_logtap.pattern_exclude')" = "" ] || fail "auth DETAIL probe: fixture must start with empty pattern_exclude"
  auth_exclude_armed=0
  trap 'auth_restore_exclude' 0
  auth_initial=$(auth_count_export)
  [ "$auth_initial" = 0 ] || fail "auth DETAIL probe: export already contains this unique HBA token"
  auth_control_initial=$(auth_count_control)
  case "$auth_control_initial" in ''|*[!0-9]*) fail "auth DETAIL probe: invalid control-event count" ;; esac
  [ "$auth_control_initial" = 0 ] || fail "auth DETAIL probe: export already contains this unique control marker"

  auth_bad_login
  auth_wait_export
  auth_before=$(auth_count_export)
  case "$auth_before" in ''|*[!0-9]*) fail "auth DETAIL probe: invalid exported-event count" ;; esac
  [ "$auth_before" -gt "$auth_initial" ] || fail "auth DETAIL probe: no exported failed-auth event"

  auth_admin -qc "ALTER SYSTEM SET pg_logtap.pattern_exclude TO '$LT_AUTH_HBA_TOKEN'" >/dev/null || fail "auth DETAIL probe: cannot set pattern_exclude"
  auth_exclude_armed=1
  auth_admin -qc 'SELECT pg_reload_conf()' >/dev/null || fail "auth DETAIL probe: cannot reload pattern_exclude"
  sleep 1
  [ "$(auth_admin -Atc 'SHOW pg_logtap.pattern_exclude')" = "$LT_AUTH_HBA_TOKEN" ] || fail "auth DETAIL probe: pattern_exclude did not take effect"

  auth_bad_login
  auth_admin -qc "DO \$\$ BEGIN RAISE WARNING '$LT_AUTH_CONTROL'; END \$\$" >/dev/null || fail "auth DETAIL probe: cannot emit control event"
  auth_wait_control "$auth_control_initial"
  auth_after=$(auth_count_export)
  [ "$auth_after" = "$auth_before" ] || fail "auth DETAIL probe: pattern_exclude did not suppress the failed-auth DETAIL event"

  auth_restore_exclude || fail "auth DETAIL probe: cannot reset pattern_exclude"
  trap - 0
  ok "failed-auth reason/effective HBA DETAIL exported, then suppressed by pattern_exclude"
}

case "${PG_LOGTAP_AUTH_PROBE:-}" in
  '') ;;
  assert) auth_require_assert_env && auth_assert_export; exit $? ;;
  run) auth_detail_probe; exit $? ;;
  *) printf '%s\n' "PG_LOGTAP_AUTH_PROBE must be run or assert" >&2; exit 2 ;;
esac

e2e_init robust "${1:-}"
e2e_gate

echo "== credential header GUC: privileged visibility =="
plain_role="lt_hdr_plain_$$"
reader_role="lt_hdr_reader_$$"
monitor_role="lt_hdr_monitor_$$"
dummy_header="Authorization: Bearer robust$SUF"
docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -qc "
  CREATE ROLE $plain_role LOGIN;
  CREATE ROLE $reader_role LOGIN;
  CREATE ROLE $monitor_role LOGIN;
  GRANT pg_read_all_settings TO $reader_role;
  GRANT pg_monitor TO $monitor_role;" >/dev/null
setguc pg_logtap.export_http_extra_headers "$dummy_header"; reload; sleep 1
super_value=$(docker exec "$PG_CT" psql -X -U postgres -Atc \
  "SHOW pg_logtap.export_http_extra_headers")
[ "$super_value" = "$dummy_header" ] \
  || fail "credential header GUC: superuser could not read configured value"
role=$plain_role
  if docker exec "$PG_CT" psql -X -U "$role" -d postgres -v ON_ERROR_STOP=1 -Atc \
    "SHOW pg_logtap.export_http_extra_headers" >/dev/null 2>&1; then
    fail "credential header GUC: ordinary role can SHOW the value"
  fi
  if docker exec "$PG_CT" psql -X -U "$role" -d postgres -v ON_ERROR_STOP=1 -Atc \
    "SELECT current_setting('pg_logtap.export_http_extra_headers')" >/dev/null 2>&1; then
    fail "credential header GUC: ordinary role can use current_setting"
  fi
  rows=$(docker exec "$PG_CT" psql -X -U "$role" -d postgres -Atc \
    "SELECT count(*) FROM pg_settings WHERE name = 'pg_logtap.export_http_extra_headers'")
  [ "$rows" = 0 ] || fail "credential header GUC: ordinary role can see pg_settings row"
  if docker exec "$PG_CT" psql -X -U "$role" -d postgres -v ON_ERROR_STOP=1 -qc \
    "ALTER ROLE $role SET pg_logtap.export_http_extra_headers = 'X-Test: changed'" \
    >/dev/null 2>&1; then
    fail "credential header GUC: ordinary role can change the value"
  fi
for role in "$reader_role" "$monitor_role"; do
  visible=$(docker exec "$PG_CT" psql -X -U "$role" -d postgres -Atc \
    "SELECT current_setting('pg_logtap.export_http_extra_headers') = '$dummy_header'")
  [ "$visible" = t ] || fail "credential header GUC: trusted settings reader cannot read value"
  rows=$(docker exec "$PG_CT" psql -X -U "$role" -d postgres -Atc \
    "SELECT count(*) FROM pg_settings WHERE name = 'pg_logtap.export_http_extra_headers'")
  [ "$rows" = 1 ] || fail "credential header GUC: trusted settings reader cannot see pg_settings row"
  if docker exec "$PG_CT" psql -X -U "$role" -d postgres -v ON_ERROR_STOP=1 -qc \
    "ALTER ROLE $role SET pg_logtap.export_http_extra_headers = 'X-Test: changed'" \
    >/dev/null 2>&1; then
    fail "credential header GUC: read privilege also granted write privilege"
  fi
done
setguc pg_logtap.export_http_extra_headers ''; reload
docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -qc "
  REVOKE pg_read_all_settings FROM $reader_role;
  REVOKE pg_monitor FROM $monitor_role;
  DROP ROLE $plain_role, $reader_role, $monitor_role;" >/dev/null
ok "ordinary roles cannot read/change credentials; pg_read_all_settings and pg_monitor remain read-only"

echo "== huge fields: message and detail past their ring slots =="
# Reset every GUC a previous (possibly failed) run may have left armed — the
# scenarios below set their own; a leftover redact_pattern or field_query
# changes what this one must observe.
setguc log_min_duration_statement -1; setguc pg_logtap.field_query off; setguc pg_logtap.redact_pattern ''
setguc pg_logtap.level_min 15; setguc pg_logtap.export_url "http://$VEC:8686"
setguc pg_logtap.export_fallback_file ''; reload; sleep 2
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
  END \$\$" >/dev/null 2>&1
wait_for huge 1 "" 20
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
  >/dev/null 2>&1
setguc pg_logtap.redact_pattern 'SECRET-[a-z0-9-]+'; reload; sleep 1
# Before the pattern switches on — the DETAIL probes below must be masked by
# the password VALUE cut alone: a secret assigned to the token is masked,
# PG's own "password authentication failed" phrasing survives verbatim.
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redd$SUF 0' USING DETAIL = 'password = ''SECRET-det$SUF-xyz789'' and user alice';
  RAISE WARNING 'logtap robust redd$SUF 1' USING DETAIL = 'password authentication failed for user \"alice\"';
  END \$do\$" >/dev/null 2>&1
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redp$SUF 0 token=SECRET-msg$SUF-abc123'; END \$do\$" \
  >/dev/null 2>&1
wait_for redq 1 "" 20; wait_for redp 1 "" 20; wait_for redd 2 "" 20
# vector-out.jsonl accumulates across runs BY DESIGN: the secrets carry this
# run's suffix so stale lines from earlier runs cannot fail this one.
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: contract"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
whole = open(path, encoding="utf-8").read()
for secret in ("SECRET-query" + suf + "-abc123", "SECRET-do" + suf + "-abc123", "SECRET-msg" + suf + "-abc123",
               "SECRET-det" + suf + "-xyz789", "SECRET-or" + suf + "-xyz789"):
    assert secret not in whole, secret + " reached the receiver unmasked"
q = p = role = det = False
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
    if m.startswith("logtap robust redd" + suf):
        d = e.get("detail") or ""
        if m.endswith(" 0"):  # assigned value masked, surrounding text intact
            assert d == "password = <REDACTED> and user alice", repr(d)
        else:  # PG's standard failure phrasing: not ours to rewrite
            assert d == 'password authentication failed for user "alice"', repr(d)
        det = True
for line in whole.splitlines():  # the role's duration line has no red marker
    if "tmp_red" + suf not in line:
        continue
    e = json.loads(line)
    m = e.get("message", "")
    if "CREATE ROLE" in m:
        assert "<REDACTED>" in m, m
        role = True
assert q and p and role and det, "probe events missing (q=%s p=%s role=%s det=%s)" % (q, p, role, det)
EOF
# truncated vs redacted are two different causes for a cut field (LT-1): a
# redaction that expands past the scratch cap clips WITHOUT slot-truncating
# (the clip result fits the slot exactly) → redacted only; a DETAIL past its
# 256-byte slot whose redaction also clips → both arrays name it.
setguc pg_logtap.redact_pattern 'ZZ'; reload; sleep 1
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redclip$SUF 0 %', repeat('ZZ ', 316);
  END \$do\$" >/dev/null 2>&1
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redboth$SUF 0 x' USING DETAIL = repeat('ZZ ', 400);
  END \$do\$" >/dev/null 2>&1
# The password value cut clips on this 1800-byte DETAIL (past the 1025-byte
# scratch); redact_pattern 'ZZ' does not match the filler, so the regex layer
# does not clip — the clip of the FIRST layer must still reach redacted_mask.
docker exec "$PG_CT" psql -U postgres -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redor$SUF 0' USING DETAIL =
    'password = ''SECRET-or$SUF-xyz789'' tail ' || repeat('ab ', 600);
  END \$do\$" >/dev/null 2>&1
wait_for redclip 1 "" 20; wait_for redboth 1 "" 20; wait_for redor 1 "" 20
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: truncated/redacted split"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
clip = both = orflag = False
for line in open(path, encoding="utf-8"):
    if ("logtap robust redclip" + suf not in line and "logtap robust redboth" + suf not in line
            and "logtap robust redor" + suf not in line):
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
    if m.startswith("logtap robust redor" + suf):
        # The mandatory value cut clipped before the active regex: fail closed
        # to the complete marker, which fits the DETAIL slot unchanged.
        d = e.get("detail") or ""
        assert "detail" in e["redacted"] and "detail" not in e["truncated"], e
        assert d == "<REDACTED>", repr(d)
        orflag = True
assert clip and both and orflag, "probes missing (clip=%s both=%s or=%s)" % (clip, both, orflag)
EOF
ok "redaction clip and slot overflow reported separately (redacted vs truncated)"
docker exec "$PG_CT" psql -U postgres -qc "DROP ROLE IF EXISTS \"tmp_red$SUF\"" >/dev/null 2>&1
setguc log_min_duration_statement -1; setguc pg_logtap.field_query off; setguc pg_logtap.redact_pattern ''; reload
ok "statement passwords cut (message and query), benign message word verbatim, redact_pattern masked"

echo "== prepared EXECUTE DETAIL uses the server logging field =="
# Keep one connection for PREPARE/EXECUTE. PostgreSQL suppresses a duplicate
# duration query when log_statement already emitted it, so run one EXECUTE
# through each logging path. No query field or regex may hide a tail-cut failure.
setguc pg_logtap.field_query off; setguc pg_logtap.redact_pattern ''; reload; sleep 1
probe="logtap_mask_probe$SUF"
docker exec -i "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 >/dev/null <<EOF
SET log_statement = 'all';
SET log_min_duration_statement = -1;
PREPARE "$probe" AS SELECT 'logtap-prepare-probe$SUF password=SECRET-canary-$SUF'::text;
EXECUTE "$probe";
SET log_statement = 'none';
SET log_min_duration_statement = 0;
EXECUTE "$probe";
DEALLOCATE "$probe";
EOF
n=0; while [ "$n" -lt 20 ]; do
  [ "$(tail -c 50000000 "$OUT/vector-out.jsonl" 2>/dev/null | grep -F -c "$probe")" -ge 2 ] && break
  n=$((n + 1)); sleep 1
done
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "prepared EXECUTE DETAIL: contract"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
probe = "logtap_mask_probe" + suf
secret = "SECRET-canary-" + suf
whole = open(path, encoding="utf-8").read()
assert secret not in whole, "canary reached exported data"
statement = duration = detail = False
for line in whole.splitlines():
    event = json.loads(line)
    message = event.get("message") or ""
    if "EXECUTE" not in message or probe not in message:
        continue
    if message.startswith("statement:"):
        statement = True
    if message.startswith("duration:") and "statement:" in message:
        duration = True
    if "detail" in event and event["detail"] is not None:
        assert "<REDACTED>" in event["detail"], event["detail"]
        detail = True
assert statement and duration and detail, (
    "missing EXECUTE evidence (statement=%s duration=%s detail=%s)" %
    (statement, duration, detail)
)
EOF
ok "same-session PREPARE/EXECUTE keeps effective DETAIL present and masked for statement and duration logs"

echo "== regex GUCs: invalid replacements preserve active expressions =="
raw_count() { grep -F -c "$1" "$OUT/vector-out.jsonl" 2>/dev/null || true; }
wait_raw() {
  needle=$1; n=0
  while [ "$n" -lt 20 ]; do
    [ "$(raw_count "$needle")" -ge 1 ] && return 0
    n=$((n + 1)); sleep 1
  done
  fail "regex GUCs: receiver never saw $needle"
}
reject_regex() { # reject_regex <guc> <bad value> <active value>
  if setguc "$1" "$2" 2>/dev/null; then
    fail "$1 accepted invalid regex"
  fi
  current=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW $1")
  [ "$current" = "$3" ] || fail "$1 changed after rejected regex"
  [ "$(statf redact_pattern_failed)" = 0 ] \
    || fail "$1 rejection changed redact_pattern_failed"
}

include_re="^RXINC$SUF [0-9]+$"
setguc pg_logtap.pattern "$include_re"; reload; sleep 1
reject_regex pg_logtap.pattern '[unclosed' "$include_re"
reject_regex pg_logtap.pattern '(RX).*(\1)' "$include_re"
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'RXINC$SUF %', 2;
  RAISE WARNING 'RXMISS$SUF %', 2;
END \$\$" >/dev/null 2>&1
wait_raw "RXINC$SUF 2"
[ "$(raw_count "RXMISS$SUF 2")" = 0 ] \
  || fail "pg_logtap.pattern stopped filtering after rejected replacement"

setguc pg_logtap.pattern ''; setguc pg_logtap.pattern_exclude "RXBLOCK$SUF"; reload; sleep 1
reject_regex pg_logtap.pattern_exclude '[unclosed' "RXBLOCK$SUF"
reject_regex pg_logtap.pattern_exclude '(RX).*(\1)' "RXBLOCK$SUF"
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'RXBLOCK$SUF 2';
  RAISE WARNING 'RXPASS$SUF 2';
END \$\$" >/dev/null 2>&1
wait_raw "RXPASS$SUF 2"
[ "$(raw_count "RXBLOCK$SUF 2")" = 0 ] \
  || fail "pg_logtap.pattern_exclude stopped filtering after rejected replacement"

redact_re="RXSECRET$SUF-[0-9]+"
setguc pg_logtap.pattern_exclude ''; setguc pg_logtap.redact_pattern "$redact_re"; reload; sleep 1
reject_regex pg_logtap.redact_pattern '[unclosed' "$redact_re"
reject_regex pg_logtap.redact_pattern '(RX).*(\1)' "$redact_re"
docker exec "$PG_CT" psql -U postgres -qc "DO \$\$ BEGIN
  RAISE WARNING 'RXRED$SUF 2 RXSECRET$SUF-2';
END \$\$" >/dev/null 2>&1
wait_raw "RXRED$SUF 2"
red_line=$(grep -F "RXRED$SUF 2" "$OUT/vector-out.jsonl" | tail -1)
printf '%s' "$red_line" | grep -q '<REDACTED>' \
  || fail "pg_logtap.redact_pattern stopped masking after rejected replacement"
printf '%s' "$red_line" | grep -F -q "RXSECRET$SUF-2" \
  && fail "pg_logtap.redact_pattern exposed a secret after rejected replacement"
[ "$(statf redact_pattern_failed)" = 0 ] \
  || fail "ordinary rejected regex set redact_pattern_failed"
setguc pg_logtap.redact_pattern ''; reload; sleep 1
[ "$(statf redact_pattern_failed)" = 0 ] \
  || fail "successful regex reset did not clear redact_pattern_failed"
ok "all regex GUCs reject syntax/backreferences and retain active behavior"

# Extended protocol (JDBC, psycopg, pgbench -M extended): duration lines for
# parse/bind/execute carry the raw SQL WITHOUT the "statement: " marker — the
# cut must fire on the phase words too. The probe SQL puts the tag BEFORE the
# password token (survives the cut, marks the line) and the secret AFTER it
# (a prepared statement's secret position). redact_pattern stays off so only
# the token cut can mask.
setguc log_min_duration_statement 0; reload; sleep 1
docker exec "$PG_CT" sh -c "printf '%s\n' \"SELECT 'ext$SUF' AS tag, 'password' AS kw, 'SECRET-exec$SUF-abc123' AS val;\" > /tmp/probe-ext.sql"
docker exec "$PG_CT" pgbench -U postgres -M extended -c 1 -t 1 -f /tmp/probe-ext.sql postgres >/dev/null 2>&1
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

# Bind parameters: statement logging puts values in a translated DETAIL
# wrapper, while execution errors put them in a translated CONTEXT wrapper
# when log_parameter_max_length_on_error is set. The shared `$N = 'value'`
# payload must be masked in both. psql \bind is psql 16+; PG15 drives the same
# extended-protocol paths through pgbench -M extended.
# Exercise the mandatory layers together, without a regex hiding a failure.
# A skipped password token must not remove the bind prefix from either field.
docker exec "$PG_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -qc "DO \$do\$ BEGIN
  RAISE WARNING 'logtap robust redaux$SUF 0'
    USING DETAIL = 'Parameters: \$1 = ''password note password ''''SECRET-aux$SUF-canary'''' trailing''',
          HINT = 'Paramètres : \$1 = ''password note password ''''SECRET-aux$SUF-canary'''' trailing''';
END \$do\$" >/dev/null 2>&1
wait_for redaux 1 "" 20
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: password-value then bind-value auxiliary pipeline"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
marker = "logtap robust redaux" + suf + " 0"
seen = False
for line in open(path, encoding="utf-8"):
    if marker not in line:
        continue
    assert "SECRET-aux" + suf + "-canary" not in line, "canary reached exported data"
    event = json.loads(line)
    if event.get("message") == marker:
        assert event.get("detail") == "Parameters: $1 = <REDACTED>", event
        assert event.get("hint") == "Paramètres : $1 = <REDACTED>", event
        seen = True
assert seen, "auxiliary-field pipeline probe missing"
EOF
ok "password-value and bind-value layers compose without losing auxiliary prefixes"

setguc log_min_duration_statement 0; setguc log_parameter_max_length 100
setguc log_parameter_max_length_on_error 100; reload; sleep 1
vnum=$(docker exec "$PG_CT" psql -U postgres -Atc "SHOW server_version_num")
if [ "$vnum" -ge 160000 ]; then
  # -i: without it docker exec does not forward stdin, psql reads an empty
  # buffer and silently runs nothing
  docker exec -i "$PG_CT" psql -U postgres >/dev/null 2>&1 <<EOF
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
    if "duration:" in m and d.lower().startswith("parameters:"):
        # every quoted value masked, the $N keys and structure verbatim
        assert d.startswith(("Parameters: $1 = <REDACTED>", "parameters: $1 = <REDACTED>")), d
        assert d.endswith("$2 = <REDACTED>"), d
        assert "SECRET" not in d and "pw" not in d, d
        saw += 1
assert saw > 0, "no bind-parameter detail lines reached the receiver"
EOF
  # Bind succeeds, then division by zero fails during Execute. PostgreSQL adds
  # every saved bind value to CONTEXT on this error path.
  docker exec -e "PGAPPNAME=logtap-ctx$SUF" -i "$PG_CT" psql -U postgres >/dev/null 2>&1 <<EOF
SELECT 'ctxmarker$SUF' AS tag, \$1::text, 1 / \$2::int \bind 'password note password ''''SECRET-ctx$SUF-uvw456'''' trailing' '0'
\g
EOF
else
  # PG15: no psql \bind — drive extended protocol with pgbench. -f script
  # keeps the secret OUT of the SQL text (:var leaves as a bind parameter,
  # the DETAIL is where it surfaces; the quoted :'v' form is NOT replaced
  # in extended mode — plain :v is); the tag literal is the marker.
  docker exec "$PG_CT" sh -c "cat > /tmp/p15bind.sql <<EOF
SELECT 'p15bind$SUF' AS tag, :v::text;
EOF"
  docker exec "$PG_CT" pgbench -U postgres -M extended -t 1 -c 1 \
    -f /tmp/p15bind.sql -D "v=SECRET-p15bind$SUF-xyz789" postgres >/dev/null 2>&1
  docker exec "$PG_CT" rm -f /tmp/p15bind.sql
  n=0; while [ "$n" -lt 20 ]; do
    [ "$(tail -c 50000000 "$OUT/vector-out.jsonl" 2>/dev/null | grep -c "p15bind$SUF")" -gt 0 ] && break
    n=$((n + 1)); sleep 1
  done
  python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: bind-parameter values masked (pgbench path)"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
whole = open(path, encoding="utf-8").read()
assert "SECRET-p15bind" + suf not in whole, "bind value reached the receiver via DETAIL"
saw = 0
for line in whole.splitlines():
    if "p15bind" + suf not in line:
        continue
    e = json.loads(line)
    m, d = e.get("message") or "", e.get("detail") or ""
    if "duration:" in m and d.lower().startswith("parameters:"):
        assert d.startswith(("Parameters: $1 = <REDACTED>", "parameters: $1 = <REDACTED>")), d
        assert "SECRET" not in d, d
        saw += 1
assert saw > 0, "no bind-parameter detail lines reached the receiver"
EOF
  docker exec "$PG_CT" sh -c "cat > /tmp/p15ctx.sql <<EOF
SELECT 'ctxmarker$SUF' AS tag, :secret::text, 1 / :zero::int;
EOF"
  docker exec "$PG_CT" pgbench -U postgres -M extended -t 1 -c 1 \
    -f /tmp/p15ctx.sql -D "secret=password note password ''SECRET-ctx$SUF-uvw456'' trailing" -D zero=0 \
    "dbname=postgres application_name=logtap-ctx$SUF" >/dev/null 2>&1
  docker exec "$PG_CT" rm -f /tmp/p15ctx.sql
fi
n=0; while [ "$n" -lt 20 ]; do
  [ "$(grep -c "\"app\":\"logtap-ctx$SUF\"" "$OUT/vector-out.jsonl")" -gt 0 ] && break
  n=$((n + 1)); sleep 1
done
python3 - "$OUT/vector-out.jsonl" "$SUF" <<'EOF' || fail "redact: error-context bind values masked"
import json, sys
path, suf = sys.argv[1], sys.argv[2]
whole = open(path, encoding="utf-8").read()
secret = "SECRET-ctx" + suf + "-uvw456"
assert secret not in whole, "bind value reached the receiver via CONTEXT"
app = "logtap-ctx" + suf
contexts = []
for line in whole.splitlines():
    e = json.loads(line)
    if e.get("app") == app and e.get("context"):
        contexts.append(e["context"])
assert contexts, "no extended-protocol error CONTEXT reached the receiver"
assert any("$1 = <REDACTED>" in c and "$2 = <REDACTED>" in c for c in contexts), contexts
EOF
setguc log_min_duration_statement -1; setguc log_parameter_max_length -1
setguc log_parameter_max_length_on_error 0; reload
ok "bind-parameter values masked in translated DETAIL and error CONTEXT wrappers"

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
# The control event carries free text (no numbered marker tail), so wait on
# the raw line count, not the marker counter.
n=0; while [ "$n" -lt 10 ]; do
  [ "$(grep -c "exc-control$SUF" "$OUT/vector-out.jsonl")" -ge 1 ] && break
  n=$((n + 1)); sleep 1
done
[ "$(grep -c "exc-control$SUF" "$OUT/vector-out.jsonl")" -ge 1 ] \
  || fail "pattern_exclude: the token-free neighbor never reached the receiver"
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
docker exec "$PG_CT" pgbench -i -q -U postgres postgres >/dev/null 2>&1
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
# No such process" then fails the loop body — Re-find until
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
dups=$(duplicate_seqs)
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
       docker exec "$PG_CT" cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null)
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
# lock; the window needs live lock traffic to matter, so flip valid patterns
# through several reloads while backends push logged statements. Invalid
# patterns never reach assign now — their rejection is covered above. Runs
# AFTER the memory-peak assert on purpose: statement-rate logging at the
# default backlog depth is what that assert exists to forbid.
# Backlog is still clamped to 8192 by the scenario above, so the burst's RAM
# cost is the documented ~28MB, not a GUC-default surprise.
setguc log_min_duration_statement 0; reload
docker exec "$PG_CT" sh -c "printf '%s\n' 'SELECT 1;' > /tmp/probe-load$SUF.sql"
docker exec -d "$PG_CT" pgbench -U postgres -c 4 -T 12 -f "/tmp/probe-load$SUF.sql" postgres
flip=0
while [ "$flip" -lt 8 ]; do
  setguc pg_logtap.redact_pattern "reload-under-load-$flip"
  reload; sleep 1
  flip=$((flip + 1))
done
docker exec "$PG_CT" psql -U postgres -qc "SELECT 1" >/dev/null 2>&1 || fail "redact_pattern reload under load crashed the server"
[ "$(statf redact_pattern_failed)" = 0 ] || fail "valid pattern under load set redact_pattern_failed"
setguc pg_logtap.redact_pattern ''; setguc log_min_duration_statement -1; reload; sleep 1
ok "redact_pattern reloaded 8x under pgbench statement load: postmaster survived, gauge clear"

echo "== fragmented HTTP status: the line straddles recvs =="
# TCP owes the sender no message boundaries: a receiver whose "HTTP/1.1 200"
# lands as two recvs ("HTTP/1." then "1 200 OK…", 300ms apart — past any
# coalescing) is perfectly legal, and the batch is already in its hands. A
# one-recv status read fails such a send → the batch parks on the fallback
# queue and replays as a DUPLICATE of what the receiver already had. The
# regression signal is that duplicate, not the divert itself (a divert is
# documented for any send failure): the suite-local python sink counts total
# marker lines ever delivered vs unique ones — they must be equal. The sink
# is dialed by CONTAINER IP, not name: resolving a fresh name from the
# long-lived worker can wedge in glibc/docker DNS (the outage the worker's
# dns_good cache exists for — but that cache cannot bootstrap a first-ever
# name), and this scenario tests the status read, not the resolver.
FRAG=pglogtap-frag-sink-$PG_CT # per container: parallel majors each rm -f it
docker rm -f "$FRAG" >/dev/null 2>&1
docker run -d --rm --name "$FRAG" --network "$NET" python:3-alpine python -u -c '
import re, socket, time
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 8687)); srv.listen(64)
seen = set()
total = 0
statuses = {
    b"/status/200": b"HTTP/1.1 200 OK\r\n",
    b"/status/203": b"HTTP/1.1 203 Non-Authoritative Information\r\n",
    b"/status/204": b"HTTP/1.1 204 No Content\r\n",
    b"/status/299": b"HTTP/1.1 299 Custom\r\n",
    b"/status/199": b"HTTP/1.1 199 Old\r\n",
    b"/status/300": b"HTTP/1.1 300 Multiple\r\n",
    b"/status/401": b"HTTP/1.1 401 Unauthorized\r\n",
    b"/status/500": b"HTTP/1.1 500 Error\r\n",
    b"/status/2xx": b"HTTP/1.1 2xx Bad\r\n",
    b"/status/20x": b"HTTP/1.1 20x Bad\r\n",
    b"/status/version": b"HTTP/2.0 200 Bad\r\n",
    b"/status/separator": b"HTTP/1.1-200 Bad\r\n",
    b"/status/2000": b"HTTP/1.1 2000 Bad\r\n",
}
while True:
    conn, _ = srv.accept()
    try:
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            d = conn.recv(4096)
            if not d:
                break
            hdr += d
        if b"\r\n\r\n" in hdr:
            clen = 0
            for line in hdr.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    clen = int(line.split(b":")[1])
            body = hdr.split(b"\r\n\r\n", 1)[1]
            while len(body) < clen:
                d = conn.recv(65536)
                if not d:
                    break
                body += d
            target = hdr.split(b"\r\n", 1)[0].split(b" ")[1]
            if target == b"/frag":
                conn.sendall(b"HTTP/1.")  # 7 bytes: below the 12 a status line needs
                time.sleep(0.3)           # two recvs for sure, still inside send timeout
                conn.sendall(b"1 200 OK\r\nContent-Length: 0\r\n\r\n")
            elif target == b"/status/203frag":
                conn.sendall(b"HTTP/1.1 203 Non-")
                time.sleep(0.3)
                conn.sendall(b"Authoritative Information\r\nContent-Length: 0\r\n\r\n")
            elif target == b"/status/incomplete":
                conn.sendall(b"HTTP/1.1 200")
            elif target == b"/status/long":
                conn.sendall(b"HTTP/1.1 200 " + b"x" * 256 + b"\r\nContent-Length: 0\r\n\r\n")
            else:
                conn.sendall(statuses[target] + b"Content-Length: 0\r\n\r\n")
            lines = [l for l in body.splitlines() if b"logtap robust" in l]
            total += len(lines)
            seen.update(lines)
            for line in lines:
                marker = re.search(rb"logtap robust ([A-Za-z0-9_.-]+) [0-9]+", line)
                if marker:
                    print("FRAGMARK target=%s marker=%s" % (target.decode(), marker.group(1).decode()), flush=True)
            print("FRAGSTAT total=%d uniq=%d" % (total, len(seen)), flush=True)
    except OSError:  # readiness probes close without sending: EPIPE must not kill the sink
        pass
    finally:
        conn.close()
' >/dev/null
n=0; SIP=''
while [ "$n" -lt 30 ]; do
  SIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$FRAG" 2>/dev/null)
  [ -n "$SIP" ] && docker exec "$PG_CT" bash -c "exec 3<>/dev/tcp/$SIP/8687" 2>/dev/null && break
  n=$((n + 1)); sleep 1
done
[ "$n" -lt 30 ] || { docker rm -f "$FRAG" >/dev/null 2>&1; fail "frag-status: sink never answered on $FRAG:8687"; }
frag_marker_count() {
  docker logs "$FRAG" 2>/dev/null | grep -F -c "FRAGMARK target=$2 marker=$1"
}
frag_restore() {
  if [ "${frag_route_configured:-0}" = 1 ]; then
    setguc pg_logtap.export_url "http://$VEC:8686" || return 1
    reload || return 1
    n=0
    while [ "$n" -lt 30 ]; do
      qb=$(( $(statf events_queued) - $(statf events_replayed) - $(statf events_compacted) ))
      [ "$qb" -le 0 ] && break
      n=$((n + 1)); sleep 1
    done
    [ "$n" -lt 30 ] || return 1
    setguc pg_logtap.export_fallback_file '' || return 1
    reload || return 1
  fi
  docker rm -f "$FRAG" >/dev/null 2>&1 || return 1
  frag_cleanup_armed=0
}
frag_cleanup() {
  frag_cleanup_status=$1
  trap - EXIT INT TERM
  if [ "${frag_cleanup_armed:-0}" = 1 ] && ! frag_restore; then
    [ "$frag_cleanup_status" -ne 0 ] || frag_cleanup_status=1
  fi
  exit "$frag_cleanup_status"
}
frag_cleanup_armed=1
frag_route_configured=0
trap 'frag_cleanup $?' EXIT
trap 'frag_cleanup 130' INT
trap 'frag_cleanup 143' TERM
setguc pg_logtap.export_url "http://$SIP:8687/frag" || fail "frag-status: cannot set fragmented receiver URL"
frag_route_configured=1
setguc pg_logtap.export_fallback_file 'pg_logtap-fallback.bin' || fail "frag-status: cannot set fallback file"
reload || fail "frag-status: cannot reload fragmented receiver settings"
sleep 2
gen frag 300
fragstat() { docker logs "$FRAG" 2>/dev/null | grep -oE 'FRAGSTAT total=[0-9]+ uniq=[0-9]+' | tail -1; }
n=0; while [ "$n" -lt 30 ]; do
  st=$(fragstat); uni=${st#*uniq=}
  [ "$uni" -ge 300 ] 2>/dev/null && break
  n=$((n + 1)); sleep 1
done
st=$(fragstat); tot=${st#*total=}; tot=${tot%% *}; uni=${st#*uniq=}
status_success() {
  kind=$1
  target=/status/$kind
  marker=statusok$kind$E2E_SUF
  before_sent=$(statf events_sent); before_failed=$(statf send_cycles_failed)
  setguc pg_logtap.export_url "http://$SIP:8687$target" || fail "status $kind: cannot set receiver URL"
  reload || fail "status $kind: cannot reload receiver URL"
  sleep 2
  gen "statusok$kind" 1
  n=0
  while [ "$n" -lt 30 ]; do
    current_seen=$(frag_marker_count "$marker" "$target")
    current_sent=$(statf events_sent); current_failed=$(statf send_cycles_failed)
    [ "$current_seen" -ge 1 ] 2>/dev/null &&
      [ "$current_sent" -gt "$before_sent" ] 2>/dev/null &&
      [ "$current_failed" = "$before_failed" ] && return 0
    n=$((n + 1)); sleep 1
  done
  [ "${current_seen:-0}" -ge 1 ] 2>/dev/null || fail "status $kind: receiver never saw its marker"
  [ "${current_sent:-0}" -gt "$before_sent" ] 2>/dev/null || fail "status $kind: receiver response was not acknowledged"
  fail "status $kind: a 2xx response grew failed cycles"
}
status_rejected() {
  kind=$1
  target=/status/$kind
  marker=statusbad$kind$E2E_SUF
  before_failed=$(statf send_cycles_failed)
  setguc pg_logtap.export_url "http://$SIP:8687$target" || fail "status $kind: cannot set receiver URL"
  reload || fail "status $kind: cannot reload receiver URL"
  sleep 2
  gen "statusbad$kind" 1
  n=0
  while [ "$n" -lt 30 ]; do
    current_seen=$(frag_marker_count "$marker" "$target")
    current_failed=$(statf send_cycles_failed)
    [ "$current_seen" -ge 1 ] 2>/dev/null &&
      [ "$current_failed" -gt "$before_failed" ] 2>/dev/null && break
    n=$((n + 1)); sleep 1
  done
  [ "${current_seen:-0}" -ge 1 ] 2>/dev/null \
    || fail "status $kind: receiver never saw the rejected marker"
  [ "${current_failed:-0}" -gt "$before_failed" ] 2>/dev/null \
    || fail "status $kind: malformed/non-2xx response did not fail the send"
  recovery_sent0=$(statf events_sent)
  setguc pg_logtap.export_url "http://$SIP:8687/status/204" || fail "status $kind: cannot set recovery URL"
  reload || fail "status $kind: cannot reload recovery URL"
  sleep 2
  n=0
  while [ "$n" -lt 30 ]; do
    recovery_seen=$(frag_marker_count "$marker" /status/204)
    current_sent=$(statf events_sent)
    [ "$recovery_seen" -ge 1 ] 2>/dev/null &&
      [ "$current_sent" -gt "$recovery_sent0" ] 2>/dev/null && return 0
    n=$((n + 1)); sleep 1
  done
  [ "${recovery_seen:-0}" -ge 1 ] 2>/dev/null \
    || fail "status $kind: rejected marker was not replayed to /status/204"
  fail "status $kind: replayed marker was not acknowledged"
}
for code in 200 203 203frag 204 299; do status_success "$code"; done
for kind in 199 300 401 500 2xx 20x version separator incomplete 2000 long; do status_rejected "$kind"; done
ok "complete 2xx status lines (200/203/204/299, including fragmented 203) acknowledged; non-2xx and malformed/incomplete/over-cap lines retried"
# Restore before the final assertions: the local EXIT trap runs this same
# path after every early failure, leaving fallback configured until it drains.
frag_restore || fail "frag-status: could not restore vector and drain fallback"
trap - EXIT INT TERM
[ "${uni:-0}" -ge 300 ] || fail "frag-status: the sink saw ${uni:-0}/300 unique events — delivery itself broke"
[ "$tot" = "$uni" ] \
  || fail "frag-status: $tot lines delivered for $uni events — a delivered batch was retried (one-recv status read)"
ok "status line across two recvs accepted: $tot events delivered, each exactly once"

dups=$(duplicate_seqs)
[ "$dups" = 0 ] || fail "$dups duplicate seqs across the suite"
echo "e2e-robust: all scenarios passed"
