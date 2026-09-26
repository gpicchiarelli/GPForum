# Failure mode audit

Date: 2026-06-02.

Purpose: make reproducible the faults that can corrupt state, lose events,
duplicate jobs, or degrade the service. This document is diagnostic: it adds no
features and does not replace the PostgreSQL/staging tests required before
go-live.

## Summary state

GPForum already has a solid base:

- canonical writes with `txn_do` in forum, moderation, privacy, and outbox;
- outbox claim with `FOR UPDATE SKIP LOCKED`;
- retry/backoff/dead-letter for the outbox;
- health readiness with a database check;
- tests for forum rollback when the outbox/event append fails;
- tests for degraded realtime when the database or LISTEN/NOTIFY is
  unavailable;
- CI with migrations, query plan evidence, benchmark smoke, and coverage.

The main gap is systematic proof of destructive or concurrent failure modes on a
real PostgreSQL. Fake/unit tests validate contracts and shapes, but they do not
demonstrate lock scheduling, concurrent isolation, or worker crashes.
In-transaction timeouts and HTTP retries after a lost response are covered by
the fake tests.

## Failure mode register

| ID | Scenario | Current state | Risk | Severity | Required test or patch |
| --- | --- | --- | --- | --- | --- |
| FM-001 | Database down on a write route | uniform 503 on create_reply, report, hide, export, password-reset, verification-resend, and email-change | non-uniform HTTP error or leakage | high | covered by `t/152-write-unavailable.t` |
| FM-002 | Database timeout during a transaction | EventLog/outbox/audit timeout with rollback | partial transaction or opaque 500 response | high | covered by `t/86-engineering-correctness.t` |
| FM-003 | Error before commit | report, hide, and approval roll back on outbox failure | partial side effects in other areas | high | covered by `t/86-engineering-correctness.t` |
| FM-004 | Error after commit but before the HTTP response | HTTP retry with the same `command_id` | a client retry can duplicate when idempotency is missing | high | covered by `t/153-lost-response-retry.t` |
| FM-005 | Worker crash after dispatch, before mark done | stale lock is reclaimable; handler skips on replay | duplicated side effect when the handler is not idempotent | medium | covered by `t/150-outbox-handler-idempotency.t`, fake reclaim in `t/84-outbox-concurrent-dispatcher.t`, and PG reclaim in `t/integration/postgres-outbox-reclaim.t` |
| FM-006 | Minion unavailable | fail-closed when enabled; outbox-dispatch skips Minion | deploy confusion or missing worker | medium | covered by `t/83-outbox-worker-wiring.t` |
| FM-007 | Outbox retries exhausted | cancelled + dead-letter; permanent fail-fast; no re-claim | dead-letter queue not drained in staging | medium | covered by `t/13-outbox-dispatcher.t` and `docs/ops/dead-letters.md` |
| FM-008 | Duplicate privacy approval job | mitigated by migration `024` and a request lock; PG evidence in `t/integration/postgres-concurrency.t` | double erasure job | closed | two concurrent approvals produce a single erasure job |
| FM-009 | Command log race | unique constraint + catch replay/`in_progress`; PG evidence in `t/integration/postgres-concurrency.t` | 500 unique violation | closed | the same `command_id` concurrently produces one winner, replay/`in_progress` |
| FM-010 | Audit hash-chain branching | `pg_advisory_xact_lock` + PG evidence in `t/integration/postgres-concurrency.t` | chain branch | closed | two concurrent appends produce a linear chain with no branch |

## Existing tests that already help

| Area | Evidence |
| --- | --- |
| outbox retry/dead-letter | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t`, `docs/ops/dead-letters.md` |
| worker wiring | `t/16-workers-phase.t`, `t/83-outbox-worker-wiring.t` |
| handler crash/replay | `t/150-outbox-handler-idempotency.t` |
| claim crash before dispatch | `t/84-outbox-concurrent-dispatcher.t`, `t/integration/postgres-outbox-reclaim.t` |
| expired running lock reclaim (PG) | `t/integration/postgres-outbox-reclaim.t` |
| forum rollback | `t/86-engineering-correctness.t` (thread, report, hide, approval) |
| idempotent privacy erasure | `t/29-privacy-rights.t` |
| realtime DB unavailable | `t/81-realtime-operational.t` |
| readiness payload | `t/23-operations-hardening.t`, `t/77-web-technical-payloads.t` |
| write DB unavailable | `t/152-write-unavailable.t` |
| lost HTTP response retry | `t/153-lost-response-retry.t` |
| Minion backend absent | `t/83-outbox-worker-wiring.t` |
| erasure rollback after revoke | `t/86-engineering-correctness.t` |

## Patch applied in this increment

`PRIV-002` has been mitigated:

- `migrations/024_privacy_erasure_job_idempotency.sql` adds
  `idx_erasure_jobs_request_unique`;
- `ErasureJob` exposes `erasure_jobs_request_key`;
- `DeletionWorkflow::approve_request` locks the deletion request with
  `FOR UPDATE` before looking up or creating the job;
- `t/29-privacy-rights.t` verifies the lock, approval replay, and the absence of
  duplicate jobs/actions.

## Next priority failure tests

1. No priority residual remains on expired outbox reclaim or on
   `event_idempotency_keys` / reputation source uniqueness: both are covered by
   `t/integration/postgres-outbox-reclaim.t` and
   `t/integration/postgres-idempotency.t` (alongside `postgres-concurrency.t`).
