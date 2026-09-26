# ADR 0054: Frontend, Rendering and Theme System

## Status

Accepted. Converted on 2026-09-19 from `prompt/6.txt` ("GPForum — Frontend,
Rendering & Theme System Constitution"); this ADR replaces the prompt as the
binding source.

## Context

GPForum needs a frontend that stays simple, secure, accessible and cacheable
for decades on top of a server-authoritative, distributed Perl platform. This
ADR fixes the frontend architecture, rendering philosophy, theme system,
component model, asset strategy, UI composition rules, realtime rendering
behavior, browser assumptions and maintainability standards.

It governs the presentation layer: SSR templates, layouts, components,
ViewModel consumption, themes and design tokens, CSS, JavaScript, static
assets, and the rendering side of realtime, caching, i18n and error states.
The rules are foundational and mandatory; all future frontend and theme
development MUST comply with them.

## Decision

### Accessibility Alignment

Per ADR 0094, frontend rendering MUST treat accessibility as an architectural
invariant:

- SSR templates MUST use semantic HTML, landmarks, logical headings,
  accessible forms, keyboard-operable controls, visible focus, WCAG 2.2 AA
  contrast, and graceful no-JavaScript behavior.
- Themes MUST NOT degrade semantic structure, focus visibility,
  reduced-motion behavior, or contrast below policy.

### Frontend Philosophy

- Frontend architecture MUST prioritize simplicity, maintainability,
  performance, accessibility, security, deterministic rendering and long-term
  sustainability.
- The platform MUST avoid frontend complexity inflation, unnecessary
  client-side frameworks, hydration-heavy architectures and JavaScript-first
  rendering models.
- Preferred model: server-side rendering, progressive enhancement, minimal
  JavaScript, component-oriented UI composition.

### Rendering Philosophy

- Rendering MUST remain deterministic, server-driven, security-aware and
  cache-friendly.
- The canonical rendering strategy is SSR (server-side rendering).
- The frontend MUST remain functional without heavy client-side execution,
  under degraded JavaScript environments, and under partial realtime
  disruption.

### Preferred Frontend Stack

- Preferred technologies: Mojolicious rendering, HTMX, Alpine.js (minimal
  usage only), CSS custom properties, server-rendered HTML.
- The platform MUST avoid SPA-first architecture, unnecessary hydration
  systems and frontend state duplication.

### Progressive Enhancement

- The frontend MUST degrade gracefully.
- Core functionality MUST remain usable without JavaScript where possible,
  under websocket failure, and under delayed asynchronous updates.
- JavaScript MUST enhance functionality, not define baseline usability.

### Template Architecture

- Templates MUST remain presentation-oriented, deterministic and minimal in
  logic.
- Business logic inside templates is prohibited.
- Templates MUST NOT perform authorization logic, perform persistence logic,
  execute workflow orchestration, or access infrastructure services directly.

### ViewModel Philosophy

- Rendering MUST consume prepared ViewModels.
- The application layer MUST prepare visibility flags, permissions, rendering
  states, formatted content and UI-safe values.
- Templates SHOULD remain declarative.

### Template Structure

- Recommended structure: `templates/` containing `layouts/`, `components/`
  and `partials/`.
- Themes MAY override layouts, components, assets and visual tokens.
- Themes MUST NOT redefine business workflows, security logic or
  authorization rules.

### Theme System Philosophy

- Themes are presentation-only.
- Themes MUST remain isolated, replaceable, inheritable and
  security-constrained.
- Themes MUST NOT execute arbitrary Perl, access databases, bypass
  sanitization, or introduce unsafe JavaScript.

### Theme Architecture

- Recommended structure: `themes/` containing `default/`, `dark/`,
  `minimal/` and `corporate/`.
- Each theme SHOULD contain templates, layouts, partials, assets, tokens and a
  theme manifest.

### Theme Manifest

- Themes SHOULD expose metadata, inheritance declarations, versioning and
  asset versions.
- Recommended metadata: `name`, `version`, `parent`, `compatibility`.

### Theme Inheritance

- Theme inheritance is mandatory.
- Themes SHOULD override selectively, inherit defaults automatically and
  minimize duplication.
- The architecture MUST support partial overrides, fallback resolution and
  component replacement.

### Component System

- The frontend MUST use reusable UI components (examples: thread card, post
  renderer, notification item, paginator, modal, navigation bar).
- Components MUST remain composable, isolated and predictable.

### Component Philosophy

- Components MUST receive prepared data, avoid direct infrastructure access
  and avoid business logic execution.
- Components SHOULD remain reusable, themeable and testable.

### CSS Architecture

- The platform MUST use design tokens, CSS custom properties, predictable
  spacing systems and scalable typography systems.
- The architecture MUST avoid uncontrolled CSS sprawl, global override chaos
  and duplicated style logic.

### Design Tokens

- Mandatory token categories: colors, spacing, typography, radii, elevation,
  motion timing.
- Themes SHOULD customize tokens rather than raw layout structures.

### Dark Mode

- Dark mode SHOULD use token-based rendering and `prefers-color-scheme`
  support.
- Dark mode SHOULD NOT require a separate frontend architecture or duplicated
  layouts.

### Asset Philosophy

- Assets MUST support fingerprinting, immutable caching, compression and CDN
  delivery.
- The platform MUST avoid mutable asset URLs and cache-unsafe deployment.

### JavaScript Philosophy

- JavaScript MUST remain minimal, explicit, progressively enhanced and
  security-aware.
- The platform SHOULD avoid frontend state duplication, giant client-side
  runtimes and hydration-heavy rendering.

### HTMX Philosophy

- HTMX is preferred for incremental updates, partial rendering, realtime
  fragment updates and low-complexity interactivity.
- HTMX interactions MUST remain server-authoritative, permission-aware and
  validation-aware.

### Alpine.js Philosophy

- Alpine.js MAY be used for lightweight UI behavior, toggles, dropdowns and
  local interaction state.
- Alpine.js MUST NOT become the application state layer.

### Accessibility Philosophy

- The frontend MUST prioritize semantic HTML, keyboard navigation, screen
  reader compatibility, accessible forms and focus visibility.
- Accessibility is mandatory.

### Browser Security

- Frontend rendering MUST comply with CSP, output escaping, strict
  sanitization and safe asset delivery.
- Unsafe inline JavaScript SHOULD be minimized.

### User Content Rendering

- User-generated content MUST remain sanitized, remain escaped appropriately
  and support safe markdown rendering.
- Unsafe HTML execution is prohibited.

### Realtime UI Philosophy

- Realtime UI updates MUST degrade gracefully, remain eventually consistent
  and avoid frontend authority assumptions.
- Realtime rendering SHOULD update fragments incrementally and avoid
  full-page rerenders.

### Caching Philosophy

- The frontend MUST support fragment caching, edge caching, ETag validation
  and conditional responses.
- Rendered fragments MUST remain permission-aware and cache-safe.

### Responsive Design

- The frontend MUST support mobile layouts, desktop layouts, adaptive
  rendering and touch-safe interactions.
- Responsive behavior MUST remain token-driven and component-oriented.

### Internationalization

- The frontend SHOULD support localization, translation, pluralization and
  timezone-aware rendering.
- UI text MUST avoid hardcoded language assumptions.

### Error Rendering

- Frontend error states MUST remain graceful, remain user-safe and avoid
  information leakage.
- Internal exceptions MUST NOT leak stack traces, SQL or infrastructure
  details.

### Long-Term Frontend Goal

- The frontend architecture MUST remain maintainable for decades,
  security-focused, highly performant, accessible, cache-efficient,
  operationally predictable and adaptable to future UI evolution.
- The frontend is NOT a separate application. It is a rendering layer over a
  server-authoritative distributed platform.

## Consequences

- Pages stay usable without JavaScript and under realtime outages, and HTML
  responses remain cacheable at the edge and validatable with ETags.
- Keeping decisions in ViewModels makes templates declarative and lets
  presenters be unit-tested without rendering.
- Themes cannot become a code-execution or data-access channel, but every
  interactive feature needs a server-rendered fragment and a server-side
  permission check instead of client state.
- Fragment caches must be keyed so cached output never crosses permission or
  moderation scopes.
- HTMX and Alpine.js are preferred tools, not requirements; the current SSR
  shell ships only `assets/js/site.js`, and adopting either stays subject to
  the minimal-JavaScript and progressive-enhancement rules.
- Open conflict: themes are token-only today (`themes/*/tokens.css` plus
  `GPForum::Theme::Registry`). There are no theme manifests, per-theme
  templates, layouts or assets, and no override or fallback resolution
  beyond falling back to the `default` theme name, although theme
  inheritance is mandatory. The shipped set (`default`, `dark`,
  `high_contrast`) also differs from the recommended `minimal` and
  `corporate` themes.
- Open conflict: motion timing is a mandatory token category, but
  `assets/css/gpforum-ssr.css` defines no motion tokens (only a
  reduced-motion override).
- Open conflict: the layout links the stylesheet at the unfingerprinted URL
  `/gpforum-ssr.css`, contrary to the MUST on fingerprinting and avoiding
  mutable asset URLs.
- Open conflict: dark mode is chosen explicitly (`data-theme`, the
  `gpforum_theme` cookie, `users.preferred_theme`); `prefers-color-scheme`
  is not honored (SHOULD).
- Repository note: the recommended `templates/partials/` directory does not
  exist; templates are grouped by feature next to `layouts/` and
  `components/`.

## Alignment

- ADR 0001, ADR 0003, ADR 0004, ADR 0019, ADR 0021, ADR 0024
- ADR 0053 (security), ADR 0055 (realtime), ADR 0057 (authorization),
  ADR 0073 (UX), ADR 0094 (accessibility)
- `lib/GPForum/Theme/Registry.pm`, `lib/GPForum/View/Presenter.pm`,
  `lib/GPForum/ViewModel/`, `lib/GPForum/Web/RenderPolicy.pm`,
  `lib/GPForum/Web/PublicHttpCache.pm`,
  `lib/GPForum/Security/BrowserHeaders.pm`
- `templates/layouts/default.html.ep`, `templates/components/`,
  `themes/default/tokens.css`, `themes/dark/tokens.css`,
  `themes/high_contrast/tokens.css`, `assets/css/gpforum-ssr.css`,
  `assets/js/site.js`
- `THEMING.md`, `docs/UI_SYSTEM.md`, `docs/UI_ACCESSIBILITY.md`,
  `docs/VIEW_MODELS.md`, `docs/ui/design-system.md`,
  `docs/ui/accessibility.md`, `docs/architecture/presentation.md`,
  `docs/i18n.md`
- `t/35-forum-accessible-ssr.t`, `t/48-browser-security.t`,
  `t/64-i18n.t`, `t/65-accessible-theme.t`, `t/67-ui-system.t`,
  `t/68-view-presenter.t`, `t/74-view-model-presenters.t`,
  `t/79-theme-preference.t`, `t/115-web-public-cache-access.t`,
  `t/120-forum-view-models.t`
