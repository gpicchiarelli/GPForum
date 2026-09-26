# ADR 0059: CI/CD, Quality Assurance and Release Engineering

## Status

Accepted. Converted on 2026-09-19 from `prompt/11.txt` ("GPForum — CI/CD,
Quality Assurance & Release Engineering Constitution"); this ADR replaces the
prompt as the binding source.

## Context

GPForum is a long-lived, distributed Perl platform. Delivery must be
deterministic, reproducible, auditable and reversible, or every other
architectural rule erodes through untested releases and environment drift.

This ADR is foundational and mandatory. It defines the continuous integration
architecture, quality assurance standards, release engineering discipline,
deployment validation model, automated testing philosophy, dependency
governance, build reproducibility requirements and operational delivery
standards. It governs the CI pipeline, the Carton dependency toolchain, test
suites, migrations, build artifacts, environments, configuration, secrets and
every release and deployment workflow. Delivery pipelines are part of the
platform architecture.

## Decision

### Release Engineering Philosophy

- GPForum MUST prioritize deterministic releases, operational safety,
  reproducibility, rollback capability, deployment auditability and long-term
  maintainability.
- The platform MUST avoid uncontrolled deployments, manual production
  patching, untested releases, environment drift and hidden operational
  changes.
- Release engineering is a core architectural discipline.

### CI/CD Philosophy

- CI/CD pipelines MUST enforce architectural discipline, security policies,
  test coverage and reproducibility, and MUST remain observable.
- The pipeline is authoritative.
- Code MUST NOT bypass automated validation, security scanning, critic
  enforcement or testing workflows.

### Mandatory Pipeline Stages

- Every pipeline MUST minimally include:
  1. dependency validation;
  2. static analysis;
  3. formatting validation;
  4. test execution;
  5. coverage validation;
  6. profiling smoke validation;
  7. security scanning;
  8. artifact creation;
  9. deployment validation.
- No production deployment MAY bypass pipeline validation.

### Build Reproducibility

- Builds MUST remain deterministic, reproducible and environment-controlled.
- Dependencies MUST remain pinned where appropriate, auditable and versioned,
  and MUST be reproducible through Carton.
- Carton is the mandatory Perl dependency manager for GPForum.
- The repository MUST maintain `cpanfile`, `cpanfile.snapshot` after
  dependency installation, scripted dependency installation, and a CI
  dependency cache where safe.
- The system MUST minimize environment drift, dependency ambiguity and
  uncontrolled upgrades.

### Perl::Critic Enforcement

- Perl::Critic is mandatory.
- CI pipelines MUST fail on critic violations and MUST enforce severity rules,
  maintainability discipline and security discipline.
- Critic exceptions MUST remain explicit, documented and reviewable.

### Static Analysis

- Mandatory static validation: Perl::Critic, syntax validation, dependency
  analysis, security linting.
- Static analysis MUST execute automatically, consistently and on every merge
  workflow.

### Formatting Discipline

- Code formatting MUST remain consistent, predictable and review-friendly.
- Formatting SHOULD minimize review noise and support readability and
  maintainability.
- Formatting MUST NOT become developer-specific.

### Dependency Governance

- Dependencies MUST remain reviewed, maintained, version-aware and
  security-audited.
- The platform MUST avoid abandoned dependencies, unnecessary dependencies and
  hidden transitive risk.
- Dependency additions MUST remain reviewable, justified and operationally
  sustainable.

### Test Philosophy

- Testing is mandatory.
- The platform MUST support unit, integration, authorization, regression,
  security, distributed workflow, coverage and profiling tests.
- Critical workflows MUST remain continuously testable.
- Test coverage MUST be mapped to architectural requirements.
- Coverage gaps in critical workflows are release blockers.

### Unit Testing

- Unit tests MUST remain deterministic and isolated, and MUST avoid external
  side effects.
- Business logic MUST remain unit-testable.

### Integration Testing

- Integration tests MUST validate database interaction, queue interaction,
  websocket behavior, authorization flows, event propagation and distributed
  workflows.
- Distributed systems assumptions MUST remain testable.

### Security Testing

- Mandatory security validation SHOULD include authorization testing, input
  fuzzing, CSRF validation, XSS validation, rate-limit testing, session
  validation and abuse testing.
- Security regressions MUST block release workflows.

### Coverage Philosophy

- Coverage is mandatory for critical behavior.
- Coverage validation MUST include:
  - statement coverage;
  - branch coverage where practical;
  - condition coverage for authorization and security logic;
  - workflow coverage for user-facing paths;
  - event and worker coverage.
- Coverage numbers MUST NOT replace review of requirement coverage.
- Critical workflows MUST have explicit tests tied to their prompt
  requirements (now recorded in ADRs 0049-0101).

### Profiling Philosophy

- Profiling is mandatory.
- CI and release workflows SHOULD support Devel::NYTProf profiling runs,
  request-path profiling, worker profiling, DB query timing capture, memory
  growth checks and startup time checks.
- Profiling MUST be available before production incidents require it.

### Regression Philosophy

- All production bugs SHOULD generate regression tests.
- The platform MUST minimize recurring failure patterns, silent regressions
  and behavior drift.

### Database Migration Validation

- All migrations MUST remain versioned, reproducible and rollback-aware where
  possible.
- Migration workflows MUST support automated validation, schema consistency
  checks and deployment safety.
- Manual production schema edits are prohibited.

### Artifact Philosophy

- Build artifacts MUST remain immutable, reproducible and traceable.
- Deployments SHOULD use versioned artifacts, reproducible containers and
  immutable deployment units.

### Deployment Philosophy

- Deployments MUST support rolling updates, graceful restart, rapid rollback
  and zero-downtime deployment where possible.
- Deployment workflows MUST remain observable, auditable and deterministic.

### Environment Separation

- Mandatory environments: development, testing, staging, production.
- Production MUST NOT become the testing environment.
- Environment behavior MUST remain reproducible and configuration-controlled.

### Configuration Philosophy

- Configuration MUST remain externalized and version-aware, and MUST avoid
  hardcoded secrets.
- Configuration SHOULD support environment isolation, deployment automation
  and operational override.

### Secret Management

- Secrets (for example API keys, database credentials, signing keys,
  encryption material) MUST remain externalized and revocable, and MUST avoid
  repository storage.
- Secrets MUST remain rotatable.

### Release Validation

- Production releases MUST validate migration success, queue health,
  websocket stability, replication state, search indexing state and
  observability health.
- The platform MUST support deployment verification, rollback workflows and
  operational recovery.

### Rollback Philosophy

- Rollback MUST remain operationally possible, documented and rehearsed.
- The architecture MUST minimize irreversible deployments and destructive
  migration coupling.

### Feature Rollout Philosophy

- The platform SHOULD support staged rollout, feature gating, operational
  toggles and gradual enablement.
- Critical features SHOULD support rapid disablement.

### Distributed Deployment Philosophy

- Distributed deployments MUST tolerate partial rollout, rolling replacement,
  temporary version skew, websocket reconnection and delayed worker upgrade.
- The system MUST degrade gracefully during deployment.

### Operational Validation

- Post-deployment validation SHOULD include queue monitoring, websocket
  metrics, replication verification, error-rate monitoring and latency
  monitoring.
- Operational verification is mandatory.

### Observability Integration

- CI/CD workflows SHOULD integrate release metrics, deployment tracing,
  profiling artifacts, coverage reports, incident correlation and rollback
  telemetry.
- Release engineering MUST remain observable.

### Infrastructure-as-Code Philosophy

- Infrastructure configuration SHOULD remain versioned, reviewable and
  reproducible.
- Operational state MUST avoid undocumented manual mutation.

### Incident Readiness

- The release process MUST assume deployment failure, rollback necessity,
  infrastructure degradation and partial outage.
- Recovery workflows MUST remain documented, testable and operationally
  realistic.

### Long-Term Delivery Goal

- GPForum release engineering MUST remain deterministic, auditable, scalable,
  operationally sustainable and resilient under distributed deployments.
- Delivery pipelines are part of the platform architecture.
- All future CI/CD and release workflows MUST comply with this ADR.

### Verifiable Release Amendment

- Release engineering MUST enforce ADR 0093.
- Every release gate MUST verify not only tests and critic, but also
  architectural invariants for critical workflows.
- Architecture-changing releases MUST include:
  - prompt alignment;
  - contract tests;
  - migration validation where schema changes exist;
  - replay or projection-impact validation where events/projections change;
  - dependency review where dependencies change;
  - profiling smoke validation for hot paths.
- Emergency gate bypasses MUST be documented with scope, risk, operator and
  follow-up verification.

### Accessibility Release Amendment

- CI/CD MUST enforce ADR 0094.
- Accessibility checks are release gates for user-facing interfaces.
- Critical WCAG 2.2 AA regressions MUST block release unless an ADR documents
  the exception, mitigation, owner and review date.
- Pipeline validation SHOULD include semantic HTML validation, contrast
  checks, keyboard smoke tests, and axe-core or pa11y where practical.

## Consequences

- The pipeline, not reviewer memory, decides whether a change ships; releases
  are reproducible from `cpanfile.snapshot` and versioned migrations, and a
  failed release can be rolled back instead of patched by hand.
- Every change pays the full gate cost (critic, formatting, migrations,
  PostgreSQL integration, benchmark smokes, coverage), which lengthens CI and
  makes flaky tests release blockers.
- Operators must keep rollback and recovery procedures documented and
  rehearsed, keep secrets outside the repository and rotatable, and record any
  emergency gate bypass with scope, risk, operator and follow-up.
- Open conflicts:
  - `.github/workflows/ci.yml` has no step dedicated to security scanning
    (only Perl::Critic, `script/cpan-license-check` and Dependabot), no
    Devel::NYTProf profiling smoke (only benchmark smokes), no build artifact
    creation (only the `cover_db` upload) and no dependency cache; the
    mandatory stage list is not fully met.
  - `script/perlcritic` fails only on violations missing from
    `etc/perlcritic-baseline.txt` (777 accepted entries). The entries are
    explicit and reviewable but not individually documented, so "fail on
    critic violations" and "exceptions MUST remain documented" are only
    partly met.
  - `lib/GPForum/Config.pm` and `etc/` define development, staging,
    production, production-small and production-medium profiles but no
    testing profile; tests configure themselves through environment
    variables.
  - "Prompt alignment" and "prompt requirements" refer to prompt files that
    will be deleted; they can then only mean alignment with the converted
    ADRs. `t/09-prompt-alignment.t` and the "Prompt alignment marker" step of
    `.github/workflows/project-hygiene.yml` read `prompt/*.txt` and will fail
    once the directory is removed.

## Alignment

- ADR 0093 (verifiable engineering invariants) and ADR 0094 (accessibility),
  enforced by the amendments above.
- ADR 0084 (test strategy), ADR 0086 (packaging and deployment), ADR 0077
  (configuration, environments and feature flags), ADR 0089 (profiling and
  coverage), ADR 0092 (GitHub project success), ADR 0087 (prompt governance
  and ADRs), ADR 0075 (runbooks), ADR 0052 (Perl engineering), ADR 0051
  (database).
- ADR 0012 (operational profiles), ADR 0048 (GlifiStore required in staging
  and production).
- `.github/workflows/ci.yml`, `.github/workflows/project-hygiene.yml`,
  `.github/dependabot.yml`, `.github/pull_request_template.md`.
- `cpanfile`, `cpanfile.postgres`, `cpanfile.snapshot`, `.perlcriticrc`,
  `etc/perlcritic-baseline.txt`, `etc/*.conf`.
- `script/bootstrap-deps`, `script/gpforum-carton`, `script/perl-syntax-check`,
  `script/perltidy-check`, `script/perlcritic`, `script/cpan-license-check`,
  `script/coverage`, `script/test`, `script/profile`, `script/profile-nytprof`,
  `script/profile-route`, `script/architecture-check`.
- `bin/gpforum-migrate`, `bin/gpforum-platform-check`, `migrations/`.
- `docs/CPAN_LICENSE_REVIEW.md`, `docs/DEPLOYMENT.md`, `docs/PROFILING.md`,
  `docs/release/readiness-review.md`, `docs/UI_ACCESSIBILITY.md`.
- `t/09-prompt-alignment.t`, `t/10-migrate-command.t`, `t/144-cpan-install.t`,
  `t/18-github-project.t`, `t/integration/postgres.t`.
