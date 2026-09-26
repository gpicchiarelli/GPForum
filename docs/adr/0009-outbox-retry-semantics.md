# ADR 0009: Outbox Retry And Dead-Letter Semantics

## Status

Accepted.

## Context

Outbox retry scheduling and dead letters existed, but operational review needed
a stable failure classification to separate transport, serialization,
authorization, transient and permanent failures.

## Decision

Persist `failure_type` on `outbox_messages` and `dead_letters`. The dispatcher
classifies failures while preserving existing attempt counters, lock fields,
retry scheduling, and append-only dead-letter behavior. Classification, retry
policy, and PostgreSQL claim SQL live in `Outbox::FailureType`,
`Outbox::Retry`, and `Outbox::ClaimQuery`.

## Consequences

Operators can inspect retry backlogs by failure type. Dead-letter rows retain
payload, class, message, retry count and failure type for later review or
replay decisions.

## Alternatives Rejected

- Infer failure type only from error text: rejected because review surfaces need
  stable categories.
- Delete exhausted outbox rows: rejected because delivery evidence must remain
  append-only and auditable.

