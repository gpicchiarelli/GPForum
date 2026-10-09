# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostReader;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Keyset;
use GPForum::Infrastructure::PreparedQuery;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

__PACKAGE__->requires('schema');

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };

# The columns a post row carries, in the order the resultset selects them.
const my @POST_COLUMNS => qw(
  post_id thread_id author_user_id current_body_id position
  visibility moderation_state created_at deleted_at
);
const my @POST_EXTRA =>
  qw(body body_source author_username author_display_name);

# What a visible post carries beyond its columns: the placement the
# visibility rule reads (ADR 0102).
const my @VISIBLE_POST_EXTRA => qw(
  thread_visibility thread_author category_id category_visibility space_id
  space_visibility
);

has prepared => sub { return GPForum::Infrastructure::PreparedQuery->new; };

# The statement is built once per shape and run with the request's values
# (Infrastructure::PreparedQuery). The shape is what changes its text: the
# viewer's standing, whether their own deleted posts are listed, and whether
# a cursor bounds the page.
sub list_thread_posts ( $self, $request ) {
    my $plan  = $self->page_window->plan($request);
    my $after = $plan->{after} || {};
    my $rows  = $self->prepared->rows(
        schema    => $self->schema,
        shape     => _posts_shape( $request, $plan ),
        source    => 'Post',
        as        => [ @POST_COLUMNS, @POST_EXTRA ],
        resultset =>
          sub { return $self->thread_posts_resultset( $request, $plan ); },
        values => {
            'me.thread_id'      => $request->{thread_id},
            'me.author_user_id' => $request->{viewer_user_id},
            'me.position'       => $after->{sort_value},
            'me.post_id'        => $after->{id},
            limit               => $plan->{fetch_rows},
        },
    );

    return $self->page_window->page( $rows, $plan->{limit},
        [ 'position', 'post_id' ] );
}

# The shape binds one viewer id for both the posts the viewer may read and
# the deleted posts of their own; a request whose scope names another
# viewer than its viewer_user_id has no shape and runs the resultset.
sub _posts_shape ( $request, $plan ) {
    my $viewer = $request->{viewer_scope}
      || GPForum::Service::Forum::Viewer->anonymous;
    return undef
      if ( $viewer->user_id // q{} ) ne ( $request->{viewer_user_id} // q{} );

    my $standing =
        $viewer->global_read ? 'global'
      : $viewer->member      ? 'member'
      :                        'anonymous';
    my $viewer_user_id = $request->{viewer_user_id};

    return join q{:}, 'posts', $standing,
      ( defined $viewer_user_id && length $viewer_user_id ? 'own'   : 'any' ),
      ( $plan->{after}                                    ? 'after' : 'first' );
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
            %{ _list_attrs() },
            order_by =>
              [ { -asc => 'me.position' }, { -asc => 'me.post_id' }, ],
            rows => $plan->{fetch_rows},
        }
    );
}

# What a listed post carries: its columns, its current body and its author.
sub _list_attrs {
    return {
        columns   => [@POST_COLUMNS],
        join      => [ 'current_body', 'author' ],
        '+select' => [
            'current_body.body_rendered_safe', 'current_body.body_source',
            'author.username',                 'author.display_name',
        ],
        '+as' => [@POST_EXTRA],
    };
}

# One post of a thread as the list would list it: the same columns, the
# same rules (ADR 0102). For the page that asks for the post a reply just
# created, with the viewer's scope for the thread.
sub find_listed_post ( $self, $request ) {
    my $query = {
        'me.post_id'          => $request->{post_id},
        'me.thread_id'        => $request->{thread_id},
        'me.moderation_state' => 'visible',
        %{ _post_visibility($request) },
    };
    _apply_deleted_filter( $query, $request );
    my $posts = $self->schema->resultset('Post');
    my $one   = sub {
        return $posts->search_rs( $query, { %{ _list_attrs() }, rows => 1 } );
    };
    my $shape = _posts_shape( $request, {} );

    return $self->prepared->rows(
        schema    => $self->schema,
        shape     => defined $shape ? "$shape:one" : undef,
        source    => 'Post',
        as        => [ @POST_COLUMNS, @POST_EXTRA ],
        resultset => $one,
        fallback  => sub { return [ $one->()->first // () ]; },
        values    => {
            'me.thread_id'      => $request->{thread_id},
            'me.post_id'        => $request->{post_id},
            'me.author_user_id' => $request->{viewer_user_id},
            limit               => 1,
        },
    )->[0];
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
    return undef if !defined $post_id || !length $post_id;

    my $posts   = $self->schema->resultset('Post');
    my $visible = sub {
        return $posts->search_rs(
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
                '+as' => [@VISIBLE_POST_EXTRA],
                rows  => 1,
            }
        );
    };
    my $row = $self->prepared->row(
        schema    => $self->schema,
        shape     => 'post:visible',
        source    => 'Post',
        extra_as  => [@VISIBLE_POST_EXTRA],
        resultset => $visible,
        fallback  => sub { return [ $visible->()->single // () ]; },
        values    => { 'me.post_id' => $post_id, limit => 1 },
    );
    return undef if !$row;

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
    ) ? $row : undef;
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
        return undef;
    }

    my $posts = $self->schema->resultset('Post');

    return $self->prepared->row(
        schema    => $self->schema,
        shape     => 'post:by-id',
        source    => 'Post',
        resultset => sub {
            return $posts->search_rs( { 'me.post_id' => $post_id } );
        },
        fallback =>
          sub { return [ $posts->find( { post_id => $post_id } ) // () ]; },
        values => { 'me.post_id' => $post_id },
    );
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::PostReader - The posts of a thread a viewer may read, page by page, and single-post lookups.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Forum::PostReader->new( schema => $schema );

    my $page = $reader->list_thread_posts(
        {
            limit          => 25,
            thread_id      => $thread_id,
            viewer_scope   => $viewer->within( $category_id, $space_id ),
            viewer_user_id => $viewer->user_id,
        }
    );
    # { items => [...], has_next => 1, next_cursor => '...' }

    my $post = $reader->find_visible_post( $post_id, $viewer );

=head1 DESCRIPTION

Reads posts for the thread page and for actions on a single post. The
caller has already authorized the thread; each post is judged on its own
visibility, with the viewer's grants decided for the thread's category
(C<viewer_scope>, from L<GPForum::Service::Forum::Viewer/within>), and as
public-only without one (ADR 0102). Only visible posts are listed, and
deleted ones are left out except that a signed-in viewer still sees their
own. Posts come in position order, keyset paged on C<position> and
C<post_id> through L<GPForum::Service::Forum::PageWindow>; the cursor is
added beside the visibility condition, never in place of it, which once
listed every private post from the second page on.

Each listed row carries the post's columns plus C<body> (the rendered safe
HTML), C<body_source>, C<author_username> and C<author_display_name>.

=head1 SUBROUTINES/METHODS

=head2 list_thread_posts

Takes a hash reference with C<thread_id>, C<viewer_scope>,
C<viewer_user_id>, C<limit> and C<after>. Returns
C<< { items, has_next, next_cursor } >> with the post rows.

=head2 thread_posts_resultset

Takes the same request and an optional page plan, made from the request
when absent. Returns the unexecuted resultset C<list_thread_posts> runs,
public so the query-plan evidence EXPLAINs what actually runs.

=head2 find_listed_post

Takes a hash reference with C<post_id>, C<thread_id>, C<viewer_scope> and
C<viewer_user_id>, as C<list_thread_posts> does. Returns the post as the
list would list it, with the same columns and under the same rules, or undef.

=head2 find_visible_post

Takes a post id and an optional viewer (a
L<GPForum::Service::Forum::Viewer>, a bare user id, or nothing for an
anonymous one). Returns the post row when the post is visible and not
deleted, its thread is visible or locked and not deleted, and the viewer may
read its space, category, thread and the post itself; undef otherwise, and
for an empty id.

=head2 find_post

Takes a post id. Returns the post row whatever its state, or undef for an
empty id or no row.

=head1 DIAGNOSTICS

C<new> throws L<GPForum::X::Argument> without a C<schema>. Otherwise none of
its own; what is missing or unreadable is returned as undef. Database errors
propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Base>, L<GPForum::Infrastructure::Keyset>,
L<GPForum::Service::Forum::Viewer>, L<GPForum::Service::Forum::Visibility>,
L<GPForum::Service::Forum::PageWindow>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
