# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Digest::SHA  qw(hmac_sha256);
use MIME::Base64 qw(decode_base64 encode_base64);
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::Service::Operations::DatabaseProvisioning;

our $VERSION = '0.001';

const my $ITERATIONS   => 4_096;
const my $SECRET_CHARS => 64;

# gpforum setup makes the forum's role and database as PostgreSQL's
# superuser, or prints the two psql commands that do. The role's password
# reaches the server, and the operator's screen, only as its SCRAM-SHA-256
# verifier.

my $class = 'GPForum::Service::Operations::DatabaseProvisioning';

subtest 'a data source is read as libpq reads it' => sub {
    is_deeply(
        $class->data_source('dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432'),
        { database => 'gpforum', host => '127.0.0.1', port => 5432 },
        'the template'
    );
    is_deeply(
        $class->data_source('dbi:Pg:database=forum'),
        { database => 'forum', host => q{}, port => 5432 },
        'the default socket and port'
    );
    is( $class->data_source('dbi:SQLite:dbname=x'),
        undef, 'and nothing but PostgreSQL' );
    is(
        $class->server_name(
            $class->data_source('dbi:Pg:dbname=x;port=55433')
        ),
        'localhost:55433',
        'its server, as an operator reads it'
    );
    ok( $class->is_local( $class->data_source('dbi:Pg:dbname=x;host=::1') ),
        'the loopback is this host' );
    ok( $class->is_local( $class->data_source('dbi:Pg:dbname=x;host=/tmp') ),
        'and so is a socket directory' );
    ok(
        !$class->is_local(
            $class->data_source('dbi:Pg:dbname=x;host=db.internal')
        ),
        'another host is not'
    );
};

# RFC 7677's example: user "user", password "pencil". The verifier's
# ServerKey must sign the exchange's AuthMessage as the RFC's server did.
subtest 'the password is sent as its SCRAM-SHA-256 verifier' => sub {
    my $salt     = decode_base64('W22ZaJ0SNY7soEsUEjb6gQ==');
    my $verifier = $class->scram_verifier( 'pencil', salt => $salt );
    my ( $iterations, $salt_text, $stored, $server ) =
      $verifier =~
      m{\A SCRAM-SHA-256 \$ (\d+) : ([^\$]+) \$ ([^:]+) : (.+) \z}msx;
    is( $iterations, $ITERATIONS,                q{PostgreSQL's iterations} );
    is( $salt_text,  'W22ZaJ0SNY7soEsUEjb6gQ==', 'the salt, in base64' );
    my $client_nonce   = 'rOprNGfwEbeRWgbNEkqO';
    my $nonce          = $client_nonce . '%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0';
    my $authentication = join q{,}, "n=user,r=$client_nonce", "r=$nonce",
      's=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096', "c=biws,r=$nonce";
    is(
        encode_base64(
            hmac_sha256( $authentication, decode_base64($server) ), q{}
        ),
        '6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=',
        q{its ServerKey signs RFC 7677's exchange as the RFC's server did}
    );
    is(
        $stored,
        'WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=',
        q{and its StoredKey is the one Python's hashlib gives}
    );

    isnt(
        $class->scram_verifier('pencil'),
        $class->scram_verifier('pencil'),
        'a new salt each time'
    );
};

subtest 'the login the data source or the environment gives' => sub {
    is_deeply(
        $class->data_source(
            'dbi:Pg:dbname=gpforum;host=db;user=postgres;password=s3cret'),
        {
            database => 'gpforum',
            host     => 'db',
            port     => 5432,
            user     => 'postgres',
            password => 's3cret',
        },
        q{a data source's own user and password are read}
    );
    is_deeply(
        $class->logins_of(
            {
                GPFORUM_DATABASE_USER     => 'postgres',
                GPFORUM_DATABASE_PASSWORD => 'postgres',
            }
        ),
        [
            {
                user     => 'postgres',
                password => 'postgres',
                from     => 'GPFORUM_DATABASE_USER',
            }
        ],
        q{and the environment's GPFORUM_DATABASE_USER, as a CI runner sets it}
    );
    is_deeply( $class->logins_of( {} ), [], 'none when it sets no user' );

    local $ENV{PGUSER} = 'nobody_libpq';
    my $none = $class->new(
        effective_uid     => 1_000,
        superuser_account => undef,
        given_logins      => $class->logins_of(
            {
                GPFORUM_DATABASE_USER     => 'postgres',
                GPFORUM_DATABASE_PASSWORD => 'postgres',
            }
        ),
    )->inspect(
        dsn  => 'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=1;user=admin',
        user => 'gpforum',
    );
    is( $none->{superuser}, undef, 'nobody answers on a closed port' );
    is_deeply(
        [ map { [ $_->{as}, $_->{from} // q{} ] } @{ $none->{tried} } ],
        [
            [ 'nobody_libpq', q{} ],
            [ 'admin',        'GPFORUM_DATABASE_DSN' ],
            [ 'postgres',     'GPFORUM_DATABASE_USER' ],
        ],
        q{libpq's own login, then the data source's, then the environment's}
    );
    unlike(
        join( q{ }, map { $_->{reason} } @{ $none->{tried} } ),
        qr/DBI \s connect | \s at \s \S+ \s line \s/msx,
        q{each said in libpq's words, without DBI's around them}
    );
};

subtest q{libpq's reason, as an operator reads it} => sub {
    is(
        $class->reason_of(
            q{DBI connect('dbname=postgres;host=127.0.0.1;port=5432','',...)}
              . ' failed: connection to server at "127.0.0.1", port 5432'
              . ' failed: fe_sendauth: no password supplied at lib/X.pm line 9.'
        ),
        'fe_sendauth: no password supplied',
        'a password the server asks for and was not given'
    );
    is(
        $class->reason_of(
                q{DBI connect(...) failed: connection to server at}
              . ' "127.0.0.1", port 55433 failed: FATAL:  role "you" does not'
              . " exist at lib/X.pm line 3.\n"
        ),
        'role "you" does not exist',
        'a role the server does not have'
    );
    is(
        $class->reason_of('role gpforum is not a superuser'),
        'role gpforum is not a superuser',
        'and its own words as they are'
    );
};

subtest 'the two psql commands, for a host where none answers' => sub {
    my $password = 'a' x $SECRET_CHARS;
    my %target   = (
        dsn      => 'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432',
        user     => 'gpforum',
        password => $password,
    );
    my $debian =
      $class->new( os => GPForum::OS->from_name('linux') )->commands(%target);
    is( scalar @{$debian}, 2, 'two' );
    is(
        index(
            $debian->[0],
            q{sudo -u postgres psql -c "CREATE ROLE gpforum LOGIN PASSWORD }
              . q{'SCRAM-SHA-256\$4096:}
        ),
        0,
q{the role, as Debian's superuser, its verifier's $ escaped for the shell}
    );
    is(
        $debian->[1],
        'sudo -u postgres psql -c "CREATE DATABASE gpforum OWNER gpforum"',
        'then the database it owns'
    );
    unlike( "@{$debian}", qr/$password/msx, 'and never the password' );
    is_deeply(
        $class->new( os => GPForum::OS->from_name('linux') )
          ->commands( %target, role_exists => 1 ),
        ['sudo -u postgres psql -c "CREATE DATABASE gpforum OWNER gpforum"'],
        'for a role the server has, the database alone'
    );

    my $elsewhere =
      $class->new( os => GPForum::OS->from_name('darwin') )->commands(
        %target,
        dsn  => 'dbi:Pg:dbname=my forum;host=db.internal;port=6432',
        user => 'Forum',
      );
    is(
        $elsewhere->[1],
        q{psql -d postgres -h db.internal -p 6432 -c }
          . q{"CREATE DATABASE \"my forum\" OWNER \"Forum\""},
        'another host and port named, and a name that needs it quoted'
    );

    my $socket =
      $class->new( os => GPForum::OS->from_name('linux') )
      ->commands( %target,
        dsn => 'dbi:Pg:dbname=gpforum;host=/srv/pg sockets;port=5432', );
    is(
        $socket->[1],
        q{sudo -u postgres psql -h '/srv/pg sockets' -c }
          . q{"CREATE DATABASE gpforum OWNER gpforum"},
        'a socket directory named, quoted for the shell: psql looks in its'
          . q{ package's own}
    );
};

subtest 'only root becomes the server account, and only on this host' => sub {
    my $unreached = $class->new(
        effective_uid     => 1_000,
        superuser_account => {
            account => 'postgres',
            role    => 'postgres',
            sockets => ['/nonexistent'],
        },
    )->inspect(
        dsn  => 'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=1',
        user => 'gpforum',
    );
    is( $unreached->{superuser}, undef, 'nobody answers on a closed port' );
    like( $unreached->{error}, qr/\S/msx, 'and it says why' );
};

done_testing();

1;
