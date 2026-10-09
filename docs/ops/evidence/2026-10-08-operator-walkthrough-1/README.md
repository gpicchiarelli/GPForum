# Operator walkthrough, iteration 1 (2026-10-08)

The walk of [iteration 0](../2026-10-07-operator-walkthrough/README.md)
repeated after iteration 1 ("say what to do"), as a sysadmin who has never
seen GPForum. The macOS quick start was **run**; the Debian 13 install was
**walked through its documents and code** without a VM.

- **Tree:** `main` at `1b19794`, cloned into a scratch directory, so nothing
  uncommitted took part.
- **Host:** macOS 27.0.1 on arm64, 10 CPUs, 16 GB, with Homebrew perl 5.44.0
  and postgresql@18 18.6.
- **Database:** the machine's shared PostgreSQL 18 on `127.0.0.1:55433`, in a
  database created for the walk (`gpforum_walk`) and dropped at the end.
- **Mail:** the development default, the `log` transport, with no MTA.
- **Language:** commands ran with `LC_ALL=en_US.UTF-8`, and the messages were
  also triggered with `it_IT.UTF-8`.

Each step is marked **run** (typed here, with what it printed), **traced** (read
in the documents and code it rests on), or **not checkable** (it needs a
Debian host, DNS, a certificate or an MTA).

## 0. Headline

| Measure | Iteration 0 | Iteration 1 | Target (audit 5.4) | Met |
| --- | --- | --- | --- | --- |
| macOS quick start to a signed-in admin, without an MTA | dead end at step 14 | **16 steps**, reached, `/admin` 200 | ~15 steps, no dead end | **yes**, with one gap: `/health/ready` answers 503 until a 17th, undocumented step (2.2) |
| macOS wall time, clone to signed-in admin | — (not run) | **about 5 min 40 s**, 166 s of it the dependency install (Carton and a warm cpanm cache already there) | — | — |
| Debian steps, bare host to an admin behind TLS | 31 | **22** (24 if web, outbox and timers count as separate rows, as in iteration 0) | ≤ 26 | **yes** |
| Debian documents the operator must open | 12 | **2** (README, DEPLOYMENT), plus the environment file template they edit | ≤ 8 | **yes** |
| Debian typed commands | about 60 | **34** | — | — |
| Undocumented Debian steps (user, code and ownership, secrets, units, outbox, certificate) | 6 | **0** | 0 | **yes** |
| Configuration problems per start | 1, named by attribute, exit 255 | **all at once**, each naming its variable, exit 78, English or Italian | all at once, by variable | **yes** (run) |
| 1 vCPU host starts | no (read) | **yes** (traced; t/471) | yes | **yes**, not run on a 1-vCPU host |

All five acceptance targets of iteration 1 are met. The remaining friction is
listed in section 4, ranked, as input for iteration 2.

## 1. macOS with Homebrew: the README quick start, run

These are the commands as typed, in README order.

**Deviations.** Each one exists only to protect the shared machine:

- `brew install` was not re-run, because it would upgrade the owner's
  packages; `brew list --versions` showed all three present.
- `brew services start postgresql@18` was not run, because it would start a
  second cluster.
- `createuser`, `createdb` and `psql` got `-h 127.0.0.1 -p 55433`.
- `GPFORUM_DATABASE_DSN` was exported to point at `gpforum_walk`, which the
  README allows (README.md:112-114).

| # | Command or action (README line) | Result | Time |
| --- | --- | --- | --- |
| 1 | `brew install perl cpanminus postgresql@18` (:91) | not re-run; `cpanminus 1.7049`, `perl 5.44.0`, `postgresql@18 18.6` present | – |
| 2 | `brew services start postgresql@18` (:92) | not run (shared cluster) | – |
| 3 | `export PATH="$(brew --prefix postgresql@18)/bin:$PATH"` (:93) | ok | – |
| 4 | `"$(brew --prefix)/bin/perl" "$(brew --prefix cpanminus)/bin/cpanm" -M https://cpan.metacpan.org/ Carton` (:94) | `Carton is up to date. (v1.0.35)` | 5 s |
| 5 | `make system-perl` (:102) | exit 0. 41 lines; the verdict `ok: system_perl -> …` is followed by the whole `perl -v` and `perl -V` | 0.1 s |
| 6 | `make install-deps-postgres` (:103) | exit 0, `130 distributions installed`, `cpanfile's dependencies are satisfied.` | 166 s |
| 7 | `script/system-preflight` (:104) | exit 0. 52 lines with the same `perl -V` dump, no closing verdict and no next step | 1.6 s |
| 8 | `createuser gpforum` (:105, macOS comment) | literally, with no server on 5432: `createuser: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: No such file or directory`. Against 55433: `role "gpforum" already exists` (expected on a shared cluster) | – |
| 9 | `createdb --owner gpforum gpforum` (:106) | `createdb -h 127.0.0.1 -p 55433 -U gpforum --owner gpforum gpforum_walk`, exit 0 | – |
| 10 | `script/gpforum-carton exec perl -Ilib bin/gpforum-migrate --plan` (:108) | exit 0. It lists all 51 migrations whether or not the database exists: `--plan` never connects, so it cannot say what is pending | 0.4 s |
| 11 | `… bin/gpforum-migrate --apply` (:109) | **without the DSN first** (5432 is empty), exit 1, one sentence:<br>EN `Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused): start it with brew services start postgresql@18, or correct GPFORUM_DATABASE_DSN in your shell's environment.`<br>IT `PostgreSQL non risponde su 127.0.0.1:5432 (connessione rifiutata): avvialo con brew services start postgresql@18, oppure correggi GPFORUM_DATABASE_DSN nell'ambiente della shell.`<br>With the DSN: 51 lines `applied 001 core identity ee9c…`, exit 0. A second `--apply` prints **nothing**; `--check` prints `migrate check status=ok pending=0` | 0.7 s |
| 12 | `script/gpforum-carton exec perl -Ilib bin/gpforum daemon -l http://127.0.0.1:3000` (:126) | `Listening at "http://127.0.0.1:3000"` | 2 s |
| 13 | Register at `/register` (:129) | "Account walkadmin was created. Check your email to verify before signing in." The page does not say that in development the mail is in the outbox worker's output | – |
| 14 | `… bin/gpforum-outbox-dispatch --once` (:134) | exit 0. `Mail not sent (GPFORUM_MAIL_TRANSPORT=log); this is what it says:`, then the To, Subject, body and verification link, then `outbox_dispatch selected=2 dispatched=2 failed=0 dead_lettered=0` | 1 s |
| 15 | Open the link, confirm, sign in (:131-132, :138) | "Your email is verified." Signed in | – |
| 16 | `… bin/gpforum-admin-bootstrap --user-id "$(PGPASSWORD=… psql -h 127.0.0.1 -U gpforum -At gpforum -c "SELECT id FROM users WHERE username = 'you'")"` (:142-144) | **with the README's `'you'` left in place:** the subquery is empty, and the usage is printed **twice**, with no reason, exit 2. With the real username: `admin bootstrap role=gpforum_owner user=01a11bf8-… permissions=14 … created_bindings=1`, exit 0 | 0.5 s |
| – | Open `/admin` | **200** in the browser and through curl. The admin dashboard shows "Health and runtime: **fail**" (see 17) | – |
| 17 | `curl http://127.0.0.1:3000/health/ready` (not in the README) | **HTTP 503, `"status":"fail"`**: `query_budget_drift` fail, 25 endpoints `missing`, runbook `docs/PERFORMANCE.md#query-budgets`. The README quick start never runs `query-budget --sync`; DEPLOYMENT step 6 does. Following the runbook, `script/query-budget --sync` printed `synced 25 endpoint query budgets`, and readiness turned `ok`, HTTP 200. `shared_cache` is `ok` with its note: "No GlifiStore is configured: each process keeps its own cache. That suits a single host; set GPFORUM_GLIFISTORE_URL to share one between hosts." | – |

**Count:** 16 steps to a signed-in admin, at the granularity iteration 0 used
(its 15 rows plus the verification link, which used to be the dead end). That
is 14 typed commands and 3 browser actions. The dead end is gone. One step
outside the README is still needed for a healthy node (17).

**Documents opened:** README.md, then docs/PERFORMANCE.md (the runbook named
by the readiness report). The quick start links docs/ops/mail-check.md only
for real mail, and a reader who opens it is misled: it still says development
defaults to `test` and lists no `log` transport (mail-check.md:31, :40-42,
:85, :91-92).

**Wall time:** clone at 16:39:04, dependencies done 16:42, server listening
16:43:10, `/admin` 200 at about 16:44:45, readiness `ok` at about 16:45:50,
server stopped 16:46:23. A truly fresh account adds the Homebrew installs of
perl and postgresql@18 and a cold cpanm cache.

## 2. Debian 13, production, behind nginx: the documents and the code, walked

I started at README.md, which sends production to
DEPLOYMENT.md#install-on-debian-or-ubuntu. The rows follow iteration 0's
granularity. "Here" says how each step was checked.

For the steps marked *run with the step-5 function*, I wrote the function body
of DEPLOYMENT.md step 5 to a script. I dropped `sudo -u gpforum`, used the
scratch clone and environment file, and cleared the environment with `env -i`.
The environment file was a copy of `deploy/gpforum.env.example` with only the
DSN pointed at the walk's database.

| # | Step | DEPLOYMENT.md | Here | What I saw or found |
| --- | --- | --- | --- | --- |
| 1 | Host packages, one line with nginx, certbot and ClamAV | step 1 | not checkable | Complete. A reader who began with README's Requirements has already run a shorter `apt install`; this one is a superset |
| 2 | Carton | step 1 | traced | `sudo cpanm` puts it in `/usr/local/bin`. `gpforum-carton` finds it with `perl -S carton` (gpforum-carton:88) |
| 3 | Service user | step 2 | traced | **Now documented**: `useradd --system --user-group --home-dir /opt/gpforum --shell /usr/sbin/nologin gpforum` |
| 4 | Code location and ownership | step 2 | traced | **Now documented**: the code is root's, `var/attachments` is `gpforum` 0750, and the pid file goes to `/run/gpforum` (unit `RuntimeDirectory=`, `PIDFile=`) |
| 5 | Install dependencies | step 2 | run (develop variant, macOS) | `sudo make install-deps-production`, one target. The perl shim is made at install (4e0387d) |
| 6 | Database role | step 3 | traced | `sudo -u postgres createuser --pwprompt gpforum`. The only extension, `pg_trgm`, is trusted, so the owner role migrates |
| 7 | Database | step 3 | run (55433) | |
| 8 | Environment file in place | step 4 | traced | **Template shipped**, installed 0640 root:gpforum |
| 9 | Fill it in, with secrets | step 4 | run with the step-5 function | **Now documented**: `openssl rand -hex 32`. The template left as copied: exit 78, both missing secrets in one report (EN and IT quoted in 3.1). The `forum.example.com` placeholders in `GPFORUM_PUBLIC_BASE_URL` and `GPFORUM_MAIL_FROM` are **accepted** in production |
| 10 | Commands as the service runs them | step 5 | run (body only) | One shell function. `gpforum migrate --check`, `query-budget --check`, `mail-check --dry-run --human`, `platform-check --with-db` and `os-preflight` all resolved and ran in production mode |
| 11 | Migrate | step 6 | run with the step-5 function | `migrate --apply` exits 0 and prints **nothing** when current |
| 12 | Query budgets | step 6 | run | `ok endpoint query budgets aligned` |
| 13 | Mail: MTA and probe | step 7 | MTA not checkable; probe run | `apt install postfix` with "Internet Site" is documented. Nothing says a VPS often cannot send on port 25 or needs SPF/PTR to be accepted. Here `mail-check --dry-run --human` printed `status=pass … probe_detail=sendmail available at /usr/sbin/sendmail`. It passes on macOS, whose postfix relays nowhere: the probe proves a binary exists, not delivery |
| 14 | Antivirus | step 8 | not checkable; the check run without clamd | `echo 'StreamMaxLength 26M' \| sudo tee -a` appends to a clamd.conf that, on Debian, already carries a generated `StreamMaxLength` line: confirm on a VM which one wins. clamav-daemon does not start until freshclam has fetched signatures. Without clamd, `antivirus-check` prints 8 lines repeating `cannot connect to clamd at …/clamd.sock: No such file or directory`, exit 1, with no "install clamd, or set `GPFORUM_ANTIVIRUS=none`" |
| 15 | Install units, daemon-reload | step 9 | traced | **Now documented**, outbox included. The units set only `GPFORUM_ENV` and the log path |
| 16 | Start web, outbox and timers | step 9 | traced; 1 vCPU by t/471 | `--strict` fails only on `fail`. On 1 CPU `cap-to-cpu` gives Hypnotoad 2 and the check counts those. A config error makes `os-preflight --strict --json` exit 1 and write the report **three times** to the journal: as text on stderr, then inside the JSON as `error` and again as `explanation` (run here with `GPFORUM_ENV=prod`) |
| 17 | TLS certificate | step 10 | not checkable | **Now documented**: `certbot certonly --nginx -d "$site"`, renewed by certbot's timer |
| 18 | nginx site | step 10 | traced | `sed` substitutes the host. Upstream `127.0.0.1:8080` is the default listen, `client_max_body_size 26m`, and `/metrics/?` is loopback only |
| 19 | Health | step 10 | run (development) | `curl -sS "https://$site/health/ready"`. Here 503 `fail` until the budgets were synced (macOS 17); on Debian, step 6 syncs them first |
| 20 | Register | step 11 | run (macOS) | |
| 21 | Verify | step 11 | run with the `log` transport; on Debian it needs step 13 | |
| 22 | First admin | step 11 | run (macOS) | Still psql for the UUID. The placeholder `'you'` left in place prints the usage twice, exit 2, with no reason |

**Count:** 22 steps, 34 typed commands (`site=` 1, step 1: 2, 2: 5, 3: 2, 4:
3 plus 2 `openssl`, 5: 1, 6: 2, 7: 2, 8: 3, 9: 4, 10: 6, 11: 1). There are
**2 documents**, README and DEPLOYMENT, and the environment file template
edited in step 4. Links followed only for detail: ops/antivirus.md and the
CHANGELOG for upgrades.

**Of iteration 0's 31 rows:**

- Gone or folded:
  - row 7, system-preflight, which is no longer in the production path;
  - row 11, GlifiStore, now optional;
  - row 18, `LimitNOFILE`;
  - row 23, attachment offload, now documented as an option under Reverse
    Proxy;
  - row 24, Caddy;
  - row 25, `PUBLIC_BASE_URL`, now validated for scheme and https;
  - row 31, staging-host-verify.
- Fixed in place:
  - row 3, the service user;
  - row 4, the code location;
  - row 6, one install target;
  - row 8, `sudo -u postgres` and `--pwprompt`;
  - row 10, the secrets;
  - row 14, the shell function;
  - row 15, the database sentences;
  - row 17, installing the units;
  - row 19, 1 vCPU;
  - row 20, the outbox;
  - the certificate in row 22, and its 26m body size.

## 3. Messages met, quoted

### 3.1 Configuration (run)

The template copied as is, with `GPFORUM_ENV=production`, through
`bin/gpforum`. Exit 78:

```text
GPForum's settings need attention:

  GPFORUM_SESSION_SECRET is required in production.
    Generate one with: openssl rand -hex 32

  GPFORUM_METRICS_TOKEN is required in production.
    Generate one with: openssl rand -hex 32

Set these in the service's environment file (deploy/gpforum.env.example describes every setting), then try again.
```

```text
Le impostazioni di GPForum vanno sistemate:

  GPFORUM_SESSION_SECRET è obbligatoria in production.
    Generane uno con: openssl rand -hex 32

  GPFORUM_METRICS_TOKEN è obbligatoria in production.
    Generane uno con: openssl rand -hex 32

Impostale nel file d'ambiente del servizio (deploy/gpforum.env.example descrive ogni impostazione), poi riprova.
```

The closing line names the template, not the file the service actually reads.
The database sentences do name it (`/etc/gpforum/gpforum.env`).

`GPFORUM_ENV=prod` under `hypnotoad -t` exits 255, with Mojolicious's prefix
in front of the report:
`Can't load application from file ".../bin/gpforum": GPForum's settings need
attention: … GPFORUM_ENV must be one of development, test, staging,
production, production-small, production-medium, not 'prod'. Did you mean
GPFORUM_ENV=production?`

### 3.2 Commands (run)

- **Database unreachable:** the two sentences quoted in 1, step 11.
- **admin-bootstrap with an empty id:** shown twice, exit 2:

  ```text
  Usage: bin/gpforum-admin-bootstrap --user-id USER_ID [--actor-user-id USER_ID] [--role-name ROLE]
  ```

  It still names `bin/gpforum-admin-bootstrap` when typed as
  `gpforum admin-bootstrap`.
- **os-preflight, human form:** `key=value` lines. They still report the
  retired settings: `runtime web_processes=14 worker_processes=2
  realtime_processes=1` and `feature=affinity setting=off enabled=0`.
- **`bin/gpforum --help`:** still Mojolicious's banner, `Usage: APPLICATION
  COMMAND [OPTIONS]`, with `mojo generate lite-app`, `-m, --mode` and
  `cgi`/`eval`/`get` among GPForum's commands.

## 4. Friction left, ranked (input for iteration 2)

Value to a new operator first, then how often they meet it. **S/M** is effort.
The tag says where the fix belongs.

1. **The README quick start leaves the node `fail`.** `/health/ready` answers
   503 and the admin dashboard shows "Health and runtime: fail" until
   `query-budget --sync`, which the README never runs. Add the step now, or
   make `migrate --apply` sync the budgets (B5). S. Docs, then B5.
2. **The first admin still needs psql and a UUID.** Forgetting to replace
   `'you'` gives the usage twice with no reason and exit 2. Fix with A9,
   `gpforum admin create`, and with misuse that says what was wrong (B6). M.
3. **No front door.** The README types `script/gpforum-carton exec perl -Ilib
   bin/gpforum-…` five times. Debian needs a shell function with `set -a; .
   /etc/gpforum/gpforum.env`. Fix with B1. M.
4. **The template's placeholders pass production validation.**
   `https://forum.example.com` and `forum@forum.example.com`, left as copied,
   start a forum whose every mail links to example.com. Refuse the
   `example.com`/`example.org`/`.invalid` hosts in staging and production, as
   `@localhost` already is (A2 follow-up). S.
5. **Mail delivery is proven by a binary's presence.** `mail-check --dry-run`
   says `pass` for `sendmail` on a host whose MTA relays nowhere (macOS, a VPS
   with port 25 blocked). DEPLOYMENT step 7 does not say that a VPS usually
   needs `smtp` through a provider, or SPF/PTR. Fix with B3 (`doctor`) and a
   docs sentence. S.
6. **No `doctor`, no `status`.** The full readiness report still needs curl,
   the token and jq. A config error reaches the journal three times (stderr,
   JSON `error`, JSON `explanation`); under Hypnotoad it exits 255 with
   Mojolicious's prefix. Fix with B3 and B4, and with B1 checking before
   Hypnotoad. M.
7. **`migrate` speaks the wrong amount.** `--apply` prints 51 hash lines the
   first time and nothing when current. `--plan` lists every migration
   without connecting, so it cannot say what is pending. Fix with B5. S.
8. **The setup tools bury their verdict.** `make system-perl` (41 lines) and
   `script/system-preflight` (52 lines) dump `perl -V` and end without a
   verdict or a next step. `system-preflight --help` runs the whole check, and
   it still fails on a `--production` install over perlcritic. Fix with B6. S.
9. **`antivirus-check` without clamd** repeats one connect error 8 times and
   names no fix: "install clamav-daemon (apt) / clamav (brew), or set
   `GPFORUM_ANTIVIRUS=none`". The Debian step appends `StreamMaxLength`
   after the package's own line, and clamd waits for freshclam's first
   download. Both need checking on a VM. S.
10. **The config report's last line names the template, not the file read**
    (`/etc/gpforum/gpforum.env`, the FreeBSD path, the launchd plist, or the
    shell in development). The database sentences already know which. S.
11. **The front door's help is Mojolicious's** (`mojo generate lite-app`,
    `-m`, cgi/psgi/eval/get), and usage lines name `bin/gpforum-X` even when
    typed as `gpforum X`. Fix with B2 and B6. S.
12. **Retired settings still show in `os-preflight`'s output**
    (`worker_processes`, `realtime_processes`, `feature=affinity`), and
    `--human` prints `key=value`. S.
13. **Docs drift after iteration 1.**
    - docs/ops/mail-check.md still says development defaults to `test` and
      lists no `log` transport.
    - README "How it is built" still calls GlifiStore the shared cache "in
      staging and production".
    - DEPLOYMENT's Linux section still offers `GPFORUM_CARTON`, an odd
      variable no Debian step needs.
    - staging-host.md's list of required settings leaves out
      `GPFORUM_PUBLIC_BASE_URL` and `GPFORUM_MAIL_FROM`.

    S.
14. **The development sign-up page doesn't say where the mail went** ("Check
    your email"). One line pointing to the outbox worker's output would do.
    S. Frontend, the owner's.
15. **Upgrade is one sentence**, and "copy the units when the CHANGELOG says
    so" is left to the operator. Fix with C4 and `doctor --upgrade`. S.
16. **Carried from the iteration-1 reviews** (not re-run here):
    - production-medium fails readiness out of the box (cache floor 4096
      against a default of 2048);
    - `gpforum-unix-socket.service`'s `%2F` is probably eaten by systemd;
    - staging-host-verify checks only 4 keys;
    - `GPFORUM_MAIL_TRANSPORT=test` is allowed in production;
    - the `log` transport writes at `info`, so `GPFORUM_LOG_LEVEL=warn` hides
      the link;
    - `GPFORUM_FORUM_READ_RATE_LIMIT` is still outside the settings table;
    - launchd plists run as root and carry no environment file;
    - the not-migrated sentence suggests the long `script/gpforum-carton exec`
      form;
    - a password with `$`, quotes or spaces reads differently under systemd
      than under the `sh` function;
    - `GPFORUM_SMTP_SSL` defaults to plaintext on 587 (D3', iteration 3);
    - the settings page restarts `gpforum` only, not `gpforum-outbox`
      (frontend);
    - `os-preflight --strict` lines are English only.

## 5. Clean-up

The scratch clone and its `local/` were deleted. `gpforum_walk` was dropped:
`pg_database` has no such row. The server on port 3000 was stopped and the
browser tab closed. The throwaway account lived only in the dropped database.
The environment file copy and the logs lived only in the scratch directory and
were deleted.
