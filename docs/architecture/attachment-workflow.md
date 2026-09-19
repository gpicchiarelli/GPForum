# Attachment Workflow Boundary

`GPForum::Service::Attachment::Workflow` is the application boundary for
attachment uploads and downloads from HTTP controllers.

Responsibilities:

- look up a visible post before linking an upload;
- reject uploads from anyone other than the post author;
- delegate binary storage and linking to `Attachment::UploadPipeline`;
- delegate authorized byte delivery to `Attachment::Delivery`;
- leave transaction, event, audit, and object-storage ownership inside those
  services;
- leave download visibility and authorized payloads on
  `Attachment::DownloadAccess`, lifecycle replay, orphan-cleanup policy, and
  link fetch caps on `Attachment::Lifecycle`, event/audit hashes on
  `Attachment::Event`,
  and row access on `Attachment::Record`;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'not_found' | 'forbidden' | 'failed',
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
`t/127-attachment-event.t`, and `t/133-web-attachment-access.t`. HTTP route
ownership is covered by `t/104-attachment-controllers.t`.
