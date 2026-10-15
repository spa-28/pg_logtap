#!/bin/sh
# Shared helpers for the e2e suites. POSIX sh, SOURCED — never executed.
# A stand-based suite does:
#   . "$(dirname "$0")/e2e-common.sh"
#   e2e_init kill "${1:-}"    # tag + container (defaults to a RUNNING
#                              # pglogtap-e2e stand, else pglogtap-pg)
#   e2e_gate                   # stand gate, freshness check, net, VEC up
# A suite with its own container (e2e-faults) sets E2E_TAG/E2E_CT after
# sourcing instead of calling e2e_init.
# Helpers address $E2E_CT (e2e_init also sets the $PG_CT alias the older
# suites are written against) and mark events as
#   logtap <tag> <marker>$E2E_SUF <i>          (E2E_SUF="-$$", unique/run)
# received() counts DISTINCT numbered markers: a re-sent chunk legitimately
# writes the same event twice, so a line count would lie. A suite whose
# markers carry no trailing number (e2e-wide) overrides received locally.

# Host builds must use the same effective binary that pgzx will execute.
# An absent/mismatched override selects the existing target-major container build.
e2e_pg_config() ( # <major>: print a matching host executable, or return nonzero
  config=${PG_CONFIG:-pg_config}
  version=$("$config" --version 2>/dev/null) || return 1
  case "$version" in "PostgreSQL $1."*|"PostgreSQL $1 "*|"PostgreSQL $1") ;; *) return 1 ;; esac
  command -v "$config"
)

# --- container pick, shared state, one-suite-per-container lock ------------
e2e_default_ct() {
  [ "$(docker inspect -f '{{.State.Status}}' pglogtap-e2e 2>/dev/null)" = running ] \
    && echo pglogtap-e2e || echo pglogtap-pg
}

e2e_init() { # e2e_init <tag> [container]
  E2E_TAG=$1
  PG_CT=${2:-$(e2e_default_ct)}
  E2E_CT=$PG_CT
  # E2E_OUT: a parallel matrix (test-matrix.sh JOBS>1) gives every major its
  # own dir — suite-private files (tls certs/sinks, hookchain.so) would
  # otherwise be rm'd/regenerated under each other. The shared vector sink
  # is symlinked in by the matrix.
  OUT=${E2E_OUT:-/tmp/logtap-e2e}
  # E2E_VECTOR: a parallel matrix gives every major its own vector — the
  # kill/robust suites stop THEIR receiver mid-scenario, which on a shared
  # one serialized the whole matrix. Sequential runs keep the stand's.
  VEC=${E2E_VECTOR:-pglogtap-vector}
  # shellcheck disable=SC2034 # suite bodies use it (kill's silent receiver)
  SILENT=pglogtap-silent
  NET=pglogtap-e2e_default
  SUF="-$$" # per-run marker suffix: sink files accumulate across runs BY DESIGN
  E2E_SUF=$SUF
  mkdir -p "$OUT"
  e2e_lock
}

e2e_lock() { # one suite per container: a deploy or a second suite restarts
  # the postmaster mid-scenario and both fail mysteriously. The lock is held
  # on fd 9 for the script's life. Identity must not depend on output roots.
  mkdir -p "${E2E_LOCK_DIR:-/tmp/logtap-e2e-locks}" || return 1
  exec 9>"${E2E_LOCK_DIR:-/tmp/logtap-e2e-locks}/lock.$E2E_CT"
  flock -n 9 || {
    echo "e2e-$E2E_TAG: another e2e holds $E2E_CT (a deploy restarts the postmaster — wait for it)" >&2
    exit 1
  }
}


# Container (fd 9) first, shared builder/compose stand (fd 7) second. Parents
# release their phase locks before dispatching child suites; no inherited bypass.
e2e_stand_lock() {
  mkdir -p "${E2E_LOCK_DIR:-/tmp/logtap-e2e-locks}" || return 1
  exec 7>"${E2E_LOCK_DIR:-/tmp/logtap-e2e-locks}/shared.stand"
  flock -w 3600 7 || { echo "timed out waiting for the build/stand lock" >&2; return 1; }
}

e2e_gate() { # the compose stand must be up, freshly deployed, reachable
  [ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' pglogtap-ready 2>/dev/null)" = "exited/0" ] \
    || fail "e2e stand not up: PG_MAJOR=<v> docker compose -f tests/e2e/compose.yaml up -d"
  # A stale .so (copied without a restart) would test yesterday's code.
  "$(dirname "$0")/e2e-require-ext.sh" "$E2E_CT" || fail "freshness check failed for $E2E_CT"
  docker network connect "$NET" "$E2E_CT" >/dev/null 2>&1 || true # non-stand pg arg
  # A run that failed mid-suite may have left the receiver stopped; the next
  # run would fail its first scenario on a dead hostname. Start is a no-op
  # when already running.
  docker start "$VEC" >/dev/null 2>&1 || fail "could not start receiver $VEC"
}

fail() {
  echo "e2e-$E2E_TAG: FAILED: $*" >&2
  # Post-mortem for the log: counters, worker liveness, export transition
  # lines, both containers' state. The server-log grep scans the WHOLE log
  # and only then tails: a burst of the very events being lost once pushed
  # the "export failing (fail_reason)" line past a plain tail -15.
  docker exec "$E2E_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()" >&2
  docker exec "$E2E_CT" psql -U postgres -Atc \
    "SELECT pid || ' ' || backend_type FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'" >&2
  docker logs "$E2E_CT" 2>&1 | grep -iE "logtap.*(failing|recovered|divert|fallback|lost)|PANIC|FATAL" | tail -8 >&2
  docker inspect -f "pg: {{.State.Status}} oom={{.State.OOMKilled}}" "$E2E_CT" >&2
  [ -n "${VEC:-}" ] && docker inspect -f "receiver: {{.State.Status}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}" "$VEC" >&2
  command -v fail_extra >/dev/null 2>&1 && fail_extra # suite-specific extras
  exit 1
}
ok() { echo "  ok: $*"; }

guc_name_valid() {
  case ${1-} in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.]*) return 1 ;;
  esac
}
setguc() { # setguc <name> <value>: psql quotes arbitrary legal string values
  guc_name_valid "$1" || return 2
  docker exec -i "$E2E_CT" psql -X -U postgres -v ON_ERROR_STOP=1 \
    -v "guc=$1" -v "value=$2" >/dev/null <<'SQL'
SELECT format('ALTER SYSTEM SET %s = %L', :'guc', :'value')
\gexec
SQL
}
reload() { docker exec "$E2E_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -qc "SELECT pg_reload_conf()" >/dev/null; }
stats() { docker exec "$E2E_CT" psql -U postgres -Atc "SELECT pg_logtap_stats()"; }
statf() { s=$(stats); v=${s#*"$1"=}; echo "${v%% *}"; }

wait_ready() { # TCP probe: the restarting server's socket comes and goes, and
  # the official image's temporary initdb server answers a plain pg_isready
  # on the unix socket before the real server exists.
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$E2E_CT" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && return 0
    n=$((n + 1)); sleep 1
  done
  fail "postgres in $E2E_CT not ready after 60s"
}
wait_vector() { # until the receiver actually accepts TCP again after the
  # suite itself stopped it (docker start): vector rebinds its port SLOWLY on
  # a loaded host (observed 30 s locally), and generating before that fails
  # every send and burns the wait_for windows.
  n=0
  while [ "$n" -lt 60 ]; do
    docker exec "$E2E_CT" bash -c "exec 3<>/dev/tcp/$VEC/8686" 2>/dev/null && return 0
    n=$((n + 1)); sleep 1
  done
  fail "receiver $VEC not accepting connections after 60s"
}

gen() { # gen <marker> <count> — distinct events from one psql round trip.
  # Markers carry the run's suffix: sink files accumulate across runs, and
  # identical markers would let an old run's lines satisfy this run's
  # asserts. Above the default log_min_messages (so it reaches the hook) and
  # not an error (so the loop is not aborted); a caught RAISE EXCEPTION never
  # reaches the server log at all.
  docker exec "$E2E_CT" psql -U postgres -v ON_ERROR_STOP=1 -qc "DO \$\$ DECLARE i int := 0; BEGIN
    WHILE i < $2 LOOP
      RAISE WARNING 'logtap $E2E_TAG $1$E2E_SUF %', i;
      i := i + 1;
    END LOOP; END \$\$" >/dev/null 2>&1 || {
    echo "  gen $1: psql FAILED (events never emitted)" >&2
    return 1
  }
}
received() { # received <marker> [file] — DISTINCT numbered marker events.
  # The trailing-digit requirement keeps out the duration-log line of the
  # generating DO statement itself (its message quotes the RAISE format
  # string when log_min_duration_statement is on).
  grep -oE "logtap $E2E_TAG $1$E2E_SUF [0-9]+" "${2:-$OUT/vector-out.jsonl}" 2>/dev/null | sort -u | wc -l
}
seqs_of() { grep -E "logtap $E2E_TAG $1$E2E_SUF [0-9]+" "${2:-$OUT/vector-out.jsonl}" | grep -o '"seq":[0-9]*' | cut -d: -f2; }
duplicate_seqs() {
  grep -E "logtap $E2E_TAG [^ ]*$E2E_SUF " "$OUT/vector-out.jsonl" | grep -o '"seq":[0-9]*' | sort | uniq -d | wc -l
}
wait_for() { # wait_for <marker> <count> [file] [tries] — FAILS on timeout
  n=0; tries=${4:-15}
  while [ "$n" -lt "$tries" ]; do
    [ "$(received "$1" "${3:-}")" -ge "$2" ] && return 0
    n=$((n + 1)); sleep 1
  done
  # POSIX while returns the last body command (sleep = 0): falling through
  # here silently once green-lit suites on follow-up asserts or on nothing.
  fail "wait_for $1: received $(received "$1" "${3:-}") of $2 in ${tries}s"
}
worker_pid() { docker exec "$E2E_CT" psql -U postgres -Atc \
  "SELECT pid FROM pg_stat_activity WHERE backend_type LIKE '%logtap%' LIMIT 1"; }
vmrss_kb() { # resident set of the worker inside the container
  docker exec "$E2E_CT" cat "/proc/$(worker_pid)/status" 2>/dev/null | awk '/^VmRSS/{print $2}'
}
drain_ring() { # markers emitted into a full ring are dropped at emit (counted
  # in events_dropped, never delivered)
  n=0
  while [ "$n" -lt 60 ]; do
    [ "$(statf ring_events)" = 0 ] && return 0
    n=$((n + 1)); sleep 1
  done
  fail "ring never drained (ring_events=$(statf ring_events))"
}
# Read epoch, configured path (hex avoids filename delimiters), queue size,
# unique exporter identity and counters together. Missing files size 0.
# Exporter replacement invalidates proof even if the postmaster survives recovery.
e2e_export_snapshot() {
  export_row=$(docker exec "$E2E_CT" psql -X -U postgres -v ON_ERROR_STOP=1 -Atc "SELECT extract(epoch FROM pg_postmaster_start_time())::text || ' ' ||
encode(convert_to(current_setting('pg_logtap.export_fallback_file'), 'UTF8'), 'hex') || ' ' ||
CASE WHEN current_setting('pg_logtap.export_fallback_file') = '' THEN '0'
ELSE coalesce((pg_stat_file(current_setting('pg_logtap.export_fallback_file'), true)).size, 0)::text END
|| ' ' || coalesce((SELECT CASE WHEN count(*) = 1 THEN min(pid)::text || ' ' ||
extract(epoch FROM min(backend_start))::text END
FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'), '0 0')
|| ' ' || pg_logtap_stats()") || return 1
  export_epoch=${export_row%% *}; export_row=${export_row#* }
  export_path=${export_row%% *}; export_row=${export_row#* }
  export_bytes=${export_row%% *}; export_row=${export_row#* }
  export_pid=${export_row%% *}; export_row=${export_row#* }
  export_started=${export_row%% *}; export_row=${export_row#* }
  case "$export_epoch" in ''|*[!0-9.]*) echo "invalid export drain epoch" >&2; return 1 ;; esac
  case "$export_path" in *[!0-9a-f]*) echo "invalid export drain path" >&2; return 1 ;; esac
  case "$export_pid" in ''|*[!0-9]*) echo "invalid export drain exporter PID" >&2; return 1 ;; esac
  case "$export_started" in ''|*[!0-9.]*) echo "invalid export drain exporter start" >&2; return 1 ;; esac
  [ "$export_pid" -gt 0 ] || { echo "export drain requires exactly one exporter with PID/backend_start" >&2; return 1; }
  export_key="$E2E_CT/$export_epoch/$export_path/$export_pid/$export_started"
  export_cap=${export_row#*events_captured=}; export_cap=${export_cap%% *}
  export_sent=${export_row#*events_sent=}; export_sent=${export_sent%% *}
  export_queued=${export_row#*events_queued=}; export_queued=${export_queued%% *}
  export_replayed=${export_row#*events_replayed=}; export_replayed=${export_replayed%% *}
  export_compacted=${export_row#*events_compacted=}; export_compacted=${export_compacted%% *}
  export_lost=${export_row#*events_lost=}; export_lost=${export_lost%% *}
  export_ring=${export_row#*ring_events=}; export_ring=${export_ring%% *}
  export_broken=${export_row#*fallback_broken=}; export_broken=${export_broken%% *}
  for value in "$export_bytes" "$export_cap" "$export_sent" "$export_queued" "$export_replayed" "$export_compacted" "$export_lost" "$export_ring" "$export_broken"; do
    case "$value" in ''|*[!0-9]*) echo "invalid export drain counters" >&2; return 1 ;; esac
  done
}

# Arm in the parent after its existing full restart/setup, BEFORE any warmup;
# retain across modes, never re-arm after replay merely to accept its totals.
# ponytail: owned fresh stand, no external queue/config writers. Arbitrary history
# needs a production RAM/inflight observable, not a guessed cumulative formula.
e2e_export_begin() {
  unset E2E_EXPORT_EPOCH
  e2e_export_snapshot || return 1
  if [ "$export_queued" != 0 ] || [ "$export_replayed" != 0 ] || [ "$export_compacted" != 0 ] || [ "$export_bytes" != 0 ] || [ "$export_broken" != 0 ]; then
    echo "export drain requires a zero-history epoch: fallback queue must be absent/empty, uncredited and healthy" >&2
    return 1
  fi
  [ "$export_ring" = 0 ] && [ "$export_cap" -eq "$((export_sent + export_lost))" ] || {
    echo "export drain requires settled captures before arming the zero-history epoch" >&2; return 1;
  }
  E2E_EXPORT_EPOCH=$export_key
}

# With proved zero history, each capture settles by live send, replay OR loss.
# Compaction/discard are already included in lost; ring zero alone misses RAM.
e2e_drain_export() (
  [ -n "${E2E_EXPORT_EPOCH:-}" ] || { echo "export drain has no proven zero-history epoch (arm before warmup)" >&2; return 1; }
  n=0
  while [ "$n" -lt 60 ]; do
    e2e_export_snapshot || return 1
    [ "$E2E_EXPORT_EPOCH" = "$export_key" ] || { echo "export drain epoch/container/fallback path/exporter changed or provenance is unknown" >&2; return 1; }
    [ "$export_queued" -le "$export_cap" ] && [ "$((export_sent + export_replayed + export_lost))" -le "$export_cap" ] || {
      echo "export drain zero-history accounting violated" >&2; return 1;
    }
    [ "$export_ring" = 0 ] && [ "$export_cap" -eq "$((export_sent + export_replayed + export_lost))" ] && return 0
    n=$((n + 1)); sleep 1
  done
  echo "export drain did not settle after 60s" >&2; return 1
)

# Sample only while the measured client lives. A slow final docker-stats call
# is discarded, and TERM reaps that call (or sleep), not just its shell wrapper.
e2e_sample_cpu() { # called in the background; no extra subshell between PID and trap
  work=$1 file=$2 child=
  trap '[ -z "$child" ] || { kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; }; rm -f "$file.sample"' EXIT
  trap 'exit 0' INT TERM
  : > "$file"
  while kill -0 "$work" 2>/dev/null; do
    docker stats --no-stream --format '{{.CPUPerc}}' "$E2E_CT" > "$file.sample" &
    child=$!
    wait "$child" || true
    child=
    kill -0 "$work" 2>/dev/null || break
    cat "$file.sample" >> "$file"
    sleep 1 &
    child=$!
    wait "$child" || true
    child=
  done
}

json_check() { # json_check <marker> [file]: prints the checked line count —
  # every delivered marker line must parse as JSON (a torn slot or a botched
  # sanitization would surface as invalid JSON or broken UTF-8)
  python3 - "${2:-$OUT/vector-out.jsonl}" "logtap $E2E_TAG $1$E2E_SUF" <<'EOF'
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
