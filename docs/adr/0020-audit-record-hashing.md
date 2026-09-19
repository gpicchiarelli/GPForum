# ADR 0020: Audit Record Hashing Boundary

## Status

Accepted.

## Context

`Infrastructure::EventRecorder` mixed EventLog/Outbox writes, AuditLog
persistence, previous-hash lookup, optional field defaults, and canonical
JSON hashing. `record_audit` and the audit helpers used postfix control.
Longevity review item 5 asked write-side persistence to keep a thin recorder
above dedicated record construction. Hash verification needed unit coverage
without opening a schema or `Crypt::URandom`.

## Decision

Introduce `GPForum::Infrastructure::AuditRecord` as the audit hashing object:

- `build` applies field defaults and computes `record_hash`;
- blank `previous_hash` inputs fall back to the chained hash from the recorder;
- `verify` compares `record_hash` to the canonical payload;
- `payload_from` / `column` read hashes or DBIx::Class rows.

`EventRecorder` still appends EventLog, OutboxMessage, and AuditLog and still
walks `created_for` plus AuditLog resultsets for the previous hash.
`EventRecorder` and `Outbox::MessageBuilder` load `Service::Id` lazily so
tests can inject `Test::Id` without Crypt::URandom.

## Consequences

Audit hashing is testable without persistence. Existing chain behavior stays:
the first row has `undef` previous hash, later rows link to the latest
`record_hash`, and explicit blank `previous_hash` does not break the chain.
Concurrency serialization of the chain remains a documented residual risk.

Tests cover the hashing contract in `t/116-infrastructure-audit-record.t`.
Persistence plus chaining remain in `t/75-architecture-foundation.t`.
Lazy Id construction is covered by `t/139-event-recorder-id.t`.

## Alternatives Rejected

- Hash inside AuditLog result classes: rejected because result classes stay
  persistence mapping.
- Walk previous hashes inside AuditRecord: rejected because lookup needs the
  schema and test `created_for` helper.
- Store caller-supplied `record_hash`: rejected; the recorder always
  recomputes the hash.

## Alignment

- `docs/audit/transactional-correctness.md`
- `docs/ENGINEERING_CORRECTNESS.md`
- `t/116-infrastructure-audit-record.t`
- `t/75-architecture-foundation.t`
- `t/139-event-recorder-id.t`
