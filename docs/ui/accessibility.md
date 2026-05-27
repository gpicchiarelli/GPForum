# Accessibility Guidelines

GPForum targets WCAG 2.2 AA for the SSR shell.

Required contracts:

- exactly one document `<main>` comes from the base layout;
- every page has a skip link to `#content`;
- header, navigation, main, breadcrumbs, flash messages, and footer use semantic
  landmarks or labelled regions;
- form controls have visible labels;
- invalid forms use `components/error_summary` plus field-level
  `components/field_error` connected through `aria-describedby`;
- pagination is a labelled `<nav>`;
- status and moderation controls include text labels, not color-only cues;
- focus styles stay visible through `:focus-visible`;
- motion-sensitive behavior honors `prefers-reduced-motion`;
- print output removes transient shell controls and preserves readable content.

Automated checks:

- `t/65-accessible-theme.t` covers contrast tokens, focus, reduced motion,
  logical direction hooks, screen-reader utilities, and print mode;
- `t/67-ui-system.t` covers component presence, landmarks, localized SSR
  rendering, and representative admin/forum/notification pages.

ARIA should be used only where native HTML needs a name, status, or dialog
semantic. Prefer real labels, headings, lists, forms, and tables.
