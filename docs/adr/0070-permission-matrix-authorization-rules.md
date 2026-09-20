# ADR 0070: Permission Matrix And Authorization Rules

## Status

Accepted. Converted on 2026-09-19 from `prompt/22.txt` ("GPForum -
Permission Matrix & Authorization Rules Constitution"); this ADR replaces
the prompt as the binding source.

## Context

Authorization is enforced server-side for every forum, moderation, identity,
and administrative workflow (ADR 0057). This ADR fixes the initial
permission matrix, role model, ABAC rules, and authorization evaluation
expectations. It is mandatory for implementation and governs the identity,
forum, moderation, notification, and admin bounded contexts.

## Decision

### Cross-ADR Alignment

- ADR 0100: permission matrix changes MUST answer the mandatory
  authorization questions for read, write, moderate, delete, restore,
  move, search, subscribe, and export. Permission rules MUST remain
  explicit, visibility-aware, moderation-aware, audit-backed, and
  anti-leak.

### Authorization Philosophy

- Authorization MUST be deny-by-default.
- Every sensitive action MUST evaluate: actor; action; target; scope;
  resource state; user state; moderation state.
- Frontend visibility MUST NOT be treated as authorization.

### Base Roles

- Canonical initial roles: `anonymous`, `member`, `trusted_member`,
  `moderator`, `space_moderator`, `administrator`, `owner`.
- Roles MUST be scope-aware where applicable.
- Global administrator power MUST be minimized and audited.

### Core Permissions

Identity permissions:

- `user.register`
- `user.login`
- `user.logout`
- `user.view_profile`
- `user.edit_self`
- `user.manage_security_self`
- `user.suspend`
- `user.ban`

Forum permissions:

- `space.view`, `space.create`, `space.edit`
- `category.view`, `category.create`, `category.edit`
- `thread.view`, `thread.create`, `thread.reply`, `thread.edit_own`,
  `thread.edit_any`, `thread.lock`, `thread.move`, `thread.archive`
- `post.view`, `post.create`, `post.edit_own`, `post.edit_any`,
  `post.hide`, `post.delete_soft`, `post.restore`

Moderation permissions:

- `report.create`
- `report.view_queue`
- `report.assign`
- `report.resolve`
- `moderation.action.create`
- `moderation.action.reverse`
- `quarantine.review`

Operational permissions:

- `admin.view_dashboard`
- `admin.manage_roles`
- `admin.manage_policies`
- `admin.view_audit_log`
- `admin.run_maintenance`

### Anonymous Rules

- Anonymous users MAY: view public spaces; view public categories; view
  public threads; view public posts; register; login.
- Anonymous users MUST NOT: create threads; create posts; report content
  unless explicitly enabled; access restricted spaces; access moderation
  state; access admin interfaces.

### Member Rules

- Members MAY: create threads in allowed categories; reply to open
  threads; edit own posts within policy; subscribe to permitted targets;
  report content; manage own profile and security settings.
- Members MUST NOT: bypass locked thread state; see hidden moderation
  details; edit other users' posts; change category policies; view
  reports.

### Trusted Member Rules

- Trusted members MAY receive: higher rate limits; reduced
  pre-moderation; attachment privileges; additional community features.
- Trusted status MUST NOT grant staff authority by itself.

### Moderator Rules

- Moderators MAY, within scope: view the moderation queue; hide and
  restore content; lock and unlock threads; move threads; review reports;
  quarantine content.
- Moderators MUST NOT: grant themselves authority; modify global security
  policy; access unrelated private data; perform unaudited actions.

### Administrator Rules

- Administrators MAY: manage site configuration; manage roles and
  policies; view operational dashboards; perform maintenance actions;
  inspect audit logs.
- Administrative actions MUST be strongly audited.
- Administrator authority SHOULD be separable from moderation authority.

### Owner Rules

- Owner authority is exceptional.
- Owner actions MUST be rare, audited, protected by strong
  authentication, and operationally visible.
- Owner authority MUST NOT be required for routine moderation.

### ABAC Constraints

- Authorization MUST account for resource state. Examples:
  - locked threads reject normal replies;
  - archived categories reject normal thread creation;
  - suspended users cannot post;
  - banned users cannot authenticate into normal workflows;
  - quarantined content cannot render publicly;
  - deleted content is visible only to authorized staff where policy
    allows.
- Ownership MAY grant edit rights only when policy permits.
- Ownership MUST NOT override moderation restrictions.

### Decision Output

- Authorization checks SHOULD return: allow or deny; reason code; policy
  source; correlation id where applicable.
- User-facing denial messages MUST be safe and non-leaky.
- Operational logs SHOULD include enough context for audit.

## Consequences

- Every sensitive path needs an explicit permission name and a
  resource-state check, which makes new features slower to wire but keeps
  authority reviewable and testable.
- Scoped roles (`space_moderator`, category or space bindings) require
  scope-aware role bindings (ADR 0069) and scope-aware evaluation.
- Structured decision output (reason code, policy source) lets audit and
  observability explain denials without leaking details to users.
- Open conflict: the implemented permission catalog does not use these
  names. `GPForum::Service::Admin::Bootstrapper` seeds `admin_console.view`,
  `admin_console.manage`, `report.view_queue`, `report.assign`,
  `report.resolve`, `post.moderate`, `thread.moderate`,
  `moderation_action.view`, `moderation_action.reverse`, `suspension.view`,
  `user.suspend`, `privacy_rights.view`, and `privacy_rights.manage` under a
  `gpforum_owner` role; the canonical roles above are not seeded.
- Open conflict: `GPForum::Service::Admin::PermissionGate` returns a
  boolean and matches any active role binding for the permission without
  checking binding scope, so moderator "within scope" limits and the
  decision output (reason code, policy source) are not yet implemented.
- Open conflict: `t/09-prompt-alignment.t` slurps `prompt/22.txt` to check
  the ADR 0100 alignment clause; it must be repointed to this ADR before
  the prompt files are deleted.

## Alignment

- ADR 0053 (security), ADR 0057 (authorization, moderation, governance),
  ADR 0065 (community operations), ADR 0069 (schema), ADR 0071 (events),
  ADR 0072 (HTTP routes and controllers), ADR 0079 (admin console),
  ADR 0100 (domain integrity, authorization, moderation execution).
- ADR 0007 (websocket authorization), ADR 0010 (moderation workflow),
  ADR 0011 (admin workflow), ADR 0044 (moderation access), ADR 0046 (admin
  access).
- `lib/GPForum/Service/Admin/PermissionGate.pm`,
  `lib/GPForum/Service/Admin/Bootstrapper.pm`,
  `lib/GPForum/Service/Admin/RoleCatalog.pm`,
  `lib/GPForum/Service/Admin/RoleBindingStore.pm`,
  `lib/GPForum/Service/Realtime/SubscriptionPolicy.pm`
- `migrations/001_core_identity.sql`,
  `migrations/009_admin_authorization.sql`
- `docs/architecture/admin-workflow.md`,
  `docs/architecture/moderation-workflow.md`
- `t/26-admin-authorization.t`, `t/45-admin-bootstrap.t`,
  `t/09-prompt-alignment.t`
