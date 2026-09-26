# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::FeedReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 25;
const my @CURSOR_COLUMNS => qw(created_at item_id);

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

# ADR 0102: only rows whose post or thread the reader can still read, judged
# in the query before LIMIT. A feed item kept pointing at a thread after its
# category turned private, showing its title to someone who lost access.
has readability => undef;

sub list_page_for_user ( $self, $user_id, $options ) {
    my $page   = $self->page_window->plan($options);
    my $search = $self->feed_resultset(
        $user_id,
        {
            %{ $options || {} },
            limit => $page->{fetch_rows},
            after => $page->{after},
        }
    );

    my @rows = _rows($search);

    return $self->page_window->page( \@rows, $page->{limit}, \@CURSOR_COLUMNS );
}

# The resultset a feed page executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub feed_resultset ( $self, $user_id, $options ) {
    my $query = {
        user_id => $user_id,
        %{ $self->_readable_items( $user_id, $options->{viewer} ) },
    };
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'item_id',    $options->{after}{id} ],
                sort      => [ 'created_at', $options->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('UserFeedItem')->search_rs(
        $query,
        {
            columns => [
                qw(
                  user_id item_type item_id created_at rank_score
                  visibility_version permission_version
                )
            ],
            order_by => [ { -desc => 'created_at' }, { -desc => 'item_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _readable_items ( $self, $user_id, $viewer ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $viewer // $user_id,
                'me.item_type', 'me.item_id'
            )
        ]
    };
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
