# Community Workflow Boundary

`GPForum::Service::Community::Workflow` is the application boundary for
thread bookmark, subscription, and member report writes from HTTP
controllers.

Responsibilities:

- save or restore a member bookmark through `Community::BookmarkStore`;
- soft-remove a member bookmark through `Community::BookmarkStore`;
- save or restore a thread subscription through
  `Notification::SubscriptionStore`;
- mute or revoke a thread subscription through
  `Notification::SubscriptionStore`;
- create a member report through `Moderation::ReportStore`;
- require `command_id` on those writes and replay from `command_log` when
  the helper is present;
- hash actor, target, and note, preference, or report reason fields only;
- map missing rows to `not_found`;
- leave unique-restore, unique reporter-target, already-applied mute,
  revoke, bookmark-remove, and already-active save stamps, and persistence
  ownership inside those stores;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'not_found' | 'failed' | 'conflict',
    error  => $message_or_undef,
    errors => $field_errors_or_undef,
    stored => $store_result_or_undef,
}
```

Feed and bookmark listing stay HTTP reads against the existing stores. CSRF,
authentication, visibility, and write rate limits stay in
`Controller::Forum::Community`, with target types and success statuses on
`Web::ForumAccess`.

Coverage lives in `t/156-community-workflow.t`, `t/32-forum-web.t`,
`t/35-forum-accessible-ssr.t`, `t/43-moderation-web.t`,
`t/61-mvp-user-flow.t`, `t/152-write-unavailable.t`, and
`t/153-lost-response-retry.t`.
