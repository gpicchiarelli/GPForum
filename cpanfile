requires 'perl', '5.038.0';

requires 'Mojolicious';
requires 'DBIx::Class';
requires 'Minion';
requires 'JSON::MaybeXS';
requires 'Type::Tiny';
requires 'Try::Tiny';
requires 'Syntax::Keyword::Try';
requires 'Log::Any';
requires 'Log::Any::Adapter';
requires 'DateTime';
requires 'DateTime::Format::Pg';
requires 'UUID::Tiny';
requires 'Crypt::Argon2';
requires 'Email::Sender';
requires 'Email::MIME';

on develop => sub {
    requires 'Perl::Critic';
    requires 'Perl::Tidy';
    requires 'Test::More';
    requires 'Test::Exception';
    requires 'Test::Deep';
    requires 'Test::Fatal';
    requires 'Test::MockModule';
    requires 'Test::WWW::Mechanize';
    requires 'Devel::Cover';
    requires 'Devel::NYTProf';
};
