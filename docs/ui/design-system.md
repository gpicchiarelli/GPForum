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

Core components live in `templates/components/`:

- shell: `site_header`, `primary_nav`, `identity_nav`, `locale_selector`,
  `breadcrumbs`, `flash_messages`, `site_footer`;
- content: `page_header`, `section_header`, `card`, `empty_state`;
- feedback: `alert`, `status_banner`, `confirmation`, `error_summary`,
  `field_error`;
- operational UI: `badge`, `status_badge`, `moderation_indicator`,
  `admin_table`, `notification_surface`;
- utility: `pagination`, `loading`, `dialog`.

Add new UI by extending semantic tokens and components first. Route-specific CSS
should be rare and justified by a surface that cannot be expressed as a shared
primitive.
