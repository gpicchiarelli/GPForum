package GPForum::Controller::Attachments;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Attachments::Base';

our $VERSION = '0.001';

sub download {
    my ($self) = @_;

    return $self->download_response(
        $self->gp_attachment_workflow->download(
            {
                attachment_id  => $self->param('attachment_id'),
                viewer_user_id => $self->current_user_id,
            }
        ),
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Attachments - Attachment download HTTP.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/attachments/:attachment_id/download')
      ->to('Attachments#download');

=head1 DESCRIPTION

Delivers attachment bytes through the attachment workflow. Uploads live on
L<GPForum::Controller::Attachments::Upload>.

=head1 SUBROUTINES/METHODS

=head2 download

Streams an authorized attachment or maps missing and forbidden objects.

=head1 DIAGNOSTICS

Not-found, forbidden, and store failures use the shared attachment helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the attachment workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Attachments::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Binary storage and visibility checks remain in the delivery service.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
