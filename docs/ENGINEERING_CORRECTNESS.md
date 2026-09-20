# Engineering Correctness Freeze

GPForum is in Engineering Correctness Freeze: user-visible feature scope is
closed, and the release gate focuses on making existing behavior verifiable.
The database remains the source of truth; controllers, templates, caches,
websocket hubs, and workers are execution boundaries, not authority boundaries.

## Critical Invariants

| Area | Invariant | Executable evidence |
| --- | --- | --- |
| thread/post writes | A canonical thread or reply write inserts the domain rows and records EventLog, OutboxMessage, and AuditLog through one service transaction. | `t/11-forum-thread.t`, `t/12-forum-post.t`, `t/75-architecture-foundation.t`, `t/86-engineering-correctness.t` |
| command replay | Forum thread/reply HTTP writes use `command_log` when an `idempotency_key` is supplied; identical retries after a lost response replay the original target ids and do not insert a second row. Report, hide, and export HTTP retries reuse the original resource. Different payloads with the same key are rejected. | `t/32-forum-web.t`, `t/72-forum-bootstrap-workflow.t`, `t/87-command-idempotency.t`, `t/153-lost-response-retry.t` |
| event contract | Every domain event has a schema version, contract/version, idempotency key, correlation id, aggregate metadata, and transport metadata. | `t/75-architecture-foundation.t`, `t/86-engineering-correctness.t` |
| outbox | Workers claim ready pending/failed messages and expired running locks atomically with PostgreSQL `FOR UPDATE SKIP LOCKED`; no two workers process the same `outbox_id`. A crash after claim and before dispatch leaves the row `running`; another worker does not take a fresh lock, and a stale lock is reclaimed and delivered once. Identity mail is an outbox job whose EventLog payload omits the raw token; a crash after send and before outbox ack resends from the outbox mail payload. | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t`, `t/86-engineering-correctness.t`, `t/121-outbox-boundaries.t`, `t/150-outbox-handler-idempotency.t`, `t/154-identity-mail.t` |
| retry/dead-letter | Retryable outbox failures advance attempt count and backoff; a classified `permanent` failure cancels immediately; max-attempt exhaustion moves to `cancelled` and records dead-letter evidence. Cancelled rows are not claimed again. A unique race on leftover `dead_letter_id` with this source reuses the review row. A unique race on `(source_table, source_id)` reuses the review row. A unique race on `dead_letter_id` remints the id once and does not return another review row. | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t`, `t/121-outbox-boundaries.t` |
| read-state | Per-user thread read state is monotonic and stored with a delta row; lower positions cannot regress the marker. | `t/41-thread-read-state.t`, `t/86-engineering-correctness.t` |
| moderation | Moderation state transitions are transactional, audited, evented, and outboxed; full command-level replay safety is tracked in `docs/audit/transactional-correctness.md`. | `t/25-moderation-review.t`, `t/43-moderation-web.t`, `t/86-engineering-correctness.t` |
| privacy | Deletion requests, legal holds, erasure jobs, and completion retries are transactional; full command-level replay safety is tracked in `docs/audit/transactional-correctness.md`. | `t/29-privacy-rights.t`, `t/62-privacy-web.t`, `t/86-engineering-correctness.t` |
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

`Infrastructure::AuditRecord` owns canonical hashing and verification.
`EventRecorder` still looks up `previous_hash` and persists the three rows.
Hashing coverage lives in `t/116-infrastructure-audit-record.t`; persistence
and chain lookup remain in `t/75-architecture-foundation.t`.

`t/86-engineering-correctness.t` includes failure injection for this rule by
forcing EventLog, outbox, or audit insert to time out during a thread write,
report create, post hide, and privacy approval, then verifying no canonical,
event, outbox, or audit row commits. Target mutations inside those
transactions (hidden post, approved deletion request) are restored.

## Idempotency Rule

Idempotency is explicit at the domain edge, not inferred from transport retry:

- forum write commands carry the boundary `idempotency_key` into event/outbox
  idempotency keys when supplied;
- thread and reply HTTP writes register supplied command keys in `command_log`;
  a completed retry replays the original `thread_id`/`post_id` response and a
  reused key with a different command fingerprint returns conflict; a unique
  race on leftover `command_id` with this idempotency key reuses the command
  and finishes it; a unique race on `command_id` remints the id once and does
  not replay another command;
- event idempotency keys are deterministic for the command or aggregate/action;
- outbox idempotency keys are unique per event handoff; a unique race on that
  key reuses the EventLog row and does not insert a second outbox message; a
  unique race on leftover `outbox_id` with this handoff key reuses the
  outbox row; a unique race on `outbox_id` remints the id once and does
  not return another event's handoff; a unique race on leftover `event_id`
  with this idempotency key reuses the event and inserts the missing
  outbox; a unique race on this write's
  `event_id` reuses the EventLog row and does not insert a second event; a
  unique race on `event_id` remints the id once and does not return another
  event; a unique race on `audit_id` remints the id once and does not
  return another audit record;
- repeated moderation report assignment/release/resolve calls replay from
  `command_log` when HTTP supplies the same `command_id`; row locks still
  serialize two different keys against the same report;
- repeated privacy export, deletion, approval, hold, and erasure completion
  replay from `command_log` when HTTP supplies the same `command_id`; open
  requests, pending exports, and active holds are unique in schema;
- reputation ledger events are unique per `(user_id, source_type, source_id)`
  with `source_id` required; a missing source is skipped without a delta; a
  unique race on leftover `reputation_event_id` with this source reuses the
  event and inserts the missing snapshot; a unique race on
  `reputation_event_id` remints the id once and does not return another
  event;
- bookmark and subscription save skip the row update when the target is
  already active with the same note or preference; restore of a deleted,
  muted, or revoked row still clears those stamps; a unique race on leftover
  `bookmark_id` with this user and target reuses the bookmark; a unique race
  on `bookmark_id` remints the id once and does not return another bookmark;
  a unique race on leftover `mention_id` with this source and mentioned user
  reuses the mention and inserts the missing notification; a unique race on
  leftover `subscription_id` with this user and target reuses the
  subscription; a unique race on `subscription_id` remints the id once and
  does not return another subscription;
- locale, theme, and notification-channel preference writes skip the row
  update when the stored value already matches;
- category update skips the row write when title, slug, description,
  visibility, and position already match;
- read-state updates use max-position semantics instead of last-write-wins;
  a non-advancing marker keeps the original `last_read_at` and does not
  rewrite the state or delta row; a unique race on `(user_id, thread_id)`
  reloads the winner and keeps that stamp when the stored position is
  already at least the requested one; a unique race on leftover
  `thread_read_state_pkey` reuses this marker and inserts the missing
  delta;
- thread title edit and move skip the row write when title and slug, or
  category, already match;
- thread create reuses this write's unique `thread_id` row and does not
  insert a second opening post or event on conflict; a unique race on leftover
  `thread_id` with this category and slug reuses the thread and inserts the
  missing opening post; a unique race on leftover opening `post_id` with
  this thread reuses the post and inserts the missing body; a unique race
  on leftover opening `body_id` with this post reuses the body and inserts
  the missing revision; a   unique race on leftover opening `revision_id`
  with this post reuses the revision and inserts the missing counter; a
  unique race on `thread_id` remints the id once and does not return
  another thread; a unique race on the opening `post_id`
  remints the id once and does not return another post; a unique race on
  the opening `body_id` remints the id once and does not reuse another
  body; a unique race on the opening `revision_id` remints the id once
  and does not reuse another revision; a unique race on the opening
  counter reuses this thread's leftover `thread_id` row and does not abort
  the create;
- reply create reuses this write's unique `post_id` row and does not insert a
  second event on conflict; a unique race on leftover `post_id` with this
  thread reuses the post and inserts the missing body; a unique race on
  leftover reply `body_id` with this post reuses the body and inserts the
  missing revision; a unique race on leftover reply `revision_id` with
  this post reuses the revision and inserts the missing shard; a unique
  race on `post_id` remints the id once and does not return another post;
  a unique race on the reply `body_id`
  remints the id once and does not reuse another body; a unique race on
  the reply `revision_id` remints the id once and does not reuse another
  revision; a unique race on `(thread_id, position)` retries allocation
  once instead of dropping the reply;
- post edit skips a new body and revision when the current `source_hash`
  already matches; a unique race on leftover edit `body_id` with this post
  reuses the body and inserts the missing revision; a unique race on leftover
  edit `revision_id` with this post reuses the revision and applies missing
  pointers; a unique race on `body_id` remints the id once and does
  not reuse another body; a unique race on `revision_id` remints the id
  once and does not reuse another revision; a unique race on this write's
  `body_id` or `revision_id` reuses the existing edit and does not write a
  second event when pointers already match; a unique race on
  `(post_id, revision_number)` retries allocation once instead of dropping
  the edit;
- search reindex skips the search-document write when title, body,
  visibility, versions, and filter columns already match;
- feed projection skips the `user_feed_items` write when created_at, rank,
  and version columns already match; a unique race on
  `(user_id, item_type, item_id)` reloads the winner and keeps that copy
  when those columns match;
- projection offset progress skips the row write when `last_event_id`
  already matches; a unique race on `projection_name` reuses the existing
  row and does not restamp `updated_at` when the event matches;
  already-failed offsets and already-ready, active, or
  failed generations skip the status rewrite; a unique race on one active
  generation per projection reloads, skips if this generation won, and
  otherwise retries the cutover once;
- query-budget schema sync skips the row write when max queries,
  transactions, and notes already match; a unique race on `endpoint_name`
  reuses the existing row and does not rewrite the catalog when those
  values match;
- media thumbnail processing skips the object read and variant write when
  the thumbnail already exists;
- attachment intent writes reuse the unique `object_key` row and do not
  insert a second event or audit on conflict; a unique race on leftover
  `attachment_id` with this object key reuses the attachment and inserts
  the missing event; a unique race
  on `attachment_id` remints the id and object key once and does not return
  another attachment;
- attachment link and variant writes reuse the unique target or
  `(attachment_id, variant_type)` row on conflict; a unique race on leftover
  `attachment_link_id` with this target reuses the link; a unique race on
  `attachment_link_id` remints the id once and does not return another
  link; a unique race on leftover `attachment_variant_id` with this type
  and object key reuses the variant; a unique race on
  `attachment_variant_id` remints the id once and does not return another
  variant; a unique race on variant `object_key` reloads the winner and
  does not insert a second blob row;
- notification delivery reuses the unique inbox `(recipient, notification)`
  row and does not insert a second notification on conflict; a unique race
  on leftover `notifications_pkey` reuses this notification and inserts the
  missing inbox, and does not remint `notification_id`;
- notification mark-read reuses the unique
  `(notification_id, recipient_user_id)` row and does not insert a second
  read on conflict;
- search index reuses the unique `(entity_type, entity_id)` document and
  keeps the original `indexed_at` on conflict when the copy is unchanged;
- notification preference writes reuse the unique `(user_id, channel)` row
  and keep the original `updated_at` on conflict when the values match;
- attachment scanning skips the object read when the row is already clean
  and available, or infected and quarantined; a failed scan still rereads;
- reputation events that do not change trust level do not restamp the user
  row; a unique race on trust snapshot `user_id` applies this event's
  delta to the winner and does not drop the score increment;
- plugin enable and disable skip the row write when status already matches;
- plugin install reuses the unique `(name, version)` row and does not insert
  a second plugin or hook set; a unique race on leftover `plugin_id` with
  this name and version reuses the plugin and registers missing hooks; a
  unique race on `plugin_id` remints the id once and does not return another
  plugin; a unique race on leftover `hook_id` with this plugin and hook name
  reuses the hook and registers missing hooks; a unique race on `hook_id`
  remints the id once and does not return another hook; a unique race on
  `(plugin_id, hook_name)` reloads the winner and does not insert a second
  hook; a unique race on `plugin_failure_id` remints the id once and does
  not return another failure;
- role, permission, and attach writes reuse unique catalog rows and do not
  insert a second audit on conflict; a unique race on leftover `role_id`
  with this name reuses the role and inserts the missing audit; a unique
  race on `role_id` remints the id once and does not return another role; a
  unique race on leftover `permission_id` with this resource and action
  reuses the permission and inserts the missing audit; a unique race on
  `permission_id` remints the id once and does not return another
  permission; a unique race on leftover role-permission with this role and
  permission reuses the grant and inserts the missing audit;
- category create reuses the unique `(space_id, slug)` row and does not
  insert a second event on conflict; a unique race on leftover
  `category_id` with this space and slug reuses the category and inserts
  the missing event; a unique race on `category_id` remints the id once
  and does not return another category;
- default-space create reuses the unique `general` slug and does not insert
  a second space on conflict; a unique race on leftover `space_id` with
  this slug reuses the space; a unique race on `space_id` remints the id
  once and does not return another space;
- role binding create reuses the unique active `(user, role, resource,
  space)` row and does not insert a second audit on conflict; a unique race
  on leftover `binding_id` with this active binding reuses the binding and
  inserts the missing audit; a unique race on `binding_id` remints the id
  once and does not return another binding;
- report create reuses the unique open `(reporter_user_id, target_type,
  target_id)` row and does not insert a second created event on conflict;
  a unique race on leftover `report_id` with this reporter and target
  reuses the report and inserts the missing event; a unique race on
  `report_id` remints the id once and does not return another report;
- moderation action writes remint `moderation_action_id` once when the
  unique primary key conflicts, and do not return another action; a unique
  race on leftover `moderation_action_id` with this command_id reuses the
  action and inserts the missing event; a unique race on `command_id`
  replays the original action;
- legacy id mapping reuses the unique `(legacy_type, legacy_id)` row and
  keeps the original native id; a unique race on leftover
  `legacy_id_map_id` with this source reuses the mapping; a unique race on
  `legacy_id_map_id` remints the id once and does not return another
  mapping;
- import failure recording reuses the unique `(import_job_id,
  source_record_type, source_record_id)` row and does not insert a second
  review row on conflict; a unique race on leftover `import_failure_id`
  with this source reuses the failure; a unique race on
  `import_failure_id` remints the id once and does not return another
  failure;
- projection generation start reuses the unique `(projection_name,
  built_from_event_id)` row and does not insert a second rebuild on
  conflict; a unique race on leftover `generation_id` with this source
  reuses the generation; a unique race on `generation_id` remints the id
  once and does not return another generation;
- import job create remints `import_job_id` once when the unique primary
  key conflicts and does not return another job; import job progress skips
  the row write when the stored counters already match;
- already-revoked suspension retries restore a still-suspended user and skip
  the user restamp when status is already active; a unique race on
  `suspension_id` remints the id once and does not return another suspension;
- incomplete legal-hold erasure retries restore `held` status and
  `last_error` without a second event, and skip those writes when they
  already match;
- retention hold create reuses the unique active `(resource_type,
  resource_id)` row and does not insert a second event on conflict; a
  unique race on leftover `retention_hold_id` with this resource reuses
  the hold and inserts the missing event; a unique race on
  `retention_hold_id` remints the id once and does not return another hold;
- already-done erasure retries complete the deletion request if it is still
  open, skip the request restamp when already completed, and do not emit a
  second action;
- concurrent deletion approval reuses the unique erasure job and does not
  insert a second approval action; a unique race on leftover
  `erasure_job_id` with this request reuses the job and inserts the missing
  approval action; a unique race on `erasure_job_id` remints the id once
  and does not return another job; a unique race on `deletion_action_id`
  remints the id once and does not return another action;
- deletion request create reuses the unique open `(resource_type,
  resource_id, request_type)` row and does not insert a second event on
  conflict; a unique race on leftover `deletion_request_id` with this
  open resource reuses the request and inserts the missing event; a unique
  race on `deletion_request_id` remints the id once and does not return
  another request;
- export request create reuses the unique pending `(requester, subject,
  export_type, format)` row and does not insert a second event on
  conflict; a unique race on leftover `export_request_id` with this
  pending unique reuses the request and inserts the missing event; a unique
  race on `export_request_id` remints the id once and does not return
  another request;
- email verification confirmation skips the user restamp when the account
  is already active and verified;
- password change skips credential rotation when the new secret already
  matches; password reset to that same secret still consumes the token
  and revokes sessions; email-change confirmation skips the user restamp
  when the address is already verified on that account; a unique race on
  `email_normalized` returns `email_already_registered` and does not
  restamp the user; email-change request for that same verified address
  does not issue a token;
- password credential create reuses the unique active `(user_id)` password
  row and does not insert a second active secret on conflict; a unique race
  on leftover credential `id` with this user reuses the active password; a
  unique race on credential `id` remints the id once and does not return
  another user's credential;
- registration remints user `id` once when the unique primary key conflicts,
  and does not return another user's account; a unique race on leftover
  `id` with this username and email reuses the account and inserts the
  missing credential;
- session create retries hash allocation once when the unique `session_hash`
  key conflicts, and does not return another user's session; a unique race
  on leftover `session_id` with this user and hash reuses the session; a
  unique race on `session_id` remints the id once and does not return
  another user's session;
- identity token create retries hash allocation once when the unique
  `token_hash` key conflicts, and does not return another user's token;
  a unique race on leftover `token_id` with this user and hash reuses
  the token; a unique race on `token_id` remints the id once and does not
  return another user's token;
- command_log writes remint `command_id` once when the unique primary key
  conflicts, and do not replay another command; a unique race on leftover
  `command_id` with this idempotency key reuses the command and finishes it;
- reply counter shard writes apply the delta to the unique
  `(thread_id, shard_id)` winner and do not drop the increment.

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
remains the final database invariant. A unique race on that key retries
allocation once instead of dropping the reply. A unique race on `post_id`
reuses this write's reply and does not insert a second event; a unique race
on `post_id` occupied by another post remints the id once and does not
return that post.

## Failure Injection

Failure injection now covers canonical writes where EventLog, outbox, or
audit insert fails with a statement timeout after domain work has begun:
thread create, report create, post hide, privacy approval, and erasure after
credential/session revocation. The expected behavior is a surfaced error and a
rolled-back transaction. It also covers an outbox worker that claims a row
and crashes before dispatch: the lock stays exclusive until it expires, then
another worker delivers the message once.

## Release Gate

Engineering correctness changes should run:

```sh
script/test
script/perlcritic
script/query-plan-check
```

When `GPFORUM_DATABASE_DSN` is set, `script/test` also runs
`t/integration/postgres.t`. It creates a throwaway database on the configured
PostgreSQL server (the role needs `CREATEDB`), applies every migration, seeds
the `small` profile, drives the anonymous, member and moderator web flows
against real SQL, and drops the database afterwards. Unit tests use fake
schemas that cannot detect SQL-level defects such as ambiguous joined columns,
NOT NULL violations, duplicate keys or unbound `jsonb` references; this test
exists to catch them. CI runs it as its own step before the full suite.

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
