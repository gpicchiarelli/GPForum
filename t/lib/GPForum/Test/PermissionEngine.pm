package GPForum::Test::PermissionEngine;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has denied => sub { return {}; };

sub can_notify {
    my ( $self, @arguments ) = @_;

    my $recipient_user_id = $arguments[0];
    return $self->denied->{$recipient_user_id} ? 0 : 1;
}

1;
