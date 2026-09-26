# ADR 0096: Core Boundary And Architectural Discipline Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/48.txt` ("GPForum - Core
Boundary And Architectural Discipline Constitution"); this ADR replaces the
prompt as the binding source.

## Context

This constitution defines mandatory hard architectural discipline for the
GPForum core, subsystems, plugins, capabilities, and feature growth. It is
mandatory.

Its purpose is to prevent GPForum from becoming an unmaintainable CMS-like
system with omnipotent plugins, hidden coupling, fragile runtime mutation,
and semi-broken features. It governs the core bounded contexts, the
controller layer, plugins and capabilities, caches, read models, and the
rendering model.

## Decision

### Execution Alignment

Prompt 50 alignment (ADR 0098): core boundary work MUST follow the execution
constitution. New behavior is incomplete unless it identifies canonical
state, emitted event, projection impact, audit record, affected indexes,
enforced permissions, failure modes, rebuildability, replayability, and
operational scaling.

### 1. Immutable Core Doctrine

- The GPForum core MUST remain small, stable, and boring.
- Core includes: identity; thread; post; revisions; moderation;
  permissions; audit; notifications; search; API; attachment; event log.
- Everything else is plugin, capability, or optional subsystem.
- If a feature is not universally necessary for a durable forum, it MUST
  remain outside core unless an ADR promotes it.
- Core changes require higher review discipline than optional subsystems.
- Core MUST NOT absorb every useful feature.

### 2. Controller Boundary Rule

- Controllers validate, authorize, dispatch, and render.
- Controllers MUST NOT contain business logic.
- Controllers MUST NOT directly manipulate DBIx::Class resultsets.
- Controllers MUST NOT become workflow containers.
- Domain behavior belongs in the service layer, domain modules, command
  handlers, policy engines, and persistence stores.

### 3. Append-Only Where It Matters

- Append-oriented records are mandatory where reversibility, forensics,
  replay, and accountability matter.
- Append-oriented workflows SHOULD be used for moderation, revisions,
  permissions, audit, security, sessions, and the event log.
- Append-only discipline supports debugging, replay, incident response,
  analytics, future federation, and governance accountability.

### 4. Lightweight CQRS Doctrine

- GPForum SHOULD use lightweight CQRS where it provides real operational
  value.
- CQRS is appropriate for: activity feed; notifications; metrics; search
  index; moderation queue; analytics.
- GPForum MUST NOT turn CQRS into architecture theater.
- GPForum MUST avoid: excessive buses; excessive projections; total event
  sourcing of every entity; indirection without measurable benefit.
- Canonical state remains PostgreSQL-first.
- Read models remain derived and rebuildable.

### 5. Plugin Capability Discipline

- Plugins MUST declare capabilities.
- Plugins MUST use stable APIs.
- Plugins MUST NOT access arbitrary core database state directly.
- Plugins MUST NOT patch runtime behavior arbitrarily.
- Plugins SHOULD extend through: hook registry; event subscription; API
  contracts; capability-scoped services; isolated schema migrations.
- Plugin migrations MUST remain reviewable, reversible where feasible, and
  scoped.
- Plugins MUST NOT become required for core correctness unless promoted
  into core through ADR and tests.

### 6. PostgreSQL As Platform

- PostgreSQL is GPForum's authoritative platform.
- GPForum SHOULD use PostgreSQL seriously: JSONB where useful; full-text
  search; partitioning; materialized views for admin/reporting where
  appropriate; generated columns; LISTEN/NOTIFY where justified; logical
  schema separation; constraints and indexes as correctness tools.
- GPForum MUST avoid: premature microservices; mandatory Redis; OpenSearch
  as a default requirement; unnecessary extra datastores; distributed
  complexity without ADR.

### 7. Cache Discipline

- Cache MUST be derived, rebuildable, sacrificial, and optional for
  correctness.
- Cache MUST NEVER be the sole source of truth.
- Cache invalidation failures MUST degrade safely.

### 8. SSR-First UI Discipline

- GPForum MUST remain SSR-first.
- Mojolicious and Perl are first-class for server-rendered pages,
  progressive enhancement, HTMX-like interaction, accessibility, perceived
  speed, and graceful degradation.
- GPForum MUST NOT begin with a mandatory SPA architecture.
- JavaScript may enhance, but core forum usage MUST remain server-driven
  where feasible.

### 9. Moderation As Primary System

- Moderation MUST be present from the beginning.
- GPForum MUST treat moderation as core infrastructure, not a later
  feature.
- Mandatory moderation foundations: audit log; moderation queue; soft
  delete; revision history; escalation; policy engine.
- Shadow-ban or quarantine features require explicit policy and audit
  discipline.
- Moderation authority remains server-authoritative.

### 10. Living But Enforced Constitution

- The architecture constitution MUST remain alive, short enough to use, and
  enforced by tests and gates.
- GPForum MUST maintain: ADRs; boundary rules; forbidden dependency checks;
  coupling review; governance documents; ADR alignment tests (formerly
  prompt alignment tests).
- Constitutional documents SHOULD be operational and enforceable.
- Unenforced philosophy MUST be converted into tests, scripts, review
  gates, or explicit ADR risk.

### 11. Failure Mode

- If GPForum loses this discipline, it will become a chaotic CMS, a
  plugin-hostile or plugin-captured platform, an unbounded schema, a fragile
  runtime, and a system full of semi-broken features.
- If GPForum preserves this discipline, it can remain robust, extensible,
  long-lived, operable, understandable, and humane.

## Consequences

- Feature growth goes to plugins, capabilities, or optional subsystems by
  default; promoting anything into core needs an ADR and tests.
- ADR 0093 treats controller business logic, plugin omnipotence, cache
  authority, projection authority, and core feature sprawl as engineering
  invariant violations, blocked by review and automated checks where
  feasible.
- Plugins lose direct database and runtime-patching access, which limits
  what they can do but keeps core upgrades safe.
- CQRS and append-only records are used where they pay off, not everywhere,
  so projections stay few and rebuildable.
- ADR 0048 makes GlifiStore a required shared L2 in staging and production;
  this stays within this constitution because it is ADR-approved and the
  cache remains disposable, fail-open, and never authoritative.

## Alignment

- Related ADRs: ADR 0091, ADR 0093, ADR 0098, ADR 0083 (plugins),
  ADR 0064 (architecture governance), ADR 0067 (cache and Redis decision),
  ADR 0054 (frontend rendering), ADR 0057 (authorization and moderation).
- Existing ADRs: 0001 (SSR UI system), 0002 (bootstrap boundaries), 0005
  (posting workflow boundary), 0006 (LISTEN/NOTIFY realtime transport),
  0010 (moderation workflow), 0016 (shared HTTP access), 0048 (GlifiStore
  L2).
- Code: `lib/GPForum/Controller/`,
  `lib/GPForum/Service/Plugin/`,
  `lib/GPForum/Service/Operations/LocalCache.pm`,
  `lib/GPForum/Service/Operations/TieredCache.pm`,
  `lib/GPForum/Service/Operations/CacheFactory.pm`.
- Tests: `t/34-architecture-discipline.t`, `t/75-architecture-foundation.t`,
  `t/86-engineering-correctness.t`, `t/28-plugins.t`, `t/40-local-cache.t`,
  `t/89-tiered-cache.t`, `t/142-cache-factory.t`,
  `t/09-prompt-alignment.t`.
- Scripts and docs: `script/architecture-check`, `GOVERNANCE.md`,
  `ARCHITECTURE.md`, `docs/ENGINEERING_CORRECTNESS.md`.
