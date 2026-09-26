# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use List::Util qw(all any first none);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::DocumentBuilder;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::SearchEventRecorder;
use GPForum::Test::SearchIndexer;
use GPForum::Test::SearchPermissionEngine;
use GPForum::Test::SearchResultSet;
use GPForum::Test::SearchRow;
use GPForum::Test::SearchSchema;
use GPForum::Worker::Handler::SearchIndexing;

our $VERSION = '0.001';

const my $SEARCH_LIMIT          => 5;
const my $SEARCH_DEFAULT        => 20;
const my $SEARCH_MAX            => 50;
const my $POST_SOURCE_VERSION   => 3;
const my $BUMPED_SOURCE_VERSION => 4;
const my $REVERSAL_CALL_INDEX   => 4;
const my $LONG_THREAD_POSTS     => 5;
const my $SMALL_BATCH           => 2;
const my $TWO_BATCHES           => 2 * $SMALL_BATCH;

# The thread's own transaction and one per batch of its posts.
const my $REMOVAL_TRANSACTIONS => 4;

my $category = GPForum::Test::SearchRow->new(
    data => {
        category_id => 'category-1',
        space_id    => 'space-1',
    },
);
my $thread = GPForum::Test::SearchRow->new(
    category => $category,
    data     => {
        thread_id          => 'thread-1',
        category_id        => 'category-1',
        author_user_id     => 'user-1',
        title              => 'Welcome to GPForum',
        visibility         => 'public',
        moderation_state   => 'visible',
        visibility_version => 1,
        permission_version => 1,
        version            => 2,
        created_at         => '2026-05-23T11:00:00Z',
        deleted_at         => undef,
    },
);
my $body = GPForum::Test::SearchRow->new(
    data => {
        body_rendered_safe => 'A durable Perl forum post',
        body_source        => 'A durable Perl forum post',
    },
);
my $post = GPForum::Test::SearchRow->new(
    current_body => $body,
    thread       => $thread,
    data         => {
        post_id            => 'post-1',
        author_user_id     => 'user-2',
        visibility         => 'public',
        moderation_state   => 'visible',
        visibility_version => 1,
        permission_version => 1,
        version            => 3,
        created_at         => '2026-05-23T12:00:00Z',
        deleted_at         => undef,
        thread_id          => 'thread-1',
    },
);

my $builder         = GPForum::Service::Search::DocumentBuilder->new;
my $thread_document = $builder->build_thread($thread);
my $post_document   = $builder->build_post($post);

is( $thread_document->{entity_type}, 'thread',   'thread document has type' );
is( $thread_document->{entity_id},   'thread-1', 'thread document has id' );
is( $thread_document->{space_id},    'space-1',  'thread document has space' );
is( $thread_document->{category_id},
    'category-1', 'thread document stores category filter' );
is( $thread_document->{author_user_id},
    'user-1', 'thread document stores author filter' );
is(
    $thread_document->{title},
    'Welcome to GPForum',
    'thread document uses title'
);
is(
    $thread_document->{body},
    'Welcome to GPForum',
    'thread document has searchable body'
);
is( $thread_document->{source_version}, 2, 'thread document stores version' );
is( $thread_document->{source_created_at},
    '2026-05-23T11:00:00Z', 'thread document stores creation time' );
is( $post_document->{entity_type}, 'post',   'post document has type' );
is( $post_document->{entity_id},   'post-1', 'post document has id' );
is( $post_document->{category_id},
    'category-1', 'post document inherits category filter' );
is( $post_document->{author_user_id},
    'user-2', 'post document stores author filter' );
is(
    $post_document->{title},
    'Welcome to GPForum',
    'post inherits thread title'
);
is(
    $post_document->{body},
    'A durable Perl forum post',
    'post document stores current body'
);
is( $post_document->{source_version},
    $POST_SOURCE_VERSION, 'post document stores version' );
is( $post_document->{source_created_at},
    '2026-05-23T12:00:00Z', 'post document stores creation time' );

my $hidden_post = GPForum::Test::SearchRow->new(
    thread => $thread,
    data   => {
        post_id          => 'post-hidden',
        visibility       => 'public',
        moderation_state => 'hidden',
        deleted_at       => undef,
    },
);
ok( !$builder->build_post($hidden_post), 'hidden post is not indexed' );

my $locked_thread = GPForum::Test::SearchRow->new(
    category => $category,
    data     => {
        %{ $thread->data },
        thread_id        => 'thread-locked',
        moderation_state => 'locked',
    },
);
ok(
    $builder->build_thread($locked_thread),
    'locked readable thread remains indexed'
);

my $hidden_thread = GPForum::Test::SearchRow->new(
    category => $category,
    data     => {
        %{ $thread->data },
        thread_id        => 'thread-hidden',
        moderation_state => 'hidden',
    },
);
ok( !$builder->build_thread($hidden_thread), 'hidden thread is not indexed' );

my $threads = GPForum::Test::SearchResultSet->new( rows => [$thread] );
my $posts   = GPForum::Test::SearchResultSet->new( rows => [$post] );
my $indexed_documents = GPForum::Test::SearchResultSet->new( rows => [] );
my $schema            = GPForum::Test::SearchSchema->new(
    resultsets => {
        Thread         => $threads,
        Post           => $posts,
        SearchDocument => $indexed_documents,
    },
);
my $clock   = GPForum::Test::FixedClock->new;
my $indexer = GPForum::Service::Search::Indexer->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);

my $indexed_thread = $indexer->index_thread('thread-1');
like(
    $indexed_thread->{search_document_id},
    qr/\A [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4} -
       [[:xdigit:]]{4} - [[:xdigit:]]{12} \z/msx,
    'thread index creates deterministic document id'
);
is( $indexed_thread->{entity_type}, 'thread', 'thread index persists type' );
is( $indexed_thread->{indexed_at},
    '2026-05-23T12:00:00Z', 'thread index stores timestamp' );
like( ${ $indexed_thread->{search_vector} }->[0],
    qr/to_tsvector/msx, 'thread index creates PostgreSQL vector expression' );
is( scalar @{ $indexed_documents->created },
    1, 'thread index upserts search document' );
$clock->iso8601('2026-05-23T13:00:00Z');
my $same_thread = $indexer->index_thread('thread-1');
ok( $same_thread->{skipped}, 'thread reindex skips an unchanged document' );
is( $same_thread->{indexed_at},
    '2026-05-23T12:00:00Z',
    'unchanged thread document keeps the original indexed_at' );
is( scalar @{ $indexed_documents->created },
    1, 'unchanged thread document does not insert another row' );
is( $indexed_documents->rows->[0]->get_column('indexed_at'),
    '2026-05-23T12:00:00Z',
    'unchanged thread document does not restamp the stored row' );

$indexed_documents->skip_search(1);
my $raced_thread = $indexer->index_thread('thread-1');
ok( $raced_thread->{skipped},
    'unique search document race skips the existing row' );
is( $raced_thread->{indexed_at},
    '2026-05-23T12:00:00Z',
    'unique search document race keeps the original indexed_at' );
is( scalar @{ $indexed_documents->created },
    1, 'unique search document race does not insert another row' );
is( $indexed_documents->rows->[0]->get_column('indexed_at'),
    '2026-05-23T12:00:00Z',
    'unique search document race does not restamp the stored row' );

$thread->update( { version => $BUMPED_SOURCE_VERSION } );
my $bumped_thread = $indexer->index_thread('thread-1');
ok( !$bumped_thread->{skipped},
    'thread reindex writes after a source version bump' );
is( $bumped_thread->{indexed_at},
    '2026-05-23T13:00:00Z', 'version bump restamps indexed_at' );
$thread->update( { version => 2 } );
$clock->iso8601('2026-05-23T12:00:00Z');

my $indexed_post = $indexer->index_post('post-1');
like(
    $indexed_post->{search_document_id},
    qr/\A [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4} -
       [[:xdigit:]]{4} - [[:xdigit:]]{12} \z/msx,
    'post index creates deterministic document id'
);
is( $indexed_post->{entity_type}, 'post', 'post index persists type' );
like( ${ $indexed_post->{search_vector} }->[0],
    qr/setweight/msx, 'post index creates weighted vector expression' );
is( scalar @{ $indexed_documents->created },
    2, 'post index upserts search document' );

my $removed = $indexer->remove_post('post-1');
ok( $removed->{ok}, 'post removal succeeds' );
is( $indexed_documents->deleted->[0]{entity_type},
    'post', 'post removal targets post documents' );
is( $indexed_documents->deleted->[0]{entity_id},
    'post-1', 'post removal targets entity id' );

my $rebuilt = $indexer->rebuild( { entity_type => 'all' } );
ok( $rebuilt->{ok}, 'search rebuild succeeds' );
is( $rebuilt->{indexed} + $rebuilt->{unchanged} + $rebuilt->{pruned},
    2, 'search rebuild visits every live thread and post' );
is( scalar @{ $indexed_documents->rows },
    2, 'search rebuild does not duplicate documents' );
is_deeply(
    $threads->last_query->{'me.moderation_state'},
    { -in => [qw(locked visible)] },
    'thread rebuild takes visible and locked threads, as the builder does'
);
ok(
    exists $posts->last_query->{'me.deleted_at'},
    'post rebuild filters deleted rows'
);

my $removed_thread = $indexer->remove_thread('thread-1');
ok( $removed_thread->{ok}, 'thread removal succeeds' );
is( $removed_thread->{posts_removed},
    1, 'thread removal also removes post documents' );
ok(
    !_document_for( $indexed_documents, 'post', 'post-1' ),
    'thread removal deletes post search documents in the thread'
);
ok(
    !_document_for( $indexed_documents, 'thread', 'thread-1' ),
    'thread removal still deletes the thread document'
);

my $reindexed_posts = $indexer->index_thread_posts('thread-1');
is( $reindexed_posts->{indexed},
    1, 'thread post reindex indexes posts in the thread' );
ok(
    _document_for( $indexed_documents, 'post', 'post-1' ),
    'thread post reindex persists post documents'
);
ok(
    _deleted_entity( $indexed_documents->created, 'post', 'post-1' ),
    'thread post reindex recreates post search documents'
);

my $search_documents = GPForum::Test::SearchResultSet->new(
    rows => [
        GPForum::Test::SearchRow->new(
            data => {
                entity_type      => 'thread',
                entity_id        => 'thread-1',
                category_id      => 'category-1',
                author_user_id   => 'user-1',
                title            => 'Welcome to GPForum',
                title_normalized => 'welcome to gpforum',
                body       => 'A durable <script>x</script> Perl forum post',
                visibility => 'public',
                permission_scope  => 'public',
                rank_score        => 0.8,
                source_created_at => '2026-05-23T11:00:00Z',
                indexed_at        => '2026-05-23T12:00:00Z',
            },
        ),
        GPForum::Test::SearchRow->new(
            data => {
                entity_type       => 'post',
                entity_id         => 'post-denied',
                category_id       => 'category-1',
                author_user_id    => 'user-3',
                title             => 'Private GPForum result',
                title_normalized  => 'private gpforum result',
                body              => 'private text must not leak',
                visibility        => 'private',
                permission_scope  => 'private',
                source_created_at => '2026-05-23T10:00:00Z',
                indexed_at        => '2026-05-23T12:00:00Z',
            },
        ),
    ],
);
my $search_schema = GPForum::Test::SearchSchema->new(
    resultsets => { SearchDocument => $search_documents, }, );

my $permission_engine = GPForum::Test::SearchPermissionEngine->new(
    visibility      => [ 'public', 'private' ],
    denied_entities => { 'post-denied' => 1 },
);
my $searcher = GPForum::Service::Search::Searcher->new(
    schema            => $search_schema,
    permission_engine => $permission_engine,
);
my $results = $searcher->search(
    { user_id => 'user-1' },
    'forum',
    {
        limit          => $SEARCH_LIMIT,
        category_id    => 'category-1',
        author_user_id => 'user-1',
        from           => '2026-05-01',
        to             => '2026-06-01',
    }
);

is( scalar @{$results}, 1, 'search filters denied render results' );

# This used to assert that the SQL asked for 'private' too, which pinned the
# defect: every logged-in actor was granted every visibility in the WHERE
# clause and the real check ran in Perl AFTER the database applied LIMIT. A
# member whose top matches were other people's private documents got a short
# page, or an empty one while public matches sat below the cut. Measured
# against PostgreSQL before the fix: anonymous 5 results, logged in 0.
is_deeply(
    $search_documents->last_query->{-and}[0]{-and}[0],
    { 'me.visibility' => { -in => [ 'public', 'private' ] } },
    'search applies the permission predicate in the WHERE clause'
);
is( $search_documents->last_query->{-and}[0]{'me.category_id'},
    'category-1', 'search applies category filter' );
is( $search_documents->last_query->{-and}[0]{'me.author_user_id'},
    'user-1', 'search applies author filter' );
ok(
    _author_qualified( [ keys %{ $search_documents->last_query->{-and}[0] } ] ),
    'search qualifies every column against the joined author'
);
is( $search_documents->last_query->{-and}[1]{'me.source_created_at'}{'>='},
    '2026-05-01', 'search applies lower date bound' );
like( ${ $search_documents->last_query->{-and}[0]{-or}[0] }->[0],
    qr/websearch_to_tsquery/msx, 'search applies PostgreSQL websearch query' );

# The tsquery used to take its configuration from me.language, a column of the
# same row. The planner only accepts an index clause whose other operand holds
# no Var of the indexed relation, so the GIN index on search_vector was
# unusable and every search read every row. The configuration is a bind now.
my $fts_arm = ${ $search_documents->last_query->{-and}[0]{-or}[0] };
like(
    $fts_arm->[0],
    qr/websearch_to_tsquery[(][?]::regconfig, \s* [?][)]/msx,
    'search binds the text-search configuration'
);
unlike( $fts_arm->[0], qr/me[.]language/msx,
    'search does not read the configuration from the row' );
is(
    $fts_arm->[1][1],
    GPForum::Service::Search::DocumentBuilder->search_config,
    'the bound configuration is the one documents are built with'
);

# similarity(...) >= ? is a function compared with a number, not a pg_trgm
# operator, so it could not use the trigram index. % can.
my $trigram_arm = ${ $search_documents->last_query->{-and}[0]{-or}[1] };
like(
    $trigram_arm->[0],
    qr/me[.]title_normalized \s+ % \s+ lower/msx,
    'search matches titles with the indexable trigram operator'
);
unlike( $trigram_arm->[0], qr/similarity/msx,
    'the fuzzy match is not a bare similarity comparison' );
is( $search_documents->last_attrs->{rows},
    $SEARCH_LIMIT, 'search applies limit' );
like( ${ $search_documents->last_attrs->{'+select'}[0] }->[0],
    qr/ts_rank_cd/msx, 'search selects deterministic rank score' );
like( $results->[0]{snippet_html},
    qr/<mark>forum<\/mark>/imsx, 'search highlights snippet safely' );
unlike( $results->[0]{snippet_html},
    qr/<script/msx, 'search snippet strips HTML tags' );

my $autocomplete =
  $searcher->autocomplete( { user_id => 'user-1' }, 'Wel', {} );
is( scalar @{$autocomplete}, 1, 'autocomplete filters denied render results' );
is( $search_documents->last_query->{'me.title_normalized'}{-like},
    'wel%', 'autocomplete uses normalized title prefix' );

$searcher->search( { user_id => 'user-1' }, 'forum', { limit => 10_000 } );
is( $search_documents->last_attrs->{rows},
    $SEARCH_MAX, 'search clamps excessive limit' );
$searcher->autocomplete( { user_id => 'user-1' }, 'Wel', { limit => 10_000 } );
is( $search_documents->last_attrs->{rows},
    $SEARCH_MAX, 'autocomplete clamps excessive limit' );
$searcher->autocomplete( { user_id => 'user-1' }, 'Wel', { limit => 0 } );
is( $search_documents->last_attrs->{rows},
    $SEARCH_DEFAULT, 'autocomplete defaults invalid limit' );

my $real_permission = GPForum::Service::Search::PermissionEngine->new;
is_deeply( [ $real_permission->search_visibility_for( undef, {} ) ],
    ['public'], 'anonymous search scope is public only' );
ok(
    !$real_permission->permits(
        undef, 'search.view',
        { visibility => 'members', entity_type => 'thread' }, {}
    ),
    'anonymous user cannot render members-only search result'
);
ok(
    $real_permission->permits(
        {
            viewer => GPForum::Service::Forum::Viewer->new(
                member  => 1,
                user_id => 'user-1'
            )
        },
        'search.view',
        {
            author_user_id      => 'user-1',
            category_visibility => 'public',
            space_visibility    => 'public',
            visibility          => 'private',
        },
        {},
    ),
    'private author can render own search result'
);

# ADR 0102: a document's category and space are judged too. A public thread
# in a private category is not a public search result.
ok(
    !$real_permission->permits(
        undef,
        'search.view',
        {
            category_visibility => 'private',
            space_visibility    => 'public',
            visibility          => 'public',
        },
        {},
    ),
    'a public document in a private category is not shown to anonymous readers'
);
is_deeply(
    $real_permission->search_condition(undef)->{-and},
    [
        { 'space.visibility'    => { -in => ['public'] } },
        { 'category.visibility' => { -in => ['public'] } },
        { 'me.visibility'       => { -in => ['public'] } },
    ],
    'and the SQL judges space, category and document for them'
);

my $fake_indexer = GPForum::Test::SearchIndexer->new;
my $handler =
  GPForum::Worker::Handler::SearchIndexing->new( indexer => $fake_indexer, );
my $task = $handler->handle(
    {
        event_id       => 'event-1',
        event_type     => 'post.created',
        aggregate_type => 'post',
        aggregate_id   => 'post-1',
    }
);

is( $fake_indexer->calls->[0][0], 'post',   'worker calls search indexer' );
is( $fake_indexer->calls->[0][1], 'post-1', 'worker passes aggregate id' );
ok( $task->{indexed}{ok}, 'worker records indexer result' );

my $hide_task = $handler->handle(
    {
        event_id       => 'event-2',
        event_type     => 'post.hidden',
        aggregate_type => 'post',
        aggregate_id   => 'post-1',
    }
);
is( $hide_task->{action}, 'search.remove', 'hide event removes document' );
is( $fake_indexer->calls->[1][0],
    'remove_post', 'hide event calls remove_post' );

my $restore_task = $handler->handle(
    {
        event_id       => 'event-3',
        event_type     => 'post.restored',
        aggregate_type => 'post',
        aggregate_id   => 'post-1',
    }
);
is( $restore_task->{action},      'search.index', 'restore event reindexes' );
is( $fake_indexer->calls->[2][0], 'post', 'restore event calls index_post' );

my $undelete_task = $handler->handle(
    {
        event_id       => 'event-3b',
        event_type     => 'post.undeleted',
        aggregate_type => 'post',
        aggregate_id   => 'post-1',
    }
);
is( $undelete_task->{action},     'search.index', 'undelete event reindexes' );
is( $fake_indexer->calls->[3][0], 'post', 'undelete event calls index_post' );

my $reversal_task = $handler->handle(
    {
        event_id       => 'event-4',
        event_type     => 'moderation_action.reversed',
        aggregate_type => 'moderation_action',
        aggregate_id   => 'action-1',
        domain_payload => {
            target_type => 'post',
            target_id   => 'post-1',
        },
    }
);
ok( $reversal_task->{indexed}{ok}, 'reversal event re-evaluates target index' );
is( $fake_indexer->calls->[$REVERSAL_CALL_INDEX][0],
    'post', 'reversal event indexes target post' );

my $thread_delete_task = $handler->handle(
    {
        event_id       => 'event-5',
        event_type     => 'thread.deleted',
        aggregate_type => 'thread',
        aggregate_id   => 'thread-1',
    }
);
is( $thread_delete_task->{action},
    'search.remove', 'thread delete event removes document' );
ok( _indexer_called( $fake_indexer->calls, 'remove_thread', 'thread-1' ),
    'thread delete event calls remove_thread' );

my $thread_hide_task = $handler->handle(
    {
        event_id       => 'event-6',
        event_type     => 'thread.hidden',
        aggregate_type => 'thread',
        aggregate_id   => 'thread-1',
    }
);
is( $thread_hide_task->{action},
    'search.remove', 'thread hide event removes document' );
ok( _indexer_called( $fake_indexer->calls, 'remove_thread', 'thread-1' ),
    'thread hide event calls remove_thread' );

my $thread_restore_task = $handler->handle(
    {
        event_id       => 'event-7',
        event_type     => 'thread.restored',
        aggregate_type => 'thread',
        aggregate_id   => 'thread-1',
    }
);
is( $thread_restore_task->{action},
    'search.index', 'thread restore event reindexes' );
ok( _indexer_called( $fake_indexer->calls, 'thread', 'thread-1' ),
    'thread restore event calls index_thread' );
ok( _indexer_called( $fake_indexer->calls, 'thread_posts', 'thread-1' ),
    'thread restore event reindexes posts in the thread' );

my $thread_undelete_task = $handler->handle(
    {
        event_id       => 'event-7b',
        event_type     => 'thread.undeleted',
        aggregate_type => 'thread',
        aggregate_id   => 'thread-1',
    }
);
is( $thread_undelete_task->{action},
    'search.index', 'thread undelete event reindexes' );
ok( _indexer_called( $fake_indexer->calls, 'thread', 'thread-1' ),
    'thread undelete event calls index_thread' );
ok(
    _indexer_called( $fake_indexer->calls, 'thread_posts', 'thread-1' ),
    'thread undelete event reindexes posts in the thread'
);

# A post's document carries its thread's title (weighted A) and category, so
# renaming or moving a thread must recompute its posts too: otherwise replies
# still match the old title, and a search inside the new category misses them
# while the old category keeps returning them.
for my $case (
    [ 'thread.updated', 'thread-renamed', 'a renamed thread' ],
    [ 'thread.moved',   'thread-moved',   'a moved thread' ],
  )
{
    my ( $event_type, $thread_id, $label ) = @{$case};
    $handler->handle(
        {
            aggregate_id   => $thread_id,
            aggregate_type => 'thread',
            event_id       => "event-$thread_id",
            event_type     => $event_type,
        }
    );
    ok( _indexer_called( $fake_indexer->calls, 'thread_posts', $thread_id ),
        "$label reindexes the posts in it" );
}

# A thread's posts are removed, and indexed again, a batch at a time. The
# removal was one transaction holding an advisory lock per post, and a thread
# of a few thousand posts could not get them from PostgreSQL's shared lock
# table: the removal was retried until it was dead-lettered, and the posts of
# the hidden thread stayed searchable.
my $long_thread = GPForum::Test::SearchRow->new(
    category => $category,
    data     => { %{ $thread->data }, thread_id => 'thread-long' },
);
my @long_posts =
  map { _long_post( $long_thread, $post, $_ ) } reverse 1 .. $LONG_THREAD_POSTS;
my $long_documents = GPForum::Test::SearchResultSet->new( rows => [] );
my $long_schema    = GPForum::Test::SearchSchema->new(
    resultsets => {
        Post => GPForum::Test::SearchResultSet->new(
            rows => [ @long_posts, $post ]
        ),
        SearchDocument => $long_documents,
        Thread         => GPForum::Test::SearchResultSet->new(
            rows => [ $long_thread, $thread ]
        ),
    },
);
my $long_indexer = GPForum::Service::Search::Indexer->new(
    clock              => $clock,
    id_service         => GPForum::Test::Id->new,
    rebuild_batch_size => $SMALL_BATCH,
    schema             => $long_schema,
);
$long_indexer->index_thread('thread-long');
$long_indexer->index_post('post-1');
is( $long_indexer->index_thread_posts('thread-long')->{indexed},
    $LONG_THREAD_POSTS, 'a thread\'s posts are indexed, a batch at a time' );
is_deeply(
    [
        map {
            $long_indexer->index_thread_posts_batch( 'thread-long', $_ )
              ->{next_after}
        } ( undef, $SMALL_BATCH, $TWO_BATCHES )
    ],
    [ $SMALL_BATCH, $TWO_BATCHES, undef ],
    'a full batch says at which position the next starts, the last says none'
);

( first { $_->get_column('post_id') eq 'long-post-3' } @long_posts )
  ->update( { moderation_state => 'hidden' } );
is_deeply(
    [
        @{
            $long_indexer->index_thread_posts_batch( 'thread-long',
                $SMALL_BATCH )
        }{qw(indexed pruned unchanged)}
    ],
    [ 0, 1, 1 ],
    'a batch removes the document of a post that died'
);

my $transactions = $long_schema->transaction_count;
my $long_removed = $long_indexer->remove_thread('thread-long');
is( $long_schema->transaction_count - $transactions,
    $REMOVAL_TRANSACTIONS,
    'removing it takes one transaction for the thread and one per batch' );
is_deeply(
    _removed_post_batches($long_documents),
    [
        [qw(long-post-1 long-post-2)], [qw(long-post-3 long-post-4)],
        ['long-post-5']
    ],
    'each batch at most the batch size, in position order, dead posts included'
);
is(
    $long_removed->{posts_removed},
    $LONG_THREAD_POSTS - 1,
    'the documents removed are counted, not the one already gone'
);
ok(
    (
        none { $_->get_column('entity_id') =~ /long/msx }
          @{ $long_documents->rows }
    ),
    'and no document of the thread or its posts is left'
);
ok( _document_for( $long_documents, 'post', 'post-1' ),
    'another thread\'s posts keep theirs' );

# Renaming, moving or restoring a thread re-derives its posts one batch per
# outbox message: the first with the event, each next one recorded as its own
# event. All of them in the one message held the dispatcher -- and every
# reply's realtime push, notifications and cache purge behind it -- for as
# long as a large thread took.
my $batching_indexer = GPForum::Test::SearchIndexer->new(
    batch_size   => $SMALL_BATCH,
    thread_posts => { 'thread-long' => $LONG_THREAD_POSTS },
);
my $recorder = GPForum::Test::SearchEventRecorder->new;
my $batching = GPForum::Worker::Handler::SearchIndexing->new(
    indexer  => $batching_indexer,
    recorder => $recorder,
);
my %moved = (
    actor_id       => 'user-1',
    aggregate_id   => 'thread-long',
    aggregate_type => 'thread',
    correlation_id => 'correlation-1',
    event_id       => 'event-moved',
    event_type     => 'thread.moved',
);
is( $batching->handle( \%moved )->{indexed}{posts_indexed}{indexed},
    $SMALL_BATCH, 'a moved thread indexes one batch of its posts' );
is( scalar @{ $recorder->events }, 1, 'and records one event for the next' );
is_deeply(
    _event_fields( $recorder->events->[0] ),
    {
        aggregate_id    => 'thread-long',
        aggregate_type  => 'thread',
        causation_id    => 'event-moved',
        correlation_id  => 'correlation-1',
        event_type      => 'search.thread_posts_requested',
        idempotency_key => "search.thread_posts:event-moved:$SMALL_BATCH",
        payload         => {
            after          => $SMALL_BATCH,
            cause_event_id => 'event-moved',
            thread_id      => 'thread-long',
        },
    },
    'its own event on the thread, naming where the next batch starts'
);
$batching->handle( \%moved );
is( scalar @{ $recorder->events }, 1, 'a retried event records nothing new' );

_deliver_chain( $batching, $recorder );
is_deeply(
    [
        map  { $_->[2] }
        grep { $_->[0] eq 'thread_posts' } @{ $batching_indexer->calls }
    ],
    [ undef, undef, $SMALL_BATCH, $TWO_BATCHES ],
    'each batch starts where the one before ended'
);
is( scalar @{ $recorder->events },
    2, 'until the thread is done, when nothing more is recorded' );
is_deeply(
    [ @{ $recorder->events->[1] }{qw(idempotency_key causation_id)} ],
    [ "search.thread_posts:event-moved:$TWO_BATCHES", 'recorded-1' ],
    'every link keyed by the event that started the chain'
);
$batching->handle( $recorder->events->[0] );
is( scalar @{ $recorder->events }, 2, 'a retried batch records nothing new' );
ok(
    (
        none { $_->{event_type} eq 'search.rebuild_requested' }
          @{ $recorder->events }
    ),
    'and none is a console rebuild step: the last rebuild shown stays as it was'
);

$batching->handle(
    {
        aggregate_id   => 'action-2',
        aggregate_type => 'moderation_action',
        domain_payload => {
            target_id   => 'thread-long',
            target_type => 'thread',
        },
        event_id   => 'event-reversed',
        event_type => 'moderation_action.reversed',
    }
);
is(
    $recorder->events->[-1]{idempotency_key},
    "search.thread_posts:event-reversed:$SMALL_BATCH",
    'a reversed thread moderation starts a chain of its own'
);

done_testing();

sub _deleted_entity {
    my ( $rows, $type, $id ) = @_;

    return any { _entity_is( $_, $type, $id ) } @{$rows};
}

sub _document_for {
    my ( $documents, $type, $id ) = @_;

    return any { _entity_is( $_->data, $type, $id ) } @{ $documents->rows };
}

sub _long_post {
    my ( $parent, $template, $position ) = @_;

    return GPForum::Test::SearchRow->new(
        current_body => $template->current_body,
        thread       => $parent,
        data         => {
            %{ $template->data },
            position  => $position,
            post_id   => "long-post-$position",
            thread_id => $parent->get_column('thread_id'),
        },
    );
}

# The post ids of each batch delete, as bound to entity_id = ANY(?).
sub _removed_post_batches {
    my ($documents) = @_;

    return [
        map  { [ @{ ${ $_->{entity_id} }->[1][1] } ] }
        grep { ref $_->{entity_id} } @{ $documents->deleted }
    ];
}

sub _event_fields {
    my ($event) = @_;

    return {
        map { $_ => $event->{$_} }
          qw(aggregate_id aggregate_type causation_id correlation_id
          event_type idempotency_key payload)
    };
}

# Every recorded event, delivered once and in order, as the outbox would,
# including those recorded along the way.
sub _deliver_chain {
    my ( $indexing, $recorded ) = @_;

    my $delivered = 0;
    while ( $delivered < @{ $recorded->events } ) {
        $indexing->handle( $recorded->events->[$delivered] );
        $delivered++;
    }

    return $delivered;
}

sub _entity_is {
    my ( $row, $type, $id ) = @_;

    if ( $row->{entity_type} ne $type ) {
        return 0;
    }
    if ( $row->{entity_id} ne $id ) {
        return 0;
    }

    return 1;
}

sub _indexer_called {
    my ( $calls, $name, $id ) = @_;

    return grep { _call_is( $_, $name, $id ) } @{$calls};
}

sub _call_is {
    my ( $call, $name, $id ) = @_;

    if ( $call->[0] ne $name ) {
        return 0;
    }
    if ( $call->[1] ne $id ) {
        return 0;
    }

    return 1;
}

sub _author_qualified {
    my ($keys) = @_;

    return all { _is_qualified_column($_) } @{$keys};
}

sub _is_qualified_column {
    my ($name) = @_;

    if ( $name =~ /\A (?:-|me[.]) /msx ) {
        return 1;
    }

    return 0;
}

1;
