# ADR 0010: Moderation Workflow Boundary

## Status

Accepted.

## Context

The moderation HTTP controller previously coordinated report assignment,
content hide/restore/lock/unlock, action reversal, and suspensions directly:
it collected input, called stores, mapped missing rows to HTTP 404, and
duplicated reason/resolution validation beside CSRF and permission checks.
`PostingWorkflow` already established a thinner write boundary for forum
commands. Longevity review item 5 asked write workflows to converge on that
shape without introducing a generic framework.

## Decision

Introduce `GPForum::Service::Moderation::Workflow` as the application boundary
for moderation writes, and split HTTP ownership:

- `Controller::Moderation` keeps report, action, and suspension review pages;
- `Controller::Moderation::Queue` owns report assign/release/resolve;
- `Controller::Moderation::Actions` owns hide/restore/lock/unlock/reverse;
- `Controller::Moderation::Suspensions` owns suspend/revoke.

The workflow validates required fields, delegates persistence to existing
stores, and returns a normalized result contract: `ok`, `status`, `error`,
`errors`, and `stored`.

Stores continue to own DBIx::Class writes and transaction boundaries.
Controllers continue to own CSRF, authentication, permission checks, HTTP
status, redirects, and content negotiation.

## Consequences

Moderation HTTP files are smaller and no longer own persistence orchestration.
Failure handling is deterministic for invalid input, missing targets, and store
exceptions. Existing store-level state idempotency is unchanged; command-id
replay is not required for these routes.

Tests cover controller/route ownership in `t/94-moderation-controllers.t` and
the workflow contract in `t/95-moderation-workflow.t`.

## Alternatives Rejected

- Keep orchestration in `Moderation.pm`: rejected because the controller would
  keep growing around every new review action.
- Move HTTP validation into stores: rejected because stores should own
  persistence, not request-field presence checks.
- Introduce a generic write-workflow framework: rejected by the longevity
  review. A dedicated moderation workflow matching `PostingWorkflow` is enough.

## Alignment

- `docs/architecture/moderation-workflow.md`
- `docs/architecture/posting-workflow.md`
- `t/94-moderation-controllers.t`
- `t/95-moderation-workflow.t`
- `t/43-moderation-web.t`
- `docs/adr/0035-moderation-action-event.md`
- `docs/adr/0044-moderation-access.md`
