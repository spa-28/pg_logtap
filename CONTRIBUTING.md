# Contributing

Bug reports and PRs are welcome. The dev loop is docker-based — see
[Development & Testing](README.md#development--testing) for the full picture.

## Setup

```sh
docker run -d --name pglogtap-pg -e POSTGRES_PASSWORD=dev -p 55432:5432 postgres:18
scripts/dev-deploy.sh        # builds in the pgzx-build container, docker cp into pglogtap-pg
```

Zig 0.16.0 and a `pg_config` for the target major are the only build
prerequisites; `pg_logtap` supports PostgreSQL 15–18.

## Before opening a PR

```sh
zig fmt --check src/ build.zig      # or scripts/build.sh 18 fmt
scripts/build.sh 18 lint            # zlinter
scripts/build.sh 18 test            # unit tests (standalone, no server needed)
```

Anything touching the export path also deserves a run of the e2e scripts
(`scripts/e2e-vector.sh`, `scripts/e2e-kill.sh`) — they need a container with
the extension deployed.

## Rules of the road

- One topic per PR, on a branch; `main` only takes merges via PR.
- Keep `pg_logtap_stats()` text keys, the `pg_logtap_delivery` view columns and
  the Prometheus metric names in sync — they are one naming scheme
  (see [docs/delivery.md](docs/delivery.md)).
- A version bump touches `pg_logtap.control`, the `sql/pg_logtap--X.Y.Z.sql`
  filename, `build.zig.zon`, and adds a delta script from the previous version
  (see [Releases](README.md#releases)).
- New GUCs or event fields → update README and docs/delivery.md in the same PR.
