# ADR 0086: Packaging, Deployment and Runtime Processes

## Status

Accepted. Converted on 2026-09-19 from `prompt/38.txt` ("GPForum -
Packaging, Deployment & Runtime Process Constitution"); this ADR replaces
the prompt as the binding source.

## Context

GPForum runs as several kinds of Perl processes (web, workers, scheduled
jobs, realtime, maintenance) behind a reverse proxy, on Linux, FreeBSD and
macOS. Deployments must be reproducible, observable and reversible, and
nobody should have to guess how the process layout works. This ADR sets the
mandatory packaging model, runtime process layout, deployment target
expectations, process supervision, web server integration and production
runtime discipline. It is mandatory for deployment design.

## Decision

### Cross-ADR alignment

- ADR 0093 (verifiable invariants): deployments are engineering events.
  Deployment packages MUST preserve reproducibility, release-gate evidence,
  migration state, readiness checks, rollback stance and dependency lockfile
  integrity. Runtime process changes MUST not introduce hidden dependencies
  or unverifiable operational behavior.
- ADR 0097 (OS-level performance): deployment profiles MUST preserve
  OS-level performance discipline. Production deployments SHOULD use
  persistent Mojolicious prefork processes, reverse-proxy static delivery,
  worker-local database connections, explicit resource limits, conservative
  OS feature flags, and documented macOS/FreeBSD/Linux fallbacks.

### Deployment philosophy

Deployment must be boring, reproducible and observable.

GPForum MUST support: deterministic dependency installation; explicit
runtime process definitions; safe rolling deploys; worker separation; web
server integration; rollback.

The platform MUST avoid: manual production patching; hidden runtime state;
unpinned critical dependencies; process layouts nobody can explain.

### Packaging

- The project SHOULD define: a Perl dependency manifest; a lockfile or
  reproducible dependency strategy; an application start command; a worker
  start command; a migration command; a test command; a coverage command; a
  profiling command.
- Mandatory Perl packaging strategy: Carton; `cpanfile`;
  `cpanfile.snapshot`; `cpanfile.postgres` for PostgreSQL-specific Perl
  dependencies.
- Additional packaging MAY use: system packages; a container image;
  deployment-specific packaging.
- Carton MUST be used for Perl dependency reproducibility.
- Dependency automation MUST provide: install; system preflight; update with
  review; audit where tooling allows; test; coverage; profiling.

### Runtime processes

- Production runtime SHOULD separate: web application processes; worker
  processes; scheduled job processes; websocket-capable processes if
  separated; maintenance commands.
- Each process type MUST have: a start command; health behavior; logging
  behavior; a restart policy; resource expectations; a configured process
  count; scaling bounds.
- Perl runtime deployment MUST support: multiple web processes per node;
  multiple worker processes per node; separate realtime process pools where
  needed; process-level graceful restart; dynamic resizing by configuration
  or supervisor; explicit per-process memory and connection budgets.
- Perl threads MAY be enabled only for bounded internal workloads with
  documented safety rules (ADR 0088).

### Web server

- Nginx or HAProxy SHOULD provide: TLS termination where applicable; request
  buffering; compression; static asset serving; websocket upgrade proxying;
  request size limits; timeout policy.
- Application nodes MUST not depend on local filesystem persistence.

### Systemd or container runtime

- Deployment MAY use systemd, containers or another supervised runtime.
- The runtime MUST provide: restart policy; environment injection; log
  routing; health integration; resource limits where feasible.

### Migrations during deploy

- Deployment MUST define when migrations run.
- Migrations SHOULD be compatible with rolling application deploys where
  feasible.
- Destructive migrations MUST require explicit runbook approval (ADR 0075).

### Assets

- Static assets SHOULD be: versioned; cacheable; reproducible; served
  through edge or web server where appropriate.
- Asset deployment MUST avoid stale references during rolling deploys.

### Production readiness

A production package MUST include: a version identifier; dependency
metadata; migration state; health endpoints; logs and metrics; a rollback
path.

## Consequences

- Carton plus committed snapshots make dependency sets reproducible across
  developer machines, CI and production.
- Every process type has an explicit command, supervisor unit, health
  behavior and budget, so scaling is a configuration change rather than a
  code change (ADR 0088).
- Rolling deploys constrain migrations to be backward compatible or to go
  through a runbook-approved destructive path.
- Open conflicts: attachments are stored on the local filesystem
  (`var/attachments`, via `GPForum::Service::Attachment::FilesystemStorage`
  wired in `lib/GPForum/Bootstrap/Forum.pm`), which contradicts "application
  nodes MUST not depend on local filesystem persistence" for multi-node
  deployments.

## Alignment

- ADRs: 0093 and 0097 (cross-alignment), 0050 (infrastructure), 0075
  (deployment and migration runbooks), 0077 (configuration), 0088
  (multi-process runtime), 0089 (Carton and automation); 0012 (operational
  profiles), 0027 (attachment lifecycle).
- Packaging: `cpanfile`, `cpanfile.snapshot`, `cpanfile.postgres`,
  `script/gpforum-carton`, `script/bootstrap-deps`, `script/system-preflight`,
  `Makefile`.
- Runtime: `bin/gpforum`, `bin/gpforum-migrate`,
  `bin/gpforum-outbox-dispatch`, `deploy/systemd/`, `deploy/nginx/`,
  `deploy/freebsd/`, `deploy/launchd/`, `deploy/caddy/`.
- Tests: `t/33-health-readiness.t`, `t/98-operational-profiles.t`,
  `t/144-cpan-install.t`.
- Docs: `docs/DEPLOYMENT.md`, `docs/DEPLOYMENT_EVIDENCE.md`,
  `docs/PRODUCTION_READINESS.md`.
