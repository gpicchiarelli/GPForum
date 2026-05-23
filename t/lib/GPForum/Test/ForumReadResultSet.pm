package GPForum::Test::ForumReadResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ForumReadSearch;

our $VERSION = '0.001';

has last_attrs => undef;
has last_query => undef;
has rows       => sub { return []; };

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);

    return GPForum::Test::ForumReadSearch->new( rows => $self->rows );
}

1;

