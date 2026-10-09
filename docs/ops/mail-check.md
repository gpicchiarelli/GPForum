# Identity mail delivery check

Prove that GPForum's mail leaves the host: the verification, reset and
notification messages a member waits for.

```sh
gpforum mail-check                                # a dry run: what it can prove without sending
gpforum mail-check --send --to ADDRESS            # one real message, to an address you read
```

`gpforum doctor` runs the same dry run among its checks. The old names,
`bin/gpforum-mail-check` and `script/mail-check`, still work and answer with
the JSON evidence unless given `--human`; `make mail-check` runs the dry run
as JSON.

## What a dry run proves, and what it does not

A dry run sends nothing, so it can only prove part of the path. It says
which part, and how to prove the rest:

| Transport | A dry run proves | It does not prove |
| --- | --- | --- |
| `sendmail` (production's default) | a `sendmail` program exists in `/usr/sbin`, `/usr/lib`, `/usr/bin` or on the `PATH` | that the local mail server relays anywhere: macOS's postfix and a VPS with port 25 blocked both pass |
| `smtp` | the server's port accepts a TCP connection (5 s) | that it takes the message, the password or the sender |
| `log` (development's default) | nothing is sent: each message, its link included, is written to the outbox worker's log | -- |
| `test` (the test suite's) | the message reaches the in-memory transport | -- |

```text
$ gpforum mail-check
✓ mail: from forum@forum.example.org through sendmail at /usr/sbin/sendmail
    That shows a program is there, not that mail leaves this host.
    To prove delivery, send one to yourself: gpforum mail-check --send --to ADDRESS --human
    On a VPS, outgoing port 25 is often blocked, and mail from a host without SPF and a PTR record is refused: relay through your provider's SMTP (GPFORUM_MAIL_TRANSPORT=smtp).

Nothing to fix.
```

Only `--send` proves delivery: check that the message arrived, and not among
the spam.

## On a VPS: send through a provider

Most VPS providers block outgoing port 25, and most mailboxes refuse mail
from a host whose domain publishes no SPF record and whose address has no
PTR (reverse DNS) record naming it. A local postfix then accepts every
message and delivers none. Unless you run mail for the domain already, send
through your provider's or a mail service's SMTP relay:

```sh
GPFORUM_MAIL_TRANSPORT=smtp
GPFORUM_SMTP_HOST=smtp.provider.example
GPFORUM_SMTP_PORT=587
GPFORUM_SMTP_USERNAME=forum@forum.example.org
GPFORUM_SMTP_PASSWORD=...
```

and publish the SPF record the provider gives for `GPFORUM_MAIL_FROM`'s
domain. TLS follows the port, STARTTLS on 587 and implicit TLS on 465
(`GPFORUM_SMTP_TLS=starttls`, `implicit` or `off` says otherwise), and needs
the Perl module IO::Socket::SSL: without it `gpforum mail-check`, `gpforum
doctor` and the service's start all stop with the same sentence, which says
to install it or to turn TLS off. Then `gpforum mail-check --send --to
ADDRESS`, with an address you read.

## Probe behavior

| Transport | `--dry-run` (default) | `--send --to …` |
| --- | --- | --- |
| `test` | Deliver a verification probe into `Email::Sender::Transport::Test` | Same, to the given recipient |
| `smtp` | TCP connect to `smtp_host:smtp_port` only | Real SMTP delivery of a verification probe |
| `sendmail` | Confirm a `sendmail` binary is present | Real sendmail delivery |
| `log` | Nothing to reach; passes | The message is written to the log |

`--json` (the old names' default, for archived evidence) reports
`mail_transport`, `mail_from`, `public_base_url` and `smtp.*` (host, port,
`tls` -- `starttls`, `implicit` or `off` -- the older `ssl`, 1 unless TLS is
off, and whether a username is set, **never** the password); `--human`, the
default of `gpforum mail-check`, writes the lines above.

Exit status is non-zero on misconfiguration or probe failure: `1`, `2`
for misuse, and `78` for settings GPForum cannot use, every one of them on
standard error, as every command reports them, naming the environment file
read. An error the check raises instead of reporting exits `1` as well,
with the reason on standard error (an inline `password=` shown as
`[redacted]`) and, as JSON, evidence of `check` `mail_delivery` and its
`mode`, `status` `fail` and the reason in `error`, with the EvidenceMeta
markers. `mail-lifecycle-check` (below) does the same, with its own `check`.

Evidence JSON always sets `secrets_redacted=true` and
`private_beta_claimed=false`, lists `residual_gaps`, and scrubs SMTP
passwords plus the internal probe token from nested strings/errors. Never
archive evidence that still contains secrets.

## From the console

`/admin/settings` has a **Send test message** button: one message, through
the configured transport, to the signed-in administrator's own address. It
never takes an address from the request, so the console cannot send mail
anywhere else; `--send --to` other addresses stays on the shell. The outcome,
or the transport's error with every configured secret replaced by
`[redacted]`, is shown on the page and recorded in the audit log
(`admin.mail_test_sent`, with the actor and the outcome, not the address).
Each SMTP step is given five seconds: the send runs inside a web request.

## Identity mail lifecycle drill

Exercise all three identity mail kinds through `Identity::Mailer` under the
test transport (not a staging SMTP send):

```sh
script/mail-lifecycle-check --simulate --human
script/mail-lifecycle-check --dry-run --json
make mail-lifecycle-check
```

This closes the “single verification probe ≠ lifecycle” residual for local
prep archives. Staging SMTP `--send` and seeded-role DB flows remain open.

## Environment

| Variable | Role |
| --- | --- |
| `GPFORUM_MAIL_TRANSPORT` | `sendmail` / `smtp` / `log` / `test` |
| `GPFORUM_MAIL_FROM` | From address |
| `GPFORUM_PUBLIC_BASE_URL` | Public site base for links |
| `GPFORUM_SMTP_HOST` / `PORT` / `SSL` | SMTP endpoint |
| `GPFORUM_SMTP_USERNAME` / `PASSWORD` | Optional SMTP auth (password never printed) |

Defaults follow `GPForum::Config`: development → `log`; test → `test`;
staging and production → `sendmail` unless overridden. Staging and
production refuse `log`.

## Related code

- `GPForum::Service::Identity::Mailer`
- `GPForum::Worker::Handler::IdentityMail`
- `docs/audit/email-lifecycle.md`
- Unit: `t/146-identity-mailer.t`, `t/154-identity-mail.t`, `t/162-mail-check.t`,
  `t/171-mail-lifecycle-check.t`
