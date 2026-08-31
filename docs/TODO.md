# Roadmap

Known ceilings and deferred designs — kept here so they are not re-derived
from scratch when the need becomes real.

- **Chained slots for oversized messages**: capture splits a long message
  across continuation ring slots under one LWLock hold, the worker joins
  them back into one event at export — no fixed per-slot tax, the ring pays
  only for the long messages it actually carries. Deferred because the three
  boundaries (ring overflow mid-chain, backlog trim at a chain head, backend
  death between slots) are exactly the failure classes that took the longest
  to stabilize; each needs its own e2e scenario before this lands.
- **Regex backreferences**: `\1` drops glibc's regexec off its fast matcher
  (~n²·⁶ measured, worst case ~20 s at the message cap); plain EREs are
  linear. A pattern-length/input-length guard, or a linear-time matcher,
  would make pathological patterns safe to accept. Until then the pattern
  GUC docs carry the warning.
- **Persist the fallback replay offset in the file header**: removes the
  full-file scan at worker startup and makes `events_replayed ≤
  events_queued` hold across soft worker restarts structurally (see the
  counter-glossary note in delivery.md). Requires a framing format bump
  (`PGLTFB01` → `02`); pick up when a queue large enough for the startup
  scan to matter is seen in the wild (642 MB scanned in ~1 s today).
- **Multi-field pattern matching**: `redact_pattern`/password-cut match the
  message only; DETAIL carries bind parameters (see README, redaction
  contract). Extend to message+detail+hint+context+query when someone asks
  for it with a real audit requirement.
- **IPv6 literal addresses** in `export_url` (bracket parsing in
  export.zig); hostnames with AAAA records already work.
- **TLS / authentication on the export hop**: deliberately not in the
  worker. The design is delegation — point `export_url` at a local sidecar
  (Vector, Fluent Bit, stunnel, an nginx TLS terminator) on the same host
  or network namespace, and terminate TLS there. That keeps the worker on
  plain blocking sockets (its crash-safety budget), gives the full client-
  cert/mTLS toolbox of a dedicated proxy, and matches how the rest of the
  stack already ships logs. Revisit only if a deployment cannot run a
  sidecar.
- **Retry backoff**: exponential + jitter on send retries; the fixed
  `flush_interval` cadence is fine until a receiver rate-limits on connect
  storms.
