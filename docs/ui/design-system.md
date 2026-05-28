# SSR Design System

GPForum's design system is SSR-first and implemented with Mojolicious partials
and `assets/css/gpforum-ssr.css`. It has no Node.js build step and no SPA
runtime.

The palette is derived from the GPForum mark:

- paper background: `#f8f6ef`;
- ink foreground: `#111412`;
- forest primary: `#214237`;
- steel secondary: `#3f5f72`;
- copper accent: `#a6532f`;
- semantic danger/success/warning/focus tokens.

`GPForum::Theme::Registry` is the runtime contract for theme names, color
schemes, label keys, theme-color metadata, and semantic color tokens. The SSR
shell applies `data-theme` and `data-color-scheme`; invalid theme values fall
back before rendering.

Core components live in `templates/components/`:

- shell: `site_header`, `primary_nav`, `identity_nav`, `locale_selector`,
  `theme_selector`, `breadcrumbs`, `flash_messages`, `site_footer`;
- content: `page_header`, `section_header`, `card`, `empty_state`;
- feedback: `alert`, `status_banner`, `confirmation`, `error_summary`,
  `field_error`;
- operational UI: `badge`, `status_badge`, `moderation_indicator`,
  `admin_table`, `notification_surface`;
- utility: `pagination`, `loading`, `dialog`.

The authenticated `/settings` surface combines locale, theme, and notification
channel preferences in ordinary SSR forms. It should remain the canonical place
for durable account preferences; shell selectors are quick controls for the same
locale/theme state.

Add new UI by extending semantic tokens and components first. Route-specific CSS
should be rare and justified by a surface that cannot be expressed as a shared
primitive. Theme token changes must update the registry, `gpforum-ssr.css`, and
the matching `themes/*/tokens.css` reference file together.
