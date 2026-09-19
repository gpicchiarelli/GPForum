package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Test::CommunityResultSet;
use GPForum::Test::CommunitySchema;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::ReputationLedger;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::ReputationUpdate;

our $VERSION = '0.001';

const my $POST_CREATED_DELTA   => 1;
const my $POST_HIDDEN_DELTA    => -10;
const my $SUSPENDED_DELTA      => -50;
const my $THREAD_CREATED_DELTA => 2;

my $ledger = GPForum::Test::ReputationLedger->new;
my $sink   = GPForum::Test::WorkerSink->new;
my $posts  = GPForum::Test::CommunityResultSet->new;
$posts->create(
    {
        author_user_id => 'user-author',
        id             => 'post-hidden',
        post_id        => 'post-hidden',
    }
);
my $schema = GPForum::Test::CommunitySchema->new(
    resultsets => {
        Post => $posts,
    },
);

my $handler = GPForum::Worker::Handler::ReputationUpdate->new(
    ledger => $ledger,
    schema => $schema,
    sink   => $sink,
);

ok(
    $handler->supports( { event_type => 'post.created' } ),
    'reputation handler supports created posts'
);
ok(
    $handler->supports( { event_type => 'thread.created' } ),
    'reputation handler supports created threads'
);
ok(
    $handler->supports( { event_type => 'post.hidden' } ),
    'reputation handler supports hidden posts'
);
ok(
    $handler->supports( { event_type => 'post.restored' } ),
    'reputation handler supports restored posts'
);
ok( $handler->supports( { event_type => 'user.suspended' } ),
    'reputation handler supports suspensions' );
ok( $handler->supports( { event_type => 'user.suspension_revoked' } ),
    'reputation handler supports revocation' );
ok( !$handler->supports( { event_type => 'thread.locked' } ),
    'reputation handler ignores lock events' );

my $created = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'post-1',
        aggregate_type => 'post',
        event_id       => 'event-post-1',
        event_type     => 'post.created',
    }
);

is( $created->{action}, 'reputation.record',
    'created post task names reputation recording' );
is( $created->{delta}, $POST_CREATED_DELTA,
    'created post uses the participation delta' );
is( $created->{reason}, 'post_created',
    'created post uses the participation reason' );
is( $ledger->calls->[0]{user_id},
    'user-author', 'created post credits the author actor' );
is( $ledger->calls->[0]{source_type},
    'post', 'created post stores post source type' );
is( $ledger->calls->[0]{source_id},
    'post-1', 'created post stores post source id' );
is( $sink->records->[0]{action},
    'reputation.record', 'created post records a sink task' );

my $hidden = $handler->handle(
    {
        actor_id       => 'moderator-1',
        aggregate_id   => 'post-hidden',
        aggregate_type => 'post',
        event_id       => 'event-hidden-1',
        event_type     => 'post.hidden',
    }
);

is( $hidden->{delta}, $POST_HIDDEN_DELTA,
    'hidden post uses the moderation penalty' );
is( $hidden->{reason}, 'post_hidden', 'hidden post uses the hidden reason' );
is( $ledger->calls->[1]{user_id},
    'user-author', 'hidden post credits the stored author, not the moderator' );
is( $ledger->calls->[1]{actor_id},
    'moderator-1', 'hidden post keeps the moderator as actor' );

my $suspended = $handler->handle(
    {
        actor_id       => 'moderator-1',
        aggregate_id   => 'user-author',
        aggregate_type => 'user',
        event_id       => 'event-suspend-1',
        event_type     => 'user.suspended',
    }
);

is( $suspended->{delta}, $SUSPENDED_DELTA,
    'suspension uses the suspension penalty' );
is( $ledger->calls->[2]{user_id},
    'user-author', 'suspension applies to the suspended user' );

my $orphaned = $handler->handle(
    {
        actor_id       => 'moderator-1',
        aggregate_id   => 'post-missing',
        aggregate_type => 'post',
        event_id       => 'event-hidden-2',
        event_type     => 'post.hidden',
    }
);

is( $orphaned->{recorded}{skipped},
    1, 'hidden post without an author is skipped' );
is( $orphaned->{recorded}{reason},
    'missing_subject', 'skip reason is missing_subject' );
is( scalar @{ $ledger->calls },
    3, 'skipped hidden post does not call the ledger' );

my $transport =
  GPForum::Service::Outbox::DomainEventTransport->new( handlers => [$handler],
  );
my $dispatch = $transport->dispatch(
    GPForum::Test::OutboxPayloadRow->new(
        data => {
            payload => {
                actor_id       => 'user-author',
                aggregate_id   => 'thread-1',
                aggregate_type => 'thread',
                event_id       => 'event-thread-1',
                event_type     => 'thread.created',
                payload        => { author_user_id => 'user-author' },
            },
        },
    )
);

is( $dispatch->{handlers}, 1,
    'outbox transport dispatches reputation handler' );
is( $ledger->calls->[-1]{reason},
    'thread_created', 'normalized thread event records thread reputation' );
is( $ledger->calls->[-1]{delta},
    $THREAD_CREATED_DELTA,
    'created thread uses the thread participation delta' );

done_testing();

1;
