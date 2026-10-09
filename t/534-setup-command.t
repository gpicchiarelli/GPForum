# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Mojo::Loader  qw(load_class);
use Mojo::Util    qw(decode encode);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Setup;
use GPForum::Command::Support::EnvironmentFileEdit;
use GPForum::Command::Support::Verbs;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::Test::SetupAccount;
use GPForum::Test::SetupDatabase;
use GPForum::Test::SetupTerminal;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;
const my $FILE_MODE    => oct '640';
const my $MODE_BITS    => oct '777';
const my $NOT_ROOT     => 1_000;
const my $QUESTIONS    => 3;
const my $NO_GROUP     => 2_147_483_646;
const my $HOST         => 'forum.gpforum.net';
const my $EDIT         => 'GPForum::Command::Support::EnvironmentFileEdit';
const my $OK           => "\N{CHECK MARK} ";
const my $FAILED       => "\N{BALLOT X} ";

# Where stat puts the mode, the owner and the group.
const my $STAT_MODE => 2;
const my $STAT_UID  => 4;
const my $STAT_GID  => 5;

# What a made secret carries after its number, to be as long as production
# asks of one.
const my $LONG => q{-} . ( 'x' x 32 );

# C1: gpforum setup asks three questions -- the address, the database, the
# mail -- and then writes the environment file, makes the database, brings
# the schema up to date and names the next steps. Re-run, it changes
# nothing and says so; it never replaces a setting without asking, or
# --force, and never prints a secret. The database, the account and the
# migrations are stand-ins here; t/integration/postgres-setup.t runs them.

my $directory = tempdir( CLEANUP => 1 );
my $secrets   = 0;
my %migrated;

subtest 'a fresh host, answered with options' => sub {
    my $file = "$directory/fresh.env";
    my $run  = _setup( { file => $file }, _flags() );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};

    my %values = _values($file);
    is_deeply(
        { map { $_ => $values{$_} } _decided() },
        {
            GPFORUM_ENV             => 'production',
            GPFORUM_PUBLIC_BASE_URL => "https://$HOST",
            GPFORUM_MAIL_FROM       => "forum\@$HOST",
            GPFORUM_MAIL_TRANSPORT  => 'sendmail',
            GPFORUM_ANTIVIRUS       => 'clamd',
            GPFORUM_DATABASE_USER   => 'gpforum',
            GPFORUM_DATABASE_DSN    =>
              'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432',
        },
        'the answers, a sender at the address, and production scanning'
    );
    for my $secret (
        qw(GPFORUM_SESSION_SECRET GPFORUM_METRICS_TOKEN GPFORUM_DATABASE_PASSWORD)
      )
    {
        like( $values{$secret}, qr/\A secret-\d+-x+ \z/msx, "$secret made" );
    }
    is( ( stat $file )[$STAT_MODE] & $MODE_BITS, $FILE_MODE, 'mode 0640' );
    is( path($file)->slurp =~ /GPFORUM_LOG_LEVEL/msx ? 1 : 0,
        0, 'the decisions alone, with no advanced row (ADR 0125)' );
    is(
        $run->{database}->made->[0]{password},
        $values{GPFORUM_DATABASE_PASSWORD},
        'the role is made with the password the file holds'
    );

    my $shape = _shape($file);
    is_deeply(
        $run->{lines},
        [
            _not_root($file),
            "$OK$file: written, $shape, with a new session secret and"
              . ' metrics token',
            "${OK}database gpforum at 127.0.0.1:5432: made, with its role"
              . ' gpforum',
            "${OK}Applied 51 migrations, 001 to 051",
            q{},
            _next_steps($file),
        ],
        'one line a step, then the next steps, reading the same file'
    );
    unlike( $run->{output} . $run->{errors},
        qr/secret-\d/msx, 'and no secret is printed' );
};

subtest 'run again, it changes nothing and says so' => sub {
    my $file   = "$directory/fresh.env";
    my $before = path($file)->slurp;
    my $run    = _setup( { file => $file, database => _database(1) }, '--yes' );
    is( $run->{status},     0,       'it succeeds' ) or diag $run->{errors};
    is( path($file)->slurp, $before, 'the file is as it was' );
    is_deeply(
        $run->{database}->made,
        [ { role_made => 0, database_made => 0 } ],
        'nothing is made'
    );
    my $shape = _shape($file);
    is_deeply(
        $run->{lines},
        [
            _not_root($file),
            "$OK$file: as it was, $shape",
            "${OK}database gpforum at 127.0.0.1:5432, as role gpforum",
            "${OK}Schema is current (051)",
            q{},
            'Nothing changed: this host was set up already.',
            q{},
            _next_steps($file),
        ],
        'each step as it was, and that nothing changed'
    );
};

subtest 'a setting the file has is replaced only with --force' => sub {
    my $file   = "$directory/fresh.env";
    my $before = path($file)->slurp;
    my $run    = _setup( { file => $file },
        '--yes', '--public-url', 'https://other.gpforum.net' );
    is( $run->{status}, $EXIT_FAILURE, 'refused' );
    is(
        $run->{errors},
        "$file has GPFORUM_PUBLIC_BASE_URL=https://$HOST, not"
          . " https://other.gpforum.net.\n"
          . 'Nothing was changed: setup replaces a setting the file has only'
          . " with --force, or when you say so at a terminal.\n",
        'naming the setting, what it is, what it would be, and --force'
    );
    is( path($file)->slurp, $before, 'nothing is written' );

    my $forced = _setup( { file => $file, database => _database(1) },
        '--yes', '--force', '--public-url', 'https://other.gpforum.net' );
    is( $forced->{status}, 0, 'with --force it succeeds' );
    my %values = _values($file);
    is( $values{GPFORUM_PUBLIC_BASE_URL},
        'https://other.gpforum.net', 'and the address is replaced' );
    is( $values{GPFORUM_MAIL_FROM},
        'forum@other.gpforum.net',
        'the sender setup derived from it following it' );
    _has(
        $forced->{output},
        "$OK$file: GPFORUM_MAIL_FROM, GPFORUM_PUBLIC_BASE_URL set, ",
        'which it names'
    );
    _has(
        $forced->{output},
        "${OK}GPFORUM_MAIL_FROM: forum\@other.gpforum.net, following the"
          . " address (it was forum\@$HOST)\n",
        'and says, with the sender it was'
    );
};

subtest 'answers setup cannot use are refused, saying why' => sub {
    for my $case (
        [
            [ '--mail', 'log' ],
            'log only writes the mail to the log, and production must'
              . ' deliver it: answer sendmail or smtp.',
            'the log in production'
        ],
        [
            [ '--mail', 'pigeon' ],
            q{'pigeon' is not sendmail, smtp HOST:PORT USER, or log.},
            'a mail it does not know'
        ],
        [
            [ '--database', 'gpforum' ],
            q{'gpforum' is neither create nor a PostgreSQL data source},
            'a database that is not a data source'
        ],
        [
            [ '--public-url', "http://$HOST" ],
            'GPFORUM_PUBLIC_BASE_URL',
            'an address production refuses, as the service would'
        ],
      )
    {
        my ( $arguments, $reason, $name ) = @{$case};
        my $file = "$directory/refused.env";
        my $run  = _setup( { file => $file }, _flags( @{$arguments} ) );
        is( $run->{status}, $EXIT_USAGE, "$name: misuse" );
        _has( $run->{errors}, $reason, "$name: saying why" );
        _has(
            $run->{errors},
            "\ngpforum help setup explains each option.\n",
            "$name: and where the options are explained"
        );
        unlike( $run->{errors}, qr/^Usage:/msx,
            "$name: not the whole usage, which buried the sentence" );
        ok( !-e $file, "$name: nothing written" );
    }

    my $development = _setup( { file => "$directory/development.env" },
        _flags( '--environment', 'development', '--mail', 'log' ) );
    is( $development->{status}, 0, 'development mails to the log' )
      or diag $development->{errors};
    is( { _values("$directory/development.env") }->{GPFORUM_ANTIVIRUS},
        'none', 'and scans nothing, its default' );

    my $unasked = _setup(
        {
            file     => "$directory/asked.env",
            terminal => GPForum::Test::SetupTerminal->new( interactive => 0 )
        }
    );
    is( $unasked->{status}, $EXIT_USAGE,
        'without a terminal, --yes is needed' );
    _has( $unasked->{errors}, 'There is no terminal to ask on:', 'and said' );
};

subtest 'the three questions, Enter taking each suggestion' => sub {
    my $file     = "$directory/asked.env";
    my $terminal = GPForum::Test::SetupTerminal->new(
        lines  => [ q{}, q{}, 'smtp mail.gpforum.net forum@gpforum.net' ],
        hidden => ['smtp-pass-word'],
    );
    my $run = _setup( { file => $file, terminal => $terminal } );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};
    is_deeply(
        $terminal->asked,
        [
            "Public address [https://$HOST]:",
            q{Database [create 'gpforum' on this host]:},
            'Mail (sendmail, smtp HOST:PORT USER, or log) [sendmail]:',
            'Password of forum@gpforum.net at mail.gpforum.net:',
        ],
        'each with its suggestion, and the SMTP password without echo'
    );
    _has(
        $run->{errors},
        "GPForum setup. Three questions; Enter accepts the suggestion.\n",
        'after a line that says how to answer'
    );
    my %values = _values($file);
    is_deeply(
        [
            @values{
                map { "GPFORUM_SMTP_$_" } qw(HOST PORT USERNAME PASSWORD)
            }
        ],
        [qw(mail.gpforum.net 587 forum@gpforum.net smtp-pass-word)],
        'the SMTP server, its port, its login and its password'
    );
    is( $values{GPFORUM_MAIL_TRANSPORT}, 'smtp', 'as the transport' );
    unlike( $run->{output}, qr/smtp-pass-word/msx, 'which is not printed' );

    my $again = GPForum::Test::SetupTerminal->new(
        lines => [ 'https://new.gpforum.net', q{}, q{} ] );
    my $typed =
      _setup( { file => $file, terminal => $again, database => _database(1) } );
    is( $typed->{status}, 0, 'asked again, it succeeds' );
    is( scalar @{ $again->asked },
        $QUESTIONS, 'an answer typed at the prompt is not asked about again' );
    %values = _values($file);
    is( $values{GPFORUM_PUBLIC_BASE_URL},
        'https://new.gpforum.net', 'it replaces what the file had' );
    is( $values{GPFORUM_MAIL_FROM},
        'forum@new.gpforum.net',
        'and the sender setup derived follows the new address' );

    my $optioned =
      GPForum::Test::SetupTerminal->new( lines => [ q{}, q{}, 'n' ] );
    my $kept = _setup(
        { file => $file, terminal => $optioned, database => _database(1) },
        '--public-url', "https://$HOST" );
    is( $kept->{status}, 0, 'given as an option at a terminal, it succeeds' );
    is(
        $optioned->asked->[-1],
        "$file has GPFORUM_PUBLIC_BASE_URL=https://new.gpforum.net. Replace it"
          . " with https://$HOST? [y/N]",
        'an option is still asked about, as Enter, --yes and --force are'
    );
    is( { _values($file) }->{GPFORUM_PUBLIC_BASE_URL},
        'https://new.gpforum.net', 'and the file kept when the answer is no' );
};

subtest 'a sender the operator wrote stays when the address changes' =>
  \&_own_sender;

subtest '--dry-run says what it would do and does nothing' => sub {
    my $file = "$directory/dry.env";
    my $run  = _setup( { file => $file }, _flags('--dry-run') );
    is( $run->{status}, 0, 'it succeeds' );
    ok( !-e $file, 'nothing is written' );
    is_deeply( $run->{database}->made, [], 'nothing is made' );
    is_deeply(
        $run->{lines},
        [
            "$OK$file: would be written, with a new session secret and"
              . ' metrics token',
            "${OK}database gpforum at 127.0.0.1:5432: would be made, with"
              . ' its role gpforum',
            "${OK}schema: the migrations, partitions and query budgets would"
              . ' be brought up to date',
            q{},
            'Nothing was changed: --dry-run says what setup would do.',
        ],
        'what it would write and make, and that nothing was changed'
    );
};

subtest 'without a superuser, the two psql commands' => sub {
    my $file   = "$directory/no-superuser.env";
    my $unmade = 'DBI connect failed: connection to server at "127.0.0.1",'
      . ' port 5432 failed: FATAL:  role "gpforum" does not exist';
    my $run = _setup(
        {
            file     => $file,
            database => GPForum::Test::SetupDatabase->new(
                superuser => undef,
                error     => $unmade
            )
        },
        _flags()
    );
    is( $run->{status}, $EXIT_FAILURE, 'it fails' );
    is_deeply(
        $run->{lines},
        [
            _not_root($file),
            "$OK$file: written, "
              . _shape($file)
              . ', with a new session secret and metrics token',
            "${FAILED}database gpforum at 127.0.0.1:5432: no PostgreSQL"
              . ' superuser answers here (you: role "you" does not exist),'
              . ' so role gpforum and its database are not made',
            '    Fix: name the superuser with PGUSER, its password in'
              . ' ~/.pgpass if it asks for one: PGUSER=postgres gpforum'
              . " --env-file $file setup",
            '         or make them as the superuser, then gpforum'
              . " --env-file $file setup again:",
            '         psql-role',
            '         psql-database',
            q{},
            '2 things to fix.',
        ],
        'what each login was told, PGUSER, the commands that make them, and'
          . ' setup again'
    );
    unlike( $run->{output}, qr/^Next:/msx, 'and no next step' );
    ok( -e $file, 'the file is written, so the commands match its password' );
};

subtest 'a role that logs in without its database: the database alone' =>
  \&_database_alone;

subtest 'what was made says which way in setup used' => \&_way_in;

subtest 'a migration that fails stops before the next steps' => sub {
    my $file = "$directory/failing.env";
    my $run  = _setup( { file => $file, migrate => 1 }, _flags() );
    is( $run->{status}, $EXIT_FAILURE, 'it fails' );
    is_deeply(
        $run->{lines},
        [
            _not_root($file),
            "$OK$file: written, "
              . _shape($file)
              . ', with a new session secret and metrics token',
            "${OK}database gpforum at 127.0.0.1:5432: made, with its role"
              . ' gpforum',
            "${FAILED}schema: the migrations did not finish, as said above",
            "    Fix: gpforum --env-file $file migrate",
            q{},
            '2 things to fix.',
        ],
        'the schema, the command, and the count'
    );
};

subtest 'the next steps run as the account only where it reads the file' =>
  sub {
    my $file = "$directory/fresh.env";
    my $mine = _setup(
        {
            file     => $file,
            database => _database(1),
            account  => GPForum::Test::SetupAccount->new(
                exists => 1,
                given  => [ $EFFECTIVE_USER_ID + 1, $NO_GROUP ]
            ),
        },
        '--yes'
    );
    is_deeply(
        [ ( reverse @{ $mine->{lines} } )[ 1, 0 ] ],
        [ ( _next_steps($file) )[ 1, 2 ] ],
        'a file the account cannot read: as the operator, whose file it is'
    );

    my $its = _setup(
        {
            file     => $file,
            database => _database(1),
            account  => GPForum::Test::SetupAccount->new( exists => 1 ),
        },
        '--yes'
    );
    is_deeply(
        [ ( reverse @{ $its->{lines} } )[ 1, 0 ] ],
        [ ( _next_steps( $file, 'sudo -u gpforum ' ) )[ 1, 2 ] ],
        q{the file its group's: as the services' account}
    );
  };

subtest 'text is written as UTF-8, as the service reads the file' => sub {
    my $file    = "$directory/utf8.env";
    my $address = "https://for\N{LATIN SMALL LETTER U WITH GRAVE}m.gpforum.net";
    my $password = "p\N{LATIN SMALL LETTER A WITH DIAERESIS}ss-word";
    my $typed    = GPForum::Test::SetupTerminal->new(
        lines  => [ $address, q{}, 'smtp mail.gpforum.net forum' ],
        hidden => [ encode( 'UTF-8', $password ) ],
    );
    my $run = _setup( { file => $file, terminal => $typed } );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};
    ok( defined decode( 'UTF-8', path($file)->slurp ), 'the file is UTF-8' );
    my %typed = _values_utf8($file);
    is( $typed{GPFORUM_PUBLIC_BASE_URL}, $address, 'the address typed' );
    is( $typed{GPFORUM_SMTP_PASSWORD},
        $password, 'the password typed without echo' );

    my $piped = "$directory/piped.env";
    my $input = _input( encode( 'UTF-8', "$password\n" ) );
    my $given = _setup(
        {
            file     => $piped,
            input    => $input,
            terminal => GPForum::Test::SetupTerminal->new( interactive => 0 ),
        },
        _flags(
            '--public-url', encode( 'UTF-8', $address ),
            '--mail',       'smtp mail.gpforum.net forum',
            '--smtp-password-stdin'
        )
    );
    is( $given->{status}, 0, 'given as options and on standard input' )
      or diag $given->{errors};
    my %piped = _values_utf8($piped);
    is( $piped{GPFORUM_PUBLIC_BASE_URL}, $address,  'the address, as UTF-8' );
    is( $piped{GPFORUM_SMTP_PASSWORD},   $password, 'the password, as UTF-8' );

    my $terminal = GPForum::Test::SetupTerminal->new(
        lines  => [ q{}, q{}, 'smtp mail.gpforum.net other', 'y', 'y' ],
        hidden => ['hidden-pass-word'],
    );
    my $asked = _setup(
        { file => $piped, terminal => $terminal, database => _database(1) },
        '--smtp-password-stdin' );
    is( $asked->{status}, 0, 'at a terminal, with --smtp-password-stdin' )
      or diag $asked->{errors};
    is( { _values_utf8($piped) }->{GPFORUM_SMTP_PASSWORD},
        'hidden-pass-word', 'the password is still asked without echo' );
};

subtest 'a server that does not answer is said, and makes no password' => sub {
    my $file = "$directory/down.env";
    my $refused =
        q{DBI connect('dbname=gpforum;host=127.0.0.1;port=5432',}
      . q{'gpforum',...) failed: connection to server at "127.0.0.1", port}
      . ' 5432 failed: Connection refused';
    my $down = sub {
        return GPForum::Test::SetupDatabase->new(
            superuser => undef,
            error     => $refused,
        );
    };
    my $dry =
      _setup( { file => $file, database => $down->() }, _flags('--dry-run') );
    is( $dry->{status}, 0, 'a dry run succeeds' );
    _has(
        $dry->{lines}[1],
        '! database: cannot reach PostgreSQL at 127.0.0.1:5432 (connection'
          . ' refused)',
        'saying the server does not answer, as the run would, under the'
          . q{ label doctor's line has}
    );
    unlike( $dry->{output}, qr/psql/msx, 'not that it would print psql' );

    my $run = _setup( { file => $file, database => $down->() }, _flags() );
    is( $run->{status}, $EXIT_FAILURE, 'the run fails' );
    _has( $run->{output},
        "${FAILED}database: cannot reach PostgreSQL at 127.0.0.1:5432",
        'and says why' );
    is( { _values($file) }->{GPFORUM_DATABASE_PASSWORD},
        q{}, 'with no password made for a role nobody was told to make' );
};

subtest 'in Italian, and as JSON' => sub {
    my $file = "$directory/fresh.env";
    my $italian =
      _setup( { file => $file, database => _database(1), language => 'it' },
        '--yes' );
    _has(
        $italian->{output},
        "\nNon \N{LATIN SMALL LETTER E WITH GRAVE} cambiato nulla: questo host"
          . " era gi\N{LATIN SMALL LETTER A WITH GRAVE} installato.\n",
        'Italian, as LC_ALL asks'
    );
    _has(
        $italian->{output},
        "\nPoi: controlla tutto il forum, con ",
        'its next steps too'
    );

    my $json =
      _setup( { file => $file, database => _database(1) }, '--yes', '--json' );
    my $document = decode_json( encode( 'UTF-8', $json->{output} ) );
    is( $document->{status}, 'degraded',
        'one JSON object, the warning about root its status' );
    is( $document->{changed}, 0, 'nothing changed' );
    is_deeply(
        [ map { $_->{name} } @{ $document->{findings} } ],
        [qw(account file database schema)],
        'a finding for each step'
    );
};

done_testing();

# What a production install run by another account than root says first.
sub _not_root ($file) {
    return (
        "! not run as root: $file is yours, and the services' account"
          . ' gpforum is not made',
        "    Fix: sudo gpforum --env-file $file setup",
    );
}

# The next steps, run as the operator who ran setup -- whose file it is,
# with no services' account here -- or as the one given.
sub _next_steps ( $file, $as = q{} ) {
    return (
        q{Next: make the forum's owner, with }
          . "${as}gpforum --env-file $file admin create --email EMAIL"
          . ' --username NAME',
        _services_step($file),
        "Then: check the whole forum, with ${as}gpforum --env-file $file"
          . ' doctor',
    );
}

# The services, with gpforum service print where that verb is there (ADR
# 0123): its own first step on this host, the files written with --to, for
# the file setup wrote -- not a bare print, which wrote every unit to the
# terminal first.
sub _services_step ($file) {
    my $verb = GPForum::Command::Support::Verbs->find('service');
    return 'Then: install and start the services, as docs/DEPLOYMENT.md shows'
      if !$verb || load_class("GPForum::CLI::$verb->{command}");

    my $files = GPForum::Service::Operations::ServiceFiles->new(
        host => GPForum::Service::Operations::Host->new(
            os               => GPForum::OS->from_name('linux'),
            environment_file => $file,
        ),
        environment_file => $file,
    );
    my ($print) = grep { /gpforum [ ] service [ ] print/msx }
      @{ $files->steps( 'systemd', start => 1 ) };
    like( $print, qr/[ ] --to [ ]/msx, 'service print offered with --to' );

    return 'Then: install and start the services, with '
      . ( $print =~ s/\b gpforum [ ]/gpforum --env-file $file /rmsx );
}

sub _decided {
    return qw(GPFORUM_ENV GPFORUM_PUBLIC_BASE_URL GPFORUM_MAIL_FROM
      GPFORUM_MAIL_TRANSPORT GPFORUM_ANTIVIRUS GPFORUM_DATABASE_USER
      GPFORUM_DATABASE_DSN);
}

# The options of a production install, every answer given.
sub _flags (@more) {
    return ( '--yes', '--public-url', "https://$HOST", '--database',
        'create', '--mail', 'sendmail', @more );
}

sub _database ($held) {
    return GPForum::Test::SetupDatabase->new(
        role     => $held,
        database => $held,
    );
}

# Runs setup with stand-ins for what reaches beyond the file, and returns
# its status, what it printed (as lines too) and the stand-in database.
sub _setup ( $given, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $database = $given->{database} // GPForum::Test::SetupDatabase->new;
    my $setup    = GPForum::Command::Setup->new(
        catalog => GPForum::Service::I18N::CliCatalog->new(
            language => $given->{language} // 'en'
        ),
        os            => GPForum::OS->from_name('linux'),
        effective_uid => $NOT_ROOT,
        host_name     => $HOST,
        terminal => $given->{terminal} // GPForum::Test::SetupTerminal->new,
        account  => $given->{account}  // GPForum::Test::SetupAccount->new,
        database => $database,
        defined $given->{input} ? ( input => $given->{input} ) : (),
        generate => sub { return 'secret-' . ++$secrets . $LONG; },
        migrate  => sub ($self) {
            return { status => 1 } if $given->{migrate};
            return { status => 0, summary => 'Schema is current (051)' }
              if $migrated{ $given->{file} }++;
            return {
                status  => 0,
                summary => 'Applied 51 migrations, 001 to 051',
                changed => 1,
            };
        },
        owner_check => sub ($self) { return 0; },
        output      => _handle( \$output ),
        prompt      => _handle( \$errors ),
    );

    my $status = _with_stderr( \$errors,
        sub { return $setup->run( '--env-file', $given->{file}, @arguments ) }
    );
    $output = decode( 'UTF-8', $output );

    return {
        status   => $status,
        output   => $output,
        lines    => [ split /\n/msx, $output ],
        errors   => decode( 'UTF-8', $errors ),
        database => $database,
    };
}

sub _with_stderr ( $errors, $code ) {
    local *STDERR = _handle($errors);

    return $code->();
}

sub _handle ($text) {
    open my $handle, '>>', $text or croak "output: $OS_ERROR";

    return $handle;
}

# The lines of the first failure: its sentence and its fixes.
sub _failure_lines ($lines) {
    my ($start) = grep { index( $lines->[$_], $FAILED ) == 0 } 0 .. $#{$lines};
    return () if !defined $start;
    my ($end) = grep { $lines->[$_] eq q{} } $start .. $#{$lines};

    return @{$lines}[ $start .. ( $end // scalar @{$lines} ) - 1 ];
}

sub _values ($file) {
    return %{ $EDIT->values_of( [ split /^/msx, path($file)->slurp ] ) };
}

# Standard input holding the text given.
sub _input ($text) {
    open my $handle, '<', \$text or croak "input: $OS_ERROR";

    return $handle;
}

sub _values_utf8 ($file) {
    return %{
        $EDIT->values_of(
            [ split /^/msx, decode( 'UTF-8', path($file)->slurp ) ]
        )
    };
}

# The file's mode, owner and group as setup says them.
sub _shape ($file) {
    my @stat = stat $file;

    return sprintf '%04o %s:%s', $stat[$STAT_MODE] & $MODE_BITS,
      scalar getpwuid $stat[$STAT_UID], scalar getgrgid $stat[$STAT_GID];
}

sub _has ( $text, $fragment, $name ) {
    ok( index( $text, $fragment ) >= 0, $name )
      or diag "looked for: $fragment\nin: $text";

    return;
}

sub _database_alone {
    my $file    = "$directory/no-database.env";
    my $missing = 'DBI connect failed: connection to server at "127.0.0.1",'
      . ' port 5432 failed: FATAL:  database "gpforum" does not exist';
    my $run = _setup(
        {
            file     => $file,
            database => GPForum::Test::SetupDatabase->new(
                superuser => undef,
                error     => $missing,
                tried     => [
                    {
                        as     => 'postgres',
                        from   => 'GPFORUM_DATABASE_USER',
                        reason => 'fe_sendauth: no password supplied',
                    }
                ],
            )
        },
        _flags()
    );
    is( $run->{status}, $EXIT_FAILURE, 'it fails' );
    is_deeply(
        [ _failure_lines( $run->{lines} ) ],
        [
            "${FAILED}database gpforum at 127.0.0.1:5432: no PostgreSQL"
              . ' superuser answers here (postgres, from'
              . ' GPFORUM_DATABASE_USER: fe_sendauth: no password supplied),'
              . ' so the database of role gpforum is not made',
            '    Fix: name the superuser with PGUSER, its password in'
              . ' ~/.pgpass if it asks for one: PGUSER=postgres gpforum'
              . " --env-file $file setup",
            '         or make it as the superuser, then gpforum'
              . " --env-file $file setup again:",
            '         psql-database',
        ],
        'no CREATE ROLE for the role the server has, which would fail with'
          . ' "already exists"'
    );
    my %values = _values($file);
    is( $values{GPFORUM_DATABASE_PASSWORD} // q{},
        q{}, 'and no new password, which would lock that role out' );

    return;
}

sub _way_in {
    my $file = "$directory/way-in.env";
    my $run  = _setup(
        {
            file     => $file,
            database => GPForum::Test::SetupDatabase->new(
                superuser => 'given',
                as        => 'postgres',
                from      => 'GPFORUM_DATABASE_USER',
            )
        },
        _flags()
    );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};
    ok(
        (
            grep {
                $_ eq "${OK}database gpforum at 127.0.0.1:5432: made, with its"
                  . q{ role gpforum, as PostgreSQL's superuser postgres, from}
                  . ' GPFORUM_DATABASE_USER'
            } @{ $run->{lines} }
        ),
        'the login the shell gave, named'
    ) or diag explain $run->{lines};

    return;
}

sub _own_sender {
    my $file = "$directory/own-sender.env";
    path($file)
      ->spew( "GPFORUM_PUBLIC_BASE_URL=https://$HOST\n"
          . "GPFORUM_MAIL_FROM=news\@gpforum.net\n" );
    my $run = _setup( { file => $file },
        _flags( '--force', '--public-url', 'https://other.gpforum.net' ) );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};
    is( { _values($file) }->{GPFORUM_MAIL_FROM},
        'news@gpforum.net', 'the sender is kept' );
    unlike(
        $run->{output},
        qr/following [ ] the [ ] address/msx,
        'and nothing is said of it'
    );

    return;
}

1;
