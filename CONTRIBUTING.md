# Contributing

GPForum accepts changes that keep the project independent, Perl-first,
PostgreSQL-authoritative, operable, and explicit.

## Development loop

1. Use the OS **system Perl** (`/usr/bin/perl` / distro package). Version
   managers and custom PREFIX builds are unsupported. On Debian/Ubuntu install
   `perl`, `build-essential`, `cpanminus`, and `libpq-dev`; then
   `cpanm -M https://cpan.metacpan.org/ Carton`. Confirm with
   `make system-perl` (`which perl`, `perl -v`, `perl -V`).
2. Install dependencies with `make install-deps` (`script/bootstrap-deps`).
   That runs `carton install --deployment` from `cpanfile.snapshot` over
   HTTPS MetaCPAN under system Perl. Use `script/bootstrap-deps --update`
   only when refreshing the lock after a `cpanfile` change, then commit
   `cpanfile.snapshot`.
3. Run `script/system-preflight` before enabling PostgreSQL-specific modules
   (`make install-deps-postgres`).
4. Make small changes around one bounded context.
5. Update prompts or ADRs for architecture-changing work.
6. Run the quality gate before opening a pull request:

```sh
make check
```

Run profiling for performance-sensitive changes:

```sh
script/profile -Ilib -It/lib t/17-notifications.t
```

## Architectural rules

- Keep boundaries narrow; do not introduce god classes.
- Prefer domain services, stores, command handlers, and projections.
- PostgreSQL is authoritative. Search, inboxes, feeds, and counters are rebuildable projections.
- Carton, Perl::Critic, tests, coverage, and profiling are mandatory project surfaces.
- Any deviation from Perl-first, PostgreSQL-native, Redis-optional, required GlifiStore L2, or SSR-first needs an ADR.
- Durable event writes should use `GPForum::Infrastructure::EventRecorder`.
- Raw SSR HTML must pass through `GPForum::Web::RenderPolicy`.
- Browser security headers belong in `GPForum::Security::*`, not controllers.

## Pull requests

Every pull request should include:

- a short user or operator reason;
- tests for the affected behavior;
- prompt or ADR updates when contracts change;
- migration and rollback notes when database shape changes;
- profiling notes when hot paths change.
