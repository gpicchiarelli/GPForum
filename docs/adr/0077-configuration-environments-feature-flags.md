# ADR 0077: Configuration, Environments and Feature Flags

## Status

Accepted. Converted on 2026-09-19 from `prompt/29.txt` ("GPForum -
Configuration, Environments & Feature Flags Constitution"); this ADR replaces
the prompt as the binding source.

## Context

Configuration decides how GPForum connects to PostgreSQL, storage, email and
workers and how secure it is in each environment. Silent drift, hardcoded
production values or leaked secrets turn configuration into an outage or
security risk. This ADR sets mandatory rules for configuration loading,
environment separation, secret handling, feature flag behavior and runtime
configuration discipline across all bounded contexts.

## Decision

### Configuration philosophy

Configuration is an operational contract.

GPForum MUST support: development; test; staging; production.

The platform MUST avoid: hardcoded production values; secrets in source
control; hidden environment drift; configuration that changes behavior
silently.

### Environment model

- Each environment MUST define: database connection; logging level; session
  secret source; object storage configuration; email configuration;
  PostgreSQL search configuration; worker configuration; public base URL;
  security mode.
- Production MUST fail fast when required configuration is missing.
- Development MAY provide safe local defaults.

### Secret management

- Secrets MUST include: database credentials; session signing keys; password
  reset signing keys; object storage credentials; email provider
  credentials; webhook secrets; API tokens.
- Secrets MUST NOT be: committed; logged; rendered in error pages; stored in
  client-side code.

### Feature flags

- Feature flags MAY control: unfinished features; risky rollouts;
  operational mitigations; beta features; emergency abuse controls.
- Feature flags MUST be: named clearly; documented; observable where
  operationally relevant; removable after permanent rollout.
- Security fixes MUST NOT rely on feature flags remaining enabled.

### Configuration validation

- Configuration validation MUST check: required keys; valid URL formats;
  valid numeric ranges; safe production defaults; mutually incompatible
  options.
- Invalid production configuration MUST stop startup.

### Runtime changes

- Runtime configuration changes SHOULD be: audited; scoped; reversible;
  observable.
- Emergency operational toggles MUST have a runbook (ADR 0075).

### Local development

- Local development SHOULD support: local PostgreSQL; a local test database;
  fake email delivery; disabled external webhooks; safe logging;
  deterministic seeds where useful.
- Local defaults MUST NOT weaken production defaults.

## Consequences

- Startup validation turns missing or unsafe production configuration into
  an immediate failure instead of a runtime incident.
- Feature flags carry a documentation and removal obligation, which limits
  flag sprawl; security fixes must be unconditional code paths.
- Secrets reach the process only through the environment or external secret
  sources, so deployment tooling must inject them (ADR 0086).
- Open conflicts: `GPForum::Config` and the `etc/*.conf` profiles define no
  keys for object storage, email provider, PostgreSQL search configuration
  or security mode, and attachment storage is hard-wired to
  `var/attachments` in `lib/GPForum/Bootstrap/Forum.pm`.

## Alignment

- ADRs: 0075 (runbooks), 0076 (configuration bootstrap), 0079 (emergency
  controls), 0086 (packaging and runtime); 0012 (operational profiles), 0047
  (metrics token access), 0048 (mandatory GlifiStore L2).
- Code: `lib/GPForum/Config.pm`, `lib/GPForum/Runtime.pm`,
  `etc/development.conf`, `etc/staging.conf`, `etc/production-small.conf`,
  `etc/production-medium.conf`.
- Tests: `t/01-config.t`, `t/98-operational-profiles.t`.
- Docs: `docs/architecture/operational-profiles.md`,
  `docs/PRODUCTION_READINESS.md`.
