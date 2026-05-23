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
    my ( $self, $thread_id ) = @_;

    return if !defined $thread_id || !length $thread_id;

    my $row = $self->schema->resultset('Thread')->find($thread_id);

    return if !_thread_is_visible($row);

    return $row;
}

sub thread_page {
    my ( $self, $request ) = @_;

    my $thread = $self->find_thread( $request->{thread_id} );

    return { ok => 0, error => 'not_found' } if !$thread;

    my $posts = $self->post_reader->list_thread_posts(
        {
            thread_id => $request->{thread_id},
            limit     => $request->{limit} || $DEFAULT_POST_LIMIT,
            after     => $request->{after},
        }
    );

    return {
        ok     => 1,
        thread => $thread,
        posts  => $posts,
    };
}

sub _thread_is_visible {
    my ($row) = @_;

    return 0 if !$row;
    return 0 if defined $row->get_column('deleted_at');

    return $row->get_column('moderation_state') eq 'visible' ? 1 : 0;
}

1;
