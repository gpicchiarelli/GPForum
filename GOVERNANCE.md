# Governance

GPForum is governed by executable architecture contracts.

## Maintainer

The current maintainer is Giacomo Picchiarelli.

## Decision rules

- [Architecture decision records](docs/adr/README.md) record durable design choices,
  their context and consequences.
- [Project documentation](docs/README.md) explains the implemented system and how
  to develop and operate it.
- Tests turn contracts into executable checks.
- Pull requests keep code, migrations, tests and documentation consistent.
- Add or amend an ADR when a design decision changes; ordinary fixes need only
  the documentation relevant to their behavior. See
  [ADR 0087](docs/adr/0087-adr-governance-architecture-evolution.md).

## Required review for changes

Architecture-changing work requires review of:

- bounded context ownership;
- interface contracts;
- data model and migrations;
- permission and privacy impact;
- failure modes;
- operational observability;
- test, profiling, and coverage evidence.
