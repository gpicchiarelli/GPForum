# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use DBI;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::Util qw(decode);
use Test::More;

use lib 'lib';

use GPForum::Command::Setup;
use GPForum::Command::Support::EnvironmentFileEdit;
use GPForum::Migration::Plan;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::DatabaseProvisioning;

our $VERSION = '0.001';

const my $NAME => "gpforum_setup_$PROCESS_ID";
const my $HOST => 'forum.gpforum.net';

# Who setup runs as: never root, whoever runs the test -- a CI container's
# root among them -- so the services' account is never made here, and setup
# says so as it does to any operator without root.
const my $NOT_ROOT => $EFFECTIVE_USER_ID || 65_534;

# The assertions about the socket, skipped where the server has none.
const my $SOCKET_TESTS => 4;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the setup test';
}

# C1 on a real PostgreSQL: gpforum setup, given a server whose superuser
# answers, makes a role of its own -- its password stored as a SCRAM
# verifier -- and a database it owns, writes the file the service reads,
# applies the migrations and syncs the budgets; run again, it changes
# nothing. Root's way in, as the server's own account over the local socket,
# is run as this account. The role and the databases are dropped at the end.

my $source = GPForum::Service::Operations::DatabaseProvisioning->data_source(
    $ENV{GPFORUM_DATABASE_DSN} );
my $server = "host=$source->{host};port=$source->{port}";

# The login the workflow gives, GPFORUM_DATABASE_USER and its password: the
# CI runner's postgres takes only a password over TCP and has no socket here.
my $given    = $ENV{GPFORUM_DATABASE_USER}     // q{};
my $password = $ENV{GPFORUM_DATABASE_PASSWORD} // q{};
my ( $admin, $superuser, $is_superuser ) = _admin();
my $migrations = scalar @{ GPForum::Migration::Plan->new->summary };
my $directory  = tempdir( CLEANUP => 1 );
my $file       = "$directory/gpforum.env";

subtest 'a fresh install, as a superuser who answers' => sub {
    if ( !$is_superuser ) {
        plan skip_all => "$superuser is not a superuser on $server, so no"
          . ' superuser is reachable for setup to make a role with: set'
          . ' GPFORUM_DATABASE_USER and GPFORUM_DATABASE_PASSWORD to one';
    }

    # libpq's own login is made to fail when the workflow gives one, so the
    # given login is the way in, as on the CI runner; else it is libpq's.
    local $ENV{PGUSER} = length $given ? 'no_such_role_setup' : $ENV{PGUSER};
    my $way =
      length $given
      ? "as PostgreSQL's superuser $superuser, from GPFORUM_DATABASE_USER"
      : "as PostgreSQL's superuser $superuser";

    my $first = _setup();
    is( $first->{status}, 0, 'it succeeds' ) or diag $first->{errors};
    _has(
        $first->{output},
        "! not run as root: $file is yours, and the services' account"
          . " gpforum is not made\n",
        'not run as root, it says what root would have made'
    );
    _has(
        $first->{output},
        "\N{CHECK MARK} database $NAME at $source->{host}:$source->{port}:"
          . " made, with its role $NAME, $way\n",
        'the database and its role, made, and the way in it used'
    );
    _has(
        $first->{output},
        "\N{CHECK MARK} Applied $migrations migrations, 001 to ",
        'the migrations applied'
    );
    _has(
        $first->{output},
        '; synced the query budgets (',
        'and the budgets synced'
    );
    _has(
        $first->{output},
        q{Next: make the forum's owner},
        'and the owner the new forum lacks, next'
    );

    my %values = _values();
    is( $values{GPFORUM_DATABASE_DSN},
        "dbi:Pg:dbname=$NAME;$server", 'the file names the database' );
    like(
        $values{GPFORUM_DATABASE_PASSWORD},
        qr/\A [[:xdigit:]]{64} \z/msx,
        'and holds a new password'
    );
    unlike(
        $first->{output},
        qr/\Q$values{GPFORUM_DATABASE_PASSWORD}\E/msx,
        'which is not printed'
    );

    my ($verifier) =
      $admin->selectrow_array(
        'SELECT rolpassword FROM pg_authid WHERE rolname = ?',
        undef, $NAME );
    like(
        $verifier,
        qr/\A SCRAM-SHA-256 \$ 4096 : /msx,
        'the server holds its SCRAM verifier, not the password'
    );
    my ($owner) = $admin->selectrow_array(
        'SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = ?',
        undef, $NAME );
    is( $owner, $NAME, 'the role owns the database' );

    my $forum = DBI->connect(
        "dbi:Pg:dbname=$NAME;$server", $NAME,
        $values{GPFORUM_DATABASE_PASSWORD},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 }
    );
    my ($applied) =
      $forum->selectrow_array('SELECT count(*) FROM schema_versions');
    is( $applied, $migrations, 'every migration is applied' );
    my ($budgets) =
      $forum->selectrow_array('SELECT count(*) FROM endpoint_query_budgets');
    ok( $budgets, 'and the query budgets written' );
    $forum->disconnect;

    my $before = path($file)->slurp;
    my $again  = _setup();
    is( $again->{status}, 0, 'run again, it succeeds' )
      or diag $again->{errors};
    is( path($file)->slurp, $before, 'the file as it was' );
    _has(
        $again->{output},
        "\N{CHECK MARK} Schema is current (",
        'the schema current'
    );
    _has(
        $again->{output},
        "\nNothing changed: this host was set up already.\n",
        'and nothing changed'
    );
};

subtest q{root's way in: the server's account, over its socket} => sub {
    if ( !$is_superuser ) {
        plan skip_all => "$superuser is not a superuser on $server";
    }
    my ($sockets) = $admin->selectrow_array('SHOW unix_socket_directories');
    my ($socket)  = grep { -S "$_/.s.PGSQL.$source->{port}" }
      split /\s*,\s*/msx, $sockets // q{};
  SKIP: {
        if ( !defined $socket ) {
            skip 'the server has no socket here', $SOCKET_TESTS;
        }

        # The libpq default fails, so only the account can answer.
        local $ENV{PGUSER} = 'no_such_role_setup';
        my $account  = getpwuid $EFFECTIVE_USER_ID;
        my $database = GPForum::Service::Operations::DatabaseProvisioning->new(
            effective_uid     => 0,
            given_logins      => [],
            superuser_account => {
                account => $account,
                role    => $superuser,
                sockets => [ '/nonexistent', $socket ],
            },
        );
        my %target = (
            dsn      => "dbi:Pg:dbname=${NAME}_b;$server",
            user     => $NAME,
            password => 'unused',
        );
        my $held = $database->inspect(%target);
        is( $held->{superuser}, $account,
            'the account answers, from a child process' );
        is_deeply(
            [ @{$held}{qw(role database)} ],
            [ 1, 0 ],
            'the role is there and the second database is not'
        );
        my $made = $database->provision(%target);
        is_deeply(
            [ @{$made}{qw(role_made database_made)} ],
            [ 0, 1 ],
            'the database is made, the role left as it was'
        );
        my ($owner) = $admin->selectrow_array(
            'SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = ?',
            undef, "${NAME}_b"
        );
        is( $owner, $NAME, 'owned by the role' );
    }
};

subtest 'under sudo, the operator who typed it, as on Homebrew' => sub {
    if ( !$is_superuser ) {
        plan skip_all => "$superuser is not a superuser on $server";
    }
    local $ENV{PGUSER}     = 'no_such_role_setup';
    local $ENV{PGPASSWORD} = $password;
    my $held = GPForum::Service::Operations::DatabaseProvisioning->new(
        effective_uid     => 0,
        sudo_user         => $superuser,
        given_logins      => [],
        superuser_account => undef,
    )->inspect(
        dsn  => "dbi:Pg:dbname=$NAME;$server",
        user => $NAME,
    );
    is( $held->{superuser}, 'you',
        q{root's own role fails, and the operator's answers} );
};

_drop();
is(
    $admin->selectrow_array(
        q{SELECT count(*) FROM pg_roles WHERE rolname = ?},
        undef, $NAME
    ),
    0,
    'the role and the databases are dropped'
);
$admin->disconnect;

done_testing();

# The server's own database, as the login the workflow gives: who it is,
# and whether it is a superuser. Every test is skipped when it cannot log in.
sub _admin {
    my $handle = DBI->connect( "dbi:Pg:dbname=postgres;$server",
        $given, $password,
        { AutoCommit => 1, PrintError => 0, RaiseError => 0 } );
    if ( !$handle ) {
        plan skip_all => "cannot connect to $server as '$given': $DBI::errstr";
    }
    $handle->{RaiseError} = 1;
    my ( $name, $super ) = $handle->selectrow_array(
'SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user'
    );

    return ( $handle, $name, $super );
}

# What the test made, which only a superuser makes, dropped as one.
sub _drop {
    return if !$is_superuser;
    for my $database ( $NAME, "${NAME}_b" ) {
        $admin->do( 'DROP DATABASE IF EXISTS '
              . $admin->quote_identifier($database)
              . ' WITH (FORCE)' );
    }
    $admin->do( 'DROP ROLE IF EXISTS ' . $admin->quote_identifier($NAME) );

    return;
}

sub _setup {
    my ( $output, $errors ) = ( q{}, q{} );
    my $setup = GPForum::Command::Setup->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
        host_name     => $HOST,
        effective_uid => $NOT_ROOT,
        output        => _handle( \$output ),
        prompt        => _handle( \$errors ),
    );
    my $status = _with_stderr(
        \$errors,
        sub {
            return $setup->run(
                '--yes',                       '--env-file',
                $file,                         '--public-url',
                "https://$HOST",               '--database',
                "dbi:Pg:dbname=$NAME;$server", '--database-user',
                $NAME,                         '--mail',
                'sendmail',
            );
        }
    );

    return {
        status => $status,
        output => decode( 'UTF-8', $output ),
        errors => decode( 'UTF-8', $errors ),
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

sub _values {
    return %{ GPForum::Command::Support::EnvironmentFileEdit->values_of(
            [ split /^/msx, path($file)->slurp ]
        )
    };
}

sub _has ( $text, $fragment, $name ) {
    ok( index( $text, $fragment ) >= 0, $name )
      or diag "looked for: $fragment\nin: $text";

    return;
}

1;
