# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $INSERT_SQL => join q{ },
  'INSERT INTO dead_letters (dead_letter_id, source_table, source_id,',
  'error_class, error_message, retry_count)',
  q{VALUES (gen_random_uuid(), 'probe', gen_random_uuid(), 'probe', ?, 0)};

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the command failure test';
}

# Every workflow that runs under a command id catches its store's exception
# and returns 'failed' from inside the command's transaction. Committing that
# kept what the store wrote before it failed -- when PostgreSQL survives the
# failure: inside a savepoint, or not a database error at all -- and stored
# 'failed' as the command id's answer, so retrying the command could never
# succeed. A failed command must leave nothing behind.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my $idempotency =
  GPForum::Service::Operations::CommandIdempotency->new( schema => $schema );

# A write, then a failure PostgreSQL survives -- a Perl exception the guarded
# code catches, as every workflow's store wrapper does.
my $first = _run(
    'command-1',
    sub {
        $dbh->do( $INSERT_SQL, undef, 'written before the failure' );
        my $caught = eval { croak 'mail transport down'; };
        return { status => 'failed', error => 'store failed' };
    }
);
is( $first->{result}{status}, 'failed', 'the failure reaches the caller' );
is( _rows('written before the failure'),
    0, 'and what the command wrote before it failed is rolled back' );
is( _commands('command-1'), 0, 'and no answer is stored for its command id' );

# A write, then a database error inside a savepoint, which leaves the
# transaction usable -- the shape of a lock or statement timeout caught by
# UniqueConflict->attempt.
my $savepoint = _run(
    'command-2',
    sub {
        $dbh->do( $INSERT_SQL, undef, 'written before the savepoint' );
        my ( undef, $error ) =
          GPForum::Infrastructure::UniqueConflict->attempt( $schema,
            sub { return $dbh->selectrow_array('SELECT 1 / 0') } );
        return { status => 'failed', error => "store failed: $error" };
    }
);
is( $savepoint->{result}{status}, 'failed', 'a savepoint failure fails' );
is( _rows('written before the savepoint'),
    0, 'and is rolled back with everything before it' );

# The same command id, retried after the cause went away, runs and succeeds.
my $retry = _run(
    'command-1',
    sub {
        $dbh->do( $INSERT_SQL, undef, 'written by the retry' );
        return { status => 'ok' };
    }
);
ok( !$retry->{replayed}, 'the retry runs instead of replaying the failure' );
is( $retry->{result}{status},      'ok', 'and succeeds' );
is( _rows('written by the retry'), 1,    'its write is kept' );
is( _commands('command-1'),        1,    'and its answer is stored' );

my $replayed = _run( 'command-1', sub { croak 'must not run again' } );
ok( $replayed->{replayed}, 'a succeeded command still replays its answer' );

$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _run {
    my ( $command_id, $code ) = @_;

    return $idempotency->run(
        {
            actor_id     => undef,
            command_id   => $command_id,
            command_type => 'probe.command',
            request      => { probe => 1 },
        },
        $code,
        sub { return $_[0] },
    );
}

sub _rows {
    my ($message) = @_;

    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM dead_letters WHERE error_message = ?',
        undef, $message );
}

sub _commands {
    my ($key) = @_;

    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM command_log WHERE idempotency_key = ?',
        undef, $key );
}

1;
