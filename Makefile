# Conventional PostgreSQL extension interface: `make && make install` builds
# against the pg_config on PATH (PGXN, PGDG and muscle memory all expect it).
# The real build is Zig — see build.zig. Requires pg_config AND libpq headers
# at configure time (the pgzx dependency translates the server headers and
# links libpq). No pg_config locally? Use scripts/build.sh (builds in the
# pgzx-build container).
PG_CONFIG ?= pg_config
PG_PKGLIBDIR = $(shell $(PG_CONFIG) --pkglibdir 2>/dev/null)
PG_SHAREDIR = $(shell $(PG_CONFIG) --sharedir 2>/dev/null)

.PHONY: all build install test clean

all: build

build:
	zig build

install: build
	install -D zig-out/lib/pg_logtap.so $(PG_PKGLIBDIR)/pg_logtap.so
	install -D pg_logtap.control $(PG_SHAREDIR)/extension/pg_logtap.control
	install -m 644 sql/*.sql $(PG_SHAREDIR)/extension/

test:
	zig build test --summary all

clean:
	rm -rf zig-out dist .zig-cache
