# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::Replication;
use GPForum::Test::ReadinessRuntime;
use GPForum::Test::ReplicationDbh;
use GPForum::Test::SlotLimitConfig;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 28;
const my $RETAINED       => 42_414_504;
const my $LOW_LIMIT      => 1_000;
const my $GIB            => 1_073_741_824;
const my $REPLAY_AGE     => 1.122_23;

plan tests => $EXPECTED_TESTS;

# ADR 0058: replication lag is monitored. A primary with one standby
# streaming through its slot and a second slot whose standby is gone.
my %primary = (
    standbys => [
        {
            application_name   => 'gpforum_standby',
            bytes_behind       => '0',
            replay_lag_seconds => '0.049058',
            state              => 'streaming',
            sync_state         => 'async',
        },
    ],
    slots => [
        _slot( 'gone_standby',    0, "$RETAINED" ),
        _slot( 'gpforum_standby', 1, '0' ),
    ],
);
my $replication = GPForum::Service::Operations::Replication->new;
my $snapshot =
  $replication->snapshot( GPForum::Test::ReplicationDbh->new(%primary) );

is( $snapshot->{role}, 'primary', 'a node not in recovery is the primary' );
is_deeply(
    $snapshot->{standbys}[0],
    {
        application_name   => 'gpforum_standby',
        bytes_behind       => 0,
        replay_lag_seconds => 0.049058,
        state              => 'streaming',
        sync_state         => 'async',
    },
    'each standby reports its state, replay lag and bytes behind'
);
is( $snapshot->{standby_details_visible},
    1, 'and the role can read the standby details' );
is_deeply(
    [
        map { [ @{$_}{qw(slot_name active retained_bytes)} ] }
          @{ $snapshot->{slots} }
    ],
    [ [ 'gone_standby', 0, $RETAINED ], [ 'gpforum_standby', 1, 0 ] ],
    'each slot reports whether it is active and the WAL it retains'
);

# DBD::Pg answers with strings; scrapers want numbers.
like(
    encode_json( $snapshot->{slots}[0] ),
    qr/"retained_bytes":$RETAINED\b/msx,
    'retained bytes are a JSON number'
);

# Without pg_read_all_stats PostgreSQL hides a walsender's state and positions.
my $hidden = $replication->snapshot(
    GPForum::Test::ReplicationDbh->new(
        standbys => [ { application_name => 'walreceiver' } ]
    )
);
is( $hidden->{standby_details_visible},
    0, 'a role that cannot read the standby details says so' );

# On a standby pg_current_wal_lsn() refuses to answer.
my $standby_dbh = GPForum::Test::ReplicationDbh->new(
    in_recovery      => 1,
    standby_position => {
        receiving            => '1',
        replay_age_seconds   => "$REPLAY_AGE",
        replay_pending_bytes => '0',
    },
);
my $standby = $replication->snapshot($standby_dbh);
is( $standby->{role}, 'standby', 'a node in recovery is a standby' );
is( $standby->{replay_age_seconds},
    $REPLAY_AGE, 'a standby reports how long ago it replayed a transaction' );
is( $standby->{replay_pending_bytes},
    0, 'and the WAL it received and has not replayed' );
is( scalar( grep { /pg_current_wal_lsn/msx } @{ $standby_dbh->statements } ),
    0, 'without asking a standby for the primary\'s WAL position' );
is( $standby->{receiving}, 1, 'and whether it is receiving WAL' );

# A standby that has lost its primary receives nothing, so it has nothing
# pending either, and its replay age grows as an idle primary's would:
# receiving is what tells the two apart.
is(
    $replication->snapshot(
        GPForum::Test::ReplicationDbh->new(
            in_recovery      => 1,
            standby_position => {
                receiving            => '0',
                replay_age_seconds   => "$REPLAY_AGE",
                replay_pending_bytes => '0',
            },
        )
    )->{receiving},
    0,
    'a standby cut off from its primary says it is not receiving'
);

# Slots: an inactive one over the limit, or a lost one, degrades.
my %report = map {
    $_->[0] => GPForum::Service::Operations::Replication->new(
        max_retained_bytes => $_->[1] )->slot_report( $_->[2] )
} (
    [ default => $GIB,       $snapshot ],
    [ low     => $LOW_LIMIT, $snapshot ],
    [
        active => $LOW_LIMIT,
        { slots => [ _slot( 'gpforum_standby', 1, "$RETAINED" ) ] }
    ],
    [
        lost => $GIB,
        { slots => [ _slot( 'gone_standby', 0, undef, 'lost' ) ] }
    ],
);
is( $report{default}{status}, 'ok', 'an inactive slot under the limit is ok' );
is( $report{low}{status},
    'degraded', 'an inactive slot over the limit degrades' );
like(
    $report{low}{problems}[0],
    qr/inactive [ ] slot [ ] gone_standby [ ] retains [ ] $RETAINED/msx,
    'and the problem names the slot and what it keeps'
);
is( $report{active}{status},
    'ok', 'a slot its standby is reading is never over the limit' );
is( $report{lost}{status}, 'degraded', 'a lost slot degrades' );

# The metrics endpoint reports the snapshot, and a database that cannot
# answer turns the section unavailable instead of failing the endpoint.
my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    schema => GPForum::Test::ReplicationDbh->new(%primary) )->collect;
is_deeply( $metrics->{replication},
    $snapshot, 'metrics expose the replication snapshot' );
my $unavailable = GPForum::Service::Operations::MetricsSnapshot->new(
    schema => GPForum::Test::ReplicationDbh->new( failure => 'gone away' ) )
  ->collect;
is( $unavailable->{replication}{status},
    'unavailable',
    'a database that cannot answer leaves the section unavailable' );
is( $unavailable->{replication}{error}, 'gone away', 'with the reason' );
is_deeply(
    GPForum::Service::Operations::MetricsSnapshot->new->collect->{replication},
    {}, 'and without a schema the section is empty'
);

# Readiness degrades on an inactive slot over the configured limit.
is( _slot_check( {} )->{status},
    'ok', 'readiness accepts a slot under the default 1 GiB' );
my $over = _slot_check( { replication_slot_max_retained_bytes => $LOW_LIMIT } );
is( $over->{status}, 'degraded',
    'readiness degrades on an inactive slot over the limit' );
is(
    $over->{runbook},
    'docs/ops/standby-and-failover.md#watch-the-lag',
    'and points at the standby runbook'
);
is( $over->{report}{max_retained_bytes},
    $LOW_LIMIT, 'and reports the limit it applied' );

# The configuration's limit applies when the attribute is not given.
is(
    _slot_check(
        {
            config => GPForum::Test::SlotLimitConfig->new(
                replication_slot_max_retained_bytes => $LOW_LIMIT
            )
        }
    )->{status},
    'degraded',
    'the configured limit applies'
);

my $failing = _slot_check( {},
    GPForum::Test::ReplicationDbh->new( failure => 'permission denied' ) );
is( $failing->{status}, 'degraded',
    'a slot catalog that cannot be read degrades, it does not fail' );
like( $failing->{error}, qr/permission [ ] denied/msx, 'with the error' );

sub _slot {
    my ( $name, $active, $retained, $wal_status ) = @_;

    return {
        active         => $active,
        retained_bytes => $retained,
        slot_name      => $name,
        slot_type      => 'physical',
        wal_status     => $wal_status // 'reserved',
    };
}

sub _slot_check {
    my ( $options, $dbh ) = @_;

    my $report = GPForum::Service::Operations::Readiness->new(
        environment => 'test',
        runtime     => GPForum::Test::ReadinessRuntime->new,
        schema      => $dbh // GPForum::Test::ReplicationDbh->new(%primary),
        %{$options},
    )->check;
    my ($check) =
      grep { $_->{name} eq 'replication_slots' } @{ $report->{checks} };

    return $check;
}

1;
