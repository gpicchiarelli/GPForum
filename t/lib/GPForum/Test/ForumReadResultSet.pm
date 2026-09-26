# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ForumReadResultSet;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use List::Util qw(any);
use Mojo::Base -base;

use GPForum::Test::ForumReadSearch;

our $VERSION = '0.001';

# The operators lib/ sends to this resultset. Anything else croaks, so a new
# query form fails here instead of silently never matching. "!=" against undef
# is IS NOT NULL, as SQL::Abstract renders it.
const my %COMPARISON_FOR => (
    q{-in} => sub {
        my ( $actual, $expected ) = @_;
        return any { $actual eq $_ } _in_candidates($expected);
    },
    q{!=} => sub {
        my ( $actual, $expected ) = @_;
        return !defined $expected || $actual ne $expected;
    },
    q{>} => sub {
        my ( $actual, $expected ) = @_;
        return $actual gt $expected;
    },
    q{>=} => sub {
        my ( $actual, $expected ) = @_;
        return $actual ge $expected;
    },
    q{<} => sub {
        my ( $actual, $expected ) = @_;
        return $actual lt $expected;
    },
    q{<=} => sub {
        my ( $actual, $expected ) = @_;
        return $actual le $expected;
    },
);

has last_attrs   => undef;
has last_query   => undef;
has filter_rows  => 0;
has rows         => sub { return []; };
has search_count => 0;

sub find {
    my ( $self, $query ) = @_;

    $self->last_query($query);

    return $self->_find_by_query($query) if ref $query eq 'HASH';

    return $self->_find_by_value($query);
}

sub _find_by_value {
    my ( $self, $query ) = @_;

    for my $row ( @{ $self->rows } ) {
        my $matched = _first_matching_column( $row, $query );
        return $row if $matched;
    }

    return;
}

sub _first_matching_column {
    my ( $row, $query ) = @_;

    for my $column (qw(category_id thread_id post_id id user_id username)) {
        my $value = $row->get_column($column);
        return 1 if defined $value && $value eq $query;
    }

    return 0;
}

sub _find_by_query {
    my ( $self, $query ) = @_;

    for my $row ( @{ $self->rows } ) {
        return $row if _matches_query( $row, $query );
    }

    return;
}

sub _matches_query {
    my ( $row, $query ) = @_;

    for my $column ( keys %{$query} ) {
        my $expected = $query->{$column};
        if ( $column eq '-or' ) {
            return 0 if !_matches_any_clause( $row, $expected );
            next;
        }
        if ( $column eq '-and' ) {
            return 0 if !_matches_all_clauses( $row, $expected );
            next;
        }

        my $actual = _column_value( $row, $column );
        return 0 if !_matches_value( $actual, $expected );
    }

    return 1;
}

sub _matches_any_clause {
    my ( $row, $clauses ) = @_;

    for my $clause ( @{$clauses} ) {
        return 1 if _matches_query( $row, $clause );
    }

    return 0;
}

sub _matches_all_clauses {
    my ( $row, $clauses ) = @_;

    for my $clause ( @{$clauses} ) {
        return 0 if !_matches_query( $row, $clause );
    }

    return 1;
}

sub _matches_value {
    my ( $actual, $expected ) = @_;

    return !defined $actual if !defined $expected;

    if ( ref $expected eq 'HASH' ) {
        for my $operator ( keys %{$expected} ) {
            return 0
              if !_matches_operator( $actual, $operator,
                $expected->{$operator} );
        }

        return 1;
    }

    return defined $actual && $actual eq $expected ? 1 : 0;
}

sub _matches_operator {
    my ( $actual, $operator, $expected ) = @_;

    return 0 if !defined $actual;

    my $compare = $COMPARISON_FOR{$operator}
      or croak "ForumReadResultSet does not model the $operator operator";

    return $compare->( $actual, $expected ) ? 1 : 0;
}

# -in takes a list, or a literal subquery \[ $sql, @bind ] whose binds are the
# selected values (see ForumReadSearch::as_query), unwrapped from DBIx::Class's
# [ \%attributes, $value ] form.
sub _in_candidates {
    my ($expected) = @_;

    return @{$expected} if ref $expected eq 'ARRAY';

    my ( undef, @bind ) = @{ ${$expected} };
    return map { ref $_ eq 'ARRAY' ? $_->[1] : $_ } @bind;
}

sub _column_value {
    my ( $row, $column ) = @_;

    my @candidates = ($column);
    if ( $column =~ m{\A ([^.]+) [.] (.+) \z}msx ) {
        push @candidates, $1 . q{_} . $2, $2;
    }

    for my $candidate (@candidates) {
        my $value = $row->get_column($candidate);
        return $value if defined $value;
    }

    return;
}

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->search_count( $self->search_count + 1 );
    $self->last_query($query);
    $self->last_attrs($attrs);

    my $rows = $self->rows;
    if ( $self->filter_rows && ref $query eq 'HASH' ) {
        $rows = [ grep { _matches_query( $_, $query ) } @{$rows} ];
    }

    return GPForum::Test::ForumReadSearch->new(
        rows => $rows,
        keys => _selected_keys( $rows, $attrs ),
    );
}

# A search that selects one column can stand in for a subquery: its as_query
# carries the selected values, the way PostgreSQL would return them.
sub _selected_keys {
    my ( $rows, $attrs ) = @_;

    my $columns = $attrs && $attrs->{columns};
    return [] if ref $columns ne 'ARRAY' || @{$columns} != 1;

    return [ map { _column_value( $_, $columns->[0] ) } @{$rows} ];
}

1;
