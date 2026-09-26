# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS   => 144;
const my $RESTORED_VERSION => 3;
const my $RESTORE_LOCKS    => 3;

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

# ADR 0102: a thread without a visibility inherits its category's effective
# visibility, and may not ask for a broader one.
my %in_members = (
    author_user_id   => 'user-1',
    body_hash        => 'hash-9',
    body_source      => 'Hello members',
    category_id      => 'category-1',
    idempotency_key  => 'thread-command-9',
    title            => 'Members only',
    visibility_floor => 'members',
);
is( $composer->prepare( {%in_members} )->{command}{thread}{visibility},
    'members', 'a thread inherits its category\'s visibility' );
is(
    $composer->prepare( { %in_members, visibility => 'public' } )
      ->{errors}{visibility},
    'visibility is broader than its category',
    'and may not be broader than it'
);
is(
    $composer->prepare( { %in_members, visibility => 'private' } )
      ->{command}{thread}{visibility},
    'private',
    'but may be narrower'
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

my $raced = $store->create_thread( $prepared->{command} );
ok( $raced->{ok},      'unique thread race succeeds' );
ok( $raced->{skipped}, 'unique thread race reuses the existing thread' );
is( scalar @{ $schema->created_for('Thread') },
    1, 'unique thread race does not insert a second thread' );
is( scalar @{ $schema->created_for('EventLog') },
    2, 'unique thread race does not write a second event' );

my $thread_pk_schema = GPForum::Test::Schema->new;
$thread_pk_schema->resultset('Thread')->create(
    {
        author_user_id => 'user-other',
        category_id    => 'category-other',
        slug           => 'other',
        thread_id      => 'generated-1',
        title          => 'Other',
    }
);
my $thread_pk_ids = GPForum::Test::Id->new;
my $thread_pk_prepared =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $thread_pk_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-pk',
        body_source     => 'PK remint body',
        category_id     => 'category-1',
        idempotency_key => 'thread-pk-command-1',
        title           => 'PK remint thread',
        visibility      => 'public',
    }
  );
my $thread_pk_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $thread_pk_ids,
    schema     => $thread_pk_schema,
);
my $thread_pk =
  $thread_pk_store->create_thread( $thread_pk_prepared->{command} );
ok( $thread_pk->{ok}, 'unique thread id collision remints and creates' );
ok( !$thread_pk->{skipped},
    'unique thread id collision does not return another thread' );
is( $thread_pk->{thread}{thread_id},
    'generated-5', 'unique thread id collision remints the id' );
is( $thread_pk->{thread}{slug},
    'pk-remint-thread', 'unique thread id collision keeps this slug' );

my $thread_leftover_schema = GPForum::Test::Schema->new;
my $thread_leftover_ids    = GPForum::Test::Id->new;
my $thread_leftover_prepared =
  GPForum::Service::Forum::ThreadComposer->new(
    id_service => $thread_leftover_ids )->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-leftover',
        body_source     => 'Leftover thread body',
        category_id     => 'category-1',
        idempotency_key => 'thread-leftover-command-1',
        title           => 'Leftover thread',
        visibility      => 'public',
    }
    );
$thread_leftover_schema->resultset('Thread')->create(
    {
        author_user_id => 'user-1',
        category_id    => 'category-1',
        slug           => 'leftover-thread',
        thread_id      => 'generated-1',
        title          => 'Leftover thread',
    }
);
my $thread_leftover_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $thread_leftover_ids,
    schema     => $thread_leftover_schema,
);
my $thread_leftover =
  $thread_leftover_store->create_thread( $thread_leftover_prepared->{command} );
ok( $thread_leftover->{ok},
    'leftover thread id race reuses this thread and finishes opening' );
ok( !$thread_leftover->{skipped},
    'leftover thread id race does not skip the missing opening post' );
is( $thread_leftover->{thread}{thread_id},
    'generated-1', 'leftover thread id race keeps this thread' );
is( $thread_leftover->{thread}{slug},
    'leftover-thread', 'leftover thread id race keeps this slug' );
is( scalar @{ $thread_leftover_schema->created_for('Thread') },
    1, 'leftover thread id race does not insert a second thread' );
is( scalar @{ $thread_leftover_schema->created_for('Post') },
    1, 'leftover thread id race inserts the missing opening post' );

my $op_pk_schema = GPForum::Test::Schema->new;
$op_pk_schema->resultset('Post')->create(
    {
        author_user_id => 'user-other',
        post_id        => 'generated-2',
        thread_id      => 'thread-other',
        position       => 1,
    }
);
my $op_pk_ids = GPForum::Test::Id->new;
my $op_pk_prepared =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $op_pk_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-pk',
        body_source     => 'OP PK remint body',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-pk-command-1',
        title           => 'OP PK remint',
        visibility      => 'public',
    }
  );
my $op_pk_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_pk_ids,
    schema     => $op_pk_schema,
);
my $op_pk = $op_pk_store->create_thread( $op_pk_prepared->{command} );
ok( $op_pk->{ok}, 'unique opening post id collision remints and creates' );
ok( !$op_pk->{skipped},
    'unique opening post id collision does not return another post' );
is( $op_pk->{post}{post_id},
    'generated-5', 'unique opening post id collision remints the id' );
is( $op_pk->{thread}{thread_id},
    'generated-1', 'unique opening post id collision keeps this thread' );

my $op_leftover_schema = GPForum::Test::Schema->new;
$op_leftover_schema->resultset('Post')->create(
    {
        author_user_id => 'user-1',
        post_id        => 'generated-2',
        thread_id      => 'generated-1',
        position       => 1,
    }
);
my $op_leftover_ids = GPForum::Test::Id->new;
my $op_leftover_prepared =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $op_leftover_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-leftover',
        body_source     => 'OP leftover body',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-leftover-1',
        title           => 'OP leftover',
        visibility      => 'public',
    }
  );
my $op_leftover_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_leftover_ids,
    schema     => $op_leftover_schema,
);
my $op_leftover =
  $op_leftover_store->create_thread( $op_leftover_prepared->{command} );
ok( $op_leftover->{ok},
    'leftover opening post id race reuses this post and finishes copy' );
ok( !$op_leftover->{skipped},
    'leftover opening post id race does not skip the missing body' );
is( $op_leftover->{post}{post_id},
    'generated-2', 'leftover opening post id race keeps this post' );
is( $op_leftover->{thread}{thread_id},
    'generated-1', 'leftover opening post id race keeps this thread' );
is( scalar @{ $op_leftover_schema->created_for('Post') },
    1, 'leftover opening post id race does not insert a second post' );
is( scalar @{ $op_leftover_schema->created_for('PostBody') },
    1, 'leftover opening post id race inserts the missing body' );

my $op_body_schema = GPForum::Test::Schema->new;
$op_body_schema->resultset('PostBody')->create(
    {
        body_id => 'generated-3',
        post_id => 'other-post',
    }
);
my $op_body_ids = GPForum::Test::Id->new;
my $op_body_prepared =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $op_body_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-body-pk',
        body_source     => 'OP body PK remint',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-body-pk-1',
        title           => 'OP body PK remint',
        visibility      => 'public',
    }
  );
my $op_body_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_body_ids,
    schema     => $op_body_schema,
);
my $op_body = $op_body_store->create_thread( $op_body_prepared->{command} );
ok( $op_body->{ok}, 'unique opening body id collision remints and creates' );
ok( !$op_body->{skipped},
    'unique opening body id collision does not reuse another body' );
is( $op_body->{post}{current_body_id},
    'generated-5', 'unique opening body id collision remints the id' );
is( $op_body->{post}{post_id},
    'generated-2', 'unique opening body id collision keeps this post' );

my $op_body_leftover_schema = GPForum::Test::Schema->new;
$op_body_leftover_schema->resultset('PostBody')->create(
    {
        body_id => 'generated-3',
        post_id => 'generated-2',
    }
);
my $op_body_leftover_ids = GPForum::Test::Id->new;
my $op_body_leftover_prepared =
  GPForum::Service::Forum::ThreadComposer->new(
    id_service => $op_body_leftover_ids )->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-body-leftover',
        body_source     => 'OP leftover body copy',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-body-leftover-1',
        title           => 'OP leftover body',
        visibility      => 'public',
    }
    );
my $op_body_leftover_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_body_leftover_ids,
    schema     => $op_body_leftover_schema,
);
my $op_body_leftover =
  $op_body_leftover_store->create_thread(
    $op_body_leftover_prepared->{command} );
ok( $op_body_leftover->{ok},
    'leftover opening body id race reuses this body and finishes copy' );
ok( !$op_body_leftover->{skipped},
    'leftover opening body id race does not skip the missing revision' );
is( $op_body_leftover->{post}{current_body_id},
    'generated-3', 'leftover opening body id race keeps this body' );
is( $op_body_leftover->{post}{post_id},
    'generated-2', 'leftover opening body id race keeps this post' );
is( scalar @{ $op_body_leftover_schema->created_for('PostBody') },
    1, 'leftover opening body id race does not insert a second body' );
is( scalar @{ $op_body_leftover_schema->created_for('PostRevision') },
    1, 'leftover opening body id race inserts the missing revision' );

my $op_rev_schema = GPForum::Test::Schema->new;
$op_rev_schema->resultset('PostRevision')->create(
    {
        post_id     => 'other-post',
        revision_id => 'generated-4',
    }
);
my $op_rev_ids = GPForum::Test::Id->new;
my $op_rev_prepared =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $op_rev_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-rev-pk',
        body_source     => 'OP revision PK remint',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-rev-pk-1',
        title           => 'OP revision PK remint',
        visibility      => 'public',
    }
  );
my $op_rev_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_rev_ids,
    schema     => $op_rev_schema,
);
my $op_rev = $op_rev_store->create_thread( $op_rev_prepared->{command} );
ok( $op_rev->{ok}, 'unique opening revision id collision remints and creates' );
ok( !$op_rev->{skipped},
    'unique opening revision id collision does not reuse another revision' );
is( $op_rev->{post}{current_revision_id},
    'generated-5', 'unique opening revision id collision remints the id' );
is( $op_rev->{post}{post_id},
    'generated-2', 'unique opening revision id collision keeps this post' );

my $op_rev_leftover_schema = GPForum::Test::Schema->new;
$op_rev_leftover_schema->resultset('PostRevision')->create(
    {
        post_id     => 'generated-2',
        revision_id => 'generated-4',
    }
);
my $op_rev_leftover_ids = GPForum::Test::Id->new;
my $op_rev_leftover_prepared =
  GPForum::Service::Forum::ThreadComposer->new(
    id_service => $op_rev_leftover_ids )->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-rev-leftover',
        body_source     => 'OP leftover revision',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-rev-leftover-1',
        title           => 'OP leftover revision',
        visibility      => 'public',
    }
    );
my $op_rev_leftover_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_rev_leftover_ids,
    schema     => $op_rev_leftover_schema,
);
my $op_rev_leftover =
  $op_rev_leftover_store->create_thread( $op_rev_leftover_prepared->{command} );
ok( $op_rev_leftover->{ok},
    'leftover opening revision id race reuses this revision and finishes' );
ok( !$op_rev_leftover->{skipped},
    'leftover opening revision id race does not skip the missing counter' );
is( $op_rev_leftover->{post}{current_revision_id},
    'generated-4', 'leftover opening revision id race keeps this revision' );
is( $op_rev_leftover->{post}{post_id},
    'generated-2', 'leftover opening revision id race keeps this post' );
is( scalar @{ $op_rev_leftover_schema->created_for('PostRevision') },
    1, 'leftover opening revision id race does not insert a second revision' );
is( scalar @{ $op_rev_leftover_schema->created_for('ThreadCounter') },
    1, 'leftover opening revision id race inserts the missing counter' );

my $op_counter_schema = GPForum::Test::Schema->new;
$op_counter_schema->resultset('ThreadCounter')->create(
    {
        last_post_id        => 'post-other',
        reply_count         => 0,
        thread_id           => 'generated-1',
        visible_reply_count => 0,
    }
);
my $op_counter_ids = GPForum::Test::Id->new;
my $op_counter_prepared =
  GPForum::Service::Forum::ThreadComposer->new( id_service => $op_counter_ids )
  ->prepare(
    {
        author_user_id  => 'user-1',
        body_hash       => 'hash-op-counter-pk',
        body_source     => 'OP counter PK reuse',
        category_id     => 'category-1',
        idempotency_key => 'thread-op-counter-pk-1',
        title           => 'OP counter PK reuse',
        visibility      => 'public',
    }
  );
my $op_counter_store = GPForum::Service::Forum::ThreadStore->new(
    id_service => $op_counter_ids,
    schema     => $op_counter_schema,
);
my $op_counter =
  $op_counter_store->create_thread( $op_counter_prepared->{command} );
ok( $op_counter->{ok}, 'unique opening counter collision reuses and creates' );
ok( !$op_counter->{skipped},
    'unique opening counter collision does not skip this thread' );
is( $op_counter->{thread}{thread_id},
    'generated-1', 'unique opening counter collision keeps this thread' );
is( scalar @{ $op_counter_schema->created_for('ThreadCounter') },
    1, 'unique opening counter collision does not insert a second counter' );

my $title_prepared = $composer->prepare_title(
    {
        editor_user_id  => 'user-1',
        idempotency_key => 'thread-edit-command-1',
        thread_id       => 'thread-1',
        title           => '  Edited Welcome  ',
    }
);
ok( $title_prepared->{ok}, 'thread title command is prepared' );
is(
    $title_prepared->{command}{thread}{title},
    'Edited Welcome',
    'thread title is normalized'
);
is( $title_prepared->{command}{thread}{slug},
    'edited-welcome', 'edited title is normalized into slug' );
is(
    $composer->prepare_title(
        {
            editor_user_id => q{},
            thread_id      => q{},
            title          => 'no',
        }
    )->{errors}{title},
    'title length is invalid',
    'edited title length is validated'
);

my $edit_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $edit_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $edit_dbh,
    threads  => [
        {
            author_user_id => 'user-1',
            slug           => 'welcome-to-gp-forum',
            thread_id      => 'thread-1',
            title          => 'Welcome to GP Forum',
            version        => 1,
        },
    ],
);
my $edit_store = GPForum::Service::Forum::ThreadStore->new(
    schema     => $edit_schema,
    id_service => GPForum::Test::Id->new,
);
my $edited = $edit_store->edit_thread( $title_prepared->{command} );

ok( $edited->{ok}, 'thread title edit is persisted' );
is(
    $edit_schema->threads->[0]{title},
    'Edited Welcome',
    'thread title is updated'
);
is( $edit_schema->threads->[0]{slug},
    'edited-welcome', 'thread slug follows the new title' );
is( $edit_schema->threads->[0]{version},
    2, 'thread title edit increments version' );
is( $edit_schema->created_for('EventLog')->[0]{event_type},
    'thread.updated', 'thread update event is recorded' );
is(
    $edit_schema->created_for('EventLog')->[0]{idempotency_key},
    'command:thread-edit-command-1:thread.updated',
    'thread update event uses command idempotency key'
);
is( $edit_schema->created_for('AuditLog')->[0]{action},
    'thread.updated', 'thread update audit is recorded' );
my @edit_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $edit_dbh->calls };
is( scalar @edit_locks, 1, 'thread title edit locks the thread row' );
is( $edit_locks[0]{bind}[0],
    'thread-1', 'thread row lock targets the edited thread' );
my $edit_events = scalar @{ $edit_schema->created_for('EventLog') };
my $edit_audits = scalar @{ $edit_schema->created_for('AuditLog') };
my $same_title  = $edit_store->edit_thread( $title_prepared->{command} );
ok( $same_title->{skipped}, 'unchanged thread title edit is skipped' );
is( $edit_schema->threads->[0]{version},
    2, 'unchanged thread title does not bump version' );
is( scalar @{ $edit_schema->created_for('EventLog') },
    $edit_events, 'unchanged thread title does not write another event' );
is( scalar @{ $edit_schema->created_for('AuditLog') },
    $edit_audits, 'unchanged thread title does not write another audit' );

my $delete_clock  = GPForum::Test::FixedClock->new;
my $delete_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $delete_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $delete_dbh,
    threads  => [
        {
            author_user_id => 'user-1',
            category_id    => 'category-1',
            slug           => 'welcome-to-gp-forum',
            thread_id      => 'thread-1',
            title          => 'Welcome to GP Forum',
            version        => 1,
        },
    ],
);
my $delete_store = GPForum::Service::Forum::ThreadStore->new(
    clock      => $delete_clock,
    schema     => $delete_schema,
    id_service => GPForum::Test::Id->new,
);
my $deleted = $delete_store->delete_thread(
    {
        idempotency_key => 'thread-delete-command-1',
        thread          => {
            category_id => 'category-1',
            deleted_by  => 'user-1',
            thread_id   => 'thread-1',
        },
    }
);

ok( $deleted->{ok}, 'thread delete is persisted' );
is( $delete_schema->threads->[0]{deleted_at},
    '2026-05-23T12:00:00Z', 'thread delete stamps deleted_at' );
is( $delete_schema->threads->[0]{deleted_by},
    'user-1', 'thread delete records the author' );
is( $delete_schema->threads->[0]{version},
    2, 'thread delete increments version' );
is( $delete_schema->created_for('EventLog')->[0]{event_type},
    'thread.deleted', 'thread delete event is recorded' );
is(
    $delete_schema->created_for('EventLog')->[0]{idempotency_key},
    'command:thread-delete-command-1:thread.deleted',
    'thread delete event uses command idempotency key'
);
is( $delete_schema->created_for('AuditLog')->[0]{action},
    'thread.deleted', 'thread delete audit is recorded' );
my @delete_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $delete_dbh->calls };
is( scalar @delete_locks, 1, 'thread delete locks the thread row' );
is( $delete_locks[0]{bind}[0],
    'thread-1', 'thread row lock targets the deleted thread' );
is(
    $delete_store->delete_thread(
        {
            idempotency_key => 'thread-delete-command-2',
            thread          => {
                deleted_by => 'user-1',
                thread_id  => 'thread-1',
            },
        }
    )->{error},
    'thread not found',
    'already-deleted threads are rejected'
);

my $restored = $delete_store->restore_thread(
    {
        idempotency_key => 'thread-restore-command-1',
        thread          => {
            restored_by => 'user-1',
            thread_id   => 'thread-1',
        },
    }
);
ok( $restored->{ok}, 'thread restore is persisted' );
ok( !defined $delete_schema->threads->[0]{deleted_at},
    'thread restore clears deleted_at' );
ok( !defined $delete_schema->threads->[0]{deleted_by},
    'thread restore clears deleted_by' );
is( $delete_schema->threads->[0]{version},
    $RESTORED_VERSION, 'thread restore increments version' );
is( $delete_schema->created_for('EventLog')->[1]{event_type},
    'thread.undeleted', 'thread restore event is recorded' );
is(
    $delete_schema->created_for('EventLog')->[1]{idempotency_key},
    'command:thread-restore-command-1:thread.undeleted',
    'thread restore event uses command idempotency key'
);
is( $delete_schema->created_for('AuditLog')->[1]{action},
    'thread.undeleted', 'thread restore audit is recorded' );
my @restore_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $delete_dbh->calls };
is( scalar @restore_locks,
    $RESTORE_LOCKS, 'thread restore locks the thread row' );
is(
    $delete_store->restore_thread(
        {
            idempotency_key => 'thread-restore-command-2',
            thread          => {
                restored_by => 'user-1',
                thread_id   => 'thread-1',
            },
        }
    )->{error},
    'thread not found',
    'thread restore rejects a live thread'
);

my $move_prepared = $composer->prepare_move(
    {
        category_id     => 'category-2',
        editor_user_id  => 'user-1',
        idempotency_key => 'thread-move-command-1',
        thread_id       => 'thread-1',
    }
);
ok( $move_prepared->{ok}, 'thread move command is prepared' );
is( $move_prepared->{command}{thread}{category_id},
    'category-2', 'thread move keeps the destination category' );
is(
    $composer->prepare_move(
        {
            category_id    => q{},
            editor_user_id => 'user-1',
            thread_id      => 'thread-1',
        }
    )->{errors}{category_id},
    'category_id is required',
    'thread move requires a category'
);

my $move_dbh    = GPForum::Test::PostStoreLockDbh->new;
my $move_schema = GPForum::Test::PostStoreLockSchema->new(
    lock_dbh => $move_dbh,
    threads  => [
        {
            author_user_id => 'user-1',
            category_id    => 'category-1',
            slug           => 'welcome-to-gp-forum',
            thread_id      => 'thread-1',
            title          => 'Welcome to GP Forum',
            version        => 1,
        },
    ],
);
my $move_store = GPForum::Service::Forum::ThreadStore->new(
    schema     => $move_schema,
    id_service => GPForum::Test::Id->new,
);
my $moved = $move_store->move_thread( $move_prepared->{command} );

ok( $moved->{ok}, 'thread move is persisted' );
is( $move_schema->threads->[0]{category_id},
    'category-2', 'thread category is updated' );
is( $move_schema->threads->[0]{version}, 2, 'thread move increments version' );
is( $move_schema->created_for('EventLog')->[0]{event_type},
    'thread.moved', 'thread move event is recorded' );
is(
    $move_schema->created_for('EventLog')->[0]{idempotency_key},
    'command:thread-move-command-1:thread.moved',
    'thread move event uses command idempotency key'
);
is( $move_schema->created_for('AuditLog')->[0]{action},
    'thread.moved', 'thread move audit is recorded' );
my @move_locks =
  grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $move_dbh->calls };
is( scalar @move_locks, 1, 'thread move locks the thread row' );
is( $move_locks[0]{bind}[0],
    'thread-1', 'thread row lock targets the moved thread' );
my $move_events = scalar @{ $move_schema->created_for('EventLog') };
my $move_audits = scalar @{ $move_schema->created_for('AuditLog') };
my $same_move   = $move_store->move_thread( $move_prepared->{command} );
ok( $same_move->{skipped}, 'unchanged thread move is skipped' );
is( $move_schema->threads->[0]{version},
    2, 'unchanged thread move does not bump version' );
is( scalar @{ $move_schema->created_for('EventLog') },
    $move_events, 'unchanged thread move does not write another event' );
is( scalar @{ $move_schema->created_for('AuditLog') },
    $move_audits, 'unchanged thread move does not write another audit' );
is(
    $move_store->move_thread(
        {
            thread => {
                category_id => 'category-2',
                thread_id   => 'missing',
            },
        }
    )->{error},
    'thread not found',
    'missing threads cannot be moved'
);

1;
