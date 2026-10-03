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
  metadata, robots.txt rules, sitemap entries, feed items, and prompt alignment.
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

- `my $undefined; return $undefined;` is now `return undef;` (ADR 0117), and
  the 63 dead returns after a final `UniqueConflict->rethrow` are gone. The
  profile no longer applies `ProhibitExplicitReturnUndef` and treats
  `rethrow` and `throw` as terminal for `RequireFinalReturn`.

- Every Perl file declares `use v5.40;` in place of `use strict;` and `use
  warnings;`, on the line after each `use Mojo::Base` (ADR 0117).
  `t/321-preamble.t` holds every file to it and names the files still to be
  converted. The profile no longer applies `ProhibitVersionStrings`.

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
- Docs: point roadmap/status at ADR 0068 and ADR 0091; keep prompt files as
  historical constitutions.
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
