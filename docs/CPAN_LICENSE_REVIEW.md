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
| Type::Tiny | runtime | Perl 5 license | lightweight type constraints | allowed |
| Try::Tiny | runtime | MIT | small exception helper | allowed |
| Syntax::Keyword::Try | runtime | Perl 5 license | syntax dependency, reviewed before expansion | allowed |
| Log::Any | runtime | Perl 5 license | logging facade | allowed |
| Log::Any::Adapter | runtime | Perl 5 license | logging adapter | allowed |
| DateTime | runtime | Perl 5 license | date/time core dependency | allowed |
| DateTime::Format::Pg | runtime | Perl 5 license | PostgreSQL timestamp conversion | allowed |
| Crypt::Argon2 | runtime | CC0 / public-domain-style metadata | password hashing XS dependency | allowed |
| Crypt::URandom | runtime | Perl 5 license | entropy source | allowed |
| Email::Sender | runtime | Perl 5 license | email delivery boundary | allowed |
| Email::MIME | runtime | Perl 5 license | MIME message construction | allowed |
| Const::Fast | runtime | Perl 5 license | immutable scalar helper | allowed |
| Perl::Critic | develop | Perl 5 license | quality gate only | dev-only allowed |
| Perl::Tidy | develop | GPL-compatible tooling posture | formatting gate only | dev-only allowed |
| Test::More | develop | Perl 5 license | test framework | dev-only allowed |
| Test::Exception | develop | Perl 5 license | test helper | dev-only allowed |
| Test::Deep | develop | Perl 5 license | test helper | dev-only allowed |
| Test::Fatal | develop | Perl 5 license | test helper | dev-only allowed |
| Test::MockModule | develop | Artistic-2.0 | test double helper | dev-only allowed |
| Test::WWW::Mechanize | develop | Perl 5 license | web test helper | dev-only allowed |
| Devel::Cover | develop | Perl 5 license | coverage tool | dev-only allowed |
| Devel::NYTProf | develop | Perl 5 license | profiling tool | dev-only allowed |
| DBD::Pg | optional-postgres | Perl 5 license | PostgreSQL driver for DB-backed CI and deployments | allowed |
| Test::PostgreSQL | optional-postgres | Perl 5 license | PostgreSQL integration testing helper | dev-only allowed |

Dependency governance rules:

* Any new `requires` entry in `cpanfile` or `cpanfile.postgres` must add a row here in the same patch.
* Runtime dependencies require explicit license posture and operational risk.
* Development dependencies may be stricter or heavier only if they do not become
  production requirements.
* `script/cpan-license-check` is the mechanical gate that ensures review
  coverage does not drift.
