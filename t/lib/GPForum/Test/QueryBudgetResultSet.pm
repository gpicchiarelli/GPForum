package GPForum::Test::QueryBudgetResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::CommunityRow;
use GPForum::Test::CommunitySearch;

our $VERSION = '0.001';

has rows    => sub { return {}; };
has updated => sub { return []; };

sub update_or_create {
    my ( $self, $row ) = @_;

    my $object = GPForum::Test::CommunityRow->new( data => $row );
    $self->rows->{ $row->{endpoint_name} } = $object;
    push @{ $self->updated }, $row;

    return $object;
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    return GPForum::Test::CommunitySearch->new(
        rows => [ values %{ $self->rows } ], );
}

1;
