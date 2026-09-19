package GPForum::Test::PurgeResultSet;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $OP_LTE => q{<} . q{=};
const my $OP_NE  => q{!} . q{=};

has last_attrs => undef;
has last_query => undef;
has name       => undef;
has rows       => sub { return []; };
has schema     => undef;

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);
    $self->_remember_last;

    return ref($self)->new(
        last_attrs => $attrs,
        last_query => $query,
        name       => $self->name,
        rows       => [ $self->_filtered_rows( $query, $attrs ) ],
        schema     => $self->schema,
    );
}

sub items {
    my ($self) = @_;

    return @{ $self->rows };
}

sub _remember_last {
    my ($self) = @_;

    if ( $self->schema ) {
        $self->schema->last_resultset($self);
    }

    return;
}

sub _filtered_rows {
    my ( $self, $query, $attrs ) = @_;

    my @rows =
      grep { _matches_query( $_->values, $query ) } @{ $self->_source_rows };
    @rows = _ordered_rows( \@rows, $attrs );

    return _limited_rows( \@rows, $attrs );
}

sub _source_rows {
    my ($self) = @_;

    return [] if !$self->schema;

    return $self->schema->rows_for( $self->name );
}

sub _matches_query {
    my ( $values, $query ) = @_;

    return 1 if !defined $query;
    if ( _has_or($query) ) {
        return _matches_or( $values, $query->{-or} );
    }

    return _matches_and( $values, $query );
}

sub _has_or {
    my ($query) = @_;

    return ref $query eq 'HASH' && exists $query->{-or} ? 1 : 0;
}

sub _matches_or {
    my ( $values, $clauses ) = @_;

    for my $clause ( @{$clauses} ) {
        return 1 if _matches_and( $values, $clause );
    }

    return 0;
}

sub _matches_and {
    my ( $values, $query ) = @_;

    for my $key ( keys %{$query} ) {
        return 0 if !_matches_field( $values->{$key}, $query->{$key} );
    }

    return 1;
}

sub _matches_field {
    my ( $actual, $expected ) = @_;

    if ( ref $expected eq 'HASH' ) {
        return _matches_operator( $actual, $expected );
    }

    return _matches_scalar( $actual, $expected );
}

sub _matches_scalar {
    my ( $actual, $expected ) = @_;

    return 0 if _defined_mismatch( $actual, $expected );
    return 1 if !defined $expected;

    return $actual eq $expected ? 1 : 0;
}

sub _defined_mismatch {
    my ( $actual, $expected ) = @_;

    return 1 if defined $expected  && !defined $actual;
    return 1 if !defined $expected && defined $actual;

    return 0;
}

sub _matches_operator {
    my ( $actual, $operator ) = @_;

    return _is_not_null($actual) if _is_not_null_op($operator);
    return _matches_lte( $actual, $operator->{$OP_LTE} )
      if exists $operator->{$OP_LTE};
    return _matches_in( $actual, $operator->{-in} )
      if exists $operator->{-in};

    return 0;
}

sub _is_not_null_op {
    my ($operator) = @_;

    return exists $operator->{$OP_NE} && !defined $operator->{$OP_NE} ? 1 : 0;
}

sub _is_not_null {
    my ($actual) = @_;

    return defined $actual ? 1 : 0;
}

sub _matches_lte {
    my ( $actual, $maximum ) = @_;

    return 0 if !defined $actual;

    return $actual le $maximum ? 1 : 0;
}

sub _matches_in {
    my ( $actual, $allowed ) = @_;

    return 0 if !defined $actual;

    for my $value ( @{$allowed} ) {
        return 1 if defined $value && $actual eq $value;
    }

    return 0;
}

sub _ordered_rows {
    my ( $rows, $attrs ) = @_;

    my $column = _order_column($attrs);
    return @{$rows} if !$column;

    return map { $_->[0] }
      sort { $a->[1] cmp $b->[1] }
      map { [ $_, _row_value( $_, $column ) ] } @{$rows};
}

sub _order_column {
    my ($attrs) = @_;

    return if !$attrs || !$attrs->{order_by};

    return $attrs->{order_by}[0]{-asc};
}

sub _row_value {
    my ( $row, $column ) = @_;

    return $row->get_column($column) || q{};
}

sub _limited_rows {
    my ( $rows, $attrs ) = @_;

    my $limit = $attrs ? $attrs->{rows} : undef;
    return @{$rows} if !defined $limit || @{$rows} <= $limit;

    return @{$rows}[ 0 .. $limit - 1 ];
}

1;
