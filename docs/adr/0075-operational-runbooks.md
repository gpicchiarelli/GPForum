# ADR 0075: Operational Runbooks and Production Procedures

## Status

Accepted. Converted on 2026-09-19 from `prompt/27.txt` ("GPForum -
Operational Runbooks & Production Procedures Constitution"); this ADR
replaces the prompt as the binding source.

## Context

Production operation of GPForum depends on repeatable procedures for
deployment, migration, backup and restore, incident and abuse response,
search rebuild, event replay and secret rotation. Undocumented tribal
operations make recovery slow and unsafe. These rules are mandatory for
operations and cut across every bounded context that has a production
failure mode.

## Decision

### Cross-ADR alignment

- ADR 0093 (verifiable invariants): runbooks are engineering contracts.
  Runbooks MUST cover recovery for invariant violations, replay failures,
  projection rebuilds, outbox backlog, failed migrations, release rollback,
  dependency emergency replacement and degraded-mode operation. Recovery
  procedures MUST be testable or explicitly marked as manual drills.

### Runbook philosophy

- Every critical operational workflow MUST be documented before production
  reliance.
- Runbooks MUST be: executable; current; concise; role-aware; testable;
  linked to observability.
- The platform MUST avoid undocumented tribal operations.

### Mandatory runbooks

GPForum MUST maintain runbooks for: deploy; rollback; database migration;
backup; restore; disaster recovery; search index rebuild; event replay; cache
purge; compromised account response; spam wave response; abusive content
escalation; object storage incident; websocket degradation; worker queue
backlog; secret rotation.

### Backup runbook

- The backup runbook MUST define: PostgreSQL backup method; backup schedule;
  object storage backup policy; configuration backup policy; encryption
  requirements; retention duration; restore testing cadence.
- Backups MUST be monitored.
- Untested backups MUST NOT be considered reliable.

### Restore runbook

- The restore runbook MUST define: restore target selection; PostgreSQL
  restore procedure; object storage reconciliation; search rebuild procedure;
  event replay considerations; validation checks; user-facing communication
  steps.
- Restore MUST be rehearsed periodically.

### Deployment runbook

- The deployment runbook MUST include: preflight checks; migration order;
  application rollout; worker rollout; health checks; smoke tests;
  observability review; rollback trigger criteria.
- Deployments MUST remain observable.

### Migration runbook

- Database migrations MUST define: forward migration; rollback or
  mitigation; expected lock behavior; estimated duration; compatibility with
  old and new app versions; validation queries; backup requirement.
- Risky migrations MUST be rehearsed outside production.

### Incident runbook

- Incident response MUST define: severity levels; incident commander role;
  communication channel; timeline capture; mitigation steps; user impact
  assessment; post-incident review.
- Incidents MUST produce follow-up actions when root causes are found.

### Abuse runbook

- Abuse response MUST cover: spam floods; credential stuffing; coordinated
  reporting abuse; harassment waves; malicious uploads; scraping spikes.
- Abuse controls SHOULD include: rate limit changes; temporary posting
  restrictions; quarantine rules; account suspension batches; WAF/CDN
  coordination where available.
- All emergency controls MUST be reversible and audited.

### Search rebuild runbook

- Search rebuild MUST define: source tables; projection version naming;
  rebuild job execution; projection swap or refresh strategy; validation
  checks; rollback strategy.
- Search rebuild MUST NOT block canonical forum writes.

### Event replay runbook

- Event replay MUST define: replay range; target consumer; idempotency
  protection; side-effect suppression; progress tracking; validation checks.
- Replay MUST NOT resend external notifications unless explicitly approved.

### Secret rotation runbook

- Secret rotation MUST cover: database credentials; session signing secrets;
  object storage credentials; API tokens; webhook secrets; deployment
  credentials.
- Rotation MUST include: compatibility window; revocation step; validation
  step; audit record.

### Operational readiness rule

A feature is not production-ready until its failure mode has: metrics; logs;
alerts where appropriate; rollback or mitigation; runbook coverage.

## Consequences

- Runbook coverage becomes part of the definition of production readiness
  for every feature, adding documentation and rehearsal work before
  production reliance.
- Backups, restores and risky migrations must be rehearsed, so staging or
  scratch environments are required for operations work.
- Emergency controls stay reversible and audited, aligning with the admin
  emergency controls (ADR 0079) and configuration toggles (ADR 0077).
- Open conflicts: the repository does not yet hold the mandatory runbook
  set. Backup/restore and deploy procedures live in
  `docs/PRODUCTION_READINESS.md` and `docs/DEPLOYMENT.md`, but there are no
  documented runbooks for secret rotation, cache purge, compromised account
  response and several other mandatory entries, and
  `docs/release/readiness-review.md` records that the rollback runbook has
  not been proven on the target.

## Alignment

- ADRs: 0093 (cross-alignment), 0074 (incident runbook for breaches), 0077
  (emergency toggles), 0079 (emergency controls), 0086 (deploy-time
  migrations), 0090 (search rebuild); 0009 and 0025 (outbox retry), 0012
  (operational profiles).
- Code: `lib/GPForum/Service/Operations/RunbookValidator.pm`,
  `bin/gpforum-migrate`, `bin/gpforum-outbox-dispatch`.
- Tests: `t/23-operations-hardening.t`.
- Docs: `docs/DEPLOYMENT.md`, `docs/PRODUCTION_READINESS.md`,
  `docs/OBSERVABILITY.md`, `docs/OUTBOX_LIFECYCLE.md`,
  `docs/ops/reactor-backend.md`, `docs/audit/failure-modes.md`,
  `docs/release/readiness-review.md`.
