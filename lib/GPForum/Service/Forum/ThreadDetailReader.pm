# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadDetailReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

use GPForum::Service::Forum::PostReader;

our $VERSION = '0.001';

const my $DEFAULT_POST_LIMIT => 25;

has post_reader => sub {
    my ($self) = @_;

    return GPForum::Service::Forum::PostReader->new( schema => $self->schema );
};
has schema => undef;

# The thread, if the viewer can read it (ADR 0102): its space, its category
# and the thread itself, an author reading their own non-public or deleted
# thread. $viewer is a Viewer; none reads as anonymous.
sub find_thread ( $self, $thread_id, $viewer = undef ) {
    my $row = $self->find_thread_row($thread_id);

    my $undefined;
    return $undefined
      if !_thread_is_visible( $row,
        GPForum::Service::Forum::Viewer->from($viewer) );

    return $row;
}

sub find_thread_row ( $self, $thread_id ) {
    my $undefined;
    return $undefined if !defined $thread_id || !length $thread_id;

    return $self->schema->resultset('Thread')->find(
        $thread_id,
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug pinned
                  visibility moderation_state locked_at last_activity_at
                  deleted_at
                )
            ],

            # The category's title names it in the breadcrumb; its and its
            # space's visibility decide who may read the thread. Primary-key
            # joins in the same statement, not further queries.
            join      => [ 'author', { category => 'space' } ],
            '+select' => [
                'author.username',   'author.display_name',
                'category.title',    'category.visibility',
                'category.space_id', 'space.visibility',
            ],
            '+as' => [
                qw(author_username author_display_name category_title
                  category_visibility space_id space_visibility)
            ],
        }
    );
}

sub thread_page ( $self, $request ) {
    my $viewer = $request->{viewer}
      || GPForum::Service::Forum::Viewer->anonymous;
    my $thread = $self->find_thread( $request->{thread_id}, $viewer );

    return { ok => 0, error => 'not_found' } if !$thread;

    my $posts = $self->post_reader->list_thread_posts(
        {
            thread_id      => $request->{thread_id},
            limit          => $request->{limit} || $DEFAULT_POST_LIMIT,
            after          => $request->{after},
            viewer_user_id => $viewer->user_id,
            viewer_scope   => _post_scope( $viewer, $thread ),
        }
    );

    return {
        ok     => 1,
        thread => $thread,
        posts  => $posts,
    };
}

# The viewer for the thread's posts: grants decided for its category, and the
# owner of a private thread reads every reply in it (Visibility::_authors).
sub _post_scope ( $viewer, $thread ) {
    my $scope = $viewer->within( $thread->get_column('category_id'),
        $thread->get_column('space_id') );
    my $owner = $thread->get_column('author_user_id') // q{};
    return $scope
      if ( $thread->get_column('visibility') // q{} ) ne 'private'
      || !$viewer->member
      || ( $viewer->user_id // q{} ) ne $owner;

    return GPForum::Service::Forum::Viewer->new(
        global_read => 1,
        member      => 1,
        user_id     => $viewer->user_id,
    );
}

sub _thread_is_visible ( $row, $viewer ) {
    return 0 if !$row;
    return 0 if !_visible_state( $row->get_column('moderation_state') );
    return 0
      if !GPForum::Service::Forum::Visibility->readable(
        $viewer,
        {
            category_id         => $row->get_column('category_id'),
            category_visibility => $row->get_column('category_visibility'),
            space_id            => $row->get_column('space_id'),
            space_visibility    => $row->get_column('space_visibility'),
            thread_author       => $row->get_column('author_user_id'),
            thread_visibility   => $row->get_column('visibility'),
        }
      );
    return 1 if !_deleted_row($row);

    return _author_viewer( $row, $viewer->user_id );
}

sub _deleted_row ($row) {
    return defined $row->get_column('deleted_at') ? 1 : 0;
}

sub _author_viewer ( $row, $viewer ) {
    return 0 if !defined $viewer || !length $viewer;

    my $author = $row->get_column('author_user_id') || q{};

    return $author eq $viewer ? 1 : 0;
}

sub _visible_state ($state) {
    return $state && ( $state eq 'visible' || $state eq 'locked' ) ? 1 : 0;
}

1;
