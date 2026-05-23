package GPForum::Worker::Handler::NotificationDispatch;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $POST_CREATED => 'post.created';

has sink => undef;

sub supports {
    my ( $self, $event ) = @_;

    return $event->{event_type} eq $POST_CREATED;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = {
        action    => 'notification.dispatch',
        thread_id => $event->{thread_id},
        post_id   => $event->{aggregate_id},
        event_id  => $event->{event_id},
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }

    return $task;
}

1;
