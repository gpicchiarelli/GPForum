# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Mojo::JSON qw(encode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ThreadStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::PostingDouble;

our $VERSION = '0.001';

# What ThreadStore hands to its recorder for a new thread (the thread's
# event, its opening post's, caused by it, and the thread's audit row), a
# title edit, a move, a delete and a restore, captured as canonical JSON
# (keys sorted) on the code as it stood before the thread events moved to
# GPForum::Service::Forum::Event. The envelopes reach the outbox and its
# consumers, and the idempotency keys keep a replayed command from recording
# an event twice.
#
# A case missing from __DATA__ fails and notes its JSON, which is how the
# lines below were written.

my %golden = map { split m/\t/msx, $_, 2 } grep { length }
  map { s/\s+\z//msxr } <DATA>;

my %seen;

sub golden ( $name, $value ) {
    $seen{$name} = 1;
    my $json = encode_json($value);
    if ( !exists $golden{$name} ) {
        fail("$name has a golden line");
        note("$name\t$json");
        return;
    }
    is( $json, $golden{$name}, $name );

    return;
}

my $recorder = GPForum::Test::PostingDouble->new;
my $dbh      = GPForum::Test::PostStoreLockDbh->new;
my $store    = GPForum::Service::Forum::ThreadStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    recorder   => $recorder,
    schema     => GPForum::Test::PostStoreLockSchema->new( lock_dbh => $dbh ),
);

ok(
    $store->create_thread(
        {
            body => {
                body_id     => 'body-1',
                body_source => 'Opening',
                post_id     => 'post-1',
                source_hash => 'hash-1',
            },
            counter         => { reply_count => 0, thread_id => 'thread-1' },
            idempotency_key => 'thread-command',
            post            => {
                author_user_id      => 'user-1',
                current_body_id     => 'body-1',
                current_revision_id => 'revision-1',
                position            => 1,
                post_id             => 'post-1',
                thread_id           => 'thread-1',
            },
            revision => {
                body_id     => 'body-1',
                post_id     => 'post-1',
                revision_id => 'revision-1',
            },
            thread => {
                author_user_id => 'user-1',
                category_id    => 'category-1',
                slug           => 'hello',
                thread_id      => 'thread-1',
                title          => 'Hello',
                version        => 1,
                visibility     => 'public',
            },
        }
    )->{ok},
    'the thread is created'
);
golden( 'thread.created envelopes', $recorder->take );

# The lock reads back the row as PostgreSQL would: the thread's author too.
$dbh->thread_row(
    {
        author_user_id   => 'user-1',
        deleted_at       => undef,
        locked_at        => undef,
        moderation_state => 'visible',
    }
);

ok(
    $store->edit_thread(
        {
            idempotency_key => 'edit-command',
            thread          => {
                editor_user_id => 'user-1',
                slug           => 'new-title',
                thread_id      => 'thread-1',
                title          => 'New title',
            },
        }
    )->{ok},
    'the title is edited'
);
golden( 'thread.updated envelope', $recorder->take );

# Without a command key, the event is keyed by its type and aggregate.
ok(
    $store->move_thread(
        {
            thread => {
                category_id    => 'category-2',
                editor_user_id => 'user-1',
                thread_id      => 'thread-1',
            },
        }
    )->{ok},
    'the thread is moved'
);
golden( 'thread.moved envelope', $recorder->take );

# A delete and a restore that name no category or author take the row's.
ok(
    $store->delete_thread(
        {
            idempotency_key => 'delete-command',
            thread => { deleted_by => 'user-1', thread_id => 'thread-1' },
        }
    )->{ok},
    'the thread is deleted'
);
golden( 'thread.deleted envelope', $recorder->take );

$dbh->thread_row(
    {
        author_user_id   => 'user-1',
        deleted_at       => '2026-05-23T12:00:00Z',
        locked_at        => undef,
        moderation_state => 'visible',
    }
);
ok(
    $store->restore_thread(
        {
            idempotency_key => 'restore-command',
            thread => { restored_by => 'user-1', thread_id => 'thread-1' },
        }
    )->{ok},
    'the thread is restored'
);
golden( 'thread.undeleted envelope', $recorder->take );

for my $name ( sort keys %golden ) {
    ok( $seen{$name}, "golden line $name is still checked" );
}

done_testing();

1;

__DATA__
thread.created envelopes	[{"event":{"actor_id":"user-1","aggregate_id":"thread-1","aggregate_type":"thread","aggregate_version":1,"causation_id":null,"correlation_id":"generated-1","event_type":"thread.created","idempotency_key":"command:thread-command:thread.created","payload":{"author_user_id":"user-1","category_id":"category-1","thread_id":"thread-1","title":"Hello","visibility":"public"}}},{"event":{"actor_id":"user-1","aggregate_id":"post-1","aggregate_type":"post","aggregate_version":1,"causation_id":"event-1","correlation_id":"generated-1","event_type":"post.created","idempotency_key":"command:thread-command:post.created","payload":{"author_user_id":"user-1","post_id":"post-1","revision_id":"revision-1","thread_id":"thread-1"}}},{"audit":{"action":"thread.created","actor_id":"user-1","correlation_id":"generated-1","metadata":{"title":"Hello"},"schema_version":1,"target_id":"thread-1","target_type":"thread"}}]
thread.deleted envelope	[{"event":{"actor_id":"user-1","aggregate_id":"thread-1","aggregate_type":"thread","aggregate_version":1,"causation_id":null,"correlation_id":"generated-4","event_type":"thread.deleted","idempotency_key":"command:delete-command:thread.deleted","payload":{"category_id":"category-2","deleted_by":"user-1","thread_id":"thread-1"}}},{"audit":{"action":"thread.deleted","actor_id":"user-1","correlation_id":"generated-4","metadata":{"category_id":"category-2"},"schema_version":1,"target_id":"thread-1","target_type":"thread"}}]
thread.moved envelope	[{"event":{"actor_id":"user-1","aggregate_id":"thread-1","aggregate_type":"thread","aggregate_version":1,"causation_id":null,"correlation_id":"generated-3","event_type":"thread.moved","idempotency_key":"thread.moved:thread-1","payload":{"category_id":"category-2","editor_user_id":"user-1","previous_category_id":"category-1","thread_id":"thread-1"}}},{"audit":{"action":"thread.moved","actor_id":"user-1","correlation_id":"generated-3","metadata":{"category_id":"category-2","previous_category_id":"category-1"},"schema_version":1,"target_id":"thread-1","target_type":"thread"}}]
thread.undeleted envelope	[{"event":{"actor_id":"user-1","aggregate_id":"thread-1","aggregate_type":"thread","aggregate_version":1,"causation_id":null,"correlation_id":"generated-5","event_type":"thread.undeleted","idempotency_key":"command:restore-command:thread.undeleted","payload":{"author_user_id":"user-1","category_id":"category-2","restored_by":"user-1","thread_id":"thread-1"}}},{"audit":{"action":"thread.undeleted","actor_id":"user-1","correlation_id":"generated-5","metadata":{"category_id":"category-2"},"schema_version":1,"target_id":"thread-1","target_type":"thread"}}]
thread.updated envelope	[{"event":{"actor_id":"user-1","aggregate_id":"thread-1","aggregate_type":"thread","aggregate_version":1,"causation_id":null,"correlation_id":"generated-2","event_type":"thread.updated","idempotency_key":"command:edit-command:thread.updated","payload":{"editor_user_id":"user-1","slug":"new-title","thread_id":"thread-1","title":"New title"}}},{"audit":{"action":"thread.updated","actor_id":"user-1","correlation_id":"generated-2","metadata":{"slug":"new-title","title":"New title"},"schema_version":1,"target_id":"thread-1","target_type":"thread"}}]
