# Operator walkthrough, iteration 4 (2026-10-11)

The walk of [iteration 3](../2026-10-10-operator-walkthrough-3/README.md),
repeated after iteration 4: setup installs the dependencies and links
`gpforum`, `service print --to` writes where the system reads, the metrics
tokens are re-read with no restart, `gpforum upgrade`, and the settings cut
to what an installation decides. It was walked as a sysadmin who has never
seen GPForum, with the same method and the same limits as iteration 3.

- **Tree:** `main` at `76f7d69`, cloned into a scratch directory, so nothing
  uncommitted took part. The walk ran on 2026-10-09, from 22:51 to 23:01
  local time.
- **Host:** macOS 27 on arm64, 10 CPUs, 16 GB, with Homebrew perl 5.44.0
  and postgresql@18 18.6.
- **Database:** the machine's shared PostgreSQL 18 on `127.0.0.1:55433`,
  whose superuser is the role `gpforum`. Setup made `gpforum_walk4`
  (development, role `gpforum`) and `gpforum_walk4p` (production, a new
  role `walk4`). Both databases and the role were dropped at the end.
- **Homebrew:** `HOMEBREW_PREFIX` named a directory in scratch, one for each
  walk, with its `bin` first on `PATH`. Setup wrote the environment file
  under it and linked `gpforum` into it, as it does into Homebrew's own.
  Nothing was written under `/opt/homebrew`.
- **Terminal:** every question was answered through `expect`, as in
  iteration 3, and `admin create` asked for its password at that terminal.

Each step is marked with how it was checked:

- **run:** typed here; its output is quoted.
- **simulated:** run here with the operating system replaced (Linux for
  `ServiceFiles`), because this Mac has no systemd, no nginx and no root.
- **traced:** read in the documents and code it rests on.

## 0. Headline

| Measure | It. 0 | It. 1 | It. 2 | It. 3 | **It. 4** | Target | Met |
| --- | --- | --- | --- | --- | --- | --- | --- |
| macOS quick start to a signed-in admin | dead end | 16 steps | 14 steps | 12 steps | **5 steps**: 4 commands, 1 browser action (1) | — | — |
| Debian typed commands, clone to signed-in admin behind TLS | — | — | — | 15 | **8**, plus 2 before the clone: the `apt` line and Carton (2) | ≤ 8 | **yes** |
| Debian questions | — | — | an editor | 3 | **3**: 1 typed (the address), 2 Enter | about 3 | **yes** |
| Debian documents opened | 12 | 2 | 2 | 2 | **1**, the README | 1 | **yes** |
| macOS production typed commands, clone to signed-in admin behind TLS | — | — | — | 17, no TLS step | **10**, TLS included (3) | ≤ 8 | **no**, by 2 |
| macOS production documents | — | — | — | 2 | **2**: README for the packages, DEPLOYMENT's macOS section | 1 | **no** |
| Upgrade, from `gpforum help` | one sentence | — | 3 lines in a document | 3 lines, reached through a document | **`gpforum upgrade`**, under Maintain, prints **3 lines** for this host (4.1) | ≤ 3, from the help | **yes** |
| Metrics-token rotation | `openssl rand` and an editor | — | 4 commands | 4 commands | **2 commands** and the scrapers' change, **no restart**: 146 of 146 scrapes answered 200 (4.2) | 3, no restart | **yes**, with 2 defects open |
| Settings a human types, common production case | 95 variables | — | — | 10 set, 258-line file | **1 typed, 2 accepted**; the file is 41 lines with 10 decisions (2.1) | 3 | **yes** |
| Doctor reports the size the host derived | — | — | — | `web processes: 14 for 10 CPUs` | **`✓ sized for 10 CPUs, 16 GB: 14 web processes, 8192 cache entries a process`**, in Italian too (4.3) | yes | **yes** |
| Old names: starts, lists each with its replacement | — | — | — | — | **starts**; 5 old names, each logged and each under `!` in doctor with its line (4.4) | yes | **yes** |

Iteration 4 meets 8 of its 9 targets. macOS production is 2 commands over,
and needs two documents. Two defects in the token re-read, found by the
token review and left open, were reproduced here against a running
service (4.2). Section 5 ranks what is left.

## 1. macOS: the README quick start (run)

| # | README | Here | Result |
| --- | --- | --- | --- |
| 1 | `make install-deps-postgres` | run | 32 distributions on top of the production ones (2.1), 33 s. It ends `Next: check the host, with script/system-preflight`, a step the quick start no longer has (friction 4) |
| 2 | `bin/gpforum setup --environment development` | run, at a terminal | Enter, the shared cluster's data source, Enter (below) |
| 3 | `gpforum admin create --email … --username …` | run | `✓ walk4dev (dev@gpforum-walk4.org) is the forum's owner and can sign in now.` |
| 4 | `gpforum start --foreground` | run | `/health/ready` `{"check":"ready","status":"ok"}` after 1.5 s |
| 5 | sign in at `http://127.0.0.1:3000/login` | run (curl, with the form's CSRF token) | 302 to `/`, `/admin` 200, "Health and runtime OK" |

```text
GPForum setup. Three questions; Enter accepts the suggestion.
Public address [http://127.0.0.1:3000]:
Database [create 'gpforum' on this host]: dbi:Pg:dbname=gpforum_walk4;host=127.0.0.1;port=55433
Mail (sendmail, smtp HOST:PORT USER, or log) [log]:
✓ …/hb-dev/etc/gpforum/gpforum.env: written, 0640 gpicchiarelli:wheel, with a new session secret and metrics token
✓ gpforum: linked into …/hb-dev/bin, so it runs from any directory
✓ database gpforum_walk4 at 127.0.0.1:55433: made, for role gpforum, as PostgreSQL's superuser gpforum
✓ Applied 51 migrations, 001 to 051; synced the query budgets (25 changed)

Next: make the forum's owner, with gpforum admin create --email EMAIL --username NAME
Then: start the forum, with gpforum start --foreground
Then: check the whole forum, with gpforum doctor
```

Setup took 1 s. `gpforum doctor` printed twelve `✓` lines and `Nothing to
fix.` Only README.md was open.

**Step 1 is not needed.** Run on a checkout without `local/`, `gpforum
setup` installs the dependencies itself, the development tools too for
`--environment development` (`CLI/FrontDoor/Carton.pm`, `setup_install`).
The production walk below shows it doing so. The quick start can be three
commands (friction 5).

## 2. Debian 13, production, behind nginx

### 2.1 Setup on a fresh clone (run, as the operator, without root)

`bin/gpforum setup` on the fresh clone, answered with the address, the
shared cluster's data source and Enter, with `--database-user walk4` so
the walk had its own role:

```text
gpforum setup installs the dependencies into …/walk4-clone/local first, as make install-deps-production does: carton install --deployment --without develop
100 distributions installed
cpanfile's dependencies are satisfied.

✓ dependencies: installed into …/walk4-clone/local, for Perl 5.44.0
GPForum setup. Three questions; Enter accepts the suggestion.
Public address [https://imac-di-giacomo.fritz.box]: https://forum.gpforum-walk4.org
Database [create 'gpforum' on this host]: dbi:Pg:dbname=gpforum_walk4p;host=127.0.0.1;port=55433
Mail (sendmail, smtp HOST:PORT USER, or log) [sendmail]:
! not run as root: …/hb-prod/etc/gpforum/gpforum.env is yours, and the services' account gpforum is not made
    Fix: sudo gpforum setup
✓ …/hb-prod/etc/gpforum/gpforum.env: written, 0640 gpicchiarelli:wheel, with a new session secret and metrics token
✓ gpforum: linked into …/hb-prod/bin, so it runs from any directory
✓ database gpforum_walk4p at 127.0.0.1:55433: made, with its role walk4, as PostgreSQL's superuser gpforum
✓ Applied 51 migrations, 001 to 051; synced the query budgets (25 changed)

Next: make the forum's owner, with gpforum admin create --email EMAIL --username NAME
Then: install and start the services, with sudo gpforum service print launchd --to /Library/LaunchDaemons
Then: check the whole forum, with gpforum doctor
```

144 s, almost all of it the dependencies. The file is 41 lines: a
four-line header, ten settings each under one line saying what it is, and
the four SMTP lines commented out. One setting was typed, the address; the
sender `forum@forum.gpforum-walk4.org` followed it. Every value was
accepted by `doctor`, which checked settings, sizing, host, open files,
database, schema, budgets, readiness, outbox and mail with `✓`, and named
four things to fix: antivirus, the account, the services and DNS.

### 2.2 Debian's own steps (simulated and traced)

A scratch script built `ServiceFiles` for Linux, `/opt/gpforum` and
`/etc/gpforum/gpforum.env`, and asked for the steps setup, `service print`
and doctor give:

```text
install_step: sudo gpforum service print systemd --to /etc/systemd/system
systemd, in place:
  sudo systemctl daemon-reload && sudo systemctl enable --now gpforum gpforum-outbox gpforum-scheduled-jobs.timer gpforum-partition-maintenance.timer
nginx, no certificate yet:
  sudo certbot certonly --nginx -d forum.gpforum-walk4.org
  sudo gpforum service print nginx --to /etc/nginx/sites-enabled
  sudo nginx -t && sudo systemctl reload nginx
```

The six units, printed here with `service print systemd --to`, run
`bin/gpforum` only: `ExecStartPre=…/bin/gpforum os-preflight --strict
--json`, `ExecStart=…/bin/gpforum start --service`, `outbox --loop`,
`scheduled-jobs --once`, `partitions --apply`, each with `User=gpforum`
and `EnvironmentFile=/etc/gpforum/gpforum.env`. Decision D9 holds.

### 2.3 The count

The README's production section, from the clone:

| # | Command | Named by |
| --- | --- | --- |
| 1 | `sudo git clone https://github.com/gpicchiarelli/GPForum.git /opt/gpforum` | README |
| 2 | `sudo /opt/gpforum/bin/gpforum setup` (3 questions) | README |
| 3 | `sudo gpforum service print --to /etc/systemd/system` | setup's `Then:` |
| 4 | `sudo systemctl daemon-reload && sudo systemctl enable --now …` | `service print` |
| 5 | `sudo certbot certonly --nginx -d forum.example.org` | `service print nginx`, doctor |
| 6 | `sudo gpforum service print nginx --to /etc/nginx/sites-enabled` | `service print nginx`, doctor |
| 7 | `sudo nginx -t && sudo systemctl reload nginx` | `service print nginx` |
| 8 | `sudo -u gpforum gpforum admin create --email EMAIL --username NAME` | setup's `Next:` |

**8 typed commands; the target is 8.** Before the clone come the `apt`
line and `sudo cpanm … Carton`. One document: the README carries all ten,
and after step 2 each command names the next. Two things sit outside the
count: `StreamMaxLength 26M` in clamd.conf, said in the README's prose and
checked by `antivirus-check`, and a mail server for `sendmail`.

Not run, because they need a Debian host and root: setup's `useradd`, the
`postgres` peer login, `systemd-analyze verify`, `nginx -t` on the site,
and certbot's nginx plugin with Debian's default site in place.

## 3. macOS production with `service print launchd` (run up to root, then traced)

From DEPLOYMENT's macOS section and the commands each step printed:

| # | Command | Here |
| --- | --- | --- |
| 1 | `sudo git clone … /opt/gpforum` | in DEPLOYMENT's prose only |
| 2 | `sudo /opt/gpforum/bin/gpforum setup` | run without root (2.1). DEPLOYMENT types `sudo gpforum setup`, before anything has linked `gpforum` |
| 3 | `sudo gpforum service print --to /Library/LaunchDaemons` | run into scratch: `✓ 4 files for launchd`, all four pass `plutil -lint` |
| 4 | `sudo install -d -o gpforum -g gpforum -m 0750 …/var/log/gpforum` | printed by `service print` and doctor |
| 5 | `sudo launchctl bootstrap system` and the four plists | printed, one line |
| 6 | `brew install nginx certbot` | printed by `service print nginx` |
| 7 | `sudo certbot certonly --standalone -d HOST --pre-hook … --post-hook …` | printed |
| 8 | `sudo gpforum service print nginx --to "$(brew --prefix)/etc/nginx/servers"` | run: refused until the certificate is there, as designed |
| 9 | `sudo nginx -t && sudo brew services restart nginx` | printed |
| 10 | `gpforum admin create …` | run (`sudo -u gpforum` on a real host) |

**10 typed commands, TLS included; the target is 8.** Iteration 3 had 17
and no TLS step. Setup now makes the account on macOS, and doctor checks
it: `✗ account gpforum: not on this host, and the services run as it`,
`Fix: sudo gpforum setup`. Two lines from 8: step 4 can go into setup,
which already makes `var/` as root, or into `service print --to`; step 6
can join the README's `brew install`. Without root, `service print launchd
--to /Library/LaunchDaemons` answered with Perl's own error, `Error in
tempfile() using template …: Permission denied` (friction 7).

## 4. Day two

### 4.1 Upgrade (run)

`gpforum` alone lists `upgrade` under Maintain: "Print the commands that
upgrade this forum". On the production file:

```text
Upgrade this forum with these three commands, in order:

  sudo git -C …/walk4-clone pull && sudo make -C …/walk4-clone install-deps-production
  gpforum migrate && sudo launchctl kickstart -k system/com.gpforum.app && sudo launchctl kickstart -k system/com.gpforum.outbox
  gpforum doctor --upgrade

The last one ends with "Nothing to fix." when the upgrade is complete.
Before them, a backup to come back to: gpforum backup --to /var/backups/gpforum
```

On the development file it printed `cd`, `git pull` and `make
install-deps-postgres`, then `migrate`, then `doctor --upgrade`, and said
to restart `gpforum start --foreground`. Reached in one command from the
help, three lines to type. The `make` on the first line ends with `Next:
check the host, with script/system-preflight` (friction 4). `/var/backups`
is root's on macOS and does not exist on a fresh Debian host, and the line
names no `install -d` (friction 11).

### 4.2 Metrics-token rotation, against a running service (run)

The production file served by `gpforum start --service --foreground`,
Hypnotoad as the units run it, on `127.0.0.1:3040` with two workers. A
scraper sent `Authorization: Bearer` from a file every 0.2 s.

1. `gpforum secret rotate metrics`: `✓ A new metrics token is in …. The
   one before stays in GPFORUM_METRICS_TOKENS, so no scraper is refused.`
   Within 0.6 s both workers logged `Read the metrics tokens again from …: 2
   accepted.` Old token 200, new token 200.
2. The scraper's file was given the new token.
3. `gpforum secret rotate metrics --finish`: `✓ The previous metrics tokens
   are gone from …; a scraper that sends one is refused.` Each worker
   logged `1 accepted.` Old token 401 six times, new token 200 six times.

**146 scrapes in 37 s, 146 answered 200.** The manager and both workers
kept their process ids: there was no restart. The file stayed
`-rw-r-----`. Two commands and the scrapers' change, against 4 commands
in iteration 3.

**Two defects, found by the token review and still open at `76f7d69`,
reproduced here:**

- **A worker Hypnotoad starts later accepts the token `--finish` dropped.**
  After step 3, a line that is not a setting was added to the file and
  both workers were sent `TERM`. Hypnotoad forked two new workers from the
  manager, which never re-reads the file. Both logged that the file changed
  but could not be used, and kept the tokens the service started with:
  the old token answered **200** six times and the current one **401** six
  times. The token was dropped, and access to it came back (friction 1).
- **A file writable by its group is not followed, and nothing says so.**
  With the file at `0660`, `secret rotate metrics` wrote a new token and
  said nothing about the mode. The service refused it (401, four times)
  and kept the one before. `doctor` printed `✓ settings`. A scraper given
  the new token, as the command says, is refused (friction 2).

### 4.3 Sizing (run)

`gpforum doctor`, second line, on both files:
`✓ sized for 10 CPUs, 16 GB: 14 web processes, 8192 cache entries a
process`. In Italian: `✓ dimensionato per 10 CPU, 16 GB: 14 processi web,
8192 voci di cache per processo`. In development the line says 14 web
processes too, where `start --foreground` runs one (friction 9).

### 4.4 An install carrying old names (run)

The production file with `GPFORUM_ENV=production-medium` and four more old
lines: `GPFORUM_SMTP_SSL=off`, `GPFORUM_WORKER_PROCESSES=4`,
`GPFORUM_REALTIME_PROCESSES=2` and `GPFORUM_OS_AFFINITY=on`. Started under
Hypnotoad on port 3041, it served `/health` 200 and logged:

```text
[warn] GPFORUM_WORKER_PROCESSES no longer has any effect; remove it from the environment file.
[warn] GPFORUM_REALTIME_PROCESSES no longer has any effect; remove it from the environment file.
[warn] GPFORUM_OS_AFFINITY no longer has any effect; remove it from the environment file.
[warn] GPFORUM_ENV=production-medium is now called production; write GPFORUM_ENV=production in the environment file in its place.
[warn] GPFORUM_SMTP_SSL is now called GPFORUM_SMTP_TLS; write GPFORUM_SMTP_TLS=off in the environment file in its place.
```

Each line came twice, 0.9 s apart, before the manager started. Doctor
listed the five under `!`, in English and Italian, each with its `Fix:`:
`set GPFORUM_ENV=production in …`, `set GPFORUM_SMTP_TLS=off in …` then
`remove the GPFORUM_SMTP_SSL line from …`, and `remove the … line` for the
three retired ones. That is 5 of the run's `9 things to fix`, and five
edits by hand. `setup --yes --dry-run` on the same file would change only
`GPFORUM_ENV` (friction 6).

## 5. Friction left, ranked (input for iteration 5)

Value to the operator first, then how often they meet it. **S/M/L** is
effort.

1. **A dropped metrics token comes back in a worker started later** (4.2).
   This one widens access. The manager keeps the tokens the service
   started with, and a worker forked while the file cannot be used keeps
   them too. The token review's fix: the manager re-reads on Hypnotoad's
   `wait` event, so new workers inherit the last accepted list. ADR 0124
   §2 says otherwise today. S/M. A defect.
2. **A group-writable file is not followed, and nothing says so** (4.2).
   `secret rotate` and doctor check `& 007` while `MetricsTokens` refuses
   `& 022`. Either say it with the `chmod 0640`, or print the restart. S.
   A defect.
3. **macOS production is 10 commands and two documents** (3). Setup or
   `service print --to` can make the log directory; `brew install nginx
   certbot` can join the packages line; DEPLOYMENT's macOS section should
   show the clone and `sudo /opt/gpforum/bin/gpforum setup`, since
   `gpforum` is not linked before setup. That makes 8. The README could
   then carry macOS production as it carries Debian. M.
4. **`make install-deps-*` ends with `Next: check the host, with
   script/system-preflight`** (`script/bootstrap-deps`,
   `system.next_preflight`). The quick start dropped that step, D9 keeps
   `script/` for maintainers, and the upgrade's first line prints it too.
   It should name `gpforum setup`, or nothing in an upgrade. S. A defect.
5. **The quick start's first command is superfluous** (1). Setup installs
   the dependencies, development tools included, on a checkout without
   `local/`. Three commands: setup, `admin create`, `start --foreground`.
   S.
6. **Old names take five edits by hand** (4.4). Setup already rewrites an
   old `GPFORUM_ENV`. It can rewrite `GPFORUM_SMTP_SSL` and drop the
   retired lines in the same pass, and doctor's fixes can become one
   `gpforum setup`. The start logs each line twice. S/M.
7. **`service print --to` into a directory the operator cannot write
   answers with Perl's error** (3), where it should say to run it with
   `sudo`. S.
8. **`service print nginx --to` before certbot is installed** names only
   the certificate command; the bare print names `brew install nginx
   certbot` first. The refusal should too. S.
9. **The sizing line in development** names 14 web processes for a
   one-process server. S.
10. **`gpforum help secret` names `/etc/gpforum/gpforum.env`** on macOS,
    where the file is Homebrew's. S.
11. **`gpforum upgrade`'s backup line** names `/var/backups/gpforum`, which
    is root's on macOS and missing on a fresh Debian host, with no
    `install -d`. S.
12. **Ten commands from a bare Debian host, eight from the clone.** The
    `cpanm … Carton` line could become Debian's `carton` package on the
    `apt` line, to check on a Debian host. S.
13. **Essentiality of the help.** `gpforum` lists 20 commands.
    `platform-check` and `os-preflight` repeat what doctor's host and open
    files lines check. The units need `os-preflight`, so it can stay
    under `help --all`, out of the first screen. S.
14. **Two rotations at once lose one** (token review, not run here): no
    lock and no check that the file is unchanged before the rename. S.
15. **Not run on a real host, still:** root's setup on Debian and macOS,
    the `postgres` peer login, `systemd-analyze verify`, `nginx -t`,
    certbot with Debian's default site, `launchctl bootstrap` as root, and
    FreeBSD.

## 6. Clean-up

- The three servers, on ports 3000, 3040 and 3041, were stopped, the
  scraper with them, and the ports are free.
- `gpforum_walk4`, `gpforum_walk4p` and the role `walk4` were dropped.
- The scratch clone and its `local/`, both Homebrew prefixes with their
  environment files, links and logs, the printed units and plists, the
  tokens, the password file, the cookie jar and the `expect` and
  simulation scripts were deleted.
- Nothing was installed with brew, no second cluster was started, and
  nothing was written outside the scratch directory.
