# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadDetailReader;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

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

    return undef
      if !_thread_is_visible( $row,
        GPForum::Service::Forum::Viewer->from($viewer) );

    return $row;
}

sub find_thread_row ( $self, $thread_id ) {
    return undef if !defined $thread_id || !length $thread_id;

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

__END__

=head1 NAME

GPForum::Service::Forum::ThreadDetailReader - Load a thread the viewer may read, with a page of its posts.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Forum::ThreadDetailReader->new(
        schema => $schema,
    );
    my $page = $reader->thread_page(
        {
            thread_id => $thread_id,
            viewer    => $viewer,
            limit     => 25,
            after     => $cursor,
        }
    );
    # { ok => 1, thread => $row, posts => { items, has_next, next_cursor } }
    # or { ok => 0, error => 'not_found' }

    my $thread = $reader->find_thread( $thread_id, $viewer );

=head1 DESCRIPTION

Reads the thread page. The thread row comes in one statement with its
author's names, its category's title and visibility and its space's
visibility, joined on primary keys, because the category and the space
decide who may read the thread (ADR 0102). A thread is readable when its
moderation state is C<visible> or C<locked> and
L<GPForum::Service::Forum::Visibility> lets the viewer read it; a deleted
thread is readable only by its author.

The posts come from L<GPForum::Service::Forum::PostReader>, scoped to the
viewer's grants for the thread's category and space. The author of a
private thread, when the viewer is a member, reads every reply in it.

A thread the viewer may not read and a thread that does not exist give the
same answer, so a page does not reveal that a hidden thread is there.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is the DBIx::Class schema;
C<post_reader> defaults to a L<GPForum::Service::Forum::PostReader> on it.

=head2 find_thread

Takes a thread id and an optional viewer (a
L<GPForum::Service::Forum::Viewer>, a user id, or nothing for an anonymous
reader). Returns the thread row from L</find_thread_row> when the viewer may
read it, otherwise C<undef>.

=head2 find_thread_row

Takes a thread id. Returns the C<Thread> row with its own columns
(C<thread_id>, C<category_id>, C<author_user_id>, C<title>, C<slug>,
C<pinned>, C<visibility>, C<moderation_state>, C<locked_at>,
C<last_activity_at>, C<deleted_at>) plus C<author_username>,
C<author_display_name>, C<category_title>, C<category_visibility>,
C<space_id> and C<space_visibility>, without any visibility check. Returns
C<undef> for an undefined or empty id or a missing thread.

=head2 thread_page

Takes a hash reference with C<thread_id>, an optional C<viewer> (anonymous
when absent), an optional C<limit> (25 when absent or zero) and an optional
C<after> cursor. Returns C<< { ok => 0, error => 'not_found' } >> when the
viewer may not read the thread, otherwise
C<< { ok => 1, thread => $row, posts => $page } >>, where C<$page> is the
post reader's page (C<items>, C<has_next>, C<next_cursor>).

=head1 DIAGNOSTICS

A thread that is missing or not readable is returned as C<not_found>, not
thrown. Database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::PostReader>, L<GPForum::Service::Forum::Viewer>,
L<GPForum::Service::Forum::Visibility>.

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
