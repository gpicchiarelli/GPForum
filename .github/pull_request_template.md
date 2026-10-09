## Summary

-

## Architecture and documentation

- [ ] I updated relevant documentation and ADRs when design decisions changed.
- [ ] I preserved Perl-first, PostgreSQL-authoritative, SSR-first defaults.
- [ ] I avoided god classes and kept boundaries narrow.

## Quality Gate

- [ ] `make check` (syntax, tests, Perl::Critic, perltidy, architecture contract)
- [ ] `script/coverage`
- [ ] Relevant profiling command, when behavior or performance changed.

## Operational Notes

- [ ] Migrations are reversible or documented with rollback strategy.
- [ ] Failure modes, health checks, and audit events are considered.
- [ ] Security and privacy impact is documented.
