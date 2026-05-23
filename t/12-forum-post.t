package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostStore;
use GPForum::Test::Id;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 31;

plan tests => $EXPECTED_TESTS;

my $id_service = GPForum::Test::Id->new;
my $composer =
  GPForum::Service::Forum::PostComposer->new( id_service => $id_service, );

my $prepared = $composer->prepare(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-1',
        position       => 2,
        body_source    => 'Reply <body> & thanks',
        body_hash      => 'hash-2',
        visibility     => 'public',
    }
);

ok( $prepared->{ok}, 'post command is prepared' );
is( $prepared->{command}{post}{post_id}, 'generated-1',
    'post id is generated' );
is( $prepared->{command}{body}{body_id}, 'generated-2',
    'body id is generated' );
is( $prepared->{command}{revision}{revision_id},
    'generated-3', 'revision id is generated' );
is( $prepared->{command}{post}{thread_id}, 'thread-1', 'post targets thread' );
is( $prepared->{command}{post}{position},  2, 'post position is kept' );
is( $prepared->{command}{post}{current_body_id},
    'generated-2', 'post points at current body' );
is( $prepared->{command}{post}{current_revision_id},
    'generated-3', 'post points at current revision' );
is(
    $prepared->{command}{body}{body_rendered_safe},
    'Reply &lt;body&gt; &amp; thanks',
    'body is rendered safely'
);
is( $prepared->{command}{counter_shard}{thread_id},
    'thread-1', 'counter shard targets thread' );
is( $prepared->{command}{counter_shard}{shard_id},
    0, 'counter shard uses deterministic initial shard' );
is( $prepared->{command}{counter_shard}{reply_count_delta},
    1, 'counter shard records one reply delta' );

my $invalid = $composer->prepare(
    {
        thread_id      => q{},
        author_user_id => q{},
        position       => 0,
        body_source    => q{},
        body_hash      => q{},
        visibility     => 'secret',
    }
);

ok( !$invalid->{ok}, 'invalid post command is rejected' );
is(
    $invalid->{errors}{thread_id},
    'thread_id is required',
    'thread is required'
);
is(
    $invalid->{errors}{author_user_id},
    'author_user_id is required',
    'author is required'
);
is(
    $invalid->{errors}{position},
    'position is invalid',
    'position is validated'
);
is( $invalid->{errors}{body_source}, 'body is required', 'body is required' );
is(
    $invalid->{errors}{body_hash},
    'body_hash is required',
    'body hash is required'
);
is(
    $invalid->{errors}{visibility},
    'visibility is invalid',
    'visibility is validated'
);

my $schema = GPForum::Test::Schema->new;
my $store  = GPForum::Service::Forum::PostStore->new(
    schema     => $schema,
    id_service => GPForum::Test::Id->new,
);

my $stored = $store->create_post( $prepared->{command} );

ok( $stored->{ok}, 'post command is persisted' );
is( scalar @{ $schema->created_for('Post') },     1, 'post is created' );
is( scalar @{ $schema->created_for('PostBody') }, 1, 'body is created' );
is( scalar @{ $schema->created_for('PostRevision') }, 1,
    'revision is created' );
is( scalar @{ $schema->created_for('ThreadCounterShard') },
    1, 'counter shard delta is created' );
is( scalar @{ $schema->created_for('EventLog') }, 1, 'event is created' );
is( scalar @{ $schema->created_for('AuditLog') }, 1, 'audit is created' );
is( $schema->transaction_count, 1, 'post persistence uses one transaction' );
is( $schema->created_for('EventLog')->[0]{event_type},
    'post.created', 'post creation event is recorded' );
is( $schema->created_for('AuditLog')->[0]{action},
    'post.created', 'post audit is recorded' );
is(
    $schema->created_for('EventLog')->[0]{correlation_id},
    $schema->created_for('AuditLog')->[0]{correlation_id},
    'event and audit share correlation id'
);
is( $schema->created_for('ThreadCounterShard')->[0]{reply_count_delta},
    1, 'stored counter shard records reply delta' );

1;
