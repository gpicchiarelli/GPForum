# ADR 0078: Email, Notification Delivery and Communication

## Status

Accepted. Converted on 2026-09-19 from `prompt/30.txt` ("GPForum - Email,
Notification Delivery & Communication Constitution"); this ADR replaces the
prompt as the binding source.

## Context

Outbound messages leave the platform's control and can leak private
content, duplicate under retries or be abused for account takeover. GPForum
needs mandatory rules for the email architecture, verification and password
reset flows, digest delivery, notification channels, unsubscribe behavior
and delivery observability. The rules govern the identity, notification and
worker bounded contexts and any feature that sends outbound communication.

## Decision

### Cross-ADR alignment

- ADR 0094 (accessibility): notification and email surfaces MUST be
  accessible. Notification inboxes, badges, read/unread state, digests,
  unsubscribe flows and realtime notification updates MUST expose accessible
  text/state and MUST NOT rely on badge-only, color-only or disruptive
  live-region behavior.
- ADR 0101 (retrieval): digests, feed emails, notification excerpts and
  syndication-adjacent communication MUST remain permission-aware,
  moderation-aware, deletion-aware, anti-leak, rate-limited, and derived
  from safe canonical or projection state.

### Communication philosophy

Outbound communication is a user trust boundary.

GPForum MUST send messages that are: expected; permission-aware;
rate-limited; auditable; privacy-safe; unsubscribe-aware where applicable.

The platform MUST avoid: leaking private content in email; sending duplicate
messages during retries; exposing moderation secrets; relying on email as a
secure identity proof after account compromise.

### Email use cases

- Email MAY be used for: account verification; password reset; security
  alerts; notification delivery; digest delivery; moderation notifications;
  policy updates.
- Security-sensitive email MUST use short-lived signed tokens.

### Delivery architecture

- Email delivery MUST be asynchronous.
- HTTP requests MUST NOT block on provider delivery.
- Delivery attempts MUST record: message type; recipient user; provider;
  status; `attempted_at`; error code; correlation id.
- Retries MUST be idempotent.

### Templates

- Email templates MUST be: versioned; localizable; plaintext-compatible;
  HTML-safe where HTML email exists.
- Templates MUST NOT include: raw unsafe user HTML; secret tokens in logs;
  private content beyond the minimum required.

### Verification

- Email verification MUST: create a short-lived token; store the token hash,
  not the raw token; bind the token to user and purpose; expire the token;
  emit audit events.
- Verification links MUST be single-purpose.

### Password reset

Password reset MUST: avoid confirming whether an email exists; use
short-lived hashed tokens; revoke active sessions after successful reset
where policy requires; emit security events; rate-limit requests.

### Digests

- Digest delivery SHOULD: respect subscriptions; respect notification
  preferences; respect visibility at generation time; avoid duplicate
  content; support unsubscribe.
- Digest generation MUST be asynchronous.

### Bounce and complaint handling

- The platform SHOULD support: bounce processing; complaint processing;
  delivery suppression; provider webhook signature validation.
- Users with failing email delivery SHOULD not cause unbounded retry loops.

### Unsubscribe

- Non-security notification emails MUST support unsubscribe.
- Unsubscribe links MUST be scoped and safe.
- Security alerts SHOULD remain deliverable unless the account email is
  invalid or policy requires suppression.

## Consequences

- Email is always sent asynchronously, so request latency is independent of
  provider latency and retries can be made idempotent.
- Tokens are stored only as hashes and bound to a purpose, which limits the
  damage of a database or log leak.
- Delivery attempts become auditable records, adding a table and retention
  obligation (ADR 0074).
- Open conflicts: no application mailer or delivery adapter is wired yet.
  `docs/audit/email-lifecycle.md` records that verification and reset
  tokens are hashed, single-use and expiring, but no asynchronous email
  delivery, delivery-attempt records, templates or bounce handling exist in
  the repository.

## Alignment

- ADRs: 0094 and 0101 (cross-alignment), 0056 (workers), 0074 (privacy and
  retention), 0077 (email configuration), 0085 (webhook contracts); 0009 and
  0025 (outbox retry), 0014 (identity workflow), 0015 (attachment and
  notification workflow), 0043 (notification access).
- Code: `lib/GPForum/Service/Identity/TokenStore.pm`,
  `lib/GPForum/Service/Identity/AccountStore.pm`,
  `lib/GPForum/Controller/Identity/Email.pm`,
  `lib/GPForum/Controller/Identity/Password.pm`,
  `lib/GPForum/Service/Notification/`.
- Migrations: `migrations/005_notifications_subscriptions.sql`,
  `migrations/025_identity_lifecycle_tokens.sql`.
- Tests: `t/06-identity-web.t`, `t/08-identity-store.t`,
  `t/17-notifications.t`, `t/107-notification-workflow.t`,
  `t/110-identity-account-store.t`.
- Docs: `docs/audit/email-lifecycle.md`,
  `docs/architecture/notification-workflow.md`.
