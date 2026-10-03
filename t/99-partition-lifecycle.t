# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English     qw(-no_match_vars);
use Time::Local qw(timegm);
use Time::Piece ();

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Test::PartitionDbh;
use GPForum::Test::RefusedSchema;
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
const my $TABLES            => 3;
const my $LOCK_KEY          => 4_021_970_002;
const my $SEPTEMBER_ATTACH => join q{ },
  'ALTER TABLE audit_log ATTACH PARTITION audit_log_2026_09',
  q{FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')},
  q{TO (TIMESTAMPTZ '2026-10-01 00:00:00+00')};
const my $DEFAULT_OVERLAP => 'DBD::Pg::db do failed: ERROR:  updated'
  . ' partition constraint for default partition "notifications_default"'
  . ' would be violated by some row';
const my $LOCK_TIMEOUT => 'DBD::Pg::db do failed: ERROR:  canceling statement'
  . ' due to lock timeout at lib/GPForum/Service/Operations/'
  . 'PartitionLifecycle.pm line 764.';
const my $ATTEMPTS        => 3;
const my $WAIT_MS         => 60_000;
const my $STATEMENT_MS    => 15_000;
const my $DEFAULT_LOCK_MS => 500;

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

# 3.7: an alert before the partition horizon runs out. The migrations create
# partitions to 2027-01-01 and the monthly maintenance command extends them;
# nothing warned when it stopped running.
const my $DAYS_LEFT_ON_20_NOVEMBER => 42;
my $horizon_lifecycle = GPForum::Service::Operations::PartitionLifecycle->new;
my @ends              = map {
    {
        default_rows  => 0,
        horizon_epoch => _day_epoch('2027-01-01'),
        table         => $_
    }
} qw(audit_log event_log notifications);
my $spilled_event_log = { %{ $ends[1] }, default_rows => 1 };
is(
    $horizon_lifecycle->evaluate_horizon(
        { now_epoch => _day_epoch('2026-09-26'), tables => \@ends }
    )->{status},
    'ok',
    'three months of partitions ahead is fine'
);
my $late = $horizon_lifecycle->evaluate_horizon(
    { now_epoch => _day_epoch('2026-11-20'), tables => \@ends } );
is( $late->{status}, 'degraded', 'under 45 days of partitions ahead degrades' );
is( $late->{tables}[0]{days_left},
    $DAYS_LEFT_ON_20_NOVEMBER, 'and says how many days are left' );
like(
    $late->{problems}[0],
    qr/audit_log .* 2027-01-01 .* 42 [ ] days/msx,
    'naming the table and its horizon'
);
my $spilled = $horizon_lifecycle->evaluate_horizon(
    {
        now_epoch => _day_epoch('2026-09-26'),
        tables    => [ $spilled_event_log, $ends[0], $ends[2] ],
    }
);
is( $spilled->{status}, 'degraded',
    'rows in a DEFAULT partition degrade: maintenance was missed' );
like( $spilled->{problems}[0],
    qr/event_log_default/msx, 'naming the partition to remediate' );
is(
    $horizon_lifecycle->evaluate_horizon(
        {
            now_epoch => _day_epoch('2026-09-26'),
            tables    => [ $ends[0], $ends[1] ]
        }
    )->{status},
    'degraded',
    'a partitioned table with no partition at all degrades'
);

# A schema whose database refuses the connection. The refusal was swallowed,
# so partition-maintenance against a database it could not reach said only
# that it needed a handle: the operator learnt nothing about the port or the
# password. The reason comes through, on one line, without the code locations
# DBI and DBIx::Class put on it. It still quotes the DSN's password=: the
# command printing it redacts that (t/284-evidence-command-failures.t).
const my $REFUSED => 'partition lifecycle: cannot connect to the database: '
  . 'DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed: '
  . q{DBI connect('dbname=gpforum;host=127.0.0.1;port=1;password=hunter2',}
  . q{'gpforum',...) failed: connection to server at "127.0.0.1", port 1}
  . ' failed: Connection refused Is the server running on that host and'
  . ' accepting TCP/IP connections?';
const my $NO_HANDLE => 'partition lifecycle: a database handle is required';

my $refused = eval {
    GPForum::Service::Operations::PartitionLifecycle->new(
        schema => GPForum::Test::RefusedSchema->new )->ensure_partitions( {} );
    1;
} ? q{} : "$EVAL_ERROR";
( my $refused_reason = $refused ) =~
  s/[ ] at [ ] \S+ [ ] line [ ] \d+ [.] \n \z//msx;
is( $refused_reason, $REFUSED,
    'an unreachable database fails with the reason it is unreachable' );
is( ( $refused =~ tr/\n// ), 1, 'on one line' );

my $no_reason = eval {
    GPForum::Service::Operations::PartitionLifecycle->new(
        schema => GPForum::Test::RefusedSchema->new( error => q{} ) )
      ->ensure_partitions( {} );
    1;
} ? q{} : "$EVAL_ERROR";
like( $no_reason, qr/\A\Q$NO_HANDLE\E/msx,
    'a storage with no handle and no reason still asks for one' );

_assert_create_then_attach();
_assert_failed_attach_rolls_back();
_assert_advisory_lock();
_assert_lock_wait();
_assert_lock_timeout_retried();
_assert_statement_timeout();
_assert_window_follows_now();

done_testing();

# ADR 0113. A month is a table of its own, attached in the same transaction
# as its registry row: ATTACH takes SHARE UPDATE EXCLUSIVE on the parent where
# CREATE TABLE ... PARTITION OF took ACCESS EXCLUSIVE. What PostgreSQL does
# with it is t/integration/postgres-partition-maintenance.t.
sub _assert_create_then_attach {
    my $handle = _partition_handle();
    my $result =
      GPForum::Service::Operations::PartitionLifecycle->new->ensure_partitions(
        {
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $now_epoch,
        }
      );
    ok( $result->{ok}, 'a run on an empty DEFAULT succeeds' );
    my @sql = map { $_->{sql} } @{ $handle->statements };
    my ($create) = grep { /\A CREATE [ ] TABLE [ ] audit_log_2026_09/msx } @sql;
    like(
        $create,
        qr/[(]LIKE [ ] audit_log [ ]/msx,
        'the month is created LIKE its parent'
    );
    like(
        $create,
        qr/INCLUDING [ ] DEFAULTS [ ] INCLUDING [ ] CONSTRAINTS/msx,
        'defaults and constraints included'
    );
    unlike(
        $create,
        qr/INDEXES|PARTITION [ ] OF/msx,
        'without copying indexes, and not as PARTITION OF'
    );
    ok(
        ( grep { $_ eq $SEPTEMBER_ATTACH } @sql ),
        'then attached for its UTC month'
    );
    is_deeply(
        $handle->transactions,
        [ ( 'begin', 'commit' ) x $TABLES ],
        'one transaction per partition, each committed'
    );
    my $order = join q{ }, map {
            /\A CREATE/msx ? 'create'
          : /ATTACH/msx    ? 'attach'
          : /\A INSERT/msx ? 'register'
          : ()
    } @sql;
    is(
        $order,
        join( q{ }, ('create attach register') x $TABLES ),
        'the registry row is written inside the same transaction'
    );
    my $creator = GPForum::Service::Operations::PartitionLifecycle->new;
    my $plan    = $creator->plan_window( { now_epoch => $now_epoch } )->[0];
    is(
        $creator->remediation_steps($plan)->[2],
        q{CREATE TABLE IF NOT EXISTS audit_log_2026_09 PARTITION OF audit_log}
          . q{ FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')}
          . q{ TO (TIMESTAMPTZ '2026-10-01 00:00:00+00');},
        'the remediation, run with DEFAULT detached, keeps PARTITION OF'
    );

    return;
}

# A DEFAULT overlap or a lock timeout raised by the ATTACH rolls the CREATE
# back too, so no unattached table is left to read as an existing partition
# next run.
sub _assert_failed_attach_rolls_back {
    my $handle = _partition_handle();
    $handle->create_errors->{notifications_2026_09} = $DEFAULT_OVERLAP;
    my $attacher = GPForum::Service::Operations::PartitionLifecycle->new;
    my $result   = $attacher->ensure_partitions(
        {
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $now_epoch,
        }
    );
    ok( !$result->{ok}, 'an ATTACH refused by PostgreSQL fails the run' );
    is( $result->{conflicts}[0]{partition_name},
        'notifications_2026_09', 'as a DEFAULT overlap on that partition' );
    is_deeply(
        $handle->transactions,
        [qw(begin commit begin commit begin rollback)],
        'its transaction is rolled back, the others committed'
    );
    ok(
        !$handle->relations->{notifications_2026_09},
        'and the table it created is gone with it'
    );
    is(
        scalar @{ $handle->statements_like(qr/INSERT [ ] INTO/msx) },
        $TABLES - 1,
        'nor a registry row for it'
    );

    delete $handle->create_errors->{notifications_2026_09};
    my $again = $attacher->ensure_partitions(
        {
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $now_epoch,
        }
    );
    is_deeply(
        [ map { $_->{partition_name} } @{ $again->{created} } ],
        ['notifications_2026_09'],
        'so the next run creates it rather than calling it existing'
    );

    return;
}

# Two nodes' timers and a deploy's migrate can overlap: the run that does
# not get the advisory lock does nothing and says so.
sub _assert_advisory_lock {
    my $handle = _partition_handle();
    my $locker = GPForum::Service::Operations::PartitionLifecycle->new;
    is( $locker->maintenance_lock_key,
        $LOCK_KEY, 'the maintenance lock has its documented key' );
    my $result = $locker->ensure_partitions(
        { dbh => $handle, lookahead_months => 1, now_epoch => $now_epoch } );
    my @locks =
      grep { /advisory/msx } map { $_->{sql} } @{ $handle->statements };
    is_deeply(
        \@locks,
        [ 'SELECT pg_try_advisory_lock(?)', 'SELECT pg_advisory_unlock(?)' ],
        'an applying run tries the lock without waiting, and releases it'
    );
    is( $handle->statements_like(qr/pg_try_advisory_lock/msx)->[0]{bind}[0],
        $LOCK_KEY, 'under that key' );
    ok( !exists $result->{locked}, 'and the result does not keep it' );
    is( $result->{skipped}, 0, 'a run that got the lock is not skipped' );

    my $busy = _partition_handle();
    $busy->lock_held(1);
    my $skipped = $locker->ensure_partitions(
        { dbh => $busy, lookahead_months => 1, now_epoch => $now_epoch } );
    ok( $skipped->{ok}, 'a run that finds the lock held is ok' );
    is( $skipped->{skipped}, 1, 'and skipped' );
    is_deeply(
        [
            map { scalar @{ $skipped->{$_} } }
              qw(created existing conflicts errors)
        ],
        [ 0, 0, 0, 0 ],
        'having done nothing'
    );
    is(
        scalar @{ $busy->statements_like(qr/CREATE|ATTACH|INSERT|unlock/msx) },
        0,
        'no DDL, no registry write, and no lock of its own to release'
    );

    my $plan_handle = _partition_handle();
    $plan_handle->lock_held(1);
    my $planned = $locker->ensure_partitions(
        {
            apply            => 0,
            dbh              => $plan_handle,
            lookahead_months => 1,
            now_epoch        => $now_epoch,
        }
    );
    is( scalar @{ $planned->{planned} },
        $TABLES, 'planning takes no lock, and plans while a run holds it' );
    is( scalar @{ $plan_handle->statements_like(qr/advisory/msx) },
        0, 'without asking for it' );

    return;
}

# migrate waits for a run already at work rather than skipping at once, under
# a lock_timeout of its own, and puts the month transactions' one back.
sub _assert_lock_wait {
    my $handle = _partition_handle();
    my $waiter =
      GPForum::Service::Operations::PartitionLifecycle->new(
        lock_wait_ms => $WAIT_MS );
    my $result = $waiter->ensure_partitions(
        { dbh => $handle, lookahead_months => 1, now_epoch => $now_epoch } );
    is( $result->{skipped}, 0, 'a run that waits for the lock gets it' );
    is_deeply(
        [
            map  { $_->{sql} }
            grep { $_->{sql} =~ /lock_timeout|advisory/msx }
              @{ $handle->statements }
        ],
        [
            "SET lock_timeout = $DEFAULT_LOCK_MS",
            "SET lock_timeout = $WAIT_MS",
            'SELECT pg_advisory_lock(?)',
            "SET lock_timeout = $DEFAULT_LOCK_MS",
            'SELECT pg_advisory_unlock(?)',
        ],
'waiting with pg_advisory_lock under its own timeout, then the short one'
    );

    my $busy = _partition_handle();
    $busy->lock_held(1);
    my $skipped = $waiter->ensure_partitions(
        { dbh => $busy, lookahead_months => 1, now_epoch => $now_epoch } );
    ok( $skipped->{ok} && $skipped->{skipped},
        'a wait that times out is a skipped run, not a failure' );
    is( scalar @{ $busy->statements_like(qr/CREATE|unlock/msx) },
        0, 'doing nothing and releasing nothing' );

    return;
}

# A lock timeout on a month's transaction is tried again, after a pause, up
# to lock_attempts times; a DEFAULT overlap is not. Errors carry no code
# location.
sub _assert_lock_timeout_retried {
    my $handle = _partition_handle();
    $handle->create_errors->{event_log_2026_09} =
      [ $LOCK_TIMEOUT, $LOCK_TIMEOUT ];
    my $retrier = GPForum::Service::Operations::PartitionLifecycle->new(
        lock_attempts  => $ATTEMPTS,
        retry_pause_ms => 0,
    );
    my $result = $retrier->ensure_partitions(
        { dbh => $handle, lookahead_months => 1, now_epoch => $now_epoch } );
    ok( $result->{ok}, 'a month that timed out twice is in on the third try' );
    is_deeply(
        $handle->transactions,
        [
            qw(begin commit begin rollback begin rollback begin commit begin commit)
        ],
        'each try its own transaction, rolled back until it went through'
    );
    ok( $handle->relations->{event_log_2026_09}, 'and the month is there' );

    my $stuck = _partition_handle();
    $stuck->create_errors->{event_log_2026_09} =
      [ ($LOCK_TIMEOUT) x $ATTEMPTS ];
    my $given_up = $retrier->ensure_partitions(
        { dbh => $stuck, lookahead_months => 1, now_epoch => $now_epoch } );
    ok( !$given_up->{ok}, 'a month still locked out after its tries fails' );
    is( scalar( grep { $_ eq 'rollback' } @{ $stuck->transactions } ),
        $ATTEMPTS, 'after lock_attempts tries' );
    is(
        $given_up->{errors}[0]{error},
        'DBD::Pg::db do failed: ERROR: canceling statement due to lock timeout',
        'reported as an error without the code location DBI appended'
    );

    my $overlap = _partition_handle();
    $overlap->create_errors->{notifications_2026_09} = $DEFAULT_OVERLAP;
    my $overlapping = $retrier->ensure_partitions(
        { dbh => $overlap, lookahead_months => 1, now_epoch => $now_epoch } );
    is( scalar( grep { $_ eq 'rollback' } @{ $overlap->transactions } ),
        1, 'a DEFAULT overlap is not tried again' );
    is( $overlapping->{conflicts}[0]{partition_name},
        'notifications_2026_09', 'and stays a conflict' );

    return;
}

# migrate lifted statement_timeout for its migrations and hands the window
# step the configured one; unset, the session's own stands.
sub _assert_statement_timeout {
    my $handle = _partition_handle();
    GPForum::Service::Operations::PartitionLifecycle->new(
        statement_timeout_ms => $STATEMENT_MS )
      ->ensure_partitions(
        { dbh => $handle, lookahead_months => 1, now_epoch => $now_epoch } );
    is_deeply(
        [
            map { $_->{sql} }
              @{ $handle->statements_like(qr/statement_timeout/msx) }
        ],
        ["SET statement_timeout = $STATEMENT_MS"],
        'a given statement_timeout is set before the run'
    );

    my $untouched = _partition_handle();
    GPForum::Service::Operations::PartitionLifecycle->new->ensure_partitions(
        { dbh => $untouched, lookahead_months => 1, now_epoch => $now_epoch } );
    is( scalar @{ $untouched->statements_like(qr/statement_timeout/msx) },
        0, 'and none is set when not given' );

    my $planned = _partition_handle();
    GPForum::Service::Operations::PartitionLifecycle->new(
        statement_timeout_ms => $STATEMENT_MS )->ensure_partitions(
        {
            apply            => 0,
            dbh              => $planned,
            lookahead_months => 1,
            now_epoch        => $now_epoch,
        }
        );
    is( scalar @{ $planned->statements_like(qr/statement_timeout/msx) },
        0, 'nor by a plan' );

    return;
}

# The window is the month of the given time and the ones after it: nothing
# about it is a date written down.
sub _assert_window_follows_now {
    my $planner = GPForum::Service::Operations::PartitionLifecycle->new;
    for my $case (
        [ '2027-03-15', [qw(2027_03 2027_04 2027_05)] ],
        [ '2026-12-31', [qw(2026_12 2027_01 2027_02)] ],
      )
    {
        my ( $day, $months ) = @{$case};
        my $handle = _partition_handle();
        my $result = $planner->ensure_partitions(
            { dbh => $handle, now_epoch => _day_epoch($day) } );
        is_deeply(
            [
                map  { $_->{partition_name} =~ /(\d{4}_\d\d)\z/msx }
                grep { $_->{table_name} eq 'audit_log' } @{ $result->{created} }
            ],
            $months,
            "on $day the default window is @{$months}"
        );
    }

    return;
}

sub _partition_handle {
    return GPForum::Test::PartitionDbh->new(
        relations => {
            audit_log_default     => 1,
            event_log_default     => 1,
            notifications_default => 1,
        }
    );
}

sub _day_epoch {
    my ($day) = @_;

    return Time::Piece->strptime( $day, '%Y-%m-%d' )->epoch;
}

1;
