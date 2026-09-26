# ADR 0060: API, Integration and External Interfaces

## Status

Accepted. Converted on 2026-09-19 from `prompt/12.txt` ("GPForum — API,
Integration & External Interface Constitution"); this ADR replaces the prompt
as the binding source.

## Context

APIs and integrations are the surfaces where untrusted, possibly hostile
clients meet GPForum's business authority. Once published they become
permanent architectural contracts, so their stability, security and
operational limits must be decided up front.

This ADR is foundational and mandatory. It defines the API architecture,
external integration model, interface stability, serialization standards,
authentication requirements, rate limiting rules, federation boundaries and
long-term interoperability principles. It governs HTTP, websocket,
administrative, integration, event, webhook, search and upload interfaces,
and any future federation or third-party integration.

## Decision

### API Philosophy

- APIs are authoritative external contracts, integration surfaces, security
  boundaries and operational interfaces.
- The API layer MUST prioritize stability, explicitness, auditability,
  security, versionability and operational predictability.
- The platform MUST avoid implicit behavior, undocumented side effects,
  unstable response structures and authorization ambiguity.

### External Interface Philosophy

- External interfaces MUST remain deterministic, documented,
  permission-aware, rate-limited and observable.
- All external consumers MUST be treated as untrusted, potentially hostile
  and operationally unpredictable.

### API Architecture

- The platform SHOULD expose HTTP APIs, websocket APIs, administrative APIs
  and integration APIs.
- APIs MUST remain server-authoritative, validation-aware and
  authorization-aware.
- Business authority MUST remain server-side.

### Versioning Philosophy

- APIs MUST support explicit versioning.
- Versioning SHOULD remain stable, predictable and backwards-aware where
  feasible.
- Breaking changes MUST remain explicit and documented, and MUST support
  migration planning.

### Serialization Philosophy

- Preferred serialization: JSON.
- Serialization MUST remain deterministic, explicit and schema-aware.
- Responses MUST avoid hidden fields, unstable ordering assumptions and
  implicit data expansion.

### API Payload Philosophy

- Payloads SHOULD contain stable identifiers, explicit timestamps, explicit
  pagination metadata and permission-aware visibility.
- Payloads SHOULD avoid giant nested structures, uncontrolled expansion and
  hidden side effects.

### API Authentication

- APIs MUST require explicit authentication where appropriate.
- Authentication MAY support session authentication, token authentication,
  API keys and OAuth-compatible workflows.
- Administrative APIs MUST require elevated authentication.

### Authorization Enforcement

- All APIs MUST enforce authorization server-side, validate resource
  ownership, validate permission scope and remain deny-by-default.
- Frontend visibility MUST NOT define authorization.

### API Rate Limiting

- All external APIs MUST support rate limiting, abuse throttling, request
  quotas and anomaly detection.
- Rate limits MAY vary by authentication level, trust level, endpoint
  category and operational role.

### Pagination Philosophy

- All collection APIs MUST paginate, expose bounded responses and avoid
  unbounded scans.
- Pagination MUST remain deterministic, cursor-safe where appropriate and
  scalable.
- Unbounded collection responses are prohibited.

### Filtering & Querying

- Filtering MUST remain explicit, validated and bounded.
- The API layer MUST avoid unrestricted query execution, unsafe search
  injection and arbitrary backend exposure.

### API Error Philosophy

- Errors MUST remain structured, machine-readable and security-aware.
- Errors MUST NOT leak stack traces, SQL, infrastructure details or sensitive
  operational state.
- Recommended fields: `error_code`, `message`, `correlation_id`.

### Idempotency

- Mutating APIs SHOULD support idempotency where appropriate.
- Critical workflows MUST tolerate retries, replay attempts and duplicate
  delivery.

### Websocket API Philosophy

- Realtime APIs MUST authenticate websocket connections, authorize
  subscriptions, validate event payloads and support reconnect workflows.
- Websocket APIs MUST remain eventually consistent, replay-tolerant and
  abuse-aware.

### Event API Philosophy

- The platform MAY expose event streams, webhook integrations and external
  notification systems.
- Event interfaces MUST remain replay-aware, permission-aware and
  rate-limited.

### Webhook Philosophy

- Webhook systems MUST support retry, signature validation and replay
  protection, and MUST remain observable.
- Webhooks MUST remain asynchronous, idempotent-aware and security-focused.

### Federation Philosophy

- Federation is OPTIONAL.
- If federation is implemented, trust boundaries MUST remain explicit, remote
  authority MUST remain constrained and local governance MUST remain
  authoritative.
- Federation MUST NOT bypass authorization, moderation or auditability.

### Third-Party Integration

- Integrations MUST remain permission-scoped, revocable and auditable.
- Third-party integrations MUST support token revocation, operational
  monitoring and abuse mitigation.

### API Stability

- Public APIs SHOULD prioritize compatibility, predictable evolution and
  explicit deprecation.
- Deprecated behavior MUST remain documented and time-bounded, and MUST
  support migration planning.

### Search APIs

- Search APIs MUST enforce authorization, remain rate-limited and avoid
  unrestricted backend exposure.
- Search responses MUST remain permission-filtered, pagination-aware and
  abuse-resistant.

### Administrative APIs

- Administrative APIs MUST remain isolated, require elevated permissions and
  remain fully auditable.
- Administrative interfaces MUST support MFA enforcement, operational
  attribution and correlation tracking.

### Upload APIs

- Upload workflows MUST validate MIME type, validate size, support scanning
  workflows and avoid unsafe execution.
- Uploads MUST remain asynchronous where appropriate and operationally
  isolated.

### API Observability

- API infrastructure MUST expose request latency, error rates, abuse metrics,
  rate-limit triggers and authorization failures.
- API behavior MUST remain observable.

### Schema Philosophy

- API schemas SHOULD remain explicit, documented, testable and version-aware.
- Implicit response mutation SHOULD be avoided.

### Documentation Philosophy

- External interfaces MUST remain documented, reproducible and testable.
- Documentation MUST include authentication requirements, authorization
  expectations, rate-limit behavior and error semantics.

### Security Philosophy for Integrations

- All external integrations MUST assume hostile clients, replay attempts,
  abuse automation and malformed payloads.
- External interfaces MUST remain defensive, observable and rate-limited.

### Operational Philosophy

- API systems MUST prioritize operational predictability, bounded resource
  usage, abuse resistance and graceful degradation.
- The platform MUST avoid uncontrolled external amplification.

### Long-Term Interface Goal

- GPForum APIs and integrations MUST remain stable, auditable, secure,
  scalable, distributed-safe and operationally sustainable.
- External interfaces are permanent architectural contracts.
- All future APIs and integrations MUST comply with this ADR.

## Consequences

- Every interface is deny-by-default, rate-limited, paginated and documented
  before it is exposed, so integrations cannot widen access or load beyond
  what the server grants.
- Contract stability costs flexibility: breaking changes need a new version,
  a documented, time-bounded deprecation and a migration plan.
- Webhooks, federation and third-party tokens add revocation, signature,
  replay-protection and monitoring work before they can ship.
- Open conflicts:
  - No versioned API surface exists. `API.md` defers REST routes to a future
    `/api/v1/...` while selected SSR routes already return JSON without an
    explicit version; if those responses count as APIs, "APIs MUST support
    explicit versioning" is not met.
  - `GPForum::Web::ErrorPayload` returns `error`, `status` and `title` (plus
    optional `errors`), not the recommended `error_code`, `message` and
    `correlation_id`; error payloads carry no correlation id.

## Alignment

- ADR 0085 (API contracts, OpenAPI and websocket schemas), ADR 0053
  (security), ADR 0057 and ADR 0070 (authorization and permission matrix),
  ADR 0072 (HTTP routes and workflows), ADR 0055 (realtime), ADR 0062
  (search), ADR 0079 (admin console), ADR 0083 (plugins and hooks).
- ADR 0007 (websocket subscription authorization), ADR 0008 (versioned
  realtime event contracts), ADR 0016 (shared HTTP access), ADR 0017
  (realtime handshake), ADR 0027 and ADR 0042 (attachment lifecycle and
  access), ADR 0046 (admin access), ADR 0047 (metrics token access).
- `API.md`, `EVENTS.md`, `SECURITY.md`, `docs/realtime.md`.
- `lib/GPForum/Web/ErrorPayload.pm`, `lib/GPForum/Web/Access.pm`.
- `t/76-web-error-payload.t`, `t/77-web-technical-payloads.t`,
  `t/55-security-abuse-hardening.t`, `t/113-web-realtime-access.t`.
