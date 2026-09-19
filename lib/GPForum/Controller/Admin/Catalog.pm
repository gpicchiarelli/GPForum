package GPForum::Controller::Admin::Catalog;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Admin::Base';

our $VERSION = '0.001';

sub create_role {
    my ($self) = @_;

    my $user_id = $self->authorized_write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->role_write_response(
        $self->gp_admin_workflow->create_role(
            {
                actor_user_id => $user_id,
                description   => $self->param('description'),
                name          => $self->param('name'),
            }
        ),
        $self->admin_access->role_created_status,
    );
}

sub create_permission {
    my ($self) = @_;

    my $user_id = $self->authorized_write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->permission_write_response(
        $self->gp_admin_workflow->create_permission(
            {
                action        => $self->param('action'),
                actor_user_id => $user_id,
                name          => $self->param('name'),
                resource_type => $self->param('resource_type'),
            }
        ),
        $self->admin_access->permission_created_status,
    );
}

sub attach_permission {
    my ($self) = @_;

    my $user_id = $self->authorized_write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->role_permission_write_response(
        $self->gp_admin_workflow->attach_permission(
            {
                actor_user_id => $user_id,
                permission_id => $self->param('permission_id'),
                role_id       => $self->param('role_id'),
            }
        ),
        $self->admin_access->role_permission_attached_status,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::Catalog - Role and permission write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/admin/roles')->to('Admin::Catalog#create_role');

=head1 DESCRIPTION

Creates roles and permissions and attaches permissions to roles through the
admin workflow. Success status names live on L<GPForum::Web::AdminAccess>.

=head1 SUBROUTINES/METHODS

=head2 create_role

Creates a role.

=head2 create_permission

Creates a permission.

=head2 attach_permission

Attaches a permission to a role.

=head1 DIAGNOSTICS

CSRF, auth, and validation failures use the shared admin helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the admin workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Admin::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Role and permission listing remains on the parent admin controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
