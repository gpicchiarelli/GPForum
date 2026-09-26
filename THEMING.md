# GPForum Theming

GPForum uses a conservative institutional theme derived from the logo palette.
The runtime registry is `GPForum::Theme::Registry`; CSS tokens live in
`assets/css/gpforum-ssr.css` and synchronized reference copies live under
`themes/`.

## Themes

Current contracts:

- `default`
- `dark`
- `high_contrast`

`GPFORUM_DEFAULT_THEME` configures the SSR default. Supported values are
`default`, `dark`, and `high_contrast`. The SSR shell exposes a POST `/theme`
selector backed by CSRF protection, and authenticated users can manage the same
theme from `/settings`. Guests persist a validated `gpforum_theme` cookie;
authenticated users also persist `users.preferred_theme`. Invalid values fall
back to the configured default without entering HTML attributes.

## Token Files

```text
themes/default/tokens.css
themes/dark/tokens.css
themes/high_contrast/tokens.css
```

Theme tokens cover:

- background;
- foreground;
- muted text;
- surface and alternate surface;
- primary;
- secondary;
- accent;
- border;
- danger;
- success;
- warning and info;
- state surfaces;
- text-on-action colors;
- focus ring.

## Accessibility

Theme changes must preserve WCAG 2.2 AA contrast across every supported theme.
Prefer AAA for normal body text and long-form reading surfaces. The registry,
main stylesheet, and `themes/*/tokens.css` files are tested for token parity.

Run:

```sh
carton exec prove -lr t/65-accessible-theme.t t/67-ui-system.t
```

before merging visual changes.
