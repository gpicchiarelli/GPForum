# GPForum Deployment

GPForum is a Perl-first Mojolicious application intended to run as a persistent
Hypnotoad process behind a reverse proxy. PostgreSQL remains authoritative.
Redis, OpenSearch, Kubernetes, and SaaS control planes are not required.
GlifiStore, a disposable shared L2 cache, is optional.

## Production Shape

Recommended baseline:

```text
nginx or Caddy
-> Hypnotoad / Mojolicious
-> PostgreSQL
-> gpforum-outbox-dispatch (required worker)
-> optional Minion workers
```

The reverse proxy should handle TLS, compression, static files, large
attachments, request buffering, and coarse network limits. GPForum should handle
identity, authorization, forum domain workflows, event/audit/outbox writes,
SSR, and API responses.

## Install on Debian or Ubuntu

From a bare Debian 13 or Ubuntu 26.04 host to a forum behind TLS. Every
command runs as a user who may use `sudo`. Set your forum's address once; the
commands below use it:

```sh
site=forum.example.com
```

1. **Packages and Carton.** PostgreSQL, nginx with certbot, ClamAV for the
   upload scan, and Carton for the system Perl.

   ```sh
   sudo apt install git perl build-essential cpanminus libpq-dev libssl-dev zlib1g-dev \
     postgresql postgresql-client nginx certbot python3-certbot-nginx \
     clamav-daemon clamav-freshclam
   sudo cpanm -M https://cpan.metacpan.org/ Carton
   ```

2. **The code.** The code belongs to root, so the service cannot rewrite it.

   ```sh
   sudo git clone https://github.com/gpicchiarelli/GPForum.git /opt/gpforum
   ```

3. **Setup.** On a fresh clone it installs the dependencies first, as `make
   install-deps-production` does, without the maintainer's tools, and links
   `gpforum`, the command every step below uses, into `/usr/local/bin`.
   Then three questions, Enter taking each suggestion: the address members
   reach the forum at, the database (Enter makes `gpforum` on this host),
   and how mail leaves (step 5).

   ```sh
   sudo /opt/gpforum/bin/gpforum setup
   ```

   ```text
   gpforum setup installs the dependencies into /opt/gpforum/local first, as make install-deps-production does: carton install --deployment --without develop
   ...
   ✓ dependencies: installed into /opt/gpforum/local, for Perl 5.40.1
   GPForum setup. Three questions; Enter accepts the suggestion.
   Public address [https://forum.example.org]:
   Database [create 'gpforum' on this host]:
   Mail (sendmail, smtp HOST:PORT USER, or log) [sendmail]:
   ✓ account gpforum: made, with /opt/gpforum/var/attachments for its uploads
   ✓ /etc/gpforum/gpforum.env: written, 0640 root:gpforum, with a new session secret and metrics token
   ✓ gpforum: linked into /usr/local/bin, so it runs from any directory
   ✓ database gpforum at 127.0.0.1:5432: made, with its role gpforum
   ✓ Applied 51 migrations, 001 to 051; synced the query budgets (25 changed)

   Next: make the forum's owner, with sudo -u gpforum gpforum admin create --email EMAIL --username NAME
   Then: install and start the services, with sudo gpforum service print systemd --to /etc/systemd/system
   Then: check the whole forum, with sudo -u gpforum gpforum doctor
   ```

   It makes the service's account, `gpforum`, and the directory its uploads
   go in. It writes `/etc/gpforum/gpforum.env`, readable by root and the
   `gpforum` group only, with a new session secret, metrics token and
   database password, and prints none of them. It makes the database role
   and the database as PostgreSQL's superuser, the `postgres` account, and
   brings the schema up to date as `gpforum migrate` does: the tables, the
   monthly partitions and the query budgets `/health/ready` compares the
   plans with. Run again, it changes nothing and says so; a setting the
   file has is replaced only when you say so.

   For a database on another host, answer its data source
   (`dbi:Pg:dbname=gpforum;host=db.internal;port=5432`). Setup reaches its
   superuser as psql would -- `PGUSER` names it, `~/.pgpass` holds its
   password -- then with the user and password the data source, or
   `GPFORUM_DATABASE_USER` and `GPFORUM_DATABASE_PASSWORD`, give. When none
   answers, it says what PostgreSQL told each, offers the `PGUSER=...` run,
   and prints the `psql` commands that make what is missing, to run there
   before `sudo gpforum setup` again.
   `sudo gpforum setup --yes --public-url "https://$site" --database create
   --mail sendmail` answers for a script, and `--dry-run` shows what setup
   would do. Everything else in the file keeps its default; a setting
   GPForum cannot use stops the start, and every command, with every
   problem at once, each with the variable to set and the file to set it
   in.

4. **Commands as the service runs them.** `gpforum` reads
   `/etc/gpforum/gpforum.env` itself, as the service does, so a command typed
   by hand sees the service's settings. Run it as the service's user, so it
   also has the service's permissions:

   ```sh
   sudo -u gpforum gpforum
   ```

   On its own it lists its commands, by what you are doing, and says which
   environment file it read. What the shell sets comes first:
   `GPFORUM_ENV=staging gpforum ...` overrides the file for one command, and
   `gpforum --env-file FILE ...` reads another file.

5. **Mail.** Verification and reset mail leaves as setup's mail answer
   says (`GPFORUM_MAIL_TRANSPORT`). The suggestion, `sendmail`, needs a
   mail server on the host: `sudo apt install postfix` and choose "Internet
   Site". Many VPS providers block port 25, and many mail servers refuse a
   host without SPF and reverse DNS; then relay through a provider instead:
   run `sudo gpforum setup` again and answer the mail question with `smtp
   HOST:PORT USER`, Enter for the other two. It asks for the password
   without echo. TLS follows `GPFORUM_SMTP_PORT`: STARTTLS on 587, implicit
   TLS on 465 (`GPFORUM_SMTP_TLS` says otherwise), through IO::Socket::SSL,
   which the dependencies install. Then send yourself a probe:

   ```sh
   sudo -u gpforum gpforum mail-check --send --to ADDRESS --human   # an address you read
   ```

6. **Antivirus.** Add `StreamMaxLength 26M` to `/etc/clamav/clamd.conf`, so
   clamd scans a file as large as the upload limit, and prove it detects the
   test file ([ops/antivirus.md](ops/antivirus.md) explains the report):

   ```sh
   echo 'StreamMaxLength 26M' | sudo tee -a /etc/clamav/clamd.conf
   sudo systemctl restart clamav-daemon
   sudo -u gpforum gpforum antivirus-check
   ```

7. **The services.** The web application, the outbox worker that sends the
   mail, and the hourly and daily timers. `gpforum service print` writes
   the units of `deploy/systemd/` for this host -- the code directory, the
   environment file it read -- into the directory systemd reads them from:
   its own six names, and nothing else there is touched. Then start them,
   in one line:

   ```sh
   sudo gpforum service print --to /etc/systemd/system
   sudo systemctl daemon-reload && sudo systemctl enable --now gpforum gpforum-outbox gpforum-scheduled-jobs.timer gpforum-partition-maintenance.timer
   ```

   It ends with that same line. To read the units before they go in place,
   give `--to` a directory of your own; it then ends with the `cp`. The web
   unit checks the host first ([Preflight](#preflight)); if it does not
   start, `journalctl -u gpforum` says why.

8. **TLS and nginx.** Take a certificate, then put GPForum's site where
   Debian's nginx reads it. `gpforum service print nginx` writes it for the
   address in `GPFORUM_PUBLIC_BASE_URL` and the one the application listens
   on, with the upload limit and `/metrics` kept to this host, and refuses
   to put it in place before its certificate is there, since nginx would
   refuse the site:

   ```sh
   sudo certbot certonly --nginx -d "$site"
   sudo gpforum service print nginx --to /etc/nginx/sites-enabled
   sudo nginx -t && sudo systemctl reload nginx
   ```

   Debian's default site stays: it answers only the names no other site
   claims. Without nginx or certbot, the steps `service print nginx` and
   `gpforum doctor` print begin with the `apt install` that brings them.
   certbot's own timer renews the certificate.
   Once the forum is serving, `curl -sS "https://$site/health/ready"`
   answers `{"check":"ready","status":"ok"}` (or `degraded`, with a reason
   under the metrics token, see [Health endpoints](#health-endpoints)).

9. **The forum's owner.** Make your account, which can sign in at once:
   no mail and no database query are needed. It asks for the password
   twice.

   ```sh
   sudo -u gpforum gpforum admin create --email you@example.com --username you
   ```

   Sign in at `https://$site/login`. To make another member an owner later:
   `sudo -u gpforum gpforum admin grant their@example.com`.

Then check it all: `sudo -u gpforum gpforum doctor` goes from the settings
to the public address, one line each, with the command for anything to
fix, and `sudo -u gpforum gpforum status` shows the running service's
readiness report ([ops/doctor.md](ops/doctor.md)).

Upgrading later is three commands, which `sudo -u gpforum gpforum upgrade`
prints for this host. The last one, `sudo -u gpforum gpforum doctor
--upgrade`, says what the upgrade left behind
([ops/upgrade.md](ops/upgrade.md)).

### The front door and the old commands

`gpforum VERB` replaces the `bin/gpforum-*` commands, which keep working
under their old names, through `gpforum` (`gpforum partition-maintenance`)
or on their own (`bin/gpforum-partition-maintenance`, which runs under the
checkout's dependencies as `gpforum` does, but does not read the
environment file). The verbs answer in sentences, in the operator's
language; the old names keep the `key=value` lines the units' journals and
older scripts read, and `--json` is the same under both. `gpforum help
--all` lists every command.

| Before | Now |
| --- | --- |
| `bin/gpforum-migrate --apply`, then `bin/gpforum-query-budget --sync` | `gpforum migrate` (`--quiet` keeps the old silence for scripts) |
| `bin/gpforum-admin-bootstrap --user-id UUID` | `gpforum admin create --email ... --username ...`, or `gpforum admin grant EMAIL` |
| `bin/gpforum daemon -l http://127.0.0.1:3000` | `gpforum start --foreground` |
| `bin/gpforum-outbox-dispatch` | `gpforum outbox` |
| `bin/gpforum-partition-maintenance` | `gpforum partitions` |
| `bin/gpforum-query-budget` | `gpforum budgets` |
| `bin/gpforum-dead-letter-replay` | `gpforum dead-letters` |
| `useradd`, `createuser --pwprompt`, `createdb`, a copied template, its secrets and an editor, then `gpforum migrate` | `sudo gpforum setup` |
| `openssl rand -hex 32` into the environment file | `gpforum secret rotate session` or `metrics` |
| a shell that sources the environment file before each command | nothing: `gpforum` reads the file |

### Rotating a secret

`gpforum secret rotate session` writes a new `GPFORUM_SESSION_SECRET` into
the environment file and keeps the one before in `GPFORUM_SESSION_SECRETS`,
which still accepts the cookies it signed, so nobody is signed out. Restart
the service, and after 30 days, when every session has been renewed, drop
the old one:

```sh
sudo gpforum secret rotate session
sudo systemctl restart gpforum gpforum-outbox
sudo gpforum secret rotate session --finish     # 30 days later
sudo systemctl restart gpforum gpforum-outbox
```

`gpforum secret rotate metrics` does the same for `GPFORUM_METRICS_TOKEN`,
with no restart, because the running service reads the tokens from the file
again (ADR 0124). Give every scraper the new token from the file, then run
`--finish`:

```sh
sudo gpforum secret rotate metrics
sudo gpforum secret rotate metrics --finish     # once every scraper sends the new one
```

Both commands keep the file's owner and mode, print no secret, and say each
next step. `--dry-run` says what would change.

## Retired settings

A setting that no longer has any effect is still accepted, whatever it
holds, so an old environment file keeps starting; each start logs one line
naming it, such as `GPFORUM_WORKER_PROCESSES no longer has any effect;
remove it from the environment file.` Remove the line when you next edit the
file.

| Setting | Retired in | Why |
| --- | --- | --- |
| `GPFORUM_WORKER_PROCESSES` | Unreleased | Nothing started processes from it; the outbox worker and the timers are their own units. |
| `GPFORUM_REALTIME_PROCESSES` | Unreleased | Live updates run inside each web process. |
| `GPFORUM_OS_AFFINITY` | Unreleased | It only flipped a reported flag; CPU affinity is a non-goal. |

A renamed setting is still read under its old name while the new one is not
set, and each start logs the line to write instead, such as
`GPFORUM_SMTP_SSL is now called GPFORUM_SMTP_TLS; write
GPFORUM_SMTP_TLS=starttls in the environment file in its place.` The
settings page shows it under its new name.

| Old name | New name | Renamed in | What the old values read as |
| --- | --- | --- | --- |
| `GPFORUM_SMTP_SSL` | `GPFORUM_SMTP_TLS` | Unreleased | `on` (or `1`, `yes`, `true`) is `starttls`, `off` (or `0`, `no`, `false`) is `off`. Unset, the new default follows the port: `implicit` on 465, `starttls` on any other. |

Values production refuses now, which an older release took:

| Setting | Refused | Why |
| --- | --- | --- |
| `GPFORUM_PUBLIC_BASE_URL`, `GPFORUM_MAIL_FROM` | an address under `example.com`, `.net`, `.org`, `.example` or `.invalid`, in staging and production | The template's placeholders, left as copied, put a link nobody can follow in every mail, from a sender no server delivers for. |
| `GPFORUM_MAIL_TRANSPORT` | `test`, in production | It keeps mail in memory and sends none. |
| `GPFORUM_FORUM_READ_RATE_LIMIT` | anything but a whole number of at least 1 | It is now a setting like the others, and on the settings page; any other value used to be ignored without a word. |

## Preflight

The service files check the host before every start, with `gpforum
os-preflight --strict --json`; run the same check by hand before the first
one:

```sh
gpforum os-preflight          # one line per finding
gpforum os-preflight --json   # the same report as one JSON document
```

A check that fails -- no CPU count, no event backend -- stops the start, and
the command exits 1. A degraded one -- one CPU, a file descriptor limit below
65536, more web processes than the CPUs carry under
`GPFORUM_RUNTIME_WORKER_POLICY=configured` -- is reported and does not stop
it. Under the default `cap-to-cpu` policy the check counts the web processes
Hypnotoad is given, not the ones configured, so a 1-vCPU host starts.

`--strict`, which the systemd units and the FreeBSD rc script pass, also
writes each check that is not ok to stderr, one line each, so `journalctl -u
gpforum` shows it without the JSON around it:

```text
os-preflight: degraded recommended_worker_count: recommended worker count below configured threshold
```

### Upgrade note: the units run `bin/gpforum`

The service files run `bin/gpforum` alone, which finds the Perl and the
dependencies the checkout installed: `gpforum os-preflight --strict --json`
before the start, `gpforum start --service` for Hypnotoad (`--service
--foreground` under launchd and daemon(8)), and `gpforum outbox`, `gpforum
scheduled-jobs` and `gpforum partitions` for the others. `script/` is the
maintainers' (owner decision D9). Units copied before this release ran
`script/gpforum-carton exec` and `script/os-preflight`; both are still
there, so those units keep starting, and `gpforum doctor` says they differ
from this release's, with the `gpforum service print` that writes them
again and the restart that reads them.

## Identity mail delivery

Probe the transport before relying on verification, reset and email-change
mail: `gpforum mail-check --dry-run --human` checks it without sending
(`smtp`: a TCP connect, the password never printed; `sendmail`: the binary is
there), and `gpforum mail-check --send --to ADDRESS --human` delivers a
real verification probe to an address you read.
[ops/mail-check.md](ops/mail-check.md) explains each transport.

## Upload antivirus

Staging and production scan every upload with the operating system's ClamAV
and serve no new upload until it is clean (ADR 0108); attachments uploaded
before stay served until the hourly backfill has scanned them. Install the
system package (`apt install clamav-daemon clamav-freshclam`, `pkg install
clamav`, `brew install clamav`), set `StreamMaxLength 26M` in `clamd.conf`,
and prove it detects the EICAR test file with `gpforum antivirus-check`. To
run without an antivirus, set `GPFORUM_ANTIVIRUS=none` explicitly.
[ops/antivirus.md](ops/antivirus.md) has each system's steps and the socket
permissions.

## Deployment Evidence

Run the Hypnotoad evidence gate before treating a deployment profile as
measured:

```sh
script/bench-hypnotoad --check --profile small --workers 2 \
  --iterations 20 --warmup 3 \
  --route /categories \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route /search?q=performance \
  --route /health/ready \
  --route /metrics
```

The benchmark starts an isolated temporary Hypnotoad runtime, records worker
metadata, compares against in-process evidence when enabled, observes DB query
counts through benchmark-only headers, and stops the server gracefully. See
`docs/DEPLOYMENT_EVIDENCE.md` for current local values and methodology.

## Perl dependencies

GPForum runs on the **OS system Perl** only (`/usr/bin/perl` on
Debian/Ubuntu with `Config{prefix}=/usr`, FreeBSD ports/pkg perl under
`/usr/local`, or Homebrew's perl keg on macOS). Perl 5.40+ is required
(Debian 13 and Ubuntu 26.04 provide 5.40.x). Version managers and custom
PREFIX builds are unsupported. `script/gpforum-system-perl` and
`script/bootstrap-deps` refuse them (including perlbrew / plenv / asdf).
Confirm the host with:

```sh
which perl
perl -v
make system-perl   # script/gpforum-system-perl --preflight
```

Host packages (before Carton):

- Debian/Ubuntu: `perl`, `build-essential`, `cpanminus`, `libpq-dev`,
  `libssl-dev`, `zlib1g-dev`, `postgresql-client`
- FreeBSD: `perl5`, `p5-App-cpanminus`, `postgresql16-client`
- macOS (Homebrew): `brew install perl cpanminus postgresql@18`. Homebrew
  installs a versioned PostgreSQL keg-only, so put its client tools on
  `PATH` with:

  ```sh
  eval "$(script/gpforum-homebrew-env)"
  script/gpforum-homebrew-env --check
  ```

  That prepends `$(brew --prefix)/opt/postgresql@NN/bin` so `pg_config`,
  `psql`, `pg_dump`, and `pg_restore` resolve from Homebrew. The helper
  no-ops on Linux CI. After `brew upgrade perl`, rebuild `local/`
  (`script/bootstrap-deps --postgres --rebuild-local`): its XS modules are
  built for one Perl.
- Then: `cpanm -M https://cpan.metacpan.org/ Carton` for that system Perl

IO::Socket::SSL, for mail over TLS, builds Net::SSLeay against the host's
OpenSSL headers: `libssl-dev` on Debian and Ubuntu (`libpq-dev` does not
bring them), FreeBSD's base, and on macOS Homebrew's `openssl@3`, which
`postgresql@18` installs and `script/bootstrap-deps` finds (or set
`OPENSSL_PREFIX`).

GPForum recognizes runtime modules from `cpanfile`, PostgreSQL modules from
`cpanfile.postgres` (Carton feature `postgres`), and exact distribution pins
from `cpanfile.snapshot`. Install only through Carton under system Perl:

```sh
make install-deps-production
# equivalent: script/bootstrap-deps --postgres --production
```

That runs `carton install --deployment --without develop` against the
committed snapshot: the runtime and test requirements and the postgres
feature, without the maintainer's tools (Perl::Critic, Perl::Tidy,
Devel::Cover, Devel::NYTProf and what they pull in; ADR 0109). A
development or CI host uses `make install-deps-postgres`, which keeps them.
Either way the install uses
`PERL_CARTON_MIRROR=https://cpan.metacpan.org/` unless the operator sets
another **HTTPS** official PAUSE/MetaCPAN mirror or a local `carton bundle`
cache (`--cached`). Carton itself runs module tests as `--notest` (Carton
1.0.35 built-in). GPForum does not sideload CPAN distributions with
`cpanm --notest` and does not fetch GitHub tarballs.

`carton install --deployment` populates `local/lib/perl5` and scripts such as
`local/bin/hypnotoad`. It does **not** install `local/bin/carton`: Carton is a
host tool for system Perl, and only installing needs it -- the `make
install-deps-*` targets find it next to that Perl. Running needs no Carton:
`gpforum`, every `bin/gpforum-*` and the provided systemd, rc.d and launchd
units put `local/` on `@INC` themselves, under the Perl that installed it,
so nothing about Carton goes in the environment file.

Reproduce an install:

1. Use the same system Perl major/minor that produced `local/` (do not delete
   `local/` to paper over a mismatch after a distro Perl upgrade).
2. Keep `cpanfile`, `cpanfile.postgres`, and `cpanfile.snapshot` from the
   same git commit.
3. Run `script/bootstrap-deps --postgres --production` then
   `script/gpforum-carton check`.
4. Optional air-gap: `carton bundle` on a trusted host, copy `vendor/cache`,
   then `script/bootstrap-deps --postgres --production --cached`.

## Linux With systemd

The units in `deploy/systemd/` are what the [install](#install-on-debian-or-ubuntu)
copies, as `gpforum service print systemd` writes them for the host:
`gpforum.service` (or `gpforum-unix-socket.service`, see
[UNIX Socket Mode](#unix-socket-mode), which `service print` picks when
`GPFORUM_RUNTIME_LISTEN` names a socket), `gpforum-outbox.service`, the
outbox worker without which no mail leaves, and the two timers below. They
run as `gpforum` from the code directory (`/opt/gpforum` in the templates),
read the environment file (`/etc/gpforum/gpforum.env`), and stop
gracefully with `systemctl stop`. Restart after changing the environment
file; `systemctl reload` is refused on purpose
([ops/reload-and-restart.md](ops/reload-and-restart.md)).

The systemd units create `/run/gpforum` with `RuntimeDirectory=gpforum`, and
Hypnotoad keeps its pid file there (`PIDFile=/run/gpforum/hypnotoad.pid`). The
units set only `GPFORUM_ENV=production` and the log path (the unix-socket
unit also its listen address); every other setting takes its default unless
`/etc/gpforum/gpforum.env` sets it, so an override belongs in that file, not
in a copy of the unit.

Hourly operational sweeps are a timer, not a daemon
(`gpforum-scheduled-jobs.timer`, which the install starts with the rest).
The oneshot unit runs `gpforum scheduled-jobs --once --limit 100` through
`bin/gpforum`. It deletes stale sessions, rate-limit buckets,
identity tokens, completed outbox rows, and dead letters in bounded
batches, then calls attachment orphan cleanup and partition
policy/evidence. It does not loop and does not execute partition DDL.
See `docs/ops/scheduled-jobs.md`.

The monthly partitions of `audit_log`, `event_log` and `notifications` are
kept ahead by a daily timer of their own (ADR 0113),
`gpforum-partition-maintenance.timer`, also started by the install. It runs
`gpforum partitions --apply`, which creates the current month and the two
after it where they are missing. The parent tables stay open to writes;
reads that open the DEFAULT partition, and the event and audit writes that
start with one, wait for each attach, half a second at most plus the scan
of DEFAULT. Enable it on every node: the runs take an advisory lock, and
the ones that do not get it do nothing. It needs the role
that owns those tables -- the one the migrations run as; if the application's
role is not the owner, give the unit an `EnvironmentFile` with the migration
role's DSN. `gpforum migrate` does the same after every deploy's
migrations. See `docs/ops/partition-maintenance.md`.

## FreeBSD With rc.d

Example:

```text
deploy/freebsd/gpforum
deploy/freebsd/gpforum_outbox
deploy/freebsd/gpforum_jobs
deploy/nginx/gpforum.conf
```

Recommended operator actions:

- install under `/usr/local/www/gpforum`;
- run as a dedicated `gpforum` user: `sudo gpforum setup` makes it with
  `pw useradd`, writes the environment file below and makes the database,
  as on Debian;
- put the service's environment -- `GPFORUM_DATABASE_DSN`,
  `GPFORUM_SESSION_SECRET` and the rest of `GPFORUM_*`, as on Linux -- in
  `/usr/local/etc/gpforum/gpforum.env` (`gpforum_env_file` in rc.conf to move
  it), owned by `root:gpforum` with mode `0640`. The rc script exports it into
  the service and refuses to start if the file is readable by others or
  writable by its group: rc.conf variables are never exported, so this file
  is the only way the configuration reaches the application. Its
  `GPFORUM_ENV` is the mode; rc.conf's `gpforum_env` is the mode of a file
  that names none;
- put both rc scripts in `/usr/local/etc/rc.d/` and the jobs' crontab in
  `/usr/local/etc/cron.d/`, and enable both services:
  `sudo gpforum service print rc --to ~/gpforum-rc` writes the three for
  this checkout and environment file, and ends with the copies and
  `sysrc gpforum_enable=YES`, `sysrc gpforum_outbox_enable=YES` and the
  starts. `gpforum_outbox` is the outbox worker, which sends the mail; it
  reads the same environment file, and both create `/var/log/gpforum` for
  the `gpforum` user;
- `service gpforum stop` sends Hypnotoad's graceful QUIT and waits;
  Hypnotoad runs in the foreground under daemon(8), which rc tracks through
  `/var/run/gpforum/daemon.pid`;
- tune file descriptor limits through login class or service wrapper;
- use nginx, Caddy, or another local reverse proxy for TLS/static transfer;
- consider jails for process isolation;
- the crontab (`deploy/freebsd/gpforum_jobs`) runs `gpforum scheduled-jobs
  --once` hourly and `gpforum partitions --apply` daily as `gpforum`, the
  systemd timers' counterparts, through `bin/gpforum`, which reads the
  environment file.

## macOS With launchd

`gpforum service print launchd` writes these for the host -- the code
directory in place of `/opt/gpforum`, the logs under Homebrew's prefix:

```text
deploy/launchd/com.gpforum.app.plist
deploy/launchd/com.gpforum.outbox.plist
deploy/launchd/com.gpforum.scheduled-jobs.plist
deploy/launchd/com.gpforum.partition-maintenance.plist
```

`com.gpforum.outbox` keeps the outbox worker running, which sends the mail.
`com.gpforum.scheduled-jobs` is a 3600s interval sample for the same oneshot
command. It is not KeepAlive. `com.gpforum.partition-maintenance` runs
`gpforum partitions --apply` every 86400s, as the systemd timer does daily.

Each plist runs as the `gpforum` account, not as root, and through
`bin/gpforum`, which reads `$(brew --prefix)/etc/gpforum/gpforum.env` too.
launchd has no environment file, so each job reads it before it starts and
takes its mode from the file's `GPFORUM_ENV` -- `production` when it names
none, as under systemd -- and the plists set only the log and, for the web
service, the pid file. Clone the code where the `gpforum` account can read
it, such as `/opt/gpforum`, not under a home directory, which macOS keeps
closed to other accounts. `sudo gpforum setup` does what it does on Debian,
the account included: it makes the group and the account `gpforum` with
`dscl`, under the highest id below 500 that no user and no group has, and
`var/`, where Hypnotoad keeps its pid file and the uploads go, under the
checkout. It writes the environment file
(`$(brew --prefix)/etc/gpforum/gpforum.env`, 0640 root:gpforum), makes the
database as your own PostgreSQL role, which Homebrew's trusts, and brings
the schema up to date. Then the plists go into place and are loaded at
once, and the site goes where Homebrew's nginx reads it, after its
certificate (`site` is the forum's name, as in the Debian steps):

```sh
sudo gpforum setup
sudo gpforum service print --to /Library/LaunchDaemons
sudo install -d -o gpforum -g gpforum -m 0750 "$(brew --prefix)/var/log/gpforum"
sudo launchctl bootstrap system /Library/LaunchDaemons/com.gpforum.*.plist
brew install nginx certbot
sudo certbot certonly --standalone -d "$site" --pre-hook 'brew services stop nginx' --post-hook 'brew services start nginx'
gpforum service print nginx --to "$(brew --prefix)/etc/nginx/servers"
sudo nginx -t && sudo brew services restart nginx
```

`service print` ends with each of these for this host; nginx runs as root
under `brew services`, which reads the certificate certbot keeps root's,
and certbot's renewals stop and start it as the first one did.

The jobs are loaded too: a plist launchd has not loaded never runs. With
`gpforum --env-file FILE service print launchd`, each job hands that file to
`bin/gpforum` with `--env-file`, as the systemd units and the rc scripts
do, so the web service follows its metrics tokens with no restart.

macOS remains primarily a development and profiling platform. It is supported
for local persistent runs, but production throughput tuning should be measured
on the target FreeBSD or Linux deployment host.

## Reverse Proxy

Examples, which `gpforum service print nginx` and `gpforum service print
caddy` write for the host -- the forum's name from
`GPFORUM_PUBLIC_BASE_URL`, the address the application listens on, the
code directory and the attachment store -- and end with where this
operating system's nginx or Caddy reads them:

```text
deploy/nginx/gpforum.conf
deploy/nginx/gpforum-unix-socket.conf
deploy/caddy/Caddyfile
```

The proxy should preserve:

- `Host`
- `X-Forwarded-For`
- `X-Forwarded-Proto`
- WebSocket upgrade headers for `/realtime`

Static `/assets/` files live in the repository `assets/` tree
(`/opt/gpforum/assets` after install). Do not point the proxy at
`public/assets`; that path does not exist.

`GET /attachments/:attachment_id/download` is an application route. Nginx must
proxy that URL to Hypnotoad. A `location /attachments/ { internal; }` prefix
intercepts the download and returns 404.

To let nginx send the file once the application has authorized the download,
set `GPFORUM_ATTACHMENT_ACCEL_REDIRECT=/internal-attachments/` in the
environment file: the application then answers with an `X-Accel-Redirect`
header instead of the bytes, and nginx serves the file from its
`/internal-attachments/` alias. The shipped alias is
`/opt/gpforum/var/attachments/`, the default `GPFORUM_ATTACHMENT_ROOT`; if you
move the attachment store, change both. nginx reads the files as its own user,
and the store belongs to `gpforum` with mode `0750`: put nginx's user in the
`gpforum` group (`sudo usermod -aG gpforum www-data`, then `sudo systemctl
restart nginx`), or every download answers 403. Leave the setting empty
behind Caddy, which has no internal alias in the sample: a proxy that does not
understand the header would pass it to the browser.

nginx accepts request bodies up to 26 MiB (`client_max_body_size`), enough for
an attachment at GPForum's 25 MiB limit and the form around it.
`/metrics` answers the loopback only, in the nginx configurations and the
Caddyfile alike: the scraper runs on the same host.

For static assets and attachments, prefer web-server file transfer with cache
headers and sendfile support. GPForum can authorize access, but Perl should not
be the ordinary large-file transfer path.

## Health endpoints

`/health/live` answers `status`, `check` and `time` to anyone and depends on
nothing: point process supervisors and liveness probes at it.

`/health/ready` answers 200 while the node can serve (`ok` or `degraded`)
and 503 when it cannot (`fail`). Load balancers and probes act on that code
alone. Without the metrics token the body is the overall status only,
`{"check":"ready","status":"degraded"}`; the full report -- every check, its
error, the replication slots and partitions it names, the runtime -- goes
only to a request carrying the same token `/metrics` takes, as
`Authorization: Bearer <token>` or `X-GPForum-Metrics-Token: <token>`, the
current `GPFORUM_METRICS_TOKEN` or one of `GPFORUM_METRICS_TOKENS` during a
rotation. On the host, `sudo -u gpforum gpforum status` asks for it with
the token from the environment file and writes it one line per check; a
scraper sends the header itself:

```sh
curl -sS -H "X-GPForum-Metrics-Token: $GPFORUM_METRICS_TOKEN" \
  http://127.0.0.1:8080/health/ready | jq '.checks[] | select(.status != "ok")'
```

A wrong or stale token gets the status alone, not a 401 as on `/metrics`:
the code must not change with the token, or a probe left with an old token
after a rotation would take every node out of service. `GET /health`, the
config/runtime/OS summary, answers `{"status":"ok"}` without the token and
the full summary with it. Development and test, where no token has to be
configured, serve the full reports to anyone, as they serve `/metrics`;
staging and production refuse to start without one. Both token-dependent
endpoints answer `Cache-Control: no-store`, so no shared cache replays a full
report to an anonymous client. Unlike `/metrics`, which the shipped nginx
configurations also restrict to `127.0.0.1`, the health endpoints stay
reachable from outside because load balancers need the code: the full reports
rest on the token alone, so keep it out of probe configurations that only need
the status.

## UNIX Socket Mode

UNIX socket mode is optional. `deploy/systemd/gpforum-unix-socket.service`
sets it; in the environment file, for another supervisor, the line is:

```text
GPFORUM_RUNTIME_LISTEN=http+unix://%2Frun%2Fgpforum%2Fgpforum.sock
```

In a unit file each `%` is written `%%`, as the shipped unit does: systemd
reads `%2` as a specifier it does not know and drops the whole line, and the
service listens on the default TCP address instead.

When using UNIX sockets, `reuseport` is not applied. The systemd socket unit
creates `/run/gpforum` with `RuntimeDirectory=gpforum` (mode `0750`, owned by
the service user), so nginx reaches the socket only as a member of the
`gpforum` group: `sudo usermod -aG gpforum www-data`, then `sudo systemctl
restart nginx`. Other supervisors must create that directory with safe
ownership before start.

## Realtime

Every web process LISTENs on PostgreSQL and serves only its own websockets;
nodes need no sticky sessions and share no presence state. See
`docs/realtime.md`.

- Keep `GPFORUM_REALTIME_LISTENER_ENABLED=1` (the default) on every web
  process. Notification badges reach sockets only through NOTIFY and the
  listener, including those changed by the same process.
- The connection quota (8 per user) is counted per worker process. The
  cross-node limit is the PostgreSQL-backed `realtime.connect` rate limit
  (30 per minute per user).
- After a PostgreSQL restart or failover, each web process clears its L1
  cache once, on its next cache read, and re-sends notification badge counts
  to its sockets, one count query per connected user: expect a short rise in
  queries.
- A web process that cannot LISTEN (pointed at a standby, say) clears its L1
  on every cache read until it can, and `listen_failures` rises in
  `/metrics`.
- After a deploy or a worker recycle, the outbox backstop starts at the head
  of the outbox; nothing is replayed. It runs only in processes that have
  websocket connections.
- Keep every host's clock on NTP. The backstop waits five seconds for an
  outbox row to settle, and that window also absorbs the offset between a
  worker's clock, which stamps the row, and the database's.

## GlifiStore (optional)

A single host needs no GlifiStore: with `GPFORUM_GLIFISTORE_URL` empty, the
default, each process keeps its own cache in front of PostgreSQL and readiness
says so in a note. Set it to share one cache between hosts. PostgreSQL remains
the only source of truth. An unreachable GlifiStore degrades readiness to
process-local L1 and PostgreSQL; it does not become authoritative.

After a failed call (unreachable, timed out, overloaded) each process skips
GlifiStore for 15 seconds, then tries again; the pause is fixed, not
configured. While it runs:

- readiness reports `local-fallback` without connecting;
- pages come from L1 or are rendered from PostgreSQL;
- cache invalidations do not reach GlifiStore, so an entry that should have
  been invalidated stays in L2 until its TTL (`category_cache_ttl_seconds`).
  L1 never keeps an entry filled from L2 longer than L2 would.

`/metrics` shows the pause under `local_caches[0].l2`: `retry_after_epoch`
while it runs, and `stats.skipped` for the calls it skipped. `stats.failures`
counts real failures only; erasing a key that is not there is not one.

Invalidating a tag is one ERASE of that tag's token. Entries cached by a
release before tokens carry none, so each misses once after the upgrade.

`GlifiStore::Client` is **not** a Carton or `cpanfile` pin: it is not published
on PAUSE, and this repository does not vendor a GlifiStore server or Perl
client. `Service::Operations::SharedCache` loads the client at runtime:

```perl
require GlifiStore::Client;
GlifiStore::Client->connect(%endpoint);
```

The expected client surface is `connect`, `get`, `put`, `erase`, and `ping`
(`t/lib/GPForum/Test/SharedCacheClient.pm` is the in-tree stand-in). There is
no installable GlifiStore binary or CPAN distribution in this project.

To use one:

1. Run a GlifiStore server that listens on `GPFORUM_GLIFISTORE_URL`
   (sample configs use `tcp://127.0.0.1:7379`; `unix://path` is also valid).
2. Install `GlifiStore::Client` onto the same Perl that owns `local/` (private
   distribution or extra `PERL5LIB`).
3. Set `GPFORUM_GLIFISTORE_URL` in `/etc/gpforum/gpforum.env`.

Without the operator-supplied server and client, shared L2 cannot connect;
leave the URL empty instead.

## PostgreSQL Baseline

Minimum recommended posture:

- application role is not PostgreSQL superuser;
- migrations use a separate role;
- `statement_timeout` defaults to 15s on app connect
  (`GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS`; `gpforum-migrate --apply`
  clears it);
- `idle_in_transaction_session_timeout` defaults to 10s on app connect
  (`GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS`);
- `lock_timeout` defaults to 3s on app connect
  (`GPFORUM_DATABASE_LOCK_TIMEOUT_MS`);
- search and autocomplete set their own `statement_timeout` of 2s for the
  transaction they run in (`GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS`; 0 leaves
  them under the 15s above) and rank only the newest 1000 matches
  (`GPFORUM_SEARCH_CANDIDATE_LIMIT`);
- `application_name=gpforum` is set on connect;
- backups and restore tests exist before production launch: `gpforum
  backup` nightly and `gpforum restore --check` on each
  ([ops/backup-and-restore.md](ops/backup-and-restore.md));
- with a streaming standby ([ops/standby-and-failover.md](ops/standby-and-failover.md)),
  the application role is granted `pg_read_all_stats`
  (`GRANT pg_read_all_stats TO gpforum;`): `/metrics` reports each standby's
  replay lag and bytes behind under `replication`, and without the grant
  PostgreSQL hides them (`standby_details_visible` is 0). Not `pg_monitor`:
  it adds `pg_read_all_settings`, which reads a standby's `primary_conninfo`,
  replication password included when one was given. `/health/ready` degrades
  its `replication_slots` check when an inactive replication slot keeps more
  than 1 GiB of WAL or a slot is lost: a standby that stopped following, whose
  slot keeps the primary's WAL until the disk fills. The runbook is
  [ops/standby-and-failover.md#watch-the-lag](ops/standby-and-failover.md#watch-the-lag).

For a repeatable local/staging migrate + `pg_dump`/`pg_restore` rehearsal on
throwaway databases, see `docs/ops/staging-drills.md`
(`script/staging-drill`). For populated `var/attachments` filesystem
backup/restore plus static and host-available nginx/systemd checks, use
`script/staging-drill-attachments`. Live Hypnotoad/TLS host bring-up is
documented in `docs/ops/staging-host.md` with non-destructive
`script/staging-host-verify` (env-file key presence, systemd activity, HTTP
health). That verify does not install units or claim private-beta readiness.

## Tuning By OS

Linux:

- use `epoll` through Mojolicious runtime selection;
- prefer systemd unit limits over application-side tuning;
- use nginx/Caddy for TLS, compression, static files, and sendfile;
- inspect sockets with `ss` and process limits with `/proc`.

FreeBSD:

- use `kqueue`;
- prefer rc.d and login class limits;
- consider jails for isolation;
- inspect runtime with `sockstat`, `systat`, `top`, and `netstat`.

macOS:

- use `kqueue`;
- keep runtime simple for development;
- do not treat macOS benchmark results as production throughput proof.

## Non-Goals

GPForum does not automatically:

- modify sysctl;
- require root;
- pin CPU affinity;
- install systemd/rc.d/launchd files;
- require Redis;
- require Kubernetes;
- replace PostgreSQL as authoritative storage.
