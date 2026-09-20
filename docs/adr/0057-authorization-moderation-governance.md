# ADR 0057: Authorization, Moderation and Governance

## Status

Accepted. Converted on 2026-09-19 from `prompt/9.txt` ("GPForum —
Authorization, Moderation & Governance Constitution"); this ADR replaces the
prompt as the binding source.

## Context

A public forum faces hostile actors, spam, social engineering, privilege
escalation, moderation misuse and insider abuse. Authority that is implicit,
duplicated or invisible cannot be audited, revoked or reviewed.

This ADR fixes the authorization architecture, permission model, moderation
system, trust framework, governance rules, administrative boundaries,
escalation policies and operational control philosophy. It governs the
identity, admin, moderation, forum, search and attachment contexts wherever
they decide who may act, plus reports, suspensions, trust levels, rate-limit
governance, emergency controls and governance audit. The rules are
foundational and mandatory; all future authorization and moderation systems
MUST comply with them.

## Decision

### Accessibility Alignment

Per ADR 0094:

- Authorization, moderation and governance workflows MUST remain accessible
  to keyboard and assistive-technology users.
- Moderation queues, audit views, dialogs, filters, confirmations and
  emergency controls MUST be semantic, focus-safe, screen-reader compatible
  and non-color-only.
- Inaccessible staff tooling is an operational safety failure.

### Execution Invariant Alignment

Per ADR 0100, authorization, moderation and governance workflows are
execution invariants:

- Each workflow MUST answer who can read, write, moderate, delete, restore,
  move, search, subscribe and export.
- Visibility, moderation state, event emission, audit records, projection
  effects, cache invalidation, anti-leak behavior and replay preservation
  MUST be explicit.

### Governance Philosophy

- GPForum MUST assume hostile actors, abuse attempts, coordinated spam,
  social engineering, privilege escalation attempts, moderation misuse and
  insider abuse.
- Governance MUST prioritize explicit authority, least privilege,
  traceability, revocability, auditability and bounded authority domains.
- The platform MUST avoid implicit privilege, hidden authority, untraceable
  moderation and global unrestricted access.

### Authorization Philosophy

- Authorization MUST remain centralized, explicit, deny-by-default and
  auditable.
- Every sensitive action MUST verify authorization, scope and context.
- Authorization MUST NOT depend on frontend visibility, template logic or
  client-side enforcement. The server is authoritative.

### Mandatory Authorization Model

- The platform MUST implement a hybrid RBAC + ABAC authorization model.
- RBAC provides roles, coarse permissions and operational grouping.
- ABAC provides contextual evaluation, ownership logic, dynamic constraints
  and resource-specific policy.

### Permission Model

- Permissions MUST support global scope, category scope, thread scope,
  resource ownership, temporary grants and contextual restrictions.
- Examples: edit own post, moderate category, suspend user, manage tags,
  delete attachments, review reports.
- Permissions MUST remain granular, composable and revocable.

### Forbidden Authorization Patterns

- The platform MUST avoid hardcoded admin booleans, hidden superuser
  bypasses, authorization inside templates and duplicated permission logic.
- Forbidden examples: `is_admin`, magic moderator checks, frontend-only
  restrictions.

### Authorization Evaluation

- Authorization MUST evaluate actor identity, role bindings, resource
  ownership, contextual restrictions, trust status and moderation state.
- Authorization MUST remain deterministic, testable and centralized.

### Permission Storage

- Recommended entities: `roles`, `permissions`, `role_bindings`,
  `resource_policies`, `moderation_actions`.
- The system MUST support auditability, revocation and historical analysis.

### Resource Ownership

- Ownership MUST remain explicit (examples: post, attachment, thread and
  moderation ownership).
- Ownership alone MUST NOT automatically grant unrestricted authority.

### Moderation Philosophy

- Moderation is operational governance, abuse mitigation and community
  stability management.
- Moderation MUST remain auditable, attributable, reversible where possible
  and scope-bound.
- Moderators MUST NOT operate invisibly.

### Moderation Scopes

- The platform MUST support global moderators, category moderators, scoped
  moderation teams and temporary moderation authority.
- Moderation authority MUST remain explicitly assigned and explicitly
  revocable.

### Moderation Actions

- Examples: hide content, soft delete, suspend account, mute account, lock
  thread, freeze edits, quarantine uploads, revoke permissions.
- All moderation actions MUST generate audit events, actor attribution,
  timestamps and contextual metadata.

### Soft Deletion Philosophy

- Destructive deletion SHOULD be minimized.
- Preferred strategy: soft deletion, reversible moderation, immutable audit
  history.
- Permanent destructive deletion SHOULD remain exceptional, restricted and
  auditable.

### Suspension Philosophy

- The platform MUST support temporary suspension, permanent suspension,
  scoped restriction and progressive penalties.
- Suspension systems SHOULD support expiration, escalation and
  reviewability.

### Trust System

- The platform SHOULD support trust levels, behavioral scoring and
  progressive capability unlocks.
- Trust systems MAY influence rate limits, moderation thresholds, posting
  permissions and anti-spam heuristics.
- Trust systems MUST remain explainable, bounded and reviewable.

### Abuse Mitigation

- Governance MUST support spam mitigation, flood control, bot detection,
  abuse throttling and coordinated attack response.
- Abuse mitigation MUST remain observable, tunable and auditable.

### Reporting System

- Users SHOULD be able to use content reporting, abuse reporting and
  escalation workflows.
- Reports MUST remain attributable, support moderation workflows and support
  audit trails.

### Administrative Philosophy

- Administrative access MUST remain minimal, attributable, auditable and
  revocable.
- Administrative authority MUST require explicit authentication, explicit
  authorization and elevated verification where appropriate.

### Separation of Duties

- The architecture SHOULD support separation of operational authority,
  limited moderation scope and bounded infrastructure access.
- The platform SHOULD avoid universal unrestricted operators.

### Security-Sensitive Actions

- The following MUST generate audit events: permission changes, role
  assignment, moderation escalation, administrative login, suspension
  actions, security policy changes.
- Auditability is mandatory.

### Appeal & Review Philosophy

- Governance SHOULD support moderation review, escalation review,
  administrative oversight and reversible actions where appropriate.
- The system SHOULD minimize irreversible silent actions.

### Rate-Limit Governance

- Governance SHOULD support dynamic restrictions, behavioral throttling,
  abuse scoring and emergency lockdown policies.
- Rate limiting MAY vary by trust level, moderation history and behavioral
  reputation.

### Content Governance

- Content workflows SHOULD support quarantine, staged visibility,
  moderation review and revision tracking.
- Content governance MUST remain traceable, reviewable and auditable.

### Anti-Abuse Automation

- The architecture MAY support automated moderation, spam scoring,
  heuristic filtering and AI-assisted analysis.
- Automated systems MUST remain reviewable, overrideable and auditable.
- Automated systems MUST NOT become opaque authority systems.

### Federation Governance

If federation is implemented in the future:

- remote trust boundaries MUST remain explicit;
- remote moderation MUST remain constrained;
- remote authority MUST remain revocable;
- federation MUST NOT bypass local governance rules.

### Emergency Controls

- The platform SHOULD support emergency lockdown, emergency moderation
  escalation, temporary feature restriction and abuse containment
  workflows.
- Emergency actions MUST remain auditable.

### Governance Logging

- Governance operations MUST expose moderation metrics, abuse metrics,
  escalation metrics, suspension history and administrative action trails.
- Operational visibility is mandatory.

### Long-Term Governance Goal

- Governance architecture MUST remain auditable, transparent,
  abuse-resistant, scalable under large communities, operationally
  sustainable and resistant to privilege abuse.
- Authority MUST always remain explicit, attributable and reviewable.

## Consequences

- One deny-by-default decision point makes authorization testable and keeps
  templates, components and clients free of permission logic.
- Every privileged or moderation action carries audit, attribution and
  revocation costs; schema and workflows must record who, when, scope and
  context, and reviews must be able to reconstruct history.
- Administrators get no shortcut flag; their authority comes from explicit,
  audited, revocable bindings like any other role.
- Staff tooling is held to the same accessibility bar as public pages.
- Repository note: the recommended `resource_policies` entity does not exist;
  resource-level policy is stored in `resource_acl`
  (`migrations/001_core_identity.sql`), with grants, revocations and
  effective permissions in `migrations/004_platform_governance.sql`.

## Alignment

- ADR 0010, ADR 0011, ADR 0020, ADR 0035, ADR 0036, ADR 0037, ADR 0038,
  ADR 0041, ADR 0044, ADR 0046
- ADR 0053 (security), ADR 0054 (frontend), ADR 0058 (observability),
  ADR 0065 (community operations), ADR 0070 (permission matrix), ADR 0079
  (admin console), ADR 0080 (content policy), ADR 0094 (accessibility),
  ADR 0100 (domain integrity and moderation execution)
- `migrations/001_core_identity.sql` (`roles`, `permissions`,
  `role_permissions`, `role_bindings`, `resource_acl`),
  `migrations/004_platform_governance.sql`,
  `migrations/007_advanced_community.sql` (`reputation_events`,
  `trust_score_snapshots`), `migrations/008_moderation_review.sql`
  (`reports`, `moderation_actions`, `suspensions`),
  `migrations/009_admin_authorization.sql`,
  `migrations/016_security_abuse_hardening.sql`
- `lib/GPForum/Service/Admin/`, `lib/GPForum/Service/Moderation/`,
  `lib/GPForum/Service/Search/PermissionEngine.pm`,
  `lib/GPForum/Service/Operations/RateLimiter.pm`,
  `lib/GPForum/Service/Community/ReputationLedger.pm`,
  `lib/GPForum/Infrastructure/AuditRecord.pm`,
  `lib/GPForum/Web/ModerationAccess.pm`, `lib/GPForum/Web/AdminAccess.pm`
- `docs/architecture/moderation-workflow.md`,
  `docs/architecture/admin-workflow.md`
- `t/25-moderation-review.t`, `t/26-admin-authorization.t`,
  `t/43-moderation-web.t`, `t/44-admin-web.t`, `t/45-admin-bootstrap.t`,
  `t/55-security-abuse-hardening.t`, `t/95-moderation-workflow.t`,
  `t/97-admin-workflow.t`, `t/130-moderation-event.t`,
  `t/131-admin-event.t`, `t/135-web-moderation-access.t`,
  `t/137-web-admin-access.t`
