# ADR 0076: Bootstrap Implementation

## Status

Accepted. Converted on 2026-09-19 from `prompt/28.txt` ("GPForum - Bootstrap
Implementation Prompt"); this ADR replaces the prompt as the binding source.

## Context

Moving from architecture documents to code needed a first, deliberately
small implementation step that could evolve into the full platform without
premature features. This ADR records what the bootstrap had to produce and
how AI code generation was instructed to produce it. It was mandatory when
moving from architecture decisions to code and governs the application
skeleton, configuration, database layer and test tooling.

## Decision

### Bootstrap goal

Generate the smallest correct GPForum application skeleton that can evolve
into the full platform.

The bootstrap MUST produce: a Mojolicious application; a configurable
multi-process launch profile; a modern Perl module layout; a DBIx::Class
schema skeleton; PostgreSQL configuration; a migration framework; a test
skeleton; a coverage command; a profiling command; a structured logging
foundation; a health endpoint; a local development command; a CI-ready
project layout.

The bootstrap MUST NOT implement advanced features prematurely.

### Repository layout

The initial layout SHOULD be:

- `bin/gpforum`
- `lib/GPForum.pm`
- `lib/GPForum/Controller/`
- `lib/GPForum/Schema.pm`
- `lib/GPForum/Schema/Result/`
- `lib/GPForum/Service/`
- `lib/GPForum/Policy/`
- `lib/GPForum/Event/`
- `lib/GPForum/Job/`
- `templates/`
- `public/`
- `etc/`
- `migrations/`
- `t/`
- `script/`

Directory names MUST remain predictable and boring.

### Initial modules

- The first implementation SHOULD include: `GPForum`,
  `GPForum::Controller::Health`, `GPForum::Controller::Home`,
  `GPForum::Schema`, `GPForum::Config`, `GPForum::Log`,
  `GPForum::Service::Clock`, `GPForum::Service::Id`.
- Domain modules SHOULD be added only when their workflow is implemented.

### First routes

- Initial routes MUST include: `GET /`; `GET /health`; `GET /health/live`;
  `GET /health/ready`.
- The health routes MUST NOT expose secrets or infrastructure internals.

### Configuration bootstrap

- The app MUST read configuration from: environment variables;
  environment-specific config files where appropriate.
- Secrets MUST NOT be committed.
- Configuration loading MUST fail clearly for missing required production
  values.

### Database bootstrap

- The initial database layer MUST include: DBIx::Class connection setup; a
  migration command placeholder; a first migration creating foundational
  tables where implementation scope allows; a test database isolation plan.
- The bootstrap SHOULD avoid connecting to production by default.

### Test bootstrap

- Initial tests MUST include: app loads; health route responds; config
  validation works; process/runtime configuration validates; coverage
  command executes; profiling command executes; basic route rendering works.
- Tests MUST be runnable from a single command.

### Generation instruction

When this decision is used with an AI code generator, instruct it to:

- read all relevant constitutions (ADRs) first;
- implement only Milestone 0 from the MVP roadmap (ADR 0068);
- avoid speculative abstractions;
- keep code Perl-native;
- add tests for generated behavior;
- add coverage and profiling commands immediately;
- document local run commands.

## Consequences

- The skeleton delivered health, configuration, logging, migrations,
  coverage and profiling before any domain feature, so later milestones
  started with test and profiling gates in place.
- Deferring domain modules until their workflow exists kept early code free
  of speculative abstractions; the repository has since grown beyond
  Milestone 0 under the later ADRs.
- Open conflicts: the current layout differs from the recommended one.
  `lib/GPForum/Policy/`, `lib/GPForum/Event/`, `lib/GPForum/Job/` and
  `public/` do not exist; jobs live in `lib/GPForum/Jobs/`, domain envelopes
  in `lib/GPForum/Domain/`, permission gates under `lib/GPForum/Service/`,
  and static assets in `assets/`.

## Alignment

- ADRs: 0068 (MVP roadmap, Milestone 0), 0077 (configuration), 0084 (test
  strategy), 0086 (packaging), 0089 (profiling and coverage); 0002
  (bootstrap boundaries), 0012 (operational profiles).
- Code: `bin/gpforum`, `lib/GPForum.pm`, `lib/GPForum/Bootstrap/`,
  `lib/GPForum/Controller/Health.pm`, `lib/GPForum/Controller/Home.pm`,
  `lib/GPForum/Schema.pm`, `lib/GPForum/Config.pm`, `lib/GPForum/Log.pm`,
  `lib/GPForum/Service/Clock.pm`, `lib/GPForum/Service/Id.pm`, `etc/`,
  `migrations/`.
- Scripts: `script/test`, `script/coverage`, `script/profile`, `Makefile`.
- Tests: `t/00-load.t`, `t/01-config.t`, `t/02-health.t`, `t/03-home.t`,
  `t/05-database.t`, `t/33-health-readiness.t`.
- Docs: `docs/architecture/bootstrap.md`.
