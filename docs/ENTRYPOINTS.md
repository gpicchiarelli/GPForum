# Entrypoint Layout

GPForum has two entrypoint directories. This is the rule that decides which
one a new command belongs in. It is enforced by `check_entrypoint_layout` in
`script/architecture-check`, so `make check` and CI fail when it drifts.

## The rule

- **`bin/`** holds **Perl application entrypoints**. These are deployed and
  they load `GPForum::*` runtime code. Every file is a thin shim:

  ```perl
  use GPForum::Command::Example;
  exit GPForum::Command::Example->new->run(@ARGV);
  ```

  `bin/` never contains shell.

- **`script/`** holds **repository tooling** for developers and CI. It is not
  deployed. Most of it is POSIX `sh`; six tools are standalone Perl because
  the tool itself needs Perl (`adr-index`, `bench-outbox-dispatcher`,
  `coverage-check`, `cpan-license-check`, `perl-syntax-check`,
  `query-plan-check`). Of these only `bench-outbox-dispatcher` loads
  `GPForum::*` code: it measures `GPForum::Service::Outbox::Dispatcher`
  against the outbox test doubles, and reads its options through
  `GPForum::Command::Usage`.
  Three `sh` tools run a one-line `perl -Ilib` that does too: `benchmark-http`
  and `standby-drill` connect through `GPForum::Config` and `GPForum::Schema`,
  and `system-preflight` asks `GPForum::Runtime` and
  `GPForum::Service::Operations::OSPreflight`.

- **Naming.** A `script/` wrapper is named after the entrypoint it wraps,
  **without** the `gpforum-` prefix: `script/stress-load` wraps
  `bin/gpforum-stress-load`. The `gpforum-` prefix inside `script/` is
  reserved for standalone tools that have no `bin/` counterpart:
  `gpforum-carton`, `gpforum-system-perl`, `gpforum-homebrew-env`,
  `gpforum-private-beta-checklist`, `gpforum-evidence-live`.

- **Invariant.** No basename appears in both `bin/` and `script/`.

- A wrapper must point at an entrypoint that exists, and every file in both
  directories must be executable.

## Wrappers

A wrapper exists to supply the Carton / system-Perl environment, not to alias
a name. The current form is:

```sh
#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

exec script/gpforum-carton exec bin/gpforum-example "$@"
```

Every wrapper now follows this shape. The ones this paragraph used to list as
calling bare `carton exec` without changing to the repository root
(`query-budget`, `seed-benchmark`, `seed-performance-data`, `bench-http`,
`bench-hypnotoad`, `bench-hypnotoad-scaling`, `outbox-dispatch`,
`scheduled-jobs`, `query-plan-evidence`) have all been moved to
`script/gpforum-carton`; the only script that invokes `carton` directly is
`script/gpforum-carton` itself. Bare `carton` would bypass the system-Perl gate
in `script/gpforum-system-perl`, and on macOS the `carton` found first on
`PATH` can belong to another Perl, so documentation uses
`script/gpforum-carton exec` throughout.

## Legacy collisions

None. Every `script/` wrapper now uses the unprefixed name, so no basename
exists in both directories and `ENTRYPOINT_COLLISION_ALLOWLIST` in
`script/architecture-check` is empty. It may not grow again: a new basename
in both directories fails the check.

## Known duplicate

`bin/gpforum-seed-benchmark` and `bin/gpforum-seed-performance-data` are
byte-identical (both run `GPForum::Command::PerformanceSeed`), and each has its
own wrapper. Collapsing them requires updating `t/49-performance-harness.t` and
`t/18-github-project.t` together.
