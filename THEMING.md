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

The stylesheet adds three colours the registry does not hold, each set per
theme: `--color-subtle` for metadata, `--color-hairline` for the rules between
rows, and `--color-mark` for search highlights.

## Type and layout

`assets/css/gpforum-ssr.css` is one file in ten numbered sections, tokens
first. Three rules hold throughout: a colour is a token, a direction is
logical (`inline`, `block`), and a size comes from the scale.

- **Faces.** The platform's own: `--font-ui` and `--font-mono` name system
  fonts only, and no web font is shipped.
- **Sizes.** Seven, `--font-size-xs` to `--font-size-2xl`. Interface text is
  `md` (16px); text read at length, a post's body, is `body` (17px) at
  `--line-height-reading`. Headings are set tighter (`--tracking-display`,
  `--tracking-heading`), as large type asks.
- **Weights.** `--weight-regular` to `--weight-bold`. Hierarchy comes from
  size and colour before weight: body text is regular, metadata is
  `--color-subtle`.
- **Code.** Monospace at 0.875em, without ligatures, so every character shows
  as typed. A fenced block scrolls sideways rather than wrapping.
- **Column.** A page is one column of `--content-max` (44rem), which keeps a
  post near 70 characters a line. A console asks for the wide column with
  `% layout 'default', shell => 'wide';`.
- **Lists.** Rows between hairlines (`.ui-card-list`), not boxes. A row with
  one destination is one target (`.ui-row`, `.ui-row__title`).
- **Sheets.** An action that needs a field or a second thought opens over the
  page: `components/sheet` is an HTML popover, opened by a button's
  `popovertarget`, closed by Escape or a click outside, with no script.
  Without popover support it is a panel in the page and its form still works.

## Accessibility

Theme changes must preserve WCAG 2.2 AA contrast across every supported theme.
Prefer AAA for normal body text and long-form reading surfaces. The registry,
main stylesheet, and `themes/*/tokens.css` files are tested for token parity.

Run:

```sh
carton exec prove -lr t/65-accessible-theme.t t/67-ui-system.t \
    t/188-theme-contrast.t t/320-thread-page-reading-first.t
```

before merging visual changes.
