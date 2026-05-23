package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::DocumentBuilder;
use GPForum::Service::Search::Indexer;
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

const my $EXPECTED_TESTS      => 37;
const my $SEARCH_LIMIT        => 5;
const my $AT_CODE             => 64;
const my $MATCH_OPERATOR      => join q{}, chr $AT_CODE, chr $AT_CODE;
const my $POST_SOURCE_VERSION => 3;

plan tests => $EXPECTED_TESTS;

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
        title              => 'Welcome to GPForum',
        visibility         => 'public',
        moderation_state   => 'visible',
        visibility_version => 1,
        permission_version => 1,
        version            => 2,
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
        visibility         => 'public',
        moderation_state   => 'visible',
        visibility_version => 1,
        permission_version => 1,
        version            => 3,
        deleted_at         => undef,
    },
);

my $builder         = GPForum::Service::Search::DocumentBuilder->new;
my $thread_document = $builder->build_thread($thread);
my $post_document   = $builder->build_post($post);

is( $thread_document->{entity_type}, 'thread',   'thread document has type' );
is( $thread_document->{entity_id},   'thread-1', 'thread document has id' );
is( $thread_document->{space_id},    'space-1',  'thread document has space' );
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
is( $post_document->{entity_type},      'post',   'post document has type' );
is( $post_document->{entity_id},        'post-1', 'post document has id' );
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

my $threads          = GPForum::Test::SearchResultSet->new( rows => [$thread] );
my $posts            = GPForum::Test::SearchResultSet->new( rows => [$post] );
my $search_documents = GPForum::Test::SearchResultSet->new(
    rows => [
        GPForum::Test::SearchRow->new(
            data => {
                entity_type => 'thread',
                entity_id   => 'thread-1',
                visibility  => 'public',
            },
        ),
        GPForum::Test::SearchRow->new(
            data => {
                entity_type => 'post',
                entity_id   => 'post-denied',
                visibility  => 'private',
            },
        ),
    ],
);
my $schema = GPForum::Test::SearchSchema->new(
    resultsets => {
        Thread         => $threads,
        Post           => $posts,
        SearchDocument => $search_documents,
    },
);
my $indexer = GPForum::Service::Search::Indexer->new(
    schema     => $schema,
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);

my $indexed_thread = $indexer->index_thread('thread-1');
is( $indexed_thread->{search_document_id},
    'generated-1', 'thread index creates document id' );
is( $indexed_thread->{entity_type}, 'thread', 'thread index persists type' );
is( $indexed_thread->{indexed_at},
    '2026-05-23T12:00:00Z', 'thread index stores timestamp' );
like(
    $indexed_thread->{search_vector},
    qr/Welcome [ ] to [ ] GPForum/msx,
    'thread index creates vector input'
);
is( scalar @{ $search_documents->created },
    1, 'thread index upserts search document' );

my $indexed_post = $indexer->index_post('post-1');
is( $indexed_post->{search_document_id},
    'generated-2', 'post index creates document id' );
is( $indexed_post->{entity_type}, 'post', 'post index persists type' );
like(
    $indexed_post->{search_vector},
    qr/durable [ ] Perl/msx,
    'post index creates vector input'
);
is( scalar @{ $search_documents->created },
    2, 'post index upserts search document' );

my $removed = $indexer->remove_post('post-1');
ok( $removed->{ok}, 'post removal succeeds' );
is( $search_documents->deleted->[0]{entity_type},
    'post', 'post removal targets post documents' );
is( $search_documents->deleted->[0]{entity_id},
    'post-1', 'post removal targets entity id' );

my $rebuilt = $indexer->rebuild( { entity_type => 'all' } );
ok( $rebuilt->{ok}, 'search rebuild succeeds' );
is( $rebuilt->{indexed}, 2, 'search rebuild indexes threads and posts' );
is( $threads->last_query->{moderation_state},
    'visible', 'thread rebuild filters visible rows' );
is( $posts->last_query->{deleted_at},
    undef, 'post rebuild filters deleted rows' );

my $permission_engine = GPForum::Test::SearchPermissionEngine->new(
    visibility      => [ 'public', 'private' ],
    denied_entities => { 'post-denied' => 1 },
);
my $searcher = GPForum::Service::Search::Searcher->new(
    schema            => $schema,
    permission_engine => $permission_engine,
);
my $results = $searcher->search( { user_id => 'user-1' },
    'forum', { limit => $SEARCH_LIMIT } );

is( scalar @{$results}, 1, 'search filters denied render results' );
is( $search_documents->last_query->{visibility}{-in}[1],
    'private', 'search applies permission visibility scopes' );
is( $search_documents->last_query->{search_vector}{$MATCH_OPERATOR},
    'forum', 'search applies full-text query input' );
is( $search_documents->last_attrs->{rows},
    $SEARCH_LIMIT, 'search applies limit' );

my $autocomplete =
  $searcher->autocomplete( { user_id => 'user-1' }, 'Wel', {} );
is( scalar @{$autocomplete}, 1, 'autocomplete filters denied render results' );
is( $search_documents->last_query->{title_normalized}{-like},
    'wel%', 'autocomplete uses normalized title prefix' );

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

1;
