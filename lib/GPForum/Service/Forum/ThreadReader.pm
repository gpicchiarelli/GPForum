# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadReader;

use strict;
use warnings;

use Const::Fast;
use English      qw(-no_match_vars);
use MIME::Base64 qw(decode_base64url encode_base64url);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $PINNED_CURSOR_PARTS => 3;
const my $LEGACY_CURSOR_PARTS => 2;
const my $PINNED_TOP          => 1;
const my %UNPINNED_TOKEN      => ( q{} => 1, '0' => 1, 'f' => 1, 'false' => 1 );

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub list_category_threads ( $self, $request ) {
    my $plan = $self->page_window->plan($request);

    return _pinned_page(
        [ _rows( $self->category_threads_resultset( $request, $plan ) ) ],
        $plan->{limit} );
}

# The resultset list_category_threads executes, before it is executed. Public
# so the plan tests EXPLAIN what actually runs rather than a transcription.
sub category_threads_resultset ( $self, $request, $plan = undef ) {
    $plan ||= $self->page_window->plan($request);

    # Scalar first: with no cursor the decoder returns an empty list, which as
    # an argument would remove the parameter rather than pass undef.
    my $after   = _decode_pinned_cursor( $request->{after} );
    my $visible = _visible_category_query( $request, $after );

    return $self->schema->resultset('Thread')->search_rs(
        $self->_viewer_condition(
            $visible, $request->{viewer_user_id},
            $plan->{fetch_rows}
        ),
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug pinned
                  visibility moderation_state locked_at last_activity_at
                  created_at deleted_at
                )
            ],
            join      => 'author',
            '+select' => [ 'author.username', 'author.display_name' ],
            '+as'     => [qw(author_username author_display_name)],
            order_by  => _category_order(),
            rows      => $plan->{fetch_rows},
        }
    );
}

sub list_public_threads ( $self, $request ) {
    my $plan = $self->page_window->plan($request);

    return $self->page_window->page(
        [ _rows( $self->latest_threads_resultset( $request, $plan ) ) ],
        $plan->{limit}, [ 'last_activity_at', 'thread_id' ],
    );
}

# The resultset list_public_threads executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
# Public threads only, from categories and spaces the viewer can read (ADR
# 0102): the home page's latest list and, with an anonymous viewer, the
# sitemap and the Atom feed.
sub latest_threads_resultset ( $self, $request, $plan = undef ) {
    $plan ||= $self->page_window->plan($request);
    my $query = {
        'me.deleted_at'       => undef,
        'me.moderation_state' => { -in => [ 'visible', 'locked' ] },
        'me.visibility'       => 'public',
        %{ GPForum::Service::Forum::Visibility->readable_condition(
                $request->{viewer}
                  || GPForum::Service::Forum::Viewer->anonymous,
                {
                    category    => 'category.visibility',
                    category_id => 'me.category_id',
                    space       => 'space.visibility',
                    space_id    => 'category.space_id',
                }
            )
        },
    };
    if ( $plan->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id   => [ 'me.thread_id',        $plan->{after}{id} ],
                sort => [ 'me.last_activity_at', $plan->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('Thread')->search_rs(
        $query,
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug pinned
                  visibility moderation_state last_activity_at created_at
                  deleted_at
                )
            ],
            join      => [ 'author',          { category => 'space' } ],
            '+select' => [ 'author.username', 'author.display_name' ],
            '+as'     => [qw(author_username author_display_name)],
            order_by  => [
                { -desc => 'me.last_activity_at' },
                { -desc => 'me.thread_id' },
            ],
            rows => $plan->{fetch_rows},
        }
    );
}

# The category was authorized by the caller; its threads are judged on their
# own level, with the viewer's grants decided for the category
# ($request->{viewer_scope}, from Viewer->within). Without one, public only.
sub _visible_category_query ( $request, $after ) {
    my $query = {
        'me.category_id'      => $request->{category_id},
        'me.deleted_at'       => undef,
        'me.moderation_state' => { -in => [ 'visible', 'locked' ] },
        %{ GPForum::Service::Forum::Visibility->readable_condition(
                $request->{viewer_scope}
                  || GPForum::Service::Forum::Viewer->anonymous,
                {
                    thread        => 'me.visibility',
                    thread_author => 'me.author_user_id',
                }
            )
        },
    };
    if ($after) {
        $query->{-or} = _pinned_cursor_clause($after);

        # The bounds the OR implies, which the category index can answer
        # (Infrastructure::Keyset says why). Past the pinned block -- every
        # deep page -- the activity bound holds too.
        $query->{'me.pinned'} = { q{<=} => $after->{pinned} };
        if ( !$after->{pinned} ) {
            $query->{'me.last_activity_at'} = { q{<=} => $after->{sort_value} };
        }
    }

    return $query;
}

# An anonymous reader sees the visible threads. A signed-in reader also sees
# their own deleted ones, and "deleted_at IS NULL OR author_user_id = ?" as one
# predicate can use no index on threads: every category index is partial on
# deleted_at IS NULL, which that OR does not imply, so PostgreSQL read the whole
# table for every signed-in category page. Each half is instead read in page
# order from its own partial index and cut at the page size, and the page is
# taken from the union of the two by key -- still one statement, and still
# ordered by PostgreSQL rather than merged here.
sub _viewer_condition ( $self, $visible, $viewer, $rows ) {
    return $visible if !defined $viewer || !length $viewer;

    my $own_deleted = {
        %{$visible},
        'me.author_user_id' => $viewer,
        'me.deleted_at'     => { q{!=} => undef },
    };

    return {
        'me.thread_id' => {
            -in => _union_all(
                map { $self->_page_keys( $_, $rows )->as_query } $visible,
                $own_deleted
            )
        }
    };
}

sub _page_keys ( $self, $query, $rows ) {
    return $self->schema->resultset('Thread')->search_rs(
        $query,
        {
            columns  => ['thread_id'],
            order_by => _category_order(),
            rows     => $rows,
        }
    );
}

# as_query gives \[ $sql, @bind ] with the SQL already parenthesised, so the
# arms join with UNION ALL as they are and their binds concatenate in order.
sub _union_all (@subqueries) {
    my @arms = map { ${$_} } @subqueries;
    my ( @sql, @bind );
    for my $arm (@arms) {
        my ( $sql, @arm_bind ) = @{$arm};
        push @sql,  $sql;
        push @bind, @arm_bind;
    }

    return \[ join( ' UNION ALL ', @sql ), @bind ];
}

sub _category_order {
    return [
        { -desc => 'me.pinned' },
        { -desc => 'me.last_activity_at' },
        { -desc => 'me.thread_id' },
    ];
}

# The category listing orders by pinned DESC, last_activity_at DESC,
# thread_id DESC, so the keyset predicate has to lead with pinned. A cursor
# that only carried the last two columns let pinned rows repeat or vanish
# across pages.
sub _pinned_cursor_clause ($after) {
    return [
        { 'me.pinned' => { '<' => $after->{pinned} } },
        {
            'me.pinned'           => $after->{pinned},
            'me.last_activity_at' => { '<' => $after->{sort_value} },
        },
        {
            'me.pinned'           => $after->{pinned},
            'me.last_activity_at' => $after->{sort_value},
            'me.thread_id'        => { '<' => $after->{id} },
        },
    ];
}

sub _pinned_page ( $rows, $limit ) {
    my @items    = @{$rows};
    my $has_next = @items > $limit ? 1 : 0;

    if ($has_next) {
        pop @items;
    }

    return {
        items       => \@items,
        has_next    => $has_next,
        next_cursor => $has_next ? _encode_pinned_cursor( $items[-1] ) : undef,
    };
}

sub _encode_pinned_cursor ($row) {
    return if !$row;

    return encode_base64url(
        join q{|},
        _pinned_flag( $row->get_column('pinned') ),
        _cursor_text( $row->get_column('last_activity_at') ),
        _cursor_text( $row->get_column('thread_id') ),
    );
}

sub _decode_pinned_cursor ($cursor) {
    return if !defined $cursor || !length $cursor;

    my $decoded = eval { return decode_base64url($cursor); };
    return if $EVAL_ERROR || !defined $decoded;

    my @parts        = split /[|]/msx, $decoded, $PINNED_CURSOR_PARTS;
    my $cursor_parts = _pinned_cursor_from_parts( \@parts );
    return if !$cursor_parts;
    return
      if !GPForum::Service::Forum::PageWindow->acceptable_cursor(
        @{$cursor_parts}{qw(sort_value id)} );

    return $cursor_parts;
}

# Cursors minted before pinned joined the keyset carry two parts. Resume them
# from the top of the pinned block instead of rejecting the page.
sub _pinned_cursor_from_parts ($parts) {
    if ( @{$parts} == $LEGACY_CURSOR_PARTS ) {
        return {
            pinned     => $PINNED_TOP,
            sort_value => $parts->[0],
            id         => $parts->[1],
        };
    }
    if ( @{$parts} != $PINNED_CURSOR_PARTS ) {
        return;
    }

    return {
        pinned     => _pinned_flag( $parts->[0] ),
        sort_value => $parts->[1],
        id         => $parts->[2],
    };
}

sub _pinned_flag ($value) {
    return 0 if !defined $value;

    return exists $UNPINNED_TOKEN{ lc $value } ? 0 : 1;
}

sub _cursor_text ($value) {
    return defined $value ? $value : q{};
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
