package GPForum::ViewModel::Attachment::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub attachment {
    my ( $self, $attachment, %input ) = @_;

    my $attachment_id = $self->column( $attachment, 'attachment_id' );

    return {
        attachment_id     => $attachment_id,
        byte_size         => $self->column( $attachment, 'byte_size' ),
        download_url      => $input{download_url},
        media_type        => $self->column( $attachment, 'media_type' ),
        original_filename => $self->column( $attachment, 'original_filename' ),
        scan_status       => $self->column( $attachment, 'scan_status' ),
        state             => $self->column( $attachment, 'state' ),
        ui                => {
            heading_id =>
              $self->stable_id( 'attachment', $attachment_id, 'heading' ),
        },
    };
}

sub upload_response {
    my ( $self, $result, %input ) = @_;

    return {
        attachment => $self->attachment(
            $result->{attachment}, download_url => $input{download_url},
        ),
        link   => $result->{link},
        status => 'uploaded',
    };
}

sub delete_response {
    my ( $self, $result ) = @_;

    return {
        attachment => $self->attachment( $result->{attachment} ),
        status     => 'deleted',
    };
}

1;
