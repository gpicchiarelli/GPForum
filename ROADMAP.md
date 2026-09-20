# Roadmap

The binding roadmap source is
[ADR 0068](docs/adr/0068-mvp-roadmap-sequencing.md)
(MVP sequencing). Architecture and event-catalog discipline follow
[ADR 0091](docs/adr/0091-executable-architecture-contract.md).
Historical constitutions remain in [prompt/20.txt](prompt/20.txt) and
[prompt/43.txt](prompt/43.txt); they are not the binding source.

## Where things stand

GPForum has completed **Milestones 0–10** under
[ADR 0068](docs/adr/0068-mvp-roadmap-sequencing.md) (Forum HTTP MVP through
advanced community features). Earlier “Milestone 17” wording referred to the
same HTTP MVP surface; the binding milestone set is ADR 0068.
The latest [release-readiness review](docs/release/readiness-review.md)
places it at:

| Target | Status |
| --- | --- |
| Local, personal use | Ready |
| Private beta | Not yet |
| Public production | Not yet |

## Shipped

- Identity and sessions: registration, login, server-side sessions, password
  and email lifecycle tokens.
- Mail delivery for identity lifecycle: `Identity::Mailer`,
  `Worker::Handler::IdentityMail`, and lifecycle tests
  (`t/146-identity-mailer.t`, `t/154-identity-mail.t`; see
  [docs/audit/email-lifecycle.md](docs/audit/email-lifecycle.md)).
- Forum read and write workflows with keyset pagination.
- Outbox events connected to Minion worker handlers, with retries and dead
  letters.
- PostgreSQL-native search indexing and permission-aware querying.
- Moderation, administration, and audit review interfaces.
- Concurrent moderation correctness in code: `ActionStore` row locks
  (`FOR UPDATE`) and unique `command_id`; report/moderation workflows use
  command idempotency (migrations `026+`).
- Database-backed and fake failure-mode coverage for writes with the DB
  unavailable, lost-response retry, outbox handler idempotency, and related
  engineering correctness (see
  [docs/audit/failure-modes.md](docs/audit/failure-modes.md):
  `t/152-write-unavailable.t`, `t/153-lost-response-retry.t`,
  `t/150-outbox-handler-idempotency.t`, `t/86-engineering-correctness.t`).
- Realtime domain fanout via PostgreSQL `LISTEN`/`NOTIFY`
  (`docs/realtime.md`); each web process listens so websocket delivery stays
  process-local by design.
- Rate limits, feed/trust projections, and uniqueness migrations through
  `036`.
- Web access, workflow, and event boundaries recorded in [ADRs](docs/adr).
- OS system Perl gate for bootstrap, Carton, make, and CI
  (`script/gpforum-system-perl`; distro `/usr/bin/perl` / FreeBSD path /
  MacPorts `/opt/local/bin/perl`; refuse version managers).
- macOS MacPorts PATH helper for PostgreSQL client tools
  (`script/gpforum-macports-env`; no-op on Linux).
- PostgreSQL two-connection integration evidence (skip unless
  `GPFORUM_DATABASE_DSN`): concurrency races in
  `t/integration/postgres-concurrency.t`, idempotency/reputation in
  `t/integration/postgres-idempotency.t`, expired outbox `running` lock
  reclaim in `t/integration/postgres-outbox-reclaim.t` (wired in CI beside
  `postgres.t`). Audits treat those residuals as evidence-closed.
- Operator staging DB drill: `script/staging-drill` /
  `docs/ops/staging-drills.md` for fresh migrate, upgrade-from-previous, and
  `pg_dump`/`pg_restore` on throwaway databases (MacPorts PostgreSQL path
  notes included).
- Attachment filesystem + deploy checklist drill:
  `script/staging-drill-attachments` (populated throwaway `var/attachments`
  backup/restore; static nginx/systemd checks plus host `systemd-analyze
  verify` / `nginx -t` when tools are on `PATH`). Live target install/
  reload evidence remains open.
- Operator stress-load harness: `script/stress-load` /
  `docs/ops/stress-load.md` with profiles `smoke` / `100` / `500` / `1000`
  (live Hypnotoad+PG VM appendix recorded; staging target numbers still open).

## Next

- Stress tests at 100, 500, and 1000 users on representative **staging**
  hardware via `script/stress-load` (`docs/ops/stress-load.md`); Cloud Agent
  VM evidence (smoke/100/500 pass; 1000 peak with p95 residual) is archived
  in the ops appendix — staging/TLS target numbers remain open.
- Attachment restore + full staging deploy drills via
  `script/staging-drill-attachments` / `docs/ops/staging-drills.md` (populated
  `var/attachments` + static/host nginx/systemd checks are shipped; live
  target install/reload evidence and private-beta claim remain open).
- Close remaining private-beta blockers listed in
  [docs/release/readiness-review.md](docs/release/readiness-review.md)
  (staging deploy evidence, attachment restore drill, SMTP/mail staging,
  operator runbooks). Do not treat private beta as ready until that evidence
  exists.

## Release readiness

A public release requires:

- stable migrations and rollback discipline;
- CI green on every pull request;
- coverage and profiling artifacts for hot paths;
- security policy and private reporting path;
- documented support boundaries;
- ADR coverage for major deviations.

The full gate is [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md).
