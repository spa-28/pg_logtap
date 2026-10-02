#!/usr/bin/env bash
set -euo pipefail
[ "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.28' ]
case "$(pg_config --version)" in "PostgreSQL $PG_MAJOR."*) ;; *) exit 1 ;; esac
WORK=/tmp/pglogtap-archive-runtime
if [ "${1:-}" != --run ]; then
  [ "$(id -u)" = 0 ]
  python3 /smoke/archive-smoke.py "$1" "$2" "$3" "$4" /tmp/archive-extracted
  install -m 755 /tmp/archive-extracted/lib/pg_logtap.so "$(pg_config --pkglibdir)/pg_logtap.so"
  install -m 644 /tmp/archive-extracted/extension/* "$(pg_config --sharedir)/extension/"
  install -d -m 700 -o postgres -g postgres "$WORK"
  exec runuser -u postgres -- bash /smoke/smoke.sh --run "$4"
fi
[ "$(id -u)" != 0 ]
VERSION=$2
initdb -D "$WORK/data" --auth=trust --no-locale --encoding=UTF8 >/dev/null
install -m 600 /dev/null "$WORK/export.jsonl"
cat >> "$WORK/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$WORK'
shared_preload_libraries = 'pg_logtap'
log_destination = ''
log_min_messages = 'log'
pg_logtap.level_min = 15
pg_logtap.flush_interval = 100
pg_logtap.export_url = 'file://$WORK/export.jsonl'
EOF
# shellcheck disable=SC2329 # EXIT trap
cleanup() { pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
if ! pg_ctl -D "$WORK/data" -l "$WORK/server.log" -w start; then
  cat "$WORK/server.log" >&2
  exit 1
fi
PSQL=(psql -X -v ON_ERROR_STOP=1 -h "$WORK" -d template1)
"${PSQL[@]}" -c 'CREATE EXTENSION pg_logtap'
[ "$("${PSQL[@]}" -Atc 'SELECT pg_logtap_version()')" = "$VERSION" ]
[ "$("${PSQL[@]}" -Atc "SELECT extversion FROM pg_extension WHERE extname = 'pg_logtap'")" = "$VERSION" ]
MARKER=archive_smoke_$(cat /proc/sys/kernel/random/uuid)
"${PSQL[@]}" -c "DO \$\$ BEGIN RAISE LOG '$MARKER'; END \$\$"
for _ in $(seq 1 100); do
  if grep -Fq "$MARKER" "$WORK/export.jsonl"; then
    [ "$(stat -c '%a:%u:%h' "$WORK/export.jsonl")" = "600:$(id -u):1" ]
    printf 'actual %s, PG %s, template1 version %s, private file marker delivered: OK\n' \
      "$(getconf GNU_LIBC_VERSION)" "$(pg_config --version)" "$VERSION"
    exit 0
  fi
  sleep 0.1
done
cat "$WORK/server.log" >&2
printf 'archive runtime marker was not exported\n' >&2
exit 1
