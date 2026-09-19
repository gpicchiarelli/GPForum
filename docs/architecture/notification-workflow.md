# Notification Workflow Boundary

`GPForum::Service::Notification::Workflow` is the application boundary for
notification inbox and preference writes from HTTP controllers.

Responsibilities:

- mark a recipient inbox row read through `Notification::Dispatcher`;
- replace member channel preferences through `Notification::PreferenceStore`;
- map missing rows to `not_found`;
- leave projection and persistence ownership inside those services;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'not_found' | 'failed',
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

Coverage lives in `t/107-notification-workflow.t` and
`t/134-web-notification-access.t`. HTTP route ownership is covered by
`t/106-notification-controllers.t`.
