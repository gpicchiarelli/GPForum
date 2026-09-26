# ADR 0080: Content Policy, Community Guidelines and Enforcement

## Status

Accepted. Converted on 2026-09-19 from `prompt/32.txt` ("GPForum - Content
Policy, Community Guidelines & Enforcement Constitution"); this ADR replaces
the prompt as the binding source.

## Context

Technical moderation tools are only fair when they enforce explicit,
versioned community policy. GPForum needs a mandatory model for community
policy, content rule structure, enforcement levels, appeals, policy
versioning and social governance. The rules are mandatory for moderation
product design and govern the moderation, identity (suspensions and bans),
forum content and policy documentation bounded contexts.

## Decision

### Cross-ADR alignment

- ADR 0100 (domain integrity): content policy enforcement MUST be
  server-authoritative, event-backed, audit-backed, visibility-versioned
  where relevant, reversible where feasible, projection-safe,
  cache-invalidating, and conservative against leaks in search, feeds,
  metadata, previews, notifications and plugins.

### Policy philosophy

Technical moderation must reflect explicit community policy.

GPForum MUST support: clear rules; consistent enforcement; proportional
response; appeal paths where appropriate; policy versioning; transparent
user-facing explanations.

The platform MUST avoid: arbitrary enforcement; hidden rule changes;
harassment-enabling ambiguity; engagement incentives that reward abuse.

### Policy documents

- The platform SHOULD support versioned: terms of service; privacy policy;
  community guidelines; moderation policy; acceptable use policy.
- Policy versions SHOULD record: title; version; `effective_at`; body;
  change summary.

### Violation categories

- Initial policy categories SHOULD include: spam; harassment; threats; hate
  or abusive conduct; illegal content; malware or malicious links; privacy
  violation; impersonation; off-topic disruption; evasion of moderation.
- Categories MUST be configurable without code changes where feasible.

### Enforcement levels

- Enforcement SHOULD support: no action; note; warning; content hide;
  content quarantine; temporary suspension; permanent ban; legal escalation;
  emergency lockdown.
- Enforcement MUST be scoped and audited.

### Appeals

- The platform SHOULD support appeals for: warnings; suspensions; bans;
  content removal where policy allows.
- Appeals MUST be: attributable; status-tracked; reviewable by authorized
  staff; protected from public disclosure.

### User explanations

User-facing enforcement messages MUST: identify the action; provide a safe
reason category; explain the next available step where appropriate; avoid
exposing reporter identity; avoid exposing internal detection details.

### Policy and automation

- Automated moderation MAY assist humans.
- Automated systems MUST remain: explainable; overrideable; auditable;
  bounded.
- Automation MUST NOT become unreviewable authority.

## Consequences

- Moderation actions are tied to a policy category and an enforcement
  level, which makes enforcement comparable and auditable across staff.
- Policy text and categories change through versioned records rather than
  code, so policy updates do not require releases where feasible.
- Automated classifiers stay advisory and overrideable, so humans remain
  accountable for enforcement decisions.

## Alignment

- ADRs: 0100 (cross-alignment), 0057 (authorization, moderation and
  governance), 0065 (community operations), 0074 (policy acceptance and
  privacy), 0083 (moderation classifier plugins); 0010 (moderation workflow
  boundary), 0035 (moderation action event), 0036 (moderation report event),
  0037 (moderation suspension event), 0044 (moderation access).
- Code: `lib/GPForum/Service/Moderation/`,
  `lib/GPForum/Controller/Moderation.pm`,
  `lib/GPForum/Controller/Moderation/`, `templates/moderation/`.
- Migrations: `migrations/008_moderation_review.sql`.
- Tests: `t/25-moderation-review.t`, `t/43-moderation-web.t`,
  `t/94-moderation-controllers.t`, `t/95-moderation-workflow.t`,
  `t/130-moderation-event.t`.
- Docs: `docs/architecture/moderation-workflow.md`.
