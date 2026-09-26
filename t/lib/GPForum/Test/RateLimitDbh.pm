# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RateLimitDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls   => sub { return []; };
has buckets => sub { return {}; };

sub selectrow_hashref {
    my ( $self, $sql, $attributes, @bind ) = @_;

    push @{ $self->calls }, { sql => $sql, bind => \@bind };

    my $key = join q{:}, @bind[ 0 .. 3 ];
    $self->buckets->{$key} ||= {
        actor_hash        => $bind[1],
        observed_count    => 0,
        window_started_at => $bind[3],
    };
    $self->buckets->{$key}{observed_count} += 1;

    return { %{ $self->buckets->{$key} } };
}

1;
