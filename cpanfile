requires 'perl', '5.038.0';

requires 'Mojolicious', '9.49';
requires 'DBIx::Class', '0.082844';
requires 'Minion', '12.0';
requires 'JSON::MaybeXS', '1.004008';
# Never loaded by name: it is the XS backend JSON::MaybeXS selects at runtime,
# and the floor is what keeps it from falling back to the pure-Perl one.
requires 'Cpanel::JSON::XS', '4.52';
requires 'Try::Tiny', '0.32';
requires 'DateTime', '1.67';
# Named directly by the date formatter and the time zone preference (9.3).
requires 'DateTime::TimeZone', '2.69';
requires 'Crypt::Argon2', '0.032';
requires 'Crypt::URandom', '0.55';
requires 'Email::Sender', '2.601';
requires 'Email::Address::XS', '1.05';
requires 'Email::Simple', '2.218';
requires 'Const::Fast', '0.014';

# Security floors for transitive dependencies with published CPANSA advisories.
requires 'DBI', '1.653';

# What the suite loads. Carton cannot install without the test phase (and
# Menlo installs a cpanfile's direct test requirements even under --notest),
# so these reach every host; they are small and pure Perl.
on test => sub {
    requires 'Test::More', '1.302225';
    requires 'Test::Exception', '0.43';
    requires 'Test::Fatal', '0.019';
};

# The maintainer's tools. A production host installs without them:
# `make install-deps-production` (script/bootstrap-deps --production).
on develop => sub {
    # Perl::Critic, Perl::Tidy, Devel::Cover and Devel::NYTProf are invoked as
    # programs by script/, not loaded by name, so they are declared but never
    # appear in a use statement.
    requires 'Perl::Critic', '1.156';
    requires 'Perl::Tidy', '20260826';
    requires 'Devel::Cover', '1.52';
    requires 'Devel::NYTProf', '6.15';

    # Security floors for transitive test-tool dependencies.
    requires 'URI', '5.37';
    requires 'HTTP::Date', '6.08';
    requires 'List::SomeUtils::XS', '0.59';
};

# PostgreSQL driver, Minion Pg backend, and DB-backed test helper.
# Kept in cpanfile.postgres so the declared set stays split. Carton
# installs this feature unless `script/bootstrap-deps` passes
# `--without postgres`.
feature 'postgres', sub {
    do './cpanfile.postgres';
};
