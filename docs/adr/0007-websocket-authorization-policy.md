# ADR 0007: Strict Websocket Subscription Authorization

## Status

Accepted.

## Context

The previous `ChannelAuthorizer` allowed non-notification channels when no
permission engine was configured. That permissive fallback could expose private
or moderated resources through realtime subscriptions.

## Decision

Realtime subscriptions now deny by default. `realtime.subscribe` is the explicit
permission action, and `SubscriptionPolicy` owns resource-specific checks for
thread visibility, notification ownership, privileged queues, feed, and future
presence channels.

## Consequences

Unknown and malformed channels fail predictably. Notification channels remain
user-scoped. Controllers collect websocket messages and delegate authorization
to services.

## Alternatives Rejected

- Public default for thread channels: rejected because hidden/private resource
  leakage is worse than requiring explicit policy.
- Controller-local authorization: rejected to preserve service boundaries and
  testability.

