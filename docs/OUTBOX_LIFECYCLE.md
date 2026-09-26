# Outbox Lifecycle

The transactional outbox is the delivery boundary between canonical writes and
asynchronous side effects.

## States

| State | Meaning |
| --- | --- |
| `pending` | ready when `next_attempt_at <= now()` |
| `running` | claimed by a dispatcher worker with a bounded lock |
| `done` | transport completed successfully |
| `failed` | retryable failure with a future `next_attempt_at` |
| `cancelled` | attempts exhausted and dead-lettered |

## Reliability Fields

`outbox_messages` stores:

- `attempt_count` and legacy `attempts`;
- `next_attempt_at`;
- `locked_by` and `locked_until`;
- `last_error`;
- `last_error_class`;
- `failure_type`.

Failure types are canonical presentation/operations categories:
`transient`, `permanent`, `serialization`, `authorization`, and `transport`.

## Dead Letters

When attempts are exhausted, `DeadLetterRecorder` writes an append-only
`dead_letters` row with the failed payload, retry count, error class, error
message, failure type, and first/last failure timestamps. A unique
`(source_table, source_id)` race reuses that review row and does not insert
a second one.

Dead letters are review surfaces, not destructive cleanup. Operators should
inspect the failure type before deciding whether to replay, patch data, or keep
the record as terminal evidence.

## Realtime Dispatch

`DomainEventTransport` can publish compatible domain events to
`PgNotifier`. Realtime delivery is best-effort: notifier failure is classified
and observable, but canonical writes and SSR reads remain authoritative.

## Worker Lifecycle

`GPForum::Bootstrap::Workers` wires the production outbox dispatcher from the
same service boundaries used by SSR:

- search indexing;
- notification fanout;
- cache invalidation;
- attachment scanning;
- media processing;
- personal feed projection;
- reputation and trust snapshot updates;
- identity mail delivery;
- realtime NOTIFY fanout.

The direct worker command can run one bounded batch:

```sh
script/gpforum-carton exec bin/gpforum-outbox-dispatch --once --limit 100
```

or a continuous loop suitable for a process supervisor:

```sh
script/gpforum-carton exec bin/gpforum-outbox-dispatch --loop --limit 100 --sleep 5
```

The loop exits cleanly on `INT` or `TERM`, prints one operational summary per
batch, and keeps write, dispatch, and dead-letter behavior inside
`GPForum::Service::Outbox::Dispatcher`. Failure classification,
attempt/backoff policy, and PostgreSQL claim SQL live in
`Outbox::FailureType`, `Outbox::Retry`, and `Outbox::ClaimQuery`.

The loop waits `--sleep` seconds only after a batch smaller than `--limit`.
A full batch means more is waiting, so the next is claimed at once and a
backlog drains at the handlers' speed. A failed message waits for its
backoff, not for the loop, so failures cannot make it spin.

A classified `permanent` failure cancels and dead-letters on that attempt.
Transient and other classified failures retry until `max_attempts`, then
cancel. Cancelled rows are not claimed again. Operator review is
`docs/ops/dead-letters.md`.

A worker that claims a row and crashes before `transport->dispatch` leaves
the message `running` with a bounded lock. Other workers skip a fresh lock.
After `locked_until` the row is eligible again and is delivered once. A
crash after dispatch and before mark-done is the same reclaim path; handlers
already completed skip on replay. Identity mail is not skip-wrapped: a
retry after send and before mark-done resends from the outbox payload.
EventLog stores `kind` and `token_id` only. Completed outbox rows are
purged.

Minion integration is opt-in so development and single-process SSR do not gain
mandatory worker infrastructure. Canonical writes still go to PostgreSQL
`outbox_messages`. `bin/gpforum-outbox-dispatch` is the required dispatcher and
does not load Minion, even when `GPFORUM_MINION_ENABLED=1` is present in the
shared environment file.

Enable Minion only with an explicit PostgreSQL backend URL:

```sh
GPFORUM_MINION_ENABLED=1 \
GPFORUM_MINION_PG_URL=postgresql://gpforum@/gpforum_minion \
script/gpforum-carton exec perl -Ilib bin/gpforum minion worker
```

The optional PostgreSQL dependency bundle includes `Mojo::Pg`, which Minion's
PostgreSQL backend requires. If Minion is enabled in a web or Minion-worker
process without a URL, without `Mojo::Pg`, or without a reachable backend,
startup fails with `Minion PostgreSQL backend is unavailable` instead of
silently skipping workers. Direct outbox dispatch remains the fallback.
