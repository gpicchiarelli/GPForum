# Email lifecycle audit

Date: 2026-09-19.

Area completed in this increment: password reset, password change, email change,
and registration verification, with mail delivery through `Identity::Mailer` and
`Email::Sender`.

## Risk mitigated

Before this increment the repository had login, logout, revocable sessions,
Argon2id password hashing, and identity audit, but no verifiable lifecycle for
password reset or email change. The risk was `high`: account recovery and email
change were not implementable without improvised raw tokens, there was no
expiry or single use, replay was possible, and the audit trail was incomplete.
Delivery stayed disconnected: tokens were issued and then discarded.

## Patch applied

- `identity_tokens` persists hashed tokens, type, expiry, `used_at`, the pending
  email, and metadata.
- `Identity::AccountStore` generates raw tokens only at the service boundary and
  saves only `token_hash`; `Identity::Store` delegates those commands.
- `reset_password` consumes the token inside a transaction, locks the row with
  `FOR UPDATE` when the DBH is available, marks `used_at`, rotates the password
  credential, and revokes active sessions. A reset to the same secret already in
  use consumes the token and revokes sessions, but does not rotate the
  credential.
- `change_password` verifies the current password before rotating the credential
  and the audit record. `POST /settings/password` mints and requires a
  `command_id`; the same command replays from `command_log` without a second
  rotation, even when the current password in the retry is already the new one.
  A second store write of the same secret does not rotate the credential. The
  hash in `command_log` contains only `user_id`, never the passwords.
- `request_email_change` creates an `email_change` token for the normalized new
  email. A request for the member's already-verified email issues neither a
  token nor mail.
- `confirm_email_change` consumes the token and updates `email_normalized` plus
  `email_verified_at`. A second confirmation of the same already-verified email
  does not reset the timestamp.
- Registration issues an `email_verification` token.
  `confirm_email_verification` activates the account (`status=active`) and marks
  `email_verified_at`. A second confirmation on an account that is already active
  and already verified does not reset the timestamp.
- `Identity::AuthStore` rejects logins from pending (`unverified`) accounts and
  opens no session. Bootstrap admins that are already `active` do not require
  `email_verified_at`.
- `Identity::AccountStore` queues reset, email-change, and verification mail
  on the outbox in the same transaction as token issuance. EventLog keeps
  `kind` and `token_id`; the raw token lives only on the outbox `mail`
  payload. `Identity::Workflow` strips the raw token from the HTTP result.
  Raw tokens are never logged.
- Configuration comes from `GPForum::Config` / `GPFORUM_MAIL_*`: transport
  `test` in development/test, `sendmail` in staging/production, SMTP optional.
  `Email::Address::XS` 1.05 is a runtime pin for `Email::Sender::Simple`.
- HTTP POSTs are protected by plaintext CSRF (`IdentityAccess`) and an
  application-level rate limit. `register`, `login`, `logout`,
  `change_password`, `request_password_reset`, `reset_password`,
  `request_email_change`, `confirm_email_change`, `request_email_verification`,
  and `verify_email` mint and require a `command_id`; the same command replays
  from `command_log` without a second pending account, a second session, a
  second revocation, a second password rotation, a second token, or a second
  consume. The registration hash in `command_log` contains the email and the
  username, never the password. The login hash contains only the identifier. The
  logout hash contains `session_id` and `user_id`. The password-change hash
  contains only `user_id`. The consume hash contains the token, never a new
  password.
- Sensitive events are recorded in the audit trail with a hash of the
  identifier, address, or email, never a raw token.

## Test evidence

- `t/08-identity-store.t`: hashed token, expiry, SQL lock, single use,
  credential rotation, session revocation, audit, confirmed email change, and
  rejected replay.
- `t/110-identity-account-store.t`: password/email/verification commands on the
  account store with injected collaborators, without `Crypt::URandom`.
- `t/111-identity-auth-store.t`: pending login rejected with no session.
- `t/06-identity-web.t`: CSRF, reset rate limit, forgot-password link, reset
  route, password/email change routes, and email confirmation. The
  registration, login, logout, password-change, issuance, and consume forms mint
  a `command_id`.
- `t/103-identity-workflow.t`: `command_id` required; command-log replay and
  conflict for registration, login, logout, password change, token issuance, and
  consume.
- `t/152-write-unavailable.t`: command log down on registration, login, logout,
  password change, issuance, and consume returns 503 without leakage.
- `t/153-lost-response-retry.t`: an HTTP retry with the same `command_id` does
  not create a second pending account, does not open a second session, does not
  revoke the session twice, does not rotate the password twice, does not issue a
  second token, and does not consume the token twice.
- `t/146-identity-mailer.t`: `Test` transport, link in the body, no tokens in the
  logs.
- `t/147-identity-email-verification.t`: workflow strips tokens; verify CSRF.
- `t/154-identity-mail.t`: EventLog omits the raw token; outbox and handler
  deliver it. `t/150-outbox-handler-idempotency.t` proves a send-before-ack
  crash resends from the outbox payload.
- `t/162-mail-check.t`: operator mail-check dry-run for test/smtp/sendmail
  without leaking SMTP passwords.
- `t/05-database.t`: DBIC schema, migration `025`, unique token hash, and
  indexes.

## Residual limits

- Identity mail stays at-least-once: a retry after send and before `mark_done`
  resends. EventLog does not contain the raw token, so the retry reads only the
  outbox payload.
- Concurrent consume of the same token: closed by
  `t/integration/postgres-concurrency.t` (two `consume_token` calls on
  `password_reset` → one ok and one `token_used`, with `used_at` set).
- A different `command_id` on the same issuance rotates the existing unused
  token for `(user_id, token_type)` instead of inserting a second one.
  `identity_tokens_hash_key` and `used_at` remain the protection on consume.
  Usernames and emails stay unique: a second registration with a different
  `command_id` does not create a second pending account. A unique race on insert
  returns the same duplicate errors without a second row.

## Minimum commands

```sh
carton exec prove -lr t/05-database.t t/06-identity-web.t t/08-identity-store.t \
  t/103-identity-workflow.t t/146-identity-mailer.t \
  t/147-identity-email-verification.t t/152-write-unavailable.t \
  t/153-lost-response-retry.t t/154-identity-mail.t t/162-mail-check.t
script/gpforum-mail-check --human --dry-run
script/perltidy-check
script/perlcritic
```
