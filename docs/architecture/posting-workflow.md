# Posting Workflow Boundary

`GPForum::Service::Forum::PostingWorkflow` is the application boundary for
creating threads and replies from HTTP controllers.

Responsibilities:

- validate category existence before thread composition;
- validate thread existence and locked state before reply composition;
- invoke `ThreadComposer` or `PostComposer`;
- invoke `ThreadStore` or `PostStore`;
- leave transaction ownership inside stores;
- record mentions only after successful persistence;
- degrade safely if mention recording fails;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok       => 0 | 1,
    status   => 'ok' | 'invalid' | 'not_found' | 'forbidden' | 'failed',
    error    => $message_or_undef,
    prepared => $composer_result_or_undef,
    stored   => $store_result_or_undef,
}
```

Controllers use this contract to map workflow outcomes to redirects, SSR form
errors, or JSON responses. The workflow never performs HTTP rendering and never
duplicates persistence logic owned by stores.

Coverage lives in `t/72-forum-bootstrap-workflow.t` and includes success,
invalid input, missing category, missing thread, locked thread, store failure,
and degraded mention recording.
