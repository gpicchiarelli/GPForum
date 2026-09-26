# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostPosition;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $FIRST_POSITION => 1;
const my $UNSAFE_NEXT_POSITION_MESSAGE =>
'PostPosition::next_position is unsafe for writes; use PostStore deferred allocation';

has schema => undef;

sub next_position {
    croak $UNSAFE_NEXT_POSITION_MESSAGE;
}

sub read_next_position ( $self, $thread_id ) {
    my $posts  = $self->schema->resultset('Post');
    my $search = $posts->search_rs(
        { thread_id => $thread_id },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' }, ],
            rows     => 1,
        }
    );
    my $latest = $search->single;

    return $FIRST_POSITION if !$latest;

    return $latest->get_column('position') + 1;
}

1;
