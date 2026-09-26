# ADR 0049: Foundational Architecture Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/1.txt` ("GPForum —
Foundational Architecture Constitution"); this ADR replaces the prompt as the
binding source.

## Context

GPForum (General Purpose Forum) is a Perl-native distributed community
platform designed for extreme scalability, security, maintainability,
modularity, and long-term operational sustainability.

The source opened with an Italian preamble stating that it is the founding
prompt: it is not meant to generate code immediately but to fix the technical
constitution of the project, and it is to be used as `000-foundation.md`, as
the initial master prompt, and as the permanent baseline for AI-assisted code
generation.

It governs every bounded context and layer: application root, persistence,
events, security, Perl code, frontend, themes, realtime, workers,
observability, and scaling. ADR 0050 to ADR 0053 refine infrastructure,
database, Perl engineering, and security.

## Decision

The project MUST follow these principles permanently.

### Core Philosophy

- GPForum is NOT: a legacy monolithic forum; a PHP-style page-oriented
  application; a microservice explosion; a JavaScript SPA-first platform.
- GPForum IS: a distributed modular monolith; event-driven; security-first;
  Perl-first; append-oriented; horizontally scalable; realtime-capable;
  operationally sustainable.
- The architecture must prioritize: simplicity over hype; deterministic
  behavior; observability; auditability; low operational entropy; strict
  coding discipline.

### Technology Stack

- Mandatory stack: Perl (modern Perl only); Mojolicious; DBIx::Class;
  PostgreSQL; Minion; Nginx or HAProxy.
- Optional acceleration infrastructure: Redis or KeyDB.
- The platform MUST remain Perl-native.
- Avoid polyglot architecture unless strictly unavoidable.

### Architecture Style

- The system MUST be implemented as: a distributed modular monolith;
  stateless application nodes; a multi-process Perl runtime; event-driven
  internal workflows; an append-oriented persistence strategy.
- Application nodes MUST: be disposable; support horizontal scaling; support
  dynamic process scaling per node; avoid local persistent state; avoid local
  sessions; avoid local authoritative caches.
- Application root classes MUST remain composition roots only. They MUST NOT
  become god class applications.
- The application root MAY: load configuration; register routes; register
  helpers; wire dependency boundaries; attach middleware; start observability
  hooks.
- The application root MUST NOT: contain business logic; contain
  authorization policy logic; contain persistence orchestration; contain
  search orchestration; contain queue workflow logic; contain websocket
  workflow logic; contain moderation workflow logic; directly implement domain
  use cases.
- If the application root grows beyond wiring, the behavior MUST be moved into
  controllers, application services, domain services, infrastructure
  adapters, or runtime modules with explicit ownership.
- Shared state MUST reside in PostgreSQL and object storage.
- Search MUST be PostgreSQL-native by default through full-text search,
  trigram indexes, and Perl orchestration.
- External search engines MAY be added only as optional acceleration through
  ADR.
- Redis/KeyDB MAY be used only as optional ephemeral acceleration.

### Database Philosophy

- PostgreSQL is the system of record.
- The database architecture MUST: support partitioning from day zero; avoid
  giant mutable tables; prefer append-only patterns; support retention
  policies; support CQRS-lite read models; minimize destructive UPDATE and
  DELETE operations.
- Mandatory database characteristics: UUIDv7 identifiers; partitioned event
  tables; append-only `event_log`; immutable audit records; migration-driven
  schema evolution.
- The system MUST be designed for multi-year growth without manual database
  maintenance crises.

### Event-Driven Model

- All significant actions MUST emit events. Examples: `thread.created`,
  `post.created`, `post.edited`, `user.banned`, `notification.sent`.
- An append-only `event_log` MUST exist.
- Events MUST be: immutable; timestamped; traceable; replayable when possible.

### Security Constitution

- Security is mandatory and foundational.
- Mandatory requirements: Argon2id password hashing; WebAuthn support; TOTP
  support; CSP enforcement; HSTS; SameSite cookies; strict input validation;
  HTML sanitization; append-only audit trails; RBAC + ABAC hybrid
  permissions.
- The system MUST assume hostile input at all times.
- No user-controlled HTML, JavaScript, or template execution may bypass
  sanitization.

### Perl Coding Discipline

- The project MUST enforce maximum Perl::Critic discipline.
- Mandatory: `use strict`; `use warnings`; lexical variables only; no package
  variables; no string eval; no two-argument open; explicit argument
  unpacking; limited McCabe complexity; deterministic error handling.
- Perl native signatures SHOULD be avoided unless explicitly justified.
- Business logic MUST NOT exist in templates.
- Controllers MUST remain thin.

### Frontend Philosophy

- Frontend architecture MUST prioritize: server-side rendering; simplicity;
  performance; accessibility; long-term maintainability.
- Preferred frontend strategy: SSR; HTMX; minimal JavaScript; Alpine.js when
  necessary.
- The platform MUST avoid SPA-first complexity unless strictly required.

### Theme System

- Themes are presentation-only.
- Themes MUST NOT: execute arbitrary Perl; access the database directly;
  contain business logic; bypass security controls.
- Themes MUST support: inheritance; design tokens; component overrides; asset
  versioning.

### Realtime Architecture

- Realtime features MUST: support distributed websocket nodes; avoid
  centralized bottlenecks; support pub/sub synchronization; use asynchronous
  event propagation.

### Worker Architecture

- Long-running or slow operations MUST execute asynchronously. Examples:
  email; indexing; moderation; analytics; media processing; notifications.
- Minion workers MUST support: retries; idempotency; distributed execution.

### Observability

- The system MUST expose: structured logs; metrics; tracing; correlation IDs;
  audit trails.
- Operational visibility is mandatory.

### Scaling Philosophy

- Scaling MUST prioritize: horizontal scalability; Perl process multiplicity;
  dynamic worker pool sizing; cache efficiency; asynchronous processing;
  read/write separation; partition-aware queries.
- The architecture MUST assume: millions of users; distributed deployments;
  multi-node synchronization.
- The application tier MUST scale by increasing: Perl web processes; Perl
  worker processes; Perl realtime processes; application nodes.

### Long-Term Engineering Philosophy

- GPForum is intended to be: maintainable for decades; operationally
  sustainable; highly auditable; security-focused; architecturally coherent.
- All future code generation, modules, APIs, database structures, workers,
  themes, and services MUST comply with this constitution.

## Consequences

- Every later ADR inherits this baseline; conflicting designs need an
  explicit superseding ADR rather than silent drift.
- The mandatory stack keeps the runtime Perl-native and limits operational
  moving parts; polyglot or SPA-first proposals start from a rejected
  position.
- Partitioning from day zero, UUIDv7 identifiers, and append-only event and
  audit storage add schema and runbook work up front in exchange for
  multi-year growth without maintenance crises.
- Stateless, disposable nodes push all shared state to PostgreSQL and object
  storage, so scaling is by adding Perl processes and nodes.
- Open conflicts:
  - ADR 0048 makes GlifiStore a required shared L2 cache in staging and
    production. This ADR lists only Redis/KeyDB as optional acceleration and
    places shared state in PostgreSQL and object storage. GlifiStore stays
    non-authoritative, so the tension is about mandatory infrastructure, not
    the source of truth.
  - WebAuthn and TOTP are mandatory here, while ADR 0053 marks
    WebAuthn/passkeys as SHOULD. The repository has no WebAuthn or TOTP
    implementation yet (`GPForum::Schema::Result::Credential` only mentions
    future MFA credentials).
  - HSTS is mandatory, but neither `GPForum::Security::BrowserHeaders` nor
    the shipped `deploy/nginx` and `deploy/caddy` configurations emit
    `Strict-Transport-Security`.
  - Attachments are written by
    `GPForum::Service::Attachment::FilesystemStorage` under
    `var/attachments`, not to object storage.
  - The mandatory edge is "Nginx or HAProxy", but `docs/DEPLOYMENT.md` and
    `deploy/caddy/Caddyfile` also document Caddy as the reverse proxy.

## Alignment

- ADR 0050 (infrastructure), ADR 0051 (database), ADR 0052 (Perl
  engineering), ADR 0053 (security).
- ADR 0054 (frontend and themes), ADR 0055 (events and realtime), ADR 0056
  (workers), ADR 0057 (authorization), ADR 0058 (observability), ADR 0062
  (search), ADR 0063 (performance), ADR 0067 (cache and Redis), ADR 0088
  (multi-process runtime), ADR 0096 (core boundary discipline).
- ADR 0001 (SSR UI system), ADR 0002 (bootstrap boundaries), ADR 0006
  (LISTEN/NOTIFY realtime transport), ADR 0012 (operational profiles and
  partition lifecycle), ADR 0048 (mandatory GlifiStore L2).
- `lib/GPForum.pm`, `lib/GPForum/Bootstrap/`, `lib/GPForum/Infrastructure/Id.pm`,
  `lib/GPForum/Service/Password.pm`,
  `lib/GPForum/Security/BrowserHeaders.pm`,
  `migrations/002_event_audit.sql`, `cpanfile`, `.perlcriticrc`.
- `t/75-architecture-foundation.t`, `t/73-bootstrap-composition.t`,
  `t/34-architecture-discipline.t`, `t/143-service-id.t`,
  `t/48-browser-security.t`.
- `ARCHITECTURE.md`, `THEMING.md`, `docs/DEPLOYMENT.md`.
