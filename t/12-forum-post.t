package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS           => 158;
const my $ALLOCATED_REPLY_POSITION => 3;
const my $NEXT_REVISION            => 2;
const my $RESTORED_VERSION         => 3;
const my $RESTORE_LOCKS            => 3;

plan tests => $EXPECTED_TESTS;

my $id_service = GPForum::Test::Id->new;
my $composer =
  GPForum::Service::Forum::PostComposer->new( id_service => $id_service, );

my $prepared = $composer->prepare(
    {
        thread_id       => 'thread-1',
        author_user_id  => 'user-1',
        position        => 2,
        body_source     => 'Reply <body> & thanks',
        body_hash       => 'hash-2',
        idempotency_key => 'reply-command-1',
        visibility      => 'public',
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
is( $prepared->{command}{idempotency_key},
    'reply-command-1', 'post command preserves boundary idempotency key' );
is( $prepared->{command}{post}{current_body_id},
    'generated-2', 'post points at current body' );
is( $prepared->{command}{post}{current_revision_id},
    'generated-3', 'post points at current revision' );
is(
    $prepared->{command}{body}{body_rendered_safe},
    '<p>Reply &lt;body&gt; &amp; thanks</p>',
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
is( scalar @{ $schema->created_for('OutboxMessage') },
    1, 'outbox message is created' );
is( scalar @{ $schema->created_for('AuditLog') }, 1, 'audit is created' );
is( $schema->transaction_count, 1, 'post persistence uses one transaction' );
is( $schema->created_for('EventLog')->[0]{event_type},
    'post.created', 'post creation event is recorded' );
is(
    $schema->created_for('EventLog')->[0]{idempotency_key},
    'command:reply-command-1:post.created',
    'post creation event uses command idempotency key'
);
is(
    $schema->created_for('OutboxMessage')->[0]{event_id},
    $schema->created_for('EventLog')->[0]{event_id},
    'outbox message points at post event'
);
is( $schema->created_for('OutboxMessage')->[0]{queue},
    'events', 'outbox message uses event queue' );
is( $schema->created_for('AuditLog')->[0]{action},
    'post.created', 'post audit is recorded' );
is(
    $schema->created_for('EventLog')->[0]{correlation_id},
    $schema->created_for('AuditLog')->[0]{correlation_id},
    'event and audit share correlation id'
);
is( $schema->created_for('ThreadCounterShard')->[0]{reply_count_delta},
    1, 'stored counter shard records reply delta' );

my $raced_id = $store->create_post( $prepared->{command} );
ok( $raced_id->{ok},      'unique post id race succeeds' );
ok( $raced_id->{skipped}, 'unique post id race reuses the existing reply' );
is( scalar @{ $schema->created_for('Post') },
    1, 'unique post id race does not insert a second post' );
is( scalar @{ $schema->created_for('EventLog') },
    1, 'unique post id race does not write a second event' );

my $post_pk_schema = GPForum::Test::Schema->new;
$post_pk_schema->resultset('Post')->create(
    {
        author_user_id => 'user-other',
        post_id        => 'generated-1',
        thread_id      => 'thread-other',
        position       => 2,
    }
);
my $post_pk_ids = GPForum::Test::Id->new;
my $post_pk_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $post_pk_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-pk',
        body_source     => 'PK remint reply',
        idempotency_key => 'reply-pk-command-1',
        position        => 2,
        thread_id       => 'thread-pk',
        visibility      => 'public',
    }
  );
my $post_pk_store = GPForum::Service::Forum::PostStore->new(
    id_service => $post_pk_ids,
    schema     => $post_pk_schema,
);
my $post_pk = $post_pk_store->create_post( $post_pk_prepared->{command} );
ok( $post_pk->{ok}, 'unique post id collision remints and creates' );
ok( !$post_pk->{skipped},
    'unique post id collision does not return another post' );
is( $post_pk->{post}{post_id},
    'generated-4', 'unique post id collision remints the id' );
is( $post_pk->{post}{thread_id},
    'thread-pk', 'unique post id collision keeps this thread' );

my $post_leftover_schema = GPForum::Test::Schema->new;
my $post_leftover_ids    = GPForum::Test::Id->new;
my $post_leftover_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $post_leftover_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-leftover',
        body_source     => 'Leftover reply',
        idempotency_key => 'reply-leftover-command-1',
        position        => 2,
        thread_id       => 'thread-leftover',
        visibility      => 'public',
    }
  );
$post_leftover_schema->resultset('Post')->create(
    {
        author_user_id => 'user-1',
        post_id        => 'generated-1',
        thread_id      => 'thread-leftover',
        position       => 2,
    }
);
my $post_leftover_store = GPForum::Service::Forum::PostStore->new(
    id_service => $post_leftover_ids,
    schema     => $post_leftover_schema,
);
my $post_leftover =
  $post_leftover_store->create_post( $post_leftover_prepared->{command} );
ok( $post_leftover->{ok},
    'leftover post id race reuses this post and finishes copy' );
ok( !$post_leftover->{skipped},
    'leftover post id race does not skip the missing body' );
is( $post_leftover->{post}{post_id},
    'generated-1', 'leftover post id race keeps this post' );
is( $post_leftover->{post}{thread_id},
    'thread-leftover', 'leftover post id race keeps this thread' );
is( scalar @{ $post_leftover_schema->created_for('Post') },
    1, 'leftover post id race does not insert a second post' );
is( scalar @{ $post_leftover_schema->created_for('PostBody') },
    1, 'leftover post id race inserts the missing body' );

my $copy_body_schema = GPForum::Test::Schema->new;
$copy_body_schema->resultset('PostBody')->create(
    {
        body_id => 'generated-2',
        post_id => 'other-post',
    }
);
my $copy_body_ids = GPForum::Test::Id->new;
my $copy_body_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $copy_body_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-copy-body-pk',
        body_source     => 'Reply body PK remint',
        idempotency_key => 'reply-copy-body-pk-1',
        position        => 2,
        thread_id       => 'thread-copy-body',
        visibility      => 'public',
    }
  );
my $copy_body_store = GPForum::Service::Forum::PostStore->new(
    id_service => $copy_body_ids,
    schema     => $copy_body_schema,
);
my $copy_body = $copy_body_store->create_post( $copy_body_prepared->{command} );
ok( $copy_body->{ok}, 'unique reply body id collision remints and creates' );
ok( !$copy_body->{skipped},
    'unique reply body id collision does not reuse another body' );
is( $copy_body->{post}{current_body_id},
    'generated-4', 'unique reply body id collision remints the id' );
is( $copy_body->{post}{post_id},
    'generated-1', 'unique reply body id collision keeps this post' );

my $copy_body_leftover_schema = GPForum::Test::Schema->new;
$copy_body_leftover_schema->resultset('PostBody')->create(
    {
        body_id => 'generated-2',
        post_id => 'generated-1',
    }
);
my $copy_body_leftover_ids = GPForum::Test::Id->new;
my $copy_body_leftover_prepared =
  GPForum::Service::Forum::PostComposer->new(
    id_service => $copy_body_leftover_ids )->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-copy-body-leftover',
        body_source     => 'Reply leftover body',
        idempotency_key => 'reply-copy-body-leftover-1',
        position        => 2,
        thread_id       => 'thread-copy-body-leftover',
        visibility      => 'public',
    }
    );
my $copy_body_leftover_store = GPForum::Service::Forum::PostStore->new(
    id_service => $copy_body_leftover_ids,
    schema     => $copy_body_leftover_schema,
);
my $copy_body_leftover =
  $copy_body_leftover_store->create_post(
    $copy_body_leftover_prepared->{command} );
ok( $copy_body_leftover->{ok},
    'leftover reply body id race reuses this body and finishes copy' );
ok( !$copy_body_leftover->{skipped},
    'leftover reply body id race does not skip the missing revision' );
is( $copy_body_leftover->{post}{current_body_id},
    'generated-2', 'leftover reply body id race keeps this body' );
is( $copy_body_leftover->{post}{post_id},
    'generated-1', 'leftover reply body id race keeps this post' );
is( scalar @{ $copy_body_leftover_schema->created_for('PostBody') },
    1, 'leftover reply body id race does not insert a second body' );
is( scalar @{ $copy_body_leftover_schema->created_for('PostRevision') },
    1, 'leftover reply body id race inserts the missing revision' );

my $copy_rev_schema = GPForum::Test::Schema->new;
$copy_rev_schema->resultset('PostRevision')->create(
    {
        post_id     => 'other-post',
        revision_id => 'generated-3',
    }
);
my $copy_rev_ids = GPForum::Test::Id->new;
my $copy_rev_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $copy_rev_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-copy-rev-pk',
        body_source     => 'Reply revision PK remint',
        idempotency_key => 'reply-copy-rev-pk-1',
        position        => 2,
        thread_id       => 'thread-copy-rev',
        visibility      => 'public',
    }
  );
my $copy_rev_store = GPForum::Service::Forum::PostStore->new(
    id_service => $copy_rev_ids,
    schema     => $copy_rev_schema,
);
my $copy_rev = $copy_rev_store->create_post( $copy_rev_prepared->{command} );
ok( $copy_rev->{ok}, 'unique reply revision id collision remints and creates' );
ok( !$copy_rev->{skipped},
    'unique reply revision id collision does not reuse another revision' );
is( $copy_rev->{post}{current_revision_id},
    'generated-4', 'unique reply revision id collision remints the id' );
is( $copy_rev->{post}{post_id},
    'generated-1', 'unique reply revision id collision keeps this post' );

my $copy_rev_leftover_schema = GPForum::Test::Schema->new;
$copy_rev_leftover_schema->resultset('PostRevision')->create(
    {
        post_id     => 'generated-1',
        revision_id => 'generated-3',
    }
);
my $copy_rev_leftover_ids = GPForum::Test::Id->new;
my $copy_rev_leftover_prepared =
  GPForum::Service::Forum::PostComposer->new(
    id_service => $copy_rev_leftover_ids )->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-copy-rev-leftover',
        body_source     => 'Reply leftover revision',
        idempotency_key => 'reply-copy-rev-leftover-1',
        position        => 2,
        thread_id       => 'thread-copy-rev-leftover',
        visibility      => 'public',
    }
    );
my $copy_rev_leftover_store = GPForum::Service::Forum::PostStore->new(
    id_service => $copy_rev_leftover_ids,
    schema     => $copy_rev_leftover_schema,
);
my $copy_rev_leftover =
  $copy_rev_leftover_store->create_post(
    $copy_rev_leftover_prepared->{command} );
ok( $copy_rev_leftover->{ok},
    'leftover reply revision id race reuses this revision and finishes' );
ok( !$copy_rev_leftover->{skipped},
    'leftover reply revision id race does not skip the missing shard' );
is( $copy_rev_leftover->{post}{current_revision_id},
    'generated-3', 'leftover reply revision id race keeps this revision' );
is( $copy_rev_leftover->{post}{post_id},
    'generated-1', 'leftover reply revision id race keeps this post' );
is( scalar @{ $copy_rev_leftover_schema->created_for('PostRevision') },
    1, 'leftover reply revision id race does not insert a second revision' );
is( scalar @{ $copy_rev_leftover_schema->created_for('ThreadCounterShard') },
    1, 'leftover reply revision id race inserts the missing shard' );

my $allocated_prepared = $composer->prepare(
    {
        thread_id         => 'thread-1',
        author_user_id    => 'user-1',
        allocate_position => 1,
        body_source       => 'Allocated reply',
        body_hash         => 'hash-3',
        idempotency_key   => 'reply-command-2',
        visibility        => 'public',
    }
);
ok( $allocated_prepared->{ok}, 'post command can defer position allocation' );
is( $allocated_prepared->{command}{post}{position},
    0, 'deferred command keeps invalid placeholder out of caller logic' );

my $lock_dbh         = GPForum::Test::PostStoreLockDbh->new;
my $allocated_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $lock_dbh,
    posts    => [
        { post_id => 'post-2', thread_id => 'thread-1', position => 2 },
        { post_id => 'post-1', thread_id => 'thread-1', position => 1 },
    ],
);
my $allocated_store = GPForum::Service::Forum::PostStore->new(
    schema     => $allocated_schema,
    id_service => GPForum::Test::Id->new,
);
my $allocated_stored =
  $allocated_store->create_post( $allocated_prepared->{command} );

ok( $allocated_stored->{ok}, 'post store persists deferred position command' );
is( $allocated_schema->created_for('Post')->[0]{position},
    $ALLOCATED_REPLY_POSITION,
    'post store allocates next position inside persistence boundary' );
my @row_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $lock_dbh->calls };
is( scalar @row_locks, 1, 'position allocation locks the thread row' );
like(
    $row_locks[0]{sql},
    qr/FOR [ ] UPDATE/msx,
    'thread row lock uses FOR UPDATE'
);
is( $row_locks[0]{bind}[0],
    'thread-1', 'thread row lock targets the reply thread' );
is(
    $allocated_schema->created_for('EventLog')->[0]{idempotency_key},
    'command:reply-command-2:post.created',
    'allocated reply event keeps command idempotency key'
);

my $race_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $race_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $race_dbh,
    posts    => [
        { post_id => 'post-2', thread_id => 'thread-1', position => 2 },
        { post_id => 'post-1', thread_id => 'thread-1', position => 1 },
    ],
);
$race_schema->skip_search_count(1);
my $raced_store = GPForum::Service::Forum::PostStore->new(
    schema     => $race_schema,
    id_service => GPForum::Test::Id->new,
);
my $raced_stored = $raced_store->create_post( $allocated_prepared->{command} );
ok( $raced_stored->{ok}, 'unique position race retries allocation' );
is( $race_schema->created_for('Post')->[0]{position},
    $ALLOCATED_REPLY_POSITION,
    'unique position race stores the next free position' );
is( scalar @{ $race_schema->created_for('Post') },
    1, 'unique position race does not insert a second post' );
ok( !$raced_stored->{skipped}, 'unique position race does not skip the reply' );

my $shard_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $shard_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $shard_dbh,
    posts    => [
        { post_id => 'post-2', thread_id => 'thread-1', position => 2 },
        { post_id => 'post-1', thread_id => 'thread-1', position => 1 },
    ],
    thread_counter_shards => [
        {
            reply_count_delta => 1,
            shard_id          => 0,
            thread_id         => 'thread-1',
        }
    ],
);
$shard_schema->find_misses(1);
my $shard_store = GPForum::Service::Forum::PostStore->new(
    schema     => $shard_schema,
    id_service => GPForum::Test::Id->new,
);
my $raced_shard = $shard_store->create_post( $allocated_prepared->{command} );
ok( $raced_shard->{ok}, 'unique shard race applies the reply delta' );
is( $shard_schema->thread_counter_shards->[0]{reply_count_delta},
    2, 'unique shard race adds the delta to the winning row' );
is( scalar @{ $shard_schema->created_for('ThreadCounterShard') },
    0, 'unique shard race does not insert a second shard' );
is( scalar @{ $shard_schema->created_for('Post') },
    1, 'unique shard race does not drop the reply' );

my $revision_prepared = $composer->prepare_revision(
    {
        post_id         => 'post-1',
        editor_user_id  => 'user-1',
        body_source     => 'Edited <body> text',
        body_hash       => 'hash-edit',
        idempotency_key => 'edit-command-1',
        thread_id       => 'thread-1',
    }
);
ok( $revision_prepared->{ok}, 'revision command is prepared' );
is( $revision_prepared->{command}{revision}{revision_number},
    0, 'revision command defers revision numbering to the store' );
is( $revision_prepared->{command}{post}{post_id},
    'post-1', 'revision command keeps the existing post id' );
like( $revision_prepared->{command}{body}{body_rendered_safe},
    qr/Edited/msx, 'revision command renders the new body' );

my $invalid_revision = $composer->prepare_revision(
    {
        post_id        => q{},
        editor_user_id => q{},
        body_source    => q{},
        body_hash      => q{},
    }
);
ok( !$invalid_revision->{ok}, 'invalid revision command is rejected' );
is(
    $invalid_revision->{errors}{post_id},
    'post_id is required',
    'revision requires post id'
);
is(
    $invalid_revision->{errors}{editor_user_id},
    'editor_user_id is required',
    'revision requires editor'
);
is(
    $invalid_revision->{errors}{body_source},
    'body is required',
    'revision requires body'
);

my $edit_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $edit_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $edit_dbh,
    posts    => [
        {
            author_user_id      => 'user-1',
            current_body_id     => 'body-1',
            current_revision_id => 'rev-1',
            post_id             => 'post-1',
            thread_id           => 'thread-1',
            version             => 1,
        },
    ],
    post_revisions => [
        {
            post_id         => 'post-1',
            revision_number => 1,
        },
    ],
);
my $edit_store = GPForum::Service::Forum::PostStore->new(
    schema     => $edit_schema,
    id_service => GPForum::Test::Id->new,
);
my $edited = $edit_store->edit_post( $revision_prepared->{command} );

ok( $edited->{ok}, 'post edit is persisted' );
is( scalar @{ $edit_schema->created_for('PostBody') },
    1, 'edit creates a new body' );
is( scalar @{ $edit_schema->created_for('PostRevision') },
    1, 'edit creates a new revision' );
is( $edit_schema->created_for('PostRevision')->[0]{revision_number},
    $NEXT_REVISION, 'edit allocates the next revision number' );
is( $edit_schema->posts->[0]{version}, 2, 'edit increments post version' );
is( $edit_schema->created_for('EventLog')->[0]{event_type},
    'post.updated', 'post update event is recorded' );
is(
    $edit_schema->created_for('EventLog')->[0]{idempotency_key},
    'command:edit-command-1:post.updated',
    'post update event uses command idempotency key'
);
is( $edit_schema->created_for('AuditLog')->[0]{action},
    'post.updated', 'post update audit is recorded' );
my @edit_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $edit_dbh->calls };
is( scalar @edit_locks, 1, 'post edit locks the post row' );
is( $edit_locks[0]{bind}[0],
    'post-1', 'post row lock targets the edited post' );
my $edit_bodies = scalar @{ $edit_schema->created_for('PostBody') };
my $edit_revs   = scalar @{ $edit_schema->created_for('PostRevision') };
my $edit_events = scalar @{ $edit_schema->created_for('EventLog') };
my $edit_audits = scalar @{ $edit_schema->created_for('AuditLog') };
my $same_body   = $edit_store->edit_post( $revision_prepared->{command} );
ok( $same_body->{skipped}, 'unchanged post edit is skipped' );
is( $edit_schema->posts->[0]{version},
    2, 'unchanged post edit does not bump version' );
is( scalar @{ $edit_schema->created_for('PostBody') },
    $edit_bodies, 'unchanged post edit does not create another body' );
is( scalar @{ $edit_schema->created_for('PostRevision') },
    $edit_revs, 'unchanged post edit does not create another revision' );
is( scalar @{ $edit_schema->created_for('EventLog') },
    $edit_events, 'unchanged post edit does not write another event' );
is( scalar @{ $edit_schema->created_for('AuditLog') },
    $edit_audits, 'unchanged post edit does not write another audit' );

my $race_edit_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $race_edit_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $race_edit_dbh,
    posts    => [
        {
            author_user_id      => 'user-1',
            current_body_id     => 'body-1',
            current_revision_id => 'rev-1',
            post_id             => 'post-1',
            thread_id           => 'thread-1',
            version             => 1,
        },
    ],
    post_revisions => [
        {
            post_id         => 'post-1',
            revision_number => 1,
        },
    ],
);
$race_edit_schema->skip_search_count(1);
my $raced_edit_store = GPForum::Service::Forum::PostStore->new(
    schema     => $race_edit_schema,
    id_service => GPForum::Test::Id->new,
);
my $raced_edit = $raced_edit_store->edit_post( $revision_prepared->{command} );
ok( $raced_edit->{ok}, 'unique revision race retries allocation' );
is( $race_edit_schema->created_for('PostRevision')->[0]{revision_number},
    $NEXT_REVISION, 'unique revision race stores the next free number' );
is( scalar @{ $race_edit_schema->created_for('PostRevision') },
    1, 'unique revision race does not insert a second revision' );
ok( !$raced_edit->{skipped}, 'unique revision race does not skip the edit' );

my $id_edit_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $id_edit_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $id_edit_dbh,
    posts    => [
        {
            author_user_id      => 'user-1',
            current_body_id     => 'body-1',
            current_revision_id => 'rev-1',
            post_id             => 'post-1',
            thread_id           => 'thread-1',
            version             => 1,
        },
    ],
    post_bodies => [
        {
            body_id     => $revision_prepared->{command}{body}{body_id},
            post_id     => 'post-1',
            source_hash => 'hash-edit',
        },
    ],
    post_revisions => [
        {
            post_id     => 'post-1',
            revision_id => $revision_prepared->{command}{revision}{revision_id},
            revision_number => $NEXT_REVISION,
        },
    ],
);
my $id_edit_store = GPForum::Service::Forum::PostStore->new(
    schema     => $id_edit_schema,
    id_service => GPForum::Test::Id->new,
);
my $raced_edit_id = $id_edit_store->edit_post( $revision_prepared->{command} );
ok( $raced_edit_id->{ok}, 'unique revision id race succeeds' );
ok( !$raced_edit_id->{skipped},
    'unique revision id race reuses this revision and finishes' );
is( scalar @{ $id_edit_schema->created_for('PostBody') },
    0, 'unique revision id race does not insert a second body' );
is( scalar @{ $id_edit_schema->created_for('EventLog') },
    1, 'unique revision id race inserts the missing event' );

my $body_pk_schema = GPForum::Test::Schema->new;
$body_pk_schema->resultset('Post')->create(
    {
        author_user_id      => 'user-1',
        current_body_id     => 'body-old',
        current_revision_id => 'rev-old',
        post_id             => 'post-pk',
        thread_id           => 'thread-1',
        version             => 1,
    }
);
$body_pk_schema->resultset('PostBody')->create(
    {
        body_id     => 'generated-1',
        post_id     => 'other-post',
        source_hash => 'other',
    }
);
my $body_pk_ids = GPForum::Test::Id->new;
my $body_pk_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $body_pk_ids )
  ->prepare_revision(
    {
        body_hash       => 'hash-body-pk',
        body_source     => 'Body PK remint',
        editor_user_id  => 'user-1',
        idempotency_key => 'edit-body-pk-1',
        post_id         => 'post-pk',
        thread_id       => 'thread-1',
    }
  );
my $body_pk_store = GPForum::Service::Forum::PostStore->new(
    id_service => $body_pk_ids,
    schema     => $body_pk_schema,
);
my $body_pk = $body_pk_store->edit_post( $body_pk_prepared->{command} );
ok( $body_pk->{ok}, 'unique body id collision remints and edits' );
ok( !$body_pk->{skipped},
    'unique body id collision does not reuse another body' );
is( $body_pk_schema->posts->[0]{current_body_id},
    'generated-3', 'unique body id collision remints the id' );
is( $body_pk_schema->created_for('PostBody')->[-1]{post_id},
    'post-pk', 'unique body id collision keeps this post' );

my $body_leftover_schema = GPForum::Test::Schema->new;
$body_leftover_schema->resultset('Post')->create(
    {
        author_user_id      => 'user-1',
        current_body_id     => 'body-old',
        current_revision_id => 'rev-old',
        post_id             => 'post-pk',
        thread_id           => 'thread-1',
        version             => 1,
    }
);
$body_leftover_schema->resultset('PostBody')->create(
    {
        body_id     => 'generated-1',
        post_id     => 'post-pk',
        source_hash => 'hash-body-leftover',
    }
);
my $body_leftover_ids = GPForum::Test::Id->new;
my $body_leftover_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $body_leftover_ids )
  ->prepare_revision(
    {
        body_hash       => 'hash-body-leftover',
        body_source     => 'Body leftover',
        editor_user_id  => 'user-1',
        idempotency_key => 'edit-body-leftover-1',
        post_id         => 'post-pk',
        thread_id       => 'thread-1',
    }
  );
my $body_leftover_store = GPForum::Service::Forum::PostStore->new(
    id_service => $body_leftover_ids,
    schema     => $body_leftover_schema,
);
my $body_leftover =
  $body_leftover_store->edit_post( $body_leftover_prepared->{command} );
ok( $body_leftover->{ok},
    'leftover edit body id race reuses this body and finishes' );
ok( !$body_leftover->{skipped},
    'leftover edit body id race does not skip the missing revision' );
is( $body_leftover_schema->posts->[0]{current_body_id},
    'generated-1', 'leftover edit body id race keeps this body' );
is( $body_leftover_schema->posts->[0]{post_id},
    'post-pk', 'leftover edit body id race keeps this post' );
is( scalar @{ $body_leftover_schema->created_for('PostBody') },
    1, 'leftover edit body id race does not insert a second body' );
is( scalar @{ $body_leftover_schema->created_for('PostRevision') },
    1, 'leftover edit body id race inserts the missing revision' );

my $rev_pk_schema = GPForum::Test::Schema->new;
$rev_pk_schema->resultset('Post')->create(
    {
        author_user_id      => 'user-1',
        current_body_id     => 'body-old',
        current_revision_id => 'rev-old',
        post_id             => 'post-pk',
        thread_id           => 'thread-1',
        version             => 1,
    }
);
$rev_pk_schema->resultset('PostRevision')->create(
    {
        post_id         => 'other-post',
        revision_id     => 'generated-2',
        revision_number => 2,
    }
);
my $rev_pk_ids = GPForum::Test::Id->new;
my $rev_pk_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $rev_pk_ids )
  ->prepare_revision(
    {
        body_hash       => 'hash-rev-pk',
        body_source     => 'Revision PK remint',
        editor_user_id  => 'user-1',
        idempotency_key => 'edit-rev-pk-1',
        post_id         => 'post-pk',
        thread_id       => 'thread-1',
    }
  );
my $rev_pk_store = GPForum::Service::Forum::PostStore->new(
    id_service => $rev_pk_ids,
    schema     => $rev_pk_schema,
);
my $rev_pk = $rev_pk_store->edit_post( $rev_pk_prepared->{command} );
ok( $rev_pk->{ok}, 'unique revision id collision remints and edits' );
ok( !$rev_pk->{skipped},
    'unique revision id collision does not reuse another revision' );
is( $rev_pk_schema->posts->[0]{current_revision_id},
    'generated-3', 'unique revision id collision remints the id' );
is( $rev_pk_schema->created_for('PostRevision')->[-1]{post_id},
    'post-pk', 'unique revision id collision keeps this post' );

my $rev_leftover_schema = GPForum::Test::Schema->new;
$rev_leftover_schema->resultset('Post')->create(
    {
        author_user_id      => 'user-1',
        current_body_id     => 'body-old',
        current_revision_id => 'rev-old',
        post_id             => 'post-pk',
        thread_id           => 'thread-1',
        version             => 1,
    }
);
$rev_leftover_schema->resultset('PostRevision')->create(
    {
        post_id         => 'post-pk',
        revision_id     => 'generated-2',
        revision_number => 2,
    }
);
my $rev_leftover_ids = GPForum::Test::Id->new;
my $rev_leftover_prepared =
  GPForum::Service::Forum::PostComposer->new( id_service => $rev_leftover_ids )
  ->prepare_revision(
    {
        body_hash       => 'hash-rev-leftover',
        body_source     => 'Revision leftover',
        editor_user_id  => 'user-1',
        idempotency_key => 'edit-rev-leftover-1',
        post_id         => 'post-pk',
        thread_id       => 'thread-1',
    }
  );
my $rev_leftover_store = GPForum::Service::Forum::PostStore->new(
    id_service => $rev_leftover_ids,
    schema     => $rev_leftover_schema,
);
my $rev_leftover =
  $rev_leftover_store->edit_post( $rev_leftover_prepared->{command} );
ok( $rev_leftover->{ok},
    'leftover edit revision id race reuses this revision and finishes' );
ok( !$rev_leftover->{skipped},
    'leftover edit revision id race does not skip the missing pointers' );
is( $rev_leftover_schema->posts->[0]{current_revision_id},
    'generated-2', 'leftover edit revision id race keeps this revision' );
is( $rev_leftover_schema->posts->[0]{post_id},
    'post-pk', 'leftover edit revision id race keeps this post' );
is( scalar @{ $rev_leftover_schema->created_for('PostRevision') },
    1, 'leftover edit revision id race does not insert a second revision' );
is( scalar @{ $rev_leftover_schema->created_for('EventLog') },
    1, 'leftover edit revision id race inserts the missing event' );

my $delete_clock  = GPForum::Test::FixedClock->new;
my $delete_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $delete_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $delete_dbh,
    posts    => [
        {
            author_user_id => 'user-1',
            post_id        => 'post-1',
            thread_id      => 'thread-1',
            version        => 1,
        },
    ],
    thread_counter_shards => [
        {
            reply_count_delta => 1,
            shard_id          => 0,
            thread_id         => 'thread-1',
        },
    ],
);
my $delete_store = GPForum::Service::Forum::PostStore->new(
    clock      => $delete_clock,
    schema     => $delete_schema,
    id_service => GPForum::Test::Id->new,
);
my $deleted = $delete_store->delete_post(
    {
        idempotency_key => 'delete-command-1',
        post            => {
            deleted_by => 'user-1',
            post_id    => 'post-1',
            thread_id  => 'thread-1',
        },
    }
);

ok( $deleted->{ok}, 'post delete is persisted' );
is( $delete_schema->posts->[0]{deleted_at},
    '2026-05-23T12:00:00Z', 'post delete stamps deleted_at' );
is( $delete_schema->posts->[0]{deleted_by},
    'user-1', 'post delete records the author' );
is( $delete_schema->posts->[0]{version},
    2, 'post delete increments post version' );
is( $delete_schema->thread_counter_shards->[0]{reply_count_delta},
    0, 'post delete decrements the reply counter shard' );
is( $delete_schema->created_for('EventLog')->[0]{event_type},
    'post.deleted', 'post delete event is recorded' );
is(
    $delete_schema->created_for('EventLog')->[0]{idempotency_key},
    'command:delete-command-1:post.deleted',
    'post delete event uses command idempotency key'
);
is( $delete_schema->created_for('AuditLog')->[0]{action},
    'post.deleted', 'post delete audit is recorded' );
my @delete_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $delete_dbh->calls };
is( scalar @delete_locks, 1, 'post delete locks the post row' );
is( $delete_locks[0]{bind}[0],
    'post-1', 'post row lock targets the deleted post' );
is(
    $delete_store->delete_post(
        {
            idempotency_key => 'delete-command-2',
            post            => {
                deleted_by => 'user-1',
                post_id    => 'post-1',
                thread_id  => 'thread-1',
            },
        }
    )->{error},
    'post not found',
    'post delete rejects an already deleted post'
);

my $restored = $delete_store->restore_post(
    {
        idempotency_key => 'restore-command-1',
        post            => {
            restored_by => 'user-1',
            post_id     => 'post-1',
            thread_id   => 'thread-1',
        },
    }
);
ok( $restored->{ok}, 'post restore is persisted' );
ok( !defined $delete_schema->posts->[0]{deleted_at},
    'post restore clears deleted_at' );
ok( !defined $delete_schema->posts->[0]{deleted_by},
    'post restore clears deleted_by' );
is( $delete_schema->posts->[0]{version},
    $RESTORED_VERSION, 'post restore increments post version' );
is( $delete_schema->thread_counter_shards->[0]{reply_count_delta},
    1, 'post restore restores the reply counter' );
is( $delete_schema->created_for('EventLog')->[1]{event_type},
    'post.undeleted', 'post restore event is recorded' );
is( $delete_schema->created_for('AuditLog')->[1]{action},
    'post.undeleted', 'post restore audit is recorded' );
my @restore_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $delete_dbh->calls };
is( scalar @restore_locks, $RESTORE_LOCKS, 'post restore locks the post row' );
is(
    $delete_store->restore_post(
        {
            idempotency_key => 'restore-command-2',
            post            => {
                restored_by => 'user-1',
                post_id     => 'post-1',
                thread_id   => 'thread-1',
            },
        }
    )->{error},
    'post not found',
    'post restore rejects a live post'
);

1;
