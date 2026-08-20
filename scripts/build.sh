#!/usr/bin/env bash
# Build the extension inside the pgzx-build container (zig 0.16 + PGDG
# server-dev 15..18 + libpq). Host builds are not possible: configure runs
# pg_config (via the pgzx dependency) and links libpq.
# Usage: scripts/build.sh [version] [zig-build-args...]   (default 18)
set -euo pipefail
cd "$(dirname "$0")/.."

V=${1:-18}; [ $# -gt 0 ] && shift || true
B=pgzx-build
ZIG=/opt/zig016/files/zig

docker exec "$B" mkdir -p /src-logtap
docker cp . "$B":/src-logtap/
docker exec -e HOME=/root "$B" bash -c \
  "cd /src-logtap && PATH=/usr/lib/postgresql/$V/bin:\$PATH $ZIG build --cache-dir /tmp/zc --global-cache-dir /tmp/zgc $*"
docker cp "$B":/src-logtap/zig-out/lib/pg_logtap.so zig-out/lib/pg_logtap.so
echo "built pg$V: zig-out/lib/pg_logtap.so"
