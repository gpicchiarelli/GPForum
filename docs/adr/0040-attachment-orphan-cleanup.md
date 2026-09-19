# ADR 0040: Attachment Orphan Cleanup Policy

## Status

Accepted.

## Context

ADR 0027 extracted upload, scan, and delete replay onto
`Attachment::Lifecycle`, but orphan cleanup still mixed the intent-state
search, default row cap, default reason, and actor fallback with resultset
deletes. Those decisions needed unit coverage without schema or
`Crypt::URandom`. Longevity review item 5 asked remaining write paths to own
policy hashes outside persistence.

## Decision

Extend `GPForum::Service::Attachment::Lifecycle` with:

- the default orphan candidate limit and search clause;
- oldest-first search attributes;
- actor and reason fallbacks;
- the normalized cleanup result hash;
- per-post and per-attachment link fetch caps, including the `post` target.

`Attachment::Store` still loads candidates, skips linked attachments, and
soft-deletes through the existing public `cleanup_orphans` signature.

## Consequences

Orphan cleanup policy is unit-testable with plain hashes. Upload pipeline
workers keep calling the store.

## Alternatives Rejected

- Fold orphan search into `Attachment::Record`: rejected because Record is a
  row accessor, not cleanup policy.
- Keep defaults in the store: rejected because the store is persistence.

## Alignment

- `docs/adr/0027-attachment-lifecycle.md`
- `docs/architecture/attachment-workflow.md`
- `t/22-attachments.t`
- `t/123-attachment-lifecycle.t`
