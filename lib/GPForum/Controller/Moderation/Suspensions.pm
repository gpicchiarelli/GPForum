package GPForum::Controller::Moderation::Suspensions;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Moderation::Base';

our $VERSION = '0.001';

sub suspend_user {
    my ($self) = @_;

    my $access        = $self->moderation_access;
    my $actor_user_id = $self->authorized_write_user_id( $access->user_resource,
        $access->suspend_action );
    if ( !$actor_user_id ) {
        return;
    }

    return $self->suspension_write_response(
        $self->gp_moderation_workflow->suspend_user(
            {
                actor_user_id => $actor_user_id,
                command_id    => $self->command_id_param,
                reason        => $self->reason_param,
                user_id       => $self->param('user_id'),
                valid_to      => $self->optional_param('valid_to'),
            }
        ),
        $access->user_suspended_status,
    );
}

sub revoke_suspension {
    my ($self) = @_;

    my $access        = $self->moderation_access;
    my $actor_user_id = $self->authorized_write_user_id( $access->user_resource,
        $access->suspend_action );
    if ( !$actor_user_id ) {
        return;
    }

    return $self->suspension_write_response(
        $self->gp_moderation_workflow->revoke_suspension(
            {
                actor_user_id => $actor_user_id,
                command_id    => $self->command_id_param,
                reason        => $self->reason_param,
                suspension_id => $self->param('suspension_id'),
            }
        ),
        $access->suspension_revoked_status,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Moderation::Suspensions - Suspension write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/moderation/users/:user_id/suspend')
      ->to('Moderation::Suspensions#suspend_user');

=head1 DESCRIPTION

Creates and revokes user suspensions through the moderation workflow.
Permission names and write-success statuses live on
L<GPForum::Web::ModerationAccess>.

=head1 SUBROUTINES/METHODS

=head2 suspend_user

Suspends a user.

=head2 revoke_suspension

Revokes an active suspension.

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

Suspension listing remains on the parent moderation controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
