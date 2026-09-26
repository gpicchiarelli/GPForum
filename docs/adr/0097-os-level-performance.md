# ADR 0097: OS-Level Performance Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/49.txt` ("GPForum - OS-Level
Performance Constitution"); this ADR replaces the prompt as the binding
source.

## Context

GPForum needs a mandatory operating-system performance doctrine for
macOS, FreeBSD, and Linux so that throughput comes from doing less work per
request, not from extra infrastructure. The doctrine is foundational and
mandatory. It governs the runtime process model, the `GPForum::OS`
abstraction, sockets, filesystem writes, worker classes, local caches, hot
and cold paths, rendering, content parsing, PostgreSQL usage, metrics,
profiling, and platform deployment profiles, so it applies to every bounded
context that serves requests or runs workers.

## Decision

### Alignment With Other Constitutions

- Prompt 45 alignment (ADR 0093): performance claims MUST be measurable, hot
  paths MUST remain bounded, and invasive optimization requires profiling
  evidence.
- Prompt 40 alignment (ADR 0088): Perl process scaling MUST respect
  operating-system limits, PostgreSQL connection pressure, worker isolation,
  and predictable deployment profiles.
- Prompt 41 alignment (ADR 0089): OS-level tuning MUST remain profileable
  through Devel::NYTProf, PostgreSQL EXPLAIN, and platform-native tools such
  as ktrace, dtrace, perf, top, systat, vmstat, and iostat where available.

### 1. Foundational Principle

- GPForum MUST be designed so the operating system does less work, does
  useful work, and does predictable work.
- Every application choice SHOULD reduce unnecessary forks, excessive
  syscalls, memory copies, blocking I/O, long locks, repeated queries,
  repeated parsing, unnecessary synchronous writes, and massive allocations in
  the request path.
- The goal is less work per request, higher throughput, steadier latency,
  stronger observability, and real portability across macOS, FreeBSD, and
  Linux.

### 2. Supported Systems

- GPForum MUST officially support macOS for primary development, FreeBSD for
  high-discipline Unix deployment, and Linux for universal cloud, bare-metal,
  and hosted deployment.
- Every OS-specific optimization MUST be detected automatically, isolated in a
  dedicated module, disableable, documented, and covered by tests or a tested
  fallback.

### 3. Portability Rule

- Application code MUST NOT scatter casual operating-system checks such as
  `if ($^O eq 'freebsd') { ... }`.
- OS-specific logic MUST live behind dedicated modules: `GPForum::OS`,
  `GPForum::OS::Darwin`, `GPForum::OS::FreeBSD`, `GPForum::OS::Linux`,
  `GPForum::OS::Socket`, `GPForum::OS::Resource`, `GPForum::OS::Process`,
  and `GPForum::OS::Filesystem`.
- Application code MUST call only abstract interfaces such as
  `$os->supports_sendfile`, `$os->supports_reuseport`,
  `$os->recommended_worker_count`, and
  `$os->feature_enabled('reuseport', $setting)`.

### 4. OS Detection

- OS detection MUST happen once during bootstrap where practical:
  `my $os = GPForum::OS->detect;`.
- Allowed detected values are `darwin`, `freebsd`, `linux`, and `unknown`.
- Unknown systems MUST run in conservative fallback mode.

### 5. Process Model

- GPForum MUST use persistent Perl processes.
- Forbidden runtime models: classic CGI, fork per request, shell-out in the
  request path, and temporary processes for ordinary forum operations.
- The mandatory production model is Mojolicious plus Hypnotoad or equivalent
  prefork-capable Mojolicious deployment, controlled prefork, warm workers,
  preloaded stable modules, copy-on-write where available, and worker-local
  database connections.
- Database handles MUST NOT be shared unsafely from master to workers.

### 6. Preload Discipline

- Stable modules SHOULD be loaded before fork when using prefork deployment.
- The preload set SHOULD include schema root, controller classes, hot-path
  reader/composer/store services, authorization and session services,
  projection and search services, and worker registration classes.
- Dynamic `require` in hot paths is forbidden unless justified by ADR.

### 7. Database Connections

- PostgreSQL connections MUST be created after fork or safely reconnected per
  worker.
- Each worker MUST have its own database lifecycle, explicit reconnect
  behavior, explicit timeouts, bounded query patterns, and statement caching
  where appropriate.

### 8. Socket Policy

- Socket behavior MUST be centralized behind OS abstractions or deployment
  configuration.
- Desired options, when available: `SO_REUSEADDR`, `SO_REUSEPORT`,
  `SO_KEEPALIVE`, `TCP_NODELAY`, adequate accept queues, and controlled
  keep-alive timeout.
- Missing socket features MUST degrade safely.
- FreeBSD SHOULD prefer kqueue, `SO_REUSEPORT` where supported, reverse-proxy
  sendfile, and optional `cpuset`.
- Linux SHOULD prefer epoll, `SO_REUSEPORT`, sendfile, optional systemd
  socket activation when documented, and optional `taskset` or `numactl`.
- macOS SHOULD prefer kqueue, sane file descriptor limits, and
  development-grade profiling without treating macOS throughput as the
  production ceiling.

### 9. Event Loop Discipline

- The request path MUST NOT block the event loop with synchronous email,
  synchronous external HTTP, heavy markdown rendering, live syntax
  highlighting, search indexing, ranking updates, social/federation
  notification work, digest generation, or heavy statistics.
- Correct write flow:

```text
validate -> authorize -> write canonical row/event -> commit -> respond -> enqueue async work
```

### 10. Static Files And Attachments

- Perl controllers SHOULD NOT serve large files except in explicitly justified
  cases.
- Preferred delivery path: reverse proxy, web server, sendfile or equivalent
  zero-copy delivery, correct cache headers, and ETag or Last-Modified.
- Perl MAY authorize access and then delegate transfer.

### 11. Append-Only Writes

- Audit logs, event logs, traces, and forensic records SHOULD use append-only
  patterns.
- GPForum MUST prefer append over update, batching over continuous flush, and
  PostgreSQL WAL over manual Perl fsync.
- Manual fsync in ordinary application code is forbidden without ADR.

### 12. Filesystem Atomicity

- Local generated files and disposable local caches MUST use atomic write
  patterns: write temp file -> close -> rename within same filesystem.
- File locks MAY be used for pidfiles, local caches, local maintenance, and
  single-host coordination.
- File locks MUST NOT provide distributed domain consistency.

### 13. Resource Limits

- Startup and metrics SHOULD expose operating system, Perl version, CPU
  count, file descriptor posture where available, event backend, and runtime
  process counts.
- Insufficient production limits SHOULD produce clear warnings.

### 14. Worker Classes

- GPForum SHOULD distinguish process classes: `web_worker`,
  `projection_worker`, `mail_worker`, `search_worker`, and
  `maintenance_worker`.
- Lower-priority worker classes MAY use `setpriority` or supervisor-level
  priority controls where available.
- Failure to set priority MUST warn, not crash.

### 15. CPU Affinity

- CPU affinity MUST NOT be required for correctness.
- Deployment MAY use FreeBSD `cpuset`, Linux `taskset` or `numactl`, and no
  mandatory affinity on macOS.
- Affinity policies are deployment controls, not application correctness
  controls.

### 16. Memory Discipline

- Web workers MUST NOT retain huge buffers.
- Forbidden: reading large files fully into memory, constructing huge
  responses in memory, unbounded per-process caches, and heavy mutable
  globals.
- Required: streaming for large files, bounded caches, buffer cleanup, and
  separate jobs for heavy processing.

### 17. Local Perl Cache

- Per-process Perl cache is allowed for configuration, feature flags,
  categories, static permission catalogs, small template fragments, and
  low-volatility lookups.
- It is forbidden for critical sessions, strong shared state, concurrent
  counters, and sensitive authorization without invalidation/versioning.
- Every cache MUST have TTL, size limit, invalidation documentation, and DB
  fallback.

### 18. Hot Paths

- Official hot paths: thread list, thread read, post creation, login, session
  validation, unread count, and forum index.
- Hot paths MAY use targeted SQL, prepared statements, narrow selects,
  projection tables, hashrefs instead of heavy objects, and controlled local
  cache.
- DBIx::Class remains allowed, but MUST NOT create N+1 queries or unnecessary
  object inflation in hot paths.

### 19. Cold Paths

- Cold paths: admin panels, complex moderation, reports, configuration, audit
  inspection, exports, and maintenance.
- Cold paths may favor expressiveness over micro-optimization while remaining
  bounded and observable.

### 20. DBIx::Class Rules

- Known N+1 queries are forbidden.
- `prefetch` is required where relationships are needed.
- `rows` or equivalent bounds are required in web lists.
- Keyset pagination is preferred.
- Unbounded resultsets are forbidden in web hot paths.
- Direct SQL is allowed only when the hot path requires it and the query is
  stable, tested, documented, and plan-verifiable.

### 21. Rendering

- Templates MUST render; they MUST NOT calculate domain behavior.
- Templates MUST NOT perform database queries, ranking calculations, complex
  permission checks, markdown rendering, heavy regular expressions, or
  business logic.
- Controllers and services MUST pass prepared view models.

### 22. Content Parsing

- Markdown, BBCode, linkification, sanitizer output, and syntax highlighting
  MUST NOT be recalculated on every read.
- The correct model includes raw body, rendered safe body, render version,
  and sanitized timestamp. Read paths serve pre-rendered safe content.

### 23. Async Workers

- Differable work MUST be asynchronous: email, notifications, digests, search
  indexing, projection rebuilds, ranking, badges, social integrations,
  webhooks, federation, image processing, and cleanup.
- Async failure MUST NOT corrupt the canonical write path.

### 24. Projection Engine

- High-traffic reads SHOULD use rebuildable projections.
- Projection tables MUST be rebuildable, idempotent, monitored, versioned,
  and verifiable.

### 25. PostgreSQL And OS

- GPForum MUST use PostgreSQL as the consistency coordinator.
- Application code MUST use short transactions, explicit locks only when
  necessary, controlled retries, statement timeouts, idle timeouts, and
  bounded queries.
- Transactions MUST NOT remain open during HTML rendering, external calls,
  email, slow filesystem work, or async jobs.

### 26. Logging And Metrics

- Hot paths SHOULD expose route, elapsed milliseconds, database milliseconds,
  render milliseconds, optional user id, request id, status, and worker pid.
- Metrics MUST include request latency, DB latency, render latency, queue
  depth, projection lag, worker memory, open file descriptors where
  available, error rate, slow queries, and cache hit/miss where available.
- Without metrics, invasive optimization is not accepted.

### 27. Profiling

- Profiling is mandatory before invasive optimization.
- Accepted tools: Devel::NYTProf, PostgreSQL `EXPLAIN ANALYZE`, ktrace or
  dtrace where available, Linux perf, top, htop, systat, vmstat, and iostat.
- Every important optimization MUST state measured problem, hypothesis,
  change, result, and possible regressions.

### 28. Platform Profiles

- The macOS profile requires simple bootstrap, full test suite, Perl
  profiling, kqueue compatibility, and no Linux-only or FreeBSD-only
  assumptions.
- The FreeBSD profile favors kqueue, web-server sendfile, optional jails,
  optional cpuset, ZFS or UFS according to workload, and rc.d integration
  where packaged.
- The Linux profile favors epoll, `SO_REUSEPORT`, sendfile, optional systemd
  integration, optional taskset, numactl, cgroups, and journald.

### 29. No Mandatory Redis

- GPForum MUST NOT require Redis for performance correctness.
- Performance comes first from PostgreSQL, projection tables, OS page cache,
  controlled local Perl cache, correct queries, and precomputed rendering.
- Redis-like systems MAY be optional plugins or accelerators only.

### 30. Reverse Proxy

- GPForum MUST be designed for reverse-proxy deployment.
- The reverse proxy SHOULD handle TLS, compression, static files, sendfile,
  coarse rate limiting, request buffering, header normalization, and HTTP/2
  or HTTP/3 where available.
- The Perl app should focus on authentication, authorization, domain
  behavior, dynamic rendering, APIs, and event emission.

### 31. Security And Performance

- No optimization may weaken session security, CSRF, authorization,
  auditability, validation, output escaping, password hashing, or transaction
  integrity.
- A cache that bypasses a security check is forbidden.

### 32. OS Feature Flags

- Every OS-specific optimization SHOULD be controllable:
  - `gpforum.os.reuseport = auto|on|off`;
  - `gpforum.os.sendfile = auto|on|off`;
  - `gpforum.os.worker_priority = auto|on|off`;
  - `gpforum.os.affinity = off|manual`;
  - `gpforum.os.static_xsendfile = auto|on|off`.
- Defaults MUST be conservative `auto`.

### 33. Controlled Degradation

- Missing OS features MUST degrade without correctness failure:
  - missing `SO_REUSEPORT` falls back to ordinary prefork listener behavior;
  - missing sendfile falls back to delegated static serving or normal
    streaming;
  - missing affinity means no pinning;
  - denied priority change warns rather than crashes.

### 34. Absolute Prohibitions

Forbidden:

- fork per request;
- unbounded hot-path queries;
- known uncorrected N+1 queries;
- templates with business logic;
- random manual fsync;
- unbounded cache;
- shell-out in request path;
- long transactions;
- huge production logs;
- unmeasured optimization claims.

### 35. Final Rule

- GPForum must be fast because it does fewer things, not because it hides
  disorder behind extra infrastructure.
- Guiding formula: persistent Perl + Mojolicious event-driven runtime +
  disciplined PostgreSQL + projection tables + OS page cache + prudent socket
  tuning + delegated static files + async workers + mandatory profiling =
  serious throughput without dirty architecture.

### 36. Required Updates To Existing Constitutions

- ADR 0050, ADR 0063, ADR 0086, ADR 0088, ADR 0089, and ADR 0093 MUST align
  with this document.
- Each update MUST preserve PostgreSQL-first, Perl-first, SSR-first,
  Redis-optional, OpenSearch-free, auditability, rebuildability, and
  operational simplicity.

## Consequences

- Performance comes from fewer forks, syscalls, copies, queries and
  allocations per request; latency becomes steadier and measurable.
- OS-specific behavior stays isolated in `GPForum::OS::*` and behind feature
  flags, so the same code runs on macOS, FreeBSD, and Linux, and unknown
  systems fall back conservatively.
- Every invasive optimization carries a profiling and metrics cost: without
  measured evidence it is rejected.
- Operators must deploy behind a reverse proxy, choose per-platform profiles,
  and tune worker classes, priority and affinity outside application
  correctness.
- Open conflicts:
  - ADR 0048 makes the GlifiStore shared L2 cache required in `staging`,
    `production`, `production-small`, and `production-medium` (boot fails
    closed without `glifistore_url`), while section 29 allows Redis-like
    systems only as optional plugins or accelerators. ADR 0048 keeps the L2
    disposable and fail-open at runtime, so correctness does not depend on
    it, but deployment does; the two need explicit reconciliation.
  - Section 22 requires a render version and a sanitized timestamp next to
    the raw and rendered safe body. `post_bodies`
    (`migrations/003_forum_projection.sql`) stores `body_source`,
    `body_rendered_safe`, and `source_hash`, but no render version or
    sanitized timestamp column.
  - Section 32 says defaults MUST be conservative `auto`, but
    `gpforum.os.affinity` only admits `off|manual`; `GPForum::Config`
    defaults it to `off`.

## Alignment

- ADR 0050, ADR 0063, ADR 0086, ADR 0088, ADR 0089, ADR 0093 (constitutions
  that MUST align with this one)
- ADR 0098, ADR 0099 (execution and scalability constitutions)
- `docs/adr/0012-operational-profiles.md`
- `docs/adr/0048-mandatory-glifistore-l2.md`
- `lib/GPForum/OS.pm` and `lib/GPForum/OS/` (`Base`, `Darwin`, `FreeBSD`,
  `Linux`, `Socket`, `Resource`, `Process`, `Filesystem`, `Preflight`,
  `RuntimePolicy`, `RuntimeEvidence`)
- `lib/GPForum/Config.pm` (`os_*` feature settings)
- `bin/gpforum-os-preflight`, `bin/gpforum-platform-check`,
  `script/system-preflight`, `script/profile-nytprof`, `script/profile`,
  `script/query-plan-check`
- `docs/OS_OPTIMIZATION.md`, `docs/OS_RUNTIME_ENFORCEMENT.md`,
  `docs/OS_RUNTIME_EVIDENCE.md`, `docs/PROFILING.md`, `docs/PERFORMANCE.md`
- `t/36-os-performance.t`, `t/37-os-filesystem.t`, `t/40-local-cache.t`,
  `t/52-os-preflight.t`, `t/53-os-runtime-policy.t`,
  `t/58-os-runtime-evidence.t`, `t/59-hypnotoad-scaling.t`
- `t/09-prompt-alignment.t`
