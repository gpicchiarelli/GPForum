# ADR 0110: ADR 0091's Mandatory Interfaces Are the Modules That Exist

## Status

Accepted. Amends ADR 0091 (its Mandatory Interfaces); follows ADR 0106.

## Context

ADR 0091 lists six interfaces that "MUST exist as explicit Perl modules" —
`EventStore`, `CommandHandler`, `PermissionEngine`, `SessionStore`,
`SearchIndexer`, `NotificationDispatcher` — with 26 methods between them, and
says a contract method MUST NOT be removed without an ADR. ADR 0106 measured
them on 2026-09-24: one of six was complete, and two did not exist as
modules.

On 2026-09-26 every method was mapped against `lib/`: where the capability
lives, who calls it, and whether anyone needs what is missing. The finding
was not that the code falls short of the contract. For most methods the code
has the capability under another name and another shape, chosen for reasons
the contract did not anticipate, and a facade with the contract's name would
have no caller. For a few, the contract describes a design the system does
not use. For a handful, the gap is real and is now closed or tracked.

A contract that describes classes nobody calls is worse than none: it sends a
reader looking for modules that are not there, and it invites facades whose
only purpose is to satisfy the document. This ADR makes the contract describe
the code, and says which gaps are real.

## Decision

ADR 0091's Mandatory Interfaces are met by the modules below. Each row names
the contract method, where it lives, and why it has that shape. Methods
marked *removed* leave the contract; *tracked* ones are real gaps recorded in
`docs/QUALITY_PROGRAM.md`.

### EventStore — `GPForum::Infrastructure::EventRecorder`

| Contract | In the code |
| --- | --- |
| `append($event)` | `record_event(%event)`: appends the event and its outbox row in the caller's transaction, idempotent on `event_id`. 22 callers. |
| `append_once($event, $key)` | `event_recorded($idempotency_key)`, then `record_event`. Six stores that replay a half-finished command (the row stored, the event lost) had each copied the lookup; they now share it. |
| `fetch_by_aggregate(...)` | *Removed.* Entity history is read from the canonical revision and moderation tables, forensics from `audit_log`. Add it when a consumer — an event-replay or forensics command — needs it. |
| `fetch_after($cursor)` | *Removed.* Events reach consumers through the transactional outbox (claim, retry, dead letter, replay; ADRs 0009 and 0025). Nothing tails `event_log`, and projections rebuild from canonical state. |

### CommandHandler — no generic module

A command is a workflow's public method. Its steps are real and have
owners; a `CommandHandler` base class would add a layer every workflow must
pass through and nothing else would call.

| Contract | In the code |
| --- | --- |
| `validate($command)` | The composer's `prepare` (`ThreadComposer`, `PostComposer`, …) or a validator such as `validate_upload`, run inside the command's transaction so a rejection is recorded and replayable. |
| `authorize($command, $actor)` | The controller's access object (`Web::*Access`) and `PermissionGate` before the workflow runs; content visibility (ADR 0102) inside it. |
| `execute($command)` | The workflow method through `CommandIdempotency::run`, which gives every command one transaction, one result per command id, and never commits a failed one. |
| `emit_events($result)` | *Removed.* Stores append their events through `EventRecorder` inside the command's transaction, as ADR 0091 itself requires; the outbox dispatcher publishes them. A separate emit step could only run after commit and lose events. |

### PermissionEngine — three owners, one convention

| Contract | In the code |
| --- | --- |
| `permits($actor, $action, $resource, $context)` | Role-based access: `Service::Identity::PermissionGate::allowed`. Content visibility: `Service::Forum::Visibility` and `Service::Forum::Readability` (ADR 0102). Per-surface policies — `Search::PermissionEngine`, `Realtime::SubscriptionPolicy`, `Notification::RecipientPolicy` — expose `permits` or a named question (`can_notify`, `readable_by`) over them. |
| `explain(...)` | `Web::Guard::log_denial`: every permission refusal (403) from the admin, moderation and privacy consoles is logged with the permission checked, the user and the binding that would have granted it (`permission denied: user U lacks moderation.review (needs a global binding, or one on resource R in space S) on /path`). With the user's bindings on `/admin/users/:user_id/roles`, that answers why moderator M is refused on category C without reading SQL. A CSRF 403 involves no permission and is not logged there. |
| `roles_for($actor, $scope)` | `Service::Admin::PermissionReview::roles_for_user($user_id, $options)`, a read model for the admin review page. Scoped evaluation lives in `PermissionGate`'s SQL; nothing at runtime needs a role list. |
| `policies_for($resource)` | *Removed.* It assumes per-resource ACLs; policy here is role bindings (scoped globally, to a space or to a category) plus the visibility columns, and `resource_acl` is not read (ADR 0102). |

### SessionStore — `GPForum::Service::Identity::SessionStore`

| Contract | In the code |
| --- | --- |
| `create_session($user, $metadata)` | `create_session($user, $input)`. |
| `find_active_session($raw_token)` | `validate_session({session_id, user_id, session_token})`. Every caller holds the id and the token together; the lookup is by id, and the token is compared in constant time. |
| `revoke_session($raw_token, $reason)` | `revoke_session({session_id, user_id})`. The raw token lives only in the cookie and was verified earlier in the request. The reason is recorded by the caller's audit and command log. |
| `revoke_all_for_user($user_id, $reason)` | `revoke_user_sessions($user_id, $revoked_at, $keep_session_id)`, the reason again with the caller. |
| `touch_session($raw_token)` | Part of `validate_session`, throttled. A separate touch would need a second row lookup per request and would have no caller. |

### SearchIndexer — `GPForum::Service::Search::Indexer`

All five methods exist under their contract names. `rebuild($scope)` had no
operator entry point and `observe_lag()` returned nothing unless an offset
tracker was wired; an operator needs both, to rebuild the projection after a
search configuration change and to tell a stalled indexer from a healthy
one. Closed with this ADR: `bin/gpforum-search-rebuild` (and `--status`),
a rebuild that streams in batches and removes orphaned documents, and a lag
read from the outbox (`docs/ops/search-rebuild.md`).

### NotificationDispatcher — `GPForum::Service::Notification::Dispatcher`

| Contract | In the code |
| --- | --- |
| `create_notification($recipient_id, $type, $payload)` | `create_notification(\%input)`: the source type and id and the idempotency key are required, so the arguments are named. |
| `dispatch_pending($limit)` | *Removed.* The pending queue, its claims, retries and dead letters belong to the outbox dispatcher; the `NotificationDispatch` handler fans a reply out to subscribers. |
| `mark_read($notification_id, $user_id)` | `mark_read`. |
| `suppress_for_policy($notification, $policy)` | Suppression happens where it can be enforced: at creation (`permission_engine`, `Notification::RecipientPolicy`) and when the inbox is read (`readability`, filtered in SQL). No caller holds a policy object to pass. |

The rule that a contract method MUST NOT be removed without an ADR stands;
this ADR is that record for the methods marked *removed*. A new method joins
the contract when a caller needs it.

## Consequences

- ADR 0091's interfaces describe code a reader can open. All six are
  accounted for: four by modules that implement them under the names above,
  `CommandHandler` by the workflow structure, `PermissionEngine` by three
  owners under one convention.
- Five methods leave the contract (`fetch_by_aggregate`, `fetch_after`,
  `emit_events`, `policies_for`, `dispatch_pending`); none had a caller, and
  each would have been a facade over a design the system does not use.
- Three gaps were real, and are closed: search `rebuild` and `observe_lag`
  have an operator command, and refusals are logged with the permission
  checked (`explain`).
- One consolidation was made with this ADR: `EventRecorder::event_recorded`
  replaces six copies of the same lookup.
- Rollback: restoring ADR 0091's list would restore a contract that the code
  does not meet and that nothing calls; there is no reason to expect it.

## Alignment

- ADR 0091 — the contract this amends. ADR 0106 — the first amendment.
- ADR 0102 — content visibility, which `PermissionEngine`'s content half is.
- ADRs 0009 and 0025 — the outbox, which replaces `fetch_after` and
  `dispatch_pending`.
- `t/integration/postgres-event-recorder.t` — `event_recorded` and the
  replay of a half-finished command, on PostgreSQL.
