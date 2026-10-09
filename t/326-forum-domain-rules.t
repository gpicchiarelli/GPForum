# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';

use GPForum::Domain::Post;
use GPForum::Domain::Thread;

our $VERSION = '0.001';

my $THREAD = 'GPForum::Domain::Thread';
my $POST   = 'GPForum::Domain::Post';
my $WHEN   = '2026-01-01T00:00:00Z';

sub thread (%column) {
    return {
        author_user_id   => 'author',
        moderation_state => 'visible',
        %column,
    };
}

sub post (%column) {
    return {
        author_user_id   => 'author',
        moderation_state => 'visible',
        %column,
    };
}

# shown_to_writer: what the thread page shows the writer.
my @SHOWN = (
    [ 'missing thread', undef,                                  'author', 0 ],
    [ 'visible',        thread(),                               'author', 1 ],
    [ 'locked state',   thread( moderation_state => 'locked' ), 'author', 1 ],
    [ 'hidden state',   thread( moderation_state => 'hidden' ), 'author', 0 ],
    [ 'no state',       thread( moderation_state => undef ),    'author', 0 ],
    [ 'deleted, to its author', thread( deleted_at => $WHEN ),  'author', 1 ],
    [ 'deleted, to another',    thread( deleted_at => $WHEN ),  'other',  0 ],
    [
        'deleted, to nobody',
        thread( author_user_id => undef, deleted_at => $WHEN ),
        undef, 0
    ],
);
for my $case (@SHOWN) {
    my ( $name, $thread, $writer, $shown ) = @{$case};
    is( $THREAD->shown_to_writer( $thread, $writer ) ? 1 : 0,
        $shown, "shown_to_writer: $name" );
}
my $row = thread();
is( $THREAD->shown_to_writer( $row, 'author' ),
    $row, 'shown_to_writer returns the thread itself' );

# reply_refusal: a thread the writer can read, or undef.
my @REPLY = (
    [ 'missing', undef,                        'thread not found' ],
    [ 'open',    thread(),                     undef ],
    [ 'locked',  thread( locked_at => $WHEN ), 'thread is locked' ],
);
for my $case (@REPLY) {
    my ( $name, $thread, $error ) = @{$case};
    is( $THREAD->reply_refusal($thread), $error, "reply_refusal: $name" );
}

# edit_refusal and restore_refusal, in their order: not found, author,
# hidden, locked.
my @THREAD_EDIT = (
    [ 'missing', undef,    'author', 'thread not found', 'thread not found' ],
    [ 'live',    thread(), 'author', undef,              'thread not found' ],
    [
        'deleted', thread( deleted_at => $WHEN ),
        'author',  'thread not found',
        undef
    ],
    [
        'another author',
        thread(),
        'other',
        'not the thread author',
        'thread not found'
    ],
    [
        'hidden', thread( moderation_state => 'hidden' ),
        'author',
        'thread is hidden',
        'thread not found'
    ],
    [
        'locked',
        thread( locked_at => $WHEN ),
        'author',
        'thread is locked',
        'thread not found'
    ],
    [
        'another author of a hidden locked thread',
        thread( locked_at => $WHEN, moderation_state => 'hidden' ),
        'other',
        'not the thread author',
        'thread not found'
    ],
    [
        'hidden and locked',
        thread( locked_at => $WHEN, moderation_state => 'hidden' ),
        'author',
        'thread is hidden',
        'thread not found'
    ],
    [
        'deleted and locked',
        thread( deleted_at => $WHEN, locked_at => $WHEN ),
        'author',
        'thread not found',
        'thread is locked'
    ],
);
for my $case (@THREAD_EDIT) {
    my ( $name, $thread, $author, $edit, $restore ) = @{$case};
    is( $THREAD->edit_refusal( $thread, $author ),
        $edit, "thread edit_refusal: $name" );
    is( $THREAD->restore_refusal( $thread, $author ),
        $restore, "thread restore_refusal: $name" );
}

# A post's edit (and delete) and restore: post not found, thread not found,
# author, hidden, locked.
my $open      = thread();
my $locked    = thread( locked_at => $WHEN );
my @POST_EDIT = (
    [
        'missing post',   undef,
        $open,            'author',
        'post not found', 'post not found'
    ],
    [ 'live post', post(), $open, 'author', undef, 'post not found' ],
    [
        'deleted post',   post( deleted_at => $WHEN ),
        $open,            'author',
        'post not found', undef
    ],
    [
        'unreadable thread', post(),
        undef,               'author',
        'thread not found',  'post not found'
    ],
    [
        'deleted post in an unreadable thread',
        post( deleted_at => $WHEN ),
        undef, 'author',
        'post not found',
        'thread not found'
    ],
    [
        'another author',      post(),
        $open,                 'other',
        'not the post author', 'post not found'
    ],
    [
        'hidden_at',      post( hidden_at => $WHEN ),
        $open,            'author',
        'post is hidden', 'post not found'
    ],
    [
        'hidden state', post( moderation_state => 'hidden' ),
        $open,          'author',
        'post is hidden',
        'post not found'
    ],
    [
        'locked thread',    post(),
        $locked,            'author',
        'thread is locked', 'post not found'
    ],
    [
        'hidden post in a locked thread',
        post( hidden_at => $WHEN ),
        $locked, 'author',
        'post is hidden',
        'post not found'
    ],
    [
        'deleted post in a locked thread',
        post( deleted_at => $WHEN ),
        $locked, 'author',
        'post not found',
        'thread is locked'
    ],
    [
        'another author in a locked thread',
        post( deleted_at => $WHEN ),
        $locked, 'other',
        'post not found',
        'not the post author'
    ],
    [
        'another author of a hidden post',
        post( hidden_at => $WHEN ),
        $open, 'other',
        'not the post author',
        'post not found'
    ],
    [
        'another author of a deleted hidden post',
        post( deleted_at => $WHEN, moderation_state => 'hidden' ),
        $open,
        'other',
        'post not found',
        'not the post author'
    ],
    [
        'another author in an unreadable thread',
        post(), undef, 'other',
        'thread not found',
        'post not found'
    ],
    [
        'another author of a deleted post in an unreadable thread',
        post( deleted_at => $WHEN ),
        undef,
        'other',
        'post not found',
        'thread not found'
    ],
);
for my $case (@POST_EDIT) {
    my ( $name, $post, $thread, $author, $edit, $restore ) = @{$case};
    is( $POST->edit_refusal( $post, $thread, $author ),
        $edit, "post edit_refusal: $name" );
    is( $POST->restore_refusal( $post, $thread, $author ),
        $restore, "post restore_refusal: $name" );
}

# Every refusal word and the status it means; anything else has none.
my %STATUS = (
    'not the post author'   => 'forbidden',
    'not the thread author' => 'forbidden',
    'post is hidden'        => 'forbidden',
    'post not found'        => 'not_found',
    'thread is hidden'      => 'forbidden',
    'thread is locked'      => 'forbidden',
    'thread not found'      => 'not_found',
);
for my $error ( sort keys %STATUS ) {
    is( $POST->status_of($error), $STATUS{$error}, "status_of: $error" );
}
is( $THREAD->status_of('post not found'),
    undef, 'a thread has no status for a post refusal' );
is( $POST->status_of('post store failed'), undef, 'status_of: a failure' );
is( $POST->status_of(undef),               undef, 'status_of: undef' );
is( $POST->status_of(q{}),                 undef, 'status_of: empty' );

is( $THREAD->by( { author_user_id => undef }, q{} ),
    1, 'by: an absent author and an empty user are the same nobody' );

done_testing();

1;
