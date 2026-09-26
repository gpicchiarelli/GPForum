# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::Id;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxRow;
use GPForum::Test::OutboxSchema;
use GPForum::Test::OutboxTransport;

our $VERSION = '0.001';

const my @WORKER_COUNTS   => ( 2, 4, 8 );
const my $BATCH_SIZE      => 3;
const my $MESSAGE_COUNT   => 24;
const my $READY_AT        => '2026-05-23T12:00:00Z';
const my $STALE_LOCK      => '2026-05-23T11:59:00Z';
const my $FUTURE_LOCK     => '2026-05-23T12:01:00Z';
const my $DEFAULT_ATTEMPT => 0;

for my $worker_count (@WORKER_COUNTS) {
    _assert_pool_delivers_once($worker_count);
    _assert_claim_wave_is_unique($worker_count);
}

_assert_retry_backoff();
_assert_stale_lock_recovery();
_assert_fresh_running_lock_is_not_claimed();
_assert_crash_between_claim_and_dispatch();
_assert_benchmark_json_smoke();

done_testing();

sub _assert_pool_delivers_once {
    my ($worker_count) = @_;

    my @rows      = _ready_rows( "pool-$worker_count", $MESSAGE_COUNT );
    my $schema    = _schema_for_rows(@rows);
    my $transport = GPForum::Test::OutboxTransport->new;
    my @workers   = _dispatchers( $schema, $transport, $worker_count );

    _drain_pool(@workers);

    is( scalar @{ $transport->delivered },
        $MESSAGE_COUNT, "$worker_count workers deliver every ready message" );
    is( _duplicate_count( $transport->delivered ),
        0, "$worker_count workers produce zero duplicate deliveries" );

    return;
}

sub _assert_claim_wave_is_unique {
    my ($worker_count) = @_;

    my @rows      = _ready_rows( "claim-$worker_count", $MESSAGE_COUNT );
    my $schema    = _schema_for_rows(@rows);
    my $transport = GPForum::Test::OutboxTransport->new;
    my @workers   = _dispatchers( $schema, $transport, $worker_count );
    my @claimed   = map { $_->claim_ready_batch($BATCH_SIZE) } @workers;

    is(
        scalar @claimed,
        $worker_count * $BATCH_SIZE,
        "$worker_count workers claim disjoint batches"
    );
    is( _duplicate_count( [ map { $_->get_column('outbox_id') } @claimed ] ),
        0, "$worker_count workers never claim the same outbox id" );

    return;
}

sub _assert_retry_backoff {
    my $row          = _ready_row('retry-1');
    my $dead_letters = GPForum::Test::OutboxCreateResultSet->new;
    my $schema       = _schema_for_rows_and_dead_letters( $dead_letters, $row );
    my $transport =
      GPForum::Test::OutboxTransport->new( fail_ids => { 'retry-1' => 1 } );
    my $dispatcher = _dispatcher( $schema, $transport, 'retry-worker' );
    my $summary    = $dispatcher->dispatch_pending(1);

    is( $summary->{failed}, 1, 'retryable failure is counted' );
    is( $summary->{dead_lettered}, 0,
        'retryable failure is not dead-lettered' );
    is( $row->get_column('status'), 'failed', 'retryable row remains failed' );
    is( $row->get_column('attempt_count'),
        1, 'retryable row increments attempt count' );
    is( $row->get_column('next_attempt_at'),
        $FUTURE_LOCK, 'retryable row schedules backoff' );
    is( scalar @{ $dead_letters->created },
        0, 'retryable row does not create a dead letter' );

    return;
}

sub _assert_stale_lock_recovery {
    my $row = _ready_row(
        'stale-1',
        {
            status       => 'running',
            locked_by    => 'old-worker',
            locked_until => $STALE_LOCK,
        }
    );
    my $schema     = _schema_for_rows($row);
    my $transport  = GPForum::Test::OutboxTransport->new;
    my $dispatcher = _dispatcher( $schema, $transport, 'new-worker' );
    my $summary    = $dispatcher->dispatch_pending(1);

    is( $summary->{selected}, 1, 'stale running row is claimed' );
    is_deeply( $transport->delivered,
        ['stale-1'], 'stale running row is delivered once' );
    is( $row->updates->[0]{locked_by},
        'new-worker', 'stale running row is relocked by current worker' );
    is( $row->get_column('status'),
        'done', 'stale running row completes after recovery' );

    return;
}

sub _assert_fresh_running_lock_is_not_claimed {
    my $row = _ready_row(
        'fresh-1',
        {
            status       => 'running',
            locked_by    => 'active-worker',
            locked_until => $FUTURE_LOCK,
        }
    );
    my $schema     = _schema_for_rows($row);
    my $transport  = GPForum::Test::OutboxTransport->new;
    my $dispatcher = _dispatcher( $schema, $transport, 'other-worker' );
    my $summary    = $dispatcher->dispatch_pending(1);

    is( $summary->{selected}, 0, 'fresh running row is not claimed' );
    is_deeply( $transport->delivered,
        [], 'fresh running row is not delivered by another worker' );

    return;
}

sub _assert_crash_between_claim_and_dispatch {
    my $row       = _ready_row('claim-crash-1');
    my $schema    = _schema_for_rows($row);
    my $transport = GPForum::Test::OutboxTransport->new;
    my $clock     = GPForum::Test::OutboxClock->new;
    my $crashed   = GPForum::Service::Outbox::Dispatcher->new(
        clock      => $clock,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
        transport  => $transport,
        worker_id  => 'crashed-worker',
    );
    my @claimed = $crashed->claim_ready_batch(1);

    is( scalar @claimed, 1, 'pending row is claimed before the crash' );
    is( $row->get_column('status'),
        'running', 'crash after claim leaves the row running' );
    is( $row->get_column('locked_by'),
        'crashed-worker', 'crash after claim keeps the claimant lock' );
    is_deeply( $transport->delivered, [],
        'crash after claim does not dispatch' );

    my $other = GPForum::Service::Outbox::Dispatcher->new(
        clock      => $clock,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
        transport  => $transport,
        worker_id  => 'other-worker',
    );
    my $fresh = $other->dispatch_pending(1);
    is( $fresh->{selected}, 0, 'fresh lock after claim crash is not taken' );
    is_deeply( $transport->delivered, [],
        'fresh lock after claim crash is not delivered' );

    $clock->now($FUTURE_LOCK);
    my $recovered = $other->dispatch_pending(1);
    is( $recovered->{selected}, 1,
        'stale lock after claim crash is reclaimed' );
    is( $recovered->{dispatched},
        1, 'stale lock after claim crash is dispatched' );
    is_deeply( $transport->delivered,
        ['claim-crash-1'], 'claim crash recovery delivers once' );
    is( $row->get_column('status'),
        'done', 'claim crash recovery acknowledges the row' );

    return;
}

sub _drain_pool {
    my (@workers) = @_;

    while (1) {
        my $selected = 0;
        for my $worker (@workers) {
            $selected += $worker->dispatch_pending($BATCH_SIZE)->{selected};
        }
        last if !$selected;
    }

    return;
}

sub _dispatchers {
    my ( $schema, $transport, $worker_count ) = @_;

    return
      map { _dispatcher( $schema, $transport, "worker-$_" ) }
      ( 1 .. $worker_count );
}

sub _dispatcher {
    my ( $schema, $transport, $worker_id ) = @_;

    return GPForum::Service::Outbox::Dispatcher->new(
        schema     => $schema,
        transport  => $transport,
        clock      => GPForum::Test::OutboxClock->new,
        id_service => GPForum::Test::Id->new,
        worker_id  => $worker_id,
    );
}

sub _schema_for_rows {
    my (@rows) = @_;

    return _schema_for_rows_and_dead_letters(
        GPForum::Test::OutboxCreateResultSet->new, @rows );
}

sub _schema_for_rows_and_dead_letters {
    my ( $dead_letters, @rows ) = @_;

    return GPForum::Test::OutboxSchema->new(
        outbox_resultset =>
          GPForum::Test::OutboxResultSet->new( rows => \@rows ),
        dead_letter_resultset => $dead_letters,
    );
}

sub _ready_rows {
    my ( $prefix, $count ) = @_;

    return map { _ready_row("$prefix-$_") } ( 1 .. $count );
}

sub _ready_row {
    my ( $outbox_id, $overrides ) = @_;

    my %data = (
        outbox_id       => $outbox_id,
        attempt_count   => $DEFAULT_ATTEMPT,
        next_attempt_at => $READY_AT,
        created_at      => $READY_AT,
        %{ $overrides || {} },
    );

    return GPForum::Test::OutboxRow->new( data => \%data );
}

sub _duplicate_count {
    my ($values) = @_;

    my %seen;
    my $duplicates = 0;
    for my $value ( @{$values} ) {
        if ( $seen{$value} ) {
            $duplicates++;
        }
        $seen{$value} = 1;
    }

    return $duplicates;
}

sub _assert_benchmark_json_smoke {
    my $output = _capture_command( 'script/bench-outbox-dispatcher',
        '--messages', '12', '--workers', '1,2', '--batch-size', '3',
        '--json', );
    my $report = decode_json($output);

    is( $report->{status}, 'ok', 'outbox benchmark reports ok status' );
    is( scalar @{ $report->{results} },
        2, 'outbox benchmark covers requested worker matrix' );
    is( $report->{results}[0]{duplicates},
        0, 'outbox benchmark reports zero duplicates' );
    is( $report->{results}[0]{lost},
        0, 'outbox benchmark reports zero lost messages' );
    ok(
        exists $report->{results}[0]{p95_claim_ms},
        'outbox benchmark reports claim latency'
    );

    return;
}

sub _capture_command {
    my (@command) = @_;

    open my $handle, q{-|}, @command
      or croak 'failed to run outbox benchmark';

    my $captured = q{};
    while ( my $line = <$handle> ) {
        $captured .= $line;
    }

    close $handle
      or croak 'outbox benchmark failed';

    return $captured;
}

1;
