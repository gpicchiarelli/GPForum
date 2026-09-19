# ADR 0048: Mandatory GlifiStore L2 Cache

## Status

Accepted.

## Context

`LocalCache` was L1 and GlifiStore was an optional L2 behind
`GPFORUM_GLIFISTORE_URL`, default off. Bootstrap used `try_connect` and
silently returned process-local cache when the URL was empty or the client
could not connect. Public SSR (`Web::PublicHttpCache`), category read models
(`Forum::CategoryReader`), and worker tag invalidation already shared that
one cache helper. ADR 0012 left L2 optional; operators could run staging and
production without a shared cache even though Hypnotoad is multi-process.

PostgreSQL remains the only source of truth. Cache entries stay disposable.

## Decision

GlifiStore is the required shared L2 for existing cache seams:

- Development defaults to `tcp://127.0.0.1:7379`.
- `staging`, `production`, `production-small`, and `production-medium` fail
  closed when `glifistore_url` is missing.
- `CacheFactory` always builds `TieredCache` when a URL is present, even if
  the first connect fails. Shared-cache operations stay fail-open and retry.
- Unreachable GlifiStore degrades readiness to `local-fallback` and keeps
  serving from L1 and PostgreSQL.

Redis/KeyDB remains optional and is not this L2.

## Consequences

Multi-process web workers share public HTML and category list entries through
GlifiStore. Operators must run GlifiStore in staging and production. A down
or empty L2 never becomes authoritative. Invalidation still flows through
`gp_local_cache`, which is now tiered when L2 is configured.

## Alternatives Rejected

- Keep L2 optional and default-off: rejected because multi-process SSR and
  category caches would keep missing each other by default.
- Fail the process when GlifiStore is unreachable: rejected because cache is
  disposable and PostgreSQL can keep serving.
- Add new speculative page caches: rejected; only existing seams are wired.

## Alignment

- `docs/adr/0012-operational-profiles.md`
- `docs/architecture/operational-profiles.md`
- `docs/OS_RUNTIME_ENFORCEMENT.md`
- `t/142-cache-factory.t`
- `t/89-tiered-cache.t`
- `t/01-config.t`
- `t/33-health-readiness.t`
- `t/98-operational-profiles.t`
