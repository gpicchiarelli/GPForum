# gpforum doctor and gpforum status

Two commands answer "is this forum working, and if not, what do I do?":

```sh
sudo -u gpforum gpforum doctor     # everything, from the settings to the public address
sudo -u gpforum gpforum status     # the running service's own readiness report
```

Both read `/etc/gpforum/gpforum.env` as the service does (another file:
`gpforum --env-file FILE doctor`, and then every `gpforum` command they offer
carries the same `--env-file FILE`). A setting the shell's environment holds
wins over the file, for them as for the service, so its fix says to change
it there. Run them as the service's user, so they also have its
permissions. They answer in Italian or English, as `LC_ALL`,
`LC_MESSAGES` or `LANG` says.

## gpforum doctor

One line per check: `✓` fine, `!` works but should be fixed, `✗` stops the
forum working as configured. Under each problem, `Fix:` lines say what to
change -- the variable and the file -- and the command to type. The last
line counts what there is to fix.

```text
$ sudo -u gpforum gpforum doctor
✓ settings: production, read from /etc/gpforum/gpforum.env
✓ host: Linux with epoll, 2 CPUs
✓ web processes: 4 for 2 CPUs
✓ open files: up to 65536
✓ database: PostgreSQL 18.6, gpforum at 127.0.0.1:5432
✓ schema: current (051)
✓ query budgets: as the code sets them
✓ readiness: 6 more checks of /health/ready pass
✓ outbox worker: nothing waiting; the last message left 4 s ago
✓ mail: from forum@forum.example.org through sendmail at /usr/sbin/sendmail
    That shows a program is there, not that mail leaves this host.
    To prove delivery, send one to yourself: gpforum mail-check --send --to ADDRESS --human
✗ antivirus: clamd does not answer at /run/clamav/clamd.ctl
    Detail: No such file or directory
    Fix: sudo apt install clamav-daemon clamav-freshclam
         or, if it is installed, start it: sudo systemctl enable --now clamav-daemon (clamd waits for freshclam's first download)
         or set GPFORUM_ANTIVIRUS=none in /etc/gpforum/gpforum.env, and uploads are checked for format only
✓ services: 6 files in /etc/systemd/system, as this release ships them
✓ services: gpforum and gpforum-outbox run the code on disk
✓ timer: gpforum-scheduled-jobs.timer fired 12 min ago
✓ timer: gpforum-partition-maintenance.timer fired 9 h ago
! address: https://forum.example.org does not answer: connection refused
    Fix: put GPForum's nginx site in place:
         sudo certbot certonly --nginx -d forum.example.org
         sudo gpforum service print nginx | sudo tee /etc/nginx/sites-available/gpforum > /dev/null
         sudo ln -sf /etc/nginx/sites-available/gpforum /etc/nginx/sites-enabled/gpforum
         sudo nginx -t && sudo systemctl reload nginx
         sudo systemctl enable --now gpforum
         journalctl -u gpforum says why

2 things to fix.
```

What each line checks:

| Line | What it checks | When it is not fine |
| --- | --- | --- |
| `settings` | every setting, as the service checks them when it starts (TLS to an SMTP server this Perl cannot speak included), and, on staging and production, that the environment file is not readable by every account | each problem on its own line, with the value to set or `gpforum secret rotate` for a missing secret; the other checks wait until the settings are right. An open file is a warning with the `chmod 0640` that closes it, and so is a retired setting, or one still under its old name (`GPFORUM_SMTP_SSL`), with the line to remove |
| `host`, `web processes`, `open files` | what `gpforum os-preflight` checks | the limit or the setting to change |
| `database` | that PostgreSQL answers with the configured DSN, role and password | one sentence: refused, unknown host, wrong password, no such role or database, `pg_hba.conf` |
| `schema` | migrations still to apply, or applied files that changed since | `gpforum migrate` |
| `query budgets` | the budgets `/health/ready` compares with the code | `gpforum budgets --sync` |
| `readiness` | the rest of `/health/ready`: runtime, shared cache, partitions, profile, replication slots | each check that is not ok, with its command or its runbook |
| `outbox worker` | the oldest message waiting to be sent, a claim a stopped worker left behind included; more than five minutes means nothing is sending | the command that starts `gpforum-outbox`, and its journal |
| `mail` | `gpforum mail-check`'s dry run, which says what it proved and what it did not | [mail-check.md](mail-check.md) |
| `antivirus` | `gpforum antivirus-check`: clamd finds the test file and lets an ordinary one through | install or start clamd, or turn scanning off |
| `services` | the unit files installed as this release ships them -- as `gpforum service print` writes them for this host, or as `deploy/` has them -- and, under systemd, the web service and the outbox worker running the code on disk | `gpforum service print` into place (one file through `sudo tee`, several into a directory first), the start of what it runs (`launchctl bootstrap` on macOS), the `diff` that shows a drift, the restart a stale service needs |
| `timer` | systemd's hourly and daily timers: on, fired recently, the last run successful | `systemctl enable --now`, or the journal |
| `address` | `GPFORUM_PUBLIC_BASE_URL/health/live` through the proxy, over TLS with a certificate this host accepts | the proxy, as `gpforum service print nginx` writes it, where this operating system's nginx reads it (also when the port answers without TLS: `no TLS handshake`), the certificate, the DNS |

`services` and `timer` are checked on staging and production hosts only;
the timers and running services under systemd only. In development the
`address` is the one `gpforum start --foreground` listens on.

`--json` prints the same findings as one JSON object (`status`, `problems`,
`findings`, each with its `name`, `status`, `message`, `notes` and
`fixes`). The exit status is 0 when nothing failed -- the `!` warnings are
counted but do not fail -- and 1 when something did.

### After an upgrade

`gpforum doctor --upgrade` is the last step of an [upgrade](upgrade.md). It
checks what an upgrade can leave behind: the settings (a release can add
one), the modules this release needs for the Perl that runs it, the
migrations still to apply, and the service files and running services. A
module so far missing that the checks themselves cannot load is reported the
same way, on its own, with the command that installs it.

```text
$ sudo -u gpforum gpforum doctor --upgrade
✓ settings: production, read from /etc/gpforum/gpforum.env
✓ dependencies: the 18 modules this release needs, for Perl 5.40.1
✓ database: PostgreSQL 18.6, gpforum at 127.0.0.1:5432
✓ schema: current (052)
✓ query budgets: as the code sets them
! services: gpforum-outbox.service differs from this release's
    sudo gpforum service print systemd gpforum-outbox.service | diff -u /etc/systemd/system/gpforum-outbox.service - shows how
    Fix: sudo gpforum service print systemd gpforum-outbox.service | sudo tee /etc/systemd/system/gpforum-outbox.service > /dev/null
         sudo systemctl daemon-reload
         sudo systemctl restart gpforum-outbox

1 thing to fix.
```

## gpforum status

The running service's full readiness report, the one `/health/ready` gives
a request carrying the metrics token, one line per check. It asks the
service where Hypnotoad listens (`GPFORUM_RUNTIME_LISTEN`, the loopback for
every interface), not through the proxy, with `GPFORUM_METRICS_TOKEN` from
the environment file; `--url URL` asks another address.

```text
$ sudo -u gpforum gpforum status
http://127.0.0.1:8080: ready, with warnings (production, 14 checks)

✓ database
✓ runtime
✓ host limits
✓ web processes
✓ event log table
✓ outbox table
✓ projection table
✓ query budget table
✓ query budgets
✓ shared cache: one per process, no GlifiStore
! antivirus: cannot connect to clamd at /run/clamav/clamd.ctl: No such file or directory
    Fix: sudo -u gpforum gpforum antivirus-check says why
✓ partitions
✓ operational profile
✓ replication slots

1 thing to fix.
```

A service that does not answer, or one that keeps its report back because it
holds another token than the file, is one line saying so, with the start or
the restart to type. A running service reads its tokens from the file again
after a `gpforum secret rotate metrics` (ADR 0124). One that does not, such as
a service started for another file without `GPFORUM_ENV_FILE`, holds the
token it started with until it is restarted. `--json` gives the report as the service sent it, with the lines.
`gpforum status` exits 0 when the service is ready (`ok` or `degraded`) and
1 when it is not or does not answer.

`gpforum doctor` makes the same report itself, without the service running,
and writes only the checks it does not cover in more detail.
