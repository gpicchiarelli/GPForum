# Realtime Architecture

GPForum realtime is an enhancement boundary. PostgreSQL, event logs, outbox
messages, SSR pages, and polling endpoints remain authoritative.

## Flow

```text
Domain event
  -> outbox_messages
  -> outbox dispatcher / domain event transport
  -> PostgreSQL NOTIFY gpforum_realtime_events
  -> GPForum::Service::Realtime::PgListener
  -> GPForum::Service::Realtime::Hub
  -> authenticated websocket subscribers
```

If LISTEN/NOTIFY is unavailable, writes still succeed, the listener/notifier
report degraded transport state, and clients continue to use polling fallback.

## Websocket Contract

`GET /realtime` upgrades to websocket only for authenticated sessions.

Client subscribe message:

```json
{ "type": "subscribe", "channel": "thread:<thread_id>" }
```

Server control messages stay stable:

```json
{ "type": "realtime.connected", "connection_id": "...", "fallback": {} }
{ "type": "subscribed", "channel": "thread:<thread_id>" }
{ "type": "error", "reason": "forbidden" }
```

## Channels

Supported channel families are explicit:

| Family | Shape | Authorization |
| --- | --- | --- |
| thread | `thread:<thread_id>` | visible thread/category, visible moderation state, active authenticated actor, owner or ACL for private resources |
| notifications | `notifications:<user_id>` | own user id only |
| moderation | `moderation:<scope>` | moderation permission |
| admin | `admin:<scope>` | admin permission |
| feed | `feed:<user_id|personal>` | own feed only |
| presence | `presence:<scope>` | authenticated actor, future policy hook |

Unknown and malformed channels are denied by default. Denial reasons are
structured: `malformed_channel`, `unknown_channel`, `authentication_required`,
`wrong_recipient`, `invisible_resource`, and `forbidden`.

## Event Envelope

Realtime fanout uses `GPForum::Service::Realtime::EventEnvelope`.

Required fields:

- `event_id`
- `type`
- `schema_version`
- `occurred_at`
- `payload`

Supported metadata fields include:

- `correlation_id`
- `causation_id`
- `aggregate_type`
- `aggregate_id`
- `actor_id`
- `metadata`

Payloads are JSON-only, bounded in size, and never contain DBIx::Class result
objects. Evolution is additive: new consumers must ignore unknown fields.

## Operational Metrics

`/metrics` includes realtime hub counters:

- active websocket `connections`
- `subscriptions`
- `broadcasts`
- delivered messages
- broadcast failures
- malformed realtime events
- configured connection/subscription quotas

`PgNotifier` and `PgListener` expose snapshots for notify failures, degraded
transport, invalid payloads, duplicates, reconnect count, and delivered events.

## Security Model

The websocket handshake validates:

- authenticated session;
- same-origin `Origin` when present;
- PostgreSQL-backed rate limit for `realtime.connect`;
- per-user connection quotas.

Subscriptions validate:

- structured channel syntax;
- PostgreSQL-backed rate limit for `realtime.subscribe`;
- policy-backed resource access;
- per-connection subscription quota.

Suspicious denials are recorded through `SecurityTelemetry` without storing raw
message bodies or private resource contents.

## Degraded Modes

| Failure | Behavior |
| --- | --- |
| NOTIFY unavailable | notifier returns `degraded`, outbox dispatch can continue, polling remains source of truth |
| LISTEN unavailable | listener status becomes `degraded`; websocket hub still handles local broadcasts |
| malformed NOTIFY payload | listener rejects payload and increments invalid counters |
| duplicate NOTIFY payload | listener suppresses recent duplicate event ids with bounded best-effort memory |
| websocket send failure | hub records failed delivery and does not affect canonical writes |
| process restart | websocket state is lost; clients reconnect and polling catches up |

## Scaling Guidance

Websocket state is process-local and disposable. PostgreSQL LISTEN/NOTIFY gives
fanout between processes, while all durable state remains in PostgreSQL tables.
Do not use websocket presence, subscriptions, or recent-event caches as
authoritative product state.

