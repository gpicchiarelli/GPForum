# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

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
use GPForum::Test::FeedProjector;
use GPForum::Test::FixedClock;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::SubscriberLookup;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::FeedProjection;

our $VERSION = '0.001';

const my $PROJECTED_USERS => 2;
const my $PROJECTED_ITEMS => 3;

my $projector   = GPForum::Test::FeedProjector->new;
my $subscribers = GPForum::Test::SubscriberLookup->new;
my $sink        = GPForum::Test::WorkerSink->new;
my $clock       = GPForum::Test::FixedClock->new;
my $posts       = GPForum::Test::CommunityResultSet->new;
$posts->create(
    {
        author_user_id => 'user-author',
        id             => 'post-hidden',
        thread_id      => 'thread-9',
    }
);
my $threads = GPForum::Test::CommunityResultSet->new;
$threads->create(
    {
        author_user_id => 'user-author',
        id             => 'thread-1',
        thread_id      => 'thread-1',
    }
);
my $schema = GPForum::Test::CommunitySchema->new(
    resultsets => {
        Post   => $posts,
        Thread => $threads,
    },
);
$subscribers->user_ids( [ 'user-author', 'user-follower', 'user-author' ] );

my $handler = GPForum::Worker::Handler::FeedProjection->new(
    clock              => $clock,
    projector          => $projector,
    schema             => $schema,
    sink               => $sink,
    subscription_store => $subscribers,
);

ok( $handler->supports( { event_type => 'post.created' } ),
    'feed handler supports created posts' );
ok( $handler->supports( { event_type => 'thread.created' } ),
    'feed handler supports created threads' );
ok( $handler->supports( { event_type => 'post.hidden' } ),
    'feed handler supports hidden posts' );
ok( $handler->supports( { event_type => 'post.restored' } ),
    'feed handler supports restored posts' );
ok( $handler->supports( { event_type => 'post.updated' } ),
    'feed handler supports updated posts' );
ok( $handler->supports( { event_type => 'post.deleted' } ),
    'feed handler supports deleted posts' );
ok( $handler->supports( { event_type => 'post.undeleted' } ),
    'feed handler supports undeleted posts' );
ok( $handler->supports( { event_type => 'thread.deleted' } ),
    'feed handler supports deleted threads' );
ok( $handler->supports( { event_type => 'thread.hidden' } ),
    'feed handler supports hidden threads' );
ok( $handler->supports( { event_type => 'thread.restored' } ),
    'feed handler supports restored threads' );
ok( $handler->supports( { event_type => 'thread.undeleted' } ),
    'feed handler supports undeleted threads' );
ok( !$handler->supports( { event_type => 'profile.updated' } ),
    'feed handler ignores unrelated events' );

my $post = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'post-1',
        aggregate_type => 'post',
        domain_payload => { thread_id => 'thread-9' },
        event_id       => 'event-post-1',
        event_type     => 'post.created',
        timestamp      => '2026-05-23T12:00:00Z',
    }
);

is( $post->{action},    'feed.project', 'post task names feed projection' );
is( $post->{item_type}, 'post',         'post task stores post item type' );
is( $post->{item_id},   'post-1',       'post task stores post id' );
is( $post->{projected}{projected},
    $PROJECTED_USERS, 'post projection includes author and subscribers' );
is_deeply(
    $projector->calls->[0]{user_ids},
    [ 'user-author', 'user-follower' ],
    'post projection deduplicates the author subscriber'
);
is( $projector->calls->[0]{item_type},
    'post', 'post projection stores post item type' );
is( $projector->calls->[0]{created_at},
    '2026-05-23T12:00:00Z', 'post projection keeps event timestamp' );
is( $subscribers->calls->[0]{target_type},
    'thread', 'post projection looks up thread subscribers' );
is( $subscribers->calls->[0]{target_id},
    'thread-9', 'post projection uses payload thread id' );
is( $sink->records->[0]{action},
    'feed.project', 'post projection records a sink task' );

my $thread = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'thread-9',
        aggregate_type => 'thread',
        event_id       => 'event-thread-1',
        event_type     => 'thread.created',
    }
);

is( $thread->{item_type}, 'thread',   'thread task stores thread item type' );
is( $thread->{item_id},   'thread-9', 'thread task stores thread id' );
is( $projector->calls->[1]{item_type},
    'thread', 'thread projection stores thread item type' );
is( $subscribers->calls->[1]{target_id},
    'thread-9', 'thread projection looks up subscribers on the new thread' );
is( $projector->calls->[1]{created_at},
    '2026-05-23T12:00:00Z', 'thread projection falls back to the clock' );

my $transport =
  GPForum::Service::Outbox::DomainEventTransport->new( handlers => [$handler],
  );
my $dispatch = $transport->dispatch(
    GPForum::Test::OutboxPayloadRow->new(
        data => {
            payload => {
                actor_id       => 'user-author',
                aggregate_id   => 'post-2',
                aggregate_type => 'post',
                event_id       => 'event-post-2',
                event_type     => 'post.created',
                payload        => { thread_id => 'thread-9' },
            },
        },
    )
);

is( $dispatch->{handlers}, 1, 'outbox transport dispatches feed handler' );
is( $projector->calls->[-1]{item_id},
    'post-2', 'normalized outbox payload still projects the post' );

my $hidden = $handler->handle(
    {
        actor_id       => 'moderator-1',
        aggregate_id   => 'post-hidden',
        aggregate_type => 'post',
        event_id       => 'event-hidden-1',
        event_type     => 'post.hidden',
    }
);

is( $hidden->{action}, 'feed.remove', 'hidden post task names feed removal' );
is( $hidden->{item_type}, 'post', 'hidden post task stores post item type' );
is( $hidden->{item_id},   'post-hidden', 'hidden post task stores post id' );
is( $hidden->{removed}{removed}, 1,      'hidden post reports removal' );
is( $projector->removals->[0]{item_type},
    'post', 'hidden post removes post feed items' );
is( $projector->removals->[0]{item_id},
    'post-hidden', 'hidden post removes the hidden item id' );
is( scalar @{ $projector->calls },
    $PROJECTED_ITEMS, 'hidden post does not project a replacement row' );

my $deleted = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'post-hidden',
        aggregate_type => 'post',
        event_id       => 'event-deleted-1',
        event_type     => 'post.deleted',
    }
);

is( $deleted->{action}, 'feed.remove', 'deleted post task names feed removal' );
is( $deleted->{item_id}, 'post-hidden', 'deleted post task stores post id' );
is( $projector->removals->[-1]{item_id},
    'post-hidden', 'deleted post removes the deleted item id' );
is( scalar @{ $projector->calls },
    $PROJECTED_ITEMS, 'deleted post does not project a replacement row' );

my $deleted_thread = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'thread-1',
        aggregate_type => 'thread',
        event_id       => 'event-thread-deleted-1',
        event_type     => 'thread.deleted',
    }
);

is( $deleted_thread->{action},
    'feed.remove', 'deleted thread task names feed removal' );
is( $deleted_thread->{item_type},
    'thread', 'deleted thread task stores thread item type' );
is( $deleted_thread->{item_id},
    'thread-1', 'deleted thread task stores thread id' );
is( $projector->removals->[-1]{item_type},
    'thread', 'deleted thread removes thread feed items' );
is( $projector->removals->[-1]{item_id},
    'thread-1', 'deleted thread removes the deleted thread item id' );
ok( $projector->removals->[-1]{cascade_posts},
    'deleted thread also removes post feed items in the thread' );
is( scalar @{ $projector->calls },
    $PROJECTED_ITEMS, 'deleted thread does not project a replacement row' );

my $hidden_thread = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'thread-1',
        aggregate_type => 'thread',
        event_id       => 'event-thread-hidden-1',
        event_type     => 'thread.hidden',
    }
);

is( $hidden_thread->{action},
    'feed.remove', 'hidden thread task names feed removal' );
is( $hidden_thread->{item_type},
    'thread', 'hidden thread task stores thread item type' );
is( $projector->removals->[-1]{item_type},
    'thread', 'hidden thread removes thread feed items' );
ok( $projector->removals->[-1]{cascade_posts},
    'hidden thread also removes post feed items in the thread' );
is( scalar @{ $projector->calls },
    $PROJECTED_ITEMS, 'hidden thread does not project a replacement row' );

my $restored = $handler->handle(
    {
        actor_id       => 'moderator-1',
        aggregate_id   => 'post-hidden',
        aggregate_type => 'post',
        event_id       => 'event-restored-1',
        event_type     => 'post.restored',
    }
);

is( $restored->{action},
    'feed.project', 'restored post task names feed projection' );
is( $restored->{projected}{projected},
    $PROJECTED_USERS, 'restored post projects to author and subscribers' );
is_deeply(
    $projector->calls->[-1]{user_ids},
    [ 'user-author', 'user-follower' ],
    'restored post uses the stored author, not the moderator'
);
is( $subscribers->calls->[-1]{target_id},
    'thread-9', 'restored post looks up subscribers from the stored thread' );

my $undeleted = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'post-hidden',
        aggregate_type => 'post',
        event_id       => 'event-undeleted-1',
        event_type     => 'post.undeleted',
    }
);

is( $undeleted->{action},
    'feed.project', 'undeleted post task names feed projection' );
is( $undeleted->{projected}{projected},
    $PROJECTED_USERS, 'undeleted post projects to author and subscribers' );

my $restored_thread = $handler->handle(
    {
        actor_id       => 'moderator-1',
        aggregate_id   => 'thread-1',
        aggregate_type => 'thread',
        event_id       => 'event-thread-restored-1',
        event_type     => 'thread.restored',
    }
);

is( $restored_thread->{action},
    'feed.project', 'restored thread task names feed projection' );
is_deeply(
    $projector->calls->[-1]{user_ids},
    [ 'user-author', 'user-follower' ],
    'restored thread uses the stored author, not the moderator'
);
is( $subscribers->calls->[-1]{target_id},
    'thread-1', 'restored thread looks up subscribers from the thread id' );

my $undeleted_thread = $handler->handle(
    {
        actor_id       => 'user-author',
        aggregate_id   => 'thread-1',
        aggregate_type => 'thread',
        event_id       => 'event-thread-undeleted-1',
        event_type     => 'thread.undeleted',
    }
);

is( $undeleted_thread->{action},
    'feed.project', 'undeleted thread task names feed projection' );
is( $undeleted_thread->{projected}{projected},
    $PROJECTED_USERS, 'undeleted thread projects to author and subscribers' );

done_testing();

1;
