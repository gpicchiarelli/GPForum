# Identity Workflow Boundary

`GPForum::Service::Identity::Workflow` is the application boundary for identity
writes from HTTP controllers.

Responsibilities:

- validate required command fields before persistence;
- prepare registrations through `Identity::Registration` and persist them
  through `Identity::RegistrationStore` via the identity store facade;
- authenticate through `Identity::AuthStore` and revoke sessions through
  `Identity::Store`;
- complete password, email-change, and registration-verification commands
  through `Identity::AccountStore` via the identity store facade;
- deliver reset, email-change, and verification tokens through
  `Identity::Mailer` after the store transaction commits, then strip raw
  tokens from the workflow result;
- persist locale and theme preferences through `Identity::PreferenceStore`
  via the identity store facade;
- hide duplicate-account details behind a non-enumerative registration error;
- leave transaction, event, audit, and outbox ownership inside stores;
- leave registration, typed identity, and login/logout audit hashes on
  `Identity::Event`;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'rejected' | 'failed',
    error  => $message_or_undef,
    errors => $field_errors_or_undef,
    stored => $store_result_or_undef,
}
```

`rejected` is reserved for failed login attempts so controllers can return
HTTP 401 without revealing whether the identifier exists. Matching
credentials on a pending account are also `rejected` with `error` set to
`unverified` so HTTP can ask the member to verify without opening a
session. Cookie-session
rotation stays HTTP through `Web::CookieSession`, including the 30-day
cookie lifetime. Locale and theme cookies
stay HTTP through `Web::IdentityAccess` names and options; persistence goes
through this workflow. `identity_http` rate-limit hashes live on
`Web::IdentityAccess`.

Coverage lives in `t/103-identity-workflow.t`,
`t/110-identity-account-store.t`, `t/111-identity-auth-store.t`,
`t/112-identity-registration-store.t`, `t/114-web-cookie-session.t`,
`t/124-web-identity-access.t`, `t/129-identity-event.t`,
`t/141-identity-store-id.t`, `t/146-identity-mailer.t`, and
`t/147-identity-email-verification.t`. HTTP route
ownership is covered by `t/92-identity-controllers.t`.
`Password` and `SessionToken` load `Crypt::URandom` when hashing or issuing
tokens; `Identity::Store` loads `Service::Id` only for the default
`id_service`.
