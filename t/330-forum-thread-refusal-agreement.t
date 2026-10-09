# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Domain::Thread;
use GPForum::Service::Forum::PostingWorkflow;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::PostingDouble;
use GPForum::Test::RowReader;

our $VERSION = '0.001';

# For every state a thread can be in, the workflow's check of an author's
# title edit, move, delete or restore before the transaction and
# ThreadStore's check under the thread's row lock give the same answer: the
# status of the store's refusal (GPForum::Domain::Thread->status_of) is the
# status the workflow answers, and where the workflow lets the write
# through, so does the store.

my $WRITER = 'author';
my $WHEN   = '2026-01-01T00:00:00Z';

my %THREAD = (
    'open' => {
        author_user_id   => 'author',
        moderation_state => 'visible',
    },
    'locked' => {
        author_user_id   => 'author',
        locked_at        => $WHEN,
        moderation_state => 'locked',
    },
    'hidden' => {
        author_user_id   => 'author',
        moderation_state => 'hidden',
    },
    'deleted by the writer' => {
        author_user_id   => 'author',
        deleted_at       => $WHEN,
        moderation_state => 'visible',
    },
    'deleted and locked' => {
        author_user_id   => 'author',
        deleted_at       => $WHEN,
        locked_at        => $WHEN,
        moderation_state => 'locked',
    },
    'deleted and hidden' => {
        author_user_id   => 'author',
        deleted_at       => $WHEN,
        moderation_state => 'hidden',
    },
    'deleted by another' => {
        author_user_id   => 'someone',
        deleted_at       => $WHEN,
        moderation_state => 'visible',
    },
    'open by another' => {
        author_user_id   => 'someone',
        moderation_state => 'visible',
    },
    'locked by another' => {
        author_user_id   => 'someone',
        locked_at        => $WHEN,
        moderation_state => 'locked',
    },
    'missing' => undef,
);

# The workflow method, and the command the workflow would hand the store.
my %OPERATION = (
    edit => {
        method  => 'edit_thread',
        command => {
            idempotency_key => 'edit-command',
            thread          => {
                editor_user_id => $WRITER,
                slug           => 'new-title',
                thread_id      => 'thread-1',
                title          => 'New title',
            },
        },
    },
    move => {
        method  => 'move_thread',
        command => {
            idempotency_key => 'move-command',
            thread          => {
                category_id    => 'other',
                editor_user_id => $WRITER,
                thread_id      => 'thread-1',
            },
        },
    },
    delete => {
        method  => 'delete_thread',
        command => {
            idempotency_key => 'delete-command',
            thread          => {
                category_id => 'general',
                deleted_by  => $WRITER,
                thread_id   => 'thread-1',
            },
        },
    },
    restore => {
        method  => 'restore_thread',
        command => {
            idempotency_key => 'restore-command',
            thread          => {
                author_user_id => 'author',
                category_id    => 'general',
                restored_by    => $WRITER,
                thread_id      => 'thread-1',
            },
        },
    },
);

for my $operation ( sort keys %OPERATION ) {
    for my $thread ( sort keys %THREAD ) {
        my $method = $OPERATION{$operation}{method};
        is(
            store_status(
                $method, $OPERATION{$operation}{command},
                $THREAD{$thread}
            ),
            workflow_status( $method, $THREAD{$thread} ),
            "$operation, $thread thread: the store agrees with the workflow"
        );
    }
}

done_testing();

sub workflow_status ( $method, $thread ) {
    my $reader = GPForum::Test::RowReader->new(
        thread => $thread,
        writer => $WRITER,
    );
    my $double   = GPForum::Test::PostingDouble->new;
    my $workflow = GPForum::Service::Forum::PostingWorkflow->new(
        category_reader      => $double,
        mention_store        => $double,
        post_composer        => $double,
        post_reader          => $double,
        post_store           => $double,
        thread_composer      => $double,
        thread_detail_reader => $reader,
        thread_store         => $double,
    );

    return $workflow->$method(
        {
            author_user_id => $WRITER,
            category_id    => 'other',
            command_id     => 'command-1',
            thread_id      => 'thread-1',
            title          => 'New title',
        }
    )->{status};
}

# The store finds the row the workflow read, and its lock reads it back the
# same: nothing changed in between.
sub store_status ( $method, $command, $thread ) {
    my $row =
      $thread
      ? {
        category_id => 'general',
        slug        => 'old-title',
        thread_id   => 'thread-1',
        title       => 'Old title',
        version     => 1,
        %{$thread},
      }
      : undef;
    my $store = GPForum::Service::Forum::ThreadStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        recorder   => GPForum::Test::PostingDouble->new,
        schema     => GPForum::Test::PostStoreLockSchema->new(
            lock_dbh => GPForum::Test::PostStoreLockDbh->new(
                thread_row => $row ? { locked_at => undef, %{$row} } : undef
            ),
            threads => $row ? [ { %{$row} } ] : [],
        ),
    );
    my $stored =
      $store->$method( { %{$command}, thread => { %{ $command->{thread} } } } );
    return 'ok' if $stored->{ok};

    return GPForum::Domain::Thread->status_of( $stored->{error} )
      // "unknown refusal: $stored->{error}";
}

1;
