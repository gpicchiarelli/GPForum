# ADR 0013: Privacy Workflow Boundary

## Status

Accepted.

## Context

The privacy HTTP controller previously coordinated member export completion,
deletion requests, staff review, legal holds, and erasure jobs directly. Hold
placement looked up the deletion request, created a retention hold, and then
called `DeletionWorkflow` from the controller. Forum posting, moderation, and
admin already use dedicated write workflows. Longevity review item 5 asked
remaining write paths to converge on that shape without a generic framework.
Item 1 asked for shared HTTP helpers for CSRF, auth, and error rendering.

## Decision

Introduce `GPForum::Service::Privacy::Workflow` as the application boundary for
privacy writes, and split HTTP ownership:

- `Controller::Privacy` keeps the member dashboard;
- `Controller::Privacy::Requests` owns member export and deletion writes;
- `Controller::Privacy::Review` owns staff review, approval, hold, and erasure.

`GPForum::Web::Guard` renders CSRF, authentication, permission, validation,
not-found, conflict, and system-failure payloads through `Responder`.

The workflow validates required fields, orchestrates existing privacy stores,
and returns a normalized result contract: `ok`, `status`, `error`, `errors`,
and `stored`. Active holds surface as `conflict`.

Stores continue to own DBIx::Class writes and transaction boundaries.
Controllers continue to own CSRF, authentication, permission checks, HTTP
status, redirects, and content negotiation.

## Consequences

Privacy HTTP files are smaller and no longer own hold orchestration. Failure
handling is deterministic for invalid input, missing rows, blocked holds, and
store exceptions. Existing deletion-store idempotency for approval and job
completion is unchanged.

Tests cover controller/route ownership in `t/100-privacy-controllers.t` and the
workflow contract in `t/101-privacy-workflow.t`.

## Alternatives Rejected

- Keep orchestration in `Privacy.pm`: rejected because hold creation mixed
  review lookup, hold persistence, and deletion-state updates in HTTP code.
- Fold HTTP validation into `DeletionWorkflow`: rejected because that store
  already owns transactional deletion semantics and should not grow request
  field checks.
- Introduce a generic write-workflow framework: rejected by the longevity
  review. A dedicated privacy workflow matching posting, moderation, and admin
  is enough.

## Alignment

- `docs/architecture/privacy-workflow.md`
- `docs/architecture/admin-workflow.md`
- `docs/architecture/moderation-workflow.md`
- `t/100-privacy-controllers.t`
- `t/101-privacy-workflow.t`
- `t/62-privacy-web.t`
- `docs/adr/0045-privacy-access.md`
