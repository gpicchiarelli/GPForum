# ADR 0081: Import, Export and Legacy Migration

## Status

Accepted. Converted on 2026-09-19 from `prompt/33.txt` ("GPForum - Import,
Export & Legacy Migration Constitution"); this ADR replaces the prompt as
the binding source.

## Context

Communities migrating from legacy forums bring hostile HTML, colliding
identifiers, broken ownership and role data that could escalate privileges.
Users and staff also need portable exports. GPForum needs mandatory rules for
import/export architecture, legacy migration strategy, data mapping,
validation and user data portability. The rules apply when import/export
features are implemented and govern the portability, identity, forum,
attachment, moderation and privacy bounded contexts.

## Decision

### Migration philosophy

Import and export are high-risk data operations.

They MUST prioritize: data integrity; traceability; repeatability;
reversibility where feasible; privacy; user identity safety.

They MUST avoid: silent data loss; unvalidated legacy HTML; privilege
escalation through imported roles; broken content ownership; unbounded
imports in request workflows.

### Import sources

- Import tooling MAY support: CSV; JSON; SQL dumps transformed offline;
  common forum exports; custom migration adapters.
- Every adapter MUST define its trust boundary.

### Import mapping

- Imports MUST map: users; spaces/categories; threads; posts; timestamps;
  attachments; moderation state where available; redirects or legacy
  identifiers.
- Imported identifiers MUST not collide with native identifiers.

### Validation

- Import validation MUST check: required fields; ownership references;
  timestamp sanity; attachment availability; content sanitization; duplicate
  detection; permission mapping.
- Invalid records MUST be reportable.

### Execution model

- Imports MUST run asynchronously.
- Large imports MUST support: dry run; progress tracking; resumability;
  failure reporting; audit logs; rollback or quarantine strategy.

### Legacy URLs

- Legacy migration SHOULD support: old thread id mapping; old post id
  mapping; redirect generation; canonical URL preservation where possible.
- Redirects MUST respect visibility and deletion state.

### Export

- Export SHOULD support: user data export; administrative content export;
  moderation/audit export for authorized staff; machine-readable formats.
- Exports MUST respect privacy and authorization boundaries.

### Security

- Imported content MUST be treated as hostile input.
- Imported HTML MUST be sanitized or converted.
- Imported attachments MUST pass validation and scanning workflows.

## Consequences

- Imports run as resumable background jobs with dry runs and audit logs, so
  large migrations can be rehearsed and restarted without request timeouts.
- Legacy identifiers live in a separate mapping, keeping native identifiers
  stable and enabling redirects that honor visibility and deletion.
- Imported roles and HTML go through the same authorization mapping and
  sanitization as native input, which costs adapter work but closes
  privilege-escalation and XSS paths.

## Alignment

- ADRs: 0074 (data export rights), 0082 (canonical URLs and redirects), 0083
  (import/export adapter plugins); 0027 (attachment lifecycle).
- Code: `lib/GPForum/Service/Portability/`.
- Migrations: `migrations/010_import_export.sql`.
- Tests: `t/27-import-export.t`.
