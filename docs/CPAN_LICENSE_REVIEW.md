# GPForum CPAN License Review

This review is an operational gate, not a substitute for legal advice. It
records the CPAN dependency decisions GPForum currently accepts for a
BSD-3-Clause project. Production dependencies must remain pinned by
`cpanfile.snapshot`; development-only dependencies must not become runtime
requirements without review.

| Module | Scope | License posture | Risk | Decision |
| --- | --- | --- | --- | --- |
| perl | runtime | Perl 5 license | language runtime | allowed |
| Mojolicious | runtime | Artistic-2.0 | mature web framework | allowed |
| DBIx::Class | runtime | Perl 5 license | mature ORM layer | allowed |
| Minion | runtime | Artistic-2.0 | optional async worker framework | allowed |
| JSON::MaybeXS | runtime | Perl 5 license | JSON adapter selection | allowed |
| Cpanel::JSON::XS | runtime | Perl 5 license | preferred JSON::MaybeXS backend; pinned for CVE-2026-9334 and CVE-2026-9516 | allowed |
| Try::Tiny | runtime | MIT | small exception helper | allowed |
| DateTime | runtime | Perl 5 license | date/time core dependency | allowed |
| Crypt::Argon2 | runtime | Apache-2.0 | password hashing XS dependency | allowed |
| Crypt::URandom | runtime | Perl 5 license | entropy source | allowed |
| Email::Sender | runtime | Perl 5 license | email delivery boundary | allowed |
| Email::Address::XS | runtime | Perl 5 license | Email::Sender::Simple address parsing | allowed |
| Email::Simple | runtime | Perl 5 license | message construction in the identity mailer | allowed |
| Const::Fast | runtime | Perl 5 license | immutable scalar helper | allowed |
| DBI | runtime | Perl 5 license | transitive database interface; security floor for CPANSA-DBI 2026 advisories fixed in 1.652+ | allowed |
| Perl::Critic | develop | Perl 5 license | quality gate only | dev-only allowed |
| Perl::Tidy | develop | GPL-compatible tooling posture | formatting gate only | dev-only allowed |
| Test::More | develop | Perl 5 license | test framework | dev-only allowed |
| Test::Exception | develop | Perl 5 license | test helper | dev-only allowed |
| Test::Fatal | develop | Perl 5 license | test helper | dev-only allowed |
| Devel::Cover | develop | Perl 5 license | coverage tool | dev-only allowed |
| Devel::NYTProf | develop | Perl 5 license | profiling tool | dev-only allowed |
| URI | develop | Perl 5 license | transitive web-test dependency; security floor for CPANSA-URI 2026 advisory | dev-only allowed |
| HTTP::Date | develop | Perl 5 license | transitive web-test dependency; security floor for CPANSA-HTTP-Date 2026 advisory | dev-only allowed |
| List::SomeUtils::XS | develop | Artistic-2.0 | transitive Perl::Critic dependency; security floor for CPANSA-List-SomeUtils-XS 2026 advisory | dev-only allowed |
| DBD::Pg | optional-postgres | Perl 5 license | PostgreSQL driver for DB-backed CI and deployments | allowed |
| Mojo::Pg | optional-postgres | Artistic-2.0 | required by Minion PostgreSQL backend | allowed |
| Test::PostgreSQL | optional-postgres | Perl 5 license | PostgreSQL integration testing helper | dev-only allowed |

Dependency governance rules:

* Any new `requires` entry in `cpanfile` or `cpanfile.postgres` must add a row here in the same patch.
* Runtime dependencies require explicit license posture and operational risk.
* Development dependencies may be stricter or heavier only if they do not become
  production requirements.
* `script/cpan-license-check` is the mechanical gate that ensures review
  coverage does not drift.
