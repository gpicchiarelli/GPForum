# ADR 0029: Privacy Approval and Completion Replay

## Status

Accepted.

## Context

`Privacy::DeletionWorkflow` still mixed idempotent approval/completion hashes,
job-done checks, skip payloads, and the default legal-hold reason with
`FOR UPDATE` locks, ErasureJob writes, and event/audit persistence after ADR
0023 extracted row accessors and anonymized identity values.

## Decision

Introduce `GPForum::Service::Privacy::Completion` behind the existing facade.
It owns:

- erasure-job `done` checks;
- idempotent approval and completion result hashes;
- skipped-erasure payloads;
- the default `active legal hold` reason.

`DeletionWorkflow` still opens the transaction, locks the request, writes jobs
and actions, revokes credentials/sessions, and records EventLog/AuditLog.
Public signatures stay unchanged, including five-argument `hold_request`.

## Consequences

Approval replay and completion idempotency are unit-testable without schema.
HTTP and `Privacy::Workflow` keep calling the facade.

## Alternatives Rejected

- Fold replay hashes into `Privacy::Erasure`: rejected because erasure owns
  anonymized user values, not job lifecycle.
- Move replay into `Privacy::Workflow`: rejected because that object is the
  HTTP write boundary.

## Alignment

- `docs/adr/0023-privacy-erasure-record.md`
- `docs/architecture/privacy-workflow.md`
- `t/29-privacy-rights.t`
- `t/119-privacy-erasure.t`
- `t/125-privacy-completion.t`
- `docs/adr/0032-privacy-event.md`
