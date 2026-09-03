#!/usr/bin/env bash
# Version-matrix acceptance: for each requested PG major — build from its
# vendored headers, deploy into the compose stand, run the e2e + a log storm,
# assert zero drops and exact delivery to Vector.
# Usage: scripts/test-matrix.sh [storm_secs] [version ...]   (default: all vendored)
# PHASES=storm,kill scripts/test-matrix.sh [secs] [version ...] runs a subset
# of the pipeline (comma list, order as below) against a stand the full run
# brought up — for load-shaped local research. Default: every phase except
# bench (opt-in: PHASES=stand,bench runs the overhead benchmark locally).
set -euo pipefail
cd "$(dirname "$0")/.."
SECS=${1:-5}; shift || true
if [ $# -gt 0 ]; then VERSIONS="$*"; else VERSIONS="15 16 17 18"; fi
PHASES=${PHASES:-stand,cluster-ops,e2e,vlogs,storm,kill,silent,slow,faults,robust,hook-chain,metrics,wide}
COMPOSE="docker compose -f tests/e2e/compose.yaml"
OUT=/tmp/logtap-e2e
mkdir -p "$OUT"
STATUS=0

has_phase() { case ",$PHASES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Down on success only — a failed job keeps its containers for post-mortem
# (the STATUS=1 paths below), as the pre-compose matrix did.
# shellcheck disable=SC2329 # invoked via the EXIT trap below
cleanup() { [ "$STATUS" = 0 ] && $COMPOSE down >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Readiness via the container healthcheck: wait for State.Health=healthy.
# The probe is TCP (127.0.0.1) on purpose — the official image's temporary
# initdb server listens on the unix socket only and would answer a plain
# pg_isready, flipping the container healthy before the real server exists
# (random CI failure: next psql hits a dead socket).
wait_ready() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = healthy ] && return 0
    sleep 1
  done
  echo "pg in $1 not ready after 60s" >&2; return 1
}

# Release artifacts are built against the oldest glibc among current distros
# (2.28 = RHEL 8, amd64 and arm64 alike; glibc is forward-compatible) and
# with ReleaseSafe, so the storm below tests exactly the binary that ships.
# The target follows the runner's arch — CI builds natively on both.
case "$(uname -m)" in
  x86_64)  ZIG_TARGET="x86_64-linux-gnu.2.28" ;;
  aarch64) ZIG_TARGET="aarch64-linux-gnu.2.28" ;;
  *) echo "unsupported runner arch: $(uname -m)" >&2; exit 1 ;;
esac
FLAGS=(-Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe)

# --- phases -------------------------------------------------------------------

phase_stand() { # <v>: build, compose stand, deploy + install the extension
  local v=$1
  # per-major name: failed jobs stay distinguishable and post-mortem-able,
  # as the matrix always was
  local C=pglogtap-mx$v
  if command -v pg_config >/dev/null 2>&1; then
    zig build "${FLAGS[@]}" -p "dist/pg$v"   # CI: server-dev for $v is installed
  else
    scripts/build.sh "$v" "${FLAGS[@]}" && mkdir -p "dist/pg$v/lib" && \
      cp zig-out/lib/pg_logtap.so "dist/pg$v/lib/"   # local: build in pgzx-build
  fi

  # Bring up (or, on an image change, recreate) the stand's pg under the
  # per-major name. pg comes up FIRST AND ALONE: a failed `up` of the whole
  # stand rolls back every recreated container (compose's dependency
  # teardown), and the pg boot log dies with it — with nothing depending on
  # a lone pg, a boot crash leaves the container for the post-mortem dump.
  # -v: the anon data volume follows the compose project, not the major —
  # without it a full local run hands pg16 a data dir initdb'd by pg15
  # ("database files are incompatible with server") and the stand never boots.
  # The project's pg service may currently live under ANOTHER major's name
  # (the run just finished pg16, pg17 starts): compose tracks containers by
  # project+service labels and would recreate THAT one into this major's
  # name, carrying its anon data volume over (observed: pg17 booting a
  # pg16 data dir). Remove the service container by label, not just by
  # this major's name — then `up` always creates fresh, with a fresh volume.
  docker ps -aq --filter "label=com.docker.compose.project=pglogtap-e2e" \
    --filter "label=com.docker.compose.service=pg" \
    | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  docker rm -f -v "$C" >/dev/null 2>&1 || true # stale same-name container
  if ! PG_MAJOR=$v PG_CT=$C $COMPOSE up -d --no-deps pg >/dev/null; then
    echo "pg$v: compose could not start pg" >&2
    docker logs "$C" >&2 || true
    return 1
  fi
  if ! wait_ready "$C"; then
    docker logs --tail 40 "$C" >&2 || true # boot crash post-mortem
    return 1
  fi
  # The rest of the stand: vector/vlogs/silent plus the one-shot ready gate,
  # which re-runs against THIS pg (exit 0 is e2e-kill's stand contract).
  # Same env as above — a drifted pg config makes compose recreate (and,
  # on boot failure, roll back) the container this run just built.
  PG_MAJOR=$v PG_CT=$C $COMPOSE up -d >/dev/null
  if ! wait_ready "$C"; then
    docker logs --tail 40 "$C" >&2 || true
    return 1
  fi

  LIBDIR=$(docker exec "$C" pg_config --pkglibdir)
  EXTDIR=$(docker exec "$C" pg_config --sharedir)/extension
  docker cp "dist/pg$v/lib/pg_logtap.so" "$C:$LIBDIR/"
  docker cp pg_logtap.control "$C:$EXTDIR/"
  for f in sql/*.sql; do docker cp "$f" "$C:$EXTDIR/"; done

  # Phase 1: core GUCs only — PG<=16 rejects ALTER SYSTEM on unregistered
  # custom GUCs, so the library must load first.
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'" \
    -qc "ALTER SYSTEM SET cluster_name = 'matrix-pg$v'" >/dev/null
  docker restart "$C" >/dev/null; wait_ready "$C"
  # Phase 2: pg_logtap.* GUCs are registered now; ring_capacity is POSTMASTER.
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.ring_capacity = 8192" \
    -qc "ALTER SYSTEM SET pg_logtap.flush_interval = 100" >/dev/null
  docker restart "$C" >/dev/null; wait_ready "$C"
  docker exec "$C" psql -U postgres -qc "CREATE EXTENSION pg_logtap" >/dev/null
}

phase_cluster_ops() { # <v>: ops that interact with other backends — the
  # exporter connects to the cluster, so it participates in
  # barrier/connection/catalog signaling. Each under timeout: pre-0.2.1 the
  # worker never absorbed ProcSignalBarriers and DROP DATABASE hung forever
  # (worker idle the whole time).
  local v=$1
  local C=pglogtap-mx$v
  docker exec "$C" bash -c "
      set -e
      timeout 30 createdb -U postgres probe
      timeout 30 createdb -U postgres -T template0 probe2
      timeout 30 dropdb -U postgres probe
      timeout 30 dropdb -U postgres probe2
      timeout 30 psql -U postgres -qc 'CREATE ROLE probe_r; DROP ROLE probe_r'
      timeout 30 psql -U postgres -qc 'CHECKPOINT'
  "
}

phase_e2e() { # <v>: N distinct events must reach Vector (file sink).
  scripts/e2e-vector.sh "pglogtap-mx$1" 20
}

phase_vlogs() { # <v>: prod-shaped chain Vector → VictoriaLogs, exact count.
  scripts/e2e-vlogs.sh "pglogtap-mx$1" 50
}

phase_storm() { # <v> <secs>: log storm at debug volume; assert dropped=0 and
  # exact delivery. vector-out.jsonl accumulates across suites and versions —
  # count from a baseline, not from zero.
  local v=$1
  local secs=$2
  local C=pglogtap-mx$v
  local base_lines=0
  [ -f "$OUT/vector-out.jsonl" ] && base_lines=$(wc -l < "$OUT/vector-out.jsonl")
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector:8686'" \
    -qc "ALTER SYSTEM SET log_min_duration_statement = 0" \
    -qc "ALTER SYSTEM SET log_min_messages = 'debug1'" \
    -qc "ALTER SYSTEM SET pg_logtap.level_min = 10" -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 2
  # Counters are cumulative since start: baseline now, compare deltas after.
  local base bcap bdrp bexp
  base=$(docker exec "$C" psql -U postgres -Atc "SELECT pg_logtap_stats()")
  bcap=${base#*events_captured=}; bcap=${bcap%% *}
  bdrp=${base#*events_dropped=}; bdrp=${bdrp%% *}
  bexp=${base#*events_sent=}; bexp=${bexp%% *}
  docker exec "$C" bash -c "pgbench -i -q -U postgres postgres >/dev/null 2>&1; \
    pgbench -U postgres -c 8 -j 2 -T $secs postgres 2>&1 | grep tps" | sed "s/^/  /"
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_min_duration_statement = -1" \
    -qc "ALTER SYSTEM SET log_min_messages = 'warning'" \
    -qc "ALTER SYSTEM SET pg_logtap.level_min = 15" -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 3 # let the worker drain and Vector flush its batch

  local stats cap drp exp lines=0
  stats=$(docker exec "$C" psql -U postgres -Atc "SELECT pg_logtap_stats()")
  echo "  $stats"
  cap=${stats#*events_captured=}; cap=${cap%% *}; cap=$((cap - bcap))
  drp=${stats#*events_dropped=}; drp=${drp%% *}; drp=$((drp - bdrp))
  exp=${stats#*events_sent=}; exp=${exp%% *}; exp=$((exp - bexp))
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$OUT/vector-out.jsonl" ] && lines=$(wc -l < "$OUT/vector-out.jsonl")
    lines=$((lines - base_lines))
    [ "$lines" -ge "$cap" ] && break
    sleep 1
  done
  echo "  vector_received=$lines"
  [ "$drp" = 0 ] && [ "$cap" = "$exp" ] && [ "$lines" -ge "$cap" ]
}

phase_kill() { # <v>: failure modes — receiver down→up, SIGKILL postmaster,
  # fallback file, worker kill: the docs/delivery.md contract.
  scripts/e2e-kill.sh "pglogtap-mx$1"
}

phase_silent() { # <v>: mute-but-accepting receiver: sends must fail after
  # export_timeout_ms, batches divert to the fallback file, /healthz answers.
  scripts/e2e-silent-receiver.sh "pglogtap-mx$1"
}

phase_slow() { # <v>: slow-but-answering receiver: export_slow_ms parks live
  # batches on the fallback file (lossless), drains once it answers fast.
  scripts/e2e-slow-receiver.sh "pglogtap-mx$1"
}

phase_faults() { # <v>: fault injection — a throwaway postgres under an
  # LD_PRELOAD shim that fails fdatasync for one named file: rollback-and-
  # retry on a file:// sink, keep-but-count on the fallback queue, and
  # /dev/full write failure. Owns its own container; the stand is untouched.
  scripts/e2e-faults.sh "$1"
}

phase_robust() { # <v>: robustness classes beyond the happy path — fields past
  # their ring slots, a logging backend SIGKILLed mid-emit (the PANIC/
  # emergency-restart path), and the RAM backlog's memory bound under a
  # receiver-dead storm.
  scripts/e2e-robust.sh "pglogtap-mx$1"
}

phase_hook_chain() { # <v>: another emit_log_hook extension preloaded first:
  # pg_logtap must chain to it, not replace it.
  scripts/e2e-hook-chain.sh "pglogtap-mx$1"
}

phase_metrics() { # <v>: worker serves /metrics, Vector prometheus_scrape
  # reads it. Opens metrics_addr to the stand network.
  scripts/e2e-metrics.sh "pglogtap-mx$1"
}

phase_wide() { # <v>: pg_logtap.message_max=8192 (POSTMASTER): whole messages
  # past the 1024B default, char-boundary cut past the configured width, aux
  # fields still 256B. Last on purpose: it ALTER SYSTEMs + restarts the pg
  # container, so every earlier phase must have passed on the default config.
  scripts/e2e-wide.sh "pglogtap-mx$1"
}

phase_bench() { # <v> <secs>: formal overhead benchmark (docs/bench.md) —
  # pgbench before/after the extension, TPS/CPU/events/s/latency report. Not
  # in the default PHASES: benchmark numbers from shared CI runners are
  # garbage; run locally on a performance-governor box.
  scripts/bench-overhead.sh "$2" "pglogtap-mx$1"
}

for v in $VERSIONS; do
  echo "===== pg$v ====="
  ok=1
  if has_phase stand; then phase_stand "$v" || { echo "pg$v: stand FAILED"; STATUS=1; ok=0; }; fi
  if [ "$ok" = 1 ] && has_phase cluster-ops; then
    phase_cluster_ops "$v" || { echo "pg$v: cluster-ops (barrier/signal classes) FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase e2e; then
    phase_e2e "$v" || { echo "pg$v: e2e FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase vlogs; then
    phase_vlogs "$v" || { echo "pg$v: vlogs-chain FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase storm; then
    phase_storm "$v" "$SECS" || { echo "pg$v: FAILED (storm drops/count mismatch)"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase kill; then
    phase_kill "$v" || { echo "pg$v: kill-scenarios FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase silent; then
    phase_silent "$v" || { echo "pg$v: silent-receiver FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase slow; then
    phase_slow "$v" || { echo "pg$v: slow-receiver FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase faults; then
    phase_faults "$v" || { echo "pg$v: faults FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase robust; then
    phase_robust "$v" || { echo "pg$v: robust FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase hook-chain; then
    phase_hook_chain "$v" || { echo "pg$v: hook-chain FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase metrics; then
    phase_metrics "$v" || { echo "pg$v: metrics FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase wide; then
    phase_wide "$v" || { echo "pg$v: wide FAILED"; STATUS=1; ok=0; }
  fi
  if [ "$ok" = 1 ] && has_phase bench; then
    phase_bench "$v" "$SECS" || { echo "pg$v: bench FAILED"; STATUS=1; ok=0; }
  fi
  [ "$ok" = 1 ] && echo "  pg$v: OK"
  # Failed jobs keep the container for post-mortem; success cleans up.
  [ "$ok" = 1 ] && docker rm -f "pglogtap-mx$v" >/dev/null 2>&1 || true
done

exit $STATUS
