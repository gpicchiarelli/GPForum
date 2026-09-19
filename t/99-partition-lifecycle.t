package main;

use strict;
use warnings;

use Const::Fast;
use Time::Local qw(timegm);

use lib 'lib';

use GPForum::Service::Operations::PartitionLifecycle;
use Test::More;

our $VERSION = '0.001';

const my $PLAN_YEAR         => 2026;
const my $PLAN_MONTH_INDEX  => 8;
const my $PLAN_DAY          => 15;
const my $HORIZON_MONTHS    => 2;
const my $RETENTION_DAYS    => 30;
const my $POLICY_VERSION    => 1;
const my $EXPECTED_PLANS    => 6;
const my $NEXT_MONTH_OFFSET => 3;

my $lifecycle = GPForum::Service::Operations::PartitionLifecycle->new;
is_deeply(
    $lifecycle->partitioned_tables,
    [ 'audit_log', 'event_log', 'notifications' ],
    'lifecycle covers range-partitioned append tables'
);
is( $lifecycle->policy_version,
    $POLICY_VERSION, 'partition lifecycle policy is versioned' );
is( $lifecycle->next_state('planned'),
    'created', 'planned partitions become created' );
is( $lifecycle->next_state('created'),
    'detached', 'created partitions detach after retention' );

my $now_epoch = timegm( 0, 0, 0, $PLAN_DAY, $PLAN_MONTH_INDEX, $PLAN_YEAR );
my $plans     = $lifecycle->plan_window(
    {
        horizon_months => $HORIZON_MONTHS,
        now_epoch      => $now_epoch,
    }
);
is( scalar @{$plans}, $EXPECTED_PLANS,    'two months plan three tables each' );
is( $plans->[0]{table_name}, 'audit_log', 'plans are emitted in table order' );
is( $plans->[0]{partition_name},
    'audit_log_2026_09', 'September 2026 names the first window' );
is( $plans->[0]{range_start},
    '2026-09-01T00:00:00Z', 'window starts at month boundary' );
is( $plans->[0]{range_end},
    '2026-10-01T00:00:00Z', 'window ends at the next month' );
is( $plans->[$NEXT_MONTH_OFFSET]{partition_name},
    'audit_log_2026_10', 'horizon includes the following month' );

my $due = $lifecycle->retention_due(
    {
        now_epoch  => $now_epoch,
        partitions => [
            {
                partition_name => 'event_log_2025_01',
                range_end      => '2025-02-01T00:00:00Z',
                state          => 'created',
                table_name     => 'event_log',
            },
            {
                partition_name => 'event_log_2026_09',
                range_end      => '2026-10-01T00:00:00Z',
                state          => 'created',
                table_name     => 'event_log',
            },
        ],
        retention_days => $RETENTION_DAYS,
    }
);
is( scalar @{$due}, 1, 'only aged created partitions are due' );
is( $due->[0]{recommended_state},
    'detached', 'retention recommends detach before archive' );

my $empty = $lifecycle->restore_evidence( { partitions => [] } );
ok( !$empty->{restore_ready},
    'restore evidence is not ready without created partitions' );

my $ready = $lifecycle->restore_evidence(
    {
        partitions => [
            {
                partition_name => 'audit_log_2026_09',
                state          => 'created',
                table_name     => 'audit_log',
            },
        ],
    }
);
ok( $ready->{restore_ready}, 'created partitions count as restore evidence' );
is( $ready->{partition_counts}{created},
    1, 'restore evidence counts created rows' );

done_testing();

1;
