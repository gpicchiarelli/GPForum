# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Mojo::File;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Command::Usage;
use GPForum::OS::Darwin;
use GPForum::OS::FreeBSD;
use GPForum::OS::Linux;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::I18N::PoFile;
use GPForum::Service::Operations::DatabaseFailure;
use GPForum::Test::OSWithEnvironmentFile;
use GPForum::Test::RefusedSchema;

our $VERSION = '0.001';

# What every command printed when it could not use the database, as
# DBIx::Class and libpq wrote it on this host (PostgreSQL 18). The
# walkthrough (docs/ops/evidence/2026-10-07-operator-walkthrough, 4.2) found
# it naming neither the variable to change, nor the file it is read from, nor
# what to run.
const my $PREFIX => 'DBIx::Class::Storage::DBI::catch {...} (): '
  . q{DBI Connection failed: DBI connect('dbname=gpforum;host=127.0.0.1;}
  . q{port=5432','gpforum',...) failed: connection to server at }
  . '"127.0.0.1", port 5432 failed: ';
const my $REFUSED => $PREFIX
  . "Connection refused\n\tIs the server running on that host and accepting"
  . ' TCP/IP connections?';
const my $UNKNOWN_DATABASE => $PREFIX
  . 'FATAL:  database "gpforum" does not exist';
const my $UNKNOWN_ROLE => $PREFIX . 'FATAL:  role "gpforum" does not exist';
const my $PASSWORD => $PREFIX
  . 'FATAL:  password authentication failed for user "gpforum"';
const my $NO_HBA => $PREFIX
  . 'FATAL:  no pg_hba.conf entry for host "10.0.0.9", user "gpforum",'
  . ' database "gpforum", no encryption';
const my $UNKNOWN_HOST => 'DBIx::Class::Storage::DBI::catch {...} (): '
  . q{DBI Connection failed: DBI connect('dbname=gpforum;host=db.invalid;}
  . q{port=5432','gpforum',...) failed: could not translate host name }
  . '"db.invalid" to address: nodename nor servname provided, or not known';
const my $NOT_MIGRATED => 'DBIx::Class::Storage::DBI::_dbh_execute(): '
  . 'DBI Exception: DBD::Pg::st execute failed: ERROR:  relation'
  . ' "dead_letters" does not exist';

# The same failures from a server or a C library speaking Italian, in the
# words of PostgreSQL's own it.po and glibc's strerror.
const my $ITALIAN_SERVER => $PREFIX
  . 'FATAL:  il database "gpforum" non esiste';
const my $ITALIAN_REFUSED => $PREFIX . 'Connessione rifiutata';

const my %LINUX_PRODUCTION => (
    os          => GPForum::OS::Linux->new,
    environment => 'production',
    language    => 'en',
);
const my $ENVIRONMENT_FILE => '/etc/gpforum/gpforum.env';

# How much of each text a test name quotes.
const my $QUOTED => -40;

subtest 'each failure is told apart' => sub {
    my %expected = (
        $REFUSED          => 'database.refused',
        $UNKNOWN_DATABASE => 'database.unknown_database',
        $UNKNOWN_ROLE     => 'database.unknown_role',
        $PASSWORD         => 'database.authentication',
        $NO_HBA           => 'database.no_hba',
        $UNKNOWN_HOST     => 'database.unknown_host',
        $NOT_MIGRATED     => 'database.not_migrated',
        $ITALIAN_SERVER   => 'database.unknown_database',
        $ITALIAN_REFUSED  => 'database.refused',
    );
    my $failure =
      GPForum::Service::Operations::DatabaseFailure->new(%LINUX_PRODUCTION);
    for my $text ( sort keys %expected ) {
        is(
            $failure->classify($text)->{key},    $expected{$text},
            "$expected{$text}: " . substr $text, $QUOTED
        );
    }
    is( $failure->classify('mail transport refused the message'),
        undef, 'and anything else is left alone' );

    # The way a mail server, clamd or GlifiStore fails reads like PostgreSQL
    # down; without DBI's, DBD::Pg's or libpq's words around it, it is not.
    for my $text (
        'SMTP TCP connect failed to 127.0.0.1:25: Connection refused',
        'cannot connect to clamd at 127.0.0.1:3310: Connection refused',
        'connect to socket /run/glifistore.sock: No such file or directory',
        'relation "x" does not exist, said the fixture',
      )
    {
        is( $failure->classify($text), undef, "not PostgreSQL: $text" );
    }
};

# The walkthrough's step 14: a command run by hand without the service's
# environment file sees the development defaults, and PostgreSQL refuses a
# password the file would have given. Changing the role's password is the
# wrong remedy; loading the file is the right one.
subtest 'a command that did not read the service file is told so' => sub {
    my $file   = '/etc/gpforum/gpforum.env';
    my %unread = (
        os                      => GPForum::OS::Linux->new,
        environment             => 'development',
        language                => 'en',
        unread_environment_file => $file,
    );
    is(
        GPForum::Service::Operations::DatabaseFailure->new(%unread)
          ->sentence($PASSWORD),
        'PostgreSQL at 127.0.0.1:5432 refused the password of role gpforum:'
          . q{ correct GPFORUM_DATABASE_PASSWORD in your shell's environment,}
          . q{ or set the role's password with sudo -u postgres psql -c}
          . q{ '\password gpforum'. This command did not read}
          . qq{ $file, which holds the service's settings: run it as}
          . ' docs/DEPLOYMENT.md shows.',
        'a second sentence names the file'
    );
    like(
        GPForum::Service::Operations::DatabaseFailure->new( %unread,
            language => 'it' )->sentence($REFUSED),
qr/[.] [ ] Questo [ ] comando [ ] non [ ] ha [ ] letto [ ] \Q$file\E,/msx,
        'in Italian too'
    );
    unlike(
        GPForum::Service::Operations::DatabaseFailure->new( %unread,
            environment => 'production' )->sentence($PASSWORD),
        qr/did [ ] not [ ] read/msx,
        'not when the command runs with the service settings'
    );

    my $present = Mojo::File::tempfile;
    my $os      = GPForum::Test::OSWithEnvironmentFile->new(
        environment_file => "$present" );
    {
        local $ENV{GPFORUM_ENV} = undef;
        is(
            GPForum::Service::Operations::DatabaseFailure->new( os => $os )
              ->unread_environment_file,
            "$present",
            'a file on this host and no GPFORUM_ENV: unread'
        );
        is(
            GPForum::Service::Operations::DatabaseFailure->new(
                os => GPForum::Test::OSWithEnvironmentFile->new(
                    environment_file => "$present.missing"
                )
            )->unread_environment_file,
            undef,
            'no file on this host: nothing to read'
        );
    }
    {
        local $ENV{GPFORUM_ENV} = 'production';
        is(
            GPForum::Service::Operations::DatabaseFailure->new( os => $os )
              ->unread_environment_file,
            undef,
            'GPFORUM_ENV set: the file, or the unit, was read'
        );
    }
    {
        local $ENV{GPFORUM_ENV} = undef;
        my $read = GPForum::Service::Operations::DatabaseFailure->new(
            os               => $os,
            environment      => 'development',
            language         => 'en',
            environment_file => '/srv/gpforum/dev.env',
        );
        is( $read->unread_environment_file,
            undef, 'a file the front door read: nothing unread' );
        like(
            $read->sentence($PASSWORD),
            qr{in [ ] /srv/gpforum/dev[.]env,}msx,
'and in development the setting is corrected there, not in the shell'
        );
    }
};

subtest 'one sentence: the setting, the file and the command' => sub {
    my $failure =
      GPForum::Service::Operations::DatabaseFailure->new(%LINUX_PRODUCTION);
    is(
        $failure->sentence($REFUSED),
        'Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused):'
          . ' start it with sudo systemctl start postgresql, or correct'
          . " GPFORUM_DATABASE_DSN in $ENVIRONMENT_FILE.",
        'PostgreSQL down'
    );
    is(
        $failure->sentence($UNKNOWN_DATABASE),
        'PostgreSQL at 127.0.0.1:5432 has no database gpforum: create it with'
          . ' sudo -u postgres createdb --owner gpforum gpforum, or correct'
          . " GPFORUM_DATABASE_DSN in $ENVIRONMENT_FILE.",
        'no database'
    );
    is(
        $failure->sentence($UNKNOWN_ROLE),
        'PostgreSQL at 127.0.0.1:5432 has no role gpforum: create it with'
          . ' sudo -u postgres createuser --pwprompt gpforum, or correct'
          . " GPFORUM_DATABASE_USER in $ENVIRONMENT_FILE.",
        'no role'
    );
    is(
        $failure->sentence($PASSWORD),
        'PostgreSQL at 127.0.0.1:5432 refused the password of role gpforum:'
          . " correct GPFORUM_DATABASE_PASSWORD in $ENVIRONMENT_FILE, or set"
          . q{ the role's password with sudo -u postgres psql -c}
          . q{ '\password gpforum'.},
        'a wrong password'
    );
    is(
        $failure->sentence($NOT_MIGRATED),
        'The database has no dead_letters table yet: apply the migrations'
          . ' with gpforum migrate, or'
          . " check that GPFORUM_DATABASE_DSN in $ENVIRONMENT_FILE names the"
          . q{ forum's database.},
        'a schema not migrated'
    );
    like(
        $failure->sentence($UNKNOWN_HOST),
qr/\ACannot [ ] find [ ] the [ ] PostgreSQL [ ] host [ ] db[.]invalid:/msx,
        'a host that does not resolve'
    );
    like(
        $failure->sentence($NO_HBA),
        qr/allow [ ] it [ ] in [ ] pg_hba[.]conf/msx,
        'and pg_hba.conf'
    );
};

subtest 'in the operator language, with the operating system commands' => sub {
    my $italian = GPForum::Service::Operations::DatabaseFailure->new(
        %LINUX_PRODUCTION,
        language => GPForum::Service::I18N::CliCatalog->language_of(
            { LANG => 'it_IT.UTF-8' }
        ),
    );
    is(
        $italian->sentence($REFUSED),
        'PostgreSQL non risponde su 127.0.0.1:5432 (connessione rifiutata):'
          . ' avvialo con sudo systemctl start postgresql, oppure correggi'
          . " GPFORUM_DATABASE_DSN in $ENVIRONMENT_FILE.",
        'Italian for LANG=it_IT.UTF-8'
    );
    is(
        GPForum::Service::I18N::CliCatalog->language_of(
            { LC_ALL => 'C', LANG => 'it_IT.UTF-8' }
        ),
        'en',
        'LC_ALL wins over LANG'
    );

    my $mac = GPForum::Service::Operations::DatabaseFailure->new(
        os                      => GPForum::OS::Darwin->new,
        environment             => 'development',
        language                => 'en',
        unread_environment_file => undef,
    );
    is(
        $mac->sentence($REFUSED),
        'Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused):'
          . ' start it with brew services start postgresql@18, or correct'
          . q{ GPFORUM_DATABASE_DSN in your shell's environment.},
        'Homebrew on a laptop, where the shell holds the settings'
    );
    like(
        GPForum::Service::Operations::DatabaseFailure->new( %LINUX_PRODUCTION,
            os => GPForum::OS::FreeBSD->new )->sentence($UNKNOWN_ROLE),
        qr{in [ ] /usr/local/etc/gpforum/gpforum[.]env[.]\z}msx,
        'FreeBSD names its own environment file'
    );
};

# The words live in the command-line catalogs with the rest of what GPForum
# tells an operator (owner decision D13); the English stays beside the code,
# as gettext keeps a msgid in the source.
subtest 'the catalogs carry every message, in both languages' => sub {
    my $english  = GPForum::Service::Operations::DatabaseFailure->english;
    my $catalogs = GPForum::Service::I18N::CliCatalog->catalogs;
    my %msgid =
      map { $_->{context} => $_->{id} }
      @{ GPForum::Service::I18N::PoFile->read_file('locale/cli/en.po')
          ->{entries} };
    for my $key ( sort keys %{$english} ) {
        is( $msgid{$key}, $english->{$key}, "en.po holds $key as the code" );
        is( $catalogs->{en}{$key}, $english->{$key}, 'and says it so' );
        ok( length( $catalogs->{it}{$key} // q{} ), 'it.po translates it' );
        is_deeply(
            [ sort $catalogs->{it}{$key} =~ /[{](\w+)[}]/gmsx ],
            [ sort $english->{$key} =~ /[{](\w+)[}]/gmsx ],
            'with the same placeholders'
        );
    }
};

# Command::Usage is the one place every command reports a failure through.
subtest 'every command says it so' => sub {
    local @ENV{qw(LC_ALL GPFORUM_ENV)} = qw(C production);
    my $error = $REFUSED =~ s/port=5432'/port=5432;password=hunter2'/msxr;
    my ( $status, $output, $errors ) =
      _capture( sub { GPForum::Command::Usage->failure( $error, @_ ) } );
    is( $status, 1, 'a failure is 1' );
    like(
        $errors,
        qr/\A Cannot [ ] reach [ ] PostgreSQL [^\n]+ \n \z/msx,
        'one sentence on stderr'
    );
    unlike( $errors, qr/hunter2|DBIx/msx, 'without DBI or the password' );

    my $document = decode_json($output);
    like(
        $document->{error},
        qr/DBI [ ] connect/msx,
        'the document keeps the error as it was'
    );
    unlike( $document->{error}, qr/hunter2/msx, 'redacted' );
    like(
        $document->{explanation},
        qr/\A Cannot [ ] reach/msx,
        'and carries the sentence'
    );

    my ( undef, undef, $misuse ) = _capture(
        sub {
            GPForum::Command::Usage->error( $UNKNOWN_DATABASE, "Usage: x\n" );
        }
    );
    like(
        $misuse,
        qr/\A PostgreSQL [ ] at [^\n]+ has [ ] no [ ] database/msx,
        'a usage error carrying one says it the same way'
    );

    my ( undef, undef, $other ) =
      _capture( sub { GPForum::Command::Usage->failure('the disk is full') } );
    is( $other, "the disk is full\n",
        'any other failure is printed as it was' );

    my $clamd = 'cannot connect to clamd at 127.0.0.1:3310: Connection refused';
    my ( undef, undef, $refused ) =
      _capture( sub { GPForum::Command::Usage->failure($clamd) } );
    is( $refused, "$clamd\n",
        'a refused connection that is not PostgreSQL is printed as it was' );
};

# The walkthrough's step 30: admin-bootstrap reported a database it could
# not reach as misuse, exit 2 with the usage text after the error.
subtest 'admin-bootstrap says it as a failure, not misuse' => sub {
    local @ENV{qw(LC_ALL GPFORUM_ENV)} = qw(C production);
    my ( $status, undef, $errors ) = _capture(
        sub {
            GPForum::Command::AdminBootstrap->new(
                schema => GPForum::Test::RefusedSchema->new )
              ->run( '--user-id', '018f1004-0001-7000-8000-000000000001' );
        }
    );
    is( $status, 1, 'exit 1' );
    like(
        $errors,
        qr/\A Cannot [ ] reach [ ] PostgreSQL [^\n]+ \n \z/msx,
        'one sentence, without the usage text'
    );

    my ( $misuse, undef, $usage ) = _capture(
        sub { GPForum::Command::AdminBootstrap->new->run('--user-id') } );
    is( $misuse, 2, 'misuse is still 2' );
    like( $usage, qr/Usage:/msx, 'with the usage text' );
};

done_testing();

# Runs a sub given a JSON document handle and returns its result, what it
# printed on stdout and what it printed on stderr.
sub _capture ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDERR = $stderr;
        $status = $code->( $stdout, { status => 'fail' } );
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }

    return ( $status, $output, $errors );
}

1;
