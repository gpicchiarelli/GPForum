# Transactional correctness audit

Date: 2026-06-02.

Purpose: freeze the new features and map what can corrupt data, duplicate
operations, lose events, or fail under load. This document introduces no
features: it classifies the residual risks and defines the patches and tests
needed to make the forum core verifiable in production.

## Summary state

Technical verdict: almost ready as a verifiable codebase, not ready for a
production go-live until the `critical` and `high` risks below are closed on
staging with a real database.

Points already closed:

- Reply hot path: `PostStore` assigns the position inside the transaction, locks
  the thread with `FOR UPDATE`, and the DB constraint `(thread_id, position)`
  remains the final invariant.
- `PostPosition::next_position` can no longer be used for writes: it fails
  explicitly, and only `read_next_position` remains for diagnostic reads.
- `create_thread`, `create_reply`, `edit_post`, `delete_post`, `edit_thread`,
  `delete_thread`, and `move_thread` require a `command_id` at the HTTP boundary
  and use `command_log` for replay/conflict.
- `record_audit` always computes `record_hash` internally and includes
  `previous_hash` in the canonical payload. `Infrastructure::AuditRecord` owns
  the defaults, hashing, and `verify`; `EventRecorder` remains persistence and
  chain lookup.

Points still to close before go-live:

- Operational staging residuals (end-to-end deploy/nginx/systemd) remain outside
  these DB evidence gates. Outbox reclaim on an expired `running` lock is
  covered by `t/integration/postgres-outbox-reclaim.t`;
  `event_idempotency_keys` and reputation source uniqueness by
  `t/integration/postgres-idempotency.t` (command_log, bookmark, subscription,
  report, moderation hide, privacy approval, audit chain, and token consume
  remain in `t/integration/postgres-concurrency.t`).

## Severity rubric

| Severity | Definition |
| --- | --- |
| critical | Can produce a destructive effect, incorrect privacy/compliance handling, event loss, or unrecoverable state under concurrency. |
| high | Can duplicate operations, audit records, events, or outbox messages, cause a 500 on a legitimate retry, or leave business state inconsistent. |
| medium | Can degrade verifiability, produce a non-linear audit chain, operational noise, or non-deterministic but recoverable behavior. |
| low | Limited operational risk, or already mitigated by constraints/tests; to be documented or monitored. |

## Priority risk register

### TX-001: reply position on a hot thread

Severity: closed, historical risk `critical`.

Files involved:

- `lib/GPForum/Service/Forum/PostStore.pm`
- `lib/GPForum/Service/Forum/PostPosition.pm`
- `migrations/003_forum_projection.sql`

Current behavior: `PostStore::_command_with_allocated_position` runs inside
`schema->txn_do`, locks the `threads` record with `FOR UPDATE`, computes the next
position, and inserts into `posts`. The migration keeps
`posts_thread_position_key UNIQUE (thread_id, position)`.

Residual risk: low. On a non-PostgreSQL backend the lock depends on the driver,
but the target for production is PostgreSQL.

Proposed patch: none for now. Only add concurrent PostgreSQL evidence with two
or more real connections.

Test to add: a DB-backed test with 25-100 simultaneous replies to the same
thread, verifying contiguous positions, zero duplicates, and zero unique errors.

### ID-001: concurrent race on `command_log`

Severity: high.

Files involved:

- `lib/GPForum/Service/Operations/CommandIdempotency.pm`
- `migrations/004_platform_governance.sql`
- `lib/GPForum/Service/Forum/PostingWorkflow.pm`

Current behavior: `CommandIdempotency::run` looks for an existing row before the
transaction, then creates the `command_log` row inside `txn_do`. The constraint
`command_log_idempotency_key_key UNIQUE (idempotency_key)` prevents two rows, but
two concurrent requests with the same `command_id` can both see it missing; one
wins, and the other can fail with a unique violation instead of receiving a
replay or `in_progress`.

Residual risk: closed by PG evidence. `t/integration/postgres-concurrency.t`
runs two real connections on the same `command_id`.

Patch applied: `CommandIdempotency::run` looks up and inserts `command_log`
inside `txn_do`. A unique violation on `idempotency_key` reloads the row and
returns replay or `in_progress` instead of a 500. `UniqueConflict->attempt` uses
a PostgreSQL savepoint so the catch does not abort the outer `txn_do`. Fake
tests in `t/87-command-idempotency.t`; PG evidence in
`t/integration/postgres-concurrency.t`.

### CM-001: non-atomic bookmark

Severity: high.

Files involved:

- `lib/GPForum/Service/Community/BookmarkStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/007_advanced_community.sql`

Current behavior: `save_bookmark` calls `find_for_user_target`, then
`create_bookmark` or restore. The constraint `bookmarks_user_target_key`
prevents duplicate rows, but the check-then-insert sequence is not retry-safe.

Residual risk: closed by PG evidence. `t/integration/postgres-concurrency.t`
runs two concurrent `save_bookmark` calls → one row. A remove on an
already-soft-deleted row does not rewrite `deleted_at`.

Patch applied: `save_bookmark` catches the unique violation on
`bookmarks_user_target_key`, reloads the winning row, and restores it.
`remove_bookmark` and `remove_for_user_target` skip the update when `deleted_at`
is already set. A second save on an already-active row with the same note
rewrites neither `deleted_at` nor `note`. Fake tests in
`t/146-concurrency-correctness.t` and `t/24-advanced-community.t`; PG evidence
in `t/integration/postgres-concurrency.t`.

### CM-002: non-atomic subscription

Severity: high.

Files involved:

- `lib/GPForum/Service/Notification/SubscriptionStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/005_notifications_subscriptions.sql`

Current behavior: `save_subscription` does a find, then an insert/restore. The
constraint `subscriptions_unique_target` prevents duplicates, but it does not
protect the application response under concurrency.

Residual risk: closed by PG evidence. `t/integration/postgres-concurrency.t`
runs two concurrent `save_subscription` calls → one row. An HTTP `command_id`
replay avoids a second mute/unsubscribe with the same command; a store retry
without a new command does not rewrite `muted_at` or `revoked_at` when the value
is already present.

Patch applied: `save_subscription` catches the unique violation on
`subscriptions_unique_target` and restores the winning row. Mute and revoke skip
the update when the timestamp is already set. A second save on an already-active
row with the same preference rewrites neither `muted_at`, `revoked_at`, nor
`preference`. Fake tests in `t/146-concurrency-correctness.t` and
`t/17-notifications.t`; PG evidence in `t/integration/postgres-concurrency.t`.

### MOD-001: duplicate open reports

Severity: high.

Files involved:

- `lib/GPForum/Service/Moderation/ReportStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/008_moderation_review.sql`
- `migrations/016_security_abuse_hardening.sql`

Current behavior: `create_report` checks for an open duplicate inside the
transaction, then inserts. HTTP mints and requires a `command_id` in
`Community::Workflow`; a lost response retried with the same key replays from
`command_log` and does not insert a second row. Migration `016` adds a partial
index on open/triaged reports, but it is not unique.

Residual risk: closed by PG evidence. `t/integration/postgres-concurrency.t`
runs two concurrent `create_report` calls → a single open report.

Patch applied: `migrations/026_concurrency_uniqueness.sql` adds
`idx_reports_reporter_target_open_unique`. `create_report` catches the conflict,
reloads the open report, and records a `duplicate_blocked` audit entry. Fake
tests in `t/146-concurrency-correctness.t`; PG evidence in
`t/integration/postgres-concurrency.t`.

### MOD-002: report transitions without a row lock

Severity: high.

Files involved:

- `lib/GPForum/Service/Moderation/ReportStore.pm`
- `lib/GPForum/Controller/Moderation.pm`

Current behavior: assign/release/resolve are transactional, lock the `reports`
row with `FOR UPDATE`, and the HTTP forms mint a distinct `command_id` per
command. The store replays on state (same moderator, already resolved) without a
unique `command_id` on the `reports` table.

Residual risk: two different `command_id` values on the same assign remain
serialized by the lock; there is no `command_log` replay when the payload
changes.

### MOD-003: moderation actions on posts/threads without a command id

Severity: high.

Files involved:

- `lib/GPForum/Service/Moderation/ActionStore.pm`
- `lib/GPForum/Controller/Moderation.pm`

Current behavior: hide/restore/lock/unlock run inside `txn_do` and, when the
state was already the expected one, return the existing action without a second
insert. Targets are read with `FOR UPDATE`.

Residual risk: closed by PG evidence for the same `command_id`.
`t/integration/postgres-concurrency.t` runs two concurrent hides → one action
and a `hidden` post. A second hide with a different `command_id` inserts no
action, event, audit record, or outbox message when the state is already the
expected one (covered by the fake tests; not re-run in the PG suite).

Patch applied: hide/restore/lock/unlock lock the target with `FOR UPDATE`. The
same `command_id` replays the existing `moderation_actions` row without a new
event/audit/outbox write. A partial unique index
`idx_moderation_actions_command_id` lives in
`migrations/026_concurrency_uniqueness.sql`. When the target is already in the
expected state, the store returns the most recent non-reversed action without a
second insert. The HTTP forms mint and pass a `command_id`. Fake tests in
`t/146-concurrency-correctness.t`, `t/25-moderation-review.t`, and
`t/86-engineering-correctness.t`; same-`command_id` PG evidence in
`t/integration/postgres-concurrency.t`.

### PRIV-001: duplicable deletion request

Severity: high. Closed in code.

Files involved:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Service/Privacy/Record.pm`
- `lib/GPForum/Service/Privacy/Erasure.pm`
- `lib/GPForum/Controller/Privacy.pm`
- `migrations/004_platform_governance.sql`

Current behavior: `request_deletion` requires a `command_id` at the HTTP
boundary and, in the store, reloads a `pending`/`approved`/`held` request for the
same `(resource_type, resource_id, request_type)` after `FOR UPDATE`. It does
not insert a second row and does not emit a second event.

Residual risk: the partial unique index on pending is no longer the gap; the
two-connection PostgreSQL evidence still has to be run.

Patch applied: `migrations/027_privacy_resource_uniqueness.sql` adds
`idx_deletion_requests_open_resource_unique`. `DeletionWorkflow` catches the
unique violation and reloads the open request. Fake tests in
`t/29-privacy-rights.t`.

### PRIV-002: concurrent approval can create multiple erasure jobs

Severity: mitigated, historical risk `critical`.

Files involved:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `migrations/004_platform_governance.sql`
- `migrations/024_privacy_erasure_job_idempotency.sql`
- `lib/GPForum/Schema/Result/ErasureJob.pm`

Current behavior: `approve_request` locks `deletion_requests` with `FOR UPDATE`
before looking up or creating the job. `erasure_jobs` now has a unique
constraint on `deletion_request_id` through `idx_erasure_jobs_request_unique`
and the DBIC schema `erasure_jobs_request_key`. A second approval of the same
request id reloads the existing job and returns idempotently. When the job
lookup misses and the insert violates `idx_erasure_jobs_request_unique`,
`DeletionWorkflow` catches the conflict, reloads the job, and does not insert a
second action. Fake tests in `t/29-privacy-rights.t`.

Residual risk: closed by PG evidence. `t/integration/postgres-concurrency.t`
runs two concurrent approvals on the same request id → a single erasure job.

Patch applied: migration `024`, the DBIC constraint, an explicit lock on
approval, a UniqueConflict catch on the job insert, and replay/race tests in
`t/29-privacy-rights.t`; PG evidence in `t/integration/postgres-concurrency.t`.

### PRIV-003: retention hold and held state repeatable without replay

Severity: medium. Closed in code.

Files involved:

- `lib/GPForum/Service/Privacy/RetentionHoldStore.pm`
- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Controller/Privacy.pm`

Current behavior: `create_hold` reloads the active hold for the same resource.
`hold_deletion` requires an HTTP `command_id`. `hold_request` stays at four
arguments besides the invocant. A state that is already `held` records no second
event/action.

Residual risk: the two-connection PostgreSQL evidence still has to be run.

Patch applied: `migrations/027_privacy_resource_uniqueness.sql` adds
`idx_retention_holds_active_resource_unique`. `RetentionHoldStore` catches the
unique violation and reloads the active hold. Fake tests in
`t/29-privacy-rights.t`.

### PRIV-005: complete_job with an active hold repeats the action and event

Severity: medium. Closed in code.

Files involved:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Service/Privacy/Completion.pm`

Current behavior: `complete_job` with an active hold marks the request `held`,
writes `last_error` on the job, and returns `retention_hold_active`. A second
`complete_job` while the hold is still active replays the same outcome
(`idempotent`) with no second deletion action and no second event. When the hold
ends, a later `complete_job` can complete the erasure. `hold_request` stays at
four arguments besides the invocant.

Residual risk: the two-connection PostgreSQL evidence still has to be run.

Patch applied: `_block_or_replay` in `DeletionWorkflow`, the `hold_block_replay`
hash in `Completion`, and tests in `t/29-privacy-rights.t` and
`t/125-privacy-completion.t`.

### PRIV-006: erasure failure after credential/session revocation

Severity: high. Closed in code.

Files involved:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `t/lib/GPForum/Test/EngineeringCorrectness/ResultSet.pm`
- `t/86-engineering-correctness.t`

Current behavior: `complete_job` anonymizes the user, revokes credentials and
sessions, then marks the job/request and writes EventLog/outbox/audit in the same
`txn_do`. A timeout on EventLog, outbox, or audit after the revocation restores
the email, `deleted_at`, and `revoked_at`, and leaves the job `pending`. A later
`complete_job` completes the erasure and the revocation.

Residual risk: real PostgreSQL evidence of the rollback still has to be run.

Patch applied: `ResultSet->all` on the correctness fake schema; timeout and
retry tests in `t/86-engineering-correctness.t`.

### PRIV-004: duplicable privacy export request

Severity: medium. Closed in code.

Files involved:

- `lib/GPForum/Service/Portability/ExportBundleBuilder.pm`
- `lib/GPForum/Controller/Privacy.pm`
- `migrations/010_import_export.sql`

Current behavior: `create_request` requires an HTTP `command_id` and reloads a
`pending` export for the same requester/subject/type/format. Completing an
already `completed` request stays idempotent. The same `command_id` after
completion replays from `command_log` and does not open a second bundle.

Residual risk: the two-connection PostgreSQL evidence still has to be run.

Patch applied: `Privacy::Workflow` wraps `request_export` with
`CommandIdempotency`. `migrations/027_privacy_resource_uniqueness.sql` adds
`idx_export_requests_pending_unique`. Tests in `t/101-privacy-workflow.t`,
`t/62-privacy-web.t`, and `t/27-import-export.t`.

### AUD-001: audit hash chain not serialized under concurrency

Severity: high.

Files involved:

- `lib/GPForum/Infrastructure/EventRecorder.pm`
- `lib/GPForum/Infrastructure/AuditRecord.pm`
- `migrations/002_event_audit.sql`
- `migrations/004_platform_governance.sql`

Current behavior: every audit record has `record_hash =
sha256(canonical_record)`, and the canonical record includes `previous_hash`.
When `previous_hash` does not arrive as input, the recorder reads the latest
available hash. This makes the individual record tamper-evident and verifiable
with `verify_audit_record`.

Residual risk: closed by PG evidence. `t/integration/postgres-concurrency.t`
runs two concurrent `record_audit` calls → a linear chain with no branch. Lookup
errors are no longer swallowed.

Patch applied: `EventRecorder::record_audit` takes `pg_advisory_xact_lock`
before the lookup. `AuditRecord` hashing is unchanged. An `AuditLog` search
failure propagates. Fake tests in `t/146-concurrency-correctness.t`; PG evidence
in `t/integration/postgres-concurrency.t`.

### OUT-001: worker crash after dispatch and before mark done

Severity: medium. Closed in code.

Files involved:

- `lib/GPForum/Service/Outbox/Dispatcher.pm`
- `lib/GPForum/Service/Outbox/ClaimQuery.pm`
- `lib/GPForum/Service/Outbox/FailureType.pm`
- `lib/GPForum/Service/Outbox/Retry.pm`
- `lib/GPForum/Service/Outbox/DomainEventTransport.pm`
- `lib/GPForum/Worker/HandlerIdempotency.pm`
- `lib/GPForum/Worker/EventIdempotencyStore.pm`
- `lib/GPForum/Worker/Handler/*`

Current behavior: the PostgreSQL claim uses `FOR UPDATE SKIP LOCKED`, the
`running` state, `locked_by`, and `locked_until`. A crash before `done` makes the
message reclaimable once the lock expires. This avoids silent loss.

`DomainEventTransport` wraps every cataloged handler and the realtime fallback
with `IdempotentJobRunner`. The keys are `worker.<name>:{event_id}`.
`EventIdempotencyStore` inserts into `event_idempotency_keys` only on
`mark_done`; `begin` and `mark_failed` do not persist. A crash after `begin` and
before `handle` does not skip the retry. A crash between `transport->dispatch`
and `_mark_done` redelivers the message; handlers that already completed come
back as `skipped`. `IdentityMail` is not skip-wrapped: a retry after send and
before `mark_done` resends from the outbox payload, because EventLog does not
hold the raw token.

Residual risk: closed by PG evidence. `t/integration/postgres-idempotency.t`
runs two concurrent `mark_done` calls inside `txn_do` → a single key row.

Patch applied: the `HandlerIdempotency` catalog, an insert-on-done store,
transport/bootstrap wrapping, and replay and crash tests in
`t/150-outbox-handler-idempotency.t`; PG evidence in
`t/integration/postgres-idempotency.t`. `UniqueConflict->attempt` on the store
insert.

### OUT-002: worker crash between claim and dispatch

Severity: medium. Closed in code.

Files involved:

- `lib/GPForum/Service/Outbox/Dispatcher.pm`
- `t/84-outbox-concurrent-dispatcher.t`

Current behavior: `claim_ready_batch` marks the row `running` with
`locked_until` before `transport->dispatch`. A crash in that window does not
deliver the payload. Another worker does not take a lock that is still fresh.
Once the lock expires, the row is reclaimed and delivered exactly once.

Residual risk: none on expired-lock reclaim; concurrent evidence remains open on
idempotency/reputation (outside this slice).

Patch applied: a claim-then-crash-then-reclaim test in
`t/84-outbox-concurrent-dispatcher.t`; two-connection PostgreSQL evidence in
`t/integration/postgres-outbox-reclaim.t` (reclaim race on an expired lock, a
fresh lock not taken, and crash-claim-then-reclaim).

### REP-001: reputation event duplicable under a race

Severity: medium. Closed in code.

Files involved:

- `lib/GPForum/Service/Community/ReputationLedger.pm`
- `lib/GPForum/Schema/Result/ReputationEvent.pm`
- `lib/GPForum/Worker/Handler/ReputationUpdate.pm`
- `migrations/028_reputation_source_uniqueness.sql`
- `migrations/029_reputation_source_required.sql`

Current behavior: `record_event` reloads an existing event for
`(user_id, source_type, source_id)` before inserting. A unique index
`idx_reputation_events_source_unique` covers every row; `source_id` is `NOT
NULL`. Events without a `source_id` do not apply the delta. The worker uses
`aggregate_id` or, when it is missing, `event_id`. A unique violation reloads the
event and does not apply the delta to the snapshot again.

Residual risk: closed by PG evidence. `t/integration/postgres-idempotency.t`
runs two concurrent `record_event` calls on the same source → one event row and
the delta applied exactly once.

Patch applied: migrations `028` and `029`, the DBIC constraint, a skip without a
source, the `event_id` fallback, and fake tests in `t/24-advanced-community.t`
and `t/149-reputation-update-handler.t`; PG evidence in
`t/integration/postgres-idempotency.t`. `UniqueConflict->attempt` on the event
and snapshot inserts.

## Write idempotency matrix

| Operation | Retry safe | Network retry safe | Double click safe | Job retry safe | State |
| --- | --- | --- | --- | --- | --- |
| `create_thread` | yes for a completed command | yes, unique `command_log` replay | yes with the same `command_id` | n/a | closed in code |
| `create_reply` | yes for a completed command | yes, unique `command_log` replay | yes with the same `command_id` | n/a | closed in code |
| `edit_post` | yes for a completed command | yes, unique `command_log` replay + skip on the same `source_hash` | yes with the same `command_id`; the store skips when the body hash matches | n/a | closed in code |
| `delete_post` | yes for a completed command | yes, unique `command_log` replay | yes with the same `command_id` | n/a | closed in code |
| `edit_thread` | yes for a completed command | yes, unique `command_log` replay + skip on unchanged title/slug | yes with the same `command_id`; the store skips when title and slug match | n/a | closed in code |
| `delete_thread` | yes for a completed command | yes, unique `command_log` replay | yes with the same `command_id` | n/a | closed in code |
| `move_thread` | yes for a completed command | yes, unique `command_log` replay + skip on the same category | yes with the same `command_id`; the store skips when the category matches | n/a | closed in code |
| `report` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique reporter/target | yes with the same `command_id` | n/a | closed in code |
| `bookmark` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique restore | yes with the same `command_id` | n/a | closed in code |
| `attachment upload` | yes, HTTP `command_id` + `command_log` | yes, unique command | yes with the same `command_id` | n/a | hash without bytes |
| `attachment delete` | yes, HTTP `command_id` + `command_log` | yes, unique command + already-deleted | yes with the same `command_id` | n/a | closed in code |
| `subscribe` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique restore | yes with the same `command_id` | n/a | closed in code |
| `thread read marker` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique `(user_id, thread_id)` + monotonic upsert + skip when it does not advance | yes with the same `command_id`; the store skips when the position does not advance or when the unique race reloads a marker that is already far enough ahead | n/a | closed in code |
| `admin role/permission/category` | yes, HTTP `command_id` + `command_log` | yes, unique command + skip on an unchanged category + unique role/permission/attach/category/space/binding | yes with the same `command_id`; the store skips when the fields match; a unique race reuses the row | n/a | closed in code |
| `moderation assign/resolve` | yes, HTTP `command_id` + `command_log` | yes, unique command + `FOR UPDATE` | yes with the same `command_id` | n/a | closed in code |
| `moderation hide/restore/lock/unlock` | yes, HTTP `command_id` + `command_log` | yes, lock + unique command | yes with the same `command_id` | n/a | store and HTTP forms closed |
| `moderation reverse` | yes, HTTP `command_id` + `command_log` | yes, unique command + `reversed_at` state | yes with the same `command_id` | n/a | store arity stops at 4 |
| `moderation suspend/revoke` | yes, HTTP `command_id` + `command_log` | yes, unique command + active reuse | yes with the same `command_id`; a revoke retry completes the user restore and skips when already active | n/a | `revoke_suspension` arity stops at 4 |
| `privacy deletion request` | yes, HTTP `command_id` + open-request replay | yes, partial unique + catch | yes for the same open resource | n/a | closed in code |
| `privacy approval` | yes for a completed retry | yes, unique job + catch | yes, reuses the existing job; the fake unique race adds no second action | n/a | mitigated with a lock and a unique job; two-connection PG evidence is residual |
| `privacy erasure completion` | yes for a `done` job or an already-written hold block | yes, rollback when EventLog/outbox/audit fails after revocation | yes, replays the block or completes; an incomplete retry restores `held`/`last_error` with no second event; a `done` job retry completes the request when it is still open | yes, replays the block or completes | closed in code |
| `privacy hold` | yes, HTTP `command_id` + active-hold replay | yes, partial unique + catch | yes for the same active resource | n/a | `hold_request` arity stops at 5 |
| `privacy export request` | yes, HTTP `command_id` + `command_log` after completion | yes, unique pending + catch | yes for the same command or the same pending request | n/a | closed in code |
| `identity login` | yes, HTTP `command_id` + `command_log` | yes, unique command | yes with the same `command_id` | n/a | closed in code |
| `identity logout` | yes, HTTP `command_id` + `command_log` | yes, unique command | yes with the same `command_id`; the store skips when already revoked | n/a | closed in code |
| `identity register` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique username/email | yes with the same `command_id`; a unique race → duplicate errors | n/a | closed in code |
| `identity password change` | yes, HTTP `command_id` + `command_log` | yes, unique command + skip on the same secret | yes with the same `command_id`; the store skips when the secret matches | n/a | closed in code |
| `identity locale change` | yes, HTTP `command_id` + `command_log` | yes, unique command + skip on the same value | yes with the same `command_id`; the store skips when the locale is already equal | n/a | guest cookie-only |
| `identity theme change` | yes, HTTP `command_id` + `command_log` | yes, unique command + skip on the same value | yes with the same `command_id`; the store skips when the theme is already equal | n/a | guest cookie-only |
| `notification preferences` | yes, HTTP `command_id` + `command_log` | yes, unique command + skip on the same channels | yes with the same `command_id`; the store skips when the channels match | n/a | locale/theme on `POST /settings` mint their own keys |
| `identity email change complete` | yes, HTTP `command_id` + `command_log` | yes, unique command + token `used_at` + skip on the same already-verified email | yes with the same `command_id`; the store skips when the email matches | n/a | closed in code |
| `identity email verification complete` | yes, HTTP `command_id` + `command_log` | yes, unique command + token `used_at` + skip when already verified | yes with the same `command_id`; the store skips when already active and verified | n/a | closed in code |
| `identity password reset complete` | yes, HTTP `command_id` + `command_log` | yes, unique command + token `used_at` + skip the rotation on the same secret | yes with the same `command_id`; the store skips the rotation when the secret matches; sessions stay revoked | n/a | closed in code |
| `identity password reset request` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique unused `(user_id, token_type)` | yes with the same `command_id`; a different `command_id` rotates the unused token | n/a | closed in code |
| `identity email change request` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique unused `(user_id, token_type)` + skip on an already-verified email | yes with the same `command_id`; the store skips when the email matches; a different `command_id` rotates the unused token | n/a | closed in code |
| `identity email verification request` | yes, HTTP `command_id` + `command_log` | yes, unique command + unique unused `(user_id, token_type)` | yes with the same `command_id`; a different `command_id` rotates the unused token | n/a | closed in code |
| `outbox dispatch` | at-least-once | n/a | n/a | yes, keys `worker.<name>:{event_id}` | closed in code |
| `reputation record` | yes for the same source | yes, unique NOT NULL + catch | yes for the same source | yes, same source | `source_id` required |

## Controllers: complexity and duplication

Controller methods longer than 30 lines, detected with a local scan:

| File | Method | Line | Lines |
| --- | --- | ---: | ---: |
| `lib/GPForum/Controller/Admin.pm` | `user_roles` | 158 | 32 |
| `lib/GPForum/Controller/Admin.pm` | `audit` | 235 | 35 |
| `lib/GPForum/Controller/Admin.pm` | `users` | 271 | 31 |
| `lib/GPForum/Controller/Admin.pm` | `jobs` | 303 | 31 |
| `lib/GPForum/Controller/Attachments.pm` | `upload_post` | 23 | 31 |
| `lib/GPForum/Controller/Attachments.pm` | `_write_user_id` | 104 | 36 |
| `lib/GPForum/Controller/Forum.pm` | `category` | 62 | 34 |
| `lib/GPForum/Controller/Forum.pm` | `thread` | 97 | 48 |
| `lib/GPForum/Controller/Forum.pm` | `mark_thread_read` | 217 | 31 |
| `lib/GPForum/Controller/Forum.pm` | `_report_input` | 558 | 31 |
| `lib/GPForum/Controller/Forum.pm` | `search` | 726 | 81 |
| `lib/GPForum/Controller/Forum.pm` | `search_autocomplete` | 808 | 51 |
| `lib/GPForum/Controller/Identity.pm` | `register` | 44 | 49 |
| `lib/GPForum/Controller/Identity.pm` | `login` | 103 | 46 |
| `lib/GPForum/Controller/Identity.pm` | `_invalid_login` | 556 | 32 |
| `lib/GPForum/Controller/Moderation.pm` | `reports` | 35 | 32 |
| `lib/GPForum/Controller/Moderation.pm` | `actions` | 68 | 35 |
| `lib/GPForum/Controller/Moderation.pm` | `suspensions` | 104 | 36 |
| `lib/GPForum/Controller/Notifications.pm` | `inbox` | 24 | 36 |
| `lib/GPForum/Controller/Privacy.pm` | `request_deletion` | 83 | 31 |
| `lib/GPForum/Controller/Privacy.pm` | `review` | 115 | 34 |
| `lib/GPForum/Controller/Privacy.pm` | `hold_deletion` | 179 | 41 |
| `lib/GPForum/Controller/Realtime.pm` | `stream` | 21 | 39 |
| `lib/GPForum/Controller/Realtime.pm` | `_handle_message` | 61 | 41 |

Duplication to reduce after the transactional fixes:

- auth/write-user/permission denial repeated across `Forum`, `Moderation`,
  `Privacy`, and `Attachments`;
- JSON/HTML negotiation and redirect action responses repeated;
- `reason`/`details` validation repeated across the controllers;
- `_system_failure`, `_bad_request`, `_not_found`, and `_conflict` handling
  already partially centralized in `GPForum::Web::ErrorPayload`, but not adopted
  by every controller.

Proposed patch: extract small `GPForum::Web::*` helpers only after the
`critical/high` risks are closed, starting from `WriteBoundary` or
`ActionResponse` for `command_id`, write auth, CSRF failure, error payload, and
redirects. Do not widen `Controller::Forum`.

## Missing failure tests

| Scenario | Current state | Required test |
| --- | --- | --- |
| DB unavailable on readiness/realtime | partially covered by readiness/realtime | the write routes `create_reply`, report, hide, and export now return 503 without leakage (`t/152`) |
| DB timeout in a write transaction | timeout on the EventLog, outbox, and audit inserts with rollback | `t/86-engineering-correctness.t` |
| Minion unavailable | fail-closed when `GPFORUM_MINION_ENABLED=1` and the backend is missing; `gpforum-outbox-dispatch` skips Minion | `t/83-outbox-worker-wiring.t` |
| Outbox retry/dead letter | cancelled + dead-letter; permanent fail-fast; no re-claim | `t/13-outbox-dispatcher.t`, `docs/ops/dead-letters.md` |
| Worker crash | crash between claim and dispatch, or between dispatch and mark done | `t/84-outbox-concurrent-dispatcher.t`, `t/150-outbox-handler-idempotency.t`, `t/integration/postgres-outbox-reclaim.t` |
| Transaction rollback after event/outbox/audit | covered on thread, report, hide, and approval outbox failures | `t/86-engineering-correctness.t` |
| Unique conflict on retry | not covered | concurrent PostgreSQL tests for command_log, bookmark, subscription, and report |
| Error after the HTTP commit | identical retry of create_reply, thread, report, hide, and export | `t/153-lost-response-retry.t` |

## Email lifecycle

Verified state:

- email verification: no complete workflow exists; `users.email_verified_at` is
  present, but registration creates a login-capable account;
- password reset: no reset workflow found;
- secure email change: no workflow with new-email verification found;
- session revocation: present in `Identity::Store::revoke_session`, logout,
  server-side session validation, and privacy erasure revocation.

Risk: high for real public accounts, because access recovery and email identity
verification are operational prerequisites. This is the only functional area
allowed before new features, but it should be treated as identity hardening, not
as product expansion.

Proposed patch: close the transactional `critical/high` risks first; then
introduce a minimal verification/reset/change-email workflow with hashed tokens,
expiry, single use, and session revocation on password/email change.

## Required real stress test

The existing scripts measure deterministic benchmarks and Hypnotoad scaling, but
they are not enough as final proof at 100/500/1000 concurrent users.

Proposed baseline:

1. Prepare a staging PostgreSQL with the migrations and seed data:

```sh
script/seed-benchmark --profile medium
script/seed-benchmark --profile hot-thread
```

2. Start Hypnotoad with a production small/medium profile and metrics enabled.

3. Run the read-heavy matrix with the existing harness:

```sh
script/bench-hypnotoad-scaling --profile medium --worker-set 4,8 \
  --clients 100 --iterations 100 --warmup 10 --json
script/bench-hypnotoad-scaling --profile medium --worker-set 4,8 \
  --clients 500 --iterations 100 --warmup 10 --json
script/bench-hypnotoad-scaling --profile hot-thread --worker-set 4,8 \
  --clients 1000 --iterations 100 --warmup 10 --json
```

4. Cover the routes:

- `/categories`
- `/t/018f1004-0001-7000-8000-000000000001`
- `/feed` with a seeded user session
- `/search?q=performance`
- `POST /t/:thread_id/reply` with a unique `command_id` per request, plus a
  retry variant with the same `command_id`

5. Minimum report per route:

- p50, p95, p99;
- error rate;
- req/s;
- max/avg DB queries;
- transaction count;
- worker distribution from the Hypnotoad output;
- outbox pending/failed/dead-letter before and after;
- RSS and file descriptors.

Go-live gate: no critical route with an error rate above 1%, no duplicate
reply/report/job, and no undrained outbox growth after the test.

## Next priority patches

1. End-to-end operational staging (nginx/systemd) beyond the DB drills: outbox
   reclaim on an expired `running` lock is covered by
   `t/integration/postgres-outbox-reclaim.t` (the claim-then-crash mock stays in
   `t/84-outbox-concurrent-dispatcher.t`); `event_idempotency_keys` and
   reputation source uniqueness by `t/integration/postgres-idempotency.t`; the
   other races in `t/integration/postgres-concurrency.t`.
