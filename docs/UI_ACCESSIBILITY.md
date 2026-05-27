# GPForum SSR UI accessibility notes

The SSR UI theme is derived from the logo palette:

| Token | Color |
| --- | --- |
| Background | `#f8f6ef` |
| Foreground | `#111412` |
| Primary | `#214237` |
| Secondary | `#3f5f72` |
| Accent | `#a6532f` |
| Danger | `#9d2424` |
| Success | `#236b45` |

WCAG contrast checks are enforced in `t/65-accessible-theme.t`.

| Pair | Ratio | Target |
| --- | ---: | --- |
| Foreground on background | 17.15:1 | AAA normal text |
| Muted text on background | 9.80:1 | AAA normal text |
| Primary links on background | 10.23:1 | AAA normal text |
| White on primary button | 11.06:1 | AAA normal text |
| White on secondary surface | 6.79:1 | AA normal text |
| White on accent action | 5.38:1 | AA normal text |
| White on danger state | 7.74:1 | AAA normal text |
| White on success state | 6.44:1 | AA normal text |

The shared stylesheet includes visible `:focus-visible` states, skip links,
reduced-motion handling, semantic breadcrumb/flash styling, form styles, and
dark-mode token readiness through `html[data-theme="dark"]`. Dark mode is not
enabled automatically.

Form validation errors are exposed through a summary with `role="alert"` and
field-level messages connected by `aria-describedby`. Invalid controls set
`aria-invalid="true"` and receive a border-width/focusable visual treatment in
addition to color, so the state does not depend on color perception alone.

## SSR component contracts

Reusable UI primitives live under `templates/components/` and are documented in
`docs/UI_SYSTEM.md`. New SSR surfaces should prefer these partials before adding
route-local markup:

- `page_header` for the page heading and top-level actions;
- `site_header`, `primary_nav`, `identity_nav`, `locale_selector`,
  `breadcrumbs`, `flash_messages`, and `site_footer` for the shared shell;
- `pagination` for labelled paging navigation;
- `empty_state` for no-results and not-yet-created states;
- `badge` for status, moderation, job, and audit indicators;
- `alert` for warning/error/success status surfaces.
- `status_banner` for section-level degraded or blocked states;
- `error_summary` and `field_error` for validation feedback;
- `moderation_indicator` for review/audit state labels;
- `admin_table` for operational data that needs column headers;
- `notification_surface` for inbox items and mark-read controls.

Every page should rely on the base layout for the document `<main>` landmark.
Nested `<main>` elements are invalid and are blocked by `t/67-ui-system.t`.

## Theme extension guidance

Add new visual decisions as semantic CSS custom properties first. Prefer
logical properties such as `padding-inline-start` and `inset-inline-start` so
future RTL locales can reuse the layout. Avoid inline `style` attributes in
templates; component and token changes belong in `assets/css/gpforum-ssr.css`.

Print output uses the same content hierarchy but removes navigation, forms,
pagination, and transient messages so long-form discussion pages remain readable
on paper or PDF exports.
