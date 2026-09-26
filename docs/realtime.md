# Realtime Architecture

GPForum realtime is an enhancement boundary. PostgreSQL, event logs, outbox
messages, SSR pages, and polling endpoints remain authoritative.

## Flow

```text
Domain event
  -> outbox_messages
  -> outbox dispatcher / domain event transport
  -> PostgreSQL NOTIFY gpforum_domain_events
  -> GPForum::Service::Realtime::PgListener
  -> GPForum::Service::Realtime::ListenerSupervisor
  -> GPForum::Service::Realtime::Hub
  -> authenticated websocket subscribers
```

If LISTEN/NOTIFY is unavailable, writes still succeed, the listener/notifier
report degraded transport state, the listener can replay recent completed
outbox messages through bounded cursor polling, and clients continue to use
polling fallback for canonical state. Missed notification badges are rebuilt
from `notifications` and `notification_inbox`, not from in-memory handler
results.

## Listener Lifecycle

The listener is supervised inside each Mojolicious web process. This is
intentional: websocket connections live in web workers, so a standalone listener
process without those connections could observe notifications but could not
deliver websocket fanout.

Enable the lifecycle hook with:

```sh
GPFORUM_REALTIME_LISTENER_ENABLED=1
```

Optional tuning:

```sh
GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS=1
GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS=5
GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS=30
```

The bootstrap hook starts the supervisor lazily on request dispatch and then
keeps polling through the process IOLoop. Starts are idempotent, reconnects use
a bounded backoff timer, and the supervisor registers IOLoop finish cleanup so
shutdown removes timers before unlistening.

## Websocket Contract

`GET /realtime` upgrades to websocket only for authenticated sessions.
Origin matching, payload size, and subscribe-message shape are decided by
`GPForum::Web::RealtimeAccess`. The controller still owns rate limits, hub
registration, telemetry, and error frames.

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
transport, invalid payloads, malformed payloads, duplicate event suppression,
`listen_notify_received`, outbox polling receives, reconnect count, and
delivered events.
`ListenerSupervisor` exposes enabled/running state, scheduled polls, poll
failures, reconnects and heartbeats.

## Security Model

The websocket handshake validates:

- authenticated session;
- same-origin `Origin` when present, via `Web::RealtimeAccess`;
- JSON payload size against the realtime byte limit;
- PostgreSQL-backed rate limit for `realtime.connect`, using the
  `user`-scope hash from `Web::RealtimeAccess`;
- per-user connection quotas.

Subscriptions validate:

- structured channel syntax;
- PostgreSQL-backed rate limit for `realtime.subscribe`, using the
  `user`-scope hash from `Web::RealtimeAccess`;
- policy-backed resource access;
- per-connection subscription quota.

Suspicious denials are recorded through `SecurityTelemetry` without storing raw
message bodies or private resource contents.

## Degraded Modes

| Failure | Behavior |
| --- | --- |
| NOTIFY unavailable | notifier returns `degraded`, outbox dispatch can continue, polling remains source of truth |
| LISTEN unavailable | listener status becomes `degraded`; websocket hub still handles local broadcasts |
| supervisor start failure | reconnect is scheduled after bounded backoff; SSR and polling continue |
| malformed NOTIFY payload | listener rejects payload and increments invalid counters |
| duplicate NOTIFY payload | listener suppresses recent duplicate event ids with bounded best-effort memory |
| websocket send failure | hub records failed delivery and does not affect canonical writes |
| process restart | websocket state is lost; clients reconnect and polling catches up |

## Scaling Guidance

Websocket state is process-local and disposable. Each web process runs its own
listener supervisor when enabled, and PostgreSQL LISTEN/NOTIFY gives fanout
between processes while all durable state remains in PostgreSQL tables. Do not
use websocket presence, subscriptions, or recent-event caches as authoritative
product state.
