#!/bin/sh
# Metrics acceptance pilot: keep the common gate/lock, run one native pytest case.
# Usage: tests/e2e/e2e-metrics.sh [pg_container] [port]
set -u
local_error() { printf 'e2e-metrics: %s\n' "$1" >&2; exit 2; }
[ "$#" -le 2 ] || local_error 'usage: e2e-metrics.sh [pg_container] [port]'
command -v uv >/dev/null 2>&1 || local_error 'uv is required'
CT=${1-}
if [ "$#" -ge 1 ]; then
  case "$CT" in
    ''|[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
      local_error 'invalid container name' ;;
  esac
fi
PORT=${2-9187}
case "$PORT" in ''|*[!0123456789]*) local_error 'port must be ASCII decimal in 1..65535' ;; esac
while [ "${PORT#0}" != "$PORT" ]; do PORT=${PORT#0}; done
PORT=${PORT:-0}
[ "${#PORT}" -le 5 ] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] \
  || local_error 'port must be ASCII decimal in 1..65535'
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 2
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tests/e2e/e2e-common.sh
. "$SCRIPT_DIR/e2e-common.sh"
e2e_init metrics "$CT"
e2e_gate
# The gate resolves its sibling freshness checker using the original $0/CWD.
cd "$SCRIPT_DIR/../.." || exit 2
REPO=$(pwd)
child_pid=
# shellcheck disable=SC2329 # invoked by the three signal traps
forward_signal() {
  trap '' HUP INT TERM
  if [ -n "$child_pid" ]; then
    kill -s "$1" "$child_pid" 2>/dev/null || :
    wait "$child_pid"
    child_status=$?
    child_pid=
    exit "$child_status"
  fi
  exit 1
}
trap 'forward_signal HUP' HUP
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
PG_LOGTAP_METRICS_BOOTSTRAPPED=1 PG_LOGTAP_METRICS_CT="$PG_CT" \
PG_LOGTAP_METRICS_VEC="$VEC" PG_LOGTAP_METRICS_NET="$NET" \
PG_LOGTAP_METRICS_SUFFIX="$SUF" PG_LOGTAP_METRICS_PORT="$PORT" \
  uv run --project "$REPO/tests" --locked --only-group test \
    python -m pytest "$REPO/tests/e2e/test_metrics.py" &
child_pid=$!
wait "$child_pid"
status=$?
child_pid=
trap - HUP INT TERM
# Diagnostics must not replace pytest collection/internal/error exit statuses.
[ "$status" -eq 0 ] || (fail "pytest exited with status $status")
exit "$status"
