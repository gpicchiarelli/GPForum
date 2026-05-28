# ADR 0006: PostgreSQL LISTEN/NOTIFY Realtime Transport

## Status

Accepted.

## Context

GPForum already uses PostgreSQL as the authoritative system of record and has a
transactional outbox. The websocket hub was process-local, which is acceptable
as an enhancement but insufficient for multi-process Hypnotoad deployments.

## Decision

Introduce `GPForum::Service::Realtime::PgNotifier` and
`GPForum::Service::Realtime::PgListener` as a PostgreSQL LISTEN/NOTIFY transport
between outbox dispatch and websocket fanout.

Websocket state remains disposable. Durable state stays in PostgreSQL tables and
clients retain polling fallback.

## Consequences

Multi-process fanout no longer requires Redis or another mandatory service.
NOTIFY payloads are bounded and validated. Transport failures are classified as
degraded operational state instead of breaking canonical writes.

## Alternatives Rejected

- Redis pub/sub: rejected as mandatory infrastructure because GPForum is
  PostgreSQL-first.
- Process-local-only fanout: rejected for production multi-process evidence.
- Websocket-authoritative state: rejected because reconnects and worker restarts
  must not lose canonical product state.

