package GPForum::Test::ForumReadResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ForumReadSearch;

our $VERSION = '0.001';

has last_attrs   => undef;
has last_query   => undef;
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
        my $actual = $row->get_column($column);
        return 0 if !defined $actual;
        return 0 if $actual ne $query->{$column};
    }

    return 1;
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->search_count( $self->search_count + 1 );
    $self->last_query($query);
    $self->last_attrs($attrs);

    return GPForum::Test::ForumReadSearch->new( rows => $self->rows );
}

1;
