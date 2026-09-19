package GPForum::Test::CommunitySearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has query     => undef;
has resultset => undef;
has rows      => sub { return []; };

sub delete {
    my ($self) = @_;

    return 0 if !$self->resultset;

    return $self->resultset->delete_matching( $self->query || {} );
}

1;
