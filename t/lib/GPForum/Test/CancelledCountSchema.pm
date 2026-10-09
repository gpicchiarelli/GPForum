# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CancelledCountSchema;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::StatementTimeoutReadability;

our $VERSION = '0.001';

# A schema in which a member's notification is already read and nothing
# else answers. It is its own NotificationInbox resultset, whose find
# returns the notification with read_at; every other resultset -- the
# readability lookup the unread count joins -- dies as PostgreSQL cancelling
# the statement does. So a mark-read commits, and only its badge count
# fails.
has read_at => '2026-05-23T12:00:00Z';

sub txn_do {
    my ( $self, $code ) = @_;

    return $code->();
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self if $name eq 'NotificationInbox';

    die GPForum::Test::StatementTimeoutReadability->message
      . qq{ [for Statement "SELECT 1"]\n};
}

sub find {
    my ( $self, $query ) = @_;

    return { %{$query}, read_at => $self->read_at };
}

1;
