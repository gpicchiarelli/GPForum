package GPForum::Controller::Attachments::Upload;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Attachments::Base';

our $VERSION = '0.001';

sub upload_post {
    my ($self) = @_;

    my $user_id = $self->write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->upload_write_response(
        $self->gp_attachment_workflow->upload_for_post(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                post_id       => $self->param('post_id'),
                upload        => $self->req->upload('attachment'),
            }
        ),
    );
}

sub delete_post {
    my ($self) = @_;

    my $user_id = $self->write_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->delete_write_response(
        $self->gp_attachment_workflow->delete_for_post(
            {
                actor_user_id => $user_id,
                attachment_id => $self->param('attachment_id'),
                command_id    => $self->command_id_param,
                post_id       => $self->param('post_id'),
            }
        ),
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Attachments::Upload - Post attachment writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/p/:post_id/attachments')
      ->to('Attachments::Upload#upload_post');

=head1 DESCRIPTION

Accepts authenticated post attachment uploads and deletes through the
attachment workflow.

=head1 SUBROUTINES/METHODS

=head2 upload_post

Uploads and links an attachment to a visible post owned by the actor.
Requires C<command_id>.

=head2 delete_post

Soft-deletes an attachment linked to a visible post owned by the actor.
Requires C<command_id>.

=head1 DIAGNOSTICS

CSRF, auth, rate-limit, and validation failures use the shared attachment
helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the attachment workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Attachments::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Attachment downloads remain on the parent attachments controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
