# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Service::Admin::Maintenance;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::SharedCache;
use GPForum::Service::Operations::TieredCache;
use GPForum::Service::Search::RebuildRun;
use GPForum::Test::LongThread;
use GPForum::Test::OperationsClock;
use GPForum::Test::PostgresHarness;
use GPForum::Test::SharedCacheClient;
use GPForum::Test::TagCache;
use GPForum::Worker::Handler::SearchIndexing;

our $VERSION = '0.001';

const my $BATCH        => 5;
const my $MAX_PASSES   => 200;
const my $THREAD_POSTS => 12;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the search rebuild run';
}

# The console's search rebuild on PostgreSQL, through the real outbox
# dispatcher, transport and search handler: one batch per message, each step
# recording the next, until a completion with the run's totals. The index is
# emptied first and given an orphan, so the run has everything to redo.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema  = GPForum::Test::PostgresHarness::connect_schema();
my $dbh     = $schema->storage->dbh;
my $indexer = GPForum::Service::Search::Indexer->new(
    rebuild_batch_size => $BATCH,
    schema             => $schema,
);
my $run = GPForum::Service::Search::RebuildRun->new(
    indexer => $indexer,
    schema  => $schema,
);

# Nothing else is waiting: the passes below deliver only the run.
$dbh->do(q{UPDATE outbox_messages SET status = 'done'});
$dbh->do('DELETE FROM search_documents');
my ($hidden) =
  $dbh->selectrow_array( q{SELECT thread_id FROM threads}
      . q{ WHERE deleted_at IS NULL ORDER BY thread_id LIMIT 1} );
$indexer->index_thread($hidden);
$dbh->do( q{UPDATE threads SET moderation_state = 'hidden' WHERE thread_id = ?},
    undef, $hidden );
is( _documents(), 1, 'the index holds only an orphan' );

my $admin = $dbh->selectrow_array('SELECT id FROM users LIMIT 1');
my $requested =
  $schema->txn_do( sub { return $run->request( { actor_id => $admin } ) } );
ok( $requested->{run_id}, 'a run is requested' );
is( _pending(), 1, 'as one outbox message' );

my $search_handler = GPForum::Worker::Handler::SearchIndexing->new(
    indexer     => $indexer,
    rebuild_run => $run,
);
my $dispatcher = GPForum::Service::Outbox::Dispatcher->new(
    id_service => GPForum::Infrastructure::Id->new,
    schema     => $schema,
    transport  => GPForum::Service::Outbox::DomainEventTransport->new(
        handlers => [$search_handler],
    ),
);

_drain();
is( _pending(), 0, 'the run drains the outbox' );
cmp_ok( _steps( $requested->{run_id} ), q{>}, 2, "in several steps of $BATCH" );

my $live = _live();
is( _documents(), $live, 'every live thread and post is indexed again' );
ok( !_document($hidden), 'and the orphan is gone' );

my $latest = $run->latest;
is( $latest->{run_id}, $requested->{run_id}, 'the latest run is this one' );
ok( $latest->{completed}, 'completed' );
is( $latest->{totals}{indexed}, $live, 'with its totals' );
is( $latest->{totals}{pruned},  1,     'the orphan counted as removed' );

# A step whose message is delivered again records its next step once.
my ($first) = $dbh->selectrow_array(
    q{SELECT payload::text FROM event_log WHERE aggregate_id = ?}
      . q{ AND event_type = 'search.rebuild_requested' ORDER BY created_at},
    undef, $requested->{run_id}
);
my $steps = _steps( $requested->{run_id} );
$run->step(
    {
        domain_payload => $run->recorder->json->decode($first),
        event_type     => 'search.rebuild_requested',
    }
);
is( _steps( $requested->{run_id} ),
    $steps, 'a repeated step does not fork the run' );

# Moving a thread re-derives its posts, which carry its title and category,
# a batch per outbox message: the first with the event, the rest as events
# of their own. Not as rebuild steps: the console's last rebuild stays as it
# was, and no prune of the whole index follows.
my $rebuilt = $run->latest;
my ($moved) =
  $dbh->selectrow_array( q{SELECT thread_id FROM threads}
      . q{ WHERE deleted_at IS NULL AND moderation_state = 'visible'}
      . q{ ORDER BY thread_id DESC LIMIT 1} );
GPForum::Test::LongThread::grow( $dbh, $moved, $THREAD_POSTS );
$dbh->do( 'UPDATE threads SET title = ? WHERE thread_id = ?',
    undef, 'Moved and renamed', $moved );
my $recorder = GPForum::Infrastructure::EventRecorder->new( schema => $schema );
$schema->txn_do(
    sub {
        return $recorder->record_event(
            actor_id       => $admin,
            aggregate_id   => $moved,
            aggregate_type => 'thread',
            event_type     => 'thread.moved',
            payload        => { thread_id => $moved },
        );
    }
);
_drain();
is( _pending(), 0, 'a moved thread drains the outbox' );
is(
    scalar $dbh->selectrow_array(
        q{SELECT count(*) FROM search_documents d JOIN posts p}
          . q{ ON p.post_id = d.entity_id WHERE d.entity_type = 'post'}
          . q{ AND p.thread_id = ? AND d.title = ?},
        undef,
        $moved,
        'Moved and renamed'
    ),
    $THREAD_POSTS,
    'every post of it carries the new title'
);
my $batches = $dbh->selectall_arrayref(
    q{SELECT event_id, payload::text AS payload FROM event_log}
      . q{ WHERE event_type = 'search.thread_posts_requested'}
      . q{ AND aggregate_id = ? ORDER BY (payload->>'after')::integer},
    { Slice => {} },
    $moved
);
is_deeply(
    [ map { $recorder->json->decode( $_->{payload} )->{after} } @{$batches} ],
    [ $BATCH, 2 * $BATCH ],
    "in batches of $BATCH: the first with the event, two as their own events"
);
is_deeply( $run->latest, $rebuilt,
    'and the last rebuild the console shows is unchanged' );

$search_handler->handle(
    {
        domain_payload => $recorder->json->decode( $batches->[0]{payload} ),
        event_id       => $batches->[0]{event_id},
        event_type     => 'search.thread_posts_requested',
    }
);
is(
    scalar $dbh->selectrow_array(
        q{SELECT count(*) FROM event_log}
          . q{ WHERE event_type = 'search.thread_posts_requested'}
          . q{ AND aggregate_id = ?},
        undef,
        $moved
    ),
    scalar @{$batches},
    'a batch delivered again records its successor once'
);

# The console's side: each write audited, the purge reaching the cache.
my $cache       = GPForum::Test::TagCache->new;
my $maintenance = GPForum::Service::Admin::Maintenance->new(
    cache  => $cache,
    schema => $schema,
);
my $asked = $schema->txn_do(
    sub {
        return $maintenance->request_search_rebuild(
            { actor_user_id => $admin } );
    }
);
$schema->txn_do(
    sub {
        return $maintenance->purge_public_cache( { actor_user_id => $admin } );
    }
);
is_deeply(
    [
        map { $_->[0] } @{
            $dbh->selectall_arrayref(
                q{SELECT action FROM audit_log WHERE actor_id = ?}
                  . q{ AND action LIKE 'admin.%' ORDER BY action},
                undef,
                $admin
            )
        }
    ],
    [qw(admin.cache_purged admin.search_rebuild_requested)],
    'a console rebuild and purge are audited'
);
ok( _steps( $asked->{run_id} ), 'the console rebuild is queued' );
is_deeply(
    $cache->invalidated,
    [qw(forum:public-html categories forum-index)],
    'and the purge drops every public page and its reader caches'
);

# A purge that could not reach GlifiStore said "purged": the pages there
# stayed current until their TTL. The answer and the audit row now say so.
my $paused_l2 = GPForum::Service::Operations::SharedCache->new(
    client => GPForum::Test::SharedCacheClient->new,
    clock  => GPForum::Test::OperationsClock->new,
);
$paused_l2->retry_after_epoch( $paused_l2->clock->now_epoch + 1 );
my $local_only = GPForum::Service::Admin::Maintenance->new(
    cache => GPForum::Service::Operations::TieredCache->new(
        l1 => GPForum::Service::Operations::LocalCache->new,
        l2 => $paused_l2,
    ),
    schema => $schema,
);
my $purged = $schema->txn_do(
    sub {
        return $local_only->purge_public_cache( { actor_user_id => $admin } );
    }
);
is( $purged->{status}, 'purged_locally',
    'a purge that did not reach the shared cache is purged locally' );
is_deeply(
    $dbh->selectall_arrayref(
        q{SELECT metadata->>'status', metadata->'unreached_tags' #>> '{}'}
          . q{ FROM audit_log WHERE actor_id = ?}
          . q{ AND action = 'admin.cache_purged'}
          . q{ ORDER BY metadata->>'status'},
        undef,
        $admin
    ),
    [
        [ 'purged', '[]' ],
        [
            'purged_locally',
            '["forum:public-html", "categories", "forum-index"]'
        ],
    ],
    'each audit row records how far its purge went, and the tags it left'
);

# A step records the next one and its outbox message together or not at all.
# They were written under autocommit: an outbox write that failed left the
# event, whose key then said the step was recorded, so every retry returned
# at once and the run stopped there with no message to carry it on. Last in
# this file, so the run it starts disturbs nothing above.
$dbh->do( q{CREATE FUNCTION test_refuse_outbox() RETURNS trigger}
      . q{ LANGUAGE plpgsql AS $$ BEGIN}
      . q{ RAISE EXCEPTION 'the outbox is unavailable'; END $$} );
$dbh->do( q{CREATE TRIGGER test_refuse_outbox BEFORE INSERT ON outbox_messages}
      . q{ FOR EACH ROW EXECUTE FUNCTION test_refuse_outbox()} );
my $stalled = {
    domain_payload => {
        entity_type => 'thread',
        run_id      => $run->id_service->uuid,
        step        => 0,
        totals      => {},
    },
    event_id   => $run->id_service->uuid,
    event_type => 'search.rebuild_requested',
};
my $stalled_run = $stalled->{domain_payload}{run_id};
my $stepped     = eval { $run->step($stalled); 1 };
ok( !$stepped, 'a step whose outbox message cannot be written fails' );
is( _steps($stalled_run), 0, 'and leaves no next step behind' );

$dbh->do('DROP TRIGGER test_refuse_outbox ON outbox_messages');
$dbh->do('DROP FUNCTION test_refuse_outbox()');
$run->step($stalled);
is_deeply(
    $dbh->selectrow_arrayref(
        q{SELECT count(DISTINCT e.event_id), count(o.event_id) FROM event_log e}
          . q{ LEFT JOIN outbox_messages o ON o.event_id = e.event_id}
          . q{ WHERE e.aggregate_id = ?},
        undef,
        $stalled_run
    ),
    [ 1, 1 ],
    'its retry records the next step, with its message'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# Delivers every pending message, one per pass. The dispatcher's clock reads
# whole seconds and a new step's message is due now, to the microsecond: it
# becomes claimable in the next second. The test does not wait for it.
sub _drain {
    my $passes = 0;
    while ( _pending() && $passes < $MAX_PASSES ) {
        $dbh->do( q{UPDATE outbox_messages SET next_attempt_at = now()}
              . q{ - interval '1 second' WHERE status = 'pending'} );
        $dispatcher->dispatch_pending(1);
        $passes++;
    }

    return $passes;
}

sub _pending {
    return
      scalar $dbh->selectrow_array(
        q{SELECT count(*) FROM outbox_messages WHERE status = 'pending'});
}

sub _steps {
    my ($run_id) = @_;

    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM event_log WHERE aggregate_id = ?',
        undef, $run_id );
}

sub _documents {
    return
      scalar $dbh->selectrow_array('SELECT count(*) FROM search_documents');
}

sub _document {
    my ($id) = @_;

    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM search_documents WHERE entity_id = ?',
        undef, $id );
}

sub _live {
    return
      scalar $dbh->selectrow_array(
            q{SELECT (SELECT count(*) FROM threads WHERE deleted_at IS NULL}
          . q{ AND moderation_state IN ('visible', 'locked'))}
          . q{ + (SELECT count(*) FROM posts p JOIN threads t}
          . q{ ON t.thread_id = p.thread_id WHERE p.deleted_at IS NULL}
          . q{ AND p.moderation_state = 'visible' AND t.deleted_at IS NULL}
          . q{ AND t.moderation_state IN ('visible', 'locked'))} );
}

1;
