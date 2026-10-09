# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::MediaProcessor;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;

our $VERSION = '0.001';

const my $THUMBNAIL => 'thumbnail';

__PACKAGE__->requires(qw(storage store));

sub process ( $self, $attachment_id ) {
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

sub _rejected_attachment ($attachment) {
    if ( !$attachment ) {
        return { error => 'not_found', ok => 0 };
    }

    return _skipped_attachment($attachment);
}

sub _skipped_attachment ($attachment) {
    if ( _not_available($attachment) ) {
        return { ok => 1, skipped => 'not_available' };
    }
    if ( _not_image($attachment) ) {
        return { ok => 1, skipped => 'not_image' };
    }

    return undef;
}

sub _not_available ($attachment) {
    if ( _text( _column( $attachment, 'state' ) ) ne 'available' ) {
        return 1;
    }

    return 0;
}

sub _not_image ($attachment) {
    if ( _text( _column( $attachment, 'media_type' ) ) !~ /\A image\//msx ) {
        return 1;
    }

    return 0;
}

sub _text ($value) {
    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _existing_thumbnail ( $self, $attachment_id ) {
    return $self->store->find_variant(
        {
            attachment_id => $attachment_id,
            variant_type  => $THUMBNAIL,
        }
    );
}

# The variant comes from the database: Record::row_hash read none of its
# columns, so a redelivered event answered with a thumbnail that had no type,
# no key and no id.
sub _skipped_variant ( $self, $existing ) {
    return {
        ok      => 1,
        skipped => 1,
        variant => {
            %{ $self->store->lifecycle->row_columns($existing) },
            idempotent => 1,
        },
    };
}

sub _write_thumbnail ( $self, $attachment ) {
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

sub _store_thumbnail_object ( $self, $variant_key, $content ) {
    if ( $self->storage->exists_object($variant_key) ) {
        return;
    }

    $self->storage->write_object( $variant_key, $content );

    return;
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::MediaProcessor - Record the thumbnail variant of an uploaded image.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $processor = GPForum::Service::Attachment::MediaProcessor->new(
        storage => $attachment_storage,
        store   => $attachment_store,
    );
    my $result = $processor->process($attachment_id);
    # { ok => 1, variant => {...} }, { ok => 1, skipped => ... }
    # or { ok => 0, error => 'not_found' }

=head1 DESCRIPTION

Run by the media processing worker
(L<GPForum::Worker::Handler::MediaProcessing>) for an attachment event. For
an available attachment whose media type starts with C<image/>, it writes a
C<thumbnail> object under the key C<< <object_key>-thumbnail >> and records
it as an attachment variant through L<GPForum::Service::Attachment::Store>.

The work is idempotent: an attachment that already has a thumbnail variant
is reported as skipped, and an object already present under the variant key
is not written again, so a redelivered event does no harm. The variant's
bytes are the original object's bytes, read from storage and written under
the new key; no image is decoded or resized here.

=head1 SUBROUTINES/METHODS

=head2 new

Constructor (L<GPForum::Base>). C<storage> (an object with C<read_object>,
C<exists_object> and C<write_object>, such as
L<GPForum::Service::Attachment::FilesystemStorage>) and C<store>, the
L<GPForum::Service::Attachment::Store> that records the variant, are required:
a missing one throws L<GPForum::X::Argument>.

=head2 process

Takes an attachment id. Returns a hash reference:

=over 4

=item * C<< { ok => 0, error => 'not_found' } >> when there is no such
attachment;

=item * C<< { ok => 1, skipped => 'not_available' } >> when its state is
not C<available>;

=item * C<< { ok => 1, skipped => 'not_image' } >> when its media type does
not start with C<image/>;

=item * C<< { ok => 1, skipped => 1, variant => {...} } >> when a thumbnail
variant already exists; the variant's columns come with
C<< idempotent => 1 >>;

=item * C<< { ok => 1, variant => {...} } >> after writing the object and
adding the variant (same media type, C<byte_size> the length of the
original's bytes, also when the object was already there and not written).

=back

=head1 DIAGNOSTICS

Refusals are returned, not thrown. Errors from the storage backend or the
store propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Attachment::Store>, L<GPForum::Infrastructure::Row>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
