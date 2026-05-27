package GPForum::Worker::Handler::NotificationDispatch;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $POST_CREATED => 'post.created';

has sink       => undef;
has dispatcher => undef;

sub supports {
    my ( $self, $event ) = @_;

    return $event->{event_type} eq $POST_CREATED;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = {
        action    => 'notification.dispatch',
        thread_id => _event_value( $event, 'thread_id' ),
        post_id   => $event->{aggregate_id},
        event_id  => $event->{event_id},
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }

    if ( $self->dispatcher && defined $task->{thread_id} ) {
        $task->{fanout} = $self->_dispatch_notifications( $event, $task );
    }

    return $task;
}

sub _dispatch_notifications {
    my ( $self, $event, $task ) = @_;

    return $self->dispatcher->fanout_to_subscribers(
        {
            target_type                => 'thread',
            target_id                  => $task->{thread_id},
            source_type                => 'post',
            source_id                  => $task->{post_id},
            notification_type          => 'reply',
            excluded_recipient_user_id => $event->{actor_id},
            idempotency_key            =>
              join( q{:}, 'notification.reply', $event->{event_id} ),
            payload => {
                thread_id => $task->{thread_id},
                post_id   => $task->{post_id},
                event_id  => $event->{event_id},
                actor_id  => $event->{actor_id},
            },
        }
    );
}

sub _event_value {
    my ( $event, $name ) = @_;

    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
