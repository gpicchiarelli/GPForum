# ADR 0079: Admin Console and Staff Operations

## Status

Accepted. Converted on 2026-09-19 from `prompt/31.txt` ("GPForum - Admin
Console & Staff Operations Constitution"); this ADR replaces the prompt as
the binding source.

## Context

The admin console is the most privileged surface of GPForum: it can change
roles, suspend accounts, pause subsystems and expose operational data.
Staff work needs mandatory rules for console architecture, staff workflows,
administrative boundaries, emergency controls and operational visibility, so
that privilege stays least, scoped, audited and reversible. The rules govern
the admin and moderation bounded contexts and the operations views they
expose.

## Decision

### Cross-ADR alignment

- ADR 0094 (accessibility): admin and staff operations MUST be accessible.
  Admin dashboards, audit viewers, moderation oversight, emergency controls,
  filters, tables, dialogs and bulk actions MUST be keyboard-operable,
  semantic, screen-reader compatible, focus-safe and WCAG 2.2 AA compliant.
- ADR 0100 (domain integrity): admin and staff workflows MUST be
  audit-backed, permission-scoped, moderation-safe, replay-aware, anti-leak,
  and protected from silent privilege escalation. Staff screens MUST not
  expose restricted content unless the actor is explicitly authorized for
  that scope.

### Admin philosophy

The admin console is a privileged operational surface.

It MUST prioritize: least privilege; auditability; clarity; safe defaults;
reversible operations; separation between moderation and infrastructure
administration.

It MUST avoid: hidden superuser actions; unaudited mutation; broad
destructive controls; exposing secrets; mixing routine community work with
emergency operations.

### Admin areas

- The admin console SHOULD include: dashboard; user management; role and
  permission management; moderation oversight; audit log viewer; worker
  queue status; search index status; cache and projection status;
  configuration view; emergency controls.
- Each area MUST require explicit permission.

### User management

- Staff MAY need to: view account status; view security event summary;
  suspend account; ban account; revoke sessions; reset trust state; inspect
  public content history.
- Staff MUST NOT see password hashes, raw secrets or private tokens.

### Role management

- Role changes MUST be: scoped; audited; attributable; reversible where safe.
- The UI MUST make scope visible before granting authority.

### Audit viewer

- Audit views MUST support: filtering by actor; filtering by target;
  filtering by action; filtering by time; correlation id lookup.
- Audit records MUST not be editable through normal admin UI.

### Operational dashboard

- The dashboard SHOULD display: application health; worker backlog; failed
  jobs; search indexing lag; recent deploy version; error rates; moderation
  queue size; abuse pressure indicators.
- Dashboard data MUST be safe for the viewer's permission level.

### Emergency controls

- Emergency controls MAY include: temporary registration closure; temporary
  posting slowdown; attachment quarantine mode; digest pause; webhook pause;
  search indexing pause.
- Emergency controls MUST be: temporary; audited; visible to
  administrators; documented by runbook (ADR 0075); reversible.

### Admin authentication

- Admin access SHOULD require: an active session; strong authentication; MFA
  where supported; recent re-authentication for dangerous actions.
- Admin routes MUST never rely on obscurity.

## Consequences

- Every admin area is permission-gated and audited, so adding a console
  feature means adding a permission (ADR 0070), an audit event and a
  runbook where it is an emergency control.
- Separating moderation from infrastructure administration keeps routine
  community staff away from operational switches.
- Audit records are append-only from the console's point of view; any
  correction must happen through audited workflows, not UI edits.

## Alignment

- ADRs: 0094 and 0100 (cross-alignment), 0057 (authorization and
  governance), 0070 (permission matrix), 0072 (admin routes), 0075
  (runbooks), 0077 (runtime toggles); 0011 (admin workflow boundary), 0020
  (audit record hashing), 0038 (admin event), 0046 (admin access).
- Code: `lib/GPForum/Controller/Admin.pm`, `lib/GPForum/Controller/Admin/`,
  `lib/GPForum/Service/Admin/`, `lib/GPForum/Web/AdminAccess.pm`,
  `bin/gpforum-admin-bootstrap`, `templates/admin/`.
- Migrations: `migrations/009_admin_authorization.sql`.
- Tests: `t/26-admin-authorization.t`, `t/44-admin-web.t`,
  `t/45-admin-bootstrap.t`, `t/96-admin-controllers.t`,
  `t/97-admin-workflow.t`, `t/131-admin-event.t`,
  `t/137-web-admin-access.t`.
- Docs: `docs/architecture/admin-workflow.md`.
