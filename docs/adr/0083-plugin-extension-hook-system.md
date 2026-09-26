# ADR 0083: Plugin, Extension and Hook System

## Status

Accepted. Converted on 2026-09-19 from `prompt/35.txt` ("GPForum - Plugin,
Extension & Hook System Constitution"); this ADR replaces the prompt as the
binding source.

## Context

Extension points let operators add UI fragments, notification channels,
classifiers, adapters and integrations without forking core, but plugins run
with core privileges and can silently bypass sanitization, authorization or
invariants. GPForum needs an optional plugin architecture with explicit
extension boundaries, hook model, safety constraints, compatibility rules
and governance. The rules are mandatory if plugins are implemented and
govern the plugin subsystem and every core bounded context that exposes an
extension point.

## Decision

### Plugin philosophy

Plugins are optional extension points, not architectural escape hatches.

Plugins MUST: respect security policy; respect authorization; remain
observable; declare capabilities; avoid hidden global mutation.

Plugins MUST NOT: bypass sanitization; bypass authorization; execute
arbitrary unsafe templates; become required for core correctness unless
promoted to core.

### Extension points

- Possible extension points MAY include: rendered UI fragments;
  notification channels; moderation classifiers; import/export adapters;
  webhook integrations; analytics sinks; custom profile fields; admin
  dashboard panels.
- Every extension point MUST define: input contract; output contract;
  permission context; failure behavior.

### Hook model

- Hooks SHOULD be explicit and named.
- Hook execution MUST define: order; timeout; error handling; logging;
  side-effect permissions.
- Hooks MUST NOT receive secrets unless explicitly required and authorized.

### Plugin metadata

- Plugins SHOULD declare: name; version; author; compatible GPForum version;
  required capabilities; required permissions; migrations if any.
- Plugin compatibility MUST be checkable before activation.

### Security

- Plugin code MUST be treated as privileged code unless sandboxed.
- The platform MUST make this trust boundary explicit.
- Plugin-provided templates or HTML MUST pass the same safety rules as core
  output.
- Plugin migrations MUST be reviewed and reversible where feasible.

### Lifecycle

- Plugin lifecycle SHOULD support: install; configure; enable; disable;
  upgrade; uninstall.
- Disabling a plugin MUST not corrupt core data.

### Operational visibility

- Plugin failures SHOULD be visible in: logs; metrics; admin console; health
  checks where critical.
- Plugins MUST not hide operational errors.

### Verifiable plugin contract amendment

- Plugins MUST comply with ADR 0093.
- Every plugin extension point MUST define: capability scope; input
  contract; output contract; authorization context; audit/event
  expectations; timeout and failure behavior; migration and rollback stance
  where data is stored.
- Plugin behavior MUST be contract-tested.
- Plugins MUST NOT create hidden authoritative state or bypass invariants
  owned by core bounded contexts.

### Accessibility plugin amendment

- Plugins MUST comply with ADR 0094.
- Plugin-rendered UI MUST preserve semantic HTML, keyboard operation, focus
  visibility, accessible names/states, screen-reader compatibility,
  reduced-motion behavior and theme contrast requirements.
- Plugins that inject inaccessible widgets or JavaScript-only core workflows
  MUST be rejected, quarantined or disabled.

### Core discipline plugin amendment

- Plugins MUST comply with ADR 0096.
- Plugins MUST declare capabilities, use stable APIs, avoid arbitrary
  runtime patching, avoid direct access to unrelated core database state,
  and remain optional for core correctness unless promoted through ADR.

## Consequences

- Core stays correct with every plugin disabled; plugins can only add
  behavior through declared, contract-tested extension points.
- Plugins are treated as privileged code, so installing one is a trust
  decision reviewed like a dependency, including its migrations.
- Hook timeouts, ordering and failure recording add dispatch overhead but
  keep a failing plugin from hiding errors or blocking core workflows.

## Alignment

- ADRs: 0093, 0094 and 0096 (amendments), 0053 (security), 0079 (admin
  console visibility), 0081 (import/export adapters), 0085 (webhook
  contracts).
- Code: `lib/GPForum/Service/Plugin/` (`FailureRecorder`, `HookDispatcher`,
  `ManifestValidator`, `Registry`).
- Migrations: `migrations/011_plugins.sql`.
- Tests: `t/28-plugins.t`.
