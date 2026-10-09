# ADR 0109: GPForum Is an Application, Not a CPAN Distribution

## Status

Accepted. Records as a decision what had been an omission: the repository
has no `Makefile.PL`, `Build.PL`, `dist.ini` or `META.json`, and nothing said
whether that was deliberate (quality program item 10.6).

## Context

Perl projects usually ship as CPAN distributions: a build file, a `META`
file, module versions that CPAN indexes, and `make test` for whoever
installs them. GPForum has none of that and was never meant to. It runs as
a service on a host its operator controls, from a git checkout or a release
tarball, with its dependencies installed next to it by Carton
(`script/gpforum-carton`) from a pinned `cpanfile.snapshot` (ADR 0059).
Nobody installs GPForum with `cpanm`, and no other program imports
`GPForum::*` modules.

Without a recorded decision, two things kept looking like defects: the
missing build files, and all 413 modules frozen at `our $VERSION = '0.001'`.

## Decision

- GPForum is an **application**. It is not published to CPAN, PAUSE does
  not index its namespace, and the repository MUST NOT gain a
  `Makefile.PL`, `Build.PL`, `dist.ini` or `META.json` to imitate a
  distribution.
- **Dependencies** are declared in `cpanfile` and pinned in
  `cpanfile.snapshot`. They are installed with Carton, never into the
  system Perl, and a release ships them as the Carton vendor bundle for
  offline installs. The `cpanfile` phases carry meaning for an application
  too: `runtime` is what the application loads, `test` what its suite loads,
  `develop` what only a maintainer's tools need. A production host installs
  without `develop` (`make install-deps-production`); Carton cannot leave
  out `test`.
- **The release version is the git tag.** A release is a `vMAJOR.MINOR.PATCH`
  tag; `.github/workflows/release.yml` derives the version from it and builds
  the source tarball (`git archive`), the vendor bundle, checksums and
  provenance from that commit. `CHANGELOG.md` names releases by the same
  version.
- **A module's `$VERSION` is not the release version.** Every module declares
  `our $VERSION = '0.001'` because `Modules::RequireVersionVar` and the POD
  `VERSION` section require one, and it MUST stay fixed: bumping it per
  module would say that modules are versioned separately, which they are
  not. Code that needs the running version asks the release metadata, not a
  module.
- **The operator interface** is the `bin/` entrypoints behind the
  `bin/gpforum` front door, the `make` targets and the unit files under
  `deploy/` -- not `make install`. The suite under `t/` is the project's own,
  run by `make test` and `make integration`; it is not an installer's check.

## Consequences

- An operator installs GPForum by checking out a tag or unpacking its
  tarball and running `make install-deps-production`, which runs
  `carton install --deployment --without develop` against the committed
  snapshot (`docs/DEPLOYMENT.md`); there is no other supported path.
- Tooling that assumes a distribution -- `dzil`, `cpanm .`, CPANTS kwalitee,
  `Module::Build` -- does not apply, and its absence is not a finding.
- Nothing may depend on a module's `$VERSION` to detect features or
  compatibility.
- Release engineering is exercised once by 10.5: tags, versioned CHANGELOG
  sections and an export-ignore list for the tarball follow from this ADR.

## Alignment

- ADR 0052 (Perl engineering discipline), ADR 0059 (CI/CD, quality and
  release engineering), ADR 0087 (ADR governance).
- `cpanfile`, `cpanfile.snapshot`, `script/gpforum-carton`,
  `.github/workflows/release.yml`, `.perlcriticrc`.
