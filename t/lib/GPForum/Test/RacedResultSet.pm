# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RacedResultSet;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A real resultset, as GPForum::Test::RacedSchema hands it out while a lookup
# in it is still to miss. A missed search is still a statement PostgreSQL
# runs, with a condition no row meets, so what comes back is a real resultset
# whatever the caller does with it next.
has inner => undef;
has name  => undef;
has raced => undef;

sub find {
    my ( $self, @arguments ) = @_;

    return undef if $self->raced->take_miss( $self->name );

    return $self->inner->find(@arguments);
}

sub search_rs {
    my ( $self, $query, $attributes ) = @_;

    if ( $self->raced->take_miss( $self->name ) ) {
        return $self->inner->search_rs( { -and => [ $query // {}, \'1 = 0' ] },
            $attributes );
    }

    return $self->inner->search_rs( $query, $attributes );
}

sub create {
    my ( $self, @arguments ) = @_;

    return $self->inner->create(@arguments);
}

1;
