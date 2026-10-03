# ADR 0115: The Translation Catalogs Are Gettext PO Files

## Status

Accepted. Amends ADR 0021, which rejected external PO files and kept the
catalogs as a Perl literal in `GPForum::Service::I18N::Catalog`; its split
of Catalog, Locale and Formatter stands.

## Context

ADR 0021 kept the English and Italian messages as one compiled Perl hash,
"for the current two-locale foundation". By October 2026 that hash was 671
keys in each locale and most of `lib/GPForum/Service/I18N/Catalog.pm`'s
1,823 lines. The trouble was who could work on it, not the size:

- a translator had to edit Perl, where a missing quote or comma stops the
  application, and no translation tool -- Poedit, Lokalize, Weblate -- could
  open the file;
- nothing recorded which English a translation was made from, so a change to
  the English left the Italian silently out of date;
- a placeholder dropped from a translation (`{user_id}`) was found only by a
  reader.

GNU gettext's PO format answers all three, and every translation tool reads
it.

## Decision

- **One PO file per locale, named after it**: `locale/en.po` and
  `locale/it.po`, UTF-8, each with a header that names its `Language` and
  declares `Plural-Forms: nplurals=2; plural=(n != 1);`, the only rule the
  formatter's `one`/`other` categories serve. An entry's `msgctxt` is the
  key, its `msgid` the English, its `msgstr` the locale's text; a counted
  message is a plural entry (`msgid_plural`, `msgstr[0]`, `msgstr[1]`), and
  a message with `{name}` placeholders carries `#, python-brace-format`, so
  `msgfmt --check` and the editors refuse a translation that loses one.
- **A message is looked up by its key alone.** The code asks
  `t('auth.signed_in_as')`, as it did before; the `msgid` is what the
  translator reads, not part of the lookup. Gettext proper looks a message
  up by its English, which would have rewritten every `t()` call and made
  each change of wording a change of code. The cost: an English changed in
  `en.po` without `msgmerge` leaves the Italian entry with the old `msgid`,
  and the loader still serves its old translation. The loader does not
  compare the files; `t/295-i18n-po-catalogs.t` does ("translates the
  current English of every message") and fails until `it.po` is merged and
  the message translated again.
- **The reader is the project's own**, `GPForum::Service::I18N::PoFile`,
  not a CPAN dependency. It accepts what gettext's tools write for these
  files -- comments, flags, continued strings, the escapes `\\`, `\"`, `\n`,
  `\r` and `\t`, obsolete `#~` entries, which it skips -- and refuses
  anything else, an octal or hexadecimal escape and a charset other than
  UTF-8 included, naming the file and, where there is one, the line.
  `GPForum::Service::I18N::Catalog` adds the rules of this application: a
  message must have a `msgctxt`, once per file; the header's `Language`
  must match the file name and its plural rule the formatter's; an English
  catalog must exist. A fuzzy entry or an empty `msgstr` is left out, as
  gettext would leave it, so the page shows the English. The facade reports
  that fallback to a `missing_key_logger` when one is set, but the
  application does not set one: in a deployment the fallback is silent.
  What keeps the shipped catalogs complete is `t/295-i18n-po-catalogs.t`,
  which refuses an empty or fuzzy entry in any of them.
- **The catalogs are read once, when Catalog loads.** Under Hypnotoad that
  is the manager, before the workers fork, so every worker shares the parsed
  catalog and no request reads a file. A malformed catalog stops the
  application at startup instead of serving keys. An edited file takes
  effect at the next restart or hot deploy.
- **Every `.po` file in `locale/` is a supported locale.** The list the
  negotiator and the selector use is the files present, not a list in code.

## Consequences

- Loading the module now costs about 46 ms on the development machine
  (Perl 5.44, macOS, with Mojolicious already loaded), of which reading and
  checking the two files is about 35 ms; the Perl literal compiled in about
  5 ms. It is paid once per start, in the manager; a worker pays nothing.
- A translator works in a PO editor or with gettext's tools: `msgfilter`
  makes a template of the English, `msgmerge` brings a locale up to date
  (marking a changed message fuzzy and keeping the old English), and
  `msgfmt --check` validates. `docs/i18n.md` is the workflow.
- `t/295-i18n-po-catalogs.t` is the gate: the catalogs are what the files
  hold and no message is left in the module; every locale has every English
  key and no other, translated from the current English, with every
  placeholder kept and plural exactly where the code counts; a translation
  that reads as the English says so with `# Same as English.`; and
  `msgfmt --check` accepts each file when gettext is installed.
  `t/297-i18n-po-reader.t` covers the reader and the loader, malformed files
  included.
- A new locale is a new file plus what the file cannot carry: its metadata
  in `GPForum::Service::I18N::Locale` and a migration widening
  `users_preferred_locale_check`. A language whose plural rule is not
  `n != 1` (French, Polish) needs the formatter's plural categories first;
  the loader refuses its header until then.
- Lookup, interpolation and plural selection are unchanged: the PO files
  load into the same in-memory shape the hash had, the same 671 keys in each
  locale.

## Alternatives Rejected

- Look messages up by `msgid`, as gettext does: see above; the keys stay.
- Compile `.mo` files and read them with a gettext binding: a build step
  and an XS or CPAN dependency for a load that takes milliseconds, and a
  compiled file a reviewer cannot read in a diff.
- Keep the Perl literal (ADR 0021): none of the three problems above is
  solved by it.

## Alignment

ADR 0021 (I18N boundaries, amended), ADR 0052 (Perl engineering
discipline: dependencies intentional and minimal, so the reader is a module
of the project).

- `docs/i18n.md`
- `lib/GPForum/Service/I18N/Catalog.pm`,
  `lib/GPForum/Service/I18N/PoFile.pm`
- `locale/en.po`, `locale/it.po`
- `t/295-i18n-po-catalogs.t`, `t/297-i18n-po-reader.t`, `t/64-i18n.t`
