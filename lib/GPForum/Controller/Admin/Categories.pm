package GPForum::Controller::Admin::Categories;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Admin::Base';

our $VERSION = '0.001';

sub create_category {
    my ($self) = @_;

    my $user_id = $self->authorized_write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->category_write_response(
        $self->gp_admin_workflow->create_category(
            $self->_category_params($user_id)
        ),
        $self->admin_access->category_created_status,
    );
}

sub update_category {
    my ($self) = @_;

    my $user_id = $self->authorized_write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->category_write_response(
        $self->gp_admin_workflow->update_category(
            {
                %{ $self->_category_params($user_id) },
                category_id => $self->param('category_id'),
            }
        ),
        $self->admin_access->category_updated_status,
    );
}

sub _category_params {
    my ( $self, $user_id ) = @_;

    return {
        actor_user_id => $user_id,
        command_id    => $self->command_id_param,
        description   => $self->param('description'),
        position      => $self->param('position'),
        slug          => $self->param('slug'),
        space_id      => $self->param('space_id'),
        title         => $self->param('title'),
        visibility    => $self->param('visibility'),
    };
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::Categories - Category write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/admin/categories')
      ->to('Admin::Categories#create_category');

=head1 DESCRIPTION

Creates and updates forum categories through the admin workflow. Success
status names live on L<GPForum::Web::AdminAccess>. CSRF stays on
L<GPForum::Controller::Admin::Base/authorized_write_user_id>.

=head1 SUBROUTINES/METHODS

=head2 create_category

Creates a category.

=head2 update_category

Updates an existing category.

=head1 DIAGNOSTICS

CSRF, auth, and validation failures use the shared admin helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the admin workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Admin::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Category listing remains on the parent admin controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
