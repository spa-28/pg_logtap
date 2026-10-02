#!/usr/bin/env bash
# Package existing split_debug outputs once, then smoke those exact tarballs.
# Usage: scripts/archive-smoke.sh <PG-major> [archive-output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
PG=${1:?PG major required}
case "$PG" in 15|16|17|18) ;; *) exit 1 ;; esac
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) printf 'unsupported native architecture\n' >&2; exit 1 ;;
esac
VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" pg_logtap.control)
OUT=${2:-dist/pg$PG/archives}
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
PACKAGE=pg_logtap-$VERSION-pg$PG-$ARCH
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/runtime/lib" "$TEMP/runtime/extension" "$TEMP/debug/lib"
cp "dist/pg$PG/lib/pg_logtap.so" "$TEMP/runtime/lib/"
cp pg_logtap.control sql/*.sql "$TEMP/runtime/extension/"
cp "dist/pg$PG/lib/pg_logtap.so.debug" "$TEMP/debug/lib/"
tar -C "$TEMP/runtime" -czf "$OUT/$PACKAGE.tar.gz" .
tar -C "$TEMP/debug" -czf "$OUT/$PACKAGE-debug.tar.gz" .
python3 scripts/archive-smoke.py --self-test
python3 scripts/archive-smoke.py "$OUT/$PACKAGE.tar.gz" "$OUT/$PACKAGE-debug.tar.gz" "$ARCH" "$VERSION"
# Unique per invocation: neither smoke builds nor runs touch developer stands.
IMAGE=pglogtap-archive-el8-pg$PG-$(basename "$TEMP" | tr '[:upper:]' '[:lower:]')
trap 'docker image rm "$IMAGE" >/dev/null 2>&1 || true; rm -rf "$TEMP"' EXIT
docker build --platform "linux/$ARCH" --build-arg "PG=$PG" -f tests/packaging/Dockerfile -t "$IMAGE" .
docker run --rm --name "$IMAGE" --platform "linux/$ARCH" --network none -v "$OUT:/archives:ro" "$IMAGE" \
  "/archives/$PACKAGE.tar.gz" "/archives/$PACKAGE-debug.tar.gz" "$ARCH" "$VERSION"
printf 'pg%s %s exact release archives: glibc 2.28 runtime smoke OK\n' "$PG" "$ARCH"
