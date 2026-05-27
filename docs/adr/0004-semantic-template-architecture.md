# ADR 0004: Semantic SSR Template Architecture

## Status

Accepted

## Context

GPForum already has a tokenized SSR theme, i18n helpers, view-model presenters,
and reusable first-generation components. As forum, admin, moderation,
notification, and privacy pages expanded, repeated route-local markup started to
appear for form errors, status surfaces, notification cards, moderation labels,
and operational tables.

The product needs a template architecture that keeps Mojolicious SSR simple
while giving new pages a durable component vocabulary.

## Decision

Extend `templates/components/` with semantic primitives for:

- form error summaries and field errors;
- status banners and confirmation sections;
- moderation indicators;
- admin tables;
- notification surfaces;
- generic cards.

Templates should consume stable view-model hashes and component partials rather
than hand-building repeated HTML shapes. Canonical values such as audit actions,
moderation states, job statuses, and search status remain stored as canonical
strings and are translated only in the presentation layer.

The shared stylesheet remains the only visual implementation layer. New
components are styled through CSS custom properties, logical properties, visible
focus states, reduced-motion support, and print-safe shell reduction. No SPA or
frontend build system is introduced.

## Consequences

Benefits:

- form validation, notification inbox, admin status, and moderation history now
  use reusable SSR primitives;
- future product pages have a clear place for shared markup before adding local
  HTML;
- tests can assert component presence, localized rendering, accessibility
  contracts, and theme tokens without exercising a browser build step;
- RTL, dark-mode readiness, print output, and accessibility hooks remain
  centralized.

Costs:

- components are intentionally conservative and do not manage client-side
  interactions yet;
- advanced modal confirmation flows still need progressive enhancement later;
- incremental migration is still required for older templates that only partially
  use the semantic component vocabulary.

## Verification

- `t/65-accessible-theme.t` verifies contrast, focus, direction hooks,
  reduced-motion, print, and shared component CSS.
- `t/67-ui-system.t` verifies component partials, component use in product
  templates, localized route rendering, and single-main landmarks.
- `t/64-i18n.t` verifies catalog coverage for component labels in English and
  Italian.

## Alternatives Rejected

- Introduce a frontend framework or build pipeline: rejected because GPForum is
  intentionally SSR-first and Perl-first.
- Keep shell/navigation markup entirely in the base layout: rejected because the
  layout was becoming a second monolith and repeated UI contracts were harder to
  test.
- Use route-local CSS for each product surface: rejected because accessibility,
  contrast, RTL readiness, and print behavior need centralized tokens.
