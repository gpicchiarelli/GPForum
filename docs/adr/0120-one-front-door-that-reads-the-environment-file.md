# ADR 0120: One Front Door, `gpforum`, That Reads the Environment File

## Status

Accepted. Amends `docs/architecture/operational-profiles.md`: the environment
stays the only configuration mechanism, and the environment file is now read
by GPForum as well as by the supervisor, with a documented precedence (owner
decision D1 of the operator walkthrough, 2026-10-07). Builds on ADR 0117
(`use v5.40`) and ADR 0118 (`GPForum::X::Config`, `GPForum::X::Usage`). Amended
by ADR 0124 (2026-10-10): the running service reads its metrics tokens from
the file again, so `gpforum secret rotate metrics` names no restart.

## Context

The operator walkthrough (`docs/ops/evidence/2026-10-07-operator-walkthrough`
and its iteration 1) followed a fresh install as a sysadmin who had never
seen GPForum. Four of the frictions it ranked first were about getting a
command to run at all:

1. **No front door.** The README typed `script/gpforum-carton exec perl
   -Ilib bin/gpforum-...` five times. `bin/gpforum` existed but answered with
   Mojolicious's generic banner (`mojo generate lite-app`, `-m, --mode`, cgi,
   psgi), and its usage lines named `bin/gpforum-X` whatever was typed.
2. **A command typed by hand did not see the service's settings.** systemd
   reads `/etc/gpforum/gpforum.env` into the service; a shell does not. The
   guide had the operator define a shell function around `sudo -u gpforum sh
   -c 'set -a; . /etc/gpforum/gpforum.env; set +a; ...'`. Forgetting it
   connected with the development defaults, and the database error that
   followed blamed the password.
3. **The fresh install left the node failing.** `gpforum-migrate --apply`
   did not sync the endpoint query budgets, so `/health/ready` answered 503
   until the operator found the runbook; `--apply` printed 51 checksum lines
   the first time and nothing at all the second.
4. **The first administrator needed psql and a mail server.** Signing in
   needed a verified address, and `gpforum-admin-bootstrap` needed the new
   account's UUID, read with a SQL query; a placeholder left in the query
   printed the usage twice, with no reason, exit 2.

`docs/architecture/operational-profiles.md` had removed the `etc/*.conf`
profile files because nothing read them, ruling that "the environment is
already the configuration mechanism and a second one with undocumented
precedence is worse than none". An environment file GPForum reads itself is
the same mechanism -- the same file, the same `NAME=value` lines -- with a
second reader, so its precedence must be written down.

## Decision

### 1. `bin/gpforum` is the front door

- **One name.** An operator types `gpforum VERB`. `bin/gpforum` resolves its
  own location (a symlink in `/usr/local/bin` works) and, when the checkout's
  `local/lib/perl5` is not on `@INC`, runs itself again through
  `script/gpforum-carton exec`, which picks the validated Perl and puts
  `local/` on `@INC`. Only core modules load before that.
- **Its own help.** `gpforum` and `gpforum help` group the verbs as an
  operator works: **Set up** (`migrate`, `admin`, `secret`), **Run**
  (`start`, `outbox`, `scheduled-jobs`), **Check** (`doctor`, `status`,
  `mail-check`, `antivirus-check`, `platform-check`, `os-preflight`),
  **Maintain** (`search-rebuild`, `dead-letters`, `partitions`, `budgets`).
  `gpforum help --all` adds the benchmarks, seeds, drills and evidence
  commands and Mojolicious's and Minion's own (`daemon`, `routes`, `eval`,
  `get`, `prefork`, `cgi`, `psgi`, `version`, `minion`).
  `gpforum help VERB` is the verb's usage. `daemon` is, for development,
  `gpforum start --foreground`.
- **The verb table** (`GPForum::Command::Support::Verbs`) names each verb's
  group, the `GPForum::CLI` command that runs it, and the `bin/` entrypoint
  that ran it before. A command still answers to its old name, dashes or
  underscores (`gpforum partition-maintenance`, `gpforum query_budget`), and
  every `bin/gpforum-*` entrypoint keeps working on its own: they are the
  verbs' aliases. Through the front door a help, usage or failure text that
  names a `bin/gpforum-X` names the verb instead (`GPForum::Command::Usage`
  reads `$0`, which the front door sets to `gpforum VERB`).
- **The verbs that work on the forum run from the code directory**, as the
  service's units do (`WorkingDirectory=/opt/gpforum`): `migrations/` and a
  relative attachment root are read from there. The more group's commands
  keep the directory they were typed in, since the files they are given are
  relative to it.
- **Hypnotoad keeps loading it.** Under `MOJO_APP_LOADER` the file returns
  the application as its last value; a trailing `1;` had made `hypnotoad -t
  bin/gpforum` answer "did not return an application object".

### 2. The front door reads the environment file, under the process environment

- **The file** is the one the host's service reads:
  `/etc/gpforum/gpforum.env` on Linux, `/usr/local/etc/gpforum/gpforum.env`
  on FreeBSD, `$(brew --prefix)/etc/gpforum/gpforum.env` on macOS, or the
  one given with `gpforum --env-file FILE VERB` (or `gpforum VERB
  --env-file FILE`, for every verb but `staging-host-verify`, whose own
  `--env-file` is the file it checks). A host without one reads none, and
  the help says so.
- **Precedence, strongest first:** the process environment (what systemd
  set from the same file, or what the operator typed), then the file, then
  GPForum's defaults. A name the process already holds is never replaced, so
  `GPFORUM_ENV=staging gpforum migrate` overrides the file for one command,
  and the service, whose supervisor read the file first, sees no change.
- **The format** is the template's: `NAME=value` lines, an optional
  `export`, a value bare, single-quoted (literal) or double-quoted (`\"`,
  `\\`, `\$`, `\`` escaped), blank lines and `#` or `;` comments; what both
  systemd's `EnvironmentFile=` and a POSIX shell read alike. A name
  assigned twice takes its last value, as both of them do. A value spread
  over lines is not read.
- **What it cannot use, it says.** A file named with `--env-file` that does
  not exist, one it cannot read (with "run gpforum as the service's user,
  with sudo -u gpforum, or as root"), and a line that is not an assignment,
  by its number, stop the front door with EX_CONFIG, 78. The service,
  loading `bin/gpforum` under Hypnotoad, reads the file leniently: its
  supervisor read it first (systemd as root, before dropping privileges).
- **The report names the file.** A configuration with problems ends with
  "Set these in /etc/gpforum/gpforum.env, then try again." -- the file this
  process read -- where it named the template; without a file read it still
  names the template. A secret the file lacks is offered as the command that
  writes it there, `gpforum secret rotate session` (with `sudo` when the
  file is not writable, and `--env-file` when it is not the host's), not
  `openssl rand -hex 32` and an editor. Every other sentence that names
  where to correct a setting -- a database that does not answer, a check's
  `Fix:` line -- names the file read too, in any environment. A `gpforum`
  command a step offers -- `Next:` after `migrate`, `Then:` after `secret
  rotate`, `admin`'s refusals -- carries the `--env-file` this run was given
  when that file is not the host's, so it acts on the same forum. A setting
  the shell's environment set stays as the shell set it, so the report
  sends the operator to the shell for that one ("The shell's environment
  sets GPFORUM_ENV, which comes before FILE: correct it there, or unset
  it"), and offers no rotation of a secret the file would not change.

### 3. One command style

- **Misuse says what was wrong, once.** The shared parser
  (`GPForum::Command::Usage`) opens its usage error with the reason ("--aply
  is not an option of this command.", "--limit takes a whole number above
  zero, not 'ten'."), and a usage error whose message already carries the
  usage prints it once.
- **Settings it cannot use exit 78** from every command that reports them
  through `Usage->failure`, as `bin/gpforum` did; a failed run is still 1 and
  misuse 2.
- **Human by default, `--json` everywhere.** `gpforum admin` and `gpforum
  secret` answer `--json`; their documents never carry a secret.
- **`--dry-run` shows and does not do** on `migrate` (the same as
  `--plan`), `admin` and `secret`.
- **A success ends with its next step** when there is one: `Next: ...`, and
  `Then: ...` for the one after.
- **The words follow the operator's language** (owner decision D13): the
  front door's and its commands' sentences are `cli.*` entries of
  `locale/cli/en.po` and `it.po`, read through
  `GPForum::Command::Support::Words`. The commands' `--help` texts stay
  English.

### 4. Three verbs do what a fresh install needs

- **`gpforum migrate`** applies the migrations, ensures the partition window
  (ADR 0113) and syncs the endpoint query budgets, so a fresh install's
  `/health/ready` is ok. It says so in one line -- `Applied 51 migrations,
  001 to 051; synced the query budgets (25 changed).`, or `Schema is current
  (051).` -- and names the next step: the forum's owner when it has none, a
  restart after a change in staging and production. `--plan` connects and
  lists what is pending; `--quiet` prints nothing unless something failed,
  for scripts that checked the old silence. `bin/gpforum-migrate` keeps
  planning without `--apply`.
- **`gpforum admin create --email --username`** asks for the password twice
  without echo (or reads it with `--password-stdin`) and makes an account
  active, its address verified, bound to the owner role, audited as
  `admin.bootstrap_created` (owner decision D6). Run again for the owner it
  made, it refuses (1) and says that account is the owner already, its
  password unchanged, rather than pointing at grant. `gpforum admin grant
  EMAIL|USERNAME` gives an account the role; `--user-id` stays.
- **`gpforum secret rotate session|metrics`** writes 32 random bytes as hex
  into the environment file and moves the one in use to
  `GPFORUM_SESSION_SECRETS` or `GPFORUM_METRICS_TOKENS`, keeping the file's
  owner, group and mode and replacing it in one rename; `--finish` drops the
  previous ones. It prints the host's restart command and the step after it,
  never a secret. On a copied template it fills the empty secrets, so the
  install needs no `openssl`; the development default, or a session secret
  too short for production, which the service refused, is replaced and not
  kept, so the next start does not refuse the list instead. A file every
  account on the host may read is said, with the `chmod 0640` that closes
  it; the mode is the operator's to change.

## Consequences

- The README and `docs/DEPLOYMENT.md` type `gpforum VERB` (as
  `sudo -u gpforum gpforum VERB` on a server), with no Carton incantation
  and no shell that sources the environment file; `t/472` holds them to it.
- `GPFORUM_ENV` and every other setting can come from the file for a command
  run by hand, so "the front door sees what the service sees" holds without
  the operator recreating the unit's environment.
- `bin/gpforum-*` run directly do not read the file, as before: the units
  and the crontabs that start them have their own environment.
- `gpforum-migrate --apply` writes the `endpoint_query_budgets` table after
  the partitions; a role that may migrate may write it. Its output changed
  from a line per migration to one line; CI's idempotency check passes
  `--quiet`.
- Each host's environment file is `GPForum::OS`'s `environment_file`, the
  Homebrew one on macOS, so every sentence that names the file names the one
  the front door reads, not the launchd plist. The supervisor's commands are
  still chosen by the operating system's name in
  `GPForum::Command::Support::ServiceEnvironment` (`systemctl` against
  `service` and `launchctl`); they belong in `GPForum::OS` with the rest of
  what differs between systems.

## Verification

- `t/482-front-door-environment-file.t`: the format, the precedence, each
  host's file, the refusals, and the report's last line with exit 78.
- `t/483-front-door-words.t`: both CLI catalogs carry every `cli.*` key,
  en.po's msgid is the code's English, and every key the code asks for
  exists.
- `t/484-front-door-launcher.t`: the grouped help in English and Italian,
  `help VERB`, misuse, old names and every `bin/` entrypoint resolving to the
  same command as its verb, `--env-file` and its precedence through
  `bin/gpforum`, a run from another directory without `local/` on `@INC`,
  and Hypnotoad's `load_app`.
- `t/485-secret-rotate.t`, `t/486-command-misuse.t`, `t/10-migrate-command.t`
  and `t/integration/postgres-front-door.t` (migrate on an empty database
  leaves no budget drift; `admin create` makes an owner who can sign in).
