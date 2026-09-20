# Changelog

All notable changes to GPForum are recorded here.

## Unreleased

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

- Add `script/bootstrap-deps --rebuild-local` to rename an incomplete or
  foreign-Perl `local/` to `local.rebuild.<epoch>` before Carton reinstall
  (still never `rm -rf local/`). Helps Cloud Agent / operator hosts where a
  partial `local/` leaves modules like `Const::Fast` missing.

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

- Add operator `script/staging-host-verify` / `bin/gpforum-staging-host-verify`
  and `docs/ops/staging-host.md`: non-destructive staging bring-up verify
  (in-repo deploy/runbook artifacts; optional `--env-file` key presence with
  values redacted, `--systemd` `is-active`, `--base-url` health/metrics).
  Documents the evidence archive commands for mail-check, stress-load, and
  staging drills. Wired into `docs/ops/private-beta-checklist.md`. Optional
  `make staging-host-verify`; not part of default CI. Does not install units
  or claim private-beta readiness.

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

- Add `script/gpforum-macports-env` for macOS MacPorts operators: detect
  `/opt/local` PostgreSQL client bins, print `export PATH=...` lines, and
  optionally verify `psql` / `pg_dump` / `pg_config`. No-op skip on Linux CI.
  Accept MacPorts `/opt/local` perl as system Perl in
  `script/gpforum-system-perl` (still refuse perlbrew / plenv / asdf).

- Record live `script/stress-load` evidence against Hypnotoad + seeded
  PostgreSQL (smoke / 100 / 500 pass; 1000 peak sustained with p95 residual) in
  `docs/ops/stress-load.md` and `docs/PERFORMANCE_EVIDENCE.md`. Prefer response
  codes over Mojo transport-error buckets for HTTP 4xx/5xx; report `ok` without
  `--check`. Optional `GPFORUM_FORUM_READ_RATE_LIMIT` for single-IP capacity
  runs above the default 60/60s forum retrieval ceiling.

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

- Add `t/integration/postgres-idempotency.t`: skippable-unless-DSN two-connection
  evidence for concurrent `event_idempotency_keys` `mark_done` and reputation
  source unique races inside open `txn_do`. `EventIdempotencyStore` and
  `ReputationLedger` wrap inserts with `UniqueConflict->attempt` so unique
  violations do not abort the outer transaction on live PostgreSQL.

- Require the OS system Perl (`/usr/bin/perl` / distro package) for bootstrap,
  Carton, make, CI, and docs. Refuse version managers and custom PREFIX
  installs via `script/gpforum-system-perl`; document distro packages and
  `perl -V` preflight.

- Add `t/integration/postgres-concurrency.t`: skippable-unless-DSN evidence
  with two real PostgreSQL connections for command_log, bookmark,
  subscription, open report, moderation hide, audit chain, privacy approval,
  and identity token consume races; wire it into CI beside `postgres.t`.
  `UniqueConflict->attempt` wraps inserts in a savepoint so unique races can
  replay inside an open `txn_do` on real PostgreSQL. Command-log payload
  updates read inflated JSON accessors, and identity token/session expiry
  compares parsed epochs so PostgreSQL timestamptz text does not false-expire.

- Add `script/staging-drill` / `bin/gpforum-staging-drill` and
  `docs/ops/staging-drills.md` so operators can rehearse fresh migrate,
  upgrade-from-previous, and `pg_dump`/`pg_restore` on throwaway databases
  with pasteable pass/fail evidence. Attachment files under
  `var/attachments` remain outside the dump/restore scope; full
  nginx/systemd deploy stays a manual runbook. Optional `make staging-drill`
  is documented and is not part of default CI.

- Docs: align `ROADMAP.md` / release readiness with shipped mail delivery,
  moderation locks/idempotency, failure-mode coverage, and LISTEN/NOTIFY
  realtime; residual “Next” is evidence and staging, not missing MVP code.
- Docs: catalogue `attachment.uploaded`, `attachment.deleted`,
  `report.assigned`, `report.released`, and `report.resolved` in
  `EVENTS.md`, ADR 0091, and ADR 0071 from emitting store payloads.
- Docs: point roadmap/status at ADR 0068 and ADR 0091; keep prompt files as
  historical constitutions.

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

- Registration remints user `id` once when the unique primary key
  conflicts, and does not return another user's account.

- Registration reuses a leftover user `id` with this username and email
  and inserts the missing credential.

- Password credential writes remint `id` once when the unique primary key
  conflicts, and do not return another user's credential.

- Password credential writes reuse a leftover credential `id` with this
  user and do not insert a second active secret.

- Command log writes remint `command_id` once when the unique primary key
  conflicts, and do not replay another command.

- Command log writes reuse a leftover `command_id` with this idempotency
  key and finish the command.

- Identity token writes remint `token_id` once when the unique primary key
  conflicts, and do not return another user's token.

- Identity token writes reuse a leftover `token_id` with this user and
  hash and do not insert a second token.

- Session writes remint `session_id` once when the unique primary key
  conflicts, and do not return another user's session.

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

- Identity token writes retry hash allocation once when the unique
  `token_hash` key conflicts, and do not return another user's token.

- Session writes retry hash allocation once when the unique `session_hash`
  key conflicts, and do not return another user's session.

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

- Identity mail outbox retry after send and before `mark_done` resends
  from the outbox payload. EventLog still omits the raw token.

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

- A registration unique race on username or email returns the same
  duplicate field errors and does not insert a second pending user.

- A second unused password-reset, email-change, or email-verification
  token for the same user replaces the open row instead of inserting
  another. The previous unused hash is invalidated. Email verification
  is a legal `identity_tokens.token_type`.

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

- Identity store and command-log failures return HTTP 503 without leaking
  the exception. A lost register, login, logout, password-change, locale,
  theme, settings, attachment upload, attachment delete, token-issuance,
  or token-consume response retried with the same `command_id` does not
  create a second pending account, open a second session, revoke a session
  twice, rotate a password twice, persist a preference twice, store a
  second file, soft-delete twice, issue a second token, or consume a token
  twice.

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

- Restoring a hidden or author-deleted thread reindexes the thread search
  document and every post in that thread. `thread.deleted` and
  `thread.hidden` already removed those post documents.

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

- HTML mark-read and attachment upload now set a success flash and
  redirect. Mark-read lands on `/notifications`; upload lands on the
  post permalink. JSON responses are unchanged.

- Member data export now copies real posts, attachments, notifications,
  subscriptions, preferences, and profile fields (including email) into
  the completed `ExportRequest` manifest. Placeholder `{index}` rows are
  gone. Storage object keys and password hashes stay out of the bundle.
  EventLog still records counts only. `GET /privacy/export/:id` downloads
  the JSON for the signed-in subject; the dashboard links completed
  exports.

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

- Identity password-reset, email-change, and verification mail is queued
  on the outbox in the same transaction as token issuance. EventLog keeps
  `kind` and `token_id` only; the raw token lives on the outbox `mail`
  payload until the `IdentityMail` worker delivers it. A crash after
  issuance no longer drops the message.

- Mojolicious keeps the current `GPFORUM_SESSION_SECRET` first for new
  cookies and still validates previous secrets from
  `GPFORUM_SESSION_SECRETS`. `/metrics` accepts previous scrape tokens from
  `GPFORUM_METRICS_TOKENS`. Staging and production reject the development
  default in both the current secret and the previous list.

- A classified permanent outbox failure cancels and dead-letters on that
  attempt. Cancelled rows are not claimed again. Operator review is
  `docs/ops/dead-letters.md`.

- An outbox worker that claims a row and crashes before dispatch leaves
  the message `running`. Another worker does not take a fresh lock; after
  the lock expires the row is reclaimed and delivered once.

- Erasure that fails after credential and session revocation rolls back
  the user identity and leaves the job pending. A later `complete_job`
  anonymizes the member and revokes access.

- A lost HTTP response can be retried with the same `command_id`. Reply,
  thread, report, hide, and export return the original resource and do
  not insert a second row.

- `GPFORUM_MINION_ENABLED=1` fails closed when the Minion PostgreSQL
  backend is missing or unreachable. `bin/gpforum-outbox-dispatch` skips
  Minion and keeps draining the canonical outbox.

- Thread, report, hide, and privacy approval writes roll back on a
  statement timeout during EventLog, outbox, or audit insert. Domain
  mutations inside the transaction are restored; no event, outbox, or
  audit row commits.

- Write routes map store and command-log failures to HTTP 503
  `service unavailable` without leaking DBI text. `create_reply`,
  thread report, moderation hide, and privacy export share that
  contract. Unexpected application errors still use HTTP 500.

- Staging and production profiles send
  `Strict-Transport-Security: max-age=31536000; includeSubDomains` and mark
  session cookies Secure. Development and test omit HSTS and the Secure
  flag. `production-small` and `production-medium` follow the same TLS
  cookie/HSTS policy as `production`.

- App PostgreSQL sessions set `statement_timeout` (15s),
  `idle_in_transaction_session_timeout` (10s), `lock_timeout` (3s), and
  `application_name=gpforum` on connect. Override with
  `GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS`,
  `GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS`, and
  `GPFORUM_DATABASE_LOCK_TIMEOUT_MS` (0 disables that timeout).
  `gpforum-migrate --apply` clears `statement_timeout` after connect so
  DDL is not capped at the web budget.

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

- Privacy export retries with the same `command_id` replay from
  `command_log` after the bundle is already completed. Open deletion
  requests are unique per resource (`pending`/`approved`/`held`); pending
  exports are unique per requester/subject/type/format; active retention
  holds are unique per resource while `ends_at` is null. A later
  `command_id` can still open a new export after complete.
  `DeletionWorkflow->hold_request` stays four arguments besides the
  invocant.

- Outbox worker handlers and the realtime fallback now wrap dispatch in
  `IdempotentJobRunner` with catalog keys `worker.<name>:{event_id}`.
  `EventIdempotencyStore` inserts into `event_idempotency_keys` only on
  `mark_done`, so a crash between `transport->dispatch` and outbox ack
  retries the message without skipping unfinished side effects. Replay of
  the same event is absorbed for search, notification, cache, attachment,
  media, feed, reputation, and realtime.

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

- Hidden posts now drop their `user_feed_items` rows through
  `FeedProjector->remove_item`; restore re-projects the author and thread
  subscribers with the existing `project_item` API. There is no
  `thread.hidden` event.
- Moderation hide, restore, lock, and unlock HTTP writes now mint and
  pass `command_id` the same way forum posting does, so ActionStore
  replay can fire on retry.
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
- Wired the existing `forum_retrieval` limiter on `GET /search`, and added
  `write_rate_input` hashes on `Web::ModerationAccess`, `Web::AdminAccess`,
  and `Web::PrivacyAccess` so moderation writes, admin writes, and privacy
  requests share the same CSRF/telemetry write helpers as forum
  `write_user_id`.
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
- Delivered private-beta identity mail for password reset, email change,
  and registration verification through an injectable `Email::Sender`
  mailer. Pending accounts no longer receive a session until the
  verification token is confirmed, and the login page links to forgot
  password. `Email::Address::XS` 1.05 is a declared runtime pin so
  `Email::Sender::Simple` can load.
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
- Updated every locked CPAN distribution to its latest release and pruned
  32 orphaned distributions from `cpanfile.snapshot` (187 -> 157). DBI moves
  from 1.647, which carried 11 CPANSA advisories, to 1.653; URI, HTTP::Date,
  and List::SomeUtils::XS also leave vulnerable versions. Security floors for
  those transitive dependencies are now declared in `cpanfile`, and
  `cpan-audit` reports no open advisories apart from the two unfixed
  Mojolicious default-secret advisories, which `GPFORUM_SESSION_SECRET`
  enforcement already mitigates.
- Install and bootstrap now recognize CPAN distributions from `cpanfile`
  plus the `postgres` feature in `cpanfile.postgres`, and fetch only
  through Carton (`make install-deps` / `script/bootstrap-deps`) using
  `carton install --deployment`, `cpanfile.snapshot` pins, and the
  official MetaCPAN HTTPS mirror. Carton is resolved via
  `script/gpforum-carton` when it is not on PATH. The previous unpinned
  `cpanm --notest` PostgreSQL sideload is gone.
- Loaded `Crypt::URandom` lazily from `Service::Id` so UUID minting no
  longer imports that XS module at compile time.
- Moved attachment per-post and per-attachment link fetch caps onto
  `Attachment::Lifecycle` so the store no longer owns those windows inline
  with resultset searches.
- Loaded `Crypt::URandom` lazily from `Password` and `SessionToken`, and
  `Service::Id` lazily from `Identity::Store` and its credential/session/token
  stores, so identity compile-time tests can inject `Test::Id` without that
  XS module.
- Made GlifiStore the required disposable L2 cache for public SSR and
  category read-model seams; staging and production fail closed when
  `GPFORUM_GLIFISTORE_URL` is missing, while PostgreSQL stays authoritative.
- Raised runtime CPAN floors to current secure releases, including
  Mojolicious 9.49, Cpanel::JSON::XS 4.52 (CVE-2026-9334,
  CVE-2026-9516), Crypt::Argon2 0.032, DateTime 1.67, DBD::Pg 3.21.2,
  and Mojo::Pg 5.0.
- Rejected non-hash JSON in `Outbox::ClaimedMessage` so Cpanel::JSON::XS
  4.42+ `allow_nonref` cannot treat scalar payloads as outbox events.
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
- Wired operational profiles into `platform-check` and readiness so undersized
  production floors fail the same gate as OS preflight and query-budget drift.
- Added versioned operational profiles for development, staging,
  production-small, and production-medium, plus a partition lifecycle policy
  for monthly planning, retention detach, archival states, and restore
  evidence.
- Split admin HTTP ownership into review, catalog, and binding controllers, and
  introduced `Admin::Workflow` as the write boundary for roles, permissions,
  and role bindings.
- Split moderation HTTP ownership into review, queue, action, and suspension
  controllers, and introduced `Moderation::Workflow` as the write boundary for
  report, content, and suspension commands.
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
- Added GitHub project success surface: CI, hygiene workflow, Dependabot,
  issue templates, pull request template, security policy, contributing guide,
  governance notes, support policy, roadmap, changelog, and ADR template.
- Added notification subscriptions, preferences, inbox projection, read state,
  and fanout services.
- Added worker phase boundaries, outbox dispatch, projection tracking, and
  platform governance migrations.
- Added core identity/session, forum write, event/audit, and projection schema
  foundations.
