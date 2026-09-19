package GPForum::Controller::Admin::Bindings;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Admin::Base';

our $VERSION = '0.001';

sub bind_role {
    my ($self) = @_;

    my $actor_user_id = $self->authorized_write_user_id;
    if ( !$actor_user_id ) {
        return;
    }

    return $self->binding_write_response(
        $self->gp_admin_workflow->bind_role(
            {
                actor_user_id => $actor_user_id,
                resource_id   => $self->param('resource_id'),
                resource_type => $self->param('resource_type'),
                role_id       => $self->param('role_id'),
                space_id      => $self->param('space_id'),
                user_id       => $self->param('user_id'),
            }
        ),
        $self->admin_access->role_bound_status,
    );
}

sub revoke_binding {
    my ($self) = @_;

    my $actor_user_id = $self->authorized_write_user_id;
    if ( !$actor_user_id ) {
        return;
    }

    return $self->binding_write_response(
        $self->gp_admin_workflow->revoke_binding(
            {
                actor_user_id => $actor_user_id,
                binding_id    => $self->param('binding_id'),
            }
        ),
        $self->admin_access->role_binding_revoked_status,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::Bindings - Role binding write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/admin/users/:user_id/roles')
      ->to('Admin::Bindings#bind_role');

=head1 DESCRIPTION

Binds and revokes user role bindings through the admin workflow. Success
status names live on L<GPForum::Web::AdminAccess>.

=head1 SUBROUTINES/METHODS

=head2 bind_role

Binds a role to a user.

=head2 revoke_binding

Revokes an existing role binding.

=head1 DIAGNOSTICS

CSRF, auth, validation, and missing-binding failures use the shared admin
helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the admin workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Admin::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

User role listing remains on the parent admin controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
