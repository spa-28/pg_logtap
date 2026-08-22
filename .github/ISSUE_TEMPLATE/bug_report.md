---
name: Bug report
about: Something captured, exported or counted wrong
labels: bug
---

**Environment**
- pg_logtap version: `SELECT pg_logtap_version();`
- PostgreSQL major + OS/arch:
- Relevant GUCs (`pg_logtap.*`, and `log_min_messages` if capture-related):

**What happened**

**What you expected**

**Evidence**
`SELECT * FROM pg_logtap_delivery;` output, receiver-side symptoms, or the
transition line (`pg_logtap export diverting batches to fallback file…`) —
whatever you have.
