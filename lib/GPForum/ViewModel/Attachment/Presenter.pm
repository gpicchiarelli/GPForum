package GPForum::ViewModel::Attachment::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub attachment {
    my ( $self, $attachment, %input ) = @_;

    return {
        attachment_id     => $self->column( $attachment, 'attachment_id' ),
        byte_size         => $self->column( $attachment, 'byte_size' ),
        download_url      => $input{download_url},
        media_type        => $self->column( $attachment, 'media_type' ),
        original_filename => $self->column( $attachment, 'original_filename' ),
        scan_status       => $self->column( $attachment, 'scan_status' ),
        state             => $self->column( $attachment, 'state' ),
    };
}

1;
