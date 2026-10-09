# ADR 0087: ADR Governance and Architecture Evolution

## Status

Accepted.

## Date

2026-09-19

## Context

Architecture decisions need a stable place where contributors can find
their rationale, scope and consequences. `docs/adr/` is GPForum's single
source of architecture decisions. Implementation guides, runbooks and
repository instructions refer to those decisions without duplicating them.
This ADR defines how decisions evolve, how conflicts are resolved, what an
ADR contains, and how documentation stays consistent with implementation.
It governs the ADR directory and contribution and review workflows.

## Decision

### Governance philosophy

The ADR set is an architectural artifact.

It MUST remain: coherent; versioned; readable; implementation-guiding;
conflict-aware; reviewable.

It MUST avoid: contradictory mandatory requirements; stale exploratory
notes presented as final decisions; hidden precedence rules; unreviewed
architectural drift.

### Document types

- Architecture decisions MUST be recorded in `docs/adr/`.
- Design guides, implementation notes and runbooks SHOULD live in the
  relevant `docs/` directory and link to applicable ADRs.
- Proposed decisions and exploratory notes MUST be labeled clearly.
- Only accepted decisions may supersede earlier accepted requirements.

### Naming

- ADR files SHOULD use numeric ordering.
- New ADRs SHOULD preserve sequence continuity.
- Major additions SHOULD update `README.md`.
- Renaming ADRs SHOULD be avoided unless the index is updated.
- Workflow, persistence, projection, audit, permission, transaction and
  operational changes MUST follow the execution checklist in ADR 0098.

### Conflict resolution

When ADRs conflict:

- security wins;
- privacy wins;
- accepted decisions win over exploratory notes;
- specific domain ADRs win over broad philosophy;
- ADRs explain intentional changes.

Conflicts SHOULD be fixed in the ADR text, not left to interpretation.

### ADR requirements

- ADRs MUST include: title; date; status; context; decision; consequences;
  superseded documents if any.
- ADRs MUST be stored in the dedicated ADR directory, `docs/adr/`.

### Implementation and review

Contributors MUST:

- read the relevant ADRs before changing the architecture;
- follow the milestone sequence (ADR 0068);
- avoid implementing optional future features early;
- preserve security and privacy rules;
- add tests for implemented behavior;
- call out conflicts instead of inventing silent compromises.

Reviewers MUST:

- compare code against the ADRs;
- identify architectural drift;
- identify missing tests;
- identify security and privacy violations.

### Architecture documentation review

- New or materially changed architecture decisions MUST be recorded in a
  new or amended ADR in the same change. Implementing an existing decision
  or making a routine fix does not require an ADR update.
- Executable contracts, migrations, tests, README status and ADRs MUST
  remain mutually consistent.
- Changes to a bounded context, interface, event, worker, security rule,
  operational invariant or deployment discipline MUST be reviewed against
  the applicable ADRs. Update an ADR when the decision changes, and update
  implementation documentation and references when their details change.
- Automated checks SHOULD verify documentation structure and valid links.
  Architecture and workflow tests MUST verify the corresponding behavior
  and invariants; matching slogans or prose is not evidence of correctness.
- The Definition of Done for every milestone MUST include an ADR alignment
  review.

### Change management

- ADR changes SHOULD be committed intentionally.
- Large ADR changes SHOULD include: summary; affected domains; compatibility
  impact; implementation impact.
- Architecture-changing ADR updates SHOULD be reviewed as seriously as code.

### Verifiable invariants amendment

- New ADRs that introduce storage, workers, projections,
  plugins, external dependencies, authorization behavior, moderation
  behavior or operational workflows MUST define their engineering
  invariants.
- Verification SHOULD cover ADR 0093 when architecture changes affect
  contracts, invariants, release gates, replay behavior, dependency
  governance or migration discipline.
- Verification SHOULD cover ADR 0094 when architecture changes affect
  frontend rendering, themes, plugins, composer behavior, realtime
  interaction, notifications, moderation/admin UI or user-facing workflow
  accessibility.
- Verification SHOULD cover ADR 0095 when architecture changes affect
  community lifecycle, emotional usability, contributor identity,
  discovery, personalization, retention or social continuity.
- Verification SHOULD cover ADR 0096 when architecture changes affect
  core boundaries, plugin capability scope, controller responsibilities,
  cache authority, CQRS usage, PostgreSQL authority or moderation core
  rules.

## Consequences

- Contributors have one source for architecture decisions and one review
  process for implementation changes.
- New or changed decisions add documentation work; routine implementation
  changes only update documentation when it becomes inaccurate.
- Precedence is explicit, so conflicts are resolved in ADR text rather
  than left to interpretation.
- Documentation checks catch missing sections and broken references.
  Behavior and architecture tests provide evidence that implementation
  preserves the recorded requirements.

## Related Decisions and Implementation

- ADRs: 0049 to 0101 (architecture decisions), 0064 (architecture
  governance), 0068 (milestone sequence), 0091 (executable architecture
  contract and Definition of Done), 0093, 0094, 0095, 0096 and 0098
  (engineering requirements).
- Tests: `t/09-architecture-documentation.t`.
- Docs: `docs/adr/README.md`, `docs/adr/0000-template.md`, `README.md`,
  `GOVERNANCE.md`, `CONTRIBUTING.md`.
