# Moderation Workflow Boundary

`GPForum::Service::Moderation::Workflow` is the application boundary for
moderation writes from HTTP controllers.

Responsibilities:

- validate required command fields (`reason`, `resolution`) before persistence;
- invoke `ReportStore`, `ActionStore`, or `SuspensionStore`;
- leave transaction, event, audit, and outbox ownership inside stores;
- leave created-action, reversal, report, and suspension EventLog/AuditLog
  hashes on `Moderation::Event`;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'not_found' | 'failed',
    error  => $message_or_undef,
    errors => $field_errors_or_undef,
    stored => $store_result_or_undef,
}
```

Controllers use this contract to map workflow outcomes to redirects, SSR form
errors, or JSON responses. The workflow never performs HTTP rendering and never
duplicates persistence logic owned by stores. Queue limits, the
`moderation_http` write rate-limit hash, default filters, permission-target
hashes, and write-success statuses live on `Web::ModerationAccess`,
including queue, content, and suspension action/resource names.

Coverage lives in `t/95-moderation-workflow.t`, `t/130-moderation-event.t`,
and `t/135-web-moderation-access.t` and includes success, invalid input, and
missing-target outcomes for hide, assign, resolve, and suspend. HTTP route
ownership is covered by `t/94-moderation-controllers.t`.
