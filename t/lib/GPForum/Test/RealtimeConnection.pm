package GPForum::Test::RealtimeConnection;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

BEGIN {
    *send = \&_send_payload;
}

has sent => sub { return []; };
has fail => 0;

sub _send_payload {
    my ( $self, $payload ) = @_;

    die 'realtime send failed' if $self->fail;

    push @{ $self->sent }, $payload;

    return $payload;
}

1;
