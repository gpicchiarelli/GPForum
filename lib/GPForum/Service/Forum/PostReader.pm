# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostReader;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub list_thread_posts ( $self, $request ) {
    my $plan = $self->page_window->plan($request);

    return $self->page_window->page(
        [ _rows( $self->thread_posts_resultset( $request, $plan ) ) ],
        $plan->{limit}, [ 'position', 'post_id' ],
    );
}

# The resultset list_thread_posts executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub thread_posts_resultset ( $self, $request, $plan = undef ) {
    $plan ||= $self->page_window->plan($request);
    my $query = {
        'me.thread_id'        => $request->{thread_id},
        'me.moderation_state' => 'visible',
        %{ _post_visibility($request) },
    };
    _apply_deleted_filter( $query, $request );
    if ( $plan->{after} ) {
        _apply_cursor( $query, $plan->{after} );
    }

    return $self->schema->resultset('Post')->search_rs(
        $query,
        {
            columns => [
                qw(
                  post_id thread_id author_user_id current_body_id position
                  visibility moderation_state deleted_at
                )
            ],
            join      => [ 'current_body', 'author' ],
            '+select' => [
                'current_body.body_rendered_safe', 'current_body.body_source',
                'author.username',                 'author.display_name',
            ],
            '+as' => [qw(body body_source author_username author_display_name)],
            order_by =>
              [ { -asc => 'me.position' }, { -asc => 'me.post_id' }, ],
            rows => $plan->{fetch_rows},
        }
    );
}

# ADR 0102. The thread was authorized by the caller; its posts are judged on
# their own level, with the viewer's grants decided for the thread's category
# ($request->{viewer_scope}, from Viewer->within). Without one, public only.
sub _post_visibility ($request) {
    my $viewer = $request->{viewer_scope}
      || GPForum::Service::Forum::Viewer->anonymous;

    return GPForum::Service::Forum::Visibility->readable_condition(
        $viewer,
        {
            post        => 'me.visibility',
            post_author => 'me.author_user_id',
        }
    );
}

# A post, if it and its thread are visible and the viewer can read them: its
# space, category, thread and the post itself (ADR 0102).
sub find_visible_post ( $self, $post_id, $viewer = undef ) {
    my $undefined;
    return $undefined if !defined $post_id || !length $post_id;

    my $posts = $self->schema->resultset('Post');
    my $row   = $posts->search_rs(
        {
            'me.post_id'              => $post_id,
            'me.deleted_at'           => undef,
            'me.moderation_state'     => 'visible',
            'thread.deleted_at'       => undef,
            'thread.moderation_state' => { -in => [ 'visible', 'locked' ] },
        },
        {
            join      => { thread => { category => 'space' } },
            '+select' => [
                'thread.visibility',  'thread.author_user_id',
                'thread.category_id', 'category.visibility',
                'category.space_id',  'space.visibility',
            ],
            '+as' => [
                qw(thread_visibility thread_author category_id
                  category_visibility space_id space_visibility)
            ],
            rows => 1,
        }
    )->single;
    return $undefined if !$row;

    return GPForum::Service::Forum::Visibility->readable(
        GPForum::Service::Forum::Viewer->from($viewer),
        {
            (
                map { $_ => $row->get_column($_) }
                  qw(category_id category_visibility space_id
                  space_visibility thread_author thread_visibility)
            ),
            post_author     => $row->get_column('author_user_id'),
            post_visibility => $row->get_column('visibility'),
        }
    ) ? $row : $undefined;
}

sub _apply_deleted_filter ( $query, $request ) {
    my $viewer = $request->{viewer_user_id};
    if ( defined $viewer && length $viewer ) {
        $query->{-or} = _viewer_deleted_clause($viewer);
        return;
    }

    $query->{'me.deleted_at'} = undef;

    return;
}

sub _viewer_deleted_clause ($viewer) {
    return [ { 'me.deleted_at' => undef },
        { 'me.author_user_id' => $viewer }, ];
}

# Adds the cursor to the query's -and, never replacing it: the -and already
# holds the post-visibility condition (ADR 0102), and replacing it -- as this
# did -- listed every private post from the second page on.
sub _apply_cursor ( $query, $after ) {
    my @and = @{ delete $query->{-and} // [] };
    if ( exists $query->{-or} ) {
        push @and, { -or => delete $query->{-or} };
    }
    push @and,
      GPForum::Infrastructure::Keyset->after(
        {},
        {
            id   => [ 'me.post_id',  $after->{id} ],
            sort => [ 'me.position', $after->{sort_value} ],
        }
      );
    $query->{-and} = \@and;

    return;
}

sub find_post ( $self, $post_id ) {
    if ( !defined $post_id || !length $post_id ) {
        my $undefined;
        return $undefined;
    }

    return $self->schema->resultset('Post')->find( { post_id => $post_id } );
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
