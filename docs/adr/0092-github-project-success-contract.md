# ADR 0092: Repository Maintenance

## Status

Accepted.

## Date

2026-09-19

## Context

Review, contribution, security reporting, and releases depend on documented
repository policies and repeatable checks. This ADR defines the required
governance files, GitHub templates, workflows, and verification commands.

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

### Maintenance Rules

- Every pull request MUST make the project easier to review, test, operate,
  or understand.
- Pull requests that introduce or materially change architecture decisions
  MUST add or update ADRs. Changes to runtime, persistence, authorization,
  search, workers, migrations, or failure behavior MUST be reviewed against
  the applicable decisions and update inaccurate implementation documentation.
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
- README links to the contribution and maintenance documentation;
- tests verify the required files and documentation structure;
- `script/perlcritic`, `script/test`, and `script/coverage` pass.

## Consequences

- Contributors get one predictable surface for reporting bugs, proposing
  features, raising architecture decisions, and disclosing security issues.
- CI and hygiene workflows turn style, test, coverage, and governance-file
  drift into failing checks instead of review comments.
- New or changed architecture decisions carry ADR updates, which adds
  review work but keeps the decision record current.
- Workflow and template changes need test updates, because
  `t/18-github-project.t` and the project hygiene workflow assert the
  required files and workflow structure.

## Related Decisions and Implementation

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
- Tests: `t/18-github-project.t`, `t/09-architecture-documentation.t`.
- Scripts: `script/perlcritic`, `script/test`, `script/coverage`.
