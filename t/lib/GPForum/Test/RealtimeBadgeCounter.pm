# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeBadgeCounter;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# Stands in for the notification dispatcher, whose unread count the hub's
# badge snapshots carry.
has calls  => sub { return []; };
has counts => sub { return {}; };

sub unread_count_for_user {
    my ( $self, $user_id ) = @_;

    push @{ $self->calls }, $user_id;

    return $self->counts->{$user_id} // 0;
}

1;
