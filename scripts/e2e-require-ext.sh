#!/bin/sh
# Fail fast when the pg container runs a stale pg_logtap: the postmaster keeps
# the .so it was started with, so a dev-deploy without a restart silently
# tests yesterday's code. Usage: scripts/e2e-require-ext.sh <pg_container>
set -eu
CT="${1:?pg container name required}"

# wait for the server, then for the extension's SQL surface
i=0
until docker exec "$CT" psql -U postgres -Atc "SELECT 1" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 30 ] || { echo "e2e-require-ext: $CT never accepted connections" >&2; exit 1; }
    sleep 1
done

want=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' "$(dirname "$0")/../src/version.zig")
got=$(docker exec "$CT" psql -U postgres -Atc "SELECT pg_logtap_version()" 2>/dev/null || true)
[ "$got" = "$want" ] || {
    echo "e2e-require-ext: $CT has pg_logtap $got loaded, the tree builds $want." >&2
    echo "  The postmaster keeps the .so it started with: scripts/dev-deploy.sh, then restart the container." >&2
    exit 1
}
