# Operator walkthrough, iteration 2 (2026-10-09)

The walk of [iteration 1](../2026-10-08-operator-walkthrough-1/README.md)
repeated after iteration 2 ("one front door"), as a sysadmin who has never
seen GPForum. The macOS quick start was **run**. The Debian 13 install was
**walked through its documents and code** without a VM. `gpforum doctor` was
broken ten ways on purpose, and what it said is quoted for each.

- **Tree:** `main` at `c5d7209`, cloned into a scratch directory, so nothing
  uncommitted took part.
- **Host:** macOS 27 on arm64, 10 CPUs, with Homebrew perl 5.44.0 and
  postgresql@18 18.6.
- **Database:** the machine's shared PostgreSQL 18 on `127.0.0.1:55433`, in a
  database created for the walk (`gpforum_walk2`) and dropped at the end.
  That cluster trusts every connection.
- **Mail:** the development default, the `log` transport, with no MTA.
- **Language:** commands ran with `LC_ALL=en_US.UTF-8`, and the messages were
  also triggered with `it_IT.UTF-8`.

Each step is marked **run** (typed here, with what it printed), **simulated**
(run here with one probe replaced, because this Mac has no systemd and its
cluster asks for no password), **traced** (read in the documents and code it
rests on), or **not checkable** (it needs a Debian host, DNS, a certificate
or an MTA).

In the quotes, `…/w2.env` is the scratch environment file and `…/walk2-clone`
the scratch clone. Both were full paths under the scratch directory.

## 0. Headline

| Measure | Iteration 0 | Iteration 1 | Iteration 2 | Target (audit 5.4) | Met |
| --- | --- | --- | --- | --- | --- |
| macOS quick start to a signed-in admin, without an MTA | dead end at step 14 | 16 steps, plus an undocumented 17th for a ready node | **14 steps** (13 commands, 1 browser action). `/health/ready` 200 and the dashboard's "Health and runtime: OK" with no extra step | ~15 steps, no dead end | **yes** |
| macOS wall time, clone to signed-in admin | — | about 5 min 40 s | **4 min 23 s**. 166 s of that is the dependency install, with Carton and a warm cpanm cache already there | — | — |
| Debian steps, bare host to an admin behind TLS | 31 | 22 | **19** (18 without step 5's look at the help) | ≤ 15 | **no** (see 2) |
| Debian documents the operator must open | 12 | 2 | **2** (README, DEPLOYMENT), plus the environment file template they edit | ≤ 4 | **yes** |
| Debian typed commands | about 60 | 34 | **34**, plus the closing `gpforum doctor` | — | — |
| First admin | psql, a UUID and a verified mail | psql and a UUID | **`gpforum admin create`**. No psql, no mail | without psql | **yes** (run) |
| `script/gpforum-carton exec perl -Ilib` or `set -a; . env` in README, DEPLOYMENT, docs/ops | everywhere | 5 times in README, plus DEPLOYMENT's shell function | **0** | 0 | **yes** (grep) |
| Breaks that `gpforum doctor` names with a `Fix:` line | — | — | **10 of 10**. 7 fixed here to `✓`; 3 need a cluster that checks passwords, systemd or a proxy, which this Mac does not run | 10 | **yes** |
| Undocumented Debian steps | 6 | 0 | **0** | 0 | **yes** |

Four of the five acceptance targets of iteration 2 are met. The fifth, Debian
in at most 15 steps, is not met: 19 rows at iteration 1's granularity. Section
2 says which rows are left, and the guided setup of iteration 3 (C1, C2)
removes them. The friction left is in section 5, ranked, as input for
iteration 3.

## 1. macOS with Homebrew: the README quick start, run

These are the commands as typed, in README order.

**Deviations.** Each one exists only to protect the shared machine:

- `brew install` was not re-run, because it would upgrade the owner's
  packages. `brew list --versions` showed all three present.
- `brew services start postgresql@18` was not run, because it would start a
  second cluster.
- `createuser` and `createdb` got `-h 127.0.0.1 -p 55433`.
  `GPFORUM_DATABASE_DSN` was exported to point at `gpforum_walk2`, which the
  README allows.
- `bin/gpforum` was linked into a scratch directory put first on `PATH`, not
  into `$(brew --prefix)/bin`, which is the owner's.
- `admin create` got `--password-stdin`, because the tool's shell has no
  terminal. The password was a generated test value in a scratch file.

| # | Command or action (README) | Result | Time |
| --- | --- | --- | --- |
| 1 | `brew install perl cpanminus postgresql@18` | not re-run. `cpanminus 1.7049`, `perl 5.44.0`, `postgresql@18 18.6` are present | – |
| 2 | `brew services start postgresql@18` | not run (shared cluster) | – |
| 3 | `export PATH="$(brew --prefix postgresql@18)/bin:$PATH"` | ok | – |
| 4 | `"$(brew --prefix)/bin/perl" "$(brew --prefix cpanminus)/bin/cpanm" -M https://cpan.metacpan.org/ Carton` | `Carton is up to date. (v1.0.35)` | 2 s |
| 5 | `make system-perl` | exit 0, **4 lines** (41 in iteration 1): `✓ Perl 5.44.0 at /opt/homebrew/Cellar/perl/5.44.0/bin/perl`, then `Next: make install-deps-postgres, or sudo make install-deps-production on a server` | 0 s |
| 6 | `make install-deps-postgres` | exit 0, `130 distributions installed`, ends `cpanfile's dependencies are satisfied.` with no `Next:` line | 166 s |
| 7 | `script/system-preflight` | exit 0, **8 lines** (52 in iteration 1): Perl, Carton, dependencies, host, web processes and open files, each `✓`, then `Nothing to fix.` | 1 s |
| 8 | `createuser gpforum` (macOS comment) | literally, with no server on 5432: `createuser: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed`. Against 55433: `role "gpforum" already exists`, as expected on a shared cluster | – |
| 9 | `createdb --owner gpforum gpforum` | as `gpforum_walk2` on 55433, exit 0 | – |
| 10 | `export GPFORUM_DATABASE_PASSWORD=…` | "not on macOS": skipped, as the comment says | – |
| 11 | `ln -s "$PWD/bin/gpforum" "$(brew --prefix)/bin/"` | into a scratch directory (deviations). `gpforum` alone prints the grouped help (Set up, Run, Check, Maintain) and its last lines: `Settings come from the shell's environment: this host has no /opt/homebrew/etc/gpforum/gpforum.env.` | 1 s |
| 12 | `gpforum migrate` | **Without the DSN first** (5432 is empty), exit 1:<br>EN `Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused): start it with brew services start postgresql@18, or correct GPFORUM_DATABASE_DSN in your shell's environment.`<br>IT `PostgreSQL non risponde su 127.0.0.1:5432 (connessione rifiutata): avvialo con brew services start postgresql@18, oppure correggi GPFORUM_DATABASE_DSN nell'ambiente della shell.`<br>With the DSN, exit 0, two lines: `Applied 51 migrations, 001 to 051; synced the query budgets (25 changed).` `Next: make the forum's owner, with gpforum admin create --email you@example.com --username you`. Run again: `Schema is current (051).`, the same `Next:` line, exit 0 | 0.7 s |
| 13 | `gpforum admin create --email … --username …` | As typed in README, with no terminal: `There is no terminal to ask for the password on: give it on standard input with --password-stdin.`, then the usage, exit 2. With `--password-stdin`: `✓ walkadmin (walkadmin@walk2.test) is the forum's owner and can sign in now.` `Next: sign in at http://127.0.0.1:3000/login`, exit 0. Run again: `walkadmin (walkadmin@walk2.test) is the forum's owner already; nothing was created, and its password is as it was.`, exit 1. After it, `gpforum migrate` no longer offers `admin create` | 0.5 s |
| 14 | `gpforum start --foreground` | `Listening at "http://127.0.0.1:3000"`. `/health/ready` **HTTP 200, `"status":"ok"`**, `query_budget_drift` ok | 2 s |
| 15 | Open <http://127.0.0.1:3000>, sign in | sign-in 302 to `/`, `/admin` **200**, "Health and runtime: **OK**" | – |

**Count:** 14 steps to a signed-in admin, at iteration 1's granularity (its
16 rows minus the verification link and the admin's psql query, plus the
`ln -s`, with step 10 skipped on macOS). That is 13 typed commands and one
browser action. No step outside the README is needed for a ready node.

**Wall time:** clone at 05:47:14, dependencies done 05:50:14, schema at
05:50:49, server listening 05:51:17, `/admin` 200 at 05:51:37. That is
**4 min 23 s**, 166 s of it the dependency install. The server was stopped at
05:56:43, after the breaks of section 3.

**Documents opened:** README.md only.

**Also run:** a member registered at `/register`, which says "Account
walkmember was created. Check your email to verify before signing in." The
README's `bin/gpforum outbox --once` printed the mail, link included, then
`outbox_dispatch selected=3 dispatched=3 failed=0 dead_lettered=0`. The link
answered 200. `gpforum doctor` and `gpforum status` on the running
development node each ended `Nothing to fix.`, exit 0.

## 2. Debian 13, production, behind nginx: the documents and the code, walked

I started at README.md, which sends production to
DEPLOYMENT.md#install-on-debian-or-ubuntu. The rows follow iteration 1's
granularity. The commands in the right-hand column were typed on this Mac
against a copy of `deploy/gpforum.env.example` with `GPFORUM_ENV=production`,
read through `gpforum --env-file`.

| # | Step | DEPLOYMENT.md | Here | What I saw or found |
| --- | --- | --- | --- | --- |
| 1 | Host packages, one line with nginx, certbot and ClamAV | step 1 | not checkable | Unchanged |
| 2 | Carton | step 1 | traced | Unchanged |
| 3 | Service user | step 2 | traced | Unchanged |
| 4 | Code location and ownership, `gpforum` on the `PATH` | step 2 | traced | `sudo ln -s /opt/gpforum/bin/gpforum /usr/local/bin/gpforum` is new in this step. Debian's sudo `secure_path` includes `/usr/local/bin`, so `sudo gpforum` and `sudo -u gpforum gpforum` find it |
| 5 | Install dependencies | step 2 | run (development variant, macOS) | |
| 6 | Database role | step 3 | traced | |
| 7 | Database | step 3 | run (55433) | |
| 8 | Environment file in place | step 4 | run | `install -m 0640` of the template |
| 9 | Secrets, and fill in the rest | step 4 | run | The template as copied: `doctor` lists all **four** problems at once and checks nothing else (3.1, break 7). `gpforum --env-file …/w2.env secret rotate session` and `metrics`, as offered, wrote both. Each said `✓ A new session secret is in …/w2.env.` and then `Next: sudo launchctl kickstart -k system/com.gpforum.app && …`. On a first install there is nothing to restart yet: on Debian that would be `sudo systemctl restart gpforum gpforum-outbox` at step 4, before step 9 installs the units (friction 2). The mode stayed `-rw-r-----` |
| 10 | `sudo -u gpforum gpforum`: the commands as the service runs them | step 5 | run | One line, no shell function. It prints the help and names the file it read. It looks rather than does, hence "18 without it" |
| 11 | Schema, partitions and budgets | step 6 | run | One command (iteration 1 had two rows here). `Schema is current (051).` |
| 12 | Mail: MTA and probe | step 7 | MTA not checkable; probe run | `doctor`, `mail-check` and DEPLOYMENT now say what the dry run proves and what it does not, and that a VPS usually relays through `smtp`. `gpforum --env-file F mail-check` offers `gpforum mail-check --send …` **without** `--env-file F` (friction 3) |
| 13 | Antivirus | step 8 | not checkable; the check run without clamd | One finding with three fixes (3.2, break 5), not eight repeated lines. On a VM, still confirm the order of the two `StreamMaxLength` lines, and that clamd waits for freshclam |
| 14 | Install units, daemon-reload | step 9 | simulated | `doctor` compares the installed units with the release's (break 9) |
| 15 | Start web, outbox and timers | step 9 | simulated | `doctor` reads each timer and both services (break 8) |
| 16 | TLS certificate | step 10 | not checkable | |
| 17 | nginx site | step 10 | traced | |
| 18 | Health | step 10 | run (development) | `/health/ready` 200 straight after `gpforum migrate` |
| 19 | First admin | step 11 | run (macOS) | `sudo -u gpforum gpforum admin create …`, one command. Iteration 1's rows Register, Verify and First admin become this one row |

**Count:** 19 steps (iteration 1: 22). The changes are:

- three rows become one: register, verify and psql become `admin create`;
- two rows become one: migrate and budgets become `gpforum migrate`;
- the shell function becomes one line;
- `ln -s` joins row 4.

There are 34 typed commands, as in iteration 1:

| Where | Commands |
| --- | --- |
| `site=` | 1 |
| Step 1 | 2 |
| Step 2 | 6 |
| Step 3 | 2 |
| Step 4 | 5 (2 of them `secret rotate`) |
| Step 5 | 1 |
| Step 6 | 1 |
| Step 7 | 2 |
| Step 8 | 3 |
| Step 9 | 4 |
| Step 10 | 6 |
| Step 11 | 1 |

The closing `gpforum doctor` makes 35. **2 documents**, README and DEPLOYMENT,
plus the environment file template. Links followed only for detail:
ops/doctor.md, ops/antivirus.md, ops/upgrade.md.

**Why 19 and not 15.** Rows 3 to 11 are nine host chores that one guided
command can do: the user, ownership, the link, the role, the database, the
file, the secrets, the edits and the schema. That command is C1, `gpforum
setup`, with three questions. Rows 14 and 15 become a printed copy (C2,
`gpforum service print`). With both, the Debian path is about 9 rows, as
iteration 3's acceptance asks (≤ 8 typed commands).

## 3. `gpforum doctor`, broken ten ways

Each break was made on purpose, then `gpforum doctor` was run.

- **Production breaks:** through `gpforum --env-file …/w2.env doctor`, with
  `GPFORUM_ENV=production`, a resolvable-looking but unknown
  `GPFORUM_PUBLIC_BASE_URL=https://forum.walk2.test`,
  `GPFORUM_MAIL_FROM=forum@walk2.test`, sendmail and clamd.
- **Development breaks:** through the shell, as the README runs it.
- **The two systemd breaks (8, 9):** this Mac has no systemd. A scratch script
  built the same `GPForum::Command::Doctor` with three changes:
  - `os => linux`;
  - a unit directory in scratch, holding the six units of `deploy/systemd`;
  - a `systemctl show` that answers as a Debian host would.

  So the sentences and fixes are Debian's, and everything else was read live.
- **The wrong password (2):** the shared cluster trusts every connection, so
  the database probe was replaced. It threw libpq's own message.

Every line printed is the full finding, `Fix:` lines included.

| # | Break | How | Here | What doctor said | The fix |
| --- | --- | --- | --- | --- | --- |
| 1 | Database unreachable | DSN port 55439 in the file; also no DSN in development | run | `✗ Cannot reach PostgreSQL at 127.0.0.1:55439 (connection refused)`<br>`Fix: start it with brew services start postgresql@18, or correct GPFORUM_DATABASE_DSN in …/w2-down.env`<br>On Debian (simulated): `start it with sudo systemctl start postgresql, or …`. Host, settings, mail and antivirus are still checked; schema, budgets, readiness and outbox wait | correcting the port: `✓ database: PostgreSQL 18.6, gpforum_walk2 at 127.0.0.1:55433` |
| 2 | Wrong password | probe throws `FATAL:  password authentication failed for user "gpforum"` | simulated | `✗ PostgreSQL at 127.0.0.1:55433 refused the password of role gpforum`<br>`Fix: correct GPFORUM_DATABASE_PASSWORD in …/w2.env, or set the role's password with sudo -u postgres psql -c '\password gpforum'`<br>IT `✗ PostgreSQL su 127.0.0.1:55433 ha rifiutato la password del ruolo gpforum` / `Rimedio: correggi GPFORUM_DATABASE_PASSWORD in …` | not checkable on a trusting cluster (t/473 covers the classification) |
| 3 | Migrations pending | the empty database, before `gpforum migrate` | run | `✗ schema: 51 migrations to apply, 001 to 051`<br>`Fix: gpforum migrate`<br>IT `✗ schema: 51 migrazioni da applicare, dalla 001 alla 051` / `Rimedio: gpforum migrate` | run: `✓ schema: current (051)`, `✓ query budgets: as the code sets them` |
| 4 | Outbox stopped | a member's verification mail left waiting, no worker, until the oldest was over 5 minutes old | run | Production: `✗ outbox worker: 3 messages waiting, the oldest for 5 min; nothing is sending them`<br>`Fix: sudo launchctl bootstrap system /Library/LaunchDaemons/com.gpforum.outbox.plist`<br>Debian (simulated): `Fix: sudo systemctl enable --now gpforum-outbox` / `journalctl -u gpforum-outbox says why`<br>Development: `Fix: gpforum outbox --loop`<br>IT `✗ worker dell'outbox: 3 messaggi in attesa, il più vecchio da 5 min; nessuno li sta inviando`. Under 5 minutes it was `✓ outbox worker: 3 waiting, the oldest for 2 min` | the README's `bin/gpforum outbox --once`, then: `✓ outbox worker: nothing waiting; the last message left 0 s ago` |
| 5 | clamd absent | `GPFORUM_ANTIVIRUS=clamd`, no clamd on this Mac | run | `✗ antivirus: clamd does not answer at /opt/homebrew/var/run/clamav/clamd.sock`<br>`Detail: No such file or directory`<br>`Fix: brew install clamav`<br>`or, if it is installed, start it: brew services start clamav (clamd waits for freshclam's first download)`<br>`or set GPFORUM_ANTIVIRUS=none in …/w2.env, and uploads are checked for format only`<br>Debian (simulated): `sudo apt install clamav-daemon clamav-freshclam` / `sudo systemctl enable --now clamav-daemon` | with scanning off (the development runs): `✓ antivirus: off; uploads are checked for format only` |
| 6 | Wrong public URL | the template's `https://forum.example.com`; then `https://forum.walk2.test`, which no DNS knows | run | The template's: `✗ GPFORUM_PUBLIC_BASE_URL is 'https://forum.example.com', an example address that leads nowhere; production needs the one members reach this forum at.` / `Fix: correct GPFORUM_PUBLIC_BASE_URL in …/w2.env`<br>The unknown one: `! address: https://forum.walk2.test does not answer: its host name is not known`<br>`Fix: point forum.walk2.test at this host in the DNS, or correct GPFORUM_PUBLIC_BASE_URL in …/w2.env`<br>IT `! indirizzo: https://forum.walk2.test non risponde: il suo nome host non è noto` | an address that answers (development): `✓ address: http://127.0.0.1:3000 answers` |
| 7 | Missing secret | the template as copied, both secrets empty | run | `✗ GPFORUM_SESSION_SECRET is required in production.`<br>`Fix: gpforum --env-file …/w2.env secret rotate session`<br>`✗ GPFORUM_METRICS_TOKEN is required in production.`<br>`Fix: gpforum --env-file …/w2.env secret rotate metrics`<br>listed with the two placeholders, then: `The host, the database, mail and the services are checked once the settings above are right.` `4 things to fix.`<br>IT `✗ GPFORUM_SESSION_SECRET è obbligatoria in production.` / `Rimedio: gpforum --env-file … secret rotate session` … `4 cose da sistemare.` | both run as offered, then: `✓ settings: production, read from …/w2.env` |
| 8 | Timer disabled | `systemctl show` answers `UnitFileState=disabled`, `ActiveState=inactive` for the hourly timer | simulated (read: ServiceUnits `timers`) | `! timer: gpforum-scheduled-jobs.timer is not on, so its job never runs`<br>`Fix: sudo systemctl enable --now gpforum-scheduled-jobs.timer`<br>and beside it `✓ timer: gpforum-partition-maintenance.timer fired 9 h ago` | not checkable without systemd |
| 9 | Unit drifted | one line added to the installed `gpforum-outbox.service` (`Environment=GPFORUM_LOG_LEVEL=debug`) | simulated (read: ServiceUnits `units`) | `! services: gpforum-outbox.service differs from this release's`<br>`diff -u …/w2-systemd/gpforum-outbox.service …/walk2-clone/deploy/systemd/gpforum-outbox.service shows how`<br>`Fix: sudo cp …/walk2-clone/deploy/systemd/gpforum-outbox.service …/w2-systemd/`<br>`sudo systemctl daemon-reload`<br>`sudo systemctl restart gpforum gpforum-outbox` | the `cp` run (without sudo, into the scratch directory): `✓ services: 6 files in …/w2-systemd, as this release ships them` |
| 10 | Proxy down | `GPFORUM_PUBLIC_BASE_URL=https://127.0.0.1:18443`, where nothing listens; then `https://localhost:3000`, the plain-HTTP development server | run | `! address: https://127.0.0.1:18443 does not answer: connection refused`<br>`Fix: put deploy/nginx/gpforum.conf in place, as step 10 of docs/DEPLOYMENT.md shows`<br>`sudo launchctl bootstrap system /Library/LaunchDaemons/com.gpforum.app.plist`<br>The plain-HTTP port: `! address: no TLS handshake with https://localhost:3000: LibreSSL/3.3.6: error:1404B42E:SSL routines:ST_CONNECT:tlsv1 alert protocol version`, with the same fixes | not checkable without a proxy |

**Verdict.** All ten breaks are named, each with a `Fix:` that says what to
change, the file to change it in, and the command. Seven were fixed here as
offered and turned `✓`: 1, 3, 4, 5, 6, 7, and 9 in the scratch unit
directory. Three need a host this Mac is not: a cluster that asks for
passwords (2), systemd (8) and a proxy (10).

### 3.1 The other checks, in production mode (run)

- **`gpforum --env-file …/w2.env status`**, with nothing on 8080:
  - `✗ http://127.0.0.1:8080 does not answer: connection refused`
  - `Fix: sudo launchctl bootstrap system /Library/LaunchDaemons/com.gpforum.app.plist`
  - `or, if it listens elsewhere, name that address: gpforum --env-file …/w2.env status --url http://HOST:PORT`
  - It exits 1.
- **`gpforum --env-file …/w2.env antivirus-check`**: the antivirus finding of
  break 5, then `1 thing to fix.`, exit 1.
- **`gpforum --env-file …/w2.env mail-check`**: `✓ mail: from
  forum@walk2.test through sendmail at /usr/sbin/sendmail`, the two notes,
  then `Nothing to fix.`, exit 0. Its note offers `gpforum mail-check --send
  --to you@example.com --human` without the `--env-file` it was run with. The
  same note from `doctor` carries it.
- **`gpforum --env-file …/w2.env doctor --upgrade`**:
  - `✓ dependencies: the 18 modules this release needs, for Perl 5.44.0`;
  - settings, database, schema and budgets `✓`;
  - `! services: com.gpforum.app.plist, … not installed in
    /Library/LaunchDaemons`, with one `sudo cp` of the four plists (about 700
    characters with this clone's path) and no `launchctl bootstrap`;
  - exit 0.
- **On the healthy production file:** `3 things to fix`, all three expected
  on this Mac (clamd, the launchd plists, the unknown address), exit 1, in
  1 s.

### 3.2 Old commands (run)

- `script/gpforum-carton exec perl -Ilib bin/gpforum-migrate --check` still
  prints `migrate check status=ok pending=0`.
- `script/gpforum-carton exec bin/gpforum-outbox-dispatch --help` still gives
  its usage.
- `bin/gpforum-outbox-dispatch` alone dies with `Can't locate Const/Fast.pm in
  @INC`, as before iteration 2. DEPLOYMENT's "The front door and the old
  commands" says the old commands also work "on their own
  (`bin/gpforum-partition-maintenance`, which does not read the environment
  file)". They work through `script/gpforum-carton exec`, not alone.

## 4. Iteration 1's friction list, now

| # (iteration 1) | Now |
| --- | --- |
| 1 Quick start leaves the node `fail` | **closed**: `gpforum migrate` syncs the budgets; `/health/ready` 200 |
| 2 First admin needs psql and a UUID | **closed**: `gpforum admin create`; no terminal is a sentence, not a bare usage |
| 3 No front door | **closed**: `gpforum VERB`, grouped help, the file read and named |
| 4 Placeholders pass production | **closed**: refused, with the file to correct (0fc039f) |
| 5 Mail proven by a binary | **closed in words**: doctor, mail-check and DEPLOYMENT say what the dry run proves, and the VPS caveat; delivery still needs `--send` |
| 6 No doctor, no status | **closed** (run). The config error written three times to the journal under `--strict --json`, and Hypnotoad's 255: not re-run |
| 7 migrate says too much or nothing | **closed**: one line, `Schema is current (051).` |
| 8 Setup tools bury their verdict | **closed**: 4 and 8 lines, each with a verdict. `make install-deps-postgres` still ends without `Next:` |
| 9 antivirus-check without clamd | **closed**: one finding, three fixes. The `StreamMaxLength` order and freshclam still need a VM |
| 10 The report names the template | **closed** for doctor, migrate and the front door, which name the file read. The start was not re-run here |
| 11 Mojolicious's help | **closed** |
| 12 Retired settings in os-preflight | `system-preflight` and doctor speak sentences; `os-preflight --human` was not re-run |
| 13 Docs drift | mail-check.md, README's GlifiStore line and staging-host.md are fixed. DEPLOYMENT's `GPFORUM_CARTON` paragraph remains |
| 14 Sign-up page does not say where dev mail went | open (frontend, the owner's) |
| 15 Upgrade is one sentence | **closed**: docs/ops/upgrade.md, three commands, `doctor --upgrade` |
| 16 Carried review items | closed by the settings stream: the cache floor, `%%`, staging-host-verify's keys, the test transport, the log level, the read rate limit, the launchd account, the not-migrated sentence, quoting, `GPFORUM_SMTP_TLS`. Still open: the settings page's restart line (frontend) and `os-preflight --strict` in English |

## 5. Friction left, ranked (input for iteration 3: guided setup)

The ranking puts value to a new operator first, then how often they meet it.
**S/M/L** is effort.

1. **Debian is still 19 steps, against ≤ 15.** Nine of them are the chores
   `gpforum setup` (C1) exists for:
   - the user;
   - code ownership and the link;
   - the role and the database;
   - the file, its secrets and its edits;
   - the schema.

   Two more, copying and enabling the units, are `gpforum service print`
   (C2). L. Iteration 3.
2. **`secret rotate` on a first install says to restart services that do not
   exist yet.** At DEPLOYMENT step 4, `Next: sudo systemctl restart gpforum
   gpforum-outbox` would answer "Unit gpforum.service not found". It should
   say the next setup step, or nothing, when no unit is installed. The same
   holds for the launchd form here. S.
3. **`gpforum --env-file F mail-check` offers commands without `--env-file
   F`.** Its note `gpforum mail-check --send --to you@example.com --human`,
   typed as offered, checks the host's file instead. doctor and status
   rewrite theirs with `ServiceEnvironment->as_read`; Command/MailCheck does
   not. S. A defect.
4. **The launchd and proxy fixes are not a working path on macOS.**
   - The missing-plists fix is a single `sudo cp`, about 700 characters, with
     no `launchctl bootstrap` after it.
   - The plists hard-code `/opt/gpforum`, so a checkout elsewhere is copied
     with the wrong paths.
   - The proxy fix sends a Mac to "step 10 of docs/DEPLOYMENT.md", Debian's
     nginx.

   C2 (`service print launchd`) is the fix. M.
5. **The fixes print long absolute paths.** The unit `cp` and `diff` lines
   repeat the checkout's full path for every file. `cd /opt/gpforum && sudo
   cp deploy/systemd/X /etc/systemd/system/`, or a glob, would read in one
   glance. S.
6. **The failing database line has no label.** It reads `✗ Cannot reach
   PostgreSQL at …`, where every other line is `name: …` (`✓ database:
   PostgreSQL 18.6, …`). S.
7. **The TLS handshake line quotes the library.** `no TLS handshake with URL:
   LibreSSL/3.3.6: error:1404B42E:SSL routines:ST_CONNECT:tlsv1 alert protocol
   version`. The sentence before the colon is enough; the raw text belongs
   under `Detail:`, as the antivirus line does it. S.
8. **Some verbs still print `key=value`:**
   - `outbox --once`'s summary, `outbox_dispatch selected=3 …`;
   - `partitions`, which also plans 9 partitions on an unmigrated database
     with exit 0;
   - bare `budgets`, a list with no verdict;
   - `migrate --check`;
   - `scheduled-jobs`.

   S each.
9. **The old commands do not work "on their own".** `bin/gpforum-X` alone
   dies with `Can't locate Const/Fast.pm`; it works through
   `script/gpforum-carton exec`. Either the old entrypoints re-exec as
   `bin/gpforum` does, or DEPLOYMENT says "through gpforum-carton". S.
10. **Long forms remain outside the acceptance set.**
    - In 7 runbooks, 14 lines still type `script/gpforum-carton exec
      bin/gpforum-…`: dead-letters, antivirus, partition-maintenance,
      scheduled-jobs, private-beta-checklist, stress-load and staging-drills.
      `gpforum VERB` replaces each.
    - backup-and-restore.md runs `bin/gpforum-migrate --check`.
    - docs/MVP.md (5 lines) and OUTBOX_LIFECYCLE.md (1) still have the
      literal `script/gpforum-carton exec perl -Ilib`.
    - DEPLOYMENT still offers `GPFORUM_CARTON`.

    S.
11. **Timers and running services are read under systemd only.** On launchd
    and rc, doctor compares the installed files and nothing more. M.
12. **Placeholders slip past in two places.**
    - A `--help` text and README use `you@example.com`, which doctor's own
      note repeats as the address to send a probe to.
    - A `GPFORUM_MAIL_FROM` with a display name (`Forum
      <forum@forum.example.com>`) slips past the placeholder check (settings
      review).

    S.
13. **Carried from the iteration-2 reviews, not re-run here:**
    - doctor quotes an invalid setting's value, a password inside a DSN
      included;
    - on FreeBSD and macOS the rc script and the plists set `GPFORUM_ENV`
      themselves, so the service ignores the file's value while `gpforum
      doctor` reads it;
    - IO::Socket::SSL is not in the cpanfile, so DEPLOYMENT step 7 adds an
      `apt install` for smtp's TLS;
    - the macOS `sysadminctl`/`dseditgroup` lines in DEPLOYMENT are
      untested;
    - per-verb `--help` is English only;
    - `bin/gpforum` dies at `use v5.40` when `perl` on `PATH` is the system
      5.34;
    - CHANGELOG has no entries yet for the iteration-2 streams, so an
      upgrading operator is not told to re-copy `gpforum-unix-socket.service`
      or the plists.

    S each, except the cpanfile row, which needs a license-review row.
14. **Development sign-up still says "Check your email".** One line could
    point to the outbox worker's output. S. Frontend, the owner's.

## 6. Clean-up

- The server on port 3000 was stopped; the port is free.
- `gpforum_walk2` was dropped: `pg_database` has no such row.
- The scratch clone and its `local/`, the environment files, the unit
  directory, the simulation script, the cookie jars, the test password and
  the logs were deleted.
- The two throwaway accounts lived only in the dropped database.
- Nothing was installed with brew, and no second cluster was started.
