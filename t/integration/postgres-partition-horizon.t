# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Time::Piece ();

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::Readiness;
use GPForum::Test::FixedClock;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $MIGRATED_HORIZON   => '2027-01-01';
const my $PARTITIONED_TABLES => 3;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the partition horizon test';
}

# 3.7 against PostgreSQL's own catalog: the horizon the migrations leave, the
# warning as it approaches, and rows spilling into a DEFAULT partition.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $schema    = GPForum::Test::PostgresHarness::connect_schema();
my $dbh       = $schema->storage->dbh;
my $lifecycle = GPForum::Service::Operations::PartitionLifecycle->new;

my $today = $lifecycle->horizon_report( $dbh, _day_epoch('2026-09-26') );
is( $today->{status}, 'ok', 'the migrated horizon is three months out' );
is_deeply(
    [ map { $_->{horizon} } @{ $today->{tables} } ],
    [ ($MIGRATED_HORIZON) x $PARTITIONED_TABLES ],
    'read from the catalog for all three partitioned tables'
);

my $december = $lifecycle->horizon_report( $dbh, _day_epoch('2026-12-01') );
is( $december->{status}, 'degraded', 'a month short of it, readiness warns' );
is( scalar @{ $december->{problems} }, $PARTITIONED_TABLES, 'for each table' );

$dbh->do(
    q{INSERT INTO audit_log (audit_id, action, schema_version, correlation_id,}
      . q{ created_at) VALUES (gen_random_uuid(), 'probe.late', 1,}
      . q{ gen_random_uuid(), '2027-03-01T00:00:00Z')} );
my $spilled = $lifecycle->horizon_report( $dbh, _day_epoch('2026-09-26') );
is( $spilled->{status}, 'degraded',
    'a row past the horizon lands in DEFAULT, and readiness warns' );
like(
    join( q{ }, @{ $spilled->{problems} } ),
    qr/audit_log_default [ ] holds [ ] rows/msx,
    'naming the partition'
);

my $readiness = GPForum::Service::Operations::Readiness->new(
    clock => GPForum::Test::FixedClock->new(
        epoch   => _day_epoch('2026-09-26'),
        iso8601 => '2026-09-26T00:00:00Z'
    ),
    environment => 'testing',
    schema      => $schema,
)->check;
my ($check) =
  grep { $_->{name} eq 'partition_horizon' } @{ $readiness->{checks} };
is( $check->{status}, 'degraded',
    'the readiness check reads the real catalog' );
ok( $check->{report}{tables}, 'and reports every table' );

$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _day_epoch {
    my ($day) = @_;

    return Time::Piece->strptime( $day, '%Y-%m-%d' )->epoch;
}

1;
