package GPForum::Test::OutboxResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::OutboxSearch;

our $VERSION = '0.001';

has rows       => sub { return []; };
has last_query => sub { return {}; };
has last_attrs => sub { return {}; };

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);

    return GPForum::Test::OutboxSearch->new( rows => $self->rows );
}

1;
