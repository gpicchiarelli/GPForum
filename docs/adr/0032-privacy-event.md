# ADR 0032: Privacy Event And Audit Hashes

## Status

Accepted.

## Context

`Privacy::DeletionWorkflow` still mixed deletion-request, approval, hold,
block, and completion EventLog input hashes with `FOR UPDATE` locks, job
writes, and recorder argument assembly after ADR 0029 extracted replay
hashes. Those contracts needed unit coverage without schema or
`Crypt::URandom`.

## Decision

Introduce `GPForum::Service::Privacy::Event` behind the existing facade. It
owns:

- requested, approved, held, blocked, and completed event hashes;
- EventLog and AuditLog argument hashes for the recorder;
- the `retention hold active` last_error text;
- created retention-hold envelopes and audit hashes (ADR 0033).

`DeletionWorkflow` still opens the transaction, locks the request, writes
jobs and actions, revokes credentials/sessions, and persists through
`EventRecorder`. Public signatures stay unchanged, including five-argument
`hold_request`.

## Consequences

Privacy event types, idempotency suffixes, and audit metadata are
unit-testable with plain hashes. HTTP and `Privacy::Workflow` keep calling
the facade.

## Alternatives Rejected

- Fold event hashes into `Privacy::Completion`: rejected because completion
  owns replay results, not EventLog shape.
- Build hashes inside `EventRecorder`: rejected because the recorder is
  persistence, not privacy payload ownership.

## Alignment

- `docs/adr/0023-privacy-erasure-record.md`
- `docs/adr/0029-privacy-completion-replay.md`
- `docs/architecture/privacy-workflow.md`
- `EVENTS.md`
- `t/128-privacy-event.t`
- `docs/adr/0033-retention-hold-event.md`
