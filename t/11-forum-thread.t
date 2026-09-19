package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Test::Id;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 41;

plan tests => $EXPECTED_TESTS;

my $id_service = GPForum::Test::Id->new;
my $composer =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $id_service, );

my $prepared = $composer->prepare(
    {
        category_id     => 'category-1',
        author_user_id  => 'user-1',
        title           => '  Welcome to GP Forum  ',
        body_source     => 'Hello <forum> & welcome',
        body_hash       => 'hash-1',
        idempotency_key => 'thread-command-1',
        visibility      => 'public',
    }
);

ok( $prepared->{ok}, 'thread command is prepared' );
is( $prepared->{command}{thread}{thread_id},
    'generated-1', 'thread id is generated' );
is( $prepared->{command}{post}{post_id},
    'generated-2', 'post id is generated' );
is( $prepared->{command}{idempotency_key},
    'thread-command-1', 'thread command preserves boundary idempotency key' );
is( $prepared->{command}{body}{body_id},
    'generated-3', 'body id is generated' );
is( $prepared->{command}{revision}{revision_id},
    'generated-4', 'revision id is generated' );
is( $prepared->{command}{thread}{slug},
    'welcome-to-gp-forum', 'title is normalized into slug' );
ok(
    !exists $prepared->{command}{thread}{last_activity_at},
    'thread record lets PostgreSQL default last activity to now()'
);
ok(
    !exists $prepared->{command}{counter}{last_activity_at},
    'thread counter record lets PostgreSQL default last activity to now()'
);
is( $prepared->{command}{post}{current_body_id},
    'generated-3', 'post points at current body' );
is( $prepared->{command}{post}{current_revision_id},
    'generated-4', 'post points at current revision' );
is(
    $prepared->{command}{body}{body_rendered_safe},
    '<p>Hello &lt;forum&gt; &amp; welcome</p>',
    'body is rendered safely'
);
is( $prepared->{command}{revision}{revision_number},
    1, 'first revision number is one' );

my $invalid = $composer->prepare(
    {
        category_id    => q{},
        author_user_id => q{},
        title          => 'no',
        body_source    => q{},
        body_hash      => q{},
        visibility     => 'secret',
    }
);

ok( !$invalid->{ok}, 'invalid thread command is rejected' );
is(
    $invalid->{errors}{category_id},
    'category_id is required',
    'category is required'
);
is(
    $invalid->{errors}{author_user_id},
    'author_user_id is required',
    'author is required'
);
is(
    $invalid->{errors}{title},
    'title length is invalid',
    'title length is validated'
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
my $store  = GPForum::Service::Forum::ThreadStore->new(
    schema     => $schema,
    id_service => GPForum::Test::Id->new,
);

my $stored = $store->create_thread( $prepared->{command} );

ok( $stored->{ok}, 'thread command is persisted' );
is( scalar @{ $schema->created_for('Thread') },   1, 'thread is created' );
is( scalar @{ $schema->created_for('Post') },     1, 'post is created' );
is( scalar @{ $schema->created_for('PostBody') }, 1, 'body is created' );
is( scalar @{ $schema->created_for('PostRevision') }, 1,
    'revision is created' );
is( scalar @{ $schema->created_for('ThreadCounter') },
    1, 'counter projection is created' );
is( scalar @{ $schema->created_for('EventLog') }, 2, 'events are created' );
is( scalar @{ $schema->created_for('OutboxMessage') },
    2, 'outbox messages are created' );
is( scalar @{ $schema->created_for('AuditLog') }, 1, 'audit is created' );
is( $schema->transaction_count, 1, 'thread persistence uses one transaction' );
is( $schema->created_for('EventLog')->[0]{event_type},
    'thread.created', 'thread creation event is recorded' );
is( $schema->created_for('EventLog')->[1]{event_type},
    'post.created', 'post creation event is recorded' );
is(
    $schema->created_for('EventLog')->[0]{idempotency_key},
    'command:thread-command-1:thread.created',
    'thread creation event uses command idempotency key'
);
is(
    $schema->created_for('EventLog')->[1]{idempotency_key},
    'command:thread-command-1:post.created',
    'first post event uses command idempotency key without colliding'
);
is(
    $schema->created_for('OutboxMessage')->[0]{event_id},
    $schema->created_for('EventLog')->[0]{event_id},
    'thread outbox message points at thread event'
);
is(
    $schema->created_for('OutboxMessage')->[1]{event_id},
    $schema->created_for('EventLog')->[1]{event_id},
    'post outbox message points at post event'
);
is( $schema->created_for('OutboxMessage')->[0]{job_type},
    'domain_event.dispatch', 'outbox uses event dispatch job type' );
is(
    $schema->created_for('EventLog')->[1]{causation_id},
    $schema->created_for('EventLog')->[0]{event_id},
    'post event is caused by thread event'
);
is(
    $schema->created_for('EventLog')->[1]{correlation_id},
    $schema->created_for('EventLog')->[0]{correlation_id},
    'events share correlation id'
);
is( $schema->created_for('AuditLog')->[0]{action},
    'thread.created', 'thread audit is recorded' );
is( $schema->created_for('ThreadCounter')->[0]{reply_count},
    0, 'thread counter starts without replies' );

1;
