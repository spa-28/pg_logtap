#!/usr/bin/env bash
# In-place dev deploy: build for the discovered container major, copy and restart.
# Usage: scripts/dev-deploy.sh [container]   (default: pglogtap-pg)
# Requires pg_logtap already preloaded and its SQL function installed; this is
# a binary verifier, not fresh bootstrap or an implicit ALTER EXTENSION UPDATE.
# Preserves preload configuration. Stopped official Debian containers work too.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tests/e2e/e2e-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../tests/e2e/e2e-common.sh"

main() {
set -euo pipefail
cd "$(dirname "$0")/.."
C=${1:-pglogtap-pg}
E2E_CT=$C E2E_TAG=deploy
e2e_lock
e2e_stand_lock
if docker exec "$C" true 2>/dev/null; then
    V=$(docker exec "$C" pg_config --version | sed -n 's/^PostgreSQL \([0-9][0-9]*\)\..*/\1/p')
    LIBDIR=$(docker exec "$C" pg_config --pkglibdir)
    EXTDIR=$(docker exec "$C" pg_config --sharedir)/extension
else
    # Official postgres images keep PG_MAJOR in Config.Env even when stopped.
    V=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C" | sed -n 's/^PG_MAJOR=\([0-9][0-9]*\)$/\1/p')
    LIBDIR=/usr/lib/postgresql/$V/lib
    EXTDIR=/usr/share/postgresql/$V/extension
fi
case "$V" in 15|16|17|18) ;; *) echo "cannot determine supported PostgreSQL major for $C" >&2; return 1 ;; esac

# ReleaseSafe: a Debug build's gzip/JSON is several times slower and the
# e2e timing asserts (parking keeping up with a storm, dns gauges) flap on it.
if HOST_CONFIG=$(e2e_pg_config "$V"); then
    PG_CONFIG="$HOST_CONFIG" zig build -Doptimize=ReleaseSafe
else
    scripts/build.sh "$V" -Doptimize=ReleaseSafe
fi || return 1
docker cp zig-out/lib/pg_logtap.so "$C:$LIBDIR/"
docker cp pg_logtap.control "$C:$EXTDIR/"
for f in sql/*.sql; do docker cp "$f" "$C:$EXTDIR/"; done

# The postmaster keeps the .so it was started with — a copied-over library
# changes nothing until restart. Restart (or start) and prove the load.
docker restart "$C" >/dev/null
"$(dirname "$0")/../tests/e2e/e2e-require-ext.sh" "$C"

echo "deployed to $C ($LIBDIR), server restarted on the new .so"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
