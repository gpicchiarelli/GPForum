# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowThreadStore;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A thread store for PostingWorkflow that counts its calls. Built with
# fail => 1 it dies; built with refuse => $error every write but
# create_thread answers that refusal, as ThreadStore does when the thread
# lock finds the thread locked, hidden or gone since the workflow looked.
has calls => 0;
has 'fail';
has 'refuse';

sub create_thread ( $self, @ ) {
    $self->_count;

    return {
        ok     => 1,
        post   => { author_user_id => 'user-1', post_id => 'post-1' },
        thread => { thread_id      => 'thread-1' },
    };
}

sub edit_thread ( $self, $command ) {
    $self->_count;
    return { ok => 0, error => $self->refuse } if $self->refuse;

    return {
        ok     => 1,
        thread => {
            slug      => $command->{thread}{slug},
            thread_id => $command->{thread}{thread_id},
            title     => $command->{thread}{title},
        },
    };
}

sub delete_thread ( $self, $command ) {
    return $self->_placed($command);
}

sub restore_thread ( $self, $command ) {
    return $self->_placed($command);
}

sub move_thread ( $self, $command ) {
    return $self->_placed($command);
}

sub _count ($self) {
    $self->calls( $self->calls + 1 );
    if ( $self->fail ) {
        die "thread store failed\n";
    }

    return undef;
}

sub _placed ( $self, $command ) {
    $self->_count;
    return { ok => 0, error => $self->refuse } if $self->refuse;

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id},
            thread_id   => $command->{thread}{thread_id},
        },
    };
}

1;
