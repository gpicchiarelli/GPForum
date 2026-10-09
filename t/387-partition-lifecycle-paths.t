# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Time::HiRes ();
use Time::Local qw(timegm);

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Test::PartitionPathDbh;
use GPForum::X::Argument;
use Test::More;

our $VERSION = '0.001';

# The PartitionLifecycle paths no test failed without when its single-caller
# helpers were folded into their callers: each block below fails under a
# mutation of the branch it names.

const my $TABLES           => 3;
const my $YEAR             => 2026;
const my $AUGUST           => 7;
const my $SEPTEMBER_INDEX  => 8;
const my $MID_MONTH        => 15;
const my $LAST_DAY         => 31;
const my $HALF_MINUTE      => 30;
const my $RETENTION_DAYS   => 30;
const my $UNKNOWN_ROWS     => -1;
const my $CONFLICTING_ROWS => 2;
const my $PAUSE_MS         => 200;
const my $PAUSE_FLOOR      => 0.15;
const my $LOCK_STATE       => '55P03';
const my $DEFAULT_LOCK     => 'SET lock_timeout = 500';
const my @DEFAULTS =>
  qw(audit_log_default event_log_default notifications_default);
const my @SEPTEMBER =>
  qw(audit_log_2026_09 event_log_2026_09 notifications_2026_09);
const my $SEPTEMBER_FROM => '2026-09-01 00:00:00+00';
const my $SEPTEMBER_TO   => '2026-10-01 00:00:00+00';
const my $RANGE => "created_at >= TIMESTAMPTZ '$SEPTEMBER_FROM'"
  . " AND created_at < TIMESTAMPTZ '$SEPTEMBER_TO'";
const my $REGISTRY_INSERT => qr/\A INSERT [ ] INTO [ ] partition_registry/msx;
const my $BAD_BOUND =>
  qr/\A partition [ ] lifecycle: [ ] unsafe [ ] range [ ] bound/msx;

my $now_epoch = timegm( 0, 0, 0, $MID_MONTH, $SEPTEMBER_INDEX, $YEAR );
my $lifecycle = GPForum::Service::Operations::PartitionLifecycle->new;
my $plan      = $lifecycle->plan_window( { now_epoch => $now_epoch } )->[0];

_assert_remediation();
_assert_conflict_report();
_assert_retention();
_assert_restore_counts();
_assert_existing_partitions();
_assert_default_probe();
_assert_lock_state_retry();
_assert_retry_pause();
_assert_attribute_checks();
_assert_wait_failure();

done_testing();

sub _assert_remediation {
    is_deeply(
        $lifecycle->remediation_steps($plan),
        [
            'BEGIN;',
            'ALTER TABLE audit_log DETACH PARTITION audit_log_default;',
'CREATE TABLE IF NOT EXISTS audit_log_2026_09 PARTITION OF audit_log'
              . " FOR VALUES FROM (TIMESTAMPTZ '$SEPTEMBER_FROM')"
              . " TO (TIMESTAMPTZ '$SEPTEMBER_TO');",
"INSERT INTO audit_log SELECT * FROM audit_log_default WHERE $RANGE;",
            "DELETE FROM audit_log_default WHERE $RANGE;",
            'ALTER TABLE audit_log ATTACH PARTITION audit_log_default DEFAULT;',
            'COMMIT;',
        ],
        'the remediation moves exactly the month out of DEFAULT and back'
    );
    my %broken = (
        %{$plan},
        partition_name => 'audit_log_bad',
        range_end_sql  => 'soon',
    );
    my $bad_bound =
      _error_of( sub { $lifecycle->remediation_steps( \%broken ) } );
    like( $bad_bound, $BAD_BOUND,
        'a bad bound is reported before a bad partition name' );
    ok(
        GPForum::X::Argument->caught($bad_bound),
        'as a broken argument, X::Argument'
    );

    return;
}

sub _assert_conflict_report {
    my $report = $lifecycle->conflict_report( $plan, undef );
    is(
        $report->{message},
        'rows already in audit_log_default overlap audit_log_2026_09'
          . ' [2026-09-01T00:00:00Z, 2026-10-01T00:00:00Z);'
          . ' move them before attaching',
        'the conflict message names DEFAULT, the month and its range in order'
    );
    is( $report->{conflicting_rows},
        $UNKNOWN_ROWS, 'unknown conflicting rows are -1' );
    ok( !exists $report->{detail},
        'and no detail is given unless there is one' );
    is(
        $lifecycle->conflict_report( $plan, $CONFLICTING_ROWS, 'pg said' )
          ->{detail},
        'pg said',
        'a given detail is kept'
    );

    return;
}

# The cutoff is now less retention_days, to the second, and a partition whose
# range ends on it is due.
sub _assert_retention {
    my $now  = timegm( $HALF_MINUTE, 0, 0, $LAST_DAY, $AUGUST, $YEAR );
    my @rows = (
        _retention_row( 'event_log_2026_07',     '2026-08-01T00:00:30Z' ),
        _retention_row( 'audit_log_2026_07',     '2026-08-01T00:00:15Z' ),
        _retention_row( 'notifications_2026_07', '2026-08-01T00:00:31Z' ),
        _retention_row(
            'event_log_2025_01', '2025-02-01T00:00:00Z', 'detached'
        ),
    );
    my @expected = map { _recommended($_) } @rows[ 0, 1 ];
    is_deeply(
        $lifecycle->retention_due(
            {
                now_epoch      => $now,
                partitions     => \@rows,
                retention_days => $RETENTION_DAYS,
            }
        ),
        \@expected,
        'created months ending on or before the cutoff are due, nothing else'
    );

    return;
}

sub _assert_restore_counts {
    my $evidence = $lifecycle->restore_evidence(
        {
            partitions => [ { state => 'dropped' }, {}, { state => 'unknown' } ]
        }
    );
    is_deeply(
        $evidence,
        {
            ok               => 0,
            partition_counts => {
                archived => 0,
                created  => 0,
                detached => 0,
                dropped  => 1,
                planned  => 1,
            },
            policy_version => 1,
            restore_ready  => 0,
            tables         => [qw(audit_log event_log notifications)],
        },
        'every state is counted, a row without one as planned, others ignored'
    );

    return;
}

# An existing month is listed, and an applying run upserts its registry row;
# a plan writes nothing, and a failed upsert is that month's error.
sub _assert_existing_partitions {
    my $handle = _handle(@SEPTEMBER);
    my $result = _ensure($handle);
    is( scalar @{ $result->{existing} }, $TABLES,
        'existing months are listed' );
    my @expected =
      map { [ _table_of($_), $_, $SEPTEMBER_FROM, $SEPTEMBER_TO, 'created' ] }
      @SEPTEMBER;
    is_deeply(
        [ map { $_->{bind} } @{ $handle->statements_like($REGISTRY_INSERT) } ],
        \@expected,
        'and their registry rows upserted as created'
    );
    is_deeply( $handle->transactions, [],
        'outside any transaction of the run' );

    my $plan_handle = _handle(@SEPTEMBER);
    _ensure( $plan_handle, apply => 0 );
    is( scalar @{ $plan_handle->statements_like(qr/INSERT/msx) },
        0, 'a plan upserts no registry row' );

    my $failing = _handle(@SEPTEMBER);
    $failing->registry_error(
        "permission denied for table partition_registry\n at Foo.pm line 3.\n");
    my $failed = _ensure($failing);
    ok( !$failed->{ok}, 'a failed registry upsert fails the run' );
    is_deeply(
        $failed->{errors}[0],
        {
            default_partition => 'audit_log_default',
            error          => 'permission denied for table partition_registry',
            partition_name => 'audit_log_2026_09',
            range_end      => '2026-10-01T00:00:00Z',
            range_start    => '2026-09-01T00:00:00Z',
            table_name     => 'audit_log',
        },
        'as an error on that month, without the code location'
    );

    return;
}

# Rows are counted in DEFAULT only when it exists, inside the half-open
# month; a probe that fails is the month's error, on one line. A created
# month carries the DDL it ran.
sub _assert_default_probe {
    my $handle  = _handle(@DEFAULTS);
    my $created = _ensure($handle);
    is_deeply(
        $handle->statements_like(qr/count/msx)->[0],
        {
            bind => [ $SEPTEMBER_FROM, $SEPTEMBER_TO ],
            sql  => 'SELECT count(*) FROM audit_log_default'
              . ' WHERE created_at >= CAST(? AS timestamptz)'
              . ' AND created_at < CAST(? AS timestamptz)',
        },
        'DEFAULT is probed for rows in [start, end)'
    );
    is( $created->{created}[0]{create_sql},
        $plan->{create_sql}, 'a created month carries the DDL it ran' );

    my $missing = _handle();
    for my $default (@DEFAULTS) {
        $missing->probe_errors->{$default} =
          qq{relation "$default" does not exist};
    }
    my $without = _ensure($missing);
    ok( $without->{ok},
        'without a DEFAULT partition there is nothing to probe' );
    is( scalar @{ $without->{created} }, $TABLES,
        'and every month is created' );

    my $failing = _handle(@DEFAULTS);
    $failing->probe_errors->{audit_log_default} =
      "canceling statement\n  due to user request at Foo.pm line 9.\n";
    is(
        _ensure($failing)->{errors}[0]{error},
        'partition lifecycle: default partition probe failed for'
          . ' audit_log_default: canceling statement due to user request',
        'a failed probe is the month error, on one line, without code locations'
    );

    return;
}

# PostgreSQL's SQLSTATE 55P03 is a lock timeout whatever the message says.
sub _assert_lock_state_retry {
    my $handle = _handle(@DEFAULTS);
    $handle->state($LOCK_STATE);
    $handle->create_errors->{audit_log_2026_09} =
      ['ERROR:  could not obtain lock on relation "audit_log_default"'];
    my $result = _ensure( $handle, retry_pause_ms => 0 );
    ok( $result->{ok}, 'a month refused with SQLSTATE 55P03 is retried' );
    my @retried = qw(begin rollback begin commit);
    is_deeply( [ @{ $handle->transactions }[ 0 .. $#retried ] ],
        \@retried, 'and goes in at the second attempt' );

    return;
}

sub _assert_retry_pause {
    my $handle = _handle(@DEFAULTS);
    $handle->create_errors->{audit_log_2026_09} =
      ['canceling statement due to lock timeout'];
    my $started = Time::HiRes::time();
    _ensure( $handle, retry_pause_ms => $PAUSE_MS );
    cmp_ok( Time::HiRes::time() - $started,
        '>=', $PAUSE_FLOOR, 'a retry waits retry_pause_ms first' );

    return;
}

# The timeouts are interpolated into SET, so only digits get there, and they
# are written as integers.
sub _assert_attribute_checks {
    for my $attribute (qw(lock_timeout_ms statement_timeout_ms lock_wait_ms)) {
        my $handle = _handle(@DEFAULTS);
        my $error  = _error_of(
            sub {
                _ensure( $handle, $attribute => '1; DROP TABLE audit_log' );
            }
        );
        is(
            ( $error =~ s/[ ] at [ ] .* \z//msxr ),
            "partition lifecycle: $attribute must be a positive integer",
            "$attribute must be digits"
        );
        ok(
            GPForum::X::Argument->caught($error),
            "a bad $attribute is an X::Argument"
        );
        is( scalar @{ $handle->statements_like(qr/DROP/msx) },
            0, "and a bad $attribute reaches no SQL" );
    }
    my $handle = _handle(@DEFAULTS);
    _ensure( $handle, lock_timeout_ms => '0500' );
    is( $handle->statements->[0]{sql},
        $DEFAULT_LOCK, 'a timeout is written as an integer' );

    my $result = _ensure( _handle(@DEFAULTS), lock_attempts => 0 );
    is(
        $result->{errors}[0]{error},
        'partition lifecycle: lock_attempts must be a positive integer',
        'lock_attempts of 0 is refused when a month is created'
    );
    is( scalar @{ $result->{created} }, 0, 'and nothing is created' );

    return;
}

# Only a lock timeout skips a run that waits for the lock; anything else
# stops it, after the month transactions' lock_timeout is set back.
sub _assert_wait_failure {
    my $handle = _handle(@DEFAULTS);
    $handle->wait_error('server closed the connection unexpectedly');
    like(
        _error_of( sub { _ensure( $handle, lock_wait_ms => $PAUSE_MS ) } ),
        qr/server [ ] closed [ ] the [ ] connection/msx,
        'a failed wait for the lock stops the run'
    );
    is( $handle->statements->[-1]{sql},
        $DEFAULT_LOCK, 'after the lock_timeout is set back' );

    return;
}

# One month of the window, applied unless apply => 0 is given; any other
# pair is an attribute of the lifecycle.
sub _ensure ( $handle, %options ) {
    my $apply = exists $options{apply} ? delete $options{apply} : 1;

    return GPForum::Service::Operations::PartitionLifecycle->new(%options)
      ->ensure_partitions(
        {
            apply            => $apply,
            dbh              => $handle,
            lookahead_months => 1,
            now_epoch        => $now_epoch,
        }
      );
}

sub _handle (@relations) {
    return GPForum::Test::PartitionPathDbh->new(
        relations => { map { $_ => 1 } @relations } );
}

sub _table_of ($partition) {
    return $partition =~ s/_2026_09\z//msxr;
}

sub _retention_row ( $partition, $range_end, $state = 'created' ) {
    return {
        partition_name => $partition,
        range_end      => $range_end,
        state          => $state,
    };
}

sub _recommended ($row) {
    return { %{$row}, recommended_state => 'detached' };
}

sub _error_of ($code) {
    my $error;
    try {
        $code->();
    }
    catch ($caught) {
        $error = $caught;
    };

    return $error // q{};
}

1;
