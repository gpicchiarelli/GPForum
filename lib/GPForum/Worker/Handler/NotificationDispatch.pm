# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::Handler::NotificationDispatch;

use strict;
use warnings;

use Carp qw(croak);

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $POST_CREATED => 'post.created';

has sink       => undef;
has dispatcher => undef;

sub supports ( $self, $event ) {
    return $event->{event_type} eq $POST_CREATED;
}

sub handle ( $self, $event ) {
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
        _fail_on_dropped_recipients( $task->{fanout} );
    }

    return $task;
}

# The dispatcher keeps going past a recipient it could not notify and reports
# them as failed. Returning normally marked the event done and dropped them
# for good: nothing retried, dead-lettered or logged them. Failing hands the
# event back to the outbox, whose retry is safe -- recipients already served
# come back as duplicates, by the inbox's primary key.
sub _fail_on_dropped_recipients ($fanout) {
    my $failed = ref $fanout eq 'HASH' ? $fanout->{failed} || [] : [];
    return if !@{$failed};

    croak sprintf 'notification fanout failed for %d recipient%s; retrying',
      scalar @{$failed}, @{$failed} == 1 ? q{} : 's';
}

sub _dispatch_notifications ( $self, $event, $task ) {
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

sub _event_value ( $event, $name ) {
    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
