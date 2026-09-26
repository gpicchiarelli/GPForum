# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::BatchPurge;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 100;
const my $MAX_LIMIT     => 1_000;

sub default_limit {
    return $DEFAULT_LIMIT;
}

sub max_limit {
    return $MAX_LIMIT;
}

sub limit ( $, $input ) {
    my $limit = $input && $input->{limit} ? $input->{limit} : $DEFAULT_LIMIT;
    if ( $limit < 1 ) {
        return $DEFAULT_LIMIT;
    }
    if ( $limit > $MAX_LIMIT ) {
        return $MAX_LIMIT;
    }

    return int $limit;
}

sub search_attrs ( $self, $input, $order_column ) {
    return {
        order_by => [ { -asc => $order_column } ],
        rows     => $self->limit($input),
    };
}

sub delete_rows ( $self, $rows ) {
    my $deleted = 0;
    for my $row ( @{$rows} ) {
        next if !$self->delete_row($row);
        $deleted += 1;
    }

    return {
        deleted => $deleted,
        ok      => 1,
    };
}

sub delete_row ( $self, $row ) {
    my $undefined;
    return $undefined if !$row;
    if ( ref $row eq 'HASH' ) {
        return $self->_delete_hash($row);
    }

    return $self->_delete_object($row);
}

sub _delete_hash ( $, $row ) {
    $row->{_deleted} = 1;
    return 1;
}

sub _delete_object ( $, $row ) {
    if ( $row->can('remove') ) {
        $row->remove;
        return 1;
    }
    if ( $row->can('delete') ) {
        $row->delete;
        return 1;
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::BatchPurge - Bounded delete helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $purge = GPForum::Service::Operations::BatchPurge->new;
    my $limit = $purge->limit( { limit => 50 } );

=head1 DESCRIPTION

Caps operational deletes so scheduled jobs never issue an unbounded
C<DELETE>. Search attributes always include a row limit.

=head1 SUBROUTINES/METHODS

=head2 default_limit

Returns the default batch size of 100.

=head2 max_limit

Returns the hard cap of 1000 rows per call.

=head2 limit

Returns a positive integer between the default and the hard cap.

=head2 search_attrs

Returns oldest-first search attributes including the row cap.

=head2 delete_rows

Deletes each supplied row and returns C<deleted> plus C<ok>.

=head2 delete_row

Deletes one hash or object row. Hash rows are marked C<_deleted>.

=head1 DIAGNOSTICS

None. Invalid limits are clamped rather than thrown.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Callers must search with C<search_attrs> before C<delete_rows>. This helper
does not generate SQL itself.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
