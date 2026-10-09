# ADR 0122: Setup Asks Three Questions and Makes What the Service Reads

## Status

Accepted (2026-10-09). Implements item C1 of the operator walkthrough
(`docs/ops/evidence/2026-10-07-operator-walkthrough`, sections 5.2 and 5.3)
under owner decision D8: `gpforum setup` writes the environment file and
makes the database objects; the service files are printed, by `gpforum
service print` (ADR 0123). Builds on ADR 0120 (the front door) and follows
D13 (the operator's language). Amended for iteration 4 (2026-10-10, last
section): setup makes the account on macOS too.

## Context

Iteration 2 (`docs/ops/evidence/2026-10-09-operator-walkthrough-2`) left a
Debian install at 19 steps against a target of 15. Its first friction named
the nine that one guided command can do: the service user, the code's
directories, the role, the database, the environment file, its two secrets,
its edits by hand, and the schema. Each was a command copied from
`docs/DEPLOYMENT.md`, and two of them -- `createuser --pwprompt` and the
password typed again into the file -- had to agree with each other.

The audit's target (section 5.2) is three questions, Enter accepting a
suggestion, then one line a step and the next steps.

## Decision

### 1. Three questions, or their options

`gpforum setup` asks for the public address, the database (`create` makes
`gpforum` on this host; a DBI data source names another), and how mail
leaves (`sendmail`, `smtp HOST[:PORT] [USER]`, or `log`, which staging and
production refuse). Each suggestion is the file's value when it has one,
otherwise `https://` and the host's name, `create`, and `sendmail` (a
development install: `http://127.0.0.1:3000` and `log`). Each answer is
checked as the service checks it -- the address by `GPForum::Config`'s own
rules -- and asked again until it is one the forum can use. An SMTP login's
password is asked without echo.

`--yes` takes every suggestion, and `--public-url`, `--database`,
`--database-user`, `--mail`, `--environment`, `--smtp-password-stdin` give
the answers, for scripts; without a terminal and without `--yes`, setup
says so (exit 2). `--dry-run` says what it would do and changes nothing;
`--json` prints the findings as one object.

### 2. The environment file

- **Its rows are the template's**, `GPForum::Config::EnvironmentFile->render`
  (the one `deploy/gpforum.env.example` is), with the answers, the derived
  sender (`forum@` the address's host) and this environment's antivirus
  default written in; an existing file keeps every other line, comments
  included (`GPForum::Command::Support::EnvironmentFileEdit`, shared with
  `gpforum secret rotate`).
- **Secrets are made, never printed**: the session secret, the metrics
  token and the database role's password, each with `gpforum secret`'s
  generator (32 random bytes as hex), only where the file has none.
- **Owner and mode**: 0640. Run as root on a deployed host, root and the
  group `gpforum`, as the units and the FreeBSD rc scripts require. Run as
  anyone else, the file is theirs, and setup says what root would have
  done. In development run through `sudo`, it belongs to the developer who
  ran it. An existing file keeps its owner and mode; a deployed one that
  every account can read is said, with the `chmod 0640` that closes it.
- **Before anything is written**, the planned file is validated as the
  service validates it (`GPForum::Config->from_environment`), every problem
  at once, exit 78.

### 3. Nothing is replaced without asking

A setting the file has that an answer would change is asked about at a
terminal (`Replace it? [y/N]`); under `--yes` setup lists each one and
writes nothing (exit 1) unless `--force` is given. Re-run on a host it set
up, every step finds what it would make already there, and the run ends
`Nothing changed: this host was set up already.`

### 4. The database: made as the superuser, or two psql commands

`GPForum::Service::Operations::DatabaseProvisioning` reaches the server's
superuser first as libpq would for the account running setup (Homebrew's
PostgreSQL trusts the operator who installed it; `PGUSER` and `~/.pgpass`
work as for psql), then, run as root on a host whose server has an account
of its own (`postgres` on Debian and FreeBSD, from `GPForum::OS`), as that
account over the local socket, where peer authentication lets it in. That
second way runs in a child process that drops to the account and returns
its result through a pipe; the parent never changes user. It then makes the
role and the database the role owns, each only when missing, and checks
that the forum's role connects.

The role's password is sent as its SCRAM-SHA-256 verifier, computed as
psql's `\password` computes it, so neither the server's log nor anything
printed carries the password. When no superuser answers and the role or the
database is missing, setup prints the two psql commands that make them --
the role with that verifier -- for the operator to run as the superuser,
then `gpforum setup` again. Any other failure is said as `gpforum doctor`
says it (`GPForum::Service::Operations::DatabaseFailure`), by `--dry-run`
too, and a server that does not answer at all makes no password: an
existing file that had none keeps none.

### 5. The schema

As `gpforum migrate` does it: the same command, run with the settings the
file now holds, its one line kept (`Applied 51 migrations, 001 to 051;
synced the query budgets (25 changed)`, or `Schema is current (051)`).

### 6. The service account and its directories: setup makes them, on Linux and FreeBSD

The task asked to decide, with evidence, whether setup makes the system
user or prints the commands. It makes it, as root on a deployed Linux or
FreeBSD host, and prints the way on macOS:

- **The file cannot be finished without it.** D8 has setup write the
  environment file, and the file the service reads is `root:gpforum` 0640:
  the FreeBSD rc script refuses any other, and systemd reads it as root for
  a service running as `gpforum`. Without the group, setup could not write
  the one file D8 gives it in one run.
- **One standard command does it, and it can be asked first.** Debian and
  Ubuntu ship `useradd` in their base system; DEPLOYMENT step 2 already
  typed `useradd --system --user-group --home-dir /opt/gpforum --shell
  /usr/sbin/nologin gpforum`, and setup runs exactly that. FreeBSD's base
  has `pw useradd`, which makes the group of the same name. Whether the
  account exists is `getpwnam`, so a second run makes nothing.
- **macOS has no such command.** Its account takes a `dseditgroup` and a
  `sysadminctl` with a UID and GID chosen by hand below the login window's
  range. The guide's 399 is already taken on the walkthrough's own Mac
  (`id` lists `399(com.apple.access_ssh)`), and iteration 2 marked those
  lines untested. Choosing an id in someone's directory service silently is
  not setup's to do: there it says the account is missing, points at the
  guide's macOS section, and goes on; a later run gives the file to the
  group once it exists.
- **The directories**: the upload store (`GPFORUM_ATTACHMENT_ROOT`,
  `var/attachments` under the code), owned by the account with mode 0750,
  as `install -d` made it. The logs and the pid file belong to systemd's
  `LogsDirectory=` and `RuntimeDirectory=` and to the rc scripts, which make
  them; the code stays root's, from the clone.
- **Not made**: the `gpforum` link on the `PATH`, which is where the
  operator keeps their tools, and the service files (ADR 0123).

### 7. Through the front door

`gpforum setup` is in the Set up group, first. It writes the environment
file rather than reading it, so the front door does not read it first: a
file named with `--env-file`, before or after the verb, need not exist
yet, and is passed to setup as an absolute path. Every `gpforum` command
setup offers carries that `--env-file` when the file is not the host's
(ADR 0120).

### 8. What it says

One line a step, as `gpforum doctor` writes them (`✓`, `!`, `✗`, `Fix:`),
in Italian or English (D13; the `setup.*` entries of `locale/cli/*.po`).
A run that worked ends with the next steps:

```text
Next: make the forum's owner, with sudo -u gpforum gpforum admin create --email you@example.com --username you
Then: install and start the services, with sudo gpforum service print
Then: check the whole forum, with sudo -u gpforum gpforum doctor
```

They run as `gpforum` only when that account exists and the file is its
group's to read; otherwise as whoever ran setup, whose file it is, through
`sudo` when that was root (macOS before the account is made). `sudo -u
gpforum`, said where there is no such account, failed as printed.

Text is kept as characters and the file written as UTF-8, which the front
door reads it as: an answer typed with an accent, or an SMTP password,
reached the file as a latin-1 byte the service could not read.

## Consequences

- A Debian install is the packages, the clone, the dependencies, the link,
  `sudo gpforum setup`, `gpforum service print`, the certificate and
  `admin create`; DEPLOYMENT's steps 2 to 6 become setup.
- `gpforum migrate`'s summary sentence is public (`summary`), so setup says
  it from the migration's `--json` document rather than a second copy.
- The operator's earlier way -- `useradd`, `createuser --pwprompt`, a copied
  template, `secret rotate` twice and an editor -- keeps working: setup
  reads such a file as its own, suggests its values, and replaces none
  without asking.

## Verification

- `t/530-environment-file-edit.t`: the line editing and the one-rename
  write `secret rotate` and setup share.
- `t/531-terminal-questions.t`: the questions and answers.
- `t/532-setup-database-provisioning.t`: data sources, the SCRAM verifier
  against RFC 7677's exchange, the psql commands and their quoting.
- `t/533-setup-service-account.t`: each system's command, and the uploads
  directory.
- `t/534-setup-command.t`: the whole run and its lines, re-run, conflicts
  and `--force`, refused answers, the three questions, `--dry-run`, no
  superuser, a failed migration, Italian and JSON.
- `t/535-setup-front-door.t`: the verb in the help, and `--env-file` naming
  a file that does not exist yet.
- `t/536-setup-as-root.t`: as root, the account made (or, on macOS, the way
  to make it said), its uploads directory, a failure that stops before the
  file, and the file given to the account's group on a later run.
- `t/integration/postgres-setup.t`: on PostgreSQL, a role and database of
  its own made and dropped, the verifier stored, the migrations and budgets,
  a re-run that changes nothing, and root's way in through a child process
  over the socket.

## Amendment: iteration 4 (2026-10-10)

**macOS gets its account from setup too** (walkthrough 3, friction 3). The
reason section 6 gave for leaving it to the operator -- an id chosen by
hand in someone's directory service -- is answered by choosing it the way
the system does: `GPForum::OS::Darwin` takes the highest id below 500,
the login window's range, that no user and no group has, and makes the
group and the account under it with `dscl` (no password, `/usr/bin/false`,
hidden, at home in `/var/empty`). Setup, run as root, runs those commands
as it runs `useradd` and `pw`, and makes the uploads directory, `var/`
included, where the plists keep the pid file. `gpforum doctor` says when
the account the service files run as is missing, with `sudo gpforum
setup`. Verified by `t/533-setup-service-account.t` and
`t/591-service-print-into-place.t`.

**A typed answer is the say-so** (friction 9). Section 3 asked `Replace
it? [y/N]` after an answer the operator had just typed. A value typed at
the prompt now replaces the file's at once; a change no one typed -- an
option given at a terminal -- is still asked about, and under `--yes` still
needs `--force`. A sender setup derived
(`forum@` the address's host) follows a new address, and says so; one the
operator wrote stays. Verified by `t/534-setup-command.t`.

**The superuser setup reaches, and why none answered** (friction 8).
Section 4's ways in are joined by the logins the operator gives: the user
and password a data source names (`user=`, `password=`), then
`GPFORUM_DATABASE_USER` and `GPFORUM_DATABASE_PASSWORD` from the shell
setup was started in, read before the file it writes is loaded. The line
of what was made names the way in (`as PostgreSQL's superuser postgres,
from GPFORUM_DATABASE_USER`). When none answers, setup says what libpq told
each login, offers the run with `PGUSER`, and prints only the statements
for what is missing: `CREATE DATABASE` alone for a role that exists.
Verified by `t/532-setup-database-provisioning.t` and
`t/534-setup-command.t`.

**The next steps** (friction 7 and 13). Section 8's lines are now:

```text
Next: make the forum's owner, with sudo -u gpforum gpforum admin create --email EMAIL --username NAME
Then: install and start the services, with sudo gpforum service print systemd --to /etc/systemd/system
Then: check the whole forum, with sudo -u gpforum gpforum doctor
```

The owner's line names what to type, not a placeholder address. The
services' line is `gpforum service print`'s own first step for this host
(`ServiceFiles->install_step`), which writes the files where the service
manager reads them and ends with the start; a bare `service print` wrote
every unit to the terminal first. `gpforum secret rotate`, before the
services are installed, offers the same line. Verified by
`t/534-setup-command.t` and `t/560-secret-rotate-next-step.t`.
