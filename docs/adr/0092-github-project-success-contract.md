# ADR 0092: GitHub Project Success Contract

## Status

Accepted. Converted on 2026-09-19 from `prompt/44.txt` ("GPForum — GitHub
Project Success Contract"); this ADR replaces the prompt as the binding
source.

## Context

GPForum MUST be operated as a serious GitHub project, not only as a code
dump. Reviewability, contribution, security reporting, and release discipline
depend on a defined repository surface and on CI that rejects drift. This
contract governs repository governance files, GitHub templates, workflows,
and the verification commands; it does not govern a bounded context.

## Decision

### Required Repository Surface

The repository MUST include:

- CI for dependency installation, lock verification, whitespace checks,
  Perl::Critic, tests, and coverage;
- project hygiene checks for required governance files;
- Dependabot configuration for GitHub Actions;
- bug, feature, and architecture decision issue templates;
- pull request template with architecture, quality, migration, and security
  gates;
- CODEOWNERS;
- security policy;
- contributing guide;
- code of conduct;
- support policy;
- governance document;
- roadmap;
- changelog;
- ADR directory and ADR template.

### Success Rules

- Every pull request MUST make the project easier to review, test, operate,
  or understand.
- Architecture-changing pull requests MUST update ADRs (the rule originally
  read "prompts or ADRs"; the prompts are now converted into ADRs). A pull
  request that changes runtime, persistence, authorization, search, workers,
  migrations, or failure behavior without contract updates is incomplete.
- CI MUST remain strict enough to reject style drift, test regressions,
  missing coverage discipline, and repository hygiene drift.
- GitHub templates MUST ask for user impact, architecture boundaries,
  definition of done, security impact, migration impact, and verification
  commands.
- The project MUST preserve the maintainer identity as Giacomo Picchiarelli.

### Definition Of Done

A GitHub project surface change is complete only when:

- required community and governance files exist;
- workflows are present and least-privilege by default;
- README links to the project success surface;
- tests verify the required files and ADR alignment (formerly prompt
  alignment);
- `script/perlcritic`, `script/test`, and `script/coverage` pass.

## Consequences

- Contributors get one predictable surface for reporting bugs, proposing
  features, raising architecture decisions, and disclosing security issues.
- CI and hygiene workflows turn style, test, coverage, and governance-file
  drift into failing checks instead of review comments.
- Architecture-changing pull requests carry ADR updates, which adds review
  work but keeps the binding contracts current.
- Workflow and template changes need test updates, because
  `t/18-github-project.t` and the project hygiene workflow assert the
  required files and markers.

## Alignment

- Related ADRs: ADR 0059 (CI/CD and release engineering), ADR 0064
  (architecture governance), ADR 0087 (ADR governance), ADR 0091, ADR 0093.
- Repository surface: `.github/workflows/ci.yml`,
  `.github/workflows/project-hygiene.yml`, `.github/dependabot.yml`,
  `.github/ISSUE_TEMPLATE/bug_report.yml`,
  `.github/ISSUE_TEMPLATE/feature_request.yml`,
  `.github/ISSUE_TEMPLATE/architecture_decision.yml`,
  `.github/pull_request_template.md`, `.github/CODEOWNERS`, `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SUPPORT.md`, `GOVERNANCE.md`,
  `ROADMAP.md`, `CHANGELOG.md`, `README.md`, `docs/adr/`,
  `docs/adr/0000-template.md`, `cpanfile.snapshot`.
- Tests: `t/18-github-project.t`, `t/09-prompt-alignment.t`.
- Scripts: `script/perlcritic`, `script/test`, `script/coverage`.
