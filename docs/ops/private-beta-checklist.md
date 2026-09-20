# Private-beta go / no-go checklist (operator)

Operator-facing aggregate of existing prep tools. Use it to walk a candidate
commit toward **private beta evidence**, not to declare readiness.

**This document and `script/gpforum-private-beta-checklist` never claim that
GPForum is private-beta ready.** A printed command list or a green local phase
is not a go decision. Record evidence per step; compare against
[docs/release/readiness-review.md](../release/readiness-review.md).

## Verdict posture (unchanged)

| Target | Status |
| --- | --- |
| Local, personal use | Ready |
| Private beta | **Not yet** — live staging evidence still open |
| Public production | Not yet |

Harnesses and drills below are **shipped**. Residuals are live staging SMTP,
stress on representative hardware, attachment restore + nginx/systemd install
on a real target, and operator runbook evidence.

## Tool map

| Phase | Tool | Docs | What PASS means here |
| --- | --- | --- | --- |
| System Perl | `script/gpforum-system-perl --preflight` | `CONTRIBUTING.md`, `Makefile` | Interpreter is OS/distro (or MacPorts) Perl 5.38+, not a version manager |
| MacPorts PATH | `script/gpforum-macports-env` | `docs/ops/staging-drills.md` | On macOS, `psql` / `pg_dump` / `pg_config` resolve under `/opt/local` (no-op skip on Linux) |
| Migrations | `carton exec bin/gpforum-migrate --apply` via `script/gpforum-carton` | `docs/DEPLOYMENT.md` | Target DB schema at current migration head (`001`–`036` on `main`) |
| Query budget | `script/query-budget --sync` then `--check` | `docs/QUERY_BUDGET_POLICY.md` | Catalog synced; readiness not 503 for empty budgets |
| Staging DB drill | `script/staging-drill` | `docs/ops/staging-drills.md` | Fresh migrate, upgrade path, dump/restore on throwaway DBs |
| Attachments + deploy checklist | `script/staging-drill-attachments` | `docs/ops/staging-drills.md` | Populated throwaway `var/attachments` restore + static (and optional host) nginx/systemd checks — **not** live install/reload |
| Stress / load | `script/stress-load` | `docs/ops/stress-load.md` | Profile evidence against a running Hypnotoad; staging 100/500/1000 still open |
| Mail | `script/gpforum-mail-check` | `docs/ops/mail-check.md` | Transport config + dry-run / optional `--send` on staging |

Print the same map as shell commands (without running drills):

```sh
script/gpforum-private-beta-checklist --commands
script/gpforum-private-beta-checklist --status
make private-beta-checklist
```

## Ordered operator walk

Run on the **staging** (or staging-like) host that will host the beta. Paste
JSON/human evidence into ops notes for the candidate commit. Do not flip the
private-beta verdict from this checklist alone.

### 1. Runtime gate

```sh
script/gpforum-system-perl --preflight
make system-perl
# macOS MacPorts PostgreSQL clients (safe no-op elsewhere):
eval "$(script/gpforum-macports-env)"
script/gpforum-macports-env --check
```

### 2. Schema + query budget

```sh
export GPFORUM_DATABASE_DSN='dbi:Pg:dbname=gpforum;host=…;port=5432'
export GPFORUM_DATABASE_USER='…'
export GPFORUM_DATABASE_PASSWORD='…'
script/gpforum-carton exec bin/gpforum-migrate --apply
script/query-budget --sync
script/query-budget --check
```

### 3. Staging DB drill

```sh
script/staging-drill --json
# or: make staging-drill
```

See [staging-drills.md](staging-drills.md). Throwaway databases only.

### 4. Attachment filesystem + deploy checklist

```sh
script/staging-drill-attachments --json
# or: make staging-drill-attachments
```

Static templates always; `systemd-analyze verify` / `nginx -t` when on `PATH`.
Missing host tools → `degraded` / `skipped`, not a live target install.

### 5. Stress / load (needs running app)

```sh
# Point at a live Hypnotoad (operator-started). Example smoke:
script/stress-load --profile smoke --base-url http://127.0.0.1:8080 --human
# Capacity profiles (staging evidence still required for beta claim):
script/stress-load --profile 100 --base-url https://forum.example --check --json
```

See [stress-load.md](stress-load.md). Elevating
`GPFORUM_FORUM_READ_RATE_LIMIT` is for capacity windows only.

### 6. Mail probe

```sh
script/gpforum-mail-check --human --dry-run
# after SMTP/sendmail is configured on staging:
script/gpforum-mail-check --send --to you@example.test --human
```

See [mail-check.md](mail-check.md).

## Go / no-go for private beta (operator)

Mark **GO** only when **all** of the following are true for the candidate
commit on the **staging** target (not only laptop smoke):

| Gate | GO when | Still open if |
| --- | --- | --- |
| CI | Green on the candidate commit | Red or skipped |
| System Perl / MacPorts | Preflight (and MacPorts `--check` on Darwin) recorded | Version-manager Perl, missing `pg_dump` on Mac |
| Migrate + query budget | `--apply`, `--sync`, `--check` on staging DB | Fresh install never applied; readiness 503 |
| Staging DB drill | `script/staging-drill --json` `status=pass` | Fail or only local throwaway without notes |
| Attachments + deploy | Attachments phase pass; deploy static pass; host verify noted | No attachment evidence; live systemd/nginx install never attempted |
| Live deploy | Hypnotoad + TLS + env file on staging host healthy | Only rendered-sample `nginx -t` |
| Stress | At least profile `100` `--check` on staging hardware archived | Only VM laptop smoke / dry-run |
| Mail | Staging `--dry-run` and a controlled `--send` archived | Adapter unconfigured; no SMTP evidence |
| Product ops | Moderation + dead-letter drill with seeded roles | Never exercised with humans |

Until then the verdict remains **PRIVATE BETA: NO-GO**. Prefer
[readiness-review.md](../release/readiness-review.md) blockers over informal
optimism.

## Related

- [staging-drills.md](staging-drills.md)
- [stress-load.md](stress-load.md)
- [mail-check.md](mail-check.md)
- [../release/readiness-review.md](../release/readiness-review.md)
- [../PRODUCTION_READINESS.md](../PRODUCTION_READINESS.md)
- [../../ROADMAP.md](../../ROADMAP.md)
