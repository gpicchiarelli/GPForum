# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Domain::Post;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::PostingWorkflow;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::PostingDouble;
use GPForum::Test::RowReader;

our $VERSION = '0.001';

# For every state a thread and a post can be in, the workflow's check before
# the transaction and the store's check under its row locks give the same
# answer: the status of the store's refusal (GPForum::Domain::Post->status_of)
# is the status the workflow answers, and where the workflow lets the write
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
    'deleted by another' => {
        author_user_id   => 'someone',
        deleted_at       => $WHEN,
        moderation_state => 'visible',
    },
    'missing' => undef,
);

my %LIVE_POST = (
    author_user_id   => 'author',
    moderation_state => 'visible',
    post_id          => 'post-1',
    thread_id        => 'thread-1',
    version          => 1,
);
my %POST = (
    'live'         => {%LIVE_POST},
    'deleted'      => { %LIVE_POST, deleted_at       => $WHEN },
    'hidden_at'    => { %LIVE_POST, hidden_at        => $WHEN },
    'hidden state' => { %LIVE_POST, moderation_state => 'hidden' },
    'by another'   => { %LIVE_POST, author_user_id   => 'other' },
    'missing'      => undef,
);

my %OPERATION = (
    edit => {
        workflow => 'edit_post',
        store    => 'edit_post',
        command  => sub {
            return {
                body => {
                    body_id     => 'body-2',
                    body_source => 'Edited',
                    post_id     => 'post-1',
                    source_hash => 'hash-2',
                },
                idempotency_key => 'edit-command',
                post            => {
                    editor_user_id => $WRITER,
                    post_id        => 'post-1',
                    thread_id      => 'thread-1',
                },
                revision => {
                    body_id     => 'body-2',
                    post_id     => 'post-1',
                    revision_id => 'revision-2',
                },
            };
        },
    },
    delete => {
        workflow => 'delete_post',
        store    => 'delete_post',
        command  => sub {
            return {
                idempotency_key => 'delete-command',
                post            => {
                    deleted_by => $WRITER,
                    post_id    => 'post-1',
                    thread_id  => 'thread-1',
                },
            };
        },
    },
    restore => {
        workflow => 'restore_post',
        store    => 'restore_post',
        command  => sub {
            return {
                idempotency_key => 'restore-command',
                post            => {
                    author_user_id => 'author',
                    post_id        => 'post-1',
                    restored_by    => $WRITER,
                    thread_id      => 'thread-1',
                },
            };
        },
    },
);

for my $operation ( sort keys %OPERATION ) {
    for my $thread ( sort keys %THREAD ) {
        for my $post ( sort keys %POST ) {
            agree(
                "$operation, $post post, $thread thread",
                workflow_status(
                    $OPERATION{$operation}{workflow}, $THREAD{$thread},
                    $POST{$post}
                ),
                store_status(
                    $OPERATION{$operation}, $THREAD{$thread}, $POST{$post}
                ),
            );
        }
    }
}

for my $thread ( sort keys %THREAD ) {
    agree(
        "reply, $thread thread",
        workflow_status( 'create_reply', $THREAD{$thread}, undef ),
        reply_store_status( $THREAD{$thread} ),
    );
}

done_testing();

sub agree ( $name, $workflow, $store ) {
    is( $store, $workflow, "$name: the store agrees with the workflow" );

    return;
}

sub workflow_status ( $method, $thread, $post ) {
    my $reader = GPForum::Test::RowReader->new(
        post   => $post,
        thread => $thread,
        writer => $WRITER,
    );
    my $double   = GPForum::Test::PostingDouble->new;
    my $workflow = GPForum::Service::Forum::PostingWorkflow->new(
        category_reader      => $double,
        mention_store        => $double,
        post_composer        => $double,
        post_reader          => $reader,
        post_store           => $double,
        thread_composer      => $double,
        thread_detail_reader => $reader,
        thread_store         => $double,
    );

    return $workflow->$method(
        {
            author_user_id => $WRITER,
            body_source    => 'Body',
            command_id     => 'command-1',
            post_id        => 'post-1',
            thread_id      => 'thread-1',
        }
    )->{status};
}

sub _store ( $thread, @posts ) {
    my $recorder = GPForum::Test::PostingDouble->new;

    return GPForum::Service::Forum::PostStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        recorder   => $recorder,
        schema     => GPForum::Test::PostStoreLockSchema->new(
            lock_dbh => GPForum::Test::PostStoreLockDbh->new(
                thread_row => $thread
                ? { locked_at => undef, %{$thread} }
                : undef
            ),
            posts => [@posts],
        ),
    );
}

sub _status ($stored) {
    return 'ok' if $stored->{ok};

    return GPForum::Domain::Post->status_of( $stored->{error} )
      // "unknown refusal: $stored->{error}";
}

sub store_status ( $operation, $thread, $post ) {
    my $store  = _store( $thread, $post ? { %{$post} } : () );
    my $method = $operation->{store};

    return _status( $store->$method( $operation->{command}->() ) );
}

sub reply_store_status ($thread) {
    my $store = _store($thread);

    return _status(
        $store->create_post(
            {
                body => {
                    body_id     => 'body-1',
                    body_source => 'Reply',
                    post_id     => 'post-9',
                    source_hash => 'hash-1',
                },
                idempotency_key => 'reply-command',
                post            => {
                    author_user_id => $WRITER,
                    position       => 1,
                    post_id        => 'post-9',
                    thread_id      => 'thread-1',
                },
                revision => {
                    body_id     => 'body-1',
                    post_id     => 'post-9',
                    revision_id => 'revision-1',
                },
            }
        )
    );
}

1;
