# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ViewModelEngagementStore;

use v5.40;

our $VERSION = '0.001';

# A bookmark and subscription store: the thread is bookmarked, and the
# member is subscribed to, not muting, any other target.

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub status_for_user_target {
    my ( undef, undef, $target_type ) = @_;

    return { bookmarked => 1 } if $target_type eq 'thread';

    return { muted => 0, subscribed => 1 };
}

1;
