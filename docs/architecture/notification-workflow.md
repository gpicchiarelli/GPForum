# Notification Workflow Boundary

`GPForum::Service::Notification::Workflow` is the application boundary for
notification inbox and preference writes from HTTP controllers.

Responsibilities:

- mark a recipient inbox row read through `Notification::Dispatcher`;
- mark every unread inbox row for a member through `Notification::Dispatcher`;
- replace member channel preferences through `Notification::PreferenceStore`;
  a second write of the same channel values skips the row restamp;
- reuse unique `(user_id, channel)` preference rows on conflict when the
  values already match;
- require `command_id` on preference writes and replay from `command_log`
  when the helper is present;
- map missing rows to `not_found`;
- leave projection and persistence ownership inside those services;
- leave unique inbox delivery replay inside `Notification::Dispatcher`;
- leave unique mark-read `(notification_id, recipient_user_id)` replay
  inside `Notification::Dispatcher`;
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

Inbox and mention listing stay HTTP reads against the dispatcher and mention
reader. Channel catalogs stay on the preference store. CSRF, authentication,
and write rate limits stay in `Controller::Notifications::Base` and
`Controller::Identity::Settings`, with page limits and rate hashes on
`Web::NotificationAccess`.

Coverage lives in `t/107-notification-workflow.t`,
`t/134-web-notification-access.t`, `t/152-write-unavailable.t`, and
`t/153-lost-response-retry.t`. HTTP route ownership is covered by
`t/106-notification-controllers.t`.
