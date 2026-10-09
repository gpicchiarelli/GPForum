# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowPostStore;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A post store for PostingWorkflow that counts its calls. Built with
# fail => 1 it dies; built with refuse => $error it answers that refusal, as
# PostStore does when its locks find the post or its thread locked, hidden
# or gone since the workflow looked: a refusal, not an exception.
has calls => 0;
has 'fail';
has 'refuse';

sub create_post ( $self, $command ) {
    return $self->_written( $command, $command->{post}{author_user_id} );
}

sub edit_post ( $self, $command ) {
    return $self->_written( $command, $command->{post}{editor_user_id} );
}

sub delete_post ( $self, $command ) {
    return $self->_written( $command, $command->{post}{deleted_by} );
}

sub restore_post ( $self, $command ) {
    return $self->_written( $command, $command->{post}{restored_by} );
}

sub _written ( $self, $command, $author_user_id ) {
    $self->calls( $self->calls + 1 );
    if ( $self->fail ) {
        die "post store failed\n";
    }
    return { ok => 0, error => $self->refuse } if $self->refuse;

    return {
        ok   => 1,
        post => {
            author_user_id => $author_user_id,
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
        },
    };
}

1;
