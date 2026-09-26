# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Moderation::Actions;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Moderation::Base', -signatures;

our $VERSION = '0.001';

sub hide_post ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->post_resource,
        $access->moderate_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->hide_post(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                post_id       => $self->param('post_id'),
                reason        => $self->reason_param,
            }
        ),
        $access->post_hidden_status,
    );
}

sub restore_post ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->post_resource,
        $access->moderate_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->restore_post(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                post_id       => $self->param('post_id'),
                reason        => $self->reason_param,
            }
        ),
        $access->post_restored_status,
    );
}

sub lock_thread ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->thread_resource,
        $access->moderate_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->lock_thread(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                thread_id     => $self->param('thread_id'),
                reason        => $self->reason_param,
            }
        ),
        $access->thread_locked_status,
    );
}

sub unlock_thread ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->thread_resource,
        $access->moderate_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->unlock_thread(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                thread_id     => $self->param('thread_id'),
                reason        => $self->reason_param,
            }
        ),
        $access->thread_unlocked_status,
    );
}

sub hide_thread ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->thread_resource,
        $access->moderate_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->hide_thread(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                thread_id     => $self->param('thread_id'),
                reason        => $self->reason_param,
            }
        ),
        $access->thread_hidden_status,
    );
}

sub restore_thread ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->thread_resource,
        $access->moderate_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->restore_thread(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                thread_id     => $self->param('thread_id'),
                reason        => $self->reason_param,
            }
        ),
        $access->thread_restored_status,
    );
}

sub reverse_action ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->moderation_resource,
        $access->reverse_action );
    if ( !$user_id ) {
        return;
    }

    return $self->moderation_write_response(
        $self->gp_moderation_workflow->reverse_action(
            {
                action_id     => $self->param('action_id'),
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                reason        => $self->reason_param,
            }
        ),
        $access->action_reversed_status,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Moderation::Actions - Content moderation write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/moderation/posts/:post_id/hide')
      ->to('Moderation::Actions#hide_post');

=head1 DESCRIPTION

Hides and restores posts, locks and unlocks threads, and reverses prior
moderation actions through the moderation workflow. Permission names and
write-success statuses live on L<GPForum::Web::ModerationAccess>.

=head1 SUBROUTINES/METHODS

=head2 hide_post

Hides a post.

=head2 restore_post

Restores a hidden post.

=head2 lock_thread

Locks a thread.

=head2 unlock_thread

Unlocks a thread.

=head2 hide_thread

Hides a thread.

=head2 restore_thread

Restores a hidden thread.

=head2 reverse_action

Records reversal of a prior moderation action.

=head1 DIAGNOSTICS

CSRF, auth, validation, and missing-target failures use the shared moderation
helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the moderation workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Moderation::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Action history listing remains on the parent moderation controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
