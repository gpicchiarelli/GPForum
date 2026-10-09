# ADR 0035: Moderation Action Event And Audit Hashes

## Status

Accepted.

## Context

`Moderation::ActionStore` still mixed created-action and reversal EventLog
envelopes, payloads, and AuditLog hashes with `ModerationAction` writes after
ADR 0010 extracted the HTTP write workflow. Those contracts needed unit
coverage without schema or `Crypt::URandom`.

## Decision

Introduce `GPForum::Service::Moderation::Event` behind the existing action
store. It owns:

- created-action payloads, envelopes, and audit hashes;
- reversal payloads, envelopes, and audit hashes.

`ActionStore` still opens the transaction, updates post/thread state, inserts
`ModerationAction` rows, and persists through `EventRecorder`. Public method
signatures stay unchanged, including four-argument `reverse_action`.

## Consequences

Action and reversal EventLog/AuditLog hashes are unit-testable with plain
hashes. `Moderation::Workflow` keeps calling the store. Report hashes now live
on `Moderation::Event` (ADR 0036). Suspension hashes now live on
`Moderation::Event` (ADR 0037).

## Alternatives Rejected

- Fold hashes into `Moderation::Workflow`: rejected because that object is the
  HTTP write boundary, not EventLog shape.
- One Event module covering reports and suspensions in this change: rejected
  so action idempotency keys can land first without widening the store.

## Alignment

- `docs/adr/0010-moderation-workflow-boundary.md`
- `docs/architecture/moderation-workflow.md`
- `EVENTS.md`
- `t/130-moderation-event.t`
- `docs/adr/0036-moderation-report-event.md`
