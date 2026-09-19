package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Outbox::ClaimQuery;
use GPForum::Service::Outbox::ClaimedMessage;
use GPForum::Service::Outbox::FailureType;
use GPForum::Service::Outbox::Retry;
use GPForum::Test::OutboxFailure;
use GPForum::Test::OutboxRow;
use Test::More;

our $VERSION = '0.001';

const my $LIMIT_BIND_INDEX  => 6;
const my $WORKER_BIND_INDEX => 9;
const my $LOCK_SECONDS      => 60;
const my $DEFAULT_MAX       => 5;
const my $CUSTOM_MAX        => 2;
const my $RETRY_ATTEMPT     => 3;
const my $NEXT_ATTEMPT      => 4;
const my $BACKOFF_SECONDS   => 180;

my $types = GPForum::Service::Outbox::FailureType->new;
is( $types->classify('boom'),
    'transient', 'unmatched exceptions classify as transient' );
is( $types->classify( GPForum::Test::OutboxFailure->new('serial timeout') ),
    'serialization', 'serial error text classifies as serialization' );
is( $types->classify( GPForum::Test::OutboxFailure->new('forbidden') ),
    'authorization', 'forbidden error text classifies as authorization' );
is( $types->classify( GPForum::Test::OutboxFailure->new('unauthorised') ),
    'authorization', 'unauthorised error text classifies as authorization' );
is( $types->classify( GPForum::Test::OutboxFailure->new('transport closed') ),
    'transport', 'transport error text classifies as transport' );
is( $types->classify( GPForum::Test::OutboxFailure->new('notify failed') ),
    'transport', 'notify error text classifies as transport' );
is( $types->classify( GPForum::Test::OutboxFailure->new('permanent reject') ),
    'permanent', 'permanent error text classifies as permanent' );
is( $types->classify( bless {}, 'GPForum::Test::SerialCase' ),
    'serialization', 'Serial class names classify as serialization' );
is( $types->classify( bless {}, 'GPForum::Test::AuthorizationDenied' ),
    'authorization', 'Authorization class names classify as authorization' );
is( $types->classify( bless {}, 'GPForum::Test::AuthorisationDenied' ),
    'authorization', 'Authorisation class names classify as authorization' );
is( $types->classify( bless {}, 'GPForum::Test::TransportBroke' ),
    'transport', 'Transport class names classify as transport' );
is( $types->classify( bless {}, 'GPForum::Test::PermanentFail' ),
    'permanent', 'Permanent class names classify as permanent' );
is(
    $types->classify(
        GPForum::Test::OutboxFailure->new( 'serial timeout', 'permanent' )
    ),
    'permanent',
    'declared failure_type wins over regex rules'
);

my $retry = GPForum::Service::Outbox::Retry->new;
is(
    $retry->next_attempt(
        GPForum::Test::OutboxRow->new( data => { attempt_count => 0 } )
    ),
    1,
    'retry starts attempt counts from zero'
);
is(
    $retry->next_attempt(
        GPForum::Test::OutboxRow->new(
            data => { attempt_count => $RETRY_ATTEMPT }
        )
    ),
    $NEXT_ATTEMPT,
    'retry increments the stored attempt count'
);
is( $retry->status($RETRY_ATTEMPT),
    'failed', 'retry keeps status failed before the attempt ceiling' );
is( $retry->status($DEFAULT_MAX),
    'cancelled', 'retry cancels when attempts reach the default ceiling' );
is(
    GPForum::Service::Outbox::Retry->new( max_attempts => $CUSTOM_MAX )
      ->status($CUSTOM_MAX),
    'cancelled',
    'retry cancels when attempts reach a custom ceiling'
);
is( $retry->backoff_seconds($RETRY_ATTEMPT),
    $BACKOFF_SECONDS, 'retry backoff is attempt count times the lock quantum' );
is( $retry->lock_seconds,
    $LOCK_SECONDS, 'retry lock duration matches the claim lock quantum' );
ok( $retry->is_cancelled('cancelled'),
    'retry treats cancelled as a terminal status' );
ok( !$retry->is_cancelled('failed'),
    'retry does not treat failed as a terminal status' );

my $query = GPForum::Service::Outbox::ClaimQuery->new;
like(
    $query->sql,
    qr/FOR [ ] UPDATE [ ] SKIP [ ] LOCKED/msx,
    'claim SQL uses FOR UPDATE SKIP LOCKED'
);
my $stable_claim_order =
  'ORDER BY next_attempt_at ASC, created_at ASC, outbox_id ASC';
ok(
    index( $query->sql, $stable_claim_order ) >= 0,
    'claim SQL uses stable ready-queue ordering'
);
is( $query->pending_status, 'pending', 'claim query exposes pending status' );
is( $query->failed_status,  'failed',  'claim query exposes failed status' );
is( $query->running_status, 'running', 'claim query exposes running status' );

my $bind = $query->bind_values(
    {
        limit        => 1,
        locked_until => '2026-05-23T12:01:00Z',
        now          => '2026-05-23T12:00:00Z',
        worker_id    => 'pg-worker',
    }
);
is( $bind->[0], 'pending', 'claim bind starts with pending status' );
is( $bind->[1], 'failed',  'claim bind includes failed status' );
is( $bind->[$LIMIT_BIND_INDEX],
    1, 'claim bind keeps the caller limit at the dispatcher index' );
is( $bind->[$WORKER_BIND_INDEX],
    'pg-worker', 'claim bind keeps the worker id at the dispatcher index' );
is( $bind->[-1], '2026-05-23T12:01:00Z',
    'claim bind ends with the lock expiry timestamp' );

my $object_message = GPForum::Service::Outbox::ClaimedMessage->new(
    row => { payload => '{"event_id":"event-1"}' }, );
is_deeply(
    $object_message->get_column('payload'),
    { event_id => 'event-1' },
    'claimed message decodes JSON object payloads'
);

my $scalar_message = GPForum::Service::Outbox::ClaimedMessage->new(
    row => { payload => '"not-an-object"' }, );
is_deeply( $scalar_message->get_column('payload'), {},
    'claimed message rejects non-object JSON after allow_nonref default change'
);

my $array_message = GPForum::Service::Outbox::ClaimedMessage->new(
    row => { payload => '["event-1"]' }, );
is_deeply( $array_message->get_column('payload'),
    {}, 'claimed message rejects JSON arrays as outbox payloads' );

done_testing();

1;
