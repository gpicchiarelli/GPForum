# ADR 0022: Attachment Download Access Boundary

## Status

Accepted.

## Context

`Attachment::Store` mixed intent persistence, linking, scan/variant lifecycle,
orphan cleanup, event/audit writes, row accessors, and download authorization.
Downloadability, visibility, and owner checks used high-complexity helpers.
Longevity review listed the store as the largest remaining service after the
I18N split. Download rules needed unit coverage without schema or
`Crypt::URandom`.

## Decision

Introduce dedicated helpers behind the existing store facade:

- `GPForum::Service::Attachment::Record` owns hash/row accessors and public
  attachment views;
- `GPForum::Service::Attachment::DownloadAccess` owns downloadability, owner
  checks, target visibility, visibility grants, and the linked-versus-unlinked
  download payload.

`Attachment::Store` still finds attachments, links, and post/thread rows, and
still writes EventLog, OutboxMessage, and AuditLog.

## Consequences

Visibility rules are testable with plain hashes. HTTP and
`Attachment::Workflow` keep calling `Store->download_for`. Profile links remain
owner-only. Public posts stay anonymous-readable. Member and private targets
keep their previous grants, including owner override.

## Alternatives Rejected

- Fold download rules into `Attachment::Delivery`: rejected because delivery
  owns byte reads after authorization.
- Reuse `Identity::Support` for row access: rejected because attachment
  persistence must not depend on the identity bounded context.

## Alignment

- `docs/architecture/attachment-workflow.md`
- `docs/adr/0027-attachment-lifecycle.md`
- `t/22-attachments.t`
- `t/118-attachment-download-access.t`
