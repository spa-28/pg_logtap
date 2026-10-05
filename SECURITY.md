# Security policy

pg_logtap runs inside the PostgreSQL server process (a bgworker plus a hook in
every backend) and opens a plaintext metrics listener when `metrics_port` is
set. The listener binds `pg_logtap.metrics_addr` — loopback by default (v0.2.1
and later); before that it bound every interface, so upgrade and check the
setting if you rely on remote scraping. No TLS, no auth (docs/delivery.md
covers the stance by design): keep it on loopback or a closed network.

## Redaction is best-effort and errs toward masking too much

The redaction layers (the always-on password-token cut, the bind-parameter
value cut, `redact_pattern`) run before the ring, fallback queue and receiver.
They are a leakage *reduction*, not a guarantee — a determined writer can
still evade text matching. Statement provenance uses PostgreSQL's
untranslated primary format ID, while the exported message stays localized;
`lc_messages` therefore does not decide whether the built-in password cut
runs. Translated auxiliary wrappers are preserved, but every exact `$N =
'quoted value'` shape in DETAIL/HINT/CONTEXT is masked. This deliberately
also over-masks application text with that shape, just as a value that merely
looks like `password = …` is masked. Accept that non-secret text will
sometimes ship as `<REDACTED>`; audit receivers against raw server logs, not
against the export. A clip reported by one layer remains reported after later
layers. Invalid `pattern`, `pattern_exclude` and `redact_pattern` assignments,
including backreferences (`\1`…`\9`), are rejected before they replace the
active compiled expression. The `pg_logtap_redact_pattern_failed` gauge is a
defensive signal for an unexpected assign-time compile failure, not for an
ordinary rejected setting.

`pg_logtap.export_http_extra_headers` is marked superuser-only because it often
contains bearer tokens. Ordinary roles cannot read it through `SHOW`,
`current_setting()` or `pg_settings`; superusers and trusted roles with
`pg_read_all_settings` (including `pg_monitor`) can. This is an access-control
boundary, not encrypted secret storage: the value also exists in PostgreSQL
configuration files and process memory.

## Local export files

`file://` sinks, fallback queues and compaction temporary files must be regular
files owned by the worker's effective UID, with exactly one hard link. The
worker checks the opened descriptor before changing permissions or doing IO,
applies `0600` and verifies it. A failed check or chmod fails closed: the sink
send fails, or the fallback queue becomes broken; no log payload is written.
Existing worker-owned files with wider modes can be tightened, but foreign-owned
files are never chmodded. Permission rejection is not a failed `fdatasync` and
does not increment `fb_sync_failures`.

Final-component symlinks, hardlinks, FIFOs and devices are unsupported.
`O_NOFOLLOW` protects the final component only: parent directories must remain
trusted and not writable by untrusted users. Keep each sink and queue private
to one cluster and one writer; descriptor checks do not make shared-directory
races or concurrent writers safe. Repair a broken queue in place and explicitly
reload to revalidate it; an unread or uncheckable active queue blocks a path
change, including disabling fallback.

## Supported versions

The latest released minor (see [releases](https://github.com/spa-28/pg_logtap/releases)).

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this
repository. Please include the affected version, a reproducer, and impact;
do not open a public issue for it. You'll get an acknowledgement within
a few days and coordinated disclosure otherwise.
