# ADR 0088: Perl Multi-Process, Threading and Dynamic Runtime Scalability

## Status

Accepted. Converted on 2026-09-19 from `prompt/40.txt` ("GPForum - Perl
Multi-Process, Threading & Dynamic Runtime Scalability Constitution"); this
ADR replaces the prompt as the binding source.

## Context

GPForum is Perl-first, and a single Perl process cannot serve a large
community. The platform needs a mandatory runtime scalability model: many
Perl processes per node and across nodes, per-workload process classes,
bounded threading, workload isolation and capacity estimation that
accounts for PostgreSQL connection budgets. This ADR is foundational and
mandatory; it governs the web, worker, realtime, indexing and maintenance
runtimes and their deployment profiles.

## Decision

### Cross-ADR alignment

- ADR 0093 (verifiable invariants): scaling claims MUST be verified by
  measurable invariants. Multi-process and threading behavior MUST preserve
  authoritative PostgreSQL state, disposable realtime/cache state,
  idempotent workers, observable coordination and bounded query cost. Any
  distributed dependency introduced for coordination requires ADR
  justification and tests for degraded operation.
- ADR 0097 (OS-level performance): process scaling MUST be OS-aware and
  resource-bounded. GPForum MUST use persistent Perl processes, never fork
  per request, and MUST centralize OS-specific behavior behind
  `GPForum::OS`. Worker counts MUST account for CPU, memory, file
  descriptors, PostgreSQL connection pressure, event backend and deployment
  profile.
- ADR 0099 (projection stability): horizontal scaling MUST preserve
  projection stability, outbox idempotency, worker restart safety, hot-row
  avoidance, bounded hot-path queries, and graceful degradation when
  optional derived subsystems lag.

### Runtime scalability philosophy

GPForum is Perl-first, not Perl-single-process.

- Application runtime code MUST remain Perl-only unless an ADR explicitly
  approves an exception.
- External infrastructure such as PostgreSQL, Nginx or HAProxy, object
  storage and operating-system supervisors MAY be used because they are
  infrastructure components, not application runtime languages.
- The platform MUST scale the application tier through: multiple Perl web
  processes; multiple Perl worker processes; multiple Perl realtime
  processes where realtime is enabled; multiple application nodes; explicit
  process supervision; bounded concurrency per process.
- The platform MUST NOT assume that one Perl process represents the
  application.

### Primary concurrency unit

- The primary concurrency unit is the Perl process.
- Processes are preferred because they provide: memory isolation; crash
  isolation; predictable restart behavior; clear supervisor integration;
  safer operational reasoning; straightforward horizontal and vertical
  scaling.
- Perl process multiplicity is mandatory for production.

### Dynamic process scaling

- Each deployment MUST allow process counts to be configured per workload
  class.
- Configurable process classes SHOULD include: web; worker; scheduled jobs;
  realtime websocket; indexing; maintenance.
- Process counts SHOULD be adjustable by: environment configuration;
  supervisor configuration; deploy profile; capacity plan; emergency
  runbook.
- Process scaling MUST remain observable.
- Process scaling MUST be profiled under representative workloads before
  production reliance.

### Per-node scaling

- A single physical or virtual node MAY run many Perl processes.
- Per-node capacity MUST account for: CPU cores; memory per process;
  database connections; file descriptors; websocket connections; queue
  concurrency; cache memory; operating system limits.
- Per-node capacity plans MUST include profiling data for: CPU time; memory
  growth; request latency; worker throughput; database connection pressure.
- The system MUST avoid increasing Perl processes beyond downstream
  capacity.
- More Perl processes MUST NOT be used to hide database, lock or query
  design problems.

### Multi-node scaling

- Multiple nodes MAY run the same process classes.
- The system MUST support: stateless web nodes; distributed worker nodes;
  isolated realtime nodes; rolling process restart; node replacement;
  load-balanced traffic.
- Application correctness MUST NOT depend on a specific node owning durable
  state.

### Threading model

- Perl interpreter threads MAY be used.
- Threads MUST be: bounded; isolated; explicitly configured; reviewed for
  shared-state safety; observable; optional for correctness.
- Threads MAY be appropriate for: CPU-bound isolated helper work; bounded
  local parallelism; carefully reviewed internal processing; workloads where
  process overhead is operationally worse.
- Threads MUST NOT be used for: shared mutable business state;
  authorization correctness; session correctness; unbounded request fanout;
  replacing durable queues; hiding blocking I/O in request paths.
- The default scaling strategy remains process-first.

### Mojolicious runtime

- Mojolicious deployment MUST support a production prefork-style runtime.
- Web runtime MUST provide: multiple workers; graceful restart; bounded
  request concurrency; health endpoints; structured logs per process;
  supervisor compatibility.
- Blocking work MUST be moved out of request handlers.

### Worker runtime

- Minion worker capacity MUST scale through multiple Perl worker processes.
- Worker pools SHOULD be separated by workload class where needed, for
  example: notification workers; search indexing workers; media workers;
  retention workers; digest workers; import workers.
- Worker concurrency MUST be tuned against PostgreSQL, object storage and
  search-indexing capacity.

### Realtime runtime

- Realtime workloads MAY run in separate Perl process pools.
- Realtime processes MUST: keep per-connection state ephemeral; avoid
  authoritative state; enforce backpressure; support reconnect; survive
  process loss through client recovery and durable events.
- Millions of concurrent realtime users require dedicated realtime capacity
  planning.

### Database connection discipline

- Process scaling MUST be coordinated with database connection budgets.
- The deployment MUST define: maximum web processes; maximum worker
  processes; maximum database connections per process; connection pool
  behavior; reserved admin/maintenance connections.
- PostgreSQL exhaustion is a release blocker.

### Capacity estimation rule

- Capacity estimates MUST distinguish between: registered users; daily
  active users; hourly active users; concurrent web users; concurrent
  websocket users; write rate; read rate; worker backlog.
- Claims about "millions of active users" MUST specify which active-user
  meaning is being used.

### Operational goal

GPForum MUST be able to grow from:

1. one node with many Perl processes;
2. to several nodes with separated process classes;
3. to a distributed deployment with dedicated web, worker, realtime, search
   and database capacity.

The project remains Perl-first while allowing specialized infrastructure
for persistence, search, edge routing and storage.

## Consequences

- Scaling is a configuration and capacity-planning exercise per process
  class, bounded by PostgreSQL connection budgets rather than by adding
  processes blindly.
- Threads stay an optional, reviewed optimization; correctness never
  depends on them.
- Because no node owns durable state, nodes and processes can be restarted
  or replaced during rolling deploys (ADR 0086).
- Capacity claims must name the active-user meaning and be backed by
  profiling data, which adds benchmark work before production reliance.

## Alignment

- ADRs: 0093, 0097 and 0099 (cross-alignment), 0050 (infrastructure), 0056
  (workers), 0063 (performance and capacity), 0086 (runtime processes), 0089
  (profiling); 0006 (LISTEN/NOTIFY realtime transport), 0012 (operational
  profiles), 0048 (mandatory GlifiStore L2, a coordination dependency
  justified by ADR).
- Code: `lib/GPForum/OS.pm`, `lib/GPForum/OS/`, `lib/GPForum/Runtime.pm`,
  `lib/GPForum/Config.pm`, `lib/GPForum/Service/Operations/RuntimeSizing.pm`,
  `lib/GPForum/Service/Realtime/ListenerSupervisor.pm`,
  `lib/GPForum/Worker/MinionRegistrar.pm`.
- Commands: `bin/gpforum-bench-hypnotoad`,
  `bin/gpforum-bench-hypnotoad-scaling`, `bin/gpforum-os-preflight`.
- Tests: `t/36-os-performance.t`, `t/53-os-runtime-policy.t`,
  `t/57-hypnotoad-benchmark.t`, `t/59-hypnotoad-scaling.t`,
  `t/82-realtime-supervisor.t`, `t/84-outbox-concurrent-dispatcher.t`,
  `t/85-realtime-outbox-multiprocess.t`.
- Docs: `docs/OS_OPTIMIZATION.md`, `docs/OS_RUNTIME_ENFORCEMENT.md`,
  `docs/PERFORMANCE.md`, `docs/realtime.md`.
