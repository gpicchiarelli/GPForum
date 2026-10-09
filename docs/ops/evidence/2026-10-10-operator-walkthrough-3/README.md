# Operator walkthrough, iteration 3 (2026-10-10)

The walk of [iteration 2](../2026-10-09-operator-walkthrough-2/README.md),
repeated after iteration 3 ("guided setup": `gpforum setup`, `gpforum service
print`, `gpforum backup`), as a sysadmin who has never seen GPForum. The macOS
quick start was **run** to a signed-in admin. A production host was then set
up on the same Mac. The Debian 13 install was **walked through its documents
and code**, with no VM. Its systemd and nginx steps were printed here and
doctor's Linux findings were **simulated**. Upgrade, metrics-token rotation
and backup were followed from `gpforum help`.

- **Tree:** `main` at `712a79f`, cloned into a scratch directory, so nothing
  uncommitted took part. The walk ran on 2026-10-09, from 10:18 to 10:32
  local time.
- **Host:** macOS 27 on arm64, 10 CPUs, with Homebrew perl 5.44.0 and
  postgresql@18 18.6.
- **Database:** the machine's shared PostgreSQL 18 on `127.0.0.1:55433`.
  Setup made two databases for the walk, `gpforum_walk3` (development) and
  `gpforum_walk3p` (production), and both were dropped at the end. That
  cluster trusts every connection, and its superuser is the role `gpforum`.
- **Mail:** `log` in development, `sendmail` (`/usr/sbin/sendmail`, no MTA
  behind it) in production.
- **Language:** commands ran with `LC_ALL=en_US.UTF-8`, and a second setup
  run, `service print`, `status` and `restore --check` also ran with
  `it_IT.UTF-8`.

Each step is marked with how it was checked:

- **run:** typed here; its output is quoted.
- **simulated:** run here with one probe replaced, because this Mac has no
  systemd or nginx.
- **traced:** read in the documents and code it rests on.
- **not checkable:** it needs a Debian host, DNS, a certificate or an MTA.

In the quotes, `…/` stands for the scratch directory.

**The terminal.** The tool's shell has no terminal, so every question was
answered through `expect`, which gives the command a pseudo-terminal. The
answers were typed by the script, and the prompts are quoted as `expect` saw
them. Iterations 1 and 2 used `--password-stdin` instead; this time
`admin create` asked for its password at a terminal, as an operator sees it.

## 0. Headline

| Measure | Iteration 0 | Iteration 1 | Iteration 2 | Iteration 3 | Target (audit 5.4) | Met |
| --- | --- | --- | --- | --- | --- | --- |
| macOS quick start to a signed-in admin, without an MTA | dead end at step 14 | 16 steps, plus an undocumented 17th for a ready node | 14 steps (13 commands, 1 browser action) | **12 steps** (11 commands, 1 browser action), **3 questions** answered with Enter. `/health/ready` 200 and "Health and runtime: OK" | — | — |
| macOS time in commands, clone to signed-in admin | — | about 5 min 40 s | 4 min 23 s | **about 3 min 20 s**: 171 s of dependency install, under 15 s for everything else. Wall clock was 9 min 30 s, because 6 min went on the `expect` harness and the shared cluster (1.2) | — | — |
| Debian typed commands, clone to a signed-in admin behind TLS | — | — | — (not counted this way) | **15** | **≤ 8** | **no** (2) |
| Debian questions answered | — | — | none; an editor instead | **3**: the address typed, Enter for the database and for mail | about 3 | **yes** |
| Debian documents the operator must open | 12 | 2 | 2, plus the template they edit | **2**, README and DEPLOYMENT, and no template: setup writes the file. Once setup has run, its `Next:` lines, `service print`'s steps and doctor's `Fix:` lines lead to TLS with no document open (2.2) | **1** (README) | **no** |
| Debian steps at iteration 1's granularity | 31 | 22 | 19 | **14** (13 without step 4's look at the help) | ≤ 15 (iteration 2's target) | **yes** |
| Debian commands in DEPLOYMENT, bare host to admin, all included | about 60 | 34 | 34, plus `doctor` | **26**, plus `doctor` | — | — |
| macOS production with `gpforum service print launchd`, clone to signed-in admin | — | — | — | **17 typed commands** from DEPLOYMENT's macOS section. **No documented TLS step**: there is no certificate command for macOS (3) | ≤ 8, as Debian | **no** |
| Upgrade | one sentence | — | 3 lines in docs/ops/upgrade.md | **3 lines** (5 commands joined by `&&`). `gpforum help` never says "upgrade"; `gpforum help doctor` names the document (4.1) | ≤ 3, straight from `gpforum help` | **in part**: 3 lines, but reached through a document |
| Metrics-token rotation | `openssl rand` and an editor | — | 4 commands in DEPLOYMENT | **4 commands**: rotate, restart, `--finish`, restart. `gpforum help secret` names the first, and each command's `Next:` line names the one after (4.2) | ≤ 3, straight from `gpforum help` | **no**, by one restart |
| Backup and its check (C5) | none | none | none | **2 commands**, both under Maintain in `gpforum help`; each prints the next (4.3) | — | — |

Iteration 3 meets one of its three targets: the questions. Debian falls 7
typed commands short of its target. Setup is 1 of the 15; the rest are the
clone and its dependencies, then printing, copying and starting the units
and the nginx site, which the CLI names but does not shorten. Section 2.3
sets out an 8-command path within decisions D8 and D9. macOS production
cannot reach TLS from the documents. Upgrade and rotation are each one step
from their targets. Section 5 ranks what is left as input for iteration 4.

## 1. macOS with Homebrew: the README quick start, run

### 1.1 The commands, in README order

**Deviations.** Each one exists only to protect the shared machine:

- `brew install`, `brew services start postgresql@18` and the Carton line
  were not re-run: the first would upgrade the owner's packages, and the
  second would start a second cluster. `brew list --versions` showed
  `cpanminus 1.7049`, `perl 5.44.0` and `postgresql@18 18.6`, and
  `system-preflight` found Carton 1.0.35.
- `bin/gpforum` was linked into a scratch directory placed first on `PATH`,
  not into `$(brew --prefix)/bin`, which is the owner's.
- `setup` got `--env-file …/walk3/literal.env`, not
  `$(brew --prefix)/etc/gpforum/gpforum.env`, which is the owner's.
- The database answer named the shared cluster, and `PGUSER=gpforum` named
  its superuser (1.2).

| # | Command or action (README) | Here | Result |
| --- | --- | --- | --- |
| 1 | `brew install perl cpanminus postgresql@18` | not re-run | present |
| 2 | `brew services start postgresql@18` | not run | shared cluster |
| 3 | `export PATH="$(brew --prefix postgresql@18)/bin:$PATH"` | run | ok |
| 4 | Carton through Homebrew's cpanm | not re-run | Carton 1.0.35 present |
| 5 | `make system-perl` | run | `✓ Perl 5.44.0 at /opt/homebrew/Cellar/perl/5.44.0/bin/perl`, then `Next: make install-deps-postgres, or sudo make install-deps-production on a server`. 1 s |
| 6 | `make install-deps-postgres` | run | `132 distributions installed`, then `cpanfile's dependencies are satisfied.`, still with no `Next:` line. 171 s |
| 7 | `script/system-preflight` | run | six `✓` lines (Perl, Carton, dependencies, host, web processes, open files), then `Nothing to fix.` |
| 8 | `ln -s "$PWD/bin/gpforum" "$(brew --prefix)/bin/"` | run, into scratch | `gpforum` alone prints the grouped help: Set up now lists `setup`, `migrate`, `admin`, `secret`, `service`; Maintain lists `backup` and `restore` |
| 9 | `gpforum setup --environment development` | run, at a terminal | Three questions, Enter for each (1.2). `✓ …/walk3/literal.env: written, 0640 gpicchiarelli:wheel, with a new session secret and metrics token`, `✓ database gpforum_walk3 at 127.0.0.1:55433: made, for role gpforum`, `✓ Applied 51 migrations, 001 to 051; synced the query budgets (25 changed)`, then three lines: `Next:` admin create, `Then:` `start --foreground`, `Then:` doctor, each with `--env-file` |
| 10 | `gpforum admin create --email … --username …` | run, at a terminal | `Password (at least 12 characters):`, `The same password again:`, `✓ walk3admin (walk3@walk3.test) is the forum's owner and can sign in now.`, `Next: sign in at http://127.0.0.1:3000/login` |
| 11 | `gpforum start --foreground` | run | `Listening at "http://127.0.0.1:3000"` one second later; `/health/ready` `{"check":"ready","status":"ok"}` |
| 12 | Sign in at <http://127.0.0.1:3000/login> | run (curl, with the form's CSRF token) | sign-in 302 to `/`, `/admin` **200**, "Health and runtime: **OK**" |

**Count:** 12 steps. Iteration 2 had 14: `createuser`, `createdb`, the
`export` of a password (macOS skipped it) and `gpforum migrate` are now one
`gpforum setup`. That leaves 11 typed commands and one browser action, with
three questions answered by Enter.

**Documents opened:** README.md only.

**Then, on the running node:** `gpforum doctor` printed twelve `✓` lines,
from `settings: development` to `address: http://127.0.0.1:3000 answers`,
then `Nothing to fix.`, exit 0. The metrics token was rotated while the
server ran, and `gpforum status` said so in Italian:
`! http://127.0.0.1:3000 risponde ok, ma non mostra il resto del rapporto a
questo token delle metriche`, with
`Rimedio: il servizio usa un GPFORUM_METRICS_TOKEN diverso da quello in …:
riavvialo, così rilegge il file, con gpforum --env-file … start
--foreground`. That was right: the server had read the token before.

### 1.2 What setup said on the way (run)

Pressed exactly as the README says, Enter three times, on this Mac, where
nothing listens on 5432:

```text
GPForum setup. Three questions; Enter accepts the suggestion.
Public address [http://127.0.0.1:3000]:
Database [create 'gpforum' on this host]:
Mail (sendmail, smtp HOST:PORT USER, or log) [log]:
✓ …/walk3/literal.env: written, 0640 gpicchiarelli:wheel, with a new session secret and metrics token
✗ Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused)
    Fix: start it with brew services start postgresql@18, or correct GPFORUM_DATABASE_DSN in …/walk3/literal.env

1 thing to fix.
```

That is the right fix on a Mac where `brew services start` was skipped. Its
first line has no `database:` label, where doctor's has one since `b10bba3`
(friction 13).

Run again with the shared cluster's data source typed at the database
question, setup asked about the setting the operator had just typed:

```text
Database [dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432]: dbi:Pg:dbname=gpforum_walk3;host=127.0.0.1;port=55433
Mail (sendmail, smtp HOST:PORT USER, or log) [log]:
…/walk3/literal.env has GPFORUM_DATABASE_DSN=dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432. Replace it with dbi:Pg:dbname=gpforum_walk3;host=127.0.0.1;port=55433? [y/N] y
✓ …/walk3/literal.env: GPFORUM_DATABASE_DSN, GPFORUM_DATABASE_PASSWORD set, 0640 gpicchiarelli:wheel
✗ database gpforum_walk3 at 127.0.0.1:55433: no PostgreSQL superuser answers here, so role gpforum and its database are not made
    Fix: psql -d postgres -p 55433 -c "CREATE ROLE gpforum LOGIN PASSWORD 'SCRAM-SHA-256$4096:…'"
         psql -d postgres -p 55433 -c "CREATE DATABASE gpforum_walk3 OWNER gpforum"
         then gpforum --env-file …/walk3/literal.env setup again
```

- **The question after the answer** (friction 9). The answer typed at the
  prompt already says what the operator wants, so `[y/N]` asks a fourth
  question for one decision.
- **"No superuser answers"** (friction 8).
  - It does not say why. Here libpq connected as the login name,
    `gpicchiarelli`, which this cluster has no role for. Its superuser is
    `gpforum`.
  - The printed `CREATE ROLE gpforum` would fail with "already exists",
    because the role is there.
  - Homebrew's own cluster trusts the login that installed it, so the
    README's path does not meet this. A cluster whose superuser has another
    name does, and the sentence should name `PGUSER`.

With `PGUSER=gpforum`, the third run made the database, applied 51
migrations and synced 25 budgets. A fourth run in Italian, pressing Enter
three times on the production file (2.1), changed nothing and said so:
`✓ … : com'era`, `✓ database … su 127.0.0.1:55433, come ruolo gpforum`,
`✓ Lo schema è aggiornato (051)`.

## 2. Debian 13, production, behind nginx

### 2.1 What ran here

Setup ran on this Mac in production mode, with
`--env-file …/walk3/prod.env` and a database on the shared cluster. Its three
answers were `https://forum.walk3.test`, the data source and Enter
(`sendmail`):

```text
! not run as root: …/walk3/prod.env is yours, and the services' account gpforum is not made
    Fix: sudo gpforum --env-file …/walk3/prod.env setup
✓ …/walk3/prod.env: written, 0640 gpicchiarelli:wheel, with a new session secret and metrics token
✓ database gpforum_walk3p at 127.0.0.1:55433: made, for role gpforum
✓ Applied 51 migrations, 001 to 051; synced the query budgets (25 changed)

Next: make the forum's owner, with gpforum --env-file …/walk3/prod.env admin create --email you@example.com --username you
Then: install and start the services, with gpforum --env-file …/walk3/prod.env service print
Then: check the whole forum, with gpforum --env-file …/walk3/prod.env doctor
```

`gpforum service print nginx` took `.test` for a placeholder: `!
GPFORUM_PUBLIC_BASE_URL is https://forum.walk3.test, not the address members
reach the forum at, so the site is written for forum.example.com`. So I ran
setup again, in Italian, with `https://forum.gpforum-walk3.org`, a name no
DNS knows. It asked `Sostituirlo con …? [s/N]` and set the address.

**A defect: the sender stayed behind.** After the second run the file held
`GPFORUM_PUBLIC_BASE_URL=https://forum.gpforum-walk3.org` and
`GPFORUM_MAIL_FROM=forum@forum.walk3.test`. Setup derives the sender from
the address only when the file has none (`Command/Setup.pm`, `_given(…,
'GPFORUM_MAIL_FROM') // _sender(…)`). An operator who corrects the address
therefore keeps mail going out from the old domain, and doctor reported
`✓ mail: from forum@forum.walk3.test through sendmail` (friction 4).

Then, in the order setup's lines name them:

- **`admin create`:** asked for the password twice;
  `✓ walk3owner (owner@gpforum-walk3.org) is the forum's owner and can sign
  in now.` `Next: sign in at https://forum.gpforum-walk3.org/login`.
- **`service print`, as setup's `Then:` gives it, bare:** it wrote 234
  lines of plists to stdout, and its steps to stderr, which begin by saying
  to write them to a directory instead: `Next: write them to a directory, read
  them, then put them in place and start them: … service print launchd --to
  ~/gpforum-launchd` (friction 7). Doctor's own fix gives the `--to` form
  straight away.
- **`service print systemd --to systemd` and `launchd --to launchd`:**
  - systemd: `✓ 6 files for systemd are in systemd: gpforum.service, …`,
    then `sudo cp systemd/* /etc/systemd/system/`, `sudo systemctl
    daemon-reload` and `sudo systemctl enable --now gpforum gpforum-outbox
    gpforum-scheduled-jobs.timer gpforum-partition-maintenance.timer`;
  - launchd: `✓ 4 files for launchd are in launchd: …`, then the copy, the
    log directory and four `launchctl bootstrap` lines;
  - the four plists passed `plutil -lint`;
  - `EnvironmentFile=` named the walk's file, and `User=gpforum`.
  - `ExecStart` still runs `…/script/gpforum-carton exec hypnotoad
    …/bin/gpforum`. Decision D9 keeps `script/` for maintainers (friction
    11).
- **`service print nginx`:** `server_name` and the certificate path came
  from the address, with `client_max_body_size 26m`. On macOS the steps
  were `… service print nginx | tee
  /opt/homebrew/etc/nginx/servers/gpforum.conf > /dev/null` and `nginx -t
  && brew services restart nginx`. Italian:
  `Prossimo passo: mettilo al suo posto:`.
- **`doctor` on the production file:**
  - `✓` for settings, host, database, schema, budgets, readiness, outbox
    and mail;
  - `✗ antivirus` (no clamd), with its three fixes;
  - `! services: … not installed in /Library/LaunchDaemons`, with the
    `service print launchd --to` fix and the four bootstraps;
  - `! address: https://forum.gpforum-walk3.org does not answer: its host
    name is not known`;
  - `3 things to fix.`

### 2.2 Debian's own steps (simulated and traced)

A scratch script built `Service::Operations::Doctor` with `os => linux`, the
host's `/etc/gpforum/gpforum.env` and a unit directory in scratch. Every
probe answered as healthy except the address, as t/542 does. Run on a fresh
host, after setup, with nothing installed and nothing on 443:

```text
! services: gpforum.service, gpforum-outbox.service, gpforum-scheduled-jobs.service, gpforum-scheduled-jobs.timer, gpforum-partition-maintenance.service, gpforum-partition-maintenance.timer not installed in …
    Fix: gpforum service print systemd --to ~/gpforum-systemd
         sudo cp ~/gpforum-systemd/* …/
         sudo systemctl daemon-reload
         sudo systemctl enable --now gpforum gpforum-outbox gpforum-scheduled-jobs.timer gpforum-partition-maintenance.timer
! address: https://forum.gpforum-walk3.org does not answer: connection refused
    Fix: put GPForum's nginx site in place:
         sudo certbot certonly --nginx -d forum.gpforum-walk3.org
         gpforum service print nginx | sudo tee /etc/nginx/sites-available/gpforum > /dev/null
         sudo ln -sf /etc/nginx/sites-available/gpforum /etc/nginx/sites-enabled/gpforum
         sudo nginx -t && sudo systemctl reload nginx
         sudo systemctl enable --now gpforum
         journalctl -u gpforum says why
```

The fixes carry no `sudo` before `gpforum` here only because the simulated
`/etc/gpforum/gpforum.env` does not exist on this Mac; for a 0640 file
`service print` adds it, as t/540 checks.

Once the units printed by `ServiceFiles` were in the directory, the
`services` finding was gone and the address finding was unchanged. So the
CLI alone takes a Debian operator from setup to TLS. Setup's `Next:` lines
lead to `service print` and `doctor`, `service print` gives the copy and
the start, and doctor gives the certificate and the site. Nothing after
step 3 needs DEPLOYMENT. Before it, the operator does need it, for the
`apt` line that brings nginx, certbot and ClamAV, and for
`make install-deps-production`. The README covers only development.

Setup's root path was not run: no root here, and no `useradd`. DEPLOYMENT
step 3 quotes `✓ account gpforum: made, with
/opt/gpforum/var/attachments for its uploads` and `0640 root:gpforum`. Those
are the lines t/536 holds the code to, with an account double.

### 2.3 The count

DEPLOYMENT, from the clone to a signed-in admin behind TLS. Step 4's look at
the help, mail (step 5), antivirus (step 6), `systemctl status` and the
`curl` are left out, because none of them is needed to sign in:

| # | Command | DEPLOYMENT step |
| --- | --- | --- |
| 1 | `sudo git clone … /opt/gpforum` | 2 |
| 2 | `cd /opt/gpforum` | 2 |
| 3 | `sudo make install-deps-production` | 2 |
| 4 | `sudo ln -s /opt/gpforum/bin/gpforum /usr/local/bin/gpforum` | 2 |
| 5 | `sudo gpforum setup` (3 questions) | 3 |
| 6 | `sudo gpforum service print --to ~/gpforum-systemd` | 7 |
| 7 | `sudo cp ~/gpforum-systemd/* /etc/systemd/system/` | 7 |
| 8 | `sudo systemctl daemon-reload` | 7 |
| 9 | `sudo systemctl enable --now gpforum gpforum-outbox …timer …timer` | 7 |
| 10 | `sudo certbot certonly --nginx -d "$site"` | 8 |
| 11 | `sudo gpforum service print nginx \| sudo tee /etc/nginx/sites-available/gpforum >/dev/null` | 8 |
| 12 | `sudo ln -s /etc/nginx/sites-available/gpforum /etc/nginx/sites-enabled/gpforum` | 8 |
| 13 | `sudo rm /etc/nginx/sites-enabled/default` | 8 |
| 14 | `sudo nginx -t && sudo systemctl reload nginx` | 8 |
| 15 | `sudo -u gpforum gpforum admin create --email … --username …` | 9 |

**15 typed commands; the target is 8.** Before the clone come `site=`, the
`apt` line and Carton, 3 more. Setup took over what iteration 2 typed for
these: `useradd`, `install -d`, `createuser`, `createdb`, the template's
`install`, two `secret rotate`s, the editor and `gpforum migrate`.

Every DEPLOYMENT command, as iteration 2 counted them:

| Step | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Commands | 2 | 4 | 1 | 1 | 1 (and `apt install postfix` in prose) | 3 | 5 | 6 | 1 |

That is 24 commands; with `site=` and the postfix line, 26, plus the
closing doctor, against 34 plus doctor in iteration 2.

**A path in 8, within D8 and D9** (friction 1):

1. `git clone`.
2. `sudo /opt/gpforum/bin/gpforum setup`, which also installs the
   dependencies and links `gpforum` onto the `PATH`. The audit's 5.2 target
   had setup print `✓ dependencies installed`. That removes `cd`, `make`
   and `ln`.
3. `sudo gpforum service print --to /etc/systemd/system`. The operator
   still copies, by naming the directory, and `--to` would write only the
   six names it owns. Today `--to` refuses a directory holding anything
   else.
4. `sudo systemctl daemon-reload && sudo systemctl enable --now …`, as one
   line.
5. `certbot`.
6. `service print nginx --to /etc/nginx/sites-enabled`, or `| tee` into
   it. Debian's nginx includes `sites-enabled/*` directly. The site names
   its server, so the default site need not go for it to answer that name.
7. `nginx -t && reload`.
8. `admin create`.

## 3. macOS production with `gpforum service print launchd` (traced, steps run)

DEPLOYMENT's macOS section, from the clone, with nginx from DEPLOYMENT's
Reverse Proxy section and `service print nginx`'s own steps:

| Commands | What |
| --- | --- |
| clone, `cd`, `make install-deps-production`, `ln -s` | 4, as Debian |
| `sudo dseditgroup …`, `sudo sysadminctl …`, `sudo install -d …` | 3: the account and its directories, which setup does not make on macOS |
| `sudo gpforum setup` | 1 |
| `service print launchd --to`, `sudo cp`, 4 × `sudo launchctl bootstrap` | 6 |
| `service print nginx \| tee …/servers/gpforum.conf`, `nginx -t && brew services restart nginx` | 2 |
| `admin create` | 1 |

**17 typed commands, and no TLS step.** The nginx site names
`/etc/letsencrypt/live/HOST/`, but neither DEPLOYMENT nor any command says
how to obtain that certificate on a Mac. `brew install nginx` is not
written anywhere either. The other gaps:

- **No account fix.** Setup's `! not run as root … the services' account
  gpforum is not made` points to `sudo gpforum setup`, which on macOS does
  not make it either. Doctor has no account check: its launchd fix begins
  with `sudo install -d -o gpforum …`, which fails while the account is
  missing.
- **Four bootstrap lines where one would do.** `launchctl bootstrap system
  A B C D` takes several paths (launchctl(1)).
- **A fixed path for a moving checkout.** DEPLOYMENT's `install -d` names
  `/opt/gpforum/var` while the plists are written for wherever the
  checkout is.

## 4. Day two, followed from `gpforum help`

### 4.1 Upgrade (run, on the clone)

`gpforum help` lists no upgrade, and `gpforum help --all | grep -i upgrad`
finds nothing. `gpforum help doctor` ends `docs/ops/upgrade.md is the
upgrade.` That document gives three lines:

```sh
sudo git -C /opt/gpforum pull && sudo make -C /opt/gpforum install-deps-production
sudo -u gpforum gpforum migrate && sudo systemctl restart gpforum gpforum-outbox
sudo -u gpforum gpforum doctor --upgrade
```

Run here as `git pull`, `make install-deps-postgres`, `gpforum migrate` and
`gpforum doctor --upgrade`:

- `Already up to date.`
- `cpanfile's dependencies are satisfied.`
- `Schema is current (051).`
- doctor: `✓ dependencies: the 19 modules this release needs, for Perl
  5.44.0`, then database, schema and budgets `✓`, and the launchd plists
  `!` with their fix.

The three commands work as written. They are not "straight from `gpforum
help`": the help names a document, and the restart comes from that
document: `gpforum migrate`, with nothing to apply, did not name it
(friction 5).

### 4.2 Metrics-token rotation (run, and simulated for an installed Debian host)

`gpforum help` → Set up → `secret`. `gpforum help secret` says: rotate,
restart, then `--finish`.

- **Run** (macOS, no service files installed):
  - `✓ A new metrics token is in …/walk3/prod.env. The one before stays in
    GPFORUM_METRICS_TOKENS, so no scraper is refused.`
  - `Next: install and start the services, with gpforum --env-file … service
    print`
  - `Then: give every scraper the new GPFORUM_METRICS_TOKEN from …, then
    gpforum --env-file … secret rotate metrics --finish`
  - `--finish`: `✓ The previous metrics tokens are gone from …; a scraper
    that sends one is refused.`
  - The file stayed `-rw-r-----`.
- **Simulated** (Linux, units installed): `Next: sudo systemctl restart
  gpforum gpforum-outbox` after the rotation, and the same line after
  `--finish`.

So it is 4 commands: rotate, restart, finish, restart. Each is named by the
one before, and the restart after `--finish` is what makes the old token
stop working. That is one over the target (friction 6).

### 4.3 Backup (run)

`gpforum --env-file … backup --to …/backups`:

```text
✓ database gpforum_walk3p: 253.0 KB, schema 051, PostgreSQL 18.6
! attachments: …/walk3-clone/var/attachments does not exist, so the backup holds no uploads
✓ Backed up into …/backups/gpforum-20261009T083124Z
Next: check that it can be restored, with gpforum --env-file … restore --check …/backups/gpforum-20261009T083124Z
```

The uploads directory was missing because setup, run without root, does not
make it. Then `restore --check`, typed as offered:

- `✓ manifest: gpforum_walk3p, taken 2026-10-09 08:31 UTC, schema 051`
- `✓ database.dump: 253.0 KB, as the backup wrote it; pg_restore reads its
  578 entries`
- `! attachments: none; …`
- `The backup can be restored; nothing was restored.`

Given the parent directory, in Italian, it printed `✗ manifest: …/backups
non ha un manifest.json, quindi non è un backup di GPForum`, then
`Prossimo passo: verifica il suo backup più recente, con … restore --check
…/gpforum-20261009T083124Z`. The `✗` reads as a failure for what is really
a pointer (friction 13).

## 5. Friction left, ranked (input for iteration 4)

The ranking puts value to a new operator first, then how often they meet it.
**S/M/L** is effort.

1. **Debian is 15 typed commands from the clone, against ≤ 8.** Section 2.3
   gives the path in 8: setup installs the dependencies and the link;
   `service print --to` accepts the unit directory and nginx's
   `sites-enabled`, writing only its own names; the start goes on one line;
   and `rm default` goes. M.
2. **Two documents, not one.** The README's production branch sends the
   operator to DEPLOYMENT for the `apt` line (nginx, certbot, ClamAV) and
   `make install-deps-production`. After setup, the CLI alone leads to TLS
   (2.2). Either the README carries the four production lines, or setup
   and doctor name a missing nginx and certbot with their `apt install`.
   S.
3. **macOS production does not reach TLS** (section 3). It needs:
   - the account commands from setup or doctor (`OS/Darwin.pm` has no
     `service_account_commands`), and a doctor check for the account;
   - `brew install nginx`, and a certificate step;
   - one `launchctl bootstrap` for all four plists;
   - DEPLOYMENT's `install -d` for wherever the checkout is.

   M.
4. **Setup keeps `GPFORUM_MAIL_FROM` at the old domain when the address
   changes** (2.1). A sender that setup itself derived (`forum@` plus the
   old host) should follow the new address. One the operator wrote should
   stay. S. A defect.
5. **Upgrade is not in `gpforum help`.** A `gpforum help upgrade` topic, or
   a footer line, could give the three lines for this host's supervisor.
   upgrade.md says `gpforum migrate` names the restart, but with nothing
   to apply it did not. S.
6. **Metrics rotation takes 4 commands.** Either `--finish` takes effect at
   the next restart, with no restart of its own, or the service re-reads
   the token list without a restart. That is a security choice for the
   owner, since the old token keeps working until then. S/M.
7. **Setup's `Then:` line offers bare `gpforum service print`**, which
   writes every unit to the terminal before saying to use `--to`. It should
   offer `gpforum service print --to ~/gpforum-systemd` (or `launchd`), as
   doctor's fix does. S.
8. **"No PostgreSQL superuser answers here" hides why.** It should:
   - say libpq's reason (`role "gpicchiarelli" does not exist`, `role X is
     not a superuser`);
   - name `PGUSER` for a cluster whose superuser has another name;
   - not print `CREATE ROLE` for a role that exists (or print `ALTER ROLE
     … PASSWORD` for it).

   S.
9. **An answer typed at the prompt is asked again** as `Replace it with …?
   [y/N]`. Typing the new value is the say-so; the replace question belongs
   to Enter, `--yes` and `--force`, not to a typed answer. S.
10. **Iteration 4's own items: fewer settings.**
    - D1': `GPFORUM_ENV` collapses to `development|staging|production`. The
      size comes from the host and `doctor` reports it (development showed
      `web processes: 14 for 10 CPUs`). `production-small`/`-medium` become
      aliases.
    - The file setup writes is 258 lines, with 10 settings set and 58
      commented. The template should be pruned to the operator set.
    - The 5.6 deprecation sweep: aliases, one warning line per old name,
      doctor's replacement line, and a "Renamed settings" table.
    - D4': the drill variables become flags.

    M/L.
11. **The printed units still run `script/gpforum-carton exec` and
    `script/os-preflight`.** D9 keeps `script/` for maintainers, and moves
    what the units need behind `bin/gpforum`. M.
12. **DEPLOYMENT step 5 is stale on TLS.** It still says to `sudo apt
    install libio-socket-ssl-perl`, and that "without it the service does
    not start". The lock has installed IO::Socket::SSL since `c57cc7a`. S.
13. **Small wording.** S each:
    - setup's failing database line lacks the `database:` label doctor has;
    - setup's `Next:` gives `admin create --email you@example.com --username
      you`, a placeholder;
    - `make install-deps-*` still ends without a `Next:` line;
    - `restore --check` on the parent directory opens with `✗` before
      offering the newest backup.
14. **Not run on a real host, still.** A Debian or FreeBSD VM is needed
    for:
    - root's setup (`useradd`/`pw`, the `postgres` peer login);
    - a password-checking `pg_hba` login with setup's SCRAM verifier;
    - `systemd-analyze verify` and `nginx -t` on the printed files;
    - certbot;
    - FreeBSD cron reading `/usr/local/etc/cron.d`;
    - clamd's `StreamMaxLength` order.

## 6. Clean-up

- The server on port 3000 was stopped, and the port is free.
- `gpforum_walk3` and `gpforum_walk3p` were dropped: `pg_database` has no
  `gpforum_walk3%` row. No role was created; setup used the existing
  `gpforum` role.
- The scratch clone and its `local/`, the environment files, the printed
  units, the backup, the `expect` and simulation scripts, the cookie jar
  and the test password were deleted.
- The two owner accounts existed only in the dropped databases.
- Nothing was installed with brew, no second cluster was started, and
  nothing was written outside the scratch directory.
