---
name: Bug report
about: Something captured, exported or counted wrong
labels: bug
---

**Environment**
- pg_logtap version: `SELECT pg_logtap_version();`
- PostgreSQL major + OS/arch:
- Relevant, anonymized GUCs (`pg_logtap.*`, and `log_min_messages` if capture-related):

Do not publish secret values from `pg_logtap.export_http_extra_headers`
(including `Authorization`), passwords or credentials in URLs, or sensitive
log text. Redact or replace them before submitting.

**What happened**

**What you expected**

**Evidence**
`SELECT * FROM pg_logtap_delivery;` output, receiver-side symptoms, or the
transition line (`pg_logtap export diverting batches to fallback file…`) —
whatever you have.
