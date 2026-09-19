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
message, failure type, and first/last failure timestamps.

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
- realtime NOTIFY fanout.

The direct worker command can run one bounded batch:

```sh
carton exec bin/gpforum-outbox-dispatch --once --limit 100
```

or a continuous loop suitable for a process supervisor:

```sh
carton exec bin/gpforum-outbox-dispatch --loop --limit 100 --sleep 5
```

The loop exits cleanly on `INT` or `TERM`, prints one operational summary per
batch, and keeps write, dispatch, and dead-letter behavior inside
`GPForum::Service::Outbox::Dispatcher`. Failure classification,
attempt/backoff policy, and PostgreSQL claim SQL live in
`Outbox::FailureType`, `Outbox::Retry`, and `Outbox::ClaimQuery`.

Minion integration is opt-in so development and single-process SSR do not gain
mandatory worker infrastructure. Enable it only with an explicit PostgreSQL
backend URL:

```sh
GPFORUM_MINION_ENABLED=1 \
GPFORUM_MINION_PG_URL=postgresql://gpforum@/gpforum_minion \
carton exec perl -Ilib bin/gpforum minion worker
```

The optional PostgreSQL dependency bundle includes `Mojo::Pg`, which Minion's
PostgreSQL backend requires. If Minion is enabled without a URL or backend
support, startup fails explicitly instead of silently skipping workers.
