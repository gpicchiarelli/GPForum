# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxRealtimeNotificationHandler;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has recipient_user_id => 'user-1';
has unread_count      => 1;

sub supports {
    return 1;
}

sub handle {
    my ($self) = @_;

    return {
        action => 'notification.dispatch',
        fanout => {
            created => [
                {
                    notification => {
                        recipient_user_id => $self->recipient_user_id,
                    },
                    unread_count => $self->unread_count,
                },
            ],
        },
    };
}

1;
