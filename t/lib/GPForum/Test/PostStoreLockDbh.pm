# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostStoreLockDbh;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has calls => sub { return []; };

# The thread row a store's row lock reads back and re-checks: unless a test
# says otherwise, there, live, visible, not locked and written by user-1;
# undef is a thread that is not there.
has thread_row => sub {
    return {
        author_user_id   => 'user-1',
        locked_at        => undef,
        moderation_state => 'visible',
    };
};

sub selectrow_array {
    my ( $self, $sql, undef, @bind ) = @_;

    push @{ $self->calls }, { bind => \@bind, sql => $sql };

    return $bind[0];
}

sub selectrow_hashref {
    my ( $self, $sql, undef, @bind ) = @_;

    push @{ $self->calls }, { bind => \@bind, sql => $sql };

    my $row = $self->thread_row;
    return $row ? { %{$row} } : $row;
}

1;
