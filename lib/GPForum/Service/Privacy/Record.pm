package GPForum::Service::Privacy::Record;

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

sub rows {
    my ( undef, $search ) = @_;

    if ( $search && $search->can('all') ) {
        return $search->all;
    }

    return _listed_rows($search);
}

sub request_payload {
    my ( $self, $request ) = @_;

    return {
        deletion_request_id => $self->column( $request, 'deletion_request_id' ),
        request_type        => $self->column( $request, 'request_type' ),
        resource_id         => $self->column( $request, 'resource_id' ),
        resource_type       => $self->column( $request, 'resource_type' ),
        status              => $self->column( $request, 'status' ),
    };
}

sub job_hash {
    my ( $self, $job ) = @_;

    if ( !$job ) {
        return;
    }

    return {
        completed_at        => $self->column( $job, 'completed_at' ),
        deletion_request_id => $self->column( $job, 'deletion_request_id' ),
        erasure_job_id      => $self->column( $job, 'erasure_job_id' ),
        last_error          => $self->column( $job, 'last_error' ),
        scheduled_at        => $self->column( $job, 'scheduled_at' ),
        status              => $self->column( $job, 'status' ),
    };
}

sub _row_column {
    my ( $row, $name ) = @_;

    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
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

GPForum::Service::Privacy::Record - Privacy row accessors.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $status = $records->column( $request, 'status' );

=head1 DESCRIPTION

Reads deletion-request and erasure-job hashes or DBIx::Class-like rows. It
does not persist privacy state. L<GPForum::Service::Privacy::DeletionWorkflow>
keeps transactions and locks. Event and audit hashes live in
L<GPForum::Service::Privacy::Event>.

=head1 SUBROUTINES/METHODS

=head2 column

Reads a named field from a hash or row.

=head2 has_text

True when the value is defined and non-empty.

=head2 rows

Expands a resultset-like search into a list.

=head2 request_payload

Returns the canonical deletion-request event payload.

=head2 job_hash

Copies erasure-job fields into a plain hash.

=head1 DIAGNOSTICS

Missing rows yield undef columns. Missing jobs yield undef hashes.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Row listing only understands C<all> and C<rows> searches.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
