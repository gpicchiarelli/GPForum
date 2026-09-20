# ADR 0068: MVP Roadmap And Implementation Sequencing

## Status

Accepted. Converted on 2026-09-19 from `prompt/20.txt` ("GPForum - MVP
Roadmap & Implementation Sequencing Constitution"); this ADR replaces the
prompt as the binding source.

## Context

A platform with this many constitutions can easily build distributed
machinery before a forum exists. This ADR fixes the mandatory
implementation order, MVP scope, release milestones, and sequencing
discipline. It is mandatory for project planning and spans every bounded
context in the order they become available.

## Decision

### Cross-ADR Alignment

- ADR 0093: milestone completion MUST include verifiable invariants,
  contract tests, observability, prompt alignment, migration/replay notes,
  and release-gate evidence. A milestone is not complete if its guarantees
  are only stated and not mechanically checked where feasible.

### Roadmap Philosophy

- GPForum MUST be built incrementally.
- The project MUST avoid:
  - building distributed complexity before core forum behavior exists;
  - optimizing projections before canonical writes exist;
  - implementing advanced governance before basic moderation exists;
  - adding optional integrations before stable domain workflows exist.
- Each milestone MUST produce a working, testable system.

### Milestone 0 - Project Skeleton

- MUST deliver: Mojolicious application skeleton; configurable
  multi-process runtime profile; DBIx::Class schema structure; PostgreSQL
  connection; migration framework; configuration loading; structured
  logging; health endpoint; basic CI checks; Perl::Critic configuration;
  Carton dependency automation; coverage command; profiling command.
- No product feature should bypass this foundation.

### Milestone 1 - Identity And Sessions

- MUST deliver: user registration; login; logout; secure password hashing;
  session creation; session revocation; CSRF protection; account status
  checks; minimal profile page.
- SHOULD include: email verification placeholder; MFA-ready credential
  model; audit events for login and logout.

### Milestone 2 - Core Forum

- MUST deliver: spaces; categories; thread creation; post creation; thread
  view; category view; pagination; server-rendered composer; post
  revisions for edits; soft deletion primitives.
- This milestone is the first real GPForum product surface.

### Milestone 3 - Authorization And Moderation

- MUST deliver: RBAC baseline; ABAC ownership checks; moderator role;
  admin role; lock/unlock thread; hide/unhide post; move thread; report
  content; moderation audit log; suspended users cannot post.
- Moderation MUST be server-authoritative.

### Milestone 4 - Events And Workers

- MUST deliver: durable event table; event emission from core workflows;
  Minion integration; idempotent job pattern; notification job
  placeholder; search indexing job placeholder; cache invalidation signal
  placeholder.
- No asynchronous workflow may become authoritative before this milestone
  is stable.

### Milestone 5 - Notifications And Subscriptions

- MUST deliver: thread subscriptions; notification preferences;
  notification creation; notification list; notification read state;
  digest-ready data model; asynchronous fanout.
- Notifications MUST respect permissions at creation and render time.

### Milestone 6 - Search

- MUST deliver: PostgreSQL full-text search integration; pg_trgm-backed
  autocomplete where appropriate; indexing worker; rebuild command;
  permission-aware search filtering; basic thread/post search; search
  observability.
- Search MUST remain derived and rebuildable.

### Milestone 7 - Realtime

- MUST deliver: authenticated websocket connections; authorized channel
  subscription; thread update notifications; notification badge updates;
  reconnect behavior; graceful fallback without websocket.
- Realtime MUST NOT be required for core forum usability.

### Milestone 8 - Attachments

- MUST deliver: upload intent; object storage integration; file
  validation; malware scanning hook; media processing job; attachment
  moderation; attachment lifecycle.
- Uploads MUST remain non-executable and permission-aware.

### Milestone 9 - Operations Hardening

- MUST deliver: backup/restore runbook validation; deployment rollback
  validation; metrics dashboards; alert rules; process pool sizing
  validation; worker concurrency validation; profiling artifact
  validation; coverage threshold validation; rate limiting; abuse
  mitigation; retention jobs; disaster recovery rehearsal.

### Milestone 10 - Advanced Community Features

- MAY deliver: trust scoring; reputation; advanced feeds; user mentions;
  bookmarks; advanced admin console; federation experiments;
  import/export tooling.
- These features MUST NOT compromise the core architecture.

### Sequencing Rule

- No milestone may depend on a later milestone for correctness.
- Every milestone MUST preserve security, auditability, testability,
  migration safety, and operational visibility.

## Consequences

- Each milestone is shippable and testable on its own; later milestones
  add capability without being needed for earlier correctness.
- Optional integrations (Redis/KeyDB, external search, federation) wait
  until domain workflows are stable, which delays some performance work
  but keeps canonical writes simple.
- Milestone sign-off needs mechanical evidence (tests, checks, release
  gates) per ADR 0093, not only a feature list.
- Open conflict: `README.md` and `ROADMAP.md` state that GPForum "has
  reached Milestone 17 — Forum HTTP MVP" under this roadmap, but this ADR
  defines only Milestones 0 to 10. Either the later milestone numbering
  needs its own ADR or the status text should be mapped back to
  Milestones 0 to 10.
- Open conflict: `ROADMAP.md` and `README.md` link `prompt/20.txt` (and
  `prompt/43.txt`) as the roadmap source; they must point to this ADR (and
  ADR 0091) once the prompt files are deleted.

## Alignment

- ADR 0049 (foundational architecture), ADR 0059 (CI/CD and release
  engineering), ADR 0076 (bootstrap implementation), ADR 0084 (test
  strategy), ADR 0091 (executable architecture contract; the roadmap must
  stay consistent with it), ADR 0093 (verifiable invariants).
- Milestone scope details: ADR 0053 (security), ADR 0055 (realtime),
  ADR 0056 (workers), ADR 0057 and ADR 0070 (authorization and
  moderation), ADR 0062 and ADR 0090 (search), ADR 0065 (community
  operations), ADR 0069 (schema), ADR 0071 (events), ADR 0075
  (runbooks), ADR 0078 (notifications), ADR 0081 (import/export).
- `ROADMAP.md`, `README.md`, `docs/MVP.md`, `docs/PRODUCTION_READINESS.md`,
  `docs/release/readiness-review.md`
- `script/coverage`, `script/profile`, `script/perlcritic`,
  `script/gpforum-carton`, `bin/gpforum-migrate`, `.perlcriticrc`,
  `.github/workflows/ci.yml`
- `t/02-health.t`, `t/16-workers-phase.t`, `t/17-notifications.t`,
  `t/19-search.t`, `t/20-realtime.t`, `t/22-attachments.t`,
  `t/23-operations-hardening.t`, `t/24-advanced-community.t`,
  `t/61-mvp-user-flow.t`
