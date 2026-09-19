package main;

use strict;
use warnings;

use Const::Fast;
use List::Util qw(all);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::DocumentBuilder;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::SearchIndexer;
use GPForum::Test::SearchPermissionEngine;
use GPForum::Test::SearchResultSet;
use GPForum::Test::SearchRow;
use GPForum::Test::SearchSchema;
use GPForum::Worker::Handler::SearchIndexing;

our $VERSION = '0.001';

const my $SEARCH_LIMIT        => 5;
const my $SEARCH_DEFAULT      => 20;
const my $SEARCH_MAX          => 50;
const my $POST_SOURCE_VERSION => 3;

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
my $indexer = GPForum::Service::Search::Indexer->new(
    schema     => $schema,
    clock      => GPForum::Test::FixedClock->new,
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
is( $rebuilt->{indexed}, 2, 'search rebuild indexes threads and posts' );
is( scalar @{ $indexed_documents->rows },
    2, 'search rebuild does not duplicate documents' );
is( $threads->last_query->{moderation_state},
    'visible', 'thread rebuild filters visible rows' );
is( $posts->last_query->{deleted_at},
    undef, 'post rebuild filters deleted rows' );

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
is( $search_documents->last_query->{-and}[0]{'me.visibility'}{-in}[1],
    'private', 'search applies permission visibility scopes' );
is( $search_documents->last_query->{-and}[0]{'me.category_id'},
    'category-1', 'search applies category filter' );
is( $search_documents->last_query->{-and}[0]{'me.author_user_id'},
    'user-1', 'search applies author filter' );
ok(
    (
        all { /\A (?:-|me[.]) /msx }
          keys %{ $search_documents->last_query->{-and}[0] }
    ),
    'search qualifies every column against the joined author'
);
is( $search_documents->last_query->{-and}[1]{'me.source_created_at'}{'>='},
    '2026-05-01', 'search applies lower date bound' );
like( ${ $search_documents->last_query->{-and}[0]{-or}[0] }->[0],
    qr/websearch_to_tsquery/msx, 'search applies PostgreSQL websearch query' );
like(
    ${ $search_documents->last_query->{-and}[0]{-or}[0] }->[0],
    qr/websearch_to_tsquery[(]me[.]language::regconfig/msx,
    'search casts the per-document language to regconfig'
);
like( ${ $search_documents->last_query->{-and}[0]{-or}[1] }->[0],
    qr/similarity/msx, 'search applies trigram fallback' );
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
    !$real_permission->can(
        undef, 'search.view',
        { visibility => 'members', entity_type => 'thread' }, {}
    ),
    'anonymous user cannot render members-only search result'
);
ok(
    $real_permission->can(
        { user_id => 'user-1' },
        'search.view', { visibility => 'private', author_user_id => 'user-1' },
        {},
    ),
    'private author can render own search result'
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
is( $fake_indexer->calls->[3][0],
    'post', 'reversal event indexes target post' );

done_testing();

1;
