# Identity mail delivery check

Operator-runnable probe for private-beta prep: prove `GPFORUM_MAIL_*` is
wired and that the configured transport can accept a dry-run or live probe
without waiting on CI.

This does **not** claim private-beta readiness. Record JSON/human evidence on
the target host after configuring SMTP/sendmail.

## Entrypoint

```sh
script/gpforum-mail-check --human --dry-run
script/gpforum-mail-check --json --dry-run
script/gpforum-mail-check --send --to you@example.test --human
```

`script/gpforum-mail-check` wraps `carton exec bin/gpforum-mail-check` under
the OS system Perl via `script/gpforum-carton`.

Optional Make target (not part of `make check` / default CI):

```sh
make mail-check
```

## What it reports

| Field | Meaning |
| --- | --- |
| `mail_transport` | `test`, `smtp`, or `sendmail` from config |
| `mail_from` | envelope From |
| `public_base_url` | base used for identity links |
| `smtp.*` | host/port/ssl and whether a username is set (**never** the password) |

## Probe behaviour

| Transport | `--dry-run` (default) | `--send --to …` |
| --- | --- | --- |
| `test` | Deliver a verification probe into `Email::Sender::Transport::Test` | Same, to the given recipient |
| `smtp` | TCP connect to `smtp_host:smtp_port` only | Real SMTP delivery of a verification probe |
| `sendmail` | Confirm a `sendmail` binary is present | Real sendmail delivery |

Exit status is non-zero on misconfiguration or probe failure.

## Environment

| Variable | Role |
| --- | --- |
| `GPFORUM_MAIL_TRANSPORT` | `test` / `smtp` / `sendmail` |
| `GPFORUM_MAIL_FROM` | From address |
| `GPFORUM_PUBLIC_BASE_URL` | Public site base for links |
| `GPFORUM_SMTP_HOST` / `PORT` / `SSL` | SMTP endpoint |
| `GPFORUM_SMTP_USERNAME` / `PASSWORD` | Optional SMTP auth (password never printed) |

Defaults follow `GPForum::Config`: development/test → `test`; staging/production
→ `sendmail` unless overridden.

## Related code

- `GPForum::Service::Identity::Mailer`
- `GPForum::Worker::Handler::IdentityMail`
- `docs/audit/email-lifecycle.md`
- Unit: `t/146-identity-mailer.t`, `t/154-identity-mail.t`, `t/162-mail-check.t`
