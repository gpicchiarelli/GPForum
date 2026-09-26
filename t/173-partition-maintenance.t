# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::Fatal;
use Test::More;
use Time::Local qw(timegm);

use lib 'lib';
use lib 't/lib';

use GPForum::Command::PartitionMaintenance;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Test::PartitionDbh;

our $VERSION = '0.001';

const my $PLAN_YEAR        => 2026;
const my $SEPTEMBER_INDEX  => 8;
const my $DECEMBER_INDEX   => 11;
const my $PLAN_DAY         => 15;
const my $TWO_MONTHS       => 2;
const my $TABLE_COUNT      => 3;
const my $SIX_PLANS        => 6;
const my $CONFLICT_ROWS    => 4;
const my $LOCK_TIMEOUT_SQL => 5_000;
const my $EXIT_USAGE       => 2;
const my $EXIT_FAILURE     => 1;
const my $SEPTEMBER_DDL => join q{ },
  'CREATE TABLE IF NOT EXISTS audit_log_2026_09',
  'PARTITION OF audit_log',
  "FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')",
  "TO (TIMESTAMPTZ '2026-10-01 00:00:00+00')";
const my $PG_DEFAULT_ERROR => join q{ },
  'DBD::Pg::db do failed: ERROR:  updated partition constraint for',
  'default partition "event_log_default" would be violated by some row';

my $september = timegm( 0, 0, 0, $PLAN_DAY, $SEPTEMBER_INDEX, $PLAN_YEAR );
my $december  = timegm( 0, 0, 0, $PLAN_DAY, $DECEMBER_INDEX,  $PLAN_YEAR );
my $lifecycle = GPForum::Service::Operations::PartitionLifecycle->new;

_assert_plan_computation();
_assert_identifier_validation();
_assert_apply_and_idempotency();
_assert_plan_mode_writes_nothing();
_assert_default_partition_conflict();
_assert_postgres_conflict_is_classified();
_assert_unexpected_error_is_reported();
_assert_command();

done_testing();

sub _assert_plan_computation {
    my $plans = $lifecycle->plan_window(
        {
            horizon_months => $TWO_MONTHS,
            now_epoch      => $september,
        }
    );
    is( scalar @{$plans}, $SIX_PLANS, 'two months plan three tables each' );
    is(
        $plans->[0]{range_start_sql},
        '2026-09-01 00:00:00+00',
        'sql bound is an explicit UTC literal'
    );
    is(
        $plans->[0]{range_end_sql},
        '2026-10-01 00:00:00+00',
        'sql upper bound is the next month in UTC'
    );
    is( $plans->[0]{range_start},
        '2026-09-01T00:00:00Z', 'iso bound stays available for evidence' );
    is( $plans->[0]{create_sql},
        $SEPTEMBER_DDL, 'plan carries the idempotent partition DDL' );
    is( $lifecycle->create_statement( $plans->[0] ),
        $SEPTEMBER_DDL, 'create_statement reproduces the plan DDL' );
    is( $lifecycle->default_partition_name('event_log'),
        'event_log_default', 'default partition name follows migration 002' );
    is( $lifecycle->partition_key('notifications'),
        'created_at', 'partition key is created_at' );

    my $rollover = $lifecycle->plan_window(
        {
            horizon_months => $TWO_MONTHS,
            now_epoch      => $december,
        }
    );
    is( $rollover->[$TABLE_COUNT]{partition_name},
        'audit_log_2027_01', 'december lookahead rolls the year over' );
    is(
        $rollover->[$TABLE_COUNT]{range_end_sql},
        '2027-02-01 00:00:00+00',
        'rolled-over window ends in february'
    );

    return;
}

sub _assert_identifier_validation {
    like(
        exception { $lifecycle->validate_table_name('users') },
        qr/not [ ] a [ ] partitioned [ ] table/msx,
        'only declared partitioned tables are accepted'
    );
    like(
        exception {
            $lifecycle->validate_table_name('event_log; DROP TABLE users');
        },
        qr/unsafe [ ] table [ ] identifier/msx,
        'table identifiers reject injected SQL'
    );
    like(
        exception {
            $lifecycle->validate_partition_name( 'event_log',
                'event_log_2026_13' );
        },
        qr/not [ ] a [ ] month [ ] partition/msx,
        'month 13 is not a valid partition suffix'
    );
    like(
        exception {
            $lifecycle->validate_partition_name( 'event_log',
                'audit_log_2026_09' );
        },
        qr/not [ ] a [ ] month [ ] partition/msx,
        'a partition must belong to its declared parent'
    );
    like(
        exception {
            $lifecycle->validate_partition_name( 'event_log',
                q{event_log_2026_09"; DROP TABLE users; --} );
        },
        qr/unsafe [ ] partition [ ] identifier/msx,
        'partition identifiers reject injected SQL'
    );
    like(
        exception {
            $lifecycle->create_statement(
                {
                    partition_name  => 'event_log_2026_09',
                    range_end_sql   => '2026-10-01 00:00:00+00',
                    range_start_sql => q{2026-09-01 00:00:00+00') --},
                    table_name      => 'event_log',
                }
            );
        },
        qr/unsafe [ ] range [ ] bound/msx,
        'range bounds reject anything but a UTC literal'
    );
    like(
        exception { $lifecycle->ensure_partitions( {} ) },
        qr/database [ ] handle [ ] is [ ] required/msx,
        'ensure_partitions refuses to run without a handle'
    );
    like(
        exception {
            $lifecycle->ensure_partitions(
                {
                    dbh              => _handle(),
                    lookahead_months => 'all',
                }
            );
        },
        qr/lookahead_months [ ] must [ ] be/msx,
        'lookahead months must be a positive integer'
    );

    return;
}

sub _assert_apply_and_idempotency {
    my $handle = _handle();
    my $result = $lifecycle->ensure_partitions(
        {
            dbh       => $handle,
            now_epoch => $september,
        }
    );
    ok( $result->{ok}, 'apply run succeeds against an empty default' );
    is(
        scalar @{ $result->{created} },
        $TABLE_COUNT * $TABLE_COUNT,
        'default lookahead creates three months for three tables'
    );
    is( scalar @{ $result->{conflicts} }, 0, 'no conflicts are reported' );
    is(
        scalar @{ $handle->statements_like(qr/CREATE [ ] TABLE/msx) },
        $TABLE_COUNT * $TABLE_COUNT,
        'one CREATE per missing partition'
    );
    is( scalar @{ $handle->statements_like(qr/SET [ ] lock_timeout/msx) },
        1, 'the run bounds its lock wait' );
    is(
        $handle->statements_like(qr/SET [ ] lock_timeout/msx)->[0]{sql},
        "SET lock_timeout = $LOCK_TIMEOUT_SQL",
        'lock timeout is built from a validated integer'
    );

    my $upserts = $handle->statements_like(qr/INSERT [ ] INTO/msx);
    is(
        scalar @{$upserts},
        $TABLE_COUNT * $TABLE_COUNT,
        'every created partition is registered'
    );
    like(
        $upserts->[0]{sql},
        qr/ON [ ] CONFLICT [ ] [(]table_name, [ ] partition_name[)]/msx,
        'registry write is an idempotent upsert'
    );
    unlike( $upserts->[0]{sql},
        qr/2026/msx, 'registry values are bound, not interpolated' );
    is_deeply(
        $upserts->[0]{bind},
        [
            'audit_log',              'audit_log_2026_09',
            '2026-09-01 00:00:00+00', '2026-10-01 00:00:00+00',
            'created',
        ],
        'registry bind parameters carry the UTC window'
    );

    my $again = $lifecycle->ensure_partitions(
        {
            dbh       => $handle,
            now_epoch => $september,
        }
    );
    ok( $again->{ok}, 'second run still succeeds' );
    is( scalar @{ $again->{created} }, 0, 'second run creates nothing' );
    is(
        scalar @{ $again->{existing} },
        $TABLE_COUNT * $TABLE_COUNT,
        'second run reports existing partitions'
    );
    is(
        scalar @{ $handle->statements_like(qr/CREATE [ ] TABLE/msx) },
        $TABLE_COUNT * $TABLE_COUNT,
        'no duplicate DDL is issued'
    );

    return;
}

sub _assert_plan_mode_writes_nothing {
    my $handle = _handle();
    my $result = $lifecycle->ensure_partitions(
        {
            apply            => 0,
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $september,
        }
    );
    ok( $result->{ok}, 'plan mode succeeds' );
    is( scalar @{ $result->{planned} },
        $TABLE_COUNT, 'plan mode reports the missing partitions' );
    is( $result->{planned}[0]{create_sql},
        $SEPTEMBER_DDL, 'plan mode reports the DDL it would run' );
    is( scalar @{ $handle->statements_like(qr/CREATE|INSERT|SET/msx) },
        0, 'plan mode executes no DDL, registry write, or session change' );

    return;
}

sub _assert_default_partition_conflict {
    my $handle = _handle();
    $handle->default_counts->{event_log_default} = $CONFLICT_ROWS;
    my $result = $lifecycle->ensure_partitions(
        {
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $september,
        }
    );
    ok( !$result->{ok}, 'a default-partition overlap fails the run' );
    is( scalar @{ $result->{conflicts} }, 1, 'the overlap is reported once' );
    my $conflict = $result->{conflicts}[0];
    is( $conflict->{error}, 'default_partition_overlap',
        'the conflict is named, not an opaque database error' );
    is( $conflict->{conflicting_rows},
        $CONFLICT_ROWS, 'the conflict counts the blocking rows' );
    is( $conflict->{default_partition},
        'event_log_default', 'the conflict names the default partition' );
    like(
        $conflict->{message},
        qr/move [ ] them [ ] before [ ] attaching/msx,
        'the conflict message is actionable'
    );
    like(
        join( q{ }, @{ $conflict->{remediation} } ),
        qr/DETACH [ ] PARTITION [ ] event_log_default/msx,
        'remediation detaches the default partition'
    );
    like(
        join( q{ }, @{ $conflict->{remediation} } ),
        qr/ATTACH [ ] PARTITION [ ] event_log_default [ ] DEFAULT/msx,
        'remediation re-attaches the default partition'
    );
    is(
        scalar @{ $handle->statements_like(qr/CREATE [ ] TABLE/msx) },
        $TABLE_COUNT - 1,
        'the blocked table is skipped, the others proceed'
    );
    is(
        scalar @{ $result->{created} },
        $TABLE_COUNT - 1,
        'unblocked tables are still created'
    );

    return;
}

sub _assert_postgres_conflict_is_classified {
    my $handle = _handle();
    $handle->create_errors->{event_log_2026_09} = $PG_DEFAULT_ERROR;
    my $result = $lifecycle->ensure_partitions(
        {
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $september,
        }
    );
    ok( !$result->{ok}, 'a racing PostgreSQL overlap fails the run' );
    is( scalar @{ $result->{conflicts} },
        1, 'the database error is classified as an overlap' );
    is( $result->{conflicts}[0]{error},
        'default_partition_overlap', 'the classification is the same' );
    like(
        $result->{conflicts}[0]{detail},
        qr/would [ ] be [ ] violated/msx,
        'the original database message is kept as detail'
    );
    is( scalar @{ $result->{errors} }, 0, 'an overlap is not a generic error' );

    return;
}

sub _assert_unexpected_error_is_reported {
    my $handle = _handle();
    $handle->create_errors->{audit_log_2026_09} = 'ERROR: disk is full';
    my $result = $lifecycle->ensure_partitions(
        {
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $september,
        }
    );
    ok( !$result->{ok}, 'an unexpected failure fails the run' );
    is( scalar @{ $result->{errors} }, 1, 'the failure is reported' );
    like(
        $result->{errors}[0]{error},
        qr/disk [ ] is [ ] full/msx,
        'the database message is kept'
    );
    is( scalar @{ $result->{conflicts} },
        0, 'an unrelated failure is not an overlap' );
    is(
        scalar @{ $result->{created} },
        $TABLE_COUNT - 1,
        'the other tables are still created'
    );

    my $broken = _handle();
    $broken->probe_errors->{event_log_default} = 'ERROR: permission denied';
    my $probed = $lifecycle->ensure_partitions(
        {
            dbh              => $broken,
            lookahead_months => 1,
            now_epoch        => $september,
        }
    );
    ok( !$probed->{ok}, 'a failed overlap probe fails the run' );
    like(
        $probed->{errors}[0]{error},
        qr/default [ ] partition [ ] probe [ ] failed/msx,
        'the probe failure names itself'
    );
    is(
        scalar @{ $probed->{created} },
        $TABLE_COUNT - 1,
        'one broken probe does not stop the run'
    );

    return;
}

sub _assert_command {
    my $usage = _run_command( ['--help'] );
    is( $usage->{status}, 0, 'help exits 0' );
    like(
        $usage->{output},
        qr{bin/gpforum-partition-maintenance}msx,
        'help names the entrypoint'
    );

    my $handle = _handle();
    my $plan   = _run_command( [ '--plan', '--lookahead', $TWO_MONTHS ],
        _lifecycle_for($handle) );
    is( $plan->{status}, 0, 'plan mode exits 0' );
    like(
        $plan->{output},
        qr/partition_maintenance [ ] mode=plan [ ] ok=1 [ ] lookahead=2/msx,
        'plan mode prints a scheduler-friendly summary'
    );
    like(
        $plan->{output},
        qr/PARTITION [ ] OF [ ] audit_log/msx,
        'plan mode prints the DDL'
    );

    my $blocked = _handle();
    $blocked->default_counts->{audit_log_default} = $CONFLICT_ROWS;
    my $conflict = _run_command( ['--apply'], _lifecycle_for($blocked) );
    is( $conflict->{status}, $EXIT_FAILURE, 'a conflict exits non-zero' );
    like(
        $conflict->{output},
        qr/remediation [ ] BEGIN;/msx,
        'the operator procedure is printed'
    );

    my $unknown = _run_command( ['--nope'] );
    is( $unknown->{status}, $EXIT_USAGE, 'unknown options exit 2' );

    return;
}

sub _lifecycle_for {
    my ($handle) = @_;

    return GPForum::Service::Operations::PartitionLifecycle->new(
        dbh => $handle );
}

sub _run_command {
    my ( $arguments, $lifecycle ) = @_;

    my $output = q{};
    my $errors = q{};
    open my $capture, '>', \$output or croak 'capture stdout';
    my $status;
    {
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDERR = $stderr;
        $status = GPForum::Command::PartitionMaintenance->new(
            lifecycle => $lifecycle,
            output    => $capture,
        )->run( @{$arguments} );
        close $stderr or croak 'close stderr';
    }
    close $capture or croak 'close stdout';

    return {
        errors => $errors,
        output => $output,
        status => $status,
    };
}

sub _handle {
    return GPForum::Test::PartitionDbh->new(
        relations => {
            audit_log_default     => 1,
            event_log_default     => 1,
            notifications_default => 1,
        }
    );
}

