# Identity Workflow Boundary

`GPForum::Service::Identity::Workflow` is the application boundary for identity
writes from HTTP controllers.

Responsibilities:

- validate required command fields before persistence;
- prepare registrations through `Identity::Registration` and persist them
  through `Identity::RegistrationStore` via the identity store facade;
  unique user `id` collisions remint once and do not return another user's
  account;
- authenticate through `Identity::AuthStore` and revoke sessions through
  `Identity::Store`; unique `session_hash` and `session_id` collisions
  remint once inside `SessionStore` and do not return another user's
  session;
- complete password, email-change, and registration-verification commands
  through `Identity::AccountStore` via the identity store facade; a second
  password write of the same secret skips credential rotation; password
  reset to that same secret still consumes the token and revokes sessions;
  email-change confirm of the same verified address, or verification
  confirm for an already-active verified user skips the restamp; a unique
  race on `email_normalized` during confirm returns
  `email_already_registered` and does not restamp the user; a request
  for the member's already-verified address does not issue a token;
  unique `token_hash` and `token_id` collisions remint once inside
  `TokenStore` and do not return another user's token; unique credential
  `id` collisions remint once inside `CredentialStore` and do not return
  another user's credential;
- require `command_id` on registration, login, logout, password change,
  locale and theme preference writes, password-reset issuance and
  complete, email-change issuance and complete, and verification issuance
  and complete, and replay from `command_log` when the helper is present;
  `POST /settings` locale and theme writes mint their own keys so they do
  not share the notification-preferences `command_id`;
- strip raw tokens from the workflow result after the store queues
  `identity.mail.requested` on the outbox in the same issuance transaction;
- persist locale and theme preferences through `Identity::PreferenceStore`
  via the identity store facade; a second write of the same locale or
  theme skips the user-row restamp;
- hide duplicate-account details behind a non-enumerative registration error;
- leave transaction, event, audit, and outbox ownership inside stores;
- leave registration, typed identity, and login/logout audit hashes on
  `Identity::Event`;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok     => 0 | 1,
    status => 'ok' | 'invalid' | 'rejected' | 'failed' | 'conflict',
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
