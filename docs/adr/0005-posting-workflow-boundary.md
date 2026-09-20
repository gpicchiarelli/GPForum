# ADR 0005: Posting Workflow Boundary

## Status

Accepted.

## Context

The forum HTTP controller previously coordinated thread and reply creation
directly: it collected input, called composers, called stores, handled locked
threads, recorded mentions, and mapped failures to HTTP responses. As the
controller gained auth, rate-limit, suspension, attachment, reporting, search,
and reading behavior, posting orchestration became the most important write path
to isolate.

## Decision

Introduce `GPForum::Service::Forum::PostingWorkflow` as the application boundary
for `create_thread`, `create_reply`, `edit_post`, `delete_post`, `restore_post`,
`edit_thread`, `delete_thread`, `restore_thread`, and `move_thread`.

The workflow validates category/thread preconditions, delegates command
preparation to composers, delegates persistence to stores, records mentions
after successful persistence, and returns a normalized result contract:
`ok`, `status`, `error`, `prepared`, and `stored`.

Stores continue to own DBIx::Class writes and transaction boundaries. Controllers
continue to own CSRF, authentication, rate limits, HTTP status, redirects, and
content negotiation.

## Consequences

The Forum controller is thinner and no longer owns persistence orchestration for
posting. Failure handling is deterministic for invalid input, missing category,
missing thread, locked thread, store failure, and mention degradation. Mention
recording can fail without corrupting a successfully persisted post.

Tests cover the workflow directly in `t/72-forum-bootstrap-workflow.t`.

## Alternatives Rejected

- Keep orchestration in `Forum.pm`: rejected because the controller would keep
  growing around the highest-risk write path.
- Move posting into DB stores: rejected because stores should own persistence,
  not HTTP-facing application decisions or mention side effects.
- Record mentions before persistence: rejected because failed writes could leave
  mention state for content that does not exist.
