package GPForum::Test::RealtimeConnection;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

BEGIN {
    *send = \&_send_payload;
}

has sent => sub { return []; };

sub _send_payload {
    my ( $self, $payload ) = @_;

    push @{ $self->sent }, $payload;

    return $payload;
}

1;
