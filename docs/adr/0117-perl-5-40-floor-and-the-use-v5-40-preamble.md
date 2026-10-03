# ADR 0117: Perl 5.40 Floor and the `use v5.40` Preamble

## Status

Accepted. Amends ADR 0052, whose "every module MUST include `use strict;`
and `use warnings;`" now reads "every Perl file declares `use v5.40;`", which
implies both, and ADR 0049's "Mandatory: `use strict`; `use warnings`" in the
same way.

## Context

The supported floor was Perl 5.38: `cpanfile` required 5.038.0,
`script/gpforum-system-perl` refused anything older, and the deployment
documents named Ubuntu 24.04, which ships 5.38.x. Every Perl file opened with
`use strict; use warnings;`, most of them followed by
`use Mojo::Base ..., -signatures`. Three habits had grown around what 5.38
could not give:

- **No `try`.** Native `try`/`catch` is experimental before 5.40, so six
  files used Try::Tiny and the rest used `eval` and `$EVAL_ERROR` (273 evals
  in `lib/`). Under any feature bundle that enables `try`, Try::Tiny's
  `my $x = try {...}` is a syntax error.
- **`my $undefined; return $undefined;`.** Perl::Critic's
  ProhibitExplicitReturnUndef forbade `return undef`, and a bare `return;` is
  wrong in this tree: it returns an empty list in list context, and hundreds
  of call sites put a result in a hash literal or an argument list, where an
  empty list shifts every pair after it. `script/architecture-check` guards
  the column readers because that happened once. The idiom returned undef
  through a lexical declared for the purpose: 440 declarations and 546
  returns.
- **Two pragma lines in every file**, 1,932 lines in all, saying what a
  version declaration says in one.

A version declaration interacts with Mojo::Base. Mojo::Base's `import`
calls `feature->import(':5.16')`. Placed before it, `use v5.40` is undone:
indirect object syntax, multidimensional hash keys, bareword filehandles and
switch come back on for the rest of the scope. Placed after it, the 5.40
bundle holds. And `use v5.40` imports the 5.40 builtins lexically -- `trim`,
`blessed`, `true`, `false`, `ceil`, `floor`, `weaken`, `refaddr`,
`reftype` and the rest -- so a package sub of one of those names is
reported as redefined and can no longer be called as a method:
`Identity::Support->trim` and `I18N::Locale->trim` broke that way.

The toolchain was probed on Perl 5.44, Perl::Critic 1.156, PPI 1.291 and
Perl::Tidy 20260826: perltidy formats `try`/`catch` and `use v5.40` stably;
RequireUseStrict and RequireUseWarnings accept `use v5.40`;
ProhibitVersionStrings fires on it; PPI, given a catch block that ends in a
bare `}`, treats the statement as unfinished and swallows the next one into
it, which also makes RequireFinalReturn misfire on a sub ending in
`try`/`catch`; ending the block with `};` fixes both.

## Decision

- **The floor is Perl 5.40.** That is Debian 13 (trixie), Ubuntu 26.04,
  FreeBSD's ports perl or Homebrew's perl. `cpanfile` requires 5.040.0,
  `script/gpforum-system-perl --require` and `script/bootstrap-deps` refuse
  older interpreters, and the CI jobs that run the repository's Perl on the
  runner's system perl use `ubuntu-26.04` (the Debian job already ran
  trixie). The README, `docs/DEPLOYMENT.md`, `docs/PRODUCTION_READINESS.md`
  and `docs/ops/staging-drills.md` say 5.40+.
- **Every Perl file declares `use v5.40;`** -- under `lib/`, `t/`, `t/lib/`,
  `t/integration/`, `bin/` and the Perl programs in `script/` -- and no file
  says `use strict;`, `use warnings;` or `use feature 'signatures';`, which
  it implies. It gives strict, warnings, signatures, stable `try`/`catch`,
  `isa`, `say`, `state`, `fc` and the rest of the 5.40 bundle, and it turns
  off indirect object syntax, multidimensional keys, bareword filehandles and
  switch. Files keep their final `1;`, which RequireEndWithOne still asks
  for, and Mojo::Base lines keep `-signatures`, which is harmless.
- **`use v5.40;` is the line after every `use Mojo::Base`**, inner packages
  included; in a file without Mojo::Base it stands where `use strict;` stood.
  Nothing but comments, `package` and `use` lines comes before it.
- **No sub is named like a 5.40 builtin.** The two `trim` methods are now
  `trimmed`.
- **`try`/`catch` is native, and every `catch` block ends with `};`.**
  Try::Tiny is not used or declared; DBIx::Class, DateTime and Email::Sender
  still install it. `finally` is not used: it is still experimental in 5.40.
  A `return` inside a native `try` returns from the enclosing sub, not from
  the block as Try::Tiny's did, so each `eval` or Try::Tiny block is read
  before it is converted.
- **A sub with no value to return says `return undef;`.** A bare `return;`
  is kept for subs called only for their effect, and a sub whose result is
  used never relies on an empty list. Both forms the idiom replaced return
  the same thing in every context: undef in scalar context, a one-element
  list in list context.
- **The profile follows.** `.perlcriticrc` disables ProhibitVersionStrings
  (it guards perls older than 5.8.1; `use 5.040` would say the same less
  readably) and ProhibitExplicitReturnUndef (the hash-pair hazard above),
  and tells RequireFinalReturn that `rethrow` and `throw` are terminal, so a
  sub may end in `UniqueConflict->rethrow(...)` or `GPForum::X->throw(...)`
  without a dead return after it. Each change carries its reason in the
  profile.
- **Gates.** `t/321-preamble.t` holds every Perl file to the preamble, the
  Mojo::Base ordering, no strict/warnings lines, no Try::Tiny, no `finally`
  and no builtin-named sub. `script/architecture-check` fails on a `catch`
  block that does not end with `};`.

## Consequences

- A host on Ubuntu 24.04 (perl 5.38) must be upgraded before it deploys this
  release, and the locked tree rebuilt for the new interpreter
  (`script/bootstrap-deps --postgres --rebuild-local`), because its XS
  modules are built for one Perl. The CHANGELOG says so under "Operator
  action required".
- The conversion was mechanical and reproducible: the preamble went into
  every Perl file and all 440 `my $undefined;` declarations went. Of the 546
  `return $undefined`, 482 became `return undef`, the 63 dead ones after a
  sub's final, unconditional `rethrow` were deleted, and one went with the
  Try::Tiny block it sat in; the 4 `: $undefined` ternaries became
  `: undef`. No call site changed meaning.
- PPI now parses signatures as signatures in every file. ProhibitManyArgs no
  longer counts signature parameters, which the profile records; its
  fourteen baseline entries stay until a signature-arity check replaces it.
  ProhibitSubroutinePrototypes stays off: under `use v5.40` a prototype can
  only be written as `:prototype(...)`, which neither the policy nor
  `script/architecture-check`'s prototype guard reads.
- The 273 evals in `lib/` become `try`/`catch` slice by slice, and the
  storage probes among them become `GPForum::Infrastructure::Storage->dbh_of`.
  `my $v = eval {...}` becomes `my $v; try { $v = ... } catch ($error) {...};`.
- Rollback is a revert of the preamble and return-undef commits and the
  floor; nothing persisted depends on them.

## Alignment

- ADR 0049 and ADR 0052 (amended); ADR 0118 (exceptions and required
  attributes, which build on `try`/`catch`).
- `cpanfile`, `script/gpforum-system-perl`, `script/system-preflight`,
  `.github/workflows/*.yml`, `.github/actionlint.yaml`.
- `.perlcriticrc`, `script/architecture-check`.
- `lib/GPForum/Service/Identity/Support.pm`,
  `lib/GPForum/Service/I18N/Locale.pm` (`trimmed`),
  `lib/GPForum/Infrastructure/Storage.pm`.
- `README.md`, `docs/DEPLOYMENT.md`, `docs/PRODUCTION_READINESS.md`,
  `docs/ops/staging-drills.md`, `docs/ops/private-beta-checklist.md`.
- `t/321-preamble.t`, `t/144-cpan-install.t`,
  `t/182-dependency-declaration.t`, `t/34-architecture-discipline.t`.
