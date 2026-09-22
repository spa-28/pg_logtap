# Conventional PostgreSQL extension interface: `make && make install` builds
# against the pg_config on PATH (PGXN, PGDG and muscle memory all expect it).
# The real build is Zig — see build.zig. Requires pg_config AND libpq headers
# at configure time (the pgzx dependency translates the server headers and
# links libpq); any server-dev major will do. CI runs the same targets.
# No local pg_config? `make container` builds in the pgzx-build container,
# `make e2e` runs the full docker test matrix.
PG_CONFIG ?= pg_config
PG_PKGLIBDIR = $(shell $(PG_CONFIG) --pkglibdir 2>/dev/null)
PG_SHAREDIR = $(shell $(PG_CONFIG) --sharedir 2>/dev/null)

V ?= 18     # PG major for make container
STORM ?= 5  # storm seconds for make e2e (CI's value)
PGS ?=      # PG majors for make e2e (empty = all vendored)
C ?=        # stand container for make deploy (default: pglogtap-pg)

.PHONY: all build check install test fmt lint clean container deploy e2e

all: build

build:
	zig build

# What CI's fast job runs: fmt + lint + unit tests in one zig build pass, then
# the library compile — `zig build test` only builds the test module, and
# broken src/ has passed it before.
check:
	zig build fmt lint test --summary all
	zig build --summary all

install: build
	install -D zig-out/lib/pg_logtap.so $(PG_PKGLIBDIR)/pg_logtap.so
	install -D pg_logtap.control $(PG_SHAREDIR)/extension/pg_logtap.control
	install -m 644 sql/*.sql $(PG_SHAREDIR)/extension/

test:
	zig build test --summary all

fmt:
	zig build fmt --summary all

lint:
	zig build lint --summary all

clean:
	rm -rf zig-out dist .zig-cache

# Dev battery without a local pg_config: same two steps, in the pgzx-build
# container (see scripts/build.sh).
container:
	scripts/build.sh $(V) fmt lint test --summary all
	scripts/build.sh $(V) --summary all

# zig-out from make container into the dev stand container.
deploy:
	scripts/dev-deploy.sh $(C)

# The docker e2e matrix; JOBS=4 (env) runs the majors in parallel.
e2e:
	scripts/test-matrix.sh $(STORM) $(PGS)
