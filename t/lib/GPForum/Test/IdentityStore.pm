package GPForum::Test::IdentityStore;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub create_registration {
    my ( $self, $registration ) = @_;

    return { ok => 1, user => $registration->{user} };
}

1;
