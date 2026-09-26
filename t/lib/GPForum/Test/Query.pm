# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Query;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;

our $VERSION = '0.001';

# The DBIx::Class comparison operators lib/ actually sends to a resultset.
# Anything else croaks, so a new query form is caught here instead of
# silently never matching.
const my %COMPARISON_FOR => (
    q{=}    => \&_equal,
    q{!=}   => \&_unequal,
    q{<}    => \&_less_than,
    q{<=}   => \&_at_most,
    q{>}    => \&_greater_than,
    q{>=}   => \&_at_least,
    -in     => \&_in_list,
    -not_in => \&_not_in_list,
    -like   => \&_like,
);

sub matches {
    my ( $row, $query, $reader ) = @_;

    return _matched( $row, $query, $reader || \&_hash_column );
}

sub _matched {
    my ( $row, $query, $read ) = @_;

    return 1                                   if !defined $query;
    return _matches_any( $row, $query, $read ) if ref $query eq 'ARRAY';

    for my $key ( keys %{$query} ) {
        return 0 if !_matches_key( $row, $key, $query->{$key}, $read );
    }

    return 1;
}

sub _matches_any {
    my ( $row, $clauses, $read ) = @_;

    for my $clause ( @{$clauses} ) {
        return 1 if _matched( $row, $clause, $read );
    }

    return 0;
}

sub _matches_all {
    my ( $row, $clauses, $read ) = @_;

    for my $clause ( @{$clauses} ) {
        return 0 if !_matched( $row, $clause, $read );
    }

    return 1;
}

sub _matches_key {
    my ( $row, $key, $expected, $read ) = @_;

    return _matches_any( $row, $expected, $read ) if $key eq '-or';
    return _matches_all( $row, $expected, $read ) if $key eq '-and';

    my $actual = $read->( $row, column_field($key) );

    return _matches_operators( $actual, $expected ) if ref $expected eq 'HASH';

    return _equal( $actual, $expected );
}

sub _matches_operators {
    my ( $actual, $expected ) = @_;

    for my $operator ( keys %{$expected} ) {
        croak "unsupported test query operator: $operator"
          if !exists $COMPARISON_FOR{$operator};
        return 0
          if !$COMPARISON_FOR{$operator}->( $actual, $expected->{$operator} );
    }

    return 1;
}

sub _equal {
    my ( $actual, $expected ) = @_;

    return defined $actual ? 0 : 1 if !defined $expected;
    return 0                       if !defined $actual;

    return $actual eq $expected ? 1 : 0;
}

sub _unequal {
    my ( $actual, $expected ) = @_;

    return _equal( $actual, $expected ) ? 0 : 1;
}

sub _less_than {
    my ( $actual, $expected ) = @_;

    return 0 if !_comparable( $actual, $expected );

    return compare_values( $actual, $expected ) < 0 ? 1 : 0;
}

sub _at_most {
    my ( $actual, $expected ) = @_;

    return 0 if !_comparable( $actual, $expected );

    return compare_values( $actual, $expected ) <= 0 ? 1 : 0;
}

sub _greater_than {
    my ( $actual, $expected ) = @_;

    return 0 if !_comparable( $actual, $expected );

    return compare_values( $actual, $expected ) > 0 ? 1 : 0;
}

sub _at_least {
    my ( $actual, $expected ) = @_;

    return 0 if !_comparable( $actual, $expected );

    return compare_values( $actual, $expected ) >= 0 ? 1 : 0;
}

sub _comparable {
    my ( $actual, $expected ) = @_;

    return defined $actual && defined $expected ? 1 : 0;
}

sub _like {
    my ( $actual, $pattern ) = @_;

    return 0 if !_comparable( $actual, $pattern );

    return $actual =~ _like_regex($pattern) ? 1 : 0;
}

sub _like_regex {
    my ($pattern) = @_;

    my $expression = join q{.*}, map { _like_literal($_) } split /%/msx,
      $pattern, -1;

    return qr/\A $expression \z/msx;
}

sub _like_literal {
    my ($chunk) = @_;

    my $literal = quotemeta $chunk;
    $literal =~ s/_/./msxg;

    return $literal;
}

sub _in_list {
    my ( $actual, $values ) = @_;

    return 0 if !defined $actual;

    for my $value ( @{$values} ) {
        return 1 if defined $value && $actual eq $value;
    }

    return 0;
}

sub _not_in_list {
    my ( $actual, $values ) = @_;

    return 0 if !defined $actual;

    return _in_list( $actual, $values ) ? 0 : 1;
}

sub column_field {
    my ($column) = @_;

    my $field = $column;
    $field =~ s/\A me[.] //msx;

    return $field;
}

sub ordered_rows {
    my ( $rows, $attributes, $reader ) = @_;

    my @terms = _order_terms($attributes);
    return @{$rows} if !@terms;

    my $read = $reader || \&_hash_column;

    return sort { _compare_terms( $a, $b, \@terms, $read ) } @{$rows};
}

sub windowed_rows {
    my ( $rows, $attributes ) = @_;

    return @{$rows} if !$attributes;

    my @window = _offset_rows( $rows, $attributes->{offset} );

    return _limited_rows( \@window, $attributes->{rows} );
}

sub compare_values {
    my ( $held, $other ) = @_;

    return _compare_missing( $held, $other )
      if !defined $held || !defined $other;
    return $held <=> $other if _numeric_pair( $held, $other );

    return $held cmp $other;
}

sub _compare_missing {
    my ( $held, $other ) = @_;

    return 0 if !defined $held && !defined $other;

    return defined $held ? -1 : 1;
}

sub _hash_column {
    my ( $row, $column ) = @_;

    return $row->{$column};
}

sub _order_terms {
    my ($attributes) = @_;

    my $order_by = $attributes ? $attributes->{order_by} : undef;

    return                                      if !$order_by;
    return map { _order_term($_) } @{$order_by} if ref $order_by eq 'ARRAY';

    return _order_term($order_by);
}

sub _order_term {
    my ($term) = @_;

    return { column => column_field($term), descending => 0 }
      if ref $term ne 'HASH';
    return { column => column_field( $term->{-desc} ), descending => 1 }
      if exists $term->{-desc};

    return { column => column_field( $term->{-asc} ), descending => 0 };
}

sub _compare_terms {
    my ( $row, $other_row, $terms, $read ) = @_;

    for my $term ( @{$terms} ) {
        my $order = compare_values(
            $read->( $row,       $term->{column} ),
            $read->( $other_row, $term->{column} )
        );
        next if !$order;

        return $term->{descending} ? -$order : $order;
    }

    return 0;
}

sub _numeric_pair {
    my ( $held, $other ) = @_;

    return _numeric_text($held) && _numeric_text($other) ? 1 : 0;
}

sub _numeric_text {
    my ($value) = @_;

    return $value =~ /\A -? \d+ (?: [.] \d+ )? \z/msx ? 1 : 0;
}

sub _offset_rows {
    my ( $rows, $offset ) = @_;

    return @{$rows} if !$offset;
    return          if $offset > $#{$rows};

    return @{$rows}[ $offset .. $#{$rows} ];
}

sub _limited_rows {
    my ( $rows, $limit ) = @_;

    return @{$rows} if !defined $limit || @{$rows} <= $limit;
    return          if $limit < 1;

    return @{$rows}[ 0 .. $limit - 1 ];
}

1;

__END__

=head1 NAME

GPForum::Test::Query - Where clauses, ordering and windowing for fake resultsets.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    @rows = GPForum::Test::Query::ordered_rows( \@rows, $attrs,
        sub { return $_[0]->get_column( $_[1] ); } );
    @rows = GPForum::Test::Query::windowed_rows( \@rows, $attrs );
    $matched = GPForum::Test::Query::matches( $row, $query );

=head1 DESCRIPTION

Applies the where clause and the C<order_by>, C<rows>, and C<offset> search
attributes that lib/ sends, so a fake resultset returns the rows a real query
would, in the order a real query would. Supports the
DBIx::Class forms in use: C<< { -desc => 'me.col' } >>, C<< { -asc => 'col' } >>,
a bare column name, and an arrayref of those. The C<me.> prefix is stripped
before the row is read. Values that both look numeric compare numerically,
everything else compares as text, and undef sorts last ascending so the order
is stable either way.

=head1 SUBROUTINES/METHODS

=head2 matches

Tests a row against a DBIx::Class-style where clause, reading columns through
the optional reader callback. Supports nested C<-or>/C<-and>, a top-level
arrayref (an OR of clauses), C<undef> as IS NULL, and the comparison operators
lib/ sends: C<=>, C<!=>, C<< < >>, C<< <= >>, C<< > >>, C<< >= >>, C<-in>,
C<-not_in>, and C<-like>. An operator it does not implement croaks rather than
quietly matching nothing.

=head2 column_field

Strips a C<me.> prefix from a column name.

=head2 ordered_rows

Sorts rows by the C<order_by> attribute, reading columns through the optional
reader callback (hash access by default).

=head2 windowed_rows

Applies the C<offset> and C<rows> attributes, in that order.

=head2 compare_values

Compares two column values numerically or as text, with undef sorting last.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Carp> and L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not implement C<group_by>, C<having>, C<join>, C<prefetch>, or ordering
by an SQL expression. Related-table columns such as C<thread.visibility> are
read from the row itself, so a fake row has to carry them.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
