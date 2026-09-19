package GPForum::Test::ForumReadResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ForumReadSearch;

our $VERSION = '0.001';

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

    if ( $operator eq '-in' ) {
        for my $candidate ( @{$expected} ) {
            return 1 if $actual eq $candidate;
        }
        return 0;
    }
    return $actual gt $expected ? 1 : 0 if $operator eq '>';
    return $actual ge $expected ? 1 : 0 if $operator eq '>=';
    return $actual lt $expected ? 1 : 0 if $operator eq '<';
    return $actual le $expected ? 1 : 0 if $operator eq '<=';

    return 0;
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

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->search_count( $self->search_count + 1 );
    $self->last_query($query);
    $self->last_attrs($attrs);

    my $rows = $self->rows;
    if ( $self->filter_rows && ref $query eq 'HASH' ) {
        $rows = [ grep { _matches_query( $_, $query ) } @{$rows} ];
    }

    return GPForum::Test::ForumReadSearch->new( rows => $rows );
}

1;
