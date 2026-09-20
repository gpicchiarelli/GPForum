# ADR 0087: ADR Governance and Architecture Evolution

## Status

Accepted. Converted on 2026-09-19 from `prompt/39.txt` ("GPForum - Prompt
Governance, ADR & Architecture Evolution Constitution"); this ADR replaces
the prompt as the binding source.

## Context

GPForum's architecture was defined by 53 prompt constitutions
(`prompt/1.txt` to `prompt/53.txt`). They are converted into ADRs 0049 to
0101, which become the single binding source; the prompt files are deleted
afterwards. The governance rules that applied to the prompt set now apply to
the ADR set: how binding decisions evolve, how conflicts are resolved, what
an ADR contains, how AI-assisted implementation consumes ADRs, and how code
and decisions are kept aligned. This ADR is mandatory for maintaining the
ADR set and governs every bounded context, `docs/adr/`, `README.md` and the
alignment tests.

## Decision

### Governance philosophy

The ADR set is an architectural artifact.

It MUST remain: coherent; versioned; readable; implementation-guiding;
conflict-aware; reviewable.

It MUST avoid: contradictory mandatory requirements; stale exploratory
notes presented as final decisions; hidden precedence rules; unreviewed
architectural drift.

### Document types

- ADRs SHOULD be classified by the kind of document they record:
  constitution; blueprint; implementation decision (formerly implementation
  prompt); memo; focused ADR; runbook.
- Only final-decision documents may supersede earlier mandatory
  requirements.
- Exploration memos MUST be labeled clearly.

### Naming

- ADR files SHOULD use numeric ordering.
- New ADRs SHOULD preserve sequence continuity.
- Major additions SHOULD update `README.md`.
- Renaming ADRs SHOULD be avoided unless the index is updated.
- ADR 0098 alignment (formerly Prompt 50 alignment): architecture-changing
  work MUST consult the execution constitution (ADR 0098) before code
  generation. Alignment tests SHOULD include ADR 0098 whenever workflow,
  persistence, projection, audit, permission, transaction or operational
  execution rules change.

### Conflict resolution

When ADRs conflict:

- security wins;
- privacy wins;
- final decision documents win over memos;
- specific domain ADRs win over broad philosophy;
- ADRs explain intentional changes.

Conflicts SHOULD be fixed in the ADR text, not left to interpretation.

### ADR requirements

- ADRs MUST include: title; date; status; context; decision; consequences;
  superseded documents if any.
- ADRs SHOULD be stored in the dedicated ADR directory, `docs/adr/`.

### AI usage contract

AI code generation MUST:

- read the relevant constitution ADR before coding;
- follow the milestone sequence (ADR 0068);
- avoid implementing optional future features early;
- preserve security and privacy rules;
- add tests for generated behavior;
- call out conflicts instead of inventing silent compromises.

AI review MUST:

- compare code against the ADRs;
- identify architectural drift;
- identify missing tests;
- identify security and privacy violations.

### ADR alignment gate (formerly the Prompt Alignment Gate)

- Every architecture-changing commit MUST update the relevant ADRs in the
  same change.
- Executable contracts, migrations, tests, README status and ADRs MUST
  remain mutually consistent.
- If implementation introduces or renames a bounded context, table,
  interface, event, worker, security rule, operational invariant or
  deployment discipline, the matching ADR MUST be updated before the change
  is considered complete.
- ADR alignment MUST be verified by automated tests where practical.
- The Definition of Done for every milestone MUST include an ADR alignment
  review.

### Change management

- ADR changes SHOULD be committed intentionally.
- Large ADR changes SHOULD include: summary; affected domains; compatibility
  impact; implementation impact.
- Architecture-changing ADR updates SHOULD be reviewed as seriously as code.

### Verifiable invariants amendment

- New constitution ADRs that introduce storage, workers, projections,
  plugins, external dependencies, authorization behavior, moderation
  behavior or operational workflows MUST define their engineering
  invariants.
- Alignment tests SHOULD include ADR 0093 when architecture changes affect
  contracts, invariants, release gates, replay behavior, dependency
  governance or migration discipline.
- Alignment tests SHOULD include ADR 0094 when architecture changes affect
  frontend rendering, themes, plugins, composer behavior, realtime
  interaction, notifications, moderation/admin UI or user-facing workflow
  accessibility.
- Alignment tests SHOULD include ADR 0095 when architecture changes affect
  community lifecycle, emotional usability, contributor identity,
  discovery, personalization, retention or social continuity.
- Alignment tests SHOULD include ADR 0096 when architecture changes affect
  core boundaries, plugin capability scope, controller responsibilities,
  cache authority, CQRS usage, PostgreSQL authority or moderation core
  rules.

## Consequences

- Architecture and code change together: a commit that alters a bounded
  context, table, event, worker, security rule or deployment discipline is
  incomplete without the matching ADR change, and CI checks key phrases
  through the alignment test.
- Precedence is explicit (security, then privacy, then final decisions over
  memos, then specific over general), so conflicts are resolved in text
  rather than by interpretation.
- AI-generated code and AI reviews are anchored to ADRs, and must surface
  conflicts instead of silently compromising.
- Open conflicts:
  - ADRs 0001 to 0048 and the template `docs/adr/0000-template.md` have no
    date field, although ADRs MUST include a date; converted ADRs 0049 to
    0101 record the conversion date in their Status section.
  - `t/09-prompt-alignment.t` still reads `prompt/*.txt`, and `README.md`,
    `GOVERNANCE.md` and `CONTRIBUTING.md` still describe prompts as the
    architectural source; they must be re-pointed to the ADRs before the
    prompt files are deleted.

## Alignment

- ADRs: 0049 to 0101 (converted constitutions), 0064 (architecture
  governance), 0068 (milestone sequence), 0091 (executable architecture
  contract and Definition of Done), 0093, 0094, 0095, 0096 and 0098
  (alignment test coverage).
- Tests: `t/09-prompt-alignment.t`.
- Docs: `docs/adr/README.md`, `docs/adr/0000-template.md`, `README.md`,
  `GOVERNANCE.md`, `CONTRIBUTING.md`.
