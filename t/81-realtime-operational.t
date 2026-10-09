# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::PgListener;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Service::Realtime::SubscriptionPolicy;
use GPForum::Test::FixedClock;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::RealtimeId;
use GPForum::Test::RealtimePermissionEngine;
use GPForum::Test::RealtimePgDbh;
use GPForum::Test::RealtimePgSchema;
use GPForum::Test::RealtimePolicySchema;
use GPForum::Test::RealtimeReadability;
use GPForum::Test::ScriptedParticipation;

our $VERSION = '0.001';

const my $QUEUED_NOTIFICATIONS  => 3;
const my $OVERSIZED_BODY_LENGTH => 600;

my $envelope = GPForum::Service::Realtime::EventEnvelope->new(
    clock =>
      GPForum::Test::FixedClock->new( iso8601 => '2026-05-28T12:00:00Z' ),
    id_service        => GPForum::Test::RealtimeId->new,
    max_payload_bytes => 512,
);
my $event = $envelope->build(
    type           => 'thread.update',
    aggregate_type => 'thread',
    aggregate_id   => 'thread-1',
    actor_id       => 'user-1',
    payload        => { post_id => 'post-1' },
);

is( $event->{schema_version}, 1, 'realtime event defaults schema version' );
is( $event->{occurred_at},
    '2026-05-28T12:00:00Z', 'realtime event has occurred timestamp' );
is( $event->{type}, 'thread.update', 'realtime event has type' );

my $serialized = $envelope->serialize($event);
ok( $serialized->{ok},        'realtime event serializes' );
ok( $serialized->{bytes} > 0, 'realtime event reports serialized size' );
ok(
    !$envelope->deserialize('{bad-json')->{ok},
    'realtime event rejects malformed JSON'
);
ok(
    !$envelope->serialize(
        $envelope->build(
            type           => 'thread.update',
            aggregate_type => 'thread',
            aggregate_id   => 'thread-1',
            payload        => { body => 'x' x $OVERSIZED_BODY_LENGTH },
        )
    )->{ok},
    'realtime event rejects oversized payloads'
);

my $policy_schema = GPForum::Test::RealtimePolicySchema->new(
    users => {
        'user-1'         => { id => 'user-1',         status => 'active' },
        'user-suspended' => { id => 'user-suspended', status => 'suspended' },
    },
);
my $readability = GPForum::Test::RealtimeReadability->new(
    readable => {
        'thread-1'       => { 'user-1' => 1, 'user-suspended' => 1 },
        'thread-members' => { 'user-1' => 1 },
    },
);
my $policy = GPForum::Service::Realtime::SubscriptionPolicy->new(
    readability => $readability,
    schema      => $policy_schema,
);

ok(
    $policy->permits(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-1' }, {},
    )->{ok},
    'subscription policy allows a thread its reader can read'
);
is(
    $policy->permits(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-hidden' }, {},
    )->{reason},
    'invisible_resource',
    'subscription policy denies a thread its reader cannot read'
);
is(
    $policy->permits(
        { user_id => 'user-suspended' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-1' }, {},
    )->{reason},
    'forbidden',
    'subscription policy denies suspended users'
);
ok(
    $policy->permits(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-members' }, {},
    )->{ok},
    'subscription policy asks readability, not the thread\'s own visibility'
);
is(
    GPForum::Service::Realtime::SubscriptionPolicy->new(
        schema => $policy_schema
    )->permits(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-1' }, {},
    )->{reason},
    'invisible_resource',
    'and without readability a thread channel fails closed'
);

# The suspension check ignored a failing store: while it errored, a member
# suspended from participating could still subscribe. It fails closed now.
for my $case (
    [ 'errors',          sub { die "suspension store unavailable\n" } ],
    [ 'answers nothing', sub { return; } ],
    [ 'denies',          sub { return { ok => 0, reason => 'suspended' } } ],
  )
{
    my ( $label, $answer ) = @{$case};
    is(
        GPForum::Service::Realtime::SubscriptionPolicy->new(
            readability      => $readability,
            schema           => $policy_schema,
            suspension_store =>
              GPForum::Test::ScriptedParticipation->new( answer => $answer ),
        )->permits(
            { user_id => 'user-1' }, 'realtime.subscribe',
            { type    => 'thread', id => 'thread-1' }, {},
        )->{reason},
        'forbidden',
        "a subscription is denied when the suspension store $label"
    );
}
ok(
    GPForum::Service::Realtime::SubscriptionPolicy->new(
        readability      => $readability,
        schema           => $policy_schema,
        suspension_store => GPForum::Test::ScriptedParticipation->new(
            answer => sub { return { ok => 1 } }
        ),
    )->permits(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-1' }, {},
    )->{ok},
    'and allowed when it says the member may participate'
);

# ADR 0102: every broadcast on a thread channel asks again who may read the
# thread; a subscriber who no longer can is unsubscribed and sent nothing.
my $guarded_hub = GPForum::Service::Realtime::Hub->new(
    authorizer => GPForum::Service::Realtime::ChannelAuthorizer->new(
        permission_engine => GPForum::Test::RealtimePermissionEngine->new,
    ),
    readability => $readability,
    registry    => GPForum::Service::Realtime::ConnectionRegistry->new,
);
my %guarded_connection;
for my $user (qw(user-1 user-2)) {
    $guarded_connection{$user} = GPForum::Test::RealtimeConnection->new;
    $guarded_hub->register_connection(
        "guarded-$user",
        { user_id => $user },
        $guarded_connection{$user}
    );
    $guarded_hub->subscribe(
        {
            actor         => { user_id => $user },
            channel       => 'thread:thread-members',
            connection_id => "guarded-$user",
        }
    );
}
is(
    $guarded_hub->broadcast( 'thread:thread-members', { type => 'x' } )
      ->{delivered},
    1,
    'a thread broadcast reaches only the subscribers who can read it'
);
is_deeply(
    [ map { scalar @{ $guarded_connection{$_}->sent } } qw(user-1 user-2) ],
    [ 1, 0 ],
    'the reader receives it and the other subscriber does not'
);
is_deeply(
    [
        sort map { $_->{connection_id} }
          $guarded_hub->registry->subscribers('thread:thread-members')
    ],
    [ 'guarded-user-1', 'guarded-user-2' ],
    'but stays subscribed: access is asked again at every broadcast'
);
$readability->readable->{'thread-members'}{'user-2'} = 1;
is(
    $guarded_hub->broadcast( 'thread:thread-members', { type => 'x' } )
      ->{delivered},
    2,
    'so a subscriber who regains access (a thread restored) resumes'
);

# An event about one post names the post and its author: only readers of the
# post receive it, though both read the thread.
$readability->readable->{'post-private'} = { 'user-1' => 1 };
is(
    $guarded_hub->broadcast( 'thread:thread-members',
        { type => 'thread.update', payload => { post_id => 'post-private' } } )
      ->{delivered},
    1,
    'a private reply is announced only to those who can read it'
);

my $dbh      = GPForum::Test::RealtimePgDbh->new;
my $schema   = GPForum::Test::RealtimePgSchema->new( dbh => $dbh );
my $notifier = GPForum::Service::Realtime::PgNotifier->new(
    event_contract => $envelope,
    schema         => $schema,
);
my $notify = $notifier->notify($event);
ok( $notify->{ok}, 'PostgreSQL notifier emits realtime event' );
like( $dbh->statements->[0][0],
    qr/pg_notify/msx, 'PostgreSQL notifier uses pg_notify' );

my $degraded_notify =
  GPForum::Service::Realtime::PgNotifier->new( event_contract => $envelope )
  ->notify($event);
ok( !$degraded_notify->{ok}, 'notifier degrades when DB is unavailable' );
is( $degraded_notify->{failure_type},
    'transport', 'notifier degraded failure is classified as transport' );

my $hub = GPForum::Service::Realtime::Hub->new(
    event_contract => $envelope,
    registry       => GPForum::Service::Realtime::ConnectionRegistry->new,
    authorizer     => GPForum::Service::Realtime::ChannelAuthorizer->new(
        permission_engine => GPForum::Test::RealtimePermissionEngine->new,
    ),
);
my $connection = GPForum::Test::RealtimeConnection->new;
$hub->register_connection( 'connection-1', { user_id => 'user-1' },
    $connection );
$hub->subscribe(
    {
        actor         => { user_id => 'user-1' },
        channel       => 'thread:thread-1',
        connection_id => 'connection-1',
        context       => {},
    }
);

my $listener_dbh = GPForum::Test::RealtimePgDbh->new(
    notifies => [
        [ 'gpforum_domain_events', 1, $serialized->{json} ],
        [ 'gpforum_domain_events', 1, $serialized->{json} ],
        [ 'gpforum_domain_events', 1, '{bad-json' ],
    ],
);
my $listener = GPForum::Service::Realtime::PgListener->new(
    event_contract => $envelope,
    hub            => $hub,
    schema => GPForum::Test::RealtimePgSchema->new( dbh => $listener_dbh ),
);
ok( $listener->start->{ok}, 'PostgreSQL listener starts LISTEN lifecycle' );
my $poll = $listener->poll_once;
is( $poll->{received},
    $QUEUED_NOTIFICATIONS, 'listener receives queued notifications' );
is( $poll->{delivered},  1, 'listener fans out valid event once' );
is( $poll->{duplicates}, 1, 'listener suppresses duplicate event ids' );
is( $poll->{invalid},    1, 'listener rejects malformed payload' );
is( scalar @{ $connection->sent }, 1, 'websocket receives one event' );
is( $listener->snapshot->{listen_notify_received},
    $QUEUED_NOTIFICATIONS, 'listener exposes received LISTEN/NOTIFY metric' );

$listener->reconnect;
is( $listener->snapshot->{reconnect_count},
    1, 'listener records reconnect count' );

my $degraded_listener = GPForum::Service::Realtime::PgListener->new;
ok( !$degraded_listener->start->{ok},
    'listener degrades when DB is unavailable' );
is( $degraded_listener->snapshot->{status},
    'degraded', 'listener exposes degraded status' );

done_testing();

1;
