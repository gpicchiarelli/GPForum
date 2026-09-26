# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FeedProjector;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls    => sub { return []; };
has removals => sub { return []; };

sub project_item {
    my ( $self, $input ) = @_;

    push @{ $self->calls }, $input;

    my @users = @{ $input->{user_ids} || [] };

    return {
        items     => [ map { { user_id => $_ } } @users ],
        ok        => 1,
        projected => scalar @users,
    };
}

sub remove_item {
    my ( $self, $input ) = @_;

    push @{ $self->removals }, $input;

    return { ok => 1, removed => 1 };
}

sub remove_thread {
    my ( $self, $thread_id ) = @_;

    push @{ $self->removals },
      {
        cascade_posts => 1,
        item_id       => $thread_id,
        item_type     => 'thread',
      };

    return { ok => 1, posts_removed => 1, removed => 1 };
}

1;
