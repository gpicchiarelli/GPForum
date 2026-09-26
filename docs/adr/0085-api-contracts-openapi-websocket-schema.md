# ADR 0085: API Contracts, OpenAPI and Websocket Schema

## Status

Accepted. Converted on 2026-09-19 from `prompt/37.txt` ("GPForum - API
Contracts, OpenAPI & Websocket Schema Constitution"); this ADR replaces the
prompt as the binding source.

## Context

JSON responses, websocket messages and webhooks are consumed by browsers,
integrations and future clients; when they are incidental controller output
they drift and break consumers. GPForum needs mandatory rules for API
contract format, OpenAPI description, websocket message schemas, pagination,
error responses, webhook contracts and compatibility. The rules are
mandatory for external and internal API design and govern the web, realtime
and integration surfaces of every bounded context.

## Decision

### Cross-ADR alignment

- ADR 0094 (accessibility): browser-facing API and websocket schemas that
  drive UI state MUST preserve accessibility semantics. Dynamic states,
  realtime messages, notification updates, validation errors and
  dialog/menu states MUST expose enough structured data for accessible
  rendering and assistive-safe updates.

### Contract philosophy

APIs are contracts, not incidental controller output.

Every public API MUST be: documented; versioned; permission-aware; testable;
backward-compatible within a version.

### OpenAPI

- HTTP APIs SHOULD be described with OpenAPI where exposed to clients.
- OpenAPI specs SHOULD define: paths; methods; request schemas; response
  schemas; error schemas; authentication; authorization notes; rate-limit
  behavior.
- The OpenAPI spec MUST not document endpoints that are not implemented
  unless marked experimental.

### Error format

- API errors SHOULD use a consistent shape: `error_code`; `message`;
  `correlation_id`; `details` where safe; `retry_after` where applicable.
- Messages MUST be safe for the caller.
- Internal details MUST remain hidden.

### Pagination

- Pagination MUST be explicit.
- Supported models MAY include: cursor pagination; keyset pagination;
  limited offset pagination for small admin views.
- Large public lists SHOULD prefer cursor or keyset pagination.
- Responses SHOULD include: `items`; `next_cursor` where applicable;
  `has_more`; `limit`.

### Authentication

- API authentication MAY include: browser session; API token; signed webhook
  secret; future OAuth-like integration.
- Authentication MUST be separated from authorization.

### Websocket messages

- Websocket messages MUST define: `type`; `schema_version`;
  `correlation_id` where applicable; `payload`.
- Subscription messages MUST be authorized.
- Server messages MUST be safe under replay, reconnect and duplicate
  delivery.

### Webhook contracts

- Webhooks MUST define: event type; schema version; signature; timestamp;
  delivery id; retry policy.
- Webhook receivers MUST validate signatures.
- Webhook senders MUST avoid duplicate side effects through idempotency
  keys.

### Compatibility

- Breaking API changes MUST require: a version change; migration notes; a
  deprecation period where feasible; contract tests.
- Experimental APIs MUST be clearly marked.

## Consequences

- Every JSON, websocket or webhook payload is a versioned contract with
  tests, so renaming a field is a compatibility decision, not a refactor.
- Idempotent, replay-safe messages let realtime clients reconnect and
  webhook receivers retry without duplicate side effects.
- Open conflicts: JSON error bodies built by `GPForum::Web::ErrorPayload`
  use `status`, `error`, `title` and `errors` rather than `error_code`,
  `message`, `correlation_id`, `details` and `retry_after`; the correlation
  id is exposed only as the `X-Request-ID` response header. No OpenAPI
  document exists; `API.md` states that no separate `/api/v1` surface has
  been introduced yet.

## Alignment

- ADRs: 0094 (cross-alignment), 0060 (API and integration), 0072 (HTTP
  response rules), 0078 (provider webhooks), 0083 (webhook plugins); 0006
  (LISTEN/NOTIFY realtime transport), 0007 (websocket authorization policy),
  0008 (realtime event contracts), 0017 (realtime handshake access).
- Code: `lib/GPForum/Web/ErrorPayload.pm`,
  `lib/GPForum/Web/RealtimePayload.pm`,
  `lib/GPForum/Service/Realtime/EventEnvelope.pm`,
  `lib/GPForum/Service/Realtime/SubscriptionPolicy.pm`,
  `lib/GPForum/Domain/EventEnvelope.pm`.
- Tests: `t/20-realtime.t`, `t/76-web-error-payload.t`,
  `t/77-web-technical-payloads.t`, `t/113-web-realtime-access.t`.
- Docs: `API.md`, `EVENTS.md`, `docs/realtime.md`.
