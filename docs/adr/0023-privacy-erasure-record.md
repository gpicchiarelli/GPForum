# ADR 0023: Privacy Erasure and Record Boundaries

## Status

Accepted.

## Context

`Privacy::DeletionWorkflow` mixed deletion-request creation, approval locking,
erasure-job lifecycle, legal-hold blocking, user anonymization, credential
revocation, and event/audit recording. Approval and completion exceeded the
complexity ceiling. Anonymous username/email helpers used a noisy `@` string.
Longevity review listed the workflow as one of the largest remaining services.
Erasure identity needed unit coverage without schema or `Crypt::URandom`.

## Decision

Introduce dedicated helpers behind the existing deletion facade:

- `GPForum::Service::Privacy::Record` owns request/job accessors and payloads;
- `GPForum::Service::Privacy::Erasure` owns user-resource checks and anonymized
  username, email, and user-row values;
- `GPForum::Service::Privacy::Completion` owns approval/completion replay
  hashes (ADR 0029);
- `GPForum::Service::Privacy::Event` owns EventLog/AuditLog hashes (ADR 0032).

`DeletionWorkflow` still opens the transaction, takes `FOR UPDATE` on approval,
loads holds, writes ErasureJob/DeletionAction rows, revokes credentials and
sessions, and records EventLog/AuditLog.

Public method signatures stay unchanged, including five-argument
`hold_request`.

## Consequences

Anonymous identity values are testable without persistence. Approval still
replays an existing job and still returns `retention_hold_active` when a hold
is open. Completed jobs remain idempotent. HTTP and `Privacy::Workflow` keep
calling the facade.

## Alternatives Rejected

- Fold anonymization into `Privacy::Workflow`: rejected because that object is
  the HTTP write boundary, not the erasure store.
- Reuse `Attachment::Record`: rejected because privacy rows are a different
  bounded context.

## Alignment

- `docs/architecture/privacy-workflow.md`
- `docs/audit/transactional-correctness.md`
- `t/29-privacy-rights.t`
- `t/119-privacy-erasure.t`
