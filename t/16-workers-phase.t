package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Test::IdempotencyStore;
use GPForum::Test::Minion;
use GPForum::Test::MinionJob;
use GPForum::Test::NotificationDispatcher;
use GPForum::Test::OutboxDispatcher;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::CacheInvalidation;
use GPForum::Worker::Handler::FeedProjection;
use GPForum::Worker::Handler::MediaProcessing;
use GPForum::Worker::Handler::NotificationDispatch;
use GPForum::Worker::Handler::ReputationUpdate;
use GPForum::Worker::Handler::SearchIndexing;
use GPForum::Worker::IdempotentJobRunner;
use GPForum::Worker::MinionRegistrar;

our $VERSION = '0.001';

const my $OUTBOX_LIMIT    => 7;
const my $POST_HANDLERS   => 5;
const my $THREAD_HANDLERS => 4;

my $sink  = GPForum::Test::WorkerSink->new;
my $cache = GPForum::Service::Operations::LocalCache->new;
$cache->put(
    'thread-page:thread-1',
    { cached => 1 },
    { tags   => ['thread:thread-1'] }
);
my $transport = GPForum::Service::Outbox::DomainEventTransport->new(
    handlers => [
        GPForum::Worker::Handler::SearchIndexing->new( sink => $sink ),
        GPForum::Worker::Handler::NotificationDispatch->new( sink => $sink ),
        GPForum::Worker::Handler::CacheInvalidation->new(
            cache => $cache,
            sink  => $sink,
        ),
        GPForum::Worker::Handler::AttachmentScanning->new( sink => $sink ),
        GPForum::Worker::Handler::MediaProcessing->new( sink => $sink ),
        GPForum::Worker::Handler::FeedProjection->new( sink => $sink ),
        GPForum::Worker::Handler::ReputationUpdate->new( sink => $sink ),
    ],
);
my $message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-1',
            event_type     => 'post.created',
            aggregate_type => 'post',
            aggregate_id   => 'post-1',
            thread_id      => 'thread-1',
        },
    },
);
my $dispatch = $transport->dispatch($message);

ok( $dispatch->{ok}, 'domain event transport succeeds' );
is( $dispatch->{handlers}, $POST_HANDLERS,
    'post event dispatches to five handlers' );
is( scalar @{ $dispatch->{results} },
    $POST_HANDLERS, 'transport returns handler results' );
is( scalar @{ $sink->records },
    $POST_HANDLERS, 'sink receives handler records' );
is( $sink->records->[0]{action},
    'search.index', 'search handler records indexing action' );
is( $sink->records->[0]{entity_type},
    'post', 'search handler records entity type' );
is( $sink->records->[1]{action},
    'notification.dispatch', 'notification handler records dispatch action' );
is( $sink->records->[1]{thread_id},
    'thread-1', 'notification handler records thread id' );
is( $sink->records->[2]{action},
    'cache.invalidate', 'cache handler records invalidation action' );
is( $sink->records->[2]{aggregate_id},
    'post-1', 'cache handler records aggregate id' );
is_deeply(
    $sink->records->[2]{tags},
    [ 'posts', 'post:post-1', 'thread:thread-1' ],
    'cache handler records invalidation tags'
);
is( $cache->snapshot->{entries},
    0, 'cache handler invalidates matching local cache entries' );
is( $sink->records->[3]{action},
    'feed.project', 'feed handler records projection action' );
is( $sink->records->[3]{item_type},
    'post', 'feed handler records post item type' );
is( $sink->records->[4]{action},
    'reputation.record', 'reputation handler records ledger action' );
is( $sink->records->[4]{reason},
    'post_created', 'reputation handler records post reason' );

my $notification_dispatcher = GPForum::Test::NotificationDispatcher->new;
my $notification_handler = GPForum::Worker::Handler::NotificationDispatch->new(
    dispatcher => $notification_dispatcher, );
my $notification_result = $notification_handler->handle(
    {
        event_id       => 'event-mention-1',
        event_type     => 'post.created',
        aggregate_type => 'post',
        aggregate_id   => 'post-9',
        actor_id       => 'user-author',
        domain_payload => { thread_id => 'thread-9' },
    }
);

is( $notification_result->{thread_id},
    'thread-9', 'notification handler reads thread id from domain payload' );
is( $notification_result->{fanout}{attempted},
    1, 'notification handler invokes fanout' );
is( scalar @{ $notification_dispatcher->calls },
    1, 'notification dispatcher receives one call' );
is( $notification_dispatcher->calls->[0]{excluded_recipient_user_id},
    'user-author', 'notification fanout excludes post author' );
is( $notification_dispatcher->calls->[0]{payload}{post_id},
    'post-9', 'notification fanout payload includes post id' );
is( $notification_dispatcher->calls->[0]{payload}{thread_id},
    'thread-9', 'notification fanout payload includes thread id' );
like(
    $notification_dispatcher->calls->[0]{idempotency_key},
    qr/\A notification[.]reply:event-mention-1/msx,
    'notification fanout includes delivery idempotency key'
);

my $thread_message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-2',
            event_type     => 'thread.created',
            aggregate_type => 'thread',
            aggregate_id   => 'thread-1',
        },
    },
);
my $thread_dispatch = $transport->dispatch($thread_message);

is( $thread_dispatch->{handlers},
    $THREAD_HANDLERS,
    'thread event dispatches to search, cache, feed, and reputation' );
is_deeply(
    $thread_dispatch->{results}[1]{tags},
    [ 'threads', 'forum-index', 'thread:thread-1' ],
    'thread cache invalidation records thread tags'
);
is( $thread_dispatch->{results}[2]{action},
    'feed.project', 'thread event also projects the feed' );
is( $thread_dispatch->{results}[3]{reason},
    'thread_created', 'thread event also records reputation' );

$cache->put(
    'categories:list:10',
    [ { title => 'Stale' } ],
    { tags => [ 'categories', 'forum-index' ] }
);
$cache->put(
    'forum-ssr:categories:/categories',
    { body => 'stale-list' },
    { tags => [ 'forum:public-html', 'forum:categories' ] }
);
$cache->put(
    'forum-ssr:category:/c/category-1',
    { body => 'stale-category' },
    { tags => [ 'forum:categories', 'forum:category:category-1' ] }
);

my $category_message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-category-1',
            event_type     => 'category.updated',
            aggregate_type => 'category',
            aggregate_id   => 'category-1',
            payload        => { category_id => 'category-1' },
        },
    },
);
my $category_dispatch = $transport->dispatch($category_message);

is( $category_dispatch->{handlers},
    1, 'category event dispatches to the cache handler' );
is_deeply(
    $sink->records->[-1]{tags},
    [
        'categories',       'forum-index',
        'forum:categories', 'category:category-1',
        'forum:category:category-1',
    ],
    'category cache invalidation records public list and page tags'
);
is( $cache->get('categories:list:10'),
    undef, 'category update invalidates the category reader list' );
is( $cache->get('forum-ssr:categories:/categories'),
    undef, 'category update invalidates the public category list page' );
is( $cache->get('forum-ssr:category:/c/category-1'),
    undef, 'category update invalidates the public category page' );

my $created_category = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-category-2',
            event_type     => 'category.created',
            aggregate_type => 'category',
            aggregate_id   => 'category-2',
        },
    },
);
is( $transport->dispatch($created_category)->{handlers},
    1, 'category create also dispatches to the cache handler' );
is( $sink->records->[-1]{aggregate_id},
    'category-2', 'category create invalidation targets the new category' );
is_deeply(
    $sink->records->[-1]{tags},
    [
        'categories',       'forum-index',
        'forum:categories', 'category:category-2',
        'forum:category:category-2',
    ],
    'category create invalidates the same public list tags'
);

my $unknown_message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-3',
            event_type     => 'profile.updated',
            aggregate_type => 'user',
            aggregate_id   => 'user-1',
        },
    },
);
my $unknown_dispatch = $transport->dispatch($unknown_message);

ok( $unknown_dispatch->{ok}, 'unknown event still dispatches successfully' );
is( $unknown_dispatch->{handlers}, 0, 'unknown event has no handlers' );

my $attachment_message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-4',
            event_type     => 'attachment.uploaded',
            aggregate_type => 'attachment',
            aggregate_id   => 'attachment-1',
        },
    },
);
my $attachment_dispatch = $transport->dispatch($attachment_message);

is( $attachment_dispatch->{handlers},
    1, 'attachment upload dispatches to scanning handler' );
is( $sink->records->[-1]{action},
    'attachment.scan', 'attachment scan action is recorded' );

my $media_message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-5',
            event_type     => 'attachment.scanned',
            aggregate_type => 'attachment',
            aggregate_id   => 'attachment-1',
            scan_status    => 'clean',
        },
    },
);
my $media_dispatch = $transport->dispatch($media_message);

is( $media_dispatch->{handlers},
    1, 'clean scanned attachment dispatches to media handler' );
is( $sink->records->[-1]{action},
    'media.process', 'media processing action is recorded' );

my $idempotency_store = GPForum::Test::IdempotencyStore->new;
my $runner =
  GPForum::Worker::IdempotentJobRunner->new( store => $idempotency_store );
my $run = $runner->run(
    'job-1',
    sub {
        return { handled => 1 };
    }
);

ok( $run->{ok},       'idempotent runner succeeds' );
ok( !$run->{skipped}, 'first idempotent run is not skipped' );
is( $run->{result}{handled}, 1, 'idempotent runner returns result' );
is( $idempotency_store->events->[0][0],
    'begin', 'idempotent runner begins key' );
is( $idempotency_store->events->[1][0],
    'done', 'idempotent runner marks key done' );

my $skipped = $runner->run(
    'job-1',
    sub {
        return { unreachable => 1 };
    }
);

ok( $skipped->{ok},      'idempotent duplicate succeeds' );
ok( $skipped->{skipped}, 'idempotent duplicate is skipped' );

my $failed = $runner->run(
    'job-2',
    sub {
        croak 'worker boom';
    }
);

ok( !$failed->{ok}, 'idempotent runner reports failure' );
like(
    $failed->{error},
    qr/\A worker [ ] boom/msx,
    'idempotent runner records failure text'
);
is( $idempotency_store->events->[-1][0],
    'failed', 'idempotent runner marks failure' );

my $minion_dispatcher = GPForum::Test::OutboxDispatcher->new;
my $registrar =
  GPForum::Worker::MinionRegistrar->new( dispatcher => $minion_dispatcher );
my $minion = GPForum::Test::Minion->new;
my $tasks  = $registrar->register($minion);

is( $tasks->{outbox}, 'gpforum.outbox.dispatch',
    'registrar names outbox task' );
ok( $minion->tasks->{'gpforum.outbox.dispatch'},
    'registrar installs outbox task' );
ok(
    $minion->tasks->{'gpforum.search.dispatch'},
    'registrar installs search dispatch task'
);
ok(
    $minion->tasks->{'gpforum.notification.dispatch'},
    'registrar installs notification dispatch task'
);
ok( $minion->tasks->{'gpforum.cache_invalidation.dispatch'},
    'registrar installs cache dispatch task' );
ok(
    $minion->tasks->{'gpforum.attachment_scan.dispatch'},
    'registrar installs attachment scan dispatch task'
);
ok(
    $minion->tasks->{'gpforum.media_processing.dispatch'},
    'registrar installs media processing dispatch task'
);
ok( $minion->tasks->{'gpforum.cache_invalidation.placeholder'},
    'registrar keeps cache legacy task alias' );

my $outbox_job = GPForum::Test::MinionJob->new;
my $outbox_result =
  $minion->tasks->{'gpforum.outbox.dispatch'}->( $outbox_job, $OUTBOX_LIMIT );

is( $minion_dispatcher->calls->[0], $OUTBOX_LIMIT, 'outbox task passes limit' );
is( $outbox_result->{dispatched},      1, 'outbox task returns summary' );
is( $outbox_job->finished->{selected}, 1, 'outbox task finishes job' );

my $notification_job = GPForum::Test::MinionJob->new;
my $notification_task_result =
  $minion->tasks->{'gpforum.notification.dispatch'}
  ->( $notification_job, $OUTBOX_LIMIT );

is( $minion_dispatcher->calls->[1],
    $OUTBOX_LIMIT, 'notification task passes limit to dispatcher' );
is( $notification_task_result->{dispatched},
    1, 'notification task returns dispatch summary' );
is( $notification_job->finished->{selected},
    1, 'notification task finishes job' );

my $search_job = GPForum::Test::MinionJob->new;
my $search_task_result =
  $minion->tasks->{'gpforum.search.dispatch'}->( $search_job, $OUTBOX_LIMIT );

is( $minion_dispatcher->calls->[2],
    $OUTBOX_LIMIT, 'search task passes limit to dispatcher' );
is( $search_task_result->{dispatched},
    1, 'search task returns dispatch summary' );
is( $search_job->finished->{selected}, 1, 'search task finishes job' );

my $media_job = GPForum::Test::MinionJob->new;
my $media_task_dispatch =
  $minion->tasks->{'gpforum.media_processing.dispatch'}
  ->( $media_job, $OUTBOX_LIMIT );

is( $minion_dispatcher->calls->[3],
    $OUTBOX_LIMIT, 'media task passes limit to dispatcher' );
is( $media_task_dispatch->{dispatched},
    1, 'media task returns dispatch summary' );
is( $media_job->finished->{selected}, 1, 'media task finishes job' );

my $legacy_job = GPForum::Test::MinionJob->new;
my $legacy_dispatch =
  $minion->tasks->{'gpforum.cache_invalidation.placeholder'}
  ->( $legacy_job, $OUTBOX_LIMIT );

ok( !exists $legacy_dispatch->{placeholder},
    'legacy placeholder task no longer returns placeholder result' );
is( $legacy_dispatch->{dispatched},
    1, 'legacy placeholder alias dispatches real outbox work' );

my @factory_jobs;
my $factory_dispatcher = GPForum::Test::OutboxDispatcher->new;
my $factory_registrar  = GPForum::Worker::MinionRegistrar->new(
    dispatcher_factory => sub {
        my ($job) = @_;

        push @factory_jobs, $job;
        return $factory_dispatcher;
    },
);
my $factory_minion = GPForum::Test::Minion->new;
$factory_registrar->register($factory_minion);
my $factory_job = GPForum::Test::MinionJob->new;
$factory_minion->tasks->{'gpforum.outbox.dispatch'}->( $factory_job, 5 );
is( scalar @factory_jobs, 1,
    'registrar can build dispatcher from job factory' );
is( $factory_dispatcher->calls->[0],
    5, 'factory-built dispatcher receives job limit' );

done_testing();

1;
