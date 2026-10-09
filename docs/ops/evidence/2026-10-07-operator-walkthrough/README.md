# Operator walkthrough, iteration 0 (2026-10-07)

The baseline for the operator-ergonomics iterations: a read-only walk through
a fresh install as a sysadmin who has never seen GPForum, with every setting,
entry point and message inventoried. Each later iteration repeats the walk and
records its numbers beside these.

## Owner decisions on this audit (2026-10-07)

- GlifiStore is optional in production (D2).
- `gpforum admin create` makes an active, verified owner without e-mail, and a
  `log` mail transport is the development default (D6, D7).
- Command-line messages follow `LANG` (Italian or English), like the forum
  (D13).
- Every other recommendation in section 5.5 is approved as written.

# GPForum operator ergonomics audit (iteration 0 baseline)

Date: 2026-10-07. Tree: `main` at `d9a688d` plus the uncommitted work in the
status snapshot. Method: I read README.md, docs/DEPLOYMENT.md and every runbook
they link. I read `lib/GPForum/Config.pm`, `bin/`, `script/`, `deploy/` and the
command layer, and ran `--help` on all 27 `bin/` entrypoints, with
`LC_ALL=en_US.UTF-8` through `script/gpforum-carton exec`. To check the startup
messages I also started `bin/gpforum version` with broken settings. That run
used no database and no server. Messages quoted below are what those runs
printed. Anything I worked out from the code without running it is marked
*(read, not run)*.

---

## 0. Headline

| Measure | Today |
| --- | --- |
| Steps from a bare Debian 13 host to a forum with an admin behind TLS | **31** (section 1.1), about 60 typed commands |
| Documents the operator must open to finish those steps | **12** (19 counting day-2 operations) |
| Environment variables read anywhere | **68** in `Config.pm` + **27** outside it = **95** |
| Of those, what a production operator must set by hand | 7 (`SESSION_SECRET`, `METRICS_TOKEN`, `GLIFISTORE_URL`, `DATABASE_DSN`/`USER`/`PASSWORD`, `PUBLIC_BASE_URL`), plus mail and antivirus settings in practice |
| Operator-facing entry points | 27 `bin/`, 50 `script/`, 33 `make` targets, 33 `bin/gpforum` subcommands (8 of them Mojolicious own) |
| Config errors reported per start | **1** (the first one only; the operator restarts 3 times to learn 3 missing secrets) |
| Config messages that name the variable to set | 6 of the 15 I triggered |

The ten problems that hurt most, roughly in this order:

1. **There is no route to a working first admin on a laptop.** Signing in
   needs a verified email (README.md:125-127). The development transport
   `test` throws the message away (Mailer.pm:146-147). macOS `sendmail` relays
   nowhere by default, and raw tokens are never stored (PRODUCT_FLOWS.md:16).
   The README quick start (README.md:119-141) is a dead end without a working
   MTA.
2. **Production requires a component nobody can install.**
   `GPFORUM_GLIFISTORE_URL` is required (Config.pm:452-457, :787-789), but
   "There is no installable GlifiStore binary or CPAN distribution in this
   project" (DEPLOYMENT.md:446-447). The client is loaded lazily
   (SharedCache.pm:283-286), so any URL satisfies the check and the node runs
   degraded. The requirement adds a step and buys nothing.
3. **The shipped units probably refuse to start on a 1-vCPU VPS** *(read, not
   run)*. `ExecStartPre=os-preflight --strict` (gpforum.service:47) fails on
   any `degraded`. With one CPU, `recommended_worker_count` is 1, below
   `GPFORUM_OS_MIN_RECOMMENDED_WORKERS=2` (OS/Base.pm:80-85,
   OS/Preflight.pm:229-231). The default `GPFORUM_WEB_PROCESSES=4` is also
   above 1×2 (OS/Preflight.pm:234-238). DEPLOYMENT.md:34-35 itself says
   `--strict` is for "once limits and worker counts have been tuned".
4. **The required outbox worker is never enabled by the deployment guide.**
   DEPLOYMENT.md:16 calls it the "required worker", but the Linux section
   (DEPLOYMENT.md:179-251) never names `deploy/systemd/gpforum-outbox.service`.
   FreeBSD and launchd ship no outbox service at all (deploy/freebsd/,
   deploy/launchd/). Without it no verification, reset or notification mail
   ever leaves.
5. **Config errors use internal attribute names, not the variable to set,**
   one per start, without a trailing newline, and exit 255:
   `glifistore_url is required`, `mail_transport must be test, smtp, or
   sendmail`, `minion_pg_url is required` (Config.pm:723, :735). A friendlier
   message for the Minion case exists in Bootstrap/Workers.pm:194-196 but is
   never reached, because Config validates first.
6. **Every command run by hand must recreate the service's environment.** The
   documented form is `sudo -u gpforum sh -c 'set -a; . /etc/gpforum/gpforum.env;
   GPFORUM_ENV=production exec /opt/gpforum/script/antivirus-check'`
   (DEPLOYMENT.md:75, antivirus.md:85). Forget it and `migrate` connects with
   the development defaults and no password, then prints a raw
   `DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed: ...`.
7. **No env file template, no secret generator, no user/layout step.** The
   keys are in prose (DEPLOYMENT.md:196-201, staging-host.md:40-47). The
   `gpforum` user, `/opt/gpforum` and file ownership appear only implicitly
   through the units (gpforum.service:8-10, :75). No document says how to make
   a secret.
8. **Three ways to name the mode, two of them dead or unchecked.** Units set
   `MOJO_MODE=production` (gpforum.service:11), which Bootstrap/Core.pm:27
   overwrites with `GPFORUM_ENV`. `bin/gpforum --help` still offers
   `-m, --mode` from Mojolicious. `GPFORUM_ENV` accepts any string: `prod`
   starts silently with the development secret and non-Secure cookies
   (Config.pm:88-93 has only `required`; Config.pm:808-810).
9. **Twenty-three `Environment=` lines in each unit restate the defaults**
   (gpforum.service:18-40, gpforum-unix-socket.service:18-40, and the launchd
   plist:20-65). Change a default in Config.pm and the units silently keep the
   old value.
10. **Upgrade, metrics-token rotation and routine backup have no procedure.**
    Upgrade is spread over DEPLOYMENT.md:37-47, :144, :204-206 and
    reload-and-restart.md:31-37. Token rotation is one clause
    (DEPLOYMENT.md:351-353). backup-and-restore.md covers PITR set-up, not a
    nightly "what do I run".

What is already good and should be kept: one exit-code contract (0/1/2) and
`--json` with a `status` on almost every command (Command/Usage.pm:22-31,
:147-163). DSN passwords are redacted in failures (Usage.pm:171-182). Every
readiness check carries a runbook link (Readiness.pm:44-61). There is already
a front door: `bin/gpforum` exposes every command as a subcommand
(GPForum.pm:38, lib/GPForum/CLI/*). `DeployContract` can compare installed
units with the templates. The FreeBSD rc script checks the env file's mode and
owner and says how to fix it (deploy/freebsd/gpforum:42-60). The bar is
already high in places; the job is to make all of it that good.

---

## 1. Walkthrough: a sysadmin who has never seen GPForum

### 1.1 Debian 13, production, behind nginx

The operator starts at README.md and follows its link to docs/DEPLOYMENT.md.
"Doc" is where they must read to get past the step.

| # | Step | What they must know or type | What goes wrong | What they see | Doc |
| --- | --- | --- | --- | --- | --- |
| 1 | Host packages | `sudo apt install perl build-essential cpanminus libpq-dev postgresql postgresql-client` (README.md:77) | No MTA or ClamAV in the list; both are needed later (steps 12 and 13) | nothing yet | README |
| 2 | Carton | `sudo cpanm -M https://cpan.metacpan.org/ Carton` (README.md:78) | none | | README |
| 3 | Service user | **undocumented for Linux.** The units say `User=gpforum` (gpforum.service:8). Only the FreeBSD section says "run as a dedicated `gpforum` user" (DEPLOYMENT.md:265) | Unit fails to start | systemd's own `status=217/USER` | (none) |
| 4 | Code location | **undocumented.** Implied by `WorkingDirectory=/opt/gpforum` (gpforum.service:10) and "`/opt/gpforum/assets` after install" (DEPLOYMENT.md:323). Ownership unspecified; the service writes into the code tree (`ReadWritePaths=/opt/gpforum`, gpforum.service:75; pid file and `var/attachments`) | A code tree the service can rewrite, or a pid file it cannot write | Hypnotoad's error in `/var/log/gpforum/gpforum.log` | (none) |
| 5 | Check Perl | `make system-perl` (README.md:102) | none, but it prints 40 lines of `perl -v` and `perl -V` (gpforum-system-perl:189-190) | `ok: system_perl -> /usr/bin/perl` buried in the dump | README |
| 6 | Install deps | README says `make install-deps-postgres` (README.md:103). DEPLOYMENT.md:144 says `make install-deps-production`. DEPLOYMENT.md:190-191 says `install-deps-postgres` again for systemd hosts | Picks the wrong one: develop tools on production, or step 7 fails | | README, DEPLOYMENT |
| 7 | Check host | `script/system-preflight` (README.md:104). It runs **after** the install whose prerequisites (pg_config) it checks | On a `--production` install it fails: perlcritic is a develop dependency (system-preflight:63-69). `--help` is ignored and the full check runs | `missing: perlcritic (a develop dependency: script/bootstrap-deps without --production)`, exit 1 | README |
| 8 | DB role and DB | `sudo -u postgres createuser --pwprompt gpforum`, `sudo -u postgres createdb --owner gpforum gpforum`. The code block (README.md:105-106) shows neither `sudo -u postgres` nor `--pwprompt`; they are in the prose after it (README.md:113-115). "Migrations use a separate role" (DEPLOYMENT.md:465) has no mechanism | Without a password the app's TCP connection (default `host=127.0.0.1`, Config.pm:152) fails scram auth | raw DBI text, see step 15 | README, DEPLOYMENT |
| 9 | Env file | Create `/etc/gpforum/gpforum.env`, mode 0640 root:gpforum. No template ships (no `*.env*` file in the tree). The keys are listed in prose (DEPLOYMENT.md:196-201); mode and owner are only in staging-host.md:40 | Missing keys found one start at a time (section 4) | `glifistore_url is required`, then `production requires GPFORUM_SESSION_SECRET`, then `production requires GPFORUM_METRICS_TOKEN` | DEPLOYMENT, staging-host |
| 10 | Secrets | Invent `GPFORUM_SESSION_SECRET` and `GPFORUM_METRICS_TOKEN`. No generator, no stated length; `abc` is accepted (Config.pm:576-579 only rejects the development default) | Weak secret accepted silently | nothing | (none) |
| 11 | GlifiStore | Run a GlifiStore server, install `GlifiStore::Client` "onto the same Perl that owns `local/`", set the URL (DEPLOYMENT.md:449-455). Neither is obtainable (DEPLOYMENT.md:436-447) | They set any URL to get past validation; the node runs degraded forever (readiness `shared_cache` → `local-fallback`) | `glifistore_url is required` until they do | DEPLOYMENT |
| 12 | Mail | Production defaults to `sendmail` (Config.pm:471). No document says to install an MTA. For SMTP: 5 variables; `GPFORUM_SMTP_SSL=1` means STARTTLS (Mailer.pm:154-155), the default is 0, so port 587 sends credentials in plaintext unless they guess | Mail silently stuck in the outbox, or dead letters | `script/mail-check --human --dry-run` says whether sendmail exists | DEPLOYMENT, mail-check.md |
| 13 | Antivirus | `apt install clamav-daemon clamav-freshclam`; set `StreamMaxLength 26M` in clamd.conf; give the `gpforum` user access to the socket. Then prove it with the incantation in DEPLOYMENT.md:75 | Socket permission | `Permission denied` (antivirus.md:73-76) | DEPLOYMENT, antivirus.md |
| 14 | Environment for manual commands | Every manual command must run as `gpforum` with the env file sourced and `GPFORUM_ENV=production` (DEPLOYMENT.md:75) | They run as root without sourcing it: development defaults, no DB password | see step 15 | DEPLOYMENT |
| 15 | Migrate | Two documented spellings: `script/gpforum-carton exec perl -Ilib bin/gpforum-migrate --apply` (README.md:108) and `script/gpforum-carton exec bin/gpforum-migrate --apply` (staging-host.md:53). The `-Ilib` is redundant (bin/gpforum-migrate:10). Creating partitions needs the owner role; "give the unit an EnvironmentFile with the migration role's DSN" (DEPLOYMENT.md:247-251) | DB down, auth failure, wrong role | `DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed: DBI connect('dbname=gpforum;host=127.0.0.1;port=5432','gpforum',...) failed: connection to server at "127.0.0.1", port 5432 failed: Connection refused` — names neither `GPFORUM_DATABASE_DSN` nor a fix. A second `--apply` prints **nothing** (Migrate.pm:196-198) | README, staging-host, partition-maintenance.md |
| 16 | Query budgets | `script/query-budget --sync` then `--check` (DEPLOYMENT.md:205-206). staging-host.md:54 wraps the wrapper in a wrapper: `script/gpforum-carton exec script/query-budget --sync` | Forgotten: `/health/ready` degrades `query_budget_drift` | runbook `docs/PERFORMANCE.md#query-budgets` | DEPLOYMENT |
| 17 | Install units | "Example: deploy/systemd/gpforum.service" (DEPLOYMENT.md:183-186). Copy, `daemon-reload` and `enable` are never spelled out | | | DEPLOYMENT |
| 18 | `LimitNOFILE` | "set `LimitNOFILE=65536`" (DEPLOYMENT.md:203), already in the unit (gpforum.service:70) | A redundant instruction | | DEPLOYMENT |
| 19 | Start web | `systemctl enable --now gpforum` | On 1 vCPU `os-preflight --strict` fails *(read, not run)*; the reason is inside a JSON blob in the journal | e.g. `"configured web processes exceed CPU-based conservative limit"` (OS/Preflight.pm:236-237), status `degraded`, exit 1 | OS_RUNTIME_ENFORCEMENT.md |
| 20 | Start outbox worker | **not in DEPLOYMENT.md.** Only staging-host.md:58 says "Enable and start `gpforum` + `gpforum-outbox`" | Verification mail never sent | nothing; mail just never arrives | staging-host |
| 21 | Timers | `systemctl enable --now gpforum-scheduled-jobs.timer` and `gpforum-partition-maintenance.timer` (DEPLOYMENT.md:220, :239); the partition one needs the owner role (DEPLOYMENT.md:247-251) | Partition run exits 1 on permissions | `docs/ops/partition-maintenance.md` | DEPLOYMENT, scheduled-jobs.md, partition-maintenance.md |
| 22 | nginx | Copy deploy/nginx/gpforum.conf; edit `server_name` twice (:25, :40) and the cert paths (:44-45). Get a certificate: certbot is never described | `client_max_body_size 20m` (:57) is below the app's 25 MiB limit (Attachment/Validator.pm:25, README.md:38): uploads of 20-25 MiB get nginx's 413 | nginx's 413 page | DEPLOYMENT |
| 23 | Attachment offload | The alias `/srv/gpforum/attachments/` (nginx:112) must match `GPFORUM_ATTACHMENT_ROOT` (default `var/attachments`, Config.pm:104), and `GPFORUM_ATTACHMENT_ACCEL_REDIRECT` must be set to use it. DEPLOYMENT.md:332-333 says X-Accel-Redirect is not implemented; it is (Controller/Attachments/Base.pm:166-176). The variable appears in no deployment doc | Three settings to align by hand; the doc says not to bother | | DEPLOYMENT (stale) |
| 24 | (Caddy instead) | Simpler, with automatic TLS, but `/metrics` is not restricted to loopback (Caddyfile:57-59), unlike nginx (:115-117) | Inconsistent exposure | | DEPLOYMENT |
| 25 | `PUBLIC_BASE_URL` | Must match `server_name` and use `https://`. Not validated: `forum.example.com` without a scheme is accepted | Broken links in every mail | nothing | DEPLOYMENT |
| 26 | Health | `curl -sS -H "X-GPForum-Metrics-Token: $GPFORUM_METRICS_TOKEN" http://127.0.0.1:8080/health/ready \| jq ...` (DEPLOYMENT.md:356-357) | Token not in the shell; jq not installed | `{"check":"ready","status":"degraded"}` without the token | DEPLOYMENT |
| 27 | Register | Open the site, register | | "verify your email" | |
| 28 | Verify | Wait for the outbox worker and the MTA (steps 12 and 20) | Mail lost | nothing | mail-check.md |
| 29 | Find own user id | `psql -At gpforum -c "SELECT id FROM users WHERE username = 'you'"` (README.md:140). On Debian as root this fails peer auth; it needs `sudo -u postgres psql` | SQL knowledge required | psql's error | README |
| 30 | First admin | `bin/gpforum-admin-bootstrap --user-id <uuid>` (README.md:139-141) | DB failure is reported as **misuse**: exit 2, usage printed twice (AdminBootstrap.pm:38-41) | raw DBI text, then `Usage: bin/gpforum-admin-bootstrap --user-id USER_ID ...` | README |
| 31 | Verify host (optional) | `script/staging-host-verify --json --env-file ... --unit-dir ... --nginx-conf ... --systemd --base-url ... --metrics-token ...` (staging-host.md:73-80) | Its required keys (StagingHostVerify.pm:38-43) leave out `GPFORUM_GLIFISTORE_URL`, which production requires, so verify says pass and the app refuses to start | | staging-host |

**Count: 31 steps, about 60 commands or edits, 12 documents**: README,
DEPLOYMENT, staging-host, mail-check, antivirus, scheduled-jobs,
partition-maintenance, OS_RUNTIME_ENFORCEMENT, PERFORMANCE,
operational-profiles, reload-and-restart, console-and-cli. Six steps (3, 4,
10, 17, 20 and the certificate in 22) are not documented at all.

### 1.2 macOS with Homebrew

**Local use (README quick start):**

| # | Step | Notes, with what goes wrong |
| --- | --- | --- |
| 1 | `brew install perl cpanminus postgresql@18` (README.md:91) | |
| 2 | `brew services start postgresql@18` | |
| 3 | `export PATH="$(brew --prefix postgresql@18)/bin:$PATH"` (README.md:93) | DEPLOYMENT.md:128 says `eval "$(script/gpforum-homebrew-env)"` instead: two ways to do one thing |
| 4 | Install Carton with the long command in README.md:94 | |
| 5-7 | `make system-perl`, `make install-deps-postgres`, `script/system-preflight` | After `brew upgrade perl`, `local/` must be rebuilt (DEPLOYMENT.md:134-136) |
| 8-9 | `createuser gpforum`, `createdb --owner gpforum gpforum` | Works: Homebrew uses trust auth |
| 10-11 | migrate `--plan`, `--apply` | |
| 12 | `script/gpforum-carton exec perl -Ilib bin/gpforum daemon -l http://127.0.0.1:3000` | `/health/ready` is degraded at once: development **defaults** to a GlifiStore at `tcp://127.0.0.1:7379` (Config.pm:17, :454), so the cache that production may leave unset is assumed on a laptop |
| 13 | Register | |
| 14 | `GPFORUM_MAIL_TRANSPORT=sendmail ... gpforum-outbox-dispatch --once` (README.md:132) | **Dead end.** macOS postfix delivers nowhere by default. The `test` transport discards. Tokens are hashed. The account cannot be verified, so nobody can sign in |
| 15 | admin-bootstrap with the psql UUID | Bootstrap does not activate a pending account (PRODUCT_FLOWS.md:15: "Pending members do not receive a session until email verification") |

**As a service (launchd):** `deploy/launchd/com.gpforum.app.plist` has no
`UserName` key, so it runs as root when installed as a LaunchDaemon. It has no
env-file mechanism, so `GPFORUM_ENV=production` (:12-13) plus the secrets must
go into the plist itself. Its log path is `/usr/local/var/log/gpforum/`
(:19), which is the Intel Homebrew prefix, and nothing creates the directory:
`unable to open the configured log path: /usr/local/var/log/gpforum/gpforum.log`
(Log.pm:42-44). There is no outbox plist. There is no preflight. DEPLOYMENT.md
gives launchd 10 lines (286-303).

**Count:** 15 steps to a dead end for local use, 4 documents (README,
DEPLOYMENT, mail-check, staging-drills for a home-directory cluster). A
launchd service is not reachable from the docs without writing a plist and a
wrapper by hand.

### 1.3 Day-2 operations

| Operation | What exists | Steps | Gaps (file:line) |
| --- | --- | --- | --- |
| Check health | `/health/ready` with token, `/admin/status`, `bin/gpforum-platform-check --with-db` | 1 (needs token and jq) | platform-check `--with-db` aborts on a DB error instead of reporting the DB as a failed check (PlatformCheck.pm:178-186, raw DBI text, exit 1); it adds only `query_budget_drift`. There is no CLI view of the readiness report |
| Upgrade | Nothing in one place | ~7: `git pull`; re-copy units if they changed (DEPLOYMENT.md:44-47); `script/bootstrap-deps --postgres --production`; `migrate --apply` as the owner role; `query-budget --sync`; `systemctl restart gpforum gpforum-outbox` (reload is unsupported, reload-and-restart.md:31-37); check health | No upgrade runbook. Nothing tells an operator their installed units drifted, although `DeployContract` can |
| Back up | backup-and-restore.md: `postgresql.conf` archive settings, `pg_basebackup`, attachments "on its own schedule" | ~5 PostgreSQL edits plus cron jobs the operator writes | No routine logical backup command; the attachment root is easy to forget (backup-and-restore.md:22-29) |
| Restore | 7 numbered steps (backup-and-restore.md:58-75) | 7 | Good; ends with `migrate --check`. Nothing says to restart and re-check health |
| Rotate metrics token | One clause (DEPLOYMENT.md:351-353), Config POD (Config.pm:874-880) | ~5 implied: move the token to `GPFORUM_METRICS_TOKENS`, set the new one, restart, update scrapers, remove the old one, restart | No procedure. The names `METRICS_TOKEN` and `METRICS_TOKENS` differ by one letter |
| Rotate session secret | DEPLOYMENT.md:193-194 | Same shape | Same `SECRET`/`SECRETS` trap |
| Fail over | standby-and-failover.md:163-179, manual by design | 4 | Good. Depends on a multi-host DSN the operator writes by hand (standby-and-failover.md:75-77) |
| Rehearse | `make pitr-drill`, `make standby-drill`, `script/staging-drill` | 1 each | Good |

---

## 2. Inventory of settings

### 2.1 The 68 settings in `Config.pm` (lib/GPForum/Config.pm:87-528)

Key: **Need**: **O** = an operator must decide; **o** = an operator sometimes
tunes; **i** = internal or tuning with a safe default; **d** = derivable.
**Prod**: whether staging and production refuse to start without it.

| Variable (Config.pm line) | Default | Need | Prod | Notes |
| --- | --- | --- | --- | --- |
| `GPFORUM_ENV` (:90) | `development` | O | – | Accepts any string (`required` only). Valid values are scattered over Config.pm:33-38 and Profile.pm:14-21 (6 names). `prod` is accepted and runs insecurely. Never explained in README or DEPLOYMENT |
| `GPFORUM_LOG_LEVEL` (:96) | `info` | o | – | Not validated: `verbose` gives `Use of uninitialized value within %LEVEL in numeric ge (>=) at .../Mojo/Log.pm line 75.` and logs at debug |
| `GPFORUM_LOG_PATH` (:100) | `''` (stderr) | d | – | Set in every unit (gpforum.service:17). Could be derived from the supervisor (journal) |
| `GPFORUM_ATTACHMENT_ROOT` (:103) | `var/attachments` | o | – | Relative to the code tree. Must equal the nginx alias (nginx:112) |
| `GPFORUM_ATTACHMENT_ACCEL_REDIRECT` (:108) | `''` | d | – | Undocumented for operators; the doc says the feature does not exist (DEPLOYMENT.md:332-333) |
| `GPFORUM_DEFAULT_LOCALE` (:113) | `en` | o | – | Not validated: `fr` is accepted |
| `GPFORUM_DEFAULT_THEME` (:119) | `auto` | o | – | One of 4; fine |
| `GPFORUM_DEFAULT_TIMEZONE` (:128) | `UTC` | o | – | Good message (example "Europe/Rome") |
| `GPFORUM_PUBLIC_BASE_URL` (:134) | `http://127.0.0.1:3000` | **O** | no (should) | No URL validation; production keeps the localhost default silently |
| `GPFORUM_SESSION_SECRET` (:140) | dev constant | **O** | yes (:576-579) | No length check |
| `GPFORUM_SESSION_SECRETS` (:146) | `[]` | o | – | Confusable with the above; it means "previous secrets" |
| `GPFORUM_DATABASE_DSN` (:151) | `dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432` | **O** | – | DBI syntax, not a URL most sysadmins know |
| `GPFORUM_DATABASE_USER` (:157) | `gpforum` | O | – | |
| `GPFORUM_DATABASE_PASSWORD` (:163) | `''` | O | – | libpq's `~/.pgpass` would work but is not mentioned |
| `GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS` (:168) | 15000 | i | – | |
| `GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS` (:175) | 10000 | i | – | |
| `GPFORUM_DATABASE_LOCK_TIMEOUT_MS` (:182) | 3000 | i | – | |
| `GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS` (:200) | 2000 | i | – | |
| `GPFORUM_SEARCH_CANDIDATE_LIMIT` (:208) | 1000 | i | – | |
| `GPFORUM_WEB_PROCESSES` (:215) | 4 | o→d | – | Should default from the CPU count; today 4 trips preflight on 1 vCPU |
| `GPFORUM_WORKER_PROCESSES` (:222) | 2 | **vestigial** | – | Only reported and floor-checked (Runtime.pm:14-35, RuntimeSizing.pm:18-24, Profile.pm:135-141). I found no code that starts processes from it |
| `GPFORUM_REALTIME_PROCESSES` (:229) | 1 | **vestigial** | – | Same |
| `GPFORUM_RUNTIME_LISTEN` (:236) | `http://127.0.0.1:8080` | o | – | Not validated (`8080` is accepted). Restated in the unit |
| `GPFORUM_RUNTIME_PID_FILE` (:242) | `hypnotoad.pid` | **i, coupled** | – | Must equal the unit's `PIDFile=/opt/gpforum/hypnotoad.pid` (gpforum.service:67); changing it breaks systemd tracking. Should be derived (`/run/gpforum/`) |
| `GPFORUM_RUNTIME_WORKER_POLICY` (:248) | `cap-to-cpu` | i | – | Cryptic value names |
| `GPFORUM_RUNTIME_MAX_WEB_PER_CPU` (:254) | 2 | i | – | Duplicates a constant in OS/Preflight.pm:21 and OS/Base.pm:20 |
| `GPFORUM_RUNTIME_BACKLOG` … `GPFORUM_RUNTIME_SPARE_PROCESSES` (:261-327, 9 vars) | Hypnotoad defaults | i | – | Hypnotoad tuning; all restated in units |
| `GPFORUM_RUNTIME_PROXY` (:331) | 1 | i | – | |
| `GPFORUM_RUNTIME_TRUSTED_PROXIES` (:338) | `127.0.0.1,::1` | o | – | Good default for the shipped proxies |
| `GPFORUM_OS_REUSEPORT`, `_SENDFILE`, `_WORKER_PRIORITY`, `_STATIC_XSENDFILE` (:344-365) | `auto` | i | – | `auto/on/off`; report and feature gating |
| `GPFORUM_OS_AFFINITY` (:368) | `off` | **vestigial** | – | `manual` only flips a reported flag (OS/Base.pm:123-126); DEPLOYMENT.md:528 says affinity is a non-goal |
| `GPFORUM_OS_MIN_RECOMMENDED_WORKERS` (:374) | 2 | i | – | The threshold that fails 1-vCPU hosts |
| `GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS` (:381) | 65536 | i | – | Duplicates `LimitNOFILE` |
| `GPFORUM_LOCAL_CACHE_MAX_ENTRIES` (:388) | 2048 | i | – | Profile floor 4096 for production-medium (Profile.pm:73) |
| `GPFORUM_CATEGORY_CACHE_TTL_SECONDS` (:395) | 60 | i | – | |
| `GPFORUM_REALTIME_LISTENER_ENABLED` (:402) | 1 | i | – | DEPLOYMENT.md:393-395: "keep it 1". A knob whose only right value is the default |
| `GPFORUM_REALTIME_LISTENER_*_SECONDS` (:409-427, 3 vars) | 1/5/30 | i | – | |
| `GPFORUM_MINION_ENABLED` (:430) | 0 | i | – | "optional Minion workers" (DEPLOYMENT.md:17); no operator story |
| `GPFORUM_MINION_PG_URL` (:437) | `''` | i | – | Message names the attribute (`minion_pg_url is required`) |
| `GPFORUM_METRICS_TOKEN` (:443) | `''` | **O** | yes (:587-590) | Message says "production requires" even on staging |
| `GPFORUM_METRICS_TOKENS` (:448) | `[]` | o | – | Previous tokens; one letter from the above |
| `GPFORUM_GLIFISTORE_URL` (:453) | dev `tcp://127.0.0.1:7379`, deployed `''` | O today, should be o | **yes** (:787-789) | Unobtainable dependency; defaults are inverted (set on the laptop, missing in production) |
| `GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS` (:460) | 300 | i | – | |
| `GPFORUM_MAIL_TRANSPORT` (:467) | dev `test`, deployed `sendmail` | O | – | `test` delivers nothing |
| `GPFORUM_MAIL_FROM` (:475) | `noreply@localhost` | **O** | no (should) | Production keeps `noreply@localhost` silently; most relays reject it. Derivable from the `PUBLIC_BASE_URL` host |
| `GPFORUM_SMTP_HOST`/`_PORT`/`_USERNAME`/`_PASSWORD` (:479-488) | `''`/587/`''`/`''` | O when smtp | – | No check that HOST is set when transport is `smtp` |
| `GPFORUM_SMTP_SSL` (:491) | 0 | **misnamed** | – | Means STARTTLS (Mailer.pm:154-155); no implicit TLS (465); the default is plaintext auth on 587 |
| `GPFORUM_ANTIVIRUS` (:504) | dev `none`, deployed `clamd` | O | – | Good |
| `GPFORUM_ANTIVIRUS_SOCKET` (:511) | per-OS | d | – | Already derived per OS; Intel Macs need an override derivable from `brew --prefix` (antivirus.md:59-61) |
| `GPFORUM_ANTIVIRUS_COMMAND` (:516) | `[]` | o | – | |
| `GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS` (:522) | 30/120 | i | – | |

Summary: of the 68, **about 10 are operator decisions** (ENV, PUBLIC_BASE_URL,
the 3 DATABASE, SESSION_SECRET, METRICS_TOKEN, MAIL_TRANSPORT, MAIL_FROM,
ANTIVIRUS), 6 more appear in some deployments (SMTP_*, TRUSTED_PROXIES,
ATTACHMENT_ROOT), **about 45 are tuning or internal** with safe defaults, **4
are vestigial** (WORKER_PROCESSES, REALTIME_PROCESSES, OS_AFFINITY,
REALTIME_LISTENER_ENABLED as a knob) and **3 are coupled or derivable**
(RUNTIME_PID_FILE, ATTACHMENT_ACCEL_REDIRECT, LOG_PATH).

Of the three that should hold the service's whole configuration, two are
duplicated tables: `Config.pm` `@SETTINGS` (:77-528) and the settings page
catalog `Service/Admin/Settings.pm` `@SECTIONS` (:27-…), kept in step by t/212.
Neither carries a one-line description an operator could read.

### 2.2 The 27 variables read outside `Config.pm`

| Variable | Read at | Who needs it | Flag |
| --- | --- | --- | --- |
| `MOJO_MODE` | every unit (gpforum.service:11 and 5 others), launchd plists, deploy/freebsd/gpforum:33 | nobody | **Dead**: overwritten by Bootstrap/Core.pm:27. `bin/gpforum -m` is equally ignored |
| `GPFORUM_CARTON` | script/gpforum-carton:13-19 | operators whose Carton is off PATH | Legitimate; better found automatically or named in a preflight message |
| `GPFORUM_PERL` | script/gpforum-system-perl:142-146 | rare | Legitimate escape hatch |
| `GPFORUM_PG_CONFIG` | script/system-preflight:74, script/bootstrap-deps:120 | rare | Fine |
| `GPFORUM_HOMEBREW_PREFIX`, `GPFORUM_HOMEBREW_PG_BIN`, `GPFORUM_UNAME` | script/gpforum-homebrew-env:74-95 | tests | **Test-only**, printed in operator `--help` |
| `GPFORUM_PG_DUMP`, `GPFORUM_PG_RESTORE` | StagingDrill/PgTools.pm:43-48, :114 | drills | Fine |
| `GPFORUM_PITR_PORT`/`_DIR`, `GPFORUM_STANDBY_PORT`/`_PRIMARY_PORT`/`_DIR` | script/pitr-drill:23-24, script/standby-drill:15-17 | drills | Should be flags (`--port`, `--dir`), as everywhere else |
| `GPFORUM_EVIDENCE_DIR`, `GPFORUM_EVIDENCE_ENV_FILE` | script/gpforum-evidence-live:70-71 | release evidence | Should be flags |
| `GPFORUM_STRESS_BASE_URL` | Command/StressLoad.pm:99 | stress | Duplicates `--base-url` |
| `GPFORUM_FORUM_READ_RATE_LIMIT` | Web/ForumAccess.pm:93 | stress tests | **Hidden security knob**: honoured in production, outside the config table, so absent from `/admin/settings` and t/212 |
| `GPFORUM_BENCHMARK_QUERY_HEADERS` | Bootstrap/Operations.pm:458 | benchmarks | **Internal**: not gated by environment; set in production it exposes per-request DB counts to every client |
| `GPFORUM_QUERY_BUDGET_ENFORCE` | Bootstrap/Operations.pm:501 | dev/test | Internal |
| `GPFORUM_BENCHMARK_THREAD_ID`/`_CATEGORY_ID`/`_PROFILE` | script/benchmark-http:50-55 | benchmarks | Should be flags |
| `GPFORUM_STARTUP_TIMEOUT` | Benchmark/Process.pm:113-115 | benchmarks | Internal |
| `GPFORUM_REPLICATION_SLOT_MAX_RETAINED_BYTES` | Readiness.pm:289 (comment) | – | **Phantom**: named as "the configuration owns the knob", but no such setting exists |
| `PERL_CARTON_MIRROR` | script/bootstrap-deps | air-gapped installs | Fine |
| `HYPNOTOAD_FOREGROUND` | unit comments only (gpforum.service:63) | – | Not used |

### 2.3 Flags

- **Never needed by an operator**: all 9 `RUNTIME_*` Hypnotoad timeouts and
  sizes, the 5 `OS_*` switches, the 4 `REALTIME_LISTENER_*`, the 3 database
  timeouts, the 2 search knobs, `LOCAL_CACHE_MAX_ENTRIES`,
  `CATEGORY_CACHE_TTL_SECONDS`, `SESSION_TOUCH_INTERVAL_SECONDS`,
  `RUNTIME_PID_FILE`, `MINION_*`, and every benchmark or test variable in 2.2.
  Keep them working; take them off every page an operator reads first.
- **Confusing pairs**: `GPFORUM_ENV` / `MOJO_MODE` / `-m` / profile names
  (`production` is `production-small`, Profile.pm:18); `SESSION_SECRET` /
  `SESSION_SECRETS`; `METRICS_TOKEN` / `METRICS_TOKENS`; `WEB_PROCESSES` /
  `RUNTIME_MAX_WEB_PER_CPU` / `OS_MIN_RECOMMENDED_WORKERS` / profile floors;
  `script/os-preflight` / `script/system-preflight` / `make preflight`
  (runs system-preflight, Makefile:79-80) / `bin/gpforum-platform-check` /
  `make system-perl`.
- **Cryptic values**: `cap-to-cpu`/`configured`; `auto/on/off` × 4;
  `off/manual`; booleans must be `0`/`1`, and `true` gives
  `GPFORUM_REALTIME_LISTENER_ENABLED must be an integer`. DSNs use DBI syntax.
- **Duplicated knobs**: unit `Environment=` lines restating defaults
  (gpforum.service:18-40); `LimitNOFILE` against
  `OS_MAX_OPEN_FILE_DESCRIPTORS`; `PIDFile=` against `RUNTIME_PID_FILE`; the
  nginx alias against `ATTACHMENT_ROOT`; `GPFORUM_STRESS_BASE_URL` against
  `--base-url`.
- **Derivable**: `WEB_PROCESSES` (from CPU count); `MAIL_FROM` (from the public
  URL's host); `ATTACHMENT_ACCEL_REDIRECT` (from the proxy in use);
  `RUNTIME_PID_FILE` (from the runtime directory); `LOG_PATH` (journal under
  systemd); the clamd socket on Intel Macs; the size profile.
- **Profiles are chosen by the operator but sized by hand.** Choosing
  `GPFORUM_ENV=production-medium` does not change any default. It raises
  floors (Profile.pm:71-86) that the defaults do not meet, so readiness fails
  with `web_processes is below the operational profile floor`
  (Profile.pm:169-171) until 4 more variables are set. The profile also
  silently picks retention (365 against 730 days, Profile.pm:57, :73).
- **History to respect**: `etc/*.conf` profile files were removed because
  nothing read them, and "a second one with undocumented precedence is worse
  than none" (docs/architecture/operational-profiles.md:17-23). Any config
  file proposal must stay the **same mechanism** (an env file) with
  **documented precedence**.

---

## 3. Inventory of entry points

### 3.1 `bin/` (27)

`bin/gpforum` has a subcommand for each (lib/GPForum/CLI/*.pm). Help quality:
**G** = explains purpose, options and exit codes; **U** = one usage line only;
**M** = misleading.

| Command | Purpose | Main flags | Help | `--json` | Default output | Says what to do next |
| --- | --- | --- | --- | --- | --- | --- |
| gpforum | app, front door | Mojolicious | **M**: generic banner "Usage: APPLICATION COMMAND", `mojo generate lite-app`, `-m` mode, `cgi`/`psgi`/`eval`/`get` | – | – | – |
| gpforum-admin-bootstrap | first admin | `--user-id UUID`, `--actor-user-id`, `--role-name` | U | **no** | `key=value` line | no; DB failure → exit 2 plus usage (AdminBootstrap.pm:38-41) |
| gpforum-antivirus-check | prove the scanner | `--human/--json` | G | yes | human | partly |
| gpforum-bench-hypnotoad | benchmark | 18 flags | U | yes | json | – |
| gpforum-bench-hypnotoad-scaling | benchmark | 10 | U | yes | json | – |
| gpforum-benchmark | benchmark | 11 | U | yes | – | – |
| gpforum-dead-letter-check | **in-memory drill** | `--simulate/--dry-run` | G | default | json | **M**: `make dead-letter-check` says "Report the dead-letter queue" (Makefile:125) and `gpforum help` says "Report exhausted outbox messages"; neither touches the real queue |
| gpforum-dead-letter-replay | list or replay | `--list`, `--id` | G | yes | human | yes |
| gpforum-evidence-meta | stamp evidence | `--write` | G | – | json | – |
| gpforum-evidence-validate | validate evidence | `--strict` | G | default | json | – |
| gpforum-mail-check | probe mail | `--dry-run/--send --to` | G | default | **json** | partly |
| gpforum-mail-lifecycle-check | drill | `--simulate` | G | default | json | – |
| gpforum-migrate | schema | `--plan/--apply/--check`, `--no-partitions` | **G (best)** | yes | human | silent when there is nothing to do |
| gpforum-os-preflight | host check | `--human/--json`, `--strict` | U | yes | human, but `key=value` lines | no |
| gpforum-outbox-dispatch | mail and event worker | `--once/--loop`, `--limit`, `--sleep` | U | yes | human | – |
| gpforum-partition-maintenance | partitions | `--plan/--apply`, `--lookahead` | G | yes | human | yes (remediation printed) |
| gpforum-platform-check | prerequisites | `--local/--with-db` (+strict) | G | yes | human | no; aborts on a DB error |
| gpforum-query-budget | budgets | `--print/--sync/--check` | G | yes | human | names the drift |
| gpforum-query-plan-evidence | EXPLAIN evidence | 8 | U | yes | – | – |
| gpforum-scheduled-jobs | hourly sweep | `--once` (the only mode, ScheduledJobs.pm:19), `--limit`, `--job` | U | yes | human | – |
| gpforum-search-rebuild | reindex | `--entity`, `--status` | G | yes | human | bad `--entity` gives no reason |
| gpforum-seed-benchmark / -seed-performance-data | seeds | profile flags | U | yes | – | – |
| gpforum-staging-drill | dump/restore drill | 7 | G | default | json | – |
| gpforum-staging-drill-attachments | fs drill | 6 | G | default | json | – |
| gpforum-staging-host-verify | host verify | 8 | G | default | json | – |
| gpforum-stress-load | load | 14 | G (with examples) | default | json | – |

### 3.2 `script/` (50), `make` (33) and the console

- **script/**: 26 wrappers that `exec` a `bin/` entrypoint, 11 maintainer
  gates (critic, tidy, coverage, syntax, architecture, cpan audit and license,
  adr-index, test), 9 drills and benchmarks, and 4 environment helpers
  (gpforum-carton, gpforum-system-perl, gpforum-homebrew-env,
  bootstrap-deps). ENTRYPOINTS.md:19-20 says script/ "is not deployed", yet
  every unit runs `script/gpforum-carton` and `script/os-preflight`
  (gpforum.service:47-48), and DEPLOYMENT tells operators to run
  `script/os-preflight`, `script/mail-check` and `script/antivirus-check`. No
  wrapper exists for `migrate`, `admin-bootstrap`, `partition-maintenance` or
  `platform-check`, so the operator has to know which commands have the short
  form.
- **make**: `make help` is tidy (Makefile:14-19), but some descriptions are
  wrong. `mail-check` says "Send a test message" and runs `--dry-run`
  (Makefile:108-109). `dead-letter-check` says "Report the dead-letter queue"
  and simulates in memory (:125-126). `partition-maintenance` says "add
  --apply to run", which make cannot pass (:122-123). There are no
  `migrate`, `start` or `doctor` targets.
- **Console**: `/admin/status`, `/admin/settings` (read-only, redacted, names
  `/etc/gpforum/gpforum.env` and `systemctl restart gpforum`, Settings.pm:17-21),
  `/admin/jobs` (replay, rebuild, purge), mail test and antivirus check. Good
  parity, documented in console-and-cli.md:21-49.

### 3.3 Inconsistencies

1. **Two names per command**: `bin/gpforum-X`, `script/X` (sometimes),
   `bin/gpforum X`. Help always prints the `bin/gpforum-X` form, even through
   the front door: `bin/gpforum help migrate` prints `Usage:
   bin/gpforum-migrate ...`. Help built with `Usage->program` prints `Usage:
   bin/gpforum [--dry-run] ...` without the subcommand and without a newline
   (`bin/gpforum performance-seed --help`; PerformanceSeed.pm:265). Usage lines
   hardcode `bin/` in AdminBootstrap.pm:113, OutboxDispatch.pm:215,
   ScheduledJobs.pm:283, SearchRebuild.pm:182 and Benchmark.pm:411, despite
   Usage.pm:222-232.
2. **Output default flips**: operational commands default to human output,
   evidence commands to JSON (mail-check, staging-*, stress-load,
   dead-letter-check). `os-preflight --human` prints `key=value` lines, not
   prose.
3. **Verb vocabularies**: `--plan/--apply/--check` (migrate, partitions);
   `--print/--sync/--check` (query-budget); `--dry-run/--send` (mail);
   `--simulate/--dry-run` (drills); `--once/--loop`; `--status`; `--local/--with-db`.
4. **Misuse messages**: some say what was wrong (`unknown option --aply`,
   `--limit requires a positive integer`, `unknown job bogus`). Others print
   only the usage (`search-rebuild --entity bogus`). admin-bootstrap prints the
   usage twice, because `parse_options` throws the usage as the message
   (Usage.pm:110) and `error` prints the message plus the usage (Usage.pm:69-78).
5. **Exit codes**: the contract is 0/1/2 (Usage.pm:29-31), but `bin/gpforum`
   exits **255** on a config error, and admin-bootstrap exits **2** on a
   database failure.
6. **Noise in setup tools**: `script/system-preflight --help` runs the whole
   check and dumps `perl -V`. `script/bootstrap-deps --help` prints
   `bootstrap-deps: system perl -> ...` before the usage (bootstrap-deps:19).
   `script/gpforum-carton exec <bare command>` first runs that command with
   `--version` as a probe (gpforum-carton:75-80).

---

## 4. Error and diagnostic messages

### 4.1 Startup (`GPForum::Config` and bootstrap); each one ends the start, one at a time

| Trigger | Message as printed | Names the fix? | File:line |
| --- | --- | --- | --- |
| production, nothing set | `glifistore_url is required` | no: attribute name, no hint the component is unobtainable | Config.pm:735 via :787-789 |
| no session secret | `production requires GPFORUM_SESSION_SECRET` | variable yes; says "production" on staging; no "generate with …" | Config.pm:578 |
| no metrics token | `production requires GPFORUM_METRICS_TOKEN` | same | Config.pm:589 |
| bad integer | `GPFORUM_WEB_PROCESSES must be an integer` | yes | Config.pm:690 |
| boolean `true` | `GPFORUM_REALTIME_LISTENER_ENABLED must be an integer` | misleading (it is a boolean) | Config.pm:690 |
| bad choice | `mail_transport must be test, smtp, or sendmail` | attribute name, not variable | Config.pm:723 |
| bad zone | `default_timezone must be an IANA time zone such as Europe/Rome` | good example, wrong name | Config.pm:763 |
| antivirus command | `antivirus command requires GPFORUM_ANTIVIRUS_COMMAND` | yes | Config.pm:794 |
| Minion | `minion_pg_url is required` | no; the good one, `GPFORUM_MINION_PG_URL is required when GPFORUM_MINION_ENABLED=1`, is unreachable | Config.pm:437-440 vs Workers.pm:194-196 |
| log dir missing | `unable to open the configured log path: /nonexistent/x.log` | no (`GPFORUM_LOG_PATH`? mkdir? owner?) | Log.pm:42-44 |
| clamd socket | `no clamd socket is known for this operating system; set GPFORUM_ANTIVIRUS_SOCKET` | **yes**, the model to follow | Clamd.pm:235-237 |
| GlifiStore URL shape | `glifistore_url must be tcp://host:port, unix://path, or host:port` | shape yes, variable no | Config.pm:784 |
| `GPFORUM_ENV=prod` | (nothing) | – | Config.pm:88-93 |
| `GPFORUM_LOG_LEVEL=verbose` | Perl warning from Mojo/Log.pm line 75 | no | Config.pm:94-99 |
| `GPFORUM_PUBLIC_BASE_URL=forum.example.com`, `GPFORUM_DEFAULT_LOCALE=fr`, `GPFORUM_RUNTIME_LISTEN=8080` | (nothing) | – | Config.pm:113-137, :236-239 |

All of them print without a trailing newline (the shell prompt follows on the
same line), and `bin/gpforum` exits 255.

### 4.2 Commands

- **Database unreachable**, from every command that connects:
  `DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed: DBI
  connect('dbname=gpforum;host=127.0.0.1;port=5432','gpforum',...) failed:
  connection to server at "127.0.0.1", port 5432 failed: Connection refused`.
  Cryptic prefix. It never says which variable to change or whether the env
  file was loaded. Classification (refused, auth, unknown database, missing
  role, schema not migrated) would let the message name the fix.
- **Good ones to copy**: migrate's `--help` (exit codes, a pointer to the
  runbook); partition-maintenance printing the remediation; `gpforum-carton`'s
  `Install it for this Perl with: $perl_bin -S cpanm -M https://cpan.metacpan.org/ Carton`
  (gpforum-carton:92-93); the FreeBSD rc's `must not be readable by others
  (chmod 0640)` (deploy/freebsd/gpforum:53); readiness checks carrying a
  `runbook` (Readiness.pm:44-61, :80-84).
- **Readiness**: names and runbook paths are good. Messages are terse
  (`runtime profile unavailable`, Readiness.pm:104), and the full report is
  reachable only through curl, the token and jq.
- **Profile**: `unknown operational profile`, `rotated session secret is
  required`, `web_processes is below the operational profile floor`
  (Profile.pm:113-118, :169-171, :184). None names a variable or a value.

---

## 5. Proposal: a guided, minimal operator experience

### 5.1 Principles, taken from the brief

1. **One front door, one name**: `gpforum <verb>`. An operator never types
   `script/gpforum-carton exec perl -Ilib`.
2. **The front door sees what the service sees.** It loads the same env file
   the unit loads, so `sudo -u gpforum gpforum doctor` and the running
   service never disagree.
3. **About 3 decisions for the common case**: the public address, the
   database, how mail leaves. Everything else is generated, derived or
   defaulted.
4. **Every problem names its fix**: the variable, an example value and the
   next command. All problems at once, never one per restart.
5. **Profiles are chosen for the operator.** Size comes from the host; the
   operator says only "this is production".
6. **Old names keep working** with a one-line deprecation warning, removed
   only after a documented release.

### 5.2 What the first minutes should look like (the acceptance target)

```text
$ sudo apt install gpforum-deps…            # (or the README's 2 lines)
$ git clone … /opt/gpforum && cd /opt/gpforum
$ sudo bin/gpforum setup
  GPForum setup. Three questions; Enter accepts the suggestion.
  Public address [https://forum.example.com]:
  Database [create 'gpforum' on this host]:
  Mail [sendmail via the local MTA | smtp | log only]:
  ✓ dependencies installed for /usr/bin/perl 5.40
  ✓ user gpforum, /etc/gpforum/gpforum.env (0640 root:gpforum), secrets generated
  ✓ database gpforum, role gpforum, 51 migrations, budgets synced
  ✓ units written for systemd: gpforum, gpforum-outbox, 2 timers (not enabled)
  Next: sudo systemctl enable --now gpforum gpforum-outbox gpforum-scheduled-jobs.timer gpforum-partition-maintenance.timer
$ sudo -u gpforum bin/gpforum admin create --email you@example.com
  Password: ********
  ✓ you@example.com is the forum's owner and can sign in now.
$ sudo -u gpforum bin/gpforum doctor
  ✓ configuration (production, sized for 1 CPU: 2 web processes)
  ✓ database 18.1, schema current (051), budgets match
  ✓ outbox worker alive (last batch 4 s ago)
  ! antivirus: clamd not found at /var/run/clamav/clamd.ctl
      Fix: sudo apt install clamav-daemon clamav-freshclam
           or set GPFORUM_ANTIVIRUS=none in /etc/gpforum/gpforum.env
  ! proxy: https://forum.example.com does not answer
      Fix: copy deploy/nginx/gpforum.conf (see `gpforum service print nginx`)
  2 things to fix.
```

### 5.3 Ranked work items (value / effort)

V = operator value (1-5), E = effort (S, M, L). D = needs an owner decision
(section 5.5).

| # | Item | V | E | D | Grounding |
| --- | --- | --- | --- | --- | --- |
| A1 | Config errors name the **variable**, give an example, list **all** problems at once, end with a newline, exit 78 (EX_CONFIG) or 1 instead of 255. Add a `summary` (one line) and `section` to each `@SETTINGS` row, so one table drives validation, the settings page and the template | 5 | S | – | Config.pm:566-593, :711-736; Settings.pm:27 |
| A2 | Validate what is silently wrong today: `GPFORUM_ENV` one-of (and suggest the nearest name: `prod` → `production`); `PUBLIC_BASE_URL` scheme and host (`https` in production); `MAIL_FROM` not `@localhost` in production; `LOG_LEVEL` one-of; `DEFAULT_LOCALE` one of the shipped locales; `RUNTIME_LISTEN` URL shape; `SMTP_HOST` set when transport is smtp; session secret at least 32 bytes in production | 5 | S | – | Config.pm:88-137, :236, :467-488 |
| A3 | Booleans accept `1/0/yes/no/true/false/on/off`; the message says "must be on or off" | 3 | S | – | Config.pm:689-691, :746-748 |
| A4 | Ship `deploy/gpforum.env.example`, **generated from `@SETTINGS`** (only the ~10 operator settings uncommented, each with a one-line comment; an "Advanced" block listing the rest commented out). A test keeps it in step | 5 | S | – | DEPLOYMENT.md:196-201 |
| A5 | Fix doc and template drift: enable `gpforum-outbox` in DEPLOYMENT; nginx `client_max_body_size 26m`; remove the stale X-Accel sentence and document `GPFORUM_ATTACHMENT_ACCEL_REDIRECT` with the alias; restrict `/metrics` in the Caddyfile; README code block with `sudo -u postgres` and `--pwprompt`; one install target named for production; add `useradd` and `/opt/gpforum` ownership | 5 | S | – | §1.1 steps 3, 4, 6, 8, 20, 22-24 |
| A6 | Drop restated defaults and `MOJO_MODE` from units and plists; derive the pid file from `RuntimeDirectory` | 4 | S | D10 | gpforum.service:11, :18-40, :67; Core.pm:27 |
| A7 | Fix `--strict` preflight on small hosts: compare **effective** web processes (after `cap-to-cpu`), not configured; default `GPFORUM_WEB_PROCESSES` to `auto`; for `--strict` in `ExecStartPre`, fail only on `fail` | 5 | S | D10 | OS/Preflight.pm:222-238, RuntimePolicy.pm:22 |
| A8 | Development mail transport `log`, the default in development: it writes the message, link included, to the log or stdout. The README quick start then works offline | 5 | S | D7 | Mailer.pm:137-147, README.md:125-133 |
| A9 | `gpforum admin create --email --username` (password prompt, active and verified, bound to the owner role) and `gpforum admin grant <email\|username>`; keep `--user-id` as an alias. Removes the psql UUID step and the mail dependency for the first admin | 5 | M | D6 | README.md:139-141, Bootstrapper.pm:27-38 |
| A10 | Make `GlifiStore` optional in production (no URL → L1 only, readiness `ok` with a note); development defaults to none instead of `tcp://127.0.0.1:7379` | 5 | S | **D2** | Config.pm:452-457; DEPLOYMENT.md:413-458 |
| B1 | **Front door**: `bin/gpforum` re-execs itself under `gpforum-carton` when `local/` is not on `@INC`, loads the env file (`/etc/gpforum/gpforum.env`, `/usr/local/etc/gpforum/gpforum.env` on FreeBSD, `$(brew --prefix)/etc/gpforum/gpforum.env` on macOS, or `--env-file`), with the process environment winning. Add a `bin/gpforum` symlink target in the docs, or `make install-cli` | 5 | M | **D1** | DEPLOYMENT.md:75; operational-profiles.md:17-23 |
| B2 | Front-door help of its own: grouped **Set up** (setup, migrate, admin), **Run** (start, outbox), **Check** (doctor, status, mail-check, antivirus-check), **Maintain** (search-rebuild, dead-letters, partitions, budgets), and **More** (`gpforum help --all`: benchmarks, seeds, drills, evidence, and Mojolicious's cgi/psgi/eval/get/prefork). No `mojo generate lite-app` | 4 | S | D4 | GPForum.pm:38; `bin/gpforum --help` |
| B3 | `gpforum doctor`: config (all problems), database (classified errors that name the variable), schema current, budgets, the readiness report (reuse `Readiness->check`), mail dry-run, antivirus, outbox worker liveness (age of oldest pending message), timers' last run, units installed and drifted (`DeployContract`), public URL reachable over TLS. Output `✓/!/✗` plus `Fix:` lines; `--json`; exit 0/1 | 5 | M | – | Readiness.pm:66-90; DeployContract.pm; PlatformCheck.pm |
| B4 | `gpforum status`: the `/health/ready` full report, read with the token from the env file, in human form | 4 | S | – | DEPLOYMENT.md:356-357 |
| B5 | `gpforum migrate` = migrate, partition window and **query-budget sync**; prints `Schema is current (051).` when there is nothing to do; `--quiet` keeps today's silence for CI | 4 | S | D5 | Migrate.pm:196-198; DEPLOYMENT.md:205 |
| B6 | One command style: usage shows the name typed (`gpforum migrate`); misuse always says what was wrong; human by default, `--json` everywhere (admin-bootstrap too); the same verbs everywhere (`--dry-run` as the universal "show, do not do"); every human success ends with a `Next:` line when there is a next step | 4 | M | D12 | §3.3 |
| B7 | DB errors: translate DBI connect failures into `cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused). Check GPFORUM_DATABASE_DSN in /etc/gpforum/gpforum.env, or start PostgreSQL.`, and the same for auth failure, unknown database and missing tables (`run: gpforum migrate`) | 5 | S | – | Usage.pm:171-182 is the single choke point |
| C1 | `gpforum setup`: interactive, idempotent, with `--yes` and flags for automation. Asks 3 questions, generates secrets, writes the env file with mode and owner, creates the role and database when it can, migrates, renders the units | 5 | L | D1, D8 | §5.2 |
| C2 | `gpforum service print systemd\|rc\|launchd\|nginx\|caddy`: renders templates with the operator's paths, host name and user, **outbox included for every OS**, launchd with `UserName` and an env-file wrapper. It prints; it does not install (respects DEPLOYMENT.md:529) | 4 | M | D8 | deploy/launchd/*, deploy/freebsd/gpforum |
| C3 | `gpforum secret rotate session\|metrics` (moves current to previous, generates new, prints restart and scraper steps) and `--finish` | 4 | S | D1 | DEPLOYMENT.md:192-194, :351-353 |
| C4 | `docs/ops/upgrade.md` plus `gpforum doctor --upgrade` (units drifted? deps for this Perl? pending migrations?) | 4 | S | – | §1.3 |
| C5 | `gpforum backup` (pg_dump `-Fc`, attachment root as tar, manifest) and `gpforum restore --check` | 3 | M | D11 | backup-and-restore.md:22-29 |
| D1' | `GPFORUM_ENV` becomes `development\|staging\|production`; size is derived from the host (CPU and RAM) and reported by `doctor`; `production-small`/`-medium` stay as deprecated aliases; retention becomes plain settings with today's production-small values as defaults | 4 | M | **D3** | Profile.pm:14-86 |
| D2' | Remove vestigial knobs (`WORKER_PROCESSES`, `REALTIME_PROCESSES`, `OS_AFFINITY`; `REALTIME_LISTENER_ENABLED` documented as internal); move `GPFORUM_FORUM_READ_RATE_LIMIT` into the table (or gate it to non-production); gate `GPFORUM_BENCHMARK_QUERY_HEADERS` to non-production; remove the phantom comment (Readiness.pm:289) | 3 | S | – | §2.2 |
| D3' | Rename `GPFORUM_SMTP_SSL` → `GPFORUM_SMTP_TLS=starttls\|implicit\|off`, defaulting to `starttls` (port 587) and `implicit` (port 465) | 3 | S | D11 | Mailer.pm:154-155 |
| D4' | Drill and evidence variables become flags (`--port`, `--dir`, `--out`) | 2 | S | – | §2.2 |

### 5.4 Iterations, each closed by a fresh-install walkthrough

Each iteration ends by repeating section 1 on a **fresh Debian 13 VM** and a
**fresh macOS/Homebrew account**. Record every command typed, every document
opened, every error met (quoted), and the wall time. Commit the record under
`docs/ops/evidence/<date>-operator-walkthrough/`. The iteration passes when
its target numbers are met and no step is undocumented.

**Iteration 1: say what to do (all S; no new commands)**
A1, A2, A3, A4, A5, A6, A7, A8, B7, plus D2' and A10 if D2 is decided.
*Acceptance*:
- Debian: the 6 undocumented steps are now documented.
- Every config problem appears at once, naming its variable.
- 1 vCPU starts.
- The README quick start reaches a signed-in admin on macOS **without an
  MTA**, through the `log` transport and the existing bootstrap: 15 steps,
  no dead end.
- Debian ≤ 26 steps and ≤ 8 documents.

**Iteration 2: one front door**
B1, B2, B3, B4, B5, B6, A9, C3, C4.
*Acceptance*:
- No `script/gpforum-carton exec perl -Ilib` and no `set -a; . env` anywhere
  in README, DEPLOYMENT or the runbooks.
- First admin without psql.
- `gpforum doctor` on the fresh VM lists every remaining problem with a
  working `Fix:` line. Check by deliberately breaking 10 things: DB down, wrong
  password, migrations pending, outbox stopped, clamd absent, wrong public
  URL, missing secret, timer disabled, unit drifted, proxy down.
- Debian ≤ 15 steps and ≤ 4 documents (README, DEPLOYMENT, one proxy page,
  one backup page).

**Iteration 3: guided setup**
C1, C2, C5, D3'.
*Acceptance*:
- Debian: from clone to signed-in admin behind TLS in **≤ 8 typed
  commands**, about 3 answered questions and **1 document** (README).
- macOS: the same with `gpforum service print launchd`.
- Upgrade and metrics-token rotation each ≤ 3 commands, followed straight
  from `gpforum help`.

**Iteration 4: fewer settings**
D1', D4', the deprecation sweep (5.6), and pruning the env template to the
final operator set.
*Acceptance*:
- The common production case needs **3 settings typed by a human** (public
  URL, database, mail); the rest are generated or derived.
- `gpforum doctor` reports the derived size.
- An install still carrying old names starts and lists each one with its
  replacement.

### 5.5 Decisions for the owner

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | May the application (front door and service) **read the env file itself**, with the process environment winning? This is the same format and mechanism, but a second loader (operational-profiles.md:17-23 rejected a second *mechanism*) | Yes. Precedence: process env > `--env-file` > the default path; shown in `doctor` and on `/admin/settings` |
| D2 | **GlifiStore optional in production** (L1 only when unset) | Yes. Today's requirement is satisfiable only by a fake URL (DEPLOYMENT.md:446-447) |
| D3 | Collapse `GPFORUM_ENV` to development, staging and production, with size derived from the host; retention as plain settings | Yes, with aliases for one release |
| D4 | Hide Mojolicious's generic commands (cgi, psgi, eval, get, prefork, routes, version) behind `help --all` | Yes; keep `daemon` as `gpforum start --foreground` for development |
| D5 | `migrate --apply` speaks when there is nothing to do (CI checks silence today) | Yes, with `--quiet` for CI |
| D6 | `admin create` makes an **active, verified** owner without email (security policy: the operator already has shell and DB access) | Yes, audited as `admin.bootstrap_created` |
| D7 | A `log` mail transport, the default in development (it prints raw tokens to the log; the rule "raw tokens are never logged", PRODUCT_FLOWS.md:16, would get a development-only exception) | Yes, refused in staging and production |
| D8 | May `setup` write files (the env file, a user, units)? DEPLOYMENT.md:529 says GPForum does not install service files | `setup` writes the env file and creates DB objects; units are **printed** (`service print`), and the operator copies them |
| D9 | Is `script/` deployed? ENTRYPOINTS.md:19-20 says no, and the units depend on it | Move what units need (`gpforum-carton`, preflight) behind `bin/gpforum`; script/ stays maintainer-only |
| D10 | Keep `os-preflight --strict` as `ExecStartPre`? | Keep it, but `--strict` fails only on `fail`; `degraded` is logged |
| D11 | Rename `SMTP_SSL`; add a `backup` command (scope: logical dump plus attachments only) | Yes and yes |
| D12 | Evidence commands default to human output like the rest (archived evidence scripts pass `--json` explicitly) | Yes; the evidence scripts already pass flags |
| D13 | CLI language: English only, or follow `LANG` (it/en) like the forum? Locale files are on the owner's hands-off list | Owner's call. English first; keep messages in one table so they can be translated later |

### 5.6 Deprecation path for old names

- Add an `aliases` field to each `@SETTINGS` row (`GPFORUM_SMTP_SSL` →
  `GPFORUM_SMTP_TLS`, `production-small` → `production`, and so on).
  `from_environment` reads the new name first, then the old, and records each
  old one it used.
- At startup, log one line per old name: `GPFORUM_SMTP_SSL is deprecated; use
  GPFORUM_SMTP_TLS=starttls (removed in 0.3).` `gpforum doctor` lists them under
  `!` with the exact replacement line for the env file. `/admin/settings`
  shows the effective value under its new name. That page is a template, so
  the change is the owner's.
- Knobs removed outright (vestigial ones such as `GPFORUM_WORKER_PROCESSES`)
  are accepted and ignored with the same warning for one release, so an old
  env file never stops a start.
- Each rename gets a CHANGELOG entry and a row in a "Renamed settings" table
  in DEPLOYMENT.md. A test asserts that every alias still resolves until its
  removal version.

---

### Appendix: files this audit rests on

`README.md`; `docs/DEPLOYMENT.md`;
`docs/ops/{staging-host,mail-check,antivirus,backup-and-restore,standby-and-failover,reload-and-restart,console-and-cli}.md`;
`docs/ENTRYPOINTS.md`; `docs/architecture/operational-profiles.md`;
`lib/GPForum/Config.pm`; `lib/GPForum.pm`; `lib/GPForum/Bootstrap/{Core,Operations,Workers}.pm`;
`lib/GPForum/Command/{Usage,AdminBootstrap,Migrate,OsPreflight,PlatformCheck,OutboxDispatch,ScheduledJobs}.pm`;
`lib/GPForum/CLI/migrate.pm`; `lib/GPForum/Service/Operations/{Profile,Readiness,SharedCache,CacheFactory,StagingHostVerify}.pm`;
`lib/GPForum/Service/Admin/{Settings,Bootstrapper}.pm`; `lib/GPForum/OS/{Preflight,Base,RuntimePolicy}.pm`;
`lib/GPForum/Service/Identity/Mailer.pm`; `lib/GPForum/Web/ForumAccess.pm`; `lib/GPForum/Log.pm`;
`deploy/systemd/*`; `deploy/nginx/gpforum.conf`; `deploy/caddy/Caddyfile`; `deploy/freebsd/gpforum`;
`deploy/launchd/com.gpforum.app.plist`; `Makefile`;
`script/{gpforum-carton,system-preflight,gpforum-system-perl,bootstrap-deps,os-preflight}`.
