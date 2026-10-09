# Changelog

All notable changes to GPForum are recorded here, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). GPForum is an
application, not a CPAN distribution (ADR 0109): its versions are the
`vMAJOR.MINOR.PATCH` git tags, and each release gets a section named after
its tag and date. Changes not yet in a tag are under **Unreleased**.

Within a section, entries are newest first. Read **Operator action required**
before upgrading past a section: it lists what the operator has to do.
**Development** records changes that only affect maintainers -- tests, gates,
CI, evidence and internal refactors with no change in behaviour.

## Unreleased

### Operator action required

- Run `make install-deps-production` after pulling: the lock now installs
  IO::Socket::SSL (with Net::SSLeay, built against the host's OpenSSL), which
  mail over TLS needs. On FreeBSD and macOS the service now takes its mode from
  the environment file's `GPFORUM_ENV` (the template says `production`): check
  it, then re-print and reinstall the units with `gpforum service print rc` or
  `gpforum service print launchd` and restart them. On macOS, load the
  scheduled-jobs and partition plists too -- they were copied but never
  loaded -- after creating `$(brew --prefix)/var/log/gpforum` owned by
  `gpforum`. On FreeBSD, the jobs can move to `/usr/local/etc/cron.d/` (remove
  the old crontab lines). Add a nightly `gpforum backup` to `gpforum`'s
  crontab (`docs/ops/backup-and-restore.md`).

- Re-copy `deploy/systemd/gpforum-unix-socket.service` (a `%` in its listen
  address is now `%%`, which systemd needs). On macOS, create the `gpforum`
  account and re-copy the plists: they now run as `gpforum` and read the
  environment file. An smtp setup that never set `GPFORUM_SMTP_SSL` now uses
  TLS (STARTTLS on 587, implicit on 465) and needs IO::Socket::SSL; set
  `GPFORUM_SMTP_TLS=off` for a relay that takes mail in the clear.

- **`gpforum-migrate --apply` now speaks, and settings errors exit 78.**
  `--apply` prints one line -- `Applied 51 migrations, 001 to 051; synced the
  query budgets (25 changed).`, or `Schema is current (051).` when nothing
  was pending -- where it printed a line per migration, and nothing at all
  the second time: a deploy script that checked for silence passes
  `--quiet`. It also syncs the endpoint query budgets after the partitions,
  so the migrating role writes `endpoint_query_budgets`. `--plan` connects
  to the database to say what is pending. `bin/gpforum-admin-bootstrap`
  says what it did in a sentence; `--json` carries the counts its
  `key=value` line had. Every command that reports settings it cannot use
  exits 78 (EX_CONFIG), as `bin/gpforum` did, where it exited 1.

- **Production refuses settings that were silently wrong.** Check
  `/etc/gpforum/gpforum.env` before upgrading: production needs an `https://`
  `GPFORUM_PUBLIC_BASE_URL`, a `GPFORUM_MAIL_FROM` that is not at localhost
  and a `GPFORUM_SESSION_SECRET` of at least 32 characters (`openssl rand
  -hex 32`). Every environment refuses a `GPFORUM_ENV` that is not
  development, test, staging, production, production-small or
  production-medium (`prod` is answered with `production`), a
  `GPFORUM_LOG_LEVEL` Mojolicious does not know, a `GPFORUM_DEFAULT_LOCALE`
  without a catalog (`en`, `it`; a region, as in `it_IT` or `en-GB`, is read
  as its language, and a POSIX locale such as `it_IT.UTF-8` is answered with
  `it`), a `GPFORUM_RUNTIME_LISTEN` that is not a URL
  such as `http://127.0.0.1:8080`, and the smtp transport without
  `GPFORUM_SMTP_HOST`. Staging and production refuse
  `GPFORUM_MAIL_TRANSPORT=log`. A start that meets any of them lists every
  one, with an example, and stops.

- **Run the outbox worker everywhere.** Without it no verification, reset or
  notification mail leaves. FreeBSD now has an rc script for it
  (`deploy/freebsd/gpforum_outbox`: copy it to `/usr/local/etc/rc.d/` and
  `sysrc gpforum_outbox_enable=YES`) and macOS a plist
  (`deploy/launchd/com.gpforum.outbox.plist`). On Linux, check that
  `systemctl is-enabled gpforum-outbox` says `enabled`: the deployment guide
  never told you to enable it.

- **Copy the nginx and Caddy configurations again.** nginx now accepts
  bodies up to 26 MiB, and its `/internal-attachments/` alias is the default
  attachment store, `/opt/gpforum/var/attachments/`; if you kept
  `/srv/gpforum/attachments/`, keep your `GPFORUM_ATTACHMENT_ROOT` and alias
  as they are. The Caddyfile now answers `/metrics` and `/metrics/` only to
  the loopback, and nginx keeps `/metrics/` there too.

- **Re-copy the service files, then `systemctl daemon-reload` and restart.**
  The units and launchd plists set only `GPFORUM_ENV` and the log path: the
  23 lines that restated `GPForum::Config`'s defaults, and `MOJO_MODE`, which
  `GPFORUM_ENV` always overrode, are gone, so a default changed in a release
  now reaches the service. An override you made by editing a unit belongs in
  `/etc/gpforum/gpforum.env`. Hypnotoad's pid file moves from
  `/opt/gpforum/hypnotoad.pid` to `/run/gpforum/hypnotoad.pid`, the directory
  `RuntimeDirectory=` makes; an absolute `GPFORUM_RUNTIME_PID_FILE` is kept
  as it is. Until you re-copy them, a unit from before this release still
  starts: under it the pid file stays in `/opt/gpforum`, and the start logs
  a line saying to copy the units again.

- **Perl 5.40 or newer is required.** The supported floor moves from 5.38 to
  5.40 (ADR 0117): Debian 13 (trixie), Ubuntu 26.04, FreeBSD ports perl 5.40,
  or Homebrew's perl. `script/gpforum-system-perl --require` and
  `script/bootstrap-deps` refuse an older interpreter. A host on Ubuntu 24.04
  (perl 5.38) must be upgraded before deploying this release; after changing
  the interpreter, rebuild the locked tree (`script/bootstrap-deps --postgres
  --rebuild-local`), because its XS modules are built for one Perl.

- Alerting or scripts that read the readiness checks (`report.problems`,
  `partition_horizon`, `replication_slots`) must send the metrics token; see
  `docs/DEPLOYMENT.md#health-endpoints`.

- Enable the new daily `gpforum-partition-maintenance` timer on every node
  (systemd `gpforum-partition-maintenance.timer`, launchd
  `com.gpforum.partition-maintenance.plist`, or the FreeBSD crontab line in
  `docs/ops/partition-maintenance.md`). It must run as the role that owns the
  partitioned tables.

- **macOS hosts use Homebrew, not MacPorts.** Install `brew install perl
  cpanminus postgresql@18`, install Carton for that perl, and rebuild the
  locked tree (`script/bootstrap-deps --postgres --rebuild-local`): its XS
  modules are built for one Perl. `script/gpforum-macports-env` is now
  `script/gpforum-homebrew-env` (`make homebrew-env`). ClamAV on macOS comes
  from `brew install clamav`, with the socket at
  `/opt/homebrew/var/run/clamav/clamd.sock` (`docs/ops/antivirus.md`).

- **A reverse proxy on another host must be listed in
  `GPFORUM_RUNTIME_TRUSTED_PROXIES`** (for example `10.0.0.5` or
  `10.0.0.0/8`). Only the loopback is trusted by default; the shipped nginx
  and Caddy units run on the same host and need nothing.

- **Members signed in before this release sign in again.** Migration 045
  revokes every session whose bearer token was stored in the command log
  by the login defect below, and removes the tokens.
- **Grant `category.read` to administrators.** Private categories are now
  readable only through a `category.read` grant. Re-run
  `bin/gpforum-admin-bootstrap --user-id ADMIN_ID` (idempotent) so the owner
  role gains it, or attach it to the roles that should read private
  categories from the admin console; scope a binding to a space or a
  category to grant just that.
- **Set the forum's time zone.** `GPFORUM_DEFAULT_TIMEZONE` (an IANA name
  such as `Europe/Rome`, default `UTC`) is what visitors and members who have
  not chosen their own see. An invalid name stops the application at boot.
  Times on the site now carry their zone abbreviation.
- **FreeBSD: re-install the rc script and create its environment file.** The
  old `deploy/freebsd/gpforum` could not start a production instance: it never
  exported the configuration, and daemon(8) lost track of Hypnotoad. Copy the
  new script to `/usr/local/etc/rc.d/gpforum` and put the service environment
  (`GPFORUM_DATABASE_DSN`, `GPFORUM_SESSION_SECRET`, ...) in
  `/usr/local/etc/gpforum/gpforum.env`, owned by `root:gpforum`, mode `0640`;
  the script refuses a file others can read. See `docs/DEPLOYMENT.md`.
- **API change for staff tools.** Revoking a role binding, suspending a user,
  approving an erasure and running an erasure job now require `confirm=1` in
  the request, and answer 400 without it. The forms carry a checkbox for it
  and state what the action does; a script that posts to these routes must
  add the field.
- **Operator action required.** Uploads are now scanned by the operating
  system's free antivirus (ClamAV) before they are served (ADR 0108). Staging
  and production default to `GPFORUM_ANTIVIRUS=clamd`: install and start the
  system package (`clamav-daemon` + `clamav-freshclam`, `pkg install clamav`,
  or MacPorts `clamav` + `clamav-server`), set `StreamMaxLength 26M`, and run
  `script/antivirus-check`. Until clamd answers, new uploads stay pending and
  unserved. Attachments uploaded before stay served until the hourly
  `attachment_backfill` job has scanned them; on a large forum run it by hand
  with a large `--limit`. To run without scanning, set
  `GPFORUM_ANTIVIRUS=none`. Migration
  043 adds `attachments.scan_engine` and `scan_signature`. A media type
  mismatch after upload is now `failed`, not `infected`. The systemd units
  start after `clamav-daemon.service` and the rc.d script requires
  `clamav_clamd`: re-copy them. `bin/gpforum-scheduled-jobs` now exits 1
  when a job fails, and prints each job's error, so a timer unit whose run
  failed is marked failed. On macOS install `clamav-server` without its
  `scan_schedule_access` and `sanesecurity` variants. See
  `docs/ops/antivirus.md`.
- **Operator action required.** Rename `script/gpforum-os-preflight` to
  `script/os-preflight`, clearing the last `bin/` + `script/` basename
  collision (see `docs/ENTRYPOINTS.md`). `ExecStartPre=` in
  `deploy/systemd/gpforum.service` and
  `deploy/systemd/gpforum-unix-socket.service`, and the preflight call in
  `deploy/freebsd/gpforum`, now use the new path. **Existing installs must
  re-copy the unit files and run `systemctl daemon-reload` (Linux), or
  reinstall the rc.d script (FreeBSD): a host still running the old units
  fails to start, because `ExecStartPre=` points at a path that no longer
  exists.** Companion renames in the same series, for runbooks that call them
  directly: `script/gpforum-dead-letter-check` -> `script/dead-letter-check`
  and `script/gpforum-mail-lifecycle-check` -> `script/mail-lifecycle-check`.
  The `bin/` entrypoints keep their `gpforum-` names.
- Require the OS system Perl (`/usr/bin/perl` / distro package) for bootstrap,
  Carton, make, CI, and docs. Refuse version managers and custom PREFIX
  installs via `script/gpforum-system-perl`; document distro packages and
  `perl -V` preflight.
- Made GlifiStore the required disposable L2 cache for public SSR and
  category read-model seams; staging and production fail closed when
  `GPFORUM_GLIFISTORE_URL` is missing, while PostgreSQL stays authoritative.

### Security

- A password change could undo the reset that took an account back. The
  change verifies the current password before its transaction; a reset that
  committed in between replaced that password, and the change rotated the
  reset's password away all the same, so whoever knew the old one set the
  last password. A reset that waited for a change answered ok and left the
  change's password, and a change that waited for another reported success
  with a password it never stored. A rotation now locks the member's active
  credential, and when another rotation commits while it waits, the
  credential that one created; a change goes on only while the credential it
  verified is that one, and answers `invalid_current_password` otherwise.

- An erasure racing a login could deadlock, and the login keep its session.
  The erasure anonymized the account row first and revoked the credentials
  after; a login holds the credential it verified while it opens its
  session, whose foreign key then shares the account row. Each waited for
  the other, PostgreSQL aborted one of them -- mostly the erasure -- and the
  login stayed signed in. The erasure now revokes the credentials first, in
  the order a login takes its locks, so it waits for that login to commit
  and revokes its session with the others; and each credential and session
  is revoked at the erasure's time or at its own creation, whichever is
  later, where a row stamped after the erasure read its clock failed the
  `revoked_after_created` checks, and the whole erasure with it.

- A password reset that waited for a login could fail and leave that login
  signed in. The reset reads its clock before it waits for a login holding
  the member's credential, and the login's session is stamped after, often a
  second later; the reset gave the session its own, earlier time, which
  `sessions_revoked_after_created_check` refuses, so the whole reset rolled
  back (two runs in five of `t/integration/postgres-login-reset-race.t`).
  A logout on a host whose clock is behind the one that signed the member in
  failed the same way. A session is now revoked at the time given or at its
  own creation, whichever is later, in one UPDATE that touches only sessions
  still live, so a revocation that landed first keeps its time.

- A login could keep a session after a password reset took the account back.
  The login verifies the password outside any transaction and opened its
  session afterwards; a reset (or a password change) that committed in
  between revoked the member's sessions before that one existed, and it
  stayed valid for whoever knew the old password. The session is now opened
  in a transaction that holds the verified credential `FOR SHARE` and opens
  none once the credential is revoked, and the rotation locks the credential
  `FOR UPDATE` before the same transaction revokes the sessions: a login
  that got there first has its session revoked, one that came after is
  refused as a wrong password.

- `GET /health/ready` no longer shows its full report to anonymous clients:
  without a valid metrics token it answers only
  `{"status":...,"check":"ready"}`. The report -- every check, its error text,
  replication slot names, `report.problems`, the runtime -- needs the same
  token as `/metrics` (`Authorization: Bearer` or `X-GPForum-Metrics-Token`,
  previous tokens accepted during a rotation). The status code is unchanged in
  every case, and a wrong token gets the status, not a 401, so a stale probe
  token cannot take nodes out of service. `GET /health` answers
  `{"status":"ok"}` without the token. Both send `Cache-Control: no-store`.
  Development and test without a configured token still show the full reports.

- Erasing a member also deletes all their export requests, whatever their
  status, and removes the bundle from their stored `privacy.export` answers in
  the command log, in the same transaction; the audit keeps the export events
  and lists the discarded requests. An export locks the member's row until it
  commits, so a concurrent erasure waits for it and then discards the bundle,
  and an export for an erased member is refused (`not_found`).

- Session revoke and validation check, in SQL, that the session belongs to the
  member id presented. A DBIx::Class `find` had dropped the member id from the
  query, so one member could revoke or validate another member's session
  given its id.

- **The replication docs no longer recommend `pg_monitor`**, which also
  grants `pg_read_all_settings` and with it a standby's `primary_conninfo`,
  replication password included; `pg_read_all_stats` is enough.

- **A `password=` in `GPFORUM_DATABASE_DSN` is redacted in command failure
  messages**, on stderr and in `--json` output; DBI's connect error printed
  it as is.

- **A static response that writes the session cookie back is marked
  `private`**, so no shared cache can store one visitor's session cookie and
  serve it to another.

- **Search no longer shows a moved thread's documents under the category it
  left** (ADR 0102): a thread moved from a public category into a private
  one stayed searchable by anyone until its reindex batch ran. Documents
  whose live placement disagrees are hidden until the outbox reindexes them.

- **A cancelled search no longer logs the visitor's search text.** The
  degraded-search log line carried the whole database error, with the SQL
  and its bound values; it now holds only the error.

- **An account that has not confirmed its e-mail is no longer a member.**
  Effective visibility (ADR 0102) counted `pending` accounts as members, so a
  session for one read members-only categories and threads. Such an account
  cannot sign in and confirming makes it `active`, so it now reads what an
  anonymous visitor reads.

- **Email::Sender 2.603** (was 2.601): CVE-2026-93012, command execution
  through an envelope address on Windows. GPForum does not run on Windows;
  the lock takes the fix anyway, and the `cpanfile` floor now requires it.
  DBI 1.655, Cpanel::JSON::XS 4.53 and DateTime::TimeZone 2.71 are updated
  too. 34 distributions nothing requires any more (Email::MIME, the
  WWW::Mechanize test stack, DateTime::Format::Pg and others) left the lock.
  `script/cpan-audit` reports no unexcluded advisory.

- **`X-Forwarded-For` is believed only from trusted proxies.** Any sender's
  header was believed, so a client that reached the application directly
  could name its own address, and with it its rate-limit bucket. Hypnotoad
  now trusts the loopback by default (`GPFORUM_RUNTIME_TRUSTED_PROXIES`).

- **Logins are limited per account, not only per address.** Ten tries per
  address every five minutes let many addresses try one account thousands of
  times. An account now takes at most twenty tries every five minutes, from
  every address together.

- **A session the database could not check is no longer served as its
  user.** When validating the session cookie failed, the request went on as
  the cookie's user: a session revoked by a password change or a sign-out
  everywhere acted again whenever the check failed and the page's own
  queries did not. The request now gets 503; the cookie is kept, so a valid
  session works again once the database answers.

- **Login timing no longer tells which accounts exist.** A login for an
  unknown or deleted account answered at once, while a wrong password took an
  Argon2 verification (68 ms here): timing the reply enumerated usernames and
  addresses. Every failed login now pays the same verification, against a
  per-process decoy hash (69 ms).

- **A login could be replayed without the password.** Logins were
  idempotent commands whose stored answer held the session's bearer token:
  sending the victim's command id and identifier with any password signed
  the sender in as the victim, and the token sat in `command_log` in plain.
  A login no longer passes through the command log; each attempt checks the
  password. Reproduced and pinned against the application on PostgreSQL.
- **Review fixes to effective visibility's third stage (ADR 0102).** Any
  question about a hidden thread died (a restricted-hash read), failing
  its notifications, downloads and realtime; realtime announced a private
  reply's id and author to every subscriber of a public thread; hiding or
  deleting a thread silenced every open page for good, even after a
  restore; "mark all read" counted notifications the inbox hides. The
  unread count now stops at "more than 99" instead of growing with the
  backlog on every delivery.
- **Hidden and restricted content leaves the public page cache at once.**
  A thread's cached public page was never invalidated, and hiding or
  restoring a post, locking a thread or reversing a moderation action did
  not reach the cache at all: anonymous visitors kept seeing hidden content,
  or a thread whose category turned private, until the entry expired (60 s
  by default). Thread and post events now purge the thread's page and its
  category's; moderation and category changes purge every public page.
- **New threads and replies inherit their place's visibility (ADR 0102).**
  A thread created without a visibility was public whatever its category,
  and the reply form sent the thread's own visibility: in a members-only
  category both were stored public, and became readable by anyone the day
  the category was opened. They now inherit the effective visibility of
  their category or thread, and a broader one is refused. The new-thread
  form's visibility defaults to "Same as the category".
- **Inboxes, lists and realtime channels respect effective visibility (ADR
  0102).** A notification, mention, bookmark or feed item kept showing its
  thread after the thread's category turned private or the reader lost
  their grant; the unread count and the realtime badge counted them. They
  now show only what the reader can still read. A realtime thread channel
  ignored the space, shut members out of members-only threads and never
  re-checked a subscriber; it now opens to the thread's readers and asks
  again at every broadcast.
- **Attachment downloads respect effective visibility (ADR 0102).** A file
  attached to a post in a private category was served to anyone, anonymous
  visitors included, because only the post's own visibility was checked. It
  is now served only to readers of the post or thread (its space, category,
  thread and post) and to its uploader.
- **Review fixes to effective visibility's first stage (ADR 0102).** The
  second page of a thread (`?after=`) dropped the post visibility filter for
  signed-in readers, showing private replies; restoring a thread looked it up
  without the viewer; a category page's thread list used a viewer without
  that category's grant context; a suspended author kept reading their own
  private threads; a thread-scoped `category.read` binding was read as a
  grant on its whole space. All are fixed and pinned by tests that fail on
  the old code.
- **Notifications and mentions no longer leak private content (ADR 0102).**
  A reply or mention in a private or members-only place notified every
  subscriber or mentioned user, with the thread, the post and the actor. A
  recipient is now notified only if they can read the source, and a mention
  of someone who cannot is not recorded.
- **Profiles and page metadata respect category visibility (ADR 0102).**
  A member's public profile listed their threads and replies in private
  categories, and a thread page in a members-only category asked to be
  indexed with OpenGraph data; both now judge the category and space too.
- **Search no longer shows private or members-only categories' content
  (ADR 0102, stage 2).** Search and autocomplete judged only a document's
  own visibility; they now also judge its category and space, live, for
  the reader.
- **Private and members-only categories no longer leak (ADR 0102, stage
  1).** A category or space an administrator marked private or members-only
  was listed to anonymous visitors and its pages and threads answered 200.
  Category lists and pages, thread lists and pages, and post lookups now
  apply the effective visibility of the space, the category, the thread and
  the post for each reader; denied reads are 404. Members-only threads, which
  were hidden from everyone, are now readable by members, and authors read
  their own private threads. Search, feeds, notifications and the other
  surfaces follow in the next stages.
- Harden `script/gpforum-mail-check` evidence: always set
  `secrets_redacted` / `private_beta_claimed=false`, emit `residual_gaps`, and
  scrub SMTP passwords plus the internal probe token from nested
  strings/errors (including connect failures). Docs + evidence-live updated.
- Registration remints user `id` once when the unique primary key
  conflicts, and does not return another user's account.
- Password credential writes remint `id` once when the unique primary key
  conflicts, and do not return another user's credential.
- Identity token writes remint `token_id` once when the unique primary key
  conflicts, and do not return another user's token.
- Session writes remint `session_id` once when the unique primary key
  conflicts, and do not return another user's session.
- Identity token writes retry hash allocation once when the unique
  `token_hash` key conflicts, and do not return another user's token.
- Session writes retry hash allocation once when the unique `session_hash`
  key conflicts, and do not return another user's session.
- A second unused password-reset, email-change, or email-verification
  token for the same user replaces the open row instead of inserting
  another. The previous unused hash is invalidated. Email verification
  is a legal `identity_tokens.token_type`.
- Mojolicious keeps the current `GPFORUM_SESSION_SECRET` first for new
  cookies and still validates previous secrets from
  `GPFORUM_SESSION_SECRETS`. `/metrics` accepts previous scrape tokens from
  `GPFORUM_METRICS_TOKENS`. Staging and production reject the development
  default in both the current secret and the previous list.
- Staging and production profiles send
  `Strict-Transport-Security: max-age=31536000; includeSubDomains` and mark
  session cookies Secure. Development and test omit HSTS and the Secure
  flag. `production-small` and `production-medium` follow the same TLS
  cookie/HSTS policy as `production`.
- Wired the existing `forum_retrieval` limiter on `GET /search`, and added
  `write_rate_input` hashes on `Web::ModerationAccess`, `Web::AdminAccess`,
  and `Web::PrivacyAccess` so moderation writes, admin writes, and privacy
  requests share the same CSRF/telemetry write helpers as forum
  `write_user_id`.
- Updated every locked CPAN distribution to its latest release and pruned
  32 orphaned distributions from `cpanfile.snapshot` (187 -> 157). DBI moves
  from 1.647, which carried 11 CPANSA advisories, to 1.653; URI, HTTP::Date,
  and List::SomeUtils::XS also leave vulnerable versions. Security floors for
  those transitive dependencies are now declared in `cpanfile`, and
  `cpan-audit` reports no open advisories apart from the two unfixed
  Mojolicious default-secret advisories, which `GPFORUM_SESSION_SECRET`
  enforcement already mitigates.
- Raised runtime CPAN floors to current secure releases, including
  Mojolicious 9.49, Cpanel::JSON::XS 4.52 (CVE-2026-9334,
  CVE-2026-9516), Crypt::Argon2 0.032, DateTime 1.67, DBD::Pg 3.21.2,
  and Mojo::Pg 5.0.
- Rejected non-hash JSON in `Outbox::ClaimedMessage` so Cpanel::JSON::XS
  4.42+ `allow_nonref` cannot treat scalar payloads as outbox events.

### Added

- **`sudo gpforum setup` links `gpforum` into `/usr/local/bin`**, so the
  commands it offers next run from any directory; a `gpforum` already there
  that is this checkout's is left as it is, another is named with the `ln
  -sf` that replaces it.

- **`sudo bin/gpforum setup` installs the dependencies first** on a fresh
  clone, as `make install-deps-production` does (`install-deps-postgres`'s
  set for `--environment development`), saying what it runs, then goes on as
  setup; `--dry-run` says so and installs nothing. `script/bootstrap-deps
  --for-setup` is what it runs.

- **`gpforum upgrade`** prints the three commands that upgrade the forum,
  written for this host: the code and its dependencies, then `gpforum migrate`
  and the restart this host's service manager needs, then `gpforum doctor
  --upgrade`, with the backup to take before them. `gpforum help` lists it
  under Maintain, and `docs/ops/upgrade.md` gives the same lines.

- `gpforum setup` sets a host up in three questions (ADR 0122): the public
  address, the database and how mail leaves; Enter takes each suggestion. As
  root on Linux or FreeBSD it makes the `gpforum` account and its uploads
  directory; it writes the environment file (0640, `root:gpforum` as root)
  with new secrets, none printed; it makes the role and database as
  PostgreSQL's superuser, sending the password only as a SCRAM verifier, or
  prints the two `psql` commands; it migrates and names the next steps. Run
  again, it changes nothing and says so, and it replaces a setting only when
  asked or with `--force`.

- `gpforum service print [systemd|rc|launchd|nginx|caddy]` prints the service
  files for this host -- its code directory, environment file, public name and
  listen address, the outbox worker on every OS -- and the commands that copy
  and start them (ADR 0123). It installs nothing; `--to DIR` writes them to a
  directory to read first. `gpforum doctor` offers it for a missing or changed
  unit and names this OS's nginx directory.

- `gpforum backup [--to DIR]` dumps the database (`pg_dump -Fc`) and archives
  the uploads with a manifest of versions, sizes and SHA-256 into a dated
  directory only its owner reads; `gpforum restore --check DIR` checks that a
  backup can be restored, without restoring it.

- **The main pages are warmed before a pre-forking server forks.** Under
  Hypnotoad (or `prefork`) the manager renders the home page, the category
  index, the login and registration forms and the newest thread with its
  category before it forks, so every worker starts with the templates
  compiled, the statements prepared and the memos filled: the first request
  to a worker took 95 ms for the home page and takes 21. One line in the
  log says what was warmed. `GPFORUM_WARMUP_ENABLED=off` turns it off; a
  single process (`daemon`, morbo) is not warmed. ADR 0121.

- `gpforum doctor` checks a forum the way an operator would, one line each,
  in Italian or English: every setting, as the service checks them at its
  start; the host's limits; the database, with a refused connection, a wrong
  password or a missing database said in one sentence; migrations pending
  and budgets that drifted; the rest of the readiness report; the outbox
  worker, by the age of the oldest message nobody sends; mail-check's dry
  run and antivirus-check's findings; the service files installed against
  this release's `deploy/`, the web service and the outbox worker running
  the code on disk, and systemd's timers; and the public address over TLS.
  Under each problem a `Fix:` line names the variable, the file and the
  command, and the last line counts what there is to fix. `--json` gives
  the same findings; it exits 1 when something failed.
  `gpforum doctor --upgrade` checks what an upgrade leaves behind: the
  settings, the modules this release needs for the Perl running it, pending
  migrations, unit files that differ from the release's and services still
  on the code before. `docs/ops/doctor.md` explains every line, and
  `docs/ops/upgrade.md` is the upgrade in three commands ending with it.

- `gpforum status` prints the running service's whole `/health/ready`
  report, one line per check with the fix under each problem, asked with
  the metrics token from the environment file: no curl, token or jq. It
  asks where Hypnotoad listens, not the proxy, says when the service does
  not answer or keeps its report from a token it does not hold, and exits 0
  when the service is ready.

- `gpforum admin create --email --username` makes the forum's owner from the
  shell: an account active and verified at once, bound to the owner role,
  audited as `admin.bootstrap_created`. It asks for the password twice
  without echo, or reads it with `--password-stdin`, and ends with where to
  sign in. `gpforum admin grant EMAIL|USERNAME` makes an existing member the
  owner, and says when that account cannot sign in yet. The first
  administrator needs neither psql nor a mail server.
  `bin/gpforum-admin-bootstrap --user-id` keeps working, as `gpforum admin
  grant --user-id`.

- `gpforum`, the front door (ADR 0120). `bin/gpforum` runs from anywhere,
  through a symlink on the `PATH` too, and re-runs itself under Carton when
  `local/` is not on `@INC`: `gpforum migrate` where the documents said
  `script/gpforum-carton exec perl -Ilib bin/gpforum-migrate`. It reads the
  environment file the service reads -- `/etc/gpforum/gpforum.env`,
  `/usr/local/etc/gpforum/gpforum.env` on FreeBSD,
  `$(brew --prefix)/etc/gpforum/gpforum.env` on macOS, or `--env-file FILE`
  -- under what the shell sets, so a command typed by hand sees the
  service's settings without `set -a; . /etc/gpforum/gpforum.env`. Its help
  is its own, in Italian or English: the verbs grouped as Set up, Run,
  Check and Maintain, then which file it read; `gpforum help --all` adds the
  benchmarks, drills and Mojolicious's commands, and `gpforum help VERB` the
  verb's usage. Every `bin/gpforum-*` command answers to a verb
  (`gpforum partitions`, `budgets`, `outbox`, `dead-letters`) and to its old
  name, and `gpforum start --foreground` is the development server. A
  mistyped verb is answered with the nearest one.

- **Relative times** ("3 minutes ago", "3 minuti fa") in a `<time>` element
  whose title keeps the absolute local time, per the reader's locale and zone,
  without JavaScript. Cached anonymous pages never carry a signed-out
  member's time zone.

- **Badge failures reach the log and `/metrics`**: `notifications.badge_failures`
  and `last_badge_error`; each message is logged at most once every five
  minutes per process, without the SQL, bind values or a DSN password.

- **`make fresh-checkout`** clones the current commit into a temporary
  directory and runs the README quick start and each step of `make check`
  there, timing each; with `GPFORUM_DATABASE_DSN` it also creates a plain
  role and database and runs the integration tier. The README now says the
  database commands need a running PostgreSQL and how to start one.

- **Replication on `/metrics`** (ADR 0058): on a primary, each standby's
  state, replay lag and bytes behind, and each slot's retained WAL; on a
  standby, the age of its last replay. `/health/ready` gains a
  `replication_slots` check, degraded when an inactive slot keeps more than
  1 GiB of WAL. Grant `pg_read_all_stats` to see standby details.
- **The plan gate checks deep and signed-in pages**: halfway down the longest
  thread, the largest category and the latest threads; it fails when a deep
  page filters more rows than its first page or ignores its cursor.

- **`--json` on the state-reporting commands** (`migrate`,
  `partition-maintenance`, `platform-check`, `query-budget`,
  `scheduled-jobs`, `search-rebuild`, `outbox-dispatch`,
  `dead-letter-replay`): one JSON object per line with a `status`, flushed as
  printed; exit codes unchanged. `gpforum-migrate --check` exits 1 when
  migrations are pending or an applied file changed.

- **Fingerprinted static assets** (quality program 7.7): stylesheet and icon
  URLs carry `?v=<12 hex digits of the file's SHA-256>`, taken at startup; a
  current digest is served `public, max-age=31536000, immutable`, a bare or
  stale one `max-age=3600`. The shipped nginx and Caddy configs match.

- **`/admin/settings`**: every configuration variable with its effective
  value and whether it comes from the environment or the default. Secrets
  show only as set or not set, and a password inside a DSN or URL is
  redacted; the page says to edit `/etc/gpforum/gpforum.env` and restart.
- **Send test message** (`/admin/settings`): one message through the
  configured transport to the signed-in admin's own address only, audited
  as `admin.mail_test_sent`, with the transport's error shown without
  credentials, stack traces or the recipient.
- **Run antivirus check** (`/admin/settings`): the check
  `bin/gpforum-antivirus-check` runs, from the console, audited as
  `admin.antivirus_checked`.
- **`docs/ops/console-and-cli.md`** maps every `bin/` command to its console
  page or says why there is none; a test fails when a command is missing or
  a named route is not registered.

- **Migrations can build indexes without stopping writes.** A migration
  whose first line is `-- gpforum:no-transaction` runs one statement at a
  time, so `CREATE INDEX CONCURRENTLY` works; the runner sent every file
  whole, inside a transaction, so every index so far locked its table's
  writes while it built. From migration 049 on, an index on an existing
  table must be built this way (`t/209-migration-indexes.t`).

- **A streaming standby and failover** (ADR 0112,
  `docs/ops/standby-and-failover.md`): the standby follows through a
  replication slot, `GPFORUM_DATABASE_DSN` names both servers with
  `target_session_attrs=read-write`, and failover is a manual promotion.
  `script/standby-drill` (`make standby-drill`) rehearses it on throwaway
  clusters: on PostgreSQL 18.6 a write reached the standby in about 50 ms,
  promotion took about 160 ms, and a connected application reconnected to
  the new primary by itself.

- **`/health/ready` names the runbook for every check that is not ok**
  (`runbook`, a path in the repository), so a degraded or failed check says
  what to do about it.

- **`docs/THREAT_MODEL.md`**: what GPForum protects, from whom, the trust
  boundaries, and at each one the mitigation and the test that pins it, with
  the residual risks said plainly.

- **Search and cache maintenance on the console.** `/admin/jobs` shows
  whether search is behind and how the last console rebuild went, rebuilds
  the index through the outbox (one batch per message, retried like any
  other work) and purges the public page cache; both are audited.
- **A refused permission says which.** A permission refusal (403) from the
  admin, moderation or privacy console logs, at info, the permission
  checked, the user and the binding that would have granted it, so an
  operator can see why a moderator is refused on a category. A user's
  bindings page now shows each binding's space.
- **`bin/gpforum-search-rebuild`** (and `script/search-rebuild`): rebuilds
  the search index from the forum's threads and posts, in batches, removing
  documents whose source is gone, deleted or hidden; `--status` reports how
  far search may be behind. See `docs/ops/search-rebuild.md`.
- **Per-member time zones.** Settings has a time zone field; dates and
  times across the forum are shown in the member's zone, or the forum's
  default, and every time names its zone ("14:00 CEST"). Migration 044 adds
  `users.preferred_timezone`.
- **Partition horizon alert.** `/readyz` reports `partition_horizon` as
  degraded when any partitioned table has less than 45 days of partitions
  ahead, or when rows have spilled into a DEFAULT partition. Point readiness
  alerting at it; the fix is `bin/gpforum-partition-maintenance --apply` in a
  maintenance window (`docs/ops/partition-maintenance.md`).
- **Replay dead letters** (ADR 0056), from the Replay button on
  `/admin/jobs` or `script/dead-letter-replay --id ID`; `--list` reviews
  them from the shell. A replay enqueues a new outbox message for the same
  event and envelope with a fresh retry budget; the cancelled message and
  the dead letter stay as evidence, each dead letter replays once, and the
  audit log records it as `outbox.dead_letter_replayed`. It works for the
  thirty days a dead letter is kept, after retention has purged the
  cancelled message. See `docs/ops/dead-letters.md`.
- **Admin audit viewer.** Filters by actor, action, target, correlation id
  and a UTC date window, and pages to older entries with a stable keyset
  cursor (ADR 0079). A filter value of the wrong shape is a 400 naming the
  field; a target id that was not a UUID used to be a 500.
- Add `script/bootstrap-deps --rebuild-local` to rename an incomplete or
  foreign-Perl `local/` to `local.rebuild.<epoch>` before Carton reinstall
  (still never `rm -rf local/`). Helps Cloud Agent / operator hosts where a
  partial `local/` leaves modules like `Const::Fast` missing.
- Add operator `script/staging-host-verify` / `bin/gpforum-staging-host-verify`
  and `docs/ops/staging-host.md`: non-destructive staging bring-up verify
  (in-repo deploy/runbook artifacts; optional `--env-file` key presence with
  values redacted, `--systemd` `is-active`, `--base-url` health/metrics).
  Documents the evidence archive commands for mail-check, stress-load, and
  staging drills. Wired into `docs/ops/private-beta-checklist.md`. Optional
  `make staging-host-verify`; not part of default CI. Does not install units
  or claim private-beta readiness.
- Add `script/gpforum-macports-env` for macOS MacPorts operators: detect
  `/opt/local` PostgreSQL client bins, print `export PATH=...` lines, and
  optionally verify `psql` / `pg_dump` / `pg_config`. No-op skip on Linux CI.
  Accept MacPorts `/opt/local` perl as system Perl in
  `script/gpforum-system-perl` (still refuse perlbrew / plenv / asdf).
- Add operator-runnable `script/gpforum-mail-check` / `bin/gpforum-mail-check`
  to prove identity mail config for `test` / `smtp` / `sendmail` transports
  (dry-run Test delivery, SMTP TCP probe without leaking passwords, sendmail
  binary check, optional `--send`). Document in `docs/ops/mail-check.md` and
  `docs/DEPLOYMENT.md`. Optional `make mail-check`; not part of default CI.
- Add operator-runnable `script/stress-load` / `bin/gpforum-stress-load` with
  profiles `smoke` / `100` / `500` / `1000` concurrent request slots against a
  running Hypnotoad/GPForum `--base-url`, JSON/human evidence, and
  `docs/ops/stress-load.md`. Optional `make stress-load` /
  `make stress-load-dry`; not part of `make check` or default CI.
- Add `script/staging-drill` / `bin/gpforum-staging-drill` and
  `docs/ops/staging-drills.md` so operators can rehearse fresh migrate,
  upgrade-from-previous, and `pg_dump`/`pg_restore` on throwaway databases
  with pasteable pass/fail evidence. Attachment files under
  `var/attachments` remain outside the dump/restore scope; full
  nginx/systemd deploy stays a manual runbook. Optional `make staging-drill`
  is documented and is not part of default CI.
- Authors can restore their own soft-deleted thread on
  `POST /t/:thread_id/restore`. The store clears `deleted_at`/`deleted_by`
  and emits `thread.undeleted` in one transaction. Search, feed, cache, and
  realtime treat it like a visible thread again. Reputation does not apply
  `thread.restored` credit. The author still sees the deleted thread on the
  category listing and thread page. HTML writes set a success flash and
  redirect to the thread. JSON returns `restored`. Live, hidden, locked, and
  foreign threads are rejected.
- Authors can restore their own soft-deleted post on
  `POST /p/:post_id/restore`. The store clears `deleted_at`/`deleted_by`
  and emits `post.undeleted` in one transaction. Search, feed, cache, and
  realtime treat it like a visible post again. Reputation does not apply
  `post.restored` credit. HTML writes set a success flash and redirect to
  the post permalink. JSON returns `restored`. Live, hidden, locked, and
  foreign posts are rejected.
- Authors can soft-delete an attachment linked to their visible post on
  `POST /p/:post_id/attachments/:attachment_id/delete`. The store writes
  `attachment.deleted` in one transaction. Already-deleted rows replay.
  HTML writes set a success flash and redirect to the post permalink.
  JSON returns `deleted`. Non-authors receive `403`.
- Members can mark the whole notification inbox read on
  `POST /notifications/read-all`. HTML writes set a success flash and
  redirect to `/notifications`. JSON returns `all_read` with
  `marked_count`. An empty inbox is success. JSON single-row mark-read is
  unchanged.
- Public SSR pages at `/legal/terms`, `/legal/privacy`, and `/legal/cookies`
  describe how this software handles terms, stored data, export/deletion,
  and cookies. The footer links them. The sitemap includes the three URLs.
  Copy is i18n catalog text, not counsel-reviewed instance policy.
- Moderators can hide and restore a whole thread on
  `POST /moderation/threads/:thread_id/hide` and
  `/restore`. `thread.hidden` removes the thread search document, post
  search documents in that thread, and feed rows, and applies a reputation
  penalty to the thread author. `thread.restored` reindexes, reprojects the
  feed, and restores the penalty. Hide keeps `locked_at`. HTTP writes mint
  `command_id` like lock/unlock.
- A lost HTTP response can be retried with the same `command_id`. Reply,
  thread, report, hide, and export return the original resource and do
  not insert a second row.
- Authors can move their own threads to another category.
  `PostingWorkflow->move_thread` updates `category_id`, increments version,
  and emits `thread.moved` with the previous category. Locked, hidden,
  deleted, foreign threads, and missing destinations are rejected.
  `POST /t/:thread_id/move` is CSRF-protected, rate limited, and idempotent
  via `command_id`. Search reindexes, cache invalidates both categories,
  and realtime `thread.update` fires; feed, reputation, and notifications
  do not.
- Authors can soft-delete their own threads. `PostingWorkflow->delete_thread`
  stamps `deleted_at`/`deleted_by`, increments version, and emits
  `thread.deleted`. Locked, hidden, already-deleted, and foreign threads are
  rejected. `POST /t/:thread_id/delete` is CSRF-protected, rate limited, and
  idempotent via `command_id`. Search removes the thread document and post
  documents in that thread, feed removes the thread item and post items,
  cache invalidates, and realtime `thread.update` fires; reputation and
  notifications do not. Moderation hide remains a separate
  `moderation_state` path. HTML clients redirect to the category.
- Authors can edit their own thread titles. `PostingWorkflow->edit_thread`
  updates `title`/`slug`, increments version, and emits `thread.updated`.
  Locked, hidden, deleted, and foreign threads are rejected.
  `POST /t/:thread_id/edit` is CSRF-protected, rate limited, and idempotent
  via `command_id`. Search, cache, and realtime `thread.update` consume the
  event; feed, reputation, and notifications do not fire again.
- Authors can soft-delete their own visible posts. `PostingWorkflow->delete_post`
  stamps `deleted_at`/`deleted_by`, decrements the thread reply counter, and
  emits `post.deleted`. Locked threads, hidden posts, already-deleted posts,
  and non-authors are rejected. `POST /p/:post_id/delete` is CSRF-protected,
  rate limited, and idempotent via `command_id`. Search, cache, feed, and
  realtime `thread.update` consume the event; reputation and reply
  notifications do not fire. Moderation hide remains a separate `post.hidden`
  path.
- Authors can edit their own visible posts. `PostingWorkflow->edit_post`
  appends a `post_bodies`/`post_revisions` pair, points the post at the new
  revision, and emits `post.updated`. Locked threads, hidden/deleted posts,
  and non-authors are rejected. `POST /p/:post_id` is CSRF-protected, rate
  limited, and idempotent via `command_id`. Search, cache, feed, and
  realtime `thread.update` consume the event; reputation and reply
  notifications do not fire again.
- Wired `FeedProjector` and `ReputationLedger` onto the existing outbox
  worker path. Created posts and threads now project into `/feed` for the
  author and thread subscribers, and posting, hide/restore, and suspension
  events update trust snapshots instead of leaving them at registration
  defaults.
- Added a oneshot `gpforum-scheduled-jobs` command, hourly systemd timer,
  and launchd sample so expired sessions, rate-limit buckets, identity
  tokens, completed outbox rows, and dead letters are deleted in bounded
  batches. The same run calls attachment orphan cleanup and
  `PartitionLifecycle` policy/evidence only (no app-owned
  `CREATE TABLE ... PARTITION OF`). See `docs/ops/scheduled-jobs.md`.
- Forum post bodies labeled `markdown` now render a safe subset (emphasis,
  http/https/mailto links, quotes, fenced code) through
  `Service::Forum::BodyRenderer` at compose time and in post presenters.
  Source is escaped before markup is added, so script tags and unsafe URLs
  stay text.
- Delivered private-beta identity mail for password reset, email change,
  and registration verification through an injectable `Email::Sender`
  mailer. Pending accounts no longer receive a session until the
  verification token is confirmed, and the login page links to forgot
  password. `Email::Address::XS` 1.05 is a declared runtime pin so
  `Email::Sender::Simple` can load.
- Added versioned operational profiles for development, staging,
  production-small, and production-medium, plus a partition lifecycle policy
  for monthly planning, retention detach, archival states, and restore
  evidence.
- Added public discovery and syndication boundaries for canonical URLs, safe
  metadata, robots.txt rules, sitemap entries, feed items, and architecture documentation.
- Added privacy rights operation boundaries for deletion requests, erasure jobs,
  retention legal holds, staff review, and DBIx::Class mapping coverage for the
  existing platform governance tables.
- Added plugin extension boundaries for manifest validation, registry
  lifecycle, named hook dispatch, observable failure recording, and PostgreSQL
  migration coverage.
- Added import/export portability boundaries for validated import manifests,
  dry-run jobs, legacy id mapping, import failure reporting, privacy-aware
  export manifests, and PostgreSQL migration coverage.
- Added admin authorization management boundaries for role catalogs, scoped role
  bindings, permission review, and audit-backed role changes.
- Added moderation review boundaries for reports, reversible moderation actions,
  suspensions, audit-backed moderation changes, and admin audit browsing.
- Added advanced community feature boundaries for mention extraction,
  bookmarks, reputation ledger events, trust score snapshots, and rebuildable
  user feed projections.
- Added operations hardening boundaries for rate limiting, metrics snapshots,
  runbook validation, runtime sizing validation, and a JSON metrics endpoint.
- Added attachment upload intent, validation, lifecycle persistence, links,
  variants, scanning hook, media processing hook, and PostgreSQL migration.
- Added bounded keyset pagination contracts for category thread lists and
  thread post lists, including limit-plus-one fetching, stable cursors, and
  pagination metadata.
- Added process-local realtime websocket boundaries for authenticated
  connections, authorized channel subscriptions, thread updates, notification
  badge broadcasts, and explicit polling fallback.
- Added PostgreSQL-native search service boundaries for document building,
  indexing, rebuild, permission-aware querying, autocomplete, lag observation,
  and worker handoff.
- Added notification subscriptions, preferences, inbox projection, read state,
  and fanout services.
- Added worker phase boundaries, outbox dispatch, projection tracking, and
  platform governance migrations.
- Added core identity/session, forum write, event/audit, and projection schema
  foundations.

### Changed

- **The README carries the production path**: the `apt` line, then eight
  commands from the clone to a signed-in owner behind TLS on Debian or
  Ubuntu -- the clone, `sudo /opt/gpforum/bin/gpforum setup`, the units into
  place and started, the certificate, the nginx site into place and
  reloaded, `admin create`. DEPLOYMENT's install drops `cd`, `make
  install-deps-production`, the link, the copies and the `rm` of the
  default site, and no longer sends mail over TLS to
  `libio-socket-ssl-perl`, which the dependencies install.

- **`gpforum service print --to` puts the files in place**: given the
  directory the host reads them from -- `/etc/systemd/system`,
  `/Library/LaunchDaemons`, `rc.d`, nginx's `sites-enabled` -- it writes its
  own names there and touches nothing else, and the steps after it are the
  reload and the start, one line under systemd (`daemon-reload &&
  enable --now`) and one `launchctl bootstrap` for every plist. Any other
  directory still holds only its files, to read before a `cp`. The nginx
  site goes straight into Debian's `sites-enabled` (no link, and the default
  site stays), and is refused before its certificate is there. The steps
  begin with the packages a missing nginx, certbot or Caddy needs (`apt`,
  `pkg`, `brew`) and, on FreeBSD and macOS too, the certbot command for the
  forum's name; FreeBSD's site names certbot's `/usr/local/etc/letsencrypt`.
  On macOS, `sudo gpforum setup` makes the `gpforum` account with `dscl`,
  under the highest id below 500 that no user and no group has, and
  `gpforum doctor` says when the services' account is missing.

- **`gpforum setup` asks less and says more.** An answer typed at the
  prompt replaces what the file has with no `Replace it? [y/N]` after it:
  typing it was the say-so (an option, `--yes` and `--force` keep the
  question or its refusal). Its `Then:` line offers `gpforum service print`'s
  own first step, the files written with `--to` (`sudo gpforum service print
  systemd --to ~/gpforum-systemd`), where a bare print wrote every unit to the
  terminal first. A database it cannot use is said under the `database:`
  label `gpforum doctor`'s line has, and the owner's step reads `gpforum
  admin create --email EMAIL --username NAME`, a placeholder that does not
  look runnable. `gpforum restore --check` given the directory of the backups
  opens with `! manifest: DIR holds backups, and is not one itself`, then
  offers the newest, where it opened with a `✗`. `make install-deps-production`
  and `make install-deps-postgres` end with the command that comes next.

- **The service files run `bin/gpforum` alone**, never `script/`: the web
  unit checks the host with `gpforum os-preflight --strict --json` and starts
  Hypnotoad with the new `gpforum start --service` (`--service --foreground`
  under launchd and FreeBSD's daemon(8)); the outbox worker and the jobs run
  `gpforum outbox`, `gpforum scheduled-jobs` and `gpforum partitions`. The rc
  scripts and the crontab put `/usr/local/bin` on their `PATH`. Units copied
  before keep starting; `gpforum doctor` says they differ from the release's
  and prints them again.

- **A metrics-token rotation needs no restart.** The running service reads
  `GPFORUM_METRICS_TOKEN` and `GPFORUM_METRICS_TOKENS` from its environment
  file again. It makes one `stat` per token check, and reads the file only when
  it changed (ADR 0124). `gpforum secret rotate metrics` and its `--finish`
  name no restart: rotate, give the scrapers the new token, finish. A file the
  service cannot use keeps the tokens it accepted, and is logged once:
  unreadable, malformed, writable by another account, or without a token.
  `/metrics` never opens to anyone. The session secret keeps its restart.

- `gpforum outbox`, `partitions`, `budgets`, `migrate --check` and
  `scheduled-jobs` answer in sentences in the operator's language (the
  `bin/gpforum-*` names keep their `key=value` lines; `--json` is unchanged).
  Bare `gpforum budgets` checks, with a verdict. `gpforum partitions` refuses
  a database the migrations have not reached. `gpforum secret rotate` on a host
  without service files points to `gpforum service print`. Runbooks and the
  guide type `gpforum` verbs; the install guide's account, directory, role,
  database, template, secrets and migrate steps are now `sudo gpforum setup`.

- `gpforum outbox` (`gpforum-outbox-dispatch`) prints `acknowledged=` and
  `lost=` after the four counts it printed, and `--json` carries them: the
  messages written `done`, and the claims another worker took before this
  one wrote the outcome. `lost` was in the dispatcher's summary since each
  claim is renewed on its own, but the command dropped it, so a batch that
  lost messages to another worker read as one that delivered them.

- **The last per-request statement of the thread page is prepared, and a
  post's row is read in one step.** The attachments of a page's posts were
  the one statement DBIx::Class still built on every request (an IN list
  of the page's post ids); `PreparedQuery` now binds a list once per
  element, kept by page size, so the page's eight statements are all
  prepared. A post's fifteen columns are read with one `get_columns`
  instead of fifteen dispatched `get_column` calls. The search page's
  "more results" link writes its parameters in one order, so the page is
  the same bytes on every render. ADR 0121.

- `GPFORUM_SMTP_TLS=starttls|implicit|off` replaces `GPFORUM_SMTP_SSL`, which
  is still read and logged with its replacement. Staging and production refuse
  a `GPFORUM_PUBLIC_BASE_URL` or `GPFORUM_MAIL_FROM` under the reserved example
  domains or `.invalid`, and production refuses `GPFORUM_MAIL_TRANSPORT=test`.
  `GPFORUM_FORUM_READ_RATE_LIMIT` is a validated setting shown on
  `/admin/settings`; `GPFORUM_LOCAL_CACHE_MAX_ENTRIES` defaults to 4096, so
  every profile passes readiness; the environment template states the quoting
  rule; the settings page names both services to restart.

- The front door keeps the operator on the file it read: every command it
  offers carries `--env-file FILE`, the flag is accepted after the verb too,
  and a setting the shell exports is reported against the shell, not the file.
  `gpforum mail-check` prints sentences (`--json` for evidence);
  `gpforum start --foreground` on a busy port says so and exits 1;
  `gpforum secret rotate` keeps a previous secret only when the service could
  have started with it, and warns when the file is readable by every account.
  `gpforum doctor` warns about such a file too, counts claims a killed worker
  left behind, tells a plain-HTTP port from a refused certificate, and
  `doctor --upgrade` reports a missing module instead of dying on it. The
  FreeBSD crontabs go through `bin/gpforum`, so cron reads the environment
  file.

- **A page renders in about half the time, byte for byte the same.** The
  signed-in thread page (25 posts, 79 KB) went from 24.7 to about 14 ms in
  process, the category page from 15.1 to about 12 and the home page from
  17.5 to about 12, the anonymous cached page from 2.7 to 1.8; the HTML and
  the headers of fourteen pages, anonymous and signed in, are unchanged. The
  CSRF token is masked once per response rather than once per form (the
  thread page has 33, and each mask opened `/dev/urandom`); formatted dates,
  rendered post bodies, route paths and asset URLs are kept once computed;
  a plain message is read from the i18n table in one step; the viewer's
  read state, bookmark, subscription and session are looked up through
  prepared statements. Responses are gzipped at zlib level 3 through
  `Compress::Raw::Zlib` (0.7 ms for the thread page where level 6 through
  `IO::Compress::Gzip` took 1.6; 900 bytes more on the wire). ADR 0121.

- `gpforum staging-host-verify --env-file` checks every setting in the file
  as the service checks them at its start -- the checks `gpforum doctor`
  reports -- under the file's `GPFORUM_ENV`, else `production`: it passed a
  file that set its four keys, and the service then refused to start. Each
  problem is in the evidence as its variable and sentence, without the
  value of a secret.

- The visual identity is now a text-free symbol: two open arcs and one amber
  node, with light and dark SVG variants and a tighter favicon crop. The
  README keeps its hero and presents features and setup more concisely,
  with CI, runtime and license badges.

- `make system-perl` and `script/system-preflight` end with a verdict, in
  Italian or English: a check mark or a cross for the Perl, Carton,
  pg_config, whether the dependencies are installed and, once they are,
  what os-preflight finds, each problem with its fix, then a count;
  `make system-perl` also names the next step. `perl -V` is printed only by
  `script/gpforum-system-perl --preflight --verbose`.
  `system-preflight --help` prints its usage instead of running the check,
  and a production install no longer fails it for lacking perlcritic, a
  develop tool. A Perl the scripts refuse is said with the command that
  installs one on this operating system, and misuse exits 2.

- `gpforum migrate` brings the database up to date in one command: the
  migrations, the partition window and the endpoint query budgets, so a
  fresh install's `/health/ready` is ok without a step of its own. It says
  so in one line, then the next step: the forum's owner when it has none, a
  restart after a change in staging and production, `gpforum start
  --foreground` in development. `--plan` (or `--dry-run`) lists the pending
  migrations from the database; `--quiet` prints nothing unless something
  failed. `bin/gpforum-migrate` is its alias and still plans without
  `--apply`.

- A command line a command cannot read is answered with what was wrong
  first -- "--aply is not an option of this command.", "--limit takes a
  whole number above zero, not 'ten'." -- and the usage once, in the
  operator's language; `admin-bootstrap` printed its usage twice and no
  reason. Through the front door, help and failures name the verb typed
  (`gpforum partitions`), not the `bin/` entrypoint. A configuration report
  ends with the environment file the command read, where it named the
  template.

- `gpforum antivirus-check` without clamd says so once -- "clamd does not
  answer at" its socket, and the operating system's reason -- where it
  repeated one connect error eight times, and follows it with the commands
  that install clamd and start it on this host (apt and systemctl, pkg and
  sysrc, or Homebrew) and `GPFORUM_ANTIVIRUS=none` as the alternative. Old
  signatures come with the command that starts freshclam, and scanning
  turned off is a warning once deployed. In Italian or English.

- `gpforum mail-check --human` says what a dry run proved and what it did
  not: a sendmail program found shows "a program is there, not that mail
  leaves this host", and an SMTP port that answers is not a server that
  takes the message; each is followed by the `--send --to` command that
  proves delivery. Deployed with sendmail, it adds that a VPS often cannot
  send on port 25 and needs SPF and a PTR record, so relay through a
  provider's SMTP. A failure names the fix: a mail server to install, or the
  smtp settings and where to set them. `docs/ops/mail-check.md` says the
  same, lists the `log` transport and gives development's default as `log`.
  The `key=value` lines are gone; `--json`, still the default, is unchanged.

- `gpforum os-preflight` speaks in sentences, in Italian or English: a
  check mark for the host, its web processes and its open-file limit, `!`
  for a warning and a cross for a failure, each problem with a `Fix:` line
  that names the setting and where to set it (or the unit's
  `LimitNOFILE=`), and a closing count. It no longer reports the retired
  worker and realtime process counts. A script that read its `key=value`
  lines reads `--json`, which keeps the whole report; each check that is
  not ok now carries the `key` and `parameters` of its sentence. Under
  `--strict --json`, what the service files run before a start, stderr
  carries the same lines for the journal, and settings that do not parse
  are reported there once: the JSON says `fail` with the problems'
  sentences as its `error` and the `variables` they name, where it used to
  write the whole report three times.

- The README quick start reaches a signed-in administrator on a laptop
  without a mail server: the outbox worker, run once, prints the
  verification link the `log` transport writes. `docs/DEPLOYMENT.md`
  describes GlifiStore as the optional shared cache it now is.

- `deploy/gpforum.env.example` is the environment file to copy: the ten
  settings every installation decides, uncommented with a one-line comment
  each and a production example (a secret with the command that generates
  it), then every other setting by section, commented out at its default.
  It is generated from `GPForum::Config`'s settings table, and t/463 fails
  when the two differ; values a shell would split, such as the DSN, are
  quoted.

- Production never sends the `X-GPForum-DB-*` benchmark headers, even with
  `GPFORUM_BENCHMARK_QUERY_HEADERS=1` left in its environment: they told
  every client how many queries each page ran. Development and staging
  benchmarks keep them.

- A configuration GPForum cannot use is reported whole: every problem at
  once, each naming the variable to set with an example (a line to paste
  into the environment file, quoted when it holds a space), a "did you mean"
  for a mistyped choice or the command that generates a secret, then where
  to set them, ending in a newline. `bin/gpforum` and the service exit 78
  (EX_CONFIG) instead of 255, in Italian or English as `LC_ALL`,
  `LC_MESSAGES` or `LANG` asks (owner decision D13); the `bin/gpforum-*`
  commands print the same report, in the same language, and exit 1. The command line's words
  are a catalog of their own, `locale/cli/en.po` and `it.po`.

- `GPFORUM_WEB_PROCESSES` defaults to `auto`: as many web processes as the
  CPUs carry under `cap-to-cpu` (`GPFORUM_RUNTIME_MAX_WEB_PER_CPU` a CPU), at
  most 16. A number is still taken as it is. An operational profile's web
  floor is what the host carries when that is less than the profile's.

- GlifiStore is optional in every environment (owner decision D2): without
  `GPFORUM_GLIFISTORE_URL` each process keeps its own cache, and readiness's
  `shared_cache` check is `ok` with a note saying so. Development no longer
  assumes one at `tcp://127.0.0.1:7379`.

- Development's mail transport is `log` (owner decision D7): each message,
  link included, is written to the log -- standard error for the outbox
  worker -- instead of sent, so the README quick start verifies an account
  on a laptop without a mail server. `test` stays the test suite's, and
  `mail-check` knows `log`.

- A boolean setting reads `on`/`off`, `yes`/`no`, `true`/`false` or `1`/`0`.

- `GPFORUM_WORKER_PROCESSES`, `GPFORUM_REALTIME_PROCESSES` and
  `GPFORUM_OS_AFFINITY`, which had no effect, are retired: still read but
  never refused, so an old environment file starts whatever it holds for
  them, and the start logs one line for each that is set, saying to remove
  it. Readiness no longer holds the worker and realtime counts to the
  operational profile's floors, which failed production-medium once they
  were removed. `docs/DEPLOYMENT.md#retired-settings` lists them, and the
  guides no longer show them, nor a GlifiStore every host must run.

- A command that cannot use the database says so in one sentence, in
  Italian or English as `LC_ALL`, `LC_MESSAGES` or `LANG` asks, naming the
  setting to correct, the file the service reads it from and the command
  that fixes it, instead of DBIx::Class's own text: `Cannot reach PostgreSQL
  at 127.0.0.1:5432 (connection refused): start it with sudo systemctl start
  postgresql, or correct GPFORUM_DATABASE_DSN in /etc/gpforum/gpforum.env.`
  The same for a wrong password, a pg_hba.conf refusal, a host, role or
  database that does not exist, and a schema not migrated. Under `--json`
  the document's `error` keeps the original text and `explanation` carries
  the sentence. Run by hand without the service's environment file on a host
  that has one, the command adds `This command did not read
  /etc/gpforum/gpforum.env, which holds the service's settings: run it as
  docs/DEPLOYMENT.md shows.`, so a password refused for want of the file is
  not mistaken for a wrong one.

- `docs/DEPLOYMENT.md` opens with the whole install on Debian or Ubuntu, in
  eleven numbered steps: packages, the `gpforum` user and who owns
  `/opt/gpforum`, the database with its password, the environment file from
  `deploy/gpforum.env.example` with its owner and mode, how to make a secret,
  commands run as the service runs them, mail, antivirus, the units with the
  outbox worker and both timers, the certificate and nginx, and the first
  administrator. A production host installs with `make
  install-deps-production` only. The README quick start creates the role
  with `sudo -u postgres` and `--pwprompt`, as Debian needs.

- `GPFORUM_ATTACHMENT_ACCEL_REDIRECT=/internal-attachments/` is documented:
  nginx sends an authorized download itself. The guide used to say the
  header was not implemented.

- The FreeBSD rc scripts create `/var/log/gpforum` for the `gpforum` user
  before they start.

- `os-preflight --strict` stops a start only when a check fails, as
  `os-preflight` without it always did; a degraded check is reported and the
  service starts (owner decision D10). Under `--strict`, which the systemd
  units and the FreeBSD rc script pass, each check that is not ok is also
  written to stderr on a line of its own, such as `os-preflight: degraded
  recommended_worker_count: recommended worker count below configured
  threshold`, so the journal shows it outside the JSON report.

- Errors GPForum raises now have classes (ADR 0118), and the outbox
  classifies a failed handler by the failure type its class declares instead
  of guessing from the message. An invalid argument, invalid configuration or
  failed check (`GPForum::X::Argument`, `X::Config`, `X::Check`) is
  `permanent`: the message is cancelled at once instead of retried. That
  covers a search rebuild for an unknown entity type or stage, a breached
  `QueryBudget->enforce`, and a handler built without a collaborator it
  requires. A request over its query budget under
  `GPFORUM_QUERY_BUDGET_ENFORCE=1`, outside the server profiles, fails with
  `X::Check` too. A dependency that did not answer (`X::Unavailable`: clamd,
  the scanner command, Minion, a reply fan-out that dropped a recipient) is
  retried as `transport`, and its dead letter says so. Config, the cache
  stack, Keyset, OS::Filesystem, Log, Migration::Plan, Migration::Runner and
  MinionRegistrar raise these classes with their old messages; a migration
  file edited after it was applied raises `X::Check`. An exception's text is
  its message alone, so outbox `error_message`, log lines and an uncaught
  startup error no longer end in " at FILE line N.".

- The stores recover a unique conflict only on the constraint they expect,
  asking `GPForum::X::Conflict->on`, and rethrow a conflict on any other
  index; several used to take any unique violation for the one they expected.
  Search documents accept their entity key or their primary key, which
  PostgreSQL names first when the same entity is inserted twice.

- Monthly partitions of `audit_log`, `event_log` and `notifications` roll
  forward with the date (ADR 0113, amending ADR 0012). `bin/gpforum-migrate
  --apply` creates the current UTC month and the next two after its
  migrations, under the configured `statement_timeout`; `--no-partitions`
  skips it, and a conflict or error exits 1 with the migrations applied. A
  daily timer runs `bin/gpforum-partition-maintenance --apply` between
  deploys; runs are serialised by advisory lock 4021970002, and one that does
  not get it reports `skipped=1` and exits 0 (migrate waits up to a minute
  first). Months are created with `CREATE TABLE ... (LIKE ...)` and `ATTACH
  PARTITION`, which holds the parent only in SHARE UPDATE EXCLUSIVE: no
  maintenance window. DEFAULT is still locked during each attach, so unpruned
  reads, and the event and audit writes that start with one, wait at most a
  0.5 s lock wait (retried five times) plus the scan of DEFAULT. Migration 049
  drops the past, empty partitions migration 038 named, one table at a time,
  keeping any that holds rows. The staging drill creates the window too.
  Detaching and dropping old months stays manual.

- ADR 0115 records that the translation catalogs are the gettext PO files,
  read at startup and looked up by key (`msgctxt`); it amends ADR 0021. The
  ADRs name the PostgreSQL integration tests that replaced the deleted store
  tests, and `t/00-load.t` loads every module added since.

- Removed `Attachment::UploadPipeline::cleanup_orphans`, which had no caller
  and could not delete files in production; the purge is
  `Attachment::Store::cleanup_orphans`, run by the scheduled jobs.

- `GPFORUM_OS_WORKER_PRIORITY=on` reports the action `supervisor-nice` and
  the policy `declared-for-the-supervisor`: nothing in GPForum calls
  setpriority, the supervisor applies the nice value.

- Translations are gettext PO files, `locale/en.po` and `locale/it.po`, which
  Poedit, Weblate and gettext's tools can open; `docs/i18n.md` describes the
  translator workflow. The catalogs are read once at startup, and a malformed
  file stops the application naming the file and line. A message left empty or
  marked fuzzy is shown in English (and reported to a `missing_key_logger`
  when one is set; `t/295` keeps the shipped catalogs complete); for a counted
  message one empty form is enough. Adding a locale also needs a migration that
  widens `users_preferred_locale_check`.

- The eight performance and database documents are now one,
  `docs/PERFORMANCE.md`: budgets, indexes and the plan gate, keyset pages,
  `CONCURRENTLY` migrations, query budgets, caching, search costs, profiling,
  OS tuning, and how to reproduce the evidence, re-measured on 2026-10-03
  (PostgreSQL 18.6, Perl 5.44). The old paths are gone; the May 2026 tables
  stay in git history (`git show 0d0ec4a:docs/PERFORMANCE_EVIDENCE.md`). The
  readiness check `query_budget_drift` points at
  `docs/PERFORMANCE.md#query-budgets`, which also says what
  `script/query-budget --sync` cannot fix: a stored budget for an endpoint the
  catalog no longer has used to stay `extra` until its row was deleted by
  hand; `--sync` now removes it (below).


- **Notifications, attachments and community stores are tested on
  PostgreSQL** (`t/integration/postgres-{notifications,attachments,community}.t`,
  over 550 assertions) instead of fake ORMs; concurrent-write recovery is
  tested against a real second connection. The fake had pinned two wrong
  results (a removed bookmark still listed, one member's feed showing
  another's items), now tested as correct.

- **Search runs under its own statement timeout and ranks a capped set**
  (quality program 8.10). `GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS` (2000) cancels
  a slow search, which then shows a degraded page instead of holding a web
  worker; `GPFORUM_SEARCH_CANDIDATE_LIMIT` (1000) ranks only the newest
  matches, walked through a new index, and the page says when it did.
  Migration 048 drops four partial search indexes no query could use
  (checked on 134 statements, 670 plans). It is not concurrent: on a large
  forum, apply it in a maintenance window.
- **A large thread's search work is bounded**: removing it deletes its
  documents 500 per transaction, title first; renaming, moving or restoring
  it reindexes 500 posts at once and the rest as
  `search.thread_posts_requested` outbox messages. The outbox dispatcher no
  longer sleeps between full batches.

- **Replies lock their thread with `FOR NO KEY UPDATE`.** A reader's first
  "mark as read" on a busy thread no longer waits for the replies in flight;
  replies are still numbered in commit order. The concurrent-reply test that
  `docs/MVP.md` listed as required before go-live now exists.
- **After a failed GlifiStore call, a process skips GlifiStore for 15
  seconds**, invalidations and the readiness ping included, so a hung server
  no longer stalls every request. `/metrics` shows `retry_after_epoch` and
  `stats.skipped`.
- **Deep pages read only the rows they show.** Every paged list (posts,
  threads, profiles, bookmarks, mentions, feed, moderation and audit
  history) bounds its sort column, which the index answers. Page 800 of a
  50,000-post thread read 39,008 rows (5.7 ms); it now reads five (0.03 ms).

- **A cached public page is served before its queries run**, and junk query
  parameters no longer mint cache entries (quality program 8.2). Pages past
  the first are not cached.

- **Removing a thread from the feeds no longer scans them per post.**
  `user_feed_items` could only be read by user, so each removed post read
  the whole table; migration 047 indexes it by item, and a thread's posts
  leave every feed in one statement.
- **Feed fan-out is one statement.** A new post reached its thread's
  subscribers with two statements each, in one ever longer transaction; it
  now reaches all of them with one `INSERT ... SELECT FROM unnest(...) ON
  CONFLICT` (8.7). 5,000 subscribers: 10,000 statements before, five now.
- **The header fits a phone.** It holds the brand, the navigation and the
  account links; the language and theme selectors moved to the footer's
  Preferences group. Below 1100px it is two rows, with the navigation on one
  line that scrolls sideways (110px tall on a 375px phone, from about 630px).
  The header no longer shows the member's internal id.
- Import job progress skips the row write when the stored counters already
  match.
- Plugin enable and disable skip the row write when status already matches.
- Reputation events that do not change trust level do not restamp the user
  row.
- Attachment scanning skips the object read when the row is already clean
  and available, or infected and quarantined. A failed scan still rereads.
- Media thumbnail processing skips the object read and variant write when
  the thumbnail already exists.
- Query-budget schema sync skips the row write when max queries,
  transactions, and notes already match.
- Already-failed projection offsets and already-ready, active, or failed
  generations skip the status rewrite.
- Projection offset progress skips the row write when `last_event_id`
  already matches.
- Feed projection skips the `user_feed_items` write when created_at, rank,
  and version columns already match.
- Search reindex of an unchanged thread or post document keeps the original
  `indexed_at` and does not rewrite the search row.
- Password reset to the same secret still consumes the token and revokes
  sessions, but does not rotate the credential.
- Email-change request for the member's already-verified address does not
  issue a token or queue mail.
- Password change skips credential rotation when the new secret already
  matches. Email-change confirmation skips the user restamp when the
  address is already verified on that account. The token is still consumed.
- Email verification confirmation skips the user restamp when the account is
  already active and `email_verified_at` is set. The token is still consumed.
- Post edit skips the new body, revision, version bump, and event/audit
  rows when the current `source_hash` already matches.
- Thread title edit and move skip the row write, version bump, and
  event/audit/outbox rows when title and slug, or category, already match.
- A thread read marker that does not advance the stored position keeps the
  original `last_read_at` and does not rewrite the state or delta row.
- Category update skips the row write, version bump, and event/audit/outbox
  rows when title, slug, description, visibility, and position are already
  the requested values.
- Locale, theme, and notification-channel preference writes skip the row
  update when the stored value is already the requested value. `updated_at`
  is not restamped.
- Bookmark and subscription save skip the row update when the target is
  already active with the same note or preference. Restore of a deleted,
  muted, or revoked row still clears those stamps.
- A second logout of an already-revoked session keeps the original
  `revoked_at` and does not restamp the row.
- Hide, restore, lock, and unlock mint and require HTTP `command_id` and
  replay from `command_log`. A lost hide, restore, lock, or unlock response
  retried with the same key does not persist twice. Store unique `command_id`
  remains the ActionStore guard. Command hashes include actor, target, and
  reason only. Store and command-log failures return HTTP 503 without
  leaking the exception.
- Thread read-marker writes mint and require HTTP `command_id` and replay
  from `command_log`. A lost `POST /t/:thread_id/read` retried with the same
  key does not persist twice. Command hashes include actor, thread, and
  position only. Store and command-log failures return HTTP 503 without
  leaking the exception.
- Assign, release, resolve, and reverse mint and require HTTP `command_id`
  and replay from `command_log`. A lost queue or reverse response retried
  with the same key does not persist twice. Command hashes include actor,
  target, and resolution or reason only. Reverse store arity stays four
  arguments. Store and command-log failures return HTTP 503 without
  leaking the exception.
- User suspend and suspension revoke mint and require HTTP `command_id`.
  A lost suspend or revoke response retried with the same key replays from
  `command_log` and does not persist twice. Command hashes include actor,
  target, and reason only. `revoke_suspension` store arity stays four
  arguments. Store and command-log failures return HTTP 503 without
  leaking the exception.
- Member thread, post, and profile reports mint and require HTTP
  `command_id`. A lost report response retried with the same key replays
  from `command_log` and does not insert a second row even when reason or
  details would otherwise hash differently. Command hashes include reporter,
  target, reason, and details only. Unique open/triaged reporter-target
  rows remain the store-level guard. Store and command-log failures return
  HTTP 503 without leaking the exception.
- Admin catalog, binding, and category writes mint and require HTTP
  `command_id`. A lost role, permission, attach, bind, revoke, or category
  response retried with the same key replays from `command_log` and does not
  persist twice. Command hashes include actor and target fields only. Store
  and command-log failures return HTTP 503 without leaking the exception.
- Thread bookmark and subscription writes mint and require HTTP `command_id`.
  A lost bookmark, bookmark-remove, subscribe, mute, or unsubscribe response
  retried with the same key replays from `command_log` and does not persist
  twice. Command hashes include actor, target, and note or preference only.
  Store and command-log failures return HTTP 503 without leaking the
  exception.
- Guest and signed-in HTML locale and theme selector writes set a success
  flash and redirect to `return_to`. JSON is unused on those cookie
  routes.
- Marking visible posts read on `POST /t/:thread_id/read` sets a success
  flash and redirects to the thread. JSON still returns the read-state
  payload.
- Registration, login, logout, password change, locale change, theme
  change, settings notification preferences, password-reset request,
  password-reset complete, email-change request, email-change complete,
  verification resend, and verification complete mint and require HTTP
  `command_id`. The same key replays from `command_log` without creating a
  second pending account, opening a second session, revoking a session
  twice, rotating a password twice, persisting a preference twice, issuing
  a second token, or consuming a token twice. Registration command hashes
  include email and username only. Login command hashes include the
  identifier only. Logout hashes include `session_id` and `user_id` only.
  Password-change hashes include `user_id` only, never the current or new
  password. Locale and theme hashes include `user_id` and the chosen
  value. Settings hashes include `user_id` and channel rows only. Token-
  consume hashes include the token only, never a new password. Token
  consume still uses `identity_tokens` uniqueness and `used_at` as the
  store-level guard. Guest locale/theme cookie writes stay cookie-only and
  omit `command_id`. Locale and theme on `POST /settings` mint their own
  keys so they do not share the settings `command_id`.
- HTML mark-read and attachment upload now set a success flash and
  redirect. Mark-read lands on `/notifications`; upload lands on the
  post permalink. JSON responses are unchanged.
- Privacy HTML writes now set a success flash and redirect. Member
  export and deletion land on `/privacy`; staff approve, hold, and
  erasure land on `/admin/privacy`. JSON responses are unchanged.
- Author HTML writes on forum now set a success flash and redirect.
  Creating a thread or reply, editing or deleting a post or thread,
  moving a thread, reporting, bookmarking, and subscribing land on the
  thread, category, or profile page with the matching catalog message.
  JSON responses are unchanged.
- Staff HTML writes on moderation and admin now set a success flash and
  redirect. Hide and assign land on `/moderation/reports`; role create lands
  on `/admin/roles`; category create lands on `/admin/categories`. JSON
  responses are unchanged.
- A classified permanent outbox failure cancels and dead-letters on that
  attempt. Cancelled rows are not claimed again. Operator review is
  `docs/ops/dead-letters.md`.
- `GPFORUM_MINION_ENABLED=1` fails closed when the Minion PostgreSQL
  backend is missing or unreachable. `bin/gpforum-outbox-dispatch` skips
  Minion and keeps draining the canonical outbox.
- Write routes map store and command-log failures to HTTP 503
  `service unavailable` without leaking DBI text. `create_reply`,
  thread report, moderation hide, and privacy export share that
  contract. Unexpected application errors still use HTTP 500.
- App PostgreSQL sessions set `statement_timeout` (15s),
  `idle_in_transaction_session_timeout` (10s), `lock_timeout` (3s), and
  `application_name=gpforum` on connect. Override with
  `GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS`,
  `GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS`, and
  `GPFORUM_DATABASE_LOCK_TIMEOUT_MS` (0 disables that timeout).
  `gpforum-migrate --apply` clears `statement_timeout` after connect so
  DDL is not capped at the web budget.
- Privacy export retries with the same `command_id` replay from
  `command_log` after the bundle is already completed. Open deletion
  requests are unique per resource (`pending`/`approved`/`held`); pending
  exports are unique per requester/subject/type/format; active retention
  holds are unique per resource while `ends_at` is null. A later
  `command_id` can still open a new export after complete.
  `DeletionWorkflow->hold_request` stays four arguments besides the
  invocant.
- Privacy export, deletion, approval, hold, and erasure HTTP writes now mint
  and require `command_id`. A second deletion request for the same open
  resource reuses the existing row; a second hold for the same active
  resource reuses the hold; a second export while one is still pending
  reuses that request. `DeletionWorkflow->hold_request` stays four
  arguments besides the invocant.
- Moderation assign, release, resolve, and reverse HTTP writes now mint a
  distinct `command_id` per form and require it at `Moderation::Workflow`.
  Hide/restore/lock/unlock already minted one shared command id; sibling
  queue forms no longer reuse it. Report and reverse stores keep
  state-based replay; `ActionStore::reverse_action` stays four arguments.
- Moderation hide, restore, lock, and unlock HTTP writes now mint and
  pass `command_id` the same way forum posting does, so ActionStore
  replay can fire on retry.
- Install and bootstrap now recognize CPAN distributions from `cpanfile`
  plus the `postgres` feature in `cpanfile.postgres`, and fetch only
  through Carton (`make install-deps` / `script/bootstrap-deps`) using
  `carton install --deployment`, `cpanfile.snapshot` pins, and the
  official MetaCPAN HTTPS mirror. Carton is resolved via
  `script/gpforum-carton` when it is not on PATH. The previous unpinned
  `cpanm --notest` PostgreSQL sideload is gone.
- Wired operational profiles into `platform-check` and readiness so undersized
  production floors fail the same gate as OS preflight and query-budget drift.

### Fixed

- **A metrics rotation in a file named with `--env-file` needs no restart
  either.** `gpforum secret rotate metrics` drops the restart whenever the
  installed web unit names the file it rotated, not only for the host's own
  file: the units `gpforum --env-file FILE service print` writes hand FILE
  to `bin/gpforum`, which tells the service in `GPFORUM_ENV_FILE`. The
  launchd jobs did not: they sourced FILE and then `bin/gpforum` read the
  host's file over it. Each plist printed for another file now passes it
  with `--env-file`. Before the services are installed, the step `secret
  rotate` offers is `gpforum service print --to` the directory the host's
  service manager reads, as setup offers it, not a bare `service print`.

- `gpforum setup` kept `GPFORUM_MAIL_FROM` at the old domain when the
  address changed. A sender it derived (`forum@` the address's host) now
  follows the new address, and setup says so (`GPFORUM_MAIL_FROM:
  forum@new.example, following the address (it was forum@old.example)`); one
  the operator wrote stays.

- `docs/ops/upgrade.md` said `gpforum migrate` names the restart. With
  nothing to apply, it names none. The upgrade's second line now ends with
  the restart whatever the migration finds, in the document and in `gpforum
  upgrade`.

- The README's Debian and Ubuntu package line installs `libssl-dev`, which
  Net::SSLeay (under IO::Socket::SSL) builds against: without it
  `make install-deps-postgres` stopped at Net::SSLeay.

- **`gpforum setup` finds a PostgreSQL superuser that takes a password, and
  says why none answered.** After libpq's own login (and, under sudo, the
  operator's) it tries the user and password the data source names, then
  `GPFORUM_DATABASE_USER` and `GPFORUM_DATABASE_PASSWORD` from the shell it
  was started in, and says the way in on the line of what it made: `made,
  with its role gpforum, as PostgreSQL's superuser postgres, from
  GPFORUM_DATABASE_USER`. When none answers it says what libpq told each
  login (`gpicchiarelli: role "gpicchiarelli" does not exist`), offers
  `PGUSER=postgres gpforum setup`, and, for a role that logged in only to
  find its database missing, prints the `CREATE DATABASE` alone, with no
  `CREATE ROLE` that would fail with "already exists" and no new password
  that would lock the role out.

- The hourly `gpforum-scheduled-jobs` timer failed on every run, so expired
  sessions, tokens and old outbox rows were never purged; the first run after
  upgrading may remove a backlog. Every `bin/gpforum-*` command runs on its
  own instead of dying on `Const::Fast`, and `bin/gpforum` run by an older
  Perl finds the supported one or says what to install. The FreeBSD rc scripts
  and launchd plists no longer override the file's `GPFORUM_ENV`. A
  `GPFORUM_MAIL_FROM` with a display name is checked like a bare address.

- **An id that is not a uuid is a 404 on the public pages too, not a 500.**
  `/t/anything`, `/c/anything`, `/attachments/anything/download` and the
  post actions under `/p/anything` bound the word for a uuid column,
  PostgreSQL refused the statement, and the page answered 500 (the writes
  503) and wrote the error log; anyone could fill it from a URL. A value
  PostgreSQL would not read as a uuid now sends no statement and finds
  nothing (`GPForum::Infrastructure::PreparedQuery`, through which the
  thread, category, post, attachment, read state, bookmark, subscription
  and session lookups now run). A uuid written as PostgreSQL also reads one
  (upper case, braces, no hyphens) still reaches the row and its 301.
- **The search endpoint's query budget is 3, not 2.** A signed-in search
  runs the session validation, the viewer's grants and the search itself;
  the budget was set when only the search was counted, and every signed-in
  search was marked over budget. Raised on that evidence
  (`t/integration/postgres-query-budget.t` had already measured 3).

- An outbox batch slower than its claim was delivered twice. A worker
  claims up to 100 messages for 60 seconds, and it acknowledged the ones it
  delivered together at the end of the batch, without ever renewing the
  claim: once a batch outlived it, another worker claimed the rest, the
  messages the first had not reached yet were delivered by both, and those it
  had delivered but not acknowledged were delivered again. Each message's
  claim is now renewed just before its dispatch and the message acknowledged
  right after it, both only while it is still the worker's own; a message
  another worker took is skipped, counted as `lost` in the batch's summary
  and logged as a warning. That costs two single-row commits a message: on
  the development laptop one worker with a transport that does nothing
  dispatches about 2,150 messages a second, where it managed 9,000 to 11,600
  (`docs/PERFORMANCE.md`).

- A worker whose outbox claim another worker had taken could still
  dead-letter the message, even one the other worker had delivered: its
  failure was written on a condition on `locked_by` whose outcome nobody
  read, and the dead letter written regardless. The failure is now written
  only while the message is still the worker's, and the dead letter only when
  that write updated the row, in the same transaction; a worker that lost the
  message records neither and logs it.

- Hypnotoad could not load the application: `hypnotoad bin/gpforum`, what
  every service unit runs, stopped with `File "bin/gpforum" did not return
  an application object.`, because the file ended in `1;` after starting the
  application. It now ends with the application, and a test loads it as
  Hypnotoad does.

- An attachment larger than 16 MiB never reached the application whole:
  Mojolicious cuts a request off at 16 MiB unless told otherwise, so even
  with nginx raised to 26 MiB an upload between 16 and 25 MiB failed
  without a reason. The application now takes requests up to 26 MiB, the
  25 MiB attachment limit and the form around it, as nginx does.

- `gpforum-admin-bootstrap` reported a database it could not reach as
  misuse: exit 2 and the usage text after the error. It now says it in the
  same one sentence as every other command, and exits 1.

- The guides now say that nginx's user must be in the `gpforum` group to
  send attachments by X-Accel-Redirect or to reach the UNIX socket, both under
  directories of mode 0750; without it every download answered 403.
  `docs/PRODUCTION_READINESS.md` and `docs/ops/staging-host.md` install with
  `make install-deps-production` and start the outbox worker as
  `docs/DEPLOYMENT.md` does, `docs/PERFORMANCE.md` no longer says that
  `--strict` fails a degraded host or that GlifiStore is required.

- `/metrics/`, which the application answers as `/metrics`, reached it from
  anywhere: nginx kept only the exact `/metrics` to the loopback, and the
  Caddyfile named only that path. Both now hold either spelling.

- On a host installed as the guide says, with the code tree root's, every
  start and every command run as `gpforum` printed `mkdir:
  /opt/gpforum/local/.perl-shim: Permission denied`: `script/gpforum-carton`
  made its interpreter shim on first use, as whoever ran it.
  `script/bootstrap-deps` (`make install-deps-production`) now makes it
  while installing; on a host installed before, run that once more.

- Upgrading the code without re-copying the systemd units stopped the
  forum: Hypnotoad wrote its pid file to `/run/gpforum` while the installed
  unit waited for `/opt/gpforum/hypnotoad.pid`, and systemd failed the start.
  Under a unit that still sets `MOJO_MODE`, which only the old ones do, the
  pid file stays where that unit looks, and the start says to copy the units.

- A command whose failure was a refused connection or a missing socket of
  something else -- clamd, the SMTP server, GlifiStore -- was told to start
  PostgreSQL, and its own reason was not printed. Only a failure DBI, DBD::Pg
  or libpq reported is now read as the database's.

- nginx refused uploads between 20 and 25 MiB with its own 413 page:
  `client_max_body_size` was 20m against GPForum's 25 MiB limit. It is 26m.

- The Caddyfile served `/metrics` to anyone with the token; like the nginx
  configurations it now answers the loopback only.

- The shipped units start on a host with one CPU. The preflight compared the
  configured `GPFORUM_WEB_PROCESSES` (4) with what one CPU carries (2) and
  called the host oversubscribed, although under the default `cap-to-cpu`
  policy Hypnotoad is given 2; it now checks the number Hypnotoad is given.

- `ThreadStore` checks a thread title edit, move, delete or restore against
  the same rule as the posting workflow, authorship included, under the
  thread's row lock: a direct store call could change another member's
  thread, or restore one someone else deleted.

- An erasure that cannot read the member's credentials or sessions fails and
  rolls back, and can be run again. Before, it could finish with the account
  anonymized and the credentials revoked while the member's sessions stayed
  signed in.

- A log file that cannot be opened stops startup with an `X::Config` error
  that carries the original reason. The check meant to report it never ran:
  Mojo::Log died first with its own message.

- `Antivirus->from_config` returns undef for `none`, as documented, instead
  of an empty list.

- A hypnotoad-benchmark child that cannot exec (a missing reverse-proxy
  binary, say) exits 127 with the reason in its log, instead of running on in
  a copy of the parent: that copy stopped the hypnotoad being measured and
  printed a second report.

- Admin category routes answer 404, not 503, for a space id in the body or a
  category id in the path that is not a uuid. A slug a soft-deleted category
  still holds, or an edit onto another category's slug, answers 400 naming
  the slug instead of 503: the store reports the slug taken (read from
  PostgreSQL's own message, so an over-long slug is not mistaken for one) and
  `Admin::Workflow` maps a store's errors to `invalid`.

- A retried notification delivery no longer writes a second `notifications`
  row when its leftover row is stored at another time or in another month's
  partition: the stored row is reused and the inbox row takes its time. Two
  workers recording the same caller-supplied event id at different times no
  longer both store it, and a caller-supplied audit id already stored at
  another time is written under a new id (ADR 0116).

- Every server profile ignores `GPFORUM_QUERY_BUDGET_ENFORCE=1` (production,
  production-small, production-medium, staging); before, only
  `GPFORUM_ENV=production` did, and elsewhere a breached budget left the
  response unsent. `/metrics` counts pending and failed outbox messages in one
  grouped statement instead of the same statement twice, and has its own
  budget, `metrics` (5 statements): run `script/query-budget --sync` after
  deploying. `--sync` deletes the rows of endpoints the catalog no longer has
  and names them (`removed` in `--json`).

- The privacy dashboard no longer fails for a member with an export request,
  and the export download returns the bundle as a JSON object instead of one
  JSON string: the jsonb manifest is read decoded. An erasure job that runs
  after its retention hold ends no longer keeps
  `last_error = 'retention hold active'`.

- Password credentials take `created_at` from the application clock that also
  sets `revoked_at`: an application clock behind the database clock no longer
  breaks `credentials_revoked_after_created_check` on the next password change.
  A new credential id that collides with one of the member's own revoked or
  other-type credentials (a second factor) is minted again instead of being
  returned as the active password, which left the member with none. A
  registration that reuses a leftover account writes its credential, event and
  audit in one transaction (ADR 0110).

- The hourly `attachments` job removes an orphan upload's file and its
  thumbnails from `attachment_root`, not only its row; until now those files
  stayed in storage indefinitely. The timer must see the same
  `GPFORUM_ATTACHMENT_ROOT` and working directory as the application, as the
  shipped units do.
- An abandoned upload must be at least a day old before the job removes it,
  so an upload still in progress is never touched, and `--limit` counts real
  orphans only: linked uploads at the front of the queue no longer stop the
  job reaching the orphans behind them.
- An orphan the job cannot purge (its file cannot be removed, or its row stays
  locked past `GPFORUM_DATABASE_LOCK_TIMEOUT_MS`) ends the run with
  `ok=0 attachments_errors=N` and exit 1; the other orphans are still purged
  and the failed one is retried on the next run.
- Repeating a delete, or a thumbnail request for a thumbnail that already
  exists, returns the attachment again instead of an empty one.

- A database error that is not a unique violation is no longer taken for a
  conflict because the row's data contains the words "unique constraint":
  `UniqueConflict->is_conflict_on` now requires PostgreSQL's own message to
  report the violation as well as to name the index.

- A raced notification, event or audit id is reused or minted again on
  PostgreSQL. Those tables are partitioned, and PostgreSQL names the
  partition's index in a unique violation (`notifications_default_pkey`), not
  the table's constraint, so every collision was rethrown as a 500.
  `UniqueConflict->is_conflict_on` reads the partitions' indexes from
  `pg_inherits`, matches whole identifiers, and looks only at the server's own
  sentence, not the row data DBI appends.

- **The evidence commands exit 1, not 2 or 255, when their check raises an
  error**, with a redacted reason and a JSON `status: fail` document;
  `partition-maintenance` against an unreachable database says why;
  `stress-load` without a base URL is misuse (exit 2).

- **A malformed id in a moderation or privacy URL answers 404**, word for
  word the unknown-id answer, without a query (it was a 500, or 503 for a
  suspension revoke); filters with a malformed id show an empty page. A
  signed-out privacy request and a forbidden staff privacy action get their
  401 or 403 instead of a dropped connection.

- **"Purge page cache" says when GlifiStore was not reached**: a warning,
  styled as one, names the tags left in the shared cache (they expire within
  their TTL); the JSON answer says `cache_purged_locally`, and a resubmitted
  form replays the same warning.

- **The application and `gpforum-migrate --apply` connect as an ordinary
  role.** Every connection ran `SET lc_messages`, which PostgreSQL allows only
  to a superuser, so a production role that owns its database could neither
  migrate nor serve. The locale is now asked for and, when refused, left at
  the server's setting; unique-conflict recovery reads the SQLSTATE first.

- **A moderator can hide and unhide a thread on PostgreSQL**: the action
  wrote a `hidden_at` column the threads table does not have and died, so
  the hide-thread route never worked. Locking now means `locked_at`, so a
  thread whose state said locked without a lock time is really locked.
- **An author's thread delete, restore or move no longer goes through after
  a moderator locked or hid the thread** between the check and the write:
  under the row lock it is refused (403 or 404), recorded against the
  command id.

- **Readiness no longer reports a shared cache that is not there**: with an
  in-process L2 the tiered cache's ping answers 0, so readiness says
  `local-fallback`. A realtime listener's dying snapshot no longer overwrites
  the error that made it degraded.

- **`scheduled-jobs` printed `attachments=ARRAY(0x...)`** and its `--json`
  carried each deleted attachment's row; it now counts them. `migrate
  --plan` outside the app root, a malformed setting in `os-preflight`, and a
  `partition-maintenance` failure without `--json` now exit 1 with a redacted
  reason instead of 2, 255 or a stack location.

- **A refused byte range (416) or a proxy error page is no longer cached for
  a year** under a fingerprinted asset URL: the app sends a lifetime only on
  200, 206 and 304, nginx no longer adds it to its own error pages, and Caddy
  serves only existing files from `/assets/`.

- **Search time filters keep their meaning**: a time with no offset is read
  in the database session's zone, as a day is, not as UTC; fractional seconds
  are kept to the microsecond instead of rounding into the next second.

- **Malformed search filters are ignored instead of reaching PostgreSQL**
  (a non-uuid id, a date that is not a day or an RFC 3339 time, an offset
  beyond +/-23:59); `to=<day>` includes the whole day. Each step of a console
  search rebuild records its next step and outbox message in one transaction.
  `GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS` is lowered to the global statement
  timeout when that is lower.

- **A mark-read whose badge count or NOTIFY fails after the write committed
  gets the write's own answer**, not a 500; inside a post's transaction a
  failed count no longer rolls the post back (`badge_failures`).
- **A realtime listener whose snapshot dies no longer takes down /metrics or
  the console**; `/metrics` shows `realtime_listener.status` and
  `last_error`, and each outage is logged once.
- **An unknown notification channel is refused** (400, nothing saved)
  instead of silently turning off a member's in-app notifications;
  `enabled_channels` applies the defaults.

- **"Purge page cache" no longer reports "purged" when GlifiStore was paused
  or failing**: the result and its audit row record `purged_locally` and the
  tags not reached (they expire within their TTL).
- **Junk URLs no longer create public-cache entries**: a wrong thread slug or
  an id written another way gets a 301 to the real URL, a trailing slash or a
  percent-escaped character shares the page's entry, and `?limit=` is keyed
  by the page size shown. The tiered cache's readiness ping no longer dies on
  an in-process L2; `SharedCache->try_connect`, unused, is removed.

- **Two administrators revoking the same role binding at once no longer both
  succeed**: the second waits on the row lock and reports the binding as
  already revoked, with one revocation time and one audit entry. Re-attaching
  a permission whose audit entry was lost writes it even when another
  permission of the role was audited, and an id spelled in upper case, in
  braces or without hyphens no longer writes a duplicate entry.

- **A post edit, delete or restore, or a thread title edit, no longer lands
  after a moderator locked the thread or hid the post** (or its author
  deleted it) between the check and the write. Under the row locks the store
  checks again and answers as the first check would: 403 `thread is locked`
  or `post is hidden`, 404 `post not found` or `thread not found`, recorded
  against the command id so a retry gets the same answer. An edit waits for
  moderation on its thread, never for replies in flight.
- **A reply waiting while the thread's author deleted the thread is
  refused** with 404 instead of landing in the deleted thread (with its
  mentions and feed items). The author can still reply to their own deleted
  thread.

- **A cached public page with a character past Latin-1 failed with a 500**
  (a dash, a curly quote or an emoji in a thread title: "Wide character"),
  and accented text on cached pages reached the browser as Latin-1 under a
  UTF-8 header, so Italian visitors saw broken letters. The page cache now
  keeps, hashes and sends UTF-8 bytes; entries cached by the previous
  release are rebuilt on their next request.

- **A moderation purge that landed while a page was being computed could
  leave the hidden content in GlifiStore until its TTL.** Tag tokens are now
  read before the computation (a ticket), so a purge in between retires the
  entry. A public page miss costs a few more token reads, and the first page
  rendered under a tag with no token stays in the process-local cache only.
- **`/categories` and `/categories?limit=25` shared one cached page**, so an
  anonymous visitor could get a truncated category index. Each limit has its
  own entry.

- **SMTP relays that require a login work.** `Net::SMTP` answers `AUTH`
  only through `Authen::SASL`, which it loads at run time and which nothing
  declared, so every installation with `GPFORUM_SMTP_USERNAME` failed at the
  first message: sign-up confirmations, password resets and e-mail changes.
  `Authen::SASL` 2.2100 is now in the lock; `t/215-smtp-authentication.t`
  sends through a local relay that asks for `AUTH PLAIN`, and fails without
  it. Run `make install-deps-postgres` (or `script/bootstrap-deps --postgres`).

- **A process that registered for cache invalidations while the database
  was unreachable, or inside a transaction, now clears its local cache once
  its LISTEN takes effect**; before, a hidden post it had cached meanwhile
  could stay visible until the TTL.
- **A realtime broadcast whose readability check fails no longer aborts the
  listener's poll**: the other notifications are still delivered, badges are
  still re-sent after a reconnect, and the failed event is left to the outbox
  backstop (`broadcast_failures`). Badges no longer crowd thread hints out of
  the listener's duplicate filter, which made the backstop send hints twice.
- **The query-plan gate checks search with the configured
  `GPFORUM_SEARCH_CANDIDATE_LIMIT`**, not the default 1000: evidence for a
  forum with another cap described a query it never sends.

- **Realtime and cache invalidation no longer steal each other's
  notifications** (ADR 0111). The cache bus and the realtime listener read
  the same connection's notification queue and took each other's messages: a
  purge the listener took left hidden content in that process's cache. One
  queue per process now routes by channel. After a reconnect -- including to
  a backend that reuses the old PID, as a PostgreSQL restarted in a fresh
  container does -- it listens again, clears the local cache once and
  re-sends badge counts. A process that cannot listen (pointed at a standby)
  clears its local cache on every read until it can (`listen_failures` in
  `/metrics`).
- **Every badge reaches every process and node**, through `NOTIFY`; a badge
  changed by a web request used to reach only that process's sockets.
- **The realtime backstop no longer replays seven days of events** after a
  deploy or worker recycle: it starts at the head, polls only while the
  process has sockets, and a failed poll keeps its place.
- **A thread restored after being hidden no longer drops out of search**
  when two dispatchers deliver the hide after the restore: each removal step
  reads the thread again under its locks.

- **`script/gpforum-carton exec prove -v` printed Carton's version** once
  Carton was installed: real `carton exec` took the command's options as its
  own, so `make integration` ran nothing. The wrapper now runs `exec` itself
  in every case, pinned to the validated Perl.
- **`script/system-preflight` reported perlcritic missing** on hosts where it
  lives in `local/`, as the gates run it. It now asks the wrapper.

- **A reply no longer lands in a thread locked or hidden while it was being
  sent.** The reply re-reads the thread under its lock and is refused with
  403 "thread is locked" or 404 "thread not found"; a retry with the same
  command id gets the same answer (ADR 0111).
- **A moderation purge could miss a cached page, and bring back a hidden
  post.** Two cache writes at the same moment lost each other's entry in a
  tag's member list in GlifiStore. A tag is now a token: invalidating it is
  one ERASE, and an entry whose token changed is a miss. Pages cached before
  the upgrade miss once.
- **Erasing a GlifiStore key that was already absent counted as a failure**
  and dropped the connection, on almost every post. It is now a success;
  only transport, availability and protocol errors drop the connection.
- **A page copied from GlifiStore into a process's own cache outlived the
  GlifiStore entry** by up to one TTL. It now expires with it. The anonymous
  category list is now shared through GlifiStore, and a page miss looks the
  page up once, not twice.

- **An English visitor could be served the Italian page.** The public page
  cache's key named neither the language nor the theme: the first visitor's
  page was served to everyone after. The key now holds both, and `Vary`
  names `Accept-Language`.
- **`?after=` with any junk failed the page on PostgreSQL** (an invalid
  timestamp). A cursor is now checked before it reaches SQL; a bad one shows
  the first page.

- **"Latest activity" is latest activity.** `threads.last_activity_at` had
  no writer, so the home page, category pages, sitemap and feed ordered
  threads by creation. A reply now moves its thread up, from the outbox
  (`ThreadActivity`, off the reply's transaction so a busy thread's row is
  not locked per reply); migration 046 sets existing threads to their
  latest visible post.
- **Autocomplete suggests each thread once.** A post's search document
  carries its thread's title, so a thread with many replies filled every
  suggestion with the same title.
- **Search rebuild review fixes.** A rebuild racing the live search handler
  could write an older document over a newer one -- a hidden post
  searchable again; documents are now written under a lock each. `--entity
  thread` left a dead thread's posts searchable. The prune decided from one
  snapshot and could drop a post restored meanwhile. `--status` printed its
  timestamp with a space, breaking its `key=value` line.
- **`bin/gpforum` exits with its command's status.** Mojolicious ignores a
  command's return value, so misuse through the front door exited 0.
- **Fix: search missed a thread's replies after a rename or a move.** A
  post's search document carries its thread's title and category; renaming or
  moving the thread now reindexes its posts.
- **Fix: notifications to some subscribers could be dropped for good.** When
  a reply's fanout failed for a recipient, the event was still marked done;
  the handler now fails so the outbox retries, and recipients already served
  are duplicates by the inbox's primary key.
- **Fix: a retried session handed the cookie a token that was never stored**
  (after a session-hash collision), so the new login was invalid at once.
- **Fix: re-recording a stored event failed on PostgreSQL.** The reuse path
  read the stored row as a hash, which only the test doubles return, and
  built its outbox row with no event.
- **Fix: marking a notification read with a malformed id answered 503**; it
  is now 404.
- **Fix: page defects.** Thread and category breadcrumbs now end at the page
  (the thread's names its category); the search page states its help once;
  metadata lines no longer uppercase usernames.
- **Fix: data export failed for members with more than 65,535 posts.** Post
  bodies were read with one bound parameter per post, past libpq's limit;
  they are now read in batches of 10,000.
- **Fix: a failed command could commit half its work and never be retried.**
  Every workflow that runs under a command id caught its store's exception
  inside the command's transaction and returned "failed", which then
  committed whatever had been written before the failure and stored
  "failed" as the command id's answer: retrying the same form could never
  succeed. `CommandIdempotency` now rolls a failed command back and keeps
  no answer for it.
- **Fix: `SAVEPOINT savepoint_0` lines in the production log.** The query
  statistics object inherited DBIx::Class's printer, and with statistics on
  for the whole process every nested transaction wrote two lines to STDERR.
- **Fix: a failed admin write could half-commit.** The admin workflow
  caught a store's exception inside the command's transaction, which then
  committed what the store had written before failing and stored "failed"
  as the command id's answer, so a retry with the same form could not
  succeed. The exception now rolls the transaction back.
- **Fix: `/readyz` died whenever uploads were not scanned.** With
  `GPFORUM_ANTIVIRUS=none` -- the default outside staging and production --
  the readiness helper was built with an empty list in place of the
  antivirus, which shifted every later argument out of place, and each
  probe failed with "Can't locate object method". Introduced with ADR 0108;
  `t/69` now pins the wiring.
- **Fix: attachment uploads failed on PostgreSQL.** Recording an upload's
  verdict wrote the scanner's name (`local-sniffer`) into `event_log.actor_id`,
  a `uuid` column, and PostgreSQL rejected the insert, so every upload failed.
  The unit doubles accept any string and no integration test had uploaded a
  file. A verdict is now a system action with a NULL actor and a `scanned_by`
  payload field, and `t/integration/postgres-attachment-scan.t` uploads end to
  end against PostgreSQL.
- Add `t/integration/postgres-idempotency.t`: skippable-unless-DSN two-connection
  evidence for concurrent `event_idempotency_keys` `mark_done` and reputation
  source unique races inside open `txn_do`. `EventIdempotencyStore` and
  `ReputationLedger` wrap inserts with `UniqueConflict->attempt` so unique
  violations do not abort the outer transaction on live PostgreSQL.
- Add `t/integration/postgres-concurrency.t`: skippable-unless-DSN evidence
  with two real PostgreSQL connections for command_log, bookmark,
  subscription, open report, moderation hide, audit chain, privacy approval,
  and identity token consume races; wire it into CI beside `postgres.t`.
  `UniqueConflict->attempt` wraps inserts in a savepoint so unique races can
  replay inside an open `txn_do` on real PostgreSQL. Command-log payload
  updates read inflated JSON accessors, and identity token/session expiry
  compares parsed epochs so PostgreSQL timestamptz text does not false-expire.
- Plugin install remints `plugin_id` once when the unique primary key
  conflicts, and does not return another plugin.
- Plugin install reuses a leftover `plugin_id` with this name and version
  and registers missing hooks.
- Plugin hook writes remint `hook_id` once when the unique primary key
  conflicts, and do not return another hook.
- Plugin hook writes reuse a leftover `hook_id` with this plugin and hook
  name and register missing hooks.
- Import job create remints `import_job_id` once when the unique primary
  key conflicts, and does not return another job.
- Import failure recording remints `import_failure_id` once when the unique
  primary key conflicts, and does not return another failure.
- Import failure recording reuses a leftover `import_failure_id` with this
  source and does not insert a second review row.
- Role catalog writes remint `role_id` once when the unique primary key
  conflicts, and do not return another role.
- Role catalog writes reuse a leftover `role_id` with this name and insert
  the missing audit.
- Permission catalog writes remint `permission_id` once when the unique
  primary key conflicts, and do not return another permission.
- Permission catalog writes reuse a leftover `permission_id` with this
  resource and action and insert the missing audit.
- Role catalog attach writes reuse a leftover grant with this role and
  permission and insert the missing audit.
- Role binding writes remint `binding_id` once when the unique primary key
  conflicts, and do not return another binding.
- Role binding writes reuse a leftover `binding_id` with this active
  binding and insert the missing audit.
- Legacy id mapping remints `legacy_id_map_id` once when the unique primary
  key conflicts, and does not return another mapping.
- Legacy id mapping reuses a leftover `legacy_id_map_id` with this source
  and keeps the original native id.
- Category create remints `category_id` once when the unique primary key
  conflicts, and does not return another category.
- Category create reuses a leftover `category_id` with this space and slug
  and inserts the missing event.
- Default-space create remints `space_id` once when the unique primary key
  conflicts, and does not return another space.
- Default-space create reuses a leftover `space_id` with this slug and
  does not insert a second space.
- Mention recording remints `mention_id` once when the unique primary key
  conflicts, and does not return another mention.
- Mention recording reuses a leftover `mention_id` with this source and
  mentioned user and inserts the missing notification.
- Bookmark save remints `bookmark_id` once when the unique primary key
  conflicts, and does not return another bookmark.
- Bookmark save reuses a leftover `bookmark_id` with this user and target
  and does not insert a second bookmark.
- Subscription save remints `subscription_id` once when the unique primary
  key conflicts, and does not return another subscription.
- Subscription save reuses a leftover `subscription_id` with this user and
  target and does not insert a second subscription.
- Report create remints `report_id` once when the unique primary key
  conflicts, and does not return another report.
- Report create reuses a leftover `report_id` with this reporter and
  target and inserts the missing event.
- Moderation action writes remint `moderation_action_id` once when the
  unique primary key conflicts, and do not return another action.
- Moderation action writes reuse a leftover `moderation_action_id` with
  this command_id and insert the missing event.
- Retention hold create remints `retention_hold_id` once when the unique
  primary key conflicts, and does not return another hold.
- Retention hold create reuses a leftover `retention_hold_id` with this
  resource and inserts the missing event.
- Deletion request create remints `deletion_request_id` once when the
  unique primary key conflicts, and does not return another request.
- Deletion request create reuses a leftover `deletion_request_id` with
  this open resource and inserts the missing event.
- Erasure job create remints `erasure_job_id` once when the unique primary
  key conflicts, and does not return another job.
- Erasure job create reuses a leftover `erasure_job_id` with this request
  and inserts the missing approval action.
- Export request create remints `export_request_id` once when the unique
  primary key conflicts, and does not return another request.
- Export request create reuses a leftover `export_request_id` with this
  pending unique and inserts the missing event.
- Deletion action writes remint `deletion_action_id` once when the unique
  primary key conflicts, and do not return another action.
- Dead-letter recording remints `dead_letter_id` once when the unique
  primary key conflicts, and does not return another review row.
- Dead-letter recording reuses a leftover `dead_letter_id` with this
  source and does not insert a second review row.
- Reputation ledger writes remint `reputation_event_id` once when the unique
  primary key conflicts, and do not return another event.
- Reputation ledger writes reuse a leftover `reputation_event_id` with this
  source and insert the missing snapshot.
- Projection generation start remints `generation_id` once when the unique
  primary key conflicts, and does not return another generation.
- Projection generation start reuses a leftover `generation_id` with this
  source and does not insert a second generation.
- Thread create remints the opening `post_id` once when the unique primary
  key is occupied by another post, and does not return that post.
- Thread create reuses a leftover opening `post_id` with this thread and
  inserts the missing body.
- Thread create remints the opening `body_id` once when the unique primary
  key is occupied by another body, and does not reuse that body.
- Thread create reuses a leftover opening `body_id` with this post and
  inserts the missing revision.
- Thread create remints the opening `revision_id` once when the unique
  primary key is occupied by another revision, and does not reuse that
  revision.
- Thread create reuses a leftover opening `revision_id` with this post and
  inserts the missing counter.
- Thread create reuses this thread's leftover opening counter when the unique
  primary key conflicts, and does not abort the create.
- Reply create remints `post_id` once when the unique primary key is occupied
  by another post, and does not return that post.
- Reply create reuses a leftover `post_id` with this thread and inserts the
  missing body.
- Reply create remints `body_id` once when the unique primary key is occupied
  by another body, and does not reuse that body.
- Reply create reuses a leftover `body_id` with this post and inserts the
  missing revision.
- Reply create remints `revision_id` once when the unique primary key is
  occupied by another revision, and does not reuse that revision.
- Reply create reuses a leftover `revision_id` with this post and inserts
  the missing counter shard.
- Post edit remints `body_id` once when the unique primary key is occupied
  by another body, and does not reuse that body.
- Post edit reuses a leftover `body_id` with this post and inserts the
  missing revision.
- Post edit remints `revision_id` once when the unique primary key is occupied
  by another revision, and does not reuse that revision.
- Post edit reuses a leftover `revision_id` with this post and applies
  missing pointers.
- Thread create remints `thread_id` once when the unique primary key is
  occupied by another thread, and does not return that thread.
- Thread create reuses a leftover `thread_id` with this category and slug
  and inserts the missing opening post.
- Event recorder remints `audit_id` once when the unique primary key
  conflicts, and does not return another audit record.
- Event recorder remints `event_id` once when the unique primary key is
  occupied by another event, and does not return that event.
- Event recorder reuses this write's leftover `event_id` row when the unique
  primary key conflicts, inserts the missing outbox, and does not insert a
  second event.
- Notification delivery reuses a leftover `notifications_pkey` row and
  inserts the missing inbox, and does not remint `notification_id`.
- Read-state writes reuse a leftover `thread_read_state_pkey` row and
  insert the missing delta.
- Event recorder remints `outbox_id` once when the unique primary key
  conflicts, and does not return another event's handoff.
- Event recorder reuses a leftover `outbox_id` with this handoff key and
  does not insert a second outbox row.
- Suspension create remints `suspension_id` once when the unique primary
  key conflicts, and does not return another suspension.
- Plugin failure recording remints `plugin_failure_id` once when the unique
  primary key conflicts, and does not return another failure.
- Event recorder reuses outbox rows by unique `idempotency_key`, and does
  not treat another event's `event_id` as the same handoff.
- Attachment variant writes remint `attachment_variant_id` once when the
  unique primary key conflicts, and do not return another variant.
- Attachment variant writes reuse a leftover `attachment_variant_id` with
  this type and object key and do not insert a second variant.
- Attachment link writes remint `attachment_link_id` once when the unique
  primary key conflicts, and do not return another link.
- Attachment link writes reuse a leftover `attachment_link_id` with this
  target and do not insert a second link.
- Attachment intent writes remint `attachment_id` and `object_key` once
  when the unique primary key conflicts with a different object, and do
  not return another attachment.
- Attachment intent writes reuse a leftover `attachment_id` with this
  object key and insert the missing event.
- Registration reuses a leftover user `id` with this username and email
  and inserts the missing credential.
- Password credential writes reuse a leftover credential `id` with this
  user and do not insert a second active secret.
- Command log writes remint `command_id` once when the unique primary key
  conflicts, and do not replay another command.
- Command log writes reuse a leftover `command_id` with this idempotency
  key and finish the command.
- Identity token writes reuse a leftover `token_id` with this user and
  hash and do not insert a second token.
- Session writes reuse a leftover `session_id` with this user and hash
  and do not insert a second session.
- Post edit reuses unique `body_id` and `revision_id` rows and does not
  write a second event on conflict.
- Reply create reuses the unique `post_id` row and does not insert a
  second event on conflict.
- Email-change confirm returns `email_already_registered` on a unique
  `email_normalized` race and does not restamp the user.
- Thread create reuses the unique `thread_id` row and does not insert a
  second opening post or event on conflict.
- Notification mark-read reuses the unique
  `(notification_id, recipient_user_id)` row and does not insert a second
  read on conflict.
- Query budget sync reuses the unique `endpoint_name` row and does not
  rewrite the catalog when max queries, transactions, and notes already
  match.
- Trust snapshot writes apply this event's delta to the unique `user_id`
  winner and do not drop the score increment.
- Projection offset writes reuse the unique `projection_name` row and do
  not restamp `updated_at` when the event already matches.
- Reply counter shard writes apply the delta to the unique
  `(thread_id, shard_id)` winner and do not drop the increment.
- Password credential writes reuse the unique active `(user_id)` password
  row and do not insert a second active secret on conflict.
- Post edits retry revision allocation once when the unique
  `(post_id, revision_number)` key conflicts, and do not drop the edit.
- Reply writes retry position allocation once when the unique
  `(thread_id, position)` key conflicts, and do not drop the reply.
- Projection generation start reuses the unique `(projection_name,
  built_from_event_id)` row and does not insert a second rebuild on
  conflict.
- Event recorder writes reuse the unique outbox `idempotency_key` and do
  not insert a second EventLog or outbox row on conflict.
- Import failure writes reuse the unique `(import_job_id,
  source_record_type, source_record_id)` row and do not insert a second
  review row on conflict.
- Dead-letter writes reuse the unique `(source_table, source_id)` row and
  do not insert a second review row on conflict.
- Attachment variant writes reuse the unique `object_key` blob and do not
  insert a second variant on conflict.
- Attachment intent writes reuse the unique `object_key` row and do not
  insert a second event or audit on conflict.
- Projection generation activate retries the cutover once when the one-active
  unique index conflicts, and skips if this generation already won.
- Plugin install reuses unique `(plugin_id, hook_name)` hook rows and does
  not insert a second hook set on conflict.
- Thread read-state writes reuse the unique `(user_id, thread_id)` row
  and keep the original `last_read_at` on conflict when the stored
  position is already at least the requested one.
- Feed projection reuses the unique `(user_id, item_type, item_id)` row
  and keeps the original copy on conflict when created_at, rank, and
  version columns match.
- Notification preference writes reuse the unique `(user_id, channel)` row
  and keep the original `updated_at` on conflict when the values match.
- Search index reuses the unique `(entity_type, entity_id)` document and
  keeps the original `indexed_at` on conflict when the copy is unchanged.
- Notification delivery reuses the unique inbox `(recipient, notification)`
  row and does not insert a second notification on conflict.
- Attachment link and variant writes reuse the unique target or
  `(attachment_id, variant_type)` row on conflict.
- Mention recording reuses the unique `(source_type, source_id,
  mentioned_user_id)` row and does not notify again on conflict.
- Role binding create reuses the unique active `(user, role, resource,
  space)` row and does not insert a second audit on conflict.
- Default-space create reuses the unique `general` slug and does not insert
  a second space on conflict.
- Legacy id mapping reuses the unique `(legacy_type, legacy_id)` row and
  keeps the original native id.
- Category create reuses the unique `(space_id, slug)` row and does not
  insert a second event on conflict.
- Role, permission, and attach writes reuse unique catalog rows and do not
  insert a second audit on conflict.
- Plugin install reuses the unique `(name, version)` row and does not insert
  a second plugin or hook set.
- Concurrent deletion approval reuses the unique erasure job and does not
  insert a second approval action.
- Already-done erasure retries complete the deletion request if it is still
  open, skip the request restamp when already completed, and do not emit a
  second action.
- Incomplete legal-hold erasure retries restore `held` status and
  `last_error` without a second event, and skip those writes when they
  already match.
- Already-revoked suspension retries restore a still-suspended user and skip
  the user restamp when status is already active.
- Identity mail outbox retry after send and before `mark_done` resends
  from the outbox payload. EventLog still omits the raw token.
- A registration unique race on username or email returns the same
  duplicate field errors and does not insert a second pending user.
- Hide, restore, lock, and unlock that are already applied do not insert a
  second `moderation_actions` row, event, audit, or outbox message. A new
  `command_id` against the same target state returns the existing action.
- Mute, unsubscribe, and bookmark-remove keep the original timestamp when
  the store is retried and the row is already muted, revoked, or deleted.
  A second store call does not write a new stamp. HTTP `command_id` replay
  still avoids a second persist for the same command.
- Reputation events require `source_id`. A missing source is skipped without
  applying a delta. Existing null `source_id` rows backfill from
  `reputation_event_id`. The unique index covers every row, not only
  `source_id IS NOT NULL`. The reputation worker uses `aggregate_id` or
  falls back to `event_id`.
- Identity store and command-log failures return HTTP 503 without leaking
  the exception. A lost register, login, logout, password-change, locale,
  theme, settings, attachment upload, attachment delete, token-issuance,
  or token-consume response retried with the same `command_id` does not
  create a second pending account, open a second session, revoke a session
  twice, rotate a password twice, persist a preference twice, store a
  second file, soft-delete twice, issue a second token, or consume a token
  twice.
- Restoring a hidden or author-deleted thread reindexes the thread search
  document and every post in that thread. `thread.deleted` and
  `thread.hidden` already removed those post documents.
- Member data export now copies real posts, attachments, notifications,
  subscriptions, preferences, and profile fields (including email) into
  the completed `ExportRequest` manifest. Placeholder `{index}` rows are
  gone. Storage object keys and password hashes stay out of the bundle.
  EventLog still records counts only. `GET /privacy/export/:id` downloads
  the JSON for the signed-in subject; the dashboard links completed
  exports.
- Identity password-reset, email-change, and verification mail is queued
  on the outbox in the same transaction as token issuance. EventLog keeps
  `kind` and `token_id` only; the raw token lives on the outbox `mail`
  payload until the `IdentityMail` worker delivers it. A crash after
  issuance no longer drops the message.
- An outbox worker that claims a row and crashes before dispatch leaves
  the message `running`. Another worker does not take a fresh lock; after
  the lock expires the row is reclaimed and delivered once.
- Erasure that fails after credential and session revocation rolls back
  the user identity and leaves the job pending. A later `complete_job`
  anonymizes the member and revokes access.
- Thread, report, hide, and privacy approval writes roll back on a
  statement timeout during EventLog, outbox, or audit insert. Domain
  mutations inside the transaction are restored; no event, outbox, or
  audit row commits.
- A second `complete_job` while a legal hold still blocks erasure replays
  the blocked result. The job stays pending with the same `last_error`;
  no second deletion action, event, or audit is written. After the hold
  ends, a later `complete_job` can finish erasure.
  `DeletionWorkflow->hold_request` stays four arguments besides the
  invocant.
- Reputation events with a `source_id` are unique per
  `(user_id, source_type, source_id)`. `ReputationLedger->record_event`
  still skips a sequential duplicate; a unique race reloads the stored
  event and does not apply the delta twice.
- `thread.deleted` also removes post search documents and post feed rows
  for posts in that thread. `Search::Indexer->remove_thread` looks up
  posts by `thread_id` then deletes each search document;
  `FeedProjector->remove_thread` deletes the thread feed item plus every
  post item. Search documents and feed rows still have no `thread_id`
  column.
- Outbox worker handlers and the realtime fallback now wrap dispatch in
  `IdempotentJobRunner` with catalog keys `worker.<name>:{event_id}`.
  `EventIdempotencyStore` inserts into `event_idempotency_keys` only on
  `mark_done`, so a crash between `transport->dispatch` and outbox ack
  retries the message without skipping unfinished side effects. Replay of
  the same event is absorbed for search, notification, cache, attachment,
  media, feed, reputation, and realtime.
- Hidden posts now drop their `user_feed_items` rows through
  `FeedProjector->remove_item`; restore re-projects the author and thread
  subscribers with the existing `project_item` API. There is no
  `thread.hidden` event.
- Closed HIGH concurrency races on command replay, bookmarks, subscriptions,
  open reports, moderation actions, and the audit hash chain. Unique
  violations now replay the winning row, moderation hide/restore/lock take
  `FOR UPDATE`, and audit appends serialize previous-hash lookup with
  `pg_advisory_xact_lock` instead of swallowing chain-break errors.
  `migrations/026_concurrency_uniqueness.sql` makes the open-report unique
  index real and unique-indexes moderation `command_id`.
- Category create and update now invalidate the public category-list cache
  tags through the existing `CacheInvalidation` worker, so later admin
  edits do not wait for the 30s TTL.
- Admin category create and update now go through `Admin::Workflow` and
  `Admin::CategoryStore`, so the first administrator can add the first
  forum category on a fresh install without `PerformanceSeed`.
- Deploy units and reverse-proxy samples can start after
  `carton install --deployment`: supervisors invoke `script/gpforum-carton`
  (not the non-existent `local/bin/carton`), Nginx proxies
  `/attachments/:id/download` instead of intercepting `/attachments/` as
  `internal`, and Nginx/Caddy serve `/assets/` from the repo `assets/` tree.
  GlifiStore remains an operator-supplied server plus `GlifiStore::Client`
  (not a Carton/PAUSE pin). systemd units create `/run/gpforum` with
  `RuntimeDirectory`.
- Search and moderation/admin optional-query hashes no longer drop the
  following keys when a missing next-page size or empty optional param
  used a bare `return` (Perl empty list). `ForumAccess::search_more_limit`
  and controller `optional_param` now return an explicit undef.

### Development

- `t/602-upgrade-from-help.t` holds `gpforum upgrade` to `gpforum help` and
  to the three lines of `docs/ops/upgrade.md`.

- `make fresh-checkout` runs the README quick start as it now reads: given a
  DSN, `gpforum setup --environment development`, `gpforum admin create` and
  `gpforum start --foreground` (until `/health/ready` answers), as
  `bin/gpforum` in the clone with an environment file of the run's own, where
  it ran `gpforum-migrate --plan` and `--apply`. `t/166` holds the run to the
  README again: since iteration 3's quick start it failed "the run includes
  the quick start's gpforum admin create" and "... gpforum start
  --foreground". Only the FreeBSD job showed it, because it is the one job
  that reached `prove -lr t`: CI stopped at `make integration`, the Debian
  job at the dependency install (no `libssl-dev`), and macOS runs the full
  suite only on schedule.

- `t/600-metrics-token-reload.t` holds the service to its environment file's
  metrics tokens: through the application, across a rotation and its
  `--finish`, and during scrapes while another process rotates them, never
  refused and never opened. `t/601-secret-rotate-metrics-no-restart.t` holds
  the rotation's printed steps to three, in English and Italian.

- `t/integration/postgres-setup.t` passes on the CI runners, whose
  `postgres` takes only a password over TCP: setup runs there as an account
  without root, which it says, and reaches the superuser with the
  workflow's `GPFORUM_DATABASE_USER` and `GPFORUM_DATABASE_PASSWORD`; the
  subtests that need a superuser skip, with the reason, when the login is
  not one.

- `script/bench-outbox-dispatcher` reports `claimed_batches` where it
  reported `ack_batches`, which had counted the batches claimed since each
  message is acknowledged on its own, and adds `acknowledged`, the messages
  acknowledged one by one; a run where it is not every message reports
  `status=fail`. Nothing in the repository read `ack_batches`, so it is not
  kept as an alias.

- Integration tests no longer leave databases on the server. A clone a
  test's subroutine held lived into global destruction, where the admin
  handle was often freed before it and the drop never ran -- four clones
  every full run; a test that died between `create_database` and
  `drop_database` left its database too. Both are dropped at `END`, by the
  process that made them; `t/integration/pg-database.t` proves it.

- Consolidate architectural documentation in the ADR set and implementation
  guides. Remove the duplicated numbered text collection, update repository
  references and contributor workflows, and replace wording checks with
  documentation structure and reference validation. The technical decisions
  and behavioral architecture tests remain in place.

- CI prepares database query evidence before architecture checks, installs
  Git and Carton for the FreeBSD VM, and pins PostgreSQL dump/restore
  clients to the server major. PostgreSQL fixtures now work with password
  authentication and the query budgets installed by migrations. The quality
  gate has time for its full suite, and the resultset `all` method is accepted
  consistently across supported Perls. Secret scanning exempts only one exact
  PostgreSQL index identifier in its documented source file and still scans
  the full history. The action pinning check distinguishes local actions
  from external dependencies, with regression cases for both.

- Hypnotoad worker discovery reads complete process commands on every
  supported platform, including FreeBSD, where the default `ps` width could
  hide the application name in a long command.

- `GPForum::Config`'s settings table carries each setting's section and
  one-line summary, and `problems` returns every problem as a record
  (`GPForum::X::Config->problems`); `GPForum::Config::Report` words them, in
  English, and `GPForum::Service::I18N::CliCatalog` in the operator's
  language. t/460-t/462 and t/464-t/467 pin the report, the checks, the two
  catalogs, the log transport, the optional GlifiStore, the retired settings
  and `auto`.

- `script/architecture-check` keeps the subtraction sweep's gains: a new
  `check_retired_idioms` refuses, in `lib/` code, an `eval` block,
  `$EVAL_ERROR` or `$@`, `index($error, ...)`, a private `_schema_dbh`, a
  `has NAME => undef;` without a `# optional` comment, and a catch variable
  handed to conflict recovery. Its allowlist holds one frontend file the sweep
  may not edit (`ViewModel/Forum/Page.pm`, still on `eval`), and an entry
  that stops firing fails the check. The prototype guard also refuses
  `:prototype(...)`, the only spelling a prototype has under `use v5.40`, and
  now reads `script/`'s Perl programs; the `};` check no longer takes a
  heredoc line at column 0 for the end of the catch block around it, and
  both checks that read code stop on a heredoc no line ends, since text that
  only looks like one would leave every line after it unread. Given check
  names, the script runs only those; `t/341` runs each gate against a
  scratch tree that breaks it.

- `t/00-load.t` loads every module under `lib/` (453), found on disk: its
  list had fallen 100 modules behind. `PostReader` declares its schema through
  `GPForum::Base`, the last `lib/` attribute that was neither required nor
  marked optional, and `t/340` pins every forum service's required
  collaborators. `X::Conflict` catches with `try`/`catch`.
  `etc/perlcritic-baseline.txt` drops the 248 entries that no longer fire:
  853 lines become 605.

- The subtraction sweep (ADR 0117, ADR 0118) is through `lib/`: `eval`
  blocks went from 274 to 1 (the frontend file above) and `try` blocks from 4
  to 229; the 74 `index($error, ...)` constraint matches and 64
  `is_conflict` and `is_conflict_on` calls are `X::Conflict->on`; the ten
  private `_schema_dbh` copies are `Infrastructure::Storage`; and of 331
  `has NAME => undef;` attributes, 87 classes now declare the ones they need
  with `requires` and the 207 left say `# optional` with the reason.
  Single-caller helper chains were folded where they only passed arguments
  on: the identity, privacy, admin, moderation, community and notification
  services shrank from 13,026 to 11,438 lines of code, and nineteen other
  services, EventRecorder, AuditRecord and three worker handlers were folded
  the same way. Their POD names the classes they raise and the collaborators
  `new` requires.

- The forum write path is split by concern. Each post and thread refusal rule
  is defined once, in `GPForum::Domain::Post` and `::Thread`; the posting
  commands' log encoding is one table in `Forum::PostingCommand`, and post and
  thread events one table in `Forum::Event`. PostStore, PostingWorkflow and
  ThreadStore went from about 2,850 to about 1,130 lines of code. Golden tests
  pin every posting command's fingerprint, response and replay and every post
  and thread event (`t/325`, `t/329`); agreement tests show the stores refuse
  with the workflow's status for every row state (`t/327`, `t/330`); `t/326`
  and `t/332`–`t/334` pin the refusal order, the stores' conflict recoveries
  and where each event field comes from.

- Security events (CSRF failure, authentication or permission denial,
  rate-limit hit) are recorded in one place, `GPForum::Web::SecurityEvent`,
  instead of six copies in the controller bases, which inherit their shared
  request helpers from the new `GPForum::Controller::Base`. `t/378` checks
  each base records the event of every refusal it renders; `t/375` and
  `t/377` that each page read that dies reaches its catch, answers the page's
  failure and logs one line. `PublicCacheAccess` no longer wraps `Mojo::Date`
  in a catch that could never run.

- The benchmark commands (`benchmark`, `bench-hypnotoad`,
  `bench-hypnotoad-scaling`, `seed-performance-data`, `query-plan-evidence`)
  read their options through one reader in `Command::Usage`, with unchanged
  options and messages, and the two benchmarks judge and compare routes by
  one set of rules in `GPForum::Benchmark::Measure`. `t/367`–`t/369` pin the
  option readers, the child-process handling and nine rules the folding
  could break unnoticed. `script/bench-outbox-dispatcher` exits 2 with its
  usage on misuse, an empty `--artifact` included, instead of dying with 255.

- Tests found by breaking the converted code on purpose: `t/336` and `t/347`
  pin each service's required collaborators and the class each one throws;
  `t/337`–`t/339` a failed mention audit, a workflow whose command log or
  store dies, and the erasure rollback; `t/355`–`t/357` the foundation's
  declared failures and nine catch paths no test reached; `t/379` the folded
  login and bookmark branches; `t/138`, `t/75` and `t/103` the metrics
  token, RenderPolicy's attribute names and the identity command log;
  `t/389` a conflict whose partition catalog cannot be read; and the
  PostgreSQL tier gains a search-document
  insert race, a notification delivery racing on a partition's key, and the
  retention purge of revoked sessions and used tokens. The tests the sweep
  touched catch with `try`/`catch`; `t/322`, `t/323` and six shared doubles
  still use `eval`.

- ADR 0117 records the Perl 5.40 floor, the `use v5.40` preamble, native
  `try`/`catch` closed with `};` and the `return undef` policy; ADR 0118
  records the `GPForum::X` exception classes, why refusals stay result
  values, and `GPForum::Base->requires`. Both amend ADR 0052.

- `script/architecture-check` fails when a native `try`/`catch` does not end
  with `};` (ADR 0117). PPI reads a catch block closed by a bare `}` as an
  unfinished statement and folds the next statement into it, which misleads
  Perl::Critic.

- `GPForum::Infrastructure::Storage->dbh_of($schema)` and `storage_of` are
  the one copy of the "schema to database handle, or undef" probe that ten
  modules each keep as `_schema_dbh`. Callers move to it in later changes.

- `GPForum::Base` lets a class declare the attributes it cannot work without:
  `__PACKAGE__->requires(qw(schema))` makes `new` throw a
  `GPForum::X::Argument` ("Store requires schema") when one is missing or
  undef, across the inheritance chain, and `required_attributes` lists them
  (ADR 0118). No class extends it yet.

- Exceptions have classes: `GPForum::X` and its `Argument`, `Config`, `Usage`,
  `Conflict`, `Unavailable` and `Check` subclasses (ADR 0118). An exception
  stringifies to its message, so every reader of the old strings keeps
  working. `UniqueConflict->attempt` returns a unique violation as a
  `GPForum::X::Conflict` whose `on($constraint)` also matches the indexes of
  a partitioned table, and `UniqueConflict->throw` raises one.

- `my $undefined; return $undefined;` is now `return undef;` (ADR 0117), and
  the 63 dead returns after a final `UniqueConflict->rethrow` are gone. The
  profile no longer applies `ProhibitExplicitReturnUndef` and treats
  `rethrow` and `throw` as terminal for `RequireFinalReturn`.

- Every Perl file declares `use v5.40;` in place of `use strict;` and `use
  warnings;`, on the line after each `use Mojo::Base` (ADR 0117).
  `t/321-preamble.t` holds every file to it, with no exceptions left. The
  profile no longer applies `ProhibitVersionStrings`.

- The six modules that used Try::Tiny use native `try`/`catch`, and `cpanfile`
  no longer declares Try::Tiny (DBIx::Class, DateTime and Email::Sender still
  install it). `Identity::Support->trim` and `I18N::Locale->trim` are now
  `trimmed`: under `use v5.40` a package sub named `trim` collides with the
  lexical builtin.

- `t/299-readiness-runbook-sections.t` fails when a readiness runbook names a
  section heading its file does not have.

- The privacy data-rights stores are tested on PostgreSQL: export bundles,
  deletion requests, approval and its row lock, legal holds (including one that
  ends) and erasure jobs (including one whose audit write fails and rolls back
  completely). `t/29-privacy-rights.t` is gone. Two known defects are pinned as
  TODO: the privacy page fails for a member with an export request because the
  manifest is read as raw JSON, and erasure leaves the member's e-mail in stored
  export bundles and in the export response kept in the command log.

- The identity stores are tested on PostgreSQL instead of a fake ORM:
  registration, login and logout, sessions, password reset and change, e-mail
  change and verification, and preferences, including races between two
  connections. Logins for unknown, deleted and password-less accounts are each
  pinned to one verification against the decoy hash, and a pending account
  with a wrong password gets the same answer as any wrong password. Two known
  defects are pinned as TODO: a session is looked up by its id alone, and a new
  credential takes its creation time from the database clock but its
  revocation time from the application's.

- The permission gate tests on PostgreSQL fail if a binding that names only a
  space, or only a resource, is treated as a global grant; an empty scope is
  tested to mean no scope, and a category created without a space is tested to
  go to the first live space by position.

- Known defect pinned as TODO in `t/integration/postgres-notifications.t`: a
  notification, event or audit row left over with a different `created_at`
  does not conflict on its `(id, created_at)` primary key, so delivering it
  again writes a second row with the same id. `script/architecture-check`
  also guards `is_conflict_on` against hand-caught errors.

- **Query-plan gate review fixes.** The "most rows" allowance is limited to
  the relation a search ranks (it had exempted full scans of any joined
  table, such as users); a parallel scan is judged by all its workers' rows;
  a table without statistics is at least as large as its scan. A test double
  (`UnavailableWrite`) lacked the methods four workflows call, so their
  outage tests passed for the wrong reason.
- **The query-plan gate judges the query, not the dataset.** It failed
  correct plans on the medium dataset (sequential scans of 120 threads):
  a sequential scan now fails only on a table above 10,000 live rows, a
  relevance-ranked endpoint may read most of a large table, and a nested
  loop over one outer row is not explosive. Measured on 20,000 threads:
  every endpoint passes, and dropping the thread indexes still fails home
  and both category pages.
- **`CommandIdempotency::result_of`** replaces seven workflows' identical
  command guards (ADR 0110's `execute` boundary). Four perlcritic findings
  outside the baseline in `t/144` and `t/188` are fixed.
- **ADR 0110 maps ADR 0091's mandatory interfaces to the modules that
  implement them**, removes five contract methods nothing called, and
  tracks three real gaps. `EventRecorder::event_recorded` replaces six
  copies of the lookup that finishes a half-recorded command on replay.
- **`GPForum::Service::Forum::Readability`** holds the effective-visibility
  check for one post or thread, for many readers of one, and as an SQL
  condition for lists; `Notification::RecipientPolicy` extends it. The
  notification, mention and bookmark readers expose the resultsets they run
  (`unread_resultset`, `mentions_resultset`, `bookmarks_resultset`), and
  `t/200-readable-lists.t` checks their SQL without a database.
- **The viewer resolution and the notification readability check count as
  queries.** Their hand-written SQL went around DBIx::Class's statistics, so
  every signed-in request under-reported its queries by one against the
  endpoint budgets; `GPForum::Infrastructure::CountedQuery` reports them. The
  thread page loads the move form's category list only for the thread's
  author, who alone sees the form.
- Let `script/gpforum-carton exec` run against `local/` when the Carton
  binary is missing for system Perl (still hard-fails on `install`). Route
  quality-gate wrappers (`script/test`, coverage, perltidy, benches, …)
  through it so gates do not depend on a packaged Carton. Does not claim
  private-beta readiness.
- Expand deploy host observe to `gpforum-scheduled-jobs.service` (unit-dir
  contract) and `gpforum-scheduled-jobs.timer` (`--systemd` is-active). Fold
  mail-lifecycle + dead-letter simulate commands into
  `script/gpforum-evidence-live`. Does not install/reload services or claim
  private-beta readiness.
- Add `script/gpforum-mail-lifecycle-check` to exercise Identity::Mailer
  `password_reset` / `email_change` / `email_verification` under the test
  transport with EvidenceMeta JSON (token scrubbing). Staging SMTP `--send`
  remains open. Does not claim private-beta readiness.
- Add `script/gpforum-dead-letter-check` to automate the
  `docs/ops/dead-letters.md` staging check (`--simulate` permanent failure →
  dead-letter → redispatch → retention hold) with EvidenceMeta JSON. Live
  `/admin/jobs` confirmation remains open. Does not claim private-beta
  readiness.
- Extend EvidenceMeta / evidence-validate to staging drills
  (`staging_drill`, `attachment_filesystem`, `deploy_checklist`,
  `staging_ops_extensions`) so prep archives can be `--strict`-checked offline.
  Meta-stamp Cloud Agent drill JSON. Does not claim private-beta readiness.
- Add `script/gpforum-evidence-meta` to stamp archived ops JSON with the shared
  EvidenceMeta contract; meta-stamp Cloud Agent verify/stress/mail archives so
  `evidence-validate --strict` can accept historical preparation blobs without
  changing measurements. Does not claim private-beta readiness.
- Centralize ops evidence metadata in
  `GPForum::Service::Operations::EvidenceMeta` (`secrets_redacted`,
  `private_beta_claimed=0`, deduped `residual_gaps`, optional secret scrubbing).
  Wire `staging-host-verify`, `mail-check`, and `stress-load` through it;
  `evidence-validate --strict` requires the markers on all known families.
  Does not claim private-beta readiness.
- Add `script/gpforum-evidence-validate` / `bin/gpforum-evidence-validate` to
  validate archived ops evidence JSON (shape by family, secret patterns,
  private-beta claim rejection; `--strict` requires modern redaction markers).
  Docs: `docs/ops/evidence-validate.md`. Does not claim private-beta readiness.
- Centralize deploy systemd/nginx contracts in
  `GPForum::Service::Operations::DeployContract` (shared by the deploy
  checklist drill and staging-host verify). Add non-destructive
  `--nginx-conf` observe to `staging-host-verify`. Does not install/reload
  services or claim private-beta readiness.
- Add non-destructive `--unit-dir` observe to `staging-host-verify`: installed
  systemd unit text must match the deploy contract (`User`, `EnvironmentFile`,
  `ExecStart` via `gpforum-carton`). Harden TLS URL parsing (host/port,
  trailing slash). Does not install/enable units or claim private-beta
  readiness.
- Observe TLS on `script/staging-host-verify --base-url https://…` (records
  https scheme; pair with the health probe). `http://` base URLs leave a
  residual gap. Wired into `docs/ops/staging-host.md` and
  `script/gpforum-evidence-live`. Does not claim private-beta readiness.
- Point ROADMAP private-beta status row at the Cloud Agent stress 500/1000 archive.
- Archive Cloud Agent VM Hypnotoad stress-load capacity evidence under
  `docs/ops/evidence/2026-09-20-cloud-agent-stress500/` (`carton_ok`, migrate +
  query-budget, medium seed, profile **500** `ok` / `--check` `pass`, profile
  **1000** `ok` with p95 residual under `--check`). Extends
  `2026-09-20-cloud-agent-live/`. **PRIVATE BETA remains NOT YET.**
- Clarify Cloud Agent live evidence reproducibility: metrics pass requires `e964899` (header fix), not bare checkout base `e5bc023`.
- Point `script/gpforum-evidence-live` at stress profile `500` as the next capacity step after archived profile `100`.
- Lock `StagingHostVerify` metrics probe header to `X-GPForum-Metrics-Token` in `t/164-staging-host-verify.t`.
- Archive Cloud Agent VM live Hypnotoad verify evidence under
  `docs/ops/evidence/2026-09-20-cloud-agent-live/` (`carton_ok`, migrate +
  query-budget, `staging-host-verify --env-file --base-url` pass including
  `/metrics`, `stress-load --profile 100` ok JSON). Fix
  `StagingHostVerify` metrics probe header to `X-GPForum-Metrics-Token`.
  **PRIVATE BETA remains NOT YET.**
- Cover `script/gpforum-evidence-live` in `t/165-evidence-live.t` and
  `t/18-github-project.t` (executable, print-only, no private-beta claim).
- Add print-only `script/gpforum-evidence-live` / `make evidence-live` to
  orchestrate live `staging-host-verify` + `stress-load` + mail-check archive
  commands (env-file / base-url). Does not start Hypnotoad or claim private-beta
  readiness. Wired into private-beta checklist and `docs/ops/staging-host.md`.
- Refresh ROADMAP/README private-beta status rows to point at the Cloud Agent drills archive while keeping staging TLS / SMTP / target install open.
- Sync inventory/readiness/ROADMAP after Cloud Agent drills archive
  (`docs/ops/evidence/2026-09-20-cloud-agent-drills/`): keep **PRIVATE BETA
  NOT YET**; Next is staging TLS / SMTP `--send` / target install evidence.
- Archive Cloud Agent VM post-Carton drills evidence under
  `docs/ops/evidence/2026-09-20-cloud-agent-drills/` (completed
  `bootstrap-deps --postgres --rebuild-local` / `carton_ok`; staging-host-verify,
  staging-drill, staging-drill-attachments, mail-check dry-run pass JSON;
  optional Hypnotoad + stress-load smoke `ok`). Extends the incomplete cut in
  `2026-09-20-cloud-agent-complete/`. **PRIVATE BETA remains NOT YET.**
- Archive Cloud Agent VM complete-sequence evidence under
  `docs/ops/evidence/2026-09-20-cloud-agent-complete/` (system Perl preflight,
  PostgreSQL role/DB ready, Carton bootstrap log tail; staging/mail drills
  skipped while `local/` incomplete). **PRIVATE BETA remains NOT YET.**
- Ignore `local.rebuild.*` / `local.incomplete.*` Carton recovery trees in `.gitignore` (companions to `bootstrap-deps --rebuild-local`).
- Wire `script/bootstrap-deps --rebuild-local` into the private-beta checklist script and docs so incomplete Carton `local/` trees are an explicit prep step.
- Archive partial Cloud Agent VM private-beta *preparation* evidence under
  `docs/ops/evidence/2026-09-20-cloud-agent/` (system Perl preflight +
  private-beta checklist `--status`/`--commands`; carton deps / drills /
  Hypnotoad / mail / stress marked skipped with `residual_gaps`). **PRIVATE
  BETA remains NOT YET** — does not claim readiness.
- Archive macOS laptop prep evidence under
  `docs/ops/evidence/2026-09-20-macos-laptop-prep/` (checklist print-only,
  repo-only `staging-host-verify` pass, degraded attachments drill). Explicitly
  **not** staging/private-beta evidence; residuals documented in the README.
- Document optional MacPorts user-space PostgreSQL (`initdb` under `$HOME`, non-default port) in `docs/ops/staging-drills.md` for throwaway drills when `sudo port load postgresql*-server` is unavailable. Still requires OS system Perl 5.38+ and Carton deps.
- Add operator private-beta go/no-go checklist aggregating system-perl,
  macports-env, migrate, query-budget, staging-drill,
  staging-drill-attachments, staging-host-verify, stress-load, and mail-check
  in `docs/ops/private-beta-checklist.md`, plus print-only
  `script/gpforum-private-beta-checklist` (`--commands` / `--status`; never
  claims readiness). Point ROADMAP / readiness review / README at it.
  Optional `make private-beta-checklist`. Does not change stress-load or
  deploy-checklist core logic.
- Make deploy-drill `nginx -t` succeed on non-root distro nginx: wrapper
  configs now place client/proxy temp paths under the throwaway prefix and
  rewrite sample `listen 80` to `127.0.0.1:18080`. When `nginx` is on
  `PATH`, host validation can reach `pass` instead of failing or staying
  skipped; missing nginx still skips/degrades. Record live `nginx -t` pass
  on a Cloud Agent VM after installing nginx via apt. Document a tuned
  stress-load profile `1000` re-run with `GPFORUM_WEB_PROCESSES=8` (p95
  improved vs 4 workers; still above default 2000 ms `--check` gate; 16
  workers worse on 4 vCPU) in `docs/ops/stress-load.md` /
  `docs/PERFORMANCE_EVIDENCE.md`.
- Strengthen `script/staging-drill-attachments` host validation: always keep
  static nginx/systemd template checks; when `systemd-analyze` / `nginx` are
  on `PATH`, run `systemd-analyze verify` and `nginx -t` against rendered
  sample configs (stub ExecStart paths / wrapper nginx.conf); missing tools
  skip those phases and may mark evidence `degraded`. Attachment drill now
  populates a throwaway `var/attachments` tree, wipes it, restores, and
  asserts digests. Docs/CHANGELOG/tests updated; stress-load harness
  untouched. Does not claim private-beta readiness.
- Record live `script/stress-load` evidence against Hypnotoad + seeded
  PostgreSQL (smoke / 100 / 500 pass; 1000 peak sustained with p95 residual) in
  `docs/ops/stress-load.md` and `docs/PERFORMANCE_EVIDENCE.md`. Prefer response
  codes over Mojo transport-error buckets for HTTP 4xx/5xx; report `ok` without
  `--check`. Optional `GPFORUM_FORUM_READ_RATE_LIMIT` for single-IP capacity
  runs above the default 60/60s forum retrieval ceiling.
- Add `script/staging-drill-attachments` / `bin/gpforum-staging-drill-attachments`
  for throwaway `FilesystemStorage` backup/restore round-trip and static
  nginx/systemd deploy template checks (`User`, `EnvironmentFile`,
  `ExecStart` via `script/gpforum-carton`, nginx upstream). Document MacPorts
  PostgreSQL `PATH` notes alongside attachment-path and live-deploy residual
  gaps in `docs/ops/staging-drills.md`. Optional `make staging-drill-attachments`
  is not part of default CI. Does not claim private-beta readiness.
- Docs: mark system Perl, PG concurrency/idempotency/outbox-reclaim evidence,
  staging-drill DB, stress-load harness, attachment/deploy drills, and
  MacPorts notes as shipped in `ROADMAP.md` / readiness review / README
  status; Next is recording staging evidence (stress 100/500/1000,
  attachment restore + live deploy), not missing harness code.
- Add `t/integration/postgres-outbox-reclaim.t`: skippable-unless-DSN evidence
  with two real PostgreSQL connections for expired `running` lock reclaim
  (concurrent SKIP LOCKED race), fresh-lock hold, and claim-crash-then-reclaim;
  wire it into CI beside the other PostgreSQL integration tests. Close the
  residual OUT-002 / FM-005 reclaim evidence gap in the transactional and
  failure-mode audits.
- Docs: align `ROADMAP.md` / release readiness with shipped mail delivery,
  moderation locks/idempotency, failure-mode coverage, and LISTEN/NOTIFY
  realtime; residual “Next” is evidence and staging, not missing MVP code.
- Docs: catalog `attachment.uploaded`, `attachment.deleted`,
  `report.assigned`, `report.released`, and `report.resolved` in
  `EVENTS.md`, ADR 0091, and ADR 0071 from emitting store payloads.
- Docs: point roadmap/status at ADR 0068 and ADR 0091. Architectural history
  is recorded in the ADR set.
- Loaded `Crypt::URandom` lazily from `Service::Id` so UUID minting no
  longer imports that XS module at compile time.
- Moved attachment per-post and per-attachment link fetch caps onto
  `Attachment::Lifecycle` so the store no longer owns those windows inline
  with resultset searches.
- Loaded `Crypt::URandom` lazily from `Password` and `SessionToken`, and
  `Service::Id` lazily from `Identity::Store` and its credential/session/token
  stores, so identity compile-time tests can inject `Test::Id` without that
  XS module.
- Loaded `Service::Id` lazily from `EventRecorder`,
  `Outbox::MessageBuilder`, and the event-backed stores that only used it
  for default construction so compile-time tests can inject `Test::Id`
  without `Crypt::URandom`.
- Moved community bookmark/subscription write-success statuses onto
  `Web::ForumAccess` so `Forum::Community` no longer owns those strings
  inline with store writes.
- Moved admin catalog/binding, moderation content/queue/suspension, and
  privacy review write-success statuses onto the existing `Web::*Access`
  objects so those controllers no longer own those strings inline with CSRF
  checks.
- Moved moderation permission action and resource names, plus admin and
  privacy catalog `view` actions, onto the existing `Web::*Access` objects
  so those controllers no longer own those strings inline with CSRF checks.
- Extracted `Web::OperationsAccess` for `/metrics` token presence, Bearer
  and `X-GPForum-Metrics-Token` comparison, and the unauthorized JSON
  payload so `Controller::Operations` no longer owns those contracts
  inline with snapshot rendering.
- Moved the 30-day authenticated cookie-session lifetime onto
  `Web::CookieSession` so `Controller::Identity` no longer owns
  `expires_at` inline with login rotation.
- Moved community `post`/`thread`/`user` target types onto
  `Web::ForumAccess` so `Forum::Community` no longer owns those strings
  inline with bookmark and report writes.
- Moved locale/theme preference-cookie names and Lax one-year options onto
  `Web::IdentityAccess` so `Identity::Base` and `Bootstrap::UI` share the
  same names without owning cookie writes there.
- Moved forum list page defaults, admin dashboard row caps, and identity
  profile thread limits onto the existing `Web::*Access` objects so those
  controllers no longer own the numbers inline with rendering.
- Moved `user`-scope `realtime.connect` / `realtime.subscribe` rate-limit
  hashes and plaintext handshake texts onto `Web::RealtimeAccess` so the
  websocket controller no longer owns those contracts inline with hub
  registration and telemetry.
- Moved identity_http rate-limit hashes onto `Web::IdentityAccess` so
  `Identity::Base` no longer owns login/register/password/logout/settings
  windows inline with CSRF telemetry.
- Moved search page, autocomplete, fetch, and more-results limits onto
  `Web::ForumAccess` so `Forum::Search` no longer owns those windows inline
  with degraded-search evals.
- Extracted `Web::AdminAccess` for catalog page limits, the
  `admin_console`/`manage` permission hash, Guard invalid-request titles,
  and the roles redirect so `Admin::Base` no longer owns those contracts
  inline with CSRF and telemetry.
- Extracted `Web::PrivacyAccess` for privacy list page limits, the
  `privacy_rights`/`manage` permission hash, `conflict` blocked-hold
  payloads, and Guard invalid-request titles so `Privacy::Base` no longer
  owns those contracts inline with CSRF checks.
- Extracted `Web::ModerationAccess` for report-queue page limits, default
  open/active filters, permission-target hashes, and Guard invalid-request
  payloads so `Moderation::Base` no longer owns those contracts inline with
  CSRF and telemetry.
- Extracted `Web::NotificationAccess` for inbox/mention page limits, the
  `notification_http` write rate-limit hash, and `failed`/`not_found`
  mapping so `Notifications::Base` no longer owns those contracts inline
  with CSRF and telemetry.
- Extracted `Web::AttachmentAccess` for upload rate-limit hashes, download
  filename sanitizing, content-disposition values, and Guard payloads so
  `Attachments::Base` no longer owns those contracts inline with CSRF checks.
- Extracted `Web::ForumAccess` for forum read/write rate-limit hashes,
  participation actions, report field errors, search filter names, public
  SSR cache keys, and integer limits so `Forum::Base` no longer owns those
  contracts inline with Guard rendering.
- Extracted attachment orphan-cleanup search, actor/reason fallbacks, and
  result hashes onto `Attachment::Lifecycle` so the store no longer owns
  those contracts inline with resultset deletes.
- Extracted login/logout AuditLog hashes onto `Identity::Event` so
  `Identity::SecurityAudit` no longer owns identifier hashing and request
  metadata inline with recorder writes.
- Extracted `Admin::Event` for role-binding and role-catalog AuditLog hashes so
  `RoleBindingStore` and `RoleCatalog` no longer own those contracts inline
  with row writes.
- Extracted suspend and revoke EventLog/AuditLog hashes onto
  `Moderation::Event` so `SuspensionStore` no longer owns those contracts
  inline with row writes.
- Extracted report created, duplicate-blocked, and transition EventLog/AuditLog
  hashes onto `Moderation::Event` so `ReportStore` no longer owns those
  contracts inline with row writes.
- Extracted `Moderation::Event` for created-action and reversal EventLog
  envelopes, payloads, and AuditLog hashes so `ActionStore` no longer owns
  those contracts inline with row writes.
- Extracted `Identity::Event` for `user.registered` envelopes, registration
  audit hashes, and typed identity audit arguments so `Identity::Audit` no
  longer owns those contracts inline with recorder writes.
- Extracted retention-hold EventLog/AuditLog hashes onto `Privacy::Event` so
  `RetentionHoldStore` no longer owns those contracts inline with row
  inserts.
- Extracted `Privacy::Event` for deletion-request, approval, hold, block, and
  completion EventLog hashes plus recorder EventLog/AuditLog arguments so the
  deletion workflow no longer owns those contracts inline with locks and
  row writes.
- Extracted `Attachment::Event` for EventLog envelopes, scan event types,
  payload hashes, and AuditLog arguments so the attachment store no longer
  owns those contracts inline with resultset writes.
- Extracted `Web::DiscoveryAccess` for sitemap/feed reader limits and crawler
  document rendering so the discovery controller no longer owns those
  contracts inline with category and thread reads.
- Extracted `Privacy::Completion` for approval/completion replay hashes, job
  done checks, skip payloads, and the default legal-hold reason so the
  deletion workflow no longer owns those results inline with locks and
  event writes.
- Extracted `Web::IdentityAccess` for identity CSRF text, rate-limit,
  system-failure, and bad-request rendering so the identity HTTP base no
  longer owns those contracts inline and does not reuse `Web::Guard`.
- Extracted `Attachment::Lifecycle` for upload replay, scan state
  transitions, and delete replay so the attachment store no longer owns those
  hashes inline with resultset writes.
- Extracted `Web::HomeAccess` for home reader limits, the success payload,
  and the custom `home_unavailable` 500 contract so the home controller no
  longer owns those hashes inline and does not reuse `Web::Guard`.
- Moved linked-versus-unlinked attachment download payloads onto
  `Attachment::DownloadAccess->authorized` so the store only preloads links
  and target rows.
- Extracted `Outbox::FailureType`, `Outbox::Retry`, and `Outbox::ClaimQuery`
  so the dispatcher no longer mixes failure classification, attempt/backoff
  policy, and PostgreSQL claim SQL with transport dispatch and row updates.
  `DeadLetterRecorder` loads `Service::Id` only when a production id service
  is needed.
- Split `ViewModel::Forum::Presenter` into row, page, and new-thread form
  helpers so the facade no longer mixes payload mapping with form defaults
  and thread-page assembly.
- Extracted `Privacy::Record` and `Privacy::Erasure` so deletion workflow no
  longer mixes row accessors and anonymized identity values with approval
  locks, hold blocking, and audit persistence.
- Extracted `Attachment::Record` and `Attachment::DownloadAccess` so the
  attachment store no longer mixes row accessors and download visibility
  with intent, scan, and audit persistence.
- Split `Service::I18N` into catalog lookup, locale negotiation, and
  date/number formatting helpers so the public facade no longer owns the
  bundled English and Italian strings inline.
- Extracted `Infrastructure::AuditRecord` for canonical audit hashing and
  verification so `EventRecorder` no longer mixes hash-chain construction
  with EventLog, OutboxMessage, and AuditLog persistence.
- Extracted `Web::PublicCacheAccess` for anonymous GET/HEAD cacheability and
  ETag/Last-Modified freshness so `PublicHttpCache` no longer mixes storage
  with validator decisions.
- Extracted `Web::CookieSession` for cookie-session presence, expiry, clearing,
  and login-value assembly so bootstrap identity and the login controller no
  longer mutate session keys inline.
- Extracted `Web::RealtimeAccess` for websocket origin, payload-size, and
  subscribe-message decisions so the realtime controller no longer mixes
  handshake rules with hub registration and telemetry.
- Extracted `Identity::RegistrationStore` for duplicate checks and
  transactional user/credential persistence so the identity store facade no
  longer owns registration writes.
- Extracted `Identity::AuthStore` for login credential verification and
  server-session creation so the identity store facade no longer owns
  authentication lookups.
- Extracted `Identity::AccountStore` for password reset, password change, and
  email-change persistence so the identity store facade no longer owns those
  token, credential, and user-row updates.
- Extracted `Identity::PreferenceStore` for locale and theme persistence so
  the identity store facade no longer owns preference row updates, and
  converted operations metrics auth helpers off postfix control.
- Extracted `Web::Access` for shared CSRF, session-user, and JSON decisions
  used by HTTP bases, identity settings, realtime, public cache, and session
  validation, leaving error rendering on `Web::Guard`.
- Routed identity locale/theme persistence and notification preference writes
  through `Identity::Workflow` and `Notification::Workflow`, keeping cookies
  and session rotation in the HTTP controllers.
- Split attachment and notification HTTP ownership, introduced
  `Attachment::Workflow` for post uploads and downloads, and
  `Notification::Workflow` for mark-read writes so controllers no longer
  look up posts, enforce authors, or map store exceptions themselves.
- Introduced `Identity::Workflow` as the write boundary for registration,
  login, logout, password, and email commands, keeping cookie-session rotation
  in the HTTP controller.
- Split privacy HTTP ownership into member dashboard, request, and staff
  review controllers, introduced `Privacy::Workflow` as the write boundary for
  export, deletion, hold, and erasure commands, and extracted `Web::Guard` for
  shared CSRF, auth, rate-limit, and error rendering used by privacy, admin,
  moderation, forum, attachments, and notifications.
- Split admin HTTP ownership into review, catalog, and binding controllers, and
  introduced `Admin::Workflow` as the write boundary for roles, permissions,
  and role bindings.
- Split moderation HTTP ownership into review, queue, action, and suspension
  controllers, and introduced `Moderation::Workflow` as the write boundary for
  report, content, and suspension commands.
- Added GitHub project success surface: CI, hygiene workflow, Dependabot,
  issue templates, pull request template, security policy, contributing guide,
  governance notes, support policy, roadmap, changelog, and ADR template.
