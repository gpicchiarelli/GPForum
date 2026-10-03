# ADR 0021: I18N Catalog, Locale, and Formatter Boundaries

## Status

Accepted. Amended by ADR 0115: the catalogs are no longer a Perl literal in
`GPForum::Service::I18N::Catalog` but the gettext PO files `locale/en.po` and
`locale/it.po`, read at startup by `GPForum::Service::I18N::PoFile`, which
reverses the first alternative rejected below. The split of Catalog, Locale
and Formatter stands.

## Context

`Service::I18N` mixed Accept-Language negotiation, catalog data, interpolation,
plural selection, and date/number formatting in one 1,390-line object. The
bundled English and Italian strings dominated the file, and several helpers
used postfix control. Longevity review listed I18N as the largest remaining
service.

## Decision

Split I18N into dedicated helpers behind the existing facade:

- `GPForum::Service::I18N::Catalog` owns catalog data, lookup, plural-form
  selection, and `{name}` interpolation;
- `GPForum::Service::I18N::Locale` owns negotiation, supported tags, direction,
  and locale metadata;
- `GPForum::Service::I18N::Formatter` owns date, time, datetime, number, and
  one/other plural category.

`GPForum::Service::I18N` remains the public API used by bootstrap, templates,
and notification rendering.

## Consequences

Catalog edits no longer require scanning negotiation or formatting code.
Locale and formatter helpers are unit-testable without Mojolicious. Template
helpers keep calling `t()`, `tc()`, and `ui_*` through the facade.

## Alternatives Rejected

- Store catalogs as external JSON/PO files: rejected for the current two-locale
  foundation; the catalogs stay compiled Perl hashes. Reversed by ADR 0115.
- Move I18N into `GPForum::I18N::*`: rejected because `GPForum::I18N` already
  owns namespace validation, not runtime catalogs.

## Alignment

- `docs/i18n.md`
- `docs/adr/0115-catalogs-are-gettext-po-files.md`
- `t/64-i18n.t`
- `t/117-i18n-boundaries.t`
