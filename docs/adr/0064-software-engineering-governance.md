# ADR 0064: Software Engineering And Architecture Governance

## Status

Accepted. Amended by ADR 0107, which names the layers the code actually
has and makes the dependency direction a checked rule.

## Date

2026-09-19

## Context

GPForum needs explicit engineering governance to keep modules bounded,
prevent framework dependencies from crossing architectural boundaries, and
make technical debt visible in a distributed Perl platform.

This ADR fixes the engineering principles, architectural governance model,
repository organization, layering, code ownership, refactoring, review,
documentation, and long-term maintainability rules. It is foundational and
mandatory, and it governs every bounded context and every change to the
repository.

## Decision

### Related Architecture Requirements

- ADR 0093: architecture MUST be preserved through verifiable invariants,
  explicit contracts, release gates, migration discipline, and architecture
  checks; intent alone is insufficient. Every new bounded context, store,
  worker, plugin hook, projection, or authoritative workflow MUST document
  its invariants and testing expectations.
- ADR 0096: the core MUST remain small and stable. Features that are not
  universally necessary belong in plugins, capabilities, or optional
  subsystems. Controllers MUST validate, authorize, dispatch, and render
  only. Plugin capability boundaries, cache disposability, PostgreSQL
  authority, and moderation-as-core are mandatory architectural discipline.
- ADR 0098: every change MUST preserve core operational integrity. Each
  workflow change MUST identify canonical state, emitted events, projection
  effects, audit records, affected indexes, enforced permissions, failure
  modes, rebuildability, replayability, and operational scaling before it is
  accepted.

### Engineering Principles

- Engineering decisions MUST prioritize: maintainability; operational
  predictability; architectural coherence; explicitness; auditability;
  long-term sustainability.
- The project MUST avoid: accidental complexity; architecture drift;
  uncontrolled abstraction; framework-driven chaos; novelty-driven
  engineering.

### Architecture Governance Principles

- Architecture is authoritative.
- The platform MUST follow architectural decisions, preserve invariants, and
  remain operationally disciplined.
- All engineering decisions MUST comply with ADRs, including ADR 0049 to
  ADR 0101, architectural constraints, and operational principles.
- No implementation convenience may override security, observability,
  scalability, or maintainability.

### Repository Principles

- The repository is a long-lived engineering artifact, an operational
  system, and an architectural contract.
- It MUST remain structured, predictable, navigable, and auditable.
- It MUST avoid dumping grounds, uncontrolled helpers, and architectural
  ambiguity.

### Recommended Repository Structure

- Recommended layout: `apps/`, `bin/`, `conf/`, `docs/`, `lib/`, `sql/`,
  `themes/`, `assets/`, `t/`, `tools/`.
- Recommended Perl namespaces: `GPForum::Domain`, `GPForum::Application`,
  `GPForum::Infrastructure`, `GPForum::Web`, `GPForum::Realtime`,
  `GPForum::Worker`, `GPForum::Security`, `GPForum::Search`.

### Layering Principles

- The platform MUST maintain explicit architectural layers.
- Recommended layering: Domain, Application, Infrastructure,
  Transport/Delivery, Rendering.
- Dependencies MUST flow inward.
- Business logic MUST remain infrastructure-independent.

### Domain Isolation

- The domain layer MUST remain persistence-independent,
  transport-independent, and rendering-independent.
- The domain layer MUST NOT depend on Mojolicious, DBIx::Class internals,
  HTTP details, or websocket transport logic.

### Infrastructure Isolation

- Infrastructure concerns MUST remain isolated. Examples: database access;
  optional Redis/KeyDB access; PostgreSQL-native search integration;
  optional external search integration; filesystem integration; object
  storage integration.
- Infrastructure MUST remain replaceable, bounded, and operationally
  explicit.

### Application Service Principles

- Application services SHOULD orchestrate workflows, enforce use-case
  boundaries, and coordinate infrastructure interaction.
- Application services MUST NOT become giant god services or absorb
  unrelated workflows.
- Application root classes MUST NOT compensate by becoming god class
  applications. The root application class MUST wire application services,
  not replace them.

### Thin Controller Rule

- Controllers MUST remain thin, orchestration-oriented, validation-aware,
  and authorization-aware.
- Controllers MUST NOT contain business logic, contain persistence
  orchestration, or implement hidden workflow complexity.

### Naming Principles

- Names MUST remain explicit, descriptive, and semantically meaningful.
- Forbidden names: `Utils`, `Helpers`, `Common`, `Misc`, `Temp`.
- Preferred style: `CreateThread`, `PermissionEvaluator`, `SearchIndexer`,
  `NotificationDispatcher`.

### Module Size Principles

- Modules MUST remain bounded, understandable, and responsibility-focused.
- The architecture MUST avoid giant god modules, hidden coupling, and
  uncontrolled inheritance hierarchies.

### Complexity Principles

- Complexity MUST remain measurable, minimized, and decomposed.
- The platform MUST prioritize small composable units, explicit workflows,
  and predictable execution paths.
- Complexity accumulation MUST be treated as technical debt.

### Refactoring Principles

- Refactoring is mandatory.
- Refactoring MUST prioritize simplification, decomposition, invariant
  preservation, and operational clarity.
- Refactoring MUST NOT silently alter behavior, bypass tests, or bypass
  architectural rules.

### Technical Debt Principles

- Technical debt MUST remain visible, documented, reviewable, and
  intentionally accepted.
- Hidden architectural debt is prohibited.

### Architectural Drift Prevention

- The platform MUST actively resist uncontrolled coupling, framework
  leakage, abstraction sprawl, dependency explosion, and hidden
  infrastructure assumptions.
- Architectural consistency is mandatory.

### ADR Principles

- ADRs SHOULD exist for major architecture changes, persistence changes,
  infrastructure changes, protocol changes, and distributed systems
  behavior.
- ADRs MUST include context, decision, consequences, and alternatives
  considered.

### Documentation Principles

- Critical systems MUST remain documented.
- Documentation SHOULD include architectural intent, invariants, failure
  assumptions, operational expectations, and scaling assumptions.
- The platform MUST remain understandable by future maintainers.

### Code Review Principles

- Code review is mandatory.
- Reviews MUST evaluate correctness, architectural compliance, security,
  maintainability, observability, and scalability impact.
- Reviews MUST reject hidden complexity, unclear ownership, unsafe
  shortcuts, and undocumented architectural violations.

### Testing Principles

- Testing is mandatory engineering infrastructure.
- Critical workflows MUST support unit, integration, regression, and
  distributed systems testing.
- Testing MUST remain deterministic, reproducible, and automation-friendly.

### Engineering Ownership

- Ownership MUST remain explicit, reviewable, and operationally
  accountable.
- Critical systems SHOULD have maintainers, operational owners, and
  architectural stewards.

### Dependency Principles

- Dependencies MUST remain intentional, minimal, reviewed, and
  operationally justified.
- The platform MUST avoid dependency sprawl, abandoned libraries, and
  unnecessary frameworks.

### Backwards Compatibility

- Backwards compatibility SHOULD remain intentional, documented, and
  operationally evaluated.
- Breaking changes MUST remain explicit, support migration planning, and
  support rollback where feasible.

### Feature Development Principles

- Features MUST align with the architecture, preserve invariants, remain
  observable, and remain testable.
- Features MUST NOT bypass architectural decisions, introduce hidden
  authority, or compromise operational sustainability.

### Security Engineering

- Security is an engineering requirement.
- All development MUST minimize attack surface, validate input, preserve
  auditability, and preserve authorization integrity.
- Security shortcuts are prohibited.

### Operational Awareness

- Engineers MUST consider deployment behavior, rollback behavior,
  observability impact, scaling impact, replay behavior, and failure modes.
- Operational sustainability is part of engineering quality.

### Distributed Systems Awareness

- All engineering MUST assume node failure, retries, replay, eventual
  consistency, propagation delay, and asynchronous execution.
- Distributed assumptions MUST remain explicit.

### Build vs Buy Principles

- The platform SHOULD prefer mature stable primitives and avoid unnecessary
  reinvention.
- The platform MUST avoid framework worship, dependency-driven
  architecture, and novelty engineering.
- Technology choices MUST remain operationally justified and maintainable
  for years.

### Long-Term Engineering Goal

- The engineering culture MUST remain disciplined, guided by architectural
  decisions, maintainable, security-focused, operationally sustainable, and
  architecturally coherent.
- Engineering is controlled long-term system design, not feature
  accumulation.
- All future development MUST comply with this ADR.

## Consequences

- `t/09-architecture-documentation.t` checks ADR structure, index navigation,
  and references to repository artifacts.
- Every change carries a governance cost: invariants, tests, review, and
  documentation are part of "done", not follow-up work.
- Layering and naming rules keep modules small and navigable; reviewers
  have explicit grounds to reject god modules, helper dumps, and framework
  leakage.
- Some rules are mechanically checked (`script/architecture-check` for
  controller persistence, template logic, cache/projection authority
  language, and dependency cycles; Perl::Critic; `t/34` and `t/75`
  architecture tests); the forbidden-name list and most review criteria are
  enforced by review only.
- The recommended layout and namespaces are guidance, not a hard contract.
  The repository currently uses `migrations/`, `etc/`, and `script/` instead
  of `sql/`, `conf/`, and `tools/`, has no `apps/`, and places most
  application code under `GPForum::Service::*`, `GPForum::Controller`,
  `GPForum::Command`, and `GPForum::Jobs`.
- Open conflict: `docs/adr/0000-template.md` has no "Alternatives
  Considered" section although ADRs MUST include alternatives considered;
  most ADRs add an "Alternatives Rejected" section by hand. The template
  should gain that section.

## Related Decisions and Implementation

- ADR 0049 (foundational architecture), ADR 0052 (Perl engineering
  discipline), ADR 0059 (CI/CD and release engineering), ADR 0084 (test
  strategy), ADR 0087 (architecture governance and ADR evolution), ADR 0091
  (executable architecture contract), ADR 0093 (verifiable invariants),
  ADR 0096 (core boundary discipline), ADR 0098 (operational integrity).
- ADR 0016, ADR 0041 to ADR 0047: examples of thin-controller decision
  objects under `GPForum::Web::*`.
- `docs/adr/0000-template.md`, `docs/adr/README.md`
- `script/architecture-check`, `.perlcriticrc`
- `t/34-architecture-discipline.t`, `t/75-architecture-foundation.t`,
  `t/09-architecture-documentation.t`
- `CONTRIBUTING.md`, `GOVERNANCE.md`, `.github/CODEOWNERS`,
  `.github/pull_request_template.md`
