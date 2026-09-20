package GPForum::Service::Forum::ThreadDetailReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Forum::PostReader;

our $VERSION = '0.001';

const my $DEFAULT_POST_LIMIT => 25;

has post_reader => sub {
    my ($self) = @_;

    return GPForum::Service::Forum::PostReader->new( schema => $self->schema );
};
has schema => undef;

sub find_thread {
    my ( $self, $thread_id, $viewer ) = @_;

    my $row = $self->find_thread_row($thread_id);

    return if !_thread_is_visible( $row, $viewer );

    return $row;
}

sub find_thread_row {
    my ( $self, $thread_id ) = @_;

    return if !defined $thread_id || !length $thread_id;

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
            join      => 'author',
            '+select' => [ 'author.username', 'author.display_name' ],
            '+as'     => [qw(author_username author_display_name)],
        }
    );
}

sub thread_page {
    my ( $self, $request ) = @_;

    my $thread =
      $self->find_thread( $request->{thread_id}, $request->{viewer_user_id} );

    return { ok => 0, error => 'not_found' } if !$thread;

    my $posts = $self->post_reader->list_thread_posts(
        {
            thread_id      => $request->{thread_id},
            limit          => $request->{limit} || $DEFAULT_POST_LIMIT,
            after          => $request->{after},
            viewer_user_id => $request->{viewer_user_id},
        }
    );

    return {
        ok     => 1,
        thread => $thread,
        posts  => $posts,
    };
}

sub _thread_is_visible {
    my ( $row, $viewer ) = @_;

    return 0 if !_public_thread($row);
    return 1 if !_deleted_row($row);

    return _author_viewer( $row, $viewer );
}

sub _public_thread {
    my ($row) = @_;

    return 0 if !$row;
    return 0 if ( $row->get_column('visibility') || q{} ) ne 'public';

    return _visible_state( $row->get_column('moderation_state') );
}

sub _deleted_row {
    my ($row) = @_;

    return defined $row->get_column('deleted_at') ? 1 : 0;
}

sub _author_viewer {
    my ( $row, $viewer ) = @_;

    return 0 if !defined $viewer || !length $viewer;

    my $author = $row->get_column('author_user_id') || q{};

    return $author eq $viewer ? 1 : 0;
}

sub _visible_state {
    my ($state) = @_;

    return $state && ( $state eq 'visible' || $state eq 'locked' ) ? 1 : 0;
}

1;
