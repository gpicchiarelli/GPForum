# GPForum release-readiness review

Date: 2026-09-20 (refresh post-merge through outbox reclaim / PG evidence
on `main`; earlier baseline 2026-06-02).

Purpose: assess GPForum after the stabilization patches without introducing new
features. This review distinguishes three levels: personal local use, private
beta, and public production.

## Release verdict

| Target | Verdict | Technical rationale |
| --- | --- | --- |
| LOCAL READY | yes | Full suite, coverage, fresh/upgrade migrations, local backup/restore, query budget, local smoke/stress benchmarks, and the security/failure suite are all green. |
| PRIVATE BETA READY | no | Harness + Cloud Agent live/stress archives (`docs/ops/evidence/2026-09-20-cloud-agent-live/` profile `100`; `docs/ops/evidence/2026-09-20-cloud-agent-stress500/` profiles `500` pass + `1000` ok with p95 residual). Still missing: evidence on **real staging TLS** (SMTP `--send`, stress 500/1000 against the target, deploy/systemd install). **PRIVATE BETA NOT YET.** |
| PUBLIC PRODUCTION READY | no | Missing an end-to-end representative staging environment, stress numbers for 100/500/1000 against a TLS target, a live attachment restore drill, and a rollback runbook rehearsed on the target (harness/drill are in tree). |

Final recommendation: GPForum is ready for personal local use and for further
hardening on staging. It is not ready for a self-service private beta or for
public production.

## Minimal patches applied during the review

| Severity | Patch | File | Risk mitigated | Test |
| --- | --- | --- | --- | --- |
| HIGH | Qualified the `me.*` filters in `PostReader::list_thread_posts` | `lib/GPForum/Service/Forum/PostReader.pm` | 500 on `/t/:thread_id` against real PostgreSQL from an ambiguous `deleted_at` after joining `post_bodies` and `users` | `t/21-forum-pagination.t`, `t/31-forum-http-readers.t`, real-DB reproduction on a seeded thread |
| HIGH | Added `EnvironmentFile=/etc/gpforum/gpforum.env` to the systemd units | `deploy/systemd/*.service` | Production systemd deploy without explicit secret/DB environment | `t/18-github-project.t` |
| HIGH | Documented `script/query-budget --sync` before readiness | `docs/DEPLOYMENT.md`, `docs/PRODUCTION_READINESS.md` | Fresh install migrated but readiness returning 503 because the query budget catalog is empty | `t/18-github-project.t`, real DB with `query-budget --sync --check` |

## Go / No-Go table

| Area | State | Evidence | Residual risk | Required action |
| --- | --- | --- | --- | --- |
| Full test suite | GO | `carton exec script/test` PASS (suite has grown past the 2026-06-02 baseline) | None blocking locally | Keep it in CI |
| Fresh install migrations | GO locally | Schema versions `001`–`036` (36 migrations) on `main`; the fresh path still has to be repeated on the staging target | Not yet on the staging target | Repeat on a staging PostgreSQL identical to production |
| Upgrade migrations | GO locally | Historical 024→025 path; the later uniqueness/concurrency migrations (`026`–`036`) are present in the tree | The full upgrade chain has not been re-run end-to-end on staging | Repeat from a staging/restored snapshot through `036` |
| Migration rollback | NO-GO for production | Forward-fix strategy documented in `docs/PRODUCTION_READINESS.md` | Rollback not rehearsed with a real system/nginx/systemd | Forward-fix rehearsal and restore drill on staging |
| Perl::Critic | GO | `script/perlcritic`: `new_violations=0` | Known baseline violations remain, but no new ones | Do not widen the baseline without review |
| Perltidy | GO | `script/perltidy-check`: PASS | None | Keep the gate |
| Coverage | GO | `script/coverage`: PASS (gate) | Some operational modules have low coverage, but the gate passes | Raise coverage on realtime/controllers only when they are touched |
| Smoke benchmarks | GO | Fixture and configured benchmarks green | Local numbers, not staging | Repeat with a representative dataset |
| Stress benchmarks | PARTIAL | Harness + live VM archives: smoke/100 + `docs/ops/evidence/2026-09-20-cloud-agent-stress500/` (500 `--check` pass ~574 req/s; 1000 peak ok, p95 residual ~2.1–2.5 s); see `docs/ops/stress-load.md` | Staging/TLS target 100/500/1000 not yet recorded; 1000 p95 on 4 vCPU | Re-run on staging hardware; archive JSON beside the VM appendix |
| Query budget | GO | `script/query-budget --sync`, `--check`: PASS; the thread route uses at most 3 queries, budget ok | The catalog must be synchronized on deploy | Run sync/check after every migration deploy |
| Query plan | GO | `script/query-plan-check`: `offset_violations=0`; `query-plan-evidence` PASS on small | Small local dataset | Medium/hot-thread staging evidence |
| Security audit | PARTIAL GO | Targeted security suite PASS | Bot/device anomaly detection is not advanced | Extend the security tests before beta |
| Failure mode tests | GO evidence | FM-001–FM-007 + FM-008–FM-010; reclaim OUT-002 closed in the audit (`t/152`/`t/153`/`t/150`/`t/86`, `t/integration/postgres-{concurrency,idempotency,outbox-reclaim}.t`) | Skipped without a DSN; staging reclaim end-to-end is still manual | Keep the suite green with a DSN in CI/ops |
| Backup/restore | GO locally / PARTIAL on staging | `pg_dump -Fc` / `pg_restore`; `script/staging-drill` + `script/staging-drill-attachments` (MacPorts notes in `docs/ops/staging-drills.md`) | Live staging RPO/RTO incomplete | Staging restore drill with attachments + deploy target |
| Session security | GO | Server-side sessions, revocation, expiry, cookie flags, and CSRF covered by the security suite | Global session revocation / device anomaly detection are not advanced | Acceptable locally, extend for beta |
| Rate limiting | GO | PostgreSQL limiter, fallback telemetry, and blocked-audit coverage | The local-memory fallback is not cluster-wide | In beta use the PostgreSQL store and monitor the fallback |
| Email lifecycle | GO in code | Password/email reset and change, single-use tokens, `Identity::Mailer`, `Worker::Handler::IdentityMail`, `docs/audit/email-lifecycle.md`, `t/146-identity-mailer.t`, `t/154-identity-mail.t`, operator `script/gpforum-mail-check` (`docs/ops/mail-check.md`) | Staging SMTP/sendmail evidence not yet recorded | Run `script/gpforum-mail-check --dry-run` / `--send` on staging before self-service beta |
| Moderation workflow | GO evidence | Report/hide/lock/workflow PASS; `FOR UPDATE` + unique `command_id`; hide race in `t/integration/postgres-concurrency.t` | Staging with real users still has to be drilled | Drill moderation on staging before beta |
| Privacy/export/deletion | GO evidence / PARTIAL ops | Privacy rights PASS; erasure idempotency `024`; approval race in `postgres-concurrency.t` | Restore evidence with attachments is still open | Attachment restore drill |
| Audit trail integrity | GO evidence | `record_hash` + `pg_advisory_xact_lock`; two appends in `postgres-concurrency.t` | No priority residual evidence gap | Keep it green with a DSN |
| Logging and metrics | PARTIAL GO | `/metrics` with an app-level token, DB query stats, outbox, readiness, OS runtime evidence | Process-local metrics are not aggregated, external alerting is absent | Scrape/alert on staging, aggregation or runbook |
| Hypnotoad deployment | PARTIAL GO | Hypnotoad smoke PASS, systemd/nginx templates present, environment file added | Not rehearsed with real systemd/nginx on the target | Full staging deploy |
| Reactor backend | PARTIAL | Local macOS actual reactor `Mojo::Reactor::Poll`, documented in `docs/ops/reactor-backend.md` | Mismatch with the declared backend; EV not installed locally | Verify the reactor on Linux/FreeBSD staging |
| Config dev/staging/prod | GO | Production rejects the default secret; prod/staging read the professional profile | The systemd environment file must be created outside the repository | Manage `/etc/gpforum/gpforum.env` with a secret manager |
| Secret management | PARTIAL GO | The default secret is blocked in production, no production secret is in the repository | No automatic or documented rotation | Define rotation for secrets and the DB password |
| Operational documentation | PARTIAL GO | Production readiness, deployment, observability, reactor docs, and `docs/ops/private-beta-checklist.md` are present | The public checklist has not been rehearsed on staging | Run the runbook and record the evidence |

## Commands executed

Historical baseline (2026-06-02). The commands below document that review; they
were not re-run for this documentation refresh. The schema on `main` is now at
36 migrations (`001`–`036`).

| Command | Outcome | Relevant output |
| --- | --- | --- |
| `carton exec script/perl-syntax-check` | PASS | All Perl/bin/script/test files syntax OK |
| `script/perltidy-check` | PASS | No file is not perltidy-clean |
| `script/perlcritic` | PASS | `perlcritic status=ok baseline_violations=695 new_violations=0` |
| `script/architecture-check` | PASS | No boundary/cycle violation detected |
| `script/query-plan-check` | PASS | `status=ok indexes=31 offset_violations=0` |
| `git diff --check` | PASS | No whitespace error |
| `carton exec script/test` | PASS | `Files=87, Tests=4680` |
| `script/coverage` | PASS | `Files=87, Tests=4680`, total coverage 88.0% |
| Fresh migrate on a temporary DB | PASS | 25 migrations at the time; `001`–`036` today |
| Upgrade 024 -> 025 on a temporary DB | PASS | `upgrade_schema_versions_before=24`, `25` afterwards, `identity_tokens_after=t` |
| `script/seed-benchmark --profile small` | PASS | 5 users, 3 categories, 12 threads, 96 posts |
| `script/query-budget --sync` | PASS | `synced 24 endpoint query budgets` |
| `script/query-budget --check` | PASS | `ok endpoint query budgets aligned` |
| `script/query-plan-evidence --check` | PASS | 12 endpoints ok, no violations |
| `carton exec bin/gpforum-platform-check --with-db` | PARTIAL | `query_budget_drift status=ok`, `os_preflight status=degraded` on the local Mac because of CPU/process counts |
| `pg_dump -Fc` + `pg_restore` | PASS | Restore with 25 migrations at the time; 36 versions today |
| `script/gpforum-os-preflight --json` | DEGRADED | Local CPU count 1, web process default 4 capped to CPU; fd limit OK |
| `script/benchmark-http --fixture --check ...` | PASS | `/categories` p95 1.637 ms, thread fixture p95 23.375 ms |
| `carton exec script/bench-outbox-dispatcher --messages 1000,10000 --workers 1,2,4` | PASS | 0 lost, 0 duplicates, up to 10k messages |
| `script/benchmark-http --configured --check ...` | PASS after fix | Thread hot path p95 7.917 ms, max 3 DB queries, budget ok |
| `script/bench-hypnotoad --check --profile hot-thread --workers 2 ...` | PASS | Error rate 0, thread p95 7.295 ms, budget ok |
| `script/bench-hypnotoad-scaling --check --profile hot-thread --worker-set 2,4 ...` | PASS | Workers 2/4 ok, 0 duplicate DB queries |
| Targeted security/failure suite | PASS | 15 files, 773 tests |
| Production config default-secret check | PASS | `production requires GPFORUM_SESSION_SECRET` |
| Production config with secret/token | PASS | `clients=250 backlog=256 requests=1000 nofile=65536 metrics_token=set` |
| Reactor probe | PARTIAL | `Mojo::Reactor::Poll`; `EV.pm` not installed locally |

## Production blockers

### BLOCKER

| Blocker | Impact | Required action |
| --- | --- | --- |
| No full staging deploy with systemd/nginx/Hypnotoad and a target DB | Throwaway DB drill + `script/staging-host-verify` / `docs/ops/staging-host.md` are shipped; end-to-end nginx/systemd on the target is missing | Run the bring-up from `docs/ops/staging-host.md`, then `script/staging-host-verify --env-file … --systemd --base-url …` and archive the JSON |
| Representative stress test not executed | Live Hypnotoad+PG evidence on the Cloud Agent VM archived in `docs/ops/stress-load.md` + `docs/ops/evidence/2026-09-20-cloud-agent-stress500/` (smoke/100/500 pass; 1000 peak ok, p95 residual); the staging target is missing | Re-run the load test on staging with p50/p95/p99, error rate, worker distribution, DB latency |
| Backup/restore not rehearsed on staging with attachment storage | DB dump/restore + `script/staging-drill-attachments` are shipped; live target evidence is missing | Full restore drill: DB + attachments + readiness on staging |
| Mail delivery not drilled on staging | Adapter + `script/gpforum-mail-check` are in code; staging evidence is not yet archived | Run `script/gpforum-mail-check --dry-run` / `--send` on staging |

### HIGH

| Risk | State | Required action |
| --- | --- | --- |
| `command_log` concurrent race | Closed in code + PG evidence (`postgres-concurrency.t`) | Keep it green with a DSN |
| Bookmark/subscription check-then-insert | Closed in code + PG evidence | Keep it green with a DSN |
| Duplicate open reports | Closed: unique `026` + catch + PG evidence | Keep it green with a DSN |
| Moderation actions without a uniform command-id/row lock | Closed in code + PG hide evidence; `command_log` on assign/release/resolve/… | Keep it green with a DSN |
| Failure mode DB down/timeout/write after commit | Closed with fake/DB-backed tests + PG concurrency/idempotency/reclaim | Keep the FM + integration suite green |
| Audit chain not serialized | Closed in code + PG evidence for two appends | Keep it green with a DSN |
| Privacy deletion/hold/export can be duplicated | Closed in code + PG approval race; hold/export HTTP replay | Keep it green; restore with attachments remains a BLOCKER |

### MEDIUM

| Risk | State | Required action |
| --- | --- | --- |
| Local Poll reactor backend | Documented | Verify on Linux/FreeBSD staging, decide the EV/native policy |
| Process-local metrics | Acceptable for a single node | Aggregate the scrape or document a dashboard for multiple workers |
| OS preflight degraded on the local Mac | Does not block the code | Run the preflight on the target host |
| Minion optional | Direct outbox is available and independent of Minion; the web tier fails closed when Minion is enabled and the backend is missing | Use `GPFORUM_MINION_ENABLED=1` on staging only with a reachable backend |
| Low coverage in some operational modules | Total gate is green | Raise coverage when those modules are touched |

### LOW

| Risk | State | Required action |
| --- | --- | --- |
| Historical Perl::Critic baseline | The gate blocks new violations | Reduce the baseline opportunistically |
| macOS benchmarks are not representative | Documented | Do not use them for public capacity planning |
| Query budget requires a manual sync | Documented and tested | Keep the step in the runbook and in CI |

## Private beta checklist

Operator aggregate (commands + go/no-go, **without** any readiness claim):
[docs/ops/private-beta-checklist.md](../ops/private-beta-checklist.md) and
`script/gpforum-private-beta-checklist --commands` / `--status`.

Before a self-service private beta:

- CI green on the candidate commit.
- Fresh install and upgrade applied to staging (through migration `036`).
- `script/query-budget --sync` and `--check` green on staging.
- `/health/live`, `/health/ready`, and `/metrics` with a token green on staging.
- Mail delivery configured and drilled for password reset and email change
  (`script/gpforum-mail-check`).
- DB backup/restore + attachment storage rehearsed
  (`script/staging-drill`, `script/staging-drill-attachments`).
- Failure suite FM-001–FM-010 green; PG integration
  (`postgres-concurrency` / `postgres-idempotency` / `postgres-outbox-reclaim`)
  green with a DSN, or an accepted manual support runbook.
- Basic moderation rehearsed with real users and seeded roles.
- Outbox dead letters observed with a controlled failure.
- Stress test with at least 100 concurrent users on `/categories`, the thread
  view, search, and replies (`script/stress-load`).

## Public production checklist

Before the public go-live:

- All BLOCKERs closed.
- All HIGH risks closed or formally accepted with mitigation and rollback.
- Stress at 100/500/1000 users on staging with p50/p95/p99, error rate, DB
  latency, and worker distribution.
- PG integration is already in tree; repeat it on the staging target with a real
  DSN.
- Backup/restore with measured RPO/RTO (including attachment blobs).
- Rollback/forward-fix rehearsed with the same systemd/nginx shape.
- `/metrics` protected by an app-level token and an allowlist/private network.
- Secrets managed outside the repository with documented rotation.
- Query-plan evidence on a representative medium/hot-thread dataset.
- Outbox worker retry, reclaim, and dead letters rehearsed on staging.
- Reactor backend and OS preflight verified on the target host.

## Final recommendation

Do not add product features. The HIGH gaps around PG concurrency/idempotency and
outbox reclaim are evidence-closed in tree. The next block of work closes the
remaining operational BLOCKERs: stress at 100/500/1000, attachment restore +
nginx/systemd deploy, and staging SMTP. GPForum stays local-ready; a
self-service private beta and public production still require that evidence.
