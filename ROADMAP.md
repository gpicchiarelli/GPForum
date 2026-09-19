# Roadmap

The roadmap follows [prompt/20.txt](prompt/20.txt) and must remain consistent
with [prompt/43.txt](prompt/43.txt).

## Where things stand

GPForum has reached **Milestone 17 — Forum HTTP MVP**. The latest
[release-readiness review](docs/release/readiness-review.md) places it at:

| Target | Status |
| --- | --- |
| Local, personal use | Ready |
| Private beta | Not yet |
| Public production | Not yet |

## Shipped

- Identity and sessions: registration, login, server-side sessions, password
  and email lifecycle tokens.
- Forum read and write workflows with keyset pagination.
- Outbox events connected to Minion worker handlers, with retries and dead
  letters.
- PostgreSQL-native search indexing and permission-aware querying.
- Moderation, administration, and audit review interfaces.
- Web access, workflow, and event boundaries recorded in [ADRs](docs/adr).

## Next

- Mail delivery, so password-reset and email-change tokens reach users.
- Row locks and idempotency for concurrent moderation actions.
- Database-backed failure-mode tests: writes with the database down or timing
  out, errors after commit, and real worker crashes.
- Staging drills: migrations from empty and restored databases,
  backup/restore with attachments, and rehearsed rollback or forward-fix.
- Stress tests at 100, 500, and 1000 users on representative hardware.
- Cluster-wide realtime fanout (currently process-local).

## Release readiness

A public release requires:

- stable migrations and rollback discipline;
- CI green on every pull request;
- coverage and profiling artifacts for hot paths;
- security policy and private reporting path;
- documented support boundaries;
- ADR coverage for major deviations.

The full gate is [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md).
