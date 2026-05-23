package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Test::IdempotencyStore;
use GPForum::Test::Minion;
use GPForum::Test::MinionJob;
use GPForum::Test::OutboxDispatcher;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::CacheInvalidation;
use GPForum::Worker::Handler::NotificationDispatch;
use GPForum::Worker::Handler::SearchIndexing;
use GPForum::Worker::IdempotentJobRunner;
use GPForum::Worker::MinionRegistrar;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 34;
const my $OUTBOX_LIMIT   => 7;
const my $POST_HANDLERS  => 3;

plan tests => $EXPECTED_TESTS;

my $sink      = GPForum::Test::WorkerSink->new;
my $transport = GPForum::Service::Outbox::DomainEventTransport->new(
    handlers => [
        GPForum::Worker::Handler::SearchIndexing->new( sink => $sink ),
        GPForum::Worker::Handler::NotificationDispatch->new( sink => $sink ),
        GPForum::Worker::Handler::CacheInvalidation->new( sink => $sink ),
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
    'post event dispatches to three handlers' );
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
    2, 'thread event dispatches to search and cache handlers' );

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
    $minion->tasks->{'gpforum.search.placeholder'},
    'registrar installs search placeholder task'
);
ok(
    $minion->tasks->{'gpforum.notification.placeholder'},
    'registrar installs notification placeholder task'
);
ok( $minion->tasks->{'gpforum.cache_invalidation.placeholder'},
    'registrar installs cache placeholder task' );

my $outbox_job = GPForum::Test::MinionJob->new;
my $outbox_result =
  $minion->tasks->{'gpforum.outbox.dispatch'}->( $outbox_job, $OUTBOX_LIMIT );

is( $minion_dispatcher->calls->[0], $OUTBOX_LIMIT, 'outbox task passes limit' );
is( $outbox_result->{dispatched},      1, 'outbox task returns summary' );
is( $outbox_job->finished->{selected}, 1, 'outbox task finishes job' );

my $placeholder_job = GPForum::Test::MinionJob->new;
my $placeholder =
  $minion->tasks->{'gpforum.search.placeholder'}->($placeholder_job);

ok( $placeholder->{ok}, 'placeholder task succeeds' );
is( $placeholder->{placeholder},
    'search', 'placeholder task identifies workload' );
is( $placeholder_job->finished->{placeholder},
    'search', 'placeholder task finishes job' );

1;
