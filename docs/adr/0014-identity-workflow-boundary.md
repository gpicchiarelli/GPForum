# ADR 0014: Identity Workflow Boundary

## Status

Accepted.

## Context

Identity HTTP controllers still coordinated registration prepare+store, login
credential checks, session revocation, and password/email commands after the
controller split. Forum posting, moderation, admin, and privacy already use
dedicated write workflows with a normalized `{ ok, status, error, errors,
stored }` contract. Longevity review item 5 asked remaining write paths to
converge on that shape without a generic framework.

## Decision

Introduce `GPForum::Service::Identity::Workflow` as the application boundary
for identity writes. Controllers keep CSRF, cookie-session rotation, and form
rendering. `identity_http` rate-limit hashes live on `Web::IdentityAccess`.
The workflow:

- prepares registrations then stores them, collapsing duplicate errors;
- authenticates login and maps failed credentials to `rejected`;
- revokes sessions, resets and changes passwords, and changes email.

`Identity::Store` and `Identity::Registration` keep persistence, hashing, and
token semantics. `Password` and `SessionToken` load `Crypt::URandom` lazily;
`Identity::Store` and its credential/session/token stores load `Service::Id`
lazily so tests can inject `Test::Id` without Crypt::URandom.
`gp_identity_workflow` is composed from the existing `gp_registration` and
`gp_identity_store` helpers so web tests that stub those helpers keep working.

## Consequences

Identity HTTP files no longer own field-presence checks or store exception
mapping for these writes. Login failures stay non-enumerative. Cookie-session
application remains HTTP-specific.

Tests cover the workflow contract in `t/103-identity-workflow.t`.

## Alternatives Rejected

- Keep orchestration in `Identity.pm` and `Identity::Password`: rejected
  because those files would keep growing around every new credential command.
- Fold HTTP validation into `Identity::Store`: rejected because the store
  already owns transactions and should not grow request-field presence checks.
- Introduce a generic write-workflow framework: rejected by the longevity
  review.

## Alignment

- `docs/architecture/identity-workflow.md`
- `docs/architecture/admin-workflow.md`
- `docs/architecture/privacy-workflow.md`
- `t/103-identity-workflow.t`
- `t/92-identity-controllers.t`
- `t/06-identity-web.t`
- `docs/adr/0034-identity-event.md`
- `docs/adr/0039-identity-login-logout-event.md`
- `t/141-identity-store-id.t`
