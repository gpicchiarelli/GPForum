# ADR 0012: Operational Profiles and Partition Lifecycle

## Status

Accepted.

## Context

Config validated process counts and rejected the development session secret in
`production`, but environment names were otherwise free strings. Range
partitions existed for `event_log`, `audit_log`, and `notifications`, and
`partition_registry` recorded intended states, but no application boundary
versioned monthly planning, retention detach, archival, or restore evidence.
Longevity review items 6 and 7 asked for explicit operational profiles and a
versioned DB lifecycle before data volume forced ad-hoc runbooks.

## Decision

Introduce `GPForum::Service::Operations::Profile` as versioned floors for
`development`, `staging`, `production-small`, and `production-medium`.
`production` aliases to `production-small`. Staging and production profiles
require a rotated session secret.

Introduce `GPForum::Service::Operations::PartitionLifecycle` to plan monthly
partitions, recommend retention transitions, and emit restore evidence.
`GPForum::Schema::Result::PartitionRegistry` maps the existing registry table.
The application does not execute partition DDL.

## Consequences

Operators can select a named profile and compare a running config against its
floors through `evaluate`, `bin/gpforum-platform-check`, and `/health/ready`. Partition work has a testable policy version without moving schema
mutation into services. Sample files live under `etc/`.

## Alternatives Rejected

- Keep environment as an unversioned string: rejected because staging and
  production-medium were indistinguishable from development except by secret
  checks.
- Execute `CREATE TABLE ... PARTITION OF` from the app: rejected because
  PostgreSQL schema changes stay in migrations and operator runbooks.
- Add Redis/search backends as part of production-medium: rejected; Redis
  stays optional. Shared L2 later became mandatory GlifiStore in
  [0048](0048-mandatory-glifistore-l2.md).

## Alignment

- `docs/architecture/operational-profiles.md`
- `docs/architecture/partition-lifecycle.md`
- `t/98-operational-profiles.t`
- `t/99-partition-lifecycle.t`
- `t/01-config.t`
