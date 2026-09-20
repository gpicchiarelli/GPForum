package GPForum::Test::QueryBudgetResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::CommunityRow;
use GPForum::Test::CommunitySearch;

our $VERSION = '0.001';

has rows              => sub { return {}; };
has skip_search_count => 0;
has updated           => sub { return []; };

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_budget_unique($row);
    return $self->_store_budget($row);
}

sub update_or_create {
    my ( $self, $row ) = @_;

    return $self->_store_budget($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $name = ref $query eq 'HASH' ? $query->{endpoint_name} : $query;
    return $self->rows->{$name};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    if ( $self->skip_search_count ) {
        $self->skip_search_count( $self->skip_search_count - 1 );
        return GPForum::Test::CommunitySearch->new( rows => [] );
    }

    return GPForum::Test::CommunitySearch->new(
        rows => [ values %{ $self->rows } ], );
}

sub _assert_budget_unique {
    my ( $self, $row ) = @_;

    if ( $self->rows->{ $row->{endpoint_name} } ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'endpoint_query_budgets_pkey');
    }

    return;
}

sub _store_budget {
    my ( $self, $row ) = @_;

    my $object = GPForum::Test::CommunityRow->new( data => $row );
    $self->rows->{ $row->{endpoint_name} } = $object;
    push @{ $self->updated }, $row;

    return $object;
}

1;
