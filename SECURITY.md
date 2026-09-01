# Security policy

pg_logtap runs inside the PostgreSQL server process (a bgworker plus a hook in
every backend) and opens a plaintext metrics listener when `metrics_port` is
set. The listener binds `pg_logtap.metrics_addr` — loopback by default (v0.2.1
and later); before that it bound every interface, so upgrade and check the
setting if you rely on remote scraping. No TLS, no auth (docs/delivery.md
covers the stance by design): keep it on loopback or a closed network.

## Redaction is best-effort and errs toward masking too much

The redaction layers (the always-on password-token cut, the bind-parameter
value cut, `redact_pattern`) run over message, detail, hint, context and the
captured query. They are a leakage *reduction*, not a guarantee — a
determined writer can evade any pattern. Where a layer has to guess, it
guesses toward over-redaction: a value that merely looks like `password =
…` in a DETAIL line is masked whole, and an event is flagged `clipped` when
*any* layer clipped its text (re-running the other layers on an already
clipped text would over-mask, so the flag is ORed across layers). Accept
that non-secret text will sometimes ship as `<REDACTED>`; audit receivers
against raw server logs, not against the export. One layer fails open: a
`redact_pattern` that does not compile disables only that layer (server-log
WARNING plus the `pg_logtap_redact_pattern_failed` gauge) while the
always-on cuts keep working.

## Supported versions

The latest released minor (see [releases](https://github.com/spa-28/pg_logtap/releases)).

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this
repository. Please include the affected version, a reproducer, and impact;
do not open a public issue for it. You'll get an acknowledgement within
a few days and coordinated disclosure otherwise.
