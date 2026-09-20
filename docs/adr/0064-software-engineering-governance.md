# ADR 0064: Software Engineering And Architecture Governance

## Status

Accepted. Converted on 2026-09-19 from `prompt/16.txt` ("GPForum — Software
Engineering, Architecture Governance & Development Constitution"); this ADR
replaces the prompt as the binding source.

## Context

GPForum is a long-term distributed systems project, a security-first
platform, an operationally sustainable architecture, and a Perl-native
engineering ecosystem. Without explicit governance, such a codebase drifts
towards god modules, framework leakage, and hidden debt.

This ADR fixes the engineering philosophy, architectural governance model,
repository organization, layering, code ownership, refactoring, review,
documentation, and long-term maintainability rules. It is foundational and
mandatory, and it governs every bounded context and every change to the
repository.

## Decision

### Cross-ADR Alignment

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

### Engineering Philosophy

- Engineering decisions MUST prioritize: maintainability; operational
  predictability; architectural coherence; explicitness; auditability;
  long-term sustainability.
- The project MUST avoid: accidental complexity; architecture drift;
  uncontrolled abstraction; framework-driven chaos; novelty-driven
  engineering.

### Architecture Governance Philosophy

- Architecture is authoritative.
- The platform MUST remain constitution-driven, invariant-aware, and
  operationally disciplined.
- All engineering decisions MUST comply with the constitutions (ADR 0049 to
  ADR 0101 since their conversion), ADRs, architectural constraints, and
  operational principles.
- No implementation convenience may override security, observability,
  scalability, or maintainability.

### Repository Philosophy

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

### Layering Philosophy

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

### Application Service Philosophy

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

### Naming Philosophy

- Names MUST remain explicit, descriptive, and semantically meaningful.
- Forbidden names: `Utils`, `Helpers`, `Common`, `Misc`, `Temp`.
- Preferred style: `CreateThread`, `PermissionEvaluator`, `SearchIndexer`,
  `NotificationDispatcher`.

### Module Size Philosophy

- Modules MUST remain bounded, understandable, and responsibility-focused.
- The architecture MUST avoid giant god modules, hidden coupling, and
  uncontrolled inheritance hierarchies.

### Complexity Philosophy

- Complexity MUST remain measurable, minimized, and decomposed.
- The platform MUST prioritize small composable units, explicit workflows,
  and predictable execution paths.
- Complexity accumulation MUST be treated as technical debt.

### Refactoring Philosophy

- Refactoring is mandatory.
- Refactoring MUST prioritize simplification, decomposition, invariant
  preservation, and operational clarity.
- Refactoring MUST NOT silently alter behavior, bypass tests, or bypass
  architectural rules.

### Technical Debt Philosophy

- Technical debt MUST remain visible, documented, reviewable, and
  intentionally accepted.
- Hidden architectural debt is prohibited.

### Architectural Drift Prevention

- The platform MUST actively resist uncontrolled coupling, framework
  leakage, abstraction sprawl, dependency explosion, and hidden
  infrastructure assumptions.
- Architectural consistency is mandatory.

### ADR Philosophy

- ADRs SHOULD exist for major architecture changes, persistence changes,
  infrastructure changes, protocol changes, and distributed systems
  behavior.
- ADRs MUST include context, decision, consequences, and alternatives
  considered.

### Documentation Philosophy

- Critical systems MUST remain documented.
- Documentation SHOULD include architectural intent, invariants, failure
  assumptions, operational expectations, and scaling assumptions.
- The platform MUST remain understandable by future maintainers.

### Code Review Philosophy

- Code review is mandatory.
- Reviews MUST evaluate correctness, architectural compliance, security,
  maintainability, observability, and scalability impact.
- Reviews MUST reject hidden complexity, unclear ownership, unsafe
  shortcuts, and undocumented architectural violations.

### Testing Philosophy

- Testing is mandatory engineering infrastructure.
- Critical workflows MUST support unit, integration, regression, and
  distributed systems testing.
- Testing MUST remain deterministic, reproducible, and automation-friendly.

### Engineering Ownership

- Ownership MUST remain explicit, reviewable, and operationally
  accountable.
- Critical systems SHOULD have maintainers, operational owners, and
  architectural stewards.

### Dependency Philosophy

- Dependencies MUST remain intentional, minimal, reviewed, and
  operationally justified.
- The platform MUST avoid dependency sprawl, abandoned libraries, and
  unnecessary frameworks.

### Backwards Compatibility

- Backwards compatibility SHOULD remain intentional, documented, and
  operationally evaluated.
- Breaking changes MUST remain explicit, support migration planning, and
  support rollback where feasible.

### Feature Development Philosophy

- Features MUST align with the architecture, preserve invariants, remain
  observable, and remain testable.
- Features MUST NOT bypass the constitutions, introduce hidden authority,
  or compromise operational sustainability.

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

### Build vs Buy Philosophy

- The platform SHOULD prefer mature stable primitives and avoid unnecessary
  reinvention.
- The platform MUST avoid framework worship, dependency-driven
  architecture, and novelty engineering.
- Technology choices MUST remain operationally justified and maintainable
  for years.

### Long-Term Engineering Goal

- The engineering culture MUST remain disciplined, constitution-driven,
  maintainable, security-focused, operationally sustainable, and
  architecturally coherent.
- Engineering is controlled long-term system design, not feature
  accumulation.
- All future development MUST comply with this ADR.

## Consequences

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
  `GPForum::Query`, `GPForum::Command`, and `GPForum::Jobs`
  (`GPForum::Application::LayerMap` records the layers actually in use).
- Open conflict: `docs/adr/0000-template.md` has no "Alternatives
  Considered" section although ADRs MUST include alternatives considered;
  most ADRs add an "Alternatives Rejected" section by hand. The template
  should gain that section.
- Open conflict: `t/09-prompt-alignment.t` slurps `prompt/16.txt` to assert
  the ADR 0098 alignment clause; it must be repointed to this ADR before the
  prompt files are deleted.

## Alignment

- ADR 0049 (foundational architecture), ADR 0052 (Perl engineering
  discipline), ADR 0059 (CI/CD and release engineering), ADR 0084 (test
  strategy), ADR 0087 (prompt governance and ADR evolution), ADR 0091
  (executable architecture contract), ADR 0093 (verifiable invariants),
  ADR 0096 (core boundary discipline), ADR 0098 (operational integrity).
- ADR 0016, ADR 0041 to ADR 0047: examples of thin-controller decision
  objects under `GPForum::Web::*`.
- `docs/adr/0000-template.md`, `docs/adr/README.md`
- `lib/GPForum/Application/LayerMap.pm`
- `script/architecture-check`, `.perlcriticrc`
- `t/34-architecture-discipline.t`, `t/75-architecture-foundation.t`,
  `t/09-prompt-alignment.t`
- `CONTRIBUTING.md`, `GOVERNANCE.md`, `.github/CODEOWNERS`,
  `.github/pull_request_template.md`
