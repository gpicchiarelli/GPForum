# ADR 0084: Test Strategy and Quality Verification

## Status

Accepted. Converted on 2026-09-19 from `prompt/36.txt` ("GPForum - Test
Strategy & Quality Verification Constitution"); this ADR replaces the prompt
as the binding source.

## Context

GPForum's correctness depends on authorization, privacy, event and worker
behavior that manual testing cannot reliably cover. The project treats tests
as executable architecture and needs mandatory rules for test architecture,
the quality verification matrix, test data, security regression coverage
and release validation. The rules govern every bounded context and the
release process.

## Decision

### Cross-ADR alignment

- ADR 0098 (execution constitution): tests MUST verify execution discipline,
  not only feature presence. Critical workflow tests SHOULD prove canonical
  state, event emission, audit emission, permission enforcement, projection
  behavior, failure mapping, rebuildability, replayability and operational
  scaling assumptions.

### Testing philosophy

Tests are executable architecture.

GPForum MUST test: domain invariants; authorization; persistence; event
workflows; security boundaries; rendering safety; operational commands;
profiling readiness; performance-critical paths.

- The platform MUST avoid relying on manual confidence for critical
  behavior.
- Tests MUST be perfectly mapped to GPForum requirements. "Perfectly
  covering" means every critical architectural, security, authorization,
  data, event, worker, privacy and operational requirement has an explicit
  verification strategy.

### Test layers

The test suite SHOULD include: unit tests; service tests; controller tests;
DB integration tests; authorization matrix tests; event consumer tests;
worker tests; template rendering tests; browser or HTMX workflow tests;
migration tests; load and capacity tests where appropriate; profiling tests;
coverage verification.

### Mandatory early tests

- Milestone 0 MUST include: app loads; health endpoints work; configuration
  validation works; logging initializes; database connection can be tested
  safely; Carton dependency installation works; profiling command exists;
  coverage command exists.
- Milestone 1 MUST include: registration; login; logout; session
  revocation; password hashing behavior; CSRF protection.

### Authorization tests

- Authorization tests MUST cover: anonymous access; member access; moderator
  scope; administrator scope; suspended users; banned users; locked threads;
  archived categories; hidden and quarantined content.
- Authorization regressions are release blockers.

### Security tests

Security regression tests SHOULD cover: XSS escaping; CSRF enforcement; SQL
injection resistance through parameterized paths; unsafe upload rejection;
session revocation; rate-limit behavior; password reset token safety.

### Coverage requirements

- Coverage verification MUST exist from the first implementation milestone.
- Coverage MUST track: statements; branches where tooling permits;
  authorization paths; error paths; worker retry paths; event consumer
  paths; security-sensitive paths.
- Coverage targets MUST be explicit per milestone.
- Critical flows SHOULD target complete requirement coverage, not only high
  numeric coverage.
- Uncovered critical requirements MUST block release.

### Event tests

Event tests MUST verify: event emission; idempotent consumer behavior;
replay safety; no duplicate external side effects on retry; projection
rebuild from event history.

### Profiling tests

- Profiling tests MUST verify that profiling can run.
- Profiling validation SHOULD include: Devel::NYTProf execution; profile
  artifact generation; request-path profiling smoke test; worker profiling
  smoke test; slow query timing capture where the database is available;
  memory growth smoke checks for long-running processes.
- Profiling failures in release validation MUST be treated as operational
  readiness failures.

### Test data

- Test data MUST be deterministic.
- Factories SHOULD generate: users; roles; categories; threads; posts;
  moderation states.
- Tests MUST NOT depend on production data.

### Release gates

- Release gates SHOULD include: formatting; Perl::Critic; Carton dependency
  validation; unit tests; integration tests; coverage validation; profiling
  smoke validation; migration validation; security checks; smoke tests.
- Failing release gates MUST block production deployment unless explicitly
  overridden by emergency procedure.

### Verifiable invariants amendment

- Testing MUST enforce ADR 0093.
- Every critical invariant MUST have either an automated test or a
  documented verification plan with release-gate consequences.
- The test suite MUST include negative tests for authorization, search
  leakage, moderation visibility, replay safety, plugin boundary failure and
  projection staleness where those features exist.
- Golden-path workflow tests MUST verify canonical writes,
  event/audit/outbox effects, projection handoff, metrics/logging
  expectations and classified error behavior.

### Accessibility testing amendment

- Testing MUST enforce ADR 0094.
- Critical user-facing routes SHOULD have automated accessibility checks
  where practical, including semantic HTML validation, contrast checks,
  keyboard smoke tests, and axe-core or pa11y scans.
- Accessibility tests MUST cover home, category, thread, composer, search,
  login/register, notifications, moderation and admin dashboard surfaces as
  those surfaces become implemented.

## Consequences

- Test coverage is measured against requirements, not only line counts, so
  every new critical rule in an ADR needs a matching test or verification
  plan.
- Authorization regressions, uncovered critical requirements and broken
  profiling block releases, which makes CI the enforcement point for
  architecture.
- Deterministic factories and no production data keep tests reproducible
  locally and in CI.

## Alignment

- ADRs: 0093, 0094 and 0098 (cross-alignment and amendments), 0059 (CI/CD
  and release engineering), 0070 (permission matrix), 0076 (bootstrap
  tests), 0089 (profiling and coverage automation).
- Scripts: `script/test`, `script/coverage`, `script/profile`,
  `script/perlcritic`, `script/perltidy-check`, `script/perl-syntax-check`,
  `Makefile`, `.github/workflows/ci.yml`.
- Tests: `t/` (suite), `t/integration/postgres.t`, `t/lib/GPForum/Test/`,
  `t/02-health.t`, `t/06-identity-web.t`, `t/26-admin-authorization.t`,
  `t/35-forum-accessible-ssr.t`, `t/48-browser-security.t`,
  `t/50-security-hardening.t`, `t/86-engineering-correctness.t`,
  `t/144-cpan-install.t`.
- Docs: `docs/ENGINEERING_CORRECTNESS.md`, `docs/PROFILING.md`.
