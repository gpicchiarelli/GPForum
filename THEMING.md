# GPForum Theming

GPForum uses a conservative institutional theme derived from the logo palette.
The runtime registry is `GPForum::Theme::Registry`; CSS tokens live in
`assets/css/gpforum-ssr.css` and synchronized reference copies live under
`themes/`.

## Themes

Current contracts:

- `auto`: the light palette until the reader's device asks for dark, and the
  dark one then. It has no tokens of its own: the stylesheet repeats the dark
  block under `prefers-color-scheme: dark`, and `t/188-theme-contrast.t` holds
  the two copies to the same declarations. The page states `color-scheme:
  light dark` and a `theme-color` for each setting of the device.
- `default`: the light palette, whatever the device asks. Shown as "Light".
- `dark`
- `high_contrast`

`GPFORUM_DEFAULT_THEME` configures the SSR default, which is `auto` unless
set. Supported values are `auto`, `default`, `dark`, and `high_contrast`.
Migration 050 lets `users.preferred_theme` hold `auto` and makes it what a
new member starts with; a member who had `default` keeps the light theme.
The SSR shell exposes a POST `/theme`
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

- **Faces.** Text is set in Inter, shipped with the forum as four variable
  `woff2` files in `assets/css/` (Latin and Latin Extended, upright and
  italic, 277 KB in all; a page in Italian or English fetches the 48 KB
  Latin file, preloaded). Its licence, the SIL Open Font License, is
  `assets/css/inter-LICENSE.txt`. The stylesheet names each file with the
  digest of its bytes (`t/233-asset-fingerprints.t`), so replacing a file
  means writing its new digest in the `@font-face` rule. Until Inter arrives
  the text stands in Arial scaled to Inter's proportions ("Inter Fallback"),
  so it does not move. Code is set in the platform's monospace: none is
  shipped, so none is named.
- **Sizes.** Six, `--font-size-xs` to `--font-size-xl`, and no literal size
  beside them. Controls and metadata are `sm` (14px); interface text is `md`
  (16px); text read at length, a post's body, is `body` (17px) at
  `--line-height-reading`. Headings are set tighter (`--tracking-display`,
  `--tracking-heading`), as large type asks.
- **Weights.** `--weight-regular` to `--weight-bold`. Hierarchy comes from
  size and colour before weight: body text is regular, metadata is
  `--color-subtle`.
- **Tones.** Text has two: `--color-foreground` and the quieter
  `--color-subtle`. `--color-muted` stays a registry token and sets no text
  (`t/188-theme-contrast.t`): used beside `subtle` it could not be told from
  it.
- **Code.** Monospace at 0.875em and never below `--font-size-xs`, without
  ligatures, so every character shows as typed. A fenced block scrolls
  sideways rather than wrapping.
- **Column.** A page is one column of `--content-max` (38rem). Beside its
  avatar a post's text is 564px wide, which at 17px in Inter measured 67 to
  71 characters a full line; at 44rem in the system face it had measured 80.
  Text set outside a post (`.prose`) is held to `--measure-readable`. A
  console asks for the wide column with `% layout 'default', shell => 'wide';`.
- **Navigation.** The header holds places, not actions: starting a thread is
  a button on the pages that list threads. The link to the page being read
  carries `aria-current` and the header's one stroke of the accent.
- **Choices among a few.** Language and theme in the footer are `.segmented`
  groups of buttons, one press each, the one in use marked `aria-pressed`.
- **Lists.** Rows between hairlines (`.ui-card-list`), not boxes. A row with
  one destination is one target (`.ui-row`, `.ui-row__title`).
- **Avatars.** `.avatar` is a name's initial on one of the palette's three
  tints (`forest`, `steel`, `clay`), chosen from the username by
  `ViewModel::Base::tint` and so always the same for a member.
- **Console filters.** `.filter-form` lays its `.field`s out as a grid, as
  many to a line as fit, so the list being filtered stays on the first screen.
- **Sheets.** An action that needs a field or a second thought opens over the
  page: `components/sheet` is an HTML popover, opened by a button's
  `popovertarget`, closed by Escape or a click outside, with no script.
  Without popover support it is a panel in the page and its form still
  works; the buttons that would open or close it are hidden until the
  stylesheet knows popovers are there (`t/320`).

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
