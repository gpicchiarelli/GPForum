# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::ScheduledJobs;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $EXPIRED_BUCKETS => 3;
const my $BUCKET_SQL => join q{ },
  'INSERT INTO rate_limit_buckets',
  '(scope, actor_hash, action, window_started_at, window_seconds, expires_at)',
  q{VALUES ('ip', ?, 'post.create', now() - interval '2 hours', 60, ?)};
const my $SESSION_SQL => join q{ },
  'INSERT INTO sessions (session_id, user_id, session_hash, created_at,',
  'expires_at) SELECT gen_random_uuid(), id, ?,',
  q{now() - interval '2 days', ? FROM users ORDER BY username LIMIT 1};

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the retention test';
}

local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the small seed profile loads' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my $jobs =
  GPForum::Service::Operations::ScheduledJobs->new( schema => $schema );

# Every retention job asked its resultset for candidates through a helper
# that returned DBIx::Class's search to a caller in list context, so the purge
# received rows where it expected a resultset. No test had ever run a purge
# against PostgreSQL; the doubles return the same object in any context.
#
# First with nothing due: every job must report success and delete nothing.
my $idle = $jobs->run(
    {
        jobs => [
            qw(sessions identity_tokens rate_limit_buckets outbox_messages dead_letters)
        ]
    }
);
for my $name (
    qw(sessions identity_tokens rate_limit_buckets outbox_messages dead_letters)
  )
{
    is( $idle->{$name}{ok},
        1, "$name runs against PostgreSQL with nothing due" )
      or diag explain $idle->{$name};
}

# Then with rows on both sides of the line.
for my $index ( 1 .. $EXPIRED_BUCKETS ) {
    $dbh->do( $BUCKET_SQL, undef, "expired-$index",
        _offset( $dbh, '-1 hour' ) );
}
$dbh->do( $BUCKET_SQL,  undef, 'current',         _offset( $dbh, '1 hour' ) );
$dbh->do( $SESSION_SQL, undef, 'expired-session', _offset( $dbh, '-1 hour' ) );
$dbh->do( $SESSION_SQL, undef, 'current-session', _offset( $dbh, '1 day' ) );

my $due = $jobs->run( { jobs => [qw(rate_limit_buckets sessions)] } );
is( $due->{rate_limit_buckets}{deleted},
    $EXPIRED_BUCKETS, 'every expired rate-limit window is purged' );
is( _count( $dbh, 'rate_limit_buckets' ), 1, 'and the current window is kept' );
is( $due->{sessions}{deleted},            1, 'the expired session is purged' );
is( _count( $dbh, 'sessions', q{session_hash = 'current-session'} ),
    1, 'and the live session is kept' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _offset {
    my ( $handle, $interval ) = @_;

    my ($value) =
      $handle->selectrow_array( 'SELECT now() + ?::interval', undef,
        $interval );

    return $value;
}

sub _count {
    my ( $handle, $table, $where ) = @_;

    my $sql = "SELECT count(*) FROM $table";
    if ($where) {
        $sql .= " WHERE $where";
    }
    my ($count) = $handle->selectrow_array($sql);

    return $count;
}

1;
