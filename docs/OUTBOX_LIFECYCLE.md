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

