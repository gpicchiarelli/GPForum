# ADR 0008: Versioned Realtime Event Contracts

## Status

Accepted.

## Context

Realtime messages existed as ad hoc hashes for `thread.update` and
`notification.badge`. Multi-process transport needs explicit serialization and
validation so DBIx rows or oversized payloads cannot leak into websocket output.

## Decision

Use `GPForum::Service::Realtime::EventEnvelope` for websocket fanout payloads.
Every event carries `event_id`, `type`, `schema_version`, `occurred_at`,
aggregate metadata, actor metadata, `payload`, and `metadata`.

## Consequences

Payloads are JSON-serializable, bounded, and additive-evolution friendly. Tests
can use fixtures without constructing DBIx::Class rows.

## Alternatives Rejected

- Reuse domain event transport payload verbatim: rejected because realtime
  payloads have a smaller public contract and stricter size needs.
- Send raw handler hashes: rejected because it couples workers, controllers and
  websocket clients too tightly.

