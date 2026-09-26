# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostStoreLockDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

# The row PostStore's thread lock reads back and re-checks. An open thread
# unless a test says otherwise; undef is a thread that is not there.
has thread_row => sub {
    return { locked_at => undef, moderation_state => 'visible' };
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
