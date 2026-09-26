# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::MentionReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 25;
const my @CURSOR_COLUMNS => qw(created_at mention_id);

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

# ADR 0102: only rows whose post or thread the reader can still read, judged
# in the query before LIMIT. A mention kept pointing at a thread after its
# category turned private, showing its title to someone who lost access.
has readability => undef;

sub list_page_for_recipient ( $self, $user_id, $options ) {
    my $page   = $self->page_window->plan($options);
    my $search = $self->mentions_resultset(
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

# The resultset a mentions page executes; public so tests and the
# query-plan evidence see the SQL that runs.
sub mentions_resultset ( $self, $user_id, $options ) {
    my $query = {
        'me.mentioned_user_id' => $user_id,
        %{ $self->_readable_sources( $user_id, $options->{viewer} ) },
    };
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'me.mention_id', $options->{after}{id} ],
                sort      => [ 'me.created_at', $options->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('Mention')->search_rs(
        $query,
        {
            columns => [
                qw(
                  mention_id source_type source_id actor_id mentioned_user_id
                  mentioned_username created_at
                )
            ],
            join      => 'actor',
            '+select' => [ 'actor.username', 'actor.display_name' ],
            '+as'     => [qw(actor_username actor_display_name)],
            order_by  =>
              [ { -desc => 'me.created_at' }, { -desc => 'me.mention_id' } ],
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _readable_sources ( $self, $user_id, $viewer ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $viewer // $user_id,
                'me.source_type', 'me.source_id'
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
