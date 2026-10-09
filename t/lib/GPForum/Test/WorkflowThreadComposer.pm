# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowThreadComposer;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A thread composer for PostingWorkflow that keeps the last input and answers
# the result it was built with, or a prepared command made from the input.
has 'last_input';
has 'result';

sub prepare ( $self, $input ) {
    $self->last_input($input);
    return $self->result if $self->result;

    return {
        ok      => 1,
        command => {
            body => { body_source => $input->{body_source} },
            post => {
                author_user_id => $input->{author_user_id},
                post_id        => 'post-1',
                thread_id      => 'thread-1',
            },
            thread => { thread_id => 'thread-1' },
        },
    };
}

sub prepare_title ( $self, $input ) {
    $self->last_input($input);
    if ( $self->result ) {
        return $self->result;
    }

    return {
        ok      => 1,
        command => {
            thread => {
                editor_user_id => $input->{editor_user_id},
                slug           => 'edited-welcome',
                thread_id      => $input->{thread_id},
                title          => $input->{title},
            },
        },
    };
}

sub prepare_move ( $self, $input ) {
    $self->last_input($input);
    if ( $self->result ) {
        return $self->result;
    }

    return {
        ok      => 1,
        command => {
            thread => {
                category_id    => $input->{category_id},
                editor_user_id => $input->{editor_user_id},
                thread_id      => $input->{thread_id},
            },
        },
    };
}

1;
