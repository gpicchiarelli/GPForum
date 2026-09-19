package GPForum::Service::Attachment::MediaProcessor;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Attachment::Store;

our $VERSION = '0.001';

const my $THUMBNAIL => 'thumbnail';

has storage => undef;
has store   => sub { return GPForum::Service::Attachment::Store->new; };

sub process {
    my ( $self, $attachment_id ) = @_;

    my $attachment = $self->store->find_attachment($attachment_id);
    return { ok => 0, error   => 'not_found' } if !$attachment;
    return { ok => 1, skipped => 'not_available' }
      if ( _column( $attachment, 'state' ) || q{} ) ne 'available';
    return { ok => 1, skipped => 'not_image' }
      if ( _column( $attachment, 'media_type' ) || q{} ) !~ /\A image\//msx;

    my $object_key  = _column( $attachment, 'object_key' );
    my $content     = $self->storage->read_object($object_key);
    my $variant_key = join q{-}, $object_key, $THUMBNAIL;
    $self->storage->write_object( $variant_key, $content )
      if !$self->storage->exists_object($variant_key);

    my $variant = $self->store->add_variant(
        {
            attachment_id => $attachment_id,
            byte_size     => length $content,
            media_type    => _column( $attachment, 'media_type' ),
            object_key    => $variant_key,
            variant_type  => $THUMBNAIL,
        }
    );

    return { ok => 1, variant => $variant };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

1;
