package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::Id;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxTransport;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $NOW            => '2026-05-23T12:00:00Z';
const my $STALE_LOCK     => '2026-05-23T11:59:00Z';
const my $FUTURE_LOCK    => '2026-05-23T12:01:00Z';
const my $RECLAIM_AT     => '2026-05-23T12:02:00Z';
const my $RECLAIM_FUTURE => '2026-05-23T12:03:00Z';
const my $HELD_LOCK      => '2026-05-23T12:30:00Z';
const my $STALE_OUTBOX   => '018f9999-0001-7000-8000-00000000d001';
const my $STALE_EVENT    => '018f9999-0001-7000-8000-00000000d101';
const my $FRESH_OUTBOX   => '018f9999-0001-7000-8000-00000000d002';
const my $FRESH_EVENT    => '018f9999-0001-7000-8000-00000000d102';
const my $CRASH_OUTBOX   => '018f9999-0001-7000-8000-00000000d003';
const my $CRASH_EVENT    => '018f9999-0001-7000-8000-00000000d103';
const my $INSERT_SQL => join q{ },
  'INSERT INTO outbox_messages (',
  'outbox_id, event_id, queue, job_type, idempotency_key, payload,',
  'available_at, created_at, status, next_attempt_at, locked_by, locked_until,',
  'locked_at, attempt_count, attempts',
  ') VALUES (',
  '?, ?, ?, ?, ?, ?::jsonb, ?::timestamptz, ?::timestamptz, ?, ?::timestamptz,',
  '?, ?::timestamptz, ?::timestamptz, 0, 0',
  ')';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the PostgreSQL outbox reclaim test';
}

local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

my $migrate = GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply'); } );
is( $migrate, 0, 'migrations apply to a clean PostgreSQL database' );

_assert_stale_running_reclaim_race($database);
_assert_fresh_running_lock_is_not_claimed($database);
_assert_claim_crash_then_reclaim_two_connections($database);

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _assert_stale_running_reclaim_race {
    my ($database_info) = @_;

    _insert_outbox(
        $database_info->{dbh},
        {
            outbox_id       => $STALE_OUTBOX,
            event_id        => $STALE_EVENT,
            idempotency_key => 'outbox-reclaim-stale',
            status          => 'running',
            locked_by       => 'crashed-worker',
            locked_until    => $STALE_LOCK,
            locked_at       => $STALE_LOCK,
            next_attempt_at => $STALE_LOCK,
        }
    );

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my ($slot) = @_;
            return _dispatch_once(
                {
                    now       => $NOW,
                    future    => $FUTURE_LOCK,
                    worker_id => "reclaim-worker-$slot",
                }
            );
        }
    );
    _assert_workers_ok( \@outcomes, 'stale running reclaim race' );

    my @selected =
      grep { $_->{selected} } map { $_->{result} } @outcomes;
    is( scalar @selected,
        1, 'exactly one worker reclaims the expired running lock' );
    is( $selected[0]{dispatched},
        1, 'reclaiming worker dispatches the message once' );
    is_deeply(
        [ sort map { @{ $_->{result}{delivered} } } @outcomes ],
        [$STALE_OUTBOX],
        'stale running reclaim delivers the outbox id once across workers'
    );
    is( _outbox_status( $database_info->{dbh}, $STALE_OUTBOX ),
        'done', 'stale running reclaim marks the row done' );
    is( _outbox_locked_by( $database_info->{dbh}, $STALE_OUTBOX ),
        undef, 'done reclaim clears locked_by' );

    return;
}

sub _assert_fresh_running_lock_is_not_claimed {
    my ($database_info) = @_;

    _insert_outbox(
        $database_info->{dbh},
        {
            outbox_id       => $FRESH_OUTBOX,
            event_id        => $FRESH_EVENT,
            idempotency_key => 'outbox-reclaim-fresh',
            status          => 'running',
            locked_by       => 'active-worker',
            locked_until    => $HELD_LOCK,
            locked_at       => $NOW,
            next_attempt_at => $NOW,
        }
    );

    my $result = _dispatch_once(
        {
            now       => $NOW,
            future    => $FUTURE_LOCK,
            worker_id => 'other-worker',
        }
    );
    is( $result->{selected}, 0, 'fresh running lock is not claimed' );
    is_deeply( $result->{delivered}, [],
        'fresh running lock is not delivered' );
    is( _outbox_status( $database_info->{dbh}, $FRESH_OUTBOX ),
        'running', 'fresh running lock stays running' );
    is( _outbox_locked_by( $database_info->{dbh}, $FRESH_OUTBOX ),
        'active-worker', 'fresh running lock keeps the original claimant' );

    return;
}

sub _assert_claim_crash_then_reclaim_two_connections {
    my ($database_info) = @_;

    _insert_outbox(
        $database_info->{dbh},
        {
            outbox_id       => $CRASH_OUTBOX,
            event_id        => $CRASH_EVENT,
            idempotency_key => 'outbox-reclaim-crash',
            status          => 'pending',
            locked_by       => undef,
            locked_until    => undef,
            locked_at       => undef,
            next_attempt_at => $NOW,
        }
    );

    my $crashed = _dispatcher(
        {
            now       => $NOW,
            future    => $FUTURE_LOCK,
            worker_id => 'claim-crash-worker',
            transport => GPForum::Test::OutboxTransport->new,
        }
    );
    my @claimed = $crashed->claim_ready_batch(1);
    is( scalar @claimed, 1, 'pending row is claimed before the crash' );
    is( _outbox_status( $database_info->{dbh}, $CRASH_OUTBOX ),
        'running', 'crash after claim leaves the row running on PostgreSQL' );
    is( _outbox_locked_by( $database_info->{dbh}, $CRASH_OUTBOX ),
        'claim-crash-worker',
        'crash after claim keeps the claimant lock on PostgreSQL' );

    my $fresh = _dispatch_once(
        {
            now       => $NOW,
            future    => $FUTURE_LOCK,
            worker_id => 'recovery-worker',
        }
    );
    is( $fresh->{selected}, 0,
        'second connection does not take a fresh claim lock' );
    is_deeply( $fresh->{delivered}, [],
        'second connection does not dispatch before lock expiry' );

    my $recovered = _dispatch_once(
        {
            now       => $RECLAIM_AT,
            future    => $RECLAIM_FUTURE,
            worker_id => 'recovery-worker',
        }
    );
    is( $recovered->{selected},
        1, 'second connection reclaims after locked_until expires' );
    is( $recovered->{dispatched},
        1, 'second connection dispatches the reclaimed row once' );
    is_deeply( $recovered->{delivered},
        [$CRASH_OUTBOX], 'claim-crash recovery delivers the outbox id once' );
    is( _outbox_status( $database_info->{dbh}, $CRASH_OUTBOX ),
        'done', 'claim-crash recovery acknowledges the row on PostgreSQL' );

    return;
}

sub _dispatch_once {
    my ($input) = @_;

    my $transport  = GPForum::Test::OutboxTransport->new;
    my $dispatcher = _dispatcher(
        {
            %{$input}, transport => $transport,
        }
    );
    my $summary = $dispatcher->dispatch_pending(1);

    return {
        delivered  => [ @{ $transport->delivered } ],
        dispatched => $summary->{dispatched},
        selected   => $summary->{selected},
    };
}

sub _dispatcher {
    my ($input) = @_;

    return GPForum::Service::Outbox::Dispatcher->new(
        clock => GPForum::Test::OutboxClock->new(
            now    => $input->{now},
            future => $input->{future},
        ),
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::PostgresHarness::connect_schema(),
        transport  => $input->{transport},
        worker_id  => $input->{worker_id},
    );
}

sub _insert_outbox {
    my ( $dbh, $row ) = @_;

    $dbh->do(
        $INSERT_SQL,
        undef,
        $row->{outbox_id},
        $row->{event_id},
        'domain',
        'test.dispatch',
        $row->{idempotency_key},
        encode_json( { event_id => $row->{event_id} } ),
        $NOW,
        $NOW,
        $row->{status},
        $row->{next_attempt_at},
        $row->{locked_by},
        $row->{locked_until},
        $row->{locked_at},
    );

    return;
}

sub _outbox_status {
    my ( $dbh, $outbox_id ) = @_;

    my ($status) = $dbh->selectrow_array(
        'SELECT status FROM outbox_messages WHERE outbox_id = ?',
        undef, $outbox_id );

    return $status;
}

sub _outbox_locked_by {
    my ( $dbh, $outbox_id ) = @_;

    my ($locked_by) = $dbh->selectrow_array(
        'SELECT locked_by FROM outbox_messages WHERE outbox_id = ?',
        undef, $outbox_id );

    return $locked_by;
}

sub _assert_workers_ok {
    my ( $outcomes, $label ) = @_;

    for my $outcome ( @{$outcomes} ) {
        ok( $outcome->{ok}, "$label worker succeeded" )
          or diag( $outcome->{error} // 'missing worker error' );
    }

    return;
}

1;
