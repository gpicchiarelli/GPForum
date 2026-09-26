# Privacy Workflow Boundary

`GPForum::Service::Privacy::Workflow` is the application boundary for privacy
writes from HTTP controllers.

Responsibilities:

- validate required command fields before persistence;
- request and complete member export bundles;
- create member deletion requests;
- approve deletion requests, create legal holds, and complete erasure jobs;
- complete an incomplete legal-hold block without a second event, and skip
  request status and job `last_error` writes when they already match;
- complete the deletion request on an already-done erasure retry without a
  second action, and skip the request restamp when already completed;
- create the erasure job before the approval action and reuse it on unique
  conflict without a second action or event;
- leave transaction, event, audit, and outbox ownership inside existing
  deletion, export, and hold stores;
- leave deletion-request/job accessors on `Privacy::Record`, anonymized
  user identity on `Privacy::Erasure`, approval/completion replay on
  `Privacy::Completion`, and event/audit hashes (including retention-hold
  created envelopes) on `Privacy::Event`;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'not_found' | 'conflict' | 'failed',
    error  => $message_or_undef,
    errors => $field_errors_or_undef,
    stored => $store_result_or_undef,
}
```

`conflict` maps store results that return `ok => 0`, including an active
retention hold during approval or erasure.

Controllers use this contract to map workflow outcomes to redirects, SSR form
errors, or JSON responses. The workflow never performs HTTP rendering and never
duplicates persistence logic owned by stores.

HTTP errors go through `GPForum::Web::Guard`, which renders existing
`ErrorPayload` contracts via `Responder`. Page limits, the `privacy_http`
write rate-limit hash, permission-target hashes, catalog `view` action,
review write-success statuses, and blocked-hold payloads live on
`Web::PrivacyAccess`.

Coverage lives in `t/101-privacy-workflow.t`, `t/119-privacy-erasure.t`,
`t/125-privacy-completion.t`, `t/128-privacy-event.t`, and
`t/136-web-privacy-access.t`. HTTP route ownership is covered by
`t/100-privacy-controllers.t`.
