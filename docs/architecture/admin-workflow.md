# Admin Workflow Boundary

`GPForum::Service::Admin::Workflow` is the application boundary for admin
authorization writes from HTTP controllers.

Responsibilities:

- validate required command fields before persistence;
- invoke `RoleCatalog`, `RoleBindingStore`, or `CategoryStore`;
- leave transaction, event, audit, and outbox ownership inside stores;
- leave role-binding, catalog, and category AuditLog hashes on `Admin::Event`;
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
duplicates persistence logic owned by stores. Catalog page limits,
permission-target hashes, catalog `view` action, write-success statuses, and
Guard invalid-request payloads live on `Web::AdminAccess`.

Category create also provisions a default public `general` space when none
exists, so the first administrator can add the first category without
PerformanceSeed.

Coverage lives in `t/97-admin-workflow.t`, `t/131-admin-event.t`,
`t/137-web-admin-access.t`, and `t/145-admin-category-store.t` and includes
success, invalid input, missing-binding, and first-category outcomes. HTTP
route ownership is covered by `t/96-admin-controllers.t`.
