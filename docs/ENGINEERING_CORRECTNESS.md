# Engineering Correctness Freeze

GPForum is in Engineering Correctness Freeze: user-visible feature scope is
closed, and the release gate focuses on making existing behavior verifiable.
The database remains the source of truth; controllers, templates, caches,
websocket hubs, and workers are execution boundaries, not authority boundaries.

## Critical Invariants

| Area | Invariant | Executable evidence |
| --- | --- | --- |
| thread/post writes | A canonical thread or reply write inserts the domain rows and records EventLog, OutboxMessage, and AuditLog through one service transaction. | `t/11-forum-thread.t`, `t/12-forum-post.t`, `t/75-architecture-foundation.t`, `t/86-engineering-correctness.t` |
| command replay | Forum thread/reply HTTP writes use `command_log` when an `idempotency_key` is supplied; identical retries replay the original target ids and different payloads with the same key are rejected. | `t/32-forum-web.t`, `t/72-forum-bootstrap-workflow.t`, `t/87-command-idempotency.t` |
| event contract | Every domain event has a schema version, contract/version, idempotency key, correlation id, aggregate metadata, and transport metadata. | `t/75-architecture-foundation.t`, `t/86-engineering-correctness.t` |
| outbox | Workers claim ready pending/failed messages and expired running locks atomically with PostgreSQL `FOR UPDATE SKIP LOCKED`; no two workers process the same `outbox_id`. | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t`, `t/86-engineering-correctness.t` |
| retry/dead-letter | Retryable outbox failures advance attempt count and backoff; max-attempt exhaustion moves to `cancelled` and records dead-letter evidence. | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t` |
| read-state | Per-user thread read state is monotonic and stored with a delta row; lower positions cannot regress the marker. | `t/41-thread-read-state.t`, `t/86-engineering-correctness.t` |
| moderation | Moderation state transitions are transactional, audited, evented, outboxed, and idempotent when repeated. | `t/25-moderation-review.t`, `t/43-moderation-web.t`, `t/86-engineering-correctness.t` |
| privacy | Deletion requests, legal holds, erasure jobs, and completion retries are transactional and idempotent; active holds block erasure. | `t/29-privacy-rights.t`, `t/62-privacy-web.t`, `t/86-engineering-correctness.t` |
| controller boundary | Controllers do not access DBIx::Class resultsets or perform direct writes; write commands go through services/stores/workflows. | `script/architecture-check`, `t/34-architecture-discipline.t`, `t/86-engineering-correctness.t` |
| templates | Templates render prepared view data only; no persistence access or business writes live in templates. | `script/architecture-check`, `t/86-engineering-correctness.t` |
| hot paths | Application and template hot paths must not use `OFFSET`; pagination remains keyset/bounded. | `script/query-plan-check`, `t/47-query-plan-check.t`, `t/86-engineering-correctness.t` |
| cache | Local cache is process-local, TTL bounded, size bounded, invalidatable, and never authoritative. | `t/40-local-cache.t`, `script/architecture-check`, `t/86-engineering-correctness.t` |
| migrations | DB constraints must encode identity, status, idempotency, uniqueness, counter, read-state, moderation, privacy, and outbox claim invariants. | `t/05-database.t`, `t/86-engineering-correctness.t` |

## Atomicity Rule

Canonical write services own write atomicity. A controller may validate HTTP
shape and call a service, but it must not open resultsets or assemble domain
side effects. Within the service transaction, the canonical row writes and the
EventRecorder calls are one unit:

1. domain rows are created or updated;
2. `record_event` appends EventLog and OutboxMessage;
3. `record_audit` appends AuditLog where the action is auditable;
4. any failure aborts the service transaction.

`t/86-engineering-correctness.t` includes failure injection for this rule by
forcing the outbox append in a thread write to fail and verifying no canonical,
event, outbox, or audit row commits.

## Idempotency Rule

Idempotency is explicit at the domain edge, not inferred from transport retry:

- forum write commands carry the boundary `idempotency_key` into event/outbox
  idempotency keys when supplied;
- thread and reply HTTP writes register supplied command keys in `command_log`;
  a completed retry replays the original `thread_id`/`post_id` response and a
  reused key with a different command fingerprint returns conflict;
- event idempotency keys are deterministic for the command or aggregate/action;
- outbox idempotency keys are unique per event handoff;
- repeated moderation report assignment/release/resolve calls avoid duplicate
  events;
- repeated privacy erasure completion avoids duplicate actions;
- read-state updates use max-position semantics instead of last-write-wins.

## Concurrency Rule

Outbox concurrency is guarded by the database claim, not by worker memory. The
dispatcher claims rows inside a DBIx::Class transaction using PostgreSQL
`FOR UPDATE SKIP LOCKED`, marks them `running` with `locked_at`, `locked_until`,
and `locked_by`, then processes only rows claimed by the current worker. Claim
ordering is deterministic on `next_attempt_at, created_at, outbox_id`, and the
partial ready-queue indexes split `pending`, `failed`, and stale `running`
paths. Expired `running` locks are claimable for stale-lock recovery.

Reply position allocation is performed inside `PostStore` in the same
transaction as the canonical post/event/audit/outbox writes. The store locks the
target thread row with PostgreSQL `FOR UPDATE`, then allocates the next position
before inserting the post. The `(thread_id, position)` uniqueness constraint
remains the final database invariant.

## Failure Injection

Failure injection now covers the most fragile correctness edge: a canonical
thread write where the outbox append fails after domain/event work has begun.
The expected behavior is a surfaced error and a rolled-back transaction.

Additional failure injection targets for future freeze work:

- event append failure before outbox append;
- audit append failure after event/outbox append;
- stale outbox worker crash between claim and dispatch;
- moderation transition failure after row mutation but before event/audit;
- privacy erasure failure after credential/session revocation.

## Release Gate

Engineering correctness changes should run:

```sh
script/test
script/perlcritic
script/query-plan-check
```

When the full Perl::Critic baseline is not green, new freeze changes must at
minimum pass targeted Perl::Critic and avoid adding new violations.

`script/perlcritic` enforces this as a pinned baseline gate:

- `etc/perlcritic-baseline.txt` lists the currently known historical
  violations;
- a full run compares policy, file, message and offending source while
  normalizing line/column drift;
- a full run fails when any violation appears outside that normalized baseline;
- a full run warns when baseline entries disappear, forcing an intentional
  baseline update after cleanup without making platform-specific disappearances
  break CI.
