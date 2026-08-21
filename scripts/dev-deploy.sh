#!/usr/bin/env bash
# Dev loop: rebuild and push the extension into the pglogtap-pg docker container.
# Usage: scripts/dev-deploy.sh [container]   (default: pglogtap-pg)
# Works for a stopped/created container too (Debian postgres image layout).
set -euo pipefail
cd "$(dirname "$0")/.."

C=${1:-pglogtap-pg}
if docker exec "$C" true 2>/dev/null; then
    LIBDIR=$(docker exec "$C" pg_config --pkglibdir)
    EXTDIR=$(docker exec "$C" pg_config --sharedir)/extension
else
    LIBDIR=/usr/lib/postgresql/18/lib
    EXTDIR=/usr/share/postgresql/18/extension
fi

scripts/build.sh 18
docker cp zig-out/lib/pg_logtap.so "$C:$LIBDIR/"
docker cp pg_logtap.control "$C:$EXTDIR/"
docker cp sql/pg_logtap--*.sql "$C:$EXTDIR/"

echo "deployed to $C ($LIBDIR)"
