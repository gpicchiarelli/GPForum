# Contributing

GPForum accepts changes that keep the project independent, Perl-first,
PostgreSQL-authoritative, operable, and explicit.

## Development Loop

1. Install dependencies with `script/bootstrap-deps`.
2. Run `script/system-preflight` before enabling PostgreSQL-specific modules.
3. Make small changes around one bounded context.
4. Update prompts or ADRs for architecture-changing work.
5. Run the quality gate before opening a pull request:

```sh
script/perlcritic
script/test
script/coverage
```

Run profiling for performance-sensitive changes:

```sh
script/profile -Ilib -It/lib t/17-notifications.t
```

## Architectural Rules

- Keep boundaries narrow; do not introduce god classes.
- Prefer domain services, stores, command handlers, and projections.
- PostgreSQL is authoritative. Search, inboxes, feeds, and counters are rebuildable projections.
- Carton, Perl::Critic, tests, coverage, and profiling are mandatory project surfaces.
- Any deviation from Perl-first, PostgreSQL-native, Redis-optional, or SSR-first needs an ADR.

## Pull Requests

Every pull request should include:

- a short user or operator reason;
- tests for the affected behavior;
- prompt or ADR updates when contracts change;
- migration and rollback notes when database shape changes;
- profiling notes when hot paths change.

