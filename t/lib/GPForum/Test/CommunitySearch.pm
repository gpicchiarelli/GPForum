package GPForum::Test::CommunitySearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has query     => undef;
has resultset => undef;
has rows      => sub { return []; };

sub delete_rows {
    my ($self) = @_;

    if ( !$self->resultset ) {
        return 0;
    }

    return $self->resultset->delete_matching( $self->query || {} );
}

BEGIN {
    *delete = \&delete_rows;
}

1;
