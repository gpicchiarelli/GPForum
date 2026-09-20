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
    my $rejected   = _rejected_attachment($attachment);
    if ($rejected) {
        return $rejected;
    }

    my $existing = $self->_existing_thumbnail($attachment_id);
    if ($existing) {
        return $self->_skipped_variant($existing);
    }

    return $self->_write_thumbnail($attachment);
}

sub _rejected_attachment {
    my ($attachment) = @_;

    if ( !$attachment ) {
        return { error => 'not_found', ok => 0 };
    }

    return _skipped_attachment($attachment);
}

sub _skipped_attachment {
    my ($attachment) = @_;

    if ( _not_available($attachment) ) {
        return { ok => 1, skipped => 'not_available' };
    }
    if ( _not_image($attachment) ) {
        return { ok => 1, skipped => 'not_image' };
    }

    return;
}

sub _not_available {
    my ($attachment) = @_;

    if ( _text( _column( $attachment, 'state' ) ) ne 'available' ) {
        return 1;
    }

    return 0;
}

sub _not_image {
    my ($attachment) = @_;

    if ( _text( _column( $attachment, 'media_type' ) ) !~ /\A image\//msx ) {
        return 1;
    }

    return 0;
}

sub _text {
    my ($value) = @_;

    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _existing_thumbnail {
    my ( $self, $attachment_id ) = @_;

    return $self->store->find_variant(
        {
            attachment_id => $attachment_id,
            variant_type  => $THUMBNAIL,
        }
    );
}

sub _skipped_variant {
    my ( $self, $existing ) = @_;

    return {
        ok      => 1,
        skipped => 1,
        variant => {
            %{ $self->store->record->row_hash($existing) }, idempotent => 1,
        },
    };
}

sub _write_thumbnail {
    my ( $self, $attachment ) = @_;

    my $object_key  = _column( $attachment, 'object_key' );
    my $content     = $self->storage->read_object($object_key);
    my $variant_key = join q{-}, $object_key, $THUMBNAIL;
    $self->_store_thumbnail_object( $variant_key, $content );

    return {
        ok      => 1,
        variant => $self->store->add_variant(
            {
                attachment_id => _column( $attachment, 'attachment_id' ),
                byte_size     => length $content,
                media_type    => _column( $attachment, 'media_type' ),
                object_key    => $variant_key,
                variant_type  => $THUMBNAIL,
            }
        ),
    };
}

sub _store_thumbnail_object {
    my ( $self, $variant_key, $content ) = @_;

    if ( $self->storage->exists_object($variant_key) ) {
        return;
    }

    $self->storage->write_object( $variant_key, $content );

    return;
}

sub _column {
    my ( $row, $column ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$column};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($column);
    }

    return;
}

1;
