package GPForum::Test::OutboxResultSet;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Test::OutboxSearch;

our $VERSION = '0.001';

const my %DEFAULT_COLUMN_VALUE => (
    status          => 'pending',
    next_attempt_at => '0000-01-01T00:00:00Z',
    created_at      => '0000-01-01T00:00:00Z',
);

has rows       => sub { return []; };
has last_query => sub { return {}; };
has last_attrs => sub { return {}; };

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);

    my @rows = grep { _matches_query( $_, $query ) } @{ $self->rows };
    @rows = _ordered_rows( \@rows, $attrs );
    @rows = _limited_rows( \@rows, $attrs );

    return GPForum::Test::OutboxSearch->new( rows => \@rows );
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return 1                            if !defined $query;
    return _matches_any( $row, $query ) if ref $query eq 'ARRAY';

    return _matches_all( $row, $query );
}

sub _matches_any {
    my ( $row, $query ) = @_;

    for my $condition ( @{$query} ) {
        return 1 if _matches_all( $row, $condition );
    }

    return;
}

sub _matches_all {
    my ( $row, $condition ) = @_;

    for my $column ( keys %{$condition} ) {
        return if !_matches_column( $row, $column, $condition->{$column} );
    }

    return 1;
}

sub _matches_column {
    my ( $row, $column, $condition ) = @_;

    my $value = _column_value( $row, $column );
    return _matches_operator( $value, $condition ) if ref $condition eq 'HASH';

    return defined $value && $value eq $condition ? 1 : 0;
}

sub _matches_operator {
    my ( $value, $condition ) = @_;

    return _matches_in( $value, $condition->{-in} )
      if exists $condition->{-in};
    return _matches_lte( $value, $condition->{'<='} )
      if exists $condition->{'<='};
    return _matches_gt( $value, $condition->{'>'} )
      if exists $condition->{'>'};

    return;
}

sub _matches_in {
    my ( $value, $allowed ) = @_;

    return if !defined $value;

    my %allowed = map { $_ => 1 } @{$allowed};

    return $allowed{$value} ? 1 : 0;
}

sub _matches_lte {
    my ( $value, $maximum ) = @_;

    return if !defined $value;

    return $value le $maximum ? 1 : 0;
}

sub _matches_gt {
    my ( $value, $minimum ) = @_;

    return if !defined $value;

    return $value gt $minimum ? 1 : 0;
}

sub _ordered_rows {
    my ( $rows, $attrs ) = @_;

    my @columns = _ordered_columns($attrs);
    return @{$rows} if !@columns;

    my @ordered = sort { _compare_by_columns( $a, $b, @columns ) } @{$rows};

    return @ordered;
}

sub _ordered_columns {
    my ($attrs) = @_;

    return if !$attrs || !$attrs->{order_by};

    return map { $_->{-asc} } @{ $attrs->{order_by} };
}

sub _compare_by_columns {
    my ( $first_row, $second_row, @columns ) = @_;

    for my $column (@columns) {
        my $comparison =
          _column_value( $first_row, $column )
          cmp _column_value( $second_row, $column );
        return $comparison if $comparison;
    }

    return 0;
}

sub _limited_rows {
    my ( $rows, $attrs ) = @_;

    my $limit = $attrs ? $attrs->{rows} : undef;
    return @{$rows} if !defined $limit || @{$rows} <= $limit;

    return @{$rows}[ 0 .. $limit - 1 ];
}

sub _column_value {
    my ( $row, $column ) = @_;

    my $value = $row->get_column($column);
    return $value if defined $value;

    return if !exists $DEFAULT_COLUMN_VALUE{$column};

    return $DEFAULT_COLUMN_VALUE{$column};
}

1;
