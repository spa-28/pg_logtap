#!/usr/bin/env bash
# Version-matrix acceptance: for each requested PG major — build from its
# vendored headers, deploy into the compose stand, run the e2e + a log storm,
# assert zero drops and exact delivery to Vector.
# Usage: scripts/test-matrix.sh [storm_secs] [version ...]   (default: all vendored)
set -euo pipefail
cd "$(dirname "$0")/.."
SECS=${1:-5}; shift || true
if [ $# -gt 0 ]; then VERSIONS="$*"; else VERSIONS="15 16 17 18"; fi
COMPOSE="docker compose -f tests/e2e/compose.yaml"
OUT=/tmp/logtap-e2e
mkdir -p "$OUT"
STATUS=0

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

for v in $VERSIONS; do
  echo "===== pg$v ====="
  C=pglogtap-mx$v # per-major container name: failed jobs stay distinguishable
                  # and post-mortem-able, as the matrix always was
  if command -v pg_config >/dev/null 2>&1; then
    zig build "${FLAGS[@]}" -p "dist/pg$v"   # CI: server-dev for $v is installed
  else
    scripts/build.sh "$v" "${FLAGS[@]}" && mkdir -p "dist/pg$v/lib" && \
      cp zig-out/lib/pg_logtap.so "dist/pg$v/lib/"   # local: build in pgzx-build
  fi

  # Bring up (or, on an image change, recreate) the stand's pg under the
  # per-major name. On a fresh stand the depends_on chain in compose.yaml
  # gates `up` itself on pg-healthy + vector-port-accepting; on a recreate
  # (ready already exited 0) the health wait below covers the new pg.
  docker rm -f "$C" >/dev/null 2>&1 || true # stale same-name container
  PG_MAJOR=$v PG_CT=$C $COMPOSE up -d
  wait_ready "$C"
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

  # Cluster ops that interact with other backends — the exporter connects to
  # the cluster, so it participates in barrier/connection/catalog signaling.
  # Each under timeout: pre-0.2.1 the worker never absorbed ProcSignalBarriers
  # and DROP DATABASE hung forever (worker idle the whole time).
  if ! docker exec "$C" bash -c "
      set -e
      timeout 30 createdb -U postgres probe
      timeout 30 createdb -U postgres -T template0 probe2
      timeout 30 dropdb -U postgres probe
      timeout 30 dropdb -U postgres probe2
      timeout 30 psql -U postgres -qc 'CREATE ROLE probe_r; DROP ROLE probe_r'
      timeout 30 psql -U postgres -qc 'CHECKPOINT'
  "; then
    echo "pg$v: cluster-ops (barrier/signal classes) FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue
  fi

  # Functional: N distinct events must reach Vector (file sink).
  if ! scripts/e2e-vector.sh "$C" 20; then
    echo "pg$v: e2e FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue
  fi

  # Prod-shaped chain: Vector → VictoriaLogs jsonline insert, exact count.
  if ! scripts/e2e-vlogs.sh "$C" 50; then
    echo "pg$v: vlogs-chain FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue
  fi

  # Storm: duration-logging on, stand vector, assert dropped=0 and exact
  # delivery. vector-out.jsonl accumulates across suites and versions —
  # count from a baseline, not from zero.
  base_lines=0
  [ -f "$OUT/vector-out.jsonl" ] && base_lines=$(wc -l < "$OUT/vector-out.jsonl")
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector:8686'" \
    -qc "ALTER SYSTEM SET log_min_duration_statement = 0" \
    -qc "ALTER SYSTEM SET log_min_messages = 'debug1'" \
    -qc "ALTER SYSTEM SET pg_logtap.level_min = 10" -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 2
  # Counters are cumulative since start: baseline now, compare deltas after.
  base=$(docker exec "$C" psql -U postgres -Atc "SELECT pg_logtap_stats()")
  bcap=${base#*events_captured=}; bcap=${bcap%% *}
  bdrp=${base#*events_dropped=}; bdrp=${bdrp%% *}
  bexp=${base#*events_sent=}; bexp=${bexp%% *}
  docker exec "$C" bash -c "pgbench -i -q -U postgres postgres >/dev/null 2>&1; \
    pgbench -U postgres -c 8 -j 2 -T $SECS postgres 2>&1 | grep tps" | sed "s/^/  /"
  docker exec "$C" psql -U postgres -qc "ALTER SYSTEM SET log_min_duration_statement = -1" \
    -qc "ALTER SYSTEM SET log_min_messages = 'warning'" \
    -qc "ALTER SYSTEM SET pg_logtap.level_min = 15" -qc "SELECT pg_reload_conf()" >/dev/null
  sleep 3 # let the worker drain and Vector flush its batch

  stats=$(docker exec "$C" psql -U postgres -Atc "SELECT pg_logtap_stats()")
  echo "  $stats"
  cap=${stats#*events_captured=}; cap=${cap%% *}; cap=$((cap - bcap))
  drp=${stats#*events_dropped=}; drp=${drp%% *}; drp=$((drp - bdrp))
  exp=${stats#*events_sent=}; exp=${exp%% *}; exp=$((exp - bexp))
  lines=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$OUT/vector-out.jsonl" ] && lines=$(wc -l < "$OUT/vector-out.jsonl")
    lines=$((lines - base_lines))
    [ "$lines" -ge "$cap" ] && break
    sleep 1
  done
  echo "  vector_received=$lines"
  if [ "$drp" = 0 ] && [ "$cap" = "$exp" ] && [ "$lines" -ge "$cap" ]; then
    # Failure modes: receiver down→up, SIGKILL postmaster, fallback file,
    # worker kill — the docs/delivery.md contract (restarts the container).
    scripts/e2e-kill.sh "$C" || { echo "pg$v: kill-scenarios FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue; }
    # Mute-but-accepting receiver: sends must fail after export_timeout_ms,
    # batches divert to the fallback file, /healthz keeps answering.
    scripts/e2e-silent-receiver.sh "$C" || { echo "pg$v: silent-receiver FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue; }
    # Slow-but-answering receiver: export_slow_ms parks live batches on the
    # fallback file (lossless), the queue drains once it answers fast.
    scripts/e2e-slow-receiver.sh "$C" || { echo "pg$v: slow-receiver FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue; }
    # Another emit_log_hook extension preloaded first: pg_logtap must chain
    # to it, not replace it (restores the container's preload afterwards).
    scripts/e2e-hook-chain.sh "$C" || { echo "pg$v: hook-chain FAILED"; STATUS=1; docker rm -f "$C" >/dev/null; continue; }
    echo "  pg$v: OK"; docker rm -f "$C" >/dev/null
  else
    echo "  pg$v: FAILED (dropped=$drp captured=$cap sent=$exp received=$lines)"
    STATUS=1 # keep the container for post-mortem
  fi
done

exit $STATUS
