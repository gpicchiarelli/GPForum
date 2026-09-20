# Admin Workflow Boundary

`GPForum::Service::Admin::Workflow` is the application boundary for admin
authorization writes from HTTP controllers.

Responsibilities:

- validate required command fields before persistence;
- invoke `RoleCatalog`, `RoleBindingStore`, or `CategoryStore`; a category
  update whose fields already match skips the store restamp;
- reuse unique role, permission, and attach rows on conflict without a
  second audit;
- reuse unique category `(space_id, slug)` rows on conflict without a
  second event;
- reuse the unique default `general` space slug on conflict;
- reuse unique active role-binding scope rows on conflict without a
  second audit;
- require `command_id` on catalog, binding, and category writes and replay
  from `command_log` when the helper is present;
- hash actor and target fields only;
- leave transaction, event, audit, and outbox ownership inside stores;
- leave role-binding, catalog, and category AuditLog hashes on `Admin::Event`;
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

Controllers use this contract to map workflow outcomes to redirects, SSR form
errors, or JSON responses. The workflow never performs HTTP rendering and never
duplicates persistence logic owned by stores. Catalog page limits,
the `admin_http` write rate-limit hash, permission-target hashes, catalog
`view` action, write-success statuses, and Guard invalid-request payloads
live on `Web::AdminAccess`.

Category create also provisions a default public `general` space when none
exists, so the first administrator can add the first category without
PerformanceSeed.

Coverage lives in `t/97-admin-workflow.t`, `t/131-admin-event.t`,
`t/137-web-admin-access.t`, `t/145-admin-category-store.t`,
`t/152-write-unavailable.t`, and `t/153-lost-response-retry.t` and includes
success, invalid input, missing-binding, command replay, and first-category
outcomes. HTTP route ownership is covered by `t/96-admin-controllers.t`.
