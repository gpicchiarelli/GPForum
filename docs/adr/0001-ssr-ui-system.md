# ADR 0001: SSR UI System Foundation

## Status

Accepted

## Context

GPForum has matured into a modular monolith with strong application services,
privacy, moderation, operations, and notification boundaries. The product UI
needed a matching SSR-first foundation without introducing a SPA, Node.js build
pipeline, or client-rendered architecture.

## Decision

Adopt a Mojolicious partial based UI component layer under
`templates/components/`, backed by the existing `gpforum-ssr.css` token system.
Components cover page headers, section headers, pagination, alerts, badges,
empty states, loading states, and an accessible dialog shell. Product templates
remain server-rendered and pass localized labels through the existing I18N
helpers.

Repeated view-model shapes are normalized by `GPForum::View::Presenter` and
exposed to templates through helpers such as `ui_actions()`, `ui_next_page()`,
and `ui_badge()`. This keeps URL generation and translation at the SSR boundary
while removing repeated action/pagination hash construction from templates.

UI-related helper registration lives in `GPForum::Bootstrap::UI` rather than
directly in `GPForum.pm`. The application root still owns service construction,
while the bootstrap module owns UI helper registration and presentation hooks.

## Consequences

Benefits:

- repeated UI patterns become reusable without changing route behavior;
- accessibility contracts are testable in SSR output;
- future RTL and typography expansion can use layout metadata already emitted by
  the base layout;
- admin/moderation/status surfaces can display canonical states through
  presentation-only labels and badges.
- page actions, pagination entries, and status badges have one normalization
  point before they reach shared components.
- `GPForum.pm` is smaller and has a first internal bootstrap boundary that can
  guide future extraction of identity, forum, moderation, privacy, and
  operations wiring.

Costs:

- templates need incremental migration to use the component vocabulary;
- the component layer is intentionally simple and does not provide client-side
  interaction management yet;
- advanced dialog behavior will need progressive enhancement later.

Rollback strategy:

- partial use can be reverted per-template because route payloads and services
  are unchanged.

## Alignment

- Preserves Mojolicious SSR-first rendering.
- Preserves Perl-first runtime assumptions and avoids frontend build tooling.
- Adds tests in `t/65-accessible-theme.t`, `t/67-ui-system.t`, and
  `t/68-view-presenter.t`.
- Documents the UI/accessibility contracts in `docs/UI_SYSTEM.md`.
