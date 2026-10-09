# ADR 0025: Outbox Failure, Retry, and Claim Query Boundaries

## Status

Accepted.

## Context

`Service::Outbox::Dispatcher` owned PostgreSQL `FOR UPDATE SKIP LOCKED` SQL,
failure-type regexes, attempt increment, cancelled-versus-failed status, lock
duration, and backoff together with transport dispatch and row updates. ADR
0009 already required stable `failure_type` categories; those rules were not
unit-testable without a schema and transport fake.

## Decision

Split the dispatcher behind the existing public methods:

- `GPForum::Service::Outbox::FailureType` owns declared and regex
  classification;
- `GPForum::Service::Outbox::Retry` owns attempt increment, cancelled status,
  lock duration, and linear backoff;
- `GPForum::Service::Outbox::ClaimQuery` owns the claim statement and bind
  order.

`GPForum::Service::Outbox::Dispatcher` still claims, dispatches, updates
rows, and writes dead letters. `DeadLetterRecorder`, `EventRecorder`, and
`Outbox::MessageBuilder` load `Service::Id` lazily so tests can inject
`Test::Id` without Crypt::URandom.

## Consequences

Classification, retry ceilings, and claim bind order are unit-testable without
DBIx::Class. `t/13-outbox-dispatcher.t` keeps the same SQL, bind indexes, and
retry schedule. Public dispatcher method names stay unchanged.

## Alternatives Rejected

- Keep regexes and SQL as dispatcher private constants: rejected because
  operators need those rules tested without a claim transaction.
- Move retry policy into `DeadLetterRecorder`: rejected because dead letters
  are terminal evidence, not scheduling.

## Alignment

- `docs/adr/0009-outbox-retry-semantics.md`
- `docs/OUTBOX_LIFECYCLE.md`
- `docs/ENGINEERING_CORRECTNESS.md`
- `t/13-outbox-dispatcher.t`
- `t/121-outbox-boundaries.t`
