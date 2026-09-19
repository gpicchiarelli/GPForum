package GPForum::Service::Attachment::Record;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub column {
    my ( undef, $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }

    return _row_column( $row, $name );
}

sub has_text {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub row_hash {
    my ( undef, $row ) = @_;

    if ( !$row ) {
        return {};
    }

    return _copied_row($row);
}

sub rows {
    my ( undef, $search ) = @_;

    if ( $search && $search->can('all') ) {
        return $search->all;
    }

    return _listed_rows($search);
}

sub view {
    my ( $self, $attachment ) = @_;

    return {
        attachment_id     => $self->column( $attachment, 'attachment_id' ),
        byte_size         => $self->column( $attachment, 'byte_size' ),
        media_type        => $self->column( $attachment, 'media_type' ),
        original_filename => $self->column( $attachment, 'original_filename' ),
    };
}

sub _row_column {
    my ( $row, $name ) = @_;

    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub _copied_row {
    my ($row) = @_;

    if ( ref $row eq 'HASH' ) {
        return { %{$row} };
    }
    if ( $row->can('data') ) {
        return { %{ $row->data } };
    }

    return {};
}

sub _listed_rows {
    my ($search) = @_;

    if ( $search && $search->can('rows') ) {
        return @{ $search->rows };
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Record - Attachment row accessors.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $state = $records->column( $attachment, 'state' );

=head1 DESCRIPTION

Reads attachment hashes and DBIx::Class-like rows. It does not persist
attachments or decide download visibility.
L<GPForum::Service::Attachment::Store> keeps writes and resultset lookups.

=head1 SUBROUTINES/METHODS

=head2 column

Reads a named field from a hash or row.

=head2 has_text

True when the value is defined and non-empty.

=head2 row_hash

Copies a hash or C<data> row into a plain hash.

=head2 rows

Expands a resultset-like search into a list.

=head2 view

Returns the public attachment fields used on post pages.

=head1 DIAGNOSTICS

Missing rows yield undef columns and empty hashes.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Row copying only understands hashes and objects with C<data>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
