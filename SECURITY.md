# Security policy

pg_logtap runs inside the PostgreSQL server process (a bgworker plus a hook in
every backend) and opens a plaintext metrics listener when `metrics_port` is
set. The listener binds `pg_logtap.metrics_addr` — loopback by default (v0.2.1
and later); before that it bound every interface, so upgrade and check the
setting if you rely on remote scraping. No TLS, no auth (docs/delivery.md
covers the stance by design): keep it on loopback or a closed network.

## Supported versions

The latest released minor (see [releases](https://github.com/spa-28/pg_logtap/releases)).

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this
repository. Please include the affected version, a reproducer, and impact;
do not open a public issue for it. You'll get an acknowledgement within
a few days and coordinated disclosure otherwise.
