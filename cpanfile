requires 'perl', '5.038.0';

requires 'Mojolicious', '9.49';
requires 'DBIx::Class', '0.082844';
requires 'Minion', '12.0';
requires 'JSON::MaybeXS', '1.004008';
requires 'Cpanel::JSON::XS', '4.52';
requires 'Type::Tiny', '2.010001';
requires 'Try::Tiny', '0.32';
requires 'Syntax::Keyword::Try', '0.31';
requires 'Log::Any', '1.720';
requires 'Log::Any::Adapter', '1.720';
requires 'DateTime', '1.67';
requires 'DateTime::Format::Pg', '0.16014';
requires 'Crypt::Argon2', '0.032';
requires 'Crypt::URandom', '0.55';
requires 'Email::Sender', '2.601';
requires 'Email::Address::XS', '1.05';
requires 'Email::MIME', '1.954';
requires 'Const::Fast', '0.014';

# Security floors for transitive dependencies with published CPANSA advisories.
requires 'DBI', '1.653';

on develop => sub {
    requires 'Perl::Critic', '1.156';
    requires 'Perl::Tidy', '20260826';
    requires 'Test::More', '1.302225';
    requires 'Test::Exception', '0.43';
    requires 'Test::Deep', '1.205';
    requires 'Test::Fatal', '0.019';
    requires 'Test::MockModule', '0.185.3';
    requires 'Test::WWW::Mechanize', '1.60';
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
