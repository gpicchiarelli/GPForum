package GPForum::Controller::Privacy::Requests;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Privacy::Base';

our $VERSION = '0.001';

sub request_export {
    my ($self) = @_;

    my $user_id = $self->write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->export_write_response(
        $self->gp_privacy_workflow->request_export(
            {
                user_id => $user_id,
            }
        ),
    );
}

sub request_deletion {
    my ($self) = @_;

    my $user_id = $self->write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->deletion_write_response(
        $self->gp_privacy_workflow->request_deletion(
            {
                reason  => $self->param('reason'),
                user_id => $user_id,
            }
        ),
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Privacy::Requests - Member export and deletion writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/privacy/export')->to('Privacy::Requests#request_export');

=head1 DESCRIPTION

Accepts authenticated member export and deletion requests through the privacy
workflow.

=head1 SUBROUTINES/METHODS

=head2 request_export

Requests and completes a user data export.

=head2 request_deletion

Creates an anonymize deletion request.

=head1 DIAGNOSTICS

CSRF, auth, and validation failures use the shared privacy helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the privacy workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Privacy::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The member dashboard remains on the parent privacy controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
