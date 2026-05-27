# GPForum SSR UI System

GPForum uses a server-rendered UI system built from Mojolicious partials and a
single tokenized stylesheet. The goal is durable product UI: dense discussion
pages, clear admin/moderation workflows, predictable keyboard navigation, and
localizable presentation text.

## Principles

- SSR-first. Components render from `templates/components/*.html.ep`.
- Semantic HTML first. ARIA is used only to name regions, status messages, and
  dialog semantics that native HTML does not provide by itself.
- No frontend build step. CSS custom properties are the design-token layer.
- Localized presentation. Component callers pass translated labels with `t()`,
  `tc()`, `ui_label()`, and locale-aware helpers.
- Presenter helpers. Repeated view-model shapes such as page actions,
  pagination links, and status badges are normalized through
  `GPForum::View::Presenter` via `ui_actions()`, `ui_next_page()`, and
  `ui_badge()`.
- Bootstrap isolation. UI, locale, translation, breadcrumb, flash, and
  presenter helpers are registered by `GPForum::Bootstrap::UI`, keeping the
  main application composition root focused on wiring boundaries.
- Canonical data stays canonical. Audit, moderation, and job state values remain
  stored as stable internal names and are translated only at render time.

## Components

| Component | Purpose |
| --- | --- |
| `components/page_header` | Page heading, optional description, page actions. |
| `components/section_header` | Section heading and optional description. |
| `components/pagination` | Screen-reader-labelled pagination links. |
| `components/empty_state` | Empty/no-results surfaces. |
| `components/alert` | Notice, warning, and error status surfaces. |
| `components/badge` | Status/moderation/admin indicators. |
| `components/status_badge` | Localized status badge backed by presenter helpers. |
| `components/loading` | Hidden progressive-enhancement loading state. |
| `components/dialog` | SSR-safe accessible dialog shell for future enhancement. |

## Tokens

`assets/css/gpforum-ssr.css` defines:

- spacing scale: `--space-1` through `--space-7`;
- typography scale: `--font-size-*`, line-height, readable measure;
- semantic colors: foreground/background/surface/primary/secondary/accent,
  danger/success/warning/focus;
- dark-mode readiness through `html[data-theme="dark"]`;
- direction and typography hooks through `data-direction`, `data-script`, and
  `typography-*` body classes.

Theme extensions must add semantic tokens first, then component rules. Avoid
route-specific styling unless a component cannot express the UI.

## Accessibility Contracts

- Every rendered page has exactly one document `<main>` from the base layout.
- Page templates use `section` or `article` inside the layout main landmark.
- Pagination is rendered through `components/pagination` or follows the same
  labelled `<nav>` contract.
- Statuses use text plus badge styling; color alone is not the only signal.
- Form errors use alert summaries and field-level `aria-describedby`.
- Focus states remain visible via `:focus-visible`.
- Motion-sensitive behavior must respect `prefers-reduced-motion`.

## Verification

- `t/65-accessible-theme.t` enforces contrast, focus, direction, and token
  contracts.
- `t/67-ui-system.t` verifies component partials, no inline CSS proliferation,
  single-main HTML structure, localized admin rendering, and component presence
  on product routes.
- `t/68-view-presenter.t` verifies SSR presenter normalization and Mojolicious
  helper integration.
- `t/64-i18n.t` verifies catalog coverage, namespace discipline, fallback,
  pluralization, and locale metadata.
