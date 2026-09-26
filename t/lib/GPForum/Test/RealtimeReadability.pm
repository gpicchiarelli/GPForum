# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeReadability;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# Thread or post id => { user id => 1 } for each reader who may read it.
has readable => sub { return {}; };

sub readable_by {
    my ( $self, $reader, $type, $id ) = @_;

    my @readers = $self->readers_of( $type, $id, $reader );
    return @readers ? 1 : 0;
}

sub readers_of {
    my ( $self, $type, $id, @readers ) = @_;

    my $can_read =
      $type eq 'thread' || $type eq 'post' ? $self->readable->{$id} || {} : {};
    return grep { defined && $can_read->{$_} } @readers;
}

1;
