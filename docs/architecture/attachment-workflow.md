# Attachment Workflow Boundary

`GPForum::Service::Attachment::Workflow` is the application boundary for
attachment uploads, author deletes, and downloads from HTTP controllers.

Responsibilities:

- look up a visible post before linking an upload or deleting a linked file;
- reject uploads and deletes from anyone other than the post author;
- delegate binary storage and linking to `Attachment::UploadPipeline`;
- delegate linked soft-delete to `Attachment::Store`;
- delegate authorized byte delivery to `Attachment::Delivery`;
- leave transaction, event, audit, and object-storage ownership inside those
  services;
- reuse unique attachment-link and variant rows on conflict;
- remint `attachment_id` and `object_key` once when the unique primary
  key conflicts with a different object, and do not return another
  attachment;
- remint `attachment_link_id` once when the unique primary key conflicts,
  and do not return another link;
- remint `attachment_variant_id` once when the unique primary key
  conflicts, and do not return another variant;
- leave download visibility and authorized payloads on
  `Attachment::DownloadAccess`, lifecycle replay, orphan-cleanup policy, and
  link fetch caps on `Attachment::Lifecycle`, event/audit hashes on
  `Attachment::Event`,
  and row access on `Attachment::Record`;
- require `command_id` on upload and delete writes and replay from
  `command_log` when the helper is present;
- hash actor and target ids only, never uploaded bytes;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'not_found' | 'forbidden' | 'failed' | 'conflict',
    error  => $message_or_undef,
    errors => $field_errors_or_undef,
    stored => $store_result_or_undef,
}
```

CSRF, authentication, and upload rate limits stay in
`Controller::Attachments::Base`, with rate hashes and filename policy on
`Web::AttachmentAccess`. Successful uploads keep `post` on `stored`
so HTTP can redirect to the thread fragment.

Coverage lives in `t/105-attachment-workflow.t`,
`t/118-attachment-download-access.t`, `t/123-attachment-lifecycle.t`,
`t/127-attachment-event.t`, `t/133-web-attachment-access.t`,
`t/152-write-unavailable.t`, and `t/153-lost-response-retry.t`. HTTP route
ownership is covered by `t/104-attachment-controllers.t`.
