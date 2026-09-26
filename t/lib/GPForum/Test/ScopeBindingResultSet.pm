# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScopeBindingResultSet;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has bindings   => sub { return []; };
has last_query => sub { return {}; };

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query ) = @_;

    $self->last_query($query);
    my @matched = grep { _matches( $_, $query ) } @{ $self->bindings };

    return __PACKAGE__->new( bindings => \@matched );
}

sub single {
    my ($self) = @_;

    return $self->bindings->[0];
}

sub _matches {
    my ( $row, $query ) = @_;

    for my $field ( keys %{$query} ) {
        if ( !_matches_field( $row, $field, $query->{$field} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _matches_field {
    my ( $row, $field, $expected ) = @_;

    if ( $field eq '-or' ) {
        return _matches_any( $row, $expected );
    }

    return _matches_value( $row->{$field}, $expected );
}

sub _matches_value {
    my ( $actual, $expected ) = @_;

    if ( !defined $expected ) {
        return !defined $actual;
    }
    if ( !defined $actual ) {
        return 0;
    }

    return $actual eq $expected;
}

sub _matches_any {
    my ( $row, $clauses ) = @_;

    for my $clause ( @{$clauses} ) {
        if ( _matches( $row, $clause ) ) {
            return 1;
        }
    }

    return 0;
}

1;
