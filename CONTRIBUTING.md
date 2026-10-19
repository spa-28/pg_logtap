# Contributing

Bug reports and PRs are welcome. The dev loop is docker-based — see
[Development & Testing](README.md#development--testing) for the full picture.

## Setup

Start with [Development & Testing](README.md#development--testing) for the
initial development stand and its prerequisites.

A native build needs Zig 0.16.0, the target PostgreSQL's `pg_config` and server
development files, and libpq development files. Python-based checks (the
host-only harness and metrics E2E pilot) need Python 3.10+ and uv;
`tests/pyproject.toml` and `tests/uv.lock` define their isolated test environment.
See [Testing](README.md#testing) for the commands. Uv and pytest are not needed
to build or run the extension.
pg_logtap supports PostgreSQL 15–18. `make container` requires an existing
pgzx-build container; it does not create the builder or a development stand.

`scripts/dev-deploy.sh` is for an existing PostgreSQL container that already
has pg_logtap preloaded and its SQL extension installed. It builds, copies the
extension, and restarts that container; it is not bootstrap or an implicit
`ALTER EXTENSION UPDATE`.

## Before opening a PR

```sh
make check                 # harness, format, lint, unit tests, and library compile
```

With an existing build container instead of native Zig/PostgreSQL setup:

```sh
make test-harness          # uv-managed host-only checks; no Docker
make container V=18        # Zig checks and library compile in pgzx-build
```

Use `make e2e` for the full compose-backed test matrix; its metrics pytest
phase also requires uv and Python 3.10+ on the host. For a prepared subset,
run `PHASES=stand,storm,kill tests/e2e/test-matrix.sh 5 18`. The metrics pilot
can be run separately with `tests/e2e/e2e-metrics.sh [container] [port]`; this
adapter supplies the required bootstrap context and holds the lock through
cleanup. Default pytest discovery remains host-only. Successful matrix runs
clean up their per-version containers.

## Rules of the road

- One topic per PR, on a branch; `main` only takes merges via PR.
- Keep `pg_logtap_stats()` text keys, the `pg_logtap_delivery` view columns and
  the Prometheus metric names in sync — they are one naming scheme
  (see [docs/delivery.md](docs/delivery.md)).
- A version bump touches `pg_logtap.control`, the `sql/pg_logtap--X.Y.Z.sql`
  filename, `build.zig.zon`, `src/version.zig`, and adds a delta script from
  the previous version (see [Releases](README.md#releases)).
- New GUCs or event fields → update README and docs/delivery.md in the same PR.
