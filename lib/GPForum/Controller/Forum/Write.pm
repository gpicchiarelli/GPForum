package GPForum::Controller::Forum::Write;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Forum::Base';

our $VERSION = '0.001';

sub create_thread {
    my ($self) = @_;

    my $user_id = $self->write_user_id('thread.create');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->create_thread(
        {
            category_id    => $self->param('category_id'),
            author_user_id => $user_id,
            title          => $self->param('title'),
            body_source    => $self->param('body_source'),
            command_id     => $self->command_id_param,
            visibility     => $self->param('visibility'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->thread_write_failure($result);
    }

    return $self->created_thread_response( $result->{stored} );
}

sub edit_thread {
    my ($self) = @_;

    my $user_id = $self->write_user_id('thread.edit');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->edit_thread(
        {
            author_user_id => $user_id,
            command_id     => $self->command_id_param,
            thread_id      => $self->param('thread_id'),
            title          => $self->param('title'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->updated_thread_response( $result->{stored} );
}

sub move_thread {
    my ($self) = @_;

    my $user_id = $self->write_user_id('thread.move');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->move_thread(
        {
            author_user_id => $user_id,
            category_id    => $self->param('category_id'),
            command_id     => $self->command_id_param,
            thread_id      => $self->param('thread_id'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->moved_thread_response( $result->{stored} );
}

sub delete_thread {
    my ($self) = @_;

    my $user_id = $self->write_user_id('thread.delete');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->delete_thread(
        {
            author_user_id => $user_id,
            command_id     => $self->command_id_param,
            thread_id      => $self->param('thread_id'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->deleted_thread_response( $result->{stored} );
}

sub restore_thread {
    my ($self) = @_;

    my $user_id = $self->write_user_id('thread.restore');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->restore_thread(
        {
            author_user_id => $user_id,
            command_id     => $self->command_id_param,
            thread_id      => $self->param('thread_id'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->restored_thread_response( $result->{stored} );
}

sub create_reply {
    my ($self) = @_;

    my $user_id = $self->write_user_id('reply.create');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->create_reply(
        {
            thread_id      => $self->param('thread_id'),
            author_user_id => $user_id,
            body_source    => $self->param('body_source'),
            command_id     => $self->command_id_param,
            visibility     => $self->param('visibility'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->created_post_response( $result->{stored} );
}

sub edit_post {
    my ($self) = @_;

    my $user_id = $self->write_user_id('post.edit');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->edit_post(
        {
            author_user_id => $user_id,
            body_source    => $self->param('body_source'),
            command_id     => $self->command_id_param,
            post_id        => $self->param('post_id'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->updated_post_response( $result->{stored} );
}

sub delete_post {
    my ($self) = @_;

    my $user_id = $self->write_user_id('post.delete');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->delete_post(
        {
            author_user_id => $user_id,
            command_id     => $self->command_id_param,
            post_id        => $self->param('post_id'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->deleted_post_response( $result->{stored} );
}

sub restore_post {
    my ($self) = @_;

    my $user_id = $self->write_user_id('post.restore');
    if ( !$user_id ) {
        return;
    }

    my $result = $self->gp_posting_workflow->restore_post(
        {
            author_user_id => $user_id,
            command_id     => $self->command_id_param,
            post_id        => $self->param('post_id'),
        }
    );

    if ( !$result->{ok} ) {
        return $self->reply_write_failure($result);
    }

    return $self->restored_post_response( $result->{stored} );
}

sub mark_thread_read {
    my ($self) = @_;

    my $user_id = $self->write_user_id('thread.read');
    if ( !$user_id ) {
        return;
    }

    return $self->_mark_visible_thread_read($user_id);
}

sub _mark_visible_thread_read {
    my ( $self, $user_id ) = @_;

    my $thread_id = $self->param('thread_id');
    if ( !$self->gp_thread_detail_reader->find_thread($thread_id) ) {
        return $self->_not_found('thread not found');
    }

    my $position = $self->param('last_read_position');
    if ( !$self->is_non_negative_integer($position) ) {
        return $self->_bad_request( $self->forum_access->read_position_errors );
    }

    return $self->_store_thread_read_marker( $user_id, $thread_id, $position );
}

sub _store_thread_read_marker {
    my ( $self, $user_id, $thread_id, $position ) = @_;

    my $marked = $self->gp_thread_read_workflow->mark_thread_read(
        {
            command_id         => $self->command_id_param,
            last_read_position => $position,
            thread_id          => $thread_id,
            user_id            => $user_id,
        }
    );
    if ( !$marked->{ok} ) {
        return $self->_read_marker_failure($marked);
    }

    return $self->read_marker_response($marked);
}

sub _read_marker_failure {
    my ( $self, $marked ) = @_;

    return $self->_write_failure(
        $marked,
        {
            conflict => sub {
                return $self->_conflict( $marked->{error} );
            },
            invalid => sub {
                return $self->_bad_request( $marked->{errors} );
            },
        }
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Forum::Write - Forum write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/threads')->to('Forum::Write#create_thread');

=head1 DESCRIPTION

Handles thread creation, replies, author post edits, author post deletes,
author post restores, author thread edits, author thread moves, author
thread deletes, and read-marker updates.

=head1 SUBROUTINES/METHODS

=head2 create_thread

Creates a thread through the posting workflow.

=head2 edit_thread

Updates an author-owned thread title through the posting workflow.

=head2 move_thread

Moves an author-owned thread to another category through the posting workflow.

=head2 delete_thread

Soft-deletes an author-owned thread through the posting workflow.

=head2 restore_thread

Restores an author-owned soft-deleted thread through the posting workflow.

=head2 create_reply

Creates a reply through the posting workflow.

=head2 edit_post

Updates an author-owned post through the posting workflow.

=head2 delete_post

Soft-deletes an author-owned post through the posting workflow.

=head2 restore_post

Restores an author-owned soft-deleted post through the posting workflow.

=head2 mark_thread_read

Stores the viewer's last-read position on a visible thread through the
read workflow. HTTP C<command_id> is required.

=head1 DIAGNOSTICS

CSRF, auth, rate-limit, and validation failures use the shared forum helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses posting and read-workflow helpers configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Forum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Participation is blocked for suspended users on thread, reply, post-edit,
post-delete, thread-edit, thread-move, and thread-delete writes.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
