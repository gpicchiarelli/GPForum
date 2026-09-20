# ADR 0089: Profiling, Coverage and Perl Automation

## Status

Accepted. Converted on 2026-09-19 from `prompt/41.txt` ("GPForum -
Profiling, Coverage & Perl Automation Constitution"); this ADR replaces the
prompt as the binding source.

## Context

Release confidence in GPForum must come from reproducible evidence:
installed dependencies, coverage mapped to requirements, and profiles of
hot paths, not intuition. This ADR fixes the mandatory profiling, coverage,
dependency automation and Perl tooling model. It is foundational and
mandatory and governs the build, test, CI and release process for every
bounded context.

## Decision

### Cross-ADR alignment

- ADR 0093 (verifiable invariants): profiling and coverage are release
  gates for engineering invariants. Coverage MUST map to requirements, not
  vanity percentages. Profiling MUST remain runnable for HTTP routes, worker
  jobs, write workflows, search and projection rebuilds. Critical hot-path
  regressions require investigation before release.
- ADR 0097 (OS-level performance): profiling MUST be able to investigate
  OS-level behavior: fork avoidance, blocking I/O, syscall-heavy paths,
  memory retention, file descriptor limits, event backend assumptions,
  PostgreSQL latency, render latency, queue lag and cache hit/miss behavior.
  Platform-native tools MAY supplement Devel::NYTProf but MUST NOT replace
  scripted Perl profiling.
- ADR 0099 (projection stability): profiling and coverage MUST be able to
  investigate hot queries, projection lag, rebuild progress, outbox retries,
  dead letters, cache hit/miss posture, worker restart behavior and
  slow-query visibility.
- ADR 0094 (accessibility): coverage and automation MUST track
  accessibility-critical routes and workflows where practical.
  Accessibility regressions in semantic rendering, keyboard access, focus
  behavior, forms, themes, plugins, realtime announcements and
  moderation/admin surfaces are quality failures, not cosmetic defects.

### Automation philosophy

GPForum MUST use the strongest practical Perl automation available.

The project MUST avoid: manual dependency installation; unrepeatable
profiling; optional test coverage for critical paths; undocumented
performance investigation; release confidence based on intuition.

### Dependency decision

- Carton is mandatory.
- The repository MUST use: `cpanfile`; `cpanfile.postgres` for
  PostgreSQL-specific Perl dependencies; `cpanfile.snapshot` once
  dependencies are installed; local dependency installation through Carton;
  scripted commands for install, test, coverage, profiling and critic.
- PostgreSQL-specific Perl dependencies MAY require system packages such as
  libpq development headers and `pg_config`.
- The repository MUST provide a preflight script that detects missing
  system prerequisites.
- Alternative Perl dependency tools MAY be evaluated only through an ADR.

### Coverage requirements

Tests MUST perfectly cover GPForum requirements. Perfect coverage means:

- every critical ADR requirement maps to at least one verification
  strategy;
- every security-critical path has tests;
- every authorization rule has tests;
- every moderation state transition has tests;
- every event producer and consumer has tests;
- every worker retry/idempotency path has tests;
- every privacy-sensitive workflow has tests;
- every deployment-critical command has tests or smoke validation.

Numeric coverage is required but not sufficient. Requirement coverage is
authoritative.

### Coverage tooling

- Coverage tooling SHOULD use Perl-native tools. Preferred tooling:
  Devel::Cover; `prove`; TAP-compatible test output.
- Coverage reports MUST be reproducible locally and in CI.
- Coverage thresholds MUST become stricter as milestones mature.

### Profiling requirements

- Profiling MUST be available from the first implementation milestone.
- Preferred profiler: Devel::NYTProf.
- Profiling MUST support: web request profiling; worker profiling; startup
  profiling; template rendering profiling; authorization path profiling;
  event consumer profiling; database call timing correlation.
- Profiling artifacts SHOULD be archived for release comparison.

### Profiling safety

- Profiling MUST NOT expose: secrets; raw credentials; private user content;
  session tokens; internal security details to unauthorized viewers.
- Profiling MUST be disabled or tightly controlled in production unless an
  incident runbook explicitly enables it.

### Automation commands

- The project SHOULD provide scripts for: dependency installation; system
  preflight; critic; test; coverage; profiling; smoke validation.
- Scripts MUST be deterministic and CI-friendly.

### Release gates

Production releases MUST be blocked by: failing tests; failing critical
coverage; broken profiling command; dependency reproducibility failure;
severe Perl::Critic violation; security regression.

Profiling readiness is an operational requirement, not a luxury.

## Consequences

- One scripted path installs, tests, covers, profiles and lints the code,
  identically on developer machines and in CI.
- Coverage is judged by requirement mapping first, so a high percentage
  does not by itself satisfy a release gate.
- A broken profiling command or dependency reproducibility failure blocks
  release just like a failing test.
- Production profiling needs an incident runbook (ADR 0075) and must not
  leak secrets or private content.

## Alignment

- ADRs: 0093, 0094, 0097 and 0099 (cross-alignment), 0052 (Perl
  engineering), 0059 (CI/CD), 0084 (test strategy), 0086 (packaging).
- Scripts: `script/bootstrap-deps`, `script/gpforum-carton`,
  `script/system-preflight`, `script/test`, `script/coverage`,
  `script/profile`, `script/profile-nytprof`, `script/profile-route`,
  `script/perlcritic`, `script/perltidy-check`, `Makefile`,
  `.github/workflows/ci.yml`.
- Dependencies: `cpanfile`, `cpanfile.postgres`, `cpanfile.snapshot`,
  `etc/perlcritic-baseline.txt`.
- Code: `lib/GPForum/Service/Operations/Profile.pm`,
  `lib/GPForum/Service/Operations/DbQueryStats.pm`.
- Tests: `t/42-profile-reader.t`, `t/56-db-query-stats.t`,
  `t/144-cpan-install.t`.
- Docs: `docs/PROFILING.md`, `docs/DEPLOYMENT.md`.
