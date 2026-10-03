# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeConnection;

use Mojo::Base -base;
use v5.40;

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
